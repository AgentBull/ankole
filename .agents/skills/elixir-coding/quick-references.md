# Elixir Quick References & Erlang Standard Library

> Supporting reference for the [Elixir skill](SKILL.md). Contains Enum, Map, Keyword, List, String, Regex, File/Path/System, URI/Encoding, Date/Time, IO/Inspect, Access/Nested Data, Process/Concurrency, Application/Code, Macro/Module, Range, Agent quick references, Erlang standard library (21 modules), and JSON encoding.

## Rules for Using Elixir Standard Library (LLM)

1. **ALWAYS use `String.graphemes/1`** to iterate over user-visible characters — never `String.split("", trim: true)` or `String.codepoints/1` (which splits multi-byte grapheme clusters)
2. **NEVER use `String.to_atom/1`** with external input — atoms are not garbage collected. Use `String.to_existing_atom/1` or keep data as strings
3. **NEVER use `Enum.at/2`** in loops on lists — it's O(n) per call. Pattern match head/tail or convert to a map/tuple for indexed access
4. **PREFER `Calendar.strftime/2`** for date/time formatting over manual string interpolation — it handles padding, locale-aware formatting, and edge cases

## Common Mistakes (BAD/GOOD)

**Atom exhaustion from user input:**
```elixir
# BAD: creates atoms from external data — atom table is limited and never GC'd
params |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

# GOOD: convert to existing atoms only, or keep as strings
params |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
# BEST: keep external keys as strings
params  # %{"name" => "Jo"} — already safe
```

**O(n²) list indexing:**
```elixir
# BAD: Enum.at is O(n) per call — this is O(n²)
for i <- 0..(length(list) - 1), do: Enum.at(list, i)

# GOOD: use Enum.with_index or pattern matching
Enum.with_index(list, fn elem, i -> {i, elem} end)
```

## Quick References

### Enum Quick Reference

#### Transform

```elixir
Enum.map(enum, fun)              # [f(a), f(b), f(c)]
Enum.flat_map(enum, fun)         # Map then flatten one level
Enum.map_reduce(enum, acc, fun)  # {mapped_list, final_acc}
Enum.with_index(enum)            # [{a, 0}, {b, 1}, {c, 2}]
Enum.with_index(enum, 1)         # [{a, 1}, {b, 2}, {c, 3}]
Enum.zip(enum1, enum2)           # [{a1, a2}, {b1, b2}]
Enum.zip_with(enum1, enum2, fun) # [f(a1, a2), f(b1, b2)]
Enum.scan(enum, fun)             # Running reduction
```

#### Filter

```elixir
Enum.filter(enum, fun)           # Keep where fun returns truthy
Enum.reject(enum, fun)           # Remove where fun returns truthy
Enum.take(enum, n)               # First n elements
Enum.drop(enum, n)               # Skip first n
Enum.take_while(enum, fun)       # Take while predicate holds
Enum.drop_while(enum, fun)       # Drop while predicate holds
Enum.uniq(enum)                  # Remove duplicates
Enum.uniq_by(enum, fun)          # Remove duplicates by key function
Enum.dedup(enum)                 # Remove consecutive duplicates
```

#### Reduce

```elixir
Enum.reduce(enum, acc, fun)         # Fold into single value
Enum.reduce(enum, fun)              # No initial acc (first element)
Enum.reduce_while(enum, acc, fun)   # {:cont, acc} or {:halt, acc}
Enum.map_reduce(enum, acc, fun)     # Map and reduce in one pass
Enum.sum(enum)                      # Sum numbers
Enum.product(enum)                  # Product of numbers
Enum.count(enum)                    # Count all
Enum.count(enum, fun)               # Count matching
Enum.frequencies(enum)              # %{value => count}
Enum.frequencies_by(enum, fun)      # %{key => count}
```

#### Search

```elixir
Enum.find(enum, fun)             # First match or nil
Enum.find(enum, default, fun)    # First match or default
Enum.find_value(enum, fun)       # First truthy return value
Enum.find_index(enum, fun)       # Index of first match
Enum.any?(enum, fun)             # At least one truthy?
Enum.all?(enum, fun)             # All truthy?
Enum.member?(enum, val)          # Contains exact value?
Enum.empty?(enum)                # No elements?
Enum.min(enum)                   # Minimum
Enum.max(enum)                   # Maximum
Enum.min_by(enum, fun)           # Element with minimum key
Enum.max_by(enum, fun)           # Element with maximum key
Enum.min_max(enum)               # {min, max}
Enum.min_max_by(enum, fun)       # {min_element, max_element}
Enum.slide(enum, index, to)      # Move element to new position (1.13+)
```

#### Group & Split

```elixir
Enum.group_by(enum, key_fun)             # %{key => [elements]}
Enum.group_by(enum, key_fun, value_fun)  # %{key => [mapped_values]}
Enum.chunk_every(enum, n)                # [[a,b], [c,d], [e]]
Enum.chunk_every(enum, n, step)          # Sliding window
Enum.chunk_by(enum, fun)                 # Split when fun return changes
Enum.split_with(enum, fun)              # {matching, non_matching}
Enum.split(enum, n)                      # {first_n, rest}
```

#### Collect & Convert

```elixir
Enum.into(enum, collectable)     # Into map, MapSet, IO device, etc.
Enum.into(enum, collectable, fun) # Transform then collect
Enum.join(enum, joiner \\ "")    # Join into string
Enum.map_join(enum, joiner, fun) # Map then join
Enum.sort(enum)                  # Sort (term ordering)
Enum.sort_by(enum, fun)          # Sort by derived key
Enum.sort_by(enum, fun, :desc)   # Sort descending
Enum.reverse(enum)               # Reverse
Enum.shuffle(enum)               # Random order
Enum.to_list(enum)               # Force into list
Map.new(enum)                    # [{k,v}] -> %{k => v}
Map.new(enum, fun)               # enum -> %{key(x) => val(x)}
MapSet.new(enum)                 # Into set
```

#### Combine

```elixir
Enum.concat(enum1, enum2)       # Concatenate enumerables
Enum.intersperse(enum, sep)      # Insert separator between elements
Enum.map_intersperse(enum, sep, fun) # Map then intersperse in one pass (1.18+)
# Useful in HEEx: Enum.map_intersperse(items, ", ", &to_string/1)
```

#### Access

```elixir
Enum.at(enum, index)             # Element at index (O(n) for lists!)
Enum.fetch(enum, index)          # {:ok, element} or :error
Enum.fetch!(enum, index)         # Element or raise
List.first(list)                 # First element or nil
List.last(list)                  # Last element or nil (O(n))
```

### Map Quick Reference

#### Read

```elixir
Map.get(map, key)                # Value or nil
Map.get(map, key, default)       # Value or default
Map.fetch(map, key)              # {:ok, value} or :error
Map.fetch!(map, key)             # Value or raise KeyError
Map.has_key?(map, key)           # Boolean
Map.keys(map)                    # List of keys
Map.values(map)                  # List of values
map.field                        # Atom key access (raises on missing)
map[:key]                        # Atom/string key access (nil on missing)
```

#### Write

```elixir
Map.put(map, key, value)         # Add or replace
Map.put_new(map, key, value)     # Add only if absent
Map.put_new_lazy(map, k, fn)    # Compute only if absent
Map.delete(map, key)             # Remove key
Map.drop(map, [:a, :b])         # Remove multiple keys
Map.update(map, key, default, fun)  # Update or set default
Map.update!(map, key, fun)       # Update existing or raise
Map.replace!(map, key, value)    # Replace existing or raise
Map.merge(map1, map2)            # Combine (map2 wins conflicts)
Map.merge(m1, m2, fn _k, v1, v2 -> v1 + v2 end)  # Custom conflict resolution
Map.intersect(map1, map2)        # Keep only shared keys (map2 values win) (1.15+)
Map.intersect(m1, m2, fn _k, v1, v2 -> v1 + v2 end)  # Custom conflict resolution
```

#### Transform

```elixir
Map.new(enum)                    # [{k,v}] -> %{k => v}
Map.new(enum, fn x -> {k, v} end)  # Transform then build
Map.take(map, [:a, :b])         # Keep only listed keys
Map.split(map, [:a, :b])        # {taken_map, rest_map}
Map.from_struct(struct)          # Struct -> plain map (keeps :__struct__)
Map.filter(map, fn {k, v} -> bool end)   # Keep matching pairs
Map.reject(map, fn {k, v} -> bool end)   # Remove matching pairs
Map.map(map, fn {k, v} -> new_v end)     # Transform values
Map.to_list(map)                 # [{k, v}, ...]
```

#### Pop

```elixir
Map.pop(map, key)                # {value_or_nil, rest_map}
Map.pop(map, key, default)       # {value_or_default, rest_map}
Map.pop!(map, key)               # {value, rest_map} or raise
Map.pop_lazy(map, key, fn)      # Compute default lazily
Map.get_and_update(map, key, fn val -> {get, update} end)
```

#### Idiomatic Map Patterns

```elixir
# Update syntax (ONLY for existing keys — raises on missing)
%{map | name: "new", age: 30}

# Pattern match to extract
%{name: name, age: age} = user

# Conditional presence
if Map.has_key?(config, :timeout), do: config.timeout, else: 5000

# Merge with defaults (idiomatic options pattern)
defaults = %{timeout: 5000, retries: 3}
opts = Map.merge(defaults, user_opts)

# Nested update with Access
put_in(map, [:user, :address, :city], "Oslo")
update_in(map, [:counters, :visits], &(&1 + 1))
get_in(map, [:user, :address, :city])
```

### Keyword Quick Reference

Keyword lists are ordered, allow duplicates, and have atom keys. Used for function options.

#### Read

```elixir
Keyword.get(kw, :key)            # Value or nil (first occurrence)
Keyword.get(kw, :key, default)   # Value or default
Keyword.fetch(kw, :key)          # {:ok, value} or :error
Keyword.fetch!(kw, :key)         # Value or raise
Keyword.has_key?(kw, :key)       # Boolean
Keyword.keys(kw)                 # All keys (may have duplicates)
Keyword.values(kw)               # All values
Keyword.keyword?(term)           # Is valid keyword list?
Keyword.get_values(kw, :key)     # ALL values for key (duplicates)
```

#### Write

```elixir
Keyword.put(kw, :key, value)     # Add/replace (first occurrence)
Keyword.put_new(kw, :key, value) # Add only if absent
Keyword.put_new_lazy(kw, :k, fn) # Compute only if absent
Keyword.delete(kw, :key)         # Remove ALL occurrences of key
Keyword.pop(kw, :key)            # {value, rest} (removes first)
Keyword.pop(kw, :key, default)   # {value_or_default, rest}
Keyword.pop!(kw, :key)           # {value, rest} or raise
Keyword.merge(kw1, kw2)          # Combine (kw2 wins, preserves order)
Keyword.merge(kw1, kw2, fn _k, v1, v2 -> v1 end)  # Custom resolver
Keyword.update(kw, :key, default, fun)  # Update or set default
Keyword.update!(kw, :key, fun)   # Update existing or raise
```

#### Split & Validate

```elixir
Keyword.take(kw, [:a, :b])      # Keep only listed keys
Keyword.drop(kw, [:a, :b])      # Remove listed keys
Keyword.split(kw, [:a, :b])     # {taken, rest}
Keyword.split_with(kw, fn {k,v} -> bool end)  # {matching, rest}
Keyword.validate(kw, [:name, :age, timeout: 5000])  # {:ok, kw} or {:error, keys}
Keyword.validate!(kw, [:name, :age, timeout: 5000]) # kw or raise
```

#### Idiomatic Keyword Patterns

```elixir
# Options with defaults (most common pattern)
def start_link(opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 5000)
  name = Keyword.get(opts, :name, __MODULE__)
  # ...
end

# Destructuring options
{db_opts, server_opts} = Keyword.split(opts, [:pool_size, :hostname, :database])

# Validate unknown keys early
Keyword.validate!(opts, [:name, :timeout, pool_size: 10])

# Pop-and-pass pattern (extract your options, forward the rest)
{my_opt, rest_opts} = Keyword.pop(opts, :my_option, :default)
GenServer.start_link(__MODULE__, args, rest_opts)
```

### List Quick Reference

#### Common Operations

```elixir
List.first(list)                 # First or nil
List.first(list, default)        # First or default
List.last(list)                  # Last or nil (O(n))
List.wrap(nil)                   # => []
List.wrap([1, 2])                # => [1, 2] (already a list)
List.wrap(:atom)                 # => [:atom]
List.flatten([[1, [2]], 3])      # => [1, 2, 3]
List.delete(list, element)       # Remove first occurrence
List.insert_at(list, index, val) # Insert at position (-1 = end)
List.update_at(list, index, fun) # Apply fun at position
List.delete_at(list, index)      # Remove at position
List.pop_at(list, index)         # {removed, rest}
List.replace_at(list, i, val)    # Replace at position
List.duplicate(:ok, 5)           # [:ok, :ok, :ok, :ok, :ok]
List.starts_with?([1,2,3], [1,2]) # true
```

#### Tuple-List Operations (Erlang heritage)

```elixir
# For lists of tuples like [{:name, "Jo"}, {:age, 30}]
List.keyfind(list, "Jo", 1)      # Find tuple where elem 1 == "Jo"
List.keyfind(list, :name, 0)     # Find tuple where elem 0 == :name
List.keymember?(list, :name, 0)  # Boolean: any tuple has :name at pos 0?
List.keystore(list, :name, 0, {:name, "New"})  # Replace/insert by key
List.keydelete(list, :name, 0)   # Delete tuple by key
List.keytake(list, :name, 0)     # {found_tuple, rest} or :error
List.keysort(list, 0)            # Sort by tuple position
```

#### Idiomatic List Patterns

```elixir
# List.wrap for defensive normalization (very common)
items =
  opts
  |> Keyword.get(:items)
  |> List.wrap()

# Prepend (O(1)) then reverse — idiomatic accumulation
Enum.reduce(items, [], fn item, acc -> [transform(item) | acc] end)
|> Enum.reverse()

# Head/tail destructuring
[first | rest] = list
[first, second | rest] = list
```

### String Quick Reference

#### Split & Join

```elixir
String.split("a,b,c", ",")              # ["a", "b", "c"]
String.split("a,,b", ",", trim: true)    # ["a", "b"] (remove empty)
String.split("a:b:c", ":", parts: 2)     # ["a", "b:c"]
String.split("hello world")              # ["hello", "world"] (whitespace)
Enum.join(["a", "b"], ", ")              # "a, b"
Enum.map_join(list, ", ", &to_string/1)  # Map then join
```

#### Trim & Pad

```elixir
String.trim("  hi  ")                   # "hi"
String.trim_leading("  hi")             # "hi"
String.trim_trailing("hi  ")            # "hi"
String.trim("--hi--", "-")              # "hi"
String.pad_leading("42", 5, "0")        # "00042"
String.pad_trailing("hi", 10)           # "hi        "
```

#### Search & Test

```elixir
String.contains?("hello", "ell")         # true
String.contains?("hello", ["x", "ell"])  # true (any match)
String.starts_with?("hello", "hel")      # true
String.ends_with?("hello", "llo")        # true
String.match?("hello", ~r/ell/)          # true
String.length("hello")                   # 5 (grapheme count, not bytes!)
String.valid?("hello")                   # true (valid UTF-8?)
```

#### Transform

```elixir
String.replace("hello", "l", "r")        # "herro"
String.replace("hello", ~r/[aeiou]/, "*") # "h*ll*"
String.downcase("Hello")                 # "hello"
String.upcase("hello")                   # "HELLO"
String.capitalize("hello world")         # "Hello world"
String.reverse("hello")                  # "olleh"
String.duplicate("ab", 3)               # "ababab"
String.slice("hello", 1..3)             # "ell"
String.slice("hello", 1, 3)             # "ell"
String.replace_prefix("hello", "he", "she") # "shello"
String.replace_suffix("hello", "lo", "p")   # "help"
```

#### Characters & Bytes

```elixir
String.graphemes("héllo")               # ["h", "é", "l", "l", "o"] — user-visible characters
String.codepoints("héllo")              # ["h", "é", "l", "l", "o"] — Unicode codepoints
# graphemes vs codepoints: "é" is 1 grapheme but may be 2 codepoints (e + combining accent)
String.graphemes("e\u0301")             # ["é"] — combined into single grapheme
String.codepoints("e\u0301")            # ["e", "́"] — separate codepoints

String.length("héllo")                  # 5 (grapheme count)
String.byte_size("héllo")              # 6 (bytes — "é" is 2 bytes in UTF-8)
# IMPORTANT: use byte_size for binary protocol sizes, length for user-facing counts

String.normalize("e\u0301", :nfc)       # "é" — canonical composed form (1.18+)
String.normalize("é", :nfd)             # "e\u0301" — decomposed form
```

#### Convert

```elixir
String.to_integer("42")                  # 42
String.to_integer("FF", 16)             # 255
String.to_float("3.14")                 # 3.14
String.to_atom("hello")                 # :hello (creates atom — use sparingly!)
String.to_existing_atom("hello")         # :hello (safe — only if atom exists)
String.to_charlist("hello")             # ~c"hello"
Integer.to_string(42)                   # "42"
Float.to_string(3.14)                   # "3.14"
Atom.to_string(:hello)                  # "hello"
to_string(anything)                     # Via String.Chars protocol
inspect(anything)                       # Via Inspect protocol (debug)
```

#### Integer/Float Parsing (prefer over String.to_*)

```elixir
# Integer.parse returns {value, remainder} — handles partial input
Integer.parse("42px")                   # {42, "px"}
Integer.parse("abc")                    # :error

# Float.parse same pattern
Float.parse("3.14rest")                 # {3.14, "rest"}
Float.parse("not_a_float")             # :error

# String.to_integer raises on non-integer — only use with validated input
```

### Regex Quick Reference

```elixir
# Test match
String.match?("hello", ~r/ell/)         # true (prefer this)
Regex.match?(~r/ell/, "hello")          # true

# Extract matches
Regex.run(~r/(\d+)/, "age: 42")         # ["42", "42"]
Regex.run(~r/(\d+)/, "no match")        # nil

# All matches
Regex.scan(~r/\d+/, "1 and 2 and 3")    # [["1"], ["2"], ["3"]]

# Named captures
Regex.named_captures(~r/(?<name>\w+):(?<val>\d+)/, "age:42")
# => %{"name" => "age", "val" => "42"}

# Replace
Regex.replace(~r/\d+/, "age 42", "XX")  # "age XX"
String.replace("age 42", ~r/\d+/, "XX") # same via String

# Split
Regex.split(~r/\s*,\s*/, "a, b , c")    # ["a", "b", "c"]
String.split("a, b , c", ~r/\s*,\s*/)   # same via String

# Compile for reuse (avoids re-compilation in loops)
pattern = Regex.compile!("\\d+")
Regex.scan(pattern, input)
```

### File, Path & System Quick Reference

#### File

```elixir
File.read("path")                # {:ok, binary} or {:error, reason}
File.read!("path")               # binary or raise
File.write("path", content)      # :ok or {:error, reason}
File.write!("path", content)     # :ok or raise
File.exists?("path")             # boolean
File.dir?("path")                # boolean
File.regular?("path")            # boolean (is regular file?)
File.mkdir_p!("a/b/c")           # Create dirs recursively
File.rm_rf("dir")                # {:ok, files} — remove recursively
File.cp!("src", "dst")           # Copy file
File.cp_r!("src_dir", "dst_dir") # Copy recursively
File.rename("old", "new")        # Rename/move
File.ls("dir")                   # {:ok, [filenames]}
File.stat!("path")               # %File.Stat{size: ..., type: ...}
File.stream!("path")             # Stream lines (lazy, for large files)
File.touch!("path")              # Create or update timestamp
```

#### Path

```elixir
Path.join("a", "b")              # "a/b"
Path.join(["a", "b", "c"])       # "a/b/c"
Path.expand("../file", __DIR__)  # Absolute path
Path.basename("/a/b/c.ex")       # "c.ex"
Path.basename("/a/b/c.ex", ".ex") # "c"
Path.dirname("/a/b/c.ex")        # "/a/b"
Path.extname("file.ex")          # ".ex"
Path.rootname("file.ex")         # "file"
Path.split("/a/b/c")             # ["/", "a", "b", "c"]
Path.wildcard("lib/**/*.ex")     # Glob matching
Path.relative_to("a/b/c", "a")  # "b/c"
Path.relative_to_cwd("path")    # Relative to current dir
```

#### System

```elixir
System.get_env("HOME")           # Value or nil
System.fetch_env!("DATABASE_URL") # Value or raise
System.put_env("KEY", "value")   # Set env var
System.cmd("git", ["status"])    # {output, exit_code}
System.cmd("npm", ["install"], into: IO.stream())  # Stream output
System.monotonic_time()          # For measuring durations (monotonic)
System.system_time(:millisecond) # Wall clock time
System.os_time(:second)          # OS time
System.schedulers_online()       # Number of CPU schedulers
System.otp_release()             # "27" etc
System.version()                 # "1.18.1" etc
System.tmp_dir!()                # Temp directory path
System.user_home!()              # Home directory path
```

### URI & Encoding Quick Reference

```elixir
# Parse
uri = URI.parse("https://example.com:8080/path?q=1#frag")
uri.scheme   # "https"
uri.host     # "example.com"
uri.port     # 8080
uri.path     # "/path"
uri.query    # "q=1"
uri.fragment # "frag"

# Build / Modify
URI.to_string(%URI{scheme: "https", host: "example.com", path: "/api"})
URI.merge("https://example.com/base", "/new/path")

# Query string
URI.encode_query(%{"key" => "val ue", "foo" => "bar"})  # "foo=bar&key=val+ue"
URI.decode_query("foo=bar&key=val+ue")                   # %{"foo" => "bar", "key" => "val ue"}

# Percent encoding
URI.encode("hello world")                    # "hello%20world"
URI.encode(filename, &URI.char_unreserved?/1) # Encode for path segment
URI.decode("hello%20world")                  # "hello world"
URI.encode_www_form("hello world")           # "hello+world" (form encoding)
URI.decode_www_form("hello+world")           # "hello world"
```

#### Base Encoding

```elixir
Base.encode64(binary)                        # Standard base64
Base.decode64!(encoded)                      # Decode base64
Base.url_encode64(binary, padding: false)    # URL-safe base64 (for tokens)
Base.url_decode64!(encoded, padding: false)  # Decode URL-safe base64
Base.encode16(binary)                        # Hex encoding "48454C4C4F"
Base.encode16(binary, case: :lower)          # "48656c6c6f"
Base.decode16!("48454C4C4F")                 # Decode hex
Base.encode32(binary)                        # Base32 encoding
```

### Date & Time Quick Reference

```elixir
# Current time
DateTime.utc_now()               # ~U[2026-03-16 12:00:00Z]
NaiveDateTime.utc_now()          # ~N[2026-03-16 12:00:00]
Date.utc_today()                 # ~D[2026-03-16]
Time.utc_now()                   # ~T[12:00:00]

# Truncate precision (very common with Ecto)
DateTime.utc_now() |> DateTime.truncate(:second)

# Arithmetic — absolute units
DateTime.add(dt, 3600, :second)  # Add 1 hour
DateTime.add(dt, -1, :day)      # Subtract 1 day
Date.add(date, 7)               # Add 7 days
DateTime.diff(dt1, dt2, :second) # Seconds between

# Arithmetic — calendar-aware (1.17+)
DateTime.shift(dt, month: 1)     # Add 1 calendar month (handles 28/30/31 days)
DateTime.shift(dt, year: 1, month: -3)  # Combine calendar units
Date.shift(date, month: 6)      # Works on Date too
# IMPORTANT: shift handles calendar semantics (Jan 31 + 1 month = Feb 28)
# while add only works with absolute time units (seconds, days)

# Comparison
DateTime.compare(dt1, dt2)       # :lt | :eq | :gt
Date.compare(d1, d2)            # :lt | :eq | :gt

# Parse / Format
DateTime.from_iso8601("2026-03-16T12:00:00Z")  # {:ok, dt, offset}
Date.from_iso8601("2026-03-16")                 # {:ok, date}
DateTime.to_iso8601(dt)                         # "2026-03-16T12:00:00Z"
Calendar.strftime(dt, "%Y-%m-%d %H:%M")         # "2026-03-16 12:00"
Calendar.strftime(dt, "%B %d, %Y")              # "March 16, 2026"
Calendar.strftime(dt, "%I:%M %p")               # "12:00 PM"

# Create
Date.new!(2026, 3, 16)          # ~D[2026-03-16]
NaiveDateTime.new!(2026, 3, 16, 12, 0, 0)  # ~N[...]
```

### IO & Inspect Quick Reference

```elixir
# Output
IO.puts("message")              # Print + newline to stdout
IO.write("no newline")          # Print without newline
IO.warn("deprecation")          # Print to stderr

# Debug (returns the value — use in pipelines!)
IO.inspect(value)               # Print and return value
IO.inspect(value, label: "step1")  # With label
value
|> IO.inspect(label: "before")
|> transform()
|> IO.inspect(label: "after")

# IO data (list of strings/bytes — avoids concatenation)
iodata = ["Hello", ?\s, "World", [" ", "!"]]
IO.iodata_to_binary(iodata)     # "Hello World !"
IO.iodata_length(iodata)        # 13

# Logger (prefer over IO.puts for production)
require Logger
Logger.debug("details")         # Filtered in prod
Logger.info("startup complete") # Normal operation
Logger.warning("deprecated")    # Warnings
Logger.error("crash: #{inspect(reason)}")  # Errors
Logger.debug(fn -> "expensive: #{inspect(data)}" end)  # Lazy — only computed if level enabled
```

#### IO.inspect Options

```elixir
IO.inspect(value,
  label: "Debug",           # Prefix label
  limit: :infinity,         # Items to show (default 50)
  printable_limit: 4096,    # Chars for strings
  pretty: true,             # Pretty print
  width: 80,                # Line width
  charlists: :as_lists,     # Show charlists as lists
  structs: false,           # Show struct as map
  binaries: :as_strings,    # :as_strings | :as_binaries | :infer
  syntax_colors: [          # IEx colors
    atom: :cyan,
    string: :green,
    number: :yellow
  ]
)

# Pipeline debugging
data
|> step_one()
|> IO.inspect(label: "after step_one")
|> step_two()
|> IO.inspect(label: "after step_two", limit: 5)
|> step_three()
```

### Access & Nested Data Quick Reference

#### get_in / put_in / update_in / pop_in

```elixir
# Works with maps and keyword lists
data = %{user: %{address: %{city: "Oslo"}}}

get_in(data, [:user, :address, :city])           # "Oslo"
put_in(data, [:user, :address, :city], "Bergen")  # Updated nested map
update_in(data, [:user, :address, :city], &String.upcase/1)
pop_in(data, [:user, :address, :city])            # {"Oslo", updated_map}

# With Access functions for complex traversals
users = %{users: [%{name: "Jo", scores: [1,2]}, %{name: "Bo", scores: [3,4]}]}

get_in(users, [:users, Access.all(), :name])      # ["Jo", "Bo"]
get_in(users, [:users, Access.at(0), :name])      # "Jo"
update_in(users, [:users, Access.all(), :scores], &Enum.sum/1)
get_in(users, [:users, Access.filter(&(&1.name == "Jo")), :scores])

# Access.key with default (for missing keys)
get_in(%{}, [Access.key(:user, %{}), Access.key(:name, "anon")])  # "anon"
```

#### Kernel struct helpers

```elixir
# Build struct from map (validates keys)
struct(User, %{name: "Jo", age: 30})     # %User{name: "Jo", age: 30}
struct!(User, %{name: "Jo", age: 30})    # Same but raises on unknown keys

# Check struct type
is_struct(value)                          # Is any struct?
is_struct(value, User)                    # Is specifically %User{}?
```

### Process & Concurrency Quick Reference

```elixir
# Current process
self()                           # Current PID
Process.alive?(pid)              # Boolean

# Send messages
send(pid, :message)              # Async message (returns message)
Process.send_after(self(), :tick, 1000)  # Delayed message (ms)

# Process info (debugging)
Process.info(pid, :message_queue_len)    # Mailbox size
Process.info(pid, :memory)               # Memory usage
Process.info(pid, :current_stacktrace)   # Where is it?

# Process dictionary (per-process mutable storage — use sparingly)
Process.put(:key, value)         # Store
Process.get(:key)                # Retrieve
Process.delete(:key)             # Remove

# Monitor / Link
ref = Process.monitor(pid)       # Receive {:DOWN, ref, :process, pid, reason}
Process.demonitor(ref, [:flush]) # Stop monitoring + flush pending :DOWN

# Spawn
spawn(fn -> work() end)          # Unlinked (fire-and-forget)
spawn_link(fn -> work() end)     # Linked (crash propagates)
{pid, ref} = spawn_monitor(fn -> work() end)  # Spawn + monitor

# Named processes
Process.whereis(:name)           # PID or nil
Process.registered()             # All registered names
```

### Application & Code Quick Reference

```elixir
# Runtime config
Application.get_env(:my_app, :key)         # Value or nil
Application.get_env(:my_app, :key, default) # Value or default
Application.fetch_env!(:my_app, :key)      # Value or raise
Application.put_env(:my_app, :key, value)  # Set at runtime

# Compile-time config (baked into release — warns if changed at runtime)
Application.compile_env(:my_app, :key)
Application.compile_env!(:my_app, :key)

# Application lifecycle
Application.ensure_all_started(:phoenix)   # Start app + deps
Application.started_applications()          # List running apps
Application.spec(:my_app, :modules)        # App metadata
Application.app_dir(:my_app, "priv")       # Path to app's priv dir

# Code loading
Code.ensure_loaded?(MyModule)              # Is module available?
Code.ensure_compiled(MyModule)             # {:module, mod} or {:error, reason}
function_exported?(Module, :fun, 2)        # Does Module.fun/2 exist?
macro_exported?(Module, :mac, 1)           # Does Module.mac/1 macro exist?

# Dynamic invocation
apply(Module, :function, [arg1, arg2])     # Call function dynamically
Code.eval_string("1 + 2")                 # {3, []} — eval string as code
Code.string_to_quoted!("1 + 2")           # {:+, [...], [1, 2]} — parse to AST

# Module introspection
Module.concat(MyApp, Router)               # MyApp.Router
Module.split(MyApp.Router)                 # ["MyApp", "Router"]
```

### Macro & Module Quick Reference

#### Macro (AST manipulation)

```elixir
# AST traversal (top-down: prewalk, bottom-up: postwalk)
Macro.prewalk(ast, fn
  {:foo, meta, args} -> {:bar, meta, args}  # Transform nodes
  node -> node                               # Pass through
end)

Macro.postwalk(ast, fn node -> transform(node) end)

# With accumulator
{new_ast, acc} = Macro.prewalk(ast, [], fn
  {:def, _, _} = node, acc -> {node, [node | acc]}  # Collect defs
  node, acc -> {node, acc}
end)

# Display
Macro.to_string(ast)             # AST -> human-readable code string
Macro.escape(%{key: :value})     # Elixir term -> AST representation

# Variable creation in macros
Macro.var(:name, __MODULE__)     # Create quoted variable
Macro.generate_unique_arguments(3, __MODULE__)  # 3 unique args

# Naming
Macro.underscore("MyModule")     # "my_module"
Macro.camelize("my_module")      # "MyModule"
```

#### Module (compile-time introspection)

```elixir
# Name manipulation
Module.concat([MyApp, "Web", Router])   # MyApp.Web.Router
Module.concat(MyApp, Router)            # MyApp.Router
Module.split(MyApp.Web.Router)          # ["MyApp", "Web", "Router"]

# Attributes (during compilation — in module body or macros)
Module.get_attribute(__MODULE__, :moduledoc)
Module.put_attribute(__MODULE__, :custom, :value)
Module.register_attribute(__MODULE__, :hooks, accumulate: true)
Module.has_attribute?(__MODULE__, :custom)
Module.delete_attribute(__MODULE__, :custom)

# Function checking
Module.defines?(MyModule, {:my_fun, 2})   # Does module define my_fun/2?
Module.defines?(MyModule, {:my_fun, 2}, :def)  # Specifically public?
```

#### Kernel Pipeline Helpers

```elixir
# tap — side effect in pipeline (returns original value)
data
|> transform()
|> tap(fn x -> Logger.debug("after transform: #{inspect(x)}") end)
|> process()

# then — transform in pipeline (returns new value)
user_id
|> then(fn id -> Repo.get(User, id) end)
|> then(fn
  nil -> {:error, :not_found}
  user -> {:ok, user}
end)

# dbg — debug in pipeline (prints and returns value, includes expression)
data
|> transform()
|> dbg()          # Prints: transform() #=> result
|> process()
```

### Range Quick Reference

```elixir
# Construction
1..10                                # Ascending inclusive: 1, 2, 3, ..., 10
10..1//-1                            # Descending: 10, 9, 8, ..., 1
0..100//5                            # Step: 0, 5, 10, 15, ..., 100
?a..?z                               # Codepoint range: 97..122

# Membership
42 in 1..100                         # true — O(1), no iteration
x in 1..100//2                       # Works with steps too

# Properties
Range.size(1..10)                    # 10
Range.disjoint?(1..5, 6..10)        # true — no overlap
Range.shift(1..5, 3)                # 4..8

# As generator
for i <- 1..5, do: i * i            # [1, 4, 9, 16, 25]
Enum.map(1..5, & &1 * 2)            # [2, 4, 6, 8, 10]
Enum.to_list(1..5//2)               # [1, 3, 5]
Enum.random(1..100)                  # Random int in range

# Slicing (O(1) for ranges)
Enum.slice(list, 0..4)              # First 5 elements
Enum.at(1..100, 42)                 # 43 (0-indexed)
String.slice("hello world", 0..4)   # "hello"

# Pattern matching (since Elixir 1.14)
case value do
  x when x in 1..10 -> :low
  x when x in 11..100 -> :high
  _ -> :other
end

# Chunk with ranges (index-based)
list
|> Enum.with_index()
|> Enum.filter(fn {_, i} -> i in 0..4 end)
```

### Agent Quick Reference

```elixir
# Agent — simple state wrapper around GenServer
# Use for trivial state that doesn't need GenServer callbacks

# Start (usually under a supervisor)
{:ok, pid} = Agent.start_link(fn -> %{} end)
{:ok, pid} = Agent.start_link(fn -> %{} end, name: :my_cache)

# Read state — Agent.get/3
Agent.get(pid, fn state -> state end)                    # Get full state
Agent.get(pid, fn state -> Map.get(state, :key) end)     # Read specific key
Agent.get(pid, & &1)                                     # Shorthand: full state

# Update state — Agent.update/3
Agent.update(pid, fn state -> Map.put(state, :key, value) end)
Agent.update(pid, &Map.delete(&1, :key))

# Get and update atomically — Agent.get_and_update/3
Agent.get_and_update(pid, fn state ->
  {Map.get(state, :counter, 0), Map.update(state, :counter, 1, & &1 + 1)}
end)  # Returns old value, stores incremented

# Cast (fire-and-forget update) — Agent.cast/2
Agent.cast(pid, fn state -> Map.put(state, :updated_at, DateTime.utc_now()) end)

# Stop
Agent.stop(pid)                     # Graceful shutdown

# Child spec for supervisor
children = [
  {Agent, fn -> %{} end}            # Anonymous
  %{id: :my_cache, start: {Agent, :start_link, [fn -> %{} end, [name: :my_cache]]}}
]
```

**When to use Agent vs GenServer:**
- Agent: Simple get/set state, no message handling, no periodic work, no complex logic
- GenServer: Handle messages, periodic work (handle_info with timers), complex state transitions, need callbacks
- Rule of thumb: If you need `handle_info`, `handle_cast` with side effects, or `terminate` — use GenServer

## Erlang Standard Library

### :queue - FIFO Operations

O(1) amortized enqueue/dequeue vs O(n) for list append:

```elixir
q = :queue.new()
q = :queue.in(item, q)                # Enqueue (add to back)
q = :queue.in_r(item, q)              # Enqueue to front
{{:value, item}, q} = :queue.out(q)   # Dequeue from front
{{:value, item}, q} = :queue.out_r(q) # Dequeue from back
:queue.is_empty(q)                    # Check if empty
:queue.peek(q)                        # {:value, item} | :empty
:queue.to_list(q)                     # Convert to list
:queue.from_list(list)                # Create from list

# WARNING: O(n) operations - avoid in hot paths
:queue.len(q)                         # Count elements
:queue.member(item, q)                # Check membership
```

**Tip:** `:queue.len/1` is O(n) — track length manually if needed:

```elixir
%{queue: :queue.new(), length: 0}
```

### :persistent_term - Read-Optimized Storage

Extremely fast reads, expensive writes (copies to all processes):

```elixir
:persistent_term.put(key, value)      # Store (expensive - global GC)
:persistent_term.get(key)             # Retrieve (very fast)
:persistent_term.get(key, default)    # With default
:persistent_term.erase(key)           # Delete (expensive)
:persistent_term.info()               # Memory stats

# Best for: config, lookup tables, feature flags
# Avoid: frequent updates, large values that change often

# Pattern: Hydrate at startup, read-only during runtime
# Anti-pattern: Frequent updates (causes global GC)
```

### :atomics - Atomic Operations

Thread-safe concurrent state without GenServer bottleneck:

```elixir
ref = :atomics.new(size, opts)        # Create array of atomics
:atomics.put(ref, idx, value)         # Set value
:atomics.get(ref, idx)                # Get value
:atomics.add(ref, idx, incr)          # Add atomically
:atomics.add_get(ref, idx, incr)      # Add and return new value
:atomics.sub(ref, idx, decr)          # Subtract atomically
:atomics.sub_get(ref, idx, decr)      # Subtract and return new value
:atomics.exchange(ref, idx, value)    # Set and return old value
:atomics.compare_exchange(ref, idx, expected, desired)  # CAS

# Options: signed: true (default) | false

# Pattern: Lock-free rate limiting (from Broadway)
# GenServer owns the atomic, but reads/writes bypass it
counter = :atomics.new(1, [])
:atomics.put(counter, 1, 100)         # Set limit
:atomics.sub_get(counter, 1, 1)       # Decrement, returns remaining
```

### :counters - Concurrent Counters

```elixir
ref = :counters.new(size, opts)       # Create counter array
:counters.add(ref, idx, incr)         # Increment/decrement
:counters.sub(ref, idx, decr)         # Decrement
:counters.put(ref, idx, value)        # Set value
:counters.get(ref, idx)               # Read value
:counters.info(ref)                   # Memory/size info

# Options: [:atomics] for strict consistency, [] for write-optimized
```

Use for: metrics, rate limiting counters, high-frequency updates.

### :ets - Erlang Term Storage

```elixir
# Create table
:ets.new(name, [:set | :ordered_set | :bag | :duplicate_bag,
                :named_table, :public | :protected | :private,
                :compressed, {:read_concurrency, true},
                {:write_concurrency, true}])

# CRUD operations
:ets.insert(table, {key, value})      # Insert/update
:ets.insert(table, [{k1, v1}, ...])   # Bulk insert
:ets.lookup(table, key)               # [{key, value}] | []
:ets.lookup_element(table, key, pos)  # Get specific element
:ets.delete(table, key)               # Delete by key
:ets.delete_object(table, object)     # Delete specific tuple
:ets.delete_all_objects(table)        # Clear table

# Iteration
:ets.first(table)                     # First key | :"$end_of_table"
:ets.next(table, key)                 # Next key
:ets.tab2list(table)                  # All entries as list

# Match/select
:ets.match(table, pattern)            # Simple pattern match
:ets.match_object(table, pattern)     # Match and return full objects
:ets.match_delete(table, pattern)     # Delete matching entries
:ets.select(table, match_spec)        # Full match spec
:ets.select_delete(table, match_spec) # Delete matching

# Info
:ets.info(table)                      # Table metadata
:ets.info(table, :size)               # Entry count
:ets.info(table, :memory)             # Words of memory
```

**Table Types:**
- `:set` - One row per key (default), fast key lookup
- `:ordered_set` - Rows sorted by key (term ordering), range queries
- `:bag` - Multiple rows per key, no duplicate rows
- `:duplicate_bag` - Multiple rows per key, duplicates allowed

**Match Patterns (non-key lookups):**

```elixir
# Create bag table (multiple entries per key)
todo = :ets.new(:todo, [:bag])
:ets.insert(todo, {~D[2024-01-15], "Dentist"})
:ets.insert(todo, {~D[2024-01-15], "Shopping"})
:ets.insert(todo, {~D[2024-01-20], "Dentist"})

# Key-based lookup (fast)
:ets.lookup(todo, ~D[2024-01-15])
# => [{~D[2024-01-15], "Dentist"}, {~D[2024-01-15], "Shopping"}]

# Pattern-based lookup (scans table)
# :_ matches any value
:ets.match_object(todo, {:_, "Dentist"})
# => [{~D[2024-01-15], "Dentist"}, {~D[2024-01-20], "Dentist"}]

# Delete by pattern
:ets.match_delete(todo, {:_, "Dentist"})
```

**Performance Note:** Key-based operations are O(1). Pattern-based operations scan the table - use sparingly on large tables.

**ETS Advanced Patterns:**

```elixir
# Owner process pattern - table dies with owner
def init(_) do
  :ets.new(@table, [:named_table, :public, read_concurrency: true])
  {:ok, nil}  # Keep process alive to keep table
end

# DETS to ETS hydration at startup
defp hydrate_from_dets do
  {:ok, dets} = :dets.open_file(:backup, file: ~c"data.dets", access: :read)
  :dets.to_ets(dets, @ets_table)
  :dets.close(dets)
end

# Efficient bulk cleanup with select_delete
now = System.monotonic_time(:millisecond)
:ets.select_delete(@table, [
  {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
])

# Match spec: pattern literals vs guards
# BAD: Guard requires full table scan
:ets.select(@table, [
  {{:"$1", :"$2", :"$3"}, [{:==, :"$3", "patio"}], [:"$_"]}
])

# GOOD: Pattern literal - VM optimizes row lookup
:ets.select(@table, [
  {{:"$1", :"$2", "patio"}, [], [:"$_"]}
])

# GOOD: Multiple patterns for OR conditions (no guards needed)
:ets.select(@table, [
  {{:"$1", :"$2", "patio"}, [], [:"$_"]},
  {{:"$1", :"$2", "kitchen"}, [], [:"$_"]}
])
```

**Match Spec Tip:** Use flat tuples and pattern match on literal values in tuple positions. Guards like `{:==, :"$3", value}` force full table scans; literal patterns allow the VM to optimize row discovery.

### :dets - Disk ETS

```elixir
{:ok, ref} = :dets.open_file(name, [
  file: ~c"path.dets",
  type: :set | :bag | :duplicate_bag,
  access: :read | :read_write,
  auto_save: interval_ms
])

:dets.insert(ref, {key, value})
:dets.lookup(ref, key)
:dets.delete(ref, key)
:dets.sync(ref)                       # Flush to disk
:dets.close(ref)                      # Close file
:dets.to_ets(dets_ref, ets_table)     # Copy DETS to ETS
```

### :ordsets - Sorted Unique Sets

Ordered sets as sorted lists. Used in Elixir's own compiler (lexical tracker, Mix compiler) for tracking unique sorted items. Faster than MapSet for small sets (<50 elements) where sort order matters.

```elixir
# Create from list (deduplicates and sorts)
set = :ordsets.from_list([:c, :a, :b, :a])  # => [:a, :b, :c]

# Operations
:ordsets.add_element(:d, set)        # => [:a, :b, :c, :d]
:ordsets.del_element(:b, set)        # => [:a, :c]
:ordsets.is_element(:a, set)         # => true
:ordsets.union(set1, set2)           # Sorted union
:ordsets.intersection(set1, set2)    # Sorted intersection
:ordsets.subtract(set1, set2)        # Sorted difference
:ordsets.to_list(set)                # Already a sorted list

# Real usage: tracking compile-time dependencies (from Elixir source)
# compile_env: :ordsets.new()
# update_in(state.compile_env, &:ordsets.add_element({app, path, return}, &1))
```

**When to use:** Small sorted unique collections, compile-time tracking, dependency lists. For large sets, use MapSet instead.

### :digraph - Directed Graphs

Mutable directed graph backed by ETS tables. Used in Mix for dependency resolution and `mix xref` for cross-reference analysis.

```elixir
# Create and populate
graph = :digraph.new()
v1 = :digraph.add_vertex(graph, :app_a)
v2 = :digraph.add_vertex(graph, :app_b)
v3 = :digraph.add_vertex(graph, :app_c)
:digraph.add_edge(graph, v1, v2)     # app_a depends on app_b
:digraph.add_edge(graph, v2, v3)     # app_b depends on app_c

# Query
:digraph.vertices(graph)             # All vertices
:digraph.edges(graph)                # All edges
:digraph.out_neighbours(graph, v1)   # Direct dependencies of v1
:digraph.in_neighbours(graph, v3)    # What depends on v3
:digraph.out_degree(graph, v1)       # Number of outgoing edges

# Path algorithms
:digraph.get_short_path(graph, v1, v3)  # Shortest path: [:app_a, :app_b, :app_c]
:digraph.get_cycle(graph, v1)           # Detect circular dependency

# Topological sort (build order)
:digraph_utils.topsort(graph)           # => [:app_c, :app_b, :app_a] or false if cycle

# IMPORTANT: digraph is mutable (ETS-backed) — always clean up
:digraph.delete(graph)

# Typical pattern: create, compute, delete
graph = :digraph.new()
try do
  # ... build graph and run algorithms ...
  :digraph_utils.topsort(graph)
after
  :digraph.delete(graph)
end
```

**When to use:** Dependency resolution, build ordering, cycle detection, shortest path. Always wrap in try/after for cleanup.

### :gb_trees - General Balanced Trees

Ordered key-value store with O(log n) operations. Rarely needed in modern Elixir (maps are usually better), but useful when you need ordered iteration by key.

```elixir
tree = :gb_trees.empty()
tree = :gb_trees.insert(1, "one", tree)
tree = :gb_trees.insert(3, "three", tree)
tree = :gb_trees.insert(2, "two", tree)

:gb_trees.get(2, tree)              # => "two"
:gb_trees.lookup(2, tree)           # => {:value, "two"}
:gb_trees.lookup(99, tree)          # => :none
:gb_trees.to_list(tree)             # => [{1, "one"}, {2, "two"}, {3, "three"}] — sorted!
:gb_trees.smallest(tree)            # => {1, "one"}
:gb_trees.largest(tree)             # => {3, "three"}
:gb_trees.size(tree)                # => 3
{_key, _val, tree} = :gb_trees.take_smallest(tree)  # Pop smallest
```

**When to use:** When you need a sorted key-value store with min/max access. For most cases, use `Map` + `Enum.sort` or `:orddict` for small sorted maps.

### :array - Functional Arrays

Fixed or dynamic-size arrays with O(log n) access by index. Useful when you genuinely need index-based access (rare in Elixir).

```elixir
arr = :array.new(10, default: 0)     # Fixed size, default 0
arr = :array.set(3, "hello", arr)    # Set index 3
:array.get(3, arr)                   # => "hello"
:array.get(0, arr)                   # => 0 (default)
:array.size(arr)                     # => 10
:array.to_list(arr)                  # => [0, 0, 0, "hello", 0, ...]

# Dynamic sizing
arr = :array.new(default: :undefined)  # Grows as needed
arr = :array.set(100, :value, arr)     # Auto-expands

# Sparse array — efficient for scattered indices
arr = :array.new(sparse: true, default: :none)
```

**When to use:** Truly index-based data (e.g., grid/matrix cells, ring buffers). For most Elixir code, use lists, maps, or tuples instead.

### :math - Mathematical Functions

```elixir
:math.pi()                # 3.141592653589793
:math.sqrt(16)            # 4.0
:math.pow(2, 10)          # 1024.0
:math.log(100)            # Natural log: 4.605...
:math.log2(1024)          # 10.0
:math.log10(100)          # 2.0
:math.sin(:math.pi / 2)  # 1.0
:math.ceil(3.2)           # 4.0
:math.floor(3.8)          # 3.0
```

### :rand - Random Numbers

```elixir
:rand.uniform()             # Float in [0.0, 1.0)
:rand.uniform(100)          # Integer in [1, 100]
:rand.uniform_real()        # Float in (0.0, 1.0) — never returns 0.0
Enum.random(1..100)         # Elixir wrapper (uses :rand internally)
Enum.shuffle(list)          # Random permutation
Enum.take_random(list, 5)   # Random sample without replacement
```

### :binary - Raw Binary Operations

```elixir
:binary.bin_to_list(<<195, 152>>)           # => [195, 152] (raw bytes, not codepoints)
:binary.copy("ab", 3)                       # => "ababab"
:binary.match("hello world", "world")       # => {6, 5} (offset, length)
:binary.part("hello", 1, 3)                 # => "ell"
:binary.split("a,b,c", ",", [:global])      # => ["a", "b", "c"]

# Compile pattern for reuse (avoids recompilation in hot paths)
pattern = :binary.compile_pattern([",", ";"])
:binary.split(input, pattern, [:global, :trim])

# Useful for stripping whitespace from binary data
:binary.replace(data, "\r\n", "\n", [:global])
```

### :erlang - System Primitives

Functions called directly when Elixir wrappers don't exist or performance matters:

```elixir
# Serialization (used by distributed Erlang, caching, persistence)
bin = :erlang.term_to_binary(%{key: [1, 2, 3]})
term = :erlang.binary_to_term(bin)
# SECURITY: never deserialize untrusted data without :safe option
:erlang.binary_to_term(bin, [:safe])  # Only existing atoms

# Hashing (fast, deterministic within a VM instance)
:erlang.phash2(term)              # Hash any term to non-negative integer
:erlang.phash2(key, num_buckets)  # Hash into 0..num_buckets-1 (sharding)

# Unique identifiers
:erlang.unique_integer([:positive, :monotonic])  # Guaranteed unique, increasing
:erlang.unique_integer([:positive])              # Unique but not ordered

# Type conversion (when Elixir wrappers don't exist)
:erlang.float_to_binary(3.14, [:short])          # "3.14" (shortest representation)
:erlang.binary_to_float("3.14")                  # 3.14
:erlang.list_to_integer(~c"FF", 16)              # 255 (parse hex)
:erlang.integer_to_list(255, 16)                 # ~c"FF" (format hex)

# System info
:erlang.system_info(:process_count)              # Current process count
:erlang.system_info(:atom_count)                 # Current atom count
:erlang.system_info(:atom_limit)                 # Atom table limit
:erlang.memory()                                 # [{:total, bytes}, {:processes, ...}, ...]
:erlang.memory(:total)                           # Total memory in bytes

# Process dictionary (same as Process.put/get but Erlang API)
:erlang.put(:key, value)
:erlang.get(:key)
:erlang.get()                                    # All process dict entries
```

### :lists - Low-Level List Operations

Use when you need Erlang-level performance or functions not exposed by Elixir:

```elixir
# :lists.reverse/2 — reverse and prepend (avoids ++ operator)
:lists.reverse(accumulated, tail)    # Equivalent to Enum.reverse(acc) ++ tail

# Tuple-keyed list operations (for ETS-style data)
:lists.keyfind(:name, 1, tuples)     # Find by key at position 1
:lists.keysort(1, tuples)            # Sort tuples by position 1
:lists.keystore(:name, 1, list, new_tuple)  # Replace or append by key
:lists.keydelete(:name, 1, list)     # Delete by key
:lists.keytake(:name, 1, list)       # {found, rest} or false

# Sorting with dedup
:lists.usort(list)                   # Sort + remove duplicates
:lists.usort(fn a, b -> a <= b end, list)  # Custom sort + dedup

# Membership (sometimes faster than MapSet for small lists)
:lists.member(:item, list)           # Boolean

# Combined map + accumulate (efficient single-pass)
:lists.mapfoldl(fn x, acc -> {x * 2, acc + x} end, 0, [1, 2, 3])
# => {[2, 4, 6], 6}

# Flatten with tail
:lists.flatten([[1, [2]], 3], [4, 5])  # [1, 2, 3, 4, 5]
```

### :timer - Timing Utilities

```elixir
# Measure execution time (returns {microseconds, result})
{usec, result} = :timer.tc(fn -> expensive_work() end)
{usec, result} = :timer.tc(Module, :function, [args])

# Time unit conversions (returns milliseconds)
:timer.seconds(30)               # 30_000
:timer.minutes(5)                # 300_000
:timer.hours(1)                  # 3_600_000

# Periodic messages (prefer Process.send_after for one-shots)
{:ok, tref} = :timer.send_interval(1000, self(), :tick)  # Every 1s
:timer.cancel(tref)              # Stop interval

# Delayed execution
:timer.apply_after(5000, Module, :function, [args])
```

### :crypto - Cryptographic Operations (OTP 24+)

> **API note:** OTP 24 replaced the old API (`block_encrypt`, `hmac`, `stream_init`, etc.) with
> the new unified API below. Old function names were removed. Cipher naming changed from
> `aes_cbc128` to `aes_128_cbc` (standardized `ALGORITHM_KEYSIZE_MODE`).

```elixir
# Secure random bytes (for tokens, IDs, secrets)
:crypto.strong_rand_bytes(16)                    # 16 random bytes
:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)  # Hex token
:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)  # URL-safe token
```

**Hashing** — `hash(type, data) :: binary()`

```elixir
:crypto.hash(:sha256, "data")                    # SHA-256 digest (32 bytes)
:crypto.hash(:sha3_256, "data")                  # SHA3-256 digest (32 bytes)
:crypto.hash(:blake2b, "data")                   # BLAKE2b digest (64 bytes)
```

| Hash atom | Algorithm | Output bytes | Use |
|-----------|-----------|-------------|-----|
| `:sha256` | SHA-256 | 32 | General purpose, most common |
| `:sha384` | SHA-384 | 48 | Higher security margin |
| `:sha512` | SHA-512 | 64 | High security |
| `:sha3_256` | SHA3-256 | 32 | Post-quantum safe, NIST |
| `:sha3_512` | SHA3-512 | 64 | Post-quantum, max security |
| `:blake2b` | BLAKE2b | 64 | Fastest secure hash |
| `:blake2s` | BLAKE2s | 32 | Fast on 32-bit platforms |
| `:md5` | MD5 | 16 | Checksums only — NOT security |

Check runtime support: `:crypto.supports(:hashs)`

**HMAC** — `mac(type, sub_type, key, data) :: binary()`

```elixir
:crypto.mac(:hmac, :sha256, key, message)        # HMAC-SHA256 (32 bytes)
:crypto.mac(:hmac, :sha512, key, message)        # HMAC-SHA512 (64 bytes)
:crypto.mac(:poly1305, :poly1305, key_32, data)  # Poly1305 (key must be 32 bytes)
```

**ECDH Key Exchange** — Diffie-Hellman key agreement over elliptic curves

```elixir
# Generate keypair — returns {public_key, private_key} as binaries
{my_pub, my_priv} = :crypto.generate_key(:ecdh, :x25519)     # 32-byte keys
{my_pub, my_priv} = :crypto.generate_key(:ecdh, :x448)       # 56-byte keys
{my_pub, my_priv} = :crypto.generate_key(:ecdh, :secp256r1)  # NIST P-256

# Compute shared secret — both sides derive the same value
shared = :crypto.compute_key(:ecdh, others_pub, my_priv, :x25519)  # 32-byte shared secret
```

| Curve atom | Key size | Shared secret | Use |
|-----------|----------|---------------|-----|
| `:x25519` | 32 B | 32 B | Modern default — fast, safe, widely supported |
| `:x448` | 56 B | 56 B | Higher security margin (~224-bit) |
| `:secp256r1` | 32 B | 32 B | NIST P-256, FIPS compliant, TLS standard |
| `:secp256k1` | 32 B | 32 B | Bitcoin/Ethereum, NOT recommended for new designs |

Check runtime support: `:crypto.supports(:curves)`

**AEAD Encryption** — Authenticated Encryption with Associated Data

```elixir
# Encrypt — returns {ciphertext, tag}
key   = :crypto.strong_rand_bytes(32)   # 32 bytes for AES-256-GCM / ChaCha20
nonce = :crypto.strong_rand_bytes(12)   # 12 bytes (ALWAYS use 12)
aad   = "associated data"               # Authenticated but not encrypted

{ciphertext, tag} = :crypto.crypto_one_time_aead(
  :aes_256_gcm, key, nonce, "plaintext", aad, true
)

# Decrypt — returns plaintext or the atom :error on auth failure
plaintext = :crypto.crypto_one_time_aead(
  :aes_256_gcm, key, nonce, ciphertext, aad, tag, false
)
# => "plaintext" or :error (NOT {:error, reason})
```

| AEAD cipher | Key | Nonce | Tag | Notes |
|-------------|-----|-------|-----|-------|
| `:aes_128_gcm` | 16 B | 12 B | 16 B | FIPS approved |
| `:aes_256_gcm` | 32 B | 12 B | 16 B | FIPS approved, recommended |
| `:chacha20_poly1305` | 32 B | 12 B | 16 B | Fast on platforms without AES-NI, RFC 8439 |

**CRITICAL:** Never reuse a nonce with the same key — completely breaks confidentiality and authentication.
**CRITICAL:** Nonce MUST be exactly 12 bytes. Non-12-byte IVs for GCM reduce security (triggers internal GHASH).
**CRITICAL:** Decrypt returns the **atom** `:error` on failure, not `{:error, reason}`. Pattern match accordingly.

**Digital Signatures** — Ed25519 (EdDSA)

```elixir
# Generate signing keypair
{pub, priv} = :crypto.generate_key(:eddsa, :ed25519)   # 32 B pub, 32 B priv

# Sign — key argument is a LIST: [private_key, curve]
signature = :crypto.sign(:eddsa, :none, "message", [priv, :ed25519])   # 64-byte signature

# Verify — key argument is a LIST: [public_key, curve]
true = :crypto.verify(:eddsa, :none, "message", signature, [pub, :ed25519])
```

**CRITICAL:** DigestType MUST be `:none` for EdDSA — Ed25519 handles hashing internally (SHA-512).
Using `:sha512` will fail.

**CRITICAL:** Key argument is a **list** `[key, :ed25519]`, NOT a tuple. Using `{key, curve}` will fail.

| Signature algorithm | Type atom | Digest | Key format |
|---|---|---|---|
| Ed25519 | `:eddsa` | `:none` | `[key, :ed25519]` |
| Ed448 | `:eddsa` | `:none` | `[key, :ed448]` |
| ECDSA P-256 | `:ecdsa` | `:sha256` | `[key, :secp256r1]` |

**Key Derivation (HKDF)** — Not built into `:crypto`, implement via HMAC (RFC 5869)

```elixir
defmodule HKDF do
  @doc "Extract a pseudorandom key from input keying material."
  def extract(hash \\ :sha256, ikm, salt) do
    :crypto.mac(:hmac, hash, salt, ikm)
  end

  @doc "Expand pseudorandom key to desired length."
  def expand(hash \\ :sha256, prk, info, length) do
    hash_len = byte_size(:crypto.hash(hash, ""))
    n = ceil(length / hash_len)

    {okm, _} =
      Enum.reduce(1..n, {<<>>, <<>>}, fn i, {acc, prev} ->
        t = :crypto.mac(:hmac, hash, prk, <<prev::binary, info::binary, i::8>>)
        {<<acc::binary, t::binary>>, t}
      end)

    binary_part(okm, 0, length)
  end
end

# Usage: derive encryption key from shared secret
prk = HKDF.extract(:sha256, shared_secret, salt)
encryption_key = HKDF.expand(:sha256, prk, "encryption", 32)
```

**Which :crypto function?**

| Need | Function | Returns |
|------|----------|---------|
| Random bytes | `strong_rand_bytes/1` | `binary()` |
| Hash data | `hash/2` | `binary()` |
| Authenticate message | `mac/4` (`:hmac`) | `binary()` |
| Encrypt + authenticate | `crypto_one_time_aead/6` | `{ciphertext, tag}` |
| Decrypt + verify | `crypto_one_time_aead/7` | `plaintext \| :error` |
| Key agreement (DH) | `generate_key/2` + `compute_key/4` | `{pub, priv}`, `binary()` |
| Sign data | `sign/4` | `binary()` |
| Verify signature | `verify/5` | `boolean()` |
| Derive subkeys | Manual HKDF via `mac/4` | `binary()` |
| Password hashing | `crypto:pbkdf2_hmac/5` (OTP 24+) | `binary()` |

### :io_lib - Erlang Format Strings

```elixir
# printf-style formatting (useful for hex, padded numbers)
:io_lib.format("~4.16.0B", [255])               # ["00FF"] (4-wide hex, zero-padded)
:io_lib.format("~.2f", [3.14159])               # ["3.14"] (2 decimal places)
:io_lib.format("~p", [term])                    # Pretty-print any term
:io_lib.format("~w", [term])                    # Write any term (compact)

# Convert to binary for use in Elixir strings
IO.iodata_to_binary(:io_lib.format("0x~4.16.0B", [addr]))
```

### :calendar - Date/Time Conversions

```elixir
# Current time as Erlang tuple
:calendar.universal_time()       # {{2026, 3, 16}, {12, 0, 0}}
:calendar.local_time()           # {{2026, 3, 16}, {13, 0, 0}}

# Gregorian seconds (useful for cookie expiry, RFC timestamps)
secs = :calendar.datetime_to_gregorian_seconds({{2026, 3, 16}, {0, 0, 0}})
:calendar.gregorian_seconds_to_datetime(secs + 3600)

# Day of week (1=Monday, 7=Sunday)
:calendar.day_of_the_week({2026, 3, 16})  # 1 (Monday)

# Validation
:calendar.valid_date(2026, 2, 29)         # false (not leap year)
```

### :unicode - Character Handling

```elixir
# Convert between encodings
:unicode.characters_to_binary(charlist)          # Charlist -> binary string
:unicode.characters_to_binary(data, :utf8)       # Explicit encoding
:unicode.characters_to_list("hello")             # Binary -> codepoint list

# Normalization (important for string comparison)
:unicode.characters_to_nfc_binary("cafe\u0301")  # Composed form (canonical)
:unicode.characters_to_nfd_binary("cafe\u0301")  # Decomposed form
```

### :zlib - Compression

```elixir
# Gzip (common for HTTP responses, file compression)
compressed = :zlib.gzip(data)
original = :zlib.gunzip(compressed)

# Raw deflate/inflate
compressed = :zlib.compress(data)
original = :zlib.uncompress(compressed)
```

### :os - Operating System Interface

```elixir
# OS type detection
case :os.type() do
  {:unix, :linux} -> "Linux"
  {:unix, :darwin} -> "macOS"
  {:win32, _} -> "Windows"
end

# High-resolution time
:os.system_time(:microsecond)                    # OS clock in microseconds

# Environment (Erlang API — prefer System.get_env)
:os.getenv(~c"HOME")                             # Returns charlist or false
```

### :telemetry - Instrumentation

```elixir
# Emit events (Phoenix, Ecto, Plug all emit telemetry)
:telemetry.execute(
  [:my_app, :request, :stop],                    # Event name (list of atoms)
  %{duration: duration},                          # Measurements (numeric)
  %{method: "GET", path: "/api"}                  # Metadata
)

# Measure a span (start + stop events automatically)
:telemetry.span([:my_app, :db, :query], %{}, fn ->
  result = run_query()
  {result, %{rows: length(result)}}               # {return_value, extra_metadata}
end)

# Attach handlers
:telemetry.attach(
  "log-requests",                                 # Unique handler ID
  [:my_app, :request, :stop],                     # Event to listen for
  &MyApp.Telemetry.handle_event/4,               # Handler function
  nil                                             # Config
)

:telemetry.attach_many("log-all", [
  [:my_app, :request, :start],
  [:my_app, :request, :stop],
  [:my_app, :request, :exception]
], &handler/4, nil)

# Detach
:telemetry.detach("log-requests")
```

### :sys - Process Debugging

```elixir
# Get GenServer state without changing it (works on ANY OTP process)
:sys.get_state(pid)                              # Returns internal state
:sys.get_state(MyApp.Server)                     # By registered name

# Replace state (debugging only!)
:sys.replace_state(pid, fn state -> %{state | debug: true} end)

# Trace process messages (very useful for debugging)
:sys.trace(pid, true)                            # Enable trace logging
:sys.trace(pid, false)                           # Disable

# Get process statistics
:sys.statistics(pid, :get)                       # Messages in/out, reductions
```

### :file - Erlang File Operations

```elixir
# Load Erlang terms from file (config files, .app files)
{:ok, terms} = :file.consult(~c"config.terms")

# Format error reasons to human-readable
reason_str = :file.format_error(:enoent)         # "no such file or directory"

# Priv directory (for OTP apps)
:code.priv_dir(:my_app)                          # ~c"/path/to/priv"
Path.join(:code.priv_dir(:my_app) |> to_string(), "static")
```

### Erlang Data Structure Selection Guide

| Structure | Elixir equiv | O(lookup) | O(insert) | Ordered? | When to use from Elixir |
|---|---|---|---|---|---|
| `:queue` | none | O(1) front/back | O(1) amort | FIFO | Message buffers, BFS |
| `:ordsets` | none | O(n) | O(n) | sorted | Small sorted unique sets (<50) |
| `:orddict` | none | O(n) | O(n) | sorted keys | Small sorted key-value (<50) |
| `:gb_trees` | none | O(log n) | O(log n) | sorted keys | Sorted KV with min/max access |
| `:gb_sets` | none | O(log n) | O(log n) | sorted | Large sorted sets |
| `:array` | none | O(log n) | O(log n) | indexed | Index-based sparse data |
| `:digraph` | none | varies | O(1) | no | Graph algorithms (mutable!) |
| `:sets` | MapSet | O(1) avg | O(1) avg | no | MapSet uses this internally |
| `:ets` | none | O(1) avg | O(1) avg | no | Cross-process, high-volume |
| `:persistent_term` | none | O(1) | expensive | no | Read-heavy config |

**Rule of thumb:** Start with Elixir's Map, List, MapSet, and Keyword. Reach for Erlang structures only when you need specific properties they provide (FIFO ordering, sorted keys, graph algorithms, mutable state, index-based access).

## JSON Encoding

### JSON Module (Elixir 1.18+)

Elixir 1.18 added `JSON` to stdlib - no external dependency needed:

```elixir
# Encoding
JSON.encode!(%{name: "John", age: 30})
# => "{\"name\":\"John\",\"age\":30}"

JSON.encode(%{data: value})
# => {:ok, "..."} | {:error, reason}

# Decoding
JSON.decode!("{\"name\":\"John\"}")
# => %{"name" => "John"}
```

### Torque Library

Use Torque when the project standardizes on its Rust-backed JSON codec:

```elixir
# In mix.exs
{:torque, "~> 0.2.3"}

# Convert structs or internal data to JSON-compatible maps at the boundary.
user_json = %{id: 1, email: "a@b.com", name: nil}

Torque.encode!(user_json)
# => "{\"id\":1,\"email\":\"a@b.com\",\"name\":null}"

Torque.decode!(~s({"id":1,"email":"a@b.com"}))
# => %{"id" => 1, "email" => "a@b.com"}
```

### Safe JavaScript Interop

When passing Elixir data to JavaScript (LiveView, Alpine.js, hooks):

```elixir
# BAD: String interpolation breaks on quotes/newlines
~s|message = '#{@user_input}'|  # Breaks if input contains '

# GOOD: JSON encoding produces valid JavaScript
~s|message = #{JSON.encode!(@user_input)}|

# In HEEx templates
<div x-init={"config = #{JSON.encode!(@config)}"}>
```

**Rule:** Always use `JSON.encode!` when embedding Elixir data in JavaScript strings.

## Related Files

- **[SKILL.md](SKILL.md)** — Core Elixir rules, BAD/GOOD pairs, decision frameworks, top-function summaries
- **[data-structures.md](data-structures.md)** — Data structure selection, performance characteristics, structs, binary patterns
- **[language-patterns.md](language-patterns.md)** — Pattern matching, guards, pipelines (tap/then/dbg), behaviours, protocols, streams
- **[production.md](production.md)** — Mix custom tasks, quality aliases, telemetry, HTTP clients
