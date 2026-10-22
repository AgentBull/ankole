defmodule Ankole.AIGateway.Conversations do
  @moduledoc """
  Durable AIGateway conversation and runtime-profile API.
  """

  require Ash.Query

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Ecto.UUIDv7

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
    metadata = managed_stateful_responses_metadata(Keyword.get(opts, :metadata, %{}))

    Ankole.Ash.create(Conversation, :open, %{
      subject_uid: normalize_uid(subject_uid),
      conversation_key: managed_stateful_responses_conversation_key(),
      metadata: metadata
    })
  end

  @doc """
  Ensures the active conversation inside a caller-owned transaction.
  """
  @spec ensure_conversation_in_tx(module(), String.t(), String.t(), map()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def ensure_conversation_in_tx(_repo, subject_uid, conversation_key, metadata \\ %{})
      when is_map(metadata) do
    Ankole.Ash.create(Conversation, :ensure, %{
      subject_uid: normalize_uid(subject_uid),
      conversation_key: conversation_key,
      metadata: metadata
    })
  end

  @doc """
  Bumps the conversation's `updated_at` inside the caller's transaction.

  Message writes call this so the Console lists and orders conversations by
  their last activity instead of the row's last direct change.
  """
  @spec touch_conversation_in_tx(module(), String.t()) :: :ok
  def touch_conversation_in_tx(_repo, conversation_id) do
    case Conversation
         |> Ash.Query.filter(id == ^conversation_id)
         |> Ankole.Ash.bulk_update(:touch, %{}, strategy: [:atomic], return_errors?: true) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> raise Ash.Error.to_error_class(errors)
    end
  end

  @doc """
  Locks a conversation row for update.
  """
  @spec lock_conversation(module(), term()) :: Conversation.t() | nil
  def lock_conversation(_repo, conversation_id) do
    Conversation
    |> Ash.Query.filter(id == ^conversation_id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  @doc """
  Locks the active conversation for one subject-local key inside a caller-owned transaction.
  """
  @spec active_conversation_for_update(module(), String.t(), String.t()) ::
          Conversation.t() | nil
  def active_conversation_for_update(_repo, subject_uid, conversation_key) do
    Conversation
    |> Ash.Query.filter(subject_uid == ^normalize_uid(subject_uid))
    |> Ash.Query.filter(conversation_key == ^conversation_key)
    |> Ash.Query.filter(is_nil(ended_at))
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  @doc false
  @spec end_active_conversation_in_tx(module(), String.t(), String.t(), DateTime.t()) ::
          {:ok, Conversation.t() | nil} | {:error, term()}
  def end_active_conversation_in_tx(repo, subject_uid, conversation_key, %DateTime{} = now) do
    case active_conversation_for_update(repo, subject_uid, conversation_key) do
      %Conversation{} = conversation ->
        Ankole.Ash.update(conversation, :finish, %{ended_at: now})

      nil ->
        {:ok, nil}
    end
  end

  @doc "Checks whether the subject has retained model history for a key, including ended histories."
  def conversation_exists_by_key?(_repo, subject_uid, conversation_key) do
    Conversation
    |> Ash.Query.filter(
      subject_uid == ^normalize_uid(subject_uid) and conversation_key == ^conversation_key
    )
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read!()
    |> Enum.any?()
  end

  @doc """
  Lists active conversations using only generic conversation attributes.

  The caller may scope by `subject_uid`, `conversation_key`, or an insertion
  cutoff. Results are deterministic and may be locked when the caller owns a
  wider transaction.
  """
  @spec list_active_conversations(module(), keyword()) :: [Conversation.t()]
  def list_active_conversations(_repo, opts \\ []) when is_list(opts) do
    limit = normalize_limit(Keyword.get(opts, :limit, 1_000))

    Conversation
    |> Ash.Query.filter(is_nil(ended_at))
    |> maybe_filter_subject_uid(Keyword.get(opts, :subject_uid))
    |> maybe_filter_conversation_key(Keyword.get(opts, :conversation_key))
    |> maybe_filter_inserted_before(Keyword.get(opts, :inserted_before))
    |> Ash.Query.sort(subject_uid: :asc, conversation_key: :asc)
    |> Ash.Query.limit(limit)
    |> maybe_lock(Keyword.get(opts, :lock, false))
    |> Ankole.Ash.read!()
  end

  defp maybe_filter_subject_uid(query, subject_uid) when is_binary(subject_uid),
    do: Ash.Query.filter(query, subject_uid == ^normalize_uid(subject_uid))

  defp maybe_filter_subject_uid(query, _subject_uid), do: query

  defp maybe_filter_conversation_key(query, conversation_key) when is_binary(conversation_key),
    do: Ash.Query.filter(query, conversation_key == ^conversation_key)

  defp maybe_filter_conversation_key(query, _conversation_key), do: query

  defp maybe_filter_inserted_before(query, %DateTime{} = inserted_before),
    do: Ash.Query.filter(query, inserted_at < ^inserted_before)

  defp maybe_filter_inserted_before(query, _inserted_before), do: query

  defp maybe_lock(query, true), do: Ash.Query.lock(query, :for_update)
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
