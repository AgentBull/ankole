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

`show_background_job_details` is a read-only tool. Its input contains only
`job_id`. It returns `title`, the concrete Job `status`, attempt counts, compact
attempt history, a current error summary, and `recent_trajectory`. The error
projection keeps only `code`, `summary`, `retryable`, and `codex_turn_status`.
It replaces UUID-shaped tokens in system failure diagnostics with
`[internal-id]`. It does not rewrite successful results or assistant content.
`recent_trajectory` is an `ankole_chatml` trajectory built from the latest three
stored semantic trajectory groups. It removes stored message IDs, maps tool-call
correlation to turn-local `call_N` aliases, and contains no cursor.

`create_background_job` creates one durable Job. Its input contains only:

- `title`: required management and display text; Codex does not receive it
- `task`: required text sent verbatim as the first Codex user prompt
- `workspace_template_id`: an optional enabled workspace template applied only
  when Agent Computer first creates the Job Workspace

The tool returns only the new `job_id` and its initial `queued` status.

`send_message_to_background_job` sends one message to an existing Job. Its
input contains only:

- `job_id`: the target Job
- `message`: the text to send to Codex
- `wait_reply`: whether to wait for the Codex Turn that receives this message;
  the default is `true`

The tool accepts only a `running` or `waiting_on_user` Job. For a running Job,
the message steers the active Codex Turn. For a waiting Job, the message answers
the request and resumes the same Codex thread. The tool rejects a queued or
terminal Job.

With `wait_reply=false`, the tool returns `job_id` and the current concrete
status immediately after it stores the message. With `wait_reply=true`, the
tool waits for the exact Codex Turn that receives the message. It then returns
`job_id`, the current concrete status, `last_turn_trajectory`,
`earlier_trajectory_omitted`, and `continues_running`.

`last_turn_trajectory` contains at most the latest 20 trajectory groups from
that one Turn. Its serialized size is at most 24 KiB. The tool states when it
omits earlier groups. If the Job is still running, the tool also states that the
Job continues in the background.

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

When a Job becomes `succeeded`, `failed`, or `stopped`, the same transaction
changes each active Turn in the current attempt to `interrupted`. A completed
lead Turn remains completed, so a successful Job keeps its required result
trajectory without leaving active child Turns behind.

The authorized parent turn supplies the Agent, originating conversation, tool
call, and reply route. The task can use real paths inside that Agent Home.

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
- resolves the Agent's current `coding` Model Profile for each worker Turn
- selects workers and checks turn fences
- notifies the originating conversation

Agent Computer:

- creates and uses the real Job workspace
- creates temporary runtime files
- prepares all current enabled Agent Plugins and Skills that permit Background
  Agent Jobs
- starts or resumes the Codex app server
- reports semantic events for each Turn trajectory
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

It stores `runtime_thread_id` as its execution identity.

It stores one optional `workspace_template_id`.
It also stores status, attempts, timestamps, result, error, and metadata.

A Job does not store a second copy of its Model Profile or provider
credentials. A new or respawned Job verifies that the effective `coding` Model
Profile exists before it stores the request. The existing `heavy` fallback
applies when `coding` is absent. Each worker Turn then resolves the current
profile and sends its model, provider selector, provider options, context
length, and parallel-tool-call capability in `model_ref`. This lets an
operator repair a queued or retried Job by changing the Agent profile.

Each execution and resume reads the Agent's current enabled Skills. Skills with
an absent `ankole-runtime` value, `any`, or `background_job` are available.
Skills with `ankole-runtime: main` are not available to a Job. A Job does not
store or accept a per-Job Skill selection.

The Job stores no Agent Plugin selection, package hash, or member Skill state.
Each run loads all Agent Plugins currently enabled for the Agent.

`background_agent_job_turns` stores one runtime Turn trajectory. A trajectory is
the semantic `ankole_chatml` history selected from Codex events, not a copy of
raw app-server frames. Each Turn row stores the trajectory header. Append-only
trajectory-group rows store its messages.

Each Turn also identifies its Job, attempt, Codex thread, and Codex turn. The API
rebuilds trajectory pages from the header and message groups.

## Where a Job Runs

The Agent Home uses this path:

```text
/agents/<agent-key>/
```

The first Job owns a Workspace at this path:

```text
/agents/<agent-key>/jobs/<workspace-owner-job-id>/
├── .codex/config.toml
├── .ankole/skills/
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

Overlapping Jobs for one Agent share ordinary Codex state. Agent Computer
serializes Plugin installation, hook trust, and Skill configuration for that
Agent's Codex Home. Job execution stays concurrent after this setup finishes.
Different Agents use different Codex Homes. A stopped queued Job completes
finalization and returns its Worker turn slot without waiting for active setup.
Its skipped queue position keeps later Jobs behind setup that is still active.

The Job's `.codex/config.toml` contains project settings, not shared Codex state.
The runner marks the exact Job path as trusted for that process.

Agent-level configuration contains stable worker and provider defaults. Job
configuration contains model, reasoning, Plugin, and safety choices. Agent
Computer supplies MCP-backed Skill dependencies through an invocation-scoped
`MCPORTER_CONFIG`, not through Codex project configuration.

Release-defined Direct MCP servers use a different projection. Agent Computer
lists their live catalogs and gives Codex deferred dynamic namespace tools.
Agent Computer executes the selected child through its MCP client and returns
text, image content, and artifact paths. It does not write these servers to
Codex project `mcp_servers` or the Skill mcporter config. See
[Direct MCP Tools](DirectMCPTools.md).

Agent Computer enables Codex native code mode for each Job. Code mode gives a
Job one isolated JavaScript executor that can call eligible local tools,
but MCP-backed Skills do not enter that tool registry. A Job follows the Skill
and runs mcporter through its terminal. Code mode remains the Codex client-side
programmatic calling path for eligible local tools. It is not the Responses API
`programmatic_tool_calling` wire type, which Codex 0.146 does not consume.

For AIGateway, the Agent Codex Home selects the `ankole_aigateway` provider.
The Job configuration contains the real Codex model name and its supported
reasoning effort. The runner never sends `coding` to Codex. It attaches the
Job's exact provider and model selector, all stored provider options, and the
stored parallel-tool-call capability to each AIGateway request. AIGateway
applies that binding before it resolves the provider. It sets
`parallel_tool_calls` from the provider capability unless Codex marks the
request as Responses Lite.

NFS makes the same files visible to several workers. It does not lock an Agent
or coordinate SQLite. Worker placement keeps one Agent's live work on one ready
worker. The Codex Home setup queue is process-local and uses that placement
contract.

## Compose the Project AGENTS.md

Project initialization writes one `AGENTS.md` at the Job Workspace root. The
optional workspace template supplies the first part. The runner appends the
rendered Job context after it: the Agent SOUL and MISSION documents, the
durable Brain context, and the execution-context facts.

The rendered Job context ends with a `Job Guidance` section. Its body is the
shared template `app/library/templates/AGENT_JOB.md`, read from the builtin
library root in the Worker image. The template carries deployment-wide
execution guidance for every Job; the current content gives the model the
turn-cost model and the long-blocking-wait contract for subagent coordination.
A missing or empty template only removes the section. A resumed thread keeps
the existing project `AGENTS.md`; the template applies when a Job initializes
its Workspace.

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

Before each run, Agent Computer rebuilds `.ankole/skills`. A Skill without a
database note becomes a symlink to its source directory.

A Skill with a database note becomes a Job-local copy. Its `SKILL.md` combines
the source instructions with that note.

Agent Computer gives Codex the real directory through `skills/extraRoots/set`.

## Prepare Agent Plugins for Each Run

Agent Plugins use the standard `.codex-plugin/plugin.json` manifest.
The optional `workspace-template` initializes the Job Workspace once.

Each preparation performs these actions:

1. Resolve the current enabled Plugin IDs against the catalog.
2. Read each same-release local manifest and its member Skill paths.
3. Refresh the rebuildable package copies.
4. Apply current Skill overlays.
5. Install and enable selected packages through Codex.
6. Configure each member Skill by absolute path. Keep `main` members disabled.
7. Verify the final Skill states.

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

The message tool cannot resume a queued or terminal Job. Respawning a terminal
Job creates a new queued Job and never changes the source Job.

The control plane allows at most three running Jobs for one Agent.
It allows at most five acquired execution attempts for one Job.

The control plane increments `attempts` only after it acquires a real execution
lease.
A placement failure returns an unstarted attempt to `queued`.

A retryable worker failure waits before the next execution attempt. Job
sessions wait on a fixed ladder from one minute to two hours, so the five
attempts span some hours and a Job survives an upstream outage. Other actor
events keep a short exponential backoff, because a user waits on them.

One control-plane transaction stores the final state and the notification.
If a worker disappears, the control plane dispatches the Job again.

An old worker process can briefly overlap the replacement. The turn fence
rejects later writes from the old process.

If Codex cannot resume its thread, one attempt can create one replacement
thread. The replacement reads the Job files and receives a short history of
earlier attempts.

## Create and Dispatch a Job Once

Start uses this idempotency key:

```text
{agent_uid, owner_session_id, source_tool_call_id}
```

A new request resolves the effective `coding` Model Profile, selects the Codex
runtime, and checks the requested capabilities. It fails before insertion when
neither `coding` nor its `heavy` fallback is configured. One transaction inserts
both the Job and its dispatch event.

The dispatch event targets this actor session:

```text
{agent_uid, "job:<job-id>"}
```

Every stored Job Session ID uses the `job:` prefix. Repeating the same start
request returns the original Job and event.

Each Job Turn uses the Agent's current AIGateway provider binding. Jobs for one
Agent can use different provider rows without changing the shared Codex Home
or adding a filesystem lock.

## Respawn a Terminal Job Once

Respawn uses the same parent-turn idempotency key as create:

```text
{agent_uid, owner_session_id, source_tool_call_id}
```

The control plane locks the source Job and accepts only `succeeded`, `failed`,
or `stopped`. The source must have a Codex thread and a Workspace owner. One
transaction inserts the new queued Job and its dispatch event. The new Job
stores the source ID in `continued_from_job_id`, the inherited root ID in
`workspace_owner_job_id`, and the new message in `task`.

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

A running Codex Turn receives the text through `turn/steer`. A Job in
`waiting_on_user` starts a new Turn on the same Codex thread with the message as
its answer.

The send request uses the source tool-call ID as its stable ActorEvent source
key. A retry of the same parent Turn returns the existing command event and does
not send the message twice.

When `wait_reply=true`, Agent Computer reads the persisted result once per
second. It stops reading when the parent Turn is canceled, but it does not undo
the stored message. There is no fixed business timeout.

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
- Terminal-source checks, linear respawn, exact thread and Workspace reuse, and
  missing-Workspace errors.
- Causal Turn lookup, bounded trajectory output, continuation, and delivery
  errors.
- Atomic tool-result journaling and lifecycle-event completion, rollback, and
  retry behavior.
- Same-channel cross-session waiting without notification consumption.
- Limits on reported file paths and `user-files` attachment checks.
- Worker placement, capacity, recovery, and account reuse.
- Real Deep Research and Office artifact Jobs in the Worker image.
