defmodule Ankole.FilesConcurrencyIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.Files
  alias Ankole.Files.Schemas.Blob
  alias Ankole.ObjectStore
  alias Ecto.Adapters.SQL.Sandbox

  setup %{tenant: tenant} do
    {agent_uid, provider_id, sha256, updated_sha256} =
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

        {:ok, %{sha256: sha256}} = Files.store(content)

        {:ok, %{sha256: updated_sha256}} =
          Files.store(String.replace(content, "Concurrent installed Skill.", "Updated Skill."))

        {agent.uid, provider.provider_id, sha256, updated_sha256}
      end)

    on_exit(fn ->
      Repo.put_tenant_id(tenant.id)

      Sandbox.unboxed_run(Repo, fn ->
        delete_agent_fixture_rows(agent_uid, provider_id)

        for sha <- [sha256, updated_sha256] do
          digest = Base.decode16!(sha, case: :lower)
          Repo.delete_all(from(blob in Blob, where: blob.sha256 == ^digest))
          ObjectStore.delete(Files.object_key(digest))
        end

        Repo.delete!(tenant)
      end)
    end)

    %{agent_uid: agent_uid, sha256: sha256, updated_sha256: updated_sha256}
  end

  test "concurrent parent and child commits cannot both succeed", ctx do
    parent = hold_transaction(fn -> commit(ctx, "a") end)

    child =
      start_unboxed(fn _parent ->
        commit(%{ctx | agent_uid: " #{String.upcase(ctx.agent_uid)} "}, "a/b")
      end)

    assert_blocked_by(child, parent)

    release(parent)
    assert {:ok, %{files: [_file]}} = finish(parent)
    assert {:error, {:path_conflict, "a", "a/b"}} = finish(child)
    assert {:ok, _file} = Files.fetch(ctx.agent_uid, "a")
    assert {:error, :not_found} = Files.fetch(ctx.agent_uid, "a/b")
  end

  test "a move and a commit serialize on the same Agent before checking their final trees", ctx do
    assert {:ok, _files} = Sandbox.unboxed_run(Repo, fn -> commit(ctx, "from/value") end)

    move = hold_transaction(fn -> Files.move(ctx.agent_uid, "from", "a") end)
    parent = start_unboxed(fn _parent -> commit(ctx, "a") end)
    assert_blocked_by(parent, move)

    release(move)
    assert {:ok, 1} = finish(move)
    assert {:error, {:path_conflict, "a", "a/value"}} = finish(parent)
    assert {:ok, _file} = Files.fetch(ctx.agent_uid, "a/value")
    assert {:error, :not_found} = Files.fetch(ctx.agent_uid, "a")
  end

  test "collection waits for a committing attachment reference and keeps its bytes", ctx do
    digest = Base.decode16!(ctx.sha256, case: :lower)

    Repo.update_all(where(Blob, sha256: ^digest),
      set: [last_referenced_at: DateTime.add(DateTime.utc_now(), -2, :day)]
    )

    writer =
      hold_transaction(fn ->
        Ankole.SignalsGateway.Outbox.commit_outbox(%{
          agent_uid: ctx.agent_uid,
          binding_name: "test",
          outbound_key: "race-attachment",
          operation: :post,
          payload: %{"attachments" => [%{"blob_ref" => ctx.sha256}]}
        })
      end)

    collector =
      start_unboxed(fn _parent -> Ankole.Files.Jobs.CollectUnreferenced.mark_unreferenced() end)

    assert_blocked_by(collector, writer)
    release(writer)
    assert {:ok, _} = finish(writer)
    assert {:ok, 0} = finish(collector)
    assert %Blob{deleting: false} = Repo.get!(Blob, digest)
    assert {:ok, _bytes} = Files.read_content(ctx.sha256)
  end

  test "a folder snapshot waits for a concurrent script commit and reports its complete revision",
       ctx do
    assert {:ok, _} = commit(ctx, "script/main.ts")
    assert {:ok, %{revision: old_revision}} = Files.list(ctx.agent_uid, "script", snapshot: true)

    writer =
      hold_transaction(fn ->
        Files.commit(ctx.agent_uid, [
          %{path: "script/main.ts", sha256: ctx.updated_sha256, source: "agent"},
          %{path: "script/module.ts", sha256: ctx.updated_sha256, source: "agent"}
        ])
      end)

    reader = start_unboxed(fn _parent -> Files.list(ctx.agent_uid, "script", snapshot: true) end)
    assert_blocked_by(reader, writer)
    release(writer)
    assert {:ok, _} = finish(writer)
    assert {:ok, %{files: files, revision: revision}} = finish(reader)
    assert revision != old_revision
    assert Enum.map(files, & &1.path) == ["script/main.ts", "script/module.ts"]
    assert Enum.all?(files, &(Base.encode16(&1.sha256, case: :lower) == ctx.updated_sha256))
  end

  test "catalog sync reads the drive after a concurrent manifest deletion commits", ctx do
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _files} = commit(ctx, "skills/race-notes/SKILL.md")

      assert {:ok, %AgentSkill{enabled_override: false}} =
               Library.set_agent_skill_override(ctx.agent_uid, "race-notes", false)
    end)

    deletion = hold_transaction(fn -> Files.delete(ctx.agent_uid, "skills/race-notes") end)
    sync = start_unboxed(fn _parent -> Library.sync_agent_skills(ctx.agent_uid) end)
    assert_blocked_by(sync, deletion)

    release(deletion)
    assert {:ok, 1} = finish(deletion)
    assert {:ok, %{changed: true}} = finish(sync)
    refute Repo.get_by(AgentSkill, agent_uid: ctx.agent_uid, skill_name: "race-notes")
  end

  test "catalog sync adopts a concurrent manifest update and preserves its operator override",
       ctx do
    {:ok, %AgentSkill{id: id}} =
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, _files} = commit(ctx, "skills/race-notes/SKILL.md")
        Library.set_agent_skill_override(ctx.agent_uid, "race-notes", false)
      end)

    write =
      hold_transaction(fn ->
        commit(%{ctx | sha256: ctx.updated_sha256}, "skills/race-notes/SKILL.md")
      end)

    sync = start_unboxed(fn _parent -> Library.sync_agent_skills(ctx.agent_uid) end)
    assert_blocked_by(sync, write)

    release(write)
    assert {:ok, _files} = finish(write)
    assert {:ok, %{changed: true}} = finish(sync)

    assert %AgentSkill{id: ^id, enabled_override: false, description: "Updated Skill."} =
             Repo.get_by!(AgentSkill, agent_uid: ctx.agent_uid, skill_name: "race-notes")
  end

  defp commit(ctx, path) do
    Files.commit(ctx.agent_uid, [%{path: path, sha256: ctx.sha256, source: "agent"}])
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
