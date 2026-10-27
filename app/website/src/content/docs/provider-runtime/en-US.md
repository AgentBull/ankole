---
title: Provider runtime
description: How AIGateway resolves a selector to a provider, builds a prepared request, and dispatches it through the kernel — the three stages from a model call to a provider response.
section: Developer guide
order: 119
---

Every model call passes through three stages before reaching an upstream provider: `Ankole.AIGateway.Resolver` maps a model selector to a concrete runtime map, the provider module builds a `UniversalAIRequest` specification, and the Rust kernel's `UniversalAIClient` executes the wire call. This page traces that pipeline across `ai_gateway/resolver.ex`, `providers.ex`, and `universal_ai_request.ex`, building on [AIGateway](../ai-gateway/) and [Adding a provider](../adding-a-provider/).

Each component owns a single responsibility: the resolver handles selector lookup, credential-pool selection, and OAuth token refresh; the provider module shapes the upstream request; and the Rust kernel executes a single wire attempt. While the control-plane attempt wrapper can rotate to another credential and rebuild the request after a failure, the kernel itself never chooses credentials or retries autonomously.

## Stage 1: resolution (Resolver)

`Ankole.AIGateway.Resolver` translates a request's `model` field—such as `primary`, `web_search.default`, or an explicit `provider_id/model`—into a provider runtime map containing the provider ID, provider kind, upstream model identifier, and resolved runtime settings.

Every Agent exposes eight built-in model profiles: `primary`, `light`, `heavy`, `coding`, `vision_fallback`, `web_search`, `web_fetch`, and `image_generate` (where `coding` is the API and storage key for the user-facing Background Agent Jobs profile). The first five profiles select language models, while the remaining three select dedicated web-search, web-fetch, and image-generation providers.

Embeddings and reranking are not configured as per-Agent profiles. Direct AIGateway requests for those capabilities must pass an explicit `provider_id/model` selector, while Brain reads the site-wide embedding model from `brain.embedding_model` and each tenant's rerank model from `brain.rerank_model` in [AppConfigure](../app-configuration/); see [Brain](../brain/) for how they affect retrieval.

Once the resolver locates the provider row, it picks a usable credential from the pool—honoring thread affinity first before applying the provider's `fill_first`, `round_robin`, `least_used`, or `random` strategy—and attaches that exact credential ID to the runtime map for downstream failure attribution. For ChatGPT Subscription OAuth credentials, the resolver refreshes near-expiry or stale tokens while holding a row lock on the provider: if a refresh fails permanently, the resolver marks that pool member `dead`; if it fails transiently, the resolver marks it `exhausted`—and in either case selects the next usable member.

Resolution can fail before Ankole contacts any upstream provider:

- `422 unknown_model_selector` — no binding exists for this selector on the calling subject.
- `422 model_binding_not_configured` — the capability and profile name exist, but the target provider row is incomplete.

Both errors point to a missing model profile, a disabled Provider, or an incomplete Provider configuration.

When every member of the credential pool is unusable, the resolver instead returns `credential_pool_exhausted` along with the non-secret status of each member, including `retry_at` only when a cooling-down member has a known recovery timestamp.

## Stage 2: preparation (Provider module + Providers)

With the runtime map resolved, `Ankole.AIGateway.Providers` invokes the provider module's preparation entrypoint for the requested capability:

```elixir
build_response_request(runtime, request)       # :language_model
build_embeddings_request(runtime, request)     # :embedding_model
build_rerank_request(runtime, request)         # :rerank_model
build_web_search_request(runtime, request)     # :web_search
build_web_fetch_request(runtime, request)      # :web_fetch
build_image_generate_request(runtime, request) # :image_generate
```

Each function delegates to `build_prepared_request/4`, which looks up the capability on the provider's `ProviderDefinition`, verifies that the provider supports it (`supports_capability?/2`), and calls the capability's `prepare` callback to construct a `UniversalAIRequest` struct from the resolved runtime settings and caller payload. Alongside the request fields, Ankole attaches a rebuild context—used only in the control plane—carrying the selected credential ID, and strips that context before passing the struct across the Rust NIF boundary.

All upstream API differences—endpoint URLs, authentication headers, JSON body structure, and vendor-specific options—live in this pure Elixir preparation step, producing a `UniversalAIRequest` struct (path, `api_resolver` atom, headers, and provider options) without opening any network connection.

## Stage 3: execution (UniversalAIRequest → kernel)

`UniversalAIRequest` acts as the thin execution bridge between AIGateway and the Rust kernel's `UniversalAIClient`, running the prepared specification and streaming back chunks in the HTTP/SSE shape expected by Phoenix controllers.

When invoked, the Rust kernel:

- maps `api_resolver` to the upstream wire codec and transport,
- opens the upstream connection (HTTP SSE, EventStream, WebSocket, or plain JSON, matching the capability's `upstream` declaration),
- transmits the request with the prepared authentication and provider headers,
- reads the upstream response stream, and
- normalizes chunks into Ankole's downstream wire format.

On both success and failure, the kernel returns a filtered subset of upstream response headers—retaining the `x-codex-*` rate-limit headers and `cf-mitigated` while stripping credentials, cookies, and other vendor headers—so the control plane can project rate limits, schedule cooldowns, and detect Cloudflare challenges safely.

In the control plane, `CredentialAttempts` wraps each kernel attempt. When a `429`, `5xx`, or transport error is attributed to a specific credential, `CredentialAttempts` marks only that credential, selects another healthy pool member, rebuilds the authorization and provider headers, waits with exponential backoff and jitter, and dispatches a fresh attempt through the kernel. If the pool has only one usable member, `CredentialAttempts` permits a single retry on that same credential; if an error carries no credential ID, it leaves pool members unmarked and stops after one pass across the pool. Once every pool member is unavailable, `CredentialAttempts` returns `credential_pool_exhausted` without failing over to another provider.

This wire stage is covered in [Kernel](../kernel/), which details `universal_ai_client` transport, demand credit, and cancellation in Rust; the Elixir provider module plays no part during wire execution.

## How a failure surfaces

Each stage surfaces its own error category so callers know how to respond:

| Stage | Failure shape | What it means |
|---|---|---|
| Resolution | `422 unknown_model_selector` / `model_binding_not_configured` | Selector or binding misconfiguration — fix settings rather than retrying |
| Credential pool | `429 credential_pool_exhausted` | Every pool member is disabled, dead, or cooling down — wait until `retry_at` if present, or repair credentials |
| Preparation | `422 unsupported_capability` / provider-specific validation | The provider does not support this capability, or request options are invalid |
| Execution | `502 upstream_response_failed` / `504 upstream_timeout` | Upstream provider error or timeout — often transient and safe to retry |

From the status code alone, callers can tell whether to fix configuration (`422`), wait for cooldown or credential repair (`429`), or retry a transient upstream fault (`502`/`504`). See [AIGateway](../ai-gateway/) for the full error envelope.

## The registry and plugin-contributed providers

`Ankole.AIGateway.Providers` maintains the merged registry of `ProviderDefinition` structs: built-in providers are compiled directly into the control plane, while Control Plane Plugins contribute additional providers via the `ai_gateway.provider` adapter contract, merged by `refresh_from_adapter_declarations/1`. Every provider kind must match `~r/\A[a-z][a-z0-9_]{0,62}\z/`, and the registry caches the merged map so request resolution never re-scans plugins per call.

## What this guide is not

This page traces how a request moves through resolution, preparation, and execution, rather than walking through how to build a new provider—for the provider DSL and `prepare` callbacks, see [Adding a provider](../adding-a-provider/). For the Rust wire transport itself, see [Kernel](../kernel/).

## Next steps

- For how to write a provider, read [Adding a provider](../adding-a-provider/).
- For the AIGateway concept page (endpoints, error shapes), read [AIGateway](../ai-gateway/).
- For the kernel that executes the request, read [Kernel](../kernel/).
- For the first model-profile setup, read [Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent).
