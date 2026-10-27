defmodule Ankole.Sessions.Turn do
  @moduledoc """
  Advances one Session from domain events and completed operations.

  `step/2` returns the next state and ordered commands for the Driver. It does
  not start processes or commit domain writes. A command that writes durable
  state must return its result before the Turn can continue past that boundary.
  All state here can be rebuilt from the existing Run, round and receipt owners.
  """

  alias Ankole.Sessions.{Commands, PendingCall, Presentation, Revisions, Run}
  alias Ankole.Sessions.{ToolArguments, ToolCatalog, ToolResult, Tools, Worker, WorkerAcquisition}
  alias Ankole.Signals.Signal

  @enforce_keys [:key]
  defstruct [
    :key,
    :run,
    :event,
    stage: :idle,
    pending: %{},
    observing?: false,
    acquisition: :idle,
    workspace_open_attempted?: false
  ]

  @type t :: %__MODULE__{}
  @idle_ms :timer.minutes(5)
  @poll_ms 1_000

  @synthesis "You've reached the maximum number of tool-calling iterations allowed. Please provide a final response summarizing what you've found and accomplished so far, without calling any more tools."
  @nudge "You just executed tool calls but returned an empty response. Please process the tool results above and continue with the task."
  @truncated "Your last response reached the output token limit before its tool calls were complete, so none of them ran. Call the tools again with complete arguments, and split large content into smaller calls."
  @volatile ~w(idempotency_key nonce request_id timestamp tool_call_id uuid)

  @doc "The optional clock is monotonic milliseconds, used for Worker acquisition."
  def step(turn, event, now \\ System.monotonic_time(:millisecond))

  def step(turn, {:completed, kind, result}, now), do: complete(turn, kind, result, now)
  def step(turn, :rebuild, _now), do: {turn, [:rebuild]}

  def step(turn, :admit, _now), do: {%{turn | stage: :admitting}, [:classify_input]}

  def step(%{stage: stage} = turn, :request, _now)
      when stage in [:boundary, :requesting_model] do
    run = %{turn.run | iteration: turn.run.iteration + 1}
    {%{turn | stage: :requesting_model, run: run}, [phase("turn_understanding"), :open_model]}
  end

  def step(%{stage: :boundary, run: %{epoch: epoch}} = turn, {:resume, epoch, stage}, now) do
    case stage do
      :preparing -> step(turn, :request, now)
      :executing_tools -> enter_tools(turn, now)
      :boundary -> {turn, [{:next, :boundary}]}
    end
  end

  def step(%{stage: :boundary} = turn, :boundary, _now), do: {turn, [:inject_pending]}
  def step(%{stage: :executing_tools} = turn, :tools, now), do: dispatch_tools(turn, now)
  def step(%{stage: :executing_tools} = turn, :poll, _now), do: observe_waits(turn)
  def step(%{stage: :idle} = turn, :retire, _now), do: {turn, [{:stop, :normal}]}

  def step(%{stage: stage} = turn, {:inbox, _id}, _now)
      when stage in [:admitting, :preparing, :recording, :finalizing],
      do: {turn, [:postpone]}

  def step(%{stage: :idle} = turn, {:inbox, _id}, _now),
    do: {turn, [{:next, :rebuild}]}

  def step(turn, {:inbox, id}, _now), do: {turn, [{:read_inbox, id}]}

  def step(%{stage: :executing_tools} = turn, :worker_changed, now) do
    {turn, commands} = acquisition_event(turn, :check, now)
    {turn, [:cancel_worker_queries | commands]}
  end

  def step(%{stage: :executing_tools} = turn, {:worker_timeout, event}, now),
    do: acquisition_event(turn, event, now)

  def step(%{stage: :executing_tools} = turn, {:worker_sends, ids}, _now),
    do: {%{turn | pending: PendingCall.worker_same(turn.pending, ids)}, []}

  def step(%{stage: :executing_tools} = turn, {:worker, type, payload}, _now)
      when type in [:workspace_ready, :tool_status, :tool_progress, :tool_result] do
    current? =
      type == :workspace_ready or
        (payload.response_id == Run.response_id(turn.run.model_response) and
           Map.has_key?(turn.pending, payload.call_id))

    if Worker.matches?(payload.run, turn.run) and current? do
      {turn, [{:decode_worker, type, payload}]}
    else
      {turn, []}
    end
  end

  def step(%{stage: :requesting_model} = turn, {:model_events, events}, now) do
    needs_worker? =
      Enum.any?(events, fn
        %{"type" => "response.output_item.added", "item" => %{"type" => "function_call"} = call} ->
          Tools.needs_worker?(turn.run, call)

        _ ->
          false
      end)

    if needs_worker?, do: transition_worker(turn, :request, now), else: {turn, []}
  end

  def step(turn, {:model_closed, %{terminal_error: %{} = error}}, now),
    do: failed(turn, error, now)

  def step(turn, {:model_closed, %{terminal_response: %{"id" => id}}}, _now),
    do: {turn, [{:read_model_response, id}]}

  def step(turn, {:model_closed, _outcome}, now),
    do: failed(turn, %{"code" => "model_stream_closed", "retryable" => true}, now)

  def step(
        %{stage: :requesting_model, run: %{epoch: epoch, iteration: iteration}} = turn,
        {:model_timeout, epoch, iteration},
        now
      ) do
    {turn, commands} =
      failed(
        turn,
        %{
          "code" => "model_inactivity_timeout",
          "message" => "The model stopped sending events.",
          "retryable" => true
        },
        now
      )

    {turn, [{:cancel_stream, "model_inactivity_timeout"} | commands]}
  end

  def step(turn, _late_event, _now), do: {turn, []}

  @doc "Folds the same tool failure policy during execution and committed-history replay."
  def track_failure(run, call, result) do
    if result.is_error do
      args = call["arguments"] || call["input"]

      args =
        case Ankole.JSON.decode(args || "") do
          {:ok, v} -> v
          _ -> args
        end

      key =
        {ToolCatalog.namespace(call["namespace"]), call["name"], result.failure_kind, scrub(args)}

      count =
        case run.repeated_failure do
          {^key, n} -> n + 1
          _ -> 1
        end

      run = %{run | repeated_failure: {key, count}}

      if count == 2,
        do: %{run | follow_ups: run.follow_ups ++ [Run.user(warning(call["name"], count))]},
        else: run
    else
      %{run | repeated_failure: nil}
    end
  end

  defp complete(turn, _kind, {:error, reason}, now)
       when reason in [:stale_driver, :run_closed],
       do: failed(turn, reason, now)

  defp complete(turn, :rebuild, {:ok, :idle}, _now),
    do: {%{turn | stage: :idle, run: nil, event: nil}, [{:wait, @idle_ms, :retire}]}

  defp complete(turn, :rebuild, {:ok, %{event: event, delay_ms: delay}}, _now) do
    turn = %{turn | event: event}

    case Commands.route(event) do
      :control -> {%{turn | stage: :admitting}, [{:control, event}]}
      :run when delay > 0 -> {%{turn | stage: :backing_off}, [{:wait, delay, :admit}]}
      :run -> {%{turn | stage: :admitting}, [{:next, :admit}]}
    end
  end

  defp complete(turn, :ambient_triage, {:ok, :intervene, event}, _now),
    do: {%{turn | event: event}, [:admit]}

  defp complete(turn, :ambient_triage, {:ok, :settled}, _now), do: rebuild(turn)

  defp complete(turn, :ambient_triage, {:ok, :deferred, event}, now),
    do: complete(turn, :admit, {:ok, %{status: :deferred, signal: event}}, now)

  defp complete(turn, :ambient_triage, {:error, _reason} = error, now),
    do: complete(turn, :admit, error, now)

  defp complete(turn, :input_kind, :ambient, _now), do: {turn, [:ambient_triage]}
  defp complete(turn, :input_kind, _kind, _now), do: {turn, [:admit]}

  defp complete(%{stage: :backing_off} = turn, :control, {:ok, %Run{} = run}, _now),
    do:
      {%{turn | run: nil, event: run.event, pending: %{}},
       [{:wait_until, run.event.available_at, :admit}]}

  defp complete(turn, :control, {:ok, %Run{} = run}, _now), do: prepare(turn, run)
  defp complete(turn, :control, {:ok, _}, _now), do: close_and_rebuild(turn)

  defp complete(turn, {:retry_action, event}, {:ok, :interrupt}, _now),
    do: interrupt(turn, event)

  defp complete(turn, {:retry_action, _}, {:ok, :continue}, _now), do: {turn, []}
  defp complete(turn, :admit, {:ok, %Run{} = run}, _now), do: prepare(turn, run)

  defp complete(%{run: %Run{}} = turn, :admit, {:ok, %{status: :deferred}}, _now),
    do: close_and_rebuild(turn)

  defp complete(turn, :admit, {:ok, %{status: :deferred, signal: event}}, _now),
    do: {%{turn | stage: :deferred, event: event}, [{:wait_until, event.available_at, :admit}]}

  defp complete(turn, :admit, {:ok, _terminal}, _now), do: rebuild(turn)

  defp complete(turn, :admit, {:error, reason}, _now)
       when reason in [:agent_not_active, :workflow_agent_at_capacity],
       do: {%{turn | stage: :deferred}, [{:wait, 30_000, :admit}]}

  defp complete(turn, :admit, {:error, :input_unavailable}, _now), do: close_and_rebuild(turn)

  defp complete(turn, :prepare, {:ok, {stage, run}}, _now) do
    # Durable controls precede resumed I/O, including controls committed while
    # no Driver existed. The epoch rejects a resume after an interruption.
    inbox = Enum.map(run.pending_event_ids, &{:next, {:inbox, &1}})
    {%{turn | stage: :boundary, run: run}, inbox ++ [{:next, {:resume, run.epoch, stage}}]}
  end

  defp complete(turn, :model_response, {:ok, response}, now) do
    run = %{
      turn.run
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
      do: {%{turn | stage: :boundary, run: %{run | calls: []}}, [{:next, :boundary}]},
      else: enter_tools(%{turn | run: %{run | calls: run.round_calls}}, now)
  end

  defp complete(turn, {:tool, id}, {:error, reason}, now),
    do: complete(turn, {:tool, id}, Tools.error(reason), now)

  defp complete(turn, {:tool, id}, {:delegate, name, args, continue}, now) do
    pending = PendingCall.delegate(turn.pending, id, name, args, continue)
    dispatch_worker(%{turn | pending: pending}, id, now)
  end

  defp complete(turn, {:tool, id}, {:await, wait}, _now) do
    {turn, commands} = await_result(turn, id, wait)
    {turn, commands ++ [{:next, :tools}]}
  end

  defp complete(turn, {:tool, id}, %ToolResult{} = result, _now) do
    {turn, commands} = accept_result(turn, id, result)
    {turn, commands ++ [{:next, :tools}]}
  end

  defp complete(turn, :record, {:ok, journal}, now) do
    {turn, commands} = transition_worker(turn, :round_committed, now)

    run = %{
      turn.run
      | calls: [],
        anchor: journal.message.id,
        saw_tool_results: true,
        follow_ups: [],
        wait_event_ids: []
    }

    {%{turn | stage: :boundary, run: run, pending: %{}, observing?: false},
     [:cancel_round_tasks | commands] ++ worker_timers(turn, now) ++ [{:next, :boundary}]}
  end

  defp complete(turn, :worker_resolve, result, now),
    do: acquisition_event(turn, {:resolved, result}, now)

  defp complete(turn, :worker_open, result, now),
    do: acquisition_event(turn, {:sent, result}, now)

  defp complete(turn, :worker_check, result, now),
    do: acquisition_event(turn, {:checked, result}, now)

  defp complete(turn, :worker, event, now), do: worker_event(turn, event, now)

  defp complete(turn, {:worker_send, id}, {:error, _reason}, now),
    do:
      acquisition_event(
        %{turn | pending: PendingCall.send_failed(turn.pending, id)},
        :send_failed,
        now
      )

  defp complete(turn, {:worker_send, _id}, {:ok, _}, _now), do: {turn, []}

  defp complete(turn, :boundary, {:ok, run}, _now) do
    case next_round(run) do
      {:request, run} ->
        {%{turn | run: run}, [{:next, :request}]}

      {:finalize, run} ->
        finalize(%{turn | run: run}, run.outcome)

      {:workflow_failure, run, failure} ->
        {%{turn | stage: :finalizing, run: run}, [{:workflow_failure, failure}]}
    end
  end

  defp complete(turn, :observe, observations, _now) when is_list(observations) do
    {turn, commands} =
      Enum.reduce(observations, {%{turn | observing?: false}, []}, fn
        {_id, :pending}, acc ->
          acc

        {id, {:ready, result, ids}}, {turn, commands} ->
          run = %{turn.run | wait_event_ids: Enum.uniq(turn.run.wait_event_ids ++ ids)}
          {turn, observed} = accept_result(%{turn | run: run}, id, result)
          {turn, commands ++ observed}
      end)

    {turn, commands ++ [{:next, :tools}]}
  end

  defp complete(%{run: nil} = turn, {:inbox, _}, %Signal{status: status} = event, _now)
       when status in [:queued, :running] do
    if event.type in ["command.stop", "command.new", "command.retry"] and
         Commands.route(event) == :control,
       do: {%{turn | stage: :admitting}, [{:control, event}]},
       else: {turn, []}
  end

  defp complete(turn, {:inbox, _}, %Signal{status: status} = event, _now)
       when status in [:queued, :running] do
    cond do
      event.id == turn.run.signal_id or event.id in turn.run.steer_event_ids ->
        {turn, []}

      Signal.produced_by_kernel?(event) and event.type == "command.retry" ->
        {turn, [{:retry_action, event}]}

      Signal.produced_by_kernel?(event) and
          (event.type in ["command.stop", "command.new"] or
             (event.type == "input.revised" and Revisions.immediate?(turn.run, event))) ->
        interrupt(turn, event)

      event.id in turn.run.pending_event_ids ->
        {turn, []}

      true ->
        run = %{turn.run | pending_event_ids: turn.run.pending_event_ids ++ [event.id]}
        turn = %{turn | run: run}
        if turn.stage == :executing_tools, do: observe_waits(turn), else: {turn, []}
    end
  end

  defp complete(turn, {:inbox, _}, _event, _now), do: {turn, []}
  defp complete(turn, :finalize, {:ok, _}, _now), do: close_and_rebuild(turn)

  defp complete(turn, :workflow_failure, {:ok, %{call: %{status: status}}}, _now)
       when status in [:queued, :sleeping], do: close_and_rebuild(turn)

  defp complete(turn, :workflow_failure, {:ok, _}, _now), do: finalize(turn, :submitted)
  defp complete(turn, :withdrawal, %Signal{} = event, _now), do: interrupt(turn, event)

  defp complete(turn, :withdrawal, nil, _now) do
    {turn, commands} = finalize(%{turn | observing?: false}, :stopped)
    {turn, [:cancel_current | commands]}
  end

  defp complete(turn, :defer_retry, {:ok, event}, _now),
    do:
      {%{turn | stage: :backing_off, run: %{turn.run | event: event}, event: event},
       [{:wait_until, event.available_at, :admit}]}

  defp complete(turn, :defer_retry, {:error, reason}, _now),
    do: {turn, [{:stop, {:defer_retry_failed, reason}}]}

  defp complete(turn, _kind, {:error, reason}, now), do: failed(turn, reason, now)

  defp prepare(turn, run),
    do: {%{turn | stage: :preparing, run: run, pending: %{}, observing?: false}, [:prepare]}

  defp interrupt(turn, event),
    do: {%{turn | observing?: false}, [:cancel_current, {:interrupt, event}]}

  defp enter_tools(turn, now) do
    pending =
      PendingCall.new_round(turn.run.calls, turn.run.recovered?)
      |> Map.new(fn {id, entry} ->
        if Map.has_key?(turn.run.receipts, id) do
          tool = ToolCatalog.find(turn.run, entry.call)

          args =
            case ToolArguments.parse(entry.call["arguments"] || "{}") do
              {:ok, args} -> args
              {:error, _reason} -> %{}
            end

          {id,
           %{
             entry
             | status: :running,
               tool: tool,
               args: args,
               sequential?: is_nil(tool) or tool.execution_mode == "sequential"
           }}
        else
          {id, entry}
        end
      end)

    {turn, commands} =
      Enum.reduce(
        turn.run.calls,
        {%{turn | stage: :executing_tools, pending: pending}, [:clear_phase]},
        fn call, {turn, commands} ->
          id = Run.call_id(call)

          {turn, observed} =
            case Map.fetch(turn.run.receipts, id) do
              {:ok, {:await, wait}} -> await_result(turn, id, wait)
              {:ok, result} -> accept_result(turn, id, result)
              :error -> {turn, []}
            end

          start = if Map.has_key?(turn.run.receipts, id), do: [{:start_tool, call}], else: []
          {turn, commands ++ start ++ observed}
        end
      )

    {%{turn | run: %{turn.run | receipts: %{}}},
     commands ++ worker_timers(turn, now) ++ [{:next, :tools}]}
  end

  defp dispatch_tools(turn, now) do
    {turn, commands} = dispatch_available(turn, now)

    cond do
      Enum.all?(turn.run.calls, &Map.has_key?(turn.run.results, Run.call_id(&1))) ->
        {%{turn | stage: :recording}, commands ++ [:record]}

      PendingCall.waits(turn.pending) != [] ->
        {turn, commands ++ worker_timers(turn, now) ++ [{:wait, @poll_ms, :poll}]}

      true ->
        {turn, commands ++ worker_timers(turn, now)}
    end
  end

  defp dispatch_available(turn, now) do
    case PendingCall.next(turn.pending, turn.run.calls) do
      {:ok, call, active} ->
        case Tools.prepare(turn.run, call) do
          {:error, result} ->
            {turn, commands} = accept_result(turn, Run.call_id(call), result)
            {turn, more} = dispatch_available(turn, now)
            {turn, commands ++ more}

          {:ok, tool, args} ->
            dispatch_call(turn, call, tool, args, active, now)
        end

      :none ->
        {turn, []}
    end
  end

  defp dispatch_call(turn, call, tool, args, active, now) do
    sequential? = tool.execution_mode == "sequential"

    if PendingCall.blocked?(turn.pending, sequential?, active) do
      {turn, []}
    else
      id = Run.call_id(call)
      pending = PendingCall.start(turn.pending, id, call, tool, args, sequential?)
      turn = %{turn | pending: pending}

      activity =
        if tool.executor != :worker,
          do: [{:present, Presentation.tool_activity(call, tool, args, "running")}],
          else: []

      {turn, commands} =
        if tool.executor == :worker or pending[id].worker_name,
          do: dispatch_worker(turn, id, now),
          else: {turn, [{:tool, turn.run, pending[id]}]}

      commands = [{:start_tool, call}] ++ activity ++ commands

      if sequential? and not Map.has_key?(turn.run.results, id) do
        {turn, commands}
      else
        {turn, more} = dispatch_available(turn, now)
        {turn, commands ++ more}
      end
    end
  end

  defp await_result(turn, id, wait),
    do:
      {%{turn | pending: PendingCall.await(turn.pending, id, wait)},
       [{:present, Presentation.waiting(turn.pending[id].call, wait)}]}

  defp accept_result(turn, id, result) do
    case turn.pending[id] do
      nil ->
        {turn, []}

      entry ->
        result =
          if is_integer(entry.started_at) and not entry.probe? and is_nil(result.duration_ms),
            do: %{
              result
              | duration_ms: max(System.monotonic_time(:millisecond) - entry.started_at, 0)
            },
            else: result

        events =
          if entry.tool && entry.tool.executor != :worker do
            phase = if result.is_error == true, do: "failed", else: "completed"
            Presentation.tool_activity(entry.call, entry.tool, entry.args, phase, result)
          else
            []
          end

        {run, attached} = Tools.attach(turn.run, result)
        run = track_failure(run, entry.call, attached)

        run = %{
          run
          | results: Map.put(run.results, id, attached),
            visible_delivery?:
              run.visible_delivery? or Run.visible_delivery?(run, entry.call, attached)
        }

        turn = %{turn | run: run, pending: Map.delete(turn.pending, id)}

        commands = [
          {:finish_tool, id, result},
          {:present, events ++ (result.presentation || [])},
          :publish_activity
        ]

        if ToolResult.ends_turn?(result) do
          Enum.reduce(PendingCall.queued(turn.pending), {turn, commands}, fn next_id,
                                                                             {turn, commands} ->
            {turn, more} =
              accept_result(turn, next_id, Tools.error("An earlier tool ended this turn."))

            {turn, commands ++ more}
          end)
        else
          {turn, commands}
        end
    end
  end

  defp observe_waits(%{observing?: true} = turn), do: {turn, [{:wait, @poll_ms, :poll}]}

  defp observe_waits(turn) do
    if PendingCall.waits(turn.pending) == [],
      do: {turn, []},
      else: {%{turn | observing?: true}, [:observe, {:wait, @poll_ms, :poll}]}
  end

  defp worker_event(turn, :ignore, _now), do: {turn, []}

  defp worker_event(turn, :ready, now), do: acquisition_event(turn, :ready, now)

  defp worker_event(turn, {kind, _} = event, now) when kind in [:waiting, :unavailable],
    do: acquisition_event(turn, event, now)

  defp worker_event(turn, {:unknown, id}, now) do
    case turn.pending[id].mode do
      "execute" ->
        turn = %{turn | pending: PendingCall.unknown(turn.pending, id)}
        acquisition_event(turn, :send_failed, now)

      "probe" ->
        complete(turn, {:tool, id}, Tools.interrupted(), now)
    end
  end

  defp worker_event(turn, {:presentation, kind, value}, _now),
    do: {turn, [{:present, [%{"kind" => kind, "payload" => value}]}]}

  defp worker_event(turn, {:result, id, result, follow}, now) do
    turn = %{turn | run: %{turn.run | follow_ups: turn.run.follow_ups ++ follow}}

    case turn.pending[id].continue do
      continue when is_function(continue, 2) and result.is_error != true ->
        {turn, [{:continue_tool, id, continue, result}]}

      _ ->
        complete(turn, {:tool, id}, result, now)
    end
  end

  defp dispatch_worker(turn, id, now) do
    turn = %{turn | pending: PendingCall.wait_worker(turn.pending, id)}

    case turn.acquisition do
      {:ready, row} ->
        {pending, entry} = PendingCall.to_worker(turn.pending, id)
        {%{turn | pending: pending}, [{:send_tool, turn.run, row, entry}]}

      {:unavailable, reason} ->
        fail_worker_waits(turn, reason)

      _ ->
        transition_worker(turn, :acquire, now)
    end
  end

  defp acquisition_event(turn, event, now) do
    {turn, commands} = transition_worker(turn, event, now)
    {turn, commands ++ worker_timers(turn, now) ++ [{:next, :tools}]}
  end

  defp transition_worker(turn, event, now) do
    {state, effects} = WorkerAcquisition.next(turn.acquisition, event, now)

    Enum.reduce(effects, {%{turn | acquisition: state}, []}, fn effect, {turn, commands} ->
      {turn, more} = worker_effect(turn, effect)
      {turn, commands ++ more}
    end)
  end

  defp worker_effect(turn, :request), do: {turn, [:request_worker]}
  defp worker_effect(turn, :resolve), do: {turn, [:resolve_worker]}

  defp worker_effect(turn, {:send_open, row, message}),
    do: {%{turn | workspace_open_attempted?: true}, [{:open_worker, row, message}]}

  defp worker_effect(turn, {:check, row}), do: {turn, [{:check_worker, row}]}

  defp worker_effect(turn, :ready),
    do: {%{turn | pending: PendingCall.ready(turn.pending)}, [:clear_phase, :publish_activity]}

  defp worker_effect(turn, :retry_calls),
    do:
      {%{turn | pending: PendingCall.worker_changed(turn.pending)},
       [:clear_phase, :publish_activity]}

  defp worker_effect(turn, :probe), do: {turn, [:read_worker_sends]}
  defp worker_effect(turn, {:unavailable, reason}), do: fail_worker_waits(turn, reason)
  defp worker_effect(turn, {:phase, name}), do: {turn, [phase(WorkerAcquisition.phase_key(name))]}

  defp worker_timers(turn, now),
    do:
      Enum.map(WorkerAcquisition.timers(turn.acquisition, now), fn {name, delay} ->
        {:worker_timer, name, delay}
      end)

  defp fail_worker_waits(turn, reason) do
    Enum.reduce(PendingCall.waiting_worker(turn.pending), {turn, []}, fn id, {turn, commands} ->
      result =
        if turn.pending[id].probe?,
          do: Tools.interrupted(),
          else: Tools.error(WorkerAcquisition.error_text(reason))

      {turn, more} = accept_result(turn, id, result)
      {turn, commands ++ more}
    end)
  end

  defp phase(name),
    do:
      {:present,
       [
         %{
           "kind" => "turn.phase",
           "payload" => %{
             "operation_id" => "turn",
             "state" => "working",
             "label_key" => "conversations.delivery.reply.activity.#{name}"
           }
         }
       ]}

  defp finalize(turn, outcome, reason \\ nil),
    do:
      {%{turn | stage: :finalizing, run: %{turn.run | outcome: outcome}},
       [{:finalize, outcome, reason}]}

  defp close_and_rebuild(turn) do
    close =
      if turn.run && turn.workspace_open_attempted?, do: [{:close_worker, turn.run}], else: []

    {turn, commands} = rebuild(turn)
    {turn, close ++ commands}
  end

  defp rebuild(turn),
    do:
      {%__MODULE__{key: turn.key},
       [
         {:settle, turn},
         :clear_tasks,
         {:worker_timer, :acquire, :cancel},
         {:worker_timer, :check, :cancel},
         {:next, :rebuild}
       ]}

  defp failed(turn, reason, _now) when reason in [:stale_driver, :run_closed],
    do: {turn, [{:refund, :stale_driver}, {:stop, :normal}]}

  defp failed(%{run: nil} = turn, reason, _now),
    do: {turn, [{:stop, {:admission_failed, reason}}]}

  defp failed(turn, :signal_canceled, _now), do: {turn, [:read_withdrawal]}

  defp failed(turn, :signal_context_canceled, _now) do
    {turn, commands} = finalize(%{turn | observing?: false}, :stopped, :signal_context_canceled)
    {turn, [:cancel_current | commands]}
  end

  defp failed(turn, reason, _now) do
    case Run.type(turn.run).failure(reason) do
      {:workflow_failure, error} ->
        {%{turn | stage: :finalizing, observing?: false},
         [:cancel_current, {:workflow_error, error}]}

      {:execution_error, error} ->
        {turn, commands} =
          if error["retryable"] == true do
            {%{turn | observing?: false}, [{:retry_cleanup, error}, {:defer_retry, error}]}
          else
            finalize(turn, :dead_letter, error)
          end

        {turn, [{:log_failure, error} | commands]}
    end
  end

  defp next_round(run) do
    had_tools = run.round_calls != []
    text = Run.text(run)
    stopped = terminating_result(run)

    max_iterations =
      get_in(run.spec.request_context, ["ai_agent", "max_iterations"]) ||
        Ankole.Sessions.AgentConfig.default_max_iterations()

    cond do
      Run.truncated?(run.model_response) ->
        truncated_calls(run)

      stopped ->
        {:finalize, %{run | outcome: stopped.outcome || run.outcome}}

      run.outcome == :iteration_exhausted and run.iteration > max_iterations ->
        Run.type(run).finish(run)

      synthesis_due?(run, max_iterations) ->
        {:request,
         %{
           run
           | outcome: :iteration_exhausted,
             tools: [],
             hosted_tools: [],
             input: [
               Run.user("#{@synthesis}\nmax_model_iterations=#{max_iterations}") | run.input
             ]
         }}

      had_tools ->
        {:request, %{run | nudged: false}}

      needs_tool_nudge?(run, text) ->
        {:request, %{run | nudged: true, input: [Run.user(@nudge) | run.input]}}

      not run.repaired and stopped_normally?(run) and Run.type(run).repair(run, text) != nil ->
        {:request, repaired(Run.type(run).repair(run, text))}

      run.input != [] ->
        {:request, run}

      true ->
        Run.type(run).finish(run)
    end
  end

  defp synthesis_due?(run, max_iterations),
    do:
      run.round_calls != [] and run.iteration >= max_iterations and
        run.outcome != :iteration_exhausted

  # A cut-off call is not executable, and AIGateway leaves it out of the replayed
  # history, so the note tells the model what happened to it.
  defp truncated_calls(run) do
    rounds = run.truncated_rounds + 1
    run = %{run | truncated_rounds: rounds}

    if rounds >= 2,
      do: Run.type(run).finish(run),
      else:
        {:request,
         %{
           run
           | input:
               Enum.map(
                 run.round_calls,
                 &Run.output(&1, Tools.error("Not run: the response was cut off."))
               ) ++ [Run.user(@truncated) | run.input]
         }}
  end

  defp needs_tool_nudge?(run, text) do
    Run.type(run).nudge?() and run.saw_tool_results and not run.nudged and
      stopped_normally?(run) and String.trim(text) == ""
  end

  defp terminating_result(run) do
    Enum.find_value(run.round_calls, fn call ->
      result = run.results[Run.call_id(call)]
      if result && ToolResult.ends_turn?(result), do: result
    end)
  end

  defp stopped_normally?(run), do: run.model_response.metadata["stop_reason"] in [nil, "stop"]
  defp repaired({prompt, run}), do: %{run | repaired: true, input: [Run.user(prompt) | run.input]}

  defp scrub(value) when is_map(value),
    do: value |> Map.drop(@volatile) |> Map.new(fn {k, v} -> {k, scrub(v)} end)

  defp scrub(value) when is_list(value), do: Enum.map(value, &scrub/1)
  defp scrub(value), do: value

  defp warning(tool, count) do
    common =
      "#{tool} has failed #{count} times this turn. This looks like a loop. First inspect the latest error/output and verify your assumptions. Use tools when they can make progress. If the Agent computer is unavailable, explain the blocker without another computer call. "

    recovery =
      if tool == "command",
        do:
          "For a failed command on an available computer, run a small diagnostic such as `pwd && ls -la` in the same tool, then try an absolute path, a simpler command, a different working directory, or a different tool such as read_file/apply_patch.",
        else:
          "Try different arguments, a narrower query/path, an absolute path when relevant, or a different tool that can make progress. If the blocker is external, report the blocker after one diagnostic attempt instead of repeating the same failing path."

    "[Tool loop warning: repeated_tool_failure; count=#{count}; #{common}#{recovery}]"
  end
end
