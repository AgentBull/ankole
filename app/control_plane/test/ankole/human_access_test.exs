defmodule Ankole.HumanAccessTest do
  # This module exercises the site-wide privileged-tenant setting.
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{AuthZ, Principals}
  alias Ankole.Principals.HumanAccess
  alias Ankole.Pod.Pages

  test "restoration clears eligible restrictions without reviving old access" do
    %{principal: human} = human_fixture()
    assert :ok = HumanAccess.check(human.uid, human.access_version)
    assert {:ok, disabled} = HumanAccess.disable(human.uid, "manual review", nil, "manual-1")
    assert disabled.access_version == human.access_version + 1
    assert {:ok, same} = HumanAccess.disable(human.uid, "manual review", nil, "manual-1")
    assert same.access_version == disabled.access_version
    assert length(HumanAccess.history(human.uid)) == 1
    assert {:ok, _} = HumanAccess.restrict_from_provider(human.uid, "lark", "departed", "event-1")

    restrictions = HumanAccess.restrictions(human.uid)
    manual = Enum.find(restrictions, &(&1.source == "manual"))
    provider = Enum.find(restrictions, &(&1.source == "provider:lark"))

    assert {:error, :provider_recovery_not_verified} =
             HumanAccess.clear_restriction(human.uid, provider.id, nil, "reviewed", "clear-1")

    assert {:ok, _} =
             HumanAccess.clear_restriction(human.uid, manual.id, nil, "reviewed", "clear-2")

    assert {:error, :provider_recovery_not_verified} =
             HumanAccess.restore(human.uid, nil, "reviewed", "restore-1")

    alias Ankole.IdentityProviders.DirectoryAccess
    assert {:ok, ticket} = DirectoryAccess.begin_sync("lark")

    assert {:ok, _} =
             DirectoryAccess.finish_sync(ticket, "scope", [{human.uid, :healthy}],
               admission_scope: "none",
               maximum_removal_percent: 20
             )

    assert {:ok, restored} =
             HumanAccess.restore(human.uid, nil, "reviewed", "restore-1")

    assert restored.status == :active
    assert {:error, :human_access_revoked} = HumanAccess.check(human.uid, human.access_version)
    assert :ok = HumanAccess.check(human.uid, restored.access_version)
    assert {:error, :human_access_revoked} = HumanAccess.check(human.uid, nil)
  end

  test "restoration applies current grants and Usersets without a permission approval" do
    owner = human_fixture().principal
    human = human_fixture().principal
    actor = actor_fixture(owner.uid)
    assert {:ok, source} = Pages.create(actor, %{private_owner_uid: owner.uid})
    assert {:ok, target} = Pages.create(actor, %{private_owner_uid: owner.uid})
    assert {:ok, _} = HumanAccess.disable(human.uid, "review", nil, "disable")

    assert {:ok, _} =
             AuthZ.create_permission_grant(%{
               principal_uid: human.uid,
               resource_pattern: "drive:**:#{source.id}:**",
               target_node_id: source.id,
               target_scope: "container",
               action: "node_view"
             })

    assert {:ok, _} =
             AuthZ.create_permission_grant(%{
               source_node_id: source.id,
               source_action: "node_view",
               resource_pattern: "drive:**:#{target.id}:**",
               target_node_id: target.id,
               target_scope: "container",
               action: "node_view"
             })

    assert {:ok, %{status: :active}} =
             HumanAccess.restore(
               human.uid,
               Ankole.ActorRef.from_actor(actor),
               "return",
               "restore"
             )

    assert Enum.all?(HumanAccess.restrictions(human.uid), &is_struct(&1.cleared_at, DateTime))
    restoration = Enum.find(HumanAccess.history(human.uid), &(&1.action == "restore"))
    assert restoration.reason == "return"
    assert restoration.actor == Ankole.ActorRef.from_actor(actor)
    assert {:ok, _} = Pages.authorize(actor_fixture(human.uid), target.id, "node_view")
  end

  test "confirmed departure disables the last administrator without reopening setup", %{
    tenant: tenant
  } do
    :ok = set_privileged_tenant(tenant)
    %{principal: human} = human_fixture()
    %{principal: other} = human_fixture()
    assert {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(human.uid)

    assert {:error, :last_active_human_admin} =
             Ankole.PrincipalsFixtures.disable_principal_fixture(human.uid)

    assert {:error, :cannot_disable_self} =
             HumanAccess.disable(
               human.uid,
               "review",
               Ankole.ActorRef.from_principal(human),
               "self"
             )

    assert {:ok, %{status: :disabled}} =
             HumanAccess.restrict_from_provider(human.uid, "lark", "departed", "event")

    assert {:error, :root_init_closed} =
             Ankole.PrincipalsFixtures.first_site_admin_fixture(other.uid)

    assert {:ok, _} = HumanAccess.recover_admin(other.uid, "test operator", "identity verified")
    assert Ankole.AuthZ.site_admin?(other.uid)
    assert Ankole.AuthZ.pod_admin?(other.uid)

    assert {:error, :active_admin_exists} =
             HumanAccess.recover_admin(human.uid, "test operator", "review")

    assert [%{action: "operator_admin_recovery"}] = HumanAccess.history(other.uid)
  end

  test "invalid restriction does not change access or leave an audit record" do
    %{principal: human} = human_fixture()
    assert {:error, %Ash.Error.Invalid{}} = HumanAccess.disable(human.uid, "", nil, "invalid")
    assert {:ok, %{status: :active, access_version: 1}} = Principals.get_principal(human.uid)
    assert [] = HumanAccess.history(human.uid)
  end
end
