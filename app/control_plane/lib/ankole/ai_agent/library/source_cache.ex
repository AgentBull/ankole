defmodule Ankole.AIAgent.Library.SourceCache do
  @moduledoc "Owns the node-local cache of trusted library files."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  # Source readers also run in build tools before the application starts.
  def get(key, default) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, value}] -> value
      [] -> default
    end
  rescue
    ArgumentError -> default
  end

  def put(key, value) do
    :ets.insert(__MODULE__, {key, value})
    :ok
  rescue
    ArgumentError -> :ok
  end
end
