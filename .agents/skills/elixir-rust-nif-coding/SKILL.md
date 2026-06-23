---
name: rust-nif
description: >
  Rust NIFs with Rustler for Elixir — safe native code, BEAM/OTP integration,
  error handling, scheduler management, and process communication.
  ALWAYS use when writing Rust NIFs or Rustler code.
  ALWAYS use when integrating native Rust code with Elixir/BEAM.
  ALWAYS use when debugging NIF performance, crashes, or type conversion issues.
---

# Rust NIFs with Rustler

## 1. Rules for Writing Rust NIFs (LLM)

1. **ALWAYS use dirty schedulers** for operations >1ms — normal scheduler NIFs must complete in <1ms or they block the BEAM
   ```rust
   #[rustler::nif(schedule = "DirtyCpu")]  // CPU work
   #[rustler::nif(schedule = "DirtyIo")]   // I/O work
   ```

2. **NEVER return `Result<Atom, Atom>` where `Ok` wraps `:ok`** — this creates `{:ok, :ok}` double-wrapping on the Elixir side. Return `Atom` directly for void-like operations, or return a meaningful value in `Ok`
   ```rust
   // BAD: produces {:ok, :ok} in Elixir
   fn insert(set: ResourceArc<Set>, val: i64) -> Result<Atom, Atom> {
       // ...
       Ok(atoms::ok())  // Elixir sees {:ok, :ok}
   }
   // GOOD: return the meaningful value, or use Atom directly
   fn insert(set: ResourceArc<Set>, val: i64) -> Result<bool, Atom> {
       // ...
       Ok(true)  // Elixir sees {:ok, true}
   }
   // GOOD: for void operations that can't fail, just return Atom
   fn insert(set: ResourceArc<Set>, val: i64) -> Atom {
       // ...
       atoms::ok()  // Elixir sees :ok
   }
   ```

   ### Return Type Matrix — How Rustler Encodes Results

   | Rust return type | Elixir sees | Correct? |
   |---|---|---|
   | `Result<Atom, E>` | `{:ok, :ok}` / `{:error, e}` | **BAD** — double-wrapped |
   | `Result<(Atom, ResourceArc<T>), E>` | `{:ok, {:ok, ref}}` / `{:error, e}` | **BAD** — double-wrapped |
   | `Result<ResourceArc<T>, E>` | `{:ok, ref}` / `{:error, e}` | Good |
   | `Result<Vec<String>, E>` | `{:ok, ["..."]}` / `{:error, e}` | Good |
   | `Result<bool, E>` | `{:ok, true}` / `{:error, e}` | Good |
   | `Atom` | `:ok` | Good — for fire-and-forget |
   | `ResourceArc<T>` | `ref` | Good — when it can't fail |
   | `(Atom, Vec<String>)` | `{:ok, ["..."]}` | Good — tuple becomes tagged tuple |

   **The rule:** `Result` wraps the `Ok` value in `{:ok, ...}`. If the `Ok` value is ALREADY a tagged atom (`:ok`, `{:ok, ref}`), you get double wrapping. Only put meaningful *data* in `Ok`.

3. **ALWAYS return Result types** instead of panicking — a panic in a NIF crashes the entire BEAM VM
   ```rust
   fn example() -> Result<T, Atom>  // Not T directly if it can fail
   ```

4. **PREFER clone-based immutability over mutex** for ResourceArc state. When mutex is needed, use `try_lock()` — blocking locks can deadlock the scheduler
   ```rust
   // BEST: Clone-based immutability (Explorer pattern — no mutex, no deadlocks)
   pub struct MyRef(pub MyData);
   impl MyRef { pub fn clone_inner(&self) -> MyData { self.0.clone() } }
   fn transform(res: ExMyData) -> Result<ExMyData, MyError> {
       let mut data = res.clone_inner();  // Clone, mutate, return new resource
       data.transform()?;
       Ok(ExMyData::new(data))
   }

   // GOOD: try_lock with error return (Discord SortedSet pattern)
   match resource.data.try_lock() {
       Some(guard) => Ok(process(&guard)),
       None => Err(atoms::lock_fail()),
   }

   // BAD: blocking lock — can deadlock the scheduler
   let guard = resource.data.lock().unwrap();
   ```

5. **ALWAYS use derive macros** for Elixir ↔ Rust type conversion
   ```rust
   #[derive(NifStruct)]       // %Module{}
   #[derive(NifMap)]          // %{key: value}  (requires ALL keys present!)
   #[derive(NifTaggedEnum)]   // :atom | {:tag, value}
   #[derive(NifUnitEnum)]     // :atom
   ```

6. **NEVER use `unwrap()` or `expect()`** in NIF function bodies — convert to Result with `.ok_or()` or `?` operator. For infallible conversions where `None`/`Err` is logically impossible, use `.expect("known valid: reason")` to document the invariant. On locks, always use `try_lock()` with error return, never `.lock().unwrap()`

7. **ALWAYS design the Elixir API first** — write how you want to call it from Elixir, then implement the Rust NIF to match

8. **ALWAYS split NIF wrappers from pure logic** — NIF functions should be thin wrappers; test the internal logic with `cargo test`, test the NIF integration with ExUnit

9. **PREFER Rayon** for data parallelism over manual thread management
   ```rust
   use rayon::prelude::*;
   data.par_iter().map(|x| process(x)).collect()
   ```

10. **PREFER `std::sync::Mutex`** (or avoid mutex entirely via clone-based immutability). No major production Rustler project (Explorer, Tokenizers, Discord SortedSet) uses `parking_lot` — all use `std::sync`. Consider `parking_lot` only if benchmarks show lock contention is a bottleneck

11. **PREFER Elixir for network I/O** — only use Rust NIFs when you need a Rust-only library, heavy CPU processing of network data, or custom binary protocol parsing

12. **ALWAYS benchmark before assuming** a NIF is faster — the overhead of crossing the NIF boundary can negate small gains

13. **ALWAYS drop MutexGuards before expensive work** — hold locks for the minimum duration
    ```rust
    let value = {
        let guard = res.data.try_lock().ok_or(atoms::lock_fail())?;
        guard.clone()
    }; // Guard dropped here
    expensive_work(value); // Lock free
    ```

14. **NEVER call `send_and_clear()` from a BEAM-managed thread** — it will panic. Only use from `std::thread::spawn` or similar

15. **ALWAYS wrap NifMap NIFs** in Elixir functions that fill missing keys with `nil` — NifMap requires ALL keys present even for `Option<T>` fields

16. **PREFER normalizing input values (case, encoding, trimming) at the Rust layer** rather than requiring Elixir callers to pre-process — the Rust side knows what the underlying library expects

17. **ALWAYS add `@spec` to public API functions that wrap NIFs** — the public-facing module (e.g., `MyApp.DataFrame`) must have specs on every function. The internal NIF stub module (`MyApp.Native`) may omit specs — Explorer and Tokenizers both skip specs on stubs and put them only on the public API. Define shared `@type` aliases when multiple functions take the same complex argument pattern
    ```elixir
    # Public API module — ALWAYS has @spec
    defmodule MyApp.DataFrame do
      @type t :: %__MODULE__{resource: reference()}
      @type column_name :: String.t() | atom()

      @spec new(list()) :: {:ok, t()} | {:error, String.t()}
      def new(data), do: Native.df_new(data)

      @spec names(t()) :: {:ok, [String.t()]} | {:error, String.t()}
      def names(df), do: Native.df_names(df)
    end

    # Native stub module — specs optional (internal module)
    defmodule MyApp.Native do
      use Rustler, otp_app: :my_app, crate: "my_nif"
      def df_new(_data), do: :erlang.nif_error(:nif_not_loaded)
      def df_names(_df), do: :erlang.nif_error(:nif_not_loaded)
    end
    ```

18. **NEVER return `Vec<u8>` to represent binary data** — Rustler encodes `Vec<u8>` as a *list of integers*, not a binary. Use `NewBinary` to return binary data to Elixir
    ```rust
    // BAD: Vec<u8> becomes [104, 101, 108, 108, 111] in Elixir (a list!)
    fn compress(data: Binary) -> Vec<u8> {
        do_compress(data.as_slice())
    }

    // GOOD: NewBinary becomes a proper Elixir binary
    fn compress(env: Env, data: Binary) -> Binary {
        let compressed = do_compress(data.as_slice());
        let mut output = NewBinary::new(env, compressed.len());
        output.as_mut_slice().copy_from_slice(&compressed);
        output.into()
    }
    ```

19. **ALWAYS enter the tokio runtime context in DirtyIo NIFs that construct async objects** — libraries like quinn (QUIC), mDNS, and other tokio-dependent crates panic with "there is no reactor running" if not inside a runtime context
    ```rust
    #[rustler::nif(schedule = "DirtyIo")]
    fn create_node(config: Config) -> Result<ResourceArc<NodeHandle>, String> {
        let runtime = RUNTIME.get().ok_or("runtime not initialized")?;
        let _guard = runtime.enter();  // Establishes tokio context for this thread
        // Now quinn::Endpoint::new(), mDNS, etc. can find the reactor
        let node = build_node(config).map_err(|e| e.to_string())?;
        Ok(ResourceArc::new(node))
    }
    ```

20. **ALWAYS use `#[rustler::resource_impl]`** on `impl Resource for T` blocks — in Rustler 0.36+, bare `impl Resource for T {}` does NOT register the resource type and causes a runtime panic (`called Option::unwrap() on a None value`). The attribute macro performs registration AND auto-generates `IMPLEMENTS_*` constants by detecting which callback functions (`down`, `destructor`, `dyncall`) are present — never set these booleans manually.
    ```rust
    // BAD: compiles but panics at runtime — resource not registered
    impl rustler::Resource for MyResource {}

    // BAD: macro on bare impl can't see callbacks, won't set IMPLEMENTS_DOWN
    impl rustler::Resource for MyResource {
        const IMPLEMENTS_DOWN: bool = true; // manual — fragile, unnecessary
        fn down<'a>(&'a self, env: Env<'a>, pid: LocalPid, mon: Monitor) { }
    }
    #[rustler::resource_impl]
    impl MyResource {}

    // GOOD: macro on Resource impl — detects `down`, auto-sets IMPLEMENTS_DOWN
    #[rustler::resource_impl]
    impl rustler::Resource for MyResource {
        fn down<'a>(&'a self, env: Env<'a>, pid: LocalPid, mon: Monitor) { }
    }
    ```

## 1b. Production Patterns (from Explorer, Tokenizers, Discord SortedSet)

### Resource Wrapper Pattern (ResourceArc + NifStruct + Deref)

The de facto standard for exposing Rust types to Elixir, used by Explorer (4 types) and Tokenizers (8+ types):

```rust
// 1. Inner resource — holds the actual data
pub struct ExDataFrameRef(pub DataFrame);

#[rustler::resource_impl]
impl Resource for ExDataFrameRef {}

// 2. NifStruct wrapper — this is what Elixir sees as %Module{}
#[derive(NifStruct)]
#[module = "MyApp.DataFrame"]
pub struct ExDataFrame {
    pub resource: ResourceArc<ExDataFrameRef>,
}

// 3. Deref for ergonomic access in NIF functions
impl Deref for ExDataFrame {
    type Target = DataFrame;
    fn deref(&self) -> &Self::Target { &self.resource.0 }
}

// 4. Constructor
impl ExDataFrame {
    pub fn new(df: DataFrame) -> Self {
        Self { resource: ResourceArc::new(ExDataFrameRef(df)) }
    }
}

// 5. Clone for mutation (avoids mutex entirely)
impl ExDataFrameRef {
    pub fn clone_inner(&self) -> DataFrame { self.0.clone() }
}
```

### Custom Error Type with thiserror + Encoder

Used by Explorer and Tokenizers. Scales better than raw Atom errors for projects wrapping complex upstream libraries:

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum MyError {
    #[error("upstream: {0}")]
    Upstream(#[from] upstream::Error),  // auto-convert with ?
    #[error("internal: {0}")]
    Internal(String),
    #[error("{0}")]
    Other(String),
}

impl rustler::Encoder for MyError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        format!("{self}").encode(env)  // Returns error string to Elixir
    }
}

// Required for catch_unwind compatibility
impl std::panic::RefUnwindSafe for MyError {}

// All NIFs return Result<T, MyError> — clean ? operator chains
#[rustler::nif(schedule = "DirtyCpu")]
fn process(data: ExMyData) -> Result<ExMyData, MyError> {
    let mut inner = data.clone_inner();
    inner.transform()?;  // upstream::Error auto-converts via #[from]
    Ok(ExMyData::new(inner))
}
```

### catch_unwind for Upstream Libraries That May Panic

When wrapping a Rust library that can panic (e.g., during training, parsing malformed data), use `catch_unwind` to convert panics to errors instead of crashing the BEAM:

```rust
use std::panic;

#[rustler::nif(schedule = "DirtyCpu")]
fn train(tokenizer: ExTokenizer, files: Vec<String>) -> Result<ExTokenizer, MyError> {
    let result = panic::catch_unwind(|| {
        let mut tok = tokenizer.resource.0.clone();
        tok.train(&files).map_err(MyError::from)?;
        Ok(tok)
    });
    match result {
        Ok(Ok(tok)) => Ok(ExTokenizer::new(tok)),
        Ok(Err(e)) => Err(e),
        Err(panic_info) => Err(MyError::Internal(
            format!("panic during training: {:?}", panic_info)
        )),
    }
}
```

### Bare Return Types for Infallible Getters

For simple property accessors that cannot fail, return the value directly without Result wrapping. This avoids unnecessary `{:ok, value}` on the Elixir side:

```rust
// GOOD: bare return for infallible getter — Elixir sees just the value
#[rustler::nif]
fn get_vocab_size(tokenizer: ExTokenizer) -> usize {
    tokenizer.get_vocab_size(true)
}

// GOOD: Option for nullable getters — Elixir sees value or nil
#[rustler::nif]
fn get_model(tokenizer: ExTokenizer) -> Option<ExModel> {
    tokenizer.get_model().map(ExModel::new)
}

// Use Result only when the operation can genuinely fail
#[rustler::nif(schedule = "DirtyCpu")]
fn encode(tokenizer: ExTokenizer, text: String) -> Result<ExEncoding, MyError> {
    let enc = tokenizer.encode(text, true)?;
    Ok(ExEncoding::new(enc))
}
```

## 2. When to Use Rust NIFs

### Good Use Cases

| Use Case | Why NIF? | Examples |
|----------|----------|----------|
| CPU-intensive computation | BEAM not optimized for number crunching | Image processing, crypto, compression |
| Large data structures | Rust's memory layout more efficient | Discord's SortedSet (11M users) |
| Specific Rust libraries | No Elixir equivalent | Polars, tokenizers, parsers |
| Performance-critical paths | 10x-100x speedup possible | JSON parsing, binary protocols |

### Performance Thresholds

```
Operation Time       | Recommendation
---------------------|----------------------------------
< 1 microsecond      | Probably not worth NIF overhead
1-100 microseconds   | Maybe, benchmark first
100 μs - 1 ms        | Good candidate for regular NIF
1-10 ms              | Use DirtyCpu scheduler
10-100 ms            | Use dirty scheduler + chunking
100+ ms              | Consider Port or yielding NIF
```

### When NOT to Use NIFs

1. **I/O-bound work** — Elixir's async model is better
2. **Simple transforms** — overhead of NIF call > savings
3. **Fault tolerance requirements** — NIF crash = entire VM crash (use Ports for isolation)
4. **Prototyping** — Rust has slower iteration than Elixir

| Alternative | Use When | Trade-off |
|-------------|----------|-----------|
| Port | Need isolation from crashes | Slower (IPC overhead) |
| :os.cmd | Simple scripts | Very slow, security risk |
| Task.async | Parallel Elixir | Limited by BEAM |
| Flow/Broadway | Data pipelines | Good for I/O, not CPU |

## 3. Rust Fundamentals for NIFs

### Ownership Rules (Critical for NIFs)
```rust
// Values have ONE owner - when owner goes out of scope, value is dropped
let s1 = String::from("hello");
let s2 = s1;  // s1 is MOVED, no longer valid

// Borrow instead of move
let s1 = String::from("hello");
let len = calculate_length(&s1);  // Borrow with &
println!("{}", s1);  // s1 still valid
```

### Move Semantics with Closures (Critical for Threads)
```rust
// Thread closures MUST use `move` to take ownership
let data = vec![1, 2, 3];
thread::spawn(move || {
    // data is MOVED here - thread might outlive parent
    process(data)
});
// data no longer valid here!
```

### Lifetime Annotations
```rust
// 'a - tied to Env lifetime (NIF call duration)
fn example<'a>(env: Env<'a>) -> Term<'a> { ... }

// 'static - lives forever (required for spawned threads)
pub fn spawn<F, T>(f: F) -> JoinHandle<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
// This is why we use `move` closures in NIFs
```

### String Types in NIFs
```rust
// String: heap-allocated, owned, mutable - use for return values
#[rustler::nif]
fn process_string(input: String) -> String {
    input.to_uppercase()
}

// &str: borrowed view, zero-copy from Elixir - use for read-only
#[rustler::nif]
fn count_chars(input: &str) -> usize {
    input.chars().count()
}

// Binary: zero-copy bytes from Elixir - most efficient for raw data
#[rustler::nif]
fn binary_length(data: Binary) -> usize {
    data.len()  // No copy!
}

// NewBinary: allocate BEAM binary, write into it, return without copy
// Use this instead of Vec<u8> when returning large binary data
#[rustler::nif]
fn compress(env: Env, data: Binary) -> Binary {
    let compressed = do_compress(data.as_slice());
    let mut output = NewBinary::new(env, compressed.len());
    output.as_mut_slice().copy_from_slice(&compressed);
    output.into()  // Converts to Binary — zero-copy return to Elixir
}
```

**Binary type selection:** `Binary` for reading input (zero-copy), `NewBinary` for writing output (allocates in BEAM heap, no copy on return), `Vec<u8>` only for intermediate Rust-side buffers.

### Error Handling (Never Panic!)
```rust
// BAD - panic crashes the BEAM!
fn bad_divide(a: i64, b: i64) -> i64 {
    a / b  // Panics on divide by zero!
}

// GOOD - return Result
fn good_divide(a: i64, b: i64) -> Result<i64, String> {
    if b == 0 {
        Err("division by zero".to_string())
    } else {
        Ok(a / b)
    }
}
```

### Thread Safety Requirements
NIF resources must be `Send + Sync`:
```rust
use std::sync::Mutex;

// Thread-safe wrapper for state
struct MyResource {
    data: Mutex<Vec<String>>,  // Mutex provides Sync
}
// ResourceArc<T> requires T: Send + Sync
```

### Smart Pointers for NIFs

| Type | Use Case | Notes |
|------|----------|-------|
| `Arc<T>` | Shared ownership across threads | ResourceArc uses this internally |
| `Mutex<T>` | Exclusive access | Blocks on contention |
| `RwLock<T>` | Multiple readers OR one writer | Better for read-heavy workloads |
| `Box<T>` | Heap allocation | Single owner |

Prefer `parking_lot::Mutex` over `std::sync::Mutex` (faster, smaller, no poisoning)

## 4. Rustler Project Setup

### Step 1: Add Dependencies
```elixir
# mix.exs
defp deps do
  [
    {:rustler, "~> 0.37.2", runtime: false}
  ]
end
```

### Step 2: Generate NIF
```bash
mix deps.get
mix rustler.new
# Enter module name: MyApp.Native
# Enter NIF name: my_nif
```

### Step 3: Cargo.toml Configuration
```toml
[package]
name = "my_nif"
version = "0.1.0"
edition = "2021"

[lib]
name = "my_nif"
crate-type = ["cdylib"]

[dependencies]
rustler = "0.37.2"

# Common additions:
# thiserror = "2.0"      # Error handling
# parking_lot = "0.12"   # Faster Mutex
# rayon = "1.10"         # Parallelism
```

### Step 4: Basic NIF Structure
```rust
// native/my_nif/src/lib.rs
#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

// Rename the Elixir-facing function (Rust name differs from Elixir name)
#[rustler::nif(name = "compute_sum")]
fn internal_sum(a: i64, b: i64) -> i64 {
    a + b
}

rustler::init!("Elixir.MyApp.Native");

// With load callback — runs once when NIF is loaded (setup global state, validate)
// rustler::init!("Elixir.MyApp.Native", load = on_load);
// fn on_load(env: Env, _info: Term) -> bool {
//     // Return true to indicate successful load, false aborts
//     true
// }
```

### Step 5: Elixir Module
```elixir
defmodule MyApp.Native do
  use Rustler,
    otp_app: :my_app,
    crate: "my_nif"

  # Every NIF binding MUST have a @spec — it's the boundary between two type systems
  @spec add(integer(), integer()) :: integer()
  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
end
```

### Adding a New NIF Function to an Existing Crate

When adding a function to a crate that already has NIFs:

1. **Rust function** — Add `#[rustler::nif]` function in the appropriate `.rs` file
2. **Register in `lib.rs`** — Add the function name to `rustler::init!("Elixir.MyApp.Native")` (forgetting this is the most common mistake — the NIF compiles but raises `:nif_not_loaded` at runtime)
3. **Elixir stub** — Add `def my_func(...), do: :erlang.nif_error(:nif_not_loaded)` with `@spec` in the native module
4. **Elixir wrapper** — Add the public API function in the appropriate context module

## 5. Type Encoding/Decoding

### Type Mapping Table

| Elixir | Rust | Notes |
|--------|------|-------|
| `integer` | `i64`, `i32`, `u64`, etc. | Use appropriate size |
| `float` | `f64`, `f32` | f64 preferred |
| `String.t()` | `String` | UTF-8, heap allocated |
| `binary` | `Binary` | Zero-copy read from Elixir |
| `binary` | `NewBinary` | Efficient write — allocate BEAM binary |
| `binary` | `Vec<u8>` | Copies data (use NewBinary instead) |
| `atom` | `Atom` | Interned strings |
| `list` | `Vec<T>` | Converted to Vec |
| `map` | `HashMap<K,V>` | Or struct with NifMap |
| `tuple` | `(A, B, ...)` | Or struct with NifTuple |
| `nil` | `()` | Unit type |
| `pid` | `LocalPid` | Process identifier |
| `reference` | `Reference` | Unique reference |

### Derive Macros

```rust
use rustler::{NifStruct, NifMap, NifTuple, NifTaggedEnum, NifUnitEnum};

// Elixir: %MyApp.User{name: "Alice", age: 30}
#[derive(NifStruct)]
#[module = "MyApp.User"]
struct User {
    name: String,
    age: i32,
    email: Option<String>,  // Optional field
}

// Elixir: %{host: "localhost", port: 8080}
#[derive(NifMap)]
struct Config {
    host: String,
    port: i32,
}

// Elixir: {1, 2}
#[derive(NifTuple)]
struct Point(i32, i32);

// Elixir: :ok | {:error, String} | {:pending, %{id: 1}}
#[derive(NifTaggedEnum)]
enum Status {
    Ok,                      // :ok
    Error(String),           // {:error, "message"}
    Pending { id: i32 },     // {:pending, %{id: 1}}
}

// Elixir: :red | :green | :blue
#[derive(NifUnitEnum)]
enum Color {
    Red,
    Green,
    Blue,
}
```

### Atoms Macro
```rust
mod atoms {
    rustler::atoms! {
        ok,
        error,
        nil,
        not_found,
        invalid_input,
        lock_fail,
    }
}

// Usage
fn example() -> Atom {
    atoms::ok()
}
```

## 6. Scheduler Safety Rules

### The 1ms Rule
NIFs on the normal scheduler MUST complete in under 1 millisecond. Longer NIFs block the scheduler and can cause:
- Scheduler collapse
- Process starvation
- Unresponsive system

### Scheduler Types

```rust
// Normal scheduler (default) - must complete in <1ms
#[rustler::nif]
fn fast_operation(x: i64) -> i64 {
    x * 2
}

// DirtyCpu - for CPU-bound work (1ms - 100ms+)
#[rustler::nif(schedule = "DirtyCpu")]
fn heavy_computation(data: Vec<i64>) -> i64 {
    data.iter().map(|x| expensive_calc(*x)).sum()
}

// DirtyIo - for I/O-bound work (file, network)
#[rustler::nif(schedule = "DirtyIo")]
fn read_file(path: String) -> Result<Vec<u8>, String> {
    std::fs::read(&path).map_err(|e| e.to_string())
}
```

## 7. Error Handling Patterns

### Returning {:ok, value} / {:error, reason}
```rust
// Result<T, E> automatically converts to {:ok, T} / {:error, E}
#[rustler::nif]
fn safe_divide(a: f64, b: f64) -> Result<f64, String> {
    if b == 0.0 {
        Err("division by zero".to_string())
    } else {
        Ok(a / b)
    }
}
// Elixir: {:ok, 5.0} or {:error, "division by zero"}
```

### Custom Atom Errors
```rust
#[rustler::nif]
fn find_user(id: i32) -> Result<User, Atom> {
    match lookup_user(id) {
        Some(user) => Ok(user),
        None => Err(atoms::not_found()),
    }
}
// Elixir: {:ok, %User{}} or {:error, :not_found}
```

### Error Propagation with thiserror
```rust
// Add to Cargo.toml: thiserror = "2.0"
use thiserror::Error;

#[derive(Error, Debug)]
enum NifError {
    #[error("Parse error: {0}")]
    Parse(#[from] std::num::ParseIntError),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Lock contention")]
    LockFail,

    #[error("Not found: {0}")]
    NotFound(String),
}

// Convert custom errors to Rustler errors
impl From<NifError> for rustler::Error {
    fn from(e: NifError) -> Self {
        rustler::Error::Term(Box::new(e.to_string()))
    }
}

#[rustler::nif]
fn complex_operation(input: String) -> Result<i64, NifError> {
    let value: i64 = input.parse()?;  // ? works with #[from]!

    if value < 0 {
        return Err(NifError::NotFound(input));
    }

    Ok(value * 2)
}
```

### Option Handling Patterns
```rust
// Convert Option to Result (avoid unwrap!)
#[rustler::nif]
fn find_item(data: Vec<i64>, target: i64) -> Result<i64, Atom> {
    data.iter()
        .find(|&&x| x == target)
        .copied()
        .ok_or(atoms::not_found())
}

// Safe defaults with unwrap_or
#[rustler::nif]
fn get_or_default(data: Vec<i64>, index: usize) -> i64 {
    data.get(index).copied().unwrap_or(-1)
}
```

## 8. OTP Integration - Env and LocalPid

### Sending Messages
```rust
#[rustler::nif]
fn notify<'a>(env: Env<'a>, pid: LocalPid, message: Term<'a>) -> Atom {
    match env.send(&pid, message) {
        Ok(()) => atoms::ok(),
        Err(_) => atoms::error(),
    }
}
```

### OwnedEnv for Async Operations

`OwnedEnv` allows sending messages from threads NOT managed by the BEAM.

```rust
use rustler::env::OwnedEnv;
use std::thread;

#[rustler::nif]
fn async_work<'a>(env: Env<'a>, data: String) -> Atom {
    let pid = env.pid();  // Capture caller's PID

    thread::spawn(move || {
        let result = expensive_computation(&data);

        let mut msg_env = OwnedEnv::new();
        let _ = msg_env.send_and_clear(&pid, |env| {
            (atoms::result(), result).encode(env)
        });
    });

    atoms::ok()  // Return immediately
}
```

**Critical:** `send_and_clear()` **PANICS** if called from a BEAM-managed thread. Only use from `std::thread::spawn`.

## 9. ResourceArc for State Management

For Rust state that persists across NIF calls:

```rust
use rustler::ResourceArc;
use parking_lot::Mutex;

struct Connection {
    data: Mutex<Vec<String>>,
}

#[rustler::resource_impl]
impl rustler::Resource for Connection {}

#[rustler::nif]
fn create_connection() -> ResourceArc<Connection> {
    ResourceArc::new(Connection {
        data: Mutex::new(Vec::new()),
    })
}

#[rustler::nif]
fn add_item(conn: ResourceArc<Connection>, item: String) -> Result<bool, Atom> {
    match conn.data.try_lock() {
        Some(mut data) => {
            data.push(item);
            Ok(true)
        }
        None => Err(atoms::lock_fail())
    }
}

#[rustler::nif]
fn get_items(conn: ResourceArc<Connection>) -> Result<Vec<String>, Atom> {
    match conn.data.try_lock() {
        Some(data) => Ok(data.clone()),
        None => Err(atoms::lock_fail())
    }
}
```

### MutexGuard Lifetime Management

Critical pattern to avoid holding locks during expensive operations:

```rust
// BAD: MutexGuard held too long
#[rustler::nif]
fn bad_long_lock(res: ResourceArc<MyRes>) -> i64 {
    let guard = res.data.lock().unwrap();
    let value = *guard;
    expensive_computation();  // Guard still held - blocks other NIFs!
    value
}

// GOOD: Drop guard before expensive work (scoped)
#[rustler::nif]
fn good_scoped_lock(res: ResourceArc<MyRes>) -> i64 {
    let value = {
        let guard = res.data.lock().unwrap();
        *guard
    }; // Guard dropped here

    expensive_computation();  // Lock free, other NIFs can proceed
    value
}
```

### RwLock for Read-Heavy Workloads

```rust
use parking_lot::RwLock;

struct DataFrame {
    data: RwLock<Vec<Vec<f64>>>,
}

#[rustler::resource_impl]
impl rustler::Resource for DataFrame {}

#[rustler::nif]
fn read_column(df: ResourceArc<DataFrame>, col: usize) -> Result<Vec<f64>, Atom> {
    // Multiple NIFs can read simultaneously
    let guard = df.data.try_read().ok_or(atoms::lock_fail())?;
    guard.get(col).cloned().ok_or(atoms::not_found())
}

#[rustler::nif]
fn add_column(df: ResourceArc<DataFrame>, data: Vec<f64>) -> Result<usize, Atom> {
    // Write blocks all readers (exclusive access)
    let mut guard = df.data.try_write().ok_or(atoms::lock_fail())?;
    guard.push(data);
    Ok(guard.len())  // Return meaningful value, not {:ok, :ok}
}
```

## 10. Common Pitfalls & Anti-Patterns

### Double-Wrapping {:ok, :ok} Tuples

The most common Rustler gotcha. `Result<T, E>` auto-wraps in `{:ok, T}` / `{:error, E}`. If `T` is itself `:ok`, you get `{:ok, :ok}`.

```rust
// BAD - returns {:ok, :ok} in Elixir, requires awkward pattern matching
#[rustler::nif]
fn insert(set: ResourceArc<Set>, val: i64) -> Result<Atom, Atom> {
    match set.data.try_lock() {
        Some(mut data) => {
            data.push(val);
            Ok(atoms::ok())  // Elixir sees {:ok, :ok}
        }
        None => Err(atoms::lock_fail()),
    }
}

// GOOD - return a meaningful value
#[rustler::nif]
fn insert(set: ResourceArc<Set>, val: i64) -> Result<usize, Atom> {
    match set.data.try_lock() {
        Some(mut data) => {
            data.push(val);
            Ok(data.len())  // Elixir sees {:ok, 5}
        }
        None => Err(atoms::lock_fail()),
    }
}

// GOOD - if truly void, separate the error path
#[rustler::nif]
fn insert(set: ResourceArc<Set>, val: i64) -> Atom {
    if let Some(mut data) = set.data.try_lock() {
        data.push(val);
        atoms::ok()       // Elixir sees :ok
    } else {
        atoms::lock_fail() // Elixir sees :lock_fail
    }
}
```

**Elixir workaround** when you can't change the NIF:
```elixir
def insert(set, value) do
  case nif_insert(set, value) do
    {:ok, :ok} -> :ok
    {:error, reason} -> {:error, reason}
  end
end
```

**Rule of thumb:** Ask yourself what the Elixir caller actually wants to pattern match on. Design the return type to make that natural.

### Blocking the Scheduler
```rust
// BAD - blocks scheduler for 5 seconds!
#[rustler::nif]
fn bad_sleep() {
    std::thread::sleep(std::time::Duration::from_secs(5));
}

// GOOD - use dirty scheduler
#[rustler::nif(schedule = "DirtyIo")]
fn good_sleep() {
    std::thread::sleep(std::time::Duration::from_secs(5));
}
```

### Panicking
```rust
// BAD - crashes entire BEAM VM!
#[rustler::nif]
fn bad_unwrap(input: Option<i32>) -> i32 {
    input.unwrap()  // Panics on None!
}

// GOOD - return Result
#[rustler::nif]
fn good_unwrap(input: Option<i32>) -> Result<i32, Atom> {
    input.ok_or(atoms::not_found())
}
```

### Deadlock with lock()
```rust
// BAD - can deadlock
#[rustler::nif]
fn bad_lock(res: ResourceArc<MyRes>) -> i32 {
    let data = res.data.lock().unwrap();  // Blocks forever if locked!
    *data
}

// GOOD - use try_lock
#[rustler::nif]
fn good_lock(res: ResourceArc<MyRes>) -> Result<i32, Atom> {
    match res.data.try_lock() {
        Some(data) => Ok(*data),
        None => Err(atoms::lock_fail()),
    }
}
```

### NifMap Requires ALL Keys Present
```rust
#[derive(NifMap)]
struct Opts {
    color_mode: Option<ColorMode>,
    filter_speckle: Option<i32>,
}
```
```elixir
# BAD - missing keys cause ArgumentError even though Rust fields are Option<T>
MyNif.call(%{color_mode: :binary})

# GOOD - wrap NIF to fill missing keys with nil
@all_keys [:color_mode, :filter_speckle]
def call(opts \\ %{}) do
  full_opts = Map.merge(Map.new(@all_keys, &{&1, nil}), opts)
  nif_call(full_opts)
end
```

### Missing @spec on NIF Bindings

NIF stubs are the boundary between Rust and Elixir type systems — they are the most important functions to type.

```elixir
# BAD - no @spec, caller has no idea what types the NIF expects or returns
defmodule MyApp.Stats do
  use Rustler, otp_app: :my_app, crate: "stats_nif"

  def compute(_matrix, _window, _pairs), do: :erlang.nif_error(:nif_not_loaded)
  def normalize(_values, _range), do: :erlang.nif_error(:nif_not_loaded)
end

# GOOD - @spec on every NIF, shared @type for recurring patterns
defmodule MyApp.Stats do
  use Rustler, otp_app: :my_app, crate: "stats_nif"

  @type point :: {float(), float()}

  @spec compute(
          [[float()]],
          non_neg_integer(),
          [point()]
        ) :: {:ok, map()} | {:error, String.t()}
  def compute(_matrix, _window, _points), do: :erlang.nif_error(:nif_not_loaded)

  @spec normalize([float()], {float(), float()}) :: {:ok, [float()]} | {:error, String.t()}
  def normalize(_values, _range), do: :erlang.nif_error(:nif_not_loaded)
end
```

**Why this matters:**
- Dialyzer catches type mismatches at the NIF boundary before runtime
- Editors show parameter types on hover — critical when the Rust side expects specific numeric types
- When multiple NIFs share complex argument types (like `{float(), float()}` for coordinate pairs), a `@type` alias keeps specs readable and consistent

### Inefficient String Conversion
```rust
// BAD - copies data
#[rustler::nif]
fn bad_binary(data: String) -> Vec<u8> {
    data.into_bytes()
}

// GOOD - zero-copy with Binary
#[rustler::nif]
fn good_binary(data: Binary) -> usize {
    data.as_slice().len()  // No copy!
}
```

## 11. Resource Monitoring

Monitor Elixir processes and react when they die:

```rust
use rustler::resource::Monitor;
use parking_lot::Mutex;

struct Session {
    data: Mutex<Vec<String>>,
}

#[rustler::resource_impl]
impl rustler::Resource for Session {
    // No manual IMPLEMENTS_DOWN needed — the macro detects `down` and sets it automatically

    fn down<'a>(&'a self, _env: Env<'a>, pid: LocalPid, _mon: Monitor) {
        println!("Process {:?} died, cleaning up...", pid);
        if let Ok(mut data) = self.data.lock() {
            data.clear();
        }
    }
}

#[rustler::nif]
fn monitor_caller(env: Env, session: ResourceArc<Session>) -> bool {
    let pid = env.pid();
    env.monitor(&session, &pid).is_some()
}
```

## 12. Testing NIFs

### Rust Unit Tests
For non-NIF logic, use standard Rust tests:
```rust
fn internal_compute(data: &[i64]) -> i64 {
    data.iter().sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compute() {
        assert_eq!(internal_compute(&[1, 2, 3]), 6);
    }
}
```

### Elixir Integration Tests
```elixir
defmodule MyNifTest do
  use ExUnit.Case

  test "add returns correct sum" do
    assert MyApp.Native.add(2, 3) == 5
  end

  test "safe_divide handles zero" do
    assert {:error, "division by zero"} = MyApp.Native.safe_divide(1.0, 0.0)
  end

  test "async operation sends message" do
    MyApp.Native.async_work("test")
    assert_receive {:result, _}, 5000
  end
end
```

### Benchmarking with Benchee
```elixir
Mix.install([{:benchee, "~> 1.3"}])

data = Enum.to_list(1..10_000)

Benchee.run(%{
  "Elixir Enum.sum" => fn -> Enum.sum(data) end,
  "NIF sum" => fn -> MyApp.Native.sum_list(data) end
})
```

**Note:** Build with `MIX_ENV=prod mix compile` for accurate benchmarks.

## 13. Precompiled NIFs

Distribute without requiring Rust on user machines:

```elixir
# mix.exs
defp deps do
  [
    {:rustler, "~> 0.37.2", runtime: false},
    {:rustler_precompiled, "~> 0.8"}
  ]
end
```

```elixir
defmodule MyApp.Native do
  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :my_app,
    crate: "my_nif",
    base_url: "https://github.com/user/repo/releases/download/v#{version}",
    version: version,
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
      aarch64-unknown-linux-gnu
      x86_64-pc-windows-msvc
    )

  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
end
```

## 14. API-First NIF Design

Design your NIF interface first by writing how you WANT to use it:

### Step 1: Design the Elixir Interface
```elixir
defmodule MyApp.ImageProcessor do
  def process(image_data, opts \\ []) do
    Native.process_image(image_data, opts)
  end
end
```

### Step 2: Write the NIF Signature to Match
```rust
#[rustler::nif(schedule = "DirtyCpu")]
fn process_image(data: Binary, opts: ProcessOptions) -> Result<Vec<u8>, NifError> {
    // Implementation follows the designed interface
}
```

### Step 3: Write Tests That Use the Interface
```rust
#[test]
fn process_image_returns_expected_result() {
    let input = load_test_image();
    let opts = ProcessOptions::default();
    let result = process_image_internal(&input, &opts).unwrap();
    assert!(result.len() > 0);
}
```

## 15. Advanced Patterns Index

> **Full implementations:** See [examples.md](examples.md) for complete working examples

| Pattern | Purpose | examples.md |
|---------|---------|-------------|
| **Builder Pattern** | Complex config with fluent API and validation | §35 |
| **State Pattern** | Type-state or enum-based state machines | §36 |
| **Default Trait** | Sensible defaults with `unwrap_or_default()` | §41 |
| **VecDeque Ring Buffer** | Circular buffers for sliding windows | §22 |
| **Slab Handle Pool** | O(1) handle allocation/lookup (Discord pattern) | §23 |
| **Custom Iterators** | Chunked data streaming from NIF resources | §27 |
| **Custom Error Types** | thiserror-based errors with atom conversion | §32 |
| **Drop Trait** | Resource cleanup on GC | §13 |
| **RAII Guards** | Automatic transaction rollback on error/panic | §37 |
| **Rayon Parallelism** | `par_iter()`, `par_chunks()`, work-stealing | §16 |
| **OnceCell/Lazy** | Global lazy statics for expensive init | §21 |
| **Bitflags** | C-compatible flag operations | §26 |
| **Binary Protocol** | byteorder for endianness-aware parsing | §24 |
| **Compression** | gzip/zstd with flate2 crate | §25, §40 |
| **Atomic Operations** | Lock-free counters, compare-and-swap | §38 |
| **Newtype Pattern** | Domain type wrappers preventing argument swapping | §34 |
| **Provider Abstraction** | Testable HTTP clients with injectable base URLs | §29 |
| **Testable NIFs** | Split NIF wrapper from internal logic | §30 |
| **JSON Pointer** | Nested JSON extraction | §31 |
| **with_context** | Rich error messages with anyhow context chains | §32 |
| **Time Measurement** | NIF profiling with AtomicU64 metrics tracking | §33 |
| **Round-Trip Testing** | Verify encode/decode consistency | §40 |
| **Network/I/O Patterns** | Tokio runtime integration, blocking fetch | §39 |

**Quick Reference - Atomic Ordering:**

| Ordering | Use Case |
|----------|----------|
| `Relaxed` | Counters, statistics (no synchronization) |
| `Acquire` | Reading shared data (pairs with Release) |
| `Release` | Writing shared data (pairs with Acquire) |
| `SeqCst` | When uncertain, or for CAS operations |

## Navigation

- **[reference.md](reference.md)** — Cargo.toml templates, complete type mapping tables, Env/OwnedEnv/Resource API reference, derive macro quick reference, lock patterns, thread patterns, data structure selection guide
- **[examples.md](examples.md)** — 43 complete working examples from basic arithmetic to production patterns (sorted sets, monitoring, streaming iterators, Tokio integration, compression, state machines)
- **[advanced.md](advanced.md)** — FFI fundamentals (CString, repr(C), raw pointers, linking), advanced threading (closure traits, scoped threads, channel pipelines, thread builders), module organization for large NIFs, string optimization, manual Term encoding (Encoder trait, keyword lists, dynamic maps), CI/CD for precompiled NIFs (GitHub Actions workflow)

## Related Skills

- **[rust-programming](../rust-programming/SKILL.md)** — General Rust patterns (ownership, traits, async/await, error handling, macros). Key: use `thiserror` for library errors, `anyhow` for application errors; prefer `impl Into<String>` over `String` parameters for ergonomic APIs.
- **[elixir](../elixir/SKILL.md)** — Elixir language fundamentals and OTP. Key: prefer `with` chains for multi-step operations, use ok/error tuples not exceptions for expected failures. **Integration:** When your NIF library uses Registry-based process management, callers MUST use your `via()` helper to address processes — raw atom names won't resolve (see elixir skill Rule 14). Document your library's process discovery mechanism.
- **[c-programming](../c-programming/SKILL.md)** — C programming for FFI/embedded. Key: always use `#[repr(C)]` for structs passed across FFI boundaries; never use default Rust repr for C interop.

## Consuming NIF Libraries in Phoenix/Elixir Apps

When a NIF library has its own OTP supervision tree (Registry, DynamicSupervisor, GenServers):

1. **Application ordering** — The NIF library's application must start before your processes. Ensure it's in `deps` (automatic) or `extra_applications` (manual).
2. **Process naming** — If the library registers processes via `{:via, Registry, ...}`, you MUST use the same via tuple to call them. Use the library's `via()` helper — never raw atom names.
3. **Initialization dependencies** — If your GenServer's `handle_continue` calls into the library, use `:rest_for_one` supervision or ensure the library's tree is fully started.
4. **Timeouts** — Cross-GenServer calls during initialization may need longer than the default 5000ms `GenServer.call` timeout. Use explicit timeouts for library operations during startup.
