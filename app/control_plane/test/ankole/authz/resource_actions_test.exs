defmodule Ankole.AuthZ.ResourceActionsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.AuthZ.{ExternalBinding, Grant, Group, Membership}

  test "built-in group identity and computation cannot change through the persistence action" do
    group = Repo.get_by!(Group, name: "all_humans")

    assert {:error, error} =
             Repo.transact(fn _repo ->
               Ankole.Ash.update(group, :profile_in_tx, %{
                 name: "replaced",
                 kind: :static,
                 computed_condition: nil
               })
             end)

    assert %{name: [_], kind: [_], computed_condition: [_]} = errors_on(error)
    Ankole.DataCase.assert_persisted_equal(Repo.get!(Group, group.id), group)
  end

  test "grant actions reject ambiguous owners and invalid action syntax before persistence" do
    %{principal: human} = human_fixture()

    {:ok, group} =
      AuthZ.create_principal_group(%{name: unique_uid("group"), display_name: "Group"})

    count = Repo.aggregate(Grant, :count)

    for {attrs, field} <- [
          {%{principal_uid: human.uid, group_id: group.id, action: "read"}, :group_id},
          {%{action: "read"}, :principal_uid},
          {%{principal_uid: human.uid, action: "page:view"}, :action}
        ] do
      assert {:error, error} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.create(Grant, :create_in_tx, Map.put(attrs, :resource_pattern, "**"))
               end)

      assert [_ | _] = Map.fetch!(errors_on(error), field)
    end

    assert Repo.aggregate(Grant, :count) == count
  end

  test "membership and external binding upserts preserve their actual keys and first admission" do
    %{principal: human} = human_fixture()

    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: unique_uid("directory"),
        display_name: "Directory",
        domain: :directory
      })

    {:ok, operator} =
      AuthZ.create_principal_group(%{name: unique_uid("operator"), display_name: "Operator"})

    assert {:ok, membership} = AuthZ.add_principal_to_group(human.uid, operator.id)
    assert {:ok, repeated} = AuthZ.add_principal_to_group(human.uid, operator.id)
    assert_persisted_equal(repeated, membership)

    Ankole.DataCase.assert_persisted_equal(
      Repo.all(from m in Membership, where: m.group_id == ^operator.id),
      [membership]
    )

    attrs = %{
      provider: "LARK-MAIN",
      external_kind: :directory_department,
      external_id: "department",
      group_id: group.id,
      metadata: %{"name" => "Initial"}
    }

    assert {:ok, binding} = AuthZ.upsert_external_binding(attrs)
    assert binding.provider == "lark-main"

    assert {:ok, updated} =
             AuthZ.upsert_external_binding(Map.put(attrs, :metadata, %{"name" => "Updated"}))

    assert Map.take(updated, [:tenant_id, :provider, :external_kind, :external_id, :inserted_at]) ==
             Map.take(binding, [:tenant_id, :provider, :external_kind, :external_id, :inserted_at])

    assert updated.metadata == %{"name" => "Updated"}

    assert_persisted_equal(
      Repo.get_by!(ExternalBinding,
        provider: "lark-main",
        external_kind: :directory_department,
        external_id: "department"
      ),
      updated
    )
  end
end
