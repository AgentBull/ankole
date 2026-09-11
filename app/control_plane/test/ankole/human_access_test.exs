defmodule Ankole.HumanAccessTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  alias Ankole.{AuthZ, Principals}
  alias Ankole.Principals.HumanAccess

  test "independent restrictions require review and restoration cannot revive old access" do
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

    assert {:ok, review} = AuthZ.restoration_review(human.uid)

    assert {:error, :active_restrictions} =
             HumanAccess.restore(human.uid, review.fingerprint, nil, "reviewed", "restore-1")

    alias Ankole.IdentityProviders.DirectoryAccess
    assert {:ok, ticket} = DirectoryAccess.begin_sync("lark")

    assert {:ok, _} =
             DirectoryAccess.finish_sync(ticket, "scope", [{human.uid, :healthy}],
               admission_scope: "none",
               maximum_removal_percent: 20
             )

    assert {:ok, _} =
             HumanAccess.clear_restriction(human.uid, provider.id, nil, "reviewed", "clear-3")

    assert {:ok, restored} =
             HumanAccess.restore(human.uid, review.fingerprint, nil, "reviewed", "restore-1")

    assert restored.status == :active
    assert {:error, :human_access_revoked} = HumanAccess.check(human.uid, human.access_version)
    assert :ok = HumanAccess.check(human.uid, restored.access_version)
    assert {:error, :human_access_revoked} = HumanAccess.check(human.uid, nil)
  end

  test "changed permission rules invalidate the restoration review" do
    %{principal: human} = human_fixture()
    assert {:ok, _} = HumanAccess.disable(human.uid, "review", nil, "disable")
    [restriction] = HumanAccess.restrictions(human.uid)

    assert {:ok, _} =
             HumanAccess.clear_restriction(human.uid, restriction.id, nil, "verified", "clear")

    assert {:ok, review} = AuthZ.restoration_review(human.uid)

    assert {:ok, _} =
             AuthZ.create_permission_grant(%{
               principal_uid: human.uid,
               resource_pattern: "**",
               action: "read"
             })

    assert {:error, :permission_review_changed} =
             HumanAccess.restore(human.uid, review.fingerprint, nil, "approved", "restore")

    assert {:ok, %{status: :disabled}} = Principals.get_principal(human.uid)
  end

  test "confirmed departure disables the last administrator without reopening setup" do
    %{principal: human} = human_fixture()
    %{principal: other} = human_fixture()
    assert {:ok, _} = AuthZ.root_init_admin(human.uid)
    assert {:error, :last_active_human_admin} = Principals.disable_principal(human.uid)

    assert {:error, :cannot_disable_self} =
             HumanAccess.disable(human.uid, "review", human.uid, "self")

    assert {:ok, %{status: :disabled}} =
             HumanAccess.restrict_from_provider(human.uid, "lark", "departed", "event")

    assert {:error, :root_init_closed} = AuthZ.root_init_admin(other.uid)
    assert {:ok, _} = HumanAccess.recover_admin(other.uid, "test operator", "identity verified")
    assert Ankole.AdminAuth.active_human_admin?(other.uid)

    assert {:error, :active_admin_exists} =
             HumanAccess.recover_admin(human.uid, "test operator", "review")

    assert [%{action: "operator_admin_recovery"}] = HumanAccess.history(other.uid)
  end

  test "invalid restriction does not change access or leave an audit record" do
    %{principal: human} = human_fixture()
    assert {:error, %Ecto.Changeset{}} = HumanAccess.disable(human.uid, "", nil, "invalid")
    assert {:ok, %{status: :active, access_version: 1}} = Principals.get_principal(human.uid)
    assert [] = HumanAccess.history(human.uid)
  end
end
