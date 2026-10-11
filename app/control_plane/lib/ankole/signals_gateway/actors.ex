defmodule Ankole.SignalsGateway.Actors do
  @moduledoc """
  The durable conversation inbox owned by SignalsGateway.

  SignalsGateway appends normalized events for an actor session. Conversations
  wakes its single Driver. AIGateway owns the durable response facts.

  Append is idempotent on the source ingress key. Every append takes the actor
  session's PostgreSQL advisory lock; `queue_sequence` allocation and
  higher-level session transitions therefore share one deterministic order.

  Several `*_in_tx` functions take a `repo` and run inside a caller-owned
  transaction so actor completion and provider-visible side effects can share
  one database boundary where needed.
  """

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Repo
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.ReplyInteractionState
  alias Ankole.SignalsGateway.ReplyPreviewAdapter
  alias Ankole.SignalsGateway.Sanitizer

  import Ankole.SignalsGateway.Utils, only: [parse_datetime: 1]

  @type append_result ::
          {:ok, ActorEvent.t()}
          | {:error, term()}
  @type actor_commit_result :: {:ok, ActorEvent.t()} | {:error, term()}

  @doc """
  Appends an actor event inside the caller-owned transaction.
  """
  @spec append_actor_event_in_tx(module(), map()) :: append_result()
  def append_actor_event_in_tx(repo, attrs) when is_map(attrs) do
    :ok =
      lock_actor_session_in_tx(
        repo,
        Map.fetch!(attrs, :agent_uid),
        Map.fetch!(attrs, :session_id)
      )

    authorization =
      case Map.get(attrs, :source_work) do
        nil -> Ankole.Principals.WorkAccess.from_sender(repo, Map.get(attrs, :sender_key))
        source -> Ankole.Principals.WorkAccess.fields(source)
      end

    attrs = attrs |> Map.merge(authorization) |> then(&put_queue_sequence(repo, &1))

    with {:ok, %ActorEvent{} = event} <-
           %ActorEvent{}
           |> ActorEvent.changeset(attrs)
           |> repo.insert(
             on_conflict: :nothing,
             conflict_target: [:agent_uid, :binding_name, :source_event_id],
             returning: true
           )
           |> inserted_or_existing(repo, attrs),
         :ok <- schedule_future_input(repo, event) do
      {:ok, event}
    end
  end

  defp schedule_future_input(repo, event) do
    if DateTime.compare(event.available_at, DateTime.utc_now(:microsecond)) == :gt,
      do:
        Ankole.Conversations.Jobs.EnsureDriver.enqueue_in_tx(
          repo,
          %{agent_uid: event.agent_uid, session_id: event.session_id},
          event.available_at
        ),
      else: :ok
  end

  @doc """
  Locks one actor event inside the caller-owned transaction.
  """
  @spec lock_actor_event_in_tx(module(), Ecto.UUID.t()) :: ActorEvent.t() | nil
  def lock_actor_event_in_tx(repo, actor_event_id) do
    ActorEvent
    |> where([event], event.id == ^actor_event_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  @doc """
  Serializes writes that decide ordering or reply-interaction state for one session.

  Callers that also lock ActorEvent rows must take this advisory lock first.
  """
  @spec lock_actor_session_in_tx(module(), String.t(), String.t()) :: :ok
  def lock_actor_session_in_tx(repo, agent_uid, session_id)
      when is_binary(agent_uid) and is_binary(session_id) do
    SQL.query!(
      repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      [agent_uid, session_id]
    )

    :ok
  end

  @doc """
  Records the provider entry created for one live AI reply preview.

  The preview is a SignalsGateway side effect, so its provider identity belongs
  to the ActorEvent rather than to AIGateway Response metadata. The first
  successful provider send wins; repeating the same value is idempotent.
  """
  @spec record_reply_preview_source_entry(Ecto.UUID.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def record_reply_preview_source_entry(
        actor_event_id,
        source_entry_id,
        provider_thread_id \\ nil
      )

  def record_reply_preview_source_entry(
        actor_event_id,
        source_entry_id,
        provider_thread_id
      )
      when is_binary(actor_event_id) and is_binary(source_entry_id) and source_entry_id != "" and
             (is_nil(provider_thread_id) or
                (is_binary(provider_thread_id) and provider_thread_id != "")) do
    case Repo.transact(fn repo ->
           case lock_actor_event_in_tx(repo, actor_event_id) do
             %ActorEvent{} = event ->
               record_reply_preview_source_in_tx(repo, event, source_entry_id, provider_thread_id)

             nil ->
               {:error, :actor_event_not_found}
           end
         end) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def record_reply_preview_source_entry(_actor_event_id, _source_entry_id, _provider_thread_id),
    do: {:error, :invalid_reply_preview_source_entry}

  defp record_reply_preview_source_in_tx(repo, event, source_entry_id, provider_thread_id)
       when is_binary(source_entry_id) and source_entry_id != "" and
              (is_nil(provider_thread_id) or
                 (is_binary(provider_thread_id) and provider_thread_id != "")) do
    case event do
      %ActorEvent{reply_preview_source_entry_id: nil} ->
        event
        |> ActorEvent.changeset(preview_source_attrs(source_entry_id, provider_thread_id))
        |> repo.update()
        |> case do
          {:ok, _event} -> {:ok, :recorded}
          {:error, _changeset} = error -> error
        end

      %ActorEvent{reply_preview_source_entry_id: ^source_entry_id} ->
        record_preview_thread(repo, event, provider_thread_id)

      %ActorEvent{} ->
        {:error, :reply_preview_source_entry_already_recorded}
    end
  end

  defp record_reply_preview_source_in_tx(_repo, _event, _source_entry_id, _provider_thread_id),
    do: {:error, :invalid_reply_preview_source_entry}

  defp preview_source_attrs(source_entry_id, nil),
    do: %{reply_preview_source_entry_id: source_entry_id}

  defp preview_source_attrs(source_entry_id, provider_thread_id),
    do: %{
      reply_preview_source_entry_id: source_entry_id,
      provider_thread_id: provider_thread_id
    }

  defp record_preview_thread(_repo, %ActorEvent{provider_thread_id: nil}, nil),
    do: {:ok, :already_recorded}

  defp record_preview_thread(
         repo,
         %ActorEvent{provider_thread_id: nil} = event,
         provider_thread_id
       ) do
    event
    |> ActorEvent.changeset(%{provider_thread_id: provider_thread_id})
    |> repo.update()
    |> case do
      {:ok, _event} -> {:ok, :thread_recorded}
      {:error, _changeset} = error -> error
    end
  end

  defp record_preview_thread(
         _repo,
         %ActorEvent{provider_thread_id: provider_thread_id},
         provider_thread_id
       ),
       do: {:ok, :already_recorded}

  defp record_preview_thread(_repo, %ActorEvent{}, nil), do: {:ok, :already_recorded}

  defp record_preview_thread(_repo, %ActorEvent{}, _provider_thread_id),
    do: {:error, :reply_preview_provider_thread_already_recorded}

  @doc """
  Persists the provider-neutral recovery checkpoint for one live reply surface.

  The checkpoint contains no transient reasoning. Provider-specific sequence
  allocation remains a separate atomic operation so a restarted process can
  safely lease a strictly higher range before a provider mutation.
  """
  @spec put_reply_preview_checkpoint(Ecto.UUID.t(), map(), {String.t(), String.t() | nil} | nil) ::
          {:ok, ActorEvent.t()} | {:error, term()}
  def put_reply_preview_checkpoint(actor_event_id, checkpoint, source \\ nil)

  def put_reply_preview_checkpoint(actor_event_id, checkpoint, source)
      when is_binary(actor_event_id) and is_map(checkpoint) do
    case Repo.transact(fn repo ->
           with %ActorEvent{} = event <- lock_actor_event_in_tx(repo, actor_event_id),
                {:ok, event} <- put_reply_preview_checkpoint_in_tx(repo, event, checkpoint) do
             checkpoint_source_result(repo, event, source)
           else
             nil -> {:error, :actor_event_not_found}
             {:error, _reason} = error -> error
           end
         end) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  def put_reply_preview_checkpoint(_actor_event_id, _checkpoint, _source),
    do: {:error, :invalid_reply_preview_checkpoint}

  defp checkpoint_source_result(_repo, event, nil), do: {:ok, {:ok, event}}

  defp checkpoint_source_result(repo, event, {source_entry_id, provider_thread_id}) do
    case record_reply_preview_source_in_tx(repo, event, source_entry_id, provider_thread_id) do
      {:ok, _recorded} ->
        {:ok, {:ok, event}}

      # Commit the checkpoint even when its source conflicts. A retry must
      # not repeat the completed provider operation.
      {:error, reason} ->
        {:ok, {:error, {:reply_preview_source_entry, reason}}}
    end
  end

  @doc false
  @spec put_reply_preview_checkpoint_in_tx(module(), ActorEvent.t(), map()) ::
          {:ok, ActorEvent.t()} | {:error, term()}
  def put_reply_preview_checkpoint_in_tx(repo, %ActorEvent{} = event, checkpoint)
      when is_map(checkpoint) do
    existing = ReplyPreviewAdapter.adapter_checkpoint(event.reply_preview_checkpoint)
    checkpoint = ReplyPreviewAdapter.adapter_checkpoint(checkpoint)
    checkpoint = preserve_reply_preview_owner_fence(existing, checkpoint)

    with :ok <- validate_reply_preview_owner_fence(event.id, existing, checkpoint) do
      surface_fun = fn merged ->
        event
        |> ReplyPreviewAdapter.for_event()
        |> ReplyPreviewAdapter.surface?(merged)
      end

      checkpoint =
        existing
        |> ReplyInteractionState.merge_checkpoint(checkpoint, surface_fun)
        |> then(fn checkpoint ->
          Map.put(
            checkpoint,
            "sequence_high_water",
            max(
              event.reply_preview_sequence_high_water || 0,
              checkpoint_sequence(checkpoint)
            )
          )
        end)
        |> ReplyPreviewAdapter.persisted_checkpoint()

      with {:ok, updated} <-
             event
             |> ActorEvent.changeset(%{
               reply_preview_checkpoint: checkpoint
             })
             |> repo.update(),
           :ok <- notify_preview_in_tx(repo, updated) do
        {:ok, updated}
      end
    end
  end

  defp preserve_reply_preview_owner_fence(existing, incoming) do
    Enum.reduce(
      ["stream_actor_event_id", "presentation_owner", "owner_generation"],
      incoming,
      fn key, checkpoint ->
        if Map.has_key?(checkpoint, key) or not Map.has_key?(existing, key) do
          checkpoint
        else
          Map.put(checkpoint, key, existing[key])
        end
      end
    )
  end

  defp validate_reply_preview_owner_fence(actor_event_id, existing, incoming) do
    existing_generation = checkpoint_owner_generation(existing)
    incoming_generation = checkpoint_owner_generation(incoming)
    existing_owner? = Map.get(existing, "presentation_owner", true)
    incoming_owner? = Map.get(incoming, "presentation_owner", existing_owner?)
    incoming_state = get_in(incoming, ["presentation", "state"])

    dispatched_rebase? =
      existing_owner? == false and incoming_owner? == true and
        incoming_generation > existing_generation and
        incoming["stream_actor_event_id"] == actor_event_id and
        existing["stream_actor_event_id"] != actor_event_id

    cond do
      incoming_generation < existing_generation ->
        {:error, :stale_reply_preview_owner_generation}

      existing_owner? == false and incoming_owner? != false and not dispatched_rebase? ->
        {:error, :stale_reply_preview_owner}

      existing_owner? == false and incoming_generation == existing_generation and
          incoming_state in ["debouncing", "working"] ->
        {:error, :stale_reply_preview_owner}

      true ->
        :ok
    end
  end

  defp checkpoint_owner_generation(%{"owner_generation" => generation})
       when is_integer(generation) and generation >= 0,
       do: generation

  defp checkpoint_owner_generation(_checkpoint), do: 0

  @doc """
  Prepares one durable provider-surface mutation without allocating a second sequence on retry.

  The caller supplies a semantic purpose, an actions digest, and a fresh UUID
  candidate. If the same logical mutation is already pending, its persisted
  sequence and UUID are returned unchanged. A different desired mutation
  supersedes the pending one and receives the next sequence. The returned
  `reused` and `sequence_current` flags are transient reconciliation facts and
  are not added to the durable pending mutation.
  """
  @spec prepare_reply_preview_mutation(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def prepare_reply_preview_mutation(actor_event_id, purpose, actions_digest, uuid)
      when is_binary(actor_event_id) and is_binary(purpose) and purpose != "" and
             is_binary(actions_digest) and actions_digest != "" and is_binary(uuid) and
             uuid != "" do
    Repo.transact(fn repo ->
      case lock_actor_event_in_tx(repo, actor_event_id) do
        %ActorEvent{} = event ->
          checkpoint = ReplyPreviewAdapter.adapter_checkpoint(event.reply_preview_checkpoint)

          case checkpoint["pending_mutation"] do
            %{
              "purpose" => ^purpose,
              "actions_digest" => ^actions_digest,
              "sequence" => sequence,
              "uuid" => persisted_uuid
            } = mutation
            when is_integer(sequence) and sequence > 0 and is_binary(persisted_uuid) ->
              {:ok,
               mutation
               |> Map.put("reused", true)
               |> Map.put(
                 "sequence_current",
                 event.reply_preview_sequence_high_water == sequence
               )}

            _other ->
              case prepare_new_reply_preview_mutation(
                     repo,
                     event,
                     checkpoint,
                     purpose,
                     actions_digest,
                     uuid
                   ) do
                {:ok, mutation} ->
                  {:ok,
                   mutation
                   |> Map.put("reused", false)
                   |> Map.put("sequence_current", true)}

                {:error, _reason} = error ->
                  error
              end
          end

        nil ->
          {:error, :actor_event_not_found}
      end
    end)
  end

  def prepare_reply_preview_mutation(_actor_event_id, _purpose, _actions_digest, _uuid),
    do: {:error, :invalid_reply_preview_mutation}

  defp prepare_new_reply_preview_mutation(
         repo,
         event,
         checkpoint,
         purpose,
         actions_digest,
         uuid
       ) do
    sequence = (event.reply_preview_sequence_high_water || 0) + 1

    if sequence > 2_147_483_647 do
      {:error, :reply_preview_sequence_exhausted}
    else
      mutation = %{
        "purpose" => purpose,
        "actions_digest" => actions_digest,
        "sequence" => sequence,
        "uuid" => uuid
      }

      checkpoint =
        checkpoint
        |> Map.put("pending_mutation", mutation)
        |> Map.put("sequence_high_water", sequence)
        |> ReplyPreviewAdapter.persisted_checkpoint()

      with {:ok, updated} <-
             event
             |> ActorEvent.changeset(%{
               reply_preview_checkpoint: checkpoint,
               reply_preview_sequence_high_water: sequence
             })
             |> repo.update(),
           :ok <- notify_preview_in_tx(repo, updated) do
        {:ok, mutation}
      end
    end
  end

  @doc """
  Requeues reply previews that require an operator repair.

  An operator update to the binding is the explicit requeue signal: it clears
  the blocked `recovery_state` marker, and the checkpoint notification lets
  the recovery scan attempt the preview again.
  """
  @spec wake_blocked_reply_previews(String.t(), String.t()) :: :ok | {:error, term()}
  def wake_blocked_reply_previews(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    Repo.transact(fn repo ->
      ActorEvent
      |> where([event], event.agent_uid == ^agent_uid)
      |> where([event], event.binding_name == ^binding_name)
      |> where(
        [event],
        fragment(
          "?->'recovery_state'->>'state' = 'blocked'",
          event.reply_preview_checkpoint
        )
      )
      |> lock("FOR UPDATE")
      |> repo.all()
      |> Enum.reduce_while({:ok, :ok}, fn event, acc ->
        checkpoint = Map.delete(event.reply_preview_checkpoint, "recovery_state")

        case put_reply_preview_checkpoint_in_tx(repo, event, checkpoint) do
          {:ok, _event} -> {:cont, acc}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end)
    |> case do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def wake_blocked_reply_previews(_agent_uid, _binding_name),
    do: {:error, :invalid_signal_binding}

  @doc """
  Completes a locked actor event inside a caller-owned transaction.

  The caller owns any immutable Response reads and projection. This primitive
  owns the source tombstone check, optional outbox insert, and completion
  timestamp.
  """
  @spec complete_actor_event_in_tx(module(), ActorEvent.t(), keyword()) ::
          actor_commit_result()
  def complete_actor_event_in_tx(repo, %ActorEvent{} = actor_event, opts) do
    completed_at = Keyword.get(opts, :completed_at, DateTime.utc_now(:microsecond))

    with :ok <- reject_tombstoned_event_source(repo, actor_event, completed_at),
         {:ok, completed_event} <-
           persist_actor_event_completion_in_tx(
             repo,
             actor_event,
             Keyword.put(opts, :completed_at, completed_at)
           ) do
      {:ok, completed_event}
    end
  end

  @doc """
  Completes a provider-entry lifecycle event without treating its tombstone as cancelation.

  `signal.entry.removed` rows exist because the provider entry was tombstoned
  after earlier actor state already completed it. Re-applying the source-entry
  tombstone guard here would cancel the lifecycle notice itself.
  """
  @spec complete_entry_lifecycle_event_in_tx(module(), ActorEvent.t(), keyword()) ::
          actor_commit_result()
  def complete_entry_lifecycle_event_in_tx(
        repo,
        %ActorEvent{type: "signal.entry.removed"} = actor_event,
        opts
      ) do
    persist_actor_event_completion_in_tx(repo, actor_event, opts)
  end

  @doc """
  Verifies that an actor event's provider source has not been tombstoned.

  Explicit Agent Turn completion uses this before committing provider-visible
  output. Individual Response terminals intentionally leave the ActorEvent
  open and never pass through `complete_actor_event_in_tx/3`.
  """
  @spec ensure_event_source_live_in_tx(module(), ActorEvent.t(), DateTime.t()) ::
          :ok | {:error, :actor_event_canceled | :actor_event_context_canceled}
  def ensure_event_source_live_in_tx(repo, %ActorEvent{} = actor_event, %DateTime{} = now) do
    reject_tombstoned_event_source(repo, actor_event, now)
  end

  @doc """
  Completes a durable command event without requiring a worker turn fence.

  Command feedback is a provider-visible control response, not transcript or
  model output, so it deliberately has no AI message id.
  """
  @spec complete_command_event_in_tx(module(), ActorEvent.t(), keyword()) ::
          actor_commit_result()
  def complete_command_event_in_tx(
        repo,
        %ActorEvent{type: "command." <> _name} = actor_event,
        opts
      ) do
    complete_actor_event_in_tx(repo, actor_event, opts)
  end

  @doc """
  Completes a session-lifecycle event without requiring a worker turn fence.
  """
  @spec complete_session_lifecycle_event_in_tx(module(), ActorEvent.t(), keyword()) ::
          actor_commit_result()
  def complete_session_lifecycle_event_in_tx(
        repo,
        %ActorEvent{type: "session." <> _name} = actor_event,
        opts
      ) do
    complete_actor_event_in_tx(repo, actor_event, opts)
  end

  defp persist_actor_event_completion_in_tx(repo, %ActorEvent{} = actor_event, opts) do
    with {:ok, _outbox_entries} <-
           insert_outbox_intents(repo, actor_event, Keyword.get(opts, :outbox_intents, [])),
         {:ok, %ActorEvent{} = updated} <-
           mark_event_completed(repo, actor_event, completion_attrs(opts)) do
      {:ok, updated}
    end
  end

  def mark_event_completed_in_tx(repo, %ActorEvent{} = actor_event, completed_at) do
    with {:ok, %ActorEvent{} = event} <-
           mark_event_completed(repo, actor_event, %{completed_at: completed_at}) do
      {:ok, event}
    end
  end

  @doc false
  @spec mark_turn_event_completed_in_tx(
          module(),
          ActorEvent.t(),
          DateTime.t(),
          String.t() | nil,
          String.t()
        ) :: actor_commit_result()
  def mark_turn_event_completed_in_tx(
        repo,
        %ActorEvent{} = actor_event,
        completed_at,
        final_response_id,
        turn_outcome
      ) do
    with {:ok, %ActorEvent{} = event} <-
           mark_event_completed(repo, actor_event, %{
             completed_at: completed_at,
             final_response_id: final_response_id,
             turn_outcome: turn_outcome
           }) do
      {:ok, event}
    end
  end

  @doc """
  Moves an actor event into the terminal dead-letter bucket.

  Dead-letter is reserved for real poison inputs after worker execution has
  repeatedly failed. Normal completion still uses `completed_at`. The event
  keeps a bounded, redacted copy of `reason`, so the row itself says why it
  was dead-lettered.
  """
  @spec mark_event_dead_letter_in_tx(module(), ActorEvent.t(), DateTime.t(), term()) ::
          actor_commit_result()
  def mark_event_dead_letter_in_tx(
        _repo,
        %ActorEvent{completed_at: %DateTime{}} = actor_event,
        _dead_letter_at,
        _reason
      ),
      do: {:ok, actor_event}

  def mark_event_dead_letter_in_tx(repo, %ActorEvent{} = actor_event, dead_letter_at, reason) do
    with {:ok, %ActorEvent{} = event} <-
           actor_event
           |> ActorEvent.changeset(%{
             input_state: "dead_letter",
             dead_letter_at: dead_letter_at,
             dead_letter_reason: dead_letter_reason(reason)
           })
           |> repo.update() do
      {:ok, event}
    end
  end

  defp dead_letter_reason(reason) when is_map(reason), do: Sanitizer.transport(reason)
  defp dead_letter_reason(reason), do: %{"reason" => Sanitizer.transport(reason)}

  defp mark_event_completed(repo, %ActorEvent{} = actor_event, attrs) when is_map(attrs) do
    actor_event
    |> ActorEvent.changeset(attrs)
    |> repo.update()
  end

  defp completion_attrs(opts) do
    %{completed_at: Keyword.fetch!(opts, :completed_at)}
    |> maybe_put_completion_anchor(:final_response_id, Keyword.get(opts, :final_response_id))
    |> maybe_put_completion_anchor(:turn_outcome, Keyword.get(opts, :turn_outcome))
  end

  defp maybe_put_completion_anchor(attrs, _key, nil), do: attrs
  defp maybe_put_completion_anchor(attrs, key, value), do: Map.put(attrs, key, value)

  @doc """
  Returns completed actor events for a provider entry inside a caller-owned transaction.
  """
  @spec actor_events_for_entry_in_tx(
          module(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: [ActorEvent.t()]
  def actor_events_for_entry_in_tx(
        repo,
        agent_uid,
        binding_name,
        signal_channel_id,
        source_entry_id
      )
      when is_binary(source_entry_id) and source_entry_id != "" do
    ActorEvent
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.binding_name == ^binding_name)
    |> where([input], input.signal_channel_id == ^signal_channel_id)
    |> where([input], not is_nil(input.completed_at))
    |> where(
      [input],
      input.source_entry_id == ^source_entry_id or
        fragment(
          """
          jsonb_typeof(?->'data'->'entries') = 'array'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(?->'data'->'entries') AS entry
            WHERE entry->>'source_entry_id' = ?
          )
          """,
          input.payload,
          input.payload,
          ^source_entry_id
        )
    )
    |> order_by([input], asc: input.available_at)
    |> repo.all()
  end

  def actor_events_for_entry_in_tx(
        _repo,
        _agent_uid,
        _binding_name,
        _signal_channel_id,
        _source_entry_id
      ),
      do: []

  def next_ready_event(uid, session, now \\ DateTime.utc_now(:microsecond), opts \\ []) do
    query =
      from(e in ActorEvent,
        where:
          e.agent_uid == ^uid and e.session_id == ^session and e.input_state == "open" and
            is_nil(e.completed_at),
        order_by: [asc: e.queue_sequence],
        limit: 1
      )

    query =
      if Keyword.get(opts, :strict_queue_order?, false),
        do: query,
        else: where(query, [e], e.available_at <= ^now)

    case Repo.one(query) do
      %ActorEvent{} = event -> if DateTime.compare(event.available_at, now) != :gt, do: event
      nil -> nil
    end
  end

  @doc false
  def reply_preview_cleanup_at(%ActorEvent{reply_preview_checkpoint: checkpoint})
      when is_map(checkpoint),
      do: parse_datetime(checkpoint["cleanup_at"])

  def reply_preview_cleanup_at(%ActorEvent{}), do: nil

  defp notify_preview_in_tx(repo, event) do
    with :ok <-
           Ankole.SignalsGateway.Jobs.ReplyPreviewCheckpoint.schedule_in_tx(
             repo,
             %{actor_event_id: event.id},
             DateTime.utc_now(:microsecond)
           ) do
      if cleanup_at = reply_preview_cleanup_at(event),
        do:
          Ankole.SignalsGateway.Jobs.ReplyPreviewCleanup.schedule_in_tx(
            repo,
            %{actor_event_id: event.id},
            cleanup_at
          ),
        else: :ok
    end
  end

  defp checkpoint_sequence(checkpoint) do
    case Map.get(checkpoint, "sequence_high_water") do
      value when is_integer(value) and value >= 0 -> value
      _value -> 0
    end
  end

  # Accepts an explicit queue sequence for fixtures and replay tools.
  # Normal ingress assigns the next value in the durable session event stream.
  defp put_queue_sequence(_repo, %{queue_sequence: queue_sequence} = attrs)
       when is_integer(queue_sequence),
       do: attrs

  # The caller already owns the actor-session advisory lock. Completion is
  # recorded separately; queue_sequence remains the durable ordering fact for
  # the session's event stream.
  defp put_queue_sequence(repo, attrs) do
    agent_uid = Map.fetch!(attrs, :agent_uid)
    session_id = Map.fetch!(attrs, :session_id)

    next =
      ActorEvent
      |> where([input], input.agent_uid == ^agent_uid)
      |> where([input], input.session_id == ^session_id)
      |> select([input], coalesce(max(input.queue_sequence), 0) + 1)
      |> repo.one()

    Map.put(attrs, :queue_sequence, next)
  end

  # The primary key is generated before insert, so an `on_conflict: :nothing`
  # placeholder can still have an id. Always re-read the unique key; callers need
  # the durable row, not a client-side insert attempt.
  defp inserted_or_existing({:ok, %ActorEvent{}}, repo, attrs), do: fetch_actor_event(repo, attrs)
  defp inserted_or_existing({:error, _changeset} = error, _repo, _attrs), do: error

  defp fetch_actor_event(repo, attrs) do
    case idempotency_key(attrs) do
      %{agent_uid: agent_uid, binding_name: binding_name, source_event_id: source_event_id} ->
        case repo.get_by(ActorEvent,
               agent_uid: agent_uid,
               binding_name: binding_name,
               source_event_id: source_event_id
             ) do
          %ActorEvent{} = event -> {:ok, event}
          nil -> {:error, :actor_event_not_found}
        end

      nil ->
        {:error, :actor_event_not_found}
    end
  end

  defp idempotency_key(attrs) do
    with agent_uid when is_binary(agent_uid) <- text_attr(attrs, :agent_uid),
         binding_name when is_binary(binding_name) <- text_attr(attrs, :binding_name),
         source_event_id when is_binary(source_event_id) <- text_attr(attrs, :source_event_id) do
      %{
        agent_uid: String.downcase(agent_uid),
        binding_name: binding_name,
        source_event_id: source_event_id
      }
    else
      _value -> nil
    end
  end

  defp text_attr(attrs, key) when is_map(attrs) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  # Events without provider entry identity cannot be matched to a deletion
  # tombstone, so they remain completable.
  defp reject_tombstoned_event_source(
         _repo,
         %ActorEvent{signal_channel_id: nil},
         _now
       ),
       do: :ok

  # Rejects completion if the source provider entry was tombstoned after the
  # actor event was queued. This keeps local generation from replying to content
  # that has already been withdrawn.
  defp reject_tombstoned_event_source(repo, %ActorEvent{} = event, now) do
    source_entry_ids = ActorEvent.source_entry_ids(event)

    case source_entry_ids do
      [] ->
        :ok

      [_entry_id | _rest] ->
        InputTombstone
        |> where([tombstone], tombstone.agent_uid == ^event.agent_uid)
        |> where([tombstone], tombstone.binding_name == ^event.binding_name)
        |> where([tombstone], tombstone.signal_channel_id == ^event.signal_channel_id)
        |> where([tombstone], tombstone.source_entry_id in ^source_entry_ids)
        |> where([tombstone], tombstone.tombstoned_until > ^now)
        |> select([tombstone], tombstone.source_entry_id)
        |> repo.all()
        |> case do
          [] ->
            :ok

          withdrawn ->
            inputs = MapSet.new(ActorEvent.input_source_entry_ids(event))

            if Enum.any?(withdrawn, &MapSet.member?(inputs, &1)),
              do: {:error, :actor_event_canceled},
              else: {:error, :actor_event_context_canceled}
        end
    end
  end

  defp insert_outbox_intents(_repo, _actor_event, []), do: {:ok, []}

  # Writes provider outbox intents in the same transaction as event completion.
  # That makes "message committed" and "reply scheduled" one durable decision.
  defp insert_outbox_intents(repo, actor_event, outbox_intents) when is_list(outbox_intents) do
    outbox_intents
    |> Enum.map(&insert_outbox_intent(repo, actor_event, &1))
    |> Ankole.Attrs.collect_results()
  end

  defp insert_outbox_intents(_repo, _actor_event, _outbox_intents),
    do: {:error, :invalid_outbox_intents}

  defp insert_outbox_intent(repo, actor_event, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:agent_uid, actor_event.agent_uid)
      |> Map.put_new(:binding_name, actor_event.binding_name)
      |> Map.put_new(:signal_channel_id, actor_event.signal_channel_id)
      |> Map.put_new(:provider_thread_id, actor_event.provider_thread_id)
      |> Map.put_new(:reply_to_source_entry_id, actor_event.source_entry_id)
      # Source table: source_actor_event_id stores the actor_events.id whose
      # completion is committing these provider outbox intents.
      |> Map.put_new(:source_actor_event_id, actor_event.id)

    Outbox.commit_outbox_in_tx(repo, attrs)
  end

  defp insert_outbox_intent(_repo, _actor_event, _attrs), do: {:error, :invalid_outbox_intent}

  def stop_human_work_in_tx(repo, uid, version, now) do
    repo.update_all(
      from(e in ActorEvent,
        where:
          e.human_uid == ^uid and e.human_access_version < ^version and e.input_state == "open" and
            is_nil(e.completed_at) and is_nil(e.last_attempt_at)
      ),
      set: [
        input_state: "dead_letter",
        dead_letter_at: now,
        updated_at: now,
        dead_letter_reason: %{"reason" => "human_access_revoked"}
      ]
    )
  end
end
