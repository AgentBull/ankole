---
title: AIGateway API
description: The OpenResponses-compatible AI boundary — HTTP, SSE, and WebSocket endpoints, stateless and stateful calls, and provider routing.
section: Developer guide
order: 101
---

AIGateway is the unified AI boundary of an Ankole deployment instance. External applications, enterprise systems, and SDKs call it directly over an OpenResponses-compatible API, while internal Agents call the same surface for their model turns. On every call, AIGateway resolves a model selector against the provider bindings that the operator configured, keeping upstream credentials strictly inside the control plane.

This page maps the routes, request shapes, and boundary between stateless and stateful calls against the control-plane router and `Ankole.AIGateway`.

## Where it fits

AIGateway sits between callers and upstream providers. A caller—an Agent's model loop, an OIDC Human, or an external integration—presents a bearer token and sends an OpenResponses-shaped request. AIGateway resolves the selector, prepares the upstream request, dispatches it to the bound provider, and returns either a single JSON body or a live event stream. LLM, embedding, rerank, web-search, and web-fetch capabilities all flow through this boundary. When a response turn uses `programmatic_tool_calling`, AIGateway executes each `programmatic_tool_call` TypeScript program inside a stateless isolate on `ankole-function-runtime` (`Ankole.FunctionRuntime.ProgramRunner`).

Callers never see upstream provider credentials: the control plane owns all credentials and routing policies, while each caller supplies only its bearer token and model selector.

## Authentication

Every endpoint under `/api/v1/ai-gateway` runs through the `:ai_gateway_api` pipeline and the `RequireAIGatewayAccessToken` plug. Every request must present a bearer token in the `Authorization` header, and the plug accepts exactly two token kinds:

- **Agent token** — an AIGateway API key whose subject is an active Agent Principal; calls are scoped to that Agent's model bindings and selectors, with `subject_type = "agent"`.
- **OIDC Human token** — issued to an active Human by an OIDC Client granted `ai_gateway.write`; calls resolve against that Client's model aliases, with `subject_type = "oidc_human"`.

To obtain an OIDC Human token, create an OIDC Client in the Console with the `ai_gateway.write` scope, configure its allowed groups and model aliases, and sign in using Authorization Code with PKCE (request `offline_access` to receive a rotating Refresh Token for long-lived sessions). The Human must belong to an allowed group and may use only the Client's configured model aliases; raw `provider_id/model` selectors are rejected.

If a request omits the token or presents one that cannot be verified, the plug returns `401` with `code: "invalid_token"`. AIGateway has no anonymous access path.

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Summarize the open incidents."}'
```

## The endpoints

All routes live under `/api/v1/ai-gateway`, and the transport that each endpoint uses is part of its contract rather than a caller preference:

| Method | Path | Transport | Purpose |
|---|---|---|---|
| `GET` | `/models` | HTTP | List model selectors visible to this subject |
| `POST` | `/responses` | HTTP or SSE | Create a response; stream when `"stream": true` |
| `GET` | `/responses` | WebSocket | Stateful streaming responses |
| `GET` | `/responses/:response_id` | HTTP | Retrieve a stored stateful response (`resp_{uuid}`) |
| `POST` | `/embeddings` | HTTP | Create embeddings |
| `POST` | `/rerank` | HTTP | Rerank documents |
| `POST` | `/web_search` | HTTP | Search the web |
| `POST` | `/web_fetch` | HTTP | Fetch web pages |
| `GET/POST/DELETE` | `/files`, `/files/:id`, `/files/:id/content` | HTTP | Upload, read, and delete files |

`POST /responses` sits at the center of the surface: it drives model turns and is the only endpoint that branches on both transport and statefulness.

## Stateless responses over HTTP and SSE

A stateless call follows a single request/response cycle: the caller sends the complete input, AIGateway resolves the selector and calls the upstream provider, and the endpoint returns the full JSON body. Pass `"stream": true` and the same endpoint switches to Server-Sent Events, opening an SSE stream that emits typed events as `event: <type>\ndata: <json>\n\n` and finishes with `data: [DONE]`.

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Draft a release note.","stream":true}'
```

Stateless HTTP and SSE share one strict rule: neither accepts the stateful fields `previous_response_id`, `conversation`, or `store`. Any caller that needs multi-turn state continuation must use the WebSocket endpoint instead; sending a stateful field over HTTP or SSE returns `400` with `code: "stateful_responses_require_websocket"` and a message naming the offending field.

## Stateful responses over WebSocket

Stateful responses run on `GET /responses` via a WebSocket upgrade, which hands the connection to `AIGatewayResponsesSocket` with the subject's identity, a 30-minute idle timeout, compression, and a 128 MiB frame ceiling. Because the client sends no frames while waiting for a model response, that 30-minute idle timeout also bounds the maximum duration of a single turn, matching the upstream first-byte and idle budgets. Over WebSocket, callers may set `store: true` and continue an existing thread via `previous_response_id` or `conversation`.

This WebSocket path hosts the durable response lifecycle. Each stored response receives an ID formatted as `resp_{uuid}` so later turns can continue from `previous_response_id` or reference a stored `conversation`. The control plane manages continuation rules, durable history, compaction, response projection, and crash recovery—none of that burden falls on the caller.

You can retrieve any stored response later over plain stateless HTTP:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses/resp_4f3c... \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN"
```

Compaction replaces a long stored history with a compact checkpoint without losing thread continuity. Rather than exposing a separate endpoint, AIGateway accepts a `{"type": "compaction_trigger"}` item in `input` and responds with a single `compaction` output item across any transport (`POST /responses` for JSON, `"stream": true` for SSE, or WebSocket). If you send only the trigger alongside `previous_response_id` or `conversation`, AIGateway compacts the stored conversation and returns the new checkpoint ID to continue from; if you include history items alongside the trigger, AIGateway compacts the history that you sent.

## Provider routing

Before making any upstream call, AIGateway resolves the model selector to a concrete provider binding. Every Agent has eight built-in profiles: five language-model profiles (`primary`, `light`, `heavy`, `coding`, and `vision_fallback`) and three capability profiles (`web_search`, `web_fetch`, and `image_generate`), plus any custom language-model profiles configured on the Agent. Administrators instead use explicit provider entries. Call `GET /models` to list every selector that the current subject can resolve, with optional OpenRouter-style query filters (`q`, `context`, `min_price`, `max_price`, `sort`, and modality filters).

Each provider row manages a credential pool whose members share the row's provider kind, base URL, headers, settings, and capability declarations. Model profiles point to the provider row as a whole rather than to a specific pool member, and AIGateway picks a healthy credential using the configured `fill_first`, `round_robin`, `least_used`, or `random` strategy (translated in the Console UI for the active locale, while the API and database always use those canonical keys). Whenever possible, AIGateway keeps a stateful thread on the same pool member across turns.

When an upstream call fails with an attributed `429`, `5xx`, or transport error, AIGateway places only that specific credential on cooldown, selects another healthy member from the pool, rebuilds the upstream request, and retries with bounded exponential backoff and jitter. The Rust kernel executes one transport attempt at a time, and AIGateway never crosses over to a different provider if the bound pool is exhausted.

`chatgpt_subscription` works like any other provider kind: its OAuth credentials remain encrypted in the control plane, where token refresh runs under a database row lock, so neither the Agent Computer nor external callers ever receive those tokens.

`agentbull_cloud` (**AgentBull Cloud**, default base URL `https://cloudapis.agentbull.com`) is a built-in aggregated upstream provider kind that serves language models, embeddings, reranking, `web_search`, `web_fetch`, and `image_generate` with a single API key. Its credentials likewise stay in the control plane, whereas external API keys read directly by Worker MCP skills continue to live in `WorkerEnv`.

Callers should handle two selector-resolution errors:

- `422 unknown_model_selector` — the selector is not bound for this subject.
- `422 model_binding_not_configured` — the capability and profile name are bound, but the underlying provider binding is incomplete.

Requesting a capability that the bound provider does not support returns `422 unsupported_capability`, and calling a provider that an operator disabled returns `422 provider_disabled`. All four `422` codes reflect configuration state rather than transient failures, so retrying without updating configuration will not succeed.

## Error shapes

Errors return an OpenAI-compatible JSON envelope (`{"error": {"code", "message"}}`) paired with an HTTP status matching the failure class:

- `400` — request validation failed (missing `model` or `input`, invalid `limit` or `top_n`, a stateful field sent over HTTP, or malformed compaction input); `code` identifies the offending field or rule.
- `401` — the bearer token is missing or cannot be verified.
- `429` — every credential in the selected provider's pool is cooling down (`code: "credential_pool_exhausted"`, with `retry_at` included whenever AIGateway knows the earliest recovery timestamp).
- `404` — the requested stored response, conversation, Agent, or file does not exist for this subject.
- `422` — the request is well-formed, but configuration prevents serving it (unknown selector, incomplete binding, unsupported capability, or disabled provider).
- `502` / `504` — the upstream provider failed: `502` covers transport and malformed-response errors (`upstream_transport_failed`, `invalid_upstream_response`, `ai_gateway_request_failed`), while `504` signals `upstream_timeout`. Upstream `4xx` client errors pass through with their original HTTP status.

When the upstream response includes an `error.message`, AIGateway forwards that message; otherwise, it reports the upstream HTTP status directly.

## Programmatic tool calling and image generation

When a `/responses` request enables the `programmatic_tool_calling` tool, AIGateway synthesizes a `program` tool from eligible tool descriptors. It executes each `programmatic_tool_call` as a deterministic TypeScript program inside a stateless isolate on `ankole-function-runtime` via `Ankole.FunctionRuntime.ProgramRunner`, suspending at nested tool boundaries while AIGateway retains ownership of history, ordering, and cancellation.

`image_generation` is a public Responses tool with two execution paths. When the subject has an `image_generate` profile configured, AIGateway runs the tool through that dedicated provider and model. Otherwise, AIGateway forwards the tool to the main language-model provider only when its capability declares native image generation; if neither path is available, AIGateway fails request preparation instead of simulating the tool.

Both execution paths emit identical stream events and persist generated images in the same way, attributing model usage and image usage separately to whichever credential produced each output.

## Web tools, files, and the other capabilities

The same Principal identity and bearer token authorize AIGateway's remaining endpoints. `POST /web_search` accepts a length-bounded `query` and returns provider-backed search results, while `POST /web_fetch` fetches content from one to five public HTTPS URLs; both accept `web_search.default` and `web_fetch.default` to resolve the calling Agent's configured profiles.

`POST /embeddings` accepts strings, token arrays, or structured input blocks, and `POST /rerank` reranks a non-empty document array using a positive integer `top_n`. Unlike `/responses`, both endpoints require an explicit `provider_id/model` selector rather than an Agent profile name—for example, Brain reads the site `brain.embedding_model` key and the tenant `brain.rerank_model` key from [AppConfigure](../app-configuration/) when calling them (see [Brain](../brain/) for retrieval details). Meanwhile, Pod Applet `ctx.ai` calls route statelessly through AIGateway under the active Agent that created the Applet, drawing on that Agent's language-model profiles, token quota, and usage attribution.

File endpoints are likewise scoped to the authenticated subject: `POST /files` uploads a file, `GET /files` lists uploaded files, `GET /files/:id` and `GET /files/:id/content` fetch metadata and raw bytes, and `DELETE /files/:id` deletes a file.

## What AIGateway is not

AIGateway is not an open, unauthenticated proxy, nor do callers pass upstream provider keys in requests—all provider credentials stay inside the control plane. It is also not a background queue or job runner; multi-step autonomous execution belongs to Sessions and Background Agent Jobs. AIGateway is strictly the synchronous and streaming request/response boundary: one authenticated request in, one response or stream out, with selectors resolved and credentials kept server-side.

## Next steps

- For where AIGateway sits in the whole system, read the [architecture overview](../architecture/).
- For running the server that hosts these routes, read the [deployment section of Quick start](../quickstart/#deployment).
- For the first Provider and model-profile setup, read [Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent).
