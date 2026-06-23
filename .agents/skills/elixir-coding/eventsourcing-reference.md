# Event Sourcing & CQRS Quick Reference

Quick-lookup tables for Commanded library, event store configuration, router DSL, middleware, projections, process managers, serialization, and mix tasks. Patterns sourced from Commanded library test suite and documentation.

## Rules for Writing Event-Sourced Elixir (LLM)

1. **ALWAYS name events in past tense** — events record what happened (`AccountOpened`, `FundsDeposited`), never imperative (`OpenAccount` is a command, not an event).
2. **NEVER mutate or modify stored events** — events are immutable facts. Schema changes require new event types (V2, V3) with upcasters for backward compatibility.
3. **ALWAYS include all data needed by projections on the event** — projectors must never look up external data. Events are the single source of truth.
4. **NEVER perform side effects in aggregates or process managers** — no HTTP calls, no database reads, no external API calls. Side effects belong in event handlers (gateways/notifiers).
5. **ALWAYS test aggregates as pure functions** — test `execute/2` input/output (command → event or error), not internal state. Never assert `state.balance == 100` directly.
6. **NEVER let process managers read from projections** — process manager state must be derived entirely from events via `apply/2`.
7. **ALWAYS manage one flow per process manager instance** — each instance handles a single business process.
8. **ALWAYS return unchanged state from failure event apply/2** — failure events record that something failed but must not change aggregate state.
9. **ALWAYS design projections for specific query patterns** — create multiple projections from the same events for different read needs.
10. **NEVER share projection tables between projectors** — each projector owns its projections exclusively.

## When to Use Event Sourcing

**Use when:**
- Complex domains with long-lived processes (insurance claims, order fulfillment, loan origination)
- Perfect audit trails are a business requirement (finance, healthcare, compliance)
- Undo/redo/replay capabilities needed
- Event-driven microservice integration
- Collaborative multi-user systems with concurrent state changes

**Do NOT use when:**
- Simple CRUD applications (blogs, to-do lists)
- Static reference/lookup data
- Read-heavy analytical systems (OLAP)
- Strong consistency reads required with zero latency
- Small teams without event sourcing experience

**Hybrid approach:** Use event sourcing only for critical bounded contexts (financial transactions, order processing) while keeping simple domains as traditional CRUD with Ecto.

## Core Architecture

```
Client → Command → Router → Aggregate → Event Store (append-only)
                                              ↓
                              ┌────────────────┼────────────────┐
                              ↓                ↓                ↓
                        Process Manager   Projector        Event Handler
                        (emits commands)  (read model)     (side effects)
```

**Aggregate**: Receives commands, validates business rules, emits events. Pure functions — no side effects.
**Projector**: Subscribes to events, builds read-optimized projections (Ecto, ETS, Redis).
**Process Manager (Saga)**: Orchestrates multi-aggregate workflows. Has lifecycle: start → continue → stop.
**Event Handler**: Performs side effects (email, webhooks, external APIs). Only gateway for external work.

### Common Mistakes (BAD/GOOD)

```elixir
# BAD: Imperative event naming
%PlaceOrder{order_id: "123"}         # This is a command name
# GOOD: Past tense
%OrderPlaced{order_id: "123"}

# BAD: Side effects in aggregate
def execute(%__MODULE__{}, %WithdrawFunds{} = cmd) do
  HTTPClient.notify_bank(cmd)  # NEVER in aggregate
  %FundsWithdrawn{...}
end
# GOOD: Event handler does side effects
defmodule BankNotifier do
  use Commanded.Event.Handler, application: MyApp.CommandedApp, name: __MODULE__
  def handle(%FundsWithdrawn{} = event, _metadata), do: HTTPClient.notify(event)
end

# BAD: Missing data on events
%FundsWithdrawn{account_id: "123", amount: 50}
# GOOD: All derived data included
%FundsWithdrawn{account_id: "123", amount: 50, new_balance: 150}

# BAD: Testing internal state
state = Account.apply(%Account{}, %FundsDeposited{amount: 100})
assert state.balance == 100
# GOOD: Test execute/2 output
state = %Account{balance: 100, status: :open}
assert %FundsWithdrawn{new_balance: 70} = Account.execute(state, %WithdrawFunds{amount: 30})
```

## Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:commanded, "~> 1.4"},
    {:commanded_eventstore_adapter, "~> 1.4"},  # PostgreSQL event store
    {:torque, "~> 0.2.3"},
    # Optional
    {:commanded_ecto_projections, "~> 1.4"},     # Ecto-based projections
    {:commanded_uniqueness_middleware, "~> 1.0"}  # Unique constraint validation
  ]
end
```

## Configuration

```elixir
# config/config.exs
config :my_app, MyApp.CommandedApp,
  event_store: [
    adapter: Commanded.EventStore.Adapters.EventStore,
    event_store: MyApp.EventStore
  ],
  pubsub: :local,
  registry: :local

config :my_app, event_stores: [MyApp.EventStore]

config :my_app, MyApp.EventStore,
  serializer: Commanded.Serialization.JsonSerializer,
  username: "postgres",
  password: "postgres",
  database: "my_app_eventstore",
  hostname: "localhost",
  pool_size: 10

# config/test.exs — use Sandbox pool
config :my_app, MyApp.EventStore,
  pool: Ecto.Adapters.SQL.Sandbox
```

## Core Modules

```elixir
# Event Store
defmodule MyApp.EventStore do
  use EventStore, otp_app: :my_app
  def init(config), do: {:ok, config}
end

# Commanded Application
defmodule MyApp.CommandedApp do
  use Commanded.Application,
    otp_app: :my_app,
    event_store: [
      adapter: Commanded.EventStore.Adapters.EventStore,
      event_store: MyApp.EventStore
    ]

  router(MyApp.Router)
end

# Aggregate — ALWAYS use the behaviour macro
defmodule MyApp.Aggregates.Account do
  use Commanded.Aggregates.Aggregate,   # Injects GenServer process management
    snapshotting: false                  # Optional: [snapshot_every: 100, snapshot_version: 1]

  defstruct [:account_id, :email, balance: 0, status: nil]

  # execute/2 — handle commands, return event(s) or {:error, reason}
  def execute(%__MODULE__{status: nil}, %OpenAccount{} = cmd) do
    %AccountOpened{account_id: cmd.account_id, email: cmd.email}
  end

  # apply/2 — reconstruct state from events (REQUIRED callback)
  def apply(%__MODULE__{} = acct, %AccountOpened{} = e) do
    %__MODULE__{acct | account_id: e.account_id, email: e.email, status: :open}
  end
end
```

## Router DSL

```elixir
defmodule MyApp.Router do
  use Commanded.Commands.Router

  # Identity: which field identifies the aggregate instance
  identify MyApp.Account, by: :account_id, prefix: "account-"
  identify MyApp.Order, by: :order_id, prefix: "order-"

  # Identity by function
  identify MyApp.Transfer, by: &(&1.from_account_id), prefix: "transfer-"

  # Dispatch commands to aggregate
  dispatch [OpenAccount, DepositFunds, WithdrawFunds, CloseAccount],
    to: MyApp.Account

  # Dispatch with middleware
  dispatch CreateOrder,
    to: MyApp.Order,
    middleware: [MyApp.Middleware.Validation]

  # Dispatch with separate command handler
  dispatch OpenAccount,
    to: OpenAccountHandler,
    aggregate: MyApp.Account,
    identity: :account_number

  # Dispatch with lifespan control
  dispatch CloseAccount,
    to: MyApp.Account,
    lifespan: MyApp.AccountLifespan
end
```

## Command Dispatch Options

| Option | Type | Description |
|--------|------|-------------|
| `timeout` | integer | Command execution timeout (ms), default 5000 |
| `consistency` | `:eventual` \| `:strong` | Wait for projections before returning |
| `metadata` | map | Attached to events (user_id, correlation_id) |
| `returning` | atom \| `false` | What to return on success (see below) |
| `causation_id` | UUID string | ID of the event/command that caused this one |
| `correlation_id` | UUID string | Links related commands/events across aggregates |

### `returning:` Option Values

| Value | Returns on success | Use when |
|-------|--------------------|----------|
| (default / `false`) | `:ok` | Fire-and-forget commands |
| `:aggregate_state` | `{:ok, %AggregateStruct{}}` | Need updated state for response |
| `:aggregate_version` | `{:ok, integer()}` | Optimistic concurrency checks |
| `:events` | `{:ok, [%Event{}]}` | Need to inspect emitted events |
| `:execution_result` | `{:ok, %Commanded.Commands.ExecutionResult{}}` | Need everything (uuid, version, events, metadata) |

```elixir
# Dispatch with options — from Commanded test suite
MyApp.CommandedApp.dispatch(command)
MyApp.CommandedApp.dispatch(command, timeout: 30_000)
MyApp.CommandedApp.dispatch(command, consistency: :strong)
MyApp.CommandedApp.dispatch(command, returning: :aggregate_state)
MyApp.CommandedApp.dispatch(command,
  metadata: %{user_id: "user-1", correlation_id: UUID.uuid4()}
)

# Router dispatch with application
MyApp.Router.dispatch(command, application: MyApp.CommandedApp)
```

## Aggregate Callbacks

| Callback | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `execute/2` | `(state, command) -> result` | event \| [events] \| `{:ok, event}` \| `{:ok, [events]}` \| `{:error, reason}` | Handle command, emit events |
| `apply/2` | `(state, event) -> state` | Updated struct | Reconstruct state from event |
| `after_command/1` | `(command) -> timeout` | `:timer.minutes(30)` \| `:infinity` \| `{:stop, reason}` | Control aggregate lifespan |

## Aggregate Lifespan

```elixir
defmodule MyApp.AccountLifespan do
  @behaviour Commanded.Aggregates.AggregateLifespan

  def after_event(%AccountClosed{}), do: :stop
  def after_event(_), do: :timer.hours(1)
  def after_command(_), do: :infinity
  def after_error(_), do: :stop
end
```

## Command Middleware

```elixir
@behaviour Commanded.Middleware

@impl true
def before_dispatch(%Pipeline{command: command} = pipeline) do
  case validate(command) do
    :ok -> pipeline
    {:error, reason} ->
      pipeline
      |> Pipeline.respond({:error, reason})
      |> Pipeline.halt()
  end
end

@impl true
def after_dispatch(pipeline), do: pipeline

@impl true
def after_failure(pipeline), do: pipeline
```

## Event Handler

```elixir
defmodule MyApp.EventHandlers.Notifier do
  use Commanded.Event.Handler,
    application: MyApp.CommandedApp,
    name: __MODULE__,
    consistency: :eventual,     # :eventual (default) or :strong
    start_from: :origin,        # :origin, :current, or event number
    subscription_opts: [
      checkpoint_threshold: 100,
      checkpoint_after: 5_000
    ]

  def handle(%AccountOpened{} = event, metadata) do
    # metadata contains: event_id, event_number, stream_id, stream_version,
    #   correlation_id, causation_id, created_at
    :ok
  end

  # Error callback — from Commanded's event_handler_error_handling_test.exs
  def error({:error, reason}, event, %{context: context}) do
    failures = Map.get(context, :failures, 0)
    cond do
      failures >= 3 -> :skip
      transient?(reason) -> {:retry, :timer.seconds(5 * (failures + 1))}
      true -> :skip
    end
  end
end
```

### Error Callback Return Values

| Return | Effect |
|--------|--------|
| `:skip` | Skip this event, continue processing |
| `{:retry, delay_ms}` | Retry after delay |
| `{:retry, command}` | Retry with modified command (process managers) |
| `{:stop, reason}` | Stop the handler/process manager |

## Ecto Projector

```elixir
defmodule MyApp.Projectors.AccountSummary do
  use Commanded.Projections.Ecto,
    application: MyApp.CommandedApp,
    repo: MyApp.Repo,
    name: "AccountSummary"

  import Ecto.Query  # Required for from/2 in update_all projections

  project(%AccountOpened{} = event, _metadata, fn multi ->
    Ecto.Multi.insert(multi, :account, %AccountSummary{
      account_id: event.account_id,
      email: event.email,
      balance: event.initial_balance,
      status: :open
    })
  end)

  project(%FundsDeposited{} = event, _metadata, fn multi ->
    Ecto.Multi.update_all(multi, :account,
      from(a in AccountSummary, where: a.account_id == ^event.account_id),
      set: [balance: event.new_balance]
    )
  end)
end
```

## Process Manager Callbacks

| Callback | Signature | Returns |
|----------|-----------|---------|
| `interested?/1` | `(event) -> result` | `{:start, id}` \| `{:continue, id}` \| `{:stop, id}` \| `{:start!, id}` \| `{:continue!, id}` \| `false` |
| `handle/2` | `(state, event) -> commands` | command \| [commands] \| `[]` |
| `apply/2` | `(state, event) -> state` | Updated struct |
| `error/3` | `(error, command_or_event, failure_context) -> result` | `:skip` \| `{:retry, delay}` \| `{:stop, reason}` |

### interested?/1 Return Values

| Return | Meaning |
|--------|---------|
| `{:start, id}` | Start new process manager instance |
| `{:continue, id}` | Continue existing instance |
| `{:stop, id}` | Stop and cleanup instance |
| `{:start!, id}` | Start if not exists, error if exists |
| `{:continue!, id}` | Continue, error if not started |
| `false` | Not interested in this event |

## Commanded.Aggregate.Multi (Multi-Event Commands)

Use when a single command must emit multiple events with state threaded between them — e.g., a withdrawal that also triggers an overdrawn warning.

```elixir
alias Commanded.Aggregate.Multi

def execute(%__MODULE__{} = acct, %WithdrawFunds{amount: amount}) do
  acct
  |> Multi.new()
  |> Multi.execute(:withdraw, fn state ->
    %FundsWithdrawn{account_id: state.account_id, amount: amount, new_balance: state.balance - amount}
  end)
  |> Multi.execute(:check_overdrawn, fn state ->
    # state already has the withdrawal applied — balance is updated
    if state.balance < 0 do
      %AccountOverdrawn{account_id: state.account_id, balance: state.balance}
    else
      []  # No event
    end
  end)
end
```

**How it works:** After each `execute` step, returned events are applied via `apply/2` to update the aggregate state. The next step receives the updated state. This enables dependent calculations (running totals, threshold checks).

| Function | Purpose |
|----------|---------|
| `Multi.new(aggregate)` | Initialize from current aggregate state |
| `Multi.execute(multi, name, fun)` | Add a step; `fun` receives updated state, returns event(s) or `[]` |
| `Multi.reduce(multi, name, enum, fun)` | Process an enumerable, threading state through each item |

## Phoenix Integration

Dispatching commands from Phoenix controllers and LiveView:

```elixir
# In a Phoenix context module
defmodule MyApp.Accounts do
  alias MyApp.CommandedApp

  def open_account(attrs) do
    cmd = %OpenAccount{
      account_id: Ecto.UUID.generate(),
      email: attrs["email"],
      name: attrs["name"]
    }

    case CommandedApp.dispatch(cmd, returning: :aggregate_state) do
      {:ok, _state} -> {:ok, cmd.account_id}
      {:error, reason} -> {:error, reason}
    end
  end
end

# In a Phoenix controller
def create(conn, %{"account" => params}) do
  case MyApp.Accounts.open_account(params) do
    {:ok, account_id} ->
      conn
      |> put_flash(:info, "Account created")
      |> redirect(to: ~p"/accounts/#{account_id}")

    {:error, reason} ->
      conn
      |> put_flash(:error, inspect(reason))
      |> render(:new)
  end
end

# In a LiveView
def handle_event("deposit", %{"amount" => amount}, socket) do
  cmd = %DepositFunds{account_id: socket.assigns.account_id, amount: String.to_integer(amount)}

  case MyApp.CommandedApp.dispatch(cmd, consistency: :strong) do
    :ok ->
      # Strong consistency — projection is updated, safe to re-read
      account = MyApp.Accounts.get_account(socket.assigns.account_id)
      {:noreply, assign(socket, :account, account)}
    {:error, reason} ->
      {:noreply, put_flash(socket, :error, inspect(reason))}
  end
end
```

**Key pattern:** Context modules wrap dispatch, controllers/LiveView call contexts. Use `returning: :aggregate_state` when you need the result, `consistency: :strong` when you'll immediately read the projection.

## Snapshotting

```elixir
defmodule MyApp.Account do
  use Commanded.Aggregates.Aggregate,
    snapshotting: [
      snapshot_every: 100,       # Snapshot every N events
      snapshot_version: 1        # Version for migration
    ]

  defstruct [:account_id, :balance, :status]
  # ...
end
```

## Event Upcasting

```elixir
# From Commanded's upcaster_test.exs
defmodule MyApp.EventUpcaster do
  @behaviour Commanded.Event.Upcaster

  def upcast(%{"event_type" => "Elixir.MyApp.Events.AccountOpened"} = event, _metadata) do
    data = Map.put_new(event["data"], "subscription_plan", "free")
    %{event | "event_type" => "Elixir.MyApp.Events.AccountOpened.V2", "data" => data}
  end

  def upcast(event, _metadata), do: event
end

# Register in config
config :my_app, MyApp.EventStore,
  upcasters: [MyApp.EventUpcaster]
```

## Serialization

```elixir
# Events should be converted to JSON-compatible maps at the serialization boundary.
defmodule MyApp.Events.AccountOpened do
  defstruct [:account_id, :email, :name, :initial_balance, :opened_at]
end

# Commands use plain structs; command handlers own validation and conversion.
defmodule MyApp.Commands.OpenAccount do
  defstruct [:account_id, :email, :name, :initial_balance]
end
```

## Metadata Fields

| Field | Type | Description |
|-------|------|-------------|
| `event_id` | string | Unique event identifier |
| `event_number` | integer | Global event sequence number |
| `stream_id` | string | Aggregate stream identifier |
| `stream_version` | integer | Stream-local version |
| `correlation_id` | string | Links related commands/events |
| `causation_id` | string | ID of event that caused this one |
| `created_at` | DateTime | When event was recorded |

## Mix Tasks

```bash
# Event store management
mix event_store.create           # Create database
mix event_store.drop             # Drop database
mix event_store.init             # Initialize schema (tables)
mix event_store.gen.migration    # Generate migration for schema changes

# Combined
mix do event_store.create, event_store.init

# Reset handler/projector subscription (replays all events)
mix commanded.reset --app MyApp.CommandedApp --handler MyApp.Projectors.AccountSummary
```

## Supervision Tree

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyApp.Repo,                                    # Ecto (if using projections)
      MyApp.CommandedApp,                            # Commanded application
      MyApp.ProcessManagers.OrderFulfillment,        # Process managers
      MyApp.Projectors.AccountSummary,               # Projectors
      MyApp.EventHandlers.EmailNotifier              # Event handlers (notifiers)
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Concurrency and Consistency

```elixir
# Optimistic concurrency (default) — from Commanded dispatch tests
case MyApp.CommandedApp.dispatch(command) do
  :ok -> {:ok, :success}
  {:error, :concurrency_error} -> {:error, :conflict}  # Retry or handle
  {:error, reason} -> {:error, reason}
end

# Strong consistency — waits for handlers marked :strong
MyApp.CommandedApp.dispatch(command, consistency: :strong)

# Handler with strong consistency
use Commanded.Event.Handler,
  consistency: :strong  # Dispatch blocks until this handler processes
```

## InMemory Event Store (Testing)

```elixir
# Commanded provides an in-memory adapter for testing
# No external database needed
config :my_app, MyApp.CommandedApp,
  event_store: [
    adapter: Commanded.EventStore.Adapters.InMemory,
    serializer: Commanded.Serialization.JsonSerializer
  ]
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "EventStore database has not been created" | `mix event_store.create && mix event_store.init` |
| Concurrency errors on dispatch | Aggregate identity inconsistent — check `identify/2` in router |
| Events not being processed | Verify handler in supervision tree, check handler `name` matches |
| Projection out of sync | `mix commanded.reset --app App --handler Handler` |
| Slow aggregate rehydration | Enable snapshotting: `snapshot_every: 100` |

## Related Files

- **[eventsourcing-examples.md](eventsourcing-examples.md)** — 13 complete worked examples: aggregates, commands/events, Ecto changesets, router/application, projections, process managers, testing, upcasting, GDPR crypto-shredding, projection rebuilding
- **[SKILL.md](SKILL.md)** — Core Elixir skill with Event Sourcing & CQRS overview, "When to Use" decision guide
- **[ecto-reference.md](ecto-reference.md)** — Ecto schemas, changesets, queries, migrations — used in projections and command validation
- **[otp-reference.md](otp-reference.md)** — Supervision trees, GenServer patterns — Commanded aggregates are GenServer processes
