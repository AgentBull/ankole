defmodule Ankole.Sessions.JobDriver do
  @moduledoc "Observes and reconnects a durable Codex Job. The Job owns execution."
  @behaviour :gen_statem
  require Logger

  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.CodexJob
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.Run
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
    Phoenix.PubSub.subscribe(Ankole.PubSub, AgentWorkers.topic(key.agent_uid))

    {:ok, :idle, %{key: key, event: nil, attempt: nil, tasks: %{}},
     [{:next_event, :internal, :rebuild}]}
  end

  @impl true
  def handle_event(:internal, :rebuild, _state, data),
    do: result(:rebuild, Run.rebuild(data.key), :idle, data)

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
    case Repo.get_by(Signal,
           id: id,
           agent_uid: data.key.agent_uid,
           session_id: data.key.session_id
         ) do
      %Signal{producer: :kernel, type: "command.steer", input_state: "open", completed_at: nil} ->
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
    if delay > 0,
      do: {:next_state, :deferred, %{data | event: event}, [{:state_timeout, delay, :admit}]},
      else: {:next_state, :admitting, %{data | event: event}, [{:next_event, :internal, :admit}]}
  end

  defp result(:admit, {:ok, %Attempt{} = attempt}, _, data) do
    start(%{data | attempt: Observability.attach_turn(attempt)})
  end

  defp result(:admit, {:ok, %{status: status, signal: event}}, _, data)
       when status in [:deferred, :waiting_for_worker] do
    delay =
      max(0, DateTime.diff(event.available_at, DateTime.utc_now(:microsecond), :millisecond))

    {:next_state, :deferred, %{data | event: event}, [{:state_timeout, delay, :admit}]}
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

  defp result(kind, {:error, reason}, _, data) when kind in [:start, :mailbox, :observe] do
    Logger.warning("Job driver #{kind} failed: #{inspect(reason)}")
    {:keep_state, data, [{:state_timeout, @poll_ms, :poll}]}
  end

  defp result(_, {:error, reason}, _, data), do: {:stop, {:admission_failed, reason}, data}
  defp result(_, _, _, _), do: :keep_state_and_data

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
    task = Task.Supervisor.async_nolink(Ankole.Sessions.Tasks, Repo.bind_tenant(fun))
    %{data | tasks: Map.put(data.tasks, task.ref, {kind, task.pid})}
  end

  defp rebuild(data) do
    clear_tasks(data)
    if data.attempt, do: Observability.finish_turn(data.attempt.span, outcome: "job_finished")

    {:next_state, :idle, %{data | attempt: nil, event: nil, tasks: %{}},
     [{:next_event, :internal, :rebuild}]}
  end

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
