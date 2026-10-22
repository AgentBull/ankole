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
- `program_runner/` - one-shot AIGateway Programmatic Tool Calling execution
  in a fresh `deno_core` isolate on a native thread. Handles own cancellation
  before task launch and monitor the owner and execution processes. Replay
  returns the first pending tool batch; no isolate survives that pause.
- `applet_runtime/` - live Applet backend routes in a fresh capability-only
  `deno_core` isolate, with asynchronous control-plane request and reply.
- `isolate_control.rs` - shared V8 timeout, heap, and cancellation authority.
- `brain_markdoc/` - analysis of Brain bodies over CommonMark.
- `model_image/` - model image validation and conversion.
- `signals/` - CEL routing-policy evaluation over a supplied context.
- `page_document/` - page XML validation, canonical conversion, search text,
  and prepared Wordgard change-set application. The complete
  XML to editor document to XML chain shares its corpus with the block editor.

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

## Applet Backend Runtime

`Ankole.Kernel.AppletRuntime.start/3` starts a native thread for one request.
The caller receives capability requests and sends each result with `reply/3`.
The isolate remains alive while a request waits. It does not replay code or
share globals with other requests. Owner process exit and `cancel/1` terminate
that isolate. Normal scheduler NIFs retain BEAM binaries without copying their
bytes. Request and capability reply JSON decoding runs on the invocation's
native thread, as does the handler. Applet and ProgramRunner calls have separate
limits of four native executions. No BEAM scheduler stays reserved while the
isolate executes or waits. Cancellation stays on a normal scheduler so that it can
interrupt active invocations. The timeout budget starts before thread creation
and request decoding, and is not reset when execution starts.

The runtime has no module loader, network, filesystem, environment, process,
or timers. An AST check rejects static imports, re-exports from other modules,
and dynamic imports anywhere in the bundle. Inspection and invocation use the
same route validation and matching code. Inspection does not run handlers;
any top-level capability attempt rejects the bundle, including a caught call.

A wall-clock watchdog covers module evaluation, handler execution, and waits
for capabilities. The shared V8 termination authority also owns cancellation
and heap pressure. A custom ArrayBuffer allocator rejects external allocations
that exceed the memory budget. V8 interrupts check the combined JS heap and
external buffer allocation. This includes SharedArrayBuffer backing stores.
Retained console logs and outstanding capability arguments use this same
budget. They do not have a separate count or byte quota. Memory-pressure tests
run in a subprocess and check that a later invocation still succeeds. The
isolate shares the host OS process, so a V8 vulnerability
is outside this boundary. A committed capability write is not rolled back.
