defmodule Ankole.SignalsGateway.ActorRuntime.AgentPluginBroker do
  @moduledoc """
  Exposes the current Agent's trusted, enabled Agent Plugin catalog to worker turns.
  """

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @spec handle_list(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_list(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id =
      RPCWire.text(request, "request_id", trim: false) ||
        "agent-plugin-list-#{Ecto.UUID.generate()}"

    case AgentPlugins.enabled_catalog_for_agent(turn_ref.agent_uid) do
      {:ok, agent_plugins} ->
        {:ok,
         %{
           "request_id" => request_id,
           "agent_uid" => turn_ref.agent_uid,
           "agent_plugins" => agent_plugins
         }}

      {:error, reason} ->
        {:error,
         RPCWire.error_payload(request_id, reason,
           fallback_code: "agent_plugin_list_failed",
           message_style: :tuple_inspect,
           details_json: %{"agent_uid" => turn_ref.agent_uid}
         )}
    end
  end
end
