# Sessions

A Session is one Agent's execution context. Its identity is `(agent_uid,
session_id)`. `Ankole.Sessions` owns admission, the Driver, tools, continuations,
retry, and completion. AIGateway owns the exact model input/output, provider
artifacts, branches, and compaction. Conversations owns public statements;
Signals owns durable stimuli. These records have different writers and lifetimes.

`Prompt.Delimiters` owns the quoted conversation, external event, environment,
and recalled-memory boundaries. It preserves each input policy: conversation
and event text replace reserved delimiters; memory text escapes its reserved
tags; environment fields also stay on one line. Input builders use the same
boundary names. This encoding does not replace Skill lesson admission rules
or authorization checks.

Each Agent participant in a conversation uses `conversation:<public_uuid>` as
its Session ID. Two Agents in one external room therefore share public history
and keep separate Sessions and model states. A cron rule uses its own stable
Session. A Background Agent Job or Workflow task has its own execution context
and can publish a result or notice into an explicitly routed conversation.

`Sessions.Key` owns construction and parsing of the transport key formats:
`conversation:<uuid>`, `cron:<id>`, `job:<id>`, and `wf_task:<id>`. Other valid
UTF-8, nonblank, NUL-free strings are named Session keys. `parse/1` classifies
the key; each work domain validates its own ID. `routable?/1` excludes private
Job and Workflow task keys from external route selection.

`SessionWorkspace` is an Ash resource. Its persisted `kind` selects exactly one
owner: a named Session, a Conversation, a Background Agent Job, a Workflow task,
or a Cron rule. Work references are typed foreign keys that include the tenant
and Agent. A Conversation reference includes the tenant because its participants
can use separate Agent Sessions. A missing owner cannot allocate a workspace.

PostgreSQL generates `session_id` from these facts. Callers cannot write a key
that disagrees with its owner. Owner deletion removes its workspace through the
foreign key. Allocation locks the referenced owner before the Session advisory
lock; the `advance_epoch` action advances the locked workspace once.

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
domain. Their write actions run in the transaction of a Session operation (see
[Persistence and Operations](#persistence-and-operations)). `record_once`
keeps the first round snapshot when recovery records the same model message
again. `commit_result` stores a tool result with its domain write. A
transaction-scoped advisory lock on the receipt identity serializes two
executions of one call; the second one reads the committed receipt and does not
repeat the domain write.
Receipt results, round pages, and result journals use the shared strict JSON
object type. Unsupported runtime values reject the write and roll back its
domain effects. PostgreSQL also rejects non-object journal values.
Round recording removes its receipts in the same transaction. An ambient
judgment keeps its original route and progress. Removing its accepted message
anchor can only degrade attribution and clear that reference.

PostgreSQL is authoritative. A Driver, Worker process, socket, or PubSub event
is not recovery truth. Committing an input also commits an EnsureDriver job.
Immediate wakeups improve latency after commit; startup and durable recovery
find accepted work even if the producer dies at that point.

`Sessions.Events` uses the `Ankole.PubSub` server. Its input and state
topics include the tenant, Agent, and Session. It accepts scalar identities and
encodes the Agent and Session identifiers before it joins the topic fields, so
delimiters cannot change the target or channel. It does not depend on a Signal
schema or execution module. Input notifications
contain an already accepted Signal ID. They do not create work or start a Driver.
The public wakeup path calls `ensure_driver/1` before it publishes a ready
input. Future inputs keep their stored EnsureDriver deadline.

Both Driver types set their tenant context and subscribe to input before their
initial inbox rebuild. A publication before subscription is found by that rebuild;
a later publication enters the inbox handler. Admission, preparation,
round recording, and finalization apply their postponement rules.
The handler reads the Signal under its Agent and Session and checks authorization.
Duplicate notifications cannot change the durable queue order. Lost notifications
are repaired by EnsureDriver and the Reconciler.

## Persistence and Operations

`Ankole.Sessions` is the Sessions Ash domain. Its resources are
`SessionWorkspace`, `RoundState`, `Receipt`, and `AmbientJudgment`.

A Session operation is a generic action of `SessionWorkspace` (the Session).
`Ankole.Sessions.Operations` declares these actions, and `Ankole.Sessions`
defines one function for each of them: for example `admit_input`,
`finalize_run`, `record_run_round`, `defer_run_retry`, `apply_command`,
`execute_receipt`, and `reset_session`. Each operation owns its transaction.
`Ankole.Sessions.Operations.Actions` runs the operations. Each one calls the
`*_in_tx` function of the owning module (`Admission`,
`Run`, `Commands`, `Notices`, `CodexJob`, `Receipts`, and others), so the lock
order and the compensation writes stay in one readable function. A domain
reason (an atom or a tuple) leaves the action as
`Ankole.Errors.Invalid.Rejected`; the module function (for example
`Run.finalize/3`) gives it back with `Ankole.Errors.reason/1`.

An operation is a top-level call. Inside `Repo.transact` or another generic
action it raises `Ankole.Errors.Framework.NestedOperation`. Work that already
runs in a transaction, such as a tool commit in a receipt or another domain's
operation, calls the `*_in_tx` function. Post-commit publication that needs
only the result is declared with `after_commit`: `defer_run_retry` publishes
the Session status, `record_run_round` publishes tool result events,
`reclaim_run` publishes failed responses, and `execute_receipt` runs the
receipt notifications. Work that needs more than the result, such as
`Run.after_finalization/1`, runs in the module function after the define
returns.

Sessions reads and changes Signals only through `Ankole.Signals`: queue reads
(`session_queue/3`, `session_status_signal/3`), row locks
(`lock_signal_in_tx/2`, `lock_session_signal_in_tx/3`, `lock_signals_in_tx/3`),
state changes (`transition_in_tx/4`, `reset_attempts_in_tx/3`), and the Signal
defines. Rows of other domains are read through their domain defines; a locked
read gives its lock identity to `Ankole.LockOrder`. Allocation locks the
workspace owner with `FOR KEY SHARE` through the owner domain.

Ambient triage gives a typed result: `{:ok, :intervene, signal}` admits the
input, `{:ok, :settled}` rebuilds the queue, `{:ok, :deferred, signal}` waits
until the retry time, and `{:error, reason}` follows the admission error path.

The operator console lists model histories with the `console_list` read action
of `AIGateway.Schemas.Conversation` (keyset pagination) through the Console
JSON:API (`/api/v2/ai-gateway/conversations`). Sessions owns that action, its
preparation `Sessions.ConsoleQueries.Prepare`, and the relationships that it
filters on: the public conversation, the direct-message peer, and the
messages. The display facts are calculations of the conversation: `kind`,
`display_name`, `channel_kind`, and `signal_adapter`
(`Sessions.ConsoleQueries.Channel`, one batch for each page) and the
`message_count` aggregate. The messages of one conversation are the
`console_list` read action of `AIGateway.Schemas.Message`, oldest first.

The Session picker reads `GET /api/v2/agents/:agent_uid/sessions`. It shows
only the selected Agent's persisted Sessions in the active tenant. The
Conversation standing-order routes are
`GET` and `PUT /api/v2/conversations/:conversation_id/standing-orders`.
`Sessions.AmbientCuration` validates and persists each edit with the current
Principal as its actor. The next Signal snapshot reads the stored order;
clearing the order excludes it from later snapshots. The transport action
adds no outer transaction around the owning domain operation.

## Turn Progression

`Sessions.Turn.step/2` owns the next execution step. It takes the current Turn
and an event, then returns the next Turn and ordered commands. Events include
operation results, inbox notices, Worker messages, model completion, and timer
expiry. The Turn includes its Run, pending calls, observation state, and Worker
acquisition state. It has no process, database table, or recovery journal.

The Driver executes these commands through the Admission, Run, Tools,
Commands, and Worker contracts. It owns registry membership, subscriptions,
Task monitors, stream handles, timers, tracing, and activity publication. It
returns each operation result to the Turn. Commands are private to this pair;
they do not form a shared work engine or a persistent command queue.

Turn owns tool scheduling, result acceptance, receipt restoration, round
completion, continuation, and failure policy. Its repeated-tool-failure rule
also folds committed history during Run recovery. Run and the Ash resources
hold transaction authority: a proposed record, retry, or finalization cannot
advance past that boundary until its operation succeeds. Epoch and closed-run
errors stop the Driver. Turn state cannot authorize a durable write.

Preparation replays durable inbox controls before it resumes model or tool I/O.
A superseded epoch cannot resume the previous Run. Round commit cancels that
round's transport and observation tasks before the next boundary. Worker
acquisition uses the bounded policy, including safe probes for calls
whose result is unknown. Activity is an observation of these pending calls
in the same Driver process.

Turn tests exercise event sequences without a Driver or database. Receipt and
Run tests use PostgreSQL for atomicity and recovery. Driver integration
tests verify process ordering, cancellation, presentation, single-writer,
epoch-fence, and cross-node checks.

State publications occur in the outer transaction owner's process after success.
The guard only rejects a transaction in that process; it is not proof of commit.
Transaction code must not start a Task to publish pending facts. Completion
publishes one `turn_completed` notification with its Signal ID and outcome.
Transient activity uses a separate publication method with Driver PID,
epoch, and revision checks. No subscriber commits a reply or sends a Delivery
because it received a completion notification.

`Sessions.driver_name/1` owns the shared registry identity for ordinary and Job
drivers. `driver_pid/1` and `active_model_conversation_id/1` are read-only
locators; neither starts a process nor creates history. External Preview uses
its checkpoint identity when recovering a completed presentation.

Both Driver types register the same global name before initialization.
`ensure_driver/1` reuses an existing PID and accepts an `already_started` result
when another caller wins registration. The DynamicSupervisor owns process
supervision, not Session uniqueness. The stored workspace
and Driver epoch fence a writer that survives a takeover. Worker commands also
carry the current incarnation and run reference. Another Agent or Session never
writes into this Session's model history. Other Sessions can append public
statements to a shared conversation without changing the running model log.

## Diagnostic Correlation

Optional tracing uses the durable Signal ID across intake, admission, model
requests, finalization, and Delivery. Intake inside a caller-owned transaction
records `prepared_in_tx`; only a post-commit path records `committed`.
Admission records `observed_committed`, queue age, readiness delay, and its
outcome. These observations neither wake work nor establish durability.

Each attempt keeps its epoch and attempt number. A turn that absorbs more inputs
records each input's relationship to the root Signal and the chosen reply Signal.
Each Delivery records its own key, source Signal, attempt, send or reconciliation
phase, and outcome, including unknown and stale results. Async recovery can start
a new trace and use these identities; no persistent trace registry is needed.

Stage spans carry identifiers, states, and elapsed times, never stimulus
bodies, prompts, tool arguments, credentials, or attachment bytes. They use facts
already loaded by the owning operation and do not add business queries or RPCs.
Missing or failed tracing does not change admission, retries, sends, or commits.

## Admission and Responsibility

Internal control, revision, ambient, and scheduled paths require the intake's
private kernel producer fact. An external event with the same type remains
external data. Scheduled work also requires its actual ScheduledEvent-to-Signal
link. JSON fields cannot select these paths, hide unread Messages, name the
requester, or create conversation policy.

Acceptance freezes authorization facts; admission checks them again before
starting work. A Human request retains Human UID and access version, so a later
revoke or restore cannot revive a queued request from an earlier version.
Service stimuli execute under their explicit service authority. An ambient
proposal defaults to the Agent's responsibility; a verified Human request can
supply the responsible Human through the judged public Message.

Generic Signal data and CloudEvents extensions never establish a Human identity.
Runtime environment and Brain disclosure use frozen facts and canonical
conversation records. An Agent being able to read a group message does not grant
it the author's action authority. Delivery destination, execution identity,
and requester authorization remain separate.

Before foreground admission, the Driver runs `AmbientTriage` in an asynchronous
task for a kernel-produced ambient input. `Run.kind/1` selects this path. First,
`Ambient.resolve/2` uses the Session admission owner to check the tenant and
Agent before it folds pending observations from the same room and rejects
expired or changed scenes. The triage builds an `Observation` from the public
room, Agent documents, and current work candidates. It does not create an
AIGateway conversation or a Session workspace. Second, the light model receives
one stateless request outside a database transaction. Third,
`AmbientCuration.record_judgment/3` repeats admission under the tenant and Agent
locks, then locks the target Job and participating Sessions. After those locks,
it checks the scene against the current time and stores the canonical decision.
A tenant suspension, Agent disablement, or expiry during the model request
prevents the proposed route from committing. That transaction also completes `NOOP` and `HANDOFF` inputs silently.
A HANDOFF locks its Job before the participating Session locks and commits one
idempotent steer with the judgment. A changed scene rejects that entire write
and returns to the observation resolver.

Only a persisted `FOREGROUND_REPLY` or `NEW_WORK` judgment permits ordinary
admission to create model history and increment the workspace epoch. A retry
uses that judgment instead of asking the model to select another route. Model
request failures defer the input and increment `attempt_count`; they leave
`last_attempt_at` empty so a newer room batch can supersede it. The third
failure records a silent `NOOP`. A missing light profile also records a silent
`NOOP` without posting a configuration notice to the room. Triage checks the
Agent token quota before it builds model context. An exhausted quota records a
silent `NOOP` at once. The same rule applies if another request uses the
remaining quota before AIGateway checks it. Neither rejection creates a Session
workspace, creates model history, or consumes a model retry.

## Prepare a Model Request

The runtime builds its instructions, tool catalog, input, model binding, and
Brain execution context. It passes that context explicitly to AIGateway.
A Session function tool declaration sends `strict: false` unless it declares
`strict` itself. The Responses API treats a missing `strict` as strict, and
strict mode makes the model fill every declared property; Session tools declare
optional parameters that the model must be able to omit. A custom (freeform)
tool has no `strict` field and keeps its declaration unchanged.
Public caller metadata is opaque to the model platform; a `signal_id` inside
an OIDC request cannot borrow another execution's authorization or memory scope.
Codex Jobs carry their runtime binding at the authenticated execution edge.

Before a request, the runtime snapshots bounded unread public statements from
the same conversation. The actual request records `conversation_read.max_seq`
and its `message_ids` atomically. Subsequent requests derive their read position
from the visible model branch. They exclude the running Session's own published
output by both author Agent and Session, and see another Agent's output.
A retry, fork, truncation, or compaction follows that branch's committed facts.
Only completed ordinary Responses establish consumption. A compaction checkpoint
can retain caller metadata for history without proving that its pending model
request consumed those Messages. Failed requests after compaction therefore
reread the same unconsumed background.

Signals retain their original envelope and current stimulus Message identities.
They do not freeze the conversation's background history. Provider reasoning,
signatures, and other continuation artifacts remain exact AIGateway records;
they are not copied into the public Message table or regenerated from text.

Completed model history, summaries, tool calls, and results replay exactly as
stored. Background edits do not rewrite it or restart the current turn. Edits
retain sequence numbers, so later turns do not reread already consumed Messages.
The request's `conversation_read` contains only `id`, `max_seq`, and `message_ids`.

## Execute Tools and Asynchronous Work

A tool result is durable before the model continues. A recorded result is reused
on recovery. A sent tool call with an unknown result becomes interrupted rather
than being silently reexecuted. Sequential calls keep their execution order;
parallel calls retain their own receipts. Worker reconnection and workspace
adoption restore committed progress under the current epoch.

A recovered Worker result can complete a batch before its new workspace open
finishes. Recording that batch cancels the pending acquisition tasks and timers
and retains the fact that the run requested a Worker. The next batch can acquire
the workspace again. If the model finishes instead, the Driver closes the
workspace for that exact Signal and the Worker releases its slot. A pure text
run that never requested a Worker sends no Worker messages.

`stale_driver` and `run_closed` are control results. Every asynchronous task
passes them to the Driver's stop path. A fenced tool cannot turn them into a
model-visible error or start the next call in its round.

Unexpected Ash tool errors return a generic message. Their logs use
`Ankole.Logging.failure_fields/3` to keep private action data out of diagnostics.
Job Driver operation failures use the same diagnostics and keep their retry
policy. Logs include the operation name without the request payload.
Receipt notification, workspace close, and Session reconciliation failures use
the same diagnostics. A failed notification cannot undo a committed receipt
or repeat its domain write.

Jobs and Workflow calls preserve the parent's source authorization, explicit
reply route, and owner Session. Their dispatch/completion/failure/attention
notifications are Signals accepted through the same intake. Parent completion
and child completion are separate records; a finished child cannot overwrite a
parent model branch. A long-lived recipient can keep an ended model history.
An orphaned pinned history or a cyclic owner chain is invalid.

Cron fires create Signals in the rule's stable Session. Native and external
recipient conversations are explicit targets. Completion commits every native
statement and every external Delivery intent in the same transaction. Failure,
quota, suspension, and unavailable-model notices follow the same target set.
The destination conversation's own Session sees those public reports on its
next request, while the cron work keeps its own model state.

Workflow-specific terminal-input recovery, retry exhaustion, task progress locks,
and attempt restoration belong to `WorkflowTask`, not the shared RunType
extension contract. Workflow owns model-unavailable diagnostics and locked task
transitions. A caller-owned transaction returns the Workflow transition through
the Session result; `Run.after_finalization/1` performs terminal cleanup only
after the outer transaction commits. Ordinary cancellation and Human revocation
apply their respective rules to already admitted work.

Input injection locks Workflow parents and calls before it locks Session,
Workspace, and Signal rows. This also applies to a fresh steer that must be
rejected after tenant suspension. That rejection completes only the fresh
input; an admitted task and its current input keep their attempt.

`RoundState` captures and restores the same six scalar loop controls. Pages,
steers, tool results, and Workflow attempts follow their recovery rules.
Run records tool journals, completed wait inputs, RoundState, and receipt removal
in the same fenced transaction. Recovery asks AIGateway for the caller's visible
suffix; checkpoints and unmatched tool journals do not falsely end that suffix.

## Revisions and Completion

A new Human input, control command, or explicit input revision reaches the
running Driver at a durable boundary. Explicit edits, supplements, and removals
keep the original trigger and frozen authorization through the
revision path.

Terminal validation distinguishes two withdrawals. If an explicit input source
was withdrawn, it returns `:signal_canceled` and cancels the turn. If only a
background Message read by this turn was deleted, it returns
`:signal_context_canceled`, stops the turn, and posts `context_withdrawn` rather
than the original answer. Background edits do not invalidate a running request.
Completed model history stays unchanged in both cases.

Work completion decides the final presentation once. Silent completion emits no
statement. A visible native result becomes a Message in the completion
transaction. An external result becomes a Delivery intent, whose provider
success can complete later or fail independently. Raw streamed model text,
reasoning, and tool results are not automatically public final statements.

Generated image bytes are prepared before the final Session transaction. The
transaction rechecks the selected Artifact identity and digest, then commits
file references, the recomputed journal-based presentation, and input completion
together. A changed provider image alias or a collected blob returns a retryable
execution error. The bounded admission and recovery path prepares it again;
no path or reply is committed with missing image bytes. A failed final commit
can leave unreferenced bytes for the file collector.
If preparation fails, a short fence check rejects closed or replaced runs
before returning an artifact error. Successful preparation
uses only the final transaction's fence check.

A native Session publishes live progress through Pod SSE. External
Sessions can use their Binding's transient reply preview. The preview is a
presentation owner, not the execution log. Final delivery settles its recorded
surface after the durable terminal intent takes ownership.

Native activity is a bounded observation in the Driver: one phase and
up to four unfinished tool labels from its PendingCalls. `Sessions.Activity`
filters native display fields, ignores late updates to terminal tools, advances
display revisions, and clears details. The Driver holds the Turn and its
PendingCalls; tracing handles stay outside that execution state. Each snapshot
carries the admitted Signal, workspace epoch, response identity, and a revision
within that epoch.
Snapshots check the durable epoch and open input; a missing or stopped Driver
falls back to durable generic status. Completion, retry, replacement, and death
clear details. Activity creates no process, journal, or separate pending state.

Only the Run's native source conversation receives activity. A scheduled report's
destinations do not subscribe to its execution. External Preview uses its
synchronous ownership, adoption, revision, checkpoint, and terminal handoff
contracts; the native display projection does not filter its payloads.

## Retry, Reset, and Recovery

Retryable execution failure backs off through a committed Signal deadline and
EnsureDriver job. EnsureDriver moves its pending wakeup only to an earlier time
(`Ankole.Job.schedule_in_tx/5` with `only_earlier: true`). Admission uses
`Run.defer_retry_in_tx/4` inside its transaction; the `defer_run_retry`
operation publishes the resulting status after commit. A rollback
publishes nothing. Provider-capacity waits keep their own accounting. Startup
reconciliation resumes due Sessions and pending deliveries. A stale epoch, a
closed run, or withdrawn authorization rejects late writes.

An explicit `signal::<uuid>` retry must identify retained terminal work of the
same Agent and valid Session, with no newer intervening user input. It restores
the declared model anchor instead of merging an unrelated branch. Reset ends
that Session's active model history and starts a new one; public conversation
history remains available and can be read under the new branch's watermark.
Neither operation removes another Agent's Session in a shared room.

A Worker is rebuildable compute. Session workspace IDs are durable numeric
IDs across provider restarts. Runtime Fabric protocol v10 names
the execution key `SessionKey`, the run reference field `session`, and accepted
inputs `Signal`; an accountable `ActorRef` identifies the responsible
Principal. File provenance names public Conversation and Message UUIDs.

See [Signals](Signals.md), [Conversations](Conversations.md),
[AIGateway](AIGateway.md), [Background Agent Jobs](BackgroundAgentJob.md),
[Workflow](Workflow.md), and [Schedule](Schedule.md) for their respective owners.
