# Elixir Documentation & Doctests Reference

> Supporting reference for the [Elixir skill](SKILL.md). Contains LLM rules, @moduledoc/@doc patterns, @spec/@type/@typedoc, @since/@deprecated, doctest syntax (multi-line, exceptions, opaque values, ellipsis matching), ExDoc configuration, cross-reference syntax, and BAD/GOOD pairs.

## Documentation & Doctests

### Rules for Documentation (LLM)

1. **ALWAYS add `@moduledoc`** to every public module — `@moduledoc false` for internal/private modules
2. **ALWAYS add `@doc` and `@spec`** to every public function — `@doc false` for intentionally undocumented helpers
3. **ALWAYS start `@moduledoc` and `@doc` with a concise summary line** — ExDoc uses the first paragraph for search/index
4. **ALWAYS include `## Examples` with `iex>` doctests** for pure functions — doctests are both documentation AND tests
5. **ALWAYS place `@doc` before the FIRST clause** of multi-clause functions — docs are per function/arity, not per clause
6. **ALWAYS pair `@deprecated` with `@doc false`** — hide deprecated functions from docs, show migration path in deprecation message
7. **NEVER write docs that just repeat the function name** — `@doc "Gets the user"` for `get_user/1` adds no value
8. **ALWAYS use backtick cross-references** for related modules and functions — `` `Module` ``, `` `Module.function/arity` ``, `` `t:type/0` ``, `` `c:callback/1` ``
9. **ALWAYS document `:ok/:error` return shapes** explicitly — callers need to know what to pattern match on
10. **PREFER `@typedoc`** for complex or important types — especially `@type t` on structs

### @moduledoc — Module Documentation

```elixir
defmodule MyApp.Accounts do
  @moduledoc """
  User account management and authentication.

  This module provides the public API for creating, updating, and
  authenticating users. It delegates to `MyApp.Accounts.User` for
  schema details and `MyApp.Accounts.Token` for session management.

  ## Examples

      iex> MyApp.Accounts.get_user(123)
      {:ok, %MyApp.Accounts.User{id: 123, email: "user@example.com"}}

      iex> MyApp.Accounts.get_user(-1)
      {:error, :not_found}

  ## Authentication

  Authentication uses bcrypt password hashing via `Bcrypt`.
  See `authenticate/2` for details.
  """
end
```

**Structure** (from Enum, Map, GenServer, Ecto.Changeset):
1. One-to-three sentence summary (first paragraph — used by ExDoc for index)
2. Detailed explanation paragraphs
3. `## Examples` with `iex>` prompts
4. `## Section` headers for major topics (Options, Differences, Notes)

**`@moduledoc false`** — for internal modules:

```elixir
# Internal implementation modules
defmodule MyApp.Accounts.Helpers do
  @moduledoc false
  # ...
end

# Protocol implementations (auto-generated docs are sufficient)
defimpl String.Chars, for: MyApp.User do
  @moduledoc false
  # ...
end
```

### @doc — Function Documentation

```elixir
@doc """
Fetches a user by ID.

Returns `{:ok, user}` if found, `{:error, :not_found}` otherwise.
Preloads the user's `:organization` association.

## Examples

    iex> MyApp.Accounts.get_user(123)
    {:ok, %User{id: 123}}

    iex> MyApp.Accounts.get_user(-1)
    {:error, :not_found}

## Options

  * `:preload` - associations to preload (default: `[:organization]`)
  * `:lock` - whether to lock the row for update (default: `false`)

"""
@spec get_user(pos_integer(), keyword()) :: {:ok, User.t()} | {:error, :not_found}
def get_user(id, opts \\ [])
```

**Key patterns from major projects:**

```elixir
# Multi-clause functions — @doc goes before the first clause only
@doc "Deletes the given element from the list. Returns a new list."
@spec delete(list, any) :: list
def delete([element | list], element), do: list
def delete([other | list], element), do: [other | delete(list, element)]
def delete([], _element), do: []

# @doc false — intentionally undocumented
@doc false
def __struct__, do: %__MODULE__{}

# @doc false + @deprecated — deprecated function (from Enum)
@doc false
@deprecated "Use Enum.chunk_every/2 instead"
def chunk(enumerable, count), do: chunk_every(enumerable, count)

# @impl true — inherits @doc from the behaviour callback definition
# Do NOT add a redundant @doc when @impl true is sufficient
@impl true
def handle_call(:get_state, _from, state) do
  {:reply, state, state}
end

# @impl true WITH custom @doc — overrides the behaviour's doc
@impl true
@doc "Returns the cached state, refreshing if older than TTL."
def handle_call(:get_state, _from, state) do
  {:reply, maybe_refresh(state), state}
end

# Delegate documentation (from Map)
@doc """
Builds a map from the given `keys` and the fixed `value`.

## Examples

    iex> Map.from_keys([1, 2, 3], :number)
    %{1 => :number, 2 => :number, 3 => :number}

"""
@doc since: "1.14.0"
@spec from_keys([key], value) :: map
defdelegate from_keys(keys, value), to: :maps

# @doc group: for organizing functions in ExDoc sidebar
@doc group: "Query"
@doc """
Lists users matching the given filters.
"""
def list_users(filters \\ []), do: ...

@doc group: "Mutation"
@doc """
Creates a new user account.
"""
def create_user(attrs), do: ...
```

### @spec — Typespecs

```elixir
# Basic spec
@spec fetch(map, key) :: {:ok, value} | :error

# With named parameters in callback (from GenServer)
@callback handle_call(request :: term, from, state :: term) ::
            {:reply, reply, new_state}
            | {:noreply, new_state}
            | {:stop, reason, reply, new_state}
          when reply: term, new_state: term, reason: term

# Keyword options — spell them out
@spec start_link(keyword()) :: GenServer.on_start()
# Better — explicit options:
@spec start_link([{:name, atom()} | {:timeout, pos_integer()}]) :: GenServer.on_start()

# Multiple clauses for different arities/types (from List)
@spec delete([], any) :: []
@spec delete([...], any) :: list

# Function that never returns normally
@spec raise!(String.t()) :: no_return

# Private functions — specs are optional but helpful for complex ones
```

**When to add specs:**
- All public functions (required for Dialyzer, documentation)
- Complex private functions (aids readability)
- All callbacks in behaviour definitions (required)
- Not needed: trivial private helpers, test code

### @type and @typedoc

```elixir
# Every struct should have @type t (from Plug.Conn, Ecto.Changeset, etc.)
defmodule MyApp.User do
  @moduledoc "User account."

  @typedoc "A user account with email and role."
  @type t :: %__MODULE__{
    id: pos_integer() | nil,
    email: String.t() | nil,
    role: role() | nil,
    inserted_at: DateTime.t() | nil
  }

  @typedoc "User role within the organization."
  @type role :: :admin | :member | :viewer

  defstruct [:id, :email, :role, :inserted_at]
end

# Opaque type — callers cannot pattern match on internals
@opaque t :: %__MODULE__{data: map(), valid?: boolean()}

# Complex return type — give it a name for readability
@typedoc "Result of a batch operation."
@type batch_result :: %{
  success: non_neg_integer(),
  failure: non_neg_integer(),
  errors: [{pos_integer(), term()}]
}

# Recursive types (from Absinthe, Torque)
@type json_value :: String.t() | number() | boolean() | nil
                  | [json_value()] | %{String.t() => json_value()}

# Parameterized types (from Enumerable)
@typedoc "An enumerable of elements of type `element`."
@type t(element) :: t()
```

### @since and @deprecated

```elixir
# Mark when a function was added (from Map, Enum, Regex)
@doc since: "1.14.0"
@spec from_keys([key], value) :: map
def from_keys(keys, value), do: ...

# Soft deprecation — appears in docs, no compile warning
@doc deprecated: "Use Foo.bar/2 instead"
def old_function(x), do: x

# Hard deprecation — compile warning + hidden from docs
@doc false
@deprecated "Use Enum.chunk_every/2 instead"
def chunk(enumerable, count), do: chunk_every(enumerable, count)
```

### Doctests

Doctests are executable examples in `@doc` and `@moduledoc` strings — they serve as both documentation and tests.

#### Basic Syntax

```elixir
@doc """
Adds two numbers.

## Examples

    iex> MyApp.Math.add(1, 2)
    3

    iex> MyApp.Math.add(-1, 1)
    0

"""
def add(a, b), do: a + b
```

**Rules:**
- Prefix with `iex>`, continuation lines with `...>`
- Expected output on line immediately after (no blank line)
- Indent 4 spaces within `@doc` strings
- Separate independent examples with blank lines (each gets its own test context)

#### Multi-line Expressions

```elixir
@doc """
## Examples

    iex> map = %{a: 1, b: 2}
    iex> Map.merge(map, %{b: 3, c: 4})
    %{a: 1, b: 3, c: 4}

    iex> Enum.chunk_while(1..10, [], fn element, acc ->
    ...>   if rem(element, 2) == 0 do
    ...>     {:cont, Enum.reverse([element | acc]), []}
    ...>   else
    ...>     {:cont, [element | acc]}
    ...>   end
    ...> end, fn
    ...>   [] -> {:cont, []}
    ...>   acc -> {:cont, Enum.reverse(acc), []}
    ...> end)
    ...> |> Enum.to_list()
    [[1, 2], [3, 4], [5, 6], [7, 8], [9, 10]]

"""
```

#### Exception Doctests

```elixir
@doc """
## Examples

    iex> Map.fetch!(%{a: 1}, :b)
    ** (KeyError) key :b not found in: %{a: 1}

    iex> Torque.decode!("invalid")
    ** (ArgumentError) JSON parse error

"""
```

Format: `** (ExceptionModule) message text`

#### Opaque Values (#Name<...>)

```elixir
@doc """
## Examples

    iex> DateTime.from_naive!(~N[2023-06-26T09:30:00], "Etc/UTC")
    ~U[2023-06-26 09:30:00Z]

    iex> Regex.compile!("foo")
    ~r/foo/

"""
```

When output starts with `#Name<`, ExUnit compares against `inspect()` output as a string. Use sigils (`~r`, `~U`, `~N`, `~D`, `~T`) when available for cleaner output.

#### Omitting Output

```elixir
@doc """
## Examples

    # When return value is unpredictable (PIDs, references)
    iex> pid = spawn(fn -> :ok end)
    iex> is_pid(pid)
    true

    # When you only care that it doesn't raise
    iex> MyApp.setup_worker!()

"""
```

If a doctest line has no expected output, it just asserts no exception is raised.

#### Ellipsis Matching (Elixir 1.19+)

```elixir
@doc """
## Examples

    iex> raise "error in pid: \#{inspect(self())}"
    ** (RuntimeError) error in pid: ...

"""
```

Use `...` for non-deterministic parts of exception messages.

#### ~S Sigil for Doctests with Special Characters

Use `~S"""` instead of `"""` when your doctest contains `#{}` interpolation or backslash escapes that should be literal:

```elixir
# BAD: interpolation executes at compile time, not in doctest
@doc """
## Examples

    iex> "Hello #{name}"   # This interpolates at compile time!
"""

# GOOD: ~S prevents interpolation — shows literal #{} in doctest
@doc ~S"""
Builds a greeting string.

## Examples

    iex> name = "World"
    iex> "Hello #{name}"
    "Hello World"

"""
def greet(name), do: "Hello #{name}"

# Also useful for regex and escape sequences in doctests
@doc ~S"""
## Examples

    iex> String.replace("a\nb", ~r/\n/, " ")
    "a b"

"""
```

**Rule:** Use `~S"""` whenever your doctest contains `#{}`, `\n`, `\t`, or other escape sequences that should appear literally in the example.

#### Doctest Gotchas

```elixir
# GOTCHA 1: Map key ordering — maps don't guarantee order
# BAD: may fail if keys print in different order
    iex> Map.merge(%{a: 1}, %{b: 2, c: 3})
    %{a: 1, b: 2, c: 3}
# GOOD: works because Elixir sorts small map keys in inspect output
# (Safe for maps with ≤32 keys — Elixir sorts them deterministically)

# GOTCHA 2: Binding leaks between consecutive iex> lines
    iex> x = 1       # x is bound
    iex> x + 1        # x is still bound (same doctest block)
    2
# Separate blocks (blank line between) get independent bindings

# GOTCHA 3: Modules defined in doctests persist for the whole test suite
# NEVER define modules in doctests — use unit tests instead

# GOTCHA 4: Doctest output comparison is string-based
# The expected output must match inspect() output exactly
    iex> Decimal.new("3.14")
    #Decimal<3.14>           # Must match inspect output format
```

#### Running Doctests

```elixir
# In test file — run all doctests for a module
defmodule MyApp.AccountsTest do
  use ExUnit.Case, async: true
  doctest MyApp.Accounts
end

# Selective doctests
doctest MyApp.Accounts, only: [get_user: 1, create_user: 1]
doctest MyApp.Accounts, except: [:moduledoc]  # Skip module-level doctests
doctest MyApp.Accounts, import: true          # Import module functions

# Doctests from Markdown files (Elixir 1.15+)
doctest_file "README.md"
doctest_file "guides/getting-started.md"
```

#### When to Use Doctests vs Unit Tests

| Use doctests for | Use unit tests for |
|---|---|
| Pure functions with simple inputs/outputs | Complex setup, database, processes |
| Demonstrating API usage | Testing edge cases and error paths |
| Functions with predictable output | Non-deterministic behavior |
| Quick examples that aid understanding | Comprehensive validation testing |
| Functions returning simple values | Side effects (IO, messages, state changes) |

**Don't use doctests when:**
- The function has side effects (prints, sends messages)
- The example defines modules (they persist across the test suite)
- The output is non-deterministic (PIDs, timestamps, random values)
- Complex setup is needed (database, GenServer state)

### ExDoc Configuration

```elixir
# In mix.exs
defp project do
  [
    # ...
    docs: docs()
  ]
end

defp docs do
  [
    main: "MyApp",                          # Landing page module
    source_ref: "v#{@version}",             # Git tag for source links
    source_url: "https://github.com/me/my_app",
    logo: "priv/static/logo.png",
    extras: extras(),
    groups_for_extras: groups_for_extras(),
    groups_for_modules: groups_for_modules(),
    formatters: ["html", "epub"]
  ]
end

# Organize guide documents (from Phoenix, Ecto, Ash)
defp extras do
  [
    {"README.md", title: "Overview"},
    "guides/getting-started.md",
    "guides/deployment.md",
    "CHANGELOG.md"
  ]
end

defp groups_for_extras do
  [
    Introduction: ~r/guides\/introduction\/.?/,
    Guides: ~r/guides\/[^\/]+\.md/
  ]
end

# Organize modules in sidebar (from Phoenix)
defp groups_for_modules do
  [
    Core: [MyApp, MyApp.Application],
    Contexts: [MyApp.Accounts, MyApp.Catalog],
    Schemas: [MyApp.Accounts.User, MyApp.Catalog.Product],
    "Web Layer": [MyAppWeb.Router, MyAppWeb.Endpoint],
    Testing: [MyApp.DataCase, MyApp.ConnCase]
  ]
end
```

**Advanced ExDoc features** (from Phoenix, Ash):

```elixir
defp docs do
  [
    # Group functions within a module by metadata
    groups_for_docs: [
      Reflection: &(&1[:type] == :reflection),
      Queries: &(&1[:group] == "Query")
    ],

    # Multi-package search (users search across related packages)
    search: [
      %{
        name: "Latest",
        help: "Search latest versions of Ecto + Ecto SQL",
        packages: [:ecto, :ecto_sql]
      }
    ],

    # Suppress warnings for specific files
    skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
  ]
end
```

### Cross-Reference Syntax

```elixir
@doc """
See `MyApp.Accounts` for the full API.
Uses `MyApp.Accounts.User` schemas.
Returns `t:MyApp.Accounts.User.t/0` structs.
Implements the `c:GenServer.handle_call/3` callback.

Link to module: `MyApp.Router`
Link to function: `Enum.map/2`
Link to type: `t:String.t/0`
Link to callback: `c:GenServer.init/1`
Link to external: `m:Kernel`

Auto-linked (no prefix needed within same module):
`my_function/2`, `MyType.t/0`
"""
```

### Documentation BAD/GOOD Pairs

**Docs that just repeat the name:**
```elixir
# BAD
@doc "Gets the user."
def get_user(id), do: ...

# GOOD
@doc """
Fetches a user by ID, preloading their organization.

Returns `{:ok, user}` if found, `{:error, :not_found}` otherwise.
"""
def get_user(id), do: ...
```

**Missing return value documentation:**
```elixir
# BAD — caller doesn't know what to pattern match
@doc "Creates a user from the given attributes."
def create_user(attrs), do: ...

# GOOD — explicit return shapes
@doc """
Creates a user from the given attributes.

Returns `{:ok, user}` on success, `{:error, changeset}` on validation failure.

## Examples

    iex> create_user(%{email: "test@example.com"})
    {:ok, %User{}}

    iex> create_user(%{email: ""})
    {:error, %Ecto.Changeset{}}

"""
@spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
def create_user(attrs), do: ...
```

**Doctest that can't actually run:**
```elixir
# BAD — requires database, will fail as doctest
@doc """
## Examples

    iex> MyApp.Accounts.create_user(%{email: "test@example.com"})
    {:ok, %User{id: 1}}

"""

# GOOD — use unit tests for DB operations, doctests for pure functions
@doc """
Creates a user from the given attributes.

Returns `{:ok, user}` on success, `{:error, changeset}` on validation failure.
See tests for usage examples.
"""
```

**Missing @spec on public function:**
```elixir
# BAD — no type information for callers or Dialyzer
def process(input), do: ...

# GOOD
@spec process(String.t()) :: {:ok, map()} | {:error, atom()}
def process(input), do: ...
```

**@moduledoc on internal module:**
```elixir
# BAD — clutters documentation with implementation details
defmodule MyApp.Accounts.Helpers do
  @moduledoc "Helper functions for accounts."
  # ...
end

# GOOD — hide internal modules
defmodule MyApp.Accounts.Helpers do
  @moduledoc false
  # ...
end
```

## Related Files

- **[SKILL.md](SKILL.md)** — Core documentation rules (10 rules), key @doc/@spec pattern, common @spec patterns, deep-dive link
- **[type-system.md](type-system.md)** — Set-theoretic types (1.17+), @spec notation, type inference, compiler warnings, gradual typing
- **[testing-reference.md](testing-reference.md)** — Doctest-driven development pattern, ExUnit doctest options
- **[language-patterns.md](language-patterns.md)** — Behaviours (@callback docs), protocols (@impl interaction), @enforce_keys
- **[code-style.md](code-style.md)** — Credo documentation checks, formatter interaction with @doc strings
