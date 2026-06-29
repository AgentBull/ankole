# AIGateway

AIGateway is the control-plane owned AI boundary between Ankole workers and
external AI providers.

Workers do not receive external provider credentials. Provider credentials,
provider kinds, model bindings, and response normalization live in Elixir.
Workers receive only an agent-scoped AIGateway API key, keep it in memory, and
call AIGateway HTTP endpoints.

This boundary makes provider choice a control-plane concern. It also gives the
worker one local AI surface instead of a growing set of provider-specific
credential and SDK paths.

## Capabilities

AIGateway models are grouped by capability kind:

- `llm`;
- `embedding`;
- `rerank`.

The registry must leave room for future capability kinds such as `web_search`,
`image_generate`, and `asr`, but those are not part of the v1 runtime surface.

Capability kind is part of model resolution. An LLM alias and a rerank alias may
have the same short name only when the caller's endpoint makes the capability
unambiguous.

## Provider Implementations

Provider kinds translate the AIGateway public contract into one upstream
provider contract. They are Elixir-side modules called by the control plane.

Built-in LLM provider kinds:

- `openai`;
- `openai-compatible`;
- `openrouter`;
- `google_ai_studio_openai`;
- `claude`;
- `azure_openai`.

The `openai-compatible` provider supports both `responses` and
`chat_completions` endpoint modes. `openrouter` is an OpenAI-compatible provider
with OpenRouter defaults and app attribution headers. `google_ai_studio_openai`
uses Google AI Studio's OpenAI-compatible endpoint. `claude` adapts Anthropic's
Messages API into the AIGateway Responses event/body contract. `azure_openai`
supports Azure OpenAI's deployment-scoped Chat Completions path and `/openai/v1`
Responses-compatible path without treating Azure authentication as a plain
OpenAI bearer-token clone. It does not claim Azure AI Foundry or Azure-hosted
Anthropic support until those endpoint families get their own provider logic.

Built-in embedding and rerank provider kinds:

- `openrouter`;
- `jina`.

Plugins may contribute additional provider implementations through the `ai_gateway.provider`
contract. Plugins are trusted first-party Elixir code discovered at boot. They
do not own AIGateway persistence, authorization, model bindings, or credential
storage. The host AIGateway subsystem owns those contracts and passes only the
resolved request context to provider callbacks.

## Provider Configuration

An AIGateway provider row is an operator-configured provider instance. It owns:

- stable provider id;
- provider kind;
- optional base URL override;
- upstream HTTP protocol (`http1` or `http2`);
- encrypted provider credential;
- connection options;
- disabled state.

`provider_kind` is stored as a validated slug, not as a database enum or fixed
database whitelist. The control plane validates it against built-in provider
modules or active plugin `ai_gateway.provider` modules before accepting or
using a provider row. `credential_mode` follows the same rule: PostgreSQL only
enforces slug shape, while the selected provider implementation decides which
credential modes are valid.

Provider kind modules are the metadata source of truth. A module declares its
id, label, capabilities, endpoint modes, defaults, credential modes, connection
option keys, runtime provider option keys, and request/response conversion
logic. The registry only discovers modules and projects that metadata; it does
not maintain a second table of provider-source facts.

`http_protocol` is an explicit connection option, not an auto-detected fallback
chain. The control plane resolves every provider call to exactly one Finch
protocol list: `[:http1]` for HTTP/1 or `[:http2]` for HTTP/2. This avoids the
known mixed-protocol pool failure mode described in
https://github.com/sneako/finch/issues/265. `openai-compatible` defaults to
`http1` because arbitrary compatible endpoints commonly terminate HTTP/1 only.
All other built-in providers, including `openrouter`, default to `http2`; an
operator may override any provider row with `connection_options.http_protocol`.

Model bindings connect an agent-visible model selector to a provider instance
and upstream model id. LLM bindings preserve the existing `primary`, `light`,
and `heavy` variants. Embedding and rerank defaults are first-class profile
slots named `embedding` and `rerank`; they live in the same
`agents.options["ai_agent"]["models"]` map as the LLM profiles.

The worker may also send an explicit provider/model selector in the form
`provider_id/raw-model-id`. That selector bypasses an agent alias but still
requires an active configured provider and the caller's agent-scoped AIGateway
credential.

## HTTP API

Public REST APIs use the global `/api/v1` prefix. The AIGateway v1 HTTP surface
is:

- `GET /api/v1/ai-gateway/provider-kinds`;
- `GET /api/v1/ai-gateway/providers`;
- `PUT /api/v1/ai-gateway/providers/:provider_id`;
- `DELETE /api/v1/ai-gateway/providers/:provider_id`;
- `GET /api/v1/ai-gateway/models`;
- `POST /api/v1/ai-gateway/responses`;
- `POST /api/v1/ai-gateway/embeddings`;
- `POST /api/v1/ai-gateway/rerank`.

`/responses` follows the OpenResponses contract. It supports non-streaming HTTP,
HTTP SSE streaming, and raw WebSocket response creation in v1. Non-streaming
responses are normalized to the OpenResponses `ResponseResource` shape. HTTP
SSE responses use `text/event-stream`, include an `event:` field matching each
event body's `type`, stream output item/content lifecycle events when output is
present, and end with the literal `data: [DONE]` sentinel.

Upstream streaming is provider-owned. A provider may emit OpenAI Responses SSE,
OpenAI Chat Completions SSE, Anthropic Messages SSE, or another provider-native
stream. AIGateway normalizes those upstream chunks into OpenResponses event JSON
once, then exposes the same normalized event sequence over HTTP SSE and raw
WebSocket frames.

OpenResponses specification, reference, and compliance documents are the
compatibility source of truth. The current `open-responses/open-responses`
repository snapshot inspected for this design note is a CLI and compose wrapper,
not a complete portable compliance suite, so local tests should be authored from
the public contract instead of assuming direct upstream test migration. The
required local stateless HTTP set covers basic text, assistant phase history,
system prompt input, tool calling, image input, multi-turn input, and SSE event
schema. The WebSocket set covers raw `response.create` messages on the same
`/responses` path, sequential turns on one socket, and connection-local
`store: false` continuation.

Official OpenResponses WebSocket compliance is tracked as the v1-applicable
subset: `websocket-response`, `websocket-sequential-responses`,
`websocket-continuation`, `websocket-reconnect-store-false-recovery`,
`websocket-previous-response-not-found`, and
`websocket-failed-continuation-evicts-cache`. The official
`websocket-compact-new-chain` test depends on `/responses/compact` and is
intentionally outside v1.

`/models` follows the OpenRouter model list response style: top-level `data`
contains model entries with `id`, `canonical_slug`, `name`, `description`,
`architecture`, `pricing`, `context_length`, `top_provider`, and
`supported_parameters`. AIGateway lists configured selectors rather than
live-proxying every upstream provider catalog: agent credentials see the
authenticated agent's alias selectors and explicit `provider_id/raw-model`
selectors; admin credentials see configured explicit provider/model selectors.

The WebSocket transport is a raw JSON WebSocket protocol, not Phoenix Channels.
Workers connect to `ws(s)://<host>/api/v1/ai-gateway/responses` with the same
agent-scoped bearer credential used for HTTP. Client messages must be JSON
objects with `type: "response.create"` plus the normal Responses create body.
HTTP-only fields `stream`, `stream_options`, and `background` are rejected in
WebSocket messages. Server messages are OpenResponses streaming event JSON
frames; the terminal `response.completed`, `response.failed`, `response.incomplete`,
or `error` event completes the current WebSocket turn. WebSocket frames do not
use the HTTP SSE `[DONE]` sentinel.

`/embeddings` follows the OpenRouter embedding contract. Requests use `model`
and `input`, with optional OpenRouter/OpenAI fields such as `dimensions` and
`encoding_format`. `input` is passed through as the provider-facing embedding
payload, including text strings, batches, token arrays, and OpenRouter
multimodal input blocks. Before provider dispatch, AIGateway resolves the public
model selector and replaces it with the upstream model id. Responses keep the
OpenRouter/OpenAI embedding shape: top-level `model`, `data`, and `usage`, where
each data item contains at least `embedding` and an `index` if the provider did
not include one.

`/rerank` follows the OpenRouter rerank contract. Requests use `model`, `query`,
`documents`, and optional `top_n`. `documents` may contain strings or structured
document objects such as `{ "text": "..." }`, `{ "image": "..." }`, or both.
Responses keep the OpenRouter rerank shape: top-level `id`, `model`, `results`,
`usage`, and provider-supplied optional fields such as `provider`. Each result
has `document`, `index`, and `relevance_score`; provider variants such as a
top-level result `text` or `score` are normalized into that shape.

AIGateway should not add Ankole-only top-level fields to these public bodies.
Gateway trace data belongs in logs, telemetry, or durable turn metadata.

## Protocol Edge Case Tests

The local test suite should pin AIGateway behavior around provider and stream
irregularities. These are AIGateway contract tests, not copies of any single
upstream gateway implementation.

Responses HTTP tests must cover non-streaming JSON response shape, no SSE
headers when `stream` is absent or false, complete stateless input requirements,
and the v1 rule that HTTP `previous_response_id` is accepted, ignored, and
stripped before provider dispatch.

Responses SSE tests must cover `text/event-stream`, `event` matching the JSON
body `type`, JSON `data`, the literal `data: [DONE]` sentinel, LF and CRLF event
delimiters, optional space after SSE field colons, multi-line `data` fields
joined with `\n`, UTF-8 characters split across byte chunks, comment or
keepalive lines, and streams that close before a terminal event.

Responses event tests must cover output item lifecycle events, content part
lifecycle events, output text deltas and completion, refusal deltas and
completion, reasoning summary events, and terminal `response.completed`,
`response.failed`, and `response.incomplete` outcomes. A stream that returns
HTTP 200 but later emits an upstream error, invalid JSON, or no terminal event
is not a successful response.

Provider dispatch tests must preserve the requested selector, resolved provider
id, upstream model id, and usage or billing model as separate facts. They must
also cover explicit wire API selection, including OpenAI-compatible `responses`
versus `chat_completions`, without treating provider id or base URL as the wire
protocol.

Capability tests must fail closed for unknown aliases, disabled providers,
unsupported capability kinds, and unsupported request features such as
streaming, tools, text format or JSON schema, reasoning, image input,
embeddings, and rerank. Local selector and configuration failures do not
trigger provider failover.

Provider error tests must classify upstream timeout, first-byte timeout, idle
timeout, 429, 5xx, 400, and 422 responses. Retry or failover policy is provider
and configuration specific, but client/configuration errors must not be retried
as provider alternatives.

Provider stream-shape tests must cover upstream non-stream requests that return
SSE or a mislabeled content type. A non-streaming AIGateway response remains
JSON: the provider implementation either aggregates the upstream stream into a
JSON response or returns a structured protocol error.

Observability tests must assert that logs, telemetry, and durable metadata can
record provider id, profile, selector, upstream model, latency, usage, finish
state, and error class without recording provider credentials, bearer tokens, or
raw secret-bearing request headers.

Future-state tests should cover persisted response storage, cross-connection
`previous_response_id`, `/responses/compact`, WebSocket compact-new-chain
behavior, and durable `store: true` recovery. Those tests are outside the
stateless v1 pass.

## v1 Response State

The first AIGateway release has no persisted response state.

The worker must send complete usable context on each `/responses` request.
AIGateway does not keep a local response object store and does not reconstruct
conversation state from an earlier response id.

For HTTP, `previous_response_id` is accepted for wire compatibility, but v1
ignores it and strips it before provider dispatch. It does not load prior state,
alter model resolution, or change provider behavior.

For WebSocket, v1 supports only connection-local `store: false` continuation.
If a response was created with `store: false`, the WebSocket process may keep a
short-lived in-memory entry for that response id for the lifetime of the same
socket. A later `response.create` on the same socket may reference that response
with `previous_response_id`; AIGateway expands the new request into a complete
stateless provider request before dispatch. The cache is not durable and is not
shared across sockets or worker restarts.

If WebSocket `previous_response_id` cannot be found in the current socket cache,
AIGateway returns an OpenResponses WebSocket error event with code
`previous_response_not_found`. If a continuation fails validation, the referenced
cached response is evicted so callers cannot keep extending a stale chain.

The following are not part of v1:

- `/responses/compact`;
- persisted response state;
- cross-connection or cross-restart `previous_response_id` handling.

The next stateful phase should add response storage, meaningful
cross-connection `previous_response_id` support, and `/responses/compact`.

## Authentication

In v1, `/api/v1/ai-gateway/*` accepts either:

- agent-scoped AIGateway bearer credentials; or
- console access JWTs whose `sub` is still an active human member of the built-in
  `admin` group.

The agent credential is a JWT signed by the control plane:

- `aud` is `ankole.ai_gateway`;
- `scope` is `ai_gateway`;
- `sub` is the agent uid;
- default expiry is 30 days.

The auth plug keeps the authenticated subject typed. Admin access does not
overload agent identity: agent model aliases resolve only for an agent subject,
while admin callers should use explicit `provider_id/raw-model` selectors unless
a later ACL design adds an explicit agent-on-behalf-of contract.

## RuntimeFabric RPC

Workers obtain an AIGateway API key through RuntimeFabric:

```text
ai_gateway.api_key_for.create_or_find_by_agent
```

The request includes a request id, the active turn ref, agent uid, and session
id. The control plane authorizes the worker route against the turn before
issuing a key for that agent.

The response includes:

- `api_key`;
- `token_type` as `Bearer`;
- `expires_at`;
- `agent_uid`;
- AIGateway base URL.

The base URL is worker-facing, not merely `Endpoint.url/0`. Local Docker worker
e2e runs the worker inside a container, where host `localhost` would point back
to the container. The control plane may therefore return an explicitly
configured URL such as `http://host.docker.internal:<port>/api/v1/ai-gateway`
without changing the public Phoenix endpoint URL.

Workers keep the key only in memory. In the current actor-agnostic worker pool,
process startup has no agent identity, so the executable v1 rule is: fetch the
agent's AIGateway key immediately at turn start before any provider HTTP request.
Before each AIGateway HTTP request, the worker checks the expiry. If the key is
absent or expired, the worker calls the RPC again. If Ankole later runs
actor-dedicated workers, those workers should also fetch the key at process
startup because agent identity will be known then.

No refresh token exists for this surface.

## Ownership

Elixir owns provider credentials, provider configuration, provider execution,
model binding resolution, AIGateway authentication, and normalized HTTP
responses.

RuntimeFabric owns the worker-to-control-plane API-key request path.

Bun workers own prompt construction, local tools, MCP servers, and the in-memory
AIGateway client. They do not own provider credentials or provider-specific
runtime state.
