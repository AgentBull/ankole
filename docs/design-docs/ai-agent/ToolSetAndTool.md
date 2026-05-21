# AIAgent ToolSets and Tools

BullX exposes AIAgent tools through a code-owned ToolSet registry. A ToolSet is
the only profile enablement unit for related tools, and a Tool is a small,
model-callable runtime primitive implemented by BullX core or trusted compiled
plugin code. AIAgent ACL decides whether the current caller may see or execute
ordinary or privileged operations; ToolSet does not become a second
authorization layer, business catalog, Skill catalog, persistent entity, or web
safety gateway.

The design keeps the runtime narrow. AIAgent Core computes the effective tool
list for each provider request from registry defaults, Agent profile overrides,
availability checks, and ACL. The final list is rendered as `ReqLLM.Tool`
schemas, and every tool call must pass through a BullX-owned dispatcher before
any implementation code runs.

## Scope

This design defines:

- The AIAgent ToolSet and Tool registry contract.
- `default_enabled` ToolSet expansion semantics.
- The built-in `basic` ToolSet with `clarify`, including required Feishu card
  delivery behavior.
- The built-in `web` ToolSet with `web_search` and `web_extract`, including
  live Exa, Tavily, SerpAPI, and Jina Reader adapters.
- AIAgent profile rules for enabling or disabling ToolSets.
- Request-time provider tool schema rendering through `ReqLLM.Tool`.
- Dispatcher enforcement before tool execution.
- Plugin-provided ToolSet and web-adapter extension boundaries.
- Failure, security, privacy, implementation, and verification expectations.

This design does not define:

- Skill persistence, Skill resolution, Skill prompt rendering, or Skill virtual
  file storage.
- PostgreSQL-backed file tools such as `read_file`, `write_file`,
  `patch_files`, or `search_files`.
- Tool consumers outside AIAgent runtime.
- Workflow Node contracts or Workflow tool semantics.
- Runtime plugin installation, hot enabling, hot disabling, or dynamic plugin
  compilation.
- New `tools`, `toolsets`, `tool_grants`, adapter, or ACL persistence tables.
- Future sandbox policy, Budget accounting, approval workflows, or external
  action audit storage.

## Existing system

The AI-agent companion docs already define the surrounding runtime boundary:

- `./Core.md` owns the model/tool loop, ToolSet expansion, provider `tools`
  option, tool-call and tool-result pairing, tool-call order, result
  compaction handoff, and durable Message boundaries.
- `./ACL.md` owns the AIAgent access gate and the `ordinary | privileged`
  operation tags. ToolSet is a configuration layer, not an authorization
  subject.
- `./SystemPromptBuilder.md` does not render executable tool schemas. Tool
  schemas travel through the provider `tools` option, not through system prompt
  text.
- `./ContextCompressionAndCaching.md` protects tool-call and tool-result pairs
  during prompt rendering and owns request-time compaction for large tool
  results.
- `../Plugins.md` owns plugin discovery, enablement, extension declarations,
  and restart-required activation. AIAgent registry consumes enabled plugin
  extensions but does not invent a plugin host.
- `../Configuration.md` owns runtime configuration and secret custody through
  `BullX.Config`.

The current implementation already has the minimal tool path:

- `BullX.AIAgent.Profile` parses `agents.profile["ai_agent"]["toolsets"]`.
- `BullX.AIAgent.Tools.Registry` is code-owned and reconstructible.
- `BullX.AIAgent.Tools.enabled_tools/5` renders allowed tools as
  `ReqLLM.Tool` structs.
- `BullX.AIAgent.Tools.Dispatcher` rechecks profile, registry, effective access,
  ACL, and timeout before execution.
- `BullX.AIAgent.Tools.Context` passes explicit caller, Agent, Conversation,
  trigger, tool-call, timeout, and idempotency facts to implementations.

The existing fake `web_research` ToolSet and fake `web_search` tool are test
scaffolding for the loop. The formal built-ins are `basic` and `web`; the
implementation migrates test naming to those registry ids.

## Core model

ToolSet and Tool stay separate from Skill:

- A `Skill` is a procedural knowledge asset. A Skill may describe how to use a
  tool, include instructions, scripts, templates, examples, or resources, and
  use progressive disclosure. A Skill does not grant execution power and is not
  exposed as a provider-visible tool schema.
- A `Tool` is a model-callable runtime primitive. A Tool is few, stable,
  general, and code-owned. It must pass registry lookup, profile resolution,
  availability checks, ACL filtering, dispatcher enforcement, and Core
  transcript recording.
- A `ToolSet` is the unique ownership group for tools and the smallest Agent
  profile enablement unit. ToolSet does not store business facts, own secrets,
  decide Principal authorization, or participate in Skill progressive
  disclosure.

ToolSet grouping should follow runtime coupling. Put tools in the same ToolSet
when real tasks need them together or when they share state, configuration,
permission assumptions, or safety boundaries. Split tools into separate ToolSets
when they should be enabled independently. If several tools must always appear
together, give them the same access tag or split the ToolSet to avoid a partial
runtime surface after ACL filtering.

## ToolSet registry contract

A ToolSet is a stable registry entry with these fields:

| Field | Meaning |
| --- | --- |
| `id` | Stable string id such as `basic`, `web`, or a plugin-provided id. |
| `default_enabled` | Boolean default used when an Agent profile omits the ToolSet. |
| `tools` | Tool names owned by this ToolSet. |
| `description` | Optional human-facing description for configuration UI, diagnostics, and docs. |
| `availability` | Optional request-time `available?(context)` check for shared prerequisites. |

ToolSet availability checks filter the whole group when common prerequisites
fail. Tool availability checks filter one Tool when only that Tool is
unavailable. The `web` ToolSet mostly uses tool-level availability because
`web_search` and `web_extract` may depend on different adapters or credentials.
Availability callbacks return `:ok | {:error, code}`. A failed availability
check filters the ToolSet or Tool from the provider schema and records a safe
diagnostic. It does not create a model-visible tool-result error because the
model never sees the unavailable tool.

Every Tool belongs to exactly one ToolSet. BullX does not support orphan tools,
one Tool shared by multiple ToolSets, profile-visible per-tool enablement, or
ToolSet-owned access defaults. If one implementation needs different risk
levels, expose distinct tools such as `bi_query_public_metric` and
`bi_query_revenue`.

ToolSet does not persist business facts, own credentials, create TargetSessions,
or decide whether a Principal may execute. AIAgent Core computes each Tool's
effective access tag from the Tool registry entry and passes that tag to
`./ACL.md`.

## Tool registry contract

A Tool registry entry contains only provider schema fields and BullX execution
fields needed for the current runtime:

| Field | Meaning |
| --- | --- |
| `name` | Provider-visible function name and BullX registry id. |
| `toolset_id` | Unique owning ToolSet id. |
| `description` | Short model-visible description passed to `ReqLLM.Tool.new/1`. |
| `parameter_schema` | `req_llm` keyword schema or supported JSON Schema map. |
| `strict` | Optional `ReqLLM.Tool` strict flag, defaulting to `false`. |
| `provider_options` | Optional `ReqLLM.Tool` provider-specific schema/rendering options. |
| `access` | Code-owned operation tag: `ordinary` or `privileged`. |
| `parallel_safe` | Code-owned scheduling hint, defaulting to `false`. |
| `module` | Execution module called by the dispatcher. |
| `availability` | Optional request-time `available?(context)` check for this Tool's prerequisites. |

`provider_options` is only for provider-specific tool schema rendering through
`ReqLLM.Tool`. It must not select a web backend, store credentials, carry Agent
profile data, hold business facts, or contain raw provider payloads.

`parallel_safe` is a small scheduler hint. AIAgent Core may execute a provider
turn's tool calls in parallel only when every tool call resolves to a registry
entry with `parallel_safe = true`. Missing entries or `false` force sequential
execution. Parallel execution must still write tool results in the provider's
original tool-call order.

Tool names must satisfy `ReqLLM.Tool.valid_name?/1`: start with a letter or
underscore, use only letters, digits, underscores, and middle hyphens, and stay
within 64 characters. BullX style further requires short, stable
`lower_snake_case` names. Do not encode plugin, vendor, provider, Skill, path,
or namespace source into the provider-visible name. Valid built-in examples are
`clarify`, `web_search`, and `web_extract`; invalid styles include
`web.search`, `plugin:vendor_action`, `repo/apply_patch`, `exa_search`, and
`skill_pdf_extract`.

Tool registry definitions come from BullX core or trusted compiled plugin code.
Core normalizes all built-in and plugin definitions into typed registry structs
before use. Plugin modules may return maps or structs, but AIAgent runtime only
uses normalized structs after validation. V1 does not add registry tables,
operator-editable Tool definitions, runtime Tool installation, or profile-level
per-tool switches.

## Built-in `basic` ToolSet

`basic` is built in, `default_enabled = true`, and cannot be disabled. Every
AIAgent has `basic`. An Agent profile that sets `basic.enabled = false` is
invalid profile data. A profile subtree that tries to disable `clarify` through
unsupported per-tool fields is also invalid profile data.

`basic` v1 contains one Tool:

| Tool | Access | Parallel-safe | Purpose |
| --- | --- | --- | --- |
| `clarify` | `ordinary` | `false` | Ask the current human-facing run for clarification. |

`clarify` accepts a required `question` and optional `choices`. The runtime
cleans empty choices and keeps at most four choices. UI layers may add their own
manual reply affordance; the provider-visible schema does not need a special
field for that affordance.

`clarify` returns one of these statuses:

| Status | Meaning |
| --- | --- |
| `requested` | BullX produced a visible clarification request. The current generation stops with `needs_input`. |
| `no_response` | The channel can present the question, but the current turn cannot obtain an answer. Runner stops for later input. |
| `unavailable` | The current runtime has no usable human interaction channel. Runner returns a safe unavailable tool result and may let the model continue without clarification. |

`clarify` does not call a Channel Adapter directly and does not write the future
human answer back into the old tool call. Runner uses Core visible reply
delivery, the current `reply_channel`, TargetSession output stream, or Channel
Adapter outbound boundary to present the request. A later answer re-enters
BullX through the original inbound path as a new Event, addressed Message, or
directed action. The answer starts a later run rather than continuing the old
tool call asynchronously.

Feishu delivery must render `clarify.requested` as an interactive card. The card
shows the question, renders each choice as a button when choices are present,
and includes a manual reply affordance. The Feishu action payload carries only
an opaque correlation id such as the needs-input assistant Message id,
`bullx_action = "clarify_answer"`, and the selected choice index or value. The
payload must not carry prompt text, ACL profile data, credentials, or raw Events.
The Feishu callback normalizes to `bullx.action.submitted`, then EventBus routes
the action back to AIAgent as new user input. Non-card channels may fall back to
a plain text question, but Feishu v1 is not complete until card delivery works.

`clarify` creates no pending clarification table, async waiting process,
dedicated correlation table, or Channel Adapter direct-delivery path. It is a
current-generation control signal, not a durable interaction subsystem. V1 does
not expose a best-effort continuation profile option for `clarify.requested`.

## Built-in `web` ToolSet

`web` is built in, `default_enabled = true`, and can be disabled by profile with
`web.enabled = false`. It exposes external web access through BullX-owned
adapters and `BullX.Config`, not through Agent profile fields.

`web` v1 contains two Tools:

| Tool | Access | Parallel-safe | Purpose |
| --- | --- | --- | --- |
| `web_search` | `ordinary` | `true` | Search the web and return normalized search results. |
| `web_extract` | `ordinary` | `true` | Extract readable text or summaries from URLs. |

`web_search` and `web_extract` use separate tool-level availability checks. If
search is configured but extract is not, AIAgent renders only `web_search`.
ToolSet availability should cover only prerequisites shared by the whole `web`
ToolSet.

Web adapter selection, credentials, default backend, and search/extract provider
settings belong to `BullX.Config`. Agent profile only says whether the `web`
ToolSet is enabled. Secrets must use the existing `BullX.Config` secret path and
must not appear in profile JSON, prompt text, provider tool schema, tool result
content, or telemetry.

Built-in web adapters use the existing `Req` HTTP client. BullX does not add SDK
dependencies for web search or extraction unless the user explicitly approves
the dependency.

The adapter selection order is deterministic:

- `web_search` reads `web.search_provider`; if absent, it reads `web.provider`;
  if still absent, it chooses the first configured and available search adapter
  in registry order.
- `web_extract` reads `web.extract_provider`; if absent, it reads
  `web.provider`; if still absent, it chooses the first configured and available
  extract adapter in registry order.
- Tool-level availability uses the same selection logic. If no adapter can be
  selected, config is invalid, or credentials are missing, only the affected
  Tool is filtered.

Core supports these built-in live adapters:

| Tool | Built-in adapters |
| --- | --- |
| `web_search` | `exa`, `tavily`, `serpapi` |
| `web_extract` | `exa`, `tavily`, `jina_reader` |

All four adapter families must land in the v1 implementation. Tests may use fake
adapters for deterministic coverage, but the implementation handoff is not
complete with only fake adapters or only an adapter registry.

Plugin code may contribute additional web adapters without adding new
provider-visible tool names. The plugin contributes adapter id, configuration
declarations, secret declarations, and callbacks; `web_search` and
`web_extract` continue to select adapters through `BullX.Config`.

Built-in web adapter configuration uses these `BullX.Config` keys:

| Key | Type | Secret | Meaning |
| --- | --- | --- | --- |
| `bullx.ai_agent.web.provider` | string or nil | no | Generic fallback provider for both tools when compatible. |
| `bullx.ai_agent.web.search_provider` | string or nil | no | Search-specific provider: `exa`, `tavily`, or `serpapi`. |
| `bullx.ai_agent.web.extract_provider` | string or nil | no | Extract-specific provider: `exa`, `tavily`, or `jina_reader`. |
| `bullx.ai_agent.web.exa.api_key` | string or nil | yes | Exa API key. |
| `bullx.ai_agent.web.tavily.api_key` | string or nil | yes | Tavily API key. |
| `bullx.ai_agent.web.serpapi.api_key` | string or nil | yes | SerpAPI key. |
| `bullx.ai_agent.web.jina.api_key` | string or nil | yes | Optional Jina Reader API key. |

V1 does not add a BullX-owned local rate limiter. Provider rate-limit responses
become safe adapter errors. Operators can choose provider credentials and
provider-specific account limits outside BullX.

`web_search` keeps a narrow parameter schema: required `query`, optional
`limit`, default `5`, clamped to `1..100`. A normalized result contains at least
`success`, `query`, `results`, and optional `error`. Each result item contains at
least `title`, `url`, and `snippet`, with optional `position`.

`web_extract` accepts up to five URLs. A normalized result contains at least
`success`, `results`, and optional `error`. Each result item contains at least
`url` and `text`, with optional `title` and `truncated`.

V1 intentionally does not add BullX-owned URL safety checks, SSRF protection,
redirect inspection, adapter deadline enforcement, response-size limits, or
result-size boundaries around web adapters. Web tools pass validated tool
arguments to the configured adapter and rely on the remote provider, `Req`, and
ordinary adapter error handling. Do not add these local safety controls during
the v1 implementation unless the design is reopened.

The built-in adapters use fixed request shapes:

| Adapter | Tool | Request | Auth | Mapping |
| --- | --- | --- | --- | --- |
| `exa` | `web_search` | `POST https://api.exa.ai/search` with `query`, `type = "auto"`, `numResults = limit`, and `contents.highlights = true`. | `x-api-key` header. | `title`, `url`, and joined `highlights` as `snippet`. |
| `exa` | `web_extract` | `POST https://api.exa.ai/contents` with `urls` and `text = true`. | `x-api-key` header. | `title`, `url`, and `text`; inspect per-URL `statuses` for partial failures. |
| `tavily` | `web_search` | `POST https://api.tavily.com/search` with `query`, `max_results = min(limit, 20)`, `search_depth = "basic"`, and answer/raw-content/image flags disabled. | `Authorization: Bearer <key>`. | `title`, `url`, and `content` as `snippet`. |
| `tavily` | `web_extract` | `POST https://api.tavily.com/extract` with `urls`, `extract_depth = "basic"`, `format = "markdown"`, and image/favicon flags disabled. | `Authorization: Bearer <key>`. | `url` and `raw_content` as `text`; `failed_results` become per-URL errors. |
| `serpapi` | `web_search` | `GET https://serpapi.com/search` with `engine = "google"`, `q = query`, `output = "json"`, and `api_key`; take up to `limit` `organic_results`. | `api_key` query parameter. | `title`, `link` as `url`, `snippet`, and optional `position`. |
| `jina_reader` | `web_extract` | One `POST https://r.jina.ai/` per URL with JSON body `%{"url" => url}`, `Accept: application/json`, and `X-Respond-With: content`. | Optional `Authorization: Bearer <key>`. | `data.url`, `data.title`, and `data.content || data.text` as `text`. |

Adapters do not expose provider-specific knobs as tool arguments. Provider
request defaults change only through this design or adapter-owned code changes,
not through Agent profile.

Adapter implementation should verify details against the current official docs
before coding:

- [Exa Search API](https://exa.ai/docs/reference/search-api-guide-for-coding-agents)
  and [Exa Contents API](https://exa.ai/docs/reference/contents-api-guide-for-coding-agents)
- [Tavily Search API](https://docs.tavily.com/documentation/api-reference/endpoint/search)
  and [Tavily Extract API](https://docs.tavily.com/documentation/api-reference/endpoint/extract)
- [SerpAPI Google Search API](https://serpapi.com/search-api) and
  [Google Organic Results](https://serpapi.com/organic-results)
- [Jina Reader API](https://jina.ai/en-US/reader/) and
  [Jina Reader OpenAPI](https://r.jina.ai/docs)

Tool results must not include provider credentials, credential ids, raw HTTP
headers, full debug dumps, or raw provider responses. If provider attribution is
needed for operations, write safe telemetry instead of expanding the
model-visible result schema.

## Privileged tools

Tools use only two access tags in v1:

| Access tag | Meaning |
| --- | --- |
| `ordinary` | Low-risk reads, clarification, search, and operations available to any Principal that may invoke the AIAgent. |
| `privileged` | Deletion, external writes, sensitive data queries, permission changes, or operations requiring higher trust. |

Access tags are code-owned registry facts. Agent profile cannot override them.
AIAgent Core reads the Tool's effective access tag, and `./ACL.md` enforces the
tag. The caller must have `invoke` on `ai_agent:<agent_principal_id>` for any
tool. If the Tool is `privileged`, the caller must also have
`invoke_privileged`.

Tool risk belongs at the Tool boundary. When risk depends on operation purpose,
split broad tools into distinct ordinary and privileged tools instead of hiding
access policy in complex parameter rules.

## Agent profile configuration

`agents.profile.ai_agent.toolsets` stores explicit ToolSet enablement overrides
only:

```json
{
  "ai_agent": {
    "toolsets": {
      "web": {
        "enabled": true
      }
    }
  }
}
```

Profile rules:

- A missing ToolSet entry uses the registry `default_enabled` value.
- A present ToolSet entry must contain `enabled`.
- `enabled` must be a boolean.
- `enabled = true` explicitly enables the ToolSet.
- `enabled = false` explicitly disables a non-`basic` ToolSet.
- `basic.enabled = false` is invalid profile data.
- A ToolSet entry may contain only `enabled`. Fields such as `access`, `tools`,
  provider credentials, per-tool enablement, or per-tool access overrides are
  invalid profile data.
- Unknown ToolSet ids do not fail profile casting because plugin registry state
  is request-time state. Unknown ToolSets do not render and cannot execute.

Default enablement is a registry declaration, not a preference row. The value
only answers what happens when the profile omits the ToolSet. Explicit profile
configuration wins except for the non-disableable `basic` ToolSet.

## Provider schema rendering

AIAgent computes executable tools for every main model request. The computation
affects only the current request and does not write a persistent registry
snapshot.

The rendering order is:

1. Core prepares the triggering Principal, Agent Principal, Target,
   Conversation, entry, generation lease, deadline, and ACL context.
2. Core reads the registry and expands ToolSets from `default_enabled`.
3. Core overlays explicit profile enablement and disablement.
4. Core forces `basic` into the enabled set because profile casting rejects
   `basic.enabled = false`.
5. Core runs ToolSet availability checks.
6. Core expands enabled ToolSets into flat Tool entries.
7. Core runs tool-level availability checks.
8. Core reads each Tool's code-owned access tag.
9. ACL filters tools unavailable to the current caller.
10. Core converts the remaining entries to `ReqLLM.Tool` structs and passes
    them through the provider `tools` option.

Executable schemas do not enter System Prompt Builder. Prompt text may describe
when to use tools, but model-visible executable availability comes only from the
provider `tools` option. A model-emitted tool call that was not rendered for the
current request is still rejected by the dispatcher.

Prompt caching does not decide tool availability. When ToolSet profile, ACL, or
availability changes, Core builds a fresh provider input for that request.

## Tool call execution

AIAgent Core owns the model/tool loop, durable assistant Message with tool-call
blocks, tool-result Message creation, tool-call order, idempotency, crash
recovery, and max-turn handling. This design fixes the dispatcher boundary.

Before invoking implementation code, the dispatcher must recheck:

- Registry presence.
- ToolSet profile enablement.
- ToolSet and Tool availability.
- Tool access tag.
- AIAgent ACL.
- Tool-call name.
- Argument schema and decoded argument shape.
- Core generation timeout when present; web adapters do not add adapter-local
  deadline controls.
- Idempotency facts.

Tool modules implement an `execute/2` shape: validated arguments plus
`BullX.AIAgent.Tools.Context.t()`, returning a safe JSON-neutral result,
`ReqLLM.ToolResult`, or structured error. Tool implementations must not read
TargetSession mailboxes directly, mutate EventBus routing, generate raw provider
JSON, inspect private ACL/profile data, or bypass Core transcript recording.

The dispatcher translates unknown, disabled, denied, malformed, timeout, crash,
and unavailable outcomes into this safe structured tool-result error envelope:

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

The v1 code set is `tool_unknown`, `tool_disabled`, `tool_unavailable`,
`tool_denied`, `tool_malformed_arguments`, `tool_timeout`, and `tool_failed`.
Messages are short and safe. Tool-result errors must not expose private
exception text, stack traces, credentials, full tool arguments, raw CloudEvents,
or raw provider payloads.

## Plugin-provided ToolSets

Plugins may add ToolSets and Tools through a typed extension point:

```elixir
%{
  point: :"bullx.ai_agent.toolset",
  id: "browser",
  module: BrowserTools.ToolSet
}
```

The extension `id` is the ToolSet id. The extension `module` returns the
ToolSet definition, its tools, optional availability checks, and each Tool's
`ReqLLM.Tool` fields, access tag, parallel-safety flag, and execution module.
One plugin declares multiple ToolSets by returning multiple
`:"bullx.ai_agent.toolset"` extensions.

The plugin host stores and serves declarations. AIAgent registry owns ToolSet
semantics. During merge, the registry validates `toolset/0`, ToolSet id, tool
names, required fields, access tags, `ReqLLM.Tool` option shape, availability
callbacks, parallel-safety flags, and execution modules.

AIAgent registry reads only enabled plugin extensions:

```elixir
BullX.Plugins.Registry.enabled_extensions_for(:"bullx.ai_agent.toolset")
```

Disabled plugins do not contribute provider-visible tools. Agent profiles that
reference disabled plugin ToolSets treat those ids as unknown at request time.

Registry merge is deterministic:

1. Load built-in ToolSets.
2. Load enabled plugin extensions sorted by plugin id and extension id.
3. Keep built-ins authoritative.
4. Skip a plugin contribution that conflicts with a built-in or already accepted
   ToolSet id or tool name.
5. Emit safe diagnostics for skipped contributions without storing plugin
   source metadata in Tool definitions or provider-visible schemas.

The failure behavior follows the Hermes reference shape: invalid plugin ToolSet
or Tool definitions are skipped with safe diagnostics, and startup continues.
Unknown ToolSets referenced by profile remain request-time unknown ToolSets.
Unknown tool calls fail lazily through the dispatcher error envelope. A skipped
plugin contribution must not enter provider-visible schemas or become
executable.

Plugin ToolSets obey the same rules as built-ins:

- A plugin cannot override `basic`, `web`, `clarify`, `web_search`, or
  `web_extract`.
- A plugin cannot declare orphan tools.
- A plugin cannot attach tools to another plugin's ToolSet or to a built-in
  ToolSet.
- A plugin cannot bypass profile resolution, availability checks, ACL filtering,
  provider schema rendering, dispatcher execution, or secret custody.
- A plugin must keep secrets out of provider schema, prompt guidance, tool
  result content, and telemetry.

Plugin-provided web adapters are different from plugin-provided Tools. A plugin
that extends `web_search` or `web_extract` contributes an adapter to the web
adapter registry, not a new provider-visible tool name.

## Failure behavior

Tool failure is an explainable model-loop result unless infrastructure cannot
preserve the transcript boundary.

The runtime handles failures as follows:

- Unknown registry entries, disabled ToolSets, unavailable tools, ACL denials,
  and malformed arguments become structured tool-result errors.
- Profile attempts to disable `basic` or configure unsupported per-tool fields
  fail profile casting.
- Tool crashes and timeouts become safe structured tool-result errors.
- `clarify` without an interaction channel returns `unavailable` or
  `no_response`; it does not create pending state.
- `web_search` and `web_extract` return safe structured errors for missing
  adapters, invalid adapter config, missing credentials, remote timeout, and
  provider rate limiting.
- Dispatcher-visible errors do not include private ACL/profile data, raw tool
  arguments, credentials, raw CloudEvents, raw HTTP payloads, or raw provider
  payloads.

## Security and privacy

Tool visibility and execution are caller constrained. AIAgent filters provider
schemas before model calls and rechecks ACL before execution. Ordinary tools
require `invoke`; privileged tools require both `invoke` and
`invoke_privileged`.

Tool descriptions, schemas, prompt guidance, and result content must not contain
secrets, private ACL/profile data, credential ids, raw external Events, raw
provider payloads, raw HTTP headers, or debug dumps. Tool results can enter
durable Conversation and Message records, so each implementation must return a
result appropriate for transcript storage and prompt replay.

Web tools access external networks. V1 deliberately limits local web-tool safety
to credential custody through `BullX.Config`, adapter selection, argument shape
validation, and safe error/result normalization. It does not add BullX-owned URL
safety rules, SSRF protection, redirect inspection, adapter deadline enforcement,
response-size limits, result-size boundaries, or a local rate limiter.

## Implementation handoff

### Goal

Implement the minimal AIAgent ToolSet and Tool runtime for `clarify`,
`web_search`, and `web_extract`, with code-owned registry definitions,
ToolSet-only profile enablement, `ReqLLM.Tool` rendering, dispatcher
enforcement, and plugin extension support. Do not add persistent Tool entities,
a second authorization layer, or runtime plugin lifecycle machinery.

### Context pointers

- `docs/Architecture.md`
- `docs/design-docs/ai-agent/Core.md`
- `docs/design-docs/ai-agent/ACL.md`
- `docs/design-docs/ai-agent/SystemPromptBuilder.md`
- `docs/design-docs/ai-agent/ContextCompressionAndCaching.md`
- `docs/design-docs/Plugins.md`
- `docs/design-docs/Configuration.md`
- `lib/bullx/ai_agent/tools.ex`
- `lib/bullx/ai_agent/tools/registry.ex`
- `lib/bullx/ai_agent/tools/dispatcher.ex`
- `lib/bullx/ai_agent/tools/context.ex`
- `lib/bullx/ai_agent/profile.ex`
- `lib/bullx/ai_agent/runner.ex`
- `lib/bullx/config.ex`
- `lib/bullx/config/plugins.ex`

### Constraints

- Do not add ToolSet or Tool persistence tables.
- Do not add a registry process.
- Do not add dependencies for web adapters without user approval.
- Keep `basic` enabled for every AIAgent and invalid to disable.
- Keep `web` default-enabled but profile-disableable.
- Keep Agent profile scoped to ToolSet `enabled` overrides.
- Keep access tags code-owned and limited to `ordinary | privileged`.
- Keep web adapter provider and credentials in `BullX.Config`.
- Do not add BullX-owned URL safety, SSRF protection, redirect inspection, local
  web adapter deadline enforcement, response-size limits, result-size
  boundaries, or a local rate limiter.
- Keep executable schemas out of System Prompt Builder.
- Keep tool execution behind `BullX.AIAgent.Tools.Dispatcher`.
- Keep plugin ToolSets behind `:"bullx.ai_agent.toolset"` enabled extensions.
- Keep EventBus, TargetSession, Oban worker, and Channel Adapter boundaries
  unchanged.

### Tasks

1. Finalize the registry shape.
   - Owns: `BullX.AIAgent.Tools.Registry`.
   - Acceptance: ToolSets have unique ids, `default_enabled`, tool lists,
     optional descriptions, and optional availability checks. Tools have unique
     valid names, one ToolSet owner, `ReqLLM.Tool` fields, access tags,
     `parallel_safe`, execution modules, and optional availability checks.
     Registry validation normalizes definitions into typed structs and rejects
     orphan tools, invalid names, unsupported access tags, and unsupported Tool
     fields. Conflicting plugin contributions are skipped with diagnostics.

2. Register built-in ToolSets.
   - Owns: `BullX.AIAgent.Tools.Registry`.
   - Acceptance: `basic` is default-enabled and non-disableable with only
     `clarify`; `web` is default-enabled and disableable with only
     `web_search` and `web_extract`.

3. Finalize ToolSet profile resolution.
   - Owns: `BullX.AIAgent.Profile` and `BullX.AIAgent.Tools.enabled_tools/5`.
   - Acceptance: resolution starts from registry `default_enabled`, overlays
     explicit profile overrides, rejects `basic.enabled = false`, rejects
     missing or non-boolean `enabled`, rejects unsupported fields such as
     `access` and `tools`, ignores unknown ToolSet ids at request time, and does
     not support per-tool profile switches.

4. Implement `clarify`.
   - Owns: AIAgent tool implementation and Runner control flow.
   - Acceptance: `clarify` accepts required `question` and up to four choices,
     returns `requested`, `no_response`, or `unavailable`, treats `requested` as
     a terminal current-generation `needs_input` signal, uses Core visible reply
     delivery and `reply_channel`, renders Feishu delivery as an interactive
     card through normal Channel Adapter outbound behavior, and stores later
     human answers as new inbound Events or Messages.

5. Implement web tools and adapters.
   - Owns: `web_search`, `web_extract`, adapter registry, and `BullX.Config`
     declarations.
   - Acceptance: `web_search` implements live `exa`, `tavily`, and `serpapi`
     adapters; `web_extract` implements live `exa`, `tavily`, and `jina_reader`
     adapters; adapter selection follows `web.search_provider`,
     `web.extract_provider`, and `web.provider`; tool-level availability filters
     search and extract independently; results match the normalized shapes in
     this design; no BullX-owned URL safety, SSRF, redirect, local deadline,
     response-size, result-size boundary, or local rate limiter is added.

6. Finalize provider schema rendering.
   - Owns: AIAgent Core provider call preparation.
   - Acceptance: Core renders executable tools only through `ReqLLM.Tool.new/1`
     or compatible `req_llm` surfaces. `description`, `parameter_schema`,
     `strict`, and `provider_options` follow `req_llm` validation. System Prompt
     Builder receives no executable schema.

7. Finalize dispatcher enforcement.
   - Owns: `BullX.AIAgent.Tools.Dispatcher` and tool implementations.
   - Acceptance: dispatcher rechecks registry, profile, availability, effective
     access, ACL, arguments, Core generation timeout when present, and
     idempotency. Unknown, disabled, denied, malformed, timeout, crash, and
     unavailable cases return the fixed structured tool-result error envelope.
     Parallel execution preserves provider tool-call order in persisted results.

8. Add plugin ToolSet extension support.
   - Owns: plugin extension spec and AIAgent registry integration.
   - Acceptance: plugins can declare `:"bullx.ai_agent.toolset"` extensions;
     AIAgent registry consumes only enabled plugin extensions; merge order is
     deterministic; invalid or conflicting plugin ToolSet contributions are
     skipped with diagnostics; plugin ToolSets cannot override built-ins, create
     orphan tools, bypass ACL, or add persistent registry state. Web adapter
     plugins extend adapter registries without adding provider-visible tool
     names.

9. Add tests.
   - Owns: `test/bullx/ai_agent/*tool*test.exs` and related support modules.
   - Acceptance: tests cover registry defaults, `basic` non-disableability,
     `web` disablement, invalid names, deterministic plugin merge, profile
     validation, privileged filtering, forged tool-call denial, timeout and
     crash errors, `clarify.requested` terminal behavior,
     `clarify.unavailable`, tool-level web availability, adapter selection,
     live-adapter request/response shape through mocked HTTP responses, skipped
     invalid plugin contributions, and enabled versus disabled plugin ToolSets.

### Stop conditions

Stop and ask before implementation if the work appears to require:

- ToolSet or Tool persistence tables.
- Making `basic` or `clarify` disableable.
- Agent profile per-tool enablement.
- Agent profile access-tag overrides.
- Access tags beyond `ordinary | privileged`.
- Parallel metadata beyond `parallel_safe`, such as conflict-key inference.
- Plugin overrides of built-in ToolSet or Tool names.
- Provider-visible tool names that fail `ReqLLM.Tool.valid_name?/1`.
- Runtime plugin installation, hot enablement, hot disablement, or dynamic
  compilation.
- Web adapter credentials, raw provider payloads, or debug dumps in Agent
  profile, prompt text, or tool results.
- BullX-owned URL safety, SSRF protection, redirect inspection, local web
  adapter deadline enforcement, response-size limits, result-size boundaries, or
  a local rate limiter.
- EventBus, TargetSession, Oban worker, or Channel Adapter boundary changes.

### Done when

The implementation is complete when:

- AIAgent computes provider `tools` from registry, profile, availability, and
  ACL for every main model request.
- ToolSet `default_enabled` drives omitted profile entries.
- Tool enablement exists only at ToolSet granularity.
- `basic` is default-enabled, non-disableable, and contains only `clarify`.
- `clarify` can request human input, return `no_response` or `unavailable`, and
  treat `requested` as a terminal current-generation control signal.
- Feishu `clarify` delivery renders an interactive card and receives card
  actions as new Events or Messages.
- `web` is default-enabled, disableable, and contains only `web_search` and
  `web_extract`.
- `web_search` and `web_extract` use live Exa, Tavily, SerpAPI, and Jina Reader
  adapters, independent availability, `BullX.Config`, and normalized results.
- Web tools do not add BullX-owned URL safety, SSRF protection, redirect
  inspection, local deadline enforcement, response-size limits, result-size
  boundaries, or a local rate limiter in v1.
- Plugin ToolSets enter the registry only through enabled
  `:"bullx.ai_agent.toolset"` extensions.
- Web adapter plugins extend `web_search` and `web_extract` without adding new
  provider-visible tool names.
- Tool schema rendering uses `ReqLLM.Tool.new/1` fields and validation.
- `provider_options` remains limited to `ReqLLM.Tool` provider schema/rendering
  options.
- `parallel_safe` remains a code-owned boolean scheduling hint.
- Dispatcher rechecks ACL and passes explicit `BullX.AIAgent.Tools.Context`.
- Unknown, disabled, denied, malformed, unavailable, timeout, and crashed tools
  produce safe structured errors with the fixed envelope from this design.
- High-risk tools are at least `privileged` and require `invoke_privileged`.
- No ToolSet or Tool tables, registry process, dependency, or extra ACL layer is
  added.
- `bun precommit` passes, or any failure is recorded with the unrelated dirty
  tree or environmental cause.
