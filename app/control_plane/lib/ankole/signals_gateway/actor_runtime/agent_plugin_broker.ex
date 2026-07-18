defmodule Ankole.SignalsGateway.ActorRuntime.AgentPluginBroker do
  @moduledoc """
  Exposes the current Agent's trusted, enabled Agent Plugin catalog to worker turns.
  """

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @spec handle_list(TurnRef.t(), FabricProto.AgentPluginListRequest.t(), map()) ::
          {:ok, FabricProto.AgentPluginListResponse.t()} | {:error, map()}
  def handle_list(%TurnRef{} = turn_ref, %FabricProto.AgentPluginListRequest{}, ctx) do
    case AgentPlugins.enabled_catalog_for_agent(turn_ref.agent_uid) do
      {:ok, agent_plugins} ->
        {:ok,
         %FabricProto.AgentPluginListResponse{
           agent_plugins: Enum.map(agent_plugins, &catalog_entry/1)
         }}

      {:error, reason} ->
        {:error,
         RPCWire.error_payload(ctx.request_id, reason,
           fallback_code: "agent_plugin_list_failed",
           message_style: :tuple_inspect,
           details_json: %{"agent_uid" => turn_ref.agent_uid}
         )}
    end
  end

  defp catalog_entry(entry) do
    %FabricProto.AgentPluginCatalogEntry{
      id: entry["id"],
      description: entry["description"],
      version: entry["version"],
      content_hash: entry["content_hash"],
      skills:
        Enum.map(entry["skills"], fn skill ->
          %FabricProto.AgentPluginCatalogSkill{
            catalog_name: skill["catalog_name"],
            codex_name: skill["codex_name"]
          }
        end)
    }
  end
end
