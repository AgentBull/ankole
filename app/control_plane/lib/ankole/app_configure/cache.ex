defmodule Ankole.AppConfigure.Cache do
  @moduledoc """
  ETS projection of scoped AppConfigure database rows.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Ankole.AppConfigure.AppConfig
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
  Stores a raw database envelope after a successful AppConfigure write.
  """
  @spec put_row(String.t(), String.t(), map()) :: :ok
  def put_row(scope, key, value) do
    GenServer.call(__MODULE__, {:put, scope, key, {:row, value}})
  end

  @doc """
  Marks a concrete row as absent after delete or lazy load.
  """
  @spec put_absent(String.t(), String.t()) :: :ok
  def put_absent(scope, key) do
    GenServer.call(__MODULE__, {:put, scope, key, :absent})
  end

  @doc """
  Caches a storage error for a concrete row.

  This prevents a bad row from being treated as missing and silently falling back
  to a broader scope.
  """
  @spec put_error(String.t(), String.t(), term()) :: :ok
  def put_error(scope, key, reason) do
    GenServer.call(__MODULE__, {:put, scope, key, {:error, reason}})
  end

  @doc """
  Loads one concrete row from PostgreSQL on cache miss.

  There is no public refresh API. This function exists so a cold cache can be
  filled lazily while AppConfigure remains the only write path.
  """
  @spec load(String.t(), String.t()) :: {:ok, row_state()} | {:error, term()}
  def load(scope, key) do
    GenServer.call(__MODULE__, {:load, scope, key})
  end

  @doc false
  @spec clear_for_test() :: :ok
  def clear_for_test do
    GenServer.call(__MODULE__, :clear_for_test)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, scope, key, state}, _from, server_state) do
    write_state(scope, key, state)
    {:reply, :ok, server_state}
  end

  @impl true
  def handle_call({:load, scope, key}, _from, server_state) do
    {:reply, load_one(scope, key), server_state}
  end

  @impl true
  def handle_call(:clear_for_test, _from, server_state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, server_state}
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
      Logger.warning(
        "Ankole.AppConfigure.Cache failed to load from database: #{Exception.message(error)}"
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
      write_state(scope, key, {:error, reason})
      {:error, reason}
  end

  defp write_row(%AppConfig{scope: scope, key: key, value: value}) do
    write_state(scope, key, {:row, value})
  end

  defp write_state(scope, key, state) do
    :ets.insert(@table, {{scope, key}, state})
  end
end
