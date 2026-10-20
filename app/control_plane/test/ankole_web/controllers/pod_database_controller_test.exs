defmodule AnkoleWeb.PodDatabaseControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import OpenApiSpex.TestAssertions

  alias Ankole.Pod.Pages
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

    assert_schema(
      hd(json_response(written, 200)["records"]),
      "PodRecord",
      AnkoleWeb.InternalAPISpec.spec()
    )

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
end
