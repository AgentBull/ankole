# AIGateway

The control plane uses AIGateway for every model request. AIGateway stores
provider rows and credentials, selects a model and one credential, prepares the
request, and records Responses. It also owns provider retry and the end of one
model request.

Caller `metadata` is local Response state. Generic OpenAI-compatible providers
do not receive it because support for that OpenAI field is not portable.

AIGateway does not run the Agent model loop and does not complete Actor work.
Agent Computer runs the loop. SignalsGateway completes the ActorEvent and sends
the final reply to the external platform.

## What Runs in Each Process

The Elixir control plane owns provider configuration, credential encryption,
credential selection, OAuth refresh, provider retry, and durable Response
state. The Rust kernel performs one prepared HTTP, SSE, or WebSocket attempt and
normalizes provider events.

Workers receive an Agent-scoped AIGateway token. They never receive external
provider credentials, ChatGPT refresh tokens, or a generated Codex
authentication file.

Every stored AIGateway record belongs to one Principal through `subject_uid`.
AIGateway stores ActorEvent metadata without interpreting it.

A completed Response means that one model request ended. It does not mean that
the Agent turn ended.

## Select a Model for Each Kind of Work

AIGateway supports these capability names:

- `llm`
- `embedding`
- `rerank`
- `web_search`
- `web_fetch`
- `image_generate`

Agent model profiles include `primary`, `light`, `heavy`, `coding`,
`vision_fallback`, `web_search`, `web_fetch`, and `image_generate`. Embedding
and rerank are instance-wide Brain settings, not Agent profiles. A caller can
also select `provider_id/raw-model-id` directly. Every profile and direct
selector points to one provider row. Neither form selects a member of its
credential pool.

Brain selects one maintainer Agent. Its `light` profile runs extraction, its
`heavy` profile runs Dreaming, and its `web_fetch` profile is the provider path
for URL Source learning. If `web_fetch` is absent or its provider request
fails, the Worker uses the same local `ankole-browser` fallback as an Agent
turn. Every Brain model request uses the maintainer Agent as its `subject_uid`,
so execution policy and observed usage belong to that Agent. Brain embedding
and rerank calls use that identity but keep their instance-wide selectors.
The maintainer Agent must be active. If it is disabled, Brain reports the
identity as unhealthy and stops every model request and local URL fetch until
the Agent is enabled or replaced. Stored knowledge and pure-text recall do not
depend on that execution identity and remain available.

An Agent can also store custom LLM profiles in the same
`agents.options["ai_agent"]["models"]` map. A custom name matches
`[a-z][a-z0-9_-]{0,63}`, does not use a fixed profile name, and has a required
description. Custom profiles cannot represent embedding, rerank, search,
fetch, or image generation. The name is immutable after creation. There is no
separate custom-profile entity.

The Agent Console has sibling `Model profiles` and `Custom model profiles`
sections. Both use the same provider, model, context-length, and request-option
form. The custom section also requires the immutable name and description. The
`coding` label identifies the Background Agent Job default model.

For an Agent token, `GET /models` exposes each configured custom name as an
alias and uses its description in the catalog. Another Agent and an admin
human do not see or resolve that alias. Explicit `provider_id/raw-model-id`
selectors remain visible to the subjects that can use AIGateway.

The `coding` profile is an ordinary AIGateway profile. It contains
`provider_id`, `model`, and request-level `provider_options`. A ChatGPT
subscription is an ordinary provider kind. There is no second Codex runtime
mode and no account identifier in a Job.

When `coding` is absent, `heavy` is its fallback. Job creation fails when
neither profile is configured.

## Bind a Codex Job to Its Model Snapshot

When the first execution attempt is admitted, the control plane resolves the
Job's logical model profile and stores it in the Job runtime projection in the
same transaction. An omitted selection uses `coding`; an explicit selection
can use only one custom profile configured for that Agent. The Job stores the
logical profile name separately from the real Codex model, the exact
`provider_id/raw-model-id` selector, all provider options, the optional context
length, and the provider parallel-tool-call capability. A retry uses this
snapshot. A new or respawned Job resolves the current profile at its own first
execution admission.

The snapshot also stores the selected model's direct input modalities. A
text-only model stores a separate `vision_fallback` target only when that
configured model accepts image input directly. The Codex model manifest reports
effective modalities: it reports image input when the selected model accepts
images or when this usable fallback exists. It reports text only when neither
path can accept an image.

Agent Computer puts the real model in the Job project configuration and selects
the `ankole_aigateway` Codex provider. The provider name is `OpenAI` because
the pinned Codex runtime uses that name to enable its remote-compaction
protocol. The provider ID remains `ankole_aigateway`. Agent Computer sends the
frozen binding in the `x-ankole-aigateway-model-binding` header. AIGateway applies this binding
before provider resolution. The binding replaces a conflicting Codex model,
provider option, reasoning effort, or parallel-tool-call choice. It also removes
the Codex-only `internal_chat_message_metadata_passthrough` and
`encrypted_function_args` fields before provider dispatch. Responses Lite stays
serial. AIGateway model cards disable Responses Lite because the pinned Codex
runtime omits configured hosted web search from that private carrier. Standard
Responses keeps the native tool declaration. Thus Codex receives the real model
and effort that it needs for local execution, but AIGateway remains the authority
for the upstream request. The runner removes `model_catalog_json` from the Job project
configuration, so a workspace template cannot replace the AIGateway-owned
model cards. The logical profile name never enters Codex as a model.

The AIGateway model card owns one model-visible tool-output limit of 10,000
tokens. `max_output_tokens` is a requested upper limit. A smaller value reduces
the output, but a larger value does not raise the model-visible limit. The card
instructions state the same limit. Codex processes larger output in code before
it returns the result, or it writes that output to a Job Workspace file.

The binding also carries the direct modalities and the optional frozen vision
fallback. AIGateway sends an image directly only when the selected model
accepts it. For a text-only model, AIGateway makes one stateless request to the
frozen fallback and replaces all current image parts with one untrusted text
description. The main model never receives the original image. If no usable
fallback exists or that request fails, AIGateway replaces the image with an
explicit unavailable marker. Stateful history stores the replacement text, so
later turns do not replay an unsupported image to the text model.

The same path handles API-key providers and `chatgpt_subscription`. Agent
Computer does not resolve, store, refresh, or write back provider
authentication.

## Describe Each Provider in Code

Provider modules use `Ankole.AIGateway.ProviderDSL`. Each module declares its
identifier, settings, default endpoint, transport options, and capabilities.
Each capability selects an upstream protocol, a Rust API resolver, and an
Elixir prepare function.

A setting has one scope:

- `connection` settings belong to the provider row and are shared by all pool
  members.
- `credential` settings are encrypted in each pool member.
- `request` settings belong to a model profile or one request.

Only `credential` settings can set `encrypted`. Connection and request values
are stored and projected in plain form, so the declaration layer rejects an
encrypted setting in any other scope.

A `select` setting limits input to its declared options. A string setting can
declare suggested options and still accept another string. The ChatGPT
Subscription, Azure OpenAI, OpenAI, and OpenAI-compatible providers use this
open string form for `serviceTier`. They suggest `fast` and `flex`, accept a
provider-specific value, and omit `service_tier` when the setting is empty.

A language-model capability can declare `supports_parallel_tool_calls` and
`supports_native_image_generation`. Both declarations default to false.

Hosted-tool support that changes per endpoint belongs to the provider row, not
to the provider kind. An `openai_compatible` row states the capability through
its `endpoint_kind`: hosted web search is part of the Responses protocol, so a
connection configured for the Responses wire declares it, and a Chat
Completions connection declares nothing. `TurnPolicy` reads that stored
endpoint kind and adds `web_search` to the turn's hosted tools, so Main Turns
and Background Jobs project one consistent capability. The supported turn hosted-tool types are `image_generation` and
`web_search`; every boundary rejects other types.

An `openai_compatible` row also declares `supports_openai_tools`. It defaults
to `false`: AIGateway treats the endpoint as a plain function-calling
implementation, emulates custom tools on the Responses wire, and never sends
it a Provider-native compaction request. An operator sets it to `true` only
for an endpoint that faithfully implements the official OpenAI Responses tool
surface, which passes custom tools through verbatim and lets compaction
pass-through reach the endpoint. Official OpenAI kinds always answer `true`;
every other kind answers `false` because it does not speak the Responses wire
natively.

Trusted Plugins can add providers through `ai_gateway.provider`. A Plugin
cannot replace AIGateway storage, authorization, profiles, credential
selection, or secret handling.

## Configure Provider Rows and Credential Pools

`ai_gateway_providers` stores operator-configured provider rows. Each row
contains:

- `provider_id`
- `provider_kind`
- optional `base_url`
- plain row-level `connection_options`
- one encrypted `credential_pool`
- optional `disabled_at`

`provider_id` uses a lowercase slug. `provider_kind` uses lowercase snake case.
The application checks each kind against built-in and active Plugin
definitions.

The pool has one row-level strategy and an ordered list of entries. Each stored
entry contains `id`, `label`, `source`, `priority`, optional `disabled_at`, an
internal `health_revision`, and the encrypted fields declared for that provider
kind. The Console API does not return `health_revision`. A single credential is
a pool with one entry. There is no non-pool execution path.

The four strategies are:

- `fill_first` selects the first usable entry by priority.
- `round_robin` moves selection through the usable entries.
- `least_used` selects the entry with the smallest process-local request count.
- `random` selects one usable entry at random.

A stateful request uses its thread or cache key as an affinity key. Affinity
wins over the configured strategy while that entry is usable. This keeps
account-scoped provider caches stable.

Runtime health is process-local and has three states. It uses the provider row,
credential ID, and health revision as its key. `ok` entries can be selected.
`exhausted` entries stay out of selection until their recovery time. `dead`
entries stay out until an operator replaces or reauthenticates them, or
re-enables their disabled provider. Each of these operations writes a new
health revision. An automatic OAuth token refresh keeps the current revision.
Thus, a late result from an old credential changes only the old revision's
health, affinity, and rate-limit state. Enabling an active provider does not
change the revision or health. Disabled entries also stay out. PostgreSQL
stores the credential revision, but it does not store these rebuildable health
facts.

An upstream reset header sets the recovery time when it is available. The
fallback is five minutes for HTTP 401 and one hour for HTTP 429. A process
restart can cause one additional probe.

The selected credential entry stays in the private request context until
success or failure. This entry supplies both the credential ID and its health
revision. A failure that has no credential attribution does not change any
entry. Credential retries stop after one pool lap.

HTTP 401 is a credential authentication failure. AIGateway can refresh, mark,
or rotate only the attributed credential. HTTP 429 is a credential quota
failure. AIGateway marks the attributed credential exhausted until the
upstream reset time, or until the fallback time when no reset time is
available, and then selects another credential.

Connection, read, and timeout failures and HTTP 502, 503, and 504 responses
belong to the route or Provider endpoint. Before the first Provider event,
AIGateway can retry the same prepared request with the same credential once.
These failures never change credential health and never select another
credential. The first normalized Provider event closes this retry window,
including `response.created`, `response.in_progress`, and `response.failed`.
An overload reported as a terminal event in an HTTP 200 stream is therefore
returned in the current Response and is never replayed. Delay uses exponential
backoff with 0.9 to 1.1 jitter. The kernel never selects a credential and never
retries a Provider request.

A hosted tool failure cannot reopen the complete model request after the main
Provider returns output. A credential HTTP 401 or 429 from the hosted request
can update only its attributed credential. A hosted route or endpoint failure
does not change credential health. AIGateway returns either failure in the
current Response without repeating the main Provider call.

When no entry is usable, AIGateway returns `credential_pool_exhausted`. It
includes the earliest `retry_at` only when a current exhausted entry has a
known future recovery time. Interactive requests receive HTTP 429. A
Background Agent Job with that recovery time returns to `queued` and releases
its Worker assignment until then, but its acquired execution attempt stays
consumed. A stale or missing `retry_at`, an empty pool, or a pool with only
disabled or dead entries uses the ordinary Job retry ladder. AIGateway does not
fall back to a different provider.

The Console shows each entry label, source, health, recovery time, request
count, last selection time, and safe recent error facts. It can add, update,
disable, enable, delete, or reauthenticate an entry. No API returns a
credential value.

Deleting a provider first sets `disabled_at`. AIGateway refuses this operation
while an active model profile still uses the provider.

## Route OpenRouter Sessions and Prompt Prefixes

OpenRouter chat requests use `session_id` and `prompt_cache_key` for different
purposes. `session_id` keeps one conversation on the provider that served its
first successful request. It also keeps the resolved model when the request
uses an OpenRouter router model. `prompt_cache_key` groups requests that can
reuse the same prompt prefix. AIGateway does not copy one value into the other.

An explicit body `session_id` has first priority. The official `x-session-id`
header is next, followed by the existing session and thread header forms. When
none is present, a stateful request uses its durable AIGateway Conversation
UUID. A stateless request with no session identifier omits `session_id` and
lets OpenRouter use its fallback routing. AIGateway preserves each supplied
value and rejects a value that is empty, contains only whitespace, is not a
string, or is longer than 256 characters.

## Use a ChatGPT Subscription Provider

`chatgpt_subscription` uses the OpenAI Responses resolver and the default base
URL `https://chatgpt.com/backend-api/codex`. One provider row can contain many
ChatGPT accounts.

An OAuth pool member contains access, refresh, and ID tokens plus the stored
account ID, plan type, email, last refresh time, and optional FedRAMP flag. An
Enterprise access-token member contains the access token and account ID and has
no refresh flow.

The Console starts device login through the control plane. It keeps the device
login context and calls one poll endpoint at the server-supplied interval. The
control plane exchanges the authorization code and writes the completed pool
entry. If the device endpoint is unavailable, the Console shows the browser
authorization URL and accepts the full localhost callback URL. Login state is
not stored before completion.

The control plane refreshes an OAuth credential during selection when its
access token enters the last five minutes or its last refresh is eight days
old. It locks the provider row while it exchanges and stores rotated tokens.
Concurrent requests then use the stored result instead of consuming the same
refresh token twice.

Both Responses requests and the model-catalog connection check send
`X-OpenAI-Fedramp: true` for a FedRAMP credential.

The model catalog uses the same account-scoped Codex `/models` endpoint as the
connection check. It lists models that the selected subscription account marks
as visible and supported in the API, and caches the normalized list for one
hour. The Console shows these entries in its model combobox and keeps manual
model entry available when the upstream catalog is unavailable.

A permanent refresh error marks the entry `dead`. An HTTP 429 refresh response
keeps the credential and marks it temporarily exhausted. A refresh transport
or endpoint failure leaves credential health unchanged and returns that
failure. An upstream HTTP 401 causes one forced refresh. A second HTTP 401
marks an OAuth or Enterprise entry `dead` and selects another entry.

The upstream ChatGPT transport always uses `store=false` and requests
`reasoning.encrypted_content`. This is a Codex-provider transport rule, not the
main Agent's public lifecycle: a main Agent Response still uses AIGateway
`store=true` state and local tool-result journals. AIGateway stores and replays
the encrypted reasoning content and does not use upstream response storage.
When upstream compaction is enabled, the compaction trigger is forwarded to the
account-scoped Codex Responses endpoint.

The provider prepares the Codex protocol as follows:

- It removes downstream-only and unsupported request fields, including caller
  `metadata`, `max_output_tokens`, and `truncation`, before dispatch. AIGateway
  still stores metadata locally and applies its own history limits.
- It converts standard string input to one user message because the Codex
  endpoint accepts only an input-item list.
- It supplies an empty `instructions` value when the client omits it.
- It removes an orphan reasoning item ID when no encrypted reasoning content
  can support replay.
- It rejects input item IDs longer than 64 characters.
- It removes `parallel_tool_calls` when no tool exists.
- It derives `prompt_cache_key`, `Session_id`, and stateful credential affinity
  from the same thread key. WebSocket requests also use `Conversation_id`.
- It forwards only the declared Codex request headers.
- It sends the required content, accept, beta, connection, originator, and user
  agent headers.
- It uses the account ID stored in the selected credential.
- It always streams upstream. A complete-response caller collects the terminal
  Response from POST SSE. A streaming WebSocket caller uses upstream WebSocket
  `response.create`. An oversized WebSocket message maps to HTTP 413.

The kernel returns only safe provider response headers to the control plane.
It keeps the `x-codex-*` rate-limit family and `cf-mitigated`, which lets the
pool use real recovery times and lets AIGateway diagnose a Cloudflare
challenge. It does not return cookies, authorization, or other provider
headers.

Provider identity settings take priority over inbound Codex identity headers.
Inbound headers take priority over the built-in Codex CLI defaults. Agent
Computer sets `CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_cli_rs` for each Codex
Job process. Thus, Codex creates the Job identity with the Codex CLI prefix,
while the app-server client name stays `ankole_agent_computer`. Enterprise
access-token requests omit the subscription account and Codex identity headers.

AIGateway forwards the caller's own identity headers to the Provider whenever
the caller sent them: originator, user agent, session, thread, request, window,
and Codex turn headers. A caller that sends none needs no rule, and a caller
that sends them is asking for its identity to reach the model, which some
upstreams use to decide service level. This is a pass-through on every
OpenAI-family provider and every transport, because a WebSocket upgrade carries
these as ordinary headers too. Provider-owned values, such as the ChatGPT
Subscription session and account identity, still overwrite them.

Agent Computer sends the current Actor Session as `Session-Id` on every
AIGateway model request. Different Actor Sessions keep different values even
when they use the same Agent, channel, instructions, tools, or prompt cache
route. A retry or WebSocket reconnect for one model call keeps the same value.
`prompt_cache_key` remains an independent cache-routing and credential-affinity
input.

Responses Lite keeps its compact request and response shapes for ChatGPT. For
other providers, AIGateway restores the normal Responses shape before provider
preparation. A real Codex client keeps Tool Search and programmatic tool calls
native. The main Agent uses the local compatibility loop. Both paths use the
same public item and lifecycle contracts.

## Runtime API

All runtime routes use `/api/v1/ai-gateway`.

The current routes are:

- `GET /models`
- `GET /files`
- `POST /files`
- `GET /files/:file_id`
- `GET /files/:file_id/content`
- `DELETE /files/:file_id`
- `GET /responses`
- `GET /responses/:response_id`
- `POST /responses`
- `POST /embeddings`
- `POST /rerank`
- `POST /web_search`
- `POST /web_fetch`

`GET /responses` upgrades to the Responses WebSocket protocol.
`POST /responses` creates a stateless response through JSON or SSE.

## Identify Every Caller

The runtime API accepts an Agent AIGateway token or an active administrator token.

Agent tokens are HS256 JWT credentials.
They have the audience `ankole.ai_gateway` and the scope `ai_gateway`.
Their default lifetime is 30 days.

`Ankole.AIGateway.Tokens` owns token minting and verification. The RuntimeFabric
broker and the Phoenix authentication plug consume that domain service.

The control plane derives the signing key from `SecretKeyBase`.
The Worker requests an Agent token through an authenticated RuntimeFabric RPC.
That response also supplies the AIGateway base URL.

The deployment can set `ANKOLE_AI_GATEWAY_BASE_URL` to any AIGateway endpoint
that its Workers can reach. If it is absent, the broker uses the Phoenix
endpoint URL. The Kubernetes chart sets the value to the control-plane Service
DNS name. Docker and other deployments can use a host, ingress, or external
endpoint instead. AIGateway does not classify the endpoint as internal or
external.

Every runtime request has one authenticated `subject_uid`. Every query for a
conversation, message, or artifact filters by that Principal.

## Create a Response without Storing It

HTTP Responses calls are stateless.
They do not write `ai_gateway_conversations` or `ai_gateway_messages`.

Codex uses this `store=false` path and replays the Responses items that it
needs. The main Agent does not use this path. It opens a stateful WebSocket
Response with `store=true`, records client tool results through
`response.tool_results.record`, and continues from the returned durable anchor.

HTTP accepts `store=false`.
It rejects `store=true`, `conversation`, and `previous_response_id`.

Stateless WebSocket calls also avoid PostgreSQL. One connection can remember 32
completed Responses for local continuation.

Codex uses `response.create` with `generate=false` to prepare a WebSocket
connection. AIGateway completes this request locally and does not open a
provider stream. The empty Response has zero usage. AIGateway remembers the
request input under its temporary Response ID, so the first generated request
can use `previous_response_id` without losing that input.

Local continuation adds remembered input and output to the next request. It
cannot retrieve a Response from PostgreSQL.

Stateless Response identifiers use the `tmp_resp_` prefix.
The retrieve endpoint does not return those identifiers.

## Store a Response and Continue It Later

Stateful execution requires WebSocket `response.create` with `store=true`.

Stateful history replays as Responses items. A stateful request must resolve to
a provider wire that replays those items without loss: `openai_responses` or
`openai_chat_completions`. AIGateway rejects other wires at turn start with
`stateful_wire_unsupported` (status 422). Providers on other wires, such as the
Anthropic wire, stay available for stateless requests. To move a conversation
across wire families, start a new conversation.

Tool history is also provider-implementation specific. A native Responses
history can contain caller-scoped Shell, Apply Patch, or other provider-hosted
items that the local compatibility runtime cannot execute. If a later route
would move that history into the local runtime, AIGateway rejects the first
unsupported child with `invalid_program_child` instead of changing its meaning.
Start a new conversation when the provider change crosses this boundary.

A visible leaf is the last Response currently available for continuation. A
request chooses one of these ways to continue:

- Provide `conversation` for implicit continuation from the current visible leaf.
- Provide `previous_response_id` for an explicit branch from one completed Response.
- Provide neither value to create a managed conversation.

A request cannot provide both selectors.
External conversation identifiers use the `conv_` prefix.
External Response identifiers use the `resp_` prefix.

Implicit continuation stays on one line of history. The start transaction locks
the conversation and checks its last visible Response.

The same transaction rejects another Response that is still generating. The
WebSocket returns `response_in_progress` with status 409.

`previous_response_id` is the explicit way to branch. It links the new Response
to the completed Response selected by the caller.

AIGateway plans compaction before it tries to start the run. One transaction
then inserts both the checkpoint and the generating Response. If another run
wins the race, compaction does not change history.

AIGateway does not promise lossless history replay after a Provider changes how
it accepts provider-native Responses items. It does keep the conversation
usable. When an OpenAI Responses Provider returns HTTP 400 with
`error.type=invalid_request_error` and `error.param=input` before the first
Provider event, AIGateway rebuilds the durable history as one local version 2
checkpoint and retries the current input once. The retained tail contains no
Provider item IDs, encrypted reasoning, or encrypted function arguments.

The checkpoint transaction also changes the generating Response to point to
the checkpoint before the retry starts. If the retry fails, the failed Response
becomes terminal but the checkpoint remains the visible continuation anchor.
The next turn starts from that checkpoint. AIGateway does not run this recovery
after a Provider event or local tool effect. Authentication errors, rate
limits, 5xx responses, and transport failures do not start it.

## Own the Identifiers on Each Link

AIGateway has two links. The upstream link connects AIGateway to a Provider.
The downstream link connects AIGateway to a consumer, such as a Codex Job or
the main Agent. Each link carries its own identifiers, and each set of
identifiers has one owner.

The Provider owns the identifiers on the upstream link. When AIGateway replays
an item to a Provider, that item must carry the identifier that this Provider
gave it. AIGateway does not invent that identifier and does not replace it. An
item that the Provider never identified goes back with no identifier. A
Provider validates some of these identifiers against state that only it can
read, such as encrypted reasoning, so a substituted identifier makes the
request fail.

AIGateway owns the identifiers on the downstream link. What a consumer holds is
AIGateway's to decide, not the Provider's, because Provider substitution is why
AIGateway exists and a contract built on Provider identifiers could not survive
it.

These two rules make AIGateway the owner of the map between the two sets. The
map must stay available for as long as the identifier can come back. A stateful
conversation keeps the Provider identifier with the stored item. A stateless
WebSocket keeps the map in the connection, and the map ends with the
connection. A map that lives for one Provider stream is too short, because a
consumer replays its history after that stream ends.

`previous_response_id` is opaque to the consumer that holds it. AIGateway
resolves it with a lookup and never from its characters. The request mode
selects where AIGateway looks: `store=true` selects the stored conversation,
and a stateless WebSocket request selects the connection history. The shape of
the string says nothing about where the history is. Code that parses this token
to make a decision is wrong even when its parsing rules are correct, because
the token can be a value that a Provider chose.

One downstream Response has one authoritative Provider call. AIGateway can make
more Provider calls for its own machinery, such as a tool loop, a program call,
or compaction. Those calls are internal, and the consumer does not see them as
Provider calls. A retry replaces its failed attempt completely, and the failed
attempt contributes nothing. Every item that reaches the consumer comes from
the authoritative call or from AIGateway itself.

The downstream identifiers reuse the Provider value when there is one. That is
an implementation choice, not the rule: a consumer that keeps a stateless
history holds it for longer than any connection, and AIGateway stores nothing
for that history, so it could never keep a map that lives long enough. Reuse
removes the need for one.

AIGateway mints an identifier when it cannot reuse the Provider value, which
today means one response already uses that value for a different item. Every
minted identifier carries the `ankole_` prefix, so the Provider request
boundary recognizes it without a stored map and removes it. Two minted
identifiers stay: one that a family carries in `id` as its pair identity, and
an `item_reference`, which is nothing but its `id`. Both match items inside the
same request and address nothing on the Provider.

## Keep a Conversation after Its Provider Changes

A Provider seals part of what it returns. Reasoning `encrypted_content` and the
parameters a tool declared `encrypted` are readable only by the Provider that
issued them, and a different Provider rejects the whole request instead of
ignoring the parts it cannot read. A stateful conversation meets this when an
operator repoints a model profile, or when a vision fallback sends one Turn to
another Provider.

The goal is a conversation that still runs, not one that keeps every byte. So
AIGateway separates structure from content. Messages, calls, outputs, and the
pairing between them are structure, and all of it survives. Sealed values are
content, and they do not. Nothing is removed that another item pairs with,
because an orphaned call would break the history for every later Turn.

Each stored message records its issuing Provider. When a Turn resolves to a
different Provider, AIGateway removes each reasoning item that carries
ciphertext, because nothing refers to those items. It keeps every call that
declared encrypted parameters, replaces those parameters with a plain value,
and removes the marker, because the call pairs with an output. The Agent loses
hidden reasoning that it derives again, and the wording of a call that already
ran; the result of that call stays in plain text.

The Agent cannot avoid this loss. Those parameters are written by the model and
sealed by the Provider, so AIGateway never holds the plain values.

The recorded issuer is the Provider row. A row that puts more than one vendor
behind one selector can still change the real upstream without changing the
issuer, and AIGateway does not detect that. The Provider 400 recovery above is
what answers it.

A message stored before AIGateway recorded issuers has no issuer and replays
unchanged. Its sealed state either still belongs to the current Provider, or
the Provider rejects the request and the recovery above rebuilds the history
without it.

A stateless caller keeps its own history, so AIGateway cannot mark those items
and cannot remove sealed state on its behalf. A Background Agent Job freezes
its Provider for the life of the Job, so its Provider does not change between
Turns.

## What AIGateway Stores

`ai_gateway_conversations` stores the Principal, conversation key, end time, and metadata.

Only one active row can use the same `(subject_uid, conversation_key)`.
A caller can create a new active row under the same key after the conversation ends.

An active Conversation is an AIGateway storage state. It does not identify an
Actor session. A caller that uses a Conversation for a finite internal trace
ends that Conversation when its work ends.

`ai_gateway_messages` stores each Response run, tool-result journal, or compaction checkpoint.

Message row types are:

- `message`
- `checkpoint`

Message row states are:

- `generating`
- `complete`
- `error`
- `retracted`

`previous_message_id` links each row to its parent. The public Response ID uses
`resp_` followed by the message UUID.

`content` stores the Response items. AIGateway returns caller metadata without
interpreting it.

AIGateway also keeps request and provider details in the metadata object. That
object must not contain a second Response item list.

## How a Stateful Response Runs

A stateful model round follows this sequence:

1. Validate the request and the authenticated subject.
2. Resolve the Agent profile or explicit provider selector.
3. Resolve the conversation and continuation anchor.
4. Expand complete message history.
5. Plan automatic compaction when the context requires it.
6. Start the run in one transaction.
7. Insert one message row with `status = generating`.
8. Prepare the upstream request without Ankole stateful fields.
9. Stream normalized provider events.
10. Store complete content or an error before reporting that the Response ended.

The Worker opens at most one active Response stream on each WebSocket.
The socket rejects a second command while that stream is active.

The control plane publishes Response events for each conversation. SignalsGateway
can subscribe and use its own metadata to select relevant events.

## Run Tool Search and Program Calls

AIGateway normalizes the executable tool contract before the first provider
round. One descriptor keeps `namespace` and `name` as the canonical tool
identity. It also keeps the input and output schemas, codec, deferred-loading
state, and allowed callers. It rejects incompatible duplicate identities and
creates one fingerprint from the complete executable snapshot. A later Tool
Search result can repeat a known tool only when its descriptor is equal, and a
program can resume only against the same fingerprint.

Native Responses declarations group namespaced tools in a `namespace`
container. A `function_call` keeps that container name in `namespace` and the
leaf name in `name`. Tool Search, execution, history, and replay keep these
fields separate. They do not parse a combined tool name. AIGateway rejects a
namespace or leaf name that does not match `^[A-Za-z0-9_-]+$` before provider
dispatch.

`ResponseItems` is the semantic owner for Responses call/output pairs. The
current registry covers function, custom, program, Tool Search, computer,
local-shell, shell, apply-patch, and MCP approval pairs, including the different
identity field used by local-shell output. It also includes program caller
scope in pair identity. Streaming, persistence, compaction, truncation, and the
tool budget use this registry instead of separate item-type lists. An unknown
provider item can pass through as opaque content, but it is not executable or
pair-aware until the registry declares its contract.

Tool Search uses one synthesized provider function and exposes
`tool_search_call` plus `tool_search_output` in the public Response. Server mode
executes the search in AIGateway. Client mode returns the search call to the
caller. Both modes preserve one public response lifecycle across later provider
rounds.

A settled Tool Search call and output remain provider history when a later
request no longer declares Tool Search. Every client-loaded contract in the
effective input stays callable across later user turns. Removing a contract
from its surviving `tool_search_output` removes that contract from the loaded
set. Local compaction keeps the minimum complete client call/output pairs that
preserve this set; a later equal contract makes an earlier pair redundant. A
server-loaded tool stays callable only while its structured identity remains in
AIGateway's current deferred catalog. Client and server outputs do not
establish each other's loading state. A conflicting contract for the same
public identity is invalid.

A nonempty provider terminal output remains authoritative. If the terminal
omits output after complete output-item events, the loop uses the raw items from
that provider round to decide local execution. It clears these temporary items
before the next provider round.

Programmatic tool calls run in a fresh bare V8 isolate. The program has no Node,
filesystem, or network API. It runs until it finishes or reaches its first
unanswered tool-call batch. A resume replays the program from the start with
the recorded answers. Nested calls carry their program caller identity, and
Agent Computer executes one only when the frozen tool descriptor permits the
`programmatic` caller. A direct-only or incomplete call becomes an explicit
tool failure and does not cross the execution boundary.

The synthesized program tool lists only the JavaScript global names of bindings
that also have direct declarations. Their schemas already exist in the provider
tool array. Each runtime binding also keeps its separate `namespace` and `name`.
The global name follows Codex code mode. A root tool and the default
`functions` namespace use `name`. Another namespace normally uses
`namespace__name`, and no separator is added when the namespace already ends
with `_` or the name starts with `_`. Codex then replaces characters that are
not valid in a JavaScript identifier with `_`. The program tool embeds the full
contract only for programmatic-only bindings, because the model has no other
way to receive those schemas. Two structured identities that map to the same
global name make the contract invalid.

Stored program fingerprints use `ankole_ptc_v2.` and freeze `namespace`,
`name`, and the JavaScript global name for every binding. Other fingerprint
versions are unsupported.

A settled program call and output remain readable provider history when a
later request has no PTC declaration. This can occur when a release, Skill
change, or temporary tool-catalog failure removes the last programmatic
binding. AIGateway projects the completed pair without adding a new program
tool. An unsettled program still requires the PTC declaration and its frozen
bindings before AIGateway can resume it.

A first-party OpenAI Responses request keeps Tool Search and Programmatic Tool
Calling provider-native. A ChatGPT Subscription request does the same only
when the inbound protocol identifies a real Codex client. The ChatGPT Codex
endpoint rejects the Responses API `programmatic_tool_calling` declaration
from the main Agent, so the main Agent uses local planning with that provider.
This provider-and-client-protocol decision cannot change when a later turn
adds or removes a tool. OpenAI Chat Completions and other providers also use
local planning. Only function and custom tools can become local program
bindings; each provider-hosted tool keeps its provider-owned contract. Codex
and Agent Computer declare apply-patch as a custom tool and shell execution as
a function tool, so AIGateway does not emulate provider built-in apply-patch or
shell declarations for local PTC.

OpenAI Chat Completions and Anthropic Messages have only one tool-name field.
Their terminal adapters derive one Provider wire alias from the structured
identity and restore `namespace` and `name` before an event enters the public
Responses contract. A name that matches `[A-Za-z0-9_-]{1,64}` stays unchanged.
Another name uses a valid readable prefix and a 12-character BLAKE3 suffix.
This wire rule is separate from the Codex code-mode JavaScript global-name
rule. The adapters reject two structured identities that produce the same
Provider alias. No earlier AIGateway layer flattens the identity.

`ResponseStream` remains the sole owner of public events, sequence numbers,
loop advancement, and durable commit. Program execution runs under a bounded
`Task.Supervisor`, so a dirty native call cannot block the stream owner. The
Rust registers only a program that has started running. Cancellation addresses
that running entry and then stops its BEAM task. If an owner is killed in the
short interval before registration, cancellation can miss and one native slot
can remain occupied until the 30-second watchdog ends that run. This bounded
loss replaces a separate reservation and guardian protocol. The same lifecycle
owner serves SSE, WebSocket, and collected non-streaming Responses.

One public `max_tool_calls` budget covers all internal rounds. A zero budget
removes every built-in tool before the first provider call. Every provider
round receives the remaining positive limit. At its terminal, provider-owned
built-in calls consume the budget before AIGateway admits locally owned Tool
Search or program calls from that round. An unadmitted local call is not
published or executed. Later rounds remove built-ins and stale `tool_choice`
values after the budget is exhausted. Function and custom calls are outside
this built-in-tool budget. Budget exhaustion does not synthesize
`response.incomplete`; the real provider or loop terminal remains
authoritative.

Internal work is bounded before it can amplify provider or worker cost. One
public response permits at most 16 internal rounds, 8 top-level programs, 256
nested program calls, 1,024 retained provider-history items, and 8 MiB of
retained provider history. The native runner also caps program code, memo,
pending calls, output, heap, runtime, and concurrent isolates. These limits fail
the affected response or program explicitly instead of dropping a dependency
edge.

Histories written before this registry existed can contain contradictory pair
identities, including duplicate items produced by the earlier PTC bug. Such a
history has no safe compaction or truncation boundary. AIGateway rejects it
instead of guessing or rewriting durable facts. The operator must start a new
conversation, or use the existing validated tail retraction or deletion when
the invalid rows form the current removable tail.

## Record Tool Results before the Next Model Call

The Worker can send `response.tool_results.record` before the next model call.
The command requires a completed `previous_response_id` and at least one client
tool output.

AIGateway matches each result to an executable tool call of the same type on
the anchor. It supports `function_call` with `function_call_output` and
`custom_tool_call` with `custom_tool_call_output`. Valid results become one
completed tool-result row.

The journal has a deterministic idempotency key.
Retrying the same record operation returns the existing row.

Unmatched results enter an error row and never reach provider history.

Implicit continuation can detect an interrupted client tool call that has no
stored result. It adds an interrupted output of the matching type before it
replays the current input.

Explicit continuation does not rewrite the caller-selected branch.

## Store the Result before Reporting Completion

The stream stores terminal content before it sends a public terminal event. If
that write fails, AIGateway tries to store a failure instead. It sends
`response.failed` only when that failure is durable. If both writes fail, it
cancels the provider stream and closes the transport without a terminal event.

A generating row receives heartbeat updates during a live response.
RuntimeEvents schedules an orphan check after each heartbeat.

A row becomes stale after five minutes without a heartbeat. The cleanup handler
changes it to `error` and records a retryable failure.

A failure update affects only the named generating Response. AIGateway never
uses metadata to select an ActorEvent.

Callers can retract or delete a selected end section of visible history. The
selected rows must exactly match the current complete chain.

Retraction keeps the rows for audit but hides them from normal history. Hard
deletion removes only the rows that AIGateway validated.

## Shorten Long History

Compaction has one protocol and one owner. Every caller asks for it the same
way: a Responses request whose input carries a `compaction_trigger` item.
AIGateway answers that request itself and never forwards the item alone, so no
caller depends on a Provider understanding it. The reply is a completed
Response carrying exactly one `compaction` output item.

The trigger is a request item, not a transport event, so every transport
answers it: HTTP returns the Response body, SSE and the WebSocket render the
same reply as events. It is an OpenAI-family extension rather than part of the
base OpenResponses request, and AIGateway implements it rather than passing it
on, so a caller does not have to know which Provider is behind the selector.

Compaction adds; it does not delete. A stateful compaction writes an artifact
and a checkpoint row, and the summarized rows stay in the conversation. Normal
reads stop at the checkpoint, while recovery walks past it to rebuild from raw
predecessors, which is what makes a Provider binding change survivable. Both
backends write the same two records: the local backend stores its summary, and
the pass-through backend stores the Provider output with its binding.

A stateful caller compacts the stored conversation, because AIGateway holds
that history and the caller sends only its current turn; its reply carries the
checkpoint id, so the next turn continues from it. A stateless caller compacts
the input it sent, because only that caller holds its history. Stateful
compaction requires `store=true` when it uses a conversation or Response
anchor. The Main Agent `/compress` command uses the same local checkpoint
rebuild path. It is the manual recovery path when automatic replay recovery
does not match a Provider failure.

When a caller sends no trigger, the history's token total decides. AIGateway
owns that total and compacts on its own threshold, so no caller has to watch
its own context to stay inside it.

The `ai_gateway.compaction` AppConfigure value has these fields:

- `threshold` defaults to `0.90` and controls the Main Agent automatic trigger.
- `max_threshold_tokens` defaults to `400000` and caps that trigger.
- `tail_rows` defaults to `4` and controls only local retention.
- `user_message_budget_tokens` defaults to `20000` and controls only local
  user-message retention.
- `upstream` defaults to `false` and selects the pass-through backend.

Under that one protocol there are two backends. The local backend writes the
summary with the Agent's light profile. The pass-through backend forwards the
trigger to the Provider and returns the Provider's own compaction item. The `upstream` field of the
`ai_gateway.compaction` settings selects between them, next to every other
compaction field. It defaults to `false`, because Ankole can always compact
locally, and because a Provider-owned compaction item binds the rest of that
history to the same upstream. It is an instance decision, not a per-Agent
capability: one Ankole instance serves one enterprise, and the binding it
creates outlives the Agent that triggered it.

Pass-through needs two structural preconditions: an effective Responses wire,
because no other protocol carries this item, and a connection that declares
official OpenAI tool support, which an `openai_compatible` row states with
`supports_openai_tools`. A connection that declares neither falls back to the
local summary without a request. Past those gates AIGateway does not judge
whether the upstream implements the item. It sends the request and reads the
reply; an upstream that cannot answer falls back to the local summary below,
and a stable unsupported result is cached. This decision is made per request,
not frozen with the Job, so a Provider failover cannot leave it pointing at a
Provider that never made it.

The pass-through request uses the standard streaming Responses preparation and
stream owner, because some upstreams accept only streaming requests. A
wrong-shaped Provider reply never reaches the caller. AIGateway collects the
stream to its terminal Response and requires exactly one `compaction` output
item before any of it enters the public stream. When that check fails,
AIGateway serves the same request with its own summary instead. A history that
already holds a Provider-owned compaction item keeps that item: the summary
covers only the items after it, and the checkpoint preserves the Provider item
verbatim, as described under the stateless trigger below.

Only a stateless caller can be forwarded, because it sends the history the
Provider must compact. A stateful caller's history lives here, so its
Provider-native path stays inside conversation compaction.

AIGateway keeps one negative, node-local ETS cache for upstream compaction. Its
key contains the Provider row UUID, Provider row update time, and resolved
model. An HTTP 404 or 405 result stores `unsupported` for one hour. A Provider
can also map a stable, structured unsupported error to the same result. A cache
hit uses local compaction without another request. Authentication errors, rate
limits, timeouts, conflicts, 5xx responses, transport failures, malformed
responses, and empty output use local compaction for that attempt but do not
populate the cache. A process restart, Provider update, or model change causes
a new probe. Concurrent cold probes can each receive an unsupported response.
The cache holds one entry per Provider row and model, so it applies to every
Provider kind that reaches this path.

The local summary always uses the Agent's `light` profile, whatever model the
compacted conversation itself used. The summarizer is internal work with its
own cost and latency profile, so it does not follow the request model. An Agent
that configures no `light` profile resolves it to `primary`. The local
checkpoint budget still uses the request model's context length.

`ai_gateway_compaction_artifacts` stores each compaction result. Version 2 is a
local artifact. It contains one summary object and a list of output items. Its
public `ankole:compact:v1:` handle remains valid. AIGateway resolves that handle
to a user `Context checkpoint` message before the request reaches the kernel.

Version 3 is an upstream artifact. It contains the provider output as one
ordered, unmodified JSON array, its usage, and a binding to the provider row
UUID, provider row update time, and resolved model. It has no public handle.
AIGateway accepts any nonempty output array and does not interpret, trim, or
reorder provider-native items.

A checkpoint message contains exactly one `compaction_artifact` reference.
The checkpoint and artifact use the same UUID.

When AIGateway builds model history, it replaces the checkpoint with that
output. For a version 3 artifact, the current binding must match before
AIGateway sends the output. A provider or model change causes AIGateway to read
the durable predecessor chain, create a local version 2 checkpoint, and send no
foreign provider state. The same raw-history fallback runs when a later
upstream compaction attempt fails. The predecessor messages remain stored, so
this recovery does not require a second history store.

Version 3 keeps this binding check because its provider-native output is one
opaque value that AIGateway cannot project item by item. Reactive replay
recovery does not replace this check.

A stateless trigger returns version 3 output without an Ankole handle. The
caller must continue with a compatible Responses provider. When its input
already contains provider-native compaction state and upstream compaction is
disabled or fails, AIGateway cannot read that ciphertext, so it does not fail
the compaction and does not invent a summary over it. The local summary covers
only the items after the last Provider compaction item. The artifact stores the
Provider items through that item verbatim as an opaque prefix, and both replay
surfaces emit that prefix ahead of the local checkpoint: handle resolution for
a stateless continuation, and checkpoint materialization for a stored one. The
reply still carries exactly one compaction item. AIGateway logs a warning when
it preserves a prefix. Replayed Provider state still reads only on a
compatible upstream; a Provider change keeps the existing stateless contract.

The kernel preserves provider-native compaction items on the Responses wire.
It rejects those items on other wires with
`unsupported_compaction_replay_wire`.

The compaction summarizer uses the shared Responses pair registry for every
registered call and output type. It renders bounded arguments, code, actions,
and results with one-call `call_N` aliases. Persisted provider call IDs do not
enter its prompt.

The configured tail row count is a preference. AIGateway can move the
compaction boundary forward to include a completed call batch or to keep the
retained tail and current input within the history budget. It can move the
boundary backward when the current input closes a call. Before AIGateway stores
a checkpoint, it estimates the selected user originals, summary, retained tail,
retained client Tool Search pairs, pending clarification, and current input
together. It moves the safe boundary forward once when the retained Tool Search
pairs reduce the available tail budget. That refit reserves every pair that can
cross the maximum safe compaction boundary, so another crossed pair cannot make
the fitted checkpoint exceed the budget. An over-budget result cannot create
an artifact and uses the normal overflow policy. AIGateway does not discard an
active Tool Search pair to make a checkpoint fit.

The summarizer uses the standard streaming Responses preparation and stream
owner. AIGateway creates its request context before model resolution and keeps
the same cache key when it prepares the provider request. It reads the stream
until a terminal Response arrives. A completed Response supplies the summary,
and a `max_output_tokens` incomplete Response can start the existing larger
output retry. A failed Response or a stream that closes before a terminal
Response cannot produce a compaction artifact.

Internal history traversal supports 10,000 rows.
The public chain API returns at most 500 rows.

### Automatic Overflow

Each stored provider usage value is a cumulative snapshot of the conversation at
that Response, not an amount to add to earlier Responses. Automatic decisions
read the newest snapshot in the visible history.

When the context exceeds its threshold and compaction has no candidate, a
request with `truncation=auto` selects the configured stable tail, then expands
the tail backward until the client tool calls and outputs in history and the
current input form a valid boundary. This rule includes `program` and
`program_output`; truncation cannot retain a program output after it drops the
matching program.

AIGateway stores the selected tail in a normal `CompactionArtifact` and creates
a checkpoint with a fixed summary that says older history was omitted for the
active context budget. The new Response points to this checkpoint. Raw earlier
messages remain in PostgreSQL for audit, and checkpoint metadata records the
dropped range and opaque references. Later continuations replay the checkpoint
instead of loading and truncating the same full history again. A later
stable-tail checkpoint replaces the prior fixed summary instead of stacking
another copy, but it keeps a real earlier compaction summary.

A suffix size cannot be derived from cumulative snapshots, so this path reports
no exact post-truncation Provider token count. It still applies the local
checkpoint estimator to the fixed summary, retained client Tool Search pairs,
selected tail, and current input before it stores the artifact. When no valid
boundary fits, the request returns `context_overflow`.

## Store Vision Files and Generated Images

`ai_gateway_artifacts` stores uploaded vision files and generated images.

Uploaded files require `purpose=vision`.
Generated images can link to the message that produced them.

The maximum image payload is 50 MiB.
Stateless generated images expire after 30 days.
Generated images linked to messages in PostgreSQL do not use that stateless
expiry.

The main language-model provider owns image generation when its Responses
capability declares native support. A configured `image_generate` profile is a
fallback only when the main provider has no native path. The fallback runs the
public `image_generation` tool as a hosted tool, and the main provider sees only
the hidden function used by that executor. The image provider endpoint catalog
removes endpoints that cannot satisfy the request. All remaining endpoints stay
eligible.
The public tool rejects `output_compression` unless `output_format` is `jpeg`
or `webp`. This validation runs before hosted or native execution is selected.

OpenAI and `chatgpt_subscription` declare native image generation. Their native
path does not resolve or validate a configured fallback, so a stale fallback
cannot block an ordinary conversation. If neither native nor fallback execution
is available, request preparation returns an explicit unsupported-value error.
AIGateway never adds an image tool that the caller did not declare. Before a
native dispatch, it inlines local input-image and mask references because the
Provider cannot read Ankole artifact IDs.

The hosted tool can run for 30 minutes.
The prepared streaming limits allow 128 MiB for the generated upstream response.
If the main provider uses a Responses WebSocket, each hosted fallback model
round uses that WebSocket transport. Other streaming providers use one
collected non-streaming main-model request for each round.
Image persistence observes normalized image events from both execution paths.
It stores the final image and accounts for native image usage. A hosted item
id is a local `ig_` UUID and stays the Artifact primary key; a native
provider's own item id is stored separately so later references to it resolve.
A hosted image attempt rotates only the image provider pool, while a main
model attempt rotates only the main provider pool. Usage stays attributed to
the credential that ran each attempt. An upstream failure keeps its provider
HTTP status in safe public error details. When the provider supplies
`error.message`, the authenticated caller receives a bounded copy. The
provider body and metadata stay private.

## Observe the Execution Path

Agent Computer logs the resolved AIGateway scheme and host at the start of a
turn. It does not infer network topology from the host. It logs the resolved
tool names once. It also logs each main model attempt, retry decision, tool
execution, and tool-result record operation with the ActorEvent ID and elapsed
time.

AIGateway logs an active WebSocket interruption with the ActorEvent ID, model,
and elapsed time. It logs every failed synchronous provider request with the
capability, provider, model, resolver, upstream host, duration, safe provider
status, and retry classification. The image-generation path logs all eligible
provider endpoints and logs failures with separate provider and public HTTP
statuses plus the execution stage.

One failure diagnostic owner normalizes synchronous, streaming, and hosted-tool
failures. Provider 4xx rejections and explicit consumer cancellations use
`WARNING`. Provider 5xx responses, transport failures, and internal execution
failures use `ERROR`.

Optional trace export uses the official OpenTelemetry API in the control plane
and sends OTLP over HTTP/protobuf. OpenTelemetry is the process-wide
instrumentation and export implementation, and OTLP is the receiver contract.
An observability Provider adds vendor attributes only to Turn roots and
AIGateway LLM spans.
It is not an AIGateway Provider, does not own transport, and does not filter
other OpenTelemetry spans.

AppConfigure owns four installation-wide values:

- `observability.traces.enabled` defaults to `false`.
- `observability.traces.provider` selects `langfuse`, `langsmith`, or
  `opentelemetry`. This value has no default when export is enabled.
- `observability.traces.otlp_endpoint` is the base OTLP HTTP endpoint. The
  exporter appends `/v1/traces`.
- `observability.traces.otlp_headers` is one encrypted string map for receiver
  authentication and protocol headers.

User attribution is not an AppConfigure value. The control plane derives it
from each Turn. The Console does not expose another observability field for
this rule.

The three Providers use the process-wide OpenTelemetry SDK and OTLP exporter.
`langfuse` adds the Langfuse v4 observation projection. `langsmith` adds the
LangSmith run-type and legacy GenAI content projection that its current OTLP
mapping accepts. `opentelemetry` adds no vendor attributes and is appropriate
for generic stores such as VictoriaTraces, Honeycomb, and Grafana Cloud.

The control plane reads these values once during startup. A configuration
change requires a restart. AppConfigure owns whether the process-wide exporter
is enabled and its OTLP destination. The control plane removes standard trace
exporter environment variables before OpenTelemetry starts and again before it
configures the exporter, so they cannot enable export or replace AppConfigure
values. An exporter initialization, network, or receiver failure never changes
a model request result. Traces are best effort and have no database outbox or
delivery retry owner.

One `turn {actor_event.type}` root span covers each persisted TurnStart. The
control plane starts it after the dispatch transaction and ends it after the
normal, noop, or error terminal transaction. The root records the bounded and
sanitized triggering event and final reply. The `langfuse` Provider marks it as
an agent observation. A Background Job root also records its Job identifier and
attempt count. A node-local ETS table holds open roots; its cleanup ends a root
that has no terminal outcome with `error.type=turn_outcome_lost`.

The control plane derives one `user.id` for the complete Turn trace:

- A direct message from a trusted human uses `principal:<principal_uid>`.
- A group Turn, or an event Turn with a source channel, uses
  `channel:<signal_channel_id>`.
- A Turn without a source channel uses `principal:<principal_uid>` when it has
  a trusted human trigger.
- A Turn without a trusted human or a source channel omits `user.id`.

These prefixes keep Principal and channel identifiers in separate namespaces.
The complete value has a limit of 200 Unicode code points. The value is an
attribution fact. It does not change the accountable Agent, authorization,
routing, or session identity.

The control plane writes the root's W3C `traceparent` and derived user
attribution into the existing `request_context_json`. Agent Computer uses the
traceparent as the explicit remote parent for Main Agent tools, `codex.turn`,
and Codex tool spans. It applies the same `user.id`, or the same omission, to
each Worker span. It sends the traceparent and an unpadded base64url carrier for
the user value on each AIGateway HTTP or WebSocket request. This encoding only
keeps the internal header ASCII-safe. The control plane decodes the original
`user.id`, and the carrier does not reach a model Provider. Worker spans use a
lazy OpenTelemetry tracer provider and return protobuf OTLP batches through the
authenticated Runtime Fabric RPC lane.
The Worker RPC route continues to use the Agent Principal, not `user.id`. The
control plane forwards those bytes to its configured receiver, so receiver
credentials never leave the control plane. Export and forwarding are best
effort and cannot change a Turn result.

Within a traced Turn, one `ai_gateway.response` child span covers each public
AIGateway Response. AIGateway accepts the carried Turn user only from an
authenticated Agent request with a valid `traceparent`. A direct request, or
another request that cannot use the carried value, uses
`principal:<authenticated_subject_uid>`. A request with no valid `traceparent`
keeps `ai_gateway.response` as its root. Each provider round is one
`chat {model}` child span. A provider retry before any output stays inside the
same generation, and each credential-pool retry adds one
`ankole.ai_gateway.credential_retry` event with the classified `error.type` and
the planned delay. Tool Search or a program continuation starts another
generation under the same Response span. A provider-native compact call is one
`compact {model}` root generation of its own. A provider terminal ends the
generation before image persistence, stateful commit, or public projection
settles the Response span, so provider completion is not confused with durable
Response completion or ActorEvent delivery.

An enabled trace contains the public request, the prepared request for each
provider round, normalized provider output, model and Provider labels, token
usage with cache-read, cache-write, and reasoning detail buckets, Principal,
and available conversation and ActorEvent identifiers. User attribution does
not change the session identity. The session identity is the stateful
conversation when one exists; otherwise it is
`RequestContext.session_key/2`, which accepts explicit client session, thread,
and conversation identifiers. `prompt_cache_key` stays a cache routing and
credential-affinity input and never becomes a trace session. Spans also carry
the Principal type, the client `originator`,
`user-agent`, and `version` headers, and an `ankole.ai_gateway.caller` label
for internal callers such as compaction. The exported
resource names `service.name`, and adds `service.version` from
`ANKOLE_VERSION` and `deployment.environment.name` from `ANKOLE_ENV` when
those variables are set — the same sources that label logs. The common layer
includes standard `gen_ai.*` attributes and bounded `ankole.ai_gateway.input`
and `ankole.ai_gateway.output` values. A Provider can add only its receiver's
compatibility projection. The common layer removes credentials, headers,
generic caller metadata, encrypted reasoning and tool fields, and `__ankole_*`
control fields. It replaces inline `data:` media with its byte count and omits
an input or output payload that exceeds 1 MiB. Enabling the feature still
sends model content outside Ankole, so the operator must treat the receiver as
a trusted system.

For Langfuse v4, use a base endpoint such as
`https://cloud.langfuse.com/api/public/otel`. Put a Basic `Authorization` value
and `x-langfuse-ingestion-version: 4` in the encrypted header map. The
`langfuse` Provider writes the derived `user.id` as the Langfuse user and keeps
the existing session key as the Langfuse session. It writes
`ANKOLE_VERSION` as `langfuse.release`, and writes the Agent Principal, caller,
and originator facts as filterable trace metadata. Langfuse reads the
environment from the exported resource. This mapping applies only to spans
that the updated processes create. It does not update historical Langfuse
records.

For LangSmith, use the regional base endpoint ending in `/otel`, an `x-api-key`
header, and an optional `Langsmith-Project` header. When a Response belongs to
a conversation, the `langsmith` Provider copies the conversation identifier to
the documented `langsmith.trace.session_id` and also keeps the vendor-neutral
`gen_ai.conversation.id` and `session.id` attributes.

Unlike optional traces, these structured logs do not contain prompts, tool
arguments, tool results, provider messages, provider response bodies, image
bytes, or credentials.
Stateful socket-open, provider terminal, and stream transport failures persist
safe classification fields and a bounded provider `error.message` when it is
available. Public failure frames, stored Responses, and response retrieval use
that message for the authenticated caller. They never include the remaining
provider response body or metadata. A stable fallback message remains when the
provider does not supply one.

The HTTP edge preserves upstream 4xx responses, maps upstream and transport
failures to 502, and maps native upstream timeouts to 504. It does not report a
provider transport failure as a 422 request error.

## Split Work between Elixir and Rust

Elixir chooses the provider, model, eligible endpoints, and headers. It
prepares the provider request and removes Ankole-only state fields before
sending it.

Elixir also owns the complete public stream lifecycle. One `ResponseStream`
state machine applies the absolute deadline, task monitors, retry boundary,
item projection, terminal validation, stateful commit, and cancellation for
streaming and collected calls.

The Rust kernel sends the `UniversalAIRequest` and converts supported HTTP, SSE,
and WebSocket responses to one event format. It owns native stream and program
run identities, resource limits, and cancellation handles, but it does not
advance the public Response lifecycle.

The public stream accepts `response.completed`, `response.failed`, and
`response.incomplete` as terminal types. Provider `error` events are diagnostic
events and do not enter the public Response lifecycle. `ResponseStream`
consumes them and waits for one canonical terminal event. It keeps the first
bounded Provider error code, type, status, and message for that Provider round.
A later transport failure keeps its canonical code and retry decision, and adds
those Provider fields for the authenticated caller and durable error. A
structured, non-retryable Provider validation error is authoritative:
AIGateway reports one `invalid_prompt` terminal instead of a retryable
disconnect. One owner selects this public code for every failure path, so the
same Provider rejection reads the same whether it arrives while the request
opens or mid-stream. Logs include the Provider code and type but omit the
Provider message. If a stream closes without a terminal event, AIGateway produces one
`response.failed` event.
Request-validation errors and socket command errors stay outside this Provider
stream rule. For retry decisions, a boolean
`response.failed.error.retryable` value is authoritative. When this field is
absent, a caller infers retryability from compatible status, code, and message
signals.

The public stream rejects a provider completion that contains an incomplete
client tool call. If a terminal output omits its item identity, AIGateway
restores the streamed item at the same provider output index only when the
terminal item is a field-for-field subset of that streamed item.

OpenAI Responses mode can use an upstream WebSocket transport. OpenAI and
OpenAI-compatible provider rows default `upstream_transport` to `sse`. A row
can select `websocket` for a streaming Responses request. Chat Completions and
non-streaming requests do not use the upstream WebSocket. Other providers adapt
their native protocols to the same public Response contract.

The kernel resolves one proxy route for HTTP and WebSocket requests.
`NO_PROXY` bypasses all proxies. For other targets, an explicit
`transport.proxy` wins. Otherwise, secure requests use `HTTPS_PROXY`, then
`ALL_PROXY`, then `HTTP_PROXY`; plain requests use `HTTP_PROXY`, then
`ALL_PROXY`. Lowercase environment-variable names are accepted. HTTP proxy
URLs and SOCKS5 proxy URLs work for WebSocket requests. If no proxy applies,
the kernel connects directly. Provider code does not contain local proxy
product names or ports.

The OpenAI Chat Completions adapter lowers a custom tool to a function with one
required `input` string. It restores the provider function call as a
`custom_tool_call` before the event enters the public Response contract. It
also translates stored custom calls and outputs back to Chat messages during
replay.

The OpenAI Responses adapter applies the same emulation when the connection
does not declare `supports_openai_tools`. The upstream space then carries only
function tools: custom tool declarations, replayed custom calls and outputs,
and a custom `tool_choice` all go out in the lowered function form, and a
grammar definition survives as prose in the `input` description. The provider's
function call comes back as a `custom_tool_call`, and its input arrives at
`done` because a streamed JSON-escaped argument string cannot be unescaped
incrementally. The caller keeps the official Responses contract on both
directions; the marker that selects the emulation never reaches the upstream
body.

For Chat providers that return `reasoning_details`, the adapter concatenates
the streamed detail objects in order and emits one Responses `reasoning` item.
Its AIGateway-owned `encrypted_content` carries the provider state without
exposing a new public item type. A continuation decodes that item and restores
the exact detail sequence on the assistant tool-call message. The envelope is
bound to the upstream provider type and model ID. Two provider rows of the same
type can share it when they use the same model ID; a provider-row ID is not part
of the scope. A missing, corrupt, old, or mismatched envelope discards only the
private reasoning state and keeps the visible assistant message and tool
history. It never sends foreign reasoning to the next provider. An explicit public
`reasoning.effort` value overrides the route's `reasoningEffort` default.
If reasoning has no assistant content or tool call, the adapter discards it
during replay. It cannot attach that state to a valid Chat message, and some
Chat providers reject an assistant message with no content or tool call.

For Anthropic Messages, the adapter keeps the native `thinking` and
`redacted_thinking` blocks with their signatures, and emits one Responses
`reasoning` item whose `encrypted_content` is a reversible AIGateway transport
value. That envelope obeys the same rule as the Chat one: it is bound to the
upstream provider type and model ID, and a missing, corrupt, old, or mismatched
envelope discards only the private reasoning state. Claude verifies a thinking
signature against the model that produced it, so replaying one to another model
is never correct.

A continuation rebuilds one Anthropic assistant turn from the several Responses
items that describe it. It merges each run of assistant items into one message,
puts the decoded thinking blocks first, and converts each stored function call to
a `tool_use` block. Visible text and tool calls come from the public items, so a
turn whose envelope was dropped still replays as a valid tool-calling turn
without private reasoning.

## Preserve Encrypted Tool Fields at Their Owner

A tool can set `encrypted: true` on a direct string parameter. Native OpenAI
Responses owns this marker: it accepts the declared schema and reports the
parameters it applied through `encrypted_function_args`. AIGateway forwards that
schema unchanged and leaves those arguments to the provider, because emulating a
capability the provider already has would replace the real contract with a
different one.

Every Responses wire keeps the marker, whoever calls. The marker is the
caller's own declaration that a Provider owns those fields, and this wire can
carry that declaration unchanged, so AIGateway does not decide for the caller.
Nothing in the marker or its value says whether the upstream understands it: a
client declares it once for a whole tool set, and the first request must be
built before any value exists. What is known is the failure that was observed:
a Codex-native upstream validates the declaration against the tool schema it
already knows, and removing the marker makes that comparison fail. This rule
decides only who owns the marker and the arguments; it does not move tool
execution, which stays where the provider-and-client decision above puts it.

A wire that cannot express the marker uses an adapter that removes it and puts
an AIGateway opaque value in the public contract instead. That is what the
emulation is for: a caller's declaration keeps working against a Provider whose
protocol has no such field. The adapter decodes that
value in replayed function calls and Agent messages, so the provider receives
its normal schema and plain parameter values. The AIGateway value is
self-describing through its versioned prefix and does not need the tool
definitions during replay.

The marker's shape is a Worker-facing contract on every route, so validation is
independent of removal. A marker that is not a boolean, or that sits anywhere
other than a direct string property of an object schema, is rejected before
dispatch even on a route that keeps it.

A marker-keeping route's input can also carry provider-owned
`encrypted_content` parts, for example in a Codex Agent message or a function
call output. The versioned prefix is the ownership boundary: AIGateway keeps a
non-AIGateway-prefixed part unchanged there. An adapter route rejects it
because its provider cannot replay the provider state. An AIGateway-prefixed
part always uses the tool-field decode rule and fails closed when its payload
is corrupt.

Readers of stored trajectory outside the provider path, such as the Console
Turn projection and the Job trajectory message, reveal stored opaque values
through `Ankole.AIGateway.OpaqueContent`. The Worker resume projection keeps
the stored form, because a resumed thread must restore what the Worker stored.

On an emulating route, after the provider adapter creates public Response events,
AIGateway encodes each marked parameter as a versioned Base64URL value. It
buffers the complete function arguments before it emits a marked value. An
incomplete or invalid value fails closed and does not enter the public stream or
stored Response.

This encoding does not provide cryptographic secrecy. Provider-owned
`encrypted_content`, including reasoning state, is a separate protocol field
and does not use this rule.

## Rules

- External provider credentials never enter Agent Computer memory.
- The Provider owns the upstream identifiers, and AIGateway owns the downstream ones.
- A Provider item returns to that Provider with the identifier that Provider gave it.
- AIGateway keeps the identifier map for as long as the identifier can come back.
- AIGateway resolves a continuation token by lookup, never from its shape.
- A stored message records the Provider that issued it.
- A Provider change removes sealed content and keeps every structure that pairs.
- A stateful Response belongs to one Principal and one conversation.
- An implicit continuation starts only from the expected last visible Response.
- Only an explicit continuation can select an earlier Response and create a branch.
- One WebSocket has at most one active Response stream.
- AIGateway commits the final state before it sends a terminal public frame.
- One Responses item registry owns call/output pairing and safe history cuts.
- A program child call runs only when its frozen tool contract permits it.
- Exhausting `max_tool_calls` never invents an incomplete terminal Response.
- A completed Response does not complete an ActorEvent.
- A compaction plan cannot change history before the run starts.
- Unmatched tool results never enter provider history.
- An orphaned generating row becomes a retryable error.
