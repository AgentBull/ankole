defmodule Ankole.Sessions.ConsoleQueries do
  @moduledoc """
  Read-only model history and Session projections for the operator console.

  Operator authorization is checked by the controller. This module normalizes
  the console parameters, reads through the AIGateway domain, and combines
  generic model history with Session and external conversation display facts.
  The `console_list` read action of `Ankole.AIGateway.Schemas.Conversation`
  and `Ankole.Sessions.ConsoleQueries.Prepare` own the list filters.
  """

  alias Ankole.AIGateway
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Principals
  alias Ankole.Conversations.ExternalTarget

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
         {:ok, search} <- normalize_search(Keyword.get(opts, :search)),
         {:ok, cursor} <- normalize_keyset(Keyword.get(opts, :cursor)) do
      limit =
        clamp(Keyword.get(opts, :limit, @conversation_limit_default), @conversation_limit_max)

      %{
        subject_uid: subject_uid,
        conversation_key: conversation_key,
        search: search,
        active: normalize_active(Keyword.get(opts, :active)),
        min_messages: normalize_min_messages(Keyword.get(opts, :min_messages))
      }
      |> AIGateway.list_console_conversations(page: page_options(limit, cursor))
      |> conversation_page(cursor)
    end
  end

  # The keyset of the last row is the cursor of the next page. A cursor that
  # the read cannot decode is the only invalid input after normalization.
  defp conversation_page({:ok, %{results: conversations, more?: more?}}, _cursor) do
    next_cursor = if more?, do: List.last(conversations).__metadata__[:keyset]
    {:ok, %{conversations: conversations, next_cursor: next_cursor}}
  end

  defp conversation_page({:error, %{class: :invalid}}, cursor) when is_binary(cursor),
    do: {:error, :invalid_cursor}

  defp conversation_page({:error, _reason} = error, _cursor), do: error

  defp page_options(limit, nil), do: [limit: limit]
  defp page_options(limit, cursor), do: [limit: limit, after: cursor]

  @spec get_conversation(String.t()) :: Conversation.t() | nil
  def get_conversation(conversation_id) when is_binary(conversation_id) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, conversation_id} -> AIGateway.get_conversation_by_id!(conversation_id)
      :error -> nil
    end
  end

  @spec list_messages(String.t(), keyword()) ::
          {:ok, %{messages: [Message.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor}
  def list_messages(conversation_id, opts \\ [])
      when is_binary(conversation_id) and is_list(opts) do
    # No existence check: a malformed or unknown id simply yields an empty page,
    # so the read-only browser keeps rendering on stale links.
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         {:ok, cursor} <- decode_cursor(Keyword.get(opts, :cursor)) do
      limit = clamp(Keyword.get(opts, :limit, @message_limit_default), @message_limit_max)

      rows =
        AIGateway.list_messages!(
          query: [
            filter: [{:conversation_id, conversation_id} | after_cursor(cursor)],
            sort: [inserted_at: :asc, id: :asc],
            limit: limit + 1
          ]
        )

      page = Enum.take(rows, limit)

      next_cursor =
        if length(rows) > limit do
          page |> List.last() |> encode_cursor(& &1.inserted_at)
        end

      {:ok, %{messages: page, next_cursor: next_cursor}}
    else
      :error -> {:ok, %{messages: [], next_cursor: nil}}
      {:error, :invalid_cursor} = error -> error
    end
  end

  @spec console_projections([Conversation.t()]) :: [map()]
  def console_projections(conversations) when is_list(conversations) do
    decorations = decorate_conversations(conversations)
    Enum.map(conversations, &conversation_projection(&1, decorations))
  end

  @spec console_projection(Conversation.t() | Message.t()) :: map()
  def console_projection(%Conversation{} = conversation) do
    conversation_projection(conversation, decorate_conversations([conversation]))
  end

  def console_projection(%Message{} = message) do
    %{
      id: message.id,
      subject_uid: message.subject_uid,
      conversation_id: message.conversation_id,
      type: Atom.to_string(message.type),
      status: Atom.to_string(message.status),
      previous_message_id: message.previous_message_id,
      content: message.content || [],
      metadata: message.metadata || %{},
      inserted_at: iso8601(message.inserted_at),
      updated_at: iso8601(message.updated_at)
    }
  end

  defp conversation_projection(%Conversation{} = conversation, decorations) do
    decoration = Map.get(decorations, conversation.id, %{})

    %{
      id: conversation.id,
      subject_uid: conversation.subject_uid,
      conversation_key: conversation.conversation_key,
      kind: conversation_kind(conversation, decoration),
      display_name: Map.get(decoration, :display_name),
      channel_kind: Map.get(decoration, :channel_kind),
      signal_adapter: Map.get(decoration, :signal_adapter),
      message_count: Map.get(decoration, :message_count, 0),
      ended_at: iso8601(conversation.ended_at),
      metadata: conversation.metadata || %{},
      inserted_at: iso8601(conversation.inserted_at),
      updated_at: iso8601(conversation.updated_at)
    }
  end

  # Page-local decoration uses one count read and one shared channel
  # projection. The `messages` relationship constrains both columns of the
  # `(subject_uid, conversation_id)` messages index.
  defp decorate_conversations([]), do: %{}

  defp decorate_conversations(conversations) do
    counts = message_counts(conversations)
    channels = ExternalTarget.resolve_many(conversations)

    Map.new(conversations, fn conversation ->
      channel = Map.get(channels, conversation.id, %{})

      {conversation.id,
       %{
         message_count: Map.get(counts, conversation.id, 0),
         display_name: Map.get(channel, :label),
         channel_kind: signal_channel_value(channel, :kind),
         signal_adapter: signal_channel_value(channel, :adapter),
         signal_origin?: Map.get(channel, :signal_origin?, false)
       }}
    end)
  end

  defp message_counts(conversations) do
    ids = Enum.map(conversations, & &1.id)

    AIGateway.list_conversations!(
      query: [
        filter: [id: [in: ids]],
        select: [:id],
        aggregate: {:message_count, :count, :messages}
      ]
    )
    |> Map.new(&{&1.id, &1.aggregates[:message_count] || 0})
  end

  # Display kind derived from the key constructors (signal ingress, background
  # jobs, cron execution sessions, managed Responses conversations). Custom
  # adapter session ids for channel-backed chats still read as "signal"
  # through the recorded conversation origin.
  defp conversation_kind(%Conversation{} = conversation, decoration) do
    case Ankole.Sessions.Key.parse(conversation.conversation_key) do
      {:conversation, _} -> "conversation"
      {:job, _} -> "job"
      {:cron, _} -> "cron"
      {:named, "stateful-responses-api:" <> _rest} -> "responses_api"
      _custom -> if Map.get(decoration, :signal_origin?, false), do: "signal", else: "custom"
    end
  end

  defp signal_channel_value(%{signal_origin?: true} = channel, key), do: Map.get(channel, key)
  defp signal_channel_value(_channel, _key), do: nil

  defp after_cursor(nil), do: []

  defp after_cursor({inserted_at, id}) do
    [
      or: [
        [inserted_at: [greater_than: inserted_at]],
        [inserted_at: inserted_at, id: [greater_than: id]]
      ]
    ]
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

  # The read action decodes the keyset cursor.
  defp normalize_keyset(nil), do: {:ok, nil}
  defp normalize_keyset(""), do: {:ok, nil}
  defp normalize_keyset(cursor) when is_binary(cursor), do: {:ok, cursor}
  defp normalize_keyset(_cursor), do: {:error, :invalid_cursor}

  defp normalize_subject_uid(nil), do: {:ok, nil}
  defp normalize_subject_uid(""), do: {:ok, nil}

  defp normalize_subject_uid(subject_uid) do
    case Principals.normalize_uid(subject_uid) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, :invalid_subject_uid}
    end
  end

  defp normalize_search(nil), do: {:ok, nil}

  defp normalize_search(search) when is_binary(search) do
    case String.trim(search) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_search(_value), do: {:error, :invalid_search}

  defp normalize_conversation_key(nil), do: {:ok, nil}
  defp normalize_conversation_key(""), do: {:ok, nil}

  defp normalize_conversation_key(conversation_key) when is_binary(conversation_key),
    do: {:ok, conversation_key}

  defp normalize_conversation_key(_value), do: {:error, :invalid_conversation_key}

  defp normalize_active(active) when is_boolean(active), do: active
  defp normalize_active(_active), do: nil

  # A threshold applies only when it is a positive integer.
  defp normalize_min_messages(min) when is_integer(min) and min > 0, do: min
  defp normalize_min_messages(_min), do: nil

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
