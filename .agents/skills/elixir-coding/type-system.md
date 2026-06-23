# Elixir Type System Reference (1.17-1.20)

> Supporting reference for the [Elixir skill](SKILL.md). Contains the full set-theoretic type system notation, inference, dynamic(), map key domains, typespecs, compiler configuration, roadmap, and BAD/GOOD pairs.

## Type System (Elixir 1.17-1.20)

Elixir has a **gradual set-theoretic type system** built into the compiler. It performs
automatic type inference and checking without requiring type annotations. The system
is sound, gradual (via `dynamic()`), and uses set operations (union, intersection, negation).

### Type System Evolution

| Version | Capabilities |
|---------|-------------|
| 1.17 | Type checking of patterns, guards, and basic expressions. Struct-aware typing. Initial warnings for type mismatches |
| 1.18 | Full type inference of patterns. Type checking across function clauses. Improved map and struct tracking |
| 1.19 | Expanded expression type checking. Better error messages. More stdlib functions typed |
| 1.20 | Full inference of function definitions and guards. Cross-clause type narrowing. Complete map key domain typing. Typed Map module operations. Redundant clause detection |

### Set-Theoretic Type Notation

The compiler uses set-theoretic types in warnings. This notation differs from `@spec` typespecs.

#### Basic Types

```
atom()          # all atoms
binary()        # all binaries (bitstring divisible by 8)
bitstring()     # all bitstrings (binary() is subtype)
integer()       # all integers
float()         # all floats
pid()           # all process identifiers
port()          # all ports
reference()     # all references
empty_list()    # the empty list []
function()      # all functions
map()           # all maps (same as %{...})
tuple()         # all tuples
```

#### Special Types

```
term()          # all types (top type, universal set)
none()          # empty set (no values, e.g. atom() and integer())
dynamic()       # gradual type — range of possible runtime types
not_set()       # marker: map key is absent
if_set(type)    # marker: map key is optional
```

#### Set Operations

```elixir
type1 or type2          # union: either type
type1 and type2         # intersection: both types
type1 and not type2     # difference: first but not second
not type                # negation: everything except type
```

#### Convenience Aliases

```elixir
boolean()       # = true or false
number()        # = integer() or float()
list()          # = empty_list() or non_empty_list(term())
list(a)         # = empty_list() or non_empty_list(a)
```

### Atoms in the Type System

Individual atoms are distinct types:

```elixir
:ok             # the specific atom :ok
:error          # the specific atom :error
nil             # the atom nil
true            # the atom true
false           # the atom false
SomeModule      # module atoms are also types
```

### Tuple Types

```elixir
tuple()                     # all tuples
{:ok, binary()}             # exact 2-element tuple
{:error, binary(), term()}  # exact 3-element tuple
{:ok, binary(), ...}        # at least 2 elements (open tuple)
```

### List Types

```elixir
list(integer())                          # [] or [1, 2, 3]
non_empty_list(integer())                # [1, 2, 3] (not empty)
non_empty_list(integer(), integer())     # improper: [1, 2 | 3]
```

### Map Types

Maps are the most sophisticated part of the type system:

```elixir
# Closed maps — exactly these keys, no more
%{name: binary(), age: integer()}

# Open maps — these keys required, others allowed
%{..., name: binary(), age: integer()}

# Optional keys — may or may not be present
%{name: binary(), age: if_set(integer())}

# Absent keys — key is definitely not present
%{..., age: not_set()}

# Domain keys — non-atom key types (always optional)
%{binary() => integer()}
%{atom() => binary(), integer() => integer()}

# Mixed — domain + specific atom keys (specific overrides domain)
%{atom() => binary(), root: integer()}

# Empty map
empty_map()
```

**Map operation type tracking (1.20+):**

```elixir
Map.put(map, :key, 123)        #=> %{..., key: integer()}
Map.delete(map, :key)          #=> %{..., key: not_set()}
Map.replace(map, :key, 123)    #=> %{..., key: if_set(integer())}

# Bang functions propagate key requirements across modules:
Map.fetch!(map, :name)         # caller must provide %{..., name: term()}
```

### Function Types

```elixir
function()                      # all functions
(integer() -> boolean())        # int argument, bool return
(binary(), binary() -> binary())  # two args

# Multiple clauses use intersection (NOT union):
(integer() -> integer()) and (boolean() -> boolean())
# = function that handles both integer→integer AND boolean→boolean
```

**Why intersection, not union?** A function with multiple clauses belongs to
*both* sets simultaneously — it can handle integers AND booleans. Union would
mean it handles integers OR booleans (not necessarily both).

### The `dynamic()` Type — Gradual Typing

`dynamic()` is the key innovation that lets the type system check existing untyped code.

**How it works:** `dynamic()` represents a *range* of possible runtime types. Unlike `any` in
TypeScript or similar, `dynamic()` still provides meaningful type checking — the compiler
warns only when ALL possible types in the range will fail.

```elixir
# Without dynamic — static typing:
# atom() or integer() given to Integer.to_string/1 → WARNING (atoms fail)

# With dynamic — gradual typing:
# dynamic(atom() or integer()) given to Integer.to_string/1 → no warning
# (at least integer() succeeds, so it might work at runtime)

# But dynamic(atom()) given to Integer.to_string/1 → WARNING
# (no type in the range works)
```

**Dynamic is always at the root:** Writing `{:ok, dynamic()}` gets rewritten to
`dynamic({:ok, term()})`. You cannot make only part of a data structure gradual.

**Modes of type checking:**

| Mode | When | Behavior |
|------|------|----------|
| `:static` | Function has explicit type signature | Full static checking, dynamic() args use subtyping |
| `:dynamic` | Function has no type signature | Gradual checking, wraps returns in dynamic() |
| `:infer` | During inference pass | No warnings, only learns types |

### Type Inference — How It Works

The compiler performs **module-level type inference** automatically:

1. **Pattern inference:** Patterns and guards narrow variable types
2. **Expression inference:** Operators and function calls refine types further
3. **Cross-clause inference:** Each clause's type excludes what previous clauses matched
4. **Cross-module:** Calls to other project modules are typed as `dynamic()` (stdlib and deps are fully typed)

```elixir
# 1. Guard inference
def example(x) when is_integer(x)
# x inferred as: integer()

# 2. Pattern + guard combination
def example({:ok, x} = y) when is_binary(x) or is_integer(x)
# x: binary() or integer()
# y: {:ok, binary() or integer()}

# 3. Map key inference
def example(x) when is_map_key(x, :foo)
# x: %{..., foo: dynamic()}

# 4. Negated guards
def example(x) when not is_map_key(x, :foo)
# x: %{..., foo: not_set()}  — accessing x.foo would be a type violation

# 5. Tuple size tracking
def example(x) when tuple_size(x) < 3
# x has at most 2 elements — elem(x, 3) is a type violation

# 6. Cross-clause narrowing (1.20+)
case System.get_env("VAR") do
  nil -> :not_found           # first clause handles nil
  value -> String.upcase(value) # value narrowed to binary() only
end

# 7. Function body inference (1.20+)
def sum_to_string(a, b) do
  Integer.to_string(a + b)
end
# a and b inferred as integer() (not float!) because
# Integer.to_string/1 only accepts integers
```

### Type Warnings — Reading Compiler Output

The compiler emits structured warnings with types, traces, and locations:

```text
warning: incompatible types given to User.name/1:

    User.name(%{})

given types:

    %{name: not_set()}

but expected one of:

    dynamic(%{..., name: term()})

type warning found at:
│
16 │     User.name(%{})
   │         ~
│
└─ lib/calls_user.ex:7:5: CallsUser.calls_name/0
```

**Common warning categories:**

| Warning | Meaning |
|---------|---------|
| `incompatible types given to` | Function called with wrong argument types |
| `incompatible types in pattern` | Pattern can never match the expression's type |
| `redundant clause` | Previous clauses already cover all cases — dead code |
| `mismatched comparison` | Comparing disjoint types (always true or always false) |
| `struct_comparison` | Using `<`/`>` on structs (structural, not semantic comparison) |
| `unknown_struct_field` | Accessing a field that doesn't exist on the struct |
| `badmap` | Map access on a non-map type |
| `badkey` | Key doesn't exist in the known map/struct shape |
| `badindex` | Tuple element access out of bounds |

### Practical Warning Examples and Fixes

**Map key access on potentially missing key:**
```text
warning: incompatible types given to Map.fetch!/2:
    Map.fetch!(config, :timeout)
given types:
    %{retries: integer()} and :timeout
```
Fix: the map shape doesn't include `:timeout`. Either add the key or use `Map.get/3` with a default.

**Pattern can never match:**
```text
warning: incompatible types in pattern:
    {:ok, value} = result
given types:
    :error or {:error, term()}
```
Fix: the expression only returns error tuples. The `{:ok, _}` branch is dead code — handle the error case.

**Struct comparison with `<`/`>`:**
```text
warning: struct_comparison: using > with struct %DateTime{}
```
Fix: use `DateTime.compare/2` or `DateTime.before?/2` / `DateTime.after?/2` instead of `>`, `<`.

**List concatenation type mismatch:**
```text
warning: incompatible types given to ++/2:
    integer() ++ list(integer())
```
Fix: left side of `++` must be a list. Wrap in list: `[value] ++ rest`.

**Redundant clause (1.20+):**
```text
warning: redundant clause — this clause cannot match because all cases are covered above
```
Fix: the previous clauses already handle all possible inputs. Remove the dead clause or reorder.

### Traditional Typespecs (`@spec` / `@type`)

Typespecs use Erlang-based notation and are **separate from the set-theoretic type system**.
They serve as documentation, are shown in ExDoc, and are used by Dialyzer. They will eventually
be replaced by set-theoretic type signatures in a future Elixir version.

**Typespec notation uses `|` for unions, `::` for type assignment:**

```elixir
# Type definitions
@type status :: :pending | :active | :archived
@type result :: {:ok, term()} | {:error, String.t()}
@type user_id :: pos_integer()

# Struct type (convention: always define t/0)
@type t :: %__MODULE__{
  id: pos_integer() | nil,
  email: String.t(),
  role: :admin | :member | :guest,
  inserted_at: DateTime.t() | nil
}

# IMPORTANT: Ecto schemas start with nil fields — Dialyzer catches this
# when a fresh %Schema{} is passed to changeset/2. Add | nil to all
# non-@enforce_keys fields that don't have a non-nil default value.

# Opaque type — callers cannot inspect internals
@opaque t :: %__MODULE__{data: map()}

# Private type — only visible in this module
@typep internal_state :: {atom(), map()}

# Parameterized type
@type tree(value) :: :leaf | {:node, value, tree(value), tree(value)}
```

**@type best practices:**

```elixir
# ALWAYS define t/0 for structs — it's the convention all tools expect
# For Ecto schemas: fields without defaults start as nil — include | nil
@type t :: %__MODULE__{id: pos_integer() | nil, email: String.t() | nil, role: role()}

# Use @opaque when callers should NOT pattern match on internals
# Dialyzer will warn if callers destructure an opaque type
@opaque t :: %__MODULE__{data: map(), cache: map()}

# Use @typep for module-internal type aliases
@typep internal_state :: {atom(), map(), non_neg_integer()}

# Name types when used in 3+ specs or when the name adds meaning
@type user_id :: pos_integer()
@type coordinates :: {float(), float()}

# Inline types when used once and self-evident
@spec get(pos_integer()) :: t() | nil  # no need for a named "id" type here
```

**Function specs:**

```elixir
@spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
@spec get(pos_integer()) :: t() | nil
@spec list(keyword()) :: [t()]
@spec delete(t()) :: :ok

# Multiple clauses (different arities need separate specs)
@spec parse(binary()) :: {:ok, t()} | {:error, binary()}

# Callback specs with named params
@callback handle_event(event :: term(), state :: t()) ::
  {:ok, t()} | {:error, reason :: term()}

# No return (raises or loops forever)
@spec raise_error(binary()) :: no_return()
```

**`when` clause — type variables for polymorphic functions:**

```elixir
# Return type depends on input type — use `when` to express this
@spec get(agent, (state -> a), timeout) :: a when a: var
# From Elixir's Agent module — `a` is a type variable, `var` means "any type"

# Identity/passthrough functions
@spec identity(a) :: a when a: term()

# Constrained type variable
@spec wrap(a) :: [a] when a: number()

# Multiple type variables
@spec zip(list(a), list(b)) :: list({a, b}) when a: term(), b: term()

# Real-world: Enum.map/2
@spec map(t, (element -> a)) :: [a] when a: var

# Common mistake: don't use `when` if the return type doesn't depend on the input
# BAD: @spec parse(a) :: {:ok, result()} when a: binary()
# GOOD: @spec parse(binary()) :: {:ok, result()}
```

**Key typespec types:**

| Type | Meaning |
|------|---------|
| `term()` | Any type (same as `any()`) |
| `String.t()` | UTF-8 binary (preferred over `binary()` for text) |
| `boolean()` | `true \| false` |
| `number()` | `integer() \| float()` |
| `keyword()` | `[{atom(), term()}]` |
| `keyword(t)` | `[{atom(), t}]` |
| `charlist()` | `[char()]` |
| `iodata()` | `binary() \| iolist()` |
| `iolist()` | Nested lists of bytes/binaries |
| `pos_integer()` | Positive integers (1, 2, 3...) |
| `non_neg_integer()` | Zero and positive (0, 1, 2...) |
| `neg_integer()` | Negative integers (..., -2, -1) |
| `module()` | Atom representing a module |
| `mfa()` | `{module(), atom(), arity()}` |
| `as_boolean(t)` | Returns `t` but treated as truthy/falsy |
| `no_return()` | Function never returns |

### Typespecs vs Set-Theoretic Types — Notation Comparison

| Concept | Typespec (`@spec`) | Set-theoretic (compiler) |
|---------|-------------------|--------------------------|
| Union | `atom() \| integer()` | `atom() or integer()` |
| All terms | `any()` / `term()` | `term()` |
| Empty | `none()` | `none()` |
| Intersection | *(not supported)* | `type1 and type2` |
| Negation | *(not supported)* | `not type` |
| Difference | *(not supported)* | `type1 and not type2` |
| Gradual | *(not available)* | `dynamic()` / `dynamic(type)` |
| Optional map key | *(not expressible)* | `if_set(type)` |
| Absent map key | *(not expressible)* | `not_set()` |
| Open map | `map()` | `%{..., key: type}` |
| Function | `(a, b -> c)` | `(a, b -> c)` |
| Multi-clause fn | *(multiple @spec)* | `(a -> b) and (c -> d)` |

### Compiler Configuration

```elixir
# In mix.exs or config — control type inference scope
Code.put_compiler_option(:infer_signatures, true)    # default: true (= [:elixir])
Code.put_compiler_option(:infer_signatures, false)   # disable module-local inference
Code.put_compiler_option(:infer_signatures, [:elixir, :my_app])  # specific apps

# Type checking still runs regardless of :infer_signatures setting
# The option only controls whether function signatures are inferred
```

### Roadmap — What's Coming

The type system is under active development by the Elixir core team with CNRS:

1. **Current (1.20):** Full inference of existing codebases — no code changes needed
2. **Next milestone:** Typed structs — field types propagated through pattern matching
3. **Future:** Set-theoretic type signatures replace `@spec`/Erlang typespecs entirely

Until type signatures arrive, `@spec` remains the primary way to document function types
for humans and tools (ExDoc, Dialyzer). Write `@spec` for public APIs today — the knowledge
transfers when set-theoretic signatures become available.

### Type System BAD/GOOD

**Ignoring type warnings:**
```elixir
# BAD: Suppressing with a wrapper
def get_name(user), do: user |> Map.from_struct() |> Map.get(:name)

# GOOD: Fix the underlying type issue
@spec get_name(User.t()) :: binary()
def get_name(%User{name: name}), do: name
```

**Overly broad types in specs:**
```elixir
# BAD: map() tells nothing
@spec process(map()) :: map()

# GOOD: Specific struct or key requirements
@spec process(Order.t()) :: {:ok, Invoice.t()} | {:error, binary()}
```

**Using `any()` as escape hatch:**
```elixir
# BAD: Defeats type checking
@spec handle(any()) :: any()

# GOOD: Use term() if truly polymorphic, or specific types
@spec handle(Event.t()) :: :ok | {:error, reason :: binary()}
```

**Not leveraging bang functions for type propagation:**
```elixir
# BAD: Type system can't verify key exists
def get_name(map) do
  case Map.fetch(map, :name) do
    {:ok, name} -> name
    :error -> raise "missing name"
  end
end

# GOOD: Bang function propagates key requirement to callers
def get_name(map), do: Map.fetch!(map, :name)
# Callers must pass %{..., name: term()} — type system enforces this
```

**Wrong set operation for function types:**
```elixir
# BAD: Union means "one or the other" — wrong for multi-clause
# (integer() -> integer()) or (boolean() -> boolean())

# GOOD: Intersection means "handles both" — correct for multi-clause
# (integer() -> integer()) and (boolean() -> boolean())
```

**Redundant type guards when compiler already infers:**
```elixir
# BAD: Unnecessary guard — compiler already knows from pattern
def process(%User{} = user) when is_map(user) do
  user.name
end

# GOOD: Pattern match is sufficient — type system tracks struct shape
def process(%User{} = user) do
  user.name
end
```

### binary() vs String.t() vs iodata() — Decision Table

LLMs frequently confuse these. They are distinct types with different semantics:

| Type | Meaning | Use When |
|------|---------|----------|
| `String.t()` | UTF-8 encoded binary | Text: user input, display strings, JSON values, filenames |
| `binary()` | Raw bytes (any content) | Binary protocols, crypto output, file contents, Erlang interop |
| `iodata()` | `binary() \| iolist()` | Building output for IO/sockets — avoids concatenation |
| `iolist()` | Nested `[binary() \| char() \| iolist()]` | Efficient string building (templates, HTML) |
| `charlist()` | `[char()]` | Erlang interop (`:io_lib.format`, NIF args) |

**Key rules:**
- **PREFER `String.t()` over `binary()`** for text in specs — it documents intent
- **PREFER `iodata()`** for function params that write to IO/sockets — allows callers to pass either binary or iolist without concatenation
- **Use `binary()`** only for raw bytes or Erlang interop where UTF-8 is not guaranteed
- `IO.write/2` accepts `chardata()` (which includes `String.t()` and charlists)
- `IO.binwrite/2` accepts `iodata()` (binary or iolist, no charlists)

**From Elixir stdlib specs (verified):**
```elixir
# String module — always String.t() for text
@spec String.upcase(String.t()) :: String.t()
@spec String.to_integer(String.t()) :: integer()

# IO module — iodata/chardata for output
@spec IO.binwrite(device, iodata) :: :ok
@spec IO.write(device, chardata | String.t()) :: :ok

# IO conversion functions show the relationship
@spec IO.iodata_to_binary(iodata) :: binary        # iodata → raw bytes
@spec IO.chardata_to_string(chardata) :: String.t() # chardata → UTF-8 text
```

**BAD/GOOD:**
```elixir
# BAD: binary() for a user-facing string
@spec greet(binary()) :: binary()

# GOOD: String.t() documents UTF-8 text
@spec greet(String.t()) :: String.t()

# BAD: String.t() for a function that builds HTML (forces concatenation)
@spec render(assigns :: map()) :: String.t()

# GOOD: iodata() lets callers use iolist for efficient building
@spec render(assigns :: map()) :: iodata()

# BAD: binary() for a crypto hash (it IS raw bytes, but document it)
@spec hash(binary()) :: binary()

# BETTER: Named type adds clarity
@type digest :: binary()
@spec hash(binary()) :: digest()
```

### Common @spec Patterns by Context

**GenServer callbacks:**
```elixir
# init/1
@impl true
@spec init(term()) :: {:ok, state()} | {:stop, reason :: term()}

# handle_call/3
@impl true
@spec handle_call(request :: term(), GenServer.from(), state()) ::
        {:reply, reply :: term(), state()}
        | {:noreply, state()}
        | {:stop, reason :: term(), reply :: term(), state()}

# handle_cast/2
@impl true
@spec handle_cast(request :: term(), state()) ::
        {:noreply, state()} | {:stop, reason :: term(), state()}

# handle_info/2
@impl true
@spec handle_info(msg :: term(), state()) ::
        {:noreply, state()} | {:stop, reason :: term(), state()}
```

**Phoenix context functions (standard CRUD):**
```elixir
@spec list_posts(keyword()) :: [Post.t()]
@spec get_post(pos_integer()) :: Post.t() | nil
@spec get_post!(pos_integer()) :: Post.t()
@spec create_post(map()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
@spec update_post(Post.t(), map()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
@spec delete_post(Post.t()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
@spec change_post(Post.t(), map()) :: Ecto.Changeset.t()
```

**Ecto changeset functions:**
```elixir
@spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
@spec registration_changeset(t(), map()) :: Ecto.Changeset.t()
```

**Plug:**
```elixir
@spec init(keyword()) :: keyword()
@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
```

**Phoenix LiveView callbacks:**
```elixir
@spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
@spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
        {:noreply, Phoenix.LiveView.Socket.t()}
@spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
        {:noreply, Phoenix.LiveView.Socket.t()}
@spec render(map()) :: Phoenix.LiveView.Rendered.t()
```

### Custom Guards and Type Inference

`defguard` creates reusable guard expressions. The type system understands guards for narrowing:

```elixir
# Define a custom guard
defguard is_positive_integer(value) when is_integer(value) and value > 0

# The type system narrows based on the guard's conditions
def process(x) when is_positive_integer(x) do
  # x is known to be integer() here
  Integer.to_string(x)
end

# defguardp for module-private guards
defguardp is_valid_status(s) when s in [:active, :inactive, :pending]

def update_status(record, status) when is_valid_status(status) do
  # status narrowed to :active or :inactive or :pending
  %{record | status: status}
end
```

**Type system interaction:** Guards composed of Kernel guard-safe functions (`is_integer/1`, `is_binary/1`, `is_map/1`, `is_atom/1`, `in/2`, comparison operators, `and`/`or`/`not`) all feed type inference. The compiler tracks the narrowing from each guard clause.

**Important:** Only expressions allowed in guards can appear in `defguard`. These include: type checks (`is_*`), comparisons, arithmetic, boolean operators, `in/2`, `elem/2`, `hd/1`, `tl/1`, `length/1`, `map_size/1`, `tuple_size/1`, `is_map_key/2`, `binary_part/3`, and `node/0-1`.

### Behaviour @callback and Type Checking

When a module implements a behaviour with `@impl true`, the type system uses the `@callback` specs for checking:

```elixir
defmodule MyBehaviour do
  @callback process(input :: term()) :: {:ok, result :: term()} | {:error, String.t()}
end

defmodule MyImpl do
  @behaviour MyBehaviour

  @impl true
  def process(input) do
    # Compiler knows this must return {:ok, _} | {:error, String.t()}
    # If you return :wrong, you'll get a type warning (1.20+)
    {:ok, transform(input)}
  end
end
```

The compiler checks that `@impl true` functions conform to the callback spec's return type. This is separate from Dialyzer — it's built into the compiler's type checking pass.

### Dialyzer — Static Analysis with @spec

Dialyzer (DIscrepancy AnaLyzer for ERlang) performs additional static analysis beyond the compiler's type system. It uses `@spec` annotations and builds a PLT (Persistent Lookup Table) of type information.

**Setup with Dialyxir:**

```elixir
# mix.exs — add to deps
defp deps do
  [
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
  ]
end

# mix.exs — optional project config
def project do
  [
    ...,
    dialyzer: [
      plt_add_apps: [:mix, :ex_unit],       # add apps to PLT
      plt_core_path: "_build/plt",           # cache PLT locally
      flags: [:unmatched_returns, :error_handling, :underspecs]
    ]
  ]
end
```

**Running:**
```bash
mix dialyzer              # First run builds PLT (slow), subsequent runs are fast
mix dialyzer --format short  # Compact output
```

**Compiler type system vs Dialyzer:**

| Aspect | Compiler (1.17+) | Dialyzer |
|--------|-----------------|----------|
| Approach | Set-theoretic inference | Success typing |
| Annotations needed | None (infers from code) | Uses `@spec` |
| Warnings | Type mismatches, dead code | Contract violations, unreachable code |
| Speed | Runs during compilation | Separate pass (slower) |
| Gradual | Yes (`dynamic()`) | No (either typed or untyped) |
| False positives | Very low | Occasional |
| Cross-module | stdlib typed, project code = `dynamic()` | Full cross-module via PLT |

**Recommendation:** Use both. The compiler's type system catches structural errors during development. Dialyzer catches contract violations and cross-module issues. They complement each other — Dialyzer uses `@spec`, the compiler infers types independently.

**Common Dialyzer warnings:**

| Warning | Meaning |
|---------|---------|
| `The pattern can never match the type` | Dead code — pattern doesn't match possible values |
| `Function has no local return` | Function always raises or loops |
| `The created fun has no local return` | Anonymous function always fails |
| `Contract violation` | Return value doesn't match @spec |
| `Callback info mismatch` | @impl doesn't match @callback spec |

### When NOT to Write @spec

Not every function needs a spec. Over-speccing adds noise and maintenance burden without value.

**ALWAYS spec:**
- Public API functions (the module's contract with callers)
- Behaviour callbacks (`@callback`)
- Functions with non-obvious return types
- Functions where type discipline prevents bugs (money, IDs, timestamps)

**SKIP specs for:**
- Trivial private helpers where types are obvious from the code
- Single-use `defp` functions that just extract a step from a pipeline
- Functions whose types are fully determined by the caller (private map/filter callbacks)
- Test helper functions

```elixir
# GOOD: Public API — spec adds value
@spec transfer(Account.t(), Account.t(), Decimal.t()) :: {:ok, Transfer.t()} | {:error, atom()}
def transfer(from, to, amount), do: ...

# UNNECESSARY: Trivial private helper — type is obvious
# @spec format_name(String.t(), String.t()) :: String.t()  # skip this
defp format_name(first, last), do: "#{first} #{last}"

# GOOD: Private but non-obvious return type
@spec calculate_fee(Decimal.t(), :standard | :express) :: Decimal.t()
defp calculate_fee(amount, tier), do: ...
```

### @spec for Erlang Interop

Erlang functions return Erlang types. These are where `binary()` vs `String.t()` vs `iodata()` matters most:

```elixir
# Networking — raw binary data, NOT UTF-8 text
@spec send_packet(port(), binary()) :: :ok | {:error, :closed | :timeout}
def send_packet(socket, data) do
  :gen_tcp.send(socket, data)
end

# Crypto — raw bytes in, raw bytes out
@spec hash(binary()) :: binary()
def hash(data), do: :crypto.hash(:sha256, data)

# Erlang string formatting — returns charlist, convert to String.t()
@spec format_number(number()) :: String.t()
def format_number(n) do
  :io_lib.format("~.2f", [n]) |> IO.chardata_to_string()
end

# NIF return types — match the NIF's actual return
@spec nif_parse(binary()) :: {:ok, map()} | {:error, binary()}
def nif_parse(input), do: MyNif.parse(input)

# ETS — term() in, term() out (ETS stores any term)
@spec cache_get(atom(), term()) :: term() | nil
def cache_get(table, key) do
  case :ets.lookup(table, key) do
    [{^key, value}] -> value
    [] -> nil
  end
end

# :timer — returns microseconds as integer
@spec measure((() -> term())) :: {non_neg_integer(), term()}
def measure(fun), do: :timer.tc(fun)
```

### Common @type Patterns for Reuse

Define named types for concepts that appear across multiple specs:

```elixir
# Option/config types — enumerate valid options
@type option ::
  {:timeout, pos_integer()}
  | {:retries, non_neg_integer()}
  | {:on_error, :raise | :return}
@type options :: [option()]

@spec start(options()) :: {:ok, pid()} | {:error, term()}

# Result types — standard ok/error with specific error reasons
@type error_reason :: :not_found | :unauthorized | :validation_failed
@type result :: {:ok, t()} | {:error, error_reason()}
@type result(value) :: {:ok, value} | {:error, error_reason()}

# Pagination
@type page :: pos_integer()
@type per_page :: pos_integer()
@type paginated(item) :: %{
  entries: [item],
  page: page(),
  per_page: per_page(),
  total_entries: non_neg_integer(),
  total_pages: non_neg_integer()
}

@spec list_users(page(), per_page()) :: paginated(User.t())

# ID types — prevent mixing different entity IDs
@type user_id :: pos_integer()
@type post_id :: pos_integer()
@type uuid :: String.t()

# Callback/function types
@type handler :: (Event.t() -> :ok | {:error, term()})
@type transformer(input, output) :: (input -> output)
```

### Dialyzer False Positives and Suppression

Dialyzer uses success typing which can produce false positives. Handle them carefully:

**Common false positive scenarios:**

1. **Dynamic dispatch** — Dialyzer can't follow `apply/3` or module variables
2. **Protocol dispatch** — implementations added at runtime
3. **Macro-generated code** — Dialyzer sees the expanded code, not the macro
4. **Ecto query types** — `Repo.all(query)` returns `[term()]` to Dialyzer

**Suppression (use sparingly):**

```elixir
# Suppress specific warning for a single function
@dialyzer {:nowarn_function, my_function: 2}

# Suppress specific warning type
@dialyzer {:no_return, my_function: 1}        # "no local return" warning
@dialyzer {:no_match, my_function: 3}         # "pattern can never match"
@dialyzer {:no_unused, my_function: 0}        # "function never used"
@dialyzer {:no_contracts, my_function: 1}     # "contract violation"

# Suppress all warnings for a function (last resort)
@dialyzer {:nowarn_function, [fun_a: 2, fun_b: 1]}

# Module-level suppression (avoid — too broad)
@dialyzer :no_return
```

**Better alternatives to suppression:**
- Fix the spec to be more accurate (most common solution)
- Add a guard or pattern match that Dialyzer can follow
- Use `@spec` with broader types that match actual runtime behaviour
- For protocol dispatch, spec the return as the protocol's declared type

```elixir
# BAD: Suppress because Dialyzer doesn't understand dynamic dispatch
@dialyzer {:nowarn_function, dispatch: 2}
def dispatch(module, event), do: apply(module, :handle, [event])

# BETTER: Constrain the module type so Dialyzer can reason about it
@spec dispatch(module(), Event.t()) :: :ok | {:error, term()}
def dispatch(module, event) when is_atom(module), do: module.handle(event)
```

### Version Feature Summary

| Feature | Version | Impact |
|---------|---------|--------|
| Pattern/guard type inference | 1.17 | Compiler warns on type mismatches in patterns |
| Cross-clause pattern typing | 1.18 | Type narrows across function clauses |
| Expanded expression checking | 1.19 | More operators and expressions type-checked |
| Function body inference | 1.20 | Full inference without annotations |
| Typed Map operations | 1.20 | `Map.put/delete/replace` tracked in types |
| Redundant clause detection | 1.20 | Dead code warnings for unreachable clauses |
| Cross-clause narrowing | 1.20 | `case`/`cond` branches narrow types |

### Minimum Version Guidance

When targeting older Elixir versions, know what type features are available:

| If you target... | You get... | You miss... |
|-------------------|-----------|-------------|
| **1.17+** | Basic pattern/guard warnings, struct-aware typing | Cross-clause narrowing, Map tracking, redundant clause detection |
| **1.18+** | + Cross-clause patterns, improved map/struct tracking | Function body inference, Map operation typing |
| **1.19+** | + Expanded expression checking, better errors | Full function inference, redundant clause detection |
| **1.20+** | Full type system — all features | Nothing (current) |

**Practical impact:**
- **1.17:** Catches obvious type errors in patterns (`case :ok do "string" -> ... end`)
- **1.18:** Catches cross-clause issues (`def f(:a), do: 1; def f(:a), do: 2`)
- **1.19:** Catches more expression-level errors (arithmetic, string ops on wrong types)
- **1.20:** Catches function-level issues (return type mismatches, dead code, Map key tracking)

**Recommendation:** Target **1.18+** minimum for meaningful type checking. The jump from 1.17 to 1.18 added cross-clause analysis which catches the most impactful bugs. 1.20 is ideal for new projects.

## Related Files

- **[SKILL.md](SKILL.md)** — Type system rules (7), key concepts, deep-dive link
- **[documentation.md](documentation.md)** — @spec in documentation, @typedoc, ExDoc rendering of types
- **[testing-reference.md](testing-reference.md)** — Testing type-related behaviour, StreamData for property testing
- **[language-patterns.md](language-patterns.md)** — Pattern matching, guards, and how they feed type inference
- **[debugging-profiling.md](debugging-profiling.md)** — Compiler warnings configuration, --warnings-as-errors

