# AIGateway

AIGateway is the control-plane owned AI boundary between Ankole workers and
external AI providers.

Workers do not receive external provider credentials. Provider credentials,
provider kinds, model bindings, endpoint selection, and prepared request
construction live in Elixir. Streaming response normalization runs in the Rust
kernel data plane once Elixir has built the upstream request. Workers receive
only an agent-scoped AIGateway API key, keep it in memory, and call AIGateway
HTTP endpoints.

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
OpenAI `responses` mode may opt into upstream WebSocket transport through
provider connection options. In that case Elixir prepares only the endpoint,
headers, transport preference, and public request context. Rust builds the
top-level `response.create` WebSocket payload, removes HTTP SSE-only request
fields such as `stream`, `stream_options`, and `background`, sends the payload,
and normalizes the returned Responses events.

Built-in embedding and rerank provider kinds:

- `openrouter`;
- `jina`.

Plugins may contribute additional provider implementations through the `ai_gateway.provider`
contract. Plugins are trusted first-party Elixir code discovered at boot. They
do not own AIGateway persistence, authorization, model bindings, or credential
storage. The host AIGateway subsystem owns those contracts and passes only the
resolved request context to provider prepare functions.

## Provider Configuration

An AIGateway provider row is an operator-configured provider instance. It owns:

- stable provider id;
- provider kind;
- optional base URL override;
- encrypted provider credential;
- connection options;
- disabled state.

`provider_kind` is stored as a validated slug, not as a database enum or fixed
database whitelist. The control plane validates it against built-in provider
modules or active plugin `ai_gateway.provider` modules before accepting or
using a provider row. Provider-specific options and encrypted credential values
are projected into the provider prepare context as settings; there is no global
credential-mode registry.

Provider kind modules are the metadata source of truth. A module uses
`ProviderDSL` to declare its id, localized label, settings, default base URL,
default transport preferences, and user-facing capabilities. Each capability
declares an `upstream` shape, a Rust `api_resolver`, and the provider-owned
Elixir prepare function that builds the `UniversalAIRequest`. The registry only
discovers compiled `ProviderDefinition` values and dispatches to those prepare
functions; it does not maintain a second table of provider-source facts.

Operator live checks follow the provider-owned request boundary.
`ProviderConfigs` may decrypt the configured secret and build the provider
context, but it must not know provider-specific probe paths, auth headers, API
versions, or attribution headers. A provider module may expose
`check_connection/1`; if it does, that function receives a context with
`settings` and builds any raw `UniversalAIRequest` call itself.

Model metadata is a separate catalog concern. Provider modules may optionally
expose `models_metadata_source/1`, which returns a provider-owned source
descriptor rather than a generic live-check hook. OpenRouter implements this
callback and points at `models?output_modalities=all`, including its attribution
and auth headers in the descriptor. Providers without the callback naturally use
the packaged `llm_db` snapshot by convention: AIGateway checks the normalized
provider kind first, then the normalized configured provider id, against
already-loaded `LLMDB.providers()`. It never creates atoms from operator input.
Built-in provider naming differences such as `claude` to `anthropic`,
`azure_openai` to `azure`, and `google_ai_studio_openai` to `google` are treated
as explicit equivalence aliases for this metadata lookup. If no metadata source
or model record exists, the catalog returns neutral text metadata or an empty
provider list instead of failing the public `/models` request.

`connection_options.transport` is optional. When omitted, Elixir displays and
normalizes the same default preference Rust uses at the NIF boundary:
`http_versions: [:h3, :h2, :h1]` and
`compression: [:zstd, :br, :gzip]`, with no proxy. Operators may override
`http_versions`, `compression`, or `proxy`; Elixir validates the preference
values before saving a provider row, and Rust performs the actual transport
attempts for the prepared request.

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

Streaming response normalization is native-kernel owned. Elixir provider modules
still choose the provider, apply credentials, select endpoint/transport, and
prepare headers. The Rust `UniversalAIClient` then owns model request body
encoding and the live data plane: upstream HTTP SSE, AWS eventstream, or
upstream WebSocket reads; provider response resolution; OpenResponses
event/resource normalization; downstream-ready SSE bytes or WebSocket text
payloads; demand credit; cancellation; and timeout handling.

The HTTP SSE route waits for native `:ready` before sending `200` and
`text/event-stream` headers. A pre-ready upstream failure therefore returns an
ordinary HTTP error response. After ready, native midstream failures are encoded
as OpenResponses `error` plus `response.failed` chunks, then the downstream
terminal signal is sent. There is no Elixir streaming decoder fallback in the
AIGateway runtime; provider modules do not implement response normalization or
stream-message decoding.

HTTP transport uses reqwest clients with gzip, Brotli, and zstd decompression
enabled according to the prepared spec. HTTP/2 versus HTTP/1.1 is negotiated by
TLS ALPN unless the spec asks for HTTP/1.1 only. HTTP/3 support is best-effort:
unknown origins first use TLS ALPN for HTTP/2/HTTP/1.1 and record
same-authority `Alt-Svc: h3=...` advertisements. Later same-origin requests
prefer reqwest HTTP/3 prior knowledge and mark ready metadata as `alt_svc_h3`.
Explicit h3-only specs may also use prior knowledge directly. The implementation
does not claim full browser-grade Alt-Svc behavior for alternate authorities
because that requires connection-authority, SNI, cache, and validation semantics
outside reqwest's high-level client contract.

OpenResponses specification, reference, and compliance documents are the
compatibility source of truth. The official `openresponses/openresponses`
repository includes a portable compliance CLI:
`bun run test:compliance --base-url <url> --api-key <key> --model <selector>`.
Local tests should mirror that suite instead of inventing a separate schema.
The required local stateless HTTP set covers basic text, assistant phase
history, system prompt input, tool calling, image input, multi-turn input, and
SSE event schema. The WebSocket set covers raw `response.create` messages on the
same `/responses` path and sequential independent turns on one socket.

The official OpenResponses compliance cases that require provider-side response
state are outside the stateless v1 pass: `previous_response_id`-driven recovery,
failure bookkeeping for stateful recovery, and `/responses/compact`.

`/models` follows the OpenRouter model list response style: top-level `data`
contains model entries with `id`, `canonical_slug`, `name`, `description`,
`architecture`, `pricing`, `context_length`, `top_provider`, and
`supported_parameters`. AIGateway uses Ankole selectors for ids. Explicit model
entries are `provider_id/raw-model`, so two configured provider rows that expose
the same upstream model remain separate entries, for example
`openrouter/openai/gpt-4` and `openrouter2/openai/gpt-4`. The endpoint lists all
active configured providers using their metadata source; it is not limited to
models currently referenced by `ModelProfiles`.

Agent credentials also receive that agent's profile aliases, such as `primary`,
`light`, `heavy`, `embedding.default`, and `rerank.default`. Alias entries keep
the alias as `id` and point `canonical_slug` at the resolved explicit selector,
for example `openrouter/openai/gpt-4`. Alias metadata is copied from the
resolved explicit provider/model entry when available, or from the neutral
fallback metadata otherwise. Admin credentials do not receive alias entries
because alias names are agent-local and collide across agents. OpenRouter-style
filters for modalities, supported parameters, context, price, query, and sort
run after explicit entries and alias entries have been assembled.

The WebSocket transport is a raw JSON WebSocket protocol, not Phoenix Channels.
Workers connect to `ws(s)://<host>/api/v1/ai-gateway/responses` with the same
agent-scoped bearer credential used for HTTP. Client messages must be JSON
objects with `type: "response.create"` plus the normal Responses create body.
HTTP-only fields `stream`, `stream_options`, and `background` are rejected in
WebSocket messages. `previous_response_id` is stripped before provider dispatch
for the same stateless reason as HTTP. Server messages are OpenResponses
streaming event JSON frames; the terminal `response.completed`,
`response.failed`, `response.incomplete`, or `error` event completes the current
WebSocket turn. WebSocket frames do not use the HTTP SSE `[DONE]` sentinel.

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

Future-state tests should cover persisted response storage, meaningful
`previous_response_id` behavior, `/responses/compact`, and durable `store: true`
recovery. Those tests are outside the stateless v1 pass.

## v1 Response State

The first AIGateway release has no persisted response state.

The worker must send complete usable context on each `/responses` request.
AIGateway does not keep a local response object store and does not reconstruct
conversation state from an earlier response id.

For HTTP, `previous_response_id` is accepted for wire compatibility, but v1
ignores it and strips it before provider dispatch. It does not load prior state,
alter model resolution, or change provider behavior.

For WebSocket, v1 follows the same stateless rule. A WebSocket
`response.create` with `previous_response_id` is treated as a complete new
stateless request after that field is stripped.

The following are not part of v1:

- `/responses/compact`;
- persisted response state;
- response-state handling across socket turns, connections, or restarts.

The next stateful phase should add response storage, meaningful
`previous_response_id` support, and `/responses/compact`.

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

The request includes a request id and the agent uid. RuntimeFabric worker traffic
is already inside Ankole's trusted worker boundary, so this method does not add a
second AuthN/AuthZ check against the current turn route. The explicit `agent_uid`
is the on-behalf-of subject for the issued key.

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
