defmodule Ankole.SignalsGateway.AIReplyPreview do
  @moduledoc """
  Subscribes to AIGateway live events for an actor event and renders IM
  preview/edit/finalize through the SignalsGateway adapter.

  Lifecycle:
    1. `maybe_start_for/1` is called post-commit after an actor event is created.
       If the binding/channel needs IM-visible AI reply, a preview handler is
       started under DynamicSupervisor, registered by actor_event_id.
    2. The handler subscribes to `ai_gateway:actor_event:{actor_event_id}` PubSub.
    3. On first `:output_text_delta` or tool activity event, it sends an
       initial IM preview message.
    4. On subsequent deltas, it throttles IM edits (~1s flush); tool activity
       updates are edited immediately.
    5. On `:response_started`, clear the per-round delta buffer while keeping
       the existing provider preview handle.
    6. On `:response_completed`:
       - If the response contains function_call → continue (not the final round).
       - Otherwise stop; the AIGateway terminal commit writes the durable
         final-reply outbox.
    7. On `:response_failed`, retryable errors or still-open actor events keep
       the handler alive for retry/fallback output; terminal non-retryable
       failures terminate the handler and leave any command feedback or recovery
       path to the owning runtime.
    8. Timeout: if no live activity arrives within the handler's lifetime,
       it self-terminates. Durable terminal delivery is owned by outbox.
  """

  use GenServer, restart: :temporary

  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Actors.ActorEvent
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.AIReplyText
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxAdapter
  alias Ankole.SignalsGateway.OutboxEntry

  # How long to wait between IM edit flushes (milliseconds).
  @edit_flush_interval_ms 1_000

  # Handler idle lifetime cap (5 minutes). Live response activity resets this
  # timer; durable terminal delivery is owned by outbox.
  @max_lifetime_ms 5 * 60 * 1_000
  @im_visible_event_types ~w(im.message.addressed im.message.may_intervene command.new command.steer check_back_later.wakeup cron.fire subagent.delegation.completed subagent.delegation.failed subagent.delegation.waiting)

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Starts a preview handler for an actor event if it needs IM-visible AI reply.

  Called post-commit after the actor event is created. The handler subscribes
  to AIGateway PubSub events for this actor_event_id.
  """
  @spec maybe_start_for(ActorEvent.t()) :: :ok | {:error, term()}
  def maybe_start_for(%ActorEvent{} = event) do
    if im_visible_event?(event) do
      # Register by actor_event_id to prevent duplicate handlers.
      name = via_tuple(event.id)

      case DynamicSupervisor.start_child(
             Ankole.SignalsGateway.PreviewSupervisor,
             {__MODULE__, {event, name}}
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @doc false
  @spec maybe_start_result_handlers(map() | term()) :: boolean()
  def maybe_start_result_handlers(result) when is_map(result) do
    events = preview_actor_events(result)
    Enum.each(events, &maybe_start_result_handler/1)
    events != []
  end

  def maybe_start_result_handlers(_result), do: false

  @doc """
  Returns true when an actor event can produce an IM-visible AI reply.

  This predicate keeps preview/final-reply delivery narrower than generic actor
  events: explicit command feedback and other provider-visible side effects
  continue to use the outbox path instead.
  """
  @spec im_visible_event?(ActorEvent.t()) :: boolean()
  def im_visible_event?(%ActorEvent{} = event) do
    not is_nil(event.signal_channel_id) and
      event.type in @im_visible_event_types
  end

  @doc false
  def im_visible_event_types, do: @im_visible_event_types

  defp preview_actor_events(result) when is_map(result) do
    ([Map.get(result, :actor_event)] ++ Map.get(result, :finalized_actor_events, []))
    |> Enum.filter(&match?(%ActorEvent{}, &1))
    |> Enum.uniq_by(& &1.id)
  end

  defp maybe_start_result_handler(%ActorEvent{} = event) do
    case maybe_start_for(event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logging.debug(
          "signals_gateway.ai_reply_preview.start_skipped",
          "signals gateway preview handler start skipped",
          actor_event_fields(event, %{reason: inspect(reason)})
        )

        :ok
    end
  end

  @doc false
  def start_link({%ActorEvent{} = event, name}) do
    GenServer.start_link(__MODULE__, event, name: name)
  end

  @doc """
  Returns the via-tuple for registry-based process naming.
  """
  def via_tuple(actor_event_id) do
    {:via, Registry, {Ankole.SignalsGateway.PreviewRegistry, actor_event_id}}
  end

  # ─────────────────────────────────────────────────────────────────
  # GenServer callbacks
  # ─────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(%ActorEvent{} = event) do
    # Subscribe to AIGateway live events for this actor event.
    StatefulResponses.subscribe(event.id)

    # Set idle lifetime cap.
    {lifetime_ref, lifetime_timer} = schedule_lifetime_timer()

    # Schedule periodic edit flush.
    Process.send_after(self(), :flush_edit, @edit_flush_interval_ms)

    state = %{
      actor_event: event,
      # Accumulated text from deltas (for preview + finalize).
      text_buffer: "",
      # Current provider-visible preview text. Tool activity can update this
      # before assistant text exists; final durability still comes from
      # response content or text_buffer.
      preview_text: "",
      # Maps function call ids to provider tool names for later tool results.
      tool_calls: %{},
      # The provider message id for the current preview (nil = no preview sent yet).
      preview_entry_id: nil,
      # Whether the preview has been established (first delta → send IM).
      preview_established: false,
      # Monotonic key segment for best-effort preview edits.
      edit_sequence: 0,
      # Dirty flag for edit flush.
      dirty: false,
      lifetime_ref: lifetime_ref,
      lifetime_timer: lifetime_timer,
      silent_success_allowed: AIReplyText.silent_success_allowed?(event)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:ai_gateway_event, :response_started, _message_id, _payload}, state) do
    {:noreply, reset_for_response_started(state)}
  end

  @impl GenServer
  def handle_info({:ai_gateway_live, :response_started, _payload}, state) do
    {:noreply, reset_for_response_started(state)}
  end

  @impl GenServer
  def handle_info({:ai_gateway_live, :output_text_delta, %{text: delta}}, state) do
    state = reset_lifetime_timer(state)
    new_buffer = state.text_buffer <> delta
    preview_text = AIReplyText.normalize_visible_text(new_buffer)
    state = %{state | text_buffer: new_buffer, preview_text: preview_text}

    state =
      cond do
        state.silent_success_allowed and AIReplyText.silent_success_marker_prefix?(new_buffer) ->
          state

        not state.preview_established ->
          if preview_text == "" do
            state
          else
            case establish_preview(state.actor_event, preview_text) do
              {:ok, entry_id} ->
                %{
                  state
                  | preview_entry_id: entry_id,
                    preview_established: true,
                    dirty: false
                }

              {:error, reason} ->
                Logging.warning(
                  "signals_gateway.ai_reply_preview.establish_failed",
                  "AI reply preview establish failed",
                  preview_fields(state, %{reason: inspect(reason)})
                )

                state
            end
          end

        true ->
          # Subsequent delta → mark dirty for flush.
          %{state | dirty: true}
      end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:ai_gateway_live, :tool_call_started, payload}, state) do
    {:noreply, handle_tool_activity(state, :started, payload)}
  end

  @impl GenServer
  def handle_info({:ai_gateway_live, :tool_call_completed, payload}, state) do
    {:noreply, handle_tool_activity(state, :completed, payload)}
  end

  @impl GenServer
  def handle_info({:ai_gateway_event, :response_completed, message_id, payload}, state) do
    content = payload[:content] || []

    if contains_function_call?(content) do
      # Intermediate round — wait for the next round.
      {:noreply, state}
    else
      # Final round — finalize the IM reply.
      finalize_reply(state, message_id, payload)
    end
  end

  @impl GenServer
  def handle_info({:ai_gateway_event, :response_failed, message_id, %{error: error}}, state) do
    Logging.info(
      "signals_gateway.ai_reply_preview.response_failed",
      "AI reply preview response failed",
      preview_fields(state, %{
        message_id: message_id,
        error: inspect(error)
      })
    )

    if retryable_response_error?(error) or actor_event_open?(state.actor_event.id) do
      {:noreply, reset_lifetime_timer(state)}
    else
      # Error rows are not IM-visible by default; the preview handler simply
      # terminates.
      {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_info(:flush_edit, state) do
    text = AIReplyText.normalize_visible_text(state.preview_text)

    state =
      if (text != "" and state.dirty) && state.preview_established && state.preview_entry_id do
        {edit_sequence, edit_key} = next_edit_key(state, "flush")

        case edit_preview(state.actor_event, state.preview_entry_id, text, edit_key) do
          :ok ->
            %{state | dirty: false, edit_sequence: edit_sequence}

          {:error, reason} ->
            Logging.debug(
              "signals_gateway.ai_reply_preview.edit_failed",
              "AI reply preview edit failed",
              preview_fields(state, %{
                preview_entry_id: state.preview_entry_id,
                edit_key: edit_key,
                edit_sequence: edit_sequence,
                reason: inspect(reason)
              })
            )

            %{state | dirty: false, edit_sequence: edit_sequence}
        end
      else
        state
      end

    # Reschedule flush.
    Process.send_after(self(), :flush_edit, @edit_flush_interval_ms)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:lifetime_expired, lifetime_ref}, %{lifetime_ref: lifetime_ref} = state) do
    Logging.info(
      "signals_gateway.ai_reply_preview.lifetime_expired",
      "AI reply preview lifetime expired",
      preview_fields(state)
    )

    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({:lifetime_expired, _stale_ref}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  defp reset_for_response_started(state) do
    state
    |> reset_lifetime_timer()
    |> Map.merge(%{text_buffer: "", dirty: false})
  end

  defp schedule_lifetime_timer do
    lifetime_ref = make_ref()
    timer = Process.send_after(self(), {:lifetime_expired, lifetime_ref}, @max_lifetime_ms)
    {lifetime_ref, timer}
  end

  defp reset_lifetime_timer(state) do
    _cancelled = Process.cancel_timer(state.lifetime_timer, async: true, info: false)
    {lifetime_ref, lifetime_timer} = schedule_lifetime_timer()
    %{state | lifetime_ref: lifetime_ref, lifetime_timer: lifetime_timer}
  end

  defp handle_tool_activity(%{silent_success_allowed: true} = state, _stage, _payload),
    do: reset_lifetime_timer(state)

  defp handle_tool_activity(state, stage, payload) when is_map(payload) do
    state = reset_lifetime_timer(state)
    call_id = normalize_optional_text(payload[:call_id] || payload["call_id"])
    name = tool_activity_name(payload, call_id, state.tool_calls)
    tool_calls = remember_tool_call(state.tool_calls, call_id, name)
    text = tool_activity_text(stage, name)

    state
    |> Map.put(:tool_calls, tool_calls)
    |> upsert_preview_text(text, "tool-#{stage}")
  end

  defp handle_tool_activity(state, _stage, _payload), do: reset_lifetime_timer(state)

  defp upsert_preview_text(state, text, edit_prefix) do
    case AIReplyText.normalize_visible_text(text) do
      "" ->
        state

      preview_text ->
        state = %{state | preview_text: preview_text}

        cond do
          not state.preview_established ->
            case establish_preview(state.actor_event, preview_text) do
              {:ok, entry_id} ->
                %{state | preview_entry_id: entry_id, preview_established: true, dirty: false}

              {:error, reason} ->
                Logging.warning(
                  "signals_gateway.ai_reply_preview.establish_failed",
                  "AI reply preview establish failed",
                  preview_fields(state, %{reason: inspect(reason)})
                )

                state
            end

          is_binary(state.preview_entry_id) ->
            {edit_sequence, edit_key} = next_edit_key(state, edit_prefix)

            case edit_preview(state.actor_event, state.preview_entry_id, preview_text, edit_key) do
              :ok ->
                %{state | dirty: false, edit_sequence: edit_sequence}

              {:error, reason} ->
                Logging.debug(
                  "signals_gateway.ai_reply_preview.tool_activity_edit_failed",
                  "AI reply preview tool activity edit failed",
                  preview_fields(state, %{
                    preview_entry_id: state.preview_entry_id,
                    edit_key: edit_key,
                    edit_sequence: edit_sequence,
                    reason: inspect(reason)
                  })
                )

                %{state | dirty: false, edit_sequence: edit_sequence}
            end

          true ->
            state
        end
    end
  end

  defp remember_tool_call(tool_calls, call_id, name) when is_binary(call_id) and is_binary(name),
    do: Map.put(tool_calls, call_id, name)

  defp remember_tool_call(tool_calls, _call_id, _name), do: tool_calls

  defp tool_activity_name(payload, call_id, tool_calls) do
    normalize_optional_text(
      payload[:name] || payload["name"] || payload[:tool] || payload["tool"]
    ) ||
      tool_name_from_output(payload[:output] || payload["output"]) ||
      if(is_binary(call_id), do: Map.get(tool_calls, call_id)) ||
      call_id ||
      "tool"
  end

  defp tool_name_from_output(%{"tool" => tool}), do: normalize_optional_text(tool)
  defp tool_name_from_output(%{tool: tool}), do: normalize_optional_text(tool)
  defp tool_name_from_output(_output), do: nil

  defp tool_activity_text(:started, name), do: "Calling tool: #{truncate_tool_name(name)}"

  defp tool_activity_text(:completed, name),
    do: "Finished tool: #{truncate_tool_name(name)}. Reading results."

  defp tool_activity_text(_stage, name), do: "Working with tool: #{truncate_tool_name(name)}"

  defp truncate_tool_name(name) do
    name = normalize_optional_text(name) || "tool"

    if String.length(name) > 80 do
      String.slice(name, 0, 77) <> "..."
    else
      name
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # IM interaction helpers (reuse OutboxAdapter)
  # ─────────────────────────────────────────────────────────────────

  # Sends the initial preview message to the provider.
  defp establish_preview(%ActorEvent{} = event, text) do
    with {:ok, result} <- send_new_reply(event, text, nil, "ai-preview:#{event.id}:initial"),
         entry_id when is_binary(entry_id) <- created_source_entry_id(result),
         :ok <- StatefulResponses.record_preview_source_entry(event.id, entry_id) do
      {:ok, entry_id}
    else
      nil -> {:error, :preview_entry_id_missing}
      {:error, _reason} = error -> error
      :unknown -> {:error, :provider_send_unknown}
      other -> {:error, {:unexpected_preview_result, other}}
    end
  end

  # Edits the existing preview message with updated text.
  defp edit_preview(%ActorEvent{} = event, entry_id, text, edit_key) do
    key = "ai-preview:#{event.id}:edit:#{entry_id}:#{edit_key}"

    case deliver_outbox(event, :edit, text,
           target_source_entry_id: entry_id,
           outbound_key: key,
           idempotency_key: key
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
      :unknown -> {:error, :provider_send_unknown}
    end
  end

  # Terminal delivery is durable outbox-owned. The preview process only stops.
  defp finalize_reply(state, message_id, _payload) do
    Logging.info(
      "signals_gateway.ai_reply_preview.terminal_observed",
      "AI reply preview terminal event observed",
      preview_fields(state, %{message_id: message_id})
    )

    {:stop, :normal, state}
  end

  defp next_edit_key(state, prefix) do
    edit_sequence = state.edit_sequence + 1
    {edit_sequence, "#{prefix}:#{edit_sequence}"}
  end

  defp preview_fields(state, extra \\ %{}) do
    actor_event_fields(state.actor_event, extra)
  end

  defp actor_event_fields(%ActorEvent{} = event, extra) do
    %{
      actor_event_id: event.id,
      agent_uid: event.agent_uid,
      binding_name: event.binding_name
    }
    |> Map.merge(extra)
  end

  # ─────────────────────────────────────────────────────────────────
  # Adapter resolution
  # ─────────────────────────────────────────────────────────────────

  defp send_new_reply(%ActorEvent{} = event, text, ai_message_id, idempotency_key) do
    with text when is_binary(text) and text != "" <- normalize_text(text),
         {:ok, operation} <- Outbox.outbox_operation_for_actor_event(event) do
      deliver_outbox(event, operation, text,
        ai_message_id: ai_message_id,
        outbound_key: idempotency_key,
        idempotency_key: idempotency_key
      )
    else
      "" -> {:error, :empty_reply_text}
      {:error, _reason} = error -> error
    end
  end

  defp deliver_outbox(%ActorEvent{} = event, operation, text, opts) do
    with {:ok, adapter} <- adapter_for_event(event) do
      event
      |> transient_outbox(operation, text, opts)
      |> then(&OutboxAdapter.deliver(adapter, &1))
    end
  end

  defp transient_outbox(%ActorEvent{} = event, operation, text, opts) do
    %OutboxEntry{
      agent_uid: event.agent_uid,
      binding_name: event.binding_name,
      outbound_key: Keyword.fetch!(opts, :outbound_key),
      operation: operation,
      signal_channel_id: event.signal_channel_id,
      provider_thread_id: event.provider_thread_id,
      reply_to_source_entry_id: if(operation == :reply, do: event.source_entry_id),
      target_source_entry_id: Keyword.get(opts, :target_source_entry_id),
      # Source table: preview side effects are caused by this actor_events.id.
      source_actor_event_id: event.id,
      ai_message_id: Keyword.get(opts, :ai_message_id),
      payload: %{},
      fallback_visible_text: text,
      idempotency_key: Keyword.fetch!(opts, :idempotency_key),
      attempt_count: 0,
      max_attempts: 1,
      last_error: %{},
      recovery_state: %{}
    }
  end

  defp adapter_for_event(%ActorEvent{} = event) do
    with {:ok, binding} <- binding_for_event(event) do
      Adapters.fetch_outbox(binding.adapter)
    end
  end

  defp binding_for_event(%ActorEvent{} = event) do
    Ankole.SignalsGateway.get_binding(event.agent_uid, event.binding_name)
  end

  defp created_source_entry_id(result) when is_map(result) do
    optional_text(result, :created_source_entry_id) ||
      optional_text(result, "created_source_entry_id")
  end

  defp normalize_text(text), do: AIReplyText.normalize_visible_text(text)

  defp normalize_optional_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_text(_text), do: nil

  defp optional_text(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  defp contains_function_call?(items) when is_list(items),
    do: Enum.any?(items, &match?(%{"type" => "function_call"}, &1))

  defp contains_function_call?(_items), do: false

  defp retryable_response_error?(%{"retryable" => true}), do: true
  defp retryable_response_error?(_error), do: false

  defp actor_event_open?(actor_event_id) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{completed_at: nil} -> true
      %ActorEvent{} -> false
      nil -> false
    end
  end
end
