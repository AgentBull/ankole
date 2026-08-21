defmodule Ankole.Setup.CompletionTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.Setup.Completion
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    {:ok, false} = SetupConfig.put_completed(false)
    {:ok, _code} = SetupConfig.put_bootstrap_activation_code("ABCDEFGH")
    :ok
  end

  describe "complete_with_root_admin/1" do
    test "claims root admin, marks setup complete, and deletes the activation code" do
      %{principal: principal} = human_fixture()

      assert {:ok, %{admin_group: admin_group}} =
               Completion.complete_with_root_admin(principal.uid)

      assert {:ok, true} = SetupConfig.completed?()
      assert :error = SetupConfig.bootstrap_activation_code()

      assert {:ok, groups} = AuthZ.list_principal_group_memberships(principal.uid)
      assert Enum.any?(groups, &(&1.id == admin_group.id))
    end

    test "does not mark setup complete when the root claim fails" do
      assert {:error, :not_found} = Completion.complete_with_root_admin("missing-principal")

      assert {:ok, false} = SetupConfig.completed?()
      assert {:ok, "ABCDEFGH"} = SetupConfig.bootstrap_activation_code()
    end
  end
end
