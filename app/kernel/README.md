# Ankole Kernel

Ankole Kernel is the Rust library loaded by the Elixir control plane through
Rustler. The browser daemon loads the `napi` build for URL admission and its
local Chromium SOCKS5 proxy. The Bun Worker process does not load this library.
Host tests also use `napi` for the shared `o200k_base` token estimator.

## Purpose

The kernel provides native primitives and transport. The control plane owns
durable state, provider policy, credentials, and domain commits.

The current surface is:

- `common/` - AEAD tokens, key derivation, hashing, password hashing,
  encodings, UUID helpers, JWT helpers, phone normalization, and `o200k_base`
  token estimates, and web URL classification and admission.
- `web_proxy.rs` - a loopback SOCKS5 TCP proxy for local Chromium. It checks the
  requested host and all resolved addresses, then connects to a checked IP.
- `authz/` - snapshot-only authorization evaluation, CEL condition validation,
  and resource-pattern validation and matching.
- `universal_ai_client/` - native async streaming for prepared AI requests:
  upstream HTTP SSE/EventStream and WebSocket transport, provider response
  and error normalization, the terminal for each Provider call, downstream
  JSON text chunk encoding, demand credit,
  cancellation, and timeouts.
- `object_store/` - file-service storage through OpenDAL over local files,
  S3, Azure Blob, D1, COS, PostgreSQL, OSS, TOS, GCS, SFTP, or WebDAV, with
  bounded retries and per-call timeouts. Large objects move through local
  files; writes use 8 MiB chunks. Some backends buffer the complete object.
- `brain_markdoc/` - analysis of Brain bodies over CommonMark.
- `model_image/` - model image validation and conversion.
- `signals/` - CEL routing-policy evaluation over a supplied context.
- `page_document/` - page XML validation, canonical conversion, search text,
  prepared Wordgard change-set application, and structural/UTF-16 document diff. The complete
  XML to editor document to XML chain shares its corpus with the block editor.

## Identifier Generation

The Control Plane generates UUIDv7 identifiers with `Ash.UUIDv7.generate/0`.
Its Ecto schemas use `Ankole.Ecto.UUIDv7` for opaque PostgreSQL `uuid` row IDs.
The kernel exposes `gen_uuid_v7` to its native consumers.
Database migrations declare UUID primary keys without PostgreSQL
defaults such as `gen_random_uuid()`. Principal `uid`, provider channel IDs,
and composite provider/runtime keys use their domain-defined semantic formats.

## Boundary

The kernel owns mechanisms, not product state:

- AuthZ receives explicit snapshots. It never loads principals, grants,
  groups, or request context from PostgreSQL.
- UniversalAIClient receives prepared provider endpoints, headers, and model
  requests. It owns protocol encoding, response and error normalization, and
  ordered terminal delivery under read credit for each call. The control plane
  consumes those results, selects providers and credentials, applies retry
  policy, and commits the public Ankole Response. It can compose several native
  calls into one public Response without managing their protocol state.
- ObjectStore receives explicit storage specifications and operations. The
  control plane owns the file lifecycle and durable references.

The kernel owns no Worker socket or RuntimeFabric envelope codec.
`proto/ankole/runtime_fabric/v1/envelope.proto` declares the protocol and its
current version. The control plane owns `Ankole.RuntimeFabric` and the Protox
compilation unit; the Worker uses protobuf-es. Each host writes the declared
version on send and checks it on receive. Domain consumers
check execution references against their authoritative state. Cross-language
fixtures live in `proto/golden`.

## Build and Transport

Rustler tracks Cargo manifests and native source inputs for incremental builds
and Phoenix development reload checks. Generated Mix, Cargo, and Bun artifacts
are excluded from this input set.
Restart the development control plane after rebuilding its loaded NIF. Phoenix
reloads the application's Elixir code and the local Elixir protocol libraries.

The control plane uses the Cargo feature `nif` for development, tests, and
production. `src/nif_exports.rs` translates BEAM values and errors, then calls
the Rust modules. Complex inputs cross as JSON-shaped values (`Torque` in
Elixir, `serde_json` in Rust); byte payloads stay binary.

The Cargo feature `napi` builds a Node addon in a separate target directory.
The addon exposes the shared URL facts, URL admission, IP-address admission,
and the local browser proxy. It also exports `estimateO200kBaseTokens` for
host tests. NIF and Node-API adapters only convert types and errors. Do not
enable `nif` and `napi` in one build.

```bash
bun run --filter @ankole/kernel build:node
```

The build writes `app/kernel/target/napi-build/ankole_kernel.node`.
Pass `--release` for an optimized build. The Worker image builds this addon
for its target architecture and bundles it with the browser entry points.
Node-API TLS tests require the `openssl` command.

CEL NIF calls use a separate 8 MiB native stack on the dirty CPU scheduler
thread. This covers parsing, evaluation, and program cleanup without changes
to the BEAM scheduler stack configuration.

UniversalAIClient uses the same aws-lc-rs TLS backend in each environment. Its
shared reqwest client uses HTTP/1.1. Upstream WebSocket calls use their own
connection. There is no environment-specific TLS provider, HTTP protocol
preference, or HTTP/3 build.

Run the declared kernel checks from the repository root:

```bash
bun run --filter @ankole/kernel lint
bun run --filter @ankole/kernel test
```

The editor and Rust page codec share valid XML, invalid XML, limit boundaries,
and continuous edit batches in `libs/ankole-editor/corpus/rust`. To compare
generated pages and multiple local edits per batch with the production Rust
codec, run `bun run --filter @ankole/block-editor test:rust`. Set `FC_SEED` to
reproduce another generated corpus. Every batch must match both the stored XML
and the client's in-memory document after normalization.

Run remote object-store checks separately. Provision test storage, then put a
JSON array of store specs in a local file. The test writes, replaces, and deletes
objects with unique test keys. It checks transfers larger than 8 MiB except for
D1, which has a smaller row limit. Do not use a production store.

```bash
ANKOLE_OBJECT_STORE_TEST_SPECS=/absolute/path/test-stores.json \
  cargo test --manifest-path app/kernel/Cargo.toml --no-default-features \
  --features object_store configured_remote_stores -- --ignored --nocapture
```
