defmodule BullXAccounts.AuthZTest do
  use BullX.DataCase, async: false

  import ExUnit.CaptureLog

  alias BullXAccounts.AuthZ.Cache
  alias BullXAccounts.PermissionGrant
  alias BullXAccounts.User
  alias BullXAccounts.UserGroup
  alias BullXAccounts.UserGroupMembership

  setup do
    Cache.invalidate_all()

    previous = Application.get_env(:bullx, :accounts)

    Application.put_env(
      :bullx,
      :accounts,
      Keyword.merge(previous || [], authz_cache_ttl_ms: 60_000)
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:bullx, :accounts)
        value -> Application.put_env(:bullx, :accounts, value)
      end

      Cache.invalidate_all()
    end)

    :ok
  end

  describe "decision flow" do
    test "direct user grant authorizes a matching resource and action" do
      user = insert_user!(display_name: "Alice")

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "web_console",
          action: "read"
        })

      assert :ok = BullXAccounts.authorize(user, "web_console", "read")
      assert {:error, :forbidden} = BullXAccounts.authorize(user, "web_console", "write")
    end

    test "static group grant authorizes a member" do
      user = insert_user!(display_name: "Alice")
      {:ok, group} = BullXAccounts.create_user_group(%{name: "engineers", type: :static})

      :ok = BullXAccounts.add_user_to_group(user, group)

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          group_id: group.id,
          resource_pattern: "web_console",
          action: "read"
        })

      assert :ok = BullXAccounts.authorize(user, "web_console", "read")
    end

    test "computed group grant authorizes when expression evaluates true" do
      user = insert_user!(display_name: "Alice")

      {:ok, group} =
        BullXAccounts.create_user_group(%{
          name: "active-users",
          type: :computed,
          computed_expression: %{"op" => "user_status", "eq" => "active"}
        })

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          group_id: group.id,
          resource_pattern: "web_console",
          action: "read"
        })

      assert :ok = BullXAccounts.authorize(user, "web_console", "read")

      banned = insert_user!(display_name: "Bob", status: :banned)

      assert {:error, :user_banned} = BullXAccounts.authorize(banned, "web_console", "read")
    end

    test "banned users are denied even with direct grants" do
      banned = insert_user!(display_name: "Banned", status: :banned)

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: banned.id,
          resource_pattern: "web_console",
          action: "read"
        })

      assert {:error, :user_banned} = BullXAccounts.authorize(banned, "web_console", "read")
    end

    test "actions do not imply other actions" do
      user = insert_user!(display_name: "Alice")

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "web_console",
          action: "write"
        })

      assert :ok = BullXAccounts.authorize(user, "web_console", "write")
      assert {:error, :forbidden} = BullXAccounts.authorize(user, "web_console", "read")
    end

    test "permission_key splits at the final colon" do
      user = insert_user!(display_name: "Alice")

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "gateway_channel:workplace-main",
          action: "write"
        })

      assert :ok =
               BullXAccounts.authorize_permission(user, "gateway_channel:workplace-main:write")

      assert {:error, :invalid_request} = BullXAccounts.authorize_permission(user, "no_colon")
    end

    test "list_user_groups merges static memberships and matching computed groups" do
      user = insert_user!(display_name: "Alice")
      {:ok, eng} = BullXAccounts.create_user_group(%{name: "engineers", type: :static})

      {:ok, active} =
        BullXAccounts.create_user_group(%{
          name: "active-users",
          type: :computed,
          computed_expression: %{"op" => "user_status", "eq" => "active"}
        })

      :ok = BullXAccounts.add_user_to_group(user, eng)

      {:ok, groups} = BullXAccounts.list_user_groups(user)

      group_ids = Enum.map(groups, & &1.id) |> Enum.sort()
      assert Enum.sort([eng.id, active.id]) == group_ids
    end
  end

  describe "resource pattern matching" do
    test "wildcard '*' matches any character including ':'" do
      user = insert_user!(display_name: "Alice")

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "gateway_channel:*",
          action: "write"
        })

      assert :ok =
               BullXAccounts.authorize(user, "gateway_channel:workplace-main", "write")

      assert :ok = BullXAccounts.authorize(user, "gateway_channel:foo:bar", "write")

      assert {:error, :forbidden} = BullXAccounts.authorize(user, "other_resource", "write")
    end
  end

  describe "Cedar conditions" do
    test "Cedar 'true' allows after match" do
      user = insert_user!(display_name: "Alice")

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "web_console",
          action: "read",
          condition: "true"
        })

      assert :ok = BullXAccounts.authorize(user, "web_console", "read")
    end

    test "Cedar 'false' denies that grant" do
      user = insert_user!(display_name: "Alice")

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "web_console",
          action: "read",
          condition: "false"
        })

      assert {:error, :forbidden} = BullXAccounts.authorize(user, "web_console", "read")
    end

    test "Cedar conditions can read precomputed Elixir-side facts under context.request" do
      user = insert_user!(display_name: "Alice")

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "web_console",
          action: "read",
          condition: "context.request.business_hours"
        })

      assert :ok =
               BullXAccounts.authorize(user, "web_console", "read", %{
                 "business_hours" => true
               })

      assert {:error, :forbidden} =
               BullXAccounts.authorize(user, "web_console", "read", %{
                 "business_hours" => false
               })
    end

    test "missing context fields fail closed without invalid_persisted_data telemetry" do
      user = insert_user!(display_name: "Alice")

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "web_console",
          action: "read",
          condition: "context.request.business_hours"
        })

      attach_telemetry()

      assert {:error, :forbidden} = BullXAccounts.authorize(user, "web_console", "read")

      refute_received {:telemetry_event, [:bullx, :authz, :invalid_persisted_data], _, _}
    after
      detach_telemetry()
    end

    test "Cedar evaluation injection attempts fail closed via condition validation" do
      user = insert_user!(display_name: "Alice")

      assert {:error, changeset} =
               BullXAccounts.create_permission_grant(%{
                 user_id: user.id,
                 resource_pattern: "web_console",
                 action: "read",
                 condition: "true } unless { false"
               })

      assert errors_on(changeset)[:condition] |> Enum.any?()

      assert {:error, changeset} =
               BullXAccounts.create_permission_grant(%{
                 user_id: user.id,
                 resource_pattern: "web_console",
                 action: "read",
                 condition: "true }; permit(principal, action, resource) when { true"
               })

      assert errors_on(changeset)[:condition] |> Enum.any?()
    end
  end

  describe "request normalization" do
    test "nil users, malformed ids, empty fields, and bad contexts return :invalid_request" do
      user = insert_user!(display_name: "Alice")

      assert {:error, :invalid_request} = BullXAccounts.authorize(nil, "web_console", "read")

      assert {:error, :invalid_request} =
               BullXAccounts.authorize("not-a-uuid", "web_console", "read")

      assert {:error, :invalid_request} =
               BullXAccounts.authorize(%User{id: "not-a-uuid"}, "web_console", "read")

      assert {:error, :invalid_request} = BullXAccounts.authorize(user, "", "read")
      assert {:error, :invalid_request} = BullXAccounts.authorize(user, "web_console", "")

      assert {:error, :invalid_request} =
               BullXAccounts.authorize(user, "web_console", "read:more")

      assert {:error, :invalid_request} =
               BullXAccounts.authorize(user, "web_console", "read", %{"k" => 1.5})

      assert {:error, :invalid_request} =
               BullXAccounts.authorize(user, "web_console", "read", %{"k" => self()})

      assert {:error, :invalid_request} =
               BullXAccounts.authorize(user, "web_console", "read", %{"k" => {1, 2}})

      assert {:error, :invalid_request} =
               BullXAccounts.authorize(user, "web_console", "read", %{"k" => :admin})
    end

    test "well-formed missing user returns :not_found without raising" do
      missing_id = "019dc9bc-0000-7000-8000-000000000001"

      assert {:error, :not_found} = BullXAccounts.authorize(missing_id, "web_console", "read")
    end

    test "id-based public mutations return :not_found for malformed ids" do
      assert {:error, :not_found} =
               BullXAccounts.update_user_group("not-a-uuid", %{description: "new"})

      assert {:error, :not_found} = BullXAccounts.delete_user_group("not-a-uuid")

      assert {:error, :not_found} =
               BullXAccounts.update_permission_grant("not-a-uuid", %{description: "new"})

      assert {:error, :not_found} = BullXAccounts.delete_permission_grant("not-a-uuid")
      assert {:error, :not_found} = BullXAccounts.update_user_status("not-a-uuid", :banned)
    end

    test "resource and action remain strings, not atoms" do
      user = insert_user!(display_name: "Alice")
      resource = "exotic-resource-#{System.unique_integer([:positive])}"
      action = "exotic-action-#{System.unique_integer([:positive])}"
      request_resource = "exotic-resource-#{System.unique_integer([:positive])}"
      request_action = "another-action-#{System.unique_integer([:positive])}"

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: resource,
          action: action
        })

      _result =
        BullXAccounts.authorize(
          user,
          request_resource,
          request_action
        )

      assert_raise ArgumentError, fn -> String.to_existing_atom(resource) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(action) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(request_resource) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(request_action) end
    end
  end

  describe "computed group cycles and invalid persisted data" do
    test "cyclic computed group expressions return false without crashing" do
      user = insert_user!(display_name: "Alice")

      {:ok, _bystander} = BullXAccounts.create_user_group(%{name: "anchor", type: :static})

      {:ok, group} =
        BullXAccounts.create_user_group(%{
          name: "circular",
          type: :computed,
          computed_expression: %{"op" => "group_member", "group" => "anchor"}
        })

      Repo.update_all(
        from(g in UserGroup, where: g.id == ^group.id),
        set: [
          computed_expression: %{"op" => "group_member", "group" => "circular"}
        ]
      )

      attach_telemetry()

      capture_log([level: :error], fn ->
        assert {:ok, groups} = BullXAccounts.list_user_groups(user)
        refute Enum.any?(groups, &(&1.id == group.id))
      end)

      assert_received {:telemetry_event, [:bullx, :authz, :invalid_persisted_data], _,
                       %{kind: :computed_group}}
    after
      detach_telemetry()
    end

    test "invalid persisted Cedar conditions emit invalid_persisted_data telemetry" do
      user = insert_user!(display_name: "Alice")

      {:ok, grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "web_console",
          action: "read",
          condition: "true"
        })

      Repo.update_all(
        from(g in BullXAccounts.PermissionGrant, where: g.id == ^grant.id),
        set: [condition: "this is invalid cedar"]
      )

      attach_telemetry()

      capture_log([level: :error], fn ->
        assert {:error, :forbidden} = BullXAccounts.authorize(user, "web_console", "read")
      end)

      assert_received {:telemetry_event, [:bullx, :authz, :invalid_persisted_data], _,
                       %{kind: :condition}}
    after
      detach_telemetry()
    end
  end

  describe "caching" do
    test "repeated authorize/4 calls are served from the cache" do
      user = insert_user!(display_name: "Alice")

      {:ok, grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "web_console",
          action: "read"
        })

      assert :ok = BullXAccounts.authorize(user, "web_console", "read")

      Repo.delete!(grant)

      assert :ok = BullXAccounts.authorize(user, "web_console", "read")

      Cache.invalidate_all()

      assert {:error, :forbidden} = BullXAccounts.authorize(user, "web_console", "read")
    end

    test "grant create/update/delete invalidates the cache" do
      user = insert_user!(display_name: "Alice")

      assert {:error, :forbidden} = BullXAccounts.authorize(user, "web_console", "read")

      {:ok, grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "web_console",
          action: "read"
        })

      assert :ok = BullXAccounts.authorize(user, "web_console", "read")

      :ok = BullXAccounts.delete_permission_grant(grant)

      assert {:error, :forbidden} = BullXAccounts.authorize(user, "web_console", "read")
    end

    test "user status change invalidates the cache" do
      user = insert_user!(display_name: "Alice")

      {:ok, _grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "web_console",
          action: "read"
        })

      assert :ok = BullXAccounts.authorize(user, "web_console", "read")

      {:ok, banned} = BullXAccounts.update_user_status(user, :banned)

      assert {:error, :user_banned} = BullXAccounts.authorize(banned, "web_console", "read")
    end

    test "default cache TTL is 60_000 milliseconds" do
      assert BullX.Config.Accounts.accounts_authz_cache_ttl_ms!() == 60_000
    end

    test "TTL of 0 disables decision caching" do
      put_authz_ttl(0)

      user = insert_user!(display_name: "Alice")

      {:ok, grant} =
        BullXAccounts.create_permission_grant(%{
          user_id: user.id,
          resource_pattern: "web_console",
          action: "read"
        })

      assert :ok = BullXAccounts.authorize(user, "web_console", "read")

      Repo.delete!(grant)

      assert {:error, :forbidden} = BullXAccounts.authorize(user, "web_console", "read")
    end
  end

  describe "admin group" do
    test "AuthZ bootstrap creates the built-in admin group idempotently" do
      Repo.delete_all(PermissionGrant)
      Repo.delete_all(UserGroupMembership)
      Repo.delete_all(UserGroup)

      BullXAccounts.AuthZ.Bootstrap.run()
      BullXAccounts.AuthZ.Bootstrap.run()

      groups = Repo.all(from g in UserGroup, where: g.name == "admin")

      assert length(groups) == 1
      [admin] = groups
      assert admin.built_in == true
      assert admin.type == :static

      assert Repo.aggregate(UserGroupMembership, :count) == 0

      assert [%PermissionGrant{} = grant] =
               Repo.all(from g in PermissionGrant, where: g.group_id == ^admin.id)

      assert grant.resource_pattern == "web_console:*"
      assert grant.action == "write"
      assert grant.condition == "true"
    end

    test "AuthZ bootstrap repairs and deduplicates the admin web console grant" do
      Repo.delete_all(PermissionGrant)
      {:ok, admin, _status} = BullXAccounts.AuthZ.ensure_built_in_admin_group()

      {:ok, bad_grant} =
        BullXAccounts.create_permission_grant(%{
          group_id: admin.id,
          resource_pattern: "web_console:*",
          action: "write",
          condition: "false"
        })

      {:ok, duplicate} =
        BullXAccounts.create_permission_grant(%{
          group_id: admin.id,
          resource_pattern: "web_console:*",
          action: "write",
          condition: "true"
        })

      BullXAccounts.AuthZ.Bootstrap.run()

      grants =
        Repo.all(
          from g in PermissionGrant,
            where:
              g.group_id == ^admin.id and g.resource_pattern == "web_console:*" and
                g.action == "write"
        )

      assert [%PermissionGrant{id: id, condition: "true"}] = grants
      assert id == bad_grant.id
      refute Repo.get(PermissionGrant, duplicate.id)
    end

    test "the built-in admin group cannot be deleted via the public API" do
      BullXAccounts.AuthZ.Bootstrap.run()
      admin = Repo.get_by!(UserGroup, name: "admin")

      assert {:error, :built_in_group} = BullXAccounts.delete_user_group(admin)
    end

    test "removing the final static member of the admin group is rejected" do
      BullXAccounts.AuthZ.Bootstrap.run()
      admin = Repo.get_by!(UserGroup, name: "admin")

      user = insert_user!(display_name: "Alice")
      :ok = BullXAccounts.add_user_to_group(user, admin)

      assert {:error, :last_admin_member} = BullXAccounts.remove_user_from_group(user, admin)

      other = insert_user!(display_name: "Bob")
      :ok = BullXAccounts.add_user_to_group(other, admin)

      assert :ok = BullXAccounts.remove_user_from_group(user, admin)
    end

    test "concurrent removals cannot empty the admin group" do
      BullXAccounts.AuthZ.Bootstrap.run()
      admin = Repo.get_by!(UserGroup, name: "admin")

      alice = insert_user!(display_name: "Alice")
      bob = insert_user!(display_name: "Bob")

      :ok = BullXAccounts.add_user_to_group(alice, admin)
      :ok = BullXAccounts.add_user_to_group(bob, admin)

      test_pid = self()

      tasks =
        for user <- [alice, bob] do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())
            BullXAccounts.remove_user_from_group(user, admin)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :last_admin_member})) == 1

      remaining =
        Repo.aggregate(
          from(m in UserGroupMembership, where: m.group_id == ^admin.id),
          :count
        )

      assert remaining == 1
    end

    test "groups referenced by computed expressions cannot be deleted" do
      {:ok, anchor} = BullXAccounts.create_user_group(%{name: "anchor", type: :static})

      {:ok, _computed} =
        BullXAccounts.create_user_group(%{
          name: "consumer",
          type: :computed,
          computed_expression: %{"op" => "group_member", "group" => "anchor"}
        })

      assert {:error, :group_in_use} = BullXAccounts.delete_user_group(anchor)
    end
  end

  defp insert_user!(attrs) do
    %User{}
    |> User.changeset(Map.new(attrs))
    |> Repo.insert!()
  end

  defp put_authz_ttl(ttl) do
    accounts = Application.get_env(:bullx, :accounts) || []
    Application.put_env(:bullx, :accounts, Keyword.put(accounts, :authz_cache_ttl_ms, ttl))
  end

  defp attach_telemetry do
    handler = make_ref()
    test_pid = self()

    :telemetry.attach(
      {:authz_test, handler},
      [:bullx, :authz, :invalid_persisted_data],
      fn event, measurements, metadata, _ ->
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
