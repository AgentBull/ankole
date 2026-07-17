defmodule DingTalkOpenAPI.TokenStore do
  @moduledoc """
  Owns the shared ETS access-token cache for the DingTalk SDK.

  The table lives outside the per-client token manager processes so transient
  manager restarts do not wipe cached app access tokens. The store deliberately
  owns only the table lifecycle; refresh policy and token acquisition stay in
  `DingTalkOpenAPI.TokenManager`.
  """

  use GenServer

  @table :dingtalk_openapi_tokens

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
