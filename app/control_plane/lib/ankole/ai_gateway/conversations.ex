defmodule Ankole.AIGateway.Conversations do
  @moduledoc """
  Durable AIGateway conversation and runtime-profile API.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  @doc """
  Creates or reuses the active conversation for one subject-local key.
  """
  @spec ensure_conversation(String.t(), String.t(), keyword()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def ensure_conversation(subject_uid, conversation_key, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    ensure_conversation_in_tx(repo, normalize_uid(subject_uid), conversation_key)
  end

  @doc """
  Creates a conversation for a first `response.create store=true` request that
  did not name an existing conversation or previous response anchor.

  The generated conversation key is an implementation detail. The metadata flag
  lets operators and future cleanup distinguish conversations created implicitly
  by the stateful Responses API.
  """
  @spec create_managed_stateful_responses_conversation(String.t(), keyword()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def create_managed_stateful_responses_conversation(subject_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    metadata = managed_stateful_responses_metadata(Keyword.get(opts, :metadata, %{}))

    %Conversation{}
    |> Conversation.changeset(%{
      subject_uid: normalize_uid(subject_uid),
      conversation_key: managed_stateful_responses_conversation_key(),
      metadata: metadata
    })
    |> repo.insert()
  end

  @doc """
  Ensures the active conversation inside a caller-owned transaction.
  """
  @spec ensure_conversation_in_tx(module(), String.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, term()}
  # Uses insert-then-refetch to tolerate concurrent first input for the same
  # conversation key without exposing unique-constraint details to callers.
  def ensure_conversation_in_tx(repo, subject_uid, conversation_key) do
    subject_uid = normalize_uid(subject_uid)

    case active_conversation(repo, subject_uid, conversation_key) do
      %Conversation{} = conversation ->
        {:ok, conversation}

      nil ->
        %Conversation{}
        |> Conversation.changeset(%{
          subject_uid: subject_uid,
          conversation_key: conversation_key,
          metadata: %{}
        })
        |> repo.insert()
        |> case do
          {:ok, %Conversation{} = conversation} ->
            {:ok, conversation}

          {:error, _changeset} ->
            refetch_active_conversation(repo, subject_uid, conversation_key)
        end
    end
  end

  @doc """
  Locks a conversation row for update.
  """
  @spec lock_conversation(module(), term()) :: Conversation.t() | nil
  def lock_conversation(repo, conversation_id) do
    Conversation
    |> where([conversation], conversation.id == ^conversation_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  @doc """
  Locks the active conversation for one subject-local key inside a caller-owned transaction.
  """
  @spec active_conversation_for_update(module(), String.t(), String.t()) ::
          Conversation.t() | nil
  def active_conversation_for_update(repo, subject_uid, conversation_key) do
    Conversation
    |> where([conversation], conversation.subject_uid == ^normalize_uid(subject_uid))
    |> where([conversation], conversation.conversation_key == ^conversation_key)
    |> where([conversation], is_nil(conversation.ended_at))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  @doc """
  Lists active conversations using only generic conversation attributes.

  The caller may scope by `subject_uid`, `conversation_key`, or an insertion
  cutoff. Results are deterministic and may be locked when the caller owns a
  wider transaction.
  """
  @spec list_active_conversations(module(), keyword()) :: [Conversation.t()]
  def list_active_conversations(repo, opts \\ []) when is_list(opts) do
    limit = normalize_limit(Keyword.get(opts, :limit, 1_000))

    Conversation
    |> where([conversation], is_nil(conversation.ended_at))
    |> maybe_filter_subject_uid(Keyword.get(opts, :subject_uid))
    |> maybe_filter_conversation_key(Keyword.get(opts, :conversation_key))
    |> maybe_filter_inserted_before(Keyword.get(opts, :inserted_before))
    |> maybe_exclude_conversation_key_prefixes(
      Keyword.get(opts, :exclude_conversation_key_prefixes, [])
    )
    |> order_by(
      [conversation],
      asc: conversation.subject_uid,
      asc: conversation.conversation_key
    )
    |> limit(^limit)
    |> maybe_lock(Keyword.get(opts, :lock, false))
    |> repo.all()
  end

  defp active_conversation(repo, subject_uid, conversation_key) do
    Conversation
    |> where([conversation], conversation.subject_uid == ^subject_uid)
    |> where([conversation], conversation.conversation_key == ^conversation_key)
    |> where([conversation], is_nil(conversation.ended_at))
    |> repo.one()
  end

  defp refetch_active_conversation(repo, subject_uid, conversation_key) do
    case active_conversation(repo, subject_uid, conversation_key) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :conversation_not_found}
    end
  end

  defp maybe_filter_subject_uid(query, subject_uid) when is_binary(subject_uid),
    do: where(query, [conversation], conversation.subject_uid == ^normalize_uid(subject_uid))

  defp maybe_filter_subject_uid(query, _subject_uid), do: query

  defp maybe_filter_conversation_key(query, conversation_key) when is_binary(conversation_key),
    do: where(query, [conversation], conversation.conversation_key == ^conversation_key)

  defp maybe_filter_conversation_key(query, _conversation_key), do: query

  defp maybe_filter_inserted_before(query, %DateTime{} = inserted_before),
    do: where(query, [conversation], conversation.inserted_at < ^inserted_before)

  defp maybe_filter_inserted_before(query, _inserted_before), do: query

  defp maybe_exclude_conversation_key_prefixes(query, prefixes) when is_list(prefixes) do
    Enum.reduce(prefixes, query, fn
      prefix, query when is_binary(prefix) and prefix != "" ->
        where(query, [conversation], not like(conversation.conversation_key, ^"#{prefix}%"))

      _prefix, query ->
        query
    end)
  end

  defp maybe_exclude_conversation_key_prefixes(query, _prefixes), do: query

  defp maybe_lock(query, true), do: lock(query, "FOR UPDATE")
  defp maybe_lock(query, false), do: query

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_limit(_limit), do: 1_000

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)

  defp managed_stateful_responses_metadata(metadata) when is_map(metadata) do
    Map.put(metadata, "managed_by_stateful_responses_api", true)
  end

  defp managed_stateful_responses_metadata(_metadata) do
    %{"managed_by_stateful_responses_api" => true}
  end

  defp managed_stateful_responses_conversation_key do
    "stateful-responses-api:#{UUIDv7.autogenerate()}"
  end
end
