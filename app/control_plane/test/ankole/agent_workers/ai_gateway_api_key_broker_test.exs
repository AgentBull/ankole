defmodule Ankole.AgentWorkers.AIGatewayAPIKeyBrokerTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Sessions.AIGatewayAPIKeyBroker
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.ReconcileJob
  alias Ankole.AgentWorkers.AgentWorker

  setup do
    Ankole.AgentWorkerDockerHTTP.install()
    :ok
  end

  test "uses the Agent's provider address and preserves its token scope" do
    %{principal: agent} = agent_fixture()
    worker = Repo.get_by!(AgentWorker, agent_uid: agent.uid)

    assert {:ok, _} =
             Providers.update(worker.provider_id, %{
               config:
                 "network: bridge\nendpoints:\n  aiGatewayUrl: https://gateway.example.test/api/v1/ai-gateway/\n"
             })

    assert :ok = Ankole.AgentWorkers.request(agent.uid)
    assert :ok = perform_job(ReconcileJob, %{"agent_uid" => agent.uid})
    assert {:ok, response} = request(agent.uid)
    assert response.base_url == "https://gateway.example.test/api/v1/ai-gateway"

    assert {:ok, claims} =
             Attesto.Token.verify(Ankole.OIDC.Config.get("ankole.ai_gateway"), response.api_key)

    assert claims["sub"] == agent.uid
    assert claims["scope"] == "ai_gateway"
  end

  test "uses the node address only when the provider does not set one" do
    %{principal: agent} = agent_fixture()
    assert :ok = Ankole.AgentWorkers.request(agent.uid)
    assert :ok = perform_job(ReconcileJob, %{"agent_uid" => agent.uid})
    assert {:ok, response} = request(agent.uid)
    configured = Application.get_env(:ankole, AIGatewayAPIKeyBroker, [])[:base_url]

    assert response.base_url ==
             String.trim_trailing(
               configured || AnkoleWeb.Endpoint.url() <> "/api/v1/ai-gateway",
               "/"
             )
  end

  defp request(agent_uid),
    do:
      AIGatewayAPIKeyBroker.handle_request(agent_uid, %FabricProto.AIGatewayAPIKeyRequest{}, %{
        request_id: "provider-endpoint"
      })
end
