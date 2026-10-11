---
title: Rust Kernel
description: Native primitives and AI transport loaded by the Elixir control plane through Rustler.
section: Developer guide
order: 109
---

The Rust Kernel is the control plane's native library. Elixir loads it through Rustler. The Bun Worker uses its own generated protobuf codec and does not load a native kernel addon.

## Native Operations

The library in `app/kernel` provides:

- **`common/`**: encryption, key derivation, password hashing, encodings, UUIDv7 identifiers, JWT helpers, and phone normalization.
- **`authz/`**: permission evaluation over explicit snapshots, CEL validation, and resource-pattern matching. The control plane supplies the data described in [Principal and AuthZ](../principal-authz/).
- **`universal_ai_client/`**: upstream HTTP SSE/EventStream and WebSocket transport, response normalization, downstream JSON text chunk encoding, demand credit, cancellation, and timeouts.
- **`object_store/`**: file-service storage over a local directory or an S3-compatible bucket.
- **`program_runner/`**, **`brain_markdoc/`**, and **`model_image/`**: programmatic tool execution, Brain body analysis, and model image conversion.
- **`signals_gateway/`**: routing-policy evaluation over a supplied context.

## Ownership

The control plane owns durable state, authorization data, provider selection, credentials, and domain commits. The kernel receives prepared inputs. It does not query PostgreSQL, schedule Agents, or own Worker sockets.

RuntimeFabric structures and protocol version 9 are declared in `proto/ankole/runtime_fabric/v1/envelope.proto`. Elixir uses Protox; the Worker uses protobuf-es. Each host sets the declared version on send and checks it on receive. Domain consumers check execution authority. Cross-language golden fixtures verify codec agreement.

## Build and Transport

One Cargo feature, `nif`, serves development, tests, and production. Rustler translates BEAM values and errors at `src/nif_exports.rs`. JSON-shaped values and byte payloads retain their respective representations at this boundary.

The shared reqwest client uses HTTP/1.1 and aws-lc-rs TLS in each environment. Upstream WebSocket calls use separate connections. Provider policy and transcript commits stay in [AIGateway](../ai-gateway/).

For Worker lifecycle and message routing, read [Actor Runtime](../actor-runtime/) and [Agent Computer Worker](../agent-computer-worker/).
