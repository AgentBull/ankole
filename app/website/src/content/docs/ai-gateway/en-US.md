---
title: AIGateway API
description: The OpenResponses-compatible AI boundary — HTTP, SSE, and WebSocket endpoints, stateless and stateful calls, and provider routing.
section: Developer guide
order: 101
---

AIGateway is the unified AI boundary of an Ankole deployment instance. External applications, enterprise systems, and SDKs call it directly over an OpenResponses-compatible API; internal agents call the same surface for their model turns. Every call resolves a model selector against the provider bindings the operator configured, and the upstream credentials never leave the control plane.

This page documents the real routes, request shapes, and the boundary between stateless and stateful calls. The source of truth is the control-plane router and the `Ankole.AIGateway` module; treat this page as the map, not the contract.

## Where it fits

AIGateway sits between callers and providers. A caller — an agent's model loop, a console operator, or an external integration — presents a bearer token and sends an OpenResponses-shaped request. AIGateway resolves the selector, prepares the request, fans it out to the bound provider, and returns either a single JSON body or a stream. LLM, embedding, rerank, web-search, and web-fetch capabilities all flow through the same boundary.

The decisive property: a caller never sees a provider credential. The control plane owns the credentials and the routing policy; the caller owns only its token and its selector.

## Authentication

Every endpoint under `/api/v1/ai-gateway` runs through the `:ai_gateway_api` pipeline and the `RequireAIGatewayAccessToken` plug. A request must present a bearer token in the `Authorization` header, and the plug accepts exactly two kinds:

- **an agent token** — an AIGateway API key whose subject is an active agent Principal; the call is scoped to that agent's model bindings and selectors, with `subject_type = "agent"`;
- **an admin token** — an active human admin console token; the call is scoped to the operator's view of providers, with `subject_type = "admin_human"`.

A missing or unverifiable token returns `401` with `code: "invalid_token"`. There is no anonymous path.

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Summarize the open incidents."}'
```

## The endpoints

All routes live under `/api/v1/ai-gateway`. The transport an endpoint uses is part of its contract, not a preference.

| Method | Path | Transport | Purpose |
|---|---|---|---|
| `GET` | `/models` | HTTP | List model selectors visible to this subject |
| `POST` | `/responses` | HTTP or SSE | Create a response; stream when `"stream": true` |
| `GET` | `/responses` | WebSocket | Stateful streaming responses |
| `GET` | `/responses/:response_id` | HTTP | Retrieve a stored stateful response (`resp_{uuid}`) |
| `POST` | `/responses/compact` | HTTP | Produce a compaction artifact for a stored conversation |
| `POST` | `/embeddings` | HTTP | Create embeddings |
| `POST` | `/rerank` | HTTP | Rerank documents |
| `POST` | `/web_search` | HTTP | Search the web |
| `POST` | `/web_fetch` | HTTP | Fetch web pages |
| `GET/POST/DELETE` | `/files`, `/files/:id`, `/files/:id/content` | HTTP | Upload, read, and delete files |

`POST /responses` is the center of the surface. It carries the model turn and is the only endpoint that branches on transport and on state.

## Stateless responses over HTTP and SSE

A stateless call is one request, one response. The caller sends the full input, AIGateway resolves the selector, calls the provider, and returns the complete body. Set `"stream": true` and the same endpoint switches to Server-Sent Events: AIGateway opens an SSE stream, writes typed events as `event: <type>\ndata: <json>\n\n`, and ends with `data: [DONE]`.

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Draft a release note.","stream":true}'
```

Stateless HTTP and SSE share one hard rule: they reject the stateful fields `previous_response_id`, `conversation`, and `store`. If a request needs continuation across turns, it must use the WebSocket path. A request that sends a stateful field over HTTP or SSE gets `400` with `code: "stateful_responses_require_websocket"` and a message naming the offending field.

## Stateful responses over WebSocket

Stateful responses live on `GET /responses` upgraded to WebSocket. The upgrade hands the connection to `AIGatewayResponsesSocket` with the subject's identity, a 300-second idle timeout, compression, and a 128 MiB frame ceiling. Over this transport a call may set `store: true` and continue an existing conversation with `previous_response_id` or `conversation`.

This is where the durable lifecycle lives. A stored response gets an id of the form `resp_{uuid}`. Subsequent turns reference it with `previous_response_id`; a stored conversation is referenced by `conversation`. The control plane owns the continuation rules, the durable history, compaction, response projection, and recovery — none of that is the caller's job.

Retrieve a stored response later, stateless and over plain HTTP:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses/resp_4f3c... \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN"
```

Compaction is the one tool that trades a long stored history for a shorter one without losing the thread. `POST /responses/compact` takes a request whose input is exactly one compaction item, anchored on a `previous_response_id` or `conversation`, and returns a compaction artifact. It requires `store: true`; a request that omits it gets `400` with `code: "compact_store_required"`.

## Provider routing

AIGateway resolves a model selector to a real provider binding before any upstream call. The selector is what the caller sees — for example `main`, or an explicit provider-owned name — and the resolution depends on the subject: an agent's selectors come from its configured model bindings, while an admin sees the explicit provider entries. `GET /models` lists what the current subject can resolve, with optional OpenRouter-style filters (`q`, `context`, `min_price`, `max_price`, `sort`, modality filters).

Each provider row owns a credential pool. Provider kind, base URL, headers, settings, and capability declarations are shared by all members. A model profile points to the row and never names a pool member. AIGateway selects a healthy member by the configured `fill_first`, `round_robin`, `least_used`, or `random` strategy. The Console translates these strategy names for the selected UI language, while the API and stored values stay unchanged. A stateful thread stays on the same member when possible.

An attributed `429`, `5xx`, or transport failure cools down only the credential that made the request. AIGateway selects another member, rebuilds the provider request, and performs a bounded retry with exponential backoff and jitter. The Rust kernel performs one transport attempt at a time. AIGateway does not switch to another provider when the pool is empty.

`chatgpt_subscription` is an ordinary provider kind. Its OAuth credentials stay in the control plane, where token refresh runs under a row lock. The Agent Computer and external callers never receive those tokens.

Resolution can fail in two ways the caller should handle:

- `422 unknown_model_selector` — the selector is not bound for this subject.
- `422 model_binding_not_configured` — the capability and name are bound but the provider binding is incomplete.

A capability the bound provider does not offer surfaces as `422 unsupported_capability`. A provider the operator disabled surfaces as `422 provider_disabled`. These are configuration problems, not transient ones; retrying without changing the configuration will not help.

## Error shapes

Errors use an OpenAI-compatible envelope. The body is `{"error": {"code", "message"}}`, and the HTTP status matches the failure class. The classes worth planning for:

- `400` — the request body failed validation: missing `model`, missing `input`, an invalid `limit` or `top_n`, a stateful field over HTTP, a malformed compaction input. The `code` names the field.
- `401` — the bearer token is missing or unverifiable.
- `429` — the selected provider's credential pool is exhausted. The error code is `credential_pool_exhausted`; `retry_at` is present when AIGateway knows the earliest recovery time.
- `404` — a stored response, conversation, agent, or file was not found for this subject.
- `422` — the request is well-formed but the control plane cannot serve it: unknown selector, unconfigured binding, unsupported capability, disabled provider.
- `502` / `504` — the upstream provider failed. `502` covers transport and invalid-response failures (`upstream_transport_failed`, `invalid_upstream_response`, `ai_gateway_request_failed`); `504` is `upstream_timeout`. A client `4xx` from the provider is passed through at its own status.

When an upstream returns an `error.message`, AIGateway forwards that message; otherwise it reports the upstream HTTP status plainly.

## Image generation

`image_generation` is a public Responses tool with two execution paths. When the subject has an `image_generate` profile, AIGateway runs the tool with that separate provider and model. Without the profile, AIGateway passes the tool to the main provider only when its capability declares native image generation. If neither path exists, request preparation fails instead of simulating the tool.

Both paths use the same public stream events and generated-image persistence. Model usage and image usage stay attributed to the credential that produced each part.

## Web tools, files, and the other capabilities

The same subject and token drive the adjacent capabilities. `POST /web_search` takes a `query` (length-bounded) and returns provider-backed results; `POST /web_fetch` takes one to five public HTTPS URLs and returns page content. `POST /embeddings` accepts text, token arrays, or input blocks; `POST /rerank` reranks a non-empty document array and takes a positive integer `top_n`. Each request uses its capability-specific semantic selector, such as `web_search.default` or `web_fetch.default`; AIGateway resolves the current Agent profile when the call arrives.

Files are first-class: `POST /files` uploads, `GET /files` lists, `GET /files/:id` and `GET /files/:id/content` read metadata and bytes, and `DELETE /files/:id` removes one. All are scoped to the subject.

## What AIGateway is not

It is not a public, unauthenticated proxy. It is not a place to send provider credentials — those live in the control plane. And it is not a queue or a job runner; long-running agent work belongs to the Actor Runtime and Background Agent Jobs. AIGateway is the request/response boundary: one call in, one response or one stream out, with selectors resolved and credentials kept inside.

## Next steps

- For where AIGateway sits in the whole system, read the [architecture overview](../architecture/).
- For running the server that hosts these routes, read the [deployment section of Quick start](../quickstart/#deployment).
- For the first Provider and model-profile setup, read [Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent).
