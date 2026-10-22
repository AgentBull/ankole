# Automation Jobs

An automation job is an Agent-owned script that consumes a trigger. It replaces
an Agent wake-up only when the trigger names it. It can finish without a reply
or emit an event to its owner session.

Automation Jobs does not own trigger time, webhook admission, or Agent turns.
Schedule and Signals keep those rules. They call Automation Jobs only
when they must create a durable run.

`Ankole.AutomationJobs` is the domain module. Each write entry point
(`create_job`, `cancel_job`, `start_attempt`, `finish_attempt`,
`infrastructure_failure`, `emit_event`) is a generic action on the Job or Run
resource. The action owns its transaction and must be the top-level call. A
trigger domain composes `enqueue_run_in_tx`, `validate_bindable_in_tx`, and
`lock_job_in_tx` in its own transaction. Reads and row locks use Ash queries.
The Job and Run resources use AshStateMachine actions in the transaction of the
generic action. A Job moves from `active` to `cancelled`. A Run starts as
`queued` or as a failed trigger receipt. Only queued work can start an attempt.
A running attempt can retry or finish, and cancellation only stops queued work.
The attempt fence and both Worker-wait and execution deadlines keep their
existing meaning. PostgreSQL also rejects incompatible lifecycle timestamps and
attempt fences.

## Human Work Authorization

Each definition stores `authorization_kind`, `human_uid`, and
`human_access_version` from its source Signal, as defined in
[Human Offboarding](HumanOffboarding.md). Trigger consumption and each attempt
check the definition's retained authorization. Runs inherit it through their
immutable `automation_job_id`.

Revocation cancels the definition and queued runs. A running attempt keeps its
completion rights; a retry or emitted follow-up cannot create newly authorized
Human work. Independent service definitions keep their own authorization.

## What PostgreSQL Stores

`automation_jobs` stores one registered script:

- the owning Agent and Session
- the source Signal and reply route
- `drive_prefix`, the folder in the Agent's drive that holds the script, and the label
- `wake_on_failure`
- `active` or `cancelled`

`automation_job_runs` stores one trigger consumption:

- the original CloudEvents 1.0 envelope
- `queued`, `running`, `succeeded`, `failed`, or `cancelled`
- the attempt count and current attempt UUID
- start and finish times, and the persisted Worker-wait start
- exit code and error
- bounded stdout and stderr tails

Both tables use PostgreSQL identity bigint IDs that start at `1000` and stay
inside the JavaScript safe-integer range. PostgreSQL checks the lifecycle shape
for each state. An event can contain at most 1 MiB. Each log or error field can
contain at most 64 KiB.

`Ankole.ModelIntegerID` owns the bounds and canonical decimal input form for
domain guards, RPC inputs, activity cursors, and Console schemas. A wire ID has
no sign or leading zeros. Counts such as schedule occurrences keep their own
range; they are not IDs.

## Bind a Trigger

Checkbacks, cron schedules, and callback capabilities have an optional
`automation_job_id`.

The trigger owner locks and validates the job before it stores the binding. The
job must be active and must belong to the same Agent. A checkback or cron update
can clear or replace the binding. A callback capability cannot change its
binding; the Agent cancels it and creates a replacement.

A trigger with no binding keeps the direct Signal path. A bound trigger
stores an automation job run instead. The run and the trigger claim or advance
commit in the same PostgreSQL transaction. A webhook therefore does not return
success before its Signal or run is durable.

Trigger owners keep the CloudEvents envelope unchanged. Changing the consumer
does not change the event.

## Run the Script

`Ankole.AutomationJobs.Jobs.ExecuteRun` uses the independent `automation_jobs`
Oban queue with ten consumers. The per-Agent cap is
`automation_jobs.max_running_per_agent` (default ten). Admission locks the
authorizing Human, Agent slot scope, definition, and run in that order. Admission
uses the shared [Worker readiness rule](AgentWorkers.md#new-attempt-readiness)
and persists its returned start in `worker_wait_started_at` in the same
transaction as the capacity check and attempt claim.

A run waits
while the Agent's Worker is not ready: the job requests the Worker
([Agent Workers](AgentWorkers.md)) and snoozes for 10 seconds, which does not
use an attempt. A run that finished or was cancelled meanwhile ends the job
without a Worker request. When the Worker is ready, the job claims the run
under a row lock, increases the attempt count, and gives the attempt a new
UUID. It then calls the Worker through the worker-owned
`automation_job.run` RuntimeFabric RPC. Each attempt resolves the Agent's
current enabled Skills and sends their existing `RuntimeSkillSummary`
projection with the request. The request does not copy `SKILL.md` or MCP
connection declarations.

The script lives in the Agent's drive ([Files](Files.md)). The Worker copies
the `drive_prefix` folder to a fresh run directory,
`<Agent Home>/.ankole/automation-runs/<attempt UUID>`, and fails the attempt
when the folder has no `main.ts`. It removes the run directory when the attempt
ends, so every run sees the script as the drive holds it at fire time, and a
file that the script writes into its working directory does not survive the
run. A Worker that ended during a run removes the directories it left when it
starts again. The request carries the binding name
from the job's reply route, so the Worker resolves the latest Agent WorkerEnv
for the same signal route. Before it reads Skill MCP declarations, it downloads
the Agent's installed Skills from the drive. A failed download is an
infrastructure failure and follows the run's retry policy; a cold cache must
not silently omit MCP dependencies. It resolves the request's Skill summaries through
the current builtin,
internal, and Agent-installed roots. It combines those Skill MCP dependencies
and writes one `0600` mcporter config with `imports: []`. It injects the path as
`MCPORTER_CONFIG` and removes it when the attempt ends. Config generation does
not start a server; `main.ts` starts one only when it calls mcporter. Automation
does not read Skill instructions; `main.ts` contains the selected tool,
arguments, bounds, and result checks. The Worker does not add turn-local human
identity or turn CLI sockets. It runs `main.ts` with Bun as the Worker's user,
in its own process group, with the run directory as the working directory; the
run limit ends the whole process group.

The run limit is ten minutes. Runs of one job can overlap. Automation Jobs does
not add a mutex or a scheduler. The script owns any state and must make a repeat
safe.

## Use the Run SDK

The Worker preloads a small SDK:

- `context()` returns the trigger event and the job ID and label.
- `emitEvent(payload)` appends one `automation_job.emitted` Signal to the
  owner session.

`emitEvent` uses a run-local Unix socket and the worker-agent RuntimeFabric RPC.
The control plane accepts it only while the run and attempt UUID are current.
The call resolves only after the Signal is durable. A run can emit zero,
one, or many events.

These SDK functions exist only inside a platform run. A direct `bun main.ts`
run can check setup and branches that do not call the SDK. After registration,
use a test trigger to check SDK branches and inspect the durable run. Do not
treat stdout as a successful event emission.

`automation_job.emitted` and `automation_job.run_failed` preserve interaction.
Their Worker projections include bounded, delimited content. The emitted event
tells the Agent to verify consequential facts at an authoritative source.

## Separate Script Failure from Worker Failure

A resolved script succeeds. A thrown exception, non-zero exit, or timeout is a
terminal script result. A folder without `main.ts` or an
invalid Skill MCP declaration are terminal too. Oban does not retry these
results.

A `timed_out` readiness result, a lost route, an RPC error, or an invalid Worker
response is an infrastructure failure. A readiness timeout claims one attempt
under the admission locks before the failure is recorded. Each new attempt
sets `started_at` to its own start time and gets the full
script execution budget. A failure before the script starts is also an
infrastructure failure, such as a failed copy from the drive or a failed
WorkerEnv resolution. The run returns to `queued`, clears its
attempt UUID, and lets Oban dispatch a new attempt. Oban permits five attempts.
The last infrastructure failure makes the run `failed`, so a Worker that cannot
start fails the run instead of keeping it queued. If authorization is revoked
between attempts, admission commits a failed run and its configured failure
notice instead of leaving a queued run with no retry owner.

WorkerAdmission owns worker liveness. When it makes a route unusable or replaces
its worker incarnation, it also ends pending RPC waits for that route. The Oban
attempt can then fail and retry without waiting for the script deadline. An old
worker cannot emit or finish after the new attempt UUID is stored.

If `wake_on_failure` is true, a terminal failure appends one
`automation_job.run_failed` Signal. Otherwise, the failure stays in the run
history.

## Manage and Observe Jobs

The Agent uses four turn-local CLI commands:

- `create-automation-job-cli`
- `list-automation-jobs-cli`
- `show-automation-job-cli`
- `cancel-automation-job-cli`

The create bridge checks that the script directory has a regular `main.ts`. It
copies the directory to a new drive folder,
`automation/<directory name>-<random suffix>`, and registers the job on that
folder; a failed registration removes the folder again. The control plane
rejects a folder without `main.ts`. To change a script, the Agent puts the
edited directory to the same folder with `ankole-files put`; no new
registration is needed. All four commands use the same owning Agent and
long-lived Session. A Job follows its persisted `owner_session_id` and pinned
`owner_conversation_id`; a Workflow task follows its AgentCall and Run. Every
link must belong to the calling Agent. An ended context still identifies its
Session. Creation fails with `long_lived_reply_owner_not_found` if these facts
do not identify a recipient. The actual calling Signal remains the source
of authorization and provenance. Cancellation changes queued runs to
`cancelled` in the same transaction. A running attempt can finish and emit.

The upgrade moves provable old Job or Workflow task owners to their long-lived
Session. It keeps resource IDs, scripts, run history, source authorization, and
webhook tokens. It keeps an unresolved row unchanged and reports its ID. The
existing Console scope can inspect these rows. Delivery uses the same owner
resolver until no resource retains a `job:` or `wf_task:` owner. An unresolved
emission fails explicitly. If a failed run cannot send its failure notice, the
run retains `long_lived_reply_owner_not_found` in its error instead of sending
the notice to an ended task.

The Console API is read-only. It lists jobs in the selected tenant or
filters them by Agent. The list requires `automation_jobs/read`. It reads one
job and its recent runs through the owning Agent path. The detail read requires
`agent:<agent_uid>:automation_jobs/read`. It shows the attempt count, terminal
result, exit code, error, and bounded logs.

## Rules

- A trigger claim and its consumer record commit together.
- A trigger envelope does not change when its consumer changes.
- Only the owning Agent can bind, inspect through the Agent API, cancel, or emit
  from a job. The Console can inspect job detail with the owning Agent read
  permission.
- Only the current attempt UUID can emit or finish.
- Run changes lock the parent Job before the Run, including start, cancellation,
  completion, and infrastructure recovery.
- Script failures do not retry.
- Infrastructure failures can use at most five attempts.
- A successful `emitEvent` call means the Signal is durable.
- The platform stores no script state, DAG, mutex, or trigger rule.

### Live activity in Console Home

Home can inspect queued and running Automation runs for an explicitly selected
Agent, under the existing `agent:<agent_uid>:automation_jobs` read permission.
The query starts from runs and reads their definitions through the Run `job`
relationship without filtering the definition status. A cancelled definition can
therefore still show its admitted running attempt, consistent with the
cancellation contract above. Activity is filtered before the independent cursor
page; labels, owner Session, attempt identity, bounded error text and known
Schedule trigger ID are available without loading scripts, event bodies or
stdout/stderr.

The activity view is read-only and links to the existing definition detail. Its
observation time describes the read, not proof that an external effect succeeded.
It is one of three explicit background activity groups alongside
[Workflow](Workflow.md#console-activity-inspection) and
[Background Agent Job](BackgroundAgentJob.md); pending Schedule rules and ordinary
conversation Turns are outside this view.
