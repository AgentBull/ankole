# OTP Complete Examples

Production-quality implementations of common OTP patterns. Each example is self-contained and based on patterns found in production Elixir codebases (Elixir stdlib, Phoenix, Plug, Ecto).

## Rate Limiter (Token Bucket with ETS)

Based on patterns from Elixir's Registry (ETS atomic operations) and Logger backends (:counters module).

```elixir
defmodule MyApp.RateLimiter do
  @moduledoc """
  Token bucket rate limiter using ETS for lock-free concurrent access.
  Supports per-key limits (e.g., per IP, per user).

  Pattern source: Elixir Registry's use of ETS insert_new + update_counter
  for atomic concurrent operations.
  """
  use GenServer

  @default_limit 100
  @default_window_ms 60_000
  @cleanup_interval_ms 30_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Check if request is allowed. Returns :ok or {:error, :rate_limited}"
  def check(key, name \\ __MODULE__) do
    table = table_name(name)
    now = System.monotonic_time(:millisecond)
    limit = :persistent_term.get({name, :limit}, @default_limit)
    window = :persistent_term.get({name, :window}, @default_window_ms)

    case :ets.lookup(table, key) do
      [{^key, count, window_start}] when now - window_start < window ->
        if count < limit do
          :ets.update_counter(table, key, {2, 1})
          :ok
        else
          {:error, :rate_limited}
        end

      _ ->
        # New window or first request — atomic insert
        :ets.insert(table, {key, 1, now})
        :ok
    end
  end

  @doc "Get remaining requests for key"
  def remaining(key, name \\ __MODULE__) do
    table = table_name(name)
    limit = :persistent_term.get({name, :limit}, @default_limit)

    case :ets.lookup(table, key) do
      [{^key, count, _}] -> max(limit - count, 0)
      [] -> limit
    end
  end

  # Server callbacks

  @impl true
  def init(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    window = Keyword.get(opts, :window_ms, @default_window_ms)
    name = Keyword.get(opts, :name, __MODULE__)

    table = :ets.new(table_name(name), [
      :set, :public, :named_table,
      read_concurrency: true,
      write_concurrency: true,
      decentralized_counters: true
    ])

    :persistent_term.put({name, :limit}, limit)
    :persistent_term.put({name, :window}, window)

    schedule_cleanup()
    {:ok, %{table: table, window: window, name: name}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    # Use select_delete for atomic bulk cleanup — pattern from Elixir Registry
    :ets.select_delete(state.table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now - state.window}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  defp table_name(name), do: Module.concat(name, Table)
end
```

## Connection State Machine (gen_statem)

Based on patterns from Mint HTTP client (connection lifecycle) and Erlang's gen_tcp.

```elixir
defmodule MyApp.Connection do
  @moduledoc """
  TCP connection manager using gen_statem with reconnection.

  States: :disconnected -> :connecting -> :connected -> :disconnected
  Uses state_enter for cleanup/setup on state transitions.
  Uses named timeouts for reconnection backoff.
  Uses :postpone to queue requests during reconnection.

  Pattern source: Mint's connection state machine, Erlang gen_tcp patterns.
  """
  @behaviour :gen_statem

  defstruct [:host, :port, :socket, :from_queue, backoff: 1_000, max_backoff: 30_000]

  def start_link(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    :gen_statem.start_link(__MODULE__, {host, port}, [])
  end

  def send_data(pid, data) do
    :gen_statem.call(pid, {:send, data}, 10_000)
  end

  # Callbacks

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init({host, port}) do
    data = %__MODULE__{host: host, port: port, from_queue: :queue.new()}
    {:ok, :disconnected, data, [{:next_event, :internal, :connect}]}
  end

  # --- Disconnected ---

  def disconnected(:enter, _old_state, data) do
    # Close socket if we had one
    if data.socket, do: :gen_tcp.close(data.socket)
    {:keep_state, %{data | socket: nil}}
  end

  def disconnected(:internal, :connect, data) do
    {:next_state, :connecting, data}
  end

  def disconnected({:call, from}, {:send, _data}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :disconnected}}]}
  end

  # --- Connecting ---

  def connecting(:enter, _old_state, data) do
    # Attempt connection with short timeout
    case :gen_tcp.connect(
      String.to_charlist(data.host),
      data.port,
      [:binary, active: true, packet: :raw],
      5_000
    ) do
      {:ok, socket} ->
        {:next_state, :connected, %{data | socket: socket, backoff: 1_000}}

      {:error, _reason} ->
        # Schedule reconnect with exponential backoff
        {:keep_state, data,
         [{{:timeout, :reconnect}, data.backoff, :reconnect}]}
    end
  end

  def connecting({:timeout, :reconnect}, :reconnect, data) do
    new_backoff = min(data.backoff * 2, data.max_backoff)
    {:next_state, :connecting, %{data | backoff: new_backoff}}
  end

  def connecting({:call, _from}, {:send, _}, _data) do
    # Postpone sends until connected — they'll replay in :connected state
    {:keep_state_and_data, [:postpone]}
  end

  # --- Connected ---

  def connected(:enter, _old_state, data) do
    # Drain any queued messages
    {:keep_state, data}
  end

  def connected({:call, from}, {:send, payload}, data) do
    case :gen_tcp.send(data.socket, payload) do
      :ok ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:next_state, :disconnected, data,
         [{:reply, from, {:error, reason}},
          {:next_event, :internal, :connect}]}
    end
  end

  def connected(:info, {:tcp, _socket, incoming}, data) do
    # Handle incoming data — dispatch to application
    handle_incoming(incoming, data)
    {:keep_state, data}
  end

  def connected(:info, {:tcp_closed, _socket}, data) do
    {:next_state, :disconnected, data,
     [{:next_event, :internal, :connect}]}
  end

  def connected(:info, {:tcp_error, _socket, _reason}, data) do
    {:next_state, :disconnected, data,
     [{:next_event, :internal, :connect}]}
  end

  defp handle_incoming(_data, _state), do: :ok
end
```

## Worker Pool (Supervisor + Registry)

Based on patterns from Elixir's PartitionSupervisor and Registry.

```elixir
defmodule MyApp.WorkerPool do
  @moduledoc """
  Dynamic worker pool with checkout/checkin using Registry.

  Pattern source: Elixir PartitionSupervisor (hash-based routing),
  Registry (process tracking), DynamicSupervisor (on-demand workers).
  """
  use Supervisor

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    size = Keyword.get(opts, :size, System.schedulers_online())
    worker_mod = Keyword.fetch!(opts, :worker)
    worker_args = Keyword.get(opts, :worker_args, [])

    children = [
      {Registry, keys: :unique, name: registry(name)},
      {Registry, keys: :duplicate, name: available_registry(name)}
    ] ++
      for i <- 1..size do
        Supervisor.child_spec(
          {MyApp.WorkerPool.Worker,
           id: i, registry: registry(name),
           available: available_registry(name),
           worker_mod: worker_mod, worker_args: worker_args},
          id: {MyApp.WorkerPool.Worker, i}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Check out a worker, run function, check back in"
  def transaction(pool_name, fun, timeout \\ 5_000) do
    case checkout(pool_name, timeout) do
      {:ok, worker_pid} ->
        try do
          fun.(worker_pid)
        after
          checkin(pool_name, worker_pid)
        end

      {:error, :timeout} ->
        {:error, :pool_exhausted}
    end
  end

  defp checkout(pool_name, timeout) do
    case Registry.lookup(available_registry(pool_name), :available) do
      [{pid, _} | _] ->
        Registry.unregister_match(available_registry(pool_name), :available, pid)
        {:ok, pid}

      [] ->
        # Wait for a worker to become available
        ref = make_ref()
        Registry.register(available_registry(pool_name), :waiting, {self(), ref})

        receive do
          {:worker_available, ^ref, pid} -> {:ok, pid}
        after
          timeout -> {:error, :timeout}
        end
    end
  end

  defp checkin(pool_name, worker_pid) do
    # Notify waiting clients or mark as available
    case Registry.lookup(available_registry(pool_name), :waiting) do
      [{_waiter_pid, {caller, ref}} | _] ->
        Registry.unregister_match(available_registry(pool_name), :waiting, {caller, ref})
        send(caller, {:worker_available, ref, worker_pid})

      [] ->
        Registry.register(available_registry(pool_name), :available, worker_pid)
    end
  end

  defp registry(name), do: Module.concat(name, Registry)
  defp available_registry(name), do: Module.concat(name, Available)
end

defmodule MyApp.WorkerPool.Worker do
  use GenServer

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    registry = Keyword.fetch!(opts, :registry)
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {registry, {:worker, id}}})
  end

  @impl true
  def init(opts) do
    available = Keyword.fetch!(opts, :available)
    worker_mod = Keyword.fetch!(opts, :worker_mod)
    worker_args = Keyword.fetch!(opts, :worker_args)

    # Register as available
    Registry.register(available, :available, self())

    {:ok, %{worker_mod: worker_mod, state: worker_mod.init(worker_args)}}
  end
end
```

## GenServer State as Struct

ALWAYS use a struct for GenServer state — it gives you `@type t`, `@enforce_keys`, compile-time key checks via `%{state | field: val}`, and self-documenting fields. Define the struct in the same module as the GenServer.

```elixir
defmodule MyApp.CacheServer do
  use GenServer

  defstruct [
    :name,
    store: %{},
    stats: %{hits: 0, misses: 0},
    max_size: 1000,
    ttl: :timer.minutes(5)
  ]

  @type t :: %__MODULE__{
    name: atom(),
    store: %{term() => {term(), integer()}},
    stats: %{hits: non_neg_integer(), misses: non_neg_integer()},
    max_size: pos_integer(),
    ttl: pos_integer()
  }

  # Constructor validates and sets defaults from opts
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    state = struct!(__MODULE__, opts)
    GenServer.start_link(__MODULE__, state, name: name)
  end

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  @impl true
  def handle_call({:get, key}, _from, %__MODULE__{} = state) do
    case Map.get(state.store, key) do
      {value, expires} when expires > System.monotonic_time(:millisecond) ->
        {:reply, {:ok, value}, %{state | stats: bump_hits(state.stats)}}
      _ ->
        {:reply, :miss, %{state | stats: bump_misses(state.stats)}}
    end
  end

  defp bump_hits(stats), do: %{stats | hits: stats.hits + 1}
  defp bump_misses(stats), do: %{stats | misses: stats.misses + 1}
end
```

**Key patterns:**
- `struct!(__MODULE__, opts)` — parse keyword opts into struct, raises on unknown keys
- `%__MODULE__{} = state` in callbacks — assertive match catches wrong state shape
- `%{state | field: val}` — compile-time safety on updates (typos crash immediately)
- Nested map fields (`stats`) updated with helper functions for clarity

## ETS Cache with TTL

Based on patterns from Elixir's Registry (select_delete for cleanup) and Mix.State (persistent_term for config).

```elixir
defmodule MyApp.Cache do
  @moduledoc """
  ETS-backed key-value cache with per-entry TTL and periodic cleanup.

  Pattern source: Elixir Registry select_delete for atomic bulk operations,
  Mix.State for persistent_term configuration storage.
  """
  use GenServer

  @default_ttl_ms 300_000  # 5 minutes
  @cleanup_interval_ms 60_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get value from cache. Returns {:ok, value} or :miss"
  def get(key, name \\ __MODULE__) do
    now = System.monotonic_time(:millisecond)
    table = table_name(name)

    case :ets.lookup(table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:ok, value}

      [{^key, _value, _expired}] ->
        :ets.delete(table, key)
        :miss

      [] ->
        :miss
    end
  end

  @doc "Put value with optional TTL in milliseconds"
  def put(key, value, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    ttl = Keyword.get(opts, :ttl, @default_ttl_ms)
    table = table_name(name)
    expires_at = System.monotonic_time(:millisecond) + ttl
    :ets.insert(table, {key, value, expires_at})
    :ok
  end

  @doc "Delete a key"
  def delete(key, name \\ __MODULE__) do
    :ets.delete(table_name(name), key)
    :ok
  end

  @doc "Get or compute value, caching the result"
  def fetch(key, fun, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case get(key, name) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        put(key, value, opts)
        value
    end
  end

  @doc "Evict all expired entries (also runs automatically)"
  def cleanup(name \\ __MODULE__) do
    GenServer.cast(name, :cleanup)
  end

  @doc "Clear entire cache"
  def clear(name \\ __MODULE__) do
    :ets.delete_all_objects(table_name(name))
    :ok
  end

  @doc "Return cache size"
  def size(name \\ __MODULE__) do
    :ets.info(table_name(name), :size)
  end

  # Server

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    table = :ets.new(table_name(name), [
      :set, :public, :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()
    {:ok, %{table: table, name: name}}
  end

  @impl true
  def handle_cast(:cleanup, state) do
    do_cleanup(state.table)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    do_cleanup(state.table)
    schedule_cleanup()
    {:noreply, state}
  end

  defp do_cleanup(table) do
    now = System.monotonic_time(:millisecond)

    # Atomic select_delete — from Elixir Registry pattern
    :ets.select_delete(table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp table_name(name), do: Module.concat(name, Table)
end
```

## Registry-Based Pub/Sub

Based directly on Elixir's Registry with duplicate keys for pub/sub dispatch.

```elixir
defmodule MyApp.PubSub do
  @moduledoc """
  Lightweight pub/sub using Elixir Registry with duplicate keys.

  This is the recommended approach for local node pub/sub when you
  don't need Phoenix.PubSub's cluster-wide broadcasting.

  Pattern source: Elixir Registry documentation and dispatch mechanism.
  """

  @registry MyApp.PubSub.Registry

  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc "Subscribe calling process to a topic"
  def subscribe(topic) do
    Registry.register(@registry, topic, [])
  end

  @doc "Subscribe with metadata (e.g., filter criteria)"
  def subscribe(topic, metadata) do
    Registry.register(@registry, topic, metadata)
  end

  @doc "Unsubscribe calling process from a topic"
  def unsubscribe(topic) do
    Registry.unregister(@registry, topic)
  end

  @doc "Broadcast message to all subscribers of a topic"
  def broadcast(topic, message) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _metadata} <- entries do
        send(pid, {__MODULE__, topic, message})
      end
    end)
  end

  @doc "Broadcast to subscribers matching a filter"
  def broadcast_filter(topic, message, filter_fn) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, metadata} <- entries, filter_fn.(metadata) do
        send(pid, {__MODULE__, topic, message})
      end
    end)
  end

  @doc "Count subscribers for a topic"
  def count(topic) do
    Registry.count_match(@registry, topic, :_)
  end

  @doc "List all subscribers for a topic"
  def subscribers(topic) do
    Registry.lookup(@registry, topic)
  end
end

# Usage in supervision tree:
# children = [
#   MyApp.PubSub,
#   ...
# ]
#
# Subscribe:   MyApp.PubSub.subscribe("user:123")
# Broadcast:   MyApp.PubSub.broadcast("user:123", {:updated, data})
# Receive:     {MyApp.PubSub, "user:123", {:updated, data}}
```

## Task Pipeline with Backpressure

Based on patterns from Task.Supervisor (async_nolink) and Erlang's :queue module.

```elixir
defmodule MyApp.TaskPipeline do
  @moduledoc """
  Bounded task pipeline with backpressure.

  Limits concurrent tasks to prevent resource exhaustion.
  Uses :queue for FIFO ordering and Task.Supervisor for fault isolation.

  Pattern source: Task.Supervisor.async_nolink for monitored tasks,
  :queue for efficient FIFO operations.
  """
  use GenServer

  defstruct [
    :task_supervisor,
    :max_concurrent,
    queue: :queue.new(),
    active: %{},       # ref => task_info
    active_count: 0
  ]

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Submit work. Returns {:ok, ref} or {:error, :queue_full}"
  def submit(pipeline, fun, opts \\ []) do
    GenServer.call(pipeline, {:submit, fun, opts})
  end

  @doc "Submit and wait for result"
  def run(pipeline, fun, timeout \\ 30_000) do
    case submit(pipeline, fun) do
      {:ok, ref} ->
        receive do
          {:pipeline_result, ^ref, result} -> result
        after
          timeout -> {:error, :timeout}
        end

      error ->
        error
    end
  end

  @doc "Get pipeline stats"
  def stats(pipeline) do
    GenServer.call(pipeline, :stats)
  end

  # Server

  @impl true
  def init(opts) do
    max_concurrent = Keyword.get(opts, :max_concurrent, System.schedulers_online() * 2)
    max_queue = Keyword.get(opts, :max_queue, 1_000)

    # Start a dedicated Task.Supervisor for isolation
    {:ok, task_sup} = Task.Supervisor.start_link()

    {:ok, %__MODULE__{
      task_supervisor: task_sup,
      max_concurrent: max_concurrent
    } |> Map.put(:max_queue, max_queue)}
  end

  @impl true
  def handle_call({:submit, fun, opts}, {caller, _}, state) do
    queue_size = :queue.len(state.queue)
    max_queue = Map.get(state, :max_queue, 1_000)

    if queue_size >= max_queue do
      {:reply, {:error, :queue_full}, state}
    else
      ref = make_ref()
      item = %{fun: fun, ref: ref, caller: caller, opts: opts}
      new_state = %{state | queue: :queue.in(item, state.queue)}
      {:reply, {:ok, ref}, maybe_start_tasks(new_state)}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      active: state.active_count,
      queued: :queue.len(state.queue),
      max_concurrent: state.max_concurrent
    }
    {:reply, stats, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completed successfully
    Process.demonitor(ref, [:flush])

    case Map.pop(state.active, ref) do
      {%{caller: caller, ref: pipeline_ref}, active} ->
        send(caller, {:pipeline_result, pipeline_ref, {:ok, result}})
        new_state = %{state | active: active, active_count: state.active_count - 1}
        {:noreply, maybe_start_tasks(new_state)}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.active, ref) do
      {%{caller: caller, ref: pipeline_ref}, active} ->
        send(caller, {:pipeline_result, pipeline_ref, {:error, reason}})
        new_state = %{state | active: active, active_count: state.active_count - 1}
        {:noreply, maybe_start_tasks(new_state)}

      {nil, _} ->
        {:noreply, state}
    end
  end

  defp maybe_start_tasks(state) do
    if state.active_count < state.max_concurrent and not :queue.is_empty(state.queue) do
      {{:value, item}, queue} = :queue.out(state.queue)

      %Task{ref: ref} = Task.Supervisor.async_nolink(
        state.task_supervisor,
        item.fun
      )

      active = Map.put(state.active, ref, item)

      maybe_start_tasks(%{state |
        queue: queue,
        active: active,
        active_count: state.active_count + 1
      })
    else
      state
    end
  end
end
```

## Circuit Breaker

Based on the fuse pattern (open/closed/half_open) implemented as a GenServer with ETS for fast reads.

```elixir
defmodule MyApp.CircuitBreaker do
  @moduledoc """
  Circuit breaker for protecting against cascading failures.

  States:
  - :closed    — Normal operation, counting failures
  - :open      — Failing fast, rejecting all calls
  - :half_open — Testing with a single request

  Uses ETS for lock-free state reads (hot path doesn't touch GenServer).

  Pattern source: Standard circuit breaker pattern, ETS for state as in
  Elixir's persistent_term and Registry patterns.
  """
  use GenServer

  @default_threshold 5
  @default_timeout_ms 30_000

  defstruct [
    :name,
    :table,
    threshold: @default_threshold,
    timeout_ms: @default_timeout_ms,
    failure_count: 0,
    last_failure_time: nil
  ]

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  @doc """
  Execute function through circuit breaker.
  Returns {:ok, result} | {:error, :circuit_open} | {:error, reason}
  """
  def call(name, fun) do
    table = table_name(name)

    case read_state(table) do
      :closed ->
        execute(name, table, fun)

      :half_open ->
        execute(name, table, fun)

      :open ->
        # Check if timeout has elapsed
        case :ets.lookup(table, :last_failure) do
          [{:last_failure, time}] ->
            [{:timeout, timeout}] = :ets.lookup(table, :timeout)

            if System.monotonic_time(:millisecond) - time > timeout do
              # Transition to half_open
              :ets.insert(table, {:state, :half_open})
              execute(name, table, fun)
            else
              {:error, :circuit_open}
            end

          [] ->
            {:error, :circuit_open}
        end
    end
  end

  @doc "Reset circuit breaker to closed state"
  def reset(name) do
    GenServer.call(via(name), :reset)
  end

  @doc "Get current state"
  def state(name) do
    read_state(table_name(name))
  end

  # Server

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    table = :ets.new(table_name(name), [
      :set, :public, :named_table,
      read_concurrency: true
    ])

    :ets.insert(table, [
      {:state, :closed},
      {:failures, 0},
      {:threshold, threshold},
      {:timeout, timeout_ms}
    ])

    {:ok, %__MODULE__{
      name: name,
      table: table,
      threshold: threshold,
      timeout_ms: timeout_ms
    }}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.insert(state.table, [{:state, :closed}, {:failures, 0}])
    {:reply, :ok, %{state | failure_count: 0}}
  end

  @impl true
  def handle_cast({:record_success, _table}, state) do
    :ets.insert(state.table, [{:state, :closed}, {:failures, 0}])
    {:noreply, %{state | failure_count: 0}}
  end

  def handle_cast({:record_failure, table}, state) do
    now = System.monotonic_time(:millisecond)
    new_count = :ets.update_counter(table, :failures, {2, 1})
    :ets.insert(table, {:last_failure, now})

    if new_count >= state.threshold do
      :ets.insert(table, {:state, :open})
      :telemetry.execute(
        [:circuit_breaker, :opened],
        %{failure_count: new_count},
        %{name: state.name}
      )
    end

    {:noreply, %{state | failure_count: new_count, last_failure_time: now}}
  end

  # Private

  defp execute(name, table, fun) do
    try do
      result = fun.()
      GenServer.cast(via(name), {:record_success, table})
      {:ok, result}
    rescue
      error ->
        GenServer.cast(via(name), {:record_failure, table})
        {:error, error}
    catch
      kind, reason ->
        GenServer.cast(via(name), {:record_failure, table})
        {:error, {kind, reason}}
    end
  end

  defp read_state(table) do
    case :ets.lookup(table, :state) do
      [{:state, state}] -> state
      [] -> :closed
    end
  end

  defp via(name), do: {:via, Registry, {MyApp.CircuitBreaker.Registry, name}}
  defp table_name(name), do: :"cb_#{name}"
end
```

## Telemetry Integration

Based on patterns from Plug.Telemetry (:telemetry.span), Phoenix.Logger (attach_many), and Absinthe's telemetry middleware.

```elixir
defmodule MyApp.Telemetry do
  @moduledoc """
  Telemetry setup: event definitions, handler attachment, metrics.

  Pattern source:
  - Plug.Telemetry: :telemetry.span/3 for start/stop/exception
  - Phoenix.Logger: :telemetry.attach_many/4 for grouped handlers
  - Absinthe.Middleware.Telemetry: wrapping operations with telemetry
  """
  use Supervisor

  require Logger

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    # Attach handlers early — they survive process crashes
    attach_handlers()

    children = [
      # Poll VM metrics every 10 seconds
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  ## Event Definitions

  @doc "Wrap a function call with telemetry span (start/stop/exception)"
  def span(event_prefix, metadata, fun) do
    # Pattern from Plug.Telemetry — emits [:prefix, :start], [:prefix, :stop],
    # or [:prefix, :exception] with duration measurement
    :telemetry.span(event_prefix, metadata, fn ->
      result = fun.()
      {result, metadata}
    end)
  end

  ## Metrics Definitions (for reporters like Prometheus/StatsD)

  def metrics do
    import Telemetry.Metrics

    [
      # Phoenix endpoint
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        tags: [:method, :route]
      ),
      counter("phoenix.endpoint.stop.duration",
        tags: [:method, :status]
      ),

      # Ecto queries
      summary("my_app.repo.query.total_time",
        unit: {:native, :millisecond},
        tags: [:source]
      ),
      distribution("my_app.repo.query.total_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 50, 100, 500, 1000]]
      ),

      # Custom application events
      counter("my_app.events.processed.count", tags: [:type]),
      last_value("my_app.pipeline.queue_depth"),

      # VM metrics (from :telemetry_poller)
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes", unit: :byte),
      last_value("vm.memory.binary", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.system_counts.process_count")
    ]
  end

  ## Handlers

  defp attach_handlers do
    :telemetry.attach_many(
      "myapp-log-handler",
      [
        [:my_app, :request, :stop],
        [:my_app, :request, :exception],
        [:my_app, :pipeline, :stop]
      ],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event([:my_app, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    if duration_ms > 1000 do
      Logger.warning("Slow request",
        duration_ms: duration_ms,
        route: metadata[:route],
        method: metadata[:method]
      )
    end
  end

  def handle_event([:my_app, :request, :exception], _measurements, metadata, _config) do
    Logger.error("Request exception",
      kind: metadata.kind,
      reason: metadata.reason,
      stacktrace: Exception.format_stacktrace(metadata.stacktrace)
    )
  end

  def handle_event([:my_app, :pipeline, :stop], measurements, metadata, _config) do
    Logger.info("Pipeline batch processed",
      count: metadata[:count],
      duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond)
    )
  end

  ## Periodic Measurements

  defp periodic_measurements do
    [
      {__MODULE__, :measure_queue_depth, []}
    ]
  end

  def measure_queue_depth do
    depth = MyApp.TaskPipeline.stats(MyApp.Pipeline) |> Map.get(:queued, 0)
    :telemetry.execute([:my_app, :pipeline], %{queue_depth: depth}, %{})
  end
end

# Emitting custom events from application code:
#
# :telemetry.execute(
#   [:my_app, :events, :processed],
#   %{count: length(events)},
#   %{type: :order}
# )
#
# Using span for automatic start/stop/exception:
#
# MyApp.Telemetry.span([:my_app, :external_api], %{service: :payments}, fn ->
#   PaymentService.charge(amount)
# end)
```

## Distributed Counter (G-Counter CRDT with :pg)

Based on patterns from Elixir's :pg process groups and :counters module.

```elixir
defmodule MyApp.DistributedCounter do
  @moduledoc """
  Grow-only counter (G-Counter CRDT) using :pg for cluster membership.

  Each node maintains its own counter. The global value is the sum
  of all node counters. Conflict-free — counters only grow.

  Pattern source: :pg module for process group membership,
  :erpc for reliable cross-node calls.
  """
  use GenServer

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Increment counter on this node"
  def increment(name, amount \\ 1) when amount > 0 do
    GenServer.cast(name, {:increment, amount})
  end

  @doc "Get counter value from this node only"
  def local_value(name) do
    GenServer.call(name, :local_value)
  end

  @doc "Get global counter value (sum across all nodes)"
  def global_value(name) do
    # Get local value
    local = GenServer.call(name, :local_value)

    # Get values from all other nodes
    remote_values =
      :pg.get_members(:my_app_counters, name)
      |> Enum.reject(&(&1 == self()))
      |> Enum.map(fn pid ->
        try do
          GenServer.call(pid, :local_value, 5_000)
        catch
          :exit, _ -> 0
        end
      end)

    local + Enum.sum(remote_values)
  end

  # Server

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    # Join process group for discovery
    :pg.join(:my_app_counters, name, self())

    # Monitor other nodes for cleanup
    :net_kernel.monitor_nodes(true)

    {:ok, %{name: name, count: 0}}
  end

  @impl true
  def handle_cast({:increment, amount}, state) do
    {:noreply, %{state | count: state.count + amount}}
  end

  @impl true
  def handle_call(:local_value, _from, state) do
    {:reply, state.count, state}
  end

  @impl true
  def handle_info({:nodedown, _node}, state) do
    # :pg handles member cleanup automatically
    {:noreply, state}
  end

  def handle_info({:nodeup, _node}, state) do
    {:noreply, state}
  end
end

# Setup in Application:
#
# def start(_type, _args) do
#   :pg.start(:my_app_counters)  # or add to supervision tree
#   children = [
#     {MyApp.DistributedCounter, name: :page_views},
#     ...
#   ]
# end
```

## Graceful Shutdown

Based on patterns from Phoenix.Endpoint (drain connections) and Plug.Cowboy (graceful stop).

```elixir
defmodule MyApp.GracefulShutdown do
  @moduledoc """
  Graceful shutdown coordinator.

  Ensures in-flight requests complete and resources are cleaned up
  before the application stops.

  Pattern source: Phoenix.Endpoint shutdown behavior,
  Application.prep_stop/1 callback.
  """
  use GenServer

  require Logger

  @shutdown_timeout_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a shutdown hook. Called in order during shutdown."
  def register_hook(name, fun) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:register, name, fun})
  end

  @doc "Begin graceful shutdown sequence"
  def initiate_shutdown do
    GenServer.call(__MODULE__, :shutdown, @shutdown_timeout_ms + 5_000)
  end

  @impl true
  def init(_opts) do
    # Trap exits to get terminate/2 callback
    Process.flag(:trap_exit, true)
    {:ok, %{hooks: []}}
  end

  @impl true
  def handle_call({:register, name, fun}, _from, state) do
    {:reply, :ok, %{state | hooks: [{name, fun} | state.hooks]}}
  end

  def handle_call(:shutdown, _from, state) do
    result = run_hooks(Enum.reverse(state.hooks))
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("Running shutdown hooks...")
    run_hooks(Enum.reverse(state.hooks))
    :ok
  end

  defp run_hooks(hooks) do
    results =
      Enum.map(hooks, fn {name, fun} ->
        Logger.info("Shutdown hook: #{name}")
        task = Task.async(fun)

        case Task.yield(task, @shutdown_timeout_ms) || Task.shutdown(task) do
          {:ok, result} ->
            Logger.info("Shutdown hook #{name}: complete")
            {name, {:ok, result}}

          nil ->
            Logger.warning("Shutdown hook #{name}: timed out")
            {name, {:error, :timeout}}
        end
      end)

    {:ok, results}
  end
end

# Usage in Application:
#
# def start(_type, _args) do
#   children = [MyApp.GracefulShutdown, ...]
#   result = Supervisor.start_link(children, opts)
#
#   # Register shutdown hooks
#   MyApp.GracefulShutdown.register_hook("drain_connections", fn ->
#     Logger.info("Draining HTTP connections...")
#     # Stop accepting new connections
#     Supervisor.terminate_child(MyApp.Supervisor, MyApp.Endpoint)
#     # Wait for in-flight requests
#     Process.sleep(5_000)
#   end)
#
#   MyApp.GracefulShutdown.register_hook("flush_telemetry", fn ->
#     :telemetry_poller.stop(MyApp.Poller)
#   end)
#
#   result
# end
```

## Hot Code Upgrade

Based on BEAM's code loading mechanism and OTP release handler.

```elixir
defmodule MyApp.VersionedServer do
  @moduledoc """
  GenServer demonstrating hot code upgrade with state migration.

  Key concepts:
  - @vsn attribute for version tracking
  - code_change/3 for state migration
  - Fully-qualified calls (__MODULE__.func) pick up new code
  - Local calls (func) stay on loaded version

  Pattern source: BEAM code loading semantics, OTP release handler.
  """
  use GenServer

  @vsn "2.0.0"

  defstruct [:name, :count, :history, :created_at]

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get_state(name), do: GenServer.call(name, :get_state)
  def increment(name), do: GenServer.cast(name, :increment)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      count: 0,
      history: [],
      created_at: DateTime.utc_now()
    }
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:increment, state) do
    new_state = %{state |
      count: state.count + 1,
      history: [DateTime.utc_now() | Enum.take(state.history, 99)]
    }
    {:noreply, new_state}
  end

  # State migration: v1 -> v2 added :history field
  @impl true
  def code_change("1.0.0", old_state, _extra) do
    # v1 state was: %{name: _, count: _}
    new_state = %__MODULE__{
      name: old_state.name,
      count: old_state.count,
      history: [],
      created_at: DateTime.utc_now()
    }
    {:ok, new_state}
  end

  def code_change(_vsn, state, _extra) do
    {:ok, state}
  end

  # Redact state in crash reports
  @impl true
  def format_status(status) do
    Map.update!(status, :state, fn state ->
      %{state | history: "[#{length(state.history)} entries]"}
    end)
  end
end

# Testing hot upgrades:
#
# test "state migration from v1 to v2" do
#   v1_state = %{name: :test, count: 42}
#   {:ok, v2_state} = MyApp.VersionedServer.code_change("1.0.0", v1_state, [])
#   assert v2_state.count == 42
#   assert v2_state.history == []
# end
#
# test "upgrade preserves running state" do
#   {:ok, pid} = MyApp.VersionedServer.start_link(name: :upgrade_test)
#   MyApp.VersionedServer.increment(:upgrade_test)
#
#   :sys.suspend(pid)
#   :sys.change_code(pid, MyApp.VersionedServer, "1.0.0", [])
#   :sys.resume(pid)
#
#   state = MyApp.VersionedServer.get_state(:upgrade_test)
#   assert state.count == 1
#   assert state.history == []
# end
```

## Process Idle Timeout

Based on GenServer timeout pattern for automatic cleanup of idle processes.

```elixir
defmodule MyApp.SessionServer do
  @moduledoc """
  Per-session GenServer that automatically terminates after inactivity.

  Uses GenServer's built-in timeout mechanism — every callback returns
  the timeout value, and :timeout info fires when no messages arrive.

  Pattern source: GenServer timeout return values, DynamicSupervisor
  for on-demand process creation.
  """
  use GenServer

  @idle_timeout_ms 300_000  # 5 minutes

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id,
      name: {:via, Registry, {MyApp.SessionRegistry, session_id}})
  end

  def get(session_id, key) do
    case Registry.lookup(MyApp.SessionRegistry, session_id) do
      [{pid, _}] -> GenServer.call(pid, {:get, key})
      [] -> {:error, :not_found}
    end
  end

  def put(session_id, key, value) do
    # Start on demand if not running
    pid = ensure_started(session_id)
    GenServer.call(pid, {:put, key, value})
  end

  @impl true
  def init(session_id) do
    {:ok, %{session_id: session_id, data: %{}}, @idle_timeout_ms}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state.data, key), state, @idle_timeout_ms}
  end

  def handle_call({:put, key, value}, _from, state) do
    new_state = %{state | data: Map.put(state.data, key, value)}
    {:reply, :ok, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    # No messages for @idle_timeout_ms — shut down
    {:stop, :normal, state}
  end

  defp ensure_started(session_id) do
    case Registry.lookup(MyApp.SessionRegistry, session_id) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(
          MyApp.SessionSupervisor,
          {__MODULE__, session_id}
        ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end
end

# Supervision tree:
#
# children = [
#   {Registry, keys: :unique, name: MyApp.SessionRegistry},
#   {DynamicSupervisor, name: MyApp.SessionSupervisor, strategy: :one_for_one},
#   ...
# ]
```

## Extended OTP Examples (from main skill)

### Deferred GenServer Replies

Block caller while freeing GenServer for other work:

```elixir
def handle_call(:wait_for_turn, from, state) do
  queue = :queue.in(from, state.queue)
  {:noreply, %{state | queue: queue}}  # Caller blocked, GenServer free
end

def handle_info(:process_next, state) do
  {{:value, caller}, queue} = :queue.out(state.queue)
  GenServer.reply(caller, :ok)  # Unblock caller here
  {:noreply, %{state | queue: queue}}
end
```

Use for: rate limiters, resource pools, work queues.

### GenServer + async_nolink Pattern

Production-grade pattern for GenServer delegating work to Tasks:

```elixir
defmodule MyApp.JobRunner do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{task_ref: nil, result: nil}}

  def handle_call(:run_job, _from, %{task_ref: nil} = state) do
    task = Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn -> do_work() end)
    {:reply, :started, %{state | task_ref: task.ref}}
  end

  # Task completed successfully
  @impl true
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])  # Clean up monitor, flush :DOWN
    {:noreply, %{state | task_ref: nil, result: result}}
  end

  # Task crashed
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.error("Task failed: #{inspect(reason)}")
    {:noreply, %{state | task_ref: nil}}
  end

  # Stale refs from previous tasks — always handle these
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end
end
```

**Key:** Always handle stale refs. When a task completes, you get `{ref, result}` as a message. The `:DOWN` message also arrives — `Process.demonitor(ref, [:flush])` discards it. Without the stale ref handler, orphaned messages accumulate in the mailbox.

### ETS-Backed GenServer Pattern

70x performance improvement — GenServer owns the table; reads/writes bypass it entirely:

```elixir
defmodule FastCache do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # FAST: Direct ETS access, no GenServer bottleneck
  def get(key) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  def put(key, value) do
    :ets.insert(__MODULE__, {key, value})
    :ok
  end

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [
      :named_table,
      :public,                    # Any process can read/write
      write_concurrency: true,    # Allow concurrent writes to different keys
      read_concurrency: true      # Optimize for concurrent reads
    ])
    {:ok, nil}
  end
end
```

**Key insight:** GenServer only owns the table; reads/writes bypass it entirely.

**ETS Concurrency Options:**
- `write_concurrency: true` - Concurrent writes to different keys
- `read_concurrency: true` - Optimize read-heavy workloads
- **Don't** use `read_concurrency` with interleaved reads/writes (hurts performance)

### Cron Job GenServer Pattern

```elixir
defmodule PeriodicJob do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.fetch!(opts, :interval)
    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    do_work()
    {:noreply, state, {:continue, :schedule}}
  end
end
```

### Fault Tolerance Patterns

#### Let It Crash

Don't rescue unknown errors in GenServer callbacks — let supervision handle it:

```elixir
# BAD — hiding errors, state may be corrupted
def handle_call({:process, data}, _from, state) do
  try do
    result = process_data(data)
    {:reply, {:ok, result}, state}
  rescue
    e -> {:reply, {:error, e}, state}  # State may be corrupt
  end
end

# GOOD — crash propagates, supervisor restarts with clean state
def handle_call({:process, data}, _from, state) do
  result = process_data(data)  # Crashes on unexpected errors
  {:reply, {:ok, result}, state}
end
```

#### Error Kernel Pattern

Keep critical state in stable processes, volatile work in expendable ones:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Stable kernel — rarely crashes, holds critical state
      MyApp.ConfigStore,
      MyApp.Repo,

      # Volatile workers — may crash, easily replaced
      {DynamicSupervisor, name: MyApp.WorkerSupervisor}
    ]

    # rest_for_one: if kernel crashes, restart workers too
    Supervisor.start_link(children, strategy: :rest_for_one)
  end
end
```

#### Retry with Exponential Backoff

```elixir
defmodule MyApp.Retry do
  def with_backoff(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 5)
    base_delay = Keyword.get(opts, :base_delay, 100)
    max_delay = Keyword.get(opts, :max_delay, 10_000)
    do_retry(fun, 1, max_attempts, base_delay, max_delay)
  end

  defp do_retry(fun, attempt, max, base, max_delay) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} when attempt < max ->
        delay = min(base * trunc(:math.pow(2, attempt - 1)), max_delay)
        jitter = :rand.uniform(div(delay, 4))
        Process.sleep(delay + jitter)
        do_retry(fun, attempt + 1, max, base, max_delay)

      {:error, reason} ->
        {:error, {:max_retries, reason}}
    end
  end
end
```

#### Circuit Breaker with Fuse

```elixir
# Add {:fuse, "~> 2.5"} to deps

# Install in application start
:fuse.install(:external_api, {
  {:standard, 5, 10_000},  # 5 failures in 10 seconds → blow
  {:reset, 30_000}          # Reset after 30 seconds
})

def call_api(request) do
  case :fuse.ask(:external_api, :sync) do
    :ok ->
      case do_request(request) do
        {:ok, result} -> {:ok, result}
        {:error, _} = error ->
          :fuse.melt(:external_api)  # Record failure
          error
      end
    :blown ->
      {:error, :circuit_open}
  end
end
```

### Distribution

#### Node Connection

```elixir
# Start distributed: iex --sname node1 --cookie secret
# Or long names:      iex --name node1@192.168.1.100 --cookie secret

Node.connect(:"node2@hostname")
Node.list()                      # Connected visible nodes
Node.ping(:"node2@hostname")    # :pong | :pang
Node.alive?()                    # Is distribution enabled?
```

#### RPC — Remote Function Calls

```elixir
# Synchronous RPC (old API)
:rpc.call(:"node2@host", Module, :function, [args])

# erpc (OTP 23+) — better error handling, raises on failure
:erpc.call(:"node2@host", fn -> expensive_work() end)
:erpc.call(:"node2@host", Module, :function, [args])

# Multi-node calls
:erpc.multicall([node1, node2], fn -> collect_stats() end)

# Pattern from IEx: remote introspection with error handling
try do
  :erpc.call(node(pid), :erlang, :process_info, [pid, @keys])
catch
  _, _ -> [{"Alive", false}]
end
```

#### Process Groups with :pg

```elixir
# Join group (in GenServer init)
:pg.join(:my_scope, :workers, self())

# Get members
:pg.get_members(:my_scope, :workers)
:pg.get_local_members(:my_scope, :workers)  # Only this node

# Broadcast to all
for pid <- :pg.get_members(:my_scope, :workers) do
  send(pid, {:broadcast, message})
end
```

#### Global Process Registry

```elixir
# Register globally (cluster-wide singleton)
GenServer.start_link(__MODULE__, arg, name: {:global, {:service, id}})

# Lookup — local ETS read, no network traffic
case :global.whereis_name({:service, id}) do
  :undefined -> {:error, :not_found}
  pid -> {:ok, pid}
end

# Multi-node GenServer calls
GenServer.multi_call([node() | Node.list()], MyServer, :status)
GenServer.abcast([node() | Node.list()], MyServer, {:notify, data})
```

#### Node Monitoring

```elixir
# Subscribe to node events
:net_kernel.monitor_nodes(true)

@impl true
def handle_info({:nodedown, node}, state) do
  Logger.warning("Node disconnected: #{node}")
  {:noreply, cleanup_node(state, node)}
end

def handle_info({:nodeup, node}, state) do
  Logger.info("Node reconnected: #{node}")
  {:noreply, state}
end
```

**:noconnection handling** — remote process monitors return `:noconnection` on network failure, not the actual exit reason:

```elixir
def handle_info({:DOWN, ref, :process, pid, reason}, state) do
  case reason do
    :noconnection -> Logger.warning("Lost connection to #{inspect(pid)}")
    :noproc -> Logger.info("Process never existed")
    other -> Logger.info("Process exited: #{inspect(other)}")
  end
  {:noreply, state}
end
```

#### Clustering with libcluster

```elixir
# config/config.exs
config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes,
      config: [kubernetes_selector: "app=myapp", kubernetes_node_basename: "myapp"]
    ]
  ]

# In application supervisor
{Cluster.Supervisor, [Application.get_env(:libcluster, :topologies),
                       [name: MyApp.ClusterSupervisor]]}
```

#### Distributed Supervisor with Horde

```elixir
# Distributed registry — processes discoverable cluster-wide
defmodule MyApp.HordeRegistry do
  use Horde.Registry

  def start_link(_) do
    Horde.Registry.start_link(__MODULE__, [keys: :unique], name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end
end

# Distributed supervisor — processes restarted on surviving nodes
defmodule MyApp.HordeSupervisor do
  use Horde.DynamicSupervisor

  def start_link(_) do
    Horde.DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_), do: Horde.DynamicSupervisor.init(strategy: :one_for_one)
end
```

### Telemetry Patterns

#### Event Naming and Execution

```elixir
# Event names are lists of atoms: [:my_app, :request, :stop]
# Start events carry system_time, stop events carry duration
start_time = System.monotonic_time()

:telemetry.execute(
  [:my_app, :request, :start],
  %{system_time: System.system_time()},
  %{path: path, method: method}
)

# ... do work ...

:telemetry.execute(
  [:my_app, :request, :stop],
  %{duration: System.monotonic_time() - start_time},
  %{path: path, status: status}
)
```

#### Span Pattern (Start/Stop/Exception)

```elixir
# :telemetry.span/3 — convenience for start/stop/exception lifecycle
:telemetry.span([:my_app, :operation], %{}, fn ->
  result = do_work()
  {result, %{}}  # {return_value, extra_stop_metadata}
end)

# Manual span with exception handling
defp with_telemetry(metadata, fun) do
  start_time = System.monotonic_time()
  :telemetry.execute(@start_event, %{system_time: System.system_time()}, metadata)

  try do
    fun.()
  catch
    kind, reason ->
      :telemetry.execute(@exception_event,
        %{duration: System.monotonic_time() - start_time},
        %{kind: kind, reason: reason, stacktrace: __STACKTRACE__})
      :erlang.raise(kind, reason, __STACKTRACE__)
  else
    result ->
      :telemetry.execute(@stop_event,
        %{duration: System.monotonic_time() - start_time}, metadata)
      result
  end
end
```

#### Attaching Handlers

```elixir
# Handler signature: (event_name, measurements, metadata, config) -> :ok
:telemetry.attach(
  "my-handler-id",                    # Unique handler ID
  [:my_app, :request, :stop],         # Event to handle
  &MyApp.Telemetry.handle_event/4,    # Handler function
  %{log_level: :info}                 # Config passed to handler
)

def handle_event(_event, %{duration: duration}, %{status: status}, config) do
  Logger.log(config.log_level, "Request completed in #{duration}ns, status: #{status}")
end
```

#### Metrics Definitions

```elixir
# In your telemetry supervisor
import Telemetry.Metrics

def metrics do
  [
    counter("my_app.request.count"),
    sum("my_app.request.duration", unit: {:native, :millisecond}),
    last_value("vm.memory.total", unit: {:byte, :kilobyte}),
    summary("my_app.repo.query.total_time", unit: {:native, :millisecond}),
    distribution("my_app.request.duration",
      unit: {:native, :millisecond},
      buckets: [10, 50, 100, 500, 1000],
      tags: [:method, :route],
      tag_values: fn %{conn: conn} -> %{method: conn.method, route: conn.request_path} end)
  ]
end
```

### Hot Code Updates

The BEAM maintains two module versions: **current** and **old**. Fully qualified calls (`Module.func()`) use current; local calls use the version loaded when the process started.

```elixir
# Process stuck in old code — local call stays in old version
defmodule Counter do
  def loop(count) do
    receive do
      :inc -> loop(count + 1)  # Local call — stays in OLD version
    end
  end
end

# Fixed — fully qualified call picks up new code
defmodule Counter do
  def loop(count) do
    receive do
      :inc -> __MODULE__.loop(count + 1)  # Picks up CURRENT version
    end
  end
end
```

**GenServer code_change/3** — state migration during hot upgrades:

```elixir
defmodule MyServer do
  use GenServer
  @vsn "2.0.0"

  @impl true
  def code_change("1.0.0", old_state, _extra) do
    # v1: %{count: n} → v2: %{count: n, history: []}
    {:ok, Map.put(old_state, :history, [])}
  end

  def code_change(_vsn, state, _extra), do: {:ok, state}
end
```

**When NOT to use hot upgrades** — prefer rolling restarts for: stateless services, database schema changes, major refactoring, first deployments.

### Library Design Guidelines

#### Configuration: Function Arguments over Application Env

```elixir
# BAD — library reads from application env (hidden dependency)
defmodule MyLib.Client do
  def start_link do
    url = Application.get_env(:my_lib, :api_url)  # Forces config.exs setup
    GenServer.start_link(__MODULE__, url)
  end
end

# GOOD — accept configuration as arguments (explicit, testable)
defmodule MyLib.Client do
  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)
    timeout = Keyword.get(opts, :timeout, 5000)
    GenServer.start_link(__MODULE__, %{url: url, timeout: timeout})
  end
end

# User's application.ex:
children = [{MyLib.Client, url: "https://api.example.com", timeout: 10_000}]
```

#### Library vs Application

| Aspect | Library | Application |
|--------|---------|-------------|
| Starts processes | No (or optional) | Yes |
| Config location | Function arguments | runtime.exs |
| Supervision | User's responsibility | Own supervisor tree |
| Example | Torque, Decimal | Phoenix, Ecto |

```elixir
# Library — no mod: key, no automatic supervision tree
def application do
  [extra_applications: [:logger]]
end

# Application — starts supervision tree
def application do
  [mod: {MyApp.Application, []}, extra_applications: [:logger]]
end
```

#### Intentional Programming vs Defensive Coding

```elixir
# DEFENSIVE (often unnecessary in Elixir)
def process_order(order) do
  if is_map(order) and Map.has_key?(order, :items) do
    if is_list(order.items) and length(order.items) > 0 do
      do_process(order)
    end
  end
end

# INTENTIONAL — trust the contract, crash on violations
def process_order(%{items: [_ | _] = items} = order) do
  do_process(order, items)
end

def process_order(%{items: []}), do: {:error, :empty_order}
```

**At system boundaries** (user input, external APIs): validate defensively.
**Internal code**: pattern match is the contract — crash on misuse.

### OTP Anti-Patterns

#### State Corruption After Crash

```elixir
# BAD — partial state update, crash between steps corrupts state
def handle_call(:transfer, _from, state) do
  state = update_in(state.account_a, &(&1 - 100))
  external_api_call()  # May crash here — account_a debited, account_b not credited
  state = update_in(state.account_b, &(&1 + 100))
  {:reply, :ok, state}
end

# GOOD — atomic: compute new state fully, then return
def handle_call(:transfer, _from, state) do
  :ok = external_api_call()

  new_state = state
    |> update_in([:account_a], &(&1 - 100))
    |> update_in([:account_b], &(&1 + 100))

  {:reply, :ok, new_state}
end
```

#### Unbounded Mailboxes

```elixir
# Monitor queue length and shed load
def handle_cast({:process, data}, state) do
  {:message_queue_len, len} = Process.info(self(), :message_queue_len)
  if len < 1000 do
    do_process(data)
  else
    Logger.warning("Dropping message, queue at #{len}")
  end
  {:noreply, state}
end
```

#### ETS Race Conditions

```elixir
# BAD — read-modify-write race
def increment(key) do
  [{^key, count}] = :ets.lookup(:counters, key)
  :ets.insert(:counters, {key, count + 1})  # Another process may write between read and write
end

# GOOD — atomic update_counter
def increment(key) do
  :ets.update_counter(:counters, key, 1, {key, 0})
end
```

#### Restart Loops

```elixir
# BAD — init crashes if service unavailable, causes restart loop
def init(opts) do
  config = fetch_config!()  # Raises if unavailable
  {:ok, %{config: config}}
end

# GOOD — defer risky init, retry with backoff
def init(opts) do
  {:ok, %{config: nil}, {:continue, :load_config}}
end

def handle_continue(:load_config, state) do
  case fetch_config() do
    {:ok, config} -> {:noreply, %{state | config: config}}
    {:error, _} ->
      Process.send_after(self(), :retry_config, 5000)
      {:noreply, state}
  end
end

def handle_info(:retry_config, state) do
  {:noreply, state, {:continue, :load_config}}
end
```

#### Message Copying Overhead

```elixir
# BAD — copies entire conn struct to spawned process
spawn(fn -> log_request(conn) end)

# GOOD — extract only needed data before spawning
ip = conn.remote_ip
path = conn.request_path
spawn(fn -> log_request(ip, path) end)
```

#### Wrong Supervision Strategy

```elixir
# BAD — independent workers with :one_for_all (unnecessary cascading restarts)
Supervisor.init([WorkerA, WorkerB], strategy: :one_for_all)

# GOOD — use :one_for_one for independent workers
Supervisor.init([WorkerA, WorkerB], strategy: :one_for_one)

# BAD — dependency chain with :one_for_one (Cache uses Database, but Database
#        crash doesn't restart Cache)
Supervisor.init([Database, Cache], strategy: :one_for_one)

# GOOD — use :rest_for_one for dependency chains
Supervisor.init([Database, Cache], strategy: :rest_for_one)
```

#### Monitor Leaks

```elixir
# BAD — monitor created but never cleaned up
def handle_cast({:track, pid}, state) do
  Process.monitor(pid)  # Leak — DOWN message arrives but ref not tracked
  {:noreply, state}
end

# GOOD — track refs, clean up on :DOWN
def handle_cast({:track, pid}, state) do
  ref = Process.monitor(pid)
  {:noreply, put_in(state.monitors[pid], ref)}
end

def handle_cast({:untrack, pid}, state) do
  {ref, monitors} = Map.pop(state.monitors, pid)
  if ref, do: Process.demonitor(ref, [:flush])
  {:noreply, %{state | monitors: monitors}}
end

def handle_info({:DOWN, _ref, :process, pid, _}, state) do
  {:noreply, %{state | monitors: Map.delete(state.monitors, pid)}}
end
```

#### Distributed Anti-Patterns

```elixir
# BAD — assumes :global is always consistent
pid = :global.whereis_name(:my_service)
GenServer.call(pid, :get)  # May fail during netsplit

# GOOD — handle network partitions
case :global.whereis_name(:my_service) do
  :undefined ->
    {:error, :not_found}
  pid ->
    try do
      {:ok, GenServer.call(pid, :get, 5000)}
    catch
      :exit, _ -> {:error, :unavailable}
    end
end
```

---

## Production OTP Patterns

### Data Buffering with Batch Flush

> Based on: [Broadway BatcherStage](https://github.com/dashbitco/broadway) — timer-based batch flushing with proper cancellation, and [Logflare HttpBackend](https://github.com/Logflare/logflare_logger_backend) — periodic flush with batch size cap.

Two-process pattern: collector accepts events without blocking, flusher drains on timer or when batch is full. Supervisor ensures ordering (collector starts before flusher).

```elixir
defmodule MyApp.EventCollector do
  @moduledoc """
  Buffers events in ETS for concurrent writes without GenServer bottleneck.
  Flushed periodically by EventFlusher or when batch size exceeded.
  """
  use GenServer

  @batch_limit 10_000    # hard cap prevents runaway memory

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Direct ETS write — no GenServer call on the hot path
  def record(event) do
    count = :ets.update_counter(__MODULE__, :count, {2, 1})
    :ets.insert(__MODULE__, {make_ref(), event})
    if count >= @batch_limit, do: send(__MODULE__, :flush_now)
    :ok
  end

  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :public, :bag, write_concurrency: true])
    :ets.insert(__MODULE__, {:count, 0})
    {:ok, %{}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    events = drain_events()
    {:reply, events, state}
  end

  @impl true
  def handle_info(:flush_now, state) do
    events = drain_events()
    if events != [], do: persist_events(events)
    {:noreply, state}
  end

  defp drain_events do
    # Atomically grab all events and reset counter
    events =
      :ets.tab2list(__MODULE__)
      |> Enum.reject(fn {key, _} -> key == :count end)
      |> Enum.map(fn {_ref, event} -> event end)

    :ets.delete_all_objects(__MODULE__)
    :ets.insert(__MODULE__, {:count, 0})
    events
  end

  defp persist_events(events) do
    Logger.info("Persisting #{length(events)} events")
  end
end

defmodule MyApp.EventFlusher do
  @moduledoc """
  Periodic flusher — drains the collector on a timer.
  Timer managed with proper cancellation to avoid stale messages.
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :flush_interval, 5_000)
    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    timer = :erlang.start_timer(state.interval, self(), :flush)
    {:noreply, Map.put(state, :timer, timer)}
  end

  @impl true
  def handle_info({:timeout, _ref, :flush}, state) do
    events = MyApp.EventCollector.flush()
    if events != [], do: persist_batch(events)
    {:noreply, state, {:continue, :schedule}}
  end

  defp persist_batch(events) do
    # Insert to database, send to external API, etc.
    Logger.info("Flushing batch of #{length(events)} events")
  end
end

defmodule MyApp.EventSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {MyApp.EventCollector, opts},     # Must start before flusher
      {MyApp.EventFlusher, opts}
    ]
    Supervisor.init(children, strategy: :rest_for_one)  # restart flusher if collector crashes
  end
end
```

### Rate Limiter with Deferred Replies

> Based on: [Finch HTTP/2 Pool](https://github.com/sneako/finch) — deferred replies via monitoring + send (not GenServer.reply), and [Broadway RateLimiter](https://github.com/dashbitco/broadway) — `:atomics` for lock-free rate counting with periodic refill.

Two approaches: GenServer with `:queue` for simple cases, `:atomics` for high-throughput.

```elixir
defmodule MyApp.RateLimiter do
  @moduledoc """
  Leaky bucket rate limiter with deferred replies.
  Callers block until their slot opens. Uses :queue for fair ordering.
  """
  use GenServer

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def wait(name) do
    GenServer.call(via(name), :wait, :infinity)
  end

  @impl true
  def init(opts) do
    rps = Keyword.fetch!(opts, :requests_per_second)
    interval = div(:timer.seconds(1), rps)
    {:ok, %{queue: :queue.new(), length: 0, interval: interval}}
  end

  @impl true
  def handle_call(:wait, from, state) do
    # Don't reply — caller stays blocked
    queue = :queue.in(from, state.queue)
    state = %{state | queue: queue, length: state.length + 1}

    # Start draining if this is the first waiter
    if state.length == 1 do
      {:noreply, state, {:continue, :drain}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_continue(:drain, state) do
    Process.send_after(self(), :release_next, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:release_next, %{length: 0} = state), do: {:noreply, state}
  def handle_info(:release_next, state) do
    {{:value, caller}, queue} = :queue.out(state.queue)
    GenServer.reply(caller, :ok)    # unblocks the waiting caller
    state = %{state | queue: queue, length: state.length - 1}

    if state.length > 0 do
      {:noreply, state, {:continue, :drain}}
    else
      {:noreply, state}
    end
  end

  defp via(name), do: {:via, Registry, {MyApp.RateLimiter.Registry, name}}
end

# High-throughput alternative: lock-free atomics (from Broadway)
defmodule MyApp.AtomicRateLimiter do
  @moduledoc """
  Lock-free rate limiter using :atomics — no GenServer on the hot path.
  A background timer refills the bucket periodically.
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Hot path — no GenServer call, just atomic decrement
  def check_rate(count \\ 1) do
    case :atomics.sub_get(counter(), 1, count) do
      remaining when remaining >= 0 -> :ok
      _ ->
        :atomics.add(counter(), 1, count)    # restore the over-decrement
        {:error, :rate_limited}
    end
  end

  @impl true
  def init(opts) do
    limit = Keyword.fetch!(opts, :limit)
    interval = Keyword.get(opts, :interval, 1_000)
    ref = :atomics.new(1, signed: true)
    :persistent_term.put({__MODULE__, :counter}, ref)
    :atomics.put(ref, 1, limit)
    schedule_refill(interval)
    {:ok, %{limit: limit, interval: interval}}
  end

  @impl true
  def handle_info(:refill, state) do
    :atomics.put(counter(), 1, state.limit)
    schedule_refill(state.interval)
    {:noreply, state}
  end

  defp counter, do: :persistent_term.get({__MODULE__, :counter})
  defp schedule_refill(interval), do: Process.send_after(self(), :refill, interval)
end
```

### Persistent Term Hydration

> Based on: [Broadway ConfigStorage.PersistentTerm](https://github.com/dashbitco/broadway) — write once, never erase (avoids global GC), and [Phoenix.PubSub.PG2](https://github.com/phoenixframework/phoenix_pubsub) — stores pool groups in persistent_term for zero-cost reads.

**Key insight from production:** Never use `:persistent_term.erase/1` — it triggers a global GC scan of all processes. Production code writes once during supervisor init and leaves values in place.

```elixir
defmodule MyApp.ConfigStorage do
  @moduledoc """
  Stores app config in :persistent_term for zero-cost reads.
  Write once during supervisor init — never erase.

  Based on Broadway's ConfigStorage which intentionally skips deletion:
  'the amount of memory it uses is negligible to justify the process
  purging done by persistent_term'
  """

  @behaviour MyApp.ConfigStorage.Behaviour

  @impl true
  def put(key, value) do
    :persistent_term.put({__MODULE__, key}, value)
  end

  @impl true
  def get(key) do
    :persistent_term.get({__MODULE__, key}, nil)
  end

  @impl true
  def get!(key) do
    :persistent_term.get({__MODULE__, key})
  end

  # Intentionally no delete — :persistent_term.erase triggers global GC
end

# Phoenix PubSub pattern: store a tuple for O(1) pool selection
defmodule MyApp.Pool do
  @moduledoc """
  Connection pool with persistent_term-backed group selection.
  Based on Phoenix.PubSub.PG2 — consistent hashing via :erlang.phash2.
  """

  def init_pool(name, pool_size) do
    groups = for i <- 0..(pool_size - 1), do: :"#{name}_#{i}"
    :persistent_term.put({__MODULE__, name}, List.to_tuple(groups))
  end

  # Zero-cost read on every request — no GenServer call
  def select_worker(name) do
    groups = :persistent_term.get({__MODULE__, name})
    index = :erlang.phash2(self(), tuple_size(groups))
    elem(groups, index)
  end
end

# Hydrator pattern for blocking supervisor init
defmodule MyApp.ConfigHydrator do
  @moduledoc """
  Blocks supervision tree until config is loaded, then exits.
  Use `restart: :transient` so supervisor continues after :ignore.
  """
  use GenServer, restart: :transient

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    source = Keyword.get(opts, :source, :default)
    hydrate(source)
    :ignore    # process exits, supervisor continues
  end

  defp hydrate(:default) do
    %{feature_flags: %{beta: false}, rate_limits: %{api: 100}}
    |> Enum.each(fn {k, v} -> MyApp.ConfigStorage.put(k, v) end)
  end

  defp hydrate({:file, path}) do
    path
    |> File.read!()
    |> Torque.decode!()
    |> Enum.each(fn {k, v} -> MyApp.ConfigStorage.put(String.to_atom(k), v) end)
  end
end
```

### ETS with DETS Persistence

> Based on: [ExRated](https://github.com/grempe/ex_rated) — public ETS for concurrent reads without GenServer bottleneck, DETS sync only on termination, match specs for efficient pruning.

```elixir
defmodule MyApp.PersistentCache do
  @moduledoc """
  Hybrid ETS+DETS cache. ETS is the hot path with public concurrent reads.
  DETS backup happens on termination only — not on every write.
  Based on ExRated's production pattern.
  """
  use GenServer

  @ets_opts [:named_table, :public, :set, read_concurrency: true, write_concurrency: true]
  @dets_file ~c"priv/cache.dets"
  @prune_interval :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public ETS reads — no GenServer bottleneck
  def get(key) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at,
          do: {:ok, value},
          else: (delete(key); :error)
      [] -> :error
    end
  end

  # Direct ETS write — concurrent-safe via write_concurrency
  def put(key, value, ttl_ms \\ :timer.minutes(5)) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(__MODULE__, {key, value, expires_at})
    :ok
  end

  def delete(key) do
    :ets.delete(__MODULE__, key)
    :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)    # ensure terminate/2 runs for DETS sync
    :ets.new(__MODULE__, @ets_opts)

    dets_file = Keyword.get(opts, :dets_file, @dets_file)
    {:ok, dets} = :dets.open_file(__MODULE__, file: dets_file, type: :set, repair: true)
    :dets.to_ets(dets, __MODULE__)     # hydrate ETS from DETS

    :timer.send_interval(@prune_interval, :prune)
    {:ok, %{dets: dets}}
  end

  @impl true
  def handle_info(:prune, state) do
    # Compiled match spec for efficient batch deletion of expired entries
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(__MODULE__, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Persist to DETS only on shutdown — not on every write
    :ets.to_dets(__MODULE__, state.dets)
    :dets.close(state.dets)
  end
end
```

### Global Registration (Cluster-Wide Singleton)

> Based on: [arjan/singleton](https://github.com/arjan/singleton) — watchdog manager on every node, jittered restart delay to prevent thundering herd, monitoring of remote winner.

```elixir
defmodule MyApp.Singleton.Manager do
  @moduledoc """
  Runs on EVERY node. Tries to start the singleton globally.
  If another node wins, monitors the remote process and retries on :DOWN.
  Jittered delay prevents thundering herd after a failover.

  Based on arjan/singleton.
  """
  use GenServer, restart: :transient

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    mod = Keyword.fetch!(opts, :module)
    args = Keyword.get(opts, :args, [])
    name = Keyword.get(opts, :name, mod)

    state = %{mod: mod, args: args, name: {:global, name}, monitor: nil}
    {:ok, state, {:continue, :try_start}}
  end

  @impl true
  def handle_continue(:try_start, state) do
    case GenServer.start_link(state.mod, state.args, name: state.name) do
      {:ok, pid} ->
        # We are the leader — monitor our own child
        ref = Process.monitor(pid)
        {:noreply, %{state | monitor: ref}}

      {:error, {:already_started, pid}} ->
        # Another node won — monitor the remote winner
        ref = Process.monitor(pid)
        {:noreply, %{state | monitor: ref}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    # Singleton died — jittered delay before retrying to prevent thundering herd
    delay = :rand.uniform(5_000) + 5_000
    Process.send_after(self(), :retry, delay)
    {:noreply, %{state | monitor: nil}}
  end

  @impl true
  def handle_info(:retry, state) do
    {:noreply, state, {:continue, :try_start}}
  end
end

# Example singleton service
defmodule MyApp.GlobalService do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # Call via :global name — works from any node
  def call(name \\ __MODULE__, request) do
    GenServer.call({:global, name}, request)
  end

  @impl true
  def init(opts), do: {:ok, %{started_at: DateTime.utc_now(), opts: opts}}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, {:ok, state}, state}
end

# In application supervisor — every node runs the manager
children = [
  {MyApp.Singleton.Manager, module: MyApp.GlobalService, name: :global_service}
]
```

### Process Groups (Replicated Service)

> Based on: [Oban.Notifiers.PG](https://github.com/oban-bg/oban) — module-scoped :pg for isolation, write-to-all/read-local, and [Phoenix.PubSub.PG2](https://github.com/phoenixframework/phoenix_pubsub) — separate local vs remote delivery paths.

```elixir
defmodule MyApp.ReplicatedCache do
  @moduledoc """
  Cache replicated across cluster nodes using :pg process groups.
  Writes broadcast to all members, reads from local process only.

  Based on Oban.Notifiers.PG (module-scoped :pg) and
  Phoenix.PubSub.PG2 (separate local/remote delivery).
  """
  use GenServer

  @pg_scope __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Write to ALL replicas across the cluster
  def put(key, value) do
    message = {:put, key, value}
    members = :pg.get_members(@pg_scope, @pg_scope)

    # Separate local vs remote — Phoenix PubSub pattern
    local = Enum.filter(members, &(node(&1) == node()))
    remote = Enum.filter(members, &(node(&1) != node()))

    Enum.each(local, &send(&1, message))
    Enum.each(remote, &send(&1, message))
  end

  # Read from LOCAL replica only — no network hop
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @impl true
  def init(_opts) do
    # Start module-scoped :pg for isolation from other groups
    {:ok, _} = :pg.start_link(@pg_scope)
    :ok = :pg.join(@pg_scope, @pg_scope, self())
    {:ok, %{cache: %{}}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state.cache, key), state}
  end

  @impl true
  def handle_info({:put, key, value}, state) do
    {:noreply, %{state | cache: Map.put(state.cache, key, value)}}
  end
end
```

### Network Partition Detection

> Based on: [Livebook NodeManager](https://github.com/livebook-dev/livebook) — monitors nodes with cleanup on disconnect, and [libcluster](https://github.com/bitwalker/libcluster) — reconciliation loop with pluggable connect/disconnect MFAs.

```elixir
defmodule MyApp.ClusterMonitor do
  @moduledoc """
  Monitors cluster connectivity and reconciles state on node changes.
  Based on Livebook's NodeManager (cache cleanup on disconnect)
  and libcluster (reconciliation with desired vs actual membership).
  """
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def connected_nodes, do: GenServer.call(__MODULE__, :connected_nodes)
  def partition_history, do: GenServer.call(__MODULE__, :partition_history)

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true, node_type: :all)

    state = %{
      nodes: MapSet.new(Node.list()),
      partitions: [],
      on_connect: [],     # {module, function, extra_args} callbacks
      on_disconnect: []
    }

    Logger.info("ClusterMonitor started, nodes: #{inspect(Node.list())}")
    {:ok, state}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node connected: #{node}")
    new_nodes = MapSet.put(state.nodes, node)

    # Run connect callbacks (sync state, rebuild caches)
    Enum.each(state.on_connect, fn {m, f, a} -> apply(m, f, [node | a]) end)

    {:noreply, %{state | nodes: new_nodes}}
  end

  @impl true
  def handle_info({:nodedown, node, info}, state) do
    reason = Keyword.get(info, :nodedown_reason, :unknown)
    Logger.warning("Node disconnected: #{node}, reason: #{inspect(reason)}")

    new_nodes = MapSet.delete(state.nodes, node)
    entry = %{node: node, reason: reason, at: DateTime.utc_now()}
    partitions = [entry | Enum.take(state.partitions, 99)]

    # Run disconnect callbacks (clean caches, failover)
    Enum.each(state.on_disconnect, fn {m, f, a} -> apply(m, f, [node, reason | a]) end)

    {:noreply, %{state | nodes: new_nodes, partitions: partitions}}
  end

  @impl true
  def handle_call(:connected_nodes, _from, state) do
    {:reply, MapSet.to_list(state.nodes), state}
  end

  def handle_call(:partition_history, _from, state) do
    {:reply, state.partitions, state}
  end
end
```

### Distributed Task Execution

> Based on: [Livebook ErlDist](https://github.com/livebook-dev/livebook) — atomic check-and-start with `Process.monitor` + raw `send` to avoid TOCTOU races, and module injection via `:rpc.call`.

```elixir
defmodule MyApp.DistributedExecutor do
  @moduledoc """
  Execute tasks on remote nodes. Uses MFA (not lambdas) for cross-node safety.
  Based on Livebook's ErlDist which uses monitor+send for atomic remote operations.
  """

  @doc "Execute MFA on a specific node with timeout"
  def execute_on(node, module, function, args, timeout \\ 30_000) do
    case :rpc.call(node, module, function, args, timeout) do
      {:badrpc, reason} -> {:error, {:rpc_failed, node, reason}}
      result -> {:ok, result}
    end
  end

  @doc "Execute on all connected nodes, collect results"
  def execute_on_all(module, function, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    nodes = [Node.self() | Node.list()]

    nodes
    |> Task.async_stream(
      fn node -> {node, execute_on(node, module, function, args, timeout)} end,
      timeout: timeout + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{successes: [], failures: []}, fn
      {:ok, {node, {:ok, result}}}, acc ->
        %{acc | successes: [{node, result} | acc.successes]}
      {:ok, {node, {:error, reason}}}, acc ->
        %{acc | failures: [{node, reason} | acc.failures]}
      {:exit, reason}, acc ->
        %{acc | failures: [{:unknown, {:exit, reason}} | acc.failures]}
    end)
  end

  @doc "Execute on first available node (load balancing)"
  def execute_on_any(module, function, args) do
    nodes = Enum.shuffle([Node.self() | Node.list()])

    Enum.find_value(nodes, {:error, :all_nodes_failed}, fn node ->
      case execute_on(node, module, function, args) do
        {:ok, result} -> {:ok, {node, result}}
        {:error, _} -> nil
      end
    end)
  end

  @doc """
  Atomic remote process start — avoids TOCTOU race between whereis and call.
  Based on Livebook's pattern: monitor first, then send, handle :DOWN.
  """
  def start_remote_process(node, module, args) do
    case :rpc.call(node, GenServer, :start_link, [module, args]) do
      {:badrpc, reason} ->
        {:error, {:rpc_failed, node, reason}}
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:ok, pid, ref}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

## Dynamic Pool Creation with Deduplication

Create connection pools on-demand with MD5 hash deduplication:

```elixir
defmodule MyApp.PoolManager do
  @moduledoc """
  Creates connection pools dynamically based on options.
  Same options = same pool (deduplicated via MD5 hash).
  """

  def get_or_create_pool(options) do
    # Generate unique pool name from options hash
    key = :erlang.md5(:erlang.term_to_binary(options))
    name = Module.concat(__MODULE__, "Pool_" <> Base.encode16(key, case: :lower))

    case DynamicSupervisor.start_child(
      MyApp.PoolSupervisor,
      {NimblePool, worker: {MyApp.PoolWorker, options}, name: name}
    ) do
      {:ok, _pid} -> name
      {:error, {:already_started, _pid}} -> name  # Deduplication: reuse existing
    end
  end
end

# In Application supervisor
children = [
  {DynamicSupervisor, strategy: :one_for_one, name: MyApp.PoolSupervisor}
]
```

## Dedicated State/Opts Structs for GenServer (Quantum Pattern)

For non-trivial GenServers, separate configuration from runtime state using companion struct modules. Quantum uses this consistently for every GenStage process:

```
lib/my_app/
├── job_scheduler.ex              # GenServer implementation
├── job_scheduler/
│   ├── state.ex                  # Runtime state struct
│   ├── start_opts.ex             # start_link argument struct
│   └── init_opts.ex              # init/1 argument struct (derived from start_opts)
```

### StartOpts — What start_link receives

```elixir
defmodule MyApp.JobScheduler.StartOpts do
  @moduledoc false

  @enforce_keys [:name, :storage, :jobs]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
    name: GenServer.name(),
    storage: module(),
    jobs: [map()]
  }
end
```

### State — Runtime state with different fields than config

```elixir
defmodule MyApp.JobScheduler.State do
  @moduledoc false

  @enforce_keys [:storage, :storage_pid, :jobs, :debug_logging]
  defstruct @enforce_keys ++ [buffer: [], remaining_demand: 0]

  @type t :: %__MODULE__{
    storage: module(),
    storage_pid: pid(),
    jobs: %{atom() => Job.t()},
    buffer: [Event.t()],
    remaining_demand: non_neg_integer(),
    debug_logging: boolean()
  }
end
```

### GenServer uses typed structs

```elixir
defmodule MyApp.JobScheduler do
  use GenServer
  alias __MODULE__.{StartOpts, State}

  def start_link(%StartOpts{} = opts) do
    GenServer.start_link(__MODULE__, opts, name: opts.name)
  end

  @impl true
  def init(%StartOpts{} = opts) do
    # Convert config to runtime state — different struct
    {:ok, %State{
      storage: opts.storage,
      storage_pid: GenServer.whereis(opts.storage),
      jobs: Map.new(opts.jobs, &{&1.name, &1}),
      debug_logging: Application.get_env(:my_app, :debug_logging, false)
    }}
  end

  @impl true
  def handle_call(:jobs, _from, %State{} = state) do
    {:reply, Map.values(state.jobs), state}
  end
end
```

**Benefits:**
- `@enforce_keys` catches missing fields at construction time
- `@type t` enables Dialyzer to verify state access
- Separating StartOpts from State makes clear what's configuration vs runtime
- Pattern matching on `%State{}` in callbacks documents intent
- Easy to add fields without breaking existing code

**When to use:**
- GenServer with 4+ state fields
- State shape differs from configuration shape
- Multiple processes in a supervision tree with similar but distinct config
- NOT needed for simple GenServers with 1-2 fields — a plain map or tuple suffices

## Related Files

- **[SKILL.md](SKILL.md)** — OTP rules, GenServer/gen_statem key patterns, supervisor strategies, decision frameworks
- **[otp-reference.md](otp-reference.md)** — Callback signatures, ETS cheatsheet, match specs, process info, release commands, send vs handle_continue, monitor lifecycle, deadline timeouts
- **[otp-advanced.md](otp-advanced.md)** — GenStage, Flow, Broadway, hot code upgrades, production debugging
- **[production.md](production.md)** — Production patterns, telemetry deep-dive (also covers telemetry — see Telemetry Integration example above for complementary patterns)
