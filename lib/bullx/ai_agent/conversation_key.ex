defmodule BullX.AIAgent.ConversationKey do
  @moduledoc """
  Deterministic AIAgent Conversation key derivation.

  The key is derived only from normalized Event data. Raw provider payloads,
  routing context projections, and CloudEvents `subject` are deliberately
  ignored.
  """

  alias BullX.AIAgent.Profile

  @prefix "ai_agent_conversation:v1"

  @type lane :: :addressed | :ambient
  @type result :: {:ok, String.t(), map()} | {:error, term()}

  @spec build(Profile.t(), String.t(), lane(), map()) :: result()
  def build(%Profile{} = profile, agent_principal_id, lane, event_data)
      when is_binary(agent_principal_id) and lane in [:addressed, :ambient] and is_map(event_data) do
    with {:ok, parts} <- key_parts(profile, agent_principal_id, lane, event_data),
         :ok <- reject_nul(parts),
         serialized <- serialize(parts),
         hash <- BullX.Ext.generic_hash(serialized) do
      {:ok, "v1:" <> hash, safe_metadata(parts)}
    end
  end

  def build(_profile, _agent_principal_id, _lane, _event_data), do: {:error, :invalid_key_input}

  @spec scene_identity(map()) :: map()
  def scene_identity(event_data) when is_map(event_data) do
    channel = map_value(event_data, "channel")
    scope = map_value(event_data, "scope")

    %{
      "channel_adapter" => string_value(channel, "adapter"),
      "channel_id" => string_value(channel, "id"),
      "channel_kind" => string_value(channel, "kind"),
      "scope_id" => string_value(scope, "id"),
      "thread_id" => string_value(scope, "thread_id")
    }
  end

  defp key_parts(profile, agent_principal_id, lane, event_data) do
    channel = map_value(event_data, "channel")
    scope = map_value(event_data, "scope")
    actor = map_value(event_data, "actor")
    isolation = resolved_isolation(profile, lane)
    actor_part = actor_part(actor, lane, isolation)

    parts = %{
      lane: Atom.to_string(lane),
      agent_principal_id: agent_principal_id,
      channel_adapter: string_value(channel, "adapter"),
      channel_id: string_value(channel, "id"),
      channel_kind: string_value(channel, "kind"),
      scope_id: string_value(scope, "id"),
      thread_id: string_value(scope, "thread_id"),
      resolved_isolation: Atom.to_string(isolation),
      actor_external_account_id: actor_part
    }

    case required_present?(parts) do
      true -> {:ok, parts}
      false -> {:error, :missing_conversation_key_parts}
    end
  end

  defp resolved_isolation(_profile, :ambient), do: :scene
  defp resolved_isolation(%Profile{conversation_isolation_mode: mode}, :addressed), do: mode

  defp actor_part(_actor, :ambient, _isolation), do: ""
  defp actor_part(_actor, :addressed, :scene), do: ""
  defp actor_part(actor, :addressed, :actor), do: string_value(actor, "external_account_id")

  defp required_present?(%{
         lane: lane,
         agent_principal_id: agent_principal_id,
         channel_adapter: channel_adapter,
         channel_id: channel_id,
         scope_id: scope_id,
         resolved_isolation: "actor",
         actor_external_account_id: actor_external_account_id
       }) do
    Enum.all?(
      [
        lane,
        agent_principal_id,
        channel_adapter,
        channel_id,
        scope_id,
        actor_external_account_id
      ],
      &(&1 != "")
    )
  end

  defp required_present?(%{
         lane: lane,
         agent_principal_id: agent_principal_id,
         channel_adapter: channel_adapter,
         channel_id: channel_id,
         scope_id: scope_id
       }) do
    Enum.all?([lane, agent_principal_id, channel_adapter, channel_id, scope_id], &(&1 != ""))
  end

  defp serialize(parts) do
    [
      @prefix,
      encode_part(parts.lane),
      encode_part(parts.agent_principal_id),
      encode_part(parts.channel_adapter),
      encode_part(parts.channel_id),
      encode_part(parts.channel_kind),
      encode_part(parts.scope_id),
      encode_part(parts.thread_id),
      encode_part(parts.resolved_isolation),
      encode_part(parts.actor_external_account_id)
    ]
    |> IO.iodata_to_binary()
  end

  defp encode_part(value) do
    [Integer.to_string(byte_size(value)), ":", value]
  end

  defp reject_nul(parts) do
    parts
    |> Map.values()
    |> Enum.any?(&String.contains?(&1, <<0>>))
    |> case do
      true -> {:error, :conversation_key_part_contains_nul}
      false -> :ok
    end
  end

  defp safe_metadata(parts) do
    %{
      "conversation_key_parts" => %{
        "lane" => parts.lane,
        "channel_adapter" => parts.channel_adapter,
        "channel_id" => parts.channel_id,
        "channel_kind" => parts.channel_kind,
        "scope_id" => parts.scope_id,
        "thread_id" => parts.thread_id,
        "resolved_isolation" => parts.resolved_isolation,
        "actor_external_account_id_present" => parts.actor_external_account_id != ""
      }
    }
  end

  defp map_value(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      %{} = value -> value
      _other -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  defp string_value(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> value
      _other -> ""
    end
  rescue
    ArgumentError -> ""
  end
end
