defmodule Ankole.AuthZTest do
  use Ankole.DataCase, async: false

  alias Ankole.AuthZ
  alias Ankole.AuthZ.ExternalBinding
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.Principals

  import Ankole.PrincipalsFixtures

  describe "authorization snapshots" do
    test "computed group grants are evaluated by the kernel" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("computed-human")})

      assert {:ok, group} =
               AuthZ.create_principal_group(%{
                 name: "active_humans_#{System.unique_integer([:positive])}",
                 display_name: "Active Humans",
                 kind: :computed,
                 computed_condition: ~s(principal.type == "human" && principal.status == "active")
               })

      assert {:ok, _grant} =
               AuthZ.upsert_permission_grant(%{
                 group_id: group.id,
                 resource_pattern: "workspace:**",
                 action: "read",
                 condition: "true"
               })

      assert :ok = AuthZ.authorize(principal.uid, "workspace:default", "read", %{source: "test"})

      assert {:ok, decision} =
               AuthZ.authorize_decision(principal.uid, "workspace:default", "read", %{})

      assert decision["status"] == "allow"
      assert group.id in decision["effectiveGroupIds"]
    end

    test "static membership grants allow and batch authorization reports first denial" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("static-human")})

      assert {:ok, group} =
               AuthZ.create_principal_group(%{
                 name: "workspace_readers_#{System.unique_integer([:positive])}",
                 display_name: "Workspace Readers"
               })

      assert {:ok, _membership} = AuthZ.add_principal_to_group(principal.uid, group.id)

      assert {:ok, _grant} =
               AuthZ.upsert_permission_grant(%{
                 group_name: group.name,
                 resource_pattern: "workspace:**",
                 action: "read"
               })

      assert :ok = AuthZ.authorize(principal.uid, "workspace:default", "read", %{})
      assert :ok = AuthZ.authorize_permission(principal.uid, "workspace:default:read", %{})
      assert :ok = AuthZ.authorize_permission(principal.uid, "workspace:project:123:read", %{})
      assert AuthZ.allowed?(principal.uid, "workspace:default", "read", %{})
      refute AuthZ.allowed?(principal.uid, "workspace:default", "write", %{})

      assert {:error, {:forbidden, "write"}} =
               AuthZ.authorize_all(principal.uid, "workspace:default", ["read", "write"], %{})
    end

    test "actions are exact and request resources cannot be grant patterns" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("exact-action-human")})

      assert {:ok, _grant} =
               AuthZ.upsert_permission_grant(%{
                 principal_uid: principal.uid,
                 resource_pattern: "workspace:**",
                 action: "Read"
               })

      assert :ok = AuthZ.authorize(principal.uid, "workspace:default", "Read", %{})

      assert {:error, {:forbidden, "read"}} =
               AuthZ.authorize(principal.uid, "workspace:default", "read", %{})

      assert {:error, :invalid_request} =
               AuthZ.authorize(principal.uid, "workspace:*", "Read", %{})

      assert {:error, :invalid_request} =
               AuthZ.authorize(principal.uid, "workspace:default", "Read", %{source: :test})
    end

    test "persisted membership rows for computed groups are ignored as static memberships" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("computed-membership-human")})

      assert {:ok, group} =
               AuthZ.create_principal_group(%{
                 name: "inactive_computed_#{System.unique_integer([:positive])}",
                 display_name: "Inactive Computed",
                 kind: :computed,
                 computed_condition: "false"
               })

      Repo.insert!(%Membership{principal_uid: principal.uid, group_id: group.id})

      assert {:ok, _grant} =
               AuthZ.upsert_permission_grant(%{
                 group_id: group.id,
                 resource_pattern: "workspace:**",
                 action: "read"
               })

      assert {:error, {:forbidden, "read"}} =
               AuthZ.authorize(principal.uid, "workspace:default", "read", %{})
    end

    test "invalid persisted grants emit diagnostics and fail closed" do
      test_pid = self()
      handler_id = {:authz_diagnostic, self(), make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:ankole, :authz, :invalid_persisted_data],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:authz_diagnostic, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{principal: principal} = human_fixture(%{uid: unique_uid("diagnostic-human")})

      assert {:ok, _grant} =
               AuthZ.upsert_permission_grant(%{
                 principal_uid: principal.uid,
                 resource_pattern: "workspace:**",
                 action: "read",
                 condition: "principal.uid"
               })

      assert {:error, {:forbidden, "read"}} =
               AuthZ.authorize(principal.uid, "workspace:default", "read", %{})

      assert_receive {:authz_diagnostic, [:ankole, :authz, :invalid_persisted_data], %{count: 1},
                      %{
                        kind: "condition_result_type",
                        action: "read",
                        resource_pattern: "workspace:**"
                      }}
    end

    test "invalid persisted computed groups expose diagnostics and fail closed" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("computed-diagnostic-human")})

      compile_group = dirty_computed_group("dirty_compile", "principal.")
      execution_group = dirty_computed_group("dirty_execution", "1 / 0 == 1")
      result_type_group = dirty_computed_group("dirty_result_type", "principal.uid")

      assert {:ok, decision} =
               AuthZ.authorize_decision(principal.uid, "workspace:default", "read", %{})

      assert decision["status"] == "deny"

      diagnostics = Map.new(decision["diagnostics"], &{&1["id"], &1})

      assert %{
               "kind" => "computed_group_condition_compile",
               "action" => nil,
               "resourcePattern" => nil,
               "reason" => compile_reason
             } = Map.fetch!(diagnostics, compile_group.id)

      assert is_binary(compile_reason)

      assert %{
               "kind" => "computed_group_condition_execution",
               "action" => nil,
               "resourcePattern" => nil,
               "reason" => execution_reason
             } = Map.fetch!(diagnostics, execution_group.id)

      assert is_binary(execution_reason)

      assert %{
               "kind" => "computed_group_condition_result_type",
               "action" => nil,
               "resourcePattern" => nil,
               "reason" => result_type_reason
             } = Map.fetch!(diagnostics, result_type_group.id)

      assert is_binary(result_type_reason)
    end

    test "disabled principals deny before grants are considered" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("disabled-human")})

      assert {:ok, group} =
               AuthZ.create_principal_group(%{
                 name: "disabled_readers_#{System.unique_integer([:positive])}",
                 display_name: "Disabled Readers"
               })

      assert {:ok, _membership} = AuthZ.add_principal_to_group(principal.uid, group.id)

      assert {:ok, _grant} =
               AuthZ.upsert_permission_grant(%{
                 group_id: group.id,
                 resource_pattern: "workspace:**",
                 action: "read"
               })

      assert {:ok, _principal} = Principals.disable_principal(principal.uid)

      assert {:ok, snapshot} =
               AuthZ.build_authorization_snapshot(principal.uid, "workspace:default", "read", %{})

      assert snapshot["principal"]["status"] == "disabled"

      assert {:error, :principal_disabled} =
               AuthZ.authorize(principal.uid, "workspace:default", "read", %{})
    end
  end

  describe "root admin safety" do
    test "invalid root init attempts do not create built-ins or close setup" do
      refute AuthZ.root_initialized?()
      assert :ok = AuthZ.ensure_root_init_open()

      assert {:error, :not_found} = AuthZ.root_init_admin(unique_uid("missing-admin"))

      refute AuthZ.root_initialized?()
      assert :ok = AuthZ.ensure_root_init_open()
    end

    test "built-in group shape drift fails root init with an explicit conflict" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("shape-drift-admin")})

      Repo.insert!(%Group{
        id: Ankole.Kernel.gen_uuid_v7(),
        name: "admin",
        display_name: "Wrong Admin",
        kind: :computed,
        built_in: true,
        computed_condition: "true",
        metadata: %{}
      })

      assert {:error, {:built_in_group_conflict, "admin"}} =
               AuthZ.root_init_admin(principal.uid)

      refute AuthZ.root_initialized?()
    end

    test "root init creates built-ins and prevents disabling the last active human admin" do
      first_admin = human_fixture(%{uid: unique_uid("first-admin")})

      refute AuthZ.root_initialized?()

      assert {:ok, %{admin_group: admin_group, all_humans_group: all_humans_group}} =
               AuthZ.root_init_admin(first_admin.principal.uid)

      assert admin_group.name == "admin"
      assert all_humans_group.name == "all_humans"
      assert AuthZ.root_initialized?()
      assert {:error, :root_init_closed} = AuthZ.ensure_root_init_open()

      assert {:error, :root_init_closed} = AuthZ.root_init_admin(first_admin.principal.uid)

      assert {:error, :last_active_human_admin} =
               Principals.disable_principal(first_admin.principal.uid)

      second_admin = human_fixture(%{uid: unique_uid("second-admin")})

      assert {:ok, _membership} =
               AuthZ.add_principal_to_group(second_admin.principal.uid, "admin")

      assert {:ok, _principal} = Principals.disable_principal(first_admin.principal.uid)
    end

    test "non-human admin members do not satisfy the active human admin safety check" do
      first_admin = human_fixture(%{uid: unique_uid("human-admin")})
      agent = agent_fixture(%{uid: unique_uid("agent-admin")})

      assert {:ok, _root} = AuthZ.root_init_admin(first_admin.principal.uid)
      assert {:ok, _membership} = AuthZ.add_principal_to_group(agent.principal.uid, "admin")
      assert {:ok, :deleted} = AuthZ.remove_principal_from_group(agent.principal.uid, "admin")

      assert {:ok, _membership} = AuthZ.add_principal_to_group(agent.principal.uid, "admin")

      assert {:error, :last_active_human_admin} =
               Principals.disable_principal(first_admin.principal.uid)
    end
  end

  describe "external group bindings" do
    test "external group lookup returns only static group bindings" do
      external_id = "dept-#{System.unique_integer([:positive])}"

      assert {:ok, group} =
               AuthZ.create_principal_group(%{
                 name: "static_external_#{System.unique_integer([:positive])}",
                 display_name: "Static External"
               })

      assert {:ok, _binding} =
               AuthZ.upsert_external_binding(%{
                 provider: "lark",
                 external_id: external_id,
                 group_id: group.id
               })

      assert AuthZ.external_group_ids("lark", external_id) == [group.id]

      assert {:ok, computed_group} =
               AuthZ.create_principal_group(%{
                 name: "dirty_computed_external_#{System.unique_integer([:positive])}",
                 display_name: "Dirty Computed External",
                 kind: :computed,
                 computed_condition: "true"
               })

      dirty_external_id = "dirty-dept-#{System.unique_integer([:positive])}"

      Repo.insert!(%ExternalBinding{
        provider: "lark",
        external_id: dirty_external_id,
        group_id: computed_group.id,
        metadata: %{}
      })

      assert AuthZ.external_group_ids("lark", dirty_external_id) == []
    end

    test "external subjects can bind only to static groups" do
      assert {:ok, group} =
               AuthZ.create_principal_group(%{
                 name: "computed_external_#{System.unique_integer([:positive])}",
                 display_name: "Computed External",
                 kind: :computed,
                 computed_condition: "true"
               })

      assert {:error, :computed_group} =
               AuthZ.upsert_external_binding(%{
                 provider: "lark",
                 external_id: "dept-#{System.unique_integer([:positive])}",
                 group_id: group.id
               })
    end
  end

  describe "permission grants" do
    test "upsert is atomic by the natural owner resource action condition key" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("upsert-grant-owner")})

      attrs = %{
        principal_uid: principal.uid,
        resource_pattern: "workspace:**",
        action: "read",
        condition: "true",
        description: "first",
        metadata: %{"version" => 1}
      }

      assert {:ok, first} = AuthZ.upsert_permission_grant(attrs)

      assert {:ok, second} =
               attrs
               |> Map.put(:description, "updated")
               |> Map.put(:metadata, %{"version" => 2})
               |> AuthZ.upsert_permission_grant()

      assert second.id == first.id
      assert second.description == "updated"
      assert second.metadata == %{"version" => 2}
    end
  end

  describe "validation" do
    test "changesets delegate rule syntax to the kernel" do
      assert {:error, group_changeset} =
               AuthZ.create_principal_group(%{
                 name: "bad_condition_#{System.unique_integer([:positive])}",
                 display_name: "Bad Condition",
                 kind: :computed,
                 computed_condition: "principal."
               })

      assert %{computed_condition: [_]} = errors_on(group_changeset)

      %{principal: principal} = human_fixture(%{uid: unique_uid("bad-grant-owner")})

      assert {:error, grant_changeset} =
               AuthZ.upsert_permission_grant(%{
                 principal_uid: principal.uid,
                 resource_pattern: "workspace:[",
                 action: "read",
                 condition: "true"
               })

      assert %{resource_pattern: [_]} = errors_on(grant_changeset)
    end
  end

  defp dirty_computed_group(prefix, condition) do
    Repo.insert!(%Group{
      id: Ankole.Kernel.gen_uuid_v7(),
      name: "#{prefix}_#{System.unique_integer([:positive])}",
      display_name: "Dirty Computed",
      kind: :computed,
      built_in: false,
      computed_condition: condition,
      metadata: %{}
    })
  end
end
