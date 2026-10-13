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
      tasks: %{},
      pending: %{},
      early_stream: [],
      observing?: false,
      acquisition: :idle
    ]

    @type t :: %__MODULE__{}
  end

  alias Ankole.AIGateway
  alias Ankole.Observability

  alias Ankole.Conversations.{
    Admission,
    Commands,
    Machine,
    Model,
    Presentation,
    Run,
    Revisions,
    ToolRound,
    ToolResult,
    Tools,
    Worker,
    WorkerAcquisition,
    PendingCall
  }

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers
  alias Ankole.Repo

  @idle_ms :timer.minutes(5)
  @poll_ms 1_000
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
     end), Model.inactivity_deadline(run)}
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
    # A query that started before this change can still return the old row.
    data = clear_tasks(data, &(&1 in [:worker_resolve, :worker_check]))
    acquisition_event(data, :check)
  end

  def handle_event({:timeout, :worker_check}, :check, :executing_tools, data),
    do: acquisition_event(data, :check)

  def handle_event({:timeout, :worker_acquire}, :expired, :executing_tools, data),
    do: acquisition_event(data, :expired)

  def handle_event(:info, {:recover_preview, _id}, state, _data)
      when state in [:admitting, :preparing],
      do: {:keep_state_and_data, [:postpone]}

  def handle_event(:info, {:recover_preview, id}, _state, %{
        run: %Run{actor_event_id: id} = run
      }) do
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
        {:keep_state, data, Model.inactivity_deadline(data.run)}

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
    if (kind in [:worker_resolve, :worker_check, :worker_open] or match?({:worker_send, _}, kind)) and
         Enum.any?(data.tasks, fn {_ref, {active, _pid}} -> active == kind end) do
      data
    else
      task =
        Task.Supervisor.async_nolink(Ankole.Conversations.Tasks, Ankole.Repo.bind_tenant(fun))

      %{data | tasks: Map.put(data.tasks, task.ref, {kind, task.pid})}
    end
  end

  defp task_result(:rebuild, {:ok, :idle}, _state, data),
    do:
      {:next_state, :idle, %{data | run: nil, event: nil}, [{:state_timeout, @idle_ms, :retire}]}

  defp task_result(:rebuild, {:ok, %{event: event, delay_ms: delay}}, _state, data) do
    case Commands.route(event) do
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
    do: finalize(%{data | run: run}, :silent)

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
        kind in [:worker_resolve, :worker_open, :worker_check, :observe] or
          match?({:worker_send, _}, kind)
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

  defp task_result(kind, {:error, reason}, _state, data)
       when kind in [:worker_resolve, :worker_open] and reason in [:stale_driver, :run_closed],
       do: failed(reason, data)

  defp task_result(:worker_resolve, result, :executing_tools, data),
    do: acquisition_event(data, {:resolved, result})

  defp task_result(:worker_open, result, :executing_tools, data),
    do: acquisition_event(data, {:sent, result})

  defp task_result(:worker_check, result, :executing_tools, data),
    do: acquisition_event(data, {:checked, result})

  defp task_result({:worker_send, id}, {:error, _reason}, :executing_tools, data) do
    data = %{data | pending: PendingCall.send_failed(data.pending, id)}
    acquisition_event(data, :send_failed)
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

  defp task_result(:workflow_failure, {:ok, _}, _state, data), do: finalize(data, :submitted)

  defp task_result(:withdrawal, %ActorEvent{} = event, _state, data) do
    data = cancel_current(data)

    task_result(:control, Commands.interrupt(data.run, event), :finalizing, data)
  end

  defp task_result(:withdrawal, nil, _state, data), do: finalize(cancel_current(data), :stopped)

  defp task_result(_kind, {:error, reason}, _state, data), do: failed(reason, data)

  defp enter_tools(data) do
    {run, pending} = ToolRound.restore(data.run)
    data = %{data | run: run, pending: pending}

    {:next_state, :executing_tools, data,
     worker_timers(data) ++ [{:next_event, :internal, :tools}]}
  end

  defp await_result(data, id, wait),
    do: %{data | pending: ToolRound.await(data.run, data.pending, id, wait)}

  defp dispatch_tools(data) do
    data = dispatch_available(data)

    actions = worker_timers(data)

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
    case ToolRound.next(data.run, data.pending) do
      {:result, id, result} ->
        dispatch_available(put_result(id, result, data))

      {:execute, entry, pending} ->
        id = Run.call_id(entry.call)
        data = %{data | pending: pending}

        data =
          if entry.tool.executor == :worker or entry.worker_name,
            do: dispatch_worker(data, id),
            else:
              task(data, {:tool, id}, fn ->
                Tools.execute(data.run, entry.call, entry.tool, entry.args)
              end)

        if entry.sequential? and not Map.has_key?(data.run.results, id),
          do: data,
          else: dispatch_available(data)

      :none ->
        data
    end
  end

  defp accept_result(id, result, data),
    do: {:keep_state, put_result(id, result, data), [{:next_event, :internal, :tools}]}

  defp put_result(id, result, data) do
    {run, pending} = ToolRound.accept(data.run, data.pending, id, result)
    %{data | run: run, pending: pending}
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
           ToolRound.observe(data.run, data.pending)
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

  defp apply_worker_event(:ready, data), do: acquisition_event(data, :ready)

  defp apply_worker_event({:waiting, reason}, data),
    do: acquisition_event(data, {:waiting, reason})

  defp apply_worker_event({:unavailable, reason}, data),
    do: acquisition_event(data, {:unavailable, reason})

  defp apply_worker_event({:unknown, id}, data) do
    case data.pending[id].mode do
      "execute" ->
        pending = PendingCall.unknown(data.pending, id)

        {:keep_state, transition_worker(%{data | pending: pending}, :send_failed),
         [{:next_event, :internal, :tools}]}

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

    case data.acquisition do
      {:ready, row} ->
        {pending, entry} = PendingCall.to_worker(data.pending, id)

        task(%{data | pending: pending}, {:worker_send, id}, fn ->
          Worker.send_call(data.run, row, entry)
        end)

      {:unavailable, reason} ->
        fail_worker_waits(reason, data)

      _ ->
        transition_worker(data, :acquire)
    end
  end

  defp acquisition_event(data, event) do
    data = transition_worker(data, event)
    {:keep_state, data, worker_timers(data) ++ [{:next_event, :internal, :tools}]}
  end

  defp transition_worker(data, event) do
    {state, effects} = WorkerAcquisition.next(data.acquisition, event)
    Enum.reduce(effects, %{data | acquisition: state}, &worker_effect/2)
  end

  defp worker_effect(:request, data) do
    AgentWorkers.request(data.run.agent_uid)
    data
  end

  defp worker_effect(:resolve, data),
    do: task(data, :worker_resolve, fn -> Worker.prepare_open(data.run) end)

  defp worker_effect({:send_open, row, message}, data),
    do: task(data, :worker_open, fn -> Worker.send_open(row, message) end)

  defp worker_effect({:check, row}, data),
    do: task(data, :worker_check, fn -> Worker.check(data.run, row) end)

  defp worker_effect(:ready, data), do: %{data | pending: PendingCall.ready(data.pending)}

  defp worker_effect(:retry_calls, data),
    do: %{data | pending: PendingCall.worker_changed(data.pending)}

  defp worker_effect(:probe, data) do
    sending = for {_, {{:worker_send, id}, _}} <- data.tasks, do: id
    %{data | pending: PendingCall.worker_same(data.pending, sending)}
  end

  defp worker_effect({:unavailable, reason}, data), do: fail_worker_waits(reason, data)

  defp worker_effect({:phase, phase}, data) do
    Presentation.event(data.run, "turn.phase", %{
      "operation_id" => "turn",
      "state" => "working",
      "label_key" => "signals_gateway.reply.activity.#{WorkerAcquisition.phase_key(phase)}"
    })

    data
  end

  defp worker_timers(data) do
    Enum.map(WorkerAcquisition.timers(data.acquisition, System.monotonic_time(:millisecond)), fn
      {:acquire, :cancel} -> {{:timeout, :worker_acquire}, :cancel}
      {:check, :cancel} -> {{:timeout, :worker_check}, :cancel}
      {:acquire, ms} -> {{:timeout, :worker_acquire}, ms, :expired}
      {:check, ms} -> {{:timeout, :worker_check}, ms, :check}
    end)
  end

  defp fail_worker_waits(reason, data) do
    Enum.reduce(PendingCall.waiting_worker(data.pending), data, fn id, data ->
      result =
        if data.pending[id].probe?,
          do: Tools.interrupted(),
          else: Tools.error(WorkerAcquisition.error_text(reason))

      put_result(id, result, data)
    end)
  end

  defp request_stream_worker(data, events) do
    needs_worker? =
      Enum.any?(events, fn
        %{"type" => "response.output_item.added", "item" => %{"type" => "function_call"} = call} ->
          Tools.needs_worker?(data.run, call)

        _ ->
          false
      end)

    if needs_worker?, do: transition_worker(data, :request), else: data
  end

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
    if data.acquisition != :idle do
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
    {:next_state, :idle,
     %{
       clear_tasks(
         ToolRound.finish_spans(data, outcome: if(data.run, do: data.run.outcome, else: nil))
       )
       | run: nil,
         pending: %{},
         stream: nil,
         acquisition: :idle,
         event: nil
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
    do: finalize(cancel_current(data), :stopped, :actor_event_context_canceled)

  defp failed(reason, data) do
    case Run.type(data.run).failure(reason) do
      {:workflow_failure, error} ->
        data = cancel_current(data)

        task_result(
          :workflow_failure,
          Commands.workflow_error(data.run, error),
          :finalizing,
          data
        )

      {:execution_error, error} ->
        failed_execution(error, data)
    end
  end

  defp failed_execution(error, data) do
    if error["retryable"] == true do
      Presentation.stop(data.run)
      if data.stream, do: AIGateway.cancel_response_stream(data.stream, "conversation_retry")
      data = data |> ToolRound.finish_spans(error_type: error["code"]) |> clear_tasks()

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
      task_result(:finalize, Run.finalize(data.run, :dead_letter, error), :finalizing, data)
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

    case WorkerAcquisition.row(data.acquisition) do
      row when is_map(row) ->
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
    run = Observability.attach_turn(run)
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

  @impl true
  def terminate(reason, state, data) do
    clear_tasks(data)
    if data.stream, do: AIGateway.cancel_response_stream(data.stream, "driver_stopped")

    if data.run && state not in [:backing_off, :deferred] &&
         (reason == :shutdown or match?({:shutdown, _}, reason)),
       do: Run.refund(data.run, :shutdown)

    if data.run, do: Presentation.stop(data.run)

    ToolRound.finish_spans(data,
      error_type:
        if(reason in [:normal, :shutdown], do: Atom.to_string(reason), else: inspect(reason))
    )

    :ok
  end
end
