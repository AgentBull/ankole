defmodule BullX.LLM.Catalog.Cache do
  @moduledoc false

  use GenServer
  require Logger

  alias BullX.LLM.Provider

  @providers_key "llm:providers"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec list() :: [Provider.t()]
  def list do
    case BullX.Cache.get(@providers_key) do
      {:ok, providers} when is_list(providers) -> providers
      {:ok, _invalid} -> load_providers_for_read()
      {:error, :not_found} -> load_providers_for_read()
      {:error, _reason} -> []
    end
  end

  @spec get(String.t()) :: {:ok, Provider.t()} | :error
  def get(provider_id) when is_binary(provider_id) do
    case Enum.find(list(), &(&1.provider_id == provider_id)) do
      %Provider{} = provider -> {:ok, provider}
      nil -> :error
    end
  end

  @spec refresh(String.t()) :: :ok | {:error, term()}
  def refresh(provider_id) when is_binary(provider_id), do: call({:refresh, provider_id})

  @spec refresh_all() :: :ok | {:error, term()}
  def refresh_all, do: call(:refresh_all)

  @impl true
  def init(_opts) do
    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:refresh, _provider_id}, _from, state) do
    {:reply, reload_all(), state}
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
    case reload_all() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "BullX.LLM.Catalog.Cache: failed to load from database, starting with empty cache: #{inspect(reason)}"
        )

        clear_providers()
        :ok
    end
  end

  defp reload_all do
    with {:ok, providers} <- fetch_providers(),
         :ok <- BullX.Cache.put(@providers_key, providers) do
      :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp load_providers_for_read do
    with {:ok, providers} <- fetch_providers() do
      _cache_result = BullX.Cache.put(@providers_key, providers)
      providers
    else
      {:error, reason} ->
        Logger.warning(
          "BullX.LLM.Catalog.Cache: failed to load from database after cache miss: #{inspect(reason)}"
        )

        clear_providers()
        []
    end
  end

  defp clear_providers do
    _cache_result = BullX.Cache.delete(@providers_key)
    :ok
  end

  defp fetch_providers do
    providers =
      Provider
      |> BullX.Repo.all()
      |> Enum.sort_by(& &1.provider_id)

    {:ok, providers}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
