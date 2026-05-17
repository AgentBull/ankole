# BullX.Ext

`BullX.Ext` is the Elixir facade for BullX native Rust NIFs. The Rust crate
lives in `native/bullx_ext` and is loaded through
[`Rustler`](https://github.com/rusterlium/rustler).

This note is a lightweight boundary note, not a full subsystem design doc.

## Boundary

`BullX.Ext` is the place for Rust-backed functions when Rust gives BullX a
clear benefit:

- CPU-heavy or latency-sensitive algorithms;
- native libraries with better Rust support than Elixir support;
- encoding, hashing, crypto, UUID, parsing, validation, or normalization logic;
- BullX-specific deterministic decision logic that is easier or safer to keep
  inside one Rust call than to split across many Elixir-to-Rust calls.

`BullX.Ext` is not limited to generic utility functions. It may contain
BullX-specific business logic when the logic is pure from BullX's point of
view: all durable facts enter as explicit arguments, and the NIF returns an
ordinary value or tagged error. Examples include a route matcher, a loaded-grant
authorization decision, or another bounded decision function over already-loaded
data.

Rust NIFs must not become a hidden runtime or storage layer. Durable product
truth stays in PostgreSQL. OTP supervision, transactions, retries, external
I/O, and cross-subsystem orchestration stay in Elixir unless a later design
explicitly changes that boundary.

## Side effects

The practical rule is: keep the blacklist small and focused on hidden business
side effects.

Rust NIFs must not:

- read or write PostgreSQL, durable files, or other BullX product truth stores;
- call remote services as part of BullX business behavior;
- read secrets implicitly from environment, files, keychains, or process state;
- mutate durable BullX state outside the Elixir-owned persistence path;
- send BEAM messages as a hidden side effect of an otherwise synchronous API;
- keep process-local mutable state as product truth.

These restrictions are about ownership, not purity. A NIF may still use ordinary
system inputs when they are part of the function contract:

- OS randomness for salts, nonces, keys, and UUIDv4-like identifiers;
- wall-clock time for UUIDv7 generation;
- CPU-local library state or caches that are reconstructible and not durable
  truth.

When a business decision depends on time, policy state, request location, or an
external fact, Elixir computes or loads that fact and passes it to the NIF
explicitly. The NIF should not fetch it on its own.

## Rustler practices

Design the Elixir API first. Public wrappers in `BullX.Ext` should have
`@spec`s and should document input shapes, return shapes, and error behavior.
The Rust function should match that public contract, not leak upstream library
types into callers.

Use dirty schedulers for work that can exceed normal scheduler expectations.
Rustler's `#[rustler::nif]` docs recommend a scheduler flag for functions that
may take more than about 1 ms. Use `DirtyCpu` for CPU work such as hashing,
crypto, parsing, matching, and expression evaluation. Use `DirtyIo` only for
blocking I/O, and prefer Elixir for I/O unless Rust is the real integration
boundary.

Return errors, do not panic, for expected bad input. A NIF should turn malformed
terms, invalid user data, parser errors, and upstream library rejections into
tagged Elixir errors. Avoid `unwrap()` and `expect()` in NIF call paths except
for small, documented invariants that cannot be affected by input.

Keep NIF wrappers thin. Put most algorithmic logic in ordinary Rust functions
that can be tested with `cargo test`, and keep Rustler term decoding/encoding
at the edge. Add focused ExUnit tests for the Elixir wrapper and Rust tests for
the pure Rust logic.

Prefer explicit conversion types. Use Rustler derive macros such as
`NifStruct`, `NifMap`, and enum encoders when the boundary benefits from typed
data. Be careful with `NifMap`: optional fields still need deliberate Elixir
normalization when missing keys are allowed.

Do not hide long-lived native state unless a design doc names the lifecycle,
reconstruction behavior, failure behavior, and ownership boundary. If native
state is only a cache, the durable source of truth must remain elsewhere.

Keep return values boring. Existing BullX.Ext functions generally return the
raw value on success or `{:error, reason}` for expected failures. Preserve that
shape unless a function has a clearer local contract.

## Current implementation notes

The current crate already contains more than trivial helpers: it includes
crypto, encoding, phone normalization, JWT handling, UUID generation, and AuthZ
condition/grant evaluation. That is compatible with this boundary as long as
Rust receives explicit inputs and does not perform hidden BullX-side effects.

The local `native/bullx_ext/README.md` may describe the crate more narrowly as
small native helpers. Treat this note as the intended broader boundary for
future work, while still keeping every addition boring, explicit, and easy to
test.
