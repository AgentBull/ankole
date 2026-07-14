# Changelog

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
