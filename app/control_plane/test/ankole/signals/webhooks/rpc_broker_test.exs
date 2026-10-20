defmodule Ankole.Signals.Webhooks.RPCBrokerTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.RuntimeFabric.V1, as: FabricProto

  alias Ankole.Sessions.RunRef
  alias Ankole.Signals.Webhooks.RPCBroker

  test "create returns the capability once and list and cancel stay inside the turn session" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    turn_ref = turn_ref(source)
    expires_at = DateTime.add(DateTime.utc_now(:second), 1, :day)

    request = %FabricProto.WebhookEndpointCreateRequest{
      label: "Watch GitHub issues",
      mode: "standing",
      expires_at: DateTime.to_iso8601(expires_at)
    }

    for id <- ["999", "01000", "+1000", "9007199254740992"] do
      assert {:error, %{"code" => "invalid_positive_integer"}} =
               RPCBroker.handle_create(
                 turn_ref,
                 %{request | automation_job_id: id},
                 rpc_ctx("invalid-id")
               )
    end

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

    endpoint = Ankole.Repo.get!(Ankole.Signals.WebhookEndpoint, endpoint_id)
    assert endpoint.binding_name == source.reply_binding_name
    assert endpoint.conversation_id == source.conversation_id
    assert endpoint.provider_thread_id == source.provider_thread_id
    assert endpoint.provider_message_id == source.provider_message_id
    assert callback_url =~ ~r|/webhooks/v1/event-callbacks/wh_[A-Za-z0-9_-]{43}\z|

    assert {:ok,
            %{
              "status" => "created",
              "webhook_endpoint" => %{
                "id" => second_id,
                "url" => second_url
              }
            }} = RPCBroker.handle_create(turn_ref, request, rpc_ctx("create-1"))

    refute second_id == endpoint_id
    refute second_url == callback_url

    assert {:ok,
            %{
              "status" => "ok",
              "webhook_endpoints" => listed
            }} =
             RPCBroker.handle_list(
               turn_ref,
               %FabricProto.WebhookEndpointListRequest{limit: 10},
               rpc_ctx("list-1")
             )

    assert MapSet.new(listed, & &1["id"]) == MapSet.new([endpoint_id, second_id])

    for endpoint <- listed,
        field <- ["url", "token", "token_digest"],
        do: refute(Map.has_key?(endpoint, field))

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

  defp source_event!(agent_uid) do
    Ankole.SignalsFixtures.external_session_signal_fixture(agent_uid,
      binding_name: "github",
      source: "test://webhook-source"
    )
  end

  defp turn_ref(source) do
    %RunRef{
      agent_uid: source.agent_uid,
      session_id: source.session_id,
      signal_id: source.id
    }
  end

  defp rpc_ctx(request_id), do: %{route: "worker-route", request_id: request_id}
end
