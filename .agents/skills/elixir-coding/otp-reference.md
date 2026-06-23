# OTP Quick Reference

Quick-lookup tables for OTP callback signatures, ETS operations, process debugging, and release management.

## Contents

- [GenServer Callbacks](#genserver-callbacks) — init, handle_call/cast/info/continue, terminate, format_status
- [gen_statem Callbacks](#gen_statem-callbacks) — callback_mode, state functions, actions
- [Supervisor](#supervisor) — child specs, restart values, strategies
- [ETS Cheatsheet](#ets-cheatsheet) — create, read, write, delete, counters, iteration
- [Match Spec Syntax](#match-spec-syntax) — pattern variables, guards, select/delete
- [Process Registry Patterns](#process-registry-patterns) — local, global, via Registry
- [Process Info Keys](#process-info-keys) — memory, reductions, mailbox, stack
- [:sys Module](#sys-module--debugging-otp-processes) — get_state, trace, statistics
- [Node Operations](#node-operations) — connect, ping, discovery
- [RPC / ERPC](#rpc--erpc) — sync/async remote calls
- [Application Callbacks](#application-callbacks) — start, stop, prep_stop
- [Release Commands](#release-commands) — build, run, remote access
- [Common Telemetry Events](#common-telemetry-events) — Phoenix, Ecto, Oban, VM
- [Debugging Quick Reference](#debugging-quick-reference) — recon, process inspection
- [Common Exit Reasons](#common-exit-reasons) — reason → supervisor action
- [Hot Code Upgrade Cheatsheet](#hot-code-upgrade-cheatsheet) — code module, appups, release handler
- [Memory Analysis](#memory-analysis) — system, per-process, ETS, binary
- [Extended OTP Reference](#extended-otp-reference-from-main-skill) — format_status, call vs cast, links vs monitors, PartitionSupervisor, ETS advanced, :persistent_term, :counters/:atomics

## GenServer Callbacks

```elixir
# Required
@impl true
def init(init_arg) do
  {:ok, state}
  {:ok, state, {:continue, term}}  # Defer heavy work after init
  {:ok, state, timeout}            # Send :timeout info after ms
  {:ok, state, :hibernate}         # Hibernate immediately
  :ignore                          # Don't start, no error
  {:stop, reason}                  # Fail to start
end

# Synchronous calls
@impl true
def handle_call(request, {pid, ref}, state) do
  {:reply, reply, new_state}
  {:reply, reply, new_state, {:continue, term}}
  {:reply, reply, new_state, timeout}
  {:reply, reply, new_state, :hibernate}
  {:noreply, new_state}            # Reply later with GenServer.reply/2
  {:noreply, new_state, {:continue, term}}
  {:stop, reason, reply, new_state}
  {:stop, reason, new_state}
end

# Asynchronous casts
@impl true
def handle_cast(request, state) do
  {:noreply, new_state}
  {:noreply, new_state, {:continue, term}}
  {:noreply, new_state, timeout}
  {:noreply, new_state, :hibernate}
  {:stop, reason, new_state}
end

# Messages (monitors, node changes, custom)
@impl true
def handle_info(msg, state) do
  # Same return values as handle_cast
end

# Deferred work after init/call/cast
@impl true
def handle_continue(continue_arg, state) do
  # Same return values as handle_cast
end

# WARNING: Cross-process calls during handle_continue
# When handle_continue calls OTHER GenServers, consider:
# 1. The other process must be started BEFORE yours in the supervision tree
# 2. Default GenServer.call timeout (5000ms) may be too short for initialization
# 3. The other process might also be in its own handle_continue
# 4. If the other process registers via Registry, use its via() helper (see below)
#
# Example: handle_continue that calls into a library's GenServer
@impl true
def handle_continue(:setup, state) do
  # Use explicit timeout for potentially slow initialization operations
  :ok = OtherServer.expensive_operation(via_tuple, _timeout = 30_000)
  {:noreply, %{state | ready: true}}
end

# Cleanup (called on shutdown if trapping exits)
@impl true
def terminate(reason, state) do
  :ok  # Return value ignored
end

# Hot code upgrade
@impl true
def code_change(old_vsn, state, extra) do
  {:ok, new_state}
  {:error, reason}
end

# Redact sensitive state from crash logs and :sys.get_status
# Elixir 1.14+
@impl true
def format_status(status) do
  Map.update!(status, :state, fn state ->
    Map.drop(state, [:password, :secret_key])
  end)
end
```

## gen_statem Callbacks

### Connection Example (state_functions + state_enter)

```elixir
defmodule MyApp.Connection do
  @behaviour :gen_statem

  def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])
  def connect(pid), do: :gen_statem.call(pid, :connect)

  @impl true
  def init(opts), do: {:ok, :disconnected, %{host: opts[:host], retries: 0}}
  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  def disconnected(:enter, _old, data), do: {:keep_state, %{data | retries: 0}}
  def disconnected({:call, from}, :connect, data),
    do: {:next_state, :connecting, data, [{:reply, from, :ok}]}

  def connecting(:enter, _old, data) do
    send(self(), :do_connect)
    {:keep_state_and_data, [{:state_timeout, 5000, :connect_timeout}]}
  end
end
```

**Timeout types:** `{:timeout, ms, event}` (any event cancels), `{:state_timeout, ms, event}` (state change cancels), `{{:timeout, name}, ms, event}` (named, cross-state).

### Callback Reference

```elixir
@impl true
def callback_mode do
  :state_functions                    # State name is callback function
  :handle_event_function              # Single handle_event/4 for all states
  [:state_functions, :state_enter]    # With enter callbacks
end

# State functions mode — one function per state
def state_name(:enter, old_state, data) do
  {:keep_state_and_data, [actions]}
  {:keep_state, new_data, [actions]}
  {:next_state, new_state, new_data, [actions]}
  {:stop, reason, new_data}
end

def state_name(event_type, event_content, data) do
  # event_type: {:call, from} | :cast | :info | :timeout |
  #             {:timeout, name} | :state_timeout | :internal
  {:keep_state_and_data, [actions]}
  {:keep_state, new_data, [actions]}
  {:next_state, new_state, new_data, [actions]}
  {:repeat_state_and_data, [actions]}  # Re-trigger enter callback
  {:stop, reason, new_data}
  {:stop_and_reply, reason, replies, new_data}
end

# Actions list
[
  {:reply, from, reply},                        # Reply to caller
  {:next_event, event_type, content},           # Inject event
  {:state_timeout, time, event_content},        # Cancelled on state change
  {:timeout, time, event_content},              # Cancelled on any event
  {{:timeout, name}, time, event_content},      # Named, independent
  :hibernate,
  :postpone                                     # Re-process in next state
]
```

## Supervisor

### Child Spec

```elixir
%{
  id: MyWorker,                    # Required, unique per supervisor
  start: {MyWorker, :start_link, [arg]},  # Required, {M, F, A}
  restart: :permanent,             # :permanent | :temporary | :transient
  shutdown: 5000,                  # ms timeout | :brutal_kill | :infinity
  type: :worker,                   # :worker | :supervisor
  modules: [MyWorker],             # For hot code upgrade
  significant: false               # For :auto_shutdown (OTP 24+)
}

# Using child_spec/1 (recommended — auto-generated by `use GenServer`)
def child_spec(opts) do
  %{
    id: __MODULE__,
    start: {__MODULE__, :start_link, [opts]},
    restart: :permanent
  }
end

# Shorthand in supervisor children list
children = [
  MyWorker,                        # Uses MyWorker.child_spec([])
  {MyWorker, arg},                 # Uses MyWorker.child_spec(arg)
  %{id: :worker, start: {M, :f, []}}  # Full spec
]
```

### Restart Values

| Value | Restart when |
|-------|--------------|
| `:permanent` | Always (default) |
| `:temporary` | Never |
| `:transient` | Only on abnormal exit (not `:normal` or `:shutdown`) |

### Strategies

| Strategy | When child crashes |
|----------|-------------------|
| `:one_for_one` | Only that child restarts |
| `:one_for_all` | All children restart |
| `:rest_for_one` | That child + children started after it restart |

### Child Spec Defaults

| Field | Default | Notes |
|-------|---------|-------|
| `id` | Required | Must be unique within supervisor |
| `start` | Required | `{M, F, A}` tuple |
| `restart` | `:permanent` | `:permanent`, `:temporary`, `:transient` |
| `shutdown` | `5000` | ms, `:brutal_kill`, or `:infinity` |
| `type` | `:worker` | `:worker` or `:supervisor` |
| `modules` | `[Module]` | For hot code upgrades |

## ETS Cheatsheet

```elixir
# Create
:ets.new(:table, opts)

# Table type options (default :set)
[:set | :ordered_set | :bag | :duplicate_bag]

# Access options (default :protected)
[:public | :protected | :private]

# Performance options
[read_concurrency: true]          # Optimize for concurrent reads
[write_concurrency: true]         # Optimize for concurrent writes
[decentralized_counters: true]    # Fast update_counter (OTP 23+)
[:named_table]                    # Use atom name instead of reference
[{:heir, pid, data}]              # Transfer table on owner death
[:compressed]                     # Compress values (slower access)

# Write
:ets.insert(table, {key, value})
:ets.insert(table, [{k1, v1}, {k2, v2}])  # Atomic batch insert
:ets.insert_new(table, tuple)     # Only if key doesn't exist (atomic)

# Read
:ets.lookup(table, key)           # [{key, value}] or []
:ets.lookup_element(table, key, pos)  # Get element at position
:ets.member(table, key)           # Boolean existence check

# Delete
:ets.delete(table, key)           # Delete by key
:ets.delete_all_objects(table)    # Clear table
:ets.delete(table)                # Destroy table

# Atomic counter operations
:ets.update_counter(table, key, increment)
:ets.update_counter(table, key, {pos, incr})
:ets.update_counter(table, key, {pos, incr, threshold, set_value})

# Iteration (not isolated — table can change between calls)
:ets.first(table)                 # First key or :"$end_of_table"
:ets.next(table, key)             # Next key
:ets.last(table)                  # For ordered_set
:ets.prev(table, key)             # For ordered_set
:ets.tab2list(table)              # All entries (careful with large tables)

# Pattern matching
:ets.match(table, pattern)        # Returns list of bound variables
:ets.match_object(table, pattern) # Returns full matching tuples
:ets.match_delete(table, pattern) # Delete matching entries

# Select (match specs — most powerful)
:ets.select(table, match_spec)
:ets.select_delete(table, match_spec)  # Atomic delete + count
:ets.select_count(table, match_spec)
:ets.select_replace(table, match_spec)  # OTP 21+

# Info
:ets.info(table)                  # All info as keyword list
:ets.info(table, :size)           # Entry count
:ets.info(table, :memory)         # Memory in words
```

## Match Spec Syntax

```elixir
# Format: [{match_pattern, guards, result}]

# Match all, return all
[{:_, [], [:"$_"]}]

# Pattern variables
:"$1", :"$2", ...  # Bound variables (positional)
:_                  # Wildcard (match anything, don't bind)
:"$_"               # Entire matched object (in result)
:"$$"               # All bound variables as list (in result)

# Guard operations
[{:>, :"$1", 10}]                                    # $1 > 10
[{:andalso, {:>, :"$1", 0}, {:<, :"$1", 100}}]      # 0 < $1 < 100
[{:orelse, {:==, :"$1", :admin}, {:==, :"$2", true}}] # $1 == :admin or $2 == true

# Example: Select users over 18, return {id, name}
:ets.select(:users, [
  {{:"$1", :"$2", :"$3"},           # Match {id, name, age}
   [{:>, :"$3", 18}],                # Guard: age > 18
   [{{:"$1", :"$2"}}]}               # Return: {id, name}
])

# Build match specs with :ets.fun2ms (compile-time only in Erlang)
# In Elixir, use Ex2ms library or write specs manually
```

## Process Registry Patterns

```elixir
# Local name (atom — limited, use for singletons only)
GenServer.start_link(__MODULE__, arg, name: MyServer)
GenServer.call(MyServer, :request)

# Global name (cluster-wide, eventually consistent)
GenServer.start_link(__MODULE__, arg, name: {:global, {:server, id}})
GenServer.call({:global, {:server, id}}, :request)

# Via Registry (recommended for dynamic processes)
GenServer.start_link(__MODULE__, arg, name: {:via, Registry, {MyReg, id}})
GenServer.call({:via, Registry, {MyReg, id}}, :request)

# Via PartitionSupervisor (load distribution)
GenServer.call({:via, PartitionSupervisor, {MyPool, key}}, :request)
```

### Registry Naming Mismatch Trap

> **WARNING:** When a process registers via `{:via, Registry, ...}`, callers MUST use the same via tuple to address it. A raw atom name will NOT resolve to a Registry-registered process — the error message is misleading ("no process") even though the process is alive.

```elixir
# BAD: Calling a Registry-registered process by raw atom name
# The process IS alive, but :my_worker doesn't resolve to it
GenServer.call(:my_worker, :ping)
# => ** (EXIT) no process associated with the given name

# GOOD: Use the same via tuple the process registered with
GenServer.call({:via, Registry, {MyApp.Registry, :my_worker}}, :ping)
# => :pong

# BEST: Library provides a via() helper — always use it
GenServer.call(MyApp.Registry.via(:my_worker), :ping)
```

This is especially dangerous when consuming NIF libraries or third-party libraries that register processes via Registry internally. The library's `start_link/1` accepts the via tuple silently — there's no hint at the call site that callers must use the same tuple. Always check how a library registers its processes and use the same naming mechanism.

### Registry Comparison

| Feature | Registry | :global | :pg | Horde |
|---------|----------|---------|-----|-------|
| Scope | Local node | Cluster | Cluster | Cluster |
| Unique keys | Yes | Yes | No (groups) | Yes |
| Duplicate keys | Yes | No | Yes | Yes |
| Partitioned | Yes | No | No | No |
| Consistency | Strong | Eventual | Eventual | Eventual |
| Net-split safe | N/A | No | Yes | Configurable |
| Performance | Excellent | Good | Good | Good |

## Process Info Keys

```elixir
Process.info(pid, key)

# Most useful keys
:message_queue_len     # Mailbox size (first check for overload)
:memory                # Process memory in bytes
:reductions            # Work done (proxy for CPU usage)
:current_function      # {module, function, arity}
:current_stacktrace    # Full stack trace
:status                # :running | :waiting | :suspended
:registered_name       # Atom name or []
:links                 # Linked PIDs
:monitors              # Active monitors
:monitored_by          # Who monitors this process
:heap_size             # Heap in words
:total_heap_size       # Total heap in words
:dictionary            # Process dictionary contents
:trap_exit             # Whether trapping exits
:initial_call          # Initial {M, F, A}
:messages              # Mailbox contents (EXPENSIVE — copies all messages)
:binary                # Binary references held
:garbage_collection    # GC settings
```

## :sys Module — Debugging OTP Processes

```elixir
# Works with: pid | name | {:global, name} | {:via, mod, name}

# State inspection
:sys.get_state(server)             # Get GenServer/gen_statem state
:sys.get_status(server)            # Get full status tuple
:sys.replace_state(server, fun)    # Replace state (debugging only!)

# Tracing
:sys.trace(server, true)           # Enable trace output to stdout
:sys.trace(server, false)          # Disable trace

# Statistics
:sys.statistics(server, true)      # Enable statistics collection
:sys.statistics(server, :get)      # Get collected statistics
:sys.statistics(server, false)     # Disable and clear

# Process control
:sys.suspend(server)               # Suspend message processing
:sys.resume(server)                # Resume processing
:sys.terminate(server, reason)     # Terminate with reason

# Hot code upgrade
:sys.change_code(server, mod, old_vsn, extra)
```

## Node Operations

```elixir
# Current node
node()                             # Current node name
Node.self()                        # Same as node()
Node.alive?()                      # Is this distributed?

# Connection
Node.connect(:"node@host")         # Returns true | false | :ignored
Node.disconnect(:"node@host")
Node.ping(:"node@host")            # :pong | :pang

# Discovery
Node.list()                        # Connected visible nodes
Node.list(:hidden)                 # Hidden nodes
Node.list(:connected)              # All connected
Node.list(:known)                  # All known (including disconnected)

# Remote spawn
Node.spawn(node, fun)
Node.spawn_link(node, fun)
```

## RPC / ERPC

```elixir
# rpc — original, returns {:badrpc, reason} on failure
:rpc.call(node, mod, fun, args)
:rpc.call(node, mod, fun, args, timeout)
:rpc.multicall(nodes, mod, fun, args)

# Async rpc
key = :rpc.async_call(node, mod, fun, args)
:rpc.yield(key)                    # Blocking wait
:rpc.nb_yield(key)                 # Non-blocking check
:rpc.nb_yield(key, timeout)

# erpc (OTP 23+) — better errors, raises on failure
:erpc.call(node, fun)
:erpc.call(node, mod, fun, args)
:erpc.call(node, mod, fun, args, timeout)
:erpc.multicall(nodes, fun)        # Returns [{:ok, val} | {:error, reason}]
:erpc.multicast(nodes, fun)        # Fire-and-forget, no return
```

## Application Callbacks

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(type, start_args) do
    # type: :normal | {:takeover, node} | {:failover, node}
    children = [...]
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(state) do
    :ok  # Cleanup after application stops
  end

  @impl true
  def prep_stop(state) do
    # Called before stop — drain connections, flush queues
    state
  end

  @impl true
  def config_change(changed, new, removed) do
    # Called on runtime config change
    :ok
  end
end
```

## Release Commands

```bash
# Build
MIX_ENV=prod mix release

# Run
bin/my_app start           # Start in background
bin/my_app start_iex       # Start with IEx attached
bin/my_app daemon          # Start as daemon
bin/my_app daemon_iex      # Daemon with IEx

# Control
bin/my_app stop            # Graceful stop
bin/my_app restart         # Restart
bin/my_app pid             # Print OS PID

# Remote access
bin/my_app remote          # Connect IEx to running node
bin/my_app rpc "expr"      # Evaluate in running node context
bin/my_app eval "expr"     # Evaluate in fresh temporary node

# Hot upgrade
bin/my_app upgrade "1.2.0" # Upgrade to version (requires appup)
```

## Common Telemetry Events

```elixir
# Phoenix
[:phoenix, :endpoint, :start | :stop]
[:phoenix, :router_dispatch, :start | :stop]
[:phoenix, :live_view, :mount, :start | :stop]
[:phoenix, :live_view, :handle_event, :start | :stop]

# Ecto
[:my_app, :repo, :query]          # Every query (includes decode_time, query_time)
[:ecto, :repo, :init]

# Oban
[:oban, :job, :start | :stop | :exception]

# VM (polled by :telemetry_poller)
[:vm, :memory]
[:vm, :total_run_queue_lengths]
[:vm, :system_counts]
```

## Debugging Quick Reference

```elixir
# Process overview
Process.list() |> length()         # Total process count
Process.registered()               # All named processes
:observer.start()                  # GUI observer (if available)

# Find problem processes (requires :recon dependency)
:recon.proc_count(:memory, 10)             # Top 10 by memory
:recon.proc_count(:message_queue_len, 10)  # Top 10 by mailbox
:recon.proc_count(:reductions, 10)         # Top 10 by CPU work

# Trace with safety limits
:recon_trace.calls({Mod, :fun, :_}, 100)   # Max 100 traces

# Memory analysis
:erlang.memory()                   # System memory breakdown
:erlang.memory(:binary)            # Binary heap size
:recon.bin_leak(10)                # Top 10 binary leak suspects

# Per-process debugging
:sys.get_state(pid)                # Current state
:sys.trace(pid, true)              # Enable trace
Process.info(pid, :message_queue_len)  # Check mailbox

# ETS memory
:ets.info(table, :memory) * :erlang.system_info(:wordsize)  # Bytes
```

## Common Exit Reasons

| Reason | Meaning | Supervisor action |
|--------|---------|-------------------|
| `:normal` | Clean exit | Restart if `:permanent` |
| `:shutdown` | Graceful shutdown requested | No restart |
| `{:shutdown, term}` | Graceful with info | No restart |
| `:killed` | `Process.exit(pid, :kill)` | Restart |
| `:timeout` | GenServer call timeout | Restart |
| `:noproc` | Process doesn't exist | N/A (caller error) |
| `:noconnection` | Node disconnected | Restart |
| `{:nodedown, node}` | Monitored node went down | Restart |

## Hot Code Upgrade Cheatsheet

### Code Module Commands

```elixir
:code.is_loaded(MyModule)           # {file, path} | false
:code.which(MyModule)               # Path to .beam file
:code.get_object_code(MyModule)     # {Module, binary, path}

:code.load_file(MyModule)           # Load from code path
:code.load_binary(Mod, path, bin)   # Load from binary

:code.soft_purge(MyModule)          # Safe — fails if processes in old
:code.purge(MyModule)               # DANGEROUS — kills processes in old

:erlang.check_process_code(pid, Module)  # true if process runs old code
```

### Appup Instructions

| Instruction | Format | Description |
|-------------|--------|-------------|
| Load module | `{load_module, Mod}` | Simple code reload |
| Update process | `{update, Mod, Change}` | `Change` = `:soft` or `{:advanced, Extra}` |
| Update with deps | `{update, Mod, Change, Deps}` | Suspend deps first |
| Add module | `{add_module, Mod}` | For new modules |
| Delete module | `{delete_module, Mod}` | Remove module |
| Add application | `{add_application, App}` | Start new app |
| Remove application | `{remove_application, App}` | Stop and remove |
| Restart application | `{restart_application, App}` | Full restart |
| Apply function | `{apply, {M, F, A}}` | Run arbitrary code |

### Release Handler

```elixir
:release_handler.which_releases()              # List installed
:release_handler.unpack_release(~c"vsn")       # Unpack tarball
:release_handler.install_release(~c"vsn")      # Make current
:release_handler.make_permanent(~c"vsn")       # Survives restart
:release_handler.reboot_old_release(~c"vsn")   # Rollback
:release_handler.remove_release(~c"vsn")       # Clean up
```

## Memory Analysis

```elixir
# System memory breakdown
:erlang.memory()
# => [total: _, processes: _, atom: _, binary: _, ets: _, ...]

# Per-process
Process.info(pid, :memory)          # Bytes
Process.info(pid, :heap_size)       # Words
Process.info(pid, :total_heap_size) # Words including stack

# ETS table memory (words → bytes)
:ets.info(table, :memory) * :erlang.system_info(:wordsize)

# Binary heap
:erlang.memory(:binary)
:recon.bin_leak(10)                 # Find processes leaking binaries

# Force GC (debugging only)
:erlang.garbage_collect(pid)
```

## OTP Version Features

| OTP Version | Key Features |
|-------------|--------------|
| 21 | Logger, :persistent_term, :counters, :atomics |
| 22 | :socket module, TLS 1.3 |
| 23 | :erpc module, JIT (experimental) |
| 24 | JIT default, PartitionSupervisor, significant children |
| 25 | Selectable features, Map improvements |
| 26 | Documentation improvements, new shell |
| 27 | Better JSON support, documentation metadata |

## Extended OTP Reference (from main skill)

### format_status — Hiding Sensitive State

Prevent passwords, tokens, and API keys from appearing in crash logs and `:sys.get_status`:

```elixir
defmodule MyApp.SecureServer do
  use GenServer

  # Elixir 1.17+ format_status/1 (map-based)
  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, Map.delete(state, :api_key)}
      {:message, {:password, _}} -> {:message, {:password, "redacted"}}
      key_value -> key_value
    end)
  end
end
```

### Call vs Cast Decision Framework

| Aspect | Call (Synchronous) | Cast (Asynchronous) |
|--------|-------------------|---------------------|
| **Response** | Caller waits for response | Fire-and-forget |
| **Backpressure** | Natural — caller blocks | None — mailbox can grow |
| **Error visibility** | Failures propagate to caller | Failures silent to caller |
| **Throughput** | Limited by target process | Higher, but risks overload |
| **Use when** | Data consistency critical | Logging, metrics, notifications |

```elixir
# Intermediate queue pattern: responsiveness + reliability
defmodule OrderQueue do
  use GenServer

  def submit(order), do: GenServer.call(__MODULE__, {:enqueue, order})

  @impl true
  def handle_call({:enqueue, order}, _from, state) do
    new_state = %{state | queue: :queue.in(order, state.queue)}
    schedule_processing()
    {:reply, {:ok, :queued}, new_state}
  end

  @impl true
  def handle_info(:process_batch, state) do
    {orders, remaining} = take_batch(state.queue, 100)
    Task.Supervisor.async_nolink(MyApp.TaskSup, fn -> process_orders(orders) end)
    {:noreply, %{state | queue: remaining}}
  end
end
```

### Raw Process Patterns (spawn_link, send, receive)

The foundation that GenServer, Task, and supervision are built on. Use raw processes when:
- GenServer is too heavy (simple fire-and-forget loops)
- Task is unavailable (AtomVM, minimal BEAM targets)
- You need a long-running linked loop (accept loops, handler loops)

**spawn_link + receive loop with state:**

```elixir
# Long-running process with state — the raw equivalent of GenServer
defp worker_loop(state) do
  receive do
    {:work, data, reply_to} ->
      result = process(data)
      send(reply_to, {:result, result})
      worker_loop(state)

    {:update_config, new_config} ->
      worker_loop(%{state | config: new_config})

    :stop ->
      :ok   # Exit normally — linked processes are NOT killed on :normal exit
  after
    30_000 ->
      do_periodic_work(state)
      worker_loop(state)
  end
end

# Start from GenServer
me = self()
pid = spawn_link(fn -> worker_loop(%{parent: me, config: opts}) end)
```

**Reporting back to parent via send:**

```elixir
# Child process reports events to parent GenServer
defp accept_loop(listen_socket, parent) do
  case :gen_tcp.accept(listen_socket) do
    {:ok, socket} ->
      send(parent, {:new_connection, socket})
      accept_loop(listen_socket, parent)
    {:error, :closed} ->
      send(parent, :listener_closed)
  end
end

# Parent handles in handle_info
def handle_info({:new_connection, socket}, state), do: ...
def handle_info(:listener_closed, state), do: {:stop, :normal, state}
```

**Crash propagation — what happens when a linked process dies:**

```elixir
# Without trap_exit: linked process crash kills the parent too
pid = spawn_link(fn -> raise "boom" end)
# Parent receives EXIT signal → also crashes (unless supervised)

# With trap_exit: EXIT signals become messages
Process.flag(:trap_exit, true)
pid = spawn_link(fn -> raise "boom" end)
# Parent receives {:EXIT, pid, {%RuntimeError{}, stacktrace}} as a message

# trap_exit in GenServer — handle linked process death gracefully
@impl true
def init(opts) do
  Process.flag(:trap_exit, true)
  pid = spawn_link(fn -> some_loop() end)
  {:ok, %{worker: pid}}
end

@impl true
def handle_info({:EXIT, pid, reason}, %{worker: pid} = state) do
  Logger.warning("Worker died: #{inspect(reason)}")
  new_pid = spawn_link(fn -> some_loop() end)   # Restart manually
  {:noreply, %{state | worker: new_pid}}
end
```

**Exit reason classification:**

| Reason | Meaning | Linked process behavior |
|--------|---------|------------------------|
| `:normal` | Clean exit | Link does NOT propagate (unless trapping) |
| `:shutdown` | Orderly shutdown | Propagates, treated as expected shutdown |
| `{:shutdown, term}` | Shutdown with info | Propagates, not logged by default |
| Any other term | Abnormal exit | Propagates, kills linked processes, logged |

**When to use raw processes vs GenServer vs Task:**

| Situation | Use | Why |
|-----------|-----|-----|
| Stateful request/response | GenServer | Client API, timeouts, supervision |
| One-off parallel work | Task | Automatic linking, await/yield, async_stream |
| Simple long-running loop | `spawn_link` + `receive` | Less overhead, no GenServer state machine |
| AtomVM / minimal BEAM | `spawn_link` + `receive` | Task may not be available |
| Accept loops, handler loops | `spawn_link` from GenServer | Expendable child, parent traps exits |
| Fire-and-forget side effect | `spawn` (no link) | Crash doesn't affect parent |

### Links vs Monitors

```elixir
# Links — bidirectional, crash propagates both ways
# Use: parent-child relationships (supervision)
spawn_link(fn -> do_work() end)
Process.link(pid)
Process.unlink(pid)

# Monitors — unidirectional, receive :DOWN message
# Use: observing processes you don't own
ref = Process.monitor(pid)
receive do
  {:DOWN, ^ref, :process, ^pid, reason} -> handle_down(reason)
end
Process.demonitor(ref, [:flush])  # Cancel + flush :DOWN from mailbox
```

**In GenServer — monitoring external processes:**

```elixir
# Pattern from IEx.Broker: monitor registered processes, cleanup on crash
@impl true
def handle_call({:register, pid}, _from, state) do
  ref = Process.monitor(pid)
  {:reply, :ok, put_in(state.tracked[ref], pid)}
end

@impl true
def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
  {_pid, state} = pop_in(state.tracked[ref])
  {:noreply, state}
end
```

**Decision: Link vs Monitor**

| Use Link when... | Use Monitor when... |
|-----------------|---------------------|
| Parent-child relationship | Observing independent process |
| Crash should propagate | Crash should be handled gracefully |
| Supervisor manages lifecycle | You need to react, not crash |
| `spawn_link`, `Task.async` | `Process.monitor`, `Task.async_nolink` |

### Supervisor + Registry Composition

When Registry and DynamicSupervisor are tightly coupled, wrap them in a parent supervisor with `:one_for_all` — if Registry crashes, DynamicSupervisor must restart too (stale registrations):

```elixir
defmodule MyApp.WorkerManager do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: MyApp.WorkerRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: MyApp.WorkerSupervisor}
    ]

    # one_for_all: Registry crash → restart DynamicSupervisor too
    Supervisor.init(children, strategy: :one_for_all)
  end
end

# In application.ex, just list the manager
children = [MyApp.WorkerManager]
```

### PartitionSupervisor for Scaling

Distribute load across multiple process instances:

```elixir
defmodule ScaledWorker do
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)  # No name

  def call(key, msg) do
    {:via, PartitionSupervisor, {ScaledWorkerSupervisor, key}}
    |> GenServer.call(msg)  # Routes by phash2(key)
  end
end

children = [
  {PartitionSupervisor,
    child_spec: ScaledWorker.child_spec([]),
    name: ScaledWorkerSupervisor,
    partitions: System.schedulers_online()}
]
```

### Child Spec Reference (Extended)

Every supervised process needs a child spec. `use GenServer` generates one automatically, but you can customize:

```elixir
# Override via use macro
use GenServer, restart: :transient, shutdown: 10_000

# Or explicit child_spec/1
def child_spec(opts) do
  %{
    id: __MODULE__,              # Unique identifier (default: module name)
    start: {__MODULE__, :start_link, [opts]},  # MFA tuple
    restart: :permanent,         # :permanent | :transient | :temporary
    shutdown: 5_000,             # milliseconds | :infinity | :brutal_kill
    type: :worker                # :worker | :supervisor
  }
end
```

**Shutdown semantics:**
- **Integer (default 5000)** — sends `:shutdown` exit signal, waits N ms, then kills
- **`:infinity`** — waits forever (ALWAYS use for supervisor children)
- **`:brutal_kill`** — `Process.exit(pid, :kill)` immediately, no cleanup

```elixir
# Override child spec inline in supervision tree
children = [
  Supervisor.child_spec({Worker, []}, id: :worker_1, restart: :temporary),
  Supervisor.child_spec({Worker, []}, id: :worker_2, restart: :temporary)
]
```

### ETS Advanced Patterns

#### Match Specs (Extended)

Pattern from Elixir's `Registry` — complex queries without leaving the VM:

```elixir
# Match spec format: [{match_pattern, guards, result}]
# Variables: :"$1", :"$2" (capture), :_ (wildcard), :"$_" (entire object)

# Select users over 18, return {id, name}
:ets.select(:users, [
  {{:"$1", :"$2", :"$3"},           # {id, name, age}
   [{:>, :"$3", 18}],                # Guard: age > 18
   [{{:"$1", :"$2"}}]}               # Result: {id, name}
])

# Count matching entries
:ets.select_count(:cache, [
  {{:_, {:_, :"$1"}}, [{:>, :"$1", 0}], [true]}
])

# Delete expired entries atomically
now = System.monotonic_time(:millisecond)
:ets.select_delete(:cache, [
  {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
])
```

#### Atomic Operations (Extended)

```elixir
# Atomic counter — no read-modify-write race
:ets.update_counter(:counters, :page_views, 1)

# With default value (create key if missing)
:ets.update_counter(:counters, key, 1, {key, 0})

# Threshold: increment pos 2 by 1, max 100, reset to 100
:ets.update_counter(:counters, key, {2, 1, 100, 100})

# Atomic insert-if-absent (from Registry)
if :ets.insert_new(table, {key, value}) do
  :ok
else
  # Key already exists — handle race condition
  [{^key, existing}] = :ets.lookup(table, key)
  existing
end

# Atomic field update without full record replacement
:ets.update_element(table, key, {3, new_value})  # Update position 3
```

#### Table Types

| Type | Duplicates | Ordering | Use Case |
|------|-----------|----------|----------|
| `:set` (default) | No | Hash | Key-value cache, unique lookups |
| `:ordered_set` | No | Key order | Range queries, sorted data |
| `:bag` | Yes (diff tuples) | Hash | Multi-value associations |
| `:duplicate_bag` | Yes (any) | Hash | Event logs, Registry internals |

#### ETS Heir Mechanism

Transfer table ownership when owner process dies:

```elixir
# Create table with heir
:ets.new(:cache, [:named_table, :public, {:heir, supervisor_pid, :cache_data}])

# When owner dies, heir receives:
# {:ETS-TRANSFER, table, from_pid, heir_data}
def handle_info({:"ETS-TRANSFER", table, _from, _data}, state) do
  {:noreply, %{state | table: table}}
end
```

### :persistent_term — Rarely-Changing Global Data

Pattern from `Mix.State` — fast reads, expensive writes:

```elixir
# Write (expensive — copies to all processes, triggers global GC)
:persistent_term.put({MyApp, :config}, config)

# Read (very fast — no copying, direct memory reference)
:persistent_term.get({MyApp, :config})
:persistent_term.get({MyApp, :config}, default)

# Erase
:persistent_term.erase({MyApp, :config})

# Good for: compiled regexes, schema definitions, feature flags
# Bad for: frequently updated data (causes global GC on each write)
```

### :counters and :atomics

Lock-free concurrent data structures. Pattern from `Logger.Backends`:

```elixir
# Counters — multi-position atomic counters
counter = :counters.new(3, [:atomics])  # 3 positions, lock-free
:counters.add(counter, 1, 1)            # Increment position 1
:counters.get(counter, 1)               # Read position 1
:counters.put(counter, 2, 42)           # Set position 2

# Logger uses counters for threshold-based dispatching:
:counters.add(counter, @pos, 1)
value = :counters.get(counter, @pos)
cond do
  value >= discard_threshold -> :discard
  value >= sync_threshold -> :sync
  true -> :async
end

# Atomics — single values with atomic operations
ref = :atomics.new(1, [])
:atomics.put(ref, 1, 0)
:atomics.add(ref, 1, 1)
:atomics.get(ref, 1)
:atomics.compare_exchange(ref, 1, expected, desired)
```

## `send(self(), ...)` vs `handle_continue` — Deferred Work Decision

Both patterns defer work after `init/1` returns, but they have different semantics:

| Pattern | Behavior | Use When |
|---|---|---|
| `{:ok, state, {:continue, :init}}` | Runs **before** any other message | Init must complete before serving requests |
| `send(self(), :init_work)` | Goes through **mailbox** — interleaved with other messages | Server should accept requests during init |

### handle_continue (default choice)

```elixir
def init(opts) do
  {:ok, %{data: nil}, {:continue, :load_data}}
end

@impl true
def handle_continue(:load_data, state) do
  data = expensive_load()
  {:noreply, %{state | data: data}}
end
# No messages processed until handle_continue completes
```

### send(self(), ...) — Pool/Cache Pattern (NimblePool)

```elixir
def init(opts) do
  send(self(), {__MODULE__, :init_worker})
  {:ok, %{workers: [], pending: :queue.new()}}
end

@impl true
def handle_info({__MODULE__, :init_worker}, state) do
  # Initialize one worker, then schedule next
  worker = create_worker()
  send(self(), {__MODULE__, :init_worker})
  {:noreply, %{state | workers: [worker | state.workers]}}
end

# Client requests are served between worker initializations:
@impl true
def handle_call(:checkout, from, state) do
  # Can serve from already-initialized workers while more are starting
  {:reply, hd(state.workers), state}
end
```

**NimblePool uses self-sends** because a pool should serve checkouts as soon as *any* worker is ready, not wait for *all* workers to initialize.

## Process Monitor Lifecycle Pattern

The complete monitor/demonitor pattern with `:flush` (NimblePool pattern):

```elixir
# 1. Monitor client on checkout
mon_ref = Process.monitor(client_pid)
state = put_in(state.monitors[mon_ref], request_ref)

# 2. Handle client crash — clean up resources
@impl true
def handle_info({:DOWN, mon_ref, :process, _pid, _reason}, state) do
  case Map.pop(state.monitors, mon_ref) do
    {nil, _} -> {:noreply, state}  # Unknown monitor
    {request_ref, monitors} ->
      # Return resource to pool, clean up request
      {:noreply, %{state | monitors: monitors} |> return_resource(request_ref)}
  end
end

# 3. Demonitor on successful checkin — ALWAYS use [:flush]
Process.demonitor(mon_ref, [:flush])
state = Map.delete(state.monitors, mon_ref)
```

**Why `[:flush]`:** Without it, a `:DOWN` message that was already in the mailbox before `demonitor` will still be processed, causing double-cleanup or crashes. The `:flush` option removes any pending `:DOWN` message for that reference.

## Deadline-Based Timeouts (NimblePool Pattern)

Convert relative timeouts to absolute monotonic deadlines to avoid serving stale requests:

```elixir
defp deadline(timeout) when is_integer(timeout) do
  System.monotonic_time() + System.convert_time_unit(timeout, :millisecond, :native)
end

defp past_deadline?(deadline) do
  System.monotonic_time() > deadline
end

# In handle_call — attach deadline to queued request
def handle_call({:checkout, timeout}, from, state) do
  {:noreply, enqueue(state, from, deadline(timeout))}
end

# When serving from queue — check if request is still fresh
defp serve_next(%{queue: q} = state) do
  case :queue.out(q) do
    {{:value, {from, deadline}}, q} ->
      if past_deadline?(deadline) do
        # Client already timed out — skip, try next
        serve_next(%{state | queue: q})
      else
        GenServer.reply(from, {:ok, resource})
        %{state | queue: q}
      end
    {:empty, _} -> state
  end
end
```

**Why not just use GenServer.call timeout?** The default timeout only raises on the *caller* side. The server still processes the request and wastes a resource on a client that has already given up. Deadlines let the server skip stale requests.

## `:rest_for_one` with Pipeline Processes (Quantum Pattern)

When processes form a pipeline (producer → consumer chain), use `:rest_for_one` so that crashing a producer restarts all downstream consumers (whose subscriptions are now invalid):

```elixir
# Quantum's supervision tree — 8 processes in pipeline order
children = [
  {Task.Supervisor, name: MyApp.TaskSupervisor},  # 1. Independent infra
  {Storage, storage_opts},                          # 2. Persistence
  {ClockBroadcaster, clock_opts},                   # 3. Producer: ticks
  {TaskRegistry, registry_opts},                    # 4. Overlap tracking
  {JobBroadcaster, job_opts},                       # 5. Producer: job CRUD
  {ExecutionBroadcaster, exec_opts},                # 6. Consumer+Producer: scheduling
  {NodeSelectorBroadcaster, node_opts},             # 7. Consumer+Producer: node selection
  {ExecutorSupervisor, executor_opts}               # 8. Consumer: runs tasks
]

Supervisor.init(children, strategy: :rest_for_one)
# If ClockBroadcaster (3) crashes, processes 4-8 restart too
# If Storage (2) crashes, processes 3-8 restart
# ExecutorSupervisor (8) crashing doesn't affect anything upstream
```

**When to use `:rest_for_one`:**
- GenStage/Broadway-style pipelines where downstream subscribes to upstream
- Process chains where later processes depend on earlier ones' state
- NOT for independent processes (use `:one_for_one`) or tightly-coupled pairs (use `:one_for_all`)

## Related Files

- **[SKILL.md](SKILL.md)** — OTP rules, GenServer/gen_statem key patterns, supervisor strategies, decision frameworks
- **[otp-advanced.md](otp-advanced.md)** — GenStage, Flow, Broadway, hot code upgrades, production debugging
- **[otp-examples.md](otp-examples.md)** — Complete implementations: rate limiter, connection state machine, worker pool, circuit breaker, cache
- **[production.md](production.md)** — Production patterns, telemetry, periodic work, graceful shutdown
