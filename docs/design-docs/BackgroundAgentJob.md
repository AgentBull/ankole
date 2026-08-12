# Background Agent Job

A BackgroundAgentJob records work that continues after the Agent turn that
started it. PostgreSQL stores the request, current state, and final result.
CodexRunner executes every Job.

Agent Plugins and standalone Skills give a Job more tools or instructions. They
do not create different kinds of Job.

## What the Main Agent Can Do

Each model tool performs one BackgroundAgentJob operation. A tool does not use
an `action` field to select different operations.

`list_background_jobs` is a read-only tool. Its input has only these optional
fields:

- `status`: `live` or `stop`; the default is `live`
- `page`: the turn-local `page_N` reference from the preceding page

`live` includes `queued`, `running`, and `waiting_on_user`. `stop` includes
`succeeded`, `failed`, and `stopped`.

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
`retryable`, and `codex_turn_status`. It replaces UUID-shaped tokens in system
failure diagnostics with `[internal-id]`. It does not rewrite successful results
or assistant content.
`recent_trajectory` is an `ankole_chatml` trajectory built from the latest three
stored semantic trajectory groups on the Job root thread. It does not filter
these groups by the stored Turn kind. It removes stored message IDs, maps
tool-call correlation to turn-local `call_N` aliases, and contains no cursor. It
preserves the trajectory-level `metadata.redacted` and
`metadata.content_truncated` facts. The control-plane projection sets
`content_truncated` when it must reduce selected message content to keep the
page within its byte limit. The fixed three-group selection does not set this
content flag.

With `result_offset`, the same tool accepts only a succeeded Job with a persisted
`output_text`. Use `0` for the first read. It returns `title`, `status`, the terminal
`result_ref`, and one exact UTF-8-safe `result`. This field contains `offset`,
`output_text`, and `next_offset`. The serialized tool result is at most 8,000 UTF-8 bytes. This byte
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
profile, raw model ID, provider ID, or reasoning effort.

The tool returns only the new `job_id` and its initial `queued` status.

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
first execution in actor-event queue order. For a running Job, the message
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

`last_turn_trajectory` contains at most the latest 20 trajectory groups from
that one Turn. Its serialized size is at most 24 KiB. The tool states when it
omits earlier groups. It also preserves `metadata.redacted` and
`metadata.content_truncated`; the latter remains true when Worker recording or
control-plane projection reduced message content. If the Job is still running,
the tool also states that the Job continues in the background.

`respawn_background_job` starts a new Job from one terminal Job. Its input
contains only:

- `source_job_id`: the `succeeded`, `failed`, or `stopped` Job to continue
- `message`: the new text sent verbatim as the next Codex user message

The source Job stays terminal. The new Job copies its title, resumes the exact
Codex thread, and uses the exact Job Workspace that the source Job used. The new
Job belongs to the current authorized turn and uses the current enabled Agent
Plugins, Skills, and runtime configuration. The tool returns only the new
`job_id` and its initial `queued` status.

The tool rejects a source Job that is not terminal, has no Codex thread, already
has a successor, or has no original Job Workspace directory. It does not copy a
Workspace and it does not create a replacement directory.

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

The authorized parent turn supplies the Agent, originating conversation, tool
call, and reply route. The task can use real paths inside that Agent Home.

When the parent is a cron turn, the Job reply route also freezes that cron
event's delivery targets. A terminal Job notification keeps this snapshot. The
parent Agent still handles the notification once, and SignalsGateway creates
one independent outbox intent for each target from its one final reply. Jobs
created from ordinary turns keep the existing one-target route.

Success, failure, and `waiting_on_user` write a notification for the originating
conversation. A success notification includes the final Codex response.
Stopping a Job does not send a notification.

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
- selects workers and checks turn fences
- notifies the originating conversation

Agent Computer:

- creates and uses the real Job workspace
- creates temporary runtime files
- materializes the Job's persisted runtime projection with current non-secret
  materials and credentials
- acquires the shared per-Agent `AgentCodexRuntime`
- selects the Job's projected Plugin roots and Background-eligible Skills
- starts or resumes the Job's own Codex root thread
- routes each Codex child thread to the Job that owns its parent
- reports semantic events for each Turn trajectory
- waits for routed child Turns before it commits a successful Job
- returns the final Codex result

Codex manages its thread, Plugins, Skills, hooks, collaboration, and task
execution. PostgreSQL keeps the Job record that survives process failure.

## What PostgreSQL Stores

`background_agent_jobs.id` is a PostgreSQL identity bigint that starts at
`1000` and cannot exceed JavaScript's maximum safe integer. Model tools use the
number directly. RuntimeFabric carries it as a canonical decimal string so no
JavaScript or Protobuf boundary can round it. The actor session is `job:<id>`.

The `background_agent_jobs` table stores these identity fields:

- `id`
- `agent_uid`
- `owner_session_id`
- `source_actor_event_id`
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
directly image-capable vision fallback, Plugin and Skill selection, MCP
selection, and non-secret Worker and browser parameters. Retry, continuation,
and Worker migration use those values instead of silently reading a new Agent
configuration. A respawn inherits `model_profile` but captures a new projection
from its current binding. Credentials and mutable Skill content still come from
their current owners. A Lark tenant token stays out of the Codex thread
environment: Agent Computer refreshes an execution-local file, and each
`lark-cli` command reads the current file.

Each execution intersects the projected Skills with the Agent's current
effective set. Skills with an absent `ankole-runtime` value, `any`, or
`background_job` are available. Skills with `ankole-runtime: main` are not
available to a Job. A caller cannot supply a per-Job capability override.

The projection stores logical Agent Plugin and member Skill IDs. It stores no
package hash, package bytes, overlay bytes, Hook state, or Plugin cache state.

`background_agent_job_turns` stores one runtime Turn trajectory. A trajectory is
the semantic `ankole_chatml` history selected from Codex events, not a copy of
raw app-server frames. Each Turn row stores the trajectory header. Append-only
trajectory-group rows store its messages.

A stored tool-result message keeps the stable execution mechanism in metadata.
`provider_hosted` means that the model Provider executed the tool.
`local_dynamic` means that Codex invoked a dynamic tool implemented by Ankole.
This fact distinguishes tools that have the same display name without changing
that name or storing the raw app-server frame.

New Codex root threads request experimental raw response-item notifications. The
trajectory recorder selects only collaboration `function_call` and
`function_call_output` items from those notifications. It stores one semantic
tool call and result pair in the caller Turn; it does not store the raw frame.
The pair keeps the exact V2 tool name, arguments, and output for `spawn_agent`,
`send_message`, `followup_task`, `interrupt_agent`, `list_agents`, and
`wait_agent`.

The parent-scoped `subAgentActivity` item has the same call ID as the raw
collaboration call. The recorder adds its stable child thread ID and Agent path
to the call result. The runtime also uses a `started` activity to assign the
child thread to the parent Job. Codex does not emit a child `thread/started`
notification. The runtime buffers child Turn events that arrive before the
activity and replays them after assignment. The child Turn remains the owner of
the child's work.

A thread that was created before raw notifications were enabled can resume
without the exact collaboration call. For this case, `subAgentActivity` stores a
minimal lifecycle pair with the stable child identity. An ambiguous interaction
uses `collaboration.agent_interaction`; it does not guess whether the original
call was `send_message` or `followup_task`. A matched activity enriches the raw
call pair and is not stored as a separate display item.

Each Turn also identifies its Job, attempt, Codex thread, and Codex turn. The API
rebuilds trajectory pages from the header and message groups.

The stored Turn `kind` is Worker-to-control-plane metadata. It is not a Responses
object and does not define a Job type, lead or child ownership, trajectory
visibility, causal message matching, or recovery. The Job `runtime_thread_id`
identifies the root thread. Trajectory `item_key` values identify causal inputs.
Turn status and order control recovery. The control-plane execution projection
keeps a diagnostic count of rows with `kind=compaction` for compatibility. This
count overlaps the lead and child counts and is not a count of compaction events.

## Where a Job Runs

The Agent Home uses this path:

```text
/agents/<agent-key>/
```

The first Job owns a Workspace at this path:

```text
/agents/<agent-key>/jobs/<workspace-owner-job-id>/
├── .codex/config.toml
├── .agents/skills/
├── .ankole/agent-plugins/ # Filtered package views selected by this Job
├── temp/
└── ...
```

The first Job stores its own ID in `workspace_owner_job_id`. A respawned Job
inherits this value, so every Job in the continuation chain uses the same
directory. The Job Workspace is the real process directory and Codex project
root. It must
exist as a directory and must not be a Git repository.

Ankole does not show the model a false alias for this path. The old
`/workspace` path is invalid, and Job creation rejects a task that contains it.

A Job can see other files in the same Agent Home. Job workspaces separate
current work, but they do not hide all files owned by the same Agent.

The runner sets these environment values:

```text
HOME=/agents/<agent-key>
CODEX_HOME=/agents/<agent-key>/.codex
```

Each Agent owns one active Codex app-server process through
`AgentCodexRuntime`. Each Background Agent Job owns one root thread in that
process. A parent-scoped `subAgentActivity` assigns each child thread to the
owning Job. Different Agents use different Codex Homes and different app-server
processes.

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
that Agent-wide state. It selects its persisted Plugin roots through
`thread/start.selectedCapabilityRoots`. Job turns run concurrently after this
owner finishes setup.

Each Job atomically rebuilds one stable package view from its persisted
projection and the current effective member set. This view is not an install,
cache, Hook trust, or user-config mutation. The view contains only the member
`SKILL.md` files that the Job can use. This keeps selection thread-local instead
of mutating Agent-wide `skills.config` while sibling Jobs run. A resume rebuilds
the same path before it restores the stored root.

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

The daily session-reset cron schedules one best-effort diagnostic database
maintenance call for each Agent and date boundary. The selected Worker makes
one non-blocking attempt to acquire the same per-Agent physical lock as the
app-server. A held lock means that the Agent runtime is active, so maintenance
changes nothing. If the lock is free, the Worker deletes only `logs_2.sqlite`
and its exact `-wal`, `-shm`, and `-journal` sidecars. A later cold start also
deletes those exact files while it holds the lock. The cleanup never deletes
Codex thread, goal, memory, session, configuration, or `.nfs*` files.

The cold-start lock owner atomically replaces the shared Codex runtime config
and AIGateway token before it starts app-server. A Worker that loses the lock
does not change those files. The lock command does not fork a separate holder;
it executes the sandbox process while it owns the lock, so process reaping and
lock release have one owner.

The Job's `.codex/config.toml` contains project settings, not shared Codex state.
The runner marks the exact Job path as trusted for that process.

The project config enables MultiAgentV2 and keeps
`hide_spawn_agent_metadata=true`. In the pinned Codex runtime, this option
removes optional Agent type, model, reasoning, and service-tier fields from the
spawn tool and removes the nickname from its result. It does not remove raw
collaboration calls or `subAgentActivity` notifications from app-server.

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
and runs mcporter through its terminal. Code mode remains the Codex client-side
programmatic calling path for eligible local tools. It is not the Responses API
`programmatic_tool_calling` wire type, which the pinned Codex runtime does not
consume.
Projected `web_search` and `web_fetch` calls send their semantic selectors
directly to AIGateway. A Job does not query or cache a separate web-tool catalog.

Codex built-in `web_search` follows the Job's frozen hosted-tool projection.
When the Job's provider connection declares hosted `web_search`, the project
config sets `web_search = "live"` and the provider executes that search inside
the model request. Every other Job keeps `web_search = "disabled"`. The
workspace template never decides this value.

For AIGateway, the Agent Codex Home selects the `ankole_aigateway` provider.
The Job configuration contains the real Codex model name and its supported
reasoning effort. The runner never sends a logical profile name to Codex. It
attaches the Job's exact provider and model selector, all stored provider
options, and the stored parallel-tool-call capability to each AIGateway
request. The same binding carries the main model's direct input modalities and
its optional frozen vision fallback. AIGateway applies that binding before it
resolves the provider. The frozen binding wins over conflicting Codex model,
provider-option, and reasoning-effort values. It sets `parallel_tool_calls`
from the provider capability unless Codex marks the request as Responses Lite.
It sends images to the main model only when the direct modalities permit that
input; otherwise it uses the frozen fallback to produce untrusted text.
When a persisted projection predates the modality fields, the next admission
may complete those fields only when its frozen provider ID still resolves to
the same provider type and model ID, then persists that completed binding. If
that identity cannot be proved, the legacy Job remains text-only; it never
borrows visual capability from a different model.

Worker placement selects the normal owner, and the per-Agent `flock` on the
shared Codex Home is the final cross-process exclusion boundary. An app-server
holds that lock until it exits. A second Worker that cannot acquire it reports a
retryable busy result instead of starting another process. Production storage
must provide reliable cross-host `flock`; deployment acceptance must verify
that property with two Worker Pods.

## Compose the Project AGENTS.md

Project initialization writes one `AGENTS.md` at the Job Workspace root. The
optional workspace template supplies the first part. The runner appends the
rendered Job context after it: the Agent SOUL and MISSION documents, the
durable Brain context, and the execution-context facts.

The rendered Job context can end with a `Job Guidance` section. Its body is the
shared template `app/library/templates/AGENT_JOB.md`, read from the builtin
library root in the Worker image. An empty template omits the section. The
shipped template is empty. The Codex project config sets the native subagent
wait minimum to one minute and the default to two minutes. It does not set the
maximum, so Codex keeps its default. This reduces repeated model turns after
empty waits, as tracked in [openai/codex#35259](https://github.com/openai/codex/issues/35259).
A resumed thread keeps the existing project `AGENTS.md`; the template applies
when a Job initializes its Workspace.

## Prepare Skills for Each Run

`SKILL.md` can declare one optional `ankole-runtime` value:

- An absent value or `any` permits the main Agent and Background Agent Jobs.
- `main` permits only the main Agent. Job selection and preparation skip it.
- `background_job` permits only Jobs. The main Agent receives Job routing
  guidance instead of the Skill body from `skill_view`.

The loader rejects all other values. This field controls Skill discovery and
invocation. It is not a file security boundary for a selected Agent Plugin
package.

Agent-installed Skill source uses this path:

```text
/agents/<agent-key>/installed-skills/<skill-name>/
```

Before each run, Agent Computer refreshes the selected Skill under the stable
Agent material root. Its `SKILL.md` combines the source instructions with the
current database note. The Job projects standalone Skills into
`.agents/skills`, and Codex discovers them through native project discovery.
The runner does not use the process-global `skills/extraRoots/set` method.

Initial preparation resolves all selected Skill overlays in one RuntimeFabric
batch. The control plane synchronizes the Agent Skill registry once, reads the
selected Skill rows once, and reads the overlay rows once. It rejects the whole
set when one requested Skill is missing, disabled, invalid, or duplicated.
Refreshing one changed Skill uses the same batch contract with one name.

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
2. Atomically rebuild the Job's stable package views with only those members
   and their current Skill overlays.
3. Pass those package roots to `thread/start.selectedCapabilityRoots`.

`thread/resume` restores the selected roots stored with the existing Codex
thread. The Job rebuilds those paths before resume, so a later disable removes
the member without a global config write. A Job does not call `plugin/install`,
trust Hooks, or mutate Plugin cache and user config.

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
source Job.

The control plane allows at most three running Jobs for one Agent.
It allows at most five acquired execution attempts for one Job.

The control plane increments `attempts` only after it acquires a real execution
lease.
A placement failure returns an unstarted attempt to `queued`.

A retryable worker failure waits before the next execution attempt. Job
sessions wait on a fixed ladder from one minute to two hours, so the five
attempts span some hours and a Job survives an upstream outage. Other actor
events keep a short exponential backoff, because a user waits on them.

AIGateway quota exhaustion with a known future recovery time returns the Job
to `queued` and releases its Worker assignment until that time. The acquired
execution attempt stays consumed. A stale or missing recovery time uses the
fixed Job retry ladder instead of immediate dispatch.

An internal RuntimeFabric handler failure is retryable only for a turn-scoped
read. Its durable error keeps the control-plane `failure_id`. Domain rejections,
turn writes, and turn completion stay terminal because their effect or commit
outcome cannot be repeated safely.

One control-plane transaction stores the final state and the notification.
If a worker disappears, the control plane dispatches the Job again.

For a terminal result, Agent Computer commits the Job status before it cleans
the Job thread, materialized files, and runtime lease. A cleanup failure after
that durable commit is an operational warning. It does not reopen or retry a
model Turn that can already have external effects.

An old worker process can briefly overlap the replacement. The turn fence
rejects later writes from the old process.

A Worker heartbeat and its activation lease only prove that the Worker process
is alive. Codex can stop producing runtime notifications while the Worker keeps
renewing both, which leaves the Job `running` and its Turn `in_progress` until
the deployment ends. The Turn row's own `updated_at` is the one clock that moves
only on real runtime progress, so it owns stall detection. Each Turn checkpoint
arms one deadline for its Job, and the control plane rearms every deadline from
storage on start and on each sweep.

One hour without a durable Turn checkpoint counts as a stall. The budget covers
the longest legitimate silence, which is one model call that the AIGateway
already fails after five minutes, or one foreground tool call. A delegated child
Turn keeps its own row, so its checkpoints keep the Job clock alive while the
lead Turn waits for it.

A stall aborts the attempt exactly like a reported Worker failure: it supersedes
the runtime fences, fails the activation, interrupts the stalled runtime Turns,
and leaves the actor event open on the retry ladder. The control plane also
sends the Worker a best-effort turn control so the abandoned Turn stops spending
tokens and returns its turn slot. The third stall of one Job is not retryable
and fails the Job with the stall cause, so a Job that only stalls cannot retry
forever. A Job without a live activation is left to the activation and Worker
deadlines, which already own that recovery.

If Codex cannot resume its thread, one attempt can create one replacement
thread. The replacement reads the Job files and receives a short history of
earlier attempts.

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

The dispatch event targets this actor session:

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
stores the source ID in `continued_from_job_id`, the inherited root ID in
`workspace_owner_job_id`, the inherited logical profile name in
`model_profile`, and the new message in `task`. It does not inherit the source
runtime projection. It resolves the current profile binding at its own first
execution admission.

`continued_from_job_id` is unique. One terminal Job can have only one direct
successor, so two live Jobs cannot write to the same Codex thread and Workspace.
A retry from the same parent tool call returns the existing successor. A
different request for a source that already has a successor fails and identifies
that successor.

Agent Computer checks that the inherited Workspace is a real directory before
it sends the respawn request. CodexRunner checks it again before execution. A
missing directory is an error; neither path creates or copies one. CodexRunner
resumes the stored thread and sends `task` as the first user message of the new
Job. A respawned Job fails if Codex cannot resume that thread; it does not
replace the thread.

## Send a Message and Wait for Its Turn

Sending a message writes a `command.steer` ActorEvent. Its ActorEvent ID is the
causal message ID. CodexRunner passes this ID to Codex as
`clientUserMessageId`. The trajectory recorder stores the same ID as
`client:<event-id>`. These facts let the control plane find the one Codex Turn
that received the message without a waiter table or a resident waiter process.

A queued message does not replace or mutate `job.task`. Background Agent Job
sessions execute open ActorEvents in `queue_sequence` order when no Turn is
live. A deferred dispatch therefore blocks later messages until the dispatch
can start. After the control plane sends that Turn, it replays the stored
messages into the activation in queue order. This keeps one Job identity and
one durable input path without a queued-only update operation.
RuntimeEvents rebuilds the Job session timer from that same queue head after a
control-plane restart. Ordinary actor sessions still use their earliest due
event and can bypass an older event that is not due.

A running Codex Turn receives the text through `turn/steer`. A Job in
`waiting_on_user` starts a new Turn on the same Codex thread with the message as
its answer.

The send request uses the source tool-call ID as its stable ActorEvent source
key. A retry of the same parent Turn returns the existing command event and does
not send the message twice.

When `wait_reply=true`, Agent Computer reads the persisted result once per
second. The foreground observation window defaults to 30 seconds and is
bounded to 10–150 seconds. This is not a Job execution timeout. On expiry the
Job remains durable and continues running. A new parent steer wakes the wait
immediately without consuming the steer; the normal agent-loop boundary records
the tool result and then applies and acknowledges that steer.

After a new worker Turn is committed and sent, the control plane immediately
drains already-persisted `command.steer` events into that activation. The
ordinary ready-event wakeup handles steering that arrives later. Periodic
recovery is therefore a fallback, not the correctness path for the short gap
between replacing a delivery and starting its successor.

Codex must produce a lead runtime notification within 60 seconds after
`turn/start` succeeds. Missing first progress is a retryable runtime failure;
it cannot leave a Job indefinitely `running` merely because the Worker process
continues to emit generic heartbeats.

The result is ready when the causal Turn is terminal and the Job has committed
`waiting_on_user`, `succeeded`, `failed`, or `stopped`. It is also ready when a
newer lead Codex Turn proves that the Job continued after the causal Turn. A
terminal trajectory with a `running` Job and no newer lead Turn is not ready;
this rule covers the short interval between trajectory storage and Job-state
commit. A completed, stopped, or dead-letter command that never appears in a
trajectory returns a delivery error.

Background Codex gives child agents `request_parent_input`, not
`request_user_input`. A child sends its question to the lead agent.

`request_parent_input` ends the current Codex turn, changes the Job to
`waiting_on_user`, and notifies the parent. The control plane records
`request_user_input` as the internal event code.

The main Agent answers through `send_message_to_background_job`. The message is
ordinary text. There is no separate answers map.

## Hand Off a Lifecycle Notification

Success, failure, and `waiting_on_user` still create an open lifecycle
ActorEvent for the originating conversation. The waiting tool can consume that
event only after it records its tool result in the AIGateway history.

Agent Computer attaches the lifecycle ActorEvent ID to an internal tool-result
field. This field is not model-visible. AIGatewayLink validates the authenticated
subject, current parent ActorEvent, target session, event type, Job, attempt,
and open state. It then writes the idempotent tool-result journal and completes
the lifecycle event in one PostgreSQL transaction. If journal storage fails or
is quarantined, the transaction rolls back and the lifecycle event stays open.
A retry reads the same journal and verifies the completed event IDs.

The tool does not attach a lifecycle event ID when it does not wait, returns an
error, is canceled, observes a continuing Job, or runs from another session.
The open lifecycle event then follows the normal wakeup path. Another session
in the same channel can send a message and wait for its Turn, but it cannot
consume the notification owned by the originating session.

## Return Results and Files

Success requires a nonempty Codex final response.
The result also includes the stable Job Workspace path.

The result can list paths in these fields:

- `files_changed`
- `artifacts`
- `artifact_roots`

Each field contains `total_count`, `paths`, and `truncated`. It keeps at most
32 paths and 8 KiB of serialized path data.

Artifacts are ordinary Job files. They do not have a separate lifecycle.

An outbound attachment must exist in the current Agent `user-files` directory.
The caller must copy or move the file there before delivery.
The caller must provide a structured attachment record. Ankole never searches
prose for an outbound file path.

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
- Causal Turn lookup, bounded trajectory output, continuation, and delivery
  errors.
- Root Turn trajectory, progress, causal lookup, and recovery when runtime
  protocol metadata reports a compaction.
- The pinned Codex app-server MultiAgentV2 event contract, child routing, exact
  collaboration call projection, and child Turn completion before Job success.
- Atomic tool-result journaling and lifecycle-event completion, rollback, and
  retry behavior.
- Same-channel cross-session waiting without notification consumption.
- Limits on reported file paths and `user-files` attachment checks.
- Worker placement, capacity, recovery, and account reuse.
- Turn stall detection, its retryable abort, its exhausted Job failure, and
  deadline rearming from storage.
- Real Deep Research and Office artifact Jobs in the Worker image.
