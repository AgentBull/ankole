# Changelog

## Version 1.0.0-rc.2 (2026-08-30)

- Console editors now stop an incomplete save in place: the page focuses the first missing or invalid field and shows a message in the app language next to that field, instead of a generic English "request failed" banner. Leaving a required field empty flags it as soon as you move on, with the same timing in every editor. Draft problems and real request failures now use separate banners.
- A save the server rejects now names the exact problem in the app language: missing or invalid connection fields on routing rules, identity providers, and structured settings values. The Brain object editor picks the type from the installed list and shows the slug format rule, and duplicate, reserved, or malformed slugs and types get clear messages. The Brain settings drawer marks its required model fields, blocks an incomplete save at the field, picks the provider from the configured provider list, and suggests catalog models per slot — embedding, rerank, or conversational — while still accepting a typed model id; empty dropdowns now show a select prompt.
- Agent chat replies no longer leak internal markers into a channel. Provider server-side web-search citation tokens and the silent-success sentinel are stripped from every channel-visible reply, so a message shows clean text instead of stray citation glyphs or a raw `<silent_success/>`. On an ordinary turn, a reply that held only the sentinel now asks the model once for real content instead of delivering the marker.
- The release-candidate review adds a few repairs: upgrading from a stored blank Agent display name now uses the Agent uid for its Brain object title instead of failing the migration; recalled-memory neutralization also covers the agent-environment-info envelope and escapes every bracket occurrence in a matched tag; a soft-deleted Brain object no longer surfaces to the model through a page read; and the Discord, Telegram, and WeCom connection reconcilers keep a working connection when another binding's configuration is incomplete, matching the Lark, DingTalk, and Slack behavior. The test suite also drops unused aliases, imports, variables, and a stray helper carried since the release candidate.
## Version 1.0.0-rc.1 (2026-08-30)

- When `remember` omits its scope in an IM conversation, it now uses the asker's Principal or the channel's member Group; an explicit writable scope still follows the Agent's confidentiality judgment. Malformed or fully rejected learning output remains retryable instead of being marked learned, and Source revision, archive, and long-content fences have stronger regression coverage. Archiving a Library Source now withdraws its managed pages from every entrypoint, Brain searches treat wildcard characters literally, internal control claims stay out of Console results, and `remember` supports a validated resolution date for takes. Recall, context, page reads, and synthesis now use the same conversation reader set, synthesis links only its real evidence pages, and self-healing applies the normal semantic deduplication rules when it rebuilds embeddings after an outage.
- Provider failures before output can be retried safely, PostgreSQL notification listeners reconnect after a database restart, terminal replies no longer show stale running activities, and repeated web fetches reuse clean results through one bounded Worker cache keyed by conversation or Codex Job. A control-plane restart now renews leases for live Workers before stale-turn recovery, so their in-flight turns can finish without dead-lettering or duplicate effects, and retryable internal failures while saving an idempotent Job turn checkpoint retry the identical request. Lark and Slack binding saves request an immediate connection reconcile, while an invalid replacement Lark identity no longer removes the working connection.
- Setup industry and plugin selections now update immediately under React Compiler by exempting only their Set-backed selectors from compiler memoization. Exact custom model IDs remain selectable, an external Principal without a local credential can be edited without inventing an email, and valid ambient replies survive irrelevant work authority while unrelated group conversation remains silent. A disabled Agent's delete action is available immediately after the disable confirmation closes, and Brain Health replaces unexpected provider, projection, and stored-setting details with plain localized messages while retaining the full cause in server logs. Provider subject IDs again match the installation-wide Principal namespace after email and mobile matching, so equal normalized subject IDs across providers deliberately share one Principal when contact matching misses; an existing explicit provider binding still wins. Lark now uses the normalized email itself as `external_id`, then falls back through `user_id`, `union_id`, and `open_id`, while binding every available fallback ID to the same Principal.
- The real-model and fault-injection suites now use the release DeepSeek and Qwen model matrix, current trajectory and tool-offset contracts, deterministic retry targets, race-free reconnects and Workflow wakeups, and collision-free disclosure fixtures; the release-candidate manual E2E pass also adds regression tests for every product repair found during the run. Internal write-scope, Library withdrawal, adapter polling, connection blocking, reply terminalization, and editor and Brain validation decisions now each have one explicit owner. Brain page grammar now runs in the native kernel as CommonMark through comrak plus one root `audience` tag and `[[slug]]` links; it rejects ambiguous tag positions and treats tag text in code as code. Source-learned media bodies are now read-only Source projections, and Console operators can create or edit instance Objects through a raw-source editor with scoped preview, line diagnostics, and conflict-safe saves. Contributor guidance now makes changelog entries historical records only, removes the unapproved alpha.6 provider-scoped identity claim, and forbids using changelog text as a product contract or design decision.

## Version 1.0.0-alpha.10 (2026-08-27)

- Agents can now learn external web material in conversation: the new `learn_source` memory tool registers a public URL and runs the learning pipeline in the background. A newly registered URL Source defaults to the registering conversation's audience — a DM registers it for its asker, a group chat for its member group, and `world` is an explicit choice; later calls for the same URL reuse that Source and report its existing audience. The Brain Agent Plugin's `brain-learning` Skill routes material kinds and scope judgment; the `brain-memory` Skill is removed, with its filing rules moved into the `remember` tool and its vocabulary lookup replaced by the rejection error itself, which now names the closest vocabulary terms (this also fixes the vocabulary file being unreadable in packaged releases).
- The system prompt now explains the Agent's own memory model — the shared Brain, automatic conversation learning, Dreaming maintenance, and the duty to repair memory when corrected — and `ConfidentialityPolicy.md` now materializes into Agent Home like `DESIGN.md`, so the scope guidance the memory tools reference is readable and stays read-only inside the shell sandbox.
- Product and Agent Plugin knowledge directories can now project world-visible, recallable pages into Brain and update them with the installed files. These managed pages are read-only — fork an ordinary knowledge page in the Console (`POST /brain/objects/fork`) to take it over — and an instance page at the same slug always wins. Removing a set soft-deletes its pages without purging attached claims and links, and restores them if the set returns; archiving its Library Source permanently withdraws the whole set.
- The Brain Agent Plugin now ships Skills that Brain discovers from their names, descriptions, and tags without listing them in every prompt (`idea-lineage` and `applied-reading`). Current Plugin and Skill settings gate discovery and loading without deleting the shared projection; Recall points the model to `skill_view`, `get_page` delegates to the same loader, and Background Agent Jobs now use Ankole `skill_view` instead of Codex native Skill discovery.
- The Brain Agent Plugin grows an applied method set adapted from GBrain (MIT, recorded in the Plugin's third-party notices): `brain-learning` now also routes recordings, files, and meeting transcripts, captures a person's own ideas verbatim, and owns the memory write and repair discipline; the new `resolve-before-asking` Skill exhausts memory before the Agent asks who someone is; `idea-lineage` traces how one idea evolved through memory; `applied-reading` turns a book into a whole-life mirror or a problem-lens playbook. A pre-upgrade Job migrates its stale native Skill roots once, preserves its Workspace instructions, and replaces its frozen Codex thread, so a disabled or updated Skill follows the current loader after resume.
- The Console shows library pages as such: the Object list and detail carry a Library badge, and ordinary library pages hide forget, restore, and rollback actions behind an explanation and offer Fork with a confirmation that states the trade (editable, but no longer updated with the product). Lazy Skill discovery pages instead explain that Agent Library owns their availability and link there without offering Fork or Object lifecycle actions. Library sources get a readable kind label, and their archive confirmation states that archiving permanently withdraws the whole page set and cannot be undone — in all four Console languages.
- Conversation learning no longer files one named entity under two memory pages: before extraction runs, the pages the conversation already names (by exact alias) are listed in the extraction prompt with the rule to reuse their slugs instead of declaring new pages.
- The Console gains a Brain merge queue: a daily mechanical scan pairs look-alike pages of one type (shared alias or near-identical title) for review, and approving a pair merges it — every claim, timeline entry, tag, alias, and link moves to the surviving page and the old slug becomes a redirect. Nothing merges automatically, a rejected pair is never suggested again, canonical Principal pages never merge away, and reviewed or Principal-only prefixes cannot starve later candidates from the queue.
- Brain recall now fails closed when an IM recipient set cannot be resolved, and a scheduled reply checks every delivery target. Recall and background maintenance exclude claims on forgotten Objects, vector comparisons use the signature of the runtime model that produced them, and learning from a group or direct message cannot widen its audience to the whole instance. Recalled memory and runtime environment values cannot close their model-data envelopes.
- Foreground ambient replies now receive only read-only local tools and hosted web search. Console claim search runs before the 100-row display limit and treats SQL wildcard characters as text, Unicode and percent signs in Object paths no longer crash the page, and irreversible source archive and suggestion rejection actions require confirmation.
- Delayed or retried Brain maintenance keeps its original cron minute and retries enqueue failures, and one invalid Library inventory no longer prevents the same self-healing sweep from repairing other Brain projections. Manual identity mapping cannot reassign an existing provider subject. Known and missing email sign-ins now receive the same retry limit; the in-memory key set is hard-bounded and fails every email closed when saturated. Telegram sends images correctly and advances past permanently invalid updates; Telegram and Discord split Unicode-heavy replies within provider limits. Lark, DingTalk, and Slack keep live connections when desired configuration is incomplete.
- RuntimeFabric now has one protocol-version owner in the kernel and only the current version 5 contract and fixtures. Operators must stop existing Workers and deploy the control-plane and Worker images from the same release. Direct upgrades to this release are supported from v0.62.2 or a later stable release; fresh installs start from one v0.62.2 schema baseline, published stable migrations stay intact, and unpublished alpha schemas are not migration states. Stored values from supported stable releases are still normalized or read where needed. Agent-installed Skills now have one model-catalog rule: every enabled Skill enters the catalog; no shipped Skill uses `disable-model-invocation`, so that frontmatter field and its runtime plumbing are removed. Unconsumed Skill summary fields are also removed.
- Replying to a failed Agent message with `/retry` now retries that exact ActorEvent, including scheduled work in its own Session and replies whose confirmed provider send could not be mirrored locally. A bare `/retry` controls only live work and otherwise asks for an exact reply or ActorEvent reference, so unrelated channel completions are never selected. A failed retry attempt no longer blocks a later exact retry, and an unavailable target now tells the user to send the original request again.
- Main Agents can now start a durable Workflow that runs a fixed JavaScript program, fans bounded work out to independent subagent turns, combines structured results across stages without another parent-model turn, and wakes the owner Session when it completes or fails. Operators can cap calls and concurrency with the new `workflow.*` settings; Workflow tasks cannot create nested Workflows. Retrying one create tool call returns the same run. Queued tasks start when a capacity slot opens, up to four kernel replays run at once and retry after 30 seconds when busy, large fanouts enforce the 6 MiB memo limit without re-encoding prior task history on every result, and read-only Brain access remains usable when a page is a lazy Skill discovery record.
- Workflow tasks can now hibernate and wake: a task delegates one or more Background Agent Jobs, sleeps without holding a worker slot, and wakes in the same conversation when a delegated job finishes, when the main Agent messages it with the new `send_message_to_workflow_task` tool, or at its sleep deadline. A task blocked on a decision escalates with an attention note that wakes the main Agent at most once per hour per run, and `show_workflow` now lists live tasks with their status and waiting notes. When a run ends, no task can create or continue a delegated Job across the terminal transition; stop cleanup retries after a process restart until every task and Job is stopped. A dead-lettered Workflow completion notice now delivers the run outcome directly, like job notices.
- The default Workflow fanout ceiling drops from 256 to 32 Agent calls per run; raise `workflow.max_agent_calls_per_run` to keep larger runs.
- A real-LLM end-to-end suite now drives the whole Workflow lifecycle over fake Feishu — fanout, sleep and wake, attention escalation with an owner answer, Job delegation, failed-run channel replies, the failed-task null contract, cancel that stops a delegated job, a free-form run whose script and task prompts the model writes itself, and Brain embedding/rerank against the configured qwen models — and it caught that Workflow completion replies never reached the channel, which is fixed. A chaos scenario now kills the Worker mid task turn and proves the watchdog requeue and a replacement Worker finish the run, and new tests pin the task mailbox timing and the dead-lettered Workflow completion notice.
- The Skill lesson reflection log now counts rejected field notes by the gate that blocked each one, so operators can tell harmless duplicates from a reflection that keeps proposing the same blocked note.
- Internal: external identity binding, Workflow persistence and terminal cleanup, asynchronous work failure policy, Brain Source state and Console reads, local-password credentials, Turn request projections, RuntimeFabric RPC response types, the pi stream cursor, and UTF-8 byte trimming each have one owner. RuntimeFabric now checks each Control Plane RPC response against its generated type, representative request and response bytes decode identically in Rust, Elixir, and TypeScript, and Skill lesson overlays carry typed text instead of JSON-wrapped text. Workflow boundary maps use one key shape. Agent Plugin and Skill runtime catalogs now resolve together in the conversation context, connection teardown accepts only explicit complete or incomplete snapshots, and Workflow task helpers stay private. Product behavior is unchanged.

## Version 1.0.0-alpha.9 (2026-08-27)

- The ChatGPT account dialog now reports the real sign-in failure — the upstream HTTP status and error code, a denied or expired login, an unreachable sign-in service, or an unreadable stored credential — instead of "provider configuration is invalid". ChatGPT sign-in and token refresh follow the HTTPS_PROXY/ALL_PROXY/HTTP_PROXY/NO_PROXY environment like model traffic, send Proxy-Authorization when the proxy URL carries credentials, log a warning instead of silently connecting directly when the proxy value is unsupported, and each credential-refresh failure writes a warning log with its upstream cause.
- Console API errors stop leaking raw internal terms: a known configuration or sign-in mistake names the violated rule, and an unexpected failure answers with a plain message and a server log entry.
- An IM sender observation no longer renames a user who already has a display name; only directory sync updates names. Conversation lists and details now advance their update time with new messages, so ordering follows last activity.
- Disabled agents stay visible: the agent list shows every agent with its status, a disabled agent can be re-enabled or opened in the editor, and deleting follows the provider pattern — disabling first, then a second delete permanently removes the agent and its records with a matching confirmation and toast. Pickers that target new work — signal routing rules, schedules, and the worker file browser — offer only agents that can run. The Website agent guide and Console API reference describe the new lifecycle in all four languages.
- Console polish: computed groups show "—" instead of a 0 member count, the signal-source group type is translated and missing settings descriptions are filled in across the four languages, Brain health shows a plain reason instead of a raw error and formats queue age as a duration, conversation details carry a page title, principal and membership pickers match UID searches, and the Chinese disabled-status label is "已停用" everywhere.

## Version 1.0.0-alpha.8 (2026-08-27)

- Telegram and Discord connections survive hostile and busy conditions: a forged Telegram callback token no longer wedges the poll loop on one update, a Discord event backlog at the queue bound now sheds what a resume can replay instead of reconnecting forever, reconnect backoff resets on durable progress rather than on every resume handshake, and two Agents that name their bindings identically no longer overwrite each other's bot token. Reaction lookups no longer leak into another chat whose numeric id extends the reacted chat's, and mention removal follows the message's entity offsets, so a username that extends the bot's stays intact.
- A half-delivered multi-message reply now reaches an operator as a delivery problem on both Telegram and Discord instead of failing silently, and a Telegram reply reposted after a human deleted it keeps its reply anchor.
- The Worker agent loop regains three guarantees the pi runtime swap had dropped: per-tool trace spans, a repeated-failure warning that counts blocked and unknown-tool calls and keys on the exact failing call rather than the tool name, and the one-nudge-then-repair recovery ladder. Declaring a tool's execution mode is now mandatory, and a parallel tool must be read-only and not destructive.
- Memory recall now ranks with the kernel's real fused scores, so a result that both search routes found keeps its full margin through confidence and recency weighting. A source-learning run whose extracted items all fail validation now rolls back whole and retries later instead of erasing the previous revision's knowledge and recording the source as done. A failed signal-source group write now refuses the message for retry instead of admitting the sender with a narrower permission surface, and a decided memory contradiction can no longer be flipped again.
- The Console brain settings gain the two skill-learning keys (enabled and reflection threshold), the cron editor no longer keeps a stale mode after a restored setting, and the identity-mapping pages use the single-principal picker that shows the current selection.
- Trajectories recorded before 2026-08-13 no longer render: the item stream is the only readable form, old Turn pages show empty, and the retired trajectory-group storage is dropped. The retired ambient two-valued decision column and the unused quantitative claim fields are also removed.
- The BrainV3 and Skill Lessons design documents now exist in English at the referenced paths, and the READMEs describe Brain again, including the PostgreSQL `pg_search`/`vector`/`pg_trgm` requirements.
- Internal: local sign-in credentials, take calibration, and the hosted-response size budget move into their own modules; email normalization, reflection-job filtering, current-fact queries, and budgeted image walks each collapse into one owner. Behavior is unchanged.
- One Background Agent Job that fails while finishing no longer takes the whole Worker down with it, so the Jobs and conversations sharing that Worker keep running. A Codex runtime that floods its output without a line break now ends alone instead of exhausting Worker memory, and preparing a task cannot leave a listening socket behind when it fails part way.
- Queuing a file for reply delivery now reads only the file's size, so a very large file no longer risks the Worker's memory, and a path outside the Agent's user files is refused before the file is touched at all. A file read reports failure when its path became a different file during the read, even when the replacement has the same size and timestamp.
- A provider that answers a rate limit with a malformed `Retry-After` no longer parks a turn on a value read out of the junk, and a legitimate but very long wait is now bounded.
- The `todo` tool rejects a malformed task list with a clear message instead of storing repaired placeholder items, and the memory tools now reject an off-grid confidence or weight and an unparseable date bound where the agent can see it, rather than after a round trip to the control plane.
- Shutdown no longer waits out a timeout for its final trace export, so a Worker stops faster and keeps the last spans of its run.
- The main agent gains three workspace tools: `find` searches file paths fuzzily over a warm in-process index ranked by relevance and recency, `grep` searches file contents with smart-case and auto-detected regex grouped by file, and `ls` lists one directory deterministically. All three stay inside the Agent Home, so every result is a path the other tools can open.
- A shell command whose output was truncated now saves the pre-truncation text under `~/.ankole/command-logs/` and reports the path, so the agent can read the dropped middle back. An oversized `read_file` page now returns the lines that fit the budget with the exact offset to continue from instead of rejecting the read.
- Console menus, dialogs, and side panels now start immediately and stay interruptible: sheets slide from the screen edge, expanders reverse mid-motion, and the readiness bar grows without reflow. Table and nav hover paint no longer stick after a tap, Brain and Access tabs fade their rule instead of jumping it, and the theme control replays its mark.
- Browser session loading and durable Worker turn replay now distinguish absent data from malformed or unreadable data, so corruption fails clearly instead of silently starting from empty state. Brain context lookup failures also reach the Worker log.
- The Website now describes Brain directly as a world model that learns from experience. Internally, Signal Adapter OpenAPI types match the runtime field contract; redundant AI Gateway mapping and telemetry layers, unsafe Console casts, and a Console import cycle are gone; and direct control flow replaces avoidable nesting across production code.

## Version 1.0.0-alpha.7 (2026-08-25)

- Upgrading deletes the previous Brain memory storage permanently: entries, bodies, relations, episodes, audit history, and retained source material do not survive, and no migration into BrainV3 exists. Conversation knowledge relearns automatically from the retained channel message history once the `brain.*` models are configured; manually curated memory and uploaded source files do not come back, so export anything you need before you upgrade.
- Agents gain BrainV3 long-term memory: one instance-shared knowledge space with scope-based knowledge and disclosure boundaries, `remember`/`recall`/`get_page`/`forget`/`entity`/`whoknows`/`synthesize`/`delta` tools, automatic batch learning from IM channel conversations, file and url source learning, and zero-model context packs plus volunteer pointers injected into turns. A `synthesize` page inherits the audience of the evidence it reasons over, so a conclusion never reaches more people than the facts behind it, and evidence that the page cannot carry stays out of it. A context pack also carries what each participant told the agent in that chat when the claim named no page, while a volunteer pointer names only a live page the message itself names, instead of repeating recently touched pages on every turn. Url sources fetch through the web-fetch provider configured in `brain.web_fetch_model`, so pages become readable text instead of raw HTML; source learning runs as a background job, covers the whole content of large sources, and relearning a changed source expires the claims of its previous revision. The BrainV3 design document and the shared vocabulary seed ship with it.
- Setup adds an industry schema-pack selection step (the general pack always installs; six industry packs are optional), and existing completed instances gain the general pack on upgrade. A daily Dreaming task maintains memory (consolidation, cross-page synthesis, link extraction, salience, take grading, calibration scorecards, contradiction probes, promotion suggestions, purge) and a Self-healing task rebuilds stale chunk, embedding, and search-index projections; both schedules and all memory models live under new `brain.*` settings with a dedicated Console editor.
- The Console adds a Brain area: object browser with version history, rollback, and restore of soft-deleted objects inside their purge window, claim management with supersede/forget, take resolution, contradiction triage, promotion review, learning-source management, any-principal search preview, per-principal knowledge audit, and a health page that also reports invalid stored `brain.*` settings, unavailable model providers, and context-pack injection counters.
- Every Agent now requires a human owner Principal (existing Agents backfill to the earliest administrator) and carries a group-memory disclosure mode (strict or relaxed). A scheduled turn — a cron fire or a check-back wakeup — has no asking sender, so it takes its memory disclosure recipients from the channel it delivers into and checks every one of them. `ConfidentialityPolicy.md` joins the editable Agent documents; IM group member Groups now mirror joined Agents as members. The per-Agent `embedding` and `rerank` model profiles are retired: operators must configure `brain.embedding_model` and `brain.rerank_model` instead, and API callers can no longer use the `embedding.default` or `rerank.default` selectors.
- Agents now learn per-skill field notes from their own job history. Once an agent accumulates enough jobs that carry mid-run human corrections or failed tool calls (`brain.skill_learning_reflection_threshold`, default 10), a reflection background job distills that evidence into short leased checklist notes; accepted notes appear under the skill's `Agent-specific additions` block, every note is re-checked when its 7-day lease ends or when the platform release or the skill body changes, and a note whose condition died is retired automatically. Mechanical gates bound the loop: a note needs two independent evidence jobs (or one with human input), at most 2 land per skill per reflection and 10 stay active per skill, and note text can never contain a URL. `brain.skill_learning_enabled` turns the whole loop off. The design lives in `docs/design-docs/SkillLessons.md`.
- Operators manage skill notes on the Agent Library page: list active and retired notes with their evidence jobs, add permanent notes by hand, and retire any note — an operator-retired note is never learned again. The skill-overlay editor and its Console endpoints are gone, and the worker loses the `skill_append` and `skill_replace` tools: an agent no longer edits its own skill guidance mid-task. Existing overlay texts migrate automatically into operator notes, and the Brain health page reports note counts and drift signals.
- The Website explains Brain and Agent-specific Skill lessons in English, Simplified Chinese, Japanese, and Korean. Its Agent, architecture, Signal routing, model, cost, AppConfigure, and Console API guides now use the same memory, disclosure, lesson, and instance-wide model contracts.
- In **May intervene** group chats, Agents now route each new message batch to silence, a bounded foreground reply, new work, or one matching live background Job. Substantial work without a direct request or standing-order authorization asks for confirmation before it can start, foreground replies cannot create Jobs, and a silent Job handoff commits with the channel judgment so retries cannot change its target.
- Background jobs gain read-only Brain `recall` and `get_page` tools, and the deep-research plugin now consults instance memory before external search. A job cannot write memory, so the agent that delegated it files the durable conclusions when the job returns. `remember` accepts an `until_date` on take-kind claims, and deep research registers report predictions that carry a resolution date as gradable Brain takes, feeding the existing calibration scorecards.
- Deep-research jobs tighten their evidence loop: collector threads now also report counter-evidence they ran into, follow-up collection aims at the weakest points instead of re-collecting what already has independent support, and the verifier re-derives the measurements a conclusion rests on by a different method, reports where the conclusion would flip, and flags a conclusion that is safe but adds no information as a defect of the same rank as overclaiming. A new `scientific-research` Playbook adds derive-with-code, primary-literature, and identifier-exactness practice for science and mathematics tasks.
- web_fetch answers a URL repeated within one session from its earlier result instead of downloading the page again, and labels a script-shell or zero-text page with what to try instead of re-fetching it.
- A tool call that the model's output token limit cuts off now enters the conversation as the call together with a standard error result, and the model retries once from that record. The job trajectory shows the failed attempt instead of a synthetic message that described where the arguments stopped.
- Feishu and Lark requests work again: the previous release combined two Req transport options that Req 0.7 rejects, so every OpenAPI call failed before it reached the network. Both default timeouts now travel in the one accepted option.
- Internal: the fake Feishu test server accepts an explicit chat id from its CLI and regenerates its chat-id token on every server start, including a restart inside one OS process, so no run can reuse a chat that an earlier incarnation already mirrored. Every generated id — messages, events, reactions, file and image keys, cards — now carries that per-boot token too, so a restarted platform can no longer mint a message id that a connected control plane already mirrored from an earlier incarnation and have the new message silently treated as an edit of the old one.
- Internal: parallel control-plane tests no longer fail at random. An AppConfigure cache miss now reads the database in the requesting process and the after-commit refresh reads as the writer, so a concurrent test that clears the cache cannot make outbound delivery in other tests lose the worker auth key, and the advisory-lock timing test uses its own lock key instead of the shared fixture identifiers.
- Internal: the end-to-end suites create their agents with the human owner that Agents now require, so the gate suites run again instead of failing at setup.
- Internal: Background Agent Job creation now pins the Job's owner conversation itself on every creation path, so no creator supplies it. This also gives the successor Job that open steers seed after a run ends a conversation, which it had none of and without which it could not start.
- Internal: the fake Feishu server now serves the reaction list endpoint the Lark adapter uses to find its own reaction before it removes one, and the transport end-to-end test sends the emoji key the adapter accepts, so the reaction gate test exercises the real removal contract.
- Internal: the Agent Computer integration suite no longer expects the retired standalone compaction endpoint, so the suite runs without a false failure.
- Internal: Worker command-activity labels now come from one vocabulary table instead of branching code, the sandbox command environment builds its documented layering directly, and the Codex job runner names its repeated diff-accounting step. Behavior is unchanged.
- Internal: the Codex notification projection now parses every runtime notification the job session observes, so the session dispatches on typed variants only. A background Job's progress summary can now also report item starts, MCP server startup failures, credential-pool exhaustion, and compaction completion.
- Internal: Worker images now pin Codex 0.150.1; AIGateway model cards and app-server protocol bindings match that runtime.

## Version 1.0.0-alpha.6 (2026-08-22)

- Direct upgrades to this release are supported only from v0.70.0 or later. RuntimeFabric no longer accepts the terminal envelopes retired before that support window, so an installation older than v0.70.0 must not upgrade directly.
- Cron schedule creation and route updates now accept only `delivery.targets`. The v0.68.3 upgrade already migrated stored schedules; API or Worker callers that still send scalar `signal_channel_id` and `provider_thread_id` fields must send a target list instead.
- AIGateway message rows and the Console API no longer expose one row-level `role`, because one Response run can contain items with different roles. Callers must read roles from the items in `content`; the upgrade drops the obsolete database column automatically.
- Moving a signal binding now keeps its group-message mode when the request omits it, instead of resetting it to the default. The retired `confidential_memory` setting is removed from binding storage, the Console, and the Console API; API callers must stop sending this field, and the upgrade drops the unused column automatically.
- Feishu and Lark OpenAPI requests keep the five-second connection-pool wait without emitting Req's deprecated `pool_timeout` warning.
- Setup now records the administrator's role and the completion flag in one transaction, so a failure part way through can no longer leave an installation that is claimed but unfinished. A wrong activation code no longer changes the installation language, the first forced password change checks administrator rights before it writes the new password and cannot be repeated with a copied link, and simultaneous group-membership changes no longer fail with a database deadlock.
- A reply that the chat provider acknowledges late can no longer overwrite the outcome that recovery already recorded, which removes a source of duplicate and lost replies. `/stop` during an active steer now cancels the reply that is really generating, an attachment that replies to an older message starts the next turn instead of joining the running one, an attachment from the same sender is still found in busy group channels, and deleting one message no longer blocks unrelated conversations in the same channel.
- Discord is now available as a chat provider. Give a binding the bot token from the Discord Developer Portal and the agent reads direct messages and guild channel messages, replies in the same channel or thread without triggering Discord mentions, keeps editing one running reply instead of posting a second answer, adds and removes reactions, sends attachments, and answers button clicks. Gateway reconnects keep received events in order, and each thread is a separate agent session.
- A Discord application must have MESSAGE CONTENT INTENT enabled in the Developer Portal before the "observe all" and "may intervene" group modes can work, because Discord otherwise delivers guild messages that do not mention the bot with no text at all. Without it the connection still serves direct messages and messages that mention the bot. An application that has an Interactions Endpoint URL set receives its button clicks at that endpoint instead of through Ankole.
- Removing a reaction on Lark now works instead of sending an invalid request. Lark, Slack, WeCom, and DingTalk connections stop when their binding is disabled, deleted, or given new credentials, so an old connection can no longer keep running or block its replacement. Five stream adapters now share one periodic reconcile lifecycle while keeping their provider-specific connection and message logic. Microsoft Teams channel synchronization stays inside the Microsoft app that owns each channel, one unreachable team no longer stops the whole synchronization, and a partly failed Microsoft Graph subscription setup no longer leaves subscriptions that Ankole cannot track.
- A reply that stops at the model's token limit is now reported as incomplete on non-streaming calls, as it already was on streaming calls. AWS Bedrock non-streaming replies return their text and token usage instead of an empty completed response, a hosted image request stops with a clear error after 16 internal rounds, and a change to a provider's configuration applies to its model catalog at once instead of up to an hour later.
- Native image models can now read files and generated images that you already sent to Ankole, including when you use one as an edit mask. An image they produce is stored under an Ankole artifact id and stays available for later requests, and a failed image in a multi-image request points at the correct output.
- A stateful response that cannot record its failure no longer reports that failure to the client while the stored response stays in the generating state. The client now receives a terminal response only after the durable record has that terminal result.
- Job trajectories now come from the recorded item stream and load one page at a time, so opening the details of a long job no longer reads its whole history first. Jobs recorded before the item stream keep their current content, order, and paging.
- Worker command output and file reads are now bounded while they are produced, so a command that writes without limit can no longer grow the Worker's memory. Browser page snapshots stop processing more accessibility nodes when their text budget is full; what the model receives is unchanged. A command that ignores the stop signal after its timeout is now forced to exit.
- One-shot model requests no longer hold a scheduler thread for the whole request, so several slow requests can no longer delay other native work, such as delivery to Workers. An unusually large `Alt-Svc` cache hint from a server can no longer stop a request, and one oversized provider event batch now fails with a clear error instead of passing the pending-event limit.
- Console fixes: a schedule can use a conversation id that is not in the suggestion list, the setup page shows the selected language at once and a slower earlier catalog load cannot switch it back, a double click on Save sends one request, a provider whose kind is no longer available is marked as unavailable with its edit actions disabled, and a malformed identifier in a Console API address returns a normal not-found result. The Console API description also no longer offers a model-profile `compaction` capability that the runtime does not accept.
- Documentation links in the architecture diagram and in the Japanese and Korean pages now reach pages and sections that exist, and the Korean architecture page shows the diagram in Korean. The Jupyter live-kernel Skill writes the kernel's original output to the notebook, so images and other rich output display again, and a clean run clears every code cell first, so a run that stops early leaves no stale results.
- Internal: reading a Skill no longer rewrites its registry row when nothing changed, and new job turns no longer store a second copy of their content.
- Internal: the website build now rejects links to missing internal files or page anchors, including links in serialized Astro island properties, and lists each source page and target. The repository no longer retains Astro's obsolete data-store cache.
- Internal: the Agent Computer type check now also rejects a missing `override` keyword, a switch case that falls through, and an import that is used only as a type. A write-only model-call field, an unread session flag, and an unused path parameter are removed, and the Worker logger selects its pino level through a declared level type instead of an untyped lookup.
- Internal: control-plane tests remove implementation-only duplication, avoid live provider access, and run more cases in parallel.
- Creating an Agent now writes its whole builtin Skill library in one statement instead of one per Skill, which takes the operation from 31 database round trips to 11 and about halves its time. Every Skill row still goes through the same validation before the write.
- Internal: starting a Turn now resolves the two BackgroundAgentJob placement limits before it opens its database transaction instead of inside it, so the transaction no longer waits on the settings owner for a value that has nothing to do with it. A terminal status commit stops resolving a limit it then discards. The capacity counts still run inside the transaction, so admission keeps its guarantee, and the control-plane suite drops from about 200 to 119 seconds.
- Internal: the Agent Computer now gives the Worker process lifecycle, active Turn state, execution materials, sandbox, Text Turn tool assembly, and Codex Job/runtime code separate module owners. SignalsGateway names channel-reply eligibility without treating all Signals as IM, and the Codex Job update poll names every Worker-local update queue that it drains. Comments preserve the non-local ownership, durability, and shutdown constraints; Worker behavior and external contracts do not change.
- Console timestamps now use the browser's standard date and time format for English, Chinese, Japanese, and Korean. Blank timestamps still show an em dash, and invalid values remain visible.
- Internal: the single-control-plane release no longer starts or configures DNS clustering, and its boot-order guides no longer list it. Dependency manifests remove an unused direct HTTP/2 declaration, an unused direct MessageFormat package, and the date library replaced by the browser formatter, and declare the websocket client that the Discord gateway connection uses. Devkit now uses the TypeScript version required by Crust.
- Long provider streams no longer rescan the whole pending SSE event for each network chunk or merge an earlier LF-delimited event with a later CRLF-delimited event. Streamed tool arguments and reasoning grow without copying their full accumulated text, hosted image limits no longer allocate a decoded image only to count its bytes, and an output event that cannot fit its downstream budget now returns a size error instead of ending as if the client cancelled.
- Internal: hosted responses count their growing public shape without copying earlier images or request history for each output item; AuthZ and Signal filters share compiled rules by source text without allocating lookup keys; RuntimeFabric NIF sends avoid an envelope copy, command waits wake without a fixed poll delay, and Dealer receives keep one total timeout; program replay moves its validated memo and tool map instead of cloning or validating them twice.

## Version 1.0.0-alpha.5 (2026-08-22)

- Worker tool failures reach the model with the failure marker and recovery hint again; a tool call with unparseable arguments fails alone and recoverably instead of failing the whole reply; and a reply-ending tool call (such as a clarify question) now ends the reply even when the model called another tool in the same round, holds queued user follow-ups for the next turn, and delivers several queued follow-ups in one model round instead of one round each.
- Worker sandbox `read_file` failures other than a missing file report the real operating-system error again; a namespaced tool call now runs the tool of its own namespace when two connected tool sources share one tool name, instead of whichever registered first; and a call to a tool that does not exist again returns the marked `Unknown tool` failure instead of an unmarked engine message.
- Moving a signal binding to another agent now keeps its "When account auto-mapping fails" setting when the move request omits it, instead of resetting it to "Hold for manual review".
- An unmatched sender whose admission group name collides with an operator-created group of the same name now records a clear failure instead of crashing the inbound message, including when the sender already belongs to that colliding group. Internal cleanups remove dead memory-source residue in reply rendering, a stale Brain metadata key in the real-LLM e2e suite, and the retired `--brain-real-llm` documentation, and align the chaos delivery-failure suite with the 1.0.0-alpha.4 provider-error classification.

## Version 1.0.0-alpha.4 (2026-08-22)

- Plain-message delivery failures on DingTalk, Lark, and Microsoft 365 now retry, wait for an operator, or stop according to the provider error, and honor the provider's requested retry delay, instead of repeating until the attempt budget runs out.
- A DingTalk or WeCom reply preview that hits a permanent or operator-level provider error now records its blocked state and stops repeating the failed recovery attempt.
- The console email field now stays editable for accounts with a linked external identity, which completes the email-edit change from 1.0.0-alpha.3.
- Empty, failed, stopped, and awaiting-input final replies now use the installation language instead of fixed Chinese text.
- Console, sign-in, and setup pages load much less JavaScript up front: the name-transliteration table, the Markdown renderer, the JSON tree editor, and the language catalogs now load on demand, and the shell preloads the active language. The sign-in page ships roughly half its previous script weight.
- Dark-theme operators no longer see a light flash on every full page load, and each Console page now names its own browser tab and history entry.
- A batch of Console interaction fixes: fast typing in a list search box can no longer lose trailing keystrokes to the debounced URL commit, a background refresh no longer clears form validation or decryption errors, a revealed secret always re-masks when its reveal is revoked, oversized tool payloads no longer pay for a JSON parse that cannot succeed, and the ChatGPT device-login countdown no longer restarts on unrelated re-renders.
- Large webhook lists stay responsive while searching, long conversation threads render faster, and the time-zone picker builds its option list in half the work.
- Internal: shared Console components narrow their contracts — a read-only editor page cannot receive submit props, capability toggles split into explicit global and per-agent controls, and one unused prop is gone. Users do not see this.

## Version 1.0.0-alpha.3 (2026-08-21)

- Ankole now has built-in local accounts. The setup wizard step becomes "Configure user sign-in" and can create the administrator with an email and password, and the sign-in page accepts email and password next to SSO. No external SSO provider is needed to start.
- Console principal management can add local users with generated one-time initial passwords, force a password change at first sign-in, reset passwords, and edit a user's display name and email. These controls appear when the local identity provider is enabled.
- Password retry protection allows at most 5 failed sign-in attempts per account inside a 30-minute window; further attempts must wait, and a password reset ends the wait at once. It is on by default, and the local provider configuration can turn it off.
- A new rescue command resets a local account password by email: `mix ankole.local_password.reset` in development, `bun kit local-password reset` from the devkit, or `Ankole.Release.reset_local_password/1` on a production release.
- Telegram is now available as the first consumer IM Signal adapter. One encrypted Bot token connects one enabled binding through supervised long polling with durable ingress; the adapter receives direct, group, forum-topic, reaction, and card-action input and sends mutable replies, attachments, reactions, dividers, and cards. Telegram cloud downloads above 20 MB remain as explicit unavailable attachment records, and rate limits follow Telegram's requested delay.
- The Signal Routing adapter selector now groups enterprise IM and consumer IM adapters. This category is display-only and does not change identity admission, routing, permissions, capabilities, or binding policy.
- Telegram and Slack replies that reduce to no visible text now show the empty-reply placeholder in the installation's configured language instead of a fixed Chinese string.
- DingTalk reply-delivery failures (for example an expired token or a deleted group) now stop or wait for an operator as appropriate, instead of retrying forever with the wrong failure reason recorded.
- An administrator can now edit a local account's email from the console even when that account also has a linked external identity, such as a manually mapped Telegram handle.
- A final AI reply on Slack, Telegram, Lark, DingTalk, or WeCom now goes through the same secret-redaction step as an in-progress reply before it reaches the provider.
- Internal: consolidated the setup-completion sequence and duplicated local-account and reply-delivery validation logic into single implementations, with no change in behavior.

## Version 1.0.0-alpha.2 (2026-08-21)

- Concurrent identity observations, Slack directory deltas, and signal channel updates now keep all accepted facts. A mapped account no longer returns to Pending mappings, a failed directory delta leaves the group unchanged, and concurrent channel metadata keys no longer overwrite each other.
- AppConfigure and Plugin process crashes now rebuild one consistent declaration and activation snapshot. Long-connection owners reconnect after their Registry fails, and Feishu, DingTalk, and WeCom token requests no longer wait until timeout when a fetch task dies.
- Feishu webhook verification tokens now use constant-time comparison, and an AIGateway Response process crash report no longer contains request content or credentials.
- The Background Agent Job detail page loads all Turn trajectories in one query. Internal AIGateway token ownership and fixed request-key handling are simpler, with no API or operator change.
- Chat attachment filenames now pass one shared sanitizer on all five platforms. A name that reduces to empty, `.`, or `..` is stored as `attachment`; DingTalk, WeCom, Slack, and Teams no longer keep raw dot names or fall back to `unnamed`.
- Internal: the Worker and the control plane remove dead scaffolding left over from the agent-loop replacement and this version's own refactors. Users do not see this.
- Internal: the Worker gives its Background Agent Job document shapes, turn-local CLI socket bridges, and tool-authoring exports one owner each, and the Console route loaders reuse the pages' own query builders. Users do not see this.
- Model-visible catalogs that sort names (skills, agent plugins, changed file paths) now order by Unicode code point on every runtime. A name with characters outside the Basic Multilingual Plane can change position once.
- Internal: duplicated inline helpers move to single owners — shared attribute-map and result helpers on `Ankole.Attrs`, canonical Principal UID normalization on `PrincipalKey.canonicalize`, Worker error/ordering/number helpers under `common/`, and shared Console test auth helpers on `ConnCase`. Same-named map helpers with different semantics received distinct names. Users do not see this.
- Internal: Worker duration constants use `ms('5m')`-style declarations, Console refresh cadences share one owner module with unchanged values, the kernel AI client uses one JSON codec (sonic-rs) throughout, closed-union dispatch uses exhaustive `match`, and audited pass-through layers (AIGateway request-key and stateful-conversation forwarders, dead execution-scope plumbing, identity casts) collapse onto their owners. Users do not see this.
- The Worker now runs Playwright, its browser daemon, and browser scripts on Bun. The Worker image no longer carries a separate Node.js runtime for browser automation.

## Version 1.0.0-alpha.1 (2026-08-20)

- Operators can now bind chat senders to accounts by hand. A sender that auto-mapping cannot identify appears under Identity → Pending mappings in the Console; binding the entry maps that platform account to the chosen user, and the same page can map an account before the person ever writes. Until then, an addressed message gets one fixed reply that asks the sender to contact an administrator, and the message is not processed.
- Each signal routing rule gains one switch, "When account auto-mapping fails": hold the sender for manual review (default) or create a standalone account and serve them at once. Deployments that relied on automatic account creation for unknown senders must switch existing rules to "Create a standalone account" to keep that behavior.
- Account auto-mapping now also matches by platform-reported email and mobile number, and Lark/Feishu senders without an employee id (external-group members) can now be identified by their open or union id instead of being dropped silently.
- Two permission groups now maintain themselves: one per signal routing rule with everyone admitted through it, and one per identity provider with everyone it imported, so policy can address "users of this source" or "everyone outside this provider".
- The login page lists only providers that can sign an admin in: the adapter must support OIDC login, and the provider's login toggle must be on. A provider configured only for directory sync no longer shows a login button that fails.
- Internal: sender identity resolution moved from the five chat adapters into one SignalsGateway owner, identity-provider login and directory sync are separate modules over one shared provider connection, and the unused reserved identity shapes (channel actor, login subject, outbound actor) are removed.
- A changelog version may now carry an `-alpha`, `-beta`, or `-rc` pre-release suffix. The runtime-image workflow publishes such a version as a GitHub pre-release and moves the `canary` image tag instead of `main-latest`, leaving the current stable release and `main-latest` tag untouched.
- Long-term memory (Brain) is removed ahead of a rewrite: an Agent can no longer recall past conversations or curated knowledge, write or update memory, or automatically learn from an attached source. Upgrading to this version permanently deletes all stored memory data — knowledge entries, chat-recall indexes, retained sources, and audit history — with no migration path; export anything needed first.
- The Console's Knowledge section (Brain) is gone: the nav item; the entry, audit, dreaming, skill-experience, source, and status pages; and the Dreaming and Embedding settings editors are all removed ahead of the Brain rewrite.
- The developer and user documentation site drops its Brain and long-term-memory pages, and every other page's mention of them, ahead of the Brain rewrite.
- Internal: the `tools/e2e` suite drops its dedicated Brain real-LLM mode and suite ahead of the Brain rewrite, and its skill-tool-call tests use the still-available `brainstorming` skill in place of the removed `brain-review` example skill.
- Internal: SignalsGateway drops its channel-visibility and confidential-channel queries and their tests. Brain was their only caller, and Brain is gone ahead of its rewrite.
- Internal: the control plane's `/api/v1/brain/*` API and its five daily background sync, embedding, and dreaming jobs are removed ahead of the Brain rewrite, along with the `pgvector` dependency and the underlying `brain_*` database tables, enum types, and search indexes.
- Internal: an AIGateway conversation no longer carries a Brain memory-store scope. The channel or DM label the Console shows now comes from a simpler "origin" fact recorded once when the conversation starts; existing conversations migrate automatically, and a channel's confidentiality no longer starts a fresh conversation when it changes.
- Internal: the Worker's main agent loop now runs on pi-agent-core's `Agent` class instead of a hand-rolled OpenAI Responses client. AIGateway stays the sole owner of durable conversation state and the wire protocol is unchanged; tool-call validation, activity reporting, structured logging, and parallel-tool concurrency bounds keep their existing behavior.

## Version 0.76.2 (2026-08-20)

- The Console can run a recurring schedule immediately again. A valid `Idempotency-Key` no longer crashes request validation, and a repeated request still returns the same scheduled event.

## Version 0.76.1 (2026-08-19)

- No product behavior changes. Agent Computer integration no longer expects the retired standalone compaction endpoint, and Schedule end-to-end coverage no longer declares an unused context, so the current compaction and scheduling contracts run without false failures or warnings.

## Version 0.76.0 (2026-08-19)

- Background Agent Jobs and conversations now run on OpenAI-compatible Responses endpoints that accept only plain function tools, such as DeepSeek. AIGateway sends the Codex custom tools to such an endpoint as function tools and restores the answers to their official shape, so the first request no longer fails with an unsupported-tool error.
- An OpenAI-compatible Provider connection gains one visible switch, "Supports official OpenAI tools", off by default. Existing OpenAI-compatible Responses connections move to the emulated function-tool wire on upgrade; turn the switch on for an endpoint that faithfully implements the official OpenAI Responses tool surface to keep verbatim custom tools and Provider-native compaction.
- Provider-native compaction no longer sends probe requests to an OpenAI-compatible endpoint that does not declare official OpenAI tool support; those connections compact locally without the wasted round trip.

## Version 0.75.1 (2026-08-19)

- Fix DingTalk AI cards to use the platform's native `isFinalize` and `isError` state transitions instead of the unsupported `flowStatus` template variable. A completed interactive card now finishes through the same native protocol. Operators who followed the earlier setup guide must remove `flowStatus` and `flowStatusVar`, bind the `answer` Markdown component in each active state layout, and republish the template.

## Version 0.75.0 (2026-08-19)

- One Agent can now keep several Lark or Feishu signal bindings enabled, each with its own application. Each enabled binding still owns one distinct `domain` and `appID` pair across the instance, and disabling it releases that application.
- A Turn or Automation Job now gets Lark CLI credentials from its current signal route. A disabled or unavailable explicit route does not fall back to another Lark application, and an execution with several Lark bindings and no matching route gets no arbitrary credentials. Existing bindings need no migration and move to an independently namespaced, binding-owned encrypted configuration when they are next saved.

## Version 0.74.5 (2026-08-17)

- A Deep Research collector now takes what it needs out of a source in the call that fetches it, takes everything it still needs in one pass when it goes back, and spends a call on a fact it has not written down rather than on one it has. A long collection run stops paging the same downloaded page or data file through the model again and again, which is where most of a Job's tokens went.
- Compaction now runs late instead of early. The trigger defaults to 0.90 of the model input context with a 400000-token cap, in place of 0.5 capped at 100000, and a Background Agent Job no longer tells Codex to compact at 100000 either, so Codex applies its own nine tenths of the window. Compaction also hands back twice as many recent rows. A long conversation or Job loses its working memory less than half as often, and stops repeating the work that each loss caused. An instance that stored `ai_gateway.compaction` explicitly keeps its old values: raise `threshold`, `max_threshold_tokens`, and `tail_rows` there to get the new behavior.
- Record why Provider-owned compaction stays off by default, so the reason survives the next person who reads the setting. Users do not see this.

## Version 0.74.4 (2026-08-17)

- Deep Research no longer spends a Job checking the material you supplied as settled. The task now names what the research must establish and what your own specification, rules, or parameters contribute as given, and the Job builds on anything marked given instead of collecting evidence against it, saying so in the report when it looks wrong. It still checks the outside facts your design depends on: whether what it assumes to exist, to cost that much, or to be large enough really is so.
- Before it starts a Deep Research Job, the Agent shows you the requirements it is about to send and what the Job will treat as given, and it asks the costly question — what the research must establish — before the cheap ones such as the output format. A requirement that first occurred to the Agent while writing the task now reaches you as a choice it leaves to the Job, not as an obligation you never saw.
- A Deep Research Job drops a question from its collection plan when neither answer would change the deliverable.

## Version 0.74.3 (2026-08-16)

- A Background Agent Job no longer fails at its first compaction. AIGateway now resolves a WebSocket caller's `previous_response_id` into the history it names before it decides what kind of request this is, so a compaction trigger summarizes the whole conversation instead of the few items the caller sent with it. The same request previously ended the Job with `invalid_previous_response_id`.
- A continuation anchor is now answered by looking it up rather than by reading its characters, because the characters can be a value the Provider chose. Two error codes change: a WebSocket anchor this connection never issued reports `previous_response_not_found`, and an HTTP compaction request that names stored history reports `stateful_responses_require_websocket`, which is what every other HTTP Responses request already reported. The retired `compact_store_required` code is gone.
- AIGateway does not send a Provider an identifier that AIGateway made. Users do not see this.
- A stored conversation keeps working after its Provider changes. An operator who repoints a model profile, or a vision fallback that sends one Turn elsewhere, no longer replays state that only the previous Provider can read and that the new one rejects. AIGateway drops the hidden reasoning and turns the sealed parameters of an earlier tool call into plain text, while every message, call, and result stays. The Agent derives that reasoning again, so the Turn can cost more.
- Record which side owns the identifiers on each AIGateway link, so a later change does not send an Ankole identifier to a Provider or replay one Provider's sealed state to another.

## Version 0.74.2 (2026-08-16)

- Provider-forwarded compaction now streams its request like every other Responses request and collects the whole reply before the caller sees any of it. Upstreams that accept only streaming requests, such as the ChatGPT subscription backend, can now answer native compaction instead of always forcing the local fallback.
- Compaction over history that already holds Provider-owned compaction state no longer fails when the Provider path is off or unavailable. The local checkpoint preserves the Provider items verbatim, summarizes only the items after them, replays the preserved state on later turns, and logs a warning. The reply still carries exactly one compaction item, and the retired `opaque_compaction_fallback_unavailable` error is removed.

## Version 0.74.1 (2026-08-16)

- Remove the retired standalone-compaction wire from the kernel and the last documentation references to the removed `/responses/compact` endpoint. No behavior changes; the unified `compaction_trigger` protocol already serves every caller.

## Version 0.74.0 (2026-08-16)

- Compaction now has one protocol and one owner. AIGateway answers the `compaction_trigger` item for every caller, so a Background Agent Job and a stored conversation compact the same way. The separate `/responses/compact` endpoint is gone, together with the per-Job switch that chose between the two protocols and the per-Provider request constructors that only that endpoint used; a Job frozen under the old switch keeps running.
- Provider-native compaction moved from a per-Agent capability to the `upstream` field of the gateway compaction settings, next to the other compaction fields. An instance that had turned it on for an Agent enables it once there; the retired per-Agent switch is removed from stored Agent settings and from the Console.
- An Agent that leaves compaction to its Provider now has that request forwarded through the same protocol instead of a retired endpoint. AIGateway reads the whole reply and checks it before the caller sees anything, and falls back to its own summary when the Provider answers with something else, unless that history already holds Provider-owned compaction state that only the Provider can read.
- Keep a caller's `encrypted` tool-parameter declaration on any Responses provider instead of only on providers Ankole recognizes. The declaration is the caller's, the wire can carry it, and a provider that validates against a known tool schema rejects the request when it is removed. A protocol that cannot express the marker still has it emulated.
- Forward the calling client's identity headers to every OpenAI-family provider, the way ChatGPT Subscription requests already did. A Background Agent Job reaching an upstream through an OpenAI, OpenAI-compatible, or Azure OpenAI provider now presents its real Codex originator, user agent, session, thread, and turn headers instead of arriving anonymous, which is what some upstreams read to decide service level. Headers the caller did not send are still not invented.
- Retry a compaction summary that comes back empty or without the required headings, using the same larger output budget that a truncated summary already gets. One barren summarizer round no longer ends a Background Job at the compaction step. A summary that is still unusable after the retry reports an upstream failure instead of an invalid-request failure, and records the summarizer's response status, stop reason, and token usage so the cause is visible.
- Decide the changelog version increment with two explicit tests in the contributor and agent guidelines: `MINOR` needs a capability that nobody had before, or a break that a person must act on; every other change is a `PATCH`, including a bug fix that users see at once.

## Version 0.73.0 (2026-08-15)

- Group new observability traces by the trusted human for direct-message Turns and by the source channel for group or event Turns instead of by the Agent. Keep the Agent as separate Principal metadata, preserve session identities, and omit the user when no trusted trigger exists. Existing Observability settings remain valid, and historical traces do not change.
- Preserve the same user attribution across Worker tools, AIGateway HTTP and WebSocket generations, Codex Jobs, and image-input fallback calls. The internal cross-runtime carrier now preserves Unicode platform identifiers without breaking model transports, while Worker export authorization continues to use the Agent Principal.
- Keep the Signal Routing list in its original Agent scope after an operator saves or leaves an editor. Opening a routing rule from All Agents no longer adds the rule's owner as a filter and changes the list layout.
- Search the Background Agent Jobs board by an exact Job ID or a name fragment across stored Jobs. The search shares one toolbar with the Agent filter, keeps its value through refresh and browser history, waits for typing to pause before it requests results, and announces the matching count.

## Version 0.72.3 (2026-08-15)

- Preserve the official Codex tool schema, including encrypted collaboration parameters, through Responses-compatible Provider proxies. A permanent Provider request rejection now stops the Background Job instead of consuming Codex retries and returning it to the queue, and reaches every caller under one error code, while transport, authorization, rate-limit, and server failures keep bounded recovery.

## Version 0.72.2 (2026-08-15)

- Preserve `namespace` and tool `name` as separate, validated identities across Provider requests, Tool Search, program execution, trajectories, progress, Background Job history, and deployment recovery. Keep valid Chat Completions and Anthropic wire names unchanged, reject alias collisions, and use only structured V2 fingerprints.
- Keep tools loaded by client Tool Search callable across later turns and local compaction until the caller removes them from the surviving Tool Search output. Compaction budgets every complete retained pair and returns a structured context overflow instead of crashing or storing an oversized checkpoint.
- Apply one `max_tool_calls` budget across provider-owned built-ins and locally implemented Tool Search or program calls instead of rejecting requests that use both owners.
- Recover a retryable model attempt when a Responses-compatible Provider sends an error event before its terminal failure. AIGateway exposes only the canonical terminal, retains bounded Provider diagnostics, and Agent Computer uses explicit retryability or compatible fallback signals for its retry decision.

## Version 0.72.1 (2026-08-14)

- Preserve a streamed Chat Completions tool call's non-empty ID and name when later argument fragments repeat either field as an empty string, so OpenAI-compatible Providers cannot turn an otherwise valid client tool call into a partial completion.

## Version 0.72.0 (2026-08-14)

- Always write compaction summaries with the Agent's light model profile. A conversation that asked for high or extra-high reasoning effort skipped that profile and summarized with the primary model instead, so an Agent whose primary Provider was unreachable could not compact at all and lost the turn. An Agent that configures no light profile now resolves it to its primary profile, the way the coding profile already resolves to heavy.
- Let each Agent decide whether its Provider compacts history, with the new "Use the primary model's native capability, where applicable" switch on the light model profile. This replaces the former instance-wide `ai_gateway.compaction.prefer_upstream` setting. The switch is off by default, and a Provider that has no native compact operation falls back to the light profile, which stays editable because it still writes those summaries. Operator action: an instance that had turned the former global setting on enables the switch for each Agent that needs it; the stored global value is removed on upgrade.
- Recover a stateful conversation when an OpenAI Responses Provider rejects replayed provider-native history before any output. Ankole writes a provider-neutral local checkpoint and retries the current input once. If that retry fails, the next turn still starts from the repaired checkpoint, and dead-letter notices point to `/compress` as the manual recovery path.
- Let the bundled OCR Skill handle an image with no file-name suffix on its first attempt by detecting its media type and passing a temporary copy with the matching supported suffix to the recognizer.
- Let an Agent list, inspect, stop, message, and respawn its Background Jobs from any of its sessions or channels. The Agent owns the Job; its original session and reply route continue to control notification and delivery only.
- Deliver Lark files above the 30 MiB IM limit as cloud-space links instead of exhausting the durable outbox retry budget. Ankole uploads each file in sequential parts, tells the user that the file was uploaded because it is too large, grants the whole chat read access for a group reply or the sender read access for a direct reply, and records structured upload logs and telemetry. Missing cloud-space scope now blocks the first failed delivery instead of uploading the file again. Operator action: grant the Lark application `drive:drive.metadata:readonly`, `drive:file:upload`, `docs:permission.member:create`, and `space:document:delete`, ensure enough cloud-space capacity, then retry any stopped `234006` delivery.

## Version 0.71.2 (2026-08-14)

- Let Skill-backed HTTP MCP declarations pin protocol negotiation, so modern
  POST-only servers do not fall back to the legacy SSE receive channel.

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
