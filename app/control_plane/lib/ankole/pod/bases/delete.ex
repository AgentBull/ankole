defmodule Ankole.Pod.Bases.Delete do
  @moduledoc "Marks a table before its idempotent shard and metadata cleanup."
  require Ash.Query
  alias Ankole.Pod.{Access, BaseRepo, BaseTable, Bases, Jobs.PurgePage}
  alias Ankole.Pod.Bases.{Physical, Write}
  alias Ankole.Repo

  def table(actor, id, authority) do
    with {:ok, table} <- Access.write(authority, fn -> mark(actor, id) end),
         {:ok, _} <- cleanup(id) do
      Bases.broadcast_schema([%{id: id, data_version: table.data_version + 1}])
      {:ok, table}
    end
  end

  defp mark(actor, id) do
    with {:ok, write} <- Write.open(actor, id, :delete_table),
         table = write.table,
         false <- referenced?(write),
         {:ok, table} <- Ankole.Ash.update(table, :begin_delete, %{}),
         {:ok, _} <- PurgePage.new(%{table_id: table.id}) |> Oban.insert(),
         do: {:ok, table},
         else: (
           true -> {:error, :table_referenced}
           error -> error
         )
  end

  defp referenced?(write) do
    Enum.any?(write.definitions, fn {id, fields} ->
      id != write.table.id and
        Enum.any?(fields, &(&1.type == :link and &1.config["table_id"] == write.table.id))
    end)
  end

  def cleanup(id) do
    Repo.transact_top_level(
      fn ->
        case BaseTable
             |> Ash.Query.filter(id == ^id)
             |> Ash.Query.lock(:for_update)
             |> Ankole.Ash.read_one!() do
          nil ->
            {:ok, :deleted}

          %{deleting_at: nil} ->
            {:error, :table_not_deleting}

          table ->
            with :ok <- drop_physical(table), do: Ankole.Ash.destroy(table, :remove)
        end
      end,
      timeout: 60_000
    )
  end

  def drop_physical(table) do
    shard = BaseRepo.shard!()

    with {:ok, :ok} <-
           BaseRepo.run(
             shard,
             fn ->
               Physical.drop!(table)
               {:ok, :ok}
             end,
             ddl: true,
             deadline: System.monotonic_time(:millisecond) + 58_000
           ),
         do: :ok
  end

  def purge_pages(page_ids) do
    tables =
      BaseTable
      |> Ash.Query.filter(page_id in ^page_ids)
      |> Ash.Query.sort(id: :asc)
      |> Ankole.Ash.read!()

    Enum.reduce_while(tables, :ok, fn table, :ok ->
      with {:ok, _} <-
             Repo.transact_top_level(fn -> Ankole.Ash.update(table, :begin_delete, %{}) end),
           {:ok, _} <- cleanup(table.id) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end
end
