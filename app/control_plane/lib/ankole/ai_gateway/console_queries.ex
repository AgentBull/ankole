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
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.Schedule.Cron
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.ConversationChannel

  require Ankole.BackgroundAgentJobs
  require Ankole.Schedule.Cron

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
         {:ok, cursor} <- decode_cursor(Keyword.get(opts, :cursor)) do
      limit =
        clamp(Keyword.get(opts, :limit, @conversation_limit_default), @conversation_limit_max)

      active = Keyword.get(opts, :active)
      min_messages = Keyword.get(opts, :min_messages)

      rows =
        from(conversation in Conversation, as: :conversation)
        |> maybe_filter_subject_uid(subject_uid)
        |> maybe_filter_conversation_key(conversation_key)
        |> maybe_filter_search(search)
        |> maybe_filter_active(active)
        |> maybe_filter_min_messages(min_messages)
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

  # Page-local decoration uses one grouped count and one shared channel
  # projection. The count constrains both columns of the
  # `(subject_uid, conversation_id)` messages index.
  defp decorate_conversations([]), do: %{}

  defp decorate_conversations(conversations) do
    counts = message_counts(conversations)
    channels = ConversationChannel.resolve_many(conversations)

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
    subject_uids = conversations |> Enum.map(& &1.subject_uid) |> Enum.uniq()

    Message
    |> where([message], message.conversation_id in ^ids and message.subject_uid in ^subject_uids)
    |> group_by([message], message.conversation_id)
    |> select([message], {message.conversation_id, count(message.id)})
    |> Repo.all()
    |> Map.new()
  end

  # Display kind derived from the key constructors (signal ingress, background
  # jobs, cron execution sessions, dreaming runs, managed Responses
  # conversations). Custom adapter session ids for channel-backed chats still
  # read as "signal" through the brain scope declaration.
  defp conversation_kind(%Conversation{} = conversation, decoration) do
    case conversation.conversation_key do
      "signal-channel:" <> _rest -> "signal"
      "brain.dreaming:" <> _rest -> "dreaming"
      key when BackgroundAgentJobs.is_job_session_id(key) -> "job"
      key when Cron.is_execution_session_id(key) -> "cron"
      "stateful-responses-api:" <> _rest -> "responses_api"
      _custom -> if Map.get(decoration, :signal_origin?, false), do: "signal", else: "custom"
    end
  end

  defp signal_channel_value(%{signal_origin?: true} = channel, key), do: Map.get(channel, key)
  defp signal_channel_value(_channel, _key), do: nil

  defp maybe_filter_subject_uid(query, nil), do: query

  defp maybe_filter_subject_uid(query, subject_uid),
    do: where(query, [conversation], conversation.subject_uid == ^subject_uid)

  defp maybe_filter_conversation_key(query, nil), do: query

  defp maybe_filter_conversation_key(query, conversation_key),
    do:
      where(query, [conversation], ilike(conversation.conversation_key, ^"%#{conversation_key}%"))

  defp maybe_filter_search(query, nil), do: query

  # One operator search box: an exact subject UID, a session-key fragment, or a
  # fragment of a name the list shows. The name sources are the SignalsGateway
  # channel mirror for groups and Principal display names for DM peers. The
  # filter matches them as a disjunction. It does not copy the display
  # precedence.
  defp maybe_filter_search(query, search) do
    pattern = "%#{escape_like(search)}%"
    # Stored subject UIDs are canonical lowercase.
    subject = String.downcase(search)

    channel_match =
      from channel in Channel,
        where:
          ilike(channel.name, ^pattern) and
            (parent_as(:conversation).conversation_key ==
               fragment("'signal-channel:' || ?", channel.id) or
               fragment(
                 "? -> 'brain' ->> 'channel_id' = ?",
                 parent_as(:conversation).metadata,
                 channel.id
               ))

    peer_match =
      from principal in Principal,
        where:
          ilike(principal.display_name, ^pattern) and
            principal.uid ==
              fragment("? -> 'brain' ->> 'peer_uid'", parent_as(:conversation).metadata)

    where(
      query,
      [conversation],
      conversation.subject_uid == ^subject or
        ilike(conversation.conversation_key, ^pattern) or
        exists(channel_match) or
        exists(peer_match)
    )
  end

  # Session keys use `_` often, so a raw ILIKE pattern would read it as a
  # single-character wildcard.
  defp escape_like(text) do
    String.replace(text, ~r/([\\%_])/, "\\\\\\1")
  end

  defp maybe_filter_active(query, nil), do: query
  defp maybe_filter_active(query, true), do: where(query, [c], is_nil(c.ended_at))
  defp maybe_filter_active(query, false), do: where(query, [c], not is_nil(c.ended_at))

  # Both predicates match the leading columns of the
  # `ai_gateway_messages_conversation_index` composite index.
  defp maybe_filter_min_messages(query, min) when is_integer(min) and min > 0 do
    where(
      query,
      [conversation],
      fragment(
        "(SELECT COUNT(*) FROM ai_gateway_messages m WHERE m.subject_uid = ? AND m.conversation_id = ?) >= ?",
        conversation.subject_uid,
        conversation.id,
        ^min
      )
    )
  end

  defp maybe_filter_min_messages(query, _value), do: query

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

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
