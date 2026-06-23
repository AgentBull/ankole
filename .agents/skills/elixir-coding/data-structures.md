# Elixir Data Structures Reference

> Supporting reference for the [Elixir skill](SKILL.md). Contains selection guide, performance characteristics, lists (linked lists, head/tail idioms, IO lists, charlists), maps (access, update, nested, patterns), tuples (tagged tuples, ETS), keyword lists, MapSet, Ranges, Erlang data structures (:queue, :digraph, :ordsets), structs (define, construct, pattern match, update, pipelines, protocols, nesting, anti-patterns), embedded schemas, and binary patterns (matching + construction).

## Data Structures

### Data Structure Selection Guide

| Need | Use | Why |
|---|---|---|
| Key-value, known keys | Struct (`%Mod{}`) | Compile-time checks, dot access, O(1) field access |
| Key-value, dynamic keys | Map (`%{}`) | O(log n) lookup, any key type |
| Ordered collection | List (`[]`) | Linked list, O(1) prepend, pattern match head |
| Fixed-size grouping | Tuple (`{}`) | O(1) element access, commonly 2-4 elements |
| Function options | Keyword list (`[k: v]`) | Ordered, duplicate keys allowed, last-arg sugar |
| Unique values | MapSet | Set operations (union, intersection, difference) |
| Integer/step sequence | Range (`1..10//2`) | Lazy, O(1) membership check with `in` |
| FIFO queue | `:queue` | O(1) amortized enqueue/dequeue |
| Graph/dependencies | `:digraph` | Mutable directed graph with path algorithms |
| Sorted unique set | `:ordsets` | Sorted list, good for small ordered sets |
| Fast concurrent reads | ETS | In-memory table, cross-process access |

**When NOT to use:**
- **MapSet** when you need ordered uniqueness → use `:ordsets` or `Enum.uniq/1`
- **`:queue`** for small collections (<100 items) → a list is simpler and fast enough
- **`:digraph`** for immutable graph data → it's mutable (ETS-backed), unusual for Elixir; consider a map of adjacency lists instead
- **Keyword list** for performance-sensitive lookups → it's a list, O(n) access; use a map
- **Tuple** as a variable-length collection → no Enum support, no head/tail matching; use a list

### Performance Characteristics

| Operation | List | Map | Struct | Tuple | MapSet | :queue | Keyword |
|---|---|---|---|---|---|---|---|
| Access by key/index | O(n) | O(log n) | O(1)¹ | O(1) | — | — | O(n) |
| Membership test | O(n) | O(log n) | — | O(n) | O(log n) | O(n) | O(n) |
| Prepend/add | O(1) | O(log n) | — | O(n)² | O(log n) | O(1)³ | O(1) |
| Append | O(n) | — | — | O(n)² | — | O(1)³ | O(n) |
| Delete | O(n) | O(log n) | — | O(n)² | O(log n) | — | O(n) |
| Size/length | O(n) | O(1) | O(1) | O(1) | O(1) | O(n) | O(n) |
| Enumerable | yes | yes | no | no | yes | no⁴ | yes |

¹ `struct.field` is O(1) map lookup on atom key. ² Tuples copy all elements on update. ³ `:queue` amortized. ⁴ Convert with `:queue.to_list/1`.

**Key performance rules:**
- Lists: always prepend, never append in loops (O(n²))
- Maps with ≤32 keys use flat structure; >32 use HAMT (both O(log n) but different constants)
- `length/1` on lists is O(n) — track length separately if called frequently
- Keyword lists are lists — same O(n) access. Use maps for performance-sensitive lookups

### Lists — Singly Linked Lists

Lists are singly-linked — O(1) prepend, O(n) append/access by index. This shapes all idiomatic patterns:

```elixir
# Construction
[]                            # Empty
[1, 2, 3]                    # Literal
[head | tail]                 # Cons cell: head is element, tail is rest of list
[1 | [2 | [3 | []]]]        # Same as [1, 2, 3] — this IS the internal structure

# Pattern matching — the core list idiom
[first | rest] = [1, 2, 3]          # first=1, rest=[2,3]
[first, second | rest] = [1, 2, 3]  # first=1, second=2, rest=[3]
[only] = [42]                        # Matches single-element list
[] = []                              # Matches empty list
```

**Head/tail patterns in function heads** — the idiomatic way to dispatch on list shape:

```elixir
# Empty vs non-empty dispatch — [_ | _] matches any non-empty list
def process([]), do: :empty
def process([_ | _] = list), do: Enum.map(list, &transform/1)

# Extract head element(s)
def first_two([a, b | _rest]), do: {a, b}
def first_two(_), do: :not_enough

# Recursive processing — base case + cons cell destructuring
def sum([], acc), do: acc
def sum([head | tail], acc), do: sum(tail, acc + head)

# Match on specific head values
def handle_commands(["quit" | _]), do: :exit
def handle_commands([cmd | rest]), do: {execute(cmd), rest}

# Guard on non-empty — prefer [_ | _] over length checks
# BAD: length/1 is O(n) — traverses entire list just to check non-empty
def process(list) when length(list) > 0, do: ...
# GOOD: pattern match is O(1)
def process([_ | _] = list), do: ...
# ALSO GOOD: guard with is_list + separate empty clause
def process([]), do: :empty
def process(list) when is_list(list), do: ...
```

**Building lists — always prepend:**

```elixir
# Prepend is O(1) — ALWAYS build lists by prepending
list = [new_item | existing_list]

# BAD: O(n) on every iteration = O(n^2) total
Enum.reduce(items, [], fn item, acc -> acc ++ [item] end)

# GOOD: prepend then reverse = O(n) total
items
|> Enum.reduce([], fn item, acc -> [item | acc] end)
|> Enum.reverse()

# BEST: just use Enum.map if transforming
Enum.map(items, &transform/1)

# Collecting filtered results — prepend + reverse
def collect_valid(items) do
  items
  |> Enum.reduce([], fn item, acc ->
    case validate(item) do
      {:ok, valid} -> [valid | acc]
      {:error, _} -> acc
    end
  end)
  |> Enum.reverse()
end
# But prefer: Enum.flat_map(items, fn item -> case validate(item) do {:ok, v} -> [v]; _ -> [] end end)
```

**List operations:**

```elixir
length(list)                  # O(n) — must traverse entire list
Enum.at(list, 0)             # O(n) — no index access
List.first(list)              # O(1) — just head
List.last(list)               # O(n) — must traverse
hd(list)                      # O(1) — head, raises on empty
tl(list)                      # O(1) — tail, raises on empty

# List-specific functions (not in Enum)
List.flatten([[1, [2]], 3])  # => [1, 2, 3]
List.zip([[1, 2], [:a, :b]])  # => [{1, :a}, {2, :b}]
List.foldl([1, 2, 3], 0, &+/2)  # left fold (same as Enum.reduce)
List.foldr([1, 2, 3], 0, &+/2)  # right fold (processes right-to-left)
List.insert_at(list, 2, :x)  # O(n) insert
List.delete(list, :item)     # Delete first occurrence
List.update_at(list, 0, &(&1 + 1))  # Update at index (O(n))
[1, 2, 3] -- [2]            # Difference: [1, 3]
[1, 2] ++ [3, 4]            # Concatenation: [1, 2, 3, 4] — O(length of left list)

# Charlists vs Strings
~c"hello"                     # Charlist: list of codepoints [104, 101, ...]
"hello"                       # Binary string (UTF-8)
# IEx displays [104, 101, ...] as ~c"hello" — it's still a list!
# Use charlists only for Erlang interop that requires them
:io.format(~c"~p~n", [value])  # Erlang :io expects charlists
```

> **Recursion patterns** (tail-call optimization, accumulators, build-and-reverse, tree traversal): see [SKILL.md — Recursion Patterns](SKILL.md#recursion-patterns).

**IO Lists** — the fastest way to build output:

```elixir
# IO lists are nested lists of binaries/integers — no copying until final output
iodata = ["Hello", ?\s, ["world", ?!]]
IO.iodata_to_binary(iodata)  # => "Hello world!" — single allocation

# BAD: string concatenation in loops (copies on every <>)
Enum.reduce(rows, "", fn row, acc -> acc <> format_row(row) <> "\n" end)

# GOOD: IO list — zero-copy accumulation, single flatten at the end
rows
|> Enum.map(fn row -> [format_row(row), ?\n] end)
|> IO.iodata_to_binary()

# IO functions accept IO lists directly — no need to flatten
File.write!("out.txt", Enum.map(rows, &[&1, ?\n]))
Plug.Conn.send_resp(conn, 200, ["<h1>", title, "</h1>", body])
```

### Maps — Hash Maps

```elixir
# Creation
%{}                                    # Empty
%{key: "value"}                        # Atom keys
%{"key" => "value"}                    # String keys (external data)
Map.new([{:a, 1}, {:b, 2}])          # From key-value pairs
Map.new(users, &{&1.id, &1})          # From enumerable with transform

# Access patterns — choose based on intent
map.key                                # Atom key: raises KeyError if missing (assertive)
map[:key]                              # Atom key: returns nil if missing (lenient)
map["key"]                             # String key: returns nil if missing
Map.get(map, key, default)             # With explicit default
Map.fetch(map, key)                    # {:ok, val} or :error (pattern matchable)
Map.fetch!(map, key)                   # Value or raise

# Update (returns new map — never mutates)
Map.put(map, key, value)               # Set (create or overwrite)
Map.put_new(map, key, value)           # Set only if key missing
Map.put_new_lazy(map, key, fun)        # Lazy default (avoid expensive computation)
%{map | key: new_value}                # Update EXISTING key only (raises if missing!)
Map.update(map, key, default, fun)     # Update with function or insert default
Map.update!(map, key, fun)             # Update with function (raises if missing)
Map.merge(map1, map2)                  # Merge (map2 wins on conflict)
Map.merge(map1, map2, fn _k, v1, v2 -> v1 + v2 end)  # Merge with resolver

# Delete & filter
Map.delete(map, key)                   # Remove key (no error if missing)
Map.drop(map, [:a, :b])               # Remove multiple keys
Map.take(map, [:a, :b])               # Keep only these keys
Map.pop(map, key)                      # {value, rest_map}
Map.reject(map, fn {_k, v} -> is_nil(v) end)  # Filter out entries
Map.filter(map, fn {_k, v} -> v > 0 end)      # Keep matching entries
Map.has_key?(map, key)                 # Boolean check
Map.keys(map)                          # List of keys
Map.values(map)                        # List of values

# Nested access — works on maps, keyword lists, structs
get_in(data, [:users, 0, :name])                    # Nested get
put_in(data, [:settings, :theme], "dark")            # Nested put
update_in(data, [:stats, :count], & &1 + 1)          # Nested update
pop_in(data, [:temp, :cache])                        # Nested pop
get_in(data, [:users, Access.all(), :name])           # All user names
get_in(data, [:items, Access.filter(&(&1.active))])   # Filtered access

# Transform — build new map
for {k, v} <- map, into: %{}, do: {k, transform(v)}
Map.new(map, fn {k, v} -> {k, transform(v)} end)   # Same, functional style
```

**Map patterns in functions:**

```elixir
# Match on specific keys (partial match — extra keys are OK)
def greet(%{name: name}), do: "Hello #{name}"

# Match on key presence + guard
def process(%{status: status} = record) when status in [:pending, :active] do
  %{record | processed_at: DateTime.utc_now()}
end

# Atom keys vs string keys — be consistent per context
# Internal data: atom keys (fast comparison, dot access)
%{user_id: 1, role: :admin}
# External/JSON data: string keys (safe, no atom exhaustion)
%{"user_id" => 1, "role" => "admin"}

# Converting between key types
Map.new(string_map, fn {k, v} -> {String.to_existing_atom(k), v} end)
```

### Tuples — Fixed-Size Containers

Tuples are stored contiguously — O(1) element access, but updating creates a full copy. Use for small, fixed-size groupings (typically 2-4 elements).

```elixir
# Tagged tuples — Elixir's primary result/control flow mechanism
{:ok, value}                  # Success
{:error, reason}              # Failure
{:error, :not_found}          # Typed failure
{:error, %Ecto.Changeset{}}   # Rich failure with details
{:noreply, state}             # GenServer continue
{:reply, response, state}     # GenServer respond
{:halt, acc}                  # Stop reduce_while/Stream.transform
{:cont, acc}                  # Continue reduce_while

# Pattern matching — the primary way to work with tuples
case File.read("config.json") do
  {:ok, contents} -> Torque.decode!(contents)
  {:error, :enoent} -> %{}       # File not found — use defaults
  {:error, reason} -> raise "Config error: #{inspect(reason)}"
end

# In function heads
def handle_result({:ok, value}), do: value
def handle_result({:error, reason}), do: raise "Failed: #{reason}"

# Tuples as lightweight records (when a struct is overkill)
# Common in Erlang interop and internal data
point = {10, 20}                    # {x, y}
color = {255, 128, 0, 1.0}         # {r, g, b, alpha}

# ETS stores tuples — first element is typically the key
:ets.insert(table, {user_id, username, email})
:ets.lookup(table, user_id)  # => [{user_id, username, email}]

# Tuple operations
elem(tuple, 0)                # O(1) access by index
put_elem(tuple, 1, :new_val)  # Returns new tuple (copies all elements)
tuple_size(tuple)              # O(1) size
Tuple.append(tuple, :val)     # Add at end (returns new tuple)

# NEVER use tuples as variable-length collections
# BAD: tuple as list replacement
items = {:a, :b, :c, :d, :e}  # Can't pattern match head/tail, no Enum support
# GOOD: use a list
items = [:a, :b, :c, :d, :e]  # Supports Enum, pattern matching, recursion
```

**When to use tuples vs other structures:**

| Size/Use | Data structure |
|---|---|
| 2-4 elements, fixed shape | Tuple `{:ok, value}` |
| Named fields, compile-time | Struct `%User{}` |
| Variable length, ordered | List `[1, 2, 3]` |
| Key-value lookup | Map `%{key: val}` |

### Keyword Lists & Options

```elixir
# Keyword lists are lists of {atom, value} tuples
# Used primarily for function options
[name: "Jo", age: 30] == [{:name, "Jo"}, {:age, 30}]

# Allow duplicate keys (unlike maps)
[a: 1, a: 2]  # Valid! First match wins with Keyword.get

# Common Operations
Keyword.get(opts, :key, default)     # Get with default
Keyword.fetch!(opts, :key)           # Get or raise
Keyword.put(opts, :key, value)       # Set (replaces first)
Keyword.merge(opts1, opts2)          # Merge
Keyword.take(opts, [:a, :b])         # Keep subset
Keyword.validate!(opts, [:a, :b])    # Validate allowed keys (Elixir 1.13+)
Keyword.pop(opts, :key, default)     # Extract and return rest

# Options pattern — last argument keyword list drops brackets
def start(opts \\ []) do
  host = Keyword.get(opts, :host, "localhost")
  port = Keyword.get(opts, :port, 4000)
  # ...
end
# Callers:
start(host: "example.com", port: 8080)
start([{:host, "example.com"}])  # Equivalent, explicit

# Keyword vs Map for options:
# Use Keyword when: order matters, duplicate keys needed, function options
# Use Map when: fast lookup needed, no duplicates, data (not config)
```

### MapSet — Unique Value Collections

```elixir
set = MapSet.new([1, 2, 3, 2])     # => MapSet.new([1, 2, 3])
MapSet.member?(set, 2)              # => true
MapSet.put(set, 4)                  # => MapSet.new([1, 2, 3, 4])
MapSet.delete(set, 1)               # => MapSet.new([2, 3])

# Set operations
MapSet.union(set_a, set_b)          # All elements from both
MapSet.intersection(set_a, set_b)   # Elements in both
MapSet.difference(set_a, set_b)     # Elements in A but not B
MapSet.disjoint?(set_a, set_b)      # True if no overlap
MapSet.subset?(small, large)        # True if small ⊆ large
MapSet.equal?(set_a, set_b)         # True if same elements

# Common patterns
# Deduplicate while preserving type
tags = MapSet.new(user_tags)
MapSet.to_list(tags)

# Fast membership testing in guards/conditions
allowed = MapSet.new([:admin, :moderator])
if MapSet.member?(allowed, user.role), do: :granted, else: :denied

# Build set from pipeline
active_ids =
  users
  |> Enum.filter(& &1.active)
  |> Enum.map(& &1.id)
  |> MapSet.new()
```

### Ranges

```elixir
# Construction
1..10                          # Ascending range (includes both endpoints)
10..1//-1                      # Descending range (must specify step)
1..100//5                      # Stepped range: 1, 6, 11, ..., 96
0..0                           # Single-element range

# Ranges are lazy — no list is created until consumed
Enum.to_list(1..5)            # => [1, 2, 3, 4, 5]
Enum.map(1..10, & &1 * 2)     # Transform without creating intermediate list

# In guards — fast O(1) membership check
def valid_age?(age) when age in 0..150, do: true

# In for comprehensions
for i <- 1..10, do: i * i

# In pattern matching (Elixir 1.14+)
case count do
  n when n in 1..10 -> :small
  n when n in 11..100 -> :medium
  _ -> :large
end

# Range operations
Range.size(1..10)              # 10
Range.disjoint?(1..5, 6..10)  # true
Range.shift(1..5, 3)          # 4..8

# Common patterns
# Slice from enumerable
Enum.slice(list, 2..5)        # Elements at indices 2, 3, 4, 5
String.slice("hello", 1..3)   # "ell"

# Generate indices
for {item, i} <- Enum.with_index(list), i in 2..5, do: item
```

### Erlang Data Structures

#### :queue — FIFO Queue

Use `:queue` instead of lists when you need efficient enqueue/dequeue from both ends. Lists are O(n) for append; `:queue` is O(1) amortized.

```elixir
q = :queue.new()
q = :queue.in(:a, q)                  # Enqueue to back
q = :queue.in(:b, q)                  # => {:a, :b}
{{:value, item}, q} = :queue.out(q)   # Dequeue from front, item = :a
:queue.peek(q)                        # {:value, :b} (don't remove)
:queue.is_empty(q)                    # false
:queue.to_list(q)                     # [:b]
:queue.from_list([:a, :b, :c])        # Create from list
:queue.len(q)                         # O(n) — track length manually if needed

# Reverse operations
q = :queue.in_r(:front, q)            # Enqueue to front
{{:value, item}, q} = :queue.out_r(q) # Dequeue from back

# Common pattern: bounded buffer
defmodule BoundedQueue do
  defstruct queue: :queue.new(), length: 0, max: 100

  def enqueue(%__MODULE__{length: len, max: max} = bq, item) when len >= max do
    {_, q} = :queue.out(bq.queue)  # Drop oldest
    %{bq | queue: :queue.in(item, q)}
  end

  def enqueue(%__MODULE__{} = bq, item) do
    %{bq | queue: :queue.in(item, bq.queue), length: bq.length + 1}
  end
end
```

**When to use `:queue` vs List:**
| Pattern | Use |
|---|---|
| Stack (LIFO) — push/pop from head | List `[new | rest]` |
| Queue (FIFO) — add to back, take from front | `:queue` |
| Random access by index | Neither — use tuple or ETS |

#### :digraph — Directed Graphs

Mutable (ETS-backed) — unusual for Elixir. Use for graph algorithms, but always delete when done.

```elixir
g = :digraph.new()
:digraph.add_vertex(g, :a)
:digraph.add_vertex(g, :b)
:digraph.add_vertex(g, :c)
:digraph.add_edge(g, :a, :b)
:digraph.add_edge(g, :b, :c)

# Query
:digraph.out_neighbours(g, :a)        # [:b]
:digraph.in_neighbours(g, :c)         # [:b]

# Path algorithms
:digraph.get_short_path(g, :a, :c)    # [:a, :b, :c]
:digraph_utils.topsort(g)             # Topological sort (false if cyclic)
:digraph_utils.is_acyclic(g)          # true/false
:digraph_utils.reachable([:a], g)     # All vertices reachable from :a

# IMPORTANT: always delete when done — ETS tables leak otherwise
:digraph.delete(g)
```

**Use cases:** dependency resolution, task scheduling, build systems. For immutable graph needs, consider a `%{vertex => [neighbours]}` map instead.

#### :ordsets — Sorted Sets

```elixir
# Small sorted sets (backed by sorted lists — O(n) insert, O(n) lookup)
s = :ordsets.new()                    # []
s = :ordsets.add_element(:b, s)       # [:b]
s = :ordsets.add_element(:a, s)       # [:a, :b] — sorted!
:ordsets.is_element(:a, s)            # true
:ordsets.union(s1, s2)                # Merge
:ordsets.intersection(s1, s2)         # Common
:ordsets.subtract(s1, s2)             # Difference
```

**Use `:ordsets` when:** you need sorted iteration and the set is small (<100 elements). For larger sets, use MapSet (unsorted but O(log n) operations).

> **Full Erlang stdlib reference:** [quick-references.md](quick-references.md) — 21 Erlang modules including :persistent_term, :counters, :atomics, :timer, :crypto, :rand, :binary, :calendar, :math, :zlib.

### Structs

Structs are named maps with compile-time guarantees. They are central to idiomatic Elixir — used as function arguments, pipeline state, GenServer state, and domain models.

#### Defining Structs

```elixir
defmodule User do
  @enforce_keys [:email]  # Required at creation time
  defstruct [:name, :email, age: 18]  # With default value

  @type t :: %__MODULE__{
    name: String.t() | nil,
    email: String.t(),
    age: non_neg_integer()
  }
end

# Creation - email required, age defaults to 18
%User{email: "a@b.com"}  # => %User{name: nil, email: "a@b.com", age: 18}
%User{name: "Jo"}        # => ArgumentError: :email is required
```

**ALWAYS include `@type t`** for every struct. Use `@enforce_keys` sparingly — only for fields that truly must be set at creation. For complex structs, provide a constructor function instead.

**Struct vs Map:**
- Structs enforce keys at compile time (typos caught early)
- `struct.field` is O(1) — same as map lookup on atom key
- No `Access` protocol — use `user.field` not `user[:field]`
- Pattern matching verifies struct type (`%User{}` won't match a plain map)
- Include `__struct__` key for type identification

#### Constructor Functions (new/build)

Don't rely on bare `%MyStruct{}` — provide constructor functions that validate, compute derived fields, and return consistent results:

```elixir
defmodule Order do
  defstruct [:id, :items, :total, :status, created_at: nil]

  @type t :: %__MODULE__{
    id: String.t() | nil,
    items: [item()],
    total: Decimal.t() | nil,
    status: :pending | :confirmed | :shipped | nil,
    created_at: DateTime.t() | nil
  }

  # Simple constructor — computes derived fields
  def new(items) when is_list(items) do
    %__MODULE__{
      id: generate_id(),
      items: items,
      total: Enum.reduce(items, Decimal.new(0), &Decimal.add(&2, &1.price)),
      status: :pending,
      created_at: DateTime.utc_now()
    }
  end

  # Constructor from external input — returns ok/error tuple
  def build(params) when is_map(params) do
    with {:ok, items} <- validate_items(params["items"]),
         {:ok, _} <- validate_address(params["address"]) do
      {:ok, new(items)}
    end
  end
end
```

**When to use which pattern:**
| Pattern | Use when |
|---|---|
| `%Mod{field: val}` | Internal code, all fields known at compile time |
| `new/1` | Computing derived fields, setting defaults beyond `defstruct` |
| `build/1` returning `{:ok, t} \| {:error, term}` | External/user input that may be invalid |
| `struct!/2` from keywords | Parsing option lists (raises on unknown keys) |

#### Pattern Matching on Structs

```elixir
# Match struct type in function head
def process(%User{age: age}) when age >= 18, do: :adult
def process(%User{}), do: :minor

# Extract only what you need for the guard, bind rest
def drive(%User{age: age} = user) when age >= 18 do
  Logger.info("#{user.name} is driving")
  {:ok, user}
end

# Match multiple struct types
def handle(%mod{name: name}) when mod in [User, Admin] do
  "#{mod}: #{name}"
end

# Assertive matching — crash on unexpected struct type
def send_email(%User{email: email}) do
  # If called with %Admin{}, this crashes immediately — good!
  Mailer.send(email)
end
```

#### Struct Updates (Immutable Transforms)

The update syntax `%{struct | field: value}` creates a new struct — it never mutates:

```elixir
# Single field update
user = %{user | name: "New Name"}

# Multiple field update
order = %{order | status: :shipped, shipped_at: DateTime.utc_now()}

# IMPORTANT: update syntax only works for EXISTING keys
%{%User{email: "a"} | nonexistent: "v"}  # ** KeyError — good, catches typos!
```

#### Struct Transformation Pipelines

The most idiomatic Elixir pattern: thread a struct through a series of functions, each returning an updated struct.

```elixir
# Pipeline of struct transforms — each function takes and returns the struct
defmodule OrderProcessor do
  def process(%Order{} = order) do
    order
    |> validate_inventory()
    |> apply_discounts()
    |> calculate_tax()
    |> set_status(:confirmed)
  end

  defp validate_inventory(%Order{items: items} = order) do
    Enum.each(items, &check_stock!/1)
    order
  end

  defp apply_discounts(%Order{items: items, total: total} = order) do
    discount = calculate_discount(items)
    %{order | total: Decimal.sub(total, discount)}
  end

  defp calculate_tax(%Order{total: total} = order) do
    tax = Decimal.mult(total, Decimal.new("0.25"))
    %{order | total: Decimal.add(total, tax)}
  end

  defp set_status(%Order{} = order, status), do: %{order | status: status}
end
```

**Pipeline with error handling** — when steps can fail, use `with` or result tuples:

```elixir
# with-chain for fallible pipeline
def checkout(%Cart{} = cart) do
  with {:ok, order} <- Cart.to_order(cart),
       {:ok, order} <- validate(order),
       {:ok, order} <- charge_payment(order),
       {:ok, order} <- send_confirmation(order) do
    {:ok, %{order | status: :completed}}
  end
end

# Or: thread {:ok, struct} through pipeline functions
def process(order) do
  {:ok, order}
  |> then_ok(&validate/1)
  |> then_ok(&charge/1)
  |> then_ok(&confirm/1)
end

defp then_ok({:ok, val}, fun), do: fun.(val)
defp then_ok({:error, _} = err, _fun), do: err
```

> **Struct as accumulator pattern** (Credo `Execution`, Phoenix `Conn`): see [architecture-reference.md](architecture-reference.md) — pipeline architecture section covers the assigns/private/halted pattern used by Plug, Credo, and Broadway.

#### Structs with Protocols

> See also: **Protocols** section in [language-patterns.md](language-patterns.md) for full protocol definition, implementation, @derive, and dispatch details.

```elixir
# @derive for common protocols — declare before defstruct
defmodule User do
  @derive {Phoenix.Param, key: :username}               # URL param generation
  @derive {Inspect, only: [:id, :name]}                 # hide sensitive fields in logs
  defstruct [:id, :name, :email, :password_hash, :username]
end

# Custom Inspect for sensitive structs (more control than @derive)
defimpl Inspect, for: Credentials do
  def inspect(%Credentials{username: username}, _opts) do
    Inspect.Algebra.concat(["#Credentials<", username, ", password: [REDACTED]>"])
  end
end

# Custom String.Chars for struct-to-string conversion
defimpl String.Chars, for: User do
  def to_string(%User{name: name, email: email}), do: "#{name} <#{email}>"
end
```

#### Nested Structs and Deep Updates

```elixir
defmodule Address do
  defstruct [:street, :city, :zip]
  @type t :: %__MODULE__{street: String.t() | nil, city: String.t() | nil, zip: String.t() | nil}
end

defmodule Company do
  defstruct [:name, :address, employees: []]
  @type t :: %__MODULE__{name: String.t() | nil, address: Address.t() | nil, employees: [User.t()]}
end

# Direct struct update (clearest for shallow nesting):
%{company | address: %{company.address | city: "Bergen"}}

# put_in with Access-style paths (for deeper nesting):
put_in(company, [Access.key(:address), Access.key(:city)], "Bergen")
update_in(company, [Access.key(:address), Access.key(:zip)], &String.upcase/1)

# Named helper functions (best for repeated deep updates):
defmodule Company do
  def update_address(%__MODULE__{} = company, fun) when is_function(fun, 1) do
    %{company | address: fun.(company.address)}
  end
end

company |> Company.update_address(&%{&1 | city: "Bergen"})
```

#### Common Anti-Patterns with Structs

```elixir
# BAD: Using Map functions that strip struct type
map = Map.put(%User{email: "a"}, :name, "Jo")  # Returns plain map, not %User{}!

# GOOD: Use struct update syntax to preserve type
user = %{%User{email: "a"} | name: "Jo"}

# BAD: Dynamic field access on structs
user[:name]  # UndefinedFunctionError — structs don't implement Access

# GOOD: Use dot notation
user.name

# BAD: Creating structs with string keys from external input
%User{"name" => "Jo"}  # Won't work — struct keys are atoms

# GOOD: Use a constructor that casts
User.build(%{"name" => "Jo"})  # or use Ecto changeset for casting

# BAD: Huge struct with 30+ fields in one module
defstruct [:a, :b, :c, :d, ...]  # Hard to reason about

# GOOD: Compose smaller structs or use map fields for extensibility
defstruct [:core_field, config: %Config{}, assigns: %{}, private: %{}]
```

### Embedded Schemas (Validation Without Database)

Use Ecto's `embedded_schema` to validate data without database tables — ideal for API commands, LiveView forms, and config validation. Call `apply_action/2` to get `{:ok, struct}` or `{:error, changeset}`.

```elixir
defmodule CreateUserCommand do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :email, :string
    field :name, :string
    field :age, :integer
  end

  def validate(params) do
    %__MODULE__{}
    |> cast(params, [:email, :name, :age])
    |> validate_required([:email])
    |> validate_format(:email, ~r/@/)
    |> apply_action(:validate)
  end
end
```

> **Full Ecto examples:** [ecto-examples.md](ecto-examples.md) — embedded schemas, polymorphic validation, and more.

### Binary Patterns — Matching & Construction

Parse and build binary protocols, file formats, network packets.

**Modifier reference:**

| Modifier | Meaning | Example |
|---|---|---|
| `big` / `little` / `native` | Endianness | `<<x::32-big>>` |
| `integer` / `float` / `binary` / `utf8` | Type | `<<x::float-64>>` |
| `signed` / `unsigned` | Signedness | `<<x::16-signed>>` |
| `size(n)` | Bit/byte count | `<<x::binary-size(4)>>` |
| `unit(n)` | Bit multiplier for size | `<<x::size(3)-unit(8)>>` = 3 bytes |

**Matching (destructuring):**

```elixir
# Fixed-size fields
<<version::8, type::8, length::16, payload::binary>> = packet

# Bit-level parsing
<<flag::1, reserved::3, value::4>> = <<0b1010_0111>>

# String matching — prefix only
<<"HTTP/", version::binary-size(3), rest::binary>> = "HTTP/1.1 200 OK"

# UTF-8 codepoint extraction
<<first::utf8, rest::binary>> = "héllo"  # first = 104 (h)

# Common modifiers
<<x::big-integer-size(32)>>          # 32-bit big-endian integer
<<x::little-float-size(64)>>         # 64-bit little-endian float
<<data::binary-size(10)>>            # Exactly 10 bytes
<<head::binary-size(4), _::binary>>  # First 4 bytes
```

**Construction (building binaries):**

```elixir
# Build protocol packets
<<0x01::8, payload_len::16, payload::binary>>

# Pack integers with endianness
<<port::16-big>>                     # 2-byte big-endian port number
<<value::32-little-signed>>          # 4-byte little-endian signed int

# Build from variables
header = <<version::8, flags::8, length::16>>
packet = <<header::binary, payload::binary>>

# Length-prefixed string
name_bytes = byte_size(name)
<<name_bytes::8, name::binary>>
```

**Advanced patterns:**

```elixir
# Pinned size — dynamic segment length from variable
size = byte_size(prefix)
<<prefix::binary-size(^size), rest::binary>> = data

# Multi-clause binary dispatch — UTF-8 cascade (from Elixir stdlib)
defp process(<<char, rest::binary>>) when char < 128, do: ...      # ASCII byte
defp process(<<char::utf8, rest::binary>>), do: ...                 # Multi-byte UTF-8
defp process(<<a::4, b::4, rest::binary>>), do: ...                 # Nibble parsing
defp process(<<>>), do: ...                                          # Empty binary

# Reinterpret bytes as nibbles (for hex encoding)
<<hi::4, lo::4>> = <<byte>>

# Binary comprehension — iterate and transform bytes
for <<byte <- binary>>, into: <<>>, do: <<byte + 1>>

# Binary comprehension — extract all 16-bit integers
for <<value::16 <- binary>>, do: value
```

### Binary Protocol Patterns

Patterns for implementing binary wire protocols — parsing, encoding, framing, and buffer management.
Pattern sources: Mint (HTTP/2 frame decoder), Tortoise (MQTT), ExRTP (RTP packets).

**Variable-length field parsing** — bind a size value and use it later in the same pattern:

```elixir
# Length-prefixed field — len bound first, used in binary-size(len)
# This is a documented Erlang feature: size can reference earlier bindings
def decode(<<len::16, payload::binary-size(len), rest::binary>>) do
  {:ok, payload, rest}
end
def decode(_incomplete), do: :more

# Multiple variable-length fields (from ExRTP extension parsing)
defp decode_field(<<id::8, len::8, data::binary-size(len), rest::binary>>, acc) do
  decode_field(rest, [{id, data} | acc])
end
defp decode_field(<<>>, acc), do: {:ok, Enum.reverse(acc)}
defp decode_field(_incomplete, _acc), do: :more

# Arithmetic in size expression (OTP 23+ — size can be a guard expression)
# From ExRTP: CSRC count * 4 bytes per CSRC
def decode_rtp(<<
  _version::2, _padding::1, _extension::1, csrc_count::4,
  _marker::1, payload_type::7, seq::16, timestamp::32, ssrc::32,
  csrc::binary-size(csrc_count * 4),
  payload::binary
>>) do
  {:ok, %{payload_type: payload_type, seq: seq, timestamp: timestamp, payload: payload}}
end
```

**Recursive binary decode with accumulator** — parse multiple records from a buffer:

```elixir
# TLV (Type-Length-Value) parser — universal pattern for tagged binary formats
defmodule TLV do
  def parse(binary, acc \\ [])

  def parse(<<type::8, length::16, value::binary-size(length), rest::binary>>, acc) do
    parse(rest, [{type, value} | acc])
  end

  def parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  def parse(remaining, acc) when byte_size(remaining) > 0, do: {:partial, Enum.reverse(acc), remaining}
end

# Multi-clause type dispatch (from Tortoise MQTT packet decoder)
# Top bits of first byte identify the packet type
def decode(<<1::4, _::4, rest::binary>>), do: decode_connect(rest)
def decode(<<2::4, _::4, rest::binary>>), do: decode_connack(rest)
def decode(<<3::4, _::4, rest::binary>>), do: decode_publish(rest)
```

**Encode/decode round-trip pattern** — the standard interface for protocol modules:

```elixir
defmodule MyProtocol.Frame do
  defstruct [:type, :flags, :payload]

  @type t :: %__MODULE__{type: 0..255, flags: 0..255, payload: binary()}

  @doc "Encode a frame struct to wire format (length-prefixed)."
  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{} = frame) do
    payload_size = byte_size(frame.payload)
    # Return IO list — no copy, can pass directly to :gen_tcp.send
    [<<frame.type::8, frame.flags::8, payload_size::16>>, frame.payload]
  end

  @doc "Decode a frame from binary. Returns {:ok, frame, rest} or :more."
  @spec decode(binary()) :: {:ok, t(), binary()} | :more | {:error, term()}
  def decode(<<type::8, flags::8, length::16, payload::binary-size(length), rest::binary>>) do
    {:ok, %__MODULE__{type: type, flags: flags, payload: payload}, rest}
  end
  def decode(data) when byte_size(data) < 4, do: :more
  def decode(<<_type::8, _flags::8, length::16, rest::binary>>)
      when byte_size(rest) < length, do: :more

  @doc "Parse all complete frames from a buffer."
  @spec parse_all(binary()) :: {[t()], binary()}
  def parse_all(buffer, acc \\ []) do
    case decode(buffer) do
      {:ok, frame, rest} -> parse_all(rest, [frame | acc])
      :more -> {Enum.reverse(acc), buffer}
    end
  end
end
```

**Return convention for streaming parsers** (verified across Mint, Tortoise, Redix, ExRTP):

| Return | Meaning | Used by |
|--------|---------|---------|
| `{:ok, parsed, rest}` | Complete parse, more data in buffer | Mint HTTP/2 frame decoder |
| `:more` | Incomplete data, need more bytes | Mint HTTP/1 and HTTP/2 |
| `{:error, reason}` | Parse error, protocol violation | Mint, ExRTP |
| `{:continuation, fun}` | Closure captures parse state | Redix (alternative to buffer) |

**Buffer management in GenServer state** — accumulate partial TCP reads:

```elixir
# Standard pattern from Mint: buffer in struct, concat + parse + store remainder
defstruct [:socket, buffer: <<>>]

def handle_info({:tcp, socket, new_data}, %{socket: socket} = state) do
  buffer = state.buffer <> new_data
  {frames, remaining} = MyProtocol.Frame.parse_all(buffer)
  state = Enum.reduce(frames, %{state | buffer: remaining}, &process_frame/2)
  :inet.setopts(socket, active: :once)
  {:noreply, state}
end

# For high-throughput: IO list accumulation avoids binary copying
# Only flatten when parsing
defstruct [:socket, buffer_parts: []]

def handle_info({:tcp, socket, new_data}, state) do
  buffer = [state.buffer_parts, new_data] |> IO.iodata_to_binary()
  {frames, remaining} = MyProtocol.Frame.parse_all(buffer)
  state = %{state | buffer_parts: [remaining]}
  # ...
end
```

**IO lists vs binary for protocol construction:**

```elixir
# Use IO lists when building incrementally or sending to socket
# :gen_tcp.send/2 accepts IO lists directly — no need to flatten
frame = [<<type::8, byte_size(payload)::16>>, payload]
:gen_tcp.send(socket, frame)    # Zero-copy send

# Use binary concatenation for small, fixed-size headers
header = <<magic::32, version::8, flags::8>>
packet = <<header::binary, body::binary>>
```

> **Deep dive:** [networking.md](networking.md) — TCP/UDP socket programming, active vs passive modes,
> listener/acceptor patterns, protocol framing, buffer management in GenServer state, Thousand Island/Ranch.

## Erlang `:queue` — O(1) Double-Ended Queue

Lists are O(1) prepend but O(n) append. When you need efficient both-end operations (request queues, resource pools, message buffers), use Erlang's `:queue` module. NimblePool uses `:queue` for both its resource pool and client request queue.

### Core Operations

```elixir
# Create
q = :queue.new()

# Add to back (enqueue) — O(1) amortized
q = :queue.in(:item1, q)
q = :queue.in(:item2, q)
q = :queue.in(:item3, q)

# Remove from front (dequeue) — O(1) amortized
{{:value, :item1}, q} = :queue.out(q)
# Returns :empty when queue is empty
:empty = :queue.out(:queue.new())

# Add to front (priority insert)
q = :queue.in_r(:urgent, q)

# Remove from back
{{:value, last}, q} = :queue.out_r(q)

# Peek without removing
{:value, front} = :queue.peek(q)
{:value, back} = :queue.peek_r(q)

# Check state
:queue.is_empty(q)      # true/false
:queue.len(q)           # length (O(n) — cache if needed)

# Convert
:queue.to_list(q)       # [front, ..., back]
:queue.from_list([1, 2, 3])

# Join two queues — O(n) in length of second queue
combined = :queue.join(q1, q2)
```

### When to Use `:queue` vs List

| Operation | List | `:queue` |
|---|---|---|
| Prepend (stack push) | O(1) | O(1) |
| Append (enqueue) | O(n) | **O(1) amortized** |
| Pop front (dequeue) | O(1) | **O(1) amortized** |
| Pop back | O(n) | **O(1) amortized** |
| Random access | O(n) | O(n) |
| Pattern match head | `[h \| t]` | Not supported |
| Enum/Stream compat | Native | `:queue.to_list/1` first |

**Use `:queue` when:** FIFO ordering matters AND both enqueue and dequeue are frequent (request queues, worker pools, message buffers, breadth-first traversal).

**Use lists when:** You only prepend/pop from one end (stacks), need pattern matching (`[h | t]`), or work with Enum/Stream functions.

### GenServer Pattern with `:queue`

```elixir
defmodule RequestQueue do
  use GenServer

  def init(_) do
    {:ok, %{queue: :queue.new(), pending: 0}}
  end

  def handle_call(:enqueue, from, %{queue: q} = state) do
    {:noreply, %{state | queue: :queue.in(from, q)}}
  end

  def handle_info(:process_next, %{queue: q} = state) do
    case :queue.out(q) do
      {{:value, from}, q} ->
        GenServer.reply(from, :ok)
        {:noreply, %{state | queue: q}}
      {:empty, _q} ->
        {:noreply, state}
    end
  end
end
```
