defmodule Ankole.Conversations.Queries do
  @moduledoc false

  require Ash.Query

  alias Ankole.Conversations.{Conversation, InputTombstone, Message, Participant}
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Repo
  alias Ankole.Signals.Signal

  @addressed "conversation.message.addressed"

  @doc "Commits the effects of a visible Message change with its observation."
  def message_changed_in_tx(before_message, after_message, now) do
    if before_message != nil and after_message == nil do
      :ok = Ankole.Sessions.AmbientCuration.message_removed_in_tx(before_message)
    end

    fields = [
      :text,
      :author_type,
      :author_uid,
      :attachments,
      :links,
      :mentions,
      :rich_content,
      :reply_to_message_id
    ]

    changed? =
      before_message != nil and
        (after_message == nil or
           Map.take(before_message, fields) != Map.take(after_message, fields))

    if changed? do
      Ankole.Brain.Sources.invalidate_conversation_message_in_tx(before_message, now)
    else
      :ok
    end
  end

  @doc "Returns a Signal's committed statement when both IDs name the same Conversation."
  def message_for_signal(%{message_id: id, conversation_id: conversation_id})
      when is_binary(id) and is_binary(conversation_id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id) do
      conversation_message(conversation_id, id)
    else
      _ -> nil
    end
  end

  def message_for_signal(_event), do: nil

  @doc "Returns the latest reply candidate text for each requested Signal."
  @spec reply_candidate_texts([String.t()]) :: %{String.t() => String.t() | nil}
  def reply_candidate_texts([]), do: %{}

  def reply_candidate_texts(signal_ids) when is_list(signal_ids) do
    messages =
      Message
      |> Ash.Query.filter(signal_id in ^signal_ids)
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.select([:signal_id, :text])
      |> Ankole.Ash.read!()
      |> latest_by(:signal_id, :text)

    fallback_ids = Enum.filter(signal_ids, &is_nil(Map.get(messages, &1)))

    fallback =
      if fallback_ids == [] do
        %{}
      else
        Intent
        |> Ash.Query.filter(
          source_signal_id in ^fallback_ids and not is_nil(fallback_visible_text)
        )
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.select([:source_signal_id, :fallback_visible_text])
        |> Ankole.Ash.read!()
        |> latest_by(:source_signal_id, :fallback_visible_text)
      end

    Map.new(signal_ids, &{&1, Map.get(messages, &1) || Map.get(fallback, &1)})
  end

  # The rows are sorted newest first, so the first row of each key wins.
  defp latest_by(rows, key, value) do
    Enum.reduce(rows, %{}, fn row, acc ->
      Map.put_new(acc, Map.fetch!(row, key), Map.fetch!(row, value))
    end)
  end

  @doc "Reads a bounded snapshot of statements not yet included by the caller."
  def context_snapshot(id, key, read_seq, excluded_ids, opts \\ []) do
    Repo.transact_top_level(fn ->
      context_snapshot_in_tx(id, key, read_seq, excluded_ids, opts)
    end)
  end

  @doc false
  def context_snapshot_in_tx(
        id,
        %{agent_uid: agent_uid, session_id: session_id},
        read_seq,
        excluded_ids,
        opts
      ) do
    limit = min(max(Keyword.get(opts, :limit, 50), 1), 500)

    with {:ok, id} <- cast_id(id),
         %Conversation{} = conversation <-
           Conversation
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.lock("FOR SHARE")
           |> Ankole.Ash.read_one!() do
      max_seq = conversation.sequence_high_water

      messages =
        Message
        |> Ash.Query.filter(
          conversation_id == ^id and seq > ^read_seq and seq <= ^max_seq and
            (is_nil(session_id) or session_id != ^session_id or is_nil(author_uid) or
               author_uid != ^agent_uid) and id not in ^excluded_ids and not withdrawn and
            not exists(
              Signal,
              message_id == parent(id) and conversation_id == ^id and producer == :kernel and
                type == ^@addressed and status in [:queued, :running] and
                is_nil(last_attempt_at)
            )
        )
        |> Ash.Query.sort(seq: :desc)
        |> Ash.Query.limit(limit)
        |> Ankole.Ash.read!()
        |> Enum.reverse()

      {:ok, %{messages: messages, max_seq: max_seq}}
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  @doc false
  def ids_for_agent_in_tx(uid) do
    uid
    |> native_conversations_of_agent()
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.id)
  end

  @doc false
  def delete_for_agent_in_tx(uid) do
    case uid |> native_conversations_of_agent() |> Ankole.Ash.destroy_where(:remove) do
      {:ok, _conversations} -> :ok
      {:error, _} = error -> error
    end
  end

  defp native_conversations_of_agent(uid) do
    Ash.Query.filter(
      Conversation,
      kind == :native and
        exists(
          Participant,
          conversation_id == parent(id) and principal_uid == ^uid and role == :agent
        )
    )
  end

  @doc "Allocates one committed statement sequence in the caller's transaction."
  def next_sequence_in_tx(%Conversation{id: id}) do
    case lock_conversation(id) do
      %Conversation{} = conversation ->
        with {:ok, updated} <- Ankole.Ash.update(conversation, :advance_sequence, %{}),
             do: {:ok, updated.sequence_high_water}

      nil ->
        {:error, :conversation_not_found}
    end
  end

  @doc "Deletes the input tombstones whose hold ended at `now` and gives their count."
  @spec expire_input_tombstones(DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def expire_input_tombstones(now) do
    with {:ok, removed} <-
           Ankole.Ash.destroy_where(InputTombstone, :expire, %{now: now}),
         do: {:ok, length(removed)}
  end

  @doc """
  Locks one Conversation row in the caller's transaction.

  `mode` is `:update`, `:share`, or `:key_share`.
  """
  @spec lock_conversation_in_tx(Ecto.UUID.t(), :update | :share | :key_share) ::
          {:ok, Conversation.t()} | {:error, :not_found}
  def lock_conversation_in_tx(id, mode \\ :update) do
    case Conversation
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.lock(row_lock(mode))
         |> Ankole.Ash.read_one() do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  def lock_conversation(id) do
    Conversation
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  def conversation_message(conversation_id, id) do
    Message
    |> Ash.Query.filter(id == ^id and conversation_id == ^conversation_id)
    |> Ankole.Ash.read_one!()
  end

  def cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end

  defp row_lock(:update), do: :for_update
  defp row_lock(:share), do: "FOR SHARE"
  defp row_lock(:key_share), do: "FOR KEY SHARE"
end
