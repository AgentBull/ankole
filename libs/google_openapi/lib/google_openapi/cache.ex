defmodule GoogleOpenAPI.Cache do
  @moduledoc """
  Owner process for the library's ETS token cache.

  The table is a process-local cache, not durable truth: losing it only costs
  a token refetch. Entries are written by callers with last-write-wins
  semantics, which is safe for idempotent cache fills.
  """

  use GenServer

  @token_table :google_openapi_token_cache

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec token_table() :: atom()
  def token_table, do: @token_table

  @impl true
  def init(_opts) do
    :ets.new(@token_table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
