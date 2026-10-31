# Tradeoffs and Known Limits

This document sets out Ankole's deliberate architectural boundaries, trust assumptions, and failure-recovery limits. Each subsystem's design document covers the underlying protocol in full detail.

## A Worker Is One Agent's Dedicated Computer

Each Agent gets its own dedicated Worker instance—Agents never share a Worker container, persistent Home volume, cache disk, or Worker credential. Inside that container, the container boundary itself is the sole security boundary: shell commands, the Codex app-server, Automation scripts, and the headless browser all run as `uid 1000` without `sudo` or an inner nested sandbox.

Ankole does not try to defend a Worker against its own Agent. Within user space, an Agent can install local tools, modify `/workspace`, or even break its own user-space environment (though it cannot install root system packages). That is intentional: the Worker's runtime credential represents only that single Agent, whose shell commands already have access to all of that Agent's files and scoped tokens. If a Worker fails to become ready within `agent_workers.ready_timeout_seconds`, the control plane replaces it with a fresh container and a clean cache disk.

Treat Worker containers as first-party, single-Agent compute; on Kubernetes, operators who want stronger host isolation can attach a `gVisor` `RuntimeClass` to the Worker Pod template. Compromising a Worker lets an attacker act as that one Agent, never as another Agent. By contrast, the control plane holds the Docker socket or Kubernetes namespace Role used to launch Workers, so protect the control plane as root-equivalent infrastructure.

## Persistent Home vs. Rebuildable Cache

An Agent's Home directory (`/workspace`) persists across Worker restarts, instance replacements, and container image updates—backed by a local Docker volume, Kubernetes PVC, Cloudflare R2 snapshot, Vercel Drive, AWS EFS directory, AgenticSpace volume, or Alibaba Cloud OSS prefix depending on the Worker provider. Persistent Codex thread files live under `/workspace/.codex`, whereas Codex SQLite databases and process locks live on a disposable cache disk at `/var/cache/ankole`. Rebuilding a Worker wipes `/var/cache/ankole` once the old container terminates while leaving `/workspace` intact.

Actual storage durability depends on the underlying provider:
- **Docker local volumes and `local-path` PVCs** do not survive losing the underlying host disk.
- **Cloudflare Containers** snapshot `/workspace` to R2 on planned stops, so an abrupt platform kill can lose writes made since the last snapshot.
- **Vercel Sandbox and AWS Lambda + EFS** cover planned replacements, image updates, and brief Lambda memory pauses in live-account verification, though behavior across prolonged MicroVM suspension and Lambda memory quotas still warrants deployment-specific checks.
- **Alibaba Cloud Function Compute + OSS** mounts object storage without full POSIX filesystem semantics, and **ACS** remains disabled until its default hibernation path is proven to preserve process memory. See [Provider Verification](design-docs/AgentWorkers.md#provider-verification) and [Agent Workers](design-docs/AgentWorkers.md) for full provider verification matrices, and back up both persistent Home storage and the control-plane Drive in production.

To prevent split-brain writes to `/workspace`, the control plane waits until every prior Worker instance—including paused or terminating ones—has completely disappeared before starting a new generation. If a create call returns an ambiguous error, Ankole reuses the same generation token on retry rather than risking two concurrent writers, which means a cloud-provider API outage will leave the Agent safely waiting rather than double-mounting its Home.

## Sessions Isolate Active Tasks, Not Agent-Owned Files

Each Session runs under the Actor identity `{agent_uid, session_id}` inside `/workspace/sessions/<workspace-id>` (where PostgreSQL allocates stable workspace IDs starting from `10000`).

While separate Sessions get distinct working directories, foreground child processes, and scratch files, every Session belonging to the same Agent shares one Worker container and has full filesystem visibility across `/workspace`—including shared Home files, `installed-skills/`, sibling Session workspaces, and `.codex/` state. Use multiple Sessions to keep concurrent tasks organized, not as a security boundary within a single Agent.

## RuntimeFabric Is Transport, Not a Queue

`RuntimeFabric` multiplexes live control messages, RPC calls, health heartbeats, and flow control over one Phoenix Channel per Worker, while streaming file payloads over one-time HTTP relay URLs.

That WebSocket channel is purely ephemeral transport. Any state that must survive a disconnect, trigger a retry, or commit business results is written to PostgreSQL first.

## Only the Control Plane Commits Durable Business State

Workers never write directly to AIGateway tables, `Signals`, or provider Delivery outboxes. Even within the control plane, responsibilities stay strictly separated:

- **AIGateway** persists individual model `Response` rows and streams token events, but never marks a `Signal` finished or dispatches external chat replies.
- **Session Drivers** orchestrate the main model loop in the control plane. Only the Driver's closing PostgreSQL transaction—guarded by the persisted Driver epoch fence—marks `Signals` complete and enqueues external `Delivery` intents. If a Driver crashes after a model `Response` finishes, the next Driver reconstructs the turn from the committed input rows and `Response` tape.
- **BackgroundAgentJobs** execute Codex turns on the Worker, and the control plane verifies the Job's attempt fence before committing the Worker's final report.

## External Provider Delivery Is At-Least-Once

In Ankole's messaging pipeline, `Conversations` observes incoming platform events and dispatches outbound `Delivery` intents, `Signals` authorizes and routes triggers, and `Sessions` runs the Agent and records the intended reply.

Keep three delivery realities in mind when integrating external chat platforms:

1. **Webhook acknowledgements mean intake, not reply.** Returning `200 OK` to Slack, Feishu, or DingTalk confirms only that Ankole recorded the inbound event, not that an Agent has finished answering.
2. **Streaming previews are best-effort.** If a process crashes mid-stream, stale preview text can linger on the external chat platform until turn completion, an empty result, dead-letter handling, or an explicit stop clears or replaces it. Final external replies always come from durable `Delivery` intents, while native Pod replies commit directly as public `Message` rows.
3. **Uncertain network calls stop safely rather than looping forever.** Adapters use provider idempotency keys or read-back reconciliation whenever the platform supports them. If a final visible reply times out with an ambiguous outcome, Ankole marks the Delivery row `unknown` and halts automatic retries so it does not spam the chat channel; an operator can manually requeue that reply once from Console (tagged with a possible-duplicate notice). Other ambiguous operations stay stopped, automatic retries halt at their configured ceiling, and expired intents are never sent.

## Steered Turns Split Records Across Two Signals

When a user sends a `/steer` follow-up while a Session Turn is already running, Ankole records that follow-up as its own `Signal`. When the Turn finishes, the latest applied `/steer` claims ownership of the final reply and its outbound `Delivery` row so the Agent's answer threads underneath the user's newest message rather than the older message that originally started the Turn.

At the same time, the internal `AIGateway` message remains linked to the opening `Signal` that spawned the Turn. As a result, a steered Turn spans two `Signal` rows: querying either `Signal` in isolation shows only half the picture. To trace a reply back to the exact model output that produced it, start from the outbound `Delivery` row and follow `ai_message_id` to `AIGateway`. Ankole accepts this split deliberately so replies appear where human readers are actually looking in chat.

## Message Edits and File Transfers Follow Provider Capabilities

`Conversations` tracks edits and deletions on observed external messages and forwards those revisions to `Sessions`. However, an adapter can record a deletion or edit only when the upstream platform actually emits an event for it, and deleting an earlier chat message does not retroactively rewrite prior `AIGateway` model history—instead, a subsequent turn sees the removal notice as a new event.

Similarly, outbound file delivery reads each Drive file as its bytes exist at send time rather than snapshotting historical byte versions, and adapters explicitly reject files or operations that exceed the target platform's size or API limits rather than silently dropping them.

## WhatsApp Enforces a 24-Hour Reply Window

Meta closes a WhatsApp customer-service window 24 hours after the user's most recent inbound message. Ankole checks that timestamp before every send: if the 24-hour window has expired, the adapter fails the `Delivery` row permanently without calling Meta's Cloud API, which means delayed answers from background jobs or scheduled tasks will not go through until the user messages again (unless re-opened externally via paid WhatsApp template messages, which sit outside Ankole's adapter scope). Once the user writes again, an operator can retry the stopped `Delivery` row from Console.

Meta's Cloud API also reports downstream delivery failures asynchronously *after* returning an initial send success. Because WhatsApp offers neither idempotency keys nor message read-back, Ankole logs late asynchronous failure webhooks for operator visibility rather than automatically re-sending, and marks ambiguous HTTP timeouts as `unknown` under the standard manual-requeue flow.

## Stateful AIGateway Responses Require WebSockets

AIGateway's HTTP `POST /v1/responses` endpoint is strictly stateless and rejects stateful continuation fields; callers that maintain server-side conversation state connect over the WebSocket Responses endpoint instead.

Key invariants of stateful AIGateway sessions:
- **Single active leaf per implicit continuation**: AIGateway tracks conversation structure directly in the message graph rather than maintaining a separate mutable cursor. Starting an implicit continuation runs a short transaction that locks the current visible leaf, inserts the new `Response` (plus a compaction checkpoint if needed), and rejects concurrent implicit callers with `response_in_progress`. Callers can still branch explicitly from any earlier turn by passing `previous_response_id`.
- **No mid-stream provider resumption**: One WebSocket connection generates at most one `Response` at a time (`background=true` is rejected), and Session Drivers serialize model calls per Session. If a connection drops mid-generation, AIGateway does not splice half-streamed upstream chunks; a background cleanup worker marks abandoned `Response` rows as failed once the grace period expires.
- **Exact usage accounting and strict Principal scoping**: Automatic context compaction relies on persisted provider token usage rather than estimating tokens from character counts. Every AIGateway query scopes conversations, messages, artifacts, and compaction checkpoints to the authenticated Principal, and AIGateway treats caller `metadata` (such as `signal_id`) as opaque pass-through data.
- **Two distinct call ceilings**: `max_tool_calls` caps hosted tool invocations *within* a single `Response`, whereas the Session Driver's iteration limit caps total model rounds across an entire Session run.

## Context Compaction Trusts Two Unverifiable Upstream Declarations

AIGateway exposes context compaction through a single uniform protocol: a request containing a `compaction_trigger` input item, which AIGateway handles across every transport without forwarding raw trigger items to upstream providers. Within that protocol, however, two behaviors depend on configuration or caller declarations that AIGateway cannot verify ahead of time:

1. **Provider-native compaction (`ai_gateway.compaction.upstream`)**: When enabled, AIGateway delegates compaction to the upstream model provider instead of generating a local summary. While a conversation contains no provider-specific compaction state, AIGateway validates the upstream reply and falls back to local summarization if the provider returns an unexpected shape. Once the conversation stores an opaque provider compaction token, however, **only that same upstream provider can compact future turns**—local summarization can no longer read the opaque state. Because that lock-in outlives a single turn, `upstream` defaults to `false` and must be opted into at the instance level.
2. **`encrypted` tool-parameter markers**: Clients declare `encrypted` once for an entire tool schema before any parameter value exists, and Responses wire transports forward that marker verbatim. Because nothing in the request tells AIGateway whether the upstream provider expects or rejects the marker, AIGateway forwards it unchanged: providers that validate against pre-registered tool schemas reject requests if the marker is stripped (a failure observed in production), whereas a hypothetical Responses provider that rejects unknown markers would fail the request rather than silently falling back. On non-Responses wire protocols that cannot represent the marker natively, AIGateway emulates round-tripping with opaque encoded tokens—preserving protocol shape without providing cryptographic secrecy.

## Provider Credentials Stay in the Control Plane

The control plane holds all master provider configurations and encrypted API keys, issuing a Worker only narrowly scoped credentials when an enabled Worker capability requires one. For example, Codex Jobs authenticate back to `AIGateway` using an Agent-scoped key that `AgentCodexRuntime` writes to a private token file inside `.codex/` and refreshes automatically, while the primary Agent loop never leaves the control plane. See [Background Agent Job](design-docs/BackgroundAgentJob.md).

Never place live API keys or secrets inside Agent workspace files, Skill parameters, progress messages, model prompts, or logs. Also note that `RuntimeFabric` assumes a private cluster network with trusted first-party Workers; do not expose Worker channel endpoints directly to untrusted public networks.

## Human Offboarding Stops at Ankole's Boundary

Disabling a Human Principal immediately blocks new logins and rejects newly arriving work attributed to that Human inside Ankole. Automatic departure detection relies on upstream identity-provider webhooks and periodic directory syncs—so if an upstream IdP has an outage or restricted API scope, operators can always disable the account manually in Console.

Once offboarding triggers, three boundary rules apply:
- **In-flight attempts finish their current run**: If a task passed its admission check before the Human was disabled, Ankole lets that attempt finish rather than aborting mid-tool-call.
- **OIDC Relying Parties enforce logout asynchronously**: Ankole sends OIDC Back-Channel Logout notifications and reflects revocation immediately on Token Introspection, but each external Client clears its own local session cache on its own schedule.
- **External tokens outside Ankole keep their own lifetimes**: Ankole cannot revoke credentials it did not issue—such as an external RP's cached session cookie, an OAuth grant held directly by a third-party app, or a Lark CLI profile already selected by an in-flight Worker attempt—until those tokens expire at their issuer. See [Human Offboarding](design-docs/HumanOffboarding.md), [Browser Sessions](design-docs/BrowserSessions.md), and [OIDC Server](design-docs/OIDCServer.md).

## Headless Browser State Lives and Dies with the Worker

`ankole-browser` runs alongside Agent Computer inside the Worker container. Agent Computer assigns each browser consumer an opaque route with pre-resolved proxy/connection settings, so the Chromium daemon never communicates with the control plane directly.

Each Worker supervises one browser daemon, isolating separate routes into distinct local Chromium profiles or remote browser sessions. Rendered `web_fetch` calls allocate ephemeral one-off routes, whereas Codex Jobs can hold onto a named route across turns to preserve cookies and login state. Because browser profiles, screenshots, and temporary downloads live on the Worker filesystem, replacing a Worker wipes local browser state unless the deployment mounts persistent storage for the browser data directory.

## Long-Running Execution Belongs in BackgroundAgentJob

Models can invoke only explicitly registered Ankole tools—merely installing a CLI binary inside the Worker image does not expose it to the model as a callable tool.

For shell execution, Ankole separates short interactive commands from long-running jobs:
- **Foreground `command` tool**: Runs synchronously with a 180-second default timeout (configurable per call) and deliberately provides no background daemon registry.
- **`BackgroundAgentJob`**: Runs open-ended multi-turn work through `CodexRunner` on the Worker while the control plane tracks durable Job state, heartbeats turn leases to detect stalled Workers, retries transient failures, handles cancellation, and posts completion updates back to the originating Conversation. Workflows that require a wall-clock deadline can steer or cancel a Job explicitly.

Every Job turn resolves the latest enabled built-in Skills, Agent Plugin Skills, and Drive-installed Skills at run time rather than pinning old Skill bytes, and Skill discovery operates independently of Control Plane Plugins. When an Agent invokes an MCP-backed Skill, `mcporter` runs in the foreground with an explicit per-call timeout rather than spawning background daemons.

## Durable Timers and Wakeups Run Through Oban

Whenever a domain operation sets a deadline or schedules follow-up work, it writes the authoritative domain state to PostgreSQL and enqueues an `Oban` job inside the **same database transaction**. When `Oban` fires, the owning module re-reads the PostgreSQL row to verify the work is still needed before acting, and a periodic Reconciler sweeps for any missed Conversation or Workflow wakeups. In-memory Driver progress is always rebuildable from committed input rows and the `AIGateway` Response chain.

## Phoenix and Vite Own Distinct Layers

Phoenix serves HTTP routes, authentication ceremonies, cookie sessions, initial setup, and the outer HTML shell, while Vite compiles the client-side React applications under `app/webapps/` using shared components from `libs/uikit`. TypeScript API clients are generated from control-plane OpenAPI schemas—always update the Elixir resource/schema first and regenerate the client rather than hand-patching frontend types.

## Fast Unit Suites Do Not Prove Live Infrastructure

Default `bun run test` suites skip container builds, live external chat/LLM providers, performance benchmarks, and chaos fault-injection runs. Before claiming that a Worker image, cloud provider, database failover, or external integration works end to end, run the corresponding `tools/e2e/run` mode; static code review catches contract mismatches, not live protocol or network behavior.

## Pod Documents Embed External Pages Without Confirmation

A Pod document stores the `href` of an `embed` and the `src` of an image as written. When a person pastes Markdown or HTML that contains an `<embed href>` element, the editor creates an external iframe without asking first, and an image address can use any scheme, including `javascript:`.

Ankole accepts this because neither case runs author-controlled script with the Pod's authority. An embed whose address is on the Pod's own origin loads in a sandbox without `allow-same-origin`, so it runs in an opaque origin. An external page keeps its own origin, so the browser's same-origin policy keeps it away from Pod data. When an external page redirects the frame to the Pod's origin, the frame shows only what the Pod serves at that address. Every Pod file response carries `Content-Security-Policy: sandbox; default-src 'none'` and `X-Content-Type-Options: nosniff`, and HTML files download as attachments instead of rendering. An Applet frame page runs with the Pod's origin, but it is a published Applet that already shares the Pod's trust boundary. A browser never runs a `javascript:` address from an `img` element. A pasted embed can still show a page that a reader did not choose to open, such as a fake sign-in form. Readers and editors should treat an embed like a link from its author. Text styles are different: the editor and the Rust kernel keep only `color`, `background-color`, and `text-transform`, because other CSS, such as a `position: fixed` overlay, would cover the page for every reader.

## Concurrent Cross-Column Deletions Can Leave an Empty Column

When a range edit ends in another column, the editor joins the text at both ends and keeps each column's other blocks. To keep the second column, the change closes the first column after the joined text and opens the second column again. Operational transformation keeps that inserted column boundary even when another collaborator deletes the text around it at the same time.

So when two people delete adjacent ranges across the same column boundary concurrently, the converged page can hold an extra column with only an empty paragraph, and undoing one of the edits restores that layout. No text is lost, and deleting the empty column restores the intended layout. Ankole accepts this rare outcome: removing it needs a different change shape for cross-column edits or special handling in transformation, while an automatic cleanup cannot tell such a column from an empty column that a person inserted on purpose.

## Deliberate Non-Goals

Today, Ankole intentionally does **not** provide:

- Public network admission for untrusted third-party Workers
- A durable message broker inside `RuntimeFabric`
- Automatic scraping of durable business records out of arbitrary Worker files
- End-user (non-operator) authoring of Signal routing rules
- Nested Workflows, hot-swapping Workflow scripts mid-run, or shared token budgets across a Workflow batch
- A public OpenAI-compatible `Conversations` CRUD API, or `Response` delete/cancel endpoints
- Named git-style branch views over the `AIGateway` message graph
- Hostile multi-tenant compute isolation inside a single Ankole deployment

Any product decision to add one of these capabilities must designate a single owning module, specify the migration path for existing data, and define end-to-end verification coverage.
