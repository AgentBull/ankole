defmodule Ankole.Pod.SyncLifecycleTest do
  use Ankole.DataCase, async: false
  alias Ankole.Pod.{Database, DbRecord, DbSyncBinding, DbTable, Sync}

  setup do
    allow_cache_database_access()
    Ankole.AppConfigure.Cache.clear_for_test()
    Ankole.PodSyncFixtures.binding_attempt_fixture()
  end

  test "binding creation advances the schema version, while pause and cancellation keep ownership",
       ctx do
    assert {:ok, table} = Database.create_table(ctx.agent, ctx.page.id, %{name: "Second source"})
    title = Enum.find(Database.fields(table.id), & &1.is_primary)
    baseline = Repo.get!(DbTable, table.id).data_version
    expected_version = baseline + 1
    Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-room:table:" <> table.id)

    assert {:ok, binding} =
             Sync.create(ctx.agent, table.id, %{
               connector: "test_source",
               source: %{},
               field_map: %{"title" => title.id},
               automation_job_id: ctx.job.id
             })

    assert Repo.get!(DbTable, table.id).data_version == expected_version
    assert_receive {:room_event, "schema_changed", %{data_version: ^expected_version}}, 1_000
    assert {:ok, %{readonly_field_ids: readonly}} = Database.get_table(ctx.human, table.id)
    assert readonly == [title.id]
    assert {:ok, _} = Sync.set_status(ctx.human, binding.id, "paused")

    assert {:ok, _} =
             Ankole.AutomationJobs.cancel_job(ctx.agent, ctx.job.owner_session_id, ctx.job.id)

    assert Repo.get!(DbSyncBinding, binding.id).status == :paused
    assert Database.readonly_field_ids(table.id) == [title.id]
    assert Repo.get!(DbTable, table.id).data_version == expected_version
    refute_receive {:room_event, "schema_changed", _}, 50
  end

  test "permanent Agent deletion releases mapped cells and invalidates the Human's schema", ctx do
    assert {:ok, %{changed_ids: [id]}} =
             Sync.apply_attempt(
               ctx.agent,
               ctx.binding.id,
               ctx.run.id,
               ctx.run.attempt_id,
               [%{external_id: "retained", data: %{"title" => "Preserved source value"}}],
               :unchanged
             )

    record = Repo.get_by!(DbRecord, id: id, table_id: ctx.table.id)
    initial_version = Repo.get!(DbTable, ctx.table.id).data_version
    expected_version = initial_version + 1
    Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-room:table:" <> ctx.table.id)

    assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(ctx.agent)
    assert Repo.get!(DbSyncBinding, ctx.binding.id)
    assert Repo.get!(DbTable, ctx.table.id).data_version == initial_version
    refute_receive {:room_event, "schema_changed", _}, 50

    assert {:error, :rollback} =
             Repo.transact(fn _repo ->
               assert {:ok, _} = Ankole.Principals.delete_agent(ctx.agent)
               assert Repo.get(DbSyncBinding, ctx.binding.id) == nil
               {:error, :rollback}
             end)

    assert Repo.get!(DbSyncBinding, ctx.binding.id)
    assert Repo.get!(DbTable, ctx.table.id).data_version == initial_version
    refute_receive {:room_event, "schema_changed", _}, 50

    assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(ctx.agent)
    assert Repo.get(DbSyncBinding, ctx.binding.id) == nil
    assert Repo.get(Ankole.AutomationJobs.Schemas.Job, ctx.job.id) == nil
    assert Repo.get_by!(DbRecord, id: id, table_id: ctx.table.id).data == record.data
    assert Repo.get!(DbTable, ctx.table.id).data_version == expected_version
    assert_receive {:room_event, "schema_changed", %{data_version: ^expected_version}}, 1_000
    refute_receive {:room_event, "schema_changed", _}, 50
    assert {:ok, %{readonly_field_ids: []}} = Database.get_table(ctx.human, ctx.table.id)

    assert {:ok, _} =
             Database.write_records(ctx.human, ctx.table.id, %{
               updates: [
                 %{
                   id: id,
                   data: %{ctx.title.id => "Now editable locally"},
                   expected_versions: %{ctx.title.id => record.versions[ctx.title.id]}
                 }
               ]
             })
  end
end
