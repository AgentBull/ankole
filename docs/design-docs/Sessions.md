# Sessions

A Session is one Agent's execution context. Its identity is `(agent_uid,
session_id)`. `Ankole.Sessions` owns admission, the Driver, tools, continuations,
retry, and completion. AIGateway owns the exact model input/output, provider
artifacts, branches, and compaction. Conversations owns public statements;
Signals owns durable stimuli. These records have different writers and lifetimes.

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

One Driver serializes a Session through a global name. The stored workspace
and Driver epoch fence a writer that survives a takeover. Worker commands also
carry the current incarnation and run reference. Another Agent or Session never
writes into this Session's model history. Other Sessions can append public
statements to a shared conversation without changing the running model log.

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

A native Session publishes live progress through Workplace SSE. External
Sessions can use their Binding's transient reply preview. The preview is a
presentation owner, not the execution log. Final delivery settles its recorded
surface after the durable terminal intent takes ownership.

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
