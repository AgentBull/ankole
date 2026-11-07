defmodule Ankole.Pod.FileExtraction.ScanCursor do
  @moduledoc """
  Holds node-local scan cursors for bounded `Ankole.Pod.FileExtraction` patrol
  batches so large tenants with many uncached binary files advance across runs
  instead of rescanning from the newest row every tick.
  """
  use GenServer

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {:ok, :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])}
  end

  @spec get(String.t()) :: {DateTime.t(), String.t()} | nil
  def get(tenant_id) when is_binary(tenant_id) do
    if :ets.whereis(@table) == :undefined do
      nil
    else
      case :ets.lookup(@table, tenant_id) do
        [{^tenant_id, cursor}] -> cursor
        [] -> nil
      end
    end
  end

  @spec put(String.t(), {DateTime.t(), String.t()}) :: :ok
  def put(tenant_id, {_updated_at, _id} = cursor) when is_binary(tenant_id) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {tenant_id, cursor})
    end

    :ok
  end

  @spec clear(String.t()) :: :ok
  def clear(tenant_id) when is_binary(tenant_id) do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table, tenant_id)
    end

    :ok
  end
end
