defmodule Ankole.Setup.CompletionTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.Setup.Completion
  alias Ankole.Setup.Config, as: SetupConfig

  setup %{tenant: tenant} do
    :ok = set_privileged_tenant(tenant)
    :ok = Ankole.Tenants.ensure_scaffold(tenant)

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    {:ok, _code} = SetupConfig.put_bootstrap_activation_code("ABCDEFGH")
    :ok
  end

  describe "complete_with_first_site_admin/1" do
    test "claims site admin, marks setup complete, and deletes the activation code" do
      %{principal: principal} = human_fixture()

      assert {:ok, %{admin_group: admin_group}} =
               Completion.complete_with_first_site_admin(principal.uid)

      assert {:ok, true} = SetupConfig.completed?()
      assert :error = SetupConfig.bootstrap_activation_code()

      assert {:ok, groups} = AuthZ.list_principal_group_memberships(principal.uid)
      assert Enum.any?(groups, &(&1.id == admin_group.id))
    end

    test "does not mark setup complete when the site admin claim fails" do
      assert {:error, :not_found} = Completion.complete_with_first_site_admin("missing-principal")

      assert {:ok, false} = SetupConfig.completed?()
      assert {:ok, "ABCDEFGH"} = SetupConfig.bootstrap_activation_code()
    end

    test "a retry by the same principal converges after both steps committed" do
      %{principal: principal} = human_fixture()

      assert {:ok, _root} = Completion.complete_with_first_site_admin(principal.uid)

      assert {:ok, %{membership: membership}} =
               Completion.complete_with_first_site_admin(principal.uid)

      assert membership.principal_uid == principal.uid
      assert {:ok, true} = SetupConfig.completed?()
      assert :error = SetupConfig.bootstrap_activation_code()
    end

    test "a different principal cannot reopen a completed setup" do
      %{principal: first} = human_fixture()
      %{principal: second} = human_fixture()

      assert {:ok, _root} = Completion.complete_with_first_site_admin(first.uid)
      assert {:error, :root_init_closed} = Completion.complete_with_first_site_admin(second.uid)

      assert {:ok, true} = SetupConfig.completed?()
      assert {:ok, groups} = AuthZ.list_principal_group_memberships(second.uid)
      assert groups == []
    end

    test "materializes the selected brain packs in the completion transaction" do
      %{principal: principal} = human_fixture()

      assert {:ok, _root} = Completion.complete_with_first_site_admin(principal.uid, ["pevc"])

      assert {:ok, true} = SetupConfig.completed?()
      installed = Enum.map(Ankole.Repo.all(Ankole.Brain.Schemas.SchemaPack), & &1.name)
      assert "general" in installed
      assert "pevc" in installed
    end

    test "a failed pack materialization rolls back the site admin claim and the flag" do
      %{principal: principal} = human_fixture()

      assert {:error, {:unknown_packs, ["bogus"]}} =
               Completion.complete_with_first_site_admin(principal.uid, ["bogus"])

      assert {:ok, false} = SetupConfig.completed?()
      assert {:ok, []} = AuthZ.list_principal_group_memberships(principal.uid)
      assert Ankole.Repo.all(Ankole.Brain.Schemas.SchemaPack) == []
    end
  end
end
