defmodule Ankole.Sessions.Driver do
  @moduledoc """
  Serializes one Session across control-plane nodes and executes Turn commands.

  The global name selects the common-path writer. The workspace epoch rejects
  a writer that survives a partition. Tasks never contain recovery truth.
  """
  @behaviour :gen_statem

  defmodule State do
    @moduledoc false
    @enforce_keys [:turn]
    defstruct [
      :turn,
      :stream,
      :phase,
      :activity_conversation_id,
      activity_revision: 0,
      activity_state: "active",
      tasks: %{},
      tool_spans: %{},
      early_stream: []
    ]
  end

  alias Ankole.{AIGateway, AgentWorkers, Observability, Repo}
  alias Ankole.Sessions.{Activity, Admission, Commands, Model, Presentation, Run, Turn, Worker}
  alias Ankole.Sessions.{Queue, Revisions, ToolResult, Tools}
  alias Ankole.Sessions.Driver.Tasks
  alias Ankole.Signals.Signal

  @spec child_spec({map(), String.t()}) :: Supervisor.child_spec()
  def child_spec({key, _tenant_id} = args),
    do: %{id: {__MODULE__, key}, start: {__MODULE__, :start_link, [args]}, restart: :temporary}

  @spec start_link({map(), String.t()}) :: :gen_statem.start_ret()
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
    {:ok, :idle, %State{turn: %Turn{key: key}}, [{:next_event, :internal, :rebuild}]}
  end

  @impl true
  def handle_event({:call, from}, :activity_snapshot, _state, data),
    do: {:keep_state_and_data, [{:reply, from, Activity.project(data)}]}

  def handle_event(:internal, {:ai_gateway_response_stream, _, _, _, _} = event, state, data),
    do: handle_event(:info, event, state, data)

  def handle_event(type, event, _state, data) when type in [:internal, :state_timeout],
    do: dispatch(data, event)

  def handle_event({:timeout, :model_activity}, {epoch, iteration}, _state, data),
    do: dispatch(data, {:model_timeout, epoch, iteration})

  def handle_event({:timeout, name}, event, _state, data)
      when name in [:worker_acquire, :worker_check],
      do: dispatch(data, {:worker_timeout, event})

  def handle_event(:info, :reconcile_inbox, _state, data) do
    actions = Enum.map(Queue.due(data.turn.key), &{:next_event, :internal, {:inbox, &1.id}})
    {:keep_state, data, actions}
  end

  def handle_event(:info, {:inbox, _} = event, _state, data), do: dispatch(data, event)

  def handle_event(
        :info,
        {:worker_changed, uid},
        _state,
        %{turn: %{key: %{agent_uid: uid}}} = data
      ),
      do: dispatch(data, :worker_changed)

  def handle_event(:info, {:recover_preview, _id}, state, _data)
      when state in [:admitting, :preparing], do: {:keep_state_and_data, [:postpone]}

  def handle_event(:info, {:recover_preview, _id}, :finalizing, _data), do: :keep_state_and_data

  def handle_event(:info, {:recover_preview, id}, _state, %{
        turn: %{run: %Run{signal_id: id} = run}
      }) do
    Presentation.start(run, self())
    :keep_state_and_data
  end

  def handle_event(:info, {:worker, _, _} = event, _state, data), do: dispatch(data, event)

  def handle_event(
        :info,
        {:ai_gateway_response_stream, _ref, :events, events, _status} = message,
        :requesting_model,
        %{stream: nil} = data
      ) do
    data = %{data | early_stream: [message | data.early_stream]}
    dispatch(data, {:model_events, events})
  end

  def handle_event(
        :info,
        {:ai_gateway_response_stream, ref, :events, events, status},
        :requesting_model,
        %{stream: %{ref: ref}} = data
      ) do
    {data, actions} = advance(data, {:model_events, events})

    case status do
      :continue ->
        AIGateway.read_response_stream(data.stream)
        transition({data, actions ++ Model.inactivity_deadline(data.turn.run)})

      {:terminal, outcome} ->
        transition(advance(%{data | stream: nil}, {:model_closed, outcome}), actions)
    end
  end

  def handle_event(:info, {ref, result}, _state, data) when is_reference(ref) do
    case Map.pop(data.tasks, ref) do
      {nil, _} ->
        :keep_state_and_data

      {{kind, _pid}, tasks} ->
        Process.demonitor(ref, [:flush])
        transition(complete(%{data | tasks: tasks}, kind, result))
    end
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, data) do
    case Map.pop(data.tasks, ref) do
      {nil, _} ->
        :keep_state_and_data

      {{kind, _pid}, tasks} ->
        transition(complete(%{data | tasks: tasks}, kind, {:error, {:task_exit, reason}}))
    end
  end

  def handle_event(:info, {:EXIT, _pid, :shutdown}, _state, data), do: {:stop, :shutdown, data}
  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  defp dispatch(data, event), do: transition(advance(data, event))

  defp transition(result, actions \\ [])
  defp transition({:stop, _, _} = stopped, _actions), do: stopped

  defp transition({data, more}, actions),
    do: {:next_state, data.turn.stage, data, actions ++ more}

  defp advance(data, event) do
    {turn, commands} = Turn.step(data.turn, event)
    execute(commands, %{data | turn: turn}, [])
  end

  defp execute([], data, actions), do: {data, actions}
  defp execute([{:stop, reason} | _], data, _actions), do: {:stop, reason, data}

  defp execute([command | commands], data, actions) do
    case execute(command, data) do
      {:stop, _, _} = stopped -> stopped
      {data, more} -> execute(commands, data, actions ++ more)
    end
  end

  # Stream handles and monitor references stay in the process adapter.
  defp complete(data, :model, {:ok, stream, _meta}) do
    :ok = AIGateway.read_response_stream(stream)
    actions = Enum.map(Enum.reverse(data.early_stream), &{:next_event, :internal, &1})
    {%{data | stream: stream, early_stream: []}, actions}
  end

  defp complete(data, kind, result), do: advance(data, {:completed, kind, result})

  defp execute(:rebuild, data), do: complete(data, :rebuild, Run.rebuild(data.turn.key))

  defp execute(:classify_input, data), do: complete(data, :input_kind, Run.kind(data.turn.event))

  defp execute(:admit, data),
    do: complete(data, :admit, Admission.admit(data.turn.key, data.turn.event))

  defp execute(:ambient_triage, data),
    do:
      {Tasks.task(data, :ambient_triage, fn ->
         Ankole.Sessions.AmbientTriage.run(data.turn.key, data.turn.event)
       end), []}

  defp execute({:control, event}, data),
    do: {Tasks.task(data, :control, fn -> Commands.process(data.turn.key, event) end), []}

  defp execute({:interrupt, event}, data),
    do: complete(data, :control, Commands.interrupt(data.turn.run, event))

  defp execute({:retry_action, event}, data),
    do: complete(data, {:retry_action, event}, Commands.retry_action(data.turn.run, event))

  defp execute(:prepare, data) do
    run = Observability.attach_turn(data.turn.run)

    data = %{
      data
      | turn: %{data.turn | run: run},
        phase: nil,
        activity_revision: 0,
        activity_state: "active",
        activity_conversation_id: Activity.native_source(run)
    }

    driver = self()

    {Tasks.task(data, :prepare, fn ->
       with {:ok, {stage, prepared}} <- Model.prepare(run) do
         Presentation.start(prepared, driver)
         {:ok, {stage, prepared}}
       end
     end), []}
  end

  defp execute(:open_model, data) do
    receiver = self()
    run = data.turn.run

    {Tasks.task(%{data | stream: nil, early_stream: []}, :model, fn ->
       Model.open(run, receiver)
     end), Model.inactivity_deadline(run)}
  end

  defp execute({:read_model_response, id}, data),
    do: complete(data, :model_response, AIGateway.get_response(data.turn.run.agent_uid, id))

  defp execute(:record, %{turn: %{run: %{follow_ups: []} = run}} = data),
    do: complete(data, :record, Run.record_round(run))

  # An image follow-up can require a vision request before the transaction.
  defp execute(:record, data),
    do: {Tasks.task(data, :record, fn -> Run.record_round(data.turn.run) end), []}

  defp execute(:inject_pending, data) do
    result =
      with {:ok, injected, run} <- Run.inject_pending(data.turn.run, fn _ -> true end),
           :ok <- Presentation.continue(run, injected),
           do: {:ok, run}

    complete(data, :boundary, result)
  end

  defp execute({:finalize, outcome, reason}, data),
    do: {Tasks.task(data, :finalize, fn -> Run.finalize(data.turn.run, outcome, reason) end), []}

  defp execute({:workflow_failure, failure}, data),
    do: complete(data, :workflow_failure, Commands.workflow_failure(data.turn.run, failure))

  defp execute({:workflow_error, error}, data),
    do: complete(data, :workflow_failure, Commands.workflow_error(data.turn.run, error))

  defp execute({:defer_retry, error}, data),
    do: complete(data, :defer_retry, Run.defer_retry(data.turn.run, error))

  defp execute({:read_inbox, id}, data) do
    event =
      Repo.get_by(Signal,
        id: id,
        agent_uid: data.turn.key.agent_uid,
        session_id: data.turn.key.session_id
      )

    event =
      case event do
        %Signal{status: status} when status in [:queued, :running] ->
          case Admission.authorize_event(event) do
            {:ok, authorized} -> authorized
            {:error, _} -> nil
          end

        _ ->
          event
      end

    complete(data, {:inbox, id}, event)
  end

  defp execute(:read_withdrawal, data) do
    event =
      Enum.find(Queue.due(data.turn.run), fn event ->
        event.type == "input.revised" and Revisions.immediate?(data.turn.run, event)
      end)

    complete(data, :withdrawal, event)
  end

  defp execute(:observe, data),
    do:
      {Tasks.task(data, :observe, fn ->
         Tools.observe_pending(data.turn.run, data.turn.pending)
       end), []}

  defp execute({:tool, run, entry}, data),
    do:
      {Tasks.task(data, {:tool, Run.call_id(entry.call)}, fn ->
         Tools.execute(run, entry.call, entry.tool, entry.args)
       end), []}

  defp execute({:continue_tool, id, continue, result}, data),
    do: {Tasks.task(data, {:tool, id}, fn -> continue.(data.turn.run, result) end), []}

  defp execute(:request_worker, data) do
    AgentWorkers.request(data.turn.run.agent_uid)
    {data, []}
  end

  defp execute(:resolve_worker, data),
    do: {Tasks.task(data, :worker_resolve, fn -> Worker.prepare_open(data.turn.run) end), []}

  defp execute({:open_worker, row, message}, data),
    do: {Tasks.task(data, :worker_open, fn -> Worker.send_open(row, message) end), []}

  defp execute({:check_worker, row}, data),
    do: {Tasks.task(data, :worker_check, fn -> Worker.check(data.turn.run, row) end), []}

  defp execute({:send_tool, run, row, entry}, data),
    do:
      {Tasks.task(data, {:worker_send, Run.call_id(entry.call)}, fn ->
         Worker.send_call(run, row, entry)
       end), []}

  defp execute(:read_worker_sends, data) do
    ids = for {_, {{:worker_send, id}, _}} <- data.tasks, do: id
    advance(data, {:worker_sends, ids})
  end

  defp execute({:decode_worker, type, payload}, data) do
    event =
      case Worker.decode(type, payload) do
        {:presentation, "tool.activity", value} ->
          {:presentation, "tool.activity", Map.put(value, "operation_id", payload.call_id)}

        decoded ->
          decoded
      end

    complete(data, :worker, event)
  end

  defp execute({:close_worker, run}, data) do
    Task.Supervisor.start_child(
      Ankole.Sessions.Tasks,
      Repo.bind_tenant(fn ->
        case Worker.close(run) do
          {:error, reason} ->
            Ankole.Logging.warning(
              "sessions.workspace.close_failed",
              "Workspace close failed",
              Map.merge(Ankole.Logging.failure_fields(:error, reason, []), %{
                agent_uid: run.agent_uid,
                session_id: run.session_id
              })
            )

          _ ->
            :ok
        end
      end)
    )

    {data, []}
  end

  defp execute(:cancel_worker_queries, data),
    do: {Tasks.clear_tasks(data, &(&1 in [:worker_resolve, :worker_check])), []}

  defp execute(:cancel_round_tasks, data),
    do:
      {Tasks.clear_tasks(data, fn kind ->
         kind in [:worker_resolve, :worker_open, :worker_check, :observe] or
           match?({:worker_send, _}, kind)
       end), []}

  defp execute(:cancel_current, data),
    do: {data |> Tasks.cancel_current() |> finish_spans(error_type: "turn_interrupted"), []}

  defp execute(:clear_tasks, data), do: {Tasks.clear_tasks(data), []}

  defp execute({:cancel_stream, reason}, data) do
    if data.stream, do: AIGateway.cancel_response_stream(data.stream, reason)
    {data, []}
  end

  defp execute({:present, events}, data),
    do:
      {Enum.reduce(events, data, fn event, data ->
         Activity.present(
           data,
           Presentation.event(data.turn.run, event["kind"], event["payload"])
         )
       end), []}

  defp execute(:clear_phase, data), do: {%{data | phase: nil}, []}
  defp execute(:publish_activity, data), do: {Activity.publish(data), []}

  defp execute({:start_tool, call}, data) do
    id = Run.call_id(call)

    spans =
      Map.put_new_lazy(data.tool_spans, id, fn ->
        Observability.start_tool(data.turn.run.span, call)
      end)

    {%{data | tool_spans: spans}, []}
  end

  defp execute({:finish_tool, id, result}, data) do
    {span, spans} = Map.pop(data.tool_spans, id)
    Observability.finish_tool(span, ToolResult.encode(result))
    {%{data | tool_spans: spans}, []}
  end

  defp execute({:settle, previous}, data) do
    cleared = Activity.clear(%{data | turn: previous}, "settled")
    cleared = finish_spans(cleared, outcome: if(previous.run, do: previous.run.outcome))
    {%{cleared | turn: data.turn, phase: nil}, []}
  end

  defp execute({:retry_cleanup, error}, data) do
    data = Activity.clear(data, "unavailable")
    Presentation.stop(data.turn.run)
    if data.stream, do: AIGateway.cancel_response_stream(data.stream, "conversation_retry")
    {data |> finish_spans(error_type: error["code"]) |> Tasks.clear_tasks(), []}
  end

  defp execute({:refund, reason}, data) do
    if data.turn.run, do: Run.refund(data.turn.run, reason)
    {data, []}
  end

  defp execute({:log_failure, error}, data) do
    Ankole.Logging.warning(
      "sessions.execution_failed",
      "Session execution failed",
      Map.take(error, ~w(code type http_status retryable))
    )

    {data, []}
  end

  defp execute({:next, event}, data), do: {data, [{:next_event, :internal, event}]}
  defp execute(:postpone, data), do: {data, [:postpone]}
  defp execute({:wait, ms, event}, data), do: {data, [{:state_timeout, ms, event}]}

  defp execute({:wait_until, deadline, event}, data),
    do:
      execute(
        {:wait, max(DateTime.diff(deadline, DateTime.utc_now(:microsecond), :millisecond), 0),
         event},
        data
      )

  defp execute({:worker_timer, :acquire, :cancel}, data),
    do: {data, [{{:timeout, :worker_acquire}, :cancel}]}

  defp execute({:worker_timer, :check, :cancel}, data),
    do: {data, [{{:timeout, :worker_check}, :cancel}]}

  defp execute({:worker_timer, :acquire, ms}, data),
    do: {data, [{{:timeout, :worker_acquire}, ms, :expired}]}

  defp execute({:worker_timer, :check, ms}, data),
    do: {data, [{{:timeout, :worker_check}, ms, :check}]}

  defp finish_spans(%{turn: %{run: nil}} = data, _opts), do: data

  defp finish_spans(data, opts) do
    Enum.each(data.tool_spans, fn {_, span} ->
      Observability.finish_tool(span, %{
        "is_error" => true,
        "failure_kind" => Keyword.get(opts, :error_type, "turn_ended")
      })
    end)

    Observability.finish_turn(data.turn.run.span, opts)
    %{data | tool_spans: %{}, turn: %{data.turn | run: %{data.turn.run | span: nil}}}
  end

  @impl true
  def terminate(reason, state, data) do
    Activity.clear(data, "unavailable")
    Tasks.clear_tasks(data)
    if data.stream, do: AIGateway.cancel_response_stream(data.stream, "driver_stopped")
    run = data.turn.run

    if run && state not in [:backing_off, :deferred] &&
         (reason == :shutdown or match?({:shutdown, _}, reason)),
       do: Run.refund(run, :shutdown)

    if run, do: Presentation.stop(run)

    finish_spans(data,
      error_type:
        if(reason in [:normal, :shutdown], do: Atom.to_string(reason), else: inspect(reason))
    )

    :ok
  end
end
