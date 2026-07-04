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
    5. On `:response_started`, clear the per-round delta buffer while keeping
       the existing provider preview handle.
    6. On `:response_completed`:
       - If the response contains function_call → continue (not the final round).
       - If visible final text exists → finalize by editing or sending the
         durable reply, then mirror it with `ai_message_id`.
       - If visible final text is empty → terminate without sending an empty
         provider edit or writing a mirror.
    7. On `:response_failed`, retryable errors keep the handler alive for the
       retry; non-retryable failures terminate the handler and leave any command
       feedback or recovery path to the owning runtime.
    8. Timeout: if no live activity arrives within the handler's lifetime,
       it self-terminates. Recovery scan picks up the orphaned terminal row.
  """

  use GenServer, restart: :temporary

  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Actors.ActorEvent
  alias Ankole.Repo
  alias Ankole.SignalsGateway.AIReplyText
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxAdapter
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.SignalEntry

  require Logger

  # How long to wait between IM edit flushes (milliseconds).
  @edit_flush_interval_ms 1_000

  # Handler idle lifetime cap (5 minutes). Live response activity resets this
  # timer; if the handler goes quiet, recovery scan picks up any terminal row.
  @max_lifetime_ms 5 * 60 * 1_000
  @im_visible_event_types ~w(im.message.addressed im.message.may_intervene command.new command.steer check_back_later.wakeup cron.fire)

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

  This predicate is shared by the live preview handler and recovery scan. Keep
  it narrower than generic actor events: explicit command feedback and other
  provider-visible side effects continue to use the outbox path instead.
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
        Logger.debug("signals_gateway preview handler start skipped: #{inspect(reason)}")
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
    state = %{state | text_buffer: new_buffer}

    state =
      cond do
        state.silent_success_allowed and AIReplyText.silent_success_marker_prefix?(new_buffer) ->
          state

        not state.preview_established ->
          preview_text = AIReplyText.normalize_visible_text(new_buffer)

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
                Logger.warning("AIReplyPreview: failed to establish preview: #{inspect(reason)}")
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
  def handle_info({:ai_gateway_event, :response_failed, _message_id, %{error: error}}, state) do
    Logger.info(
      "AIReplyPreview: response failed for actor_event #{state.actor_event.id}: #{inspect(error)}"
    )

    if retryable_response_error?(error) do
      {:noreply, state}
    else
      # Error rows are not IM-visible by default; the preview handler simply
      # terminates.
      {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_info(:flush_edit, state) do
    text = AIReplyText.normalize_visible_text(state.text_buffer)

    state =
      if (text != "" and state.dirty) && state.preview_established && state.preview_entry_id do
        {edit_sequence, edit_key} = next_edit_key(state, "flush")

        case edit_preview(state.actor_event, state.preview_entry_id, text, edit_key) do
          :ok ->
            %{state | dirty: false, edit_sequence: edit_sequence}

          {:error, reason} ->
            Logger.debug("AIReplyPreview: edit failed (best-effort): #{inspect(reason)}")
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
    Logger.info(
      "AIReplyPreview: lifetime expired for actor_event #{state.actor_event.id}, terminating"
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

  # Finalizes the reply: replaces preview with durable content and writes mirror.
  defp finalize_reply(state, message_id, payload) do
    %ActorEvent{} = event = state.actor_event
    content = payload[:content] || []

    text =
      AIReplyText.visible_text(content) || AIReplyText.normalize_visible_text(state.text_buffer)

    # Flush any remaining buffered text first.
    state = flush_pending(state)

    result =
      cond do
        text == "" ->
          :ok

        is_binary(state.preview_entry_id) ->
          entry_id = state.preview_entry_id

          with :ok <- edit_preview(event, entry_id, text, "final:#{message_id}"),
               :ok <- mirror_final_reply(event, message_id, text, source_entry_id: entry_id) do
            :ok
          end

        true ->
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
    text = normalize_text(state.text_buffer)

    if state.dirty && state.preview_entry_id && text != "" do
      {edit_sequence, edit_key} = next_edit_key(state, "flush")
      edit_preview(state.actor_event, state.preview_entry_id, text, edit_key)
      %{state | dirty: false, edit_sequence: edit_sequence}
    else
      %{state | dirty: false}
    end
  end

  defp next_edit_key(state, prefix) do
    edit_sequence = state.edit_sequence + 1
    {edit_sequence, "#{prefix}:#{edit_sequence}"}
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
         source_entry_id when is_binary(source_entry_id) <- created_source_entry_id(result) do
      mirror_final_reply(event, message_id, text,
        source_entry_id: source_entry_id,
        raw_payload: raw_payload(result)
      )
    else
      "" -> {:error, :empty_final_reply_text}
      nil -> {:error, :final_reply_entry_id_missing}
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
    with source_entry_id when is_binary(source_entry_id) <- source_entry_id(opts),
         text when is_binary(text) and text != "" <- normalize_text(text) do
      now = DateTime.utc_now(:microsecond)
      raw_payload = Keyword.get(opts, :raw_payload, %{}) |> Sanitizer.transport()
      author = %{"agent_uid" => event.agent_uid}

      metadata = %{
        "ai_message_id" => ai_message_id,
        "actor_event_id" => event.id,
        "source" => "ai_gateway_final_reply",
        "provider_thread_id" => event.provider_thread_id
      }

      metadata = Enum.reject(metadata, fn {_key, value} -> is_nil(value) end) |> Map.new()

      metadata_text =
        Projection.entry_metadata_text(%{
          author: author,
          metadata: metadata,
          channel_name: nil,
          channel_title: nil
        })

      attrs = %{
        signal_channel_id: event.signal_channel_id,
        source_entry_id: source_entry_id,
        text: text,
        fallback_visible_text: text,
        formatted_content: %{},
        attachments: [],
        links: [],
        author: author,
        mentions: [],
        metadata: metadata,
        raw_payload: raw_payload,
        document_id: Projection.entry_document_id(event.signal_channel_id, source_entry_id),
        search_text: text,
        metadata_text: metadata_text,
        content_hash: Projection.entry_content_hash([text, metadata_text, %{}, [], []]),
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
                  :document_id,
                  :search_text,
                  :metadata_text,
                  :content_hash,
                  :last_seen_at,
                  :ai_message_id,
                  :updated_at
                ]},
             conflict_target: [:signal_channel_id, :source_entry_id]
           ) do
        {:ok, _entry} -> :ok
        {:error, _changeset} = error -> error
      end
    else
      nil -> {:error, :final_reply_entry_id_missing}
      "" -> {:error, :empty_final_reply_text}
    end
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

  defp source_entry_id(opts), do: normalize_optional_text(Keyword.get(opts, :source_entry_id))

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
end
