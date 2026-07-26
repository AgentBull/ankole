---
title: Provider runtime
description: How AIGateway resolves a selector to a provider, builds a prepared request, and dispatches it through the kernel — the three stages from a model call to a provider response.
section: Developer guide
order: 119
---

A model call travels through three stages before it reaches a provider: the resolver turns a selector into a provider runtime map, the provider module builds a prepared request, and the kernel's `UniversalAIClient` executes it. This page documents the path, against the real code in `ai_gateway/resolver.ex`, `providers.ex`, and `universal_ai_request.ex`. It builds on [AIGateway](../ai-gateway/) and [Adding a provider](../adding-a-provider/).

The decisive property, stated up front: the resolver, the provider module, and the kernel each own one stage, and none crosses into another. The resolver owns selector-to-runtime resolution; the provider module owns request preparation; the kernel owns the wire. A failure surfaces as the error from the stage that caught it, and the caller sees which stage failed.

## Stage 1: resolution (Resolver)

`Ankole.AIGateway.Resolver` turns the `model` field of a request into a concrete provider runtime map. The resolver is where a subject-visible selector — `primary`, `light`, `embedding.default`, or an explicit `provider_id/model` — becomes a provider id, a provider kind, an upstream model name, and the resolved runtime settings.

LLM aliases (`primary`, `light`, `heavy`, `coding`, `vision_fallback`) resolve through the agent's model profiles. Embedding and rerank accept `default`, explicit default bindings (`embedding.default`), or explicit selectors. Provider modules never see the selector or the subject — they receive the resolved runtime map only. The resolver is the sole point where subject identity and model profiles are consulted.

Resolution can fail before any provider is contacted:

- `422 unknown_model_selector` — the selector is not bound for this subject.
- `422 model_binding_not_configured` — the capability and name are bound but the provider row is incomplete.

These are the errors [Providers and models](../providers-and-models/) tells operators to check.

## Stage 2: preparation (Provider module + Providers)

With the runtime map resolved, `Ankole.AIGateway.Providers` dispatches to the provider module's prepare function. The entrypoints are typed by capability:

```elixir
build_response_request(runtime, request)    # :language_model
build_embeddings_request(runtime, request)  # :embedding_model
build_rerank_request(runtime, request)      # :rerank_model
build_web_search_request(runtime, request)  # :web_search
build_web_fetch_request(runtime, request)   # :web_fetch
build_image_generate_request(runtime, request) # :image_generate
```

Each delegates to `build_prepared_request/4`, which looks up the capability on the provider's `ProviderDefinition`, verifies the provider supports it (`supports_capability?/2`), and calls the capability's `prepare` function — the normal Elixir function that builds a `UniversalAIRequest` struct from the resolved settings and the request.

This is the stage where provider differences live: URL construction, auth headers, body shaping, the quirks of a specific upstream API. The prepared request is a `UniversalAIRequest` — a struct with a path, an `api_resolver` atom, headers, and provider options — not an HTTP call.

## Stage 3: execution (UniversalAIRequest → kernel)

`UniversalAIRequest` is a thin execution adapter from AIGateway to the kernel's `UniversalAIClient`. Its moduledoc: "Provider modules prepare the UniversalAIClient spec. This module only executes it and preserves the HTTP/SSE ready boundary expected by Phoenix callers."

The execution hands the prepared request to the Rust kernel, which:

- resolves the `api_resolver` to the wire protocol (encoding, transport),
- opens the upstream connection (HTTP SSE, EventStream, WebSocket, or plain JSON, as the capability's `upstream` declared),
- sends the request with the provider's auth and headers,
- receives the response stream,
- normalizes it into the downstream chunk format.

This is the stage the [Kernel](../kernel/) page documents: the `universal_ai_client` module in Rust, with its transport, demand credit, and cancellation. The provider module does not participate in execution; it handed off a prepared request and the kernel owns the wire from there.

## How a failure surfaces

Each stage produces a distinct class of error:

| Stage | Failure shape | What it means |
|---|---|---|
| Resolution | `422 unknown_model_selector` / `model_binding_not_configured` | the selector or binding is wrong — configuration, not transient |
| Preparation | `422 unsupported_capability` / provider-specific validation | the provider does not serve this capability, or the request options are invalid |
| Execution | `502 upstream_response_failed` / `504 upstream_timeout` | the provider returned an error or timed out — may be transient |

The error class tells the caller whether to fix configuration (422), wait and retry (502/504), or investigate the provider. The [AIGateway](../ai-gateway/) page documents the full error envelope.

## The registry and plugin-contributed providers

The provider registry in `Providers` holds the compiled `ProviderDefinition` structs. First-party providers are compiled in; plugin-contributed providers arrive through the `ai_gateway.provider` contract, and `refresh_from_adapter_declarations/1` merges them into the registry. A provider kind must match `~r/\A[a-z][a-z0-9_]{0,62}\z/`, and the registry caches the merged set so resolution does not re-scan plugins on every call.

## What this guide is not

It is not a provider-authoring tutorial — see [Adding a provider](../adding-a-provider/) for the DSL, the definition, and the prepare function. It is not a wire-protocol reference — the kernel owns the wire, and that is the [Kernel](../kernel/) page. And it is not a substitute for reading the three modules; this page is the path through them.

## Next steps

- For how to write a provider, read [Adding a provider](../adding-a-provider/).
- For the AIGateway concept page (endpoints, error shapes), read [AIGateway](../ai-gateway/).
- For the kernel that executes the request, read [Kernel](../kernel/).
- For the model profiles that feed the resolver, read [Providers and models](../providers-and-models/).
