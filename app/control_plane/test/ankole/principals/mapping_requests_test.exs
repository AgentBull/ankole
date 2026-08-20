defmodule Ankole.Principals.MappingRequestsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Principals
  alias Ankole.Principals.MappingRequest
  alias Ankole.Principals.MappingRequests

  test "record_observation converges on one row and keeps earlier hints" do
    assert {:ok, first} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_pending",
               display_name: "Ada",
               email: "ada@example.com",
               metadata: %{"binding_name" => "lark"}
             })

    assert {:ok, second} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_pending",
               metadata: %{"channel_name" => "Ops"}
             })

    assert second.id == first.id
    assert second.display_name == "Ada"
    assert second.email == "ada@example.com"
    assert second.metadata["binding_name"] == "lark"
    assert second.metadata["channel_name"] == "Ops"
    assert [_only] = MappingRequests.list_requests()
  end

  test "bind_request writes the identity to the chosen principal and removes the row" do
    %{principal: principal} = human_fixture()

    assert {:ok, request} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_bind_me",
               display_name: "Bindable"
             })

    assert {:ok, %{identity: identity}} = MappingRequests.bind_request(request.id, principal.uid)
    assert identity.principal_uid == principal.uid
    assert identity.metadata["origin"] == "manual"

    assert {:ok, resolved} = Principals.resolve_platform_subject("lark-main", "ou_bind_me")
    assert resolved.uid == principal.uid
    assert MappingRequests.list_requests() == []
  end

  test "bind_request refuses agents and disabled principals" do
    %{principal: agent} = agent_fixture()
    %{principal: disabled} = human_fixture()
    assert {:ok, _principal} = Principals.disable_principal(disabled.uid)

    assert {:ok, request} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_refused"
             })

    assert {:error, :not_human} = MappingRequests.bind_request(request.id, agent.uid)
    assert {:error, :principal_disabled} = MappingRequests.bind_request(request.id, disabled.uid)
    assert [_still_pending] = MappingRequests.list_requests()
  end

  test "bind_subject maps a subject proactively and clears any pending row" do
    %{principal: principal} = human_fixture()

    assert {:ok, _request} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_proactive"
             })

    assert {:ok, identity} =
             MappingRequests.bind_subject(principal.uid, %{
               provider: "lark-main",
               external_id: "ou_proactive"
             })

    assert identity.principal_uid == principal.uid
    assert MappingRequests.list_requests() == []

    assert {:ok, resolved} = Principals.resolve_platform_subject("lark-main", "ou_proactive")
    assert resolved.uid == principal.uid
  end

  test "delete_request drops the row without binding" do
    assert {:ok, request} =
             MappingRequests.record_observation(%{
               provider: "lark-main",
               external_id: "ou_dismissed"
             })

    assert {:ok, %MappingRequest{}} = MappingRequests.delete_request(request.id)
    assert MappingRequests.list_requests() == []
    assert {:error, :not_found} = MappingRequests.delete_request(request.id)
  end
end
