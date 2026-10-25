defmodule Ankole.Pod.ResourceActionsTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures

  alias Ankole.Pod.{Page, Pages}

  test "stored predicates protect copy initialization and nonempty personal state" do
    owner = human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{type: :database})

    {:ok, table} =
      Ankole.Pod.Database.create_table(
        Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
        page.id,
        %{}
      )

    assert {:ok, initialized} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(table, :initialize_copy, %{record_count: 2, next_auto_number: 3})
             end)

    assert {:error, %Ash.Error.Invalid{errors: [%Ankole.Errors.Invalid.Stale{}]}} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(table, :initialize_copy, %{
                 record_count: 20,
                 next_auto_number: 30
               })
             end)

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Ankole.Pod.DbTable, table.id), initialized)

    {:ok, state} =
      Repo.transact(fn _ ->
        Ankole.Ash.create(Ankole.Pod.PageUserState, :put, %{
          principal_uid: owner.uid,
          page_id: page.id,
          favorited_at: DateTime.utc_now(:microsecond)
        })
      end)

    assert {:error, %Ash.Error.Invalid{errors: [%Ankole.Errors.Invalid.Stale{}]}} =
             Repo.transact(fn _ ->
               Ankole.Ash.destroy(state, :remove_empty)
             end)

    assert_persisted_equal(
      Repo.get_by!(Ankole.Pod.PageUserState, principal_uid: owner.uid, page_id: page.id),
      state
    )
  end

  test "page revision increments use stored state even when a caller holds an old snapshot" do
    owner = human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{type: :applet})

    now = DateTime.utc_now(:microsecond)

    assert {:ok, second} =
             Repo.transact(fn _ ->
               with {:ok, first} <- Ankole.Ash.update(page, :advance_revision, %{updated_at: now}),
                    {:ok, second} <-
                      Ankole.Ash.update(page, :advance_revision, %{updated_at: now}) do
                 assert first.revision == page.revision + 1
                 {:ok, second}
               end
             end)

    assert second.revision == page.revision + 2
    Ankole.DataCase.assert_persisted_equal(Repo.get!(Page, page.id), second)
  end

  test "editing a page cannot replace its identity, type, attribution, or revision" do
    owner = human_fixture().principal
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{})

    assert {:error, error} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(page, :edit, %{
                 id: Ankole.Ecto.UUIDv7.autogenerate(),
                 type: :applet,
                 created_by: Ankole.ActorRef.from_principal(owner),
                 revision: 100
               })
             end)

    assert MapSet.new(
             Enum.map(error.errors, fn
               %Ash.Error.Invalid.NoSuchInput{input: input} -> input
             end)
           ) ==
             MapSet.new([:id, :type, :created_by, :revision])

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Page, page.id), page)
  end

  test "Database counters and schema versions advance from stored state" do
    owner = human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{type: :database})

    {:ok, table} =
      Ankole.Pod.Database.create_table(
        Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
        page.id,
        %{}
      )

    [field] = Ankole.Pod.Database.fields(table.id)
    view = Repo.get_by!(Ankole.Pod.DbView, table_id: table.id)

    assert {:ok, {table, field, view}} =
             Repo.transact(fn _ ->
               with {:ok, _} <- Ankole.Ash.update(table, :commit_write, %{delta: 0, inserted: 0}),
                    {:ok, advanced_table} <-
                      Ankole.Ash.update(table, :commit_write, %{delta: 0, inserted: 0}),
                    {:ok, _} <- Ankole.Ash.update(field, :update_definition, %{name: "First"}),
                    {:ok, advanced_field} <-
                      Ankole.Ash.update(field, :update_definition, %{name: "Second"}),
                    {:ok, _} <- Ankole.Ash.update(view, :update_definition, %{name: "First"}),
                    {:ok, advanced_view} <-
                      Ankole.Ash.update(view, :update_definition, %{name: "Second"}) do
                 {:ok, {advanced_table, advanced_field, advanced_view}}
               end
             end)

    assert {table.data_version, table.record_count, table.next_auto_number} == {2, 0, 1}
    assert {field.version, field.name} == {3, "Second"}
    assert {view.version, view.name} == {3, "Second"}

    assert Ankole.Pod.Serialization.item(field) |> Map.keys() |> MapSet.new() ==
             MapSet.new([:id, :table_id, :name, :position, :type, :config, :is_primary, :version])

    assert Ankole.Pod.Serialization.json_value(field)["type"] == "text"
  end

  test "Database actions reject changes to identity and creation facts" do
    owner = human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{type: :database})

    {:ok, table} =
      Ankole.Pod.Database.create_table(
        Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
        page.id,
        %{}
      )

    [field] = Ankole.Pod.Database.fields(table.id)
    view = Repo.get_by!(Ankole.Pod.DbView, table_id: table.id)

    {:ok, %{records: [created]}} =
      Ankole.Pod.Database.write_records(
        Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
        table.id,
        %{creates: [%{}]}
      )

    record = Repo.get_by!(Ankole.Pod.DbRecord, table_id: table.id, id: created.id)

    for {record, action, attrs} <- [
          {table, :commit_write,
           %{id: table.id, page_id: page.id, data_version: 100, delta: 0, inserted: 0}},
          {field, :update_definition, %{table_id: table.id, is_primary: false, version: 100}},
          {view, :update_definition, %{table_id: table.id, version: 100}}
        ] do
      record = reload(record)
      assert {:error, error} = Repo.transact(fn _ -> Ankole.Ash.update(record, action, attrs) end)

      rejected =
        Enum.map(error.errors, fn %Ash.Error.Invalid.NoSuchInput{input: input} -> input end)

      assert MapSet.new(rejected) == MapSet.new(Map.keys(attrs) -- [:delta, :inserted])
      assert reload(record) == record
    end

    # Records belong to the Database subsystem's Ecto schema.
    attrs = %{
      id: record.id,
      table_id: table.id,
      created_by: record.created_by,
      created_at: record.created_at
    }

    changeset = Ankole.Pod.DbRecord.update_values_changeset(record, attrs)
    refute changeset.valid?
    assert MapSet.new(Keyword.keys(changeset.errors)) == MapSet.new(Map.keys(attrs))
    assert {:error, _changeset} = Repo.update(changeset)
    assert reload(record) == record
  end

  test "PostgreSQL rejects invalid Database counters, versions, and JSON shapes" do
    owner = human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{type: :database})

    {:ok, table} =
      Ankole.Pod.Database.create_table(
        Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
        page.id,
        %{}
      )

    {:ok, %{records: [_]}} =
      Ankole.Pod.Database.write_records(
        Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
        table.id,
        %{creates: [%{}]}
      )

    for {sql, constraint} <- [
          {"UPDATE db_tables SET record_count = -1", "db_tables_counters"},
          {"UPDATE db_tables SET data_version = -1", "db_tables_counters"},
          {"UPDATE db_tables SET next_auto_number = 0", "db_tables_counters"},
          {"UPDATE db_fields SET version = 0", "db_fields_version"},
          {"UPDATE db_views SET version = 0", "db_views_version"},
          {"UPDATE db_fields SET config = '[]'::jsonb", "db_fields_config_object"},
          {"UPDATE db_views SET config = '[]'::jsonb", "db_views_config_object"},
          {"UPDATE db_records SET data = '[]'::jsonb", "db_records_value_objects"},
          {"UPDATE db_records SET versions = '[]'::jsonb", "db_records_value_objects"}
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(sql <> " WHERE tenant_id = $1::text::uuid", [Repo.tenant_id!()],
            mode: :savepoint
          )
        end

      assert error.postgres.constraint == constraint
    end
  end

  test "a failed Database copy preserves its domain rejection and rolls back its new page" do
    owner = human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{type: :database})

    {:ok, %{tables: [table]}} =
      Ankole.Pod.Database.list_tables(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), page.id)

    before = Repo.aggregate(Page, :count)

    assert {:error, :invalid_query} =
             Ankole.Pod.Database.copy_table(
               Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
               table.id,
               %{
                 filter: %{conjunction: "invalid"}
               }
             )

    assert Repo.aggregate(Page, :count) == before
    assert Repo.aggregate(Ankole.Pod.DbTable, :count) == 1
  end

  defp reload(%schema{} = record) do
    Repo.get_by!(schema, Map.take(record, schema.__schema__(:primary_key)))
  end
end
