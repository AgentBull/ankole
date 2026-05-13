defmodule BullXAIAgent.LLM.Catalog.Cache do
  @moduledoc false

  use GenServer
  require Logger

  alias BullXAIAgent.LLM.Provider

  @table :bullx_llm_providers

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec list() :: [Provider.t()]
  def list do
    read_table(
      fn ->
        @table
        |> :ets.tab2list()
        |> Enum.map(&elem(&1, 1))
        |> Enum.sort_by(& &1.provider_id)
      end,
      []
    )
  end

  @spec get(String.t()) :: {:ok, Provider.t()} | :error
  def get(provider_id) when is_binary(provider_id) do
    read_table(
      fn ->
        case :ets.lookup(@table, provider_id) do
          [{^provider_id, provider}] -> {:ok, provider}
          [] -> :error
        end
      end,
      :error
    )
  end

  @spec refresh(String.t()) :: :ok | {:error, term()}
  def refresh(provider_id) when is_binary(provider_id), do: call({:refresh, provider_id})

  @spec refresh_all() :: :ok | {:error, term()}
  def refresh_all, do: call(:refresh_all)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:refresh, provider_id}, _from, state) do
    {:reply, do_refresh_provider(provider_id), state}
  end

  def handle_call(:refresh_all, _from, state) do
    {:reply, load_all(), state}
  end

  defp call(message) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :cache_not_running}
      _pid -> GenServer.call(__MODULE__, message)
    end
  end

  defp load_all do
    rows = BullX.Repo.all(Provider)

    :ets.delete_all_objects(@table)
    Enum.each(rows, &:ets.insert(@table, {&1.provider_id, &1}))

    :ok
  rescue
    e ->
      Logger.warning(
        "BullXAIAgent.LLM.Catalog.Cache: failed to load from database, starting with empty cache: #{Exception.message(e)}"
      )

      :ok
  end

  defp do_refresh_provider(provider_id) do
    case BullX.Repo.get_by(Provider, provider_id: provider_id) do
      nil -> :ets.delete(@table, provider_id)
      provider -> :ets.insert(@table, {provider_id, provider})
    end

    :ok
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp read_table(fun, fallback) do
    fun.()
  rescue
    ArgumentError -> fallback
  end
end
