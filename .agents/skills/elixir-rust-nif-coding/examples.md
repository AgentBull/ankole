# Rustler NIF Examples

Complete working examples demonstrating Rust NIF patterns from basic to production-grade.

## 1. Simple Arithmetic NIF

### Rust Code (native/math_nif/src/lib.rs)
```rust
#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

#[rustler::nif]
fn multiply(a: i64, b: i64) -> i64 {
    a * b
}

#[rustler::nif]
fn factorial(n: u64) -> u64 {
    (1..=n).product()
}

rustler::init!("Elixir.MyApp.Math");
```

### Elixir Module
```elixir
defmodule MyApp.Math do
  use Rustler,
    otp_app: :my_app,
    crate: "math_nif"

  @spec add(integer(), integer()) :: integer()
  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)

  @spec multiply(integer(), integer()) :: integer()
  def multiply(_a, _b), do: :erlang.nif_error(:nif_not_loaded)

  @spec factorial(non_neg_integer()) :: non_neg_integer()
  def factorial(_n), do: :erlang.nif_error(:nif_not_loaded)
end
```

### Usage
```elixir
iex> MyApp.Math.add(2, 3)
5
iex> MyApp.Math.factorial(20)
2432902008176640000
```

---

## 2. String Processing NIF

### Rust Code
```rust
use rustler::NifResult;

#[rustler::nif]
fn reverse_string(input: String) -> String {
    input.chars().rev().collect()
}

#[rustler::nif]
fn word_count(input: &str) -> usize {
    input.split_whitespace().count()
}

#[rustler::nif]
fn to_uppercase(input: String) -> String {
    input.to_uppercase()
}

// String validation with Result
#[rustler::nif]
fn validate_email(email: String) -> NifResult<bool> {
    if email.contains('@') && email.contains('.') {
        Ok(true)
    } else {
        Ok(false)
    }
}

rustler::init!("Elixir.MyApp.StringUtils");
```

### Elixir Module
```elixir
defmodule MyApp.StringUtils do
  use Rustler, otp_app: :my_app, crate: "string_nif"

  @spec reverse_string(String.t()) :: String.t()
  def reverse_string(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec word_count(String.t()) :: non_neg_integer()
  def word_count(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec to_uppercase(String.t()) :: String.t()
  def to_uppercase(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec validate_email(String.t()) :: {:ok, boolean()} | {:error, String.t()}
  def validate_email(_email), do: :erlang.nif_error(:nif_not_loaded)
end
```

---

## 3. Binary Processing NIF

### Rust Code
```rust
use rustler::{Binary, OwnedBinary, NewBinary, Env};

// Zero-copy binary reading
#[rustler::nif]
fn binary_length(data: Binary) -> usize {
    data.len()
}

// Binary to Vec (copies data)
#[rustler::nif]
fn sum_bytes(data: Binary) -> u64 {
    data.iter().map(|&b| b as u64).sum()
}

// Creating new binary
#[rustler::nif]
fn create_binary(env: Env, size: usize) -> Binary {
    let mut binary = NewBinary::new(env, size);
    for (i, byte) in binary.as_mut_slice().iter_mut().enumerate() {
        *byte = (i % 256) as u8;
    }
    binary.into()
}

// XOR encryption (returns new binary)
#[rustler::nif]
fn xor_bytes(env: Env, data: Binary, key: u8) -> Binary {
    let mut result = OwnedBinary::new(data.len()).unwrap();
    for (i, &byte) in data.iter().enumerate() {
        result.as_mut_slice()[i] = byte ^ key;
    }
    result.release(env)
}

rustler::init!("Elixir.MyApp.BinaryUtils");
```

### Elixir Module
```elixir
defmodule MyApp.BinaryUtils do
  use Rustler, otp_app: :my_app, crate: "binary_nif"

  def binary_length(_data), do: :erlang.nif_error(:nif_not_loaded)
  def sum_bytes(_data), do: :erlang.nif_error(:nif_not_loaded)
  def create_binary(_size), do: :erlang.nif_error(:nif_not_loaded)
  def xor_bytes(_data, _key), do: :erlang.nif_error(:nif_not_loaded)
end
```

### Usage
```elixir
iex> MyApp.BinaryUtils.binary_length(<<1, 2, 3, 4>>)
4
iex> MyApp.BinaryUtils.xor_bytes(<<1, 2, 3>>, 255)
<<254, 253, 252>>
```

---

## 4. Returning Elixir Tuples

### Rust Code
```rust
use rustler::{Atom, NifResult, Error};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        not_found,
        invalid_input,
        overflow,
    }
}

// Automatic {:ok, value} / {:error, reason} conversion
#[rustler::nif]
fn safe_divide(a: i64, b: i64) -> Result<i64, Atom> {
    if b == 0 {
        Err(atoms::invalid_input())
    } else {
        Ok(a / b)
    }
}

// String error messages
#[rustler::nif]
fn parse_number(input: String) -> Result<i64, String> {
    input.parse()
        .map_err(|_| format!("Cannot parse '{}' as number", input))
}

// Multiple error types with custom atoms
#[rustler::nif]
fn checked_add(a: i64, b: i64) -> Result<i64, Atom> {
    a.checked_add(b).ok_or(atoms::overflow())
}

// Using NifResult for BadArg errors
#[rustler::nif]
fn strict_positive(n: i64) -> NifResult<i64> {
    if n > 0 {
        Ok(n)
    } else {
        Err(Error::BadArg)
    }
}

rustler::init!("Elixir.MyApp.SafeMath");
```

### Elixir Usage
```elixir
iex> MyApp.SafeMath.safe_divide(10, 2)
{:ok, 5}
iex> MyApp.SafeMath.safe_divide(10, 0)
{:error, :invalid_input}
iex> MyApp.SafeMath.parse_number("abc")
{:error, "Cannot parse 'abc' as number"}
iex> MyApp.SafeMath.checked_add(9223372036854775807, 1)
{:error, :overflow}
```

---

## 5. Working with Structs

### Rust Code
```rust
use rustler::NifResult;

// Maps to %MyApp.User{name: "", age: 0}
#[derive(rustler::NifStruct)]
#[module = "MyApp.User"]
struct User {
    name: String,
    age: i32,
}

// Maps to plain map %{host: "", port: 0}
#[derive(rustler::NifMap)]
struct ServerConfig {
    host: String,
    port: i32,
}

// Maps to tuple {x, y}
#[derive(rustler::NifTuple)]
struct Point(i32, i32);

// Maps to tagged tuple {:point, x, y}
#[derive(rustler::NifRecord)]
#[tag = "point"]
struct RecordPoint {
    x: i32,
    y: i32,
}

#[rustler::nif]
fn greet_user(user: User) -> String {
    format!("Hello, {}! You are {} years old.", user.name, user.age)
}

#[rustler::nif]
fn create_user(name: String, age: i32) -> User {
    User { name, age }
}

#[rustler::nif]
fn format_config(config: ServerConfig) -> String {
    format!("{}:{}", config.host, config.port)
}

#[rustler::nif]
fn distance_from_origin(point: Point) -> f64 {
    let Point(x, y) = point;
    ((x.pow(2) + y.pow(2)) as f64).sqrt()
}

#[rustler::nif]
fn move_point(point: RecordPoint, dx: i32, dy: i32) -> RecordPoint {
    RecordPoint {
        x: point.x + dx,
        y: point.y + dy,
    }
}

rustler::init!("Elixir.MyApp.Structs");
```

### Elixir Module with Struct Definition
```elixir
defmodule MyApp.User do
  defstruct [:name, :age]
end

defmodule MyApp.Structs do
  use Rustler, otp_app: :my_app, crate: "struct_nif"

  def greet_user(_user), do: :erlang.nif_error(:nif_not_loaded)
  def create_user(_name, _age), do: :erlang.nif_error(:nif_not_loaded)
  def format_config(_config), do: :erlang.nif_error(:nif_not_loaded)
  def distance_from_origin(_point), do: :erlang.nif_error(:nif_not_loaded)
  def move_point(_point, _dx, _dy), do: :erlang.nif_error(:nif_not_loaded)
end
```

### Usage
```elixir
iex> MyApp.Structs.greet_user(%MyApp.User{name: "Alice", age: 30})
"Hello, Alice! You are 30 years old."
iex> MyApp.Structs.create_user("Bob", 25)
%MyApp.User{name: "Bob", age: 25}
iex> MyApp.Structs.format_config(%{host: "localhost", port: 5432})
"localhost:5432"
iex> MyApp.Structs.distance_from_origin({3, 4})
5.0
iex> MyApp.Structs.move_point({:point, 1, 2}, 3, 4)
{:point, 4, 6}
```

---

## 6. Dirty Scheduler Example

### Rust Code
```rust
use std::thread;
use std::time::Duration;

// Normal scheduler - for operations < 1ms
#[rustler::nif]
fn fast_hash(data: String) -> u64 {
    // Simple hash - completes in microseconds
    let mut hash: u64 = 0;
    for byte in data.bytes() {
        hash = hash.wrapping_mul(31).wrapping_add(byte as u64);
    }
    hash
}

// Dirty CPU scheduler - for CPU-bound operations > 1ms
#[rustler::nif(schedule = "DirtyCpu")]
fn compute_heavy(iterations: u64) -> u64 {
    let mut result: u64 = 0;
    for i in 0..iterations {
        result = result.wrapping_add(i.wrapping_mul(i));
    }
    result
}

// Dirty I/O scheduler - for I/O-bound operations
#[rustler::nif(schedule = "DirtyIo")]
fn simulate_io_wait(milliseconds: u64) -> String {
    thread::sleep(Duration::from_millis(milliseconds));
    format!("Waited {} ms", milliseconds)
}

// CPU-intensive with timing check
#[rustler::nif(schedule = "DirtyCpu")]
fn matrix_multiply(size: usize) -> u64 {
    // Simulated matrix operation
    let mut result: u64 = 0;
    for i in 0..size {
        for j in 0..size {
            for k in 0..size {
                result = result.wrapping_add((i * j * k) as u64);
            }
        }
    }
    result
}

rustler::init!("Elixir.MyApp.Heavy");
```

### Elixir Module
```elixir
defmodule MyApp.Heavy do
  use Rustler, otp_app: :my_app, crate: "heavy_nif"

  def fast_hash(_data), do: :erlang.nif_error(:nif_not_loaded)
  def compute_heavy(_iterations), do: :erlang.nif_error(:nif_not_loaded)
  def simulate_io_wait(_ms), do: :erlang.nif_error(:nif_not_loaded)
  def matrix_multiply(_size), do: :erlang.nif_error(:nif_not_loaded)
end
```

### Benchmarking with Benchee
```elixir
# benchmark.exs
Benchee.run(%{
  "fast_hash" => fn -> MyApp.Heavy.fast_hash("test string") end,
  "compute_heavy_1k" => fn -> MyApp.Heavy.compute_heavy(1_000) end,
  "compute_heavy_1m" => fn -> MyApp.Heavy.compute_heavy(1_000_000) end,
})
```

---

## 7. Enum Handling

### Rust Code
```rust
// Unit enum - maps to atoms :red, :green, :blue
#[derive(rustler::NifUnitEnum)]
enum Color {
    Red,
    Green,
    Blue,
}

// Tagged enum - maps to :ok | {:error, String}
#[derive(rustler::NifTaggedEnum)]
enum ProcessResult {
    Ok,
    Error(String),
    Partial { processed: i32, remaining: i32 },
}

// Untagged enum - multiple representations
#[derive(rustler::NifUntaggedEnum)]
enum FlexibleInput {
    Integer(i64),
    Text(String),
    Flag(bool),
}

#[rustler::nif]
fn color_to_hex(color: Color) -> String {
    match color {
        Color::Red => "#FF0000".to_string(),
        Color::Green => "#00FF00".to_string(),
        Color::Blue => "#0000FF".to_string(),
    }
}

#[rustler::nif]
fn process_data(count: i32) -> ProcessResult {
    if count < 0 {
        ProcessResult::Error("Count cannot be negative".to_string())
    } else if count > 100 {
        ProcessResult::Partial {
            processed: 100,
            remaining: count - 100,
        }
    } else {
        ProcessResult::Ok
    }
}

#[rustler::nif]
fn describe_input(input: FlexibleInput) -> String {
    match input {
        FlexibleInput::Integer(n) => format!("Got integer: {}", n),
        FlexibleInput::Text(s) => format!("Got text: {}", s),
        FlexibleInput::Flag(b) => format!("Got flag: {}", b),
    }
}

rustler::init!("Elixir.MyApp.Enums");
```

### Elixir Usage
```elixir
iex> MyApp.Enums.color_to_hex(:red)
"#FF0000"
iex> MyApp.Enums.process_data(50)
:ok
iex> MyApp.Enums.process_data(-1)
{:error, "Count cannot be negative"}
iex> MyApp.Enums.process_data(150)
{:partial, 100, 50}
iex> MyApp.Enums.describe_input(42)
"Got integer: 42"
iex> MyApp.Enums.describe_input("hello")
"Got text: hello"
```

---

## 8. Sending Messages to Processes

### Rust Code
```rust
use rustler::{Env, LocalPid, Encoder};

mod atoms {
    rustler::atoms! {
        ok,
        notification,
        progress,
    }
}

// Send notification to caller
#[rustler::nif]
fn notify_caller(env: Env, message: String) -> Result<(), rustler::Error> {
    let pid = env.pid();
    env.send(&pid, (atoms::notification(), message).encode(env))
        .map_err(|_| rustler::Error::Term(Box::new("send failed")))
}

// Send to specific PID
#[rustler::nif]
fn send_to_pid(env: Env, pid: LocalPid, message: String) -> Result<(), rustler::Error> {
    if !env.is_process_alive(pid) {
        return Err(rustler::Error::Term(Box::new("process not alive")));
    }

    env.send(&pid, (atoms::notification(), message).encode(env))
        .map_err(|_| rustler::Error::Term(Box::new("send failed")))
}

// Send progress updates during long operation
#[rustler::nif(schedule = "DirtyCpu")]
fn process_with_progress(env: Env, items: Vec<i64>) -> i64 {
    let pid = env.pid();
    let total = items.len();
    let mut sum: i64 = 0;

    for (i, item) in items.iter().enumerate() {
        sum += item;

        // Send progress every 100 items
        if i % 100 == 0 {
            let progress = ((i * 100) / total) as i32;
            let _ = env.send(&pid, (atoms::progress(), progress).encode(env));
        }
    }

    sum
}

rustler::init!("Elixir.MyApp.Messaging");
```

### Elixir Usage
```elixir
defmodule MyApp.Messaging do
  use Rustler, otp_app: :my_app, crate: "messaging_nif"

  def notify_caller(_message), do: :erlang.nif_error(:nif_not_loaded)
  def send_to_pid(_pid, _message), do: :erlang.nif_error(:nif_not_loaded)
  def process_with_progress(_items), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> MyApp.Messaging.notify_caller("Hello!")
:ok
iex> receive do {:notification, msg} -> msg end
"Hello!"

# With progress monitoring
iex> spawn(fn ->
...>   MyApp.Messaging.process_with_progress(Enum.to_list(1..1000))
...>   |> IO.inspect(label: "Result")
...> end)
iex> flush()
{:progress, 0}
{:progress, 10}
{:progress, 20}
# ... etc
```

---

## 9. Async Operations with OwnedEnv

### Rust Code
```rust
use rustler::{Env, LocalPid, Encoder};
use rustler::env::OwnedEnv;
use std::thread;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        result,
        async_result,
    }
}

// Async operation using OwnedEnv
#[rustler::nif]
fn async_compute(env: Env, value: i64) -> rustler::Atom {
    let pid = env.pid();

    thread::spawn(move || {
        // Simulate long computation
        let result = expensive_computation(value);

        // Create process-independent environment
        let mut owned_env = OwnedEnv::new();

        // Send result back to caller
        // IMPORTANT: send_and_clear panics on BEAM threads!
        let _ = owned_env.send_and_clear(&pid, |env| {
            (atoms::async_result(), result).encode(env)
        });
    });

    atoms::ok()
}

fn expensive_computation(value: i64) -> i64 {
    // Simulate work
    std::thread::sleep(std::time::Duration::from_millis(100));
    value * value
}

// Save terms for use across OwnedEnv runs
#[rustler::nif]
fn async_with_context(env: Env, context: String, value: i64) -> rustler::Atom {
    let pid = env.pid();

    thread::spawn(move || {
        let result = expensive_computation(value);

        let mut owned_env = OwnedEnv::new();
        let _ = owned_env.send_and_clear(&pid, |env| {
            (atoms::result(), context, result).encode(env)
        });
    });

    atoms::ok()
}

rustler::init!("Elixir.MyApp.Async");
```

### Elixir Usage
```elixir
defmodule MyApp.Async do
  use Rustler, otp_app: :my_app, crate: "async_nif"

  def async_compute(_value), do: :erlang.nif_error(:nif_not_loaded)
  def async_with_context(_context, _value), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> MyApp.Async.async_compute(42)
:ok
iex> receive do {:async_result, result} -> result end
1764

# With context
iex> MyApp.Async.async_with_context("task_1", 10)
:ok
iex> receive do {:result, ctx, val} -> {ctx, val} end
{"task_1", 100}
```

---

## 10. Thread Spawning with rustler::thread::spawn

### Rust Code
```rust
use rustler::{Env, Encoder};

mod atoms {
    rustler::atoms! {
        ok,
        error,
    }
}

// Using rustler::thread::spawn for automatic message sending
#[rustler::nif]
fn spawn_computation(env: Env, value: i64) -> rustler::Atom {
    // Spawns thread, automatically sends result to caller
    rustler::thread::spawn::<_, Result<i64, String>>(env, move || {
        if value < 0 {
            return Err("Value must be non-negative".to_string());
        }

        // Simulate long computation
        std::thread::sleep(std::time::Duration::from_millis(50));
        Ok(value * value)
    });

    atoms::ok()
}

// Thread spawning with complex return type
#[derive(rustler::NifMap)]
struct ComputeResult {
    input: i64,
    output: i64,
    elapsed_ms: u64,
}

#[rustler::nif]
fn spawn_with_timing(env: Env, value: i64) -> rustler::Atom {
    rustler::thread::spawn::<_, ComputeResult>(env, move || {
        let start = std::time::Instant::now();

        // Do work
        std::thread::sleep(std::time::Duration::from_millis(100));
        let output = value * value;

        ComputeResult {
            input: value,
            output,
            elapsed_ms: start.elapsed().as_millis() as u64,
        }
    });

    atoms::ok()
}

rustler::init!("Elixir.MyApp.ThreadSpawn");
```

### Elixir Usage
```elixir
defmodule MyApp.ThreadSpawn do
  use Rustler, otp_app: :my_app, crate: "thread_spawn_nif"

  def spawn_computation(_value), do: :erlang.nif_error(:nif_not_loaded)
  def spawn_with_timing(_value), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage - result automatically sent to caller
iex> MyApp.ThreadSpawn.spawn_computation(10)
:ok
iex> receive do msg -> msg end
{:ok, 100}

iex> MyApp.ThreadSpawn.spawn_computation(-1)
:ok
iex> receive do msg -> msg end
{:error, "Value must be non-negative"}

# With timing
iex> MyApp.ThreadSpawn.spawn_with_timing(5)
:ok
iex> receive do msg -> msg end
%{input: 5, output: 25, elapsed_ms: 100}
```

---

## 11. Basic State Management with ResourceArc

### Rust Code
```rust
use rustler::{Env, ResourceArc};
use std::sync::Mutex;

struct Counter {
    value: Mutex<i64>,
}

#[rustler::resource_impl]
impl rustler::Resource for Counter {}

#[rustler::nif]
fn counter_new() -> ResourceArc<Counter> {
    ResourceArc::new(Counter {
        value: Mutex::new(0),
    })
}

#[rustler::nif]
fn counter_increment(counter: ResourceArc<Counter>) -> i64 {
    let mut value = counter.value.lock().unwrap();
    *value += 1;
    *value
}

#[rustler::nif]
fn counter_get(counter: ResourceArc<Counter>) -> i64 {
    *counter.value.lock().unwrap()
}

#[rustler::nif]
fn counter_add(counter: ResourceArc<Counter>, amount: i64) -> i64 {
    let mut value = counter.value.lock().unwrap();
    *value += amount;
    *value
}

rustler::init!("Elixir.MyApp.Counter");
```

### Elixir Module
```elixir
defmodule MyApp.Counter do
  use Rustler, otp_app: :my_app, crate: "counter_nif"

  def counter_new(), do: :erlang.nif_error(:nif_not_loaded)
  def counter_increment(_counter), do: :erlang.nif_error(:nif_not_loaded)
  def counter_get(_counter), do: :erlang.nif_error(:nif_not_loaded)
  def counter_add(_counter, _amount), do: :erlang.nif_error(:nif_not_loaded)
end
```

### Usage
```elixir
iex> counter = MyApp.Counter.counter_new()
#Reference<...>
iex> MyApp.Counter.counter_increment(counter)
1
iex> MyApp.Counter.counter_increment(counter)
2
iex> MyApp.Counter.counter_add(counter, 10)
12
iex> MyApp.Counter.counter_get(counter)
12
```

---

## 12. Defensive Locking (Discord Pattern)

### Rust Code
```rust
use rustler::{Env, ResourceArc, Atom};
use parking_lot::Mutex;  // Faster than std::sync::Mutex

mod atoms {
    rustler::atoms! {
        ok,
        error,
        lock_fail,
    }
}

struct SortedSet {
    data: Mutex<Vec<i64>>,
}

#[rustler::resource_impl]
impl rustler::Resource for SortedSet {}

#[rustler::nif]
fn sorted_set_new() -> ResourceArc<SortedSet> {
    ResourceArc::new(SortedSet {
        data: Mutex::new(Vec::new()),
    })
}

// Discord pattern: use try_lock() instead of lock()
// Returns error instead of blocking/deadlocking
#[rustler::nif]
fn sorted_set_insert(set: ResourceArc<SortedSet>, value: i64) -> Result<bool, Atom> {
    match set.data.try_lock() {
        Some(mut data) => {
            match data.binary_search(&value) {
                Ok(_) => Ok(false), // Already existed
                Err(pos) => {
                    data.insert(pos, value);
                    Ok(true) // Newly inserted
                }
            }
        }
        None => Err(atoms::lock_fail()),
    }
}

#[rustler::nif]
fn sorted_set_contains(set: ResourceArc<SortedSet>, value: i64) -> Result<bool, Atom> {
    match set.data.try_lock() {
        Some(data) => Ok(data.binary_search(&value).is_ok()),
        None => Err(atoms::lock_fail()),
    }
}

#[rustler::nif]
fn sorted_set_to_list(set: ResourceArc<SortedSet>) -> Result<Vec<i64>, Atom> {
    match set.data.try_lock() {
        Some(data) => Ok(data.clone()),
        None => Err(atoms::lock_fail()),
    }
}

#[rustler::nif]
fn sorted_set_size(set: ResourceArc<SortedSet>) -> Result<usize, Atom> {
    match set.data.try_lock() {
        Some(data) => Ok(data.len()),
        None => Err(atoms::lock_fail()),
    }
}

rustler::init!("Elixir.MyApp.SortedSet");
```

### Elixir Wrapper with Retry Logic
```elixir
defmodule MyApp.SortedSet do
  use Rustler, otp_app: :my_app, crate: "sorted_set_nif"

  # NIF functions
  def sorted_set_new(), do: :erlang.nif_error(:nif_not_loaded)
  def sorted_set_insert(_set, _value), do: :erlang.nif_error(:nif_not_loaded)
  def sorted_set_contains(_set, _value), do: :erlang.nif_error(:nif_not_loaded)
  def sorted_set_to_list(_set), do: :erlang.nif_error(:nif_not_loaded)
  def sorted_set_size(_set), do: :erlang.nif_error(:nif_not_loaded)

  # Public API with retry logic
  def new, do: sorted_set_new()

  def insert(set, value, retries \\ 3) do
    case sorted_set_insert(set, value) do
      {:ok, _inserted} -> :ok
      {:error, :lock_fail} when retries > 0 ->
        Process.sleep(1)
        insert(set, value, retries - 1)
      {:error, :lock_fail} ->
        {:error, :lock_timeout}
    end
  end

  def contains?(set, value) do
    case sorted_set_contains(set, value) do
      {:ok, result} -> result
      {:error, :lock_fail} -> false
    end
  end

  def to_list(set) do
    case sorted_set_to_list(set) do
      {:ok, list} -> list
      {:error, :lock_fail} -> []
    end
  end
end
```

---

## 13. Process Monitoring with Resource Callbacks

### Rust Code
```rust
use rustler::{Env, LocalPid, ResourceArc, Encoder};
use rustler::resource::Monitor;
use parking_lot::Mutex;
use std::collections::HashMap;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        subscription_ended,
    }
}

struct Subscription {
    subscribers: Mutex<HashMap<LocalPid, Monitor>>,
}

#[rustler::resource_impl]
impl rustler::Resource for Subscription {
    // No manual IMPLEMENTS_DOWN needed — the macro detects `down` and sets it automatically

    fn down<'a>(&'a self, env: Env<'a>, pid: LocalPid, _mon: Monitor) {
        // Called when a monitored process dies
        if let Some(mut subs) = self.subscribers.try_lock() {
            subs.remove(&pid);
        }

        // Optional: notify other subscribers
        println!("Process {:?} terminated", pid);
    }
}

#[rustler::nif]
fn subscription_new() -> ResourceArc<Subscription> {
    ResourceArc::new(Subscription {
        subscribers: Mutex::new(HashMap::new()),
    })
}

#[rustler::nif]
fn subscribe(env: Env, sub: ResourceArc<Subscription>) -> Result<usize, rustler::Atom> {
    let pid = env.pid();

    // Monitor the calling process
    match env.monitor(&sub, &pid) {
        Some(monitor) => {
            if let Some(mut subs) = sub.subscribers.try_lock() {
                subs.insert(pid, monitor);
                Ok(subs.len())  // Return subscriber count
            } else {
                Err(atoms::error())
            }
        }
        None => Err(atoms::error()),
    }
}

#[rustler::nif]
fn unsubscribe(env: Env, sub: ResourceArc<Subscription>) -> Result<usize, rustler::Atom> {
    let pid = env.pid();

    if let Some(mut subs) = sub.subscribers.try_lock() {
        if let Some(monitor) = subs.remove(&pid) {
            env.demonitor(&sub, &monitor);
        }
        Ok(subs.len())  // Return remaining subscriber count
    } else {
        Err(atoms::error())
    }
}

#[rustler::nif]
fn subscriber_count(sub: ResourceArc<Subscription>) -> Result<usize, rustler::Atom> {
    sub.subscribers.try_lock()
        .map(|subs| subs.len())
        .ok_or(atoms::error())
}

rustler::init!("Elixir.MyApp.Subscription");
```

### Elixir Usage
```elixir
defmodule MyApp.Subscription do
  use Rustler, otp_app: :my_app, crate: "subscription_nif"

  def subscription_new(), do: :erlang.nif_error(:nif_not_loaded)
  def subscribe(_sub), do: :erlang.nif_error(:nif_not_loaded)
  def unsubscribe(_sub), do: :erlang.nif_error(:nif_not_loaded)
  def subscriber_count(_sub), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> sub = MyApp.Subscription.subscription_new()
iex> MyApp.Subscription.subscribe(sub)
{:ok, 1}
iex> MyApp.Subscription.subscriber_count(sub)
{:ok, 1}

# Spawn process that subscribes then exits
iex> spawn(fn ->
...>   MyApp.Subscription.subscribe(sub)
...>   Process.sleep(100)
...> end)
iex> Process.sleep(200)
iex> MyApp.Subscription.subscriber_count(sub)
{:ok, 1}  # Only the iex process remains subscribed
```

---

## 14. Discord sorted_set_nif Production Pattern

### Complete Production-Ready Example

```rust
// Cargo.toml
// [dependencies]
// rustler = "0.37.2"
// parking_lot = "0.12"
//
// [target.'cfg(not(target_env = "musl"))'.dependencies]
// jemallocator = "0.5"

use parking_lot::Mutex;
use rustler::{Atom, Env, ResourceArc, NifResult};
use std::cmp::Ordering;

#[cfg(not(target_env = "musl"))]
#[global_allocator]
static ALLOC: jemallocator::Jemalloc = jemallocator::Jemalloc;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        lock_fail,
        not_found,
        duplicate,
        invalid_score,
    }
}

// Return enum for semantic operations
#[derive(rustler::NifTaggedEnum)]
enum InsertResult {
    Inserted,
    Updated { old_score: f64 },
    Duplicate,
}

#[derive(Debug, Clone)]
struct ScoredMember {
    score: f64,
    member: String,
}

struct SortedSetResource {
    data: Mutex<Vec<ScoredMember>>,
}

#[rustler::resource_impl]
impl rustler::Resource for SortedSetResource {}

#[rustler::nif]
fn new() -> ResourceArc<SortedSetResource> {
    ResourceArc::new(SortedSetResource {
        data: Mutex::new(Vec::new()),
    })
}

#[rustler::nif]
fn add(
    set: ResourceArc<SortedSetResource>,
    member: String,
    score: f64,
) -> Result<InsertResult, Atom> {
    if score.is_nan() || score.is_infinite() {
        return Err(atoms::invalid_score());
    }

    let mut data = set.data.try_lock().ok_or(atoms::lock_fail())?;

    // Check if member exists
    if let Some(pos) = data.iter().position(|m| m.member == member) {
        let old_score = data[pos].score;
        data[pos].score = score;

        // Re-sort after score change
        data.sort_by(|a, b| {
            a.score.partial_cmp(&b.score)
                .unwrap_or(Ordering::Equal)
                .then_with(|| a.member.cmp(&b.member))
        });

        return Ok(InsertResult::Updated { old_score });
    }

    // Insert new member
    let new_member = ScoredMember { score, member };
    let pos = data.binary_search_by(|m| {
        m.score.partial_cmp(&score)
            .unwrap_or(Ordering::Equal)
            .then_with(|| m.member.cmp(&new_member.member))
    }).unwrap_or_else(|p| p);

    data.insert(pos, new_member);
    Ok(InsertResult::Inserted)
}

#[rustler::nif]
fn remove(
    set: ResourceArc<SortedSetResource>,
    member: String,
) -> Result<bool, Atom> {
    let mut data = set.data.try_lock().ok_or(atoms::lock_fail())?;

    if let Some(pos) = data.iter().position(|m| m.member == member) {
        data.remove(pos);
        Ok(true)
    } else {
        Ok(false)
    }
}

#[rustler::nif]
fn range_by_score(
    set: ResourceArc<SortedSetResource>,
    min: f64,
    max: f64,
    offset: usize,
    limit: usize,
) -> Result<Vec<(String, f64)>, Atom> {
    let data = set.data.try_lock().ok_or(atoms::lock_fail())?;

    let results: Vec<(String, f64)> = data.iter()
        .filter(|m| m.score >= min && m.score <= max)
        .skip(offset)
        .take(limit)
        .map(|m| (m.member.clone(), m.score))
        .collect();

    Ok(results)
}

#[rustler::nif]
fn cardinality(set: ResourceArc<SortedSetResource>) -> Result<usize, Atom> {
    let data = set.data.try_lock().ok_or(atoms::lock_fail())?;
    Ok(data.len())
}

#[rustler::nif]
fn score(
    set: ResourceArc<SortedSetResource>,
    member: String,
) -> Result<Option<f64>, Atom> {
    let data = set.data.try_lock().ok_or(atoms::lock_fail())?;
    Ok(data.iter()
        .find(|m| m.member == member)
        .map(|m| m.score))
}

rustler::init!("Elixir.MyApp.ScoredSet");
```

### Elixir Wrapper
```elixir
defmodule MyApp.ScoredSet do
  use Rustler, otp_app: :my_app, crate: "scored_set_nif"

  def new(), do: :erlang.nif_error(:nif_not_loaded)
  def add(_set, _member, _score), do: :erlang.nif_error(:nif_not_loaded)
  def remove(_set, _member), do: :erlang.nif_error(:nif_not_loaded)
  def range_by_score(_set, _min, _max, _offset, _limit), do: :erlang.nif_error(:nif_not_loaded)
  def cardinality(_set), do: :erlang.nif_error(:nif_not_loaded)
  def score(_set, _member), do: :erlang.nif_error(:nif_not_loaded)
end
```

---

## 15. Explorer/Polars Pattern (Read-Heavy Workload)

### Rust Code
```rust
use parking_lot::RwLock;  // For read-heavy workloads
use rustler::{Atom, ResourceArc, Env, Binary};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        lock_fail,
    }
}

#[derive(Clone)]
struct DataFrame {
    columns: Vec<Column>,
}

#[derive(Clone)]
struct Column {
    name: String,
    data: Vec<f64>,
}

struct DataFrameResource {
    inner: RwLock<DataFrame>,  // RwLock for many readers
}

#[rustler::resource_impl]
impl rustler::Resource for DataFrameResource {}

#[rustler::nif]
fn df_new() -> ResourceArc<DataFrameResource> {
    ResourceArc::new(DataFrameResource {
        inner: RwLock::new(DataFrame { columns: Vec::new() }),
    })
}

// Read operation - multiple concurrent readers allowed
#[rustler::nif]
fn df_shape(df: ResourceArc<DataFrameResource>) -> Result<(usize, usize), Atom> {
    let guard = df.inner.try_read().ok_or(atoms::lock_fail())?;
    let rows = guard.columns.first().map(|c| c.data.len()).unwrap_or(0);
    let cols = guard.columns.len();
    Ok((rows, cols))
}

// Read operation
#[rustler::nif]
fn df_column_names(df: ResourceArc<DataFrameResource>) -> Result<Vec<String>, Atom> {
    let guard = df.inner.try_read().ok_or(atoms::lock_fail())?;
    Ok(guard.columns.iter().map(|c| c.name.clone()).collect())
}

// Read operation with computation
#[rustler::nif(schedule = "DirtyCpu")]
fn df_sum(df: ResourceArc<DataFrameResource>, column: String) -> Result<Option<f64>, Atom> {
    let guard = df.inner.try_read().ok_or(atoms::lock_fail())?;

    Ok(guard.columns.iter()
        .find(|c| c.name == column)
        .map(|c| c.data.iter().sum()))
}

// Write operation - exclusive access
#[rustler::nif]
fn df_add_column(
    df: ResourceArc<DataFrameResource>,
    name: String,
    data: Vec<f64>,
) -> Result<usize, Atom> {
    let mut guard = df.inner.try_write().ok_or(atoms::lock_fail())?;

    // Validate length
    if let Some(first) = guard.columns.first() {
        if first.data.len() != data.len() {
            return Err(atoms::error());
        }
    }

    guard.columns.push(Column { name, data });
    Ok(guard.columns.len())  // Return new column count
}

// Heavy computation with parallel processing
#[rustler::nif(schedule = "DirtyCpu")]
fn df_mean(df: ResourceArc<DataFrameResource>, column: String) -> Result<Option<f64>, Atom> {
    let guard = df.inner.try_read().ok_or(atoms::lock_fail())?;

    Ok(guard.columns.iter()
        .find(|c| c.name == column)
        .map(|c| {
            if c.data.is_empty() {
                0.0
            } else {
                c.data.iter().sum::<f64>() / c.data.len() as f64
            }
        }))
}

rustler::init!("Elixir.MyApp.DataFrame");
```

---

## 16. Parallel Processing with Rayon

### Rust Code
```rust
use rayon::prelude::*;
use rustler::{Env, Binary, OwnedBinary};

// Parallel sum using rayon
#[rustler::nif(schedule = "DirtyCpu")]
fn parallel_sum(data: Vec<i64>) -> i64 {
    data.par_iter().sum()
}

// Parallel map
#[rustler::nif(schedule = "DirtyCpu")]
fn parallel_square(data: Vec<i64>) -> Vec<i64> {
    data.par_iter().map(|x| x * x).collect()
}

// Parallel filter
#[rustler::nif(schedule = "DirtyCpu")]
fn parallel_filter_positive(data: Vec<i64>) -> Vec<i64> {
    data.par_iter()
        .filter(|&&x| x > 0)
        .copied()
        .collect()
}

// Parallel reduce with custom operation
#[rustler::nif(schedule = "DirtyCpu")]
fn parallel_max(data: Vec<i64>) -> Option<i64> {
    data.par_iter().copied().reduce_with(|a, b| a.max(b))
}

// Parallel binary processing
#[rustler::nif(schedule = "DirtyCpu")]
fn parallel_xor(env: Env, data: Binary, key: u8) -> Binary {
    let result: Vec<u8> = data.as_slice()
        .par_iter()
        .map(|&b| b ^ key)
        .collect();

    let mut binary = OwnedBinary::new(result.len()).unwrap();
    binary.as_mut_slice().copy_from_slice(&result);
    binary.release(env)
}

// Parallel sort
#[rustler::nif(schedule = "DirtyCpu")]
fn parallel_sort(mut data: Vec<i64>) -> Vec<i64> {
    data.par_sort();
    data
}

// Parallel word count
#[rustler::nif(schedule = "DirtyCpu")]
fn parallel_word_count(texts: Vec<String>) -> usize {
    texts.par_iter()
        .map(|s| s.split_whitespace().count())
        .sum()
}

rustler::init!("Elixir.MyApp.Parallel");
```

### Elixir Module
```elixir
defmodule MyApp.Parallel do
  use Rustler, otp_app: :my_app, crate: "parallel_nif"

  def parallel_sum(_data), do: :erlang.nif_error(:nif_not_loaded)
  def parallel_square(_data), do: :erlang.nif_error(:nif_not_loaded)
  def parallel_filter_positive(_data), do: :erlang.nif_error(:nif_not_loaded)
  def parallel_max(_data), do: :erlang.nif_error(:nif_not_loaded)
  def parallel_xor(_data, _key), do: :erlang.nif_error(:nif_not_loaded)
  def parallel_sort(_data), do: :erlang.nif_error(:nif_not_loaded)
  def parallel_word_count(_texts), do: :erlang.nif_error(:nif_not_loaded)
end
```

---

## 17. Anti-Patterns and Fixes

### Anti-Pattern 1: Blocking the Scheduler

```rust
// BAD: Long operation on normal scheduler
#[rustler::nif]
fn bad_heavy_compute(n: u64) -> u64 {
    // This blocks the BEAM scheduler!
    (0..n).map(|i| i * i).sum()
}

// GOOD: Use dirty scheduler
#[rustler::nif(schedule = "DirtyCpu")]
fn good_heavy_compute(n: u64) -> u64 {
    (0..n).map(|i| i * i).sum()
}
```

### Anti-Pattern 2: Panic Crashing BEAM

```rust
// BAD: Unwrap can panic and crash the BEAM
#[rustler::nif]
fn bad_parse(input: String) -> i64 {
    input.parse().unwrap()  // PANIC if invalid!
}

// GOOD: Return Result
#[rustler::nif]
fn good_parse(input: String) -> Result<i64, String> {
    input.parse()
        .map_err(|e: std::num::ParseIntError| e.to_string())
}
```

### Anti-Pattern 3: Deadlock with lock()

```rust
// BAD: Blocking lock can deadlock
#[rustler::nif]
fn bad_increment(counter: ResourceArc<Counter>) -> i64 {
    let mut value = counter.value.lock().unwrap();  // Can block forever!
    *value += 1;
    *value
}

// GOOD: Try lock with error return
#[rustler::nif]
fn good_increment(counter: ResourceArc<Counter>) -> Result<i64, Atom> {
    match counter.value.try_lock() {
        Some(mut value) => {
            *value += 1;
            Ok(*value)
        }
        None => Err(atoms::lock_fail()),
    }
}
```

### Anti-Pattern 4: Memory Leak with Resources

```rust
// BAD: Creating resources in hot path without cleanup
#[rustler::nif]
fn bad_temp_resource() -> ResourceArc<LargeData> {
    // New resource every call - garbage collected eventually
    // but can cause memory pressure
    ResourceArc::new(LargeData::new())
}

// GOOD: Reuse resources, explicit cleanup
#[rustler::nif]
fn process_data(data: ResourceArc<LargeData>) -> i64 {
    // Work with existing resource
    data.compute()
}
```

### Anti-Pattern 5: Inefficient Type Conversion

```rust
// BAD: Converting binary to String (allocates, validates UTF-8)
#[rustler::nif]
fn bad_process_bytes(data: String) -> usize {
    data.len()
}

// GOOD: Use Binary for raw bytes (zero-copy)
#[rustler::nif]
fn good_process_bytes(data: Binary) -> usize {
    data.len()
}
```

### Anti-Pattern 6: send_and_clear on BEAM Thread

```rust
// BAD: This PANICS on BEAM-managed thread
#[rustler::nif]
fn bad_send(env: Env, message: String) {
    let pid = env.pid();
    let mut owned = OwnedEnv::new();
    // PANIC! Can't use send_and_clear from NIF directly
    owned.send_and_clear(&pid, |e| message.encode(e));
}

// GOOD: Only use OwnedEnv in spawned threads
#[rustler::nif]
fn good_send(env: Env, message: String) {
    let pid = env.pid();
    std::thread::spawn(move || {
        let mut owned = OwnedEnv::new();
        let _ = owned.send_and_clear(&pid, |e| message.encode(e));
    });
}

// BETTER: Use env.send() directly in NIF
#[rustler::nif]
fn best_send(env: Env, message: String) -> rustler::Atom {
    let pid = env.pid();
    let _ = env.send(&pid, message.encode(env));
    atoms::ok()
}
```

---

## 18. Complete Testing Pattern

### Rust Unit Tests (native/my_nif/src/lib.rs)
```rust
// Non-NIF functions can be unit tested in Rust
fn compute_hash(data: &[u8]) -> u64 {
    let mut hash: u64 = 0;
    for &byte in data {
        hash = hash.wrapping_mul(31).wrapping_add(byte as u64);
    }
    hash
}

fn validate_score(score: f64) -> Result<f64, &'static str> {
    if score.is_nan() {
        Err("score is NaN")
    } else if score.is_infinite() {
        Err("score is infinite")
    } else {
        Ok(score)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compute_hash() {
        assert_eq!(compute_hash(b""), 0);
        assert_eq!(compute_hash(b"a"), 97);
        assert_eq!(compute_hash(b"ab"), 97 * 31 + 98);
    }

    #[test]
    fn test_validate_score() {
        assert!(validate_score(1.0).is_ok());
        assert!(validate_score(f64::NAN).is_err());
        assert!(validate_score(f64::INFINITY).is_err());
    }

    #[test]
    fn test_hash_consistency() {
        let data = b"test data";
        assert_eq!(compute_hash(data), compute_hash(data));
    }
}
```

### Run Rust Tests
```bash
cd native/my_nif
cargo test
cargo test -- --nocapture  # Show println! output
```

### Elixir ExUnit Integration Tests
```elixir
# test/my_nif_test.exs
defmodule MyNifTest do
  use ExUnit.Case, async: true

  describe "Math NIF" do
    test "add/2 adds two numbers" do
      assert MyApp.Math.add(2, 3) == 5
      assert MyApp.Math.add(-1, 1) == 0
      assert MyApp.Math.add(0, 0) == 0
    end

    test "factorial/1 computes factorial" do
      assert MyApp.Math.factorial(0) == 1
      assert MyApp.Math.factorial(5) == 120
      assert MyApp.Math.factorial(20) == 2_432_902_008_176_640_000
    end
  end

  describe "SafeMath NIF" do
    test "safe_divide/2 returns ok tuple" do
      assert {:ok, 5} = MyApp.SafeMath.safe_divide(10, 2)
    end

    test "safe_divide/2 handles division by zero" do
      assert {:error, :invalid_input} = MyApp.SafeMath.safe_divide(10, 0)
    end
  end

  describe "Counter ResourceArc" do
    test "counter maintains state" do
      counter = MyApp.Counter.counter_new()
      assert MyApp.Counter.counter_get(counter) == 0
      assert MyApp.Counter.counter_increment(counter) == 1
      assert MyApp.Counter.counter_increment(counter) == 2
      assert MyApp.Counter.counter_get(counter) == 2
    end

    test "counter is isolated per instance" do
      c1 = MyApp.Counter.counter_new()
      c2 = MyApp.Counter.counter_new()

      MyApp.Counter.counter_add(c1, 10)
      MyApp.Counter.counter_add(c2, 20)

      assert MyApp.Counter.counter_get(c1) == 10
      assert MyApp.Counter.counter_get(c2) == 20
    end
  end

  describe "Async NIF" do
    test "async_compute sends result to caller" do
      assert :ok = MyApp.Async.async_compute(5)

      assert_receive {:async_result, result}, 1000
      assert result == 25
    end

    test "spawn_computation handles errors" do
      assert :ok = MyApp.ThreadSpawn.spawn_computation(-1)

      assert_receive {:error, message}, 1000
      assert message =~ "non-negative"
    end
  end

  describe "Messaging NIF" do
    test "notify_caller sends message" do
      assert :ok = MyApp.Messaging.notify_caller("test message")

      assert_receive {:notification, "test message"}
    end

    test "send_to_pid sends to specific process" do
      parent = self()

      child = spawn(fn ->
        receive do
          {:notification, msg} -> send(parent, {:got, msg})
        end
      end)

      assert :ok = MyApp.Messaging.send_to_pid(child, "hello child")

      assert_receive {:got, "hello child"}, 1000
    end
  end
end
```

### Run Elixir Tests
```bash
mix test
mix test test/my_nif_test.exs
mix test --trace  # Verbose output
```

### Benchmarking with Benchee
```elixir
# bench/nif_bench.exs
Benchee.run(
  %{
    "Elixir Enum.sum" => fn input -> Enum.sum(input) end,
    "Rust parallel_sum" => fn input -> MyApp.Parallel.parallel_sum(input) end,
  },
  inputs: %{
    "small (1K)" => Enum.to_list(1..1_000),
    "medium (100K)" => Enum.to_list(1..100_000),
    "large (1M)" => Enum.to_list(1..1_000_000),
  },
  time: 5,
  memory_time: 2
)
```

### Run Benchmarks
```bash
# Development
mix run bench/nif_bench.exs

# Release (recommended for accurate results)
MIX_ENV=prod mix compile
MIX_ENV=prod mix run bench/nif_bench.exs
```

### Release vs Debug Testing
```bash
# Test debug build
cd native/my_nif && cargo build
cd ../.. && mix test

# Test release build
cd native/my_nif && cargo build --release
cd ../.. && MIX_ENV=prod mix compile
MIX_ENV=prod mix test
```

---

## 19. Channel-Based Pipeline Processing

Multi-stage async processing using channels (CSP model).

### Rust Code
```rust
use rustler::{Env, Atom, Encoder};
use rustler::env::OwnedEnv;
use std::sync::mpsc;
use std::thread;

mod atoms {
    rustler::atoms! {
        ok,
        pipeline_complete,
        stage_update,
    }
}

/// Multi-stage pipeline: transform -> filter -> aggregate
#[rustler::nif]
fn pipeline_process(env: Env, inputs: Vec<i64>, threshold: i64) -> Atom {
    let pid = env.pid();

    // Stage 1 -> Stage 2 channel
    let (tx1, rx1) = mpsc::channel::<i64>();
    // Stage 2 -> Stage 3 channel
    let (tx2, rx2) = mpsc::channel::<i64>();

    // Stage 1: Transform (square each value)
    thread::spawn(move || {
        for item in inputs {
            let transformed = item * item;
            let _ = tx1.send(transformed);
        }
    });

    // Stage 2: Filter (keep values above threshold)
    let threshold_copy = threshold;
    thread::spawn(move || {
        for item in rx1 {
            if item > threshold_copy {
                let _ = tx2.send(item);
            }
        }
    });

    // Stage 3: Aggregate and send result
    thread::spawn(move || {
        let results: Vec<i64> = rx2.iter().collect();
        let sum: i64 = results.iter().sum();

        let mut owned_env = OwnedEnv::new();
        let _ = owned_env.send_and_clear(&pid, |env| {
            (atoms::pipeline_complete(), sum, results.len()).encode(env)
        });
    });

    atoms::ok()
}

rustler::init!("Elixir.MyApp.Pipeline");
```

### Elixir Usage
```elixir
defmodule MyApp.Pipeline do
  use Rustler, otp_app: :my_app, crate: "pipeline_nif"

  def pipeline_process(_inputs, _threshold), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> MyApp.Pipeline.pipeline_process([1, 2, 3, 4, 5], 5)
:ok
iex> receive do msg -> msg end
{:pipeline_complete, 66, 4}  # 4+9+16+25 = 54, but 1 filtered out
```

---

## 20. Scoped Thread Parallel Processing

Parallel chunk processing with deterministic cleanup.

### Rust Code
```rust
use rustler::Atom;
use std::thread;
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
    }
}

/// Parallel processing using scoped threads
/// No 'static required - threads are joined before returning
#[rustler::nif(schedule = "DirtyCpu")]
fn parallel_map_reduce(data: Vec<i64>, chunk_size: usize) -> i64 {
    let results = Mutex::new(Vec::new());

    thread::scope(|s| {
        for chunk in data.chunks(chunk_size) {
            s.spawn(|| {
                // Process chunk: sum of squares
                let chunk_result: i64 = chunk.iter()
                    .map(|x| x * x)
                    .sum();

                results.lock().unwrap().push(chunk_result);
            });
        }
    }); // All threads joined here automatically

    // Aggregate results
    results.into_inner().unwrap().iter().sum()
}

/// Parallel search with early exit
#[rustler::nif(schedule = "DirtyCpu")]
fn parallel_find(data: Vec<i64>, target: i64) -> Option<usize> {
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    let found = AtomicBool::new(false);
    let found_index = AtomicUsize::new(usize::MAX);
    let chunk_size = (data.len() / 4).max(1);

    thread::scope(|s| {
        for (chunk_idx, chunk) in data.chunks(chunk_size).enumerate() {
            let found_ref = &found;
            let found_index_ref = &found_index;

            s.spawn(move || {
                for (i, &val) in chunk.iter().enumerate() {
                    // Check if another thread found it
                    if found_ref.load(Ordering::Relaxed) {
                        return;
                    }

                    if val == target {
                        let global_idx = chunk_idx * chunk_size + i;
                        found_index_ref.store(global_idx, Ordering::Relaxed);
                        found_ref.store(true, Ordering::Relaxed);
                        return;
                    }
                }
            });
        }
    });

    let idx = found_index.load(Ordering::Relaxed);
    if idx == usize::MAX { None } else { Some(idx) }
}

rustler::init!("Elixir.MyApp.ParallelOps");
```

### Elixir Usage
```elixir
defmodule MyApp.ParallelOps do
  use Rustler, otp_app: :my_app, crate: "parallel_ops_nif"

  def parallel_map_reduce(_data, _chunk_size), do: :erlang.nif_error(:nif_not_loaded)
  def parallel_find(_data, _target), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> MyApp.ParallelOps.parallel_map_reduce([1, 2, 3, 4, 5, 6, 7, 8], 2)
204  # 1+4 + 9+16 + 25+36 + 49+64

iex> MyApp.ParallelOps.parallel_find(Enum.to_list(1..1_000_000), 500_000)
{:ok, 499999}  # 0-indexed
```

---

## 21. Lazy Initialization with OnceCell

Expensive resource initialization that happens only once.

### Rust Code
```rust
use rustler::{ResourceArc, Atom};
use once_cell::sync::OnceCell;
use parking_lot::Mutex;
use std::collections::HashMap;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        not_initialized,
    }
}

/// Expensive configuration that should only load once
struct ExpensiveConfig {
    settings: HashMap<String, String>,
    lookup_table: Vec<i64>,
}

impl ExpensiveConfig {
    fn load() -> Self {
        // Simulate expensive initialization
        std::thread::sleep(std::time::Duration::from_millis(100));

        let mut settings = HashMap::new();
        settings.insert("version".to_string(), "1.0".to_string());
        settings.insert("mode".to_string(), "production".to_string());

        let lookup_table: Vec<i64> = (0..10000).map(|i| i * i).collect();

        ExpensiveConfig { settings, lookup_table }
    }
}

struct ConfigResource {
    config: OnceCell<ExpensiveConfig>,
    access_count: Mutex<u64>,
}

#[rustler::resource_impl]
impl rustler::Resource for ConfigResource {}

#[rustler::nif]
fn create_config_resource() -> ResourceArc<ConfigResource> {
    ResourceArc::new(ConfigResource {
        config: OnceCell::new(),
        access_count: Mutex::new(0),
    })
}

/// First call initializes; subsequent calls return cached config
#[rustler::nif]
fn get_setting(res: ResourceArc<ConfigResource>, key: String) -> Result<String, Atom> {
    // Lazy initialization - only happens on first access
    let config = res.config.get_or_init(|| ExpensiveConfig::load());

    // Track access count
    *res.access_count.lock() += 1;

    config.settings.get(&key)
        .cloned()
        .ok_or(atoms::not_initialized())
}

#[rustler::nif]
fn lookup_value(res: ResourceArc<ConfigResource>, index: usize) -> Result<i64, Atom> {
    let config = res.config.get_or_init(|| ExpensiveConfig::load());

    *res.access_count.lock() += 1;

    config.lookup_table.get(index)
        .copied()
        .ok_or(atoms::error())
}

#[rustler::nif]
fn get_access_count(res: ResourceArc<ConfigResource>) -> u64 {
    *res.access_count.lock()
}

rustler::init!("Elixir.MyApp.LazyConfig");
```

### Elixir Usage
```elixir
defmodule MyApp.LazyConfig do
  use Rustler, otp_app: :my_app, crate: "lazy_config_nif"

  def create_config_resource(), do: :erlang.nif_error(:nif_not_loaded)
  def get_setting(_res, _key), do: :erlang.nif_error(:nif_not_loaded)
  def lookup_value(_res, _index), do: :erlang.nif_error(:nif_not_loaded)
  def get_access_count(_res), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> config = MyApp.LazyConfig.create_config_resource()
# First access triggers initialization (takes ~100ms)
iex> MyApp.LazyConfig.get_setting(config, "version")
{:ok, "1.0"}
# Subsequent accesses are instant (cached)
iex> MyApp.LazyConfig.get_setting(config, "mode")
{:ok, "production"}
iex> MyApp.LazyConfig.lookup_value(config, 100)
{:ok, 10000}
iex> MyApp.LazyConfig.get_access_count(config)
3
```

---

## 22. Ring Buffer with VecDeque

Event buffer with fixed capacity for sliding window calculations.

### Rust Code
```rust
use rustler::{Atom, ResourceArc};
use parking_lot::Mutex;
use std::collections::VecDeque;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        lock_fail,
        empty,
    }
}

#[derive(Clone)]
struct Event {
    timestamp: u64,
    value: f64,
    tag: String,
}

struct EventBuffer {
    events: Mutex<VecDeque<Event>>,
    capacity: usize,
}

#[rustler::resource_impl]
impl rustler::Resource for EventBuffer {}

#[rustler::nif]
fn buffer_new(capacity: usize) -> ResourceArc<EventBuffer> {
    ResourceArc::new(EventBuffer {
        events: Mutex::new(VecDeque::with_capacity(capacity)),
        capacity,
    })
}

#[rustler::nif]
fn buffer_push(
    buffer: ResourceArc<EventBuffer>,
    timestamp: u64,
    value: f64,
    tag: String,
) -> Result<usize, Atom> {
    let mut events = buffer.events.try_lock().ok_or(atoms::lock_fail())?;

    // Remove oldest if at capacity
    if events.len() >= buffer.capacity {
        events.pop_front();
    }

    events.push_back(Event { timestamp, value, tag });
    Ok(events.len())  // Return current buffer size
}

#[rustler::nif]
fn buffer_get_recent(
    buffer: ResourceArc<EventBuffer>,
    count: usize,
) -> Result<Vec<(u64, f64, String)>, Atom> {
    let events = buffer.events.try_lock().ok_or(atoms::lock_fail())?;

    Ok(events.iter()
        .rev()
        .take(count)
        .map(|e| (e.timestamp, e.value, e.tag.clone()))
        .collect())
}

#[rustler::nif]
fn buffer_sliding_average(
    buffer: ResourceArc<EventBuffer>,
    window: usize,
) -> Result<Option<f64>, Atom> {
    let events = buffer.events.try_lock().ok_or(atoms::lock_fail())?;

    if events.is_empty() {
        return Ok(None);
    }

    let values: Vec<f64> = events.iter()
        .rev()
        .take(window)
        .map(|e| e.value)
        .collect();

    let avg = values.iter().sum::<f64>() / values.len() as f64;
    Ok(Some(avg))
}

#[rustler::nif]
fn buffer_size(buffer: ResourceArc<EventBuffer>) -> Result<usize, Atom> {
    let events = buffer.events.try_lock().ok_or(atoms::lock_fail())?;
    Ok(events.len())
}

rustler::init!("Elixir.MyApp.EventBuffer");
```

### Elixir Usage
```elixir
defmodule MyApp.EventBuffer do
  use Rustler, otp_app: :my_app, crate: "event_buffer_nif"

  def buffer_new(_capacity), do: :erlang.nif_error(:nif_not_loaded)
  def buffer_push(_buffer, _ts, _val, _tag), do: :erlang.nif_error(:nif_not_loaded)
  def buffer_get_recent(_buffer, _count), do: :erlang.nif_error(:nif_not_loaded)
  def buffer_sliding_average(_buffer, _window), do: :erlang.nif_error(:nif_not_loaded)
  def buffer_size(_buffer), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> buf = MyApp.EventBuffer.buffer_new(100)
iex> MyApp.EventBuffer.buffer_push(buf, 1000, 42.5, "sensor_a")
{:ok, 1}
iex> MyApp.EventBuffer.buffer_push(buf, 1001, 43.2, "sensor_a")
{:ok, 2}
iex> MyApp.EventBuffer.buffer_sliding_average(buf, 10)
{:ok, 42.85}
```

---

## 23. Handle Pool with Slab

Connection/resource pool with handle-based access.

### Rust Code
```rust
use rustler::{Atom, ResourceArc};
use parking_lot::RwLock;
use slab::Slab;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        not_found,
        lock_fail,
    }
}

#[derive(Clone)]
struct Connection {
    id: String,
    host: String,
    port: u16,
    active: bool,
}

struct ConnectionPool {
    connections: RwLock<Slab<Connection>>,
}

#[rustler::resource_impl]
impl rustler::Resource for ConnectionPool {}

#[rustler::nif]
fn pool_new() -> ResourceArc<ConnectionPool> {
    ResourceArc::new(ConnectionPool {
        connections: RwLock::new(Slab::new()),
    })
}

/// Returns handle (usize) for the new connection
#[rustler::nif]
fn pool_create_connection(
    pool: ResourceArc<ConnectionPool>,
    id: String,
    host: String,
    port: u16,
) -> Result<usize, Atom> {
    let mut conns = pool.connections.try_write().ok_or(atoms::lock_fail())?;

    let conn = Connection {
        id,
        host,
        port,
        active: true,
    };

    let handle = conns.insert(conn);
    Ok(handle)
}

/// Get connection info by handle
#[rustler::nif]
fn pool_get_connection(
    pool: ResourceArc<ConnectionPool>,
    handle: usize,
) -> Result<(String, String, u16, bool), Atom> {
    let conns = pool.connections.try_read().ok_or(atoms::lock_fail())?;

    conns.get(handle)
        .map(|c| (c.id.clone(), c.host.clone(), c.port, c.active))
        .ok_or(atoms::not_found())
}

/// Remove connection by handle
#[rustler::nif]
fn pool_remove_connection(
    pool: ResourceArc<ConnectionPool>,
    handle: usize,
) -> Result<bool, Atom> {
    let mut conns = pool.connections.try_write().ok_or(atoms::lock_fail())?;

    if conns.contains(handle) {
        conns.remove(handle);
        Ok(true)
    } else {
        Ok(false)
    }
}

/// List all active handles
#[rustler::nif]
fn pool_list_handles(pool: ResourceArc<ConnectionPool>) -> Result<Vec<usize>, Atom> {
    let conns = pool.connections.try_read().ok_or(atoms::lock_fail())?;

    Ok(conns.iter().map(|(key, _)| key).collect())
}

/// Get pool size
#[rustler::nif]
fn pool_size(pool: ResourceArc<ConnectionPool>) -> Result<usize, Atom> {
    let conns = pool.connections.try_read().ok_or(atoms::lock_fail())?;
    Ok(conns.len())
}

rustler::init!("Elixir.MyApp.ConnectionPool");
```

### Elixir Usage
```elixir
defmodule MyApp.ConnectionPool do
  use Rustler, otp_app: :my_app, crate: "connection_pool_nif"

  def pool_new(), do: :erlang.nif_error(:nif_not_loaded)
  def pool_create_connection(_pool, _id, _host, _port), do: :erlang.nif_error(:nif_not_loaded)
  def pool_get_connection(_pool, _handle), do: :erlang.nif_error(:nif_not_loaded)
  def pool_remove_connection(_pool, _handle), do: :erlang.nif_error(:nif_not_loaded)
  def pool_list_handles(_pool), do: :erlang.nif_error(:nif_not_loaded)
  def pool_size(_pool), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> pool = MyApp.ConnectionPool.pool_new()
iex> {:ok, h1} = MyApp.ConnectionPool.pool_create_connection(pool, "db1", "localhost", 5432)
{:ok, 0}
iex> {:ok, h2} = MyApp.ConnectionPool.pool_create_connection(pool, "db2", "localhost", 5433)
{:ok, 1}
iex> MyApp.ConnectionPool.pool_get_connection(pool, h1)
{:ok, {"db1", "localhost", 5432, true}}
iex> MyApp.ConnectionPool.pool_list_handles(pool)
{:ok, [0, 1]}
```

---

## 24. Binary Protocol Handler

Parsing and creating binary packets with byteorder.

### Rust Code
```rust
use rustler::{Atom, Binary, OwnedBinary, Env};
use byteorder::{BigEndian, LittleEndian, ReadBytesExt, WriteBytesExt};
use std::io::Cursor;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_magic,
        truncated,
    }
}

const MAGIC: u32 = 0xDEADBEEF;

/// Packet format:
/// - Magic: u32 BE (4 bytes)
/// - Version: u16 LE (2 bytes)
/// - Flags: u8 (1 byte)
/// - Payload length: u32 BE (4 bytes)
/// - Payload: variable

#[derive(rustler::NifMap)]
struct PacketHeader {
    version: u16,
    flags: u8,
    payload_length: u32,
}

#[rustler::nif]
fn parse_packet_header(data: Binary) -> Result<PacketHeader, Atom> {
    let slice = data.as_slice();
    if slice.len() < 11 {
        return Err(atoms::truncated());
    }

    let mut cursor = Cursor::new(slice);

    let magic = cursor.read_u32::<BigEndian>()
        .map_err(|_| atoms::truncated())?;

    if magic != MAGIC {
        return Err(atoms::invalid_magic());
    }

    let version = cursor.read_u16::<LittleEndian>()
        .map_err(|_| atoms::truncated())?;
    let flags = cursor.read_u8()
        .map_err(|_| atoms::truncated())?;
    let payload_length = cursor.read_u32::<BigEndian>()
        .map_err(|_| atoms::truncated())?;

    Ok(PacketHeader {
        version,
        flags,
        payload_length,
    })
}

#[rustler::nif]
fn create_packet(env: Env, version: u16, flags: u8, payload: Binary) -> Binary {
    let payload_len = payload.len() as u32;
    let total_len = 11 + payload.len();

    let mut buffer = Vec::with_capacity(total_len);

    buffer.write_u32::<BigEndian>(MAGIC).unwrap();
    buffer.write_u16::<LittleEndian>(version).unwrap();
    buffer.write_u8(flags).unwrap();
    buffer.write_u32::<BigEndian>(payload_len).unwrap();
    buffer.extend_from_slice(payload.as_slice());

    let mut binary = OwnedBinary::new(buffer.len()).unwrap();
    binary.as_mut_slice().copy_from_slice(&buffer);
    binary.release(env)
}

#[rustler::nif]
fn extract_payload(data: Binary) -> Result<Vec<u8>, Atom> {
    let slice = data.as_slice();
    if slice.len() < 11 {
        return Err(atoms::truncated());
    }

    let mut cursor = Cursor::new(slice);
    cursor.set_position(7); // Skip magic, version, flags

    let payload_length = cursor.read_u32::<BigEndian>()
        .map_err(|_| atoms::truncated())? as usize;

    let payload_start = 11;
    let payload_end = payload_start + payload_length;

    if slice.len() < payload_end {
        return Err(atoms::truncated());
    }

    Ok(slice[payload_start..payload_end].to_vec())
}

rustler::init!("Elixir.MyApp.BinaryProtocol");
```

### Elixir Usage
```elixir
defmodule MyApp.BinaryProtocol do
  use Rustler, otp_app: :my_app, crate: "binary_protocol_nif"

  def parse_packet_header(_data), do: :erlang.nif_error(:nif_not_loaded)
  def create_packet(_version, _flags, _payload), do: :erlang.nif_error(:nif_not_loaded)
  def extract_payload(_data), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> packet = MyApp.BinaryProtocol.create_packet(1, 0x03, "Hello")
<<222, 173, 190, 239, 1, 0, 3, 0, 0, 0, 5, 72, 101, 108, 108, 111>>
iex> MyApp.BinaryProtocol.parse_packet_header(packet)
{:ok, %{version: 1, flags: 3, payload_length: 5}}
iex> MyApp.BinaryProtocol.extract_payload(packet)
{:ok, [72, 101, 108, 108, 111]}  # "Hello"
```

---

## 25. Compression NIF

Gzip compression and decompression.

### Rust Code
```rust
use rustler::{Atom, Binary, OwnedBinary, Env};
use flate2::Compression;
use flate2::write::GzEncoder;
use flate2::read::GzDecoder;
use std::io::{Write, Read};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        compression_failed,
        decompression_failed,
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn gzip_compress(env: Env, data: Binary) -> Result<Binary, Atom> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());

    encoder.write_all(data.as_slice())
        .map_err(|_| atoms::compression_failed())?;

    let compressed = encoder.finish()
        .map_err(|_| atoms::compression_failed())?;

    let mut binary = OwnedBinary::new(compressed.len())
        .ok_or(atoms::error())?;
    binary.as_mut_slice().copy_from_slice(&compressed);

    Ok(binary.release(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn gzip_compress_level(env: Env, data: Binary, level: u32) -> Result<Binary, Atom> {
    let level = Compression::new(level.min(9));
    let mut encoder = GzEncoder::new(Vec::new(), level);

    encoder.write_all(data.as_slice())
        .map_err(|_| atoms::compression_failed())?;

    let compressed = encoder.finish()
        .map_err(|_| atoms::compression_failed())?;

    let mut binary = OwnedBinary::new(compressed.len())
        .ok_or(atoms::error())?;
    binary.as_mut_slice().copy_from_slice(&compressed);

    Ok(binary.release(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn gzip_decompress(env: Env, data: Binary) -> Result<Binary, Atom> {
    let mut decoder = GzDecoder::new(data.as_slice());
    let mut decompressed = Vec::new();

    decoder.read_to_end(&mut decompressed)
        .map_err(|_| atoms::decompression_failed())?;

    let mut binary = OwnedBinary::new(decompressed.len())
        .ok_or(atoms::error())?;
    binary.as_mut_slice().copy_from_slice(&decompressed);

    Ok(binary.release(env))
}

#[rustler::nif]
fn compression_ratio(original: Binary, compressed: Binary) -> f64 {
    if original.len() == 0 {
        return 0.0;
    }
    1.0 - (compressed.len() as f64 / original.len() as f64)
}

rustler::init!("Elixir.MyApp.Compression");
```

### Elixir Usage
```elixir
defmodule MyApp.Compression do
  use Rustler, otp_app: :my_app, crate: "compression_nif"

  def gzip_compress(_data), do: :erlang.nif_error(:nif_not_loaded)
  def gzip_compress_level(_data, _level), do: :erlang.nif_error(:nif_not_loaded)
  def gzip_decompress(_data), do: :erlang.nif_error(:nif_not_loaded)
  def compression_ratio(_original, _compressed), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> data = String.duplicate("Hello World! ", 1000)
iex> {:ok, compressed} = MyApp.Compression.gzip_compress(data)
iex> byte_size(data)
13000
iex> byte_size(compressed)
68
iex> MyApp.Compression.compression_ratio(data, compressed)
0.9947692307692308
iex> {:ok, decompressed} = MyApp.Compression.gzip_decompress(compressed)
iex> decompressed == data
true
```

---

## 26. Bitflags Permission System

C-compatible bitflags for permission management.

### Rust Code
```rust
use rustler::Atom;
use bitflags::bitflags;

mod atoms {
    rustler::atoms! {
        ok,
        read,
        write,
        execute,
        admin,
    }
}

bitflags! {
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
    pub struct Permissions: u32 {
        const READ    = 0b00000001;
        const WRITE   = 0b00000010;
        const EXECUTE = 0b00000100;
        const ADMIN   = 0b00001000;

        const READ_WRITE = Self::READ.bits() | Self::WRITE.bits();
        const ALL = Self::READ.bits() | Self::WRITE.bits() |
                    Self::EXECUTE.bits() | Self::ADMIN.bits();
    }
}

#[rustler::nif]
fn permissions_new() -> u32 {
    Permissions::empty().bits()
}

#[rustler::nif]
fn permissions_all() -> u32 {
    Permissions::ALL.bits()
}

#[rustler::nif]
fn permissions_add(current: u32, add: u32) -> u32 {
    let mut perms = Permissions::from_bits_truncate(current);
    let to_add = Permissions::from_bits_truncate(add);
    perms.insert(to_add);
    perms.bits()
}

#[rustler::nif]
fn permissions_remove(current: u32, remove: u32) -> u32 {
    let mut perms = Permissions::from_bits_truncate(current);
    let to_remove = Permissions::from_bits_truncate(remove);
    perms.remove(to_remove);
    perms.bits()
}

#[rustler::nif]
fn permissions_has(perms: u32, check: u32) -> bool {
    let perms = Permissions::from_bits_truncate(perms);
    let check = Permissions::from_bits_truncate(check);
    perms.contains(check)
}

#[rustler::nif]
fn permissions_to_list(perms: u32) -> Vec<Atom> {
    let perms = Permissions::from_bits_truncate(perms);
    let mut result = Vec::new();

    if perms.contains(Permissions::READ) {
        result.push(atoms::read());
    }
    if perms.contains(Permissions::WRITE) {
        result.push(atoms::write());
    }
    if perms.contains(Permissions::EXECUTE) {
        result.push(atoms::execute());
    }
    if perms.contains(Permissions::ADMIN) {
        result.push(atoms::admin());
    }

    result
}

#[rustler::nif]
fn permissions_from_list(list: Vec<Atom>) -> u32 {
    let mut perms = Permissions::empty();

    for atom in list {
        match atom.to_string().as_str() {
            "read" => perms.insert(Permissions::READ),
            "write" => perms.insert(Permissions::WRITE),
            "execute" => perms.insert(Permissions::EXECUTE),
            "admin" => perms.insert(Permissions::ADMIN),
            _ => {}
        }
    }

    perms.bits()
}

rustler::init!("Elixir.MyApp.Permissions");
```

### Elixir Module
```elixir
defmodule MyApp.Permissions do
  use Rustler, otp_app: :my_app, crate: "permissions_nif"

  # Permission constants
  @read 1
  @write 2
  @execute 4
  @admin 8

  def read, do: @read
  def write, do: @write
  def execute, do: @execute
  def admin, do: @admin

  def permissions_new(), do: :erlang.nif_error(:nif_not_loaded)
  def permissions_all(), do: :erlang.nif_error(:nif_not_loaded)
  def permissions_add(_current, _add), do: :erlang.nif_error(:nif_not_loaded)
  def permissions_remove(_current, _remove), do: :erlang.nif_error(:nif_not_loaded)
  def permissions_has(_perms, _check), do: :erlang.nif_error(:nif_not_loaded)
  def permissions_to_list(_perms), do: :erlang.nif_error(:nif_not_loaded)
  def permissions_from_list(_list), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> alias MyApp.Permissions
iex> p = Permissions.permissions_new()
0
iex> p = Permissions.permissions_add(p, Permissions.read() ||| Permissions.write())
3
iex> Permissions.permissions_has(p, Permissions.read())
true
iex> Permissions.permissions_has(p, Permissions.admin())
false
iex> Permissions.permissions_to_list(p)
[:read, :write]
iex> Permissions.permissions_from_list([:read, :execute])
5
```

---

## 27. Streaming Iterator

Chunked data iteration for large datasets.

### Rust Code
```rust
use rustler::{Atom, ResourceArc};
use parking_lot::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
        done,
        lock_fail,
    }
}

struct DataIterator {
    data: Vec<i64>,
    position: Mutex<usize>,
    chunk_size: usize,
}

#[rustler::resource_impl]
impl rustler::Resource for DataIterator {}

#[rustler::nif]
fn iterator_new(data: Vec<i64>, chunk_size: usize) -> ResourceArc<DataIterator> {
    ResourceArc::new(DataIterator {
        data,
        position: Mutex::new(0),
        chunk_size: chunk_size.max(1), // At least 1
    })
}

#[derive(rustler::NifTaggedEnum)]
enum IteratorResult {
    Chunk(Vec<i64>),
    Done,
}

#[rustler::nif]
fn iterator_next(iter: ResourceArc<DataIterator>) -> Result<IteratorResult, Atom> {
    let mut pos = iter.position.try_lock().ok_or(atoms::lock_fail())?;

    if *pos >= iter.data.len() {
        return Ok(IteratorResult::Done);
    }

    let end = (*pos + iter.chunk_size).min(iter.data.len());
    let chunk = iter.data[*pos..end].to_vec();
    *pos = end;

    Ok(IteratorResult::Chunk(chunk))
}

#[rustler::nif]
fn iterator_reset(iter: ResourceArc<DataIterator>) -> Result<usize, Atom> {
    let mut pos = iter.position.try_lock().ok_or(atoms::lock_fail())?;
    *pos = 0;
    Ok(iter.data.len())  // Return total remaining items
}

#[rustler::nif]
fn iterator_remaining(iter: ResourceArc<DataIterator>) -> Result<usize, Atom> {
    let pos = iter.position.try_lock().ok_or(atoms::lock_fail())?;
    Ok(iter.data.len().saturating_sub(*pos))
}

#[rustler::nif]
fn iterator_progress(iter: ResourceArc<DataIterator>) -> Result<f64, Atom> {
    let pos = iter.position.try_lock().ok_or(atoms::lock_fail())?;
    if iter.data.is_empty() {
        return Ok(1.0);
    }
    Ok(*pos as f64 / iter.data.len() as f64)
}

rustler::init!("Elixir.MyApp.DataIterator");
```

### Elixir Module with Stream
```elixir
defmodule MyApp.DataIterator do
  use Rustler, otp_app: :my_app, crate: "data_iterator_nif"

  def iterator_new(_data, _chunk_size), do: :erlang.nif_error(:nif_not_loaded)
  def iterator_next(_iter), do: :erlang.nif_error(:nif_not_loaded)
  def iterator_reset(_iter), do: :erlang.nif_error(:nif_not_loaded)
  def iterator_remaining(_iter), do: :erlang.nif_error(:nif_not_loaded)
  def iterator_progress(_iter), do: :erlang.nif_error(:nif_not_loaded)

  # Create an Elixir Stream from the iterator
  def stream(data, chunk_size \\ 100) do
    iter = iterator_new(data, chunk_size)

    Stream.resource(
      fn -> iter end,
      fn iter ->
        case iterator_next(iter) do
          {:ok, {:chunk, chunk}} -> {[chunk], iter}
          {:ok, :done} -> {:halt, iter}
          {:error, _} -> {:halt, iter}
        end
      end,
      fn _iter -> :ok end
    )
  end
end

# Usage
iex> data = Enum.to_list(1..1000)
iex> iter = MyApp.DataIterator.iterator_new(data, 100)
iex> MyApp.DataIterator.iterator_next(iter)
{:ok, {:chunk, [1, 2, 3, ..., 100]}}
iex> MyApp.DataIterator.iterator_progress(iter)
{:ok, 0.1}

# Using as a stream
iex> MyApp.DataIterator.stream(Enum.to_list(1..1000), 100)
...> |> Stream.map(&Enum.sum/1)
...> |> Enum.to_list()
[5050, 15050, 25050, 35050, 45050, 55050, 65050, 75050, 85050, 95050]
```

---

## 28. C Library Integration via FFI

Calling external C libraries from NIFs.

### Rust Code
```rust
use rustler::{Env, Binary, OwnedBinary, Atom};
use std::ffi::{CString, CStr};
use std::os::raw::{c_char, c_int};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_input,
    }
}

// Declare external C functions (example: a hypothetical compression library)
// In real usage, these would come from linking a C library
extern "C" {
    // Simulated C function declarations
    // fn compress_data(input: *const u8, input_len: usize,
    //                  output: *mut u8, output_len: *mut usize) -> c_int;
}

// For this example, we'll implement a mock "C library" in Rust
mod mock_c_lib {
    use std::os::raw::c_int;

    /// Mock C function: simple XOR "compression"
    #[no_mangle]
    pub extern "C" fn xor_transform(
        input: *const u8,
        input_len: usize,
        output: *mut u8,
        key: u8,
    ) -> c_int {
        if input.is_null() || output.is_null() {
            return -1;
        }

        unsafe {
            for i in 0..input_len {
                *output.add(i) = *input.add(i) ^ key;
            }
        }

        0 // Success
    }

    /// Mock C function: string processing
    #[no_mangle]
    pub extern "C" fn count_occurrences(
        haystack: *const std::os::raw::c_char,
        needle: std::os::raw::c_char,
    ) -> c_int {
        if haystack.is_null() {
            return -1;
        }

        let mut count = 0i32;
        let mut ptr = haystack;

        unsafe {
            while *ptr != 0 {
                if *ptr == needle {
                    count += 1;
                }
                ptr = ptr.add(1);
            }
        }

        count
    }
}

/// NIF wrapper for C XOR transform
#[rustler::nif]
fn c_xor_transform(env: Env, data: Binary, key: u8) -> Result<Binary, Atom> {
    let input = data.as_slice();
    let mut output = OwnedBinary::new(input.len())
        .ok_or(atoms::error())?;

    let result = unsafe {
        mock_c_lib::xor_transform(
            input.as_ptr(),
            input.len(),
            output.as_mut_slice().as_mut_ptr(),
            key,
        )
    };

    if result != 0 {
        return Err(atoms::error());
    }

    Ok(output.release(env))
}

/// NIF wrapper for C string processing
#[rustler::nif]
fn c_count_char(input: String, needle: u8) -> Result<i32, Atom> {
    // Convert Rust String to C string
    let c_string = CString::new(input)
        .map_err(|_| atoms::invalid_input())?;

    let count = unsafe {
        mock_c_lib::count_occurrences(
            c_string.as_ptr(),
            needle as i8,
        )
    };

    if count < 0 {
        Err(atoms::error())
    } else {
        Ok(count)
    }
}

rustler::init!("Elixir.MyApp.CLibrary");
```

### Elixir Usage
```elixir
defmodule MyApp.CLibrary do
  use Rustler, otp_app: :my_app, crate: "c_library_nif"

  def c_xor_transform(_data, _key), do: :erlang.nif_error(:nif_not_loaded)
  def c_count_char(_input, _needle), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
iex> MyApp.CLibrary.c_xor_transform(<<1, 2, 3, 4>>, 255)
{:ok, <<254, 253, 252, 251>>}

iex> MyApp.CLibrary.c_count_char("hello world", ?l)
{:ok, 3}
```

### Linking Real C Libraries

For actual C libraries, add to Cargo.toml:

```toml
[build-dependencies]
cc = "1.0"

# Or use pkg-config for system libraries
[target.'cfg(unix)'.dependencies]
zstd-sys = "2.0"
```

And create a `build.rs`:

```rust
fn main() {
    // Compile C code
    cc::Build::new()
        .file("src/c_code.c")
        .compile("mylib");

    // Or link system library
    println!("cargo:rustc-link-lib=z");  // Link libz
}
```

---

## 29. Provider Abstraction Pattern

Encapsulate configuration in a provider struct for testability.

### Rust Code
```rust
use rustler::{ResourceArc, Atom};
use parking_lot::RwLock;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        timeout,
        not_found,
    }
}

/// Provider encapsulates config - testable via field injection
pub struct DataProvider {
    pub base_url: String,  // Public for test overrides
    api_key: String,
    timeout_ms: u64,
    cache: RwLock<std::collections::HashMap<String, String>>,
}

impl DataProvider {
    pub fn new(api_key: &str) -> Self {
        Self {
            base_url: "https://api.production.example.com".into(),
            api_key: api_key.into(),
            timeout_ms: 5000,
            cache: RwLock::new(std::collections::HashMap::new()),
        }
    }

    // Builder methods for configuration
    pub fn with_base_url(mut self, url: &str) -> Self {
        self.base_url = url.into();
        self
    }

    pub fn with_timeout(mut self, ms: u64) -> Self {
        self.timeout_ms = ms;
        self
    }

    // Internal fetch logic - testable independently
    fn fetch_internal(&self, path: &str) -> Result<String, &'static str> {
        // Check cache first
        if let Some(cached) = self.cache.read().get(path) {
            return Ok(cached.clone());
        }

        // Simulate HTTP request (in real code: use reqwest)
        let url = format!("{}/{}", self.base_url, path);
        let _api_key = &self.api_key;
        let _timeout = self.timeout_ms;

        // Mock response
        let response = format!("data from {}", url);

        // Cache the result
        self.cache.write().insert(path.to_string(), response.clone());

        Ok(response)
    }
}

#[rustler::resource_impl]
impl rustler::Resource for DataProvider {}

// NIF: Create provider with production defaults
#[rustler::nif]
fn create_provider(api_key: String) -> ResourceArc<DataProvider> {
    ResourceArc::new(DataProvider::new(&api_key))
}

// NIF: Create provider with custom base URL (for testing)
#[rustler::nif]
fn create_provider_with_url(api_key: String, base_url: String) -> ResourceArc<DataProvider> {
    ResourceArc::new(
        DataProvider::new(&api_key)
            .with_base_url(&base_url)
    )
}

// NIF: Fetch data through provider
#[rustler::nif(schedule = "DirtyIo")]
fn provider_fetch(
    provider: ResourceArc<DataProvider>,
    path: String,
) -> Result<String, Atom> {
    provider.fetch_internal(&path)
        .map_err(|_| atoms::error())
}

// NIF: Check cache status
#[rustler::nif]
fn provider_cache_size(provider: ResourceArc<DataProvider>) -> usize {
    provider.cache.read().len()
}

rustler::init!("Elixir.MyApp.Provider");

// Tests with mock server injection
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_with_mock_url() {
        let provider = DataProvider::new("test-key")
            .with_base_url("http://localhost:8080/mock");

        assert_eq!(provider.base_url, "http://localhost:8080/mock");
    }

    #[test]
    fn test_caching() {
        let provider = DataProvider::new("test-key");

        // First fetch
        let result1 = provider.fetch_internal("users").unwrap();

        // Second fetch should hit cache
        let result2 = provider.fetch_internal("users").unwrap();

        assert_eq!(result1, result2);
        assert_eq!(provider.cache.read().len(), 1);
    }
}
```

### Elixir Usage
```elixir
defmodule MyApp.Provider do
  use Rustler, otp_app: :my_app, crate: "provider_nif"

  def create_provider(_api_key), do: :erlang.nif_error(:nif_not_loaded)
  def create_provider_with_url(_api_key, _base_url), do: :erlang.nif_error(:nif_not_loaded)
  def provider_fetch(_provider, _path), do: :erlang.nif_error(:nif_not_loaded)
  def provider_cache_size(_provider), do: :erlang.nif_error(:nif_not_loaded)
end

# Production usage
iex> provider = MyApp.Provider.create_provider("prod-api-key")
iex> MyApp.Provider.provider_fetch(provider, "users/123")
{:ok, "data from https://api.production.example.com/users/123"}

# Testing with mock server
iex> test_provider = MyApp.Provider.create_provider_with_url("test-key", "http://localhost:4000/mock")
iex> MyApp.Provider.provider_fetch(test_provider, "users/123")
{:ok, "data from http://localhost:4000/mock/users/123"}
```

---

## 30. Testable NIF with Function Splitting

Split NIF logic into testable components.

### Rust Code
```rust
use rustler::{Binary, Atom};

mod atoms {
    rustler::atoms! {
        ok,
        decode_error,
        transform_error,
        encode_error,
    }
}

// ============================================
// Domain types and errors
// ============================================

#[derive(Debug, Clone, PartialEq)]
struct ImageData {
    width: u32,
    height: u32,
    pixels: Vec<u8>,
}

#[derive(Debug)]
enum ImageError {
    InvalidHeader,
    InvalidDimensions,
    TruncatedData,
}

#[derive(Debug)]
enum TransformError {
    EmptyImage,
    InvalidOperation,
}

// ============================================
// Internal testable functions (pure logic)
// ============================================

/// Decode image from bytes - testable independently
fn decode_image(bytes: &[u8]) -> Result<ImageData, ImageError> {
    // Check minimum header size
    if bytes.len() < 8 {
        return Err(ImageError::InvalidHeader);
    }

    // Parse width/height from header (mock format)
    let width = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    let height = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);

    if width == 0 || height == 0 {
        return Err(ImageError::InvalidDimensions);
    }

    let expected_size = (width * height) as usize;
    let pixels = &bytes[8..];

    if pixels.len() < expected_size {
        return Err(ImageError::TruncatedData);
    }

    Ok(ImageData {
        width,
        height,
        pixels: pixels[..expected_size].to_vec(),
    })
}

/// Transform image - testable independently
fn apply_brightness(image: &ImageData, delta: i16) -> Result<ImageData, TransformError> {
    if image.pixels.is_empty() {
        return Err(TransformError::EmptyImage);
    }

    let new_pixels: Vec<u8> = image.pixels.iter()
        .map(|&p| {
            let new_val = (p as i16 + delta).clamp(0, 255);
            new_val as u8
        })
        .collect();

    Ok(ImageData {
        width: image.width,
        height: image.height,
        pixels: new_pixels,
    })
}

/// Encode image back to bytes - testable independently
fn encode_image(image: &ImageData) -> Vec<u8> {
    let mut output = Vec::with_capacity(8 + image.pixels.len());
    output.extend_from_slice(&image.width.to_le_bytes());
    output.extend_from_slice(&image.height.to_le_bytes());
    output.extend_from_slice(&image.pixels);
    output
}

// ============================================
// NIF - thin wrapper calling internal functions
// ============================================

#[rustler::nif(schedule = "DirtyCpu")]
fn process_image(data: Binary, brightness: i16) -> Result<Vec<u8>, Atom> {
    // Each step has clear error mapping
    let decoded = decode_image(data.as_slice())
        .map_err(|_| atoms::decode_error())?;

    let transformed = apply_brightness(&decoded, brightness)
        .map_err(|_| atoms::transform_error())?;

    Ok(encode_image(&transformed))
}

rustler::init!("Elixir.MyApp.Image");

// ============================================
// Comprehensive tests for each component
// ============================================

#[cfg(test)]
mod tests {
    use super::*;

    // Test data helpers
    fn make_test_image(width: u32, height: u32, fill: u8) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(&width.to_le_bytes());
        data.extend_from_slice(&height.to_le_bytes());
        data.extend(vec![fill; (width * height) as usize]);
        data
    }

    // Decode tests
    #[test]
    fn decode_valid_image() {
        let data = make_test_image(2, 2, 128);
        let img = decode_image(&data).unwrap();
        assert_eq!(img.width, 2);
        assert_eq!(img.height, 2);
        assert_eq!(img.pixels, vec![128, 128, 128, 128]);
    }

    #[test]
    fn decode_rejects_short_header() {
        let data = vec![1, 2, 3];  // Too short
        assert!(matches!(decode_image(&data), Err(ImageError::InvalidHeader)));
    }

    #[test]
    fn decode_rejects_zero_dimensions() {
        let data = make_test_image(0, 10, 0);
        assert!(matches!(decode_image(&data), Err(ImageError::InvalidDimensions)));
    }

    #[test]
    fn decode_rejects_truncated() {
        let mut data = make_test_image(10, 10, 128);
        data.truncate(20);  // Cut off pixel data
        assert!(matches!(decode_image(&data), Err(ImageError::TruncatedData)));
    }

    // Transform tests
    #[test]
    fn brightness_increases_values() {
        let img = ImageData { width: 2, height: 1, pixels: vec![100, 150] };
        let result = apply_brightness(&img, 50).unwrap();
        assert_eq!(result.pixels, vec![150, 200]);
    }

    #[test]
    fn brightness_clamps_at_max() {
        let img = ImageData { width: 2, height: 1, pixels: vec![200, 250] };
        let result = apply_brightness(&img, 100).unwrap();
        assert_eq!(result.pixels, vec![255, 255]);  // Clamped
    }

    #[test]
    fn brightness_negative_decreases() {
        let img = ImageData { width: 2, height: 1, pixels: vec![100, 50] };
        let result = apply_brightness(&img, -60).unwrap();
        assert_eq!(result.pixels, vec![40, 0]);  // 50-60 clamps to 0
    }

    // Round-trip test
    #[test]
    fn encode_decode_roundtrip() {
        let original = ImageData {
            width: 3,
            height: 2,
            pixels: vec![10, 20, 30, 40, 50, 60],
        };

        let encoded = encode_image(&original);
        let decoded = decode_image(&encoded).unwrap();

        assert_eq!(original, decoded);
    }
}
```

### Elixir Usage
```elixir
defmodule MyApp.Image do
  use Rustler, otp_app: :my_app, crate: "image_nif"

  def process_image(_data, _brightness), do: :erlang.nif_error(:nif_not_loaded)
end

# Create test image (4x4, filled with 100)
iex> data = <<4::little-32, 4::little-32>> <> :binary.copy(<<100>>, 16)
iex> {:ok, result} = MyApp.Image.process_image(data, 50)
# Pixels now 150
```

---

## 31. JSON Pointer Extraction

Extract nested values without full struct definition.

### Rust Code
```rust
use rustler::Atom;
use serde_json::Value;

mod atoms {
    rustler::atoms! {
        ok,
        json_error,
        missing_field,
    }
}

#[derive(rustler::NifMap)]
struct UserProfile {
    name: String,
    email: String,
    age: i64,
    city: String,
}

/// Extract specific fields from deeply nested JSON using JSON Pointer
#[rustler::nif]
fn extract_user_profile(json: String) -> Result<UserProfile, Atom> {
    let val: Value = serde_json::from_str(&json)
        .map_err(|_| atoms::json_error())?;

    // Use JSON Pointer syntax: /key/nested_key/array_index
    let name = val.pointer("/data/user/profile/name")
        .and_then(Value::as_str)
        .ok_or(atoms::missing_field())?
        .to_string();

    let email = val.pointer("/data/user/contact/email")
        .and_then(Value::as_str)
        .ok_or(atoms::missing_field())?
        .to_string();

    let age = val.pointer("/data/user/profile/age")
        .and_then(Value::as_i64)
        .ok_or(atoms::missing_field())?;

    // Array access with index
    let city = val.pointer("/data/user/addresses/0/city")
        .and_then(Value::as_str)
        .ok_or(atoms::missing_field())?
        .to_string();

    Ok(UserProfile { name, email, age, city })
}

/// Extract multiple values at once, with defaults
#[rustler::nif]
fn extract_with_defaults(json: String) -> Result<(String, i64, Vec<String>), Atom> {
    let val: Value = serde_json::from_str(&json)
        .map_err(|_| atoms::json_error())?;

    // Required field
    let id = val.pointer("/id")
        .and_then(Value::as_str)
        .ok_or(atoms::missing_field())?
        .to_string();

    // Optional with default
    let count = val.pointer("/stats/count")
        .and_then(Value::as_i64)
        .unwrap_or(0);

    // Extract array of strings
    let tags: Vec<String> = val.pointer("/tags")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();

    Ok((id, count, tags))
}

/// Dynamic pointer path from Elixir
#[rustler::nif]
fn get_at_path(json: String, path: String) -> Result<String, Atom> {
    let val: Value = serde_json::from_str(&json)
        .map_err(|_| atoms::json_error())?;

    val.pointer(&path)
        .map(|v| v.to_string())
        .ok_or(atoms::missing_field())
}

rustler::init!("Elixir.MyApp.JsonPointer");
```

### Elixir Usage
```elixir
defmodule MyApp.JsonPointer do
  use Rustler, otp_app: :my_app, crate: "json_pointer_nif"

  def extract_user_profile(_json), do: :erlang.nif_error(:nif_not_loaded)
  def extract_with_defaults(_json), do: :erlang.nif_error(:nif_not_loaded)
  def get_at_path(_json, _path), do: :erlang.nif_error(:nif_not_loaded)
end

# Complex nested JSON
json = ~s({
  "data": {
    "user": {
      "profile": {"name": "Alice", "age": 30},
      "contact": {"email": "alice@example.com"},
      "addresses": [{"city": "Portland"}, {"city": "Seattle"}]
    }
  }
})

iex> MyApp.JsonPointer.extract_user_profile(json)
{:ok, %{name: "Alice", email: "alice@example.com", age: 30, city: "Portland"}}

# Dynamic path
iex> MyApp.JsonPointer.get_at_path(json, "/data/user/addresses/1/city")
{:ok, "\"Seattle\""}
```

---

## 32. with_context Rich Error Handling

Build detailed error chains with context.

### Rust Code
```rust
use rustler::Atom;
use anyhow::{Context, Result, anyhow};

mod atoms {
    rustler::atoms! {
        ok,
        error,
    }
}

/// Internal function using anyhow for rich errors
fn load_and_parse_config(path: &str) -> Result<Config> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("Failed to read config file: {}", path))?;

    let config: Config = toml::from_str(&content)
        .with_context(|| format!("Failed to parse TOML in: {}", path))?;

    validate_config(&config)
        .with_context(|| format!("Config validation failed for: {}", path))?;

    Ok(config)
}

fn validate_config(config: &Config) -> Result<()> {
    if config.port == 0 {
        return Err(anyhow!("Port cannot be zero"));
    }
    if config.host.is_empty() {
        return Err(anyhow!("Host cannot be empty"));
    }
    if config.max_connections < 1 {
        return Err(anyhow!("max_connections must be at least 1"));
    }
    Ok(())
}

#[derive(Debug, serde::Deserialize)]
struct Config {
    host: String,
    port: u16,
    max_connections: u32,
}

/// NIF wrapper - converts rich error to user-friendly string
#[rustler::nif(schedule = "DirtyIo")]
fn load_config(path: String) -> Result<(String, u16, u32), String> {
    let config = load_and_parse_config(&path)
        // {:#} format shows full error chain
        .map_err(|e| format!("{:#}", e))?;

    Ok((config.host, config.port, config.max_connections))
}

/// Multi-step operation with context at each step
fn process_data_file(input_path: &str, output_path: &str) -> Result<usize> {
    // Step 1: Read input
    let input_data = std::fs::read(input_path)
        .with_context(|| format!("Failed to read input: {}", input_path))?;

    // Step 2: Validate
    if input_data.is_empty() {
        return Err(anyhow!("Input file is empty"))
            .with_context(|| format!("Validation failed for: {}", input_path));
    }

    // Step 3: Transform
    let processed: Vec<u8> = input_data.iter()
        .map(|b| b.wrapping_add(1))
        .collect();

    // Step 4: Write output
    std::fs::write(output_path, &processed)
        .with_context(|| format!("Failed to write output: {}", output_path))?;

    Ok(processed.len())
}

#[rustler::nif(schedule = "DirtyIo")]
fn process_file(input: String, output: String) -> Result<usize, String> {
    process_data_file(&input, &output)
        .map_err(|e| format!("{:#}", e))
}

rustler::init!("Elixir.MyApp.RichErrors");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_chain_includes_context() {
        // Test that error messages include context
        let result = load_and_parse_config("/nonexistent/path/config.toml");
        let err_msg = format!("{:#}", result.unwrap_err());

        // Should contain both the context and the underlying error
        assert!(err_msg.contains("Failed to read config file"));
        assert!(err_msg.contains("nonexistent"));
    }
}
```

### Elixir Usage
```elixir
defmodule MyApp.RichErrors do
  use Rustler, otp_app: :my_app, crate: "rich_errors_nif"

  def load_config(_path), do: :erlang.nif_error(:nif_not_loaded)
  def process_file(_input, _output), do: :erlang.nif_error(:nif_not_loaded)
end

# Error includes full context chain
iex> MyApp.RichErrors.load_config("/invalid/path.toml")
{:error, "Failed to read config file: /invalid/path.toml: No such file or directory (os error 2)"}

# Successful load
iex> MyApp.RichErrors.load_config("config.toml")
{:ok, {"localhost", 8080, 100}}
```

---

## 33. NIF Performance Profiling

Built-in timing and metrics collection.

### Rust Code
```rust
use rustler::{ResourceArc, Atom};
use std::time::Instant;
use std::sync::atomic::{AtomicU64, Ordering};
use parking_lot::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
    }
}

// Global metrics
static TOTAL_CALLS: AtomicU64 = AtomicU64::new(0);
static TOTAL_NANOS: AtomicU64 = AtomicU64::new(0);
static MIN_NANOS: AtomicU64 = AtomicU64::new(u64::MAX);
static MAX_NANOS: AtomicU64 = AtomicU64::new(0);

// Per-operation metrics
struct OperationMetrics {
    call_count: AtomicU64,
    total_nanos: AtomicU64,
    last_call_nanos: AtomicU64,
}

impl OperationMetrics {
    fn new() -> Self {
        Self {
            call_count: AtomicU64::new(0),
            total_nanos: AtomicU64::new(0),
            last_call_nanos: AtomicU64::new(0),
        }
    }

    fn record(&self, nanos: u64) {
        self.call_count.fetch_add(1, Ordering::Relaxed);
        self.total_nanos.fetch_add(nanos, Ordering::Relaxed);
        self.last_call_nanos.store(nanos, Ordering::Relaxed);
    }

    fn average_micros(&self) -> f64 {
        let calls = self.call_count.load(Ordering::Relaxed);
        let nanos = self.total_nanos.load(Ordering::Relaxed);
        if calls > 0 {
            (nanos as f64 / calls as f64) / 1000.0
        } else {
            0.0
        }
    }
}

struct ProfilingResource {
    data: Mutex<Vec<i64>>,
    metrics: OperationMetrics,
}

#[rustler::resource_impl]
impl rustler::Resource for ProfilingResource {}

#[rustler::nif]
fn profiled_new(initial: Vec<i64>) -> ResourceArc<ProfilingResource> {
    ResourceArc::new(ProfilingResource {
        data: Mutex::new(initial),
        metrics: OperationMetrics::new(),
    })
}

/// Timed operation with per-instance and global metrics
#[rustler::nif(schedule = "DirtyCpu")]
fn profiled_sum(res: ResourceArc<ProfilingResource>) -> i64 {
    let start = Instant::now();

    let result = res.data.lock().iter().sum();

    let elapsed = start.elapsed().as_nanos() as u64;

    // Record to instance metrics
    res.metrics.record(elapsed);

    // Record to global metrics
    TOTAL_CALLS.fetch_add(1, Ordering::Relaxed);
    TOTAL_NANOS.fetch_add(elapsed, Ordering::Relaxed);

    // Update min/max (atomic compare-exchange loop)
    let mut current_min = MIN_NANOS.load(Ordering::Relaxed);
    while elapsed < current_min {
        match MIN_NANOS.compare_exchange_weak(
            current_min, elapsed,
            Ordering::Relaxed, Ordering::Relaxed
        ) {
            Ok(_) => break,
            Err(c) => current_min = c,
        }
    }

    let mut current_max = MAX_NANOS.load(Ordering::Relaxed);
    while elapsed > current_max {
        match MAX_NANOS.compare_exchange_weak(
            current_max, elapsed,
            Ordering::Relaxed, Ordering::Relaxed
        ) {
            Ok(_) => break,
            Err(c) => current_max = c,
        }
    }

    result
}

#[derive(rustler::NifMap)]
struct InstanceMetrics {
    call_count: u64,
    total_micros: f64,
    avg_micros: f64,
    last_call_micros: f64,
}

/// Get per-instance metrics
#[rustler::nif]
fn get_instance_metrics(res: ResourceArc<ProfilingResource>) -> InstanceMetrics {
    let calls = res.metrics.call_count.load(Ordering::Relaxed);
    let total = res.metrics.total_nanos.load(Ordering::Relaxed) as f64 / 1000.0;
    let last = res.metrics.last_call_nanos.load(Ordering::Relaxed) as f64 / 1000.0;

    InstanceMetrics {
        call_count: calls,
        total_micros: total,
        avg_micros: res.metrics.average_micros(),
        last_call_micros: last,
    }
}

#[derive(rustler::NifMap)]
struct GlobalMetrics {
    total_calls: u64,
    total_micros: f64,
    avg_micros: f64,
    min_micros: f64,
    max_micros: f64,
}

/// Get global metrics across all instances
#[rustler::nif]
fn get_global_metrics() -> GlobalMetrics {
    let calls = TOTAL_CALLS.load(Ordering::Relaxed);
    let nanos = TOTAL_NANOS.load(Ordering::Relaxed);
    let min = MIN_NANOS.load(Ordering::Relaxed);
    let max = MAX_NANOS.load(Ordering::Relaxed);

    GlobalMetrics {
        total_calls: calls,
        total_micros: nanos as f64 / 1000.0,
        avg_micros: if calls > 0 { (nanos as f64 / calls as f64) / 1000.0 } else { 0.0 },
        min_micros: if min == u64::MAX { 0.0 } else { min as f64 / 1000.0 },
        max_micros: max as f64 / 1000.0,
    }
}

/// Reset global metrics
#[rustler::nif]
fn reset_global_metrics() -> Atom {
    TOTAL_CALLS.store(0, Ordering::Relaxed);
    TOTAL_NANOS.store(0, Ordering::Relaxed);
    MIN_NANOS.store(u64::MAX, Ordering::Relaxed);
    MAX_NANOS.store(0, Ordering::Relaxed);
    atoms::ok()
}

rustler::init!("Elixir.MyApp.Profiling");
```

### Elixir Usage
```elixir
defmodule MyApp.Profiling do
  use Rustler, otp_app: :my_app, crate: "profiling_nif"

  def profiled_new(_initial), do: :erlang.nif_error(:nif_not_loaded)
  def profiled_sum(_res), do: :erlang.nif_error(:nif_not_loaded)
  def get_instance_metrics(_res), do: :erlang.nif_error(:nif_not_loaded)
  def get_global_metrics(), do: :erlang.nif_error(:nif_not_loaded)
  def reset_global_metrics(), do: :erlang.nif_error(:nif_not_loaded)
end

# Create and profile operations
iex> res = MyApp.Profiling.profiled_new(Enum.to_list(1..10000))
iex> for _ <- 1..100, do: MyApp.Profiling.profiled_sum(res)
iex> MyApp.Profiling.get_instance_metrics(res)
%{call_count: 100, total_micros: 245.3, avg_micros: 2.45, last_call_micros: 2.1}

iex> MyApp.Profiling.get_global_metrics()
%{total_calls: 100, total_micros: 245.3, avg_micros: 2.45, min_micros: 1.8, max_micros: 5.2}
```

---

## 34. Newtype Domain Validation

Type-safe wrappers with validation.

### Rust Code
```rust
use rustler::Atom;

mod atoms {
    rustler::atoms! {
        ok,
        invalid_user_id,
        invalid_email,
        invalid_percentage,
        invalid_timestamp,
        empty_string,
    }
}

// ============================================
// Newtype wrappers with validation
// ============================================

/// User ID must be positive
pub struct UserId(i64);

impl UserId {
    pub fn new(id: i64) -> Result<Self, &'static str> {
        if id > 0 {
            Ok(Self(id))
        } else {
            Err("UserId must be positive")
        }
    }

    pub fn as_i64(&self) -> i64 { self.0 }
}

/// Email must contain @ and have content before/after
pub struct Email(String);

impl Email {
    pub fn new(email: &str) -> Result<Self, &'static str> {
        let email = email.trim();
        if let Some(at_pos) = email.find('@') {
            if at_pos > 0 && at_pos < email.len() - 1 {
                return Ok(Self(email.to_string()));
            }
        }
        Err("Invalid email format")
    }

    pub fn as_str(&self) -> &str { &self.0 }

    pub fn domain(&self) -> &str {
        self.0.split('@').nth(1).unwrap_or("")
    }
}

/// Percentage must be 0.0 to 100.0
pub struct Percentage(f64);

impl Percentage {
    pub fn new(value: f64) -> Result<Self, &'static str> {
        if value >= 0.0 && value <= 100.0 && !value.is_nan() {
            Ok(Self(value))
        } else {
            Err("Percentage must be between 0 and 100")
        }
    }

    pub fn as_f64(&self) -> f64 { self.0 }

    pub fn as_fraction(&self) -> f64 { self.0 / 100.0 }
}

/// Non-empty string
pub struct NonEmptyString(String);

impl NonEmptyString {
    pub fn new(s: &str) -> Result<Self, &'static str> {
        let trimmed = s.trim();
        if trimmed.is_empty() {
            Err("String cannot be empty")
        } else {
            Ok(Self(trimmed.to_string()))
        }
    }

    pub fn as_str(&self) -> &str { &self.0 }
    pub fn len(&self) -> usize { self.0.len() }
}

/// Unix timestamp (must be positive)
pub struct Timestamp(i64);

impl Timestamp {
    pub fn new(ts: i64) -> Result<Self, &'static str> {
        if ts >= 0 {
            Ok(Self(ts))
        } else {
            Err("Timestamp cannot be negative")
        }
    }

    pub fn as_i64(&self) -> i64 { self.0 }
}

// ============================================
// NIFs using validated types
// ============================================

#[rustler::nif]
fn validate_user_id(id: i64) -> Result<i64, Atom> {
    let user_id = UserId::new(id).map_err(|_| atoms::invalid_user_id())?;
    Ok(user_id.as_i64())
}

#[rustler::nif]
fn validate_email(email: String) -> Result<(String, String), Atom> {
    let validated = Email::new(&email).map_err(|_| atoms::invalid_email())?;
    Ok((validated.as_str().to_string(), validated.domain().to_string()))
}

#[rustler::nif]
fn validate_percentage(value: f64) -> Result<(f64, f64), Atom> {
    let pct = Percentage::new(value).map_err(|_| atoms::invalid_percentage())?;
    Ok((pct.as_f64(), pct.as_fraction()))
}

#[rustler::nif]
fn validate_non_empty(s: String) -> Result<(String, usize), Atom> {
    let validated = NonEmptyString::new(&s).map_err(|_| atoms::empty_string())?;
    Ok((validated.as_str().to_string(), validated.len()))
}

/// Combined validation for a user record
#[derive(rustler::NifMap)]
struct ValidatedUser {
    id: i64,
    email: String,
    domain: String,
    name: String,
}

#[rustler::nif]
fn validate_user(id: i64, email: String, name: String) -> Result<ValidatedUser, Atom> {
    let user_id = UserId::new(id).map_err(|_| atoms::invalid_user_id())?;
    let validated_email = Email::new(&email).map_err(|_| atoms::invalid_email())?;
    let validated_name = NonEmptyString::new(&name).map_err(|_| atoms::empty_string())?;

    Ok(ValidatedUser {
        id: user_id.as_i64(),
        email: validated_email.as_str().to_string(),
        domain: validated_email.domain().to_string(),
        name: validated_name.as_str().to_string(),
    })
}

rustler::init!("Elixir.MyApp.Validated");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_id_rejects_zero() {
        assert!(UserId::new(0).is_err());
        assert!(UserId::new(-1).is_err());
    }

    #[test]
    fn user_id_accepts_positive() {
        assert_eq!(UserId::new(1).unwrap().as_i64(), 1);
        assert_eq!(UserId::new(i64::MAX).unwrap().as_i64(), i64::MAX);
    }

    #[test]
    fn email_validation() {
        assert!(Email::new("invalid").is_err());
        assert!(Email::new("@domain.com").is_err());
        assert!(Email::new("user@").is_err());

        let email = Email::new("user@example.com").unwrap();
        assert_eq!(email.as_str(), "user@example.com");
        assert_eq!(email.domain(), "example.com");
    }

    #[test]
    fn percentage_bounds() {
        assert!(Percentage::new(-0.1).is_err());
        assert!(Percentage::new(100.1).is_err());
        assert!(Percentage::new(f64::NAN).is_err());

        let pct = Percentage::new(75.0).unwrap();
        assert_eq!(pct.as_fraction(), 0.75);
    }

    #[test]
    fn non_empty_trims_whitespace() {
        assert!(NonEmptyString::new("").is_err());
        assert!(NonEmptyString::new("   ").is_err());

        let s = NonEmptyString::new("  hello  ").unwrap();
        assert_eq!(s.as_str(), "hello");
    }
}
```

### Elixir Usage
```elixir
defmodule MyApp.Validated do
  use Rustler, otp_app: :my_app, crate: "validated_nif"

  def validate_user_id(_id), do: :erlang.nif_error(:nif_not_loaded)
  def validate_email(_email), do: :erlang.nif_error(:nif_not_loaded)
  def validate_percentage(_value), do: :erlang.nif_error(:nif_not_loaded)
  def validate_non_empty(_s), do: :erlang.nif_error(:nif_not_loaded)
  def validate_user(_id, _email, _name), do: :erlang.nif_error(:nif_not_loaded)
end

# Individual validations
iex> MyApp.Validated.validate_user_id(123)
{:ok, 123}
iex> MyApp.Validated.validate_user_id(-1)
{:error, :invalid_user_id}

iex> MyApp.Validated.validate_email("user@example.com")
{:ok, {"user@example.com", "example.com"}}
iex> MyApp.Validated.validate_email("invalid")
{:error, :invalid_email}

iex> MyApp.Validated.validate_percentage(75.5)
{:ok, {75.5, 0.755}}

# Combined validation
iex> MyApp.Validated.validate_user(1, "alice@example.com", "Alice")
{:ok, %{id: 1, email: "alice@example.com", domain: "example.com", name: "Alice"}}

iex> MyApp.Validated.validate_user(-1, "alice@example.com", "Alice")
{:error, :invalid_user_id}
```

## 35. Builder Pattern with Validation

### Rust Code

```rust
use rustler::{ResourceArc, Atom};

mod atoms {
    rustler::atoms! { ok, error, invalid_port, host_required }
}

// Target configuration struct
pub struct ConnectionConfig {
    host: String,
    port: u16,
    timeout_ms: u64,
    pool_size: usize,
}

// Builder with defaults
pub struct ConnectionConfigBuilder {
    host: Option<String>,
    port: u16,
    timeout_ms: u64,
    pool_size: usize,
}

impl ConnectionConfigBuilder {
    pub fn new() -> Self {
        Self {
            host: None,
            port: 5432,
            timeout_ms: 5000,
            pool_size: 10,
        }
    }

    pub fn host(mut self, host: impl Into<String>) -> Self {
        self.host = Some(host.into());
        self
    }

    pub fn port(mut self, port: u16) -> Self {
        self.port = port;
        self
    }

    pub fn timeout_ms(mut self, timeout: u64) -> Self {
        self.timeout_ms = timeout;
        self
    }

    pub fn pool_size(mut self, size: usize) -> Self {
        self.pool_size = size;
        self
    }

    // Validates and builds
    pub fn build(self) -> Result<ConnectionConfig, String> {
        let host = self.host.ok_or("host is required")?;
        
        if self.port == 0 {
            return Err("port cannot be zero".to_string());
        }
        
        if self.pool_size == 0 {
            return Err("pool_size must be positive".to_string());
        }

        Ok(ConnectionConfig {
            host,
            port: self.port,
            timeout_ms: self.timeout_ms,
            pool_size: self.pool_size,
        })
    }
}

impl Default for ConnectionConfigBuilder {
    fn default() -> Self {
        Self::new()
    }
}

// NIF using builder
#[rustler::nif]
fn create_connection(
    host: Option<String>,
    port: Option<u16>,
    timeout: Option<u64>,
) -> Result<(Atom, String), (Atom, String)> {
    let mut builder = ConnectionConfigBuilder::new();
    
    if let Some(h) = host {
        builder = builder.host(h);
    }
    if let Some(p) = port {
        builder = builder.port(p);
    }
    if let Some(t) = timeout {
        builder = builder.timeout_ms(t);
    }

    match builder.build() {
        Ok(config) => Ok((atoms::ok(), format!("Connected to {}:{}", config.host, config.port))),
        Err(e) => Err((atoms::error(), e)),
    }
}

rustler::init!("Elixir.MyApp.Connection");
```

### Elixir Usage

```elixir
defmodule MyApp.Connection do
  use Rustler, otp_app: :my_app, crate: "connection_nif"
  
  def create_connection(_host, _port, _timeout), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
{:ok, msg} = MyApp.Connection.create_connection("localhost", 5432, 10000)
# => {:ok, "Connected to localhost:5432"}

{:error, reason} = MyApp.Connection.create_connection(nil, nil, nil)
# => {:error, "host is required"}

{:error, reason} = MyApp.Connection.create_connection("localhost", 0, nil)
# => {:error, "port cannot be zero"}
```

## 36. State Pattern for Typed States

Use Rust's type system to enforce valid state transitions at compile time.

### Rust Code

```rust
use rustler::{ResourceArc, Atom};
use std::sync::Mutex;

// Enum-based state for runtime checking (more flexible for NIFs)
#[derive(Clone, Debug)]
enum ConnectionState {
    Disconnected,
    Connected { connected_at: u64 },
    Authenticated { session_id: String, user: String },
    Error { message: String },
}

struct DynamicConnection {
    host: String,
    port: u16,
    state: Mutex<ConnectionState>,
}

#[rustler::resource_impl]
impl rustler::Resource for DynamicConnection {}

mod atoms {
    rustler::atoms! {
        ok, error, disconnected, connected, authenticated,
        invalid_state, auth_failed,
    }
}

#[rustler::nif]
fn conn_new(host: String, port: u16) -> ResourceArc<DynamicConnection> {
    ResourceArc::new(DynamicConnection {
        host,
        port,
        state: Mutex::new(ConnectionState::Disconnected),
    })
}

#[rustler::nif]
// NOTE: Result<Atom, Atom> is OK here because Ok returns the NEW STATE (:connected),
// not :ok. See Rule 2 — only `Ok(atoms::ok())` causes double-wrapping.
fn conn_connect(conn: ResourceArc<DynamicConnection>) -> Result<Atom, Atom> {
    let mut state = conn.state.try_lock().ok_or(atoms::error())?;

    match &*state {
        ConnectionState::Disconnected => {
            *state = ConnectionState::Connected {
                connected_at: std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs(),
            };
            Ok(atoms::connected())  // Return new state, not :ok
        }
        ConnectionState::Connected { .. } => Ok(atoms::connected()),
        _ => Err(atoms::invalid_state()),
    }
}

#[rustler::nif]
fn conn_authenticate(
    conn: ResourceArc<DynamicConnection>,
    user: String,
    token: String,
) -> Result<Atom, Atom> {
    let mut state = conn.state.try_lock().ok_or(atoms::error())?;

    match &*state {
        ConnectionState::Connected { .. } => {
            if token.is_empty() {
                *state = ConnectionState::Error {
                    message: "empty token".to_string(),
                };
                return Err(atoms::auth_failed());
            }

            *state = ConnectionState::Authenticated {
                session_id: format!("sess_{}", token),
                user,
            };
            Ok(atoms::authenticated())  // Return new state, not :ok
        }
        ConnectionState::Authenticated { .. } => Ok(atoms::authenticated()),
        _ => Err(atoms::invalid_state()),
    }
}

#[rustler::nif]
fn conn_execute(
    conn: ResourceArc<DynamicConnection>,
    command: String,
) -> Result<String, Atom> {
    let state = conn.state.try_lock().ok_or(atoms::error())?;

    match &*state {
        ConnectionState::Authenticated { session_id, user } => {
            Ok(format!("[{}@{}] {}", user, session_id, command))
        }
        _ => Err(atoms::invalid_state()),
    }
}

#[rustler::nif]
fn conn_state(conn: ResourceArc<DynamicConnection>) -> Result<Atom, Atom> {
    let state = conn.state.try_lock().ok_or(atoms::error())?;

    Ok(match &*state {
        ConnectionState::Disconnected => atoms::disconnected(),
        ConnectionState::Connected { .. } => atoms::connected(),
        ConnectionState::Authenticated { .. } => atoms::authenticated(),
        ConnectionState::Error { .. } => atoms::error(),
    })
}

rustler::init!("Elixir.MyApp.StatefulConn");
```

### Elixir Usage

```elixir
defmodule MyApp.StatefulConn do
  use Rustler, otp_app: :my_app, crate: "stateful_conn_nif"

  def conn_new(_host, _port), do: :erlang.nif_error(:nif_not_loaded)
  def conn_connect(_conn), do: :erlang.nif_error(:nif_not_loaded)
  def conn_authenticate(_conn, _user, _token), do: :erlang.nif_error(:nif_not_loaded)
  def conn_execute(_conn, _command), do: :erlang.nif_error(:nif_not_loaded)
  def conn_state(_conn), do: :erlang.nif_error(:nif_not_loaded)
end

# Usage
conn = MyApp.StatefulConn.conn_new("localhost", 5432)
:disconnected = MyApp.StatefulConn.conn_state(conn)

:ok = MyApp.StatefulConn.conn_connect(conn)
:connected = MyApp.StatefulConn.conn_state(conn)

:ok = MyApp.StatefulConn.conn_authenticate(conn, "alice", "secret123")
:authenticated = MyApp.StatefulConn.conn_state(conn)

{:ok, result} = MyApp.StatefulConn.conn_execute(conn, "SELECT 1")
# => {:ok, "[alice@sess_secret123] SELECT 1"}

# Invalid state transitions return errors
{:error, :invalid_state} = MyApp.StatefulConn.conn_execute(
  MyApp.StatefulConn.conn_new("host", 5432),  # Not connected!
  "SELECT 1"
)
```

## 37. RAII Guards for Transactions

Automatic rollback on error/panic using Drop trait.

### Rust Code

```rust
use rustler::{ResourceArc, Atom};
use std::sync::Mutex;

mod atoms {
    rustler::atoms! { ok, error, rollback }
}

struct Connection {
    in_transaction: Mutex<bool>,
    operations: Mutex<Vec<String>>,
}

#[rustler::resource_impl]
impl rustler::Resource for Connection {}

struct TransactionGuard<'a> {
    conn: &'a Connection,
    committed: bool,
}

impl<'a> TransactionGuard<'a> {
    fn new(conn: &'a Connection) -> Result<Self, Atom> {
        let mut in_tx = conn.in_transaction.lock().unwrap();
        if *in_tx {
            return Err(atoms::error());
        }
        *in_tx = true;
        conn.operations.lock().unwrap().push("BEGIN".to_string());
        
        Ok(Self {
            conn,
            committed: false,
        })
    }

    fn execute(&self, op: &str) -> Result<(), Atom> {
        self.conn.operations.lock().unwrap().push(op.to_string());
        Ok(())
    }

    fn commit(mut self) -> Result<(), Atom> {
        self.conn.operations.lock().unwrap().push("COMMIT".to_string());
        self.committed = true;
        Ok(())
    }
}

impl<'a> Drop for TransactionGuard<'a> {
    fn drop(&mut self) {
        if !self.committed {
            // Automatic rollback if not committed
            self.conn.operations.lock().unwrap().push("ROLLBACK".to_string());
        }
        *self.conn.in_transaction.lock().unwrap() = false;
    }
}

#[rustler::nif]
fn create_conn() -> ResourceArc<Connection> {
    ResourceArc::new(Connection {
        in_transaction: Mutex::new(false),
        operations: Mutex::new(Vec::new()),
    })
}

#[rustler::nif]
fn execute_transaction(
    conn: ResourceArc<Connection>,
    ops: Vec<String>,
    should_fail: bool,
) -> Result<usize, Atom> {
    let guard = TransactionGuard::new(&conn)?;

    for op in ops {
        guard.execute(&op)?;
        
        if should_fail && op.contains("FAIL") {
            // Guard drops here, triggering automatic rollback
            return Err(atoms::error());
        }
    }

    let op_count = conn.operations.lock().unwrap().len();
    guard.commit()?;
    Ok(op_count)  // Return number of operations committed
}

#[rustler::nif]
fn get_operations(conn: ResourceArc<Connection>) -> Vec<String> {
    conn.operations.lock().unwrap().clone()
}

rustler::init!("Elixir.MyApp.Transaction");
```

### Elixir Usage

```elixir
defmodule MyApp.Transaction do
  use Rustler, otp_app: :my_app, crate: "transaction_nif"

  def create_conn(), do: :erlang.nif_error(:nif_not_loaded)
  def execute_transaction(_conn, _ops, _should_fail), do: :erlang.nif_error(:nif_not_loaded)
  def get_operations(_conn), do: :erlang.nif_error(:nif_not_loaded)
end

# Successful transaction
conn = MyApp.Transaction.create_conn()
:ok = MyApp.Transaction.execute_transaction(conn, ["INSERT 1", "UPDATE 2"], false)
MyApp.Transaction.get_operations(conn)
# => ["BEGIN", "INSERT 1", "UPDATE 2", "COMMIT"]

# Failed transaction - automatic rollback
conn2 = MyApp.Transaction.create_conn()
{:error, _} = MyApp.Transaction.execute_transaction(conn2, ["INSERT", "FAIL", "UPDATE"], true)
MyApp.Transaction.get_operations(conn2)
# => ["BEGIN", "INSERT", "FAIL", "ROLLBACK"]  # Note automatic rollback!
```

## 38. Expanded Atomic Operations

Lock-free counters and compare-and-swap patterns.

### Rust Code

```rust
use rustler::{ResourceArc, Atom};
use std::sync::atomic::{AtomicU64, AtomicBool, Ordering};

mod atoms {
    rustler::atoms! { ok, error, limit_reached, already_active, not_active }
}

struct AtomicCounter {
    count: AtomicU64,
    active: AtomicBool,
    max_value: u64,
}

#[rustler::resource_impl]
impl rustler::Resource for AtomicCounter {}

#[rustler::nif]
fn counter_new(max_value: u64) -> ResourceArc<AtomicCounter> {
    ResourceArc::new(AtomicCounter {
        count: AtomicU64::new(0),
        active: AtomicBool::new(true),
        max_value,
    })
}

// Lock-free increment
#[rustler::nif]
fn counter_increment(counter: ResourceArc<AtomicCounter>) -> u64 {
    counter.count.fetch_add(1, Ordering::Relaxed) + 1
}

// Atomic compare-and-swap with limit
#[rustler::nif]
fn counter_increment_if_below_max(counter: ResourceArc<AtomicCounter>) -> Result<u64, Atom> {
    loop {
        let current = counter.count.load(Ordering::Relaxed);
        if current >= counter.max_value {
            return Err(atoms::limit_reached());
        }
        
        match counter.count.compare_exchange_weak(
            current,
            current + 1,
            Ordering::SeqCst,
            Ordering::Relaxed,
        ) {
            Ok(_) => return Ok(current + 1),
            Err(_) => continue, // Retry on contention
        }
    }
}

// Atomic flag toggle with return of previous value
#[rustler::nif]
fn counter_deactivate(counter: ResourceArc<AtomicCounter>) -> Result<bool, Atom> {
    let was_active = counter.active.swap(false, Ordering::SeqCst);
    Ok(was_active)  // Return previous state: true = was active, false = was already inactive
}

#[rustler::nif]
fn counter_activate(counter: ResourceArc<AtomicCounter>) -> Result<bool, Atom> {
    let was_active = counter.active.swap(true, Ordering::SeqCst);
    Ok(!was_active)  // Return true if newly activated, false if was already active
}

#[rustler::nif]
fn counter_get(counter: ResourceArc<AtomicCounter>) -> (u64, bool) {
    (
        counter.count.load(Ordering::Relaxed),
        counter.active.load(Ordering::Relaxed),
    )
}

rustler::init!("Elixir.MyApp.AtomicCounter");
```

### Elixir Usage

```elixir
defmodule MyApp.AtomicCounter do
  use Rustler, otp_app: :my_app, crate: "atomic_counter_nif"

  def counter_new(_max), do: :erlang.nif_error(:nif_not_loaded)
  def counter_increment(_counter), do: :erlang.nif_error(:nif_not_loaded)
  def counter_increment_if_below_max(_counter), do: :erlang.nif_error(:nif_not_loaded)
  def counter_deactivate(_counter), do: :erlang.nif_error(:nif_not_loaded)
  def counter_activate(_counter), do: :erlang.nif_error(:nif_not_loaded)
  def counter_get(_counter), do: :erlang.nif_error(:nif_not_loaded)
end

# Basic usage
counter = MyApp.AtomicCounter.counter_new(100)
1 = MyApp.AtomicCounter.counter_increment(counter)
2 = MyApp.AtomicCounter.counter_increment(counter)
{2, true} = MyApp.AtomicCounter.counter_get(counter)

# Compare-and-swap with limit
counter = MyApp.AtomicCounter.counter_new(3)
{:ok, 1} = MyApp.AtomicCounter.counter_increment_if_below_max(counter)
{:ok, 2} = MyApp.AtomicCounter.counter_increment_if_below_max(counter)
{:ok, 3} = MyApp.AtomicCounter.counter_increment_if_below_max(counter)
{:error, :limit_reached} = MyApp.AtomicCounter.counter_increment_if_below_max(counter)

# Atomic flag operations
:ok = MyApp.AtomicCounter.counter_deactivate(counter)
{:error, :not_active} = MyApp.AtomicCounter.counter_deactivate(counter)
```

## 39. Network and I/O Integration with Tokio

Async network operations using a global Tokio runtime.

### Rust Code

```rust
use tokio::runtime::Runtime;
use once_cell::sync::Lazy;
use rustler::{Env, Atom, Encoder, LocalPid};
use rustler::env::OwnedEnv;
use std::time::Duration;

mod atoms {
    rustler::atoms! { ok, error, result, timeout }
}

// Global Tokio runtime (singleton)
static TOKIO_RT: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime")
});

// Async HTTP fetch - returns immediately, sends result to caller
#[rustler::nif]
fn async_fetch(env: Env, url: String, timeout_secs: u64) -> Atom {
    let pid = env.pid();

    TOKIO_RT.spawn(async move {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(timeout_secs))
            .build()
            .unwrap();

        let result = match client.get(&url).send().await {
            Ok(response) => match response.text().await {
                Ok(body) => Ok(body),
                Err(e) => Err(e.to_string()),
            },
            Err(e) => Err(e.to_string()),
        };

        let mut msg_env = OwnedEnv::new();
        let _ = msg_env.send_and_clear(&pid, |env| {
            match result {
                Ok(body) => (atoms::result(), atoms::ok(), body).encode(env),
                Err(e) => (atoms::result(), atoms::error(), e).encode(env),
            }
        });
    });

    atoms::ok()
}

// Blocking fetch on DirtyIo (simpler for basic use cases)
#[rustler::nif(schedule = "DirtyIo")]
fn blocking_fetch(url: String, timeout_secs: u64) -> Result<String, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(timeout_secs))
        .build()
        .map_err(|e| e.to_string())?;

    client
        .get(&url)
        .send()
        .map_err(|e| e.to_string())?
        .text()
        .map_err(|e| e.to_string())
}

// TCP connectivity check
#[rustler::nif(schedule = "DirtyIo")]
fn tcp_check(host: String, port: u16, timeout_ms: u64) -> Result<bool, String> {
    use std::net::TcpStream;
    
    let addr = format!("{}:{}", host, port);
    let timeout = Duration::from_millis(timeout_ms);

    let socket_addr = addr.parse()
        .map_err(|e| format!("Invalid address: {}", e))?;

    match TcpStream::connect_timeout(&socket_addr, timeout) {
        Ok(_) => Ok(true),
        Err(_) => Ok(false),
    }
}

rustler::init!("Elixir.MyApp.Network");
```

### Cargo.toml

```toml
[dependencies]
rustler = "0.30"
tokio = { version = "1.0", features = ["rt-multi-thread", "macros"] }
reqwest = { version = "0.11", features = ["json", "blocking"] }
once_cell = "1.18"
```

### Elixir Usage

```elixir
defmodule MyApp.Network do
  use Rustler, otp_app: :my_app, crate: "network_nif"

  def async_fetch(_url, _timeout), do: :erlang.nif_error(:nif_not_loaded)
  def blocking_fetch(_url, _timeout), do: :erlang.nif_error(:nif_not_loaded)
  def tcp_check(_host, _port, _timeout), do: :erlang.nif_error(:nif_not_loaded)
end

# Async fetch - returns immediately
:ok = MyApp.Network.async_fetch("https://httpbin.org/get", 30)
receive do
  {:result, :ok, body} -> IO.puts("Got #{byte_size(body)} bytes")
  {:result, :error, reason} -> IO.puts("Error: #{reason}")
after
  5000 -> IO.puts("Timeout")
end

# Blocking fetch - simple synchronous call
{:ok, body} = MyApp.Network.blocking_fetch("https://httpbin.org/get", 30)

# TCP connectivity check
true = MyApp.Network.tcp_check("google.com", 443, 5000)
false = MyApp.Network.tcp_check("localhost", 12345, 1000)
```

## 40. Round-Trip Testing Pattern

Verify encode/decode consistency in Rust tests.

### Rust Code

```rust
use rustler::{Binary, OwnedBinary, Env, NifResult};
use flate2::write::{GzEncoder, GzDecoder};
use flate2::Compression;
use std::io::Write;

#[rustler::nif]
fn gzip_compress(data: Binary) -> NifResult<OwnedBinary> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(data.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    
    let compressed = encoder.finish()
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    
    let mut binary = OwnedBinary::new(compressed.len())
        .ok_or(rustler::Error::Term(Box::new("allocation failed")))?;
    binary.as_mut_slice().copy_from_slice(&compressed);
    Ok(binary)
}

#[rustler::nif]
fn gzip_decompress(data: Binary) -> NifResult<OwnedBinary> {
    use std::io::Read;
    use flate2::read::GzDecoder;
    
    let mut decoder = GzDecoder::new(data.as_slice());
    let mut decompressed = Vec::new();
    decoder.read_to_end(&mut decompressed)
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    
    let mut binary = OwnedBinary::new(decompressed.len())
        .ok_or(rustler::Error::Term(Box::new("allocation failed")))?;
    binary.as_mut_slice().copy_from_slice(&decompressed);
    Ok(binary)
}

// Internal functions for testing
fn compress_internal(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(data).map_err(|e| e.to_string())?;
    encoder.finish().map_err(|e| e.to_string())
}

fn decompress_internal(data: &[u8]) -> Result<Vec<u8>, String> {
    use std::io::Read;
    use flate2::read::GzDecoder;
    
    let mut decoder = GzDecoder::new(data);
    let mut result = Vec::new();
    decoder.read_to_end(&mut result).map_err(|e| e.to_string())?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compression_roundtrip() {
        let original = b"Hello, World! ".repeat(1000);
        
        let compressed = compress_internal(&original).unwrap();
        let decompressed = decompress_internal(&compressed).unwrap();
        
        assert_eq!(original.as_slice(), decompressed.as_slice());
    }

    #[test]
    fn compression_reduces_size() {
        let data = b"AAAAAAAAAA".repeat(1000);  // Highly compressible
        
        let compressed = compress_internal(&data).unwrap();
        
        assert!(compressed.len() < data.len());
    }

    #[test]
    fn empty_data_roundtrip() {
        let original: Vec<u8> = vec![];
        
        let compressed = compress_internal(&original).unwrap();
        let decompressed = decompress_internal(&compressed).unwrap();
        
        assert_eq!(original, decompressed);
    }

    #[test]
    fn binary_data_roundtrip() {
        let original: Vec<u8> = (0..=255).collect();  // All byte values
        
        let compressed = compress_internal(&original).unwrap();
        let decompressed = decompress_internal(&compressed).unwrap();
        
        assert_eq!(original, decompressed);
    }
}

rustler::init!("Elixir.MyApp.Compression");
```

### Cargo.toml

```toml
[dependencies]
rustler = "0.30"
flate2 = "1.0"
```

### Run Rust Tests

```bash
cd native/compression_nif
cargo test
```

## 41. Default Trait and must_use Patterns

### Rust Code

```rust
use rustler::{NifStruct, Atom};

mod atoms {
    rustler::atoms! { ok, error }
}

// Default trait for config with sensible defaults
#[derive(Clone, Default)]
pub struct ProcessingOptions {
    batch_size: usize,
    parallel: bool,
    timeout_ms: u64,
}

impl Default for ProcessingOptions {
    fn default() -> Self {
        Self {
            batch_size: 100,
            parallel: true,
            timeout_ms: 5000,
        }
    }
}

// NifStruct with defaults
#[derive(NifStruct, Clone)]
#[module = "MyApp.Options"]
pub struct NifOptions {
    batch_size: Option<usize>,
    parallel: Option<bool>,
    timeout_ms: Option<u64>,
}

impl NifOptions {
    fn to_processing_options(self) -> ProcessingOptions {
        ProcessingOptions {
            batch_size: self.batch_size.unwrap_or(100),
            parallel: self.parallel.unwrap_or(true),
            timeout_ms: self.timeout_ms.unwrap_or(5000),
        }
    }
}

// must_use ensures return values aren't ignored
#[must_use]
pub fn create_resource() -> String {
    "resource_created".to_string()
}

#[rustler::nif]
fn process_with_defaults(
    data: Vec<i64>,
    opts: Option<NifOptions>,
) -> Vec<i64> {
    let options = opts
        .map(|o| o.to_processing_options())
        .unwrap_or_default();
    
    // Use options.batch_size, options.parallel, etc.
    if options.parallel {
        data.into_iter().map(|x| x * 2).collect()
    } else {
        data.into_iter().map(|x| x * 2).collect()
    }
}

// Field init shorthand - cleaner struct construction
#[derive(NifStruct)]
#[module = "MyApp.User"]
struct User {
    name: String,
    email: String,
    age: u32,
}

#[rustler::nif]
fn create_user(name: String, email: String, age: u32) -> User {
    // Field init shorthand: { name, email, age } instead of { name: name, ... }
    User { name, email, age }
}

rustler::init!("Elixir.MyApp.Defaults");
```

### Elixir Usage

```elixir
defmodule MyApp.Options do
  defstruct [:batch_size, :parallel, :timeout_ms]
end

defmodule MyApp.User do
  defstruct [:name, :email, :age]
end

defmodule MyApp.Defaults do
  use Rustler, otp_app: :my_app, crate: "defaults_nif"

  def process_with_defaults(_data, _opts), do: :erlang.nif_error(:nif_not_loaded)
  def create_user(_name, _email, _age), do: :erlang.nif_error(:nif_not_loaded)
end

# Use defaults
[2, 4, 6] = MyApp.Defaults.process_with_defaults([1, 2, 3], nil)

# Override specific options
[2, 4, 6] = MyApp.Defaults.process_with_defaults(
  [1, 2, 3], 
  %MyApp.Options{batch_size: 50, parallel: false}
)

# Create user with field init shorthand
%MyApp.User{name: "Alice", email: "alice@example.com", age: 30} = 
  MyApp.Defaults.create_user("Alice", "alice@example.com", 30)
```
