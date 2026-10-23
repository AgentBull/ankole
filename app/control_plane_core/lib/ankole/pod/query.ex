defmodule Ankole.Pod.Query do
  @moduledoc false
  alias Ankole.Pod.{Formula, Values}
  alias Ankole.Repo

  def records(table, fields, attrs, opts \\ []) do
    with {:ok, where, params} <-
           filter(fields, Ankole.Attrs.get(attrs, :filter), [Repo.tenant_id!(), table.id]),
         {:ok, group, params} <- group_filter(fields, Ankole.Attrs.get(attrs, :group), params),
         {:ok, order, params} <- sort(fields, Ankole.Attrs.get(attrs, :sort, []), params),
         {:ok, cursor, params} <- cursor(table, attrs, order, params),
         {:ok, projection, params} <- projection(fields, params),
         {:ok, ids_sql, params} <- ids(Ankole.Attrs.get(attrs, :ids), params) do
      limit = Ankole.Attrs.get(attrs, :page_size, Keyword.get(opts, :limit, 200))

      if is_integer(limit) and limit > 0 and limit <= Keyword.get(opts, :max_limit, 100_000) do
        {limit_param, params} = Formula.bind(params, limit + 1)

        case Repo.query(
               "SELECT (to_jsonb(r) - 'tenant_id' - 'table_id') || jsonb_build_object('created_at', #{utc_timestamp("r.created_at")}, 'updated_at', #{utc_timestamp("r.updated_at")}, 'data', r.data || #{projection}), jsonb_build_array(#{Enum.map_join(order, ",", &cursor_value/1)}) FROM db_records r WHERE r.tenant_id = $1::text::uuid AND r.table_id = $2::text::uuid AND (#{where}) AND (#{group}) AND (#{cursor}) AND (#{ids_sql}) ORDER BY #{Enum.join(Enum.map(order, &(&1.sql <> " " <> &1.direction <> " NULLS LAST")) ++ ["r.id ASC"], ",")} LIMIT #{limit_param}",
               params
             ) do
          {:ok, result} ->
            {rows, extra} = Enum.split(result.rows, limit)
            last = List.last(rows)
            token = if extra != [] and last, do: encode_cursor(table, attrs, last), else: nil

            {:ok,
             %{
               records: Enum.map(rows, &hd/1),
               data_version: table.data_version,
               page_token: token,
               complete: extra == []
             }}

          {:error, error} ->
            {:error, {:invalid_query, Exception.message(error)}}
        end
      else
        {:error, :query_limit}
      end
    end
  end

  def filter(_fields, nil, params), do: {:ok, "TRUE", params}

  def filter(fields, attrs, params) when is_map(attrs) do
    conjunction = Ankole.Attrs.get(attrs, :conjunction, "and")
    conditions = Ankole.Attrs.get(attrs, :conditions, [])

    if conjunction in ["and", "or"] and is_list(conditions) and length(conditions) <= 100 and
         Enum.all?(conditions, &is_map/1) do
      Enum.reduce_while(conditions, {:ok, [], params}, fn attrs, {:ok, sqls, params} ->
        case condition(fields, attrs, params) do
          {:ok, sql, params} -> {:cont, {:ok, [sql | sqls], params}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, [], params} ->
          {:ok, "TRUE", params}

        {:ok, sqls, params} ->
          {:ok,
           "(" <> Enum.join(sqls, if(conjunction == "and", do: " AND ", else: " OR ")) <> ")",
           params}

        error ->
          error
      end
    else
      {:error, :invalid_query}
    end
  end

  def filter(_, _, _), do: {:error, :invalid_query}

  defp group_filter(_fields, nil, params), do: {:ok, "TRUE", params}

  defp group_filter(fields, attrs, params) when is_map(attrs) do
    with {:ok, field} <- field(fields, Ankole.Attrs.get(attrs, :field_id)) do
      value = Ankole.Attrs.get(attrs, :value)
      json = Ankole.Attrs.get(attrs, :value_json)

      cond do
        is_binary(json) ->
          exact_group_filter(field, fields, json, params)

        is_nil(value) ->
          typed_condition(field, fields, "is_empty", nil, params)

        true ->
          exact_group_filter(field, fields, Torque.encode!(value), params)
      end
    end
  end

  defp group_filter(_, _, _), do: {:error, :invalid_query}

  defp exact_group_filter(field, fields, json, params) do
    with {:ok, expr, type, params} <- Formula.expression(field, fields, params),
         {:ok, value} <- Torque.decode(json),
         {:ok, json} <- group_json(type, value, json) do
      {param, params} = Formula.bind(params, json)

      sql =
        if type == :array,
          do:
            "#{expr} @> jsonb_build_array(#{param}::text::jsonb) AND EXISTS (SELECT 1 FROM jsonb_array_elements(#{expr}) AS group_element(value) WHERE group_element.value = #{param}::text::jsonb)",
          else: "to_jsonb(#{expr}) = #{param}::text::jsonb"

      {:ok, "(#{param}::text::jsonb = 'null'::jsonb AND #{expr} IS NULL) OR (#{sql})", params}
    else
      _ -> {:error, :invalid_query}
    end
  end

  def aggregate(table, fields, attrs, opts \\ []) do
    groups = Ankole.Attrs.get(attrs, :group_by, [])
    metrics = Ankole.Attrs.get(attrs, :metrics, [%{"operation" => "count", "alias" => "count"}])

    with true <-
           is_list(groups) and length(groups) <= 2 and is_list(metrics) and
             length(metrics) in 1..20 and Enum.all?(groups ++ metrics, &is_map/1),
         {:ok, where, params} <-
           filter(fields, Ankole.Attrs.get(attrs, :filter), [Repo.tenant_id!(), table.id]),
         {:ok, group_sql, params, lateral} <- groups(fields, groups, params),
         {:ok, metrics_sql, params} <- metrics(fields, metrics, params) do
      columns = Enum.map_join(group_sql ++ metrics_sql, ",", & &1)

      grouping =
        if group_sql == [],
          do: "",
          else: " GROUP BY " <> Enum.join(group_sql, ",")

      case Repo.query(
             "SELECT jsonb_build_array(#{columns}), jsonb_build_array(#{Enum.map_join(group_sql, ",", &"COALESCE(to_jsonb(#{&1})::text,'null')")}) FROM db_records r #{lateral} WHERE r.tenant_id=$1::text::uuid AND r.table_id=$2::text::uuid AND (#{where})#{grouping} LIMIT #{Keyword.fetch!(opts, :max_groups) + 1}",
             params
           ) do
        {:ok, result} ->
          {:ok,
           %{
             groups:
               Enum.map(result.rows, fn [values, value_json] ->
                 %{
                   values: Enum.take(values, length(groups)),
                   value_json: value_json,
                   metrics:
                     Map.new(
                       Enum.zip(
                         Enum.map(
                           metrics,
                           &Ankole.Attrs.get(&1, :alias, Ankole.Attrs.get(&1, :operation))
                         ),
                         Enum.drop(values, length(groups))
                       )
                     )
                 }
               end),
             data_version: table.data_version
           }}

        _ ->
          {:error, :invalid_query}
      end
    else
      false -> {:error, :query_limit}
      error -> error
    end
  end

  defp condition(fields, attrs, params) do
    with {:ok, field} <- field(fields, Ankole.Attrs.get(attrs, :field_id)),
         op <- Ankole.Attrs.get(attrs, :operator),
         {:ok, value} <- condition_value(field, op, Ankole.Attrs.get(attrs, :value)) do
      stored =
        field.type != :formula and
          to_string(field.type) not in ~w(created_at updated_at created_by updated_by)

      cond do
        op == "is" and stored ->
          {json, params} = Formula.bind(params, Torque.encode!(%{field.id => value}))

          if Formula.type(field) == :array do
            {fid, params} = Formula.bind(params, field.id)

            {:ok,
             "r.data @> #{json}::text::jsonb AND (r.data->#{fid}::text)=(#{json}::text::jsonb->#{fid}::text)",
             params}
          else
            {:ok, "r.data @> #{json}::text::jsonb", params}
          end

        op == "contains" and Formula.type(field) == :array and stored ->
          {json, params} = Formula.bind(params, Torque.encode!(%{field.id => [value]}))
          {:ok, "r.data @> #{json}::text::jsonb", params}

        true ->
          typed_condition(field, fields, op, value, params)
      end
    end
  end

  defp condition_value(%{type: :datetime}, "is", value), do: datetime_value(value)
  defp condition_value(_field, _operator, value), do: {:ok, value}

  defp group_json(:datetime, value, _json) when not is_nil(value) do
    with {:ok, value} <- datetime_value(value), do: {:ok, Torque.encode!(value)}
  end

  defp group_json(_type, _value, json), do: {:ok, json}

  defp datetime_value(nil), do: {:ok, nil}

  defp datetime_value(value) do
    with {:ok, canonical} when is_binary(canonical) <- Values.cast(%{type: :datetime}, value, nil),
         do: {:ok, canonical},
         else: (_ -> {:error, :invalid_query})
  end

  defp typed_condition(field, fields, op, value, params) do
    with {:ok, expr, type, params} <- Formula.expression(field, fields, params) do
      expr =
        if type in [:text, :datetime] and op != "text_contains",
          do: "#{expr} COLLATE \"C\"",
          else: expr

      cond do
        op == "is_empty" ->
          {:ok, "#{expr} IS NULL", params}

        op == "is_not_empty" ->
          {:ok, "#{expr} IS NOT NULL", params}

        op == "text_contains" and type == :text and is_binary(value) ->
          {param, params} = Formula.bind(params, "%" <> Repo.escape_like(value) <> "%")
          {:ok, "#{expr} ILIKE #{param}::text", params}

        op in ["is", "gt", "gte", "lt", "lte"] ->
          with {:ok, param, params} <- typed_bind(params, value, type) do
            operator = %{"is" => "=", "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<="}[op]
            {:ok, "#{expr} #{operator} #{param}", params}
          end

        true ->
          {:error, :invalid_query}
      end
    end
  end

  defp sort(fields, sorts, params) when is_list(sorts) and length(sorts) <= 20 do
    Enum.reduce_while(sorts, {:ok, [], params}, fn attrs, {:ok, order, params} ->
      direction = if is_map(attrs), do: Ankole.Attrs.get(attrs, :direction, "asc")

      with true <- direction in ["asc", "desc"],
           {:ok, field} <- field(fields, Ankole.Attrs.get(attrs, :field_id)),
           {:ok, expr, type, params} <- Formula.expression(field, fields, params) do
        expr = if type in [:text, :datetime], do: "#{expr} COLLATE \"C\"", else: expr

        {:cont,
         {:ok, [%{sql: expr, type: type, direction: String.upcase(direction)} | order], params}}
      else
        _ -> {:halt, {:error, :invalid_query}}
      end
    end)
    |> reverse_values()
  end

  defp sort(_, _, _), do: {:error, :invalid_query}

  defp projection(fields, params) do
    fields
    |> Enum.filter(&(&1.type == :formula))
    |> Enum.reduce_while({:ok, "'{}'::jsonb", params}, fn field, {:ok, sql, params} ->
      with {:ok, expr, _type, params} <- Formula.expression(field, fields, params) do
        {key, params} = Formula.bind(params, field.id)
        {:cont, {:ok, sql <> " || jsonb_build_object(#{key}::text, #{expr})", params}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp ids(nil, params), do: {:ok, "TRUE", params}

  defp ids(ids, params) when is_list(ids) do
    ids = Enum.uniq(ids)

    if length(ids) <= Ankole.Pod.DbTable.record_limit() and
         Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      {param, params} = Formula.bind(params, ids)
      {:ok, "r.id=ANY(#{param}::text[]::uuid[])", params}
    else
      {:error, :invalid_query}
    end
  end

  defp ids(_, _), do: {:error, :invalid_query}

  defp cursor(table, attrs, order, params) do
    case Ankole.Attrs.get(attrs, :page_token) do
      nil ->
        {:ok, "TRUE", params}

      token ->
        with {:ok, payload} <-
               Phoenix.Token.verify(AnkoleWeb.Endpoint, "pod-table-cursor", token,
                 max_age: :infinity
               ),
             true <- payload.table_id == table.id and payload.query == fingerprint(attrs),
             true <- length(payload.values) == length(order) do
          cursor_sql(order, payload.values, payload.id, params)
        else
          _ -> {:error, :invalid_page_token}
        end
    end
  end

  defp cursor_sql(order, values, id, params) do
    {clauses, equal, params} =
      Enum.zip(order, values)
      |> Enum.reduce({[], [], params}, fn {key, value}, {clauses, equal, params} ->
        if is_nil(value) do
          {clauses, ["#{key.sql} IS NULL" | equal], params}
        else
          {:ok, param, params} = cursor_bind(params, value, key.type)

          after_sql =
            "(#{key.sql} #{if key.direction == "ASC", do: ">", else: "<"} #{param} OR #{key.sql} IS NULL)"

          clause = Enum.join([after_sql | equal], " AND ")
          {["(" <> clause <> ")" | clauses], ["#{key.sql} = #{param}" | equal], params}
        end
      end)

    {param, params} = Formula.bind(params, id)
    final = Enum.join(["r.id > #{param}::text::uuid" | equal], " AND ")
    {:ok, Enum.join(["(" <> final <> ")" | clauses], " OR "), params}
  end

  defp encode_cursor(table, attrs, [record, values]),
    do:
      Phoenix.Token.sign(AnkoleWeb.Endpoint, "pod-table-cursor", %{
        table_id: table.id,
        query: fingerprint(attrs),
        id: record["id"],
        values: values
      })

  defp fingerprint(attrs),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {Ankole.Attrs.get(attrs, :sort, []), Ankole.Attrs.get(attrs, :filter),
           Ankole.Attrs.get(attrs, :ids), Ankole.Attrs.get(attrs, :group)},
          [:deterministic]
        )
      )

  defp groups(fields, groups, params) do
    Enum.with_index(groups)
    |> Enum.reduce_while({:ok, [], params, ""}, fn {attrs, index}, {:ok, sqls, params, lateral} ->
      with {:ok, field} <- field(fields, Ankole.Attrs.get(attrs, :field_id)),
           {:ok, expr, type, params} <- Formula.expression(field, fields, params) do
        bucket = Ankole.Attrs.get(attrs, :bucket)

        cond do
          type == :array ->
            name = "group_value_#{index}"

            {:cont,
             {:ok, [name <> ".value" | sqls], params,
              lateral <>
                " LEFT JOIN LATERAL jsonb_array_elements(#{expr}) AS #{name}(value) ON TRUE "}}

          bucket in ["day", "week", "month", "quarter", "year"] and type == :datetime ->
            {param, params} = Formula.bind(params, bucket)

            formats = %{
              "day" => "YYYY-MM-DD",
              "week" => "YYYY-MM-DD",
              "month" => "YYYY-MM",
              "quarter" => "YYYY-\"Q\"Q",
              "year" => "YYYY"
            }

            {format, params} = Formula.bind(params, formats[bucket])

            {:cont,
             {:ok,
              [
                "to_char(date_trunc(#{param}::text, #{expr}::timestamptz),#{format}::text)" | sqls
              ], params, lateral}}

          is_nil(bucket) ->
            {:cont, {:ok, [expr | sqls], params, lateral}}

          true ->
            {:halt, {:error, :invalid_query}}
        end
      else
        error -> {:halt, error}
      end
    end)
    |> reverse_values()
  end

  defp metrics(fields, metrics, params) do
    Enum.reduce_while(metrics, {:ok, [], params}, fn attrs, {:ok, sqls, params} ->
      operation = Ankole.Attrs.get(attrs, :operation)

      if operation == "count" and is_nil(Ankole.Attrs.get(attrs, :field_id)) do
        {:cont, {:ok, ["count(*)" | sqls], params}}
      else
        with true <- operation in ["count", "sum", "avg", "min", "max"],
             {:ok, field} <- field(fields, Ankole.Attrs.get(attrs, :field_id)),
             {:ok, expr, type, params} <- Formula.expression(field, fields, params),
             true <-
               operation == "count" or type == :number or
                 (operation in ["min", "max"] and type in [:text, :datetime]) do
          expr = if type in [:text, :datetime], do: "#{expr} COLLATE \"C\"", else: expr
          {:cont, {:ok, [operation <> "(" <> expr <> ")" | sqls], params}}
        else
          _ -> {:halt, {:error, :invalid_query}}
        end
      end
    end)
    |> reverse_values()
  end

  defp reverse_values({:ok, values, params}), do: {:ok, Enum.reverse(values), params}

  defp reverse_values({:ok, values, params, lateral}),
    do: {:ok, Enum.reverse(values), params, lateral}

  defp reverse_values(error), do: error

  defp field(fields, id) do
    case Enum.find(fields, &(&1.id == id)) do
      nil -> {:error, :unknown_field}
      field -> {:ok, field}
    end
  end

  defp cursor_value(%{type: type, sql: sql}) when type in [:number, :array],
    do: "(#{sql})::text"

  defp cursor_value(%{sql: sql}), do: sql

  defp cursor_bind(params, value, type) when is_binary(value) and type in [:number, :array] do
    {param, params} = Formula.bind(params, value)
    cast = if type == :number, do: "numeric", else: "jsonb"
    {:ok, param <> "::text::" <> cast, params}
  end

  defp cursor_bind(params, value, type), do: typed_bind(params, value, type)

  defp typed_bind(params, value, :number) when is_number(value) do
    {param, params} = Formula.bind(params, to_string(value))
    {:ok, param <> "::text::numeric", params}
  end

  defp typed_bind(params, value, :boolean) when is_boolean(value) do
    {param, params} = Formula.bind(params, value)
    {:ok, param <> "::boolean", params}
  end

  defp typed_bind(params, value, :datetime) do
    with {:ok, canonical} <- datetime_value(value) do
      {param, params} = Formula.bind(params, canonical)
      {:ok, param <> "::text", params}
    end
  end

  defp typed_bind(params, value, :text) when is_binary(value) do
    {param, params} = Formula.bind(params, value)
    {:ok, param <> "::text", params}
  end

  defp typed_bind(params, value, :array) when is_list(value) do
    {param, params} = Formula.bind(params, Torque.encode!(value))
    {:ok, param <> "::text::jsonb", params}
  end

  defp typed_bind(_, _, _), do: {:error, :invalid_query}

  defp utc_timestamp(column),
    do: "to_char(#{column} AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')"
end
