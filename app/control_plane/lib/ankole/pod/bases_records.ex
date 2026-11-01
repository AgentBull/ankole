defmodule Ankole.Pod.Bases.Records do
  @moduledoc """
  Applies record batches to their table's storage transaction.

  Inline records use `Ankole.Pod.BaseRecord`; physical records use native shard
  columns and edge tables. Ash owns the table and field definitions.
  """
  import Ecto.Query
  alias Ankole.{ActorRef, Repo}
  alias Ankole.Pod.{BaseRecord, Query, Values}
  alias Ankole.Pod.Bases.{Write, Physical, Links}

  @doc "Rewrites inline authors and user fields during the Principal rename transaction."
  def rename_principal_in_tx(table, fields, {identity_tenant, old_uid}, new_uid) do
    tenant = Repo.tenant_id!()
    old_actor = to_string(ActorRef.from_principal(%{tenant_id: identity_tenant, uid: old_uid}))
    new_actor = to_string(ActorRef.from_principal(%{tenant_id: identity_tenant, uid: new_uid}))

    authors =
      Repo.query!(
        "UPDATE base_records SET created_by=CASE WHEN created_by=$3 THEN $4 ELSE created_by END, updated_by=CASE WHEN updated_by=$3 THEN $4 ELSE updated_by END WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid AND (created_by=$3 OR updated_by=$3)",
        [tenant, table.id, old_actor, new_actor]
      ).num_rows

    users =
      for field <- fields, field.type == :user do
        Repo.query!(
          """
          UPDATE base_records SET
            data=jsonb_set(data,ARRAY[$3::text],
              (SELECT jsonb_agg(CASE WHEN value=$4 THEN $5 ELSE value END ORDER BY n)
               FROM jsonb_array_elements_text(data->$3) WITH ORDINALITY AS item(value,n)),false),
            versions=jsonb_set(versions,ARRAY[$3::text],to_jsonb(COALESCE((versions->>$3)::bigint,0)+1))
          WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid AND (data->$3) ? $4
          """,
          [tenant, table.id, field.id, old_uid, new_uid]
        ).num_rows
      end

    if authors + Enum.sum(users) == 0 do
      {:ok, []}
    else
      %Write{table: table, tables: %{table.id => table}}
      |> Write.touch(table.id, resync: true)
      |> Write.finish()
    end
  end

  def prepare(write, attrs) when is_map(attrs) do
    creates = Ankole.Attrs.get(attrs, :creates, [])
    updates = Ankole.Attrs.get(attrs, :updates, [])
    deletes = Ankole.Attrs.get(attrs, :deletes, [])

    if is_list(creates) and is_list(updates) and is_list(deletes) and
         (length(creates) + length(updates) + length(deletes)) in 1..200 and
         Enum.all?(creates ++ updates ++ deletes, &is_map/1) do
      fields = Map.fetch!(write.definitions, write.table.id)

      with {:ok, creates} <- prepare_rows(creates, fields, write.table.page_id, %{}),
           {:ok, updates} <- prepare_rows(updates, fields, write.table.page_id, nil),
           do: {:ok, %{creates: creates, updates: updates, deletes: deletes}}
    else
      {:error, :invalid_record_batch}
    end
  end

  def prepare(_, _), do: {:error, :invalid_record_batch}

  defp prepare_rows(rows, fields, page, default) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, prepared} ->
      case Values.patch(Ankole.Attrs.get(row, :data, default), fields, page) do
        {:ok, patch} ->
          {:cont, {:ok, [row |> Map.delete("data") |> Map.put(:data, patch) | prepared]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  def batch(write, %{creates: creates, updates: updates, deletes: deletes}) do
    definitions = Map.fetch!(write.definitions, write.table.id)

    with {:ok, created, write} <- create(write, creates, definitions),
         {:ok, updated, write} <- update_records(write, updates, definitions),
         {:ok, write} <- delete(write, deletes),
         {:ok, changes} <- Write.finish(Write.touch(write, write.table.id)),
         ids <- Enum.uniq(Enum.reverse(created) ++ Enum.reverse(updated)),
         {:ok, records} <- project(write.table, definitions, ids) do
      {:ok, Write.result(changes, write.table.id) |> Map.put(:records, records)}
    end
  end

  defp create(write, attrs, definitions) do
    attrs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], write}, fn {attrs, index}, {:ok, ids, write} ->
      with id <- Ankole.Attrs.get(attrs, :id, Ankole.Ecto.UUIDv7.autogenerate()),
           patch <-
             Enum.reduce(definitions, attrs.data, fn field, acc ->
               if field.type == :auto_number,
                 do: Map.put(acc, field.id, write.table.next_auto_number + index),
                 else: acc
             end),
           clean <- Values.clean(patch),
           :ok <- Values.record_size(clean, write.limits),
           {:ok, record} <-
             %{
               id: id,
               table_id: write.table.id,
               data: clean,
               versions: Map.new(Map.keys(patch), &{&1, 1}),
               created_by: author(write),
               updated_by: author(write),
               created_at: DateTime.utc_now(:microsecond),
               updated_at: DateTime.utc_now(:microsecond)
             }
             |> BaseRecord.create_changeset()
             |> persist(write, :insert),
           write <-
             Write.touch(write, write.table.id, changed: [record.id], delta: 1, inserted: 1),
           {:ok, write} <- maintain_links(write, definitions, %{}, record.data, record.id) do
        {:cont, {:ok, [record.id | ids], write}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp update_records(write, attrs, definitions) do
    Enum.reduce_while(attrs, {:ok, [], write}, fn attrs, {:ok, ids, write} ->
      with {:ok, record} <- fetch(write, Ankole.Attrs.get(attrs, :id)),
           data <- Ankole.Attrs.get(attrs, :data),
           expected <- Ankole.Attrs.get(attrs, :expected_versions),
           true <- is_map(data) and map_size(data) > 0 and is_map(expected),
           :ok <- field_cas(record, data, expected),
           merged <- Map.merge(record.data, data) |> Values.clean(),
           :ok <- Values.record_size(merged, write.limits),
           {:ok, saved} <-
             record
             |> BaseRecord.update_values_changeset(%{
               data: merged,
               versions:
                 Enum.reduce(
                   Map.keys(data),
                   record.versions,
                   &Map.update(&2, &1, 1, fn v -> v + 1 end)
                 ),
               updated_by: author(write),
               updated_at: DateTime.utc_now(:microsecond)
             })
             |> persist(write, :update),
           write <- Write.touch(write, write.table.id, changed: [record.id]),
           {:ok, write} <- maintain_links(write, definitions, record.data, saved.data, record.id) do
        {:cont, {:ok, [record.id | ids], write}}
      else
        false -> {:halt, {:error, :expected_versions_required}}
        error -> {:halt, error}
      end
    end)
  end

  defp delete(write, []), do: {:ok, write}

  defp delete(write, attrs) do
    Enum.reduce_while(attrs, {:ok, write}, fn attrs, {:ok, write} ->
      with {:ok, record} <- fetch(write, Ankole.Attrs.get(attrs, :id)),
           true <- Ankole.Attrs.get(attrs, :expected_versions) == record.versions,
           {:ok, write} <- clean_incoming(write, record.id),
           {:ok, _} <- delete_record(write, record) do
        {:cont, {:ok, Write.touch(write, write.table.id, deleted: [record.id], delta: -1)}}
      else
        false -> {:halt, {:error, {:record_conflict, Ankole.Attrs.get(attrs, :id)}}}
        error -> {:halt, error}
      end
    end)
  end

  defp field_cas(record, data, expected) do
    conflicts =
      Enum.uniq(Map.keys(data) ++ Map.keys(expected))
      |> Enum.filter(&(Map.get(record.versions, &1) != Map.get(expected, &1)))

    if conflicts == [],
      do: :ok,
      else:
        {:error,
         {:field_conflict,
          %{
            id: record.id,
            fields: conflicts,
            data: Map.take(record.data, conflicts),
            versions: Map.take(record.versions, conflicts)
          }}}
  end

  def maintain_links(
        %{table: %{storage_mode: :physical}} = write,
        fields,
        before,
        after_data,
        id
      ),
      do: Links.maintain(write, fields, before, after_data, id)

  def maintain_links(write, _fields, _before, _after, _id), do: {:ok, write}

  defp clean_incoming(%{table: %{storage_mode: :physical}} = write, id),
    do: Links.clean_incoming(write, id)

  defp clean_incoming(write, _id), do: {:ok, write}
  defp delete_record(%{table: %{storage_mode: :physical}}, record), do: Physical.delete(record)
  defp delete_record(_write, record), do: Repo.delete(record, stale_error_field: :id)

  defp persist(changeset, %{table: %{storage_mode: :physical}} = write, operation) do
    with {:ok, record} <- Ecto.Changeset.apply_action(changeset, operation),
         do:
           Physical.save(
             write,
             %{record | tenant_id: Repo.tenant_id!()},
             operation,
             changeset.data.versions || %{}
           )
  end

  defp persist(changeset, _write, :insert) do
    case Repo.insert(changeset) do
      {:error, invalid} ->
        duplicate? =
          Enum.any?(invalid.errors, fn {_field, {_message, metadata}} ->
            metadata[:constraint_name] == "base_records_pkey"
          end)

        if duplicate?,
          do: {:error, {:record_exists, Ecto.Changeset.get_field(changeset, :id)}},
          else: {:error, invalid}

      result ->
        result
    end
  end

  defp persist(changeset, _write, :update), do: Repo.update(changeset)

  def fetch(%{table: %{storage_mode: :physical}} = write, id),
    do: Physical.fetch(write.table.id, id, Map.fetch!(write.definitions, write.table.id))

  def fetch(%{table: table}, id), do: fetch(table.id, id)

  def fetch(table, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %BaseRecord{} = record <-
           Repo.one(from(r in BaseRecord, where: r.table_id == ^table and r.id == ^id)),
         do: {:ok, record},
         else: (_ -> {:error, :not_found})
  end

  def project(table, definitions, ids) do
    with {:ok, result} <-
           Query.records(table, definitions, %{ids: ids, page_size: max(length(ids), 1)},
             max_limit: 200
           ) do
      by_id = Map.new(result.records, &{&1["id"], &1})

      {:ok,
       Enum.flat_map(ids, fn id ->
         case by_id[id] do
           nil ->
             []

           record ->
             [Map.new(record, fn {key, value} -> {String.to_existing_atom(key), value} end)]
         end
       end)}
    end
  end

  defp author(write), do: ActorRef.from_writer(write.uid, Repo.tenant_id!(), [])
end
