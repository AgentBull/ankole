# Automation Jobs

An automation job is an Agent-owned script that consumes a trigger. It replaces
an Agent wake-up only when the trigger names it. It can finish without a reply
or emit an event to its owner session.

Automation Jobs does not own trigger time, webhook admission, or Agent turns.
Schedule and SignalsGateway keep those rules. They call Automation Jobs only
when they must create a durable run.

## What PostgreSQL Stores

`automation_jobs` stores one registered script:

- the owning Agent and Session
- the source ActorEvent and reply route
- the absolute directory path and label
- `wake_on_failure`
- an optional expiry time
- `active`, `cancelled`, or `expired`

`automation_job_runs` stores one trigger consumption:

- the original CloudEvents 1.0 envelope
- `queued`, `running`, `succeeded`, `failed`, or `cancelled`
- the attempt count and current attempt UUID
- the Oban job ID
- start and finish times
- exit code and error
- bounded stdout and stderr tails

Both tables use PostgreSQL identity bigint IDs that start at `1000` and stay
inside the JavaScript safe-integer range. PostgreSQL checks the lifecycle shape
for each state. An event can contain at most 1 MiB. Each log or error field can
contain at most 64 KiB.

## Bind a Trigger

Checkbacks, cron schedules, and callback capabilities have an optional
`automation_job_id`.

The trigger owner locks and validates the job before it stores the binding. The
job must be active and must belong to the same Agent. A checkback or cron update
can clear or replace the binding. A callback capability cannot change its
binding; the Agent cancels it and creates a replacement.

A trigger with no binding keeps the direct ActorEvent path. A bound trigger
stores an automation job run instead. The run and the trigger claim or advance
commit in the same PostgreSQL transaction. A webhook therefore does not return
success before its ActorEvent or run is durable.

Trigger owners keep the CloudEvents envelope unchanged. Changing the consumer
does not change the event.

## Run the Script

`Ankole.AutomationJobs.Jobs.ExecuteRun` is the Oban wake edge. It claims the run
under a row lock, increases the attempt count, and gives the attempt a new UUID.
It then calls one admitted Agent Computer worker through the worker-owned
`automation_job.run` RuntimeFabric RPC. Each attempt resolves the Agent's
current enabled Skills and sends their existing `RuntimeSkillSummary`
projection with the request. The request does not copy `SKILL.md` or MCP
connection declarations.

The Worker checks the directory and `main.ts` through `realpath` again. Both
must stay inside the current Agent Home. The request carries the binding name
from the job's reply route, so the Worker resolves the latest Agent WorkerEnv
for the same signal route. It resolves the request's Skill summaries through
the current builtin,
internal, and Agent-installed roots. It combines those Skill MCP dependencies
and writes one `0600` mcporter config with `imports: []`. It injects the path as
`MCPORTER_CONFIG` and removes it when the attempt ends. Config generation does
not start a server; `main.ts` starts one only when it calls mcporter. Automation
does not read Skill instructions; `main.ts` contains the selected tool,
arguments, bounds, and result checks. The Worker does not add turn-local human
identity or turn CLI sockets. It runs `main.ts` with Bun in the existing
bubblewrap sandbox, with the job directory as the working directory.

The run limit is ten minutes. Runs of one job can overlap. Automation Jobs does
not add a mutex or a scheduler. The script owns any state and must make a repeat
safe.

## Use the Run SDK

The Worker preloads a small SDK:

- `context()` returns the trigger event and the job ID and label.
- `emitEvent(payload)` appends one `automation_job.emitted` ActorEvent to the
  owner session.

`emitEvent` uses a run-local Unix socket and the worker-agent RuntimeFabric RPC.
The control plane accepts it only while the run and attempt UUID are current.
The call resolves only after the ActorEvent is durable. A run can emit zero,
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
terminal script result. Oban does not retry that result.

A missing worker, lost route, RPC error, or invalid worker response is an
infrastructure failure. The run returns to `queued`, clears its attempt UUID,
and lets Oban dispatch a new attempt. Oban permits five attempts. The last
infrastructure failure makes the run `failed`.

WorkerAdmission owns worker liveness. When it makes a route unusable or replaces
its worker incarnation, it also ends pending RPC waits for that route. The Oban
attempt can then fail and retry without waiting for the script deadline. An old
worker cannot emit or finish after the new attempt UUID is stored.

If `wake_on_failure` is true, a terminal failure appends one
`automation_job.run_failed` ActorEvent. Otherwise, the failure stays in the run
history.

## Manage and Observe Jobs

The Agent uses four turn-local CLI commands:

- `create-automation-job-cli`
- `list-automation-jobs-cli`
- `show-automation-job-cli`
- `cancel-automation-job-cli`

The create bridge resolves the directory and `main.ts` before it registers the
job. The list and show commands return only jobs owned by the current Agent
Session. Cancellation changes queued runs to `cancelled` in the same
transaction. A running attempt can finish and emit.

The Console API is read-only. It lists jobs across the deployment instance or
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
- Script failures do not retry.
- Infrastructure failures can use at most five attempts.
- A successful `emitEvent` call means the ActorEvent is durable.
- The platform stores no script state, DAG, mutex, or trigger rule.
