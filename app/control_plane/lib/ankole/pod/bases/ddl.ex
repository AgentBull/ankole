defmodule Ankole.Pod.Bases.DDL do
  @moduledoc "Applies field changes to stored values, native columns, and link relations."
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :tenant_schema
  alias Ankole.Repo
  alias Ankole.Pod.{BaseRepo, Bases, Formula, Query, Values}
  alias Ankole.Pod.Bases.{Physical, Promote, Links, Write}

  def finish(write) do
    definitions = Map.new(write.tables, fn {id, _} -> {id, Bases.fields(id)} end)
    links = definitions |> Map.values() |> List.flatten() |> Enum.filter(&(&1.type == :link))
    linked = Enum.flat_map(links, &[&1.table_id, &1.config["table_id"]]) |> MapSet.new()

    promoted =
      for {id, table} <- write.tables,
          table.storage_mode == :inline and MapSet.member?(linked, id),
          do: id

    write = Enum.reduce(promoted, write, &Write.touch(&2, &1))

    inline_changes =
      Map.filter(write.changes, fn {id, _} -> write.tables[id].storage_mode == :inline end)

    with :ok <- change_inline_tables(write, inline_changes, definitions),
         {:ok, inline_results} <- Write.finish(%{write | changes: inline_changes}),
         promoted =
           Enum.uniq(
             promoted ++
               Enum.flat_map(inline_changes, fn {id, _} ->
                 {:ok, table} = Bases.fetch_table(id)
                 if Bases.inline?(table), do: [], else: [id]
               end)
           ),
         {:ok, targets} <- prepare_tables(write, promoted),
         records = Map.new(promoted, &{&1, Promote.records(&1)}),
         {:ok, physical_results} <- apply_changes(write, targets, definitions, records, links),
         :ok <- commit_promotions(promoted, targets) do
      inline_results = Enum.reject(inline_results, &(&1.id in promoted))
      {:ok, inline_results ++ physical_results}
    end
  end

  defp change_inline_tables(write, changes, definitions) do
    Enum.reduce_while(changes, :ok, fn {id, _}, :ok ->
      table = write.tables[id]

      for old <- removed_values(write.definitions[id], definitions[id]) do
        Repo.query!(
          "UPDATE base_records SET data=data-$3::text,versions=versions-$3::text WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid",
          [Repo.tenant_id!(), id, old.id]
        )
      end

      result =
        write.conversions
        |> Map.values()
        |> Enum.filter(&(&1.old.table_id == id))
        |> Enum.reduce_while(:ok, fn conversion, :ok ->
          with {:ok, values} <- converted_values(write, table, write.definitions[id], conversion) do
            put_values!(table, conversion.candidate, values, write.uid)
            {:cont, :ok}
          else
            error -> {:halt, error}
          end
        end)

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp commit_promotions(ids, targets) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Promote.commit(Map.fetch!(targets, id)) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp prepare_tables(write, promoted) do
    Enum.reduce_while(write.changes, {:ok, %{}}, fn {id, _}, {:ok, targets} ->
      table = write.tables[id]

      cond do
        id in promoted ->
          {:ok, current} = Bases.fetch_table(id)

          {:cont,
           {:ok,
            Map.put(targets, id, %{
              current
              | storage_mode: :physical,
                schema_version: current.schema_version + 1
            })}}

        table.storage_mode == :physical ->
          case Ankole.Ash.update(table, :schema_changed, %{}) do
            {:ok, updated} -> {:cont, {:ok, Map.put(targets, id, updated)}}
            error -> {:halt, error}
          end

        true ->
          {:cont, {:ok, targets}}
      end
    end)
  end

  defp apply_changes(_write, targets, _definitions, _records, _links) when map_size(targets) == 0,
    do: {:ok, []}

  defp apply_changes(write, targets, definitions, records, links) do
    BaseRepo.run(
      write.shard,
      fn ->
        with {:ok, locked} <- Physical.lock_states(write),
             {:ok, converted} <- conversions(locked),
             :ok <- change_tables(locked, targets, definitions, records, converted),
             {:ok, changed} <- change_edges(locked, definitions, records, links, converted),
             :ok <- Links.constrain(links, Map.keys(targets)),
             :ok <- validate_conversions(changed, converted) do
          results =
            for {id, change} <- changed.changes,
                Map.has_key?(targets, id) or locked.tables[id].storage_mode == :physical do
              table = targets[id] || locked.tables[id]

              if Map.has_key?(records, id) do
                %{
                  id: id,
                  data_version: table.data_version,
                  changed_ids: [],
                  deleted_ids: [],
                  resync: true
                }
              else
                BaseRepo.query!(
                  "UPDATE #{BaseRepo.states()} SET schema_version=$2 WHERE table_id=$1::text::uuid",
                  [id, table.schema_version]
                )

                {:ok, current} = Physical.commit(locked.tables[id], change)

                %{
                  id: id,
                  data_version: current.data_version,
                  changed_ids: [],
                  deleted_ids: [],
                  resync: true
                }
              end
            end

          {:ok, results}
        end
      end,
      ddl: true,
      deadline: write.deadline,
      timezone: write.timezone
    )
  end

  defp change_tables(write, targets, definitions, records, converted) do
    Enum.reduce_while(targets, :ok, fn {id, table}, :ok ->
      result =
        if Map.has_key?(records, id) do
          Physical.create_table!(table, definitions[id], records[id])
          :ok
        else
          alter_table(write, table, write.definitions[id], definitions[id], converted)
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp conversions(write) do
    conversions =
      Enum.filter(write.conversions, fn {_id, conversion} ->
        write.tables[conversion.old.table_id].storage_mode == :physical and
          not Formula.readonly?(conversion.candidate)
      end)

    if conversions != [] do
      BaseRepo.query!(
        "CREATE TEMP TABLE pg_temp.ankole_base_conversions (field_id text, id uuid, data jsonb) ON COMMIT DROP",
        []
      )
    end

    Enum.reduce_while(conversions, {:ok, %{}}, fn {id, conversion}, {:ok, converted} ->
      table = write.tables[conversion.old.table_id]

      case converted_values(write, table, write.definitions[table.id], conversion) do
        {:ok, values} -> {:cont, {:ok, Map.put(converted, id, values)}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_conversions(write, converted) do
    converted
    |> Map.keys()
    |> Enum.map(&write.conversions[&1].old.table_id)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case Physical.validate_sizes(write, id, nil) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp alter_table(write, table, before, fields, converted) do
    before_by_id = Map.new(before, &{&1.id, &1})

    added =
      Enum.count(fields, fn field ->
        Physical.stored?(field) and
          (is_nil(before_by_id[field.id]) or not Physical.stored?(before_by_id[field.id]))
      end)

    [[attnum]] =
      BaseRepo.query!(
        "SELECT COALESCE(max(attnum),0) FROM pg_attribute WHERE attrelid=$1::text::regclass",
        [BaseRepo.table(table.id)]
      ).rows

    if attnum + added > 1600 do
      {:error, :field_history_limit}
    else
      for old <- removed_values(before, fields) do
        BaseRepo.query!("UPDATE #{BaseRepo.table(table.id)} SET versions=versions-$1::text", [
          old.id
        ])
      end

      for old <- before,
          Physical.stored?(old),
          not Enum.any?(fields, &(&1.id == old.id and Physical.stored?(&1))) do
        BaseRepo.query!(
          "ALTER TABLE #{BaseRepo.table(table.id)} DROP COLUMN #{BaseRepo.column(old.id)}",
          []
        )
      end

      for field <- fields, Physical.stored?(field) do
        old = before_by_id[field.id]

        cond do
          is_nil(old) or not Physical.stored?(old) ->
            add_column!(table, field)

          Physical.sql_type(old) != Physical.sql_type(field) ->
            BaseRepo.query!(
              "ALTER TABLE #{BaseRepo.table(table.id)} ALTER COLUMN #{BaseRepo.column(field.id)} TYPE #{Physical.sql_type(field)} USING NULL",
              []
            )

          true ->
            :ok
        end

        if values = converted[field.id], do: put_values!(table, field, values, write.uid)
      end

      :ok
    end
  end

  defp removed_values(before, fields) do
    current = Map.new(fields, &{&1.id, &1})

    Enum.filter(before, fn old ->
      is_nil(current[old.id]) or
        (not Formula.readonly?(old) and Formula.readonly?(current[old.id]))
    end)
  end

  defp add_column!(table, field) do
    BaseRepo.query!(
      "ALTER TABLE #{BaseRepo.table(table.id)} ADD COLUMN #{BaseRepo.column(field.id)} #{Physical.sql_type(field)}",
      []
    )

    Physical.index!(table, field)
  end

  defp converted_values(write, table, fields, %{candidate: candidate} = conversion) do
    if Formula.readonly?(candidate),
      do: {:ok, []},
      else: convert_stored_values(write, table, fields, conversion)
  end

  defp convert_stored_values(write, table, fields, %{candidate: %{type: :number}} = conversion) do
    fields = Physical.fields(table, fields)
    old = Enum.find(fields, &(&1.id == conversion.old.id))
    {:ok, expr, _type, params} = Formula.expression(old, fields, [Repo.tenant_id!(), table.id])
    {field_key, params} = Formula.bind(params, conversion.candidate.id)

    with :ok <- check_numeric_conversion(table, expr, field_key, params, conversion.clear),
         do: store_numeric_conversion(write, table, expr, field_key, params)
  end

  defp convert_stored_values(write, table, fields, %{old: old, candidate: candidate, clear: clear}) do
    fields = Physical.fields(table, fields)
    old = Enum.find(fields, &(&1.id == old.id))
    {:ok, expr, _type, params} = Formula.expression(old, fields, [Repo.tenant_id!(), table.id])
    data = if table.storage_mode == :physical, do: "NULL::jsonb", else: "r.data"
    present = if Formula.readonly?(old), do: "TRUE", else: "#{expr} IS NOT NULL"

    sql =
      "SELECT r.id::text,to_jsonb(#{expr}),#{data} FROM #{Query.source(table)} r WHERE #{Query.scope(table)} AND #{present}"

    if table.storage_mode == :physical do
      Ecto.Adapters.SQL.stream(BaseRepo.get_dynamic_repo(), sql, params, max_rows: 100)
      |> Enum.reduce_while({:ok, :staged}, fn %{rows: rows}, result ->
        case convert_rows(rows, write, table, old, candidate, clear) do
          {:ok, values} ->
            BaseRepo.query!(
              """
              INSERT INTO pg_temp.ankole_base_conversions(field_id,id,data)
              SELECT $1,id::uuid,data FROM jsonb_to_recordset($2::text::jsonb) AS source(id text,data jsonb)
              """,
              [candidate.id, Torque.encode!(values)]
            )

            {:cont, result}

          error ->
            {:halt, error}
        end
      end)
    else
      with {:ok, %{rows: rows}} <- Query.execute(table, sql, params),
           do: convert_rows(rows, write, table, old, candidate, clear)
    end
  end

  defp execute_numeric_conversion(table, expr, field_key, statement, params) do
    original = if table.storage_mode == :inline, do: "r.data", else: "NULL::jsonb"

    projection = """
    WITH cells AS (
      SELECT r.id, to_jsonb(#{expr}) AS value, #{original} AS original
      FROM #{Query.source(table)} r WHERE #{Query.scope(table)}
    ), checked AS (
      SELECT *, value IS NULL OR value IN ('null'::jsonb, '""'::jsonb, '[]'::jsonb) AS empty,
        jsonb_typeof(value) IN ('number', 'string')
          AND pg_input_is_valid(value #>> '{}', 'numeric')
          AND lower(btrim(value #>> '{}')) NOT IN ('nan', 'infinity', '+infinity', '-infinity', 'inf', '+inf', '-inf') AS valid
      FROM cells
    ), converted AS (
      SELECT id, original, jsonb_build_object(#{field_key}::text,
        CASE WHEN valid THEN to_jsonb((value #>> '{}')::numeric) ELSE 'null'::jsonb END) AS data
      FROM checked
    )
    """

    Query.execute(table, projection <> statement, params)
  end

  defp check_numeric_conversion(_table, _expr, _field_key, _params, true), do: :ok

  defp check_numeric_conversion(table, expr, field_key, params, false) do
    case execute_numeric_conversion(
           table,
           expr,
           field_key,
           "SELECT id::text FROM checked WHERE NOT empty AND NOT COALESCE(valid, false) LIMIT 1",
           params
         ) do
      {:ok, %{rows: []}} -> :ok
      {:ok, %{rows: [[id]]}} -> {:error, {:conversion_failed, [id]}}
      error -> error
    end
  end

  defp store_numeric_conversion(
         write,
         %{storage_mode: :inline} = table,
         expr,
         field_key,
         params
       ) do
    {limit, sized_params} = Formula.bind(params, write.limits["record_bytes"])

    size_query =
      "SELECT id FROM converted WHERE octet_length(jsonb_strip_nulls((original-#{field_key}::text)||data)::text)>#{limit} LIMIT 1"

    with {:ok, %{rows: []}} <-
           execute_numeric_conversion(table, expr, field_key, size_query, sized_params),
         {:ok, %{rows: [[payload]]}} <-
           execute_numeric_conversion(
             table,
             expr,
             field_key,
             "SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id::text,'data',data)), '[]'::jsonb)::text FROM converted",
             params
           ) do
      {:ok, {:json, payload}}
    else
      {:ok, %{rows: [_ | _]}} -> {:error, :record_size_limit}
      error -> error
    end
  end

  defp store_numeric_conversion(_write, table, expr, field_key, params) do
    with {:ok, _} <-
           execute_numeric_conversion(
             table,
             expr,
             field_key,
             "INSERT INTO pg_temp.ankole_base_conversions(field_id,id,data) SELECT #{field_key}::text,id,data FROM converted",
             params
           ),
         do: {:ok, :staged}
  end

  defp convert_rows(rows, write, table, old, candidate, clear) do
    Enum.reduce_while(rows, {:ok, []}, fn [id, value, data], {:ok, values} ->
      result =
        case Values.convert(candidate, value, table.page_id) do
          {:error, _} when clear -> {:ok, nil}
          result -> result
        end

      case result do
        {:ok, ^value} when old.type == :select and candidate.type == :select ->
          {:cont, {:ok, values}}

        {:ok, converted} ->
          size =
            if table.storage_mode == :inline,
              do:
                Values.record_size(
                  Values.clean(Map.put(data, candidate.id, converted)),
                  write.limits
                ),
              else: :ok

          case size do
            :ok -> {:cont, {:ok, [%{id: id, data: %{candidate.id => converted}} | values]}}
            error -> {:halt, error}
          end

        {:error, _} ->
          {:halt, {:error, {:conversion_failed, [id]}}}
      end
    end)
  end

  defp put_values!(_table, _field, [], _uid), do: :ok

  defp put_values!(%{storage_mode: :inline} = table, field, values, uid) do
    Repo.query!(
      """
      UPDATE base_records r SET data=jsonb_strip_nulls((r.data-$3::text)||source.data),
        versions=jsonb_set(r.versions,ARRAY[$3::text],to_jsonb(COALESCE((r.versions->>$3::text)::bigint,0)+1)),
        updated_at=now(),updated_by=$5::text
      FROM jsonb_to_recordset($4::text::jsonb) AS source(id text,data jsonb)
      WHERE r.tenant_id=$1::text::uuid AND r.table_id=$2::text::uuid AND r.id=source.id::uuid
      """,
      [
        Repo.tenant_id!(),
        table.id,
        field.id,
        conversion_payload(values),
        to_string(Ankole.ActorRef.from_writer(uid, Repo.tenant_id!(), []))
      ]
    )
  end

  defp put_values!(table, field, :staged, uid) do
    BaseRepo.query!(
      """
      UPDATE #{BaseRepo.table(table.id)} r SET #{BaseRepo.column(field.id)}=#{Physical.json_value(field, "source.data")},
        versions=jsonb_set(r.versions,ARRAY[$1::text],to_jsonb(COALESCE((r.versions->>$1::text)::bigint,0)+1)),
        updated_by=$2,updated_at=now()
      FROM pg_temp.ankole_base_conversions source WHERE source.field_id=$1 AND r.id=source.id
      """,
      [
        field.id,
        to_string(Ankole.ActorRef.from_writer(uid, Ankole.Repo.tenant_id!(), []))
      ]
    )
  end

  defp conversion_payload({:json, payload}), do: payload
  defp conversion_payload(values), do: Torque.encode!(values)

  defp change_edges(write, definitions, records, links, converted) do
    old_links =
      write.definitions |> Map.values() |> List.flatten() |> Enum.filter(&(&1.type == :link))

    old_names = MapSet.new(old_links, & &1.config["edge_table"])
    new_names = MapSet.new(links, & &1.config["edge_table"])

    Links.remove_constraints(old_links, Map.keys(write.changes))

    for field <- links,
        field.config["edge_role"] == "src",
        not MapSet.member?(old_names, field.config["edge_table"]) do
      BaseRepo.query!(
        "DROP TABLE IF EXISTS #{BaseRepo.edge(field.config["edge_table"])} CASCADE",
        []
      )

      Links.create!(field)

      case Enum.find(old_links, &(&1.id == field.id)) do
        nil ->
          :ok

        old ->
          {own, peer} = Links.roles(old)

          BaseRepo.query!(
            "INSERT INTO #{BaseRepo.edge(field.config["edge_table"])} (src_id,dst_id,src_ord,dst_ord) SELECT #{own}_id,#{peer}_id,#{own}_ord,#{peer}_ord FROM #{BaseRepo.edge(old.config["edge_table"])}",
            []
          )
      end
    end

    # Endpoint changes replace the edge's foreign keys together with its contents.
    for field <- links, field.config["edge_role"] == "src" do
      old = Enum.find(old_links, &(&1.id == field.id))

      if old && old.config["edge_table"] == field.config["edge_table"] &&
           old.config["table_id"] != field.config["table_id"] do
        BaseRepo.query!("DROP TABLE #{BaseRepo.edge(field.config["edge_table"])}", [])
        Links.create!(field)
      end
    end

    for name <- MapSet.difference(old_names, new_names),
        do: BaseRepo.query!("DROP TABLE IF EXISTS #{BaseRepo.edge(name)}", [])

    write = %{
      write
      | definitions: definitions,
        tables:
          Map.new(write.tables, fn {id, table} -> {id, %{table | storage_mode: :physical}} end)
    }

    with {:ok, write} <- populate_promoted(write, records),
         {:ok, write} <- convert_links(write, converted) do
      links
      |> Enum.reject(fn field -> Enum.any?(old_links, &(&1.id == field.id)) end)
      |> Enum.reduce_while({:ok, write}, fn field, {:ok, write} ->
        case Links.initialize_field(write, field) do
          :ok -> {:cont, {:ok, write}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp populate_promoted(write, records) do
    Enum.reduce_while(records, {:ok, write}, fn {id, {:json, json}}, {:ok, write} ->
      result =
        Enum.reduce_while(Torque.decode!(json), {:ok, write}, fn row, {:ok, write} ->
          case Links.maintain(write, write.definitions[id], %{}, row["data"], row["id"]) do
            {:ok, write} -> {:cont, {:ok, write}}
            error -> {:halt, error}
          end
        end)

      case result do
        {:ok, write} -> {:cont, {:ok, write}}
        error -> {:halt, error}
      end
    end)
  end

  defp convert_links(write, converted) do
    fields = write.definitions |> Map.values() |> List.flatten()
    fields = Enum.filter(fields, &(&1.type == :link and Map.has_key?(converted, &1.id)))

    Enum.reduce_while(fields, {:ok, write}, fn field, {:ok, write} ->
      result =
        Ecto.Adapters.SQL.stream(
          BaseRepo.get_dynamic_repo(),
          """
          SELECT source.id::text,source.data,#{Links.expression(field, "r")}
          FROM pg_temp.ankole_base_conversions source
          JOIN #{BaseRepo.table(field.table_id)} r ON r.id=source.id WHERE source.field_id=$1
          """,
          [field.id],
          max_rows: 100
        )
        |> Enum.reduce_while({:ok, write}, fn %{rows: rows}, {:ok, write} ->
          result =
            Enum.reduce_while(rows, {:ok, write}, fn [id, data, before], {:ok, write} ->
              case convert_link(write, field, %{field.id => before}, %{id: id, data: data}) do
                {:ok, write} -> {:cont, {:ok, write}}
                error -> {:halt, error}
              end
            end)

          case result do
            {:ok, write} ->
              Links.bump_field!(write, field, Enum.map(rows, &hd/1))
              {:cont, {:ok, write}}

            error ->
              {:halt, error}
          end
        end)

      case result do
        {:ok, write} -> {:cont, {:ok, write}}
        error -> {:halt, error}
      end
    end)
  end

  defp convert_link(write, field, before, row) do
    case Links.maintain(write, [field], before, row.data, row.id) do
      {:error, :invalid_link} ->
        if write.conversions[field.id].clear do
          Links.maintain(write, [field], before, %{field.id => nil}, row.id)
        else
          {:error, {:conversion_failed, [row.id]}}
        end

      result ->
        result
    end
  end
end
