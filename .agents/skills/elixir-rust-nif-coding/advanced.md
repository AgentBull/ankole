# Rust NIF Advanced Topics

## 1. Advanced Threading Patterns

### rustler::thread::spawn (Automatic Result Sending)

Rustler provides built-in thread spawning that automatically sends results back:

```rust
use rustler::thread::ThreadSpawner;

#[rustler::nif]
fn compute_async<'a>(env: Env<'a>, data: Vec<i64>) -> Atom {
    rustler::thread::spawn::<ThreadSpawner, _>(env, move |_thread_env| {
        // This runs on a non-BEAM thread
        let result: i64 = data.iter().sum();

        // Return value is automatically sent to caller
        result
    });

    atoms::ok()
}
```

**Behavior:**
- Spawns a new system thread
- Closure's return value sent to calling process
- If closure panics, sends `{:error, reason}` instead
- Thread is NOT managed by BEAM scheduler

### Channel-Based Pipelines (CSP Model)

Use channels for multi-stage async processing:

```rust
use std::sync::mpsc;
use std::thread;

#[rustler::nif]
fn async_pipeline(env: Env, inputs: Vec<i64>) -> Atom {
    let pid = env.pid();

    // Create channel for stage communication
    let (tx, rx) = mpsc::channel();

    // Stage 1: Process data
    thread::spawn(move || {
        for item in inputs {
            let processed = expensive_compute(item);
            let _ = tx.send(processed);
        }
    });

    // Stage 2: Aggregate and send back
    thread::spawn(move || {
        let results: Vec<_> = rx.iter().collect();
        let mut owned_env = OwnedEnv::new();
        let _ = owned_env.send_and_clear(&pid, |env| {
            (atoms::results(), results).encode(env)
        });
    });

    atoms::ok()
}
```

### Scoped Threads (Deterministic Cleanup)

Scoped threads don't require `'static` - useful for parallel processing within a NIF:

```rust
use std::thread;
use std::sync::Mutex;

#[rustler::nif(schedule = "DirtyCpu")]
fn parallel_process(data: Vec<i64>) -> Vec<i64> {
    let results = Mutex::new(Vec::new());

    thread::scope(|s| {
        for chunk in data.chunks(100) {
            s.spawn(|| {
                let processed: Vec<i64> = chunk.iter()
                    .map(|x| expensive_calc(*x))
                    .collect();
                results.lock().unwrap().extend(processed);
            });
        }
    }); // All threads automatically joined here - no move needed!

    results.into_inner().unwrap()
}
```

**Benefits of scoped threads:**
- Can borrow local data (no `move` required)
- Guaranteed cleanup before scope exits
- Better for controlled parallel work within dirty schedulers

### Understanding Closure Traits (Fn, FnMut, FnOnce)

When passing closures to threads or callbacks, Rust uses three traits to describe how closures capture their environment:

| Trait | Captures By | Can Call | Use Case |
|-------|-------------|----------|----------|
| `Fn` | Immutable reference | Multiple times | Read-only access |
| `FnMut` | Mutable reference | Multiple times | Modifies captured state |
| `FnOnce` | Ownership (move) | Once | Transfers ownership |

**Why This Matters for NIFs:**

```rust
// thread::spawn requires FnOnce + Send + 'static
// The 'static bound means no borrowed references - must own all data
pub fn spawn<F, T>(f: F) -> JoinHandle<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static;

// This is why we use `move` closures:
#[rustler::nif]
fn async_work(env: Env, data: Vec<i64>) -> Atom {
    let pid = env.pid();  // Copy the pid (LocalPid is Copy)

    thread::spawn(move || {
        // `move` takes ownership of `data` and `pid`
        // Without `move`, this would try to borrow - fails 'static check
        let result: i64 = data.iter().sum();

        let mut owned_env = OwnedEnv::new();
        let _ = owned_env.send_and_clear(&pid, |env| {
            result.encode(env)
        });
    });

    atoms::ok()
}
```

**Closure Trait Hierarchy:**
```
FnOnce (can be called once)
   ↑
FnMut (can be called multiple times, may mutate)
   ↑
Fn (can be called multiple times, no mutation)
```

Every `Fn` is also `FnMut` and `FnOnce`. The compiler infers the most permissive trait based on what the closure does.

**Common Pattern with ResourceArc:**

```rust
// When callbacks need to mutate shared state, use Mutex inside ResourceArc
struct Counter {
    value: Mutex<i64>,
}

#[rustler::nif]
fn spawn_incrementer(env: Env, counter: ResourceArc<Counter>) -> Atom {
    let pid = env.pid();

    // ResourceArc is Clone, so we can share it across threads
    let counter_clone = counter.clone();

    thread::spawn(move || {
        // The closure takes ownership of counter_clone
        if let Ok(mut val) = counter_clone.value.try_lock() {
            *val += 1;
        }

        let mut owned_env = OwnedEnv::new();
        let _ = owned_env.send_and_clear(&pid, |env| {
            atoms::done().encode(env)
        });
    });

    atoms::ok()
}
```

### Thread Builder (Named/Sized Threads)

Use for debugging and resource control:

```rust
use std::thread::Builder;

#[rustler::nif]
fn spawn_named_worker(env: Env, name: String, value: i64) -> Atom {
    let pid = env.pid();

    let builder = Builder::new()
        .name(format!("nif_worker_{}", name))  // Visible in debuggers
        .stack_size(4096);  // Smaller stack for many workers

    builder.spawn(move || {
        let current = thread::current();
        println!("Running on thread: {:?}", current.name());

        let result = expensive_computation(value);

        let mut owned_env = OwnedEnv::new();
        let _ = owned_env.send_and_clear(&pid, |env| {
            (atoms::result(), result).encode(env)
        });
    }).expect("Failed to spawn thread");

    atoms::ok()
}
```

### Saving Terms Across Threads

```rust
#[rustler::nif]
fn process_term<'a>(env: Env<'a>, term: Term<'a>) -> Atom {
    let pid = env.pid();
    let mut thread_env = OwnedEnv::new();
    let saved = thread_env.save(term);  // Save term for other thread

    thread::spawn(move || {
        thread_env.run(|env| {
            let term = saved.load(env);  // Load saved term
            // Process term...
        });
    });

    atoms::ok()
}
```

**Critical Restrictions:**
- `send_and_clear()` PANICS if called from a BEAM-managed thread
- Only use from `std::thread::spawn` or similar
- Cannot save terms across `send()` or `clear()` calls

## 2. FFI Fundamentals for NIFs

### How NIF Types Map to Erlang NIF API

| Rustler Type | Erlang NIF API | FFI Concept |
|--------------|----------------|-------------|
| `Env<'a>` | `ErlNifEnv*` | Opaque pointer |
| `Term<'a>` | `ERL_NIF_TERM` | u64 handle |
| `ResourceArc<T>` | Resource object | Ref-counted pointer |
| `Binary` | `ErlNifBinary` | Pointer + length |

### CString for Calling C Libraries

When your NIF wraps a C library:

```rust
use std::ffi::{CString, CStr};
use std::os::raw::c_char;

// Declare the external C function
extern "C" {
    fn external_process(data: *const c_char) -> i32;
}

#[rustler::nif(schedule = "DirtyIo")]
fn call_c_library(input: String) -> Result<i32, String> {
    // Convert Rust String -> C string (null-terminated)
    let c_string = CString::new(input)
        .map_err(|_| "Invalid string (contains null byte)")?;

    // Safety: c_string is valid for the duration of this call
    let result = unsafe {
        external_process(c_string.as_ptr())
    };

    Ok(result)
}
```

### repr(C) for C-Compatible Struct Layouts

When passing structs to C code:

```rust
// C-compatible memory layout (predictable field ordering)
#[repr(C)]
struct CCompatibleData {
    size: u32,
    flags: u32,
    data: [u8; 256],
}

// Ensure matching layout with C headers
extern "C" {
    fn process_buffer(buf: *const CCompatibleData) -> i32;
}

#[rustler::nif(schedule = "DirtyIo")]
fn process_native_buffer(data: Vec<u8>) -> Result<i32, Atom> {
    if data.len() > 256 {
        return Err(atoms::invalid_input());
    }

    let mut buffer = CCompatibleData {
        size: data.len() as u32,
        flags: 0,
        data: [0u8; 256],
    };
    buffer.data[..data.len()].copy_from_slice(&data);

    Ok(unsafe { process_buffer(&buffer) })
}
```

### Memory Layout Attributes Reference

| Attribute | Effect | Use Case |
|-----------|--------|----------|
| `#[repr(Rust)]` | Default. Compiler may reorder fields. | Pure Rust structs (NOT for FFI) |
| `#[repr(C)]` | C-compatible layout. Predictable field order. | FFI structs passed to C |
| `#[repr(transparent)]` | Same layout as single field. | Newtype wrappers for FFI |
| `#[repr(packed)]` | No padding between fields. | Binary protocols, hardware registers |
| `#[repr(align(N))]` | Minimum alignment of N bytes. | SIMD, cache optimization |

**Examples:**

```rust
// repr(transparent) - newtype has same ABI as inner type
#[repr(transparent)]
struct UserId(u64);  // Can pass UserId where u64 expected in C

// repr(packed) - WARNING: may cause unaligned access issues
#[repr(packed)]
struct PackedHeader {
    magic: u16,
    version: u8,
    flags: u8,
    length: u32,
}  // Exactly 8 bytes, no padding

// repr(align) - force alignment for SIMD or cache lines
#[repr(C, align(64))]
struct CacheAligned {
    data: [f32; 16],
}  // Always starts on 64-byte boundary

// Combining attributes
#[repr(C, align(4))]
struct AlignedCStruct {
    a: u8,
    b: u8,
    // 2 bytes padding here
    c: u32,
}

// repr(C) for enums with C interop
#[repr(C)]
enum CStatus {
    Ok = 0,
    Error = 1,
    Pending = 2,
}

// repr(u8/u16/u32/etc) for enum discriminant size
#[repr(u8)]
enum SmallEnum {
    A = 0,
    B = 1,
}  // Discriminant is exactly 1 byte
```

**Safety Warning:**

```rust
// NEVER use default repr(Rust) for FFI!
struct BadForFFI {      // Compiler may reorder fields
    a: u8,
    b: u64,
    c: u8,
}

// ALWAYS use repr(C) for FFI
#[repr(C)]
struct GoodForFFI {     // Guaranteed C-compatible layout
    a: u8,
    _pad1: [u8; 7],     // Explicit padding if needed
    b: u64,
    c: u8,
    _pad2: [u8; 7],
}
```

### Raw Pointer Operations

Understanding how ResourceArc works internally:

```rust
// Box provides heap allocation with single ownership
let boxed = Box::new(ExpensiveData::new());

// into_raw transfers ownership to raw pointer
let raw: *mut ExpensiveData = Box::into_raw(boxed);
// boxed is now invalid - we own raw

// from_raw takes ownership back
let boxed_again = unsafe { Box::from_raw(raw) };
// raw is now invalid - boxed_again owns the data
```

### Linking External Libraries

In Cargo.toml:

```toml
[build-dependencies]
cc = "1.0"

# Or for system libraries
[target.'cfg(unix)'.dependencies]
zstd-sys = "2.0"
```

## 3. Module Organization for Large NIFs

For NIFs with multiple features, organize with modules:

### Project Structure

```
native/my_nif/src/
├── lib.rs          # NIF exports and init
├── atoms.rs        # Shared atoms module
├── resources/
│   ├── mod.rs
│   ├── counter.rs
│   └── cache.rs
├── operations/
│   ├── mod.rs
│   ├── math.rs
│   └── string.rs
└── utils.rs        # Internal helpers
```

### lib.rs (Main Entry Point)

```rust
mod atoms;
mod resources;
mod operations;
mod utils;

use resources::{counter, cache};
use operations::{math, string};

// Export all NIF functions
rustler::init!("Elixir.MyApp.Native");
```

### atoms.rs (Shared Atoms)

```rust
// Shared across all modules
rustler::atoms! {
    ok,
    error,
    not_found,
    lock_fail,
    invalid_input,
}

// Re-export for convenience
pub use atoms::*;
```

### Submodule Pattern

```rust
// resources/mod.rs
pub mod counter;
pub mod cache;

// resources/counter.rs
use crate::atoms;
use rustler::ResourceArc;
use parking_lot::Mutex;

pub struct Counter {
    value: Mutex<i64>,
}

#[rustler::resource_impl]
impl rustler::Resource for Counter {}

#[rustler::nif]
pub fn counter_new() -> ResourceArc<Counter> {
    ResourceArc::new(Counter {
        value: Mutex::new(0),
    })
}

#[rustler::nif]
pub fn counter_increment(counter: ResourceArc<Counter>) -> Result<i64, rustler::Atom> {
    match counter.value.try_lock() {
        Some(mut val) => {
            *val += 1;
            Ok(*val)
        }
        None => Err(atoms::lock_fail()),
    }
}
```

### Visibility Guidelines

- Use `pub` for NIF functions (must be accessible from lib.rs)
- Use `pub(crate)` for internal helpers shared between modules
- Keep implementation details private (no modifier)

## 4. String Optimization Patterns

### Efficient String Building
```rust
// BAD - multiple allocations
let result = s1 + &s2 + &s3;

// GOOD - preallocate capacity
let mut result = String::with_capacity(s1.len() + s2.len() + s3.len());
result.push_str(&s1);
result.push_str(&s2);
result.push_str(&s3);

// BETTER for clarity (single allocation)
let result = format!("{}{}{}", s1, s2, s3);
```

### NIF String Building
```rust
#[rustler::nif]
fn build_message(parts: Vec<String>) -> String {
    let total_len: usize = parts.iter().map(|s| s.len()).sum();
    let mut result = String::with_capacity(total_len);
    for part in parts {
        result.push_str(&part);
    }
    result
}
```

## 5. Lazy Initialization with OnceCell

For expensive resource setup that should happen only once:

```rust
use once_cell::sync::OnceCell;

struct ConfigResource {
    config: OnceCell<ExpensiveConfig>,
}

#[rustler::resource_impl]
impl rustler::Resource for ConfigResource {}

#[rustler::nif]
fn create_config_resource() -> ResourceArc<ConfigResource> {
    ResourceArc::new(ConfigResource {
        config: OnceCell::new(),
    })
}

#[rustler::nif]
fn get_config(res: ResourceArc<ConfigResource>) -> Result<Config, Atom> {
    // Expensive initialization only happens on first call
    let config = res.config.get_or_init(|| {
        load_expensive_config()  // Called once, then cached
    });
    Ok(config.clone())
}
```

## 6. When to Use Rust for Network Operations

| Scenario | Recommendation | Why |
|----------|----------------|-----|
| Simple HTTP requests | Use Elixir (Req) | Elixir async model is excellent |
| Heavy JSON processing with HTTP | Consider NIF | Combine network + CPU work |
| Custom binary protocols | Good NIF candidate | Rust's byteorder + type safety |
| Integration with Rust library | Use NIF | When library only exists in Rust |

## 7. Manual Term Encoding (Encoder Trait)

Derive macros cover most cases, but sometimes you need manual `Term` construction — keyword lists, mixed-type lists, or dynamic structures.

### The Encoder Trait

```rust
use rustler::{Encoder, Env, Term};

// Implement Encoder to control how your type becomes an Elixir term
struct Stats {
    count: usize,
    mean: f64,
    labels: Vec<String>,
}

impl Encoder for Stats {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        // Build an Elixir map: %{count: 42, mean: 3.14, labels: ["a", "b"]}
        let keys = vec![
            atoms::count().encode(env),
            atoms::mean().encode(env),
            atoms::labels().encode(env),
        ];
        let values = vec![
            self.count.encode(env),
            self.mean.encode(env),
            self.labels.encode(env),
        ];
        Term::map_from_arrays(env, &keys, &values).unwrap()
    }
}

mod atoms {
    rustler::atoms! { count, mean, labels }
}
```

### Returning Keyword Lists

Elixir keyword lists are `[{atom, value}, ...]` — encode as a list of 2-tuples:

```rust
#[rustler::nif]
fn build_options<'a>(env: Env<'a>) -> Term<'a> {
    let opts: Vec<Term> = vec![
        (atoms::timeout(), 5000i64).encode(env),
        (atoms::retries(), 3i64).encode(env),
    ];
    opts.encode(env)  // Elixir sees [timeout: 5000, retries: 3]
}

mod atoms {
    rustler::atoms! { timeout, retries }
}
```

### Building Dynamic Lists

```rust
#[rustler::nif]
fn mixed_results<'a>(env: Env<'a>, data: Vec<i64>) -> Term<'a> {
    // Build a list where each element can be a different type
    let terms: Vec<Term> = data.iter().map(|&val| {
        if val >= 0 {
            (atoms::ok(), val).encode(env)       // {:ok, 42}
        } else {
            (atoms::error(), "negative").encode(env)  // {:error, "negative"}
        }
    }).collect();
    terms.encode(env)
}
```

**When to use manual encoding vs derive macros:**

| Situation | Approach |
|-----------|----------|
| Fixed struct shape | `#[derive(NifMap)]` or `#[derive(NifStruct)]` |
| Keyword lists | Manual `Encoder` — no derive macro for keyword lists |
| Mixed-type lists | Manual `Encoder` — `Vec<T>` requires uniform type |
| Dynamic key sets | Manual `Term::map_from_arrays` |
| Conditional fields | Manual `Encoder` — derive includes all fields always |

## 8. CI/CD for Precompiled NIFs

GitHub Actions workflow for building and releasing precompiled NIF binaries across platforms.

### GitHub Actions Workflow

```yaml
# .github/workflows/release.yml
name: Build Precompiled NIFs

on:
  push:
    tags: ["v*"]

permissions:
  contents: write

jobs:
  build_release:
    name: NIF ${{ matrix.nif }} - ${{ matrix.target }}
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - { target: x86_64-unknown-linux-gnu,    os: ubuntu-latest,  nif: "2.16" }
          - { target: aarch64-unknown-linux-gnu,    os: ubuntu-latest,  nif: "2.16" }
          - { target: x86_64-apple-darwin,          os: macos-13,       nif: "2.16" }
          - { target: aarch64-apple-darwin,          os: macos-14,       nif: "2.16" }
          - { target: x86_64-unknown-linux-musl,    os: ubuntu-latest,  nif: "2.16" }

    steps:
      - uses: actions/checkout@v4

      - name: Install Rust toolchain
        uses: dtolnay/rust-toolchain@stable
        with:
          targets: ${{ matrix.target }}

      - name: Install cross-compilation tools (Linux aarch64)
        if: matrix.target == 'aarch64-unknown-linux-gnu'
        run: |
          sudo apt-get update
          sudo apt-get install -y gcc-aarch64-linux-gnu

      - name: Build NIF
        run: |
          cd native/my_nif
          cargo build --release --target ${{ matrix.target }}

      - name: Package artifact
        run: |
          tar -czf my_nif-nif-${{ matrix.nif }}-${{ matrix.target }}.tar.gz \
            -C native/my_nif/target/${{ matrix.target }}/release \
            libmy_nif.so libmy_nif.dylib 2>/dev/null || true

      - name: Upload to release
        uses: softprops/action-gh-release@v2
        with:
          files: my_nif-nif-*.tar.gz
```

### Elixir Module with Precompiled Support

```elixir
defmodule MyApp.Native do
  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :my_app,
    crate: "my_nif",
    base_url: "https://github.com/user/repo/releases/download/v#{version}",
    version: version,
    force_build: System.get_env("FORCE_NIF_BUILD") in ["1", "true"],
    targets: ~w(
      aarch64-apple-darwin
      aarch64-unknown-linux-gnu
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
    )

  # NIF stubs...
end
```

**Key points:**
- Tag a release (`git tag v0.1.0 && git push --tags`) to trigger the build
- `RustlerPrecompiled` downloads the matching binary at compile time
- `force_build: true` falls back to local Rust compilation (for dev/CI)
- Add `checksum-*.exs` files to your repo after first successful release
