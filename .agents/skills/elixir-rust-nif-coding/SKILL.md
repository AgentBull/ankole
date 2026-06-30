---
name: rust-nif
description: >
  Writing or changing the Rustler binding layer for Ankole native kernel
  functions. Use only when adding, renaming, removing, or changing NIF exports,
  Elixir NIF stubs, Rustler resource/event delivery code, scheduler choices, or
  BEAM boundary argument/return encoding. Do not use merely because Elixir calls
  an existing native function, or because host-neutral Rust code under
  `app/kernel/src/*` is being changed without touching the Rustler/NIF boundary.
---

# Rust NIFs for the Ankole Kernel

`app/kernel` is **one Rust crate compiled two ways** from the same source:

| Host | Loader | Binding file | Cargo feature |
|------|--------|--------------|---------------|
| Elixir / BEAM | Rustler | `src/nif_exports.rs` | `nif` |
| Bun / Node | N-API (napi-rs) | `src/napi_exports.rs` | `napi` |

The real behavior lives in **host-neutral modules** — `common/`, `authz/`, and
`runtime_fabric/` — that know nothing about the BEAM or Node. Both binding layers
stay thin: decode host values, keep binaries binary-safe, translate errors, and
forward to those modules. This skill covers the **Rustler (`nif`) side**.

> Golden path for a new capability: implement and `cargo test` it in the relevant
> host-neutral module, then add a thin `#[rustler::nif]` wrapper, then the Elixir
> stub. The wrapper is the smallest, last step — never put logic in it.

## Rules

### 1. Keep bindings thin — behavior goes in `common`/`authz`/`runtime_fabric`

A function in `nif_exports.rs` should only decode terms, call **one** host-neutral
function, and map the error. This one anchor example exercises rules 1–5:

```rust
#[rustler::nif(schedule = "DirtyCpu")]
pub fn aead_encrypt(plaintext: Term<'_>, key: Term<'_>) -> NifResult<String> {
    let plaintext = decode_binary(plaintext, "plaintext")?;
    let key = decode_string(key, "key")?;
    common::aead_encrypt(plaintext.as_slice(), &key).map_err(error)
}
```

If you find yourself writing business logic inside `#[rustler::nif]`, move it down
into a host-neutral module.

### 2. Pick the scheduler by cost

Normal-scheduler NIFs must finish in **<1 ms** or they stall the BEAM. In this
crate:

- `DirtyCpu` — crypto, hashing, encoding, JWT, authz (cost scales with payload)
- `DirtyIo` — ZeroMQ socket work (`runtime_fabric_router_*`)
- normal scheduler — only trivially cheap calls (`gen_uuid`, `generate_key`,
  `runtime_fabric_router_endpoint`)

### 3. Return `NifResult<T>`; never panic

`Ok(t)` encodes as the **bare value** `t` (not `{:ok, t}`); `Err(e)` **raises** the
term. No `unwrap()`/`expect()` in NIF bodies — use `?`, `.ok_or(...)`, and the
decode helpers. A panic crashes the whole VM. An infallible NIF may return a bare
type directly (`pub fn gen_uuid() -> String`).

### 4. Errors cross as string terms

Host-neutral code returns a plain `KernelError(String)`; the binding turns it into
`Error::Term(Box::new(message))` through two local helpers. No thiserror enums,
custom atom errors, or `Encoder` impls at the boundary — one human-readable string
is the contract.

```rust
fn error(error: common::KernelError) -> Error { error_message(error.to_string()) }
fn error_message(message: impl Into<String>) -> Error { Error::Term(Box::new(message.into())) }
```

### 5. Decode every argument explicitly, with a field name

Accept `Term<'_>` and decode inside the body so callers get a stable
`"<field> must be a binary"` message instead of Rustler's low-level wording. Reuse
the `decode_string` / `decode_binary` / `decode_optional_*` / `decode_json` helpers.

```rust
fn decode_string(term: Term<'_>, field: &str) -> NifResult<String> {
    term.decode().map_err(|_| error_message(format!("{field} must be a string")))
}

fn decode_binary<'a>(term: Term<'a>, field: &str) -> NifResult<Binary<'a>> {
    if !term.is_binary() {
        return Err(error_message(format!("{field} must be a binary")));
    }
    Binary::from_term(term).map_err(|_| error_message(format!("{field} must be a binary")))
}
```

### 6. Binary in, binary out — never `Vec<u8>` across the boundary

Rustler encodes `Vec<u8>` as a *list of integers*. Read input zero-copy with
`Binary`; return bytes with `OwnedBinary` via the `binary_from_vec` helper.

```rust
fn binary_from_vec(bytes: Vec<u8>) -> NifResult<OwnedBinary> {
    let mut binary =
        OwnedBinary::new(bytes.len()).ok_or_else(|| error_message("failed to allocate binary"))?;
    binary.as_mut_slice().copy_from_slice(&bytes);
    Ok(binary)
}
// usage: common::aead_decrypt(&ct, &key).map_err(error).and_then(binary_from_vec)
```

### 7. Bridge complex data as JSON, not derive macros

Maps and structs cross as a JSON **string**: Elixir uses `Torque.encode!/decode!`,
Rust uses `serde_json`. We do not use `NifStruct`/`NifMap`/`NifTaggedEnum`. The
`_json` NIF takes/returns a `String`; the public Elixir function wraps it.

```elixir
@spec authz_authorize(authz_snapshot()) :: result(authz_decision())
def authz_authorize(snapshot) when is_map(snapshot) do
  snapshot |> Torque.encode!() |> authz_authorize_json() |> Torque.decode!()
end

@doc false
@spec authz_authorize_json(String.t()) :: result(String.t())
def authz_authorize_json(_snapshot_json), do: :erlang.nif_error(:nif_not_loaded)
```

```rust
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_authorize_json(snapshot_json: Term<'_>) -> NifResult<String> {
    let snapshot = decode_json(snapshot_json, "snapshot_json")?;
    let decision = authz::authorize_json(snapshot).map_err(error)?;
    encode_json(decision) // serde_json::to_string, wrapped as an error term on failure
}
```

### 8. Hold native handles in `ResourceArc` + `#[rustler::resource_impl]`

The attribute macro is **mandatory** — a bare `impl Resource` compiles but panics at
runtime (`Option::unwrap()` on `None`) because the type never registers. Keep the
resource a plain newtype over a handle that owns its own thread/channels.

```rust
pub struct RuntimeFabricRouterResource(pub RouterHandle);

#[rustler::resource_impl]
impl rustler::Resource for RuntimeFabricRouterResource {}

#[rustler::nif(schedule = "DirtyIo")]
pub fn runtime_fabric_router_start(/* ... */) -> NifResult<ResourceArc<RuntimeFabricRouterResource>> {
    let handle = runtime_fabric::transport::start_router(config, sink).map_err(error)?;
    Ok(ResourceArc::new(RuntimeFabricRouterResource(handle)))
}
```

### 9. Push async events with `OwnedEnv` + `send_and_clear`, from a Rust-owned thread

Capture the owner `LocalPid`, build messages in an `OwnedEnv`, and tag them with
`rustler::atoms!`. **Never** call `send_and_clear` from a BEAM-managed thread — it
panics. Only Rust-owned socket/worker threads may send.

```rust
mod atoms {
    rustler::atoms! { runtime_fabric_router_received, runtime_fabric_router_socket_error }
}

fn send_router_event(owner_pid: LocalPid, event: RouterEvent) {
    let mut env = OwnedEnv::new();
    let _ = env.send_and_clear(&owner_pid, |env| match event {
        RouterEvent::Received { transport_route, envelope_json, .. } => {
            (atoms::runtime_fabric_router_received(), transport_route, envelope_json).encode(env)
        }
        RouterEvent::SocketError { reason } => {
            (atoms::runtime_fabric_router_socket_error(), reason).encode(env)
        }
    });
}
```

### 10. `@spec` every function in the Elixir module

`Ankole.Kernel` is both the public API and the NIF stub module, so every
`def ..., do: :erlang.nif_error(:nif_not_loaded)` carries a `@spec`. Reuse the
shared type aliases (`result(value)`, `salt()`, the `*_json` shapes).

```elixir
@type result(value) :: value | {:error, String.t()}

@spec aead_encrypt(binary(), String.t()) :: result(String.t())
def aead_encrypt(_plaintext, _key), do: :erlang.nif_error(:nif_not_loaded)
```

### 11. Locking lives below the binding layer — prefer `try_lock` + `OnceLock`

The NIF layer holds no locks. Host-neutral caches use
`OnceLock<Mutex<HashMap<...>>>` with `try_lock().ok()` (std::sync, **not**
parking_lot). Blocking `.lock()` can deadlock a dirty scheduler; a missed cache
read is cheaper than a stall.

```rust
static CONDITION_CACHE: OnceLock<Mutex<HashMap<String, CachedCondition>>> = OnceLock::new();

let cache = CONDITION_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
let guard = cache.try_lock().ok()?; // miss on contention, never block
```

## Build wiring

`Cargo.toml` (dual-target, abridged) — edition 2024, Rustler 0.38:

```toml
[lib]
crate-type = ["cdylib", "rlib"]

[features]
napi = ["dep:napi", "dep:napi-derive"]
nif  = ["dep:rustler"]

[dependencies]
rustler = { version = "0.38.0", optional = true }
serde_json = "1"
# ... native crates: blake3, jsonwebtoken, zmq, prost, uuid, ...
```

`src/lib.rs` gates the binding module; `nif_exports.rs` registers the NIFs:

```rust
#[cfg(feature = "nif")]
mod nif_exports;

// bottom of nif_exports.rs — list EVERY nif function name, no load callback:
rustler::init!("Elixir.Ankole.Kernel");
```

`mix.exs` + module:

```elixir
# deps
{:rustler, "~> 0.38.0", runtime: false},
{:torque, "~> 0.2.3"}

# lib/ankole/kernel.ex
use Rustler,
  otp_app: :ankole_kernel,
  crate: "ankole_kernel",
  path: ".",
  default_features: false,
  features: ["nif"]
```

## Adding a NIF (checklist)

1. **Shared implementation** — implement and `cargo test` the logic in the right
   `common/`/`authz/`/`runtime_fabric/` module, returning `KernelResult<T>`.
2. **Wrapper** — add a thin `#[rustler::nif(schedule = ...)]` in `nif_exports.rs`
   that decodes terms and forwards.
3. **Register** — add the function name to `rustler::init!(...)`. Forgetting this is
   the #1 mistake: it compiles, then raises `:nif_not_loaded` at runtime.
4. **Elixir stub** — add `def ..., do: :erlang.nif_error(:nif_not_loaded)` with a
   `@spec` in `Ankole.Kernel`; if it takes/returns maps, add the Torque-bridging
   public wrapper too.
5. **Bun (if shared)** — this is a shared kernel. If Bun needs the same capability,
   add the matching `#[napi]` export in `napi_exports.rs`.

## Type & error quick reference

| Elixir | Rust (binding) | Note |
|--------|----------------|------|
| `String.t()` | `String` / `decode_string` | UTF-8 |
| `binary` (read) | `Binary` | zero-copy |
| `binary` (return) | `OwnedBinary` | never `Vec<u8>` |
| `integer` | `i64`, `u32`, … | size-specific |
| `atom` | `Atom` / `rustler::atoms!` | event tags |
| `pid` | `LocalPid` | owner of async events |
| `reference` | `ResourceArc<T>` | native handle |
| map / struct | JSON `String` (Torque ⇄ serde_json) | not `NifStruct` |

- A NIF returning `NifResult<T>`: `Ok(t)` → bare `t`; `Err(e)` → raised term.
- An infallible NIF may return `T` directly (e.g. `gen_uuid() -> String`).

## Testing

- **Shared logic** → Rust unit tests (`cargo test`) against the pure functions;
  this is where coverage belongs.
- **Boundary** → ExUnit calling `Ankole.Kernel.*`, asserting decode errors and
  round-trips through the JSON/binary bridges.

## When NOT to write a NIF

- I/O-bound orchestration — let the BEAM do it; drop to Rust only for socket-level
  work that needs a Rust-only crate (e.g. the ZeroMQ ROUTER).
- Logic with no Rust-only dependency and no measured hot path — the boundary plus
  JSON cost can erase small wins; benchmark before assuming.
- Anything that must survive a crash in isolation — a NIF panic takes the whole VM
  down. The dirty-scheduler + thin-wrapper discipline above is the mitigation.

## Related skills

- **[elixir-coding](../elixir-coding/SKILL.md)** — Elixir/OTP conventions for the
  code that calls these NIFs.
- **[phoenix-coding](../phoenix-coding/SKILL.md)** — the web layer above the kernel.
