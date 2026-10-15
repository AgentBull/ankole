defmodule Ankole.AgentWorkers.TransportTest do
  use Ankole.SessionsCase

  describe "transport and inbound authorization" do
    test "control plane can call a worker RPC method over the RPC lane" do
      route = unique_route()
      :ok = WorkerRoute.register_local_worker(route, self())
      on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)

      probe_payload = encode_proto!(%FabricProto.WorkerEnvResolveRequest{})

      task =
        Task.async(fn ->
          WorkerRoute.request_rpc(
            route,
            "test.probe",
            probe_payload,
            timeout_ms: 200
          )
        end)

      assert_receive {:actor_lane, %FabricProto.Envelope{body: {:rpc_request, request}}}, 200

      assert request.method == "test.probe"
      assert request.payload == probe_payload
      request_id = request.request_id

      WorkerRoute.local_inbound(
        route,
        encode_fabric_envelope(%FabricProto.Envelope{
          message_id: "worker-rpc-response",
          body:
            {:rpc_response,
             %FabricProto.RPCResponse{
               request_id: request_id,
               payload:
                 encode_proto!(%FabricProto.WorkerEnvResolveResponse{
                   vars: %{"runtime" => "bun"}
                 })
             }}
        })
      )

      assert {:ok, payload} = Task.await(task, 500)

      assert {:ok, %FabricProto.WorkerEnvResolveResponse{vars: %{"runtime" => "bun"}}} =
               FabricProto.WorkerEnvResolveResponse.decode(payload)
    end

    # The Worker Channel test checks that this error reaches the Worker over a
    # real connection and that the connection stays open.
    test "a crashing RPC handler becomes an rpc_error with a failure id" do
      %{principal: agent} = agent_fixture()
      config_owner = Ankole.Sessions.AIGatewayAPIKeyBroker
      previous_config = Application.get_env(:ankole, config_owner)
      Application.put_env(:ankole, config_owner, base_url: :invalid_test_value)

      on_exit(fn ->
        case previous_config do
          nil -> Application.delete_env(:ankole, config_owner)
          value -> Application.put_env(:ankole, config_owner, value)
        end
      end)

      request = %FabricProto.RPCRequest{
        request_id: "rpc-handler-crash",
        method: "ai_gateway.api_key_for.create_or_find_by_agent",
        payload: encode_proto!(%FabricProto.AIGatewayAPIKeyRequest{})
      }

      assert {:ok, response} = handle_rpc(request, "worker-route", agent.uid)
      assert envelope_body_type(response) == :rpc_error

      assert %FabricProto.RPCError{
               code: "rpc_handler_failed",
               retryable: false,
               details_json: details_json
             } = envelope_body!(response, :rpc_error)

      assert %{
               "failure_id" => failure_id,
               "method" => "ai_gateway.api_key_for.create_or_find_by_agent"
             } = Torque.decode!(details_json)

      assert {:ok, _failure_id} = Ecto.UUID.cast(failure_id)
    end

    test "only reads and the idempotent Job Turn checkpoint retry handler failures" do
      assert RPCLane.retryable_handler_failure?("background_agent_job.get")
      assert RPCLane.retryable_handler_failure?("background_agent_job.turn.upsert")
      refute RPCLane.retryable_handler_failure?("background_agent_job.status.update")
      refute RPCLane.retryable_handler_failure?("actor_turn.complete")
    end
  end
end
