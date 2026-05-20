# AIAgent context compression and caching

BullX keeps Conversation and Message records as the durable evidence for an
AIAgent conversation. Context compression, request-time large-result compaction,
and prompt caching are provider-input optimizations layered on top of that
evidence. They may change the provider-renderable history for a request, but
they must not delete, rewrite, reorder, or replace the raw Conversation facts.

This design belongs inside the AIAgent runtime. EventBus delivers Events to a
TargetSession, TargetSession invokes the AIAgent Target, and the Agentic Loop
prepares model input from durable Conversation state plus request-time runtime
context. EventBus, TargetSession, LLM provider catalog, application cache, Brain,
future Budget, future Capability, and Work records keep their own boundaries.

## Scope

This document defines:

- Context compression for an active Conversation branch.
- `kind = summary` Message validation and summary overlay rendering.
- The deterministic `original_dialogue_time_range` summary prefix.
- Provider-required tool-call and tool-result preservation during compression.
- Request-time compaction of large historical tool results.
- Compression auxiliary-call constraints and structured summary content.
- Oversized compression request retry and failure behavior.
- Manual compression after a canonical AIAgent command has been accepted by the
  command path.
- Content-free telemetry and repeated compression failure guards.
- Provider-native prompt cache hint placement through existing `req_llm`
  message, content-part, and provider-option surfaces.
- Implementation handoff and acceptance criteria.

This document does not define:

- EventBus acceptance, routing, TargetSession side-channel storage, or
  TargetSession worker behavior.
- Slash command catalog, localized command aliases, command routing, or command
  ACLs.
- AIAgent identity, Conversation key selection, input modes, main model/tool
  loop ownership, visible delivery, daily reset, or streaming output.
- LLM provider catalog storage, provider registration, encrypted credentials,
  provider option validation, or `req_llm` runtime settings.
- Brain, Work, future Budget, future Capability, Governance, audit, or external
  action schemas.
- System prompt construction. This design consumes the Agentic Loop system
  prompt builder output and its stable-prefix boundary; it does not define the
  builder input blocks or ordering rules.
- New tables for summaries, prompt cache entries, rendered prompt snapshots, or
  provider cache backends. This includes creation, lifecycle management, or
  durable storage for provider cached-content resources.
- Raw HTTP request mutation or provider-private prompt editing outside typed
  `req_llm` message, content-part, or provider-option surfaces.

## Boundaries

The AIAgent runtime calls this compression and caching layer after it has
validated the AIAgent profile, selected the Conversation, persisted inbound
Messages, and prepared to render model input. This layer does not call EventBus,
does not inspect Event Routing Rule matchers, does not decide whether a
tool or future Capability may execute, and does not write visible delivery state.

Context compression may write a `kind = summary` Message into the Conversation.
The raw Messages covered by that summary remain durable evidence. A summary only
affects later provider input rendering through overlay rules.

Request-time large-result compaction changes only the provider input built for
one request. It does not update `conversation_messages.content`, delete raw tool
results, synthesize tool completion, or change the raw evidence available to
Brain, audit, Work, or business ingestion.

Prompt caching emits provider rendering hints only. `context.prompt_cache` is a
BullX AIAgent profile/rendering option, not a field on `ReqLLM.Context`. Cache
hints are not Conversation truth, Budget truth, EventBus routing state,
TargetSession state, or provider-private continuation state.

The system prompt builder owns request-time `:system` content. Compression and
caching consume that output and its stable-prefix boundary. They do not copy the
builder output into summary Messages, derive a competing stable prefix, or
change builder ordering for cache geometry.

## Provider input preparation

Each model call prepares provider input in a deterministic order:

1. The AIAgent runtime reconstructs the raw active Conversation branch and
   obtains the request-time system prefix plus stable-prefix boundary.
2. The renderer selects one summary overlay compatible with that raw active
   branch and produces a provider-renderable Conversation branch.
3. The renderer may compact eligible historical large tool results in the
   request-time provider input while preserving provider-required tool-result
   structure and correlation fields.
4. The renderer validates provider structure: role order, tool-call and
   tool-result pairing, content block shape, and status.
5. Token accounting evaluates the optimized provider input against the safe
   context budget. If the input is still too large, the AIAgent runtime invokes
   durable context compression, writes a complete summary when successful, and
   repeats preparation.
6. Prompt cache hints are added last. Hint placement is based on the final
   provider input after summary overlay and large-result compaction.

This order prevents three classes of bugs: rearranging history for cache
benefit, writing durable summaries when request-time compaction is sufficient,
and treating provider cache state as Conversation truth.

## Summary Message contract

Context compression reuses the Conversation Message store. It does not add a
summary table.

A summary Message has these required properties:

- `role = assistant`.
- `kind = summary`.
- `status = complete`.
- `content` contains BullX-owned summary content blocks, not raw provider
  payloads.
- `covers_range = {from_id, to_id}`.
- `metadata.source_leaf_message_id` points to the raw branch leaf used when the
  summary was generated.
- `metadata.original_dialogue_time_range` stores the covered dialogue time range
  in the Installation runtime time zone, truncated to minutes.
- `metadata.compression.estimated_input_tokens`,
  `metadata.compression.estimated_output_budget`,
  `metadata.compression.usage`, and
  `metadata.compression.usage_source` store content-free accounting for the
  auxiliary compression call.
- `target_session_id` and `target_session_entry_id` may record the runtime
  source that triggered compression. Maintenance compression may leave them
  empty.

`covers_range` is a closed interval on one active branch. It must not cross
branches, cover a `generating` Message, cover the current inbound user or
command entry, or cover Messages that are no longer on the raw path rooted at
`metadata.source_leaf_message_id`.

The AIAgent runtime computes `original_dialogue_time_range` from raw covered
Messages. User Messages prefer `metadata.time_awareness.send_at`; other Messages
or missing metadata use the persisted timestamp. Both endpoints are converted to
the Installation runtime time zone and truncated to minutes. If both endpoints
fall in the same minute, the closed range still uses that minute value.

The time range helps the model understand when the summarized dialogue happened.
It does not decide future time-awareness injection. Future injection decisions
still inspect the raw branch for the previous true user Message that received a
time prefix.

The summary content begins with a deterministic prefix generated by BullX:

```text
<meta>original_dialogue_time_range: YYYY-MM-DD HH:MM to YYYY-MM-DD HH:MM</meta>
```

The prefix is followed by one newline and then the model-generated summary. The
compression model must not invent, rewrite, or omit the prefix.

## Summary overlay

A summary Message is an overlay node, not chronological dialogue. Rendering
first reconstructs the raw active branch up to
`summary.metadata.source_leaf_message_id`, replaces the branch-local closed
interval `[from_id, to_id]` with the summary block, keeps raw tail Messages
after `to_id`, and skips the summary Message's physical insertion position.

Overlay rules:

- Summary overlay never deletes raw Messages.
- Summary overlay never changes raw branch evidence.
- Summary overlay affects only provider input rendering.
- Multiple summaries may exist, but one render applies at most one compatible
  summary overlay. The default selection is the latest valid summary on the
  current branch, with `id` as a stable tiebreaker.
- The renderer does not combine summaries to maximize token savings.
- If summary metadata is incompatible with the raw active branch, the renderer
  ignores that summary or enters safe recovery. It must not build
  provider-invalid history.

The renderer must not infer dialogue order from the physical parent chain of the
summary Message. It must reconstruct the raw branch first, then apply overlay.

Physical placement rules:

- A summary Message is written with
  `parent_id = metadata.source_leaf_message_id`. This makes the summary
  reachable from the raw leaf that was compressed, but it does not make the
  summary the next chronological dialogue Message.
- A summary Message is not a valid append parent for new user, ambient,
  assistant, tool, or error Messages. If `current_leaf_message_id` points to a
  summary, the AIAgent branch resolver uses
  `metadata.source_leaf_message_id` as the raw active leaf before appending new
  Messages or rendering provider input.
- A compatible summary may be selected for rendering when its
  `metadata.source_leaf_message_id` lies on the resolved raw active branch and
  its `covers_range` is a closed interval on that branch. The summary does not
  need to be a physical ancestor of the current raw leaf.
- Command handlers may refer to a summary Message id, but slash command inputs
  and command responses are not Messages and do not use `parent_id`.

## Context compression

Context compression converts an over-budget active Conversation branch into a
shorter provider-renderable history view while preserving head context, a
token-budgeted tail, and provider-required structure. Automatic trigger
thresholds belong to the AIAgent runtime's token accounting. Manual compression
uses the same algorithm after the command path decides that compression should
run.

Compression may cover only branch-local complete provider rounds. A provider
round is the smallest safe segment that can be preserved, summarized, or replaced
without breaking provider semantics. It must not split one assistant response,
split assistant tool calls from matching tool results, cut through a
`generating` Message, include the current inbound Message, or split incomplete
tool-result pairs.

When a candidate boundary is unsafe, compression expands outward to a complete
round. If expansion would enter the protected head, protected tail, or current
inbound/generating Message, compression chooses a smaller safe interval or
fails.

BullX follows a head-middle-tail compaction shape. The protected tail is not
configured as a fixed Message count. V1 derives a tail token budget as
`safe_context_limit * context.compression_threshold_ratio * 0.20`; the `0.20`
value is a BullX-owned implementation constant, not a profile field. The
renderer walks backward from the raw branch leaf, accumulating estimated
provider-input tokens until that budget is reached, then moves the cut backward
to a complete provider-round boundary. The middle interval between the protected
head and protected tail is the summarization candidate.

`safe_context_limit` is based on the active model config's effective
`context_window`, not the provider's max-output token limit. Setup should fill
that value from dynamic provider metadata, local model metadata, or an operator
override. Runtime falls back to `80000` when the profile lacks a usable value.

Compression execution follows these rules:

1. Preserve the system prompt builder output. Compression must not paraphrase,
   summarize, replace, or rewrite request-time system/developer prompt content.
2. Preserve opening user context when it anchors the Conversation. Do not create
   fake openers for cache geometry.
3. Preserve a token-budgeted tail. Move the tail start backward to a complete
   provider-round, complete assistant-response, and complete tool-call/tool-result
   boundary.
4. Select one complete provider-round interval from the active branch for
   summarization.
5. Preserve provider-required tool-call and tool-result structure.
6. Resolve `compression_llm` through the same model-call boundary used by the
   AIAgent runtime, and treat the call as an AIAgent-owned auxiliary model call.
7. Invoke the auxiliary compression call with no executable tools, no
   `tool_choice`, and no provider-native tool schemas. The expected result is
   text summary content only. Any provider tool call emitted by the compression
   model is treated as compression failure.
8. The auxiliary compression input may replace non-text media or document blocks
   with safe markers and may omit oversized provider-private payloads. The
   summary may describe only information the compression model actually
   received. If markers or omissions were used, the summary content must disclose
   that limitation safely.
9. Read normalized usage from the compression model response when available.
   Use `ReqLLM.Response.usage/1`, `ReqLLM.StreamResponse.usage/1`, or equivalent
   materialized response usage. Do not store raw provider payload usage. Missing
   provider usage is recorded as estimated accounting with
   `metadata.compression.usage_source = "estimated"`.
10. Compute `metadata.original_dialogue_time_range` from covered raw Messages and
   prepend the deterministic meta prefix to summary content.
11. Write one complete summary Message with
    `parent_id = metadata.source_leaf_message_id` and `covers_range` covering
    only the interval actually seen by the summarizer.
12. Before moving the Conversation leaf, recheck the generation lease,
    Conversation active state, and raw branch leaf. If the lease is invalid or
    the leaf changed, the summary result must not advance
    `current_leaf_message_id`.
13. Move `current_leaf_message_id` to the summary Message only after the summary
    Message is written and lease/leaf checks still pass.

When `compression_llm` resolves to the same provider and model as the main
generation model, the compression request may reuse the same system prompt
builder output and stable-prefix boundary for vocabulary and safety context, but
it still omits executable tools and provider tool schemas. It then appends a
transient compression instruction after the rendered history. It does not
introduce a separate summarizer-specific stable system prompt. If a different
`compression_llm` is configured, the different provider/model and cache
namespace are an AIAgent profile tradeoff.

The transient compression instruction is auxiliary provider input. It is not a
chronological Conversation Message and is not eligible as a future prompt cache
breakpoint.

The generated summary content uses a small BullX-owned envelope. After the
deterministic meta prefix, the body should contain these sections when relevant:
`Goal`, `Constraints and Preferences`, `Progress`, `Decisions`, `Relevant Files
and Records`, `Current Work`, and `Next Step`. Empty sections are omitted. The
runtime stores only the final summary body, not model draft text, hidden
reasoning, alternative summaries, or prompt instructions.

If the compression request itself is too large for the provider context window,
the runtime may retry by removing oldest complete provider rounds from the
summarizer input. If the provider error reports the token gap, the runtime drops
enough complete rounds to cover that gap plus padding. If no useful gap is
reported, the runtime drops the oldest complete provider rounds in bounded
batches until the estimator returns under the safe compression-request budget.
`covers_range` must shrink to the closed interval the summarizer actually saw.
Compression must not claim coverage for omitted Messages. If bounded retry
cannot produce a final provider input within safe budget, compression fails.

Automatic generation-time compression failure fails the current entry's
generation path. The AIAgent writes a safe diagnostic `kind = error` Message,
releases the generation lease through normal recovery, and returns success from
the Target path when the failure has been durably recorded. It must not write a
fake summary to pretend context was safely preserved.

Manual compression failure is a command result. It may write a safe diagnostic
`kind = error` Message or return a safe command response, but it does not call
the main model and does not write a fake summary.

Auxiliary compression calls that produce no visible output may use the AIAgent
runtime's provider retry or fallback policy before any visible assistant reply
starts.

V1 enforces at most three compression attempts for one generation lease or
TargetSession entry. After that guard trips, the entry goes through the durable
error path instead of trying another compression variant.

## Manual compression

Manual compression lets a human request early compression before automatic token
thresholds require it. The command path owns slash tokens, localized aliases,
adapter-normalized command Events, ACLs, active-generation checks, command
control operation handling, and safe command responses. This design owns what
happens after that path invokes compression.

Manual compression rules:

- The command input is not persisted as a Conversation Message.
- If a summary is written, it becomes the current Conversation leaf through the
  normal summary write path.
- Command responses are not rendered as ordinary provider dialogue.
- Manual compression does not call the main model and does not execute tools.
- Manual compression may run even when the optimized provider input is still
  below safe budget, but it must still select a branch-local complete
  provider-round interval.
- Manual compression requires that the Conversation has no active generation
  lease. It does not preempt, cancel, wait for, or compress through active
  generation.
- If no safe complete provider-round interval exists, the command is a safe
  no-op: no summary is written, `current_leaf_message_id` does not move, and no
  generation failure is reported.
- If a summary is written, `metadata.trigger` may record `manual_command`, and
  `target_session_entry_id` may point to the command entry.
- Manual compression does not bypass access control, Budget, model policy, or
  the compression failure guard.
- Command redelivery follows the command handler's control-plane semantics. Once
  a command entry has produced a valid summary, repeated delivery must not write
  another summary.

Manual compression only shortens future provider-renderable history. It does not
delete raw Messages, alter Brain, alter Work, alter audit records, or guarantee
that the next provider call will be under budget. The next generation still
performs full preparation, token accounting, and provider-structure validation.

## Request-time large-result compaction

Large-result compaction is a request-time rendering optimization. It applies only
to allowlisted historical tool results that are outside the protected tail, have
a complete provider-required pair, and remain readable from durable raw Messages.

Rules:

- Large-result compaction runs after summary overlay and before token accounting
  and prompt cache hints.
- It may replace bulky historical output from allowlisted result classes such as
  file reads, shell logs, search results, web fetch bodies, diffs, large JSON
  payloads, and low-risk local or sandbox write/update confirmations with a short
  marker such as
  `tool result content omitted from prompt; raw Message remains durable`.
- The marker must preserve provider-required `tool_use_id` or equivalent
  correlation fields.
- Current inbound entries, protected-tail tool results, incomplete tool pairs,
  command responses, visible delivery diagnostics, error recovery
  diagnostics, and high-risk tool or future Capability results are not compacted
  unless the relevant owning design defines a safe summary contract.
- Any result that confirms a governed external side effect, irreversible action,
  approval outcome, financial/legal/customer-facing operation, or business record
  mutation is high-risk for compaction unless its owning design explicitly marks
  a compactable summary shape.
- V1 performs BullX-owned content replacement in provider input. It does not use
  provider-private prompt editing APIs or mutate raw provider request bodies.
- Large-result compaction does not write a `kind = summary` Message, move
  `current_leaf_message_id`, change raw branch evidence, or affect Brain, audit,
  or business ingestion.
- If provider input remains over budget after compaction, the runtime invokes
  durable context compression or enters the failure path. It must not keep
  appending markers indefinitely.

## Tool structure validity

Compression and compaction must preserve provider-required tool-call and
tool-result shape.

Rules:

- Every preserved assistant Message with tool-call blocks must have matching
  tool-result blocks in the rendered provider input.
- The renderer must not produce orphan tool-result blocks.
- Tool-result Messages preserve provider-required tool call ids or equivalent
  correlation fields.
- Providers may accept multiple tool calls matched by one tool Message with
  multiple result blocks, or by several provider-compatible tool Messages. The
  final provider input sequence must be valid for the chosen provider.
- If a provider-required pair cannot safely fit in context, compression must
  summarize or preserve the pair as a unit.
- Structured tool-result errors for unknown, malformed, denied, or crashed tool
  calls count as legal tool results.
- If one assistant response is stored across multiple Messages that share a
  provider response id or equivalent id, compression and protected-tail selection
  treat those Messages as one response unit.

## Prompt caching

Prompt caching is provider-native rendering optimization. It does not change
Conversation history, summary overlay semantics, or durable business truth.

Rules:

- `context.prompt_cache = true` allows the BullX renderer to attempt
  provider-native prompt caching for this AIAgent profile. It is consumed before
  BullX builds the `ReqLLM.Context`; it is not sent as a `ReqLLM.Context` field.
- `context.prompt_cache = false` disables BullX-added prompt cache hints.
  Providers with automatic prefix caching may still cache exact repeated
  prefixes without any explicit BullX marker.
- When `context.prompt_cache = true`, the renderer must first resolve the
  selected provider/model and choose one of the `req_llm` mappings below. If no
  mapping is supported, rendering proceeds without cache markers.
- Cache hints are added only after summary overlay and large-result compaction.
- Hint placement is based on the final provider input. A breakpoint must not
  target a block that will be replaced by a marker before the provider receives
  it.
- The system prompt builder output and stable tool schemas are the preferred
  cache prefix. The builder-reported stable-prefix boundary is the natural cache
  anchor.
- Volatile runtime context such as current time, heartbeat, retry count, visible
  stream status, and delivery diagnostics must not enter the cache-stable
  prefix.
- Transient request blocks, current inbound entries, `generating` Messages,
  command responses, branch-incompatible summaries, delivery diagnostics,
  and incomplete tool-call/tool-result pairs are cache-ineligible.
- Cache hints must not expose credentials, private policy internals, raw
  provider payloads, or plaintext secrets.
- Cache hit, cache miss, and provider cache eviction are not business Events and
  are not written to Conversation or Message truth.
- Cache miss is not generation failure. Rendering continues without cache
  benefit.
- Provider minimum cacheable sizes, TTLs, and explicit breakpoint limits are
  provider capability gates. They affect whether hints are emitted, not when
  compression runs and not how model-call results are recorded.
- Provider TTL or cache eviction may influence request-time hint placement or
  rolling breakpoint selection. TTL must not mutate durable Messages and must
  not define summary coverage.

The renderer treats prompt input as three regions:

1. Cache-stable prefix: system prompt builder output and stable tool schema
   blocks, bounded by the builder-reported stable-prefix boundary.
2. Append-only rendered history: the provider-renderable Conversation branch
   after summary overlay.
3. Request-volatile suffix: current inbound entry, transient runtime context,
   current tool results, retry diagnostics, and other data expected to change
   before the next request.

Static content should stay before volatile content, but cache optimization must
not break provider-required message order, branch order, or tool-call/tool-result
pairing.

The implementation mapping is deliberately small:

- Direct Anthropic-family providers supported by `req_llm` use
  `provider_options: [anthropic_prompt_cache: true]`. When BullX has selected a
  cacheable rendered-history breakpoint, it may also pass
  `anthropic_cache_messages: index`; when a provider-validated TTL is configured,
  it may pass `anthropic_prompt_cache_ttl`. This uses the provider adapter's
  typed option path, which injects cache control for system prompts, tools, and
  the selected message.
- Anthropic models reached through OpenRouter use
  `ReqLLM.Message.ContentPart.metadata.cache_control` on the selected
  cache-eligible content parts. BullX only emits this metadata when the resolved
  OpenRouter model is known to route to an Anthropic-compatible cache-control
  surface.
- OpenAI-style automatic prefix caching receives no explicit cache marker and no
  BullX-supplied cache identity. BullX preserves an exact stable prefix and
  reads provider-native cache usage from `ReqLLM.Response.usage/1` or
  `ReqLLM.StreamResponse.usage/1`.
- Google Gemini cached-content resources are not created or managed by
  `context.prompt_cache`. Although `req_llm` exposes Google's cached-content API
  and `provider_options[:cached_content]`, that API has provider resource
  lifecycle and storage semantics. It needs a separate owner before BullX can use
  it.
- `ReqLLM.Cache`, `cache_key`, `cache_ttl`, and `cache_options` are
  application-layer response caching, not provider-native prompt caching, and
  are not used by the main Agentic Loop.

For providers with explicit per-block cache hints, BullX uses only `req_llm`
content-part metadata or validated provider options. The default placement
strategy is:

- Mark the system prompt builder stable-prefix boundary and stable tool schema
  boundary first.
- If provider breakpoint budget remains, choose a recent cache-eligible complete
  content block in rendered history as a rolling breakpoint.
- Do not exceed provider explicit breakpoint limits.
- Skip transient request blocks and cache-ineligible Messages.
- Skip marker blocks produced by request-time large-result compaction unless the
  provider explicitly treats the marker as stable and cacheable.
- Use provider default TTL unless a selected `req_llm` provider exposes a
  validated longer-TTL option.

This strategy does not create a BullX cache-key table or routing service.
Anthropic/OpenRouter-style `cache_control` belongs in `ReqLLM.Message`
content-part metadata or provider-supported options. OpenAI-style automatic
caching normally needs no explicit marker. AIAgent code must not mutate raw
provider HTTP bodies outside the `req_llm` boundary to add cache hints.

If a provider exposes opaque continuation state, it is handled by the Agentic
Loop provider-continuation rules, not by prompt caching.

## Recovery and failure guards

Summary writes are atomic from the renderer's point of view. A compression
attempt may leave only one of these states:

- No new summary Message exists.
- A complete summary Message exists with valid `covers_range` and
  `metadata.source_leaf_message_id`.

If crash recovery finds an incomplete or invalid summary Message, the renderer
must not use it for overlay. Recovery may mark it as an error or write safe
diagnostics through normal AIAgent recovery behavior.

If a crash happens before `current_leaf_message_id` moves to the summary Message,
the raw branch remains renderable. If it happens after the leaf moves, rendering
still reconstructs the raw branch through `metadata.source_leaf_message_id` and
applies overlay rules.

If ignoring an invalid summary leaves provider input over budget, the runtime may
invoke compression again. A single generation lease or TargetSession entry must
enforce the same at-most-three-attempt repeated-failure guard so
prompt-too-long, invalid summary, and retry handling cannot loop forever. The
guard does not require a new table; it may live in generation coordination
metadata or current-entry attempt state. After process crash, durable error and
recovery behavior converge the entry.

## Telemetry and privacy

Compression and caching telemetry is content-free. Allowed metadata includes:

- Reason code.
- Estimated input tokens and output budget.
- Normalized provider-reported input, output, total, and reasoning tokens.
- Candidate Message count.
- Summary token count.
- Coverage size.
- Retry count.
- Provider id and model id.
- Cache hint strategy.
- Duration.

Telemetry, logs, and diagnostics must not include summary content, raw tool
result content, credentials, raw CloudEvents, raw provider payloads, stream
chunks, or private policy data.

## Implementation handoff

### Goal

Implement AIAgent context compression, summary overlay rendering, request-time
large-result compaction, and provider-native prompt cache hints without changing
durable Conversation truth or EventBus/TargetSession boundaries.

### Context pointers

- `docs/Architecture.md` defines the EventBus, TargetSession, AIAgent,
  Conversation, Brain, Work, Skill, future Budget, future Capability, and
  persistence boundaries.
- `docs/design-docs/LLMProvider.md` defines the LLM provider catalog and
  `req_llm` boundary. It does not own Agentic Loop behavior or prompt
  orchestration.
- `docs/design-docs/Cache.md` defines the application cache facade. Prompt
  caching in this design is provider-native rendering behavior, not
  `BullX.Cache`.
- `docs/design-docs/eventbus/Core.md` defines Event acceptance, side-channel
  delivery, TargetSession invocation, and Command Target routing boundaries.
- `docs/design-docs/eventbus/StreamingOutput.md` defines weak Redis runtime
  output streams. Stream chunks are not Conversation transcripts.

### Constraints

- Do not add summary, prompt cache, rendered prompt snapshot, or provider cache
  backend tables.
- Do not persist rendered provider prompts unless a later audit design explicitly
  defines that storage.
- Do not store raw provider payloads, credentials, plaintext secrets, or provider
  cache internals in Conversation metadata.
- Do not delete raw Messages or alter raw branch evidence.
- Do not let the compression model generate or change
  `original_dialogue_time_range`; BullX computes it from covered Messages.
- Do not let manual compression bypass command ownership, generation lease,
  access control, Budget, model policy, or compression failure guards.
- Do not duplicate, paraphrase, summarize, replace, or rederive the system prompt
  builder output.
- Do not write request-time large-result compaction output back to
  `conversation_messages.content`.
- Do not let provider cache TTL, cache miss, or cache eviction alter Conversation
  truth, Budget truth, or summary coverage.

### Tasks

1. Add summary Message validation.
   - Owns: `kind = summary`, `covers_range`,
     `metadata.source_leaf_message_id`, and
     `metadata.original_dialogue_time_range` validation.
   - Acceptance: coverage is a closed interval on one active branch, excludes
     `generating` and current inbound Messages, and formats the time range to
     minute precision in the Installation runtime time zone.

2. Add summary overlay rendering.
   - Owns: raw branch reconstruction through `metadata.source_leaf_message_id`,
     interval replacement, raw tail preservation, and physical summary
     position skipping.
   - Acceptance: prompt rendering never appends a summary as ordinary
     chronological assistant dialogue.

3. Add provider-round interval selection.
   - Owns: complete provider-round selection, token-budgeted tail selection,
     and protection for current inbound Messages, `generating` Messages,
    command responses, and incomplete tool pairs.
   - Acceptance: compression does not split assistant response fragments or
     tool-call/tool-result pairs.

4. Add manual compression handoff.
   - Owns: receiving a canonical compression command result from the command
     path and recording summary, no-op, or safe error outcomes.
   - Acceptance: manual compression does not call the main model, execute tools,
     preempt active generation, or duplicate summary writes on command
     redelivery.

5. Add context compression execution.
   - Owns: `compression_llm` resolution, no-tools auxiliary model call,
     structured summary envelope, bounded retry for oversized compression input,
     complete summary write, and lease/leaf recheck before moving the
     Conversation leaf.
   - Acceptance: `covers_range` covers only Messages seen by the summarizer; the
     summary content starts with the BullX-generated meta prefix and newline;
     summary output follows the BullX envelope without storing draft prompt text;
     normalized usage is recorded when available; estimated usage is marked when
     provider usage is missing; failure writes safe diagnostics and never writes
     a fake summary.

6. Add request-time large-result compaction.
   - Owns: provider input content replacement after summary overlay and before
     cache hints, limited to allowlisted result classes.
   - Acceptance: raw Message content is unchanged, provider input keeps legal
     tool-result blocks and correlation fields, and current, protected-tail,
     incomplete, diagnostic, and high-risk results are protected.

7. Add provider-valid tool structure validation.
   - Owns: validation of assistant tool-call and tool-result pairs after
     compression and compaction.
   - Acceptance: rendered input has no orphan tool results and no preserved
     tool-call side without its matching result side.

8. Add prompt cache hints.
   - Owns: provider cache hint generation through supported `req_llm` content
     metadata or provider options.
   - Acceptance: hints are added only after overlay and compaction, prefer the
     builder-reported stable-prefix boundary, skip cache-ineligible blocks,
     respect provider limits, and never become Conversation truth.

9. Add content-free telemetry and compression failure guard.
   - Owns: metrics, allowlisted metadata, and repeated-failure guard per
     generation lease or TargetSession entry.
   - Acceptance: telemetry excludes content, credentials, raw provider payloads,
     raw CloudEvents, stream chunks, and private policy data; repeated
     prompt-too-long attempts cannot loop indefinitely; V1 stops after at most
     three compression attempts for the same lease or entry.

### Done when

- Summary Messages render as overlays through
  `metadata.source_leaf_message_id`.
- Summary metadata and content carry the BullX-computed
  `original_dialogue_time_range` at minute precision.
- Summary overlay replaces covered branch-local intervals without deleting raw
  Messages or rendering summaries at their physical chronological position.
- Compression never deletes raw Messages and never writes fake summaries.
- Compression failure writes safe diagnostics.
- Compression preserves tool-call/tool-result structure and complete assistant
  response units.
- Compression protects the tail by token budget, not by any fixed Message
  count.
- Compression auxiliary calls do not expose executable tools and store only the
  final summary envelope content.
- Oversized compression input uses bounded retry, and coverage never includes
  Messages omitted from summarizer input.
- Compression usage is normalized through `req_llm` response usage surfaces when
  available and marked as estimated when provider usage is missing.
- Repeated compression failures for one generation lease or TargetSession entry
  trip the failure guard after at most three attempts and enter durable error
  handling.
- Manual compression can run before token threshold, but does not call the main
  model, execute tools, preempt active generation, or
  duplicate outcomes on redelivery.
- Request-time large-result compaction affects only provider input, is limited to
  allowlisted historical result classes, and never writes a summary Message.
- Prompt cache hints are provider-rendering hints only, use stable-prefix
  discipline, respect provider limits, and never mutate durable business facts.
- Compression and prompt caching consume the system prompt builder output and
  stable-prefix boundary without rederiving or persisting system prompt content.
