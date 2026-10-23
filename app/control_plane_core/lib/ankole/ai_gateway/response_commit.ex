defmodule Ankole.AIGateway.ResponseCommit do
  @moduledoc "Response liveness and terminal commits; PostgreSQL owns the final status."
  require Ash.Query
  import Ankole.AIGateway.ResponseChain, only: [decode_response_id: 1]
  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.{Principals, Repo}
  @orphaned_generating_grace_seconds 300

  @doc """
  Returns the grace window before a generating response is treated as orphaned.
  """
  @spec orphaned_generating_grace_seconds() :: pos_integer()
  def orphaned_generating_grace_seconds, do: @orphaned_generating_grace_seconds

  @doc """
  Returns the cutoff for orphaned generating response rows.
  """
  @spec orphaned_generating_cutoff(DateTime.t()) :: DateTime.t()
  def orphaned_generating_cutoff(now),
    do: DateTime.add(now, -orphaned_generating_grace_seconds(), :second)

  @doc """
  Returns whether a generating row has exceeded the orphan grace window.
  """
  @spec generating_message_stale?(Message.t(), DateTime.t()) :: boolean()
  def generating_message_stale?(%Message{updated_at: updated_at}, now)
      when not is_nil(updated_at) do
    cutoff = orphaned_generating_cutoff(now)
    DateTime.compare(updated_at, cutoff) in [:lt, :eq]
  end

  def generating_message_stale?(_message, _now), do: false

  @doc "Locks one generating response row inside the caller's transaction."
  @spec lock_generating_message(binary()) :: Message.t() | nil
  def lock_generating_message(message_id) do
    Message
    |> Ash.Query.filter(id == ^message_id and type == :message and status == :generating)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  @doc """
  Refreshes a generating response lease and schedules its next orphan deadline.
  """
  @spec touch_generating_response(String.t(), binary(), map() | nil) ::
          {:ok, Message.t() | :already_terminal} | {:error, :not_found | term()}
  def touch_generating_response(subject_uid, response_id, upstream_progress \\ nil) do
    metadata =
      if is_map(upstream_progress), do: %{"upstream_progress" => upstream_progress}, else: %{}

    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, message_id} <- decode_response_id(response_id) do
      Ankole.Ash.run_action(Message, :renew_lease, %{
        subject_uid: subject_uid,
        message_id: message_id,
        metadata: metadata,
        now: DateTime.utc_now(:microsecond)
      })
    else
      _invalid -> {:error, :not_found}
    end
  end

  @doc false
  # Runs the `:renew_lease` action: the heartbeat and the next orphan deadline
  # commit together.
  def renew_lease(%{subject_uid: subject_uid, message_id: message_id} = arguments) do
    query = Ash.Query.filter(Message, id == ^message_id and subject_uid == ^subject_uid)

    query
    |> Ankole.Ash.update_atomic(:heartbeat, Map.take(arguments, [:now, :metadata]))
    |> Ankole.Errors.reason()
    |> case do
      {:ok, message} ->
        with :ok <- notify_ai_message_deadline(message), do: {:ok, message}

      {:error, :stale} ->
        if Ankole.Ash.read_one!(query), do: {:ok, :already_terminal}, else: {:error, :not_found}

      {:error, _error} = error ->
        error
    end
  end

  @doc """
  Merges `metadata.upstream_progress` into a generating Response. It does not
  renew the lease or schedule an orphan deadline.
  """
  @spec record_upstream_progress(String.t(), binary(), map()) :: :ok | {:error, :not_found}
  def record_upstream_progress(subject_uid, response_id, progress) when is_map(progress) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, message_id} <- decode_response_id(response_id) do
      Message
      |> Ash.Query.filter(id == ^message_id and subject_uid == ^subject_uid)
      |> Ankole.Ash.update_atomic(
        :record_progress,
        %{metadata: %{"upstream_progress" => progress}},
        select: [:id]
      )
      |> Ankole.Errors.reason()
      |> case do
        {:ok, _message} -> :ok
        {:error, :stale} -> {:error, :not_found}
        {:error, _error} = error -> error
      end
    else
      _invalid -> {:error, :not_found}
    end
  end

  @doc """
  Marks one explicitly identified generating response as failed.
  """
  @spec fail_generating_response(String.t(), binary(), map()) ::
          {:ok, Message.t() | :already_terminal} | {:error, :not_found | term()}
  def fail_generating_response(subject_uid, response_id, error_details)
      when is_map(error_details) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, message_id} <- decode_response_id(response_id) do
      Message
      |> Ankole.Ash.run_action(:fail_generating, %{
        subject_uid: subject_uid,
        message_id: message_id,
        error_details: error_details,
        now: DateTime.utc_now(:microsecond)
      })
      |> published()
    else
      _invalid -> {:error, :not_found}
    end
  end

  @doc false
  # Runs the `:fail_generating` action.
  def fail_generating(%{error_details: error_details} = arguments) do
    with {:ok, %Message{} = message} <-
           fail_generating_response_in_tx(
             Repo,
             arguments.subject_uid,
             arguments.message_id,
             error_details,
             arguments.now
           ) do
      {:ok, {:publish, message, :response_failed, %{error: error_details}}}
    end
  end

  @doc """
  Transactional variant of `fail_generating_response/3` for callers that own a
  wider transaction. It has no domain-specific side effects.
  """
  @spec fail_generating_response_in_tx(module(), String.t(), binary(), map(), DateTime.t()) ::
          {:ok, Message.t() | :already_terminal} | {:error, :not_found | term()}
  def fail_generating_response_in_tx(_repo, subject_uid, response_id, error_details, now)
      when is_map(error_details) do
    transition_generating_response(
      subject_uid,
      response_id,
      now,
      :fail,
      {"error", error_details}
    )
  end

  @doc """
  Marks one explicitly identified generating response as retracted.

  This transition preserves the partial response as an audit fact while
  excluding it from future history after its input was superseded.
  """
  @spec retract_generating_response_in_tx(
          module(),
          String.t(),
          binary(),
          String.t(),
          DateTime.t()
        ) :: {:ok, Message.t() | :already_terminal} | {:error, :not_found | term()}
  def retract_generating_response_in_tx(_repo, subject_uid, response_id, reason, now)
      when is_binary(reason) do
    transition_generating_response(
      subject_uid,
      response_id,
      now,
      :retract,
      {"retraction", %{"reason" => reason, "retracted_at" => DateTime.to_iso8601(now)}}
    )
  end

  defp transition_generating_response(subject_uid, response_id, now, action, {key, value}) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, message_id} <- decode_response_id(response_id) do
      case lock_response_for_subject(subject_uid, message_id) do
        %Message{status: :generating} = message ->
          Ankole.Ash.update(message, action, %{now: now, metadata: %{key => value}})

        %Message{} ->
          {:ok, :already_terminal}

        nil ->
          {:error, :not_found}
      end
    else
      _invalid -> {:error, :not_found}
    end
  end

  @doc """
  Reconciles one orphan deadline using only the response row's own heartbeat.
  """
  @spec reconcile_orphaned_response(binary(), keyword()) ::
          {:ok, :failed | :live | :already_terminal} | {:error, term()}
  def reconcile_orphaned_response(response_id, opts \\ []) do
    with {:ok, message_id} <- decode_response_id(response_id) do
      Message
      |> Ankole.Ash.run_action(:reconcile_orphan, %{
        message_id: message_id,
        now: Keyword.get(opts, :now, DateTime.utc_now(:microsecond)),
        force: Keyword.get(opts, :force, false)
      })
      |> case do
        {:ok, {:publish, %Message{}, :response_failed, _payload}} -> {:ok, :failed}
        other -> other
      end
    end
  end

  @doc false
  # Runs the `:reconcile_orphan` action.
  def reconcile_orphan(%{message_id: message_id, now: now, force: force}) do
    case reconcile_orphaned_response_in_tx(Repo, message_id, now: now, force: force) do
      {:ok, {:failed, message, error}} ->
        {:ok, {:publish, message, :response_failed, %{error: error}}}

      other ->
        other
    end
  end

  @doc false
  def reconcile_orphaned_response_in_tx(repo, response_id, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, message_id} <- decode_response_id(response_id) do
      case lock_generating_message(message_id) do
        %Message{} = message ->
          if Keyword.get(opts, :force, false) or generating_message_stale?(message, now) do
            error = %{
              "code" => "orphaned_generating_response",
              "reason" => "response heartbeat expired before a terminal commit",
              "stage" => "ai_message_deadline",
              "retryable" => true
            }

            with {:ok, %Message{} = failed} <-
                   fail_generating_response_in_tx(
                     repo,
                     message.subject_uid,
                     message.id,
                     error,
                     now
                   ) do
              {:ok, {:failed, failed, error}}
            end
          else
            with :ok <- notify_ai_message_deadline(message), do: {:ok, :live}
          end

        nil ->
          {:ok, :already_terminal}
      end
    end
  end

  defp lock_response_for_subject(subject_uid, message_id) do
    Message
    |> Ash.Query.filter(id == ^message_id and subject_uid == ^subject_uid)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  @doc """
  Commits a response run as `complete` with the final durable content.

  Uses an optimistic transition guard: `WHERE status = 'generating'` ensures
  only the first terminal commit wins. If the row is already terminal (e.g.
  a concurrent cleanup path), this is a no-op that returns the existing row.
  """
  @spec commit_complete(Message.t() | binary(), [map()], map()) ::
          {:ok, Message.t()} | {:error, term()} | {:ok, :already_terminal}
  def commit_complete(message, content_items, extra_metadata \\ %{}),
    do: commit_terminal(message, :complete, content_items, extra_metadata)

  @doc "Commits partial output and failure details when the response is still generating."
  @spec commit_error(Message.t() | binary(), [map()], map(), keyword()) ::
          {:ok, Message.t() | :already_terminal} | {:error, term()}
  def commit_error(message, partial_content, error_details, opts \\ []) do
    metadata = opts |> Keyword.get(:metadata, %{}) |> Map.put("error", error_details)
    commit_terminal(message, :fail, partial_content, metadata)
  end

  defp commit_terminal(message, action, output, metadata) do
    case ensure_loaded(message) do
      nil ->
        {:error, :message_not_found}

      %Message{status: status} when status != :generating ->
        {:ok, :already_terminal}

      %Message{id: message_id} ->
        Message
        |> Ankole.Ash.run_action(:commit_terminal, %{
          message_id: message_id,
          transition: action,
          output: output,
          metadata: metadata
        })
        |> published()
    end
  end

  @doc false
  # Runs the `:commit_terminal` action: the first terminal commit wins.
  def commit_terminal_locked(%{message_id: message_id, transition: action} = arguments) do
    case lock_generating_message(message_id) do
      nil ->
        {:ok, :already_terminal}

      current ->
        with {:ok, updated} <-
               Ankole.Ash.update(current, action, Map.take(arguments, [:output, :metadata])) do
          {:ok, terminal_event(updated, action, arguments.metadata)}
        end
    end
  end

  defp terminal_event(message, :complete, _metadata),
    do: {:publish, message, complete_event_type(message), %{content: message.content}}

  defp terminal_event(message, :fail, metadata),
    do: {:publish, message, :response_failed, %{error: metadata["error"]}}

  @doc false
  # The after-commit function of the Message generic actions.
  def publish_committed({:publish, %Message{} = message, event_type, payload}),
    do: Events.publish(message, event_type, payload)

  def publish_committed(_result), do: :ok

  defp published({:ok, {:publish, %Message{} = message, _event_type, _payload}}),
    do: {:ok, message}

  defp published(result), do: result

  @doc """
  Publishes a terminal live event for a response row that was moved to a terminal
  state outside the normal WebSocket commit path.
  """
  @spec publish_terminal_event(
          Message.t(),
          :response_completed | :response_incomplete | :response_failed,
          map()
        ) :: :ok
  def publish_terminal_event(%Message{} = message, event_type, payload)
      when event_type in [:response_completed, :response_incomplete, :response_failed] do
    Events.publish(message, event_type, payload)
  end

  defp complete_event_type(%Message{metadata: %{"response" => %{"status" => "incomplete"}}}),
    do: :response_incomplete

  defp complete_event_type(%Message{metadata: %{"incomplete_details" => details}})
       when is_map(details),
       do: :response_incomplete

  defp complete_event_type(_message), do: :response_completed

  @doc false
  def notify_ai_message_deadline(%Message{} = message) do
    Ankole.AIGateway.Jobs.ReconcileOrphanedResponse.schedule_in_tx(
      Repo,
      %{message_id: message.id},
      ai_message_orphan_at(message)
    )
  end

  defp ai_message_orphan_at(%Message{} = message) do
    base_at = message.updated_at || message.inserted_at || DateTime.utc_now(:microsecond)
    DateTime.add(base_at, orphaned_generating_grace_seconds(), :second)
  end

  # Ensures the message is loaded from the DB if only an id was given.
  defp ensure_loaded(%Message{} = message), do: message

  defp ensure_loaded(id) when is_binary(id),
    do: Message |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()
end
