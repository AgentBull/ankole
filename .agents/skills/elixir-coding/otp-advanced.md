# Advanced OTP Topics

Deep-dive into GenStage, Flow, Broadway, hot code upgrades, and production patterns.

## Rules for Advanced OTP Patterns (LLM)

1. **PREFER `Task.async_stream` over GenStage** for simple parallel map operations — GenStage adds complexity only justified by backpressure needs.
2. **ALWAYS set explicit `max_demand` and `min_demand`** on GenStage consumers — defaults cause bursty demand patterns.
3. **PREFER Broadway over raw GenStage** for queue-based data processing (SQS, RabbitMQ, Kafka) — Broadway handles batching, fault tolerance, and graceful shutdown.
4. **NEVER use hot code upgrades for stateless services** — use rolling restarts instead. Hot upgrades are only worth the complexity when preserving in-memory state matters.
5. **ALWAYS test `code_change/3` state migrations** before deploying hot upgrades — untested migrations corrupt running state.
6. **ALWAYS use `:recon_trace` with explicit limits** for production tracing — never `:dbg` or raw `:erlang.trace` (no safety limits, can crash nodes).

## Common Mistakes (BAD/GOOD)

**Using GenStage for simple parallelism:**
```elixir
# BAD: GenStage pipeline for a one-shot parallel map
defmodule Transform do
  use GenStage
  # ... 50+ lines of producer/consumer boilerplate for a simple parallel map
end
```

```elixir
# GOOD: Task.async_stream for simple parallel work
results =
  items
  |> Task.async_stream(&process/1, max_concurrency: 10, timeout: 30_000)
  |> Enum.map(fn {:ok, result} -> result end)
```

**Untuned Broadway concurrency:**
```elixir
# BAD: Default concurrency — no thought given to resource limits
processors: [default: []],
batchers: [default: [batch_size: 10]]
```

```elixir
# GOOD: Tuned to match downstream capacity
processors: [default: [concurrency: 10, max_demand: 10]],
batchers: [default: [batch_size: 100, batch_timeout: 1_000, concurrency: 5]]
```

**Unsafe production tracing:**
```elixir
# BAD: No limits — can generate millions of trace messages and crash the node
:dbg.tracer()
:dbg.p(:all, :c)
:dbg.tp(MyModule, :my_function, :x)
```

```elixir
# GOOD: recon_trace with automatic limit (stops after 100 traces)
:recon_trace.calls({MyModule, :my_function, :return_trace}, 100)
# Always clean up
:recon_trace.clear()
```

## GenStage (Backpressure)

GenStage is a specification for exchanging events between producers and consumers with built-in backpressure. Consumers request demand from producers, preventing overload.

### When to Use GenStage

| Scenario | Use GenStage? | Alternative |
|----------|--------------|-------------|
| Process data from external queue | Yes (via Broadway) | Broadway wraps GenStage |
| Fan-out processing pipeline | Yes | Task.async_stream for simple cases |
| Rate-limited API calls | Yes | Simple GenServer + Process.send_after |
| Real-time event processing | Yes | Phoenix.PubSub for broadcast |
| Batch database inserts | Yes (batching) | Ecto.Multi for transactions |
| Simple parallel map | No | Task.async_stream |

### Producer

```elixir
defmodule MyApp.EventProducer do
  use GenStage

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Push events into the producer (for push-based sources)"
  def push_events(events) do
    GenStage.cast(__MODULE__, {:push, events})
  end

  @impl true
  def init(_opts) do
    {:producer, %{queue: :queue.new(), demand: 0}}
  end

  @impl true
  def handle_demand(incoming_demand, state) do
    {events, new_state} = take_events(state.demand + incoming_demand, state)
    {:noreply, events, new_state}
  end

  @impl true
  def handle_cast({:push, events}, state) do
    queue = Enum.reduce(events, state.queue, &:queue.in(&1, &2))
    {to_send, new_state} = take_events(state.demand, %{state | queue: queue})
    {:noreply, to_send, new_state}
  end

  defp take_events(demand, state) do
    {events, queue} = dequeue(demand, state.queue, [])
    remaining_demand = demand - length(events)
    {events, %{state | queue: queue, demand: remaining_demand}}
  end

  defp dequeue(0, queue, acc), do: {Enum.reverse(acc), queue}
  defp dequeue(n, queue, acc) do
    case :queue.out(queue) do
      {{:value, item}, queue} -> dequeue(n - 1, queue, [item | acc])
      {:empty, queue} -> {Enum.reverse(acc), queue}
    end
  end
end
```

### Producer-Consumer (Transform)

```elixir
defmodule MyApp.EventTransformer do
  use GenStage

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    subscribe_to = Keyword.get(opts, :subscribe_to, [])
    {:producer_consumer, %{}, subscribe_to: subscribe_to}
  end

  @impl true
  def handle_events(events, _from, state) do
    transformed =
      events
      |> Enum.map(&transform/1)
      |> Enum.reject(&is_nil/1)

    {:noreply, transformed, state}
  end

  defp transform(event) do
    # Your transformation logic
    case event do
      %{type: :valid} -> Map.put(event, :processed_at, DateTime.utc_now())
      _ -> nil  # Filter invalid events
    end
  end
end
```

### Consumer

```elixir
defmodule MyApp.EventConsumer do
  use GenStage

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    subscribe_to = Keyword.get(opts, :subscribe_to, [])

    {:consumer, %{},
     subscribe_to:
       Enum.map(subscribe_to, fn source ->
         {source, max_demand: 100, min_demand: 50}
       end)}
  end

  @impl true
  def handle_events(events, _from, state) do
    # Process batch — GenStage guarantees max_demand events per batch
    Enum.each(events, &process_event/1)
    {:noreply, [], state}
  end

  defp process_event(event) do
    # Your processing logic
    IO.inspect(event, label: "processed")
  end
end
```

### Wiring a Pipeline

```elixir
# In your supervision tree:
children = [
  MyApp.EventProducer,
  {MyApp.EventTransformer,
   subscribe_to: [{MyApp.EventProducer, max_demand: 200}]},
  {MyApp.EventConsumer,
   subscribe_to: [MyApp.EventTransformer]}
]
```

## Flow (Parallel Processing)

Flow builds on GenStage to provide parallel data processing with MapReduce-like operations.

### When to Use Flow vs Enum vs Stream

| Data size | Operation | Use |
|-----------|-----------|-----|
| Fits in memory | Simple transform | `Enum.map/filter/reduce` |
| Large file/stream | Sequential processing | `Stream.map/filter` |
| Large dataset | CPU-bound parallel work | `Flow` |
| Infinite stream | Windowed aggregation | `Flow` with windows |
| External queue | Reliable processing | `Broadway` |

### Basic Flow

```elixir
# Parallel word count from a large file
File.stream!("large_file.txt")
|> Flow.from_enumerable()
|> Flow.flat_map(&String.split(&1))
|> Flow.partition()
|> Flow.reduce(fn -> %{} end, fn word, acc ->
  Map.update(acc, word, 1, &(&1 + 1))
end)
|> Enum.to_list()
```

### Flow with Windows

```elixir
# Count events in 5-second windows
Flow.from_enumerable(event_stream)
|> Flow.partition(
  window: Flow.Window.periodic(5, :second),
  stages: System.schedulers_online()
)
|> Flow.reduce(fn -> %{} end, fn event, acc ->
  Map.update(acc, event.type, 1, &(&1 + 1))
end)
|> Flow.on_trigger(fn counts ->
  # Emit window results
  IO.inspect(counts, label: "window")
  {[counts], %{}}  # {emit, new_acc}
end)
|> Enum.to_list()
```

### Flow from Multiple Sources

```elixir
# Merge multiple producers
flow1 = Flow.from_enumerable(source_a)
flow2 = Flow.from_enumerable(source_b)

Flow.merge([flow1, flow2])
|> Flow.partition(key: {:key, :user_id})
|> Flow.reduce(fn -> %{} end, &aggregate/2)
|> Enum.to_list()
```

## Broadway (Data Pipelines)

Broadway provides a high-level abstraction for building data processing pipelines with built-in features: batching, fault tolerance, graceful shutdown, and back-pressure.

### When to Use Broadway

| Source | Use Broadway? | Notes |
|--------|--------------|-------|
| SQS/RabbitMQ/Kafka | Yes | First-class producer support |
| Database polling | Yes | Use `BroadwayEcto` or custom producer |
| HTTP webhooks | Maybe | GenServer + Broadway if high volume |
| File processing | No | Use Flow or Task.async_stream |
| Simple job queue | No | Use Oban instead |

### SQS Pipeline

```elixir
defmodule MyApp.SQSPipeline do
  use Broadway

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {
          BroadwaySQS.Producer,
          queue_url: System.fetch_env!("SQS_QUEUE_URL"),
          config: [
            region: "eu-west-1",
            access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
            secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")
          ]
        },
        concurrency: 2  # Number of SQS pollers
      ],
      processors: [
        default: [
          concurrency: 10,   # Parallel message processors
          max_demand: 10      # Messages per processor
        ]
      ],
      batchers: [
        default: [
          batch_size: 100,    # Batch this many before handle_batch
          batch_timeout: 1_000,  # Or flush after 1 second
          concurrency: 5      # Parallel batch processors
        ],
        s3: [
          batch_size: 50,
          batch_timeout: 5_000
        ]
      ]
    )
  end

  @impl true
  def handle_message(_processor, message, _context) do
    data =
      message.data
      |> Torque.decode!()
      |> process_record()

    message
    |> Broadway.Message.update_data(fn _ -> data end)
    |> Broadway.Message.put_batcher(choose_batcher(data))
  end

  @impl true
  def handle_batch(:default, messages, _batch_info, _context) do
    # Batch insert into database
    records = Enum.map(messages, & &1.data)

    MyApp.Repo.insert_all(MyApp.Event, records,
      on_conflict: :nothing,
      conflict_target: [:id]
    )

    messages
  end

  def handle_batch(:s3, messages, batch_info, _context) do
    # Write batch to S3
    data = Enum.map(messages, &Torque.encode!(&1.data))
    key = "events/#{batch_info.batch_key}/#{System.system_time(:second)}.jsonl"

    ExAws.S3.put_object("my-bucket", key, Enum.join(data, "\n"))
    |> ExAws.request!()

    messages
  end

  @impl true
  def handle_failed(messages, _context) do
    # Called for messages that raised in handle_message
    Enum.each(messages, fn message ->
      Logger.error("Failed to process message",
        data: inspect(message.data),
        error: inspect(message.status)
      )
    end)

    messages
  end

  defp process_record(record) do
    # Transform/validate
    %{
      id: record["id"],
      type: record["type"],
      payload: record["payload"],
      processed_at: DateTime.utc_now()
    }
  end

  defp choose_batcher(%{type: "archive"}), do: :s3
  defp choose_batcher(_), do: :default
end
```

### Custom Broadway Producer

```elixir
defmodule MyApp.DatabaseProducer do
  @moduledoc "Poll database for unprocessed records."
  use GenStage

  @poll_interval_ms 1_000

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    schedule_poll()
    {:producer, %{table: table, demand: 0, queue: :queue.new()}}
  end

  @impl true
  def handle_demand(incoming_demand, state) do
    {events, new_state} = fetch_events(%{state | demand: state.demand + incoming_demand})
    {:noreply, events, new_state}
  end

  @impl true
  def handle_info(:poll, state) do
    # Fetch from database
    records =
      MyApp.Repo.all(
        from r in state.table,
          where: r.status == "pending",
          order_by: [asc: r.inserted_at],
          limit: 100
      )

    # Convert to Broadway messages
    messages =
      Enum.map(records, fn record ->
        %Broadway.Message{
          data: record,
          acknowledger: {__MODULE__, :ack_id, record.id}
        }
      end)

    queue = Enum.reduce(messages, state.queue, &:queue.in(&1, &2))
    {events, new_state} = fetch_events(%{state | queue: queue})

    schedule_poll()
    {:noreply, events, new_state}
  end

  defp fetch_events(state) do
    {events, queue} = dequeue(state.demand, state.queue, [])
    remaining = state.demand - length(events)
    {events, %{state | queue: queue, demand: remaining}}
  end

  defp dequeue(0, queue, acc), do: {Enum.reverse(acc), queue}
  defp dequeue(n, queue, acc) do
    case :queue.out(queue) do
      {{:value, item}, queue} -> dequeue(n - 1, queue, [item | acc])
      {:empty, queue} -> {Enum.reverse(acc), queue}
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
```

## Hot Code Upgrades — Deep Dive

### Code Loading Fundamentals

The BEAM maintains up to two versions of each module: **current** and **old**.

```elixir
# Key rules:
# 1. Fully qualified calls (Module.func()) ALWAYS use CURRENT version
# 2. Local calls (func()) use the version loaded when process started
# 3. Loading new code: new -> current, current -> old
# 4. Processes in old code must transition before purge

# BAD: Process stuck in old code forever
defmodule Counter do
  def loop(count) do
    receive do
      :inc -> loop(count + 1)  # Local call — stays in OLD version!
    end
  end
end

# GOOD: Fully qualified call picks up new code
defmodule Counter do
  def loop(count) do
    receive do
      :inc -> __MODULE__.loop(count + 1)  # Always uses CURRENT version
    end
  end
end
```

### Code Purging

```elixir
# Safe purge — fails if processes still in old code
case :code.soft_purge(MyModule) do
  true -> :ok
  false -> :processes_in_old_code
end

# DANGEROUS: Kills processes running old code
:code.purge(MyModule)

# Find all processes in old code
for pid <- Process.list(),
    :erlang.check_process_code(pid, MyModule),
    do: pid
```

### Appup Files

Describe how to upgrade/downgrade between versions:

```erlang
%% rel/appups/my_app/1.1.0.appup
{"1.1.0",
 [{"1.0.0",                           %% Upgrade from 1.0.0
   [{load_module, my_app_handler},     %% Simple reload
    {update, my_app_worker,            %% State change
     {advanced, []},                   %% Calls code_change/3
     [my_app_handler]},                %% Dependencies
    {add_module, my_app_new_mod}]}],   %% New module
 [{"1.0.0",                           %% Downgrade to 1.0.0
   [{delete_module, my_app_new_mod},
    {update, my_app_worker, {advanced, []}, []},
    {load_module, my_app_handler}]}]}.
```

### When NOT to Use Hot Code Upgrades

Prefer rolling restarts when:

| Scenario | Why avoid hot upgrade |
|----------|----------------------|
| Stateless services | Just restart — no state to preserve |
| Database schema changes | Need migration coordination |
| Major refactoring | Complex state migrations are error-prone |
| Supervision tree changes | Risky without careful planning |
| First deployment | Always full deploy first |
| No test infrastructure | Hot upgrades need thorough testing |

### Testing Hot Upgrades

```elixir
defmodule MyApp.UpgradeTest do
  use ExUnit.Case

  test "state migration from v1 to v2" do
    v1_state = %{count: 42}
    {:ok, v2_state} = MyServer.code_change("1.0.0", v1_state, [])
    assert v2_state == %{count: 42, history: []}
  end

  test "upgrade preserves running state" do
    {:ok, pid} = MyServer.start_link(count: 10)

    # Simulate the upgrade sequence
    :sys.suspend(pid)
    :sys.change_code(pid, MyServer, "1.0.0", [])
    :sys.resume(pid)

    assert MyServer.get_count(pid) == 10
    assert MyServer.get_history(pid) == []
  end
end
```

### Release Building

```elixir
# mix.exs
def project do
  [
    app: :my_app,
    version: "1.1.0",
    releases: [
      my_app: [
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  ]
end
```

```bash
# Build and deploy
MIX_ENV=prod mix release
bin/my_app upgrade "1.1.0"

# Or manually via remote shell:
bin/my_app remote
iex> :release_handler.unpack_release(~c"my_app-1.1.0")
iex> :release_handler.install_release(~c"1.1.0")
iex> :release_handler.make_permanent(~c"1.1.0")
```

## Production Debugging Patterns

### Finding Problem Processes

```elixir
# In a remote IEx session (bin/my_app remote)

# Top processes by memory
Process.list()
|> Enum.map(fn pid ->
  info = Process.info(pid, [:memory, :message_queue_len, :registered_name, :current_function])
  {pid, info}
end)
|> Enum.sort_by(fn {_, info} -> info[:memory] end, :desc)
|> Enum.take(10)

# Or with :recon (add {:recon, "~> 2.5"} to deps)
:recon.proc_count(:memory, 10)
:recon.proc_count(:message_queue_len, 10)

# Processes with large mailboxes (potential bottleneck)
for pid <- Process.list(),
    {:message_queue_len, len} = Process.info(pid, :message_queue_len),
    len > 100 do
  {pid, len, Process.info(pid, :registered_name)}
end
```

### Safe Tracing in Production

```elixir
# NEVER use :dbg or :erlang.trace directly in production
# Use :recon_trace with automatic limits

# Trace 100 calls to MyModule.my_function
:recon_trace.calls({MyModule, :my_function, :_}, 100)

# Trace with return values
:recon_trace.calls({MyModule, :my_function, :return_trace}, 100)

# Trace specific patterns
:recon_trace.calls(
  {MyModule, :my_function, fn [arg1 | _] -> arg1 == :special end},
  100,
  [{:scope, :local}]  # Include private functions
)

# Stop tracing
:recon_trace.clear()
```

### Binary Leak Detection

```elixir
# Large binaries (>64 bytes) are reference-counted and shared
# If a process holds a reference, the entire binary stays in memory

# Find top binary leak suspects
:recon.bin_leak(10)

# Force GC on suspect processes
for {pid, _, _} <- :recon.bin_leak(5) do
  :erlang.garbage_collect(pid)
end

# Check total binary memory
:erlang.memory(:binary)
```

### ETS Table Analysis

```elixir
# List all ETS tables with size and memory
for table <- :ets.all() do
  info = :ets.info(table)
  word_size = :erlang.system_info(:wordsize)
  %{
    name: info[:name],
    type: info[:type],
    size: info[:size],
    memory_bytes: info[:memory] * word_size,
    owner: info[:owner]
  }
end
|> Enum.sort_by(& &1.memory_bytes, :desc)
|> Enum.take(10)
```

## Subscriber Resubscription Pattern

Auto-reconnect to producers after transient failures:

```elixir
defmodule MyApp.Subscriber do
  use GenStage

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    producers = Keyword.fetch!(opts, :producers)
    resubscribe_delay = Keyword.get(opts, :resubscribe_delay, 1000)

    state = %{
      producers: producers,
      resubscribe_delay: resubscribe_delay,
      subscriptions: %{}
    }

    # Subscribe to all producers
    {:consumer, state, subscribe_to: producers}
  end

  @impl true
  def handle_subscribe(:producer, _opts, {pid, _ref} = from, state) do
    subscriptions = Map.put(state.subscriptions, pid, from)
    {:automatic, %{state | subscriptions: subscriptions}}
  end

  @impl true
  def handle_cancel({:down, _reason}, {pid, _ref}, state) do
    # Producer crashed - schedule resubscription
    Process.send_after(self(), {:resubscribe, pid}, state.resubscribe_delay)
    subscriptions = Map.delete(state.subscriptions, pid)
    {:noreply, [], %{state | subscriptions: subscriptions}}
  end

  def handle_cancel(_reason, {pid, _ref}, state) do
    # Normal cancellation - don't resubscribe
    subscriptions = Map.delete(state.subscriptions, pid)
    {:noreply, [], %{state | subscriptions: subscriptions}}
  end

  @impl true
  def handle_info({:resubscribe, producer}, state) do
    case GenStage.sync_subscribe(self(), to: producer) do
      {:ok, _ref} ->
        {:noreply, [], state}
      {:error, _reason} ->
        # Retry with backoff
        Process.send_after(self(), {:resubscribe, producer}, state.resubscribe_delay * 2)
        {:noreply, [], state}
    end
  end

  @impl true
  def handle_events(events, _from, state) do
    Enum.each(events, &process_event/1)
    {:noreply, [], state}
  end

  defp process_event(event), do: IO.inspect(event, label: "Event")
end
```

## Coordinated Shutdown (Terminator Pattern)

Three-phase shutdown to prevent message loss:

```elixir
defmodule Terminator do
  use GenServer

  def handle_info(:terminate, state) do
    # Phase 1: Signal consumers to stop accepting new work
    for name <- state.consumers do
      if pid = GenServer.whereis(name), do: send(pid, :will_terminate)
    end

    # Phase 2: Drain producer buffers
    for name <- state.producers do
      if pid = GenServer.whereis(name), do: Producer.drain(pid)
    end

    # Phase 3: Wait for completion with monitoring
    refs = Enum.map(state.producers, &Process.monitor(GenServer.whereis(&1)))
    await_completion(refs)

    {:stop, :normal, state}
  end
end
```

## CallerAcknowledger for Testing Async Flows

Test acknowledgment-based systems by sending messages back to test process:

```elixir
defmodule CallerAcknowledger do
  @behaviour MyApp.Acknowledger

  def init({pid, ref}, _data) when is_pid(pid) do
    {__MODULE__, {pid, ref}, nil}
  end

  @impl true
  def ack({pid, ref}, successful, failed) do
    send(pid, {:ack, ref, successful, failed})
  end
end

# In test
test "processes and acknowledges messages" do
  ref = make_ref()
  ack = CallerAcknowledger.init({self(), ref}, nil)

  MyApp.Pipeline.push_message(%Message{data: "test", acknowledger: ack})

  assert_receive {:ack, ^ref, [%{data: "test"}], []}, 5000
end
```

## Message with Acknowledger Pattern (from Broadway)

Decouple message processing from acknowledgment strategy:

```elixir
defmodule MyApp.Message do
  @enforce_keys [:data, :acknowledger]
  defstruct [
    :data,
    :metadata,
    :acknowledger,  # {module, ack_ref, ack_data}
    status: :ok,
    batcher: :default
  ]

  @type acknowledger :: {module, ack_ref :: term, ack_data :: term}

  def ack_immediately(%__MODULE__{} = message) do
    {module, ack_ref, ack_data} = message.acknowledger
    module.ack(ack_ref, [message], [])
    %{message | acknowledger: MyApp.NoopAcknowledger.init()}
  end

  def failed(%__MODULE__{} = message, reason) do
    %{message | status: {:failed, reason}}
  end
end

defmodule MyApp.Acknowledger do
  @callback ack(ack_ref :: term, successful :: [Message.t()], failed :: [Message.t()]) :: :ok
  @callback configure(ack_ref :: term, ack_data :: term, opts :: keyword) :: {:ok, ack_data}
  @optional_callbacks configure: 3
end

defmodule MyApp.NoopAcknowledger do
  @behaviour MyApp.Acknowledger

  def init, do: {__MODULE__, nil, nil}

  @impl true
  def ack(_ref, _successful, _failed), do: :ok
end

defmodule MyApp.SQSAcknowledger do
  @behaviour MyApp.Acknowledger

  def init(queue_url, receipt_handle) do
    {__MODULE__, queue_url, receipt_handle}
  end

  @impl true
  def ack(queue_url, successful, _failed) do
    entries = Enum.map(successful, fn msg ->
      {_, _, receipt_handle} = msg.acknowledger
      %{id: msg.metadata.id, receipt_handle: receipt_handle}
    end)

    ExAws.SQS.delete_message_batch(queue_url, entries)
    |> ExAws.request()

    :ok
  end
end
```

## Batch Info with Trigger Metadata

Include why a batch was triggered for context-aware handling:

```elixir
defmodule MyApp.BatchInfo do
  @type t :: %__MODULE__{
    batcher: atom,
    batch_key: term,
    partition: non_neg_integer | nil,
    size: pos_integer,
    trigger: :size | :timeout | :flush
  }

  defstruct [:batcher, :batch_key, :partition, :size, :trigger]
end

defmodule MyApp.BatchHandler do
  def handle_batch(batcher, messages, batch_info, state) do
    case batch_info.trigger do
      :timeout ->
        # Partial batch due to timeout - might want different handling
        Logger.info("Processing partial batch of #{batch_info.size} (timeout)")
        process_messages(messages, async: false)

      :size ->
        # Full batch - can process more aggressively
        Logger.info("Processing full batch of #{batch_info.size}")
        process_messages(messages, async: true)

      :flush ->
        # Urgent flush - process immediately
        Logger.info("Flush-triggered batch of #{batch_info.size}")
        process_messages(messages, async: false, priority: :high)
    end

    {:ok, messages, state}
  end
end
```

## Related Files

- **[SKILL.md](SKILL.md)** — OTP rules, GenServer/gen_statem key patterns, supervisor strategies, decision frameworks
- **[otp-reference.md](otp-reference.md)** — Callback signatures, ETS cheatsheet, match specs, process info, release commands
- **[otp-examples.md](otp-examples.md)** — Complete implementations: rate limiter, connection state machine, worker pool, circuit breaker, cache, telemetry
- **[production.md](production.md)** — Production deployment patterns, telemetry deep-dive, periodic work, graceful shutdown
