defmodule Ankole.AIGateway.CredentialTest do
  use Ankole.AIGatewayCase

  import Ankole.SignalsGateway.ActorRuntimeCase,
    only: [
      rpc_request: 3,
      rpc_request: 4,
      rpc_response_payload!: 2,
      rpc_error_payload!: 1,
      envelope_body_type: 1,
      envelope_body!: 2
    ]

  alias Ankole.RuntimeFabric.V1, as: FabricProto

  test "agent API key JWT carries the AIGateway audience, scope, subject, and 30 day expiry" do
    %{principal: agent} = agent_fixture()

    assert {:ok, api_key} = Tokens.mint_for_agent(agent.uid)
    assert api_key.scope == "ai_gateway"
    assert api_key.token_type == "Bearer"
    assert api_key.expires_in == 30 * 24 * 60 * 60

    assert {:ok, claims} = Tokens.verify_api_key(api_key.api_key)
    assert claims["aud"] == "ankole.ai_gateway"
    assert claims["scope"] == "ai_gateway"
    assert claims["sub"] == agent.uid
    assert claims["subject_type"] == "agent"
    assert claims["token_use"] == "api_key"
    assert claims["exp"] == api_key.expires_at
  end

  test "RuntimeFabric RPC returns an agent AIGateway API key from explicit agent uid" do
    %{principal: agent} = agent_fixture()

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "ai-gateway-key-1",
                 "ai_gateway.api_key_for.create_or_find_by_agent",
                 %FabricProto.AIGatewayAPIKeyRequest{},
                 agent_uid: agent.uid
               ),
               "trusted-worker-route"
             )

    response = rpc_response_payload!(envelope, FabricProto.AIGatewayAPIKeyResponse)
    assert envelope_body!(envelope, :rpc_response).request_id == "ai-gateway-key-1"
    assert response.agent_uid == agent.uid
    assert response.token_type == "Bearer"
    assert response.scope == "ai_gateway"
    assert response.expires_in == 30 * 24 * 60 * 60
    assert String.ends_with?(response.base_url, "/api/v1/ai-gateway")
    assert {:ok, claims} = Tokens.verify_api_key(response.api_key)
    assert claims["sub"] == agent.uid
  end

  test "RuntimeFabric RPC returns the configured AIGateway base URL" do
    put_ai_gateway_broker_env!(base_url: "https://gateway.example.test/api/v1/ai-gateway/")

    %{principal: agent} = agent_fixture()

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "ai-gateway-worker-url",
                 "ai_gateway.api_key_for.create_or_find_by_agent",
                 %FabricProto.AIGatewayAPIKeyRequest{},
                 agent_uid: agent.uid
               ),
               "trusted-worker-route"
             )

    response = rpc_response_payload!(envelope, FabricProto.AIGatewayAPIKeyResponse)

    assert response.base_url ==
             "https://gateway.example.test/api/v1/ai-gateway"
  end

  test "RuntimeFabric RPC requires the agent uid for an agent-scoped AIGateway API key" do
    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "missing-agent-uid",
                 "ai_gateway.api_key_for.create_or_find_by_agent",
                 %FabricProto.AIGatewayAPIKeyRequest{}
               ),
               "trusted-worker-route"
             )

    assert envelope_body_type(envelope) == :rpc_error
    assert envelope_body!(envelope, :rpc_error).code == "missing_agent_uid"

    assert rpc_error_payload!(envelope)["details_json"] == %{
             "agent_uid" => "",
             "retryable" => false
           }
  end

  test "RuntimeFabric rejects RPC methods outside the declared contract" do
    %{principal: agent} = agent_fixture()
    {route, turn} = assign_worker_route(agent.uid, "signal-channel:no-provider-secret-rpc")

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "unknown-method-rpc",
                 "definitely.not_a_declared_method",
                 %FabricProto.AIGatewayAPIKeyRequest{},
                 turn: turn,
                 agent_uid: agent.uid
               ),
               route
             )

    assert envelope_body_type(envelope) == :rpc_error
    assert envelope_body!(envelope, :rpc_error).code == "unknown_rpc_method"
  end

  defp put_ai_gateway_broker_env!(config) do
    old_env =
      Application.fetch_env(:ankole, Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker)

    Application.put_env(:ankole, Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker, config)

    on_exit(fn ->
      case old_env do
        {:ok, value} ->
          Application.put_env(
            :ankole,
            Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker,
            value
          )

        :error ->
          Application.delete_env(
            :ankole,
            Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker
          )
      end
    end)
  end
end
