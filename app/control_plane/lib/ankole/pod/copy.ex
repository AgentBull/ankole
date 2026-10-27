defmodule Ankole.Pod.Copy do
  @moduledoc """
  Copies a Base table, its schema, records, and attachments to a new page.

  The copy runs in one top-level transaction. Records move in bounded batches
  through transaction-local SQL storage.
  Source metadata locks keep the copy stable across batches.
  """
  require Ash.Query
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :tenant_schema
  alias Ankole.{Files, Repo}
  alias __MODULE__.Projection
  alias Ankole.Pod.Bases.{Physical, Promote}

  alias Ankole.Pod.{
    Access,
    Config,
    Bases,
    BaseField,
    BaseTable,
    BaseView,
    BaseRepo,
    Formula,
    Pages,
    Query
  }

  def table(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write_tree(authority, fn -> table_in_tx(actor, id, attrs) end,
      timeout: 60_000,
      after_commit: &committed/1
    )
  end

  @doc "Publishes a committed copy: the tree changed and the new page exists."
  def committed(%{page: page}) do
    Pages.broadcast_access()
    Pages.broadcast(page.id)
  end

  @doc false
  def table_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    Pages.lock_tree()

    with {:ok, candidate} <- Bases.fetch_table(id),
         locked <-
           BaseTable
           |> Ash.Query.filter(page_id == ^candidate.page_id and is_nil(deleting_at))
           |> Ash.Query.sort(id: :asc)
           |> Ash.Query.lock(:for_update)
           |> Ankole.Ash.read!(),
         %BaseTable{} = source <- Enum.find(locked, &(&1.id == candidate.id)),
         {:ok, source} <- Bases.table_access(actor, source, :read),
         {:ok, limits} <- Config.limits(),
         {:ok, timezone} <- Ankole.SystemConfig.timezone(),
         {:ok, _} <- Repo.query("SELECT set_config('TimeZone',$1,true)", [timezone]),
         {:ok, page} <-
           Pages.create_in_tx(actor, %{
             type: "base",
             skip_default_table: true,
             title: Ankole.Attrs.get(attrs, :title, source.name),
             parent_id: Ankole.Attrs.get(attrs, :parent_id),
             private_owner_uid: Ankole.Attrs.get(attrs, :private_owner_uid)
           }),
         {:ok, target} <-
           Ankole.Ash.create(BaseTable, :create_in_tx, %{
             page_id: page.id,
             name: source.name,
             position: Ankole.Ecto.UUIDv7.autogenerate()
           }),
         definitions <- Bases.fields(source.id),
         {:ok, links} <- link_targets(actor, definitions),
         {:ok, copied_fields, mapping} <- copy_fields(definitions, target),
         options = %{
           filter: Ankole.Attrs.get(attrs, :filter),
           timezone: timezone,
           links: links,
           formula_ids: materialized_formulas(definitions, copied_fields)
         },
         :ok <-
           copy_views(
             source.id,
             target.id,
             mapping,
             changed_value_types(definitions, copied_fields)
           ),
         :ok <- Projection.begin_stage(),
         {:ok, counters} <-
           stage_records(actor, source, target, definitions, copied_fields, limits, options),
         {:ok, target} <- Ankole.Ash.update(target, :initialize_copy, counters),
         {:ok, target} <- store_records(target, copied_fields, timezone) do
      Projection.end_stage()
      {:ok, %{page: page, table: target}}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp copy_fields(definitions, table) do
    mapping = Map.new(definitions, &{&1.id, Ankole.Ecto.UUIDv7.autogenerate()})

    with {:ok, ordered} <- Formula.validate_all(definitions),
         {:ok, checked} <- copied_definitions(ordered, table.id, mapping) do
      by_id = Map.new(checked, &{&1.id, &1})

      Enum.reduce_while(definitions, {:ok, []}, fn field, {:ok, copied} ->
        attrs =
          by_id[mapping[field.id]]
          |> Map.take([:id, :table_id, :name, :type, :config, :position, :is_primary])

        case Ankole.Ash.create(BaseField, :create_in_tx, attrs) do
          {:ok, new} -> {:cont, {:ok, [new | copied]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, copied} -> {:ok, Enum.reverse(copied), mapping}
        error -> error
      end
    end
  end

  defp copied_definitions(ordered, table_id, mapping) do
    Enum.reduce_while(ordered, {:ok, []}, fn field, {:ok, copied} ->
      {type, config} = copy_field(field, mapping)
      candidate = %{field | id: mapping[field.id], table_id: table_id, type: type, config: config}

      case Formula.validate_all([candidate | copied]) do
        {:ok, checked} ->
          {:cont, {:ok, checked}}

        {:error, :formula_type} when candidate.type == :formula ->
          # The source was valid. Keep its result when the copied dependency
          # types cannot support the same formula.
          materialized = %{candidate | type: snapshot_type(field), config: %{}}
          {:cont, {:ok, [materialized | copied]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp snapshot_type(field) do
    case Formula.type(field) do
      :array -> :text
      :boolean -> :checkbox
      type -> type
    end
  end

  defp changed_value_types(fields, copied) do
    fields
    |> Enum.zip(copied)
    |> Enum.filter(fn {old, new} -> Formula.type(old) != Formula.type(new) end)
    |> MapSet.new(fn {old, _new} -> old.id end)
  end

  defp materialized_formulas(fields, copied) do
    fields
    |> Enum.zip(copied)
    |> Enum.filter(fn {old, new} -> old.type == :formula and new.type != :formula end)
    |> Enum.map(fn {old, _new} -> old.id end)
  end

  defp copy_field(%{type: :formula, config: config}, mapping),
    do: {:formula, Map.update!(config, "ast", &Formula.remap_references(&1, mapping))}

  defp copy_field(%{type: :link}, _mapping), do: {:text, %{}}

  defp copy_field(%{type: type, config: config}, _mapping) do
    type =
      case type do
        kind when kind in [:created_at, :updated_at] -> :datetime
        kind when kind in [:created_by, :updated_by] -> :text
        kind -> kind
      end

    {type, config}
  end

  defp link_targets(actor, fields) do
    fields
    |> Enum.filter(&(&1.type == :link))
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, links} ->
      with {:ok, table} <- Bases.table_access(actor, field.config["table_id"], :read),
           primary when not is_nil(primary) <- Enum.find(Bases.fields(table.id), & &1.is_primary) do
        {:cont, {:ok, [{field, table, primary} | links]}}
      else
        nil -> {:halt, {:error, :not_found}}
        error -> {:halt, error}
      end
    end)
  end

  defp copy_views(source_id, target_id, mapping, changed_types) do
    Enum.reduce_while(
      Ankole.Ash.read!(Ash.Query.filter(BaseView, table_id == ^source_id)),
      :ok,
      fn view, :ok ->
        attrs = %{
          table_id: target_id,
          name: view.name,
          type: view.type,
          config: remap_view(view.config, mapping, changed_types),
          position: view.position
        }

        case Ankole.Ash.create(BaseView, :create_in_tx, attrs) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    )
  end

  defp snapshot(table, fields, options) do
    fun = fn current ->
      with {:ok, snapshot} <-
             Query.records(
               current,
               fields,
               %{filter: options.filter, page_token: options[:page_token], page_size: 100},
               max_limit: 100,
               raw_json: true,
               formula_ids: options.formula_ids
             ),
           do: materialize_links(snapshot, options.links)
    end

    if table.storage_mode == :physical do
      BaseRepo.run(
        BaseRepo.shard!(),
        fn ->
          with {:ok, current} <- Physical.state(table), do: fun.(current)
        end,
        read_only: true,
        timezone: options.timezone,
        deadline: Access.deadline()
      )
    else
      fun.(table)
    end
  end

  # Read only the linked labels in this batch. Keep the JSON text in PostgreSQL
  # so a copy does not round numeric cells through an Elixir float.
  defp materialize_links(snapshot, links) do
    Enum.reduce_while(links, {:ok, snapshot}, fn {field, table, primary}, {:ok, snapshot} ->
      payload = "[" <> Enum.join(snapshot.records, ",") <> "]"

      result =
        BaseRepo.query(
          """
          SELECT jsonb_set(record, ARRAY['data', $2::text], COALESCE((
            SELECT to_jsonb(string_agg(COALESCE(target.#{BaseRepo.column(primary.id)}, ''), ', ' ORDER BY ref.position))
            FROM jsonb_array_elements_text(COALESCE(NULLIF(record->'data'->$2::text, 'null'::jsonb), '[]'::jsonb))
              WITH ORDINALITY AS ref(id, position)
            JOIN #{BaseRepo.table(table.id)} target ON target.id=ref.id::uuid
          ), 'null'::jsonb), true)::text
          FROM jsonb_array_elements($1::text::jsonb) WITH ORDINALITY AS source(record, position)
          ORDER BY source.position
          """,
          [payload, field.id]
        )

      case result do
        {:ok, %{rows: rows}} -> {:cont, {:ok, %{snapshot | records: Enum.map(rows, &hd/1)}}}
        error -> {:halt, error}
      end
    end)
  end

  defp stage_records(actor, source, target, fields, copied, limits, options) do
    with {:ok, snapshot} <- snapshot(source, fields, options),
         {:ok, payload, counters} <-
           Projection.records(actor, snapshot, source, target, fields, copied, limits),
         :ok <- copy_attachments(source, target, payload, copied),
         :ok <- Projection.stage(payload) do
      if snapshot.complete do
        {:ok, counters}
      else
        with {:ok, rest} <-
               stage_records(
                 actor,
                 source,
                 target,
                 fields,
                 copied,
                 limits,
                 Map.put(options, :page_token, snapshot.page_token)
               ) do
          {:ok,
           %{
             record_count: counters.record_count + rest.record_count,
             record_bytes: counters.record_bytes + rest.record_bytes,
             next_auto_number: max(counters.next_auto_number, rest.next_auto_number)
           }}
        end
      end
    end
  end

  defp store_records(table, fields, timezone) do
    if Bases.inline?(table) do
      with {:ok, _} <-
             Repo.query(
               """
               INSERT INTO base_records(tenant_id,table_id,id,data,versions,created_by,created_at,updated_by,updated_at)
               SELECT $1::text::uuid,$2::text::uuid,source.id,source.record->'data',source.record->'versions',
                 source.record->>'created_by',(source.record->>'created_at')::timestamptz,
                 source.record->>'updated_by',(source.record->>'updated_at')::timestamptz
               FROM pg_temp.ankole_base_copy source
               """,
               [Repo.tenant_id!(), table.id]
             ),
           do: {:ok, table}
    else
      table = %{table | storage_mode: :physical, schema_version: table.schema_version + 1}

      with {:ok, :ok} <-
             BaseRepo.run(
               BaseRepo.shard!(),
               fn ->
                 Physical.create_table!(table, fields, [])

                 Enum.each(
                   Projection.batches(),
                   &Physical.insert_rows!(table, fields, {:json, &1})
                 )

                 {:ok, :ok}
               end,
               ddl: true,
               timezone: timezone,
               deadline: Access.deadline()
             ),
           do: Promote.commit(table)
    end
  end

  defp copy_attachments(source, target, payload, fields) do
    fields = Enum.filter(fields, &(&1.type == :attachment))
    paths = Projection.attachment_paths(payload, Enum.map(fields, & &1.id))

    paths
    |> Enum.chunk_every(200)
    |> Enum.reduce_while(:ok, fn paths, :ok ->
      by_source =
        Map.new(paths, fn path ->
          {String.replace_prefix(
             path,
             Ankole.Pod.Files.prefix(target.page_id) <> "/",
             Ankole.Pod.Files.prefix(source.page_id) <> "/"
           ), path}
        end)

      with {:ok, files} <- Files.fetch_many(:pod, Map.keys(by_source)),
           true <- length(files) == map_size(by_source),
           upserts <-
             Enum.map(files, fn file ->
               %{
                 path: Map.fetch!(by_source, file.path),
                 sha256: Base.encode16(file.sha256, case: :lower),
                 content_type: file.content_type,
                 mode: file.mode,
                 source: "pod"
               }
             end),
           {:ok, _} <- Files.commit_in_tx(:pod, upserts, []) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :not_found}}
        error -> {:halt, error}
      end
    end)
  end

  defp remap_view(config, mapping, changed_types) do
    Map.new(config, fn
      {key, id} when key in ~w(group_field_id cover_field_id) ->
        {key, Map.get(mapping, id, id)}

      {key, ids} when key == "visible_fields" and is_list(ids) ->
        {key, Enum.map(ids, &Map.get(mapping, &1, &1))}

      {"filter", %{"conditions" => conditions} = filter} when is_list(conditions) ->
        conditions =
          Enum.reject(conditions, fn condition ->
            MapSet.member?(changed_types, condition["field_id"]) and
              condition["operator"] not in ["is_empty", "is_not_empty"]
          end)

        {"filter",
         Map.put(filter, "conditions", Enum.map(conditions, &remap_field_id(&1, mapping)))}

      {"sort", sort} when is_list(sort) ->
        {"sort", Enum.map(sort, &remap_field_id(&1, mapping))}

      entry ->
        entry
    end)
  end

  defp remap_field_id(config, mapping) when is_map(config) do
    case Map.fetch(config, "field_id") do
      {:ok, id} -> Map.put(config, "field_id", Map.get(mapping, id, id))
      :error -> config
    end
  end

  defp remap_field_id(config, _mapping), do: config
end

# This projection reads JSON parameters and transaction-local staging rows.
defmodule Ankole.Pod.Copy.Projection do
  @moduledoc false
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :site
  alias Ankole.Repo
  alias Ankole.Pod.Formula
  alias Ankole.Pod.Values

  def begin_stage do
    Repo.query!(
      "CREATE TEMP TABLE pg_temp.ankole_base_copy (id uuid PRIMARY KEY, record jsonb NOT NULL) ON COMMIT DROP",
      []
    )

    :ok
  end

  def stage(payload) do
    Repo.query!(
      "INSERT INTO pg_temp.ankole_base_copy SELECT (record->>'id')::uuid,record FROM jsonb_array_elements($1::text::jsonb) record",
      [payload]
    )

    :ok
  end

  def batches do
    Ecto.Adapters.SQL.stream(
      Repo,
      "SELECT record::text FROM pg_temp.ankole_base_copy ORDER BY id",
      [],
      max_rows: 100
    )
    |> Stream.map(fn result -> "[" <> Enum.map_join(result.rows, ",", &hd/1) <> "]" end)
  end

  def end_stage, do: Repo.query!("DROP TABLE pg_temp.ankole_base_copy", [])

  def records(actor, snapshot, source, target, fields, copied, limits) do
    payload = "[" <> Enum.join(snapshot.records, ",") <> "]"
    ids = Enum.map(snapshot.records, fn _ -> Ankole.Ecto.UUIDv7.autogenerate() end)

    author =
      to_string(Ankole.ActorRef.from_writer(Ankole.AuthZ.Actor.uid(actor), Repo.tenant_id!(), []))

    params = [payload, ids, author]

    {data, params} =
      Enum.zip(fields, copied)
      |> Enum.reject(fn {_field, new} -> new.type == :formula end)
      |> Enum.reduce({"'{}'::jsonb", params}, fn {field, new}, {data, params} ->
        {old_key, params} = Formula.bind(params, field.id)
        {new_key, params} = Formula.bind(params, new.id)

        value =
          if field.type in [:created_at, :updated_at, :created_by, :updated_by],
            do: "to_jsonb(r.#{field.type})",
            else: "r.data->#{old_key}::text"

        value =
          if field.type == :formula and field.config["result_type"] == "array" do
            "to_jsonb(NULLIF(#{value}, 'null'::jsonb)::text)"
          else
            value
          end

        {value, params} =
          if field.type == :attachment do
            {old_prefix, params} =
              Formula.bind(params, Ankole.Pod.Files.prefix(source.page_id) <> "/attachments/")

            {new_prefix, params} =
              Formula.bind(params, Ankole.Pod.Files.prefix(target.page_id) <> "/attachments/")

            {"(SELECT jsonb_agg(item || jsonb_build_object('path',replace(item->>'path',#{old_prefix}::text,#{new_prefix}::text))) FROM jsonb_array_elements(#{value}) item)",
             params}
          else
            {value, params}
          end

        # Keep every bound parameter typed, including system fields.
        value = "CASE WHEN #{old_key}::text IS NOT NULL THEN #{value} END"
        {data <> " || jsonb_build_object(#{new_key}::text, #{value})", params}
      end)

    auto = Enum.find(copied, &(&1.type == :auto_number))
    {auto_key, params} = Formula.bind(params, if(auto, do: auto.id))

    with {:ok, %{rows: [[json, count, bytes, next, largest]]}} <-
           Repo.query(
             """
             WITH selected AS (
               SELECT row_number() OVER (ORDER BY r.id) AS n,jsonb_strip_nulls(#{data}) AS data
               FROM jsonb_to_recordset($1::text::jsonb) AS r(id text,data jsonb,created_at text,updated_at text,created_by text,updated_by text)
             ), copied AS (
               SELECT ($2::text[])[n::int] AS id,data,
                 COALESCE((SELECT jsonb_object_agg(key,1) FROM jsonb_object_keys(data) AS key),'{}'::jsonb) AS versions,
                 $3::text AS created_by,now() AS created_at,$3::text AS updated_by,now() AS updated_at FROM selected
             )
             SELECT COALESCE(jsonb_agg(to_jsonb(copied)),'[]'::jsonb)::text,count(*),
               COALESCE(sum(octet_length(data::text)),0)::bigint,
               COALESCE(max((data->>#{auto_key}::text)::numeric),0)::bigint+1,
               COALESCE(max(octet_length(data::text)),0) FROM copied
             """,
             params
           ) do
      with :ok <- validate_sizes(json, largest, limits) do
        {:ok, json, %{record_count: count, record_bytes: bytes, next_auto_number: next}}
      end
    end
  end

  defp validate_sizes(_json, largest, limits)
       when largest <= :erlang.map_get("record_bytes", limits), do: :ok

  defp validate_sizes(json, _largest, limits) do
    Repo.query!(
      "SELECT data FROM jsonb_to_recordset($1::text::jsonb) AS r(data jsonb) WHERE octet_length(data::text)>$2",
      [json, limits["record_bytes"]]
    ).rows
    |> Enum.reduce_while(:ok, fn [data], :ok ->
      case Values.record_size(data, limits) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def attachment_paths(payload, ids) do
    Repo.query!(
      """
      SELECT DISTINCT item->>'path'
      FROM jsonb_to_recordset($1::text::jsonb) AS r(data jsonb)
      CROSS JOIN LATERAL jsonb_each(r.data) f
      CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN f.key=ANY($2::text[]) THEN f.value ELSE '[]'::jsonb END) item
      WHERE f.key=ANY($2::text[])
      """,
      [payload, ids]
    ).rows
    |> Enum.map(&hd/1)
  end
end
