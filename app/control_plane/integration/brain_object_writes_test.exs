defmodule Ankole.BrainObjectWritesIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  alias Ankole.Brain.Chunks
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ecto.Adapters.SQL.Sandbox

  setup %{tenant: tenant} do
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.with_tenant(tenant.id, fn -> cleanup_tenant!(tenant) end)
      end)
    end)

    {:ok, _} = SchemaPacks.install_packs([])

    {:ok, original} =
      Ankole.Brain.create_object(
        %{slug: "notes/commit-order", type: "note", title: "Commit order", body: "Original"},
        :system
      )

    {:ok, object} =
      Ankole.Brain.update_object(
        original.slug,
        %{body: "Current", expected_content_hash: original.content_hash},
        :system
      )

    [version] = Repo.all(from(v in ObjectVersion, where: v.object_id == ^object.id))

    %{object: object, version: version}
  end

  for operation <- [:update, :rollback] do
    @operation operation
    test "#{operation} waiting behind a delete cannot change the hidden content", context do
      deleted =
        hold(fn -> Objects.soft_delete_in_tx(context.object.slug, reason: "Obsolete") end)

      waiting =
        start(fn ->
          result =
            case @operation do
              :update ->
                Ankole.Brain.update_object(
                  context.object.slug,
                  %{body: "Stale update", expected_content_hash: context.object.content_hash},
                  :system
                )

              :rollback ->
                Ankole.Brain.rollback_object(context.object.slug, context.version.id, :system)
            end

          Ankole.Errors.reason(result)
        end)

      assert_blocked_by(waiting, deleted)
      send(deleted.task.pid, :commit)
      assert {:ok, _} = Task.await(deleted.task, 5_000)
      assert {:error, :object_deleted} = Task.await(waiting.task, 5_000)

      stored = Repo.get!(Object, context.object.id)
      assert stored.body == "Current"
      assert stored.deleted_at
      assert stored.meta["forgotten_reason"] == "Obsolete"

      assert Repo.all(from(v in ObjectVersion, where: v.object_id == ^stored.id)) == [
               context.version
             ]
    end
  end

  test "a save that commits first remains the content later deleted", context do
    saved =
      hold(fn ->
        Objects.update_object_in_tx(
          context.object.slug,
          %{
            body: "Committed before deletion",
            expected_content_hash: context.object.content_hash
          },
          :system
        )
      end)

    deleted = start(fn -> Ankole.Brain.soft_delete_object(context.object.slug) end)
    assert_blocked_by(deleted, saved)
    send(saved.task.pid, :commit)
    assert {:ok, _} = Task.await(saved.task, 5_000)
    assert {:ok, _} = Task.await(deleted.task, 5_000)
    stored = Repo.get!(Object, context.object.id)
    assert stored.body == "Committed before deletion"
    assert stored.deleted_at
    assert Repo.aggregate(from(v in ObjectVersion, where: v.object_id == ^stored.id), :count) == 2
  end

  # Match the existing transaction suites: these tasks use independent,
  # committed PostgreSQL connections rather than a shared Sandbox owner.

  test "an embedding result commits once and a later body edit invalidates its position",
       context do
    chunk = Repo.get_by!(Chunk, object_id: context.object.id, chunk_index: 0)
    {:ok, vector} = Ash.Vector.new(List.duplicate(0.5, 4096))
    embedded = hold(fn -> Chunks.record_embedding(chunk, {:ok, vector, "current-model"}) end)

    late_failure =
      start(fn -> Chunks.record_embedding(chunk, {:error, "late failure", "old-model"}) end)

    assert_blocked_by(late_failure, embedded)
    send(embedded.task.pid, :commit)
    assert {:ok, :updated} = Task.await(embedded.task, 5_000)
    assert {:ok, :stale} = Task.await(late_failure.task, 5_000)

    stored = Repo.get!(Chunk, chunk.id)
    assert stored.embedding != nil
    assert stored.embedding_signature == "current-model"
    assert stored.embedding_error == nil
    assert stored.embedded_at != nil

    assert {:ok, _object} =
             Ankole.Brain.update_object(
               context.object.slug,
               %{
                 body: "Changed after embedding",
                 expected_content_hash: context.object.content_hash
               },
               :system
             )

    replaced = Repo.get!(Chunk, chunk.id)
    assert replaced.chunk_text == "Changed after embedding"
    assert replaced.embedding == nil
    assert replaced.embedding_signature == nil
    assert replaced.embedding_error == nil
    assert replaced.embedded_at == nil
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
            fun.()
          end)
        end)
      end)

    pid = task.pid
    assert_receive {:database_task, ^pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid}
  end

  defp hold(fun) do
    parent = self()

    operation =
      start(fn ->
        Repo.transact(fn _repo ->
          result = fun.()
          send(parent, {:transaction_held, self()})

          receive do
            :commit -> result
          after
            10_000 -> raise "test did not release its transaction"
          end
        end)
      end)

    pid = operation.task.pid
    assert_receive {:transaction_held, ^pid}, 5_000
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
end
