defmodule AnkoleWeb.PodDatabaseControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod

  alias Ankole.Pod.Pages
  alias Ankole.Repo

  setup do
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  test "browser schema, record batches, query, conflicts, and copy use JSON:API", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    created = api_post(conn, "/api/v2/pod/pages", %{type: "database", title: "Orders"})
    assert %{"page" => %{"id" => page_id}} = api_response(created, 200)

    table_conn =
      created
      |> recycle_api()
      |> api_post("/api/v2/pod/databases/#{page_id}/tables", %{name: "Orders"})

    assert %{"table" => %{"id" => table_id}} = api_response(table_conn, 200)

    field_conn =
      table_conn
      |> recycle_api()
      |> api_post("/api/v2/pod/tables/#{table_id}/fields", %{name: "Amount", type: "number"})

    assert %{"field" => %{"id" => field_id, "type" => "number", "version" => 1}} =
             api_response(field_conn, 200)

    written =
      field_conn
      |> recycle_api()
      |> api_post("/api/v2/pod/tables/#{table_id}/records", %{
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
           } = api_response(written, 200)

    assert {:ok, _, _} = DateTime.from_iso8601(timestamp)
    assert author =~ ":principal/#{uid}"

    queried =
      written |> recycle_api() |> api_post("/api/v2/pod/tables/#{table_id}/query", %{})

    assert %{"records" => [%{"data" => %{^field_id => 7}}], "complete" => true} =
             api_response(queried, 200)

    filter = %{
      conjunction: "or",
      conditions: [%{field_id: field_id, operator: "gt", value: 6}]
    }

    filtered =
      queried
      |> recycle_api()
      |> api_post("/api/v2/pod/tables/#{table_id}/query", %{
        filter: filter,
        sort: [%{field_id: field_id, direction: "desc"}]
      })

    assert %{"records" => [%{"id" => ^record_id}]} = api_response(filtered, 201)

    aggregated =
      filtered
      |> recycle_api()
      |> api_post("/api/v2/pod/tables/#{table_id}/aggregate", %{
        filter: filter,
        group_by: [],
        metrics: [%{operation: "sum", field_id: field_id, alias: "total"}]
      })

    assert %{"groups" => [%{"metrics" => %{"total" => 7}}]} = api_response(aggregated, 201)

    renamed =
      queried
      |> recycle_api()
      |> api_patch("/api/v2/pod/fields/#{field_id}", %{version: 1, name: "Total"})

    assert %{"field" => %{"version" => 2, "name" => "Total"}} = api_response(renamed, 200)

    stale =
      renamed
      |> recycle_api()
      |> api_patch("/api/v2/pod/fields/#{field_id}", %{version: 1, name: "Stale"})

    assert %{
             "errors" => [
               %{"code" => "schema_conflict", "meta" => %{"details" => %{"type" => "number"}}}
             ]
           } =
             api_response(stale, 409)

    Repo.put_tenant_id(tenant.id)
    {:ok, report} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{title: "Report"})

    copied =
      stale
      |> recycle_api()
      |> api_post("/api/v2/pod/tables/#{table_id}/copy", %{parent_id: report.id})

    assert %{"page" => %{"type" => "database"}, "table" => %{"record_count" => 1}} =
             api_response(copied, 200)

    changed =
      copied
      |> recycle_api()
      |> api_post("/api/v2/pod/tables/#{table_id}/records", %{
        updates: [%{id: record_id, data: %{field_id => 8}, expected_versions: versions}]
      })

    assert %{"records" => [%{"updated_at" => updated}]} = api_response(changed, 200)
    assert {:ok, _, _} = DateTime.from_iso8601(updated)
  end
end
