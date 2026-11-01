defmodule Ankole.AuthZ.PodContractTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  alias Ankole.{AuthZ, Principals}
  alias Ankole.AuthZ.{Grant, Snapshot}
  alias Ankole.Pod.{Page, Pages}

  test "one statement loads membership, static groups, computed groups, and Userset grants",
       ctx do
    owner = human_fixture().principal
    {:ok, first} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{})
    {:ok, target} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{})

    {:ok, group} =
      AuthZ.create_principal_group(%{name: unique_uid("snapshot"), display_name: "Snapshot"})

    {:ok, _} = AuthZ.add_principal_to_group(owner.uid, group.id)

    {:ok, userset} =
      AuthZ.create_permission_grant(%{
        source_node_id: first.id,
        source_action: "node_view",
        resource_pattern: "drive:**:#{target.id}:node",
        action: "node_view",
        condition: ~s(context.request.ip == "10.0.0.1")
      })

    {:ok, direct} =
      AuthZ.create_permission_grant(%{
        group_id: group.id,
        resource_pattern: "tenant_console:**",
        action: "update"
      })

    handler = "snapshot-query-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, pid -> send(pid, {:query, metadata.query}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, snapshot} = Snapshot.build_drive_context_snapshot(owner.uid, %{ip: "10.0.0.1"})
    assert snapshot["principal"]["membership"] == "member"
    assert group.id in snapshot["staticGroupIDs"]
    assert snapshot["computedGroups"] != []
    assert Enum.find(snapshot["grants"], &(&1["id"] == userset.id))["hasSourceNode"]
    assert Enum.find(snapshot["grants"], &(&1["id"] == direct.id))["condition"] == "true"
    assert_receive {:query, sql}
    assert sql =~ "WITH execution"
    assert_receive {:query, conversations_sql}
    assert conversations_sql =~ "conversation_participants"
    refute_receive {:query, _}
    :telemetry.detach(handler)

    assert {:ok, ordinary} =
             Snapshot.build_authorization_snapshot(
               owner.uid,
               "tenant_console:drive_space",
               "update"
             )

    refute Enum.any?(ordinary["grants"], & &1["hasSourceNode"])

    foreign = create_tenant()

    assert Repo.with_tenant(foreign.id, fn -> Snapshot.build_drive_context_snapshot(owner.uid) end) ==
             {:error, :not_found}

    assert Repo.tenant_id!() == ctx.tenant.id
  end

  test "invalid stored Pod conditions deny access and emit the AuthZ diagnostic" do
    owner = human_fixture().principal
    viewer = human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        private_owner_uid: owner.uid
      })

    {:ok, grant} =
      AuthZ.create_permission_grant(%{
        principal_uid: viewer.uid,
        resource_pattern: "drive:**:#{page.id}:node",
        action: "node_view"
      })

    assert {:ok, _} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
               page.id,
               "node_view"
             )

    Repo.update_all(from(g in Grant, where: g.id == ^grant.id),
      set: [condition: ~s(resource == "drive:space")]
    )

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :authz, :invalid_persisted_data],
        fn _, _, diagnostic, pid -> send(pid, {:diagnostic, diagnostic}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
               page.id,
               "node_view"
             )

    id = grant.id
    assert_receive {:diagnostic, %{id: ^id, kind: "condition_variables"}}
  end

  test "canonical Grant targets follow create, retarget, and delete through anchor maintenance" do
    owner = human_fixture().principal
    {:ok, root} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{})

    {:ok, first} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{parent_id: root.id})

    {:ok, second} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{parent_id: root.id})

    refute Repo.get!(Page, first.id).has_local_acl

    {:ok, grant} =
      AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "drive:**:#{first.id}:node",
        action: "node_view"
      })

    assert {grant.target_node_id, grant.target_scope} == {first.id, "self"}
    assert Repo.get!(Page, first.id).has_local_acl

    {:ok, updated} =
      AuthZ.update_permission_grant(grant, %{resource_pattern: "drive:**:#{second.id}:**"})

    assert {updated.target_node_id, updated.target_scope} == {second.id, "container"}
    refute Repo.get!(Page, first.id).has_local_acl
    assert Repo.get!(Page, second.id).has_local_acl
    {:ok, _} = AuthZ.delete_permission_grant(updated.id)
    refute Repo.get!(Page, second.id).has_local_acl
    assert Repo.get!(Page, second.id).acl_anchor_id == root.acl_anchor_id
  end

  test "Pod grants reject resource-dependent CEL, malformed targets, and bare global wildcards" do
    owner = human_fixture().principal
    {:ok, root} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{})

    for attrs <- [
          %{resource_pattern: "**", action: "read"},
          %{resource_pattern: "drive:anything", action: "node_view"},
          %{
            resource_pattern: "drive:**:#{root.id}:node",
            action: "node_view",
            target_scope: "container"
          },
          %{
            resource_pattern: "drive:space:**",
            action: "node_view",
            condition: ~s(resource == "drive:space")
          }
        ] do
      assert {:error, _} =
               AuthZ.create_permission_grant(Map.put(attrs, :principal_uid, owner.uid))
    end
  end

  test "guest admission, sharing, default membership, and explicit transitions obey their owners" do
    member = human_fixture().principal
    guest_fixture = human_fixture(%{membership: :guest})
    guest = guest_fixture.principal
    {:ok, root} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(member.uid), %{})
    {:ok, group} = AuthZ.Root.ensure_site_admin_group()
    assert {:error, :guest_cannot_be_admin} = AuthZ.add_principal_to_group(guest.uid, group.id)
    assert {:ok, groups} = AuthZ.list_current_groups_for_principal(guest.uid)
    refute Enum.any?(groups, &(&1.name == "all_humans"))
    assert {:ok, promoted} = Principals.change_human_membership(guest.uid, :member)
    assert promoted.access_version == guest.access_version + 1
    assert {:ok, unchanged} = Principals.change_human_membership(guest.uid, :member)
    assert unchanged.access_version == promoted.access_version
    assert {:ok, demoted} = Principals.change_human_membership(guest.uid, :guest)
    assert demoted.access_version == promoted.access_version + 1

    assert {:ok, _} =
             Ankole.PrincipalsFixtures.create_external_identity(%{
               principal_uid: guest.uid,
               provider: "guest-jit",
               external_id: "external-guest"
             })

    assert {:ok, admitted} =
             Principals.upsert_platform_subject_human(%{
               provider: "guest-jit",
               external_id: "external-guest",
               email: guest_fixture.human_user.email,
               membership: :member,
               display_name: "Guest from IdP"
             })

    assert admitted.principal.uid == guest.uid
    assert admitted.principal.membership == :guest
    assert admitted.principal.access_version == demoted.access_version

    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.allow_external_guests", false)

    assert {:error, :external_guests_disabled} =
             Principals.create_human(%{membership: :guest, display_name: "Blocked"})

    assert {:error, :external_guests_disabled} =
             AuthZ.create_permission_grant(%{
               principal_uid: guest.uid,
               resource_pattern: "drive:**:#{root.id}:node",
               action: "node_view"
             })

    assert {:ok, private_root} = Ankole.Files.private_root(guest.uid)

    assert {:error, :forbidden} =
             Ankole.Files.Nodes.authorize(actor_fixture(demoted), private_root.id, "node_view")

    refute Repo.exists?(
             from g in Grant,
               where: g.principal_uid == ^guest.uid and not is_nil(g.target_node_id)
           )
  end

  test "Guest creation and membership actions use the production Principal contract" do
    assert {:ok, guest} =
             Ankole.Ash.run_action(Principals.Principal, :create_member, %{
               email: "invited-guest@example.com",
               membership: :guest,
               display_name: "Invited guest"
             })

    assert {:ok, guest} = Principals.get_principal(guest.uid)
    assert guest.membership == :guest

    assert {:ok, member} =
             Ankole.Ash.run_action(Principals.Principal, :change_human_membership, %{
               uid: guest.uid,
               membership: :member
             })

    assert member.access_version == guest.access_version + 1
    {:ok, admin_group} = AuthZ.Root.ensure_site_admin_group()
    {:ok, _} = AuthZ.add_principal_to_group(member.uid, admin_group.id)

    assert {:error, :admin_cannot_be_guest} =
             Principals.change_human_membership(member.uid, :guest)
  end

  test "wildcard console updates take the Pod tree lock" do
    for pattern <- ["tenant_console:**", "tenant_console:drive_*", "tenant_console:*"] do
      assert Ankole.AuthZ.Grants.grant_affects_pod?(%{
               resource_pattern: pattern,
               action: "update"
             })
    end

    refute Ankole.AuthZ.Grants.grant_affects_pod?(%{
             resource_pattern: "tenant_console:agents",
             action: "update"
           })

    refute Ankole.AuthZ.Grants.grant_affects_pod?(%{
             resource_pattern: "tenant_console:**",
             action: "read"
           })
  end
end
