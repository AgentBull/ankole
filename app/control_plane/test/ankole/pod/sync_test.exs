defmodule Ankole.Pod.SyncTest do
  use Ankole.DataCase, async: false
  import Ecto.Query
  alias Ankole.Pod.{Database, DbRecord, DbSyncBinding, Sync}

  setup do
    allow_cache_database_access()
    Ankole.AppConfigure.Cache.clear_for_test()
    Ankole.PodSyncFixtures.binding_attempt_fixture()
  end

  test "repeated external IDs update in place and retain editable local fields", ctx do
    rows = [%{external_id: "issue-42", data: %{"title" => "First title"}}]

    assert {:ok, first} =
             Sync.apply_attempt(
               ctx.agent,
               ctx.binding.id,
               ctx.run.id,
               ctx.run.attempt_id,
               rows,
               %{"page" => 1}
             )

    [id] = first.changed_ids
    assert {:ok, %{records: [record]}} = Database.query(ctx.agent, ctx.table.id, %{})
    assert record["data"][ctx.title.id] == "First title"

    assert {:ok, _} =
             Database.write_records(ctx.agent, ctx.table.id, %{
               updates: [%{id: id, data: %{ctx.local.id => "High"}, expected_versions: %{}}]
             })

    assert {:ok, second} =
             Sync.apply_attempt(
               ctx.agent,
               ctx.binding.id,
               ctx.run.id,
               ctx.run.attempt_id,
               [%{external_id: "issue-42", data: %{"title" => "Updated title"}}],
               %{"page" => 2}
             )

    assert second.changed_ids == [id]
    assert Repo.aggregate(DbRecord, :count) == 1
    record = Repo.get_by!(DbRecord, id: id)
    assert record.data[ctx.title.id] == "Updated title"
    assert record.data[ctx.local.id] == "High"
    assert Repo.get!(DbSyncBinding, ctx.binding.id).cursor == %{"page" => 2}

    assert {:error, :synced_field_readonly} =
             Database.write_records(ctx.agent, ctx.table.id, %{
               updates: [
                 %{
                   id: id,
                   data: %{ctx.title.id => "Local overwrite"},
                   expected_versions: %{ctx.title.id => record.versions[ctx.title.id]}
                 }
               ]
             })
  end

  test "a no-link MERGE reads 200 records in bulk without per-record readback", ctx do
    handler = "sync-readback-#{ctx.table.id}"
    parent = self()

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _, _, metadata, owner ->
        if self() == owner, do: send(owner, {:sync_query, metadata.query})
      end,
      parent
    )

    try do
      rows =
        Enum.map(
          1..200,
          &%{external_id: Integer.to_string(&1), data: %{"title" => "Title #{&1}"}}
        )

      assert {:ok, %{changed_ids: ids}} =
               Sync.apply_attempt(
                 ctx.agent,
                 ctx.binding.id,
                 ctx.run.id,
                 ctx.run.attempt_id,
                 rows,
                 :unchanged
               )

      assert length(ids) == 200
      queries = collect_queries([])
      assert Enum.count(queries, &String.contains?(&1, "MERGE INTO db_records")) == 1
      assert Enum.count(queries, &Regex.match?(~r/^SELECT.*FROM "?db_records"? /s, &1)) == 2
    after
      :telemetry.detach(handler)
    end
  end

  defp collect_queries(queries) do
    receive do
      {:sync_query, query} -> collect_queries([query | queries])
    after
      0 -> queries
    end
  end

  test "only the binding's live job attempt can write, and pause or lost access takes effect",
       ctx do
    rows = [%{external_id: "42", data: %{"title" => "Title"}}]

    assert {:error, :sync_attempt_not_authorized} =
             Sync.apply_attempt(
               ctx.agent,
               ctx.binding.id,
               ctx.run.id,
               Ecto.UUID.generate(),
               rows,
               :unchanged
             )

    assert {:error, :sync_attempt_not_authorized} =
             Sync.apply_attempt(
               ctx.human,
               ctx.binding.id,
               ctx.run.id,
               ctx.run.attempt_id,
               rows,
               :unchanged
             )

    assert {:ok, _} = Sync.set_status(ctx.human, ctx.binding.id, "paused")

    assert {:error, :sync_attempt_not_authorized} =
             Sync.apply_attempt(
               ctx.agent,
               ctx.binding.id,
               ctx.run.id,
               ctx.run.attempt_id,
               rows,
               :unchanged
             )

    assert {:ok, _} = Sync.set_status(ctx.human, ctx.binding.id, "active")
    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(ctx.human, ctx.page.id, %{grants: []})

    assert {:error, :forbidden} =
             Sync.apply_attempt(
               ctx.agent,
               ctx.binding.id,
               ctx.run.id,
               ctx.run.attempt_id,
               rows,
               :unchanged
             )

    assert Repo.aggregate(DbRecord, :count) == 0
  end

  test "invalid batches and cursor failures roll back records and cursor together", ctx do
    assert {:error, :invalid_external_record} =
             Sync.apply_attempt(
               ctx.agent,
               ctx.binding.id,
               ctx.run.id,
               ctx.run.attempt_id,
               [false],
               :unchanged
             )

    row = %{external_id: "42", data: %{"title" => "Title"}}

    assert {:error, :duplicate_external_id} =
             Sync.apply_attempt(
               ctx.agent,
               ctx.binding.id,
               ctx.run.id,
               ctx.run.attempt_id,
               [row, row],
               :unchanged
             )

    assert {:error, :invalid_sync_cursor} =
             Sync.apply_attempt(
               ctx.agent,
               ctx.binding.id,
               ctx.run.id,
               ctx.run.attempt_id,
               [row],
               "invalid"
             )

    assert Repo.aggregate(DbRecord, :count) == 0
    assert Repo.get!(DbSyncBinding, ctx.binding.id).cursor == nil
  end

  test "sync responses compute formulas through the same projection as queries", ctx do
    {:ok, formula} =
      Database.create_field(ctx.agent, ctx.table.id, %{
        name: "Title length",
        type: "formula",
        config: %{"source" => "LEN([#{ctx.title.name}])"}
      })

    assert {:ok, %{records: [record]}} =
             Sync.apply_attempt(
               ctx.agent,
               ctx.binding.id,
               ctx.run.id,
               ctx.run.attempt_id,
               [%{external_id: "formula", data: %{"title" => "Hello"}}],
               :unchanged
             )

    assert record.data[formula.id] == 5
    refute Map.has_key?(Repo.get_by!(DbRecord, id: record.id).data, formula.id)
  end

  test "paused mapped reverse fields reject local edits and incoming deletion atomically", ctx do
    {:ok, target} = Database.create_table(ctx.agent, ctx.page.id, %{name: "People"})

    {:ok, %{records: [person]}} =
      Database.write_records(ctx.agent, target.id, %{creates: [%{data: %{}}]})

    {:ok, link} =
      Database.create_field(ctx.agent, ctx.table.id, %{
        name: "Owner",
        type: "link",
        config: %{"table_id" => target.id, "bidirectional" => true}
      })

    {:ok, %{records: [record]}} =
      Database.write_records(ctx.agent, ctx.table.id, %{
        creates: [%{data: %{link.id => [person.id]}}]
      })

    {:ok, binding} =
      Sync.create(ctx.agent, target.id, %{
        connector: "test",
        source: %{},
        field_map: %{"owners" => link.config["reverse_field_id"]},
        automation_job_id: ctx.job.id
      })

    {:ok, _} = Sync.set_status(ctx.human, binding.id, "paused")

    assert {:error, :synced_field_readonly} =
             Database.write_records(ctx.agent, ctx.table.id, %{
               updates: [
                 %{id: record.id, data: %{link.id => []}, expected_versions: record.versions}
               ]
             })

    assert {:error, :synced_field_readonly} =
             Database.write_records(ctx.agent, ctx.table.id, %{
               deletes: [%{id: record.id, expected_versions: record.versions}]
             })

    assert Repo.get_by!(DbRecord, id: record.id).data[link.id] == [person.id]

    assert Repo.get_by!(DbRecord, id: person.id).data[link.config["reverse_field_id"]] == [
             record.id
           ]
  end

  test "paused mapped records including cleared values cannot be deleted locally", ctx do
    assert {:ok, _} =
             Sync.apply_attempt(
               ctx.agent,
               ctx.binding.id,
               ctx.run.id,
               ctx.run.attempt_id,
               [
                 %{external_id: "value", data: %{"title" => "Synced"}},
                 %{external_id: "empty", data: %{}}
               ],
               :unchanged
             )

    {:ok, _} = Sync.set_status(ctx.human, ctx.binding.id, "paused")

    {:ok, %{records: [local]}} =
      Database.write_records(ctx.human, ctx.table.id, %{
        creates: [%{data: %{ctx.local.id => "Local"}}]
      })

    for record <- Repo.all(from r in DbRecord, where: not is_nil(r.external_id)) do
      assert {:error, :synced_field_readonly} =
               Database.write_records(ctx.human, ctx.table.id, %{
                 updates: [
                   %{
                     id: local.id,
                     data: %{ctx.local.id => "Should roll back"},
                     expected_versions: local.versions
                   }
                 ],
                 deletes: [%{id: record.id, expected_versions: record.versions}]
               })

      assert Repo.get_by!(DbRecord, id: record.id).versions[ctx.title.id] == 1
      assert Repo.get_by!(DbRecord, id: local.id).data[ctx.local.id] == "Local"
    end

    assert {:ok, _} =
             Database.write_records(ctx.human, ctx.table.id, %{
               deletes: [%{id: local.id, expected_versions: local.versions}]
             })

    assert Repo.aggregate(DbRecord, :count) == 2
  end

  test "malformed binding IDs are rejected without a cast exception", ctx do
    assert {:error, :not_found} = Sync.set_status(ctx.human, "bad", "paused")
  end
end
