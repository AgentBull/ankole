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
    8. A lifecycle stop checkpoints the latest renderer-safe semantic projection
       before outbox takes over, even when the last provider update is still dirty.
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
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias Ankole.Repo

  # How long to wait between IM edit flushes (milliseconds).
  @edit_flush_interval_ms 1_000
  @cardkit_flush_interval_ms 250
  @cardkit_creation_debounce_ms 350
  @cardkit_retry_max_ms 30_000
  @terminal_handoff_timeout_ms 5_000

  @im_visible_event_types ~w(im.message.addressed im.message.may_intervene signal.action.invoked command.new command.steer check_back_later.wakeup cron.fire background_agent_job.completed background_agent_job.failed background_agent_job.waiting)

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
        GenServer.cast(pid, :stop)

      [] ->
        :ok
    end
  end

  @doc false
  @spec presentation_event(Ecto.UUID.t(), map()) :: :ok
  def presentation_event(actor_event_id, event)
      when is_binary(actor_event_id) and is_map(event) do
    case Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event_id) do
      [{pid, _value}] -> GenServer.cast(pid, {:presentation_event, event})
      [] -> :ok
    end
  end

  @doc false
  @spec recover(Ecto.UUID.t()) :: :ok | {:error, term()}
  def recover(actor_event_id) when is_binary(actor_event_id) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{reply_preview_checkpoint: %{"refresh_pending" => true}} = event ->
        refresh_checkpoint(event)

      %ActorEvent{
        input_state: "open",
        completed_at: nil,
        reply_preview_checkpoint: %{
          "subject_uid" => subject_uid,
          "conversation_id" => conversation_id
        }
      } = event
      when is_binary(subject_uid) and is_binary(conversation_id) ->
        maybe_start_for(event, subject_uid, conversation_id)

      %ActorEvent{} ->
        {:error, :reply_preview_not_recoverable}

      nil ->
        {:error, :actor_event_not_found}
    end
  end

  @doc false
  @spec cleanup_due(Ecto.UUID.t()) :: :ok | {:error, term()}
  def cleanup_due(actor_event_id) when is_binary(actor_event_id) do
    now = DateTime.utc_now(:microsecond)

    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{reply_preview_cleanup_at: %DateTime{} = due_at} = event ->
        if DateTime.compare(due_at, now) in [:lt, :eq] do
          cleanup_due_event(event)
        else
          {:error, :reply_preview_cleanup_not_due}
        end

      %ActorEvent{} ->
        {:error, :reply_preview_cleanup_not_due}

      nil ->
        {:error, :actor_event_not_found}
    end
  end

  defp cleanup_due_event(%ActorEvent{} = event) do
    case Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, event.id) do
      [{pid, _value}] ->
        GenServer.cast(pid, :cleanup_thought)
        :ok

      [] ->
        with {:ok, _event} <- mark_cleanup_refresh_pending(event.id),
             :ok <- recover(event.id) do
          :ok
        end
    end
  end

  defp mark_cleanup_refresh_pending(actor_event_id) do
    Repo.transact(fn repo ->
      case Actors.lock_actor_event_in_tx(repo, actor_event_id) do
        %ActorEvent{reply_preview_checkpoint: checkpoint} = event when is_map(checkpoint) ->
          checkpoint =
            checkpoint
            |> Map.delete("cleanup_at")
            |> Map.put("refresh_pending", true)
            |> Map.put("refresh_reason", "thought_cleanup")

          Actors.put_reply_preview_checkpoint_in_tx(repo, event, checkpoint)

        %ActorEvent{} ->
          {:error, :reply_preview_not_recoverable}

        nil ->
          {:error, :actor_event_not_found}
      end
    end)
  end

  defp refresh_checkpoint(%ActorEvent{} = event) do
    checkpoint = event.reply_preview_checkpoint || %{}

    with {:ok, binding} <- binding_for_event(event),
         {:ok, adapter} <- Adapters.fetch_reply_preview(binding.adapter) do
      presentation =
        checkpoint["presentation"]
        |> ReplyPresentation.normalize()
        |> ReplyPresentation.project_trigger(event.type, event.payload)

      ReplyPreviewAdapter.refresh(adapter, %Request{
        actor_event: event,
        subject_uid: checkpoint["subject_uid"],
        conversation_id: checkpoint["conversation_id"],
        presentation: presentation,
        previous_presentation: checkpoint["previous_presentation"],
        checkpoint: checkpoint,
        mode: if(ReplyPresentation.terminal_state?(presentation), do: :terminal, else: :working)
      })
      |> case do
        {:ok, _result} -> :ok
        {:error, _reason} = error -> error
      end
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

    rich_adapter = rich_adapter_for_event(event)
    rich? = match?(%ReplyPreviewAdapter{}, rich_adapter)
    checkpoint = event.reply_preview_checkpoint || %{}

    presentation =
      checkpoint
      |> Map.get("presentation")
      |> ReplyPresentation.normalize()
      |> ReplyPresentation.project_trigger(event.type, event.payload)

    initial_flush_ms =
      cond do
        not rich? -> @edit_flush_interval_ms
        map_size(checkpoint) > 0 -> 0
        true -> @cardkit_creation_debounce_ms
      end

    Process.send_after(self(), :flush_edit, initial_flush_ms)

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
      # A provider rejection while establishing or editing disables this
      # best-effort preview for the rest of the turn. Durable terminal output
      # still uses the outbox path.
      preview_disabled: false,
      # Monotonic key segment for best-effort preview edits.
      edit_sequence: 0,
      # Dirty flag for edit flush.
      dirty: rich? and map_size(checkpoint) > 0,
      reply_preview_adapter: rich_adapter,
      presentation: presentation,
      last_synced_presentation: checkpoint["presentation"],
      rich_task: nil,
      rich_task_presentation: nil,
      rich_retry_ms: 1_000,
      rich_retry_at: nil,
      stopping: false,
      terminal_handoff_timer: nil,
      silent_success_allowed: ScheduledTurn.silent_success_allowed?(event),
      # Worker phase and tool events arrive before a quiet scheduled turn can
      # choose `<silent_success/>`. Do not let those events open a visible card.
      silent_rich_pending:
        rich? and ScheduledTurn.silent_success_allowed?(event) and map_size(checkpoint) == 0
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast(:stop, state) do
    state
    |> ensure_terminal_handoff_timer()
    |> Map.merge(%{stopping: true, rich_retry_at: nil})
    |> settle_rich_stop()
  end

  def handle_cast(:cleanup_thought, %{reply_preview_adapter: %ReplyPreviewAdapter{}} = state) do
    presentation = Map.delete(state.presentation, "thought")
    {:noreply, %{state | presentation: presentation, dirty: true}}
  end

  def handle_cast(:cleanup_thought, state), do: {:noreply, state}

  def handle_cast(
        {:presentation_event, _event},
        %{reply_preview_adapter: %ReplyPreviewAdapter{}, silent_rich_pending: true} = state
      ),
      do: {:noreply, state}

  def handle_cast(
        {:presentation_event, event},
        %{reply_preview_adapter: %ReplyPreviewAdapter{}} = state
      ) do
    kind = map_value(event, :kind) || map_value(event, :type)
    payload = map_value(event, :payload) || event

    presentation =
      if (is_binary(kind) or is_atom(kind)) and is_map(payload) do
        ReplyPresentation.apply_event(state.presentation, kind, payload)
      else
        state.presentation
      end

    {:noreply, mark_rich_dirty(state, presentation)}
  end

  def handle_cast({:presentation_event, _event}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:ai_gateway_event, event_type, event}, state) when is_map(event) do
    if event_matches_actor?(event, state) do
      handle_gateway_event(event_type, map_value(event, :payload) || %{}, state)
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:flush_edit, %{stopping: true} = state) do
    case settle_rich_stop(state) do
      {:noreply, _state} = result ->
        Process.send_after(self(), :flush_edit, @cardkit_flush_interval_ms)
        result

      {:stop, _reason, _state} = result ->
        result
    end
  end

  def handle_info(:flush_edit, state) do
    if match?(%ReplyPreviewAdapter{}, state.reply_preview_adapter) do
      state = maybe_start_rich_sync(state)
      Process.send_after(self(), :flush_edit, @cardkit_flush_interval_ms)
      {:noreply, state}
    else
      handle_legacy_flush(state)
    end
  end

  def handle_info({ref, result}, %{rich_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = finish_rich_sync(state, result)

    if state.stopping do
      settle_after_terminal_sync(state, result)
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{rich_task: %Task{ref: ref}} = state) do
    result = {:error, {:reply_preview_task_exit, reason}}
    state = finish_rich_sync(state, result)

    if state.stopping do
      settle_after_terminal_sync(state, result)
    else
      {:noreply, state}
    end
  end

  def handle_info(:terminal_handoff_timeout, %{stopping: true} = state) do
    Logging.warning(
      "signals_gateway.ai_reply_preview.terminal_handoff_timeout",
      "AI reply preview exceeded the terminal handoff deadline",
      preview_fields(state, %{})
    )

    shutdown_rich_task_now(state.rich_task)

    state
    |> Map.merge(%{
      rich_task: nil,
      rich_task_presentation: nil,
      dirty: false,
      terminal_handoff_timer: nil
    })
    |> finish_rich_stop()
  end

  def handle_info(:terminal_handoff_timeout, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_legacy_flush(state) do
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

            disable_preview_after_edit_failure(state, edit_sequence)
        end
      else
        state
      end

    # Reschedule flush.
    Process.send_after(self(), :flush_edit, @edit_flush_interval_ms)
    {:noreply, state}
  end

  defp handle_gateway_event(:response_started, _payload, state) do
    {:noreply, reset_for_response_started(state)}
  end

  defp handle_gateway_event(:output_text_delta, payload, state) do
    delta = map_value(payload, :text)

    if is_binary(delta) do
      new_buffer = state.text_buffer <> delta
      preview_text = AIReplyText.normalize_visible_text(new_buffer)
      state = %{state | text_buffer: new_buffer, preview_text: preview_text}

      if state.silent_success_allowed and
           AIReplyText.silent_success_marker_prefix?(new_buffer) do
        {:noreply, state}
      else
        if match?(%ReplyPreviewAdapter{}, state.reply_preview_adapter) do
          presentation = ReplyPresentation.append_answer(state.presentation, delta)

          {:noreply,
           state
           |> Map.put(:silent_rich_pending, false)
           |> mark_rich_dirty(presentation)}
        else
          handle_legacy_output_delta(state, new_buffer, preview_text)
        end
      end
    else
      {:noreply, state}
    end
  end

  defp handle_gateway_event(:reasoning_delta, payload, state) do
    if match?(%ReplyPreviewAdapter{}, state.reply_preview_adapter) and
         not state.silent_rich_pending do
      presentation = ReplyPresentation.apply_event(state.presentation, "reasoning.delta", payload)
      {:noreply, mark_rich_dirty(state, presentation)}
    else
      {:noreply, state}
    end
  end

  defp handle_gateway_event(:tool_call_started, payload, state) do
    if match?(%ReplyPreviewAdapter{}, state.reply_preview_adapter) do
      {:noreply, state}
    else
      {:noreply, handle_tool_activity(state, :started, payload)}
    end
  end

  defp handle_gateway_event(:tool_call_completed, payload, state) do
    if match?(%ReplyPreviewAdapter{}, state.reply_preview_adapter) do
      {:noreply, state}
    else
      {:noreply, handle_tool_activity(state, :completed, payload)}
    end
  end

  defp handle_gateway_event(event_type, _payload, state)
       when event_type in [:response_completed, :response_failed, :response_incomplete],
       do: {:noreply, state}

  defp handle_gateway_event(_event_type, _payload, state), do: {:noreply, state}

  defp handle_legacy_output_delta(state, new_buffer, preview_text) do
    state =
      cond do
        state.silent_success_allowed and AIReplyText.silent_success_marker_prefix?(new_buffer) ->
          state

        state.preview_disabled ->
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

                %{state | preview_disabled: true}
            end
          end

        true ->
          %{state | dirty: true}
      end

    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    shutdown_rich_task(state.rich_task)
    _ = Events.unsubscribe(state.subject_uid, state.conversation_id)
    :ok
  end

  defp reset_for_response_started(state) do
    state = Map.merge(state, %{text_buffer: "", dirty: false})

    if match?(%ReplyPreviewAdapter{}, state.reply_preview_adapter) and
         not state.silent_rich_pending do
      presentation =
        state.presentation
        |> ReplyPresentation.replace_answer("")
        |> Map.delete("thought")

      mark_rich_dirty(state, presentation)
    else
      state
    end
  end

  defp mark_rich_dirty(state, presentation) do
    if presentation == state.presentation do
      state
    else
      %{state | presentation: presentation, dirty: true}
    end
  end

  defp maybe_start_rich_sync(%{dirty: true, rich_task: nil, preview_disabled: false} = state) do
    if rich_retry_due?(state.rich_retry_at) do
      presentation = state.presentation

      request = %Request{
        actor_event: state.actor_event,
        subject_uid: state.subject_uid,
        conversation_id: state.conversation_id,
        presentation: presentation,
        previous_presentation: state.last_synced_presentation,
        checkpoint: state.actor_event.reply_preview_checkpoint,
        mode: :working
      }

      adapter = state.reply_preview_adapter

      task =
        Task.Supervisor.async_nolink(
          Ankole.SignalsGateway.PreviewTaskSupervisor,
          fn -> ReplyPreviewAdapter.update(adapter, request) end
        )

      %{
        state
        | dirty: false,
          rich_task: task,
          rich_task_presentation: presentation,
          rich_retry_at: nil
      }
    else
      state
    end
  end

  defp maybe_start_rich_sync(state), do: state

  defp finish_rich_sync(state, {:ok, result}) when is_map(result) do
    checkpoint =
      Map.get(result, :reply_preview_checkpoint) ||
        Map.get(result, "reply_preview_checkpoint") ||
        state.actor_event.reply_preview_checkpoint

    entry_id = created_source_entry_id(result) || state.preview_entry_id

    actor_event =
      if is_map(checkpoint) do
        %{state.actor_event | reply_preview_checkpoint: checkpoint}
      else
        state.actor_event
      end

    %{
      state
      | actor_event: actor_event,
        last_synced_presentation: state.rich_task_presentation,
        rich_task: nil,
        rich_task_presentation: nil,
        rich_retry_ms: 1_000,
        rich_retry_at: nil,
        preview_entry_id: entry_id,
        preview_established: is_binary(entry_id),
        dirty:
          state.dirty or
            presentation_revision(state.presentation) >
              presentation_revision(state.rich_task_presentation)
    }
  end

  defp finish_rich_sync(state, {:error, reason}) do
    retry? = rich_retryable?(reason)

    Logging.warning(
      "signals_gateway.ai_reply_preview.cardkit_sync_failed",
      "AI reply CardKit sync failed",
      preview_fields(state, %{reason: inspect(reason, limit: 20), retry: retry?})
    )

    if retry? do
      retry_ms = min(state.rich_retry_ms * 2, @cardkit_retry_max_ms)

      %{
        state
        | rich_task: nil,
          rich_task_presentation: nil,
          dirty: true,
          rich_retry_at: System.monotonic_time(:millisecond) + state.rich_retry_ms,
          rich_retry_ms: retry_ms
      }
    else
      %{
        state
        | rich_task: nil,
          rich_task_presentation: nil,
          dirty: false,
          preview_disabled: true
      }
    end
  end

  defp finish_rich_sync(state, result),
    do: finish_rich_sync(state, {:error, {:invalid_reply_preview_sync_result, result}})

  defp rich_retryable?({:reply_delivery, :operator_action_required, _error}), do: false
  defp rich_retryable?({:cardkit_plain_text_fallback, _error}), do: false
  defp rich_retryable?(:cardkit_replacement_exhausted), do: false
  defp rich_retryable?(_reason), do: true

  defp rich_retry_due?(nil), do: true

  defp rich_retry_due?(retry_at) when is_integer(retry_at),
    do: System.monotonic_time(:millisecond) >= retry_at

  defp presentation_revision(presentation) when is_map(presentation),
    do: Map.get(presentation, "revision", 0)

  defp presentation_revision(_presentation), do: 0

  defp checkpoint_latest_rich_presentation(
         %{
           reply_preview_adapter: %ReplyPreviewAdapter{},
           silent_rich_pending: false
         } = state
       ) do
    latest_presentation = ReplyPresentation.checkpoint(state.presentation)

    Repo.transact(fn repo ->
      case Actors.lock_actor_event_in_tx(repo, state.actor_event.id) do
        %ActorEvent{} = event ->
          checkpoint = event.reply_preview_checkpoint || %{}
          stored_checkpoint = checkpoint["presentation"]
          stored_presentation = ReplyPresentation.normalize(stored_checkpoint)

          if not is_map(stored_checkpoint) or
               presentation_revision(latest_presentation) >
                 presentation_revision(stored_presentation) do
            checkpoint =
              checkpoint
              |> Map.put_new("subject_uid", state.subject_uid)
              |> Map.put_new("conversation_id", state.conversation_id)
              |> Map.put("presentation", latest_presentation)

            Actors.put_reply_preview_checkpoint_in_tx(repo, event, checkpoint)
          else
            {:ok, event}
          end

        nil ->
          {:error, :actor_event_not_found}
      end
    end)
    |> case do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "signals_gateway.ai_reply_preview.checkpoint_before_stop_failed",
          "AI reply preview could not checkpoint its latest presentation before stopping",
          preview_fields(state, %{reason: inspect(reason, limit: 20)})
        )
    end
  end

  defp checkpoint_latest_rich_presentation(_state), do: :ok

  # A normal Actor lifecycle stop is also the ownership handoff from the
  # transient preview to the durable terminal outbox. Give one in-flight
  # mutation a bounded chance to settle. On failure or timeout, checkpoint the
  # latest semantic projection and let the durable terminal mutation supersede
  # it with a higher CardKit sequence; retrying transient work indefinitely here
  # would leave an accepted message stuck on a working card forever.
  defp settle_rich_stop(
         %{
           reply_preview_adapter: %ReplyPreviewAdapter{},
           silent_rich_pending: false,
           preview_disabled: false
         } = state
       ) do
    state = maybe_start_rich_sync(state)

    case {state.rich_task, state.dirty} do
      {%Task{}, _dirty} -> {:noreply, state}
      {nil, true} -> {:noreply, state}
      {nil, false} -> finish_rich_stop(state)
    end
  end

  defp settle_rich_stop(state), do: finish_rich_stop(state)

  defp settle_after_terminal_sync(state, {:ok, result}) when is_map(result),
    do: settle_rich_stop(state)

  defp settle_after_terminal_sync(state, _failed_result), do: finish_rich_stop(state)

  defp finish_rich_stop(state) do
    cancel_terminal_handoff_timer(state.terminal_handoff_timer)
    checkpoint_latest_rich_presentation(state)

    {:stop, :normal,
     %{
       state
       | rich_task: nil,
         rich_task_presentation: nil,
         dirty: false,
         terminal_handoff_timer: nil
     }}
  end

  defp ensure_terminal_handoff_timer(%{terminal_handoff_timer: nil} = state) do
    timer = Process.send_after(self(), :terminal_handoff_timeout, @terminal_handoff_timeout_ms)
    %{state | terminal_handoff_timer: timer}
  end

  defp ensure_terminal_handoff_timer(state), do: state

  defp cancel_terminal_handoff_timer(nil), do: :ok

  defp cancel_terminal_handoff_timer(timer) do
    Process.cancel_timer(timer, async: true, info: false)
    :ok
  end

  defp shutdown_rich_task(%Task{} = task) do
    _ = Task.shutdown(task, 5_000)
    :ok
  end

  defp shutdown_rich_task(_task), do: :ok

  defp shutdown_rich_task_now(%Task{} = task) do
    _ = Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp shutdown_rich_task_now(_task), do: :ok

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
          state.preview_disabled ->
            state

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

                %{state | preview_disabled: true}
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

                disable_preview_after_edit_failure(state, edit_sequence)
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
    with {:ok, result} <- send_new_reply(event, text, nil, "ai-preview:#{event.id}"),
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

  defp disable_preview_after_edit_failure(state, edit_sequence) do
    %{
      state
      | dirty: false,
        edit_sequence: edit_sequence,
        preview_disabled: true
    }
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

  defp rich_adapter_for_event(%ActorEvent{} = event) do
    with {:ok, binding} <- binding_for_event(event),
         {:ok, adapter} <- Adapters.fetch_reply_preview(binding.adapter) do
      adapter
    else
      _unavailable -> nil
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
