defmodule Ankole.Memory.Recall.Scope do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Channel

  @type context :: %{
          actor_event: map(),
          allowed_channels: [String.t()],
          current_channel_id: String.t() | nil,
          turn_ref: TurnRef.t()
        }

  @doc false
  @spec resolve(map(), String.t()) :: {:ok, context()} | {:error, term()}
  def resolve(attrs, scope) when scope in ["current_channel", "permitted_context"] do
    with {:ok, turn_ref} <- required_turn_ref(attrs),
         {:ok, actor_event} <- optional_map(attrs, "actor_event"),
         {:ok, current_channel_id} <- current_channel_id(actor_event, turn_ref),
         {:ok, allowed_channels} <-
           allowed_channels(
             turn_ref.agent_uid,
             current_channel_id,
             scope,
             actor_event,
             turn_ref
           ) do
      {:ok,
       %{
         actor_event: actor_event,
         allowed_channels: allowed_channels,
         current_channel_id: current_channel_id,
         turn_ref: turn_ref
       }}
    end
  end

  defp allowed_channels(_agent_uid, nil, "current_channel", _actor_event, _turn_ref),
    do: {:ok, []}

  defp allowed_channels(
         _agent_uid,
         current_channel_id,
         "current_channel",
         _actor_event,
         _turn_ref
       ),
       do: {:ok, [current_channel_id]}

  defp allowed_channels(_agent_uid, nil, "permitted_context", _actor_event, _turn_ref),
    do: {:ok, []}

  defp allowed_channels(agent_uid, current_channel_id, "permitted_context", actor_event, turn_ref) do
    case Repo.get(Channel, current_channel_id) do
      %Channel{kind: :im_dm} = channel ->
        dm_permitted_channels(agent_uid, channel, actor_event, turn_ref)

      %Channel{} ->
        {:ok, [current_channel_id]}

      nil ->
        {:ok, []}
    end
  end

  defp dm_permitted_channels(agent_uid, %Channel{id: current_channel_id}, actor_event, turn_ref) do
    with {:ok, %{"binding_name" => binding_name, "principal_uid" => principal_uid}}
         when is_binary(binding_name) and is_binary(principal_uid) <-
           current_dm_context(actor_event, turn_ref) do
      # A shared group is visible from a DM only when both the human principal and this exact bot
      # binding are currently joined. Matching only one side would leak history across installations
      # that reuse the same provider subject or across multiple bot applications.
      participant_key = "#{String.downcase(agent_uid)}|#{binding_name}"

      group_channels =
        Channel
        |> join(:inner, [channel], group in Group, on: group.id == channel.principal_group_id)
        |> join(:inner, [_channel, group], membership in Membership,
          on: membership.group_id == group.id
        )
        |> where([channel, _group, _membership], channel.kind == :im_group)
        |> where([_channel, group, _membership], group.domain == :im_group)
        |> where([_channel, _group, membership], membership.principal_uid == ^principal_uid)
        |> where(
          [_channel, group, _membership],
          fragment(
            "?->'lark_im'->'sync_participants'->?->>'state' = 'joined'",
            group.metadata,
            ^participant_key
          )
        )
        |> select([channel, _group, _membership], channel.id)
        |> Repo.all()

      {:ok, Enum.uniq([current_channel_id | group_channels])}
    else
      # Missing identity context must not widen recall. The current DM remains useful, while shared
      # groups require the stronger principal-and-binding proof above.
      _reason -> {:ok, [current_channel_id]}
    end
  end

  defp current_dm_context(actor_event, turn_ref) do
    event = actor_event_record(actor_event, turn_ref)
    binding_name = actor_event_binding_name(actor_event, event)
    principal_uid = actor_event_author_principal_uid(actor_event, event)

    case {binding_name, principal_uid} do
      {binding_name, principal_uid} when is_binary(binding_name) and is_binary(principal_uid) ->
        {:ok,
         %{"binding_name" => binding_name, "principal_uid" => String.downcase(principal_uid)}}

      _value ->
        {:error, :missing_memory_principal_context}
    end
  end

  defp actor_event_record(%{"actor_event_id" => actor_event_id}, _turn_ref)
       when is_binary(actor_event_id) do
    Repo.get(ActorEvent, actor_event_id)
  end

  defp actor_event_record(_actor_event, %TurnRef{actor_event_id: actor_event_id})
       when is_binary(actor_event_id) do
    Repo.get(ActorEvent, actor_event_id)
  end

  defp actor_event_record(_actor_event, _turn_ref), do: nil

  defp actor_event_binding_name(actor_event, event) do
    text(actor_event, "binding_name") || actor_event_payload_binding_name(actor_event) ||
      case event do
        %ActorEvent{binding_name: binding_name} -> binding_name
        _value -> nil
      end
  end

  defp actor_event_payload_binding_name(actor_event) do
    actor_event
    |> actor_event_payload()
    |> get_in(["data", "session", "binding_name"])
  end

  defp actor_event_author_principal_uid(actor_event, event) do
    principal_uid_from_payload(actor_event_payload(actor_event)) ||
      case event do
        %ActorEvent{payload: payload} -> principal_uid_from_payload(payload)
        _value -> nil
      end
  end

  defp actor_event_payload(actor_event) when is_map(actor_event) do
    case Map.get(actor_event, "payload_json") || Map.get(actor_event, "payload") do
      payload when is_map(payload) -> payload
      _value -> %{}
    end
  end

  defp actor_event_payload(_actor_event), do: %{}

  defp principal_uid_from_payload(payload) when is_map(payload) do
    case get_in(payload, ["data", "entry", "author", "principal_uid"]) do
      principal_uid when is_binary(principal_uid) and principal_uid != "" -> principal_uid
      _value -> nil
    end
  end

  defp principal_uid_from_payload(_payload), do: nil

  defp current_channel_id(%{"signal_channel_id" => channel_id}, _turn)
       when is_binary(channel_id),
       do: {:ok, channel_id}

  defp current_channel_id(_actor_event, %TurnRef{actor_event_id: actor_event_id}) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{signal_channel_id: channel_id} when is_binary(channel_id) -> {:ok, channel_id}
      _value -> {:ok, nil}
    end
  end

  defp required_turn_ref(attrs) do
    case Map.get(attrs, "turn_ref") || Map.get(attrs, :turn_ref) do
      nil -> {:error, {:missing, "turn_ref"}}
      turn_ref -> TurnRef.from_wire(turn_ref)
    end
  end

  defp optional_map(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_map(value) -> {:ok, stringify_keys(value)}
      _value -> {:ok, %{}}
    end
  end

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) and is_map(value) ->
        {Atom.to_string(key), stringify_keys(value)}

      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} when is_map(value) ->
        {key, stringify_keys(value)}

      pair ->
        pair
    end)
  end
end
