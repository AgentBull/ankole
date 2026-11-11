# Tradeoffs and Known Limits

This document records Ankole's non-obvious trust boundaries, accepted edge-case behaviors, and operational limits. Each subsystem's specification under [`design-docs/`](design-docs/) defines the full runtime protocol.

## Tenants Trust the Site Operator and Shared Site Runtime

Ankole isolates tenant data, Principals, AuthZ grants, physical Base shards, and per-Agent Workers by tenant, while all tenants on a site trust the site operator and share the Elixir control plane, `FunctionRuntime`, model provider pools, and Worker providers (see [Tenants](design-docs/Tenants.md)). Ankole does not provide hostile multi-tenant compute isolation within a single site deployment.

Site administrators can also register a Brain `file` source (`site_console:brain:update`) that reads paths directly on the control-plane host. Choosing which host paths to ingest sits inside the site operator's trusted infrastructure boundary.

## Workers Isolate Control-Plane Credentials and Cross-Chat Mounts, Not an Agent's Own User Space

Inside each Agent's dedicated Worker container, the root supervisor, `ankole-rclone`, and the Bun Worker process run as `uid 0` and hold the Worker channel credential and VFS tokens in root-owned memory. They spawn untrusted child executions—`command`, Codex `app-server`, MCP servers, and `ankole-browser`—as `uid 1000` with `no-new-privs` inside private Linux mount and PID namespaces that bind only the active execution's authorized `/drive/ChatDrive` alongside `/drive/{Public,MyDrive,AgentDrive,Brain,Skills}` (see [Agent Workers](design-docs/AgentWorkers.md) and [Files](design-docs/Files.md)).

Within `uid 1000`, however, Ankole intentionally does not defend a Worker against its own Agent:

- Every Session (`{tenant_id, agent_uid, session_id}`) and Background Agent Job belonging to the same Agent shares `/workspace`—including sibling `/workspace/sessions/*` and `/workspace/jobs/*` directories, `.ankole/turn-skills/`, and `.codex/` state. Use multiple Sessions to organize concurrent tasks, not as an intra-Agent security boundary over `/workspace`.
- An Agent can install user-space tools, modify `/workspace`, or break its own user-space environment. When a Worker fails readiness within `agent_workers.ready_timeout_seconds`, the control plane replaces the container and wipes `/var/cache/ankole` while preserving `/workspace`.
- Compromising a Worker lets an attacker act only as that single Agent, never as another Agent; on Kubernetes, operators who want stronger host kernel isolation can attach a `gVisor` `RuntimeClass` to the Worker Pod template.

## Worker Storage Durability and Single-Writer Fencing

Durability and lifecycle guarantees across cloud Worker providers carry provider-specific limits (see [Provider Verification](design-docs/AgentWorkers.md#provider-verification)):

- **Cloudflare Containers** snapshot `/workspace` to R2 on planned drains and stops, so an abrupt platform kill loses `/workspace` writes made after the latest snapshot.
- **Vercel Sandbox and AWS Lambda + EFS** cover planned replacements, image updates, and brief Lambda memory pauses in live verification; prolonged MicroVM suspension and Lambda memory or burst quotas still require deployment-specific validation.
- **Alibaba Cloud Function Compute** mounts OSS prefixes via `ossfs2` without full POSIX semantics (`chown` fails with `EIO`), whereas NAS provisions an `AgenticSpace` mounted via AgenticFS; **Alibaba Container Compute Service (ACS)** is intentionally unregistered because its default hibernation path has not been proven to preserve process memory. Back up both persistent Worker Home storage and Drive object storage (`ANKOLE_FILES_STORE` plus PostgreSQL) in production.

To prevent split-brain writes to `/workspace`, the control plane waits until every prior Worker instance—including paused or terminating instances—has disappeared before starting a new generation. When a create call returns an ambiguous error, Ankole retries with the same generation token rather than risking two concurrent writers, deliberately leaving the Agent waiting during a cloud-provider API outage instead of double-mounting its Home.

## External Chat Delivery Halts on Ambiguity and Preserves Historical Context

When integrating external messaging platforms, keep four deliberate boundaries in mind (see [Conversations](design-docs/Conversations.md) and [Signals](design-docs/Signals.md)):

1. **Ambiguous sends stop in `unknown` instead of retrying blindly.** Adapters use provider idempotency keys or read-back reconciliation whenever the platform supports them. If a final visible reply times out with an uncertain outcome, Ankole marks the `Delivery` row `unknown` and halts automatic retries to avoid spamming the chat channel; an operator can manually requeue that reply once from Console (flagged with a possible-duplicate notice).
2. **Streaming previews are best-effort.** If a control-plane process crashes mid-stream, partial preview text can remain visible on the chat platform until turn completion, an empty outcome, dead-letter handling, or an explicit stop replaces or clears it.
3. **External edits and withdrawals do not rewrite completed model history.** Unlike native Pod inline message edits—which retract subsequent Agent replies and `AIGateway` `Response` rows—external adapters observe only revisions emitted by the upstream platform: withdrawing an explicit triggering message cancels an in-flight turn, whereas editing or deleting an already-consumed message updates `conversation_messages` in place without rewriting prior `AIGateway` history or triggering a new turn.
4. **WhatsApp enforces a strict customer-service window and asynchronous failure webhooks.** Ankole checks a 23-hour-55-minute window from the user's latest inbound message or interactive reply before sending and does not send paid WhatsApp template messages; delayed answers from Background Agent Jobs or schedules fail permanently (`customer_service_window_closed`) until the user messages again and an operator retries from Console. Because Meta's Cloud API reports downstream delivery failures asynchronously after returning an initial HTTP success and provides neither idempotency keys nor read-back, Ankole logs late failure webhooks for operators rather than resending automatically (see [WhatsApp Adapter](design-docs/plugins/WhatsAppAdapter.md)).

## Steered Turns Split Attribution Across Signals

When addressed follow-up messages, `/steer` commands, priority peer messages, or ambient handoffs steer an already running Session turn, Ankole records each steer as its own `Signal`, so a single turn can span two or more `Signal` rows (see [Sessions](design-docs/Sessions.md)).

When the turn finishes, the latest reply-eligible steered `Signal` claims the public `Message` (`conversation_messages.signal_id` in Pod) or outbound `Delivery` (`deliveries.source_signal_id` on external channels) so the Agent's answer threads underneath the user's newest message, while internal `AIGateway` `Response` and `ai_gateway_usage_records` rows stay linked to the opening `Signal` that started the turn. Querying either `Signal` in isolation shows only part of the turn; join through `ai_message_id` to trace a public reply back to its model output.

## AIGateway Compaction, Wire Emulation, and Accounting Constraints

Several `AIGateway` behaviors depend on upstream protocol capabilities or caller mode (see [AIGateway](design-docs/AIGateway.md) and [Agent Token Quota](design-docs/AgentTokenQuota.md)):

- **Provider-native compaction (`ai_gateway.compaction.upstream`) locks stateless threads to Responses wires.** Stateful (`store=true`) conversations keep raw predecessor rows in PostgreSQL, so switching providers or falling back from a failed upstream compaction cleanly rebuilds a local summary checkpoint. Stateless (`store=false`) callers such as Codex Jobs, however, carry opaque provider compaction tokens directly in their thread items; replaying those items requires a Responses-wire upstream and fails with `unsupported_compaction_replay_wire` on other protocols.
- **`encrypted` tool-property markers preserve schema shape without cryptographic secrecy outside Responses.** On Responses wires, `AIGateway` forwards `encrypted: true` on top-level string tool properties verbatim so providers that validate pre-registered schemas accept the call (whereas a Responses provider that rejects unknown schema markers will reject the request). On non-Responses wires, `AIGateway` round-trips values as versioned `Base64URL` tokens to preserve protocol shape without providing confidentiality.
- **Interrupted streams are discarded rather than spliced.** `AIGateway` rejects `background=true` and never resumes half-streamed upstream chunks after a disconnect; background reconciliation marks orphaned `Response` rows failed once their heartbeat grace window expires.
- **Missing provider usage bypasses token quota enforcement for that round.** When an upstream provider omits token usage, `AIGateway` records `NULL` rather than estimating tokens from character counts, so calls on providers that omit usage can exceed an Agent's token quota until usage is reported.
- **Tool ceilings and pool counters measure narrow scopes.** `Response` `max_tool_calls` caps only built-in hosted tools (`Tool Search`, `Programmatic Tool Calling`, `Brain`, `web_search`, and `image_generation`), leaving client tools to the Session Driver's round ceiling. Likewise, `CredentialPool` `request_count` counts every successful credential selection—including cached `ModelMetadata` lookups and affinity hits—rather than outbound HTTP requests alone.

## Human Offboarding Sync Coverage and In-Flight Runs

Automatic departure webhooks and periodic directory syncs are implemented only for Feishu/Lark and DingTalk (with automatic missing-member disablement gated on initial baseline approval and a 20% removal circuit breaker); Google Workspace, Microsoft 365, Slack, and generic OIDC rely on manual disablement in Console (see [Human Offboarding](design-docs/HumanOffboarding.md)).

When Ankole suspends or offboards a Human, any execution attempt that already passed admission finishes its current run rather than aborting mid-tool-call; revocation blocks subsequent turns, retries, scheduled wakeups, and sign-ins.

## Dynamic Skill Edits and Ephemeral Local Browser Profiles in Jobs

Two Worker runtime behaviors intentionally favor fresh state over pinned snapshots (see [BackgroundAgentJob](design-docs/BackgroundAgentJob.md) and [Web Tools](design-docs/WebTools.md)):

- **Background Agent Jobs freeze Skill names, not Skill file bytes.** At first admission, a Job freezes its candidate Skill names and intersects them with current enablement so disabling a Skill revokes it mid-Job, while edits to a still-enabled Skill's content take effect on subsequent reads and turns.
- **Local Chromium profiles live in ephemeral `/tmp`.** Even though a Codex Job persists its route metadata and `browser/` screenshots and downloads under `/workspace/jobs/job-<id>`, `ankole-browserd` stores local Chromium profile directories (`cookies` and `localStorage`) under `/tmp/ankole-agent-computer/browser/routes/<route>`. Context idle expiry or Worker container replacement clears local browser login state unless the route uses a remote CDP browser backend.

## Pod Documents Embed External Pages Without Confirmation

A Pod document stores the `href` of an `embed` and the `src` of an image verbatim. When a user pastes Markdown or HTML containing an `<embed href>` or `<iframe src>` snippet, the editor creates an external preview iframe without prompting first, and an image `src` may contain any URI scheme, including `javascript:` (see [Pod Content Model](design-docs/PodContentModel.md)).

Ankole accepts this because neither case executes author-controlled script with the Pod's authority:

- A same-origin embed loads inside a sandbox that omits `allow-same-origin`, isolating it in an opaque origin, while a cross-origin embed stays isolated under the browser's same-origin policy (and if it redirects back to the Pod's origin, the frame renders only what the Pod serves there). Published Applet frames share the Pod's origin because they already run inside the Pod's trust boundary.
- Every Pod file response sets `Content-Security-Policy: sandbox; default-src 'none'` and `X-Content-Type-Options: nosniff`, serving HTML and non-allowlisted MIME types as `attachment` downloads, and browsers never execute `javascript:` URIs on `<img>` elements.
- Inline text styles in both the editor and the Rust kernel retain only `color`, `background-color`, and `text-transform` so arbitrary CSS (such as `position: fixed` overlays) cannot spoof or cover the surrounding page. Because a pasted embed can still display an unprompted external page (such as a phishing form), readers should treat embeds with the same caution as external links.

## Concurrent Cross-Column Deletions Can Leave an Empty Column

When a range edit starts in one column and ends in another, the editor joins the text at both ends while closing the first column and reopening the second so the remaining blocks in each column stay in place. Operational transformation preserves that inserted column boundary even if a concurrent collaborator deletes the surrounding text at the same time.

Consequently, when two collaborators concurrently delete adjacent ranges across the same column boundary, the converged page can contain an extra column holding a single empty paragraph; no text is lost, undoing either edit restores the prior layout, and deleting the empty column cleans it up. Ankole accepts this rare outcome because automatic cleanup cannot distinguish that column from an empty column inserted intentionally by a user.

## Database Connections Trust the Database Role

Ankole authorizes an external database connection as a unit: any Principal granted query access on the connection can run every read-only statement permitted to that connection's database role (see [Database Connectors](design-docs/plugins/DatabaseConnectors.md)). Ankole does not layer row- or column-level filtering onto `query` results—sensitive-value withholding applies only to catalog samples and `probe_values`—so administrators must scope each audience to a least-privileged database role, view, or row-level security policy.

Read-only session settings, `sql_inspect`, and query time/size budgets block writes, runaway reads, and known side-effecting built-in functions, yet they cannot detect side effects inside user-defined or extension functions callable by the database role. In addition, PostgreSQL and MySQL sessions connect directly over TCP from the control plane; the HTTP egress proxy applies only to ClickHouse, which speaks HTTP.

## Deliberate Non-Goals

Ankole intentionally does **not** provide:

- Admission for untrusted third-party Workers
- End-user authoring of external IM/channel or Console-level Signal routing rules (Pod members configure Applet Jobs, schedules, webhooks, and `/api/v2/pod/signal-bindings` triggers inside each Applet's settings)
- Nested Workflows, hot-swapping Workflow scripts mid-run, or dedicated per-Workflow token budgets (Workflow task turns draw from the Agent's shared [Agent Token Quota](design-docs/AgentTokenQuota.md))
- A public OpenAI-compatible `Conversations` CRUD API, or `Response` delete/cancel HTTP endpoints on `AIGateway`
- Named git-style branch refs over the `AIGateway` message graph
