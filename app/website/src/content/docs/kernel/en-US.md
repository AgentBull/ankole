---
title: Rust Kernel
description: Native primitives and AI transport loaded by the Elixir control plane through Rustler.
section: Developer guide
order: 109
---

The Rust Kernel provides stateless native primitives and AI transport for the Elixir control plane, which loads it in-process through Rustler. Meanwhile, the Bun Worker uses its own generated protobuf codec rather than loading the Rust NIF library.

## Native Operations

The Rust crate under `app/kernel/src` groups its native primitives by domain:

- **`common/`**: AEAD encryption, key derivation, encodings, hashing, UUIDv7 generation, JWT helpers, phone normalization, reciprocal rank fusion, token estimation, and SSRF checks on URLs and IP addresses.
- **`authz/`**: permission evaluation over explicit snapshots, CEL validation and condition evaluation, and resource-pattern matching. The control plane assembles and supplies the snapshots described in [Principal and AuthZ](../principal-authz/).
- **`universal_ai_client/`**: upstream HTTP SSE/EventStream and WebSocket transport, response normalization, encoding for downstream JSON text chunks, demand-based backpressure credit, cancellation, and timeouts.
- **`object_store/`**: file-service storage backed by either a local directory or an S3-compatible bucket.
- **`page_document/`**: validating XML trees for Pod pages, applying Wordgard changesets, and computing UTF-16 diffs.
- **`brain_markdoc/`** and **`markdown.rs`**: analyzing Brain document bodies and parsing Markdown.
- **`model_image.rs`**: decoding, resizing, and converting images for model requests.
- **`web_proxy.rs`**: a loopback SOCKS5 `CONNECT` proxy that enforces SSRF checks on resolved IP addresses for Worker Chromium sessions.
- **`signals/`**: evaluating signal routing policies against a caller-supplied context.

## Ownership

The Elixir control plane owns durable state, authorization snapshots, provider selection, credentials, and domain transactions, whereas the Rust Kernel operates strictly on prepared inputs. Because the kernel is stateless, it never queries PostgreSQL, schedules Agents, or holds Worker sockets. Isolated TypeScript execution—both for programmatic tool calling and for backend functions in Pod Applets—runs in the separate stateless `ankole-function-runtime` service rather than in the Rust Kernel.

`app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto` declares the RuntimeFabric wire structures and protocol version `10`. Elixir encodes envelopes with Protox, while the Bun Worker uses `protobuf-es`. Each side stamps the declared protocol version when sending and verifies it on receipt, domain consumers enforce execution authority, and cross-language golden fixtures verify that both codecs agree byte for byte.

## Build and Transport

Cargo exposes two host bindings from the same crate: the `nif` feature serves the Elixir control plane through `src/nif_exports.rs`, where Rustler translates BEAM terms and error tuples, while the `napi` feature serves the Worker browser daemon and host tests through `src/napi_exports.rs`. Both JSON-shaped structures and raw byte payloads keep their native representations across the NIF boundary.

For outbound AI requests, each environment shares a `reqwest` client configured for HTTP/1.1 with `aws-lc-rs` TLS, while upstream WebSocket requests open dedicated connections. Provider retry policies and transcript commits remain in [AIGateway](../ai-gateway/).

For Worker lifecycle management and message routing, see [Sessions](../sessions/) and [Agent Computer Worker](../agent-computer-worker/).
