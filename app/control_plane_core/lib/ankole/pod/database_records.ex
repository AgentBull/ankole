defmodule Ankole.Pod.Database.Records do
  @moduledoc false
  import Ecto.Query
  alias Ankole.{ActorRef, Repo}
  alias Ankole.Pod.{Database, DbField, DbRecord, DbTable, Query, Values}
  alias Ankole.Pod.Database.Write

  def batch(write, attrs) when is_map(attrs) do
    creates = Ankole.Attrs.get(attrs, :creates, [])
    updates = Ankole.Attrs.get(attrs, :updates, [])
    deletes = Ankole.Attrs.get(attrs, :deletes, [])

    with true <-
           is_list(creates) and is_list(updates) and is_list(deletes) and
             (length(creates) + length(updates) + length(deletes)) in 1..200,
         true <- Enum.all?(creates ++ updates ++ deletes, &is_map/1),
         definitions <- Database.fields(write.table.id),
         {:ok, created, write} <- create(write, creates, definitions),
         {:ok, updated, write} <- update_records(write, updates, definitions),
         {:ok, write} <- delete(write, deletes),
         {:ok, changes} <- Write.finish(Write.touch(write, write.table.id)),
         ids <- Enum.uniq(Enum.reverse(created) ++ Enum.reverse(updated)),
         {:ok, records} <- project(write.table, definitions, ids) do
      {:ok, Write.result(changes, write.table.id) |> Map.put(:records, records)}
    else
      false -> {:error, :invalid_record_batch}
      error -> error
    end
  end

  def batch(_, _), do: {:error, :invalid_record_batch}

  defp create(write, attrs, definitions) do
    attrs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], write}, fn {attrs, index}, {:ok, ids, write} ->
      with data when is_map(data) <- Ankole.Attrs.get(attrs, :data, %{}),
           {:ok, patch} <- Values.patch(data, definitions, write.table.page_id),
           patch <-
             Enum.reduce(definitions, patch, fn field, acc ->
               if field.type == :auto_number,
                 do: Map.put(acc, field.id, write.table.next_auto_number + index),
                 else: acc
             end),
           clean <- Write.clean(patch),
           :ok <- Write.record_size(clean, write.limits),
           {:ok, record} <-
             Repo.insert(
               DbRecord.changeset(%DbRecord{}, %{
                 id: Ankole.Attrs.get(attrs, :id, Ankole.Ecto.UUIDv7.autogenerate()),
                 table_id: write.table.id,
                 data: clean,
                 versions: Map.new(Map.keys(patch), &{&1, 1}),
                 created_by: author(write),
                 updated_by: author(write),
                 created_at: DateTime.utc_now(:microsecond),
                 updated_at: DateTime.utc_now(:microsecond)
               })
             ),
           write <-
             Write.touch(write, write.table.id, changed: [record.id], delta: 1, inserted: 1),
           {:ok, write} <- maintain_links(write, definitions, %{}, record.data, record.id) do
        {:cont, {:ok, [record.id | ids], write}}
      else
        value when not is_tuple(value) -> {:halt, {:error, :invalid_record}}
        error -> {:halt, error}
      end
    end)
  end

  defp update_records(write, attrs, definitions) do
    Enum.reduce_while(attrs, {:ok, [], write}, fn attrs, {:ok, ids, write} ->
      with {:ok, record} <- fetch(write.table.id, Ankole.Attrs.get(attrs, :id)),
           data <- Ankole.Attrs.get(attrs, :data),
           expected <- Ankole.Attrs.get(attrs, :expected_versions),
           true <- is_map(data) and map_size(data) > 0 and is_map(expected),
           :ok <- field_cas(record, data, expected),
           {:ok, patch} <- Values.patch(data, definitions, write.table.page_id),
           merged <- Map.merge(record.data, patch) |> Write.clean(),
           :ok <- Write.record_size(merged, write.limits),
           {:ok, saved} <-
             Repo.update(
               DbRecord.changeset(record, %{
                 data: merged,
                 versions:
                   Enum.reduce(
                     Map.keys(patch),
                     record.versions,
                     &Map.update(&2, &1, 1, fn v -> v + 1 end)
                   ),
                 updated_by: author(write),
                 updated_at: DateTime.utc_now(:microsecond)
               })
             ),
           write <- Write.touch(write, write.table.id, changed: [record.id]),
           {:ok, write} <- maintain_links(write, definitions, record.data, saved.data, record.id) do
        {:cont, {:ok, [record.id | ids], write}}
      else
        false -> {:halt, {:error, :expected_versions_required}}
        error -> {:halt, error}
      end
    end)
  end

  defp delete(write, attrs) do
    Enum.reduce_while(attrs, {:ok, write}, fn attrs, {:ok, write} ->
      with {:ok, record} <- fetch(write.table.id, Ankole.Attrs.get(attrs, :id)),
           true <- Ankole.Attrs.get(attrs, :expected_versions) == record.versions,
           {:ok, write} <- clean_incoming(write, record.id),
           {:ok, _} <- Repo.delete(record) do
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

  def maintain_links(write, definitions, before, after_data, id) do
    links = Enum.filter(definitions, &(&1.type == :link and &1.config["reverse_field_id"]))
    missing = Enum.map(links, & &1.config["reverse_field_id"]) -- Map.keys(write.reverse_fields)

    fields =
      if missing == [],
        do: [],
        else:
          Repo.all(
            from f in DbField, where: f.id in ^missing and f.table_id in ^Map.keys(write.tables)
          )

    write = %{
      write
      | reverse_fields: Map.merge(write.reverse_fields, Map.new(fields, &{&1.id, &1}))
    }

    links
    |> Enum.reduce_while({:ok, write}, fn field, {:ok, write} ->
      old = Map.get(before, field.id, [])
      new = Map.get(after_data, field.id, [])
      operations = Enum.map(old -- new, &{&1, false}) ++ Enum.map(new -- old, &{&1, true})
      reverse = Map.fetch!(write.reverse_fields, field.config["reverse_field_id"])

      result =
        Enum.reduce_while(operations, {:ok, write}, fn {target, added}, {:ok, write} ->
          with {:ok, record} <- fetch(reverse.table_id, target),
               ids <- Map.get(record.data, reverse.id, []),
               ids <- if(added, do: Enum.uniq([id | ids]), else: ids -- [id]),
               true <- reverse.config["multiple"] != false or length(ids) <= 1,
               {:ok, write} <- linked_record(write, record, reverse.id, ids) do
            {:cont, {:ok, write}}
          else
            false -> {:halt, {:error, :link_cardinality}}
            error -> {:halt, error}
          end
        end)

      case result do
        {:ok, write} -> {:cont, {:ok, write}}
        error -> {:halt, error}
      end
    end)
  end

  defp linked_record(write, record, field_id, ids) do
    data = Map.put(record.data, field_id, ids) |> Write.clean()

    with :ok <- Write.record_size(data, write.limits),
         {:ok, _} <-
           Repo.update(
             DbRecord.changeset(record, %{
               data: data,
               versions: Map.update(record.versions, field_id, 1, &(&1 + 1)),
               updated_by: author(write),
               updated_at: DateTime.utc_now(:microsecond)
             })
           ) do
      {:ok, Write.touch(write, record.table_id, changed: [record.id])}
    end
  end

  defp clean_incoming(write, id) do
    links =
      Repo.all(
        from f in DbField,
          join: t in DbTable,
          on: t.id == f.table_id,
          where: t.page_id == ^write.table.page_id and f.type == :link
      )

    Enum.reduce_while(links, {:ok, write}, fn field, {:ok, write} ->
      records =
        if field.config["table_id"] == write.table.id do
          Repo.stream(
            from(r in DbRecord,
              where:
                r.table_id == ^field.table_id and
                  fragment("? @> ?::text::jsonb", r.data, ^Torque.encode!(%{field.id => [id]}))
            ),
            max_rows: 200
          )
        else
          []
        end

      result =
        Enum.reduce_while(records, {:ok, write}, fn record, {:ok, write} ->
          case linked_record(write, record, field.id, Map.get(record.data, field.id, []) -- [id]) do
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

  def fetch(table, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %DbRecord{} = record <- Repo.get_by(DbRecord, table_id: table, id: id),
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
