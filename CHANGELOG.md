# Changelog

## Version 0.71.1 (2026-08-14)

- Keep the Background Agent Job board within the desktop viewport with independently scrolling columns. Its five health cards now keep their space while loading, show request failures, and use one wide-screen row. Assistive technology can identify each Job column and the health loading state.

## Version 0.71.0 (2026-08-14)

- Re-enable a disabled model provider without rebuilding its credential pool. Re-enabling validates the stored configuration and retries credentials that failed before disablement, while enabling an active provider preserves current health. Credential replacement and disabled-provider re-enable use new internal health revisions, so a late response from an earlier secret cannot mark the current credential dead or rate-limited. Metadata changes and automatic OAuth token refresh preserve current health. Encrypted settings are limited to credential scope, and the endpoint uses the existing provider update permission.
- Make Console readiness continuously check five deployment-instance requirements: a provider, an active Agent, all required model profiles, a ready Worker, and a usable Signal Routing Rule owned by an active Agent. Header and home polling continue after setup, so removing or disabling a requirement restores its setup step.
- Make Console state match visible resources. Agent and Brain owner changes remove prior-scope rows from schedule, Signal Routing Rule, webhook, conversation, Automation Job, Background Agent Job, and Brain lists. Background Agent Job details use compact, right-aligned action footers, and their dialogs close with their Agent filter. Automation Job deep links accept every positive integer ID, retain owning-Agent authorization, and show explicit errors for invalid filters, invalid IDs, and missing details. Encrypted settings keep scalar input as a string and parse only valid JSON objects or arrays as structured data. Dirty drafts require confirmation; pending writes cannot be dismissed as discarded; Skill Experience drafts reset per Agent and retain their conflict hash; schedule limits survive edits; terminal schedules are read-only; and IME input cannot submit forms. Provider-hosted capability switches can be turned off again. Setup validates activation codes in the selected language and shows submission progress. Searches, settings, and operational states now use localized visible labels and explicit errors.
- Keep startup Signal connection reconciliation in tests, but disable its periodic timer so supervised plugin work does not race SQL Sandbox tests.

## Version 0.70.0 (2026-08-13)

- Continue a Background Job even after its Worker is replaced. When the Worker-local Codex thread is gone, a respawned or retried Job now replays its stored turn history into a fresh thread and continues where it left off. When nothing is stored, it continues in the same Workspace, seeded with the source Job's task and final report, and the Job metadata states which recovery ran. Previously a Worker replacement made every earlier Job impossible to continue, and a Worker whose thread index survived without its thread file failed the Job outright.
- The Worker now reports each Job Turn's content once, as sanitized semantic items. The control plane stores that stream for thread replay and derives the existing trajectory views from it, so the Console, message results, and attempt summaries keep their current shape.
- Let operators enable `ai_gateway.compaction.prefer_upstream` to make Main Agents and Background Jobs prefer a Responses Provider's native compaction. The switch is off by default. New ChatGPT Subscription Jobs use Codex v2 through AIGateway's normal Responses path; all other Jobs and every Main Agent use the standalone compact operation, fall back to Ankole's local summary when readable, and remember a 404 or 405 for one hour per Provider revision and model. Main Agent history binds opaque output to its Provider and model and rebuilds a local checkpoint before a switch. A later standalone fallback from opaque Provider state returns `opaque_compaction_fallback_unavailable`. When a real compact request fails and the local summary runs instead, the control-plane log records the Provider, model, and cause, so an operator can tell a working switch from one that degrades on every compaction.
- Keep Codex thread resume on its own 120-second request budget and preserve the existing app-server liveness check: a timed-out resume fails only its Background Job when the shared process still answers, while a process that cannot answer either request is replaced.
- Remove the separate `hosted_web_search` switch from OpenAI-compatible Providers: an endpoint configured for the Responses wire already states that capability, and whether to use it is the Agent's own web-search switch. Operator action: none, the stored option is removed on upgrade.
- Rework the Deep Research instructions around findings from a production trace audit. A spawned support thread now executes only its own brief instead of adopting the whole research workflow after an interruption, collectors report facts without pre-empting the judgment, and the verifier must report findings in both directions — a conclusion made softer than the evidence warrants counts the same as one made stronger. Reports state each limitation once and stop repeating already-green checks; build and writing tasks skip the research scaffolding entirely. The ACH playbook now rejects undecidable questions up front, gives every hypothesis the same burden of proof, and refuses matrices built only for compliance.
- Tell operators when the Job queue is held by the per-Agent concurrency cap rather than by Worker capacity. The Background Agent Jobs health panel now shows how many Agents sit at that cap and how many Jobs wait behind it, and states that the cap counts across all Workers, so adding a Worker will not start them. Raise `agent_computer.background_agent_job.max_running_per_agent` for that case, after confirming Provider quota.
- Stop dropping every message on a channel that changes kind. A channel first recorded as a group and later seen as a direct message kept its stored group, which storage rejects, so each later message on it failed silently and the sender never got a reply. The group is now cleared when the channel is no longer a group.
- Keep saved custom model profiles editable in the Console. Their description, Provider, model, context length, and Provider options now stay in sync while an operator types or selects values instead of freezing after the first change.
- Let an operator enable `signals_gateway.show_dead_letter_error_details` to append the current Actor turn error to Signal-channel dead-letter notices. The setting is off by default, and enabled notices limit and redact the details before delivery.
- Let image and scanned-document OCR run inside the Agent sandbox. The sandbox now exposes the Worker's `/sys` tree as read-only, so OpenVINO can inspect CPU topology instead of crashing during startup.
- Retry a dropped upstream provider connection inside the same model call. An AIGateway upstream WebSocket connect, send, or read failure — for example a connection reset mid-stream — was classified as an unknown, non-retryable error, so the whole Turn failed and waited for control-plane redelivery. The Worker now classifies these as retryable transport errors and retries the call from the stored anchor.
- Stop counting an AIGateway credential-pool cooldown, such as a 429 storm, against a Background Job's five execution failures. The Job now waits for the pool's declared recovery time with its budget intact, so a storm no longer fails a whole batch of parallel Jobs as `attempts_exhausted` task failures; a storm that outlasts all twenty-five claims fails with the existing infrastructure verdict instead.
- Let operators send optional OpenTelemetry traces through OTLP/HTTP. Export is off by default and is configured in one AppConfigure form with encrypted authentication headers. Each dispatched Agent Turn becomes one trace that names the Agent Principal and its conversation; Main Agent and Codex tool spans and each AIGateway model generation attach below it with bounded, redacted input and output, token usage with cache and reasoning buckets, and timing. The `langfuse`, `langsmith`, and generic `opentelemetry` Providers add vendor semantics, so a receiver such as Langfuse groups cost and quality per Agent, per session, and per release. The website documents Langfuse and LangSmith setup plus common OTLP alternatives.
- Count Claude prompt-cache reads and writes in AIGateway response usage the way OpenAI counts them: `usage.input_tokens` now includes both cache portions and `input_tokens_details` itemizes them, and Gemini cached prompt tokens now appear in the same detail field. Context accounting, traces, and cost views see real cache traffic instead of zero.
- Upgrade the bundled OfficeCLI to 1.0.144, which fixes XLSX `SUBTOTAL` handling for filtered and hidden rows, empty-cell comparisons, and date/time text arithmetic. The Office Agent Plugin now requires that matching runtime, sends top-level commands to their correct help entry, makes CSV and TSV imports durable through a verified non-resident batch, and aligns DOCX page-break and TOC guidance and XLSX print-layout guidance with the 1.0.144 source.
- Fix first-use Lark approval setup for each human profile. App-registration and user-login device codes now remain in locked profile state instead of crossing model Turns, so browser setup can finish without a signed code being altered. Registration errors retain the provider code and HTTP status, and the Worker bundles `lark-cli` 1.0.86.
- Let an Agent address the current Lark sender without asking them to copy an ID. Inbound Turns preserve a Contact-synchronized display name when the message webhook omits it, render group speakers as `name(uid)`, and expose the current chat ID. The Lark Skill uses a human `uid` as the usual Lark `user_id`, so the Agent can resolve that user through the bot Contact API and start a direct message.
- Shorten the Agent system prompt and tell a new Agent how to write. Duplicate sentences, self-evident tool instructions, and self-check directions are gone from the system prompt, which lowers the fixed token cost of every Agent turn; the approval boundaries, security limits, and schedule rules stay the same. The default SOUL template now asks for the voice of the colleague who did the work and is briefing the person whose call it is: lead with the judgment, keep replies short by default, calibrate what to explain to the reader at hand, commit to a position instead of surveying options, and write in everyday words instead of invented jargon. An Agent created before this release keeps its stored SOUL until an operator edits that document.
- Reject a Worker Turn checkpoint that reuses a revision but changes header fields such as status, progress, usage, or error. The header comparison always passed before, so such a resend was silently accepted and the drift was ignored.
- No product behavior changes from added delivery edge-case test coverage, corrected end-to-end expectations, test-fixture cleanup, an internal cleanup pass that gives the Responses-wire check, trace attribute encoding, and other duplicated internal logic a single owner each, and a compaction-planner cleanup that replaces its long internal argument lists with one context bundle per path.

## Version 0.69.0 (2026-08-13)

- Keep a Claude model's extended thinking across a tool-calling conversation. AIGateway carries the signed thinking blocks between rounds and rebuilds each assistant turn from the stored history, so Claude tool calls now replay correctly even with thinking off. Reasoning from one model is never replayed to another, and a conversation whose stored reasoning is missing or unreadable continues without it instead of failing.
- Deliver every configured target of a recurring task, and stop losing the ones that cannot be reached. A target whose channel or binding was deleted no longer leaves an undeliverable row waiting forever: it is recorded as unsupported, appears in the stopped-delivery view, and the remaining targets still deliver.
- Keep a Background Job on the Worker that holds its Codex thread. A retry, and a Job continued from steering messages, both stay put instead of moving to the emptiest Worker and rebuilding or failing to resume that thread. A continuation that truly lost its Worker now reports that cause.
- Stop rewriting what the pinned Codex runtime declares: model-visible tool descriptions keep their official `exec` declarations, and native OpenAI Responses keeps the encrypted tool-parameter marker it owns instead of an AIGateway emulation. A malformed marker is still rejected on every route.
- Give each Agent one switch per capability for web search and image generation: leave it to the Agent's language-model Provider, or use the Agent's own capability Provider. Turning it on disables that capability's model profile, because the Provider then runs the work inside its own turn and owns its results. A model that cannot run the capability means the Agent has none, rather than silently switching executor mid-conversation. Both switches default on for new Agents; an Agent that already configured a search or image Provider keeps it. This replaces the previous behavior where a provider-hosted search was declared alongside a competing local `web_search` tool, which let the model pick either one.
- Repair the operator endpoint that commits an externally verified Job completion: it read the result summary from the wrong place and rejected every valid request. Agents can also now state how many targets a recurring schedule delivers to instead of guessing.
- Maintenance with no user-visible behavior: declared Provider setting types are validated on write, daily Codex log maintenance no longer stops at the first unreachable Worker, the Rust lint gate passes again, the end-to-end steering check now looks for the final reply where a steer actually owns it, and the repository-only `audit-ankole-trajectories` Skill and the unit tests that only inventoried catalogs, restated source or locale copy, or snapshotted CSS class names are removed.

## Version 0.68.4 (2026-08-13)

- No product behavior changes. A `bun test` started outside the Worker image now stops with the correct Agent Computer test commands instead of reporting host environment failures, and the contributor guidelines state that a package's declared test or build script is the only correct entrypoint.

## Version 0.68.3 (2026-08-13)

- Let an Agent Plugin workspace template hold a Background Job to single-Agent execution: `features.multi_agent_v2.enabled` in the template `.codex/config.toml` now keeps the value the operator wrote, and Ankole supplies its default only when the template leaves the switch unset.

## Version 0.68.2 (2026-08-12)

- Apply the valid PR review-bot findings: restored Brain drafts rebaseline only from a fetched response, overlapping model-profile saves each keep their pending state, a refetch that restates current values no longer fakes "unsaved changes", the checkbacks list documents 401/403, schedule toolbars gain a real accessible label, the conversations search placeholder names every input, an invalid worker file timestamp renders as absent instead of crashing the table, and an abandoned invalid fitness horizon snaps back to the applied value.

## Version 0.68.1 (2026-08-12)

- Correct the automation-blueprints and Console API guides in all four locales to the real schedule API: `POST /api/v1/agents/:agent_uid/cron-schedules` with `owner_session_id`, `idempotency_key`, and `delivery` in the request body, the `{ "kind": "cron", "expression": ... }` schedule shape, and the checkback surface (`GET /api/v1/checkbacks?agent=`, `DELETE /api/v1/agents/:agent_uid/checkbacks/:scheduled_event_id`).

## Version 0.68.0 (2026-08-12)

- Give the Console lists for Schedules, Signal Routing, Automation Jobs, Webhooks, and Background Agent Jobs one "All Agents" default scope with a one-row search-and-filter toolbar, served by installation-wide `GET` endpoints with an optional `agent` query filter in place of the per-agent list routes. Operator action: these list endpoints now check the installation-wide read permission (`schedules`, `signal_gateway_bindings`, `webhooks`, `automation_jobs`); give custom roles that hold only per-agent grants the matching installation-wide read grant, and update API clients to the new list paths. Checkback lists now cap at 100 rows by default (500 maximum).
- Let the Console conversations list search by name: the `q` filter matches an exact subject UID (any letter case), a session-key fragment, or a fragment of a group channel or DM peer name, with literal `%` and `_` handling and a debounced search box.
- Fix the Console defects found in this release's full review: a rejected token refresh recovers through the browser session and survives network blips; legacy single-target schedules, deep-linked Automation Jobs, Brain audit restores, and settings-group restores no longer dead-end or silently revert; secret, encrypted, and model-profile editors validate and display stored values honestly; destructive actions confirm first and name their target; switching the Agent filter keeps an open job detail; ja-JP and ko-KR timestamps and English plural forms render correctly.
- Rebuild the Schedules area and the shared Console chrome: Cron and Checkbacks are routed tabs of the shared list frame, editors use the shared editor frame, `every` schedules require their anchor and drop hidden timezones, ChatGPT credential labels and priorities become editable, and the review's duplication findings collapse into shared owners.
- Make the ChatGPT device-login test clock-independent so unpinned credential resolution stays on the no-refresh path regardless of the run date.

## Version 0.67.2 (2026-08-13)

- Remove the obsolete per-Job Agent Plugin selection column from upgraded databases. Pause legacy direct-Agent cron schedules without a complete task, cancel their pending fires, and block resume or manual fire until repair; schedule coverage now uses explicit clocks and payload or delivery updates preserve run history.
- Move Codex runtime state to Worker-local shards, bind each shard into its Job sandbox, and retire only an unlocked, real legacy config directory. Pin local Worker builds to Codex 0.147, keep app-server timeouts retryable, redact bounded startup diagnostics, and roll back a successful terminal Job commit if its steer successor cannot be stored.
- Keep provider-hosted web search on standard Responses without a competing local tool, and persist and publish through the Console API whether each search was provider-hosted or local. Preserve frozen provider options across model and tool-result rounds, keep generic caller metadata local, retain configured WebSockets through hosted image fallback, and restore omitted terminal output from completed stream items.
- Keep OIDC login buttons usable after browser back navigation, and stop stale Feishu CardKit recovery from replacing a durable terminal presentation or retrying a provider binding-limit fallback forever.

## Version 0.67.1 (2026-08-13)

- No product behavior changes. Add the `tools/fake-feishu` developer tool: a standalone fake Feishu platform plus CLI for local end-to-end work without the Feishu web client, simulating CardKit streaming with the real conflict codes, the chat directory, images, and reaction/member/card-action events; the e2e suites share the same simulation core with unchanged behavior.
- Add the dev-only `ANKOLE_LARK_BASE_URL_OVERRIDE` environment variable that points a `:dev` control plane's Lark clients at such a local platform; production endpoint rules stay unchanged.
- Clarify the changelog rules in `AGENTS.md`: entries are written for end users, and `MINOR` is only for main-product capabilities that end users experience — everything else is `PATCH`.

## Version 0.67.0 (2026-08-12)

- Make BackgroundAgentJob retries honest and bounded: a retryable attempt failure returns the Job to `queued` and frees its Agent slot and Worker assignment, the new `execution_failures` budget (5) counts only real execution failures while total claims cap at 25, and infrastructure interruptions retry within minutes while provider-class failures keep the hours-spanning ladder. Operators see `execution_failures` beside `attempts`, and the per-Agent running cap becomes the `agent_computer.background_agent_job.max_running_per_agent` setting (default 3; confirm provider quota before raising it).
- Never block a Job's terminal commit on unconsumed steering: a succeeded commit converts open steers into one successor Job and names it in the wakeup, failed and stopped commits answer steers with the terminal notice, and the new `request_complete` operator action commits an externally verified completion with a result summary. A dead-lettered lifecycle wakeup now delivers the real outcome — title, status, result or error, artifacts, successor — without a model turn, and a Codex app-server internal death stays retryable instead of dead-lettering the notification.
- Move Codex SQLite state to Worker-local per-Agent shards (`ANKOLE_CODEX_STATE_ROOT`, default `/var/lib/ankole/codex`); SQLite WAL cannot run on the shared network filesystem, which was the root cause of production `thread/resume` stalls. Place Jobs per Job instead of per Agent so one Agent's Jobs spread across Workers by free capacity; a lost Worker shard falls into the existing runtime-chain recreation, and daily `logs_2` maintenance reaches every ready Worker.
- Keep one slow app-server request from killing every Job of the Agent: a timed-out request health-probes the process and fails alone when the process still answers; only an unresponsive process, a failed `initialize`, or a `turn/start` timeout closes the transport.
- Add the Console Job reliability panel: oldest queued wait, execution failures against claims, successor seeding, and dead-letter notices over 24 hours through `/background-agent-jobs/health`.
- Run each cron fire in the schedule's own derived execution session (`cron:<schedule_id>`) so long autonomous runs no longer block addressed messages in the owner conversation; a direct-Agent schedule stores its complete standing instruction in `payload.task`, and payload or delivery edits restart the schedule conversation from current facts. Console schedule forms pick the owner conversation from real sessions and edit the Task directly; the migration renames `session_id` to `owner_session_id` and moves pending fires to derived sessions.
- Store messages sent to a queued BackgroundAgentJob and replay them in strict order at admission instead of forcing a stop-and-recreate; admin OIDC sign-in redirects in one navigation; OpenAI-compatible and OpenAI providers declare endpoint kind and upstream WebSocket transport as Console selects with an editable `serviceTier`; a streamed OpenAI-compatible output item keeps its identity across a lossy terminal snapshot so Codex never executes one tool call twice; `audit-ankole-trajectories` loads only when a user invokes it by name.

## Version 0.66.0 (2026-08-12)

- Let an OpenAI-compatible Responses connection declare provider-hosted `web_search`, and project that capability end to end: Main Turns declare the hosted tool to the provider, and Background Agent Jobs enable Codex live web search from the same frozen declaration.
- Reject `hosted_web_search` on a connection whose `endpoint_kind` is not `responses`.

## Version 0.65.0 (2026-08-12)

- Run each recurring Agent or BackgroundAgentJob task once and deliver the same final reply and attachments through one independently retryable outbox row for each configured Signal target.
- Normalize existing single-target schedules and live event snapshots without rewriting terminal history or replaying old outbox effects; downgrade stops before it can lose a multi-target route.
- Let operators manage canonical `delivery.targets` in Console while target edits preserve worker-owned `quiet_success` and Agent tools preserve operator targets; schedule reads use the canonical list and legacy scalar writes still normalize to one target.
- Cover one-turn multi-target delivery and isolated retry with a real Worker and Lark adapter E2E case.

## Version 0.64.2 (2026-08-12)

- Update the public Console guides for reversible Signal Routing, safe credential replacement, Provider-dependent model options, and the editable boundaries of Principals, permission groups, and grants.
- Preserve whether a Background Agent Job tool ran through a Provider-hosted tool or an Ankole dynamic tool, even when both tools use the same display name.
- Let an authorized parent Agent read a succeeded Background Agent Job's exact persisted response through bounded offset reads when the completion notification is truncated.
- Stream Mix diagnostics while devkit renders the Worker bootstrap contract, so a held `_build` lock shows its holder immediately, and stop the wait after 10 minutes instead of hanging without output.

## Version 0.64.1 (2026-08-12)

- Compress every historical release into concise outcomes for release readers. Preserve all version headings, dates, ordering, and material user, operator, compatibility, migration, security, and architectural facts.
- Require future versions to use 1–4 outcome and operator-action bullets in normal cases. Do not use file or test inventories or implementation narratives. Continue to cover every material retained change.

## Version 0.64.0 (2026-08-12)

- Complete Turns for unreachable channels without endless model retries, and prevent removed or listen-only adapters from blocking Worker takeover.
- Enforce a hard outbox attempt limit, require explicit operator requeue, and add Console controls for stopped deliveries.
- Classify WeCom delivery failures and mark replies that may have been duplicated.

## Version 0.63.0 (2026-08-11)

- Move AgentBull Cloud web search to `/web-search/v1/search`; operators must provide an API key, which AIGateway sends with Bearer authentication.

## Version 0.62.2 (2026-08-09)

- Flatten namespaced function and custom-tool history even when the current request declares no tools.

## Version 0.62.1 (2026-08-09)

- Flatten namespaced custom-tool replay for strict OpenAI-compatible providers while preserving public Codex tool names.

## Version 0.62.0 (2026-08-09)

- Make `/steer` queue input for the next model boundary instead of aborting the active provider call.
- Add complete Japanese and Korean localization for the Website, Console, and server, and normalize Korean documentation style.
- Route the trajectory-audit Skill only for its intended audit work.

## Version 0.61.6 (2026-08-09)

- Proofread the Chinese documentation and Chinese READMEs without changing product behavior.

## Version 0.61.5 (2026-08-08)

- Upgrade dependencies, show Worker-image pull progress, and fail WebSocket connection attempts after one minute.
- Add immediate steer preemption; Version 0.62.0 later replaced this behavior with queued boundary admission.

## Version 0.61.4 (2026-08-07)

- Count credential-pool exhaustion against the bounded five-attempt Background Agent Job budget.

## Version 0.61.3 (2026-08-07)

- Retry HTTP 402 failures within the Background Agent Job budget, but keep HTTP 403 terminal.
- Respawn terminal Jobs from the same Codex thread and workspace.
- Return bounded provider error details through public AIGateway errors without exposing response bodies or log data.

## Version 0.61.2 (2026-08-07)

- Upgrade dependencies and Codex to 0.147.
- Hide the readiness control after setup is complete.

## Version 0.61.1 (2026-08-07)

- Preserve native OpenAI `encrypted_content` while rejecting foreign or corrupt adapter state.
- Limit web-search queries to 500 trimmed characters.

## Version 0.61.0 (2026-08-07)

- Recover stalled Background Agent Jobs and Brain work with clearer operator alerts and bounded recurring-reply escalation.
- Correct speaker, timezone, attachment, and deliverable handling across conversation and research workflows.
- Repair Codex tool, prewarm, MultiAgent, compaction, model-routing, and vision behavior; add Unicode Agent UIDs and sticky OpenRouter routing.
- Overhaul the PPTX Skill, make Deep Research confirmation safer, and move durable conduct rules into pinned memory.

## Version 0.60.0 (2026-08-06)

- Improve Console layout, accessibility, forms, and operator feedback.
- Redact secrets safely and preserve blank secret fields when editing Signal Routing and Identity Provider settings.
- Add a secure Signal Routing detail API and a soft-disable lifecycle, and validate provider option mappings.

## Version 0.59.0 (2026-08-06)

- Improve Agent and Job reliability with finite schedules, empty-reply reminders, truncated-call recovery, durable steering, richer collaboration history, and clearer stall and failure handling.
- Sanitize Skill catalogs and tool results, and cap `web_fetch` at 40,000 characters with workspace overflow. Add direct AIGateway web providers, refresh Lark credentials, and add read-only Mail through `lark-cli` 1.0.84.
- Strengthen provider and runtime correctness with sealed RuntimeFabric headers and typed stream events. Repair Brain curation, model-switch, vision, and cache behavior, and limit Codex tool output to 10,000 tokens.
- Add the disabled-by-default `context-dev` Skill, which requires `CONTEXT_DEV_API_KEY`, plus repository evaluation, BP fidelity, and trajectory-audit tooling.

## Version 0.58.0 (2026-08-05)

- Add recoverable Slack Block Kit replies, threads, attachments, and direct mentions; deterministic binding failures now wait for operator repair.
- Honor standard HTTP and WebSocket proxy variables, including `NO_PROXY`.
- Overhaul Console setup, readiness, forms, and accessibility; Agent display name and role are required when saving, while legacy unnamed Agents remain usable until edited.

## Version 0.57.2 (2026-08-04)

- Simplify the Background Agent Job board and distinguish synchronous from asynchronous Job messages.
- Add acknowledged Turn completion, no-op, and abort operations with rolling-upgrade compatibility; deployment must stop old Workers before applying the control-plane phase.
- Preserve `/steer` continuation presentation and durable compaction checkpoints across retries and restarts.

## Version 0.57.1 (2026-08-04)

- Restore Bearer authentication for Skill-backed HTTP MCP while keeping raw tokens only in WorkerEnv.

## Version 0.57.0 (2026-08-03)

- Scope Schedules, Automation Jobs, and Webhooks to an Agent across all its sessions, and label automatic Feishu cron replies.
- Run an Agent's active Background Jobs through one shared Codex app-server. Add official Plugin installation, per-Job Skill projection, physical Home locking, bounded recovery, and live Skill-disable or content-change hints.
- Persist a frozen Job runtime and model projection, add Agent-owned custom model profiles and `/llm`, and return HTTP 422 for unconfigured profiles.
- Add aggregated global financial data through Twelve Data, Massive US options, and Polymarket. Route Hong Kong daily bars through BullX, upgrade mcporter to 0.13.0, and prevent silent MCP result truncation.

## Version 0.56.3 (2026-08-03)

- Run Codex diagnostic cleanup only at the daily session-reset boundary.

## Version 0.56.2 (2026-08-03)

- Serialize Codex Home initialization and clean only disposable diagnostic databases when the Home is idle.
- Restore `tini` as the Kubernetes Worker supervisor and replace `RUNTIME_FABRIC_URL` with separate RuntimeFabric endpoint and authentication-key settings.
- Use immutable or content-addressed Worker images instead of the fixed local image.
- Require repository repairs to update all affected ownership boundaries and remove superseded paths.

## Version 0.56.1 (2026-08-03)

- Keep settled Tool Search history replayable after its declaration is removed, without making the removed tool callable again.

## Version 0.56.0 (2026-08-02)

- Improve Deep Research planning, add Academic Verification, and add a source-faithful playbook-porting Skill.
- Fix Brain retrieval for entries with many matching blocks and return clear canonical-name and alias-ambiguity results.
- Remove Flint Chart and general Direct MCP while preserving invocation-scoped Skill-backed MCP and compatible historical replay.
- Refine `clarify` and add explicit-request-only `brainstorming` and confirmation-first `proposal-review` Skills.

## Version 0.55.0 (2026-08-02)

- Keep Lark CardKit replies within table and page limits, block permanent recovery failures, and let operators requeue them after binding repair.
- Prevent duplicate replies during deployment with acknowledged terminal completion and safe Worker draining.
- Move to AgentBull active-support packages and Bun canary, with immutable runtime ownership and updated architecture documentation.
- Add local PDF triage, text extraction, and CPU OCR, and refresh bilingual channel and Automation Job guidance.

## Version 0.54.0 (2026-08-02)

- Add durable per-channel ambient judgments, reply attribution, and member-managed standing orders.
- Give Sessions and inbound attachments stable numeric IDs; legacy Session directories migrate on first access and fail on conflicting old and new state.
- Make MCP-backed capabilities Skill-first across main turns, Background Jobs, and Automation Jobs, with only a narrow release-defined Direct MCP exception.
- Disable Codex creator and installer Skills, improve localized conversation context, and strengthen RuntimeFabric, credential-retry, and file-I/O ownership.

## Version 0.53.1 (2026-08-01)

- Keep complete-response ChatGPT Subscription calls on the required upstream SSE protocol and omit its unsupported `truncation` field.
- Recover local Tool Search and program continuations when a provider omits the terminal `output` array.

## Version 0.53.0 (2026-08-01)

- Unify AIGateway Tool Search and programmatic tool calling under one public, multi-round Response lifecycle with stable replay and cancellation.
- Enforce frozen tool contracts, caller permissions, output schemas, `max_tool_calls`, and bounded program resources before execution.
- Preserve OpenRouter reasoning state, provider-native OpenAI tool behavior, ChatGPT Codex compatibility, and native-first image generation.
- Align Agent Computer execution and stateful replay with the Responses contract, and return invalid declarations as OpenAI-compatible HTTP 400 errors.

## Version 0.52.2 (2026-08-01)

- Omit `max_output_tokens` from ChatGPT Subscription requests so long-conversation compaction can run.
- Document the canonical WeCom WebSocket Upgrade header requirement fixed in Version 0.52.1.

## Version 0.52.1 (2026-07-31)

- Preserve conventional RFC 6455 header casing so WeCom AI-bot WebSocket handshakes succeed.

## Version 0.52.0 (2026-07-31)

- Restore mcporter 0.12.3 to the Agent Computer image; Automation scripts can use `~/.mcporter/mcporter.json` through Bun Shell.

## Version 0.51.0 (2026-07-31)

- Validate Identity Provider settings in the first-run form before submission, with localized and accessible field errors.
- Simplify Feishu setup, keep setup drafts across navigation and restarts, and preserve plugin-selection behavior until setup completes.
- Standardize setup copy and boolean controls across all supported Identity Providers without changing stored keys or defaults.
- Keep WeCom handlers available during unfinished setup and reduce AIGateway native error size without changing its serialized contract.

## Version 0.50.2 (2026-07-31)

- Compact large program calls as complete call-output pairs and reject checkpoints that would still exceed the provider budget.

## Version 0.50.1 (2026-07-31)

- Prevent Programmatic Tool Calling from aborting the control plane when V8 schedules delayed work under heap pressure.

## Version 0.50.0 (2026-07-31)

- Add WeCom chat and identity support with long-lived bot connections, streaming replies, media handling, directory sync, and documented platform limits.
- Fix blank DingTalk AI cards, preserve their lifecycle state, and add operator setup and troubleshooting guidance.
- Retry transient AIGateway transport and 502–504 failures once before provider output without disabling healthy credentials; keep 401 and 429 ownership distinct.
- Fix ChatGPT Subscription compaction for both automatic and manual summarization.

## Version 0.49.1 (2026-07-31)

- Preserve the complete AIGateway WebSocket connection state after upgrade.

## Version 0.49.0 (2026-07-30)

- Add durable webhook delegations with redacted raw-body admission and callback URLs under `/webhooks/v1/event-callbacks/*`.
- Add Agent-owned Automation Jobs for checkbacks, cron events, and webhook deliveries.
- Isolate main-Agent MCP catalog failures by server so one failure does not remove other catalogs.
- Clarify that one pending changelog version covers all retained work in one commit.

## Version 0.48.2 (2026-07-29)

- Fix release conflict detection in the `runtime-images` workflow.

## Version 0.48.1 (2026-07-30)

- Position Ankole as the open-source AI Workforce OS across localized READMEs and the Website.
- Publish a versioned RuntimeFabric image pair and GitHub Release only after both immutable images pass verification.
- Upgrade control-plane, kernel, and Worker dependencies while preserving CEL list and map functions.
- Align main-Agent file editing with Codex 0.146.

## Version 0.48.0 (2026-07-29)

- Adopt Semantic Versioning from the fixed `0.42.0` baseline.
- Add official Tool Search, deferred loading, and Programmatic Tool Calling across AIGateway, main turns, and Codex 0.146 Background Jobs.
- Replace the separate ChatGPT Subscription runtime with AIGateway v2 credential pools, and reject stateful providers that cannot replay stored history.
- Add pinned database and cloud CLIs to Agent Computer images, move font builds to `AgentBull/ankole-fonts`, localize credential strategies, and enforce Feishu's five-table card limit.

## Version 0.47.0 (2026-07-28)

- Keep Background Agent Jobs alive through upstream outages and resolve their model profiles when each Job is created.
- Preserve OpenRouter prompt caching and decode opaque tool state by its own version.
- Improve Brain Stage A output and show accepted clarification answers in frozen Feishu cards.
- Limit Codex Job threads to 100,000 tokens and reject truncated compaction summaries.

## Version 0.46.1 (2026-07-28)

- Serialize shared Codex Home setup for overlapping Background Agent Jobs owned by one Agent.

## Version 0.46.0 (2026-07-27)

- Complete Worker heartbeat recovery and keep the Worker registry non-durable across database restart.
- Give Deep Research durable state, delivery audit, first-party repository access, and a complete bilingual guide.
- Repair recurring Schedule state, idempotency, editing, replacement, and restart recovery; remove unused `stagger_ms`, `failure_policy`, and cron-level `failed`.
- Require callers to supply stable idempotency keys for manual cron runs, while automatic runs keep unique event identities.

## Version 0.45.1 (2026-07-26)

- Rebuild Quick start as the single path from deployment to an IM reply. Define one private enterprise instance as the product boundary, and remove or redirect duplicate setup and adapter pages.
- Reorganize Architecture, Agent Library, memory, schedules, web, files, images, and visual-design guidance around the real operator task and owner.
- Make AppConfigure the owner of runtime settings, replace the WorkerEnv essay with Console-led environment guidance, and document identity, permissions, and Background Job behavior in user terms.
- Improve troubleshooting, responsive navigation, and table-of-contents tracking. Docker Compose now supports Docker on Linux, macOS, and Windows. The persisted `coding` key remains compatible behind the Background Agent Jobs label.

## Version 0.45.0 (2026-07-26)

- Add a Console start page, consistent resource navigation and paging, Principal access, and clearer provider and Job views. Improve responsive layouts, labels, errors, motion, contrast, and keyboard navigation.
- Remove an Agent's visible reply when its source message is recalled, and repair Agent Library defects and misleading success states.
- Rebuild the Website around current product outcomes with consistent English and Chinese copy, a dark default, responsive composition, and a restrained motion system.
- Keep Website-only changes from rebuilding runtime images and pass requested report length to Deep Research as an approximate target.

## Version 0.44.0 (2026-07-26)

- Bound and persist the first Brain Stage A window for channels without a cursor.
- Add one Console editor for the five `brain.*` settings and separate installation-owned settings from operator-editable values.

## Version 0.43.0 (2026-07-25)

- Add compare-and-set Console editing for per-Agent Skill experience so stale edits cannot overwrite newer curation.
- Improve the ACH playbook and correct the repository changelog rule.
- Show Identity Provider callback URLs and current DingTalk credential names with targeted failure guidance.
- Let adapters validate credentials before the setup flow redirects to the provider.

## Version 0.42.0 (2026-07-24)

- Fix AIGateway compaction accounting and keep valid function call-output boundaries during overflow truncation.
- Add Turn-scoped runtime facts and redact Worker authentication and declared Agent secrets before provider-bound previews and outboxes.
- Add human-operated Lark approvals and Console editors for Brain embedding and retryable Stage B curation.
- Use forwarded HTTPS for OIDC callbacks and stop enabling the GitHub Agent Plugin for every Agent by default.

## Version 0.41.0 (2026-07-24)

- Remove generic Agent Home path policy from Computer tools while preserving domain-owned paths for attachments, Skills, learning, Job artifacts, and transfers.

## Version 0.40.0 (2026-07-23)

- Remove the CodexRunner `codex_no_progress` termination policy.

## Version 0.39.0 (2026-07-23)

- Repair Feishu CardKit crash recovery and prevent abandoned previews from blocking durable terminal replies.
- Show each clarification choice on its own button.

## Version 0.38.0 (2026-07-23)

- Resume group replies after the Brain visibility migration.
- Repair Feishu CardKit recovery when the provider omits an expected interactive element.
- Allow Brain Stage B to edit or delete the first block at position `0`.

## Version 0.37.0 (2026-07-23)

- Return readable rendered-browser content even when a page never emits `DOMContentLoaded`.
- Rate-limit Feishu CardKit writes without blocking durable replies, and delete old visible replies when `/retry` retracts them.
- Add a two-step AIGateway provider-removal lifecycle and align the Console file browser with Agent-scoped roots.
- Restore JavaScript-safe Schedule IDs, localize Background Job activity in Chinese, and update Turbo to 2.10.6.

## Version 0.36.0 (2026-07-23)

- Publish verified control-plane and Agent Computer manifests through the `main-latest` channel.

## Version 0.35.0 (2026-07-23)

- Restore RuntimeFabric image builds after workspace and Playwright packaging changes.

## Version 0.34.0 (2026-07-18)

- Replace model-visible `/workspace` paths with direct `/agents/<agent-key>` Agent Home paths.
- Share Home and Codex state at Agent scope, and project current Agent documents. Pin each Agent's live Sessions and Jobs to one Worker and Codex account.
- Change Control Plane Plugins to an explicit global allowlist. Existing shipped integrations migrate. New or invalid plugins stay disabled until an operator enables them and restarts Ankole.
- Complete RuntimeFabric ownership cleanup and pin both Agent Computer images to Codex 0.144.6.

## Version 0.33.0 (2026-07-18)

- Reject Background Agent Jobs that still use caller-local `/workspace/user-files` or `/workspace/temp` paths.
- Make `bun dev` shut down cleanly on Unix hosts that reject process-group signals.

## Version 0.32.0 (2026-07-18)

- Allow upgrade from unreleased destructive Job migrations only when PostgreSQL proves that no legacy Job was accepted; otherwise require backup recovery.
- Stop treating admission-only AIGateway frames as stalled output, while retaining stale detection after real output.
- Prevent cold-cache Skill edits from exhausting database connections and add default CJK Matplotlib fonts.
- Bound repeated no-progress Job calls and force stuck Vite watcher shutdown after its graceful window.

## Version 0.31.0 (2026-07-18)

- Publish control-plane and Agent Computer images as one verified, immutable RuntimeFabric pair and reject incompatible mixed runtimes before work starts.
- Make Background Agent Jobs the durable owner of long-running Codex work, with guarded migration of older Job history.
- Repair signal ordering, Schedule recovery, Brain source withdrawal, AppConfigure consistency, Console editing, and BullX native MCP access.
- Patch provider dependencies and restore repository, protocol-generation, lifecycle, and recovery gates after the TypeScript transition.

## Version 0.30.0 (2026-07-18)

- Restore control-plane image dependency installation for the `@ankole/browser` workspace.

## Version 0.29.0 (2026-07-18)

- Migrate RuntimeFabric RPC business payloads from hand-maintained JSON to generated Protobuf messages.
- Align real-LLM Job checks with the persisted Agent Plugin selection.

## Version 0.27.0 (2026-07-18)

- Make queued ambient group intervention use the latest valid channel scene and complete stale, expired, or disabled events without dead-lettering.

## Version 0.26.0 (2026-07-18)

- Keep Feishu WebSocket reconnection in its direct Mint-based owner instead of a shared adapter abstraction.

## Version 0.25.0 (2026-07-18)

- Remove wording-pinned tests while preserving the Skill activity test that prevents file paths and content from leaking into user-visible progress.

## Version 0.24.0 (2026-07-18)

- Add a repository subtraction discipline that removes superseded concepts unless a real dependency or staged migration requires them.
- Set the design priority to simplicity, correctness, consistency, then completeness.

## Version 0.23.0 (2026-07-18)

- Remove low-yield OpenAPI, Schedule, and wording tests while keeping contract and real end-to-end owners.
- Make Brain Stage B source revalidation non-locking so provider edits and deletes do not wait on Brain.

## Version 0.21.0 (2026-07-18)

- Replace per-method Worker RPC wrappers with one required typed requester while preserving rejection and transport-retry behavior.
- Make always-present Turn capabilities required and move strict Background Job response decoding into the RuntimeFabric contract.
- Use one rendered `web_fetch` construction for main turns and Codex Jobs.

## Version 0.20.0 (2026-07-18)

- Define and validate the complete 33-command browser wire protocol once, and derive both CLI parsing and execution from that typed declaration.

## Version 0.19.0 (2026-07-18)

- Resolve completed and current AIGateway Responses through public completion anchors and metadata APIs instead of probing storage layout.

## Version 0.18.0 (2026-07-17)

- Move Identity Provider directory writes into one control-plane owner for groups, bindings, memberships, and subject synchronization.

## Version 0.17.0 (2026-07-17)

- Freeze Background Agent Job Session IDs as the public `"job:" <> job_id` format with one owner.
- Harden Agent Computer path containment against lexical and symlink escapes while preserving intended Session file access and atomic moves.

## Version 0.15.0 (2026-07-17)

- Make each model tool own its user-visible activity text, with a generic fallback only when description generation fails.

## Version 0.14.0 (2026-07-17)

- Derive Background Agent Job RPC, summary, and Console projections from one field owner and validate Console responses against closed OpenAPI schemas.

## Version 0.13.0 (2026-07-17)

- Consolidate common adapter map decoding in one host-owned helper while keeping provider-specific formatting separate.

## Version 0.12.0 (2026-07-17)

- Execute function calls only after a successful tool-use terminal. Reconcile durable results to explicit calls, and quarantine malformed historical pairs without rewriting their audit rows.
- Repair bounded malformed arguments against schemas and split file editing into strict `replace` and V4A `patch` tools.
- Make Protobuf the sole RuntimeFabric envelope definition across Rust, Elixir, and TypeScript, restore the output-token ceiling, and preserve rolling-deploy decoding with golden fixtures.
- Let recoverable Job wakes use the Job attempt budget, remove obsolete delegation retention code, and unify rendered `web_fetch` fallback settings.

## Version 0.11.0 (2026-07-17)

- Add DingTalk as both a chat adapter and an Identity Provider with Stream connections, OAuth login, directory sync, robot messaging, and card support.
- Limit DingTalk groups to addressed-only messages and document unsupported reply, edit, reaction, and reconciliation features.
- Deliver streaming AI replies through operator-configured DingTalk card templates, with continuation cards for long answers.
- Fall back once to durable plain Markdown when card configuration or permanent provider rejection prevents card delivery, and disable departed users from contact events.

## Version 0.10.0 (2026-07-17)

- Add a Console Schedules page for recurring cron work and pending checkbacks, including edit, pause, resume, run-now, delete, cancel, and history actions.
- Add Agent Session listing for the Console, with manual Session ID entry when no durable activity exists.

## Version 0.9.0 (2026-07-16)

- Replace Subagent Delegation with durable Background Agent Jobs; the migration requires no non-terminal old Jobs and does not add compatibility aliases.
- Add resumable Codex Job execution, Agent Plugins, Skill inheritance, Console Agent Library management, and ordinary Plugin-based Deep Research.
- Narrow main turns to foreground work, move durable work and browser automation into Jobs, and replace mcporter with native MCP for allowlisted capabilities.
- Add a persistent browser data plane and pin Codex 0.144.5. Define the Worker container as the security boundary, and make development shutdown cleanly own all child processes.

## Version 0.8.0 (2026-07-15)

- Improve localized Console providers, IM batching and reply context, Checkback controls, CardKit activity, onboarding, Agent documents, visual identity, and CJK artifact fonts.
- Rebuild Deep Research, delegation recovery, Brain evidence curation, source learning, clarification, and retained context around durable, operator-visible contracts.
- Add the long-running Browser Skill, provider-only web profiles, bot-operated Lark Skills, OpenRouter image generation, and read-only Conversation inspection.
- Harden Worker recovery, RPC isolation, file transfers, generated-image persistence, Job output schemas, research retention, and channel-less internal Turns.

## Version 0.7.0 (2026-07-15)

- Query only the selected BullX MCP tool schema so large catalogs cannot truncate into invalid JSON.
- Route cutoff-based latest-bar requests separately from explicit historical ranges.

## Version 0.6.0 (2026-07-15)

- Make `/retry` retract the visible completed suffix and regenerate from its predecessor.
- End valid clarification turns immediately, preserve degraded Brain-search status, and keep one stable prompt and deterministic tool order per conversation.
- Route BullX and web-search profiles correctly, support providers without optional credentials, and keep Skill catalogs bounded.
- Prevent CardKit preview races and use the Agent owner's embedding profile when Brain has no global model owner.

## Version 0.5.0 (2026-07-14)

- Align Auth, Setup, and Console around one responsive Carbon-inspired shell and editor hierarchy.
- Split Brain into Entries, Audit, and Dreaming surfaces with clear filters and run ownership.
- Add typed settings, explicit save boundaries, accessible empty and error states, sensitive-value handling, and a persisted light or dark theme.

## Version 0.4.0 (2026-07-14)

- Prevent `/new` and `/stop` from reviving retryable Turns after cancellation.
- Keep stopped CardKit replies truthful when no partial answer exists.
- Degrade a failed remote Markdown image to its link without delaying durable delivery.

## Version 0.3.0 (2026-07-14)

- Reframe the root architecture maps around product entry points, AIGateway, Brain, durable delegation, and artifact ownership.
- Move migrations and Worker authentication bootstrap into release-owned commands.
- Add streaming Lark CardKit replies with progress, clarification, attachments, and long-answer continuation.
- Recover CardKit delivery after process loss and fall back without dropping terminal results.

## Version 0.2.0 (2026-07-14)

- Make Feishu and Lark CardKit replies durable across preview races, restarts, long Unicode or code answers, and provider limits. Preserve replies during image failures, clarification actions, cancellation, and binding repair.
- Strengthen AIGateway replay, `/retry`, function-tool validation, Brain curation, resident context, scheduled silent output, and renderer-safe progress.
- Improve Console provider setup with clear labels, typed options, advanced fields, masked secrets, custom models, and stable navigation.
- Harden Worker deadlines, process fencing, cross-mount file transfer, local Skill execution, SignalsGateway message storage, and the local end-to-end setup path.

## Version 0.1.0 (2027-07-13)

- First preview release of Ankole.
