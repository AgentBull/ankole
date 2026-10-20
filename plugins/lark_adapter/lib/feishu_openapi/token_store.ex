defmodule FeishuOpenAPI.TokenStore do
  @moduledoc """
  Owns the shared ETS token cache for the Feishu SDK.

  The table lives outside the per-client token manager processes so transient
  manager restarts do not wipe cached app or tenant tokens. The store
  deliberately owns only the table lifecycle; refresh policy and token
  acquisition stay in the manager modules.
  """

  use GenServer

  @table :feishu_openapi_tokens

  @spec table() :: atom()
  def table, do: @table

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    _ =
      if :ets.info(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      else
        @table
      end

    {:ok, %{}}
  end
end
