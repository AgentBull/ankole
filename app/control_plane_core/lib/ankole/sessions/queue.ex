defmodule Ankole.Sessions.Queue do
  @moduledoc """
  The durable Signal queue for each execution Session.

  Signals owns intake and source deduplication. This module owns queue reads,
  the Session advisory lock, and input completion. Intake uses the same lock
  for `queue_sequence` allocation as higher-level Session transitions.

  The `*_in_tx` functions run in the caller's transaction so input completion
  and provider-visible effects can commit together. AIGateway owns model facts.
  """

  import Ecto.Query, warn: false

  alias Ankole.Signals.Signal
  alias Ankole.Repo
  alias Ankole.Conversations.InputTombstone
  alias Ankole.Signals.Sanitizer

  @type session_commit_result :: {:ok, Signal.t()} | {:error, term()}

  @doc """
  Serializes writes that decide ordering or reply-interaction state for one session.

  Callers that also lock Signal rows must take this advisory lock first.
  """
  @spec lock_session_in_tx(module(), String.t(), String.t()) :: :ok
  def lock_session_in_tx(repo, agent_uid, session_id)
      when is_binary(agent_uid) and is_binary(session_id) do
    Ankole.AdvisoryLock.lock!(repo, {agent_uid, session_id})

    :ok
  end

  @doc "Locks every participating session before any workspace or Signal row."
  def lock_sessions_in_tx(repo, sessions) do
    sessions
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn {agent_uid, session_id} ->
      lock_session_in_tx(repo, agent_uid, session_id)
    end)

    :ok
  end

  @doc """
  Completes a locked Signal inside a caller-owned transaction.

  The caller owns any immutable Response reads and projection. This primitive
  owns the source tombstone check and completion
  timestamp.
  """
  @spec complete_signal_in_tx(module(), Signal.t(), keyword()) ::
          session_commit_result()
  def complete_signal_in_tx(repo, %Signal{} = signal, opts) do
    completed_at = Keyword.get(opts, :completed_at, DateTime.utc_now(:microsecond))

    with :ok <- ensure_event_source_live_in_tx(repo, signal, completed_at),
         {:ok, completed_event} <-
           persist_signal_completion_in_tx(
             repo,
             signal,
             Keyword.put(opts, :completed_at, completed_at)
           ) do
      {:ok, completed_event}
    end
  end

  @doc """
  Completes a provider-entry lifecycle event without treating its tombstone as cancelation.

  `conversation.message.removed` rows exist because the provider entry was tombstoned
  after earlier execution already completed it. Re-applying the source-entry
  tombstone guard here would cancel the lifecycle notice itself.
  """
  @spec complete_entry_lifecycle_event_in_tx(module(), Signal.t(), keyword()) ::
          session_commit_result()
  def complete_entry_lifecycle_event_in_tx(
        repo,
        %Signal{type: "conversation.message.removed"} = signal,
        opts
      ) do
    persist_signal_completion_in_tx(repo, signal, opts)
  end

  @doc """
  Verifies that an Signal's provider source has not been tombstoned.

  Explicit Agent Turn completion uses this before committing provider-visible
  output. Individual Response terminals intentionally leave the Signal
  open and never pass through `complete_signal_in_tx/3`.
  """
  @spec ensure_event_source_live_in_tx(module(), Signal.t(), DateTime.t()) ::
          :ok | {:error, :signal_canceled | :signal_context_canceled}
  def ensure_event_source_live_in_tx(repo, %Signal{} = signal, %DateTime{} = now) do
    with :ok <- reject_tombstoned_event_source(repo, signal, now),
         do: reject_withdrawn_background(repo, signal)
  end

  @doc """
  Completes a durable command event without requiring a worker turn fence.

  Command feedback is a provider-visible control response, not transcript or
  model output, so it deliberately has no AI message id.
  """
  @spec complete_command_event_in_tx(module(), Signal.t(), keyword()) ::
          session_commit_result()
  def complete_command_event_in_tx(
        repo,
        %Signal{type: "command." <> _name} = signal,
        opts
      ) do
    complete_signal_in_tx(repo, signal, opts)
  end

  @doc """
  Completes a session-lifecycle event without requiring a worker turn fence.
  """
  @spec complete_session_lifecycle_event_in_tx(module(), Signal.t(), keyword()) ::
          session_commit_result()
  def complete_session_lifecycle_event_in_tx(
        repo,
        %Signal{type: "session." <> _name} = signal,
        opts
      ) do
    complete_signal_in_tx(repo, signal, opts)
  end

  defp persist_signal_completion_in_tx(repo, %Signal{} = signal, opts) do
    with {:ok, %Signal{} = updated} <-
           mark_event_completed(repo, signal, completion_attrs(opts)) do
      {:ok, updated}
    end
  end

  def mark_event_completed_in_tx(repo, %Signal{} = signal, completed_at) do
    with {:ok, %Signal{} = event} <-
           mark_event_completed(repo, signal, %{completed_at: completed_at}) do
      {:ok, event}
    end
  end

  @doc false
  @spec mark_turn_event_completed_in_tx(
          module(),
          Signal.t(),
          DateTime.t(),
          String.t() | nil,
          String.t()
        ) :: session_commit_result()
  def mark_turn_event_completed_in_tx(
        repo,
        %Signal{} = signal,
        completed_at,
        final_response_id,
        turn_outcome
      ) do
    with {:ok, %Signal{} = event} <-
           mark_event_completed(repo, signal, %{
             completed_at: completed_at,
             final_response_id: final_response_id,
             turn_outcome: turn_outcome
           }) do
      {:ok, event}
    end
  end

  @doc """
  Moves an Signal into the terminal dead-letter bucket.

  Dead-letter is reserved for real poison inputs after worker execution has
  repeatedly failed. Normal completion transitions to `completed`. The event
  keeps a bounded, redacted copy of `reason`, so the row itself says why it
  was dead-lettered.
  """
  @spec mark_event_dead_letter_in_tx(module(), Signal.t(), DateTime.t(), term()) ::
          session_commit_result()
  def mark_event_dead_letter_in_tx(
        _repo,
        %Signal{status: :completed} = signal,
        _dead_letter_at,
        _reason
      ),
      do: {:ok, signal}

  def mark_event_dead_letter_in_tx(_repo, %Signal{} = signal, dead_letter_at, reason) do
    Ankole.Ash.update(signal, :dead_letter, %{
      dead_letter_at: dead_letter_at,
      dead_letter_reason: dead_letter_reason(reason)
    })
  end

  defp dead_letter_reason(reason) when is_map(reason), do: Sanitizer.transport(reason)
  defp dead_letter_reason(reason), do: %{"reason" => Sanitizer.transport(reason)}

  defp mark_event_completed(_repo, %Signal{status: :dead_letter}, _attrs),
    do: {:error, :signal_already_dead_lettered}

  defp mark_event_completed(_repo, %Signal{} = signal, attrs) when is_map(attrs),
    do: Ankole.Ash.update(signal, :complete, attrs)

  defp completion_attrs(opts) do
    %{completed_at: Keyword.fetch!(opts, :completed_at)}
    |> maybe_put_completion_anchor(:final_response_id, Keyword.get(opts, :final_response_id))
    |> maybe_put_completion_anchor(:turn_outcome, Keyword.get(opts, :turn_outcome))
  end

  defp maybe_put_completion_anchor(attrs, _key, nil), do: attrs
  defp maybe_put_completion_anchor(attrs, key, value), do: Map.put(attrs, key, value)

  @doc "All open inputs due now, in queue order."
  def due(key, now \\ DateTime.utc_now(:microsecond)) do
    open_query(key.agent_uid, key.session_id)
    |> where([e], e.available_at <= ^now)
    |> Repo.all()
  end

  @doc "The oldest open input, including future or unstarted work."
  def oldest_open(repo, uid, session),
    do: open_query(uid, session) |> limit(1) |> repo.one()

  @doc "The oldest admitted open input, including a deferred retry."
  def oldest_started(repo, uid, session) do
    open_query(uid, session)
    |> where([e], not is_nil(e.last_attempt_at))
    |> limit(1)
    |> repo.one()
  end

  @doc "Returns runnable or admitted work for the public Session status."
  def status_event(repo, uid, session, now) do
    open_query(uid, session)
    |> exclude(:order_by)
    |> order_by([event],
      asc:
        fragment(
          "CASE WHEN ? > ? THEN 2 WHEN ? IS NULL THEN 1 ELSE 0 END",
          event.available_at,
          ^now,
          event.last_attempt_at
        ),
      asc: event.available_at,
      asc: event.queue_sequence
    )
    |> limit(1)
    |> repo.one()
  end

  defp open_query(uid, session) do
    from(e in Signal,
      left_join: conversation in Ankole.Conversations.Conversation,
      on: conversation.id == e.conversation_id and conversation.kind == :native,
      where:
        e.agent_uid == ^uid and e.session_id == ^session and
          e.status in [:queued, :running],
      where:
        not is_nil(e.last_attempt_at) or e.type != "conversation.message.addressed" or
          fragment("COALESCE(?->>'delivery_mode', 'steer')", e.data) != "queue" or
          is_nil(conversation.id) or
          fragment("COALESCE(?->>'queue_paused', 'false')", conversation.metadata) != "true",
      order_by: [asc: e.queue_sequence]
    )
  end

  def next_ready_event(uid, session, now \\ DateTime.utc_now(:microsecond)) do
    open_query(uid, session)
    |> where([e], e.available_at <= ^now)
    |> limit(1)
    |> Repo.one()
  end

  # Accepts an explicit queue sequence for fixtures and replay tools.
  # Events without provider entry identity cannot be matched to a deletion
  # tombstone, so they remain completable.
  defp reject_tombstoned_event_source(
         _repo,
         %Signal{conversation_id: nil},
         _now
       ),
       do: :ok

  # Rejects completion if the source provider entry was tombstoned after the
  # Signal was queued. This keeps local generation from replying to content
  # that has already been withdrawn.
  defp reject_tombstoned_event_source(_repo, %Signal{reply_binding_name: nil}, _now), do: :ok

  defp reject_tombstoned_event_source(repo, %Signal{} = event, now) do
    provider_message_ids = Signal.input_provider_message_ids(event)

    case provider_message_ids do
      [] ->
        :ok

      [_entry_id | _rest] ->
        InputTombstone
        |> where([tombstone], tombstone.conversation_id == ^event.conversation_id)
        |> where([tombstone], tombstone.provider_message_id in ^provider_message_ids)
        |> where([tombstone], tombstone.tombstoned_until > ^now)
        |> select([tombstone], tombstone.provider_message_id)
        |> repo.all()
        |> case do
          [] ->
            :ok

          [_withdrawn | _rest] ->
            {:error, :signal_canceled}
        end
    end
  end

  defp reject_withdrawn_background(_repo, %Signal{conversation_id: nil}), do: :ok

  defp reject_withdrawn_background(repo, signal) do
    declared = if is_map(signal.data), do: List.wrap(signal.data["message_ids"]), else: []
    explicit_ids = [signal.message_id | declared]
    background = Ankole.Sessions.ModelHistory.read_message_ids_in_tx(repo, signal) -- explicit_ids

    existing =
      repo.all(
        from(m in Ankole.Conversations.Message,
          where: m.conversation_id == ^signal.conversation_id and m.id in ^background,
          select: m.id
        )
      )

    if background -- existing == [], do: :ok, else: {:error, :signal_context_canceled}
  end

  def stop_human_work_in_tx(_repo, uid, version, now) do
    require Ash.Query

    result =
      Signal
      |> Ash.Query.filter(
        human_uid == ^uid and human_access_version < ^version and status == :queued and
          is_nil(last_attempt_at)
      )
      |> Ankole.Ash.bulk_update(
        :revoke_unstarted,
        %{
          dead_letter_at: now,
          dead_letter_reason: %{"reason" => "human_access_revoked"}
        },
        strategy: [:atomic],
        return_records?: true,
        return_errors?: true
      )

    case result do
      %Ash.BulkResult{status: :success, records: records} -> {length(records), nil}
      %Ash.BulkResult{errors: errors} -> Ankole.Repo.rollback(errors)
    end
  end
end
