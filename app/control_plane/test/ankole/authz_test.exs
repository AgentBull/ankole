defmodule Ankole.AuthZTest do
  use Ankole.DataCase, async: true

  alias Ankole.AuthZ
  alias Ankole.AuthZ.ExternalBinding
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership

  import Ankole.PrincipalsFixtures

  describe "authorization snapshots" do
    test "independent checks use the public boundary and retain explicit grant restrictions" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("checks-human")})

      {:ok, grant} =
        AuthZ.upsert_permission_grant(%{
          principal_uid: principal.uid,
          resource_pattern: "workspace:**",
          action: "read",
          condition: ~s(resource == "workspace:first")
        })

      assert {:ok, [true, false, false, true, false]} =
               AuthZ.authorize_checks(principal.uid, [
                 %{resource: "workspace:first", action: "read"},
                 %{resource: "workspace:second", action: "read"},
                 %{resource: "workspace:first", action: "write"},
                 %{resource: "workspace:first", action: "read", grant_ids: [grant.id]},
                 %{resource: "workspace:first", action: "read", grant_ids: []}
               ])

      for checks <- [
            [],
            [%{resource: "workspace:*", action: "read"}],
            [%{resource: "workspace:first", action: ""}],
            [%{resource: "workspace:first", action: "read", grant_ids: nil}],
            [%{resource: "workspace:first", action: "read", grant_ids: [123]}]
          ] do
        assert {:error, :invalid_request} = AuthZ.authorize_checks(principal.uid, checks)
      end
    end

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
      assert group.id in decision["effectiveGroupIDs"]
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
      assert :ok = Ankole.AuthZ.authorize(principal.uid, "workspace:default", "read", %{})
      assert :ok = Ankole.AuthZ.authorize(principal.uid, "workspace:project:123", "read", %{})
      assert AuthZ.allowed?(principal.uid, "workspace:default", "read", %{})
      refute AuthZ.allowed?(principal.uid, "workspace:default", "write", %{})

      assert {:ok, decision} =
               AuthZ.authorize_all_decision(
                 principal.uid,
                 "workspace:default",
                 ["read", "write"],
                 %{}
               )

      assert {:error, {:forbidden, "write"}} = Ankole.AuthZ.Decision.result(decision)
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

      assert {:ok, _membership} =
               Repo.transact(fn ->
                 Ankole.AuthZ.Store.insert_membership(group.id, principal.uid)
               end)

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

      assert {:ok, _principal} =
               Ankole.PrincipalsFixtures.disable_principal_fixture(principal.uid)

      assert {:ok, snapshot} =
               Ankole.AuthZ.Snapshot.build_authorization_snapshot(
                 principal.uid,
                 "workspace:default",
                 "read",
                 %{}
               )

      assert snapshot["principal"]["status"] == "disabled"

      assert {:error, :principal_disabled} =
               AuthZ.authorize(principal.uid, "workspace:default", "read", %{})
    end
  end

  describe "root admin safety" do
    test "root init uses the scaffold and prevents disabling the last active human admin" do
      first_admin = human_fixture(%{uid: unique_uid("first-admin")})

      assert {:ok, %{admin_group: admin_group}} =
               Ankole.PrincipalsFixtures.first_site_admin_fixture(first_admin.principal.uid)

      assert admin_group.name == "siteadmin"

      assert {:ok, %{membership: retried_membership}} =
               Ankole.PrincipalsFixtures.first_site_admin_fixture(first_admin.principal.uid)

      assert retried_membership.principal_uid == first_admin.principal.uid

      other_human = human_fixture(%{uid: unique_uid("other-root-init")})

      assert {:error, :root_init_closed} =
               Ankole.PrincipalsFixtures.first_site_admin_fixture(other_human.principal.uid)

      assert {:error, :last_active_human_admin} =
               Ankole.PrincipalsFixtures.disable_principal_fixture(first_admin.principal.uid)

      second_admin = human_fixture(%{uid: unique_uid("second-admin")})

      assert {:ok, _membership} =
               AuthZ.add_principal_to_group(second_admin.principal.uid, "siteadmin")

      assert {:ok, _} = AuthZ.add_principal_to_group(second_admin.principal.uid, "pod_admin")

      assert {:ok, _principal} =
               Ankole.PrincipalsFixtures.disable_principal_fixture(first_admin.principal.uid)
    end

    test "admin group accepts only active humans" do
      first_admin = human_fixture(%{uid: unique_uid("human-admin")})
      agent = agent_fixture(%{uid: unique_uid("agent-admin")})

      assert {:ok, _root} =
               Ankole.PrincipalsFixtures.first_site_admin_fixture(first_admin.principal.uid)

      assert {:error, :not_human} = AuthZ.add_principal_to_group(agent.principal.uid, "siteadmin")

      assert {:error, :last_active_human_admin} =
               Ankole.PrincipalsFixtures.disable_principal_fixture(first_admin.principal.uid)
    end
  end

  describe "external group bindings" do
    test "external group lookup returns only static group bindings" do
      external_id = "dept-#{System.unique_integer([:positive])}"

      assert {:ok, group} =
               AuthZ.create_principal_group(%{
                 name: "static_external_#{System.unique_integer([:positive])}",
                 display_name: "Static External",
                 domain: :directory
               })

      assert {:ok, _binding} =
               AuthZ.upsert_external_binding(%{
                 provider: "lark",
                 external_kind: :directory_department,
                 external_id: external_id,
                 group_id: group.id
               })

      assert AuthZ.external_group_ids("lark", :directory_department, external_id) == [group.id]

      assert {:ok, computed_group} =
               AuthZ.create_principal_group(%{
                 name: "dirty_computed_external_#{System.unique_integer([:positive])}",
                 display_name: "Dirty Computed External",
                 kind: :computed,
                 computed_condition: "true"
               })

      dirty_external_id = "dirty-dept-#{System.unique_integer([:positive])}"

      persist_binding(%{
        provider: "lark",
        external_kind: :directory_department,
        external_id: dirty_external_id,
        group_id: computed_group.id,
        metadata: %{}
      })

      assert AuthZ.external_group_ids("lark", :directory_department, dirty_external_id) == []

      assert {:ok, operator_group} =
               AuthZ.create_principal_group(%{
                 name: "dirty_operator_external_#{System.unique_integer([:positive])}",
                 display_name: "Dirty Operator External"
               })

      dirty_operator_external_id = "dirty-operator-dept-#{System.unique_integer([:positive])}"

      persist_binding(%{
        provider: "lark",
        external_kind: :directory_department,
        external_id: dirty_operator_external_id,
        group_id: operator_group.id,
        metadata: %{}
      })

      assert AuthZ.external_group_ids("lark", :directory_department, dirty_operator_external_id) ==
               []
    end

    test "external directory membership sync only touches directory-domain groups" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("directory-member")})

      assert {:ok, managed_group} =
               AuthZ.create_principal_group(%{
                 name: "lark_managed_#{System.unique_integer([:positive])}",
                 display_name: "Lark Managed",
                 domain: :directory
               })

      assert {:ok, unmarked_group} =
               AuthZ.create_principal_group(%{
                 name: "lark_unmarked_#{System.unique_integer([:positive])}",
                 display_name: "Lark Unmarked"
               })

      assert {:ok, _binding} =
               AuthZ.upsert_external_binding(%{
                 provider: "lark-main",
                 external_kind: :directory_department,
                 external_id: "od_managed",
                 group_id: managed_group.id
               })

      persist_binding(%{
        provider: "lark-main",
        external_kind: :directory_department,
        external_id: "od_unmarked",
        group_id: unmarked_group.id,
        metadata: %{}
      })

      assert {:ok, %{synced_group_ids: [managed_group_id]}} =
               AuthZ.sync_external_directory_group_memberships(
                 "lark-main",
                 principal.uid,
                 ["od_managed", "od_unmarked"]
               )

      assert managed_group_id == managed_group.id
      assert Repo.get_by(Membership, principal_uid: principal.uid, group_id: managed_group.id)
      refute Repo.get_by(Membership, principal_uid: principal.uid, group_id: unmarked_group.id)

      assert {:ok, _membership} = AuthZ.add_principal_to_group(principal.uid, unmarked_group.id)

      assert {:ok, %{synced_group_ids: [], removed_memberships: 1}} =
               AuthZ.sync_external_directory_group_memberships("lark-main", principal.uid, [])

      refute Repo.get_by(Membership, principal_uid: principal.uid, group_id: managed_group.id)
      assert Repo.get_by(Membership, principal_uid: principal.uid, group_id: unmarked_group.id)
    end

    test "external directory membership sync expands department ancestors from binding metadata" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("directory-child-member")})

      assert {:ok, parent_group} =
               AuthZ.create_principal_group(%{
                 name: "lark_parent_#{System.unique_integer([:positive])}",
                 display_name: "Lark Parent",
                 domain: :directory
               })

      assert {:ok, child_group} =
               AuthZ.create_principal_group(%{
                 name: "lark_child_#{System.unique_integer([:positive])}",
                 display_name: "Lark Child",
                 domain: :directory
               })

      assert {:ok, _binding} =
               AuthZ.upsert_external_binding(%{
                 provider: "lark-main",
                 external_kind: :directory_department,
                 external_id: "od_parent",
                 group_id: parent_group.id,
                 metadata: %{"parentExternalID" => "0"}
               })

      assert {:ok, _binding} =
               AuthZ.upsert_external_binding(%{
                 provider: "lark-main",
                 external_kind: :directory_department,
                 external_id: "od_child",
                 group_id: child_group.id,
                 metadata: %{"parentExternalID" => "od_parent"}
               })

      assert {:ok, directory_group_index} = AuthZ.external_directory_group_index("lark-main")

      assert {:ok, %{synced_group_ids: synced_group_ids}} =
               AuthZ.sync_external_directory_group_memberships(
                 "lark-main",
                 principal.uid,
                 ["od_child"],
                 directory_group_index: directory_group_index
               )

      assert Enum.sort(synced_group_ids) == Enum.sort([parent_group.id, child_group.id])
      assert Repo.get_by(Membership, principal_uid: principal.uid, group_id: parent_group.id)
      assert Repo.get_by(Membership, principal_uid: principal.uid, group_id: child_group.id)

      assert {:ok, %{synced_group_ids: [], removed_memberships: 2}} =
               AuthZ.sync_external_directory_group_memberships("lark-main", principal.uid, [])

      refute Repo.get_by(Membership, principal_uid: principal.uid, group_id: parent_group.id)
      refute Repo.get_by(Membership, principal_uid: principal.uid, group_id: child_group.id)
    end

    test "external directory ancestor expansion is cycle safe" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("directory-cycle-member")})

      assert {:ok, first_group} =
               AuthZ.create_principal_group(%{
                 name: "lark_cycle_first_#{System.unique_integer([:positive])}",
                 display_name: "Lark Cycle First",
                 domain: :directory
               })

      assert {:ok, second_group} =
               AuthZ.create_principal_group(%{
                 name: "lark_cycle_second_#{System.unique_integer([:positive])}",
                 display_name: "Lark Cycle Second",
                 domain: :directory
               })

      assert {:ok, _binding} =
               AuthZ.upsert_external_binding(%{
                 provider: "lark-main",
                 external_kind: :directory_department,
                 external_id: "od_cycle_first",
                 group_id: first_group.id,
                 metadata: %{"parentExternalID" => "od_cycle_second"}
               })

      assert {:ok, _binding} =
               AuthZ.upsert_external_binding(%{
                 provider: "lark-main",
                 external_kind: :directory_department,
                 external_id: "od_cycle_second",
                 group_id: second_group.id,
                 metadata: %{"parentExternalID" => "od_cycle_first"}
               })

      assert {:ok, %{synced_group_ids: synced_group_ids}} =
               AuthZ.sync_external_directory_group_memberships(
                 "lark-main",
                 principal.uid,
                 ["od_cycle_first"]
               )

      assert Enum.sort(synced_group_ids) == Enum.sort([first_group.id, second_group.id])
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
                 external_kind: :directory_department,
                 external_id: "dept-#{System.unique_integer([:positive])}",
                 group_id: group.id
               })
    end

    test "external binding rejects mismatched external kind and group domain" do
      assert {:ok, operator_group} =
               AuthZ.create_principal_group(%{
                 name: "operator_external_#{System.unique_integer([:positive])}",
                 display_name: "Operator External"
               })

      assert {:error, :group_domain_mismatch} =
               AuthZ.upsert_external_binding(%{
                 provider: "lark",
                 external_kind: :directory_department,
                 external_id: "dept-#{System.unique_integer([:positive])}",
                 group_id: operator_group.id
               })
    end
  end

  describe "synced group membership" do
    test "rejects a same-named group of another domain instead of raising" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("synced-member")})
      name = "signal_source_collision_#{System.unique_integer([:positive])}"

      assert {:ok, operator_group} =
               AuthZ.create_principal_group(%{
                 name: name,
                 display_name: "Operator-owned collision",
                 domain: :operator
               })

      group_attrs = %{
        name: name,
        display_name: "Signal source group",
        domain: :signal_source,
        metadata: %{}
      }

      assert {:error, :group_domain_mismatch} =
               AuthZ.ensure_synced_group_member(group_attrs, principal.uid)

      # An existing membership in the same-named operator group must not
      # satisfy the member-exists fast path either — the domain still
      # mismatches.
      assert {:ok, _membership} =
               Repo.transact(fn ->
                 Ankole.AuthZ.Store.insert_membership(operator_group.id, principal.uid)
               end)

      assert {:error, :group_domain_mismatch} =
               AuthZ.ensure_synced_group_member(group_attrs, principal.uid)
    end

    test "creates the group and accumulates membership for the requested domain" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("synced-add")})
      name = "signal_source_member_#{System.unique_integer([:positive])}"

      group_attrs = %{
        name: name,
        display_name: "Signal source group",
        domain: :signal_source,
        metadata: %{}
      }

      assert :ok = AuthZ.ensure_synced_group_member(group_attrs, principal.uid)
      assert :ok = AuthZ.ensure_synced_group_member(group_attrs, principal.uid)

      group = Repo.get_by!(Group, name: name)
      assert group.domain == :signal_source
      assert Repo.get_by(Membership, group_id: group.id, principal_uid: principal.uid)
    end
  end

  describe "static group member deltas" do
    test "applies one add and remove set atomically in stable uid order" do
      %{principal: added_b} = human_fixture(%{uid: unique_uid("delta-b")})
      %{principal: added_a} = human_fixture(%{uid: unique_uid("delta-a")})
      %{principal: removed} = human_fixture(%{uid: unique_uid("delta-removed")})

      assert {:ok, group} =
               AuthZ.create_principal_group(%{
                 name: "directory_delta_#{System.unique_integer([:positive])}",
                 display_name: "Directory Delta",
                 kind: :static,
                 domain: :directory
               })

      assert {:ok, _result} =
               AuthZ.replace_static_group_members(group.id, :directory, [removed.uid])

      assert {:ok, delta} =
               AuthZ.apply_static_group_member_delta(
                 group.id,
                 :directory,
                 [added_b.uid, added_a.uid],
                 [removed.uid]
               )

      assert delta.added_principal_uids == Enum.sort([added_a.uid, added_b.uid])
      assert delta.removed_principal_uids == [removed.uid]
      assert delta.removed_memberships == 1

      assert {:ok, members} = AuthZ.list_group_members(group.id)
      assert Enum.map(members, & &1.principal.uid) == Enum.sort([added_a.uid, added_b.uid])
    end

    test "rolls back the complete delta when one added principal is missing" do
      %{principal: valid} = human_fixture(%{uid: unique_uid("delta-valid")})

      assert {:ok, group} =
               AuthZ.create_principal_group(%{
                 name: "directory_delta_rollback_#{System.unique_integer([:positive])}",
                 display_name: "Directory Delta Rollback",
                 kind: :static,
                 domain: :directory
               })

      assert {:error, :not_found} =
               AuthZ.apply_static_group_member_delta(
                 group.id,
                 :directory,
                 [valid.uid, "missing-principal"],
                 []
               )

      assert {:ok, []} = AuthZ.list_group_members(group.id)
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
    test "resource actions delegate rule syntax to the kernel" do
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

  describe "computed group member preview" do
    test "returns active Principals matching the condition ordered by display name" do
      %{principal: human} = human_fixture(%{uid: unique_uid("preview-human")})
      %{principal: agent} = agent_fixture(%{uid: unique_uid("preview-agent")})

      assert {:ok, members} =
               AuthZ.preview_computed_group_members(~s(principal.type == "human"))

      member_uids = Enum.map(members, & &1.uid)
      assert human.uid in member_uids
      refute agent.uid in member_uids

      display_names = Enum.map(members, & &1.display_name)
      assert display_names == Enum.sort(display_names)
    end

    test "disabled Principals never match" do
      %{principal: principal} = human_fixture(%{uid: unique_uid("preview-disabled")})
      assert {:ok, _disabled} = Ankole.PrincipalsFixtures.disable_principal_fixture(principal.uid)

      assert {:ok, members} =
               AuthZ.preview_computed_group_members(~s(principal.type == "human"))

      refute principal.uid in Enum.map(members, & &1.uid)
    end

    test "invalid conditions return an error instead of an empty list" do
      assert {:error, reason} = AuthZ.preview_computed_group_members("principal.")
      assert is_binary(reason)
      assert {:error, _reason} = AuthZ.preview_computed_group_members(nil)
    end
  end

  defp persist_binding(attrs) do
    {:ok, binding} =
      Repo.transact(fn _repo ->
        Ankole.Ash.create(ExternalBinding, :bind_in_tx, attrs)
      end)

    binding
  end

  defp dirty_computed_group(prefix, condition) do
    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: "#{prefix}_#{System.unique_integer([:positive])}",
        display_name: "Dirty Computed",
        kind: :computed,
        computed_condition: "true"
      })

    {1, _} =
      Repo.update_all(from(g in Group, where: g.id == ^group.id),
        set: [computed_condition: condition]
      )

    Repo.get!(Group, group.id)
  end
end
