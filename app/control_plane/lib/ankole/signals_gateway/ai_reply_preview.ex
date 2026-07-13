defmodule Ankole.SignalsGateway.AIReplyPreview do
  @moduledoc """
  Subscribes to one generic AIGateway conversation and renders IM previews.

  Lifecycle:
    1. `maybe_start_for/3` is called immediately before a real worker turn is
       dispatched, after its AIGateway conversation is known.
    2. The handler subscribes to generic conversation-scoped AIGateway events
       and filters opaque metadata in SignalsGateway.
    3. On first `:output_text_delta` or tool activity event, it sends an
       initial IM preview message.
    4. On subsequent deltas, it throttles IM edits (~1s flush); tool activity
       updates are edited immediately.
    5. On `:response_started`, clear the per-round delta buffer while keeping
       the existing provider preview handle.
    6. Response terminal events never imply that the Agent turn is terminal.
       Only explicit Actor lifecycle handlers stop the preview.
    7. Durable terminal delivery is owned by outbox; the transient handler
       remains available across long model calls and retryable execution loss.
  """

  use GenServer, restart: :temporary

  alias Ankole.AIGateway.Events
  alias Ankole.I18n
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.ScheduledTurn
  alias Ankole.Logging
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.AIReplyText
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxAdapter
  alias Ankole.SignalsGateway.OutboxEntry

  # How long to wait between IM edit flushes (milliseconds).
  @edit_flush_interval_ms 1_000

  @im_visible_event_types ~w(im.message.addressed im.message.may_intervene command.new command.steer check_back_later.wakeup cron.fire subagent.delegation.completed subagent.delegation.failed subagent.delegation.waiting)

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Starts one preview handler for a dispatched Actor turn.
  """
  @spec maybe_start_for(ActorEvent.t(), String.t(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def maybe_start_for(%ActorEvent{} = event, subject_uid, conversation_id)
      when is_binary(subject_uid) and is_binary(conversation_id) do
    if im_visible_event?(event) do
      name = via_tuple(event.id)

      case DynamicSupervisor.start_child(
             Ankole.SignalsGateway.PreviewSupervisor,
             {__MODULE__, {event, subject_uid, conversation_id, name}}
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

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

  @doc false
  def start_link({%ActorEvent{} = event, subject_uid, conversation_id, name}) do
    GenServer.start_link(__MODULE__, {event, subject_uid, conversation_id}, name: name)
  end

  @doc """
  Returns the via-tuple for registry-based process naming.
  """
  def via_tuple(actor_event_id) do
    {:via, Registry, {Ankole.SignalsGateway.PreviewRegistry, actor_event_id}}
  end

  @doc """
  Stops the preview owned by an explicit Actor lifecycle transition.
  """
  @spec stop(Ecto.UUID.t()) :: :ok
  def stop(actor_event_id) when is_binary(actor_event_id) do
    case Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event_id) do
      [{pid, _value}] ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _reason -> :ok
        end

      [] ->
        :ok
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # GenServer callbacks
  # ─────────────────────────────────────────────────────────────────

  @impl GenServer
  def init({%ActorEvent{} = event, subject_uid, conversation_id}) do
    case Events.subscribe(subject_uid, conversation_id) do
      :ok -> :ok
      {:error, reason} -> raise "cannot subscribe AI reply preview: #{inspect(reason)}"
    end

    # Schedule periodic edit flush.
    Process.send_after(self(), :flush_edit, @edit_flush_interval_ms)

    state = %{
      actor_event: event,
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      # Accumulated text from deltas for the current preview round.
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
      silent_success_allowed: ScheduledTurn.silent_success_allowed?(event)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:ai_gateway_event, event_type, event}, state) when is_map(event) do
    if event_matches_actor?(event, state) do
      handle_gateway_event(event_type, map_value(event, :payload) || %{}, state)
    else
      {:noreply, state}
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
  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_gateway_event(:response_started, _payload, state) do
    {:noreply, reset_for_response_started(state)}
  end

  defp handle_gateway_event(:output_text_delta, payload, state) do
    delta = map_value(payload, :text)

    if is_binary(delta) do
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
            %{state | dirty: true}
        end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp handle_gateway_event(:tool_call_started, payload, state) do
    {:noreply, handle_tool_activity(state, :started, payload)}
  end

  defp handle_gateway_event(:tool_call_completed, payload, state) do
    {:noreply, handle_tool_activity(state, :completed, payload)}
  end

  defp handle_gateway_event(event_type, _payload, state)
       when event_type in [:response_completed, :response_failed, :response_incomplete],
       do: {:noreply, state}

  defp handle_gateway_event(_event_type, _payload, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = Events.unsubscribe(state.subject_uid, state.conversation_id)
    :ok
  end

  defp reset_for_response_started(state) do
    Map.merge(state, %{text_buffer: "", dirty: false})
  end

  defp handle_tool_activity(%{silent_success_allowed: true} = state, _stage, _payload),
    do: state

  defp handle_tool_activity(state, stage, payload) when is_map(payload) do
    call_id = normalize_optional_text(payload[:call_id] || payload["call_id"])
    name = tool_activity_name(payload, call_id, state.tool_calls)
    tool_calls = remember_tool_call(state.tool_calls, call_id, name)
    text = tool_activity_text(stage, name)

    state
    |> Map.put(:tool_calls, tool_calls)
    |> upsert_preview_text(text, "tool-#{stage}")
  end

  defp handle_tool_activity(state, _stage, _payload), do: state

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
      payload[:name] || payload["name"] || payload[:tool] || payload["tool"] ||
        payload[:type] || payload["type"]
    ) ||
      tool_name_from_output(payload[:output] || payload["output"]) ||
      if(is_binary(call_id), do: Map.get(tool_calls, call_id)) ||
      call_id ||
      "tool"
  end

  defp tool_name_from_output(%{"tool" => tool}), do: normalize_optional_text(tool)
  defp tool_name_from_output(%{tool: tool}), do: normalize_optional_text(tool)
  defp tool_name_from_output(_output), do: nil

  defp tool_activity_text(:started, name) do
    I18n.t("signals_gateway.reply.tool_call_started", %{"tool" => truncate_tool_name(name)})
  end

  defp tool_activity_text(:completed, name) do
    I18n.t("signals_gateway.reply.tool_call_completed", %{"tool" => truncate_tool_name(name)})
  end

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
         :ok <- Actors.record_reply_preview_source_entry(event.id, entry_id) do
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

  defp next_edit_key(state, prefix) do
    edit_sequence = state.edit_sequence + 1
    {edit_sequence, "#{prefix}:#{edit_sequence}"}
  end

  defp preview_fields(state, extra) do
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

  defp event_matches_actor?(event, state) do
    metadata = map_value(event, :metadata) || %{}

    map_value(event, :subject_uid) == state.subject_uid and
      map_value(event, :conversation_id) == state.conversation_id and
      map_value(metadata, :actor_event_id) == state.actor_event.id
  end

  defp map_value(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
