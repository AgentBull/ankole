defmodule Ankole.Conversations.Delivery.Preview do
  @moduledoc """
  Subscribes to one generic AIGateway conversation and renders live reply
  previews for a Conversation.

  Lifecycle:
    1. `maybe_start_for/4` is called when a Driver starts its attempt, after its AIGateway conversation is known.
    2. The handler subscribes to generic conversation-scoped AIGateway events
       and filters opaque metadata in Conversations.Delivery.
    3. On first `:output_text_delta` or tool activity event, it sends an
       initial provider preview message.
    4. On subsequent deltas, it throttles provider edits (~1s flush); tool
       activity updates are edited immediately.
    5. On `:response_started`, clear the per-round delta buffer while keeping
       the existing provider preview handle.
    6. Response terminal events never imply that the Agent turn is terminal.
       Only explicit Actor lifecycle handlers stop the preview.
    7. Durable terminal delivery is owned by intent; the transient handler
       remains available across long model calls and retryable execution loss.
    8. A lifecycle stop checkpoints the latest renderer-safe semantic
       projection before intent takes over, even when the last provider update
       is still dirty.
  """

  use GenServer, restart: :temporary

  require Ash.Query

  alias Ankole.Conversations.Delivery.PreviewState
  alias Ankole.AIGateway.Events
  alias Ankole.I18n
  alias Ankole.Sessions.Queue
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.Scheduled
  alias Ankole.Logging
  alias Ankole.Signals.Adapters
  alias Ankole.Conversations.Delivery.Text
  alias Ankole.Conversations.Delivery
  alias Ankole.Conversations.Delivery.Adapter
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Signals.Sanitizer
  alias Ankole.Conversations.Delivery.PreviewAdapter
  alias Ankole.Conversations.Delivery.PreviewAdapter.Request

  # Throttle plain-text edits to avoid provider rate limits.
  @edit_flush_interval_ms 1_000
  # Throttle rich updates because they use slower provider-native APIs.
  @rich_flush_interval_ms 1_000
  # Avoid an empty provider message while the first rich content takes shape.
  @rich_creation_debounce_ms 350
  # Keep rich-preview recovery responsive after repeated temporary failures.
  @rich_retry_max_ms 30_000
  @silent_success_marker ~s({"outcome":"silent_success","reply":null})

  # These event types can use a Turn's AI output as a reply to a Conversation.
  # Other provider-visible effects have separate lifecycle owners.
  @channel_reply_event_types ~w(
    conversation.message.addressed
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
    background_agent_job.input_undeliverable
    background_agent_job.waiting
    workflow.run.completed
    workflow.run.failed
    workflow.run.attention
  )

  @doc """
  Starts one preview handler for a dispatched Actor turn.
  """
  @spec maybe_start_for(Signal.t(), String.t(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def maybe_start_for(event, subject_uid, conversation_id, opts \\ [])

  def maybe_start_for(%Signal{} = event, subject_uid, conversation_id, opts)
      when is_binary(subject_uid) and is_binary(conversation_id) do
    if channel_reply_eligible?(event) do
      owner = current_presentation_owner(event.id, event) || event
      start_preview(owner, subject_uid, conversation_id, event.id, opts)
    else
      :ok
    end
  end

  defp start_preview(event, subject_uid, conversation_id, stream_signal_id, opts \\ []) do
    name = via_tuple(event)

    case DynamicSupervisor.start_child(
           Ankole.Conversations.Delivery.Previews,
           {__MODULE__, {event, subject_uid, conversation_id, stream_signal_id, name, opts}}
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        monitor = Process.monitor(pid)

        case GenServer.call(pid, {:adopt_driver, stream_signal_id, opts}) do
          :retiring ->
            receive do
              {:DOWN, ^monitor, :process, ^pid, _reason} ->
                start_preview(event, subject_uid, conversation_id, stream_signal_id, opts)
            after
              30_000 ->
                Process.demonitor(monitor, [:flush])
                {:error, :reply_preview_close_timeout}
            end

          result ->
            Process.demonitor(monitor, [:flush])
            result
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns true when an Signal can use its Turn's AI output as a reply to a
  Conversation.

  A true result does not guarantee an Intent or a provider send. The reply
  mode and route are checked later. Command feedback and other provider effects
  have separate owners.
  """
  @spec channel_reply_eligible?(Signal.t()) :: boolean()
  def channel_reply_eligible?(%Signal{} = event) do
    not is_nil(event.conversation_id) and is_binary(event.reply_binding_name) and
      event.reply_binding_name != "" and event.type in @channel_reply_event_types
  end

  @doc false
  def channel_reply_event_types, do: @channel_reply_event_types

  @doc false
  def start_link({%Signal{} = event, subject_uid, conversation_id, stream_signal_id, name, opts}) do
    GenServer.start_link(
      __MODULE__,
      {event, subject_uid, conversation_id, stream_signal_id, opts},
      name: name
    )
  end

  @doc """
  Returns the global name for one conversation preview.
  """
  def via_tuple(%Signal{} = event),
    do: {:global, {__MODULE__, event.agent_uid, event.session_id}}

  def via_tuple(signal_id),
    do: via_tuple(PreviewState.load_signal(signal_id))

  @doc """
  Stops the preview owned by an explicit Actor lifecycle transition.
  """
  @spec stop(Signal.t() | Ecto.UUID.t()) :: :ok
  def stop(event), do: cast_for_event(event, :stop)

  @doc """
  Freezes the current visible reply fragment and makes `new_owner` own later
  presentation updates for the same run stream.
  """
  @spec continue_on(Ecto.UUID.t(), Signal.t()) :: :ok | {:error, term()}
  def continue_on(stream_signal_id, %Signal{} = new_owner)
      when is_binary(stream_signal_id) do
    case lookup(stream_signal_id) do
      [{pid, _value}] ->
        GenServer.call(
          pid,
          {:continue_on, PreviewState.load(new_owner)},
          60_000
        )

      [] ->
        continue_without_live_owner(stream_signal_id, new_owner)

      {:error, _reason} = error ->
        error
    end
  end

  defp continue_without_live_owner(stream_signal_id, %Signal{} = new_owner) do
    new_owner = PreviewState.load(new_owner)
    old_owner = current_presentation_owner(stream_signal_id, new_owner)

    conversation_id =
      case old_owner do
        %Signal{
          preview: %PreviewState{
            checkpoint: %{"conversation_id" => conversation_id}
          }
        }
        when is_binary(conversation_id) ->
          conversation_id

        %Signal{} ->
          Ankole.Sessions.active_model_conversation_id(new_owner)

        nil ->
          nil
      end

    with %Signal{} = old_owner <- old_owner,
         conversation_id when is_binary(conversation_id) <- conversation_id,
         :ok <-
           start_preview(
             old_owner,
             new_owner.agent_uid,
             conversation_id,
             stream_signal_id
           ),
         [{pid, _value}] <-
           lookup(stream_signal_id) do
      GenServer.call(
        pid,
        {:continue_on, PreviewState.load(new_owner)},
        60_000
      )
    else
      nil -> {:error, :reply_preview_owner_not_found}
      [] -> {:error, :reply_preview_owner_not_running}
      {:error, _reason} = error -> error
    end
  end

  defp current_presentation_owner(stream_signal_id, %Signal{} = new_owner) do
    PreviewState
    |> Ash.Query.filter(
      fragment("?->>'stream_signal_id' = ?", checkpoint, ^stream_signal_id) and
        fragment("COALESCE((?->>'presentation_owner')::boolean, false)", checkpoint) and
        exists(
          Signal,
          id == parent(signal_id) and agent_uid == ^new_owner.agent_uid and
            session_id == ^new_owner.session_id
        )
    )
    |> Ash.Query.sort(owner_generation: :desc)
    |> Ash.Query.limit(1)
    |> Ankole.Ash.read_one!()
    |> case do
      %PreviewState{signal_id: signal_id} -> PreviewState.load_signal(signal_id)
      nil -> PreviewState.load_signal(stream_signal_id)
    end
  end

  @doc false
  @spec input_superseded(Ecto.UUID.t()) :: :ok
  def input_superseded(event), do: cast_for_event(event, :input_superseded)

  @doc false
  @spec presentation_event(Ecto.UUID.t(), map()) :: :ok
  def presentation_event(owner, event) when is_map(event),
    do: cast_for_event(owner, {:presentation_event, event})

  @doc false
  @spec recover(Ecto.UUID.t()) :: :ok | {:error, term()}
  def recover(signal_id) when is_binary(signal_id) do
    :global.trans({{__MODULE__, :recovery, signal_id}, self()}, fn ->
      case lookup(signal_id) do
        [] -> recover_without_owner(signal_id) |> start_recovered_preview()
        [{_pid, _value}] -> :ok
        {:error, _reason} = error -> error
      end
    end)
  end

  defp recover_without_owner(signal_id) do
    case PreviewState.load_signal(signal_id) do
      %Signal{
        preview: %PreviewState{
          checkpoint: %{
            "presentation_owner" => false,
            "refresh_pending" => true
          }
        }
      } = event ->
        refresh_checkpoint(event)

      %Signal{
        preview: %PreviewState{
          checkpoint: %{"presentation_owner" => false}
        }
      } ->
        {:error, :reply_preview_not_recoverable}

      %Signal{
        preview: %PreviewState{
          checkpoint: %{"recovery_state" => %{"state" => state}}
        }
      }
      when state in ["blocked", "permanent"] ->
        {:error, :reply_preview_not_recoverable}

      %Signal{
        preview: %PreviewState{
          checkpoint: %{"refresh_pending" => true}
        }
      } = event ->
        if event.status == :completed and surface_open?(event) do
          recover_completed_preview(event)
        else
          with :ok <- refresh_checkpoint(event) do
            recovered_preview_target(event.id)
          end
        end

      %Signal{
        status: :completed,
        preview: %PreviewState{checkpoint: checkpoint}
      } = event
      when is_map(checkpoint) ->
        if refreshable_provider_checkpoint?(event) and surface_open?(event) do
          recover_completed_preview(event)
        else
          {:error, :reply_preview_not_recoverable}
        end

      %Signal{
        status: live_status,
        preview: %PreviewState{
          checkpoint: %{
            "subject_uid" => subject_uid,
            "conversation_id" => conversation_id
          }
        }
      } = event
      when live_status in [:queued, :running] and
             (is_binary(subject_uid) and is_binary(conversation_id)) ->
        if refreshable_provider_checkpoint?(event) do
          with {:ok, event} <- mark_owner_recovery_refresh_pending(event.id),
               :ok <- refresh_checkpoint(event) do
            recovered_preview_target(event.id)
          end
        else
          {:start, event, subject_uid, conversation_id}
        end

      %Signal{} ->
        {:error, :reply_preview_not_recoverable}

      nil ->
        {:error, :signal_not_found}
    end
  end

  defp start_recovered_preview(
         {:start, %Signal{status: live_status} = event, _subject, _conversation}
       )
       when live_status in [:queued, :running] do
    with {:ok, pid} <-
           Ankole.Sessions.ensure_driver(%{
             agent_uid: event.agent_uid,
             session_id: event.session_id
           }) do
      stream_id =
        PreviewState.get(event).checkpoint["stream_signal_id"] ||
          event.id

      send(pid, {:recover_preview, stream_id})
      :ok
    end
  end

  defp start_recovered_preview(result), do: result

  defp recovered_preview_target(signal_id) do
    case PreviewState.load_signal(signal_id) do
      %Signal{
        preview: %PreviewState{
          checkpoint: %{"presentation_owner" => false}
        }
      } ->
        :ok

      %Signal{
        status: live_status,
        preview: %PreviewState{
          checkpoint: %{
            "subject_uid" => subject_uid,
            "conversation_id" => conversation_id
          }
        }
      } = event
      when live_status in [:queued, :running] and
             (is_binary(subject_uid) and is_binary(conversation_id)) ->
        {:start, event, subject_uid, conversation_id}

      %Signal{} ->
        :ok

      nil ->
        {:error, :signal_not_found}
    end
  end

  defp refreshable_provider_checkpoint?(
         %Signal{preview: %PreviewState{checkpoint: checkpoint}} =
           event
       )
       when is_map(checkpoint) do
    case PreviewAdapter.for_event(event) do
      %PreviewAdapter{refresh_fun: fun} = adapter when is_function(fun, 1) ->
        PreviewAdapter.surface?(adapter, checkpoint)

      _plain_or_unavailable ->
        false
    end
  end

  defp surface_open?(
         %Signal{preview: %PreviewState{checkpoint: checkpoint}} =
           event
       )
       when is_map(checkpoint) do
    event
    |> PreviewAdapter.for_event()
    |> PreviewAdapter.surface_open?(checkpoint)
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

  defp durable_terminal_presentation(signal_id) do
    presentation =
      Intent
      |> Ash.Query.filter(source_signal_id == ^signal_id and delivery_class == :durable_ai_reply)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ankole.Ash.read!()
      |> Enum.find_value(fn
        %Intent{payload: %{"reply_presentation" => presentation}}
        when is_map(presentation) ->
          presentation

        _intent ->
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

  defp mark_owner_recovery_refresh_pending(signal_id) do
    PreviewState.update_checkpoint(signal_id, fn
      %Signal{status: status, preview: %PreviewState{checkpoint: checkpoint}}
      when status in [:queued, :running] and is_map(checkpoint) ->
        {:ok,
         checkpoint
         |> Map.put("refresh_pending", true)
         |> Map.put("refresh_reason", "owner_recovery")}

      %Signal{} ->
        {:error, :reply_preview_not_recoverable}
    end)
  end

  defp mark_terminal_recovery_refresh_pending(signal_id) do
    PreviewState.update_checkpoint(signal_id, fn
      %Signal{status: :completed, preview: %PreviewState{checkpoint: checkpoint}} = event
      when is_map(checkpoint) ->
        if surface_open?(event) do
          {:ok,
           checkpoint
           |> Map.put("refresh_pending", true)
           |> Map.put("refresh_reason", "terminal_recovery")}
        else
          {:error, :reply_preview_not_recoverable}
        end

      %Signal{} ->
        {:error, :reply_preview_not_recoverable}
    end)
  end

  @doc false
  @spec cleanup_due(Ecto.UUID.t()) :: :ok | {:error, term()}
  def cleanup_due(signal_id) when is_binary(signal_id) do
    now = DateTime.utc_now(:microsecond)

    case PreviewState.load_signal(signal_id) do
      %Signal{} = event ->
        case PreviewState.cleanup_at(event) do
          %DateTime{} = due_at ->
            if DateTime.compare(due_at, now) in [:lt, :eq] do
              cleanup_due_event(event)
            else
              {:error, :reply_preview_cleanup_not_due}
            end

          nil ->
            {:error, :reply_preview_cleanup_not_due}
        end

      nil ->
        {:error, :signal_not_found}
    end
  end

  defp cleanup_due_event(%Signal{} = event) do
    case lookup(event.id) do
      [{pid, _value}] ->
        GenServer.cast(pid, :cleanup_thought)
        :ok

      [] ->
        with {:ok, _event} <- mark_cleanup_refresh_pending(event.id),
             :ok <- recover(event.id) do
          :ok
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp mark_cleanup_refresh_pending(signal_id) do
    PreviewState.update_checkpoint(signal_id, fn
      %Signal{preview: %PreviewState{checkpoint: checkpoint}} when is_map(checkpoint) ->
        {:ok,
         checkpoint
         |> Map.delete("cleanup_at")
         |> Map.put("refresh_pending", true)
         |> Map.put("refresh_reason", "thought_cleanup")}

      %Signal{} ->
        {:error, :reply_preview_not_recoverable}
    end)
  end

  defp refresh_checkpoint(%Signal{} = event) do
    checkpoint = PreviewState.get(event).checkpoint || %{}

    presentation =
      checkpoint["presentation"]
      |> ReplyPresentation.normalize()
      |> ReplyPresentation.project_trigger(event.type, Signal.envelope(event))

    refresh_checkpoint(event, presentation)
  end

  defp refresh_checkpoint(%Signal{} = event, presentation) when is_map(presentation) do
    checkpoint = PreviewState.get(event).checkpoint || %{}

    with {:ok, binding} <- binding_for_event(event),
         {:ok, adapter} <- Adapters.fetch_preview(binding.adapter) do
      PreviewAdapter.refresh(adapter, %Request{
        signal: event,
        subject_uid: checkpoint["subject_uid"],
        conversation_id: checkpoint["conversation_id"],
        presentation: presentation,
        mode: if(ReplyPresentation.terminal_state?(presentation), do: :terminal, else: :working)
      })
      |> case do
        {:ok, _result} ->
          :ok

        {:error, {:degraded, :plain_text, detail}} ->
          delegate_delivery_to_intent(event, detail)

        {:error, reason} = error ->
          unless rich_retryable?(reason), do: block_recovery(event, reason)
          error
      end
    end
  end

  # Preview recovery deliberately has no Intent, so it cannot perform a
  # provider-visible plain-text fallback itself. Hand eventual terminal
  # delivery to the durable intent instead of classifying the binding limit as
  # an operator-repair block. The open provider checkpoint is retained so the
  # intent finalizer can calculate and send only the undelivered text tail.
  defp delegate_delivery_to_intent(%Signal{} = event, detail) do
    delegated_at = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()

    PreviewState.update_checkpoint(event.id, fn
      %Signal{preview: %PreviewState{checkpoint: checkpoint}} when is_map(checkpoint) ->
        {:ok,
         checkpoint
         |> Map.delete("refresh_pending")
         |> Map.delete("refresh_reason")
         |> Map.put("presentation_owner", false)
         |> Map.put("recovery_state", %{
           "state" => "delegated",
           "reason" => "plain_text_fallback",
           "detail" => Sanitizer.transport(detail),
           "delegated_at" => delegated_at
         })}

      %Signal{} ->
        {:error, :reply_preview_checkpoint_missing}
    end)
    |> case do
      {:ok, _event} ->
        Logging.info(
          "conversations.delivery.preview.delivery_delegated",
          "AI reply preview delegated terminal delivery to durable intent",
          signal_fields(event, %{reason: "plain_text_fallback"})
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
  defp block_recovery(%Signal{} = event, reason) do
    recovery_state = blocked_recovery_state(reason)

    PreviewState.update_checkpoint(event.id, fn
      %Signal{preview: %PreviewState{checkpoint: checkpoint}} when is_map(checkpoint) ->
        {:ok,
         checkpoint
         |> Map.delete("refresh_pending")
         |> Map.delete("refresh_reason")
         |> Map.put("recovery_state", recovery_state)}

      %Signal{} ->
        {:error, :reply_preview_checkpoint_missing}
    end)
    |> case do
      {:ok, _event} ->
        Logging.warning(
          "conversations.delivery.preview.recovery_blocked",
          "AI reply preview recovery stopped",
          signal_fields(event, %{reason: inspect(reason, limit: 20)})
        )

      {:error, block_error} ->
        Logging.warning(
          "conversations.delivery.preview.recovery_block_failed",
          "AI reply preview recovery could not persist its blocked state",
          signal_fields(event, %{
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

  @impl GenServer
  def init({%Signal{} = event, subject_uid, conversation_id, stream_signal_id, opts}) do
    Ankole.Repo.put_tenant_id(event.tenant_id)

    case claim_owner(event, subject_uid, conversation_id, stream_signal_id, opts) do
      {:ok, event} -> init_owner(event, subject_uid, conversation_id, stream_signal_id, opts)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_owner(event, subject_uid, conversation_id, stream_signal_id, opts) do
    event = PreviewState.load(event)

    case Events.subscribe(subject_uid, conversation_id) do
      :ok -> :ok
      {:error, reason} -> raise "cannot subscribe AI reply preview: #{inspect(reason)}"
    end

    rich_adapter = PreviewAdapter.for_event(event)
    rich? = match?(%PreviewAdapter{}, rich_adapter)
    preview_editable? = rich? or editable_intent?(event)
    checkpoint = PreviewState.get(event).checkpoint || %{}

    resuming? =
      is_map(checkpoint["presentation"]) or PreviewAdapter.surface?(rich_adapter, checkpoint)

    stream_event =
      if event.id == stream_signal_id,
        do: event,
        else: PreviewState.load_signal(stream_signal_id)

    presentation =
      checkpoint
      |> Map.get("presentation")
      |> ReplyPresentation.normalize()
      |> ReplyPresentation.project_trigger(event.type, Signal.envelope(event))

    initial_flush_ms =
      cond do
        not rich? -> @edit_flush_interval_ms
        resuming? -> 0
        true -> @rich_creation_debounce_ms
      end

    Process.send_after(self(), :flush_edit, initial_flush_ms)

    state = %{
      signal: event,
      driver: preview_driver(event, opts),
      stream_signal_id: stream_signal_id,
      structured_reply: stream_event.type in ["cron.fire", "check_back_later.wakeup"],
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
      # still uses the intent path. A conversation that cannot edit an entry never
      # gets a plain-text preview: the first fragment would become the only
      # message, and the final reply would turn into an edit the adapter
      # refuses.
      preview_editable: preview_editable?,
      preview_disabled: not preview_editable?,
      # Monotonic key segment for best-effort preview edits.
      edit_sequence: 0,
      dirty: rich? and resuming?,
      preview_adapter: rich_adapter,
      presentation: presentation,
      rich_task: nil,
      rich_task_kind: nil,
      rich_task_generation: nil,
      rich_task_presentation: nil,
      rich_retry_ms: 1_000,
      rich_retry_at: nil,
      silent_success_allowed: Scheduled.silent_success_allowed?(event),
      # A quiet scheduled turn must not open a card before its result is known.
      silent_rich_pending: rich? and Scheduled.silent_success_allowed?(event) and not resuming?,
      input_superseded: false,
      handoff: nil,
      stopping: false
    }

    {:ok, state}
  end

  @doc false
  def lookup(id, timeout_ms \\ 5_000) do
    with %Signal{} = event <-
           PreviewState.load_signal(id),
         pid when is_pid(pid) <- preview_pid(event),
         true <- GenServer.call(pid, {:owns_event, id}, timeout_ms) do
      [{pid, nil}]
    else
      _missing -> []
    end
  catch
    :exit, {:noproc, _call} -> []
    :exit, _reason -> {:error, :reply_preview_owner_unavailable}
  end

  defp preview_pid(%Signal{} = event) do
    {:global, name} = via_tuple(event)
    :global.whereis_name(name)
  end

  defp cast_for_event(id, message) when is_binary(id),
    do: cast_for_event(PreviewState.load_signal(id), message)

  defp cast_for_event(%Signal{} = event, message) do
    case preview_pid(event) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:for_event, event.id, message})
      :undefined -> :ok
    end
  end

  defp cast_for_event(nil, _message), do: :ok

  defp preview_driver(event, opts) do
    driver = Keyword.get(opts, :driver) || Ankole.Sessions.driver_pid(event)
    if is_pid(driver), do: {driver, Process.monitor(driver)}, else: nil
  end

  defp claim_owner(event, subject_uid, conversation_id, stream_id, opts) do
    event.id
    |> Ankole.Conversations.claim_preview_owner(subject_uid, conversation_id, stream_id, opts)
    |> Ankole.Errors.reason()
  end

  @doc false
  def claim_owner_in_tx(repo, signal_id, subject_uid, conversation_id, stream_id, opts) do
    with :ok <- authorize_owner_in_tx(repo, opts),
         %Signal{} = current <-
           PreviewState.load(Ankole.Signals.lock_signal_in_tx(repo, signal_id)) do
      checkpoint = PreviewState.get(current).checkpoint || %{}

      checkpoint =
        checkpoint
        |> Map.put("subject_uid", subject_uid)
        |> Map.put("conversation_id", conversation_id)
        |> Map.put("stream_signal_id", stream_id)
        |> Map.put("presentation_owner", true)
        |> Map.put("owner_generation", non_negative_integer(checkpoint["owner_generation"]) + 1)
        |> Map.delete("continued_to_signal_id")

      PreviewState.put_checkpoint_in_tx(repo, current, checkpoint)
    else
      nil -> {:error, :signal_not_found}
      error -> error
    end
  end

  @doc false
  def authorize_owner_in_tx(repo, opts) do
    case Keyword.get(opts, :run) do
      nil -> :ok
      run -> Ankole.Sessions.Fence.check_in_tx(repo, run, :share)
    end
  end

  @impl GenServer
  def handle_call({:owns_event, id}, _from, state),
    do: {:reply, id in [state.stream_signal_id, state.signal.id], state}

  def handle_call({:adopt_driver, stream_id, opts}, _from, state)
      when stream_id != state.stream_signal_id do
    if Keyword.get(opts, :driver) do
      case opts |> Ankole.Conversations.authorize_preview_owner() |> Ankole.Errors.reason() do
        {:ok, :authorized} ->
          if state.rich_task do
            {:reply, :retiring, %{state | stopping: true}}
          else
            checkpoint_latest_rich_presentation(state)
            {:stop, :normal, :retiring, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :reply_preview_not_recoverable}, state}
    end
  end

  def handle_call({:adopt_driver, _stream_id, opts}, _from, state) do
    if Keyword.get(opts, :driver),
      do: adopt_driver(opts, state),
      else: {:reply, :ok, state}
  end

  def handle_call({:continue_on, %Signal{} = new_owner}, from, state) do
    cond do
      state.signal.id == new_owner.id ->
        {:reply, :ok, state}

      not valid_handoff_owner?(state.signal, new_owner) ->
        {:reply, {:error, :invalid_reply_preview_owner}, state}

      not is_nil(state.handoff) ->
        {:reply, {:error, :reply_preview_handoff_in_progress}, state}

      true ->
        state
        |> Map.put(:handoff, %{from: from, new_owner: new_owner})
        |> continue_pending_handoff()
    end
  end

  defp adopt_driver(opts, state) do
    driver = Keyword.fetch!(opts, :driver)

    case state.driver do
      {^driver, _ref} ->
        {:reply, :ok, state}

      _previous ->
        case claim_owner(
               state.signal,
               state.subject_uid,
               state.conversation_id,
               state.stream_signal_id,
               opts
             ) do
          {:ok, event} ->
            if state.driver, do: Process.demonitor(elem(state.driver, 1), [:flush])

            {:reply, :ok,
             %{
               state
               | driver: preview_driver(event, opts),
                 signal: event,
                 owner_generation:
                   PreviewState.get(event).checkpoint[
                     "owner_generation"
                   ],
                 stopping: false
             }}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_cast({:for_event, id, message}, state) do
    if id in [state.stream_signal_id, state.signal.id],
      do: handle_cast(message, state),
      else: {:noreply, state}
  end

  def handle_cast(:stop, %{rich_task: nil} = state), do: finish_rich_stop(state)

  def handle_cast(:stop, state) do
    {:noreply, %{state | stopping: true, rich_retry_at: nil, dirty: false}}
  end

  def handle_cast(_message, %{stopping: true} = state), do: {:noreply, state}

  def handle_cast(:input_superseded, state) do
    {:noreply, show_input_superseded(state)}
  end

  def handle_cast(:cleanup_thought, %{preview_adapter: %PreviewAdapter{}} = state) do
    presentation = ReplyPresentation.checkpoint(state.presentation)
    {:noreply, %{state | presentation: presentation, dirty: true}}
  end

  def handle_cast(:cleanup_thought, state), do: {:noreply, state}

  def handle_cast(
        {:presentation_event, _event},
        %{preview_adapter: %PreviewAdapter{}, silent_rich_pending: true} = state
      ),
      do: {:noreply, state}

  def handle_cast(
        {:presentation_event, event},
        %{preview_adapter: %PreviewAdapter{}} = state
      ) do
    kind = Map.get(event, "kind") || Map.get(event, "type")
    payload = Map.get(event, "payload") || event

    presentation =
      if (is_binary(kind) or is_atom(kind)) and is_map(payload) do
        payload = Map.put_new(payload, "revision", state.presentation["revision"] + 1)
        ReplyPresentation.apply_event(state.presentation, kind, payload)
      else
        state.presentation
      end

    {:noreply, mark_rich_dirty(state, presentation)}
  end

  def handle_cast({:presentation_event, _event}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, driver, _reason}, %{driver: {driver, ref}} = state) do
    handle_cast(:stop, state)
  end

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
    if match?(%PreviewAdapter{}, state.preview_adapter) do
      state = maybe_start_rich_sync(state)
      Process.send_after(self(), :flush_edit, @rich_flush_interval_ms)
      {:noreply, state}
    else
      handle_plain_text_flush(state)
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_plain_text_flush(state) do
    text = Text.normalize_visible_text(state.preview_text)

    state =
      if (text != "" and state.dirty) && state.preview_established && state.preview_entry_id do
        {edit_sequence, edit_key} = next_edit_key(state, "flush")

        case edit_preview(state.signal, state.preview_entry_id, text, edit_key) do
          :ok ->
            %{state | dirty: false, edit_sequence: edit_sequence}

          {:error, reason} ->
            Logging.debug(
              "conversations.delivery.preview.edit_failed",
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

    Process.send_after(self(), :flush_edit, @edit_flush_interval_ms)
    {:noreply, state}
  end

  defp handle_gateway_event(:response_started, _payload, state) do
    {:noreply, reset_for_response_started(state)}
  end

  # Scheduled model text is a result envelope. Only durable completion can
  # validate it and project its reply field to a conversation.
  defp handle_gateway_event(:output_text_delta, _payload, %{structured_reply: true} = state),
    do: {:noreply, state}

  defp handle_gateway_event(:output_text_delta, payload, state) do
    delta = map_value(payload, :text)

    if is_binary(delta) do
      input_superseded? = state.input_superseded
      new_buffer = state.text_buffer <> delta

      if ordinary_silent_success_candidate?(state, new_buffer) do
        {:noreply, %{state | text_buffer: new_buffer}}
      else
        preview_text = Text.normalize_visible_text(new_buffer)
        candidate_before? = ordinary_silent_success_candidate?(state, state.text_buffer)

        state = %{
          state
          | text_buffer: new_buffer,
            preview_text: preview_text,
            input_superseded: false
        }

        if match?(%PreviewAdapter{}, state.preview_adapter) do
          presentation_delta = if candidate_before?, do: new_buffer, else: delta

          presentation =
            if input_superseded? do
              ReplyPresentation.replace_answer(state.presentation, presentation_delta)
            else
              ReplyPresentation.append_answer(state.presentation, presentation_delta)
            end

          {:noreply,
           state
           |> Map.put(:silent_rich_pending, false)
           |> mark_rich_dirty(presentation)}
        else
          handle_plain_text_output_delta(state, preview_text)
        end
      end
    else
      {:noreply, state}
    end
  end

  defp handle_gateway_event(:reasoning_delta, payload, state) do
    if match?(%PreviewAdapter{}, state.preview_adapter) and
         not state.silent_rich_pending do
      presentation = ReplyPresentation.apply_event(state.presentation, "reasoning.delta", payload)
      {:noreply, mark_rich_dirty(state, presentation)}
    else
      {:noreply, state}
    end
  end

  defp handle_gateway_event(:tool_call_started, payload, state) do
    if match?(%PreviewAdapter{}, state.preview_adapter) do
      {:noreply, state}
    else
      {:noreply, handle_tool_activity(state, :started, payload)}
    end
  end

  defp handle_gateway_event(:tool_call_completed, payload, state) do
    if match?(%PreviewAdapter{}, state.preview_adapter) do
      {:noreply, state}
    else
      {:noreply, handle_tool_activity(state, :completed, payload)}
    end
  end

  defp handle_gateway_event(event_type, _payload, state)
       when event_type in [:response_completed, :response_failed, :response_incomplete],
       do: {:noreply, state}

  defp handle_gateway_event(_event_type, _payload, state), do: {:noreply, state}

  defp ordinary_silent_success_candidate?(_state, text) when is_binary(text) do
    String.starts_with?(@silent_success_marker, String.trim(text))
  end

  defp handle_plain_text_output_delta(state, preview_text) do
    state =
      cond do
        state.preview_disabled ->
          state

        not state.preview_established ->
          if preview_text == "" do
            state
          else
            case establish_preview(state.signal, preview_text) do
              {:ok, entry_id} ->
                %{
                  state
                  | preview_entry_id: entry_id,
                    preview_established: true,
                    dirty: false
                }

              {:error, reason} ->
                Logging.warning(
                  "conversations.delivery.preview.establish_failed",
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

    if match?(%PreviewAdapter{}, state.preview_adapter) and
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
    text = I18n.t("conversations.delivery.reply.input_superseded")

    cond do
      match?(%PreviewAdapter{}, state.preview_adapter) ->
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

        case edit_preview(state.signal, state.preview_entry_id, text, edit_key) do
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

      match?(%PreviewAdapter{}, state.preview_adapter) ->
        continued = ReplyPresentation.continued(state.presentation)

        request = %Request{
          signal: state.signal,
          subject_uid: state.subject_uid,
          conversation_id: state.conversation_id,
          presentation: continued,
          mode: :terminal
        }

        adapter = state.preview_adapter

        task =
          Task.Supervisor.async_nolink(
            Ankole.Conversations.Delivery.PreviewTasks,
            Ankole.Repo.bind_tenant(fn -> PreviewAdapter.finalize(adapter, request) end)
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

  defp switch_presentation_owner(state, %Signal{} = new_owner, handoff_result) do
    continued = ReplyPresentation.continued(state.presentation)
    new_presentation = ReplyPresentation.new(state: "working")
    old_visible? = old_preview_visible?(state)
    refresh_old? = old_visible? and match?({:error, _reason}, handoff_result)

    handoff = %{
      continued: continued,
      new_presentation: new_presentation,
      old_visible?: old_visible?,
      refresh_old?: refresh_old?
    }

    state
    |> Ankole.Conversations.switch_preview_owner(new_owner, handoff)
    |> Ankole.Errors.reason()
    |> case do
      {:ok, %{new_owner: new_owner}} ->
        checkpoint = PreviewState.get(new_owner).checkpoint || %{}
        presentation = ReplyPresentation.normalize(checkpoint["presentation"])

        preview_entry_id =
          PreviewState.get(new_owner).provider_message_id

        {:ok,
         %{
           state
           | signal: new_owner,
             owner_generation: checkpoint["owner_generation"],
             text_buffer: "",
             preview_text: "",
             tool_calls: %{},
             preview_entry_id: preview_entry_id,
             preview_established: is_binary(preview_entry_id),
             preview_disabled: not state.preview_editable,
             edit_sequence: 0,
             dirty: false,
             presentation: presentation,
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

  @doc false
  def switch_owner_in_tx(repo, state, %Signal{} = new_owner, handoff) do
    with :ok <-
           Queue.lock_session_in_tx(
             repo,
             state.signal.agent_uid,
             state.signal.session_id
           ),
         %Signal{} = old_event <-
           PreviewState.load(Ankole.Signals.lock_signal_in_tx(repo, state.signal.id)),
         %Signal{} = new_event <-
           PreviewState.load(Ankole.Signals.lock_signal_in_tx(repo, new_owner.id)),
         true <- valid_handoff_owner?(old_event, new_event),
         true <-
           non_negative_integer(
             (PreviewState.get(old_event).checkpoint || %{})[
               "owner_generation"
             ]
           ) ==
             state.owner_generation,
         next_generation =
           max(
             state.owner_generation,
             non_negative_integer(
               (PreviewState.get(new_event).checkpoint || %{})[
                 "owner_generation"
               ]
             )
           ) + 1,
         {:ok, old_event} <-
           persist_previous_owner_in_tx(
             repo,
             old_event,
             new_event.id,
             state.owner_generation,
             handoff.continued,
             handoff.old_visible?,
             handoff.refresh_old?
           ),
         {:ok, new_event} <-
           persist_new_owner_in_tx(
             repo,
             new_event,
             state,
             next_generation,
             handoff.new_presentation
           ) do
      {:ok, %{old_owner: old_event, new_owner: new_event}}
    else
      false -> {:error, :invalid_reply_preview_owner}
      nil -> {:error, :signal_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp persist_previous_owner_in_tx(
         _repo,
         %Signal{preview: %PreviewState{checkpoint: nil}} = event,
         _new_owner_id,
         _generation,
         _continued,
         false,
         _refresh?
       ),
       do: {:ok, event}

  defp persist_previous_owner_in_tx(
         repo,
         %Signal{} = event,
         new_owner_id,
         generation,
         continued,
         visible?,
         refresh?
       ) do
    checkpoint =
      (PreviewState.get(event).checkpoint || %{})
      |> Map.put("presentation_owner", false)
      |> Map.put("owner_generation", generation)
      |> Map.put("continued_to_signal_id", new_owner_id)
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

    PreviewState.put_checkpoint_in_tx(repo, event, checkpoint)
  end

  defp persist_new_owner_in_tx(repo, %Signal{} = event, state, generation, presentation) do
    checkpoint =
      (PreviewState.get(event).checkpoint || %{})
      |> Map.put("subject_uid", state.subject_uid)
      |> Map.put("conversation_id", state.conversation_id)
      |> Map.put("stream_signal_id", state.stream_signal_id)
      |> Map.put("presentation_owner", true)
      |> Map.put("owner_generation", generation)
      |> Map.put("presentation", ReplyPresentation.checkpoint(presentation))
      |> Map.delete("continued_to_signal_id")

    PreviewState.put_checkpoint_in_tx(repo, event, checkpoint)
  end

  defp old_preview_visible?(state) do
    state.preview_established or
      PreviewAdapter.surface?(
        state.preview_adapter,
        PreviewState.get(state.signal).checkpoint
      )
  end

  defp freeze_plain_preview(state) do
    text = continued_plain_text(state.preview_text)
    {_edit_sequence, edit_key} = next_edit_key(state, "continued")

    case edit_preview(state.signal, state.preview_entry_id, text, edit_key) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp continued_plain_text(text) do
    status = I18n.t("conversations.delivery.reply.continued")

    case Text.normalize_visible_text(text) do
      "" -> status
      visible -> visible <> "\n\n" <> status
    end
  end

  defp valid_handoff_owner?(%Signal{} = current, %Signal{} = new_owner) do
    channel_reply_eligible?(new_owner) and
      current.agent_uid == new_owner.agent_uid and
      current.reply_binding_name == new_owner.reply_binding_name and
      current.session_id == new_owner.session_id and
      current.conversation_id == new_owner.conversation_id
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
        signal: state.signal,
        subject_uid: state.subject_uid,
        conversation_id: state.conversation_id,
        presentation: presentation,
        mode: :working
      }

      adapter = state.preview_adapter

      task =
        Task.Supervisor.async_nolink(
          Ankole.Conversations.Delivery.PreviewTasks,
          Ankole.Repo.bind_tenant(fn -> PreviewAdapter.update(adapter, request) end)
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
        PreviewState.get(state.signal).checkpoint

    entry_id = created_provider_message_id(result) || state.preview_entry_id

    signal =
      if is_map(checkpoint) do
        %{
          state.signal
          | preview: %{
              PreviewState.get(state.signal)
              | checkpoint: checkpoint
            }
        }
      else
        state.signal
      end

    %{
      state
      | signal: signal,
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
      "conversations.delivery.preview.rich_sync_failed",
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
    Ankole.Attrs.reply_delivery_retry_after_seconds(detail) * 1_000
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
           preview_adapter: %PreviewAdapter{},
           silent_rich_pending: false
         } = state
       ) do
    latest_presentation = ReplyPresentation.checkpoint(state.presentation)

    state
    |> Ankole.Conversations.checkpoint_preview_presentation(latest_presentation)
    |> Ankole.Errors.reason()
    |> case do
      {:ok, _event} ->
        :ok

      # A retracted source entry takes its Signal with it. There is no
      # state left to keep, and the cards this preview opened are already
      # queued for deletion.
      {:error, :signal_not_found} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "conversations.delivery.preview.checkpoint_before_stop_failed",
          "AI reply preview could not checkpoint its latest presentation before stopping",
          preview_fields(state, %{reason: inspect(reason, limit: 20)})
        )
    end
  end

  defp checkpoint_latest_rich_presentation(_state), do: :ok

  @doc false
  def checkpoint_presentation_in_tx(repo, state, latest_presentation) do
    case PreviewState.load(Ankole.Signals.lock_signal_in_tx(repo, state.signal.id)) do
      %Signal{} = event ->
        checkpoint = PreviewState.get(event).checkpoint || %{}
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
              |> Map.put_new("stream_signal_id", state.stream_signal_id)
              |> Map.put_new("presentation_owner", true)
              |> Map.put_new("owner_generation", state.owner_generation)
              |> Map.put("presentation", latest_presentation)

            PreviewState.put_checkpoint_in_tx(repo, event, checkpoint)
        end

      nil ->
        {:error, :signal_not_found}
    end
  end

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
    call_id = Ankole.Attrs.optional_text(payload["call_id"])
    name = tool_activity_name(payload, call_id, state.tool_calls)
    tool_calls = remember_tool_call(state.tool_calls, call_id, name)
    text = tool_activity_text(stage, name)

    state
    |> Map.put(:tool_calls, tool_calls)
    |> upsert_preview_text(text, "tool-#{stage}")
  end

  defp handle_tool_activity(state, _stage, _payload), do: state

  defp upsert_preview_text(state, text, edit_prefix) do
    case Text.normalize_visible_text(text) do
      "" ->
        state

      preview_text ->
        state = %{state | preview_text: preview_text}

        cond do
          state.preview_disabled ->
            state

          not state.preview_established ->
            case establish_preview(state.signal, preview_text) do
              {:ok, entry_id} ->
                %{state | preview_entry_id: entry_id, preview_established: true, dirty: false}

              {:error, reason} ->
                Logging.warning(
                  "conversations.delivery.preview.establish_failed",
                  "AI reply preview establish failed",
                  preview_fields(state, %{reason: inspect(reason)})
                )

                %{state | preview_disabled: true}
            end

          is_binary(state.preview_entry_id) ->
            {edit_sequence, edit_key} = next_edit_key(state, edit_prefix)

            case edit_preview(state.signal, state.preview_entry_id, preview_text, edit_key) do
              :ok ->
                %{state | dirty: false, edit_sequence: edit_sequence}

              {:error, reason} ->
                Logging.debug(
                  "conversations.delivery.preview.tool_activity_edit_failed",
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
      Ankole.Attrs.optional_text(
        payload["name"] || payload["tool"] ||
          payload["type"]
      ) ||
        tool_name_from_output(payload["output"]) ||
        if(is_binary(call_id), do: Map.get(tool_calls, call_id)) ||
        call_id ||
        "tool"

    case Ankole.Attrs.optional_text(payload["namespace"]) do
      nil -> name
      namespace -> "#{namespace}.#{name}"
    end
  end

  defp tool_name_from_output(%{"tool" => tool}), do: Ankole.Attrs.optional_text(tool)
  defp tool_name_from_output(%{tool: tool}), do: Ankole.Attrs.optional_text(tool)
  defp tool_name_from_output(_output), do: nil

  defp tool_activity_text(:started, name) do
    I18n.t("conversations.delivery.reply.tool_call_started", %{"tool" => truncate_tool_name(name)})
  end

  defp tool_activity_text(:completed, name) do
    I18n.t("conversations.delivery.reply.tool_call_completed", %{
      "tool" => truncate_tool_name(name)
    })
  end

  defp truncate_tool_name(name) do
    name = Ankole.Attrs.optional_text(name) || "tool"

    if String.length(name) > 80 do
      String.slice(name, 0, 77) <> "..."
    else
      name
    end
  end

  defp establish_preview(%Signal{} = event, text) do
    with {:ok, result} <- send_new_reply(event, text, nil, "ai-preview:#{event.id}"),
         entry_id when is_binary(entry_id) <- created_provider_message_id(result),
         :ok <-
           PreviewState.record_provider_message(event.id, entry_id) do
      {:ok, entry_id}
    else
      nil -> {:error, :preview_entry_id_missing}
      {:error, _reason} = error -> error
      :unknown -> {:error, :provider_send_unknown}
      other -> {:error, {:unexpected_preview_result, other}}
    end
  end

  defp edit_preview(%Signal{} = event, entry_id, text, edit_key) do
    key = "ai-preview:#{event.id}:edit:#{entry_id}:#{edit_key}"

    case deliver_intent(event, :edit, text,
           target_provider_message_id: entry_id,
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
    signal_fields(state.signal, extra)
  end

  defp signal_fields(%Signal{} = event, extra) do
    %{
      signal_id: event.id,
      agent_uid: event.agent_uid,
      binding_name: event.reply_binding_name
    }
    |> Map.merge(extra)
  end

  defp send_new_reply(%Signal{} = event, text, ai_message_id, idempotency_key) do
    with text when is_binary(text) and text != "" <- normalize_text(text),
         {:ok, operation} <- Delivery.operation_for_signal(event) do
      deliver_intent(event, operation, text,
        ai_message_id: ai_message_id,
        outbound_key: idempotency_key,
        idempotency_key: idempotency_key
      )
    else
      "" -> {:error, :empty_reply_text}
      {:error, _reason} = error -> error
    end
  end

  # A preview message is transient, so it never becomes an intent row that
  # `dispatch` could degrade. Apply the same adapter degrade here before
  # handing the entry to the adapter.
  defp deliver_intent(%Signal{} = event, operation, text, opts) do
    with {:ok, adapter} <- adapter_for_event(event) do
      operation =
        Delivery.effective_operation(operation, Adapter.capabilities(adapter))

      event
      |> transient_intent(operation, text, opts)
      |> then(&Adapter.deliver(adapter, &1))
    end
  end

  defp transient_intent(%Signal{} = event, operation, text, opts) do
    %Intent{
      agent_uid: event.agent_uid,
      delivery_class: :generic,
      status: :pending,
      possible_duplicate: false,
      binding_name: event.reply_binding_name,
      outbound_key: Keyword.fetch!(opts, :outbound_key),
      operation: operation,
      conversation_id: event.conversation_id,
      provider_thread_id: event.provider_thread_id,
      reply_to_provider_message_id:
        if(operation == :reply, do: Signal.reply_anchor_provider_message_id(event)),
      target_provider_message_id: Keyword.get(opts, :target_provider_message_id),
      # Source table: preview side effects are caused by this signals.id.
      source_signal_id: event.id,
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

  defp adapter_for_event(%Signal{} = event) do
    with {:ok, binding} <- binding_for_event(event) do
      Adapters.fetch_delivery(binding.adapter)
    end
  end

  # The plain-text preview posts the first fragment and then edits it in
  # place, so it needs `edit_entry`. An unresolved adapter counts as not
  # editable; the durable final reply does not depend on this answer.
  defp editable_intent?(%Signal{} = event) do
    case adapter_for_event(event) do
      {:ok, adapter} -> MapSet.member?(Adapter.capabilities(adapter), :edit_entry)
      {:error, _reason} -> false
    end
  end

  defp binding_for_event(%Signal{} = event) do
    Ankole.Signals.Bindings.get_binding(event.agent_uid, event.reply_binding_name)
  end

  defp created_provider_message_id(result) when is_map(result) do
    Ankole.Attrs.optional_text(Map.get(result, :created_provider_message_id))
  end

  defp normalize_text(text), do: Text.normalize_visible_text(text)

  defp event_matches_actor?(event, state) do
    metadata = map_value(event, :metadata) || %{}

    map_value(event, :subject_uid) == state.subject_uid and
      map_value(event, :conversation_id) == state.conversation_id and
      Map.get(metadata, "signal_id") == state.stream_signal_id
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp map_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key)
end
