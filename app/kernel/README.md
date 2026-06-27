# Ankole Kernel

Ankole Kernel is the shared Rust crate loaded by both the Elixir and Bun parts
of Ankole.

It is not a Bun package with an Elixir adapter, and not an Elixir NIF project
with a Bun adapter. Rust owns the low-level semantics. Bun and Elixir are equal
host runtimes that load those semantics through separate binding layers.

## Purpose

The kernel exists to prevent the Bun side and the Elixir side from developing
separate meanings for the same native behavior. If a behavior must be trusted by
both runtimes, it belongs here as Rust first, with bindings second.

The current shared surface is:

- `common/` - AEAD tokens, key derivation, hashing, encodings, UUID helpers, JWT
  helpers, phone normalization, and other host-neutral primitives.
- `authz/` - snapshot-only authorization evaluation, CEL condition validation,
  and resource-pattern validation and matching.
- `runtime_fabric/` - RuntimeFabric v1 protobuf envelope validation and codec
  for actor and RPC traffic.
- `runtime_fabric/transport.rs` - Rust-owned ZeroMQ ROUTER/DEALER socket loops,
  ZAP/PLAIN worker authentication, mandatory routing, backpressure and route
  errors, and raw worker-file multipart frames.

## Identifier Generation

The kernel owns Ankole's shared UUID helpers. `gen_uuid_v7` is exposed to
Elixir as `Ankole.Kernel.gen_uuid_v7/0` and to Bun as `genUUIDv7()`.

Control-plane Ecto schemas should use `Ankole.Ecto.UUIDv7` for opaque
PostgreSQL `uuid` row ids. That type stores the same database value as
`Ecto.UUID`, but its autogeneration calls the Rust kernel helper so Elixir and
Bun do not grow separate UUID semantics.

Database migrations should declare UUID primary keys without PostgreSQL-side
defaults such as `gen_random_uuid()`. Semantic keys stay semantic: Principal
`uid`, provider channel ids, and composite provider/runtime keys should not be
replaced with opaque UUIDs merely for uniformity.

## Boundary

The kernel owns shared mechanisms, not product ownership.

It may own the evaluator, codec, verifier, socket loop, or protocol machinery.
It does not own actor scheduling, PostgreSQL state, plugin lifecycle, provider
policy, UI, final transcript commits, or the business meaning that uses those
mechanisms.

Host runtimes provide complete inputs:

- AuthZ receives explicit snapshots. It never loads principals, grants, groups,
  or request context from PostgreSQL.
- RuntimeFabric receives JSON-shaped envelope maps. The kernel validates and
  encodes them, but durable replay and commit authority stay in the control
  plane.
- Worker-file frames are live transport bytes. File and skill semantics stay in
  the host runtime and durable stores.

## Architecture

`app/kernel` is one Rust crate compiled through feature-gated binding layers:

| Host | Loader | Binding file | Cargo feature |
|------|--------|--------------|---------------|
| Elixir / BEAM | Rustler | `src/nif_exports.rs` | `nif` |
| Bun / Node | N-API | `src/napi_exports.rs` | `napi` |

The host-neutral modules are compiled for tests and for both binding features.
The binding files decode host values, preserve binary and JSON boundaries,
translate errors, and forward to the shared modules.

Binding layers may use host-native naming and types, but they must not introduce
different behavior. Complex maps cross as JSON-shaped values (`Torque` on
Elixir, `serde_json` in Rust, napi-rs JSON values on Bun). Byte payloads stay
binary-safe across both hosts.

One-sided exports are allowed, but they should stay explicit in the binding layer
rather than changing the shared kernel contract by accident.
