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
  @topic "app_configure:cache"
  # Row entries use tuples, so this atom key cannot collide with them.
  @refresh_generation :refresh_generation

  @type row_state :: {:row, map()} | :absent | {:error, term()}

  @doc """
  Starts the ETS projection owner.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up the cached row state for one concrete scope and key in this tenant.

  The cache stores row state instead of resolved values because resolution needs
  the caller's definition to validate plaintext or decrypt secret rows.
  """
  @spec lookup(String.t(), String.t()) :: {:ok, row_state()} | :miss
  def lookup(scope, key) when is_binary(scope) and is_binary(key) do
    assert_scope!(scope)

    cache_key = cache_key(scope, key, Repo.tenant_id())

    case safe_lookup(cache_key) do
      [{^cache_key, state}] -> {:ok, state}
      [] -> :miss
      :missing_table -> :miss
    end
  end

  @doc """
  Loads the current concrete row from PostgreSQL on a cache miss.

  The read runs in the calling process, so it is re-entrant inside the caller's
  open transaction and the SQL Sandbox serves it from the caller's test
  connection. The cache process then publishes the result only if no refresh
  started after this load began, and it never replaces an existing entry. A
  refresh follows a commit, so an earlier load can hold the row from before that
  commit, and a failed refresh leaves no entry to block it. The caller still
  gets its own result. A load that begins after a refresh sees that refresh's
  commit under READ COMMITTED isolation, so it can publish.
  """
  @spec load(String.t(), String.t()) :: {:ok, row_state()} | {:error, term()}
  def load(scope, key) do
    assert_scope!(scope)
    generation = refresh_generation()
    read_result = read_one(scope, key)

    GenServer.call(
      __MODULE__,
      {:publish_load, scope, key, Repo.tenant_id(), generation, read_result}
    )
  end

  @doc """
  Re-reads one key after a committed write and replaces its projection.

  A refresh first removes the old entry and starts a new refresh generation, so
  no load that began earlier can publish (see `load/2`). A failed read then
  leaves the key empty until a later load.

  The read runs inside the cache process, so concurrent refreshes serialize and
  each one reads the row state as of its turn; a delayed publisher therefore
  cannot replace a newer database value with an older captured envelope. The
  query names the requesting process as `:caller`: write owners call this
  outside their transaction, the SQL Sandbox then uses the writer's test
  connection, and normal pools ignore the option.
  """
  @spec refresh(String.t(), String.t()) :: {:ok, row_state()} | {:error, term()}
  def refresh(scope, key) do
    assert_scope!(scope)
    tenant_id = Repo.tenant_id()

    Phoenix.PubSub.broadcast_from(
      Ankole.PubSub,
      Process.whereis(__MODULE__) || self(),
      @topic,
      {:invalidate, scope, key, tenant_id}
    )

    GenServer.call(__MODULE__, {:refresh, scope, key, tenant_id})
  end

  @doc """
  Clears the ETS projection for tests.
  """
  @spec clear_for_test() :: :ok
  def clear_for_test do
    GenServer.call(__MODULE__, :clear_for_test)
  end

  @doc false
  @spec fail_next_refresh_for_test(String.t(), String.t(), term()) :: :ok
  def fail_next_refresh_for_test(scope, key, reason) when is_binary(scope) and is_binary(key) do
    GenServer.call(__MODULE__, {:fail_next_refresh_for_test, scope, key, reason})
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Ankole.PubSub, @topic)
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    # A new process starts a new generation, so a load that began before a
    # restart cannot publish into the new table.
    new_refresh_generation()
    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:invalidate, scope, key, tenant_id}, state) do
    invalidate(scope, key, tenant_id)
    {:noreply, state}
  end

  @impl true
  def handle_call(
        {:publish_load, scope, key, tenant_id, generation, read_result},
        _from,
        server_state
      ) do
    with {:ok, state} <- read_result,
         ^generation <- refresh_generation() do
      :ets.insert_new(@table, {cache_key(scope, key, tenant_id), state})
    end

    {:reply, read_result, server_state}
  end

  def handle_call({:refresh, scope, key, tenant_id}, _from, server_state)
      when is_map_key(server_state, {:fail_next_refresh, scope, key}) do
    {reason, server_state} = Map.pop!(server_state, {:fail_next_refresh, scope, key})
    invalidate(scope, key, tenant_id)
    {:reply, {:error, reason}, server_state}
  end

  def handle_call({:refresh, scope, key, tenant_id}, {caller, _tag}, server_state) do
    loaded =
      if tenant_id,
        do: Repo.with_tenant(tenant_id, fn -> load_one(scope, key, caller) end),
        else: Repo.without_tenant(fn -> load_one(scope, key, caller) end)

    {:reply, loaded, server_state}
  end

  def handle_call({:fail_next_refresh_for_test, scope, key, reason}, _from, server_state) do
    {:reply, :ok, Map.put(server_state, {:fail_next_refresh, scope, key}, reason)}
  end

  @impl true
  def handle_call(:clear_for_test, _from, _server_state) do
    :ets.delete_all_objects(@table)
    new_refresh_generation()
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
    rows = Repo.all(Ankole.AppConfigure.SiteConfig)

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

  # Refresh path: invalidates the key before reading PostgreSQL so a failed or
  # missing row cannot leave an old value behind in the projection.
  defp load_one(scope, key, caller) do
    invalidate(scope, key, Repo.tenant_id())

    AppConfig.for_scope(scope)
    |> where([row], row.scope == ^scope and row.key == ^key)
    |> Repo.one(caller: caller)
    |> case do
      nil ->
        write_state(scope, key, :absent)
        {:ok, :absent}

      %{value: _} = row ->
        write_row(row)
        {:ok, {:row, row.value}}
    end
  rescue
    error ->
      reason = {:load_failed, scope, key, Exception.message(error)}
      {:error, reason}
  end

  # Runs in the process that called `load/2`, not in the cache process.
  defp read_one(scope, key) do
    AppConfig.for_scope(scope)
    |> where([row], row.scope == ^scope and row.key == ^key)
    |> Repo.one()
    |> case do
      nil -> {:ok, :absent}
      %{value: _} = row -> {:ok, {:row, row.value}}
    end
  rescue
    error ->
      reason = {:load_failed, scope, key, Exception.message(error)}
      {:error, reason}
  end

  defp assert_scope!("global"), do: :ok

  defp assert_scope!("tenant:" <> tenant_id) do
    if Repo.tenant_id!() != tenant_id,
      do: raise(ArgumentError, "configuration scope belongs to another tenant")

    :ok
  end

  defp assert_scope!("agent:" <> _), do: Repo.tenant_id!()

  defp invalidate(scope, key, tenant_id) do
    new_refresh_generation()
    :ets.delete(@table, cache_key(scope, key, tenant_id))
  end

  defp cache_key("global", key, _tenant_id), do: {nil, "global", key}
  defp cache_key(scope, key, tenant_id), do: {tenant_id, scope, key}

  # Runs in the process that called `load/2` and in the cache process. Without
  # the table, the generation is `nil`, which never matches a started cache.
  defp refresh_generation do
    case safe_lookup(@refresh_generation) do
      [{@refresh_generation, generation}] -> generation
      _missing -> nil
    end
  end

  defp new_refresh_generation do
    :ets.insert(@table, {@refresh_generation, make_ref()})
  end

  defp write_row(%{scope: scope, key: key, value: value}) do
    write_state(scope, key, {:row, value})
  end

  defp write_state(scope, key, state) do
    :ets.insert(@table, {cache_key(scope, key, Repo.tenant_id()), state})
  end
end
