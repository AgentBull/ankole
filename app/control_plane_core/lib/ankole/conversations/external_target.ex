defmodule Ankole.Conversations.ExternalTarget do
  @moduledoc """
  Projects the provider channel referenced by an AIGateway conversation.

  Conversation metadata owns the stable channel and DM peer identities. The
  Conversations owns the current group name, and Principal owns
  the current DM peer name. The adapter domain is connection configuration and
  does not change this projection.
  """

  require Ash.Query

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Conversations.Conversation, as: PublicConversation

  @type t :: %{
          required(:adapter) => String.t() | nil,
          required(:id) => String.t(),
          required(:kind) => String.t() | nil,
          required(:label) => String.t() | nil,
          required(:page_id) => String.t() | nil,
          required(:signal_origin?) => boolean()
        }

  @doc "Returns the origin channel for one signal-backed conversation."
  @spec origin(Conversation.t()) :: t() | nil
  def origin(%Conversation{} = conversation) do
    case Map.get(resolve_many([conversation]), conversation.id) do
      %{signal_origin?: true} = channel -> channel
      _channel -> nil
    end
  end

  @doc "Returns channel projections keyed by conversation ID."
  @spec resolve_many([Conversation.t()]) :: %{String.t() => t()}
  def resolve_many([]), do: %{}

  def resolve_many(conversations) when is_list(conversations) do
    channels = channels_by_id(conversations)
    peer_names = peer_names_by_uid(conversations)

    for %Conversation{} = conversation <- conversations,
        channel_id = channel_id(conversation),
        is_binary(channel_id),
        into: %{} do
      channel = Map.get(channels, channel_id)
      kind = channel_kind(conversation, channel)

      {conversation.id,
       %{
         id: channel_id,
         adapter: if(channel, do: adapter_segment(channel.provider_conversation_id)),
         kind: kind,
         label: channel_label(kind, conversation, channel, peer_names),
         page_id: if(channel, do: channel.page_id),
         signal_origin?: signal_origin?(conversation)
       }}
    end
  end

  defp channels_by_id(conversations) do
    channel_ids =
      conversations
      |> Enum.map(&channel_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case channel_ids do
      [] ->
        %{}

      channel_ids ->
        PublicConversation
        |> Ash.Query.filter(id in ^channel_ids)
        |> Ankole.Ash.read!()
        |> Map.new(&{&1.id, &1})
    end
  end

  defp peer_names_by_uid(conversations) do
    peer_uids =
      conversations
      |> Enum.map(&origin_text(&1, "peer_uid"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case peer_uids do
      [] ->
        %{}

      peer_uids ->
        Ankole.Principals.Domain.list_principals!(
          query: [filter: [uid: [in: peer_uids]], select: [:uid, :display_name]]
        )
        |> Map.new(&{&1.uid, &1.display_name})
    end
  end

  defp signal_origin?(%Conversation{} = conversation) do
    case Ankole.Sessions.Key.parse(conversation.conversation_key) do
      {:conversation, _} -> true
      {:job, _} -> false
      {:named, "stateful-responses-api:" <> _} -> false
      _ -> is_binary(origin_text(conversation, "conversation_id"))
    end
  end

  defp channel_id(%Conversation{} = conversation) do
    origin_text(conversation, "conversation_id") ||
      channel_id_from_key(conversation.conversation_key)
  end

  defp channel_id_from_key(key) do
    case Ankole.Sessions.Key.parse(key) do
      {:conversation, id} -> id
      _ -> nil
    end
  end

  defp channel_kind(_conversation, %PublicConversation{kind: :native}), do: "native"

  defp channel_kind(_conversation, %PublicConversation{external_kind: kind}) when is_atom(kind),
    do: Atom.to_string(kind)

  defp channel_kind(conversation, _channel), do: origin_text(conversation, "channel_kind")

  defp channel_label("im_dm", conversation, _channel, peer_names) do
    case origin_text(conversation, "peer_uid") do
      nil -> nil
      peer_uid -> Map.get(peer_names, peer_uid) || peer_uid
    end
  end

  defp channel_label(_kind, _conversation, %PublicConversation{title: name}, _peer_names)
       when is_binary(name),
       do: name

  defp channel_label(_kind, _conversation, _channel, _peer_names), do: nil

  defp adapter_segment(nil), do: nil

  defp adapter_segment(channel_id) do
    case String.split(channel_id, ":", parts: 2) do
      [adapter, _rest] when adapter != "" -> adapter
      _unsegmented -> nil
    end
  end

  defp origin_text(%Conversation{} = conversation, key) do
    case get_in(conversation.metadata || %{}, ["origin", key]) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end
end
