defmodule Ankole.Plugins.DatabaseConnectors.ClickHouse do
  @moduledoc """
  ClickHouse connections over its HTTP(S) SQL interface through
  `Ankole.Files.HTTP`, which applies the SSRF policy and the egress proxy.

  Every request sends `readonly=1`, `max_execution_time`,
  `max_bytes_to_read`, and `max_result_rows` with
  `result_overflow_mode=break`, plus the `limit` setting, which caps the
  outermost result at the rows Ankole fetches without rewriting the statement;
  `max_result_rows` alone stops only at a block boundary, and one block of wide
  rows can exceed the response budget. Results use
  `JSONCompactEachRowWithNamesAndTypes` with 64-bit integers and decimals
  quoted, so those values keep full precision as strings while NULLs, arrays,
  and maps stay JSON values, and parameters bind natively as `{p1:Type}`
  placeholders. The `verify` and `require` TLS modes pass the same client
  options as the MySQL and PostgreSQL drivers to `Ankole.Files.HTTP`, so
  `verify` trusts the system certificate authorities or the connection's
  `ca_certificate`.

  An export streams without `wait_end_of_query`, so ClickHouse may fail after
  it has sent `200 OK` and some rows. With
  `http_write_exception_in_output_format=0`, ClickHouse then writes an
  `__exception__` marker and its error as plain text after the last row. The
  first line that is not a JSON row starts that report: the decoder collects
  the rest of the response, up to 64 KiB, and raises `ServerError` with the text
  from the first `Code:` on, so marker or tag lines that a newer server adds do
  not hide the message. The error aborts the Pod upload and returns the
  server's error code and message.
  """
  @behaviour Ankole.Connectors.Connector
  alias Ankole.Plugins.DatabaseConnectors.{Adapter, Network, Tools}

  defmodule ServerError do
    @moduledoc false
    defexception [:message]
  end

  @tools Tools.tools("clickhouse")
  @format "JSONCompactEachRowWithNamesAndTypes"
  @error_report_bytes 64 * 1024
  @report_key {__MODULE__, :error_report}
  @system_databases "('system', 'INFORMATION_SCHEMA', 'information_schema')"
  # ClickHouse returns up to `take` rows whatever max_result_bytes says, and the
  # consumer trims them to the budget; this floor keeps a small budget from
  # rejecting a response that the consumer would only truncate.
  @response_bytes 8_000_000

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

  # Several tenants and connections may read the same cluster with different users.
  @impl true
  def platform_application(_config), do: {:ok, nil}

  def dialect, do: :clickhouse
  def default_port, do: 8443
  def quote(name), do: "`" <> String.replace(name, ["\\", "`"], &("\\" <> &1)) <> "`"
  def placeholder(index), do: "{p#{index}:String}"
  def text_type, do: "String"
  def normalized_text(column), do: "lowerUTF8(trimBoth(toString(#{column})))"
  def explain_sql(sql), do: "EXPLAIN " <> sql
  def plan(rows), do: Enum.map_join(rows, "\n", &hd/1)

  def session(endpoint, limits, fun),
    do:
      fun.(fn sql, params, opts, consume ->
        exec(endpoint, limits, sql, params, opts, consume)
      end)

  defp exec(endpoint, limits, sql, params, opts, consume) do
    take = opts[:take] || limits["max_rows"]
    url = url(endpoint, limits, params, take, opts[:stream] == true)

    headers = [
      {"x-clickhouse-user", endpoint.username},
      {"x-clickhouse-key", endpoint.password},
      {"content-type", "text/plain; charset=utf-8"}
    ]

    http =
      [timeout: limits["statement_timeout_ms"] + 5_000, idempotent: true] ++
        if(endpoint.tls == "disable",
          do: [],
          else: [transport_opts: Network.ssl_options(endpoint)]
        )

    if opts[:stream] == true,
      do: stream(url, headers, sql, http, consume),
      else:
        buffered(
          url,
          headers,
          sql,
          Keyword.put(http, :max_bytes, max(limits["max_result_bytes"] * 4, @response_bytes)),
          consume
        )
  end

  defp url(endpoint, limits, params, take, stream?) do
    scheme = if endpoint.tls == "disable", do: "http", else: "https"
    host = if String.contains?(endpoint.host, ":"), do: "[#{endpoint.host}]", else: endpoint.host

    settings =
      [
        database: endpoint.database || "default",
        default_format: @format,
        output_format_json_quote_64bit_integers: 1,
        output_format_json_quote_decimals: 1,
        output_format_decimal_trailing_zeros: 1,
        http_write_exception_in_output_format: 0,
        max_execution_time: div(limits["statement_timeout_ms"] + 999, 1000),
        max_bytes_to_read: limits["max_scanned_bytes"],
        max_result_rows: take,
        result_overflow_mode: "break",
        limit: take
      ] ++
        if(stream?,
          do: [],
          else: [max_result_bytes: limits["max_result_bytes"], wait_end_of_query: 1]
        ) ++
        Enum.map(Enum.with_index(params, 1), fn {value, index} ->
          {"param_p#{index}", param(value)}
        end) ++ [readonly: 1]

    "#{scheme}://#{host}:#{endpoint.port}/?" <> URI.encode_query(settings)
  end

  defp param(nil), do: "\\N"
  defp param(value) when is_binary(value), do: value
  defp param(value), do: to_string(value)

  defp buffered(url, headers, sql, http, consume) do
    case Ankole.Files.HTTP.request("POST", url, headers, sql, http) do
      {:ok, %{status: 200, body: body}} ->
        with {:ok, [names, types | rows]} <- decode_lines(String.split(body, "\n", trim: true)) do
          {:ok, %{columns: columns(names, types), result: consume.([{names, rows}])}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, failure(status, body)}

      {:error, %{reason: ":json_too_large"}} ->
        {:error,
         %{
           code: "result_too_large",
           message: "The rows exceed the response budget. Select fewer or narrower columns.",
           retryable: false
         }}

      {:error, %{code: "http_request_failed"} = error} ->
        {:error, Map.merge(error, %{code: "database_unavailable", retryable: true})}

      error ->
        error
    end
  end

  defp stream(url, headers, sql, http, consume) do
    key = {__MODULE__, make_ref()}

    chunks =
      Ankole.Files.HTTP.stream("POST", url, headers, sql, http)
      |> decode_stream(&Process.put(@report_key, &1))
      |> Stream.transform(:names, fn
        names, :names ->
          {[], {:types, names}}

        types, {:types, names} ->
          Process.put(key, columns(names, types))
          {[], {:rows, names}}

        row, {:rows, names} ->
          {[{names, [row]}], {:rows, names}}
      end)

    result = consume.(chunks)
    Process.delete(@report_key)
    {:ok, %{columns: Process.delete(key) || [], result: result}}
  rescue
    error in ServerError ->
      Process.delete(@report_key)
      {:error, failure(500, error.message)}

    error in Ankole.Files.HTTP.Error ->
      # ClickHouse closes the connection after its error report, so a transport
      # error that follows a report carries the report's message.
      case {Process.delete(@report_key), error} do
        {report, _error} when report != nil ->
          {:error, failure(500, report_text(report))}

        {nil, error} ->
          stream_failure(error)
      end
  end

  defp stream_failure(error) do
    case error do
      %{reason: {:http_status, status}, body: body} when is_binary(body) ->
        {:error, failure(status, body)}

      _ ->
        {:error,
         %{code: "database_unavailable", message: Exception.message(error), retryable: true}}
    end
  end

  @doc false
  # Splits a streamed response into JSON rows and raises `ServerError` with the
  # server's error report, which starts at the first line that is not a row.
  # `on_report` receives the report so far, in case the connection closes
  # before the stream ends.
  def decode_stream(chunks, on_report \\ fn _report -> :ok end) do
    Stream.transform(
      chunks,
      fn -> {"", nil} end,
      fn data, {buffer, failure} ->
        [rest | lines] =
          (buffer <> IO.iodata_to_binary(data)) |> String.split("\n") |> Enum.reverse()

        {rows, failure} = stream_rows(Enum.reverse(lines), failure)
        if failure, do: on_report.([elem(failure, 0), "\n", rest])
        {rows, {rest, failure}}
      end,
      fn {rest, failure} ->
        case stream_rows([rest], failure) do
          {rows, nil} -> {rows, {"", nil}}
          {_rows, {report, _size}} -> raise ServerError, message: report_text(report)
        end
      end,
      fn _acc -> :ok end
    )
  end

  defp stream_rows(lines, failure) do
    Enum.flat_map_reduce(lines, failure, fn
      line, nil ->
        line = String.trim_trailing(line, "\r")

        case Torque.decode(line) do
          _ when line == "" -> {[], nil}
          {:ok, row} when is_list(row) -> {[row], nil}
          _ -> {[], {[line], byte_size(line)}}
        end

      line, {report, size} ->
        size = size + byte_size(line) + 1
        report = [report, "\n", line]

        if size >= @error_report_bytes,
          do: raise(ServerError, message: report_text(report)),
          else: {[], {report, size}}
    end)
  end

  defp report_text(report) do
    text =
      report
      |> IO.iodata_to_binary()
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.reject(&(&1 in ["", "__exception__"]))
      |> Enum.join("\n")

    case :binary.match(text, "Code: ") do
      {start, _} ->
        binary_part(text, start, byte_size(text) - start)

      :nomatch when text == "" ->
        "ClickHouse ended the result with an error report but no message."

      :nomatch ->
        text
    end
  end

  defp decode_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case Torque.decode(line) do
        {:ok, value} when is_list(value) -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, {:error, %{code: "invalid_upstream_output", retryable: false}}}
      end
    end)
    |> case do
      {:ok, [_, _ | _] = decoded} -> {:ok, Enum.reverse(decoded)}
      {:ok, _} -> {:error, %{code: "invalid_upstream_output", retryable: false}}
      error -> error
    end
  end

  defp columns(names, types),
    do: Enum.zip_with(names, types, &%{"name" => &1, "type" => &2})

  defp failure(status, body) do
    message = String.slice(String.trim(body), 0, 2_000)

    code =
      case Regex.run(~r/Code: (\d+)/, body) do
        [_, code] when code in ["159", "160"] -> "statement_timeout"
        [_, code] when code in ["164"] -> "not_read_only"
        [_, code] when code in ["307", "396"] -> "scan_budget_exceeded"
        _ when status in [401, 403, 516] -> "database_unauthorized"
        _ -> "query_failed"
      end

    %{code: code, message: message, retryable: false}
  end

  ## Catalog

  def catalog(exec, max_tables) do
    with {:ok, %{result: tables}} <-
           exec.(
             """
             SELECT database, name, engine, comment, toString(total_rows), sorting_key, primary_key
             FROM system.tables
             WHERE database NOT IN #{@system_databases} AND NOT is_temporary
             ORDER BY database, name LIMIT {p1:UInt32}
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
    tuples =
      Enum.map_join(tables, ", ", fn [database, name | _] ->
        "(#{literal(database)}, #{literal(name)})"
      end)

    with {:ok, %{result: columns}} <-
           exec.(
             """
             SELECT database, table, name, toString(position), type, comment,
                    is_in_sorting_key OR is_in_primary_key
             FROM system.columns
             WHERE database NOT IN #{@system_databases} AND (database, table) IN (#{tuples})
             ORDER BY database, table, position
             """,
             [],
             [take: 1_000_000],
             &rows/1
           ) do
      {:ok, assemble(tables, columns)}
    end
  end

  defp literal(value),
    do: "'" <> (value |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")) <> "'"

  defp rows(chunks), do: Enum.flat_map(chunks, fn {_names, rows} -> rows end)

  # ClickHouse sorting and primary keys order sparse index granules; they never
  # promise uniqueness, so the cache records them as sparse_order_key only. The
  # table lists the key's expressions in order, and each column records whether
  # any of them reads it, as system.columns reports.
  defp assemble(tables, columns) do
    columns = Enum.group_by(columns, fn [database, table | _] -> {database, table} end)

    Enum.map(tables, fn [database, name, engine, comment, total_rows, sorting_key, primary_key] ->
      order_key =
        key_expressions(if sorting_key in [nil, ""], do: primary_key || "", else: sorting_key)

      %{
        "schema" => database,
        "name" => name,
        "kind" => kind(engine),
        "comment" => if(comment in [nil, ""], do: nil, else: comment),
        "row_estimate" => integer(total_rows),
        "primary_key" => [],
        "sparse_order_key" => order_key,
        "columns" =>
          for [_, _, column, position, type, column_comment, in_key] <-
                Map.get(columns, {database, name}, []) do
            %{
              "name" => column,
              "ordinal" => integer(position),
              "type" => type,
              "nullable" => String.starts_with?(type, "Nullable("),
              "comment" => if(column_comment in [nil, ""], do: nil, else: column_comment),
              "primary_key" => false,
              "unique" => false,
              "sparse_order_key" => in_key == 1,
              "foreign_key" => nil
            }
          end
      }
    end)
  end

  # Splits a key such as `toDate(ts), toStartOfInterval(ts, toIntervalHour(1))` at
  # the commas outside parentheses, brackets, string literals, and quoted names.
  defp key_expressions(key), do: split_key(key, 0, nil, "", [])

  defp split_key("", _depth, _delimiter, part, parts),
    do: [part | parts] |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.reverse()

  defp split_key(<<?\\, char, rest::binary>>, depth, delimiter, part, parts)
       when delimiter != nil,
       do: split_key(rest, depth, delimiter, <<part::binary, ?\\, char>>, parts)

  defp split_key(<<char, rest::binary>>, depth, nil, part, parts) when char in [?', ?", ?`],
    do: split_key(rest, depth, char, <<part::binary, char>>, parts)

  defp split_key(<<char, rest::binary>>, depth, char, part, parts),
    do: split_key(rest, depth, nil, <<part::binary, char>>, parts)

  defp split_key(<<?,, rest::binary>>, 0, nil, part, parts),
    do: split_key(rest, 0, nil, "", [part | parts])

  defp split_key(<<char, rest::binary>>, depth, nil, part, parts) when char in [?(, ?[],
    do: split_key(rest, depth + 1, nil, <<part::binary, char>>, parts)

  defp split_key(<<char, rest::binary>>, depth, nil, part, parts) when char in [?), ?]],
    do: split_key(rest, depth - 1, nil, <<part::binary, char>>, parts)

  defp split_key(<<char, rest::binary>>, depth, delimiter, part, parts),
    do: split_key(rest, depth, delimiter, <<part::binary, char>>, parts)

  defp kind("MaterializedView"), do: "materialized_view"
  defp kind("View"), do: "view"
  defp kind("Dictionary"), do: "dictionary"
  defp kind(_), do: "table"

  defp integer(nil), do: nil

  defp integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  @doc "Counts finished SELECT queries per table from system.query_log when it is readable."
  def query_counts(exec) do
    case exec.(
           """
           SELECT table_name, toString(count()) FROM system.query_log ARRAY JOIN tables AS table_name
           WHERE type = 'QueryFinish' AND query_kind = 'Select' AND event_date >= today() - 30
           GROUP BY table_name ORDER BY count() DESC LIMIT 1000
           """,
           [],
           [take: 1000],
           &rows/1
         ) do
      {:ok, %{result: rows}} ->
        Map.new(rows, fn [qualified, count] ->
          case String.split(qualified, ".", parts: 2) do
            [database, table] -> {{database, table}, integer(count)}
            [table] -> {{"default", table}, integer(count)}
          end
        end)

      _ ->
        %{}
    end
  end
end
