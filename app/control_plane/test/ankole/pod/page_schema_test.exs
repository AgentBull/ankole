defmodule Ankole.Pod.PageSchemaTest do
  use Ankole.DataCase, async: false

  alias Ankole.Pod.{DbField, DbRecord, DbTable, DbView}
  alias Ankole.Pod.{Page, PageChange, PageContent, PageUserState}

  @schemas [
    Page,
    PageContent,
    PageChange,
    PageUserState,
    DbTable,
    DbField,
    DbView,
    DbRecord
  ]
  @author "ankole:019a2b00-0000-7000-8000-000000000001:principal/system"

  test "empty titles and empty derived text survive writes and updates" do
    page = new_page()
    assert Repo.get!(Page, page.id).title == ""

    content =
      insert!(PageContent, %{
        page_id: page.id,
        content: "<page />",
        plain_text: "",
        updated_by: @author,
        updated_at: now()
      })

    assert Repo.reload!(content).plain_text == ""
    page = update!(page, :edit, %{title: "Named", icon: ""})
    assert page.icon == ""
    assert update!(page, :edit, %{title: ""}).title == ""
    content = update!(content, :replace, %{plain_text: "text"})
    assert update!(content, :replace, %{plain_text: ""}).plain_text == ""
    refute action_changeset(page, :edit, %{title: nil}).valid?
    refute action_changeset(content, :replace, %{plain_text: nil}).valid?
  end

  test "all Page and Database schemas require a tenant context for reads and writes" do
    Repo.without_tenant(fn ->
      for schema <- @schemas do
        assert_raise Ankole.TenantContextMissing, fn -> Repo.all(schema) end
        assert_raise Ankole.TenantContextMissing, fn -> Repo.insert(struct(schema)) end
      end
    end)
  end

  test "another tenant cannot read, update, or delete an owned page" do
    page = new_page()
    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert Repo.get(Page, page.id) == nil
      assert Repo.all(Page) == []
      assert_raise ArgumentError, fn -> Repo.update(change(page, title: "Changed")) end
      assert_raise ArgumentError, fn -> Repo.delete(page) end
    end)

    assert Repo.get!(Page, page.id).title == page.title
  end

  test "the database rejects a missing tenant and invalid page states", %{tenant: tenant} do
    page = new_page()
    args = [tenant.id, page.id]
    where = " WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid"

    assert_sql_constraint(
      "UPDATE pages SET type = 'spreadsheet'" <> where,
      args,
      "pages_type_check"
    )

    assert_sql_constraint(
      "UPDATE pages SET purge_started_at = now()" <> where,
      args,
      "pages_purge_state"
    )

    assert_sql_constraint(
      "UPDATE pages SET parent_id = id, inherit_permissions = false, parent_anchor_id = $3::text::uuid, private_owner_uid = 'owner'" <>
        where,
      args ++ [new_page().id],
      "pages_private_owner"
    )

    missing = Ankole.Ecto.UUIDv7.autogenerate()

    assert_sql_constraint(
      "UPDATE pages SET tenant_id = $3::text::uuid" <> where,
      args ++ [missing],
      "pages_tenant_id_fkey"
    )

    assert Repo.get!(Page, page.id).type == :doc
  end

  test "composite references cannot cross a tenant boundary" do
    other = create_tenant()
    foreign_page = Repo.with_tenant(other.id, fn -> new_page(%{type: :database}) end)
    foreign_table = Repo.with_tenant(other.id, fn -> new_table(foreign_page) end)

    assert_constraint(
      action_changeset(
        Page,
        page_attrs(%{
          parent_id: foreign_page.id,
          inherit_permissions: false,
          parent_anchor_id: foreign_page.id
        })
      ),
      "pages_tenant_id_parent_id_fkey"
    )

    assert_constraint(
      action_changeset(DbTable, %{page_id: foreign_page.id, name: "Table", position: "a"}),
      "db_tables_tenant_id_page_id_fkey"
    )

    assert {:error, changeset} =
             foreign_table.id |> record_attrs() |> DbRecord.create_changeset() |> Repo.insert()

    assert {_message,
            [constraint: :foreign, constraint_name: "db_records_tenant_id_table_id_fkey"]} =
             changeset.errors[:table_id]

    assert_constraint(
      action_changeset(PageChange, change_attrs(foreign_page.id, :reset)),
      "page_changes_tenant_id_page_id_fkey"
    )
  end

  test "real editor ChangeSet JSON round-trips through one JSONB column" do
    page = new_page()
    changes = editor_changes()
    assert is_list(changes)
    entry = insert!(PageChange, change_attrs(page.id, :change))

    assert Repo.get_by!(PageChange, page_id: entry.page_id, revision: entry.revision).changes ==
             changes

    assert Repo.query!(
             "SELECT jsonb_typeof(changes) FROM page_changes WHERE tenant_id = $1::text::uuid AND page_id = $2::text::uuid",
             [Repo.tenant_id!(), page.id]
           ).rows == [["array"]]

    empty =
      insert!(PageChange, %{
        change_attrs(page.id, :change)
        | revision: 2,
          client_seq: 2,
          changes: []
      })

    assert empty.changes == []
    refute Ash.Resource.Info.action(PageChange, :update)

    for invalid <- [%{"sections" => []}, [self()], ["bad\0text"], [<<255>>]] do
      refute action_changeset(
               PageChange,
               Map.put(change_attrs(page.id, :change), :changes, invalid)
             ).valid?
    end
  end

  test "reset entries reject every partial change payload in both layers", %{tenant: tenant} do
    page = new_page()
    attrs = change_attrs(page.id, :reset)
    reset = insert!(PageChange, attrs)
    assert {reset.client_id, reset.client_seq, reset.changes} == {nil, nil, nil}

    for patch <- [%{client_id: "editor"}, %{client_seq: 1}, %{changes: []}] do
      refute action_changeset(PageChange, Map.merge(attrs, patch)).valid?
    end

    for assignment <- ["client_id = 'editor'", "client_seq = 1", "changes = '[]'::jsonb"] do
      assert_sql_constraint(
        "UPDATE page_changes SET " <>
          assignment <>
          " WHERE tenant_id = $1::text::uuid AND page_id = $2::text::uuid",
        [tenant.id, page.id],
        "page_changes_entry_shape"
      )
    end

    refute action_changeset(PageChange, Map.delete(change_attrs(page.id, :change), :changes)).valid?
  end

  test "one revision and one client sequence can be stored only once" do
    page = new_page()
    attrs = change_attrs(page.id, :change)
    insert!(PageChange, attrs)

    assert_constraint(
      action_changeset(PageChange, %{attrs | revision: 2}),
      "page_changes_tenant_id_page_id_client_id_client_seq_key"
    )

    assert_constraint(
      action_changeset(PageChange, %{attrs | client_seq: 2}),
      "page_changes_pkey"
    )
  end

  test "editor batches report each missing field while resets reject each supplied field" do
    page = new_page()
    payload = %{client_id: "editor", client_seq: 0, changes: []}

    for kind <- [:change, :reset],
        fields <- [[], [:client_id], [:client_seq], [:changes], Map.keys(payload)] do
      attrs =
        change_attrs(page.id, :reset)
        |> Map.put(:kind, kind)
        |> Map.merge(Map.take(payload, fields))

      rejected_fields = if kind == :change, do: Map.keys(payload) -- fields, else: fields
      message = if kind == :change, do: "is required", else: "is not part of a reset entry"

      if rejected_fields != [] do
        assert {:error, error} =
                 Repo.transact(fn -> Ankole.Ash.create(PageChange, :append, attrs) end)

        assert Enum.sort(Ankole.Ash.validation_details(error)) ==
                 Enum.sort(Enum.map(rejected_fields, &%{path: to_string(&1), message: message}))
      end
    end

    assert Repo.aggregate(PageChange, :count) == 0
    assert insert!(PageChange, Map.merge(change_attrs(page.id, :change), payload)).client_seq == 0
  end

  test "the database rejects a non-array change payload", %{tenant: tenant} do
    page = new_page()
    insert!(PageChange, change_attrs(page.id, :change))

    assert_sql_constraint(
      "UPDATE page_changes SET changes = '{}'::jsonb WHERE tenant_id = $1::text::uuid AND page_id = $2::text::uuid",
      [tenant.id, page.id],
      "page_changes_entry_shape"
    )
  end

  test "page states have the same primary key in Ecto and PostgreSQL" do
    page = new_page()

    attrs = %{
      principal_uid: Ankole.Ecto.UUIDv7.autogenerate(),
      page_id: page.id,
      visited_at: now()
    }

    state = insert!(PageUserState, attrs)
    assert insert!(PageUserState, Map.put(attrs, :favorited_at, now())).favorited_at

    assert Repo.get_by!(PageUserState, principal_uid: state.principal_uid, page_id: page.id).visited_at ==
             state.visited_at

    assert_sql_constraint(
      "INSERT INTO page_user_states SELECT * FROM page_user_states WHERE tenant_id = $1::text::uuid AND page_id = $2::text::uuid",
      [Repo.tenant_id!(), page.id],
      "page_user_states_pkey"
    )

    for {schema, fields} <- [
          {PageContent, [:page_id]},
          {PageChange, [:tenant_id, :page_id, :revision]},
          {PageUserState, [:tenant_id, :principal_uid, :page_id]},
          {DbRecord, [:tenant_id, :table_id, :id]}
        ] do
      %{rows: [[stored_fields]]} =
        Repo.query!(
          """
          SELECT array_agg(attribute.attname::text ORDER BY key.position)
          FROM pg_constraint AS stored_key
          JOIN LATERAL unnest(stored_key.conkey) WITH ORDINALITY AS key(attnum, position) ON true
          JOIN pg_attribute AS attribute
            ON attribute.attrelid = stored_key.conrelid AND attribute.attnum = key.attnum
          WHERE stored_key.contype = 'p' AND stored_key.conrelid = $1::text::regclass
          """,
          [schema.__schema__(:source)]
        )

      assert MapSet.new(schema.__schema__(:primary_key)) == MapSet.new(fields)
      assert MapSet.new(stored_fields) == MapSet.new(Enum.map(fields, &Atom.to_string/1))
    end
  end

  test "field names and the primary field are unique" do
    table = new_table(new_page(%{type: :database}))
    attrs = %{table_id: table.id, name: "Title", position: "a", type: :text, is_primary: true}
    insert!(DbField, attrs)

    assert_constraint(
      action_changeset(DbField, %{attrs | is_primary: false}),
      "db_fields_name_index"
    )

    assert_constraint(
      action_changeset(DbField, %{attrs | name: "Other"}),
      "db_fields_one_primary_index"
    )
  end

  test "accepts the declared view and field types", %{tenant: tenant} do
    table = new_table(new_page(%{type: :database}))

    for type <- Ash.Resource.Info.attribute(DbView, :type).constraints[:one_of] do
      view =
        insert!(DbView, %{
          table_id: table.id,
          name: "View",
          position: "a",
          type: type
        })

      assert Repo.reload!(view).type == type
    end

    for type <- Ash.Resource.Info.attribute(DbField, :type).constraints[:one_of] do
      field =
        insert!(DbField, %{
          table_id: table.id,
          name: to_string(type),
          position: "a",
          type: type
        })

      assert Repo.reload!(field).type == type
    end

    view = Repo.one!(from v in DbView, limit: 1)
    field = Repo.one!(from f in DbField, limit: 1)

    assert_sql_constraint(
      "UPDATE db_views SET type = 'timeline' WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid",
      [tenant.id, view.id],
      "db_views_type_check"
    )

    assert_sql_constraint(
      "UPDATE db_fields SET type = 'rich_text' WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid",
      [tenant.id, field.id],
      "db_fields_type_check"
    )
  end

  defp action(PageChange), do: :append
  defp action(PageUserState), do: :put
  defp action(_resource), do: :create_in_tx

  defp action_changeset(resource, attrs) do
    {:ok, changeset} =
      Repo.transact(fn _ -> {:ok, Ankole.Ash.for_create(resource, action(resource), attrs)} end)

    changeset
  end

  defp action_changeset(record, action, attrs) do
    {:ok, changeset} =
      Repo.transact(fn _ -> {:ok, Ankole.Ash.for_update(record, action, attrs)} end)

    changeset
  end

  defp insert!(resource, attrs) do
    {:ok, record} =
      Repo.transact(fn _ -> Ankole.Ash.create(resource, action(resource), attrs) end)

    record
  end

  defp update!(record, action, attrs) do
    {:ok, record} = Repo.transact(fn _ -> Ankole.Ash.update(record, action, attrs) end)
    record
  end

  defp assert_constraint(%Ash.Changeset{} = changeset, name) do
    assert changeset.valid?, inspect(changeset.errors)
    assert {:error, rejected} = Repo.transact(fn _ -> Ankole.Ash.create(changeset) end)

    assert Enum.any?(rejected.errors, fn
             %Ash.Error.Changes.InvalidAttribute{private_vars: vars} -> vars[:constraint] == name
             _error -> false
           end),
           inspect(rejected.errors)
  end

  defp assert_sql_constraint(sql, params, name) do
    error = assert_raise Postgrex.Error, fn -> Repo.query!(sql, params, mode: :savepoint) end
    assert error.postgres.constraint == name
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp page_attrs(attrs),
    do:
      Map.merge(
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          type: :doc,
          title: "",
          position: "a",
          created_by: @author,
          created_at: now(),
          updated_at: now()
        },
        attrs
      )
      |> then(fn attrs -> Map.put(attrs, :acl_anchor_id, attrs.id) end)

  defp new_page(attrs \\ %{}), do: insert!(Page, page_attrs(attrs))

  defp new_table(page),
    do: insert!(DbTable, %{page_id: page.id, name: "Table", position: "a"})

  defp record_attrs(table_id),
    do: %{
      table_id: table_id,
      data: %{},
      versions: %{},
      created_by: @author,
      created_at: now(),
      updated_by: @author,
      updated_at: now()
    }

  defp change_attrs(page_id, :reset),
    do: %{page_id: page_id, revision: 1, kind: :reset, author: @author, created_at: now()}

  defp change_attrs(page_id, :change),
    do:
      Map.merge(
        change_attrs(page_id, :reset),
        %{kind: :change, client_id: "editor", client_seq: 1, changes: editor_changes()}
      )

  defp editor_changes do
    Path.expand("../../../../../libs/ankole-editor/corpus/rust/index.json", __DIR__)
    |> File.read!()
    |> Ankole.JSON.decode!()
    |> get_in(["edits", Access.at(0), "batches", Access.at(0), "changes"])
  end
end
