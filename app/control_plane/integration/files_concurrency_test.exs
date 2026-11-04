defmodule Ankole.FilesConcurrencyIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.Files
  alias Ankole.Files.Schemas.FileObject
  alias Ankole.Pod.Page, as: Node
  alias Ankole.ObjectStore
  alias Ecto.Adapters.SQL.Sandbox

  setup %{tenant: tenant} do
    {agent_uid, provider_id, stored, updated} =
      Sandbox.unboxed_run(Repo, fn ->
        provider = worker_provider_fixture()
        %{principal: agent} = agent_fixture(%{worker_provider_id: provider.provider_id})

        content = """
        ---
        name: race-notes
        description: Concurrent installed Skill.
        ---
        Notes for #{agent.uid}.
        """

        {:ok, stored} = Files.store(content)

        {:ok, updated} =
          Files.store(String.replace(content, "Concurrent installed Skill.", "Updated Skill."))

        {agent.uid, provider.provider_id, stored, updated}
      end)

    on_exit(fn ->
      Repo.put_tenant_id(tenant.id)

      Sandbox.unboxed_run(Repo, fn ->
        delete_agent_fixture_rows(agent_uid, provider_id)

        for object <- Repo.all(FileObject) do
          ObjectStore.delete(object.storage_key)
        end

        cleanup_tenant!(tenant)
      end)
    end)

    %{agent_uid: agent_uid, stored: stored, updated: updated}
  end

  test "concurrent parent and child commits cannot both succeed", ctx do
    parent = hold_transaction(fn -> commit_in_tx(ctx, "a") end)

    child =
      start_unboxed(fn _parent ->
        commit(%{ctx | agent_uid: " #{String.upcase(ctx.agent_uid)} "}, "a/b")
      end)

    assert_blocked_by(child, parent)

    release(parent)
    assert {:ok, %{files: [_file]}} = finish(parent)
    assert {:error, :not_a_directory} = finish(child)
    assert {:ok, _file} = Files.fetch(ctx.agent_uid, "a")
    assert {:error, :not_found} = Files.fetch(ctx.agent_uid, "a/b")
  end

  test "a move and a commit serialize on the same Agent before checking their final trees", ctx do
    assert {:ok, _files} = Sandbox.unboxed_run(Repo, fn -> commit(ctx, "from/value") end)

    move = hold_transaction(fn -> Files.move_in_tx(ctx.agent_uid, "from", "a") end)
    parent = start_unboxed(fn _parent -> commit(ctx, "a") end)
    assert_blocked_by(parent, move)

    release(move)
    assert {:ok, 1} = finish(move)
    assert {:error, :is_a_directory} = finish(parent)
    assert {:ok, _file} = Files.fetch(ctx.agent_uid, "a/value")
    assert {:ok, %{type: :doc}} = Files.fetch(ctx.agent_uid, "a")
  end

  test "a tree writer resolves its private root after a concurrent cross-root move", ctx do
    actor = actor_fixture(ctx.agent_uid)
    other = human_fixture().principal
    {:ok, source_root} = Ankole.Pod.private_root(ctx.agent_uid)
    {:ok, target_root} = Ankole.Pod.private_root(other.uid)

    for action <- Ankole.Pod.Access.page_actions() do
      assert {:ok, _} =
               Ankole.AuthZ.create_permission_grant(%{
                 principal_uid: ctx.agent_uid,
                 resource_pattern: "drive:private:#{other.uid}:**",
                 action: action
               })
    end

    {:ok, node} =
      Ankole.Pod.create_node(actor, %{parent_id: source_root.id, type: :doc, name: "before"})

    move =
      hold_transaction(fn ->
        :ok = Ankole.Pod.lock_tree_in_tx()
        :ok = Ankole.Pod.Pages.Tree.lock_roots([source_root.id, target_root.id])
        Ankole.Pod.Pages.Tree.move_in_tx(actor, node.id, %{parent_id: target_root.id})
      end)

    snapshot =
      start_unboxed(fn parent ->
        Repo.transact(fn ->
          :ok = Ankole.Pod.Pages.Tree.lock_roots([target_root.id])
          send(parent, {:snapshot_held, self()})

          receive do
            :commit_transaction -> Files.Paths.list_snapshot_in_tx(other.uid, "", [])
          after
            10_000 -> raise "test did not release the snapshot"
          end
        end)
      end)

    assert_blocked_by(snapshot, move)

    writer =
      start_unboxed(fn _parent -> Ankole.Pod.move_node(actor, node.id, %{name: "after"}) end)

    assert_blocked_by(writer, move)
    release(move)
    assert {:ok, _} = finish(move)
    snapshot_pid = snapshot.task.pid
    assert_receive {:snapshot_held, ^snapshot_pid}, 5_000
    assert_blocked_by(writer, snapshot)

    release(snapshot)
    assert {:ok, %{files: []}} = finish(snapshot)
    assert {:ok, %{name: "after", parent_id: parent_id}} = finish(writer)
    assert parent_id == target_root.id
  end

  test "collection waits for a committing object reference and keeps its bytes", ctx do
    Repo.update_all(where(FileObject, id: ^ctx.stored.object_id),
      set: [created_at: DateTime.add(DateTime.utc_now(:microsecond), -2, :day)]
    )

    writer = hold_transaction(fn -> commit_in_tx(ctx, "retained.txt") end)
    collector = start_unboxed(fn _parent -> Files.collect_objects() end)
    assert_blocked_by(collector, writer)
    release(writer)
    assert {:ok, _} = finish(writer)
    assert {:ok, 0} = finish(collector)

    assert %FileObject{completed_at: %DateTime{}} =
             Repo.get_by!(FileObject, id: ctx.stored.object_id)

    assert {:ok, _bytes} = Files.read_object(ctx.stored.object_id)
  end

  test "two writers preserve the node and the last commit wins", ctx do
    {:ok, %{files: [original]}} = commit(ctx, "shared.txt")
    first = hold_transaction(fn -> commit_in_tx(%{ctx | stored: ctx.updated}, "shared.txt") end)
    last = start_unboxed(fn _parent -> commit(ctx, "shared.txt") end)
    assert_blocked_by(last, first)
    release(first)
    assert {:ok, %{files: [one]}} = finish(first)
    assert {:ok, %{files: [two]}} = finish(last)
    assert one.id == original.id and two.id == original.id
    assert one.object_id == ctx.updated.object_id
    assert two.object_id == ctx.stored.object_id
    assert {:ok, %{object_id: final}} = Files.fetch(ctx.agent_uid, "shared.txt")
    assert final == ctx.stored.object_id
  end

  test "a path deleted before an overwrite acquires its root lock is not silently recreated",
       ctx do
    {:ok, _} = commit(ctx, "deleted.txt")
    deletion = hold_transaction(fn -> Files.delete_in_tx(ctx.agent_uid, "deleted.txt") end)
    writer = start_unboxed(fn _parent -> commit(%{ctx | stored: ctx.updated}, "deleted.txt") end)
    assert_blocked_by(writer, deletion)
    release(deletion)
    assert {:ok, 1} = finish(deletion)
    assert {:error, :path_changed} = finish(writer)
    assert {:error, :not_found} = Files.fetch(ctx.agent_uid, "deleted.txt")
  end

  test "a content write resolves its current root after waiting for a public to private move",
       ctx do
    actor = actor_fixture(ctx.agent_uid)

    assert :ok =
             Repo.transact_top_level(fn ->
               Ankole.Pod.Access.put_role(
                 %{principal_uid: ctx.agent_uid},
                 "drive:space:**",
                 "manage"
               )
             end)

    {:ok, public} = Ankole.Pod.public_root()
    {:ok, private} = Ankole.Pod.private_root(ctx.agent_uid)

    {:ok, file} =
      Ankole.Pod.create_node(actor, %{parent_id: public.id, type: :file, name: "moving.txt"})

    move =
      hold_transaction(fn ->
        Ankole.Pod.lock_tree_in_tx()
        Ankole.Pod.lock_root_ids_in_tx([private.id])
        Ankole.Pod.Pages.Tree.move_in_tx(actor, file.id, %{parent_id: private.id})
      end)

    writer =
      start_unboxed(fn _parent -> Ankole.Pod.write_node(actor, file.id, "racing write") end)

    assert_blocked_by(writer, move)
    release(move)
    assert {:ok, _} = finish(move)
    assert {:ok, written} = finish(writer)
    assert {:ok, %{object_id: object_id, parent_id: parent_id}} = Ankole.Pod.fetch_node(file.id)
    assert parent_id == private.id
    assert object_id == written.object_id
    assert {:ok, "racing write"} = Files.read_object(object_id)
  end

  test "a content commit prevents an independent ACL ancestor from crossing roots", ctx do
    actor = actor_fixture(ctx.agent_uid)

    assert :ok =
             Repo.transact_top_level(fn ->
               Ankole.Pod.Access.put_role(
                 %{principal_uid: ctx.agent_uid},
                 "drive:space:**",
                 "manage"
               )
             end)

    {:ok, public} = Ankole.Pod.public_root()
    {:ok, private} = Ankole.Pod.private_root(ctx.agent_uid)

    {:ok, folder} =
      Ankole.Pod.create_node(actor, %{parent_id: public.id, type: :doc, name: "anchored"})

    assert :ok =
             Repo.transact_top_level(fn ->
               Ankole.Pod.Access.put_role(
                 %{principal_uid: ctx.agent_uid},
                 "drive:**:#{folder.id}:**",
                 "manage"
               )
             end)

    {:ok, folder} = Ankole.Pod.fetch_node(folder.id)
    assert folder.acl_anchor_id == folder.id

    {:ok, nested} =
      Ankole.Pod.create_node(actor, %{parent_id: folder.id, type: :doc, name: "nested"})

    {:ok, file} =
      Ankole.Pod.create_node(actor, %{parent_id: nested.id, type: :file, name: "value.txt"})

    row = hold_transaction(fn -> Ankole.Pod.Pages.Tree.lock(file.id) end)

    writer =
      start_unboxed(fn _parent ->
        Ankole.Pod.write_node(actor, file.id, "before ancestor move")
      end)

    assert_blocked_by(writer, row)

    move =
      start_unboxed(fn _parent ->
        Ankole.Pod.move_node(actor, folder.id, %{parent_id: private.id})
      end)

    assert_blocked_by(move, writer)
    release(row)
    assert {:ok, _} = finish(row)
    assert {:ok, written} = finish(writer)
    assert {:ok, moved} = finish(move)
    assert moved.parent_id == private.id and moved.acl_anchor_id == folder.id
    assert {:ok, "before ancestor move"} = Files.read_object(written.object_id)
    assert {:ok, found} = Files.fetch(ctx.agent_uid, "anchored/nested/value.txt")
    assert found.object_id == written.object_id
  end

  @tag timeout: 120_000
  test "moving and renaming ten thousand nodes preserves every identity", ctx do
    actor = actor_fixture(ctx.agent_uid)
    {:ok, root} = Ankole.Pod.private_root(ctx.agent_uid)

    {:ok, source} =
      Ankole.Pod.create_node(actor, %{parent_id: root.id, type: :doc, name: "source"})

    {:ok, target} =
      Ankole.Pod.create_node(actor, %{parent_id: root.id, type: :doc, name: "target"})

    {:ok, entries} =
      Repo.transact(fn ->
        :ok = Ankole.Pod.lock_tree_in_tx()
        :ok = Files.lock_drive(ctx.agent_uid)

        1..10_000
        |> Enum.map(fn n ->
          %{
            id: Ash.UUIDv7.generate(),
            parent_id: source.id,
            type: :file,
            name: "file-#{n}",
            acl_anchor_id: root.id,
            mode: 0o644
          }
        end)
        |> Ankole.Ash.create_all(Node, :create_in_tx)
      end)

    before = entries |> Enum.map(& &1.id) |> MapSet.new()

    {elapsed, result} =
      :timer.tc(fn ->
        Ankole.Pod.move_node(actor, source.id, %{parent_id: target.id, name: "renamed"})
      end)

    assert {:ok, %{id: id}} = result
    assert id == source.id

    after_ids =
      Repo.all(from n in Node, where: n.parent_id == ^source.id, select: n.id) |> MapSet.new()

    assert before == after_ids and MapSet.size(after_ids) == 10_000
    assert {:ok, %{id: first}} = Files.fetch(ctx.agent_uid, "target/renamed/file-1")
    assert first in before
    IO.puts("Drive 10000-node move+rename: #{Float.round(elapsed / 1000, 1)} ms")
  end

  test "a folder snapshot waits for a concurrent script commit and reports its complete revision",
       ctx do
    assert {:ok, _} = commit(ctx, "script/main.ts")
    assert {:ok, %{revision: old_revision}} = Files.list(ctx.agent_uid, "script", snapshot: true)

    writer =
      hold_transaction(fn ->
        Files.commit_in_tx(
          ctx.agent_uid,
          [
            Map.merge(ctx.updated, %{path: "script/main.ts", source: "agent"}),
            Map.merge(ctx.updated, %{path: "script/module.ts", source: "agent"})
          ],
          []
        )
      end)

    reader = start_unboxed(fn _parent -> Files.list(ctx.agent_uid, "script", snapshot: true) end)
    assert_blocked_by(reader, writer)
    release(writer)
    assert {:ok, _} = finish(writer)
    assert {:ok, %{files: files, revision: revision}} = finish(reader)
    assert revision != old_revision
    assert Enum.map(files, & &1.path) == ["script/main.ts", "script/module.ts"]
    assert Enum.all?(files, &(&1.object_id == ctx.updated.object_id))
  end

  test "catalog sync is independent of concurrent private Drive changes", ctx do
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} = commit(ctx, "skills/race-notes/SKILL.md")
      assert {:ok, _} = Library.sync_agent_skills(ctx.agent_uid)
      assert {:error, :not_found} = Library.Skills.get("race-notes")
    end)

    deletion = hold_transaction(fn -> Files.delete_in_tx(ctx.agent_uid, "skills/race-notes") end)
    sync = start_unboxed(fn _parent -> Library.sync_agent_skills(ctx.agent_uid) end)
    assert {:ok, :ok} = finish(sync)
    release(deletion)
    assert {:ok, 1} = finish(deletion)

    # The sync finished while the Drive deletion was still open and never
    # brought the Agent's Drive Skill into the catalog.
    Sandbox.unboxed_run(Repo, fn ->
      assert {:error, :not_found} = Library.Skills.get("race-notes")
    end)
  end

  defp commit(ctx, path) do
    Files.commit(ctx.agent_uid, [Map.merge(ctx.stored, %{path: path, source: "agent"})])
  end

  # A held transaction runs the commit body, because a commit action owns its
  # own transaction.
  defp commit_in_tx(ctx, path) do
    Files.commit_in_tx(ctx.agent_uid, [Map.merge(ctx.stored, %{path: path, source: "agent"})], [])
  end

  defp start_unboxed(fun) do
    parent = self()
    tenant_id = Repo.tenant_id!()

    task =
      Task.async(fn ->
        Repo.put_tenant_id(tenant_id)

        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:database_task, self(), backend_pid})
          fun.(parent)
        end)
      end)

    task_pid = task.pid
    assert_receive {:database_task, ^task_pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid}
  end

  defp hold_transaction(fun) do
    operation =
      start_unboxed(fn parent ->
        Repo.transact(fn _repo ->
          result = fun.()
          send(parent, {:transaction_held, self()})

          receive do
            :commit_transaction -> result
          after
            10_000 -> raise "test did not release its transaction"
          end
        end)
      end)

    task_pid = operation.task.pid
    assert_receive {:transaction_held, ^task_pid}, 5_000
    operation
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
  end

  defp release(operation), do: send(operation.task.pid, :commit_transaction)
  defp finish(operation), do: Task.await(operation.task, 10_000)
end
