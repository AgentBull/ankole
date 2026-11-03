defmodule Ankole.Files.Vfs.Base do
  @moduledoc "Projects Base tables through their query and record-write owners."
  alias Ankole.{Kernel, Repo}
  alias Ankole.Files.Vfs.Namespace
  alias Ankole.Pod.{Bases, Query, Formula}
  @formats ~w(csv tsv json jsonl)
  @directories ~w(.info .views .filter .order .columns .first .last .export .import)

  def resolve(scope, node, parts) do
    with {:ok, %{tables: tables}} <- Bases.list_tables_in_tx(scope.actor, node.id) do
      case parts do
        [".base.json"] ->
          {:ok,
           bytes(node, parts, %{
             tables:
               Enum.map(
                 tables,
                 &Map.take(&1, [:id, :name, :schema_version, :data_version, :record_count])
               )
           })}

        [name | rest] ->
          resolve_named(scope, node, parts, rest, named(tables, name))

        _ ->
          {:error, :not_found}
      end
    end
  end

  defp resolve_named(_scope, _node, _parts, _rest, nil), do: {:error, :not_found}

  defp resolve_named(scope, node, parts, rest, table) do
    Bases.vfs_read_in_tx(scope.actor, table.id, fn table, fields, views ->
      with {:ok, pipeline} <- compile(rest, fields, views),
           do: resolve_table(node, parts, table, fields, views, pipeline)
    end)
  end

  def children(scope, %{kind: :base, node: node}) do
    with {:ok, %{tables: tables}} <- Bases.list_tables_in_tx(scope.actor, node.id) do
      {:ok,
       [
         bytes(node, [".base.json"], %{
           tables: Enum.map(tables, &Map.take(&1, [:id, :name, :record_count]))
         })
         | Enum.map(tables, &directory(node, [name(&1, tables)]))
       ]}
    end
  end

  def children(scope, %{node: node, base_path: [table_name | rest] = parts}) do
    with {:ok, %{tables: tables}} <- Bases.list_tables_in_tx(scope.actor, node.id),
         table when not is_nil(table) <- named(tables, table_name) do
      Bases.vfs_read_in_tx(scope.actor, table.id, fn table, fields, views ->
        with {:ok, pipeline} <- compile(rest, fields, views) do
          table_children(node, parts, table, fields, views, pipeline)
        end
      end)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp table_children(node, parts, table, fields, views, pipeline) do
    case pipeline.rest do
      [] ->
        with {:ok, records} <- records(table, fields, pipeline, 200) do
          {:ok,
           Enum.map(@directories, &directory(node, parts ++ [&1])) ++
             Enum.map(records, fn record ->
               record_entry(
                 node,
                 parts ++ ["rec_#{record["id"]}.json"],
                 table,
                 pipeline.columns,
                 record
               )
             end)}
        end

      [".export"] ->
        {:ok, Enum.map(@formats, &export_entry(node, parts ++ [&1], table, pipeline, &1))}

      [".import"] ->
        {:ok, Enum.map(~w(csv jsonl), &import_entry(node, parts ++ ["append." <> &1], table, &1))}

      [".info"] ->
        with {:ok, count} <- count(table, fields, pipeline),
             do:
               {:ok,
                [
                  bytes(node, parts ++ ["schema.json"], schema(table, fields)),
                  bytes(node, parts ++ ["count"], "#{count}\n")
                ]}

      [".views"] ->
        {:ok, Enum.map(views, &directory(node, parts ++ [name(&1, views)]))}

      [".filter"] ->
        {:ok, Enum.map(fields, &directory(node, parts ++ [field_segment(&1)]))}

      [".filter", field_name] ->
        with field when not is_nil(field) <- field(fields, field_name),
             {:ok, records} <- records(table, fields, pipeline, 200) do
          values =
            records
            |> Enum.map(& &1["data"][field.id])
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          {:ok, Enum.map(values, &directory(node, parts ++ [display(&1) |> path_component()]))}
        else
          nil -> {:error, :not_found}
          error -> error
        end

      [".order"] ->
        {:ok,
         for(
           field <- fields,
           direction <- ~w(asc desc),
           do: directory(node, parts ++ [field_segment(field) <> "." <> direction])
         )}

      [".columns"] ->
        {:ok, Enum.map(fields, &directory(node, parts ++ [field_segment(&1)]))}

      [window] when window in [".first", ".last"] ->
        {:ok, Enum.map(~w(20 100), &directory(node, parts ++ [&1]))}

      _ ->
        {:error, :not_a_directory}
    end
  end

  defp resolve_table(node, parts, table, fields, _views, pipeline) do
    case pipeline.rest do
      [] ->
        {:ok, directory(node, parts)}

      [dir] when dir in @directories ->
        {:ok, directory(node, parts)}

      [".filter", name] ->
        if field(fields, name), do: {:ok, directory(node, parts)}, else: {:error, :not_found}

      [".info", "schema.json"] ->
        {:ok, bytes(node, parts, schema(table, fields))}

      [".info", "count"] ->
        with {:ok, count} <- count(table, fields, pipeline),
             do: {:ok, bytes(node, parts, "#{count}\n")}

      [".export", format] when format in @formats ->
        {:ok, export_entry(node, parts, table, pipeline, format)}

      [".import", "append." <> format] when format in ["csv", "jsonl"] ->
        if pipeline.stages == [],
          do: {:ok, import_entry(node, parts, table, format)},
          else: {:error, :forbidden}

      ["rec_" <> tail] ->
        with ".json" <- Path.extname(tail),
             {:ok, id} <- Ecto.UUID.cast(Path.rootname(tail)),
             {:ok, result} <-
               Query.records(table, fields, Map.merge(pipeline.query, %{ids: [id], page_size: 1})),
             [record] <- result.records,
             do: {:ok, record_entry(node, parts, table, pipeline.columns, record)},
             else: (_ -> {:error, :not_found})

      ["new_" <> tail] ->
        if String.ends_with?(tail, ".json") && pipeline.stages == [],
          do:
            {:ok,
             bytes(node, parts, "") |> Map.put(:base_write, %{table_id: table.id, kind: :new})},
          else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  def compile(parts, fields, views) do
    with {:ok, parsed} <- Kernel.vfs_pipeline(parts) do
      Enum.reduce_while(
        parsed["stages"],
        {:ok,
         %{
           query: %{},
           columns: fields,
           windows: [],
           rest: parsed["rest"],
           stages: parsed["stages"]
         }},
        fn stage, {:ok, state} ->
          case stage(stage["op"], stage["args"], state, fields, views) do
            {:ok, state} -> {:cont, {:ok, state}}
            error -> {:halt, error}
          end
        end
      )
    end
  end

  defp stage(".filter", [name, value], state, fields, _) do
    with field when not is_nil(field) <- field(fields, name),
         {:ok, value} <- filter_value(field, URI.decode(value)) do
      condition = %{"field_id" => field.id, "operator" => "is", "value" => value}
      filter = Map.get(state.query, :filter, %{"conjunction" => "and", "conditions" => []})
      # The query owner supports flat groups. A saved OR view cannot be silently
      # changed into AND by appending another filter.
      if filter["conjunction"] == "and" || filter["conditions"] == [] do
        {:ok,
         %{
           state
           | query:
               Map.put(state.query, :filter, %{
                 "conjunction" => "and",
                 "conditions" => filter["conditions"] ++ [condition]
               })
         }}
      else
        {:error, :incompatible_view_filter}
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp stage(".order", [value], state, fields, _) do
    with [_, name, direction] <- Regex.run(~r/^(.*)\.(asc|desc)$/, value),
         field when not is_nil(field) <- field(fields, name),
         do:
           {:ok,
            %{
              state
              | query:
                  Map.put(state.query, :sort, [
                    %{"field_id" => field.id, "direction" => direction}
                  ])
            }},
         else: (_ -> {:error, :invalid_query})
  end

  defp stage(".columns", [value], state, fields, _) do
    columns = value |> String.split(",") |> Enum.map(&field(fields, &1))

    if Enum.any?(columns, &is_nil/1),
      do: {:error, :not_found},
      else: {:ok, %{state | columns: columns}}
  end

  defp stage(window, [value], state, _, _) when window in [".first", ".last"] do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, %{state | windows: state.windows ++ [{window, n}]}}
      _ -> {:error, :invalid_query}
    end
  end

  defp stage(".views", [name], state, fields, views) do
    case named(views, name) do
      nil ->
        {:error, :not_found}

      view ->
        query =
          Enum.reduce(~w(filter sort), state.query, fn key, query ->
            if view.config[key],
              do: Map.put(query, String.to_existing_atom(key), view.config[key]),
              else: query
          end)

        columns =
          case view.config["visible_fields"] do
            nil -> fields
            ids -> Enum.filter(fields, &(&1.is_primary || &1.id in ids))
          end

        {:ok, %{state | query: query, columns: columns}}
    end
  end

  defp field(fields, name), do: Enum.find(fields, &(&1.name == name || &1.id == name))
  defp field_key(%{name: name, id: id}), do: if(name in ["_id", "_versions"], do: id, else: name)

  defp field_segment(field) do
    if field.name in ["", ".", ".."] || String.contains?(field.name, ["/", ","]) ||
         byte_size(field.name) > 240, do: field.id, else: field.name
  end

  defp path_component(value),
    do: value |> String.replace("%", "%25") |> String.replace("/", "%2F")

  defp filter_value(%{type: :select, config: config}, value) do
    case Enum.find(config["options"] || [], &(&1["name"] == value || &1["id"] == value)) do
      nil -> {:error, :invalid_value}
      option -> {:ok, option["id"]}
    end
  end

  defp filter_value(%{type: type}, value) when type in [:number, :checkbox, :auto_number] do
    case Torque.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_value}
    end
  end

  defp filter_value(_, value), do: {:ok, value}

  def count(table, fields, pipeline) do
    with {:ok, %{groups: [%{metrics: %{"count" => count}}]}} <-
           Query.aggregate(table, fields, pipeline.query, max_groups: 1) do
      {_offset, count} = window(pipeline, count)
      {:ok, count}
    end
  end

  defp bounds(table, fields, pipeline) do
    with {:ok, %{groups: [%{metrics: %{"count" => count}}]}} <-
           Query.aggregate(table, fields, pipeline.query, max_groups: 1),
         do: {:ok, window(pipeline, count)}
  end

  defp window(pipeline, total) do
    Enum.reduce(pipeline.windows, {0, total}, fn
      {".first", n}, {offset, count} -> {offset, min(count, n)}
      {".last", n}, {offset, count} -> {offset + max(0, count - n), min(count, n)}
    end)
  end

  defp records(table, fields, pipeline, limit) do
    with {:ok, {offset, count}} <- bounds(table, fields, pipeline) do
      if count == 0,
        do: {:ok, []},
        else:
          with(
            {:ok, result} <-
              Query.records(table, fields, Map.put(pipeline.query, :page_size, min(count, limit)),
                offset: offset
              ),
            do: {:ok, result.records}
          )
    end
  end

  def export_in_tx(scope, entry, local_path) do
    Bases.vfs_read_in_tx(scope.actor, entry.export.table_id, fn table, fields, views ->
      with {:ok, _} <- Namespace.authorize(scope, entry.node, "node_view"),
           {:ok, pipeline} <- compile(entry.export.parts, fields, views),
           {:ok, {offset, count}} <- bounds(table, fields, pipeline),
           :ok <-
             export_batches(
               table,
               fields,
               pipeline,
               entry.export.format,
               local_path,
               offset,
               count,
               nil,
               true
             ) do
        key =
          Kernel.vfs_fingerprint(
            Torque.encode!([
              table.id,
              table.schema_version,
              table.data_version,
              pipeline.stages,
              entry.export.format
            ])
          )

        {:ok, key}
      end
    end)
  end

  defp export_batches(table, fields, pipeline, format, path, offset, count, cursor, first) do
    query =
      pipeline.query
      |> Map.put(:page_size, max(1, min(count, 200)))
      |> Map.put(:page_token, cursor)

    with {:ok, result} <-
           if(count == 0,
             do: {:ok, %{records: [], complete: true, page_token: nil}},
             else: Query.records(table, fields, query, offset: offset)
           ),
         rows = Enum.map(result.records, &business_record(&1, pipeline.columns, false)),
         last = result.complete || count <= 200,
         size when is_integer(size) <-
           Kernel.vfs_export_chunk(
             path,
             format,
             Enum.map(pipeline.columns, &field_key/1),
             rows,
             first,
             last
           ) do
      if last,
        do: :ok,
        else:
          export_batches(
            table,
            fields,
            pipeline,
            format,
            path,
            0,
            count - length(rows),
            result.page_token,
            false
          )
    end
  end

  def write(scope, entry, path, headers) do
    with {:ok, _} <- Namespace.authorize(scope, entry.node, "node_contribute") do
      case entry.base_write.kind do
        :import ->
          import_batches(scope, entry, path, headers, 0, 0)

        kind when kind in [:record, :new] ->
          with {:ok, raw} <- File.read(path),
               {:ok, value} <- Torque.decode(raw),
               do: write_rows(scope, entry, [value], headers, 0)
      end
    end
  end

  defp import_batches(scope, entry, path, headers, cursor, row_index) do
    with {:ok, chunk} <- Kernel.vfs_import_chunk(path, entry.base_write.format, cursor),
         :ok <-
           if(chunk["rows"] == [],
             do: :ok,
             else: write_rows(scope, entry, chunk["rows"], headers, row_index)
           ) do
      if chunk["complete"],
        do: :ok,
        else:
          import_batches(
            scope,
            entry,
            path,
            headers,
            chunk["cursor"],
            row_index + length(chunk["rows"])
          )
    end
  end

  defp write_rows(scope, entry, rows, headers, row_index) do
    Ankole.Pod.Access.write(
      scope.actor.turn_authority,
      fn ->
        with {:ok, access} <- Ankole.Brain.Access.for_context(scope.context),
             {:ok, _} <-
               Namespace.authorize(%{scope | access: access}, entry.node, "node_contribute"),
             {:ok, table} <- Bases.fetch_table(entry.base_write.table_id),
             fields = Bases.fields(table.id),
             {:ok, attrs} <- write_attrs(entry.base_write, rows, fields, headers, row_index),
             {:ok, result} <-
               if(attrs == %{},
                 do: {:ok, nil},
                 else: Bases.write_records_in_tx(scope.actor, table.id, attrs, vfs_replay: true)
               ),
             do: {:ok, result}
      end,
      after_commit: fn
        nil -> :ok
        result -> Bases.committed_records(result)
      end
    )
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp write_attrs(%{kind: :record, record_id: id}, [value], fields, headers, _) do
    patch =
      if headers["x-ankole-record-patch"] == "1",
        do: Kernel.vfs_record_patch(value),
        else:
          {:ok,
           %{
             "data" => Map.reject(value, fn {key, _} -> key in ["_id", "_versions"] end),
             "expected_versions" => value["_versions"]
           }}

    with {:ok, patch} <- patch,
         {:ok, data} <- field_map(patch["data"], fields),
         {:ok, expected} <- field_map(patch["expected_versions"], fields) do
      if data == %{},
        do: {:ok, %{}},
        else: {:ok, %{updates: [%{id: id, data: data, expected_versions: expected}]}}
    end
  end

  defp write_attrs(write, rows, fields, headers, row_index) do
    with {:ok, request} <- Ecto.UUID.cast(headers["x-ankole-request-id"]),
         {millis, ""} when millis > 0 <- Integer.parse(headers["x-ankole-request-ts-ms"] || "") do
      rows
      |> Enum.with_index(row_index)
      |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, creates} ->
        id =
          row["_id"] ||
            Kernel.vfs_import_id(Repo.tenant_id!(), write.table_id, request, millis, index)

        data = Map.reject(row, fn {key, _} -> key in ["_id", "_versions"] end)

        with {:ok, id} <- Ecto.UUID.cast(id),
             {:ok, data} <- field_map(data, fields),
             {:ok, data} <- cast_csv(data, fields, Map.get(write, :format)) do
          {:cont, {:ok, [%{id: id, data: data} | creates]}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, creates} -> {:ok, %{creates: Enum.reverse(creates)}}
        error -> error
      end
    else
      _ -> {:error, :request_identity_required}
    end
  end

  defp field_map(map, fields) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {name, value}, {:ok, result} ->
      case field(fields, name) do
        nil -> {:halt, {:error, {:unknown_field, name}}}
        field -> {:cont, {:ok, Map.put(result, field.id, value)}}
      end
    end)
  end

  defp field_map(_, _), do: {:error, :expected_versions_required}

  defp cast_csv(data, fields, "csv") do
    Enum.reduce_while(data, {:ok, %{}}, fn {id, value}, {:ok, result} ->
      field = Enum.find(fields, &(&1.id == id))

      parsed =
        cond do
          value == "" ->
            {:ok, nil}

          field.type in [:text, :datetime] ->
            {:ok, value}

          field.type in [:user, :attachment, :link] ||
              (field.type == :select && field.config["multiple"] == true) ->
            Torque.decode(value)

          true ->
            filter_value(field, value)
        end

      case parsed do
        {:ok, value} -> {:cont, {:ok, Map.put(result, id, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp cast_csv(data, _, _), do: {:ok, data}

  defp record_entry(node, parts, table, fields, record),
    do:
      bytes(node, parts, business_record(record, fields, true))
      |> Map.put(:base_write, %{kind: :record, table_id: table.id, record_id: record["id"]})

  defp business_record(record, fields, versions?) do
    data = Map.new(fields, &{field_key(&1), record["data"][&1.id]})

    if versions? do
      writable = Enum.reject(fields, &(Formula.readonly?(&1) || &1.type == :auto_number))

      data
      |> Map.put("_id", record["id"])
      |> Map.put("_versions", Map.new(writable, &{field_key(&1), record["versions"][&1.id]}))
    else
      data
    end
  end

  defp import_entry(node, parts, table, format),
    do:
      bytes(node, parts, "")
      |> Map.put(:base_write, %{kind: :import, table_id: table.id, format: format})
      |> Map.put(:etag, "\"import:#{table.id}:#{table.data_version}\"")

  defp export_entry(node, parts, table, pipeline, format) do
    bytes(node, parts, "")
    |> Map.put(:export, %{
      table_id: table.id,
      parts: Enum.drop(parts, 1),
      format: format,
      key:
        Kernel.vfs_fingerprint(
          Torque.encode!([
            table.id,
            table.schema_version,
            table.data_version,
            pipeline.stages,
            format
          ])
        )
    })
    |> Map.put(:stat_on_lookup, true)
  end

  defp directory(node, parts),
    do: %{node: node, kind: :virtual_directory, name: List.last(parts), base_path: parts}

  defp bytes(node, parts, value) do
    bytes = if is_binary(value), do: value, else: Torque.encode!(value) <> "\n"

    %{
      node: node,
      kind: :virtual_file,
      name: List.last(parts),
      base_path: parts,
      size: byte_size(bytes),
      content: {:bytes, bytes},
      etag: "\"vfs:#{Kernel.vfs_fingerprint(bytes)}\"",
      modified: node.updated_at,
      content_type:
        if(Path.extname(List.last(parts)) == ".json",
          do: "application/json",
          else: "text/plain; charset=utf-8"
        )
    }
  end

  defp schema(table, fields),
    do: %{
      table: Map.take(table, [:id, :name, :schema_version]),
      fields: Enum.map(fields, &Map.take(&1, [:id, :name, :type, :config, :is_primary]))
    }

  defp display(value) when is_binary(value), do: value
  defp display(value), do: Torque.encode!(value)
  defp named(items, segment), do: Enum.find(items, &(name(&1, items) == segment))

  defp name(item, items) do
    raw = item.name |> String.replace("%", "%25") |> String.replace("/", "%2F")

    raw =
      if Enum.count(items, &(&1.name == item.name)) > 1 || String.starts_with?(raw, "."),
        do: raw <> "~" <> String.slice(Kernel.vfs_fingerprint(item.id), 0, 10),
        else: raw

    Kernel.vfs_name(raw, :folder, item.id)
  end
end
