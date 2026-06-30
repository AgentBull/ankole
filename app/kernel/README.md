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
- `runtime_fabric/` - RuntimeFabric v1 envelope codec and validation, including
  JSON-shaped host maps, protobuf bytes, lanes, durability classes, correlation
  rules, and turn/control/progress/RPC body semantics.
- `runtime_fabric/transport/` - Rust-owned ZeroMQ ROUTER/DEALER transport split
  across auth, config, router, dealer, and framing modules, including ZAP/PLAIN
  worker authentication, mandatory route sends, bounded socket options, route
  and decode errors, and raw `ANKOLE_FILE/1` worker-file multipart frames.
- `universal_ai_client/` - feature-gated native async streaming client for
  prepared AI provider requests, including upstream HTTP SSE/EventStream and
  WebSocket transport, provider response normalization, downstream SSE/WebSocket
  chunk encoding, demand credit, and cancellation.

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
- UniversalAIClient receives provider endpoint/header/transport specs plus the
  public model request. The kernel owns model request body encoding, raw HTTP
  execution, the live streaming data plane, API protocol normalization,
  downstream-ready SSE or WebSocket text chunks, demand credit, cancellation,
  and timeout handling. Provider selection, credentials, endpoint choice,
  transcript commits, and policy stay in the host runtime and durable stores.

## Architecture

`app/kernel` is one Rust crate compiled through feature-gated binding layers:

| Host | Loader | Binding file | Cargo feature |
|------|--------|--------------|---------------|
| Elixir / BEAM | Rustler | `src/nif_exports.rs` | `nif` |
| Bun / Node | N-API | `src/napi_exports.rs` | `napi` |

The host-neutral modules are compiled for tests and for both binding features.
The binding files decode host values, preserve binary and JSON boundaries,
translate errors, and forward to the shared modules.

`universal_ai_client` is feature-gated separately and currently enabled by the
Rustler/NIF build. Keep one-sided exports explicit in the binding layer until
another host needs the same API.

Binding layers may use host-native naming and types, but they must not introduce
different behavior. Complex maps cross as JSON-shaped values (`Torque` on
Elixir, `serde_json` in Rust, napi-rs JSON values on Bun). Byte payloads stay
binary-safe across both hosts.

One-sided exports are allowed, but they should stay explicit in the binding layer
rather than changing the shared kernel contract by accident.
