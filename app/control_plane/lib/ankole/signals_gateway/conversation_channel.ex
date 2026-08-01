defmodule Ankole.SignalsGateway.ConversationChannel do
  @moduledoc """
  Projects the provider channel referenced by an AIGateway conversation.

  Conversation metadata owns the stable channel and DM peer identities. The
  SignalsGateway channel mirror owns the current group name, and Principal owns
  the current DM peer name. The adapter domain is connection configuration and
  does not change this projection.
  """

  import Ecto.Query

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Channel

  require Ankole.BackgroundAgentJobs

  @type t :: %{
          required(:adapter) => String.t() | nil,
          required(:kind) => String.t() | nil,
          required(:label) => String.t() | nil,
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
         adapter: adapter_segment(channel_id),
         kind: kind,
         label: channel_label(kind, conversation, channel, peer_names),
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
        Channel
        |> where([channel], channel.id in ^channel_ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
    end
  end

  defp peer_names_by_uid(conversations) do
    peer_uids =
      conversations
      |> Enum.map(&brain_text(&1, "peer_uid"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case peer_uids do
      [] ->
        %{}

      peer_uids ->
        Principal
        |> where([principal], principal.uid in ^peer_uids)
        |> select([principal], {principal.uid, principal.display_name})
        |> Repo.all()
        |> Map.new()
    end
  end

  defp signal_origin?(%Conversation{conversation_key: "signal-channel:" <> _channel_id}),
    do: true

  defp signal_origin?(%Conversation{conversation_key: "brain.dreaming:" <> _run_id}),
    do: false

  defp signal_origin?(%Conversation{conversation_key: key})
       when BackgroundAgentJobs.is_job_session_id(key),
       do: false

  defp signal_origin?(%Conversation{conversation_key: "stateful-responses-api:" <> _id}),
    do: false

  defp signal_origin?(%Conversation{} = conversation),
    do: is_binary(brain_text(conversation, "channel_id"))

  defp channel_id(%Conversation{} = conversation) do
    brain_text(conversation, "channel_id") || channel_id_from_key(conversation.conversation_key)
  end

  defp channel_id_from_key("signal-channel:" <> channel_id) when channel_id != "",
    do: channel_id

  defp channel_id_from_key(_key), do: nil

  defp channel_kind(_conversation, %Channel{kind: kind}), do: Atom.to_string(kind)
  defp channel_kind(conversation, _channel), do: brain_text(conversation, "channel_kind")

  defp channel_label("im_dm", conversation, _channel, peer_names) do
    case brain_text(conversation, "peer_uid") do
      nil -> nil
      peer_uid -> Map.get(peer_names, peer_uid) || peer_uid
    end
  end

  defp channel_label(_kind, _conversation, %Channel{name: name}, _peer_names)
       when is_binary(name),
       do: name

  defp channel_label(_kind, _conversation, _channel, _peer_names), do: nil

  defp adapter_segment(channel_id) do
    case String.split(channel_id, ":", parts: 2) do
      [adapter, _rest] when adapter != "" -> adapter
      _unsegmented -> nil
    end
  end

  defp brain_text(%Conversation{} = conversation, key) do
    case get_in(conversation.metadata || %{}, ["brain", key]) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end
end
