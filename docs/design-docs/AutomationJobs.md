# Automation Jobs

An automation job is an Agent-owned script that consumes a trigger. When a
trigger names an automation job, Ankole runs that script instead of waking the
Agent. The script can finish silently or emit an event to its owner session.

The Automation Jobs subsystem does not manage trigger timing, webhook admission,
or Agent turns. Schedule and Signals own those rules and call
`Ankole.AutomationJobs` only when they need to create a durable run.

`Ankole.AutomationJobs` is the domain module. Every write entry point runs as a
top-level call inside `Repo.transact_top_level/2`: `create_job`, `cancel_job`,
`start_attempt`, `finish_attempt`, `infrastructure_failure`, and `emit_event`.
When a trigger domain records a run inside its own transaction, it composes
`enqueue_run_in_tx`, `validate_bindable_in_tx`, and `lock_job_in_tx`. Reads and
row locks use Ash queries, and the Job and Run resources apply AshStateMachine
actions inside the caller's transaction.

A Job transitions only from `active` to `cancelled`. A Run starts either as
`queued` or as a failed trigger receipt, and only a `queued` Run can start an
execution attempt. Once an attempt is `running`, it can retry or finish;
cancelling a job stops only `queued` runs. Ankole enforces attempt ownership
with an attempt fence, bounds execution time with separate deadlines for Worker
wait and script execution, and enforces compatible lifecycle timestamps and
attempt fences through PostgreSQL check constraints.

`Ankole.PrincipalKey` trims surrounding whitespace from Agent UID inputs and
converts letters to lowercase. When an Agent UID is required,
`Ankole.PrincipalKey` rejects empty input. In list queries, an empty Agent UID
matches no jobs; only `nil` selects jobs across every Agent.

## Human Work Authorization

Each job definition stores `authorization_kind`, `human_uid`, and
`human_access_version` from its source Signal, as defined in
[Human Offboarding](HumanOffboarding.md). Runs inherit that authorization
through their immutable `automation_job_id`. The control plane checks the
definition's retained authorization both when a trigger fires and before each
attempt starts.

When a Human's access is revoked, cleanup cancels the definition and its queued
runs. A running attempt keeps its completion rights, but a retry or an emitted
follow-up event cannot authorize new Human work. Independent `service`
definitions keep their own authorization.

Pod and file RPCs carry an `AutomationAttemptRef` containing `job_id`, `run_id`,
and `attempt_id`. `AutomationJobs.authorize_attempt_actor/2` verifies the
calling Worker, the active definition, the running Run, and its current attempt
UUID, locking the retained Human authorization before locking the definition and
Run:

- For a `human` definition, the check intersects the Human's and Agent's page
  permissions and requires the recorded Human access version to remain current.
- For a `service` definition, the check uses the Agent's page permissions.
- For a `review_required` definition, the check rejects Pod access.

Every Pod write rechecks the attempt inside the transaction that commits its
content. A tree write acquires the Pod tree lock before locking the Human and
attempt rows, whereas a content-row write locks the content row after the
attempt rows. Because `authorize_attempt_actor/2` requires a live matching
attempt, a stale or completed attempt cannot read or modify Pod data.

## What PostgreSQL Stores

`automation_jobs` stores one registered script:

- the owning Agent and Session
- the source Signal and reply route
- `drive_prefix` (the folder in the Agent's drive that holds the script) and the label
- `wake_on_failure`
- the status (`active` or `cancelled`)

`automation_job_runs` stores one trigger consumption:

- the original CloudEvents 1.0 envelope
- the status (`queued`, `running`, `succeeded`, `failed`, or `cancelled`)
- the attempt count and current attempt UUID
- start and finish timestamps, plus the persisted start time of the Worker wait
- the exit code and error text
- bounded `stdout` and `stderr` tails

Both tables use PostgreSQL identity `bigint` IDs that start at `1000` and stay
within the JavaScript safe-integer range. PostgreSQL check constraints validate
the lifecycle columns for each state. An event envelope can contain at most
1 MiB, and each log or error field can contain at most 64 KiB.

`Ankole.ModelIntegerID` defines the numeric bounds and canonical decimal string
format for domain guards, RPC inputs, activity cursors, and Console schemas. On
the wire, an ID has no sign and no leading zeros. Plain counters such as
schedule occurrences are not IDs and keep their own numeric ranges.

## Bind a Trigger

Checkbacks, cron schedules, and callback capabilities carry an optional
`automation_job_id`.

Before storing a binding, the trigger owner locks and validates the target job,
which must be `active` and belong to the same Agent. Updating a checkback or
cron schedule can clear or replace its binding. A callback capability cannot
change its binding in place; to rebind it, the Agent cancels the capability and
creates a new one.

An unbound trigger delivers a Signal directly to the Agent, whereas a bound
trigger records an automation job run instead. Because the control plane commits
the run together with the trigger claim or schedule advance in a single
PostgreSQL transaction, a webhook never returns success before its Signal or run
is durable.

Trigger owners leave the CloudEvents envelope unchanged when the consumer
changes.

## Run the Script

`Ankole.AutomationJobs.Jobs.ExecuteRun` runs on the dedicated `automation_jobs`
Oban queue with ten consumers. At most `automation_jobs.max_running_per_agent`
runs execute concurrently per Agent (ten by default). During admission, the job
locks the authorizing Human, the Agent slot scope, the job definition, and the
run in that exact order. It evaluates the shared
[Worker readiness rule](AgentWorkers.md#new-attempt-readiness) and persists the
returned timestamp in `worker_wait_started_at` inside the same transaction that
checks capacity and claims the attempt.

While the Agent's Worker is not ready, the Oban job requests the Worker
([Agent Workers](AgentWorkers.md)) and snoozes for 10 seconds without consuming
an attempt. If the run finishes or is cancelled in the meantime, the Oban job
exits without requesting a Worker. Once the Worker is ready, `ExecuteRun` claims
the run under a row lock, increments the attempt count, assigns a fresh attempt
UUID, and invokes the worker-owned `automation_job.run` RuntimeFabric RPC. For
each attempt, the control plane resolves the Agent's currently enabled Skills
and sends their `RuntimeSkillSummary` projections in the RPC request, without
copying `SKILL.md` bodies or MCP connection declarations.

The script itself lives in the Agent's drive ([Files](Files.md)). At the start
of an attempt, the Worker copies the `drive_prefix` folder into a fresh working
directory at `<Agent Home>/.ankole/automation-runs/<attempt UUID>`; if the
folder has no `main.ts`, the Worker fails the attempt immediately. When the
attempt finishes, the Worker deletes that working directory. As a result, every
run sees the drive contents as they exist when the attempt starts, and temporary
files written into the working directory do not persist across runs. If a Worker
exits mid-run, it removes any leftover run directories on startup.

The RPC request carries the binding name from the job's reply route so that the
Worker can resolve the latest Agent `WorkerEnv` for that signal route. Before
reading MCP declarations from Skills, the Worker synchronizes the Agent's
installed Skills from the drive; if that download fails, the Worker reports an
infrastructure failure so that the run retries instead of silently omitting MCP
dependencies on a cold cache. The Worker then resolves the Skill summaries
across the builtin, internal, and Agent-installed roots, merges their MCP
dependencies into a single `0600` mcporter config file with `imports: []`,
exposes its path via `MCPORTER_CONFIG`, and deletes that file when the attempt
ends. Generating this config does not launch any MCP server; `main.ts` starts a
server only when it invokes mcporter. Automation runs do not load Skill
instructions, because `main.ts` already encodes the chosen tool, arguments,
bounds, and result checks.

Finally, the Worker opens `ankole-pod` and `ankole-files` CLI bridges bound to
the claimed attempt and closes them when the script exits. Pod file downloads
enforce the same page and path permissions as browser downloads. The Worker
executes `main.ts` with Bun under the Worker user, inside its own process group,
with the run directory as its working directory.

Each attempt has a ten-minute execution limit; when that deadline expires, the
Worker terminates the entire process group. Runs of the same job can overlap
because Automation Jobs provides neither a mutex nor a job-level scheduler. Any
stateful script must manage its own state and make repeated runs safe.

## Use the Run SDK

The Worker preloads the Run SDK module from its installed code directory. On the
first call to `context()`, the SDK reads and caches the run context:

- `context()` returns the trigger event together with the job ID and label.
- `emitEvent(payload)` appends one `automation_job.emitted` Signal to the owner
  session.

`emitEvent` sends the payload over a run-local Unix socket and the worker-agent
RuntimeFabric RPC. The control plane accepts the call only while the run and
attempt UUID remain current, and the promise resolves only after PostgreSQL
commits the Signal. A single run can emit zero, one, or many events.

These SDK functions are available only inside a platform run. Running
`bun main.ts` directly can exercise setup logic and code branches that do not
call the SDK, whereas testing SDK branches requires registering the job, firing
a test trigger, and inspecting the durable run. Never treat `stdout` output as
proof that an event was emitted.

Both `automation_job.emitted` and `automation_job.run_failed` preserve
conversation interaction. Their Worker projections wrap content in bounded
delimiters, and the emitted-event prompt instructs the Agent to verify
consequential claims against an authoritative source.

## Separate Script Failure from Worker Failure

When `main.ts` resolves normally, the run succeeds. If the script throws an
unhandled exception, exits with a non-zero code, or hits the ten-minute timeout,
the run ends in a terminal script failure. Missing `main.ts` files and invalid
MCP declarations in Skills are also terminal script failures, so Oban never
retries them.

By contrast, a `timed_out` Worker readiness result, a lost Worker route, a
RuntimeFabric RPC error, or an invalid Worker response counts as an
infrastructure failure. Setup failures before `main.ts` starts (such as a failed
copy from the drive or a failed `WorkerEnv` resolution) also count as
infrastructure failures. When Worker readiness times out, admission claims one
attempt under its locks before recording the failure. Every new attempt records
its own `started_at` timestamp and receives a fresh ten-minute script budget.

After an infrastructure failure, the control plane returns the run to `queued`,
clears its attempt UUID, and lets Oban dispatch a retry, up to five total
attempts. On the fifth infrastructure failure, the control plane marks the run
`failed` so that a Worker unable to start cannot leave the run queued
indefinitely. Likewise, if Human authorization is revoked between attempts,
admission marks the run `failed` and commits any configured failure notice
instead of stranding a queued run without a valid retry owner.

`WorkerAdmission` tracks Worker liveness. Whenever it marks a route unusable or
replaces a Worker incarnation, it immediately aborts pending RPC waits on that
route so the Oban attempt can fail and retry without waiting out the ten-minute
script deadline. Once PostgreSQL records a new attempt UUID, the old Worker can
neither emit events nor finish the run.

When a run ends in a terminal failure and `wake_on_failure` is `true`, the
control plane appends one `automation_job.run_failed` Signal to the owner
session; otherwise, it records the failure only in the run history.

## Manage and Observe Jobs

An Agent manages its automation jobs through four turn-local CLI commands:

- `create-automation-job-cli`
- `list-automation-jobs-cli`
- `show-automation-job-cli`
- `cancel-automation-job-cli`

During creation, the CLI bridge verifies that the local script directory
contains a regular `main.ts` file, uploads the directory to a new drive folder
at `automation/<directory name>-<random suffix>`, and registers the job against
that folder. If registration fails, the bridge deletes the uploaded folder; the
control plane also rejects any target folder that lacks `main.ts`. To update an
existing script, the Agent uploads the edited directory to the same
`drive_prefix` with `ankole-files put` without re-registering the job.

All four CLI commands resolve the same owning Agent and long-lived Session. A
Background Agent Job follows its persisted `owner_session_id` and pinned
`owner_conversation_id`, while a Workflow task follows its `AgentCall` and
`Run`. Every link in that chain must belong to the calling Agent, and an ended
task context still identifies its originating Session. If those links do not
resolve to a long-lived recipient, creation fails with
`long_lived_reply_owner_not_found`. Meanwhile, the calling Signal itself remains
the source of work authorization and provenance. Cancelling a job marks its
`queued` runs `cancelled` in the same transaction while allowing any `running`
attempt to finish and emit events. If a failed run cannot deliver its failure
notice because the recipient Session cannot be resolved, the control plane
records `long_lived_reply_owner_not_found` in the run's error field rather than
sending the notice to an ended task.

The Console API is read-only and is served through `/api/v2` JSON:API:

- `GET /automation-jobs` lists jobs in the selected tenant (with an optional
  Agent filter) and requires `site_console:automation_jobs` with the `read`
  action.
- `GET /agents/:agent_uid/automation-jobs/:id` and
  `GET /agents/:agent_uid/automation-jobs/:automation_job_id/runs` read a single
  job and its recent runs under the owning Agent path. Both require
  `site_console:agent:<agent_uid>:automation_jobs` with the `read` action and
  return the attempt count, terminal status, exit code, error text, and bounded
  logs.

### Live activity in Console Home

Console Home can inspect `queued` and `running` Automation runs for an
explicitly selected Agent when the operator holds the
`site_console:agent:<agent_uid>:automation_jobs` `read` permission. The query
starts from `automation_job_runs` and joins each run's definition through the
Run `job` relationship without filtering on definition status. As a result, a
`cancelled` job definition still surfaces an already admitted `running` attempt,
matching the cancellation contract above. The query applies its status and Agent filters before applying its independent
page cursor, and it returns job labels, owner Session, attempt identity, bounded
error text, and any known Schedule trigger ID without loading scripts, event
bodies, `stdout`, or `stderr`.

This read-only activity view links directly to the job definition detail. Its
observation timestamp records when the Console read the database, not proof that
an external side effect succeeded. Alongside
[Workflow](Workflow.md#console-activity-inspection) and
[Background Agent Job](BackgroundAgentJob.md), it forms one of the three
background-activity panels in Console Home; pending Schedule rules and ordinary
conversation Turns stay outside this view.

## Rules

- Commit every trigger claim together with its consumer record in one transaction.
- Keep the CloudEvents trigger envelope unchanged when its consumer changes.
- Allow only the owning Agent to bind, inspect via the Agent API, cancel, or
  emit events from a job; allow the Console to inspect job details with the
  owning Agent's `read` permission.
- Accept `emitEvent` and attempt completion only from the current attempt UUID.
- Lock the parent Job row before locking the Run row on every Run transition,
  including start, cancellation, completion, and infrastructure recovery.
- Never retry script failures.
- Retry infrastructure failures up to five total attempts.
- Resolve `emitEvent` only after the emitted Signal is durable in PostgreSQL.
- Store no script state, DAG, mutex, or trigger schedule inside Automation Jobs.
