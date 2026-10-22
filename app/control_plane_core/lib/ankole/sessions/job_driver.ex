defmodule Ankole.Sessions.JobDriver do
  @moduledoc "Observes and reconnects a durable Codex Job. The Job owns execution."
  @behaviour :gen_statem

  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.CodexJob
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.CodexJob.Attempt
  alias Ankole.{Observability, Repo}
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers

  @poll_ms 60_000
  @idle_ms :timer.minutes(5)

  def child_spec({key, _tenant_id} = args),
    do: %{id: {__MODULE__, key}, start: {__MODULE__, :start_link, [args]}, restart: :temporary}

  def start_link({key, _tenant_id} = args),
    do: :gen_statem.start_link({:global, Ankole.Sessions.driver_name(key)}, __MODULE__, args, [])

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init({key, tenant_id}) do
    Repo.put_tenant_id(tenant_id)
    Process.flag(:trap_exit, true)
    :ok = Ankole.Sessions.Events.subscribe_input(key.agent_uid, key.session_id)
    Phoenix.PubSub.subscribe(Ankole.PubSub, AgentWorkers.topic(key.agent_uid))

    {:ok, :idle,
     %{
       key: key,
       event: nil,
       attempt: nil,
       tasks: %{},
       mailbox_dirty: false,
       deferred_reason: nil,
       deferred_mode: nil
     }, [{:next_event, :internal, :rebuild}]}
  end

  @impl true
  def handle_event(:internal, :rebuild, _state, data),
    do: result(:rebuild, CodexJob.rebuild(data.key), :idle, data)

  def handle_event(:internal, :admit, _state, data),
    do: result(:admit, Admission.admit(data.key, data.event), :admitting, data)

  def handle_event(:state_timeout, :admit, :deferred, data),
    do: handle_event(:internal, :admit, :deferred, data)

  def handle_event(:state_timeout, :poll, state, data) when state in [:starting, :running],
    do: {:keep_state, observe(data), [{:state_timeout, @poll_ms, :poll}]}

  def handle_event(
        :info,
        {:job_turn, id, attempt},
        _state,
        %{attempt: %{job_ref: %{job_id: id, attempt: attempt}}} = data
      ),
      do: {:keep_state, observe(data)}

  def handle_event(:info, {:worker_changed, uid}, state, %{key: %{agent_uid: uid}} = data)
      when state in [:starting, :running], do: {:keep_state, observe(data)}

  def handle_event(
        :info,
        {:worker_changed, uid},
        :deferred,
        %{key: %{agent_uid: uid}, deferred_reason: :agent_worker_unavailable} = data
      ) do
    if worker_ready_for_mode?(uid, data.deferred_mode) do
      {:next_state, :admitting, %{data | deferred_reason: nil, deferred_mode: nil},
       [{:next_event, :internal, :admit}]}
    else
      :keep_state_and_data
    end
  end

  def handle_event(:info, {:worker, :turn_accepted, payload}, :starting, data) do
    if payload.turn == JobTurnRef.to_proto(data.attempt.job_ref),
      do:
        {:next_state, :running, task(data, :mailbox, fn -> CodexJob.mailbox(data.attempt) end),
         [{:state_timeout, @poll_ms, :poll}]},
      else: :keep_state_and_data
  end

  def handle_event(:info, {:worker, :worker_progress, _}, :running, data),
    do: {:keep_state, data, [{:state_timeout, @poll_ms, :poll}]}

  def handle_event(:info, :reconcile_inbox, :idle, data), do: rebuild(data)
  def handle_event(:info, {:inbox, _}, :idle, data), do: rebuild(data)

  def handle_event(:info, :reconcile_inbox, state, data) when state in [:starting, :running],
    do: {:keep_state, task(data, :mailbox, fn -> CodexJob.mailbox(data.attempt) end)}

  def handle_event(:info, {:inbox, id}, state, data) when state in [:starting, :running] do
    %{agent_uid: uid, session_id: session} = data.key

    case Ankole.Signals.get_signal!(id) do
      %Signal{
        agent_uid: ^uid,
        session_id: ^session,
        producer: :kernel,
        type: "command.steer",
        status: live_status
      }
      when live_status in [:queued, :running] ->
        {:keep_state, task(data, :mailbox, fn -> CodexJob.mailbox(data.attempt) end)}

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:state_timeout, :retire, :idle, data), do: {:stop, :normal, data}

  def handle_event(:info, {ref, value}, state, data) when is_reference(ref) do
    case Map.pop(data.tasks, ref) do
      {nil, _} ->
        :keep_state_and_data

      {{kind, _}, tasks} ->
        Process.demonitor(ref, [:flush])
        result(kind, value, state, %{data | tasks: tasks})
    end
  end

  def handle_event(:info, {:DOWN, ref, :process, _, reason}, state, data) do
    case Map.pop(data.tasks, ref) do
      {nil, _} ->
        :keep_state_and_data

      {{kind, _}, tasks} ->
        result(kind, {:error, {:task_exit, reason}}, state, %{data | tasks: tasks})
    end
  end

  def handle_event(:info, {:EXIT, _, :shutdown}, _state, data), do: {:stop, :shutdown, data}
  def handle_event(_, _, _, _), do: :keep_state_and_data

  defp result(:rebuild, {:ok, :idle}, _, data),
    do: {:next_state, :idle, data, [{:state_timeout, @idle_ms, :retire}]}

  defp result(:rebuild, {:ok, %{event: event, delay_ms: delay}}, _, data) do
    data = %{data | event: event, deferred_reason: nil, deferred_mode: nil}

    if delay > 0,
      do: {:next_state, :deferred, data, [{:state_timeout, delay, :admit}]},
      else: {:next_state, :admitting, data, [{:next_event, :internal, :admit}]}
  end

  defp result(:admit, {:ok, %Attempt{} = attempt}, _, data) do
    start(%{
      data
      | attempt: Observability.attach_turn(attempt),
        deferred_reason: nil,
        deferred_mode: nil
    })
  end

  defp result(
         :admit,
         {:ok, %{status: status, signal: event, retry_at: retry_at} = outcome},
         _,
         data
       )
       when status in [:deferred, :waiting_for_worker] do
    delay =
      max(0, DateTime.diff(retry_at, DateTime.utc_now(:microsecond), :millisecond))

    {:next_state, :deferred,
     %{
       data
       | event: event,
         deferred_reason: Map.get(outcome, :reason),
         deferred_mode: Map.get(outcome, :mode)
     }, [{:state_timeout, delay, :admit}]}
  end

  defp result(:admit, {:ok, _}, _, data), do: rebuild(data)
  defp result(:admit, {:error, :input_unavailable}, _, data), do: rebuild(data)

  defp result(:observe, {:ok, :running}, :starting, data),
    do: {:keep_state, task(data, :start, fn -> CodexJob.start(data.attempt) end)}

  defp result(:observe, {:ok, :running}, _, data),
    do:
      {:keep_state, task(data, :mailbox, fn -> CodexJob.mailbox(data.attempt) end),
       [{:state_timeout, @poll_ms, :poll}]}

  defp result(:observe, {:ok, {:adopt, worker}}, _, data),
    do: start(%{data | attempt: %{data.attempt | job_worker: worker, job_mode: "adopt"}})

  defp result(:observe, {:ok, :finished}, _, data), do: rebuild(data)

  defp result(_, {:error, reason}, _, data) when reason in [:stale_driver, :run_closed],
    do: {:stop, :normal, data}

  defp result(:mailbox, value, _, %{mailbox_dirty: true} = data) do
    case value do
      {:error, reason} -> log_failure(:mailbox, reason)
      _ -> :ok
    end

    {:keep_state,
     task(%{data | mailbox_dirty: false}, :mailbox, fn -> CodexJob.mailbox(data.attempt) end),
     [{:state_timeout, @poll_ms, :poll}]}
  end

  defp result(kind, {:error, reason}, _, data) when kind in [:start, :mailbox, :observe] do
    log_failure(kind, reason)
    {:keep_state, data, [{:state_timeout, @poll_ms, :poll}]}
  end

  defp result(_, {:error, reason}, _, data), do: {:stop, {:admission_failed, reason}, data}
  defp result(_, _, _, data), do: {:keep_state, data}

  defp log_failure(operation, reason) do
    Ankole.Logging.warning(
      "sessions.job_driver.operation_failed",
      "Job driver operation failed",
      Map.put(Ankole.Logging.failure_fields(:error, reason, []), :operation, operation)
    )
  end

  defp start(data),
    do:
      {:next_state, :starting, task(data, :start, fn -> CodexJob.start(data.attempt) end),
       [{:state_timeout, @poll_ms, :poll}]}

  defp observe(data) do
    if Enum.any?(data.tasks, fn {_, {kind, _}} -> kind == :observe end),
      do: data,
      else: task(data, :observe, fn -> CodexJob.observe(data.attempt) end)
  end

  defp task(data, kind, fun) do
    if kind == :mailbox and Enum.any?(data.tasks, fn {_, {running, _}} -> running == :mailbox end) do
      %{data | mailbox_dirty: true}
    else
      task = Task.Supervisor.async_nolink(Ankole.Sessions.Tasks, Repo.bind_tenant(fun))
      %{data | tasks: Map.put(data.tasks, task.ref, {kind, task.pid})}
    end
  end

  defp rebuild(data) do
    clear_tasks(data)
    if data.attempt, do: Observability.finish_turn(data.attempt.span, outcome: "job_finished")

    {:next_state, :idle,
     %{
       data
       | attempt: nil,
         event: nil,
         tasks: %{},
         mailbox_dirty: false,
         deferred_reason: nil,
         deferred_mode: nil
     }, [{:next_event, :internal, :rebuild}]}
  end

  defp worker_ready_for_mode?(uid, "adopt"),
    do: match?({:ok, _}, AgentWorkers.connected_worker(uid))

  defp worker_ready_for_mode?(uid, _mode),
    do: match?({:ok, _}, AgentWorkers.ready_worker(uid))

  defp clear_tasks(data) do
    Enum.each(data.tasks, fn {ref, {_, pid}} ->
      Task.Supervisor.terminate_child(Ankole.Sessions.Tasks, pid)
      Process.demonitor(ref, [:flush])
    end)
  end

  @impl true
  def terminate(reason, _state, data) do
    clear_tasks(data)
    if data.attempt, do: Observability.finish_turn(data.attempt.span, error_type: inspect(reason))
    :ok
  end
end
