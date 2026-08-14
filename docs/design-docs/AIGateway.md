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
`vision_fallback`, `embedding`, `rerank`, `web_search`, `web_fetch`, and
`image_generate`. A caller can also select `provider_id/raw-model-id`
directly. Every profile and direct selector points to one provider row. Neither
form selects a member of its credential pool.

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
Codex 0.147 uses that name to enable its standalone remote-compaction path. The
provider ID remains `ankole_aigateway`. Agent Computer sends the frozen binding
in the `x-ankole-aigateway-model-binding` header. AIGateway applies this binding
before provider resolution. The binding replaces a conflicting Codex model,
provider option, reasoning effort, or parallel-tool-call choice. It also removes
the Codex-only `internal_chat_message_metadata_passthrough` and
`encrypted_function_args` fields before provider dispatch. Responses Lite stays
serial. AIGateway model cards disable Responses Lite because Codex 0.147 omits
configured hosted web search from that private carrier. Standard Responses
keeps the native tool declaration. Thus Codex receives the real model and effort
that it needs for local execution, but AIGateway remains the authority for the
upstream request. The runner removes `model_catalog_json` from the Job project
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

The pool has one row-level strategy and an ordered list of entries. Each entry
contains `id`, `label`, `source`, `priority`, optional `disabled_at`, and the
encrypted fields declared for that provider kind. A single credential is a
pool with one entry. There is no non-pool execution path.

The four strategies are:

- `fill_first` selects the first usable entry by priority.
- `round_robin` moves selection through the usable entries.
- `least_used` selects the entry with the smallest process-local request count.
- `random` selects one usable entry at random.

A stateful request uses its thread or cache key as an affinity key. Affinity
wins over the configured strategy while that entry is usable. This keeps
account-scoped provider caches stable.

Runtime health is process-local and has three states. `ok` entries can be
selected. `exhausted` entries stay out of selection until their recovery time.
`dead` entries stay out until an operator replaces or reauthenticates them.
Disabled entries also stay out. PostgreSQL stores the credential facts, but it
does not store these rebuildable health facts.

An upstream reset header sets the recovery time when it is available. The
fallback is five minutes for HTTP 401 and one hour for HTTP 429. A process
restart can cause one additional probe.

The selected credential ID stays in the private request context until success
or failure. A failure that has no credential attribution does not change any
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
When upstream compaction is enabled, a separate compact operation can use the
account-scoped Codex `/responses/compact` endpoint.

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
- `POST /responses/compact`
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

When the pre-compaction Brain reminder is due, AIGateway adds it to the current
input before the start transaction. This also applies to an empty continuation.
The stored Response keeps the reminder marker, so later history detects it and
does not add the reminder again.

The same transaction rejects another Response that is still generating. The
WebSocket returns `response_in_progress` with status 409.

`previous_response_id` is the explicit way to branch. It links the new Response
to the completed Response selected by the caller.

AIGateway plans compaction before it tries to start the run. One transaction
then inserts both the checkpoint and the generating Response. If another run
wins the race, compaction does not change history.

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
round. One descriptor keeps the public name and namespace, provider alias,
input and output schemas, codec, deferred-loading state, and allowed callers.
It rejects ambiguous provider aliases and incompatible duplicate tools. It also
creates one fingerprint from the complete executable snapshot. A later Tool
Search result can repeat a known tool only when its descriptor is equal, and a
program can resume only against the same fingerprint.

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

A settled Tool Search call and output remain readable provider history when a
later request no longer declares Tool Search or the loaded tool. The stored
output carries the historical tool descriptor, so AIGateway can replay the pair
and its completed calls without adding the removed tool to the current provider
tool set or searchable catalog. An unsettled server search still requires the
current declaration. A client-loaded tool stays callable only in the user turn
that contains its search output. A later user turn must load it again from the
client's current catalog. A server-loaded tool stays callable only while its
provider identity remains in AIGateway's current deferred catalog. Equal
client-loaded contracts can recur in later settled outputs and coalesce to one
provider tool. Client and server outputs never establish each other's current
loading state. A conflicting contract for the same public identity is invalid.

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

The synthesized program tool lists only the provider aliases of bindings that
also have direct declarations. Their schemas already exist in the provider tool
array. It embeds the full contract only for programmatic-only bindings, because
the model has no other way to receive those schemas.

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
bindings; each provider-hosted tool keeps its provider-owned contract.

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
removes every built-in tool before the first provider call. A positive budget
admits calls in response order, ignores later attempts, and removes built-ins
and stale `tool_choice` values from later rounds. Function and custom calls are
outside this built-in-tool budget. Native Responses providers receive the
positive limit directly; AIGateway enforces the same rule for locally owned
Tool Search, program, hosted-image, and adapted-provider effects. Budget
exhaustion does not synthesize `response.incomplete`; the real provider or loop
terminal remains authoritative.

AIGateway rejects a positive budget when one request mixes a local Tool Search
or program owner with a provider-owned built-in tool. HTTP returns 400, and
WebSocket returns the equivalent `unsupported_value` error for
`max_tool_calls`. No single owner can enforce the call order for that
combination. A `tool_choice: "none"` request is the exception because it
prevents every tool effect, so the positive limit cannot cross an
execution-owner boundary.

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
storage fails, AIGateway sends `response.failed` and cancels the provider stream.

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

Manual compaction uses `POST /responses/compact`.
Stateful compaction requires `store=true` when it uses a conversation or Response anchor.

The `ai_gateway.compaction` AppConfigure value has these fields:

- `threshold` defaults to `0.50` and controls the Main Agent automatic trigger.
- `max_threshold_tokens` defaults to `100000` and caps that trigger.
- `tail_rows` defaults to `2` and controls only local retention.
- `user_message_budget_tokens` defaults to `20000` and controls only local
  user-message retention.
- `prefer_upstream` defaults to `false`. When it is `true`, Main Agent automatic
  compaction, Main Agent `/compress`, and standalone `/responses/compact` first
  try the current Provider's standalone compact operation. It also enables
  Codex v2 compaction for a newly admitted Background Job only when that Job's
  frozen Provider kind is `chatgpt_subscription`.

The standalone upstream path applies only to an effective Responses wire for
`openai`, `openai_compatible`, `azure_openai`, or `chatgpt_subscription`. A Chat
Completions wire uses local compaction without a probe. AIGateway sends a real
`POST /responses/compact` request, so that request is both the capability probe
and the requested operation. Main Agent compaction always uses this standalone
path. Background Jobs also use it unless their frozen configuration enables the
ChatGPT Subscription v2 path.

The v2 path is a normal Responses request whose last input item is
`compaction_trigger`. AIGateway forwards the request and its provider-native
`compaction` output without converting it to a standalone request. It enables
this Codex mode only for `chatgpt_subscription`, whose protocol contract is
known. OpenAI, OpenAI-compatible, and Azure OpenAI Jobs keep
`remote_compaction_v2=false` even if a concrete endpoint might accept the
trigger; their support is not inferred from an OpenAI-compatible surface.

AIGateway keeps one negative, node-local ETS cache for the standalone path. Its
key contains the Provider row UUID, Provider row update time, and resolved
model. An HTTP 404 or 405 result stores `unsupported` for one hour. A Provider
can also map a stable, structured unsupported error to the same result. A cache
hit uses local compaction without another request. Authentication errors, rate
limits, timeouts, conflicts, 5xx responses, transport failures, malformed
responses, and empty output use local compaction for that attempt but do not
populate the cache. A process restart, Provider update, or model change causes
a new probe. Concurrent cold probes can each receive an unsupported response.
The cache does not apply to v2: ChatGPT Subscription support is a static Provider
contract, and a v2 failure remains a normal turn failure after Codex retries it.

`prefer_upstream` is a rollout guard. It can be removed and upstream-first can
become fixed after the AIGateway and Codex paths are deployed, the real OpenAI
compact-and-replay test passes, all four provider families have protocol tests,
and no open incident requires a global return to local compaction. Local
fallback and its opaque-history limit remain after that removal.

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

The standalone endpoint returns version 3 output without an Ankole handle. The
caller must continue with a compatible Responses provider. If standalone input
already contains provider-native compaction state and upstream compaction is
disabled or fails, AIGateway returns HTTP 502 with
`opaque_compaction_fallback_unavailable`. It cannot create a correct local
summary from provider ciphertext.

The kernel preserves provider-native compaction items on the Responses and
Responses Compact wires. It rejects those items on other wires with
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
and current input together. An over-budget result cannot create an artifact and
uses the normal overflow policy.

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
no post-truncation token estimate and leaves the measurement to the provider.
When no valid boundary exists, the request returns `context_overflow`.

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
AIGateway never adds an image tool that the caller did not declare.

The hosted tool can run for 30 minutes.
The prepared streaming limits allow 128 MiB for the generated upstream response.
If the main provider uses a Responses WebSocket, each hosted fallback model
round uses that WebSocket transport. Other streaming providers use one
collected non-streaming main-model request for each round.
Image persistence observes normalized image events from both execution paths.
It stores the final image and accounts for native image usage. A hosted image
attempt rotates only the image provider pool, while a main model attempt
rotates only the main provider pool. Usage stays attributed to the credential
that ran each attempt. An upstream failure keeps its provider HTTP status in
safe public error details. When the provider supplies `error.message`, the
authenticated caller receives a bounded copy. The provider body and metadata
stay private.

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

The control plane writes the root's W3C `traceparent` into the existing
`request_context_json`. Agent Computer uses it as the explicit remote parent
for Main Agent tools, `codex.turn`, and Codex tool spans. It also sends the same
header on each AIGateway HTTP or WebSocket request. Worker spans use a lazy
OpenTelemetry tracer provider and return protobuf OTLP batches through the
authenticated Runtime Fabric RPC lane. The control plane forwards those bytes
to its configured receiver, so receiver credentials never leave the control
plane. Export and forwarding are best effort and cannot change a Turn result.

Within a traced Turn, one `ai_gateway.response` child span covers each public
AIGateway Response. A direct AIGateway request with no valid `traceparent`
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
and available conversation and ActorEvent identifiers. The session identity is
the stateful conversation when one exists; otherwise it is
`RequestContext.session_key/2`, which accepts explicit client session, thread,
and conversation identifiers. `prompt_cache_key` stays a cache routing and
credential-affinity input and never becomes a trace session. Spans also carry
the Principal type, the client `originator`,
`user-agent`, and `version` headers, and an `ankole.ai_gateway.caller` label
for internal callers such as Brain dreaming and compaction. The exported
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
`langfuse` Provider writes the Principal as the Langfuse user, the session key
as the Langfuse session, `ANKOLE_VERSION` as `langfuse.release`, and the
Principal, caller, and originator facts as filterable trace metadata. Langfuse
reads the environment from the exported resource.

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

The public stream accepts `response.completed`, `response.failed`, and `response.incomplete` as terminal types.
It rejects a provider completion that contains an incomplete client tool call.
If a terminal output omits its item identity, AIGateway restores the streamed
item at the same provider output index only when the terminal item is a
field-for-field subset of that streamed item.

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

No other provider has the marker, so their adapters remove it and use an
AIGateway opaque value in the public contract instead. They decode that value in
replayed function calls and Agent messages, so the provider receives its normal
schema and plain parameter values. The AIGateway value is self-describing through
its versioned prefix and does not need the tool definitions during replay.

The marker's shape is a Worker-facing contract on every route, so validation is
independent of removal. A marker that is not a boolean, or that sits anywhere
other than a direct string property of an object schema, is rejected before
dispatch even on the native route that keeps it.

Native OpenAI Responses input can also carry provider-owned
`encrypted_content` parts, for example in a Codex Agent message or a function
call output. The versioned prefix is the ownership boundary: AIGateway keeps a
non-AIGateway-prefixed part unchanged on the native route. Other provider
adapters reject it because they cannot replay the provider state. An
AIGateway-prefixed part always uses the tool-field decode rule and fails
closed when its payload is corrupt.

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
