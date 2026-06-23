# Elixir Debugging & Profiling Reference

> Supporting reference for the [Elixir skill](SKILL.md). Contains IO.inspect, dbg, IEx.pry, break!, Rexbug tracing, system introspection, Logger, mix profile (fprof/eprof/cprof/tprof), Benchee, memory profiling, VM/scheduler profiling, allocator profiling, :sys module tracing, and telemetry-based profiling.

## Rules for Debugging & Profiling (LLM)

1. **ALWAYS start with `IO.inspect` or `dbg`** before reaching for heavier tools — most bugs are found with simple value inspection.
2. **ALWAYS use `dbg()` over `IO.inspect` in pipelines** (Elixir 1.14+) — it shows every intermediate step automatically.
3. **NEVER use `:dbg` or `:erlang.trace` in production** — no safety limits, can crash nodes. Use `:recon_trace` or Rexbug with explicit message count limits.
4. **ALWAYS use `System.monotonic_time` for duration measurement** — never `System.system_time` (jumps on NTP sync).
5. **ALWAYS use Benchee for comparisons** — never single `:timer.tc` calls (no warmup, no statistical analysis).
6. **PREFER `:sys.trace` over manual message inspection** for debugging OTP process message flow — it shows formatted in/out messages.

## Common Mistakes (BAD/GOOD)

**Profiling without warmup or statistics:**
```elixir
# BAD: Single measurement — JIT not warmed up, no variance info
{usec, _} = :timer.tc(fn -> my_function() end)
IO.puts("Took #{usec}μs")  # Misleading — could be 10x slower than steady-state
```

```elixir
# GOOD: Benchee with warmup and statistical analysis
Benchee.run(%{"my_function" => fn -> my_function() end}, warmup: 2, time: 5)
```

**Unsafe production tracing:**
```elixir
# BAD: No limits — unbounded trace messages can crash the node
:dbg.tracer()
:dbg.p(:all, :c)
:dbg.tp(MyModule, :_, :x)
```

```elixir
# GOOD: recon_trace with automatic limit
:recon_trace.calls({MyModule, :_, :return_trace}, 100)  # Stops after 100 traces
:recon_trace.clear()
```

## Debugging

### IO.inspect/2

```elixir
data
|> transform()
|> IO.inspect(label: "After transform")
|> validate()
|> IO.inspect(label: "After validate", limit: 5)

# Options: label, limit, pretty, width, charlists: :as_lists
```

### dbg/2 (Elixir 1.14+)

A macro that prints the AST and result of each step. Returns the value unchanged, so it's pipeline-safe.

```elixir
# Pipeline — shows every intermediate step with values
[1, 2, 3]
|> Enum.map(&(&1 * 2))
|> Enum.filter(&(&1 > 2))
|> dbg()
# Prints:
#   [1, 2, 3] #=> [1, 2, 3]
#   |> Enum.map(&(&1 * 2)) #=> [2, 4, 6]
#   |> Enum.filter(&(&1 > 2)) #=> [4, 6]

# Non-pipeline expressions — works with case, cond, with, if
case Map.fetch(data, :key) do
  {:ok, value} -> process(value)
  :error -> default()
end
|> dbg()  # Shows the matched clause and result

# No args — shows all current bindings
def process(data, opts) do
  result = transform(data)
  dbg()  # Prints: data => ..., opts => ..., result => ...
  finalize(result)
end

# Returns value — can insert anywhere without breaking the chain
value = dbg(expensive_computation())  # prints and returns
```

**dbg with pry mode:**

```elixir
# Make dbg drop into IEx.pry instead of printing
# Start IEx with:
iex --dbg pry -S mix

# Now dbg() pauses execution like IEx.pry()
data
|> transform()
|> dbg()  # Pauses here, inspect bindings
```

**Custom dbg backend:**

```elixir
# Route dbg output to Logger instead of IO
Application.put_env(:elixir, :dbg_callback, {MyApp.Debug, :log_dbg, []})

defmodule MyApp.Debug do
  def log_dbg(code, options, env) do
    header = "#{env.file}:#{env.line}"
    result = Macro.dbg(code, options, env)
    Logger.debug("dbg at #{header}: #{inspect(result)}")
    result
  end
end
```

### IEx.pry — Interactive Breakpoint Debugging

Insert `IEx.pry()` to pause execution and inspect the live environment:

```elixir
require IEx

def process(data) do
  result = transform(data)
  IEx.pry()  # Execution pauses here
  save(result)
end

# MUST run inside IEx — plain `mix run` won't work
# For mix projects:
iex -S mix
# For Phoenix:
iex -S mix phx.server
# To make dbg() also use pry:
iex --dbg pry -S mix
```

**Inside a pry session:**

```elixir
# All local variables are available directly
iex> data          # inspect the `data` argument
iex> result        # inspect local `result` binding
iex> self()        # current process PID
iex> Process.info(self(), :message_queue_len)  # check mailbox

# Evaluate any expression in the paused context
iex> Map.keys(result)
iex> Enum.count(data.items)

# Navigate the stack (Elixir 1.14+)
iex> whereami()    # show surrounding source code

# Continue execution
iex> continue()    # or just `c` — resumes the paused process
# Or press Ctrl+C twice to abort (kills the process)

# IMPORTANT: If pry times out (default 5s for GenServer calls),
# the calling process gets a timeout error. For GenServer debugging,
# increase the timeout or pry in a Task:
GenServer.call(pid, :msg, :infinity)
```

**Pry in tests:**

```elixir
# In test file:
test "debugging a failing case", %{conn: conn} do
  result = MyApp.process(input)
  require IEx; IEx.pry()   # one-liner for quick insertion
  assert result == expected
end

# Run with: iex -S mix test test/my_test.exs:42
# The --trace flag helps avoid timeouts:
# iex -S mix test --trace test/my_test.exs:42
```

**Pry in LiveView/GenServer (avoid timeout):**

```elixir
# BAD: pry in handle_call blocks the caller
def handle_call(:get, _from, state) do
  IEx.pry()  # caller times out after 5s!
  {:reply, state, state}
end

# GOOD: pry in handle_info or handle_continue (no caller waiting)
def handle_info(:debug, state) do
  IEx.pry()  # safe — no process waiting for reply
  {:noreply, state}
end
# Trigger: send(pid, :debug)

# GOOD: pry in a Task for one-off inspection
Task.start(fn ->
  state = :sys.get_state(pid)
  IEx.pry()
end)
```

### break!/1 (No Code Changes)

Set breakpoints from IEx without editing source code:

```elixir
# Set a breakpoint on a function
iex> break!(MyApp.Service.process/1)
# With a condition (only break when pattern matches)
iex> break!(MyApp.Service.process/1, 3)  # break on 3rd call only

# Manage breakpoints
iex> breaks()          # list all breakpoints
iex> remove_breaks()   # remove all
iex> remove_breaks(1)  # remove breakpoint #1

# Combine with pattern matching — break only for specific args
iex> break!(MyApp.Service.process(data) when is_list(data))

# After hitting a breakpoint, same commands as pry:
# whereami(), continue(), inspect variables directly
```

### Rexbug (Production-Safe Tracing)

```elixir
# Add {:rexbug, "~> 1.0"}
Rexbug.start("MyApp.Service.process/1", return_trace: true)
Rexbug.start("MyApp.Service._", time: 10_000, msgs: 100)  # Limits for safety
```

### System Introspection (Programmatic)

Inspect a running system without a GUI — works in IEx, remote shells, and scripts:

```elixir
# === Memory ===
:erlang.memory()
# => [total: 48_372_736, processes: 15_234_048, atom: 1_048_577,
#     binary: 3_276_800, ets: 2_097_152, ...]

:erlang.memory(:binary)          # just binary heap (large binary leaks show here)
:erlang.memory(:processes_used)  # actual process memory in use

# === Process health ===
:erlang.system_info(:process_count)  # total live processes
:erlang.statistics(:run_queue)       # scheduler backlog (0 = healthy, sustained >0 = overloaded)

# === Find top memory/message-queue processes ===
Process.list()
|> Enum.map(fn pid ->
  info = Process.info(pid, [:registered_name, :memory, :message_queue_len, :reductions])
  {pid, info}
end)
|> Enum.sort_by(fn {_, info} -> info[:memory] end, :desc)
|> Enum.take(10)
|> Enum.each(fn {pid, info} ->
  name = info[:registered_name] || pid
  IO.puts("#{inspect(name)}: mem=#{info[:memory]} msgq=#{info[:message_queue_len]} reds=#{info[:reductions]}")
end)

# === Inspect a specific process ===
pid = Process.whereis(MyApp.Worker)
Process.info(pid)  # all info
Process.info(pid, :message_queue_len)  # check for mailbox buildup
Process.info(pid, :current_stacktrace) # what it's doing right now
:sys.get_state(pid)                    # GenServer/gen_statem state (dev only!)
:sys.get_status(pid)                   # formatted status with state

# === ETS tables ===
:ets.i()  # list all ETS tables: name, type, size, memory, owner

# Inspect a specific table
:ets.info(:my_table)              # metadata
:ets.info(:my_table, :size)       # row count
:ets.info(:my_table, :memory)     # words (multiply by 8 for bytes on 64-bit)
:ets.tab2list(:my_table)          # dump all rows (careful with large tables)
:ets.first(:my_table)             # peek at first key

# === Scheduler utilization (sample over 1 second) ===
:scheduler.utilization(1000)
# Returns per-scheduler utilization — spot unbalanced load

# === Application supervision tree ===
# Walk the tree programmatically:
Supervisor.which_children(MyApp.Supervisor)
# => [{MyApp.Repo, #PID<0.234.0>, :worker, [MyApp.Repo]}, ...]
Supervisor.count_children(MyApp.Supervisor)
# => %{active: 5, specs: 5, supervisors: 1, workers: 4}

# === For production/headless: observer_cli ===
# Add {:observer_cli, "~> 1.7"} to deps
# Provides a TUI (terminal UI) — works over SSH
:observer_cli.start()
```

**Common diagnostic patterns:**

```elixir
# Detect message queue buildup (process can't keep up)
for pid <- Process.list(),
    {:message_queue_len, n} = Process.info(pid, :message_queue_len),
    n > 100,
    do: {pid, Process.info(pid, :registered_name), n}

# Detect binary memory leak (large binaries not GC'd)
# Force GC on all processes, then check binary memory before/after
before = :erlang.memory(:binary)
:erlang.garbage_collect()  # GC calling process
after_gc = :erlang.memory(:binary)
IO.puts("Binary: #{before} -> #{after_gc}")

# Check if a GenServer is a bottleneck (large message queue)
pid = Process.whereis(MyApp.CacheServer)
case Process.info(pid, :message_queue_len) do
  {:message_queue_len, n} when n > 50 ->
    IO.puts("WARNING: #{n} messages queued — consider ETS or pooling")
  {:message_queue_len, n} ->
    IO.puts("OK: #{n} messages queued")
end
```

### Logger

```elixir
require Logger
Logger.debug("Debug")
Logger.info("User created", user_id: user.id)
Logger.warning("Warning")
Logger.error("Error")

# Lazy evaluation
Logger.debug(fn -> "Expensive: #{inspect(expensive())}" end)
```

## Profiling & Benchmarking

### Quick Timing — :timer.tc

```elixir
# Measure a single function call (returns {microseconds, result})
{usec, result} = :timer.tc(fn -> expensive_work() end)
{usec, result} = :timer.tc(Module, :function, [arg1, arg2])
IO.puts("Took #{usec / 1000}ms")

# Helper for readable output (from Credo's ExecutionTiming)
defp format_time(usec) do
  cond do
    usec > 1_000_000 -> "#{div(usec, 1_000_000)}s"
    usec > 1_000 -> "#{div(usec, 1_000)}ms"
    true -> "#{usec}μs"
  end
end
```

### Monotonic Time — Precise Duration Measurement

```elixir
# System.monotonic_time — immune to clock adjustments, preferred for durations
start = System.monotonic_time()
result = do_work()
duration = System.monotonic_time() - start

# Convert to human-readable units
duration_ms = System.convert_time_unit(duration, :native, :millisecond)
duration_us = System.convert_time_unit(duration, :native, :microsecond)

# Direct unit specification
start = System.monotonic_time(:millisecond)
# ... work ...
elapsed_ms = System.monotonic_time(:millisecond) - start

# Telemetry span pattern (from Plug.Telemetry, Phoenix, Absinthe)
start_time = System.monotonic_time()
:telemetry.execute([:my_app, :operation, :start], %{system_time: System.system_time()}, metadata)
# ... work ...
duration = System.monotonic_time() - start_time
:telemetry.execute([:my_app, :operation, :stop], %{duration: duration}, metadata)
```

**monotonic_time vs system_time:** Use `monotonic_time` for measuring durations (never goes backward). Use `system_time` only for timestamps/wall clock (can jump on NTP sync).

### Mix Profile Tasks — Built-in Profilers

#### mix profile.fprof — Function Profiling (Most Detail)

```bash
# Profile a one-liner
mix profile.fprof -e "Enum.map(1..1000, &(&1 * 2))"

# Profile a script with callers info
mix profile.fprof my_script.exs --callers --sort own

# Options:
#   --callers    show who called each function
#   --details    per-process breakdown
#   --sort acc   sort by accumulated time (default)
#   --sort own   sort by own time (excludes called functions)
#   --no-warmup  skip warmup run
```

**Output columns:** CNT (call count), ACC (accumulated ms including callees), OWN (own time ms excluding callees)

**When to use:** Deep analysis of where time is spent. High overhead — development only.

#### mix profile.eprof — Time Profiling (Moderate Overhead)

```bash
# Profile with function matching filter
mix profile.eprof -e "MyApp.process(data)" --matching String
mix profile.eprof my_script.exs --matching MyApp.Parser --calls 5

# Options:
#   --matching Module          filter to specific module
#   --matching Module.fun/3    filter to specific function
#   --calls N                  minimum call count to display
#   --sort time                sort by time (default)
#   --sort calls               sort by call count
#   --set-on-spawn             trace spawned processes too
```

**Output columns:** CALLS, % TIME, µS/CALL

**When to use:** When fprof is too slow. Good for identifying hot functions. Moderate overhead.

#### mix profile.cprof — Call Count Profiling (Lowest Overhead)

```bash
# Count function calls
mix profile.cprof -e "Enum.reverse([1,2,3])"
mix profile.cprof my_script.exs --matching Enum --limit 10

# Options:
#   --matching Module    filter to module
#   --limit N            minimum call count to display
```

**Output columns:** CNT (call count) per function, grouped by module

**When to use:** Quick check of which functions are called most. Lowest overhead — closer to production-safe.

#### mix profile.tprof — Unified Profiler (OTP 27+)

```bash
# Time profiling (default)
mix profile.tprof -e "MyApp.process(data)"

# Memory profiling
mix profile.tprof -e "MyApp.process(data)" --type memory

# Call count profiling
mix profile.tprof -e "MyApp.process(data)" --type calls

# Combined
mix profile.tprof my_script.exs --type memory --type calls --matching MyApp
```

**When to use:** OTP 27+ replacement that unifies fprof/eprof/cprof. Preferred on newer BEAM versions.

#### Profiler Decision Table

| Profiler | Overhead | Output | Best for |
|---|---|---|---|
| `cprof` | Very low | Call counts | "What's called most?" |
| `eprof` | Moderate | Time per function | "Where is time spent?" |
| `fprof` | High | Full call graph + time | "Why is this slow?" (deep analysis) |
| `tprof` (OTP 27+) | Varies | Unified time/memory/calls | Modern replacement for all three |
| `:timer.tc` | None | Single measurement | Quick one-off timing |

### Programmatic Profiling in Code

```elixir
# === eprof from IEx/code (interactive profiling) ===
:eprof.start()
:eprof.profile(fn -> MyApp.slow_function() end)
:eprof.stop()
:eprof.analyze()

# With matching filter
:eprof.start()
{:ok, result} = :eprof.profile([], fn -> MyApp.process(data) end,
  {MyApp.Parser, :_, :_},  # Only trace MyApp.Parser functions
  set_on_spawn: true)
:eprof.stop()
:eprof.analyze(:total)

# === fprof from IEx/code ===
:fprof.apply(fn -> MyApp.slow_function() end, [])
:fprof.profile()
:fprof.analyse(totals: true, sort: :own)

# === cprof from IEx ===
:cprof.start()
MyApp.slow_function()
:cprof.pause()
:cprof.analyse()
:cprof.stop()
```

### Benchee — Full-Featured Benchmarking

```elixir
# Add {:benchee, "~> 1.0", only: :dev} to deps

# Basic comparison
Benchee.run(%{
  "Enum.map" => fn -> Enum.map(1..1000, & &1 * 2) end,
  "for comprehension" => fn -> for x <- 1..1000, do: x * 2 end,
  "Stream.map" => fn ->
    1..1000
    |> Stream.map(& &1 * 2)
    |> Enum.to_list()
  end
})

# With inputs, memory, and reduction tracking (from Torque benchmarks)
Benchee.run(
  %{
    "Torque" => fn input -> Torque.encode!(input) end,
    "Poison" => fn input -> Poison.encode!(input) end
  },
  warmup: 2,
  time: 15,
  memory_time: 2,
  reduction_time: 2,
  inputs: %{
    "small" => %{key: "value"},
    "medium" => Enum.map(1..100, &{:"key_#{&1}", &1}) |> Map.new(),
    "large" => File.read!("test/fixtures/large.json") |> Torque.decode!()
  },
  formatters: [
    {Benchee.Formatters.HTML, file: "bench/output/results.html"},
    Benchee.Formatters.Console
  ]
)

# With setup per run (different data each iteration)
Benchee.run(%{
  "random lookup" => {
    fn {map, key} -> Map.get(map, key) end,
    before_each: fn _ ->
      map = Map.new(1..10_000, &{&1, &1})
      {map, Enum.random(1..10_000)}
    end
  }
})
```

### Memory Profiling

#### VM Memory Breakdown

```elixir
# Overall memory (returns keyword list in bytes)
:erlang.memory()
# => [total: 48_372_736, processes: 15_234_048, processes_used: 14_987_520,
#     system: 33_138_688, atom: 1_048_577, atom_used: 1_023_456,
#     binary: 3_276_800, code: 12_345_678, ets: 2_097_152]

# Specific categories
:erlang.memory(:total)           # Total VM memory
:erlang.memory(:processes)       # All process heaps + stacks
:erlang.memory(:binary)          # Refc binary heap (watch for leaks!)
:erlang.memory(:ets)             # ETS table memory
:erlang.memory(:atom)            # Atom table (never shrinks)
:erlang.memory(:code)            # Loaded BEAM code

# IEx shorthand
runtime_info(:memory)  # Pretty-printed memory summary
```

#### Measure Memory of a Specific Operation

```elixir
# Pattern from Absinthe benchmarks — force GC for stable readings
defp measure_memory(fun) do
  :erlang.garbage_collect()
  before = :erlang.memory(:total)
  result = fun.()
  :erlang.garbage_collect()
  after_mem = :erlang.memory(:total)
  {after_mem - before, result}
end

{bytes, result} = measure_memory(fn -> build_large_structure() end)
IO.puts("Used #{div(bytes, 1024)} KB")
```

#### Per-Process Memory

```elixir
# Top 10 processes by memory
Process.list()
|> Enum.map(fn pid ->
  info = Process.info(pid, [:registered_name, :memory, :message_queue_len, :reductions])
  {pid, info}
end)
|> Enum.sort_by(fn {_, info} -> info[:memory] end, :desc)
|> Enum.take(10)
|> Enum.each(fn {pid, info} ->
  name = info[:registered_name] || inspect(pid)
  mem_kb = div(info[:memory], 1024)
  IO.puts("#{name}: #{mem_kb}KB mem, #{info[:message_queue_len]} msgs, #{info[:reductions]} reds")
end)

# Detailed process memory breakdown
pid = Process.whereis(MyApp.CacheServer)
Process.info(pid, :memory)             # Total memory (bytes)
Process.info(pid, :heap_size)          # Heap size (words)
Process.info(pid, :total_heap_size)    # Heap + old heap + stack (words)
Process.info(pid, :stack_size)         # Stack size (words)
# Words to bytes: multiply by :erlang.system_info(:wordsize) — 8 on 64-bit

# Binary memory per process (detect refc binary leaks)
Process.info(pid, :binary)  # List of {ref, size, ref_count} for refc binaries
```

#### ETS Memory

```elixir
:ets.i()  # List all ETS tables with name, type, size, memory, owner

# Specific table
:ets.info(:my_table, :size)    # Row count
:ets.info(:my_table, :memory)  # Memory in words (* 8 for bytes on 64-bit)
:ets.info(:my_table, :type)    # :set, :ordered_set, :bag, :duplicate_bag

# Find largest ETS tables
:ets.all()
|> Enum.map(fn tab ->
  {tab, :ets.info(tab, :memory) * :erlang.system_info(:wordsize)}
end)
|> Enum.sort_by(&elem(&1, 1), :desc)
|> Enum.take(5)
```

#### Detecting Binary Memory Leaks

```elixir
# Refc binaries > 64 bytes are reference-counted and shared
# Sub-binaries hold references to large parent binaries
# Common leak: keeping a small slice of a large binary alive

# Check binary memory before/after GC
before = :erlang.memory(:binary)
for pid <- Process.list(), do: :erlang.garbage_collect(pid)
Process.sleep(100)
after_gc = :erlang.memory(:binary)
IO.puts("Binary: #{div(before, 1024)}KB -> #{div(after_gc, 1024)}KB")

# Fix: use :binary.copy to detach sub-binary from parent
# BAD: keeps entire large_binary alive
<<header::binary-size(100), _rest::binary>> = large_binary
keep_reference_to(header)  # Holds ref to all of large_binary!

# GOOD: copy the slice to release parent
header = :binary.copy(<<header::binary-size(100), _rest::binary>> = large_binary)
keep_reference_to(header)  # Only 100 bytes retained
```

### VM & Scheduler Profiling

```elixir
# === Scheduler utilization (sample over 1 second) ===
:scheduler.utilization(1000)
# Returns per-scheduler utilization percentage
# High (>90%) sustained = scheduler bottleneck

# Manual scheduler wall time measurement
:erlang.system_flag(:scheduler_wall_time, true)
sample1 = :erlang.statistics(:scheduler_wall_time)
Process.sleep(1000)
sample2 = :erlang.statistics(:scheduler_wall_time)
:erlang.system_flag(:scheduler_wall_time, false)

# Calculate utilization per scheduler
Enum.zip(sample1, sample2)
|> Enum.map(fn {{id, active1, total1}, {id, active2, total2}} ->
  {id, (active2 - active1) / (total2 - total1) * 100}
end)
# => [{1, 45.2}, {2, 67.8}, ...] — percentage active per scheduler

# === Run queue (scheduler backlog) ===
:erlang.statistics(:run_queue)  # 0 = healthy, sustained >0 = overloaded

# === Reduction counting (relative CPU work) ===
{reds_total, reds_since_last} = :erlang.statistics(:reductions)

# === GC statistics ===
{gc_count, words_reclaimed, _} = :erlang.statistics(:garbage_collection)

# === I/O statistics ===
{{:input, bytes_in}, {:output, bytes_out}} = :erlang.statistics(:io)

# === System limits — how close to exhaustion ===
# IEx: runtime_info(:limits)
:erlang.system_info(:process_count)  # current
:erlang.system_info(:process_limit)  # max (default 262144)
:erlang.system_info(:atom_count)     # current
:erlang.system_info(:atom_limit)     # max (atoms are never GC'd!)
:erlang.system_info(:port_count)     # current (files, sockets)
:erlang.system_info(:port_limit)     # max
:erlang.system_info(:ets_count)      # current ETS tables
:erlang.system_info(:ets_limit)      # max
```

### Allocator Profiling (Advanced)

```elixir
# IEx shorthand
runtime_info(:allocators)

# Programmatic: get all allocator sizes
allocators = :erlang.system_info(:alloc_util_allocators)
for {alloc, instances} <- :erlang.system_info({:allocator_sizes, allocators}),
    {:instance, _, info} <- instances,
    reduce: %{} do
  acc ->
    # Extract block_size, carrier_size from info
    Map.update(acc, alloc, 0, & &1 + extract_size(info))
end

# Key allocators to watch:
# :binary_alloc  — binary heap (refc binaries)
# :eheap_alloc   — Erlang process heaps
# :ets_alloc     — ETS table storage
# :ll_alloc      — long-lived allocations
# :temp_alloc    — temporary allocations (should be near 0 at rest)
```

### :sys Module — GenServer/OTP Process Tracing

```elixir
pid = Process.whereis(MyApp.Worker)

# Inspect state (development only — may expose sensitive data)
:sys.get_state(pid)              # Raw state
:sys.get_status(pid)             # Formatted status with state

# Replace state (live patching — development only)
:sys.replace_state(pid, fn state ->
  %{state | debug: true}
end)

# Trace message handling (shows all messages in/out)
:sys.trace(pid, true)
# Output: *DBG* <0.234.0> got call {get, :key} from <0.123.0>
# Output: *DBG* <0.234.0> sent {:ok, "value"} to <0.123.0>
:sys.trace(pid, false)  # Stop tracing

# Statistics (counts calls, messages, time)
:sys.statistics(pid, true)
# ... use the process ...
:sys.statistics(pid, :get)
# => {:ok, [{:start_time, ...}, {:current_time, ...},
#           {:reductions, 1234}, {:messages_in, 56}, {:messages_out, 42}]}
:sys.statistics(pid, false)

# Log last N events
:sys.log(pid, 20)      # Start logging last 20 events
:sys.log(pid, :get)     # Retrieve logged events
:sys.log(pid, false)    # Stop logging
```

### Telemetry-Based Profiling

```elixir
# Attach profiling handler to existing telemetry events
:telemetry.attach_many("profiler", [
  [:my_app, :repo, :query],
  [:phoenix, :endpoint, :stop],
  [:phoenix, :router_dispatch, :stop]
], fn event, measurements, metadata, _config ->
  duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
  if duration_ms > 100 do
    Logger.warning("Slow #{inspect(event)}: #{duration_ms}ms",
      source: metadata[:source],
      query: metadata[:query]
    )
  end
end, nil)

# Telemetry span — instrument your own code
:telemetry.span([:my_app, :process], %{input_size: byte_size(data)}, fn ->
  result = do_processing(data)
  {result, %{output_size: byte_size(result)}}
end)

# Phoenix VM metrics (from generated telemetry.ex)
defmodule MyAppWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def metrics do
    [
      # VM metrics (built-in pollers)
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Ecto metrics
      summary("my_app.repo.query.total_time", unit: {:native, :millisecond}),
      summary("my_app.repo.query.queue_time", unit: {:native, :millisecond}),

      # Phoenix metrics
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration", unit: {:native, :millisecond})
    ]
  end
end
```

### Profiling Decision Guide

| Question | Tool |
|---|---|
| "How long does this one function take?" | `:timer.tc` or `System.monotonic_time` |
| "Which functions are called most?" | `mix profile.cprof` |
| "Where is time spent?" | `mix profile.eprof` |
| "Why is this slow? (full call graph)" | `mix profile.fprof` |
| "Is implementation A faster than B?" | Benchee |
| "How much memory does this use?" | `:erlang.memory` + GC pattern |
| "Which process uses most memory?" | `Process.list` + `Process.info` sort |
| "Is my GenServer a bottleneck?" | `Process.info(pid, :message_queue_len)` + `:sys.statistics` |
| "Are schedulers overloaded?" | `:erlang.statistics(:run_queue)` + `:scheduler.utilization` |
| "Where are slow DB queries?" | Telemetry handler on `[:my_app, :repo, :query]` |
| "Is there a binary memory leak?" | `:erlang.memory(:binary)` before/after GC |
| "What's my GenServer doing right now?" | `:sys.trace(pid, true)` or `Process.info(pid, :current_stacktrace)` |
| "Production monitoring?" | Telemetry + LiveDashboard or observer_cli |

## Related Files

- **[SKILL.md](SKILL.md)** — Debugging essentials (IO.inspect, dbg, IEx.pry), profiling quick reference, quality tools
- **[otp-reference.md](otp-reference.md)** — Process info keys, :sys module, debugging quick reference (lighter overlap)
- **[otp-advanced.md](otp-advanced.md)** — Production debugging patterns: finding problem processes, safe tracing, binary leak detection, ETS analysis
- **[production.md](production.md)** — Telemetry deep-dive, production monitoring patterns
- **[testing-reference.md](testing-reference.md)** — Debugging failing tests, async failure diagnosis
