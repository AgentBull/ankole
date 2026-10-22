defmodule Ankole.Pod.DocumentSnapshotTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  alias Ankole.Pod.{Documents, Pages}

  setup do
    Ankole.E2E.Harness.cleanup_committed_fixtures_on_exit!()
    owner = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, page} = Pages.create(owner.uid, %{})
    {:ok, %{page: page}} = Documents.write(owner.uid, page.id, 0, "<page><p>Before</p></page>")
    %{owner: owner.uid, page: page}
  end

  test "a document snapshot holds its revision stable until the body has been read", ctx do
    {:ok, detail} =
      read_while_writer_attempts(ctx, "pages", fn -> Pages.get(ctx.owner, ctx.page.id) end)

    assert detail.page.revision == 1
    assert detail.content.content == "<page><p>Before</p></page>"
  end

  test "replay holds its revision and byte budget stable until all batches have been read", ctx do
    {:ok, replay} =
      read_while_writer_attempts(ctx, "page_changes", fn ->
        Documents.since(ctx.owner, ctx.page.id, 0)
      end)

    assert replay.revision == 1
    assert Enum.map(replay.changes, & &1.revision) == [1]
    refute replay.reset_required
  end

  defp read_while_writer_attempts(ctx, source, read) do
    observer = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if Process.get(handler) == :wait and metadata[:source] == source do
            Process.delete(handler)
            send(observer, {:read_paused, self()})

            receive do
              :continue_read -> :ok
            after
              5_000 -> raise "snapshot read was not released"
            end
          end
        end,
        nil
      )

    reader =
      Task.async(fn ->
        Repo.with_tenant(ctx.tenant.id, fn ->
          Process.put(handler, :wait)
          read.()
        end)
      end)

    try do
      assert_receive {:read_paused, reader_pid}, 2_000

      error =
        assert_raise Postgrex.Error, fn ->
          # The test sets the lock timeout, so it owns the transaction and runs the write body.
          Repo.transact(fn repo ->
            repo.query!("SET LOCAL lock_timeout = '100ms'")
            xml = "<page><p>After</p></page>"
            Documents.write_in_tx(ctx.owner, ctx.page.id, 1, Ankole.Kernel.page_validate(xml))
          end)
        end

      assert error.postgres.code == :lock_not_available
      send(reader_pid, :continue_read)
      snapshot = Task.await(reader, 5_000)

      assert {:ok, %{page: %{revision: 2}}} =
               Documents.write(ctx.owner, ctx.page.id, 1, "<page><p>After</p></page>")

      snapshot
    after
      send(reader.pid, :continue_read)
      :telemetry.detach(handler)
    end
  end
end
