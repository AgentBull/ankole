defmodule Ankole.Connectors.ExternalDatabaseHelpers do
  @moduledoc false
  # Tool calls, TLS checks, and Brain fixtures shared by the external database suites below.
  import ExUnit.Assertions
  import Ankole.PrincipalsFixtures
  alias Ankole.AppConfigure
  alias Ankole.Connectors.{Gateway, Store}

  def connection(toolkit, metadata, secret) do
    %{principal: admin} = human_fixture()
    {:ok, _} = Ankole.Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)

    {:ok, config} =
      Store.create_auth_config(admin, %{
        "plugin_id" => toolkit,
        "slug" => "warehouse",
        "display_name" => "Warehouse",
        "auth_scheme" => "password",
        "public_metadata" =>
          Map.merge(
            %{"tls_mode" => "disable", "sample_exclusions" => ["orders.status"]},
            metadata
          ),
        "secret" => secret
      })

    %{admin: admin, actor: actor_fixture(admin.uid), config: config, toolkit: toolkit}
  end

  def call(ctx, name, args) do
    request = %{"method" => "tools/call", "params" => %{"name" => name, "arguments" => args}}
    context = %{actor: ctx.actor, read_only: false}

    case Gateway.request({:toolkit, ctx.toolkit}, request, context, %{"connection" => "warehouse"}) do
      {:ok, %{"structuredContent" => content}} -> {:ok, content}
      error -> error
    end
  end

  def column(table, name), do: Enum.find(table["columns"], &(&1["name"] == name))

  @doc "Exports `sql` to a new Pod CSV file and returns the call result and the file's text."
  def export(ctx, sql, max_rows) do
    export = export_destination(ctx)

    assert {:ok, %{"file" => file} = result} =
             call(ctx, "query", %{"sql" => sql, "max_rows" => max_rows, "export" => export})

    assert {:ok, page_id, path} = Ankole.Pod.Files.parse_path(file["file_ref"])
    assert {:ok, stored} = Ankole.Pod.Files.resolve_read(ctx.actor, page_id, path)
    assert {:ok, object} = Ankole.Files.fetch_object(stored.object_id)
    assert {:ok, csv} = Ankole.Files.read_object_range(object, 0, stored.size)
    {result, csv}
  end

  @doc "Exports a failing `sql`, checks that the Page received no file, and returns the error."
  def failed_export(ctx, sql) do
    export = export_destination(ctx)
    assert {:error, error} = call(ctx, "query", %{"sql" => sql, "export" => export})
    assert {:ok, %{files: []}} = Ankole.Pod.Files.manifest(ctx.actor, export["page_id"])
    error
  end

  defp export_destination(ctx) do
    {:ok, page} =
      Ankole.Pod.Pages.create(ctx.actor, %{
        type: "file",
        title: "orders.csv",
        private_owner_uid: ctx.admin.uid
      })

    %{"page_id" => page.id, "role" => "file", "name" => "orders.csv"}
  end

  @doc """
  Points the connection at `host` and `port` and checks each TLS mode: `require`
  connects, `verify` connects with the CA in `ca_file` and the host name that
  the server certificate lists, and `verify` fails with another CA or with the
  host's IP address, which the certificate does not list.
  """
  def assert_tls_modes(ctx, host, port, ca_file) do
    ca = File.read!(ca_file)
    %{cert: other} = :public_key.pkix_test_root_cert(~c"Ankole Other CA", [])
    other_ca = :public_key.pem_encode([{:Certificate, other, :not_encrypted}])
    {:ok, address} = :inet.getaddr(String.to_charlist(host), :inet)
    ip = to_string(:inet.ntoa(address))

    query = fn tls, host, pem ->
      metadata =
        Map.merge(ctx.config.public_metadata, %{
          "host" => host,
          "port" => port,
          "tls_mode" => tls,
          "ca_certificate" => pem
        })

      assert {:ok, _} =
               Store.update_auth_config(ctx.admin, ctx.config.id, %{"public_metadata" => metadata})

      call(ctx, "query", %{"sql" => "SELECT 1"})
    end

    assert {:ok, %{"rows" => [[1]]}} = query.("require", ip, nil)
    assert {:ok, %{"rows" => [[1]]}} = query.("verify", host, ca)

    assert {:error, %{code: "database_unavailable", reason: reason}} =
             query.("verify", host, other_ca)

    assert reason =~ "unknown_ca"

    assert {:error, %{code: "database_unavailable", reason: reason}} =
             query.("verify", ip, ca)

    assert reason =~ "hostname_check_failed"
  end

  def put_limits(changes) do
    limits = Map.merge(Ankole.Plugins.DatabaseConnectors.Config.defaults(), changes)
    assert {:ok, _} = AppConfigure.put_tenant_by_key("connectors.database.limits", limits)
  end

  @doc "Publishes a dataset over `schema.table` and a metric that sums its `amount` column."
  def refund_metric(ctx, schema, table, sql) do
    {:ok, _} = AppConfigure.put_tenant_by_key("brain.enabled", true)
    datasets = Ankole.BrainFixtures.category_fixture(ctx.admin.uid, "datasets")
    metrics = Ankole.BrainFixtures.category_fixture(ctx.admin.uid, "metrics")

    {:ok, dataset} =
      knowledge(ctx, datasets, "Refunds", %{
        "grain" => "one row per refund",
        "source" => %{
          "kind" => "connector",
          "connection" => "warehouse",
          "schema" => schema,
          "table" => table
        },
        "primary_key" => ["id"]
      })

    {:ok, metric} =
      knowledge(ctx, metrics, "Refund total", %{
        "dataset" => dataset.id,
        "grain" => "refund",
        "unit" => "CNY",
        "numerator" => "Refund amounts",
        "sql" => sql,
        "columns" => ["amount"]
      })

    metric
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
end

# MariaDB runs the same cases; it reports session status in information_schema.
for {server, env, ca_env, status_table} <- [
      {"MySQL", "ANKOLE_TEST_MYSQL_URL", "ANKOLE_TEST_MYSQL_CA_FILE",
       "performance_schema.session_status"},
      {"MariaDB", "ANKOLE_TEST_MARIADB_URL", "ANKOLE_TEST_MARIADB_CA_FILE",
       "information_schema.SESSION_STATUS"}
    ] do
  defmodule Module.concat(Ankole.Connectors, "DatabaseConnectors#{server}Test") do
    @moduledoc """
    Exercises the MySQL database connector against a real #{server} server named
    by `#{env}` (`mysql://root:password@localhost:3307`). The suite creates a
    throwaway database and account and drops them afterwards. The verify TLS
    test also needs `#{ca_env}`, the PEM file of the certificate authority that
    signed a server certificate for the URL's host name.
    """
    use Ankole.DataCase, async: false
    import Ankole.Connectors.ExternalDatabaseHelpers
    alias Ankole.Connectors.{Databases, Store}

    @moduletag skip: is_nil(System.get_env(env))
    @env env
    @ca_env ca_env
    @status_table status_table

    setup_all do
      admin = admin_options(System.fetch_env!(@env))
      suffix = System.unique_integer([:positive])
      database = "ankole_dbconn_#{suffix}"
      user = "ankole_dbconn_#{suffix}"
      password = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      with_admin(admin, fn conn ->
        for statement <- [
              "CREATE DATABASE #{database}",
              "CREATE USER '#{user}'@'%' IDENTIFIED BY '#{password}'",
              "GRANT ALL ON #{database}.* TO '#{user}'@'%'",
              "USE #{database}",
              """
              CREATE TABLE customers (id INT PRIMARY KEY, name VARCHAR(100) NOT NULL,
                city VARCHAR(50) COMMENT 'Billing city', email VARCHAR(100),
                UNIQUE KEY customer_name (name), UNIQUE KEY city_email (city, email))
                COMMENT 'Customer master records'
              """,
              """
              CREATE TABLE orders (id INT PRIMARY KEY, customer_id INT, amount DECIMAL(12, 2) NOT NULL,
                big BIGINT UNSIGNED, status VARCHAR(10), created_at DATE,
                FOREIGN KEY (customer_id) REFERENCES customers (id))
              """,
              """
              CREATE FUNCTION touch_order() RETURNS INT DETERMINISTIC MODIFIES SQL DATA
              BEGIN UPDATE orders SET status = status WHERE id = 1; RETURN 1; END
              """,
              """
              INSERT INTO customers
              WITH RECURSIVE g (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM g WHERE n < 30)
              SELECT n, CONCAT('Customer ', n),
                     CASE n % 3 WHEN 0 THEN 'Beijing' WHEN 1 THEN 'Shanghai' ELSE ' Shenzhen ' END,
                     CONCAT('c', n, '@example.com')
              FROM g
              """,
              """
              INSERT INTO orders
              WITH RECURSIVE g (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM g WHERE n < 100)
              SELECT n, (n % 30) + 1, n * 1.25, 18446744073709551615 - n,
                     IF(n % 2 = 0, 'paid', 'open'), DATE '2026-01-01' + INTERVAL n DAY
              FROM g
              """,
              "ANALYZE TABLE customers, orders"
            ],
            do: MyXQL.query!(conn, statement, [], query_type: :text)
      end)

      on_exit(fn ->
        with_admin(admin, fn conn ->
          MyXQL.query!(conn, "DROP DATABASE IF EXISTS #{database}", [], query_type: :text)
          MyXQL.query!(conn, "DROP USER IF EXISTS '#{user}'@'%'", [], query_type: :text)
        end)
      end)

      %{
        admin_options: admin,
        external: %{
          "host" => admin[:hostname],
          "port" => admin[:port],
          "database" => database,
          "username" => user,
          "password" => password
        }
      }
    end

    setup %{external: external} do
      connection(
        "mysql",
        Map.take(external, ["host", "port", "database"]),
        Map.take(external, ["username", "password"])
      )
    end

    test "catalog refresh caches comments, keys, and masked profiles", ctx do
      assert {:ok, %{"table_count" => 2, "complete" => true}} =
               Databases.refresh(ctx.admin, ctx.config.id)

      assert {:ok, customers} = call(ctx, "describe_table", %{"table" => "customers"})
      assert customers["comment"] == "Customer master records"
      assert customers["primary_key"] == ["id"]

      assert %{"comment" => "Billing city", "sensitive" => false, "profile" => city} =
               column(customers, "city")

      assert "Beijing" in city["sample_values"]
      assert city["low_cardinality"]
      refute column(customers, "city")["unique"]
      assert %{"sensitive" => true, "profile" => nil} = column(customers, "email")
      assert column(customers, "id")["primary_key"] and column(customers, "id")["unique"]
      assert column(customers, "name")["unique"]

      assert {:ok, orders} = call(ctx, "describe_table", %{"table" => "orders"})

      assert column(orders, "customer_id")["foreign_key"] == %{
               "schema" => ctx.external["database"],
               "table" => "customers",
               "column" => "id"
             }

      assert %{"sensitive" => true, "profile" => nil} = column(orders, "status")
      assert column(orders, "amount")["profile"]["min"] == "1.25"
      assert column(orders, "big")["type"] in ["bigint unsigned", "bigint(20) unsigned"]
    end

    test "query keeps exact numbers and marks row and byte truncation", ctx do
      assert {:ok, result} =
               call(ctx, "query", %{
                 "sql" => "SELECT id, amount, big FROM orders ORDER BY id",
                 "max_rows" => 5
               })

      assert %{
               "columns" => [
                 %{"name" => "id", "type" => "integer"},
                 %{"name" => "amount", "type" => "decimal"},
                 %{"name" => "big", "type" => "integer"}
               ],
               "rows" => [[1, "1.25", "18446744073709551614"], [2, "2.50", _] | _],
               "row_count" => 5,
               "truncated" => true
             } = result

      assert {:ok, %{"rows" => [["12345678901234567890.123456789"]], "truncated" => false}} =
               call(ctx, "query", %{
                 "sql" => "SELECT CAST('12345678901234567890.123456789' AS DECIMAL(38, 9))"
               })

      assert {:ok, %{"rows" => [[50]], "truncated" => false}} =
               Ankole.Connectors.run_read_query(
                 ctx.actor,
                 "warehouse",
                 "SELECT COUNT(*) FROM orders WHERE status = ?",
                 ["paid"]
               )

      put_limits(%{"max_result_bytes" => 300})

      assert {:ok, %{"rows" => rows, "truncated" => true}} =
               call(ctx, "query", %{"sql" => "SELECT id, status FROM orders ORDER BY id"})

      assert length(rows) in 1..49
      assert :erlang.external_size(rows) <= 300
    end

    test "writes, batches, locking reads, and side effects are rejected", ctx do
      for {sql, code} <- [
            {"DELETE FROM orders", "not_read_only"},
            {"SELECT 1; SELECT 2", "multiple_statements"},
            {"SELECT * FROM orders FOR UPDATE", "locking_clause"},
            {"SELECT * FROM orders LOCK IN SHARE MODE", "locking_clause"},
            {"SELECT SLEEP(5)", "side_effect_function"},
            {"SELECT GET_LOCK('ankole', 1)", "side_effect_function"},
            # sql_inspect cannot see inside a stored function; the read-only session stops it.
            {"SELECT touch_order()", "not_read_only"}
          ] do
        assert {:error, %{code: ^code}} = call(ctx, "query", %{"sql" => sql}), sql
      end
    end

    test "the operator's statement timeout cancels long statements", ctx do
      put_limits(%{"statement_timeout_ms" => 300})

      # The server's own message shows that max_execution_time (MariaDB:
      # max_statement_time) stopped the statement before Ankole's session budget.
      assert {:error, %{code: "statement_timeout", message: message}} =
               call(ctx, "query", %{
                 "sql" =>
                   "SELECT COUNT(*) FROM orders a, orders b, orders c, orders d " <>
                     "WHERE a.amount + b.amount + c.amount + d.amount = 1"
               })

      assert message =~ "Query execution was interrupted"
    end

    test "probes report case-insensitive matches and keep sensitive columns to counts", ctx do
      assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)

      assert {:ok, %{"results" => [city, email, id]}} =
               call(ctx, "probe_values", %{
                 "table" => "customers",
                 "probes" => [
                   %{"column" => "city", "kind" => "match", "value" => "shenzhen"},
                   %{"column" => "email", "kind" => "distinct"},
                   %{"column" => "id", "kind" => "range"}
                 ]
               })

      assert %{"exact_count" => 0, "values" => [%{"value" => " Shenzhen ", "count" => 10}]} = city
      assert %{"masked" => true, "exact_count" => 30} = email
      refute Map.has_key?(email, "values")
      assert %{"min" => 1, "max" => 30, "row_count" => 30, "non_null_count" => 30} = id
    end

    test "export streams every row to a Pod CSV file", ctx do
      {result, csv} = export(ctx, "SELECT id, amount, big FROM orders ORDER BY id", 2)

      assert %{"rows" => [[1, "1.25", _], [2, "2.50", _]], "truncated" => true} = result
      assert %{"row_count" => 100, "truncated" => false} = result["file"]
      assert String.starts_with?(csv, "id,amount,big\r\n1,1.25,18446744073709551614\r\n")
      assert length(String.split(csv, "\r\n", trim: true)) == 101
    end

    test "a failed export reports the server's error and saves no file", ctx do
      assert %{code: "query_failed", message: message} =
               failed_export(
                 ctx,
                 "SELECT a.id, IF(a.id = 90, (SELECT id FROM customers), 0) FROM orders a, orders b"
               )

      assert message =~ "more than 1 row"

      put_limits(%{"statement_timeout_ms" => 300})

      assert %{code: "statement_timeout", message: message} =
               failed_export(
                 ctx,
                 "SELECT a.id FROM orders a, orders b, orders c, orders d " <>
                   "WHERE a.amount + b.amount + c.amount + d.amount = 1"
               )

      assert message =~ "Query execution was interrupted"
    end

    test "the require TLS mode encrypts the session", ctx do
      metadata = Map.put(ctx.config.public_metadata, "tls_mode", "require")

      assert {:ok, _} =
               Store.update_auth_config(ctx.admin, ctx.config.id, %{"public_metadata" => metadata})

      assert {:ok, %{"rows" => [[cipher]]}} =
               call(ctx, "query", %{
                 "sql" =>
                   "SELECT VARIABLE_VALUE FROM #{@status_table} WHERE VARIABLE_NAME = 'Ssl_cipher'"
               })

      assert cipher != ""
    end

    @tag skip: is_nil(System.get_env(ca_env))
    test "the verify TLS mode checks the CA and the host name", ctx do
      assert_tls_modes(
        ctx,
        ctx.external["host"],
        ctx.external["port"],
        System.fetch_env!(@ca_env)
      )
    end

    test "explain returns the JSON plan", ctx do
      assert {:ok, %{"plan" => %{"query_block" => _}}} =
               call(ctx, "explain", %{"sql" => "SELECT * FROM orders WHERE id = 1"})
    end

    test "a metric runs through the connection and a dropped column sends it to review", ctx do
      on_exit(fn -> external(ctx, "DROP TABLE IF EXISTS refunds") end)
      external(ctx, "CREATE TABLE refunds (id INT PRIMARY KEY, amount DECIMAL(12, 2))")
      external(ctx, "INSERT INTO refunds VALUES (1, 2.50), (2, 4.00)")
      assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)

      metric =
        refund_metric(
          ctx,
          ctx.external["database"],
          "refunds",
          "SELECT SUM(amount) AS value FROM refunds"
        )

      assert {:ok, %{"result" => %{"rows" => [["6.50"]]}}} =
               call(ctx, "metric_query", %{"metric_slug" => metric.id, "revision" => 1})

      external(ctx, "ALTER TABLE refunds DROP COLUMN amount")
      assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)

      assert {:error, %{code: "metric_needs_review"}} =
               call(ctx, "metric_query", %{"metric_slug" => metric.id, "revision" => 1})
    end

    defp external(ctx, sql) do
      ctx.admin_options
      |> Keyword.put(:database, ctx.external["database"])
      |> with_admin(&MyXQL.query!(&1, sql, [], query_type: :text))
    end

    defp admin_options(url) do
      uri = URI.parse(url)
      [username, password] = String.split(uri.userinfo, ":", parts: 2)
      [hostname: uri.host, port: uri.port || 3306, username: username, password: password]
    end

    defp with_admin(options, fun) do
      {:ok, conn} = MyXQL.start_link(Keyword.put(options, :pool_size, 1))

      try do
        fun.(conn)
      after
        GenServer.stop(conn)
      end
    end
  end
end

defmodule Ankole.Connectors.DatabaseConnectorsClickHouseTest do
  @moduledoc """
  Exercises the ClickHouse database connector against a real server's HTTP
  interface named by `ANKOLE_TEST_CLICKHOUSE_URL`
  (`http://user:password@127.0.0.1:8124`, a user with access management). The
  suite creates a throwaway database and user and drops them afterwards. The
  TLS test also needs the same server's HTTPS port as
  `ANKOLE_TEST_CLICKHOUSE_HTTPS_URL` (`https://localhost:8444`, a host name
  that the server certificate names) and the PEM file of the certificate
  authority that signed it as `ANKOLE_TEST_CLICKHOUSE_CA_FILE`.
  """
  use Ankole.DataCase, async: false
  import Ankole.Connectors.ExternalDatabaseHelpers
  alias Ankole.Connectors.Databases

  @moduletag skip: is_nil(System.get_env("ANKOLE_TEST_CLICKHOUSE_URL"))

  setup_all do
    suffix = System.unique_integer([:positive])
    database = "ankole_dbconn_#{suffix}"
    user = "ankole_dbconn_#{suffix}"
    password = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    for statement <- [
          "CREATE DATABASE #{database}",
          "CREATE USER #{user} IDENTIFIED BY '#{password}'",
          "GRANT ALL ON #{database}.* TO #{user}",
          """
          CREATE TABLE #{database}.customers (id UInt32, name String,
            city String COMMENT 'Billing city', email String)
          ENGINE = MergeTree ORDER BY id COMMENT 'Customer master records'
          """,
          """
          CREATE TABLE #{database}.orders (id UInt64, customer_id UInt32, amount Decimal(12, 2),
            big UInt64, status String, created_at Date)
          ENGINE = MergeTree ORDER BY (customer_id, id)
          """,
          """
          INSERT INTO #{database}.customers
          SELECT number + 1, concat('Customer ', toString(number + 1)),
                 multiIf((number + 1) % 3 = 0, 'Beijing', (number + 1) % 3 = 1, 'Shanghai', ' Shenzhen '),
                 concat('c', toString(number + 1), '@example.com')
          FROM numbers(30)
          """,
          """
          INSERT INTO #{database}.orders
          SELECT number + 1, ((number + 1) % 30) + 1, toDecimal64((number + 1) * 1.25, 2),
                 18446744073709551615 - (number + 1), if((number + 1) % 2 = 0, 'paid', 'open'),
                 toDate('2026-01-01') + (number + 1)
          FROM numbers(100)
          """
        ],
        do: admin!(statement)

    on_exit(fn ->
      admin!("DROP DATABASE IF EXISTS #{database}")
      admin!("DROP USER IF EXISTS #{user}")
    end)

    uri = URI.parse(url())

    %{
      external: %{
        "host" => uri.host,
        "port" => uri.port,
        "database" => database,
        "username" => user,
        "password" => password
      }
    }
  end

  setup %{external: external} do
    connection(
      "clickhouse",
      Map.take(external, ["host", "port", "database"]),
      Map.take(external, ["username", "password"])
    )
  end

  test "catalog refresh records sorting keys as non-unique sparse order keys", ctx do
    assert {:ok, %{"table_count" => 2, "complete" => true}} =
             Databases.refresh(ctx.admin, ctx.config.id)

    assert {:ok, customers} = call(ctx, "describe_table", %{"table" => "customers"})
    assert customers["comment"] == "Customer master records"
    assert customers["primary_key"] == []
    assert customers["sparse_order_key"] == ["id"]

    assert %{"comment" => "Billing city", "sensitive" => false, "profile" => city} =
             column(customers, "city")

    assert "Beijing" in city["sample_values"]
    assert %{"sensitive" => true, "profile" => nil} = column(customers, "email")

    assert %{"sparse_order_key" => true, "primary_key" => false, "unique" => false} =
             column(customers, "id")

    assert {:ok, orders} = call(ctx, "describe_table", %{"table" => "orders"})
    assert orders["sparse_order_key"] == ["customer_id", "id"]
    assert %{"sensitive" => true, "profile" => nil} = column(orders, "status")
    assert column(orders, "amount")["profile"]["min"] == "1.25"
    assert column(orders, "big")["type"] == "UInt64"
  end

  test "query keeps exact numbers, NULLs, and row and byte truncation", ctx do
    assert {:ok, result} =
             call(ctx, "query", %{
               "sql" => "SELECT id, amount, big FROM orders ORDER BY id",
               "max_rows" => 5
             })

    assert %{
             "columns" => [
               %{"name" => "id", "type" => "UInt64"},
               %{"name" => "amount", "type" => "Decimal(12, 2)"},
               %{"name" => "big", "type" => "UInt64"}
             ],
             "rows" => [["1", "1.25", "18446744073709551614"], ["2", "2.50", _] | _],
             "row_count" => 5,
             "truncated" => true
           } = result

    assert {:ok, %{"rows" => [[nil, [1, nil], "12345678901234567890.123456789", 7]]}} =
             call(ctx, "query", %{
               "sql" =>
                 "SELECT CAST(NULL AS Nullable(String)), [1, NULL], " <>
                   "toDecimal128('12345678901234567890.123456789', 9), toUInt8(7)"
             })

    assert {:ok, %{"rows" => [["50"]], "truncated" => false}} =
             Ankole.Connectors.run_read_query(
               ctx.actor,
               "warehouse",
               "SELECT count() FROM orders WHERE status = {p1:String}",
               ["paid"]
             )

    # One server block of these rows exceeds the response budget, so the
    # server-side limit, not the block boundary, bounds the preview.
    assert {:ok, %{"rows" => wide, "truncated" => true}} =
             call(ctx, "query", %{"sql" => "SELECT repeat('x', 1000) FROM numbers(1000000)"})

    assert length(wide) == 500

    assert {:error, %{code: "result_too_large"}} =
             call(ctx, "query", %{"sql" => "SELECT repeat('x', 30000) FROM numbers(1000)"})

    put_limits(%{"max_result_bytes" => 300})

    assert {:ok, %{"rows" => rows, "truncated" => true}} =
             call(ctx, "query", %{"sql" => "SELECT id, status FROM orders ORDER BY id"})

    assert length(rows) in 1..49
    assert :erlang.external_size(rows) <= 300
  end

  test "writes, batches, side effects, and setting overrides are rejected", ctx do
    for {sql, code} <- [
          {"INSERT INTO orders (id) VALUES (1)", "not_read_only"},
          {"SELECT 1; SELECT 2", "multiple_statements"},
          {"SELECT sleep(1)", "side_effect_function"},
          {"SELECT * FROM url('http://127.0.0.1:1/', CSV, 'a String')", "side_effect_function"},
          {"SELECT * FROM file('/etc/passwd', 'LineAsString')", "side_effect_function"},
          # sql_inspect accepts a SETTINGS clause; readonly=1 stops it from lifting a budget.
          {"SELECT count() FROM orders SETTINGS max_execution_time = 0", "not_read_only"}
        ] do
      assert {:error, %{code: ^code}} = call(ctx, "query", %{"sql" => sql}), sql
    end
  end

  test "the operator's statement timeout cancels long statements", ctx do
    put_limits(%{"statement_timeout_ms" => 1_000})

    assert {:error, %{code: "statement_timeout", message: message}} =
             call(ctx, "query", %{
               "sql" =>
                 "SELECT count() FROM numbers(100000000) AS a CROSS JOIN numbers(100000) AS b " <>
                   "WHERE a.number + b.number = 7"
             })

    assert message =~ "Code: 159"
  end

  test "probes report case-insensitive matches and keep sensitive columns to counts", ctx do
    assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)

    assert {:ok, %{"results" => [city, email, id]}} =
             call(ctx, "probe_values", %{
               "table" => "customers",
               "probes" => [
                 %{"column" => "city", "kind" => "match", "value" => "shenzhen"},
                 %{"column" => "email", "kind" => "distinct"},
                 %{"column" => "id", "kind" => "range"}
               ]
             })

    assert %{"exact_count" => 0, "values" => [%{"value" => " Shenzhen ", "count" => 10}]} = city
    assert %{"masked" => true, "exact_count" => 30} = email
    refute Map.has_key?(email, "values")
    assert %{"min" => 1, "max" => 30, "row_count" => 30, "non_null_count" => 30} = id
  end

  test "export streams every row to a Pod CSV file", ctx do
    {result, csv} = export(ctx, "SELECT id, amount, big FROM orders ORDER BY id", 2)

    assert %{"rows" => [["1", "1.25", _], ["2", "2.50", _]], "truncated" => true} = result
    assert %{"row_count" => 100, "truncated" => false} = result["file"]
    assert String.starts_with?(csv, "id,amount,big\r\n1,1.25,18446744073709551614\r\n")
    assert length(String.split(csv, "\r\n", trim: true)) == 101
  end

  test "a failed export reports the server's error and saves no file", ctx do
    # The first statement fails before the response starts; the second after
    # ClickHouse has sent 200 OK and the column header rows.
    for {sql, text} <- [
          {"SELECT throwIf(number = 5, 'early') FROM numbers(10)", "early"},
          {"SELECT number, throwIf(number = 100000, 'boom') FROM numbers(200000)", "boom"}
        ] do
      assert %{code: "query_failed", message: message} = failed_export(ctx, sql)
      assert message =~ "Code: 395" and message =~ text
    end

    # ClickHouse stops this export at its one-second limit while rows are streaming.
    put_limits(%{"statement_timeout_ms" => 1_000})

    assert %{code: "statement_timeout", message: message} =
             failed_export(ctx, "SELECT number, repeat('x', 1000) FROM numbers(100000000)")

    assert message =~ "Code: 159"
  end

  test "sparse order keys keep whole key expressions and mark the columns they read", ctx do
    database = ctx.external["database"]
    on_exit(fn -> admin!("DROP TABLE IF EXISTS #{database}.events, #{database}.unordered") end)

    admin!("""
    CREATE TABLE #{database}.events (user_id UInt64, ts DateTime, kind String, note String)
    ENGINE = MergeTree PRIMARY KEY (toDate(ts), intHash32(user_id))
    ORDER BY (toDate(ts), intHash32(user_id), toStartOfInterval(ts, toIntervalHour(1)), kind)
    """)

    admin!(
      "CREATE TABLE #{database}.unordered (a UInt8, b String) ENGINE = MergeTree ORDER BY tuple()"
    )

    assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)
    assert {:ok, events} = call(ctx, "describe_table", %{"table" => "events"})

    assert events["sparse_order_key"] == [
             "toDate(ts)",
             "intHash32(user_id)",
             "toStartOfInterval(ts, toIntervalHour(1))",
             "kind"
           ]

    assert for(c <- events["columns"], c["sparse_order_key"], do: c["name"]) ==
             ["user_id", "ts", "kind"]

    assert {:ok, unordered} = call(ctx, "describe_table", %{"table" => "unordered"})
    assert unordered["sparse_order_key"] == []
    refute Enum.any?(unordered["columns"], & &1["sparse_order_key"])
  end

  @tag skip: is_nil(System.get_env("ANKOLE_TEST_CLICKHOUSE_HTTPS_URL"))
  test "TLS modes reach the HTTPS port, and verify checks the CA and the host name", ctx do
    https = URI.parse(System.fetch_env!("ANKOLE_TEST_CLICKHOUSE_HTTPS_URL"))

    assert_tls_modes(
      ctx,
      https.host,
      https.port,
      System.fetch_env!("ANKOLE_TEST_CLICKHOUSE_CA_FILE")
    )
  end

  test "explain returns the plan text", ctx do
    assert {:ok, %{"plan" => plan}} =
             call(ctx, "explain", %{"sql" => "SELECT * FROM orders WHERE id = 1"})

    assert plan =~ "ReadFromMergeTree"
  end

  test "a metric runs through the connection and a dropped column sends it to review", ctx do
    table = ctx.external["database"] <> ".refunds"
    on_exit(fn -> admin!("DROP TABLE IF EXISTS #{table}") end)

    admin!(
      "CREATE TABLE #{table} (id UInt32, amount Decimal(12, 2)) ENGINE = MergeTree ORDER BY id"
    )

    admin!("INSERT INTO #{table} VALUES (1, 2.50), (2, 4.00)")
    assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)

    metric =
      refund_metric(
        ctx,
        ctx.external["database"],
        "refunds",
        "SELECT sum(amount) AS value FROM refunds"
      )

    assert {:ok, %{"result" => %{"rows" => [["6.50"]]}}} =
             call(ctx, "metric_query", %{"metric_slug" => metric.id, "revision" => 1})

    admin!("ALTER TABLE #{table} DROP COLUMN amount")
    assert {:ok, _} = Databases.refresh(ctx.admin, ctx.config.id)

    assert {:error, %{code: "metric_needs_review"}} =
             call(ctx, "metric_query", %{"metric_slug" => metric.id, "revision" => 1})
  end

  defp url, do: System.fetch_env!("ANKOLE_TEST_CLICKHOUSE_URL")

  defp admin!(sql) do
    uri = URI.parse(url())
    endpoint = URI.to_string(%{uri | userinfo: nil, path: "/"})
    response = Req.post!(endpoint, body: sql, auth: {:basic, uri.userinfo}, retry: false)
    assert response.status == 200, response.body
  end
end

defmodule Ankole.Connectors.DatabaseConnectorsPostgreSQLTLSTest do
  @moduledoc """
  Checks the PostgreSQL connector's TLS modes against a TLS-enabled server named
  by `ANKOLE_TEST_POSTGRES_TLS_URL`
  (`postgres://postgres:password@localhost:5434/postgres`, a host name that the
  server certificate lists), with the PEM file of the certificate authority
  that signed the certificate as `ANKOLE_TEST_POSTGRES_CA_FILE`. The connection
  signs in with the URL's account and runs only `SELECT 1`; the main PostgreSQL
  suite in `database_connectors_test.exs` covers the rest of the connector.
  """
  use Ankole.DataCase, async: false
  import Ankole.Connectors.ExternalDatabaseHelpers

  @moduletag skip: is_nil(System.get_env("ANKOLE_TEST_POSTGRES_TLS_URL"))

  test "the verify TLS mode checks the CA and the host name" do
    uri = URI.parse(System.fetch_env!("ANKOLE_TEST_POSTGRES_TLS_URL"))
    [username, password] = String.split(uri.userinfo, ":", parts: 2)

    ctx =
      connection(
        "postgresql",
        %{
          "host" => uri.host,
          "port" => uri.port,
          "database" => String.trim_leading(uri.path, "/")
        },
        %{"username" => username, "password" => password}
      )

    assert_tls_modes(ctx, uri.host, uri.port, System.fetch_env!("ANKOLE_TEST_POSTGRES_CA_FILE"))
  end
end
