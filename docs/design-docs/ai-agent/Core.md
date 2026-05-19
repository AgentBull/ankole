# AIAgent core

AIAgent Core is the runtime boundary that lets an `ai_agent` Target handle one
TargetSession side-channel entry by writing Conversation and Message business
records, rendering model input, calling `req_llm`, executing allowed tools,
producing visible output, and recording safe outcomes. The Agentic Loop stays
inside AIAgent or SubAgent execution. It is not EventBus routing, a
TargetSession, a Channel Adapter, or a Workflow Node expansion.

The v1 design keeps the Core deliberately small. Core owns AIAgent profile
validation, Conversation and Message persistence, prompt rendering orchestration,
token accounting, model calls, ToolSet expansion, the model/tool loop, streaming
production, delivery handoff, idempotency, and recovery. ACL rules, slash
commands, context compression and prompt caching, system prompt assembly, and
ambient Event policy are separate AIAgent companion designs consumed by Core.

## Scope

This document defines:

- AIAgent as the `ai_agent` Target entry point and return semantics.
- How `target_type = "ai_agent"` and `target_ref` connect EventBus routing to an
  Agent Principal.
- The `agents.profile.ai_agent` fields consumed by AIAgent runtime.
- Conversation and Message durable business records owned by AIAgent Core.
- Conversation key derivation for addressed and ambient IM Events.
- Message meta context building for time awareness, ambient context, and actor
  context.
- Prompt rendering orchestration, active branch rendering, token accounting,
  and `req_llm` request projection.
- The boundary with AIAgent companion designs:
  `./ACL.md`, `./SlashCommands.md`,
  `./ContextCompressionAndCaching.md`, `./SystemPromptBuilder.md`, and
  `./AmbientAndEventMessages.md`.
- ToolSet expansion, tool execution, SubAgent delegation, visible reply
  delivery, TargetSession output stream production, idempotency, failure, and
  recovery behavior.
- Implementation handoff and verification expectations.

## Non-goals

This document does not define:

- EventBus acceptance, CloudEvents validation, `RoutingContext`, matcher,
  Event Routing Rule priority, Blackhole, TargetSession side-channel storage,
  the TargetSession Oban worker, or EventBus stream buffer internals.
- Channel Adapter inbound acknowledgement, provider protocol handling, login,
  signature verification, upload, provider command, listen-mode, or outbound
  rendering internals.
- Business handling for world Events such as webhooks, market Events,
  operational Events, or domain state changes. AIAgent v1 records safe
  diagnostics and returns for unsupported Event types. Provider-directed action
  submissions are user-facing inputs when routed to AIAgent, not world Event
  business handlers.
- Workflow Node DSL, Wait Node, approval node, Workflow storage, or Workflow
  canvas behavior.
- AIAgent ACL grants, privileged elevation, approval UI, credential stores,
  external API adapters, or independent audit subsystems.
- Real external tool implementations, their provider-specific schemas, result
  ranking, or usage accounting. V1 defines the ToolSet, registry, dispatcher,
  ACL, tool-result, timeout, parallel-safety, and idempotency contracts with one
  fake test tool only.
- LLMProvider catalog storage, provider credential encryption, plugin provider
  registration, or the `req_llm` bridge.
- Context compression, summary overlay, prompt caching, system prompt assembly,
  slash command catalog, ambient batching, ambient brief, ambient recall, or
  unsupported Event policy internals.
- Operator UI, branch UI, manual recovery UI, or prompt editing UI.

## Runtime boundaries

EventBus accepts decoded CloudEvents, matches the first applicable Event Routing
Rule by priority, creates or reuses a TargetSession, appends one side-channel
entry, and ensures an alive TargetSession worker exists. EventBus does not
understand AIAgent reasoning, execute tools, write Conversation records, or turn
Target failure into business failure.

TargetSession is an execution window. It may deliver several side-channel
entries to the same AIAgent in stable order, but each callback receives one
entry. Business continuity lives in Conversation, Message, Work, ChildRun,
Artifact, Brain, future Budget, and domain records. After a TargetSession closes,
expires, or fails, later replies, callbacks, and child work completions re-enter
BullX as new Events.

Channel Adapter remains a transport boundary. It may normalize provider input
into CloudEvents, call EventBus, deliver outbound messages, or consume output
streams. It must not create TargetSessions, inspect AIAgent internal state, write
Conversation transcripts, decide whether an AIAgent operation is allowed, or
infer business completion.

LLMProvider is a provider/catalog support layer. AIAgent stores model specs in
its profile and resolves them through `BullX.LLM.Catalog.resolve_model_spec/1`.
Core consumes the returned `model_input` and base `req_llm` options, then adds
call-specific prompt, tools, tool choice, generation options, reasoning effort,
and validated `provider_options`. LLMProvider does not own prompts, model/tool
loops, TargetSession behavior, ACL, usage policy, or AIAgent identity.

Principal is the accountability boundary. An AIAgent normally has its own Agent
Principal. For an Event Routing Rule with `target_type = "ai_agent"`,
`target_ref` is the Agent Principal id. SubAgent execution is a delegated child
Agentic Loop and is not a new Agent Principal by default. Target execution must
preserve the triggering Principal, executing Agent Principal, and on-behalf-of
relationship instead of collapsing them into one ambiguous field.

## AIAgent profile

`agents.profile` is the durable configuration entry point for AIAgent runtime.
Principal storage guarantees only that the profile is a JSONB object; AIAgent
Core owns casting and validation for the `ai_agent` object.

```json
{
  "ai_agent": {
    "main_model": "openai_proxy:gpt-5.4",
    "main_model_reasoning_effort": "medium",
    "compression_model": null,
    "compression_model_reasoning_effort": "low",
    "heavy_model": null,
    "heavy_model_reasoning_effort": "high",
    "mission": "...",
    "ambient_intent_system_prompt": "",
    "soul": "...",
    "instructions": "...",
    "conversation_isolation_mode": "scene",
    "unmentioned_group_messages": "observe_only",
    "daily_reset": {
      "enabled": true,
      "hour": "04:00",
      "timezone": "Asia/Shanghai",
      "retry_minutes": 30
    },
    "context": {
      "max_turns": 50,
      "compression_threshold_ratio": 0.70,
      "prompt_cache": true,
      "time_awareness_granularity": "hour"
    },
    "acl": {
      "elevation_strategy": "deny"
    },
    "toolsets": {
      "web_research": {
        "enabled": true,
        "access": "ordinary",
        "tools": {
          "web_search": {
            "access": "privileged"
          }
        }
      }
    }
  }
}
```

Profile rules:

- `main_model` is required and is resolved by
  `BullX.LLM.Catalog.resolve_model_spec/1`.
- `compression_model` and `heavy_model` default to `main_model` when null.
- `main_model_reasoning_effort`, `compression_model_reasoning_effort`, and
  `heavy_model_reasoning_effort` are stored as strings and cast to one of
  `:none`, `:minimal`, `:low`, `:medium`, `:high`, or `:xhigh`.
- Reasoning effort remains independently effective even when the compression or
  heavy model falls back to the same resolved model as `main_model`.
- `mission`, `soul`, and `instructions` are request-time prompt inputs passed
  through `./SystemPromptBuilder.md`. They are not Conversation Messages and do
  not participate in compression. `mission` describes long-term responsibility,
  not the current run objective.
- `ambient_intent_system_prompt` is an optional supplement for the ambient
  intent recognizer defined by `./AmbientAndEventMessages.md`. It does not
  replace main model instructions, change Event routing, or become a Message.
- `conversation_isolation_mode` controls whether addressed IM user turns share a
  scene Conversation or split by normalized external actor. V1 supports `scene`
  and `actor`, with `scene` as the default.
- `unmentioned_group_messages` controls handling for
  `bullx.im.message.ambient`. V1 supports `observe_only` and `may_intervene`,
  with `observe_only` as the AIAgent Core default when the profile omits the
  field. Setup or another operator-facing profile writer may intentionally set
  `may_intervene` as a product default for the Agent it creates.
- `daily_reset.hour` is local wall-clock time in `HH:MM`; `daily_reset.timezone`
  must be an IANA timezone.
- `context.max_turns` caps model/tool recursion for one handled entry.
- `context.compression_threshold_ratio` is between 0 and 1. Compression and
  prompt cache semantics belong to `./ContextCompressionAndCaching.md`.
- `context.prompt_cache` is a BullX AIAgent profile/rendering option consumed by
  `./ContextCompressionAndCaching.md`. It is not a `ReqLLM.Context` field; when
  no `req_llm` provider-specific mapping applies, rendering continues without
  BullX-added prompt cache hints.
- `context.time_awareness_granularity` supports `minute`, `hour`, `day`, and
  `off`, defaulting to `hour`. It affects rendered user-like model input only.
- `acl.elevation_strategy` is defined by `./ACL.md`. V1 only allows `deny`.
- `toolsets` declares enabled ToolSets, default access tags, and per-tool access
  overrides. These tags describe operation requirements; they do not grant the
  caller permission.
- Unknown fields in `agents.profile.ai_agent` are ignored. They are not errors,
  not rendered into provider input, and not copied into runtime policy.
- Unknown ToolSets and unknown tools under `toolsets` are ignored at runtime.
  They do not render schemas and cannot execute.

Executable defaults and ranges:

| Field | Default | Allowed values | Runtime meaning |
| --- | --- | --- | --- |
| `conversation_isolation_mode` | `scene` | `scene`, `actor` | Addressed IM Conversation isolation mode. |
| `unmentioned_group_messages` | `observe_only` | `observe_only`, `may_intervene` | Ambient IM handling mode. |
| `daily_reset.enabled` | `true` | boolean | Enables profile-local daily Conversation reset. |
| `daily_reset.retry_minutes` | `30` | integer `1..720` | Retry delay for Conversations skipped because generation is active. |
| `context.max_turns` | `50` | integer `1..200` | Maximum model/tool recursion depth while handling one entry. |
| `context.compression_threshold_ratio` | `0.70` | number `> 0` and `< 1` | Fraction of safe context limit used before compression is considered. |
| `context.prompt_cache` | `true` | boolean | Allows BullX to add provider-supported prompt cache hints. |
| `context.time_awareness_granularity` | `hour` | `minute`, `hour`, `day`, `off` | Granularity for rendered time-awareness context. |
| `acl.elevation_strategy` | `deny` | `deny` | V1 denial behavior for missing access or privileged-operation grant. |

Installation defaults come from the Configuration boundary. Profile overrides
are consumed inside AIAgent runtime and do not change Principal storage
semantics.

Invalid profile data prevents model calls and external side effects. AIAgent
Core records a safe failure with `BullX.EventBus.TargetSession.fail/2`, returns
`:ok`, and lets TargetSession progress advance instead of retrying an
unrecoverable configuration error. A disabled Agent Principal cannot run as an
AIAgent Target.

## ToolSet profile

ToolSet is Core's batch configuration layer for tools. ACL does not expand
ToolSets; Core computes the tools available to the current request from the
profile, registry, and ACL result.

Rules:

- Every tool has exactly one owning ToolSet. V1 does not allow orphan tools.
- AIAgent can use only enabled ToolSets in its profile.
- A ToolSet may declare a default access tag: `ordinary` or `privileged`.
- A tool may override its owning ToolSet access tag.
- Disabled ToolSets and disabled tools are not rendered to provider input and
  cannot execute.
- Access tags define whether an operation is ordinary or requires an extra
  privileged-operation grant.
- Caller permission comes from the ACL gate defined by `./ACL.md`.
- A new tool must be registered under a ToolSet before any AIAgent can render or
  execute it.

Effective access is computed in this order:

```text
disabled tool or disabled ToolSet -> disabled
per-tool profile override         -> ordinary | privileged
ToolSet profile default           -> ordinary | privileged
ToolSet registry default          -> ordinary | privileged
```

V1 does not support one tool shared by multiple ToolSets. If the same underlying
implementation needs different risk levels, expose distinct tools such as
`bi_query_public_metric` and `bi_query_revenue`.

Before provider request rendering, Core filters tools with the ACL result:

```text
agent access denied
  -> do not run the model/tool loop
agent access allowed, no privileged-operation grant
  -> render ordinary tools only
agent access allowed, privileged-operation grant present
  -> render ordinary and privileged tools
```

The same effective access tag must be checked again before tool execution.
Unknown, disabled, malformed, stale, or never-rendered provider tool calls become
structured tool-result errors unless the current loop policy requires terminal
failure.

## Tool registry and dispatcher

V1 ships the AIAgent tool registry and dispatcher contract with one fake tool
used by tests. It does not ship real external tools and does not require a
future Capability governance layer before the loop can be implemented.

The registry is code-owned and reconstructible. It has no PostgreSQL table,
runtime plugin discovery requirement, or operator-editable state in v1. Core uses
these functions:

```elixir
BullX.AIAgent.Tools.Registry.list_toolsets()
BullX.AIAgent.Tools.Registry.list_tools()
BullX.AIAgent.Tools.Registry.get_tool(tool_name)
BullX.AIAgent.Tools.Registry.tools_for_toolset(toolset_id)
```

`tool_name` is both the BullX registry id and provider-visible function name in
v1. It must satisfy `ReqLLM.Tool.valid_name?/1`; dotted names such as
`web.search` are not v1 AIAgent tool names. If a later design wants separate
BullX ids and provider names, it must define the mapping and recovery behavior.

A registry entry has this shape:

```elixir
%{
  name: "web_search",
  toolset_id: "web_research",
  description: "Fake search tool used by AIAgent loop tests.",
  parameter_schema: [
    query: [type: :string, required: true, doc: "Search query"]
  ],
  default_access: :ordinary,
  timeout_ms: 30_000,
  parallel_safe: true,
  module: BullX.AIAgent.Tools.FakeSearch
}
```

`parameter_schema` is the value passed to `ReqLLM.Tool.new/1`. It may be a
NimbleOptions keyword list or a JSON Schema map supported by `req_llm`.
`description` must be safe to show to the model and must not contain secrets,
private policy data, or raw provider payloads.

Tool modules implement:

```elixir
@callback execute(map(), BullX.AIAgent.Tools.Context.t()) ::
            {:ok, ReqLLM.ToolResult.t() | String.t() | map() | list()}
            | {:error, BullX.AIAgent.Tools.Error.t()}
```

The context is built by Core and contains only explicit runtime facts:

```elixir
%BullX.AIAgent.Tools.Context{
  caller_principal_id: caller_principal_id,
  agent_principal_id: agent_principal_id,
  conversation_id: conversation_id,
  source_type: source_type,
  source_id: source_id,
  tool_call_id: tool_call_id,
  tool_name: tool_name,
  effective_access: :ordinary,
  timeout_ms: 30_000,
  idempotency_key: idempotency_key,
  metadata: %{}
}
```

The idempotency key is deterministic and derived by Core from stable business
ids: Conversation id, assistant Message id, provider tool-call id, tool name, and
canonicalized tool arguments. It is passed to the tool context before execution.
Real side-effecting tools added by a later design must use this key or a
stronger domain idempotency key. The v1 fake tool records that it received the
key and performs no external side effects.

Core renders tools by creating `ReqLLM.Tool` structs from registry entries:

```elixir
ReqLLM.Tool.new(
  name: entry.name,
  description: entry.description,
  parameter_schema: entry.parameter_schema,
  callback: {BullX.AIAgent.Tools.Dispatcher, :execute, [entry.name, context_seed]},
  provider_options: entry[:provider_options] || %{}
)
```

The dispatcher rechecks registry presence, profile enablement, effective access,
ACL result, timeout, and the tool-call name before invoking the tool module. The
current generation deadline clamps tool execution timeout. A registry entry may
explicitly opt into bounded retry for retryable tool errors; retry is off by
default. The dispatcher does not trust the rendered tool list or the model output
as authority.

Tool errors returned to the model use a structured `ReqLLM.ToolResult` output:

```json
{
  "ok": false,
  "error": {
    "code": "tool_denied",
    "message": "Tool is not available for this request.",
    "retryable": false
  }
}
```

V1 error codes are `tool_unknown`, `tool_disabled`, `tool_denied`,
`tool_malformed_arguments`, `tool_timeout`, and `tool_failed`. Error messages are
safe, short, and content-free. Private exception text, stack traces, credentials,
raw provider payloads, and private policy facts stay out of tool-result content
and telemetry.

Provider-native tools are not BullX-owned registry tools. They may be enabled
only through model/provider configuration when BullX does not need local ACL,
idempotency, dispatch, or durable tool-result records around the effect. If BullX
needs those guarantees, the behavior must be represented as a BullX-owned tool
entry instead of a provider-native tool.

## Conversation and Message

Conversation is the durable business object that expresses AIAgent conversation
continuity. TargetSession is not a Conversation. One Conversation may be touched
by multiple TargetSessions over time, and one active TargetSession may process
several Events for the same Conversation.

V1 uses two AIAgent-owned tables:

- `conversations`
- `conversation_messages`

### `conversations`

`conversations` stores the active context for one AIAgent and one normalized
conversation key.

Fields:

- `id`: UUIDv7 primary key.
- `agent_principal_id`: Agent Principal id.
- `conversation_key`: BullX-normalized key derived from Agent, channel, scope,
  thread, and profile isolation policy. It is not a raw provider id.
- `current_leaf_message_id`: current active branch leaf, nullable for an empty
  Conversation.
- `ended_at`: null means active.
- `generation`: JSONB runtime coordination object, default `{}`.
- `metadata`: JSONB non-secret business/debug metadata, default `{}`.
- `inserted_at` and `updated_at`: timestamps.

Constraints:

- UUID primary keys use `BullX.Ecto.UUIDv7`.
- `metadata` and `generation` are JSON objects.
- Active Conversations are unique by `(agent_principal_id, conversation_key)`
  where `ended_at IS NULL`.
- `current_leaf_message_id` uses a deferrable composite foreign key so the leaf
  must belong to the same Conversation.

`generation` is weak coordination metadata, not business truth. It only answers
which generation attempt may still commit output for the active Conversation. It
may hold `lease_id`, `owner_source_type`, `owner_source_id`,
`source_message_id`, `started_at`, `expires_at`, `heartbeat_at`,
`cancelled_at`, and a content-free cancellation reason. Event-derived runs
normally use `target_session_entry_id` as `owner_source_id`; ambient batch runs
use a deterministic ambient batch idempotency key. Slash command input history,
steering text, delivery state, and command responses do not live in the lease
object.

### `conversation_messages`

`conversation_messages` stores the persistent message tree that can be rendered
into provider input.

Fields:

- `id`: UUIDv7 primary key.
- `conversation_id`: parent Conversation id.
- `parent_id`: previous Message on the branch; null means root.
- `role`: `user`, `assistant`, `tool`, or `im_ambient`.
- `kind`: `normal`, `summary`, `introspection`, or `error`.
- `status`: `generating` or `complete`.
- `content`: JSONB normalized content blocks.
- `covers_range`: JSONB summary coverage marker, nullable.
- `target_session_id`: TargetSession id that accepted or produced the Message,
  nullable for maintenance records.
- `target_session_entry_id`: side-channel entry id that caused the Message,
  nullable for maintenance records.
- `event_source`: inbound CloudEvents `source`, nullable.
- `event_id`: inbound CloudEvents `id`, nullable.
- `metadata`: JSONB non-secret metadata, default `{}`.
- `inserted_at` and `updated_at`: timestamps.

Rules:

- `role`, `kind`, and `status` are closed sets. Migrations use PostgreSQL
  native enums mapped through `Ecto.Enum`, not open-ended text columns.
- `role = tool` stores tool-result blocks and follows the assistant Message that
  requested those tools. It preserves provider-required tool call ids or
  equivalent correlation fields.
- `role = im_ambient, kind = normal` stores group or channel messages that did
  not mention the AIAgent. `role = im_ambient, kind = introspection` stores an
  internal trigger generated by ambient policy and is rendered as user-like
  input.
- `kind = summary` is produced by context compression. Coverage markers,
  source leaf metadata, and overlay rendering belong to
  `./ContextCompressionAndCaching.md`.
- `kind = error` is a durable diagnostic record but is not rendered as ordinary
  provider dialogue.
- `status = generating` is an in-flight recovery marker, not business truth.
- Inbound user and ambient normal Messages dedupe by `target_session_entry_id`
  through partial unique constraints.
- Ambient introspection Messages use the ambient batch key or equivalent
  metadata for idempotency.
- `content` contains AIAgent transcript blocks and safe references only.
  Inbound Event content is projected into transcript text blocks before
  persistence. It must not inline raw provider payloads, credentials, access
  tokens, raw CloudEvents, or stream chunks.
- `metadata.brief` may store an ambient brief for a single ambient Message. It
  is not a summary Message and does not alter `content`.
- User Message time-awareness metadata records enough information to reproduce
  rendering after redelivery or restart. The rendered time prefix is not written
  back into `content`.
- Assistant, tool, and error Messages produced by AIAgent carry
  `metadata.generation.source_message_id`, `source_type`, `source_id`, and
  `root_assistant_message_id` for command recovery and branch audit. These are
  implementation metadata, not a turns table.
- Assistant model metadata stores normalized `finish_reason` and allowlisted
  provider diagnostic ids such as request or response id. Raw provider metadata
  is not persisted wholesale.

Valid v1 `role`, `kind`, and `status` combinations are:

| `role` | `kind` | `status` | Notes |
| --- | --- | --- | --- |
| `user` | `normal` | `complete` | Inbound user-like input that enters provider dialogue. |
| `assistant` | `normal` | `generating`, `complete` | Model output, including assistant tool-call requests. |
| `assistant` | `summary` | `complete` | Context compression overlay Message. |
| `assistant` | `error` | `complete` | Durable generation or recovery diagnostic that is not ordinary dialogue. |
| `tool` | `normal` | `complete` | Tool result Message, including structured tool errors. |
| `im_ambient` | `normal` | `complete` | Passive ambient observation. |
| `im_ambient` | `introspection` | `complete` | Proactive ambient trigger rendered as user-like input. |

No other combinations are valid. In particular, v1 does not use
`role = tool, kind = error`; tool failures remain `role = tool, kind = normal`
with a structured error inside the `tool_result` content block. Migrations or
changesets must reject invalid combinations, and `status = generating` is valid
only for `role = assistant, kind = normal`.

V1 `content` is a JSON array of AIAgent transcript blocks. The block union is
small and owned by Core; renderers map it to provider-specific
`ReqLLM.Message` inputs at request time.

| Block `type` | Required fields | Rendering owner | Provider input |
| --- | --- | --- | --- |
| `text` | `text` | Core history renderer | Yes, when the containing Message is rendered. |
| `tool_call` | `tool_call_id`, `name`, `arguments` | Core tool loop | Yes, as an assistant tool-call request. |
| `tool_result` | `tool_call_id`, `is_error`, `result` or `error` | Core dispatcher | Yes, as a provider-valid tool result. |
| `error` | `code`, `message`, `retryable` | Core recovery and diagnostics | No ordinary dialogue rendering. |
| `summary_text` | `text` | Context compression | Yes, only through the summary overlay rules. |
| `human_steering_note` | `text`, `command_entry_id` | Slash command runtime | Yes, only when attached to the next provider-visible result defined by `./SlashCommands.md`. |
| `omitted_marker` | `reason` | Compression or renderer | Yes, only when the renderer needs an explicit omission marker. |

`tool_call_id` is the provider tool-call id when the provider supplies one, or a
BullX-generated stable equivalent when it does not. The same correlation value
must connect `tool_call` and `tool_result` blocks. Blocks store safe normalized
facts only; raw provider payloads, raw CloudEvents, credentials, bearer-like
reply handles, and stream chunks stay out of `content`.

Inbound `NormalizedCloudEvent.data.content` is not copied into Message content
as a second schema. Core applies one deterministic transcript projection before
writing `role = user, kind = normal` or `role = im_ambient, kind = normal`:

- `text.text` becomes a `text` block.
- `card.fallback_text` becomes a `text` block; `card.payload` remains structured
  Event evidence and is not ordinary dialogue text.
- `action.text` becomes a `text` block; `action_id` and `values` remain
  structured Event evidence and are not ordinary dialogue text.
- Media `fallback_text` becomes a `text` block in v1. Image and multimodal
  provider input is intentionally not passed through to the model as image
  content until a separate multimodal design defines retrieval, permissions,
  and prompt rendering.
- If every normalized part projects to empty text, Core writes an
  `omitted_marker` instead of fabricating user dialogue.

Active branch resolution starts from `current_leaf_message_id`, resolves any
summary leaf to `metadata.source_leaf_message_id`, walks the raw `parent_id`
chain back to root, then reverses that raw path into branch order. The renderer
then selects at most one compatible summary overlay whose source leaf and covered
range lie on that raw branch. A summary Message's `parent_id` is a physical
placement pointer, not dialogue order.

## Conversation key

`conversation_key` is an implementation key, not product identity. Core derives
it from the accepted CloudEvent `data` object, not from raw adapter payloads or
side-channel routing projections. Equivalent normalized inputs must produce
the same key.

The resolved key parts are:

- `lane`: `addressed` or `ambient`.
- `agent_principal_id`.
- normalized `data.channel.adapter`, `data.channel.id`, and `data.channel.kind`.
- normalized `data.scope.id` and `data.scope.thread_id`.
- resolved isolation mode: `scene` or `actor`.
- normalized `data.actor.external_account_id` only when addressed IM uses
  resolved isolation mode `actor`.

`conversation_isolation_mode = "scene"` is the default because an AIAgent is a
digital colleague working in the shared scene, not a separate private assistant
per group speaker. `conversation_isolation_mode = "actor"` is an explicit
profile choice for addressed IM user turns that need per-external-actor
isolation. If `actor` mode is selected and the addressed Event has no normalized
external actor id, Core fails the entry with a safe configuration or input-shape
error before model calls or external side effects.

| Normalized Event | Lane | Resolved isolation | Actor part |
| --- | --- | --- | --- |
| DM addressed | `addressed` | profile mode, default `scene` | empty for `scene`; `data.actor.external_account_id` for `actor` |
| Group mention addressed | `addressed` | profile mode, default `scene` | empty for `scene`; `data.actor.external_account_id` for `actor` |
| Thread reply addressed | `addressed` | profile mode, default `scene` | empty for `scene`; `data.actor.external_account_id` for `actor` |
| Ambient group or channel | `ambient` | forced `scene` | always empty |

Ambient IM Events always use the Agent plus normalized IM scene to derive an
active ambient Conversation. Core does not put the ambient speaker into the key
and does not copy one ambient Message into many per-actor Conversations. The
`lane` part keeps ambient scene Conversations distinct from addressed scene
Conversations. When a later addressed user turn needs group context,
`./AmbientAndEventMessages.md` provides ambient reference recall across the same
Agent and IM scene.

Core serializes key parts with fixed length-prefixed UTF-8 encoding and hashes
that byte string with `BullX.Ext.generic_hash/1`. The stored key is:

```text
"v1:" <> BullX.Ext.generic_hash(serialized_parts)
```

The serialized input is:

```text
"ai_agent_conversation:v1"
<> byte_size(lane) <> ":" <> lane
<> byte_size(agent_principal_id) <> ":" <> agent_principal_id
<> byte_size(channel_adapter) <> ":" <> channel_adapter
<> byte_size(channel_id) <> ":" <> channel_id
<> byte_size(channel_kind_or_empty) <> ":" <> channel_kind_or_empty
<> byte_size(scope_id) <> ":" <> scope_id
<> byte_size(thread_id_or_empty) <> ":" <> thread_id_or_empty
<> byte_size(resolved_isolation) <> ":" <> resolved_isolation
<> byte_size(actor_external_account_id_or_empty) <> ":"
<> actor_external_account_id_or_empty
```

`byte_size(...)` is encoded as decimal ASCII digits and measures UTF-8 bytes.
Implementations must use the same byte encoding in golden tests. Stored
`conversation_key` values are ASCII `v1:` plus lowercase hex and contain no NUL.
Implementations must not persist a NUL-separated composite key in PostgreSQL
`text` or `jsonb`, and normalized string inputs containing NUL are invalid for
conversation key derivation.

Core may store the safe resolved parts under
`conversations.metadata.conversation_key_parts` for debugging. Metadata does not
participate in uniqueness and must not become a routing surface. Routing remains
owned by EventBus and Event Routing Rules.

## Target entry flow

The callback shape remains the EventBus Target contract:

```elixir
Target.handle_event(invocation, side_channel_entry) ::
  :ok | {:error, term()}
```

AIAgent v1 handles one entry in this order:

```text
Target.handle_event(invocation, entry)
  -> resolve target_ref to an active Agent Principal
  -> cast and validate agents.profile.ai_agent with Installation defaults
  -> normalize accepted CloudEvent content and Principal evidence for AIAgent use
  -> classify the Event through AmbientAndEventMessages policy
  -> return after safe diagnostics for unsupported Events
  -> derive conversation_key
  -> find or create the active Conversation
  -> dedupe inbound entry by target_session_entry_id
  -> append inbound user or im_ambient Message when applicable
  -> route AIAgent command inputs to the command control path without writing a Message
  -> handle command, ambient observe-only, or unsupported paths when applicable
  -> acquire a Conversation generation lease when a model run is needed
  -> render prompt context from active branch, Work, and entry context
  -> call context compression if token limits require it
  -> resolve the model spec through BullX.LLM.Catalog
  -> run the model/tool loop under ACL and max_turns
  -> persist assistant, tool, error, and business records
  -> release the generation lease
  -> request TargetSession close or fail when appropriate
```

`Target.handle_event/2` returning `:ok` means EventBus and TargetSession
progress can advance. It does not mean the business outcome succeeded. Business
failure is recorded in AIAgent-owned records. Retryable infrastructure failure
returns `{:error, reason}` and follows TargetSession retry semantics.

AIAgent consumes:

- accepted CloudEvent `id`, `source`, `type`, `time`, and `data`
- `data.content`, `data.channel`, `data.scope`, `data.actor`, `data.refs`,
  `data.reply_channel`, and `data.routing_facts`
- TargetSession ids and close/fail/output helpers from `invocation`
- Principal or actor evidence passed by EventBus for downstream policy

AIAgent must not route on CloudEvents `subject`, parse provider raw payloads,
read EventBus matcher internals, or dispatch from database module names.
AIAgent treats `docs/design-docs/eventbus/NormalizedCloudEvent.md` as the
normalized inbound data contract.

## Generation source contract

Core uses one generation runner for Event-derived user turns, ambient proactive
turns, and command-driven retries. The runner input is explicit and does not
infer source state from process-local context:

| `source_type` | `source_id` | TargetSession ids | Reply channel |
| --- | --- | --- | --- |
| `target_session_entry` | `target_session_entry_id` | Required from invocation. | From accepted Event `data.reply_channel`. |
| `ambient_batch` | Deterministic processed-batch idempotency key. | Absent. | Captured session-level ambient `reply_channel` hint. |
| `command_retry` | Command entry id. | Optional; present only when the command came from a TargetSession entry. | Reuses the retried source Message delivery context when still valid. |

The runner always receives `agent_principal_id`, `conversation_id`,
`source_message_id`, triggering Principal evidence, safe caller context, and the
resolved `reply_channel` hint if one is available. Event-derived runs may also
carry `target_session_id` and `target_session_entry_id`; ambient batch runs must
not fabricate those identifiers because the Redis batch worker is not a
TargetSession Target invocation.

For `source_type = ambient_batch`, the source id identifies the processed batch,
not the long-lived ambient Conversation. Reprocessing the same Redis batch must
reuse the same source id, while later batches in the same ambient Conversation
must receive different source ids. The triggering Principal and safe caller
context are the Agent Principal itself. Ambient message speakers remain evidence
and context only; they are not the ACL caller for proactive generation.

Generated assistant, tool, and error Messages write
`metadata.generation.lease_id`, `source_type`, `source_id`,
`source_message_id`, and `root_assistant_message_id`. Event-derived Messages may
also write `target_session_id` and `target_session_entry_id`. Ambient batch
Messages leave those TargetSession fields null and rely on the deterministic
batch idempotency key for recovery and outbound idempotency.

## Event message boundary

AIAgent v1 treats `bullx.im.message.addressed` as the IM Event that enters the
main Agentic Loop directly. DMs, group mentions, and provider-native direct
message interactions are normalized into this Event type. Core stores the input
as `role = user, kind = normal`, or handles a leading AIAgent-owned slash token
as a control command without writing a Conversation Message. DM and group
mention differences affect `reply_channel`, conversation key, scope, and message
meta context; they do not create separate AIAgent runtime modes.

AIAgent v1 also treats `bullx.action.submitted` as a directed user input when an
Event Routing Rule sends it to an AIAgent Target. The normalized `action.text`
projection becomes the transcript text block. Structured action identifiers and
sanitized values remain structured Event facts referenced through the Message
source identifiers; they are not expanded into prompt-private raw payloads. This
lets provider cards, buttons, and approval clicks continue the same Conversation
without requiring adapters to forge IM text messages.

AIAgent v1 also consumes `bullx.command.invoked` when EventBus routes that Event
to `target_type = "ai_agent"` and the normalized command name belongs to the
AIAgent command catalog. This Event is command control input only. It does not
append a user Message, does not enter provider dialogue, and does not go through
a generic Command Target delegation path. Unknown AIAgent command names produce
a safe command diagnostic without being reinterpreted as ordinary user text.

Ambient utterances, unsupported Events, 30-second batching, ambient brief,
ambient reference recall, and proactive intervention policy are owned by
`./AmbientAndEventMessages.md`. Core consumes only the stable outcomes:

- `role = im_ambient, kind = normal` for passive ambient records.
- `role = im_ambient, kind = introspection` for proactive user-like triggers.
- Ambient reference context sources passed to Message Meta Context Builder.
- Unsupported Event outcomes that log safe diagnostics or telemetry and return
  `:ok` without calling the model.

## Slash command boundary

`./SlashCommands.md` defines the AIAgent-owned command catalog, default tokens,
localized aliases, control operation contract, active-generation semantics, and
canonical `new`, `compress`, `retry`, `steer`, `stop`, and `undo` behavior.
Core provides runtime primitives for that design:

- Detect AIAgent-owned leading slash tokens in addressed IM Events and consume
  `bullx.command.invoked` Events routed directly to this AIAgent.
- Keep slash command inputs and command responses out of
  `conversation_messages`.
- Run the command ACL gate before execution.
- Cancel generation leases for preemptive commands such as `new` and `stop`.
- Rewind active leaves for branch commands such as `retry` and `undo` while
  preserving raw Message evidence.
- Let `steer` provide live control input to the active runtime loop without
  writing a durable Message.
- Call manual compression handoff for `compress`.

Slash commands are control-plane inputs, not Agent durable Messages. They do not
enter ordinary provider dialogue. Command Target, Channel Adapter, EventBus, and
LLMProvider must not edit AIAgent Conversation internals, write summary
Messages, move Conversation leaves, or change generation leases.

Before committing assistant/tool/error Messages, starting visible output, or
handing off outbound delivery, a running model/tool loop must recheck the
generation lease and Conversation active state. If a command cancelled the lease,
the lease expired, or the Conversation ended, late output must not be written to a
fresh Conversation or appended to an ended branch.

## Daily reset

Daily reset is Conversation hygiene, not TargetSession identity. It closes stale
active Conversations at a profile-local service-day boundary so the next Event
starts a fresh Conversation while old Messages remain queryable.

Eligibility compares last Conversation activity against the profile-local daily
reset boundary. V1 defines last activity as the latest completed Conversation
Message `updated_at`; when no completed Message exists, it uses
`conversations.updated_at`.

The boundary is computed from BullX runtime time, `daily_reset.timezone`, and
`daily_reset.hour`. CloudEvent occurrence time is not reset truth. If current
local time is before the configured hour, today's boundary is the previous day's
configured hour.

Scheduler owns production of Time Events. AIAgent Core owns the shared
eligibility helper and the maintenance path. Scheduled maintenance and lazy
pre-entry checks must use the same logic:

1. Find active Conversations eligible by timezone, hour, and last activity.
2. Skip Conversations with active non-expired generation leases.
3. Retry skipped Conversations after `daily_reset.retry_minutes`.
4. Close eligible Conversations by setting `ended_at` and
   `metadata.end_reason = "daily_reset"`.
5. Do not delete Messages or create lineage records.

The Redis ambient batch from `./AmbientAndEventMessages.md` is not a generation
lease. Daily reset does not scan Redis, add a lease for pending batches, or wait
for them. If reset closes an ambient Conversation first, a later batch worker
drops the proactive opportunity during active-state recheck. If the batch worker
has already created an introspection Message and entered generation, the normal
generation lease prevents reset from closing a Conversation that can still
receive results.

Daily reset must never close a Conversation that can still receive generation
output.

## Message Meta Context Builder

`BullX.AIAgent.MessageContextBuilder` is Core's request-time builder for
per-message context. It centralizes time awareness, ambient background, and user
identity context so prompt rendering does not concatenate these fragments in
multiple places.

Inputs are prepared by Core and companion designs:

- The current inbound Message and `metadata.time_awareness`.
- Ambient reference context from `./AmbientAndEventMessages.md`.
- Triggering Principal, IM actor, scope, and safe display metadata.
- Later user identity context. DM identity context may become a
  system-prompt-eligible section; group speaker context stays as a current
  user-like Message prefix so one group member is not promoted into global
  system fact.

Outputs are typed placement blocks:

- `message_prefix` blocks inserted before the current user-like Message content.
- `system_prompt_section` blocks passed to `./SystemPromptBuilder.md`.

The builder does not query EventBus, read adapter raw payloads, call LLMs,
perform retrieval, or own System Prompt Builder ordering. It validates and
places already prepared safe inputs.

### Time-aware user Messages

Time awareness is a `message_prefix` block. It gives the model the send time for
long conversations without moving current time into system prompt, EventBus,
TargetSession, Adapter, or LLMProvider.

`context.time_awareness_granularity` controls injection:

- `off`: no time prefix.
- `day`: day-level prefix.
- `hour`: hour-level prefix.
- `minute`: minute-level prefix.

Formatting uses the BullX Installation runtime timezone from Configuration. V1
does not add per-Agent timezone override and does not reuse
`daily_reset.timezone` for time-aware rendering.

`send_at` comes from normalized inbound message send time when available; else
it uses BullX runtime time when accepting the user Message. Rendering converts
to Installation timezone and truncates to minute.

Only `role = user, kind = normal` Messages that enter provider dialogue can
receive the prefix. Commands, errors, and tool Messages do not.

Injection is computed from the previous time-injected user Message on the same
active branch:

- The first eligible user Message on a branch is injected.
- `minute` injects when `send_at` is at least 1 minute after the previous
  injected `send_at`.
- `hour` injects when `send_at` is at least 1 hour after the previous injected
  `send_at`.
- `day` injects when `send_at` is at least 1 day after the previous injected
  `send_at`.
- Later user Messages before the boundary are not injected.
- A fresh Conversation created by `new` restarts the first-message rule.

If the current leaf is a summary, Core follows the summary overlay's raw branch
recovery to find the previous real user Message with
`metadata.time_awareness.injected = true`. Summary time ranges do not replace
that source.

The prefix is rendered as a leading text block in the same user Message and is
followed by one newline. It is not a separate Message and does not use the
system role.

```text
<meta>send_at: 2026-05-18</meta>
original user content
```

```text
<meta>send_at: 2026-05-18 14:35</meta>
original user content
```

`day` uses `YYYY-MM-DD`; `hour` and `minute` use `YYYY-MM-DD HH:MM`.

## Prompt rendering

Prompt rendering constructs provider input at call time. Rendered prompt
snapshots are not persisted unless a later debugging design explicitly adds
that contract. Conversation and Message rows remain BullX durable truth;
`ReqLLM.Context`, `ReqLLM.Message`, and content part structs are request-time
projections.

Core owns the orchestration:

- Resolve the active raw branch and apply at most one compatible summary overlay.
- Call Message Meta Context Builder for user-like Messages.
- Validate tool-call and tool-result pairing.
- Compute executable tool definitions from ToolSet, ACL, and registry state.
- Call `./SystemPromptBuilder.md` with typed input blocks.
- Generate a `req_llm`-compatible request.

Prompt inputs include:

- Profile fields such as mission, soul, instructions, model settings, and
  ToolSet hints.
- Invocation context such as Principal evidence, TargetSession ids, scope/window
  keys, and safe routing metadata.
- Current inbound Message, time-awareness metadata, ambient reference context,
  actor context, and later user identity context.
- Active branch Conversation history after summary overlay.
- Relevant Work, Task, ChildRun, and Artifact references.
- Executable tool definitions passed through the provider `tools` option, not
  freeform prompt text.

Rules:

- System prompt content is assembled only by `./SystemPromptBuilder.md` from
  typed request-time inputs. Core consumes the `:system` content and stable
  prefix boundary.
- Core renders Conversation history into `:user`, `:assistant`, and `:tool`
  roles supported by `req_llm`. It does not invent unsupported provider roles.
- `role = im_ambient, kind = introspection` renders as user-like input.
  `role = im_ambient, kind = normal` enters provider input only through ambient
  context, not as ordinary dialogue.
- `kind = error` is skipped as dialogue. Explicit recovery logic may inject a
  safe summary of recent errors.
- `kind = summary` is rendered only through the summary overlay rules. Core does
  not render a summary Message at its physical parent-chain position.
- User-like Messages always pass through Message Meta Context Builder before
  rendering.
- DM user identity context may become a system-prompt section; group speaker
  context must remain a message prefix.
- Tool-call assistant Messages must have matching tool-result blocks in provider
  input. Recovery, branch rendering, truncation, and compression must not leave
  orphan tool results or orphan tool calls.
- Executable tool availability is computed by Core from ToolSet and ACL state.
  Freeform prompt instructions do not grant tools.
- Request-time provider input omits credentials, private policy internals, raw
  provider payloads, and raw CloudEvents.
- Provider-native prompt cache markers are produced by
  `./ContextCompressionAndCaching.md` from the System Prompt Builder stable
  prefix boundary and are attached only through `req_llm`-supported content
  metadata or validated provider options. Core does not patch raw HTTP bodies.

## Token accounting

Token accounting estimates context size before provider calls and captures
provider-reported usage after calls. Counts are metadata for diagnostics,
compression triggers, future Budget accounting, and future optimization. They
are not routing facts.

Core owns estimation, provider usage capture, safe context limit selection, and
safe usage metadata. It does not own summary overlay selection, compression
prompts, prompt cache marker generation, or cache invalidation.

Pre-call estimation runs after summary overlay, request-time large result
compaction, and provider-structure validation. It uses model metadata when
available, a conservative BullX estimator, and reserved output/tool overhead.
Prompt cache hints are not added before estimation and must not change the
estimated input object.

The conservative estimator is intentionally simple and content-shape aware. Text
blocks use a padded character or byte-length estimate. Tool results are estimated
from the provider-renderable result after request-time large-result compaction,
plus correlation and JSON overhead. Image, document, audio, and other non-text
blocks use provider metadata when available and otherwise use fixed high-cost
class estimates. Tool schemas, system prompt blocks, and expected tool-followup
output reserve their own overhead. The estimator may trigger compression early;
provider-reported usage remains authoritative after the call.

Post-call usage comes from `req_llm` surfaces:

- Non-streaming calls read `ReqLLM.Response.usage(response)`.
- Streaming calls read `ReqLLM.StreamResponse.usage(stream_response)` after
  stream metadata completes, or `ReqLLM.Response.usage(response)` when the stream
  is materialized.

Stored normalized fields may include `input_tokens`, `output_tokens`,
`total_tokens`, `cached_tokens`, `cache_creation_tokens`, `reasoning_tokens`,
`input_cost`, `output_cost`, and `total_cost` when `req_llm` returns them.
Provider-reported usage sets `usage_source = "provider_reported"`; missing usage
stores estimator metadata with `usage_source = "estimated"`. Core must not parse
raw provider responses to invent usage fields.

Main, tool-followup, compression, and heavy auxiliary model calls use the same
usage capture path. Usage metadata is written to the Message that records the
call outcome and must not contain prompt content, stream chunks, credentials,
raw provider payloads, or plaintext secrets.

When estimated input exceeds the active model's safe context limit, Core calls
`./ContextCompressionAndCaching.md`. Compression failure is a generation failure:
Core writes a safe `kind = error` Message, releases the lease, and returns `:ok`
if the failure has been durably recorded. It must not invent a fake summary. Core
also carries the per-generation or per-entry compression attempt count used by
the companion failure guard, so a single entry cannot loop indefinitely through
estimation, prompt-too-long, and retry handling.

## Model and provider runtime

AIAgent resolves model specs through:

```elixir
BullX.LLM.Catalog.resolve_model_spec(spec)
```

Core records safe model metadata such as provider id, model id, request id,
usage, finish reason, reasoning metadata, and safe diagnostics on Messages.
Plaintext API keys, provider credentials, and raw provider payloads are never
stored in Conversation metadata.

Non-streaming generation uses `ReqLLM.generate_text/3`. Streaming generation
uses `ReqLLM.stream_text/3` and materializes the final assistant result through
`ReqLLM.StreamResponse.process_stream/2` or an equivalent single-consumption
path. Normal Target processing does not use bang helpers because provider errors
must become safe AIAgent outcomes.

Core builds call-time options from profile, run policy, and rendered context.
Typical options include `tools`, `tool_choice`, `reasoning_effort`, generation
parameters, and validated call-specific `provider_options`. Static
`llm_providers.provider_options` remains endpoint/provider configuration and
must not store per-turn generation behavior.

Reasoning effort is chosen from the call scenario:

- main and tool-followup calls use `main_model_reasoning_effort`
- compression calls use `compression_model_reasoning_effort`
- heavy auxiliary calls use `heavy_model_reasoning_effort`

Provider-specific behavior must pass through supported `req_llm` surfaces:
model spec metadata, validated `provider_options`, `ReqLLM.Tool` schema/provider
options, `ReqLLM.Message.ContentPart` metadata, or a BullX-owned `req_llm`
provider override. Core must not patch raw provider JSON bodies, depend on raw
provider response payloads, or inspect `Req` internals.

`ReqLLM.Response.context` and `ReqLLM.StreamResponse.context` are convenience
values for the caller. BullX may use them to extract the normalized assistant
turn, but must not persist them as Conversation truth. Core writes its own
normalized Conversation Messages after checking the lease and Conversation
active state.

The main Agentic Loop v1 does not use `ReqLLM.Cache` application-layer response
caching. Reusing an old response could bypass ACL, tool, visibility, and recovery
decisions that Core must make for each run. Provider-native prompt caching hints
remain allowed through `./ContextCompressionAndCaching.md`.

Provider retry and fallback are allowed only before visible output starts.
Visible output has started once any user-visible TargetSession stream chunk,
Channel Adapter partial/final outbound request, or user-visible assistant
content enters the delivery boundary. After that point, the same visible reply
must not silently switch provider or model; later failure becomes a safe error,
interrupted stream, or recovery outcome.

Provider-private continuation state is not a first-class v1 model. If a selected
`req_llm` provider requires an opaque continuation handle, Core may store it as
short-term Message or Conversation metadata. It must be opaque, secret-free, and
scoped to the provider, model, Conversation, branch, and assistant Message. It is
dropped after `new`, daily reset, branch switch, model spec change, provider
fallback, or Conversation end unless a later provider-specific design states
otherwise.

## Tool loop

When a model turn returns tool calls, Core first persists an assistant Message
with tool-call blocks. It then executes tools through a Core-owned thin
dispatcher and writes tool results as `role = tool, kind = normal` Messages.

Rules:

- Core may use `ReqLLM.Tool` to build provider-compatible tool definitions.
- A `ReqLLM.Tool.execute/2` callback must be a BullX-owned thin dispatcher. It
  receives explicit triggering Principal, Agent Principal, Target, Conversation,
  entry, effective access tag, timeout, and idempotency context.
- The main Agentic Loop must not use `ReqLLM.Context.execute_and_append_tools/3`
  or any `req_llm` or provider auto-execution path that can execute tools before
  Core has persisted the assistant `tool_call` Message. `ReqLLM.Tool` is schema
  and dispatch metadata in this loop; Core calls the dispatcher only after the
  durable tool-call request exists.
- Prompt rendering must not hide business side effects inside tool callbacks.
- Provider-native tools, such as provider-hosted web search, are allowed only
  when the selected model/profile treats them as provider behavior and BullX does
  not need local ACL, idempotency, or result records around the effect.
- BullX-owned tools must belong to ToolSet and pass ACL gate.
- V1 ships no real BullX-owned external tools. The fake registry tool is enough
  to validate loop wiring, ACL filtering, tool-call/result pairing, timeout,
  parallel ordering, and recovery behavior.
- Unknown, malformed, denied, disabled, or disallowed tool calls become
  structured tool-result errors unless policy requires terminal failure.
- Tool crashes inside the tool contract become tool-result errors. Runtime
  infrastructure failures may return `{:error, reason}`.
- Tool-result Messages preserve provider-required tool call ids or equivalent
  correlation fields.
- Multiple results may be stored in one tool Message or several provider-valid
  tool Messages; the final provider input sequence must be legal for the
  selected provider.
- Tool calls are extracted from normalized `req_llm` response surfaces, not raw
  provider payloads. Core preserves provider tool-call order.
- Parallel tool execution is a default runtime capability when tool metadata
  says the calls are parallel-safe and arguments/idempotency keys do not
  conflict. Calls whose safety cannot be determined run serially or return a
  structured error.
- Parallel results are written in original tool-call order, not completion
  order.
- `parallel_safe` defaults to `false` when absent. Timeout defaults to
  `30_000` milliseconds when absent.
- Durable tool-result Messages preserve raw evidence. Prompt rendering may apply
  request-time large result compaction defined by
  `./ContextCompressionAndCaching.md`.
- Privileged operations must be privileged tools or privileged commands. V1
  denies insufficient access through `./ACL.md`; it does not create approvals,
  wait for humans, or keep TargetSession alive for elevation.

`context.max_turns`, resource limits, and repeated-tool-call detection prevent
runaway loops. At a limit, Core records a safe error or assistant Message and
stops, asks for human help, creates Work, takes another available step, or fails
the TargetSession with safe diagnostics.

## SubAgent and External Agent Harness

A short SubAgent may run inside the current TargetSession when bounded by model,
ACL, timeout, tool policy, sandbox policy, result format, and any future Budget
policy defined by the owning design. Its result is stored as tool-style evidence
or a ChildRun-linked result.

A long-running SubAgent or External Agent Harness writes a ChildRun and returns
completion, failure, or timeout through EventBus as a later Event. Parent AIAgent
must not keep one TargetSession alive for days while waiting for external work.

Codex-style External Agent Harnesses are ToolSet or Target integrations, not new
identity roots. They execute under delegated Principal and ACL boundaries.

## Visible reply delivery

AIAgent visible replies can return to the originating conversation surface only
when the generation comes from `role = user, kind = normal` or
`role = im_ambient, kind = introspection` and the trigger has a usable
`reply_channel`. `reply_channel` is a transport hint, not authorization. Core
must complete ACL, Event message policy, and delivery decision before asking an
adapter to send or stream.

Visible delivery checks the triggering Message, `reply_channel`, and Message
visibility metadata. `role = im_ambient, kind = normal` never public-replies just
because it has content. Only the `may_intervene` path from
`./AmbientAndEventMessages.md` may create an introspection Message that triggers
proactive visible reply.

The Redis ambient batch worker has no TargetSession invocation and no
TargetSession output helpers. In v1, proactive ambient replies use final Channel
Adapter outbound delivery only. Proactive streaming requires a later explicit
EventBus re-entry design.

For non-streaming replies, Core writes the final assistant Message as durable
Conversation history, builds a transport-neutral outbound request from safe
assistant content blocks, and hands it to the Channel Adapter selected by
`reply_channel.adapter` and `reply_channel.channel_id`. The adapter owns provider
rendering, provider retry, and provider errors. Core owns whether a reply should
be sent and how results are recorded as safe metadata.

For streaming replies, Core creates a TargetSession output stream. If the
adapter supports stream transport, Core starts adapter stream consumption,
appends user-visible chunks as provider output arrives, and finishes the stream
when the assistant Message reaches a terminal state. The durable transcript is
the assistant Message; stream chunks are weak runtime state.

Outbound visible reply idempotency keys are derived from assistant Message id,
generation source id, and reply-channel stable identity. Event-derived runs use
`target_session_entry_id` as the generation source id; ambient batch runs use
the deterministic ambient batch idempotency key. V1 records delivery results on
assistant Message metadata or existing business records and does not add a
delivery table.

When Core records delivery metadata on an assistant Message, it uses an
allowlisted shape:

```json
{
  "delivery": {
    "mode": "outbound",
    "adapter": "feishu",
    "reply_channel_identity": "sha256:...",
    "idempotency_key": "sha256:...",
    "status": "sent",
    "adapter_result_ref": "provider-safe-message-ref",
    "safe_error_code": null,
    "delivered_at": "2026-05-18T14:35:00Z"
  }
}
```

`mode` is `outbound` or `stream`. `status` is `sent`, `failed`, or `unknown`.
`adapter_result_ref` is optional and must be safe to store. Delivery metadata
must not include raw provider payloads, credentials, bearer-like reply tokens,
full message content, or private adapter internals.

If redelivery finds a complete assistant Message but no delivery result, Core may
retry the delivery handoff and must not rerun the model. If a provider or adapter
cannot guarantee exactly-once send, that duplicate risk is an adapter or
operator limit, not an EventBus responsibility.

If `reply_channel` is missing or the adapter does not support the requested
outbound mode, Core still records the assistant Message and a safe delivery
error. It must not bypass the Channel Adapter boundary.

## Streaming output

Core may create a TargetSession output stream while handling an entry. The stream
belongs to `target_session_id` and usually to `target_session_entry_id`.
EventBus StreamingOutput owns Redis buffer and API semantics; AIAgent is only a
producer.

Rules:

- The producer is AIAgent Target code running under the TargetSession job.
- Stream consumers do not own producer lifecycle.
- Client or provider transport disconnect is not stop or cancel.
- Before the first user-visible chunk, Core must have persisted a
  `role = assistant`, `status = generating` Message or equivalent durable
  generation record with `stream_id`, `target_session_entry_id`, and visible
  streaming-started metadata.
- Each user-visible streaming callback must recheck the generation lease and
  Conversation active state before calling `append_chunk/2`.
- User-visible chunks use `create_stream/3`, `append_chunk/2`, and
  `finish_stream/3`.
- Normal completion updates the same assistant Message to `status = complete`
  with final assistant content.
- Reasoning, progress, tool, or metadata stream events are emitted only when the
  consuming surface explicitly supports safe telemetry or fragments.
- Stream chunks are weak Redis runtime state and not Conversation, Message,
  business truth, audit, or durable replay truth.
- If the lease is cancelled, the lease expires, the Conversation ends, or visible
  streaming fails, Core best-effort cancels the `ReqLLM.StreamResponse` and
  writes durable interrupted/error outcome.
- Crash recovery for a stale visible `generating` assistant Message produces a
  safe interrupted/error outcome and best-effort finishes the stream. It does not
  rerun the same visible reply.
- V1 does not add a stream persistence table.
- Adapter live streaming consumes stream APIs. It does not create chunks, inspect
  AIAgent internals, or infer business completion from stream status.

## Idempotency, concurrency, and recovery

EventBus provides at-least-once delivery to Target. AIAgent must treat duplicate
delivery of the same side-channel entry as normal.

Required idempotency:

- Inbound user and ambient Message append dedupes by `target_session_entry_id`.
- Slash commands do not append Conversation Messages. Durable command effects
  use the state-transition semantics of the records they mutate.
- Conversation mutation is serialized by the active Conversation row and its
  generation lease.
- Tool dispatch receives idempotency keys derived from stable business ids, not
  process state. The v1 fake tool performs no external side effects; real tools
  added later must either use the Core-provided key or define a stronger
  domain-owned key.
- ChildRun, Work, Artifact, and domain writes use natural unique keys or
  explicit idempotency keys where redelivery could duplicate facts.
- A completed repeated entry must not call the model again unless durable state
  is incomplete and recovery explicitly resumes.
- Outbound visible replies use the derived delivery idempotency key. Redelivery
  may retry delivery handoff but must not rerun the model for a complete
  assistant Message.

Generation lease rules:

- The model/tool loop acquires the Conversation generation lease before appending
  a `generating` assistant Message or calling a model.
- Repo defaults are `generation_lease_ttl_ms = 600_000`,
  `generation_heartbeat_interval_ms = 30_000`, and
  `generation_max_runtime_ms = 1_800_000`.
- Installation config or Agent profile may override those values. Overrides must
  be positive finite integers, and `generation_heartbeat_interval_ms` must be no
  greater than one third of `generation_lease_ttl_ms`.
- Heartbeat extends a matching owned active lease to
  `min(now + generation_lease_ttl_ms, started_at + generation_max_runtime_ms)`.
  V1 does not allow an infinite max runtime.
- An active lease has an owner, `expires_at > now`, and no `cancelled_at`.
- An owned active lease additionally matches the runner's `lease_id`.
- An available lease is empty, expired, or cancelled. Acquire may overwrite an
  available lease under the active Conversation row lock.
- Lease records have expiration and heartbeat; crashes cannot block a
  Conversation forever. Heartbeat may only extend a matching owned active lease.
- A process that loses the lease, sees it expire, or sees it cancelled must stop
  before committing more assistant, tool, error, visible stream, or delivery
  output.
- Running loops recheck lease and Conversation active state before committing
  Messages, starting visible output, and handing off outbound delivery.
- Late provider/tool output after command cancellation or Conversation end is
  discarded from the normal branch.
- Recovery can mark stale `generating` Messages as `kind = error`, clear or
  overwrite the expired lease, and let a later Event or operator action continue.

High-value partial-commit recovery cases:

- Inbound Message written, lease not acquired, then crash: redelivery dedupes the
  inbound Message and continues.
- Lease acquired, provider call not started, then crash: stale lease cleanup or
  retry continues without duplicating the inbound Message.
- Assistant tool-call Message written, missing tool result, then crash:
  redelivery does not write a second tool-call Message; it executes missing tool
  results or writes terminal safe errors.
- Partial tool results written, then crash: completed tool side effects are not
  repeated; missing results are filled or converted to safe errors.
- Assistant Message complete, delivery result missing, then crash: redelivery
  retries delivery handoff and does not rerun the model.
- Visible stream chunks appended while assistant Message remains `generating`,
  then crash: recovery writes interrupted/error durable outcome and does not
  fallback or rerun the same visible reply.
- `new` wins an active-generation race: previous late output does not enter the
  fresh Conversation.
- A close request while TargetSession has pending entries follows EventBus
  safe-point drain/close behavior.

`BullX.EventBus.TargetSession.close/1` and `fail/2` remain session-window
controls. One-shot Events, command-only Events, ignored Events, and completed
addressed replies should request `close/1` when no more pending work remains.
Only terminal runtime failures requiring operator diagnosis should request
`fail/2`. If Core requests close or fail after writing durable records,
`Target.handle_event/2` still returns `:ok` so TargetSession progress advances.
`terminal_reason` must be short and safe; it must not contain user content, raw
CloudEvents, provider payloads, stream chunks, or credentials.

## Error behavior

AIAgent distinguishes these error classes:

- Business failure: record Message, Work state, ChildRun failure, Artifact
  state, audit, or domain records, then return `:ok`.
- Recoverable provider or tool failure: retry by policy or return structured
  tool/result error.
- Prompt still too long after compression: write a safe error Message and stop
  generation.
- ACL denial or resource limit: follow `./ACL.md`, stop the current operation,
  take an available next step, create Work, or write a safe error.
- Infrastructure failure: return `{:error, reason}` for TargetSession retry.
- Broken profile or missing Agent Principal: fail safely without model calls or
  external side effects.

Logs and telemetry may include ids, status atoms, provider ids, model ids, safe
diagnostic codes, and durations. They must not include Message content, secrets,
raw provider payloads, complete CloudEvents, or stream chunks.

## Implementation handoff

### Goal

Implement AIAgent v1 runtime so an Event Routing Rule with
`target_type = "ai_agent"` invokes an Agent Principal through TargetSession and
can complete one model/tool/output loop without moving AIAgent behavior into
EventBus, LLMProvider, Principal, Channel Adapter, or Workflow boundaries.

### Context pointers

- `docs/Architecture.md`
- `docs/design-docs/eventbus/Core.md`
- `docs/design-docs/eventbus/NormalizedCloudEvent.md`
- `docs/design-docs/eventbus/Persistence.md`
- `docs/design-docs/eventbus/StreamingOutput.md`
- `docs/design-docs/eventbus/ChannelAdapter.md`
- `docs/design-docs/Principal.md`
- `docs/design-docs/LLMProvider.md`
- `docs/design-docs/AuthZ.md`
- `docs/design-docs/Plugins.md`
- `docs/design-docs/Configuration.md`
- `docs/design-docs/ai-agent/ACL.md`
- `docs/design-docs/ai-agent/AmbientAndEventMessages.md`
- `docs/design-docs/ai-agent/ContextCompressionAndCaching.md`
- `docs/design-docs/ai-agent/SlashCommands.md`
- `docs/design-docs/ai-agent/SystemPromptBuilder.md`
- `lib/bullx/runtime.ex`
- `lib/bullx/runtime/supervisor.ex`
- `lib/bullx/ecto/uuid_v7.ex`
- `priv/repo/migrations/`

### Constraints

- Non-SubAgent AIAgent uses `target_type = "ai_agent"` and
  `target_ref = principals.id`.
- Do not add another Agent subtype discriminator column.
- Conversation and Message UUID primary keys use `BullX.Ecto.UUIDv7`.
- TargetSession side-channel state and output stream buffers do not become
  Conversation or Message truth.
- Use `BullX.LLM.Catalog.resolve_model_spec/1`; do not move prompt
  orchestration, model selection storage, usage policy, failover, or tool
  behavior into LLMProvider.
- Use `BullX.EventBus.TargetSession.close/1` and `fail/2`; do not extend
  `Target.handle_event/2` return shape.
- Keep Channel Adapter transport-only.
- Do not add dependencies unless an implementation review explicitly approves
  them.
- Do not change supervision boundaries unless a real failure boundary changes.
- V1 does not add `conversation_message_deliveries` or stream persistence
  tables.
- Time-aware user Messages use the BullX Installation runtime timezone, not a
  per-Agent timezone override.
- Time awareness, ambient context, and user identity context must go through
  Message Meta Context Builder.
- Ambient Conversations do not use per-actor isolation and do not copy one
  ambient Message into multiple Conversations.

### Tasks

1. Add AIAgent profile casting and validation.
   - Owns: `agents.profile.ai_agent` casting and tests.
   - Acceptance: model specs, reasoning effort values, daily reset fields,
     time-awareness granularity, ambient fields, ACL strategy, and ToolSet
     fields validate; invalid profile fails safely without model calls or side
     effects.

2. Add Conversation and Message persistence.
   - Owns: migrations, schemas, changesets, active Conversation uniqueness,
     native enum mapping for closed Message fields, message tree constraints,
     and focused tests.
   - Acceptance: active branch prompt path reconstructs after restart, and time
     awareness rendering can be reproduced from Message metadata.
   - Acceptance: invalid `role`/`kind`/`status` combinations are rejected;
     persisted content uses the v1 block union; tool errors remain
     `role = tool, kind = normal` with structured `tool_result` error blocks.

3. Add AIAgent Target dispatch.
   - Owns: `ai_agent` Target registry entry and
     `BullX.AIAgent.handle_event/2`, plus the shared generation runner
     source contract for `target_session_entry`, `ambient_batch`, and
     `command_retry`.
   - Acceptance: a fake side-channel entry invokes AIAgent without EventBus
     owning AIAgent internals; ambient batch generation can run without
     fabricated TargetSession identifiers and uses the Agent Principal itself as
     ACL caller; command retry generation uses the command entry id as source id.

4. Add conversation key and Event message handling.
   - Owns: deterministic key builder, addressed IM and directed action user
     turn handling, `bullx.command.invoked` command-control routing for AIAgent
     Targets, and integration with ambient/unsupported Event policy.
   - Acceptance: conversation key golden tests cover fixed length-prefixed UTF-8
     encoding, `BullX.Ext.generic_hash/1`, `scene` and `actor` profile modes,
     addressed and ambient lanes, thread and non-thread scenes, and invalid NUL
     input.
   - Acceptance: addressed IM and `bullx.action.submitted` enter normal user
     turns; ambient IM writes to the active ambient Conversation without
     per-actor splitting; companion ambient behavior remains owned by
     `./AmbientAndEventMessages.md`.
   - Acceptance: `bullx.command.invoked` routed to `target_type = "ai_agent"`
     executes the AIAgent command control path without writing a Conversation
     Message or delegating through a generic Command Target.

5. Add slash command integration and daily reset.
   - Owns: command runtime primitives, generation lease cancellation, branch
     commands, reset helper, and tests.
   - Acceptance: `new`, `retry`, `steer`, `stop`, `undo`, `compress`, and daily
     reset satisfy companion contracts and do not persist slash command inputs or
     command responses as Conversation Messages.

6. Add prompt renderer, Message Meta Context Builder, and token accounting.
   - Owns: active branch renderer, builder, time prefix rendering, ambient
     context integration, provider input validation, token estimation, usage
     capture, compression failure handoff, and System Prompt Builder integration.
   - Acceptance: Core consumes summary overlay, prompt cache hints, builder
     output, and stable-prefix boundary without reimplementing companion rules.
   - Acceptance: token estimation is conservative, content-shape aware, and runs
     before prompt cache hints; compression attempts for one lease or entry are
     bounded by the companion failure guard.

7. Add model call boundary.
   - Owns: LLMProvider catalog integration, `req_llm` high-level calls, response
     normalization, usage metadata, provider retry/fallback boundary, and safe
     errors.
   - Acceptance: model calls use `ReqLLM.generate_text/3` or
     `ReqLLM.stream_text/3`; no bang helpers in normal Target processing; no
     raw provider body patching; no durable `ReqLLM.Response.context`.

8. Add ToolSet and tool loop.
   - Owns: code-owned registry, one fake tool, ToolSet validation, `ReqLLM.Tool`
     rendering, tool-call normalization, ACL filtering, dispatcher context,
     timeout, idempotency key propagation, result persistence, result compaction,
     max turns, and parallel execution.
   - Acceptance: an enabled fake `web_search` tool can render through
     `ReqLLM.Tool`, execute through the Core dispatcher, receive timeout and
     idempotency context, write correlated tool results, and feed the next model
     turn; denied, malformed, crashed, timed-out, disabled, or unknown tool calls
     become safe structured errors.
   - Acceptance: the main Agentic Loop does not use a `req_llm` auto-execution
     path that can run tools before the assistant tool-call Message is durable.
   - Acceptance: v1 does not ship real external tools and does not require
     future Capability governance before the fake tool loop works.

9. Add output stream production.
   - Owns: producer-side use of EventBus stream helpers.
   - Acceptance: durable generating assistant state exists before the first
     visible chunk; recovery converts stale visible generation into
     interrupted/error outcome instead of rerunning the reply.

10. Add visible reply delivery.
    - Owns: `reply_channel` validation, adapter outbound handoff, adapter stream
      handoff, and delivery-result metadata.
    - Acceptance: visible replies use Channel Adapter outbound or stream
      boundary; ambient normal Messages never public-reply; proactive ambient
      v1 uses final delivery only.

11. Add idempotency and recovery tests.
    - Owns: duplicate entry behavior, stale lease cleanup, stale generating
      recovery, partial tool-result recovery, and side-effect idempotency stubs.
    - Acceptance: the recovery matrix in this document passes without adding a
      delivery table or stream persistence table.
    - Acceptance: lease defaults, override validation, heartbeat extension, max
      runtime cap, cancellation, expiry, and owned-active checks follow the Core
      generation lease contract.

### Stop and ask

Stop implementation and ask for a design decision if:

- One Event must fan out to multiple Targets at EventBus routing time.
- AIAgent needs EventBus matcher access to provider raw payloads, CloudEvents
  `subject`, or private Agent profile fields.
- `ai_agent` needs a non-UUID `target_ref` or SubAgent must become a full Agent
  Principal.
- AIAgent ACL needs an elevation strategy other than `deny`, or authorization
  needs to move into prompt text.
- Provider fallback must continue the same visible assistant reply after output
  has started.
- Adapter must wait for Target execution, Conversation persistence, or
  TargetSession completion before acknowledging the provider.
- A TargetSession must remain alive beyond 24 hours to wait for approval,
  external agents, or human replies.
- A provider conversation must bypass Channel Adapter outbound or stream
  boundary to send replies.
- Visible delivery idempotency requires a dedicated delivery table in v1.
- Core needs to bypass System Prompt Builder or Message Meta Context Builder.
- One ambient Message must be copied into multiple per-actor Conversations.
- Daily reset needs Redis ambient batch lease or wait semantics.
- AIAgent v1 cannot ship without adding future Capability governance, future
  Budget, sandbox, or independent audit subsystems.

## Verification

Focused implementation verification should include:

- AIAgent profile casting and validation tests.
- Conversation and Message migration, changeset, branch rendering, and
  time-awareness metadata tests.
- Target dispatch tests proving EventBus invokes `ai_agent` through the normal
  one-entry `Target.handle_event/2` contract.
- Addressed IM, directed action, ambient IM, unsupported Event, command, and
  daily reset tests.
- Prompt rendering tests for active branch, summary overlay, Message Meta
  Context Builder placement, System Prompt Builder handoff, tool-call/result
  pairing, and provider input safety.
- Token accounting and usage capture tests for non-streaming and streaming
  `req_llm` calls.
- ToolSet, ACL filtering, parallel result ordering, max-turn, and recovery tests.
- Streaming producer and visible delivery idempotency tests.
- Partial-commit recovery matrix tests.
- `bun precommit` before the implementation is considered done.
