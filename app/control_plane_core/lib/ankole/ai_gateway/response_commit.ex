defmodule Ankole.AIGateway.ResponseCommit do
  @moduledoc "Response liveness and terminal commits; PostgreSQL owns the final status."
  import Ecto.Query
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

  defp generating_messages_query do
    Message
    |> where([message], message.type == :message)
    |> where([message], message.status == :generating)
  end

  def lock_generating_message_by_id(repo, message_id) do
    generating_messages_query()
    |> where([message], message.id == ^message_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  @doc """
  Refreshes a generating response lease and schedules its next orphan deadline.
  """
  @spec touch_generating_response(String.t(), binary(), map() | nil) ::
          {:ok, Message.t() | :already_terminal} | {:error, :not_found | term()}
  def touch_generating_response(subject_uid, response_id, upstream_progress \\ nil) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, message_id} <- decode_response_id(response_id) do
      Repo.transact(fn repo ->
        metadata =
          if is_map(upstream_progress), do: %{"upstream_progress" => upstream_progress}, else: %{}

        case Message
             |> Ash.Query.filter(id == ^message_id and subject_uid == ^subject_uid)
             |> Ankole.Ash.bulk_update(:heartbeat, %{now: now, metadata: metadata},
               strategy: [:atomic],
               return_records?: true,
               return_errors?: true
             ) do
          %Ash.BulkResult{status: :success, records: [message]} ->
            with :ok <- notify_ai_message_deadline(repo, message), do: {:ok, message}

          %Ash.BulkResult{status: :success, records: []} ->
            case Message
                 |> Ash.Query.filter(id == ^message_id and subject_uid == ^subject_uid)
                 |> Ankole.Ash.read_one!() do
              %Message{} -> {:ok, :already_terminal}
              nil -> {:error, :not_found}
            end

          %Ash.BulkResult{errors: errors} ->
            {:error, Ash.Error.to_error_class(errors)}
        end
      end)
    else
      _invalid -> {:error, :not_found}
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
      Repo.transact(fn ->
        case Message
             |> Ash.Query.filter(id == ^message_id and subject_uid == ^subject_uid)
             |> Ankole.Ash.bulk_update(
               :record_progress,
               %{metadata: %{"upstream_progress" => progress}},
               strategy: [:atomic],
               return_records?: true,
               select: [:id],
               return_errors?: true
             ) do
          %Ash.BulkResult{status: :success, records: [_message]} -> {:ok, :ok}
          %Ash.BulkResult{status: :success, records: []} -> {:error, :not_found}
          %Ash.BulkResult{errors: errors} -> {:error, Ash.Error.to_error_class(errors)}
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        error -> error
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
    now = DateTime.utc_now(:microsecond)

    case Repo.transact(fn repo ->
           fail_generating_response_in_tx(
             repo,
             subject_uid,
             response_id,
             error_details,
             now
           )
         end) do
      {:ok, %Message{} = message} = ok ->
        Events.publish(message, :response_failed, %{error: error_details})
        ok

      other ->
        other
    end
  end

  @doc """
  Transactional variant of `fail_generating_response/3` for callers that own a
  wider transaction. It has no domain-specific side effects.
  """
  @spec fail_generating_response_in_tx(module(), String.t(), binary(), map(), DateTime.t()) ::
          {:ok, Message.t() | :already_terminal} | {:error, :not_found | term()}
  def fail_generating_response_in_tx(repo, subject_uid, response_id, error_details, now)
      when is_map(error_details) do
    transition_generating_response(
      repo,
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
  def retract_generating_response_in_tx(repo, subject_uid, response_id, reason, now)
      when is_binary(reason) do
    transition_generating_response(
      repo,
      subject_uid,
      response_id,
      now,
      :retract,
      {"retraction", %{"reason" => reason, "retracted_at" => DateTime.to_iso8601(now)}}
    )
  end

  defp transition_generating_response(repo, subject_uid, response_id, now, action, {key, value}) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, message_id} <- decode_response_id(response_id) do
      case lock_response_for_subject(repo, subject_uid, message_id) do
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
    case Repo.transact(fn repo -> reconcile_orphaned_response_in_tx(repo, response_id, opts) end) do
      {:ok, {:failed, %Message{} = message, error}} ->
        Events.publish(message, :response_failed, %{error: error})
        {:ok, :failed}

      other ->
        other
    end
  end

  @doc false
  def reconcile_orphaned_response_in_tx(repo, response_id, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, message_id} <- decode_response_id(response_id) do
      case lock_generating_message_by_id(repo, message_id) do
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
            with :ok <- notify_ai_message_deadline(repo, message), do: {:ok, :live}
          end

        nil ->
          {:ok, :already_terminal}
      end
    end
  end

  defp lock_response_for_subject(repo, subject_uid, message_id) do
    Message
    |> where([message], message.id == ^message_id)
    |> where([message], message.subject_uid == ^subject_uid)
    |> lock("FOR UPDATE")
    |> repo.one()
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

      %Message{} = message ->
        Repo.transact(fn repo ->
          case lock_generating_message_by_id(repo, message.id) do
            nil -> {:ok, :already_terminal}
            current -> Ankole.Ash.update(current, action, %{output: output, metadata: metadata})
          end
        end)
        |> case do
          {:ok, %Message{} = updated} = result ->
            if action == :complete,
              do:
                Events.publish(updated, complete_event_type(updated), %{content: updated.content}),
              else: Events.publish(updated, :response_failed, %{error: metadata["error"]})

            result

          other ->
            other
        end
    end
  end

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

  def notify_ai_message_deadline(repo, %Message{} = message) do
    Ankole.AIGateway.Jobs.ReconcileOrphanedResponse.schedule_in_tx(
      repo,
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
