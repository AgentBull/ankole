# Ankole Kernel

Ankole Kernel is the Rust library that the Elixir control plane loads through
Rustler. A separate `napi` build serves the browser daemon—for URL admission and
its local Chromium SOCKS5 proxy—as well as host tests that call the shared
`o200k_base` token estimator. The Bun Worker process itself does not load this
library.

## Purpose

The kernel provides native primitives and transport, whereas the control plane
owns durable state, provider policy, credentials, and domain commits.

The current modules are:

- `common/` - AEAD tokens, key derivation, hashing,
  encodings, UUID helpers, JWT helpers, phone normalization, `o200k_base` token
  estimation and budget truncation, and web URL classification and admission.
- `brain_chunker.rs` - CJK-aware recursive text chunking and exact `o200k_base`
  token counting for Brain retrieval positions.
- `web_proxy.rs` - a loopback SOCKS5 TCP proxy for local Chromium that validates
  both the requested host and every resolved IP address before connecting to a
  verified IP.
- `authz/` - snapshot-only authorization evaluation, CEL condition validation,
  and validation and matching for resource patterns.
- `universal_ai_client/` - native async streaming for prepared AI requests,
  covering upstream HTTP SSE/EventStream and WebSocket transport, normalization
  of provider responses and errors, terminal delivery for each Provider call,
  JSON text-chunk encoding for downstream consumers, demand credit,
  cancellation, and timeouts.
- `object_store/` - file-service storage through OpenDAL across local files,
  S3, Azure Blob, D1, COS, PostgreSQL, OSS, TOS, GCS, SFTP, and WebDAV, with
  bounded retries and per-call timeouts. Large writes consume local files or
  acknowledged binary streams in 8 MiB chunks, though some backends buffer the
  full object. Byte-range reads return only the requested bytes to the caller.
- `page_document/knowledge/` - deterministic OKF Markdown and YAML conversion
  and 3-way block and metadata merge for knowledge pages.
- `vfs/` - stateless codecs for the Drive WebDAV boundary: WebDAV `PROPFIND`
  validation and `multistatus` XML encoding, VFS path-segment and RFC 9110
  `Range` header codecs, 3-way knowledge merge and anchored Markdown document
  reconciliation (with `page_document/vfs.rs`), and Base tabular dot-directory
  query pipelines, chunked CSV/TSV/JSON/JSONL imports and exports, field-CAS
  record patches, and replay-stable UUIDv7 import IDs.
- `markdown.rs` - source-byte range extraction for inline code and fenced or
  indented code blocks, plus idempotent repair of common model-emitted Markdown
  defects outside code, math, links, HTML, and wikilinks.
- `model_image/` - validation and conversion of model images.
- `signals/` - CEL routing-policy evaluation against a supplied context.
- `page_document/` - page XML validation, canonical conversion, search text
  extraction, application of prepared Wordgard change sets, and structural or
  UTF-16 document diffs. The full round-trip chain from XML to the editor
  document and back shares its test corpus with the block editor.

Two workspace crates sit beside the root crate, because the root crate's own
dependencies do not build for WebAssembly:

- `spreadsheet/` (`ankole_spreadsheet`) - host-neutral spreadsheet documents
  over GridCraft, pinned to one Git revision for every GridCraft crate. It opens
  `.xlsx` bytes with stable sheet ids, executes and rebases the canonical
  operations, derives search text and sheet metadata, and serves the editor's
  viewport views. The NIF and the browser load the same crate. Its tests include
  the business-workbook corpus in `test/fixtures/spreadsheet/corpus`, which
  every GridCraft upgrade must keep green.
- `spreadsheet-wasm/` (`ankole_spreadsheet_wasm`) - the wasm-bindgen wrapper
  that runs `ankole_spreadsheet` in the Pod spreadsheet editor's Web Worker,
  which keeps a confirmed and a local document (`fork`) and rebases pending
  operations onto the confirmed one (`apply_rebased`).
  `bun run --filter @ankole/kernel build:wasm` (also the package `build`
  script, so Turbo builds it before the webapps) writes the module to
  `dist/spreadsheet-wasm/`. `@ankole/kernel/spreadsheet-wasm` exports that
  module with the declarations in `spreadsheet-wasm/ankole_spreadsheet_wasm.d.ts`,
  generated output that the script refreshes on every build and that stays in
  git so that type checks need no Rust toolchain, and
  `@ankole/kernel/spreadsheet-wasm/*` exposes the other build files, such as
  the `.wasm` binary that the worker loads by URL.

## Identifier Generation

For opaque PostgreSQL `uuid` row IDs, the Control Plane generates UUIDv7
identifiers with `Ash.UUIDv7.generate/0` and maps them in Ecto schemas with
`Ankole.Ecto.UUIDv7`, while native consumers call `gen_uuid_v7` from the kernel.
Database migrations declare UUID primary keys without PostgreSQL defaults such
as `gen_random_uuid()`. By contrast, Principal `uid` values, provider channel
IDs, and composite provider or runtime keys keep the semantic formats defined by
their owning domains.

## Boundary

The kernel implements mechanisms rather than product state:

- **AuthZ** evaluates explicit snapshots and never queries principals, grants,
  groups, or request context from PostgreSQL.
- **UniversalAIClient** accepts prepared provider endpoints, headers, and model
  requests. It handles protocol encoding, response and error normalization, and
  ordered terminal delivery under read credit for each call. The control plane
  consumes those results, chooses providers and credentials, applies retry
  policy, and commits the public Ankole Response—so it can compose several
  native calls into a single public Response without tracking wire-level
  protocol state.
- **ObjectStore** executes explicit storage specifications and operations, while
  the control plane owns the file lifecycle and durable references.

The kernel does not own a Worker socket or a RuntimeFabric envelope codec. The
RuntimeFabric protocol and its current version are defined in
`proto/ankole/runtime_fabric/v1/envelope.proto`, with cross-language golden
fixtures in `proto/golden`. The control plane compiles the schema via Protox in
`Ankole.RuntimeFabric`, and the Worker uses `protobuf-es`. Each side writes the
declared version when sending and verifies it on receipt, after which domain
consumers validate execution references against their authoritative state.

## Build and Transport

The repository pins its Rust toolchain in the root `rust-toolchain.toml`, uses
Thin LTO (`lto = "thin"`) for parallel release codegen, and enables local Cargo
incremental compilation in development. Whenever `sccache` is installed on
`PATH`, host Rustler and Kernel Cargo builds automatically wrap `rustc` with a
local SSD cache (`SCCACHE_CACHE_SIZE=20G` by default, stripping remote cache
backends) so dependency crates reuse compiled artifacts across clean builds
while `ankole_kernel` keeps local incremental compilation; hosts without
`sccache` (or with `ANKOLE_SCCACHE=0`) run standard Cargo cleanly.

For incremental builds and reload checks during Phoenix development, Rustler
tracks Cargo manifests and native source files while ignoring generated Mix,
Cargo, and Bun artifacts. Phoenix reloads Elixir application code and local
protocol libraries automatically, but after rebuilding the loaded NIF you must
restart the development control plane.

In development, test, and production, the control plane compiles the kernel with
the `nif` Cargo feature. `src/nif_exports.rs` converts BEAM terms and errors
before calling the underlying Rust modules: structured inputs cross the boundary
as JSON-shaped values (`Torque` in Elixir, `serde_json` in Rust), whereas raw
byte payloads stay binary.

Compiling with the `napi` Cargo feature builds a Node addon in a separate target
directory. That addon exposes shared URL facts, URL and IP-address admission,
the local browser proxy, and `estimateO200kBaseTokens` for host tests. Both the
NIF and Node-API layers only translate types and errors. Never enable `nif` and
`napi` in the same build.

```bash
bun run --filter @ankole/kernel build:node
```

This command writes `app/kernel/target/napi-build/ankole_kernel.node` (pass
`--release` for an optimized build). When building the Worker image, Docker
compiles this addon for the target architecture and bundles it with the browser
entry points. Running the Node-API TLS tests requires the `openssl` CLI on the
host.

CEL NIF calls run on a dedicated 8 MiB native stack on the dirty CPU scheduler
thread, which accommodates parsing, evaluation, and program cleanup without
requiring changes to the stack configuration of the BEAM schedulers.

`UniversalAIClient` uses the `aws-lc-rs` TLS backend in every environment: its
shared `reqwest` client speaks HTTP/1.1, while upstream WebSocket calls open
dedicated connections. There is no environment-specific TLS provider, HTTP
protocol negotiation preference, or HTTP/3 build.

Run the kernel lint and unit checks from the repository root:

```bash
bun run --filter @ankole/kernel lint
bun run --filter @ankole/kernel test
```

The block editor and the Rust page codec share valid XML fixtures, invalid XML
cases, limit boundaries, and multi-edit batches in
`libs/ankole-editor/corpus/rust`. Run
`bun run --filter @ankole/block-editor test:rust` to verify generated pages and
batched local edits against the production Rust codec (set `FC_SEED` to replay
or vary the generated corpus). After normalization, every batch must match both
the stored XML and the client's in-memory document.

Remote object-store integration tests run separately against dedicated test
storage (never point them at a production store). Provision test buckets or
backends, list their store specs as a JSON array in a local file, and run the
command below. The suite writes, overwrites, and deletes objects under unique
test keys, including transfers larger than 8 MiB on every backend except D1,
which has a smaller row-size limit.

```bash
ANKOLE_OBJECT_STORE_TEST_SPECS=/absolute/path/test-stores.json \
  cargo test --manifest-path app/kernel/Cargo.toml --no-default-features \
  --features object_store configured_remote_stores -- --ignored --nocapture
```
