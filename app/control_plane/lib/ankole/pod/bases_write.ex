defmodule Ankole.Pod.Bases.Write do
  @moduledoc false
  require Ash.Query
  alias Ankole.Pod.{Config, Bases, BaseTable, BaseRepo}
  alias Ankole.Pod.Bases.Physical

  # Collect changes for the locked tables. Each affected table advances once
  # when the transaction finishes.
  defstruct [
    :uid,
    :table,
    :limits,
    :shard,
    :timezone,
    :deadline,
    definitions: %{},
    conversions: %{},
    tables: %{},
    changes: %{}
  ]

  def open(actor, table, intent \\ :write_records)

  def open(actor, id, intent) when is_binary(id) do
    with {:ok, table} <- Bases.fetch_table(id), do: open(actor, table, intent)
  end

  def open(%Ankole.AuthZ.Actor{} = actor, %BaseTable{} = table, intent)
      when intent in [:write_records, :manage_schema, :delete_table] do
    id = table.id

    with {:ok, limits} <- Config.limits() do
      lock =
        cond do
          intent != :write_records -> "FOR UPDATE"
          table.storage_mode == :physical -> "FOR KEY SHARE"
          true -> "FOR NO KEY UPDATE"
        end

      query =
        if intent == :write_records and table.storage_mode == :inline,
          do: Ash.Query.filter(BaseTable, id == ^id),
          else: Ash.Query.filter(BaseTable, page_id == ^table.page_id)

      tables =
        query
        |> Ash.Query.filter(is_nil(deleting_at))
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.lock(lock)
        |> Ankole.Ash.read!()
        |> Map.new(&{&1.id, &1})

      case tables[id] do
        nil ->
          {:error, :not_found}

        %{storage_mode: mode} when intent == :write_records and mode != table.storage_mode ->
          {:error, :base_storage_changed}

        locked ->
          with {:ok, _} <- Bases.table_access(actor, locked, intent),
               {:ok, timezone} <- Ankole.SystemConfig.timezone() do
            {:ok,
             %__MODULE__{
               uid: Ankole.AuthZ.Actor.uid(actor),
               table: locked,
               tables: tables,
               limits: limits,
               shard: BaseRepo.shard!(),
               timezone: timezone,
               deadline: Ankole.Pod.Access.deadline(),
               definitions: Map.new(tables, fn {id, _} -> {id, Bases.fields(id)} end)
             }}
          end
      end
    end
  end

  def touch(write, id, opts \\ []) do
    change =
      Map.get(write.changes, id, %{
        changed_ids: MapSet.new(),
        deleted_ids: MapSet.new(),
        delta: 0,
        inserted: 0,
        resync: false
      })

    deleted = MapSet.union(change.deleted_ids, MapSet.new(Keyword.get(opts, :deleted, [])))

    change = %{
      change
      | resync: change.resync or Keyword.get(opts, :resync, false),
        changed_ids:
          MapSet.union(change.changed_ids, MapSet.new(Keyword.get(opts, :changed, [])))
          |> MapSet.difference(deleted),
        deleted_ids: deleted,
        delta: change.delta + Keyword.get(opts, :delta, 0),
        inserted: change.inserted + Keyword.get(opts, :inserted, 0)
    }

    %{write | changes: Map.put(write.changes, id, change)}
  end

  def finish(write) do
    Enum.reduce_while(write.changes, {:ok, []}, fn {id, change}, {:ok, results} ->
      before = Map.fetch!(write.tables, id)
      count = before.record_count + change.delta

      if count <= BaseTable.record_limit() do
        case commit(before, change) do
          {:ok, table} ->
            {:cont,
             {:ok,
              [
                %{
                  id: id,
                  resync: change.resync,
                  data_version: table.data_version,
                  changed_ids: Enum.sort(change.changed_ids),
                  deleted_ids: Enum.sort(change.deleted_ids)
                }
                | results
              ]}}

          error ->
            {:halt, error}
        end
      else
        {:halt, {:error, :record_limit}}
      end
    end)
  end

  defp commit(%{storage_mode: :physical} = table, change), do: Physical.commit(table, change)

  defp commit(table, change) do
    [[bytes]] =
      Ankole.Repo.query!(
        "SELECT COALESCE(SUM(data_bytes),0)::bigint FROM base_records WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid",
        [Ankole.Repo.tenant_id!(), table.id]
      ).rows

    Ankole.Ash.update(table, :commit_write, %{
      delta: change.delta,
      inserted: change.inserted,
      record_bytes: bytes
    })
  end

  def result(changes, id) do
    own = Enum.find(changes, &(&1.id == id))
    own |> Map.delete(:id) |> Map.put(:related, Enum.reject(changes, &(&1.id == id)))
  end
end
