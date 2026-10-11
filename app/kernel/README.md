# Ankole Kernel

Ankole Kernel is the Rust library loaded by the Elixir control plane through
Rustler. The Bun Worker does not load a native kernel addon.

## Purpose

The kernel provides native primitives and transport. The control plane owns
durable state, provider policy, credentials, and domain commits.

The current surface is:

- `common/` - AEAD tokens, key derivation, hashing, password hashing,
  encodings, UUID helpers, JWT helpers, and phone normalization.
- `authz/` - snapshot-only authorization evaluation, CEL condition validation,
  and resource-pattern validation and matching.
- `universal_ai_client/` - native async streaming for prepared AI requests:
  upstream HTTP SSE/EventStream and WebSocket transport, provider response
  normalization, downstream JSON text chunk encoding, demand credit,
  cancellation, and timeouts.
- `object_store/` - file-service storage through OpenDAL over a local directory
  or an S3-compatible bucket, with bounded retries and per-call timeouts.
  Large objects move through local files; writes use 8 MiB parts.
- `program_runner/` - one-shot AIGateway Programmatic Tool Calling execution
  in a `deno_core` isolate.
- `brain_markdoc/` - analysis of Brain bodies over CommonMark.
- `model_image/` - model image validation and conversion.
- `signals_gateway/` - CEL routing-policy evaluation over a supplied context.

## Identifier Generation

`Ankole.Kernel.gen_uuid_v7/0` supplies UUIDv7 identifiers to Elixir.
Control-plane Ecto schemas use `Ankole.Ecto.UUIDv7` for opaque PostgreSQL `uuid`
row IDs. Database migrations declare UUID primary keys without PostgreSQL
defaults such as `gen_random_uuid()`.

Semantic keys remain semantic. Principal `uid`, provider channel IDs, and
composite provider/runtime keys do not become opaque UUIDs for uniformity.

## Boundary

The kernel owns mechanisms, not product state:

- AuthZ receives explicit snapshots. It never loads principals, grants,
  groups, or request context from PostgreSQL.
- UniversalAIClient receives prepared provider endpoints, headers, and model
  requests. It encodes requests and owns the streaming data plane. The control
  plane selects providers and credentials, applies policy, and commits results.
- ObjectStore receives explicit storage specifications and operations. The
  control plane owns the file lifecycle and durable references.

The kernel owns no Worker socket or RuntimeFabric envelope codec.
`proto/ankole/runtime_fabric/v1/envelope.proto` declares the protocol and its
current version. Elixir uses Protox and the Worker uses protobuf-es. Each host
writes the declared version on send and checks it on receive. Domain consumers
check execution references against their authoritative state. Cross-language
fixtures live in `proto/golden`.

## Build and Transport

The control plane uses one Cargo feature, `nif`, for development, tests, and
production. `src/nif_exports.rs` translates BEAM values and errors, then calls
the Rust modules. Complex inputs cross as JSON-shaped values (`Torque` in
Elixir, `serde_json` in Rust); byte payloads stay binary.

UniversalAIClient uses the same aws-lc-rs TLS backend in each environment. Its
shared reqwest client uses HTTP/1.1. Upstream WebSocket calls use their own
connection. There is no environment-specific TLS provider, HTTP protocol
preference, or HTTP/3 build.

Run the declared kernel checks from the repository root:

```bash
bun run --filter @ankole/kernel lint
bun run --filter @ankole/kernel test
```
