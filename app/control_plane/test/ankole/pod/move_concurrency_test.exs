defmodule Ankole.Pod.MoveConcurrencyTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AuthZ
  alias Ankole.Pod.{Page, Pages}

  @moduletag sandbox: false

  setup %{tenant: tenant} do
    owner = human_fixture().principal
    editor = human_fixture().principal
    viewer = human_fixture().principal

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "**",
        action: "update"
      })

    {:ok, _} = Pages.set_space(owner.uid, "edit")
    {:ok, left} = Pages.create(owner.uid, %{})
    {:ok, right} = Pages.create(owner.uid, %{})
    {:ok, page} = Pages.create(owner.uid, %{parent_id: left.id})

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        Repo.delete_all(
          from j in Oban.Job, where: fragment("?->>'tenant_id' = ?", j.args, ^tenant.id)
        )

        for table <- Ankole.Tenants.Jobs.Delete.tenant_tables() do
          Repo.query!("DELETE FROM #{table} WHERE tenant_id = $1::text::uuid", [tenant.id])
        end

        Repo.delete!(tenant)
      end)
    end)

    %{owner: owner, editor: editor, viewer: viewer, left: left, right: right, page: page}
  end

  test "the checked move holds grant and tree changes until the durable commit", ctx do
    parent = self()

    move =
      Task.async(
        Repo.bind_tenant(fn ->
          # The test holds the move's transaction open, so it runs the move body.
          Repo.transact(fn _repo ->
            {:ok, moved} =
              Pages.move_in_tx(ctx.editor.uid, ctx.page.id, %{parent_id: ctx.right.id})

            send(parent, {:checked, backend_pid()})
            receive do: (:commit -> {:ok, moved})
          end)
        end)
      )

    assert_receive {:checked, move_pid}, 5_000

    grant =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact(fn _repo ->
            send(parent, {:grant_started, backend_pid()})

            AuthZ.create_permission_grant(%{
              principal_uid: ctx.viewer.uid,
              resource_pattern: "pod:**:#{ctx.page.id}:**",
              action: "page_manage"
            })
          end)
        end)
      )

    assert_receive {:grant_started, grant_pid}, 5_000

    sharing =
      Task.async(
        Repo.bind_tenant(fn ->
          # One connection runs the sharing action and reports its backend.
          Repo.checkout(fn ->
            send(parent, {:sharing_started, backend_pid()})

            Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, ctx.right.id, %{
              inherit_permissions: false
            })
          end)
        end)
      )

    assert_receive {:sharing_started, sharing_pid}, 5_000
    assert_blocked_by(grant_pid, move_pid)
    assert_blocked_by(sharing_pid, move_pid)

    send(move.pid, :commit)
    assert {:ok, %{parent_id: id}} = Task.await(move, 5_000)
    assert id == ctx.right.id
    assert {:ok, _} = Task.await(grant, 5_000)
    assert {:ok, _} = Task.await(sharing, 5_000)
    assert Repo.get!(Page, ctx.page.id).parent_id == ctx.right.id
  end

  test "a grant committed while the move waits is included in its policy proof", ctx do
    parent = self()

    writer =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact(fn _repo ->
            {:ok, _} =
              AuthZ.create_permission_grant(%{
                principal_uid: ctx.viewer.uid,
                resource_pattern: "pod:**:#{ctx.right.id}:**",
                action: "page_manage"
              })

            send(parent, {:grant_uncommitted, backend_pid()})
            receive do: (:commit -> {:ok, :written})
          end)
        end)
      )

    assert_receive {:grant_uncommitted, writer_pid}, 5_000

    move =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.checkout(fn ->
            send(parent, {:move_started, backend_pid()})
            Pages.move(ctx.editor.uid, ctx.page.id, %{parent_id: ctx.right.id})
          end)
        end)
      )

    assert_receive {:move_started, move_pid}, 5_000
    assert_blocked_by(move_pid, writer_pid)
    send(writer.pid, :commit)
    assert {:ok, :written} = Task.await(writer, 5_000)
    assert {:error, :move_requires_manage} = Task.await(move, 5_000)
    assert Repo.get!(Page, ctx.page.id).parent_id == ctx.left.id
  end

  test "destination edit access is rechecked after waiting for a grant writer", ctx do
    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, ctx.page.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: ctx.editor.uid, role: "edit"}]
      })

    parent = self()

    writer =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact(fn _repo ->
            {:ok, _} = Pages.set_space_in_tx(ctx.owner.uid, "view")
            send(parent, {:access_uncommitted, backend_pid()})
            receive do: (:commit -> {:ok, :written})
          end)
        end)
      )

    assert_receive {:access_uncommitted, writer_pid}, 5_000

    move =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.checkout(fn ->
            send(parent, {:move_started, backend_pid()})
            Pages.move(ctx.editor.uid, ctx.page.id, %{parent_id: ctx.right.id})
          end)
        end)
      )

    assert_receive {:move_started, move_pid}, 5_000
    assert_blocked_by(move_pid, writer_pid)
    send(writer.pid, :commit)
    assert {:ok, :written} = Task.await(writer, 5_000)
    assert {:error, :forbidden} = Task.await(move, 5_000)
    assert Repo.get!(Page, ctx.page.id).parent_id == ctx.left.id
  end

  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp assert_blocked_by(waiter, blocker) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_blocker(waiter, blocker, deadline)
  end

  defp await_blocker(waiter, blocker, deadline) do
    [[blocked]] =
      Repo.query!("SELECT $1::int = ANY(pg_blocking_pids($2::int))", [blocker, waiter]).rows

    cond do
      blocked ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("backend #{waiter} did not wait for #{blocker}")

      true ->
        Process.sleep(5)
        await_blocker(waiter, blocker, deadline)
    end
  end
end
