# Changelog

## Version 26.07.8 (2026-07-15)

- Rename the `jina` provider's display label from "Jina AI" to "Jina Embedding & Rerank" ("Jina 嵌入与重排"), so the provider list states which capabilities it serves next to Jina Reader (web fetch) and Jina Search (web search); the provider kind id is unchanged.
- Resolve Console provider kind labels through the shared `localizedText` helper against the active locale, replacing the hardcoded `en`/`en-US` lookups no provider emits, so zh-Hans-CN sessions see the Chinese provider labels.
- Render an empty-text addressed IM message as a summons naming the sender and pointing the Agent at the quoted channel context, instead of a generic actor-event fallback line the model would echo back at the user; attachment-only addressed messages are described by their sender too.
- Carry `provider_thread_id` only for messages inside a real provider thread (Lark root/parent replies, Slack threaded replies, Teams channel posts) and leave it nil for top-level messages across all three IM adapters, so inbound batching debounces and merges same-sender bursts at channel scope instead of giving every top-level message a private batch key.
- Print an ASCII-art Ankole banner with a `devkit · environment setup` tagline when `env-setup.sh` starts, coloring it cyan when stdout is a TTY.
- Show concise file, command-family, terminal, and Skill activity in live CardKit replies, keeping the execution plan expanded while folding secondary processing detail without exposing raw tool parameters.
- Let agents list, inspect, atomically replace, and cancel pending one-shot checkbacks, and require a confirmed schedule effect before claiming a conversational correction changed durable work.
- Preserve direct reply relations across Lark, Slack, and Teams from provider ingress through SignalEntry, reply-target-scoped batching, ActorEvent, and the current model turn; resolve quoted agent/human content without depending on conversation history, treat replies to the current Agent as addressed, surface unresolved targets instead of guessing, and reuse binding-visible parent attachments without re-downloading or leaking them across Agents.
- Add the domain-neutral `deep_research` profile for general research, ACH forecasts, and forecast retrospectives by reusing one default-mode Codex delegation and thread with a lean Skill pack, automatic source-archive before hooks, and passive final-artifact observation; defer equity forecasting and trajectory backtesting.
- Enable native Codex subagents, browser tools, and installed data-source Skills inside Deep Research while removing the custom fan-out/reviewer runner, isolated AIGateway review conversations, source-count floors, quality scores, staged gates, and other model-process constraints.
- Bind immutable evidence archives and deterministic ACH artifacts with the kernel `genericHash`, return incomplete artifact observations to the parent without rewriting files or running a host repair state machine, and reuse the normalized delegation Turn trajectory instead of introducing a Deep Research-specific worker or transcript lifecycle.
- Preserve Responses namespace-tool semantics over Chat-compatible AI Gateway providers so Codex native subagent calls execute instead of surfacing as flattened unsupported functions, and persist each native child thread as passive observation under the root delegation while only the lead thread controls completion and remains the resume/steer anchor.
- Route CDP-backed browser automation through a default long-running Browser Skill with persistent-session, fresh-ref, state-based function-calling guidance, keep search and fetch on ordinary routing, and replace the ten-minute delegation heuristic with a runtime-neutral immediate-response versus follow-up delivery contract.
- Expose `web_fetch` alongside `web_search` as provider-only Console profiles and fail closed on missing capability metadata so non-LLM providers such as Jina never appear in LLM selectors.
- Define `web_fetch` as text extraction only, route binary downloads through shell `aria2c`, and include `aria2` in the Agent Computer image so the documented path is executable.
- Make onboarding executable for new humans and coding agents with a staged contribution guide, safe handoff and troubleshooting boundaries, real Feishu acceptance, and one full-URL setup prompt in each root README.
- Let Brain Console operators select any active human or agent Principal when browsing, auditing, running dreaming, or creating entries, backed by a shared Principal list API instead of an unstable agent-only datalist.
- Let Console operators inspect and safely edit each Agent's MISSION and SOUL documents with per-document optimistic concurrency and next-turn runtime pickup.
- Add per-Agent DESIGN.md visual-identity documents, expose a consumption-only design-md skill with required, optional, and opt-out routing, and project the current VIS at a stable read-only Agent Computer path without adding it to every system prompt.
- Ship a real factory-default DESIGN.md: Ankole's Carbon-derived visual identity with the berry #b31b5d accent, role-based color tokens for both themes, the IBM Plex type scale, flat 0px geometry, and a four-test design-principles creed governing cases tokens do not cover, weighted for the artifacts agents actually produce — a document-first component vocabulary (stats, callouts, quotes, captions, footers) plus dedicated slide, document/PDF, static-HTML-report, and chart rules instead of application chrome — all lint-clean against the upstream DESIGN.md spec; the design-md skill drops its unconfigured-VIS branch since every installation now carries a usable default.
- Install IBM Plex Sans SC, IBM Plex Mono, and Source Han Serif CN into the Agent Computer base image from checksum-pinned upstream releases, and register them as the fontconfig default sans, mono, and serif families so artifacts render the standard faces without webfonts.
- Show the current Ankole version in the Console navigation, using the Changelog version in published control-plane images and the Git description for local dirty checkouts.
- Derive Brain chat-context exclusion from the root turn's exact visible AIGateway Response chain, so session resets can recall prior group reports without re-serving messages already in the model transcript.
- Project bounded recent SignalEntry history into addressed and ambient IM turns at channel scope, preserving human and other-Agent attribution while excluding documents already visible in the target Agent's AIGateway Response chain.
- Make clarification cards one-shot across conversation turns by durably superseding older interactions before the next Agent Turn, and add an authorized free-text CardKit reply form alongside choices.
- Rebuild Brain around evidence → curation → current knowledge → human review: retain exact URL, PDF/file, and pasted bytes without copying chat, byte-verify and fully read sources before citation-fenced Agent writes can complete, derive learning state from ActorEvent and audit truth, share group evidence while preserving per-Agent scope, and give Console operators clear entry, material, curation-guide, review, correction, and recovery workflows.
- Recover Codex subagent execution from transient stream and HTTP 502/503/504 failures by continuing the same durable delegation and Codex thread across worker attempts; recreate only after an explicit unknown-session or no-rollout response, and let parent Agents either make small direct corrections or steer succeeded/failed delegations to resume that same runtime thread instead of creating replacement work.
- Re-admit an authenticated stale Agent Computer when matching lifecycle traffic returns after a heartbeat timeout or broken route, while keeping released assignments and old Turn writes fenced, so a live pod recovers from `connection expired` without requiring a restart.
- Reject task-worker output schemas that Codex strict Structured Outputs cannot accept before creating durable work, recursively requiring closed objects and every declared property while keeping Deep Research report schemas provider-independent.
- Prefix Agent follow-up cards triggered by failed background delegations with the bounded failure context, restoring the user-visible causal link without relying on model-authored prose.
- Add bot-only `lark-cli` capability for signal-bound digital employees, reusing each Agent's tenant credentials in its worker and auto-enabling three consolidated Lark skills behind a global escape hatch.
- Make the Lark capability match the pinned CLI's real bot surface by installing and validating v1.0.69 directly in the Worker image, removing user-only Approval and Contact examples, serializing one-Agent/one-app binding saves, projecting only the app ID and existing manager's cached tenant token once per Turn without a command-level refresh protocol, and keeping custom-base-URL bindings signal-only.
- Let the Agent Library own a generic Skill enablement-provider contract, move Lark binding and CLI compatibility policy into the Lark plugin, and discover validation targets from each Skill's execution profile instead of duplicated Elixir and TypeScript name lists.
- Add the OpenAI-compatible Responses `image_generation` hosted tool through OpenRouter's stable Images API, with vision Files endpoints, capability-gated image profiles, definitive endpoint validation, durable subject-scoped artifacts, SDK-compatible HTTP/SSE/WebSocket lifecycles, bounded resources, and private provider telemetry.
- Harden hosted image generation against malformed partials, ambiguous endpoint descriptors, multi-image persistence failures, and downstream credit starvation; align OpenAI error and event shapes, bound the complete hosted loop, and verify Files, Responses, SSE, and ResponsesWS through the official SDK against the real local gateway.
- Replace raw subagent JSON-RPC event and Deep Research rollout persistence with one normalized, redacted, 256 KiB-bounded `ankole_chatml` row per actual Codex Turn; precisely opt out of and defensively ignore text, reasoning, command, patch, and MCP progress deltas, persist only completed semantic items alongside concrete progress and official usage snapshots, keep silent executions alive through actor heartbeats, make revision replay strictly fenced and idempotent, bridge Default-mode parent questions into the single pending lead `request_user_input` contract, show complete bounded Turns in Console, and give `subagent(status)` a current execution summary plus three lead semantic groups with opaque backward pagination.
- Honor clear user-directed Brain memory changes without a future-value gate, and require proactive writes to add clear value over existing Brain and chat for a likely future task or later user question.
- Gate each saved resident-context item on continued validity, sufficient support, and direct relevance to the current topic before the Agent uses it.
- Add a read-only Conversations Console module that lists and opens AIGateway conversations and their messages, rendering the Response-item thread as a chat-style timeline with cursor pagination, subject and active-state filters, and a no-write operator view backed by a dedicated projection-only query context.
- Introduce date-fns and fold the four inline `Intl.DateTimeFormat` timestamp formatters (Conversations, Delegations, Brain shared/editors) into one locale-aware `formatConsoleDate` shared helper that follows the active i18n language, so zh-CN browsers keep native date rendering instead of silently falling back to English.
- Give the source-learning turn one owning worker module that constructs its complete toolset (snapshot reader plus Brain read tools and a write-gated `memory_update`) by function reference, replacing the text-turn string whitelist, the generic pre-write hook, and the duplicate event derivation in memory tools; a learning turn without the Brain memory RPC seam now fails loudly instead of silently degrading to read-only.
- Put each AIGateway response stream behind one control-plane owner so generated-image completion cannot escape before artifact persistence, public responses retain image bytes while durable messages store only artifact-backed references, and SSE/WebSocket stay framing-only adapters.
- Make root agent guidance lean and standalone for context-free subagents: merge repeated execution rules, preserve its Writing style contract, define authorization, concurrent-work, validation, ownership-discovery, and real-versus-fake boundaries, and clarify Bun without forcing tool migrations.
- Project the current canonical Signal channel ID in each Turn's trusted environment context so provider Skills such as bot-only `lark-cli` can address the active DM directly without guessing or adding a worker-owned routing seam; clarify that bot chat listing cannot discover P2P chats.
- Keep a browser evidence card's semantic source identity separate from the automatic tool receipt, validating the captured URL, archive kind, path, and kernel hash without forcing the researcher to guess a hidden `browser_tool:*` source value.
- Render Lark clarification choices and free-text forms with Card JSON 2.0 callback behaviors and provider-valid element IDs, so real Feishu clients show the controls instead of silently falling back to a plain-text question.
- Keep an unanswered clarification active while asynchronous subagent, checkback, or cron notifications run, and supersede it only when new human input or control intent actually makes the old interaction stale.
- Commit worker-file transfers atomically across distinct Docker mounts by copying the completed scratch file into a target-local temporary path before the final rename when the direct rename reports `EXDEV`, so Brain source learning and other session-file writes work with real shared-volume layouts.
- Complete channel-less internal Agent turns without creating provider outboxes, so Brain source-learning runs persist their completion anchors and lifecycle state without requiring an IM channel.
- Make `report/report.md` the sole authoritative and self-contained Deep Research deliverable; treat JSON, evidence indexes, source archives, and bundles as optional working material that neither completion checks nor user delivery require.
- Expire managed Deep Research workspaces on a per-delegation retention clock: dispatch stamps every `deep_research` delegation with the operator-configured retention days while task workers carry none, and an hourly bounded job deletes each expired terminal delegation's managed `research/<delegation-id>` worker files, marks `workspace_cleaned_at`, and defers unmanaged workspaces and failed deletions to later runs, leaving delegation records, forecast dossiers, and normalized runtime Turn trajectories in place.
- Alias third-party and generated identifiers to canonical initialism casing at their import boundaries (OpenAPISpex, UUID, TCPListener/TCPStream, JSONValue, and generated Console query options) and rename the AIGateway artifacts migration module, so `bun run analyze:naming` passes repo-wide again.
- Align the real-LLM e2e expectations with the shipped delegation contracts: the completion wake `source_event_id` match includes the attempts suffix, and native Codex skill consumption is evidenced by the OfficeCLI workflow instead of a literal `pptx/SKILL.md` read that 0.144 skill injection no longer produces.
- Delete locally-overfit test cases and assertions across the Elixir, TypeScript, and Rust suites — removal-remnant string pins, cross-runtime source greps, Phoenix scaffold error-view tests, an Ecto-delegation UUID roundtrip, fixture-echo provider-settings placement tests, a duplicate 90-iteration stateful-loop case, and exact prose or order pins on tool lists, activity copy, receipts, compaction framing, and Vite dev scaffolding — keeping contract-shaped assertions such as set membership, semantic containment, revision monotonicity, and decoded decision keys in their place.
- Keep one malformed worker RPC from disconnecting the shared RuntimeFabric worker pool by rejecting PostgreSQL-incompatible NUL bytes before JSONB writes, converting handler crashes into scoped RPC errors, releasing native ROUTER resources when their Broker owner dies, and retrying transient bind conflicts until the transport recovers.

## Version 26.07.7 (2026-07-15)

- Query one selected MCP tool schema directly instead of streaming and filtering a server-wide catalog, preventing large BullX schema output from being truncated into invalid JSON or polluting agent trajectories.
- Route BullX “latest N as of a cutoff” requests to latest-daily-bars with its exact parameter shape, keeping them distinct from explicit start-to-end historical ranges.

## Version 26.07.6 (2026-07-15)

- Make `/retry` a true regeneration by retracting the completed visible Response suffix while preserving its audit rows, then continuing from the predecessor.
- End clarification turns immediately after durably recording a nonblank schema-validated question, preserve degraded Brain-search completeness instead of presenting partial emptiness as absence, and move tool-specific operating rules into tool descriptions and schemas.
- Keep one byte-stable system prompt per AIGateway conversation, leave only current-event observations in the trusted user environment block, sort tool definitions deterministically, route shared leading prefixes with a stable prompt cache key, and keep the web-tool catalog fixed while resolving provider availability lazily at execution time.
- Route BullX Financial Data MCP calls directly from the skill intent table and inspect only a selected tool schema when its parameters are genuinely uncertain.
- Point repository guidance at the real root changelog while preserving the pending-change append versus clean-tree next-version rule.
- Bound the model-visible skill catalog with identity-first description compaction and clarify when requested local changes proceed without another approval versus actions that still require confirmation.
- Expose the backend-supported `web_search` profile in Console as provider routing with ProviderDSL options, keeping its backend-only default-model placeholder and context length out of the operator UI.
- Avoid recursive credential lookup when an optional provider API key is absent, so unauthenticated providers such as Yuma web search prepare and execute normally.
- Drain in-flight CardKit preview mutations before terminal outbox handoff so a provider-committed update cannot race a stale checkpoint into a duplicate final reply.
- Fall back to an agent owner's `embedding` ModelProfile when Brain has no global dreaming model owner, and resolve pending knowledge blocks per owner so indexing and queries use the same model route.

## Version 26.07.5 (2026-07-14)

- Align Auth, Setup, and Console around a Carbon-inspired shell, page header, resource table, and dedicated editor hierarchy while retaining the Ankole UI kit and magenta brand.
- Split Brain into Entries, Audit, and Dreaming task surfaces with focused filters, structured audit diffs, and explicit run ownership.
- Clarify editor save boundaries, add typed setting controls and read-only identifiers, and improve responsive, empty, error, keyboard, and sensitive-value states across operator workflows.
- Restore the light Console navigation by making its desktop rail and mobile drawer follow the shared surface tokens, then apply one persisted light/dark theme across Auth, Setup, Console, overlays, and notifications.
## Version 26.07.4 (2026-07-14)

- Prevent `/new` and `/stop` from resurrecting retryable turns when a worker failure supersedes the live delivery just before cancellation.
- Keep stopped CardKit replies with no partial answer metadata-only instead of fabricating an empty body, while preserving the working stream anchor and plain-text fallback.
- Degrade a failed remote Markdown image to its link after one transport attempt so optional image resolution cannot hold a durable final reply through implicit retries.

## Version 26.07.3 (2026-07-14)

- Reframe the root README architecture maps around product-facing entry points, AIGateway's external and agent-facing stateless/stateful surfaces, Brain long-term memory, durable Subagent Delegation, and the semantic-state/artifact split.
- Run migrations and worker-auth bootstrap through release-owned commands instead of encoding application lifecycle and module ownership in Helm.
- Deliver Lark AI replies as streaming CardKit cards with Markdown, compact collapsible progress metadata, interactive clarification, attachments, and ordered long-answer rollover.
- Preserve terminal plans and receipts across preview/outbox races, recover consumed CardKit mutations after process loss, and fall back to new text messages for provider edit or page-binding limits without dropping undelivered results.

## Version 26.07.2 (2026-07-14)

- Prevent short AI replies from racing their transient preview identity before durable final delivery.
- Round runtime-event deadlines up to the next millisecond so an early timer cannot strand due work until the periodic sweep.
- Stop best-effort AI preview updates after a provider rejects an edit while preserving durable terminal delivery.
- Treat `<silent_success/>` as visible output in ordinary turns; only explicitly eligible scheduled turns may complete silently.
- Cover preview-settle timeouts so durable final replies remain untouched and retry successfully after the preview owner exits.
- Expose `memory_update` with a provider-compatible root object schema and reject invalid function-tool contracts before dispatch.
- Mount locally available internal skills into the `bun dev` worker so catalog-visible skills remain executable end to end.
- Collapse SignalsGateway entry mirrors onto one canonical text body, native JSONB search, first-class thread identity, and optional non-duplicated rich content.
- Deliver Feishu/Lark AI replies as one direct CardKit/CardChain surface with streamed Markdown, semantic plan/activity/receipt projections, typed rich results, and authorized clarification buttons.
- Recover the same CardKit chain after worker or control-plane restarts from PostgreSQL checkpoints, preserving per-card identity and mutation sequence/UUID identity while keeping provider reasoning transient and cleanup-leased.
- Keep durable AI replies retryable beyond the generic outbox budget, wake blocked delivery after binding repair, and fall back from deterministic CardKit or edit-limit failures to idempotent, lossless text chunks.
- Show safe todo, memory, and deferred-work progress without raw tool protocol, while preserving genuinely quiet scheduled success.
- Continue oversized Unicode and fenced-code Markdown across ordered CardKit cards without truncating the final answer, and resume an ambiguous tail-card send with the same provider UUID.
- Resolve remote Markdown images into cached Feishu image keys, keep intranet images available by default, and apply the shared `security.ssrf_filter` policy to web fetches, browser navigation, and every image redirect while always blocking cloud metadata.
- Bound remote CardKit image downloads before buffering, escape artifact links safely, preserve explicit false presentation values, and consolidate Lark reply fallback handling.
- Upload image attachments through Feishu's native image API, keep other files on the file API, and show the terminal attachment receipt without duplicating delivery.
- Keep clarification choices real: free-form input stays in the normal composer instead of appearing as a fake “Other” button.
- Localize CardKit lifecycle and panel chrome with Feishu's native per-element `i18n_content` while leaving the agent's answer unchanged.
- Return to the provider list after saving or leaving an AIGateway provider editor.
- Display Select item labels after selection instead of exposing their underlying values across the web UI.
- Show provider kind names without internal IDs and keep OpenRouter attribution and endpoint overrides under advanced settings.
- Default new provider IDs to their provider kind and choose the first available `-2`, `-3`, and later suffix.
- Let ProviderDSL declarations mark advanced settings explicitly instead of hard-coding provider-specific field groups in Console.
- Clarify the optional WorkerEnv note and present secret storage as a compact, accessible setting in the Console editor.
- Keep encrypted WorkerEnv and AppConfigure values visibly masked until explicitly revealed, with in-field reveal controls and no-op secret saves.
- Render model-profile provider options from ProviderDSL fields and let operators select a known model or enter a custom model ID.
- Standardize reasoning effort as a DSL-backed select, remove provider-native escape fields, map it to each upstream wire shape, and collapse advanced request options in Console.
- Store and inject only self-contained resident rule text plus truncation state, without storage or audit metadata, and retrieve memory only when saved context lacks required detail, freshness, or provenance.
- Keep `agent_environment_info` compact by omitting duplicate room and DM speaker metadata, and append only non-user group roles to the speaker name.
- Move Brain dreaming JSON envelopes out of model instructions and into AIGateway structured-output schemas while retaining server-side domain validation.
- Replace raw AIGateway conversation rows in Brain Dreaming with completed Actor task outcomes, keep tool arguments and outputs out of evidence, and retain store routing, versions, hashes, and concurrency fences server-side.
- Make `/retry` replay requests that failed before AIGateway conversation creation, preserve their original payload and attachments, and return visible feedback when no retry source exists.
- Upload CardKit Markdown images through Feishu's required image multipart field and degrade failed image uploads to links so terminal answers still deliver.
- Allow renderer-safe `reply_presentation` progress through RuntimeFabric so CardKit can show todo, tool, memory, scheduling, and transient thinking state.
- Persist structured `clarify` tool results and give every choice a unique CardKit name so clarification-only turns close their stream and deliver actionable buttons.
- Normalize Feishu's current CardKit callback envelope so operator identity, message context, choice locking, and follow-up turns survive real button clicks.
- Close CardKit text streaming in its own sequenced mutation before applying terminal content, preventing short and scheduled replies from remaining in a provider-visible working state.
- Keep the active CardChain tail's source bytes, offsets, and digest current as streamed text grows so a restart can reconstruct every long reply exactly.
- Fence each worker process with a fresh incarnation id so restarting the same stable worker immediately releases its predecessor's delivery ownership without waiting for stale-heartbeat expiry.
- Repair a replayed AIGateway chain after a control-plane crash by completing orphaned function calls with an explicit interrupted-tool result before continuing the turn.
- Finalize active CardKit previews durably when `/stop` or `/new` cancels a turn, preserving acknowledged partial answers and rich results while suppressing late worker output.
- Treat deletion of a conservatively checkpointed but provider-absent CardKit element as idempotent cleanup, isolating it from terminal answer, status, and action mutations.
- Add an end-to-end local test environment guide covering devkit setup, activation, Feishu/Lark onboarding, Console routing, and Codex-assisted verification.

## Version 26.07.1 (2027-07-13)

- First preview release of Ankole.
