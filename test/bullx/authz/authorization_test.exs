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
          principal_id: human.id,
          resource_pattern: "web_console",
          action: "read"
        })

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          principal_id: agent.id,
          resource_pattern: "capability:browser_use",
          action: "execute"
        })

      assert :ok = AuthZ.authorize(human, "web_console", "read")
      assert :ok = AuthZ.authorize(agent.id, "capability:browser_use", "execute")
      assert {:error, :forbidden} = AuthZ.authorize(human, "web_console", "write")
    end

    test "group grants use resource patterns and exact action matching" do
      human = human!("group-human")
      {:ok, group} = AuthZ.create_principal_group(%{name: "operators"})

      :ok = AuthZ.add_principal_to_group(human, group)

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          group_id: group.id,
          resource_pattern: "gateway_channel:*",
          action: "write"
        })

      assert :ok = AuthZ.authorize(human, "gateway_channel:workplace-main", "write")
      assert :ok = AuthZ.authorize_permission(human, "gateway_channel:foo:bar:write")
      assert {:error, :forbidden} = AuthZ.authorize(human, "gateway_channel:foo", "read")
      assert {:error, :invalid_request} = AuthZ.authorize(human, "gateway_channel:*", "write")
    end

    test "disabled Principals deny before grants are evaluated" do
      human = human!("disabled-human")

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          principal_id: human.id,
          resource_pattern: "web_console",
          action: "read"
        })

      assert {:ok, disabled} = Principals.disable_principal(human)
      assert {:error, :principal_disabled} = AuthZ.authorize(disabled, "web_console", "read")
    end

    test "Cedar request context controls matching grants" do
      human = human!("cedar-human")

      {:ok, _grant} =
        AuthZ.create_permission_grant(%{
          principal_id: human.id,
          resource_pattern: "web_console",
          action: "read",
          condition: "context.request.business_hours"
        })

      assert :ok = AuthZ.authorize(human, "web_console", "read", %{business_hours: true})

      assert {:error, :forbidden} =
               AuthZ.authorize(human, "web_console", "read", %{business_hours: false})

      assert {:error, :forbidden} = AuthZ.authorize(human, "web_console", "read", %{})
    end

    test "invalid persisted Cedar conditions fail closed and emit telemetry" do
      human = human!("invalid-cedar-human")

      {:ok, grant} =
        AuthZ.create_permission_grant(%{
          principal_id: human.id,
          resource_pattern: "web_console",
          action: "read",
          condition: "true"
        })

      Repo.update_all(
        from(g in PermissionGrant, where: g.id == ^grant.id),
        set: [condition: "this is invalid cedar"]
      )

      attach_telemetry()

      capture_log([level: :error], fn ->
        assert {:error, :forbidden} = AuthZ.authorize(human, "web_console", "read")
      end)

      assert_received {:telemetry_event, [:bullx, :authz, :invalid_persisted_data], %{count: 1},
                       %{kind: :condition, id: grant_id, action: "read"}}

      assert grant_id == grant.id
    after
      detach_telemetry()
    end
  end

  describe "group management and admin recoverability" do
    test "built-in admin group is protected and non-magical" do
      assert :ok = AuthZ.reconcile_bootstrap_admin_membership()

      admin = Repo.get_by!(PrincipalGroup, name: "admin")
      assert admin.built_in == true
      assert {:error, :built_in_group} = AuthZ.delete_principal_group(admin)
      assert [] = Repo.all(from grant in PermissionGrant, where: grant.group_id == ^admin.id)
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

  describe "bootstrap admin handoff" do
    test "bootstrap activation grants admin membership after commit" do
      {:ok, %{code: plaintext}} = Principals.create_activation_code(nil, %{"bootstrap" => true})

      assert {:ok, principal, _identity} =
               Principals.consume_activation_code(
                 plaintext,
                 channel_input("bootstrap-admin", "bootstrap-admin@example.com")
               )

      admin = Repo.get_by!(PrincipalGroup, name: "admin")
      assert membership_exists?(principal.id, admin.id)
    end

    test "non-bootstrap activation does not add admin membership" do
      {:ok, %{code: plaintext}} = Principals.create_activation_code(nil, %{"purpose" => "test"})

      assert {:ok, principal, _identity} =
               Principals.consume_activation_code(
                 plaintext,
                 channel_input("ordinary-activation", "ordinary@example.com")
               )

      case Repo.get_by(PrincipalGroup, name: "admin") do
        nil -> refute Repo.exists?(from membership in PrincipalGroupMembership, select: 1)
        admin -> refute membership_exists?(principal.id, admin.id)
      end
    end

    test "bootstrap worker repairs missed admin membership handoff" do
      {:ok, %{code: plaintext}} = Principals.create_activation_code(nil, %{"bootstrap" => true})

      assert {:ok, principal, _identity} =
               Principals.consume_activation_code(
                 plaintext,
                 channel_input("repair-admin", "repair@example.com")
               )

      admin = Repo.get_by!(PrincipalGroup, name: "admin")

      Repo.delete_all(
        from membership in PrincipalGroupMembership,
          where: membership.principal_id == ^principal.id and membership.group_id == ^admin.id
      )

      refute membership_exists?(principal.id, admin.id)

      BullX.AuthZ.Bootstrap.run()

      assert membership_exists?(principal.id, admin.id)
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
        profile: %{main_llm: "llm.primary", goals: "Help", soul: "Calm"}
      })

    principal
  end

  defp channel_input(external_id, email) do
    %{
      adapter: "feishu",
      channel_id: "workplace",
      external_id: external_id,
      profile: %{"email" => email},
      metadata: %{}
    }
  end

  defp membership_exists?(principal_id, group_id) do
    Repo.exists?(
      from membership in PrincipalGroupMembership,
        where: membership.principal_id == ^principal_id and membership.group_id == ^group_id,
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
