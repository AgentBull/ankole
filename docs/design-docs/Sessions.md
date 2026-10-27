# Sessions

A Session is one Agent's execution context, identified by `(agent_uid,
session_id)`. `Ankole.Sessions` owns admission, the Driver, tools, continuations,
retries, and completion. Surrounding domains own the related records, which have
separate writers and lifetimes: AIGateway owns exact model inputs and outputs,
provider artifacts, branches, and compaction; Conversations owns public
statements; and Signals owns durable stimuli.

`Prompt.Delimiters` owns the boundary tags for quoted conversations, external
events, environment fields, and recalled memories, and all input builders share
these boundary names. Each input kind follows its own escaping policy:
conversation and event text replace reserved delimiters, memory text escapes its
reserved tags, and environment fields also stay on a single line. This boundary
encoding does not replace admission rules for Skill lessons or authorization
checks.

Each Agent participating in a conversation uses `conversation:<public_uuid>` as
its Session ID. Because of this, two Agents in the same external room share
public history while keeping separate Sessions and model states. A cron rule
uses its own stable Session, while a Background Agent Job or Workflow task runs
in its own execution context and can publish results or notices to an explicitly
routed conversation.

`Sessions.Key` constructs and parses the transport key formats:
`conversation:<uuid>`, `cron:<id>`, `job:<id>`, and `wf_task:<id>`. Any other
valid UTF-8 string that is nonblank and free of NUL bytes is treated as a named
Session key. `parse/1` classifies the key, and each work domain validates its
own ID. To protect internal execution boundaries, `routable?/1` excludes private
Job and Workflow task keys from external route selection.

`SessionWorkspace` is an Ash resource stored in the `sessions` table. Its
persisted `kind` selects exactly one owner: a named Session, a Conversation, a
Background Agent Job, a Workflow task, or a Cron rule. Work references use typed
foreign keys that include both the tenant and the Agent, whereas a Conversation
reference includes only the tenant because its participants can run in separate
Agent Sessions. Ankole refuses to allocate a workspace if its owner row is
missing.

PostgreSQL generates `session_id` directly from these owner columns, so callers
cannot write a key that disagrees with its owner. When an owner row is deleted,
its foreign key removes the associated workspace. During workspace allocation,
Ankole locks the referenced owner before acquiring the Session advisory lock,
and the `advance_epoch` action advances the locked workspace once.

## Durable Owners

| Owner | Durable truth |
| --- | --- |
| `Signals` | Canonical stimulus, frozen authorization, Agent/Session target, queue sequence, admission and terminal state |
| `Sessions` | Numeric workspace, Driver epoch, runtime continuation and tool receipts |
| AIGateway | Exact caller input, model output, tool calls/results, original provider artifacts, checkpoint, and visible Response branch |
| `Conversations` | Shared Message UUID/sequence, participants, public statements and external facts |
| `Conversations.Delivery` | External send intent, attempt fence, provider confirmation, and recovery result |
| `AgentWorkers` | Worker provisioning and incarnation; its in-memory route can be rebuilt |

`RoundState`, `Receipt`, and `AmbientJudgment` are Ash resources in the Sessions
domain whose write actions run inside the enclosing Session transaction (see
[Persistence and Operations](#persistence-and-operations)). On `RoundState`,
`record_once` keeps the first round snapshot if recovery records the same model
message again. On `Receipt`, `commit_result` stores a tool result together with
its domain write. A transaction-scoped advisory lock on the receipt identity
serializes concurrent executions of the same tool call, so the second execution
reads the committed receipt instead of repeating the domain write.

Receipt results, round pages, and result journals use the shared strict JSON
object type. If a tool or caller returns an unsupported runtime value, Ankole
rejects the write and rolls back its domain effects; PostgreSQL also rejects
non-object journal values. When a round is recorded, the same transaction
deletes its receipts. By contrast, an `AmbientJudgment` retains its original
route and progress: if its accepted message anchor is deleted, that removal only
clears the message reference and degrades attribution.

PostgreSQL is the sole recovery source of truth—never a Driver, Worker process,
socket, or PubSub event. Every transaction that commits an input also commits an
`EnsureDriver` job. Immediate wakeups reduce latency after commit, while startup
reconciliation and durable recovery find accepted work even if the producer
exits right after committing.

`Sessions.Events` broadcasts over `Ankole.PubSub` using input and state topics
scoped by tenant, Agent, and Session. It accepts scalar identities and encodes
the Agent and Session identifiers before joining the topic segments, so embedded
delimiters cannot alter the target or channel, and it does not depend on any
Signal schema or execution module. Input notifications carry only an already
accepted Signal ID—they neither create work nor start a Driver. On the public
wakeup path, Ankole calls `ensure_driver/1` before publishing a ready input,
whereas future-dated inputs wait for their stored `EnsureDriver` deadline.

Both Driver types set their tenant context and subscribe to the input topic
before rebuilding their initial inbox. Consequently, the initial rebuild catches
any input published before subscription, while later publications enter the live
inbox handler. When a notification arrives, the handler loads the Signal under
its Agent and Session, verifies authorization, and applies the postponement
rules for admission, preparation, round recording, and finalization. Duplicate
notifications do not affect the durable queue order, and `EnsureDriver` plus the
Reconciler repair any lost notifications.

## Persistence and Operations

`Ankole.Sessions` is the Ash domain for Sessions and owns `SessionWorkspace`,
`RoundState`, `Receipt`, and `AmbientJudgment`.

Each multi-step Session operation—such as `admit_input`, `finalize_run`,
`record_run_round`, `defer_run_retry`, `apply_command`, `execute_receipt`, and
`reset_session`—runs inside `Repo.transact_top_level/2` in its owning module
(`Admission`, `Run`, `Commands`, `Notices`, `CodexJob`, or `Receipts`). Keeping
the transaction in one function makes the lock order and compensation writes
explicit.

Because these operations are top-level entry points, calling them inside an
existing `Repo.transact` block or generic action raises
`Ankole.Errors.Framework.NestedOperation`. Callers that already own a
transaction—such as a tool commit inside a receipt or an operation in another
domain—must call the corresponding `*_in_tx` function instead. Post-commit side
effects run either through the `after_commit` option of
`Repo.transact_top_level/2` or after the outer transaction returns:
`defer_retry` publishes the Session status, `record_round` publishes tool-result
events, `reclaim_stale` publishes failed responses, `execute_receipt` runs
receipt notifications, and `Run.finalize/3` runs `Run.after_finalization/1`.

Sessions reads and mutates Signals exclusively through `Ankole.Signals`, using
its queue readers (`session_queue/3`, `session_status_signal/3`), row lockers
(`lock_signal_in_tx/1`, `lock_session_signal_in_tx/2`, `lock_signals_in_tx/2`),
state-transition helpers (`transition_in_tx/3`, `reset_attempts_in_tx/2`), and
domain defines. Similarly, Sessions reads rows from other domains through their
domain defines, and every locked read registers its lock identity with
`Ankole.LockOrder`. During workspace allocation, Sessions locks the workspace
owner with `FOR KEY SHARE` through the owning domain.

Ambient triage returns a typed outcome that drives the next step:
`{:ok, :intervene, signal}` admits the input, `{:ok, :settled}` rebuilds the
queue, `{:ok, :deferred, signal}` waits until the retry deadline, and
`{:error, reason}` follows the admission error path.

The operator console lists model histories through the Console JSON:API
(`/api/v2/ai-gateway/conversations`) by calling the `console_list` read action
on `AIGateway.Schemas.Conversation` with keyset pagination. Sessions owns that
action, its preparation module (`Sessions.ConsoleQueries.Prepare`), and the
relationships on which it filters: the public conversation, the direct-message
peer, and the messages. Display metadata comes from conversation
calculations—`kind`, `display_name`, `channel_kind`, and `signal_adapter`
(loaded in a single batch per page by `Sessions.ConsoleQueries.Channel`)—together
with the `message_count` aggregate. To inspect an individual conversation, the
console calls the `console_list` read action on `AIGateway.Schemas.Message`,
ordered oldest first.

The Session picker queries `GET /api/v2/agents/:agent_uid/sessions` and shows
only the selected Agent's persisted Sessions within the active tenant. Routes
for conversation standing orders are served at `GET` and
`PUT /api/v2/conversations/:conversation_id/standing-orders`, without wrapping
an extra outer transaction around the domain operation.
`Sessions.AmbientCuration` validates and persists each edit with the current
Principal recorded as the actor. Subsequent Signal snapshots read the stored
standing order, while clearing the order omits it from later snapshots.

## Turn Progression

`Sessions.Turn.step/2` computes each execution step as a pure state transition.
Given the current Turn and an incoming event—such as an operation result, inbox
notice, Worker message, model completion, or timer expiry—it returns the updated
Turn and an ordered list of commands. The Turn holds its Run, pending calls,
observation state, and Worker acquisition state in memory; it has no process,
database table, or recovery journal of its own.

The Driver executes those commands through the Admission, Run, Tools, Commands,
and Worker contracts, and feeds each operation result back to the Turn. In doing
so, the Driver owns registry membership, PubSub subscriptions, Task monitors,
stream handles, timers, tracing, and activity publication. Commands stay private
to this Turn–Driver pair rather than forming a shared work engine or persistent
command queue.

Within a turn, Turn governs tool scheduling, result acceptance, receipt
restoration, round completion, continuation, and failure policy—including the
rule for repeated tool failures, which also folds committed history during Run
recovery. However, in-memory Turn state cannot authorize durable writes; only
Run and the Ash resources hold transaction authority, so no proposed record,
retry, or finalization can advance past that boundary until its database
operation commits. If an operation returns an epoch mismatch or closed-run
error, the Driver stops immediately.

During preparation, the Driver replays durable inbox controls before resuming
model or tool I/O, and if a newer epoch has superseded the workspace, Ankole
refuses to resume the previous Run. When a round commits, the Driver cancels
that round's transport and observation tasks before advancing to the next
boundary. Worker acquisition follows a bounded policy that uses safe probes when
a prior call's result is unknown, and live activity reflects an in-process
observation of those pending calls inside the Driver.

Tests mirror this separation of responsibilities: Turn unit tests exercise event
sequences without a Driver or database; Receipt and Run tests verify atomicity
and recovery against PostgreSQL; and Driver integration tests check process
ordering, cancellation, presentation, single-writer guarantees, epoch fences,
and cross-node behavior.

State publications run in the outer transaction owner's process only after
commit. A process-local guard rejects publication calls made while a transaction
is still open, though passing the guard does not by itself prove commit, and
transaction code must never spawn a Task to publish pending facts. When a turn
finishes, completion publishes a single `turn_completed` notification carrying
its Signal ID and outcome. Transient activity uses a separate publication
channel guarded by Driver PID, epoch, and revision checks. Subscribers treat
`turn_completed` strictly as an observation: no subscriber commits a reply or
dispatches a Delivery in response to a completion notification.

`Sessions.driver_name/1` defines the shared registry identity for both ordinary
and Job drivers. `driver_pid/1` and `active_model_conversation_id/1` are
read-only locators that neither start a process nor create model history, while
External Preview uses its stored checkpoint identity when recovering a completed
presentation.

`Driver.display_snapshot/1` inspects a running Driver by verifying the current
Signal and workspace epoch, reading the active stream's display snapshot, and
prepending completed reasoning from earlier Responses of the same Signal via
ModelHistory. While tools are executing, the latest recorded Response supplies
the text and reasoning. Pod SSE reads this snapshot right after subscribing so a
newly connected client can render the prefix received so far and then follow
subsequent stream deltas.

Both Driver types register under the same global name before initializing.
`ensure_driver/1` reuses an existing PID and accepts an `already_started` result
when another caller wins registration. Process supervision belongs to the
DynamicSupervisor, whereas Session write safety comes from PostgreSQL: the
stored workspace and Driver epoch fence out any writer that survives a takeover,
and Worker commands also carry the current incarnation and run reference. No
other Agent or Session ever writes into a Session's model history, although
other Sessions can append public statements to a shared conversation without
altering the running model log.

## Diagnostic Correlation

Optional tracing correlates intake, admission, model requests, finalization, and
Delivery through the durable Signal ID. When intake runs inside a caller-owned
transaction, it records `prepared_in_tx`, and only the post-commit path records
`committed`. Admission records `observed_committed`, queue age, readiness delay,
and its final outcome. These trace events neither wake work nor establish
durability.

Each execution attempt records its workspace epoch and attempt number. If a turn
absorbs additional inputs, the trace records how each absorbed input relates to
the root Signal and the selected reply Signal. Likewise, each Delivery records
its delivery key, source Signal, attempt number, send or reconciliation phase,
and outcome (including unknown and stale results). Because asynchronous recovery
can start a fresh trace from these durable IDs, Ankole needs no persistent trace
registry.

Stage spans carry only identifiers, states, and elapsed times—never stimulus
bodies, prompts, tool arguments, credentials, or attachment bytes. They read
facts already loaded by the owning operation without issuing extra business
queries or RPCs, and missing or failed tracing never alters admission, retries,
sends, or commits.

## Admission and Responsibility

Internal control, revision, ambient, and scheduled paths require the private
`kernel` producer marker recorded at intake; an external event with the same
type string is still treated as untrusted external data, and scheduled work must
also carry an actual ScheduledEvent-to-Signal link. Callers cannot use payload
JSON fields to select internal paths, hide unread Messages, name the requester,
or invent conversation policy.

Intake freezes the requester's authorization snapshot at acceptance, and
admission verifies that snapshot again before starting work. Human requests
record both the Human UID and access version, so revoking and later restoring
access cannot revive a queued request from an earlier version. Service stimuli
run under explicit service authority. An ambient proposal defaults to the
Agent's own responsibility, though a verified Human request can supply the
responsible Human through the judged public Message: attribution uses the
Message ID selected from the observed batch together with that author's current
authorization, and a subsequent message from another speaker does not clear that
request.

Generic Signal payloads and CloudEvents extensions never establish a Human
identity. Both the runtime environment and Brain disclosure rely strictly on
frozen authorization snapshots and canonical conversation records. Being able to
read a group message does not grant an Agent the message author's action
authority; delivery destination, execution identity, and requester authorization
remain independent.

When `Run.kind/1` identifies a kernel-produced ambient input, the Driver runs
`AmbientTriage` in an asynchronous task before foreground admission:

1. `Ambient.resolve/2` checks the tenant and Agent through the Session admission
   owner, folds pending observations from the same room, and rejects expired or
   changed scenes. Triage then assembles an `Observation` from the public room,
   Agent documents, and active work candidates without creating an AIGateway
   conversation or a Session workspace.
2. Outside any database transaction, triage sends a single stateless request to
   the light model using the sampling settings defined on the light profile.
3. `AmbientCuration.record_judgment/3` re-runs admission checks under the tenant
   and Agent locks, locks any target Job and participating Sessions, verifies
   the scene against the current clock, and persists the canonical decision. If
   the tenant is suspended, the Agent is disabled, or the observation expires
   while the model call is in flight, Ankole refuses to commit the proposed
   route. If the scene changed in the meantime, Ankole aborts the write and
   returns control to the observation resolver. Otherwise, the same transaction
   silently completes `NOOP` and `HANDOFF` inputs; for `HANDOFF`, it locks the
   target Job before locking participating Sessions and commits one idempotent
   steer alongside the judgment.

Only a committed `FOREGROUND_REPLY` or `NEW_WORK` judgment allows ordinary
admission to create model history and advance the workspace epoch; if the turn
later retries, it reuses that persisted judgment instead of asking the model to
pick a new route. If the light-model request fails, triage defers the input and
increments `attempt_count` while leaving `last_attempt_at` empty so a newer room
batch can supersede it, and on the third failure it records a silent `NOOP`.
When no light profile is configured, triage likewise records a silent `NOOP`
without posting a configuration notice to the room. Triage also checks the
Agent's token quota before building model context: if the quota is already
exhausted—or if another request consumes the remaining quota before AIGateway
checks it—triage immediately records a silent `NOOP`. Neither quota nor profile
rejection allocates a Session workspace, creates model history, or consumes a
model retry.

## Prepare a Model Request

Before calling a model, the runtime assembles instructions, the tool catalog,
input items, the model binding, and the Brain execution context, passing that
context explicitly to AIGateway. Function tool declarations in a Session default
to `strict: false` unless the tool explicitly sets `strict`, because the
Responses API treats an omitted `strict` flag as strict mode—which forces the
model to populate every declared property—and Session tools declare optional
parameters that the model must be allowed to omit. Custom (freeform) tools have
no `strict` field and pass through unchanged. Public caller metadata remains
opaque to the model platform, so a `signal_id` supplied on an OIDC request
cannot borrow another execution's authorization or memory scope. Codex Jobs
carry their runtime binding at the authenticated execution edge.

Prior to sending a request, the runtime snapshots a bounded window of unread
public statements from the conversation, and the outgoing AIGateway request
atomically records `conversation_read.max_seq` and `message_ids` (the
`conversation_read` payload carries only `id`, `max_seq`, and `message_ids`).
Subsequent requests derive their read watermark from the visible model branch,
skipping the running Session's own published output (matched by both author
Agent and Session) while still reading statements from other Agents. Retries,
forks, truncations, and compactions follow the committed watermarks on their
visible branch. Only a completed ordinary Response marks those background
Messages as consumed: a compaction checkpoint may retain caller metadata for
lineage, but that metadata does not prove that a pending model request consumed
the Messages, so a failed request after compaction rereads the same unconsumed
background.

Signals keep their original envelope and the IDs of the stimulus Messages that
triggered the turn, without freezing background conversation history. In native
conversations, the input environment identifies the current Human speaker by
display name and Principal UID so that multiple people in one room stay distinct
in the model prompt. Provider reasoning, cryptographic signatures, and other
continuation artifacts stay solely in AIGateway as exact records—they are
neither copied into the public Message table nor reconstructed from plain text.

Completed model history, compaction summaries, tool calls, and tool results
replay verbatim as stored. Edits to background conversation messages neither
rewrite prior model history nor restart an active turn, and because edits
preserve sequence numbers, later turns do not reread edited Messages that were
already consumed.

## Execute Tools and Asynchronous Work

Every tool call must supply complete, valid JSON arguments before execution; if
the arguments are incomplete or invalid, Ankole returns a tool error so the
model can submit a complete call.

Tool results are persisted before the model continues, and recovery reuses any
committed result rather than re-running the tool. If a tool call was already
dispatched to a Worker and its outcome is unknown on recovery, Ankole marks the
call as interrupted instead of silently re-executing it. Sequential calls run in
declared order, whereas parallel calls record independent receipts. When a
Worker reconnects or adopts an existing workspace, committed progress is
restored under the current workspace epoch.

During recovery, a Worker result can complete a pending tool batch before a
newly requested workspace open finishes. When the Driver records that completed
batch, it cancels the pending workspace-acquisition tasks and timers while
retaining the fact that the run requested a Worker, so the next tool batch can
acquire the workspace again. Conversely, if the model finishes the turn without
further tool calls, the Driver closes the workspace for that exact Signal and
the Worker releases its slot. A pure text run that never requested a Worker
sends no Worker messages at all.

`stale_driver` and `run_closed` are control outcomes rather than tool errors.
Every asynchronous task forwards them straight to the Driver's stop path, so a
fenced tool task never converts them into a model-visible error or starts the
next call in its round.

When an Ash tool raises an unexpected error, Ankole returns a generic error
message to the model and formats diagnostic logs through
`Ankole.Logging.failure_fields/3` so private action arguments stay out of logs.
Job Driver operation failures, receipt notifications, workspace closes, and
Session reconciliation failures use the same scrubbed logging—recording the
operation name without request payloads—while Job Drivers preserve their own
retry policy. If a post-commit receipt notification fails, the committed receipt
remains valid and its domain write is never repeated.

Background Agent Jobs and Workflow calls inherit their parent's source
authorization, explicit reply route, and owner Session, and their dispatch,
completion, failure, and attention notifications enter through the standard
Signal intake. Parent and child completions commit as independent records: a
finished child never overwrites its parent's model branch, and a long-lived
recipient Session can retain an ended model history, whereas orphaned pinned
histories and cyclic owner chains are rejected as invalid.

When a cron rule fires, it enqueues a Signal in the rule's stable Session with
explicit native or external target conversations. Turn completion commits every
native statement and every external Delivery intent in a single transaction, and
failure, quota, suspension, or unavailable-model notices publish to the same
target set. Each destination conversation's own Session observes those public
reports on its next model request, while the cron Session keeps its own isolated
model state.

`WorkflowTask`—rather than the shared `RunType` extension contract—owns recovery
of terminal inputs, retry exhaustion, task-progress locking, attempt
restoration, unavailable-model diagnostics, and locked task transitions for
Workflows. When finalization runs inside a caller-owned transaction, the Session
result returns the Workflow transition to the caller, and
`Run.after_finalization/1` runs terminal cleanup only after the outer
transaction commits. Ordinary cancellation and Human access revocation apply
their respective rules to work that has already been admitted.

Injecting an input into a Workflow task locks the Workflow parent and call rows
before locking the Session, Workspace, and Signal rows. The same lock order
governs a fresh steer that arrives after tenant suspension: Ankole rejects and
completes only the fresh steer while leaving the already admitted task and its
active input attempt untouched.

`RoundState` captures and restores six scalar loop-control counters, while round
pages, steers, tool results, and Workflow attempts follow their own recovery
contracts. Each round commit writes tool journals, completed wait inputs,
`RoundState`, and receipt deletions together in one epoch-fenced transaction. On
recovery, Run queries AIGateway for the caller's visible branch suffix;
compaction checkpoints and unmatched tool journals do not prematurely truncate
that suffix.

## Revisions and Completion

New Human inputs, control commands, and explicit input revisions reach a running
Driver only at durable step boundaries. Explicit edits, supplements, and message
removals travel through the revision path while preserving the original trigger
and frozen authorization snapshot.

Terminal validation distinguishes between withdrawing the turn's trigger and
deleting background context. If an explicit input source was withdrawn,
validation returns `:signal_canceled` and cancels the turn. If only a background
Message that the turn read was deleted, validation returns
`:signal_context_canceled`, stops the turn, and posts a `context_withdrawn`
notice instead of the drafted answer. Edits to background Messages do not
invalidate a running request, and in both withdrawal cases, already completed
model history stays intact.

Completion resolves the turn's public presentation once. Silent completion emits
nothing; a visible native result commits as a public Message inside the
completion transaction; and an external result commits as a durable Delivery
intent whose provider transmission can succeed or fail independently afterward.
Raw streamed model text, reasoning traces, and tool outputs never become public
statements automatically.

When a turn generates images, Ankole prepares the image bytes before opening the
final Session transaction. That final transaction re-verifies the selected
Artifact identity and digest, then atomically commits the file references, the
recomputed journal-based presentation, and Signal completion. If the provider
image alias changed or the file collector already swept the blob, preparation
returns a retryable execution error so bounded admission or recovery prepares
the bytes again—Ankole never commits a file path or reply that points to missing
image bytes. If the final commit rolls back, the file collector later reclaims
any unreferenced bytes. When image preparation fails, a lightweight fence check
rejects closed or superseded runs before surfacing an artifact error; when
preparation succeeds, the final transaction's own epoch fence is sufficient.

Live progress uses separate surfaces for native and external conversations.
Native Sessions stream progress over Pod SSE, whereas external Sessions can
render a transient reply preview through their Binding. That preview owns only
transient presentation, not the execution log, and final Delivery settles the
preview surface once the durable terminal intent takes ownership.

Inside the Driver, native activity is an in-memory observation consisting of one
phase plus the current turn's tool history; it spawns no extra process, journal,
or separate pending-call store. The Driver holds the Turn and its `PendingCalls`
while keeping tracing handles outside execution state, and `Sessions.Activity`
filters native display fields, ignores late updates for completed tools,
increments display revisions, and clears transient details on completion, retry,
takeover, or process exit. Every activity snapshot carries the admitted Signal,
workspace epoch, response identity, and an intra-epoch revision, validated
against the durable epoch and open input; if the Driver is missing or stopped,
callers fall back to durable generic status.

Only the Run's native source conversation receives live activity events—target
conversations of a scheduled report do not subscribe to its execution stream.
External Preview enforces its own synchronous contracts for ownership, adoption,
revisions, checkpoints, and terminal handoff, and its payloads bypass the native
display projection filter.

## Retry, Reset, and Recovery

When execution hits a retryable failure, Ankole backs off by committing a new
Signal deadline alongside an `EnsureDriver` job, moving any existing wakeup job
only to an earlier timestamp (`Ankole.Job.schedule_in_tx/4` with
`only_earlier: true`). Inside an existing transaction, admission calls
`Run.defer_retry_in_tx/3`; top-level `Run.defer_retry/3` publishes the updated
Session status after commit, so a rolled-back transaction publishes nothing.
Provider-capacity waits maintain their own separate attempt accounting. On node
startup, reconciliation resumes due Sessions and pending deliveries, and Ankole
rejects any late write that carries a stale epoch, targets a closed run, or
relies on withdrawn authorization.

An explicit `signal::<uuid>` retry must reference retained terminal work
belonging to the same Agent and a valid Session, with no newer user input in
between; it restores the declared model anchor rather than merging an unrelated
branch. Resetting a Session closes its active model history and starts a fresh
branch, while leaving shared public conversation history intact and readable
under the new branch's watermark. Neither retry nor reset affects another
Agent's Session in a shared room.

Workers are stateless, rebuildable compute, whereas Session workspace IDs are
durable integers that survive provider restarts. In Runtime Fabric protocol v10,
the execution key is named `SessionKey`, the run reference field is `session`,
accepted stimuli are `Signal`, and an accountable `ActorRef` identifies the
responsible Principal. File provenance records reference public Conversation and
Message UUIDs.

For related domain contracts, see [Signals](Signals.md),
[Conversations](Conversations.md), [AIGateway](AIGateway.md),
[Background Agent Jobs](BackgroundAgentJob.md), [Workflow](Workflow.md), and
[Schedule](Schedule.md).
