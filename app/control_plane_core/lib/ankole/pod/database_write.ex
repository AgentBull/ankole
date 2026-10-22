defmodule Ankole.Pod.Database.Write do
  @moduledoc false
  require Ash.Query
  alias Ankole.Pod.{Config, Database, DbTable}

  # One immutable journal for the already locked Database. Versions advance once,
  # from these actual writes, rather than from clocks or intermediate increments.
  defstruct [
    :uid,
    :table,
    :limits,
    tables: %{},
    changes: %{},
    reverse_fields: %{}
  ]

  def open(uid, id) do
    with {:ok, table} <- Database.table_access(uid, id, "page_edit"),
         {:ok, limits} <- Config.limits() do
      tables =
        DbTable
        |> Ash.Query.filter(page_id == ^table.page_id)
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.lock(:for_update)
        |> Ankole.Ash.read!()
        |> Map.new(&{&1.id, &1})

      case tables[id] do
        nil ->
          {:error, :not_found}

        locked ->
          {:ok,
           %__MODULE__{
             uid: uid,
             table: locked,
             tables: tables,
             limits: limits
           }}
      end
    end
  end

  def touch(write, id, opts \\ []) do
    change =
      Map.get(write.changes, id, %{
        changed_ids: MapSet.new(),
        deleted_ids: MapSet.new(),
        delta: 0,
        inserted: 0
      })

    deleted = MapSet.union(change.deleted_ids, MapSet.new(Keyword.get(opts, :deleted, [])))

    change = %{
      change
      | changed_ids:
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

      if count <= DbTable.record_limit() do
        case Ankole.Ash.update(before, :commit_write, %{
               delta: change.delta,
               inserted: change.inserted
             }) do
          {:ok, table} ->
            {:cont,
             {:ok,
              [
                %{
                  id: id,
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

  def result(changes, id) do
    own = Enum.find(changes, &(&1.id == id))
    own |> Map.delete(:id) |> Map.put(:related, Enum.reject(changes, &(&1.id == id)))
  end

  def record_size(data, limits) do
    if byte_size(Torque.encode!(data)) <= limits["record_bytes"],
      do: :ok,
      else: {:error, :record_size_limit}
  end

  def clean(data), do: Map.reject(data, fn {_key, value} -> value in [nil, "", []] end)
end
