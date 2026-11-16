defmodule Ankole.Principals.AgentLifecycleTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.Pod.Pages
  alias Ankole.Pod.Access
  alias Ankole.Principals

  test "physical Agent deletion removes its local grants and restores minimal Page anchors" do
    owner = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: owner.uid}).principal

    assert {:ok, _} =
             AuthZ.create_permission_grant(%{
               principal_uid: owner.uid,
               resource_pattern: "tenant_console:drive_space",
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
                 resource_pattern: "drive:**:#{boundary.id}:node",
                 action: "node_view"
               })
    end

    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: agent.uid,
               resource_pattern: "drive:**:#{shared.id}:**",
               action: "node_view"
             })

    assert {:ok, %{has_local_acl: true, is_acl_anchor: true, acl_anchor_id: shared_id}} =
             Pages.fetch(shared.id)

    assert shared_id == shared.id
    assert {:ok, %{acl_anchor_id: ^shared_id}} = Pages.fetch(descendant.id)
    assert {:ok, %{parent_anchor_id: ^shared_id}} = Pages.fetch(boundary.id)

    agent_actor = actor_fixture(agent)
    assert {:ok, private_root} = Ankole.Pod.private_root(agent.uid)

    assert {:ok, private_page} =
             Pages.create(agent_actor, %{private_owner_uid: agent.uid, title: "Owned"})

    assert {:ok, applet} =
             Pages.create(agent_actor, %{parent_id: private_root.id, type: "applet"})

    Ankole.FilesFixtures.publish_applet_fixture(
      %{actor: agent_actor, page: applet},
      "export default {actions:{work:{handler:()=>true}}}"
    )

    assert {:ok, job} =
             Ankole.AutomationJobs.create_applet_job(agent_actor, applet.id, "work", %{
               authorization_kind: "service"
             })

    assert {:ok, _} =
             Ankole.Signals.put_event_binding(agent_actor, %{
               config_ref: "applet://#{applet.id}",
               automation_job_id: job.id
             })

    assert {:ok, _} =
             Ankole.Signals.emit("applet://#{applet.id}", %{
               id: "private-event",
               type: "test.changed"
             })

    assert {:ok, %{status: :disabled}} = Principals.delete_agent(agent.uid)
    assert {:ok, _} = Pages.fetch(private_page.id)
    assert {:ok, _} = Ankole.Pod.fetch_node(private_root.id)
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
    assert {:ok, nil} = Ankole.AutomationJobs.get_automation_job(job.id)
    assert Repo.aggregate(Ankole.AutomationJobs.Schemas.Run, :count) == 0
    assert Repo.aggregate(Ankole.Signals.Binding, :count) == 0
    assert {:error, :not_found} = Pages.fetch(private_page.id)
    assert {:error, :not_found} = Ankole.Pod.fetch_node(private_root.id)
    assert Access.grants(principal_uid: agent.uid) == []
    root_id = root.acl_anchor_id

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

  test "deleting an agent releases owner_uid on Applet Pages instead of failing foreign-key constraints" do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    human_actor = actor_fixture(human.uid)
    agent_actor = actor_fixture(agent.uid)

    {:ok, root} = Pages.create(human_actor, %{type: "doc", title: "Workspace Root"})

    for action <- ["node_view", "node_contribute", "node_edit"] do
      {:ok, _} =
        AuthZ.create_permission_grant(%{
          principal_uid: agent.uid,
          resource_pattern: "drive:**:#{root.id}:**",
          action: action
        })
    end

    {:ok, applet} =
      Pages.create(agent_actor, %{
        type: "applet",
        title: "Ops Dashboard",
        parent_id: root.id
      })

    assert Repo.get_by!(Ankole.Pod.Page, id: applet.id).owner_uid == agent.uid

    assert {:ok, %{status: :disabled}} = Principals.Agents.delete_agent(agent.uid)
    assert {:ok, _deleted} = Principals.Agents.delete_agent(agent.uid)

    reloaded = Repo.get_by!(Ankole.Pod.Page, id: applet.id)
    assert reloaded.owner_uid == nil
    assert reloaded.deleted_at == nil
  end
end
