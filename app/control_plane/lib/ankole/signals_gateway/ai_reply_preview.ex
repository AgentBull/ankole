defmodule Ankole.SignalsGateway.AIReplyPreview do
  @moduledoc """
  Subscribes to AIGateway live events for an actor event and renders IM
  preview/edit/finalize through the SignalsGateway adapter.

  Lifecycle:
    1. `maybe_start_for/1` is called post-commit after an actor event is created.
       If the binding/channel needs IM-visible AI reply, a preview handler is
       started under DynamicSupervisor, registered by actor_event_id.
    2. The handler subscribes to `ai_gateway:actor_event:{actor_event_id}` PubSub.
    3. On first `:output_text_delta`, it sends an initial IM preview message.
    4. On subsequent deltas, it throttles IM edits (~1s flush).
    5. On `:response_completed`:
       - If the response contains function_call → continue (not the final round).
       - If no function_call → finalize: replace preview with durable content,
         write signal_entries mirror with ai_message_id.
    6. On `:response_failed` → send error reply or delete preview.
    7. Timeout: if no terminal event arrives within the handler's lifetime,
       it self-terminates. Recovery scan picks up the orphaned terminal row.
  """

  use GenServer, restart: :temporary

  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors.ActorEvent
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxAdapter
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.SignalEntry

  require Logger

  # How long to wait between IM edit flushes (milliseconds).
  @edit_flush_interval_ms 1_000

  # Handler lifetime cap (5 minutes). If no terminal event arrives, the handler
  # self-terminates and recovery scan picks up the row.
  @max_lifetime_ms 5 * 60 * 1_000

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
    # Only start if this event has a signal channel (IM-visible path).
    if event.signal_channel_id &&
         event.type in ~w(im.message.addressed im.message.may_intervene check_back_later.wakeup cron.fire) do
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

    # Set lifetime cap.
    Process.send_after(self(), :lifetime_expired, @max_lifetime_ms)

    # Schedule periodic edit flush.
    Process.send_after(self(), :flush_edit, @edit_flush_interval_ms)

    state = %{
      actor_event: event,
      # Accumulated text from deltas (for preview + finalize).
      text_buffer: "",
      # The provider message id for the current preview (nil = no preview sent yet).
      preview_entry_id: nil,
      # The last message_id from response_completed (for finalize).
      final_message_id: nil,
      # Whether the preview has been established (first delta → send IM).
      preview_established: false,
      # Dirty flag for edit flush.
      dirty: false
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:ai_gateway_live, :output_text_delta, %{text: delta}}, state) do
    new_buffer = state.text_buffer <> delta

    state =
      if not state.preview_established do
        # First text delta → establish preview.
        case establish_preview(state.actor_event, new_buffer) do
          {:ok, entry_id} ->
            %{
              state
              | text_buffer: new_buffer,
                preview_entry_id: entry_id,
                preview_established: true,
                dirty: false
            }

          {:error, reason} ->
            Logger.warning("AIReplyPreview: failed to establish preview: #{inspect(reason)}")
            %{state | text_buffer: new_buffer}
        end
      else
        # Subsequent delta → mark dirty for flush.
        %{state | text_buffer: new_buffer, dirty: true}
      end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:ai_gateway_event, :response_completed, message_id, payload}, state) do
    content = payload[:content] || []

    if contains_function_call?(content) do
      # Intermediate round — wait for the next round.
      {:noreply, %{state | final_message_id: message_id}}
    else
      # Final round — finalize the IM reply.
      finalize_reply(state, message_id, payload)
    end
  end

  @impl GenServer
  def handle_info({:ai_gateway_event, :response_failed, _message_id, %{error: error}}, state) do
    Logger.info(
      "AIReplyPreview: response failed for actor_event #{state.actor_event.id}: #{inspect(error)}"
    )

    # Phase 1: error rows are not IM-visible by default (policy).
    # The preview handler simply terminates.
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(:flush_edit, state) do
    state =
      if state.dirty && state.preview_established && state.preview_entry_id do
        case edit_preview(state.actor_event, state.preview_entry_id, state.text_buffer) do
          :ok ->
            %{state | dirty: false}

          {:error, reason} ->
            Logger.debug("AIReplyPreview: edit failed (best-effort): #{inspect(reason)}")
            %{state | dirty: false}
        end
      else
        state
      end

    # Reschedule flush.
    Process.send_after(self(), :flush_edit, @edit_flush_interval_ms)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:lifetime_expired, state) do
    Logger.info(
      "AIReplyPreview: lifetime expired for actor_event #{state.actor_event.id}, terminating"
    )

    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  # ─────────────────────────────────────────────────────────────────
  # IM interaction helpers (reuse OutboxAdapter)
  # ─────────────────────────────────────────────────────────────────

  # Sends the initial preview message to the provider.
  defp establish_preview(%ActorEvent{} = event, text) do
    with {:ok, result} <- send_new_reply(event, text, nil, "ai-preview:#{event.id}:initial"),
         entry_id when is_binary(entry_id) <- created_source_entry_id(result) do
      {:ok, entry_id}
    else
      nil -> {:error, :preview_entry_id_missing}
      {:error, _reason} = error -> error
      :unknown -> {:error, :provider_send_unknown}
      other -> {:error, {:unexpected_preview_result, other}}
    end
  end

  # Edits the existing preview message with updated text.
  defp edit_preview(%ActorEvent{} = event, entry_id, text) do
    case deliver_outbox(event, :edit, text,
           target_source_entry_id: entry_id,
           outbound_key: "ai-preview:#{event.id}:edit:#{entry_id}",
           idempotency_key: "ai-preview:#{event.id}:edit:#{entry_id}"
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
      :unknown -> {:error, :provider_send_unknown}
    end
  end

  # Finalizes the reply: replaces preview with durable content and writes mirror.
  defp finalize_reply(state, message_id, payload) do
    %ActorEvent{} = event = state.actor_event
    content = payload[:content] || []
    text = visible_text(content) || state.text_buffer

    # Flush any remaining buffered text first.
    state = flush_pending(state)

    result =
      case state.preview_entry_id do
        entry_id when is_binary(entry_id) ->
          with :ok <- edit_preview(event, entry_id, text),
               :ok <- mirror_final_reply(event, message_id, text, source_entry_id: entry_id) do
            :ok
          end

        _no_preview ->
          deliver_and_mirror_final_reply(event, message_id, text)
      end

    case result do
      :ok ->
        Logger.info(
          "AIReplyPreview: finalized reply for actor_event #{event.id}, message #{message_id}"
        )

      {:error, reason} ->
        Logger.warning(
          "AIReplyPreview: final reply delivery failed for actor_event #{event.id}, message #{message_id}: #{inspect(Sanitizer.transport(reason), limit: 20)}"
        )
    end

    {:stop, :normal, state}
  end

  defp flush_pending(state) do
    if state.dirty && state.preview_entry_id do
      edit_preview(state.actor_event, state.preview_entry_id, state.text_buffer)
    end

    %{state | dirty: false}
  end

  # ─────────────────────────────────────────────────────────────────
  # Mirror helper (shared by live finalize + recovery scan + outbox)
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Sends a final reply if needed and records the `signal_entries.ai_message_id`
  mirror only after provider delivery succeeds. Recovery scan calls this for
  terminal rows whose live preview handler died before final delivery.
  """
  @spec deliver_and_mirror_final_reply(ActorEvent.t(), Message.t() | binary(), String.t()) ::
          :ok | {:error, term()}
  def deliver_and_mirror_final_reply(%ActorEvent{} = event, %Message{id: message_id}, text),
    do: deliver_and_mirror_final_reply(event, message_id, text)

  def deliver_and_mirror_final_reply(%ActorEvent{} = event, message_id, text)
      when is_binary(message_id) do
    with text when is_binary(text) and text != "" <- normalize_text(text),
         {:ok, result} <- send_new_reply(event, text, message_id, "ai-reply:#{message_id}"),
         source_entry_id <- created_source_entry_id(result) || "ai-reply:#{message_id}" do
      mirror_final_reply(event, message_id, text,
        source_entry_id: source_entry_id,
        raw_payload: raw_payload(result)
      )
    else
      "" -> {:error, :empty_final_reply_text}
      {:error, _reason} = error -> error
      :unknown -> {:error, :provider_send_unknown}
    end
  end

  @doc """
  Writes the final reply mirror into signal_entries with ai_message_id.

  Called after a successful IM send/edit to record that the final reply
  for this ai_gateway_messages row has been delivered to the provider.
  This is the durable marker that recovery scan checks.
  """
  @spec mirror_final_reply(ActorEvent.t(), binary(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def mirror_final_reply(%ActorEvent{} = event, ai_message_id, text, opts \\ []) do
    now = DateTime.utc_now(:microsecond)
    source_entry_id = Keyword.get(opts, :source_entry_id) || "ai-reply:#{ai_message_id}"
    raw_payload = Keyword.get(opts, :raw_payload, %{}) |> Sanitizer.transport()

    attrs = %{
      signal_channel_id: event.signal_channel_id,
      source_entry_id: source_entry_id,
      text: text,
      fallback_visible_text: text,
      formatted_content: %{},
      attachments: [],
      links: [],
      author: %{"agent_uid" => event.agent_uid},
      mentions: [],
      metadata: %{
        "ai_message_id" => ai_message_id,
        "actor_event_id" => event.id,
        "source" => "ai_gateway_final_reply"
      },
      raw_payload: raw_payload,
      document_id: source_entry_id,
      search_text: text,
      first_seen_at: now,
      last_seen_at: now,
      ai_message_id: ai_message_id
    }

    case %SignalEntry{}
         |> SignalEntry.changeset(attrs)
         |> Repo.insert(
           on_conflict:
             {:replace,
              [
                :text,
                :fallback_visible_text,
                :metadata,
                :raw_payload,
                :search_text,
                :last_seen_at,
                :ai_message_id,
                :updated_at
              ]},
           conflict_target: [:signal_channel_id, :source_entry_id]
         ) do
      {:ok, _entry} -> :ok
      {:error, _changeset} = error -> error
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Adapter resolution
  # ─────────────────────────────────────────────────────────────────

  defp send_new_reply(%ActorEvent{} = event, text, ai_message_id, idempotency_key) do
    with text when is_binary(text) and text != "" <- normalize_text(text),
         {:ok, operation} <- Outbox.outbox_operation_for_actor_input(event) do
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
    with {:ok, binding} <- binding_for_event(event),
         {:ok, adapter_module} <- outbox_module_for_adapter(binding.adapter) do
      OutboxAdapter.normalize(adapter_module)
    end
  end

  defp binding_for_event(%ActorEvent{} = event) do
    Ankole.SignalsGateway.get_binding(event.agent_uid, event.binding_name)
  end

  defp outbox_module_for_adapter(adapter_id) do
    case Process.whereis(Ankole.Plugins.Registry) do
      nil ->
        {:error, :plugin_registry_not_started}

      _pid ->
        "signals_gateway.adapter"
        |> Ankole.Plugins.adapter_declarations()
        |> Enum.find(fn declaration ->
          declaration[:id] == adapter_id or declaration["id"] == adapter_id
        end)
        |> case do
          %{outbox_module: module} when is_atom(module) -> {:ok, module}
          %{"outbox_module" => module} when is_atom(module) -> {:ok, module}
          _declaration -> {:error, {:outbox_adapter_not_found, adapter_id}}
        end
    end
  end

  defp created_source_entry_id(result) when is_map(result) do
    optional_text(result, :created_source_entry_id) ||
      optional_text(result, "created_source_entry_id")
  end

  defp raw_payload(result) when is_map(result),
    do: Map.get(result, :raw_payload) || Map.get(result, "raw_payload") || result

  defp normalize_text(text) when is_binary(text), do: String.trim(text)
  defp normalize_text(_text), do: ""

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

  defp visible_text(items) when is_list(items) do
    items
    |> Enum.flat_map(&visible_text_parts/1)
    |> Enum.join("")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp visible_text(_items), do: nil

  defp visible_text_parts(%{"type" => "message", "content" => content}) when is_list(content),
    do: Enum.flat_map(content, &visible_text_parts/1)

  defp visible_text_parts(%{"type" => type, "text" => text})
       when type in ["output_text", "text"] and is_binary(text),
       do: [text]

  defp visible_text_parts(%{"content" => text}) when is_binary(text), do: [text]
  defp visible_text_parts(_item), do: []

  defp contains_function_call?(items) when is_list(items),
    do: Enum.any?(items, &match?(%{"type" => "function_call"}, &1))

  defp contains_function_call?(_items), do: false
end
