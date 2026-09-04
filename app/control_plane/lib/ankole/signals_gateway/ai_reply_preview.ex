defmodule Ankole.SignalsGateway.AIReplyPreview do
  @moduledoc """
  Subscribes to one generic AIGateway conversation and renders live reply
  previews for a Signal channel.

  Lifecycle:
    1. `maybe_start_for/3` is called immediately before a real worker turn is
       dispatched, after its AIGateway conversation is known.
    2. The handler subscribes to generic conversation-scoped AIGateway events
       and filters opaque metadata in SignalsGateway.
    3. On first `:output_text_delta` or tool activity event, it sends an
       initial provider preview message.
    4. On subsequent deltas, it throttles provider edits (~1s flush); tool
       activity updates are edited immediately.
    5. On `:response_started`, clear the per-round delta buffer while keeping
       the existing provider preview handle.
    6. Response terminal events never imply that the Agent turn is terminal.
       Only explicit Actor lifecycle handlers stop the preview.
    7. Durable terminal delivery is owned by outbox; the transient handler
       remains available across long model calls and retryable execution loss.
    8. A lifecycle stop checkpoints the latest renderer-safe semantic
       projection before outbox takes over, even when the last provider update
       is still dirty.
  """

  use GenServer, restart: :temporary

  import Ecto.Query

  alias Ankole.AIGateway.Events
  alias Ankole.I18n
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.ScheduledTurn
  alias Ankole.Logging
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.AIReplyText
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxAdapter
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.Utils
  alias Ankole.SignalsGateway.ReplyPreviewAdapter
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias Ankole.Repo

  # Throttle plain-text edits to avoid provider rate limits.
  @edit_flush_interval_ms 1_000
  # Throttle rich updates because they use slower provider-native APIs.
  @rich_flush_interval_ms 1_000
  # Avoid an empty provider message while the first rich content takes shape.
  @rich_creation_debounce_ms 350
  # Keep rich-preview recovery responsive after repeated temporary failures.
  @rich_retry_max_ms 30_000

  # These event types can use a Turn's AI output as a reply to a Signal channel.
  # Other provider-visible effects have separate lifecycle owners.
  @channel_reply_event_types ~w(
    im.message.addressed
    im.message.may_intervene
    signal.action.invoked
    command.new
    command.steer
    command.llm
    check_back_later.wakeup
    cron.fire
    webhook.received
    automation_job.emitted
    automation_job.run_failed
    background_agent_job.completed
    background_agent_job.failed
    background_agent_job.waiting
    workflow.run.completed
    workflow.run.failed
    workflow.run.attention
  )

  # Public API

  @doc """
  Starts one preview handler for a dispatched Actor turn.
  """
  @spec maybe_start_for(ActorEvent.t(), String.t(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def maybe_start_for(%ActorEvent{} = event, subject_uid, conversation_id)
      when is_binary(subject_uid) and is_binary(conversation_id) do
    if channel_reply_eligible?(event) do
      with {:ok, event} <- rebase_dispatched_owner(event) do
        start_preview(event, subject_uid, conversation_id, event.id)
      end
    else
      :ok
    end
  end

  defp rebase_dispatched_owner(%ActorEvent{reply_preview_checkpoint: checkpoint} = event)
       when is_map(checkpoint) do
    if checkpoint["stream_actor_event_id"] in [nil, event.id] and
         checkpoint["presentation_owner"] != false do
      {:ok, event}
    else
      generation = non_negative_integer(checkpoint["owner_generation"]) + 1

      checkpoint =
        checkpoint
        |> Map.put("stream_actor_event_id", event.id)
        |> Map.put("presentation_owner", true)
        |> Map.put("owner_generation", generation)
        |> Map.delete("continued_to_actor_event_id")

      Actors.put_reply_preview_checkpoint(event.id, checkpoint)
    end
  end

  defp rebase_dispatched_owner(%ActorEvent{} = event), do: {:ok, event}

  defp start_preview(event, subject_uid, conversation_id, stream_actor_event_id) do
    name = via_tuple(stream_actor_event_id)

    case DynamicSupervisor.start_child(
           Ankole.SignalsGateway.PreviewSupervisor,
           {__MODULE__, {event, subject_uid, conversation_id, stream_actor_event_id, name}}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns true when an ActorEvent can use its Turn's AI output as a reply to a
  Signal channel.

  A true result does not guarantee an OutboxEntry or a provider send. The reply
  mode and route are checked later. Command feedback and other provider effects
  have separate owners.
  """
  @spec channel_reply_eligible?(ActorEvent.t()) :: boolean()
  def channel_reply_eligible?(%ActorEvent{} = event) do
    not is_nil(event.signal_channel_id) and
      event.type in @channel_reply_event_types
  end

  @doc false
  def channel_reply_event_types, do: @channel_reply_event_types

  @doc false
  def start_link(
        {%ActorEvent{} = event, subject_uid, conversation_id, stream_actor_event_id, name}
      ) do
    GenServer.start_link(
      __MODULE__,
      {event, subject_uid, conversation_id, stream_actor_event_id},
      name: name
    )
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

  @doc """
  Freezes the current visible reply fragment and makes `new_owner` own later
  presentation updates for the same immutable worker Turn stream.
  """
  @spec continue_on(Ecto.UUID.t(), ActorEvent.t()) :: :ok | {:error, term()}
  def continue_on(stream_actor_event_id, %ActorEvent{} = new_owner)
      when is_binary(stream_actor_event_id) do
    case Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, stream_actor_event_id) do
      [{pid, _value}] ->
        GenServer.call(pid, {:continue_on, new_owner}, 60_000)

      [] ->
        continue_without_live_owner(stream_actor_event_id, new_owner)
    end
  end

  defp continue_without_live_owner(stream_actor_event_id, %ActorEvent{} = new_owner) do
    old_owner = current_presentation_owner(stream_actor_event_id, new_owner)

    conversation_id =
      case old_owner do
        %ActorEvent{reply_preview_checkpoint: %{"conversation_id" => conversation_id}}
        when is_binary(conversation_id) ->
          conversation_id

        %ActorEvent{} ->
          case AIGatewayLink.active_conversation(new_owner.agent_uid, new_owner.session_id) do
            %{id: conversation_id} when is_binary(conversation_id) -> conversation_id
            _missing -> nil
          end

        nil ->
          nil
      end

    with %ActorEvent{} = old_owner <- old_owner,
         conversation_id when is_binary(conversation_id) <- conversation_id,
         :ok <-
           start_preview(
             old_owner,
             new_owner.agent_uid,
             conversation_id,
             stream_actor_event_id
           ),
         [{pid, _value}] <-
           Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, stream_actor_event_id) do
      GenServer.call(pid, {:continue_on, new_owner}, 60_000)
    else
      nil -> {:error, :reply_preview_owner_not_found}
      [] -> {:error, :reply_preview_owner_not_running}
      {:error, _reason} = error -> error
    end
  end

  defp current_presentation_owner(stream_actor_event_id, %ActorEvent{} = new_owner) do
    ActorEvent
    |> where([event], event.agent_uid == ^new_owner.agent_uid)
    |> where([event], event.session_id == ^new_owner.session_id)
    |> where(
      [event],
      fragment(
        "?->>'stream_actor_event_id' = ?",
        event.reply_preview_checkpoint,
        ^stream_actor_event_id
      )
    )
    |> where(
      [event],
      fragment(
        "COALESCE((?->>'presentation_owner')::boolean, false)",
        event.reply_preview_checkpoint
      )
    )
    |> order_by(
      [event],
      desc:
        fragment("COALESCE((?->>'owner_generation')::integer, 0)", event.reply_preview_checkpoint)
    )
    |> limit(1)
    |> Repo.one()
    |> case do
      %ActorEvent{} = event -> event
      nil -> Repo.get(ActorEvent, stream_actor_event_id)
    end
  end

  @doc false
  @spec input_superseded(Ecto.UUID.t()) :: :ok
  def input_superseded(actor_event_id) when is_binary(actor_event_id) do
    case Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event_id) do
      [{pid, _value}] -> GenServer.cast(pid, :input_superseded)
      [] -> :ok
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
    case Registry.register(
           Ankole.SignalsGateway.PreviewRegistry,
           actor_event_id,
           :recovery
         ) do
      {:ok, _owner} ->
        result =
          try do
            recover_without_owner(actor_event_id)
          after
            Registry.unregister(Ankole.SignalsGateway.PreviewRegistry, actor_event_id)
          end

        start_recovered_preview(result)

      {:error, {:already_registered, _owner}} ->
        :ok
    end
  end

  defp recover_without_owner(actor_event_id) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{
        reply_preview_checkpoint: %{
          "presentation_owner" => false,
          "refresh_pending" => true
        }
      } = event ->
        refresh_checkpoint(event)

      %ActorEvent{reply_preview_checkpoint: %{"presentation_owner" => false}} ->
        {:error, :reply_preview_not_recoverable}

      %ActorEvent{reply_preview_checkpoint: %{"recovery_state" => %{"state" => state}}}
      when state in ["blocked", "permanent"] ->
        {:error, :reply_preview_not_recoverable}

      %ActorEvent{reply_preview_checkpoint: %{"refresh_pending" => true}} = event ->
        if match?(%DateTime{}, event.completed_at) and surface_open?(event) do
          recover_completed_preview(event)
        else
          with :ok <- refresh_checkpoint(event) do
            recovered_preview_target(event.id)
          end
        end

      %ActorEvent{completed_at: %DateTime{}, reply_preview_checkpoint: checkpoint} = event
      when is_map(checkpoint) ->
        if refreshable_provider_checkpoint?(event) and surface_open?(event) do
          recover_completed_preview(event)
        else
          {:error, :reply_preview_not_recoverable}
        end

      %ActorEvent{
        input_state: "open",
        completed_at: nil,
        reply_preview_checkpoint: %{
          "subject_uid" => subject_uid,
          "conversation_id" => conversation_id
        }
      } = event
      when is_binary(subject_uid) and is_binary(conversation_id) ->
        if refreshable_provider_checkpoint?(event) do
          with {:ok, event} <- mark_owner_recovery_refresh_pending(event.id),
               :ok <- refresh_checkpoint(event) do
            recovered_preview_target(event.id)
          end
        else
          {:start, event, subject_uid, conversation_id}
        end

      %ActorEvent{} ->
        {:error, :reply_preview_not_recoverable}

      nil ->
        {:error, :actor_event_not_found}
    end
  end

  defp start_recovered_preview({:start, event, subject_uid, conversation_id}) do
    stream_actor_event_id =
      event.reply_preview_checkpoint
      |> then(&if(is_map(&1), do: &1["stream_actor_event_id"], else: nil))
      |> case do
        stream_actor_event_id when is_binary(stream_actor_event_id) -> stream_actor_event_id
        _missing -> event.id
      end

    start_preview(event, subject_uid, conversation_id, stream_actor_event_id)
  end

  defp start_recovered_preview(result), do: result

  defp recovered_preview_target(actor_event_id) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{reply_preview_checkpoint: %{"presentation_owner" => false}} ->
        :ok

      %ActorEvent{
        input_state: "open",
        completed_at: nil,
        reply_preview_checkpoint: %{
          "subject_uid" => subject_uid,
          "conversation_id" => conversation_id
        }
      } = event
      when is_binary(subject_uid) and is_binary(conversation_id) ->
        {:start, event, subject_uid, conversation_id}

      %ActorEvent{} ->
        :ok

      nil ->
        {:error, :actor_event_not_found}
    end
  end

  defp refreshable_provider_checkpoint?(%ActorEvent{reply_preview_checkpoint: checkpoint} = event)
       when is_map(checkpoint) do
    case ReplyPreviewAdapter.for_event(event) do
      %ReplyPreviewAdapter{refresh_fun: fun} = adapter when is_function(fun, 1) ->
        ReplyPreviewAdapter.surface?(adapter, checkpoint)

      _plain_or_unavailable ->
        false
    end
  end

  defp surface_open?(%ActorEvent{reply_preview_checkpoint: checkpoint} = event)
       when is_map(checkpoint) do
    event
    |> ReplyPreviewAdapter.for_event()
    |> ReplyPreviewAdapter.surface_open?(checkpoint)
  end

  defp recover_completed_preview(event) do
    with true <- refreshable_provider_checkpoint?(event),
         {:ok, presentation} <- durable_terminal_presentation(event.id),
         {:ok, event} <- mark_terminal_recovery_refresh_pending(event.id),
         :ok <- refresh_checkpoint(event, presentation) do
      :ok
    else
      false -> {:error, :reply_preview_not_recoverable}
      {:error, _reason} = error -> error
    end
  end

  defp durable_terminal_presentation(actor_event_id) do
    presentation =
      OutboxEntry
      |> where([entry], entry.source_actor_event_id == ^actor_event_id)
      |> where([entry], entry.delivery_class == :durable_ai_reply)
      |> order_by([entry], desc: entry.updated_at)
      |> Repo.all()
      |> Enum.find_value(fn
        %OutboxEntry{payload: %{"reply_presentation" => presentation}}
        when is_map(presentation) ->
          presentation

        _outbox ->
          nil
      end)

    case presentation do
      presentation when is_map(presentation) ->
        presentation = ReplyPresentation.normalize(presentation)

        if ReplyPresentation.terminal_state?(presentation) do
          {:ok, presentation}
        else
          {:error, :reply_preview_terminal_presentation_missing}
        end

      nil ->
        {:error, :reply_preview_terminal_presentation_missing}
    end
  end

  defp mark_owner_recovery_refresh_pending(actor_event_id) do
    Repo.transact(fn repo ->
      case Actors.lock_actor_event_in_tx(repo, actor_event_id) do
        %ActorEvent{
          input_state: "open",
          completed_at: nil,
          reply_preview_checkpoint: checkpoint
        } = event
        when is_map(checkpoint) ->
          checkpoint =
            checkpoint
            |> Map.put("refresh_pending", true)
            |> Map.put("refresh_reason", "owner_recovery")

          Actors.put_reply_preview_checkpoint_in_tx(repo, event, checkpoint)

        %ActorEvent{} ->
          {:error, :reply_preview_not_recoverable}

        nil ->
          {:error, :actor_event_not_found}
      end
    end)
  end

  defp mark_terminal_recovery_refresh_pending(actor_event_id) do
    Repo.transact(fn repo ->
      case Actors.lock_actor_event_in_tx(repo, actor_event_id) do
        %ActorEvent{completed_at: %DateTime{}, reply_preview_checkpoint: checkpoint} = event
        when is_map(checkpoint) ->
          if surface_open?(event) do
            checkpoint =
              checkpoint
              |> Map.put("refresh_pending", true)
              |> Map.put("refresh_reason", "terminal_recovery")

            Actors.put_reply_preview_checkpoint_in_tx(repo, event, checkpoint)
          else
            {:error, :reply_preview_not_recoverable}
          end

        %ActorEvent{} ->
          {:error, :reply_preview_not_recoverable}

        nil ->
          {:error, :actor_event_not_found}
      end
    end)
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

    presentation =
      checkpoint["presentation"]
      |> ReplyPresentation.normalize()
      |> ReplyPresentation.project_trigger(event.type, event.payload)

    refresh_checkpoint(event, presentation)
  end

  defp refresh_checkpoint(%ActorEvent{} = event, presentation) when is_map(presentation) do
    checkpoint = event.reply_preview_checkpoint || %{}

    with {:ok, binding} <- binding_for_event(event),
         {:ok, adapter} <- Adapters.fetch_reply_preview(binding.adapter) do
      ReplyPreviewAdapter.refresh(adapter, %Request{
        actor_event: event,
        subject_uid: checkpoint["subject_uid"],
        conversation_id: checkpoint["conversation_id"],
        presentation: presentation,
        mode: if(ReplyPresentation.terminal_state?(presentation), do: :terminal, else: :working)
      })
      |> case do
        {:ok, _result} ->
          :ok

        {:error, {:degraded, :plain_text, detail}} ->
          delegate_delivery_to_outbox(event, detail)

        {:error, reason} = error ->
          unless rich_retryable?(reason), do: block_recovery(event, reason)
          error
      end
    end
  end

  # Preview recovery deliberately has no OutboxEntry, so it cannot perform a
  # provider-visible plain-text fallback itself. Hand eventual terminal
  # delivery to the durable outbox instead of classifying the binding limit as
  # an operator-repair block. The open provider checkpoint is retained so the
  # outbox finalizer can calculate and send only the undelivered text tail.
  defp delegate_delivery_to_outbox(%ActorEvent{} = event, detail) do
    delegated_at = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()

    Repo.transact(fn repo ->
      case Actors.lock_actor_event_in_tx(repo, event.id) do
        %ActorEvent{reply_preview_checkpoint: checkpoint} = locked when is_map(checkpoint) ->
          checkpoint =
            checkpoint
            |> Map.delete("refresh_pending")
            |> Map.delete("refresh_reason")
            |> Map.put("presentation_owner", false)
            |> Map.put("recovery_state", %{
              "state" => "delegated",
              "reason" => "plain_text_fallback",
              # Sanitize before the JSONPayload checkpoint gate: adapter
              # details may carry atom reasons, which JSONPayload rejects.
              "detail" => Sanitizer.transport(detail),
              "delegated_at" => delegated_at
            })

          Actors.put_reply_preview_checkpoint_in_tx(repo, locked, checkpoint)

        %ActorEvent{} ->
          {:error, :reply_preview_checkpoint_missing}

        nil ->
          {:error, :actor_event_not_found}
      end
    end)
    |> case do
      {:ok, _event} ->
        Logging.info(
          "signals_gateway.ai_reply_preview.delivery_delegated",
          "AI reply preview delegated terminal delivery to durable outbox",
          actor_event_fields(event, %{reason: "plain_text_fallback"})
        )

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  # A refresh that a non-retryable provider error rejected would repeat on
  # every recovery sweep. Store the stop state on the checkpoint. A binding
  # update wakes only failures that require operator action; permanent failures
  # remain stopped.
  defp block_recovery(%ActorEvent{} = event, reason) do
    recovery_state = blocked_recovery_state(reason)

    Repo.transact(fn repo ->
      case Actors.lock_actor_event_in_tx(repo, event.id) do
        %ActorEvent{reply_preview_checkpoint: checkpoint} = locked when is_map(checkpoint) ->
          checkpoint =
            checkpoint
            |> Map.delete("refresh_pending")
            |> Map.delete("refresh_reason")
            |> Map.put("recovery_state", recovery_state)

          Actors.put_reply_preview_checkpoint_in_tx(repo, locked, checkpoint)

        %ActorEvent{} ->
          {:error, :reply_preview_checkpoint_missing}

        nil ->
          {:error, :actor_event_not_found}
      end
    end)
    |> case do
      {:ok, _event} ->
        Logging.warning(
          "signals_gateway.ai_reply_preview.recovery_blocked",
          "AI reply preview recovery stopped",
          actor_event_fields(event, %{reason: inspect(reason, limit: 20)})
        )

      {:error, block_error} ->
        Logging.warning(
          "signals_gateway.ai_reply_preview.recovery_block_failed",
          "AI reply preview recovery could not persist its blocked state",
          actor_event_fields(event, %{
            reason: inspect(reason, limit: 20),
            block_error: inspect(block_error, limit: 20)
          })
        )
    end

    :ok
  end

  defp blocked_recovery_state(reason) do
    {state, class, detail} =
      case reason do
        {:reply_delivery, :operator_action_required, detail} ->
          {"blocked", "operator_action_required", detail}

        {:reply_delivery, :permanent, detail} ->
          {"permanent", "permanent_failure", detail}
      end

    %{
      "state" => state,
      "reason" => class,
      # Sanitize before the JSONPayload checkpoint gate: adapter details may
      # carry atom reasons, which JSONPayload rejects.
      "detail" => Sanitizer.transport(detail),
      "blocked_at" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
    }
  end

  # GenServer callbacks

  @impl GenServer
  def init({%ActorEvent{} = event, subject_uid, conversation_id, stream_actor_event_id}) do
    case Events.subscribe(subject_uid, conversation_id) do
      :ok -> :ok
      {:error, reason} -> raise "cannot subscribe AI reply preview: #{inspect(reason)}"
    end

    rich_adapter = ReplyPreviewAdapter.for_event(event)
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
        true -> @rich_creation_debounce_ms
      end

    Process.send_after(self(), :flush_edit, initial_flush_ms)

    state = %{
      actor_event: event,
      stream_actor_event_id: stream_actor_event_id,
      owner_generation: non_negative_integer(checkpoint["owner_generation"]),
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
      preview_established: false,
      # A provider rejection while establishing or editing disables this
      # best-effort preview for the rest of the turn. Durable terminal output
      # still uses the outbox path.
      preview_disabled: false,
      # Monotonic key segment for best-effort preview edits.
      edit_sequence: 0,
      dirty: rich? and map_size(checkpoint) > 0,
      reply_preview_adapter: rich_adapter,
      presentation: presentation,
      last_synced_presentation: checkpoint["presentation"],
      rich_task: nil,
      rich_task_kind: nil,
      rich_task_generation: nil,
      rich_task_presentation: nil,
      rich_retry_ms: 1_000,
      rich_retry_at: nil,
      silent_success_allowed: ScheduledTurn.silent_success_allowed?(event),
      # Worker phase and tool events arrive before a quiet scheduled turn can
      # choose `<silent_success/>`. Do not let those events open a visible card.
      silent_rich_pending:
        rich? and ScheduledTurn.silent_success_allowed?(event) and map_size(checkpoint) == 0,
      input_superseded: false,
      handoff: nil,
      stopping: false
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:continue_on, %ActorEvent{} = new_owner}, from, state) do
    cond do
      state.actor_event.id == new_owner.id ->
        {:reply, :ok, state}

      not valid_handoff_owner?(state.actor_event, new_owner) ->
        {:reply, {:error, :invalid_reply_preview_owner}, state}

      not is_nil(state.handoff) ->
        {:reply, {:error, :reply_preview_handoff_in_progress}, state}

      true ->
        state
        |> Map.put(:handoff, %{from: from, new_owner: new_owner})
        |> continue_pending_handoff()
    end
  end

  @impl GenServer
  def handle_cast(:stop, %{rich_task: nil} = state), do: finish_rich_stop(state)

  def handle_cast(:stop, state) do
    {:noreply, %{state | stopping: true, rich_retry_at: nil, dirty: false}}
  end

  def handle_cast(_message, %{stopping: true} = state), do: {:noreply, state}

  def handle_cast(:input_superseded, state) do
    {:noreply, show_input_superseded(state)}
  end

  def handle_cast(:cleanup_thought, %{reply_preview_adapter: %ReplyPreviewAdapter{}} = state) do
    presentation = ReplyPresentation.checkpoint(state.presentation)
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
    kind = Map.get(event, "kind") || Map.get(event, "type")
    payload = Map.get(event, "payload") || event

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
  def handle_info({ref, result}, %{rich_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish_rich_task(state, result)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{rich_task: %Task{ref: ref}} = state) do
    finish_rich_task(state, {:error, {:reply_preview_task_exit, reason}})
  end

  def handle_info(_message, %{stopping: true} = state), do: {:noreply, state}

  def handle_info({:ai_gateway_event, event_type, event}, state) when is_map(event) do
    if event_matches_actor?(event, state) do
      handle_gateway_event(event_type, map_value(event, :payload) || %{}, state)
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:flush_edit, state) do
    if match?(%ReplyPreviewAdapter{}, state.reply_preview_adapter) do
      state = maybe_start_rich_sync(state)
      Process.send_after(self(), :flush_edit, @rich_flush_interval_ms)
      {:noreply, state}
    else
      handle_plain_text_flush(state)
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_plain_text_flush(state) do
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
      input_superseded? = state.input_superseded
      new_buffer = state.text_buffer <> delta
      preview_text = AIReplyText.normalize_visible_text(new_buffer)

      state = %{
        state
        | text_buffer: new_buffer,
          preview_text: preview_text,
          input_superseded: false
      }

      if state.silent_success_allowed and
           AIReplyText.silent_success_marker_prefix?(new_buffer) do
        {:noreply, state}
      else
        if match?(%ReplyPreviewAdapter{}, state.reply_preview_adapter) do
          presentation =
            if input_superseded? do
              ReplyPresentation.replace_answer(state.presentation, delta)
            else
              ReplyPresentation.append_answer(state.presentation, delta)
            end

          {:noreply,
           state
           |> Map.put(:silent_rich_pending, false)
           |> mark_rich_dirty(presentation)}
        else
          handle_plain_text_output_delta(state, new_buffer, preview_text)
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

  defp handle_plain_text_output_delta(state, new_buffer, preview_text) do
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
    _ = Events.unsubscribe(state.subject_uid, state.conversation_id)
    :ok
  end

  defp reset_for_response_started(state) do
    state = Map.merge(state, %{text_buffer: "", dirty: false})

    if match?(%ReplyPreviewAdapter{}, state.reply_preview_adapter) and
         not state.silent_rich_pending and not state.input_superseded do
      presentation =
        state.presentation
        |> ReplyPresentation.replace_answer("")
        |> ReplyPresentation.checkpoint()

      mark_rich_dirty(state, presentation)
    else
      state
    end
  end

  defp show_input_superseded(state) do
    text = I18n.t("signals_gateway.reply.input_superseded")

    cond do
      match?(%ReplyPreviewAdapter{}, state.reply_preview_adapter) ->
        presentation =
          state.presentation
          |> ReplyPresentation.replace_answer(text)
          |> ReplyPresentation.checkpoint()

        state
        |> Map.put(:input_superseded, true)
        |> Map.put(:silent_rich_pending, false)
        |> mark_rich_dirty(presentation)
        |> maybe_start_rich_sync()

      state.preview_established and is_binary(state.preview_entry_id) ->
        {edit_sequence, edit_key} = next_edit_key(state, "input-superseded")

        case edit_preview(state.actor_event, state.preview_entry_id, text, edit_key) do
          :ok ->
            %{
              state
              | text_buffer: "",
                preview_text: text,
                dirty: false,
                edit_sequence: edit_sequence,
                input_superseded: true
            }

          {:error, _reason} ->
            state
            |> Map.put(:input_superseded, true)
            |> disable_preview_after_edit_failure(edit_sequence)
        end

      true ->
        %{state | input_superseded: true}
    end
  end

  defp mark_rich_dirty(state, presentation) do
    if presentation == state.presentation do
      state
    else
      %{state | presentation: presentation, dirty: true}
    end
  end

  defp continue_pending_handoff(%{rich_task: %Task{}} = state), do: {:noreply, state}

  defp continue_pending_handoff(%{handoff: %{new_owner: _new_owner}} = state) do
    cond do
      not old_preview_visible?(state) ->
        complete_pending_handoff(state, :ok)

      match?(%ReplyPreviewAdapter{}, state.reply_preview_adapter) ->
        continued = ReplyPresentation.continued(state.presentation)

        request = %Request{
          actor_event: state.actor_event,
          subject_uid: state.subject_uid,
          conversation_id: state.conversation_id,
          presentation: continued,
          mode: :terminal
        }

        adapter = state.reply_preview_adapter

        task =
          Task.Supervisor.async_nolink(
            Ankole.SignalsGateway.PreviewTaskSupervisor,
            fn -> ReplyPreviewAdapter.finalize(adapter, request) end
          )

        {:noreply,
         %{
           state
           | presentation: continued,
             dirty: false,
             rich_task: task,
             rich_task_kind: :handoff,
             rich_task_generation: state.owner_generation,
             rich_task_presentation: continued,
             rich_retry_at: nil
         }}

      true ->
        result = freeze_plain_preview(state)
        complete_pending_handoff(state, result)
    end
  end

  defp continue_pending_handoff(state), do: {:noreply, state}

  defp complete_pending_handoff(%{handoff: %{from: from, new_owner: new_owner}} = state, result) do
    case switch_presentation_owner(state, new_owner, result) do
      {:ok, state} ->
        GenServer.reply(from, result)

        if state.stopping do
          finish_rich_stop(state)
        else
          {:noreply, state}
        end

      {:error, reason} ->
        GenServer.reply(from, {:error, reason})
        state = %{state | handoff: nil}

        if state.stopping do
          finish_rich_stop(state)
        else
          {:noreply, state}
        end
    end
  end

  defp complete_pending_handoff(state, _result), do: {:noreply, state}

  defp switch_presentation_owner(state, %ActorEvent{} = new_owner, handoff_result) do
    next_generation = state.owner_generation + 1
    continued = ReplyPresentation.continued(state.presentation)
    new_presentation = ReplyPresentation.new(state: "working")
    old_visible? = old_preview_visible?(state)
    refresh_old? = old_visible? and match?({:error, _reason}, handoff_result)

    Repo.transact(fn repo ->
      with :ok <-
             Actors.lock_actor_session_in_tx(
               repo,
               state.actor_event.agent_uid,
               state.actor_event.session_id
             ),
           %ActorEvent{} = old_event <-
             Actors.lock_actor_event_in_tx(repo, state.actor_event.id),
           %ActorEvent{} = new_event <- Actors.lock_actor_event_in_tx(repo, new_owner.id),
           true <- valid_handoff_owner?(old_event, new_event),
           {:ok, old_event} <-
             persist_previous_owner_in_tx(
               repo,
               old_event,
               new_event.id,
               state.owner_generation,
               continued,
               old_visible?,
               refresh_old?
             ),
           {:ok, new_event} <-
             persist_new_owner_in_tx(
               repo,
               new_event,
               state,
               next_generation,
               new_presentation
             ) do
        {:ok, %{old_owner: old_event, new_owner: new_event}}
      else
        false -> {:error, :invalid_reply_preview_owner}
        nil -> {:error, :actor_event_not_found}
        {:error, _reason} = error -> error
      end
    end)
    |> case do
      {:ok, %{new_owner: new_owner}} ->
        checkpoint = new_owner.reply_preview_checkpoint || %{}
        presentation = ReplyPresentation.normalize(checkpoint["presentation"])
        preview_entry_id = new_owner.reply_preview_source_entry_id

        {:ok,
         %{
           state
           | actor_event: new_owner,
             owner_generation: next_generation,
             text_buffer: "",
             preview_text: "",
             tool_calls: %{},
             preview_entry_id: preview_entry_id,
             preview_established: is_binary(preview_entry_id),
             preview_disabled: false,
             edit_sequence: 0,
             dirty: false,
             presentation: presentation,
             last_synced_presentation: checkpoint["presentation"],
             rich_task: nil,
             rich_task_kind: nil,
             rich_task_generation: nil,
             rich_task_presentation: nil,
             rich_retry_ms: 1_000,
             rich_retry_at: nil,
             silent_success_allowed: false,
             silent_rich_pending: false,
             input_superseded: false,
             handoff: nil
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_previous_owner_in_tx(
         _repo,
         %ActorEvent{reply_preview_checkpoint: nil} = event,
         _new_owner_id,
         _generation,
         _continued,
         false,
         _refresh?
       ),
       do: {:ok, event}

  defp persist_previous_owner_in_tx(
         repo,
         %ActorEvent{} = event,
         new_owner_id,
         generation,
         continued,
         visible?,
         refresh?
       ) do
    checkpoint =
      (event.reply_preview_checkpoint || %{})
      |> Map.put("presentation_owner", false)
      |> Map.put("owner_generation", generation)
      |> Map.put("continued_to_actor_event_id", new_owner_id)
      |> then(fn checkpoint ->
        if visible? do
          Map.put(checkpoint, "presentation", ReplyPresentation.checkpoint(continued))
        else
          checkpoint
        end
      end)
      |> then(fn checkpoint ->
        if refresh? do
          checkpoint
          |> Map.put("refresh_pending", true)
          |> Map.put("refresh_reason", "owner_handoff")
        else
          checkpoint
        end
      end)

    Actors.put_reply_preview_checkpoint_in_tx(repo, event, checkpoint)
  end

  defp persist_new_owner_in_tx(repo, %ActorEvent{} = event, state, generation, presentation) do
    checkpoint =
      (event.reply_preview_checkpoint || %{})
      |> Map.put("subject_uid", state.subject_uid)
      |> Map.put("conversation_id", state.conversation_id)
      |> Map.put("stream_actor_event_id", state.stream_actor_event_id)
      |> Map.put("presentation_owner", true)
      |> Map.put("owner_generation", generation)
      |> Map.put("presentation", ReplyPresentation.checkpoint(presentation))
      |> Map.delete("continued_to_actor_event_id")

    Actors.put_reply_preview_checkpoint_in_tx(repo, event, checkpoint)
  end

  defp old_preview_visible?(state) do
    state.preview_established or
      ReplyPreviewAdapter.surface?(
        state.reply_preview_adapter,
        state.actor_event.reply_preview_checkpoint
      )
  end

  defp freeze_plain_preview(state) do
    text = continued_plain_text(state.preview_text)
    {_edit_sequence, edit_key} = next_edit_key(state, "continued")

    case edit_preview(state.actor_event, state.preview_entry_id, text, edit_key) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp continued_plain_text(text) do
    status = I18n.t("signals_gateway.reply.continued")

    case AIReplyText.normalize_visible_text(text) do
      "" -> status
      visible -> visible <> "\n\n" <> status
    end
  end

  defp valid_handoff_owner?(%ActorEvent{} = current, %ActorEvent{} = new_owner) do
    new_owner.type == "command.steer" and
      current.agent_uid == new_owner.agent_uid and
      current.binding_name == new_owner.binding_name and
      current.session_id == new_owner.session_id and
      current.signal_channel_id == new_owner.signal_channel_id
  end

  defp maybe_start_rich_sync(
         %{
           dirty: true,
           rich_task: nil,
           preview_disabled: false,
           stopping: false
         } = state
       ) do
    if rich_retry_due?(state.rich_retry_at) do
      presentation = state.presentation

      request = %Request{
        actor_event: state.actor_event,
        subject_uid: state.subject_uid,
        conversation_id: state.conversation_id,
        presentation: presentation,
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
          rich_task_kind: :update,
          rich_task_generation: state.owner_generation,
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
        rich_task_kind: nil,
        rich_task_generation: nil,
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
      "signals_gateway.ai_reply_preview.rich_sync_failed",
      "AI reply rich preview sync failed",
      preview_fields(state, %{reason: inspect(reason, limit: 20), retry: retry?})
    )

    if retry? do
      retry_delay_ms = max(state.rich_retry_ms, rich_retry_after_ms(reason))
      retry_ms = min(state.rich_retry_ms * 2, @rich_retry_max_ms)

      %{
        state
        | rich_task: nil,
          rich_task_kind: nil,
          rich_task_generation: nil,
          rich_task_presentation: nil,
          dirty: true,
          rich_retry_at: System.monotonic_time(:millisecond) + retry_delay_ms,
          rich_retry_ms: retry_ms
      }
    else
      %{
        state
        | rich_task: nil,
          rich_task_kind: nil,
          rich_task_generation: nil,
          rich_task_presentation: nil,
          dirty: false,
          preview_disabled: true
      }
    end
  end

  defp finish_rich_sync(state, result),
    do: finish_rich_sync(state, {:error, {:invalid_reply_preview_sync_result, result}})

  # A handoff finalize can leave the old provider surface in an unknown state.
  # The preview cannot repeat it safely, so the old owner takes the refresh
  # path like any other non-retryable failure.
  defp finish_rich_task(state, :unknown),
    do: finish_rich_task(state, {:error, :reply_preview_delivery_unknown})

  defp finish_rich_task(state, result) do
    task_kind = state.rich_task_kind
    task_generation = state.rich_task_generation

    state =
      if task_generation == state.owner_generation do
        finish_rich_sync(state, result)
      else
        clear_rich_task(state)
      end

    cond do
      task_kind == :handoff ->
        complete_pending_handoff(state, handoff_result(result))

      not is_nil(state.handoff) ->
        continue_pending_handoff(state)

      state.stopping ->
        finish_rich_stop(state)

      true ->
        {:noreply, state}
    end
  end

  defp clear_rich_task(state) do
    %{
      state
      | rich_task: nil,
        rich_task_kind: nil,
        rich_task_generation: nil,
        rich_task_presentation: nil
    }
  end

  defp handoff_result({:ok, _result}), do: :ok
  defp handoff_result({:error, reason}), do: {:error, reason}
  defp handoff_result(other), do: {:error, {:invalid_reply_preview_sync_result, other}}

  defp rich_retryable?({:reply_delivery, :operator_action_required, _error}), do: false
  defp rich_retryable?({:reply_delivery, :permanent, _error}), do: false
  defp rich_retryable?({:degraded, :plain_text, _error}), do: false
  defp rich_retryable?(:reply_preview_delivery_unknown), do: false
  defp rich_retryable?(_reason), do: true

  defp rich_retry_after_ms({:reply_delivery, :retryable, detail}) when is_map(detail) do
    Utils.reply_delivery_retry_after_seconds(detail) * 1_000
  end

  defp rich_retry_after_ms(_reason), do: 0

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
          stored_generation = non_negative_integer(checkpoint["owner_generation"])

          cond do
            stored_generation != state.owner_generation ->
              {:ok, event}

            is_map(stored_checkpoint) and
                presentation_revision(latest_presentation) <=
                  presentation_revision(stored_presentation) ->
              {:ok, event}

            true ->
              checkpoint =
                checkpoint
                |> Map.put_new("subject_uid", state.subject_uid)
                |> Map.put_new("conversation_id", state.conversation_id)
                |> Map.put_new("stream_actor_event_id", state.stream_actor_event_id)
                |> Map.put_new("presentation_owner", true)
                |> Map.put_new("owner_generation", state.owner_generation)
                |> Map.put("presentation", latest_presentation)

              Actors.put_reply_preview_checkpoint_in_tx(repo, event, checkpoint)
          end

        nil ->
          {:error, :actor_event_not_found}
      end
    end)
    |> case do
      {:ok, _event} ->
        :ok

      # A retracted source entry takes its Actor event with it. There is no
      # state left to keep, and the cards this preview opened are already
      # queued for deletion.
      {:error, :actor_event_not_found} ->
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

  defp finish_rich_stop(state) do
    checkpoint_latest_rich_presentation(state)

    {:stop, :normal,
     %{
       state
       | rich_task: nil,
         rich_task_kind: nil,
         rich_task_generation: nil,
         rich_task_presentation: nil,
         dirty: false
     }}
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
    name =
      normalize_optional_text(
        payload[:name] || payload["name"] || payload[:tool] || payload["tool"] ||
          payload[:type] || payload["type"]
      ) ||
        tool_name_from_output(payload[:output] || payload["output"]) ||
        if(is_binary(call_id), do: Map.get(tool_calls, call_id)) ||
        call_id ||
        "tool"

    case normalize_optional_text(payload[:namespace] || payload["namespace"]) do
      nil -> name
      namespace -> "#{namespace}.#{name}"
    end
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

  # Adapter resolution

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

  # A preview message is transient, so it never becomes an outbox row that
  # `dispatch_outbox` could degrade. Apply the same adapter degrade here before
  # handing the entry to the adapter.
  defp deliver_outbox(%ActorEvent{} = event, operation, text, opts) do
    with {:ok, adapter} <- adapter_for_event(event) do
      operation =
        Outbox.effective_outbox_operation(operation, OutboxAdapter.capabilities(adapter))

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
      reply_to_source_entry_id:
        if(operation == :reply, do: ActorEvent.reply_anchor_source_entry_id(event)),
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
    optional_text(result, :created_source_entry_id)
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
      Map.get(metadata, "actor_event_id") == state.stream_actor_event_id
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp map_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key)
end
