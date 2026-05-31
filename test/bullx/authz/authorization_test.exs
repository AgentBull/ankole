defmodule BullX.AuthZ.AuthorizationTest do
  use BullX.DataCase, async: false

  import ExUnit.CaptureLog

  alias BullX.AuthZ
  alias BullX.AuthZ.PermissionGrant
  alias BullX.AuthZ.PrincipalGroup
  alias BullX.AuthZ.PrincipalGroupMembership
  alias BullX.Principals

  describe "authorization decisions" do
    test "direct grants authorize Human and Agent Principals" do
      human = human!("direct-human")
      agent = agent!("direct-agent")

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: human.uid,
          resource_pattern: "web_console",
          action: "read"
        })

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: agent.uid,
          resource_pattern: "capability:browser_use",
          action: "execute"
        })

      assert :ok = AuthZ.authorize(human, "web_console", "read")
      assert :ok = AuthZ.authorize(agent.uid, "capability:browser_use", "execute")
      assert {:error, :forbidden} = AuthZ.authorize(human, "web_console", "write")
    end

    test "authorize_all authorizes multiple actions for one principal and resource" do
      human = human!("multi-action-human")
      resource = "ai_agent:multi-action"

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: human.uid,
          resource_pattern: resource,
          action: "invoke"
        })

      assert :ok = AuthZ.authorize_all(human, resource, ["invoke"])
      assert {:error, :forbidden} = AuthZ.authorize_all(human, resource, ["invoke", "write"])

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: human.uid,
          resource_pattern: resource,
          action: "write"
        })

      assert :ok = AuthZ.authorize_all(human.uid, resource, ["invoke", "write"])
      assert {:error, :invalid_request} = AuthZ.authorize_all(human, resource, [])
      assert {:error, :invalid_request} = AuthZ.authorize_all(human, resource, ["bad:action"])
    end

    test "action mismatch never authorizes" do
      human = human!("action-mismatch-human")

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: human.uid,
          resource_pattern: "web_console",
          action: "read"
        })

      assert :ok = AuthZ.authorize(human, "web_console", "read")
      assert {:error, :forbidden} = AuthZ.authorize(human, "web_console", "write")
    end

    test "group grants use resource patterns and exact action matching" do
      human = human!("group-human")
      {:ok, group} = AuthZ.create_principal_group(%{name: "operators"})

      :ok = AuthZ.add_principal_to_group(human, group)

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          group_id: group.id,
          resource_pattern: "workspace_channel:**",
          action: "write"
        })

      assert :ok = AuthZ.authorize(human, "workspace_channel:main", "write")
      assert :ok = AuthZ.authorize_permission(human, "workspace_channel:foo:bar:write")
      assert {:error, :forbidden} = AuthZ.authorize(human, "workspace_channel:foo", "read")
      assert {:error, :invalid_request} = AuthZ.authorize(human, "workspace_channel:*", "write")
    end

    test "computed group grants authorize matching Principals without membership rows" do
      human = human!("computed-human")
      agent = agent!("computed-agent")

      {:ok, group} =
        AuthZ.create_principal_group(%{
          name: "computed-agents",
          kind: :computed,
          computed_condition: ~s(principal.type == "agent" && principal.status == "active")
        })

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          group_id: group.id,
          resource_pattern: "capability:browser",
          action: "execute"
        })

      refute membership_exists?(agent.uid, group.id)

      assert :ok = AuthZ.authorize(agent, "capability:browser", "execute")
      assert {:error, :forbidden} = AuthZ.authorize(human, "capability:browser", "execute")

      assert {:ok, agent_groups} = AuthZ.list_principal_groups(agent)
      assert Enum.map(agent_groups, & &1.name) == ["computed-agents"]
    end

    test "all_humans computed group grants authorize active Human Principals without membership rows" do
      ensure_built_in_groups!()

      all_humans = Repo.get_by!(PrincipalGroup, name: "all_humans")
      human = human!("all-humans-member")
      disabled_human = human!("all-humans-disabled")
      agent = agent!("all-humans-agent")

      {:ok, disabled_human} = Principals.disable_principal(disabled_human)

      assert all_humans.kind == :computed

      assert all_humans.computed_condition ==
               ~s(principal.type == "human" && principal.status == "active")

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          group_id: all_humans.id,
          resource_pattern: "ai_agent:default",
          action: "invoke"
        })

      refute membership_exists?(human.uid, all_humans.id)
      refute membership_exists?(disabled_human.uid, all_humans.id)

      assert :ok = AuthZ.authorize(human, "ai_agent:default", "invoke")

      assert {:error, :principal_disabled} =
               AuthZ.authorize(disabled_human, "ai_agent:default", "invoke")

      assert {:error, :forbidden} = AuthZ.authorize(agent, "ai_agent:default", "invoke")

      assert {:ok, human_groups} = AuthZ.list_principal_groups(human)
      assert Enum.map(human_groups, & &1.name) == ["all_humans"]

      assert {:ok, []} = AuthZ.list_principal_groups(disabled_human)
      assert {:ok, []} = AuthZ.list_principal_groups(agent)
    end

    test "disabled Principals deny before grants are evaluated" do
      human = human!("disabled-human")

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: human.uid,
          resource_pattern: "web_console",
          action: "read"
        })

      assert {:ok, disabled} = Principals.disable_principal(human)
      assert {:error, :principal_disabled} = AuthZ.authorize(disabled, "web_console", "read")
    end

    test "CEL request context controls matching grants" do
      human = human!("cel-human")

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: human.uid,
          resource_pattern: "web_console",
          action: "read",
          condition: "context.request.business_hours"
        })

      assert :ok = AuthZ.authorize(human, "web_console", "read", %{business_hours: true})

      assert {:error, :forbidden} =
               AuthZ.authorize(human, "web_console", "read", %{business_hours: false})

      assert {:error, :forbidden} = AuthZ.authorize(human, "web_console", "read", %{})
    end

    test "invalid persisted CEL conditions fail closed and emit telemetry" do
      human = human!("invalid-cel-human")

      {:ok, grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: human.uid,
          resource_pattern: "web_console",
          action: "read",
          condition: "true"
        })

      Repo.update_all(
        from(g in PermissionGrant, where: g.id == ^grant.id),
        set: [condition: "not valid cel"]
      )

      attach_telemetry()

      capture_log([level: :error], fn ->
        assert {:error, :forbidden} = AuthZ.authorize(human, "web_console", "read")
      end)

      assert_received {:telemetry_event, [:bullx, :authz, :invalid_persisted_data], %{count: 1},
                       %{kind: :condition_compile, id: grant_id, action: "read"}}

      assert grant_id == grant.id
    after
      detach_telemetry()
    end

    test "non-boolean CEL results fail closed and emit persisted-data telemetry" do
      human = human!("non-boolean-cel-human")

      {:ok, grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: human.uid,
          resource_pattern: "web_console",
          action: "read",
          condition: "principal.uid"
        })

      attach_telemetry()

      capture_log([level: :error], fn ->
        assert {:error, :forbidden} = AuthZ.authorize(human, "web_console", "read")
      end)

      assert_received {:telemetry_event, [:bullx, :authz, :invalid_persisted_data], %{count: 1},
                       %{kind: :condition_result_type, id: grant_id, action: "read"}}

      assert grant_id == grant.id
    after
      detach_telemetry()
    end

    test "missing CEL context fails closed without invalid persisted data telemetry" do
      human = human!("missing-cel-context-human")

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: human.uid,
          resource_pattern: "web_console",
          action: "read",
          condition: "context.request.business_hours"
        })

      attach_telemetry()

      assert {:error, :forbidden} = AuthZ.authorize(human, "web_console", "read", %{})

      refute_received {:telemetry_event, [:bullx, :authz, :invalid_persisted_data], _measurements,
                       _metadata}
    after
      detach_telemetry()
    end

    test "invalid persisted computed group conditions fail closed and emit telemetry" do
      human = human!("invalid-computed-human")

      {:ok, group} =
        AuthZ.create_principal_group(%{
          name: "invalid-computed",
          kind: :computed,
          computed_condition: ~s(principal.type == "human")
        })

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          group_id: group.id,
          resource_pattern: "web_console",
          action: "read"
        })

      Repo.update_all(
        from(g in PrincipalGroup, where: g.id == ^group.id),
        set: [computed_condition: "principal.uid"]
      )

      attach_telemetry()

      capture_log([level: :error], fn ->
        assert {:error, :forbidden} = AuthZ.authorize(human, "web_console", "read")
      end)

      assert_received {:telemetry_event, [:bullx, :authz, :invalid_persisted_data], %{count: 1},
                       %{kind: :computed_group_condition_result_type, id: group_id}}

      assert group_id == group.id
    after
      detach_telemetry()
    end
  end

  describe "group management and admin recoverability" do
    test "built-in admin group is protected and non-magical" do
      ensure_built_in_groups!()

      admin = Repo.get_by!(PrincipalGroup, name: "admin")
      all_humans = Repo.get_by!(PrincipalGroup, name: "all_humans")

      assert admin.built_in == true
      assert admin.kind == :static
      assert all_humans.built_in == true
      assert all_humans.kind == :computed
      assert {:error, :built_in_group} = AuthZ.delete_principal_group(admin)
      assert {:error, :built_in_group} = AuthZ.delete_principal_group(all_humans)
      assert [] = Repo.all(from grant in PermissionGrant, where: grant.group_id == ^admin.id)
    end

    test "computed groups reject manual membership edits" do
      ensure_built_in_groups!()

      human = human!("all-humans-manual")
      all_humans = Repo.get_by!(PrincipalGroup, name: "all_humans")

      assert {:error, :computed_group} = AuthZ.add_principal_to_group(human, all_humans)
      assert {:error, :computed_group} = AuthZ.remove_principal_from_group(human, all_humans)
      refute membership_exists?(human.uid, all_humans.id)
    end

    test "groups with grants cannot be deleted" do
      {:ok, group} = AuthZ.create_principal_group(%{name: "delete-guard"})

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          group_id: group.id,
          resource_pattern: "web_console",
          action: "read"
        })

      assert {:error, :group_has_grants} = AuthZ.delete_principal_group(group)
    end

    test "disabled Principals can still be added to and listed from static groups" do
      human = human!("disabled-member")
      {:ok, disabled} = Principals.disable_principal(human)
      {:ok, group} = AuthZ.create_principal_group(%{name: "disabled-members"})

      assert :ok = AuthZ.add_principal_to_group(disabled, group)
      assert {:ok, [listed]} = AuthZ.list_principal_groups(disabled)
      assert listed.id == group.id
    end

    test "admin membership removal preserves static and active Human recovery" do
      alice = human!("admin-alice")
      bob = human!("admin-bob")
      agent = agent!("admin-agent")
      {:ok, admin, _status} = AuthZ.ensure_built_in_admin_group()

      :ok = AuthZ.add_principal_to_group(alice, admin)
      assert {:error, :last_admin_member} = AuthZ.remove_principal_from_group(alice, admin)

      :ok = AuthZ.add_principal_to_group(agent, admin)
      assert {:error, :last_active_human_admin} = AuthZ.remove_principal_from_group(alice, admin)

      :ok = AuthZ.add_principal_to_group(bob, admin)
      assert :ok = AuthZ.remove_principal_from_group(alice, admin)
    end

    test "Principal disable flow preserves the final active Human admin" do
      alice = human!("disable-admin-alice")
      bob = human!("disable-admin-bob")
      {:ok, admin, _status} = AuthZ.ensure_built_in_admin_group()

      :ok = AuthZ.add_principal_to_group(alice, admin)
      assert {:error, :last_active_human_admin} = Principals.disable_principal(alice)

      :ok = AuthZ.add_principal_to_group(bob, admin)
      assert {:ok, disabled} = Principals.disable_principal(alice)
      assert disabled.status == :disabled
    end
  end

  describe "root initialization" do
    test "root_init_admin creates built-in groups and the first admin membership" do
      principal = human!("root-admin")

      refute AuthZ.root_initialized?()
      assert :ok = AuthZ.root_init_admin(principal)
      assert AuthZ.root_initialized?()

      admin = Repo.get_by!(PrincipalGroup, name: "admin")
      all_humans = Repo.get_by!(PrincipalGroup, name: "all_humans")

      assert membership_exists?(principal.uid, admin.id)
      assert all_humans.built_in == true
      assert all_humans.kind == :computed
      refute membership_exists?(principal.uid, all_humans.id)
    end

    test "root_init_admin closes after the first admin membership exists" do
      first = human!("root-first")
      second = human!("root-second")

      assert :ok = AuthZ.root_init_admin(first)
      assert {:error, :root_init_closed} = AuthZ.root_init_admin(second)
    end
  end

  defp human!(uid) do
    {:ok, %{principal: principal}} =
      Principals.create_human(%{uid: uid, display_name: uid, email: "#{uid}@example.com"})

    principal
  end

  defp agent!(uid) do
    {:ok, %{principal: principal}} =
      Principals.create_agent(%{
        uid: uid,
        display_name: uid,
        profile: %{}
      })

    principal
  end

  defp ensure_built_in_groups! do
    assert {:ok, _all_humans, _status} = AuthZ.ensure_built_in_all_humans_group()
    assert {:ok, _admin, _status} = AuthZ.ensure_built_in_admin_group()
    :ok
  end

  defp membership_exists?(principal_uid, group_id) do
    Repo.exists?(
      from membership in PrincipalGroupMembership,
        where: membership.principal_uid == ^principal_uid and membership.group_id == ^group_id,
        select: 1
    )
  end

  defp attach_telemetry do
    handler = make_ref()
    test_pid = self()

    :telemetry.attach(
      {:authz_test, handler},
      [:bullx, :authz, :invalid_persisted_data],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    Process.put(:authz_test_telemetry_handler, handler)
  end

  defp detach_telemetry do
    case Process.get(:authz_test_telemetry_handler) do
      nil ->
        :ok

      handler ->
        :telemetry.detach({:authz_test, handler})
        Process.delete(:authz_test_telemetry_handler)
    end
  end
end
