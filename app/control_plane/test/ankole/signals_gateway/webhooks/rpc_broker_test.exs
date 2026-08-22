defmodule Ankole.SignalsGateway.Webhooks.RPCBrokerTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.Webhooks.RPCBroker

  @token "wh_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"

  test "create returns the capability once and list and cancel stay inside the turn session" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    turn_ref = turn_ref(source)
    expires_at = DateTime.add(DateTime.utc_now(:second), 1, :day)

    request = %FabricProto.WebhookEndpointCreateRequest{
      token: @token,
      label: "Watch GitHub issues",
      mode: "standing",
      expires_at: DateTime.to_iso8601(expires_at),
      reply_route_json: Torque.encode!(reply_route(source))
    }

    assert {:ok,
            %{
              "status" => "created",
              "webhook_endpoint" => %{
                "id" => endpoint_id,
                "url" => callback_url,
                "mode" => "standing",
                "status" => "active"
              }
            }} = RPCBroker.handle_create(turn_ref, request, rpc_ctx("create-1"))

    assert String.ends_with?(callback_url, "/webhooks/v1/event-callbacks/" <> @token)

    assert {:ok,
            %{
              "status" => "already_exists",
              "webhook_endpoint" => %{
                "id" => ^endpoint_id,
                "url" => ^callback_url
              }
            }} = RPCBroker.handle_create(turn_ref, request, rpc_ctx("create-1"))

    assert {:ok,
            %{
              "status" => "ok",
              "webhook_endpoints" => [%{"id" => ^endpoint_id} = listed]
            }} =
             RPCBroker.handle_list(
               turn_ref,
               %FabricProto.WebhookEndpointListRequest{limit: 10},
               rpc_ctx("list-1")
             )

    refute Map.has_key?(listed, "url")
    refute Map.has_key?(listed, "token")
    refute Map.has_key?(listed, "token_digest")

    other_session = %{turn_ref | session_id: "another-session"}

    assert {:error, %{"code" => "webhook_endpoint_not_found"}} =
             RPCBroker.handle_cancel(
               other_session,
               %FabricProto.WebhookEndpointTargetRequest{webhook_endpoint_id: endpoint_id},
               rpc_ctx("cancel-other")
             )

    assert {:ok,
            %{
              "status" => "cancelled",
              "webhook_endpoint" => %{"id" => ^endpoint_id, "status" => "cancelled"} = cancelled
            }} =
             RPCBroker.handle_cancel(
               turn_ref,
               %FabricProto.WebhookEndpointTargetRequest{webhook_endpoint_id: endpoint_id},
               rpc_ctx("cancel-1")
             )

    refute Map.has_key?(cancelled, "url")
  end

  test "create rejects a route that is not the current durable ActorEvent route" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)

    request = %FabricProto.WebhookEndpointCreateRequest{
      token: @token,
      label: "Wrong route",
      mode: "one_shot",
      expires_at:
        DateTime.utc_now(:microsecond) |> DateTime.add(1, :day) |> DateTime.to_iso8601(),
      reply_route_json:
        source
        |> reply_route()
        |> Map.put("source_entry_id", "not-current-entry")
        |> Torque.encode!()
    }

    assert {:error, %{"code" => "reply_route_not_in_turn"}} =
             RPCBroker.handle_create(turn_ref(source), request, rpc_ctx("create-wrong-route"))
  end

  defp source_event!(agent_uid) do
    unique = System.unique_integer([:positive])

    {:ok, event} =
      SignalsGateway.append_actor_event(%{
        agent_uid: agent_uid,
        binding_name: "github",
        session_id: "conversation-#{unique}",
        source_event_id: "source-#{unique}",
        signal_channel_id: "github:repo:ankole-#{unique}",
        provider_thread_id: "issue:42",
        source_entry_id: "comment:7",
        type: "im.message.addressed",
        available_at: DateTime.utc_now(:microsecond),
        sender_key: nil,
        payload: %{
          "specversion" => "1.0",
          "id" => "source-#{unique}",
          "source" => "test://webhook-rpc",
          "type" => "im.message.addressed",
          "data" => %{}
        }
      })

    event
  end

  defp turn_ref(source) do
    %TurnRef{
      agent_uid: source.agent_uid,
      session_id: source.session_id,
      activation_uid: "webhook-rpc-test",
      actor_epoch: 1,
      actor_event_id: source.id,
      revision: 0
    }
  end

  defp reply_route(source) do
    %{
      "binding_name" => source.binding_name,
      "signal_channel_id" => source.signal_channel_id,
      "provider_thread_id" => source.provider_thread_id,
      "source_entry_id" => source.source_entry_id
    }
  end

  defp rpc_ctx(request_id), do: %{route: "worker-route", request_id: request_id}
end
