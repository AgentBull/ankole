defmodule Ankole.AIGateway.CredentialTest do
  use Ankole.AIGatewayCase

  test "agent API key JWT carries the AIGateway audience, scope, subject, and 30 day expiry" do
    %{principal: agent} = agent_fixture()

    assert {:ok, api_key} = AIGatewayTokens.mint_for_agent(agent.uid)
    assert api_key.scope == "ai_gateway"
    assert api_key.token_type == "Bearer"
    assert api_key.expires_in == 30 * 24 * 60 * 60

    assert {:ok, claims} = AIGatewayTokens.verify_api_key(api_key.api_key)
    assert claims["aud"] == "ankole.ai_gateway"
    assert claims["scope"] == "ai_gateway"
    assert claims["sub"] == agent.uid
    assert claims["subject_type"] == "agent"
    assert claims["token_use"] == "api_key"
    assert claims["exp"] == api_key.expires_at
  end

  test "RuntimeFabric RPC returns an agent AIGateway API key and no provider credential" do
    %{principal: agent} = agent_fixture()
    session_id = "signal-channel:ai-gateway-rpc"
    {route, turn} = assign_worker_route(agent.uid, session_id)

    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "ai-gateway-key-1",
                 "method" => "ai_gateway.api_key_for.create_or_find_by_agent",
                 "payload_json" => %{
                   "request_id" => "ai-gateway-key-1",
                   "turn" => turn,
                   "agent_uid" => agent.uid,
                   "session_id" => session_id
                 }
               },
               route
             )

    response = get_in(envelope, ["body", "rpc_response", "payload_json"])
    assert response["request_id"] == "ai-gateway-key-1"
    assert response["agent_uid"] == agent.uid
    assert response["session_id"] == session_id
    assert response["token_type"] == "Bearer"
    assert response["scope"] == "ai_gateway"
    assert response["expires_in"] == 30 * 24 * 60 * 60
    assert String.ends_with?(response["base_url"], "/api/v1/ai-gateway")
    refute Map.has_key?(response, "credential")
    refute Map.has_key?(response, "provider_id")
    assert {:ok, claims} = AIGatewayTokens.verify_api_key(response["api_key"])
    assert claims["sub"] == agent.uid
  end

  test "RuntimeFabric RPC returns the configured worker-facing AIGateway base URL" do
    put_ai_gateway_broker_env!(
      worker_facing_base_url: "http://host.docker.internal:49321/api/v1/ai-gateway/"
    )

    %{principal: agent} = agent_fixture()
    session_id = "signal-channel:ai-gateway-worker-url"
    {route, turn} = assign_worker_route(agent.uid, session_id)

    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "ai-gateway-worker-url",
                 "method" => "ai_gateway.api_key_for.create_or_find_by_agent",
                 "payload_json" => %{
                   "request_id" => "ai-gateway-worker-url",
                   "turn" => turn,
                   "agent_uid" => agent.uid,
                   "session_id" => session_id
                 }
               },
               route
             )

    response = get_in(envelope, ["body", "rpc_response", "payload_json"])

    assert response["base_url"] ==
             "http://host.docker.internal:49321/api/v1/ai-gateway"
  end

  test "RuntimeFabric no longer exposes provider credential resolution as a public RPC" do
    %{principal: agent} = agent_fixture()
    {route, turn} = assign_worker_route(agent.uid, "signal-channel:no-provider-secret-rpc")

    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "old-credential-rpc",
                 "method" => "ai_gateway_provider.resolve_credential",
                 "payload_json" => %{
                   "turn" => turn,
                   "agent_uid" => agent.uid,
                   "session_id" => "signal-channel:no-provider-secret-rpc",
                   "profile" => "primary",
                   "purpose" => "ai_turn"
                 }
               },
               route
             )

    assert get_in(envelope, ["body", "type"]) == "rpc_error"
    assert get_in(envelope, ["body", "rpc_error", "code"]) == "unknown_rpc_method"
  end

  defp put_ai_gateway_broker_env!(config) do
    old_env = Application.fetch_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker)
    Application.put_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker, config)

    on_exit(fn ->
      case old_env do
        {:ok, value} ->
          Application.put_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker, value)

        :error ->
          Application.delete_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker)
      end
    end)
  end
end
