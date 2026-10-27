# Background Agent Job

A BackgroundAgentJob records work that continues after the Agent turn that
started it. PostgreSQL stores the request, current state, and final result.
CodexRunner executes every Job.

Agent Plugins and standalone Skills give a Job more tools or instructions. They
do not create different kinds of Job.

## What the Operator Console Can Do

The Console Job board lists the newest matching Jobs in the selected tenant.
Its optional Agent filter and search combine. Search matches an exact
Job ID or a case-insensitive title fragment before the 100-row page limit is
applied, so an older matching Job is not hidden by newer unrelated work.
The board reads the `console_list` read action of the Job resource through the
Console JSON:API (`GET /api/v2/background-agent-jobs`, arguments `agent_uid`,
`status`, and `search`), ordered by queue time and then Job ID, with keyset
pagination (`page[limit]`, `page[after]`). The action reads only the board
columns and the calculated `duration_seconds`. The Job detail is the JSON:API
record (`GET /api/v2/background-agent-jobs/:id`). The generic actions
`console_cancel` and `console_complete` (`POST …/:id/cancel`, `…/:id/complete`)
record the Console Principal (the Ash actor) as the operator and stop the live
Turn after the commit. A missing Job is not found (404); completing a failed or
stopped Job is a conflict (409, `background_agent_job_terminal`).
The background activity list keeps its opaque cursor: it carries a version, the
list parameters that it belongs to, and the keyset of the last row, so a cursor
of another list or of an earlier format is rejected. The
`list_background_jobs` tool reads the `list_for_agent` action the same way.

The Job detail shows the runtime Turn trajectory in bounded pages. The
trajectory is a typed read model of the Turns and their items. The Job Ash
domain exposes it through JSON:API
(`GET /api/v2/background-agent-jobs/:job_id/turns`). The first page holds the
newest Turns. Each page contains at most 20 semantic item groups within 24 KiB,
and the pager walks back into the older history. A Turn that recorded no
readable item still appears on its page with its status and error.

## What the Main Agent Can Do

Each model tool performs one BackgroundAgentJob operation. A tool does not use
an `action` field to select different operations.

`list_background_jobs` is a read-only tool. Its input has only these optional
fields:

- `status`: `live` or `stop`; the default is `live`
- `page`: the turn-local `page_N` reference from the preceding page

`live` includes `queued`, `running`, and `waiting_on_user`. `stop` includes
`succeeded`, `failed`, and `stopped`.

The current Agent owns the list. `owner_session_id` and `reply_route` select
notification and delivery targets. They do not limit Job access to the session
or channel that created it.

The tool returns at most 32 Jobs. It orders them by `updated_at` descending and
then by `id` descending. Each item contains only `job_id`, `title`, the concrete
Job `status`. The page also contains `next_page`. Its value is `null` when no
older Job is available.

`show_background_job_details` is a read-only tool. Its input contains `job_id`
and an optional stable UTF-8 byte `result_offset`. Without `result_offset`, it returns
`title`, the concrete Job `status`, the terminal
`result_ref` when one exists, attempt counts, compact
attempt history, the current Turn status, thread and Turn counts, aggregate
progress, latest usage, the execution update time, a current error summary, and
`recent_trajectory`. Turn counts use runtime thread ownership and do not expose
the stored Turn kind. The error projection keeps only `code`, `summary`,
`retryable`, and `codex_turn_status`. It uses the Job error when available;
otherwise, it uses the current Turn error from the current attempt. A stored
Codex `message` supplies the summary when no `summary` exists. Attempt history
uses the same message source for failed Turns, even when no tool ran or assistant
text was produced. The projection replaces UUID-shaped tokens in system
failure diagnostics with `[internal-id]`. It does not rewrite successful results
or assistant content.
Aggregate progress keeps `tool_execution_mechanisms` for calls whose execution
boundary is meaningful. Each entry contains an optional `namespace`, the tool
`name`, `provider_hosted` or `local_dynamic`, and the call count. This compact
fact survives trajectory pagination, so the parent Agent does not infer the
mechanism from tool prose.
`recent_trajectory` is an `ankole_chatml` trajectory built from the latest three
semantic item groups on the Job root thread. It does not filter
these groups by the stored Turn kind. It removes stored message IDs, maps
tool-call correlation to turn-local `call_N` aliases, and contains no cursor. It
preserves the trajectory-level `metadata.redacted` and
`metadata.content_truncated` facts. The control-plane projection sets
`content_truncated` when it must reduce selected message content to keep the
page within its byte limit. The fixed three-group selection does not set this
content flag.

With `result_offset`, the same tool accepts only a succeeded Job with a persisted
`output_text`. Use `0` for the first read. It returns `title`, `status`, the terminal
`result_ref`, `workspace_owner_job_id`, the result's `project_path`, `artifacts`,
and `artifact_roots`, and one exact UTF-8-safe `result`. This field contains `offset`,
`output_text`, and `next_offset`. The path fields repeat on every chunk so a reader
in a later Turn or another session locates the Job's real files, including the
Workspace that a continued Job inherits, without deriving a directory from the
Job id. The path fields take at most 2,000 bytes of each chunk: the Workspace
path always stays, discovery roots are dropped first and then artifacts from the
end, and a shortened list keeps its `total_count` and sets `truncated`, so the
output window always has room to advance. The serialized tool result is at most 8,000 UTF-8 bytes. This byte
limit keeps the result below the 10,000-token model-visible tool-output limit,
including JSON escaping. Concatenating the segments in order reconstructs the
persisted final response exactly. A later Turn can resume from the same offset
because a succeeded result is immutable. The Control Plane returns only a bounded
window instead of transferring the full persisted result. This field does not
change the bounded completion notification.

`create_background_job` creates one durable Job. Its input contains only:

- `title`: required management and display text; Codex does not receive it
- `task`: required text sent verbatim as the first Codex user prompt
- `model_profile`: an optional custom model profile from the current Agent's
  TurnStart catalog; omission uses `coding`
- `workspace_template_id`: an optional enabled workspace template applied only
  when Agent Computer first creates the Job Workspace

The tool schema contains an enum of the Agent's configured custom profiles. It
omits `model_profile` when the catalog is empty. It never accepts a fixed
profile, raw model ID, provider ID, or reasoning effort. The tool description
tells the Agent to omit `model_profile` unless the human asks for a custom
profile by name, and that the default is the Agent's standard model for the
work. A custom profile description must say what the profile is for.

The tool returns only the new `job_id` and its initial `queued` status.

The tool description states the Job's capability boundary. A Job cannot create
a Job or load a `main` Skill, so the delegating Agent creates every Job that
the work needs. It does the steps of a `main` Skill itself and gives a Job only
the task that the Skill defines.

`send_message_to_background_job` sends one message to an existing Job. Its
input contains only:

- `job_id`: the target Job
- `message`: the text to send to Codex
- `wait_reply`: whether to wait for the Codex Turn that receives this message;
  the default is `true`
- `wait_timeout_ms`: the foreground observation window when `wait_reply=true`;
  the default is 30,000, the minimum is 10,000, and the maximum is 150,000

The tool accepts every live Job: `queued`, `running`, or `waiting_on_user`. For
a queued Job, the message stays behind the original dispatch and enters the
first execution in Signal queue order. For a running Job, the message
steers the active Codex Turn. For a waiting Job, the message answers the request
and resumes the same Codex thread. The tool rejects a terminal Job.

With `wait_reply=false`, the tool returns `job_id` and the current concrete
status immediately after it stores the message. With `wait_reply=true`, the
tool observes the exact Codex Turn until its result is ready, a new parent steer
arrives, the parent Turn is canceled, or `wait_timeout_ms` expires. A steer or
deadline ends only foreground observation. It never retracts or resends the
already stored message and it never stops the Job.

A ready result returns `job_id`, the current concrete status,
`last_turn_trajectory`, `earlier_trajectory_omitted`, `continues_running`,
`reply_ready=true`, and `wait_outcome=reply_ready`. A deadline or steer returns
`reply_ready=false`, `wait_outcome=timed_out|steered`, the current status, and
whether the Job continues running. The parent records that tool result before
applying queued steering to its next model input.

`last_turn_trajectory` contains at most the latest 20 semantic item groups from
that one Turn. Its serialized size is at most 24 KiB. The tool states when it
omits earlier groups. It also preserves `metadata.redacted` and
`metadata.content_truncated`; the latter remains true when Worker recording or
control-plane projection reduced message content. If the Job is still running,
the tool also states that the Job continues in the background.

An ambient channel route can append the same `command.steer` without a model
tool call. It may target only one live Job from the same Agent, owner Session,
signal channel, and binding. The control plane rechecks those facts and the
ambient scene, appends the steer, stores the canonical ambient judgment, and
advances the channel cursor in one transaction. The steer contains only the
new channel messages; it does not include earlier context, private memory, or
the recognizer reason.

`respawn_background_job` starts a new Job from one terminal Job. Its input
contains only:

- `source_job_id`: the `succeeded`, `failed`, or `stopped` Job to continue
- `message`: the new text sent verbatim as the next Codex user message

The source Job stays terminal. The new Job copies its title, resumes the exact
Codex thread, and uses the exact Job Workspace that the source Job used. When
the native thread state is gone, the Job continues through the thread
replacement ladder described under Turn recovery. The new Job belongs to the
current authorized turn and uses the current enabled Agent Plugins, Skills, and
runtime configuration. The tool returns only the new `job_id` and its initial
`queued` status.

The tool rejects a source Job that is not terminal, has no Codex thread, already
has a successor, or has no original Job Workspace, neither on this Worker nor in
the drive. It does not copy a Workspace and it does not create a replacement
directory.

`stop_background_job` accepts only `job_id`. It changes `queued`, `running`, or
`waiting_on_user` to `stopped`. A terminal Job is an idempotent no-op. The tool
returns only `job_id` and the concrete status. The Console can keep an operator
stop reason, but the model tool does not accept one.

Before a Job becomes `succeeded`, Agent Computer waits until each active Turn in
the routed root and child thread tree is terminal. When a Job becomes
`succeeded`, `failed`, or `stopped`, the same transaction changes each remaining
active Turn in the current attempt to `interrupted`. A completed lead Turn stays
completed, so a successful Job keeps its result trajectory and every terminal
child trajectory.

The authorized parent turn supplies the Agent, tool call, and reply route. The
task can use real paths inside that Agent Home. Creation itself pins the
originating conversation on every path: it resolves the owner session's active
AIGateway conversation, creates one when none exists, and writes its id into
`metadata.owner_conversation_id`. The Job runtime reads that field to resolve
its conversation context, so a control-plane-created Job and the successor Job
that open steers seed get a conversation without a calling turn.

For a Pod source Conversation, the execution context includes the source
Page ID and Pod delivery instructions. The control plane derives both from
the Conversation owner. The Worker passes those instructions to the Job's
developer instructions, including resumed Jobs. Research reports default to
editable Pod Pages; explicit file formats and other source channels retain
their delivery rules.

A Workflow task turn can also create a Job. The Job then records the
`wf_task:<call_id>` session as its owner, so every lifecycle wakeup —
completed, failed, or waiting — wakes the sleeping task instead of the main
Agent's session, and the task shapes the outcome into its Workflow result. A
run that reaches a terminal status stops the live Jobs its task sessions own.
See [Workflow](Workflow.md).

A Job retains the turn-local webhook and automation management CLIs. These
long-lived resources use `Conversations.Route` to follow the persisted Job and Workflow
owner chain to the originating Agent Session. Their callbacks do not target
the Job or task that created them. This recipient resolution does not change
the Job lifecycle wakeup described above, the calling Signal, or its
`WorkAccess` authorization. A missing or inconsistent owner fails creation
before a resource is stored.

When the parent is a cron turn, the Job reply route also freezes that cron
event's delivery targets. A terminal Job notification keeps this snapshot. The
parent Agent still handles the notification once. Sessions.Presentation commits
one native Message or external Delivery intent per target from its final reply. Jobs
created from ordinary turns use a one-target route.

Success, failure, and `waiting_on_user` write a notification for the originating
conversation. A success notification includes the final Codex response.
Stopping a Job does not send a notification. The parent turn for a terminal
notification always ends with a visible reply.

Brain Skill reflection Jobs use an empty reply route and an Agent-owned
execution Session. Success queues lesson application in the terminal-commit
transaction; these internal Jobs complete without conversation delivery.

A waiting notification gives the parent only each question's header, text,
secret flag, and labeled choices. Codex thread, turn, item, question, and option
IDs remain in Job metadata for resume and do not enter the parent prompt.

## Which Process Does What

The Elixir control plane:

- stores Job and Job Turn rows
- checks authorization and stores the reply route
- changes Job state and counts attempts
- dispatches, steers, stops, and completes Jobs
- checks the optional workspace template
- validates the requested custom Model Profile or selects `coding`
- resolves the logical profile at first execution admission
- places or adopts Codex Turns through `Sessions.JobDriver` and checks
  the Job attempt fence
- notifies the originating conversation

Agent Computer:

- creates and uses the real Job workspace
- creates temporary runtime files
- materializes the Job's persisted runtime projection with current non-secret
  materials and credentials
- acquires the shared per-Agent `AgentCodexRuntime`
- selects the Job's current Background-eligible Skills and Skill-owned MCP servers
- starts or resumes the Job's own Codex root thread
- routes each Codex child thread to the Job that owns its parent
- reports semantic events for each Turn trajectory
- waits for routed child Turns before it commits a successful Job
- returns the final Codex result

Codex manages its thread, collaboration, and task execution. Ankole owns Skill
selection and loading, and `AgentCodexRuntime` owns Plugin installation and Hook
trust. PostgreSQL keeps the Job record that survives process failure.

## Human Work Authorization

Each Job stores `authorization_kind`, `human_uid`, and `human_access_version`
from its authenticated source under [Human Offboarding](HumanOffboarding.md).
The creation and respawn paths read the current source Signal. Worker
recovery retains the original authorization. Brain's independent reflection
caller supplies its Agent as the trusted `created_by` source.

The control plane checks authorization before creation, dispatch admission,
and a new resume or retry. Revocation stops queued and waiting Jobs after any
admitted Codex turn finishes. It does not interrupt that turn or discard its
result. Child work keeps the source Human even when it uses Agent credentials.

## What PostgreSQL Stores

`background_agent_jobs.id` is a PostgreSQL identity bigint that starts at
`1000` and cannot exceed JavaScript's maximum safe integer. Model tools use the
number directly. RuntimeFabric carries it as a canonical decimal string so no
JavaScript or Protobuf boundary can round it. The Session is `job:<id>`.

The `background_agent_jobs` table stores these identity fields:

- `id`
- `agent_uid`
- `owner_session_id`
- `source_signal_id`
- `source_tool_call_id`
- `reply_route`
- `continued_from_job_id`
- `workspace_owner_job_id`

It stores these request fields:

- `title`
- `task`
- `model_profile`, which is always `coding` or a custom logical profile name

It stores `runtime_thread_id` as its execution identity.

It stores one optional `workspace_template_id`.
It stores one typed `runtime_projection` at first execution admission. The same
PostgreSQL transaction that admits the first attempt writes the projection when
it is absent. It also stores status, attempts, timestamps, result, error, and
metadata.

A Job does not store provider credentials. Its runtime projection stores the
resolved provider, model, effort, options, direct input modalities, optional
directly image-capable vision fallback, Plugin and Skill selection, and
non-secret Worker and browser parameters. Retry, continuation,
and Worker migration use those values instead of silently reading a new Agent
configuration. A respawn inherits `model_profile` but captures a new projection
from its current binding.
The reserved `native_mcp_servers` field is currently empty. Each execution
resolves MCP dependencies from the selected Skills' current content.
Credentials and mutable Skill content still come from their current owners. A
Lark tenant token stays out of the Codex thread environment: Agent Computer
refreshes an execution-local file, and each `lark-cli` command reads the current
file.

Each execution intersects the projected Skills with the Agent's current
effective set. Skills with an absent `ankole-runtime` value, `any`, or
`background_job` are available. Skills with `ankole-runtime: main` are not
available to a Job. A caller cannot supply a per-Job capability override.

The projection stores logical Agent Plugin and member Skill IDs. It stores no
package hash, package bytes, overlay bytes, Hook state, or Plugin cache state.

`background_agent_job_turns` stores one runtime Turn trajectory. A trajectory is
the semantic `ankole_chatml` history selected from Codex events, not a copy of
raw app-server frames. Each Turn row stores the trajectory header.

The Worker ships one content stream per Turn: sanitized semantic thread items
with their positions and item keys. Append-only `background_agent_job_turn_items`
rows store that stream, and they are the one storage and read-path owner of
Turn content: every trajectory reader projects `ankole_chatml` messages from
the stored items at read time. An item whose projection is empty stays stored
for thread replay. A Turn with no item
rows returns an empty trajectory, and its thread falls back to the Workspace rebuild
below when replay finds no items.

A stored tool-result message keeps the stable execution mechanism in metadata.
`provider_hosted` means that the model Provider executed the tool.
`local_dynamic` means that Codex invoked a dynamic tool implemented by Ankole.
The call and result keep `namespace` separate from the leaf `name`. This fact
distinguishes tools that have the same leaf name without changing their
identity or storing the raw app-server frame.

New Codex root threads request experimental raw response-item notifications. The
trajectory recorder selects only collaboration `function_call` and
`function_call_output` items from those notifications. It stores one semantic
tool call and result pair in the caller Turn; it does not store the raw frame.
The pair keeps `namespace: collaboration`, the exact V2 leaf name, arguments,
and output for `spawn_agent`, `send_message`, `followup_task`,
`interrupt_agent`, `list_agents`, and `wait_agent`.

Each stored collaboration call states its `arguments_source`.
`raw_function_call` means that the raw `function_call` item carried the
arguments. In code mode the model calls the collaboration tools inside the
JavaScript executor and no raw `function_call` exists. The recorder then pairs
the activity with the child thread's raw `agent_message` item: its payload
part holds the plaintext brief, and the recorder stores it as
`arguments.message` (with `target` for an interaction) with source
`child_initial_input`. Activities and inputs of one child thread arrive in the
same order on both sides, so the recorder pairs them first-in first-out in
either arrival order, before or after the child's own `turn/started`. A call
whose child input has not arrived when its Turn ends, or before a flush, is
stored with empty arguments and source `activity_fallback`.

The parent-scoped `subAgentActivity` item has the same call ID as the raw
collaboration call. The recorder adds its stable child thread ID and Agent path
to the call result. The runtime also uses a `started` activity to assign the
child thread to the parent Job. Codex does not emit a child `thread/started`
notification. The runtime buffers child Turn events that arrive before the
activity and replays them after assignment. The child Turn remains the owner of
the child's work.

The app-server transport checks every JSON-RPC line before parsing, including
complete lines and the final line without a newline. The limit is 64 MiB of
wire bytes. Unowned thread notifications share bounds of 256 messages and
64 MiB of serialized UTF-8. These are protocol and retention bounds, not heap
size guarantees. Crossing either notification bound ends and reaps this
Agent's app-server through the runtime-loss path. It does not discard
completion events and continue with an incomplete view of the thread tree.

The Job session serializes ordinary lead-Turn completions and deduplicates them
by thread and Turn ID. A retry may finish in the same app-server output batch
as its start response; its completion waits for the preceding recovery rather
than being discarded. Explicit compaction completion resolves its handshake
immediately, outside that serial order, because recovery waits for it before
starting the retry. These rules preserve the recovery budgets.

A thread without raw notifications can resume
without the exact collaboration call. For this case, `subAgentActivity` stores a
minimal lifecycle pair with the stable child identity. An ambiguous interaction
uses `collaboration.agent_interaction`; it does not guess whether the original
call was `send_message` or `followup_task`. A matched activity enriches the raw
call pair and is not stored as a separate display item.

The Turn resource owns checkpoint and interruption transitions through Ash
state-machine actions. A checkpoint update matches the stored revision and
status. It must advance the revision, and a terminal Turn can only retain its
terminal status. The first observed checkpoint can already be terminal. Bulk
interruption advances each active revision once and removes its active item in
the same SQL update. Late Worker snapshots cannot overwrite this outcome.
Checkpoint actions validate the canonical header, bounded progress, and official
usage fields. Native constraints enforce the state and completion-time relation.

The recorder keeps the Job and Turn locks while it validates an identical
checkpoint retry and appends its items. TurnItem exposes only an append action;
its position and semantic item key remain unique within the Turn. A conflict
rolls back the checkpoint and its items together. Content truncation merges its
marker into the stored header without replacing other metadata.

Each Turn also identifies its Job, attempt, Codex thread, and Codex turn. The API
rebuilds trajectory pages from the header and the messages that the stored
items project.

The stored Turn `kind` is Worker-to-control-plane metadata. The Worker sets
`kind=compaction` only on the Turn that its own `thread/compact/start` request
creates. A compaction that Codex runs automatically inside an agent Turn stays a
`contextCompaction` item of that agent Turn. The kind does not change after the
Worker records the Turn. It is not a Responses
object and does not define a Job type, lead or child ownership, trajectory
visibility, causal message matching, or recovery. The Job `runtime_thread_id`
identifies the root thread. Trajectory `item_key` values identify causal inputs.
Turn status and order control recovery. The control-plane execution projection
keeps a diagnostic count of rows with `kind=compaction`. This count overlaps the
lead and child counts and is not a count of compaction events.

## Where a Job Runs

The Agent Home uses this path:

```text
/workspace/
```

The first Job owns a Workspace at this path:

```text
/workspace/jobs/<workspace-owner-job-id>/
├── .codex/config.toml
├── AGENTS.md
├── temp/
└── ...
```

The first Job stores its own ID in `workspace_owner_job_id`. A respawned Job
inherits this value, so every Job in the continuation chain uses the same
directory. The Job Workspace is the real process directory and Codex project
root. It must
exist as a directory and must not be a Git repository. The directory is on
persistent Home and survives Worker replacement.

Agent Home is `/workspace`. The entrypoint links
`/agents/<agent_uid>` to it so persisted task paths under that prefix resolve
to Home.

A Job can see other files in the same Agent Home. Job workspaces separate
current work, but they do not hide all files owned by the same Agent.

The runner sets these environment values:

```text
HOME=/workspace
CODEX_HOME=/workspace/.codex
CODEX_SQLITE_HOME=/var/cache/ankole/codex
```

Home and Codex thread files are persistent. SQLite is a cache; Codex can
resume from thread files after this cache is lost. See
[Agent Workers](AgentWorkers.md).

Plugin packages and their local marketplace are rebuildable Codex runtime
files under the Codex Home. Codex also discovers
`$HOME/.agents/plugins/marketplace.json`; a marketplace with the same name
there would take over the Plugin IDs. The install check therefore selects the
Worker marketplace by its path and fails with the path of each other
marketplace.

The Worker owns one Codex app-server process for its Agent through
`AgentCodexRuntimeManager`; the process starts with the first Job lease and
closes after the last one. Each Background Agent Job owns one root thread in
that process. A parent-scoped `subAgentActivity` assigns each child thread to
the owning Job.

When a Job tree is removed, the runtime keeps retired child thread IDs until the
app-server exits. If Codex reports a late child whose parent is retired, the
runtime interrupts and unsubscribes that child. A late child cannot become an
unowned thread while another Job keeps the shared app-server alive.

A durable root thread is different. A later retry or respawn can explicitly
reclaim that same root after the prior owner finishes cleanup. The runtime
serializes cleanup, new-root registration, resume registration, and late
retired-thread cleanup by thread ID. Registration happens before Codex resume
events can arrive. A stale cleanup cannot retire or unsubscribe a root after a
new Job owns it. A failed resume restores a reclaimable root tombstone, while
child tombstones stay closed.

`AgentCodexRuntime` serializes app-server initialization, official Plugin
installation, Hook trust, Plugin cache changes, and Codex user-config changes.
It installs and trusts all same-release packages before it starts the first Job
thread, then leaves every global Plugin entry disabled. A Job never mutates
that Agent-wide state or gives Codex a native Skill root. Ankole intersects the
Job's persisted selection with the current effective catalog, renders the
ordinary Skill index in `AGENTS.md`, and exposes full Skill content through its
dynamic `skill_view` tool. The runner prepares MCP configuration separately
from the selected Skills' dependencies. Job turns run concurrently after the
serialized runtime setup finishes.

The last Job lease closes app-server input, gives the process a bounded clean
exit period, and reaps it before the runtime owner is removed. It sends a kill
only when the clean exit does not finish. There is no idle TTL. A stopped queued
Job completes finalization and returns its Worker turn slot without waiting for
a Job-local Plugin setup because no such setup exists.

The pinned Codex app-server can spend tens of seconds maintaining
`logs_2.sqlite` before it
answers `initialize`. Agent Computer records a slow-start diagnostic at 60
seconds and uses a 300-second hard timeout. After initialization, it installs a
SQLite trigger that drops only `TRACE`, `DEBUG`, and `INFO` diagnostic records.
The trigger is a temporary compatibility fix for
[openai/codex#27741](https://github.com/openai/codex/issues/27741), based on the
filter in
[codex-logs-trigger-patch](https://github.com/yangtzech/codex-logs-trigger-patch/blob/main/patch_codex_logs.sh).
It keeps `WARNING` and higher records and does not change the journal mode.

Cold start deletes only `logs_2.sqlite` and its `-wal`, `-shm`, and
`-journal` sidecars while it holds the lock. Other Codex files remain.

The cold-start lock owner atomically replaces the shared Codex runtime config
and AIGateway token before it starts app-server. A Worker that loses the lock
does not change those files. The lock command does not fork a separate holder;
it executes the Codex app-server process while it owns the lock, so process
reaping and lock release have one owner.

The Job's `.codex/config.toml` contains project settings, not shared Codex state.
The runner marks the exact Job path as trusted for that process.

The project config enables MultiAgentV2 by default and keeps
`hide_spawn_agent_metadata=true`. In the pinned Codex runtime, this option
removes optional Agent type, model, reasoning, and service-tier fields from the
spawn tool and removes the nickname from its result. It does not remove raw
collaboration calls or `subAgentActivity` notifications from app-server.
MultiAgentV2 is an operator reliability choice, not a runner safety invariant:
a workspace template that sets `features.multi_agent_v2.enabled` keeps its own
value, so an operator can hold a Job to single-Agent execution.

The project config also sets `features.multi_agent_v2_dynamic_tools = true`.
The pinned Codex gives a child thread the parent's dynamic tools only behind
this feature gate. Without it a child sees only the native tools and cannot
call `skill_view`, `web_fetch`, `web_search`, or `request_parent_input`. The
Ankole tools are part of the Job contract for every thread, so this flag is a
runner invariant that a workspace template cannot turn off. The running-status
metadata records `child_dynamic_tools_inherited` and `code_mode` from the
effective thread configuration. The host integration test
`codex-dynamic-tools-inheritance` starts a thread with dynamic tools, has the
Provider reply with `spawn_agent`, and checks that the child's model request
declares every dynamic tool that the lead received.

Agent-level configuration owns worker and provider defaults, Plugin and Skill
availability, and safety choices. The Job runtime projection records the
effective non-secret snapshot at first execution admission; callers cannot set
per-Job capability overrides. The frozen model and reasoning values are the
Job's execution binding. Agent Computer supplies MCP-backed Skill dependencies
through an invocation-scoped `MCPORTER_CONFIG`, not through Codex project
configuration.

Job preparation removes `mcp_servers` from workspace project configuration.
No bundled native MCP server is currently installed. If a concrete capability
adds one, Codex must own the Background connection and expose it through native
MCP. Agent Computer must not project an `mcp__` namespace through dynamic tools.
See [MCP-backed Skills](MCPBackedSkills.md#model-visible-mcp-boundary).

Agent Computer enables Codex native code mode for each Job. Code mode gives a
Job one isolated JavaScript executor that can call eligible local tools,
but MCP-backed Skills do not enter that tool registry. A Job follows the Skill
and runs mcporter through its terminal. Code mode is the Codex client-side
programmatic calling path for eligible local tools. It is not the Responses API
`programmatic_tool_calling` wire type, which the pinned Codex runtime does not
consume. The JavaScript global can combine the namespace and leaf name, but the
runtime keeps the structured identity beside that local binding.
Projected `web_search` and `web_fetch` calls send their semantic selectors
directly to AIGateway. A Job does not query or cache a separate web-tool catalog.

### Code-mode tool registry

Code mode exposes exactly the dynamic tools that Agent Computer declares to the
Codex thread. The model calls them as `tools.<name>` in the JavaScript
executor; a tool that is not in this registry does not exist for the Job, and
a hosted tool that AIGateway would execute inside the Response does not enter
it. The Job projection (`buildCodexJobProjection`) admits only these names:

| Tool | Executor | Condition |
| --- | --- | --- |
| `web_search` | `Ankole.Sessions.Tools.Web` through `tools.read` | Omitted when the Job's provider connection declares hosted `web_search` |
| `web_fetch` | `Ankole.Sessions.Tools.Web` through `tools.read`, with the Worker rendered fallback | Always |
| `skill_view` | `Ankole.Sessions.Tools.Skill` through `tools.read` | Always |
| `recall` | `Ankole.Sessions.Tools.Brain` through `tools.read` | The turn start carries its declaration in `request_context.brain_tools`, which the control plane fills while `brain.enabled` is true |
| `get_page` | `Ankole.Sessions.Tools.Brain` through `tools.read` | Same as `recall` |
| `request_parent_input` | The Worker lead-thread guard and the control plane wait | Always declared; only the lead thread may call it |

Every registered tool is read-only from the Job's point of view. The Brain
write operations, the browser tools, and the foreground-only tools never enter
the registry. The control plane owns each read tool's contract and result.
For the Brain tools, `Ankole.Sessions.Tools.Brain.declarations/0` is the one
schema owner: `TurnEnvelope` puts those declarations (name, description, JSON
schema, activity) into `request_context.brain_tools`, the Worker declares them
to Codex unchanged, and `ReadToolBroker` validates each call against the same
declaration. The Worker Brain tool is only the RPC codec. Child threads that
a Job spawns inherit the same registry, so a child calls `skill_view`, the
web tools, and the Brain read tools directly instead of reporting the need to
the lead.

Codex built-in `web_search` follows the Job's frozen hosted-tool projection.
When the Job's provider connection declares hosted `web_search`, the project
config sets `web_search = "live"` and the provider executes that search inside
the model request. Agent Computer omits its dynamic `web_search` in this case,
so the model cannot silently select the local path instead. Every other Job
keeps `web_search = "disabled"` and receives the dynamic tool. The workspace
template never decides this value. The dynamic `web_fetch` remains available
in both cases. AIGateway model cards disable Responses Lite because the pinned
Codex omits configured hosted search from that private carrier. Standard
Responses sends the native `web_search` declaration.

For AIGateway, the Agent Codex Home selects the `ankole_aigateway` provider.
Its configured name is `OpenAI`, which tells the pinned Codex runtime that this
hop can carry remote compaction. The provider ID does not change. Every Job uses
that one protocol: Codex appends `compaction_trigger` to a normal Responses
request and AIGateway answers it.

Whether AIGateway answers with its own summary or forwards the trigger to the
Provider is the `upstream` field of the instance `ai_gateway.compaction`
settings, not a Job setting, and it is read per request.
The Job config sets no `model_auto_compact_token_limit`, so Codex applies its
own nine tenths of the model window and the AIGateway ratio triggers first.

The Job configuration contains the real Codex model name and its supported
reasoning effort. The runner never sends a logical profile name to Codex. It
attaches the Job's exact provider and model selector, all stored provider
options, and the stored parallel-tool-call capability to each AIGateway
request. The same binding carries the main model's direct input modalities and
its optional frozen vision fallback. AIGateway applies that binding before it
resolves the provider. The frozen binding wins over conflicting Codex model,
provider-option, and reasoning-effort values. A bound request also removes the
Codex-only `internal_chat_message_metadata_passthrough` and
`encrypted_function_args` fields. It sets `parallel_tool_calls` from the
provider capability unless Codex marks the request as Responses Lite. It sends
images to the main model only when the direct modalities permit that input;
otherwise it uses the frozen fallback to produce untrusted text.

When the instance leaves compaction to the Provider, AIGateway tries the Job's
frozen Responses Provider and model before it uses local compaction.
Unsupported and transient failures use local compaction. A provider-native
compact output is opaque. If a later compact request cannot use the same
upstream path, AIGateway keeps the opaque items verbatim, summarizes only the
readable items after them, and logs a warning, so the Job's compaction
completes instead of failing. The preserved Provider state still reads only on
a compatible Provider on later turns.

Each Agent has one Worker, so every Job of an Agent runs in that Worker's one
app-server. The `flock` on the Codex Home is the final exclusion boundary: an
app-server holds the lock until it exits, and a second process that cannot
acquire it reports a retryable busy result instead of starting another
app-server on the same Codex Home.

## Compose the Project AGENTS.md

Project initialization writes one `AGENTS.md` at the Job Workspace root. The
optional workspace template supplies the first part. The runner appends the
rendered Job context after it: the Agent SOUL and MISSION documents, and the
execution-context facts.

When the Job has a source channel, its context names the conversation's drive
directory. The Job must save files that it needs to keep or deliver in that
directory. The workspace is
temporary. The Job must not read or write another conversation's workspace or
drive directory. A Job without a source channel uses the shared drive.

The rendered Job context includes the ordinary Skill index. A Skill with
`brain-recall-only: true` stays out of the index and is discoverable through
Brain. The Codex project config sets the native subagent wait minimum to one
minute and the default to ten minutes. The maximum uses the Codex default.
These durations cover Job subtasks that take minutes and limit repeated model
turns during a wait; see [openai/codex#35259](https://github.com/openai/codex/issues/35259).
A resumed thread keeps its project `AGENTS.md`.
The runner also gives Codex these drive rules as developer instructions. After
it resumes a native thread, it adds the current instructions to the thread with
`thread/inject_items`. This keeps the rules in the model context without
rewriting the project documents.

## Prepare Skills for Each Run

`SKILL.md` can declare one optional `ankole-runtime` value:

- An absent value or `any` permits the main Agent and Background Agent Jobs.
- `main` permits only the main Agent. Job preparation leaves it out of the
  Job's Skill index and MCP configuration.
- `background_job` permits only Jobs. The main Agent receives Job routing
  guidance instead of the Skill body from `skill_view`.

The loader rejects all other values. This field controls Skill discovery and
invocation. It is not a file security boundary for a selected Agent Plugin
package.

Agent-installed Skill source uses this path:

```text
/workspace/installed-skills/<skill-name>/
```

Before each run, Agent Computer derives the loadable Skill set by intersecting
the frozen Job selection with the Agent's current effective Skills and the
`ankole-runtime` rule. The Job's Ankole `skill_view` tool reads the selected
source file through the same confined loader as the main Agent, adds the current
database lesson to `SKILL.md`, and records the Skill as used. A result that
contains Skill content states the `ankole-runtime` value of the Skill. It rejects a
disabled Skill, a selected Skill for another runtime, and any path outside that
Skill. Codex native project discovery, `.agents/skills`, and `skills/list` do
not own Ankole Skills.

## Prepare Agent Plugins for Each Run

Agent Plugins use the standard `.codex-plugin/plugin.json` manifest.
The optional `workspace-template` initializes the Job Workspace once.

`AgentCodexRuntime` performs Agent-wide setup before the first Job thread:

1. Refresh stable Agent package material for every trusted same-release Plugin.
2. Install every package through official Codex `plugin/install`.
3. Verify installation and trust package Hooks through Codex.
4. Set every global installed Plugin entry to disabled.

Each Job preparation performs only thread-owned selection:

1. Intersect the persisted Plugin and member selection with the current
   effective catalog.
2. Add the Background-eligible members to the Ankole `skill_view` load set and
   the non-lazy Skill index.
3. Project any enabled Skill-owned MCP servers separately.

A Job does not pass Plugin Skill roots to Codex. A later disable removes the
member from the loader, and an active Job receives the disable notice.
A Job does not call `plugin/install`, trust Hooks, or mutate Plugin cache and
user config.

Enabling a Plugin does not create another Skill path or Job runner. See
[Plugins](Plugins.md) for package and enabled-state rules.

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

The message tool stores input for any live Job. It cannot resume a terminal
Job. Respawning a terminal Job creates a new queued Job and never changes the
source Job. The Job resource declares each allowed transition with
`AshStateMachine`, and this declaration is the only transition table. Each
lifecycle step runs one declared transition action. The state machine rejects
a transition that the action does not declare, and the domain reason of the
rejection is `{:invalid_status_transition, from, to}`. The action accepts
only the fields that it owns. Status reports cannot change authorization,
ownership, runtime configuration, or attempt counters. Unknown fields fail
validation before the write. A terminal Job cannot return to `queued` or
`running`.
The Job resource supplies status sets and status casts. The Console query, list,
and detail schemas share one status projection from this declaration. Worker
wait clocks use the resource's atomic actions. Turn schemas also read their enum
from the Turn resource, and the Turn state machine decides each checkpoint
transition.

The transition action is the only discriminator of a status commit.
`worker_report` takes its target from the reported status; a report without a
status fails with `background_agent_job_status_missing`. `external_complete`,
`fail_admission`, `fail_turn`, `requeue`, `stop`, and `stop_human_work` have a
fixed target. Only a `worker_report` success seeds a steer successor.
`external_complete` answers open steers with its own wakeup, and
`external_complete` and `fail_admission` do not require a closed lead Turn.

Each operation that changes more than one row runs in
`Repo.transact_top_level/2`: `create_with_dispatch`, `respawn_with_dispatch`,
`request_stop`, `request_complete`, `send_message`, `commit_status_with_wakeup`
(whose `after_commit` wakes the Job driver), `upsert_turn_from_worker`,
`complete_signal`, `WorkerWait.resolve_timeout`, and the lock phase of
`TurnWatchdog.reconcile_stuck_job`. Each operation owns its transaction and
must be the top-level call. Another domain composes these steps
inside its own operation through `BackgroundAgentJobs` composition functions.
`admit_attempt_in_tx/4` checks admission authority, then locks the Worker, Agent
slots, and Job before it checks capacity, persists Worker wait state, and claims
or adopts an attempt. The Session caller supplies a preparation check that runs
under the Job lock before slot reservation. `abort_attempt_in_tx/4` authorizes
the attempt, then locks its Turns, Sessions, and Signal before it settles the
input and compensates the Job. `fail_admission_in_tx/3` commits an admission
failure and its parent wakeup. Session and Signal admission share the caller's
transaction with these steps. Action rejection runs before SQL and does not
roll back the enclosing transaction. `CodexJob.abort` can therefore
commit its Signal settlement and owner wakeup after a rejected transition.
Worker authorization reads the input under the locked Job and attempt fence;
the mutation locks its input after Turn and Session locks. A successful Turn
reserves any steer successor identity before it locks Signals, so the new
Job's Session lock joins the current and owner Session locks in sorted order.
This domain reads Signal rows only through the Signals code interface and the
Signals composition functions.

The `agent_computer.background_agent_job.max_running_per_agent` setting caps how
many Jobs of one Agent run at once, with a default of three. One Job spends at
most five execution failures and at most twenty-five total claims, so
interruptions that never became execution failures cannot consume the task's own
budget.

The control plane increments `attempts` only when it claims a real Worker
slot. Adoption of a running attempt does not claim or count again.
New attempts use the shared [Worker readiness rule](AgentWorkers.md#new-attempt-readiness).
Admission supplies the locked Worker and the Agent's Job-capacity result. It
persists the returned start in `worker_wait_started_at`. The Job resource uses
atomic clock updates, including requests from an older snapshot. Repeated waits
and repeated clears do not change the stored update time.

A wait enqueues a durable wakeup 30 seconds later without consuming an attempt.
The result supplies `retry_at` to the Driver timer. The Signal keeps its business
deadline in `available_at`; admission checks that deadline and the queue head
again under lock before it commits a wait or resolves a readiness timeout.
An unavailable Worker keeps the Worker-readiness wake reason even when the
Agent's Job capacity is full. When the Agent's Worker becomes ready,
`JobDriver` wakes immediately on `{:worker_changed, uid}` and admits the oldest
open Signal without waiting for that 30-second timer. If the shared rule returns
`timed_out`, a `queued` Job fails with `agent_worker_unavailable`
and dead-letters its dispatch Signal, while a `waiting_on_user` Job stays in
`waiting_on_user`, clears `worker_wait_started_at`, dead-letters the steer
Signal, and sends `background_agent_job.input_undeliverable` to the owner
Session.

The Worker stops local execution when acceptance or progress confirms that
the attempt changed or the run closed. A connection failure alone does not
stop it. After the control plane accepts a newer attempt, the Worker stops
and cleans the older local attempt before it resumes the same Codex thread.
This recovery does not depend on receipt of the best-effort retry control.
When the Worker has no free slot, a newer attempt of a Job whose older
attempt still holds a slot takes over that slot instead of a `worker_busy`
rejection; the older attempt is retired before the newer one executes, and
the slot returns to the older attempt if the control plane refuses the newer
one first. When a third attempt has already taken the refused attempt's slot,
the refused attempt passes its own donor on to that third attempt instead, so
one slot stays accounted to exactly one live attempt across the chain.

A retryable worker failure waits before the next execution attempt.
Infrastructure interruptions retry within minutes and never consume the
execution-failure budget, while provider-capacity failures and other execution
failures use a ladder that spans hours so a Job survives an upstream outage. The
control plane classifies the failure once for every retry owner. A
provider-capacity failure is a retryable failure whose kind is `server` or
`rate_limit`, or a credential pool exhaustion. The `details_json.retryable`
value is authoritative over the nested AIGateway value, and an explicit `false`
is never provider capacity. The ordinary actor Turn reads the same
classification but keeps its own shorter ladder, because a user waits on it.

Worker `socket_closed`, `runtime_fabric_timeout`, and `runtime_rpc_timeout`
failures use the infrastructure account. A generic `timeout` does not. Safe
reads first recover within their original caller and deadline after rejoin;
classification applies when an attempt actually needs to return to the queue.
An unanswered write can already have completed and is not repeated by the
generic RPC layer.

Context overflow consumes no execution-failure budget, because that path
compacts the context and retries instead of failing the task.

A Provider status that rejects the request itself is terminal for the Job.
Agent Computer reads that status before Codex stream-disconnect wording, so a
permanent rejection does not consume local Turn retries or return the Job to
`queued`. Transport, authorization, rate-limit, and server-capacity failures
keep their bounded recovery, because AIGateway rotates its credential pool and
a later attempt can reach a healthy credential or a recovered upstream.

A retry runs on the Agent's one Worker. A replacement mounts the same Home,
so the retry uses the Job Workspace and resumes the Codex thread
from its persistent file.

AIGateway quota exhaustion with a known future recovery time returns the Job
to `queued` until that time. The acquired
execution attempt stays consumed and the attempt charges no execution-failure
budget. A stale or missing recovery time is an ordinary provider-capacity
failure: the Job returns to `queued` on the fixed Job retry ladder and the
attempt charges the execution-failure budget.

An Agent [token quota](AgentTokenQuota.md) rejection is terminal for the Job.
Creation and admission do not check the quota; the first rejected request ends
the Job turn with `agent_token_quota_exceeded`, and the Job fails with that
code. It does not return to `queued` and does not wait for the next period.

An internal RuntimeFabric handler failure is retryable only for a turn-scoped
read. Its durable error keeps the control-plane `failure_id`. Domain rejections,
turn writes, and turn completion stay terminal because their effect or commit
outcome cannot be repeated safely.

One control-plane transaction stores the final state and the notification.
After commit, the caller delivers the notification to the owner Session.
If unapplied steers create a successor, the caller also delivers its dispatch
event. External completion delivers both the owner notification and any stop
command for the running Job. An outer transaction must deliver its returned
events after commit; a rollback must not wake a Driver.
If a worker disappears, the control plane dispatches the Job again.

For a terminal result, Agent Computer commits the Job status before it cleans
the Job thread, materialized files, and runtime lease. A cleanup failure after
that durable commit is an operational warning. It does not reopen or retry a
model Turn that can already have external effects.

A replacement instance waits until the previous instance is gone. The Turn
fence also rejects late control-plane writes from an earlier attempt.

A Worker heartbeat proves only that the Worker process is alive. Codex can
stop producing runtime notifications while the Worker keeps reporting capacity.
`TurnWatchdog` reads the latest in-progress Turn checkpoint for the current
attempt. Before the first Turn exists, it uses the Job's `updated_at`.

One hour without durable progress counts as a stall. A delegated child has its
own Turn row, so its checkpoints keep the Job clock alive while the lead waits.
Worker heartbeats do not move this clock. The Oban sweep checks it;
there is no activation lease or separate deadline process.

A stall interrupts the current attempt's Turns through the Job owner, leaves
retryable input open, and sends a best-effort retry control to stop the old
Worker execution. The third stall fails the Job with its cause. The attempt
fence rejects late commits from the abandoned execution.

### Persistent thread files

Codex writes each thread under `/workspace/.codex/sessions/`. The file contains
conversation items, reasoning content, and compaction references. Codex can
resume by thread ID without its old SQLite database. Old files can be
compressed as `.jsonl.zst`; Codex reads both forms. The Worker does not archive
these threads.

The Job Workspace and thread files survive instance deletion and image
replacement through the provider's persistent storage. No thread-segment table,
RPC, or workspace-checkpoint copy is involved. A crash can leave an incomplete
last line; recovery resumes the complete prefix and can repeat work after it.
PostgreSQL Turn items remain the audit and display record, not the normal
thread recovery source. Cloudflare's backup timing has the storage limits
listed in [Agent Workers](AgentWorkers.md#cloudflare).

### Replacement threads

If Codex cannot resume its thread, one attempt can create one
replacement thread:

1. Replay, only for a Job marked `legacy_thread_replay`. The Worker pages the
   stored lead-thread turn items of the Job's workspace lineage over
   `background_agent_job.turn_items.list`, converts them back to wire response
   items, and injects them into a fresh thread. Each replayed `function_call`
   restores its stored `namespace` and `name` as separate fields. An app-server
   restart during a deployment cannot turn a namespaced tool into a root tool.
   Codex re-compacts when the replayed history exceeds the model window. The
   Job metadata records `runtime_checkpoint_recovery: replayed_from_transcript`.
2. Workspace rebuild. For a Job without `legacy_thread_replay`, or when replay has no items
   or fails, the fresh thread starts from the Job task, the
   durable Workspace, and a short history of earlier attempts. A continued Job
   also receives its source Job's task and final report from the source row.
   The metadata records
   `runtime_checkpoint_recovery: new_thread_from_bounded_history`.

Both outcomes are disclosed, bounded to one replacement per attempt, and apply
to first-turn resume and to a thread lost inside a running attempt alike.
The first successful runtime anchor clears `legacy_thread_replay`. Continued
Jobs inherit it only while it remains set.

## Create and Dispatch a Job Once

Start uses this idempotency key:

```text
{agent_uid, owner_session_id, source_tool_call_id}
```

A new request validates the selected logical Model Profile. Omission validates
`coding` and its `heavy` fallback. An explicit value must name a configured
custom LLM profile; it cannot name `coding`, another fixed profile, or a raw
model. An unavailable custom profile fails without fallback. One transaction
inserts both the Job and its dispatch event. The first real execution admission
captures the resolved runtime projection and model binding in the Job row.

The dispatch event targets this Session:

```text
{agent_uid, "job:<job-id>"}
```

Every stored Job Session ID uses the `job:` prefix. Repeating the same start
request returns the original Job and event.

Each Job Turn uses its persisted AIGateway provider binding. Jobs for one Agent
can use different provider rows without changing the shared Codex Home or
adding a filesystem lock.

## Respawn a Terminal Job Once

Respawn uses the same parent-turn idempotency key as create:

```text
{agent_uid, owner_session_id, source_tool_call_id}
```

The control plane locks the source Job and accepts only `succeeded`, `failed`,
or `stopped`. The source must have a Codex thread and a Workspace owner. One
transaction inserts the new queued Job and its dispatch event. The new Job
stores the source ID in `continued_from_job_id` and the new message in `task`.
`Ankole.BackgroundAgentJobs.Schemas.Job.successor_attrs/2` owns what a
successor copies from its source, for a manual respawn and for a steer
successor alike. The inherited fields are:

- `title`
- `runtime_thread_id`
- `workspace_owner_job_id`
- `workspace_template_id`
- `model_profile`

The whole continuation chain resumes one Codex thread inside the Workspace of
the first Job, which that Job built from the template, so each successor keeps
the template identity. Agent Computer materializes a template only for a Job
without a stored thread, so a successor never rebuilds it. The
`legacy_thread_replay` metadata marker follows the source. A successor does
not inherit the source runtime projection, result, error, attempts, or
`managed_background_agent_job_root`; it resolves the current profile binding at
its own first execution admission. The Console Job detail projects
`continued_from_job_id` and `workspace_owner_job_id` with the other identity
fields.

`continued_from_job_id` is unique. One terminal Job can have only one direct
successor, so two live Jobs cannot write to the same Codex thread and Workspace.
A retry from the same parent tool call returns the stored successor. A
different request for a source that already has a successor fails and identifies
that successor.

Agent Computer checks that the inherited Workspace is a real directory in
persistent Home before it sends the respawn request. CodexRunner checks it
again before execution; a missing inherited directory is an error, and neither
path creates one. CodexRunner resumes the stored thread and sends `task` as
the first user message of the new Job. When Codex
cannot resume that thread, the respawned Job takes the same replacement ladder
as any lost thread, ending with the disclosed Workspace rebuild seeded with the
source Job's task and final report.

## Send a Message and Wait for Its Turn

Native Human instructions are resolved from the causal input and its consumed
steers, separately from the main Agent's delegated task. The source Message
establishes Human identity; the corresponding Signal retains the exact input
version. Editing the visible Message puts the revised text into a new retry
Signal without rewriting the original input. Queued, unconsumed messages do not
become current Job instructions.

Page creation provenance follows the original Job source. Current execution
intent follows a newer applied Human request, including completion wakes and
continued Jobs. A persisted `client:<signal-id>` steer receipt advances the
control plane's reserved `applied_source_signal_id` metadata in the same fenced
transaction. Worker metadata cannot set or clear that reference, and an older
main Agent summary cannot reset it. Recovery after that durable receipt uses the
applied request. The external Codex ACK and the subsequent database receipt are
not an atomic transaction; an unrecorded steer remains open for replay.

Sending a message writes a `command.steer` Signal. Its Signal ID is the
causal message ID. CodexRunner passes this ID to Codex as
`clientUserMessageId`. The trajectory recorder stores the same ID as
`client:<event-id>`. These facts let the control plane find the one Codex Turn
that received the message without a waiter table or a resident waiter process.

A queued message does not replace or mutate `job.task`. Background Agent Job
sessions execute open Signals in `queue_sequence` order when no Turn is
live. A deferred dispatch therefore blocks later messages until the dispatch
can start. After start or adoption, the Driver sends unapplied messages in
queue order. Due Oban `EnsureDriver` jobs and the conversation Reconciler recover
that queue after process loss. Ordinary conversations can use a later due event
when an older event is not yet due.

A running Codex Turn receives the text through `turn/steer`. A Job in
`waiting_on_user` starts a new Turn on the same Codex thread with the message as
its answer.

The send request uses the source tool-call ID as its stable Signal source
key. A retry of the same parent Turn returns the stored command event and does
not send the message twice.

When `wait_reply=true`, the parent Session Driver reads the persisted
result once per second. The foreground observation window defaults to 30 seconds and is
bounded to 10–150 seconds. This is not a Job execution timeout. On expiry the
Job remains durable and continues running. A new parent steer wakes the wait
immediately without consuming the steer. The Driver records the tool result
and injects the steer at its next model boundary.

After a Codex Turn starts or is adopted, the Driver immediately sends stored
`command.steer` events. Later inbox wakes send new messages through the same
mailbox owner. Worker deduplication uses each event ID.
The mailbox locks Human authorizers before the Session and Signal rows. It
checks the locked Signal's authorization against its snapshot before admission.
Revoked fresh input becomes terminal without reaching the Worker.

Codex must produce a lead runtime notification within 60 seconds after
`turn/start` succeeds. Missing first progress is a retryable runtime failure;
it cannot leave a Job indefinitely `running` merely because the Worker process
emits generic heartbeats.

The result is ready when the causal Turn is terminal and the Job has committed
`waiting_on_user`, `succeeded`, `failed`, or `stopped`. It is also ready when a
newer lead Codex Turn proves that the Job continued after the causal Turn. A
terminal trajectory with a `running` Job and no newer lead Turn is not ready;
this rule covers the short interval between trajectory storage and Job-state
commit. A completed, stopped, or dead-letter command that never appears in a
trajectory returns a delivery error.

If a succeeded commit finds open steer events outside the terminal Turn's
`applied_signal_ids`, the same transaction creates one successor with
those messages in order and completes the events. The terminal status commit
consumes the applied IDs with the Job state and parent notification. If the successor cannot be stored,
the transaction fails and leaves the source Job and unapplied steer events
unchanged. A failed, stopped, or external completion answers open steers with
the terminal notification instead.

The successor continues the source Job's Codex thread on the Agent's one
Worker: it resumes the thread from persistent Codex Home. When the thread
cannot resume,
the successor starts a [replacement thread](#replacement-threads) that carries
the source Job's task and final report, and its metadata discloses that.

Background Codex gives child agents `request_parent_input`, not
`request_user_input`. A child sends its question to the lead agent.

`request_parent_input` ends the current Codex turn, changes the Job to
`waiting_on_user`, and notifies the parent. The control plane records
`request_user_input` as the internal event code.

The main Agent answers through `send_message_to_background_job`. The message is
ordinary text. There is no separate answers map. The main Agent answers a
question itself when the conversation, a loaded Skill, or its tools give the
answer. When a question shows that the Job cannot do its task as written, the
main Agent sends the Job a task that it can do, or stops the Job and does the
work in a different way. It relays to the user only a question that needs the
user's decision, approval, or information.

## Hand Off a Lifecycle Notification

Success, failure, and `waiting_on_user` create an open lifecycle
Signal for the originating conversation. The waiting tool can consume that
event only after it records its tool result in the AIGateway history.

Agent Computer attaches the lifecycle Signal ID to an internal tool-result
field. This field is not model-visible. AIGatewayLink validates the authenticated
subject, current parent Signal, target session, event type, Job, attempt,
and open state. It then writes the idempotent tool-result journal and completes
the lifecycle event in one PostgreSQL transaction. If journal storage fails or
is quarantined, the transaction rolls back and the lifecycle event stays open.
A retry reads the same journal and verifies the completed event IDs.

The tool does not attach a lifecycle event ID when it does not wait, returns an
error, is canceled, observes a continuing Job, or runs from another session.
The open lifecycle event then follows the normal wakeup path. Another session
of the same Agent can send a message and wait for its Turn, but it cannot consume
the notification owned by the originating session.

## Return Results and Files

Success requires a nonempty Codex final response. A phased assistant message
must have `phase: final_answer`. Commentary and partial answers stay in the Turn
trajectory and cannot become the Job result. When `phase` is missing or null,
under the pinned Codex protocol contract the last lead message is a candidate
only until the lead thread starts another work item (a command, file change,
tool call, or collaboration item; an automatic compaction is not work), and a
new lead Turn clears the previous candidate. If no final report is present, the same thread gets one
report request before the Job fails with `codex_empty_report`.
The result also includes the stable Job Workspace path.

Main compares each Job's reported outcomes and deliverables with the user's
overall goal and current instructions. It reuses reported verification and
continues concrete missing work before claiming completion. It does not start
a generic verification Job for work already covered by the report.
For a continuation, Main states the unmet outcome without an unverified
reconstruction of saved state. The continued Job checks and reuses its earlier
tool-returned IDs before it creates more content. An incomplete report does
not show that saved work is absent.

The result can list paths in these fields:

- `files_changed`
- `artifacts`
- `artifact_roots`

Each field contains `total_count`, `paths`, and `truncated`. It keeps at most
32 paths and 8 KiB of serialized path data.

`files_changed` unites two sources, and `files_changed_source` names each one
that contributed. `codex_diff` is the aggregate `turn/diff/updated` stream,
which lists only the files that Codex tools changed. `workspace_snapshot` is a
comparison of the Job Workspace before the attempt's first Turn and after the
lead Turn tree is idle; it lists the files that a shell command or a child
thread added, changed, or removed. The snapshot skips the root `AGENTS.md` and,
at any depth, the directories `.codex`, `.ankole`, `.git`, `.venv`, `venv`,
`__pycache__`, `browser`, `build`, `dist`, `node_modules`, `target`, and
`temp`. A scan stops above 50,000 files or two seconds; the result then keeps
only the Codex diff and lists `workspace_snapshot_skipped` as a source. A
change that keeps the same size and modification time is not visible to the
snapshot.

Artifacts are ordinary Job files. They do not have a separate lifecycle.

An outbound attachment must be a file in the Agent's drive. `reply_attachment`
accepts only `drive_path` and records the file's current digest. A file under
`chats/<channel_id>/` can be delivered only to that channel (see [Files](Files.md)).
The caller must provide a structured attachment record. Ankole never searches
prose for an outbound file path.

## Console background activity coverage

The Home background activity area reads queued, running and waiting-on-user Jobs
for one selected Agent in the current tenant. It uses the
`site_console:background_agent_jobs` `read` permission, owner Session and source Signal links,
native status, admission timestamps and bounded error summaries. Its query
filters activity before cursor pagination and does not load task text, result
bodies, metadata or Turn trajectories; the Job detail is the
inspection surface for those facts. An absent error summary stays unknown.

The Background Job health metrics describe this domain only. The
activity area separately displays [Workflow](Workflow.md#console-activity-inspection)
and [Automation runs](AutomationJobs.md#live-activity-in-console-home), with their
own permissions, observation times and page cursors. The three JSON:API reads
are under `/api/v2/agents/:agent_uid/background-activities`: `background-jobs`,
`workflow`, and `automation-runs`. The aggregation action calls each owning
domain query in the active tenant. Job health uses
`GET /api/v2/background-agent-jobs/health`. Console readiness uses
`GET /api/v2/console-readiness` and reports four runtime setup facts: a usable
LLM provider, an active Agent with a display name and role, the Agent's required
model profiles, and an available default Worker provider. The Console header
and home page use this snapshot to link to configuration. Pod chat and
Automation jobs receive work through their own domain contracts; operators
configure external message channels in Signals when they use those channels.
These transport reads keep the domain's admission and observation rules.
The area does not total parent
Workflow rows, child calls and delegated Jobs as execution slots, and it does not
cover all conversation Turns, Worker processes or resource utilization.

`Ankole.ModelIntegerID` owns the shared `1000..9007199254740991` bounds and
canonical decimal wire parsing. Workflow IDs use the same contract. Worker
and Control Plane checks use the vectors in
`app/kernel/proto/ankole/runtime_fabric/v1/model_integer_id_vectors.json`.
Session workspace IDs use a lower bound of `10000`.

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
