defmodule BullX.AuthZ.SchemaTest do
  use BullX.DataCase, async: false

  alias BullX.AuthZ
  alias BullX.AuthZ.PermissionGrant
  alias BullX.Repo

  test "principal groups normalize names and protect built_in from public writes" do
    assert {:ok, group} =
             AuthZ.create_principal_group(%{
               name: " Engineers ",
               description: "Team",
               built_in: true
             })

    assert group.name == "engineers"
    assert group.kind == :static
    assert group.built_in == false

    assert {:ok, updated} =
             AuthZ.update_principal_group(group, %{
               name: "admins",
               built_in: true,
               description: "Engineering group"
             })

    assert updated.name == "engineers"
    assert updated.kind == :static
    assert updated.built_in == false
    assert updated.description == "Engineering group"
  end

  test "computed groups validate CEL conditions and keep kind immutable on update" do
    assert {:ok, group} =
             AuthZ.create_principal_group(%{
               name: " Active_Humans ",
               kind: :computed,
               computed_condition: ~s(principal.type == "human" && principal.status == "active"),
               built_in: true
             })

    assert group.name == "active_humans"
    assert group.kind == :computed
    assert group.built_in == false

    assert {:ok, updated} =
             AuthZ.update_principal_group(group, %{
               kind: :static,
               computed_condition: ~s(principal.type == "agent")
             })

    assert updated.kind == :computed
    assert updated.computed_condition == ~s(principal.type == "agent")

    assert {:error, changeset} =
             AuthZ.create_principal_group(%{
               name: "bad-computed",
               kind: :computed,
               computed_condition: "not valid cel"
             })

    assert %{computed_condition: [_ | _]} = errors_on(changeset)

    assert {:error, changeset} =
             AuthZ.create_principal_group(%{
               name: "bad-static",
               computed_condition: ~s(principal.type == "human")
             })

    assert %{computed_condition: [_ | _]} = errors_on(changeset)
  end

  test "permission grants require one subject and validate action, resource pattern, metadata, and condition" do
    human = human!("grant-human")
    {:ok, group} = AuthZ.create_principal_group(%{name: "grant-group"})

    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: human.uid,
               resource_pattern: "web_console",
               action: "read"
             })

    assert grant.condition == "true"
    assert grant.metadata == %{}

    assert {:error, changeset} =
             AuthZ.create_permission_grant(%{
               principal_uid: human.uid,
               group_id: group.id,
               resource_pattern: "web_console",
               action: "read"
             })

    assert %{principal_uid: [_ | _], group_id: [_ | _]} = errors_on(changeset)

    assert {:error, changeset} =
             AuthZ.create_permission_grant(%{
               principal_uid: human.uid,
               resource_pattern: "[",
               action: "read:all",
               metadata: [],
               condition: "true"
             })

    assert %{resource_pattern: [_ | _], action: [_ | _], metadata: [_ | _]} =
             errors_on(changeset)

    assert {:ok, _grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: human.uid,
               resource_pattern: "workspace:**:member",
               action: "read"
             })

    assert {:error, changeset} =
             AuthZ.create_permission_grant(%{
               principal_uid: human.uid,
               resource_pattern: "web_console",
               action: "read",
               condition: "true }; permit(principal, action, resource) when { true"
             })

    assert %{condition: [_ | _]} = errors_on(changeset)
  end

  test "permission grants can be idempotently upserted by subject, resource, action, and condition" do
    human = human!("upsert-human")
    {:ok, group} = AuthZ.create_principal_group(%{name: "upsert-group"})

    assert {:ok, principal_grant} =
             AuthZ.upsert_permission_grant(%{
               principal_uid: human.uid,
               resource_pattern: "ai_agent:agent-a",
               action: "invoke",
               condition: "true",
               description: "initial",
               metadata: %{"created_by" => "test"}
             })

    assert {:ok, updated_principal_grant} =
             AuthZ.upsert_permission_grant(%{
               principal_uid: human.uid,
               resource_pattern: "ai_agent:agent-a",
               action: "invoke",
               condition: "true",
               description: "updated",
               metadata: %{"created_by" => "setup"}
             })

    assert updated_principal_grant.id == principal_grant.id
    assert updated_principal_grant.description == "updated"
    assert updated_principal_grant.metadata == %{"created_by" => "setup"}

    assert {:ok, group_grant} =
             AuthZ.upsert_permission_grant(%{
               group_id: group.id,
               resource_pattern: "ai_agent:agent-a",
               action: "invoke",
               condition: "true",
               metadata: %{"group" => "first"}
             })

    assert {:ok, updated_group_grant} =
             AuthZ.upsert_permission_grant(%{
               group_id: group.id,
               resource_pattern: "ai_agent:agent-a",
               action: "invoke",
               condition: "true",
               metadata: %{"group" => "second"}
             })

    assert updated_group_grant.id == group_grant.id
    assert updated_group_grant.metadata == %{"group" => "second"}

    assert Repo.aggregate(PermissionGrant, :count) == 2
  end

  defp human!(uid) do
    {:ok, %{principal: principal}} =
      BullX.Principals.create_human(%{uid: uid, display_name: uid, email: "#{uid}@example.com"})

    principal
  end
end
