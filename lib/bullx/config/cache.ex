defmodule BullX.Config.Cache do
  use GenServer
  require Logger

  @table :bullx_config_db

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Reads a raw string value from ETS. Returns `:error` if absent or table unavailable."
  def get_raw(key) when is_binary(key) do
    try do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> :error
      end
    rescue
      ArgumentError -> :error
    end
  end

  @doc "Removes a key from ETS without touching the database. Used for test cleanup."
  def delete_raw(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:delete_raw, key})
  end

  @doc "Reloads a single key from PostgreSQL and updates ETS."
  def refresh(key) when is_binary(key) do
    call({:refresh, key})
  end

  @doc "Reloads all keys from PostgreSQL."
  def refresh_all do
    call(:refresh_all)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:delete_raw, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:refresh, key}, _from, state) do
    {:reply, do_refresh_key(key), state}
  end

  @impl true
  def handle_call(:refresh_all, _from, state) do
    {:reply, load_all(), state}
  end

  defp call(message) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :cache_not_running}
      _pid -> safe_call(message)
    end
  end

  defp safe_call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, reason -> {:error, {:cache_call_failed, reason}}
  end

  defp load_all do
    try do
      rows = BullX.Repo.all(BullX.Config.AppConfig)
      :ets.delete_all_objects(@table)

      rows
      |> Enum.reduce([], &collect_load_error/2)
      |> load_result()
    rescue
      e ->
        reason = {:load_failed, Exception.message(e)}

        Logger.warning(
          "BullX.Config.Cache: failed to load from database, starting with empty cache: #{Exception.message(e)}"
        )

        {:error, reason}
    end
  end

  defp do_refresh_key(key) do
    try do
      case BullX.Repo.get(BullX.Config.AppConfig, key) do
        nil ->
          :ets.delete(@table, key)
          :ok

        %BullX.Config.AppConfig{value: value, type: type} ->
          refresh_value(key, value, type)
      end
    rescue
      e ->
        reason = {:refresh_failed, key, Exception.message(e)}

        Logger.warning(
          "BullX.Config.Cache: failed to refresh key #{inspect(key)}: #{Exception.message(e)}"
        )

        {:error, reason}
    end
  end

  defp collect_load_error(%BullX.Config.AppConfig{key: key, value: value, type: type}, acc) do
    case refresh_value(key, value, type) do
      :ok -> acc
      {:error, reason} -> [reason | acc]
    end
  end

  defp load_result([]), do: :ok
  defp load_result(errors), do: {:error, {:load_failed, Enum.reverse(errors)}}

  defp refresh_value(key, value, type) do
    case decrypt_if_secret(value, type, key) do
      {:ok, plaintext} ->
        :ets.insert(@table, {key, plaintext})
        :ok

      {:error, reason} ->
        :ets.delete(@table, key)

        Logger.warning(
          "BullX.Config.Cache: failed to decrypt key #{inspect(key)}: #{inspect(reason)}"
        )

        {:error, {:decrypt_failed, key, reason}}
    end
  end

  defp decrypt_if_secret(value, :secret, key), do: BullX.Config.Crypto.decrypt(value, key)
  defp decrypt_if_secret(value, _type, _key), do: {:ok, value}
end
