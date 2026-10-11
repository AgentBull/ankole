defmodule Ankole.Conversations.Driver do
  @moduledoc """
  Serializes one conversation across control-plane nodes.

  The global name selects the common-path writer. The workspace epoch rejects
  a writer that survives a partition. Tasks never contain recovery truth.
  """
  @behaviour :gen_statem
  require Logger

  defmodule State do
    @moduledoc false
    @enforce_keys [:key]
    defstruct [
      :key,
      :run,
      :event,
      :stream,
      :worker,
      :worker_monitor,
      :workspace_reply,
      :worker_wait_since,
      :worker_wait_phase,
      tasks: %{},
      pending: %{},
      early_stream: [],
      observing?: false,
      worker_changed?: false,
      worker_requested?: false,
      workspace_opened?: false
    ]

    @type t :: %__MODULE__{}
  end

  defmodule PendingCall do
    @moduledoc false
    @enforce_keys [:call]
    defstruct [
      :call,
      :tool,
      :args,
      :span,
      :wait,
      :worker_name,
      :continue,
      :mode,
      status: :queued,
      probe?: false,
      sequential?: false
    ]

    @type t :: %__MODULE__{}
    @parallelism 4
    alias Ankole.Conversations.Run

    def new_round(calls, probe?),
      do: Map.new(calls, &{Run.call_id(&1), %__MODULE__{call: &1, probe?: probe?}})

    def next(pending, calls) do
      active = Enum.count(pending, fn {_id, p} -> p.status != :queued end)
      call = Enum.find(calls, &match?(%{status: :queued}, pending[Run.call_id(&1)]))
      if call && active < @parallelism, do: {:ok, call, active}, else: :none
    end

    def blocked?(pending, sequential?, active),
      do:
        Enum.any?(pending, fn {_id, p} -> p.status != :queued and p.sequential? end) or
          (sequential? and active > 0)

    def start(pending, id, call, tool, args, span, sequential?),
      do:
        Map.update!(
          pending,
          id,
          &%{
            &1
            | call: call,
              tool: tool,
              args: args,
              span: span,
              sequential?: sequential?,
              status: :running
          }
        )

    def delegate(pending, id, name, args, continue),
      do:
        Map.update!(
          pending,
          id,
          &%{
            &1
            | worker_name: name,
              args: args,
              continue: continue,
              tool: %{&1.tool | retry_safe: true}
          }
        )

    def await(pending, id, wait),
      do: Map.update!(pending, id, &%{&1 | status: :waiting, wait: wait})

    def wait_worker(pending, id), do: Map.update!(pending, id, &%{&1 | status: :worker_wait})

    def to_worker(pending, id) do
      entry = pending[id]
      mode = if entry.probe? and not entry.tool.retry_safe, do: "probe", else: "execute"
      entry = %{entry | status: :worker, mode: mode}
      {Map.put(pending, id, entry), entry}
    end

    def ready(pending),
      do:
        map(pending, fn p -> if p.status == :worker_wait, do: %{p | status: :queued}, else: p end)

    def worker_changed(pending),
      do:
        map(pending, fn p ->
          if p.status in [:worker, :worker_wait],
            do: %{p | status: :queued, probe?: p.probe? or p.status == :worker},
            else: p
        end)

    def worker_same(pending),
      do:
        map(pending, fn p ->
          if p.status == :worker, do: %{p | status: :queued, probe?: true}, else: p
        end)

    def send_failed(pending, id),
      do:
        if(Map.has_key?(pending, id),
          do: Map.update!(pending, id, &%{&1 | status: :queued, probe?: true}),
          else: pending
        )

    def unknown(pending, id),
      do: Map.update!(pending, id, &%{&1 | status: :queued, probe?: false})

    def waiting_worker(pending), do: for({id, p} <- pending, p.status == :worker_wait, do: id)

    def queued(pending), do: for({id, p} <- pending, p.status == :queued, do: id)
    def on_worker(pending), do: for({id, p} <- pending, p.status == :worker, do: id)
    def waits(pending), do: for({id, p} <- pending, p.status == :waiting, do: {id, p.wait})
    defp map(pending, transform), do: Map.new(pending, fn {id, p} -> {id, transform.(p)} end)
  end

  alias Ankole.AIGateway
  alias Ankole.Observability

  alias Ankole.Conversations.{
    Admission,
    CodexJob,
    Commands,
    Machine,
    Model,
    Presentation,
    Run,
    Revisions,
    ToolArguments,
    ToolCatalog,
    ToolResult,
    Tools,
    Worker
  }

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers
  alias Ankole.Repo

  @idle_ms :timer.minutes(5)
  @poll_ms 1_000
  @worker_acquire_ms 60_000

  @spec child_spec({map(), String.t()}) :: Supervisor.child_spec()
  def child_spec({key, _tenant_id} = args),
    do: %{id: {__MODULE__, key}, start: {__MODULE__, :start_link, [args]}, restart: :temporary}

  @spec name(map()) :: {module(), String.t(), String.t()}
  def name(key), do: {__MODULE__, key.agent_uid, key.session_id}
  @spec whereis(map()) :: pid() | :undefined
  def whereis(key), do: :global.whereis_name(name(key))
  @spec start_link({map(), String.t()}) :: :gen_statem.start_ret()
  def start_link({key, _tenant_id} = args),
    do: :gen_statem.start_link({:global, name(key)}, __MODULE__, args, [])

  @spec ensure(map()) :: {:ok, pid()} | {:error, term()}
  def ensure(key) do
    case Repo.get(Ankole.Principals.Principal, key.agent_uid) do
      %{type: :agent, tenant_id: tenant_id} -> ensure_in_tenant(key, tenant_id)
      _ -> {:error, :agent_not_found}
    end
  end

  defp ensure_in_tenant(key, tenant_id) do
    case whereis(key) do
      :undefined ->
        case DynamicSupervisor.start_child(
               Ankole.Conversations.Drivers,
               {__MODULE__, {key, tenant_id}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = error -> error
        end

      pid ->
        {:ok, pid}
    end
  end

  @impl true
  def callback_mode, do: :handle_event_function
  @impl true
  def init({key, tenant_id}) do
    Repo.put_tenant_id(tenant_id)
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Ankole.PubSub, AgentWorkers.topic(key.agent_uid))

    {:ok, :idle, %State{key: key}, [{:next_event, :internal, :rebuild}]}
  end

  @impl true
  def handle_event(:internal, :rebuild, _state, data) do
    task_result(:rebuild, Run.rebuild(data.key), :idle, data)
  end

  def handle_event(:state_timeout, :admit, :backing_off, data), do: admit(data)
  def handle_event(:state_timeout, :admit, :deferred, data), do: admit(data)
  def handle_event(:internal, :admit, _state, data), do: admit(data)

  def handle_event(:internal, :request, _state, data) do
    run = %{data.run | iteration: data.run.iteration + 1}
    receiver = self()

    Presentation.event(run, "turn.phase", %{
      "operation_id" => "turn",
      "state" => "working",
      "label_key" => "signals_gateway.reply.activity.turn_understanding"
    })

    {:next_state, :requesting_model,
     task(%{data | run: run, stream: nil, early_stream: []}, :model, fn ->
       Model.open(run, receiver)
     end), model_deadline(run)}
  end

  def handle_event(
        :internal,
        {:resume_run, epoch, state},
        _state,
        %{run: %Run{epoch: epoch}} = data
      ) do
    case state do
      :preparing -> {:next_state, :requesting_model, data, [{:next_event, :internal, :request}]}
      :executing_tools -> enter_tools(data)
      :boundary -> {:next_state, :boundary, data, [{:next_event, :internal, :boundary}]}
    end
  end

  def handle_event(:internal, :tools, :executing_tools, data), do: dispatch_tools(data)

  def handle_event(:internal, :boundary, _state, data) do
    task_result(:boundary, inject_pending(data.run), :boundary, data)
  end

  def handle_event(:state_timeout, :poll, :executing_tools, data), do: observe_waits(data)

  def handle_event(:state_timeout, :job_poll, :job_running, data) do
    {:keep_state, task(data, :job_observe, fn -> CodexJob.observe(data.run) end)}
  end

  def handle_event(
        :info,
        {:job_turn, id, attempt},
        _state,
        %{run: %{kind: :job, job_ref: %{job_id: id, attempt: attempt}}} = data
      ) do
    if Enum.any?(data.tasks, fn {_ref, {kind, _}} -> kind == :job_observe end),
      do: :keep_state_and_data,
      else: {:keep_state, task(data, :job_observe, fn -> CodexJob.observe(data.run) end)}
  end

  def handle_event(:state_timeout, :job_accept, :starting_job, data) do
    data =
      if Enum.any?(data.tasks, fn {_ref, {kind, _}} -> kind == :job_observe end),
        do: data,
        else: task(data, :job_observe, fn -> CodexJob.observe(data.run) end)

    {:keep_state, data, [{:state_timeout, 60_000, :job_accept}]}
  end

  def handle_event(
        {:timeout, :model_activity},
        {epoch, iteration},
        :requesting_model,
        %{run: %{epoch: epoch, iteration: iteration}} = data
      ) do
    if data.stream, do: AIGateway.cancel_response_stream(data.stream, "model_inactivity_timeout")

    failed(
      %{
        "code" => "model_inactivity_timeout",
        "message" => "The model stopped sending events.",
        "retryable" => true
      },
      data
    )
  end

  def handle_event(:info, {:worker, :turn_accepted, payload}, :starting_job, data) do
    if payload.turn == Ankole.Conversations.JobTurnRef.to_proto(data.run.job_ref) do
      {:next_state, :job_running, task(data, :job_mailbox, fn -> CodexJob.mailbox(data.run) end),
       [{:state_timeout, 60_000, :job_poll}]}
    else
      :keep_state_and_data
    end
  end

  def handle_event(:info, {:worker, :worker_progress, _payload}, :job_running, data),
    do: {:keep_state, data, [{:state_timeout, 60_000, :job_poll}]}

  def handle_event(:state_timeout, :retire, :idle, data), do: {:stop, :normal, data}

  def handle_event(:info, :reconcile_inbox, _state, data) do
    actions = Enum.map(Run.open_events(data.key), &{:next_event, :internal, {:inbox, &1.id}})
    {:keep_state, data, actions}
  end

  def handle_event(:internal, {:inbox, _id} = event, state, data),
    do: handle_event(:info, event, state, data)

  # Admission must return its Run before a control input can end that Run.
  def handle_event(:info, {:inbox, _id}, state, _data)
      when state in [:admitting, :preparing],
      do: {:keep_state_and_data, [:postpone]}

  # An inbox notice must not cancel the current terminal transaction or the
  # round that is being recorded.
  def handle_event(:info, {:inbox, _id}, state, _data) when state in [:finalizing, :recording],
    do: {:keep_state_and_data, [:postpone]}

  def handle_event(:info, {:inbox, _id}, :idle, data) do
    {:keep_state, data, [{:next_event, :internal, :rebuild}]}
  end

  def handle_event(:info, {:inbox, id}, state, data) do
    event =
      Repo.get_by(ActorEvent,
        id: id,
        agent_uid: data.key.agent_uid,
        session_id: data.key.session_id
      )

    event =
      case event do
        %ActorEvent{input_state: "open", completed_at: nil} ->
          case Admission.authorize_event(event) do
            {:ok, authorized} -> authorized
            {:error, _} -> nil
          end

        _ ->
          event
      end

    task_result({:inbox, id}, event, state, data)
  end

  def handle_event(
        :info,
        {:worker_changed, uid},
        :executing_tools,
        %{key: %{agent_uid: uid}} = data
      ) do
    {:keep_state, worker_changed(data), [{:next_event, :internal, :tools}]}
  end

  def handle_event({:timeout, :worker_check}, :check, :executing_tools, data) do
    {:keep_state, check_worker(data),
     [{{:timeout, :worker_check}, 60_000, :check}, {:next_event, :internal, :tools}]}
  end

  def handle_event({:timeout, :worker_acquire}, :expired, :executing_tools, data) do
    if data.worker_wait_since do
      data = fail_worker_waits({:timeout, data.worker_wait_phase}, data)
      data = clear_tasks(data, fn kind -> kind == :worker_open end)
      {:keep_state, data, [{:next_event, :internal, :tools}]}
    else
      :keep_state_and_data
    end
  end

  def handle_event(
        :info,
        {:worker_changed, uid},
        state,
        %{run: %{kind: :job}, key: %{agent_uid: uid}} = data
      )
      when state in [:starting_job, :job_running],
      do: {:keep_state, task(data, :job_observe, fn -> CodexJob.observe(data.run) end)}

  def handle_event(:info, {:recover_preview, _id}, state, _data)
      when state in [:admitting, :preparing],
      do: {:keep_state_and_data, [:postpone]}

  def handle_event(:info, {:recover_preview, id}, _state, %{
        run: %Run{actor_event_id: id, kind: kind} = run
      })
      when kind != :job do
    Presentation.start(run, self())
    :keep_state_and_data
  end

  def handle_event(:info, {:worker, type, payload}, :executing_tools, data),
    do: worker_result(type, payload, data)

  def handle_event(
        :info,
        {:ai_gateway_response_stream, _ref, :events, events, _status} = message,
        :requesting_model,
        %{stream: nil} = data
      ) do
    data = request_stream_worker(data, events)
    {:keep_state, %{data | early_stream: [message | data.early_stream]}}
  end

  def handle_event(:internal, {:worker_unavailable, reason}, :executing_tools, data) do
    data = fail_worker_waits(reason, data)

    {:keep_state, data,
     [{{:timeout, :worker_acquire}, :cancel}, {:next_event, :internal, :tools}]}
  end

  def handle_event(
        :info,
        {:ai_gateway_response_stream, ref, :events, events, status},
        :requesting_model,
        %{stream: %{ref: ref}} = data
      ) do
    data = request_stream_worker(data, events)

    case status do
      :continue ->
        AIGateway.read_response_stream(data.stream)
        {:keep_state, data, model_deadline(data.run)}

      {:terminal, outcome} ->
        model_terminal(outcome, data)
    end
  end

  def handle_event(:internal, {:ai_gateway_response_stream, _, _, _, _} = event, state, data),
    do: handle_event(:info, event, state, data)

  def handle_event(:info, {ref, result}, state, data) when is_reference(ref) do
    case Map.pop(data.tasks, ref) do
      {nil, _} ->
        :keep_state_and_data

      {{kind, _pid}, tasks} ->
        Process.demonitor(ref, [:flush])
        task_result(kind, result, state, %{data | tasks: tasks})
    end
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        :executing_tools,
        %{worker_monitor: ref} = data
      ) do
    {:keep_state, worker_changed(%{data | worker_monitor: nil}),
     [{:next_event, :internal, :tools}]}
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, state, data) do
    case Map.pop(data.tasks, ref) do
      {nil, _} ->
        :keep_state_and_data

      {{kind, _pid}, tasks} ->
        task_result(kind, {:error, {:task_exit, reason}}, state, %{data | tasks: tasks})
    end
  end

  def handle_event(:info, {:EXIT, _pid, :shutdown}, _state, data), do: {:stop, :shutdown, data}
  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  defp admit(data),
    do: task_result(:admit, Admission.admit(data.key, data.event), :admitting, data)

  defp task(data, kind, fun) do
    task = Task.Supervisor.async_nolink(Ankole.Conversations.Tasks, Ankole.Repo.bind_tenant(fun))
    %{data | tasks: Map.put(data.tasks, task.ref, {kind, task.pid})}
  end

  defp task_result(:rebuild, {:ok, :idle}, _state, data),
    do:
      {:next_state, :idle, %{data | run: nil, event: nil}, [{:state_timeout, @idle_ms, :retire}]}

  defp task_result(:rebuild, {:ok, %{event: event, delay_ms: delay}}, _state, data) do
    route =
      if Run.kind(data.key.session_id) == :job, do: :run, else: Commands.route(event)

    case route do
      :run ->
        if delay > 0,
          do:
            {:next_state, :backing_off, %{data | event: event}, [{:state_timeout, delay, :admit}]},
          else:
            {:next_state, :admitting, %{data | event: event}, [{:next_event, :internal, :admit}]}

      :control ->
        {:next_state, :admitting,
         task(%{data | event: event}, :control, fn -> Commands.process(data.key, event) end)}
    end
  end

  defp task_result(:control, {:ok, %Run{} = run}, :backing_off, data) do
    delay =
      max(DateTime.diff(run.event.available_at, DateTime.utc_now(:microsecond), :millisecond), 0)

    {:next_state, :backing_off, %{data | run: nil, event: run.event, pending: %{}},
     [{:state_timeout, delay, :admit}]}
  end

  defp task_result(:control, {:ok, %Run{} = run}, _state, data) do
    prepare(%{data | run: run, pending: %{}}, run)
  end

  defp task_result(:control, {:ok, _}, _state, data) do
    close_and_rebuild(data)
  end

  defp task_result({:retry_action, event}, {:ok, :interrupt}, state, data) do
    data = cancel_current(data)

    task_result(:control, Commands.interrupt(data.run, event), state, data)
  end

  defp task_result({:retry_action, _event}, {:ok, :continue}, _state, _data),
    do: :keep_state_and_data

  defp task_result(:admit, {:ok, %Run{kind: :job} = run}, _state, data) do
    run = start_trace(run)

    {:next_state, :starting_job,
     task(%{data | run: run}, :job_start, fn -> CodexJob.start(run) end),
     [{:state_timeout, 60_000, :job_accept}]}
  end

  defp task_result(:job_start, {:ok, _}, _state, _data), do: :keep_state_and_data

  defp task_result(kind, {:error, reason}, _state, data)
       when kind in [:job_start, :job_mailbox] and
              reason in [:stale_driver, :run_closed],
       do: failed(reason, data)

  defp task_result(kind, {:error, _}, _state, _data)
       when kind in [:job_start, :job_mailbox], do: :keep_state_and_data

  defp task_result(:job_mailbox, :ok, _state, _data), do: :keep_state_and_data
  defp task_result(:job_mailbox, {:ok, _}, _state, _data), do: :keep_state_and_data

  defp task_result(:job_observe, {:ok, :running}, :starting_job, data),
    do: {:keep_state, task(data, :job_start, fn -> CodexJob.start(data.run) end)}

  defp task_result(:job_observe, {:ok, :running}, _state, data),
    do:
      {:keep_state, task(data, :job_mailbox, fn -> CodexJob.mailbox(data.run) end),
       [{:state_timeout, 60_000, :job_poll}]}

  defp task_result(:job_observe, {:ok, {:adopt, worker}}, _state, data) do
    run = %{data.run | job_worker: worker, job_mode: "adopt"}

    {:next_state, :starting_job,
     task(%{data | run: run}, :job_start, fn -> CodexJob.start(run) end),
     [{:state_timeout, 60_000, :job_accept}]}
  end

  defp task_result(:job_observe, {:ok, :finished}, _state, data),
    do: rebuild(finish_trace(data, outcome: "job_finished"))

  defp task_result(:admit, {:ok, %Run{} = run}, _state, data) do
    prepare(data, run)
  end

  defp task_result(:admit, {:ok, %{status: :deferred}}, _state, %{run: %Run{}} = data),
    do: close_and_rebuild(data)

  defp task_result(:admit, {:ok, %{status: status, actor_event: event}}, _state, data)
       when status in [:deferred, :waiting_for_worker] do
    delay =
      max(0, DateTime.diff(event.available_at, DateTime.utc_now(:microsecond), :millisecond))

    {:next_state, :deferred, %{data | event: event}, [{:state_timeout, delay, :admit}]}
  end

  defp task_result(:admit, {:ok, _terminal}, _state, data), do: rebuild(data)

  defp task_result(:admit, {:error, reason}, _state, data)
       when reason in [:agent_not_active, :workflow_agent_at_capacity] do
    {:next_state, :deferred, data, [{:state_timeout, 30_000, :admit}]}
  end

  defp task_result(:admit, {:error, :input_unavailable}, _state, data),
    do: close_and_rebuild(data)

  defp task_result(:prepare, {:ok, {:ambient_skip, run}}, _old_state, data),
    do: finalize(%{data | run: run}, "silent")

  defp task_result(:prepare, {:ok, {state, run}}, _old_state, data) do
    # Rebuild the durable inbox before resuming model or tool I/O. A stop can
    # have committed while no process existed to receive its notification.
    actions = Enum.map(run.pending_event_ids, &{:next_event, :internal, {:inbox, &1}})

    {:next_state, :boundary, %{data | run: run},
     actions ++ [{:next_event, :internal, {:resume_run, run.epoch, state}}]}
  end

  defp task_result(:model, {:ok, stream, _meta}, _state, data) do
    :ok = AIGateway.read_response_stream(stream)
    actions = Enum.map(Enum.reverse(data.early_stream), &{:next_event, :internal, &1})
    {:keep_state, %{data | stream: stream, early_stream: []}, actions}
  end

  defp task_result(:model_response, {:ok, response}, _state, data) do
    run = %{
      data.run
      | model_response: response,
        anchor: response.id,
        input: [],
        round_calls: Run.executable_calls(response),
        results: %{},
        receipts: %{},
        follow_ups: [],
        wait_event_ids: [],
        recovered?: false
    }

    if Run.truncated?(response) or run.round_calls == [],
      do:
        {:next_state, :boundary, %{data | run: %{run | calls: []}, stream: nil},
         [{:next_event, :internal, :boundary}]},
      else: enter_tools(%{data | run: %{run | calls: run.round_calls}, stream: nil})
  end

  defp task_result({:tool, id}, {:error, reason}, state, data),
    do: task_result({:tool, id}, Tools.error(reason), state, data)

  defp task_result({:tool, id}, {:delegate, name, args, continue}, :executing_tools, data) do
    pending = PendingCall.delegate(data.pending, id, name, args, continue)

    {:keep_state, dispatch_worker(%{data | pending: pending}, id)}
  end

  defp task_result({:tool, id}, {:await, wait}, :executing_tools, data) do
    {:keep_state, await_result(data, id, wait), [{:next_event, :internal, :tools}]}
  end

  defp task_result({:tool, id}, %ToolResult{} = result, :executing_tools, data),
    do: accept_result(id, result, data)

  defp task_result(:record, {:ok, journal}, _state, data) do
    # A committed batch no longer accepts its transport and polling results.
    data =
      clear_tasks(data, fn kind ->
        kind in [:worker_open, :observe] or match?({:worker_send, _}, kind)
      end)

    run = %{
      data.run
      | calls: [],
        anchor: journal.message.id,
        saw_tool_results: true,
        follow_ups: [],
        wait_event_ids: []
    }

    {:next_state, :boundary, %{data | run: run, pending: %{}, observing?: false},
     [{:next_event, :internal, :boundary}]}
  end

  defp task_result(:worker_open, {:error, reason}, _state, data)
       when reason in [:stale_driver, :run_closed], do: failed(reason, data)

  defp task_result(:worker_open, result, :executing_tools, data),
    do: worker_opened(data, result)

  defp task_result({:worker_send, id}, {:error, _reason}, :executing_tools, data) do
    pending = PendingCall.send_failed(data.pending, id)

    {:keep_state, %{data | pending: pending, worker: nil, workspace_reply: nil},
     [{:next_event, :internal, :tools}]}
  end

  defp task_result({:worker_send, _id}, {:ok, _}, _state, _data), do: :keep_state_and_data

  defp task_result(:boundary, {:ok, run}, _state, data) do
    case Machine.next(run) do
      {:request, run} ->
        {:keep_state, %{data | run: run}, [{:next_event, :internal, :request}]}

      {:finalize, run} ->
        finalize(%{data | run: run}, run.outcome)

      {:workflow_failure, run, failure} ->
        task_result(:workflow_failure, Commands.workflow_failure(run, failure), :finalizing, %{
          data
          | run: run
        })
    end
  end

  defp task_result(:observe, observations, :executing_tools, data) when is_list(observations) do
    data = %{data | observing?: false}

    {data, _} =
      Enum.reduce(observations, {data, nil}, fn
        {_id, :pending}, acc ->
          acc

        {id, {:ready, result, ids}}, {data, _} ->
          {put_result(id, result, %{
             data
             | run: %{data.run | wait_event_ids: Enum.uniq(data.run.wait_event_ids ++ ids)}
           }), nil}
      end)

    {:keep_state, data, [{:next_event, :internal, :tools}]}
  end

  defp task_result(
         {:inbox, _id},
         %ActorEvent{input_state: "open", completed_at: nil} = event,
         _state,
         %{run: %Run{kind: :job}} = data
       ) do
    case event.type do
      "command.steer" ->
        {:keep_state, task(data, :job_mailbox, fn -> CodexJob.mailbox(data.run) end)}

      _ ->
        :keep_state_and_data
    end
  end

  defp task_result(
         {:inbox, _id},
         %ActorEvent{input_state: "open", completed_at: nil} = event,
         _state,
         %{run: nil} = data
       ) do
    if event.type in ["command.stop", "command.new", "command.retry"] and
         Commands.route(event) == :control,
       do:
         {:next_state, :admitting,
          task(data, :control, fn -> Commands.process(data.key, event) end)},
       else: :keep_state_and_data
  end

  defp task_result(
         {:inbox, _id},
         %ActorEvent{input_state: "open", completed_at: nil} = event,
         state,
         data
       ) do
    cond do
      event.id == data.run.actor_event_id or event.id in data.run.steer_event_ids ->
        :keep_state_and_data

      event.type == "command.retry" ->
        task_result({:retry_action, event}, Commands.retry_action(data.run, event), state, data)

      event.type in ["command.stop", "command.new"] or
          (event.type == "input.revised" and Revisions.immediate?(data.run, event)) ->
        data = cancel_current(data)
        task_result(:control, Commands.interrupt(data.run, event), state, data)

      event.id in data.run.pending_event_ids ->
        :keep_state_and_data

      true ->
        run = %{data.run | pending_event_ids: data.run.pending_event_ids ++ [event.id]}
        data = %{data | run: run}
        if state == :executing_tools, do: observe_waits(data), else: {:keep_state, data}
    end
  end

  defp task_result({:inbox, _}, _result, _state, _data), do: :keep_state_and_data

  defp task_result(:finalize, {:ok, _result}, _state, data), do: close_and_rebuild(data)

  defp task_result(:workflow_failure, {:ok, %{call: %{status: status}}}, _state, data)
       when status in ["queued", "sleeping"], do: close_and_rebuild(data)

  defp task_result(:workflow_failure, {:ok, _}, _state, data), do: finalize(data, "submitted")

  defp task_result(:withdrawal, %ActorEvent{} = event, _state, data) do
    data = cancel_current(data)

    task_result(:control, Commands.interrupt(data.run, event), :finalizing, data)
  end

  defp task_result(:withdrawal, nil, _state, data), do: finalize(cancel_current(data), "stopped")

  defp task_result(_kind, {:error, reason}, _state, data), do: failed(reason, data)

  defp enter_tools(data) do
    # Committed operations survive changes to the current tool definitions.
    pending =
      PendingCall.new_round(data.run.calls, data.run.recovered?)
      |> Map.new(fn {id, entry} ->
        if Map.has_key?(data.run.receipts, id) do
          tool = ToolCatalog.find(data.run, entry.call)

          args =
            case ToolArguments.parse(entry.call["arguments"] || "{}") do
              {:ok, args, _repair} -> args
              {:error, _reason} -> %{}
            end

          {id,
           %{
             entry
             | status: :running,
               tool: tool,
               args: args,
               span: Observability.start_tool(data.run.span, entry.call),
               sequential?: is_nil(tool) or tool.execution_mode == "sequential"
           }}
        else
          {id, entry}
        end
      end)

    data = %{data | pending: pending, worker: nil, workspace_reply: nil}

    data =
      Enum.reduce(data.run.calls, data, fn call, data ->
        id = Run.call_id(call)

        case Map.fetch(data.run.receipts, id) do
          {:ok, {:await, wait}} -> await_result(data, id, wait)
          {:ok, result} -> put_result(id, result, data)
          :error -> data
        end
      end)

    {:next_state, :executing_tools, %{data | run: %{data.run | receipts: %{}}},
     [{{:timeout, :worker_check}, 60_000, :check}, {:next_event, :internal, :tools}]}
  end

  defp await_result(data, id, wait) do
    pending = PendingCall.await(data.pending, id, wait)
    Presentation.waiting(data.run, data.pending[id].call, wait)
    %{data | pending: pending}
  end

  defp dispatch_tools(data) do
    data = dispatch_available(data)

    {data, actions} =
      if data.worker == :opening and is_nil(data.worker_wait_since),
        do: wait_for_worker(data, :starting),
        else: {data, []}

    cond do
      Enum.all?(data.run.calls, &Map.has_key?(data.run.results, Run.call_id(&1))) ->
        record(data)

      # Only a waiting tool needs observation. Other results arrive as messages.
      PendingCall.waits(data.pending) != [] ->
        {:keep_state, data, actions ++ [{:state_timeout, @poll_ms, :poll}]}

      true ->
        {:keep_state, data, actions}
    end
  end

  # A follow-up image can need a vision fallback request before the round is
  # recorded, so that round records in a task.
  defp record(%{run: %{follow_ups: []}} = data),
    do: task_result(:record, Run.record_round(data.run), :recording, data)

  defp record(data),
    do: {:next_state, :recording, task(data, :record, fn -> Run.record_round(data.run) end)}

  defp dispatch_available(data) do
    case PendingCall.next(data.pending, data.run.calls) do
      {:ok, call, active} ->
        case Tools.prepare(data.run, call) do
          {:error, result} -> dispatch_available(put_result(Run.call_id(call), result, data))
          {:ok, tool, args} -> dispatch_prepared(data, call, tool, args, active)
        end

      :none ->
        data
    end
  end

  defp dispatch_prepared(data, queued, tool, args, active) do
    sequential? = tool.execution_mode == "sequential"

    if PendingCall.blocked?(data.pending, sequential?, active) do
      data
    else
      id = Run.call_id(queued)
      previous = data.pending[id]

      pending =
        PendingCall.start(
          data.pending,
          id,
          queued,
          tool,
          args,
          previous.span || Observability.start_tool(data.run.span, queued),
          sequential?
        )

      data = %{data | pending: pending}

      if tool.executor != :worker,
        do: Presentation.activity(data.run, queued, tool, args, "running")

      data =
        if tool.executor == :worker or previous.worker_name,
          do: dispatch_worker(data, id),
          else: task(data, {:tool, id}, fn -> Tools.execute(data.run, queued, tool, args) end)

      if sequential? and not Map.has_key?(data.run.results, id),
        do: data,
        else: dispatch_available(data)
    end
  end

  defp accept_result(id, result, data),
    do: {:keep_state, put_result(id, result, data), [{:next_event, :internal, :tools}]}

  defp put_result(id, result, data) do
    case data.pending[id] do
      nil ->
        data

      pending ->
        Observability.finish_tool(pending.span, ToolResult.encode(result))

        if pending.tool && pending.tool.executor != :worker do
          phase = if result.is_error == true, do: "failed", else: "completed"
          Presentation.activity(data.run, pending.call, pending.tool, pending.args, phase, result)
        end

        Enum.each(result.presentation || [], fn event ->
          Presentation.event(data.run, event["kind"], event["payload"])
        end)

        {run, result} = Tools.attach(data.run, result)
        run = Machine.failure(run, pending.call, result)

        run = %{
          run
          | results: Map.put(run.results, id, result),
            visible_delivery?:
              run.visible_delivery? or
                Run.visible_delivery?(pending.call, result)
        }

        data = %{data | run: run, pending: Map.delete(data.pending, id)}

        if ToolResult.ends_turn?(result) do
          Enum.reduce(PendingCall.queued(data.pending), data, fn next_id, data ->
            put_result(next_id, Tools.error("An earlier tool ended this turn."), data)
          end)
        else
          data
        end
    end
  end

  defp observe_waits(%{observing?: true} = data),
    do: {:keep_state, data, [{:state_timeout, @poll_ms, :poll}]}

  defp observe_waits(data) do
    waits = PendingCall.waits(data.pending)

    if waits == [],
      do: {:keep_state, data},
      else:
        {:keep_state,
         task(%{data | observing?: true}, :observe, fn ->
           steered? =
             Enum.any?(
               Run.open_events(data.run),
               &(&1.id in data.run.pending_event_ids and
                   (&1.type == "command.steer" or
                      (String.starts_with?(&1.type, "im.message.") and
                         &1.type != "im.message.may_intervene")))
             )

           Enum.map(waits, fn {id, wait} -> {id, Tools.observe(data.run, wait, steered?)} end)
         end), [{:state_timeout, @poll_ms, :poll}]}
  end

  defp inject_pending(run) do
    with {:ok, injected, run} <- Run.inject_pending(run, fn _event -> true end),
         :ok <- Presentation.continue(run, injected),
         do: {:ok, run}
  end

  defp model_terminal(%{terminal_error: %{} = error}, data),
    do: failed(error, %{data | stream: nil})

  defp model_terminal(%{terminal_response: %{"id" => id}}, data) do
    task_result(
      :model_response,
      AIGateway.get_response(data.run.agent_uid, id),
      :requesting_model,
      data
    )
  end

  defp model_terminal(_outcome, data),
    do: failed(%{"code" => "model_stream_closed", "retryable" => true}, data)

  defp worker_result(type, payload, data)
       when type in [:workspace_ready, :tool_status, :tool_progress, :tool_result] do
    current? =
      type == :workspace_ready or
        (payload.response_id == Run.response_id(data.run.model_response) and
           Map.has_key?(data.pending, payload.call_id))

    if Worker.matches?(payload.run, data.run) and current?,
      do: apply_worker_event(Worker.decode(type, payload), data),
      else: :keep_state_and_data
  end

  defp worker_result(_type, _payload, _data), do: :keep_state_and_data

  defp apply_worker_event(:ignore, _data), do: :keep_state_and_data

  defp apply_worker_event(:ready, %{worker: %{row: _}} = data) do
    pending = PendingCall.ready(data.pending)

    {:keep_state,
     %{
       data
       | worker: %{data.worker | ready?: true},
         pending: pending,
         workspace_reply: :ready,
         worker_wait_since: nil,
         worker_wait_phase: nil
     }, [{{:timeout, :worker_acquire}, :cancel}, {:next_event, :internal, :tools}]}
  end

  defp apply_worker_event(:ready, data),
    do:
      {:keep_state,
       %{data | workspace_reply: :ready, worker_wait_since: nil, worker_wait_phase: nil},
       [{{:timeout, :worker_acquire}, :cancel}]}

  defp apply_worker_event({:waiting, reason} = reply, data) do
    phase = if reason == :CAPACITY, do: :capacity, else: :replacing
    {data, actions} = wait_for_worker(data, phase)
    {:keep_state, %{data | worker: :waiting, workspace_reply: reply}, actions}
  end

  defp apply_worker_event({:unavailable, reason} = reply, data),
    do:
      {:keep_state, %{data | worker: :waiting, workspace_reply: reply},
       [{:next_event, :internal, {:worker_unavailable, reason}}]}

  defp apply_worker_event({:unknown, id}, data) do
    case data.pending[id].mode do
      "execute" ->
        pending = PendingCall.unknown(data.pending, id)
        {:keep_state, open_worker(%{data | pending: pending}), [{:next_event, :internal, :tools}]}

      "probe" ->
        accept_result(id, Tools.interrupted(), data)
    end
  end

  defp apply_worker_event({:presentation, kind, value}, data) do
    Presentation.event(data.run, kind, value)
    :keep_state_and_data
  end

  defp apply_worker_event({:result, id, result, follow}, data),
    do:
      accept_worker_result(id, result, %{
        data
        | run: %{data.run | follow_ups: data.run.follow_ups ++ follow}
      })

  defp dispatch_worker(data, id) do
    data = %{data | pending: PendingCall.wait_worker(data.pending, id)}

    case data.worker do
      nil ->
        open_worker(data)

      %{row: row, ready?: true} ->
        {pending, entry} = PendingCall.to_worker(data.pending, id)

        task(%{data | pending: pending}, {:worker_send, id}, fn ->
          Worker.send_call(data.run, row, entry)
        end)

      {:unavailable, reason} ->
        fail_worker_waits(reason, data)

      _ ->
        data
    end
  end

  defp open_worker(data) do
    if data.worker_monitor, do: Process.demonitor(data.worker_monitor, [:flush])

    task(
      %{
        data
        | worker: :opening,
          worker_monitor: nil,
          workspace_reply: nil,
          workspace_opened?: true
      },
      :worker_open,
      fn -> Worker.open(data.run) end
    )
  end

  defp worker_opened(%{worker_changed?: true} = data, {:ok, row}) do
    data = %{data | worker_changed?: false}

    case Worker.check(data.run, row) do
      {:ok, :changed} -> {:keep_state, open_worker(data)}
      _ -> worker_opened(data, {:ok, row})
    end
  end

  defp worker_opened(%{worker_changed?: true} = data, {:wait, _phase}),
    do: {:keep_state, open_worker(%{data | worker_changed?: false})}

  defp worker_opened(data, {:ok, row}) do
    monitor =
      case Worker.connection(row) do
        {:ok, pid} -> Process.monitor(pid)
        _ -> nil
      end

    data = %{data | worker: %{row: row, ready?: false}, worker_monitor: monitor}

    case data.workspace_reply do
      nil -> {:keep_state, data}
      reply -> apply_worker_event(reply, data)
    end
  end

  defp worker_opened(data, {:wait, phase}) do
    AgentWorkers.request(data.run.agent_uid)
    {data, actions} = wait_for_worker(data, phase)
    {:keep_state, %{data | worker: :waiting, worker_changed?: false}, actions}
  end

  defp worker_opened(data, {:error, reason}) do
    if reason not in [:agent_not_active, :agent_worker_unavailable],
      do: AgentWorkers.request(data.run.agent_uid)

    {:keep_state, %{data | worker: :waiting, worker_changed?: false},
     [{:next_event, :internal, {:worker_unavailable, reason}}]}
  end

  defp wait_for_worker(data, phase) do
    Presentation.event(data.run, "turn.phase", %{
      "operation_id" => "turn",
      "state" => "working",
      "label_key" => "signals_gateway.reply.activity.#{worker_phase_key(phase)}"
    })

    actions =
      if is_nil(data.worker_wait_since),
        do: [{{:timeout, :worker_acquire}, @worker_acquire_ms, :expired}],
        else: []

    {%{
       data
       | worker_wait_since: data.worker_wait_since || System.monotonic_time(:millisecond),
         worker_wait_phase: phase
     }, actions}
  end

  defp worker_phase_key(:starting), do: "starting_computer"
  defp worker_phase_key(:resuming), do: "resuming_computer"
  defp worker_phase_key(:retrying), do: "computer_retrying"
  defp worker_phase_key(:replacing), do: "computer_replacing"
  defp worker_phase_key(:capacity), do: "computer_busy"
  defp worker_phase_key(:preparing), do: "computer_preparing"

  defp fail_worker_waits(reason, data) do
    data =
      Enum.reduce(PendingCall.waiting_worker(data.pending), data, fn id, data ->
        result =
          if data.pending[id].probe?,
            do: Tools.interrupted(),
            else: Tools.error(worker_error_text(reason))

        put_result(id, result, data)
      end)

    %{data | worker: {:unavailable, reason}, worker_wait_since: nil, worker_wait_phase: nil}
  end

  defp worker_error_text({:rejected, _}), do: worker_error_text(:worker_provider_missing)

  defp worker_error_text(:worker_provider_missing),
    do:
      "The Agent computer cannot start: its provider configuration was rejected. An administrator must fix it in the Console."

  defp worker_error_text({:timeout, :preparing}),
    do: "The Agent computer is being prepared for a new version. Try again in a few minutes."

  defp worker_error_text({:timeout, :capacity}),
    do: "The Agent computer is busy with other tasks. Try again shortly."

  defp worker_error_text({:timeout, _}),
    do: "The Agent computer did not become ready in time. Try again shortly."

  defp worker_error_text(:agent_not_active),
    do: "This Agent is disabled, so its computer is unavailable."

  defp worker_error_text(_), do: "The Agent computer is unavailable. Try again shortly."

  defp request_stream_worker(%{worker_requested?: true} = data, _events), do: data

  defp request_stream_worker(data, events) do
    needs_worker? =
      Enum.any?(events, fn
        %{"type" => "response.output_item.added", "item" => %{"type" => "function_call"} = call} ->
          Tools.needs_worker?(data.run, call)

        _event ->
          false
      end)

    if needs_worker? do
      AgentWorkers.request(data.run.agent_uid)
      %{data | worker_requested?: true}
    else
      data
    end
  end

  defp worker_changed(%{worker: nil} = data), do: data
  defp worker_changed(%{worker: {:unavailable, _}} = data), do: data
  defp worker_changed(%{worker: :opening} = data), do: %{data | worker_changed?: true}

  defp worker_changed(data) do
    pending = PendingCall.worker_changed(data.pending)

    open_worker(%{data | pending: pending})
  end

  defp check_worker(%{worker: :opening} = data), do: data

  defp check_worker(%{worker: %{row: row, ready?: ready?}} = data) do
    case Worker.check(data.run, row) do
      {:ok, :same} when ready? ->
        pending = PendingCall.worker_same(data.pending)

        %{data | pending: pending}

      {:ok, _} ->
        worker_changed(data)

      {:error, reason} ->
        Logger.warning("Worker observation failed; calls remain pending: #{inspect(reason)}")
        data
    end
  end

  defp check_worker(data), do: worker_changed(data)

  defp accept_worker_result(id, result, data) do
    case data.pending[id].continue do
      continue when is_function(continue, 2) and result.is_error != true ->
        {:keep_state, task(data, {:tool, id}, fn -> continue.(data.run, result) end)}

      _ ->
        accept_result(id, result, data)
    end
  end

  defp finalize(data, outcome, reason \\ nil) do
    run = %{data.run | outcome: outcome}

    task_result(:finalize, Run.finalize(run, outcome, reason), :finalizing, %{data | run: run})
  end

  defp close_and_rebuild(%{run: nil} = data), do: rebuild(data)

  defp close_and_rebuild(data) do
    if data.workspace_opened? do
      run = data.run

      Task.Supervisor.start_child(
        Ankole.Conversations.Tasks,
        Repo.bind_tenant(fn ->
          case Worker.close(run) do
            {:error, reason} -> Logger.warning("Workspace close failed: #{inspect(reason)}")
            _result -> :ok
          end
        end)
      )
    end

    rebuild(data)
  end

  defp rebuild(data) do
    if data.worker_monitor, do: Process.demonitor(data.worker_monitor, [:flush])

    {:next_state, :idle,
     %{
       clear_tasks(finish_trace(data, outcome: if(data.run, do: data.run.outcome, else: nil)))
       | run: nil,
         pending: %{},
         stream: nil,
         worker: nil,
         worker_monitor: nil,
         worker_changed?: false,
         worker_wait_since: nil,
         worker_wait_phase: nil,
         worker_requested?: false,
         workspace_opened?: false,
         event: nil,
         workspace_reply: nil
     },
     [
       {{:timeout, :worker_acquire}, :cancel},
       {{:timeout, :worker_check}, :cancel},
       {:next_event, :internal, :rebuild}
     ]}
  end

  defp failed(reason, data) when reason in [:stale_driver, :run_closed] do
    if data.run, do: Run.refund(data.run, :stale_driver)
    {:stop, :normal, data}
  end

  defp failed(reason, %{run: nil} = data), do: {:stop, {:admission_failed, reason}, data}

  defp failed(:actor_event_canceled, data) do
    event =
      Enum.find(Run.open_events(data.run), fn event ->
        event.type == "input.revised" and Revisions.immediate?(data.run, event)
      end)

    task_result(:withdrawal, event, :finalizing, data)
  end

  defp failed(:actor_event_context_canceled, data),
    do: finalize(cancel_current(data), "stopped", :actor_event_context_canceled)

  defp failed(reason, %{run: %{kind: :workflow_task}} = data) do
    error =
      if is_map(reason),
        do: reason,
        else: %{"code" => "workflow_task_turn_failed", "message" => inspect(reason)}

    data = cancel_current(data)

    task_result(:workflow_failure, Commands.workflow_error(data.run, error), :finalizing, data)
  end

  defp failed(reason, data)
       when reason in [
              :invalid_scheduled_reply,
              :schedule_silent_success_not_allowed,
              :turn_completion_has_no_user_visible_projection
            ] do
    failed(
      %{
        "code" => Atom.to_string(reason),
        "message" => "The model result did not satisfy the completion contract.",
        "retryable" => false
      },
      data
    )
  end

  defp failed(reason, data) do
    error =
      if is_map(reason),
        do: reason,
        else: %{
          "code" => "conversation_execution_error",
          "message" => inspect(reason),
          "retryable" => true
        }

    if error["retryable"] == true do
      Presentation.stop(data.run)
      if data.stream, do: AIGateway.cancel_response_stream(data.stream, "conversation_retry")
      data = data |> finish_trace(error_type: error["code"]) |> clear_tasks()

      case Run.defer_retry(data.run, error) do
        {:ok, event} ->
          delay =
            max(
              DateTime.diff(event.available_at, DateTime.utc_now(:microsecond), :millisecond),
              0
            )

          data = %{data | run: %{data.run | event: event}, event: event}
          {:next_state, :backing_off, data, [{:state_timeout, delay, :admit}]}

        {:error, reason} when reason in [:stale_driver, :run_closed] ->
          failed(reason, data)

        {:error, reason} ->
          {:stop, {:defer_retry_failed, reason}, data}
      end
    else
      task_result(:finalize, Run.finalize(data.run, "dead_letter", error), :finalizing, data)
    end
  end

  defp clear_tasks(data),
    do: %{
      clear_tasks(data, fn _kind -> true end)
      | stream: nil,
        early_stream: [],
        observing?: false
    }

  defp clear_tasks(data, discard?) do
    tasks =
      Enum.reduce(data.tasks, %{}, fn {ref, {kind, pid} = task}, retained ->
        if discard?.(kind) do
          Task.Supervisor.terminate_child(Ankole.Conversations.Tasks, pid)
          Process.demonitor(ref, [:flush])
          retained
        else
          Map.put(retained, ref, task)
        end
      end)

    %{data | tasks: tasks}
  end

  defp cancel_current(data) do
    if data.stream, do: AIGateway.cancel_response_stream(data.stream, "conversation_interrupted")

    case data.worker do
      %{row: row} ->
        ids = PendingCall.on_worker(data.pending)

        Task.Supervisor.start_child(
          Ankole.Conversations.Tasks,
          Ankole.Repo.bind_tenant(fn ->
            Worker.cancel(data.run, row, ids)
          end)
        )

      _ ->
        :ok
    end

    clear_tasks(data)
  end

  defp prepare(data, run) do
    run = start_trace(run)
    driver = self()

    {:next_state, :preparing,
     task(%{data | run: run}, :prepare, fn ->
       with {:ok, {state, prepared}} <- Model.prepare(run) do
         if state == :ambient_skip do
           {:ok, {state, prepared}}
         else
           Presentation.start(prepared, driver)
           {:ok, {state, prepared}}
         end
       end
     end)}
  end

  defp start_trace(%{span: nil} = run) do
    span = Observability.start_turn(run.event, run.spec)

    context =
      if span,
        do:
          Map.merge(run.spec.request_context, %{
            "traceparent" => span.traceparent,
            "observability_user_id" => span.user_id
          }),
        else: run.spec.request_context

    %{run | span: span, spec: Map.put(run.spec, :request_context, context)}
  end

  defp start_trace(run), do: run

  defp finish_trace(%{run: nil} = data, _opts), do: data

  defp finish_trace(data, opts) do
    Enum.each(data.pending, fn {_id, pending} ->
      Observability.finish_tool(pending.span, %{
        "is_error" => true,
        "failure_kind" => Keyword.get(opts, :error_type, "turn_ended")
      })
    end)

    Observability.finish_turn(data.run.span, opts)

    %{
      data
      | run: %{data.run | span: nil},
        pending: Map.new(data.pending, fn {id, pending} -> {id, Map.put(pending, :span, nil)} end)
    }
  end

  defp model_deadline(run) do
    timeout =
      get_in(run.spec.request_context, ["ai_agent", "inactivity_timeout_ms"]) ||
        Ankole.SignalsGateway.ActorRuntime.AgentConfig.default_inactivity_timeout_ms()

    [
      {{:timeout, :model_activity}, if(timeout > 0, do: timeout, else: :infinity),
       {run.epoch, run.iteration}}
    ]
  end

  @impl true
  def terminate(reason, state, data) do
    clear_tasks(data)
    if data.stream, do: AIGateway.cancel_response_stream(data.stream, "driver_stopped")

    if data.run && data.run.kind != :job && state not in [:backing_off, :deferred] &&
         (reason == :shutdown or match?({:shutdown, _}, reason)),
       do: Run.refund(data.run, :shutdown)

    if data.run, do: Presentation.stop(data.run)

    finish_trace(data,
      error_type:
        if(reason in [:normal, :shutdown], do: Atom.to_string(reason), else: inspect(reason))
    )

    :ok
  end
end
