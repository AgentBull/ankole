defmodule MicrosoftOpenAPI.Cache do
  @moduledoc """
  Owner process for the library's ETS caches.

  The tables are process-local caches, not durable truth: losing them only
  costs a token or JWKS refetch. Entries are written by callers with
  last-write-wins semantics, which is safe for idempotent cache fills.
  """

  use GenServer

  @token_table :microsoft_openapi_token_cache
  @jwks_table :microsoft_openapi_jwks_cache

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec token_table() :: atom()
  def token_table, do: @token_table

  @spec jwks_table() :: atom()
  def jwks_table, do: @jwks_table

  @impl true
  def init(_opts) do
    :ets.new(@token_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@jwks_table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
