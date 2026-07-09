# Subagent Delegation

Subagent Delegation is Ankole's durable background-work subsystem. It lets the
main agent hand a long-running task to an isolated Codex execution, acknowledge
the work immediately, keep the parent conversation available, and return to the
user when the work completes, fails, or needs clarification.

The important abstraction is the work item, not the Codex process. PostgreSQL
owns the commitment; an Agent Computer worker and a Codex app-server process
are replaceable execution leases. This is Ankole's first background work-item
type and establishes the shape future durable work types should follow.

Use delegation only for work expected to take at least ten minutes. Work that
can be completed promptly belongs in the current agent turn.

## User Contract

A successful delegation has four visible phases:

1. The parent agent turns the request into a self-contained brief and starts a
   delegation.
2. `subagent(start)` returns immediately, so the parent tells the user that the
   work has started and the conversation remains usable.
3. The subagent works in its own actor session and durable filesystem area. It
   may survive worker loss, accept steering, or pause for user input.
4. A terminal or waiting state wakes the parent session. The parent inspects
   the result, verifies the artifacts, and reports to the user.

The parent agent must not treat the subagent's final text as trusted delivery.
It is an input to the parent's verification and reporting turn. Artifacts are
placed under `/workspace/user-files` so the parent can inspect and attach them.

The task board in Console is an independent management surface. Operators can
inspect work across channels and cancel non-terminal delegations without going
through chat.

## Core Invariants

- PostgreSQL is the lifecycle source of truth. Worker memory, Codex SQLite, and
  RuntimeFabric are not the product ledger.
- Parent conversations orchestrate and deliver; they never host delegated
  execution.
- A delegation has one serial actor session, so two workers cannot execute the
  same attempt concurrently.
- Worker loss causes redispatch and resume, not immediate task failure.
- Creation, terminal transitions, and waiting transitions are durable before
  they become visible.
- `succeeded`, `failed`, and `waiting_on_user` wake the parent. `stopped` does
  not, because cancellation is already an explicit control action.
- No parent conversation history is copied implicitly. Identity is automatic,
  the brief is explicit, and additional knowledge is retrieved on demand.
- The Codex runtime currently runs with `danger-full-access` and approval policy
  `never`. An unexpected approval request fails closed.
- Durable background work must end a parent turn with either a delegation, a
  scheduled wakeup, or a terminal result. A prose promise is not a commitment.

## Architecture

```text
parent agent turn
  -> subagent(start) RuntimeFabric RPC
  -> PostgreSQL delegation + dispatch ActorEvent
  -> delegation actor session: subagent:<delegation-id>
  -> Agent Computer subagent turn
  -> Codex 0.144 app-server
  -> status/event RuntimeFabric RPCs
  -> PostgreSQL transition + parent wake ActorEvent
  -> parent verification and user delivery turn
```

Elixir owns lifecycle state, dispatch, authorization, retries, capacity, wakeup
transactions, Console reads, and cancellation. Bun owns the isolated execution
turn, Codex protocol client, dynamic-tool projection, and worker-local process
lifecycle. Codex owns its thread and rollout state inside a durable `CODEX_HOME`.

RuntimeFabric is transport only. Every mutating RPC carries the authenticated
worker route and an actor turn reference; the control plane fences stale or
foreign writers before changing durable state.

## Domain Model

### Delegation

`subagent_delegations` stores one work item. Its main fields are:

- UUIDv7 `id`;
- parent `agent_uid`, `session_id`, `actor_event_id`, and `tool_call_id`;
- `runtime`, currently constrained to `codex`;
- operator-facing `title` and durable task `prompt`;
- frozen `reply_route` containing the originating binding and channel route;
- `runtime_thread_id` for Codex resume;
- `workdir` under `/workspace`;
- `attempts`;
- timestamps for queue, start, and completion;
- JSON objects for `result`, `error`, and `metadata`.

`tool_call_id` is unique within the parent agent session. A retried start call
therefore returns the same work item instead of creating duplicate work.

The status machine is:

```text
queued -> running -> succeeded
                  -> failed
                  -> stopped
          ^    |
          |    v
      waiting_on_user
```

`queued`, `running`, and `waiting_on_user` are non-terminal. `succeeded`,
`failed`, and `stopped` are terminal. Cancellation commits `stopped`; it is not
a separate transient state.

### Event Journal

`subagent_delegation_events` stores the execution trajectory. Events have a
per-delegation sequence number, direction, event type, JSON payload, redaction
metadata, and occurrence time. The unique `(delegation_id, seq)` key makes the
journal append order explicit.

Agent Computer batches ordinary audit events to at most one flush per second or
twenty accumulated events. State-changing and terminal events force a flush.
Payload and batch limits use UTF-8 byte length because they protect transport
and persistence, not model context.

## Dispatch, Capacity, and Recovery

Starting a delegation inserts the queued work item and appends a
`subagent.delegation.dispatch` event to the actor session identified by:

```text
{agent_uid, "subagent:<delegation-id>"}
```

The actor session reuses the parent's binding but not its conversational
context. It is excluded from daily conversation-session reset.

Two capacity boundaries apply:

- an agent may have at most three running delegations;
- a worker may host at most
  `agent_computer.subagent.max_delegation_turns_per_worker`, default `9`.

The worker limit is AppConfigure-backed. The default is intentionally permissive
for the current fleet; operators can lower it to reserve capacity for normal
conversation turns. No-capacity dispatches are deferred and reconsidered when
capacity changes.

The active worker extends the actor activation lease only after Codex produces
an app-server notification or request. The generic worker progress timer must
not renew a subagent lease when no Codex activity was observed, because that
would hide a wedged runtime forever. There is no subagent wall-clock timeout:
valid, active work may run for hours. If activity stops or the worker
disappears, the activation lease expires, the dispatch becomes available again,
and a new worker increments `attempts`.

Codex state lives in the installation's shared RWX worker workspace, so a
replacement worker resumes `runtime_thread_id` with `thread/resume`. PostgreSQL
owns the lifecycle and the storage reference; the filesystem contains recovery
material, not a competing work-item ledger. Three execution attempts are allowed.
Exhausting them commits `failed` with an `attempts_exhausted` error and wakes the
parent.

## Agent Computer Turn

A subagent actor event selects a dedicated turn handler rather than the normal
text-agent loop. The handler:

1. validates the dispatch payload and resolves the parent session workspace;
2. materializes the work directory, durable Codex home, runtime configuration,
   identity handoff, skill catalog, and dynamic tools;
3. starts Codex app-server and uses `thread/start` for new work or
   `thread/resume` for an existing runtime thread;
4. starts or continues the Codex turn with the brief, steering instruction, or
   user answers;
5. projects Codex events into the audit journal and durable lifecycle;
6. exits only after completion, failure, cancellation, or a user-input request.

The handler must never start background work and yield. Its exit is the end of
that execution attempt. Runtime liveness comes from the actor lease, not a Bun
job queue or in-process delegation registry.

Codex is pinned to `0.144.0`. Container contract tests cover its experimental
app-server types, Linux sandbox, interrupt behavior, cross-process durable
resume, dynamic tools after resume, SQLite/rollout placement, encrypted
reasoning content, and `prompt_cache_key` behavior.

Codex-reported failures use its structured `codexErrorInfo` before message
matching. Capacity and internal-system failures retry the same thread up to
three times with bounded backoff. Context overflow compacts once, waits for the
canonical `item/completed` `contextCompaction` notification, and then retries.
An unknown thread recreates the thread once from the durable brief and current
continuation instruction. An app-server process loss is infrastructure loss,
not a product terminal state: the worker turn errors, the actor lease path
redispatches it, and the delegation-level three-attempt bound remains the final
guard.

### Filesystem Lifetime

The default artifact directory is:

```text
/workspace/user-files/subagent/<short-id>/
```

It is durable user data and is never removed automatically.

The runtime home is:

```text
<parent-session-root>/.ankole/subagent/<delegation-id>/home
```

It holds Codex configuration, credentials, SQLite state, and rollouts. A cleanup
job removes terminal runtime homes after seven days. Keeping runtime state for a
short recovery window must not be confused with artifact retention.

## Handoff and Capability Projection

Handoff has three layers:

1. Identity: SOUL and MISSION are injected automatically on every dispatch.
2. Task: the parent's brief is the only automatic task context. It should name
   paths, constraints, acceptance criteria, and output language.
3. Knowledge: the subagent uses projected skills and read-only memory tools when
   it needs information not present in the brief.

The parent conversation transcript is deliberately excluded. This prevents
context noise, preserves the parent session's budget, and makes redispatch
reproducible from durable inputs.

Only tools that are useful in a standalone Codex app-server and safe outside the
normal model loop are projected:

- `skill_view`;
- `web_search`;
- `memory_search`;
- `memory_browse`.

Tool definitions are rebuilt on every dispatch. They use JSON Schema, bounded
UTF-8 payloads, output validation, and quarantine after malformed results.
Skill reads preserve enabled-skill visibility, overlays, and symlink
confinement. The `clarify` tool is not projected; Codex asks questions through
its protocol-native `requestUserInput` item.

Native Codex web search is disabled in the generated AIGateway profile. The
projected `web_search` tool preserves Ankole's provider routing and audit
boundary.

Model context limits are different from the transport limits above. Context
assembly and reasoning budgets use the Kernel tokenizer/token estimator.
RuntimeFabric envelopes, database JSON, audit batches, tool output, and wakeup
summaries use UTF-8 bytes. Character counts are not a substitute for either.
The subagent developer instruction is capped at 24,000 `o200k_base` tokens;
SOUL, MISSION, and the skills index degrade within that token budget while the
execution and safety contract remains present.

## Runtime Configuration and Credentials

`agent_computer.codex.config_override` is an encrypted, scoped AppConfigure key.
It accepts:

```json
{
  "mode": "aigateway | official_subscription",
  "config_toml": "optional literal config.toml",
  "auth_json": "optional literal auth.json or JSON object",
  "env": { "allowlisted_variable": "value" }
}
```

Agent scope overrides global scope. A missing override selects the
worker-generated AIGateway profile and a short-lived agent-scoped AIGateway key.

`official_subscription` supports an operator's existing Codex subscription.
Literal `config_toml` and literal `auth_json` are copied byte-for-byte into the
delegation's durable `CODEX_HOME`; object-form `auth_json` is serialized as
JSON. Both files use mode `0600`. Copying subscription credentials is intended
behavior, which is why the complete override is encrypted at rest and is never
placed in actor events, model messages, or audit payloads.

Every dispatch rematerializes the effective configuration. Switching a runtime
home back to the generated AIGateway mode deletes any stale subscription
`auth.json` before starting Codex.

The CLI also enforces `approval_policy="never"`,
`sandbox_mode="danger-full-access"`, and file-backed credential storage. These
execution settings are fixed even when an operator supplies a custom
`config.toml`.

## Tool Contract

The model-facing `subagent` tool has five asynchronous actions:

- `start`: requires a short title and self-contained brief; optionally accepts a
  work directory and output schema; returns the durable snapshot immediately.
- `list`: shows current-session and same-channel historical work. The channel is
  the audience boundary.
- `status`: returns one work item, result/error summary, and latest event cursor.
- `steer`: sends new instructions to a running turn or answers a waiting input
  request and redispatches it.
- `stop`: commits cancellation for queued, running, or waiting work.

There is no blocking `run` or `wait` action. Waiting in the parent model turn
would violate the product contract even if the worker implementation could do
it.

Running steering is delivered as Codex `turn/steer`. Steering a
`waiting_on_user` delegation stores the answers and appends a new dispatch that
resumes the same Codex thread.

## Waiting for User Input

When Codex emits `requestUserInput`, Agent Computer interrupts the Codex turn,
stores the normalized pending questions, and commits `waiting_on_user`. The
same transaction appends a parent wake event.

The parent turns Codex's one-to-three questions into ordinary `clarify` tool
turns. `clarify` is a general main-agent tool with a turn-ending contract:

- card-capable channels receive a portable interactive card and text fallback;
- other channels receive numbered text choices;
- each prompt is one agent turn;
- the user's reply arrives as a normal later turn;
- after all answers are collected, the parent calls `subagent(steer, answers)`.

Interactive-card state improves the experience but is not semantic truth. If
that short-lived state is lost, the user can still answer in text.

## Wakeup and Delivery

Terminal and waiting transitions append the parent `ActorEvent` in the same
database transaction as the delegation state change:

- `subagent.delegation.completed`;
- `subagent.delegation.failed`;
- `subagent.delegation.waiting`.

Terminal idempotency keys contain delegation id and status. Waiting keys also
contain the attempt number so a later question from the same runtime thread is
not suppressed as a duplicate.

Wake payloads contain the delegation id, title, status, a bounded result
summary, work directory, and frozen reply route. Result summaries are limited
to 16 KiB in UTF-8 bytes. The parent worker receives purpose-built instructions
to fetch status, inspect artifacts, run appropriate verification, and use
`reply_attachment` when delivering files.

Successful durable results include the final `summary`/`output_text`, normalized
turn `usage`, the latest diff-derived `files_changed`, and Codex's terminal turn
status. These are verification hints, not a substitute for the parent's direct
inspection of the worktree and artifacts.

These wake turns cannot end as silent success. The parent must either ask the
pending question or report the verified terminal result to the user.

## Cancellation

Cancellation is control-plane first:

- queued work commits `stopped` and consumes the undispatched event;
- waiting work commits `stopped` and prevents resume;
- running work commits `stopped` and then sends `command.stop` to interrupt the
  active worker turn.

This order means a stale or unreachable worker cannot keep the task logically
alive. Late worker writes are fenced and cannot overwrite the terminal state.
The stop command does not emit a generic chat message; chat and Console already
know why the control action happened.

## Console Surface

Console exposes:

- `GET /delegations` with status/agent filters and cursor pagination;
- `GET /delegations/:id` with the event timeline;
- `POST /delegations/:id/cancel`.

The Subagent Tasks page uses three columns: queued, active (including waiting),
and completed. Cards show title, agent, elapsed time, attempts, and waiting
state. The detail view shows result/error summaries and the journal timeline.
Console v1 does not create delegations.

## Operations and Known Limits

- The runtime currently supports only Codex. The `runtime` field makes that
  fact explicit but is not a dormant dispatch abstraction.
- Guarded approvals are outside the current contract. Supporting them requires
  a portable approval interaction and a different sandbox policy.
- Running progress is visible in Console; Ankole does not send progress cards
  to IM channels.
- Codex goal APIs are not used. Durable delegation plus resume and steer is the
  work-management primitive.
- The official subscription mode deliberately transfers operator-managed Codex
  credentials into the worker's isolated runtime home.
- A real external-model artifact workflow remains an operational acceptance
  test, separate from deterministic repository and RuntimeFabric gates.

## Verification Boundaries

The subsystem is protected at several layers:

- release validation covers fresh setup and a reversible rename
  `up -> down -> up` round trip;
- Elixir tests cover idempotent dispatch, route fencing, retries, capacity,
  transactional wakeups, three-state cancellation, list visibility, session
  reset exclusion, AppConfigure encryption, and Console endpoints;
- Agent Computer fast container tests cover the five-action tool, projection,
  credentials, clarify, and turn behavior; a separate integration command runs
  the real Codex binary for protocol, sandbox, interrupt, and resume contracts;
- RuntimeFabric Docker tests cover cross-process completion and waiting/resume;
- Console type checking, production build, and browser verification cover the
  operator surface;
- the repository-wide test gate protects interactions with the remaining
  actor, AIGateway, SignalsGateway, kernel, and web application boundaries.

Related designs are [RuntimeFabric](RuntimeFabric.md),
[SignalsGateway](SignalsGateway.md), [App Configuration](AppConfiguration.md),
[Schedule](Schedule.md), and [Memory](memory/Basic.md).
