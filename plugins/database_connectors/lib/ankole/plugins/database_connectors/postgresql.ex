defmodule Ankole.Plugins.DatabaseConnectors.PostgreSQL do
  @moduledoc """
  PostgreSQL connections through short-lived Postgrex sessions.

  The session sets `default_transaction_read_only`, and every statement runs
  in its own `READ ONLY` transaction with `SET LOCAL statement_timeout` and
  `lock_timeout`.
  """
  @behaviour Ankole.Connectors.Connector

  # Postgrex statements run on the tenant's external database, which holds no
  # Ankole tenant rows; the connection's credentials scope what they read.
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :site

  alias Ankole.Plugins.DatabaseConnectors.{Adapter, Network, Tools, Values}

  @tools Tools.tools("postgresql")
  @uuid_oid 2950
  @chunk_rows 500
  @schemas_excluded "n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_toast%' AND n.nspname NOT LIKE 'pg\\_temp%'"
  @relation_filter "c.relkind IN ('r', 'v', 'm', 'p', 'f') AND NOT c.relispartition AND has_table_privilege(c.oid, 'SELECT')"

  @impl true
  def tools, do: @tools
  @impl true
  def call(tool, args, context), do: Adapter.call(__MODULE__, tool, args, context)
  @impl true
  def read_query(context, sql, params, opts),
    do: Adapter.read_query(__MODULE__, context, sql, params, opts)

  @impl true
  def fetch_catalog(config, secret, opts),
    do: Adapter.fetch_catalog(__MODULE__, config, secret, opts)

  @impl true
  def mark_catalog(config, tables), do: Adapter.mark_catalog(config, tables)

  # Several tenants and connections may read the same database with different roles.
  @impl true
  def platform_application(_config), do: {:ok, nil}

  def dialect, do: :postgres
  def default_port, do: 5432
  def quote(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")
  def placeholder(index), do: "$#{index}"
  def text_type, do: "text"
  def normalized_text(column), do: "lower(trim(CAST(#{column} AS text)))"
  def explain_sql(sql), do: "EXPLAIN (FORMAT JSON) " <> sql
  def plan([[plan] | _]), do: plan
  def plan(rows), do: rows

  def session(%{database: nil}, _limits, _fun),
    do:
      {:error,
       %{code: "invalid_database_connection", message: "Name the database.", retryable: false}}

  def session(endpoint, limits, fun) do
    Process.flag(:trap_exit, true)
    failures = Network.tls_failures()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: endpoint.address,
        port: endpoint.port,
        database: endpoint.database,
        username: endpoint.username,
        password: endpoint.password,
        ssl: Network.ssl_options(endpoint, failures),
        parameters: [default_transaction_read_only: "on", application_name: "ankole"],
        pool_size: 1,
        backoff_type: :stop,
        max_restarts: 0,
        connect_timeout: 10_000,
        queue_target: 10_000,
        show_sensitive_data_on_connection_error: false
      )

    try do
      fun.(fn sql, params, opts, consume -> exec(conn, limits, sql, params, opts, consume) end)
    catch
      :exit, reason -> Network.tls_failure(reason, failures)
    after
      Adapter.stop(conn)
      :ets.delete(failures)
    end
  end

  defp exec(conn, limits, sql, params, opts, consume) do
    Postgrex.transaction(
      conn,
      fn conn ->
        Postgrex.query!(conn, "SET TRANSACTION READ ONLY", [])

        Postgrex.query!(
          conn,
          "SET LOCAL statement_timeout = #{limits["statement_timeout_ms"]}",
          []
        )

        Postgrex.query!(conn, "SET LOCAL lock_timeout = #{limits["lock_timeout_ms"]}", [])
        query = Postgrex.prepare!(conn, "", sql)

        uuids =
          for {oid, index} <- Enum.with_index(query.result_oids || []),
              oid == @uuid_oid,
              do: index

        result =
          conn
          |> Postgrex.stream(query, params,
            max_rows: min(opts[:take] || @chunk_rows, @chunk_rows)
          )
          |> Stream.map(fn chunk ->
            {chunk.columns || query.columns || [], Enum.map(chunk.rows || [], &row(&1, uuids))}
          end)
          |> consume.()

        %{columns: typed_columns(conn, query), result: result}
      end,
      timeout: :infinity
    )
  rescue
    error in Postgrex.Error -> {:error, failure(error)}
    error in DBConnection.ConnectionError -> {:error, unavailable(error.message)}
  end

  defp row(values, []), do: Values.row(values)

  defp row(values, uuids) do
    values
    |> Enum.with_index()
    |> Enum.map(fn
      {<<_::128>> = uuid, index} ->
        if index in uuids, do: Ecto.UUID.load!(uuid), else: Values.value(uuid)

      {value, _index} ->
        Values.value(value)
    end)
  end

  defp typed_columns(_conn, %{columns: nil}), do: []

  defp typed_columns(conn, query) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT oid::bigint, format_type(oid, NULL) FROM pg_type WHERE oid = ANY($1::oid[])",
        [Enum.uniq(query.result_oids)]
      )

    names = Map.new(rows, fn [oid, name] -> {oid, name} end)

    Enum.zip_with(query.columns, query.result_oids, fn name, oid ->
      %{"name" => name, "type" => Map.get(names, oid, "unknown")}
    end)
  end

  defp failure(%Postgrex.Error{postgres: %{code: code, message: message}}) do
    case code do
      :query_canceled -> %{code: "statement_timeout", message: message, retryable: false}
      :lock_not_available -> %{code: "lock_timeout", message: message, retryable: true}
      :read_only_sql_transaction -> %{code: "not_read_only", message: message, retryable: false}
      _ -> %{code: "query_failed", message: message, sqlstate: to_string(code), retryable: false}
    end
  end

  defp failure(%Postgrex.Error{} = error), do: unavailable(Exception.message(error))

  defp unavailable(message),
    do: %{code: "database_unavailable", message: message, retryable: true}

  ## Catalog

  def catalog(exec, max_tables) do
    with {:ok, %{result: tables}} <-
           exec.(
             """
             SELECT n.nspname, c.relname, c.relkind::text, obj_description(c.oid, 'pg_class'),
                    CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE #{@schemas_excluded} AND #{@relation_filter}
             ORDER BY 1, 2 LIMIT $1
             """,
             [max_tables],
             [take: max_tables],
             &rows/1
           ),
         {:ok, %{result: columns}} <-
           exec.(
             """
             SELECT n.nspname, c.relname, a.attname, a.attnum::int, format_type(a.atttypid, a.atttypmod),
                    NOT a.attnotnull, col_description(c.oid, a.attnum)
             FROM pg_attribute a
             JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE a.attnum > 0 AND NOT a.attisdropped AND #{@schemas_excluded} AND #{@relation_filter}
             ORDER BY 1, 2, 4
             """,
             [],
             [take: 1_000_000],
             &rows/1
           ),
         {:ok, %{result: constraints}} <-
           exec.(
             """
             SELECT n.nspname, c.relname, con.contype::text,
                    ARRAY(SELECT a.attname::text FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
                          JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum ORDER BY k.ord),
                    fn.nspname, fc.relname,
                    ARRAY(SELECT a.attname::text FROM unnest(con.confkey) WITH ORDINALITY k(attnum, ord)
                          JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum ORDER BY k.ord)
             FROM pg_constraint con
             JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             LEFT JOIN pg_class fc ON fc.oid = con.confrelid
             LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
             WHERE con.contype IN ('p', 'u', 'f') AND #{@schemas_excluded}
             """,
             [],
             [take: 1_000_000],
             &rows/1
           ) do
      {:ok, assemble(tables, columns, constraints)}
    end
  end

  defp rows(chunks), do: Enum.flat_map(chunks, fn {_names, rows} -> rows end)

  defp assemble(tables, columns, constraints) do
    columns = Enum.group_by(columns, fn [schema, table | _] -> {schema, table} end)
    constraints = Enum.group_by(constraints, fn [schema, table | _] -> {schema, table} end)

    Enum.map(tables, fn [schema, name, kind, comment, estimate] ->
      keys = Map.get(constraints, {schema, name}, [])
      primary = for([_, _, "p", columns | _] <- keys, do: columns) |> List.first([])

      unique =
        for [_, _, "u", [column] | _] <- keys, do: column

      foreign =
        for [_, _, "f", [column], ref_schema, ref_table, [ref_column]] <- keys,
            into: %{},
            do: {column, %{"schema" => ref_schema, "table" => ref_table, "column" => ref_column}}

      %{
        "schema" => schema,
        "name" => name,
        "kind" => kind_name(kind),
        "comment" => comment,
        "row_estimate" => estimate,
        "primary_key" => primary,
        "sparse_order_key" => [],
        "columns" =>
          for [_, _, column, ordinal, type, nullable, column_comment] <-
                Map.get(columns, {schema, name}, []) do
            %{
              "name" => column,
              "ordinal" => ordinal,
              "type" => type,
              "nullable" => nullable,
              "comment" => column_comment,
              "primary_key" => column in primary,
              "unique" => column in unique or primary == [column],
              "foreign_key" => foreign[column]
            }
          end
      }
    end)
  end

  defp kind_name("v"), do: "view"
  defp kind_name("m"), do: "materialized_view"
  defp kind_name("f"), do: "foreign_table"
  defp kind_name(_), do: "table"

  @doc "Sums pg_stat_statements calls per table when the extension is readable."
  def query_counts(exec) do
    case exec.(
           "SELECT query, calls FROM pg_stat_statements ORDER BY calls DESC LIMIT 500",
           [],
           [take: 500],
           &rows/1
         ) do
      {:ok, %{result: statements}} -> Adapter.table_counts(statements, :postgres, "public")
      _ -> %{}
    end
  end
end
