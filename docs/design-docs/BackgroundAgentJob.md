# Background Agent Job

A BackgroundAgentJob records work that continues after the Agent turn that
started it. PostgreSQL stores the request, current state, and final result, and
CodexRunner executes every Job.

Agent Plugins and standalone Skills give a Job extra tools or instructions
without introducing separate Job types.

## What the Operator Console Can Do

The Console Job board lists the newest matching Jobs in the selected tenant,
combining its optional Agent filter and search query. The server evaluates the
search filter (matching either an exact Job ID or a case-insensitive title
substring) before applying the 100-row page limit so newer unrelated Jobs never
hide an older match. Under the hood, the board calls the `console_list` read
action on the Job resource over JSON:API (`GET /api/v2/background-agent-jobs`
with `agent_uid`, `status`, and `search`), ordered by queue timestamp and then
Job ID with keyset pagination (`page[limit]` and `page[after]`), loading only
board columns plus the calculated `duration_seconds`. Each opaque pagination
cursor encodes a format version, the query parameters it belongs to, and the
last row's keyset so the server rejects cursors from another query or an older
format; the `list_background_jobs` model tool calls `list_for_agent` using the
same cursor contract.

`GET /api/v2/background-agent-jobs/:id` returns the single Job detail record.
The generic actions `console_cancel` and `console_complete`
(`POST .../:id/cancel` and `POST .../:id/complete`) record the Console Principal
(the Ash actor) as the operator and stop any live Turn after the transaction
commits. Targeting a nonexistent Job returns HTTP 404, and attempting to
complete an already `failed` or `stopped` Job returns HTTP 409
(`background_agent_job_terminal`).

The Job detail page also displays the runtime Turn trajectory in bounded pages
through `GET /api/v2/background-agent-jobs/:job_id/turns`, a typed read model of
Turns and their projected items. Page one starts with the newest Turns and walks
backward into older history, packing up to 20 semantic item groups within 24 KiB
per page. Even if a Turn recorded zero readable items, it still appears on its
page with its status and error.

## What the Main Agent Can Do

Each model-facing tool performs exactly one BackgroundAgentJob operation rather
than multiplexing operations through an `action` field.

### `list_background_jobs`

`list_background_jobs` is a read-only tool that accepts two optional arguments:

- `status`: `live` (`queued`, `running`, and `waiting_on_user`) or `stop`
  (`succeeded`, `failed`, and `stopped`); defaults to `live`.
- `page`: the turn-local `page_N` cursor returned by the preceding page.

The calling Agent owns the entire Job list: `owner_session_id` and `reply_route`
select notification and delivery targets rather than restricting Job visibility
to the session or channel that started the Job. Each call returns up to 32 Jobs
ordered by `updated_at` descending and then `id` descending, projecting only
`job_id`, `title`, and the concrete Job `status`, plus `next_page` (`null` when
no older Job remains).

### `show_background_job_details`

`show_background_job_details` is a read-only tool accepting `job_id` and an
optional UTF-8 byte `result_offset`.

When `result_offset` is omitted, the tool returns an execution snapshot:
`title`, concrete `status`, terminal `result_ref` (when present), attempt
counts, compact attempt history, current Turn status, thread and Turn counts
(grouped by runtime thread ownership without exposing the stored Turn `kind`),
aggregate progress, latest token usage, execution `updated_at`, current error
summary, and `recent_trajectory`.

The error projection exposes only `code`, `summary`, `retryable`, and
`codex_turn_status`, reading the Job error first and falling back to the current
attempt's Turn error (using a stored Codex `message` when `summary` is absent;
compact attempt history uses that same fallback for failed Turns even when no
tool ran or assistant text appeared). System failure diagnostics scrub
UUID-shaped substrings to `[internal-id]` without altering successful outputs or
assistant prose. Aggregate progress also preserves `tool_execution_mechanisms`
for calls with a meaningful execution boundary (`namespace` when present, leaf
`name`, `provider_hosted` or `local_dynamic`, and call count) so the parent
Agent never has to guess execution boundaries from truncated trajectory pages.

`recent_trajectory` projects an `ankole_chatml` slice from the latest three
semantic item groups on the Job's root thread (across all stored Turn kinds),
stripping database message IDs, rewriting tool-call IDs to turn-local `call_N`
aliases, omitting pagination cursors, and preserving `metadata.redacted` and
`metadata.content_truncated` (set by control-plane projection only when message
bodies must be trimmed to fit byte caps, never merely because three groups were
selected).

When `result_offset` is supplied (starting at `0`), the tool accepts only a
`succeeded` Job with a persisted `output_text`. It returns `title`, `status`,
`result_ref`, `workspace_owner_job_id`, `project_path`, `artifacts`,
`artifact_roots`, and one UTF-8-safe `result` chunk (`{offset, output_text,
next_offset}`):

- Path metadata repeats on every chunk so later Turns or other sessions can
  locate real Job files (including an inherited continuation Workspace) without
  deriving filesystem paths from `job_id`.
- Path fields are capped at 2,000 bytes per chunk: `project_path` is always
  kept, `artifact_roots` are trimmed first and then trailing `artifacts`
  (preserving `total_count` and setting `truncated: true`), guaranteeing room
  for `output_text` to advance.
- Each serialized tool response stays within 8,000 UTF-8 bytes (safely inside
  the 10,000-token limit on model-visible tool output after JSON escaping).
  Concatenating chunks in order reproduces the immutable final response byte for
  byte without transferring the full text across the control plane or altering
  the bounded completion notification.

### `create_background_job`

`create_background_job` creates one durable Job from up to four fields:

- `title`: required management and UI label (never sent to Codex).
- `task`: required prompt text passed verbatim as the initial Codex user
  message.
- `model_profile`: optional custom model profile from the Agent's `TurnStart`
  catalog (omitted from the schema when the catalog is empty; defaults to
  `coding` when omitted, and never accepts fixed profile names, raw model IDs,
  provider IDs, or reasoning-effort overrides).
- `workspace_template_id`: optional enabled workspace template materialized
  only when Agent Computer first creates the Job Workspace.

The tool description instructs the main Agent to omit `model_profile` unless the
human explicitly requests a named custom profile (whose description must state
its purpose), and explains the Job capability boundary: because a Job can
neither spawn another Background Agent Job nor load a `main`-only Skill, the
main Agent executes `main` Skill orchestration steps itself and creates every
needed Job with its concrete task brief. Creation returns only `{job_id, status:
"queued"}`.

### `send_message_to_background_job`

`send_message_to_background_job` sends one message to any live Job (`queued`,
`running`, or `waiting_on_user`; terminal Jobs are rejected):

- `job_id`: target Job ID.
- `message`: text sent to Codex.
- `wait_reply`: whether to observe the receiving Codex Turn in the foreground
  (defaults to `true`).
- `wait_timeout_ms`: foreground observation window when `wait_reply=true`
  (default `30,000`, minimum `10,000`, maximum `150,000`).

On a `queued` Job, the message queues behind the initial dispatch in Signal
order; on a `running` Job, it steers the active Codex Turn; and on a
`waiting_on_user` Job, it answers the pending prompt and resumes the Codex
thread.

When `wait_reply=false`, the tool returns `job_id` and the current status as
soon as the message commits. When `wait_reply=true`, the tool watches that
specific Codex Turn until its result settles, a new parent steer arrives, the
parent Turn is canceled, or `wait_timeout_ms` elapses (ending only foreground
observation without retracting, resending, or stopping the Job):

- If the Turn settles in time, the tool returns `job_id`, concrete `status`,
  `last_turn_trajectory` (up to 20 latest semantic item groups within 24 KiB,
  flagging `earlier_trajectory_omitted`, preserving `metadata.redacted` and
  `metadata.content_truncated`, and noting when the Job continues running),
  `continues_running`, `reply_ready=true`, and `wait_outcome=reply_ready`.
- If a parent steer or timeout interrupts the wait, the tool returns
  `reply_ready=false`, `wait_outcome=timed_out|steered`, current `status`, and
  `continues_running`, journaling that tool result before injecting queued
  parent steering into the next model round.

An ambient channel route can append the same `command.steer` Signal without a
model tool call when targeting a single live Job belonging to the same Agent,
owner Session, signal channel, and binding: in one transaction, the control
plane re-verifies those invariants and the ambient scene, appends the steer
containing only the new channel messages (excluding prior context, private
Brain memory, and recognizer rationale), records the canonical ambient judgment,
and advances the channel cursor.

### `respawn_background_job` and `stop_background_job`

`respawn_background_job` continues a terminal Job (`succeeded`, `failed`, or
`stopped`) as a new Job from two inputs (`source_job_id` and `message`):

- The source Job stays terminal while the new Job copies its title, resumes the
  exact Codex thread in the original Job Workspace (or falls back to the
  replacement-thread ladder under Turn recovery if native thread files are
  gone), binds to the current authorized turn, and uses currently enabled Agent
  Plugins, Skills, and runtime configuration, returning `{job_id, status:
  "queued"}`.
- The tool rejects any source Job that is still live, lacks a `runtime_thread_id`,
  already has a successor, or has lost its original Workspace on both the Worker
  and the drive (never copying a Workspace or creating a fresh directory).

`stop_background_job` takes only `job_id` (an operator stop reason is supported
only in the Console, not on the model tool), transitions any `queued`,
`running`, or `waiting_on_user` Job to `stopped` (acting as an idempotent no-op
on terminal Jobs), and returns `{job_id, status}`.

### Completion, Ownership, and Notifications

Before marking a Job `succeeded`, Agent Computer waits until every active Turn
in the routed root-and-child thread tree reaches a terminal state. Whenever a
Job transitions to `succeeded`, `failed`, or `stopped`, the same transaction
marks any remaining active Turn in the current attempt `interrupted` while
leaving completed lead and child Turns intact so their trajectories are
preserved.

Every Job creation path pins its originating conversation up front: using the
Agent, tool call, and reply route from the authorized parent turn (whose real
Agent Home paths the task may reference), creation resolves or creates the owner
Session's active AIGateway conversation and writes its ID to
`metadata.owner_conversation_id`. The Job runtime resolves conversation context
from that metadata field, allowing control-plane-created Jobs and automatic
steer-seeded successors to resolve their conversation without a live calling
turn.

When the originating Conversation is a Pod room, the control plane derives the
source Page ID and Pod delivery instructions from the Conversation owner and
passes them into the Job's developer instructions on both initial runs and
resumes (defaulting research reports to editable Pod Pages while honoring
explicit file-format requests and external channel rules).

Workflow task turns can also spawn Jobs: the Job records `wf_task:<call_id>` as
`owner_session_id` so `succeeded`, `failed`, and `waiting_on_user` wakeups
resume the sleeping Workflow task rather than the main Agent's chat session, and
when a Workflow run terminates, cleanup stops any live Jobs that its task
sessions own (see [Workflow](Workflow.md)). Meanwhile, turn-local webhook and
automation CLIs invoked inside a Job use `Conversations.Route` to walk the
persisted Job and Workflow owner chain back to the originating long-lived Agent
Session so long-lived callbacks never target an ephemeral Job or task (without
altering Job lifecycle wakeups, the calling Signal, or its `WorkAccess`
authority; if the owner chain is missing or inconsistent, creation fails before
persisting any resource).

When a cron turn creates a Job, the Job's `reply_route` snapshots that cron
fire's delivery targets. Terminal notifications retain that snapshot: the parent
Agent handles the wakeup once, and `Sessions.Presentation` commits one native
Message or external Delivery intent per snapshotted target from its final reply
(ordinary turns use a single-target route).

Reaching `succeeded` (carrying the final Codex answer), `failed`, or
`waiting_on_user` writes a wakeup notification for the originating conversation
(and a terminal Job wakeup always produces a visible parent reply), whereas
stopping a Job sends no notification. Internal Brain Skill-reflection Jobs use
an empty `reply_route` and an Agent-owned execution Session, queuing lesson
application inside the terminal commit transaction without conversation
delivery. A `waiting_on_user` notification passes only each question's header, prompt
text, `secret` flag, and labeled choices to the parent. Raw Codex thread, turn,
item, question, and option IDs stay inside Job metadata for resume and never
enter the parent prompt.

## Which Process Does What

The Elixir control plane:

- stores Job and Job Turn rows in PostgreSQL
- verifies authorization and persists `reply_route`
- drives Job state transitions and counts execution attempts
- dispatches, steers, stops, and externally completes Jobs
- validates optional workspace templates and custom Model Profiles (defaulting
  to `coding`)
- freezes the resolved runtime projection at first execution admission
- places or adopts Codex Turns through `Sessions.JobDriver` and enforces the
  attempt fence
- delivers lifecycle notifications to the originating Session

Agent Computer:

- creates and manages the Job Workspace directory and temporary runtime files
- combines the Job's frozen runtime projection with live credentials and
  mutable Skill files
- acquires a lease on the shared per-Agent `AgentCodexRuntime`
- filters Background-eligible Skills and Skill-owned MCP servers
- starts or resumes the Job's Codex root thread and routes child threads to the
  owning Job
- streams sanitized semantic Turn trajectory checkpoints
- waits for routed child Turns before committing Job success, then returns the
  final Codex response

Codex owns thread state, subagent collaboration, and command execution; Ankole
owns Skill discovery and loading; `AgentCodexRuntime` owns Plugin installation
and Hook trust; and PostgreSQL owns the durable Job record across crashes.

## Human Work Authorization

Under [Human Offboarding](HumanOffboarding.md), every Job persists
`authorization_kind`, `human_uid`, and `human_access_version` from its
authenticated source Signal on creation and respawn (Worker crash recovery
retains the stored authorization, and Brain's reflection caller supplies its
Agent as the trusted `created_by` service source).

The control plane verifies authorization before creation, dispatch admission,
and any fresh resume or retry. When a Human's access is revoked, cleanup stops
`queued` and `waiting_on_user` Jobs once any already admitted Codex Turn
finishes; it never interrupts an in-flight Turn or discards its result. Child
work retains the originating Human association even when tools authenticate with
Agent credentials.

## What PostgreSQL Stores

`background_agent_jobs.id` is a PostgreSQL identity `bigint` starting at `1000`
and bounded by JavaScript's `Number.MAX_SAFE_INTEGER` (exposed as a JSON integer
to model tools, serialized as a canonical decimal string across RuntimeFabric to
prevent rounding, and paired with Session key `job:<id>`).

The `background_agent_jobs` table stores:

- **Identity and lineage:** `id`, `agent_uid`, `owner_session_id`,
  `source_signal_id`, `source_tool_call_id`, `reply_route`,
  `continued_from_job_id`, `workspace_owner_job_id`, and `runtime_thread_id`.
- **Request:** `title`, `task`, `model_profile` (`coding` or a custom profile
  name), and optional `workspace_template_id`.
- **Execution state:** `runtime_projection` (written atomically on first
  attempt admission when absent), `status`, `attempts`, timestamps, `result`,
  `error`, and `metadata`.

`runtime_projection` never stores secrets. Instead, it freezes the resolved
provider, model, reasoning effort, provider options, direct input modalities,
optional image-capable vision fallback, logical Plugin and member Skill IDs (no
package hashes, archive bytes, overlays, Hook state, or cache paths), and
non-secret Worker and browser settings. Retries, continuations, and Worker
migrations reuse those frozen values rather than drifting with later Agent
configuration edits, while a manual respawn inherits `model_profile` and
snapshots a fresh projection on its own first admission.

`native_mcp_servers` is reserved and currently empty: each run resolves MCP
dependencies from current Skill files and fetches live credentials from their
owners. For example, Agent Computer writes refreshed Lark tenant tokens to an
execution-local file read by `lark-cli` rather than exporting tokens into the
Codex process environment.

On every run, Agent Computer intersects the Job's projected Skill IDs with the
Agent's currently enabled Skills, admitting Skills whose `ankole-runtime` is
unset, `any`, or `background_job` while excluding `main` Skills (callers cannot
pass per-Job capability overrides).

### Turn Trajectories and Collaboration Items

`background_agent_job_turns` stores one trajectory header per runtime Turn,
alongside foreign keys and IDs for the Job, attempt, Codex thread, and Codex
turn. Append-only `background_agent_job_turn_items` rows store sanitized
semantic thread items with their positions and `item_key` values. Those item
rows are the single storage and read-path owner of Turn content: every reader
projects `ankole_chatml` messages from stored items at read time. Items whose
`ankole_chatml` projection is empty remain stored for thread replay, and if a
Turn has zero item rows, it returns an empty trajectory and falls back to
Workspace rebuild when replay finds no items.

Each tool-call and tool-result pair keeps `namespace` separate from leaf `name`
and tags tool results with `provider_hosted` (executed inside the upstream LLM
Response) or `local_dynamic` (executed by Ankole via Codex dynamic tools).

New Codex root threads enable experimental raw response-item notifications, from
which the trajectory recorder selects only collaboration `function_call` and
`function_call_output` items on the caller Turn without persisting raw
app-server frames. Each stored pair keeps `namespace: collaboration`, the exact
V2 leaf name, arguments, and output for `spawn_agent`, `send_message`,
`followup_task`, `interrupt_agent`, `list_agents`, and `wait_agent`, and tags
each call with `arguments_source`:

- **`raw_function_call`:** arguments came directly from a raw `function_call`
  item.
- **`child_initial_input`:** in code mode, collaboration calls happen inside the
  JavaScript executor with no raw `function_call`; the recorder FIFO-pairs the
  collaboration activity with the child thread's raw `agent_message` payload
  (storing the plaintext brief in `arguments.message`, plus `target` on
  interactions) regardless of whether the child message arrives before or after
  `turn/started`.
- **`activity_fallback`:** if the caller Turn finishes or flushes before the
  child input arrives, the recorder stores empty arguments.

Because parent-scoped `subAgentActivity` notifications share the collaboration
call ID, the recorder enriches the call result with the stable child thread ID
and Agent path without storing a duplicate display item. The runtime also uses
`started` activities to assign child threads to the parent Job. Because Codex
emits no child `thread/started` notification, the runtime buffers child Turn
events that arrive before assignment and replays them afterward. When resuming
an older thread without raw notifications, `subAgentActivity` synthesizes a
minimal lifecycle pair and uses `collaboration.agent_interaction` whenever
`send_message` versus `followup_task` is ambiguous.

### Transport Bounds, Checkpoints, and Compaction Metadata

Before JSON parsing, the app-server transport enforces a 64 MiB wire-byte cap
on every JSON-RPC line (including trailing unterminated lines), and caps
buffered notifications for unowned threads at 256 messages or 64 MiB of UTF-8
(protocol retention limits rather than JS heap guarantees). Exceeding either cap
terminates and reaps the Agent's app-server via the runtime-loss recovery path
rather than dropping completion frames and continuing with a corrupt thread
tree.

Within a Job session, ordinary lead-Turn completions are serialized and
deduplicated by `(thread_id, turn_id)` so a fast retry finishing in the same
output batch as its start response waits behind preceding recovery rather than
being dropped. By contrast, explicit `thread/compact/start` completions resolve
their handshake immediately outside that serial queue so recovery can launch its
retry without deadlocking.

On the control plane, Ash state-machine actions on `Turn` enforce monotonic
checkpoint revisions and terminal immutability (allowing the first observed
checkpoint to be terminal already, validating headers/progress/usage alongside
SQL completion-time constraints, and advancing revisions while clearing active
items in one bulk SQL update on interruption so late Worker snapshots are
ignored). While holding the Job and Turn locks, the recorder accepts idempotent
checkpoint retries, appends `TurnItem` rows (unique by position and semantic
`item_key` per Turn, rolling back checkpoint and items together on conflict),
and merges `content_truncated` into header metadata non-destructively.

The Worker sets `kind=compaction` strictly as immutable Worker-to-control-plane
diagnostic metadata on Turns created by explicit `thread/compact/start` calls
(automatic in-Turn Codex compactions remain `contextCompaction` items inside
that agent Turn). `kind` never affects Job type, lead/child routing, trajectory
visibility, `item_key` causal matching, or Turn recovery (though the execution
projection exposes a diagnostic `kind=compaction` row count that overlaps lead
and child counts rather than counting total compaction events).

## Where a Job Runs

Agent Home lives at `/workspace/` (with `/agents/<agent_uid>` symlinked to
`/workspace` by the container entrypoint so persisted paths under either prefix
resolve identically), and the initial Job creates its Workspace at:

```text
/workspace/jobs/<workspace-owner-job-id>/
├── .codex/config.toml
├── AGENTS.md
├── temp/
└── ...
```

The initial Job sets `workspace_owner_job_id` to its own ID, and every respawned
successor inherits that value so the entire continuation chain executes inside
the same real working directory and Codex project root (which must exist as a
non-Git directory on persistent Home across Worker replacements). Sibling Job
workspaces organize work cleanly without acting as a security sandbox against
other files owned by the same Agent under `/workspace`.

The runner configures three paths for Codex:

```text
HOME=/workspace
CODEX_HOME=/workspace/.codex
CODEX_SQLITE_HOME=/var/cache/ankole/codex
```

Both `HOME` and Codex session JSONL files under `CODEX_HOME` live on persistent
storage, while `CODEX_SQLITE_HOME` is an ephemeral local cache that Codex
rebuilds from thread files on resume (see [Agent Workers](AgentWorkers.md)).
Rebuildable Plugin packages and their local marketplace also live under
`CODEX_HOME`; because Codex auto-discovers `$HOME/.agents/plugins/marketplace.json`
and a colliding marketplace name there would hijack Plugin IDs, startup
verification selects the Worker marketplace by exact path and fails if any other
marketplace path appears.

### Shared `app-server` Lifecycle and Thread Ownership

Each Worker runs at most one Codex `app-server` process for its Agent via
`AgentCodexRuntimeManager`, starting on the first Job lease, shutting down
cleanly (closing stdin, waiting a bounded grace period before `SIGKILL`, and
reaping the child with no idle TTL) when the last lease releases, and guarding
`CODEX_HOME` with an OS `flock` held directly by the `exec`-ed `app-server`
process (so lock release and process exit share one kernel owner, and any
contending starter immediately reports a retryable busy status). Stopping a
`queued` Job finalizes and frees its Worker slot immediately because Jobs have
no per-Job Plugin setup phase.

Inside that shared `app-server`, each Job owns one root thread and any child
threads assigned via `subAgentActivity`:

- When a Job finishes, the runtime retains tombstones for its retired child
  thread IDs until `app-server` exits, immediately interrupting and
  unsubscribing any straggling child event so late children never linger as
  unowned threads.
- Root threads remain reclaimable across retries and respawns once the prior
  owner finishes cleanup: the runtime serializes cleanup, new-root registration,
  resume registration, and retired-thread teardown per thread ID (registering
  ownership before Codex can emit resume events, blocking stale cleanups from
  unsubscribing a reclaimed root, and restoring a reclaimable root tombstone on
  failed resume while keeping child tombstones permanently closed).

Before the first Job thread starts, `AgentCodexRuntime` serializes one-time
Agent-wide setup: it refreshes same-release Plugin packages, installs them via
`plugin/install`, trusts Hooks, and disables every global Plugin entry. Once
setup completes, concurrent Job turns run without mutating shared Plugin or user
config state or exposing native Skill directories to Codex. Instead, Ankole
writes the filtered Skill index into the project `AGENTS.md`, serves full Skill
files via dynamic `skill_view`, and supplies Skill MCP servers via an
invocation-scoped `MCPORTER_CONFIG`. Job preparation strips any `mcp_servers`
table from `.codex/config.toml`; no bundled native MCP server is currently
shipped, and if one is added later, Codex must own it natively rather than
projecting `mcp__*` dynamic tools (see
[MCP-backed Skills](MCPBackedSkills.md#model-visible-mcp-boundary)).

On cold start, while holding the `CODEX_HOME` `flock`, Agent Computer deletes
only `logs_2.sqlite` (and its `-wal`, `-shm`, and `-journal` sidecars) and
atomically refreshes the shared Codex config and AIGateway token before
`exec`-ing `app-server`; contenders that lose the lock touch nothing. Because
the pinned Codex `app-server` can spend tens of seconds maintaining
`logs_2.sqlite` before answering `initialize`, Agent Computer logs a slow-start
warning at 60 seconds and enforces a 300-second hard timeout. After
initialization, it installs a temporary SQLite trigger that drops `TRACE`,
`DEBUG`, and `INFO` log rows while keeping `WARNING` and higher without altering
journal mode, working around
[openai/codex#27741](https://github.com/openai/codex/issues/27741) using the
filter in
[codex-logs-trigger-patch](https://github.com/yangtzech/codex-logs-trigger-patch/blob/main/patch_codex_logs.sh).

### Project Configuration and Code Mode

Each Job's `.codex/config.toml` holds project-local settings (trusted by exact
Workspace path):

- **MultiAgentV2:** enabled by default with `hide_spawn_agent_metadata=true`
  (hiding optional Agent type, model, reasoning, and service-tier inputs plus
  result nicknames on `spawn_agent`, while keeping raw collaboration items and
  `subAgentActivity` events intact). Because MultiAgentV2 is a reliability
  default rather than a safety invariant, a workspace template that sets
  `features.multi_agent_v2.enabled` keeps its own value so an operator can hold
  a Job to single-Agent execution.
- **Child dynamic tools (`features.multi_agent_v2_dynamic_tools = true`):**
  enforced unconditionally as a runner invariant (templates cannot disable it)
  so spawned child threads inherit `skill_view`, `web_fetch`, `web_search`, and
  Brain read tools; running-status metadata records both
  `child_dynamic_tools_inherited` and `code_mode`, verified by the
  `codex-dynamic-tools-inheritance` host integration test.
- **Native code mode:** enabled on every Job so Codex provides an isolated
  client-side JavaScript executor for eligible local dynamic tools (distinct
  from the Responses API `programmatic_tool_calling` wire feature, which the
  pinned Codex runtime ignores), keeping structured `(namespace, name)` tool
  identities alongside JS globals while leaving MCP-backed Skills on terminal
  `mcporter` commands and sending `web_search`/`web_fetch` selectors straight to
  AIGateway without a separate catalog cache.

### Code-mode tool registry

Code mode exposes strictly the dynamic tools that Agent Computer declares to the
Codex thread (`tools.<name>` inside the JavaScript executor; undeclared tools do
not exist, and AIGateway-hosted Response tools never enter this registry).
`buildCodexJobProjection` admits at most six read-only/coordination tools:

| Tool | Executor | Condition |
| --- | --- | --- |
| `web_search` | `Ankole.Sessions.Tools.Web` through `tools.read` | Omitted when the Job's provider connection declares hosted `web_search` |
| `web_fetch` | `Ankole.Sessions.Tools.Web` through `tools.read`, with the Worker rendered fallback | Always |
| `skill_view` | `Ankole.Sessions.Tools.Skill` through `tools.read` | Always |
| `recall` | `Ankole.Sessions.Tools.Brain` through `tools.read` | The turn start carries its declaration in `request_context.brain_tools`, which the control plane fills while `brain.enabled` is true |
| `get_page` | `Ankole.Sessions.Tools.Brain` through `tools.read` | Same as `recall` |
| `request_parent_input` | The Worker lead-thread guard and the control plane wait | Always declared; only the lead thread may call it |

Brain write operations, browser tools, and foreground-only tools never enter
this registry, and the control plane owns every read tool's schema and execution
(`Ankole.Sessions.Tools.Brain.declarations/0` is the single schema source piped
through `TurnEnvelope` -> `request_context.brain_tools` -> Codex and validated by
`ReadToolBroker`, while the Worker Brain module is purely an RPC codec). Spawned
child threads inherit this exact registry so children can call `skill_view`, web
tools, and Brain reads directly.

For `web_search`, when the Job's frozen provider connection supports hosted
search, `.codex/config.toml` sets `web_search = "live"` and Agent Computer omits
dynamic `web_search` so the model always uses the upstream hosted tool (AIGateway
model cards disable Responses Lite because the pinned Codex drops hosted search
on Responses Lite, using standard Responses instead). Otherwise, config sets
`web_search = "disabled"` and registers dynamic `web_search` (workspace
templates cannot override either setting, and dynamic `web_fetch` is always
registered).

All Job LLM traffic routes through the `ankole_aigateway` provider configured in
`CODEX_HOME` with display name `OpenAI` (signaling remote-compaction support to
the pinned Codex runtime so Codex sends `compaction_trigger` on standard
Responses requests; omitting `model_auto_compact_token_limit` lets AIGateway's
threshold fire ahead of Codex's `0.9` fallback). Whether AIGateway summarizes locally or delegates upstream is controlled per
request by the `upstream` field of the instance `ai_gateway.compaction`
settings (not a per-Job setting): when delegating upstream, AIGateway tries the
Job's frozen Provider and model first, falls back to local compaction on
unsupported or transient errors, and if a later compaction cannot use the same
upstream Provider after opaque compact items were stored, keeps the opaque items
verbatim, summarizes only subsequent readable items, and logs a warning (note
that preserved opaque items remain readable only on a compatible Provider).

On every AIGateway request, the runner sends the real Codex model ID and
supported reasoning effort (never a logical profile name) alongside the Job's
frozen provider/model selector, provider options, parallel-tool-call capability,
direct input modalities, and optional frozen vision fallback: AIGateway enforces
that frozen binding ahead of any conflicting Codex request fields, strips
Codex-internal `internal_chat_message_metadata_passthrough` and
`encrypted_function_args`, sets `parallel_tool_calls` (except on Responses Lite),
and routes images either directly to multimodal main models or through the
frozen vision fallback as untrusted text.

## Compose the Project AGENTS.md

When initializing a Job Workspace, the runner writes `AGENTS.md` at the
Workspace root: any optional workspace template provides the opening section,
followed by the rendered Agent `SOUL` and `MISSION` documents and execution
context.

If the Job originated in a channel conversation, the execution context names
that conversation's drive directory (whereas Jobs without a source channel use
the shared drive). Because the local Job Workspace is temporary scratch space,
the instructions direct the Job to save durable outputs and outbound
deliverables into its assigned drive directory and forbid reading or writing
another conversation's workspace or drive folder.

The rendered context also embeds the ordinary Skill index (omitting Skills
marked `brain-recall-only: true`, which remain discoverable through Brain),
while `.codex/config.toml` sets the native subagent wait minimum to 1 minute and
the default to 10 minutes (keeping the Codex default maximum) to accommodate
multi-minute subtasks without burning repeated model turns during waits; see
[openai/codex#35259](https://github.com/openai/codex/issues/35259). Resumed threads keep their project `AGENTS.md` untouched: instead of rewriting
project files on resume, the runner passes the latest drive and delivery rules
as developer instructions and appends refreshed instructions via
`thread/inject_items`.

## Prepare Skills for Each Run

Each `SKILL.md` frontmatter may declare an optional `ankole-runtime` target
(any other value is rejected by the loader):

- **Omitted or `any`:** available to both the main Agent and Background Agent
  Jobs.
- **`main`:** available only to the main Agent; Job preparation excludes it from
  both the Job's Skill index and its MCP configuration.
- **`background_job`:** available only to Background Agent Jobs; calling
  `skill_view` from the main Agent returns Job-delegation guidance rather than
  the Skill body.

`ankole-runtime` governs Skill discovery and `skill_view` invocation rather than
acting as a filesystem boundary inside an installed Plugin directory.
Agent-installed Skills live at `/workspace/installed-skills/<skill-name>/`.

Before each run, Agent Computer computes the loadable Skill set by intersecting
the Job's frozen Skill selection with the Agent's currently enabled Skills and
the `ankole-runtime` filter. When a Job calls Ankole's dynamic `skill_view` tool, it reads through the same
path-confined loader as the main Agent, appends any active database lesson to
`SKILL.md`, marks the Skill as used, and includes the Skill's `ankole-runtime`
value in the tool output. The loader rejects disabled Skills, `main`-only
Skills, and any path traversal outside the Skill root. Native Codex Skill
discovery (`.agents/skills` and `skills/list`) never manages Ankole Skills.

## Prepare Agent Plugins for Each Run

Agent Plugins follow the standard `.codex-plugin/plugin.json` manifest, and any
bundled `workspace-template` initializes the Job Workspace once at creation.

Before starting the first Job thread on a Worker, `AgentCodexRuntime` runs
Agent-wide Plugin setup:

1. Refresh local package directories for every trusted same-release Plugin.
2. Install each package through Codex `plugin/install`.
3. Verify installation and mark package Hooks trusted in Codex.
4. Disable every global Plugin entry in shared Codex user configuration.

Per-Job preparation then performs strictly thread-scoped selection without
calling `plugin/install`, trusting Hooks, or mutating shared Plugin caches or
user config:

1. Intersect the Job's frozen Plugin and member selection with the Agent's
   current effective catalog.
2. Add Background-eligible Plugin Skills to the `skill_view` allowlist and
   non-lazy Skill index (never passing Plugin Skill roots to Codex directly; if
   an operator disables a member mid-run, Agent Computer drops it from the
   loader and sends a disable notice to active Jobs).
3. Project enabled Skill-owned MCP servers into the invocation-scoped mcporter
   configuration.

Enabling an Agent Plugin never introduces an alternate Skill loader or a second
Job runner; see [Plugins](Plugins.md).

## Job States and Recovery

```text
queued
  -> running
       -> waiting_on_user -> running
       -> succeeded
       -> failed
       -> stopped
  -> failed
  -> stopped
```

Sending a message writes input for any live Job (`queued`, `running`, or
`waiting_on_user`) and never reopens a terminal Job (`succeeded`, `failed`, or
`stopped`); respawning a terminal Job inserts a brand-new `queued` Job without
mutating the source row.

### State Machine and Transaction Composition

The Job Ash resource defines the single authoritative transition table via
`AshStateMachine`:

- Every status change runs through its dedicated transition action, rejecting
  undeclared transitions with `{:invalid_status_transition, from, to}`,
  preventing terminal Jobs from returning to `queued` or `running`, accepting
  only action-owned attributes (status reports can never alter authorization,
  ownership, runtime projection, or attempt counters), and failing validation
  before SQL if unknown fields are supplied.
- Console queries, lists, and detail schemas share one status enum projection
  from the Job resource, Worker-wait timestamps update via atomic resource
  actions, and Turn schemas and checkpoint transitions likewise delegate to the
  Turn resource's state machine.
- The transition action alone selects the commit semantics: `worker_report`
  derives its target status from the Worker payload (failing with
  `background_agent_job_status_missing` when absent) and is the only path that
  can seed an automatic steer successor on `succeeded`; `external_complete`,
  `fail_admission`, `fail_turn`, `requeue`, `stop`, and `stop_human_work` have
  fixed target states, `external_complete` answers open steers via its own
  wakeup, and neither `external_complete` nor `fail_admission` requires a closed
  lead Turn.

Every multi-row operation owns a top-level `Repo.transact_top_level/2`
transaction: `create_with_dispatch`, `respawn_with_dispatch`, `request_stop`,
`request_complete`, `send_message`, `commit_status_with_wakeup` (whose
`after_commit` wakes `JobDriver`), `upsert_turn_from_worker`, `complete_signal`,
`WorkerWait.resolve_timeout`, and the lock phase of
`TurnWatchdog.reconcile_stuck_job`. Cross-domain callers compose inside their
own transactions through `BackgroundAgentJobs` helpers and read Signals strictly
through the Signals domain interface and composition helpers:

- **`admit_attempt_in_tx/4`** verifies admission authority, locks the Worker,
  Agent slot scope, and Job (running the Session caller's preparation check
  under the Job lock before reserving a slot), checks capacity, updates
  `worker_wait_started_at`, and claims or adopts the attempt.
- **`abort_attempt_in_tx/4`** verifies attempt ownership, locks Turns, Sessions,
  and the Signal, settles the input, and compensates the Job; because pre-SQL
  Ash action rejections do not abort the enclosing PostgreSQL transaction,
  `CodexJob.abort` can still commit Signal settlement and owner wakeup after a
  rejected state transition.
- **`fail_admission_in_tx/3`** commits an admission failure together with its
  parent wakeup.
- For lock ordering, Worker RPC authorization reads the input under the Job lock
  and attempt fence before mutations lock Turns, Sessions, and Signals; and when
  a `succeeded` Turn seeds a steer successor, it allocates the successor ID
  before locking Signals so the new `job:<id>` Session lock sorts cleanly with
  the current and owner Session locks.

### Concurrency, Worker Readiness, and Retry Budgets

`background_agent_jobs.max_running_per_agent` caps concurrent
running Jobs per Agent (default `3`), and each Job has a budget of at most 5
execution failures and 25 total slot claims (so infrastructure interruptions
cannot burn the task's execution-failure budget). Only claiming a fresh Worker
slot increments `attempts`; adopting an already running attempt does not.

New attempts evaluate the shared
[Worker readiness rule](AgentWorkers.md#new-attempt-readiness) using the locked
Worker and Agent Job-capacity check, persisting `worker_wait_started_at` via
atomic resource updates that leave `updated_at` untouched across repeated waits
or clears:

- **Waiting:** schedules a durable wakeup 30 seconds out without consuming an
  attempt (passing `retry_at` to the Driver timer while keeping the Signal's
  business deadline in `available_at` and re-verifying both deadline and queue
  head under lock, preserving the Worker-readiness wake reason even if Agent Job
  slots are also full). Whenever the Agent's Worker becomes ready, `JobDriver`
  wakes immediately on `{:worker_changed, uid}` without waiting for the
  30-second timer.
- **Readiness timeout (`timed_out`):** a `queued` Job fails with
  `agent_worker_unavailable` and dead-letters its dispatch Signal, whereas a
  `waiting_on_user` Job stays in `waiting_on_user`, clears
  `worker_wait_started_at`, dead-letters the steer Signal, and emits
  `background_agent_job.input_undeliverable` to the owner Session.

On the Worker, transient connection drops alone do not abort local execution.
The Worker stops an attempt once control-plane acceptance or checkpoint replies
confirm that the attempt changed or the Job closed, and accepting a newer
attempt tears down any older local attempt before resuming the Codex thread
without relying on best-effort retry-control messages. If all Worker slots are
busy when a newer attempt of the same Job arrives, the newer attempt takes over
its older attempt's slot rather than failing with `worker_busy`: it retires the
older attempt before running, returns the slot if the control plane rejects the
newer attempt first, or passes the donor slot forward if a third attempt already
claimed it so every slot maps to at most one live attempt.

Retryable failures follow tiered backoff ladders classified once by the control
plane (ordinary foreground Turns share the classifier with shorter user-facing
waits):

- **Infrastructure interruptions** (`socket_closed`, `runtime_fabric_timeout`,
  and `runtime_rpc_timeout`, never generic `timeout`) retry within minutes and
  charge zero execution-failure budget. Safe reads first retry in place after
  rejoin, whereas unacknowledged writes never auto-repeat at the RPC layer.
- **Context overflow** compacts the thread and retries in place without charging
  the execution-failure budget.
- **Provider-capacity and execution failures** (`server`, `rate_limit`, or
  credential-pool exhaustion where authoritative `details_json.retryable` is not
  `false`) back off across hours so Jobs survive upstream outages while AIGateway
  rotates credentials. When AIGateway reports quota exhaustion with a known
  future reset timestamp, the Job returns to `queued` until that timestamp
  without charging an execution failure (keeping the consumed claim count);
  missing or past reset times use the standard multi-hour provider-capacity
  ladder and charge one execution failure.
- **Terminal rejections:** upstream HTTP statuses that reject the request
  payload itself (inspected before Codex stream-disconnect text), Agent
  [token quota](AgentTokenQuota.md) rejections (`agent_token_quota_exceeded` on
  the first rejected LLM call, since creation and admission do not precheck
  quota), domain rejections, and non-idempotent RuntimeFabric turn writes or
  completions fail the Job immediately without requeueing. Only turn-scoped
  RuntimeFabric read handler errors retry, preserving `failure_id`.

Retries run on the Agent's single Worker (or a replacement mounting the same
persistent Home), resuming the Workspace and Codex thread file. Terminal commits
store the final Job status and wakeup notification in one transaction, and
callers deliver owner wakeups, successor dispatches, or external-completion stop
signals strictly after the outer transaction commits. Agent Computer commits
terminal status before cleaning up local threads, files, and runtime leases,
logging any post-commit cleanup error as a warning without reopening completed
Turns. Replacement Workers wait for the prior Worker to exit, and the Turn
attempt fence rejects stale writes from superseded attempts.

### Stall Detection (`TurnWatchdog`)

Because Worker heartbeats prove only OS process liveness even if Codex stops
emitting progress, `TurnWatchdog` monitors the latest in-progress Turn
checkpoint timestamp for the active attempt (or Job `updated_at` before the
first Turn row exists; delegated child Turn checkpoints also advance this clock,
whereas Worker heartbeats do not) via an Oban sweep with no separate lease
process. One hour without durable checkpoint progress counts as a stall: the
watchdog interrupts the attempt's active Turns, leaves retryable input open, and
sends a best-effort stop to the Worker (fencing out late commits), failing the
Job permanently on its third stall.

### Persistent thread files

Codex persists each thread under `/workspace/.codex/sessions/` (containing
conversation items, reasoning traces, and compaction markers in `.jsonl` or
`.jsonl.zst`, both readable without the ephemeral SQLite cache; the Worker never
archives these files).

Because `/workspace` sits on persistent provider storage, both the Job Workspace
and session files survive container deletion and image upgrades without a
thread-segment database table, RPC copy, or workspace snapshot archive (if a
crash leaves a truncated final JSONL line, Codex resumes the valid prefix and
repeats subsequent work, while PostgreSQL `TurnItem` rows remain the audit/UI
record; see [Agent Workers](AgentWorkers.md#cloudflare) for Cloudflare backup
window limits).

### Replacement threads

If Codex cannot resume its native session file, each attempt may create at most
one disclosed replacement thread (whether on initial resume or mid-attempt
thread loss):

1. **Transcript replay** (only while `legacy_thread_replay` is set in metadata;
   cleared on the first successful runtime anchor and inherited by continuations
   only while set): the Worker pages stored lead-thread items across the
   Workspace lineage via `background_agent_job.turn_items.list`, reconstructs
   wire response items with separate `namespace` and `name` on every
   `function_call` (so app-server restarts during deploys never flatten
   namespaced tools into root tools), injects them into a fresh thread
   (re-compacting if needed), and sets
   `runtime_checkpoint_recovery: replayed_from_transcript`.
2. **Workspace rebuild** (when `legacy_thread_replay` is unset, or when replay
   finds zero items or fails): starts a fresh thread seeded with `job.task`, the
   durable Workspace files, bounded attempt history, and (for continued Jobs)
   the source Job's `task` and final report, setting
   `runtime_checkpoint_recovery: new_thread_from_bounded_history`.

## Create and Dispatch a Job Once

Job creation deduplicates on `{agent_uid, owner_session_id, source_tool_call_id}`
(returning the existing Job and dispatch Signal on retry):

- Omitting `model_profile` validates `coding` (and its `heavy` fallback),
  whereas an explicit value must match a configured custom LLM profile (failing
  without fallback if unavailable, and rejecting `coding`, other fixed profiles,
  or raw model names).
- One PostgreSQL transaction inserts both the Job row and its dispatch Signal
  targeting `{agent_uid, "job:<job-id>"}` (every Job Session uses the `job:`
  prefix).
- First execution admission snapshots the resolved runtime projection and
  AIGateway provider binding onto the Job row, allowing concurrent Jobs of one
  Agent to use different provider rows without mutating shared `CODEX_HOME`
  files.

## Respawn a Terminal Job Once

Respawning shares the same `{agent_uid, owner_session_id, source_tool_call_id}`
idempotency key:

- Locking the source Job, the control plane requires `succeeded`, `failed`, or
  `stopped` plus a stored `runtime_thread_id` and `workspace_owner_job_id`,
  enforcing a unique constraint on `continued_from_job_id` so each terminal Job
  has at most one direct successor (preventing concurrent writes to one thread
  and Workspace; same-call retries return the stored successor, while distinct
  calls fail naming that successor).
- `Ankole.BackgroundAgentJobs.Schemas.Job.successor_attrs/2` copies `title`,
  `runtime_thread_id`, `workspace_owner_job_id`, `workspace_template_id`, and
  `model_profile` (plus `legacy_thread_replay` when still set) for both manual
  respawns and automatic steer successors. Successors never copy
  `runtime_projection`, `result`, `error`, `attempts`, or
  `managed_background_agent_job_root`, and Agent Computer never re-materializes
  the workspace template once a thread exists. Console Job detail surfaces both
  `continued_from_job_id` and `workspace_owner_job_id`.
- Both Agent Computer (pre-RPC) and CodexRunner (pre-run) verify that the
  inherited Workspace exists on persistent Home without creating one if missing,
  then resume the stored thread with `message` as the new `task` (falling back
  to the [replacement thread](#replacement-threads) ladder if Codex cannot
  resume).

## Send a Message and Wait for Its Turn

Ankole tracks native Human instructions from the triggering Message and consumed
steers separately from the main Agent's delegated `task` brief. The source
Message establishes Human identity, and the corresponding Signal freezes that
exact input version: editing the visible Message creates a fresh retry Signal
rather than mutating stored inputs, and unconsumed queued messages do not count
as active Job instructions. While Pod Page creation provenance follows the
original Job source, current execution intent advances to newer applied Human
steers. Recording a `client:<signal-id>` steer receipt atomically updates the
control plane's reserved `applied_source_signal_id` metadata, which neither
Worker payloads nor older main-Agent summaries can overwrite; because the
external Codex ACK and database receipt are not atomic, unrecorded steers stay
open for replay.

Each `send_message_to_background_job` call (idempotent by `source_tool_call_id`)
inserts a `command.steer` Signal whose Signal ID flows into Codex as
`clientUserMessageId` and is recorded in the trajectory as `client:<event-id>`.
Those matching IDs let the control plane find the exact Codex Turn that received
the message without a waiter table or resident waiter process:

- Queued messages never overwrite `job.task`. Job sessions drain open Signals in
  strict `queue_sequence` order whenever no Turn is live, so messages sent to a
  deferred `queued` Job wait behind initial dispatch (unlike ordinary
  conversations, which can process an earlier-due Signal ahead of a future-dated
  one). Due Oban `EnsureDriver` jobs and the conversation Reconciler recover
  that queue after process crashes.
- Once a Codex Turn starts or is adopted, the Driver immediately flushes open
  `command.steer` Signals in order (`turn/steer` on `running` Jobs, or a fresh
  Turn on `waiting_on_user` Jobs). The Worker deduplicates by Signal ID, and the
  mailbox locks Human authorizers before Session and Signal rows so revoked
  inputs terminate before reaching the Worker.
- After `turn/start` succeeds, Codex must emit a lead runtime notification
  within 60 seconds; otherwise, Agent Computer aborts the attempt as a retryable
  runtime failure so generic Worker heartbeats cannot mask a wedged Turn.
- When `wait_reply=true`, the parent Session Driver polls persisted Turn state
  once per second across a 10–150 second foreground window (30 seconds by
  default; timeout leaves the Job running, and an incoming parent steer wakes
  the wait immediately without consuming that steer). A reply is ready once the
  causal Turn is terminal and the Job has committed `waiting_on_user`,
  `succeeded`, `failed`, or `stopped`, or once a newer lead Codex Turn proves
  that execution continued past the causal Turn. A terminal trajectory while the
  Job still shows `running` with no newer lead Turn waits across the brief gap
  before Job-state commit, whereas commands that settle or dead-letter without
  appearing in any trajectory return a delivery error.

If a `succeeded` `worker_report` finds open steers outside `applied_signal_ids`,
the same transaction creates one successor Job carrying those messages in order
and completes the steer Signals (rolling back if successor creation fails,
whereas `failed`, `stopped`, and `external_complete` commits answer open steers
via the terminal wakeup instead). That successor resumes the Codex thread on the
Agent's Worker or starts a [replacement thread](#replacement-threads) seeded
with the source Job's task and final report.

Inside Background Codex, child subagents receive `request_parent_input` rather
than `request_user_input` and send questions to their lead thread. Calling
`request_parent_input` on the lead thread ends the active Codex Turn,
transitions the Job to `waiting_on_user` (recording internal event code
`request_user_input`), and notifies the main Agent. The main Agent answers in
plain text via `send_message_to_background_job`: it answers directly whenever
conversation history, a loaded Skill, or its own tools supply the answer;
rewrites or stops the Job when a question reveals that the task is infeasible as
written; and asks the human user only when a real user decision, approval, or
missing user fact is needed.

## Hand Off a Lifecycle Notification

Transitioning to `succeeded`, `failed`, or `waiting_on_user` inserts an open
lifecycle Signal for the originating conversation. When a foreground
`send_message_to_background_job(wait_reply=true)` call from that exact
originating Session observes the settled result directly, Agent Computer
attaches the lifecycle Signal ID in a hidden, non-model-visible tool-result
field: `AIGatewayLink` verifies the authenticated subject, active parent Signal,
target Session, event type, Job, attempt, and `open` status, then journals the
tool result and completes the lifecycle Signal atomically in one PostgreSQL
transaction (rolling back both if journaling fails or is quarantined, and
re-verifying completed IDs on journal retry).

Whenever the tool does not wait, errors, is canceled, observes a still-running
Job, or runs from a different Session of the same Agent, it omits that hidden ID
so the originating Session receives its normal asynchronous wakeup.

## Return Results and Files

Job success requires a non-empty final Codex response (plus the Job Workspace
path):

- When Codex emits message `phase`, only `phase: final_answer` qualifies
  (commentary and partial messages stay in the trajectory).
- When `phase` is absent or `null`, the pinned Codex contract treats the latest
  lead assistant message as a candidate only until the lead thread starts
  another work item (command, file edit, tool call, or collaboration call;
  automatic compaction does not clear it) or starts a new lead Turn.
- If no candidate final report exists when the Turn tree settles, the runner
  prompts the same thread once for a final report before failing with
  `codex_empty_report`.

On wakeup, the main Agent checks reported deliverables and verification against
the user's goal: it reuses completed verification rather than spawning redundant
check Jobs, and continues concrete unfinished work before claiming completion.
On a continuation, the main Agent states the unmet outcome without guessing at
unverified saved state, while the continued Job inspects and reuses earlier
tool-returned IDs rather than treating an incomplete report as proof that saved
work is absent.

Job results can include three bounded path lists (`files_changed`, `artifacts`,
and `artifact_roots`), each carrying `{total_count, paths, truncated}` capped at
32 paths and 8 KiB (`artifacts` are ordinary Workspace files with no separate
lifecycle):

- `files_changed` merges two sources and lists each contributing source in
  `files_changed_source`: `codex_diff` captures aggregate `turn/diff/updated`
  edits made by Codex tools, while `workspace_snapshot` diffs the Workspace
  before the attempt's first Turn and after the lead Turn tree becomes idle to
  capture shell and child-thread file additions, edits, and deletions. The
  snapshot skips root `AGENTS.md` plus `.codex`, `.ankole`, `.git`, `.venv`,
  `venv`, `__pycache__`, `browser`, `build`, `dist`, `node_modules`, `target`,
  and `temp` at any depth. If a scan exceeds 50,000 files or 2 seconds, it stops
  and records `workspace_snapshot_skipped` alongside `codex_diff`; edits that
  leave both byte size and mtime unchanged are invisible to the snapshot.
- Outbound attachments must live in the Agent's drive: `reply_attachment`
  accepts only `drive_path`, pins the current SHA-256 digest, confines
  `chats/<channel_id>/` files to that exact channel (see [Files](Files.md)), and
  requires explicit structured attachment calls (Ankole never scrapes file paths
  from prose).

## Console background activity coverage

In Console Home, the Background Jobs activity panel lists `queued`, `running`,
and `waiting_on_user` Jobs for one selected Agent in the active tenant under the
`site_console:background_agent_jobs` `read` permission. Its query filters
activity before cursor pagination and returns owner Session and source Signal
links, status, admission timestamps, and bounded error summaries (keeping absent
summaries unknown and deferring full `task` text, results, metadata, and Turn
trajectories to the Job detail view).

Background Job health (`GET /api/v2/background-agent-jobs/health`) covers this
domain alone. Console Home renders sibling panels for
[Workflow](Workflow.md#console-activity-inspection) and
[Automation runs](AutomationJobs.md#live-activity-in-console-home) via
`/api/v2/agents/:agent_uid/background-activities` (`background-jobs`,
`workflow`, and `automation-runs`), each enforcing its own permission,
observation timestamp, and independent cursor. This area neither sums parent
Workflows, child calls, and Jobs into a single slot counter nor tracks
foreground conversation Turns, Worker OS processes, or host resource
utilization.

Separately, `GET /api/v2/console-readiness` reports four instance setup checks:
a usable LLM provider, an active Agent with a display name and role, that
Agent's required model profiles, and an available default Worker provider. The
Console header and Home page use this snapshot to link directly to missing
configuration, while Pod chat and Automation Jobs receive work through their own
domain contracts and operators configure external IM channels in Signals when
needed.

`Ankole.ModelIntegerID` enforces the shared `1000..9007199254740991` integer
bounds and canonical decimal wire format across Background Jobs and Workflows
(verified on both Worker and control plane against
`app/kernel/proto/ankole/runtime_fabric/v1/model_integer_id_vectors.json`, while
Session workspace IDs start at `10000`).

## Tests Required for Changes

Changes to this subsystem must validate these paths when their environments are
available:

- Agent Codex Home sharing and cross-Agent separation.
- Real Job cwd and model-visible path equality.
- Plugin, Skill, overlay, MCP-backed Skill, and resume behavior.
- Create, respawn, list, details, send, stop, waiting, recovery, and wakeups.
- Queued message ordering behind a deferred dispatch and ordered replay after
  admission.
- Terminal-source checks, linear respawn, exact thread and Workspace reuse, and
  missing-Workspace errors.
- Workspace save and restore: unchanged files, mode changes, deletions, left-out
  files, and drive changes against local work after the last save.
- Causal Turn lookup, bounded trajectory output, continuation, and delivery
  errors.
- Root Turn trajectory, progress, causal lookup, and recovery when runtime
  protocol metadata reports a compaction.
- The pinned Codex app-server MultiAgentV2 event contract, child routing, exact
  collaboration call projection, and child Turn completion before Job success.
- Atomic tool-result journaling and lifecycle-event completion, rollback, and
  retry behavior.
- Same-Agent cross-session waiting without notification consumption.
- Limits on reported file paths and drive checks of reply attachments.
- Worker placement, capacity, recovery, and account reuse.
- Turn stall detection, its retryable abort, its exhausted Job failure, and
  deadline rearming from storage.
- Real Deep Research and Office artifact Jobs in the Worker image.
