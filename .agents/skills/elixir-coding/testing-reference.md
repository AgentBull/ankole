# Elixir Testing Quick Reference

Quick-lookup tables for ExUnit, Mox, Phoenix testing, property-based testing, ExVCR, and Wallaby. Production patterns sourced from Elixir stdlib, Phoenix, Ecto, Mox, and JSON round-trip tests.

## Test Case Types

| Case Template | Purpose | Provides | async safe? |
|---|---|---|---|
| `ExUnit.Case` | Pure unit tests (no DB) | Basic ExUnit | Yes |
| `DataCase` | Database tests with Sandbox | Repo, Ecto imports, `errors_on/1` | Yes (with Sandbox) |
| `ConnCase` | Phoenix controller/plug tests | `conn`, Phoenix.ConnTest helpers | Yes (with Sandbox) |
| `ChannelCase` | Phoenix channel tests | Phoenix.ChannelTest helpers | Yes |
| `FeatureCase` | Wallaby browser tests | Wallaby.Feature, sessions | No (usually) |
| Custom `CaseTemplate` | Shared setup | Whatever you define | Depends |

## Assertions

```elixir
# Value assertions
assert value                              # Truthy
assert value, "Custom failure message"    # With message
refute value                              # Falsy

# Equality and pattern matching
assert x == y                             # Equality (shows diff on failure)
assert x === y                            # Strict equality (1 !== 1.0)
assert x != y                             # Inequality
assert x =~ "pattern"                     # String contains / regex match
assert x in [:a, :b, :c]                  # Membership
assert x in 1..10                         # Range membership
assert %{key: _} = map                    # Pattern match (binds variables)
assert {:ok, %User{name: name}} = result  # Nested pattern match
assert <<_::8, rest::binary>> = data      # Binary pattern
assert match?({:ok, _}, result)           # Boolean pattern check

# Comparisons
assert x > y
assert x >= y
assert x < y
assert x <= y

# Numeric
assert_in_delta 0.1 + 0.2, 0.3, 0.0001  # Float comparison

# Exception assertions
assert_raise RuntimeError, fn -> raise "boom" end
assert_raise RuntimeError, "boom", fn -> raise "boom" end
assert_raise RuntimeError, ~r/pattern/, fn -> raise "boom pattern" end

# Process mailbox
assert_receive {:msg, payload}, 1000      # Wait up to 1000ms
assert_receive {:msg, ^expected_id}       # Pin operator for matching
assert_received :already_there            # Already in mailbox (no wait)
refute_receive :unexpected, 100           # Nothing received within timeout
refute_received :not_there                # Not in mailbox now

# Capture output
import ExUnit.CaptureIO
import ExUnit.CaptureLog
assert capture_io(fn -> IO.puts("hello") end) == "hello\n"
assert capture_io(:stderr, fn -> IO.warn("x") end) =~ "x"
assert capture_log(fn -> Logger.error("oops") end) =~ "oops"

# with_log (Elixir 1.14+) — returns {result, log}
{result, log} = with_log(fn ->
  Logger.info("computing...")
  42
end)

# Explicit failure
flunk("should not reach here")
```

## Setup Patterns

```elixir
# Basic setup — return context map
setup do
  %{user: insert(:user)}
end

# Setup with context access
setup context do
  user = if context[:admin], do: insert(:admin), else: insert(:user)
  %{user: user}
end

# Named setup — reference functions by name
setup [:create_user, :verify_on_exit!]

# setup_all — runs once per module (NOT per test)
setup_all do
  start_supervised!({Phoenix.PubSub, name: TestPubSub, pool_size: 1})
  %{pubsub: TestPubSub}
end

# on_exit — cleanup callback, runs after each test even on failure
setup context do
  :telemetry.attach("#{context.test}", @events, &handler/4, nil)
  on_exit(fn -> :telemetry.detach("#{context.test}") end)
  :ok
end

# start_supervised! — auto-stopped after test
setup do
  pid = start_supervised!({MyWorker, initial_state: []})
  %{worker: pid}
end

# @tag :tmp_dir — ExUnit creates and cleans up temp directory
@tag :tmp_dir
test "writes file", %{tmp_dir: tmp_dir} do
  File.write!(Path.join(tmp_dir, "test.txt"), "hello")
end
```

## Tags and Filtering

```elixir
@tag :slow                       # Tag single test
@tag timeout: 120_000            # Tag with value
@describetag :integration        # Tag describe block
@moduletag :database             # Tag all tests in module
@moduletag :capture_log          # Suppress Logger output
```

```bash
mix test --only slow             # Only tagged
mix test --exclude integration   # Exclude tagged
mix test --include slow          # Include previously excluded
```

Tag precedence: test > describe > module (later overrides earlier).

## Mox API

```elixir
# test_helper.exs
Mox.defmock(MyMock, for: MyBehaviour)
Mox.defmock(MultiMock, for: [BehaviourA, BehaviourB])
Mox.defmock(MyMock, for: MyBehaviour, skip_optional_callbacks: true)

# Test setup
import Mox
setup :verify_on_exit!           # ALWAYS — catches unfulfilled expectations
setup :set_mox_from_context      # Auto-selects private/global based on async tag

# Expectations
expect(Mock, :func, fn arg -> result end)          # Expect 1 call
expect(Mock, :func, 3, fn arg -> result end)       # Expect exactly 3 calls
Mock
|> expect(:a, fn -> :a end)
|> expect(:b, fn -> :b end)  # Chain

# Stubs (any number of calls, no verification)
stub(Mock, :func, fn arg -> default end)
stub_with(Mock, RealImplementation)                # Stub all functions from module

# Deny (must NOT be called)
deny(Mock, :func, 2)                               # func/2 must not be called

# Allow (multi-process)
allow(Mock, self(), pid)                            # Allow pid to use expectations
allow(Mock, self(), fn -> GenServer.whereis(name) end)  # Lazy pid resolution

# Modes
set_mox_private()                # Only owning process (default)
set_mox_global()                 # All processes share (requires async: false)
set_mox_from_context()           # Auto-detect from async tag

# Verify
verify!()                        # Verify all mocks
verify!(Mock)                    # Verify specific mock
```

## Factories (ExMachina)

```elixir
insert(:user)                    # Insert to DB
insert(:user, email: "a@b.com")  # With override
insert_list(3, :user)            # Insert multiple
build(:user)                     # Build without insert
params_for(:user)                # Map (atom keys)
string_params_for(:user)         # Map (string keys) — for controller tests
```

## Controller Testing

```elixir
# HTTP verbs
conn = get(conn, ~p"/users")
conn = post(conn, ~p"/users", user: attrs)
conn = put(conn, ~p"/users/#{id}", user: attrs)
conn = patch(conn, ~p"/users/#{id}", user: attrs)
conn = delete(conn, ~p"/users/#{id}")

# Response assertions
html_response(conn, 200)         # Assert status, return HTML body
json_response(conn, 200)         # Assert status, decode JSON body
text_response(conn, 200)         # Assert status, return text body
response(conn, 204)              # Assert status, return raw body
redirected_to(conn)              # Get redirect location
redirected_params(conn)          # Get redirect params
response_content_type(conn, :json)  # Assert content-type

# Error pages
assert_error_sent 404, fn -> get(conn, ~p"/users/0") end

# Session/cookie management
conn = build_conn() |> init_test_session(%{user_id: 123})
conn = recycle(conn)             # New conn keeping cookies (browser sim)
conn = bypass_through(conn, Router, [:browser])  # Run pipeline without dispatch
```

## Channel Testing

```elixir
# Create and join
{:ok, reply, socket} =
  socket(UserSocket, "user:id", %{user_id: 123})
  |> subscribe_and_join(Channel, "topic:name")

# Push and assert
ref = push(socket, "event", %{data: "value"})
assert_reply ref, :ok, response
assert_reply ref, :error, %{reason: "invalid"}

# Broadcast assertions
assert_broadcast "event", payload
refute_broadcast "event", _

# Push to client
assert_push "event", payload
refute_push "event", _

# Broadcast from outside
broadcast_from!(socket, "event", %{data: "new"})

# Leave/close
ref = leave(socket)
close(socket)
```

## LiveView Testing

```elixir
import Phoenix.LiveViewTest

# Mount
{:ok, view, html} = live(conn, ~p"/path")

# Click elements
view
|> element("button#submit")
|> render_click()

view
|> element("a", "Link Text")
|> render_click()

view
|> element("button", "Delete")
|> render_click(%{"id" => "123"})

# Forms
view
|> form("#form-id", %{field: "value"})
|> render_change()

view
|> form("#form-id", %{field: "value"})
|> render_submit()

# Navigation
{:ok, conn} =
  view
  |> element("a", "Link")
  |> render_click()
  |> follow_redirect(conn)
assert_patch(view, ~p"/users/1/edit")
assert_redirect(view, ~p"/login")

# Element existence (prefer over HTML matching)
assert has_element?(view, "#item-1")
assert has_element?(view, "[data-role=name]", "Item 1")

# Async assigns (LiveView 0.20+)
html = render_async(view)

# Controller-delegated forms
conn = submit_form(form, conn)           # Form with :action attribute
conn = follow_trigger_action(form, conn)  # phx-trigger-action forms

# Server-push events
send(view.pid, {:update, %{count: 5}})
assert render(view) =~ "Count: 5"
```

## Property Testing (StreamData)

```elixir
use ExUnitProperties

property "name" do
  check all x <- integer(),
            y <- string(:ascii),
            max_runs: 100 do
    assert function(x, y)
  end
end
```

### Built-in Generators

| Generator | Produces |
|---|---|
| `integer()` | Any integer |
| `positive_integer()` | > 0 |
| `non_negative_integer()` | >= 0 |
| `float()` | Any float |
| `boolean()` | true/false |
| `atom(:alphanumeric)` | Random atom |
| `binary()` | Binary data |
| `string(:ascii)` | ASCII string |
| `string(:alphanumeric)` | a-z, A-Z, 0-9 |
| `string(:printable)` | Printable chars |
| `string([?a..?z])` | Custom range |
| `list_of(gen)` | List |
| `list_of(gen, min_length: 1)` | Non-empty list |
| `nonempty(list_of(gen))` | Guaranteed non-empty |
| `uniq_list_of(gen)` | No duplicates |
| `map_of(key_gen, val_gen)` | Map |
| `keyword_of(gen)` | Keyword list |
| `tuple({gen1, gen2})` | Tuple |
| `fixed_list([gen1, gen2])` | Fixed-length list |
| `one_of([gen1, gen2])` | Choice |
| `member_of([:a, :b])` | From list |
| `constant(value)` | Fixed value |
| `term()` | Any term |

### Generator Composition

```elixir
map(gen, fn x -> transform(x) end)        # Transform
filter(gen, fn x -> predicate(x) end)      # Filter (use sparingly)
bind(gen, fn x -> another_gen end)         # Dependent generation
tree(leaf, fn g -> one_of([list_of(g), map_of(key, g)]) end)  # Recursive

gen all x <- gen1, y <- gen2 do            # Multi-value generation
  {x, y}
end
```

## ExVCR HTTP Recording

```elixir
# mix.exs
{:exvcr, "~> 0.15", only: :test}

# Test module
use ExVCR.Mock, adapter: ExVCR.Adapter.Hackney  # or .Finch, .Httpc

# Record/replay HTTP calls
use_cassette "cassette_name" do
  {:ok, response} = HTTPoison.get("https://api.example.com/data")
  assert response.status_code == 200
end

# Stub mode (inline, no file)
use_cassette :stub, [url: "https://api.example.com/data", status_code: 200, body: "{}"] do
  # ...
end

# Filtering sensitive data
ExVCR.Config.filter_sensitive_data("Bearer [^\"]+", "Bearer ***")
ExVCR.Config.filter_request_headers("Authorization")

# Matching options
use_cassette "name", match_requests_on: [:query, :request_body] do ... end
```

### ExVCR vs Mox Decision Table

| Scenario | ExVCR | Mox |
|---|---|---|
| Test real API response structure | Yes | No |
| Contract/API verification | Yes | No |
| Fast isolated unit tests | No | Yes |
| Error handling logic | Both | Preferred |
| Performance-critical suites | No (slower) | Yes |
| Compile-time guarantees | No | Yes (behaviours) |
| Requires `async: false` | Yes | No (with private mode) |

## Wallaby Browser Testing

```elixir
# mix.exs
{:wallaby, "~> 0.30", only: :test, runtime: false}

# FeatureCase
defmodule MyAppWeb.FeatureCase do
  use ExUnit.CaseTemplate
  using do
    quote do
      use Wallaby.Feature
      import MyApp.Factory
      @endpoint MyAppWeb.Endpoint
    end
  end
  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
    unless tags[:async], do: Sandbox.mode(MyApp.Repo, {:shared, self()})
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(MyApp.Repo, self())
    {:ok, session} = Wallaby.start_session(metadata: metadata)
    {:ok, session: session}
  end
end

# Test
feature "user registers", %{session: session} do
  session
  |> visit("/register")
  |> fill_in(Query.text_field("Email"), with: "test@example.com")
  |> fill_in(Query.text_field("Password"), with: "secret123")
  |> click(Query.button("Register"))
  |> assert_has(Query.text("Welcome!"))
end
```

## Ecto Sandbox Modes

| Mode | How | When |
|---|---|---|
| `:manual` | Must explicitly checkout | Default in test_helper.exs |
| `:auto` | Auto-checkout on first query | Simple sync tests |
| `{:shared, pid}` | All processes share one connection | Non-async, LiveView, channels |

```elixir
# Modern pattern (Phoenix 1.7+)
pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: not tags[:async])
on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

# Allow spawned process
Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
```

## Common Commands

```bash
mix test                         # All tests
mix test path/file_test.exs      # Specific file
mix test path/file_test.exs:42   # Specific line
mix test --failed                # Re-run failed only
mix test --only slow             # Only tagged
mix test --exclude integration   # Exclude tagged
mix test --cover                 # With coverage
mix test --trace                 # Show test names
mix test --seed 123              # Reproducible ordering
mix test --max-failures 5        # Stop early
mix test --slowest 10            # Profile slow tests
mix test --stale                 # Only changed modules
```

## errors_on Helper

```elixir
def errors_on(changeset) do
  Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts
      |> Keyword.get(String.to_existing_atom(key), key)
      |> to_string()
    end)
  end)
end

# Usage
assert %{email: ["can't be blank"]} = errors_on(changeset)
assert "must be at least 8 characters" in errors_on(changeset).password
```

## Debugging Failing Tests

```bash
# Interactive debugging
MIX_ENV=test iex -S mix
iex -S mix test test/path_test.exs:42 --trace

# Verbose output
mix test --trace --max-failures 1
```

```elixir
# In test
IO.inspect(result, label: "debug")
require IEx; IEx.pry()
|> dbg()

# Async failure diagnosis
use MyApp.DataCase, async: false  # Temporarily disable async
```

### Common Async Failure Causes

| Symptom | Likely Cause | Fix |
|---|---|---|
| Passes alone, fails with others | Shared global state | Use `async: false` or isolate state |
| Random failures | Race condition | Use `assert_receive` instead of `Process.sleep` |
| DBConnection errors | Missing sandbox allow | `Sandbox.allow(Repo, self(), pid)` |
| Time-dependent failures | Wall-clock assertions | Use `assert_in_delta` with tolerance |
| Factory conflicts | Sequence collisions | Use `sequence/2` for unique fields |

## Test-Driven Development (TDD)

### Red-Green-Refactor Cycle

1. **Red** — Write a failing test that describes the desired behavior
2. **Green** — Write the minimum code to make the test pass
3. **Refactor** — Clean up while keeping tests green

```elixir
# Step 1: RED — Write the test first
defmodule MyApp.PricingTest do
  use ExUnit.Case, async: true

  describe "discount/2" do
    test "applies percentage discount" do
      assert MyApp.Pricing.discount(100_00, 0.10) == 90_00
    end

    test "clamps discount to item price (never negative)" do
      assert MyApp.Pricing.discount(50_00, 1.50) == 0
    end

    test "returns price unchanged for zero discount" do
      assert MyApp.Pricing.discount(75_00, 0.0) == 75_00
    end
  end
end

# Step 2: GREEN — Implement the minimum
defmodule MyApp.Pricing do
  @spec discount(non_neg_integer(), float()) :: non_neg_integer()
  def discount(price_cents, rate) when rate >= 0 do
    max(0, price_cents - round(price_cents * rate))
  end
end

# Step 3: REFACTOR — Extract, rename, optimize while tests stay green
```

### TDD Workflow with Mix

```bash
# Run only the test you're writing (fast feedback loop)
mix test test/my_app/pricing_test.exs:8

# Run tests affected by recent code changes
mix test --stale

# Watch mode (requires mix_test_watch)
mix test.watch

# Run with coverage to find untested paths
mix test --cover

# Run and stop at first failure
mix test --max-failures 1
```

### Doctest-Driven Development

> **Full doctest reference:** [documentation.md](documentation.md) — syntax (multi-line, exceptions, opaque values, ellipsis matching), `~S"""` sigil for interpolation, gotchas (map ordering, binding leaks, module persistence), when to use doctests vs unit tests, `doctest_file` for Markdown.

Write the doctest example first — it becomes both documentation and test:

```elixir
defmodule MyApp.Slug do
  @doc ~S"""
  Converts a string to a URL-safe slug.

  ## Examples

      iex> MyApp.Slug.from_string("Hello World!")
      "hello-world"

      iex> MyApp.Slug.from_string("  Elixir & OTP  ")
      "elixir-otp"

      iex> MyApp.Slug.from_string("")
      ""
  """
  @spec from_string(String.t()) :: String.t()
  def from_string(string) do
    string
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.trim()
    |> String.replace(~r/[\s_]+/, "-")
  end
end
```

### TDD Patterns for Elixir

**Outside-In TDD** — Start from the public context API, let failures guide you inward:

```elixir
# 1. Write context-level test first
test "register/1 creates user and sends welcome email" do
  Mox.expect(MyApp.Mailer.Mock, :send_welcome, fn %User{email: "a@b.com"} -> :ok end)
  assert {:ok, %User{email: "a@b.com"}} = Accounts.register(%{email: "a@b.com", password: "secret123"})
end

# 2. This test tells you exactly what Accounts.register/1 needs to do
# 3. Implement register/1, then write unit tests for any extracted helpers
```

**Property-Based TDD** — Define invariants first, then implement:

```elixir
# Write the property before the implementation
property "encode then decode is identity" do
  check all value <- term() do
    assert value ==
             value
             |> MyCodec.encode()
             |> MyCodec.decode()
  end
end

property "sort output is always ordered" do
  check all list <- list_of(integer()) do
    sorted = MySort.sort(list)
    assert sorted == Enum.sort(list)
    assert length(sorted) == length(list)
  end
end
```

### When to Write Tests First vs After

| Write tests FIRST | Write tests AFTER |
|---|---|
| Bug fixes — reproduce the bug as a test | Exploratory prototyping (spike) |
| New public API functions | UI/LiveView layout changes |
| Business logic with clear rules | One-off scripts |
| Anything with edge cases | Performance optimizations (benchmark instead) |
| Refactoring (write characterization tests) | |

### TDD Anti-Patterns

```elixir
# BAD — Testing implementation details
test "calls Repo.insert" do
  # Brittle: breaks when you refactor internals
end

# GOOD — Testing behavior
test "persists the user and returns {:ok, user}" do
  assert {:ok, %User{id: id}} = Accounts.register(@valid_attrs)
  assert Repo.get(User, id)
end

# BAD — Writing the implementation, then reverse-engineering tests
# Tests become tautological — they just assert what the code already does

# GOOD — Tests describe WHAT should happen, code describes HOW
# If you write tests after, pretend the implementation doesn't exist
```

## Related Files

- **[SKILL.md](SKILL.md)** — 12 testing rules, ExUnit fundamentals, Mox pattern, key assertions
- **[testing-examples.md](testing-examples.md)** — Complete examples: CaseTemplate, Ecto Sandbox, Mox patterns, LiveView testing, property-based testing, Oban, OTP process testing
- **[production.md](production.md)** — Production telemetry patterns (complements telemetry testing)
- **[ecto-reference.md](ecto-reference.md)** — Changeset and query patterns (tested via DataCase)
