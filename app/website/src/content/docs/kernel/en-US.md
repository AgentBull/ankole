---
title: Rust Kernel
description: Native primitives and AI transport loaded by the Elixir control plane through Rustler.
section: Developer guide
order: 109
---

The Rust Kernel is the control plane's native library. Elixir loads it through Rustler. The Bun Worker uses its own generated protobuf codec.

## Native Operations

The library in `app/kernel/src` provides:

- **`common/`**: AEAD encryption, key derivation, encodings, hashing, UUIDv7 identifiers, JWT helpers, phone normalization, reciprocal rank fusion, token estimation, and URL/IP SSRF checks.
- **`authz/`**: permission evaluation over explicit snapshots, CEL validation and condition evaluation, and resource-pattern matching. The control plane supplies the data described in [Principal and AuthZ](../principal-authz/).
- **`universal_ai_client/`**: upstream HTTP SSE/EventStream and WebSocket transport, response normalization, downstream JSON text chunk encoding, demand credit, cancellation, and timeouts.
- **`object_store/`**: file-service storage over a local directory or an S3-compatible bucket.
- **`page_document/`**: Pod page XML tree validation, Wordgard changeset application, and UTF-16 diffing.
- **`brain_markdoc/`** and **`markdown.rs`**: Brain body analysis and Markdown parsing.
- **`model_image.rs`**: model image decoding, resizing, and conversion.
- **`web_proxy.rs`**: loopback SOCKS5 `CONNECT` proxy with resolved-address SSRF checks for Worker Chromium sessions.
- **`signals/`**: routing-policy evaluation over a supplied context.

## Ownership

The control plane owns durable state, authorization data, provider selection, credentials, and domain commits. The kernel receives prepared inputs. It does not query PostgreSQL, schedule Agents, or own Worker sockets. Isolated TypeScript execution for programmatic tool calling and Pod Applet backend functions runs in the stateless `ankole-function-runtime` service, not in the Rust Kernel.

RuntimeFabric structures and protocol version 10 are declared in `app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto`. Elixir uses Protox; the Worker uses protobuf-es. Each host sets the declared version on send and checks it on receive. Domain consumers check execution authority. Cross-language golden fixtures verify codec agreement.

## Build and Transport

The `nif` Cargo feature serves the Elixir control plane through `src/nif_exports.rs`, and `napi` serves the Worker browser daemon and host tests through `src/napi_exports.rs`. Rustler translates BEAM values and errors at `src/nif_exports.rs`. JSON-shaped values and byte payloads keep their respective representations at this boundary.

The shared reqwest client uses HTTP/1.1 and aws-lc-rs TLS in each environment. Upstream WebSocket calls use separate connections. Provider policy and transcript commits stay in [AIGateway](../ai-gateway/).

For Worker lifecycle and message routing, read [Sessions](../sessions/) and [Agent Computer Worker](../agent-computer-worker/).
