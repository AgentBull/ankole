---
title: Rust Kernel
description: The shared native layer — one Rust implementation of authorization, RuntimeFabric transport, and AI data-plane primitives, loaded by both the Elixir control plane and the Bun worker.
section: Developer guide
order: 109
---

Ankole runs on two host runtimes — an Elixir control plane and a Bun worker — and a few behaviors must mean the same thing on both sides. The Rust Kernel is where those shared native semantics live. This page maps the kernel against the real code in `app/kernel`.

The decisive property, stated up front: the kernel is one Rust crate loaded by two hosts through two binding layers, not a Bun package with an Elixir adapter or an Elixir NIF with a Bun adapter. Rust owns the low-level semantics; bindings only translate host types, naming, and errors. If a behavior must be trusted by both runtimes, it belongs here as Rust first, with bindings second.

## Two hosts, one implementation

The crate builds under mutually exclusive feature flags — `napi` for Bun's N-API, `nif_dev`/`nif_prod` for Elixir's Rustler — so the same source compiles to two native addons. A global mimalloc allocator is set explicitly, because a native addon loaded by a long-running host must keep allocator behavior identical across the N-API and NIF builds.

The binding surface mirrors this. On the Elixir side, `Ankole.Kernel` is a Rustler module whose functions fall back to `:erlang.nif_error(:nif_not_loaded)` until the native crate is loaded — `aead_encrypt`, `authz_authorize`, `runtime_fabric_router_start`, `universal_ai_client_open_nif`, `gen_uuid_v7`. On the Bun side, the same crate ships as an N-API addon. The names differ; the behavior does not.

## Why a shared kernel exists

The kernel exists to stop the Bun side and the Elixir side from developing separate meanings for the same native behavior. Without it, authorization evaluation, fabric framing, and AI streaming would drift between two implementations, and a decision made on one side could disagree with a decision made on the other. Putting the trusted behavior in Rust once, with bindings second, is what keeps the two runtimes honest with each other.

## The shared surface

Four modules carry the shared semantics:

- **`common/`** — host-neutral primitives: AEAD token encrypt and decrypt, key derivation, hashing, encodings, UUID helpers (including `gen_uuid_v7`, exposed to Elixir as `gen_uuid_v7/0` and to Bun as `genUUIDv7()`), JWT helpers, and phone normalization. These are the small trusted operations both runtimes reach for.
- **`authz/`** — snapshot-only authorization evaluation. `authorize` and `authorize_all` take an `AuthzSnapshot` and return an `AuthzDecision`; CEL condition validation and resource-pattern matching live here too. This is the deterministic evaluator the [Principal and AuthZ](../principal-authz/) page describes the control plane assembling snapshots for.
- **`runtime_fabric/`** — the RuntimeFabric v1 envelope protocol: lanes, durability classes, correlation rules, and turn/control/progress/RPC body semantics, validated over host-encoded protobuf bytes. The single structural declaration is `proto/envelope.proto`; each host derives its own codec from it — `prost-build` in Rust, `protox` in Elixir, `protoc-gen-es` in TypeScript. No host invents the structure.
- **`universal_ai_client/`** — a feature-gated native async streaming client for prepared AI provider requests: upstream HTTP SSE/EventStream and WebSocket transport, provider response normalization, downstream SSE/WebSocket chunk encoding, demand credit, and cancellation. This is the AI data-plane primitive the [AIGateway](../ai-gateway/) uses to talk to providers.

## The ZeroMQ transport

Inside `runtime_fabric/transport/`, the kernel owns the ZeroMQ ROUTER/DEALER transport split across auth, config, router, dealer, and framing modules. This is where the live control-plane-to-worker fabric actually runs:

- **ZAP/PLAIN worker authentication** — a worker authenticates with its auth key before the fabric accepts its traffic.
- **Mandatory route sends** — a send that cannot be routed fails loudly rather than silently dropping.
- **Bounded socket options** — the sockets are configured to prevent unbounded queues and the failure modes they bring.
- **Raw `ANKOLE_FILE/1` worker-file multipart frames** — file transfer between control plane and worker rides the same transport, as raw multipart frames distinct from the RPC lane.

The transport is Rust-owned on purpose. It is the one place where a dropped frame or a misrouted send would mean a worker reply landing on the wrong session, so the trusted behavior lives here and both hosts call into it.

## The boundaries

The kernel's boundaries with the two runtimes are sharp, and each is a consequence of the shared-semantics rule:

- **With the Actor Runtime.** The control plane owns actor state, the activation fence, and the durable transcript. The kernel owns the deterministic authorization evaluation and the transport that carries turn, progress, and RPC envelopes. When the Actor Runtime checks a worker reply against the fence, the decision logic that authorized the principal is kernel code; the fence rows themselves are control-plane state.
- **With the Agent Computer.** The worker owns live execution. The kernel owns the AI streaming client that worker turns use to reach providers, and the transport that carries the worker's progress and file frames back. The worker does not reimplement streaming or framing; it calls the same native surface the control plane would call for the symmetric direction.
- **With AIGateway.** The gateway owns provider routing and credentials. The kernel owns the bytes-on-the-wire: the HTTP and WebSocket transport, the response normalization, the chunk encoding a caller ultimately receives.

## What the kernel is not

It is not a place for host-specific behavior. Anything that only one runtime needs — a Phoenix plug, a Bun tool, a console route — stays in that runtime; the kernel takes only what both must trust. It is not a second authority for actor state or provider credentials; those are the control plane's. And it is not optional plumbing the hosts could replace. The whole point is that the two runtimes share one meaning for the behaviors that cross the boundary between them, and that meaning is Rust.

## Next steps

- For the authorization evaluation the kernel runs, read [Principal and AuthZ](../principal-authz/).
- For the transport the kernel carries envelopes over, read the [Actor Runtime](../actor-runtime/) and [Agent Computer](../agent-computer/) pages.
- For the AI streaming the kernel provides, read the [AIGateway API](../ai-gateway/).
