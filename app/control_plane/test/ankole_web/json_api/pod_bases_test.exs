defmodule AnkoleWeb.JSONAPI.PodBasesTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod

  alias Ankole.Pod.Pages
  alias Ankole.Repo

  test "browser schema, record batches, query, conflicts, and copy use JSON:API", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    created = api_post(conn, "/api/v2/pod/pages", %{type: "base", title: "Orders"})
    assert %{"page" => %{"id" => page_id}} = api_response(created, 200)

    table_conn =
      created
      |> recycle_api()
      |> api_post("/api/v2/pod/bases/#{page_id}/tables", %{name: "Orders"})

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

    assert %{"page" => %{"type" => "base"}, "table" => %{"record_count" => 1}} =
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

  test "browser table and field descriptions round-trip through the Pod HTTP contract", %{
    conn: conn
  } do
    {conn, _uid} = console_conn_with_principal(conn)
    created = api_post(conn, "/api/v2/pod/pages", %{type: "base", title: "Ledger"})
    assert %{"page" => %{"id" => page_id}} = api_response(created, 200)

    table_conn =
      created
      |> recycle_api()
      |> api_post("/api/v2/pod/bases/#{page_id}/tables", %{
        name: "Payments",
        description: "Incoming payments from the bank feed"
      })

    assert %{
             "table" => %{
               "id" => table_id,
               "description" => "Incoming payments from the bank feed"
             }
           } =
             api_response(table_conn, 200)

    field_conn =
      table_conn
      |> recycle_api()
      |> api_post("/api/v2/pod/tables/#{table_id}/fields", %{
        name: "Amount",
        type: "number",
        description: "USD, before tax"
      })

    assert %{"field" => %{"id" => field_id, "description" => "USD, before tax"}} =
             api_response(field_conn, 200)

    cleared =
      field_conn
      |> recycle_api()
      |> api_patch("/api/v2/pod/fields/#{field_id}", %{version: 1, description: ""})

    assert %{"field" => %{"version" => 2, "description" => ""}} = api_response(cleared, 200)

    configured =
      cleared
      |> recycle_api()
      |> api_put("/api/v2/pod/tables/#{table_id}/settings", %{description: "Settled payments"})

    assert %{"table" => %{"description" => "Settled payments"}} = api_response(configured, 200)

    rejected =
      configured
      |> recycle_api()
      |> api_put("/api/v2/pod/tables/#{table_id}/settings", %{
        description: String.duplicate("x", 2049)
      })

    assert %{"code" => "description_size_limit"} = api_error(rejected, 422)

    schema = rejected |> recycle_api() |> api_get("/api/v2/pod/tables/#{table_id}")

    assert %{"table" => %{"description" => "Settled payments"}, "fields" => fields} =
             api_response(schema, 200)

    assert Enum.find(fields, &(&1["id"] == field_id))["description"] == ""
  end

  test "aggregates follow link paths through the typed Pod HTTP contract", %{conn: conn} do
    {conn, _uid} = console_conn_with_principal(conn)
    created = api_post(conn, "/api/v2/pod/pages", %{type: "base", title: "Shop"})
    assert %{"page" => %{"id" => page_id}} = api_response(created, 200)

    post = fn conn, path, body -> conn |> recycle_api() |> api_post(path, body) end
    orders_conn = post.(created, "/api/v2/pod/bases/#{page_id}/tables", %{name: "Orders"})
    assert %{"table" => %{"id" => orders}} = api_response(orders_conn, 200)
    products_conn = post.(orders_conn, "/api/v2/pod/bases/#{page_id}/tables", %{name: "Products"})
    assert %{"table" => %{"id" => products}} = api_response(products_conn, 200)

    category_conn =
      post.(products_conn, "/api/v2/pod/tables/#{products}/fields", %{
        name: "Category",
        type: "text"
      })

    assert %{"field" => %{"id" => category}} = api_response(category_conn, 200)

    link_conn =
      post.(category_conn, "/api/v2/pod/tables/#{orders}/fields", %{
        name: "Product",
        type: "link",
        config: %{table_id: products, multiple: false}
      })

    assert %{"field" => %{"id" => product}} = api_response(link_conn, 200)

    product_conn =
      post.(link_conn, "/api/v2/pod/tables/#{products}/records", %{
        creates: [%{data: %{category => "tools"}}]
      })

    assert %{"records" => [%{"id" => tool}]} = api_response(product_conn, 200)

    order_conn =
      post.(product_conn, "/api/v2/pod/tables/#{orders}/records", %{
        creates: [%{data: %{product => [tool]}}, %{data: %{}}]
      })

    assert %{"records" => [_, _]} = api_response(order_conn, 200)

    aggregated =
      post.(order_conn, "/api/v2/pod/tables/#{orders}/aggregate", %{
        filter: %{
          conjunction: "and",
          conditions: [
            %{
              operator: "exists",
              path: [product],
              filter: %{
                conjunction: "and",
                conditions: [%{field_id: category, operator: "is", value: "tools"}]
              }
            }
          ]
        },
        group_by: [%{field_id: category, path: [product]}],
        metrics: [%{operation: "count", alias: "orders"}]
      })

    assert %{
             "groups" => [%{"values" => ["tools"], "metrics_text" => %{"orders" => "1"}}],
             "data_versions" => %{^orders => _, ^products => _}
           } = api_response(aggregated, 201)
  end
end
