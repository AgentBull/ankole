defmodule Ankole.AuthZ.GrantConcurrencyTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias Ankole.Files.Access
  alias Ankole.Pod.{Pages}

  setup %{tenant: tenant} do
    owner = human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{title: "Grant target"})

    {:ok, group} = Access.space_group()
    for grant <- Access.grants(group_id: group.id), do: AuthZ.delete_permission_grant(grant.id)

    {:ok, grant} =
      AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "tenant_console:other",
        action: "update"
      })

    on_exit(fn -> Repo.with_tenant(tenant.id, fn -> cleanup_tenant!(tenant) end) end)
    %{owner: owner, grant: grant, page: page}
  end

  test "operator deletion serializes with promotion and a Pod writer", ctx do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _, _, meta, _ ->
        if Process.get(:pause_grant_delete) &&
             String.starts_with?(meta.query, "SELECT") &&
             String.contains?(meta.query, ~s(FROM "permission_grants")) do
          reads = Process.get(:grant_reads, 0) + 1
          Process.put(:grant_reads, reads)

          if reads == 2 do
            Process.delete(:pause_grant_delete)
            send(parent, {:delete_read, backend_pid()})
            receive do: (:continue -> :ok)
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    deletion =
      Task.async(
        Repo.bind_tenant(fn ->
          Process.put(:pause_grant_delete, true)
          operator(:delete, ctx.grant.id)
        end)
      )

    assert_receive {:delete_read, delete_backend}, 5_000

    promotion =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.checkout(fn ->
            send(parent, {:promotion_started, backend_pid()})

            Ankole.Ash.run_action(Grant, :update_operator_grant, %{
              id: ctx.grant.id,
              resource_pattern: "tenant_console:drive_space"
            })
          end)
        end)
      )

    assert_receive {:promotion_started, promotion_backend}, 5_000

    case await_promotion(promotion, promotion_backend, delete_backend) do
      :blocked ->
        send(deletion.pid, :continue)
        assert {:ok, _} = Task.await(deletion, 5_000)
        assert {:error, :not_found} = Ankole.Errors.reason(Task.await(promotion, 5_000))

      {:committed, grant} ->
        assert grant.resource_pattern == "tenant_console:drive_space"
        writer = start_writer(ctx.owner.uid, parent)
        assert_receive {:writer_open, writer_backend}, 5_000
        send(deletion.pid, :continue)
        assert_blocked_by(delete_backend, writer_backend)
        assert {:ok, _} = AuthZ.get_permission_grant(ctx.grant.id)
        send(writer.pid, :commit)
        assert {:ok, %{title: "Authorized write"}} = Task.await(writer, 5_000)
        assert {:ok, _} = Task.await(deletion, 5_000)
    end

    assert {:error, :not_found} = AuthZ.get_permission_grant(ctx.grant.id)
  end

  for operation <- [:update, :delete] do
    test "operator #{operation} enforces the page-grant policy after a concurrent promotion",
         ctx do
      parent = self()

      promotion =
        Task.async(
          Repo.bind_tenant(fn ->
            Repo.transact(fn ->
              {:ok, grant} =
                AuthZ.Grants.update_permission_grant(ctx.grant, %{
                  action: "node_view",
                  resource_pattern: "drive:**:#{ctx.page.id}:node"
                })

              send(parent, {:page_grant_uncommitted, backend_pid()})
              receive do: (:commit -> {:ok, grant})
            end)
          end)
        )

      assert_receive {:page_grant_uncommitted, promoter_backend}, 5_000

      mutation =
        Task.async(
          Repo.bind_tenant(fn ->
            Repo.checkout(fn ->
              send(parent, {:mutation_started, backend_pid()})
              operator(unquote(operation), ctx.grant.id)
            end)
          end)
        )

      assert_receive {:mutation_started, mutation_backend}, 5_000
      assert_blocked_by(mutation_backend, promoter_backend)
      send(promotion.pid, :commit)
      assert {:ok, promoted} = Task.await(promotion, 5_000)
      assert {:error, error} = Task.await(mutation, 5_000)

      case unquote(operation) do
        :delete -> assert error == :page_grant
        :update -> assert %{action: ["cannot change on a Pod page grant"]} = errors_on(error)
      end

      assert {:ok, persisted} = AuthZ.get_permission_grant(ctx.grant.id)
      assert persisted.action == "node_view"
      assert persisted.resource_pattern == promoted.resource_pattern
    end
  end

  test "a captured grant cannot overwrite a later operator promotion", ctx do
    assert {:ok, %{resource_pattern: "tenant_console:drive_space"}} =
             Ankole.Ash.run_action(Grant, :update_operator_grant, %{
               id: ctx.grant.id,
               resource_pattern: "tenant_console:drive_space"
             })

    assert {:ok, updated} =
             AuthZ.update_permission_grant(ctx.grant, %{description: "Description only"})

    assert updated.resource_pattern == "tenant_console:drive_space"
    assert updated.description == "Description only"
    assert {:ok, persisted} = AuthZ.get_permission_grant(ctx.grant.id)
    assert persisted.resource_pattern == "tenant_console:drive_space"
  end

  for operation <- [:update, :delete] do
    test "operator #{operation} of a runtime grant does not wait for unrelated tree writes",
         ctx do
      {:ok, grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: ctx.owner.uid,
          resource_pattern: "agent:runtime-only:tool:read",
          action: "invoke"
        })

      parent = self()

      writer =
        Task.async(
          Repo.bind_tenant(fn ->
            Repo.transact(fn ->
              :ok = Pages.lock_tree()
              send(parent, :tree_locked)
              receive do: (:commit -> {:ok, :released})
            end)
          end)
        )

      assert_receive :tree_locked, 5_000

      mutation =
        Task.async(Repo.bind_tenant(fn -> operator(unquote(operation), grant.id) end))

      try do
        assert {:ok, {:ok, _}} = Task.yield(mutation, 2_000)
      after
        send(writer.pid, :commit)
        assert {:ok, :released} = Task.await(writer, 5_000)
        Task.shutdown(mutation)
      end
    end
  end

  for operation <- [:update, :delete] do
    test "domain #{operation} of a Console grant does not wait for unrelated tree writes", ctx do
      parent = self()
      writer = start_writer(ctx.owner.uid, parent, %{private_owner_uid: ctx.owner.uid})
      assert_receive {:writer_open, _backend}, 5_000

      mutation =
        Task.async(
          Repo.bind_tenant(fn ->
            mutate(:domain, unquote(operation), ctx.grant.id, %{description: "Console grant"})
          end)
        )

      try do
        assert {:ok, {:ok, _}} = Task.yield(mutation, 2_000)
      after
        send(writer.pid, :commit)
        assert {:ok, _} = Task.await(writer, 5_000)
        Task.shutdown(mutation)
      end
    end
  end

  for boundary <- [:domain, :operator], operation <- [:update, :delete] do
    test "#{boundary} #{operation} rejects a Pod promotion after the initial read", ctx do
      parent = self()
      pause_initial_grant_read()

      mutation =
        Task.async(
          Repo.bind_tenant(fn ->
            Process.put(:pause_initial_grant_read, true)

            mutate(unquote(boundary), unquote(operation), ctx.grant.id, %{
              description: "Concurrent change"
            })
          end)
        )

      assert_receive :initial_grant_read, 5_000

      assert {:ok, promoted} =
               AuthZ.update_permission_grant(ctx.grant.id, %{
                 resource_pattern: "tenant_console:drive_space"
               })

      writer = start_writer(ctx.owner.uid, parent, %{private_owner_uid: ctx.owner.uid})
      assert_receive {:writer_open, _backend}, 5_000

      try do
        send(mutation.pid, :continue)
        assert {:ok, result} = Task.yield(mutation, 2_000)
        assert {:error, :stale} = Ankole.Errors.reason(result)
        assert {:ok, persisted} = AuthZ.get_permission_grant(ctx.grant.id)
        assert persisted.resource_pattern == promoted.resource_pattern
        assert persisted.description == promoted.description
      after
        send(writer.pid, :commit)
        assert {:ok, _} = Task.await(writer, 5_000)
        Task.shutdown(mutation)
      end

      assert {:ok, _} =
               mutate(unquote(boundary), unquote(operation), ctx.grant.id, %{
                 description: "Concurrent change"
               })
    end
  end

  for boundary <- [:domain, :operator] do
    test "#{boundary} promotion waits for the tree before locking the Grant", ctx do
      parent = self()
      writer = start_writer(ctx.owner.uid, parent, %{private_owner_uid: ctx.owner.uid})
      assert_receive {:writer_open, writer_backend}, 5_000

      promotion =
        Task.async(
          Repo.bind_tenant(fn ->
            Repo.checkout(fn ->
              send(parent, {:promotion_started, backend_pid()})

              mutate(unquote(boundary), :update, ctx.grant.id, %{
                resource_pattern: "tenant_console:drive_space"
              })
            end)
          end)
        )

      assert_receive {:promotion_started, promoter_backend}, 5_000
      assert_blocked_by(promoter_backend, writer_backend)

      mutation =
        Task.async(
          Repo.bind_tenant(fn ->
            AuthZ.update_permission_grant(ctx.grant.id, %{description: "Concurrent description"})
          end)
        )

      try do
        assert {:ok, {:ok, _}} = Task.yield(mutation, 2_000)
      after
        send(writer.pid, :commit)
        assert {:ok, _} = Task.await(writer, 5_000)
        Task.shutdown(mutation)
      end

      assert {:ok, promoted} = Task.await(promotion, 5_000)
      assert promoted.resource_pattern == "tenant_console:drive_space"
      assert promoted.description == "Concurrent description"
    end
  end

  for boundary <- [:domain, :operator] do
    test "#{boundary} update rechecks the proposed scope after a concurrent change", ctx do
      assert {:ok, _} = AuthZ.update_permission_grant(ctx.grant.id, %{action: "read"})
      parent = self()
      pause_initial_grant_read()

      mutation =
        Task.async(
          Repo.bind_tenant(fn ->
            Process.put(:pause_initial_grant_read, true)
            mutate(unquote(boundary), :update, ctx.grant.id, %{action: "update"})
          end)
        )

      assert_receive :initial_grant_read, 5_000

      assert {:ok, promoted} =
               AuthZ.update_permission_grant(ctx.grant.id, %{
                 resource_pattern: "tenant_console:drive_space"
               })

      assert promoted.action == "read"
      writer = start_writer(ctx.owner.uid, parent, %{private_owner_uid: ctx.owner.uid})
      assert_receive {:writer_open, _backend}, 5_000

      try do
        send(mutation.pid, :continue)
        assert {:ok, result} = Task.yield(mutation, 2_000)
        assert {:error, :stale} = Ankole.Errors.reason(result)
        assert {:ok, persisted} = AuthZ.get_permission_grant(ctx.grant.id)
        assert persisted.resource_pattern == promoted.resource_pattern
        assert persisted.action == "read"
      after
        send(writer.pid, :commit)
        assert {:ok, _} = Task.await(writer, 5_000)
        Task.shutdown(mutation)
      end

      assert {:ok, %{action: "update"}} =
               mutate(unquote(boundary), :update, ctx.grant.id, %{action: "update"})
    end
  end

  defp pause_initial_grant_read do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _, _, meta, _ ->
        if Process.get(:pause_initial_grant_read) &&
             String.starts_with?(meta.query, "SELECT") &&
             String.contains?(meta.query, ~s(FROM "permission_grants")) do
          Process.delete(:pause_initial_grant_read)
          send(parent, :initial_grant_read)
          receive do: (:continue -> :ok)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp mutate(:domain, :update, id, attrs), do: AuthZ.update_permission_grant(id, attrs)
  defp mutate(:domain, :delete, id, _attrs), do: AuthZ.delete_permission_grant(id)

  defp mutate(:operator, :update, id, attrs),
    do: Ankole.Ash.run_action(Grant, :update_operator_grant, Map.put(attrs, :id, id))

  defp mutate(:operator, :delete, id, _attrs), do: operator(:delete, id)

  defp start_writer(uid, parent, attrs \\ %{}) do
    Task.async(
      Repo.bind_tenant(fn ->
        Repo.transact(fn ->
          {:ok, page} =
            Pages.create_in_tx(
              Ankole.PrincipalsFixtures.actor_fixture(uid),
              Map.put(attrs, :title, "Authorized write")
            )

          send(parent, {:writer_open, backend_pid()})
          receive do: (:commit -> {:ok, page})
        end)
      end)
    )
  end

  defp await_promotion(task, promoter, deleter),
    do: await_promotion(task, promoter, deleter, System.monotonic_time(:millisecond) + 5_000)

  defp await_promotion(task, promoter, deleter, deadline) do
    cond do
      blocked_by?(promoter, deleter) ->
        :blocked

      result = Task.yield(task, 5) ->
        assert {:ok, {:ok, grant}} = result
        {:committed, grant}

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("promotion neither committed nor waited for deletion")

      true ->
        await_promotion(task, promoter, deleter, deadline)
    end
  end

  defp operator(:update, id),
    do: Ankole.Ash.run_action(Grant, :update_operator_grant, %{id: id, action: "read"})

  defp operator(:delete, id),
    do: Ankole.Ash.run_action(Grant, :delete_operator_grant, %{id: id})

  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp assert_blocked_by(waiter, blocker),
    do: await_blocker(waiter, blocker, System.monotonic_time(:millisecond) + 5_000)

  defp await_blocker(waiter, blocker, deadline) do
    cond do
      blocked_by?(waiter, blocker) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("backend #{waiter} did not wait for #{blocker}")

      true ->
        Process.sleep(5)
        await_blocker(waiter, blocker, deadline)
    end
  end

  defp blocked_by?(waiter, blocker) do
    [[blocked]] =
      Repo.query!("SELECT $1::int = ANY(pg_blocking_pids($2::int))", [blocker, waiter]).rows

    blocked
  end
end
