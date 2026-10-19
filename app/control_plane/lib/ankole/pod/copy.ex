defmodule Ankole.Pod.Copy do
  @moduledoc false
  import Ecto.Query
  alias Ankole.{Files, Repo}
  alias Ankole.Pod.Database.Write

  alias Ankole.Pod.{
    Access,
    Config,
    Database,
    DbField,
    DbTable,
    DbView,
    Formula,
    Pages,
    Query
  }

  def table(uid, id, attrs, authority \\ nil) do
    result =
      Access.write_transaction(authority, fn _repo ->
        Pages.lock_tree()

        with {:ok, source} <- Database.table_access(uid, id, "page_view"),
             _locked <-
               Repo.all(
                 from t in DbTable,
                   where: t.page_id == ^source.page_id,
                   order_by: t.id,
                   lock: "FOR UPDATE"
               ),
             {:ok, limits} <- Config.limits(),
             {:ok, timezone} <- Ankole.SystemConfig.timezone(),
             {:ok, _} <- Repo.query("SELECT set_config('TimeZone',$1,true)", [timezone]),
             {:ok, page} <-
               Pages.create(uid, %{
                 type: "database",
                 title: Ankole.Attrs.get(attrs, :title, source.name),
                 parent_id: Ankole.Attrs.get(attrs, :parent_id),
                 private_owner_uid: Ankole.Attrs.get(attrs, :private_owner_uid)
               }),
             {:ok, target} <-
               Repo.insert(
                 DbTable.changeset(%DbTable{}, %{
                   page_id: page.id,
                   name: source.name,
                   position: Ankole.Ecto.UUIDv7.autogenerate()
                 })
               ),
             definitions <- Database.fields(source.id),
             {:ok, copied_fields, mapping} <- copy_fields(definitions, target),
             :ok <- copy_views(source.id, target.id, mapping),
             {:ok, count} <-
               copy_records(
                 uid,
                 source,
                 target,
                 definitions,
                 copied_fields,
                 Ankole.Attrs.get(attrs, :filter),
                 limits
               ),
             :ok <- copy_attachments(source, target),
             {:ok, target} <- update_count(target, count, copied_fields) do
          {:ok, %{page: page, table: target}}
        end
      end)

    case result do
      {:ok, %{page: page}} ->
        Pages.broadcast_access()
        Pages.broadcast(page.id)

      _ ->
        :ok
    end

    result
  end

  defp copy_fields(definitions, table) do
    mapping = Map.new(definitions, &{&1.id, Ankole.Ecto.UUIDv7.autogenerate()})

    Enum.reduce_while(definitions, {:ok, [], mapping}, fn field, {:ok, copied, mapping} ->
      with {:ok, type, config} <- copy_field(field, mapping) do
        attrs = %{
          id: mapping[field.id],
          table_id: table.id,
          name: field.name,
          type: type,
          config: config,
          position: field.position,
          is_primary: field.is_primary
        }

        case Repo.insert(DbField.changeset(%DbField{}, attrs)) do
          {:ok, new} -> {:cont, {:ok, [new | copied], mapping}}
          error -> {:halt, error}
        end
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, copied, mapping} -> {:ok, Enum.reverse(copied), mapping}
      error -> error
    end
  end

  defp copy_field(%{type: :formula, config: config}, mapping),
    do: {:ok, :formula, Map.update!(config, "ast", &Formula.remap_references(&1, mapping))}

  defp copy_field(%{type: :link, config: config}, _mapping) do
    target_id = config["table_id"]
    fields = Database.fields(target_id)
    primary = Enum.find(fields, & &1.is_primary)

    with {:ok, title, _type, params} <-
           Formula.expression(primary, fields, [Repo.tenant_id!(), target_id]),
         {:ok, result} <-
           Repo.query(
             "SELECT r.id::text, COALESCE((#{title})::text, '') FROM db_records r WHERE r.tenant_id=$1::text::uuid AND r.table_id=$2::text::uuid ORDER BY r.id",
             params
           ) do
      options = Enum.map(result.rows, fn [id, name] -> %{"id" => id, "name" => name} end)
      {:ok, :select, %{"multiple" => true, "options" => options}}
    end
  end

  defp copy_field(%{type: type, config: config}, _mapping) do
    type =
      case type do
        kind when kind in [:created_at, :updated_at] -> :datetime
        kind when kind in [:created_by, :updated_by] -> :text
        kind -> kind
      end

    {:ok, type, config}
  end

  defp copy_views(source_id, target_id, mapping) do
    Enum.reduce_while(Repo.all(from v in DbView, where: v.table_id == ^source_id), :ok, fn view,
                                                                                           :ok ->
      attrs = %{
        table_id: target_id,
        name: view.name,
        type: view.type,
        config: remap_view(view.config, mapping),
        position: view.position
      }

      case Repo.insert(DbView.changeset(%DbView{}, attrs)) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp copy_records(uid, source, target, fields, copied, filter, limits) do
    with {:ok, where, params} <- Query.filter(fields, filter, [Repo.tenant_id!(), source.id]),
         {:ok, %{rows: [[count]]}} <-
           Repo.query(
             "SELECT count(*) FROM db_records r WHERE r.tenant_id=$1::text::uuid AND r.table_id=$2::text::uuid AND (#{where})",
             params
           ),
         {:ok, data_sql, params} <- data_expression(source, target, fields, copied, params) do
      ids = for _ <- 1..count//1, count > 0, do: Ankole.Ecto.UUIDv7.autogenerate()
      {target_param, params} = Formula.bind(params, target.id)
      {ids_param, params} = Formula.bind(params, ids)

      {author_param, params} =
        Formula.bind(params, to_string(Ankole.ActorRef.from_writer(uid, Repo.tenant_id!(), [])))

      sql = """
      WITH selected AS (
        SELECT row_number() OVER (ORDER BY r.id) AS row_num, jsonb_strip_nulls(#{data_sql}) AS data
        FROM db_records r
        WHERE r.tenant_id=$1::text::uuid AND r.table_id=$2::text::uuid AND (#{where})
      )
      INSERT INTO db_records (tenant_id,table_id,id,data,versions,created_by,created_at,updated_by,updated_at)
      SELECT $1::text::uuid,#{target_param}::text::uuid,(#{ids_param}::text[]::uuid[])[row_num::int],data,
        COALESCE((SELECT jsonb_object_agg(key,1) FROM jsonb_object_keys(data) AS key),'{}'::jsonb),
        #{author_param}::text,now(),#{author_param}::text,now() FROM selected
      """

      with {:ok, _} <- Repo.query(sql, params) do
        with :ok <- validate_record_sizes(target.id, limits), do: {:ok, count}
      end
    end
  end

  defp validate_record_sizes(table_id, limits) do
    Ecto.Adapters.SQL.stream(
      Repo,
      "SELECT data FROM db_records WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid",
      [Repo.tenant_id!(), table_id],
      max_rows: 200
    )
    |> Stream.flat_map(& &1.rows)
    |> Enum.reduce_while(:ok, fn [data], :ok ->
      case Write.record_size(data, limits) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp data_expression(source, target, fields, copied, params) do
    Enum.zip(fields, copied)
    |> Enum.reject(fn {field, _new} -> field.type == :formula end)
    |> Enum.reduce_while({:ok, "'{}'::jsonb", params}, fn {field, new}, {:ok, result, params} ->
      with {:ok, expr, _type, params} <- Formula.expression(field, fields, params),
           {:ok, expr, params} <- copy_expression(field, expr, source, target, params) do
        {key, params} = Formula.bind(params, new.id)
        {:cont, {:ok, result <> " || jsonb_build_object(#{key}::text, #{expr})", params}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp copy_expression(%{type: :attachment}, expr, source, target, params) do
    {old, params} = Formula.bind(params, "pages/#{source.page_id}/attachments/")
    {new, params} = Formula.bind(params, "pages/#{target.page_id}/attachments/")

    {:ok,
     "(SELECT jsonb_agg(item || jsonb_build_object('path',replace(item->>'path',#{old}::text,#{new}::text))) FROM jsonb_array_elements(#{expr}) item)",
     params}
  end

  defp copy_expression(_field, expr, _source, _target, params), do: {:ok, expr, params}

  defp copy_attachments(source, target) do
    fields = Database.fields(target.id) |> Enum.filter(&(&1.type == :attachment))

    paths =
      Repo.query!(
        """
        SELECT DISTINCT item->>'path'
        FROM db_records r CROSS JOIN LATERAL jsonb_each(r.data) f
        CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN f.key=ANY($3::text[]) THEN f.value ELSE '[]'::jsonb END) item
        WHERE r.tenant_id=$1::text::uuid AND r.table_id=$2::text::uuid
          AND f.key=ANY($3::text[])
        """,
        [Repo.tenant_id!(), target.id, Enum.map(fields, & &1.id)]
      ).rows
      |> Enum.map(&hd/1)

    paths
    |> Enum.chunk_every(200)
    |> Enum.reduce_while(:ok, fn paths, :ok ->
      by_source =
        Map.new(paths, fn path ->
          {String.replace_prefix(path, "pages/#{target.page_id}/", "pages/#{source.page_id}/"),
           path}
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
           {:ok, _} <- Files.commit(Repo, :pod, upserts, []) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :not_found}}
        error -> {:halt, error}
      end
    end)
  end

  defp update_count(table, count, fields) do
    auto = Enum.find(fields, &(&1.type == :auto_number))

    next =
      if auto do
        Repo.query!(
          "SELECT COALESCE(max((data->>$3::text)::numeric),0)::bigint+1 FROM db_records WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid",
          [Repo.tenant_id!(), table.id, auto.id]
        ).rows
        |> hd()
        |> hd()
      else
        1
      end

    Repo.update(
      DbTable.changeset(table, %{record_count: count, next_auto_number: next, data_version: 1})
    )
  end

  defp remap_view(config, mapping) do
    Map.new(config, fn
      {key, id} when key in ~w(group_field_id cover_field_id) ->
        {key, Map.get(mapping, id, id)}

      {key, ids} when key == "visible_fields" and is_list(ids) ->
        {key, Enum.map(ids, &Map.get(mapping, &1, &1))}

      {"filter", %{"conditions" => conditions} = filter} when is_list(conditions) ->
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
