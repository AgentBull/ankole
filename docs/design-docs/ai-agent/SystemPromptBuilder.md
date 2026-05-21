# System Prompt Builder

The System Prompt Builder is the deterministic request-time renderer for the
AIAgent system prompt. It accepts caller-prepared typed sections plus an optional
small embedded prompt template, validates the section contract, renders stable
prompt text and tagged sections into `req_llm`-compatible `:system` content, and
reports the stable-prefix boundary that token accounting and prompt caching can
consume.

The stable-prefix discipline follows the same practical shape used by strong
agent runtimes such as Claude Code: keep durable instructions and stable context
byte-identical when possible, and keep request-volatile facts after that prefix.
BullX does not assume every provider exposes Claude/Anthropic-style cache
markers. The builder reports a provider-neutral boundary; the prompt-cache layer
maps it through `req_llm` when the selected provider supports explicit hints and
otherwise treats it as deterministic rendering metadata.

The builder is deliberately small. It does not own AIAgent profile loading,
Skill retrieval, Brain retrieval, Principal resolution, AuthZ decisions, ToolSet
selection, tool schemas, Conversation history, message meta context, future
Capability selection, or the model provider call. Those sources are prepared by
AIAgent Core and adjacent designs, then normalized into the section input
described here.

## Scope

This design defines:

- The System Prompt Builder as a stateless request-time component.
- The section input contract, including identity, stability, ordering,
  provenance, optional prompt tags, and payload shape.
- Deterministic rendering rules for embedded template text, optional template
  segments, stable sections, and volatile sections.
- The output shape for `req_llm` system content and stable-prefix metadata.
- The boundary with token accounting, context compression, and prompt caching.
- Security constraints, length behavior, recovery behavior, failure behavior,
  and content-free telemetry.
- Implementation handoff and acceptance criteria for the first implementation.

## Non-goals

This design does not define:

- AIAgent profile schema, validation, or storage.
- Skill content, Skill retrieval policy, Skill ranking, or Skill VFS behavior.
- Brain retrieval, Brain representation, Brain ingestion, or memory ranking.
- Principal identity, external identity evidence, Agent Principal schema, or
  Principal redaction rules.
- AuthZ grants, policy evaluation, approval gates, or future Capability
  authorization.
- Tool schema rendering or tool execution. `ReqLLM.Tool` schemas are delivered
  through the provider call's independent `tools` option, not through this
  builder.
- Conversation / Message rendering, active branch selection, tool-call and
  tool-result pairing, or history view generation.
- Summary overlays, compression triggers, or provider cache marker placement.
- Model provider resolution, provider fallback, streaming output, or visible
  delivery.
- A builder cache, rendered prompt snapshot table, provider cache backend, or
  provider-private request mutation.

## Boundary

The builder is a pure rendering boundary inside AIAgent request assembly.
AIAgent Core decides which sources may enter the system prompt for a request and
passes those sources as typed sections. The builder never calls EventBus, reads
TargetSession state, queries PostgreSQL, consults Brain or Skill stores, calls
AuthZ, resolves Principals, calls `BullX.LLM`, or reaches into provider
adapters.

This keeps the current BullX architecture boundaries intact:

- AIAgent is the Target that owns reasoning and tool-use behavior.
- TargetSession is the runtime lane that invokes the Target; it is not the
  durable source of prompt truth.
- Conversation / Message, Work, Brain, Budget, Artifact, and audit or domain
  records hold durable business facts.
- `BullX.LLM` is the `req_llm` provider catalog and lower-level model access
  support layer. It does not own prompt orchestration.
- Principal and AuthZ decide identity and authorization before content reaches
  the builder. The builder only enforces its own input contract.

Caller responsibilities:

- Collect system-prompt-eligible content from caller-owned sources.
- Normalize each content source into a section that follows this design.
- Provide any short product-level prompt text as an embedded template segment
  rather than hiding it inside a catch-all section.
- Decide whether each section is `:stable` or `:volatile`.
- Provide a short `cache_break_reason` for every `:volatile` section.
- Complete retrieval, authorization, redaction, policy checks, and
  source-specific truncation before calling the builder.
- Pass the builder output and stable-prefix boundary to the provider call,
  token accounting, and prompt cache hint layer.
- Rebuild section input when caller-owned context changes.

Builder responsibilities:

- Validate section shape, section identity, stability classification,
  duplicate ids, optional tag shape, cache-break reasons, and coarse payload
  allowlist rules.
- Omit optional empty sections without changing stable-prefix bytes.
- Render template text and non-empty sections in the deterministic order defined
  below.
- Produce `req_llm`-compatible `:system` content.
- Return total size, per-section size, stable-prefix size, volatile suffix size,
  rendered section order, omitted section ids, and stable-prefix metadata.
- Return structured errors for contract violations.

## Section Contract

The builder accepts an ordered list of section structs. Each section has these
fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Caller-stable identifier, unique within one request. |
| `kind` | yes | Caller-defined coarse semantic atom used for diagnostics and ordering tie-breaks. |
| `stability` | yes | `:stable` or `:volatile`. |
| `cache_break_reason` | conditional | Required non-empty short diagnostic reason for `:volatile` sections. Must be absent or empty for `:stable` sections. |
| `tag` | no | Optional prompt block tag. When present, the builder renders the section as `<tag>...</tag>`. |
| `priority` | no | Integer secondary sort key. Defaults to `0`. |
| `content` | yes | `nil`, normalized text, or normalized parts compatible with `ReqLLM.Message.ContentPart`. |
| `provenance` | no | Small caller-owned metadata map for diagnostics and tests. Keys may be reported; values never render or appear in telemetry. |

`id` is a stable key and a diagnostic label. It is not rendered into provider
input. Callers should use stable, low-cardinality ids such as
`profile.instructions`, `skill.guidance:<skill_id>`, or
`brain.context:<retrieval_plan_id>`. Request ids, Message ids, TargetSession
side-channel entry ids, retry counters, and wall-clock timestamps must not be
embedded in section ids.

`kind` is intentionally caller-defined. The builder does not maintain a business
enum for prompt sources and does not interpret `kind` as profile, Skill, Brain,
Principal, or policy semantics. It only requires an atom so diagnostics and
telemetry stay bounded and testable.

`tag` is prompt markup, not a provider protocol. It is useful for long,
source-shaped blocks such as `soul`, `instructions`, `context`, Skill guidance,
or Brain context. Tags must be low-cardinality lowercase names made from
letters, digits, `_`, or `-`, starting with a letter. Tags are rendered into the
system prompt; section ids, kinds, priorities, cache-break reasons, and
provenance are not.

`content = nil` means the section was considered but produced no renderable
content for this request. That is a valid optional path. A missing required field
is different: it is a contract error and prevents rendering.

`content = ""`, an empty part list, or a text part whose text is `""` is a
contract error. Callers that have no renderable content must pass `nil`. A
whitespace-only string is renderable content; the builder does not trim it.

Renderable content is intentionally narrow in v1. A section may provide plain
text or a list of `ReqLLM.Message.ContentPart` values whose `type` is `:text`.
Media, file, tool-result, and provider reasoning parts belong to Conversation
history or provider response handling, not system-prompt sections. The builder
treats accepted text parts as already normalized request-time content and still
validates metadata against the security rules below. Any part whose metadata or
shape marks it as a credential, raw provider payload, raw CloudEvent, raw stream
chunk, or private policy object is rejected before rendering.

The builder treats validated sections as opaque content. It does not query
external state to complete missing fields, infer authorization, redact
Principals, or classify business meaning.

## Stability Discipline

`stability` is the only builder-owned classification for stable-prefix
discipline.

`:stable` sections must produce the same content for the same
request-invariant input. They must not embed current wall-clock time, request
ids, retry counts, generated Message ids, current tool results, current inbound
Event payloads, latest provider diagnostics, cache hit or miss state, delivery
diagnostics, or other request-volatile data.

`:volatile` sections may carry request-specific data. The builder still renders
them into system content, but always after all rendered stable sections and
outside the stable-prefix boundary.

`:volatile` sections must include a short `cache_break_reason`, such as
`current inbound event summary`, `retry diagnostic`, or `request-specific
language override`. The builder validates bounded shape so cache-breaking prompt
content stays reviewable. Stable sections must not carry a cache-break reason.

The builder does not try to prove that a `:stable` section is semantically
stable. Runtime heuristics for detecting timestamps, request ids, or other
volatile facts would be noisy and incomplete. Callers that render stable
sections must test their own rendering code.

## Embedded Template And Rendering Order

Rendering is deterministic:

1. Validate the full section list before rendering any output.
2. Reject duplicate `id` values within the request.
3. Omit sections whose `content` is `nil`; record them in omitted diagnostics.
4. Normalize embedded template text and optional template segments. Empty
   optional segments are omitted.
5. Render all non-empty `:stable` sections before all non-empty `:volatile`
   sections.
6. Within the same stability class, sort by `priority` ascending.
7. For equal priority within the same stability class, keep caller-supplied list
   order as the stable tie-breaker.
8. Do not cross the stable/volatile boundary to improve prompt cache utility.
9. Do not silently drop, merge, truncate, summarize, or reorder content to fit a
   length limit or cache geometry preference.
10. Produce byte-identical output and boundary metadata when called twice with
   the same normalized input.

The embedded template is deliberately not EEx, HEEx, Liquid, Jinja, or a general
prompt DSL. It supports only stable literal text, optional stable segments, and a
sections placeholder. This gives caller code a readable place for short
first-principles product text while preserving typed section diagnostics and
stable-prefix accounting.

Canonical rendering shape:

```elixir
rendered_sections =
  sections
  |> validate_all!()
  |> reject_nil_content()
  |> sort_by_stability_priority_and_input_order()
  |> Enum.map(&section_text!/1)

rendered_units =
  render_template_segments(template, sections_placeholder: rendered_sections)

system_text = Enum.join(rendered_units, "\n\n")
```

`section_text!/1` renders plain text as-is unless the section has a `tag`. A
tagged section renders as:

```text
<tag>
section content
</tag>
```

For a text content-part list, `section_text!/1` extracts each part's text in part
order and joins those texts with exactly `"\n\n"` before optional tag wrapping.
Section ids, kinds, stability labels, priorities, cache-break reasons, and
provenance are never rendered into provider input. Normalized text means valid
UTF-8 text with LF line endings and no NUL bytes; invalid UTF-8, CRLF, and NUL
bytes are contract errors.

`system_text` is the canonical byte sequence. If the returned `system_content`
uses `ReqLLM.Message.ContentPart` values instead of one plain text value, the
builder emits one text part per rendered unit: the first part is the first unit
text, and every later part is `"\n\n" <> unit_text`. Concatenating all returned
text parts must exactly equal `system_text`.

The stable-prefix boundary is the position immediately after the last rendered
stable unit, whether that unit is template text or a stable section. If volatile
sections also render, the `"\n\n"` separator between the last stable unit and
first volatile section belongs to the volatile suffix, not the stable prefix.
The result reports the boundary as a typed descriptor:

```elixir
%{
  last_stable_section_id: "profile.instructions",
  stable_section_count: 3,
  content_part_index: 7,
  byte_offset: 12_048
}
```

`last_stable_section_id` is the id of the final stable section when the boundary
lands on a section; it may be `nil` when only template text renders. The stable
count includes rendered stable units so callers can tell whether a stable prefix
exists. `content_part_index` and `byte_offset` are exact-position metadata for
provider mappings that need explicit cache marker placement. When present, they
must be derived from the same rendered output. Providers with automatic prefix
caching or no prompt-cache support may ignore exact-position metadata.
`byte_offset` is measured with Elixir binary byte semantics, equivalent to
`byte_size(stable_prefix_text)`, not grapheme count or display width. When
`system_content` is returned as text parts, `content_part_index` is the
zero-based index of the last text part wholly inside the stable prefix; it is
`nil` when no stable unit renders.

## Output Shape

Builder output is request-time provider input. It is not durable evidence,
Conversation history, business truth, or usage accounting truth.

The result contains:

- `system_content`: `req_llm`-compatible system role content, represented as
  normalized text or normalized text `ReqLLM.Message.ContentPart` values.
- `stable_prefix`: boundary metadata for token accounting and prompt cache
  hint placement.
- `diagnostics`: rendered order, omitted section ids, per-section sizes, total
  size, stable-prefix size, volatile suffix size, and optional cache-break
  indicators.

Rendering rules:

- The builder targets the `ReqLLM.Context` / `ReqLLM.Message` system-role
  surfaces, or an equivalent list shape accepted by `ReqLLM.Context.normalize/2`.
- Developer-style instructions render only through system text blocks or other
  provider-supported `req_llm` surfaces.
- The builder does not output raw provider JSON, mutate `Req` request bodies, or
  depend on provider-private payload shape.
- Provider-specific behavior must travel through validated `provider_options`,
  `ReqLLM.Message.ContentPart` metadata, or a BullX-owned `req_llm` provider
  override.
- `ReqLLM.Tool` schema delivery remains caller-owned provider-call input and is
  not part of the builder section list.
- The builder does not generate provider prompt-cache markers.

## Length Behavior

Token accounting owns model-specific length judgment. The builder provides
deterministic size information and an optional coarse guardrail:

- Report per-section size, total size, stable-prefix size, and volatile suffix
  size.
- Accept an optional `max_total_bytes` sanity cap.
- Return `{:error, {:system_prompt_builder, :system_prompt_size_exceeded, meta}}`
  when the optional cap is exceeded.
- Never drop, truncate, summarize, or reorder a stable section to satisfy a
  length limit.

Per-section truncation and retrieval shaping belong to the caller before
builder invocation. That keeps the builder deterministic and keeps summarization
decisions out of the rendering boundary.

## Context Compression

The builder handles only request-time system content. Conversation history is
not a builder input.

Summary overlays, history replacement, and compression triggers belong to the
AIAgent context compression design. They operate after system prompt rendering
and must not rewrite the builder output.

Rules:

- System prompt content is regenerated from section input for each request; it
  is not compressed into Conversation truth.
- Compression must not create `kind = summary` Messages that paraphrase system
  prompt content.
- An auxiliary compression model call may reuse the same builder output as a
  stable prefix. Compression-specific instructions are transient suffix input to
  that auxiliary call, not new stable system prompt truth.
- If a `:stable` section changes across turns without a caller-owned input
  change, the caller's section renderer is wrong. Compression must not repair
  unstable system prefixes.

## Prompt Caching

The builder creates a natural cache-stable prefix but does not own prompt
caching policy.

Rules:

- The builder reports stable-prefix boundary metadata.
- Cache marker placement, breakpoint selection, TTL behavior, and
  provider-feature gating belong to the prompt caching design.
- The builder does not produce provider-specific cache markers.
- The builder does not require the selected provider to support explicit prompt
  cache markers. Provider-neutral stable rendering remains useful for automatic
  prefix caching, token accounting, and deterministic tests.
- The builder does not change rendered output to improve cache geometry.
- Cache hits, misses, eviction state, and provider cache diagnostics are not
  builder input and not builder output.

## Invalidation And Recovery

The builder has no internal cache or durable state. Invalidation is expressed by
caller-owned section construction.

When AIAgent profile data, Installation defaults, Skill retrieval, Brain
retrieval, tool guidance, language preference, output policy, or runtime
instructions change, the caller passes a different section list. The builder
does not track or compare prior inputs.

After crash or restart, the caller reconstructs sections from PostgreSQL
business truth and any valid weak runtime state, then invokes the builder again.
The builder guarantees only that the same normalized input produces the same
output and boundary metadata.

The builder does not need a rendered prompt snapshot table, generation lease,
section cache, global registry, recovery table, or invocation log.

## Security

The builder performs low-cost structural safety checks. It is not a general
prompt firewall, secret scanner, redaction engine, or policy evaluator.

Rules:

- Reject content parts explicitly marked as credentials, API keys, signed
  tokens, session secrets, or similar secret-bearing payloads.
- Reject raw provider payloads, raw CloudEvents, raw TargetSession side-channel
  entries, raw stream chunks, and private AuthZ policy internals.
- Do not render `provenance`.
- Do not render Principal identifiers, scope keys, external identity evidence,
  or reply-channel identifiers unless the caller has already authorized and
  redacted them for system prompt use.
- Do not expose Human email, phone, channel metadata, Agent profile fields, or
  external identity metadata by default through builder behavior.
- Never emit section content, credentials, provider payloads, raw CloudEvents,
  Principal evidence values, or private policy internals in telemetry.

The caller remains responsible for source-specific retrieval, authorization,
redaction, policy gates, and high-risk action approval. The builder only
protects its own rendering boundary.

## Failure Behavior

Builder failures are caller bugs or input contract violations. They are not
provider failures and are not Conversation business failures.

Failure cases include:

- Missing required section fields.
- Non-atom `kind`.
- Unknown `stability` value.
- Duplicate `id`.
- Missing or malformed `cache_break_reason` for a volatile section.
- Cache-break reason present on a stable section.
- Malformed prompt block tag.
- Template text placed after a volatile section, which would make the stable
  prefix non-contiguous.
- Explicit credential or raw-payload content shape rejected by the allowlist.
- Optional `max_total_bytes` cap exceeded.

The builder returns structured errors:

```elixir
{:error, {:system_prompt_builder, reason, metadata}}
```

`metadata` may include `section_id`, `kind`, `stability`, size information, and
bounded reason data. It must not include section content or secret-bearing
values.

The caller maps the error to the owning AIAgent Core behavior, such as profile
validation failure, safe generation failure before provider call, or
TargetSession failure. Retrying the builder with the same invalid input is not a
recovery path; the caller must fix the input or fail the current generation.

## Telemetry

The builder emits content-free telemetry under
`[:bullx, :ai_agent, :system_prompt, ...]`.

`[:bullx, :ai_agent, :system_prompt, :built]` measurements:

- total size
- stable-prefix size
- volatile suffix size
- rendered stable section count
- rendered volatile section count
- omitted section count
- build duration

`[:bullx, :ai_agent, :system_prompt, :built]` metadata:

- rendered section ids
- omitted section ids
- section kinds
- section stability values
- cache-break reason presence flags
- provenance keys

`[:bullx, :ai_agent, :system_prompt, :error]` metadata:

- `reason`
- `section_id`
- `kind`
- `stability`
- provenance keys

Telemetry metadata uses an allowlist. Section content, provenance values,
credentials, provider payloads, raw CloudEvents, Principal evidence values, and
private AuthZ internals are never emitted.

## Implementation Handoff

### Goal

Implement the System Prompt Builder so AIAgent Core can normalize all
system-prompt-eligible inputs into typed sections, render `req_llm` system
content, and pass stable-prefix metadata to token accounting and prompt caching.

### Context Pointers

- `docs/Architecture.md`
- `docs/design-docs/LLMProvider.md`
- `docs/design-docs/Principal.md`
- `docs/design-docs/AuthZ.md`
- AIAgent Core design
- AIAgent context compression and prompt caching design

### Constraints

- Keep the builder stateless and side-effect-free.
- Do not call EventBus, TargetSession, LLMProvider, Brain, Skill, ToolSet,
  Principal, AuthZ, or future Capability code from the builder.
- Do not read Conversation / Message rows from the builder.
- Do not output raw provider JSON or mutate `Req` request bodies.
- Do not use provider-private surfaces outside `req_llm`.
- Do not silently drop, truncate, summarize, or reorder stable sections.
- Do not record section content.
- Do not add a builder cache, builder snapshot table, generation lease, or
  rendered system prompt persistence.
- Do not introduce a global section registry.

### Tasks

1. Define the section struct and validator.
   - Owns: section fields, atom `kind` validation, stability validation,
     duplicate id detection, prompt tag validation, cache-break validation, and
     coarse content allowlist.
   - Acceptance: malformed input returns structured errors before rendering;
     volatile sections without cache-break reasons fail; stable sections with
     cache-break reasons fail.

2. Implement deterministic ordering and rendering.
   - Owns: nil-content omission, stable-before-volatile rendering,
     priority sorting, input-position tie-breaks, embedded template segments,
     tagged section rendering, canonical `"\n\n"` unit joining, unit-level
     text-part output, and `req_llm` system content generation.
   - Acceptance: identical input produces byte-identical output; adding or
     removing `content = nil` sections does not change stable-prefix bytes;
     empty strings and empty text parts fail validation.

3. Implement size estimation and boundary reporting.
   - Owns: per-section size, total size, stable-prefix size, volatile suffix
     size, required logical stable-prefix descriptor fields, optional exact
     position metadata, and optional `max_total_bytes` enforcement.
   - Acceptance: size-cap overflow fails the request; no section is dropped,
     truncated, summarized, or reordered by the builder; exact-position metadata,
     when present, describes the same rendered stable-prefix boundary.

4. Implement safety checks and telemetry.
   - Owns: known credential and raw-payload shape rejection, structured error
     metadata, and allowlisted telemetry fields.
   - Acceptance: explicit credential or raw payload input fails before provider
     input exists; telemetry contains no section content.

5. Integrate AIAgent Core prompt rendering.
   - Owns: caller-side section construction, builder invocation, and handoff of
     rendered output plus stable-prefix metadata to provider-call assembly.
   - Acceptance: restart reconstruction with the same normalized caller state
     produces the same builder output; no hidden global section registry is
     introduced.

6. Integrate context compression and prompt caching.
   - Owns: consuming stable-prefix metadata for cache hint placement and keeping
     compression from rewriting system prompt content.
   - Acceptance: provider cache markers, when supported through `req_llm`, align
     with the reported boundary; providers without explicit markers still receive
     deterministic system content; Conversation history compression does not
     alter builder output.

### Stop And Ask

Implementation must stop for review if any of these become necessary:

- The builder needs direct access to Conversation / Message, Brain, Skill,
  ToolSet, EventBus, TargetSession, Principal, AuthZ, or future Capability state.
- The builder needs persistence, a generation lease, section cache, global
  registry, or cross-request memoization.
- The builder needs to silently discard, truncate, summarize, or reorder content
  to fit cache or length constraints.
- The builder needs to embed plaintext credentials, provider raw payloads, raw
  CloudEvents, raw stream chunks, or private AuthZ internals into system content.
- System prompt content needs to participate in Conversation compression or be
  represented as a `kind = summary` Message.
- The builder needs to generate provider-specific cache markers.
- `ReqLLM.Tool` schemas need to be rendered into system prompt content instead
  of the provider call's independent `tools` option.

## Done When

- AIAgent Core normalizes every system-prompt-eligible source into typed
  sections and calls the builder.
- The builder is pure, stateless, deterministic, and reconstructible from caller
  input.
- Stable sections always render before volatile sections.
- The stable-prefix boundary is available to token accounting and prompt
  caching.
- Section rendering uses the canonical `"\n\n"` template, and any returned text
  parts concatenate to the same canonical system text.
- Embedded template text can provide short stable product framing without
  becoming a general template language.
- Tagged sections render source-shaped prompt blocks such as `<soul>`,
  `<instructions>`, and `<context>`.
- Volatile sections carry bounded cache-break diagnostics, and the
  stable/volatile boundary remains the required cache contract.
- Optional `content = nil` sections are omitted without producing empty prompt
  blocks or changing stable-prefix bytes.
- Contract violations and size-cap overflow return structured errors.
- Builder output excludes credentials, raw provider payloads, raw stream chunks,
  raw CloudEvents, private AuthZ internals, and unapproved Principal evidence.
- System prompt content is not written as Conversation history, not compressed
  into summary Messages, and not persisted as a rendered snapshot.
- Provider cache markers are placed outside the builder based on the reported
  boundary.
- Builder telemetry is content-free and uses allowlisted metadata only.
- Focused builder tests pass, followed by `bun precommit`.
