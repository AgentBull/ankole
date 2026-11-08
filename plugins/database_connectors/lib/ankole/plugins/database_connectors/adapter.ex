defmodule Ankole.Plugins.DatabaseConnectors.Adapter do
  @moduledoc """
  Tool execution shared by the PostgreSQL, MySQL, and ClickHouse adapters.

  Every statement that a caller supplies passes `Ankole.Kernel.sql_inspect/2`
  first, then runs in the engine's read-only session under the operator's
  `connectors.database.limits`. Ankole fetches at most `max_rows + 1` rows
  through a cursor or a server-side result limit instead of rewriting the
  statement, so the statement's own `ORDER BY` and `LIMIT` keep their meaning
  and the extra row only reports truncation.

  An engine module implements `dialect/0`, `default_port/0`, `quote/1`,
  `placeholder/1`, `normalized_text/1`, `explain_sql/1`, `plan/1`,
  `session/3`, `catalog/2`, and `query_counts/1`. `session/3` opens one
  connection and passes an `exec` function: `exec.(sql, params, opts, fun)`
  runs one statement, calls `fun` with a stream of `{column_names, rows}`
  chunks, and returns `{:ok, %{columns: [%{"name", "type"}], result: term}}`.
  """
  require Logger
  alias Ankole.Plugins.DatabaseConnectors.{Config, Network, Profile, Values}

  @tasks Ankole.Plugins.DatabaseConnectors.Tasks
  @connect_ms 10_000
  @probe_values 20

  ## Tools

  @doc "Runs one tool call; atom reasons become structured tool errors."
  def call(engine, tool, args, context) do
    case dispatch(engine, tool, args, context) do
      {:error, reason} when is_atom(reason) ->
        {:error, %{code: Atom.to_string(reason), retryable: false, request_sent: false}}

      result ->
        result
    end
  end

  defp dispatch(_engine, %{name: "search_catalog"}, args, context),
    do:
      Ankole.Connectors.search_database_catalog(
        context.auth_config,
        args["query"],
        args["limit"] || 20
      )

  defp dispatch(_engine, %{name: "describe_table"}, args, context),
    do: describe(context.auth_config, args["schema"], args["table"])

  defp dispatch(engine, %{name: "probe_values"}, args, context), do: probe(engine, context, args)

  defp dispatch(engine, %{name: "explain"}, args, context),
    do: explain(engine, context, args["sql"], args["params"] || [])

  # Saving an export writes a Pod file, so it needs a route that permits writes.
  defp dispatch(_engine, %{name: "query"}, %{"export" => _}, %{read_only: true}),
    do: {:error, :read_only_route}

  defp dispatch(engine, %{name: "query"}, args, context),
    do:
      read_query(engine, context, args["sql"], args["params"] || [],
        max_rows: args["max_rows"],
        export: args["export"]
      )

  defp dispatch(_engine, %{name: "metric_query"}, args, context) do
    case Ankole.Brain.execute_metric(
           context.actor,
           args["metric_slug"],
           args["revision"],
           args["params"] || %{}
         ) do
      {:ok, result} ->
        {:ok, Values.value(result)}

      {:error, {code, details}} when is_atom(code) and is_map(details) ->
        {:error, Map.merge(%{code: Atom.to_string(code), retryable: false}, details)}

      error ->
        error
    end
  end

  ## Read queries

  def read_query(engine, context, sql, params, opts) do
    limits = Config.limits()
    max_rows = min(opts[:max_rows] || limits["max_rows"], limits["max_rows"])

    with {:ok, facts} <- inspect_sql(engine, sql),
         {:ok, endpoint} <- endpoint(engine, context.auth_config) do
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      started = System.monotonic_time(:millisecond)

      result =
        case opts[:export] do
          nil ->
            preview(engine, endpoint, context, sql, params, limits, max_rows)

          destination ->
            export(engine, endpoint, context, sql, params, limits, max_rows, destination)
        end

      with {:ok, %{columns: columns, result: {rows, truncated, file}}} <- result do
        {:ok,
         %{
           "columns" => columns,
           "rows" => rows,
           "row_count" => length(rows),
           "truncated" => truncated,
           "elapsed_ms" => System.monotonic_time(:millisecond) - started,
           "sql" => sql,
           "data_timestamp" => timestamp,
           "warnings" => if(facts["fanout_risk"] == true, do: ["fanout_risk"], else: []),
           "file" => file
         }}
      end
    end
  end

  defp preview(engine, endpoint, context, sql, params, limits, max_rows) do
    session(engine, endpoint, limits, timeout(context, limits), fn exec ->
      exec.(sql, params, [take: max_rows + 1], fn chunks ->
        {rows, truncated} = take_rows(chunks, max_rows, limits["max_result_bytes"])
        {rows, truncated, nil}
      end)
    end)
  end

  @doc """
  The byte-bounded consumer behind every result that Ankole keeps. It reads
  `{column_names, rows}` chunks and returns `{rows, truncated}`; rows past
  `max_rows`, or past `max_bytes` in total, mark the result truncated.
  """
  def take_rows(chunks, max_rows, max_bytes) do
    chunks
    |> Stream.flat_map(fn {_names, rows} -> rows end)
    |> Enum.reduce_while({{[], 0, 0}, false}, fn row, {kept, false} ->
      case keep_row(kept, row, max_rows, max_bytes) do
        :full -> {:halt, {kept, true}}
        kept -> {:cont, {kept, false}}
      end
    end)
    |> then(fn {{rows, _count, _bytes}, truncated} -> {Enum.reverse(rows), truncated} end)
  end

  defp keep_row({rows, count, bytes}, row, max_rows, max_bytes) do
    bytes = bytes + :erlang.external_size(row)
    if count >= max_rows or bytes > max_bytes, do: :full, else: {[row | rows], count + 1, bytes}
  end

  defp export(
         engine,
         endpoint,
         %{actor: %Ankole.AuthZ.Actor{} = actor} = context,
         sql,
         params,
         limits,
         max_rows,
         destination
       ) do
    max_export = limits["max_export_rows"]
    # An export fetches many rows; each fetch keeps the statement budget and the session gets ten.
    timeout =
      timeout(context, %{limits | "statement_timeout_ms" => limits["statement_timeout_ms"] * 10})

    session(engine, endpoint, limits, timeout, fn exec ->
      exec.(sql, params, [take: max_export + 1, stream: true], fn chunks ->
        # Pod.Files.upload consumes the stream in this process, so the
        # preview and row count travel in the process dictionary.
        key = {__MODULE__, make_ref()}
        Process.put(key, {{[], 0, 0}, 0, false})

        body =
          chunks
          |> Stream.transform(:start, fn
            {names, rows}, :start -> {[{:header, names} | Enum.map(rows, &{:row, &1})], :rows}
            {_names, rows}, :rows -> {Enum.map(rows, &{:row, &1}), :rows}
          end)
          |> Stream.transform(0, fn
            {:header, names}, count ->
              {[Values.csv_line(names)], count}

            {:row, _row}, count when count >= max_export ->
              {preview, ^count, _} = Process.get(key)
              Process.put(key, {preview, count, true})
              {:halt, count}

            {:row, row}, count ->
              {preview, ^count, truncated} = Process.get(key)
              preview = preview_row(preview, row, max_rows, limits["max_result_bytes"])
              Process.put(key, {preview, count + 1, truncated})
              {[Values.csv_line(row)], count + 1}
          end)

        upload =
          Ankole.Pod.Files.upload(
            actor,
            destination["page_id"],
            destination["role"],
            destination["base_object_id"],
            destination["name"],
            body,
            "text/csv",
            actor.turn_authority
          )

        {{preview, _kept, _bytes}, count, truncated} = Process.delete(key)

        case upload do
          {:ok, %{page_id: page_id, file: file}} ->
            {Enum.reverse(preview), count > length(preview),
             %{
               "file_ref" => "pages/" <> page_id <> "/" <> file.path,
               "size" => file.size,
               "content_type" => file.content_type,
               "row_count" => count,
               "truncated" => truncated
             }}

          error ->
            {:export_failed, error}
        end
      end)
    end)
    |> case do
      {:ok, %{result: {:export_failed, error}}} -> error
      result -> result
    end
  end

  defp export(_engine, _endpoint, _context, _sql, _params, _limits, _max_rows, _destination),
    do: {:error, %{code: "export_requires_actor", retryable: false, request_sent: false}}

  # The export preview keeps rows while take_rows would; once full it stays
  # full, so the preview remains a prefix of the exported rows.
  defp preview_row({rows, _count, bytes} = kept, row, max_rows, max_bytes) do
    case keep_row(kept, row, max_rows, max_bytes) do
      :full -> {rows, max_rows, bytes}
      kept -> kept
    end
  end

  ## Explain and probes

  def explain(engine, context, sql, params) do
    limits = Config.limits()

    with {:ok, _facts} <- inspect_sql(engine, sql),
         {:ok, endpoint} <- endpoint(engine, context.auth_config),
         {:ok, %{result: rows}} <-
           session(engine, endpoint, limits, timeout(context, limits), fn exec ->
             exec.(
               engine.explain_sql(sql),
               params,
               [take: 100_000],
               &bounded_rows(&1, 100_000, limits["max_result_bytes"])
             )
           end),
         {:ok, rows} <- rows,
         do: {:ok, %{"plan" => engine.plan(rows), "sql" => sql}}
  end

  # Results that make sense only whole, such as a plan or a probe, are
  # rejected rather than cut when they exceed the byte budget.
  defp bounded_rows(chunks, max_rows, max_bytes) do
    case take_rows(chunks, max_rows, max_bytes) do
      {rows, false} ->
        {:ok, rows}

      {_rows, true} ->
        {:error,
         %{
           code: "result_too_large",
           message:
             "The result exceeds the max_result_bytes budget. Narrow the statement or probe a shorter column.",
           retryable: false
         }}
    end
  end

  def probe(engine, context, %{"table" => table, "probes" => probes} = args) do
    limits = Config.limits()
    # The probes of one call share the byte budget.
    max_bytes = div(limits["max_result_bytes"], max(length(probes), 1))

    with :ok <- probe_budget(probes, limits),
         {:ok, described} <- probe_table(context.auth_config, args["schema"], table),
         :ok <- known_columns(described, probes),
         {:ok, endpoint} <- endpoint(engine, context.auth_config) do
      sensitive = for column <- described["columns"], column["sensitive"], do: column["name"]
      relation = relation(engine, described["schema"], table)

      with {:ok, results} <-
             session(engine, endpoint, limits, timeout(context, limits), fn exec ->
               run_probes(engine, exec, relation, probes, &(&1 in sensitive), max_bytes)
             end),
           do: {:ok, %{"results" => results}}
    end
  end

  # Sensitivity depends on column types, so a probe needs the cached columns.
  defp probe_table(config, schema, table) do
    case describe(config, schema, table) do
      {:error, :table_not_found} ->
        {:error,
         %{
           code: "table_not_cataloged",
           message:
             "The catalog has no columns for #{table}. Ask an administrator to refresh the connection's catalog, then probe again.",
           retryable: false,
           request_sent: false
         }}

      result ->
        result
    end
  end

  # The cache records sensitivity at refresh time; the connection's current
  # exclusions and the heuristics apply at once.
  defp describe(config, schema, table) do
    with {:ok, described} <- Ankole.Connectors.describe_database_table(config, schema, table) do
      [marked] =
        mark_catalog(config, [
          %{"schema" => described["schema"], "name" => table, "columns" => described["columns"]}
        ])

      {:ok, %{described | "columns" => marked["columns"]}}
    end
  end

  @doc """
  Marks cached columns sensitive when their stored flag, the connection's
  current `sample_exclusions`, or the name and type heuristics say so, and
  drops the sampled values of every sensitive column. Each table carries
  `schema`, `name`, and `columns`.
  """
  def mark_catalog(config, tables) do
    exclusions = Profile.exclusions(config.public_metadata || %{})

    Enum.map(tables, fn table ->
      columns =
        Enum.map(table["columns"], fn column ->
          if column["sensitive"] == true or Profile.sensitive?(table, column, exclusions),
            do:
              column
              |> Map.put("sensitive", true)
              |> Map.update("profile", nil, &Profile.masked/1),
            else: column
        end)

      %{table | "columns" => columns}
    end)
  end

  defp probe_budget(probes, limits) do
    if length(probes) > limits["probe_count"],
      do:
        {:error,
         %{
           code: "probe_budget_exceeded",
           message: "Send at most #{limits["probe_count"]} probes per call.",
           retryable: false,
           request_sent: false
         }},
      else: :ok
  end

  defp run_probes(engine, exec, relation, probes, sensitive?, max_bytes) do
    exec = fn sql, params ->
      exec.(sql, params, [take: @probe_values], &bounded_rows(&1, @probe_values, max_bytes))
    end

    Enum.reduce_while(probes, {:ok, []}, fn probe, {:ok, results} ->
      case run_probe(engine, exec, relation, probe, sensitive?.(probe["column"])) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp known_columns(described, probes) do
    names = Enum.map(described["columns"], & &1["name"])

    case Enum.reject(probes, &(&1["column"] in names)) do
      [] ->
        :ok

      [missing | _] ->
        {:error,
         %{
           code: "unknown_column",
           message: "#{missing["column"]} is not a column of #{described["table"]}.",
           retryable: false,
           request_sent: false
         }}
    end
  end

  defp relation(engine, nil, table), do: engine.quote(table)
  defp relation(engine, "", table), do: engine.quote(table)
  defp relation(engine, schema, table), do: engine.quote(schema) <> "." <> engine.quote(table)

  defp run_probe(engine, exec, relation, %{"kind" => "range"} = probe, sensitive?) do
    column = engine.quote(probe["column"])

    select =
      if sensitive?,
        do: "COUNT(*), COUNT(#{column})",
        else: "COUNT(*), COUNT(#{column}), MIN(#{column}), MAX(#{column})"

    with {:ok, [[rows, non_null | bounds]]} <-
           first_rows(exec, "SELECT #{select} FROM #{relation}", []) do
      {:ok,
       Map.merge(
         base(probe, sensitive?),
         %{"row_count" => int(rows), "non_null_count" => int(non_null)}
       )
       |> Map.merge(
         case bounds do
           [min, max] -> %{"min" => min, "max" => max}
           _ -> %{}
         end
       )}
    end
  end

  defp run_probe(engine, exec, relation, %{"kind" => "distinct"} = probe, true) do
    column = engine.quote(probe["column"])

    with {:ok, [[count]]} <-
           first_rows(exec, "SELECT COUNT(DISTINCT #{column}) FROM #{relation}", []),
         do: {:ok, Map.put(base(probe, true), "exact_count", int(count))}
  end

  defp run_probe(engine, exec, relation, %{"kind" => "distinct"} = probe, false) do
    column = engine.quote(probe["column"])

    sql =
      "SELECT #{column}, COUNT(*) AS ankole_count FROM #{relation} GROUP BY #{column} " <>
        "ORDER BY ankole_count DESC LIMIT #{@probe_values}"

    with {:ok, rows} <- first_rows(exec, sql, []),
         do: {:ok, Map.put(base(probe, false), "values", value_counts(rows))}
  end

  defp run_probe(
         engine,
         exec,
         relation,
         %{"kind" => "match", "value" => value} = probe,
         sensitive?
       )
       when is_binary(value) do
    column = engine.quote(probe["column"])
    pattern = "%" <> escape_like(String.downcase(String.trim(value))) <> "%"
    fuzzy = engine.normalized_text(column)

    exact =
      "SELECT COUNT(*) FROM #{relation} WHERE CAST(#{column} AS #{engine.text_type()}) = #{engine.placeholder(1)}"

    near =
      if sensitive?,
        do: "SELECT COUNT(*) FROM #{relation} WHERE #{fuzzy} LIKE #{engine.placeholder(1)}",
        else:
          "SELECT #{column}, COUNT(*) AS ankole_count FROM #{relation} WHERE #{fuzzy} LIKE #{engine.placeholder(1)} " <>
            "GROUP BY #{column} ORDER BY ankole_count DESC LIMIT #{@probe_values}"

    with {:ok, [[exact_count]]} <- first_rows(exec, exact, [value]),
         {:ok, near_rows} <- first_rows(exec, near, [pattern]) do
      result = Map.put(base(probe, sensitive?), "exact_count", int(exact_count))

      if sensitive?,
        do:
          {:ok, Map.put(result, "values", [%{"value" => nil, "count" => int(hd(hd(near_rows)))}])},
        else: {:ok, Map.put(result, "values", value_counts(near_rows))}
    end
  end

  defp run_probe(_engine, _exec, _relation, probe, _sensitive?),
    do:
      {:error,
       %{
         code: "invalid_tool_arguments",
         message: "A match probe on #{probe["column"]} needs a value.",
         retryable: false
       }}

  defp first_rows(exec, sql, params) do
    with {:ok, %{result: rows}} <- exec.(sql, params), do: rows
  end

  defp base(probe, sensitive?),
    do: %{"column" => probe["column"], "kind" => probe["kind"], "masked" => sensitive?}

  defp value_counts(rows),
    do: Enum.map(rows, fn [value, count] -> %{"value" => value, "count" => int(count)} end)

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_binary(value), do: String.to_integer(value)
  defp int(_), do: nil

  defp escape_like(text),
    do:
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

  ## Catalog

  def fetch_catalog(engine, config, secret, _opts) do
    limits = Config.limits()
    exclusions = Profile.exclusions(Map.merge(config.public_metadata || %{}, secret))

    with {:ok, endpoint} <- Network.endpoint(config, secret, engine.default_port()) do
      session(
        engine,
        endpoint,
        limits,
        limits["statement_timeout_ms"] * 20 + @connect_ms,
        fn exec ->
          # One table past the budget shows that the snapshot is incomplete.
          with {:ok, fetched} <- engine.catalog(exec, limits["catalog_tables"] + 1) do
            tables = Enum.take(fetched, limits["catalog_tables"])
            counts = engine.query_counts(exec)
            fetched_at = DateTime.utc_now() |> DateTime.to_iso8601()

            tables =
              Enum.map(tables, fn table ->
                table
                |> Map.put("query_count", Map.get(counts, {table["schema"], table["name"]}))
                |> Profile.mark(exclusions)
              end)

            profiled =
              tables
              |> Enum.sort_by(&{-(&1["query_count"] || 0), -(&1["row_estimate"] || 0)})
              |> Enum.take(limits["profile_tables"])
              |> MapSet.new(&{&1["schema"], &1["name"]})

            {:ok,
             %{
               "complete" => length(fetched) == length(tables),
               "tables" =>
                 Enum.map(tables, fn table ->
                   if MapSet.member?(profiled, {table["schema"], table["name"]}),
                     do: sample(engine, exec, table, limits, fetched_at),
                     else: table
                 end)
             }}
          end
        end
      )
    end
  end

  # Only non-sensitive columns are selected, so a skipped column's values never leave the database.
  defp sample(engine, exec, table, limits, fetched_at) do
    rows = limits["sample_rows"]
    columns = table["columns"] |> Enum.reject(& &1["sensitive"]) |> Enum.map(& &1["name"])

    if columns == [] do
      table
    else
      sql =
        "SELECT #{Enum.map_join(columns, ", ", &engine.quote/1)} FROM " <>
          relation(engine, table["schema"], table["name"]) <> " LIMIT #{rows}"

      case exec.(sql, [], [take: rows], &take_rows(&1, rows, limits["max_result_bytes"])) do
        {:ok, %{result: {sampled, _truncated}}} ->
          Profile.summarize(table, columns, sampled, fetched_at)

        _ ->
          table
      end
    end
  end

  @doc """
  Sums query-history counts per `{schema, table}`. Each entry is a recorded
  statement and its call count; `sql_inspect` names the tables it reads.
  """
  def table_counts(statements, dialect, default_schema) do
    Enum.reduce(statements, %{}, fn [query, calls], counts ->
      case Ankole.Kernel.sql_inspect(to_string(query), dialect) do
        {:ok, %{"tables" => tables}} ->
          calls = if is_binary(calls), do: String.to_integer(calls), else: calls

          tables
          |> Enum.map(&{&1["schema"] || default_schema, &1["name"]})
          |> Enum.uniq()
          |> Enum.reduce(counts, &Map.update(&2, &1, calls, fn n -> n + calls end))

        _ ->
          counts
      end
    end)
  end

  ## Sessions

  def inspect_sql(engine, sql) when is_binary(sql) do
    case Ankole.Kernel.sql_inspect(sql, engine.dialect()) do
      {:ok, facts} ->
        {:ok, facts}

      {:error, %{"code" => code} = error} ->
        {:error, %{code: code, message: error["message"], retryable: false, request_sent: false}}
    end
  end

  def inspect_sql(_engine, _sql),
    do: {:error, %{code: "empty", message: "Provide one SQL query.", retryable: false}}

  defp endpoint(engine, config) do
    with {:ok, secret} <- Ankole.Connectors.resolve_credentials(config.id),
         do: Network.endpoint(config, secret, engine.default_port())
  end

  defp timeout(context, limits) do
    budget = limits["statement_timeout_ms"] + @connect_ms

    case context[:deadline] do
      deadline when is_integer(deadline) ->
        max(min(budget, deadline - System.monotonic_time(:millisecond)), 0)

      _ ->
        budget
    end
  end

  @doc "Stops a driver pool that may already have exited after a failed connect."
  def stop(conn) do
    GenServer.stop(conn)
  catch
    :exit, _ -> :ok
  end

  @doc "Runs one engine session in a supervised task, bounded by `timeout` milliseconds."
  def session(engine, endpoint, limits, timeout, fun) do
    task =
      Task.Supervisor.async_nolink(
        @tasks,
        Ankole.Repo.bind_tenant(fn -> engine.session(endpoint, limits, fun) end)
      )

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.warning("Database connector session failed: #{inspect(reason, limit: 5)}")

        {:error,
         %{
           code: "database_unavailable",
           message:
             "Ankole could not complete the database session. Check the host, credentials, and TLS settings.",
           retryable: true
         }}

      nil ->
        {:error,
         %{
           code: "statement_timeout",
           message: "The statement exceeded its time budget.",
           retryable: false
         }}
    end
  end
end
