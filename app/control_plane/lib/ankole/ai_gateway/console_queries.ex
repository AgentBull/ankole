defmodule Ankole.AIGateway.ConsoleQueries do
  @moduledoc """
  Read-only, installation-wide projections of AIGateway conversations and
  messages for the operator console.

  Unlike `Ankole.AIGateway.Conversations` and
  `Ankole.AIGateway.StatefulResponses`, this module carries no runtime locks and
  enforces no subject ownership: it exists only to browse historical and active
  conversation logs. All durable writes remain owned by the runtime contexts.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Principals
  alias Ankole.Repo

  @conversation_limit_max 100
  @conversation_limit_default 50
  @message_limit_max 500
  @message_limit_default 200

  @spec list_conversations(keyword()) ::
          {:ok, %{conversations: [Conversation.t()], next_cursor: String.t() | nil}}
          | {:error, term()}
  def list_conversations(opts \\ []) when is_list(opts) do
    with {:ok, subject_uid} <- normalize_subject_uid(Keyword.get(opts, :subject_uid)),
         {:ok, conversation_key} <-
           normalize_conversation_key(Keyword.get(opts, :conversation_key)),
         {:ok, cursor} <- decode_cursor(Keyword.get(opts, :cursor)) do
      limit =
        clamp(Keyword.get(opts, :limit, @conversation_limit_default), @conversation_limit_max)

      active = Keyword.get(opts, :active)

      rows =
        Conversation
        |> maybe_filter_subject_uid(subject_uid)
        |> maybe_filter_conversation_key(conversation_key)
        |> maybe_filter_active(active)
        |> maybe_before_cursor(cursor)
        |> order_by([conversation], desc: conversation.updated_at, desc: conversation.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      page = Enum.take(rows, limit)

      next_cursor =
        if length(rows) > limit do
          page |> List.last() |> encode_cursor(& &1.updated_at)
        end

      {:ok, %{conversations: page, next_cursor: next_cursor}}
    end
  end

  @spec get_conversation(String.t()) :: Conversation.t() | nil
  def get_conversation(conversation_id) when is_binary(conversation_id) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, conversation_id} -> Repo.get(Conversation, conversation_id)
      :error -> nil
    end
  end

  @spec list_messages(String.t(), keyword()) ::
          {:ok, %{messages: [Message.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor}
  def list_messages(conversation_id, opts \\ [])
      when is_binary(conversation_id) and is_list(opts) do
    # No existence or UUID-shape check: a malformed or unknown id simply yields
    # an empty page (the query filters by value), so the read-only browser keeps
    # rendering on stale links.
    with {:ok, cursor} <- decode_cursor(Keyword.get(opts, :cursor)) do
      limit = clamp(Keyword.get(opts, :limit, @message_limit_default), @message_limit_max)

      rows =
        Message
        |> where([message], message.conversation_id == ^conversation_id)
        |> maybe_after_cursor(cursor)
        |> order_by([message], asc: message.inserted_at, asc: message.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      page = Enum.take(rows, limit)

      next_cursor =
        if length(rows) > limit do
          page |> List.last() |> encode_cursor(& &1.inserted_at)
        end

      {:ok, %{messages: page, next_cursor: next_cursor}}
    end
  end

  @spec console_projection(Conversation.t()) :: map()
  def console_projection(%Conversation{} = conversation) do
    %{
      id: conversation.id,
      subject_uid: conversation.subject_uid,
      conversation_key: conversation.conversation_key,
      ended_at: iso8601(conversation.ended_at),
      metadata: conversation.metadata || %{},
      inserted_at: iso8601(conversation.inserted_at),
      updated_at: iso8601(conversation.updated_at)
    }
  end

  @spec console_projection(Message.t()) :: map()
  def console_projection(%Message{} = message) do
    %{
      id: message.id,
      subject_uid: message.subject_uid,
      conversation_id: message.conversation_id,
      type: message.type,
      role: message.role,
      status: message.status,
      previous_message_id: message.previous_message_id,
      content: message.content || [],
      metadata: message.metadata || %{},
      inserted_at: iso8601(message.inserted_at),
      updated_at: iso8601(message.updated_at)
    }
  end

  defp maybe_filter_subject_uid(query, nil), do: query

  defp maybe_filter_subject_uid(query, subject_uid),
    do: where(query, [conversation], conversation.subject_uid == ^subject_uid)

  defp maybe_filter_conversation_key(query, nil), do: query

  defp maybe_filter_conversation_key(query, conversation_key),
    do:
      where(query, [conversation], ilike(conversation.conversation_key, ^"%#{conversation_key}%"))

  defp maybe_filter_active(query, nil), do: query
  defp maybe_filter_active(query, true), do: where(query, [c], is_nil(c.ended_at))
  defp maybe_filter_active(query, false), do: where(query, [c], not is_nil(c.ended_at))

  defp maybe_before_cursor(query, nil), do: query

  defp maybe_before_cursor(query, {updated_at, id}) do
    where(
      query,
      [conversation],
      conversation.updated_at < ^updated_at or
        (conversation.updated_at == ^updated_at and conversation.id < ^id)
    )
  end

  defp maybe_after_cursor(query, nil), do: query

  defp maybe_after_cursor(query, {inserted_at, id}) do
    where(
      query,
      [message],
      message.inserted_at > ^inserted_at or
        (message.inserted_at == ^inserted_at and message.id > ^id)
    )
  end

  defp clamp(value, max) when is_integer(value) do
    value |> max(1) |> min(max)
  end

  defp clamp(_value, max), do: max

  defp encode_cursor(nil, _field), do: nil

  defp encode_cursor(%_{} = row, field) do
    "#{DateTime.to_iso8601(field.(row))}|#{row.id}"
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil), do: {:ok, nil}
  defp decode_cursor(""), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [at_text, id] <- String.split(decoded, "|", parts: 2),
         {:ok, at, _offset} <- DateTime.from_iso8601(at_text),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _reason -> {:error, :invalid_cursor}
    end
  end

  defp normalize_subject_uid(nil), do: {:ok, nil}
  defp normalize_subject_uid(""), do: {:ok, nil}

  defp normalize_subject_uid(subject_uid) do
    case Principals.normalize_uid(subject_uid) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, :invalid_subject_uid}
    end
  end

  defp normalize_conversation_key(nil), do: {:ok, nil}
  defp normalize_conversation_key(""), do: {:ok, nil}

  defp normalize_conversation_key(conversation_key) when is_binary(conversation_key),
    do: {:ok, conversation_key}

  defp normalize_conversation_key(_value), do: {:error, :invalid_conversation_key}

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
