defmodule Ankole.Pod.Bases.Promote do
  @moduledoc "Moves inline records into typed shard tables under the metadata lock."
  import Ecto.Query
  require Ash.Query
  alias Ankole.Pod.{BaseRepo, BaseRecord, BaseTable, Bases}
  alias Ankole.Pod.Bases.Physical
  alias Ankole.Repo

  @chunk_size 500

  def if_needed(write) do
    {:ok, table} = Bases.fetch_table(write.table.id)

    if table.storage_mode == :inline and not Bases.inline?(table) do
      locked =
        BaseTable
        |> Ash.Query.filter(id == ^table.id)
        |> Ash.Query.lock(:for_update)
        |> Ankole.Ash.read_one!()

      chunks = records(locked.id)
      table = %{locked | storage_mode: :physical, schema_version: locked.schema_version + 1}

      with {:ok, :ok} <-
             BaseRepo.run(
               write.shard,
               fn ->
                 Physical.create_table!(table, Map.fetch!(write.definitions, table.id), chunks)
                 {:ok, :ok}
               end,
               ddl: true,
               deadline: write.deadline,
               timezone: write.timezone
             ),
           do: commit(table)
    else
      {:ok, table}
    end
  end

  def records(id) do
    tenant_id = Repo.tenant_id!()

    {:chunks,
     Stream.resource(
       fn -> nil end,
       fn
         :done ->
           {:halt, :done}

         after_id ->
           rows =
             if is_nil(after_id) do
               Repo.query!(
                 """
                 SELECT id::text, (to_jsonb(r)-'tenant_id'-'table_id'-'data_bytes')::text
                 FROM base_records r
                 WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid
                 ORDER BY id ASC
                 LIMIT $3
                 """,
                 [tenant_id, id, @chunk_size]
               ).rows
             else
               Repo.query!(
                 """
                 SELECT id::text, (to_jsonb(r)-'tenant_id'-'table_id'-'data_bytes')::text
                 FROM base_records r
                 WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid AND id > $3::text::uuid
                 ORDER BY id ASC
                 LIMIT $4
                 """,
                 [tenant_id, id, after_id, @chunk_size]
               ).rows
             end

           case rows do
             [] ->
               {:halt, :done}

             batch ->
               last_id = batch |> List.last() |> hd()
               json = "[" <> Enum.map_join(batch, ",", fn [_id, row_json] -> row_json end) <> "]"
               next_cursor = if length(batch) < @chunk_size, do: :done, else: last_id
               {[{:json, json}], next_cursor}
           end
       end,
       fn _ -> :ok end
     )}
  end

  def commit(table) do
    Repo.delete_all(from(r in BaseRecord, where: r.table_id == ^table.id))
    current = BaseTable |> Ash.Query.filter(id == ^table.id) |> Ankole.Ash.read_one!()
    Ankole.Ash.update(current, :promote, %{schema_version: table.schema_version})
  end
end
