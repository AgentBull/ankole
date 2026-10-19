defmodule AnkoleWeb.PodDatabaseControllerTest do
  use AnkoleWeb.ConnCase, async: false
  alias Ankole.Pod.{DbSyncBinding, Pages}
  alias Ankole.Repo

  setup do
    allow_cache_database_access()
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  test "browser schema, record batches, query, conflicts, and copy use plain JSON", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    created = post(conn, "/.internal-apis/pod/pages", %{type: "database", title: "Orders"})
    assert %{"page" => %{"id" => page_id}} = json_response(created, 200)

    table_conn =
      created
      |> recycle_api()
      |> post("/.internal-apis/pod/databases/#{page_id}/tables", %{name: "Orders"})

    assert %{"table" => %{"id" => table_id}} = json_response(table_conn, 200)

    field_conn =
      table_conn
      |> recycle_api()
      |> post("/.internal-apis/pod/tables/#{table_id}/fields", %{name: "Amount", type: "number"})

    assert %{"field" => %{"id" => field_id, "type" => "number", "version" => 1}} =
             json_response(field_conn, 200)

    written =
      field_conn
      |> recycle_api()
      |> post("/.internal-apis/pod/tables/#{table_id}/records", %{
        creates: [%{data: %{field_id => 7}}]
      })

    assert %{
             "records" => [
               %{
                 "id" => record_id,
                 "created_at" => timestamp,
                 "created_by" => author,
                 "versions" => versions
               }
             ]
           } = json_response(written, 200)

    assert {:ok, _, _} = DateTime.from_iso8601(timestamp)
    assert author =~ ":principal/#{uid}"

    queried =
      written |> recycle_api() |> post("/.internal-apis/pod/tables/#{table_id}/query", %{})

    assert %{"records" => [%{"data" => %{^field_id => 7}}], "complete" => true} =
             json_response(queried, 200)

    stale =
      queried
      |> recycle_api()
      |> patch("/.internal-apis/pod/fields/#{field_id}", %{version: 0, name: "Stale"})

    assert %{"error" => %{"code" => "schema_conflict", "details" => %{"type" => "number"}}} =
             json_response(stale, 409)

    Repo.put_tenant_id(tenant.id)
    {:ok, report} = Pages.create(uid, %{title: "Report"})

    copied =
      stale
      |> recycle_api()
      |> post("/.internal-apis/pod/tables/#{table_id}/copy", %{parent_id: report.id})

    assert %{"page" => %{"type" => "database"}, "table" => %{"record_count" => 1}} =
             json_response(copied, 200)

    changed =
      copied
      |> recycle_api()
      |> post("/.internal-apis/pod/tables/#{table_id}/records", %{
        updates: [%{id: record_id, data: %{field_id => 8}, expected_versions: versions}]
      })

    assert %{"records" => [%{"updated_at" => updated}]} = json_response(changed, 200)
    assert {:ok, _, _} = DateTime.from_iso8601(updated)
  end

  test "paused sync fields remain read-only in schema and reject destructive schema edits", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    {:ok, page} = Pages.create(uid, %{type: "database"})
    {:ok, table} = Ankole.Pod.Database.create_table(uid, page.id, %{name: "Synced"})
    field = hd(Ankole.Pod.Database.fields(table.id))

    Repo.insert!(
      DbSyncBinding.changeset(%DbSyncBinding{}, %{
        table_id: table.id,
        connector: "fixture",
        source: %{},
        field_map: %{"title" => field.id},
        status: :paused,
        created_by: Ankole.ActorRef.from_writer(uid, tenant.id, []),
        created_at: DateTime.utc_now(:microsecond)
      })
    )

    schema = get(conn, "/.internal-apis/pod/tables/#{table.id}")

    assert %{
             "readonly_field_ids" => [id],
             "fields" => [%{"type" => "text"}],
             "timezone" => timezone
           } = json_response(schema, 200)

    assert id == field.id
    assert is_binary(timezone)

    changed =
      schema
      |> recycle_api()
      |> patch("/.internal-apis/pod/fields/#{field.id}", %{version: 1, type: "number"})

    assert %{"error" => %{"code" => "synced_field_readonly"}} = json_response(changed, 422)

    renamed =
      changed
      |> recycle_api()
      |> patch("/.internal-apis/pod/fields/#{field.id}", %{version: 1, name: "New title"})

    assert %{"field" => %{"name" => "New title"}} = json_response(renamed, 200)

    deleted =
      renamed |> recycle_api() |> delete("/.internal-apis/pod/fields/#{field.id}", %{version: 2})

    assert %{"error" => %{"code" => "synced_field_readonly"}} = json_response(deleted, 422)
  end
end
