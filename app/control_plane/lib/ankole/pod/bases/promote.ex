defmodule Ankole.Pod.Bases.Promote do
  @moduledoc "Moves inline records into typed shard tables under the metadata lock."
  import Ecto.Query
  require Ash.Query
  alias Ankole.Pod.{BaseRepo, BaseRecord, BaseTable, Bases}
  alias Ankole.Pod.Bases.Physical
  alias Ankole.Repo

  def if_needed(write) do
    {:ok, table} = Bases.fetch_table(write.table.id)

    if table.storage_mode == :inline and not Bases.inline?(table) do
      locked =
        BaseTable
        |> Ash.Query.filter(id == ^table.id)
        |> Ash.Query.lock(:for_update)
        |> Ankole.Ash.read_one!()

      records = records(locked.id)
      table = %{locked | storage_mode: :physical, schema_version: locked.schema_version + 1}

      with {:ok, :ok} <-
             BaseRepo.run(
               write.shard,
               fn ->
                 Physical.create_table!(table, Map.fetch!(write.definitions, table.id), records)
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
    [[json]] =
      Repo.query!(
        """
        SELECT COALESCE(jsonb_agg(to_jsonb(r)-'tenant_id'-'table_id'-'data_bytes'),'[]'::jsonb)::text
        FROM base_records r WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid
        """,
        [Repo.tenant_id!(), id]
      ).rows

    {:json, json}
  end

  def commit(table) do
    Repo.delete_all(from(r in BaseRecord, where: r.table_id == ^table.id))
    current = BaseTable |> Ash.Query.filter(id == ^table.id) |> Ankole.Ash.read_one!()
    Ankole.Ash.update(current, :promote, %{schema_version: table.schema_version})
  end
end
