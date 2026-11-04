# Automation Jobs

An Automation Job holds a published Applet Action's configuration and execution
authority. Schedule owns timing, Signals owns event routing, and AutomationJobs
owns durable Run admission, state, execution and recovery. Every accepted trigger
creates or coalesces a Run before Ankole acknowledges it.

`Ankole.AutomationJobs` declares the domain interfaces. `Applet` manages Page
Jobs and Action policy, `JobSources` authorizes and coordinates their Schedule
and Webhooks operations, `Queue` owns
concurrency, and `Lifecycle` settles and recovers attempts. Writes compose inside
one `Repo.transact_top_level/2` transaction through Ash resources.

## Authorization and lifecycle

A Job belongs to one Page and one `action_key`. It records its label, JSON
configuration, Action policy, and retained work authorization (`authorization_kind`,
`human_uid`, `human_access_version`). Personal Jobs use their enabling Human for
ordinary capabilities; team Jobs have no current user. `AnkoleRuntime.admin`
capabilities use the Page's current owner. Resource operations check that actual
Principal through AuthZ and record it in audit attribution.

Personal Jobs are visible and manageable only by their Human or that Human's
personal assistant, with the corresponding Page access. Managing their sources
requires `node_contribute`; managing service Job sources requires `node_edit`.
Source reads require `node_view`. `authorize_bindable_in_tx/2` verifies that a
consumer Job is active and that the caller may contribute to its Page and use
its personal authority. Source and consumer authorization are independent.

Human revocation cancels personal Job definitions and queued Runs, pauses their
cron schedules and Webhooks, and prevents new admission under the retained access
version. A running Action keeps completion rights; a retry or emitted follow-up
must pass current work admission. Independent service Jobs continue.

Every Action capability carries an internal attempt reference containing Job,
Run, attempt UUID and execution Principal. `AttemptAccess` checks the running
Run and matching fence. Writes repeat that check in their committing transaction;
stale attempts cannot commit. Domain operations that acquire lower-ranked locks
can request a nonlocking authority precheck, then acquire the Job and Run fence
before committing the same transaction. Page tree locks precede work and content locks.

Trashing a Page or an ancestor stops its Job sources. Automatic cron skips missed
slots while advancing its next fire without creating Runs or spending occurrence
budget. Webhooks ignore callbacks without consuming a one-shot endpoint.
Restoring the Page makes active sources eligible again. Deleting a Job or purging
its Page removes its schedules, endpoints, source Bindings, consumer Bindings,
receipts, Runs and state in the same transaction. Cleanup locks all affected
Jobs in ID order before Bindings and source rows.

An independent source can still deliver to a Job whose Page is in the trash.
Ankole records that Run as failed with `page_trashed`, preserving the source and
its other subscriptions. Restoring the Page allows later events to execute.

## Persistence and routing

`automation_jobs` stores Page-owned definitions. `automation_job_runs` stores the
CloudEvents envelope, queue status, concurrency key, attempt fence, admitted
publication and idempotency policy, slice counters, progress, result and error.
`automation_job_states` stores durable checkpoints scoped to one Job. Job and Run
IDs use `Ankole.ModelIntegerID` and fit JavaScript's safe-integer range.

`signal_bindings` routes cron, checkback, webhook, Base, Applet and Connector
events. Built-in source flows maintain one default Binding. Additional subscriptions
use `Signals.put_event_binding/2` or `/api/v2/pod/signal-bindings`; callers cannot
edit a source-managed default Binding through that API. Dispatch locks target
Jobs, Bindings and source rows before receipt and Run rows. Source transitions,
receipts, Runs and Oban wakeups commit together. [Signals](Signals.md) owns
producer identity, fanout and receipt retention.

## Native Job sources

`cron_schedules.owner_job_id` and `signal_webhook_endpoints.owner_job_id` identify
the owning Job. Sources inherit its retained work authorization. They require no
Agent, Session, chat delivery target, or `payload.task`. Each source's default
Binding is an Action destination for its owner Job. Extra authorized subscriptions
may fan out to other Jobs or Agent Sessions.

Source edits lock the Human authorizers before the owning Job and source row. Dispatch locks its destination
Jobs in ID order before Bindings and the source row. Editing a source does not
lock unrelated consumers, so a concurrent fanout can finish without a lock cycle.

Cron accepts the same `every` and `cron` recurrence, timezone and occurrence bounds
as [Schedule](Schedule.md). Ankole copies business payload fields into
`ctx.signal.data` and adds authoritative `cron_fire_slot_at` and `fired_at`
metadata. Each slot has a stable source event identity. A delayed scheduler fires
once for the due slot and advances to the next future slot; it does not replay
every missed interval. Schedule creation records the acting Principal. An update
with an `id` requires that schedule to exist and preserves omitted fields; without
an `id`, `name` identifies the schedule to create or update. Manual runs accept
an idempotency key. `serial_fifo`
preserves independent business inputs; `serial_coalesce` deliberately replaces
an unstarted tail's input while keeping every receipt linked to the surviving Run.

Job Webhooks support raw receipts and CloudEvents, one-shot and standing modes,
and a required expiry. Creation returns the callback capability and its
`callback_path` once. The client resolves that path against its Pod origin. Pausing
acts on the endpoint before dispatch, so every subscription stops and a one-shot
endpoint stays unconsumed. Resume rejects expired capabilities and restores the
mode's armed or active state. Cancel and delete revoke the capability; the
terminal endpoint remains available as history until Job or Page deletion.
Fired, cancelled and expired endpoints reject edits, pause and resume with
`webhook_terminal`. Repeated cancellation leaves their recorded outcome intact.

The Applet's **Automation** panel lets a member select a published Action and
create a personal Job, or create a team Job when they can edit the Page. The panel
edits Job configuration, schedules, and webhook endpoints, and shows source
receipts and Run results. Calendar recurrence uses the shared Cron editor for
daily, weekly, monthly, and custom schedules. Selecting a receipt opens the
authorized Run detail, including its trigger input and retained execution logs.
The Connector event picker uses each adapter's declared streams and event types,
along with configured subscriptions. Selecting a stream event stores an exact
`signal.type` filter. The panel lists saved associations independently of the
picker selection and shows each connection and subscription's current status.
Authorized members can cancel an association while its connection is disabled.
Deleted subscriptions and disabled connections cannot be selected for new
associations.

`GET /api/v2/pod/pages/:page_id/job-actions` lists the current publication's Action
keys. `GET /api/v2/pod/pages/:page_id/jobs/:job_id/runs` returns the latest 100 Runs
visible to the caller. Run history and single-Run reads include the retained
CloudEvents `event`, start and finish timestamps, progress, result, error, and
`stdout` and `stderr` tails. Applet `console` output follows the Run through
continuation slices and final success or failure: `warn` and `error` append to
stderr, and other levels append to stdout. The current attempt fence and the
slice transition commit the logs together, so retries cannot append an already
committed slice twice. Each log tail is bounded to 64 KiB and carries a
truncation flag. Timestamps are null before the corresponding lifecycle step.
For a coalesced Run, `event` is its current input; source receipts identify earlier
deliveries that were coalesced into it. Source management lives under that Job's
path:

- `/schedules`: list and put; `/:id/pause`, `/resume`, `/run`, `/runs`, and delete.
- `/webhooks`: list and create; `/:id` update/delete, `/pause`, `/resume`, `/cancel`.

Schedule history returns scheduled events and delivery receipts. Webhook lists
include each source's latest 100 delivery receipts across all its consumers.
A receipt exposes its source event ID, receipt time,
Run ID and status, and whether the Run consumed a later coalesced event. Ankole
compares both the source and event ID with the Run's current input, so equal
business IDs from different sources remain distinct events.
Applet frontends use `useAppletJobs()` and `useJobSources(jobID)` from
`@ankole/applet-sdk`. Agents discover Actions and Runs with `ankole-pod jobs.actions`
and `ankole-pod jobs.runs`. Agents use
`ankole-pod jobs schedules <operation> <JSON>` and
`ankole-pod jobs webhooks <operation> <JSON>` under the same Page authorization.
History reads use the Job's current Page visibility and personal-owner check,
without taking the Job's execution lock. Ankole loads recent receipts through
the Binding relationship and reads Run statuses once for all listed sources.
A restored member can read their cancelled Job's sources and receipts, while
the retained, revoked work authorization still prevents source mutations.

## Applet Actions

An Applet publishes `actions` alongside its `routes`. Each Action declares
`idempotent`, optional `concurrency` (`parallel`, `serial_fifo`, or
`serial_coalesce`), `concurrencyKey(ctx)`, and `maxSlices` (default 1000).
Ankole inspects these exports and refreshes all matching Jobs in the same
transaction as the files and Page revision. It locks these Jobs before checking
the executing Signal or Automation Run fence. If execution has ended or the
Page revision has changed, Ankole rolls back the policy refresh and any queued
wakeups. The code declaration owns policy; Job editors configure its label,
JSON configuration and authorization, rather than competing policy overrides.
Multiple Jobs may invoke the same Action with different configuration and state.

Each slice loads the latest publication and snapshots its revision and
`idempotent` value on the Run. Recovery uses that snapshot even if another
publication changes policy. A missing Action, trashed Page or unavailable Page
owner fails that Run and wakes its successor, preserving saved state. Restoring
the Action or owner lets the next trigger resume from its saved cursor. Revoking
a personal Job's Human authorization cancels the Job and its queued Runs.

`ctx.state.get/set/delete` stores JSON in `automation_job_states`, keyed by Job,
scope and key. The default scope is `default`; `ctx.state.scope(name)` selects a
business partition. Scope and key contain 1–255 characters and each value is at
most 64 KiB. State follows the Job lifecycle, including deletion on Page purge.
Conversation deletion and permanent Agent deletion remove Applet Jobs in the
roots they own before taking Page row locks. The Job's cascading dependents
are removed in that transaction; Page foreign keys remain restrictive.

`ctx.remainingMs()` reports the current slice budget. Function Runtime carries
the control plane's invocation deadline through the host bridge to the isolate;
setup time consumes that budget. Failed Actions preserve `HttpError` details,
including authorization links and identifiers needed to reconcile a partial write. A handler returns
`await ctx.continueSlice({delaySeconds, progress})` to request another slice of
its Run. After the handler completes, Ankole requests runtime cleanup and then
increments `slice_count`, resets `attempts_in_slice`, and commits the next Oban
wakeup with the progress (at most 16 KiB). An exception or oversized result fails
the current slice without committing a continuation. Synchronous child Actions
share the parent Job's state but cannot continue its Run.

Every wakeup carries `expected_slice_count`; replaying an earlier wakeup is a
no-op and cannot bypass the next slice's delay. Each Oban wakeup has five attempts.
A busy runtime defers the wakeup without spending its retry budget or the slice's
execution retry budget. Once admitted, a deferred Run keeps its admission count
and queue position, distinct from an unstarted coalescing tail. Other runtime
rejections before execution use the wakeup's retry budget. Ankole records a
completed handler result as terminal, including a nested call's capacity error;
it does not infer whether execution started from the HTTP status. A lost runtime
connection leaves the outcome unknown and uses the admitted idempotency snapshot
and bounded recovery described below. Successful handlers may return any JSON value.

Serial queues use the smallest unfinished Run ID within `(job, concurrency_key)`
under the Job lock. Only the head gets a wakeup. `serial_coalesce` replaces the
event of a queued tail only while `attempts = 0 AND slice_count = 0`; PostgreSQL
enforces one such tail. Retrying or continuing a started Run preserves its place
and cannot collide with the coalescing tail. Terminal settlement wakes the next
queued Run in the same transaction. Publishing a change to `parallel` wakes all
queued Runs as part of the policy update, preserving any already scheduled
slice delay.

Normal execution uses event-driven wakeups. `ExpireAttempts` handles abandoned
running attempts, including a crash on Oban's fifth attempt. It requeues a slice
whose admitted policy was idempotent while `attempts_in_slice < 10`. Otherwise it
fails the Run with `execution_outcome_unknown` and wakes the next serial head.

Page Job APIs create, list, configure and delete definitions under
`/api/v2/pod/pages/:page_id/jobs`. A targeted Applet `signals.emit({targetJobId})`
requires the same Page and `node_contribute`, returning
`{accepted: true, runId, coalesced}`. Personal Jobs are limited to their Human or
that Human's personal assistant. Reading `/runs/:id` and joining `run:<id>` use
the same authorization; team Run progress requires `node_view` on its Page.
Agent `jobs.list` and `jobs.get_run` requests identify that Page with `page_id`;
the Agent and the conversation's disclosure recipients must be able to view it.
The Job domain also checks the Run's Page and personal Job ownership.
Committed slice and terminal changes publish progress to authorized subscribers.
Applet frontends use `useActionRun(runId)` from `@ankole/applet-sdk` to read the
Run and follow its progress, result and error through the host's existing socket.
The hook refreshes on subscription and reconnection, so a completion committed
while the browser was disconnected appears without another button click.

## Console inspection

The read-only Console lists Jobs across the tenant and opens details directly by
Job ID. It shows Page, Action, execution identity, configuration, progress,
result and errors. Its Run history exposes the same event, timestamps and bounded
logs as the Page Job API. The JSON:API paths are `GET /api/v2/automation-jobs`,
`GET /api/v2/automation-jobs/:id`, and
`GET /api/v2/automation-jobs/:automation_job_id/runs`; each requires
`site_console:automation_jobs` `read` permission.
