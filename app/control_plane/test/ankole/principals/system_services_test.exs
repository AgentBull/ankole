defmodule Ankole.Principals.SystemServicesTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Principals
  alias Ankole.Principals.{Principal, SystemServices}

  test "the tenant lifecycle scaffolds every registered system Principal idempotently" do
    tenant = create_committed_tenant()

    Repo.with_tenant(tenant.id, fn ->
      for uid <- SystemServices.uids() do
        assert {:ok, %{uid: ^uid, type: :system, status: :active}} =
                 Principals.system_principal(uid)

        assert {:error, :not_found} = Principals.get_agent(uid)
      end

      assert {:ok, %{uid: "system"}} = Principals.system_principal()
      assert {:ok, _} = Repo.transact(fn -> Principals.ensure_system_principals_in_tx() end)
      assert Repo.aggregate(from(p in Principal, where: p.type == :system), :count) == 2
    end)
  end

  test "unregistered system creation and system rename are rejected" do
    assert {:error, :unknown_system_principal} = Principals.system_principal("unregistered")

    assert {:error, _} =
             Ankole.Ash.create(Principal, :create_in_tx, %{uid: "unregistered", type: :system})

    for uid <- SystemServices.uids() do
      assert {:error, :system_uid_immutable} = Principals.rename(uid, "renamed")
    end
  end

  test "missing system rows fail reads without recreating the Principal" do
    assert {1, _} = Repo.delete_all(from(p in Principal, where: p.uid == "ankole_brain"))
    assert {:error, :system_principal_missing} = Principals.system_principal("ankole_brain")
    assert {:error, :system_principal_missing} = Ankole.Brain.Config.execution_subject_uid()

    assert {:error, :system_principal_missing} =
             Ankole.AIGateway.ModelProfiles.system_model_profile_configuration("ankole_brain")

    for read <- [
          &Ankole.Brain.Config.extraction_model/0,
          &Ankole.Brain.Config.dreaming_model/0,
          &Ankole.Brain.Config.web_fetch_model/0,
          &Ankole.Brain.Config.rerank_model/0
        ] do
      assert_raise RuntimeError,
                   "Brain system Principal unavailable: :system_principal_missing",
                   read
    end

    assert {:error, :not_found} = Principals.get_principal("ankole_brain")
  end

  test "system Principals stay out of mention, collaborator, and conversation choices" do
    %{principal: human} = human_fixture()
    actor = actor_fixture(human.uid)

    assert {:ok, candidates} =
             Ankole.Pod.Pages.Mentions.candidates(actor, %{category: :principal})

    uids = SystemServices.uids()
    refute Enum.any?(candidates.principals, &(&1.principal_uid in uids))
    refute Enum.any?(Ankole.Pod.Pages.Collaborators.catalog([]), &(&1.principal_uid in uids))
    refute Enum.any?(Ankole.Conversations.NativeRoom.teammates(actor), &(&1.uid in uids))
  end
end
