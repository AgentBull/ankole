defmodule Ankole.Plugins.DatabaseConnectors.MySQL do
  @moduledoc """
  MySQL connections through short-lived MyXQL sessions.

  Each connection sets `SET SESSION TRANSACTION READ ONLY` and
  `max_execution_time` (MariaDB: `max_statement_time`) before any statement,
  and every statement except the one-row `EXPLAIN` plan streams through a
  server-side cursor in a transaction.
  MyXQL does not report result column types, so the envelope names each
  column's type from its first non-null value.
  """
  @behaviour Ankole.Connectors.Connector
  alias Ankole.Plugins.DatabaseConnectors.{Adapter, Network, Tools, Values}

  @tools Tools.tools("mysql")
  @chunk_rows 500
  @system_schemas "('mysql', 'information_schema', 'performance_schema', 'sys')"
  @schema_filter "(DATABASE() IS NULL OR TABLE_SCHEMA = DATABASE()) AND TABLE_SCHEMA NOT IN #{@system_schemas}"

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

  # Several tenants and connections may read the same database with different accounts.
  @impl true
  def platform_application(_config), do: {:ok, nil}

  def dialect, do: :mysql
  def default_port, do: 3306
  def quote(name), do: "`" <> String.replace(name, "`", "``") <> "`"
  def placeholder(_index), do: "?"
  def text_type, do: "CHAR"
  def normalized_text(column), do: "LOWER(TRIM(CAST(#{column} AS CHAR)))"
  @explain "EXPLAIN FORMAT=JSON "
  def explain_sql(sql), do: @explain <> sql

  def plan([[plan] | _]) when is_binary(plan) do
    case Torque.decode(plan) do
      {:ok, decoded} -> decoded
      _ -> plan
    end
  end

  def plan(rows), do: rows

  def session(endpoint, limits, fun) do
    Process.flag(:trap_exit, true)
    failures = Network.tls_failures()

    {:ok, conn} =
      MyXQL.start_link(
        protocol: :tcp,
        hostname: endpoint.address,
        port: endpoint.port,
        database: endpoint.database,
        username: endpoint.username,
        password: endpoint.password,
        ssl: Network.ssl_options(endpoint, failures),
        pool_size: 1,
        backoff_type: :stop,
        max_restarts: 0,
        connect_timeout: 10_000,
        queue_target: 10_000,
        prepare: :unnamed,
        after_connect: &read_only_session(&1, limits["statement_timeout_ms"])
      )

    try do
      fun.(fn sql, params, opts, consume -> exec(conn, sql, params, opts, consume) end)
    catch
      :exit, reason -> Network.tls_failure(reason, failures)
    after
      Adapter.stop(conn)
      :ets.delete(failures)
    end
  end

  defp read_only_session(conn, timeout_ms) do
    MyXQL.query!(conn, "SET SESSION TRANSACTION READ ONLY")

    case MyXQL.query(conn, "SET SESSION max_execution_time = #{timeout_ms}") do
      {:ok, _} -> :ok
      {:error, _} -> MyXQL.query!(conn, "SET SESSION max_statement_time = #{timeout_ms / 1000}")
    end
  end

  defp exec(conn, sql, params, opts, consume) do
    key = {__MODULE__, make_ref()}

    MyXQL.transaction(
      conn,
      fn conn ->
        Process.put(key, {[], %{}})

        # MySQL 8.4 crashes when EXPLAIN FORMAT=JSON runs through a cursor; a plan is one row.
        chunks =
          if String.starts_with?(sql, @explain),
            do: [MyXQL.query!(conn, sql, params)],
            else:
              MyXQL.stream(conn, sql, params,
                max_rows: min(opts[:take] || @chunk_rows, @chunk_rows)
              )

        result =
          chunks
          |> Stream.map(fn chunk ->
            {names, kinds} = Process.get(key)
            names = chunk.columns || names
            rows = chunk.rows || []
            Process.put(key, {names, Enum.reduce(rows, kinds, &observe_kinds/2)})
            {names, Enum.map(rows, &Values.row/1)}
          end)
          |> consume.()

        {names, kinds} = Process.delete(key)

        %{
          columns:
            names
            |> Enum.with_index()
            |> Enum.map(fn {name, index} ->
              %{"name" => name, "type" => kinds[index] || "unknown"}
            end),
          result: result
        }
      end,
      timeout: :infinity
    )
  rescue
    error in MyXQL.Error -> {:error, failure(error)}
    error in DBConnection.ConnectionError -> {:error, unavailable(error.message)}
  end

  defp observe_kinds(row, kinds) do
    row
    |> Enum.with_index()
    |> Enum.reduce(kinds, fn
      {nil, _index}, kinds -> kinds
      {value, index}, kinds -> Map.put_new(kinds, index, Values.kind(value))
    end)
  end

  # MyXQL names only some server errors, so the match uses the numeric codes:
  # 3024 ER_QUERY_TIMEOUT, 1969 MariaDB ER_STATEMENT_TIMEOUT,
  # 1792 ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION, and 1205 ER_LOCK_WAIT_TIMEOUT.
  defp failure(%MyXQL.Error{mysql: %{code: code}, message: message}) do
    case code do
      code when code in [3024, 1969] ->
        %{code: "statement_timeout", message: message, retryable: false}

      1792 ->
        %{code: "not_read_only", message: message, retryable: false}

      1205 ->
        %{code: "lock_timeout", message: message, retryable: true}

      _ ->
        %{code: "query_failed", message: message, retryable: false}
    end
  end

  defp failure(%MyXQL.Error{message: message}), do: unavailable(message)

  defp unavailable(message),
    do: %{code: "database_unavailable", message: message, retryable: true}

  ## Catalog

  def catalog(exec, max_tables) do
    with {:ok, %{result: tables}} <-
           exec.(
             """
             SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, TABLE_COMMENT, TABLE_ROWS
             FROM information_schema.TABLES WHERE #{@schema_filter}
             ORDER BY TABLE_SCHEMA, TABLE_NAME LIMIT ?
             """,
             [max_tables],
             [take: max_tables],
             &rows/1
           ) do
      catalog_details(exec, tables)
    end
  end

  defp catalog_details(_exec, []), do: {:ok, []}

  defp catalog_details(exec, tables) do
    placeholders = Enum.map_join(tables, ", ", fn _ -> "(?, ?)" end)
    params = Enum.flat_map(tables, fn [schema, name | _] -> [schema, name] end)

    with {:ok, %{result: columns}} <-
           exec.(
             """
             SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, COLUMN_TYPE,
                    IS_NULLABLE = 'YES', COLUMN_COMMENT, COLUMN_KEY
             FROM information_schema.COLUMNS
             WHERE #{@schema_filter} AND (TABLE_SCHEMA, TABLE_NAME) IN (#{placeholders})
             ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
             """,
             params,
             [take: 1_000_000],
             &rows/1
           ),
         {:ok, %{result: keys}} <-
           exec.(
             """
             SELECT TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, COLUMN_NAME,
                    REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
             FROM information_schema.KEY_COLUMN_USAGE
             WHERE #{@schema_filter} AND (TABLE_SCHEMA, TABLE_NAME) IN (#{placeholders})
             ORDER BY TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
             """,
             params,
             [take: 1_000_000],
             &rows/1
           ) do
      {:ok, assemble(tables, columns, keys)}
    end
  end

  defp rows(chunks), do: Enum.flat_map(chunks, fn {_names, rows} -> rows end)

  defp assemble(tables, columns, keys) do
    columns = Enum.group_by(columns, fn [schema, table | _] -> {schema, table} end)
    keys = Enum.group_by(keys, fn [schema, table | _] -> {schema, table} end)

    Enum.map(tables, fn [schema, name, type, comment, estimate] ->
      table_keys = Map.get(keys, {schema, name}, [])
      primary = for [_, _, "PRIMARY", column | _] <- table_keys, do: column

      foreign =
        for [_, _, _, column, ref_schema, ref_table, ref_column] <- table_keys,
            not is_nil(ref_table),
            into: %{},
            do: {column, %{"schema" => ref_schema, "table" => ref_table, "column" => ref_column}}

      %{
        "schema" => schema,
        "name" => name,
        "kind" => if(type == "VIEW", do: "view", else: "table"),
        "comment" => blank(if(type == "VIEW", do: nil, else: comment)),
        "row_estimate" => estimate,
        "primary_key" => primary,
        "sparse_order_key" => [],
        "columns" =>
          for [_, _, column, ordinal, column_type, nullable, column_comment, key] <-
                Map.get(columns, {schema, name}, []) do
            %{
              "name" => column,
              "ordinal" => ordinal,
              "type" => column_type,
              "nullable" => nullable in [1, true],
              "comment" => blank(column_comment),
              "primary_key" => column in primary,
              "unique" => key == "UNI" or primary == [column],
              "foreign_key" => foreign[column]
            }
          end
      }
    end)
  end

  defp blank(""), do: nil
  defp blank(value), do: value

  @doc "Sums performance_schema statement digests per table when they are readable."
  def query_counts(exec) do
    with {:ok, %{result: [[database]]}} <- exec.("SELECT DATABASE()", [], [take: 1], &rows/1),
         {:ok, %{result: digests}} <-
           exec.(
             """
             SELECT DIGEST_TEXT, COUNT_STAR
             FROM performance_schema.events_statements_summary_by_digest
             WHERE DIGEST_TEXT IS NOT NULL AND (DATABASE() IS NULL OR SCHEMA_NAME = DATABASE())
             ORDER BY COUNT_STAR DESC LIMIT 500
             """,
             [],
             [take: 500],
             &rows/1
           ) do
      Adapter.table_counts(digests, :mysql, database)
    else
      _ -> %{}
    end
  end
end
