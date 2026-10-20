defmodule IMTransport.TokenCache do
  @moduledoc """
  Shared ETS token row and single-key fetch.

  A row is `{key, token, expires_at}`. `expires_at` is a monotonic millisecond
  time, shortened by three minutes so a caller does not use a token as it
  lapses. A proactive refresh is armed thirty seconds before that time.

  `start_link/1` runs one GenServer for one key. Lock-free reads use `lookup/2`.
  A miss is serialized here, and concurrent callers share one upstream fetch.
  The `fetch` function owns the provider request and the provider error.
  """

  use GenServer

  # Shorten the lifetime for clock skew, early server expiry, and request time.
  @expiry_delta_ms :timer.minutes(3)
  # Refresh this far ahead of the shortened expiry.
  @refresh_lead_ms :timer.seconds(30)
  # Caller bound. It must exceed the HTTP receive timeout.
  @call_timeout :timer.seconds(15)

  defstruct [
    :client,
    :key,
    :table,
    :fetch,
    :crash_error,
    :start_error,
    :task_supervisor,
    flight: nil,
    refresh_timer: nil
  ]

  @spec expiry_delta_ms() :: pos_integer()
  def expiry_delta_ms, do: @expiry_delta_ms

  @spec call_timeout() :: pos_integer()
  def call_timeout, do: @call_timeout

  @spec expires_at_ms(integer()) :: integer()
  def expires_at_ms(expire_seconds) when is_integer(expire_seconds) do
    System.monotonic_time(:millisecond) + :timer.seconds(expire_seconds) - @expiry_delta_ms
  end

  @spec refresh_delay_ms(integer()) :: integer()
  def refresh_delay_ms(expires_at_ms) when is_integer(expires_at_ms) do
    expires_at_ms - System.monotonic_time(:millisecond) - @refresh_lead_ms
  end

  @doc "Creates a public named ETS table when the name is free."
  @spec ensure_table(atom()) :: atom()
  def ensure_table(table) when is_atom(table) do
    if :ets.info(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    else
      table
    end
  end

  @spec lookup(atom(), term()) :: {:ok, term()} | :miss
  def lookup(table, key) when is_atom(table) do
    case :ets.lookup(table, key) do
      [{^key, token, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, token}
        else
          :ets.delete_object(table, {key, token, expires_at})
          :miss
        end

      [] ->
        :miss
    end
  end

  @spec store(atom(), term(), term(), integer()) :: {:ok, term(), integer()}
  def store(table, key, token, expire_seconds)
      when is_atom(table) and is_integer(expire_seconds) do
    expires_at = expires_at_ms(expire_seconds)
    :ets.insert(table, {key, token, expires_at})
    {:ok, token, expires_at}
  end

  @doc """
  Starts the single-key fetch process.

  Required options: `:name`, `:client`, `:key`, `:table`, `:fetch`,
  `:crash_error`, `:start_error`, `:task_supervisor`. `:fetch` is
  `(client, key) -> {:ok, token, expires_at_ms} | {:error, error}`.
  `:crash_error` and `:start_error` build the provider error from the failure.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :name,
        :client,
        :key,
        :table,
        :fetch,
        :crash_error,
        :start_error,
        :task_supervisor
      ])

    GenServer.start_link(__MODULE__, Map.new(opts), name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       client: Map.fetch!(opts, :client),
       key: Map.fetch!(opts, :key),
       table: Map.fetch!(opts, :table),
       fetch: Map.fetch!(opts, :fetch),
       crash_error: Map.fetch!(opts, :crash_error),
       start_error: Map.fetch!(opts, :start_error),
       task_supervisor: Map.fetch!(opts, :task_supervisor)
     }}
  end

  @impl true
  def handle_call(:fetch, from, state) do
    case lookup(state.table, state.key) do
      {:ok, token} ->
        {:reply, {:ok, token}, state}

      :miss ->
        case state.flight do
          nil -> {:noreply, start_fetch(state, [from])}
          flight -> {:noreply, %{state | flight: %{flight | waiters: [from | flight.waiters]}}}
        end
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    state = %{state | refresh_timer: nil}
    {:noreply, if(is_nil(state.flight), do: start_fetch(state, []), else: state)}
  end

  def handle_info({:fetch_done, result}, state), do: {:noreply, finish_fetch(state, result)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{flight: %{ref: ref}} = state) do
    result = {:error, state.crash_error.({:exit, reason})}
    {:noreply, finish_fetch(state, result)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp finish_fetch(state, result) do
    if state.flight.ref, do: Process.demonitor(state.flight.ref, [:flush])
    Enum.each(state.flight.waiters, &GenServer.reply(&1, client_result(result)))
    state = %{state | flight: nil}

    case result do
      {:ok, _token, expires_at_ms} -> schedule_refresh(state, expires_at_ms)
      _other -> state
    end
  end

  defp client_result({:ok, token, _expires_at}), do: {:ok, token}
  defp client_result({:error, _reason} = err), do: err

  defp start_fetch(state, waiters) do
    state = cancel_refresh_timer(state)
    parent = self()
    client = state.client
    key = state.key
    fetch = state.fetch
    crash_error = state.crash_error

    case start_fetch_task(state.task_supervisor, fn ->
           send(parent, {:fetch_done, safe_fetch(fetch, crash_error, client, key)})
         end) do
      {:ok, pid} ->
        %{state | flight: %{ref: Process.monitor(pid), waiters: waiters}}

      {:error, reason} ->
        result = {:error, state.start_error.(reason)}
        Enum.each(waiters, &GenServer.reply(&1, result))
        state
    end
  end

  defp start_fetch_task(supervisor, fun) do
    try do
      Task.Supervisor.start_child(supervisor, fun)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp safe_fetch(fetch, crash_error, client, key) do
    fetch.(client, key)
  rescue
    exception -> {:error, crash_error.(exception)}
  catch
    kind, reason -> {:error, crash_error.({kind, reason})}
  end

  defp schedule_refresh(state, expires_at_ms) do
    state = cancel_refresh_timer(state)
    delay = refresh_delay_ms(expires_at_ms)

    if delay > 0,
      do: %{state | refresh_timer: Process.send_after(self(), :refresh, delay)},
      else: state
  end

  defp cancel_refresh_timer(state) do
    if state.refresh_timer, do: Process.cancel_timer(state.refresh_timer)
    %{state | refresh_timer: nil}
  end
end
