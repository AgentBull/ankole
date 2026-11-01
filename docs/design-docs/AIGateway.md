# AIGateway

Provider pools and credentials belong to the site, whereas Conversations,
messages, and files belong to the authenticated Principal's tenant. Every HTTP
and WebSocket entry point binds that tenant context before touching tenant
storage. When a tenant is suspended, AIGateway rejects OIDC Human requests while
keeping Agent access open so already-admitted work can finish.

The control plane routes every model request through AIGateway. AIGateway stores
provider rows and encrypted credentials, selects a model and one pool
credential, prepares the upstream request, handles provider-level retries,
determines when a single model request ends, and records durable Responses.

Caller `metadata` stays local to the Ankole Response: at the native request
boundary, AIGateway strips `metadata` after merging provider options and before
passing the request to any provider resolver. Similarly, `Sessions.Driver`
passes `model_profile` through the local `response_metadata` option rather than
placing it in the request body.

AIGateway neither drives the multi-step Agent loop nor completes user inputs on
its own. Instead, `Sessions.Driver` runs ordinary and Workflow loops in the
control plane, Codex runs Background Agent Job turns on the Worker, `Sessions`
completes the triggering input, and `Conversations.Delivery` delivers the final
reply to the external chat platform.

## What Runs in Each Process

Responsibility splits cleanly across process boundaries:

- **Elixir control plane**: owns provider configuration, credential encryption,
  credential selection, OAuth token refresh, provider retries, and durable
  Response state in PostgreSQL.
- **Rust kernel**: executes one prepared HTTP, SSE, or WebSocket attempt and
  normalizes upstream provider events.
- **Agent Computer Workers**: receive only an Agent-scoped AIGateway bearer
  token—never external provider API keys, ChatGPT refresh tokens, or generated
  Codex auth files.

Every persisted AIGateway record belongs to a single Principal via
`subject_uid`, and AIGateway stores caller `metadata` opaquely without
interpreting it. Subject-scoped history queries can pass `include_ended: true`
to read retained model state after a conversation has ended, whereas admitting a
new stateful request requires an active conversation.

Finally, a completed Response marks the end of a single model request—not the
end of an Agent turn.

## Select a Model for Each Kind of Work

AIGateway exposes six capability kinds:

- `llm`
- `embedding`
- `rerank`
- `web_search`
- `web_fetch`
- `image_generate`

`Ankole.AIGateway.ModelProfiles` owns model and capability configuration at
three layers: Site defaults, Pod overrides, and sparse subject overrides. Agents
store overrides in `agents.options`; registered system Principals store them in
AppConfigure under `system:<uid>`. Site, Pod, and system Principals expose
`primary`, `light`, `heavy`, `coding`, `vision_fallback`, `web_search`,
`web_fetch`, `image_generate`, and `rerank`; Agents expose the same slots except
`rerank`. Pod and Site rows live in AppConfigure under
`ai_gateway.model_profiles.<slot>` and `ai_gateway.provider_hosted.<capability>`.
Deleting a row restores inheritance; storing `nil` is invalid because only a
missing row may advance fallback to the next layer.

Resolution first merges each slot across `Agent -> Pod -> Site`,
`system Principal -> Pod -> Site`, or `Pod -> Site` for Human calls, then applies
`coding -> heavy -> primary` and
`light -> primary`. A single effective `primary` therefore serves the basic LLM
paths, while embedding, web fetching, reranking, and other specialized
capabilities require their own configuration. `brain.embedding_model` remains a
Site-only setting because Brain shares one physical vector space. Brain uses the
effective heavy profile for Dreaming and falls back to effective primary when
heavy is absent.

The owner exposes three distinct reads:

- **Overrides** are the sparse values persisted at the current layer.
- **Inherited** values are the next layer's values for the same slot, without
  cross-slot fallback, and identify their source.
- **Effective** values contain the merged result plus `source` and
  `resolved_from_profile`. Model directories, runtime resolution, and both
  Console editors consume this form; the browser never reconstructs fallback.

New Session Turns and first Background Agent Job admission freeze the effective
model and tools for that run. Editing a default affects the next resolution or
stateless gateway request, not an already frozen Turn or Job. `/v1/models` and
the Codex `/models` manifest include inherited and fallback selectors even when
an Agent has no fixed-slot overrides.

Agents and system Principals execute with their own effective three-layer
configuration. Human Principals resolve the Pod's effective configuration, so
control-plane compaction can run without an Agent binding. Brain executes as
`ankole_brain` and reads its effective `light`, `heavy`, `web_fetch`, and `rerank`
slots. This includes reranking during Agent-initiated recall. The `default` and
`rerank.default` capability selectors resolve a system Principal's effective
rerank slot; Agent and Human rerank calls use the Pod slot. Pod Applets execute
as `system`, accept only built-in LLM slots, and do not consult a creator Agent
or its quota. OIDC-bound external requests use their explicit model binding.

Provider-hosted switches inherit from Pod and Site for system Principals;
system overrides accept only the nine fixed slots, with no custom aliases.
Without subject overrides, every effective slot matches the Pod configuration.

Alongside fixed profiles, an Agent can store custom LLM profiles in
`agents.options["ai_agent"]["models"]`. Each custom name matches
`[a-z][a-z0-9_-]{0,63}`, avoids the eight Agent fixed slots, is immutable, and
has a non-empty description. The name `rerank` is a valid custom LLM alias; it
does not collide with the Pod/Site rerank capability, whose default selectors
are `default` and `rerank.default`. OIDC Clients use the same custom-alias
contract and still resolve external Human requests through the Client's model
binding. Custom aliases never configure embedding, rerank, web search, web
fetch, or image generation.

The Console's `/model-profiles` page edits Pod and Site defaults through
`/api/v2/model-profiles`, including rerank and Provider-hosted switches. Agent
routes under `/api/v2/agents/:agent_uid` return overrides, inherited values,
and effective values, and allow every fixed-slot override to be deleted.
The System Principals section lists the code registry and uses
`/api/v2/system-principals/:uid/model-profiles` to read each configuration, PUT
an override at `/:profile`, or DELETE it to restore inheritance. These operations
use the same permissions as Pod defaults and reject unregistered UIDs. All
editors share the provider, model, context-length, and request-option form.
Profile writes and deletions return the complete configuration so the editor
can refresh inherited and fallback fields while preserving unsaved edits.
When configuration queries refresh, fixed-slot editors also update untouched
fields and preserve unsaved slot drafts.
The Pod page uses the Console's selected tenant; Site defaults apply across Pods.
The readiness model step links to Pod defaults when the Pod has no Agent.
Provider deletion checks Agent options and every Site, Pod, and `system:<uid>`
profile row before allowing the operation. Tenant-owned references include the
tenant ID, together with the Agent or system Principal UID when applicable, so
operators can identify the configuration that must change.

The `coding` profile holds `provider_id`, `model`, and request-level
`provider_options`, and `chatgpt_subscription` is an ordinary provider kind.
When coding and heavy are absent, the effective primary handles Job creation;
only a missing value along the whole fallback chain rejects it.

## Bind a Codex Job to Its Model Snapshot

When admitting a Background Agent Job's first execution attempt, the control
plane resolves the Job's logical model profile—defaulting to `coding` when
omitted, or accepting a single custom profile configured on that Agent—and
writes the frozen snapshot into the Job runtime projection in the same
transaction. That snapshot records the logical profile name alongside the
resolved Codex model, the exact `provider_id/raw-model-id` selector, all
provider options, optional context length, and whether the provider supports
parallel tool calls. Subsequent retries of that Job reuse the frozen snapshot,
whereas a newly created or respawned Job resolves the latest profile at its own
first execution admission. The model binding omits the hosted `brain` tool:
Codex Jobs call `recall` and `get_page` over the read-tool bridge on the Worker
so each tool name has a single executor (see
[BackgroundAgentJob.md](BackgroundAgentJob.md#code-mode-tool-registry)).

The snapshot also captures input modalities. If the primary model is text-only,
the snapshot includes a `vision_fallback` target only when that fallback model
accepts images directly. In the Codex model manifest, effective modalities
include image input whenever either the primary model or a usable
`vision_fallback` accepts images, reporting text-only when neither can handle
images.

On the Worker, Agent Computer writes the resolved real model into the Job's
project configuration—never exposing the logical profile name to Codex—and
selects the `ankole_aigateway` Codex provider (whose display `name` is set to
`"OpenAI"` because the pinned Codex runtime gates its remote-compaction protocol
on that provider name, while the provider ID stays `ankole_aigateway`). It also
strips `model_catalog_json` from the Job project configuration so workspace
templates cannot override AIGateway's model cards. On every upstream call, Agent
Computer sends the frozen snapshot in `x-ankole-aigateway-model-binding`. Before
provider resolution, AIGateway enforces that header—overwriting any conflicting
Codex model, provider option, reasoning effort, or parallel-tool-call flag, and
stripping the Codex-internal fields
`internal_chat_message_metadata_passthrough` and `encrypted_function_args`.
AIGateway model cards also disable `Responses Lite` (which stays serial and
drops configured hosted web search in the pinned Codex runtime) so Codex uses
standard Responses with native tool declarations. As a result, Codex sees the
real model and reasoning effort it needs locally while AIGateway stays the sole
authority for upstream requests.

Each AIGateway model card enforces a 10,000-token ceiling on tool output visible
to the model (and states that same limit in the card instructions). Callers can
pass a smaller `max_output_tokens` value to lower output further, but passing a
larger value never raises the 10,000-token tool-output limit; Codex either
filters larger outputs in code before returning them or writes them to files in
the Job workspace.

Image handling follows the frozen modality snapshot on both direct inputs and
Worker tool outputs:

- **Direct image inputs**: AIGateway forwards images directly only when the
  selected model accepts image input. When the selected model is text-only,
  AIGateway sends one stateless request to the frozen `vision_fallback` model
  and replaces all current image parts with a single untrusted text description
  (so the main model never sees raw image bytes); if no usable fallback exists
  or the fallback call fails, AIGateway substitutes an explicit unavailable
  marker instead. Stateful history persists that replacement text so later turns
  never replay unsupported images to a text-only model.
- **Worker `read_file` images**: `read_file` can return a PNG, JPEG, GIF, WebP,
  or BMP file up to `8 MiB` (sized to fit base64-encoded inside a Worker channel
  frame). The control plane transcodes the image through the same Rust kernel
  helper used for inbound chat images, producing a WebP data URL of at most
  `4 MiB` in a user message immediately following the tool output (with a
  caption repeating that output). Before committing the round to stateful
  history, the control plane applies the exact same vision rule—keeping the WebP
  image for vision-capable models, or running the frozen `vision_fallback` (in a
  Driver task, since it performs a model request) or inserting an unavailable
  marker for text-only models. If a round ends early via stop or dead letter,
  history records the raw image unchanged, and any later replay to a text-only
  model replaces it with a removal marker.

Both API-key providers and `chatgpt_subscription` run through this exact same
pipeline; Agent Computer never resolves, stores, refreshes, or writes back
upstream provider credentials.

## Describe Each Provider in Code

Provider modules declare their contract with `Ankole.AIGateway.ProviderDSL`,
specifying a provider identifier, settings, default endpoint, transport options,
and supported capabilities. Each capability binds a Rust API resolver and an
Elixir preparation function, and its capability kind determines the default
upstream wire format: SSE for `language_model`, and a single JSON response body
for all other capabilities (requests that use an alternate transport, such as
OpenAI WebSocket mode, select it when building the upstream request).

Every declared provider setting belongs to one of three scopes:

- `connection` — stored in plaintext on the provider row and shared across all
  pool entries.
- `credential` — encrypted inside each individual pool entry.
- `request` — stored in plaintext on a model profile or passed per request.

A provider declares a `request` setting only when its prepare code writes the
value to an upstream field. Public names stay camelCase, and prepare code moves
each value to the native field name: OpenAI-family providers send
`promptCacheKey`, `promptCacheRetention`, and `contextManagement` as
`prompt_cache_key`, `prompt_cache_retention`, and `context_management`,
OpenRouter sends `textVerbosity` as `verbosity`, and Claude sends `inferenceGeo`
as `inference_geo`. OpenAI Chat Completions rejects the Responses-only options
`reasoningSummary`, `truncation`, and `contextManagement` with
`unsupported_provider_option`. Claude accepts the `reasoningEffort` values
`low`, `medium`, `high`, and `xhigh`, and sends `xhigh` as `max`.

A request carries a reasoning effort only when the packaged `llm_db` model
metadata allows it, because upstreams reject an effort for a model that does
not reason. When neither the model profile nor the request chooses a value, a
model that the metadata marks as reasoning gets `high`, provided that `high`
is one of its listed effort levels. A Claude model qualifies only when the
metadata lists effort levels. A chosen value is rejected with a
`reasoning_effort` error when the metadata marks the model as not reasoning or
does not list the value. A model that the metadata does not describe gets only a
chosen value. OpenRouter, ChatGPT Subscription, and Volcengine Ark own their
model catalogs, so their models get `high` when nothing chooses a value. This
check reads only local metadata and adds no upstream request.

Only `credential` settings may set `encrypted: true`; `ProviderDSL` rejects
`encrypted` in `connection` or `request` scopes at compile/declaration time.
`select` settings restrict values to a closed option list, whereas `string`
settings can list suggested values while still accepting custom strings—for
example, `chatgpt_subscription`, Azure OpenAI, OpenAI, and `openai_compatible`
use an open string setting for `serviceTier`, suggesting `fast` and `flex`,
accepting custom provider tiers, and omitting `service_tier` when blank.

For Azure OpenAI Chat Completions, AIGateway maps `max_output_tokens` (and its
`max_tokens` alias) to `max_completion_tokens` by default, because Azure
deployment names are operator-chosen strings from which Ankole does not infer
model capabilities. When targeting an older Azure model that rejects
`max_completion_tokens`, operators set `maxTokensParameter` to `max_tokens` on
each affected model profile (see Microsoft's notes on
[reasoning model parameters](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/reasoning)
and
[older model compatibility](https://learn.microsoft.com/en-us/azure/foundry-classic/openai/faq#do-all-azure-openai-models-support-max_completion_tokens-with-the-chat-completions-api)).
Internally, the Elixir Azure adapter attaches a private codec marker that the
Rust resolver strips when writing the single chosen token-limit field, letting
an explicit public limit override any conflicting token fields in provider
options or `extra_body`. Non-Azure Chat Completions providers emit `max_tokens`,
and Responses providers emit `max_output_tokens`.

Language-model capabilities can also declare `supports_parallel_tool_calls` and
`supports_native_image_generation` (both `false` by default). When hosted-tool
support depends on how an endpoint is configured rather than on the provider
kind as a whole, the provider row itself declares that capability:

- On every row, `endpoint_kind` determines native hosted tools: connections
  using the Responses wire advertise `web_search`, and also `image_generation`
  when the kind declares `supports_native_image_generation`. Chat Completions
  connections, including an `openai` row set to `chat_completions`, advertise
  neither, because Chat Completions accepts only function and custom tools.
  `TurnPolicy` reads `endpoint_kind` so Main Turns and Background Agent Jobs
  expose identical hosted tools. Across all
  boundaries, Ankole accepts only `image_generation`, `web_search`, and `brain`
  as turn hosted-tool types (`brain` depends solely on the site's
  `brain.enabled` flag because AIGateway executes it locally across every
  provider).
- An `openai_compatible` row also sets `supports_openai_tools` (defaulting to
  `false`). When `false`, AIGateway treats the endpoint as a standard
  function-calling server, emulates custom tools over the Responses wire, and
  never forwards provider-native compaction requests. Operators enable
  `supports_openai_tools: true` only for endpoints that implement the full
  OpenAI Responses tool contract—passing custom tools through verbatim and
  allowing upstream compaction pass-through. First-party OpenAI kinds always
  enable this behavior, and non-Responses provider kinds always disable it.

Trusted Plugins can register additional provider kinds via
`ai_gateway.provider`, without replacing AIGateway's storage, authorization,
model profiles, credential pools, or secret handling.

## Configure Provider Rows and Credential Pools

`ProviderConfigs.Provider` is a site-owned Ash resource inside the
`Ankole.AIGateway.ProviderConfigs` domain (kept separate from
`Ankole.AIGateway` so site-level provider routes and tenant-level Conversation
routes mount on their respective JSON:API routers). Its actions own endpoint
configuration, credential updates, disable/delete guards, re-enablement, and
cooldown writes; callers can never write raw ciphertext directly, and the
resource's row ID is known before sealing credentials.

Internally, `ProviderConfigs.Credentials` implements pure transformations over
encrypted pool values, while `CredentialPool` manages selection strategies,
session affinity, and runtime health. Every read-modify-write locks the
`ai_gateway_providers` row—holding that row lock across automatic OAuth token
refresh callbacks—and API controllers only authorize and project domain results
without choosing persistence paths. Automatic token refreshes preserve the
entry's `health_revision`, whereas explicit credential replacements increment
it, and stale cooldown updates return the current row without writing to
PostgreSQL.

The site JSON:API under `/api/v2/site/ai-gateway/providers` lists, reads,
creates or updates (`PATCH` via `put`), disables or deletes (`DELETE` via
`retire`; deleting a provider sets `disabled_at` first and is rejected while any
active model profile still references that provider), and re-enables
(`POST …/enable`) providers. Its calculated `credential_pool`
(`CredentialPoolView`) and `provider_metadata` fields match
`ProviderConfigs.projection/1` without ever exposing secret values, and errors
format operator messages through `ProviderConfigs.rejection/1`. The same site
API serves the model catalog, provider-kind definitions, credential writes
(returning the safe `Provider` projection), pool-strategy updates, and ChatGPT
sign-in flows (`ChatGPTAuth` runs outside transport transactions, committing
only when storing a completed credential and returning just the current step,
opaque client context, and safe account metadata). In the Console, operators can
view each pool entry's label, source, health, recovery timestamp, request count,
last selection time, and sanitized recent error details, as well as add, edit,
disable, enable, delete, or reauthenticate entries.

Each row in `ai_gateway_providers` stores:

- `provider_id` (lowercase slug)
- `provider_kind` (lowercase `snake_case`, validated against built-in and active
  Plugin definitions)
- optional `base_url`
- plaintext row-level `connection_options`
- one encrypted `credential_pool`
- optional `disabled_at`

A provider row pools credentials for a single `provider_kind` and never fails
over across different provider kinds. As a built-in convenience,
`Ankole.AIGateway.Providers.AgentBullCloud` (`:agentbull_cloud`, defaulting to
`https://cloudapis.agentbull.com`) implements all six `ProviderDSL` capabilities
(`language_model`, `embedding_model`, `rerank_model`, `web_search`, `web_fetch`,
and `image_generate`) so an operator can connect AIGateway to AgentBull Cloud
with a single API key kept inside the control plane (Worker-side MCP skills read
their own credentials separately through `WorkerEnv`). Meanwhile, three shared
building blocks remain pure, stateless functions with no session or billing
state: the wire resolvers in `app/kernel/src/universal_ai_client/`, failure and
rate-limit classification in `Ankole.AIGateway.FailureDiagnostics`, and token
usage normalization.

Every `credential_pool` has a row-level selection strategy and an ordered list
of entries (even a single credential is stored as a one-entry pool; there is no
non-pool code path). Each entry holds `id`, `label`, `source`, `priority`,
optional `disabled_at`, an internal `health_revision` (omitted from Console API
responses), and the encrypted credential fields for that `provider_kind`. Pool
selection supports four strategies:

- `fill_first` — picks the highest-priority usable entry.
- `round_robin` — cycles through usable entries in order.
- `least_used` — picks the usable entry with the lowest process-local request
  count.
- `random` — picks a usable entry uniformly at random.

Stateful requests pass their thread or prompt-cache key as a credential-affinity
key. Each provider maintains an in-memory LRU table of up to 10,000 affinity
mappings: a successful selection marks its key most-recently-used, inserting at
capacity evicts the least-recently-used mapping (without disturbing in-flight
requests), and an existing mapping overrides the pool strategy as long as its
target credential remains usable. Once a mapping is evicted—or when its
credential becomes unusable—the next request falls back to the pool strategy and
updates affinity if it picks a healthy credential.

PostgreSQL persists credential health via `cooldown_until` and its recorded
cause, which survive node restarts:

- `ok` entries are eligible for selection; disabled entries are always skipped.
- `exhausted` entries are skipped until `cooldown_until` passes.
- `dead` entries stay out of rotation until an operator replaces or
  reauthenticates them, or re-enables a disabled provider—operations that bump
  `health_revision` so late failures from an older revision cannot taint its
  replacement.

Selection always filters by persisted health before consulting process-local
affinity. During an attempt, the chosen entry's ID and `health_revision` stay in
the private request context; unattributed errors never mutate pool health, and
credential rotation stops after one full pass across the pool.

Cooldown durations follow upstream headers and status codes:

- AIGateway parses `Retry-After` (delay seconds or HTTP date) and Codex reset
  headers, taking the later timestamp when both are present, and never allowing
  a subsequent error to shorten an active cooldown.
- Without a valid reset header, HTTP `401` sets a five-minute cooldown, and HTTP
  `429` sets a one-second cooldown—unless the error code or type is
  `insufficient_quota`, `usage_limit_reached`, or `billing_hard_limit_reached`,
  which set a one-hour quota cooldown (unrecognized `429` codes use the
  one-second cooldown).
- On HTTP `401`, AIGateway refreshes, marks, or rotates only the attributed
  credential. On HTTP `429`, AIGateway cools down the attributed credential and
  rotates to another usable entry; if no other entry is usable and the `429` is
  a temporary rate limit with a wait of at most four seconds (before the first
  response event), AIGateway sleeps until that recovery time with standard
  backoff and retries once with the same credential. Longer waits or hard quota
  errors return immediately with `retry_at` (note that this single-caller wait
  does not throttle concurrent callers).

`UniversalAIRequest` wraps native transport errors in `ProviderFailure`, and
`FailureDiagnostics` classifies them for credential health, route retry, quota
detection, and sanitized public error projection (shared by main-model attempts,
hosted image calls, and terminal `response.failed` stream events).

Route and upstream endpoint errors—connection, read, and timeout errors plus
HTTP `502`, `503`, and `504`—never alter credential health or rotate
credentials. Instead, if the failure happens before the first normalized
response event (`response.created`, `response.in_progress`, or
`response.failed`), Elixir retries the prepared request once with the same
credential after exponential backoff with `0.9`–`1.1` jitter (the Rust kernel
itself never selects credentials or retries requests). Once the first normalized
event arrives—for example, an overload delivered as `response.failed` inside an
HTTP `200` SSE stream—the retry window closes and AIGateway returns that
Response as-is.

`Stream Ready` indicates only that the Rust kernel received HTTP response
headers or a WebSocket `101` upgrade, not that a provider event arrived. Both
the first-byte timeout and the inter-event idle timeout are 30 minutes, with no
overall wall-clock stream cap: only a complete SSE event, AWS eventstream frame,
or WebSocket text message resets the idle timer (SSE comments, partial frames,
WebSocket Ping/Pong frames, and time spent waiting on downstream read credit do
not). Because a pre-first-event timeout can trigger the single same-credential
route retry, a stream that stalls on both attempts can take slightly over 60
minutes to fail.

If a hosted tool call fails after the main model has already returned output,
AIGateway never replays the main model call: a credential `401` or `429` on the
hosted call updates only the hosted tool's credential, a route/endpoint error
leaves credential health untouched, and AIGateway reports the failure in the
current Response.

When an entire pool has no usable entries, AIGateway returns
`credential_pool_exhausted`—attaching the earliest `retry_at` only if at least
one `exhausted` entry has a known future recovery timestamp, and keeping bounded
upstream `message`, `code`, and `type` fields without leaking credential IDs or
raw bodies. Pool exhaustion on its own never emits `usage_limit_reached`
(temporary rate limits map to `rate_limit_error`), and AIGateway never falls
back to a different provider row. Interactive HTTP callers receive `429`. A
Background Agent Job with a valid future `retry_at` returns to `queued` until
that timestamp (keeping its current execution attempt consumed), whereas a
missing or stale `retry_at`, an empty pool, or a pool containing only disabled
or `dead` entries follows the ordinary Job retry ladder.

## Route OpenRouter Sessions and Prompt Prefixes

On OpenRouter Chat Completions requests, AIGateway keeps `session_id` and
`prompt_cache_key` separate—never copying one into the other—because they serve
distinct purposes: `session_id` pins a conversation to the upstream provider
(and resolved model, when using an OpenRouter router model) that served its
first successful request, whereas `prompt_cache_key` groups requests that can
share a cached prompt prefix.

AIGateway resolves `session_id` in priority order:

1. An explicit `session_id` in the request body.
2. The `x-session-id` header, followed by standard session and thread headers.
3. For a stateful request with none of those inputs, the durable AIGateway
   Conversation UUID (stateless requests with no session input omit
   `session_id` so OpenRouter uses its default fallback routing).

Any caller-supplied `session_id` is forwarded verbatim unless it is empty,
whitespace-only, non-string, or longer than 256 characters, in which case
AIGateway rejects the request.

Profiles and callers can also set the request-scoped `provider` option—the
routing-preference object for OpenRouter (`order`, `only`, `ignore`,
`allow_fallbacks`, `require_parameters`, and its other documented keys)—for
example, to steer a model away from an upstream sub-provider that truncates
output. AIGateway validates only that `provider` is a map and forwards it as
`provider` in the chat request body.

## Use a ChatGPT Subscription Provider

`chatgpt_subscription` uses the OpenAI Responses resolver against the default
base URL `https://chatgpt.com/backend-api/codex`, and a single provider row can
pool multiple ChatGPT accounts:

- **OAuth pool entries** store access, refresh, and ID tokens together with the
  account ID, plan type, email, last refresh timestamp, and optional FedRAMP
  flag.
- **Enterprise access-token entries** store only the access token and account
  ID, with no refresh flow.
- **FedRAMP entries** attach `X-OpenAI-Fedramp: true` on both Responses calls
  and model-catalog calls.

Operators sign in from the Console through a control-plane device-login flow:
the Console holds an opaque login context in memory (nothing is persisted before
completion) and polls a single endpoint at the server-supplied interval until
the control plane exchanges the authorization code and writes the pool entry. If
the upstream device endpoint is unavailable, the Console displays the browser
authorization URL and accepts the pasted `localhost` callback URL instead.

For model discovery, AIGateway queries the account-scoped Codex `/models`
endpoint, filters to models that the subscription account marks as visible and
API-supported, and caches the normalized list for one hour; the Console populates
its model combobox from that cache while keeping manual model entry enabled if
the catalog is unreachable.

During credential selection, the control plane refreshes an OAuth entry under
the provider row lock whenever its access token is within five minutes of expiry
or its last refresh is at least eight days old, so concurrent requests share the
rotated tokens instead of spending the same refresh token twice:

- A permanent refresh error marks the entry `dead`.
- An HTTP `429` during refresh preserves the credential and marks it temporarily
  `exhausted`.
- A transport or endpoint error during refresh leaves credential health
  unchanged and returns that error.
- An upstream HTTP `401` on a model request triggers one forced refresh; a
  second `401` marks either an OAuth or Enterprise entry `dead` and rotates to
  another pool entry.

On the upstream Codex wire, AIGateway always sends `store=false` and requests
`reasoning.encrypted_content` (and forwards `compaction_trigger` to the
account-scoped Codex Responses endpoint when upstream compaction is enabled).
This is strictly an upstream transport rule: main Agent turns still use
AIGateway's local `store=true` persistence and tool-result journals, storing and
replaying encrypted reasoning locally without relying on OpenAI server-side
storage.

When preparing a `chatgpt_subscription` request, AIGateway normalizes the Codex
wire payload:

- Strips downstream-only and unsupported fields—including caller `metadata`,
  `max_output_tokens`, and `truncation`—storing `metadata` locally and applying
  AIGateway's own history limits.
- Wraps plain string `input` into a single-item user message list, because the
  Codex endpoint accepts only item arrays.
- Inserts an empty `instructions` string when omitted by the caller.
- Drops orphaned reasoning item IDs that lack `encrypted_content` for replay,
  and rejects input item IDs longer than 64 characters.
- Strips `parallel_tool_calls` when the request declares no tools.
- Derives `prompt_cache_key`, `Session_id`, and stateful credential affinity
  from the same thread key (adding `Conversation_id` on WebSocket calls).
- Whitelists declared Codex request headers, attaches the required `content-type`,
  `accept`, `beta`, `connection`, `originator`, and `user-agent` headers, and
  injects the selected credential's account ID.
- Streams every upstream call: synchronous callers collect the terminal Response
  over `POST` SSE, while WebSocket callers use upstream WebSocket
  `response.create` (mapping oversized WebSocket frames to HTTP `413`).

On the return path, the Rust kernel strips cookies, `Authorization`, and other
sensitive upstream response headers—surfacing only `Retry-After`, the
`x-codex-*` rate-limit headers, and `cf-mitigated` so the pool can honor exact
reset timestamps and diagnose Cloudflare challenges.

Identity headers follow a clear precedence rule: provider-level identity
settings override inbound Codex headers, which in turn override built-in Codex
CLI defaults (Enterprise access-token requests omit subscription account and
Codex identity headers). For each Codex Job process, Agent Computer sets
`CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_cli_rs` so Codex stamps the Job with
the Codex CLI prefix while keeping `ankole_agent_computer` as the local
`app-server` client name. Across all OpenAI-family providers and transports
(including WebSocket upgrade handshakes), whenever a caller sends its own
originator, user-agent, session, thread, request, window, or Codex turn headers,
AIGateway passes them through so upstreams that tier service by client identity
receive them—unless provider-owned values (such as ChatGPT Subscription session
and account headers) overwrite them.

In addition, Agent Computer attaches the active execution Session as
`Session-Id` on every AIGateway model call. Distinct execution Sessions send
distinct `Session-Id` values even when sharing the same Agent, channel,
instructions, tools, or prompt-cache route, whereas retries or WebSocket
reconnects for the same model call reuse the same `Session-Id`
(`prompt_cache_key` remains an independent input for cache routing and
credential affinity).

Finally, `Responses Lite` retains its compact wire format when talking to
ChatGPT, whereas for other providers AIGateway expands it back into standard
Responses shape before provider preparation. Real Codex clients keep Tool Search
and Programmatic Tool Calling native, while the main Agent uses AIGateway's
local compatibility loop—both exposing the exact same public item and lifecycle
contracts.

## Runtime API

All runtime endpoints mount under `/api/v1/ai-gateway`:

- `GET /models`
- `GET /files`
- `POST /files`
- `GET /files/:file_id`
- `GET /files/:file_id/content`
- `DELETE /files/:file_id`
- `GET /responses` (upgrades to the Responses WebSocket protocol)
- `GET /responses/:response_id`
- `POST /responses` (creates a stateless Response via JSON or SSE)
- `POST /embeddings`
- `POST /rerank`
- `POST /web_search`
- `POST /web_fetch`

## Identify Every Caller

Every runtime request authenticates with either an Agent token or an authorized
OIDC Human token, signed with the installation's `RS256` key and typed as
`at+jwt`:

- **Agent tokens** (`Ankole.AIGateway.Tokens`): carry audience
  `ankole.ai_gateway`, scope `ai_gateway`, `tenant_id`, the Agent uid in `sub`,
  and a default 30-day lifetime. Authentication binds the claimed tenant before
  resolving the Agent name.
  Workers obtain their Agent token—and the AIGateway base URL—over an
  authenticated RuntimeFabric RPC. Operators can point Workers at a specific
  AIGateway URL via `ANKOLE_AI_GATEWAY_BASE_URL` (the Helm chart sets the
  control-plane Service DNS name, while Docker or custom setups can use a host,
  ingress, or external URL; if unset, the RuntimeFabric broker uses the Phoenix
  endpoint URL, and AIGateway never classifies URLs as internal vs external).
- **OIDC Human tokens** (`Ankole.OIDC.Tokens`): include the `ankole.ai_gateway`
  audience only when granted the `ai_gateway.write` scope. Authentication resolves
  `client_id` first and looks up `sub` inside that Client's tenant.

Both token services build on `Ankole.TokenSigning`. On incoming HTTP and
WebSocket connections, the Phoenix authentication plug verifies the JWT
signature and `ankole.ai_gateway` audience once, then dispatches to the domain
claim validator selected by `subject_type` and `client_id` (while the
RuntimeFabric broker and other direct consumers call their domain service's full
verifier).

For OIDC Humans, every HTTP request—and every `response.create` command on an
open WebSocket—re-verifies that the Principal and OIDC Client are active, checks
scopes and group memberships, and resolves the requested Client model alias
before provider selection; policy changes take effect on the next request
without interrupting an already-running stream. Every runtime query scopes
conversations, messages, and artifacts to the caller's `(tenant_id, subject_uid)`.
Personal assistants use their own execution identity for these records and for
usage metering. Because
OIDC Human requests use the Human Principal's UID as `subject_uid`, stateful
Responses belong privately to that Human: the same Human can resume a stored
Response from another authorized OIDC Client, and deleting an OIDC Client never
deletes the Human's stored history.

## Limit an Agent's Token Usage

Agents can carry a repeating token quota (configured, counted, and surfaced as
described in [Agent Token Quota](AgentTokenQuota.md)). Whenever AIGateway
resolves the model for an `llm` request with `subject_type: "agent"`—before
selecting a model or credential—it checks that Agent's quota and rejects
over-limit requests with HTTP `429` (`code: "agent_token_quota_exceeded"`,
`retryable: false`). Compaction triggered by such a request inherits the same
identity and is checked and counted alongside it, whereas internal control-plane
callers (such as Brain and automatic compaction) omit `subject_type` and bypass
the quota check. At the exact points where AIGateway records credential usage,
it appends one row to `ai_gateway_usage_records` for each counted provider
round.

Applet backend calls to `AnkoleRuntime.ai.generateText` run in-process under the
tenant's `system` Principal. The adapter resolves only built-in LLM slots from
that Principal's effective configuration (rejecting raw `provider/model` selectors and
falling back from a missing `light` profile to `primary`), validates reasoning
effort against the resolved model, and records LLM usage with origin `applet`
without checking an Agent quota. It maps upstream provider errors to
`ai_unavailable` and returns the generated text, `stop`/`length` finish reason,
and input/output token counts without ever exposing credentials to the Applet
isolate. The Applet invocation owns its overall timeout and cancellation: just
like streaming calls, native non-streaming requests monitor their BEAM owner
process and drop active upstream I/O immediately if the capability process exits.

## Create a Response without Storing It

Stateless Responses run without writing to `ai_gateway_conversations` or
`ai_gateway_messages`, mint temporary IDs prefixed with `tmp_resp_` (which
`GET /responses/:response_id` never returns), and support both HTTP and
WebSocket transports:

- **HTTP (`POST /responses`)**: always stateless—accepts `store=false` and
  rejects `store=true`, `conversation`, and `previous_response_id`. Codex uses
  this `store=false` contract when replaying its own Responses item history
  (whereas the main Agent opens durable stored Responses through the in-process
  API, committing each completed tool round and input consumption in one
  PostgreSQL transaction before continuing from that durable anchor).
- **Stateless WebSocket (`GET /responses` with `store=false`)**: caches up to 32
  completed Responses in connection memory so `previous_response_id` can prepend
  prior input and output locally on that socket without touching PostgreSQL.
  When Codex sends `response.create` with `generate=false` to warm up a
  WebSocket, AIGateway completes the empty zero-usage Response locally without
  opening a provider stream and caches the request input under its `tmp_resp_`
  ID so the first real generation can chain from `previous_response_id` without
  losing that initial input.

## Store a Response and Continue It Later

Stateful execution requires WebSocket `response.create` with `store=true`, using
public `conv_` conversation IDs and `resp_` Response IDs. The caller's `store`
flag governs persistence in Ankole alone: AIGateway strips it before dispatch,
and the OpenAI, Azure OpenAI, and `openai_compatible` Responses adapters set
upstream `store: false` independently so local conversation durability never
depends on provider-side storage.

Because AIGateway replays stateful history as Responses items, a stateful turn
must target an upstream wire that can replay those items losslessly—either
`openai_responses` or `openai_chat_completions`. Other wires (such as Anthropic
Messages) remain available for stateless calls, while stateful turns against
them fail at turn start with HTTP `422` (`stateful_wire_unsupported`). Tool
history is likewise bound to its execution runtime: if a native Responses
conversation recorded caller-executed Shell, Apply Patch, or provider-hosted
items that AIGateway's local compatibility loop cannot run, switching the
conversation to a local-compatibility route fails on the first unsupported item
with `invalid_program_child` rather than silently altering history. Moving across
either boundary requires starting a new conversation.

A stateful request continues history in one of three mutually exclusive ways
(passing both `conversation` and `previous_response_id` is invalid):

- **Implicit continuation (`conversation`)**: continues linearly from the
  conversation's current visible leaf. The admission transaction locks the
  conversation row, verifies the last visible Response, and rejects concurrent
  generations with status `409` (`response_in_progress`).
- **Explicit branch (`previous_response_id`)**: branches from a specific
  completed Response chosen by the caller.
- **New managed conversation (neither field)**: creates a fresh conversation and
  its root Response.

When context size requires compaction, AIGateway plans the compaction before
admission and inserts both the checkpoint row and the new `generating` Response
in one atomic transaction—so if a competing run wins the lock race, the losing
compaction plan leaves stored history untouched.

When an upstream provider changes how it validates provider-native Responses
items, AIGateway prioritizes keeping the conversation runnable over preserving
unreadable opaque bytes. Specifically, if an OpenAI Responses provider rejects a
turn before the first provider event with HTTP `400`,
`error.type=invalid_request_error`, and `error.param=input`, AIGateway rebuilds
durable history into a local version 2 checkpoint—stripping provider item IDs,
encrypted reasoning, and encrypted function arguments from the retained tail—and
retries the current input once:

- One transaction re-parents the `generating` Response onto the new checkpoint,
  clears old injected memory items, and records the updated item positions and
  request-item count.
- If the single retry still fails, that Response becomes terminal `error`, while
  the new checkpoint remains the visible continuation anchor for the next turn.
- AIGateway never triggers this recovery after a provider event or local tool
  effect has occurred, nor on `401`/`429`/`5xx` or transport errors.

## Own the Identifiers on Each Link

AIGateway sits between two links—an **upstream link** to a Provider and a
**downstream link** to a consumer (such as a Codex Job or the main Agent)—and
enforces strict single ownership over the identifiers on each side:

- **Upstream identifiers belong to the Provider**: When replaying an item to a
  Provider, AIGateway sends back the exact ID that Provider originally assigned
  (or omits the ID if that Provider never assigned one). Because Providers
  validate item IDs against server-sealed state such as `encrypted_content`,
  inventing or substituting an upstream ID would break the request.
- **Downstream identifiers belong to AIGateway**: Consumers see only IDs chosen
  by AIGateway, decoupling consumer state from Provider swaps.

Because the two ID spaces have different owners, AIGateway owns the translation
map between them for as long as a consumer can replay an ID: stateful
conversations persist the Provider ID alongside each stored item in PostgreSQL,
while stateless WebSockets hold the map in connection memory for the life of the
socket (keeping a map only for a single Provider stream would be too short,
because consumers replay items on subsequent requests).

Consumers must treat `previous_response_id` as an opaque lookup key and never
parse its string format (since a token can even mirror a Provider-chosen
format): AIGateway resolves it strictly by lookup—querying PostgreSQL when
`store=true` and connection memory on a stateless WebSocket.

Each downstream Response corresponds to one authoritative Provider round, even
when AIGateway runs additional internal Provider rounds for tool loops, program
execution, or compaction; retries completely replace failed attempts so every
item reaching the consumer comes either from the winning Provider round or from
AIGateway itself. As a pragmatic optimization for stateless callers (whose
history outlives any single socket while AIGateway stores nothing durable),
AIGateway reuses the Provider's item ID downstream whenever there is no
collision. When a collision prevents reuse—for example, two items in one
Response sharing the same raw ID—AIGateway mints an `ankole_`-prefixed ID that
the upstream request boundary recognizes and strips without needing a stored
map. Only two minted shapes ever stay in an outgoing request—a paired call/output
family's matching `id` and an `item_reference` pointing to an `id` inside that
same request—neither of which addresses server-side Provider state.

## Keep a Conversation after Its Provider Changes

Providers cryptographically seal parts of their output—such as reasoning
`encrypted_content` and tool parameters that a schema declared `encrypted`—so
only the issuing Provider can read them, and any other Provider rejects the
entire request rather than ignoring unreadable fields. A stateful conversation
hits this boundary whenever an operator repoints a model profile to another
Provider or a `vision_fallback` routes a turn elsewhere.

To keep the conversation runnable without breaking call/output pairing,
AIGateway separates **structure** from **sealed content**: messages, tool calls,
tool outputs, and their pairing IDs are structure and always survive, whereas
sealed ciphertexts are content and are scrubbed when switching Providers.

Concretely, every stored message records its issuing Provider row in `issuer`.
When a subsequent turn resolves to a different Provider row:

- AIGateway drops any `reasoning` item carrying ciphertext (because no other
  item pairs with a reasoning item).
- AIGateway preserves every tool call that declared `encrypted` parameters
  (because dropping the call would orphan its paired `tool_output`), replacing
  those sealed arguments with a plain placeholder and stripping the encryption
  marker. While the Agent loses hidden prior reasoning and the exact wording of
  sealed past arguments—which AIGateway never held in plaintext—the plain-text
  tool output remains intact.

Note three boundary cases:

- Because `issuer` tracks the Provider row ID, a single routing Provider row
  fronting multiple upstream vendors can switch vendors without changing
  `issuer`; the HTTP `400` checkpoint recovery above handles that case.
- Legacy messages lacking an `issuer` field replay unchanged: either their
  sealed state matches the current Provider, or an upstream `400` triggers
  checkpoint recovery.
- Stateless callers manage their own history (so AIGateway cannot tag or scrub
  their items), and Background Agent Jobs freeze their Provider at first
  admission so their Provider never changes mid-Job.

## What AIGateway Stores

AIGateway persists conversations and messages through two Ash resources:

- **`Conversation` (`ai_gateway_conversations`)**: stores `subject_uid`,
  `conversation_key`, end timestamp, and caller `metadata`. At most one active
  row can hold a given `(subject_uid, conversation_key)` pair; once a
  conversation ends, the caller can open a fresh active row under that same key
  (and `ensure` retries preserve the initial metadata). Note that an active
  Conversation is strictly an AIGateway storage record—not an execution
  Session—so callers that open a Conversation for a bounded internal trace end
  it when that work finishes.
- **`Message` (`ai_gateway_messages`)**: stores each Response run, tool-result
  journal, or compaction checkpoint. Each row has a type (`message` or
  `checkpoint`), a state (`generating`, `complete`, `error`, or `retracted`—represented
  as atoms in Elixir and strings in PostgreSQL and public JSON), a
  `previous_message_id` parent pointer, `content` holding the Response items,
  and a `metadata` object holding caller metadata alongside request and provider
  diagnostics (never a second item list). Public Response IDs format the message
  UUID as `resp_<uuid>`.

Message actions enforce initial row invariants and state transitions out of
`generating`. Completing a stream appends output items and merges metadata in
the same conditional `UPDATE` that sets the terminal state, whereas
progress-only heartbeat updates never renew the response lease. Tool-result
journals deduplicate against a tenant-scoped partial expression index on
`metadata.tool_result_idempotency_key`: retrying an immutable upsert returns the
first committed journal (and a cross-tenant key collision raises a stale-record
error). Compaction checkpoints insert immutably, joining the caller's admission
transaction whenever admission writes a checkpoint alongside a new `generating`
row.

Callers read `Conversation` and `Message` projections through `ResponseChain`,
which enforces active subject ownership and branch selection:

- Normal history expansion stops in SQL at—and includes—the first `complete`
  checkpoint.
- Explicit cross-checkpoint reads enforce cycle detection and a 10,000-row raw
  ancestor cap, while the public immutable chain endpoint caps responses at 500
  rows.
- Metadata-only chain reads cross checkpoints and return caller metadata only
  from `complete` ordinary rows; checkpoint metadata remains accessible for
  audit without implying that post-compaction input succeeded.

For operator visibility, `Sessions.Driver` passes the turn's frozen profile name
in `response_metadata`, which AIGateway stores as `model_profile` next to
`request_model` (outside `request_metadata`). The Console displays
`model_profile` beside the resolved provider model—falling back to
`request_model`, preserving the requested tier or custom profile name even when
configuration fell back to another tier, and never guessing a profile for older
messages or direct `provider_id/model` selectors. Background Agent Jobs record
their profile on the Job row and display it in the Jobs Console. Meanwhile,
`Sessions` persists loop progress separately in `session_round_states` (committed
in the same database transaction as each model call or tool journal); AIGateway
never reads or stores loop state inside caller metadata.

Stateful OIDC requests (`store=true`) also stamp the trusted `oidc_client_id`
from the active grant onto the stored row while keeping the caller's raw input
(including caller-supplied environment blocks) separate from local Brain memory
and pointer fields. `OIDCClientConversations` reads those raw inputs directly to
expose terminal request revisions and structured dialogue evidence grouped by
OIDC Client and conversation—preserving request IDs, parent IDs, submission
identity, speakers, and model output while excluding system/developer
instructions, reasoning, tool records, and checkpoints (for failed requests,
only submitted user dialogue counts as evidence, and retracting a row advances
the material revision and removes that row from evidence). Brain ingests this
projection asynchronously via its OIDC Client Source rather than enqueueing jobs
inside AIGateway's response commit; internal Agent requests carry no OIDC origin
and unattributed rows are never matched to a Client by inference.

Finally, `ai_gateway_usage_records` appends one immutable row per provider round
that counts toward an Agent token quota (see
[Agent Token Quota](AgentTokenQuota.md)), recording the Agent, origin, resolved
model selector, input/output tokens, and work attribution (`session_id`,
`signal_id`, `job_id`, and `attempts`, read from the same request-context keys
as the Turn root span):

- A Session Turn populates `session_id` during runtime resolution and
  `signal_id` when attaching the Turn span.
- A Background Agent Job attempt populates all four fields at admission, embeds
  the attempt in the `job` block of `x-ankole-aigateway-model-binding`, and
  restores them on every Codex request via
  `Ankole.Sessions.CodexModelBinding.request_context/2`.
- In-process calls lacking those keys write `NULL`. These attribution columns
  join to `background_agent_jobs.id`, the Session, and `signals.id` by value
  without foreign keys so a stale reference can never block quota accounting,
  and rows survive untouched until deleting the Agent Principal deletes all of
  its AIGateway records.

### Persistence Contract

`Ankole.AIGateway` is the Ash domain for `Conversation`, `Message`, `Artifact`,
`CompactionArtifact`, and `UsageRecord`, exposing `get_*` and `list_*` defines
and domain functions for cross-domain reads (`get_conversation_by_id` looks up a
Conversation by UUID, while `get_conversation/2` looks up one subject's
Conversation; provider rows live in `Ankole.AIGateway.ProviderConfigs`).

Every multi-step domain write runs in `Repo.transact_top_level/2` at the top
level—or through its matching `*_in_tx` helper when joining an existing caller
transaction—and publishes live events only after commit:

- **Lease renewal**: updates the heartbeat and schedules the next orphan
  deadline.
- **Terminal commit**: commits a Response's transition out of `generating`.
- **Generating failure and orphan reconciliation**: settles a failed or orphaned
  `generating` Response.
- **Stateful admission**: inserts the `generating` Response (plus optional
  compaction checkpoint) and runs caller admission hooks.
- **Recovery checkpoint installation**: installs the local version 2 replay
  recovery checkpoint.

Progress-only writes execute as a single conditional `UPDATE` without a
transaction, generated images for one Response persist together in a single
transaction, and Provider mutations (`change`, `retire`, `put_cooldown`,
`rotate_credential`) lock the provider row before reading `credential_pool`.
History expansion walks `previous_message_id` via a single tenant-bound
recursive SQL query to fetch ordered row IDs, then loads the typed rows through
`Message`.

## How a Stateful Response Runs

Each stateful model round executes in ten steps:

1. Validate the request payload and the authenticated `subject_uid`.
2. Resolve the Agent model profile, Client alias, or direct provider selector.
3. Resolve the target Conversation and continuation anchor.
4. Expand the `complete` message history up to the latest checkpoint.
5. Plan automatic compaction if historical token usage crosses the threshold.
6. Open the admission transaction, verify caller fences, and insert any planned
   checkpoint alongside one `Message` row with `status = generating`.
7. Strip Ankole-only stateful fields and prepare the upstream request.
8. Stream and normalize upstream provider events.
9. Persist the terminal output items or error record in PostgreSQL.
10. Emit the public terminal event and publish Conversation events (which
    `Conversations.Delivery` can subscribe to and filter using its own
    metadata).

Each Worker WebSocket permits at most one active Response stream at a time,
rejecting any second command until the active stream finishes.

## Run Tool Search and Program Calls

`HostedTools.StreamLoop` orchestrates provider rounds and public item
projections for every Response. When no gateway-hosted tools are active, a
Response runs a single provider round with zero gateway side effects and no
continuation state. When Tool Search, Brain, or Programmatic Tool Calling (PTC)
is active, `StreamLoop` executes those local effects, drives continuation rounds
under shared budgets, and exposes round and item-rewrite queries while keeping
each tool's planning and execution rules modular.

Ordinary Responses preserve the provider's terminal event shape without
synthesizing item-completion events for items that appear only in the terminal
snapshot (and if a terminal snapshot carries an empty `output`, only already-admitted
public items populate it so raw round items cannot resurrect calls rejected by
the tool budget; hosted tools admit terminal-only provider items before
publishing local outputs).

Before the first provider round, AIGateway validates and freezes the executable
tool catalog:

- Each tool descriptor keeps `namespace` and `name` separate (both matching
  `^[A-Za-z0-9_-]+$`; native Responses groups namespaced tools inside a
  `namespace` container while `function_call` items preserve `namespace` and
  `name` as distinct fields without string concatenation), alongside input and
  output schemas, codec, deferred-loading flag, and permitted callers.
- AIGateway rejects conflicting duplicate identities and hashes the full
  catalog into a single fingerprint: a subsequent Tool Search result can repeat
  a known tool only if its descriptor is identical, and a paused program can
  resume only against the exact same fingerprint.

`ResponseItems` serves as the single semantic registry for call/output pairs—covering
function, custom, program, Tool Search, computer, local-shell (with its distinct
output ID field), shell, apply-patch, and MCP approval pairs, and incorporating
program caller scope into pair identity. Streaming, persistence, compaction,
truncation, and tool budgets all consult `ResponseItems` rather than maintaining
separate type lists (unregistered provider item types pass through as opaque
content without execution or pair tracking). `ResponseItems` also extracts
ordered message content and text for downstream consumers: machine callers join
with newlines and trim, Applet `generateText` preserves raw text, and chat
Delivery extracts assistant text with provider citation markers stripped.

**Tool Search** synthesizes a single provider function and projects public
`tool_search_call` and `tool_search_output` items within one continuous Response
lifecycle:

- **Server mode** runs the search inside AIGateway; a server-loaded tool stays
  callable only while its structured identity remains in AIGateway's current
  deferred catalog.
- **Client mode** returns `tool_search_call` to the caller; every client-loaded
  tool contract in effective history stays callable across later user turns
  unless its `tool_search_output` is removed, and local compaction retains the
  minimal set of complete client call/output pairs needed to preserve those
  contracts (dropping earlier pairs superseded by an identical later contract).
- Client and server outputs never populate each other's loaded state,
  conflicting contracts for the same identity are rejected, and settled Tool
  Search pairs remain valid history even if a later turn omits Tool Search.
- When deciding local continuation, a non-empty provider terminal `output` is
  authoritative; if the terminal omits `output` after streaming complete
  output-item events, `StreamLoop` uses that round's streamed items and clears
  them before the next round.

**Programmatic Tool Calling (PTC)** executes model-written JavaScript programs
inside fresh, isolated workers via `Ankole.FunctionRuntime.ProgramRunner`
(`POST /v1/program/run` under a bounded `Task.Supervisor`, with network,
filesystem, environment, process, and FFI permissions denied, deterministic
clock/PRNG replay from a memo, and an opaque pre-admission cancellation handle
that aborts the HTTP call if the Response owner or task exits; native
supervision retires each worker as soon as its step returns, serving SSE,
WebSocket, and synchronous Responses uniformly):

- A program runs until it finishes or hits its first unanswered batch of nested
  tool calls; resuming replays the program from the start against recorded
  tool answers. The runner consumes each recorded answer only when the next
  call has the same namespace, name, and JSON arguments; object-key order does
  not affect equality. A replay mismatch remains a failed step even if the
  program catches the exception. Failed steps expose no pending calls, and a
  completed step must have consumed every recorded answer.
- Nested calls carry their `programmatic` caller scope, and Agent Computer runs
  a call only when its frozen descriptor permits `programmatic` callers—turning
  direct-only or malformed calls into explicit tool errors before they cross the
  execution boundary.
- In the synthesized program tool prompt, bindings that also have direct tool
  declarations list only their JavaScript global names (since their schemas are
  already in the provider `tools` array), whereas programmatic-only bindings
  embed their full schemas. Global names follow Codex code-mode rules: root
  tools and the default `functions` namespace use `name`; other namespaces use
  `namespace__name` (omitting the extra `__` if `namespace` already ends with
  `_` or `name` starts with `_`) with non-identifier characters replaced by `_`
  (two tools colliding on the same global name invalidate the request).
- Persisted program fingerprints carry the `ankole_ptc_v2.` prefix and freeze
  `namespace`, `name`, and the JavaScript global name for every binding (other
  fingerprint versions are rejected). Settled `program`/`program_output` pairs
  remain readable in history even if a later turn drops PTC (for example, after
  a Skill update removes the last programmatic tool), whereas resuming an
  unsettled program requires both the PTC declaration and matching frozen
  bindings.

Whether Tool Search and PTC run natively upstream or locally in AIGateway is
fixed by the provider and client protocol—and never flips mid-conversation when
tools are added or removed:

- **Provider-native**: first-party OpenAI Responses, plus `chatgpt_subscription`
  when called by a real Codex client.
- **Local planning in AIGateway**: `chatgpt_subscription` called by the main
  Agent (because the ChatGPT Codex endpoint rejects the Responses API
  `programmatic_tool_calling` declaration from the main Agent), OpenAI Chat
  Completions, and all other providers. Only function and custom tools can bind
  into local PTC (Codex and Agent Computer already declare apply-patch as a
  custom tool and shell execution as a function tool, so AIGateway never
  emulates provider built-in apply-patch or shell tools for local PTC).

Because OpenAI Chat Completions and Anthropic Messages expose only a flat tool
`name` field, their wire adapters map structured `(namespace, name)` pairs to a
single wire alias—keeping names matching `[A-Za-z0-9_-]{1,64}` unchanged,
encoding others as a readable prefix plus a 12-character BLAKE3 hash (distinct
from the Codex JavaScript global-name rule, rejecting alias collisions), and
restoring `namespace` and `name` before events enter the public Responses
stream. For custom tools, both adapters declare an object with one required
string field, `input`, and restore the public `custom_tool_call` with its raw
text input. They buffer the provider's JSON fragments until the complete text
can be decoded, then emit `response.custom_tool_call_input.done`. Explicit tool
choices and replayed custom call/result pairs use the same wire identity and
input wrapper.

`ResponseStream` is the single owner of public events, sequence numbers, loop
advancement, and PostgreSQL commits—accumulating public text and reasoning
summaries so UI display snapshots can read live progress in-process without
spending stream credit or advancing the upstream socket.

Strict resource caps bound internal loops before they can amplify cost:

- One public `max_tool_calls` budget spans all internal rounds: a budget of `0`
  strips all built-in tools before round 1; each round receives the remaining
  positive budget; provider-executed built-in calls deduct from the budget first
  at round end before AIGateway admits local Tool Search or program calls
  (unadmitted local calls are neither published nor run); once exhausted, later
  rounds strip built-in tools and stale `tool_choice` values without fabricating
  `response.incomplete` (function and custom tools sit outside this built-in
  budget).
- A single public Response allows at most 16 internal rounds, 8 top-level
  programs, 256 nested program calls, 1,024 retained provider-history items, and
  `8 MiB` of retained provider history, alongside isolate caps on code size,
  memo size, pending calls, output bytes, heap, wall time, and concurrency—failing
  explicitly rather than dropping call/output edges.
- If stored history contains duplicate items or contradictory pair IDs with no
  safe cut point, AIGateway rejects the turn rather than guessing or rewriting
  durable rows; operators recover by starting a new conversation or retracting/deleting
  an invalid removable tail.

## Recall and Write Memory inside a Response

Callers enable Brain memory tools by declaring `{"type": "brain"}` (with an
optional `operations` filter; Background Agent Jobs and Workflow tasks restrict
`operations` to `recall` and `get_page`). AIGateway expands that hosted tool
into root provider functions for `remember`, `learn_source`, `recall`,
`get_page`, `forget`, `entity`, `whoknows`, `synthesize`, and `delta`—reserving
all nine names so any colliding caller tool is rejected—using schemas and
executors owned by `Ankole.Brain.Tools`.

AIGateway executes every Brain call locally inside the current public Response
across all providers, counting each pair against the built-in tool budget:

- The provider's `function_call` projects publicly as `brain_call` (`operation`,
  `arguments`, `call_id`).
- Execution produces a paired `brain_output` (`call_id`, `status` of `completed`
  or `failed`, and JSON `output` that the model receives as a
  `function_call_output` on the next provider round); an individual Brain error
  fails only that call, and later turns replay settled pairs as function items.

Every Brain call queries and writes as the authenticated `subject_uid`. Rather
than trusting opaque public `metadata.signal_id` fields, runtime callers construct
a typed `Ankole.Brain.RequestContext` (carrying disclosure recipients, write
scope, conversation parent, and live-input write fences) and thread it through
call options across stateful continuations, replay recovery, and standalone
compaction. When no runtime context is supplied (as on generic OIDC Human
calls), AIGateway builds a default context scoped strictly to `subject_uid`.
(Codex Jobs bypass the hosted tool and construct the same fenced context in
`Ankole.Sessions.Tools.Brain`.)

Setting `inject: true` enriches stateful provider replays without mutating the
stored request input:

- On the opening turn, AIGateway stores the retrieved context pack in
  `metadata.brain_context_pack`, pointer lines in
  `metadata.brain_pointer_lines`, and a claim flag in
  `metadata.brain_context_pack_claimed` (so subsequent tool rounds do not inject
  a second opening pack).
- When building the upstream replay copy, AIGateway orders items as: opening (or
  checkpoint) pack, retained original inputs, checkpoint output, and subsequent
  history—appending pointer lines to the newest user message's environment block
  only in that transient replay copy. Because stored inputs stay untouched,
  compaction and OIDC evidence read clean originals without tracking byte or
  item offsets.
- Creating a compaction checkpoint refreshes `brain_context_pack` on the
  compaction artifact from the latest user text in current input—or, if current
  input has no user text, by walking the raw ancestor chain across earlier
  checkpoints at the continuation anchor (never reading summaries or other
  branches)—and replaces the opening pack on later replays (conversations
  without an opening claim receive no checkpoint pack, stateless calls receive
  no injection, and any pack-retrieval error logs a warning and leaves the
  request or checkpoint unpacked).

## Record Tool Results before the Next Model Call

`Sessions.Driver` commits an entire client tool round through the in-process
tool-result API (never over WebSocket), anchored to a `complete`
`previous_response_id` with at least one client output. In a single caller-owned
PostgreSQL transaction, the Driver writes the deduplicated tool-result journal
(idempotent on retry), completes satisfied wait inputs (skipped if the journal
already existed), records round progress, and deletes control-plane tool
receipts—publishing live events after commit. (By contrast, model-Response
admission owns its own transaction—checking the Driver epoch fence, writing any
planned checkpoint plus the `generating` row, saving the caller snapshot, and
publishing `response_started` after commit—while the Response stream itself owns
the later terminal commit.)

AIGateway pairs each submitted output (`function_call_output` or
`custom_tool_call_output`) against an executable `function_call` or
`custom_tool_call` on the anchor: matched outputs form one `complete` journal
row, whereas unmatched outputs land in an `error` row that never enters provider
replay.

During provider replay, AIGateway repairs deterministic JSON punctuation damage
in stored `function_call` arguments in memory without rewriting PostgreSQL. If
arguments are unrecoverable:

- A call with a recorded output replays with `{}` and prepends a warning note to
  that output (preserving media parts, naming the broken call, and instructing
  the model to verify state before repeating side effects rather than claiming
  the tool ran with `{}`).
- An unpaired malformed call is dropped without synthesizing an output.

On **implicit continuation**, if AIGateway finds an interrupted client tool call
with no recorded output on the visible leaf, it injects a synthetic interrupted
output of the matching type before replaying the new input. **Explicit branch
continuation** (`previous_response_id`) never rewrites the caller-chosen branch.

For crash recovery, `visible_response_suffix/3` takes an opaque caller-metadata
string selector and scans backward in SQL—crossing checkpoints, invisible
ancestors, and unmatched error journals until hitting the first `complete`
ordinary Response that does not match—returning matching rows, ordinary
Responses, the current visible leaf (even when zero rows match), and already-recorded
`call_id`s so recovery executes only unrecorded calls. Note that `error` and
`retracted` rows still preserve the input IDs that the model already read, so
those inputs remain marked consumed even after the row is hidden from visible
history.

Live Conversation event subscriptions go through `Events` (subscribing requires
an active owned Conversation, while unsubscribing also succeeds after the
Conversation ends), explicit compactions go through `CompactionRequests`, and
Console audit queries read tenant-scoped history including ended Conversations,
`error` and `retracted` rows, and historical branches.

## Store the Result before Reporting Completion

`ResponseStream` always commits terminal items to PostgreSQL before sending a
public terminal frame (`response.completed` or `response.incomplete`). If that
commit fails, AIGateway attempts to commit an `error` state instead and emits
`response.failed` only after that error commit succeeds; if both database writes
fail, AIGateway cancels the upstream stream and closes the transport without
sending a terminal frame.

While a Response is `generating`, `ResponseStream` sends a 60-second heartbeat
whose transaction schedules `ReconcileOrphanedResponse` via Oban, and merges
`metadata.upstream_progress` (on heartbeats, pre-Ready failures, and terminal
commits—never overwriting terminal rows or other metadata keys, and without
extending the lease on metadata-only writes):

- `attempt` counts native upstream opens (including route retries and tool-loop
  continuation rounds), starting a fresh UTC ISO 8601 timeline per attempt.
- `dispatched_at` records native open; `ready_at` and `ready_status` record
  `Stream Ready`; and `first_event_at`, `last_event_at`, and `event_count`
  count decoded `Provider`-origin events (`ready_at` without `first_event_at`
  pinpoints a stream that opened headers without delivering a single provider
  event; pre-first-event native errors and `Client`-origin hosted lifecycle
  events do not advance `Provider` event counters).
- If five minutes pass with no dispatch, `Stream Ready`, or `Provider` event
  progress, the heartbeat logs a single `ai_gateway.response_stream_stalled`
  warning for that stream without shortening its 30-minute timeout.

If a `generating` row goes five minutes without a heartbeat,
`ReconcileOrphanedResponse` transitions that specific Response to `error` with a
retryable failure (never looking up Signals from caller metadata), and a newly
elected `Sessions.Driver` can call `reconcile_orphaned_response/2` with
`force: true` after verifying its epoch to settle a predecessor's `generating`
row immediately; any late stream commit for that Response ID cannot overwrite
the settled `error` state.

Finally, callers can retract or hard-delete a contiguous suffix at the end of
visible history as long as the supplied row IDs match the current `complete`
tail exactly: retraction hides the rows from normal replay while keeping them
for audit, and hard deletion deletes only the validated rows.

## Shorten Long History

`AIGateway.Usage` normalizes token usage for both stored Responses and
compaction artifacts using non-negative integers: canonical nested cached and
reasoning counts take priority over legacy provider detail names and flat fields
(preserving explicit zeros, including an explicit zero total), missing or
invalid totals default to `input + output`, re-normalizing a canonical struct is
idempotent, and lost historical counts are never guessed.

Compaction uses a single caller-facing protocol owned by AIGateway: any caller
requests compaction by including a `compaction_trigger` input item in a
Responses call, and AIGateway answers with a `complete` Response containing
exactly one `compaction` output item—never forwarding `compaction_trigger` raw
to an unverified upstream. Because `compaction_trigger` is an input item (an
OpenAI-family extension implemented by AIGateway rather than part of base
OpenResponses) rather than a transport frame, every transport supports it: HTTP
returns the JSON Response body, while SSE and WebSocket stream the matching
events. Internally, `create_response/3` returns only `:body` for a compaction
trigger (without inventing `:status` or `:model_ref`, which normal model calls
include), and transport adapters handle both shapes uniformly.

Compaction is strictly additive—it never deletes predecessor rows:

- **Stateful callers (`store=true`)** compact stored conversation history
  (writing a `CompactionArtifact` and an immutable `checkpoint` Message row with
  the same UUID, and returning that checkpoint's ID so the next turn continues
  from it). Passing an explicit `previous_response_id` (which must belong to the
  subject and conversation) compacts that predecessor chain; omitting it
  compacts up to the current visible leaf. Normal history expansion stops at the
  checkpoint, whereas replay recovery walks past checkpoints to rebuild from raw
  predecessor messages when a Provider binding changes. The main Agent's
  `/compress` command invokes this exact local checkpoint rebuild as an explicit
  manual recovery path.
- **Stateless callers (`store=false`)** compact the input items that they sent
  in the request, because only the caller holds stateless history.

When a stateful caller sends no explicit trigger, AIGateway checks historical
token usage automatically against `ai_gateway.compaction` in AppConfigure:

- `threshold` (default `0.90`, `0 < threshold <= 1`): fraction of context that
  triggers automatic compaction for the main Agent.
- `max_threshold_tokens` (default `400000`, positive integer): hard ceiling on
  that automatic trigger.
- `tail_rows` (default `4`, non-negative integer): preferred number of recent
  rows retained during local compaction.
- `user_message_budget_tokens` (default `20000`, positive integer): token budget
  for retained user originals during local compaction.
- `upstream` (default `false`, boolean): selects the upstream pass-through
  backend instead of the local summarizer.

`CompactionPolicy` enforces no server-side ceiling on the integer fields, while
the Console caps integer inputs at `9007199254740991` (`Number.MAX_SAFE_INTEGER`)
to avoid JSON precision loss. Because provider usage includes fixed instructions
and tool schemas—which compaction cannot shrink—operators should keep the
effective trigger comfortably above fixed input size (leaving room for the
summary, retained tail, and next turn); setting `max_threshold_tokens` too close
to fixed input (or pairing a tiny model context with a large output reservation)
can trigger compaction on every turn or leave zero retained rows, as AIGateway
does not suppress back-to-back compactions.

Under this single protocol, `ai_gateway.compaction.upstream` (a tenant setting
inheriting the site default) chooses between two backends:

1. **Local summarizer (`upstream: false`, default)**: summarizes history using
   the Agent's `light` profile (falling back to `primary` if `light` is unset,
   while sizing the checkpoint budget against the request model's context
   length) so summarization cost and latency stay decoupled from the main
   conversation model, without binding history to any upstream vendor.
2. **Upstream pass-through (`upstream: true`)**: forwards the compaction request
   to the Provider and returns the Provider's native `compaction` item (which
   binds subsequent history to that upstream, outliving the Agent that triggered
   it).

Upstream pass-through applies per request (never frozen on a Job) and requires
two structural gates: an effective Responses wire and official OpenAI tool
support (`supports_openai_tools: true` on `openai_compatible` rows). Only
stateless callers forward directly (since they supply the full history that the
Provider must compact, whereas stateful callers run provider-native compaction
inside conversation compaction). If either gate is missing, AIGateway runs local
compaction immediately without probing upstream. Once past those gates,
AIGateway streams the request through the standard Responses stream owner
(collecting until terminal and requiring a single `compaction` output item before
emitting anything publicly), falling back to the local summarizer on wrong-shaped
or failed replies. A node-local negative ETS cache keyed by
`{provider_row_uuid, provider_updated_at, resolved_model}` caches HTTP `404`/`405`
or structured unsupported errors for one hour so subsequent calls skip the probe,
whereas transient errors (`401`, `429`, timeouts, `409`, `5xx`, transport drops,
malformed streams, or empty outputs) fall back locally for that attempt without
caching (restarts, provider edits, or model changes trigger a fresh probe, and
concurrent cold probes may each observe `unsupported`).

`ai_gateway_compaction_artifacts` stores two artifact versions (both of which
may also carry a separate `brain_context_pack` message list excluded from
`output`, public handles, and OIDC evidence):

- **Version 2 (local)**: stores a structured summary object plus `output` items,
  and exposes a public `ankole:compact:v1:` handle that resolves to a user
  `Context checkpoint` message before entering the Rust kernel.
- **Version 3 (upstream)**: stores the Provider's unmodified non-empty JSON
  `output` array, usage, and a binding to `{provider_row_uuid,
  provider_updated_at, resolved_model}`, with no public handle.

During stateful replay, AIGateway expands a checkpoint to
`brain_context_pack ++ output` (ordering local replay as: memory pack, retained
user originals, any preserved opaque prefix, summary, retained tail, and current
input). Before replaying a version 3 artifact, AIGateway verifies its stored
provider/model binding (reactive `400` recovery does not replace this proactive
check because version 3 `output` is an indivisible opaque array); if the
provider or model changed—or a later upstream compaction fails—AIGateway walks
the retained raw predecessor messages and builds a local version 2 checkpoint
free of foreign provider state.

On a stateless trigger, version 3 returns raw provider output without an Ankole
handle (requiring a compatible Responses upstream on continuation; the Rust
kernel preserves provider-native compaction items on the Responses wire and
rejects them on other wires with `unsupported_compaction_replay_wire`). If a
stateless request already contains provider-native compaction ciphertext and
upstream compaction is disabled or fails, AIGateway neither fails nor fabricates
a summary over unreadable ciphertext: instead, it copies items up through the
last Provider compaction item verbatim as an opaque prefix (logging a warning),
summarizes only the trailing items locally, and emits that prefix ahead of the
local checkpoint on replay while still returning a single `compaction` item.

Local compaction sizing and boundary selection follow strict pairing and budget
rules:

- The summarizer consults `ResponseItems` for all call/output types, rendering
  bounded arguments, code, actions, and outputs under synthetic `call_N` aliases
  so raw provider call IDs never enter the summarizer prompt. It streams through
  the standard Responses owner (preserving the request context and cache key,
  retrying once with a larger output limit if truncated by `max_output_tokens`,
  and aborting artifact creation if the stream fails or closes without a
  terminal Response).
- `tail_rows` is a soft preference: AIGateway shifts the cut forward to keep
  call/output batches intact or fit within the context budget (shifting forward
  once when retained client Tool Search pairs shrink available tail room,
  reserving every pair that could cross the maximum safe boundary so refitting
  never overflows, and never dropping an active Tool Search pair), or shifts the
  cut backward when current input closes an open call.
- Before selecting the tail or persisting a checkpoint, AIGateway reserves up to
  4,000 tokens (including message wrapper) for the refreshed
  `brain_context_pack` and estimates the combined token size of the pack, user
  originals, summary, retained client Tool Search pairs, retained tail, pending
  clarification, and current input—returning a single plan with filtered input
  and injection positions without adding memory after the budget check (earlier
  checkpoint packs never enter a new summary, and legacy checkpoints without
  `brain_context_pack` replay unpacked until conversation rotation or an explicit
  reset starts a fresh conversation; if the fitted result still exceeds budget,
  AIGateway skips artifact creation and falls through to automatic overflow).
- Manual `/compress` runs without waiting for `threshold` and can summarize a
  short history with fewer rows than `tail_rows` as long as a safe completed
  prefix exists; otherwise it replies `Nothing to compress.` without writing a
  checkpoint.
- Internal ancestor traversal reads up to 10,000 rows (with no separate SQL byte
  cap when replay recovery walks raw predecessors across checkpoints before
  applying the compaction token budget), whereas the public chain API returns at
  most 500 rows.

### Automatic Overflow

Each stored Response's provider usage is a cumulative snapshot of the
conversation at that point rather than a delta to sum across rows, so automatic
compaction and overflow read the latest usage snapshot in visible history.

When usage exceeds the threshold, no compaction candidate is available, and the
request sets `truncation=auto`, AIGateway selects the configured stable tail and
expands it backward until all client tool calls and outputs—including `program`
and `program_output`—form a closed, valid pair boundary across history and
current input. AIGateway writes that tail into a `CompactionArtifact` with a
fixed notice stating that older history was omitted for the context budget,
points the new Response at that checkpoint (preserving raw predecessor rows in
PostgreSQL and recording the dropped range and opaque references in checkpoint
metadata), and replaces any prior fixed truncation notice on subsequent
overflows while preserving real earlier compaction summaries. Because exact
suffix token counts cannot be subtracted from cumulative provider snapshots,
AIGateway validates fit with the local checkpoint estimator over the fixed
notice, retained client Tool Search pairs, selected tail, and current input—returning
`context_overflow` if no valid cut fits.

## Store Vision Files and Generated Images

`ai_gateway_artifacts` stores uploaded vision files (`purpose=vision`, up to
`50 MiB`) and generated images:

- `Artifact` actions compute byte length and `SHA-256` directly from the stored
  payload (callers cannot supply derived fields or pick an artifact kind), omit
  raw payload bytes on ordinary reads unless an image or file adapter explicitly
  selects them, and share atomic expiry and failed-response predicates during
  garbage collection. Stateless generated images expire after 30 days, whereas
  generated images linked to a `Message` row in PostgreSQL are retained with
  that conversation.
- `CompactionArtifact` exposes only a `create` action (no updates), and
  `UsageRecord` is append-only with non-negative counts summed via one
  tenant-scoped aggregate query and normalized through `AIGateway.Usage`.

For `image_generation` (which AIGateway includes only when declared by the
caller, validating up front that `output_compression` is set only when
`output_format` is `jpeg` or `webp`):

- **Native execution**: When the main LLM provider's Responses capability
  declares `supports_native_image_generation` (such as OpenAI and
  `chatgpt_subscription`) and its row uses the Responses wire, that provider
  executes image generation natively
  without resolving or validating any fallback `image_generate` profile—so a
  stale fallback configuration never blocks ordinary chats.
- **Hosted fallback**: When the main provider lacks native support, AIGateway
  executes the public `image_generation` tool through the Agent's
  `image_generate` profile (filtering out ineligible provider endpoints, showing
  the main LLM only the executor's hidden function, and returning an explicit
  unsupported-value error if neither native nor fallback execution exists).

Before dispatching any Responses or native image call, AIGateway inlines local
input-image and mask artifact references and restores each stored
`image_generation_call.result` from its `Artifact` (within the shared `100 MiB`
outgoing request limit, keeping lightweight references in stored message
history)—even on `openai_compatible` Responses proxies that lack image-generation
capabilities, since proxies may return images and strip item IDs on later turns.

Hosted image rounds allow a 30-minute runtime and a `128 MiB` upstream streaming
limit, continuing over the Responses WebSocket when the main provider uses
WebSocket mode and using one collected non-streaming main-model call per round
otherwise. A single persistence observer records normalized image events from
both native and hosted paths—keying hosted artifacts by a local `ig_` UUID while
storing native provider item IDs separately for later lookup, rotating and
attributing usage strictly within whichever pool (image vs main model) ran each
attempt, and surfacing upstream failures with safe HTTP status details and a
bounded `error.message` copy while keeping raw provider bodies and metadata
private.

## Observe the Execution Path

Structured logs record execution metadata without ever logging prompts, tool
arguments, tool outputs, raw provider messages or response bodies, image bytes,
or credentials:

- **Agent Computer**: logs the resolved AIGateway scheme and host once at turn
  start (without inferring network topology from the hostname), logs resolved
  tool names once, and logs each main-model attempt, retry decision, tool
  execution, and tool-result commit with the runtime-supplied Signal trace ID
  and elapsed time.
- **AIGateway**: logs interrupted WebSockets (with Signal trace ID, model, and
  elapsed time), failed synchronous provider calls (capability, provider, model,
  resolver, upstream host, duration, sanitized provider status, and retry
  classification), and image-generation eligible endpoints and stage-annotated
  failures (reporting provider and public HTTP statuses separately). Unexpected
  crashes during replay recovery, program cancellation, or Codex
  `vision_fallback` log warnings with failure class and stack locations (omitting
  exception messages and function arguments; recovery preserves the original
  Provider error, and cancellation returns best-effort output).
- **Severity and public projection**: A single diagnostic owner normalizes
  synchronous, streaming, and hosted-tool errors—logging Provider `4xx`
  rejections and consumer cancellations at `WARNING`, and Provider `5xx`
  errors, transport drops, and internal errors at `ERROR`. Stateful socket-open,
  provider terminal, and stream-transport failures persist safe classification
  fields plus a bounded copy of `error.message` (falling back to a stable
  default message when absent) without storing raw bodies or metadata. One
  shared projection serves both HTTP and WebSocket edges: preserving upstream
  `4xx` codes, mapping upstream/transport errors to `502` (never `422`), mapping
  native upstream timeouts to `504`, and keeping request-validation rejections at
  their `4xx` status with identical codes and messages across both transports.

On conversation turns, the caller stores its Driver epoch and input-availability
snapshot in opaque request metadata so a successor Driver can detect a committed
capacity error from the prior epoch and schedule its retry through the
conversation retry owner. Likewise, if profile resolution hits an exhausted
credential pool before opening model I/O, conversation admission commits the
attempt and capacity retry atomically—returning the deferred input contract
without starting a model call or spending the execution failure budget.

Optional distributed tracing uses the process-wide OpenTelemetry SDK in the
control plane to export OTLP over HTTP/protobuf, configured via four
site-wide AppConfigure keys read once at node boot (changing them requires a
restart; the control plane scrubs standard `OTEL_*` exporter environment
variables before OpenTelemetry boots and again before configuring the exporter,
and trace export is strictly best-effort with no database queue or retry effect
on model calls):

- `observability.traces.enabled` (default `false`; enabling it exports model
  prompts and outputs externally, so operators must point it only at a trusted
  receiver).
- `observability.traces.provider` (`langfuse`, `langsmith`, or
  `opentelemetry`; required with no default when enabled).
- `observability.traces.otlp_endpoint` (base HTTP URL, to which the exporter
  appends `/v1/traces`).
- `observability.traces.otlp_headers` (encrypted string map for receiver auth
  and protocol headers).

Note that an observability Provider only projects vendor span attributes onto
Turn roots, AIGateway LLM spans, and forwarded Worker OTLP batches—it is not an
AIGateway model Provider, does not own transport, and does not filter unrelated
OpenTelemetry spans (`opentelemetry` adds zero vendor attributes for generic
backends such as VictoriaTraces, Honeycomb, and Grafana Cloud).

For each Driver attempt, the control plane opens a `turn {signal.type}` root
span after admission (recording bounded, sanitized trigger and final-reply
payloads, plus Job ID and attempt number on Background Agent Jobs; closing on
finalization, retry, or process exit, with rebuilt Drivers opening a fresh span)
and derives a single attribution-only `user.id` (capped at 200 Unicode code
points, with no effect on authorization, routing, or Session identity; omitted
from AppConfigure and Console settings):

- `principal:<principal_uid>` for a direct message from a trusted Human, or a
  channel-less Turn triggered by a trusted Human.
- `channel:<signal_channel_id>` for a group Turn or any event Turn carrying a
  source channel.
- Omitted when neither a trusted Human nor a source channel exists.

The control plane injects the root span's W3C `traceparent` and `user.id` into
the turn request context:

- Agent Computer parents Main Agent tools, `invoke_agent codex`, and Codex
  `execute_tool` spans to that `traceparent`, stamps the same `user.id` onto
  Worker spans, forwards `traceparent` plus an unpadded `base64url`-encoded
  `user.id` header on AIGateway calls (decoded by the control plane and never
  sent upstream; AIGateway accepts a carried `user.id` only on authenticated
  Agent calls with a valid `traceparent`, falling back to
  `principal:<authenticated_subject_uid>` otherwise), and ships provider-neutral
  protobuf OTLP batches back over RuntimeFabric RPC (authenticated by Agent
  Principal, where the control plane applies the vendor mapping before
  forwarding to the OTLP receiver).
- Under a traced Agent Turn, each `chat {model}` round is a direct child of the
  Turn root (standalone or non-Agent calls open an `ai_gateway.response` root
  instead). Pre-output retries stay inside the same generation span (appending an
  `ankole.ai_gateway.credential_retry` event with `error.type` and planned delay
  on pool rotation), Tool Search and PTC continuations open sibling generations,
  and upstream compaction opens a `compact {model}` generation. Each generation
  span ends as soon as the upstream provider terminal arrives—before image
  persistence, PostgreSQL commit, or public projection—recording only the
  round's own output items (falling back to round `response.output_item.done`
  items if the streamed terminal `output` is empty, excluding echoed
  `instructions`/`input`/`tools`, and preserving JSON booleans and `null`),
  status, usage, and sanitized `FailureDiagnostics` attributes (`error.type` and
  `ankole.ai_gateway.*`, never overwriting an outer code like
  `credential_pool_exhausted` with `nil` and omitting raw error messages/bodies).

Exported spans attach `service.name`, optional `service.version`
(`ANKOLE_VERSION`, falling back to `ANKOLE_RELEASE_REVISION` on the Worker)
and `deployment.environment.name` (`ANKOLE_ENV`), Principal UID and type, client
`originator`/`user-agent`/`version` headers, `ankole.ai_gateway.caller` for
internal callers, session identity (the stateful Conversation ID when present,
otherwise `RequestContext.session_key/2`—never `prompt_cache_key`), standard
`gen_ai.*` operation/model/usage/tool attributes (including cache-read,
cache-write, and reasoning token buckets), and a single content projection
(scrubbing credentials, headers, caller metadata, encrypted fields, and
`__ankole_*` markers, replacing inline `data:` URLs with byte counts, and
omitting payloads over `1 MiB`):

- **Generic `opentelemetry`**: keeps bounded `ankole.*` fields (including Worker
  `ankole.agent.input`/`ankole.agent.output` and
  `gen_ai.tool.call.arguments`/`gen_ai.tool.call.result`).
- **Langfuse v4** (for example `https://cloud.langfuse.com/api/public/otel` with
  Basic `Authorization` and `x-langfuse-ingestion-version: 4`): maps content to
  `langfuse.observation.*` (replacing duplicate Worker fields), marks Turn/Worker
  Agent and tool spans as `agent` and `tool` observations, sets Langfuse user
  and session from `user.id` and the session key, sets `langfuse.release` from
  `ANKOLE_VERSION`, and writes Agent Principal, caller, and originator as
  filterable trace metadata.
- **LangSmith** (regional `/otel` base URL with `x-api-key` and optional
  `Langsmith-Project`): maps content to `gen_ai.prompt` and `gen_ai.completion`
  (plus one input/output pair for Worker spans) and copies stateful conversation
  IDs to `langsmith.trace.session_id` alongside `gen_ai.conversation.id` and
  `session.id`.

## Split Work between Elixir and Rust

The Rust `UniversalAIClient` executes one prepared Provider call end to end—encoding
and sending the request, parsing HTTP, SSE, AWS eventstream, or WebSocket frames,
normalizing items and errors through its resolver, and managing ordering,
pending-byte windows, read credit, and cancellation through `Delivery` (a
standalone contract usable even without an AIGateway consumer). Meanwhile,
Elixir selects the Provider, model, eligible endpoints, credentials, and
headers (`CredentialAttempts` owns pool selection, cooldowns, and post-output
credential health updates from `response.failed`), and `ResponseStream` owns the
multi-round Ankole Response (public IDs, item projection, terminal validation,
tool continuations, task monitors, deadlines, PostgreSQL commits, downstream
credit, and Elixir/native-owner failure terminals, including turning a Rust task
panic reported as `native_stream_panicked` into an immediate owner failure).

The NIF entry points parse model and hosted-tool request specifications on a
temporary 8 MiB stack on the calling scheduler thread. This accommodates nested
tool schemas without depending on the BEAM dirty scheduler's native stack size.

Chunks crossing the NIF boundary tag their origin as `Provider` (normalized
upstream frames, which are the only chunks that record upstream progress or
credential success) or `Client` (pre-call hosted lifecycle and native failure
frames), both consuming downstream read credit in order:

- **Before the first normalized event is queued**: any error aborts the native
  attempt with `StreamError` and zero events, allowing Elixir to run replay
  recovery or credential/route retry.
- **Once any event is queued or delivered**: the retry window is closed (even if
  downstream has not read the queued event yet), and any subsequent upstream or
  transport failure passes through the resolver to emit one ordered
  `response.failed` terminal under read credit before native termination
  (terminal batches can exceed the mid-stream pending-byte window to carry full
  accumulated output). Downstream consumers pull via `ResponseStream.next/2`:
  unread terminals stay buffered until read, canceled, or exited (late credit on
  a finished stream is a no-op, and delivered mailbox batches remain readable
  after owner exit).

Public streams emit `response.completed`, `response.failed`, or
`response.incomplete` as terminals (upstream `error` frames stay diagnostic; if
an upstream closes without a terminal, Rust emits `response.failed`, and if the
native owner dies without emitting a terminal, SSE and WebSocket send one
`error` frame with `provider_stream_error` while keeping the WebSocket open for
future requests). The Rust resolver retains the first bounded Provider error
code, type, status, and message for the call—attaching them if a later native
failure needs a terminal, preserving transport codes on subsequent transport
drops, and mapping permanent Provider validation errors through
`FailureDiagnostics` to `invalid_prompt` identically whether raised on open or
mid-stream (logging code and type without the message).

Retryability rules outside request/socket validation errors follow explicit
evidence:

- An explicit boolean `response.failed.error.retryable` is authoritative.
- When `retryable` is absent, callers infer retryability from Provider status,
  error type, and error body (note that the kernel wraps mid-stream failures in
  OpenAI envelope type `server_error`, so only the inner Provider status, type,
  and body count as Provider evidence): capacity errors stay retryable across
  all aliases (`server_error`, `service_unavailable_error`, `overloaded_error`,
  even without an HTTP status); `invalid_provider_event` (such as malformed JSON)
  and `provider_terminal_rejected` are non-retryable protocol errors unless
  marked otherwise; hosted image errors attach `details_json.stage` and treat
  Provider `403` as non-retryable; `429` and `5xx` keep their retry class; and
  `upstream_timeout` without an HTTP status remains a timeout rather than a
  capacity error.
- **AWS Bedrock eventstream** mid-stream errors after HTTP `200`: exception
  frames report `:exception-type` plus Bedrock's documented HTTP status—making
  `throttlingException` (`429`), `serviceUnavailableException` (`503`), and
  `internalServerException` (`500`) retryable, `validationException` (`400`) a
  validation error, and `modelStreamErrorException` (`424`) non-retryable—while
  error frames report `:error-code` with no status.
- **Anthropic Messages** mid-stream `error` events after HTTP `200`: end the
  Response with the event as error body and Anthropic's documented status—making
  `overloaded_error` (`529`), `rate_limit_error` (`429`), and `api_error`
  (`500`) retryable, `invalid_request_error` (`400`) a validation error, and
  undocumented types statusless.

On terminal reconciliation, `ResponseStream` rejects completions containing an
incomplete client tool call. Because the Rust kernel reports the raw terminal
body and recorded `done`-item snapshot separately without merging them, Elixir
reconciles missing terminal item IDs from the matching streamed index only when
the terminal item is a field-for-field subset of the streamed item, and treats a
missing terminal `output` as `[]` before appending consecutive streamed `done`
items past the terminal list's last index (keeping conflicting terminal items
authoritative at their index).

Transport, proxy, tool-lowering, and reasoning-envelope adapters bridge wire
differences cleanly:

- **Upstream WebSocket & proxy resolution**: OpenAI and `openai_compatible` rows
  default `upstream_transport` to `sse` and can opt into `websocket` for
  streaming Responses calls (Chat Completions and non-streaming calls stay on
  HTTP). For both HTTP and WebSocket (supporting HTTP and `SOCKS5` proxies),
  `NO_PROXY` bypasses all proxies, explicit `transport.proxy` takes priority
  next, secure URLs check `HTTPS_PROXY` -> `ALL_PROXY` -> `HTTP_PROXY`, plain
  URLs check `HTTP_PROXY` -> `ALL_PROXY` (case-insensitively), and unmatched
  targets connect directly—with zero hardcoded local proxy names or ports.
- **Custom tool lowering**: On OpenAI Chat Completions—and on OpenAI Responses
  connections where `supports_openai_tools` is `false`—the adapter lowers custom
  tools, replayed custom calls/outputs, and custom `tool_choice` to single-string
  `input` function tools (embedding grammar rules in `input`'s description and
  stripping the internal emulation marker) and restores `custom_tool_call` at
  `done` once the full JSON-escaped string arrives.
- **Chat `reasoning_details` & Gemini signatures**: Streamed `reasoning_details`
  concatenate into one public `reasoning` item sealed in an AIGateway envelope
  bound to `(provider_type, model_id)` (shared across rows of the same type and
  model; explicit `reasoning.effort` overrides route `reasoningEffort`). On
  replay, valid matching envelopes restore details onto the assistant message
  (dropping standalone reasoning with no assistant text or tool call so Chat
  providers never reject an empty assistant turn), while missing, stale, or
  mismatched envelopes drop only private reasoning. The same envelope keys per-call
  `extra_content` by `call_id`—preserving Gemini's thought signature on the
  first parallel call regardless of item ordering (since Gemini streams text
  ahead of the call that it signs while tool loops store reasoning ahead of that
  text) and never leaking signatures across models.
- **Anthropic `thinking` signatures**: Native `thinking` and `redacted_thinking`
  blocks plus signatures seal into the same `(provider_type, model_id)`-scoped
  `reasoning` envelope (since Claude validates signatures per model). On
  continuation, the adapter coalesces consecutive assistant Responses items into
  one Anthropic assistant message—placing decoded thinking blocks first and
  converting function calls to `tool_use` blocks, or replaying a valid
  thinking-free tool turn when the envelope was dropped.

## Preserve Encrypted Tool Fields at Their Owner

Tools can mark a direct string property on an object schema with
`encrypted: true` (AIGateway validates this shape up front on every route,
rejecting non-boolean markers or markers placed anywhere else in the schema):

- **Responses wires**: Forward `encrypted: true` unchanged and let the upstream
  Provider own `encrypted_function_args`. Because Codex-native upstreams compare
  inbound schemas against built-in tool definitions on the very first request,
  stripping the marker would fail validation (this rule governs only marker and
  argument ownership—tool execution still follows the native-vs-local PTC rule
  above). On input, non-AIGateway-prefixed `encrypted_content` parts pass
  through untouched, while AIGateway-prefixed parts decode via the tool-field
  codec and fail closed if corrupt.
- **Non-Responses wires**: An emulating adapter strips `encrypted: true` before
  dispatch, buffers complete outgoing function arguments, and encodes marked
  fields into self-describing, version-prefixed `Base64URL` opaque strings (failing
  closed before anything enters the stream or database if incomplete or invalid;
  rejecting foreign non-AIGateway `encrypted_content` on input, and decoding
  AIGateway-prefixed values back to plaintext on replay without needing tool
  schemas).

Outside provider replay, Console Turn views and Job trajectory readers reveal
these AIGateway-encoded fields via `Ankole.AIGateway.OpaqueContent`, whereas
Worker thread resume keeps the stored encoded form that the Worker expects. Note
that this versioned `Base64URL` encoding is a wire-compatibility envelope—not
cryptographic encryption—and is completely separate from Provider-sealed
reasoning `encrypted_content`.

## Rules

- External provider credentials never enter Agent Computer memory.
- Each Provider owns upstream item identifiers; AIGateway owns downstream ones.
- Replayed Provider items carry the exact identifier assigned by that Provider.
- AIGateway retains its identifier map for as long as consumers can replay those identifiers.
- AIGateway resolves `previous_response_id` strictly by lookup, never by parsing string prefixes.
- Every stored message records its issuing Provider row.
- Switching Providers scrubs sealed ciphertexts while keeping every paired call/output structure intact.
- Every stateful Response belongs to one Principal and one Conversation.
- Implicit continuation advances only from the expected visible leaf.
- Only explicit `previous_response_id` continuation can branch from an earlier Response.
- Each WebSocket runs at most one active Response stream at a time.
- AIGateway commits terminal state to PostgreSQL before sending a public terminal frame.
- `ResponseItems` is the single authority for call/output pairing and safe history cuts.
- Nested programmatic tool calls execute only when their frozen tool descriptor permits `programmatic` callers.
- Exhausting `max_tool_calls` never fabricates a synthetic `response.incomplete` terminal.
- Completing a Response never completes the triggering Signal on its own.
- Planning compaction never mutates stored history ahead of the admission transaction.
- Unmatched tool results land in `error` rows and never enter provider replay.
- Orphaned `generating` rows reconcile to retryable `error` rows.
- Agent token-quota rejections fire before provider/credential selection and touch zero credentials.
