defmodule Ankole.AIGateway.ResponseStream.State do
  @moduledoc false

  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.AIGateway.ImageStreamPersistence
  alias Ankole.AIGateway.MaxToolCalls
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.StatefulLifecycle
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.ToolSearch.StreamLoop
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Logging

  @terminal_event_types ~w(response.completed response.failed response.incomplete)

  defstruct subject_uid: nil,
            stateful: nil,
            image_persistence: nil,
            max_tool_calls: nil,
            tool_loop: nil,
            public_items: [],
            durable_items: [],
            local_response_id: nil,
            provider_response_id: nil,
            provider_error_diagnostic: nil,
            terminal_response: nil,
            terminal_error: nil,
            terminal?: false,
            public_lifecycle_started?: false,
            sequence_number: nil,
            provider_output_indexes: %{},
            provider_item_ids: %{},
            provider_pair_ids: %{},
            public_item_ids: MapSet.new(),
            public_pair_ids: MapSet.new(),
            next_output_index: 0

  @type t :: %__MODULE__{}
  @type outcome :: %{
          required(:stateful?) => boolean(),
          required(:terminal_response) => map() | nil,
          required(:terminal_error) => map() | nil,
          required(:public_items) => [map()]
        }
  @type status ::
          :continue
          | {:terminal, outcome(), :keep_upstream | :cancel_upstream}
          | {:round, map()}
          | {:local, [map()], map()}

  @spec new(String.t(), map(), map(), keyword()) :: t()
  def new(subject_uid, request, meta, opts \\ []) do
    stateful = Keyword.get(opts, :stateful)
    tool_loop = StreamLoop.new(Keyword.get(opts, :tool_loop))

    %__MODULE__{
      subject_uid: subject_uid,
      stateful: stateful,
      local_response_id: "resp_#{UUIDv7.autogenerate()}",
      image_persistence:
        ImageStreamPersistence.new(subject_uid, message_id: stateful_message_id(stateful)),
      max_tool_calls:
        MaxToolCalls.new(
          Map.get(request, "max_tool_calls"),
          Map.get(meta, "api_resolver") || Map.get(meta, :api_resolver),
          force: StreamLoop.gateway_effects?(tool_loop)
        ),
      tool_loop: tool_loop
    }
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{terminal?: terminal?}), do: terminal?

  @spec stateful_context(t()) :: map() | nil
  def stateful_context(%__MODULE__{stateful: stateful}), do: stateful

  @spec observe(t(), map(), non_neg_integer()) ::
          {:ok, t(), [map()], status()}
          | {:error, t(), [map()], status(), term()}
  def observe(%__MODULE__{} = state, %{"type" => "error"} = event, _fallback_sequence),
    do: {:ok, remember_provider_error(state, event), [], :continue}

  def observe(%__MODULE__{} = state, %{} = event, fallback_sequence) do
    case ImageStreamPersistence.observe(state.image_persistence, event) do
      {:ok, image_persistence, events} ->
        {state, public_events, status} =
          state
          |> Map.put(:image_persistence, image_persistence)
          |> observe_public_events(events, fallback_sequence)

        {:ok, state, public_events, status}

      {:error, image_persistence, events, reason} ->
        {state, public_events, status} =
          state
          |> Map.put(:image_persistence, image_persistence)
          |> observe_public_events(events, fallback_sequence)

        {:error, state, public_events, force_cancel(status), reason}
    end
  end

  @spec fail(t(), String.t(), keyword()) :: {t(), [map()], outcome() | nil}
  def fail(%__MODULE__{terminal?: true} = state, _reason, _opts),
    do: {state, [], outcome(state)}

  def fail(%__MODULE__{} = state, _reason, opts) do
    code = Keyword.get(opts, :code, "provider_stream_error")
    retryable? = Keyword.get(opts, :retryable, false) == true
    message = Keyword.get(opts, :message, safe_error_message(code))
    details = Keyword.get(opts, :details)
    provider_status = Keyword.get(opts, :provider_status)

    error =
      %{
        "code" => code,
        "message" => message,
        "retryable" => retryable?
      }
      |> maybe_put_metadata("provider_status", provider_status)
      |> maybe_put_metadata("details_json", details)
      |> correlate_provider_error(state)

    commit_stateful_error(state.stateful, chronological(state.durable_items), error)

    response = %{
      "id" => cleanup_response_id(state),
      "object" => "response",
      "status" => "failed",
      "error" => error,
      # Failure is another terminal projection of the same response. Items
      # already emitted before a continuation/open failure cannot disappear
      # from the final public response while remaining in durable history.
      "output" => chronological(state.public_items)
    }

    event =
      %{"type" => "response.failed", "response" => response}
      |> maybe_put_sequence_number(next_sequence_number(state))
      |> rewrite_response_id(state)

    state = %{
      state
      | terminal?: true,
        terminal_response: event["response"],
        terminal_error: event["response"]["error"]
    }

    {state, [event], outcome(state)}
  end

  @spec outcome(t()) :: outcome()
  def outcome(%__MODULE__{} = state) do
    %{
      stateful?: not is_nil(state.stateful),
      terminal_response: state.terminal_response,
      terminal_error: state.terminal_error,
      public_items: chronological(state.public_items)
    }
  end

  @doc """
  Takes the local effects that precede the first provider round.
  """
  @spec take_initial_local_effect(t()) :: {:ok, t(), [map()], [map()], map()}
  def take_initial_local_effect(%__MODULE__{tool_loop: %StreamLoop{}} = state) do
    {state, lifecycle_events} = ensure_public_lifecycle(state)
    {:ok, jobs, context, tool_loop} = StreamLoop.take_initial_local_effect(state.tool_loop)
    {:ok, %{state | tool_loop: tool_loop}, lifecycle_events, jobs, context}
  end

  defp ensure_public_lifecycle(
         %__MODULE__{tool_loop: %StreamLoop{}, public_lifecycle_started?: true} = state
       ),
       do: {state, []}

  defp ensure_public_lifecycle(%__MODULE__{tool_loop: %StreamLoop{}} = state) do
    response_id = cleanup_response_id(state)
    tool_loop = StreamLoop.bump(state.tool_loop)

    state = %{
      state
      | tool_loop: tool_loop,
        public_lifecycle_started?: true,
        provider_response_id: state.provider_response_id || response_id,
        sequence_number: tool_loop.sequence
    }

    event = %{
      "type" => "response.created",
      "sequence_number" => tool_loop.sequence,
      "response" => %{
        "id" => response_id,
        "object" => "response",
        "status" => "in_progress",
        "output" => []
      }
    }

    {state, [rewrite_response_id(event, state)]}
  end

  defp observe_public_events(state, events, fallback_sequence) do
    state = preobserve_delayed_image_items(state, events)

    {state, reversed_events, status} =
      Enum.reduce_while(events, {state, [], :continue}, fn event,
                                                           {state, public_events, :continue} ->
        {state, emitted, status} = observe_public_event(state, event, fallback_sequence)
        result = {state, Enum.reverse(emitted, public_events), status}

        case status do
          :continue -> {:cont, result}
          {:round, _continuation_request} -> {:halt, result}
          {:local, _jobs, _context} -> {:halt, result}
          {:terminal, _outcome, _upstream_action} -> {:halt, result}
        end
      end)

    {state, Enum.reverse(reversed_events), status}
  end

  defp observe_public_event(%{tool_loop: %StreamLoop{}} = state, event, fallback_sequence) do
    case StreamLoop.observe(state.tool_loop, event) do
      {:suppress, tool_loop} ->
        {%{state | tool_loop: tool_loop}, [], :continue}

      {:emit, event, tool_loop} ->
        observe_planned_public_event(%{state | tool_loop: tool_loop}, event, fallback_sequence)
    end
  end

  defp observe_public_event(state, event, fallback_sequence),
    do: observe_planned_public_event(state, event, fallback_sequence)

  defp observe_planned_public_event(state, event, fallback_sequence) do
    sequence = public_sequence_number(event, fallback_sequence)
    previous_sequence = state.sequence_number

    state =
      state
      |> remember_provider_response_id(event)
      |> Map.put(:sequence_number, sequence)
      |> account_tool_calls(event)

    if event["type"] in @terminal_event_types do
      event = reconcile_terminal_item_snapshots(state, event)
      event = filter_unadmitted_tool_items(state, event)
      observe_terminal_event(state, event, sequence)
    else
      observe_non_terminal_event(state, event, sequence, previous_sequence)
    end
  end

  defp observe_non_terminal_event(
         state,
         %{"item" => %{} = _item} = event,
         sequence,
         previous_sequence
       ) do
    if MaxToolCalls.event_item_admitted?(state.max_tool_calls, event, budget_scope(state)) do
      {state, event} = map_provider_item_identity(state, event)
      {state, event} = map_provider_output_index(state, event)
      state = remember_non_terminal_event(state, event, sequence)
      public_event = rewrite_response_id(event, state)
      {state, [public_event], :continue}
    else
      {rollback_rejected_sequence(state, event, previous_sequence), [], :continue}
    end
  end

  # ImageStreamPersistence holds this event until the following done item has
  # been stored. Some native providers omit output_item.added, so the released
  # completion is the first public reference to its item and output index.
  defp observe_non_terminal_event(
         state,
         %{
           "type" => "response.image_generation_call.completed",
           "item_id" => upstream_id
         } = event,
         sequence,
         previous_sequence
       )
       when is_binary(upstream_id) and upstream_id != "" do
    item = %{"type" => "image_generation_call", "id" => upstream_id}

    if MaxToolCalls.item_admitted?(state.max_tool_calls, item, budget_scope(state)) do
      {state, public_id} = provider_public_item_id(state, upstream_id)
      {state, event} = map_provider_output_index(state, event)
      event = Map.put(event, "item_id", public_id)
      state = remember_non_terminal_event(state, event, sequence)
      {state, [rewrite_response_id(event, state)], :continue}
    else
      {rollback_rejected_sequence(state, event, previous_sequence), [], :continue}
    end
  end

  defp observe_non_terminal_event(state, event, sequence, previous_sequence) do
    with {:ok, event} <- mapped_provider_output_index(state, event),
         {:ok, event} <- mapped_provider_item_identity(state, event) do
      state = remember_non_terminal_event(state, event, sequence)
      public_event = rewrite_response_id(event, state)
      {state, [public_event], :continue}
    else
      _unadmitted_reference ->
        {rollback_rejected_sequence(state, event, previous_sequence), [], :continue}
    end
  end

  # Image persistence releases a delayed completion marker immediately before
  # its matching done item. Decide the done item's budget admission first, but
  # keep the provider's public event order.
  defp preobserve_delayed_image_items(state, events) do
    completion_ids =
      Enum.reduce(events, MapSet.new(), fn
        %{
          "type" => "response.image_generation_call.completed",
          "item_id" => item_id
        },
        ids
        when is_binary(item_id) and item_id != "" ->
          MapSet.put(ids, item_id)

        _event, ids ->
          ids
      end)

    Enum.reduce(events, state, fn
      %{
        "type" => "response.output_item.done",
        "item" => %{"type" => "image_generation_call", "id" => item_id}
      } = event,
      state
      when is_binary(item_id) and item_id != "" ->
        if MapSet.member?(completion_ids, item_id),
          do: account_tool_calls(state, event),
          else: state

      _event, state ->
        state
    end)
  end

  defp filter_unadmitted_tool_items(
         state,
         %{"response" => %{"output" => output} = response} = event
       )
       when is_list(output) do
    public_output =
      case state.tool_loop do
        %StreamLoop{} = loop -> StreamLoop.rewrite_public_items(loop, output)
        _no_loop -> output
      end

    filtered =
      output
      |> Enum.zip(public_output)
      |> Enum.filter(fn
        {_provider_item, %{} = public_item} ->
          MaxToolCalls.item_admitted?(
            state.max_tool_calls,
            public_item,
            budget_scope(state)
          )

        {_provider_item, _invalid_public_item} ->
          true
      end)
      |> Enum.map(&elem(&1, 0))

    Map.put(event, "response", Map.put(response, "output", filtered))
  end

  defp filter_unadmitted_tool_items(_state, event), do: event

  defp rollback_rejected_sequence(
         %{tool_loop: %StreamLoop{} = loop} = state,
         %{"sequence_number" => sequence_number},
         previous_sequence
       )
       when is_integer(sequence_number) do
    %{
      state
      | tool_loop: %{loop | sequence: max(loop.sequence - 1, -1)},
        sequence_number: previous_sequence
    }
  end

  defp rollback_rejected_sequence(state, _event, previous_sequence),
    do: %{state | sequence_number: previous_sequence}

  defp observe_terminal_event(%{tool_loop: %StreamLoop{}} = state, event, _sequence) do
    response = Map.get(event, "response", %{})
    {state, provider_events} = admit_terminal_provider_items(state, response)

    case StreamLoop.intercept_terminal(state.tool_loop, event["type"], response) do
      {:round, continuation_request, round_items, tool_loop} ->
        {state, round_events} =
          append_loop_items(%{state | tool_loop: tool_loop}, round_items)

        {state, events, status} =
          gate_next_effect(state, round_events, {:round, continuation_request})

        {state, provider_events ++ events, status}

      {:local, jobs, context, tool_loop} ->
        context = Map.put(context, :event, event)
        {%{state | tool_loop: tool_loop}, provider_events, {:local, jobs, context}}

      {:finalize, output_items, extra_items, tool_loop} ->
        {state, events, status} =
          finish_loop_terminal(state, event, output_items, extra_items, tool_loop)

        {state, provider_events ++ events, status}
    end
  end

  defp observe_terminal_event(state, event, sequence),
    do: finalize_terminal(state, event, sequence, :keep_upstream)

  # Some compatible providers omit item identities and other fields from the
  # terminal snapshot. Restore a same-index item only when the snapshot is a
  # field-for-field subset of the item that its done event already admitted.
  defp reconcile_terminal_item_snapshots(
         state,
         %{"response" => %{"output" => output} = response} = event
       )
       when is_list(output) do
    output =
      output
      |> Enum.with_index()
      |> Enum.map(fn {item, provider_index} ->
        reconcile_terminal_item_snapshot(state, item, provider_index)
      end)

    Map.put(event, "response", Map.put(response, "output", output))
  end

  defp reconcile_terminal_item_snapshots(_state, event), do: event

  defp reconcile_terminal_item_snapshot(state, %{} = item, provider_index) do
    with nil <- public_item_id(item),
         {:ok, recorded_item} <- terminal_snapshot_candidate(state, provider_index),
         true <- terminal_item_subset?(item, recorded_item) do
      recorded_item
    else
      _not_same_item -> item
    end
  end

  defp reconcile_terminal_item_snapshot(_state, item, _provider_index), do: item

  defp terminal_snapshot_candidate(
         %{tool_loop: %StreamLoop{current_round_items_rev: provider_items}} = state,
         provider_index
       ) do
    with {:ok, public_item} <- terminal_public_item_candidate(state, provider_index),
         public_id when is_binary(public_id) <- public_item_id(public_item),
         %{} = provider_item <-
           Enum.find(provider_items, fn provider_item ->
             case public_item_id(provider_item) do
               nil -> false
               provider_id -> Map.get(state.provider_item_ids, provider_id) == public_id
             end
           end) do
      {:ok, provider_item}
    else
      _missing -> :error
    end
  end

  defp terminal_snapshot_candidate(state, provider_index),
    do: terminal_public_item_candidate(state, provider_index)

  defp terminal_public_item_candidate(state, provider_index) do
    with {:ok, public_index} <- Map.fetch(state.provider_output_indexes, provider_index),
         %{} = item <- Enum.at(chronological(state.public_items), public_index),
         item_id when is_binary(item_id) <- public_item_id(item) do
      {:ok, item}
    else
      _missing -> :error
    end
  end

  defp terminal_item_subset?(%{"type" => type} = item, %{"type" => type} = recorded_item)
       when is_binary(type) do
    snapshot = Map.delete(item, "id")

    map_size(snapshot) > 0 and
      Enum.all?(snapshot, fn {key, value} -> Map.fetch(recorded_item, key) == {:ok, value} end)
  end

  defp terminal_item_subset?(_item, _recorded_item), do: false

  @doc false
  @spec complete_local_effect(t(), map(), [map()]) ::
          {:ok, t(), [map()], status()} | {:error, t(), term()}
  def complete_local_effect(%__MODULE__{tool_loop: %StreamLoop{}} = state, context, outcomes) do
    loop_context = Map.delete(context, :event)

    case StreamLoop.complete_local_effect(state.tool_loop, loop_context, outcomes) do
      {:round, continuation_request, round_items, tool_loop} ->
        {state, round_events} =
          append_loop_items(%{state | tool_loop: tool_loop}, round_items)

        {state, events, status} =
          gate_next_effect(state, round_events, {:round, continuation_request})

        {:ok, state, events, status}

      {:finalize, output_items, extra_items, tool_loop} ->
        {state, events, status} =
          case Map.get(context, :event) do
            %{} = event ->
              finish_loop_terminal(state, event, output_items, extra_items, tool_loop)

            nil ->
              finish_local_terminal(state, output_items, extra_items, tool_loop)
          end

        {:ok, state, events, status}

      {:error, reason, tool_loop} ->
        {:error, %{state | tool_loop: tool_loop}, reason}
    end
  end

  defp finish_local_terminal(state, output_items, extra_items, tool_loop) do
    event = %{
      "type" => "response.completed",
      "response" => %{
        "id" => cleanup_response_id(state),
        "object" => "response",
        "status" => "completed",
        "output" => output_items
      }
    }

    finish_loop_terminal(state, event, output_items, extra_items, tool_loop)
  end

  defp finish_loop_terminal(state, event, output_items, extra_items, tool_loop) do
    {state, output_items} =
      map_terminal_provider_items(%{state | tool_loop: tool_loop}, output_items)

    {state, extra_events} = append_loop_items(state, extra_items)

    mapped_extra_items = Enum.map(extra_events, &Map.fetch!(&1, "item"))
    tool_loop = state.tool_loop

    finish_loop_provider_terminal(
      state,
      event,
      output_items,
      mapped_extra_items,
      extra_events,
      tool_loop
    )
  end

  defp finish_loop_provider_terminal(
         state,
         event,
         output_items,
         extra_items,
         extra_events,
         tool_loop
       ) do
    response =
      event
      |> Map.get("response", %{})
      |> Map.put("output", output_items ++ extra_items)

    event =
      event
      |> Map.put("response", response)
      |> finalize_loop_terminal_event(tool_loop)

    {state, terminal_events, status} =
      finalize_terminal(
        state,
        event,
        StreamLoop.next_sequence(tool_loop),
        :keep_upstream
      )

    {state, extra_events ++ terminal_events, status}
  end

  defp gate_next_effect(state, events, next_status) do
    case next_status do
      {:round, continuation_request} ->
        continuation_request =
          StreamLoop.apply_tool_budget(
            state.tool_loop,
            continuation_request,
            MaxToolCalls.remaining(state.max_tool_calls)
          )

        {begin_provider_round(state), events, {:round, continuation_request}}

      _no_round ->
        {state, events, next_status}
    end
  end

  # Appends loop-produced items (search outputs) as public output items with
  # their own `response.output_item.done` events.
  defp append_loop_items(state, []), do: {state, []}

  defp append_loop_items(state, items) do
    {state, events} =
      Enum.reduce(items, {state, []}, fn item, {state, events} ->
        {state, item} = register_local_item_identity(state, item)
        tool_loop = StreamLoop.bump(state.tool_loop)

        event =
          %{
            "type" => "response.output_item.done",
            "item" => item,
            "output_index" => state.next_output_index,
            "sequence_number" => tool_loop.sequence
          }
          |> rewrite_response_id(state)

        state = %{
          state
          | tool_loop: tool_loop,
            sequence_number: tool_loop.sequence,
            next_output_index: state.next_output_index + 1,
            public_items: [item | state.public_items],
            durable_items: [ImageStreamPersistence.storage_item(item) | state.durable_items]
        }

        {state, [event | events]}
      end)

    {state, Enum.reverse(events)}
  end

  # Some providers put complete items only in the terminal response. Admit
  # those provider facts before local search or program outputs so the public
  # stream, durable history, and global output indexes keep the same order.
  defp admit_terminal_provider_items(state, response) do
    items = response |> Map.get("output", []) |> map_items()
    public_items = StreamLoop.rewrite_public_items(state.tool_loop, items)

    {recorded_ids, recorded_anonymous} = recorded_item_identities(state.public_items)

    {state, events, _recorded_ids, _recorded_anonymous} =
      public_items
      |> Enum.with_index()
      |> Enum.reduce(
        {state, [], recorded_ids, recorded_anonymous},
        fn {item, provider_index}, {state, events, recorded_ids, recorded_anonymous} ->
          {state, identity_event} = map_provider_item_identity(state, %{"item" => item})
          item = Map.fetch!(identity_event, "item")

          case terminal_item_recorded?(item, recorded_ids, recorded_anonymous) do
            {:yes, recorded_ids, recorded_anonymous} ->
              {state, events, recorded_ids, recorded_anonymous}

            :no ->
              {state, event} =
                map_provider_output_index(
                  state,
                  Map.put(identity_event, "output_index", provider_index)
                )

              tool_loop = StreamLoop.bump(state.tool_loop)

              event =
                event
                |> Map.put("type", "response.output_item.done")
                |> Map.put("sequence_number", tool_loop.sequence)
                |> rewrite_response_id(state)

              state =
                state
                |> Map.put(:tool_loop, tool_loop)
                |> Map.put(:sequence_number, tool_loop.sequence)
                |> remember_non_terminal_event(event, tool_loop.sequence)

              {recorded_ids, recorded_anonymous} =
                remember_terminal_item(item, recorded_ids, recorded_anonymous)

              {state, [event | events], recorded_ids, recorded_anonymous}
          end
        end
      )

    {state, Enum.reverse(events)}
  end

  defp recorded_item_identities(items) do
    Enum.reduce(items, {MapSet.new(), %{}}, fn item, {ids, anonymous} ->
      case public_item_id(item) do
        nil -> {ids, Map.update(anonymous, item, 1, &(&1 + 1))}
        item_id -> {MapSet.put(ids, item_id), anonymous}
      end
    end)
  end

  defp terminal_item_recorded?(item, recorded_ids, recorded_anonymous) do
    case public_item_id(item) do
      nil ->
        case Map.get(recorded_anonymous, item, 0) do
          count when count > 0 ->
            {:yes, recorded_ids, Map.put(recorded_anonymous, item, count - 1)}

          _missing ->
            :no
        end

      item_id ->
        if MapSet.member?(recorded_ids, item_id),
          do: {:yes, recorded_ids, recorded_anonymous},
          else: :no
    end
  end

  defp remember_terminal_item(item, recorded_ids, recorded_anonymous) do
    case public_item_id(item) do
      nil -> {recorded_ids, recorded_anonymous}
      item_id -> {MapSet.put(recorded_ids, item_id), recorded_anonymous}
    end
  end

  # A terminal that still carries unanswered search calls after the round
  # budget cannot honestly complete; it becomes an explicit incomplete.
  defp finalize_loop_terminal_event(%{"type" => "response.completed"} = event, tool_loop) do
    response = Map.get(event, "response", %{})

    if reason = StreamLoop.incomplete_reason(tool_loop) do
      response =
        response
        |> Map.put("status", "incomplete")
        |> Map.put("incomplete_details", %{"reason" => reason})

      event
      |> Map.put("type", "response.incomplete")
      |> Map.put("response", response)
      |> put_loop_usage(tool_loop)
    else
      put_loop_usage(event, tool_loop)
    end
  end

  defp finalize_loop_terminal_event(event, tool_loop), do: put_loop_usage(event, tool_loop)

  defp put_loop_usage(event, tool_loop) do
    response =
      event
      |> Map.get("response", %{})
      |> maybe_put_metadata("usage", StreamLoop.accumulated_usage(tool_loop))
      |> maybe_put_metadata("tool_usage", StreamLoop.accumulated_tool_usage(tool_loop))

    Map.put(event, "response", response)
  end

  defp remember_non_terminal_event(state, %{"type" => "response.output_text.delta"} = event, seq) do
    delta = Map.get(event, "delta", "")

    if is_binary(delta) and delta != "" do
      publish(state, :output_text_delta, %{text: delta, seq: seq})
      state
    else
      state
    end
  end

  defp remember_non_terminal_event(
         state,
         %{"type" => type} = event,
         seq
       )
       when type in ["response.reasoning_summary_text.delta", "response.reasoning_text.delta"] do
    delta = Map.get(event, "delta", "")

    if is_binary(delta) and delta != "" do
      publish(state, :reasoning_delta, %{text: delta, source: type, seq: seq})
    end

    state
  end

  defp remember_non_terminal_event(
         state,
         %{"type" => "response.output_item.done", "item" => %{} = item} = event,
         seq
       ) do
    if tool_activity_item?(item) do
      publish(state, :tool_call_started, tool_activity_payload(item, seq))
    end

    next_output_index =
      if is_integer(event["output_index"]),
        do: state.next_output_index,
        else: state.next_output_index + 1

    %{
      state
      | next_output_index: next_output_index,
        public_items: [item | state.public_items],
        durable_items: [ImageStreamPersistence.storage_item(item) | state.durable_items]
    }
  end

  defp remember_non_terminal_event(state, _event, _seq), do: state

  defp finalize_terminal(state, event, sequence, upstream_action) do
    response = Map.get(event, "response", %{})
    terminal_items = response |> Map.get("output", []) |> map_items()
    public_items = terminal_public_items(state, terminal_items)
    durable_items = ImageStreamPersistence.storage_items(public_items)

    response = Map.put(response, "output", public_items)
    {terminal_type, response, terminal_error} = canonical_terminal(event["type"], response)
    terminal_error = correlate_provider_error(terminal_error, state)
    terminal_metadata = terminal_response_metadata(state, terminal_type, response)
    public_response = public_terminal_response(terminal_type, response, terminal_error)

    state = %{
      state
      | public_items: Enum.reverse(public_items),
        durable_items: Enum.reverse(durable_items),
        terminal_error: terminal_error
    }

    case commit_stateful_terminal(
           state.stateful,
           durable_items,
           terminal_error,
           terminal_metadata
         ) do
      :ok ->
        public_event =
          event
          |> Map.put("type", terminal_type)
          |> Map.put("response", public_response)
          |> maybe_put_sequence_number(sequence)
          |> rewrite_response_id(state)

        state = %{
          state
          | terminal?: true,
            terminal_response: public_event["response"]
        }

        {state, [public_event], {:terminal, outcome(state), upstream_action}}

      {:already_terminal, authoritative_response} ->
        finalize_authoritative_terminal(state, authoritative_response, sequence)

      {:error, reason} ->
        public_event = stateful_commit_failed_event(state, reason, sequence)

        state = %{
          state
          | terminal?: true,
            terminal_response: public_event["response"],
            terminal_error: public_event["response"]["error"]
        }

        {state, [public_event], {:terminal, outcome(state), :cancel_upstream}}
    end
  end

  defp finalize_authoritative_terminal(state, response, sequence) do
    terminal_type = terminal_event_type(response)
    terminal_error = authoritative_terminal_error(terminal_type, response)
    public_items = response |> Map.get("output", []) |> map_items()

    public_event =
      %{"type" => terminal_type, "response" => response}
      |> maybe_put_sequence_number(sequence)
      |> rewrite_response_id(state)

    state = %{
      state
      | public_items: Enum.reverse(public_items),
        terminal?: true,
        terminal_response: public_event["response"],
        terminal_error: terminal_error
    }

    {state, [public_event], {:terminal, outcome(state), :cancel_upstream}}
  end

  defp terminal_event_type(%{"status" => "completed"}), do: "response.completed"
  defp terminal_event_type(%{"status" => "incomplete"}), do: "response.incomplete"
  defp terminal_event_type(_response), do: "response.failed"

  defp authoritative_terminal_error("response.failed", %{"error" => %{} = error}),
    do: Map.put(error, "type", "response.failed")

  defp authoritative_terminal_error("response.incomplete", response),
    do: terminal_error("response.incomplete", response)

  defp authoritative_terminal_error(_terminal_type, _response), do: nil

  defp terminal_error("response.failed", response) do
    classification = FailureDiagnostics.classify({:provider_event_failed, response})

    %{
      "type" => "response.failed",
      "code" => Map.get(classification, :error_code, "provider_response_failed"),
      "message" => FailureDiagnostics.public_message(classification),
      "retryable" => Map.get(classification, :retryable, false)
    }
    |> put_safe_failure_fields(classification)
  end

  defp terminal_error("response.incomplete", response) do
    reason = incomplete_response_reason(response) || "unknown"

    cond do
      response_has_incomplete_tool_call?(response) ->
        %{
          "type" => "response.incomplete",
          "code" => "partial_tool_call_incomplete",
          "message" => safe_error_message("partial_tool_call_incomplete"),
          "status" => Map.get(response, "status", "incomplete"),
          "incomplete_details" => Map.get(response, "incomplete_details"),
          "reason" => reason,
          "retryable" => transient_incomplete_reason?(reason)
        }

      output_limit_incomplete_response?(response) ->
        nil

      true ->
        %{
          "type" => "response.incomplete",
          "code" => "response_incomplete",
          "message" => safe_error_message("response_incomplete"),
          "status" => Map.get(response, "status", "incomplete"),
          "incomplete_details" => Map.get(response, "incomplete_details"),
          "reason" => reason,
          "retryable" => transient_incomplete_reason?(reason)
        }
    end
  end

  defp terminal_error("response.completed", %{"output" => output}) when is_list(output) do
    if Enum.any?(output, &incomplete_tool_call_item?/1) do
      %{
        "type" => "response.completed",
        "code" => "partial_tool_call_completed",
        "message" => safe_error_message("partial_tool_call_completed"),
        "reason" =>
          "provider marked the response completed while a client tool call remained incomplete",
        "retryable" => false
      }
    end
  end

  defp terminal_error(_type, _response), do: nil

  # One terminal fact crosses every boundary. A provider cannot publicly claim
  # completion while the durable state and outcome correctly record an
  # unfinished call as an error.
  defp canonical_terminal("response.completed", response) do
    case terminal_error("response.completed", response) do
      %{} = error ->
        response =
          response
          |> Map.put("status", "failed")
          |> Map.put("error", Map.delete(error, "type"))

        {"response.failed", response, %{error | "type" => "response.failed"}}

      nil ->
        {"response.completed", response, nil}
    end
  end

  defp canonical_terminal(type, response), do: {type, response, terminal_error(type, response)}

  defp public_terminal_response("response.failed", response, %{} = error) do
    Map.put(response, "error", Map.delete(error, "type"))
  end

  defp public_terminal_response(_type, response, _error), do: response

  defp response_has_incomplete_tool_call?(%{"output" => output}) when is_list(output),
    do: Enum.any?(output, &incomplete_tool_call_item?/1)

  defp response_has_incomplete_tool_call?(_response), do: false

  defp output_limit_incomplete_response?(response),
    do: incomplete_response_reason(response) == "max_output_tokens"

  defp incomplete_response_reason(%{"incomplete_details" => %{"reason" => reason}})
       when is_binary(reason),
       do: reason

  defp incomplete_response_reason(_response), do: nil

  defp transient_incomplete_reason?(reason) do
    reason in [
      "upstream_stream_closed",
      "upstream_stream_closed_before_terminal_event",
      "provider_stream_closed_without_terminal"
    ]
  end

  defp incomplete_tool_call_item?(item), do: ResponseItems.incomplete_call?(item)

  defp account_tool_calls(state, event) do
    scope = budget_scope(state)

    policy = MaxToolCalls.observe_provider_event(state.max_tool_calls, event, scope)

    policy =
      case event do
        %{"type" => type, "response" => %{"output" => output}}
        when type in @terminal_event_types and is_list(output) ->
          public_output =
            case state.tool_loop do
              %StreamLoop{} = loop -> StreamLoop.rewrite_public_items(loop, output)
              _no_loop -> output
            end

          policy
          |> MaxToolCalls.reconcile_provider_items(public_output, scope)
          |> MaxToolCalls.admit_gateway_items(public_output, scope)

        _event ->
          policy
      end

    %{state | max_tool_calls: policy}
  end

  defp budget_scope(%{tool_loop: %StreamLoop{rounds: rounds}}), do: {:provider_round, rounds}
  defp budget_scope(_state), do: :single_response

  defp force_cancel(:continue), do: :continue
  defp force_cancel({:round, _continuation_request}), do: :continue
  defp force_cancel({:local, _jobs, _context}), do: :continue
  defp force_cancel({:terminal, outcome, _action}), do: {:terminal, outcome, :cancel_upstream}

  defp map_items(items) when is_list(items), do: Enum.filter(items, &is_map/1)
  defp map_items(_items), do: []

  # A multi-round public response accumulated items from every provider round;
  # the final provider terminal only carries the last round.
  defp terminal_public_items(%{tool_loop: %StreamLoop{rounds: rounds}} = state, terminal_items)
       when rounds > 0 do
    accumulated = chronological(state.public_items)
    terminal_by_id = Map.new(terminal_items, &{public_item_id(&1), &1}) |> Map.delete(nil)

    accumulated_ids =
      accumulated
      |> Enum.map(&public_item_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    merged =
      Enum.map(accumulated, fn item ->
        case public_item_id(item) do
          nil -> item
          id -> Map.get(terminal_by_id, id, item)
        end
      end)

    merged ++
      Enum.reject(terminal_items, fn item ->
        case public_item_id(item) do
          nil -> item in accumulated
          id -> MapSet.member?(accumulated_ids, id)
        end
      end)
  end

  defp terminal_public_items(state, terminal_items),
    do: terminal_items_or_accumulated(chronological(state.public_items), terminal_items)

  defp terminal_items_or_accumulated(accumulated, []), do: accumulated
  defp terminal_items_or_accumulated(_accumulated, terminal_items), do: terminal_items

  defp map_provider_output_index(state, %{"output_index" => upstream_index} = event)
       when is_integer(upstream_index) and upstream_index >= 0 do
    case Map.fetch(state.provider_output_indexes, upstream_index) do
      {:ok, public_index} ->
        {state, Map.put(event, "output_index", public_index)}

      :error ->
        public_index = state.next_output_index

        state = %{
          state
          | provider_output_indexes:
              Map.put(state.provider_output_indexes, upstream_index, public_index),
            next_output_index: public_index + 1
        }

        {state, Map.put(event, "output_index", public_index)}
    end
  end

  defp map_provider_output_index(state, event), do: {state, event}

  defp mapped_provider_output_index(state, %{"output_index" => upstream_index} = event)
       when is_integer(upstream_index) and upstream_index >= 0 do
    case Map.fetch(state.provider_output_indexes, upstream_index) do
      {:ok, public_index} -> {:ok, Map.put(event, "output_index", public_index)}
      :error -> :unadmitted_output
    end
  end

  defp mapped_provider_output_index(_state, event), do: {:ok, event}

  # Some Responses families use `id` as both the output-item identity and the
  # call/output pair identity. Allocate it once so the two namespaces cannot
  # drift apart.
  defp map_provider_item_identity(
         state,
         %{"item" => %{"id" => upstream_id} = item} = event
       )
       when is_binary(upstream_id) and upstream_id != "" do
    if ResponseItems.pair_identity_field(item) == "id" do
      map_provider_conflated_identity(state, event, item, upstream_id)
    else
      map_provider_item_and_pair_identity(state, event, item)
    end
  end

  defp map_provider_item_identity(state, %{"item" => %{} = item} = event),
    do: map_provider_item_and_pair_identity(state, event, item)

  defp map_provider_item_identity(state, event), do: {state, event}

  defp map_provider_conflated_identity(state, event, item, upstream_id) do
    {state, public_id} = provider_public_conflated_identity(state, upstream_id)
    {state, item} = map_program_caller(state, Map.put(item, "id", public_id))
    {state, put_in(event, ["item"], item)}
  end

  defp map_provider_item_and_pair_identity(state, event, item) do
    {state, item} = map_provider_item_id(state, item)
    {state, item} = map_round_pair_identity(state, item)
    {state, put_in(event, ["item"], item)}
  end

  defp map_provider_item_id(state, item) do
    case public_item_id(item) do
      nil ->
        {state, item}

      upstream_id ->
        {state, public_id} = provider_public_item_id(state, upstream_id)
        {state, Map.put(item, "id", public_id)}
    end
  end

  defp map_round_pair_identity(state, item) do
    {state, item} =
      map_pair_field(state, item, ResponseItems.pair_identity_field(item))

    map_program_caller(state, item)
  end

  defp map_pair_field(state, item, field) when is_binary(field) do
    case Map.get(item, field) do
      pair_id when is_binary(pair_id) and pair_id != "" ->
        {state, public_id} = provider_public_pair_id(state, pair_id)
        {state, Map.put(item, field, public_id)}

      _missing ->
        {state, item}
    end
  end

  defp map_pair_field(state, item, _field), do: {state, item}

  defp map_program_caller(
         state,
         %{"caller" => %{"type" => "program", "caller_id" => caller_id} = caller} = item
       )
       when is_binary(caller_id) and caller_id != "" do
    {state, public_id} = provider_public_pair_id(state, caller_id)
    {state, Map.put(item, "caller", Map.put(caller, "caller_id", public_id))}
  end

  defp map_program_caller(state, item), do: {state, item}

  defp mapped_provider_item_identity(state, %{"item_id" => upstream_id} = event)
       when is_binary(upstream_id) and upstream_id != "" do
    case Map.fetch(state.provider_item_ids, upstream_id) do
      {:ok, public_id} -> {:ok, Map.put(event, "item_id", public_id)}
      :error -> :unadmitted_item
    end
  end

  defp mapped_provider_item_identity(_state, event), do: {:ok, event}

  defp provider_public_item_id(state, upstream_id) do
    case Map.fetch(state.provider_item_ids, upstream_id) do
      {:ok, public_id} ->
        {state, public_id}

      :error ->
        public_id = available_public_item_id(state, upstream_id, :provider)

        state = %{
          state
          | provider_item_ids: Map.put(state.provider_item_ids, upstream_id, public_id),
            public_item_ids: MapSet.put(state.public_item_ids, public_id)
        }

        {state, public_id}
    end
  end

  defp provider_public_pair_id(state, upstream_id) do
    case Map.fetch(state.provider_pair_ids, upstream_id) do
      {:ok, public_id} ->
        {state, public_id}

      :error ->
        public_id = available_public_pair_id(state, upstream_id, 0)

        state = %{
          state
          | provider_pair_ids: Map.put(state.provider_pair_ids, upstream_id, public_id),
            public_pair_ids: MapSet.put(state.public_pair_ids, public_id)
        }

        {state, public_id}
    end
  end

  defp provider_public_conflated_identity(state, upstream_id) do
    public_id =
      Map.get(state.provider_item_ids, upstream_id) ||
        Map.get(state.provider_pair_ids, upstream_id) ||
        available_public_item_id(state, upstream_id, :provider)

    state = %{
      state
      | provider_item_ids: Map.put(state.provider_item_ids, upstream_id, public_id),
        provider_pair_ids: Map.put(state.provider_pair_ids, upstream_id, public_id),
        public_item_ids: MapSet.put(state.public_item_ids, public_id),
        public_pair_ids: MapSet.put(state.public_pair_ids, public_id)
    }

    {state, public_id}
  end

  defp register_local_item_identity(state, %{} = item) do
    {state, item} = map_round_pair_identity(state, item)

    case {ResponseItems.pair_identity_field(item), public_item_id(item)} do
      {"id", item_id} when is_binary(item_id) and item_id != "" ->
        {%{state | public_item_ids: MapSet.put(state.public_item_ids, item_id)}, item}

      {_field, nil} ->
        {state, item}

      {_field, item_id} ->
        public_id = available_public_item_id(state, item_id, :local)
        state = %{state | public_item_ids: MapSet.put(state.public_item_ids, public_id)}
        {state, Map.put(item, "id", public_id)}
    end
  end

  defp map_terminal_provider_items(state, items) do
    {items, state} =
      Enum.map_reduce(items, state, fn item, state ->
        {state, event} = map_provider_item_identity(state, %{"item" => item})
        {event["item"], state}
      end)

    {state, items}
  end

  defp available_public_item_id(state, item_id, source) do
    if public_identity_taken?(state, item_id) do
      unique_public_item_id(state, item_id, source, 0)
    else
      item_id
    end
  end

  defp unique_public_item_id(state, item_id, source, attempt) do
    round = if match?(%StreamLoop{}, state.tool_loop), do: state.tool_loop.rounds, else: 0

    digest =
      :crypto.hash(
        :sha256,
        "#{state.local_response_id}\0#{round}\0#{source}\0#{item_id}\0#{attempt}"
      )
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    candidate = "item_#{digest}"

    if public_identity_taken?(state, candidate),
      do: unique_public_item_id(state, item_id, source, attempt + 1),
      else: candidate
  end

  defp available_public_pair_id(state, pair_id, attempt) do
    if public_identity_taken?(state, pair_id) do
      unique_public_pair_id(state, pair_id, attempt)
    else
      pair_id
    end
  end

  defp unique_public_pair_id(state, pair_id, attempt) do
    round = if match?(%StreamLoop{}, state.tool_loop), do: state.tool_loop.rounds, else: 0

    digest =
      :crypto.hash(
        :sha256,
        "#{state.local_response_id}\0#{round}\0pair\0#{pair_id}\0#{attempt}"
      )
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    candidate = "call_#{digest}"

    if public_identity_taken?(state, candidate),
      do: unique_public_pair_id(state, pair_id, attempt + 1),
      else: candidate
  end

  defp public_identity_taken?(state, identity) do
    MapSet.member?(state.public_item_ids, identity) or
      MapSet.member?(state.public_pair_ids, identity)
  end

  defp public_item_id(%{"id" => item_id}) when is_binary(item_id) and item_id != "", do: item_id
  defp public_item_id(_item), do: nil

  defp begin_provider_round(state),
    do: %{
      state
      | provider_output_indexes: %{},
        provider_item_ids: %{},
        provider_pair_ids: %{},
        provider_error_diagnostic: nil
    }

  defp chronological(reversed_items), do: Enum.reverse(reversed_items)

  defp terminal_response_metadata(_state, _event_type, %{} = response) do
    %{}
    |> maybe_put_metadata("usage", response["usage"])
    |> maybe_put_metadata("tool_usage", response["tool_usage"])
    |> maybe_put_metadata("provider_model", response["model"])
    |> maybe_put_metadata("provider_metadata", provider_response_metadata(response))
    |> maybe_put_metadata("stop_reason", response_stop_reason(response))
    |> maybe_put_metadata("response", response_trace_metadata(response))
    |> maybe_put_metadata("incomplete_details", response["incomplete_details"])
  end

  defp provider_response_metadata(response) do
    Map.take(response, [
      "id",
      "object",
      "model",
      "status",
      "service_tier",
      "system_fingerprint"
    ])
  end

  defp response_trace_metadata(response) do
    Map.take(response, ["id", "object", "created_at", "completed_at", "status"])
  end

  defp response_stop_reason(%{"stop_reason" => stop_reason}) when is_binary(stop_reason),
    do: stop_reason

  defp response_stop_reason(%{"finish_reason" => finish_reason}) when is_binary(finish_reason),
    do: finish_reason

  defp response_stop_reason(%{"incomplete_details" => %{"reason" => reason}})
       when is_binary(reason),
       do: reason

  defp response_stop_reason(%{"status" => status}) when status in ["failed", "error"],
    do: "error"

  defp response_stop_reason(%{"output" => output}) when is_list(output) do
    if Enum.any?(output, &completed_tool_call_item?/1), do: "tool_use", else: "stop"
  end

  defp response_stop_reason(_response), do: "stop"

  defp completed_tool_call_item?(item),
    do: ResponseItems.call_item?(item) and ResponseItems.executable_call?(item)

  defp commit_stateful_terminal(nil, _items, _terminal_error, _terminal_metadata), do: :ok

  defp commit_stateful_terminal(stateful, items, nil, terminal_metadata) do
    case StatefulResponses.commit_complete(stateful.message_id, items, terminal_metadata) do
      {:ok, %{} = _message} ->
        :ok

      {:ok, :already_terminal} ->
        authoritative_stateful_terminal(stateful)

      {:error, reason} ->
        Logging.warning(
          "ai_gateway.response_stream.complete_commit_failed",
          "AIGateway response stream complete commit failed",
          %{message_id: stateful.message_id, reason: inspect(reason)}
        )

        commit_stateful_terminal_commit_failure(stateful, items, reason)
        {:error, reason}
    end
  end

  defp commit_stateful_terminal(stateful, items, error_details, terminal_metadata) do
    case StatefulResponses.commit_error(stateful.message_id, items, error_details,
           metadata: terminal_metadata
         ) do
      {:ok, %{} = _message} ->
        :ok

      {:ok, :already_terminal} ->
        authoritative_stateful_terminal(stateful)

      {:error, reason} ->
        Logging.warning(
          "ai_gateway.response_stream.error_commit_failed",
          "AIGateway response stream error commit failed",
          %{message_id: stateful.message_id, reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  defp authoritative_stateful_terminal(stateful) do
    response_id = stateful_response_id(stateful)

    subject_uid =
      case stateful do
        %{subject_uid: subject_uid} -> subject_uid
        %{message: %{subject_uid: subject_uid}} -> subject_uid
        _stateful -> nil
      end

    case StatefulLifecycle.retrieve_response(subject_uid, response_id) do
      {:ok, %{body: %{} = response}} -> {:already_terminal, response}
      {:error, reason} -> {:error, {:authoritative_terminal_unavailable, reason}}
    end
  end

  defp commit_stateful_terminal_commit_failure(stateful, items, _reason) do
    StatefulResponses.commit_error(
      stateful.message_id,
      items,
      %{
        "code" => "stateful_terminal_commit_failed",
        "message" => safe_error_message("stateful_terminal_commit_failed"),
        "stage" => "terminal_commit",
        "retryable" => false
      }
    )
  end

  defp commit_stateful_error(nil, _partial_content, _error_details), do: :ok

  defp commit_stateful_error(%{message_id: message_id}, partial_content, error_details) do
    error_details = Map.put_new(error_details, "stage", "response_stream_cleanup")

    case StatefulResponses.commit_error(message_id, partial_content, error_details) do
      {:ok, _message_or_terminal} ->
        :ok

      {:error, commit_reason} ->
        Logging.warning(
          "ai_gateway.response_stream.cleanup_commit_failed",
          "AIGateway response stream cleanup commit failed",
          %{message_id: message_id, reason: inspect(commit_reason)}
        )

        {:error, commit_reason}
    end
  end

  defp stateful_commit_failed_event(state, _reason, sequence_number) do
    response = %{
      "id" => stateful_response_id(state.stateful),
      "object" => "response",
      "status" => "failed",
      "error" => %{
        "code" => "stateful_commit_failed",
        "message" => safe_error_message("stateful_commit_failed"),
        "retryable" => false
      },
      "output" => []
    }

    %{"type" => "response.failed", "response" => response}
    |> maybe_put_sequence_number(sequence_number)
  end

  defp remember_provider_response_id(state, %{"response" => %{"id" => response_id}})
       when is_binary(response_id) do
    %{state | provider_response_id: state.provider_response_id || response_id}
  end

  defp remember_provider_response_id(state, %{"response_id" => response_id})
       when is_binary(response_id) do
    %{state | provider_response_id: state.provider_response_id || response_id}
  end

  defp remember_provider_response_id(state, _event), do: state

  defp rewrite_response_id(event, %{stateful: %{message_id: message_id}}) do
    new_id = "resp_#{message_id}"

    event
    |> rewrite_nested_response_id(new_id)
    |> rewrite_top_level_response_id(new_id)
  end

  defp rewrite_response_id(event, %{provider_response_id: response_id})
       when is_binary(response_id) do
    event
    |> rewrite_nested_response_id(response_id)
    |> rewrite_top_level_response_id(response_id)
  end

  defp rewrite_response_id(event, _state), do: event

  defp rewrite_nested_response_id(%{"response" => %{}} = event, new_id),
    do: put_in(event, ["response", "id"], new_id)

  defp rewrite_nested_response_id(event, _new_id), do: event

  defp rewrite_top_level_response_id(%{"response_id" => response_id} = event, new_id)
       when is_binary(response_id),
       do: Map.put(event, "response_id", new_id)

  defp rewrite_top_level_response_id(event, _new_id), do: event

  defp cleanup_response_id(%{stateful: %{message_id: message_id}}), do: "resp_#{message_id}"

  defp cleanup_response_id(%{provider_response_id: response_id}) when is_binary(response_id),
    do: response_id

  defp cleanup_response_id(%{local_response_id: response_id}) when is_binary(response_id),
    do: response_id

  defp cleanup_response_id(_state), do: nil

  defp stateful_response_id(%{message_id: message_id}), do: "resp_#{message_id}"
  defp stateful_response_id(_stateful), do: nil

  defp stateful_message_id(%{message_id: message_id}), do: message_id
  defp stateful_message_id(_stateful), do: nil

  defp safe_error_message(code) do
    %{"code" => code}
    |> FailureDiagnostics.classify()
    |> FailureDiagnostics.public_message()
  end

  defp public_sequence_number(%{"sequence_number" => sequence}, _fallback)
       when is_integer(sequence),
       do: sequence

  defp public_sequence_number(_event, fallback), do: fallback

  defp next_sequence_number(%{sequence_number: sequence}) when is_integer(sequence),
    do: sequence + 1

  defp next_sequence_number(_state), do: nil

  defp maybe_put_sequence_number(event, nil), do: event

  defp maybe_put_sequence_number(event, sequence_number),
    do: Map.put(event, "sequence_number", sequence_number)

  defp maybe_put_metadata(map, _key, nil), do: map

  defp maybe_put_metadata(map, _key, value) when is_map(value) and map_size(value) == 0,
    do: map

  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp remember_provider_error(%{provider_error_diagnostic: %{} = _diagnostic} = state, _event),
    do: state

  defp remember_provider_error(state, event) do
    diagnostic =
      {:provider_event_failed, event}
      |> FailureDiagnostics.classify()
      |> Map.take([
        :provider_error_code,
        :provider_error_type,
        :provider_message
      ])

    if map_size(diagnostic) == 0,
      do: state,
      else: %{state | provider_error_diagnostic: diagnostic}
  end

  defp correlate_provider_error(
         %{} = error,
         %{provider_error_diagnostic: %{} = diagnostic}
       ) do
    case FailureDiagnostics.classify(error) do
      %{failure_kind: :transport} ->
        error
        |> Map.put("failure_kind", "transport")
        |> maybe_put_metadata("message", Map.get(diagnostic, :provider_message))
        |> maybe_put_metadata("provider_error_code", Map.get(diagnostic, :provider_error_code))
        |> maybe_put_metadata("provider_error_type", Map.get(diagnostic, :provider_error_type))

      _non_transport ->
        error
    end
  end

  defp correlate_provider_error(error, _state), do: error

  defp put_safe_failure_fields(details, classification) do
    classification
    |> Map.take([
      :error_stage,
      :failure_kind,
      :http_status,
      :provider_error_code,
      :provider_error_type,
      :provider_status
    ])
    |> Enum.reduce(details, fn
      {:failure_kind, value}, acc -> Map.put(acc, "failure_kind", Atom.to_string(value))
      {key, value}, acc -> Map.put(acc, Atom.to_string(key), value)
    end)
  end

  defp publish(%{stateful: %{message: %{} = message}}, type, payload),
    do: Events.publish(message, type, payload)

  defp publish(_state, _type, _payload), do: :ok

  defp tool_activity_payload(item, seq) do
    item
    |> Map.take(["type", "id", "call_id", "namespace", "name", "status", "output", "action"])
    |> maybe_put_payload("seq", seq)
  end

  defp tool_activity_item?(%{"type" => type} = item) when is_binary(type) do
    ResponseItems.call_item?(item) or type == "mcp_list_tools" or
      String.ends_with?(type, "_call")
  end

  defp tool_activity_item?(_item), do: false

  defp maybe_put_payload(payload, _key, nil), do: payload
  defp maybe_put_payload(payload, key, value), do: Map.put(payload, key, value)
end
