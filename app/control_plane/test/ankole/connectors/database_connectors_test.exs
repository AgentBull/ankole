defmodule Ankole.Connectors.DatabaseConnectorsTest do
  @moduledoc """
  Exercises the PostgreSQL database connector against a real, throwaway
  database and role on the devkit PostgreSQL server.
  """
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.Connectors.{Databases, Gateway, Store}
  alias Ankole.Security.SSRFFilter

  @toolkit "postgresql"

  setup_all do
    admin = server_options()
    suffix = System.unique_integer([:positive])
    database = "ankole_dbconn_#{suffix}"
    role = "ankole_dbconn_#{suffix}"
    password = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    with_connection(admin, fn conn ->
      Postgrex.query!(conn, "CREATE ROLE #{role} LOGIN PASSWORD '#{password}'", [])
      Postgrex.query!(conn, "CREATE DATABASE #{database} OWNER #{role}", [])
    end)

    with_connection(
      Keyword.merge(admin, database: database, username: role, password: password),
      fn conn ->
        for statement <- [
              "CREATE TABLE customers (id integer PRIMARY KEY, name text NOT NULL, city text, email text)",
              "COMMENT ON TABLE customers IS 'Customer master records'",
              "COMMENT ON COLUMN customers.city IS 'Billing city'",
              """
              CREATE TABLE orders (id integer PRIMARY KEY, customer_id integer REFERENCES customers(id),
                amount numeric(12, 2) NOT NULL, status text, created_at date)
              """,
              "CREATE SEQUENCE ticket_numbers",
              """
              CREATE FUNCTION touch_order() RETURNS integer LANGUAGE sql
                AS 'UPDATE orders SET status = status WHERE id = 1 RETURNING 1'
              """,
              """
              INSERT INTO customers
              SELECT g, 'Customer ' || g,
                     CASE g % 3 WHEN 0 THEN 'Beijing' WHEN 1 THEN 'Shanghai' ELSE ' Shenzhen ' END,
                     'c' || g || '@example.com'
              FROM generate_series(1, 30) g
              """,
              """
              INSERT INTO orders
              SELECT g, (g % 30) + 1, g * 1.25, CASE WHEN g % 2 = 0 THEN 'paid' ELSE 'open' END,
                     DATE '2026-01-01' + g
              FROM generate_series(1, 100) g
              """,
              "ANALYZE"
            ],
            do: Postgrex.query!(conn, statement, [])
      end
    )

    on_exit(fn ->
      with_connection(admin, fn conn ->
        Postgrex.query!(conn, "DROP DATABASE IF EXISTS #{database} WITH (FORCE)", [])
        Postgrex.query!(conn, "DROP ROLE IF EXISTS #{role}", [])
      end)
    end)

    %{
      external: %{
        "host" => admin[:hostname],
        "port" => admin[:port] || 5432,
        "database" => database,
        "username" => role,
        "password" => password
      }
    }
  end

  setup %{external: external} do
    %{principal: admin} = human_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)

    {:ok, config} =
      Store.create_auth_config(admin, %{
        "plugin_id" => "postgresql",
        "slug" => "warehouse",
        "display_name" => "Warehouse",
        "auth_scheme" => "password",
        "public_metadata" => %{
          "host" => external["host"],
          "port" => external["port"],
          "database" => external["database"],
          "tls_mode" => "disable",
          "sample_exclusions" => ["orders.status"]
        },
        "secret" => Map.take(external, ["username", "password"])
      })

    %{admin: admin, actor: actor_fixture(admin.uid), config: config}
  end

  test "saving a connection grants members and AI colleagues and queues a catalog refresh", ctx do
    assert_enqueued(
      worker: Ankole.Connectors.Jobs.RefreshDatabaseCatalog,
      args: %{"auth_config_id" => ctx.config.id}
    )

    assert %{access: %{"mode" => "members"}} = Store.public(ctx.config)
    %{principal: member} = human_fixture()
    assert {:ok, %{"rows" => [[1]]}} = query(actor_fixture(member.uid), "SELECT 1")
  end

  test "catalog refresh caches keys, comments, and masked profiles", ctx do
    assert {:ok, %{"table_count" => 2}} = Databases.refresh(ctx.admin, ctx.config.id)

    assert {:ok, %{"tables" => [%{"table" => "customers"} | _]}} =
             call(ctx.actor, "search_catalog", %{"query" => "billing"})

    assert {:ok, customers} = call(ctx.actor, "describe_table", %{"table" => "customers"})
    assert customers["comment"] == "Customer master records"
    assert customers["primary_key"] == ["id"]
    columns = Map.new(customers["columns"], &{&1["name"], &1})

    assert %{"comment" => "Billing city", "sensitive" => false, "profile" => city} =
             columns["city"]

    assert "Beijing" in city["sample_values"]
    assert city["low_cardinality"]
    assert %{"sensitive" => true, "profile" => nil} = columns["email"]
    assert columns["id"]["primary_key"] and columns["id"]["unique"]

    assert {:ok, orders} =
             call(ctx.actor, "describe_table", %{"schema" => "public", "table" => "orders"})

    orders = Map.new(orders["columns"], &{&1["name"], &1})

    assert orders["customer_id"]["foreign_key"] == %{
             "schema" => "public",
             "table" => "customers",
             "column" => "id"
           }

    assert %{"sensitive" => true, "profile" => nil} = orders["status"]
    assert orders["amount"]["profile"]["min"] == "1.25"
  end

  test "query returns an evidence envelope that marks truncation and fan-out", ctx do
    assert {:ok, result} =
             call(ctx.actor, "query", %{
               "sql" => "SELECT id, amount FROM orders ORDER BY id",
               "max_rows" => 5
             })

    assert %{
             "columns" => [%{"name" => "id", "type" => "integer"}, %{"name" => "amount"}],
             "rows" => [[1, "1.25"], [2, "2.50"] | _],
             "row_count" => 5,
             "truncated" => true,
             "sql" => "SELECT id, amount FROM orders ORDER BY id",
             "warnings" => []
           } = result

    assert {:ok, _, _} = DateTime.from_iso8601(result["data_timestamp"])
    assert String.starts_with?(hd(tl(result["columns"]))["type"], "numeric")

    assert {:ok, %{"truncated" => false, "warnings" => ["fanout_risk"]}} =
             call(ctx.actor, "query", %{
               "sql" =>
                 "SELECT c.city, sum(o.amount) FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.city"
             })

    assert {:ok, %{"rows" => [[50]], "truncated" => false}} =
             Ankole.Connectors.run_read_query(
               ctx.actor,
               "warehouse",
               "SELECT count(*) FROM orders WHERE status = $1",
               ["paid"]
             )
  end

  test "writes, statement batches, locking reads, and side effects are rejected", ctx do
    for {sql, code} <- [
          {"DELETE FROM orders", "not_read_only"},
          {"SELECT 1; SELECT 2", "multiple_statements"},
          {"SELECT * FROM orders FOR UPDATE", "locking_clause"},
          {"SELECT nextval('ticket_numbers')", "side_effect_function"},
          {"SELECT pg_notify('orders_ready', 'payload')", "side_effect_function"},
          # sql_inspect cannot see inside a user-defined function; the read-only session stops it.
          {"SELECT touch_order()", "not_read_only"}
        ] do
      assert {:error, %{code: ^code}} = call(ctx.actor, "query", %{"sql" => sql})
    end
  end

  test "the operator's statement timeout cancels long statements", ctx do
    limits = Ankole.Plugins.DatabaseConnectors.Config.defaults()

    assert {:ok, _} =
             AppConfigure.put_tenant_by_key(
               "connectors.database.limits",
               %{limits | "statement_timeout_ms" => 200}
             )

    assert {:error, %{code: "statement_timeout"}} =
             call(ctx.actor, "query", %{
               "sql" => "SELECT count(*) FROM generate_series(1, 500000000)"
             })
  end

  test "a rejected login fails the call without exposing the password", ctx do
    assert {:ok, _} =
             Store.update_auth_config(ctx.admin, ctx.config.id, %{
               "secret" => %{"password" => "wrong-password"}
             })

    assert {:error, %{code: "database_unavailable"} = error} =
             call(ctx.actor, "query", %{"sql" => "SELECT 1"})

    refute inspect(error) =~ "wrong-password"
  end

  test "the SSRF policy rejects a private database address", ctx do
    assert {:ok, true} = AppConfigure.put_global(SSRFFilter.definition(), true)
    on_exit(fn -> AppConfigure.put_global(SSRFFilter.definition(), false) end)

    assert {:error, %{code: "database_host_blocked"}} =
             call(ctx.actor, "query", %{"sql" => "SELECT 1"})
  end

  test "restricted connections admit only granted groups and Agents", ctx do
    %{principal: outsider} = human_fixture()
    %{principal: analyst} = human_fixture()
    agent = agent_fixture()

    {:ok, group} =
      Ankole.AuthZ.create_principal_group(%{
        name: "finance_#{System.unique_integer([:positive])}",
        display_name: "Finance",
        domain: :operator,
        kind: :static
      })

    {:ok, _} = Ankole.AuthZ.add_principal_to_group(analyst.uid, group.id)

    assert {:ok, updated} =
             Store.update_auth_config(ctx.admin, ctx.config.id, %{
               "access" => %{
                 "mode" => "restricted",
                 "group_ids" => [group.id],
                 "principal_uids" => [agent.principal.uid]
               }
             })

    assert %{access: %{"mode" => "restricted", "group_ids" => [group_id]}} = Store.public(updated)
    assert group_id == group.id

    assert {:error, %{code: "connection_forbidden"}} =
             call(actor_fixture(outsider.uid), "query", %{"sql" => "SELECT 1"})

    assert {:error, :connection_forbidden} =
             Ankole.Connectors.run_read_query(outsider, "warehouse", "SELECT 1")

    assert {:ok, %{"rows" => [[1]]}} = query(actor_fixture(analyst.uid), "SELECT 1")
    assert {:ok, %{"rows" => [[1]]}} = query(actor_fixture(agent.principal.uid), "SELECT 1")
  end

  test "probes report case-insensitive matches and keep sensitive columns to counts", ctx do
    assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)

    assert {:ok, %{"results" => [city, email, amount]}} =
             call(ctx.actor, "probe_values", %{
               "table" => "customers",
               "probes" => [
                 %{"column" => "city", "kind" => "match", "value" => "shenzhen"},
                 %{"column" => "email", "kind" => "distinct"},
                 %{"column" => "id", "kind" => "range"}
               ]
             })

    assert %{
             "exact_count" => 0,
             "masked" => false,
             "values" => [%{"value" => " Shenzhen ", "count" => 10}]
           } =
             city

    assert %{"masked" => true, "exact_count" => 30} = email
    refute Map.has_key?(email, "values")
    assert %{"min" => 1, "max" => 30, "row_count" => 30, "non_null_count" => 30} = amount

    assert {:error, %{code: "unknown_column"}} =
             call(ctx.actor, "probe_values", %{
               "table" => "customers",
               "probes" => [%{"column" => "missing", "kind" => "range"}]
             })
  end

  test "a published metric runs through the connection and a dropped column sends it to review",
       ctx do
    {:ok, _} = AppConfigure.put_tenant_by_key("brain.enabled", true)
    datasets = Ankole.BrainFixtures.category_fixture(ctx.admin.uid, "datasets")
    metrics = Ankole.BrainFixtures.category_fixture(ctx.admin.uid, "metrics")

    on_exit(fn ->
      with_external(ctx.external, &Postgrex.query!(&1, "DROP TABLE IF EXISTS refunds", []))
    end)

    with_external(ctx.external, fn conn ->
      Postgrex.query!(
        conn,
        "CREATE TABLE refunds (id integer PRIMARY KEY, amount numeric(12, 2))",
        []
      )

      Postgrex.query!(conn, "INSERT INTO refunds VALUES (1, 2.50), (2, 4.00)", [])
    end)

    assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)

    {:ok, dataset} =
      knowledge(ctx, datasets, "Refunds", %{
        "grain" => "one row per refund",
        "source" => %{
          "kind" => "connector",
          "connection" => "warehouse",
          "schema" => "public",
          "table" => "refunds"
        },
        "primary_key" => ["id"]
      })

    {:ok, metric} =
      knowledge(ctx, metrics, "Refund total", %{
        "dataset" => dataset.id,
        "grain" => "refund",
        "unit" => "CNY",
        "numerator" => "Refund amounts",
        "sql" => "SELECT sum(amount) AS value FROM public.refunds",
        "columns" => ["amount"]
      })

    assert {:ok, %{result: %{"rows" => [[total]]}}} =
             Ankole.Brain.execute_metric(ctx.actor, metric.id, :latest, %{})

    assert "#{total}" == "6.50"

    with_external(ctx.external, fn conn ->
      Postgrex.query!(conn, "ALTER TABLE refunds DROP COLUMN amount", [])
    end)

    assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)

    assert {:error, {:metric_needs_review, _}} =
             Ankole.Brain.execute_metric(ctx.actor, metric.id, :latest, %{})
  end

  test "explain returns the plan without running the statement", ctx do
    assert {:ok, %{"plan" => [%{"Plan" => %{"Node Type" => _}}]}} =
             call(ctx.actor, "explain", %{"sql" => "SELECT * FROM orders WHERE id = 1"})
  end

  test "export saves every row to a Pod CSV file and needs a writable route", ctx do
    {:ok, page} =
      Ankole.Pod.Pages.create(ctx.actor, %{
        type: "file",
        title: "orders.csv",
        private_owner_uid: ctx.admin.uid
      })

    export = %{"page_id" => page.id, "role" => "file", "name" => "orders.csv"}

    args = %{
      "sql" => "SELECT id, status FROM orders ORDER BY id",
      "max_rows" => 3,
      "export" => export
    }

    assert {:error, %{code: "read_only_route"}} = call(ctx.actor, "query", args, read_only: true)

    assert {:ok,
            %{
              "rows" => [[1, "open"], [2, "paid"], [3, "open"]],
              "truncated" => true,
              "file" => file
            }} =
             call(ctx.actor, "query", args)

    assert %{"row_count" => 100, "truncated" => false, "content_type" => "text/csv"} = file
    assert {:ok, page_id, path} = Ankole.Pod.Files.parse_path(file["file_ref"])
    assert {:ok, stored} = Ankole.Pod.Files.resolve_read(ctx.actor, page_id, path)
    assert {:ok, object} = Ankole.Files.fetch_object(stored.object_id)
    assert {:ok, csv} = Ankole.Files.read_object_range(object, 0, stored.size)
    assert String.starts_with?(csv, "id,status\r\n1,open\r\n2,paid\r\n")
    assert length(String.split(csv, "\r\n", trim: true)) == 101
  end

  test "a probe needs cached column types and masks binary columns by type", ctx do
    on_exit(fn ->
      with_external(ctx.external, &Postgrex.query!(&1, "DROP TABLE IF EXISTS documents", []))
    end)

    with_external(ctx.external, fn conn ->
      Postgrex.query!(conn, "CREATE TABLE documents (id integer PRIMARY KEY, payload bytea)", [])
      Postgrex.query!(conn, "INSERT INTO documents VALUES (1, $1)", [<<222, 173, 190, 239>>])
    end)

    probe = %{
      "table" => "documents",
      "probes" => [%{"column" => "payload", "kind" => "distinct"}]
    }

    assert {:error, %{code: "table_not_cataloged"}} = call(ctx.actor, "probe_values", probe)
    assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)

    assert {:ok, %{"results" => [%{"masked" => true, "exact_count" => 1} = result]}} =
             call(ctx.actor, "probe_values", probe)

    refute Map.has_key?(result, "values")
  end

  test "a saved sample exclusion hides cached samples before the next refresh", ctx do
    assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)
    assert {:ok, customers} = call(ctx.actor, "describe_table", %{"table" => "customers"})
    assert "Beijing" in column(customers, "city")["profile"]["sample_values"]

    metadata =
      Map.put(ctx.config.public_metadata, "sample_exclusions", ["orders.status", "customers.city"])

    assert {:ok, _} =
             Store.update_auth_config(ctx.admin, ctx.config.id, %{"public_metadata" => metadata})

    assert {:ok, stored} = Databases.describe_table(ctx.config, nil, "customers")
    assert %{"sensitive" => true, "profile" => nil} = column(stored, "city")
    assert column(stored, "name")["profile"]["sample_values"] != []

    assert {:ok, customers} = call(ctx.actor, "describe_table", %{"table" => "customers"})
    assert %{"sensitive" => true, "profile" => nil} = column(customers, "city")

    assert {:ok, %{"results" => [%{"masked" => true} = city]}} =
             call(ctx.actor, "probe_values", %{
               "table" => "customers",
               "probes" => [%{"column" => "city", "kind" => "distinct"}]
             })

    refute Map.has_key?(city, "values")
  end

  test "the byte budget bounds probes, plans, catalog samples, and export previews", ctx do
    assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)
    put_limits(%{"max_result_bytes" => 300})

    assert {:error, %{code: "result_too_large"}} =
             call(ctx.actor, "probe_values", %{
               "table" => "customers",
               "probes" => [%{"column" => "name", "kind" => "distinct"}]
             })

    assert {:error, %{code: "result_too_large"}} =
             call(ctx.actor, "explain", %{
               "sql" => "SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id"
             })

    assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)
    assert {:ok, customers} = call(ctx.actor, "describe_table", %{"table" => "customers"})
    assert column(customers, "city")["profile"]["sampled_rows"] in 1..29

    {:ok, page} =
      Ankole.Pod.Pages.create(ctx.actor, %{
        type: "file",
        title: "orders.csv",
        private_owner_uid: ctx.admin.uid
      })

    assert {:ok, %{"rows" => [[1, "open"] | _] = rows, "truncated" => true, "file" => file}} =
             call(ctx.actor, "query", %{
               "sql" => "SELECT id, status FROM orders ORDER BY id",
               "max_rows" => 50,
               "export" => %{"page_id" => page.id, "role" => "file", "name" => "orders.csv"}
             })

    assert length(rows) < 50
    assert :erlang.external_size(rows) <= 300
    assert %{"row_count" => 100, "truncated" => false} = file
  end

  test "a catalog cut at its table budget records the cut and reports only columns of the tables it holds",
       ctx do
    {:ok, _} = AppConfigure.put_tenant_by_key("brain.enabled", true)
    datasets = Ankole.BrainFixtures.category_fixture(ctx.admin.uid, "datasets")
    metrics = Ankole.BrainFixtures.category_fixture(ctx.admin.uid, "metrics")

    on_exit(fn ->
      with_external(ctx.external, &Postgrex.query!(&1, "DROP TABLE IF EXISTS a_refunds", []))
    end)

    with_external(ctx.external, fn conn ->
      Postgrex.query!(
        conn,
        "CREATE TABLE a_refunds (id integer PRIMARY KEY, amount numeric(12, 2))",
        []
      )

      Postgrex.query!(conn, "INSERT INTO a_refunds VALUES (1, 2.50)", [])
    end)

    assert {:ok, %{"table_count" => 3, "complete" => true}} =
             Databases.refresh(ctx.admin, ctx.config.id)

    assert %{catalog: %{table_count: 3, complete: true}} = Store.public(ctx.config)
    assert {:ok, %{"complete" => true}} = call(ctx.actor, "search_catalog", %{})

    # Catalog tables sort by schema and name, so a budget of two cuts orders.
    [refunds, orders] =
      for table <- ["a_refunds", "orders"] do
        {:ok, dataset} =
          knowledge(ctx, datasets, "Dataset #{table}", %{
            "grain" => "one row per #{table}",
            "source" => %{
              "kind" => "connector",
              "connection" => "warehouse",
              "schema" => "public",
              "table" => table
            },
            "primary_key" => ["id"]
          })

        {:ok, metric} =
          knowledge(ctx, metrics, "Total #{table}", %{
            "dataset" => dataset.id,
            "grain" => table,
            "unit" => "CNY",
            "numerator" => "Amounts",
            "sql" => "SELECT sum(amount) AS value FROM public.#{table}",
            "columns" => ["amount"]
          })

        metric
      end

    put_limits(%{"catalog_tables" => 2})

    with_external(ctx.external, fn conn ->
      Postgrex.query!(conn, "ALTER TABLE a_refunds DROP COLUMN amount", [])
    end)

    assert {:ok, %{"table_count" => 2, "complete" => false}} =
             Databases.refresh(ctx.admin, ctx.config.id)

    assert %{catalog: %{table_count: 2, complete: false}} = Store.public(ctx.config)

    assert {:ok, %{"complete" => false, "tables" => [_, _]}} =
             call(ctx.actor, "search_catalog", %{})

    assert {:ok, %{result: %{"rows" => [[_total]]}}} =
             Ankole.Brain.execute_metric(ctx.actor, orders.id, :latest, %{})

    assert {:error, {:metric_needs_review, _}} =
             Ankole.Brain.execute_metric(ctx.actor, refunds.id, :latest, %{})
  end

  defp column(table, name), do: Enum.find(table["columns"], &(&1["name"] == name))

  defp put_limits(changes) do
    limits = Map.merge(Ankole.Plugins.DatabaseConnectors.Config.defaults(), changes)
    assert {:ok, _} = AppConfigure.put_tenant_by_key("connectors.database.limits", limits)
  end

  defp query(actor, sql), do: call(actor, "query", %{"sql" => sql})

  defp call(actor, name, args, opts \\ []) do
    request = %{"method" => "tools/call", "params" => %{"name" => name, "arguments" => args}}
    context = %{actor: actor, read_only: Keyword.get(opts, :read_only, false)}

    case Gateway.request({:toolkit, @toolkit}, request, context, %{"connection" => "warehouse"}) do
      {:ok, %{"structuredContent" => content}} -> {:ok, content}
      error -> error
    end
  end

  defp server_options do
    config = Ankole.Repo.config()

    url =
      if config[:url], do: Ecto.Repo.Supervisor.parse_url(config[:url]), else: []

    config
    |> Keyword.merge(url)
    |> Keyword.take([:hostname, :port, :username, :password])
    |> Keyword.put(:database, "postgres")
  end

  defp knowledge(ctx, category, title, metadata) do
    Ankole.Pod.Pages.create(ctx.actor, %{
      type: :knowledge,
      parent_id: category.id,
      title: title,
      xml: "<page><p>#{title}</p></page>",
      metadata: metadata
    })
  end

  defp with_external(external, fun) do
    server_options()
    |> Keyword.merge(
      database: external["database"],
      username: external["username"],
      password: external["password"]
    )
    |> with_connection(fun)
  end

  defp with_connection(options, fun) do
    {:ok, conn} = Postgrex.start_link(Keyword.put(options, :pool_size, 1))

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end
end
