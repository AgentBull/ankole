defmodule Ankole.TenantAdministrationTransactionsIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.{AppConfigure, AuthZ, Tenants}
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AuthZ.{Grant, Group, Membership}
  alias Ankole.Pod.{Page, Pages}
  alias Ecto.Adapters.SQL.Sandbox

  @assignment_key "tenants.privileged_tenant_id"
  @pause_key {__MODULE__, :pause_assignment}

  setup %{tenant: source} do
    original = Repo.get_by!(SiteConfig, scope: "global", key: @assignment_key)
    middle = create_committed_tenant()
    final = create_committed_tenant()

    on_exit(fn -> restore_fixture(original, [source, middle, final]) end)

    :ok = set_privileged_tenant(source)
    :ok = Tenants.ensure_scaffold(source)
    %{principal: source_admin} = human_fixture()
    %{principal: middle_admin} = Repo.with_tenant(middle.id, fn -> human_fixture() end)
    %{principal: final_admin} = Repo.with_tenant(final.id, fn -> human_fixture() end)

    initial_grants =
      Map.new([source, middle, final], fn tenant ->
        {tenant.id,
         Repo.with_tenant(tenant.id, fn ->
           site_admin = Repo.get_by(Group, name: "siteadmin")

           Repo.all(from g in Grant, order_by: g.id)
           |> Enum.reject(fn grant -> site_admin && grant.group_id == site_admin.id end)
         end)}
      end)

    {:ok, %{admin_group: source_group}} = first_site_admin_fixture(source_admin.uid)

    %{
      initial_grants: initial_grants,
      source: source,
      source_admin: source_admin,
      source_group: source_group,
      middle: middle,
      middle_admin: middle_admin,
      final: final,
      final_admin: final_admin
    }
  end

  test "concurrent transfers serialize on the assignment and the waiter removes the committed intermediate owner",
       context do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        &__MODULE__.pause_assignment/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    first =
      start(fn ->
        Tenants.transfer_site_administration(context.middle, context.middle_admin.uid)
      end)

    first_pid = first.task.pid
    assert_receive {:assignment_locked, ^first_pid}, 5_000

    second =
      start(fn ->
        Tenants.transfer_site_administration(context.final, context.final_admin.uid)
      end)

    try do
      refute first.backend_pid == second.backend_pid
      assert_blocked_by(second, first)
      assert_privileged(context.source)
      assert AuthZ.site_admin?(context.source_admin.uid)
      assert_no_site_admin_state(context.middle, context.initial_grants[context.middle.id])
      assert_no_site_admin_state(context.final, context.initial_grants[context.final.id])

      send(first.task.pid, :continue)
      assert {:ok, %{id: middle_id}} = Task.await(first.task, 5_000)
      assert middle_id == context.middle.id
      second_pid = second.task.pid
      assert_receive {:assignment_locked, ^second_pid}, 5_000

      assert_privileged(context.middle)
      refute AuthZ.site_admin?(context.source_admin.uid)
      assert AuthZ.site_admin?(context.middle_admin.uid)
      refute AuthZ.site_admin?(context.final_admin.uid)

      assert_no_site_admin_state(
        context.source,
        context.initial_grants[context.source.id],
        context.source_admin.uid
      )

      assert_no_site_admin_state(context.final, context.initial_grants[context.final.id])

      middle_group =
        Repo.with_tenant(context.middle.id, fn -> Repo.get_by!(Group, name: "siteadmin") end)

      send(second.task.pid, :continue)
      assert {:ok, %{id: final_id}} = Task.await(second.task, 5_000)
      assert final_id == context.final.id
      assert_privileged(context.final)
      refute AuthZ.site_admin?(context.source_admin.uid)
      refute AuthZ.site_admin?(context.middle_admin.uid)
      assert AuthZ.site_admin?(context.final_admin.uid)

      assert_no_site_admin_state(
        context.source,
        context.initial_grants[context.source.id],
        context.source_admin.uid
      )

      assert_no_site_admin_state(
        context.middle,
        context.initial_grants[context.middle.id],
        context.middle_admin.uid
      )

      for {tenant, group} <- [
            {context.source, context.source_group},
            {context.middle, middle_group}
          ] do
        Repo.with_tenant(tenant.id, fn ->
          refute Repo.exists?(from grant in Grant, where: grant.group_id == ^group.id)
          refute Repo.exists?(from member in Membership, where: member.group_id == ^group.id)
        end)
      end

      Repo.with_tenant(context.final.id, fn ->
        group = Repo.get_by!(Group, name: "siteadmin", built_in: true)

        assert Repo.all(
                 from member in Membership,
                   where: member.group_id == ^group.id,
                   select: member.principal_uid
               ) == [context.final_admin.uid]

        expected_rules =
          for pattern <- ["site_console:**", "tenant_console:**"],
              action <- ~w(decrypt delete read reset sync update),
              do: {pattern, action}

        assert Repo.all(
                 from grant in Grant,
                   where: grant.group_id == ^group.id,
                   order_by: [grant.resource_pattern, grant.action],
                   select: {grant.resource_pattern, grant.action}
               ) == expected_rules

        assert AuthZ.pod_admin?(context.final_admin.uid)
      end)
    after
      send(first.task.pid, :continue)
      send(second.task.pid, :continue)
      Task.shutdown(first.task, :brutal_kill)
      Task.shutdown(second.task, :brutal_kill)
    end
  end

  test "transferring administration refreshes deleted group grants and inherited Page anchors",
       context do
    owner = actor_fixture(context.source_admin.uid)
    viewer = human_fixture().principal
    assert {:ok, parent} = Pages.create(owner, %{private_owner_uid: context.source_admin.uid})
    assert {:ok, child} = Pages.create(owner, %{parent_id: parent.id})
    assert {:ok, grandchild} = Pages.create(owner, %{parent_id: child.id})

    assert {:ok, _} =
             AuthZ.create_permission_grant(%{
               principal_uid: viewer.uid,
               resource_pattern: "drive:**:#{parent.id}:**",
               action: "node_view"
             })

    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               group_id: context.source_group.id,
               resource_pattern: "drive:**:#{child.id}:**",
               action: "node_view"
             })

    assert %{has_local_acl: true, is_acl_anchor: true, acl_anchor_id: child_anchor} =
             Repo.get!(Page, child.id)

    assert child_anchor == child.id

    assert %{has_local_acl: false, is_acl_anchor: false, acl_anchor_id: ^child_anchor} =
             Repo.get!(Page, grandchild.id)

    assert {:ok, _} =
             Tenants.transfer_site_administration(context.middle, context.middle_admin.uid)

    refute Repo.get(Grant, grant.id)
    refute Repo.get(Group, context.source_group.id)

    for page <- [child, grandchild] do
      assert %{has_local_acl: false, is_acl_anchor: false, acl_anchor_id: parent_anchor} =
               Repo.get!(Page, page.id)

      assert parent_anchor == parent.id
      assert {:ok, _} = Pages.authorize(actor_fixture(viewer.uid), page.id, "node_view")
    end
  end

  # Pause after the real assignment row lock, inside the production transaction.
  # Each transfer retains its own commit and cache-publication boundary.
  def pause_assignment(_event, _measurements, metadata, parent) do
    if Process.get(@pause_key) == true and metadata.source == "site_app_configurations" and
         String.contains?(metadata.query, "FOR UPDATE") do
      Process.delete(@pause_key)
      send(parent, {:assignment_locked, self()})

      receive do
        :continue -> :ok
      after
        10_000 -> raise "test did not release the assignment lock"
      end
    end
  end

  defp start(fun) do
    parent = self()
    tenant_id = Repo.tenant_id!()

    task =
      Task.async(fn ->
        Repo.with_tenant(tenant_id, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:database_task, self(), backend_pid})
            Process.put(@pause_key, true)
            fun.()
          end)
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    pid = task.pid
    assert_receive {:database_task, ^pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid}
  end

  defp assert_blocked_by(waiter, holder) do
    assert {:ok, true} =
             wait_until(deadline(5_000), fn ->
               %{rows: [[blocked]]} =
                 Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [
                   holder.backend_pid,
                   waiter.backend_pid
                 ])

               blocked
             end)

    %{rows: [[query]]} =
      Repo.query!("SELECT query FROM pg_stat_activity WHERE pid = $1", [waiter.backend_pid])

    assert query =~ ~s(FROM "site_app_configurations")
    assert query =~ "FOR UPDATE"
  end

  defp assert_privileged(tenant) do
    assert {:ok, %{id: id}} = Tenants.privileged()
    assert id == tenant.id
  end

  defp assert_no_site_admin_state(tenant, initial_grants, pod_admin_uid \\ nil) do
    Repo.with_tenant(tenant.id, fn ->
      refute Repo.get_by(Group, name: "siteadmin")
      current_grants = Repo.all(from g in Grant, order_by: g.id)
      rule_fields = Grant.__schema__(:fields) -- [:updated_at]

      actual = Enum.map(current_grants, &Map.take(&1, rule_fields))
      expected = Enum.map(initial_grants, &Map.take(&1, rule_fields))

      assert actual == expected,
             inspect(%{added: actual -- expected, removed: expected -- actual}, limit: :infinity)

      if pod_admin_uid do
        pod_admin = Repo.get_by!(Group, name: "pod_admin", built_in: true)

        assert Repo.all(from m in Membership, select: {m.group_id, m.principal_uid}) ==
                 [{pod_admin.id, pod_admin_uid}]

        assert AuthZ.pod_admin?(pod_admin_uid)
      else
        refute Repo.exists?(Membership)
      end
    end)
  end

  defp restore_fixture(original, tenants) do
    Sandbox.unboxed_run(Repo, fn ->
      {:ok, :restored} =
        Repo.transact(fn repo ->
          {1, _} =
            repo.update_all(
              from(config in SiteConfig,
                where: config.scope == "global" and config.key == @assignment_key
              ),
              set: [
                value: original.value,
                inserted_at: original.inserted_at,
                updated_at: original.updated_at
              ]
            )

          # These tenants had no site-admin group before this fixture. Restore
          # that state with the assignment before lifecycle deletion starts.
          for tenant <- tenants do
            Repo.with_tenant(tenant.id, fn ->
              Ankole.Pod.Pages.lock_tree()

              if group = repo.get_by(Group, name: "siteadmin", built_in: true) do
                repo.delete_all(from grant in Grant, where: grant.group_id == ^group.id)
                repo.delete!(group)
              end
            end)
          end

          {:ok, :restored}
        end)

      {:ok, _} = AppConfigure.Cache.refresh("global", @assignment_key)

      for tenant <- tenants do
        Repo.with_tenant(tenant.id, fn -> cleanup_tenant!(tenant) end)
      end
    end)
  end
end
