# Subagent Delegation

Subagent Delegation is Ankole's durable background-work subsystem. It lets a
main agent turn a long-running request into an isolated Codex job, return to the
conversation immediately, and receive a durable wakeup when the task finishes,
fails, or needs user input. Codex is the current execution implementation.

The product object is the delegation, not a Codex process. PostgreSQL owns the
work item and its lifecycle. Agent Computer workers and task-worker processes
are replaceable execution leases over that durable state; the current
implementation launches Codex app-server.

Choose delegation by its user-visible delivery contract. Immediate-response
work stays in the current turn: the user can reasonably wait in the active
exchange, and the next assistant reply contains the completed result. Follow-up
work becomes a delegation: accept it as a separate work item so the conversation
can continue, then deliver the completed result in a later reply. Several tool
calls may still be immediate-response work, while explicit background requests
and enabled long-running Skills always require delegation.

## User Contract

1. The parent agent writes one self-contained `task` string and calls
   `subagent(start)`. The string contains the instruction and every requirement,
   constraint, and acceptance criterion.
2. The call returns the durable delegation immediately. The parent confirms
   that work started and remains available for normal conversation.
3. Codex works in an isolated actor session and a durable artifact directory.
   The execution can resume after worker loss,
   accept steering, or ask the user a question.
4. A waiting or terminal transition wakes the parent session. The parent reads
   the result, verifies artifacts and tests, and then reports to the user.

The subagent's final text is an input to parent verification, not trusted
delivery. User-facing artifacts belong under `/workspace/user-files`, where a
later parent turn can inspect and attach them.

Console is an installation-wide management surface. Operators can inspect the
task board and Turn trajectory or cancel non-terminal work independently of the
originating channel.

## Ownership and Invariants

- PostgreSQL owns lifecycle, attempts, account selection, normalized runtime
  Turns, and final result/error JSON.
- Elixir owns dispatch, placement, authorization, capacity, retries, wakeups,
  Codex account storage, ModelProfiles, Console APIs, and terminal commit.
- Rust kernel owns identifier/crypto helpers and `generic_hash`.
- Bun Agent Computer owns the Codex process, protocol loop, native Skill root,
  dynamic tools, sandbox, task-level AGENTS, and materialization of the
  account-scoped Codex home.
- RuntimeFabric is live transport. Every worker mutation that affects durable
  state uses a private RPC and an active turn fence.
- A delegation actor session is serial. A superseded worker cannot upsert Turn
  trajectories, update credentials, or commit status for the replacement attempt.
- A prose promise is not durable work. A parent turn that defers work must end
  with a delegation, a scheduled wakeup, or a terminal result.
- Codex runs with approval policy `never` and `danger-full-access`. Any
  approval request that still arrives is accepted for the session; approvals
  never gate execution.

## Architecture

```text
parent agent turn
  -> subagent(start) private RuntimeFabric RPC
  -> PostgreSQL delegation + dispatch ActorEvent
  -> actor session subagent:<delegation-id>
  -> Agent Computer subagent turn
  -> Codex 0.144 app-server
  -> fenced account/Turn/status RPCs
  -> PostgreSQL transition + parent wake ActorEvent
  -> parent verification and user delivery
```

## Domain Model

### Delegation

`subagent_delegations` stores one work item. Important fields include:

- UUIDv7 `id`;
- parent `agent_uid`, `session_id`, `actor_event_id`, and `tool_call_id`;
- `runtime`: `task_worker` by default, or the `deep_research` profile over the
  same Codex implementation;
- operator-facing `title`, verbatim `task`, and optional `background` and
  `notes` text;
- frozen `reply_route`;
- frozen `codex_account_id`;
- `runtime_thread_id` and `workdir`;
- `attempts` and lifecycle timestamps;
- JSONB `result`, `error`, and `metadata`.

`tool_call_id` is unique within the parent agent session, so retrying the
start RPC returns the same work item instead of creating duplicate work.

The status machine is:

```text
queued -> running -> succeeded
                  -> failed
                  -> stopped
          ^    |
          |    v
      waiting_on_user
```

`succeeded`, `failed`, and `stopped` are terminal. `waiting_on_user` remains an
in-flight user story but does not consume an agent running slot or worker
assignment.

### Four-Layer Execution Contract

The background execution path keeps four layers separate:

1. The **control plane** owns the delegation lifecycle, attempts, authorization,
   commands, wakeups, and the orchestrator-facing `execution` projection.
2. The **runtime snapshot** records bounded `progress` and optional official
   `usage` on each Codex Turn. It answers what is active, what tools and files
   have been observed, and how many runtime Turns and threads exist without
   pretending to be conversation history.
3. The **semantic trajectory** records only model-meaningful, final Turn items
   as `ankole_chatml`. It is the ShareGPT-style history used by Console and the
   main agent's paged status reads.
4. The **activation heartbeat** renews the live worker lease every sixty seconds
   while its actor Turn exists. It says only that the worker still owns the
   execution; it never changes the snapshot or trajectory.

These layers deliberately use different clocks and failure semantics. A
semantic checkpoint updates the Turn's `updated_at`; actor heartbeat state owns
runtime liveness. Codex silence is valid, while app-server exit or transport
closure is an execution failure.

### Runtime Turn Trajectory

`subagent_delegation_turns` stores one row per actual Codex Turn. The identity
is unique on `(delegation_id, runtime_turn_id)`. Each row records its delegation
attempt, runtime thread, kind (`agent` or `compaction`), lifecycle status,
monotonic revision, required runtime `progress`, optional official thread
`usage`, error data, timestamps, and one normalized `ankole_chatml` v1
trajectory. Runtime Turn status is one of `in_progress`, `completed`, `failed`,
or `interrupted`; `waiting_on_user` belongs only to the delegation lifecycle.

The delegation's `runtime_thread_id` anchors the lead Codex thread used for
resume and steering. Native Codex subagents create child runtime threads; their
Turns retain those child `runtime_thread_id` values under the same delegation
and attempt. The authenticated delegation route is the ownership boundary, and
an existing `runtime_turn_id` can never move between runtime threads.
The control plane treats those child threads as passive observations of Codex's
internal execution graph. Only the latest lead Turn participates in delegation
lifecycle checks; a child Turn's last observed status may remain `in_progress`
after Codex completes the lead Turn and cannot block or alter that completion.

Agent Computer opts out of message, plan, reasoning, command-output, patch, and
MCP-progress deltas during app-server initialization. The recorder also ignores
those methods if an upstream still emits them; they cannot change revision,
trajectory, progress, or lease state. `item/started` may set the active tool but
does not create a message. `item/completed` adds the final semantic item or
tool-call/result pair, increments unique-item statistics, and checkpoints
immediately. Completed reasoning contributes only its summary; raw reasoning is
never stored. Initial input and accepted steering remain stable user messages.
An unmatched `request_user_input` call with `pending_user_input` metadata is the
only permitted tool call without a result.

Plan, official token usage, and diff-derived file paths are state snapshots, not
trajectory messages. They coalesce for at most five seconds and flush on every
terminal path. The `turn/diff/updated` body is not stored; a completed
`fileChange` may still retain its final patch arguments in the semantic tool
pair. Tool names and counts use the same canonical naming function as
trajectory projection, count each completed item id once before trajectory
truncation, and stay sorted. Deep Research uses this same path; it does not copy
raw rollout JSONL into a second archive model.

Before persistence, Agent Computer removes credential-shaped keys and text,
bounds nested values, and keeps each compact encoded trajectory at or below
256 KiB, beneath PostgreSQL's 512 KiB hard limit.
The trajectory metadata records redaction, truncation, and omitted item counts,
which Console shows on the Turn. PostgreSQL repeats the format, role, and byte
limit constraints, so a wrapped JSON-RPC event is not a valid trajectory.

Background execution stays in Codex Default mode so normal execution and plan
updates remain available. The pinned app-server exposes native
`request_user_input` to the model but rejects it in Default mode, so Agent
Computer projects one control-only dynamic tool named `request_parent_input`.
The task-level AGENTS document directs the lead agent to use that tool and child
agents to return questions to the lead. Both this bridge and the native
`item/tool/requestUserInput` compatibility path normalize to the same pending
`request_user_input` trajectory item; no second lifecycle or storage contract is
introduced.

Each checkpoint is retried up to three times with bounded backoff after a
transport failure. The monotonic `revision` makes a lost-response replay
idempotent: an older revision returns the current row and an equal revision is
accepted only when every checkpoint field is identical. Divergent equal
revisions fail with `subagent_turn_revision_conflict`; a newer revision may
advance only through the Turn status machine. The upsert
revalidates worker route, activation, assignment, and attempt inside the same
transaction, while updates to an existing Turn revalidate its immutable runtime
thread. A stale worker cannot overwrite the replacement attempt. If retries are
exhausted or a checkpoint is explicitly rejected after the writer has been
fenced, the control plane interrupts any remaining active Turn before it commits
the terminal delegation failure.

For each stored Turn returned by Console's bounded detail timeline, Console
renders the complete bounded trajectory together with its progress and usage
snapshot. `subagent(status)` always returns the latest execution summary and,
by default, the newest three semantic groups from lead agent Turns in the
current attempt. A matching assistant tool call and its tool result are one
indivisible group. The caller may request one to twenty groups or follow an
opaque cursor to the immediately older page; each page is also bounded to 24
KiB and remains chronological. Child trajectories and compaction Turns do not
enter this page because concurrent child messages have no valid global chat
order. Attempt history prefers the last lead assistant report and never lets a
later passive child observation replace it. An attempt with no Turn does not
project a stale Turn from an earlier attempt.

## ModelProfiles and Codex Accounts

Model profiles are owned by `Ankole.AIAgent.ModelProfiles`. The `coding`
profile has two valid shapes:

```json
{"provider_id":"openrouter-main","model":"openai/gpt-5.4"}
```

or:

```json
{"codex_account_id":"account-id-from-auth-json"}
```

The first shape runs Codex through AIGateway. The second selects a named
ChatGPT subscription account. When no explicit coding account is selected,
the delegation freezes the synthetic account identity `aigateway`.

`codex_accounts` stores installation-wide subscription accounts:

- `account_id`, extracted from `auth.json`, is the natural primary key;
- `name` is supplied by the operator and is unique case-insensitively;
- `encrypted_auth_json` is encrypted with an account-specific derived key;
- `auth_hash` is the string returned by the kernel's `generic_hash`;
- timestamps support operator visibility.

The name is the selection label in Console. The account id is stable runtime
identity. Creating or replacing authentication always parses the account id,
computes the hash in the control plane, and stores the encrypted bytes and hash
together. Authentication updates cannot change account identity.

A Codex account cannot be deleted while an agent coding profile or a
non-terminal delegation references it. Account responses expose metadata and
`auth_hash`; they never expose `auth.json`.

## Dispatch, Capacity, and Recovery

Starting a delegation inserts the queued row and appends a dispatch event to:

```text
{agent_uid, "subagent:<delegation-id>"}
```

Two capacity boundaries apply:

- at most three `running` delegations per agent;
- at most `agent_computer.subagent.max_delegation_turns_per_worker` active
  delegation assignments per worker, default `9`.

Placement is not an execution attempt. Worker assignment, the per-agent slot,
`attempts + 1`, actor activation, and delivery persistence commit together.
If no worker or slot is available, the delegation stays visibly `queued` and
does not consume an attempt. A definitive transport-send failure before worker
acceptance compensates the claim back to `queued` and restores the attempt
counter.

An official subscription account admits at most one live delegated Codex turn
across the installation. The live worker assignment is the execution lease for
that account's single shared Codex home; it remains held through terminal status
persistence until the worker finalizes its actor turn. This prevents concurrent
processes from overwriting refreshed auth or Codex-owned state. The synthetic
`aigateway` account keeps normal worker and per-agent concurrency because it has
no mutable subscription credentials.

When a task enters `waiting_on_user`, its status transaction releases the agent
running slot and appends the parent wakeup. The worker's immediately following
no-op turn completion releases the assignment and nudges queued delegations.
Answering the question redispatches the waiting delegation and claims a new
execution lease.

Every active worker Turn renews its actor lease once per minute, independently
of Codex notifications. There is no fixed wall-clock timeout for valid
long-running work, and a quiet model or tool cannot make a healthy execution
look dead. App-server exit, channel closure, worker loss, or actual lease expiry
still enters the existing failure and recovery path.

Automatic dispatch and recovery are capped at three execution attempts.
Exhaustion commits `failed` with `attempts_exhausted` and wakes the parent.
An explicit parent continuation through `subagent(steer)` may allocate a later
attempt because it is new user intent, not an automatic retry loop.

The normal recovery path resumes `runtime_thread_id`. If Codex reports an
unknown thread, Agent Computer creates one replacement thread and supplies the
original task, continuation instruction, current workspace, and a bounded
summary of at most three prior attempts derived from Turn trajectories. The
history is used only for thread recreation; routine resume relies on Codex's
own rollout and compaction state.

## Account-Scoped Codex Home

All workers mount the installation's shared workspace. Codex homes are keyed by
runtime account identity, not by agent or delegation:

```text
/workspace/shared/.ankole/codex/<account_id>
/workspace/shared/.ankole/codex/aigateway
```

Every Codex process for the same account uses the same `CODEX_HOME`. Different
ChatGPT accounts never share Codex rollout, SQLite, or authentication state.
All AIGateway-backed coding profiles share the synthetic `aigateway` home.

Agent Computer writes a system-owned `config.toml` before each launch. The
official-subscription form uses Codex's normal endpoint. The AIGateway form
adds the system provider/base URL and the short-lived agent AIGateway key.
Approval, sandbox, file credential storage, and native web-search settings are
fixed by Ankole.

For a subscription account, launch and refresh follow one observable cycle:

1. `codex.account.resolve` returns the delegation's frozen `account_id`,
   decrypted `auth_json`, and stored `auth_hash` to its active worker turn.
2. Agent Computer atomically overwrites `$CODEX_HOME/auth.json` with mode
   `0600` immediately before starting Codex.
3. Codex may refresh that file in place while it runs.
4. After the Codex turn ends, Agent Computer reads the file and computes
   `generic_hash` locally.
5. Only when the string differs from the launch hash, the worker sends the new
   `auth_json` through `codex.account.auth.update`.
6. The control plane validates account identity, recomputes the hash, encrypts
   the bytes, and stores both values atomically.

The comparison is a mandatory Codex-process cleanup step, including abnormal
process exit. Update transport failures receive bounded retries. A terminal
delegation status is not committed while a changed credential file has failed
to persist.

The update RPC does not accept a caller-provided hash. Both account RPCs are
private RuntimeFabric operations scoped to the active delegation turn; they
are not AIGateway HTTP endpoints.

## Agent Computer Turn

The subagent handler:

1. fetches the durable delegation and resolves its parent workspace;
2. resolves the frozen Codex account and materializes the account home;
3. rebuilds the task-level AGENTS file, native enabled-Skill root, and dynamic
   tools;
4. starts or resumes Codex app-server;
5. assembles Codex notifications into one normalized row per runtime Turn;
6. persists waiting, terminal, or retryable outcomes before exiting.

The handler never starts background work and yields. Its exit ends the worker
attempt. Runtime liveness comes from the actor lease rather than an in-process
job registry.

Codex is pinned to `0.144.0`. Structured `codexErrorInfo` drives recovery before
message matching. Transient failures retry the current thread with bounded
backoff. Context overflow uses Codex-native compaction once and waits for the
canonical completion notification. Unknown-thread recovery is bounded to one
replacement thread.

Successful `result` JSONB includes:

- `summary`, `output_text`, and `report`;
- execution `attempt`, `workdir`, and `runtime_thread_id`;
- normalized token `usage`;
- diff-derived `files_changed`;
- the terminal Codex turn status.

These fields are verification inputs. The parent still inspects the worktree
and artifacts before reporting success.

### Deep Research Profile

`deep_research` is not a second worker, runner, or agent hierarchy. It is the
ordinary Codex delegation with the `deep-research` Skill and a small set of
before/after hooks. Before execution, Agent Computer enables Codex native
multi-agent support without overriding the default collaboration mode, requires
the research Skill, wraps successful web and
browser observations in source archives, and starts the resource budget. After
Codex proposes a final result, Agent Computer passively reads the available
artifacts and reports objective form issues alongside the candidate. It does
not rewrite artifacts, reject research quality, or start a repair Turn. The
parent decides whether to deliver the candidate, make a small direct correction,
or continue the same `runtime_thread_id` with `subagent(steer)` when the work
benefits from the existing Codex context.

Native Codex subagents remain model-directed and advisory. There is no host
fan-out runner, isolated AIGateway reviewer conversation, source-count floor,
quality score, or staged research gate. General research and domain-neutral ACH
share this profile; domain packs and trajectory backtesting are separate future
work.

## Handoff and Capability Projection

`task` is the complete instruction and is passed verbatim as the first Codex
user input. Agent Computer only validates that it is non-blank; it does not
parse, split, or reformat it. Steering, question answers, retries, and thread
recovery remain later user inputs.

Every dispatch materializes a private, read-only `AGENTS.override.md`. Existing
same-level Codex guidance is included first, followed by SOUL, MISSION, optional
saved durable context, optional `background`, optional execution `notes`, and
execution context. When a
same-level AGENTS file already exists, the merged document overlays that
existing sandbox mountpoint without changing its host contents. Otherwise,
Codex discovers the document through its native project-doc fallback from a
process-private mount; Agent Computer never creates a placeholder in the user
workdir. Requirements belong in `task`, not `notes`. The task, Skill catalog,
tool list, and parent transcript are not duplicated into AGENTS.

All Skills enabled for the parent turn are mounted into a delegation-specific
Skill root. After app-server initialization and before thread start or resume,
Agent Computer calls `skills/extraRoots/set`, forces `skills/list` to reload,
and verifies that every enabled Ankole Skill is natively discoverable. A Skill
with a database overlay receives a merged `SKILL.md` facade while other
resources stay mounted from their source directory. A missing enabled Skill is
a setup failure; there is no `skill_view`, prompt-catalog, or MCP fallback.

The projected Ankole tools are `web_search`, `web_fetch`, the full Brain surface
(`memory_search`, `memory_browse`, `memory_open`, `memory_update`, and
`memory_health_check`), and every `browser_*` tool except `browser_run`. Brain
reads and writes resolve through the server-validated parent conversation scope;
the subagent cannot choose an owner, store, or author. Browser work uses a private
`subagent:<delegation_id>` execution scope and screenshot results remain Codex
`inputImage` parts. Codex-native shell, file, patch, and planning capabilities are
not projected twice. Skill writes, user delivery, scheduling, clarification, and
nested delegation remain parent-owned. The sole clarification bridge is
`request_parent_input`: it can pause the lead Turn and wake the parent, but it
cannot answer a question or interact with the user itself.

The worker does not subscribe to or use streaming message deltas. The last
completed Codex `agentMessage` is the canonical delegation report. If Codex
completes without one, Agent Computer asks once on the same thread for a final
report; another empty completion fails with `codex_empty_report`.

## Tool and Steering Contract

The model-facing `subagent` tool has five asynchronous actions:

- `start` creates durable work from a title, complete `task`, optional
  `background`, optional `notes`, optional workdir, and optional output schema;
- `list` shows work visible from the current parent session or channel;
- `status` returns the latest execution summary and three semantic groups by
  default, with optional `trajectory_limit` and `trajectory_cursor` pagination;
- `steer` appends instructions or answers a pending user-input request;
- `stop` commits cancellation.

There is no blocking wait action. Parent turns remain responsive while the
delegation runs. Pagination fields are accepted only by `status`.

Running steering uses Codex `turn/steer`. The mailbox event remains durable
until Codex accepts it. If steering loses the race with a completed turn, the
terminal Codex result is preserved. A transport or
protocol failure before completion fails the execution attempt and leaves the
instruction replayable. Terminal status commit checks for unapplied steering
under the delegation lock.

## Waiting for User Input

When the lead calls `request_parent_input` (or app-server emits the compatible
native `requestUserInput` request), Agent Computer interrupts the current Codex
Turn, stores that Turn as `interrupted` with a
`request_user_input` reason, stores normalized questions on the delegation, and
commits the delegation as `waiting_on_user`. The parent wake event is appended
in the same transaction. The control plane rejects this transition unless the
latest lead Turn is interrupted with that reason and the current attempt
contains a `request_user_input` tool call in that same lead Turn, marked
`pending_user_input` and without a matching result. A native child cannot pause
the delegation directly; its request is rejected with an instruction to report
the question to the lead agent. Other child states remain Codex-internal and do
not gate the delegation.

The parent asks the one-to-three questions through the normal `clarify` tool.
Card-capable channels can render interactive choices; other channels use text.
Each question ends its parent turn. When answers are collected, the parent
calls `subagent(steer, answers)` and the delegation is redispatched.

## Wakeups, Cancellation, and Console

Waiting and result-bearing terminal transitions append one of:

- `subagent.delegation.waiting`;
- `subagent.delegation.completed`;
- `subagent.delegation.failed`.

Wake payloads include the delegation id, title, status, runtime, mode, bounded
summary, passive delivery status and issue count, workdir, and frozen reply
route. The parent wake turn asks the pending question, verifies and delivers the
candidate, or continues the same delegation; it cannot end as silent success.

A succeeded or failed delegation is settled but resumable. If the goal still
needs work, the parent calls `subagent(steer)` on that delegation; the control
plane queues another attempt and Agent Computer resumes the existing
`runtime_thread_id`. Active Turns receive the same command through native steer.
Only an explicitly stopped delegation cannot be resumed.

Cancellation commits `stopped` first. Queued and waiting work cannot start
after that commit. Running work additionally receives an interrupt command;
late worker writes are rejected by the turn fence.

Console provides:

- a three-column Subagent Tasks board;
- task details, structured result/error, and semantic Turn rows grouped by
  execution attempt;
- cancellation for non-terminal work;
- a single LLM Providers configuration area containing AIGateway provider rows
  and named Codex accounts;
- agent ModelProfiles editing where `coding` selects AIGateway or a Codex
  account by its operator-supplied name.

## Verification Gates

The implementation is protected by package-local gates for:

- migration, schema constraints, encrypted account storage, account identity,
  unique names, and kernel-derived hash updates;
- model-profile validation and frozen delegation account identity;
- private RPC route/turn fencing and auth refresh writeback;
- no-worker placement, capacity, attempts, waiting slot release, wakeups, and
  cancellation;
- completed-item projection, runtime snapshots, redaction and byte bounds,
  checkpoint retries, strict revision idempotency, lead-only pagination,
  attempt history, and stale-worker rejection;
- Codex 0.144 app-server success, resume, unknown-thread recovery, native
  compaction, steer races, Default-mode parent-input interruption and
  cross-process answer resume, abort, approval acceptance, and auth refresh;
- task-level AGENTS isolation, native Skill discovery and overlays, the tool
  allowlist, Browser scope, and screenshot image projection;
- OpenAPI generation and Console type checking;
- a real parent-to-Codex PPTX scenario that reads the native Skill, runs
  OfficeCLI, verifies the two-slide artifact independently, and delivers it
  through `reply_attachment` and fake Feishu.
