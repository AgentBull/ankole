# Elixir Language Patterns — Deep Dive

> Supporting reference for the [Elixir skill](SKILL.md). Contains extended pattern matching, guards, comprehensions, pipelines, behaviours, protocols, streams, error handling, and advanced patterns. Core patterns and rules are in [SKILL.md](SKILL.md) — this file covers additional depth, edge cases, and extended examples. See also: [code-style.md](code-style.md), [documentation.md](documentation.md).

## Pattern Matching (extended)

> Core pattern matching (multi-clause, tagged tuples, head/tail, pin, guards, case/cond, match?/2) is in [SKILL.md](SKILL.md). This section covers additional patterns and edge cases.

### Pattern-Based Dispatch

```elixir
defmodule Formatter do
  # Specific patterns first
  def format(%Date{} = date), do: Calendar.strftime(date, "%Y-%m-%d")
  def format(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  def format(%Time{} = time), do: Calendar.strftime(time, "%H:%M:%S")

  # Fallback last
  def format(value) when is_binary(value), do: value
  def format(value), do: to_string(value)
end
```

### Default Arguments with Multi-Clause

```elixir
# Header clause defines defaults
def paginate(query, opts \\ [])
def paginate(query, opts) do
  page = Keyword.get(opts, :page, 1)
  per_page = Keyword.get(opts, :per_page, 20)

  query
  |> limit(^per_page)
  |> offset(^((page - 1) * per_page))
end
```

### String Prefix Matching

```elixir
# String prefix matching with <>
def join("room:" <> room_id, _payload, socket), do: ...  # Phoenix Channel pattern
def parse("Bearer " <> token), do: {:ok, token}
def parse(_), do: {:error, :invalid_scheme}
# NOTE: <> can ONLY match prefixes, not suffixes. Use String.ends_with?/2 for suffixes.
```

### Extracting Nested Data

```elixir
def get_user_city(%{address: %{city: city}}), do: {:ok, city}
def get_user_city(_), do: {:error, :no_city}

# With default
def get_user_city(%{address: %{city: city}}), do: city
def get_user_city(%{address: _}), do: "Unknown"
def get_user_city(_), do: "No address"
```

### Binary Pattern Matching

```elixir
# Parse fixed-width fields
def parse_record(<<
  id::binary-size(8),
  _separator::binary-size(1),
  name::binary-size(20),
  _rest::binary
>>) do
  %{id: String.trim(id), name: String.trim(name)}
end

# Parse UTF-8 characters
def first_char(<<char::utf8, _rest::binary>>), do: <<char::utf8>>
def first_char(""), do: ""
```

### Map Updates

```elixir
def increment_count(%{count: count} = state) do
  %{state | count: count + 1}
end

# With nested update
def update_user_email(state, user_id, email) do
  update_in(state, [:users, user_id, :email], fn _ -> email end)
end
```

### Assertive Pattern Matching

Let functions crash on unexpected input — makes bugs visible immediately:

```elixir
# BAD - hides malformed input, returns wrong value
def get_value(string, key) do
  parts = String.split(string, "&")
  Enum.find_value(parts, fn pair ->
    key_value = String.split(pair, "=")
    Enum.at(key_value, 0) == key && Enum.at(key_value, 1)
  end)
end

# GOOD - pattern match asserts structure, crashes on malformed input
def get_value(string, key) do
  Enum.find_value(String.split(string, "&"), fn pair ->
    [k, value] = String.split(pair, "=")
    k == key && value
  end)
end

# GOOD - extract only what guard needs, destructure in body
def drive(%User{age: age} = user) when age >= 18 do
  %User{name: name, license: license} = user
  "#{name} with license #{license} can drive"
end
```

### Pin Operator (^) — Advanced Uses

```elixir
# Pin as map key — essential for dynamic key lookup
key = :email
case map do
  %{^key => value} -> {:ok, value}   # Without ^, key would rebind!
  _ -> :error
end

# Double pin — assert both key AND value exist
%{^key => ^value} = map  # Crashes if key missing or value differs

# Pin in receive — correlate async responses (the definitive use case)
ref = make_ref()
send(server, {self(), ref, :request})
receive do
  {^ref, {:ok, result}} -> result    # Only matches OUR response
  {^ref, {:error, reason}} -> raise reason
end

# Pin in case with nested maps
case state.channels do
  %{^pid => {^topic, join_ref}} -> handle_existing(join_ref)
  %{^pid => _} -> handle_wrong_topic()
  _ -> handle_new()
end

# Pin in comprehension generators
target = 42
for %{id: ^target, data: data} <- records, do: data

# Pin in with clauses
expected = "admin"
with %{role: ^expected} <- get_user(id) do
  :authorized
end
```

### Nested Destructuring

```elixir
# 2-level deep — struct inside tuple
{%User{__meta__: %Ecto.Schema.Metadata{}}, _opts} = arg

# 2-level deep — map inside struct, binding both levels
def process(%JoinExpr{source: %Ecto.Query{} = subquery, qual: qual} = join) do
  {join, subquery, qual}
end

# Destructure accumulator + data in one function head
defp on_change(
  %{cardinality: :one, field: field} = meta,          # meta struct
  %{action: action, data: current} = changeset,        # changeset struct
  {parent, changes, halt, valid?}                       # tuple accumulator
) do
  ...
end

# Matching on __struct__ for dynamic struct dispatch
def primary_key(%{__struct__: schema} = struct) do
  schema.__schema__(:primary_key)
end
```

### match?/2 — Boolean Pattern Matching

```elixir
# Use match?/2 when you only need true/false, not extracted values
Enum.filter(items, &match?({:ok, _}, &1))
Enum.all?(values, &match?(%{__struct__: ^schema}, &1))
if match?({:error, _}, result), do: log_error(result)

# match? with guards
match?({in_type, _} when in_type in [:in, :one_of], config[:type])

# Use case when you need the matched values
case result do
  {:ok, value} -> use(value)      # Need value — use case
  {:error, _} -> handle_error()
end
```

### Multi-Clause Anonymous Functions

```elixir
# In Enum.reduce — different clauses for different data shapes
Enum.reduce(subscribers, %{}, fn
  {pid, _}, cache when pid == sender ->
    cache                                    # Skip sender
  {pid, {:fastlane, fast_pid, serializer}}, cache ->
    send(fast_pid, serialize(serializer))    # Fastlane delivery
    cache
  {pid, _}, cache ->
    send(pid, msg)                           # Normal delivery
    cache
end)

# In Task.async_stream result handling
|> Enum.map(fn
  {:ok, result} -> result
  {:exit, :timeout} -> :timed_out
end)
```

### Exception Pattern Matching

```elixir
# Rescue specific exception types
try do
  risky_operation()
rescue
  e in ArgumentError -> {:error, e.message}           # Bind + type
  e in [KeyError, UndefinedFunctionError] -> handle(e) # Multiple types
  _ in RuntimeError -> :runtime_error                  # Type only, ignore value
end

# catch vs rescue — catch matches throws (not exceptions)
try do
  Torque.decode!(data)
catch
  {:position, pos} -> {:error, %{position: pos}}     # Thrown values
  :throw, value -> {:error, value}                     # Explicit kind
end
```

### Pattern Matching in receive

```elixir
# Selective receive with pinned reference — request/response correlation
def call(server, request, timeout) do
  ref = make_ref()
  mon = Process.monitor(server)
  send(server, {:"$call", {self(), ref}, request})
  receive do
    {^ref, reply} ->
      Process.demonitor(mon, [:flush])
      reply
    {:DOWN, ^mon, _, _, reason} ->
      exit(reason)
  after
    timeout -> exit(:timeout)
  end
end

# Non-blocking drain — after 0 returns immediately if no match
def drain_mailbox(acc \\ []) do
  receive do
    msg -> drain_mailbox([msg | acc])
  after
    0 -> Enum.reverse(acc)
  end
end
```

## Guards (extended)

> Core guard patterns, allowed expressions, custom guards, and `in`/multiple `when` are in [SKILL.md](SKILL.md). This section covers additional examples.

```elixir
# Combined guard with pattern match
def valid_user?(%{age: age, active: active}) when age >= 18 and active == true, do: true
def valid_user?(_), do: false

# Type-safe operations — guard all inputs
def divide(a, b) when is_number(a) and is_number(b) and b != 0, do: a / b
def divide(_, 0), do: {:error, :division_by_zero}
def divide(_, _), do: {:error, :invalid_arguments}

# Guards in case (not just function heads)
def categorize(value) do
  case value do
    n when is_integer(n) and n < 0 -> :negative
    0 -> :zero
    n when is_integer(n) and n > 0 -> :positive
    f when is_float(f) -> :float
    _ -> :other
  end
end

# Additional Bitwise guards (beyond core list)
# Bitwise.&&&, Bitwise.|||, Bitwise.bsl, Bitwise.bsr also allowed in guards
```

## case and cond (extended)

> Basic case/cond patterns are in [SKILL.md](SKILL.md). This section covers advanced usage.

**cond with variable binding** — assign in condition, use in body:

```elixir
# Priority-based config resolution (from Absinthe)
cond do
  executor = Keyword.get(opts, :executor) ->
    executor

  executor = get_in(opts, [:context, :streaming_executor]) ->
    executor

  schema && function_exported?(schema, :__streaming_executor__, 0) ->
    schema.__streaming_executor__()

  executor = Application.get_env(:my_app, :executor) ->
    executor

  true ->
    DefaultExecutor
end

# Only/except option handling (from selective encoder options)
cond do
  only = Keyword.get(opts, :only) ->
    validate_fields!(only, fields, ":only")
    only

  except = Keyword.get(opts, :except) ->
    validate_fields!(except, fields, ":except")
    fields -- [:__struct__ | except]

  true ->
    fields -- [:__struct__]
end
```

**cond for capability detection** — graceful degradation:

```elixir
cond do
  Code.ensure_loaded?(FastModule) -> FastModule
  Code.ensure_loaded?(FallbackModule) -> FallbackModule
  true -> DefaultModule
end
```

**cond for range/threshold branching:**

```elixir
# Format time values (from Credo)
cond do
  time > 1_000_000 -> "#{div(time, 1_000_000)}s"
  time > 1_000 -> "#{div(time, 1_000)}ms"
  true -> "#{time}μs"
end
```

**When to use cond vs case vs multi-clause:**

| Use | When |
|-----|------|
| `case` | Matching on ONE value's shape/pattern |
| `cond` | Multiple DIFFERENT boolean expressions |
| Multi-clause | Function dispatches on argument patterns |
| `with` | Chaining operations that may fail |

**cond is best for:** priority fallback chains, range/threshold checks, binding-in-condition patterns, and situations where each branch tests a completely different expression.

## The With Statement (extended)

> Basic `with` pattern is in [SKILL.md](SKILL.md). This shows the full helper function pattern:

```elixir
defmodule MyApp.Orders do
  def create_order(user_id, cart_id, payment_method) do
    with {:ok, user} <- fetch_user(user_id),
         {:ok, cart} <- fetch_cart(cart_id, user),
         :ok <- validate_cart(cart),
         {:ok, charge} <- process_payment(cart, payment_method),
         {:ok, order} <- insert_order(user, cart, charge) do
      send_confirmation(user, order)
      {:ok, order}
    else
      {:error, :user_not_found} ->
        {:error, "User not found"}

      {:error, :cart_not_found} ->
        {:error, "Cart not found or doesn't belong to user"}

      {:error, :empty_cart} ->
        {:error, "Cannot create order with empty cart"}

      {:error, :payment_failed, reason} ->
        Logger.error("Payment failed: #{reason}")
        {:error, "Payment failed: #{reason}"}

      {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
        {:error, changeset}
    end
  end

  defp fetch_user(id) do
    case Repo.get(User, id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp fetch_cart(cart_id, user) do
    case Repo.get_by(Cart, id: cart_id, user_id: user.id) do
      nil -> {:error, :cart_not_found}
      cart -> {:ok, Repo.preload(cart, :items)}
    end
  end

  defp validate_cart(%{items: []}), do: {:error, :empty_cart}
  defp validate_cart(_cart), do: :ok

  defp process_payment(cart, payment_method) do
    case PaymentGateway.charge(cart.total, payment_method) do
      {:ok, charge} -> {:ok, charge}
      {:error, reason} -> {:error, :payment_failed, reason}
    end
  end
end
```

## Imperative to Elixir Translation

**Collection Operations:**

| Imperative | Elixir |
|---|---|
| `for (x of list) result.push(f(x))` | `Enum.map(list, &f/1)` |
| `for (x of list) if (p(x)) result.push(x)` | `Enum.filter(list, &p/1)` |
| `let acc = init; for (...) acc = f(acc, x)` | `Enum.reduce(list, init, fn x, acc -> ... end)` |
| `list.find(x => p(x))` | `Enum.find(list, &p/1)` |
| `list.some(x => p(x))` | `Enum.any?(list, &p/1)` |
| `list.flatMap(x => f(x))` | `Enum.flat_map(list, &f/1)` |
| `[...set]` (deduplicate) | `Enum.uniq(list)` or `Enum.uniq_by(list, &key/1)` |
| `list.sort((a,b) => a.name - b.name)` | `Enum.sort_by(list, & &1.name)` |
| `Object.groupBy(list, x => x.type)` | `Enum.group_by(list, & &1.type)` |
| `_.countBy(list, f)` | `Enum.frequencies_by(list, &f/1)` |
| `_.chunk(list, 3)` | `Enum.chunk_every(list, 3)` |
| `_.partition(list, pred)` | `Enum.split_with(list, &pred/1)` |
| `list.join(", ")` | `Enum.join(list, ", ")` |
| `Math.max(...list)` | `Enum.max(list)` |
| `list.reduce((a, b) => a + b, 0)` | `Enum.sum(list)` |

**Control Flow:**

| Imperative | Elixir |
|---|---|
| `if/else if/else` | Multi-clause function with pattern matching |
| `switch (x.type)` | `case x.type do ... end` or multi-clause function |
| `if (x != null && x.active)` | `def f(%{active: true} = x)` (pattern match) |
| `try { risky() } catch(e) { ... }` | `case risky() do {:ok, v} -> v; {:error, _} -> fallback end` |
| `for (...) { if (done) break }` | `Enum.reduce_while(list, acc, fn x, acc -> {:cont/:halt, acc} end)` |
| `while (cond) { ... }` | Recursive function with guard or `Stream.iterate/2` |
| `early return` | Pattern match + multiple function clauses |

**Data Mutation:**

| Imperative | Elixir |
|---|---|
| `obj.key = value` | `%{map \| key: value}` or `Map.put(map, key, value)` |
| `obj.a.b.c = value` | `put_in(obj, [:a, :b, :c], value)` |
| `obj.count++` | `update_in(obj, [:count], & &1 + 1)` |
| `delete obj.key` | `Map.delete(map, key)` |
| `list.push(item)` | `[item \| list]` (prepend — O(1)) |
| `list.pop()` | `[head \| tail] = list` (pattern match) |
| `set.add(item)` | `MapSet.put(set, item)` |
| `str += chunk` in loop | IO list: `[chunk \| acc]`, then `IO.iodata_to_binary/1` |
| `"Hello " + name + "!"` | `"Hello #{name}!"` (interpolation) |
| `result = ""; for (x) result += f(x)` | `Enum.map_join(items, ", ", &f/1)` |
| `x ?? default` | `x \|\| default` (beware: also catches `false`) |
| `x?.y?.z` | `get_in(x, [:y, :z])` |

## Pipeline Best Practices (extended)

> Core pipeline patterns are in [SKILL.md](SKILL.md). This section covers additional techniques.

```elixir
# Design functions data-first so they compose in pipelines
defmodule StringHelpers do
  def normalize(string) do
    string
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end
  def truncate(string, max) when byte_size(string) <= max, do: string
  def truncate(string, max), do: String.slice(string, 0, max - 3) <> "..."
end

input
|> StringHelpers.normalize()
|> StringHelpers.truncate(100)

# Break long pipelines into named private functions
def process_orders(orders) do
  orders
  |> filter_valid()
  |> calculate_totals()
  |> apply_discounts()
  |> generate_invoices()
end

defp filter_valid(orders) do
  orders
  |> Enum.filter(&valid_order?/1)
  |> Enum.reject(&cancelled?/1)
end
defp calculate_totals(orders), do: Enum.map(orders, &%{&1 | total: calculate_order_total(&1)})

# Conditional steps — use maybe_ helpers to keep pipeline flat
data
|> transform()
|> maybe_validate(opts[:validate])
|> finalize()

defp maybe_validate(data, true), do: validate(data)
defp maybe_validate(data, _), do: data

# Or with then/1 for inline conditionals
data
|> transform()
|> then(fn d -> if opts[:validate], do: validate(d), else: d end)

# ok/error pipeline — chain with pattern-matching helpers
defp authorize(user, action) do
  user
  |> check_role(action)
  |> check_permissions(action)
  |> check_rate_limit()
end

defp check_role(%{role: :admin} = user, _action), do: {:ok, user}
defp check_role(%{role: :user} = user, :read), do: {:ok, user}
defp check_role(_, action), do: {:error, {:unauthorized, action}}

defp check_permissions({:ok, user}, action), do: Permissions.verify(user, action)
defp check_permissions(error, _action), do: error

defp check_rate_limit({:ok, user}), do: RateLimiter.check(user)
defp check_rate_limit(error), do: error
```

### tap/1 and then/1 — Pipeline Utilities

```elixir
# tap/1 — execute a side effect, returns the ORIGINAL value (not the tap result)
order
|> calculate_total()
|> tap(&Logger.debug("Total: #{&1}"))  # Returns order total, not Logger's :ok
|> apply_tax()

# BAD: expecting tap to transform the value
data |> tap(&String.upcase/1)  # Returns original data, NOT uppercased!

# GOOD: use then/1 when you need the transformed value
data |> then(&String.upcase/1)  # Returns uppercased data

# then/1 — transform with a function (useful for non-pipeable APIs)
user_id
|> fetch_user()
|> then(fn {:ok, user} -> send_email(user); {:error, _} = err -> err end)

# then/1 for wrapping non-pipe-friendly calls
config
|> Map.get(:timeout, 5000)
|> then(&Process.send_after(self(), :check, &1))
```

### dbg/2 — Pipeline Debugging (Elixir 1.14+)

```elixir
# dbg at the end of a pipeline shows each step with intermediate values
[1, 2, 3]
|> Enum.map(&(&1 * 2))
|> Enum.filter(&(&1 > 2))
|> dbg()
# Output shows: [1, 2, 3] |> Enum.map(...) #=> [2, 4, 6] |> Enum.filter(...) #=> [4, 6]

# dbg on any expression
x = compute_value()
dbg(x)  # Prints: x #=> <value> with file:line

# Make dbg use IEx.pry for interactive debugging
# iex --dbg pry -S mix

# BAD: leaving dbg in production code — always remove after debugging
# GOOD: use tap(&IO.inspect(&1, label: "...")) for permanent debug logging
```

## For Comprehensions (full)

Single-pass iteration with filtering and collection — more efficient than pipelines for complex transformations:

```elixir
# Basic with filtering (conditions after <-)
for line <- File.stream!("config.txt"), line != "", String.contains?(line, "=") do
  String.split(line, "=", parts: 2)
end
```

**Pattern matching in generators** — non-matching elements are silently skipped (no error):

```elixir
# Only process successful results — {:error, _} tuples silently skipped
for {:ok, val} <- results, do: val

# Destructure nested data
for {_key, %{name: name, active: true}} <- users_map, do: name

# Filter nil values while building a map (from Logger stdlib)
for {_k, v} = elem <- keyword, v != nil, into: %{}, do: elem
```

**Collect into different types with `into:`**

```elixir
# Into a map
for {k, v} <- [a: 1, b: 2], into: %{} do
  {k, v * 2}
end
# => %{a: 2, b: 4}

# Into a MapSet (from Mix xref — collect modules from multiple apps)
for app <- apps,
    module <- Application.spec(app, :modules),
    into: MapSet.new(),
    do: module

# Into a string
for c <- ?a..?z, into: "", do: <<c>>
# => "abcdefghijklmnopqrstuvwxyz"
```

**Binary comprehensions** — iterate bytes/bits of a binary:

```elixir
# URL encoding (from URI stdlib)
for <<byte <- string>>, into: "" do
  case percent(byte, &char_unreserved?/1) do
    "%20" -> "+"
    percent -> percent
  end
end

# Strip whitespace from base64 (from Base stdlib)
for <<char::8 <- string>>, char not in ~c"\s\t\r\n", into: <<>>, do: <<char::8>>

# Multi-byte binary parsing
for <<c1::8, c2::8 <- data>>, into: <<>> do
  <<decode(c1)::4, decode(c2)::4>>
end
```

**Accumulator control with `reduce:`**

```elixir
# Simple accumulator
for line <- File.stream!("data.csv"), reduce: %{totals: 0, count: 0} do
  acc ->
    value =
      line
      |> String.trim()
      |> String.to_integer()
    %{acc | totals: acc.totals + value, count: acc.count + 1}
end

# Tuple accumulator — partition fields (from Ecto schema)
for {name, {_, writable}} <- fields, reduce: {[], []} do
  {keep, drop} ->
    case writable do
      :always -> {[name | keep], drop}
      _ -> {keep, [name | drop]}
    end
end

# Process options while building state (from Absinthe)
for key <- @packed_keys, reduce: {options, reverse_map} do
  {options, reverse_map} ->
    value = Keyword.get(options, key, %{})
    if value == %{} do
      {options, reverse_map}
    else
      {packed, reverse_map} = pack_value(value, reverse_map)
      {Keyword.put(options, key, packed), reverse_map}
    end
end
```

**`:uniq` option** — deduplicate results inline:

```elixir
# Collect unique formatter options from dependencies (from Mix)
for dep <- deps,
    dep_opts = eval_formatter(dep),
    parenless_call <- dep_opts[:export][:locals_without_parens] || [],
    uniq: true,
    do: parenless_call

# Collect unique type variables
for type_expr <- args, var <- collect_vars(type_expr), uniq: true, do: var
```

**Multiple generators** (Cartesian product):

```elixir
for x <- 1..3, y <- 1..3, x <= y do
  {x, y}
end
# => [{1,1}, {1,2}, {1,3}, {2,2}, {2,3}, {3,3}]

# Nested generators with filter (from Mox — generate mock functions)
for behaviour <- behaviours,
    {fun, arity} <- behaviour.behaviour_info(:callbacks),
    {fun, arity} not in callbacks_to_skip do
  define_mock(fun, arity)
end
```

**When to prefer `for` over pipelines:**
- Pattern matching silently filters (no `Enum.filter` needed)
- Building maps/MapSets/strings (`into:`)
- Complex accumulation with tuple state (`reduce:`)
- Multiple generators with cross-product
- Binary iteration (`<<byte <- binary>>`)
- Deduplication needed (`:uniq`)

**When to prefer `Enum` pipeline over `for`:**
- Simple map/filter/reduce on a single collection
- Need lazy evaluation (`Stream`)
- Readability with named pipeline steps

### More `reduce:` Patterns

```elixir
# reduce: with struct accumulator — event sourcing style
for event <- events, reduce: %OrderState{} do
  state -> OrderState.apply(state, event)
end

# Nested generators with reduce — build adjacency list
for {from, tos} <- edge_list, to <- tos, reduce: %{} do
  acc -> Map.update(acc, from, [to], &[to | &1])
end

# Counting with pattern filter — only count matching elements
for %{status: :active} <- users, reduce: 0 do
  count -> count + 1
end

# Recursive key-value transform with into: (from Plug SnakeCaseParams)
defp convert(params) when is_map(params) do
  for {key, value} <- params, into: %{}, do: {Macro.underscore(key), convert(value)}
end
defp convert(params) when is_list(params), do: for(value <- params, do: convert(value))
defp convert(value), do: value
```

## Advanced Reduce Patterns

Production patterns from Ecto, Phoenix LiveView, and Plug.

**Multi-accumulator reduce** — process a collection while tracking multiple concerns:

```elixir
# Tuple accumulator — partition in a single pass (from Ecto changeset)
{changes, errors, valid?} =
  Enum.reduce(new_changes, {old_changes, [], true}, fn
    {key, value}, {changes, errors, valid?} ->
      case validate(key, value) do
        :ok -> {Map.put(changes, key, value), errors, valid?}
        {:error, msg} -> {changes, [{key, msg} | errors], false}
      end
  end)

# Simpler example — separate odds and evens
{evens, odds} = Enum.reduce(numbers, {[], []}, fn n, {e, o} ->
  if rem(n, 2) == 0, do: {[n | e], o}, else: {e, [n | o]}
end)
# Note: prefer Enum.split_with/2 for this specific case
```

**`Enum.reduce_while/3` with complex state** — validation with error accumulation, halt on fatal:

```elixir
# Validate config keys against allowed set — halt on first unknown key
Enum.reduce_while(config, :ok, fn {key, _value}, :ok ->
  if key in allowed_keys,
    do: {:cont, :ok},
    else: {:halt, {:error, {:unknown_key, key}}}
end)

# Process items with budget — stop when budget exhausted
Enum.reduce_while(items, {[], budget}, fn item, {processed, remaining} ->
  cost = compute_cost(item)
  if cost <= remaining do
    {:cont, {[process(item) | processed], remaining - cost}}
  else
    {:halt, {Enum.reverse(processed), remaining}}
  end
end)
```

**`Enum.map_reduce/3`** — transform elements while threading an accumulator (from Ecto query builder):

```elixir
# Transform list while accumulating parameters (from Ecto.Query.Builder)
{escaped_exprs, params_acc} =
  Enum.map_reduce(expressions, params_acc, fn expr, params ->
    {escaped, new_params} = escape(expr, type, params, vars, env)
    {escaped, new_params}
  end)

# Assign sequential IDs while transforming
{items_with_ids, next_id} =
  Enum.map_reduce(items, 1, fn item, id ->
    {Map.put(item, :id, id), id + 1}
  end)

# Build indexed output while tracking state
{lines, _line_num} =
  Enum.map_reduce(paragraphs, 1, fn para, line ->
    formatted = "#{line}: #{para}"
    {formatted, line + String.length(para)}
  end)
```

**`Enum.flat_map_reduce/3`** — emit 0..N results per element while threading state (from Phoenix LiveView):

```elixir
# Delete components while accumulating state changes
{deleted_cids, new_state} =
  Enum.flat_map_reduce(cids, state, fn cid, acc ->
    {deleted, components} = delete_component(cid, acc.components)
    {deleted, %{acc | components: components}}
  end)
```

**Building maps/keyword lists with reduce** — pipeline assembly (from Plug.Builder):

```elixir
# Build nested AST by reducing over plug pipeline
ast = Enum.reduce(pipeline, conn_var, fn {plug, opts, guards}, acc ->
  quote_plug({plug, opts, guards}, acc)
end)

# Build keyword list conditionally
opts = Enum.reduce([timeout: t, retries: r, verbose: v], [], fn
  {_key, nil}, acc -> acc          # Skip nil values
  {key, value}, acc -> [{key, value} | acc]
end)
```

**`Enum.scan/3`** — like reduce but emits every intermediate accumulator value:

```elixir
# Running totals
Enum.scan([10, 20, 30, 40], 0, &(&1 + &2))
#=> [10, 30, 60, 100]

# State evolution tracking — useful for debugging event-sourced systems
states = Enum.scan(events, initial_state, &apply_event/2)
# => [state_after_event_1, state_after_event_2, ...]
```

> **Note:** `Enum.scan` is rarely used in production Elixir — most code needs only the
> final result (`Enum.reduce`) or uses streams for lazy intermediate values (`Stream.scan`).

## Functional State Module Pattern

Pure struct module that encapsulates domain logic, embedded as GenServer state. The "functional core, imperative shell" pattern — domain logic in pure functions, I/O and process management in GenServer.

Pattern sources: Commanded aggregates, Kevin Hoffman's "Functional Core" pattern, Tyler Young's GenServer testability article.

```elixir
# Functional core — pure module, no process, no side effects
defmodule MyApp.Router do
  @moduledoc false
  defstruct peers: %{}, routes: %{}

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  def add_peer(%__MODULE__{} = router, peer_id, conn_pid) do
    route = %{via: :direct, conn_pid: conn_pid, hops: 0}
    %{router | peers: Map.put(router.peers, peer_id, route)}
  end

  def remove_peer(%__MODULE__{} = router, peer_id) do
    # Pure transformation — returns new router, no side effects
    peers = Map.delete(router.peers, peer_id)
    # Also remove routes that go through this peer
    routes = Map.reject(router.routes, fn {_dest, route} -> route.via == peer_id end)
    %{router | peers: peers, routes: routes}
  end

  def find_route(%__MODULE__{} = router, destination) do
    case Map.fetch(router.routes, destination) do
      {:ok, route} -> {:ok, route}
      :error -> {:error, :no_route}
    end
  end
end

# Imperative shell — GenServer holds the struct, handles I/O
defmodule MyApp.Node do
  use GenServer

  defstruct [:router, :listener]

  @impl true
  def init(opts) do
    # Domain state is a field in GenServer state
    {:ok, %__MODULE__{router: MyApp.Router.new()}}
  end

  @impl true
  def handle_info({:peer_connected, peer_id, conn_pid}, state) do
    # Delegate domain logic to pure function
    router = MyApp.Router.add_peer(state.router, peer_id, conn_pid)
    {:noreply, %{state | router: router}}
  end

  def handle_info({:peer_disconnected, peer_id}, state) do
    router = MyApp.Router.remove_peer(state.router, peer_id)
    {:noreply, %{state | router: router}}
  end
end
```

**Testing advantage — no process setup needed for domain logic:**

```elixir
# Test the functional core directly — fast, deterministic, no async
test "remove_peer cascades to routes" do
  router =
    Router.new()
    |> Router.add_peer("A", self())
    |> Router.add_peer("B", self())
    |> Router.remove_peer("A")

  assert map_size(router.peers) == 1
  refute Map.has_key?(router.peers, "A")
end

# GenServer test only verifies wiring — thin layer
test "node handles peer disconnect" do
  {:ok, pid} = GenServer.start_link(MyApp.Node, [])
  send(pid, {:peer_connected, "A", self()})
  send(pid, {:peer_disconnected, "A"})
  # Assert on GenServer state if needed
end
```

**When to use this pattern:**
- Domain logic is complex enough to benefit from isolated testing
- Multiple GenServers need the same domain logic (share the struct module)
- You want to separate "what happens" (pure) from "when/where it happens" (process)

**When NOT to use:**
- Simple GenServer with trivial state — just put the logic in callbacks
- State transformations are one-liners — the indirection isn't worth it

## Syntax Equivalences — Why Elixir Code Looks Different

Elixir has three syntax features that combine to make the same code look very different depending on style. All forms below produce **identical AST** — the compiler sees no difference.

### 1. Optional Parentheses

Parentheses are optional on function calls with arguments:

```elixir
# These are identical:
IO.puts("hello")
IO.puts "hello"

length([1, 2, 3])
length [1, 2, 3]
```

**Exception:** Zero-arity calls require parentheses to distinguish from variables — `node()` calls the function, `node` references a variable.

### 2. Keyword List Representations

Keyword lists are lists of `{atom, value}` tuples. Elixir provides several layers of sugar — all forms below are identical at the AST level:

```elixir
# Level 1: Explicit tuple list
[{:name, "Alice"}, {:age, 30}]

# Level 2: Keyword sugar (colon moves to end of atom)
[name: "Alice", age: 30]

# Level 3: Brackets optional as last function argument
String.split("a b c", " ", parts: 2, trim: true)
String.split("a b c", " ", [{:parts, 2}, {:trim, true}])

# Quoted atom keys (for atoms with special characters)
["my-key": value]          # sugar for [{:"my-key", value}]
["with spaces": value]     # sugar for [{:"with spaces", value}]
```

**Keyword lists vs map atom-key sugar** — the same `key: value` notation appears in maps too, but means something different:

```elixir
# Keyword list — list of tuples, ordered, allows duplicate keys
[a: 1, b: 2]              # == [{:a, 1}, {:b, 2}]

# Map with atom keys — hash map, unordered, unique keys
%{a: 1, b: 2}             # == %{:a => 1, :b => 2}
```

### 3. `do/end` Blocks as Keyword Lists

`do/end` blocks are syntactic sugar for `do:` keyword arguments. The block keywords (`do`, `else`, `rescue`, `catch`, `after`) become keyword list keys:

```elixir
# All three are identical:

# do/end block style
if condition do
  :yes
else
  :no
end

# Keyword style
if(condition, do: :yes, else: :no)

# Explicit tuple list
if(condition, [{:do, :yes}, {:else, :no}])
```

### Combined — DSL Syntax Explained

These three features combine to enable DSL-style code (used by Ash, Ecto, Phoenix, etc.). All forms below compile to the same AST:

```elixir
# DSL style (no parens, do/end block) — common in Ash, Ecto migrations
attribute :name, :string do
  allow_nil? false
end

# Keyword style (no parens, trailing keyword list)
attribute :name, :string, allow_nil?: false

# Fully explicit (parens, bracketed keyword list)
attribute(:name, :string, [allow_nil?: false])
```

Another example with `schema` and `field`:

```elixir
# Ecto DSL style
schema "users" do
  field :email, :string
  timestamps()
end

# Desugared — what the compiler actually sees
schema("users", [do: (
  field(:email, :string)
  timestamps()
)])
```

**Why this matters for LLMs:** When generating code for frameworks like Ash, Phoenix, or Ecto, use the DSL style (no parentheses, `do/end` blocks) to match community conventions. When writing regular application code, use parentheses for clarity.

## Function References & Capture

```elixir
# Capture operator (&)
&Module.function/arity          # Reference to named function
&(&1 + 1)                      # Short anonymous function (one arg)
&(&1 + &2)                     # Multiple args
&{&1, &2}                      # Returns tuple

# When to use which:
# Named function reference - prefer when function already exists
Enum.map(list, &String.upcase/1)
Enum.filter(list, &valid?/1)

# Short capture - prefer for simple one-liners
Enum.map(list, & &1 * 2)
Enum.filter(list, & &1 > 0)

# Full anonymous function - prefer for multi-line or pattern matching
Enum.map(list, fn %{name: name, age: age} ->
  "#{name} is #{age}"
end)

# Common captures
&to_string/1                    # Kernel.to_string
&is_nil/1                       # Kernel.is_nil
&elem(&1, 0)                    # Get first tuple element
&(&1)                           # Identity function
```

## @enforce_keys — Struct Construction Safety

```elixir
defmodule MyApp.Config do
  @enforce_keys [:name, :adapter]
  defstruct [:name, :adapter, timeout: 5000, retries: 3]

  @type t :: %__MODULE__{
    name: atom(),
    adapter: module(),
    timeout: pos_integer(),
    retries: non_neg_integer()
  }

  # Constructor validates and normalizes
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)  # Raises if @enforce_keys missing
  end
end

# struct!/2 raises ArgumentError on missing enforced keys
MyApp.Config.new(name: :cache)  # ** (ArgumentError) the following keys must also be given: [:adapter]

# BAD: using %MyApp.Config{} directly — bypasses enforcement in some contexts
# GOOD: always use the new/1 constructor from outside the module
```

## Behaviours, Callbacks & @impl

### Rules for Behaviours (LLM)

1. **ALWAYS use `@impl true`** on every callback implementation — catches typos and missing callbacks at compile time
2. **Once you use `@impl` on ANY callback, you MUST use it on ALL callbacks** — the compiler warns about inconsistency
3. **Use `@impl BehaviourModule`** (not `@impl true`) when implementing multiple behaviours with overlapping callback names
4. **ALWAYS name parameters in `@callback` specs** — e.g., `key :: String.t()` not just `String.t()` — serves as documentation
5. **NEVER use behaviour inheritance** — compose multiple small behaviours instead (Ecto adapter pattern)
6. **ALWAYS pair `defoverridable` with `@behaviour`** when providing defaults in `__using__`
7. **Use behaviours for module-level polymorphism** (adapters, strategies); use **protocols for data-level polymorphism** (dispatch on first argument's type)
8. **Handle `@optional_callbacks` at call sites** with `function_exported?/3` — optional means the function may not exist

### Defining Behaviours

```elixir
defmodule MyApp.Storage do
  @doc "Fetch an item by key"
  @callback fetch(key :: String.t()) :: {:ok, term()} | {:error, :not_found}

  @callback store(key :: String.t(), value :: term()) :: :ok | {:error, term()}

  @optional_callbacks [store: 2]  # Not all implementations need write
end

defmodule MyApp.Storage.ETS do
  @behaviour MyApp.Storage

  @impl true
  def fetch(key), do: ...

  @impl true
  def store(key, value), do: ...
end
```

### @impl true vs @impl ModuleName

```elixir
# Single behaviour — use @impl true (common case)
defmodule MyServer do
  use GenServer
  @impl true
  def init(state), do: {:ok, state}
  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}
end

# Multiple behaviours with overlapping names — use @impl ModuleName
defmodule MyAdapter do
  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Queryable
  @behaviour Ecto.Adapter.Schema

  @impl Ecto.Adapter
  def init(config), do: ...

  @impl Ecto.Adapter.Queryable
  def execute(adapter_meta, query_meta, query_cache, params, opts), do: ...

  @impl Ecto.Adapter.Schema
  def insert(adapter_meta, schema_meta, fields, on_conflict, returning, opts), do: ...
end
```

**Compiler warning traps:**
- `@impl true` on a non-callback function → warns "no behaviour specifies such callback"
- `@impl` on a private function → warns "@impl is always discarded for private functions"
- `@impl` set but no `def` follows → warns "module attribute @impl was set but no definition follows"
- Missing `@impl` when others have it → warns about the missing one

### Behaviour + use Macro — The Full Pattern

Libraries combine `@behaviour` with `use` to provide defaults:

```elixir
defmodule MyLib.Worker do
  # Step 1: Define the behaviour
  @callback process(term()) :: {:ok, term()} | {:error, term()}
  @callback handle_failure(term(), term()) :: :retry | :skip

  # Step 2: __using__ injects defaults + makes them overridable
  defmacro __using__(opts) do
    quote do
      @behaviour MyLib.Worker

      # Default implementation — users override what they need
      @impl MyLib.Worker
      def handle_failure(_item, _reason), do: :skip

      defoverridable MyLib.Worker  # Makes ALL callbacks overridable at once
      # Or: defoverridable handle_failure: 2  (specific functions)
    end
  end
end

# Usage — only implement what differs from defaults
defmodule MyApp.EmailWorker do
  use MyLib.Worker

  @impl true
  def process(email), do: {:ok, send_email(email)}

  # handle_failure/2 uses the default :skip — no need to implement
end
```

### Dynamic Dispatch via Behaviours (Adapter Pattern)

```elixir
# Define the behaviour (contract)
defmodule MyApp.Mailer do
  @callback send_email(to :: String.t(), subject :: String.t(), body :: String.t()) ::
    {:ok, term()} | {:error, term()}
end

# Implementations
defmodule MyApp.Mailer.SMTP do
  @behaviour MyApp.Mailer
  @impl true
  def send_email(to, subject, body), do: ...
end

defmodule MyApp.Mailer.SendGrid do
  @behaviour MyApp.Mailer
  @impl true
  def send_email(to, subject, body), do: ...
end

# Runtime dispatch — module from config
defmodule MyApp.Mailer.Dispatcher do
  def send(to, subject, body) do
    impl = Application.get_env(:my_app, :mailer, MyApp.Mailer.SMTP)
    impl.send_email(to, subject, body)
  end
end

# config/config.exs
config :my_app, :mailer, MyApp.Mailer.SendGrid

# config/test.exs — use Mox for testing
config :my_app, :mailer, MyApp.MockMailer
```

### Multi-Behaviour Composition (Ecto Adapter Pattern)

Elixir uses flat composition of multiple small behaviours — never inheritance:

```elixir
# Small, focused behaviour modules
defmodule MyLib.Adapter do
  @callback init(config :: keyword()) :: {:ok, state :: term()}
end

defmodule MyLib.Adapter.Read do
  @callback fetch(state :: term(), key :: term()) :: {:ok, term()} | {:error, :not_found}
end

defmodule MyLib.Adapter.Write do
  @callback store(state :: term(), key :: term(), value :: term()) :: :ok | {:error, term()}
end

# Implementors opt-in to what they support
defmodule MyLib.Adapter.ReadOnly do
  @behaviour MyLib.Adapter
  @behaviour MyLib.Adapter.Read
  # No Write behaviour — this adapter is read-only
end
```

### Behaviour vs Protocol — When to Use Which

| | Behaviour | Protocol |
|---|---|---|
| **Dispatch on** | Module identity (passed as config) | Data type of first argument |
| **Define with** | `@callback` | `defprotocol` |
| **Implement with** | `@behaviour` + `@impl` | `defimpl` |
| **Testing** | Works with Mox | Does not work with Mox |
| **Use for** | Adapters, strategies, services | Type-specific formatting, conversion |
| **Examples** | Ecto.Adapter, Plug, Phoenix.Channel | Enumerable, String.Chars, Inspect |

### Behaviour Introspection

```elixir
# Check if a module defines a behaviour
function_exported?(GenServer, :behaviour_info, 1)  # true

# List all callbacks
GenServer.behaviour_info(:callbacks)
# [{:init, 1}, {:handle_call, 3}, {:handle_cast, 2}, ...]

# List optional callbacks
GenServer.behaviour_info(:optional_callbacks)
# [{:handle_call, 3}, {:handle_cast, 2}, ...]

# Check what behaviours a module implements
MyServer.__info__(:attributes)[:behaviour]
# [GenServer]

# Check if a module implements a specific callback at runtime
function_exported?(MyModule, :handle_call, 3)
```

### defoverridable — Layered Default Implementations

Two forms exist:

```elixir
# Form 1: Override all callbacks of a behaviour at once
defmacro __using__(_opts) do
  quote do
    @behaviour Plug
    def init(opts), do: opts
    def call(conn, opts), do: build_pipeline(conn, opts)
    defoverridable Plug          # Makes init/1 and call/2 overridable
  end
end

# Form 2: Override specific functions by name/arity
defoverridable init: 1, call: 2, action: 2
```

**The `@before_compile` + `defoverridable` + `super` wrapping pattern** (used by Phoenix.Endpoint, Plug.Debugger, Plug.ErrorHandler):

```elixir
defmacro __before_compile__(_env) do
  quote do
    defoverridable call: 2
    def call(conn, opts) do
      try do
        super(conn, opts)      # Calls the previous definition
      rescue
        e -> handle_error(conn, e)
      end
    end
  end
end
```

This allows multiple modules to wrap `call/2` in layers — each layer calls `super` to invoke the previous definition.

### `defdelegate` for Callback Reuse — Thin Wrapper Modules (AshAuthentication Pattern)

When multiple modules share the same implementation for behaviour callbacks, use `defdelegate` to create thin wrappers. This is Elixir's equivalent of implementation inheritance — without the inheritance.

```elixir
# Base implementation — OAuth2 does the real work
defmodule MyApp.Strategy.OAuth2 do
  def transform(strategy, dsl_state) do
    # Complex OAuth2 transformation logic (100+ lines)
    # ...
  end

  def verify(strategy, dsl_state) do
    # Validate client_id, client_secret, URLs
    # ...
  end
end

# GitHub is OAuth2 with different defaults — delegates ALL callbacks
defmodule MyApp.Strategy.GitHub do
  defstruct [:client_id, :client_secret, name: :github]

  defdelegate transform(strategy, dsl_state), to: MyApp.Strategy.OAuth2
  defdelegate verify(strategy, dsl_state), to: MyApp.Strategy.OAuth2
end

# Google overrides one callback, delegates the rest
defmodule MyApp.Strategy.Google do
  defstruct [:client_id, :client_secret, :hd, name: :google]

  defdelegate transform(strategy, dsl_state), to: MyApp.Strategy.OAuth2

  def verify(strategy, dsl_state) do
    # Google-specific: validate hosted domain (hd) config
    with :ok <- MyApp.Strategy.OAuth2.verify(strategy, dsl_state) do
      validate_hosted_domain(strategy)
    end
  end
end
```

**When to use `defdelegate` for callbacks:**
- Multiple modules implement the same behaviour with identical logic
- A "subtype" differs only in configuration/defaults, not behavior
- You want to override one callback while delegating the rest (Google example above)
- NOT when the delegated module needs access to the delegating module's state — that's a sign they should share a helper module instead

### `@after_verify` — Post-Compile Validation

`@after_verify` runs after a module is fully compiled. Unlike `@before_compile` (which can inject code), `@after_verify` is read-only — it validates but cannot modify the module. Use it to check that the module's final state is consistent.

```elixir
defmodule MyBehaviour do
  @callback process(term()) :: {:ok, term()} | {:error, term()}

  # Old callback — deprecated, kept for backwards compatibility
  @callback process(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @optional_callbacks process: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour MyBehaviour
      @after_verify {MyBehaviour, :verify_callback_arity}
    end
  end

  # Called after the using module is fully compiled
  def verify_callback_arity(module) do
    has_1 = Module.defines?(module, {:process, 1})
    has_2 = Module.defines?(module, {:process, 2})

    cond do
      has_1 and has_2 ->
        raise CompileError,
          description: "#{inspect(module)} defines both process/1 and process/2 — pick one"
      not has_1 and not has_2 ->
        raise CompileError,
          description: "#{inspect(module)} must define process/1"
      has_2 ->
        IO.warn("#{inspect(module)}: process/2 is deprecated, use process/1")
      true ->
        :ok
    end
  end
end
```

**`@after_verify` vs `@before_compile`:**

| | `@before_compile` | `@after_verify` |
|---|---|---|
| When | Before compilation finishes | After compilation finishes |
| Can inject code | Yes (`defmacro __before_compile__`) | No — read-only |
| Can check which functions exist | Yes, via `Module.defines?/2` | Yes, via `Module.defines?/2` |
| Use for | DSL code generation | Mutual exclusivity checks, deprecation warnings |
| AshAuthentication uses for | — | Secret arity validation (3 vs 4 args) |

### Compile-Time Transformers — Convention Over Configuration

Ash and Spark use a **transformer** pattern to auto-generate boilerplate at compile time. The user declares *what* they want in a DSL; transformers generate *how* it works:

```elixir
# User writes minimal DSL:
defmodule MyApp.User do
  use Ash.Resource

  authentication do
    strategy :password do
      identity_field :email
    end
  end
end

# The password transformer AUTO-GENERATES:
# - A :sign_in action with email/password arguments
# - A :register action with email/password/password_confirmation
# - Hash password changes, sign-in preparations
# - Token generation if tokens are enabled
# User can override any generated action by defining it explicitly
```

This pattern is broadly useful beyond Ash — any DSL that needs to generate boilerplate from declarations. The key implementation tool is `Spark.Dsl.Transformer` (or `@before_compile` for non-Spark libraries).

### The DSL Recipe — __using__ + Accumulated Attributes + @before_compile

This three-step pattern is how Phoenix, Plug, Absinthe, and Ash build DSLs:

```elixir
# Step 1: __using__ — set up imports, register attributes, schedule compilation
defmacro __using__(_opts) do
  quote do
    @behaviour MyDSL
    import MyDSL, only: [register_handler: 2]
    Module.register_attribute(__MODULE__, :handlers, accumulate: true)
    @before_compile MyDSL
  end
end

# Step 2: Macros push data into accumulated attributes
defmacro register_handler(event, handler) do
  quote do
    @handlers {unquote(event), unquote(handler)}
  end
end

# Step 3: @before_compile reads attributes and generates functions
defmacro __before_compile__(env) do
  handlers = Module.get_attribute(env.module, :handlers)
  # NOTE: accumulated attributes are in REVERSE order (last declared first)

  for {event, handler} <- Enum.reverse(handlers) do
    quote do
      def handle(unquote(event)), do: unquote(handler).()
    end
  end
end
```

**Critical:** Accumulated attributes are stored in **reverse order** — `Module.register_attribute(mod, :attr, accumulate: true)` prepends each new value. Either:
- Design your `Enum.reduce` to consume reversed lists (Plug.Builder approach)
- Call `Enum.reverse()` explicitly when order matters (Phoenix.Socket approach)

## Protocols

### Rules for Protocols (LLM)

1. **PREFER single-function protocols** — the vast majority of stdlib/library protocols define exactly 1 function. Multi-function only for optimization callbacks (Enumerable pattern)
2. **ALWAYS put `@derive` BEFORE `defstruct`** (or `schema`) — the compiler warns if it comes after
3. **NEVER implement `for: Map` expecting it to match structs** — structs dispatch through `struct_impl_for/1`, not the Map implementation. `defimpl for: Map` only matches bare maps
4. **Use `@fallback_to_any true`** only when there IS a sensible default. Don't use it when failure should be loud (Enumerable, String.Chars don't use it)
5. **ALWAYS implement all 3 commands** in Collectable: `{:cont, elem}`, `:done`, `:halt`
6. **For Enumerable, return `{:error, __MODULE__}`** from `count/1`, `member?/2`, `slice/1` when O(1) isn't possible — this triggers the reduce-based fallback
7. **Use `Protocol.derive/3`** for structs you don't own instead of reaching into their modules
8. **Guard `for: BitString` implementations** with `is_binary/1` — BitString matches both binaries and bitstrings

### Defining Protocols

```elixir
# Most protocols: single function, no fallback
defprotocol MyApp.Renderable do
  @spec render(t()) :: iodata()
  def render(term)
end

# With @fallback_to_any for a sensible default or helpful error
defprotocol MyApp.Parameterizable do
  @fallback_to_any true
  @spec to_param(t()) :: String.t()
  def to_param(term)
end
```

**The 11 built-in types** you can implement for: `Atom`, `BitString`, `Float`, `Function`, `Integer`, `List`, `Map`, `PID`, `Port`, `Reference`, `Tuple` — plus `Any` (fallback).

### Implementing Protocols

```elixir
# For built-in types
defimpl MyApp.Renderable, for: BitString do
  def render(binary) when is_binary(binary), do: binary  # Guard: BitString includes non-binary bitstrings
  def render(bits), do: raise Protocol.UndefinedError, protocol: @protocol, value: bits
end

defimpl MyApp.Renderable, for: List do
  def render(iolist), do: iolist  # IO lists are already renderable
end

# For multiple types at once
defimpl MyApp.Renderable, for: [Integer, Float] do
  def render(number), do: to_string(number)
end

# For a struct — inside the struct's module (`:for` is optional)
defmodule MyApp.Widget do
  defstruct [:name, :html]

  defimpl MyApp.Renderable do
    def render(%{html: html}), do: html
  end
end

# For a struct — outside the module
defimpl MyApp.Renderable, for: MyApp.Alert do
  def render(%{message: msg, level: level}), do: ~s(<div class="#{level}">#{msg}</div>)
end
```

### @derive — Compile-Time Protocol Implementation

```elixir
defmodule MyApp.User do
  # @derive MUST come before defstruct/schema
  @derive {Phoenix.Param, key: :username}                  # URL: /users/john_doe
  @derive {Inspect, only: [:id, :name]}                    # Hide password_hash in logs
  defstruct [:id, :name, :email, :username, :password_hash]
end

# For structs you don't own — use Protocol.derive/3
require Protocol
Protocol.derive(JSON.Encoder, SomeLibrary.Thing, only: [:id, :name])
```

**How @derive works:** The protocol's `__deriving__` macro (defined in the protocol or its Any implementation) generates a `defimpl` block at compile time. The derived implementation can pattern-match struct fields directly in function heads for optimal performance.

### @fallback_to_any — When to Use

| Protocol | Has `@fallback_to_any`? | Why |
|---|---|---|
| `Inspect` | Yes | Default `%Module{...}` printing for all structs |
| `Phoenix.Param` | Yes | Convention: assumes `:id` field exists |
| `Plug.Exception` | Yes | Default: return 500 status, empty actions |
| `Inspect` | Yes | Debug output can use a conservative fallback |
| `Enumerable` | **No** | `Enum.map` on non-enumerable must fail loudly |
| `String.Chars` | **No** | Silent garbage output would hide bugs |
| `Collectable` | **No** | No sensible default |

**Alternative to `@fallback_to_any`:** Use `@undefined_impl_description` (Elixir 1.18+) to customize the error message without providing a fallback:

```elixir
defprotocol MyApp.Encoder do
  @undefined_impl_description """
  protocol must be explicitly implemented.
  Add `@derive {MyApp.Encoder, only: [...]}` before defstruct.
  """
  def encode(term)
end
```

### Making a Derivable Protocol

```elixir
defprotocol MyApp.Cacheable do
  @fallback_to_any true
  @spec cache_key(t()) :: String.t()
  def cache_key(term)
end

defimpl MyApp.Cacheable, for: Any do
  # __deriving__/3 in Any impl (legacy approach, works in all versions)
  defmacro __deriving__(module, _struct, opts) do
    key_fields = Keyword.get(opts, :keys, [:id])
    quote do
      defimpl MyApp.Cacheable, for: unquote(module) do
        def cache_key(struct) do
          parts = Enum.map(unquote(key_fields), &Map.fetch!(struct, &1))
          Enum.join([unquote(inspect(module)) | parts], ":")
        end
      end
    end
  end

  # Fallback: use module name + :id
  def cache_key(%{__struct__: mod, id: id}), do: "#{inspect(mod)}:#{id}"
  def cache_key(term), do: raise Protocol.UndefinedError, protocol: @protocol, value: term
end

# Usage
@derive {MyApp.Cacheable, keys: [:tenant_id, :id]}
defstruct [:tenant_id, :id, :name]
```

### Struct Dispatch Precedence

Protocol dispatch for structs follows this priority:

1. **Explicit `defimpl` for the struct** — highest priority
2. **`@derive`-generated implementation** — compiled from `__deriving__` macro
3. **`Any` implementation** — only if `@fallback_to_any true`

**Structs NEVER match the `Map` implementation** — even though structs are maps, protocol dispatch checks `struct_impl_for/1` first. The `Map` impl only matches bare `%{}` maps:

```elixir
# BAD — this does NOT match structs
defimpl MyProtocol, for: Map do
  def my_func(map), do: ...   # Only bare maps, not %User{}, %Post{}, etc.
end

# GOOD — implement for the specific struct
defimpl MyProtocol, for: MyApp.User do
  def my_func(user), do: ...
end
```

### Protocol Introspection

```elixir
# Check if a value's type implements a protocol
Enumerable.impl_for([1, 2, 3])    #=> Enumerable.List
Enumerable.impl_for("string")     #=> nil (not implemented)
Enumerable.impl_for!("string")    #=> raises Protocol.UndefinedError

# Check consolidation (important for debugging)
Protocol.consolidated?(Enumerable)  #=> true (release) / false (dev)

# List all implementations (only when consolidated)
Enumerable.__protocol__(:impls)     #=> {:consolidated, [List, Map, ...]}

# Protocol metadata
Enumerable.__protocol__(:functions) #=> [count: 1, member?: 2, reduce: 3, slice: 1]

# Implementation metadata
Enumerable.List.__impl__(:protocol) #=> Enumerable
Enumerable.List.__impl__(:for)      #=> List
```

### Protocol Consolidation Gotchas

- **Mix auto-consolidates** at compile time — after consolidation, new `defimpl`s have no effect
- **In tests:** If test support files define protocol implementations, ensure `test/support` is in `elixirc_paths`:
  ```elixir
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
  ```
- **For optional dependencies:** Guard with `Code.ensure_loaded?/1`:
  ```elixir
  if Code.ensure_loaded?(Decimal) do
    defimpl String.Chars, for: Decimal do
      def to_string(decimal), do: Decimal.to_string(decimal)
    end
  end
  ```

## Stream & Enumerable Protocol

### The Enumerable Protocol — How It All Fits Together

`Enum` and `Stream` both operate on anything that implements the `Enumerable` protocol. This is the foundation — lists, maps, ranges, MapSets, streams, and any custom data structure that implements `Enumerable` all work with `Enum.*` and `Stream.*` functions.

```
Enumerable (protocol)
├── List, Map, Range, MapSet       ← built-in, eager
├── Stream                         ← lazy wrapper around Enumerable
├── File.stream!/1                 ← lazy file I/O
└── Your custom struct             ← implement Enumerable for it
```

**Key insight:** `Enum` functions are *eager* — they consume the entire enumerable and produce a result immediately. `Stream` functions are *lazy* — they return a new `%Stream{}` struct that describes the computation but doesn't execute it until consumed by an `Enum` function.

```elixir
# Eager — builds 3 intermediate lists
result = list
|> Enum.map(&transform/1)     # produces full list
|> Enum.filter(&valid?/1)     # produces full list
|> Enum.take(10)              # produces final list

# Lazy — builds 0 intermediate lists, processes element-by-element
result = list
|> Stream.map(&transform/1)   # returns %Stream{} (no work done)
|> Stream.filter(&valid?/1)   # returns %Stream{} (no work done)
|> Enum.take(10)              # NOW executes: pulls elements one at a time
```

### When to Use Stream vs Enum

| Use Enum when... | Use Stream when... |
|---|---|
| Collection fits in memory | Data is large or infinite |
| You need all results | You need only a subset (first N, take_while) |
| Simple 1-2 step pipeline | Chaining 3+ transforms on large data |
| Performance matters on small data | Avoiding intermediate allocations matters |
| Debugging (easier to inspect) | Wrapping I/O resources (files, sockets) |

**Rule of thumb:** Start with `Enum`. Switch to `Stream` when you have a reason — large data, partial consumption, or I/O resources.

### Stream Creators

```elixir
# From values
Stream.iterate(0, & &1 + 1)        # Infinite: 0, 1, 2, 3, ...
Stream.cycle([:a, :b, :c])         # Infinite: :a, :b, :c, :a, :b, ...
Stream.repeatedly(fn -> :rand.uniform() end)  # Infinite: random values
Stream.interval(1000)               # Emits incrementing integers every 1s

# From state (most versatile)
Stream.unfold(state, fun)
# fun receives state, returns {emit_value, next_state} or nil to halt
Stream.unfold(5, fn
  0 -> nil                         # halt
  n -> {n, n - 1}                  # emit n, continue with n-1
end) |> Enum.to_list()
# => [5, 4, 3, 2, 1]

# From external resources (files, sockets, database cursors)
Stream.resource(start_fun, next_fun, after_fun)
# start_fun: () -> resource       (open)
# next_fun: resource -> {[items], resource} | {:halt, resource}
# after_fun: resource -> :ok      (cleanup, always called)
File.stream!("path")               # Built-in: lazy line-by-line
File.stream!("path", :line)        # Same, explicit
File.stream!("path", 4096)         # Read in 4KB chunks (binary)
```

### Stream Transforms (Lazy — No Execution Until Consumed)

```elixir
Stream.map(stream, fun)             # transform each element
Stream.filter(stream, fun)          # keep matching elements
Stream.reject(stream, fun)          # remove matching elements
Stream.flat_map(stream, fun)        # transform and flatten
Stream.chunk_every(stream, n)       # group into chunks of n
Stream.chunk_while(stream, acc, chunk_fun, after_fun)  # custom chunking
Stream.take(stream, n)              # first n elements
Stream.take_every(stream, nth)      # every nth element
Stream.take_while(stream, fun)      # take while predicate holds
Stream.drop(stream, n)              # skip first n
Stream.drop_while(stream, fun)      # skip while predicate holds
Stream.dedup(stream)                # remove consecutive duplicates
Stream.dedup_by(stream, fun)        # dedup by key function
Stream.uniq(stream)                 # remove all duplicates (uses memory!)
Stream.uniq_by(stream, fun)         # unique by key function
Stream.scan(stream, acc, fun)       # like reduce but emits each accumulator
Stream.with_index(stream)           # add index: {element, index}
Stream.zip(stream_a, stream_b)      # pair elements from two streams
Stream.concat(stream_a, stream_b)   # append streams
Stream.intersperse(stream, sep)     # insert separator between elements
Stream.transform(stream, acc, reducer)  # most powerful: stateful map with halt
```

### Consuming Streams (Triggers Execution)

```elixir
Enum.to_list(stream)       # collect all into list
Enum.take(stream, n)       # collect first n
Enum.reduce(stream, ...)   # fold to single value
Enum.count(stream)         # count elements (consumes all!)
Enum.any?(stream, fun)     # short-circuits on first true
Enum.find(stream, fun)     # short-circuits on first match
Stream.run(stream)         # execute for side effects, returns :ok
```

### Practical Stream Patterns

```elixir
# Process large file without loading into memory
File.stream!("huge.csv")
|> Stream.map(&String.trim/1)
|> Stream.reject(&(&1 == ""))
|> Stream.map(&String.split(&1, ","))
|> Enum.take(1000)  # only reads ~1000 lines from disk

# Paginated API consumption
Stream.resource(
  fn -> fetch_page(1) end,
  fn
    %{data: [], next: nil} -> {:halt, nil}
    %{data: data, next: cursor} -> {data, fetch_page(cursor)}
  end,
  fn _ -> :ok end
)
|> Stream.take(500)
|> Enum.to_list()

# Batched database inserts
large_list
|> Stream.chunk_every(1000)
|> Stream.each(fn batch -> Repo.insert_all(MySchema, batch) end)
|> Stream.run()

# Fibonacci via unfold
fibs = Stream.unfold({0, 1}, fn {a, b} -> {a, {b, a + b}} end)
Enum.take(fibs, 10)  # => [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]

# Sliding window
Stream.chunk_every(data, 3, 1, :discard)
# [1,2,3,4,5] => [[1,2,3], [2,3,4], [3,4,5]]

# Rate-limited processing
stream
|> Stream.each(fn item ->
  process(item)
  Process.sleep(100)  # 10 items/sec
end)
|> Stream.run()

# Stream.transform for stateful processing with early halt
Stream.transform(events, 0, fn
  _event, acc when acc >= 100 -> {:halt, acc}  # stop after 100 processed
  event, acc -> {[process(event)], acc + 1}
end)
```

### Implementing the Enumerable Protocol

Make any custom data structure work with `Enum.*` and `Stream.*` by implementing `Enumerable`:

```elixir
defmodule CircularBuffer do
  defstruct [:data, :size, :start, :count]

  def new(size) do
    %CircularBuffer{data: :array.new(size, default: nil), size: size, start: 0, count: 0}
  end

  def push(%CircularBuffer{} = buf, item) do
    pos = rem(buf.start + buf.count, buf.size)
    data = :array.set(pos, item, buf.data)
    if buf.count < buf.size do
      %{buf | data: data, count: buf.count + 1}
    else
      %{buf | data: data, start: rem(buf.start + 1, buf.size)}
    end
  end
end

# Implement Enumerable so Enum.map/filter/reduce/etc. all work
defimpl Enumerable, for: CircularBuffer do
  # Required: reduce/3 — the core iteration function
  def reduce(_buf, {:halt, acc}, _fun), do: {:halted, acc}
  def reduce(buf, {:suspend, acc}, fun), do: {:suspended, acc, &reduce(buf, &1, fun)}
  def reduce(%{count: 0}, {:cont, acc}, _fun), do: {:done, acc}
  def reduce(%{data: data, start: start, size: size, count: count} = buf, {:cont, acc}, fun) do
    item = :array.get(start, data)
    next = %{buf | start: rem(start + 1, size), count: count - 1}
    reduce(next, fun.(item, acc), fun)
  end

  # Required: count/1 — return {:ok, count} for O(1) or {:error, __MODULE__} to fall back to reduce
  def count(%{count: count}), do: {:ok, count}

  # Required: member?/2 — return {:ok, bool} for O(1) lookup or {:error, __MODULE__} to fall back
  def member?(_buf, _value), do: {:error, __MODULE__}  # no fast lookup, use reduce

  # Required: slice/1 — return {:ok, size, slicing_fun} for O(1) slicing or {:error, __MODULE__}
  def slice(_buf), do: {:error, __MODULE__}
end

# Now it works with all Enum and Stream functions:
buf =
  CircularBuffer.new(5)
  |> CircularBuffer.push(1)
  |> CircularBuffer.push(2)
  |> CircularBuffer.push(3)
Enum.to_list(buf)          # => [1, 2, 3]
Enum.map(buf, & &1 * 10)   # => [10, 20, 30]
Enum.sum(buf)              # => 6
buf
|> Stream.map(& &1 * 2)
|> Enum.to_list()  # => [2, 4, 6]
```

**The four Enumerable callbacks:**

| Callback | Purpose | Return for fast path | Return for fallback |
|---|---|---|---|
| `reduce/3` | Core iteration (required, always implement fully) | n/a — always implement | n/a |
| `count/1` | Element count | `{:ok, integer}` | `{:error, __MODULE__}` |
| `member?/2` | Membership test | `{:ok, boolean}` | `{:error, __MODULE__}` |
| `slice/1` | Random access | `{:ok, size, slice_fun}` | `{:error, __MODULE__}` |

When you return `{:error, __MODULE__}`, Elixir falls back to using `reduce/3` — always correct but O(n). Implement the fast path when your data structure supports it (e.g., `count/1` for structures that track size).

### The Collectable Protocol — Building Collections

`Collectable` is the inverse of `Enumerable` — it defines how to build a collection. Used by `Enum.into/2`, `for` comprehensions, and `Map.new/2`.

```elixir
# Enum.into uses Collectable to pour data into a target
Enum.into([a: 1, b: 2], %{})       # => %{a: 1, b: 2}
Enum.into(stream, File.stream!("out.txt"))  # stream into file

# for comprehensions use Collectable for :into
for {k, v} <- map, into: %{}, do: {k, v * 2}

# Implement Collectable for custom structs
defimpl Collectable, for: CircularBuffer do
  def into(buf) do
    collector_fun = fn
      buf_acc, {:cont, item} -> CircularBuffer.push(buf_acc, item)
      buf_acc, :done -> buf_acc
      _buf_acc, :halt -> :ok
    end
    {buf, collector_fun}
  end
end

# Now works with into:
buf = Enum.into([1, 2, 3], CircularBuffer.new(5))
for x <- 1..5, into: CircularBuffer.new(5), do: x
```

## Error Handling

> Core error handling rules (ok/error tuples, no try/rescue for control flow, let it crash) are in [SKILL.md](SKILL.md). This section covers defexception patterns, error kernel design, exit reasons, and the Result module pattern.

### defexception Patterns

```elixir
# Simple — message-only exception
defmodule MyApp.NotFoundError do
  defexception message: "resource not found"
end

# With constructor — builds message from params
defmodule MyApp.MissingParamError do
  defexception [:message, plug_status: 400]  # plug_status maps to HTTP status

  def exception(key: key) do
    %__MODULE__{message: "expected key #{inspect(key)} to be present in params"}
  end
end

# WrapperError — preserving context through error boundaries
defmodule MyApp.WrapperError do
  defexception [:conn, :kind, :reason, :stack]

  @impl true
  def message(%{kind: kind, reason: reason, stack: stack}) do
    Exception.format_banner(kind, reason, stack)
  end
end
```

**Convention:** The `plug_status` field on exceptions is recognized by `Plug.Exception` protocol to map exceptions to HTTP status codes. Any struct with `plug_status` gets that status automatically via `@fallback_to_any true`.

### ok/error Tuples

```elixir
@spec fetch_user(integer()) :: {:ok, User.t()} | {:error, atom()}
def fetch_user(id) do
  case Repo.get(User, id) do
    nil -> {:error, :not_found}
    user -> {:ok, user}
  end
end

# Bang functions raise on error
def fetch_user!(id), do: Repo.get(User, id) || raise "User not found"
```

### Let It Crash

Don't catch everything — let supervisors restart:

```elixir
def handle_call({:process, data}, _from, state) do
  result = process_data(data)  # Crashes propagate to supervisor
  {:reply, {:ok, result}, state}
end
```

**When NOT to let it crash:**
- Error kernel processes (supervisors, registries, ETS owners) — use defensive code
- Processes holding connections/resources that need cleanup — use `terminate/2`
- Expected failures (user input, external APIs) — return `{:error, reason}` tuples

### Error Kernel Design

The **error kernel** is the minimal, critical part of your system that must remain operational:

```
Application
├── Supervisor (error kernel)
│   ├── Registry (error kernel - process discovery)
│   ├── ETS owner (error kernel - shared state survives worker crashes)
│   └── DynamicSupervisor
│       └── Worker processes (can crash freely)
```

**Principles:**
1. Keep the error kernel small and simple
2. Non-critical components should crash and restart with clean state
3. Supervisors and registries are part of the error kernel
4. Critical state can be stored in ETS (survives child process crashes)
5. Only use defensive programming in error kernel components

**Pattern:** Store critical state in ETS owned by a supervisor-level process. Workers read/write to ETS but their crashes don't lose data:

```elixir
defmodule MyApp.StateStore do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(:critical_state, [:named_table, :public, :set])
    {:ok, nil}  # Minimal state - just keeps table alive
  end
end

# Workers can crash - ETS data persists
defmodule MyApp.Worker do
  def save(key, value), do: :ets.insert(:critical_state, {key, value})
  def load(key), do: :ets.lookup(:critical_state, key)
end
```

### Exit Reason Classification

Exit reasons determine whether a supervised child restarts:

| Exit reason | `:permanent` | `:transient` | `:temporary` |
|------------|-------------|-------------|-------------|
| `:normal` | restart | no restart | no restart |
| `:shutdown` | restart | no restart | no restart |
| `{:shutdown, term}` | restart | no restart | no restart |
| Any other (abnormal) | restart | restart | no restart |

**Key insight:** `:permanent` restarts on ALL exits including `:normal`. Use `:transient` for processes that should restart only on crashes. Use `:temporary` for fire-and-forget work (tasks).

```elixir
# Transient: restarts only on abnormal exit (crashes)
use GenServer, restart: :transient

# Temporary: never restarts (one-shot work)
use GenServer, restart: :temporary
```

### Result Module Pattern

```elixir
defmodule MyApp.Result do
  @type t(ok, err) :: {:ok, ok} | {:error, err}
  @type t(ok) :: t(ok, any())

  def ok(value), do: {:ok, value}
  def error(reason), do: {:error, reason}

  def map({:ok, value}, fun), do: {:ok, fun.(value)}
  def map({:error, _} = error, _fun), do: error

  def flat_map({:ok, value}, fun), do: fun.(value)
  def flat_map({:error, _} = error, _fun), do: error

  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, reason}), do: raise "Unwrap error: #{inspect(reason)}"

  def unwrap_or({:ok, value}, _default), do: value
  def unwrap_or({:error, _}, default), do: default

  # Use in pipeline
  def then({:ok, value}, fun), do: fun.(value)
  def then({:error, _} = error, _fun), do: error
end

# Usage
import MyApp.Result

fetch_user(id)
|> Result.flat_map(&validate_user/1)
|> Result.map(&format_user/1)
|> Result.unwrap_or(%{})
```

## Advanced Patterns (General-Purpose)

> Domain-specific patterns have been moved to their natural homes:
> - Telemetry patterns → [production.md](production.md)
> - Plug halt semantics → [production.md](production.md)
> - Changeset semantics → [ecto-reference.md](ecto-reference.md)
> - GenStage/Broadway patterns (Subscriber, CallerAcknowledger, Coordinated Shutdown, Message/Acknowledger, BatchInfo) → [otp-advanced.md](otp-advanced.md)
> - Dynamic Pool → [otp-examples.md](otp-examples.md)

### Bidirectional Step Pipeline

Design pipelines where steps can convert between success and error states:

```elixir
@type request_step :: (Request.t() ->
  Request.t() | {Request.t(), Response.t() | Exception.t()})

@type response_step :: ({Request.t(), Response.t()} ->
  {Request.t(), Response.t() | Exception.t()})

@type error_step :: ({Request.t(), Exception.t()} ->
  {Request.t(), Response.t() | Exception.t()})

def run_pipeline(request) do
  request
  |> run_request_steps()
  |> run_adapter()
  |> run_response_steps()  # Can return exception to trigger error steps
  |> run_error_steps()     # Can return response to recover
end
```

**Key insight:** Error steps returning a response "recover" the pipeline. Response steps returning an exception trigger error handling. This enables retry, circuit-breaker, and fallback patterns.

### Option Registration Pattern

Validate options at compile/runtime to catch typos early:

```elixir
defmodule MyLib.Request do
  defstruct registered_options: MapSet.new()

  def register_options(request, options) when is_list(options) do
    update_in(request.registered_options, &MapSet.union(&1, MapSet.new(options)))
  end

  def put_option(request, key, value) do
    if key in request.registered_options do
      put_in(request.options[key], value)
    else
      raise ArgumentError, "unknown option #{inspect(key)}"
    end
  end
end

# Plugin registers its options
def attach(request) do
  request
  |> Request.register_options([:retry, :retry_delay, :max_retries])
end
```

### Private Data Namespace

Reserve a map for library/framework extensions without polluting the public API:

```elixir
defstruct data: nil,
          metadata: %{},
          private: %{}  # Reserved for libraries

def put_private(%__MODULE__{} = struct, key, value) when is_atom(key) do
  put_in(struct.private[key], value)
end

def get_private(%__MODULE__{} = struct, key, default \\ nil) do
  Map.get(struct.private, key, default)
end
```

### Error Delegation Pattern

Wrap underlying library errors while leveraging their formatting:

```elixir
defmodule MyApp.TransportError do
  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}) do
    # Delegate to underlying library's error formatting
    Mint.TransportError.message(%Mint.TransportError{reason: reason})
  end
end
```

### Atomics for Lock-Free Rate Limiting

Use `:atomics` for high-throughput counters without GenServer bottleneck:

```elixir
defmodule RateLimiter do
  use GenServer

  def init(opts) do
    counter = :atomics.new(1, [])
    :atomics.put(counter, 1, opts[:allowed])
    schedule_reset(opts[:interval])
    {:ok, %{counter: counter, allowed: opts[:allowed], interval: opts[:interval]}}
  end

  # Lock-free decrement - no message passing
  def rate_limit(limiter, amount) do
    %{counter: counter} = :sys.get_state(limiter)
    :atomics.sub_get(counter, 1, amount)  # Returns new value
  end

  def handle_info(:reset, state) do
    :atomics.put(state.counter, 1, state.allowed)
    schedule_reset(state.interval)
    {:noreply, state}
  end
end
```

### Persistent Term with Namespacing

Use `{Module, key}` tuples for efficient global config:

```elixir
defmodule MyApp.Config do
  def put(key, value) do
    :persistent_term.put({__MODULE__, key}, value)
  end

  def get(key, default \\ nil) do
    :persistent_term.get({__MODULE__, key}, default)
  end

  # Intentional: Don't delete from persistent_term
  # Memory overhead is negligible for named resources
  # Keeping entries allows process restarts without metadata loss
  def delete(_key), do: :ok
end
```

### Status as Tagged Exception Tuple

Capture full exception context for rich error handling:

```elixir
@type status ::
  :ok
  | {:failed, reason :: term}
  | {:throw | :error | :exit, term, Exception.stacktrace()}

def process_with_status(message, fun) do
  result = fun.(message)
  %{message | status: :ok, data: result}
rescue
  e -> %{message | status: {:error, e, __STACKTRACE__}}
catch
  :throw, value -> %{message | status: {:throw, value, __STACKTRACE__}}
  :exit, reason -> %{message | status: {:exit, reason, __STACKTRACE__}}
end
```

### Collectable with Streaming Hash

Compute checksums while streaming without buffering:

```elixir
def collect_with_hash(into, algorithm) do
  hash_state = :crypto.hash_init(algorithm)

  collector_fun = fn
    {acc, hash}, {:cont, chunk} ->
      {[chunk | acc], :crypto.hash_update(hash, chunk)}
    {acc, hash}, :done ->
      {Enum.reverse(acc), :crypto.hash_final(hash)}
    _, :halt ->
      :ok
  end

  {{[], hash_state}, collector_fun}
end

# Usage
{body, checksum} =
  stream
  |> Enum.into(collect_with_hash([], :sha256))
```

### Task.async_stream Patterns

```elixir
# Fire-and-forget with Stream.run() — for side effects only
source_files
|> Task.async_stream(&check_file/1,
  max_concurrency: System.schedulers_online(),
  timeout: :infinity,
  ordered: false)        # Don't wait for order — faster for independent work
|> Stream.run()          # Consume stream, discard results

# Collecting results — unwrap the {:ok, result} tuples
results =
  items
  |> Task.async_stream(&process/1, timeout: :infinity, ordered: false)
  |> Enum.map(fn {:ok, result} -> result end)

# Handling timeouts — use on_timeout: :kill_task
filenames
|> Task.async_stream(&parse/1, timeout: 5_000, on_timeout: :kill_task)
|> Stream.zip(filenames)
|> Enum.map(fn
  {{:exit, :timeout}, filename} -> {:error, {:timeout, filename}}
  {{:ok, result}, _filename} -> {:ok, result}
end)
```

### AST Traversal with Accumulators

`Macro.prewalk/3` and `Macro.postwalk/3` use the `{node, acc}` return pattern:

```elixir
# Collect all function calls in an AST
def find_calls(ast) do
  {_ast, calls} = Macro.prewalk(ast, [], fn
    # Return {node, acc} — node controls traversal, acc accumulates results
    {func, _meta, args} = node, acc when is_atom(func) and is_list(args) ->
      {node, [{func, length(args)} | acc]}

    # Return {nil, acc} to PRUNE a subtree from further traversal
    {:@, _, _}, acc ->
      {nil, acc}    # Skip module attribute subtrees

    node, acc ->
      {node, acc}   # Pass through unchanged
  end)
  Enum.reverse(calls)
end

# Nested prewalk — search within a matched node's children
defp walk({:@, _, [{:spec, _, args}]} = node, issues) do
  case Macro.prewalk(args, [], &find_structs/2) do
    {_ast, []} -> {node, issues}
    {_ast, structs} -> {node, [build_issue(structs) | issues]}
  end
end
```

### Phase Pipeline Pattern

Used by Absinthe — each phase returns a tagged tuple controlling flow:

```elixir
@type result ::
  {:ok, data}                           # Continue to next phase
  | {:jump, data, destination_phase}    # Skip ahead to a specific phase
  | {:insert, data, extra_phases}       # Insert phases before remaining
  | {:replace, data, new_pipeline}      # Replace remaining pipeline
  | {:error, reason}                    # Abort

def run_phases([], input, done), do: {:ok, input, done}
def run_phases([phase | todo], input, done) do
  case phase.run(input) do
    {:ok, result}      -> run_phases(todo, result, [phase | done])
    {:jump, result, dest} -> run_phases(from(todo, dest), result, [phase | done])
    {:insert, result, extra} -> run_phases(extra ++ todo, result, [phase | done])
    {:error, reason}   -> {:error, reason, [phase | done]}
  end
end
```

### Pluggable Engine Pattern (from Oban)

```elixir
defmodule MyApp.Engine do
  @callback init(conf :: Config.t(), opts :: keyword()) :: {:ok, meta :: map()}
  @callback insert_job(conf :: Config.t(), changeset :: Changeset.t(), opts :: keyword()) ::
    {:ok, Job.t()} | {:error, term()}
  @callback fetch_jobs(conf :: Config.t(), meta :: map(), opts :: keyword()) ::
    {:ok, {meta :: map(), [Job.t()]}}
  @callback complete_job(conf :: Config.t(), job :: Job.t()) :: :ok
  @callback error_job(conf :: Config.t(), job :: Job.t(), reason :: term()) :: :ok

  @optional_callbacks [stage_jobs: 3, prune_jobs: 3]

  def insert_job(conf, changeset, opts), do: conf.engine.insert_job(conf, changeset, opts)

  def stage_jobs(conf, meta, opts) do
    if function_exported?(conf.engine, :stage_jobs, 3) do
      conf.engine.stage_jobs(conf, meta, opts)
    else
      Basic.stage_jobs(conf, meta, opts)
    end
  end
end
```

### Validation with Smart Suggestions

```elixir
defmodule MyApp.Validation do
  def validate_schema(opts, schema) when is_list(opts) and is_map(schema) do
    Enum.reduce_while(opts, :ok, fn {key, value}, :ok ->
      case Map.fetch(schema, key) do
        {:ok, type} ->
          case validate_type(key, value, type) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        :error ->
          suggestion = suggest_key(key, Map.keys(schema))
          {:halt, {:error, "unknown option #{inspect(key)}" <> suggestion}}
      end
    end)
  end

  defp suggest_key(key, known_keys) do
    key_string = to_string(key)
    known_keys
    |> Enum.map(&{&1, String.jaro_distance(key_string, to_string(&1))})
    |> Enum.filter(fn {_, d} -> d > 0.7 end)
    |> Enum.max_by(fn {_, d} -> d end, fn -> nil end)
    |> case do
      {suggestion, _} -> ", did you mean #{inspect(suggestion)}?"
      nil -> ""
    end
  end

  defp validate_type(_key, value, :pos_integer) when is_integer(value) and value > 0, do: :ok
  defp validate_type(key, value, :pos_integer), do: {:error, "expected #{inspect(key)} to be positive integer"}
  defp validate_type(_key, value, :atom) when is_atom(value), do: :ok
  defp validate_type(_key, value, {:in, allowed}) when value in allowed, do: :ok
end
```

### Exponential Backoff with Jitter

```elixir
defmodule MyApp.Backoff do
  def exponential(attempt, opts \\ []) do
    mult = Keyword.get(opts, :mult, 1)
    base_pad = Keyword.get(opts, :base, 15)
    max_pow = Keyword.get(opts, :max_pow, 10)
    base_pad + mult * :math.pow(2, min(attempt, max_pow)) |> round()
  end

  def jitter(value, opts \\ []) do
    mode = Keyword.get(opts, :mode, :both)
    mult = Keyword.get(opts, :mult, 0.1)
    diff = :rand.uniform() * mult * value |> round()
    case mode do
      :inc -> value + diff
      :dec -> value - diff
      :both -> if(:rand.uniform() > 0.5, do: value + diff, else: value - diff)
    end
  end

  def with_retry(fun, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, :infinity)
    attempt = Keyword.get(opts, :attempt, 1)
    try do
      fun.()
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error] ->
        if max_retries == :infinity or attempt < max_retries do
          Process.sleep(exponential(attempt) |> jitter())
          with_retry(fun, Keyword.put(opts, :attempt, attempt + 1))
        else
          reraise e, __STACKTRACE__
        end
    end
  end
end
```

## `throw`/`catch` for Local Early-Exit (NimbleOptions Pattern)

While `try/rescue` is for exceptions and `{:ok, _}/{:error, _}` tuples are for expected failures, `throw`/`catch` has a legitimate use as a **local control flow mechanism** for early exit inside comprehensions or reduces where threading error state is awkward.

```elixir
# Problem: validating a list inside a for comprehension
# Can't "break" out of a comprehension on first error
def validate_list(items, schema) do
  try do
    values =
      for {item, index} <- Enum.with_index(items) do
        case validate_item(item, schema) do
          {:ok, value} -> value
          {:error, error} -> throw({:error, %{error | keys_path: [index | error.keys_path]}})
        end
      end
    {:ok, values}
  catch
    {:error, _} = error -> error
  end
end
```

**When this is appropriate:**
- Inside `for` comprehensions where early exit on first error is needed
- Inside `Enum.reduce` where threading `{:halt, {:error, reason}}` would complicate the accumulator
- Scope must be local — `throw` and `catch` in the same function or a direct helper
- The NimbleOptions library uses this pattern for list/tuple element validation

**When NOT to use:**
- Across module boundaries (use ok/error tuples)
- For expected business failures (use ok/error tuples)
- For truly exceptional situations (use raise/rescue)

## `Module.create/3` — Runtime Module Generation (Mox Pattern)

`defmodule` creates modules at compile time. `Module.create/3` creates them at runtime, essential for test frameworks, code generators, and dynamic protocol adapters.

```elixir
# Mox generates mock modules at runtime from behaviour definitions
defp create_mock(name, behaviours) do
  funs = for behaviour <- behaviours,
             {fun, arity} <- behaviour.behaviour_info(:callbacks) do
    args = Enum.map(1..arity//1, &Macro.var(:"arg#{&1}", Elixir))

    quote do
      def unquote(fun)(unquote_splicing(args)) do
        Mox.__dispatch__(__MODULE__, unquote(fun), unquote(arity), unquote(args))
      end
    end
  end

  body = quote do
    @behaviour unquote(hd(behaviours))
    unquote_splicing(funs)
  end

  Module.create(name, body, Macro.Env.location(__ENV__))
end

# Usage in test_helper.exs:
Mox.defmock(CalcMock, for: Calculator)
# CalcMock now exists as a module at runtime
```

**When to use `Module.create/3`:**
- Test helpers that generate mock/stub modules (Mox)
- Code generators that need to create modules from runtime data
- Dynamic protocol implementations

## `@compile {:no_warn_undefined, [...]}` — Optional Dependencies

Suppress warnings for modules that may not exist at compile time (runtime-only modules, optional deps):

```elixir
# Suppress warning for mock modules that only exist at runtime
@compile {:no_warn_undefined, [CalcMock, StorageMock]}

# Suppress for optional dependency functions
@compile {:no_warn_undefined, {SomeOptionalLib, :function, 2}}
```

**When to use:**
- Test files referencing mock modules created by `Mox.defmock/2`
- Libraries with optional dependencies checked via `Code.ensure_loaded?/1`
- NOT as a general silencer — only for genuinely optional/runtime modules
