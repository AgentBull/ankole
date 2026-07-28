# AIGateway

The control plane uses AIGateway for every model request. AIGateway stores model
provider settings, selects a model, prepares requests, and records Responses.
It also decides when one model request has ended.

AIGateway does not run the Agent's model loop and does not complete Actor work.
Agent Computer runs the loop. SignalsGateway completes the ActorEvent and sends
the final reply to the external platform.

## What Runs in Each Process

The Elixir control plane stores provider credentials and prepares requests. The
Rust kernel sends those requests and handles their streaming protocols.

Workers receive an Agent-scoped AIGateway token.
They never receive external AI provider credentials.

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

The requested capability helps select the model. The same short model name can
point to different providers for different kinds of work.

Agent model profiles are:

- `primary`
- `light`
- `heavy`
- `coding`
- `vision_fallback`
- `embedding`
- `rerank`
- `web_search`
- `web_fetch`
- `image_generate`

The runtime requires `primary`, `light`, and `heavy`. Other capabilities use
defaults such as `embedding.default` and `web_fetch.default`.

The Background Agent Jobs profile selects one of two Codex runtimes. Its
persisted key and API name remain `coding` until that stored contract is
migrated. It can select an AIGateway provider and model, or it can select a
named ChatGPT subscription account. A subscription profile also contains the
Codex model, the model reasoning effort, and Fast Mode. Fast Mode is off by
default. When `coding` is absent, the existing `heavy` profile is its fallback.
A Job cannot be created when neither profile is configured.

A caller can select `provider_id/raw-model-id` directly. This skips the Agent
profile but still requires an active provider.

## Bind a Codex Job to Its Model Snapshot

The control plane resolves the effective `coding` profile when it creates a
Job. An AIGateway Job stores the real Codex model name, the exact
`provider_id/raw-model-id` selector, all provider options, and the optional
context length. It also stores the provider's parallel-tool-call capability. A
retry uses this snapshot. A new or respawned Job resolves the current profile
again.

Agent Computer puts the real model name in the Job's Codex project configuration
and selects the AIGateway provider in the Agent Codex Home. It sends the frozen
selector, provider options, and parallel-tool-call capability in the
`x-ankole-aigateway-model-binding` provider header. AIGateway replaces the
Codex-facing model name with the selector before provider resolution and uses
the stored provider options as request defaults. It sets `parallel_tool_calls`
from the stored provider capability. An explicit Codex Responses Lite marker in
the HTTP header or WebSocket client metadata keeps this value false. The
`coding` profile name never enters Codex as a model name.

An official-subscription Job does not use this binding. Agent Computer loads its
stored model settings and native `auth.json` credentials instead.

## Describe Each Provider in Code

Provider modules use `Ankole.AIGateway.ProviderDSL`.
Each module declares its identifier, settings, default endpoint, transport options, and supported capabilities.

Each capability selects an upstream protocol, a Rust API resolver, and an Elixir
function that creates a `UniversalAIRequest`.

Each language-model capability can declare `supports_parallel_tool_calls`. It
defaults to false. OpenAI, OpenRouter, Google AI Studio OpenAI, Azure OpenAI,
and Claude declare it true. The generic `openai_compatible` provider keeps the
default because its upstream is unknown.

Built-in language-model providers are:

- `openai`
- `openai_compatible`
- `openrouter`
- `google_ai_studio_openai`
- `claude`
- `azure_openai`

Built-in embedding providers are:

- `openrouter`
- `google_ai_studio_openai`
- `jina`

Built-in rerank providers are:

- `openrouter`
- `jina`

Built-in web-search providers are:

- `parallel`
- `bright_data_serp`
- `jina_search`
- `agentbull_cloud`

Built-in web-fetch providers are:

- `parallel`
- `jina_reader`

`openrouter` provides image generation.

Trusted Plugins can add providers through `ai_gateway.provider`. A Plugin
cannot replace AIGateway storage, authorization, profiles, or secret handling.

## Configure Provider Instances

`ai_gateway_providers` stores operator-configured provider instances.

Each row contains:

- `provider_id`
- `provider_kind`
- optional `base_url`
- encrypted provider options
- plain connection options
- optional disable time

`provider_id` uses a lowercase slug. `provider_kind` uses lowercase snake case.

The database does not use an enum for provider kinds. The application checks
each value against built-in and active Plugin definitions.

Provider definitions mark which settings contain secrets. The Console and API
never return those values as plaintext.

AIGateway decrypts secrets only while it prepares a request or checks a
connection.

Deleting a provider sets `disabled_at`. AIGateway refuses the operation while
an active model profile still uses that provider.

Connection settings can select HTTP versions, compression, and a proxy. The
Rust client tries the selected transport options.

## Runtime API

All runtime routes use `/api/v1/ai-gateway`.

The current routes are:

- `GET /models`
- `GET /web_tools`
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

HTTP accepts `store=false`.
It rejects `store=true`, `conversation`, and `previous_response_id`.

Stateless WebSocket calls also avoid PostgreSQL. One connection can remember 32
completed Responses for local continuation.

Local continuation adds remembered input and output to the next request. It
cannot retrieve a Response from PostgreSQL.

Stateless Response identifiers use the `tmp_resp_` prefix.
The retrieve endpoint does not return those identifiers.

## Store a Response and Continue It Later

Stateful execution requires WebSocket `response.create` with `store=true`.

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

## What AIGateway Stores

`ai_gateway_conversations` stores the Principal, conversation key, end time, and metadata.

Only one active row can use the same `(subject_uid, conversation_key)`.
A caller can create a new active row under the same key after the conversation ends.

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

## Record Tool Results before the Next Model Call

The Worker can send `response.tool_results.record` before the next model call.
The command requires a completed `previous_response_id` and at least one function-call output.

AIGateway matches each result to an executable function call on the anchor.
Valid results become one completed tool-result row.

The journal has a deterministic idempotency key.
Retrying the same record operation returns the existing row.

Unmatched results enter an error row and never reach provider history.

Implicit continuation can detect an interrupted function call that has no stored
result. It adds an interrupted output before replaying the current input.

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

`ai_gateway_compaction_artifacts` stores each compaction result. Version 2
contains one summary object and a list of output items.

A checkpoint message contains exactly one `compaction_artifact` reference.
The checkpoint and artifact use the same UUID.

When AIGateway builds model history, it replaces the checkpoint with that
output. It also keeps selected original user facts.

The compaction summarizer keeps function-call pairing with one-call `call_N`
aliases. Persisted provider call IDs do not enter its prompt.

Internal history traversal supports 10,000 rows.
The public chain API returns at most 500 rows.

### Automatic Overflow

Each stored provider usage value is a cumulative snapshot of the conversation at
that Response, not an amount to add to earlier Responses. Automatic decisions
read the newest snapshot in the visible history.

When the context exceeds its threshold and compaction has no candidate, a
request with `truncation=auto` keeps the last compaction checkpoint and the
configured stable tail, then expands the tail backward until the function calls
and outputs in both history and the current input form a valid boundary. The
checkpoint stays because it is the only remaining record of the conversation
before it. A suffix size cannot be derived from cumulative snapshots, so this
path reports no post-truncation token estimate and leaves the measurement to the
provider. When no valid boundary exists, the request returns `context_overflow`.

## Store Vision Files and Generated Images

`ai_gateway_artifacts` stores uploaded vision files and generated images.

Uploaded files require `purpose=vision`.
Generated images can link to the message that produced them.

The maximum image payload is 50 MiB.
Stateless generated images expire after 30 days.
Generated images linked to messages in PostgreSQL do not use that stateless
expiry.

The image-generation hosted tool resolves the `image_generate` model profile.
OpenRouter is the current built-in provider for this capability.
The endpoint catalog removes endpoints that cannot satisfy the request. All
remaining endpoints stay eligible. OpenRouter owns routing and fallback
between these endpoints.

The hosted tool can run for 30 minutes.
The prepared streaming limits allow 128 MiB for the generated upstream response.
An upstream failure keeps its provider HTTP status in safe public error details.
The provider body and provider message stay private. This status lets the
Worker classify a safe retry without copying provider routing into Ankole.

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

These logs do not contain prompts, tool arguments, tool results, provider
messages, provider response bodies, image bytes, or credentials.
Stateful socket-open, provider terminal, and stream transport failures persist
only safe classification fields. Public failure frames and stored Responses do
not contain provider messages or provider response bodies. Each public or
stored error keeps a stable code and a fixed safe message. Response retrieval
also projects legacy error metadata through this safe shape.

The HTTP edge preserves upstream 4xx responses, maps upstream and transport
failures to 502, and maps native upstream timeouts to 504. It does not report a
provider transport failure as a 422 request error.

## Split Work between Elixir and Rust

Elixir chooses the provider, model, eligible endpoints, and headers. It
prepares the provider request and removes Ankole-only state fields before
sending it.

The Rust kernel sends the `UniversalAIRequest` and converts supported HTTP, SSE,
and WebSocket responses to one event format.

The public stream accepts `response.completed`, `response.failed`, and `response.incomplete` as terminal types.
It rejects a provider completion that contains an incomplete function call.

OpenAI Responses mode can use an upstream WebSocket transport.
Other providers adapt their native protocols to the same public Response
contract.

## Keep Encrypted Tool Fields inside AIGateway

A tool can set `encrypted: true` on a direct string parameter. This marker is
part of the Worker-facing Responses contract. It is not a provider capability.

The Rust API resolver removes the marker before it builds a provider request.
It decodes AIGateway opaque values in replayed function calls and Agent
messages. The values are self-describing through their versioned prefix, so
this decode does not need the tool definitions; a request that replays history
without tools, such as a Codex local compaction request, still reaches the
provider with plain parameter values. A quoted prefix inside a longer plain
value stays verbatim, and a plaintext value of a marked field passes through.
The provider receives a normal schema and plain parameter values.

Readers of stored trajectory outside the provider path, such as the Console
Turn projection and the Job trajectory message, reveal stored opaque values
through `Ankole.AIGateway.OpaqueContent`. The Worker resume projection keeps
the stored form, because a resumed thread must restore what the Worker stored.

After the provider adapter creates public Response events, AIGateway encodes
each marked parameter as a versioned Base64URL value. It buffers the complete
function arguments before it emits a marked value. An incomplete or invalid
value fails closed and does not enter the public stream or stored Response.

This encoding does not provide cryptographic secrecy. Provider reasoning
`encrypted_content` is a separate protocol field and does not use this rule.

## Rules

- External provider credentials never enter Agent Computer memory.
- A stateful Response belongs to one Principal and one conversation.
- An implicit continuation starts only from the expected last visible Response.
- Only an explicit continuation can select an earlier Response and create a branch.
- One WebSocket has at most one active Response stream.
- AIGateway commits the final state before it sends a terminal public frame.
- A completed Response does not complete an ActorEvent.
- A compaction plan cannot change history before the run starts.
- Unmatched tool results never enter provider history.
- An orphaned generating row becomes a retryable error.
