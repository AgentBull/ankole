defmodule Ankole.Principals.AgentLifecycleTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.Pod.{Access, Pages}
  alias Ankole.Principals

  test "physical Agent deletion removes its local grants and restores minimal Page anchors" do
    owner = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: owner.uid}).principal

    assert {:ok, _} =
             AuthZ.create_permission_grant(%{
               principal_uid: owner.uid,
               resource_pattern: "tenant_console:pod_space",
               action: "update"
             })

    assert {:ok, root} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{title: "Root"})

    assert {:ok, shared} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
               parent_id: root.id,
               title: "Shared"
             })

    assert {:ok, descendant} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
               parent_id: shared.id,
               title: "Child"
             })

    assert {:ok, boundary} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
               parent_id: descendant.id,
               title: "Boundary"
             })

    for uid <- [agent.uid, owner.uid] do
      assert {:ok, _} =
               AuthZ.create_permission_grant(%{
                 principal_uid: uid,
                 resource_pattern: "pod:**:#{boundary.id}:page",
                 action: "page_view"
               })
    end

    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: agent.uid,
               resource_pattern: "pod:**:#{shared.id}:**",
               action: "page_view"
             })

    assert {:ok, %{has_local_acl: true, is_acl_anchor: true, acl_anchor_id: shared_id}} =
             Pages.fetch(shared.id)

    assert shared_id == shared.id
    assert {:ok, %{acl_anchor_id: ^shared_id}} = Pages.fetch(descendant.id)
    assert {:ok, %{parent_anchor_id: ^shared_id}} = Pages.fetch(boundary.id)

    assert {:ok, %{status: :disabled}} = Principals.delete_agent(agent.uid)
    assert {:ok, _} = AuthZ.get_permission_grant(grant.id)
    assert {:ok, %{has_local_acl: true, is_acl_anchor: true}} = Pages.fetch(shared.id)

    assert {:error, :rollback} =
             Repo.transact(fn ->
               assert {:ok, _} = Principals.delete_agent_in_tx(agent.uid)

               assert {:ok, %{has_local_acl: false, is_acl_anchor: false}} =
                        Pages.fetch(shared.id)

               {:error, :rollback}
             end)

    assert {:ok, _} = AuthZ.get_permission_grant(grant.id)
    assert {:ok, %{has_local_acl: true, is_acl_anchor: true}} = Pages.fetch(shared.id)

    assert {:ok, %{status: :disabled}} = Principals.delete_agent(agent.uid)
    assert {:error, :not_found} = Principals.get_agent(agent.uid)
    assert Access.grants(principal_uid: agent.uid) == []
    root_id = root.id

    assert {:ok,
            %{
              has_local_acl: false,
              is_acl_anchor: false,
              acl_anchor_id: ^root_id,
              parent_anchor_id: nil
            }} = Pages.fetch(shared.id)

    assert {:ok, %{acl_anchor_id: ^root_id}} = Pages.fetch(descendant.id)
    boundary_id = boundary.id

    assert {:ok,
            %{
              has_local_acl: true,
              is_acl_anchor: true,
              acl_anchor_id: ^boundary_id,
              parent_anchor_id: ^root_id
            }} = Pages.fetch(boundary.id)

    assert [%{principal_uid: owner_uid}] = Access.page_grants(boundary.id)
    assert owner_uid == owner.uid
  end
end
