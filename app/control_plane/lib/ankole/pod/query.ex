defmodule Ankole.Pod.Query do
  @moduledoc false
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :tenant_schema
  alias Ankole.Pod.{Formula, Values}
  alias Ankole.Repo
  alias Ankole.Pod.BaseRepo
  alias Ankole.Pod.Bases.{Links, Physical}

  @bucket_formats %{
    "day" => "YYYY-MM-DD",
    "week" => "YYYY-MM-DD",
    "month" => "YYYY-MM",
    "quarter" => "YYYY-\"Q\"Q",
    "year" => "YYYY"
  }

  def records(table, fields, attrs, opts \\ []) do
    fields = Physical.fields(table, fields)

    with {:ok, where, params} <-
           filter(fields, Ankole.Attrs.get(attrs, :filter), [Repo.tenant_id!(), table.id]),
         {:ok, search_sql, params} <-
           search_filter(fields, Ankole.Attrs.get(attrs, :search), params, opts),
         {:ok, slices} <- normalize_group_slices(attrs),
         {:ok, group, params} <- group_slices_filter(fields, slices, params),
         {:ok, order, params} <- sort(fields, Ankole.Attrs.get(attrs, :sort, []), params),
         {:ok, cursor, params} <- cursor(table, attrs, order, params),
         {:ok, projection, params} <-
           projection(
             fields,
             params,
             if(Keyword.get(opts, :raw_json, false), do: Keyword.get(opts, :formula_ids, []))
           ),
         {:ok, ids_sql, params} <- ids(Ankole.Attrs.get(attrs, :ids), params) do
      limit = Ankole.Attrs.get(attrs, :page_size, Keyword.get(opts, :limit, 200))

      if is_integer(limit) and limit > 0 and limit <= Keyword.get(opts, :max_limit, 100_000) do
        {limit_param, params} = Formula.bind(params, limit + 1)
        {offset_param, params} = Formula.bind(params, Keyword.get(opts, :offset, 0))

        json_cast = if Keyword.get(opts, :raw_json, false), do: "::text", else: ""

        case execute(
               table,
               "SELECT (#{record_sql(table, fields, projection)})#{json_cast}, jsonb_build_array(#{Enum.map_join(order, ",", &cursor_value/1)}) FROM #{source(table)} r WHERE #{scope(table)} AND (#{where}) AND (#{search_sql}) AND (#{group}) AND (#{cursor}) AND (#{ids_sql}) ORDER BY #{Enum.join(Enum.map(order, &(&1.sql <> " " <> &1.direction <> " NULLS LAST")) ++ ["r.id ASC"], ",")} LIMIT #{limit_param} OFFSET #{offset_param}",
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

  def snapshot_fits?(table, fields, max_bytes) do
    fields = Physical.fields(table, fields)
    {:ok, projection, params} = projection(fields, [Repo.tenant_id!(), table.id, max_bytes])

    {:ok, %{rows: [[fits]]}} =
      execute(
        table,
        "SELECT COALESCE(sum(octet_length((#{record_sql(table, fields, projection)})::text)+1),0)+1 <= $3 FROM #{source(table)} r WHERE #{scope(table)}",
        params
      )

    fits
  end

  defp record_sql(table, fields, projection),
    do:
      "#{envelope(table)} || jsonb_build_object('created_at', #{utc_timestamp("r.created_at")}, 'updated_at', #{utc_timestamp("r.updated_at")}, 'data', #{data(table, fields)} || #{projection})"

  def filter(fields, attrs, params), do: combine(attrs, params, &condition(fields, &1, &2))

  # The accumulator is opaque so aggregates can also collect linked table IDs.
  defp combine(nil, acc, _condition), do: {:ok, "TRUE", acc}

  defp combine(attrs, acc, condition) when is_map(attrs) do
    conjunction = Ankole.Attrs.get(attrs, :conjunction, "and")
    conditions = Ankole.Attrs.get(attrs, :conditions, [])

    if conjunction in ["and", "or"] and is_list(conditions) and length(conditions) <= 100 and
         Enum.all?(conditions, &is_map/1) do
      Enum.reduce_while(conditions, {:ok, [], acc}, fn attrs, {:ok, sqls, acc} ->
        case condition.(attrs, acc) do
          {:ok, sql, acc} -> {:cont, {:ok, [sql | sqls], acc}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, [], acc} ->
          {:ok, "TRUE", acc}

        {:ok, sqls, acc} ->
          {:ok,
           "(" <> Enum.join(sqls, if(conjunction == "and", do: " AND ", else: " OR ")) <> ")",
           acc}

        error ->
          error
      end
    else
      {:error, :invalid_query}
    end
  end

  defp combine(_attrs, _acc, _condition), do: {:error, :invalid_query}

  defp normalize_group_slices(attrs) when is_map(attrs) do
    with {:ok, first} <- slice_list(Ankole.Attrs.get(attrs, :group), :single_or_list),
         {:ok, rest} <- slice_list(Ankole.Attrs.get(attrs, :groups), :list_only) do
      slices = first ++ rest
      if length(slices) <= 2, do: {:ok, slices}, else: {:error, :invalid_query}
    end
  end

  defp normalize_group_slices(_attrs), do: {:error, :invalid_query}

  defp slice_list(nil, _mode), do: {:ok, []}
  defp slice_list(slice, :single_or_list) when is_map(slice), do: {:ok, [slice]}

  defp slice_list(slices, _mode) when is_list(slices) do
    if Enum.all?(slices, &is_map/1), do: {:ok, slices}, else: {:error, :invalid_query}
  end

  defp slice_list(_invalid, _mode), do: {:error, :invalid_query}

  defp group_slices_filter(_fields, [], params), do: {:ok, "TRUE", params}

  defp group_slices_filter(fields, slices, params) do
    Enum.reduce_while(slices, {:ok, [], params}, fn slice, {:ok, sqls, params} ->
      case slice_filter(fields, slice, params) do
        {:ok, sql, params} -> {:cont, {:ok, [sql | sqls], params}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sqls, params} ->
        {:ok, Enum.map_join(Enum.reverse(sqls), " AND ", &"(#{&1})"), params}

      error ->
        error
    end
  end

  defp slice_filter(fields, slice, params) do
    with {:ok, field} <- field(fields, Ankole.Attrs.get(slice, :field_id)),
         {:ok, bucket} <- normalize_bucket(Ankole.Attrs.get(slice, :bucket)),
         {:ok, other_exclude} <- extract_other_exclude(slice) do
      cumulative_from = Ankole.Attrs.get(slice, :cumulative_from_json)

      cond do
        not is_nil(other_exclude) ->
          other_slice_filter(field, fields, bucket, cumulative_from, other_exclude, params)

        not is_nil(bucket) ->
          bucket_slice_filter(field, fields, bucket, cumulative_from, slice, params)

        not is_nil(cumulative_from) ->
          cumulative_scalar_filter(field, fields, cumulative_from, slice, params)

        true ->
          exact_or_empty_slice_filter(field, fields, slice, params)
      end
    end
  end

  defp normalize_bucket(nil), do: {:ok, nil}

  defp normalize_bucket(bucket) when is_atom(bucket),
    do: normalize_bucket(Atom.to_string(bucket))

  defp normalize_bucket(bucket) when is_map_key(@bucket_formats, bucket),
    do: {:ok, bucket}

  defp normalize_bucket(_bucket), do: {:error, :invalid_query}

  defp extract_other_exclude(slice) do
    raw =
      case Ankole.Attrs.get(slice, :other_exclude_values_json) do
        nil -> Ankole.Attrs.get(slice, :other_exclude_json)
        val -> val
      end

    cond do
      is_nil(raw) -> {:ok, nil}
      is_list(raw) and Enum.all?(raw, &is_binary/1) -> {:ok, raw}
      true -> {:error, :invalid_query}
    end
  end

  defp other_slice_filter(field, fields, bucket, nil, excluded_jsons, params) do
    with {:ok, expr, type, params} <- expression(field, fields, params),
         true <- is_nil(bucket) or type == :datetime,
         {:ok, canonical_jsons} <- canonical_excluded_jsons(field, type, bucket, excluded_jsons) do
      {excluded_param, params} = Formula.bind(params, canonical_jsons)

      if type == :array do
        array_expr = array_elements_source(expr)

        sql =
          "EXISTS (SELECT 1 FROM jsonb_array_elements(#{array_expr}) AS group_element(value) WHERE group_element.value IS NOT NULL AND group_element.value <> 'null'::jsonb AND NOT (group_element.value = ANY(SELECT excluded_item::jsonb FROM unnest(#{excluded_param}::text[]) AS excluded_item)))"

        {:ok, sql, params}
      else
        {group_expr, params} = scalar_group_expression(expr, type, bucket, params)

        sql =
          "(#{group_expr}) IS NOT NULL AND NOT (to_jsonb(#{group_expr}) = ANY(SELECT excluded_item::jsonb FROM unnest(#{excluded_param}::text[]) AS excluded_item))"

        {:ok, sql, params}
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp other_slice_filter(_field, _fields, _bucket, _cumulative_from, _excluded, _params),
    do: {:error, :invalid_query}

  defp canonical_excluded_jsons(field, type, bucket, excluded_jsons) do
    Enum.reduce_while(excluded_jsons, {:ok, []}, fn raw_json, {:ok, acc} ->
      with {:ok, decoded} <- Torque.decode(raw_json),
           {:ok, canonical} <-
             if(is_nil(bucket) and not is_nil(decoded),
               do: group_json(field, type, decoded, raw_json),
               else: {:ok, raw_json}
             ) do
        {:cont, {:ok, [canonical | acc]}}
      else
        _ -> {:halt, {:error, :invalid_query}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp scalar_group_expression(expr, _type, bucket, params) when not is_nil(bucket),
    do: bucket_expression(expr, bucket, params)

  defp scalar_group_expression(expr, :datetime, nil, params),
    do: {utc_timestamp("(#{expr})::timestamptz"), params}

  defp scalar_group_expression(expr, _type, nil, params), do: {expr, params}

  defp bucket_slice_filter(field, fields, bucket, cumulative_from, slice, params) do
    with {:ok, expr, :datetime, params} <- expression(field, fields, params),
         {:ok, target} <- slice_target_value(slice) do
      {bucket_expr, params} = bucket_expression(expr, bucket, params)
      bucket_target_sql(bucket_expr, target, cumulative_from, params)
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp bucket_target_sql(bucket_expr, nil, nil, params),
    do: {:ok, "(#{bucket_expr}) IS NULL", params}

  defp bucket_target_sql(bucket_expr, target, nil, params) when is_binary(target) do
    {target_param, params} = Formula.bind(params, target)
    {:ok, "(#{bucket_expr}) = #{target_param}::text", params}
  end

  defp bucket_target_sql(bucket_expr, target, cumulative_from, params)
       when is_binary(target) and is_binary(cumulative_from) do
    case Torque.decode(cumulative_from) do
      {:ok, from_bucket} when is_binary(from_bucket) ->
        {from_param, params} = Formula.bind(params, from_bucket)
        {target_param, params} = Formula.bind(params, target)

        {:ok,
         "(#{bucket_expr}) IS NOT NULL AND (#{bucket_expr}) >= #{from_param}::text AND (#{bucket_expr}) <= #{target_param}::text",
         params}

      _ ->
        {:error, :invalid_query}
    end
  end

  defp bucket_target_sql(_bucket_expr, _target, _cumulative_from, _params),
    do: {:error, :invalid_query}

  defp cumulative_scalar_filter(field, fields, cumulative_from, slice, params)
       when is_binary(cumulative_from) do
    with {:ok, from_val} when not is_nil(from_val) <- Torque.decode(cumulative_from),
         {:ok, target_val} when not is_nil(target_val) <- slice_target_value(slice),
         {:ok, _expr, type, _} when type in [:number, :text, :datetime] <-
           expression(field, fields, params),
         {:ok, gte_sql, params} <- typed_condition(field, fields, "gte", from_val, params),
         {:ok, lte_sql, params} <- typed_condition(field, fields, "lte", target_val, params) do
      {:ok, "(#{gte_sql}) AND (#{lte_sql})", params}
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp cumulative_scalar_filter(_field, _fields, _cumulative_from, _slice, _params),
    do: {:error, :invalid_query}

  defp slice_target_value(slice) do
    case Ankole.Attrs.get(slice, :value_json) do
      nil ->
        {:ok, Ankole.Attrs.get(slice, :value)}

      json when is_binary(json) ->
        case Torque.decode(json) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:error, :invalid_query}
        end

      _ ->
        {:error, :invalid_query}
    end
  end

  defp exact_or_empty_slice_filter(field, fields, slice, params) do
    value = Ankole.Attrs.get(slice, :value)
    json = Ankole.Attrs.get(slice, :value_json)

    cond do
      is_binary(json) ->
        exact_group_filter(field, fields, json, params)

      not is_nil(json) ->
        {:error, :invalid_query}

      is_nil(value) ->
        typed_condition(field, fields, "is_empty", nil, params)

      true ->
        exact_group_filter(field, fields, Torque.encode!(value), params)
    end
  end

  defp exact_group_filter(field, fields, json, params) do
    with {:ok, expr, type, params} <- expression(field, fields, params),
         expr = if(type == :datetime, do: utc_timestamp("(#{expr})::timestamptz"), else: expr),
         {:ok, value} <- Torque.decode(json),
         {:ok, json} <- group_json(field, type, value, json) do
      {param, params} = Formula.bind(params, json)

      sql =
        if type == :array,
          do:
            "#{expr} @> jsonb_build_array(#{param}::text::jsonb) AND EXISTS (SELECT 1 FROM jsonb_array_elements(#{array_elements_source(expr)}) AS group_element(value) WHERE group_element.value = #{param}::text::jsonb)",
          else: "to_jsonb(#{expr}) = #{param}::text::jsonb"

      {:ok, "(#{param}::text::jsonb = 'null'::jsonb AND #{expr} IS NULL) OR (#{sql})", params}
    else
      _ -> {:error, :invalid_query}
    end
  end

  @doc "Reports whether an aggregate request reads linked tables through a `path`."
  def linked?(attrs) when is_map(attrs) do
    conditions =
      case Ankole.Attrs.get(attrs, :filter) do
        %{} = filter -> List.wrap(Ankole.Attrs.get(filter, :conditions))
        _ -> []
      end

    (List.wrap(Ankole.Attrs.get(attrs, :group_by)) ++
       List.wrap(Ankole.Attrs.get(attrs, :metrics)) ++ conditions)
    |> Enum.any?(&(is_map(&1) and not is_nil(Ankole.Attrs.get(&1, :path))))
  end

  def linked?(_attrs), do: false

  def aggregate(table, fields, attrs, opts \\ []) do
    fields = Physical.fields(table, fields)
    links = link_context(table, fields, Keyword.get(opts, :tables, %{}))
    groups = Ankole.Attrs.get(attrs, :group_by, [])
    metrics = Ankole.Attrs.get(attrs, :metrics, [%{"operation" => "count", "alias" => "count"}])

    with true <-
           is_list(groups) and length(groups) <= 2 and is_list(metrics) and
             length(metrics) in 1..20 and Enum.all?(groups ++ metrics, &is_map/1),
         {:ok, where, {params, filter_tables}} <-
           combine(
             Ankole.Attrs.get(attrs, :filter),
             {[Repo.tenant_id!(), table.id], []},
             &aggregate_condition(links, &1, &2)
           ),
         {:ok, omit_empty} <- parse_omit_empty(attrs),
         {:ok, group_specs, params, lateral} <- prepare_groups(links, groups, params),
         {:ok, metric_specs, params} <- prepare_metrics(links, metrics, params),
         {:ok, order_by} <-
           prepare_order_by(Ankole.Attrs.get(attrs, :order_by), group_specs, metric_specs),
         {:ok, top_n} <- prepare_top_n(Ankole.Attrs.get(attrs, :top_n), group_specs),
         linked = filter_tables ++ Enum.flat_map(group_specs ++ metric_specs, & &1.tables),
         {:ok, data_versions} <- data_versions(links, linked) do
      aliases = Enum.map(metric_specs, & &1.alias)

      case execute_aggregate(
             table,
             where,
             omit_empty,
             group_specs,
             link_joins(linked, metric_specs) <> lateral,
             metric_specs,
             order_by,
             top_n,
             Keyword.fetch!(opts, :max_groups),
             params
           ) do
        {:ok, result} ->
          {:ok,
           %{
             groups:
               Enum.map(result.rows, fn [values, value_json, other, metric_vals, metric_texts] ->
                 %{
                   values: values,
                   value_json: value_json,
                   other: other,
                   metrics: Map.new(Enum.zip(aliases, metric_vals)),
                   metrics_text: Map.new(Enum.zip(aliases, metric_texts))
                 }
               end),
             data_version: table.data_version,
             data_versions: data_versions
           }}

        _ ->
          {:error, :invalid_query}
      end
    else
      false -> {:error, :query_limit}
      error -> error
    end
  end

  # Linked tables share the Base's physical shard, and the caller locked their metadata.
  defp link_context(table, fields, tables) do
    tables =
      Map.new(tables, fn {id, {linked, linked_fields}} ->
        {id, %{table: linked, fields: Physical.fields(linked, linked_fields)}}
      end)

    %{root: table.id, tables: Map.put(tables, table.id, %{table: table, fields: fields})}
  end

  defp root_fields(links), do: links.tables[links.root].fields

  defp data_versions(links, ids) do
    linked = for id <- Enum.uniq(ids), id != links.root, do: links.tables[id].table

    with {:ok, tables} <- Physical.refresh(linked),
         do: {:ok, Map.new([links.tables[links.root].table | tables], &{&1.id, &1.data_version})}
  end

  # Path subqueries alias their own target table as `r`, so they reach the
  # outer record through `link_root`.
  defp link_joins([], _metric_specs), do: ""

  defp link_joins(_linked, metric_specs),
    do:
      " CROSS JOIN LATERAL (SELECT r.id AS id) AS link_root" <>
        Enum.map_join(metric_specs, &Map.get(&1, :join, ""))

  defp aggregate_condition(links, attrs, {params, tables}) do
    operator = Ankole.Attrs.get(attrs, :operator)

    case Ankole.Attrs.get(attrs, :path) do
      nil when operator in ["exists", "not_exists"] ->
        {:error, {:invalid_link_path, %{reason: "path_required"}}}

      nil ->
        with {:ok, sql, params} <- condition(root_fields(links), attrs, params),
             do: {:ok, sql, {params, tables}}

      path ->
        with {:ok, link} <- resolve_path(links, path),
             {:ok, sql, params} <-
               link_condition(link.fields, operator, Map.drop(attrs, [:path, "path"]), params) do
          exists =
            "EXISTS (SELECT 1 FROM #{link.source} WHERE #{link.parent}=link_root.id AND #{sql})"

          {:ok, if(operator == "not_exists", do: "NOT " <> exists, else: exists),
           {params, tables ++ link.tables}}
        end
    end
  end

  defp link_condition(fields, operator, attrs, params) when operator in ["exists", "not_exists"],
    do: filter(fields, Ankole.Attrs.get(attrs, :filter), params)

  defp link_condition(fields, _operator, attrs, params), do: condition(fields, attrs, params)

  # Resolves declared link fields hop by hop. `parent` and `child` name the
  # edge columns that hold the starting and the reached record IDs.
  defp resolve_path(links, path) when is_list(path) and path != [] and length(path) <= 3 do
    path
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, %{target: links.root, tables: [], joins: [], parent: nil, child: nil, single?: true}},
      fn {id, index}, {:ok, link} ->
        case link_hop(links.tables, link.target, id) do
          {:ok, field, target} ->
            {own, peer} = Links.roles(field)
            edge = "#{BaseRepo.edge(field.config["edge_table"])} e#{index}"

            {:cont,
             {:ok,
              %{
                link
                | target: target,
                  tables: [link.target, target | link.tables],
                  joins: [
                    if(index == 0,
                      do: edge,
                      else: "JOIN #{edge} ON e#{index}.#{own}_id=#{link.child}"
                    )
                    | link.joins
                  ],
                  parent: link.parent || "e0.#{own}_id",
                  child: "e#{index}.#{peer}_id",
                  single?: link.single? and field.config["multiple"] == false
              }}}

          error ->
            {:halt, error}
        end
      end
    )
    |> case do
      {:ok, link} ->
        edges = link.joins |> Enum.reverse() |> Enum.join(" ")
        target = links.tables[link.target]

        {:ok,
         Map.merge(link, %{
           edges: edges,
           fields: target.fields,
           table: target.table,
           source: "#{edges} JOIN #{source(target.table)} r ON r.id=#{link.child}"
         })}

      error ->
        error
    end
  end

  defp resolve_path(_links, path),
    do: {:error, {:invalid_link_path, %{path: path, reason: "invalid_path"}}}

  defp link_hop(tables, table_id, id) do
    case Enum.find(tables[table_id].fields, &(&1.id == id)) do
      %{type: :link, config: %{"table_id" => target, "edge_table" => _, "edge_role" => _}} =
          field
      when is_map_key(tables, target) ->
        {:ok, field, target}

      nil ->
        {:error, {:invalid_link_path, %{field_id: id, reason: "unknown_field"}}}

      _field ->
        {:error, {:invalid_link_path, %{field_id: id, reason: "not_link"}}}
    end
  end

  defp condition(fields, attrs, params) do
    if is_nil(Ankole.Attrs.get(attrs, :path)),
      do: plain_condition(fields, attrs, params),
      else: {:error, {:invalid_link_path, %{reason: "nested_path"}}}
  end

  defp plain_condition(fields, attrs, params) do
    with {:ok, field} <- field(fields, Ankole.Attrs.get(attrs, :field_id)),
         op <- Ankole.Attrs.get(attrs, :operator),
         {:ok, value} <- condition_value(field, op, Ankole.Attrs.get(attrs, :value)) do
      stored =
        Map.get(field, :storage_mode) != :physical and field.type != :formula and
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

  defp condition_value(%{type: kind}, op, value)
       when kind in [:created_by, :updated_by, "created_by", "updated_by"] and
              op in ["is", "gt", "gte", "lt", "lte"] and is_binary(value),
       do: {:ok, actor_ref_string(value)}

  defp condition_value(_field, _operator, value), do: {:ok, value}

  defp group_json(_field, :datetime, value, _json) when not is_nil(value) do
    with {:ok, value} <- datetime_value(value), do: {:ok, Torque.encode!(value)}
  end

  defp group_json(%{type: kind}, _type, value, _json)
       when kind in [:created_by, :updated_by, "created_by", "updated_by"] and is_binary(value),
       do: {:ok, Torque.encode!(actor_ref_string(value))}

  defp group_json(_field, _type, _value, json), do: {:ok, json}

  defp actor_ref_string("ankole:" <> rest = value) do
    with [tenant_id, raw_uid] <- String.split(rest, ":principal/", parts: 2),
         {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         {:ok, uid} <- Ankole.PrincipalKey.normalize(raw_uid) do
      to_string(%Ankole.ActorRef{tenant_id: tenant_id, uid: uid})
    else
      _ -> value
    end
  end

  defp actor_ref_string(value) do
    case Ankole.PrincipalKey.normalize(value) do
      {:ok, uid} -> to_string(%Ankole.ActorRef{tenant_id: Repo.tenant_id!(), uid: uid})
      _ -> value
    end
  end

  defp datetime_value(nil), do: {:ok, nil}

  defp datetime_value(value) do
    with {:ok, canonical} when is_binary(canonical) <- Values.cast(%{type: :datetime}, value, nil),
         do: {:ok, canonical},
         else: (_ -> {:error, :invalid_query})
  end

  defp typed_condition(field, fields, op, value, params) do
    with {:ok, expr, type, params} <- expression(field, fields, params) do
      expr = datetime_expression(expr, type)

      expr =
        if type == :text and op != "text_contains",
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

        op == "contains" and type == :array ->
          {param, params} = Formula.bind(params, Torque.encode!(value))
          {:ok, "#{expr} @> jsonb_build_array(#{param}::text::jsonb)", params}

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
      direction =
        if is_map(attrs), do: normalize_string(Ankole.Attrs.get(attrs, :direction, "asc"))

      with true <- direction in ["asc", "desc"],
           {:ok, field} <- field(fields, Ankole.Attrs.get(attrs, :field_id)),
           {:ok, expr, type, params} <- expression(field, fields, params) do
        expr =
          if type == :text, do: "#{expr} COLLATE \"C\"", else: datetime_expression(expr, type)

        {:cont,
         {:ok, [%{sql: expr, type: type, direction: String.upcase(direction)} | order], params}}
      else
        _ -> {:halt, {:error, :invalid_query}}
      end
    end)
    |> reverse_values()
  end

  defp sort(_, _, _), do: {:error, :invalid_query}

  defp projection(fields, params, selected_ids \\ nil) do
    fields
    |> Enum.filter(&(&1.type == :formula and (is_nil(selected_ids) or &1.id in selected_ids)))
    |> Enum.reduce_while({:ok, "'{}'::jsonb", params}, fn field, {:ok, sql, params} ->
      with {:ok, expr, _type, params} <- expression(field, fields, params) do
        {key, params} = Formula.bind(params, field.id)
        {:cont, {:ok, sql <> " || jsonb_build_object(#{key}::text, #{expr})", params}}
      else
        error -> {:halt, error}
      end
    end)
  end

  @doc "Formats a table's display field as SQL text for link flattening and record search."
  def display_label_sql(primary, fields, params, opts \\ []) do
    with {:ok, sql, _value_type, params} <-
           display_label_sql_with_type(primary, fields, params, opts) do
      {:ok, sql, params}
    end
  end

  defp display_label_sql_with_type(primary, fields, params, opts) do
    with {:ok, expr, value_type, params} <- Formula.expression(primary, fields, params) do
      array_expr =
        "(SELECT CASE WHEN jsonb_typeof(_raw.v) = 'array' THEN _raw.v ELSE '[]'::jsonb END FROM (SELECT #{expr} AS v) _raw)"

      principal_names = Keyword.get(opts, :principal_names)

      cond do
        primary.type == :select ->
          options_json =
            Torque.encode!(Map.new(primary.config["options"] || [], &{&1["id"], &1["name"]}))

          {opts_param, params} = Formula.bind(params, options_json)

          sql =
            if value_type == :array do
              "(SELECT string_agg(COALESCE((#{opts_param}::text::jsonb)->>opt.id, opt.id), ', ' ORDER BY opt.pos) FROM jsonb_array_elements_text(#{array_expr}) WITH ORDINALITY AS opt(id, pos))"
            else
              "(SELECT CASE WHEN _raw.v IS NULL THEN NULL ELSE COALESCE((#{opts_param}::text::jsonb)->>(_raw.v), (_raw.v)::text) END FROM (SELECT #{expr} AS v) _raw)"
            end

          {:ok, sql, value_type, params}

        primary.type == :attachment ->
          {:ok,
           "(SELECT string_agg(NULLIF(att.item->>'name', ''), ', ' ORDER BY att.pos) FROM jsonb_array_elements(#{array_expr}) WITH ORDINALITY AS att(item, pos))",
           value_type, params}

        primary.type == :user and is_map(principal_names) ->
          {names_param, params} = Formula.bind(params, Torque.encode!(principal_names))

          uid_sql =
            "lower(btrim(COALESCE(NULLIF(split_part(elem.val, ':principal/', 2), ''), elem.val)))"

          {:ok,
           "(SELECT string_agg(COALESCE((#{names_param}::text::jsonb)->>(#{uid_sql}), #{uid_sql}), ', ' ORDER BY elem.pos) FROM jsonb_array_elements_text(#{array_expr}) WITH ORDINALITY AS elem(val, pos))",
           value_type, params}

        primary.type == :user ->
          {:ok,
           "(SELECT string_agg(COALESCE(NULLIF(split_part(elem.val, ':principal/', 2), ''), elem.val), ', ' ORDER BY elem.pos) FROM jsonb_array_elements_text(#{array_expr}) WITH ORDINALITY AS elem(val, pos))",
           value_type, params}

        primary.type == :link ->
          {:ok,
           "(SELECT string_agg('#' || right(elem.val, 6), ', ' ORDER BY elem.pos) FROM jsonb_array_elements_text(#{array_expr}) WITH ORDINALITY AS elem(val, pos))",
           value_type, params}

        value_type == :array ->
          {:ok,
           "(SELECT string_agg(elem.val, ', ' ORDER BY elem.pos) FROM jsonb_array_elements_text(#{array_expr}) WITH ORDINALITY AS elem(val, pos))",
           value_type, params}

        primary.type in [:created_by, :updated_by] and is_map(principal_names) ->
          {names_param, params} = Formula.bind(params, Torque.encode!(principal_names))

          {:ok,
           "(SELECT CASE WHEN _raw.v IS NULL OR _raw.v = '' THEN NULL ELSE COALESCE((#{names_param}::text::jsonb)->>(_u.uid), _u.uid) END FROM (SELECT (#{expr})::text AS v) _raw, LATERAL (SELECT lower(btrim(COALESCE(NULLIF(split_part(_raw.v, ':principal/', 2), ''), _raw.v))) AS uid) _u)",
           value_type, params}

        primary.type in [:created_by, :updated_by] ->
          {:ok,
           "(SELECT COALESCE(NULLIF(split_part(_raw.v, ':principal/', 2), ''), _raw.v) FROM (SELECT (#{expr})::text AS v) _raw)",
           value_type, params}

        true ->
          {:ok, "(#{expr})::text", value_type, params}
      end
    end
  end

  defp search_filter(_fields, search, params, _opts) when search in [nil, ""],
    do: {:ok, "TRUE", params}

  defp search_filter(fields, search, params, opts) when is_binary(search) do
    {param, params} = Formula.bind(params, "%" <> Repo.escape_like(search) <> "%")
    fallback = "'#' || right(r.id::text, 6)"

    case Enum.find(fields, & &1.is_primary) || List.first(fields) do
      nil ->
        {:ok, "(#{fallback}) ILIKE #{param}::text", params}

      %{type: :checkbox} = primary ->
        with {:ok, expr, _type, params} <- Formula.expression(primary, fields, params) do
          haystack =
            "(SELECT CASE WHEN _raw.v IS NULL THEN #{fallback} WHEN _raw.v THEN '✓ true' ELSE '— false' END FROM (SELECT #{expr} AS v) _raw)"

          {:ok, "(#{haystack}) ILIKE #{param}::text", params}
        end

      primary ->
        with {:ok, label_sql, value_type, params} <-
               display_label_sql_with_type(primary, fields, params, opts) do
          haystack =
            if value_type == :datetime do
              formatted =
                "to_char((_lbl.val)::timestamptz, 'YYYY-MM-DD HH24:MI:SS FMMonth FMDD, YYYY FMMon FMDD, YYYY, FMHH12:MI:SS AM YYYY/MM/DD YYYY/FMMM/FMDD YYYY. FMMM. FMDD. YYYY\"年\"FMMM\"月\"FMDD\"日\"')"

              "(SELECT CASE WHEN _lbl.val IS NULL OR _lbl.val = '' THEN #{fallback} ELSE (_lbl.val || ' ' || #{formatted}) END FROM (SELECT #{label_sql} AS val) _lbl)"
            else
              "COALESCE(NULLIF(#{label_sql}, ''), #{fallback})"
            end

          {:ok, "(#{haystack}) ILIKE #{param}::text", params}
        end
    end
  end

  defp search_filter(_fields, _search, _params, _opts), do: {:error, :invalid_query}

  defp ids(nil, params), do: {:ok, "TRUE", params}

  defp ids(ids, params) when is_list(ids) do
    ids = Enum.uniq(ids)

    if length(ids) <= Ankole.Pod.BaseTable.record_limit() and
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

  defp encode_cursor(table, attrs, [record, values]) when is_binary(record),
    do: encode_cursor(table, attrs, [Torque.decode!(record), values])

  defp encode_cursor(table, attrs, [record, values]),
    do:
      Phoenix.Token.sign(AnkoleWeb.Endpoint, "pod-table-cursor", %{
        table_id: table.id,
        query: fingerprint(attrs),
        id: record["id"],
        values: values
      })

  defp fingerprint(attrs) do
    slices =
      case normalize_group_slices(attrs) do
        {:ok, list} -> list
        _ -> {Ankole.Attrs.get(attrs, :group), Ankole.Attrs.get(attrs, :groups)}
      end

    search =
      case Ankole.Attrs.get(attrs, :search) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {Ankole.Attrs.get(attrs, :sort, []), Ankole.Attrs.get(attrs, :filter),
         Ankole.Attrs.get(attrs, :ids), slices, search},
        [:deterministic]
      )
    )
  end

  defp parse_omit_empty(attrs) do
    case Ankole.Attrs.get(attrs, :omit_empty) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :invalid_query}
    end
  end

  defp prepare_groups(links, groups, params) do
    Enum.with_index(groups)
    |> Enum.reduce_while({:ok, [], params, ""}, fn {attrs, index},
                                                   {:ok, specs, params, lateral} ->
      case prepare_group_dimension(links, attrs, index, params, lateral) do
        {:ok, spec, params, lateral} -> {:cont, {:ok, [spec | specs], params, lateral}}
        error -> {:halt, error}
      end
    end)
    |> reverse_values()
  end

  defp prepare_group_dimension(links, attrs, index, params, lateral) do
    with {:ok, expr, type, tables, params} <- dimension(links, attrs, params),
         {:ok, bucket} <- normalize_bucket(Ankole.Attrs.get(attrs, :bucket)),
         {:ok, spec, params, lateral} <-
           build_group_spec(expr, type, bucket, index, params, lateral),
         do: {:ok, Map.put(spec, :tables, tables), params, lateral}
  end

  defp dimension(links, attrs, params) do
    case Ankole.Attrs.get(attrs, :path) do
      nil ->
        fields = root_fields(links)

        with {:ok, field} <- field(fields, Ankole.Attrs.get(attrs, :field_id)),
             {:ok, expr, type, params} <- expression(field, fields, params),
             do: {:ok, expr, type, [], params}

      path ->
        # Only single-value hops keep one dimension value per record.
        with {:ok, %{single?: true} = link} <- resolve_path(links, path),
             {:ok, field} <- field(link.fields, Ankole.Attrs.get(attrs, :field_id)),
             {:ok, expr, type, params} <- expression(field, link.fields, params) do
          {:ok, "(SELECT #{expr} FROM #{link.source} WHERE #{link.parent}=link_root.id)", type,
           link.tables, params}
        else
          {:ok, _link} ->
            {:error, {:invalid_link_path, %{path: path, reason: "multi_value_dimension"}}}

          error ->
            error
        end
    end
  end

  defp build_group_spec(expr, :array, nil, index, params, lateral) do
    name = "group_value_#{index}"
    array_expr = array_elements_source(expr)

    spec = %{
      index: index,
      source_type: :array,
      value_type: :array,
      sql: "(CASE WHEN #{name}.value = 'null'::jsonb THEN NULL ELSE #{name}.value END)"
    }

    {:ok, spec, params,
     lateral <>
       " LEFT JOIN LATERAL jsonb_array_elements(#{array_expr}) AS #{name}(value) ON TRUE "}
  end

  defp build_group_spec(expr, :datetime, bucket, index, params, lateral)
       when not is_nil(bucket) do
    {bucket_sql, params} = bucket_expression(expr, bucket, params)

    spec = %{
      index: index,
      source_type: :datetime,
      value_type: :text,
      sql: "(#{bucket_sql} COLLATE \"C\")"
    }

    {:ok, spec, params, lateral}
  end

  defp build_group_spec(expr, type, nil, index, params, lateral) when type != :array do
    {sql, value_type} =
      case type do
        :datetime -> {"(#{utc_timestamp("(#{expr})::timestamptz")} COLLATE \"C\")", :text}
        :text -> {"(#{expr} COLLATE \"C\")", :text}
        _ -> {expr, type}
      end

    {:ok, %{index: index, source_type: type, value_type: value_type, sql: sql}, params, lateral}
  end

  defp build_group_spec(_expr, _type, _bucket, _index, _params, _lateral),
    do: {:error, :invalid_query}

  defp bucket_expression(expr, bucket, params) do
    {bucket_param, params} = Formula.bind(params, bucket)
    {format_param, params} = Formula.bind(params, Map.fetch!(@bucket_formats, bucket))

    sql =
      "to_char(date_trunc(#{bucket_param}::text, (#{expr})::timestamptz), #{format_param}::text)"

    {sql, params}
  end

  defp array_elements_source(expr),
    do: "CASE WHEN jsonb_typeof(#{expr}) = 'array' THEN #{expr} ELSE '[]'::jsonb END"

  defp prepare_metrics(links, metrics, params) do
    Enum.with_index(metrics)
    |> Enum.reduce_while({:ok, [], params}, fn {attrs, index}, {:ok, specs, params} ->
      case prepare_metric(links, attrs, index, params) do
        {:ok, spec, params} -> {:cont, {:ok, [Map.put_new(spec, :tables, []) | specs], params}}
        error -> {:halt, error}
      end
    end)
    |> reverse_values()
  end

  defp prepare_metric(links, attrs, index, params) do
    operation = normalize_string(Ankole.Attrs.get(attrs, :operation))
    alias_name = normalize_string(Ankole.Attrs.get(attrs, :alias, operation))
    path = Ankole.Attrs.get(attrs, :path)

    cond do
      not is_binary(alias_name) or alias_name == "" ->
        {:error, :invalid_query}

      not is_nil(path) ->
        prepare_link_metric(links, attrs, path, index, operation, alias_name, params)

      not is_nil(Ankole.Attrs.get(attrs, :filter)) ->
        {:error, :invalid_query}

      operation == "count" and is_nil(Ankole.Attrs.get(attrs, :field_id)) ->
        {:ok,
         %{
           index: index,
           alias: alias_name,
           operation: "count",
           input_sql: nil,
           agg_sql: "count(*)"
         }, params}

      operation in ["count", "count_distinct", "sum", "avg", "min", "max"] ->
        prepare_field_metric(root_fields(links), attrs, index, operation, alias_name, params)

      true ->
        {:error, :invalid_query}
    end
  end

  defp prepare_field_metric(fields, attrs, index, operation, alias_name, params) do
    with {:ok, field} <- field(fields, Ankole.Attrs.get(attrs, :field_id)),
         {:ok, expr, type, params} <- expression(field, fields, params),
         true <- valid_metric_type?(operation, type) do
      input_sql = metric_input_sql(expr, type)
      col = "m_#{index}"

      agg_sql =
        cond do
          operation == "count_distinct" and type == :text ->
            "count(distinct (#{col} COLLATE \"C\"))"

          operation == "count_distinct" ->
            "count(distinct #{col})"

          operation in ["min", "max"] and type == :text ->
            "#{operation}(#{col} COLLATE \"C\")"

          true ->
            "#{operation}(#{col})"
        end

      {:ok,
       %{
         index: index,
         alias: alias_name,
         operation: operation,
         input_sql: input_sql,
         agg_sql: agg_sql
       }, params}
    else
      _ -> {:error, :invalid_query}
    end
  end

  # Each linked record reached through the path is aggregated once per parent
  # record before the join, so a parent's own values are never repeated per child.
  defp prepare_link_metric(links, attrs, path, index, operation, alias_name, params) do
    name = "link_metric_#{index}"
    col = "m_#{index}"

    with true <-
           operation in ["count", "sum", "avg", "min", "max"] or
             {:error, {:invalid_link_path, %{path: path, reason: "unsupported_operation"}}},
         {:ok, link} <- resolve_path(links, path),
         {:ok, input, params} <-
           link_metric_input(link.fields, Ankole.Attrs.get(attrs, :field_id), operation, params),
         {:ok, where, params} <- filter(link.fields, Ankole.Attrs.get(attrs, :filter), params) do
      {child_sql, agg_sql} = link_metric_sql(operation, input, col)

      {:ok,
       %{
         index: index,
         alias: alias_name,
         operation: operation,
         input_sql: "#{name}.value",
         extra: if(operation == "avg", do: [{"#{name}.n", "#{col}_n"}], else: []),
         agg_sql: agg_sql,
         tables: link.tables,
         cte:
           "#{name} AS (SELECT pairs.parent_id, #{child_sql} FROM (SELECT DISTINCT #{link.parent} AS parent_id, #{link.child} AS child_id FROM #{link.edges}) pairs JOIN #{source(link.table)} r ON r.id=pairs.child_id WHERE #{where} GROUP BY pairs.parent_id)",
         join: " LEFT JOIN #{name} ON #{name}.parent_id=r.id"
       }, params}
    end
  end

  defp link_metric_input(_fields, nil, "count", params), do: {:ok, nil, params}

  defp link_metric_input(fields, field_id, operation, params) do
    with {:ok, field} <- field(fields, field_id),
         {:ok, expr, type, params} <- expression(field, fields, params),
         true <- valid_metric_type?(operation, type) or {:error, :invalid_query},
         do: {:ok, {metric_input_sql(expr, type), type}, params}
  end

  defp link_metric_sql("count", nil, col),
    do: {"count(*) AS value", "COALESCE(sum(#{col}), 0)::bigint"}

  defp link_metric_sql("count", {input, _type}, col),
    do: {"count(#{input}) AS value", "COALESCE(sum(#{col}), 0)::bigint"}

  defp link_metric_sql("avg", {input, _type}, col),
    do:
      {"sum(#{input}) AS value, count(#{input}) AS n", "(sum(#{col}) / NULLIF(sum(#{col}_n), 0))"}

  defp link_metric_sql(operation, {input, :text}, col) when operation in ["min", "max"],
    do: {"#{operation}(#{input}) AS value", "#{operation}(#{col} COLLATE \"C\")"}

  defp link_metric_sql(operation, {input, _type}, col),
    do: {"#{operation}(#{input}) AS value", "#{operation}(#{col})"}

  defp metric_columns(spec) do
    if(spec.input_sql, do: [{spec.input_sql, "m_#{spec.index}"}], else: []) ++
      Map.get(spec, :extra, [])
  end

  defp valid_metric_type?(op, _type) when op in ["count", "count_distinct"], do: true
  defp valid_metric_type?(op, :number) when op in ["sum", "avg"], do: true

  defp valid_metric_type?(op, type) when op in ["min", "max"],
    do: type in [:number, :text, :datetime]

  defp valid_metric_type?(_op, _type), do: false

  defp metric_input_sql(expr, :text), do: "(#{expr} COLLATE \"C\")"
  defp metric_input_sql(expr, :datetime), do: datetime_expression(expr, :datetime)

  defp metric_input_sql(expr, :array),
    do:
      "(CASE WHEN #{expr} IS NULL OR jsonb_typeof(#{expr}) <> 'array' OR #{expr} = '[]'::jsonb THEN NULL ELSE #{expr} END)"

  defp metric_input_sql(expr, _type), do: expr

  defp prepare_order_by(nil, _group_specs, _metric_specs), do: {:ok, []}

  defp prepare_order_by(items, group_specs, metric_specs)
       when is_list(items) and length(items) <= 4 do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case prepare_order_item(item, group_specs, metric_specs) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp prepare_order_by(_invalid, _group_specs, _metric_specs), do: {:error, :invalid_query}

  defp prepare_order_item(item, group_specs, metric_specs) when is_map(item) do
    metric_alias = Ankole.Attrs.get(item, :metric_alias)
    group_index = Ankole.Attrs.get(item, :group_index)
    dir = normalize_string(Ankole.Attrs.get(item, :direction, "asc"))

    cond do
      dir not in ["asc", "desc"] ->
        {:error, :invalid_query}

      is_binary(metric_alias) and is_nil(group_index) ->
        case Enum.find(metric_specs, &(&1.alias == metric_alias)) do
          nil -> {:error, :invalid_query}
          spec -> {:ok, %{kind: :metric, agg_sql: spec.agg_sql, direction: String.upcase(dir)}}
        end

      is_integer(group_index) and is_nil(metric_alias) and group_index >= 0 and
          group_index < length(group_specs) ->
        {:ok, %{kind: :group, group_index: group_index, direction: String.upcase(dir)}}

      true ->
        {:error, :invalid_query}
    end
  end

  defp prepare_order_item(_invalid, _group_specs, _metric_specs), do: {:error, :invalid_query}

  defp prepare_top_n(nil, _group_specs), do: {:ok, nil}

  defp prepare_top_n(top_n, group_specs) when is_map(top_n) and group_specs != [] do
    limit = Ankole.Attrs.get(top_n, :limit)

    include_other =
      case Ankole.Attrs.get(top_n, :include_other) do
        nil -> Ankole.Attrs.get(top_n, :include_other?, true)
        val -> val
      end

    default_target = if length(group_specs) == 2, do: 1, else: 0

    target_idx =
      case Ankole.Attrs.get(top_n, :target_group_index) do
        nil -> default_target
        val -> val
      end

    if is_integer(limit) and limit in 1..100 and is_boolean(include_other) and
         is_integer(target_idx) and target_idx >= 0 and target_idx < length(group_specs) do
      {:ok, %{limit: limit, include_other: include_other, target_group_index: target_idx}}
    else
      {:error, :invalid_query}
    end
  end

  defp prepare_top_n(_invalid, _group_specs), do: {:error, :invalid_query}

  defp execute_aggregate(
         table,
         where,
         omit_empty,
         group_specs,
         lateral,
         metric_specs,
         order_by,
         top_n,
         max_groups,
         params
       ) do
    projected =
      ["r.id AS __row_id"] ++
        Enum.map(group_specs, &"#{&1.sql} AS g#{&1.index}") ++
        for(spec <- metric_specs, {sql, col} <- metric_columns(spec), do: "#{sql} AS #{col}")

    raw_sql =
      "SELECT #{Enum.join(projected, ", ")} FROM #{source(table)} r #{lateral} WHERE #{scope(table)} AND (#{where})"

    {raw_cte_name, extra_base_ctes} =
      if omit_empty and group_specs != [] do
        non_null = Enum.map_join(group_specs, " AND ", &"g#{&1.index} IS NOT NULL")
        {"raw_base", ["base_rows AS (SELECT * FROM raw_base WHERE #{non_null})"]}
      else
        {"base_rows", []}
      end

    {fold_ctes, from_table, group_by_sql, other_array_sql, order_sql, params} =
      build_folding_plan(group_specs, metric_specs, order_by, top_n, params)

    tail_ctes =
      case extra_base_ctes ++ fold_ctes do
        [] -> ""
        ctes -> ", " <> Enum.join(ctes, ", ")
      end

    group_cols = Enum.map_join(group_specs, ", ", &"g#{&1.index}")

    group_jsons =
      Enum.map_join(group_specs, ", ", &"COALESCE(to_jsonb(g#{&1.index})::text, 'null')")

    metric_aggs = Enum.map_join(metric_specs, ", ", & &1.agg_sql)
    metric_texts = Enum.map_join(metric_specs, ", ", &"(#{&1.agg_sql})::text")

    execute(
      table,
      "WITH #{Enum.map_join(metric_specs, &if(&1[:cte], do: &1.cte <> ", ", else: ""))}#{raw_cte_name} AS (#{raw_sql})#{tail_ctes} SELECT jsonb_build_array(#{group_cols}), jsonb_build_array(#{group_jsons}), #{other_array_sql}, jsonb_build_array(#{metric_aggs}), jsonb_build_array(#{metric_texts}) FROM #{from_table}#{group_by_sql}#{order_sql} LIMIT #{max_groups + 1}",
      params
    )
  end

  defp build_folding_plan([], _metric_specs, _order_by, nil, params) do
    {[], "base_rows", "", "'[]'::jsonb", "", params}
  end

  defp build_folding_plan(group_specs, _metric_specs, order_by, nil, params) do
    group_by_sql = " GROUP BY " <> Enum.map_join(group_specs, ", ", &"g#{&1.index}")

    other_array_sql =
      "jsonb_build_array(" <>
        Enum.map_join(group_specs, ", ", fn _ -> "false" end) <> ")"

    order_sql =
      if order_by == [] do
        ""
      else
        clauses =
          Enum.map(order_by, &order_clause_sql(&1, group_specs)) ++
            tie_breaker_clauses(group_specs)

        " ORDER BY " <> Enum.join(clauses, ", ")
      end

    {[], "base_rows", group_by_sql, other_array_sql, order_sql, params}
  end

  defp build_folding_plan(group_specs, metric_specs, order_by, top_n, params) do
    t = top_n.target_group_index
    target_spec = Enum.at(group_specs, t)
    {limit_param, params} = Formula.bind(params, top_n.limit)
    {rank_agg_sql, rank_dir} = ranking_metric(order_by, metric_specs)

    rank_source =
      if Enum.any?(group_specs, &(&1.source_type == :array)) do
        "(SELECT DISTINCT ON (__row_id, g#{t}) * FROM base_rows WHERE g#{t} IS NOT NULL ORDER BY __row_id, g#{t})"
      else
        "(SELECT * FROM base_rows WHERE g#{t} IS NOT NULL)"
      end

    top_keys_cte =
      "top_keys AS (SELECT g#{t} AS top_val FROM #{rank_source} ranked_source GROUP BY g#{t} ORDER BY #{rank_agg_sql} #{rank_dir} NULLS LAST, COALESCE(to_jsonb(g#{t})::text, 'null') COLLATE \"C\" ASC LIMIT #{limit_param}::integer)"

    raw_folded_cte = build_raw_folded_cte(group_specs, metric_specs, top_n)

    {fold_ctes, from_table} =
      if target_spec.source_type == :array do
        dedup_keys = folded_dedup_keys(group_specs, t)

        dedup_cte =
          "folded_rows AS (SELECT DISTINCT ON (#{dedup_keys}) * FROM raw_folded ORDER BY #{dedup_keys})"

        {[top_keys_cte, raw_folded_cte, dedup_cte], "folded_rows"}
      else
        {[top_keys_cte, raw_folded_cte], "raw_folded"}
      end

    group_by_cols =
      Enum.flat_map(group_specs, fn spec ->
        if spec.index == t, do: ["is_other", "g#{t}"], else: ["g#{spec.index}"]
      end)

    other_array_sql =
      "jsonb_build_array(" <>
        Enum.map_join(group_specs, ", ", fn spec ->
          if spec.index == t, do: "is_other", else: "false"
        end) <> ")"

    order_sql =
      " ORDER BY " <>
        Enum.join(top_n_order_clauses(group_specs, order_by, t, rank_agg_sql, rank_dir), ", ")

    {fold_ctes, from_table, " GROUP BY " <> Enum.join(group_by_cols, ", "), other_array_sql,
     order_sql, params}
  end

  defp build_raw_folded_cte(group_specs, metric_specs, %{
         include_other: include_other,
         target_group_index: t
       }) do
    group_projections =
      Enum.flat_map(group_specs, fn spec ->
        if spec.index == t do
          if include_other do
            [
              "CASE WHEN g#{t} IS NULL THEN FALSE WHEN g#{t} IN (SELECT top_val FROM top_keys) THEN FALSE ELSE TRUE END AS is_other",
              "CASE WHEN g#{t} IS NULL THEN NULL WHEN g#{t} IN (SELECT top_val FROM top_keys) THEN g#{t} ELSE NULL END AS g#{t}"
            ]
          else
            ["FALSE AS is_other", "g#{t}"]
          end
        else
          ["g#{spec.index}"]
        end
      end)

    metric_cols = for spec <- metric_specs, {_sql, col} <- metric_columns(spec), do: col

    cols = Enum.join(["__row_id"] ++ group_projections ++ metric_cols, ", ")

    where_tail =
      if include_other,
        do: "",
        else: " WHERE g#{t} IS NULL OR g#{t} IN (SELECT top_val FROM top_keys)"

    "raw_folded AS (SELECT #{cols} FROM base_rows#{where_tail})"
  end

  defp folded_dedup_keys(group_specs, t) do
    non_target =
      for spec <- group_specs, spec.index != t, do: "g#{spec.index}"

    Enum.join(["__row_id"] ++ non_target ++ ["is_other", "g#{t}"], ", ")
  end

  defp ranking_metric(order_by, [first | _]) do
    case Enum.find(order_by, &(&1.kind == :metric)) do
      %{agg_sql: agg_sql, direction: dir} -> {agg_sql, dir}
      nil -> {first.agg_sql, "DESC"}
    end
  end

  defp top_n_order_clauses(group_specs, order_by, t, rank_agg_sql, rank_dir) do
    bucket_rank = "CASE WHEN is_other THEN 1 WHEN g#{t} IS NULL THEN 2 ELSE 0 END ASC"

    if order_by == [] do
      leading =
        for spec <- group_specs, spec.index != t, do: group_order_sql(spec, "ASC")

      leading ++
        [bucket_rank, "#{rank_agg_sql} #{rank_dir} NULLS LAST"] ++
        tie_breaker_clauses(group_specs)
    else
      {non_target, target_or_metric} =
        Enum.split_with(order_by, &match?(%{kind: :group, group_index: idx} when idx != t, &1))

      Enum.map(non_target, &order_clause_sql(&1, group_specs)) ++
        [bucket_rank] ++
        Enum.map(target_or_metric, &order_clause_sql(&1, group_specs)) ++
        tie_breaker_clauses(group_specs)
    end
  end

  defp order_clause_sql(%{kind: :metric, agg_sql: agg_sql, direction: dir}, _group_specs),
    do: "#{agg_sql} #{dir} NULLS LAST"

  defp order_clause_sql(%{kind: :group, group_index: idx, direction: dir}, group_specs),
    do: group_order_sql(Enum.at(group_specs, idx), dir)

  defp group_order_sql(%{index: idx, value_type: :text}, dir),
    do: "(g#{idx} COLLATE \"C\") #{dir} NULLS LAST"

  defp group_order_sql(%{index: idx}, dir),
    do: "g#{idx} #{dir} NULLS LAST"

  defp tie_breaker_clauses(group_specs) do
    Enum.map(
      group_specs,
      &"COALESCE(to_jsonb(g#{&1.index})::text, 'null') COLLATE \"C\" ASC"
    )
  end

  defp normalize_string(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalize_string(value), do: value

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

  defp cursor_value(%{type: :datetime, sql: sql}), do: utc_timestamp("(#{sql})::timestamptz")
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
      {:ok, param <> "::text::timestamptz", params}
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

  defp expression(%{storage_mode: :physical, type: :datetime} = field, _fields, params),
    do: {:ok, Physical.expression(field, "r"), :datetime, params}

  defp expression(field, fields, params), do: Formula.expression(field, fields, params)

  def source(%{storage_mode: :physical, id: id}), do: BaseRepo.table(id)
  def source(_table), do: "base_records"

  def scope(%{storage_mode: :physical}),
    do: "$1::text::uuid IS NOT NULL AND $2::text::uuid IS NOT NULL"

  def scope(_table), do: "r.tenant_id=$1::text::uuid AND r.table_id=$2::text::uuid"
  def execute(%{storage_mode: :physical}, sql, params), do: BaseRepo.query(sql, params)
  def execute(_table, sql, params), do: Repo.query(sql, params)
  defp data(%{storage_mode: :physical}, fields), do: Physical.data_sql(fields)
  defp data(_table, _fields), do: "r.data"

  defp envelope(%{storage_mode: :physical}),
    do:
      "jsonb_build_object('id',r.id,'versions',r.versions,'created_by',r.created_by,'updated_by',r.updated_by)"

  defp envelope(_table), do: "(to_jsonb(r) - 'tenant_id' - 'table_id' - 'data_bytes')"
  defp datetime_expression(expr, :datetime), do: "(#{expr})::timestamptz"
  defp datetime_expression(expr, _type), do: expr

  def utc_timestamp(column),
    do: "to_char(#{column} AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')"
end
