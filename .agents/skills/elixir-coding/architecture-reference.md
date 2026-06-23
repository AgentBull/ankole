# Elixir Architecture Reference

> Supporting reference for the [Elixir skill](SKILL.md). See also: [type-system.md](type-system.md), [debugging-profiling.md](debugging-profiling.md).

## Section Index

| Section | Key Content |
|---------|------------|
| [Architectural Principles](#architectural-principles) | 11 foundational rules governing all structural decisions |
| [Architecture Decision Rules](#architecture-decision-rules-llm) | ALWAYS/NEVER rules for LLM architectural guidance |
| [Actor Model](#the-actor-model--beams-concurrency-architecture) | Process isolation, message passing semantics |
| [Hexagonal Architecture](#hexagonal-architecture-ports--adapters) | Behaviours as ports, implementations as adapters, config wiring |
| [Side Effects Isolation](#side-effects-isolation) | Pure core / impure shell, GenServer pure delegation |
| [Layered Architecture](#layered-architecture) | Interface → Domain ← Infrastructure, boundary patterns |
| [Configuration](#configuration) | Compile-time vs runtime config, secrets |
| [Project Layouts](#project-layouts) | Single app, umbrella, poncho, library vs application |
| [Domain Boundaries](#domain-boundaries-contexts) | Contexts, entities, aggregates, context mapping |
| [Data Ownership](#data-ownership--consistency) | Cross-context transactions, idempotency, multi-tenancy |
| [Inter-Context Communication](#inter-context-communication) | 6 mechanisms: direct → PubSub → GenStage → Oban → Commanded |
| [Supervision as Architecture](#supervision-as-architecture) | Error kernel, strategies, stateful vs stateless processes |
| [Process Design Patterns](#anti-pattern-simulating-objects-with-processes) | Object-with-process anti-pattern, instructions pattern, callback module pattern |
| [Resilience Patterns](#resilience-patterns) | Bulkheads, circuit breaker, retry, degradation, timeouts |
| [Pipeline Architecture](#pipeline-architecture) | Plug, GenStage, Broadway, Absinthe phases |
| [Production Patterns](#production-patterns) | Telemetry, caching, NIF architecture |
| [Security Architecture](#security-architecture) | Input validation, authorization, secrets |
| [Observability Architecture](#observability-architecture) | Metrics, logging, tracing |
| [Production Decision Trees](#production-architecture-decision-tree) | 5-step planning guide, refactoring signals |
| [Growing Architecture](#growing-architecture--small-to-large) | Small → medium → large progression |
| [Distributed Architecture](#distributed-architecture) | What changes, communication, when NOT to distribute |
| [Architectural Styles](#architectural-styles-in-elixir) | MVC, microservices, event-driven, CQRS, how styles combine |
| [Anti-Patterns Catalog](#anti-patterns-catalog) | Imperative habits, architecture, testing, OTP, performance |

## Architectural Principles

These principles govern all structural decisions. When in doubt, refer back here.

1. **Dependencies point inward.** Interface depends on Domain. Domain depends on nothing external. Infrastructure implements contracts defined by Domain. Never let inner layers reference outer layers. A domain module must NEVER alias, import, or reference web modules, controller helpers, or framework-specific types.

2. **Behaviours are ports. Implementations are adapters.** Every external dependency (database, API, email, file system, hardware) is behind a `@callback` behaviour defined by the domain. Config selects which implementation runs. This IS hexagonal architecture — Elixir has it built in. Note: Ecto itself follows this pattern — `Ecto.Adapter` is a behaviour, Postgres/MySQL/SQLite are adapters. The pattern is pervasive in the ecosystem.

3. **Side effects belong in infrastructure, never in domain** — the ideal. In practice, Phoenix contexts intentionally mix Repo calls into domain-adjacent modules (`mix phx.gen.context` generates this). Full separation (pure domain, Repo behind behaviours) is practiced in event-sourced systems (Commanded) but is not the norm for standard Phoenix CRUD apps. For non-Repo side effects (HTTP, email, file I/O), the behaviour boundary is consistently applied.

4. **The supervision tree IS the architecture.** Start order = dependency order. Strategy encodes coupling. The tree is not just fault tolerance — it expresses which components depend on which, what restarts together, and what can fail independently.

5. **Error kernel design.** Stable processes hold critical state near the top of the tree. Volatile, crash-prone workers live below. If a worker crashes, critical state survives. Design for recovery, not prevention.

6. **Pure core, impure shell.** GenServers delegate business logic to pure functions. The GenServer handles process mechanics (state, messages, lifecycle). Pure functions handle domain logic (calculations, validations, transformations). This makes domain logic testable without processes. For complex cases, use the [instructions pattern](#the-instructions-pattern--separating-domain-from-side-effects) — domain functions return instruction tuples, GenServer interprets them.

7. **Each boundary module has one reason to change: its domain changes.** If a module changes because both business rules changed AND the database schema changed, it has too many responsibilities. Boundary modules are public API facades. Internal modules use `@moduledoc false`. Cross-boundary communication goes through public APIs, never through internal modules or direct Repo access.

8. **Design for replaceability.** Can you swap this component's implementation without changing business logic? If not, introduce a behaviour at the boundary. Behaviours enable extension without modifying existing code — add a new adapter, configure it, done. Protocols enable new types without modifying existing dispatch — implement the protocol for the new type, done.

9. **Keep behaviours small and focused.** No client should be forced to depend on callbacks it doesn't use. If a module only needs `charge/2`, don't force it to depend on a behaviour that also defines `refund/1`, `subscribe/2`, and `list_transactions/1`. Split into focused behaviours (`Chargeable`, `Refundable`). Prefer multiple small behaviours over one large one. Use `@optional_callbacks` sparingly — it weakens the contract.

10. **The testability test.** If you cannot test a business rule without starting a database, web server, or external service, your architecture has a boundary problem. Pure domain logic should be testable with plain ExUnit — no Repo, no HTTP, no processes required. If a test needs complex setup of many modules, you are missing a behaviour boundary.

11. **Scream the domain.** Top-level module names should reflect the business domain (`Accounts`, `Catalog`, `Billing`, `Sensors`), not technical concerns (`Controllers`, `Models`, `Services`, `Helpers`). A developer reading the module tree should understand what the system does, not what framework it uses.

## Architecture Decision Rules (LLM)

These rules capture the most critical architectural decisions. When generating or reviewing Elixir code, follow these without exception.

1. **NEVER** put business logic in interface modules (controllers, LiveView, CLI handlers). They translate input, delegate to a context, and format output — nothing else.
2. **NEVER** organize code into `models/`, `services/`, or `helpers/` directories. Use contexts (boundary modules) with internal modules marked `@moduledoc false`.
3. **NEVER** call `Repo` directly from outside the owning context. Cross-context data access goes through the owning context's public API.
4. **NEVER** import or alias web/framework modules from domain modules. Domain must be framework-agnostic.
5. **ALWAYS** put external dependencies (APIs, email, file I/O, hardware) behind a `@callback` behaviour. Config selects the implementation. Test with Mox.
6. **ALWAYS** use `GenServer.call` (not `cast`) across node boundaries — network partitions make `cast` unreliable.
7. **ALWAYS** default to the simplest architecture: contexts + supervision + behaviours. Add PubSub, GenStage, Oban, or event sourcing only when you have the specific problem they solve.
8. **ALWAYS** start with a single Mix application. Split into umbrella/poncho only when teams or deployment targets demand it.
9. **NEVER** split into microservices for "loose coupling" or "fault isolation" — OTP already provides both. Split only for different languages, compliance isolation, or extreme scaling.
10. **ALWAYS** put GenServer business logic in a separate pure module. The GenServer handles process mechanics; pure functions handle domain logic.
11. **PREFER** GenStage/Broadway over PubSub when producer rate can exceed consumer throughput or data loss is unacceptable.
12. **NEVER** place circuit breakers or retry logic in domain modules. These belong in infrastructure adapters.
13. **ALWAYS** make operations idempotent when they may be retried (Oban workers, webhook handlers, event processors, distributed calls).
14. **NEVER** use `String.to_atom(user_input)` — atom table exhaustion. Use `String.to_existing_atom/1` or explicit mapping.
15. **ALWAYS** set timeouts at every boundary, cascading correctly: outer > middle > inner.

## The Actor Model — BEAM's Concurrency Architecture

### What "Actor Model" Means in Practice

| Property | What It Means | Consequence |
|----------|--------------|-------------|
| **Isolated state** | Each process has its own heap and GC | No locks, no mutexes, no race conditions on shared data |
| **Message passing** | Processes communicate only by sending messages | All inter-process data is copied (immutable by design) |
| **Shared nothing** | No shared memory between processes | Scales linearly across cores; GC is per-process, never stop-the-world |
| **Location transparent** | `send(pid, msg)` works identically for local and remote pids | Distribution is a configuration choice, not a code change |
| **Fail independently** | One process crash doesn't affect others | Supervision handles recovery; the rest of the system continues |

### Message Passing Semantics

| Guarantee | Meaning | Implication |
|-----------|---------|-------------|
| **At-most-once** | A message is delivered zero or one times (default) | Messages can be lost if receiver crashes before processing |
| **Ordering** | Messages from process A to process B arrive in send order | But messages from A and C to B may interleave |
| **No exactly-once** | BEAM provides no built-in exactly-once delivery | Application must handle via idempotency (see Data Ownership) |
| **`call` semantics** | GenServer.call succeeds OR caller gets exit signal | Caller always knows the outcome — success, timeout, or crash |

**Architectural rule:** Use `GenServer.call` (synchronous) when you need to know the outcome. Use `GenServer.cast` or `send` (asynchronous) only when fire-and-forget is acceptable. Across node boundaries, ALWAYS use `call` — network partitions make `cast` unreliable.

## Hexagonal Architecture (Ports & Adapters)

| Hexagonal Concept | Elixir Implementation |
|-------------------|----------------------|
| Port (interface)  | `@callback` behaviour |
| Adapter (implementation) | Module implementing the behaviour |
| Domain core | Context modules with pure functions |
| Driving adapter (input) | Phoenix controllers, LiveView, CLI, API |
| Driven adapter (output) | Repo, HTTP clients, email, file I/O |
| Configuration | `Application.compile_env` selects implementation |

### The Pattern

```
                    ┌─────────────────────┐
   HTTP Request ──→ │                     │ ──→ Stripe API
   LiveView    ──→ │    Domain Core       │ ──→ PostgreSQL
   CLI         ──→ │    (Contexts)        │ ──→ Email Service
   GenServer   ──→ │    Pure Functions    │ ──→ File System
                    └─────────────────────┘
                    Driving    │    Driven
                    Adapters   │    Adapters
                    (input)    │    (output)
                               │
                     Behaviours define
                     the boundary
```

### Complete Example

```elixir
# === PORT: Domain defines what it needs ===
defmodule MyApp.PaymentGateway do
  @moduledoc "Contract for payment processing. Domain owns this."

  @callback charge(Decimal.t(), String.t()) ::
    {:ok, %{transaction_id: String.t()}} | {:error, term()}

  @callback refund(String.t()) ::
    :ok | {:error, term()}
end

# === ADAPTER: Infrastructure implements it ===
defmodule MyApp.PaymentGateway.Stripe do
  @behaviour MyApp.PaymentGateway

  @impl true
  def charge(amount, card_token) do
    case Stripe.Charge.create(%{amount: amount, source: card_token}) do
      {:ok, %{id: id}} -> {:ok, %{transaction_id: id}}
      {:error, %{message: msg}} -> {:error, msg}
    end
  end

  @impl true
  def refund(transaction_id) do
    case Stripe.Refund.create(%{charge: transaction_id}) do
      {:ok, _} -> :ok
      {:error, %{message: msg}} -> {:error, msg}
    end
  end
end

# === ADAPTER: Test double ===
# In test_helper.exs:
Mox.defmock(MyApp.PaymentGateway.Mock, for: MyApp.PaymentGateway)

# === DOMAIN: Context uses the port, not any adapter ===
defmodule MyApp.Billing do
  @gateway Application.compile_env(:my_app, :payment_gateway)

  def charge_order(order) do
    with {:ok, result} <- @gateway.charge(order.total, order.card_token) do
      # Pure domain logic here — update order, etc.
      {:ok, %{order | transaction_id: result.transaction_id, status: :paid}}
    end
  end

  defdelegate refund(transaction_id), to: @gateway
end
```

**Config swaps the adapter:**

```elixir
# config/config.exs
config :my_app, :payment_gateway, MyApp.PaymentGateway.Stripe

# config/test.exs
config :my_app, :payment_gateway, MyApp.PaymentGateway.Mock
```

### When to Use Hexagonal Boundaries

| Situation | Use Behaviour? | Reason |
|-----------|---------------|--------|
| External API (Stripe, S3, SendGrid) | **Yes** | Must mock in tests, may swap provider |
| Database (Repo) | Usually no | Ecto already abstracts this; use Sandbox in tests |
| Internal pure logic | No | Just call the function directly |
| Hardware / native code (NIF) | **Yes** | Need testability without hardware |
| Cross-context communication | Depends | Direct call for simple; PubSub/behaviour for decoupled |
| Configuration-driven strategy | **Yes** | Different behaviour per environment or tenant |

## Side Effects Isolation

Elixir functions are fundamentally about **data transformation** — data goes in, transformed data comes out. A pure function's output is determined entirely by its input. If you know the input, you know the output.

**A side effect is any operation where knowing the input does NOT tell you the output** — because the result depends on external state. Database reads, HTTP calls, file I/O, sending messages, getting the current time — these all depend on something outside the function.

```elixir
# Pure function — input determines output, always
def calculate_total(items) do
  Enum.reduce(items, Decimal.new(0), &Decimal.add(&2, &1.price))
end

# Side effect — same input, different output depending on external state
def get_product(id) do
  Repo.get(Product, id)  # Depends on database state, not just id
end
```

### The Rule

**Domain logic is pure data transformation. Side effects live at the edges — in dedicated, supervised processes.**

Side-effecting operations (email, HTTP calls, file writes, notifications) belong in their own processes so they can:
- **Crash independently** without taking down the caller or domain logic
- **Be supervised and restarted** by OTP supervision trees
- **Be retried** with backoff strategies
- **Be tested in isolation** from business logic

```elixir
# BAD: Side effects mixed into domain logic
defmodule MyApp.Orders do
  def complete_order(order) do
    order = %{order | status: :completed, completed_at: DateTime.utc_now()}
    Repo.update!(order)                    # Side effect in domain
    Mailer.send_confirmation(order)        # Side effect in domain
    Warehouse.notify_shipment(order)       # Side effect in domain
    {:ok, order}
  end
end

# GOOD: Domain is pure, side effects are event-driven
defmodule MyApp.Orders do
  def complete_order(order) do
    changeset = Order.complete_changeset(order)

    with {:ok, order} <- Repo.update(changeset) do
      # Broadcast event — subscribers handle side effects
      # Use Phoenix.PubSub, :pg, or any pub/sub mechanism
      broadcast("orders", {:order_completed, order})
      {:ok, order}
    end
  end

  defp broadcast(topic, message) do
    # Phoenix: Phoenix.PubSub.broadcast(MyApp.PubSub, topic, message)
    # Pure OTP: Enum.each(:pg.get_members(:my_app, topic), &send(&1, message))
  end
end

# Side effect handlers are separate, independently supervised
defmodule MyApp.Notifications.OrderListener do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    # Subscribe via whichever PubSub mechanism your app uses
    Phoenix.PubSub.subscribe(MyApp.PubSub, "orders")
    {:ok, nil}
  end

  def handle_info({:order_completed, order}, state) do
    MyApp.Mailer.send_confirmation(order)
    {:noreply, state}
  end
end
# Each listener is an independent failure domain — email failure doesn't block shipment
```

### GenServer: Pure Core, Impure Shell

GenServers should delegate business logic to pure functions. The GenServer is plumbing — message routing, state storage, lifecycle management. The pure module is the brain.

```elixir
# === Pure module — testable without processes ===
defmodule MyApp.RateLimiter.Logic do
  @max_requests 100
  @window_ms 60_000

  defstruct requests: %{}

  def check(state, client_id, now \\ System.monotonic_time(:millisecond)) do
    {state, count} = count_recent(state, client_id, now)

    if count < @max_requests do
      state = record_request(state, client_id, now)
      {state, :allowed}
    else
      {state, {:denied, retry_after(state, client_id, now)}}
    end
  end

  defp count_recent(state, client_id, now) do
    timestamps = Map.get(state.requests, client_id, [])
    recent = Enum.filter(timestamps, &(&1 > now - @window_ms))
    {put_in(state.requests[client_id], recent), length(recent)}
  end

  defp record_request(state, client_id, now) do
    update_in(state.requests[client_id], &[now | &1 || []])
  end

  defp retry_after(state, client_id, now) do
    oldest = state.requests[client_id] |> Enum.min()
    oldest + @window_ms - now
  end
end

# === GenServer — just plumbing ===
defmodule MyApp.RateLimiter do
  use GenServer

  alias MyApp.RateLimiter.Logic

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def check(client_id), do: GenServer.call(__MODULE__, {:check, client_id})

  @impl true
  def init(_opts), do: {:ok, %Logic{}}

  @impl true
  def handle_call({:check, client_id}, _from, state) do
    {new_state, result} = Logic.check(state, client_id)
    {:reply, result, new_state}
  end
end
```

**Testing the pure module needs no GenServer:**

```elixir
test "allows requests under limit" do
  state = %Logic{}
  {state, :allowed} = Logic.check(state, "client-1", 1000)
  {_state, :allowed} = Logic.check(state, "client-1", 1001)
end
```

## Layered Architecture

Elixir applications naturally form layers. The key principle: **dependencies point inward** — outer layers depend on inner layers, never the reverse. This applies whether you're building a Phoenix web app, a Nerves firmware, a CLI tool, or a pure OTP service.

### The Standard Layers

```
┌─────────────────────────────────────────────┐
│  Interface Layer                             │
│  Web (Phoenix), CLI (escript), API (gRPC),   │
│  Hardware (Nerves), GenServer API, Scenic UI │
│  Thin: translates external input to domain   │
├─────────────────────────────────────────────┤
│  Domain Layer                                │
│  Boundary modules → Business Logic → Structs │
│  Pure functions, validation, rules           │
│  NO side effects, NO infrastructure deps     │
├─────────────────────────────────────────────┤
│  Infrastructure Layer                        │
│  Repo, HTTP clients, email, file storage,    │
│  hardware drivers, message brokers           │
│  Implements behaviours defined by Domain     │
├─────────────────────────────────────────────┤
│  OTP Foundation                              │
│  Application, Supervision tree, Registry     │
│  GenServer, Task, ETS, PubSub               │
└─────────────────────────────────────────────┘
```

**Dependency direction:** Interface → Domain ← Infrastructure ← OTP

The arrow between Domain and Infrastructure points **inward** — Domain defines behaviours (ports), Infrastructure implements them (adapters). Domain never imports or references Infrastructure modules directly.

**Interface layer varies by application type:**

| Application Type | Interface Layer |
|-----------------|-----------------|
| Phoenix web app | Endpoint, Router, Controllers, LiveView |
| Nerves firmware | Hardware interfaces, GPIO callbacks, UART handlers |
| CLI tool | `escript` main, argument parsing, `Mix.Task` |
| Pure OTP service | GenServer/GenStage public API, message protocols |
| Library | Public module API (`@doc`, `@spec`) |

### Data Transformation at Boundaries (Humble Objects)

Interface modules contain zero business logic. They translate input, call a domain function, translate the result back.

```elixir
# Every interface follows the same pattern: translate → delegate → format result

# Phoenix controller
def create(conn, %{"user" => params}) do
  case Accounts.register_user(params) do
    {:ok, user} ->
      conn
      |> put_status(:created)
      |> json(UserJSON.show(user))

    {:error, changeset} ->
      conn
      |> put_status(422)
      |> json(ErrorJSON.error(changeset))
  end
end

# CLI — identical pattern, different I/O
def run(argv) do
  {opts, _, _} = OptionParser.parse(argv, strict: [name: :string, email: :string])
  case Accounts.register_user(Map.new(opts)) do
    {:ok, user} -> IO.puts("Created #{user.name}")
    {:error, changeset} -> IO.puts("Error: #{inspect(changeset.errors)}")
  end
end
# LiveView, GenServer API, Nerves handlers — all follow the same translate → delegate → format pattern
```

**Rule:** If you see a conditional, calculation, or validation in a controller/LiveView/CLI handler, extract it to the domain layer.

### Behaviours as Layer Contracts

Inner layers declare what they need (`@callback`), outer layers provide implementations. See Hexagonal Architecture above for complete example with production + test adapters.

### Protocols as Polymorphic Boundaries

Behaviours = contracts for implementations. Protocols = contracts across types.

```elixir
# Define in shared/core layer
defprotocol MyApp.Exportable do
  @doc "Convert to export format"
  @spec to_csv_row(t()) :: [String.t()]
  def to_csv_row(entity)
end

# Each context implements for its types
defimpl MyApp.Exportable, for: MyApp.Catalog.Product do
  def to_csv_row(product) do
    [product.title, Decimal.to_string(product.price)]
  end
end

defimpl MyApp.Exportable, for: MyApp.Accounts.User do
  def to_csv_row(user) do
    [user.name, user.email]
  end
end
```

### Behaviour vs Protocol Decision

| Use Behaviour when... | Use Protocol when... |
|-----------------------|---------------------|
| Swapping implementations (Stripe vs PayPal) | Dispatching on data type (Product vs User) |
| External service integration | Cross-context polymorphism |
| Testing with Mox | Data format conversion |
| One module implements the whole contract | Each type implements its own logic |
| Compile-time or runtime config selects impl | Type of argument selects impl at call site |

### Protocol-on-Struct for Strategy/Plugin Dispatch (AshAuthentication Pattern)

The behaviour-vs-protocol table above covers the common cases. There's a third pattern: **protocol dispatch on strategy structs** — when you have a collection of typed structs and need polymorphic dispatch without knowing all types at compile time.

```elixir
# Define a protocol — each strategy struct implements its own dispatch
defprotocol MyApp.Strategy do
  @doc "Execute the strategy for the given phase"
  def plug(strategy, conn, phase)

  @doc "List phases this strategy supports"
  def phases(strategy)

  @doc "List actions this strategy provides"
  def actions(strategy)
end

# Each strategy is a struct that implements the protocol
defmodule MyApp.Strategy.Password do
  defstruct [:identity_field, :hashed_password_field, :resettable]

  defimpl MyApp.Strategy do
    def plug(strategy, conn, :sign_in), do: PasswordActions.sign_in(conn, strategy)
    def plug(strategy, conn, :register), do: PasswordActions.register(conn, strategy)
    def phases(_), do: [:sign_in, :register, :reset]
    def actions(_), do: [:sign_in, :register, :reset_request, :reset]
  end
end

defmodule MyApp.Strategy.OAuth2 do
  defstruct [:client_id, :client_secret, :authorize_url, :token_url]

  defimpl MyApp.Strategy do
    def plug(strategy, conn, :authorize), do: OAuthActions.authorize(conn, strategy)
    def plug(strategy, conn, :callback), do: OAuthActions.callback(conn, strategy)
    def phases(_), do: [:authorize, :callback]
    def actions(_), do: [:authorize, :callback]
  end
end

# Thin subtypes reuse a base strategy's struct + protocol impl
defmodule MyApp.Strategy.GitHub do
  # GitHub IS OAuth2 with different defaults
  defdelegate plug(strategy, conn, phase), to: MyApp.Strategy.OAuth2.MyApp.Strategy
  # Or: the GitHub struct can be the same as OAuth2 with auto_set_fields
end

# Dispatch works on any strategy struct — open for extension
def handle_request(conn, %strategy_mod{} = strategy) do
  MyApp.Strategy.plug(strategy, conn, phase_from_request(conn))
end
```

**When to use protocol-on-struct (vs behaviour):**

| Use Protocol-on-Struct | Use Behaviour |
|---|---|
| Collection of typed strategy/plugin structs | Single configurable adapter |
| Dispatch varies by struct type at runtime | Dispatch selected at compile-time/config |
| Open for extension (new structs, no core changes) | Closed set of implementations |
| Each struct carries its own config fields | Config lives in Application env |
| AshAuthentication, Membrane (elements) | Ecto adapters, Oban plugins, Mox |

### Error Wrapping with Structured Context (AshAuthentication Pattern)

For security-sensitive or complex domains, wrap internal errors in a generic domain error with structured `caused_by` metadata. This lets you log full details internally while exposing only safe information externally.

```elixir
defmodule MyApp.AuthError do
  defexception [:message, :caused_by, :strategy, :changeset]

  @impl true
  def message(%{message: msg}), do: msg
end

# In strategy action code — exhaustive matching with different caused_by
defp sign_in(strategy, params) do
  case query_user(strategy, params) do
    {:ok, nil} ->
      # Simulate hash to prevent timing attacks
      Bcrypt.no_user_verify()
      {:error, AuthError.exception(
        message: "Authentication failed",
        strategy: strategy,
        caused_by: %{module: __MODULE__, action: :sign_in,
                      message: "Query returned no users"}
      )}

    {:ok, user} ->
      if Bcrypt.verify_pass(params["password"], user.hashed_password) do
        {:ok, user}
      else
        {:error, AuthError.exception(
          message: "Authentication failed",
          strategy: strategy,
          caused_by: %{module: __MODULE__, action: :sign_in,
                        message: "Password verification failed"}
        )}
      end

    {:error, %Ash.Error{} = error} ->
      {:error, AuthError.exception(
        message: "Authentication failed",
        strategy: strategy,
        caused_by: %{module: __MODULE__, action: :sign_in,
                      message: Exception.message(error)}
      )}
  end
end
```

**Key principles:**
- The external-facing error (`"Authentication failed"`) is always generic — never reveals whether the user exists or the password was wrong
- The `caused_by` map captures full internal details for logging/debugging
- Opt-in verbose logging: `if config.debug_auth_failures?, do: Logger.warning(inspect(caused_by))`
- Works with Splode (Ash's error library) which provides error classes (`:invalid`, `:forbidden`, `:framework`) and structured field declarations

### Real-World Layering Examples

**Ecto's layers:**
- Protocol layer: `Ecto.Queryable` — schemas, strings, queries all become queries
- Behaviour layer: `Ecto.Adapter` — PostgreSQL, MySQL, SQLite implement same contract
- Schema layer: Data definitions and changesets
- Repo layer: Public API that ties everything together

**Plug's layers:**
- Behaviour: `Plug` — `init/1` + `call/2` contract
- Builder: Compiles a pipeline of plugs into nested function calls
- Conn: Immutable request/response struct threaded through plugs

**Ash's layers:**
- Domain: Groups of resources with shared config
- Resource: Declarative entity definitions (actions, policies, relationships)
- DataLayer behaviour: Swappable persistence (ETS, PostgreSQL, custom)
- Authorizer behaviour: Pluggable authorization (policies, RBAC)
- Notifier behaviour: Event publishing after actions

## Configuration

### Config Files

Non-Phoenix projects typically use only `config.exs` and `runtime.exs`. Phoenix adds environment-specific files:

| File | Evaluated | Purpose |
|------|-----------|---------|
| `config/config.exs` | Compile time | Shared defaults, library config, structural config |
| `config/dev.exs` | Compile time | Dev server, watchers, debug flags, hardcoded secrets |
| `config/test.exs` | Compile time | Test isolation, mock adapters, `server: false` |
| `config/prod.exs` | Compile time | `force_ssl`, cache manifests, prod adapters |
| `config/runtime.exs` | Boot time | **Secrets, env vars, anything that varies per deployment** |

**The critical rule:** Never call `System.get_env/1` in compile-time config files for values that vary per deployment. Use `runtime.exs` instead.

```elixir
# config/config.exs — shared compile-time defaults
import Config
config :my_app, ecto_repos: [MyApp.Repo]
config :my_app, MyAppWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: MyApp.PubSub,
  live_view: [signing_salt: "abc123"]
config :phoenix, :json_library, MyApp.JSON
import_config "#{config_env()}.exs"  # MUST be last line

# config/runtime.exs — secrets and env vars
import Config
if config_env() == :prod do
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
  config :my_app, MyAppWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST", "example.com"), port: 443, scheme: "https"],
    secret_key_base: secret_key_base
  config :my_app, MyApp.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end
```

**Reading config at runtime:**

```elixir
# Compile-time — baked into .beam, recompile to change
@val Application.compile_env(:my_app, :some_key)      # nil if missing
@val Application.compile_env!(:my_app, :some_key)     # raises if missing

# Runtime — reads application env, set by config files
Application.fetch_env!(:my_app, :some_key)             # raises if missing
Application.get_env(:my_app, :some_key, default)       # returns default

# System env — raw OS variable, typically used in runtime.exs
System.fetch_env!("SECRET_KEY_BASE")                    # raises if missing
System.get_env("PORT", "4000")                          # returns default
```

**When to use `compile_env` vs `fetch_env!`:** Use `compile_env` when the value must be known at compile time (module attributes, macro expansion, `@gateway` in module body). Use `fetch_env!` for everything else — it reads the current value at runtime, respecting `runtime.exs` changes without recompilation.

### Application.compile_env — Conditional Compilation

`compile_env` is for values that affect **code generation** — what code gets compiled, not just what values are used at runtime:

```elixir
# compile_env — value affects CODE GENERATION (conditional compilation)
# Used when the value determines what code is compiled
debug_errors? = Application.compile_env(:my_app, [MyEndpoint, :debug_errors], false)
if debug_errors?, do: plug Plug.Debugger  # Plug is included/excluded at compile time

# Runtime config — for operational values that can change between deploys
# Port, host, secret_key_base, database URL, etc.
config = Application.get_env(:my_app, MyEndpoint)
port = config[:port] || 4000
```

**Rule:** Use `compile_env` only when the value determines what code is generated. Use runtime config for everything else. `compile_env` triggers recompilation when the value changes — the compiler tracks which modules use it and automatically recompiles them.

**Protocol consolidation interaction:** Protocol implementations are consolidated at compile time. If you conditionally define `defimpl` blocks using `compile_env`, the implementation is baked into the consolidated protocol. Changing the config requires recompilation:

```elixir
# This defimpl is included/excluded at compile time
if Application.compile_env(:my_app, :enable_custom_inspect, false) do
  defimpl Inspect, for: MyApp.Secret do
    def inspect(_secret, _opts), do: "#MyApp.Secret<redacted>"
  end
end
```

## Project Layouts

### Single Application (Default — Start Here)

The standard Elixir project. All code in one `lib/` tree, organized by domain boundaries. This layout works for Phoenix web apps, Nerves firmware, CLI tools, and pure OTP services alike:

```
my_app/
├── lib/
│   ├── my_app/            # Domain layer
│   │   ├── accounts.ex    # Context: public API
│   │   ├── accounts/
│   │   │   ├── user.ex    # Schema (internal to context)
│   │   │   └── user_token.ex
│   │   ├── catalog.ex     # Another context
│   │   ├── catalog/
│   │   │   ├── product.ex
│   │   │   └── category.ex
│   │   ├── application.ex # Supervision tree
│   │   └── repo.ex        # Ecto Repo
│   └── my_app_web/        # Web layer
│       ├── controllers/
│       ├── live/
│       ├── components/
│       ├── router.ex
│       └── endpoint.ex
├── config/
├── test/
└── mix.exs
```

**When sufficient:** Most applications. Contexts provide domain boundaries without the overhead of multiple apps. Scale by adding contexts, not apps.

### Umbrella Project

Multiple OTP applications in one repository sharing build artifacts, deps, and config:

```
my_platform/                  # Root (no code here)
├── apps/
│   ├── core/                 # Domain logic, no web dependency
│   │   ├── lib/core/
│   │   │   ├── accounts.ex
│   │   │   └── billing.ex
│   │   └── mix.exs
│   ├── core_web/             # Phoenix web layer
│   │   ├── lib/core_web/
│   │   │   ├── endpoint.ex
│   │   │   └── router.ex
│   │   └── mix.exs           # deps: [{:core, in_umbrella: true}]
│   └── worker/               # Background processing
│       ├── lib/worker/
│       └── mix.exs           # deps: [{:core, in_umbrella: true}]
├── config/config.exs         # Shared config for ALL apps
├── mix.exs                   # apps_path: "apps"
└── mix.lock                  # Single lockfile
```

**Root mix.exs:**

```elixir
defmodule MyPlatform.MixProject do
  use Mix.Project
  def project do
    [apps_path: "apps", version: "0.1.0", deps: deps()]
  end
  defp deps, do: []  # Shared deps go here; app-specific deps in child mix.exs
end
```

**Child mix.exs:**

```elixir
defmodule Core.MixProject do
  use Mix.Project
  def project do
    [
      app: :core,
      version: "0.1.0",
      build_path: "../../_build",       # Shared build
      config_path: "../../config/config.exs",  # Shared config
      deps_path: "../../deps",          # Shared deps
      lockfile: "../../mix.lock",       # Shared lockfile
      deps: [{:ecto, "~> 3.12"}]       # App-specific deps
    ]
  end
end
```

**Key properties:**
- Single `mix test` runs all apps; `mix test --app core` runs one
- Single `config/config.exs` for all apps (both strength and limitation)
- Sibling deps via `in_umbrella: true` — resolved to `path: "../sibling"`
- All apps share the same dependency versions (no version conflicts possible)
- `mix new my_platform --umbrella` scaffolds the structure

**When to use:** Multiple teams working on distinct subsystems. Separate deployment targets (web vs worker vs API). Enforcing hard module boundaries at the OTP application level.

### Poncho Project

Independent Mix projects in one repository linked by path dependencies:

```
my_platform/
├── core/                     # Independent project
│   ├── lib/core/
│   ├── config/config.exs     # Own config
│   ├── mix.exs               # Own deps, own lockfile
│   └── mix.lock
├── web/                      # Independent project
│   ├── lib/web/
│   ├── config/config.exs
│   ├── mix.exs               # deps: [{:core, path: "../core"}]
│   └── mix.lock
└── worker/
    ├── lib/worker/
    ├── mix.exs               # deps: [{:core, path: "../core"}]
    └── mix.lock
```

**Key differences from umbrella:**
- Each app has its own config, deps, and lockfile
- Different apps can use different dependency versions
- No shared build directory — fully independent compilation
- No `mix test` from root — test each app separately
- More independence, more management overhead

**When to use:** Apps need different dependency versions. Apps have different release cycles. Migrating toward fully independent Hex packages. Teams need complete autonomy.

### Layout Decision Guide

| Signal | Layout |
|--------|--------|
| Single team, one deployable | Single app with contexts |
| Need hard compile-time boundaries | Umbrella |
| Different teams, shared config OK | Umbrella |
| Different dependency versions needed | Poncho |
| Extracting a library for reuse | Poncho → eventual Hex package |
| "Should I split?" uncertainty | Don't split — use contexts |

### Library vs Application Architecture

**Libraries** must not assume anything about the host environment:

| Constraint | Why | Pattern |
|-----------|-----|---------|
| No global state | Library doesn't own the supervision tree | Accept supervisor/process refs as arguments |
| No `Application.get_env` at compile time | Config belongs to the consuming app | Accept options at runtime (`start_link(opts)`) |
| No hard dependencies on frameworks | Consumer may not use Phoenix/Ecto | Optional dependencies, behaviour-based extensions |
| Minimal dependency tree | Each dep is a liability for consumers | Prefer Erlang stdlib over adding deps |
| Extension via behaviours | Consumers need to customize | Define `@callback`, don't hardcode implementations |

```elixir
# BAD: Library assumes it owns the world
defmodule MyLib.Worker do
  use GenServer
  def start_link(_) do
    # Hardcoded name — can't run two instances
    GenServer.start_link(__MODULE__, Application.get_env(:my_lib, :config), name: __MODULE__)
  end
end

# GOOD: Library is a guest in someone else's application
defmodule MyLib.Worker do
  use GenServer
  def start_link(opts) do
    # Consumer controls name, config — library assumes nothing
    {config, server_opts} = Keyword.split(opts, [:buffer_size, :flush_interval])
    GenServer.start_link(__MODULE__, config, server_opts)
  end

  # Let consumer add to their supervision tree
  def child_spec(opts) do
    %{id: opts[:id] || __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end
end
```

**Application architecture differs:**

| Application | Library |
|------------|---------|
| Owns supervision tree | Added as child to someone else's tree |
| Uses `Application.get_env` in `runtime.exs` | Accepts config via function arguments |
| Depends on specific frameworks | Framework-agnostic or optional integration |
| Contexts as boundaries | Modules with clear public API (`@moduledoc`) |
| Can use global registries, PubSub | Must accept registry/PubSub refs as options |
| Config-driven behaviour swapping | Consumer passes implementation module |

**Library extension pattern:**

```elixir
defmodule MyLib do
  @moduledoc "Public API — consumers call these functions"

  @type storage :: module()

  @doc "Start with a storage backend that implements MyLib.Storage behaviour"
  def start_link(storage_module, opts \\ []) do
    MyLib.Server.start_link([{:storage, storage_module} | opts])
  end
end

defmodule MyLib.Storage do
  @moduledoc "Implement this behaviour to provide custom storage"
  @callback store(key :: term(), value :: term()) :: :ok | {:error, term()}
  @callback fetch(key :: term()) :: {:ok, term()} | {:error, :not_found}
end

# Library ships a default implementation
defmodule MyLib.Storage.ETS do
  @behaviour MyLib.Storage
  @impl true
  def store(key, value), do: ...
  @impl true
  def fetch(key), do: ...
end
```

## Domain Boundaries (Contexts)

Boundary modules group related functionality behind a public API. Phoenix calls these "contexts", but the pattern is framework-agnostic — it works in any Elixir application. The boundary module is the only entry point; internal modules are hidden.

### Entities vs Use Cases

The domain layer contains two kinds of logic:

**Entities** — core business rules that exist regardless of the application. These are pure data structures with functions that enforce invariants:

```elixir
# Entity — business rules about what an Order IS
defmodule MyApp.Orders.Order do
  @moduledoc false
  defstruct [:id, :items, :status, :total]

  def calculate_total(%__MODULE__{items: items}) do
    Enum.reduce(items, Decimal.new(0), &Decimal.add(&2, &1.subtotal))
  end

  def can_cancel?(%__MODULE__{status: status}), do: status in [:pending, :confirmed]
end
```

**Use cases** — application-specific orchestration. Each public function in a boundary module is a use case. It coordinates entities, calls infrastructure through behaviours, and returns `{:ok, _} | {:error, _}`:

```elixir
# Use case — application-specific orchestration
defmodule MyApp.Orders do
  alias MyApp.Orders.Order

  def cancel_order(order_id) do
    with {:ok, order} <- fetch_order(order_id),
         true <- Order.can_cancel?(order),             # Entity rule
         {:ok, order} <- mark_cancelled(order),        # Persistence
         :ok <- notify_cancellation(order) do          # Side effect via behaviour
      {:ok, order}
    else
      false -> {:error, :not_cancellable}
      error -> error
    end
  end
end
```

**For most Elixir applications** a single domain layer is sufficient — entities are internal modules (`@moduledoc false`), use cases are public boundary functions. Separate the two explicitly only when entity rules are complex enough to warrant independent testing and reuse across multiple use cases.

### Boundary Structure

```elixir
# With Ecto (Phoenix, database-backed apps)
defmodule MyApp.Catalog do
  @moduledoc "Product catalog management."

  import Ecto.Query, warn: false
  alias MyApp.Repo
  alias MyApp.Catalog.{Product, Category}

  def list_products, do: Repo.all(Product)
  def get_product!(id), do: Repo.get!(Product, id)

  def create_product(attrs \\ %{}) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end
end

# Without Ecto (Nerves, CLI, pure OTP services)
defmodule MyFirmware.Sensors do
  @moduledoc "Sensor reading and calibration."

  alias MyFirmware.Sensors.{Reader, Calibration}

  defdelegate read(sensor_id), to: Reader
  defdelegate calibrate(sensor_id, reference), to: Calibration

  def read_calibrated(sensor_id) do
    with {:ok, raw} <- Reader.read(sensor_id),
         {:ok, cal} <- Calibration.get(sensor_id) do
      {:ok, Calibration.apply(raw, cal)}
    end
  end
end
```

Internal modules are private to the boundary:

```elixir
defmodule MyApp.Catalog.Product do
  @moduledoc false  # Internal — not part of public API
  use Ecto.Schema
  # ...
end

defmodule MyFirmware.Sensors.Reader do
  @moduledoc false  # Internal
  # ...
end
```

> **Phoenix generators:** `mix phx.gen.context`, `mix phx.gen.live`, `mix phx.gen.html`, `mix phx.gen.auth` scaffold boundary modules with Ecto schemas. See the phoenix skill for full generator reference and field types.

### Boundary Rules

**When to create a new context:**
- Different business domain (Catalog vs ShoppingCart vs Accounts)
- Different teams will own the code
- Data has distinct lifecycle (orders vs products)
- When in doubt, prefer separate contexts — merge later if needed

**When NOT to split:**
- Entities share the same aggregate root (Order and OrderItem → same context)
- Tightly coupled operations that always change together
- Splitting would require constant cross-context calls

### Aggregates as Consistency Boundaries

An aggregate is a cluster of entities that must be consistent as a unit. The aggregate root is the entity you load, validate, and save as a whole. In Ecto, this maps to `cast_assoc` / `cast_embed`:

```elixir
# Order is the aggregate root — OrderItems are part of the aggregate
defmodule MyApp.Orders.Order do
  use Ecto.Schema

  schema "orders" do
    field :status, Ecto.Enum, values: [:pending, :confirmed, :shipped]
    has_many :items, MyApp.Orders.OrderItem, on_replace: :delete
    timestamps()
  end

  def changeset(order, attrs) do
    order
    |> cast(attrs, [:status])
    |> cast_assoc(:items)  # Items are validated and saved WITH the order
    |> validate_at_least_one_item()
  end
end

# The context operates on the aggregate root, not individual items
defmodule MyApp.Orders do
  def add_item(order, item_attrs) do
    items = order.items ++ [item_attrs]
    update_order(order, %{items: items})  # Whole aggregate saved together
  end
end
```

**Rules:**
- Never load/save parts of an aggregate independently — always go through the root
- Each aggregate is a transaction boundary — one `Repo.insert`/`Repo.update` per aggregate
- Different aggregates communicate through the context's public API, not direct associations

### Internal Context Organization

Inside a context, organize however your team prefers — the context module is the boundary:

```
lib/my_app/catalog/
├── product.ex              # Schema
├── category.ex             # Schema
├── product_queries.ex      # Complex query builders
├── import_worker.ex        # Background processing
└── price_calculator.ex     # Pure business logic
```

All internal modules are private. Only `MyApp.Catalog` is the public API.

### Context Relationships (Context Mapping)

Contexts don't exist in isolation — they relate to each other in specific ways:

| Relationship | Meaning | Elixir Implementation |
|-------------|---------|----------------------|
| **Shared kernel** | Two contexts share a data structure | Shared module in a common namespace (e.g., `MyApp.Shared.Money`) |
| **Customer-supplier** | One context serves another | Supplier exposes public API, customer calls it |
| **Conformist** | You adapt to an external model | Anti-corruption layer translates their types to yours |
| **Separate ways** | Contexts are independent | No direct communication, possibly PubSub |

### Anti-Corruption Layer

When integrating with external or legacy systems, translate their data model to yours at the boundary. Never let foreign data structures leak into your domain:

```elixir
# BAD: External API's data model leaks into domain
def process_payment(stripe_charge) do
  # Domain logic uses Stripe's field names and structure
  if stripe_charge["status"] == "succeeded" do
    update_order(stripe_charge["metadata"]["order_id"], stripe_charge["amount"])
  end
end

# GOOD: Anti-corruption layer translates at the boundary
defmodule MyApp.PaymentGateway.Stripe do
  @behaviour MyApp.PaymentGateway

  @impl true
  def charge(amount, token) do
    case Stripe.Charge.create(%{amount: amount, source: token}) do
      {:ok, charge} -> {:ok, to_domain_result(charge)}   # Translate here
      {:error, err} -> {:error, to_domain_error(err)}     # Translate here
    end
  end

  # Translation layer — Stripe's model → our domain model
  defp to_domain_result(charge) do
    %{transaction_id: charge.id, amount: charge.amount, captured_at: DateTime.utc_now()}
  end

  defp to_domain_error(%{code: "card_declined"}), do: :card_declined
  defp to_domain_error(%{code: "expired_card"}), do: :card_expired
  defp to_domain_error(_), do: :payment_failed
end
```

**Rule:** The behaviour adapter IS the anti-corruption layer. All translation between external and domain models happens in the adapter module. Domain code never sees external data structures.

## Data Ownership & Consistency

### Who Owns the Data?

Every table/schema must be owned by exactly one context. That context is the only one allowed to write to those tables. Other contexts read through the owning context's public API.

```elixir
# Accounts context OWNS users table — only it writes
defmodule MyApp.Accounts do
  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end
  def get_user!(id), do: Repo.get!(User, id)
end

# Orders context REFERENCES users but never writes to users table
defmodule MyApp.Orders do
  def create_order(user_id, items) do
    user = MyApp.Accounts.get_user!(user_id)  # Read through owning context
    # ... create order with user_id foreign key
  end
end
```

**When two contexts seem to need the same table:** Either one context owns it and the other reads through the API, or the data belongs in a shared kernel module. Never have two contexts writing to the same table.

### Cross-Context Transactions

What happens when an operation spans multiple contexts?

```elixir
# BAD: Reaching into multiple contexts' internals in one transaction
Repo.transaction(fn ->
  Repo.insert!(%Order{...})           # Orders context data
  Repo.update!(%Product{stock: ...})  # Catalog context data
  Repo.insert!(%Payment{...})         # Billing context data
end)

# OPTION 1: Saga pattern — sequence of compensating operations
defmodule MyApp.OrderSaga do
  def place_order(user_id, items) do
    with {:ok, reservation} <- Catalog.reserve_stock(items),
         {:ok, payment} <- Billing.charge(user_id, total(items)),
         {:ok, order} <- Orders.create(user_id, items, payment.id) do
      {:ok, order}
    else
      {:error, :payment_failed} ->
        Catalog.release_stock(reservation)  # Compensating action
        {:error, :payment_failed}
      {:error, :out_of_stock} ->
        {:error, :out_of_stock}
    end
  end
end

# OPTION 2: Accept eventual consistency
def place_order(user_id, items) do
  with {:ok, order} <- Orders.create(user_id, items) do
    # Async side effects — may fail independently
    Oban.insert(StockReductionWorker.new(%{order_id: order.id}))
    Oban.insert(PaymentChargeWorker.new(%{order_id: order.id}))
    {:ok, order}
  end
end

# OPTION 3: Merge contexts if they always change together
# If Orders and Billing are always modified in the same transaction,
# they belong in the same context — the split was premature
```

**Decision guide:**
- Operations always happen together → merge into one context, use `Ecto.Multi`
- Operations can fail independently → saga with compensating actions
- Eventual consistency acceptable → async with Oban
- Full audit trail needed → event sourcing with process managers

### Idempotency

Operations that may be retried (webhooks, job queues, event handlers, distributed calls) MUST be idempotent — executing them multiple times produces the same result as executing once.

```elixir
# BAD: Not idempotent — double-charging on retry
def charge_order(order_id) do
  order = Orders.get_order!(order_id)
  PaymentGateway.charge(order.total, order.token)  # Charges again on retry!
end

# GOOD: Idempotent — check if already done
def charge_order(order_id) do
  order = Orders.get_order!(order_id)
  case order.payment_status do
    :charged -> {:ok, order}  # Already done, return success
    :pending ->
      with {:ok, result} <- PaymentGateway.charge(order.total, order.token) do
        Orders.mark_charged(order, result.transaction_id)
      end
  end
end

# GOOD: Idempotency via unique constraints (Oban)
%{order_id: order.id}
|> ChargeWorker.new(unique: [period: 300, keys: [:order_id]])
|> Oban.insert()

# GOOD: Idempotency via database constraints
def record_event(event_id, data) do
  %Event{id: event_id, data: data}
  |> Repo.insert(on_conflict: :nothing)  # Silently skip duplicates
end
```

**Where idempotency matters:**
- Oban workers (retried on failure)
- Webhook handlers (provider may retry)
- Event handlers / projectors (may replay)
- Any operation called via `:erpc` or HTTP (network may retry)

### Eventual Consistency

When contexts communicate asynchronously, different parts may temporarily disagree about current state.

**Rules:**
- Accept eventual consistency for non-critical reads (dashboards, analytics, search)
- Require strong consistency for financial operations (use `Ecto.Multi` or saga)
- Show clear state indicators in UI ("processing", "confirmed", "failed")
- Design event handlers to be idempotent — they may process the same event twice
- Use optimistic UI updates — show expected state immediately, correct via PubSub later

### Multi-Tenancy Architecture

| Approach | Isolation | Complexity | When to Use |
|----------|-----------|------------|-------------|
| **Row-level** (tenant_id column) | Low — shared tables | Low | Most SaaS apps, single database, simplest to start |
| **Schema-per-tenant** (Postgres schemas) | Medium — separate tables, shared DB | Medium | Need stronger isolation, moderate tenant count (<1000) |
| **Database-per-tenant** | High — full isolation | High | Regulatory requirement, very different data sizes, separate backups |

#### Row-Level (Default — Start Here)

Every table has a `tenant_id` column. Contexts enforce tenant scoping:

```elixir
# Architectural rule: tenant_id flows through ALL context functions
defmodule MyApp.Catalog do
  def list_products(tenant_id) do
    Product
    |> where(tenant_id: ^tenant_id)
    |> Repo.all()
  end

  def create_product(tenant_id, attrs) do
    %Product{tenant_id: tenant_id}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end
end
```

**Enforce at the data layer** — never rely on callers remembering to filter:

```elixir
# Ecto: default scope via prepare_query callback
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app

  # Automatically scope queries when tenant is set in process dictionary
  @impl true
  def prepare_query(_operation, query, opts) do
    case opts[:tenant_id] || Process.get(:current_tenant_id) do
      nil -> {query, opts}
      tenant_id -> {where(query, tenant_id: ^tenant_id), opts}
    end
  end
end

# Without Ecto: wrapper module enforces scoping
defmodule MyApp.TenantStore do
  def get(tenant_id, key), do: :ets.lookup(:"tenant_#{tenant_id}", key)
  def put(tenant_id, key, value), do: :ets.insert(:"tenant_#{tenant_id}", {key, value})
end
```

#### Schema-Per-Tenant (When Row-Level Isn't Enough)

```elixir
# Ecto prefix-based approach — each tenant gets a Postgres schema
defmodule MyApp.Repo do
  def tenant_prefix(tenant_id), do: "tenant_#{tenant_id}"
end

defmodule MyApp.Catalog do
  def list_products(tenant_id) do
    Product |> Repo.all(prefix: Repo.tenant_prefix(tenant_id))
  end
end
```

#### Architectural Rules for Multi-Tenancy

1. **Choose tenant strategy early** — it affects every context, every query, every migration
2. **Tenant scoping is infrastructure, not domain** — contexts shouldn't contain tenant filtering logic; enforce it in the repo/data layer
3. **Pass tenant_id explicitly** or set it once at the interface boundary (Plug, GenServer init) — don't scatter tenant resolution throughout the codebase
4. **Tenant-specific supervision** — for schema/DB-per-tenant, each tenant may need its own process subtree (connection pool, cache, workers)
5. **Test with multiple tenants** — the #1 multi-tenancy bug is data leaking between tenants

```
Row-level:     Interface → set tenant_id → Contexts use it → Repo enforces it
Schema-level:  Interface → resolve prefix → Contexts pass prefix → Repo applies it
DB-level:      Interface → resolve tenant → Route to tenant's Repo/supervisor
```

## Inter-Context Communication

How contexts talk to each other is a critical architectural decision. Choose the simplest mechanism that meets your needs.

### 1. Direct Function Calls (Default)

The simplest approach. Context A calls Context B's public API directly:

```elixir
defmodule MyApp.ShoppingCart do
  alias MyApp.Catalog

  def add_item_to_cart(cart, product_id) do
    # Call through Catalog context API — not Repo.get!(Product, id)
    product = Catalog.get_product!(product_id)

    %CartItem{quantity: 1, price_when_carted: product.price}
    |> CartItem.changeset(%{})
    |> Ecto.Changeset.put_assoc(:cart, cart)
    |> Ecto.Changeset.put_assoc(:product, product)
    |> Repo.insert()
  end
end
```

**Use when:** Synchronous, request-scoped, simple dependency. The caller needs the result immediately. This is the right default for most cross-context calls.

**Cross-context data references:** Use foreign keys at the schema level but always fetch through context functions. Never `Repo.preload` across context boundaries.

### 2. PubSub (Fire-and-Forget Events)

Decoupled, asynchronous communication where the publisher doesn't know or care who listens. Two options — `Phoenix.PubSub` (if Phoenix is a dependency) or Erlang's built-in `:pg` (no dependencies):

```elixir
# === Option A: Phoenix.PubSub (Phoenix apps) ===
# Publisher
Phoenix.PubSub.broadcast(MyApp.PubSub, "orders", {:order_completed, order})
# Subscriber
Phoenix.PubSub.subscribe(MyApp.PubSub, "orders")
# Receives: handle_info({:order_completed, order}, state)

# === Option B: Erlang :pg (any Elixir app, no deps, OTP 23+) ===
# Start :pg in supervision tree: {pg, :my_app_pubsub}
# Publisher
:pg.get_members(:my_app_pubsub, "orders")
|> Enum.each(&send(&1, {:order_completed, order}))
# Subscriber
:pg.join(:my_app_pubsub, "orders", self())
# Receives: handle_info({:order_completed, order}, state)
```

Subscribers are GenServers that subscribe in `init/1` and handle events in `handle_info/2` (see Side Effects Isolation for full example).

**`:pg` vs `Phoenix.PubSub`:** `:pg` is built into OTP — no dependency, works across nodes automatically. `Phoenix.PubSub` adds topic-based dispatch and pluggable adapters. For non-Phoenix apps, `:pg` is the natural choice.

**Limitations (both):**
- **No persistence** — if a subscriber is down when an event fires, the event is lost forever. No replay, no catch-up.
- **No backpressure** — a fast publisher can overwhelm a slow subscriber. Messages queue in the subscriber's mailbox without bound.
- **No ordering guarantees** — across nodes, messages may arrive out of order.
- **No delivery confirmation** — publisher doesn't know if anyone received the message.

**When PubSub is right:** UI updates (LiveView), notifications where occasional loss is acceptable, decoupling contexts where the subscriber can tolerate missed events, in-process event fan-out.

### 3. Registry for Fine-Grained PubSub

When Phoenix.PubSub topics are too coarse, use Registry with `:duplicate` keys:

```elixir
# Subscribe to specific entity events
Registry.register(MyApp.EventRegistry, {:order, order_id}, [])

# Broadcast to specific entity subscribers only
Registry.dispatch(MyApp.EventRegistry, {:order, order_id}, fn entries ->
  for {pid, _} <- entries, do: send(pid, {:order_updated, order})
end)
```

**Use when:** You need per-entity subscriptions (e.g., LiveView subscribing to updates for a specific order). More efficient than broad PubSub topics when you have many entities.

### 4. GenStage / Broadway (Backpressure Pipelines)

GenStage is a pure OTP library (no Phoenix dependency) that solves a fundamental problem: **what happens when producers are faster than consumers?** PubSub and plain message passing have no answer — mailboxes grow without bound until the system crashes. GenStage inverts control: consumers request data when ready (demand-driven).

**ALWAYS prefer GenStage over PubSub/plain messaging when:**
- Producer rate is variable or bursty and can exceed consumer throughput
- Data loss is unacceptable (PubSub drops events when subscribers are overwhelmed)
- You need multi-stage transformation pipelines (producer → filter → transform → persist)
- Processing involves I/O-bound work (HTTP calls, DB writes) that creates natural bottlenecks
- You need concurrency control — limit how many items are processed simultaneously

**ALWAYS prefer Broadway over raw GenStage when:**
- Consuming from an external message broker (Kafka, SQS, RabbitMQ, Redis Streams)
- You need batching (accumulate N items, flush together — e.g., bulk DB inserts)
- You want declarative concurrency config instead of manual stage wiring
- You need built-in fault tolerance, graceful shutdown, and telemetry

**Keep using PubSub (not GenStage) when:**
- Fan-out to UI (LiveView updates) — consumers are fast, volume is low
- Occasional event loss is acceptable (notifications, analytics)
- No transformation pipeline — just broadcast and forget

GenStage inverts control — consumers request data when ready (`max_demand`). Producer buffers events, emits only when demand exists.

```elixir
# Producer: buffers events, dispatches on demand
defmodule MyApp.OrderProducer do
  use GenStage
  def start_link(_), do: GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  def init(:ok), do: {:producer, %{queue: :queue.new()}}
  def notify(event), do: GenStage.cast(__MODULE__, {:notify, event})

  def handle_cast({:notify, event}, state) do
    dispatch_events(%{state | queue: :queue.in(event, state.queue)}, [])
  end

  def handle_demand(demand, state) when demand > 0, do: dispatch_events(state, [])

  defp dispatch_events(%{queue: queue} = state, events) do
    case :queue.out(queue) do
      {{:value, event}, queue} -> dispatch_events(%{state | queue: queue}, [event | events])
      {:empty, _queue} -> {:noreply, Enum.reverse(events), state}
    end
  end
end

# Consumer: processes at its own pace
defmodule MyApp.OrderProcessor do
  use GenStage
  def start_link(_), do: GenStage.start_link(__MODULE__, :ok)
  def init(:ok), do: {:consumer, :ok, subscribe_to: [{MyApp.OrderProducer, max_demand: 10}]}

  def handle_events(events, _from, state) do
    Enum.each(events, &process_order/1)
    {:noreply, [], state}
  end
end
```

**Use when:** High-throughput pipelines where consumers are slower than producers. **Broadway** wraps GenStage with a declarative API — prefer it for message queue consumption (Kafka, SQS, RabbitMQ).

### 5. Oban (Persistent Job Queue)

When events must survive restarts, need scheduling, retries, and guaranteed execution:

```elixir
# Enqueue a job — persisted to PostgreSQL
defmodule MyApp.Workers.SendConfirmation do
  use Oban.Worker, queue: :emails, max_attempts: 5

  @impl true
  def perform(%Oban.Job{args: %{"order_id" => order_id}}) do
    order = MyApp.Orders.get_order!(order_id)
    MyApp.Mailer.send_confirmation(order)
    :ok
  end
end

# In your context
def complete_order(order) do
  with {:ok, order} <- mark_completed(order) do
    %{order_id: order.id}
    |> MyApp.Workers.SendConfirmation.new()
    |> Oban.insert()
    {:ok, order}
  end
end
```

**Use when:** Jobs must not be lost (email, webhooks, billing). Need retries with backoff. Need scheduling (run at specific times). Need uniqueness constraints (deduplicate).

### 6. Event Sourcing / Commanded (Full Audit Trail)

When you need complete history, replay, and complex multi-aggregate workflows:

> Full reference: [eventsourcing-reference.md](eventsourcing-reference.md) and [eventsourcing-examples.md](eventsourcing-examples.md)

**Use when:** Perfect audit trail is a business requirement. Complex long-lived processes (insurance claims, loan origination). Undo/replay capabilities needed.

### Communication Decision Guide

| Need | Mechanism | Persistence | Backpressure | Cross-Node |
|------|-----------|-------------|--------------|------------|
| Simple sync call | Direct function | N/A | N/A | No |
| UI updates, notifications | Phoenix.PubSub | No | No | Yes (cluster) |
| Per-entity subscriptions | Registry (`:duplicate`) | No | No | No |
| High-throughput pipeline | GenStage/Broadway | No (in-flight) | **Yes** | No |
| Reliable async jobs | Oban | **Yes** (PostgreSQL) | Yes (queue limits) | **Yes** (shared DB) |
| Full audit + replay | Commanded | **Yes** (event store) | Via subscriptions | **Yes** (shared store) |
| Cross-service messaging | External broker (Kafka, RabbitMQ) + Broadway | **Yes** | **Yes** | **Yes** |

**Escalation path:** Start with direct function calls. When you need decoupling, add PubSub. When producers outpace consumers or data loss is unacceptable, switch to GenStage/Broadway. When events must survive restarts, add Oban. When you need full replay/audit, consider event sourcing. Don't jump to the complex solution first.

**Signals that you've outgrown your current mechanism:**
- PubSub subscriber mailbox growing → need GenStage (backpressure)
- Events lost during deploys/crashes → need Oban (persistence)
- Need to batch writes for performance → need Broadway (batching)
- "What happened and when?" questions → need event sourcing (audit trail)

### API & Contract Evolution

#### Context API Design

```elixir
# GOOD: Options map — easy to extend without breaking callers
defmodule MyApp.Catalog do
  def list_products(opts \\ []) do
    opts
    |> Enum.reduce(Product, fn
      {:category, cat}, query -> where(query, category: ^cat)
      {:min_price, p}, query -> where(query, [p], p.price >= ^p)
      {:sort, field}, query -> order_by(query, ^field)
      {:limit, n}, query -> limit(query, ^n)
      _, query -> query
    end)
    |> Repo.all()
  end
end

# BAD: Positional arguments — adding params breaks all callers
def list_products(category, min_price, sort_field, limit) do ...
```

**Rules for context APIs:**
1. **Use keyword/map opts for queries** — new filters don't break existing callers
2. **Return structs, not raw maps** — structs define a contract; adding a field is backwards-compatible, removing one fails loudly
3. **Use `{:ok, result} | {:error, reason}`** — the shape is the contract, callers pattern match on it
4. **Add functions, don't change signatures** — `get_user/1` stays; add `get_user_with_profile/1` rather than changing the return shape

#### Event Contract Evolution

When contexts communicate via events (PubSub, Oban, Commanded), the event structure becomes a contract:

```elixir
# GOOD: Events are structs with enforced keys — adding fields is safe
defmodule MyApp.Events.OrderCompleted do
  @enforce_keys [:order_id, :customer_id, :total, :completed_at]
  defstruct [:order_id, :customer_id, :total, :completed_at,
             # v2 additions — optional, nil for old events
             :currency, :discount_applied]
end

# Subscribers handle missing fields gracefully
def handle_info({:order_completed, %OrderCompleted{} = event}, state) do
  currency = event.currency || :USD  # Default for events from before v2
  ...
end
```

**Rules for event evolution:**
1. **Add fields, never remove or rename** — existing subscribers pattern match on current shape
2. **New fields must be optional** (default `nil`) — old publishers don't send them
3. **Use structs with `@enforce_keys`** — catches contract violations at compile time for new events
4. **If you must change shape radically** — create a new event type, subscribe to both during transition, retire old one when all publishers upgraded

#### Breaking Changes — When Unavoidable

```elixir
# Deprecation pattern for context APIs
defmodule MyApp.Catalog do
  @deprecated "Use list_products/1 with opts instead"
  def list_products_by_category(category) do
    list_products(category: category)
  end

  def list_products(opts \\ []) do
    # New implementation
  end
end
```

## Supervision as Architecture

### Error Kernel Design

The error kernel is the minimal set of processes that must not fail for the system to function. Everything else is expendable and can crash freely.

```
Application Supervisor (:one_for_one)
├── Telemetry              # Must survive (observability)
├── Repo                   # Must survive (data access)
├── PubSub                 # Must survive (communication)
│
│   ─── ERROR KERNEL BOUNDARY ───
│   Everything above is stable infrastructure.
│   Everything below can crash and restart.
│
├── DomainServices (:rest_for_one supervisor)
│   ├── Cache              # Volatile — rebuilt from DB on restart
│   ├── EventProcessor     # Volatile — replays from last checkpoint
│   └── NotificationQueue  # Volatile — Oban persists pending jobs
├── WorkerManager (:one_for_all supervisor)
│   ├── WorkerRegistry     # Tightly coupled pair
│   └── WorkerSupervisor   # DynamicSupervisor for workers
└── Endpoint               # Web — last (serve only when ready)
```

**Design principles:**
- Critical state (database, PubSub, telemetry) starts first and lives at the top
- Volatile processes (caches, processors, workers) live below — they can crash and recover
- Workers under DynamicSupervisor are fully expendable — each crash is isolated
- Endpoint starts last — don't accept traffic until the system is ready

### Supervision Strategy Semantics

| Strategy | Meaning | Use When |
|----------|---------|----------|
| `:one_for_one` | Only the crashed child restarts | Children are independent (default at top level) |
| `:rest_for_one` | Crashed child + all children started after it restart | Later children depend on earlier ones |
| `:one_for_all` | All children restart when any one crashes | Children are tightly coupled (Registry + DynamicSupervisor) |

**Architectural rules expressed through supervision:**
- **Start order = dependency order** (top to bottom)
- **`:rest_for_one`** = later children depend on earlier ones (cache → processor → notifier)
- **`:one_for_all`** = tightly coupled subsystem (Registry + DynamicSupervisor must be in sync)
- **`:one_for_one`** = independent subsystems at the top level
- **Endpoint last** = don't accept requests until everything is ready

### Critical OTP Process Rules (from SKILL.md)

These rules apply when **implementing** processes — not just when planning the supervision tree. Re-read before writing any GenServer, Task, or process code.

1. **ALWAYS supervise processes.** Never use bare `spawn/spawn_link` for long-running work.
2. **ALWAYS provide a client API** wrapping GenServer calls/casts — callers never use `GenServer.call(pid, ...)` directly.
3. **PREFER call over cast.** Use cast only for fire-and-forget where losing messages is acceptable.
4. **NEVER block GenServer callbacks with I/O, HTTP, or DB queries.** Offload to `Task` or use `handle_continue`. Common trap: blocking `:gen_tcp.accept`/`:gen_tcp.recv` in `handle_info` — use active mode (`:active, true`) or spawn an acceptor Task instead.
5. **ALWAYS use `{:continue, _}` for post-init work** instead of slow/crashing `init/1`.
6. **NEVER store large data (>100KB) in process state.** Use ETS for large/shared data.
7. **ALWAYS use `via` tuples** for dynamic process registration — `{:via, Registry, {MyRegistry, key}}`.
8. **ALWAYS match on specific messages in `handle_info`** — add a catch-all clause that logs unexpected messages.
9. **ALWAYS use `start_supervised!` in tests** for processes — auto-cleanup prevents test pollution.

> Full OTP reference: [otp-reference.md](otp-reference.md) — callback signatures, ETS operations, process debugging, release management

### OTP Applications as Architectural Boundaries

Each OTP application is a deployment unit with its own supervision tree, configuration, and lifecycle. In umbrella/poncho projects, this maps directly to architectural boundaries.

```elixir
defmodule Core.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Core.Repo,
      {Phoenix.PubSub, name: Core.PubSub},
      Core.Accounts.SessionCleanup,
      Core.Catalog.SearchIndex
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: Core.Supervisor)
  end
end
```

**Each application controls:**
- Which processes start and in what order
- Restart strategy for its subsystems
- Configuration namespace (`Application.get_env(:core, ...)`)
- What it exposes to other applications (public modules)

### Process Architecture Patterns

#### Process-Per-Service (Most Common)

One long-lived process per service. Processes represent capabilities, not entities:

```elixir
children = [
  MyApp.Repo,           # One DB connection pool
  MyApp.Cache,          # One cache service
  MyApp.Mailer,         # One email sender
  MyApp.RateLimiter     # One rate limiting service
]
```

**Use when:** Service has shared state (connection pool, cache, counters). Most applications.

#### Process-Per-Entity (When Needed)

One process per domain entity. Each instance manages its own state:

```elixir
# Game server — one process per active game
DynamicSupervisor.start_child(GameSupervisor, {GameServer, game_id: id})

# IoT device — one process per connected device
DynamicSupervisor.start_child(DeviceSupervisor, {DeviceHandler, device_id: id})
```

**Use when:** Entities have independent state, need isolated failure domains, or communicate asynchronously. Watch for: memory use scales linearly with entity count.

#### Hybrid: Service + Entity Pool

Service process manages the lifecycle, DynamicSupervisor manages instances:

```elixir
defmodule MyApp.GameManager do
  def start_game(params) do
    game_id = generate_id()
    {:ok, _pid} = DynamicSupervisor.start_child(
      MyApp.GameSupervisor,
      {MyApp.GameServer, {game_id, params}}
    )
    {:ok, game_id}
  end

  def find_game(game_id) do
    MyApp.GameRegistry.lookup(game_id)
  end
end
```

### Stateful vs Stateless Process Design

A key architectural decision: should a process hold state in memory, or reconstruct it from a data store on each call?

| Approach | Trade-off | Use When |
|----------|-----------|----------|
| **Stateful** (state in process memory) | Fast reads, state lost on crash | Real-time data, caches, active sessions, hardware connections |
| **Stateless** (reconstruct from DB/store) | Slower reads, crash-resilient | CRUD operations, request handlers, most web contexts |
| **Hybrid** (process state + periodic persistence) | Best of both, more complex | Game state, long-running workflows, IoT device state |

**The decision rule:** Hold state in a process only when you need it — for performance (avoid repeated DB hits), for real-time responsiveness (sub-millisecond access), or because the state has no durable store (hardware connections, active WebSocket sessions, in-flight computations).

```elixir
# STATELESS: No process needed — context functions hit the DB each time
# Good for: CRUD, low-frequency reads, data that changes from many sources
defmodule MyApp.Accounts do
  def get_user(id), do: Repo.get(User, id)
  def update_user(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end
end

# STATEFUL: GenServer holds state — fast reads, single writer
# Good for: real-time counters, active sessions, device connections
defmodule MyApp.DeviceConnection do
  use GenServer

  def get_status(device_id), do: GenServer.call(via(device_id), :status)

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info({:sensor_data, data}, state) do
    new_state = %{state | last_reading: data, status: :active}
    {:noreply, new_state}
  end
end

# HYBRID: Process state + periodic DB sync
# Good for: game state, long workflows, data too expensive to lose
defmodule MyApp.GameServer do
  use GenServer

  @persist_interval :timer.seconds(30)

  @impl true
  def init(game_id) do
    state = Games.load_state(game_id)  # Reconstruct from DB
    Process.send_after(self(), :persist, @persist_interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:persist, state) do
    Games.save_state(state)  # Periodic persistence
    Process.send_after(self(), :persist, @persist_interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Games.save_state(state)  # Save on shutdown
  end
end
```

**Architectural rules:**
1. **Default to stateless** — most contexts don't need a process, just functions + a data store
2. **Don't create GenServers for single-caller request/response** — that's just adding a bottleneck (serialised mailbox) for no benefit
3. **Stateful processes need a recovery strategy** — what happens on crash? Reconstruct from DB? Accept empty state? Fetch from peer?
4. **State ≠ cache** — if you're holding DB data in a GenServer just to avoid queries, use ETS or `:persistent_term` instead

### Anti-Pattern: Simulating Objects with Processes

A common mistake — especially from developers coming from OO languages — is using one Agent or GenServer per domain concept: an Agent for the shopping cart, an Agent for the inventory, an Agent for the order. This simulates objects with processes and brings only downsides:

- **Process overhead** — each process costs memory (~2.6KB) and communication overhead (message copying)
- **Forced synchronization** — concepts that are naturally sequential now require cross-process messaging to coordinate
- **Complex cleanup** — crash of one "object process" requires terminating all related ones
- **No benefit** — if the concepts are used together in a single flow, they share the same runtime concerns and gain nothing from isolation

```elixir
# BAD: One Agent per domain concept — simulating objects with processes
cart_agent = Agent.start_link(fn -> Cart.new() end)
inventory_agent = Agent.start_link(fn -> Inventory.new(products) end)
# Now every operation requires cross-process messaging to coordinate
Agent.update(cart_agent, fn cart ->
  item = Agent.get(inventory_agent, fn inv -> Inventory.take(inv, sku) end)
  Cart.add(cart, item)
end)

# GOOD: Pure functional abstractions — modules and functions, no processes
cart = Cart.new()
{:ok, item, inventory} = Inventory.take(inventory, sku)
cart = Cart.add(cart, item)
# Simple, testable, no overhead. Wrap in ONE GenServer only if needed for runtime concerns.
```

**The rule:** Use functions and modules to separate *thought concerns* (domain concepts that exist in your mental model). Use processes to separate *runtime concerns* (fault isolation, parallelism, independent lifecycles). If multiple concepts always change together in the same flow, they belong in the same process.

**Decision test:** Ask "do these things need to fail independently? run in parallel? have different lifecycles?" If not, they belong together in one process (or no process at all), separated by modules and functions.

### The Instructions Pattern — Separating Domain from Side Effects

When domain logic needs to trigger side effects (notifications, messages, I/O), don't perform them inline. Instead, have pure domain functions return a list of **instructions** — data describing what should happen — and let the caller (GenServer, controller, test) interpret them.

```elixir
# Pure domain module — no side effects, no process mechanics
defmodule MyApp.Workflow do
  @opaque t :: %__MODULE__{}
  defstruct [:state, :participants, instructions: []]

  @spec advance(t(), participant_id(), action()) :: {[instruction()], t()}
  def advance(workflow, participant_id, action) do
    workflow
    |> validate_participant(participant_id)
    |> apply_action(action)
    |> maybe_transition()
    |> emit_instructions()
  end

  # Returns instructions like:
  # [
  #   {:notify, participant_id, {:status_changed, :approved}},
  #   {:notify, reviewer_id, {:task_assigned, task}},
  #   {:schedule, {:deadline, task_id}, :timer.hours(24)}
  # ]

  defp emit_instructions(%{instructions: instructions} = workflow) do
    {Enum.reverse(instructions), %{workflow | instructions: []}}
  end

  # Internal helpers push instructions without performing them
  defp notify(workflow, participant, event) do
    %{workflow | instructions: [{:notify, participant, event} | workflow.instructions]}
  end

  defp schedule(workflow, event, delay) do
    %{workflow | instructions: [{:schedule, event, delay} | workflow.instructions]}
  end
end
```

The GenServer interprets the instructions — this is where side effects happen:

```elixir
defmodule MyApp.WorkflowServer do
  use GenServer

  @impl true
  def handle_call({:advance, participant_id, action}, _from, state) do
    {instructions, workflow} = MyApp.Workflow.advance(state.workflow, participant_id, action)
    new_state = %{state | workflow: workflow}
    execute_instructions(instructions, state)
    {:reply, :ok, new_state}
  end

  defp execute_instructions(instructions, state) do
    Enum.each(instructions, fn
      {:notify, participant_id, event} ->
        # Send to the participant's notifier process
        MyApp.Notifier.send(state.notifiers[participant_id], event)

      {:schedule, event, delay} ->
        Process.send_after(self(), {:scheduled, event}, delay)
    end)
  end
end
```

**Benefits:**
- **Domain logic is pure and trivially testable** — assert on returned instructions, no mocking needed
- **Multiple drivers** — same domain module can be driven by a GenServer, a LiveView, a test, or an IEx session
- **Temporal concerns stay out of domain** — retries, timeouts, delivery guarantees are the server's problem
- **Domain can evolve independently** — adding new business rules doesn't touch notification/persistence code

```elixir
# Testing is dead simple — no processes, no mocking
test "advancing workflow notifies next participant" do
  workflow = Workflow.new([:alice, :bob])
  {instructions, _workflow} = Workflow.advance(workflow, :alice, :approve)

  assert {:notify, :bob, {:task_assigned, _}} = List.last(instructions)
end
```

### Callback Module Pattern — Pluggable GenServer Behaviour

When a GenServer needs to interact with different types of clients (HTTP, WebSocket, TCP, test harness), define a behaviour for the client-facing callbacks. The server invokes callback functions without knowing the transport:

```elixir
defmodule MyApp.SessionServer do
  @callback on_event(callback_arg :: any(), participant_id(), event()) :: any()
  @callback on_complete(callback_arg :: any(), participant_id(), result()) :: any()

  use GenServer

  def start_link(session_id, participants) do
    # Each participant: %{id: id, callback_mod: module, callback_arg: any}
    GenServer.start_link(__MODULE__, {session_id, participants}, name: via(session_id))
  end

  @impl true
  def handle_call({:action, participant_id, action}, _from, state) do
    {instructions, domain} = MyDomain.process(state.domain, participant_id, action)
    new_state = %{state | domain: domain}
    dispatch(instructions, state.participants)
    {:reply, :ok, new_state}
  end

  defp dispatch(instructions, participants) do
    Enum.each(instructions, fn {:notify, participant_id, event} ->
      %{callback_mod: mod, callback_arg: arg} = Map.fetch!(participants, participant_id)
      mod.on_event(arg, participant_id, event)
    end)
  end
end
```

Now different transports implement the same behaviour:

```elixir
# Phoenix Channel transport
defmodule MyApp.ChannelNotifier do
  @behaviour MyApp.SessionServer

  @impl true
  def on_event(socket_pid, participant_id, event) do
    send(socket_pid, {:push_event, participant_id, event})
  end

  @impl true
  def on_complete(socket_pid, _participant_id, result) do
    send(socket_pid, {:session_complete, result})
  end
end

# Test transport — sends messages to test process
defmodule MyApp.TestNotifier do
  @behaviour MyApp.SessionServer

  @impl true
  def on_event(test_pid, participant_id, event) do
    send(test_pid, {:event, participant_id, event})
  end

  @impl true
  def on_complete(test_pid, _participant_id, result) do
    send(test_pid, {:complete, result})
  end
end
```

**When to use:** Any GenServer that needs to push information to external clients over potentially different transports. The callback module pattern keeps the server transport-agnostic, testable without network, and extensible without modification.

## Resilience Patterns

OTP provides resilience primitives that other ecosystems need external libraries for. These patterns are architectural — they determine where failure handling lives and how subsystems degrade.

### BEAM Processes as Bulkheads

Every BEAM process is an isolated failure domain — its own heap, its own garbage collection, its own crash boundary. This IS the bulkhead pattern. When one process crashes, others are unaffected.

```elixir
# Each context's workers are isolated failure domains
children = [
  # If email sending fails, order processing continues
  {MyApp.Mailer.Pool, pool_size: 5},
  # If payment gateway is slow, catalog browsing is unaffected
  {MyApp.PaymentWorker, []},
  # If search indexing crashes, CRUD operations work fine
  {MyApp.SearchIndexer, []}
]
```

**Architectural rule:** Different concerns should run in different processes. This gives you bulkhead isolation for free. Never run unrelated work in the same GenServer — split it.

### Circuit Breaker

Prevent cascading failures by stopping calls to a failing subsystem. In Elixir, implement with a GenServer or use the `:fuse` library:

```elixir
# Architectural placement: circuit breaker wraps infrastructure adapters
defmodule MyApp.PaymentGateway.Protected do
  @behaviour MyApp.PaymentGateway

  @impl true
  def charge(amount, token) do
    case :fuse.ask(:payment_fuse, :sync) do
      :ok ->
        case MyApp.PaymentGateway.Stripe.charge(amount, token) do
          {:ok, _} = success -> success
          {:error, :timeout} -> :fuse.melt(:payment_fuse); {:error, :service_unavailable}
          {:error, _} = error -> error
        end
      :blown ->
        {:error, :service_unavailable}
    end
  end
end

# Supervision — fuse must start before the service that uses it
children = [
  {Fuse, name: :payment_fuse, strategy: {:standard, 5, 60_000}},  # 5 failures in 60s
  MyApp.PaymentWorker
]
```

**Where circuit breakers belong:** Around infrastructure adapters (HTTP clients, external APIs, database calls to remote services). NEVER in domain logic. The domain gets `{:error, :service_unavailable}` and decides what to do (queue for retry, show cached data, return partial result).

### Retry and Backoff

Retries belong in infrastructure, never in domain logic. Different layers handle retries differently:

| Layer | Retry Mechanism | Example |
|-------|----------------|---------|
| HTTP client | Built-in retry | `Req.new(retry: :transient, max_retries: 3)` |
| Background jobs | Job-level retry | `use Oban.Worker, max_attempts: 5` |
| Event handlers | Handler-level retry | Commanded error callback with backoff |
| GenServer | Process restart | Supervisor with `max_restarts` / `max_seconds` |
| Infrastructure adapter | Wrapper with backoff | Custom retry around external call |

**Idempotency is a prerequisite for safe retries.** If an operation isn't idempotent, retrying it may cause duplicate effects. See Data Ownership section below.

### Graceful Degradation

When a subsystem is down, serve degraded functionality instead of failing entirely:

```elixir
defmodule MyApp.Catalog do
  def get_product_with_recommendations(product_id) do
    product = get_product!(product_id)

    # Recommendations are nice-to-have — degrade gracefully if service is down
    recommendations =
      case MyApp.Recommendations.for_product(product_id) do
        {:ok, recs} -> recs
        {:error, _} -> []  # Show product without recommendations
      end

    {product, recommendations}
  end
end
```

**Architectural rule:** Identify which features are critical (must work) vs nice-to-have (can degrade). Critical paths use synchronous calls with clear error handling. Nice-to-have features use `try`-style fallbacks or cached data.

### Timeout Architecture

Timeouts must be set at every boundary and cascade correctly — outer timeouts must be longer than inner timeouts:

```elixir
# Inner: HTTP client timeout (shortest)
client = Req.new(receive_timeout: 5_000)

# Middle: GenServer call timeout
GenServer.call(PaymentService, {:charge, order}, 10_000)

# Outer: Request timeout (longest)
# Phoenix endpoint: timeout: 15_000

# Rule: outer > middle > inner, or you get confusing timeout errors
# 15_000 > 10_000 > 5_000 ✓
```

**Where to set timeouts:**
- HTTP clients: `receive_timeout` in Req/Finch
- GenServer calls: second argument to `GenServer.call/3` (default 5000ms)
- Task.await: second argument (default 5000ms)
- Database queries: `:timeout` option in Repo operations
- Phoenix endpoint: `:timeout` in endpoint config

## Pipeline Architecture

Elixir excels at pipeline patterns — sequential transformation of data through stages.

| Pipeline Type | Pattern | Use When |
|--------------|---------|----------|
| **Plug** | Synchronous, each plug transforms `%Conn{}`, `halt/1` short-circuits | Request/response processing (HTTP, API) |
| **GenStage** | Demand-driven, producers/consumers at different speeds | High-throughput data processing with backpressure |
| **Broadway** | Declarative GenStage with batching and fault tolerance | Message queue consumption (Kafka, SQS, RabbitMQ) |
| **Absinthe Phases** | Branching phases with skip/insert/replace control | Multi-stage document/AST transformations |
| **`|>` pipeline** | Pure function composition | Data transformation in domain logic |

**Broadway example** (declarative GenStage for message queues):

```elixir
defmodule MyApp.Pipeline do
  use Broadway

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [module: {BroadwayKafka.Producer, hosts: [...], topics: ["events"]}],
      processors: [default: [concurrency: 10]],
      batchers: [default: [batch_size: 100, batch_timeout: 1000, concurrency: 5]]
    )
  end

  @impl true
  def handle_message(_processor, message, _context) do
    Message.update_data(message, &process_event/1)
  end

  @impl true
  def handle_batch(_batcher, messages, _batch_info, _context) do
    Enum.map(messages, & &1.data) |> MyApp.Repo.insert_all(Event)
    messages
  end
end
```

### Hex Packages as Architectural Units

When code matures beyond a single project, extract to Hex packages:

```elixir
# Private Hex org for company libraries
defp deps do
  [
    {:core_auth, "~> 1.0", organization: "my_company"},
    {:shared_schemas, "~> 2.0", organization: "my_company"}
  ]
end

# Path dep during development, Hex in production
{:my_lib, path: "../my_lib"}   # Development
{:my_lib, "~> 1.0"}           # Production (published to Hex)
```

**Progression:** Context module → Umbrella app → Poncho app → Hex package. Each step increases independence and formality of the API boundary.

## Production Patterns

> Production Phoenix patterns (changelog.com), Edge/IoT patterns (ExNVR), and Job Processing patterns (Oban) are in [production.md](production.md).
>
> **OTP supporting files:** Quick-reference tables in [otp-reference.md](otp-reference.md). Complete working examples (rate limiter, connection state machine, worker pool, cache, circuit breaker, pub/sub, task pipeline, telemetry, distributed counter, graceful shutdown) in [otp-examples.md](otp-examples.md). GenStage, Flow, Broadway, hot code upgrades, and production debugging in [otp-advanced.md](otp-advanced.md).

### Telemetry & HTTP Clients

> **Telemetry:** `:telemetry` is the standard instrumentation library. Emit events with `:telemetry.execute/3`, instrument blocks with `:telemetry.span/3`, define metrics with `Telemetry.Metrics`. Full API reference, built-in events table, and slow query logger example in [production.md](production.md).
>
> **HTTP Clients:** Req is the default (auto-JSON, retries, streaming). Finch for low-level control. Testing with Req.Test or Mox + behaviour. Full reference and examples in [production.md](production.md).

**Architectural placement:** Telemetry emission belongs in infrastructure and boundary modules — observe without coupling. HTTP clients belong behind behaviours in the infrastructure layer — the domain never calls Req directly.

### Caching Architecture

Different caching mechanisms for different access patterns:

| Mechanism | Use When | Properties |
|-----------|----------|------------|
| **ETS** | Hot-path reads, per-node | Shared across processes, in-memory, lost on restart |
| **`:persistent_term`** | Rarely-changing lookup data | Global reads (zero-copy), expensive writes, survives GC |
| **Cachex / ConCache** | ETS + TTL + eviction | Wraps ETS with expiry, size limits, stats |
| **External (Redis)** | Shared across nodes | Survives restarts, network overhead per access |
| **Process state** | Single-consumer cache | Private to one process, simple, GC pressure if large |

**Key implementation notes:**
- ETS: create in GenServer `init/1` with `read_concurrency: true`, reads bypass the GenServer
- `:persistent_term`: zero-copy reads, but writes trigger global GC — only for rarely-changing data
- WARNING: `:persistent_term.put/2` in a loop will crash the VM

**Cache invalidation strategies:**

| Strategy | How | Use When |
|----------|-----|----------|
| **TTL** | Expire after N seconds | Acceptable staleness window exists |
| **Write-through** | Update cache on every write | Strong consistency needed, write rate is moderate |
| **Event-driven** | PubSub invalidates on change | Multiple caches, decoupled invalidation |
| **Rebuild on restart** | Cache is empty on boot, fills lazily | Cache is optimization, not requirement |

### NIF Architecture (Rust/C/Zig)

NIFs (Native Implemented Functions) run native code inside the BEAM VM. This creates architectural concerns that don't exist with pure Elixir:

**The core risk:** A NIF crash (segfault) kills the **entire VM** — not just one process. Unlike Elixir processes, NIFs bypass OTP fault tolerance. This demands careful boundary design.

#### Architectural Rules

1. **Minimize the NIF surface** — move as much logic as possible to Elixir. The NIF should do only what Elixir cannot: CPU-intensive computation, hardware access, existing C/Rust library bindings
2. **Keep the NIF boundary thin** — convert to/from Elixir types at the edge. Don't pass complex nested structures across the boundary
3. **Use dirty schedulers for long operations** — NIFs that take >1ms block a scheduler. Use `dirty_cpu` for computation, `dirty_io` for I/O
4. **Wrap NIFs in a supervised GenServer** — the GenServer owns the NIF resource lifecycle, provides a clean API, and can handle reinitialisation if something goes wrong
5. **Use Rustler resources for state** — `ResourceArc<T>` gives the BEAM a safe handle to native state with proper cleanup via `Drop`

#### NIF Boundary Design

```elixir
# BAD: Exposing NIF directly to callers
defmodule MyApp.ImageProcessor do
  use Rustler, otp_app: :my_app, crate: "image_processor"
  def resize(_binary, _width, _height), do: :erlang.nif_error(:not_loaded)
end

# GOOD: NIF behind a context with behaviour
defmodule MyApp.Media do
  @moduledoc "Public API — callers never know about NIFs"
  alias MyApp.Media.ImageProcessor

  def resize_image(binary, width, height) do
    ImageProcessor.resize(binary, width, height)
  end
end

defmodule MyApp.Media.ImageProcessor do
  @moduledoc false
  use Rustler, otp_app: :my_app, crate: "image_processor"

  # NIF functions — thin boundary, simple types in/out
  def resize(_binary, _width, _height), do: :erlang.nif_error(:not_loaded)
end
```

#### Decision Guide

| Consideration | Approach |
|--------------|----------|
| CPU work <1ms | Regular NIF (normal scheduler) |
| CPU work >1ms | `#[rustler::nif(schedule = "DirtyCpu")]` |
| Blocking I/O | `#[rustler::nif(schedule = "DirtyIo")]` or use Port instead |
| Long-lived native state | Rustler `ResourceArc<Mutex<T>>` + GenServer owner |
| Fallible native code (C libraries) | Consider Port (separate OS process) instead of NIF — crashes won't kill VM |
| Need maximum safety | Rustler (Rust) — memory safety, no segfaults from Rust code |
| Need existing C library | Zigler (Zig) or Rustler with `unsafe` FFI — wrap carefully |

> Full NIF implementation patterns: rust-nif skill

## Security Architecture

Security is an architectural concern — decisions about where to validate, authorize, and handle secrets affect the entire system structure.

### Input Validation Boundaries

**Validate at system edges. Trust internal data.** External input (HTTP params, webhooks, file uploads, UART data, MQTT messages) is untrusted. Once validated and converted to domain types at the boundary, internal code trusts the data.

```elixir
# === System edge: validate and convert ===
# Controller / LiveView / API endpoint
def create(conn, %{"user" => params}) do
  # Ecto changeset validates at the boundary
  case Accounts.register_user(params) do
    {:ok, user} -> ...
    {:error, changeset} -> ...  # Validation errors returned to caller
  end
end

# Context: changeset validates structure and business rules
def register_user(attrs) do
  %User{}
  |> User.registration_changeset(attrs)  # Validates email format, password strength
  |> Repo.insert()
end

# === Internal code: trusts validated data ===
# No re-validation of email format deep inside domain logic
defp send_welcome(%User{email: email} = user) do
  # email is already validated — just use it
  Mailer.deliver(email, welcome_template(user))
end
```

**NEVER:** `String.to_atom(user_input)` — atom table exhaustion. Use `String.to_existing_atom/1` or explicit mapping.

### Authorization Architecture

Authorization checks belong in the domain layer (contexts), not in the interface layer:

```elixir
# BAD: Authorization in controller — bypassed if called from LiveView or CLI
def delete(conn, %{"id" => id}) do
  if conn.assigns.current_user.role == :admin do
    Catalog.delete_product!(id)
  end
end

# GOOD: Authorization in context — enforced regardless of interface
defmodule MyApp.Catalog do
  def delete_product(product_id, %User{} = actor) do
    product = Repo.get!(Product, product_id)

    if authorized?(actor, :delete, product) do
      Repo.delete(product)
    else
      {:error, :unauthorized}
    end
  end

  defp authorized?(%User{role: :admin}, :delete, _product), do: true
  defp authorized?(%User{id: id}, :delete, %{owner_id: id}), do: true
  defp authorized?(_, _, _), do: false
end
```

**For complex authorization:** Use Bodyguard (lightweight policy modules) or Ash Framework's built-in policy system. Define policies as separate modules implementing a behaviour — keeps authorization logic testable and separate from business logic.

### Secrets Management

```elixir
# Secrets flow: Environment → runtime.exs → Application env → Module attribute
# NEVER hard-code secrets, NEVER commit secrets, NEVER log secrets

# config/runtime.exs (loaded at boot, not compiled into release)
config :my_app, MyApp.PaymentGateway.Stripe,
  api_key: System.fetch_env!("STRIPE_API_KEY")

# Module reads at runtime
defmodule MyApp.PaymentGateway.Stripe do
  defp api_key, do: Application.fetch_env!(:my_app, __MODULE__)[:api_key]
end
```

**Rules:**
- ALL secrets in `runtime.exs` via `System.fetch_env!/1` — never in compile-time config
- Never log request/response bodies that may contain tokens
- Rotate credentials without redeployment (runtime.exs + restart)

## Observability Architecture

Observability has three pillars — metrics, logs, and traces. Each serves a different purpose and maps to different Elixir tools.

### The Three Pillars

| Pillar | Purpose | Elixir Tool | Answers |
|--------|---------|-------------|---------|
| **Metrics** | Aggregate numerical measurements | `:telemetry` + `Telemetry.Metrics` | "How fast? How many? How much?" |
| **Logs** | Discrete events with context | `Logger` with metadata | "What happened? Why did it fail?" |
| **Traces** | Request flow across components | `OpenTelemetry` | "Where did time go? What called what?" |

### Structured Logging

**Rules:**
- Set `Logger.metadata(order_id: id, ...)` at boundary entry points — flows through all nested calls in that process
- Use structured fields: `Logger.info("Processed", count: n)` not `Logger.info("Processed #{n} items")`
- Use `LoggerJSON.Formatters.Basic` in production for parseable output
- Log at boundaries: incoming requests, outgoing calls, state transitions, errors
- NEVER log secrets, tokens, passwords, or full request bodies

### Distributed Tracing

Use OpenTelemetry when requests flow through multiple contexts or services and you need to understand latency breakdown. For single-context operations, telemetry metrics are sufficient.

- Auto-instrumentation: `OpentelemetryPhoenix.setup()` + `OpentelemetryEcto.setup/1` in `application.ex`
- Manual spans: `Tracer.with_span "name" do ... end` for custom operations
- Deps: `{:opentelemetry, "~> 1.4"}`, `{:opentelemetry_phoenix, "~> 1.2"}`

> Full telemetry and tracing examples: [production.md](production.md)

## Production Architecture Decision Tree

When planning a new Elixir project or making structural decisions, work through these in order. **Priorities: robustness first, then replaceability, then simplicity.**

### 1. Domain Boundaries (First Decision)

```
What business domains does this system handle?
├── Single domain → Single context (e.g., MyApp.Billing)
├── 2-5 related domains → Multiple contexts in one Mix app
├── 5+ domains with team boundaries → Consider umbrella/poncho
└── Unsure → Start with one context, split when pain emerges
```

**Key principle:** Contexts are cheap to split later but expensive to merge. Start broader, narrow down.

### 2. Data Persistence Strategy

```
What data patterns does each domain need?
├── Standard CRUD → Ecto schemas + context functions + Repo
├── Event history / audit trail → Event sourcing (Commanded)
├── Complex state transitions → gen_statem + Ecto for persistence
├── High-read, low-write → ETS cache + Ecto for durability
├── Real-time ephemeral state → GenServer / process state only
└── Multiple patterns → Different strategies per context (mix freely)
```

### 3. Process Architecture

```
Does this feature need its own process?
├── No shared mutable state → Pure functions (NO process needed)
├── Shared state, moderate access → GenServer
├── Shared state, high reads → ETS (:read_concurrency)
├── Per-entity isolation → DynamicSupervisor + Registry
├── Explicit state transitions → gen_statem
├── Background / scheduled work → Oban job
├── Data pipeline with backpressure → Broadway / GenStage
└── One-off parallel work → Task.async_stream
```

**Key principle:** Start without processes. Add a GenServer only when you need serialized access to shared mutable state. Most business logic belongs in pure functions called by contexts.

### 4. Integration Boundaries

```
How does this component talk to external systems?
├── External API (Stripe, S3, etc.) → Behaviour + impl module + Mox in test
├── Internal service (another context) → Context public API (function calls)
├── Cross-context events → PubSub / Oban / GenStage (see Communication Guide above)
├── Cross-node communication → :erpc or distributed PubSub
└── Hardware / native code → NIF behind behaviour (for testability)
```

**Key principle:** Every external dependency should be behind a behaviour. This enables testing with Mox, swapping implementations, and isolating failure domains.

### 5. Supervision Strategy

```
How should processes recover from failures?
├── Independent services → :one_for_one (most common at top level)
├── Ordered dependencies (cache → processor → notifier) → :rest_for_one
├── Tightly coupled (Registry + DynamicSupervisor) → :one_for_all
├── External-facing endpoint (web, API, MQTT) → Always last child
└── Database pools, PubSub, Telemetry → Always first children
```

### Refactoring Decision Tree

Use when an existing codebase needs structural changes. **Priorities: preserve behaviour, improve boundaries, increase testability.**

| Signal | Refactoring | How |
|--------|------------|-----|
| Context module >500 lines | Split context | Extract related functions into a new context with its own schemas |
| Boundary module calls Repo directly | Introduce context | Move queries behind context functions |
| Business logic in GenServer callbacks | Extract pure functions | Create a domain module, call it from the callback |
| Hard-coded external service call | Introduce behaviour | Define callback, create impl module, configure via `compile_env` |
| Multiple `case` branches on same field | Extract to gen_statem | If transitions form a graph, use explicit state machine |
| Same query pattern repeated 3+ times | Composable query module | Create `MyApp.SomeContext.Queries` with chainable functions |
| Test requires complex setup of many modules | Missing boundaries | Introduce behaviour + Mox for isolation |
| Context A calls Context B calls Context A | Circular dependency | Extract shared logic into a third context, or merge |
| Single app with >20 contexts | Umbrella candidate | Group by deployment/team boundary into umbrella apps |
| GenServer bottleneck (message queue growing) | Partition or ETS | Use PartitionSupervisor or move hot reads to ETS |
| Multiple Repo.insert/update without transaction | Introduce Ecto.Multi | Wrap related operations in `Multi` + `Repo.transact` |
| Process state >100KB | Move to ETS | Large state causes GC pressure; ETS is off-heap |
| PubSub events being lost | Oban or Commanded | Need persistence? Use a persistent job queue or event store |
| Subscriber overwhelmed by events | GenStage or Broadway | Need backpressure? Move from PubSub to demand-driven pipeline |

### Component Reuse Patterns

| Pattern | When | Example |
|---------|------|---------|
| **Behaviour + default impl** | Swappable strategy | Payment gateway, notification channel, storage backend |
| **Context with behaviour boundary** | Reusable domain logic | Auth context with configurable token store |
| **Protocol + implementations** | Polymorphic data handling | Export formats, serialization, display rendering |
| **`use` macro with options** | Configurable scaffolding | Schema base module, test case templates |
| **Plug pipeline** | Composable request processing | Auth plugs, rate limiting, logging |
| **Telemetry events** | Observable components | Emit events, let consumers decide what to measure |
| **PubSub topics** | Decoupled communication | Publisher doesn't know subscribers exist |

## Growing Architecture — Small to Large

### Stage 1: Small App (1-3 domains, 1 developer)

Start with the simplest structure that enforces boundaries:

```elixir
# One application, one or a few boundary modules, pure functions
defmodule MyApp.Application do
  use Application
  def start(_type, _args) do
    children = [MyApp.Repo]  # Or no Repo if no database
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule MyApp.Core do
  # Single boundary module — all public API here
  # Internal modules in MyApp.Core.* with @moduledoc false
end
```

**What matters at this stage:**
- Domain logic in pure functions (testable, no process overhead)
- External dependencies behind behaviours (even just one: the database)
- One supervision tree with flat `:one_for_one`
- No PubSub, no GenStage, no event sourcing — add complexity only when needed

### Stage 2: Medium App (3-8 domains, small team)

Split into multiple boundary modules. Add processes only where needed:

```elixir
defmodule MyApp.Application do
  use Application
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},  # If Phoenix, or {:pg, :my_pubsub}
      MyApp.Cache,                             # First GenServer — shared state
      MyAppWeb.Endpoint                        # If web app
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

# Multiple boundary modules, each owning its internals
defmodule MyApp.Accounts do ... end
defmodule MyApp.Catalog do ... end
defmodule MyApp.Billing do ... end
```

**What changes:**
- Multiple boundary modules with clear ownership
- PubSub for cross-boundary events (UI updates, notifications)
- First GenServers appear for genuinely shared mutable state
- Behaviours at external service boundaries (payment, email)
- Still one Mix application — contexts provide sufficient boundaries

### Stage 3: Large App (8+ domains, multiple teams)

Introduce supervision hierarchy, consider umbrella for team boundaries:

```elixir
defmodule MyApp.Application do
  use Application
  def start(_type, _args) do
    children = [
      # Infrastructure (error kernel — must not fail)
      MyApp.Telemetry,
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},

      # Domain services (can crash and recover)
      {Supervisor, name: MyApp.DomainSupervisor, strategy: :rest_for_one,
        children: [
          MyApp.Cache,
          MyApp.EventProcessor,
          MyApp.NotificationService
        ]},

      # Dynamic workers
      {Supervisor, name: MyApp.WorkerSupervisor, strategy: :one_for_all,
        children: [
          {Registry, keys: :unique, name: MyApp.WorkerRegistry},
          {DynamicSupervisor, name: MyApp.Workers, max_children: 10_000}
        ]},

      # Interface (last — serve only when ready)
      MyAppWeb.Endpoint
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

**What changes:**
- Nested supervision tree with error kernel design
- Oban for persistent background jobs
- GenStage/Broadway for high-throughput pipelines
- Telemetry instrumentation throughout
- Consider umbrella if teams need hard compile-time boundaries
- Event sourcing for domains that need audit trails

### What DOESN'T Change Between Stages

These principles hold at every scale:

- Domain logic is pure functions — this never changes
- External dependencies are behind behaviours — this never changes
- Boundary modules are the only public API — this never changes
- `{:ok, _}` / `{:error, _}` tuples for results — this never changes
- Supervision tree expresses architecture — this never changes

**The progression is additive.** Add GenServers, PubSub, supervision layers as needed. Never restructure the fundamentals.

## Distributed Architecture

When your application runs on multiple nodes (clustered Phoenix, distributed Nerves fleet, multi-region deployment), several architectural assumptions change.

### What Changes in Distribution

| Single-Node Assumption | Distributed Reality |
|----------------------|---------------------|
| Function calls always succeed | Network calls can fail, timeout, or partition |
| Process state is always available | Process may be on another node |
| PubSub is instant and reliable | Messages can be delayed, duplicated, or lost |
| ETS is shared across the app | ETS is local to each node |
| Registry finds processes instantly | Need distributed registry (:global, Horde, Syn) |
| One supervision tree | One tree per node, coordination across trees |

### Distributed Communication Patterns

```elixir
# === :erpc — synchronous call to remote node (OTP 23+) ===
# Preferred over :rpc for better error handling
case :erpc.call(:"worker@host", MyApp.Heavy, :compute, [data], 30_000) do
  result -> {:ok, result}
rescue
  # :erpc raises on timeout, node down, etc.
  e -> {:error, e}
end

# === :pg — distributed process groups (OTP 23+) ===
# Automatically propagates across connected nodes
:pg.join(:my_scope, :workers, self())
:pg.get_members(:my_scope, :workers)  # Returns pids from ALL nodes

# === Phoenix.PubSub — distributed by default in a cluster ===
# Uses :pg under the hood for cross-node broadcast
Phoenix.PubSub.broadcast(MyApp.PubSub, "events", {:update, data})
# All subscribers on ALL connected nodes receive this

# === Distributed Registry options ===
# Horde — CRDT-based, eventually consistent
{Horde.Registry, name: MyApp.DistRegistry, keys: :unique}
# Syn — global registry with metadata
# :global — built-in, uses global lock (not for high frequency)
```

### Architectural Decisions for Distribution

**State ownership — who holds the truth?**

```
Where does authoritative state live?
├── Database (PostgreSQL, EventStore) → Safest, use for persistent state
├── Single designated node → Use :global or Horde to register owner
├── Replicated across nodes → CRDTs (Horde, DeltaCrdt) for convergence
├── Local to each node → ETS cache, eventually consistent is OK
└── No shared state needed → Stateless workers, load balance freely
```

**When you must partition:**

- **Consistent hashing** — route entities to specific nodes by key (e.g., game_id mod N)
- **Leader election** — one node coordinates, others follow (use `:global` registration)
- **CRDTs** — each node modifies independently, state converges automatically (Horde, DeltaCrdt)

### What NOT to Distribute

Most Elixir apps don't need distribution. Before going multi-node, exhaust single-node options:

| Problem | Single-Node Solution | Distribute Only When |
|---------|---------------------|---------------------|
| More throughput | `Task.async_stream`, `Flow`, more cores | Single machine maxed out |
| High availability | Supervisor restarts, health checks | Need zero-downtime deploys |
| Data locality | ETS caching, read replicas | Data must be near users geographically |
| Background jobs | Oban (shares PostgreSQL) | Need to spread CPU-heavy work |
| WebSocket scale | Single node handles ~1M connections | More connections than one machine |

**Default to single node.** Distribution adds network partitions, split-brain, and eventual consistency. Avoid until genuinely needed.

### Distribution Anti-Patterns

```elixir
# BAD: Assuming remote calls always succeed
result = GenServer.call({MyServer, :"remote@host"}, :work)

# GOOD: Handle node-down and timeout
try do
  GenServer.call({MyServer, :"remote@host"}, :work, 10_000)
catch
  :exit, {:noproc, _} -> {:error, :not_running}
  :exit, {{:nodedown, _}, _} -> {:error, :node_down}
  :exit, {:timeout, _} -> {:error, :timeout}
end

# BAD: Storing cluster-wide state in a single GenServer
# One node owns it, everyone else does cross-node calls → bottleneck + SPOF

# GOOD: Local ETS cache per node, refreshed via PubSub or periodic sync
# Each node reads locally, writes propagate asynchronously

# BAD: Using :global for frequently accessed registrations
# :global uses a global lock — high contention under load

# GOOD: Use Horde or :pg for high-frequency distributed lookup
```

## Architectural Styles in Elixir

How common architectural styles map to Elixir idioms. Many patterns that require frameworks and infrastructure in other languages are built into OTP. Understand what Elixir gives you for free before reaching for external solutions.

### What Each Style Solves — Quick Reference

Use this table to match a problem to an architectural approach. **Start with the simplest style that solves the actual problem.** Do not adopt a style because it sounds sophisticated — adopt it because you have the specific problem it solves.

| Problem You Have | Style | Elixir Solution |
|-----------------|-------|-----------------|
| Need to separate UI from logic | MVC | Thin dispatchers → contexts → structs (Elixir default) |
| Need swappable external dependencies (DB, APIs, hardware) | Hexagonal / Ports & Adapters | Behaviours (ports) + implementations (adapters) + config |
| Need fault isolation without separate deployments | Modular Monolith | Contexts + supervision trees (OTP default) |
| Need to decouple producers from consumers | Event Notification | PubSub / `:pg` — fire and forget |
| Subscribers need full data without calling back | Event-Carried State Transfer | PubSub with rich event payloads |
| Need complete audit trail / state replay / compliance | Event Sourcing | Commanded — events are source of truth |
| Read and write patterns diverge significantly | CQRS | Query modules, read replicas, or projections |
| Need backpressure between fast producer and slow consumer | Demand-Driven | GenStage / Broadway |
| Side effects must survive crashes / guaranteed delivery | Persistent Queue | Oban |
| Multi-step workflows that must complete or compensate | Saga / Process Manager | Commanded process managers or Oban workflows |
| Different language / compliance / extreme scaling | Microservices | Separate deployments — last resort in Elixir |
| Need to protect against slow/failing external services | Resilience | Circuit breaker (`:fuse`), bulkheads (process pools), timeouts |

**The default Elixir architecture** — contexts + supervision + behaviours — already gives you MVC, hexagonal, and modular monolith patterns. Most apps never need anything beyond this plus PubSub for decoupling.

### MVC — How It Maps to Elixir

| Classical MVC | Elixir Reality |
|--------------|-----------------|
| Model (active record, ORM) | Contexts + schemas/structs (separated) |
| View (template/UI rendering) | Function components, CLI formatters, display renderers |
| Controller (handles input) | Thin dispatcher — translates input, delegates to context |

| Interface Type | "Controller" | "View" | "Model" |
|---------------|-------------|--------|---------|
| Phoenix web | Controller / LiveView | HEEx templates, components | Contexts + Ecto schemas |
| CLI tool | `main/1` or escript entry | IO/formatting module | Contexts + structs |
| Nerves device | GenServer handling hardware input | Display/output module | Contexts + structs |
| Library | Public API module | N/A (no UI) | Internal modules |

**The LLM rule:** NEVER organize Elixir code into `models/`, `services/`, or `helpers/` directories. These are anti-patterns from other ecosystems. Elixir uses:
- **Contexts/boundary modules** where MVC would say "model" or "service"
- **Output/formatting modules** where MVC would say "view"
- **Thin dispatchers** where MVC would say "controller" — containing no business logic

```elixir
# BAD: "MVC" thinking imported from Rails/Django
lib/my_app/
├── models/         # No — use contexts
│   └── user.ex
├── services/       # No — logic belongs in contexts
│   └── user_service.ex
└── helpers/        # No — use context functions or formatters
    └── format_helper.ex

# GOOD: Elixir domain-driven structure
lib/my_app/
├── accounts.ex            # Context (boundary)
├── accounts/
│   ├── user.ex            # Schema/struct (internal to context)
│   └── authentication.ex  # Pure logic (internal)
└── catalog.ex             # Another context
```

**When someone says "MVC" in Elixir, they mean:** Interface → Domain → Infrastructure. MVC is a UI-layer pattern. The real architecture is the layered/hexagonal design described in this document.

### Microservices — Why Elixir Rarely Needs Them

OTP already provides fault isolation (supervision), independent scaling (process pools), loose coupling (contexts + PubSub), and service discovery (Registry, `:pg`). The Elixir default is the **modular monolith** — one deployment, zero network hops.

**ONLY split into separate services when:**

| Signal | Why Separate Service |
|--------|---------------------|
| Different language needed | GPU service in Python/CUDA, web in Elixir |
| Regulatory/compliance isolation | Payment processing must be PCI-isolated |
| Wildly different scaling needs | Video transcoding vs web API |
| Separate teams, separate release cycles | Organization-driven, not tech-driven |
| Legacy system integration | Wrap legacy behind an API boundary |

**NEVER split into services for:**
- "It's getting big" → add contexts
- "We want loose coupling" → use behaviours and PubSub
- "We want fault isolation" → use supervision trees
- "We want independent scaling" → use process pools, `Task.async_stream`, Broadway

**If you do split:** communicate via well-defined APIs (HTTP/gRPC), not shared databases. Each service owns its data. Use Broadway + message broker (Kafka, RabbitMQ) for async integration. Consider `:erpc` for Elixir-to-Elixir calls within a trusted network.

### Event-Driven Architecture

Three distinct patterns, often conflated:

#### 1. Event Notification

Publisher broadcasts that something happened. Subscribers decide what to do. Event carries minimal data — just an identifier.

```elixir
# Publisher: "this happened"
Phoenix.PubSub.broadcast(MyApp.PubSub, "orders", {:order_completed, order_id})

# Subscriber fetches what it needs
def handle_info({:order_completed, order_id}, state) do
  order = Orders.get_order!(order_id)  # Subscriber calls back for data
  send_confirmation(order)
  {:noreply, state}
end
```

**Trade-offs:** Simple. Publisher is decoupled. But subscriber must call back to fetch data — creates coupling to the source context and a potential N+1 query pattern if many subscribers each fetch.

#### 2. Event-Carried State Transfer

Event carries all data the subscriber needs. No callback required.

```elixir
# Publisher includes everything
event = %{
  order_id: order.id,
  customer_email: order.customer.email,
  items: Enum.map(order.items, &%{name: &1.name, qty: &1.quantity}),
  total: order.total,
  completed_at: DateTime.utc_now()
}
Phoenix.PubSub.broadcast(MyApp.PubSub, "orders", {:order_completed, event})

# Subscriber has everything it needs — no callback
def handle_info({:order_completed, event}, state) do
  send_confirmation(event.customer_email, event)  # No need to fetch
  {:noreply, state}
end
```

**Trade-offs:** Subscribers are fully decoupled — no callback to source. But events are larger, and publisher must anticipate what data subscribers need. This is the pattern used in event sourcing (events carry all relevant state).

#### 3. Event Sourcing

Events are the authoritative source of truth. Current state is derived by replaying events. See [eventsourcing-reference.md](eventsourcing-reference.md) for full Commanded implementation.

```
Standard:  State is truth, events are notifications
           DB row → read current state → done

Sourced:   Events are truth, state is derived
           Event log → replay all events → compute current state
```

#### Event-Driven Decision Guide

```
Do you need to decouple contexts?
├── No coupling needed → Direct function call (not event-driven)
├── Fire-and-forget notification → Event Notification (PubSub, :pg)
├── Subscriber needs data but shouldn't call back → Event-Carried State Transfer
├── Need backpressure → GenStage/Broadway (demand-driven events)
├── Events must survive crashes → Oban (persistent queue)
└── Events ARE the source of truth → Event Sourcing (Commanded)
```

### CQRS — Command Query Responsibility Segregation

Three levels of increasing complexity:

#### Level 1: Light CQRS (Default — Most Apps Already Do This)

```elixir
defmodule MyApp.Catalog do
  # === Queries (reads) ===
  def list_products, do: Repo.all(Product)
  def get_product!(id), do: Repo.get!(Product, id)
  def search_products(query), do: Product.search(query) |> Repo.all()

  # === Commands (writes) ===
  def create_product(attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end

  def update_product(product, attrs) do
    product
    |> Product.changeset(attrs)
    |> Repo.update()
  end
  def delete_product(product), do: Repo.delete(product)
end
```

**This is CQRS.** Queries return data. Commands return `{:ok, _} | {:error, _}`. The same database serves both, but the functions are conceptually separated. For most applications, this is sufficient.

#### Level 2: Separated Read Path (When Reads Need Optimization)

When read patterns diverge from write patterns — complex queries, aggregations, search, dashboards — extract query modules and optionally use read replicas:

```elixir
# Write path: standard context
defmodule MyApp.Catalog do
  def create_product(attrs), do: ...
  def update_product(product, attrs), do: ...
end

# Read path: specialized query module
defmodule MyApp.Catalog.Queries do
  @moduledoc false
  import Ecto.Query

  def top_sellers(limit \\ 10) do
    from(p in Product,
      join: oi in OrderItem, on: oi.product_id == p.id,
      group_by: p.id,
      order_by: [desc: count(oi.id)],
      limit: ^limit,
      select: %{product: p, sales_count: count(oi.id)}
    )
    |> Repo.all()
  end
end

# Context delegates
defmodule MyApp.Catalog do
  alias MyApp.Catalog.Queries
  defdelegate top_sellers(limit \\ 10), to: Queries
  # ... write functions remain here
end
```

**Read replicas (optional):**

```elixir
# config/runtime.exs
config :my_app, MyApp.ReadRepo,
  url: System.fetch_env!("READ_DATABASE_URL"),
  read_only: true

# Query module uses read replica
def top_sellers(limit) do
  from(...) |> MyApp.ReadRepo.all()
end
```

**Use when:** Dashboard/reporting queries are slow and contend with writes. Search needs a different data structure (Elasticsearch). Analytics need pre-aggregated data. Read traffic is 10x+ write traffic.

#### Level 3: Full CQRS + Projections (With Event Sourcing)

Writes go to an event store. Reads come from purpose-built projections (materialized views). Each projection is optimized for a specific query pattern.

```
Command → Aggregate → Event Store (append-only)
                            ↓
              ┌─────────────┼──────────────┐
              ↓             ↓              ↓
        ProductList    ProductSearch    SalesDashboard
        (Ecto table)   (Elasticsearch)  (TimescaleDB)
```

```elixir
# Write side: Commanded aggregate (pure function)
defmodule MyApp.Catalog.ProductAggregate do
  def execute(%{status: :active}, %CreateProduct{} = cmd) do
    %ProductCreated{id: cmd.id, title: cmd.title, price: cmd.price}
  end
end

# Read side: Projection optimized for listing
defmodule MyApp.Catalog.Projectors.ProductList do
  use Commanded.Projections.Ecto, repo: MyApp.Repo, name: "product_list"

  project(%ProductCreated{} = event, fn multi ->
    Ecto.Multi.insert(multi, :product, %ProductListEntry{
      product_id: event.id, title: event.title, price: event.price
    })
  end)
end

# Read side: Projection optimized for search (different store)
defmodule MyApp.Catalog.Projectors.ProductSearch do
  use Commanded.Event.Handler, name: "product_search"

  def handle(%ProductCreated{} = event, _metadata) do
    Elasticsearch.index(:products, event.id, %{title: event.title, price: event.price})
  end
end
```

> Full Commanded implementation details: [eventsourcing-reference.md](eventsourcing-reference.md) and [eventsourcing-examples.md](eventsourcing-examples.md)

**Use when:** Event sourcing is already in use. Multiple very different read views of the same data. Read and write scaling needs are dramatically different. Eventual consistency between read models is acceptable.

#### CQRS Decision Guide

| Signal | Level | Approach |
|--------|-------|----------|
| Standard web app, moderate traffic | Light (1) | Queries and commands in same context |
| Complex reporting alongside CRUD | Separated (2) | Query modules, optional read replica |
| Dashboard queries contend with writes | Separated (2) | Read replica, pre-aggregated tables |
| Full audit trail + different read stores | Full (3) | Event sourcing + projections |
| "Should I use CQRS?" uncertainty | Light (1) | You're probably already doing it |

### How Styles Combine

```
Typical large Elixir app:

┌─────────────────────────────────────────────────────┐
│ Modular monolith (NOT microservices)                 │
│                                                      │
│  Accounts context          Orders context            │
│  ├─ Light CQRS             ├─ Event sourcing         │
│  ├─ Direct Ecto            │  (Commanded)             │
│  └─ Request-response       ├─ Full CQRS              │
│                            │  (projections)           │
│  Catalog context           ├─ Event-driven            │
│  ├─ Separated read path    │  (process managers)      │
│  │  (search index)         └─ Sagas for workflows     │
│  └─ Event-carried state                              │
│     transfer (PubSub)      Notifications context      │
│                            ├─ Event notification      │
│                            │  (subscribes to PubSub)  │
│                            └─ Oban for delivery       │
│                                                      │
│  ── All within one Mix release, one supervision ──   │
│  ── tree, one deployment                         ──  │
└─────────────────────────────────────────────────────┘
```

**Key insight:** Different contexts within the same application can use different architectural styles. The Accounts context might be simple CRUD while the Orders context uses full event sourcing. The boundary module (context) is what enables this — callers don't know or care what style is used internally.

### Architectural Style Decision Tree

```
Starting a new Elixir project or context:

1. How complex is the domain?
   ├── Simple CRUD → Ecto + contexts + light CQRS (STOP HERE for most apps)
   ├── Moderate → Contexts + separated read path if needed
   └── Complex domain logic, long-lived processes → Consider event sourcing

2. How important is the event history?
   ├── Not needed → Standard Ecto (mutable state)
   ├── Nice to have → Audit log table + standard Ecto
   └── Business requirement (compliance, replay) → Event sourcing

3. How different are read and write patterns?
   ├── Same shape → Light CQRS (queries and commands in one context)
   ├── Different queries needed → Separated read path (query modules)
   └── Totally different stores → Full CQRS with projections

4. How do contexts need to communicate?
   ├── Synchronous, simple → Direct function calls
   ├── Async, loss tolerant → PubSub (event notification)
   ├── Async, data self-contained → PubSub (event-carried state)
   ├── Async, guaranteed delivery → Oban
   ├── Backpressure needed → GenStage/Broadway
   └── Multi-step orchestration → Process manager / saga

5. Deployment model?
   ├── Single deployment → Modular monolith (default, preferred)
   ├── Need separate scaling → Separate Mix releases from umbrella
   └── Different language/compliance → Separate service with API boundary
```

## Anti-Patterns Catalog

### Imperative Habits (Most Common LLM Mistakes)

```elixir
# BAD - #1 MISTAKE: accumulation with Enum.each
# Rebinding inside each does NOT affect outer scope
def collect(items) do
  result = []
  Enum.each(items, fn item ->
    result = [transform(item) | result]  # This rebinding is local!
  end)
  result  # Always returns []
end

# GOOD
def collect(items), do: Enum.map(items, &transform/1)


# BAD - nested case instead of with
def register(params) do
  case validate_email(params) do
    {:ok, email} ->
      case validate_password(params) do
        {:ok, password} ->
          case create_user(email, password) do
            {:ok, user} -> {:ok, user}
            {:error, reason} -> {:error, reason}
          end
        {:error, reason} -> {:error, reason}
      end
    {:error, reason} -> {:error, reason}
  end
end

# GOOD
def register(params) do
  with {:ok, email} <- validate_email(params),
       {:ok, password} <- validate_password(params),
       {:ok, user} <- create_user(email, password) do
    {:ok, user}
  end
end


# BAD - if/else chain for type dispatch
def format(value) do
  if is_list(value) do
    Enum.join(value, ", ")
  else
    if is_map(value) do
      Torque.encode!(value)
    else
      to_string(value)
    end
  end
end

# GOOD
def format(value) when is_list(value), do: Enum.join(value, ", ")
def format(value) when is_map(value), do: Torque.encode!(value)
def format(value), do: to_string(value)


# BAD - nil checking with if
def greet(user) do
  if user != nil do
    if user.name != nil do
      "Hello, #{user.name}"
    else
      "Hello, anonymous"
    end
  else
    "Hello, guest"
  end
end

# GOOD
def greet(%{name: name}) when is_binary(name), do: "Hello, #{name}"
def greet(%{}), do: "Hello, anonymous"
def greet(nil), do: "Hello, guest"


# BAD - string concatenation in loop (O(n^2))
def build_csv(rows) do
  Enum.reduce(rows, "", fn row, acc ->
    acc <> Enum.join(row, ",") <> "\n"
  end)
end

# GOOD - IO list, single binary conversion
def build_csv(rows) do
  rows
  |> Enum.map(fn row -> [Enum.intersperse(row, ","), "\n"] end)
  |> IO.iodata_to_binary()
end

# ALSO GOOD
def build_csv(rows) do
  Enum.map_join(rows, "\n", &Enum.join(&1, ","))
end


# BAD - imperative index tracking
def process_with_index(list) do
  {result, _} = Enum.reduce(list, {[], 0}, fn item, {acc, i} ->
    {[{i, transform(item)} | acc], i + 1}
  end)
  Enum.reverse(result)
end

# GOOD
list
|> Enum.with_index()
|> Enum.map(fn {item, i} -> {i, transform(item)} end)


# BAD - try/rescue for flow control
def parse_int(str) do
  try do
    {:ok, String.to_integer(str)}
  rescue
    ArgumentError -> {:error, :invalid}
  end
end

# GOOD
def parse_int(str) do
  case Integer.parse(str) do
    {int, ""} -> {:ok, int}
    {_int, _rest} -> {:error, :trailing_chars}
    :error -> {:error, :invalid}
  end
end


# BAD - Enum.each discards return values silently
def send_notifications(users) do
  Enum.each(users, fn user ->
    Mailer.send(user.email, "Hello")  # Return value discarded, no error visibility
  end)
end

# GOOD - collect results
def send_notifications(users) do
  results = Enum.map(users, fn user ->
    case Mailer.send(user.email, "Hello") do
      {:ok, _} -> {:ok, user.id}
      {:error, reason} -> {:error, user.id, reason}
    end
  end)
  {sent, failed} = Enum.split_with(results, &match?({:ok, _}, &1))
  %{sent: length(sent), failed: failed}
end


# BAD - sequential rebinding instead of pipeline
def process(data) do
  data = Map.put(data, :step1, compute_step1(data))
  data = Map.put(data, :step2, compute_step2(data))
  data = Map.put(data, :step3, compute_step3(data))
  data
end

# GOOD - if steps are independent
def process(data) do
  Map.merge(data, %{
    step1: compute_step1(data),
    step2: compute_step2(data),
    step3: compute_step3(data)
  })
end

# GOOD - if steps depend on prior results
def process(data) do
  data
  |> then(fn d -> Map.put(d, :step1, compute_step1(d)) end)
  |> then(fn d -> Map.put(d, :step2, compute_step2(d)) end)
  |> then(fn d -> Map.put(d, :step3, compute_step3(d)) end)
end


# BAD - boolean flag parameters
fetch_users(true, false)

# GOOD - keyword options
fetch_users(active: true, preload: false)

# BETTER - separate functions for distinct behaviors
fetch_active_users()
```

### Architecture Anti-Patterns

```elixir
# BAD: Domain module depends on web/framework layer (dependency rule violation)
defmodule MyApp.Orders do
  alias MyAppWeb.Router.Helpers, as: Routes  # NEVER — domain depends on web!
  import Phoenix.Controller                   # NEVER — framework in domain!

  def complete_order(order) do
    url = Routes.order_url(MyAppWeb.Endpoint, :show, order)  # Web concern in domain!
    # ...
  end
end

# GOOD: Domain is framework-agnostic, interface layer handles presentation
defmodule MyApp.Orders do
  def complete_order(order) do
    # Pure domain logic only — URL generation belongs in controller/LiveView
    with {:ok, order} <- mark_completed(order) do
      {:ok, order}
    end
  end
end


# BAD: Controller queries Repo directly
def index(conn, _params) do
  products = Repo.all(Product)
  render(conn, :index, products: products)
end

# GOOD: Controller calls context
def index(conn, _params) do
  products = Catalog.list_products()
  render(conn, :index, products: products)
end


# BAD: God context with unrelated functionality
defmodule MyApp.Admin do
  def list_users, do: ...
  def create_product, do: ...
  def process_payment, do: ...
  def send_notification, do: ...
end

# GOOD: Separate contexts per domain
defmodule MyApp.Accounts do ... end
defmodule MyApp.Catalog do ... end
defmodule MyApp.Billing do ... end
defmodule MyApp.Notifications do ... end


# BAD: Domain tightly coupled to external service
defmodule MyApp.Billing do
  def charge(order) do
    Stripe.Charge.create(%{amount: order.total, source: order.token})
  end
end

# GOOD: Behaviour-based abstraction
defmodule MyApp.Billing do
  @gateway Application.compile_env(:my_app, :payment_gateway)
  def charge(order), do: @gateway.charge(order.total, order.token)
end


# BAD: Business logic in GenServer callbacks
def handle_call({:apply_discount, code}, _from, state) do
  discount = case code do
    "SAVE10" -> Decimal.new("0.10")
    "SAVE20" -> Decimal.new("0.20")
    _ -> Decimal.new("0")
  end
  new_total = Decimal.mult(state.total, Decimal.sub(1, discount))
  {:reply, {:ok, new_total}, %{state | total: new_total}}
end

# GOOD: Pure function for logic, GenServer for state only
defmodule MyApp.Pricing do
  def apply_discount(total, code) do
    rate = discount_rate(code)
    Decimal.mult(total, Decimal.sub(1, rate))
  end

  defp discount_rate("SAVE10"), do: Decimal.new("0.10")
  defp discount_rate("SAVE20"), do: Decimal.new("0.20")
  defp discount_rate(_), do: Decimal.new("0")
end

def handle_call({:apply_discount, code}, _from, state) do
  new_total = MyApp.Pricing.apply_discount(state.total, code)
  {:reply, {:ok, new_total}, %{state | total: new_total}}
end


# BAD: Premature umbrella split
apps/
├── auth/          # Used by every other app
├── core/          # Used by every other app
├── web/           # Depends on auth, core, billing, catalog
├── billing/       # Depends on auth, core
├── catalog/       # Depends on auth, core
└── notifications/ # Depends on auth, core, billing, catalog

# GOOD: Single app with clean contexts
lib/my_app/
├── accounts.ex
├── billing.ex
├── catalog.ex
└── notifications.ex


# BAD: Registry and DynamicSupervisor under :one_for_one
children = [
  {Registry, keys: :unique, name: MyApp.WorkerRegistry},
  {DynamicSupervisor, name: MyApp.WorkerSupervisor}
]
Supervisor.init(children, strategy: :one_for_one)  # WRONG

# GOOD: Tightly coupled processes under :one_for_all
Supervisor.init(children, strategy: :one_for_all)
```

### Testing & Mock Anti-Patterns

```elixir
# BAD: Mock always returns :ok — hides error paths (Liskov Substitution violation)
# Tests pass, production crashes on {:error, _} because no code handles it
Mox.expect(PaymentMock, :charge, fn _, _ -> {:ok, %{id: "tx_123"}} end)

# GOOD: Test both success AND error paths — mock must behave like real adapter
test "handles payment failure" do
  Mox.expect(PaymentMock, :charge, fn _, _ -> {:error, :card_declined} end)
  assert {:error, :payment_failed} = Orders.complete_order(order)
end

test "handles payment timeout" do
  Mox.expect(PaymentMock, :charge, fn _, _ -> {:error, :timeout} end)
  assert {:error, :payment_failed} = Orders.complete_order(order)
end

# BAD: Business logic only testable with full infrastructure
# If this test needs Repo, PubSub, and an HTTP mock just to test a discount rule,
# the architecture has a boundary problem
test "applies discount" do
  {:ok, _} = start_supervised(MyApp.PubSub)      # Why does a discount need PubSub?
  insert(:product, price: 100)                     # Why does a discount need a DB?
  assert MyApp.Orders.apply_discount(order, "SAVE10") == ...
end

# GOOD: Pure domain logic tested without infrastructure
test "applies discount" do
  order = %Order{total: Decimal.new(100)}
  assert Decimal.eq?(Pricing.apply_discount(order.total, "SAVE10"), Decimal.new(90))
end
```

### Pattern Matching Gotchas

```elixir
# BAD: %{} matches ANY map, not just empty maps
def handle(%{}), do: :empty       # Matches %{a: 1} too!
def handle(map), do: :has_keys

# GOOD: Guard for empty map
def handle(map) when map == %{}, do: :empty
def handle(map) when map_size(map) == 0, do: :empty
def handle(map), do: :has_keys

# BAD: Atom keys don't match string keys (very common with params)
%{name: name} = %{"name" => "Jo"}  # MatchError! Atom :name != string "name"

# GOOD: Match with the correct key type
%{"name" => name} = params          # External data (JSON, forms) uses string keys
%{name: name} = internal_map        # Internal data uses atom keys

# BAD: Keyword list order matters in pattern matching
def process([a: _, b: _]), do: :matched
process([b: 1, a: 2])  # => Falls through, no match!

# GOOD: Use Keyword functions or convert to map
def process(opts) when is_list(opts) do
  a = Keyword.get(opts, :a)
  b = Keyword.get(opts, :b)
end

# BAD: Pattern matching integers with floats (strict type matching)
def handle(1), do: :one
handle(1.0)  # => FunctionClauseError! 1 != 1.0 in patterns

# GOOD: Use guards for numeric comparisons, not pattern literals
def handle(n) when n == 0, do: :zero      # Works for 0, 0.0, and -0.0
def handle(n) when n == 1, do: :one       # Works for both 1 and 1.0
def handle(n) when is_number(n), do: :number

# BAD: Float equality (precision issues)
0.1 + 0.2 == 0.3  # => false!

# GOOD: Compare with tolerance for floats
def nearly_equal?(a, b, epsilon \\ 1.0e-10), do: abs(a - b) < epsilon
```

### Cross-Type Comparisons

Elixir allows comparisons between any types via term ordering:

```elixir
# SURPRISING: This returns true!
"1" > 2  # => true (strings > numbers in term order)

# Term ordering (lowest to highest):
# number < atom < reference < function < port < pid < tuple < map < list < binary

# BAD: Comparing user input without type checking
def authorized?(level) when level > 5, do: true  # "admin" > 5 is true!

# GOOD: Validate type first
def authorized?(level) when is_integer(level) and level > 5, do: true
```

### Data Structures

```elixir
# DANGEROUS: Atoms from user input (exhausts atom table ~1M limit)
String.to_atom(user_input)
# Avoid JSON decode options that create atoms from untrusted keys.
:erlang.binary_to_term(data)            # Atoms from untrusted binary

# GOOD: Explicit mapping (preferred for user input)
defp convert_status("pending"), do: :pending
defp convert_status("active"), do: :active
defp convert_status("inactive"), do: :inactive
defp convert_status(_), do: :unknown

# SAFE: to_existing_atom (only works if atom already exists)
String.to_existing_atom(user_input)
Torque.decode!(json)                     # String keys by default, safe
:erlang.binary_to_term(data, [:safe])   # Rejects new atoms

# BAD: String concatenation in loops (O(n^2))
Enum.reduce(items, "", fn i, acc -> acc <> "#{i}\n" end)

# GOOD: IO lists
items
|> Enum.map(&["Item: ", &1, "\n"])
|> IO.iodata_to_binary()
```

### Processes & OTP

```elixir
# BAD: GenServer bottleneck for reads
GenServer.call(Cache, {:get, key})

# GOOD: Direct ETS reads
:ets.lookup(:cache, key)

# BAD: Blocking operations in GenServer callbacks
def handle_call(:fetch, _from, state) do
  data = HTTPClient.get!(url)  # Blocks ALL message processing!
  {:reply, data, state}
end

# GOOD: Offload to Task, reply asynchronously
def handle_call(:fetch, from, state) do
  Task.start(fn ->
    data = HTTPClient.get!(url)
    GenServer.reply(from, data)
  end)
  {:noreply, state}
end

# BAD: Large data in process state (memory pressure, slow GC)
def init(_), do: {:ok, %{cache: load_million_records()}}

# GOOD: Store large data in ETS, reference from state
def init(_) do
  :ets.new(:cache, [:named_table, :public, read_concurrency: true])
  {:ok, %{table: :cache}}
end

# BAD: Unbounded mailbox growth
def handle_cast(:process, state) do
  # Slow processing while messages flood in
  Process.sleep(1000)
  {:noreply, state}
end

# GOOD: Apply backpressure or use call instead of cast
def handle_call(:process, _from, state) do
  # Caller blocks until complete - natural backpressure
  result = slow_operation()
  {:reply, result, state}
end

# BAD: Unsupervised GenServer - single point of failure
GenServer.start_link(Worker, [])

# GOOD: Always supervise
children = [{Worker, []}]
Supervisor.start_link(children, strategy: :one_for_one)

# BAD: Task.async in a GenServer — crash kills the GenServer
def handle_call(:work, _from, state) do
  task = Task.async(fn -> risky_work() end)
  result = Task.await(task)
  {:reply, result, state}
end

# GOOD: Task.Supervisor.async_nolink — GenServer survives task crash
def handle_call(:work, _from, state) do
  task = Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn -> risky_work() end)
  {:reply, :started, %{state | task_ref: task.ref}}
end

# BAD: DynamicSupervisor without max_children — unbounded growth
DynamicSupervisor.init(strategy: :one_for_one)

# GOOD: Set a limit based on system capacity
DynamicSupervisor.init(strategy: :one_for_one, max_children: 10_000)
```

**OTP Health Checks:**
- Monitor mailbox size: `Process.info(pid, :message_queue_len)`
- Check memory: `Process.info(pid, :memory)`
- Unsupervised processes = silent failures

### Errors

```elixir
# BAD: Swallowing errors
try do
  risky_operation()
rescue
  _ -> :ok
end

# BAD: try/rescue for expected errors
try do
  Torque.decode!(json)
rescue
  e -> {:error, e}
end

# GOOD: Use non-bang functions
Torque.decode(json)
```

### Performance

```elixir
# BAD: N+1 queries
posts = Repo.all(Post)
Enum.map(posts, fn p -> Repo.get(User, p.user_id) end)

# GOOD: Preload
Post
|> Repo.all()
|> Repo.preload(:author)

# BAD: Loading large files into memory
File.read!("huge.txt") |> String.split("\n") |> Enum.map(&process/1)

# GOOD: Streaming
File.stream!("huge.txt")
|> Stream.map(&process/1)
|> Enum.to_list()
```

### Distribution

```elixir
# BAD: Using casts across nodes (no delivery guarantee)
GenServer.cast({:global, :service}, {:update, data})

# GOOD: Use calls for distributed operations (confirms delivery)
GenServer.call({:global, :service}, {:update, data})

# BAD: Sending lambdas to remote nodes (code must match exactly)
Node.spawn(:remote@host, fn -> process(data) end)

# GOOD: Use MFA (Module, Function, Arguments)
Node.spawn(:remote@host, MyModule, :process, [data])

# BAD: Ignoring network partitions
# Nodes silently disconnect, your code keeps trying

# GOOD: Monitor node connections
:net_kernel.monitor_nodes(true)
# Receive {:nodeup, node} and {:nodedown, node} messages
```

**Distribution Principles:**
- Always use `call` (not `cast`) across nodes — you need delivery confirmation
- Use MFA, not lambdas, for remote spawning
- Handle `:nodedown` messages — partitions happen
- Global registration is eventually consistent
