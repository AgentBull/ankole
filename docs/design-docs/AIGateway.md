# AIGateway

AIGateway is the control-plane owned AI boundary of Ankole. It sits between
callers and external AI providers, and it owns two things:

- the provider boundary: provider credentials, provider kinds, model bindings,
  endpoint selection, and prepared request construction live in Elixir. Workers
  never receive external provider credentials.
- the stateful Responses log: AIGateway stores every model call as a row in
  PostgreSQL and owns Response history, continuation, compaction, and Response
  terminal persistence. It does not own an agent loop or an Actor turn.

Workers receive only an agent-scoped AIGateway API key, keep it in memory, and
call AIGateway over HTTP and WebSocket. Streaming response normalization runs
in the Rust kernel data plane once Elixir has built the upstream request.

AIGateway is actor-agnostic. Its durable owner is a Principal `subject_uid`;
it does not import or query Actor, ActorRuntime, SignalsGateway, delivery, or
outbox state. A completed Response means only that one model request completed.
The Agent Computer owns loop termination, and SignalsGateway owns Actor turn
completion and provider-visible reply projection.

This boundary makes provider choice a control-plane concern. It gives the
worker one local AI surface instead of a growing set of provider-specific
credential and SDK paths. It also keeps durable conversation state out of the
worker: a worker process can die at any point without losing model history.

If this is your first Ankole document, read `docs/README.md` first. It shows
where AIGateway sits in the whole system and how one chat message flows
through it.

## Capabilities

AIGateway models are grouped by capability kind:

- `llm`;
- `embedding`;
- `rerank`;
- `web_search`;
- `web_fetch`;
- `image_generate`.

The registry must leave room for future capability kinds such as `asr`, but
providers do not declare capabilities until they have a real request path.
`image_generate` is currently declared only by OpenRouter and is consumed by
the Responses `image_generation` hosted tool; it is not a worker function tool.

Capability kind is part of model resolution. An LLM alias and a rerank alias may
have the same short name only when the caller's endpoint makes the capability
unambiguous.

## Provider Implementations

Provider kinds translate the AIGateway public contract into one upstream
provider contract. They are Elixir-side modules called by the control plane.

Built-in LLM provider kinds:

- `openai`;
- `openai_compatible`;
- `openrouter`;
- `google_ai_studio_openai`;
- `claude`;
- `azure_openai`.

The `openai_compatible` provider supports both `responses` and
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
top-level `response.create` WebSocket payload, preserves OpenAI
`ResponseCreateWsRequest` fields such as `stream`, `stream_options`,
`include`, `generate`, and `client_metadata`, removes fields that AIGateway
owns internally such as `service_tier`, and normalizes the returned Responses
events.

Built-in embedding and rerank provider kinds:

- `openrouter`;
- `jina`.

Built-in image-generation provider kinds:

- `openrouter`, through its stable `/images` API and separate image model and
  endpoint catalogs.

Built-in web search and extraction provider kinds:

- `parallel`, for provider-backed search and extraction;
- `bright_data_serp`, for Bright Data SERP search;
- `agentbull_cloud`, for AgentBull cloud search;
- `jina_reader`, for Jina Reader extraction.

`jina_reader` is intentionally separate from `jina`. The existing `jina`
provider continues to own Jina embedding and rerank behavior; reader-style web
extraction uses its own provider kind and resolver so request and response
contracts do not leak across capabilities.

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

`provider_kind` is stored as a validated snake_case slug, not as a database enum
or fixed database whitelist. The control plane validates it against built-in
provider modules or active plugin `ai_gateway.provider` modules before accepting
or using a provider row. Provider-specific options and encrypted credential
values are projected into the provider prepare context as settings; there is no
global credential-mode registry.

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
`prepare_connection_check/1`; if it does, that function receives a context with
`settings` and returns a `ProviderConnectionCheck` prepared with the provider's
path and headers. `ProviderConfigs` executes that prepared check through the
shared raw `UniversalAIRequest` path and owns the common upstream error shape.

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
as explicit equivalence aliases for this metadata lookup. Plugin provider ids
should match the upstream `llm_db` provider id when one exists; if the product
name needs a clearer Ankole id, add an explicit metadata alias such as
`xiaomi_mimo` to `xiaomi`. If no metadata source or model record exists, the
catalog returns neutral text metadata or an empty provider list instead of
failing the public `/models` request.

`connection_options.transport` is optional. When omitted, Elixir displays and
normalizes the same default preference Rust uses at the NIF boundary:
`http_versions: [:h3, :h2, :h1]` and
`compression: [:zstd, :br, :gzip]`, with no proxy. Operators may override
`http_versions`, `compression`, or `proxy`; Elixir validates the preference
values before saving a provider row, and Rust performs the actual transport
attempts for the prepared request.

Model bindings connect an agent-visible model selector to a provider instance
and upstream model id. LLM bindings preserve the existing `primary`, `light`,
and `heavy` variants. Embedding, rerank, web search, and web fetch defaults
are first-class profile slots named `embedding`, `rerank`, `web_search`, and
`web_fetch`. Image generation has an optional `image_generate` profile. These
profiles live in the same `agents.options["ai_agent"]["models"]` map as the
LLM profiles. Their public selectors are `embedding.default`,
`rerank.default`, `web_search.default`, `web_fetch.default`, and
`image_generate.default`.

The binding map is owned by `Ankole.AIAgent.ModelProfiles`, because profiles
configure worker behavior rather than the gateway itself. A `coding` profile
may instead select a named Codex subscription account. That account-shaped
profile is resolved when CodexRunner prepares an ordinary BackgroundAgentJob;
it is not a Plugin option and does not become an AIGateway model alias.
Provider/model-shaped coding profiles continue to resolve through AIGateway
normally.

The worker may also send an explicit provider/model selector in the form
`provider_id/raw-model-id`. That selector bypasses an agent alias but still
requires an active configured provider and the caller's agent-scoped AIGateway
credential.

## Usage Surfaces

AIGateway has two usage surfaces. They share the same `/responses` endpoint
family but have different state rules.

**The stateless surface** serves enterprise/internal callers that are not
agent-computer workers. It plays the role of a small private OpenRouter: pick a
model, send a request, get a response. Rules:

- HTTP with optional SSE streaming is the primary path. WebSocket is also
  allowed, with the same stateless meaning.
- It never writes the `ai_gateway_messages` or `ai_gateway_conversations`
  tables. Nothing is stored.
- Stateless HTTP rejects `store=true`, `previous_response_id`, and
  `conversation` with `400`. A stateless WebSocket request may use
  `previous_response_id` only when it names a response already completed on the
  same socket; AIGateway expands that connection-local cache into input and
  still writes no durable state. Unknown ids are rejected.
- A stateless response still needs a schema-level id. It uses a transport-only
  id with the prefix `tmp_resp_`, for example
  `tmp_resp_0198f00d-31aa-7cde-9f00-3c9b52ab01aa`. A `tmp_resp_*` id can never
  be retrieved, chained, or stored. `GET /responses/:id` on it returns `404`.

**The stateful Responses surface** serves both the Bun worker and other
Responses-compatible internal clients. The persistence contract is the same
for every Principal subject and has no Actor-specific branch. Rules:

- The transport is WebSocket `response.create` messages, plus an explicit
  `store=true` field, plus an authenticated Principal subject.
- A request may pass `conversation` to attach to an existing
  `ai_gateway_conversations` row, or pass `previous_response_id` to continue
  from a stored response. Sending both is a `400`.
- If `store=true` names neither `conversation` nor `previous_response_id`,
  AIGateway creates a new conversation internally and marks it with
  `metadata.managed_by_stateful_responses_api = true`.
- Request `metadata` is opaque caller data. AIGateway persists, returns, and
  publishes the complete map without recognizing, validating, or indexing
  individual keys. An Agent Computer may put an `actor_event_id` string there,
  but only SignalsGateway interprets it.
- The worker opens one WebSocket connection per actor-event run, reuses it for
  tool-loop continuation `response.create` messages, and runs at most one
  in-flight response on that connection at a time.
- `background=true` does not enable an Ankole background response mode.
  AIGateway exposes only Response-scoped fail and suffix-removal primitives;
  Actor stop, retry, and retraction policy chooses targets in SignalsGateway.

Stateful HTTP/SSE is intentionally unsupported in the current product. External
OpenAI-style HTTP clients use the stateless surface; a client that needs durable
continuation must use the WebSocket contract above.

The gate is intentionally explicit. AIGateway never guesses from headers or
`User-Agent` whether a request should be stateful. Only
`WebSocket + store=true + valid token` opens the stateful path.

Rejections are typed. A bad request shape (stateful fields on HTTP, a
continuation without `store=true`, `conversation` and `previous_response_id`
both present) is a `400`. A missing or invalid token is a
standard Bearer-auth failure: `401`. An authenticated subject that is explicitly
refused is a `403`. A `conversation` or `previous_response_id` that does not
resolve inside the authenticated subject's scope is a `400` (unknown conversation /
invalid anchor).

## HTTP API

Public REST APIs use the global `/api/v1` prefix. The AIGateway v1 HTTP surface
is:

- `GET /api/v1/ai-gateway/provider-kinds`;
- `GET /api/v1/ai-gateway/providers`;
- `PUT /api/v1/ai-gateway/providers/:provider_id`;
- `DELETE /api/v1/ai-gateway/providers/:provider_id`;
- `GET /api/v1/ai-gateway/models`;
- `POST /api/v1/ai-gateway/files`;
- `GET /api/v1/ai-gateway/files`;
- `GET /api/v1/ai-gateway/files/:file_id`;
- `GET /api/v1/ai-gateway/files/:file_id/content`;
- `DELETE /api/v1/ai-gateway/files/:file_id`;
- `POST /api/v1/ai-gateway/responses`;
- `GET /api/v1/ai-gateway/responses/:response_id`;
- `POST /api/v1/ai-gateway/responses/compact`;
- `POST /api/v1/ai-gateway/embeddings`;
- `POST /api/v1/ai-gateway/rerank`;
- `GET /api/v1/ai-gateway/web_tools`;
- `POST /api/v1/ai-gateway/web_search`;
- `POST /api/v1/ai-gateway/web_fetch`.

`POST /responses` over HTTP follows the OpenResponses contract and is always
stateless. It supports non-streaming HTTP and HTTP SSE streaming. It rejects
`store=true`, `previous_response_id`, and `conversation` with `400`.
Non-streaming responses are normalized to the OpenResponses `ResponseResource`
shape. HTTP SSE responses use `text/event-stream`, include an `event:` field
matching each event body's `type`, stream output item/content lifecycle events
when output is present, and end with the literal `data: [DONE]` sentinel.

Provider-facing streaming normalization is native-kernel owned. Elixir provider
modules still choose the provider, apply credentials, select endpoint/transport,
and prepare headers. The Rust `UniversalAIClient` owns model request body
encoding and the live data plane: upstream HTTP SSE, AWS eventstream, or
upstream WebSocket reads; provider response resolution; OpenResponses
event/resource normalization; demand credit; cancellation; and timeout
handling.

Each normalized stream then has one control-plane owner,
`AIGateway.ResponseStream`. It is the only process that receives Kernel events
and owns generated-image persistence, public versus durable projections,
stateful terminal commits, tool-call limits, cancellation, and hosted-tool
telemetry. Only guarded, transport-neutral event maps leave that owner. The HTTP
SSE and WebSocket modules request credit and encode those maps; they do not
reconstruct AIGateway semantics.

The HTTP SSE route waits for native `:ready` before sending `200` and
`text/event-stream` headers. A pre-ready upstream failure therefore returns an
ordinary HTTP error response. After ready, midstream failures become a guarded
OpenResponses failure before the downstream terminal signal is sent. There is
no provider-specific streaming decoder fallback in the AIGateway runtime;
provider modules do not implement response normalization or stream-message
decoding.

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
history, system prompt input, tool calling, image input, multi-turn input, SSE
event schema, and standalone `/responses/compact`. Compliance cases that need
provider-side response state, such as `previous_response_id` recovery, run
against the WebSocket surface.

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
The accepted body is intentionally compatible with Codex/OpenAI
`ResponseCreateWsRequest`, including fields such as `stream`,
`stream_options`, `include`, `service_tier`, `prompt_cache_key`, `text`,
`generate`, and `client_metadata`. AIGateway consumes or strips internal policy
fields before provider dispatch when they are not upstream request semantics.

A WebSocket `response.create` without `store=true` is a stateless request. With
`store=true` and a valid Principal credential it enters the stateful path described in
the sections below. For stateful runs, every server frame — including
non-terminal frames such as `response.created` — carries
`response.id = "resp_" <> row id`. A worker reading the id from any frame, the
way the OpenAI SDK does, can never see an upstream provider id.

Server messages are OpenResponses streaming event JSON frames; the terminal
`response.completed`, `response.failed`, `response.incomplete`, or `error`
event completes the current WebSocket turn. WebSocket frames do not use the
HTTP SSE `[DONE]` sentinel.

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

`GET /web_tools` exposes the provider-backed tool availability for the current
agent token. The response tells the worker whether `web_search` and
`web_fetch` are configured, and which profile selector to send back. It does
not advertise the worker-local rendered-page fallback; Agent Computer may add
that fallback for `web_fetch` independently when building its tool list.

`/web_search` accepts `model`, `query`, and optional `limit`. It resolves the
model through the `web_search` capability and dispatches to the configured
provider. Provider responses are normalized to a shared body with `success`,
`query`, and `results`. Each result may include `title`, `url`, `snippet`,
`published_at`, `source`, `sources`, `score`, and provider metadata when the
upstream supplies it.

`/web_fetch` accepts `model` and one to five HTTPS `urls`. It resolves the
model through the `web_fetch` capability and dispatches only to
provider-backed extraction. Literal cloud metadata-host URLs are always
rejected before provider dispatch; literal localhost, private, link-local,
loopback, and CGNAT URLs are additionally rejected when the
`security.ssrf_filter` AppConfigure key is enabled (default off;
see the WebTools design doc). Responses are
normalized to `success` plus `results`, where each result includes at least the
requested `url` and may include `title`, `content`, `text`, `markdown`,
`html`, `links`, `images`, `metadata`, or `error` depending on the provider
contract.

AIGateway should not add Ankole-only top-level fields to these public bodies.
Gateway trace data belongs in logs, telemetry, or durable message metadata.

### Image generation hosted tool

Responses accepts the OpenAI `image_generation` hosted-tool request and event
contract. Worker code uses the official OpenAI SDK's `files` and `responses`
resources directly; it does not register an `image_generate` function tool or
translate an Ankole-specific result.

The public tool is gateway-owned. Elixir validates the complete public tool,
resolves the `image_generate` profile and a definitive OpenRouter image
endpoint, and resolves subject-scoped file and generated-image references.
The Rust `HostedResponsesExecutor` replaces the public tool only in the
provider-facing main-model request with a random strict private function. It
intercepts that function, calls OpenRouter's stable `/images` API, emits the
public `image_generation_call` lifecycle, adds only a compact private tool
result to canonical main-model history, and continues the same main model.
Private function names, ids, arguments, provider tags, costs, and intermediate
main-model terminal events never enter the public Response stream.

The image model is independent of `Response.model`. Omitting
`tools[].model` uses `image_generate.default`; an explicit model changes only
the model on that same OpenRouter connection. Endpoint selection pins one
catalog-declared `provider_tag`, disables fallback, requires declared
parameters, and rejects unsupported values instead of silently dropping them.
Only the image request uses the image provider; the main model remains the
resolved LLM profile.

The Files subset accepts `purpose=vision` multipart uploads and implements
create, list, retrieve, content, and delete with OpenAI object and pagination
shapes. `file_*` and `ig_*` references are scoped to the authenticated
Principal. External HTTP(S) image URLs are passed through without a gateway
download; local ids and data URLs are validated and expanded to provider-ready
data URLs before dispatch.

`ImageStreamPersistence` owns this invariant for both non-streaming JSON and the
per-response stream owner: generated bytes are persisted before a completed
image output item or terminal event is released to HTTP, SSE, or WebSocket
clients. The public projection retains the base64 result, while stored message
JSON contains the item id and `result: null`; retrieval hydrates the base64 from
the artifact row. Stateful images are linked to the owning message, stateless
images expire after 30 days, and uploaded files expire only when the caller
supplies `expires_after`.

## Protocol Positioning

Ankole AIGateway is a superset of OpenResponses. It also borrows a small set of
concepts from the OpenAI Responses API. If you have used the OpenAI SDK, most
field names here already mean what you expect. This section lists what matches
and what is different on purpose.

Taken from OpenResponses:

- object shapes, stream events, and the `ResponseItem[]` item model;
- the `/responses/compact` standalone request and `response.compaction`
  resource shape.

Taken from the OpenAI Responses API, with Ankole-scoped semantics:

- `previous_response_id`: continue from an earlier stored response;
- `conversation`: name the conversation a new session belongs to;
- `store`: opt into stored state;
- `GET /responses/:id`: retrieve one stored response.

These four form the internal stateful Responses service for any authenticated
Principal subject. They are not a public multi-tenant conversation service.

Deliberately not implemented:

- the OpenAI Conversations API public object surface;
- `DELETE /responses/:id` — IM message deletion has its own mapping (see
  `docs/design-docs/SignalsGateway.md`), and nothing else needs response
  deletion;
- `POST /responses/:id/cancel` — Ankole has no public background Response mode;
  internal callers may mark a known generating Response failed through the
  narrow subject/Response API;

Field rules:

- `instructions` always comes from the current request. It is never inherited
  from `previous_response_id` and never stored into the history projection.
- `prompt_cache_key` is accepted and may be forwarded when the provider
  resolver supports it, but AIGateway does not use it as a local cache key. It
  does not locate history, and does not affect compaction, retrieval, or
  authorization.
- `service_tier` is accepted but has no Ankole value domain. It is stripped
  before the provider call so upstream providers do not reject it. It does not
  affect scheduling, routing, billing, or priority. Responses may echo it or
  omit it.
- `max_tool_calls` is an optional per-Response limit for provider-executed
  built-in tools. Omitted and `null` mean no numeric default. Native OpenAI
  Responses resolvers pass it through. Other resolvers count only built-in
  calls and stop best-effort at a safe event boundary; already-started parallel
  calls may overshoot. Function/custom tool calls and earlier Responses never
  count. A fallback late stop yields `response.incomplete` and records the
  limit, observed count, and overshoot only in provider metadata.
- WebSocket `store=false` `previous_response_id` is connection-local
  compatibility only. It can refer to a response completed earlier on the same
  WebSocket and is expanded into input items before provider dispatch. It never
  creates `ai_gateway_messages` rows and cannot be retrieved later.

## Stateful Message Log

Three PostgreSQL tables carry all stateful Responses state. AIGateway is the only
writer.

`ai_gateway_messages` is the message log. One row records one stateful
Responses run, or one stateful compaction. A "run row" is the row written for
one `response.create` call.

| Column | Meaning |
| --- | --- |
| `id` (uuid) | The row id. The API id `resp_#{id}` is this uuid with a prefix. |
| `subject_uid` | Owning Principal subject. Every query filters on it. |
| `conversation_id` | The `ai_gateway_conversations` row this run belongs to. |
| `type` | `message` (a Responses run) or `checkpoint` (a compaction continuation anchor). |
| `role` | Display hint for transcript projections only. Not authoritative. |
| `status` | `generating`, `complete`, `error`, or `retracted`. |
| `previous_message_id` | Self-reference to the anchor row. Rendered as `previous_response_id` at the API edge. |
| `content` (jsonb) | The OpenResponses `ResponseItem[]` array for message rows, or exactly one `compaction_artifact` ref for checkpoint rows. |
| `metadata` (jsonb) | Opaque caller metadata plus generic model/provider, usage, request, and error facts. |

Compaction bodies live in `ai_gateway_compaction_artifacts`, not in
`ai_gateway_messages`:

| Column | Meaning |
| --- | --- |
| `id` (uuid) | The artifact id. When a checkpoint is written, the checkpoint row uses the same raw UUID. |
| `subject_uid` | Owning Principal subject. Every lookup filters on it. |
| `conversation_id` | Nullable. Filled for stateful/checkpoint compaction; null for standalone artifacts. |
| `content` (jsonb) | Versioned artifact body: summary, canonical `response.compaction.output`, retained tail, and usage. |

Uploaded vision files and generated images live in `ai_gateway_artifacts`, not
in `ai_gateway_messages`:

| Column | Meaning |
| --- | --- |
| `id` (uuid) | UUIDv7 rendered as `file_#{id}` for uploads or `ig_#{id}` for generated images. |
| `subject_uid` | Owning Principal; every read, delete, and reference resolution filters on it. |
| `message_id` | Nullable owner message for stateful generated images. |
| `kind` | `uploaded_file` or `generated_image`. |
| `purpose`, `filename`, `mime_type` | OpenAI file metadata and the sniffed image type. |
| `byte_size`, `sha256`, `payload` | Bounded binary payload and integrity metadata. Payload is excluded from ordinary queries. |
| `expires_at` | Optional upload expiry or the stateless generated-image retention deadline. |

`content` holds both sides of one run: the request-side input items and the
model output items live in the same array, in one row. A two-round tool loop
therefore produces rows like:

```json
// row 1 (first response.create of the actor event)
[
  {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "How many files changed this week?"}]},
  {"type": "reasoning", "summary": [...]},
  {"type": "function_call", "call_id": "call_a1", "name": "run_command", "arguments": "{\"cmd\":\"git diff --stat ...\"}"}
]

// row 2 (second response.create, chained to row 1)
[
  {"type": "function_call_output", "call_id": "call_a1", "output": "14 files changed ..."},
  {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "14 files changed this week."}]}
]
```

One call, one row. Multiple output items from one call are elements of the same
`content` array, never separate rows. Streaming deltas are never written to the
log; only the terminal state of a run lands in `content` (see Live Delivery).

`content` must stay JSON-safe. Text, caller-supplied data URLs, provider file
ids, file/image URLs, durable file refs, MIME types, and filenames are fine.
Generated image base64 and raw byte buffers are not stored there. Item content parts such as
`input_text`, `input_image`, `input_file`, and `output_text` are stored as
sent. An unsupported multimodal item is either kept opaque-but-JSON-safe with a
restricted replay path, or rejected as unsupported. It is never silently
flattened into plain text.

Type and content combine under two rules, enforced in the changeset:

- a `checkpoint` row contains exactly one
  `{"type": "compaction_artifact", "id": "cmp_<uuid>"}` ref item;
- a `message` row must not contain compaction items or compaction artifact
  refs.

Errors are statuses, not types. A failed run is a `message` row with
`status = "error"`. `status = "retracted"` remains a cheap audit/recovery enum
value, but v1 IM deletion does not write it: tail deletion hard-deletes, and
historical or compaction-covered deletion is a no-op. Row type states what the
row is; status states where it is in its lifecycle.

`previous_message_id` values always come from `ai_gateway_messages.id`. The two
id spaces never mix (see Response Identity). AIGateway has no Actor-keyed
generating index and does not use metadata as a lifecycle key.

`ai_gateway_conversations` stores conversation identity only:

| Column | Meaning |
| --- | --- |
| `id` (uuid) | The API id `conv_#{id}` is this uuid with a prefix. |
| `subject_uid` | Owning Principal subject. |
| `conversation_key` | Stable external key for the session scope. |
| `ended_at` | Set when the session window is closed. |
| `metadata` (jsonb) | Auxiliary facts. |

Conversations created implicitly by `response.create store=true` with no
`conversation` and no `previous_response_id` use an internal
`conversation_key` and carry
`metadata.managed_by_stateful_responses_api = true`.

The conversation row deliberately stores no active-generation lease and no
"current position" pointer. The continuation base is always derived from the
message graph (see Status And Projection). A stored pointer would be a second
source of truth, and it would drift from the graph on compaction, retraction,
branching, and worker reconnect. Keeping only the graph means there is nothing
to repair. The conversation row is used only as a short transaction mutex when
AIGateway admits an implicit continuation. Under that lock AIGateway recomputes
the visible leaf, rejects an existing `generating` Response, and writes the
optional auto-compaction checkpoint plus new run atomically. This is admission
serialization, not a stored lease or current-position fact.

## Response Identity

Stored ids and database ids are the same identity:

- `resp_#{uuid}` always equals `resp_#{ai_gateway_messages.id}`;
- `conv_#{uuid}` always equals `conv_#{ai_gateway_conversations.id}`.

Decoding a `resp_*` or `conv_*` id means stripping the prefix, nothing more.
There is no mapping table and no alias generation. An upstream provider
response id is never used as an Ankole stored id, and no API frame ever leaks
one: every stateful frame rewrites `response.id` to `resp_#{row id}`.

Two more prefixes exist:

- `tmp_resp_*` is the transport-only id of a stateless response. It cannot be
  used in `previous_response_id`, `conversation`, `GET /responses/:id`, or any
  database write path.
- `cmp_*` renders a compaction artifact id. When a checkpoint exists, the
  artifact, checkpoint row, `cmp_*`, and `resp_*` all share the same raw UUID
  with different public prefixes.

Across the whole system, any column or JSON key that references a model output
is named `ai_message_id` and holds an `ai_gateway_messages.id`. This is one of
four strictly separated identity layers (source event id, source entry id,
actor event id, AI message id). The canonical definition of all four lives in
`docs/design-docs/SignalsGateway.md` under Identity Layers.

## Status And Projection

A message-log row is always in one of four statuses:

- `generating`: the row is in the durable log, but its provider request is
  still in flight. Normal history cannot
  read it, and it cannot be a continuation anchor. Even inside the same actor
  event, the next loop round anchors on the previous round's already-committed
  `complete` row, never on a `generating` row.
- `complete`: the row is part of normal history. It can be read by projection
  and used as an anchor.
- `error`: the run failed terminally. The row keeps whatever content could be
  saved plus `metadata.error` for audit. It is not an anchor.
- `retracted`: reserved for future audit/recovery facts. If present, projection
  skips its `content`, it is never an implicit leaf, and it is not an anchor. No
  replacement note is generated for the model; the row is simply invisible to
  history. Current IM deletion mapping does not write this status.

The API `Response.status` is synthesized from the row:

- `complete` → `completed`;
- `error` → `failed`;
- provider/overflow metadata marking a truncated result → `incomplete`.

There is no `cancelled` status, because there is no cancel endpoint.

The "anchor" of a run is the row its `previous_message_id` points to — the
previous hop of the chain. History projection walks that chain backwards:

- it reads only `complete` rows and skips `retracted` rows;
- when it meets a checkpoint row, it keeps that checkpoint as the visible chain
  element and stops provider-visible ancestor traversal. Provider replay loads
  the referenced artifact output and resolves any Ankole compaction handle to
  summary text before handing the request to the provider adapter;
- it never reads `generating` rows;
- the current request's input comes only from the current `response.create`
  payload, never from re-reading history.

A "visible leaf" is a `complete`, non-retracted row that no other `complete`
row chains from — a tail of the graph. Continuation resolves like this:

- an explicit `previous_response_id` names the anchor directly. It does not
  have to be the newest row. Passing an older `complete` id creates a branch,
  the same way it does in the OpenAI Responses API.
- a request with only `conversation` uses implicit continuation: AIGateway
  tentatively picks the latest visible leaf by creation order, then verifies
  that leaf again while holding the conversation row lock. Zero leaves means
  the conversation starts from empty history. If another run is generating or
  the leaf changed before admission, the request gets `409
  response_in_progress` and may retry after the active run finishes. If several
  leaves already exist because of explicit branching, implicit continuation
  still picks only the latest; it never explores or merges the branch graph. A
  caller that wants an older branch must pass `previous_response_id` explicitly.
- a `store=true` request with neither `conversation` nor
  `previous_response_id` creates a new managed conversation and starts from
  empty history.

## Stateful Write Path And Tool Loop

If you have written a tool-calling agent with the OpenAI SDK or ai-sdk, the
wire shape here is the loop you already know: send a request, get output, run
the `function_call`, send the result back, repeat. The difference is where the
state lives. In a client-side loop, the client owns the growing message list.
Here AIGateway owns history, anchors, and Response persistence. A loop-capable
client owns tool execution, iteration policy, and its own decision to stop.

One `response.create` runs this pipeline:

1. Gate: transport is WebSocket, `store=true` is present, the token is valid.
2. Scope: all queries from here on filter by the authenticated
   `subject_uid`.
3. Resolve a tentative anchor from `previous_response_id` or `conversation`; if
   neither is present, create a managed conversation and start from empty
   history. Expand that chain and, when needed, compute an auto-compaction
   summary without writing an artifact or checkpoint yet.
4. Admit the run in one short database transaction. Explicit
   `previous_response_id` keeps branch semantics. Implicit `conversation`
   continuation locks the conversation row, rejects any ordinary `generating`
   row, and verifies that the tentative leaf is still current.
5. In the same transaction, write the optional compaction artifact and
   checkpoint, then create the run row with `status = "generating"`, the
   request-side input in `content`, and request metadata. The run points at the
   checkpoint from the start. A rejected admission writes none of the three.
6. Expand the admitted history and merge the request-side input items.
7. Strip AIGateway continuation fields such as `previous_response_id`,
   `conversation`, and `store`, then build the provider request. The upstream
   provider sees plain input items, never Ankole continuation fields.
8. Call the provider. While it streams, AIGateway publishes live chunk events
   as process messages (see Live Delivery). Chunks are not written to the row.
9. On the provider terminal, normalize the final model facts into the same
   row's `content`: request-side input items plus output items, one array.
10. Commit the row to `complete` in the database, then send the terminal frame
    to the worker. Commit always happens before the frame. If the commit
    fails, the worker gets a failed frame instead, and the row is either set to
    `error` explicitly or left for the orphan reclaim path. A repeated
    terminal commit returns `already_terminal` and is idempotent.

The loop across calls is worker-driven:

```text
worker                                  AIGateway
------                                  ---------
response.create                          create run row 1 (generating)
  store=true, conversation=conv_...,     expand history, call provider
  metadata.actor_event_id=...,           commit row 1 complete
  input=[user message]              <--  response.completed
                                         output has function_call

(run the tool locally)

response.create                          create run row 2 (generating)
  store=true,                            anchor = row 1, expand history
  previous_response_id=resp_<row1>,      call provider
  input=[function_call_output]           commit row 2 complete
                                    <--  response.completed
                                         output has no function_call

(stop; the loop is done)
```

The main Ankole worker supplies `conversation` and opaque metadata because it is
executing a durable Actor event. Other clients use the same API without that
metadata. If they omit both `conversation` and `previous_response_id`,
AIGateway creates the managed conversation described above.

The Agent Computer owns the loop rule and its per-execution iteration budget.
Every logical model call counts once; provider retries of that same call do not.
If the final budgeted call still requires continuation, the worker makes one
budget-exempt, tool-free summary Response and declares the turn outcome
`iteration_exhausted`. AIGateway neither counts these iterations nor infers
turn completion from `function_call` output.

One Agent turn normally produces a chain of rows linked by
`previous_message_id`. The worker explicitly identifies the final adopted
Response in `turn_completed`; Response shape alone does not make a row an Actor
terminal. The first human input travels inside the first `response.create`'s
`input`; there is no separate stored user-message row.

The worker side stays thin:

- it uses the official `openai` npm package: the OpenAI-compatible client for
  stateless HTTP calls, and the Responses/WebSocket wire shape with a small
  transport adapter for the stateful path;
- it keeps only short-lived execution state: the WebSocket connection, the
  current actor event id, current tool-call ids, and tool-local state;
- it never expands history, never compacts, and never writes `ai_gateway_messages`,
  `ai_gateway_conversations`, or `signal_gateway_outbox_entries`.

## Compaction

Compaction folds an older history prefix into one summary so future runs fit
the model context. It runs entirely in Elixir inside AIGateway. Workers never
summarize and never commit summaries.

A compaction artifact is the durable summary source. Every compact path first
writes `ai_gateway_compaction_artifacts.content` with a versioned body:
summary text, canonical `response.compaction.output`, retained tail items, and
usage. A checkpoint is optional and only exists when the caller needs
`previous_response_id` continuation. Checkpoint rows have `type = "checkpoint"`
and `content = [{"type": "compaction_artifact", "id": "cmp_<uuid>"}]`; the
checkpoint row and artifact share the same raw UUID.

`POST /responses/compact` always returns `object = "response.compaction"`:

- With `store=false` or no `store`, AIGateway writes the artifact only. The
  client continues by passing the returned `output` back as later input.
- With `store=true`, AIGateway writes the artifact and a checkpoint row, then
  adds an Ankole extension containing the checkpoint `response_id` and
  conversation id. If no anchor or conversation is supplied, AIGateway creates
  a managed conversation marked `managed_by_stateful_responses_api = true`.
- The IM command `/compress` is a control-plane command that ends in this same
  artifact/checkpoint path: AIGateway summarizes and writes the artifact plus
  checkpoint, then the user gets fixed command feedback through the outbox. See
  `docs/design-docs/SignalsGateway.md` for the command surface.

Auto-compaction runs inside the write path, at history expansion and admission:

- AIGateway budgets automatic compaction from upstream provider usage recorded
  on history messages. `usage.total_tokens` is used when present; otherwise
  normalized `input_tokens + output_tokens` is used. Missing usage metadata is
  not replaced by a content-length heuristic.
- Over the threshold, it selects the compactable prefix: `complete`
  text-bearing rows after the last checkpoint. It never covers `generating`
  rows, never covers `retracted` rows, and always copies a recent retained tail
  into the artifact output so the current task keeps its latest context.
- An internal summarizer model generates the summary — the agent's `light`
  profile first, falling back to `primary`. The summarizer's usage is recorded
  in the artifact and in checkpoint metadata for operator inspection.
- Summarization produces an in-memory plan first. The short admission
  transaction verifies the implicit leaf, then writes the artifact, checkpoint,
  and triggering run together. A competing implicit continuation may duplicate
  summarizer work, but the losing request writes no branch, artifact, or
  checkpoint.
- The triggering run chains from the checkpoint. The summary of
  already-complete rows is valid whether or not that admitted run later
  succeeds.
- If the summarizer fails, no artifact or checkpoint is written. There is never
  a half-written compaction artifact. The request falls back to truncation, an
  overflow retry, or an explicit error.

Truncation is the fallback ladder:

- `truncation = disabled` (default): an over-budget request that cannot be
  compacted returns a structured `context_overflow` error. The owning client
  may choose a later request with `truncation = auto`; AIGateway does not decide
  an Actor retry policy.
- `truncation = auto`: AIGateway drops history from the head of the
  provider-facing input. It never crosses a valid compaction anchor and never
  mixes covered original rows back in. The durable `previous_message_id` still
  points at the real anchor; truncation changes only what the provider sees.
- When `truncation = auto` drops media or other opaque items, the triggering
  run records them in `metadata.auto_truncation.dropped_opaque_messages`: the
  `resp_*` ids, item types, and any durable or provider refs. Media never
  disappears silently.

Multimodal coverage is conservative: the current version compacts text-bearing
items only. A media item without an auditable summary or durable ref stays out
of the covered prefix.

The compaction prompt semantics are fixed: the summary is reference state, not
a command to continue old work; it must preserve paths, function names,
identifiers, error messages, command lines, and ids; when the covered history
contains reverse signals such as stop, undo, rollback, or a topic change, the
old work is marked cancelled or superseded in the summary.

## Live Delivery

While a provider call streams, its `AIGateway.ResponseStream` sends guarded
OpenResponses event batches directly to the requesting transport. For stateful
responses it also publishes typed preview events through Phoenix.PubSub after
the same guard. Live chunks are preview signals. They are never written to
`ai_gateway_messages`, and no database notification mechanism is involved.

Two consumers subscribe:

- the worker's WebSocket connection receives the guarded batches as
  OpenResponses event frames;
- SignalsGateway's `AIReplyPreview` process filters conversation-scoped events
  by opaque metadata and uses deltas to send and edit the provider-visible
  preview message. A Response terminal event does not terminate the preview or
  complete an Actor turn.

Durable content truth stays in the message log; delivery state stays in
SignalsGateway. The provider-side preview message id is never written back
into a message-log row. Live preview deltas bypass `signal_gateway_outbox_entries`,
but SignalsGateway always commits the adopted final reply through that durable
outbox. The full provider-visible delivery and recovery story lives in
`docs/design-docs/SignalsGateway.md` under Streamed AI Reply Delivery.

## Recovery And Reconnect

Nothing in the stateful path assumes a long-lived process. Recovery rules:

- A stateful WebSocket touches its `generating` row every 60 seconds. An orphaned
  row is detected after the 300-second grace solely from Response status and
  `updated_at`; no Actor activation or delivery is consulted. The caller then
  re-sends the round from the last complete anchor.
- There is no half-stream recovery. The current version keeps no stable item
  snapshots and no content version counter. A broken stream costs one round:
  the partial row goes to `error`, its partial calls remain audit-only, and the
  round is re-sent from the last complete anchor. A function call is executable
  only after a successful tool-use terminal; EOF never upgrades accumulated
  argument deltas into a completed call.
- A control-plane crash can persist a function call before its function output
  reaches the message chain. Before replay, AIGateway detects each dangling
  call and appends a synthetic `function_call_output` whose structured error is
  `tool_execution_interrupted`. This restores a provider-valid chain without
  claiming that the tool succeeded; the resumed model may retry or explain the
  interruption.
- A provider can return a truncated or otherwise malformed
  `function_call.arguments` string that the worker correctly answers with an
  invalid-arguments `function_call_output`. Durable history retains the raw
  call for audit. Current execution and Kernel replay apply a bounded repair
  ladder: strict JSON, fenced JSON, the first balanced object, and deterministic
  closure of containers/trailing commas, followed by the tool's strict schema.
  Kernel uses `{}` only when an unrepairable historical call already has a
  matching output; it drops an unpaired malformed call instead of inventing a
  result or arguments.
- `response.tool_results.record` reconciles outputs against executable calls on
  its explicit anchor. Identical duplicates collapse. Orphans, conflicting
  duplicates, name conflicts, and outputs for partial calls are retained in an
  idempotent `status = "error"` quarantine row and returned as a structured
  error; they never become the latest complete leaf. Provider-facing history
  independently filters structurally invalid calls plus legacy orphan,
  duplicate, mismatched, or non-executable outputs while leaving their durable
  rows untouched.
- A worker reconnect restores tool-execution context only. The worker does not
  repair history; it continues from ids it holds or its owning runtime starts a
  new execution. Failed rows keep their audit content under `status = "error"`.

`GET /responses/:id` is the read-side recovery and debug surface:

- it decodes `resp_*` to a row id and synthesizes the Response object from that
  single row;
- a `generating` row returns `200` with `status = "in_progress"`,
  `completed_at = null`, and `output = []`. The request-side input is visible;
  half-finished provider output is not;
- it does not replay streams (`stream` + `starting_after` is unsupported), does
  not trigger writes, and does not change the chain;
- `tmp_resp_*` returns `404`.

## Authentication

`/api/v1/ai-gateway/*` accepts either:

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

The security model for stateful data is exactly two rules:

1. the 30-day agent token proves which agent is calling;
2. every conversation, message, and anchor query filters by the authenticated
   Principal's `subject_uid`, so subjects are isolated from each other.

There is deliberately nothing else: no per-actor-event tokens, no claims, no
actor-event liveness checks in AIGateway, and no generation lease acting as a
permission. Finer-grained permission layers here would add failure modes
without adding a real boundary — the worker fleet is first-party and already
inside the trusted fabric. Error order is fixed: bad request shape → `400`;
missing or invalid token → `401`; authenticated-but-refused subject → `403`;
anchor or conversation that does not resolve in the agent's scope → `400`.

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

The worker derives its stateful WebSocket endpoint from the same response: the
key response's base URL becomes `ws(s)://.../responses`. The model profile for
a run comes from the turn's `model_ref`; neither the token nor the endpoint is
carried in the RuntimeFabric protobuf envelope.

Workers keep the key only in memory. In the current actor-agnostic worker pool,
process startup has no agent identity, so the executable rule is: fetch the
agent's AIGateway key immediately at turn start before any AIGateway request.
Before each request, the worker checks the expiry. If the key is absent or
expired, the worker calls the RPC again. If Ankole later runs actor-dedicated
workers, those workers should also fetch the key at process startup because
agent identity will be known then.

No refresh token exists for this surface.

## Protocol Edge Case Tests

The local test suite should pin AIGateway behavior around provider and stream
irregularities. These are AIGateway contract tests, not copies of any single
upstream gateway implementation.

Responses HTTP tests must cover non-streaming JSON response shape, no SSE
headers when `stream` is absent or false, complete stateless input requirements,
and the rule that HTTP `previous_response_id`, `conversation`, and `store=true`
are rejected with `400`.

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
embeddings, rerank, web search, and web fetch. Local selector and
configuration failures do not trigger provider failover.

Web tool tests must cover capability registration, profile resolution,
provider config validation, normalized search/extract responses, URL rejection
before extraction dispatch, worker tool registration from `/web_tools`, gateway
success and error propagation, and the explicit unavailable behavior when
provider-backed extraction is not configured. The worker's private rendered-page
fallback is owned by Agent Computer and is not part of this AIGateway path.

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

Stateful contract tests must cover:

- the gate: `store=true` required for durable continuation fields,
  `conversation` and `previous_response_id` are mutually exclusive,
  `store=true` with neither creates a managed conversation, and `400` / `401` /
  `403` ordering;
- WebSocket `store=false` compatibility: sequential responses on one socket,
  same-socket `previous_response_id` continuation, reconnect miss returning
  `previous_response_not_found`, and failed continuation evicting the cached
  response id;
- one run row per `response.create`, with request input items and output items
  in the same `content` array;
- opaque metadata round-tripping without key-specific validation or indexing;
- commit-before-terminal-frame ordering, `already_terminal` idempotency, and
  `response.id` rewriting to `resp_*` on every frame;
- `GET /responses/:id` single-row synthesis, `in_progress` for `generating`
  rows with empty output, and `404` for `tmp_resp_*`;
- `/responses/compact` always returning `response.compaction`, artifact
  persistence for compact output, and `store=true` compact creating a
  checkpoint whose id matches the artifact id;
- 60-second WebSocket touches, orphaned `generating` reclaim after the
  300-second grace, and no Actor/delivery lookup in either path;
- `instructions` non-inheritance, `prompt_cache_key` no-op, and `service_tier`
  stripping.

## Hermes Floor And Runtime Tradeoffs

Hermes commit `3a1a3c7e6727a31df89b61b27bad313430bdac45` is the minimum robustness floor. Equivalent Ankole work must not fail earlier or accept less legal input; Ankole is intentionally wider where BackgroundAgentJob work is longer-lived.

| Boundary | Previous Ankole | Hermes reference | Current Ankole | Tradeoff |
| --- | --- | --- | --- | --- |
| HTTP credential recovery | Two total attempts; a second `401` failed immediately | Auth refresh remains inside the retry loop with `5s` base backoff | Three total attempts: first `401` refreshes immediately; a `401` on the refreshed key waits `5s` before the third attempt | One extra request and at most `5s` latency avoids failing during key rotation or propagation lag. |
| WebSocket reconnect after `response.create` | Close/error was terminal locally | Transient stream failure gets two retries, three attempts total | Close/error retries from the last stable Response anchor, up to three local attempts | Replaying a round costs provider work, but stable anchors prevent partial function-call fragments from executing. |
| First event | No independent signal; the fixed inactivity timer was the only observation | `120s` TTFB for smaller Codex requests; disabled for larger input | Never fatal solely for first-byte delay; emit `slow_first_byte` at `300s` | A warning preserves observability without killing a valid long-prefill request. |
| Post-first-event staleness | Fixed `30m` inactivity | Layered stale budgets up to `180s`, with wider reasoning-model floors | `180s` for estimated input up to `100k` tokens; `300s` above `100k`; overall activity lease `35m` | Slower detection for very large contexts is deliberate; any valid event resets the watchdog. |
| Image input normalization | Oversize images could be dropped and fallback description output was capped at 2,000 tokens | Codex image materialization accepts up to `25 MiB`; normal model output policy applies | Raw ingress up to `50 MiB`, decode guard `268 MP`, concurrency `2`, WebP output at most `4096x4096`, complete data URL at most `4 MiB`; no separate 2,000-token fallback ceiling | Decode and model payload limits remain bounded, while legal high-resolution inputs are normalized instead of rejected early. |

## Known Limits And Extension Points

These are deliberate extension points beyond the implemented
`image_generation` hosted tool. Each one has a defined place in the current
design:

- Additional hosted server-side tools. `image_generation` already executes in
  AIGateway/Kernel, feeds a private result back into the main model, stores image
  bytes in `ai_gateway_artifacts`, and exposes only OpenAI Responses items and
  events. Future hosted tools such as file or workspace search must reuse that
  multi-step executor contract instead of injecting one synthetic result; their
  durable binary payloads likewise stay outside `ai_gateway_messages.content`.
- Named branches. Branching already exists through explicit
  `previous_response_id`. A branch-naming projection can be added later without
  touching the log schema, because the graph is the only truth.
- Multi-instance recovery coordination and richer multimodal compaction
  summaries are future work; see `docs/TradeoffsAndKnownLimits.md`.
- Other stateful clients. Enterprise systems may use the same Principal-owned
  Responses log without routing through ActorRuntime. They share AIGateway's
  Response semantics but own their own workflow lifecycle and side effects.

## Ownership

Elixir owns provider credentials, provider configuration, provider execution,
model binding resolution, AIGateway authentication, normalized HTTP responses,
and the whole stateful Response layer: the message log, history expansion,
continuation anchors, compaction, Response terminal commit, generating-row
liveness, and generic event publication.

RuntimeFabric owns the worker-to-control-plane API-key request path.

Bun workers own prompt construction, local tools, environment capabilities,
loop iteration policy, and explicit Agent turn completion.
If Ankole later exposes MCP servers to model runs, that bridge belongs in the
worker boundary as another local tool source. A worker drives loop iterations
through the official `openai` client over WebSocket. It owns no durable Response
history or anchors and writes none of `ai_gateway_messages`,
`ai_gateway_conversations`, and `signal_gateway_outbox_entries` directly.
