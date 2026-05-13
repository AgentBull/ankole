defmodule BullX.AuthZ.SchemaTest do
  use BullX.DataCase, async: false

  alias BullX.AuthZ

  test "principal groups normalize names and protect built_in from public writes" do
    assert {:ok, group} =
             AuthZ.create_principal_group(%{
               name: " Engineers ",
               description: "Team",
               built_in: true
             })

    assert group.name == "engineers"
    assert group.built_in == false

    assert {:ok, updated} =
             AuthZ.update_principal_group(group, %{
               name: "admins",
               built_in: true,
               description: "Engineering group"
             })

    assert updated.name == "engineers"
    assert updated.built_in == false
    assert updated.description == "Engineering group"
  end

  test "permission grants require one subject and validate action, resource pattern, metadata, and condition" do
    human = human!("grant-human")
    {:ok, group} = AuthZ.create_principal_group(%{name: "grant-group"})

    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               principal_id: human.id,
               resource_pattern: "web_console",
               action: "read"
             })

    assert grant.condition == "true"
    assert grant.metadata == %{}

    assert {:error, changeset} =
             AuthZ.create_permission_grant(%{
               principal_id: human.id,
               group_id: group.id,
               resource_pattern: "web_console",
               action: "read"
             })

    assert %{principal_id: [_ | _], group_id: [_ | _]} = errors_on(changeset)

    assert {:error, changeset} =
             AuthZ.create_permission_grant(%{
               principal_id: human.id,
               resource_pattern: "web**",
               action: "read:all",
               metadata: [],
               condition: "true"
             })

    assert %{resource_pattern: [_ | _], action: [_ | _], metadata: [_ | _]} =
             errors_on(changeset)

    assert {:error, changeset} =
             AuthZ.create_permission_grant(%{
               principal_id: human.id,
               resource_pattern: "web_console",
               action: "read",
               condition: "true }; permit(principal, action, resource) when { true"
             })

    assert %{condition: [_ | _]} = errors_on(changeset)
  end

  defp human!(uid) do
    {:ok, %{principal: principal}} =
      BullX.Principals.create_human(%{uid: uid, display_name: uid, email: "#{uid}@example.com"})

    principal
  end
end
