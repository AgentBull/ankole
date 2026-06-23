# Elixir Code Style & Formatter Reference

> Supporting reference for the [Elixir skill](SKILL.md). Contains .formatter.exs configuration, migration options, formatter enforcement rules, mix format commands, Credo style checks catalog, readable code patterns (pipelines, guards, pattern match ordering, with-chains, multi-line calls, import organization, naming, conditionals, Ecto.Multi, pure/side-effect separation), and BAD/GOOD pairs.

## Code Style & Formatter

### The Formatter (`mix format`)

#### .formatter.exs Configuration

```elixir
# .formatter.exs (project root)
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  excludes: ["test/fixtures/**/*.{ex,exs}"],   # since v1.19

  # Target line length (soft limit — formatter may exceed when no break point exists)
  line_length: 98,  # default

  # DSL functions that skip parentheses
  locals_without_parens: [
    my_macro: 1,
    my_macro: 2,
    my_dsl: :*      # :* = all arities
  ],

  # Pull locals_without_parens from dependencies
  import_deps: [:phoenix, :ecto, :ecto_sql],

  # Convert all keyword syntax to do-end blocks (convergent — won't convert back)
  force_do_end_blocks: false,  # default

  # Formatter plugins (since v1.13)
  plugins: [Phoenix.LiveView.HTMLFormatter],

  # Subdirectories with their own .formatter.exs (configs NOT inherited)
  subdirectories: ["apps/*"]
]
```

#### Exporting for Library Authors

Libraries export their formatting config so consumers can `import_deps`:

```elixir
# In your library's .formatter.exs
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: [my_macro: 1, my_dsl: :*],
  export: [
    locals_without_parens: [my_macro: 1, my_dsl: :*]
  ]
]
```

#### Migration Options (Since 1.18+)

The formatter can automatically migrate deprecated syntax:

```bash
mix format --migrate
```

| Migration | Version | What it does |
|-----------|---------|-------------|
| `migrate_bitstring_modifiers` | 1.18+ | `<<x::binary()>>` → `<<x::binary>>` |
| `migrate_charlists_as_sigils` | 1.18+ | `'foo'` → `~c"foo"` |
| `migrate_unless` | 1.18+ | `unless x, do: y` → `if !x, do: y` |
| `migrate_call_parens_on_pipe` | 1.19+ | `foo \|> bar` → `foo \|> bar()` |

Enable all at once with `migrate: true` in `.formatter.exs` or `--migrate` flag.

#### What the Formatter Enforces

**Spacing and indentation:**
- 2-space indentation (always)
- Spaces around binary operators: `a + b`, `x |> y`
- Space after `#` in comments: `# comment` (not `#comment`)
- No trailing whitespace
- Single trailing newline at end of file
- Consecutive blank lines squeezed to one

**Parentheses:**
- Added to all function calls except `locals_without_parens`
- Removed from `if`/`unless`/`case`/`cond` conditions
- Added when mixing operators with different precedence
- Zero-arity function definitions: no parens (`def foo do`)

**Line breaking:**
- Breaks at `line_length` boundary when possible
- Multi-line lists/maps/tuples get one element per line with trailing comma position
- Preserves user's choice of `do:` keyword vs `do/end` block (unless `force_do_end_blocks`)
- Preserves intentional blank lines within blocks (squeezed to max 1)

**Number formatting:**
- Large integers get underscores: `1000000` → `1_000_000` (6+ digits)
- Hex digits uppercased: `0xabcd` → `0xABCD`

**What the formatter does NOT enforce:**
- Variable/function naming conventions
- Module organization order
- Pipe usage patterns
- Documentation presence
- Code complexity

#### mix format Commands

```bash
mix format                     # Format all files
mix format --check-formatted   # CI check — exit 1 if unformatted
mix format --dry-run           # Check without writing
mix format --force             # Ignore cache, reformat everything
mix format lib/my_file.ex      # Format specific file
mix format --dot-formatter path/.formatter.exs  # Custom config
```

### Credo Style Checks

Credo enforces semantic style rules the formatter cannot. Key checks organized by impact:

#### High-Priority (Community Consensus)

| Check | Rule |
|-------|------|
| `FunctionNames` | Functions must be `snake_case` |
| `VariableNames` | Variables must be `snake_case` |
| `ModuleNames` | Modules must be `PascalCase` |
| `ModuleAttributeNames` | Attributes must be `snake_case` |
| `PredicateFunctionNames` | Public: end with `?`; Guard macros: start with `is_`, no `?` |
| `PreferUnquotedAtoms` | `:foo` not `:"foo"` |
| `ParenthesesInCondition` | No parens in `if`/`unless` conditions |
| `Semicolons` | Never use `;` — use line breaks |
| `ExceptionNames` | Consistent suffix (e.g., `Error`) |
| `SpaceAroundOperators` | `a + b` not `a+b` |
| `TabsOrSpaces` | Spaces only (2-space indent) |

#### Readability (Recommended)

| Check | Rule |
|-------|------|
| `SinglePipe` | Don't pipe single calls: `list \|> length()` → `length(list)` |
| `ModuleDoc` | Every module needs `@moduledoc` or `@moduledoc false` |
| `AliasOrder` | Alphabetize aliases within groups |
| `SeparateAliasRequire` | Group all `alias` together, all `require` together |
| `LargeNumbers` | Use underscores: `1_000_000` not `1000000` |
| `RedundantBlankLines` | Max 1 consecutive blank line |
| `PipeIntoAnonymousFunctions` | Use `then/1` instead of `\|> (fn x -> ... end).()` |
| `PreferImplicitTry` | Use implicit try in function bodies |
| `StringSigils` | Use `~s` when string has 3+ escaped quotes |
| `OnePipePerLine` | Each `\|>` on its own line |
| `OneArityFunctionInPipe` | `\|> String.downcase()` not `\|> String.downcase` |
| `WithSingleClause` | Single-clause `with` + `else` → use `case` instead |
| `ImplTrue` | `@impl MyBehaviour` over `@impl true` for clarity |

#### Consistency (Team Choice — Pick One)

| Check | Options |
|-------|---------|
| `MultiAliasImportRequireUse` | `alias Mod.{A, B}` vs separate `alias` per module |
| `ParameterPatternMatching` | `pattern = param` vs `param = pattern` |
| `UnusedVariableNames` | `_user` (meaningful) vs `_` (anonymous) |

### Readable Code Patterns

#### Pipeline Readability

```elixir
# GOOD: Multi-step transformation — pipes read left-to-right, top-to-bottom
order
|> calculate_subtotal()
|> apply_discount(coupon)
|> add_tax(state)
|> round_to_cents()

# BAD: Single step — just call the function directly
name |> String.upcase()

# GOOD: Direct call for single transformation
String.upcase(name)

# BAD: Piping to anonymous function
data |> (fn x -> x * 2 end).()

# GOOD: Use then/1 or named function
data |> then(&(&1 * 2))
data |> double()
```

#### Guard Clause Patterns

Use guards for type validation at function boundaries — they're more readable than
`if`/`cond` inside the function body and the type system can reason about them:

```elixir
# GOOD: Guards declare constraints visibly
def chunk_every(enum, count, step)
    when is_integer(count) and count > 0
    when is_integer(step) and step > 0 do
  # ...
end

# GOOD: Type-specialized clauses with guards (fast path first)
def process(items) when is_list(items) do
  Enum.map(items, &transform/1)    # List-optimized path
end

def process(items) do
  items
  |> Enum.to_list()
  |> process()   # General enumerable fallback
end

# BAD: Type check buried in function body
def process(items) do
  if is_list(items) do
    Enum.map(items, &transform/1)
  else
    items |> Enum.to_list() |> process()
  end
end
```

#### Pattern Match Ordering

Always order clauses from most specific to most general:

```elixir
# GOOD: Specific → general
def handle_response({:ok, %{status: 200, body: body}}), do: {:ok, decode(body)}
def handle_response({:ok, %{status: 404}}), do: {:error, :not_found}
def handle_response({:ok, %{status: status}}), do: {:error, {:http_error, status}}
def handle_response({:error, reason}), do: {:error, reason}

# GOOD: Pin operator signals "must match exactly"
case acc do
  [^current | _] -> acc       # Duplicate — skip
  _ -> [current | acc]         # New value — prepend
end

# GOOD: Success path first, then errors
case Repo.insert(changeset) do
  {:ok, record} -> {:ok, record}
  {:error, changeset} -> {:error, format_errors(changeset)}
end
```

#### with-Chain Formatting

```elixir
# GOOD: Each clause on its own line, aligned
with {:ok, user} <- Accounts.get_user(id),
     {:ok, token} <- Tokens.generate(user),
     :ok <- Mailer.send_reset(user, token) do
  {:ok, :email_sent}
else
  {:error, :not_found} -> {:error, :user_not_found}
  {:error, :rate_limited} -> {:error, :try_later}
  {:error, reason} -> {:error, reason}
end

# BAD: with for single clause — use case instead
with {:ok, user} <- Accounts.get_user(id) do
  {:ok, user.name}
else
  {:error, _} -> {:error, :not_found}
end

# GOOD: case for single pattern
case Accounts.get_user(id) do
  {:ok, user} -> {:ok, user.name}
  {:error, _} -> {:error, :not_found}
end
```

#### Multi-Line Function Calls

```elixir
# GOOD: One argument per line when many parameters
defp process_param(
       key,
       params,
       types,
       data,
       defaults,
       {changes, errors, valid?}
     ) do
  # ...
end

# GOOD: Keyword list on separate lines when long
changeset
|> validate_required([:name, :email])
|> validate_format(:email, ~r/@/,
  message: "must contain @"
)
|> validate_length(:name,
  min: 2,
  max: 100,
  message: "must be between 2 and 100 characters"
)
```

#### Import/Alias/Require Organization

See [Module Organization Order](#module-organization-order) below for the full 12-section template.
Quick rule: `use` → `import` → `alias` (alphabetized) → `require`. Always group each kind together.

#### Variable Naming for Readability

```elixir
# GOOD: Descriptive names reveal intent
def transfer(from_account, to_account, amount) do
  # ...
end

# BAD: Single letters obscure meaning (except in short lambdas/comprehensions)
def transfer(a, b, c) do
  # ...
end

# GOOD: Single letters OK in lambdas and comprehensions
Enum.map(users, &(&1.name))
for u <- users, u.active?, do: u.email

# GOOD: Underscore prefix for unused but documented
def handle_info(_message, state), do: {:noreply, state}

# GOOD: Meaningful underscore names when debugging might need them
def handle_call(_request, _from, state), do: {:reply, :ok, state}
```

#### Private Function Naming

Follow the stdlib convention for private helper naming:

```elixir
# Optimized variant for specific type
defp process_list(items) when is_list(items), do: ...
defp process_map(items) when is_map(items), do: ...

# Recursive helper for public function
defp do_transform([], acc), do: Enum.reverse(acc)
defp do_transform([h | t], acc), do: do_transform(t, [convert(h) | acc])

# Reducer functions
defp reduce_totals(item, acc), do: ...
```

#### Readable Conditionals

```elixir
# GOOD: Pattern match in function head — clearest
def status(%Order{paid: true}), do: :paid
def status(%Order{shipped: true}), do: :shipped
def status(%Order{}), do: :pending

# GOOD: case for multiple patterns on same value
case order.status do
  :pending -> process_payment(order)
  :paid -> ship_order(order)
  :shipped -> track_delivery(order)
end

# GOOD: cond for unrelated boolean conditions
cond do
  order.total > 100 -> apply_bulk_discount(order)
  order.coupon != nil -> apply_coupon(order)
  true -> order
end

# BAD: Nested if/else — hard to read
if order.paid do
  if order.shipped do
    :delivered
  else
    :processing
  end
else
  :pending
end
```

#### Ecto.Multi for Readable Transactions

```elixir
# GOOD: Named steps read as a story
def transfer_funds(from, to, amount) do
  result =
    Ecto.Multi.new()
    |> Ecto.Multi.update(:debit, debit_changeset(from, amount))
    |> Ecto.Multi.update(:credit, credit_changeset(to, amount))
    |> Ecto.Multi.insert(:log, transfer_log(from, to, amount))
    |> Repo.transact()

  case result do
    {:ok, %{debit: _debit, credit: _credit, log: log}} ->
      {:ok, log}
    {:error, :debit, _changeset, _changes} ->
      {:error, :insufficient_funds}
    {:error, _failed_step, _changeset, _changes} ->
      {:error, :transfer_failed}
  end
end
```

#### Separation of Pure Logic from Side Effects

```elixir
# GOOD: Pure calculation function — easy to test, easy to read
defmodule MyApp.Pricing do
  def calculate_total(items, tax_rate) do
    subtotal = Enum.reduce(items, Decimal.new(0), &Decimal.add(&2, &1.price))
    tax = Decimal.mult(subtotal, tax_rate)
    Decimal.add(subtotal, tax)
  end
end

# Side effects isolated in context
defmodule MyApp.Orders do
  def create_order(items, params) do
    total = Pricing.calculate_total(items, tax_rate())
    %Order{}
    |> Order.changeset(Map.put(params, :total, total))
    |> Repo.insert()
  end
end
```

#### Module Organization Order

The formatter doesn't enforce section order, but the community convention is:

```elixir
defmodule MyApp.Accounts.User do
  @moduledoc """
  User accounts and authentication.
  """

  # 1. use — changes module fundamentals
  use Ecto.Schema

  # 2. @behaviour — declares contracts this module fulfills
  @behaviour MyApp.Authenticatable

  # 3. import — brings functions into scope
  import Ecto.Changeset

  # 4. alias — shortens module references (STRICTLY alphabetized — Credo enforces)
  alias MyApp.Accounts.{Organization, Team}
  alias MyApp.Repo

  # NOTE: Credo's AliasOrder check enforces strict alphabetical ordering.
  # Do NOT order aliases by "dependency" or "importance" — always alphabetize.
  # Grouped aliases ({A, B}) are sorted by the parent module name.

  # Multi-source alias grouping: group aliases by parent module,
  # then alphabetize the parent groups. Within a group, alphabetize.
  alias MyApp.Accounts.{Organization, Team}  # "MyApp.Accounts" group
  alias MyApp.Repo                            # "MyApp.Repo" group  
  alias Phoenix.LiveView                      # "Phoenix" group

  # Credo sorts by the FULL first segment: MyApp.Accounts < MyApp.Repo < Phoenix
  # Within {braces}, sort alphabetically: {Organization, Team} not {Team, Organization}

  # 5. require — compile-time macros
  require Logger

  # 6. Module attributes — constants, config
  @max_login_attempts 5
  @token_ttl :timer.hours(24)

  # 7. @type / @typep — type definitions
  @type t :: %__MODULE__{}
  @typep state :: :active | :suspended | :deleted

  # 8. @callback — if this module defines a behaviour
  # (not common — usually in a separate behaviour module)

  # 9. Schema / struct definition
  schema "users" do
    field :email, :string
    # ...
  end

  # 10. Public functions — the module's API
  def create(attrs), do: ...
  def get!(id), do: ...

  # 11. Callback implementations (@impl true)
  @impl true
  def authenticate(credentials), do: ...

  # 12. Private functions — in the order they're called from public functions
  defp validate_email(changeset), do: ...
  defp hash_password(changeset), do: ...
end
```

**Key rules:**
- Group related public functions together (all CRUD, all queries, all transformations)
- Place private functions directly after the public function that calls them, or group at the bottom
- `@compile` and `@dialyzer` attributes go after module attributes (section 6), before types

#### Function Ordering Convention

```elixir
# GOOD: Public function followed by its private helpers
def create_order(params) do
  params
  |> build_order()
  |> apply_pricing()
  |> Repo.insert()
end

defp build_order(params), do: ...
defp apply_pricing(order), do: ...

# Next public function and its helpers
def cancel_order(order) do
  order
  |> validate_cancellable()
  |> do_cancel()
end

defp validate_cancellable(order), do: ...
defp do_cancel(order), do: ...
```

**Alternative (also acceptable):** All public functions first, then all private functions grouped logically. Pick one convention per project.

#### Multi-Clause Function Formatting

```elixir
# GOOD: Short clauses — keep together, one line each
def to_status(:pending), do: "Pending"
def to_status(:active), do: "Active"
def to_status(:archived), do: "Archived"

# GOOD: Complex clauses — blank line between each
def handle_event("save", params, socket) do
  # multiple lines...
end

def handle_event("delete", %{"id" => id}, socket) do
  # multiple lines...
end

def handle_event("validate", params, socket) do
  # multiple lines...
end

# When a function has 5+ clauses, consider extracting
# BAD: 8 clauses of handle_event in one module
# GOOD: Extract to a helper or use a lookup
@status_labels %{pending: "Pending", active: "Active", archived: "Archived"}
def to_status(status), do: Map.fetch!(@status_labels, status)
```

#### String Sigil Selection

| Sigil | Interpolation | Escapes | Use When |
|-------|--------------|---------|----------|
| `""` | Yes | Yes | Default — most strings |
| `~s()` | Yes | Minimal | String contains `"` quotes |
| `~S()` | No | No | Raw strings, regex patterns, doctests with `#{}` |
| `~r()` | Yes | Regex | Regular expressions |
| `~w()` | Yes | N/A | Word lists: `~w(foo bar baz)a` for atoms |
| `~c()` | Yes | Yes | Charlists (Erlang interop) — replaces `'string'` |
| `"""` | Yes | Yes | Multi-line strings, heredocs, long SQL |

```elixir
# GOOD: ~s when string has quotes
~s(She said "hello")

# GOOD: ~S in doctests with interpolation syntax (prevents execution)
~S(#{not_interpolated})

# GOOD: ~w for word lists
~w(admin editor viewer)a   # atoms
~w(pending active archived) # strings

# GOOD: Heredoc for multi-line
query = """
SELECT u.name, count(p.id)
FROM users u
JOIN posts p ON p.user_id = u.id
GROUP BY u.name
"""

# BAD: Escaped quotes when sigil is cleaner
"She said \"hello\""
```

#### defdelegate — When to Use

```elixir
# GOOD: Public API delegates to implementation module — keeps context module clean
defmodule MyApp.Accounts do
  defdelegate get_user(id), to: MyApp.Accounts.UserQueries
  defdelegate list_users(opts \\ []), to: MyApp.Accounts.UserQueries
end

# GOOD: Rename on delegation for better API
defdelegate active_users, to: MyApp.Accounts.UserQueries, as: :list_active

# BAD: Delegating when you need to add logic — use a wrapper instead
# defdelegate create_user(attrs), to: MyApp.Accounts.UserCommands
# ↑ If you need to broadcast after creation, delegation can't do that

# GOOD: Wrapper when you need pre/post logic
def create_user(attrs) do
  case UserCommands.create_user(attrs) do
    {:ok, user} = result ->
      broadcast({:user_created, user})
      result
    error -> error
  end
end
```

**Rule:** Use `defdelegate` when the function is a pure pass-through. Use a wrapper function when you need any additional logic.

**defdelegate decision table:**

| Scenario | Use defdelegate? | Why |
|----------|:---:|-----|
| Pure pass-through to internal module | YES | Zero overhead, clean facade |
| Facade context (Phoenix contexts) | YES | Keeps context as routing layer |
| Delegating to Erlang module | YES | `Map` delegates 6 functions to `:maps` |
| Need to rename for better API | YES | Use `as:` option |
| Need to add logging/telemetry | NO | Wrapper — defdelegate can't add logic |
| Need to transform args or return value | NO | Wrapper — defdelegate passes args as-is |
| Need authorization before calling | NO | Wrapper — may need it later |
| Need different @doc than target | NO | defdelegate copies the target's @doc |
| Internal private helper | NO | Just call the function directly |

**Real-world precedent:** Elixir's `Map` module delegates `keys/1`, `values/1`, `merge/2`, `to_list/1`, `from_keys/2`, `intersect/2` to Erlang's `:maps`. Elixir's `String` delegates `split/1`, `trim_leading/1`, `trim_trailing/1` to `String.Break`. Phoenix contexts use defdelegate to route to query/command submodules.

#### Idiomatic Readability Within Formatter Rules

The formatter handles layout, but you control structure. These patterns produce cleaner formatted output:

**Leverage trailing comma position for readability:**
```elixir
# The formatter places trailing content after the last element
# Structure your code to take advantage of this

# GOOD: Keyword list as last argument stays inline or wraps cleanly
Repo.insert(changeset,
  on_conflict: :nothing,
  conflict_target: :email,
  returning: true
)

# GOOD: Map update syntax — formatter aligns nicely
%{socket | assigns: Map.merge(socket.assigns, new_assigns)}
```

**Use intermediate variables to shorten formatted lines:**
```elixir
# BAD: Formatter wraps this into hard-to-read multi-line
Enum.reduce(items, %{total: Decimal.new(0), count: 0}, fn item, %{total: total, count: count} ->
  %{total: Decimal.add(total, item.price), count: count + 1}
end)

# GOOD: Name the accumulator — formatter produces cleaner output
initial = %{total: Decimal.new(0), count: 0}

Enum.reduce(items, initial, fn item, acc ->
  %{acc | total: Decimal.add(acc.total, item.price), count: acc.count + 1}
end)
```

**Break complex expressions at natural boundaries:**
```elixir
# BAD: One long expression — formatter breaks at arbitrary points
from(u in User, join: p in assoc(u, :posts), where: p.published and u.active, select: %{name: u.name, post_count: count(p.id)}, group_by: u.id)

# GOOD: Break at query clauses — each on its own line
from u in User,
  join: p in assoc(u, :posts),
  where: p.published and u.active,
  select: %{name: u.name, post_count: count(p.id)},
  group_by: u.id
```

**Use `then/1` to keep pipelines flowing:**
```elixir
# BAD: Breaking the pipeline for a conditional
result = data |> transform() |> validate()
final = if condition, do: result |> extra_step(), else: result

# GOOD: then/1 keeps it in the pipeline
data
|> transform()
|> validate()
|> then(fn result ->
  if condition, do: extra_step(result), else: result
end)
```

**Consistent map/keyword construction style:**
```elixir
# GOOD: Short maps on one line
%{name: "Alice", role: :admin}

# GOOD: Long maps one-key-per-line (formatter does this at line_length)
%{
  name: "Alice",
  email: "alice@example.com",
  role: :admin,
  inserted_at: DateTime.utc_now()
}

# GOOD: Use variables to build maps incrementally for complex construction
base = %{name: name, email: email}
with_role = Map.put(base, :role, determine_role(attrs))
with_timestamps = Map.merge(with_role, timestamps())
```

**Whitespace as paragraph breaks:**
```elixir
# GOOD: Blank lines separate logical phases within a function
def process_order(params) do
  # Phase 1: Build
  order = build_order(params)
  items = build_line_items(params.items)

  # Phase 2: Calculate
  subtotal = calculate_subtotal(items)
  tax = calculate_tax(subtotal, params.region)
  total = Decimal.add(subtotal, tax)

  # Phase 3: Persist
  order
  |> Order.changeset(%{items: items, total: total})
  |> Repo.insert()
end
```

### Code Style BAD/GOOD

**Fighting the formatter with escape hatches:**
```elixir
# BAD: Manual alignment that formatter will destroy
result = some_function(arg1,
                       arg2,
                       arg3)

# GOOD: Let formatter decide — it uses 2-space nesting
result =
  some_function(
    arg1,
    arg2,
    arg3
  )
```

**Missing import_deps:**
```elixir
# BAD: Duplicating library DSL config in your .formatter.exs
locals_without_parens: [
  get: 3, post: 3, put: 3, patch: 3,  # Phoenix
  field: 2, belongs_to: 3,             # Ecto
  plug: 1, plug: 2                     # Plug
]

# GOOD: Let libraries provide their own config
import_deps: [:phoenix, :ecto, :ecto_sql, :plug]
```

**Pipe into block construct:**
```elixir
# BAD: Piping into case/if/with is hard to follow
data
|> transform()
|> case do
  {:ok, result} -> result
  {:error, _} -> nil
end

# GOOD: Assign, then match
result = data |> transform()
case result do
  {:ok, value} -> value
  {:error, _} -> nil
end

# GOOD: Pipe directly into case — natural end of a pipeline
# Common in Ash, Phoenix, Oban when the pipeline builds a value to branch on
data
|> transform()
|> validate()
|> case do
  {:ok, value} -> value
  {:error, _} -> nil
end
```

**When to use `|> case do`:**
- The expression before `case` is a pipeline (2+ steps) — avoids an intermediate variable
- Only two branches (found/not-found, ok/error) — keeps it readable
- Don't nest `|> case do` inside another `|> case do` — extract a function instead

**Inconsistent do: keyword vs do/end block:**
```elixir
# BAD: Long expression crammed into keyword syntax
if user.admin?, do: render(conn, :admin_dashboard, users: list_users(), stats: get_stats()), else: redirect(conn, to: ~p"/")

# GOOD: Use do/end when expressions are complex
if user.admin? do
  render(conn, :admin_dashboard, users: list_users(), stats: get_stats())
else
  redirect(conn, to: ~p"/")
end

# GOOD: Keyword syntax for short, simple expressions
if user.admin?, do: :admin, else: :user
```

**Deeply nested data access:**
```elixir
# BAD: Chain of Map.get for nested access
city = Map.get(Map.get(Map.get(user, :address, %{}), :location, %{}), :city)

# GOOD: get_in with Access path
city = get_in(user, [:address, :location, :city])

# GOOD: Pattern match when structure is known
%{address: %{location: %{city: city}}} = user
```

**Magic numbers and unnamed constants:**
```elixir
# BAD: What does 86400 mean?
Process.send_after(self(), :cleanup, 86400 * 1000)

# GOOD: Module attribute gives it a name
@cleanup_interval :timer.hours(24)
Process.send_after(self(), :cleanup, @cleanup_interval)
```

**Missing `@doc false` on internal public functions:**
```elixir
# BAD: Omitting @doc — function appears undocumented in ExDoc
def __handle_internal__(data), do: ...

# GOOD: @doc false — explicitly hidden from ExDoc, Credo won't warn
@doc false
def __handle_internal__(data), do: ...

# Also applies to public functions only used by macros or other modules internally
@doc false
def child_spec(opts), do: ...
```

**Inconsistent private function naming:**
```elixir
# BAD: Mixed naming conventions for helpers
defp _internal_process(data), do: ...  # leading underscore = unused convention
defp processHelper(data), do: ...     # camelCase

# GOOD: Consistent snake_case, descriptive prefixes
defp do_process(data), do: ...         # do_ prefix for recursive/core logic
defp build_response(data), do: ...     # verb_ prefix describes action
defp validate_input(data), do: ...
```

**Over-aliasing or under-aliasing:**
```elixir
# BAD: Aliasing a module used only once
alias MyApp.Accounts.Users.ProfilePicture
ProfilePicture.upload(user, file)

# GOOD: Use the full path for one-off usage
MyApp.Accounts.Users.ProfilePicture.upload(user, file)

# BAD: No alias when module is used 3+ times
MyApp.Billing.Invoices.InvoiceCalculator.subtotal(items)
MyApp.Billing.Invoices.InvoiceCalculator.tax(items)
MyApp.Billing.Invoices.InvoiceCalculator.total(items)

# GOOD: Alias when used multiple times
alias MyApp.Billing.Invoices.InvoiceCalculator
InvoiceCalculator.subtotal(items)
InvoiceCalculator.tax(items)
InvoiceCalculator.total(items)
```

**Non-alphabetical alias ordering (Credo AliasOrder):**
```elixir
# BAD: Aliases ordered by "dependency" or "importance" — Credo rejects this
alias MyApp.Sensors.Parser
alias MyApp.Readings.CurrentRow
alias MyApp.Repo

# GOOD: Strictly alphabetical — Credo's AliasOrder check passes
alias MyApp.Readings.CurrentRow
alias MyApp.Repo
alias MyApp.Sensors.Parser
```

**Large number literals without underscores (Credo LargeNumbers):**
```elixir
# BAD: Numbers > 9999 without underscores
register = 40001
timeout = 30000

# GOOD: Underscores for readability
register = 40_001
timeout = 30_000
```

**Using length/1 for non-empty check (Credo):**
```elixir
# BAD: length/1 is O(n) — traverses entire list
assert length(readings) > 0

# GOOD: O(1) non-empty check
assert readings != []
# Or for exact count
assert length(readings) == 5
```

**Case that just passes errors through (use `with` instead):**
```elixir
# BAD: case clause exists only to return the error unchanged
case Native.some_call(args) do
  {:ok, result} -> {:ok, transform(result)}
  {:error, _} = err -> err
end

# GOOD: with handles error passthrough implicitly — non-matching results fall through
with {:ok, result} <- Native.some_call(args) do
  {:ok, transform(result)}
end
# If the function returns {:error, _}, it passes through automatically.
# Use else only when you need to transform or differentiate errors.
```

**Identity case statement (redundant pattern match):**
```elixir
# BAD: every clause returns its own input — the case does nothing
mode = case config.mode do
  :async -> :async
  :sync -> :sync
end

# GOOD: assign directly — validation happened at input boundary
mode = config.mode

# If you need runtime validation, use a guard or function clause:
defp validate_mode!(:async), do: :async
defp validate_mode!(:sync), do: :sync
defp validate_mode!(other), do: raise ArgumentError, "unknown mode: #{inspect(other)}"
```

**Magic number defaults in structs (use module attributes):**
```elixir
# BAD: identity case — returns its own input unchanged
mode = case config.mode do
  :async -> :async
  :sync -> :sync
end
# GOOD: assign directly (validation happened earlier or use guard)
mode = config.mode

# BAD: default repeated in struct definition and constructor
defstruct [timeout: 5_000, max_retries: 3]

def new(opts \\ []) do
  %__MODULE__{
    timeout: Keyword.get(opts, :timeout, 5_000),      # duplicated!
    max_retries: Keyword.get(opts, :max_retries, 3)    # duplicated!
  }
end

# GOOD: module attribute is single source of truth
@default_timeout 5_000
@default_max_retries 3

defstruct [timeout: @default_timeout, max_retries: @default_max_retries]

def new(opts \\ []) do
  %__MODULE__{
    timeout: Keyword.get(opts, :timeout, @default_timeout),
    max_retries: Keyword.get(opts, :max_retries, @default_max_retries)
  }
end
```

## Related Files

- **[SKILL.md](SKILL.md)** — Code style rules (12), key BAD/GOOD pairs, deep-dive link
- **[documentation.md](documentation.md)** — @moduledoc and @doc formatting, ExDoc rendering, doctest conventions, @doc group: metadata
- **[language-patterns.md](language-patterns.md)** — Pattern matching depth, guard expressions, pipeline patterns, comprehension style
- **[type-system.md](type-system.md)** — @spec writing conventions, when NOT to spec, @type best practices
- **[testing-reference.md](testing-reference.md)** — Test naming conventions, describe block organization, setup patterns

