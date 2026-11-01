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

    for {attrs, field, message} <- [
          {%{principal_uid: human.uid, group_id: group.id, action: "read"}, :principal_uid,
           "exactly one Principal, group, or source node is required"},
          {%{action: "read"}, :principal_uid,
           "exactly one Principal, group, or source node is required"},
          {%{principal_uid: human.uid, action: "page:view"}, :action, "must not contain colon"}
        ] do
      assert {:error, error} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.create(
                   Grant,
                   :create_in_tx,
                   Map.put(attrs, :resource_pattern, "tenant_console:**")
                 )
               end)

      assert Map.fetch!(errors_on(error), field) == [message]
    end

    assert Repo.aggregate(Grant, :count) == count
  end

  test "private Drive grant namespaces preserve literal opaque UIDs and reject glob owners" do
    human = human_fixture().principal

    for uid <- ["ops%41", "用户", "abc:def"] do
      assert {:ok, grant} =
               AuthZ.create_permission_grant(%{
                 principal_uid: human.uid,
                 resource_pattern: "drive:private:#{uid}:**",
                 action: "node_view"
               })

      assert grant.resource_pattern == "drive:private:#{uid}:**"
    end

    for uid <- ["abc*", "abc?", "abc[1]", "abc{1}"] do
      assert {:error, _} =
               AuthZ.create_permission_grant(%{
                 principal_uid: human.uid,
                 resource_pattern: "drive:private:#{uid}:**",
                 action: "node_view"
               })
    end
  end

  test "static group membership counts unique canonical UIDs within its tenant" do
    human = human_fixture().principal
    other = human_fixture().principal

    {:ok, group} =
      AuthZ.create_principal_group(%{name: unique_uid("count"), display_name: "Count"})

    {:ok, _} = AuthZ.add_principal_to_group(human.uid, group.name)

    assert AuthZ.all_in_group?([], group)
    assert AuthZ.all_in_group?([human.uid, String.upcase(human.uid)], group)
    refute AuthZ.all_in_group?([human.uid, other.uid], group)
    refute AuthZ.all_in_group?([human.uid, ""], group)

    foreign = create_tenant()
    refute Repo.with_tenant(foreign.id, fn -> AuthZ.all_in_group?([human.uid], group) end)
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

  test "batch grant upserts deduplicate natural keys and update metadata idempotently" do
    %{principal: human} = human_fixture()

    {:ok, group} =
      AuthZ.create_principal_group(%{name: unique_uid("batch-grants"), display_name: "Batch"})

    assert {:ok, grants} =
             Repo.transact(fn _repo ->
               Ankole.AuthZ.Grants.upsert_permission_grants([
                 %{
                   group_id: group.id,
                   resource_pattern: "tenant_console:**",
                   action: "read",
                   description: "Initial",
                   metadata: %{"rev" => 1}
                 },
                 %{
                   group_id: group.id,
                   resource_pattern: "tenant_console:**",
                   action: "read",
                   description: "Latest in batch",
                   metadata: %{"rev" => 2}
                 },
                 %{
                   principal_uid: human.uid,
                   resource_pattern: "site_console:**",
                   action: "read",
                   description: "Principal read"
                 }
               ])
             end)

    assert length(grants) == 2

    [group_grant, principal_grant] = grants
    assert group_grant.description == "Latest in batch"
    assert group_grant.metadata == %{"rev" => 2}
    assert principal_grant.principal_uid == human.uid

    assert {:ok, [repeated_group_grant]} =
             Repo.transact(fn _repo ->
               Ankole.AuthZ.Grants.upsert_permission_grants([
                 %{
                   group_id: group.id,
                   resource_pattern: "tenant_console:**",
                   action: "read",
                   description: "Updated across tx",
                   metadata: %{"rev" => 3}
                 }
               ])
             end)

    assert repeated_group_grant.id == group_grant.id
    assert repeated_group_grant.description == "Updated across tx"
    assert repeated_group_grant.metadata == %{"rev" => 3}
  end
end
