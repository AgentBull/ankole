defmodule Ankole.SignalsGateway.Actors do
  @moduledoc """
  The actor event journal: durable inbox shared by SignalsGateway and ActorRuntime.

  SignalsGateway appends normalized events for an actor session. ActorRuntime
  leases and delivers one executable event at a time; durable response facts live
  in AIGateway-owned tables.

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
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway.ActorEventTypes
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.ReplyInteractionState

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

    attrs = put_queue_sequence(repo, attrs)

    with {:ok, %ActorEvent{} = event} <-
           %ActorEvent{}
           |> ActorEvent.changeset(attrs)
           |> repo.insert(
             on_conflict: :nothing,
             conflict_target: [:agent_uid, :binding_name, :source_event_id],
             returning: true
           )
           |> inserted_or_existing(repo, attrs),
         :ok <-
           RuntimeEvents.notify_actor_session_ready(
             repo,
             event.agent_uid,
             event.session_id,
             event.available_at
           ) do
      {:ok, event}
    end
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
             %ActorEvent{reply_preview_source_entry_id: nil} = event ->
               event
               |> ActorEvent.changeset(preview_source_attrs(source_entry_id, provider_thread_id))
               |> repo.update()
               |> case do
                 {:ok, _event} -> {:ok, :recorded}
                 {:error, _changeset} = error -> error
               end

             %ActorEvent{reply_preview_source_entry_id: ^source_entry_id} = event ->
               record_preview_thread(repo, event, provider_thread_id)

             %ActorEvent{} ->
               {:error, :reply_preview_source_entry_already_recorded}

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
  @spec put_reply_preview_checkpoint(Ecto.UUID.t(), map()) ::
          {:ok, ActorEvent.t()} | {:error, term()}
  def put_reply_preview_checkpoint(actor_event_id, checkpoint)
      when is_binary(actor_event_id) and is_map(checkpoint) do
    Repo.transact(fn repo ->
      case lock_actor_event_in_tx(repo, actor_event_id) do
        %ActorEvent{} = event ->
          put_reply_preview_checkpoint_in_tx(repo, event, checkpoint)

        nil ->
          {:error, :actor_event_not_found}
      end
    end)
  end

  def put_reply_preview_checkpoint(_actor_event_id, _checkpoint),
    do: {:error, :invalid_reply_preview_checkpoint}

  @doc false
  @spec put_reply_preview_checkpoint_in_tx(module(), ActorEvent.t(), map()) ::
          {:ok, ActorEvent.t()} | {:error, term()}
  def put_reply_preview_checkpoint_in_tx(repo, %ActorEvent{} = event, checkpoint)
      when is_map(checkpoint) do
    existing = event.reply_preview_checkpoint || %{}
    checkpoint = preserve_reply_preview_owner_fence(existing, checkpoint)

    with :ok <- validate_reply_preview_owner_fence(event.id, existing, checkpoint) do
      checkpoint =
        existing
        |> ReplyInteractionState.merge_checkpoint(checkpoint)
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

      cleanup_at = parse_datetime(Map.get(checkpoint, "cleanup_at"))

      with {:ok, updated} <-
             event
             |> ActorEvent.changeset(%{
               reply_preview_checkpoint: checkpoint,
               reply_preview_cleanup_at: cleanup_at
             })
             |> repo.update(),
           :ok <- RuntimeEvents.notify_reply_preview_checkpoint(repo, updated) do
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
          checkpoint = event.reply_preview_checkpoint || %{}

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

      with {:ok, updated} <-
             event
             |> ActorEvent.changeset(%{
               reply_preview_checkpoint: checkpoint,
               reply_preview_sequence_high_water: sequence
             })
             |> repo.update(),
           :ok <- RuntimeEvents.notify_reply_preview_checkpoint(repo, updated) do
        {:ok, mutation}
      end
    end
  end

  @doc false
  @spec recoverable_reply_preview_events() :: [ActorEvent.t()]
  def recoverable_reply_preview_events do
    ActorEvent
    |> where([event], not is_nil(event.reply_preview_checkpoint))
    |> where(
      [event],
      fragment(
        "COALESCE(?->'recovery_state'->>'state', '') <> 'blocked'",
        event.reply_preview_checkpoint
      )
    )
    |> where(
      [event],
      fragment(
        "COALESCE((?->>'presentation_owner')::boolean, true) OR COALESCE((?->>'refresh_pending')::boolean, false)",
        event.reply_preview_checkpoint,
        event.reply_preview_checkpoint
      )
    )
    |> where(
      [event],
      (((event.input_state == "open" and is_nil(event.completed_at)) or
          not is_nil(event.completed_at)) and
         fragment(
           "COALESCE(?->>'streaming_state', 'open') NOT IN ('closed', 'replaced')",
           event.reply_preview_checkpoint
         )) or
        fragment(
          "COALESCE((?->>'refresh_pending')::boolean, false)",
          event.reply_preview_checkpoint
        )
    )
    |> order_by([event], asc: event.inserted_at)
    |> Repo.all()
  end

  @doc """
  Requeues reply previews that a not-retryable provider error blocked.

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

  @doc false
  @spec reply_preview_runtime_event(ActorEvent.t()) :: {String.t(), map()}
  def reply_preview_runtime_event(%ActorEvent{} = event) do
    {RuntimeEvents.reply_preview_checkpoint_channel(), %{"actor_event_id" => event.id}}
  end

  @doc false
  @spec reply_preview_cleanup_runtime_event(ActorEvent.t()) :: {String.t(), map()}
  def reply_preview_cleanup_runtime_event(%ActorEvent{} = event) do
    {RuntimeEvents.reply_preview_cleanup_channel(),
     %{
       "actor_event_id" => event.id,
       "due_at" => RuntimeEvents.encode_datetime(event.reply_preview_cleanup_at)
     }}
  end

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
           ),
         :ok <-
           RuntimeEvents.notify_actor_session_ready(
             repo,
             completed_event.agent_uid,
             completed_event.session_id,
             completed_at
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
          :ok | {:error, :actor_event_canceled}
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
           mark_event_completed(repo, actor_event, %{completed_at: completed_at}),
         :ok <-
           RuntimeEvents.notify_actor_session_ready(
             repo,
             event.agent_uid,
             event.session_id,
             completed_at
           ) do
      {:ok, event}
    end
  end

  @doc false
  @spec mark_turn_event_completed_in_tx(
          module(),
          ActorEvent.t(),
          DateTime.t(),
          String.t(),
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
           }),
         :ok <-
           RuntimeEvents.notify_actor_session_ready(
             repo,
             event.agent_uid,
             event.session_id,
             completed_at
           ) do
      {:ok, event}
    end
  end

  @doc """
  Moves an actor event into the terminal dead-letter bucket.

  Dead-letter is reserved for real poison inputs after worker execution has
  repeatedly failed. Normal completion still uses `completed_at`.
  """
  @spec mark_event_dead_letter_in_tx(module(), ActorEvent.t(), DateTime.t()) ::
          actor_commit_result()
  def mark_event_dead_letter_in_tx(
        _repo,
        %ActorEvent{completed_at: %DateTime{}} = actor_event,
        _dead_letter_at
      ),
      do: {:ok, actor_event}

  def mark_event_dead_letter_in_tx(repo, %ActorEvent{} = actor_event, dead_letter_at) do
    with {:ok, %ActorEvent{} = event} <-
           actor_event
           |> ActorEvent.changeset(%{
             input_state: "dead_letter",
             dead_letter_at: dead_letter_at
           })
           |> repo.update(),
         :ok <-
           RuntimeEvents.notify_actor_session_ready(
             repo,
             event.agent_uid,
             event.session_id,
             dead_letter_at
           ) do
      {:ok, event}
    end
  end

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
  Returns actor events for a provider entry.
  """
  @spec actor_events_for_entry(String.t(), String.t(), String.t(), String.t()) :: [
          ActorEvent.t()
        ]
  def actor_events_for_entry(agent_uid, binding_name, signal_channel_id, source_entry_id) do
    actor_events_for_entry_in_tx(
      Repo,
      agent_uid,
      binding_name,
      signal_channel_id,
      source_entry_id
    )
  end

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

  @doc """
  Reads the next executable actor event for one actor session.
  """
  @spec next_ready_event(String.t(), String.t(), DateTime.t(), keyword()) :: ActorEvent.t() | nil
  def next_ready_event(agent_uid, session_id, now \\ DateTime.utc_now(:microsecond), opts \\ []) do
    candidate_limit = Keyword.get(opts, :candidate_limit, 100)
    live_delivery? = Keyword.get(opts, :live_delivery?, false)

    if live_delivery? do
      next_live_turn_command_event(agent_uid, session_id, now) ||
        next_ready_queue_barrier(agent_uid, session_id, now)
    else
      agent_uid
      |> ready_event_candidates(session_id, now)
      |> limit(^candidate_limit)
      |> Repo.all()
      |> select_next_ready_event(false)
    end
  end

  defp ready_event_candidates(agent_uid, session_id, now) do
    delivery_states = ["created", "sent", "accepted"]

    ActorEvent
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.session_id == ^session_id)
    |> where([input], input.input_state == "open")
    |> where([input], is_nil(input.completed_at))
    |> where([input], input.available_at <= ^now)
    |> join(:left, [input], delivery in "actor_event_deliveries",
      on: delivery.actor_event_id == input.id and delivery.state in ^delivery_states
    )
    |> where([_input, delivery], is_nil(delivery.id))
    |> order_by([input], asc: input.queue_sequence)
  end

  defp select_next_ready_event([], _live_delivery?), do: nil

  defp select_next_ready_event([first_event | _rest], false), do: first_event

  defp hard_queue_barrier?(%ActorEvent{type: "session.reset_due"}), do: true
  defp hard_queue_barrier?(_event), do: false

  defp next_live_turn_command_event(agent_uid, session_id, now) do
    command_types = ActorEventTypes.live_turn_command_types()

    agent_uid
    |> ready_event_candidates(session_id, now)
    |> where([input, _delivery], input.type in ^command_types)
    |> exclude(:order_by)
    |> order_by([input, _delivery],
      asc:
        fragment(
          "CASE ? WHEN 'command.stop' THEN 0 WHEN 'command.retry' THEN 1 WHEN 'command.new' THEN 2 WHEN 'command.steer' THEN 3 WHEN 'command.compress' THEN 4 ELSE 5 END",
          input.type
        ),
      asc: input.queue_sequence
    )
    |> limit(1)
    |> Repo.one()
  end

  defp next_ready_queue_barrier(agent_uid, session_id, now) do
    agent_uid
    |> ready_event_candidates(session_id, now)
    |> limit(1)
    |> Repo.one()
    |> case do
      %ActorEvent{} = event ->
        if hard_queue_barrier?(event), do: event

      nil ->
        nil
    end
  end

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    actor_session_runtime_events() ++
      Enum.map(recoverable_reply_preview_events(), &reply_preview_runtime_event/1) ++
      reply_preview_cleanup_runtime_events()
  end

  defp reply_preview_cleanup_runtime_events do
    ActorEvent
    |> where([event], not is_nil(event.reply_preview_cleanup_at))
    |> order_by([event], asc: event.reply_preview_cleanup_at)
    |> Repo.all()
    |> Enum.map(&reply_preview_cleanup_runtime_event/1)
  end

  defp actor_session_runtime_events do
    ActorEvent
    |> where([input], input.input_state == "open")
    |> where([input], is_nil(input.completed_at))
    |> group_by([input], [input.agent_uid, input.session_id])
    |> select([input], %{
      agent_uid: input.agent_uid,
      session_id: input.session_id,
      due_at: min(input.available_at)
    })
    |> Repo.all()
    |> Enum.map(fn %{agent_uid: agent_uid, session_id: session_id, due_at: due_at} ->
      {RuntimeEvents.actor_session_ready_channel(),
       %{
         "agent_uid" => agent_uid,
         "session_id" => session_id,
         "due_at" => RuntimeEvents.encode_datetime(due_at)
       }}
    end)
  end

  defp checkpoint_sequence(checkpoint) do
    case Map.get(checkpoint, "sequence_high_water") || Map.get(checkpoint, :sequence_high_water) do
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
        |> repo.exists?()
        |> case do
          true -> {:error, :actor_event_canceled}
          false -> :ok
        end
    end
  end

  defp insert_outbox_intents(_repo, _actor_event, []), do: {:ok, []}

  # Writes provider outbox intents in the same transaction as event completion.
  # That makes "message committed" and "reply scheduled" one durable decision.
  defp insert_outbox_intents(repo, actor_event, outbox_intents) when is_list(outbox_intents) do
    outbox_intents
    |> Enum.map(&insert_outbox_intent(repo, actor_event, &1))
    |> collect_results()
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

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
