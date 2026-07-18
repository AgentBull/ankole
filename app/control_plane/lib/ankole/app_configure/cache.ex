defmodule Ankole.AppConfigure.Cache do
  @moduledoc """
  ETS projection of scoped AppConfigure database rows.
  """

  use GenServer

  import Ecto.Query

  alias Ankole.AppConfigure.AppConfig
  alias Ankole.Logging
  alias Ankole.Repo

  @table :ankole_app_configure_cache

  @type row_state :: {:row, map()} | :absent | {:error, term()}

  @doc """
  Starts the ETS projection owner.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up the cached row state for one concrete `{scope, key}`.

  The cache stores row state instead of resolved values because resolution needs
  the caller's definition to validate plaintext or decrypt secret rows.
  """
  @spec lookup(String.t(), String.t()) :: {:ok, row_state()} | :miss
  def lookup(scope, key) when is_binary(scope) and is_binary(key) do
    case safe_lookup({scope, key}) do
      [{{^scope, ^key}, state}] -> {:ok, state}
      [] -> :miss
      :missing_table -> :miss
    end
  end

  @doc """
  Loads the current concrete row from PostgreSQL.

  Reads use it on a cache miss. The AppConfigure write owner also uses it after
  commit so delayed publishers cannot replace a newer database value with an
  older captured envelope.
  """
  @spec load(String.t(), String.t()) :: {:ok, row_state()} | {:error, term()}
  def load(scope, key) do
    GenServer.call(__MODULE__, {:load, scope, key})
  end

  @doc """
  Clears the ETS projection for tests.
  """
  @spec clear_for_test() :: :ok
  def clear_for_test do
    GenServer.call(__MODULE__, :clear_for_test)
  end

  @doc false
  @spec fail_next_load_for_test(term()) :: :ok
  def fail_next_load_for_test(reason) do
    GenServer.call(__MODULE__, {:fail_next_load_for_test, reason})
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_call(
        {:load, scope, key},
        _from,
        %{fail_next_load: reason} = server_state
      ) do
    :ets.delete(@table, {scope, key})
    {:reply, {:error, reason}, Map.delete(server_state, :fail_next_load)}
  end

  def handle_call({:load, scope, key}, _from, server_state) do
    {:reply, load_one(scope, key), server_state}
  end

  def handle_call({:fail_next_load_for_test, reason}, _from, server_state) do
    {:reply, :ok, Map.put(server_state, :fail_next_load, reason)}
  end

  @impl true
  def handle_call(:clear_for_test, _from, _server_state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{}}
  end

  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> :missing_table
  end

  # Startup loading is best-effort for the projection. PostgreSQL is still the
  # durable source of truth, and later cache misses can load individual rows.
  defp load_all do
    rows = Repo.all(AppConfig)

    :ets.delete_all_objects(@table)
    Enum.each(rows, &write_row/1)
    :ok
  rescue
    error ->
      Logging.warning(
        "app_configure.cache.load_failed",
        "app configure cache failed to load from database",
        %{
          error: Exception.message(error)
        }
      )

      {:error, {:load_failed, Exception.message(error)}}
  end

  # Deletes the stale ETS entry before reading PostgreSQL so a failed or missing
  # row cannot leave an old value behind in the projection.
  defp load_one(scope, key) do
    :ets.delete(@table, {scope, key})

    AppConfig
    |> where([row], row.scope == ^scope and row.key == ^key)
    |> Repo.one()
    |> case do
      nil ->
        write_state(scope, key, :absent)
        {:ok, :absent}

      %AppConfig{} = row ->
        write_row(row)
        {:ok, {:row, row.value}}
    end
  rescue
    error ->
      reason = {:load_failed, scope, key, Exception.message(error)}
      {:error, reason}
  end

  defp write_row(%AppConfig{scope: scope, key: key, value: value}) do
    write_state(scope, key, {:row, value})
  end

  defp write_state(scope, key, state) do
    :ets.insert(@table, {{scope, key}, state})
  end
end
