# Rustler Quick Reference

## 1. Cargo.toml Template

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

# Error handling
thiserror = "2.0"

# Faster synchronization primitives
parking_lot = "0.12"

# Parallel processing
rayon = "1.10"

# Serialization (optional)
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

# Async runtime (for network NIFs)
# tokio = { version = "1.0", features = ["rt-multi-thread", "macros"] }

# HTTP client (use blocking for DirtyIo, async for Tokio)
# reqwest = { version = "0.11", features = ["blocking", "json"] }

# Command timeout (for system command execution)
# wait-timeout = "0.2"

# Optional NIF features
# rustler = { version = "0.37.2", features = ["serde", "nif_version_2_16"] }

# Performance allocators (pick one)
# [target.'cfg(not(target_env = "musl"))'.dependencies]
# mimalloc = "0.1"
# jemallocator = "0.5"

[profile.release]
lto = true
codegen-units = 1
```

## 2. Rustler Attributes

### NIF Function Attributes
```rust
// Basic NIF
#[rustler::nif]
fn my_function() -> i64 { 42 }

// With dirty CPU scheduler (for CPU-bound work >1ms)
#[rustler::nif(schedule = "DirtyCpu")]
fn cpu_heavy() -> i64 { /* ... */ }

// With dirty I/O scheduler (for I/O-bound work)
#[rustler::nif(schedule = "DirtyIo")]
fn io_heavy() -> i64 { /* ... */ }

// Custom name in Elixir
#[rustler::nif(name = "elixir_name")]
fn rust_name() -> i64 { 42 }
```

### Resource Implementation
```rust
#[rustler::resource_impl]
impl rustler::Resource for MyResource {}
```

### Module Initialization
```rust
rustler::init!("Elixir.MyApp.Native");

// With load function
rustler::init!("Elixir.MyApp.Native", load = on_load);

fn on_load(env: Env, _info: Term) -> bool {
    true
}
```

## 3. Derive Macros Quick Reference

| Macro | Elixir Type | Rust Type | Example |
|-------|-------------|-----------|---------|
| `NifStruct` | `%Module{}` | named struct | `%User{name: ""}` |
| `NifMap` | `%{}` | named struct | `%{key: value}` |
| `NifTuple` | `{a, b}` | tuple struct | `{1, 2}` |
| `NifRecord` | `{:tag, ...}` | tagged struct | `{:point, 1, 2}` |
| `NifTaggedEnum` | `:atom \| {:tag, val}` | enum | `:ok \| {:error, msg}` |
| `NifUnitEnum` | `:atom` | unit enum | `:red \| :green` |
| `NifUntaggedEnum` | varies | enum | multiple representations |
| `NifException` | exception | struct | raises in Elixir |

### Derive Examples
```rust
#[derive(rustler::NifStruct)]
#[module = "MyApp.User"]
struct User { name: String, age: i32 }

#[derive(rustler::NifMap)]
struct Config { host: String, port: i32 }
// ⚠ NifMap requires ALL keys present — see §3.1 below

#[derive(rustler::NifTuple)]
struct Point(i32, i32);

#[derive(rustler::NifRecord)]
#[tag = "point"]
struct RecordPoint { x: i32, y: i32 }

#[derive(rustler::NifTaggedEnum)]
enum Result { Ok(i32), Error(String) }

#[derive(rustler::NifUnitEnum)]
enum Color { Red, Green, Blue }

#[derive(rustler::NifException)]
#[module = "MyApp.Error"]
struct MyError { message: String }
```

### 3.1 NifMap Requires ALL Keys Present

**Critical gotcha:** `#[derive(NifMap)]` requires the Elixir map to contain **every** key declared in the Rust struct, even if the Rust fields are `Option<T>`. Passing a partial map (missing keys) causes `ArgumentError` at the NIF boundary.

```rust
#[derive(NifMap)]
struct Opts {
    color_mode: Option<ColorMode>,
    filter_speckle: Option<i32>,
    // ... more Option fields
}
```

```elixir
# FAILS - missing keys cause ArgumentError
MyNif.convert(data, %{color_mode: :binary, filter_speckle: 4})

# WORKS - all keys present, missing ones set to nil
MyNif.convert(data, %{color_mode: :binary, filter_speckle: 4,
  other_key: nil, another_key: nil, ...})
```

**Solution:** Wrap the NIF call in an Elixir function that fills missing keys with `nil`:

```elixir
@all_keys [:color_mode, :filter_speckle, :other_key, :another_key]

def convert(data, opts \\ %{}) do
  # NifMap requires all keys present — fill missing with nil
  full_opts = Map.merge(Map.new(@all_keys, &{&1, nil}), opts)
  nif_convert(data, full_opts)
end

defp nif_convert(_data, _opts), do: :erlang.nif_error(:nif_not_loaded)
```

This does **not** apply to `NifStruct` (which uses `%Module{}` and handles defaults differently). Only `NifMap` has this requirement because it decodes from plain Elixir maps where missing keys are indistinguishable from intentionally absent keys.

## 4. Type Mapping Complete Table

### Numeric Types
| Elixir | Rust |
|--------|------|
| `integer` | `i8`, `i16`, `i32`, `i64`, `i128`, `isize` |
| `integer` | `u8`, `u16`, `u32`, `u64`, `u128`, `usize` |
| `float` | `f32`, `f64` |

### String/Binary Types
| Elixir | Rust | Notes |
|--------|------|-------|
| `String.t()` | `String` | Heap allocated, owned |
| `String.t()` | `&str` | Borrowed (lifetime) |
| `binary` | `Binary` | Zero-copy view |
| `binary` | `OwnedBinary` | Owned binary |
| `binary` | `Vec<u8>` | Copied to Vec |
| `binary` | `NewBinary` | For creating binaries |

### Collection Types
| Elixir | Rust | Notes |
|--------|------|-------|
| `list` | `Vec<T>` | Copied to Vec |
| `list` | `ListIterator<T>` | Lazy iteration |
| `map` | `HashMap<K,V>` | Copied |
| `map` | struct + `NifMap` | Named fields |
| `tuple` | `(A, B, C)` | Direct tuple |
| `tuple` | struct + `NifTuple` | Named tuple struct |

### Special Types
| Elixir | Rust | Notes |
|--------|------|-------|
| `atom` | `Atom` | Interned string |
| `nil` | `()` | Unit type |
| `nil` | `Option::None` | With Option wrapper |
| `pid` | `LocalPid` | Process identifier |
| `reference` | `Reference` | Unique reference |
| `any` | `Term` | Raw term (manual handling) |

### Option Handling
| Elixir | Rust |
|--------|------|
| `value \| nil` | `Option<T>` |
| `nil` | `None` |
| `value` | `Some(value)` |

## 5. Atoms Macro

```rust
mod atoms {
    rustler::atoms! {
        // Standard atoms
        ok,
        error,
        nil,
        true_ = "true",    // Reserved word
        false_ = "false",  // Reserved word

        // Custom atoms
        not_found,
        invalid_input,
        lock_fail,
        timeout,

        // With explicit string
        my_atom = "my-atom",
    }
}

// Usage
use atoms::*;

fn example() -> Atom {
    ok()
}

fn return_error() -> Result<i32, Atom> {
    Err(not_found())
}
```

## 6. Env Methods Reference

```rust
use rustler::{Env, LocalPid, Term};

// Get caller's process ID
env.pid() -> LocalPid

// Check if process is alive
env.is_process_alive(pid: LocalPid) -> bool

// Find process by registered name or PID
env.whereis_pid(name_or_pid: Term) -> Option<LocalPid>

// Send message to process
env.send(pid: &LocalPid, message: impl Encoder) -> Result<(), SendError>

// Create error tuple {:error, reason}
env.error_tuple(reason: impl Encoder) -> Term

// Decode binary using External Term Format
env.binary_to_term(data: &[u8]) -> Option<(Term, usize)>

// Monitor a resource's owning process
env.monitor<T: Resource>(resource: &ResourceArc<T>, pid: &LocalPid) -> Option<Monitor>

// Remove monitor
env.demonitor<T: Resource>(resource: &ResourceArc<T>, mon: &Monitor) -> bool

// Register resource type (usually in load function)
env.register::<T: Resource>() -> Result<(), ResourceInitError>
```

## 7. OwnedEnv Methods Reference

```rust
use rustler::env::OwnedEnv;

// Create new process-independent environment
OwnedEnv::new() -> OwnedEnv

// Run code with access to environment
owned_env.run<F, R>(f: F) -> R
where F: FnOnce(Env) -> R

// Send message to process and clear environment
// PANICS if called from BEAM-managed thread!
owned_env.send_and_clear<F>(pid: &LocalPid, f: F) -> Result<(), SendError>
where F: FnOnce(Env) -> Term

// Save term for use across run() calls or threads
owned_env.save(term: Term) -> SavedTerm

// Load saved term (within run() callback)
saved_term.load(env: Env) -> Term

// Clear all terms (invalidates SavedTerms!)
owned_env.clear()
```

### OwnedEnv Usage Pattern
```rust
use std::thread;

fn async_example(caller_pid: LocalPid) {
    thread::spawn(move || {
        let mut env = OwnedEnv::new();

        // Build and send message
        let _ = env.send_and_clear(&caller_pid, |env| {
            (atoms::result(), 42).encode(env)
        });
    });
}
```

## 8. Resource Trait Reference

```rust
use rustler::{Env, LocalPid};
use rustler::resource::Monitor;

// The #[rustler::resource_impl] macro MUST go on the impl Resource block.
// It auto-generates IMPLEMENTS_* constants by detecting which callback functions are present.
#[rustler::resource_impl]
impl rustler::Resource for MyResource {
    // Called before resource is deallocated
    // Useful when cleanup needs Env (e.g., sending messages)
    fn destructor(self, env: Env) {
        // Cleanup code
    }

    // Called when a monitored process dies
    fn down<'a>(&'a self, env: Env<'a>, pid: LocalPid, mon: Monitor) {
        // Handle process death
    }

    // For dynamic invocation (advanced)
    fn dyncall<'a>(&'a self, env: Env<'a>, call_data: *mut c_void) {
        // Handle dynamic call
    }
}
```

## 9. Error Types Reference

```rust
use rustler::{Error, NifResult, Atom};

// NifResult is an alias
type NifResult<T> = Result<T, Error>;

// Error variants
Error::BadArg                      // Bad argument error
Error::Term(Box<dyn Encoder>)      // Custom term as error
Error::Atom(Atom)                  // Atom as error
Error::RaiseAtom(Atom)            // Raise as exception
Error::RaiseTerm(Box<dyn Encoder>) // Raise term as exception

// Usage examples
fn example1() -> NifResult<i32> {
    Err(Error::BadArg)
}

fn example2() -> NifResult<i32> {
    Err(Error::Term(Box::new("custom error message")))
}

fn example3() -> NifResult<i32> {
    Err(Error::Atom(atoms::not_found()))
}

// Simpler: just use Result with automatic conversion
fn example4() -> Result<i32, String> {
    Err("error message".to_string())
}
// Returns {:error, "error message"} in Elixir

fn example5() -> Result<i32, Atom> {
    Err(atoms::not_found())
}
// Returns {:error, :not_found} in Elixir
```

## 10. Common Cargo Commands

```bash
# Navigate to NIF directory
cd native/my_nif

# Build (development)
cargo build

# Build (release/optimized)
cargo build --release

# Run tests
cargo test

# Run tests with output
cargo test -- --nocapture

# Lint code
cargo clippy

# Format code
cargo fmt

# Check without building
cargo check

# Update dependencies
cargo update

# Show dependency tree
cargo tree

# Clean build artifacts
cargo clean

# Build docs
cargo doc --open
```

## 11. Elixir Module Template

### Basic Template
```elixir
defmodule MyApp.Native do
  use Rustler,
    otp_app: :my_app,
    crate: "my_nif"

  # NIF functions with fallbacks
  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def multiply(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
end
```

### With Load Data
```elixir
defmodule MyApp.Native do
  use Rustler,
    otp_app: :my_app,
    crate: "my_nif",
    load_data: %{config: "value"}

  def init(_config), do: :erlang.nif_error(:nif_not_loaded)
end
```

### With Skip Compilation (for precompiled)
```elixir
defmodule MyApp.Native do
  use Rustler,
    otp_app: :my_app,
    crate: "my_nif",
    skip_compilation?: true

  def function(_arg), do: :erlang.nif_error(:nif_not_loaded)
end
```

### Precompiled Template
```elixir
defmodule MyApp.Native do
  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :my_app,
    crate: "my_nif",
    base_url: "https://github.com/user/repo/releases/download/v#{version}",
    version: version,
    force_build: System.get_env("FORCE_BUILD") == "true",
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
      aarch64-unknown-linux-gnu
      x86_64-pc-windows-msvc
    )

  def function(_arg), do: :erlang.nif_error(:nif_not_loaded)
end
```

## 12. Mix Commands

```bash
# Generate new NIF
mix rustler.new
# Prompts for module name and NIF name

# Compile project (includes NIF)
mix compile

# Force recompile NIF
mix compile --force

# Run tests
mix test

# Run specific test file
mix test test/my_nif_test.exs

# Run with verbose output
mix test --trace

# Interactive shell with NIF loaded
iex -S mix

# Release build
MIX_ENV=prod mix compile

# Clean build artifacts
mix clean

# Get dependencies
mix deps.get

# Update dependencies
mix deps.update --all
```

### Environment Variables
```bash
# Force local build (skip precompiled)
EXPLORER_BUILD=1 mix compile
RUSTLER_PRECOMPILATION_FORCE_BUILD=1 mix compile

# Enable debug output
RUST_BACKTRACE=1 mix test

# Optimize NIF
RUSTFLAGS="-C target-cpu=native" mix compile
```

## 13. Smart Pointer Decision Tree

```
Need shared ownership across threads?
├── Yes → Arc<T> (or ResourceArc for NIF resources)
│   └── Need interior mutability?
│       ├── Read-heavy → Arc<RwLock<T>>
│       └── Write-heavy → Arc<Mutex<T>>
└── No → Box<T> for heap allocation

Need interior mutability?
├── Single thread only
│   ├── Copy types → Cell<T>
│   └── Non-Copy types → RefCell<T>
└── Multi-threaded (NIF resources)
    ├── Read-heavy → RwLock<T>
    ├── Write-heavy → Mutex<T>
    └── Simple counters → AtomicU64, AtomicI64

Lazy initialization needed?
├── Single thread → OnceCell<T>
└── Multi-thread → once_cell::sync::OnceCell<T>
```

## 14. Lifetime Cheat Sheet

```rust
// 'a - tied to Env lifetime (NIF call duration)
fn example<'a>(env: Env<'a>) -> Term<'a> { ... }

// 'static - lives forever (required for spawned threads)
thread::spawn(move || ...)  // Closure must be 'static

// Why? The thread might outlive the caller
pub fn spawn<F, T>(f: F) -> JoinHandle<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,

// Scoped threads relax 'static requirement
thread::scope(|s| {
    s.spawn(|| /* can borrow local data */)
});  // Threads joined before scope exits
```

### Common Lifetime Patterns

| Pattern | Use Case | Example |
|---------|----------|---------|
| `'a` on Env | NIF return types | `fn nif<'a>(env: Env<'a>) -> Term<'a>` |
| `'static` | Thread closures | `thread::spawn(move \|\| ...)` |
| Elided | Simple functions | `fn process(s: &str) -> usize` |
| Owned types | Crossing thread boundaries | `String` instead of `&str` |

## 15. Error Handling Quick Reference

```rust
// Option → Result conversion
let value = option.ok_or(atoms::not_found())?;

// Result mapping
let parsed = input.parse::<i64>()
    .map_err(|_| atoms::invalid_input())?;

// Safe defaults
let value = option.unwrap_or(default);
let value = option.unwrap_or_else(|| compute_default());

// Chaining
let result = first_try()
    .or_else(|_| second_try())
    .map(|v| v * 2)?;

// thiserror integration
#[derive(thiserror::Error, Debug)]
enum NifError {
    #[error("Parse error: {0}")]
    Parse(#[from] std::num::ParseIntError),
}
```

## 16. Scheduler Selection Quick Reference

| Operation Time | Scheduler | Attribute |
|----------------|-----------|-----------|
| < 1ms | Normal | `#[rustler::nif]` |
| 1-100ms CPU | DirtyCpu | `#[rustler::nif(schedule = "DirtyCpu")]` |
| Any I/O | DirtyIo | `#[rustler::nif(schedule = "DirtyIo")]` |
| > 100ms | Consider async | `thread::spawn` + OwnedEnv |

## 17. Lock Pattern Quick Reference

```rust
// PREFER: Non-blocking with try_lock
match resource.data.try_lock() {
    Some(guard) => Ok(process(&guard)),
    None => Err(atoms::lock_fail()),
}

// AVOID: Blocking lock (can deadlock)
let guard = resource.data.lock().unwrap();  // DON'T

// Short lock scope (drop before expensive work)
let value = {
    let guard = resource.data.lock().unwrap();
    guard.clone()
};  // Guard dropped
expensive_work(value);  // Lock free

// Explicit drop
let guard = resource.data.lock().unwrap();
let value = guard.clone();
drop(guard);  // Release early
expensive_work(value);
```

## 18. Thread Pattern Quick Reference

| Pattern | Use Case | Example |
|---------|----------|---------|
| `thread::spawn` | Fire-and-forget async | Background processing |
| `thread::scope` | Parallel within NIF | Chunked data processing |
| Channels (mpsc) | Multi-stage pipeline | Producer/consumer |
| `rustler::thread::spawn` | Auto-send result | Simple async ops |

## 19. Common Cargo.toml Dependencies

```toml
[dependencies]
rustler = "0.37.2"

# Error handling
thiserror = "2.0"

# Faster synchronization
parking_lot = "0.12"

# Lazy initialization
once_cell = "1.19"

# Parallel processing
rayon = "1.10"

# Serialization
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

# Data structures
slab = "0.4"           # Handle/connection pools
bitflags = "2.4"       # C-compatible flags

# Binary handling
byteorder = "1.5"      # Endianness

# Compression
flate2 = "1.0"         # gzip/deflate

# Regex (compile-time cached)
regex = "1.10"

# Network/Async (optional - for network NIFs)
# tokio = { version = "1.0", features = ["rt-multi-thread", "macros"] }
# reqwest = { version = "0.11", features = ["blocking", "json"] }
# wait-timeout = "0.2"  # Command timeouts

# Performance allocators (pick one, optional)
[target.'cfg(not(target_env = "musl"))'.dependencies]
mimalloc = "0.1"
# jemallocator = "0.5"

[profile.release]
lto = true
codegen-units = 1
opt-level = 3
```

## 20. Data Structure Selection Guide

| Need | Use | Why |
|------|-----|-----|
| Dynamic array | `Vec<T>` | Contiguous, cache-friendly |
| Queue/ring buffer | `VecDeque<T>` | O(1) push/pop both ends |
| Key-value lookup | `HashMap<K,V>` | O(1) average lookup |
| Unique elements | `HashSet<T>` | O(1) contains check |
| Handle pool | `Slab<T>` | O(1) insert/remove by key |
| Sorted data | `BTreeMap<K,V>` | O(log n) ordered ops |
| Bit flags | `bitflags!` | C-compatible, type-safe |

## 21. String Type Selection

| Type | Use When | Copy? |
|------|----------|-------|
| `String` | Need owned, mutable string | Yes |
| `&str` | Read-only, borrowed | No |
| `Binary` | Raw bytes from Elixir | No (zero-copy) |
| `Vec<u8>` | Need owned bytes | Yes |
| `&[u8]` | Borrowed bytes | No |

## 22. Collection Quick Patterns

### VecDeque (Ring Buffer)
```rust
use std::collections::VecDeque;

let mut buffer: VecDeque<i64> = VecDeque::with_capacity(100);
buffer.push_back(item);      // Add to end
buffer.push_front(item);     // Add to front
buffer.pop_front();          // Remove from front
buffer.pop_back();           // Remove from back
buffer.get(0);               // Access by index
```

### HashMap with Entry API
```rust
use std::collections::HashMap;

let mut map: HashMap<String, i64> = HashMap::new();
map.entry(key.clone())
    .and_modify(|v| *v += 1)
    .or_insert(1);
```

### Slab for Handle Management
```rust
use slab::Slab;

let mut slab = Slab::new();
let key = slab.insert(value);  // Returns handle
let val = slab.get(key);       // O(1) access
slab.remove(key);              // O(1) remove
```

## 23. Builder Pattern Template

```rust
pub struct Config {
    field1: String,
    field2: u32,
}

pub struct ConfigBuilder {
    field1: String,
    field2: u32,
}

impl ConfigBuilder {
    pub fn new() -> Self {
        Self { field1: "default".into(), field2: 0 }
    }
    pub fn field1(mut self, v: impl Into<String>) -> Self {
        self.field1 = v.into(); self
    }
    pub fn field2(mut self, v: u32) -> Self {
        self.field2 = v; self
    }
    pub fn build(self) -> Config {
        Config { field1: self.field1, field2: self.field2 }
    }
}
```

## 24. Drop Trait Pattern

```rust
impl Drop for MyResource {
    fn drop(&mut self) {
        // Cleanup code here
        // Called when ResourceArc ref count = 0
    }
}

// Force early drop
std::mem::drop(resource);
```

## 25. RAII Guard Pattern

```rust
struct Guard<'a> {
    resource: &'a Resource,
    committed: bool,
}

impl<'a> Guard<'a> {
    fn new(r: &'a Resource) -> Self {
        r.acquire();
        Self { resource: r, committed: false }
    }
    fn commit(mut self) {
        self.resource.finalize();
        self.committed = true;
    }
}

impl<'a> Drop for Guard<'a> {
    fn drop(&mut self) {
        if !self.committed {
            self.resource.rollback();
        }
    }
}
```

## 26. Rayon Parallel Patterns

```rust
use rayon::prelude::*;

// Parallel map
data.par_iter().map(|x| f(x)).collect()

// Parallel filter
data.par_iter().filter(|x| cond(x)).collect()

// Parallel reduce
data.par_iter().sum()
data.par_iter().reduce(|| init, |a, b| combine(a, b))

// Parallel sort
data.par_sort();
data.par_sort_by(|a, b| a.cmp(b));

// Parallel chunks
data.par_chunks(100).for_each(|chunk| process(chunk));

// Join two operations
rayon::join(|| op1(), || op2())
```

## 27. Lazy Initialization Patterns

```rust
// Global static (Lazy)
use once_cell::sync::Lazy;
static DATA: Lazy<Vec<i64>> = Lazy::new(|| expensive_init());

// Per-instance (OnceCell)
use once_cell::sync::OnceCell;
struct Res { cache: OnceCell<Data> }
res.cache.get_or_init(|| compute())
```

## 28. Binary Protocol Quick Reference

```rust
use byteorder::{BigEndian, LittleEndian, ReadBytesExt, WriteBytesExt};
use std::io::Cursor;

// Reading
let mut c = Cursor::new(data);
let val = c.read_u32::<BigEndian>()?;
let val = c.read_i16::<LittleEndian>()?;
let val = c.read_f64::<BigEndian>()?;

// Writing
let mut buf = Vec::new();
buf.write_u32::<BigEndian>(42)?;
buf.write_i16::<LittleEndian>(-1)?;
```

## 29. Compression Quick Reference

```rust
use flate2::{Compression, write::GzEncoder, read::GzDecoder};
use std::io::{Write, Read};

// Compress
let mut enc = GzEncoder::new(Vec::new(), Compression::default());
enc.write_all(&data)?;
let compressed = enc.finish()?;

// Decompress
let mut dec = GzDecoder::new(&compressed[..]);
let mut decompressed = Vec::new();
dec.read_to_end(&mut decompressed)?;
```

## 30. Bitflags Quick Reference

```rust
use bitflags::bitflags;

bitflags! {
    pub struct Flags: u32 {
        const A = 0b0001;
        const B = 0b0010;
        const C = 0b0100;
        const AB = Self::A.bits() | Self::B.bits();
    }
}

let f = Flags::A | Flags::B;
f.contains(Flags::A)  // true
f.bits()              // u32 value
Flags::from_bits_truncate(3)  // Flags::AB
```

## 31. Atomic Operations Quick Reference

```rust
use std::sync::atomic::{AtomicU64, AtomicBool, Ordering};

let counter = AtomicU64::new(0);
counter.fetch_add(1, Ordering::Relaxed);     // Increment
counter.load(Ordering::Relaxed);              // Read
counter.store(42, Ordering::Relaxed);         // Write
counter.compare_exchange(                     // CAS
    expected, new,
    Ordering::SeqCst, Ordering::Relaxed
);

let flag = AtomicBool::new(false);
flag.swap(true, Ordering::SeqCst);            // Set and get old
```

## 32. Custom Error Type Template

```rust
use thiserror::Error;

#[derive(Error, Debug)]
pub enum MyError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Not found: {0}")]
    NotFound(String),

    #[error("Validation: {field} - {msg}")]
    Validation { field: String, msg: String },
}

impl From<MyError> for rustler::Error {
    fn from(e: MyError) -> Self {
        rustler::Error::Term(Box::new(e.to_string()))
    }
}

## 33. JSON Pointer Extraction

```rust
use serde_json::Value;

// Extract nested values without defining intermediate structs
let val: Value = serde_json::from_str(json)?;

// Pointer syntax: /key/nested/array_index
let name = val.pointer("/user/profile/name")
    .and_then(Value::as_str)
    .ok_or(atoms::missing_name())?;

let age = val.pointer("/user/profile/age")
    .and_then(Value::as_i64)
    .ok_or(atoms::missing_age())?;

// Array access
let first = val.pointer("/items/0/id").and_then(Value::as_i64);

// Common extractors
Value::as_str(&self)    -> Option<&str>
Value::as_i64(&self)    -> Option<i64>
Value::as_f64(&self)    -> Option<f64>
Value::as_bool(&self)   -> Option<bool>
Value::as_array(&self)  -> Option<&Vec<Value>>
Value::as_object(&self) -> Option<&Map<String, Value>>
```

## 34. with_context Error Pattern

```rust
use anyhow::{Context, Result};

// Add context to errors
fn load_config(path: &str) -> Result<Config> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("Failed to read: {}", path))?;

    let config: Config = toml::from_str(&content)
        .with_context(|| format!("Invalid TOML in {}", path))?;

    Ok(config)
}

// NIF wrapper converts to string
#[rustler::nif(schedule = "DirtyIo")]
fn load_config_nif(path: String) -> Result<Config, String> {
    load_config(&path).map_err(|e| format!("{:#}", e))
}

// {:#} pretty prints error chain:
// "Invalid TOML in config.toml: expected '=' at line 5"
```

## 35. Time Measurement Pattern

```rust
use std::time::Instant;
use std::sync::atomic::{AtomicU64, Ordering};

// Global metrics
static CALL_COUNT: AtomicU64 = AtomicU64::new(0);
static TOTAL_NANOS: AtomicU64 = AtomicU64::new(0);

#[rustler::nif(schedule = "DirtyCpu")]
fn timed_process(data: Vec<i64>) -> Vec<i64> {
    let start = Instant::now();

    let result: Vec<i64> = data.iter().map(|x| x * x).collect();

    let elapsed = start.elapsed().as_nanos() as u64;
    CALL_COUNT.fetch_add(1, Ordering::Relaxed);
    TOTAL_NANOS.fetch_add(elapsed, Ordering::Relaxed);

    result
}

#[rustler::nif]
fn get_metrics() -> (u64, u64, f64) {
    let calls = CALL_COUNT.load(Ordering::Relaxed);
    let nanos = TOTAL_NANOS.load(Ordering::Relaxed);
    let avg_micros = if calls > 0 {
        (nanos as f64 / calls as f64) / 1000.0
    } else { 0.0 };
    (calls, nanos, avg_micros)
}

// Reset metrics
#[rustler::nif]
fn reset_metrics() -> Atom {
    CALL_COUNT.store(0, Ordering::Relaxed);
    TOTAL_NANOS.store(0, Ordering::Relaxed);
    atoms::ok()
}
```

## 36. Newtype Pattern Template

```rust
// Wrap primitive for type safety
pub struct UserId(i64);

impl UserId {
    pub fn new(id: i64) -> Result<Self, &'static str> {
        if id > 0 { Ok(Self(id)) }
        else { Err("UserId must be positive") }
    }

    pub fn as_i64(&self) -> i64 { self.0 }
}

// NIF with validation
#[rustler::nif]
fn get_user(id: i64) -> Result<User, Atom> {
    let user_id = UserId::new(id)
        .map_err(|_| atoms::invalid_id())?;
    fetch_user(user_id)
}

// Common newtypes for NIFs
pub struct ByteCount(usize);
pub struct Timestamp(i64);
pub struct Percentage(f64);  // Validate 0.0-100.0
pub struct NonEmptyString(String);
```

## 37. Provider Abstraction Template

```rust
// Provider encapsulates config, testable via field injection
pub struct DataProvider {
    pub base_url: String,  // Public for test overrides
    api_key: String,
}

impl DataProvider {
    pub fn new(api_key: &str) -> Self {
        Self {
            base_url: "https://api.example.com".into(),
            api_key: api_key.into(),
        }
    }

    pub fn with_base_url(mut self, url: &str) -> Self {
        self.base_url = url.into();
        self
    }

    pub fn fetch(&self, path: &str) -> Result<Data, Error> {
        // Uses self.base_url and self.api_key
        todo!()
    }
}

#[rustler::resource_impl]
impl rustler::Resource for DataProvider {}

// NIF creates provider
#[rustler::nif]
fn create_provider(api_key: String) -> ResourceArc<DataProvider> {
    ResourceArc::new(DataProvider::new(&api_key))
}

// Tests can inject mock URL
#[test]
fn test_fetch() {
    let provider = DataProvider::new("test-key")
        .with_base_url("http://localhost:8080");
    // Test against mock server
}
```

## 38. Round-Trip Testing Template

```rust
#[cfg(test)]
mod tests {
    use super::*;

    // Test encode/decode roundtrip
    #[test]
    fn encode_decode_roundtrip() {
        let original = TestData { id: 42, name: "test".into() };

        let encoded = encode(&original).unwrap();
        let decoded: TestData = decode(&encoded).unwrap();

        assert_eq!(original, decoded);
    }

    // Test with various inputs
    #[test]
    fn roundtrip_edge_cases() {
        // Empty
        roundtrip_check(TestData::default());

        // Max values
        roundtrip_check(TestData { id: i64::MAX, .. });

        // Unicode
        roundtrip_check(TestData { name: "日本語".into(), .. });

        // Special chars
        roundtrip_check(TestData { name: "\0\n\r".into(), .. });
    }

    fn roundtrip_check(original: TestData) {
        let encoded = encode(&original).unwrap();
        let decoded: TestData = decode(&encoded).unwrap();
        assert_eq!(original, decoded);
    }
}
```

## 39. must_use Attribute Pattern

```rust
// Warn if return value is ignored
#[must_use]
pub fn new(config: Config) -> Self {
    Self { config }
}

// On functions returning Result
#[must_use = "errors must be handled"]
pub fn process(data: &[u8]) -> Result<Vec<u8>, Error> {
    // ...
}

// On resource constructors
#[must_use]
#[rustler::nif]
fn create_connection(url: String) -> ResourceArc<Connection> {
    ResourceArc::new(Connection::new(&url))
}

// On types
#[must_use = "iterators are lazy"]
pub struct DataIterator { /* ... */ }
```

## 40. Field Init Shorthand

```rust
// When variable names match struct fields
#[derive(rustler::NifStruct)]
#[module = "MyApp.User"]
struct User {
    name: String,
    email: String,
    age: u32,
}

// AVOID: Redundant field names
fn create_user(name: String, email: String, age: u32) -> User {
    User { name: name, email: email, age: age }  // Verbose
}

// PREFER: Shorthand when names match
fn create_user(name: String, email: String, age: u32) -> User {
    User { name, email, age }  // Clean
}

// Works for updates too
fn with_email(mut user: User, email: String) -> User {
    user.email = email;  // Direct assign
    user
}

// Mix shorthand with explicit
fn partial_update(name: String, new_email: &str) -> User {
    User {
        name,                          // Shorthand
        email: new_email.to_string(),  // Explicit
        age: 0,                        // Explicit
    }
}
```

## 41. API-First Design Checklist

```
Design Flow:
1. Write Elixir interface first
   def process(data, opts), do: Native.process(data, opts)

2. Write tests that use that interface
   assert {:ok, result} = process([1,2,3], %{scale: 2})

3. Design Rust NIF signature to match
   #[rustler::nif]
   fn process(data: Vec<i64>, opts: Options) -> Result<...>

4. Implement and iterate

Checklist:
□ Elixir-friendly naming (snake_case)
□ Return {:ok, result} | {:error, reason} pattern
□ Options as map/struct for flexibility
□ Document expected types in Elixir @spec
□ Handle nil as Option<T> in Rust
□ Test both success and error paths
```

## 42. Testable NIF Design Pattern

```rust
// Split into testable components
#[rustler::nif(schedule = "DirtyCpu")]
fn process_image(data: Binary) -> Result<Vec<u8>, Atom> {
    // Thin wrapper - just calls internal functions
    let decoded = decode_image(data.as_slice())
        .map_err(|_| atoms::decode_error())?;
    let processed = apply_filters(&decoded)
        .map_err(|_| atoms::filter_error())?;
    let encoded = encode_result(&processed)
        .map_err(|_| atoms::encode_error())?;
    Ok(encoded)
}

// Internal functions - independently testable
fn decode_image(bytes: &[u8]) -> Result<Image, ImageError> { todo!() }
fn apply_filters(img: &Image) -> Result<Image, FilterError> { todo!() }
fn encode_result(img: &Image) -> Result<Vec<u8>, EncodeError> { todo!() }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_handles_png() {
        let png_bytes = include_bytes!("../test_data/test.png");
        let img = decode_image(png_bytes).unwrap();
        assert_eq!(img.width, 100);
    }

    #[test]
    fn apply_filters_brightness() {
        let img = Image::solid(100, 100, Color::gray(50));
        let result = apply_filters(&img).unwrap();
        assert!(result.average_brightness() > 50);
    }
}
```
