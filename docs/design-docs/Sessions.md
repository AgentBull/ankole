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

`Sessions.Key` owns construction and parsing of the stored key formats:
`conversation:<uuid>`, `cron:<id>`, `job:<id>`, and `wf_task:<id>`. Other valid
UTF-8, nonblank, NUL-free strings are named Session keys. `parse/1` classifies
the key; each work domain validates its own ID. `routable?/1` excludes private
Job and Workflow task keys from external route selection.

## Durable Owners

| Owner | Durable truth |
| --- | --- |
| `Signals` | Canonical stimulus, frozen authorization, Agent/Session target, queue sequence, admission and terminal state |
| `Sessions` | Numeric workspace, Driver epoch, runtime continuation and tool receipts |
| AIGateway | Exact caller input, model output, tool calls/results, original provider artifacts, checkpoint, and visible Response branch |
| `Conversations` | Shared Message UUID/sequence, participants, public statements and external facts |
| `Conversations.Delivery` | External send intent, attempt fence, provider confirmation, and recovery result |
| `AgentWorkers` | Worker provisioning and incarnation; its in-memory route can be rebuilt |

PostgreSQL is authoritative. A Driver, Worker process, socket, or PubSub event
is not recovery truth. Committing an input also commits an EnsureDriver job.
Immediate wakeups improve latency after commit; startup and durable recovery
find accepted work even if the producer dies at that point.

`Sessions.Events` uses the existing `Ankole.PubSub` server. Its input and state
topics include the tenant, Agent, and Session. It accepts scalar identities and
encodes the Agent and Session identifiers before it joins the topic fields, so
delimiters cannot change the target or channel. It does not depend on a Signal
schema or execution module. Input notifications
contain an already accepted Signal ID. They do not create work or start a Driver.
The public wakeup path still calls `ensure_driver/1` before it publishes a ready
input. Future inputs retain their stored EnsureDriver deadline.

Both Driver types set their tenant context and subscribe to input before their
initial inbox rebuild. A publication before subscription is found by that rebuild;
a later publication enters the existing inbox handler. Admission, preparation,
round recording, and finalization retain their existing postponement rules.
The handler reads the Signal under its Agent and Session and checks authorization.
Duplicate notifications cannot change the durable queue order. Lost notifications
are repaired by EnsureDriver and the existing Reconciler.

State publications occur in the outer transaction owner's process after success.
The guard only rejects a transaction in that process; it is not proof of commit.
Transaction code must not start a Task to publish pending facts. Completion
publishes one `turn_completed` notification with its Signal ID and outcome.
Transient activity uses a separate publication method and retains its Driver PID,
epoch, and revision checks. No subscriber commits a reply or sends a Delivery
because it received a completion notification.

`Sessions.driver_name/1` owns the shared registry identity for ordinary and Job
drivers. `driver_pid/1` and `active_model_conversation_id/1` are read-only
locators; neither starts a process nor creates history. External Preview keeps
its existing checkpoint identity when recovering a completed presentation.

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
records `prepared_in_tx`; only an existing post-commit path records `committed`.
Admission records `observed_committed`, queue age, readiness delay, and its
outcome. These observations neither wake work nor establish durability.

Each attempt keeps its epoch and attempt number. A turn that absorbs more inputs
records each input's relationship to the root Signal and the chosen reply Signal.
Each Delivery records its own key, source Signal, attempt, send or reconciliation
phase, and outcome, including unknown and stale results. Async recovery can start
a new trace and still use these identities; no persistent trace registry is needed.

New stage spans carry identifiers, states, and elapsed times, never stimulus
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

## Prepare a Model Request

The runtime builds its instructions, tool catalog, input, model binding, and
Brain execution context. It passes that context explicitly to AIGateway.
Public caller metadata is opaque to the model platform; a `signal_id` inside
an OIDC request cannot borrow another execution's authorization or memory scope.
Codex Jobs carry their runtime binding at the authenticated execution edge.

Before a request, the runtime snapshots bounded unread public statements from
the same conversation. The actual request records `conversation_read.max_seq`
and its `message_ids` atomically. Subsequent requests derive their read position
from the visible model branch. They exclude the running Session's own published
output by both author Agent and Session, and still see another Agent's output.
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

Jobs and Workflow calls preserve the parent's source authorization, explicit
reply route, and owner Session. Their dispatch/completion/failure/attention
notifications are Signals accepted through the same intake. Parent completion
and child completion are separate records; a finished child cannot overwrite a
parent model branch. A long-lived recipient can retain an ended model history.
An orphaned pinned history or a cyclic owner chain remains invalid.

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
retain their different treatment of already admitted work.

`RoundState` captures and restores the same six scalar loop controls. Pages,
steers, tool results, and Workflow attempts retain their distinct recovery rules.
Run records tool journals, completed wait inputs, RoundState, and receipt removal
in the same fenced transaction. Recovery asks AIGateway for the caller's visible
suffix; checkpoints and unmatched tool journals do not falsely end that suffix.

## Revisions and Completion

A new Human input, control command, or explicit input revision reaches the
running Driver at a durable boundary. Explicit edits, supplements, and removals
keep the original trigger and frozen authorization through their existing
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
execution error. The existing bounded admission/recovery path prepares it again;
no path or reply is committed with missing image bytes. A failed final commit
can leave unreferenced bytes for the existing file collector.
If preparation fails, a short fence check gives closed or replaced runs their
existing rejection before returning an artifact error. Successful preparation
uses only the final transaction's fence check.

A native Session publishes live progress through Pod SSE. External
Sessions can use their Binding's transient reply preview. The preview is a
presentation owner, not the execution log. Final delivery settles its recorded
surface after the durable terminal intent takes ownership.

Native activity is a bounded observation in the existing Driver: one phase and
up to four unfinished tool labels from its PendingCalls. `Sessions.Activity`
filters native display fields, ignores late updates to terminal tools, advances
display revisions, and clears details. The Driver keeps execution state and
PendingCalls. Each snapshot carries the
admitted Signal, workspace epoch, response identity, and a revision within that
epoch.
Snapshots check the durable epoch and open input; a missing or stopped Driver
falls back to durable generic status. Completion, retry, replacement, and death
clear details. Activity creates no process, journal, or separate pending state.

Only the Run's native source conversation receives activity. A scheduled report's
destinations do not subscribe to its execution. External Preview retains its
synchronous ownership, adoption, revision, checkpoint, and terminal handoff
contracts; the native display projection does not filter its payloads.

## Retry, Reset, and Recovery

Retryable execution failure backs off through a committed Signal deadline and
EnsureDriver job. Admission uses `Run.defer_retry_in_tx/4` inside its transaction;
the transaction owner publishes the resulting status after commit. A rollback
publishes nothing. Provider-capacity waits keep their own accounting. Startup
reconciliation resumes due Sessions and pending deliveries. A stale epoch, a
closed run, or withdrawn authorization rejects late writes.

An explicit `signal::<uuid>` retry must identify retained terminal work of the
same Agent and valid Session, with no newer intervening user input. It restores
the declared model anchor instead of merging an unrelated branch. Reset ends
that Session's active model history and starts a new one; public conversation
history remains retained and can be read under the new branch's watermark.
Neither operation removes another Agent's Session in a shared room.

A Worker is rebuildable compute. Session workspace IDs remain durable numeric
IDs across provider restarts and upgrades. Runtime Fabric protocol v10 names
the execution key `SessionKey`, the run reference field `session`, and accepted
inputs `Signal`; an accountable `ActorRef` still identifies the responsible
Principal. File provenance names public Conversation and Message UUIDs.

The CSS upgrade renames stored Session keys and all corresponding model,
workspace, scheduling, Job, Workflow, and queued worker references together.
It preserves model row IDs, provider bytes, and checkpoint artifacts. External
history migration retains one physical room and learns it once; every evidenced
Agent keeps its own execution state.

See [Signals](Signals.md), [Conversations](Conversations.md),
[AIGateway](AIGateway.md), [Background Agent Jobs](BackgroundAgentJob.md),
[Workflow](Workflow.md), and [Schedule](Schedule.md) for their respective owners.
