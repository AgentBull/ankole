# Conversations

`Ankole.Conversations` owns the shared conversation, participation, and public
message records. A native conversation is hosted by Ankole and currently has
one Human and one Agent. An external conversation is hosted by a platform and
can have multiple Agent participants observing and speaking in the same room.

A conversation is the shared space that its participants can read. Each Agent
executes its own work through `Ankole.Sessions`. AIGateway separately owns model
Responses and model conversation state. Model output becomes conversation
history only when the control plane commits a message.

## Owners and Stored Facts

| Owner | Contract |
| --- | --- |
| `Ankole.Conversations` | Conversation creation, participation, access checks, messages, and committed conversation events |
| `Ankole.Signals` | Acceptance of input with its source, source event ID, type, subject, data, explicit target, and sender |
| `Ankole.Sessions` | Ordered execution, admission, steering, retry, recovery, and completion |
| AIGateway | Model Responses, live model events, and model conversation history |
| Principal and AuthZ | Human and Agent identity, tenant ownership, and work authorization |

Conversations uses these tenant-scoped tables:

| Table | Stored facts |
| --- | --- |
| `conversations` | Public UUID, native/external kind, optional current Page, title, activity, sequence high water, external platform identity, and standing orders |
| `conversation_participants` | Conversation, Principal, and role; native creation admits one Human owner and one Agent, external rooms can have multiple Agents |
| `conversation_messages` | Public UUID, conversation, sequence, author, kind, exact text, attachments, public reply reference, and execution provenance |
| `external_message_refs` | Platform message/thread/reply IDs, raw author, metadata, reactions, content hash, and observation times for an external Message |

Each table has a tenant foreign key. Primary and unique keys include
`tenant_id`. The tenant deletion owner includes all four tables.

`Ankole.Conversations` is the Ash domain of these records and of the inbound
batch, input tombstone, Delivery intent, and preview state resources. It gives
one code interface function for each resource read and write action. Code in
other domains, web controllers, and plugins reads and writes these records
through these functions, not through Ecto or `Ash.Query`.

Each operation that opens a transaction (`create`, `post`, `observe_entry`,
`claim_intent_dispatch`, `PreviewStates.put_checkpoint`, and others) runs in
`Repo.transact_top_level/2`. It owns the transaction, takes the locks in the
work lock order, and runs its publication after commit. Inside another
transaction it raises `Ankole.Errors.Framework.NestedOperation`. A caller that
already owns a transaction uses the `_in_tx` function of the same operation,
for example `create_in_tx/2`, `post_in_tx/3`, `detail_in_tx/3`, or
`Attachments.link_payload_in_tx/3`.

The domain reads the rows of other domains through their code interface
functions. It locks Principal and Signal rows through the composition functions
of their owners (`Principals.lock_principals_in_tx/1`,
`Signals.lock_signals_in_tx/2`), which give each locked read to the lock-order
check. Other domains lock a Conversation row with
`Conversations.lock_conversation_in_tx/2`. A query filters by
the rows of a related resource with a resource-based `exists` expression; the
resources declare no relationships, so their Ecto structs do not change. A
Message is `withdrawn` when one of its native inputs is removed; history,
context, and detail reads exclude these Messages.

Membership retries retain the first role, and native creation retries cannot
replace stored facts. External observation actions can change content and
observation metadata, but cannot change the platform identity or the first
observation time.

A message sequence is unique within its conversation. Writers lock the
conversation before the resource action increments its retained high water in
the database. A stale resource cannot overwrite the current counter.
Deleting a tail message never permits sequence reuse. A reply reference can
only name a message in the same tenant and conversation.

Human messages have no execution provenance. Agent replies and notices retain
the execution session ID and source signal ID. Native message provenance keeps
its Signal while the native conversation exists. External facts survive removal
of an Agent or its Binding: Principal and Signal foreign keys can become null,
while the observed platform facts and recorded Session identity remain.

## External Message Batching

`Conversations.InboundBatches` owns one shared batching policy for IM adapters.
A batch is scoped by tenant, Agent, binding, conversation, and thread. Requester
continuity decides whether an incoming observation can extend that batch. The
batch deadline and finalize job commit in the same transaction; an early wakeup
retries at the stored deadline. Adapters own platform wire formats and identity
observation, Conversations owns batching and source tombstones, and Signals accepts the
resulting stimulus. Adding an adapter does not copy these windows or recovery
rules into that adapter.

`InboundBatch` actions own the `open`, `finalized`, and `canceled` states.
Only an open batch can change. A revision or terminal action increments the
stored revision atomically; PostgreSQL rejects negative revisions. The deadline
keeps its scheduling meaning and does not define the batch state. A source
removal records or renews one shared tombstone through its resource action.
Expiry removes only rows whose stored deadline has passed.

`Conversations.MessageInput` computes message-backed input revisions without
database writes. It updates source entries, their summary, ambient batch facts,
and the attachment supplement deadline. Both `Conversations.InputRevisions`
and `Sessions.Revisions` use this calculation. The former owns queued changes
and revision intake; the latter owns in-flight cancellation, retained effects,
and recovery. Each caller runs inside its own transaction and locks. Inbound
batch windows and supplement waiting remain separate policies. Other Signal
sources do not need this message representation or these revision rules.

## Accept a Human Message

The current Human must participate in the conversation. Creation and each
new Human message require `chat` permission on `agent:<agent_uid>`. The Agent
must be active and belong to the Human's tenant. Native conversations do not
require a configured provider binding or a separate enable flag.

Creation commits these facts in one transaction:

1. The conversation and both participants.
2. The first Human message.
3. A `conversation.message.addressed` signal for the Agent.
4. The AIGateway conversation for this execution session.
5. The durable EnsureDriver wakeup.

A later message commits its message, signal, and durable wakeup in one
transaction. The signal has these values:

| Field | Value |
| --- | --- |
| Source | `conversation:<conversation_id>` |
| Source event ID | Human message ID |
| Type | `conversation.message.addressed` |
| Subject | Conversation ID |
| Target | Agent UID and execution session `conversation:<conversation_id>` |
| Sender | The authenticated Human UID |
| Data | Conversation ID, message IDs, author UID, model profile, exact message text, and trusted request IP |

`Ankole.Signals.accept_in_tx/1` stores the input in `signals`, allocates its
Agent/Session queue position, and commits an EnsureDriver job in the same
transaction. Native conversations create no Signal Binding, external reference,
or Delivery intent. WorkAccess freezes the Human UID and access version;
admission checks those facts again when execution starts.
The Signal stores the trusted input IP in `data.request_context`. Tool and
Pod RPC authorization use that IP when execution resumes. The runtime checks
the Signal producer, native type, conversation source, and session key before
it reads the context. Derived work follows its stored owner to this input and
keeps the same Agent and WorkAccess identity. See [AuthZ](AuthZ.md) for condition
inputs and Human-derived tool and Pod checks.

The browser generates the conversation and message UUIDs. A retry with the
same IDs and facts reuses the stored message and signal. Reusing an ID for
different facts returns `conversation_conflict`. A deleted native Conversation
UUID cannot be reused: the execution and history records retire that identity.
Text must be valid UTF-8,
contain no NUL character, and be nonempty after whitespace is removed from both
ends. Storage and retry comparison retain the original text. The title uses
the first nonempty line, up to 80 characters.

The control plane publishes changes after the transaction commits. A rollback
publishes no event and leaves no accepted message or signal. The native
create, post, and queue operations return their `publications` and `session_key`.
After commit, the `after_commit` callback of `Repo.transact_top_level/2` calls
`Conversations.Events.publish_committed/1` and publishes one status change
through `Sessions.Events`. Another transaction owner uses `create_in_tx/2` or
the Human `post_in_tx/3`, retains the returned facts, and publishes them after
its own commit. A repeated request with no new publications publishes neither
event. The durable EnsureDriver job owns the recovery wakeup.

The publication guard rejects a transaction in the calling process. It does not
prove that the supplied facts committed, and a new Task does not inherit the
parent's transaction. Transaction code must return publication facts to its
outer owner; it must not start a Task to publish them.

When a tenant is suspended, admission can reject a queued follow-up while the
earlier admitted turn continues. The notice and completed follow-up commit
together; the page receives message and status events after that commit.

## Execute and Commit the Reply

The native signal enters the main Session loop. `Prompt.Input` reads
the Human message text. A follow-up from the same Human can join the active
Run through the steering path.

Presentation appends the visible Agent reply in the completion transaction.
It does not create a provider Delivery operation. A silent turn adds no message.
Notices appends an immutable notice when an input enters dead-letter state.
Both replies and notices use the Agent as their author.

The source signal ID prevents duplicate Agent messages when completion is
retried. This does not make upstream model requests execute exactly once. An
interrupted model request can run again during recovery.

The daily model conversation reset excludes native conversation Sessions.
Refresh and reconnect read committed messages from Conversations; AIGateway
history remains model state rather than the visible transcript.

## Pod Browser API

The browser API is mounted at `/api/v2/pod`. It uses the same
access gate as the Pod shell: setup must be complete, and the browser
must prove a Human authentication for the target Pod. Unsafe requests require
CSRF proof. Ash actions declare the request and result types. Generic action
requests put arguments in `data` and use `application/vnd.api+json`.
`AnkoleWeb.JSONAPI.PodRouter.spec/0` uses AshJsonApi to generate `pod-v2.json`.
`mix ankole.openapi.check` verifies the committed documents; `--write` exports
them. The webapps `openapi:generate` script derives the browser clients.
File transfer, Applet HTTP routes, and SSE use their native media and transport.

The authenticated Principal determines the tenant. A Console data tenant
selection cannot change the Pod tenant. Read, write, and SSE operations
check that the current Human participates in the conversation.
All Pod requests require Guest admission under `pod.allow_external_guests`.
The Agent directory lists only active Agents for which the Human has `chat`
permission. Model profile lookup uses the same Agent permission check.

| Method and path | Contract |
| --- | --- |
| `GET /agents` | `{agents: [{uid, displayName}]}` for active Agents with current `chat` permission |
| `GET /conversations` | `{conversations: [...]}` with the latest 100 participating conversations, ordered by recent activity; optional `pageID` filters to an accessible Page |
| `POST /conversations` | Accepts `conversationID`, `agentUID`, `messageID`, `text`, and optional `pageID`; returns the committed conversation detail |
| `GET /conversations/:id` | Returns conversation detail, the latest 500 messages in sequence order, and execution status |
| `POST /conversations/:id/messages` | Accepts `messageID` and `text`; returns the committed conversation detail |
| `GET /conversations/:id/events` | SSE for committed changes, current activity, and subsequent live model text |

Both POST operations return HTTP 200 on success. Conversation summaries contain
`id`, `title`, nullable `pageID`, `agent` (`uid`, `displayName`, `active`), and `lastActivityAt`.
Detail responses contain `conversation`, `messages`, and `status`.

A native Conversation can belong to one Page. Conversations owns this stable
association in `page_id`; an idempotent create cannot change it. The Human must
still have `page_view` permission when creating, listing by Page, or posting a
new message. A missing, deleted, or inaccessible Page returns `page_unavailable`.
The Agent retains its own Pod permissions. Main and Background Agent Job
contexts identify the Page and require a fresh read before a change. Page chat
and the separate Chat view use the same Conversation and committed messages.
Purging a Page clears the association and keeps the Conversation history.

In Pod conversations, documents and research reports default to editable Pages.
An explicit file-format request keeps its requested format. Other channels use
their file delivery rules.

The current Pod document owns unsent Chat drafts and pending request IDs.
Closing a panel, switching conversations, or navigating between Pages keeps
that local work. A successful acknowledgement binds a new draft to its saved
Conversation. Retrying an unconfirmed request with the same text and Agent
keeps its original IDs. Reloading or leaving the document prompts when local
work remains. If Page access is lost, the Page error view exposes only locally
authored draft text for copying; it does not expose saved content or history.

Each message contains `id`, `seq`, `authorType`, `authorUID`, `kind`, `text`,
`createdAt`, `signalID`, and `replyToMessageID`. `authorType` is `human` or
`agent`; `kind` is `message` or `notice`. Human `signalID` values are null.
Timestamps use ISO 8601.

Status contains `state`, `retryAt`, and `activity`. State is `idle`, `queued`, `running`, or
`retrying`. `retryAt` is a timestamp for a scheduled retry and null otherwise.
Sessions derives this status from its durable inbox.
Ready admitted input takes priority over queued input, which takes priority
over future retries. An earlier retry must not hide later work that can run.
Paused, unadmitted queue inputs are not eligible work. A conversation with only
those inputs is idle; releasing one input can make it queued or running while
the remaining queue stays paused.

`Conversations.get/3` reads the message range, pending inputs, queue version,
retry capability, and durable Session status in one transaction under the
Session advisory lock. Input acceptance, admission, and terminal
reply commits use the same lock. A detail read cannot combine messages from
before a native reply commit with an idle status from after that commit.
Controllers serialize the returned status without a second query. Activity
remains a separate temporary observation and can be newer than this detail.

Domain errors use the `{error: {code, message, details}}` envelope:

| HTTP status | Codes |
| --- | --- |
| 422 | `invalid_request`, `invalid_id`, `invalid_text` |
| 403 | `page_unavailable` |
| 404 | `conversation_not_found` |
| 409 | `agent_unavailable`, `conversation_conflict` |

The session gate returns HTTP 401 with `unauthorized` when access is absent or
inactive. CSRF protection rejects an unsafe request without valid proof.

## SSE and Visible History

The SSE endpoint checks access before it subscribes. It subscribes to
`Conversations.Events` for public message and availability changes,
`Sessions.Events` for that Agent's execution state and activity, and AIGateway
for model events. All topics are tenant-scoped. The connection establishes these
subscriptions before it reads the current Driver snapshot. It sends a `: ping`
comment every 15 seconds and removes all subscriptions when it closes. Before
each frame or ping, it checks current Pod admission and Conversation access.
A failed check closes the stream.

| Event | JSON data | Meaning |
| --- | --- | --- |
| `message` | `{}` | A Human message, Agent reply, or notice was committed |
| `status` | `{}` | Execution or Agent availability changed |
| `started` | `{responseID, signalIDs}` | A model Response started; replace prior live text |
| `delta` | `{responseID, signalIDs, text}` | Subsequent text for that Response |
| `activity` | Current activity snapshot | Bounded phase and unfinished tool labels |

An activity snapshot contains `conversationID`, `agentUID`, `sessionID`,
`signalID`, `responseID`, `epoch`, `revision`, `state`, `phase`, and `tools`.
Its state is `active`, `unavailable`, or `settled`; it is a display observation,
not a second execution lifecycle. Labels have bounded text and bindings, and
`tools` has at most four entries. Reasoning, tool arguments, outputs, and result
bodies do not enter this projection.

The stream subscribes before reading a bounded current Driver snapshot. It
checks the stored workspace epoch and open Signal before accepting active
details, and monitors the Driver. The initial frame includes the current
snapshot, so a late connection can show a capacity wait without replaying an
event log. Epoch and revision ordering reject older observations; a settled
epoch cannot reopen. Driver loss, retry, and disconnection clear transient
details and fall back to the durable status. An activity frame never triggers
a full history read.

`Conversations.Events` publishes a message event after a public statement commits.
Its status event covers Conversation deletion and Agent availability.
`Sessions.Events` owns acceptance, queue, admission, retry, and terminal state
notifications. A committed turn publishes one `turn_completed` notification in
place of a status notification. The SSE connection maps either to the
`status` frame. An external turn completion proves that its Delivery intents
committed; only provider confirmation creates its public messages. Activity
events are transient observations and do not establish committed facts.

`signalIDs` comes from the Response's primary input and the steered inputs in
`session_round_states`. It identifies the durable inputs that the model
request includes. It is not inferred from a cached message sequence. A visible
Agent message's `signalID` lets the page replace the corresponding live text
with committed history. `responseID` keeps text from different model Responses
separate.

The stream does not replay events or send text generated before subscription.
After reconnect, only subsequent deltas are available. If the connection
missed `started`, a subsequent `delta` still carries its Response and input
identities. The page can display that new text; the next history read supplies
the complete reply after commit. Live text is never a stored message.

The page reads detail again on every connection, `message`, and `status`
event. Each event must cause a read taken after that event; an older request
already in flight cannot satisfy it. A late POST response cannot replace more
recent history. The page keeps unconfirmed message IDs for retry and removes
them when those IDs appear in committed history. It clears live text when the
matching reply commits, or when a fresh execution status settles that same
Response without a visible reply.

Native Chat detail also returns pending inputs, durable queue pause state, a
queue comparison token, and the latest message that the retry owner
can retry. Queue edits and reordering check that token under the Session lock.
A lost response to an already committed retry can replay the same command ID;
it does not create another input or recapture its model selection.

Stop cancels the current reply and pauses unadmitted inputs, including pending
steer messages. Refresh retains the pause. Continue resumes the queue; Send now
releases only its selected input. A stale edit retains the local draft. An
explicit refresh can adopt the new comparison token only while the saved text
still matches the original; a changed saved message requires an explicit choice.

Last-turn editing and regeneration reuse Commands and ModelHistory. The latest
eligible failed reply exposes Retry through the same capability predicate;
Stop and preflight notices do not become retryable merely because they are
notices. A new Human retry captures the current Chat model preference. Completed
Page, Database, and applet changes remain. Native edits, regeneration, and logical
queue removal call the message-change lifecycle in their transaction,
invalidating affected Brain facts and rewinding its learning cursor. Removed
messages retain stable idempotency identities while a shared visibility query
excludes them from history, Main context, and Brain learning.

History reads return at most 500 visible statements and an earlier-message
cursor. The covered sequence interval lets the browser merge older windows into
its existing cache without discarding loaded history or restoring removed text.

## Agent Lifecycle and Scope

Disabling an Agent preserves its native conversations and history. Reads stay
available; new conversations and messages return `agent_unavailable`. Pod
disables the composer and explains that the Agent is unavailable.

Permanent Agent deletion removes its native conversations and participation.
Shared-room Messages remain readable. Their author and source Signal references
become null when the Principal and its Signals are removed. The source Signal
foreign key retains its tenant-qualified identity and checks at transaction
commit, after both native cascades have completed. This avoids dependence on
PostgreSQL trigger creation order. Existing native pages refresh on the status
event, remove cached detail on `conversation_not_found`, and close SSE.

Human chat uploads store bytes through `Conversations.Attachments` and `Files`.
A signed upload receipt binds the tenant, Human, client file ID, digest, name,
size, and content type. A Message accepts verified receipts and retains its
attachment references in the same transaction. Unsent receipts expire after one
day; an exact retry of an accepted Message remains valid. Unreferenced upload
bytes use the file collection grace. An upload does not create a Page.
The Human can use the explicit Save action to create a file Page later.

The input owner links accepted attachments into the Agent's drive
before they enter the model input. An input that waits in the queue does not
expose its files in that drive. Image inputs use the native image
normalization. Attachment downloads read the Message's frozen bytes through
current Conversation membership, so an Agent's later file edits do not change
the download. The local Chat draft owns selected Files and upload retries when
the Human closes its panel. A refresh warning protects unsent work; a browser
refresh restores accepted Message attachments, not unsent File objects.

Native conversations accept Agent attachments from `reply_attachment` and
hosted `image_generation`. The native message commit uses the same attachment
validation and Agent drive references as external delivery. A message retains
its content digest for file collection, so a saved Pod file can refer to the
same content without copying bytes. An attachment-only reply is a visible
message. Page links in native text, such as `ankole:page/<page ID>`, are stored
as `{kind: "page", id}` message links. Reading the referenced page still
requires the reader's page permission.

The Human owner can delete an idle native conversation. The delete operation
locks its execution target and conversation. Pending and running Signals cause
`conversation_busy`; the owner can retry after the work finishes. The operation
ends the target's active model history, removes messages and participation,
and leaves saved Pages in place. A saved
Page reports a deleted source only when its source message is absent.

Cron reports and notices
can target a native conversation through its UUID. Its own execution Session
reads those committed statements on the next request; the cron rule keeps a
separate model history. Native multi-person and multi-Agent creation,
conversation rename, and conversation search remain outside the current Pod
interface.

## Observe an External Conversation

An external identity is unique by `(tenant_id, provider_conversation_id)`.
The provider ID includes the adapter namespace, such as `lark:oc_xxx`. The
conversation stores neither an Agent host nor a Binding host. Agent and Binding
identify the receiving observation entrance or the sending Delivery. An adapter
that learns a room outside a message, such as a channel sync, records it with
`Conversations.observe_external_conversation/3`.

`Conversations.Observe` normalizes the provider observation, evaluates Binding
filters against the platform identity, resolves the shared UUID, and persists
the public Message plus its external reference. Signal acceptance belongs to
`Signals`; it uses the target Agent's own `conversation:<uuid>` Session. A second
Agent observing the same platform message reuses the same Message UUID and
sequence. A confirmed Agent send and a subsequent provider push also converge
on that identity. A quote of a previously ignored but retained batch observation
promotes that real observation to a Message before the reply links to it.

Unmapped authors and attachment-only messages are valid external facts. Their
text and Principal association can be null. Provider authors and reaction actors
remain platform observations, not execution authorization. Known replies use
public Message UUIDs; an unobserved parent retains its opaque provider ID in the
external reference. Edits preserve the Message UUID and sequence, and older
provider versions cannot overwrite newer content. Provider deletions remove the
statement and retain a deletion guard keyed by tenant, Conversation UUID, and
provider message ID. The guard applies to every Agent and binding that observes
the room, including queued replies. Removing an observing Agent does not remove
this shared guard.

An observation that changes a public statement commits `message_changed_in_tx`
in the same transaction. It invalidates affected Brain learning. Explicit input
edits, supplements, and removals apply their revision rules; changing a
background statement does not create a revision. A duplicate observation does
not reset learning. Durable jobs and facts own crash recovery.

The public record owner does not invoke Session execution. One transactional
exception applies: removing a shared Message calls
`Sessions.AmbientCuration.message_removed_in_tx/1` so every Agent's accepted
ambient judgment loses its anchor atomically. The database requires accepted
judgments to retain an anchor. `Sessions.Key` is a pure value-format dependency;
it performs no Session execution.

## Read Shared History and Learn It

Every Agent in an external room has its own Session, model Responses, visible
branch read watermark, and ambient judgment history. All read the same public
statements and standing orders. A Session snapshots a bounded list of unread
Messages before a request, and commits `conversation_read.max_seq` plus the
actual `message_ids` with the request. It excludes its own committed output by
both author Agent and Session; another Agent's output remains readable even
though both Sessions use the same `conversation:<uuid>` string.

Completed model history is replayed exactly as stored, including its original
background statements and quotes. Editing a background Message during a turn
does not interrupt that turn. An edit keeps the Message sequence, so later
turns do not reread a statement below their watermark.

At the terminal check, withdrawal of an explicit source returns
`:signal_canceled`. If only a background Message read by this turn has been
removed, the check returns `:signal_context_canceled`: the turn stops, posts a
`context_withdrawn` notice, and does not publish its original answer. The read
set comes from this turn's model-call `conversation_read.message_ids`, with
its explicit input Message IDs removed.

Brain uses one shared conversation Source and its audience. Its learning cursor
uses Message sequence, and multiple Agents do not cause duplicate source
extraction. An edit or deletion of an already learned statement rewinds the
Source and withdraws newly tracked source-derived claims before relearning.
Ambient judgment cursors are derived separately from each Agent's own
`session_ambient_judgments`, including its recorded `judged_until`; there is no
shared cursor column on the conversation.

## Deliver a Statement

`Conversations.post_in_tx/2` is the statement operation. A validated
`Conversations.Target` supplies its kind, Conversation UUID, Binding, thread,
and primary flag. `Target.for_reply/2` resolves a reply route;
`for_delivery_in_tx/2` validates a cron destination and Agent participation.
Native destinations accept no Binding or thread. External destinations require
a Binding. Native and external replies use the same attachment tools; the
receiving adapter owns delivery of the committed attachment facts.

A `Conversations.Statement` carries reply completion/outcome or notice facts.
The operation returns a `Conversations.PostResult` with `messages` and `intents`.
It appends a native Message or commits an external Delivery intent. Only the
primary target owns preview finalization and interactive reply presentation.
Callers retain the Session lock in the same transaction before public rows are
written. They publish returned Messages after commit.

`Conversations.Delivery` keeps the public commit/dispatch/requeue API and owns
intent submission. `Delivery.Dispatch` claims and sends; `Recovery` owns retry
and uncertain outcomes; `Mirror` commits provider-confirmed public statements;
`Queries` supplies durable surface lookup and stopped-delivery projections.
Intents in `deliveries` record the speaking Agent, Binding, public IDs, and
opaque provider references. `Delivery.sent_provider_message?/4` tells an
adapter whether a quoted provider message is one that a Binding sent. Work
completion and delivery completion are separate facts.

`recovery_status` and `recovery_reason` record why a failed or unknown delivery
stopped. The status is `blocked`, `permanent`, or `exhausted`. PostgreSQL requires
a paired reason and rejects these fields on another delivery status.
`possible_duplicate` records an uncertain prior send; `possible_duplicate_notice`
records its visible warning. Automatic retries cannot advance a stopped or
ambiguous delivery. An explicit requeue grants one further attempt on the same
row and retains the warning.

`recovery_state` contains only Adapter-owned provider anchors, such as CardKit
card IDs and streaming state. Recovery, requeue, and retry failures preserve
these anchors. PostgreSQL rejects control-plane recovery keys in this JSONB
column. LINE reads the typed duplicate flag before it permits an aged retry.

| Status | Meaning |
| --- | --- |
| `pending` | Durable and awaiting delivery; a recorded send-start timestamp can indicate an in-flight attempt |
| `sent` | Provider success and canonical public statement were committed together |
| `failed` | A known failure; its reason and retry policy determine whether it can retry |
| `expired` | Expired before sending; the provider is not called |
| `unknown` | The send cannot be confirmed; automatic resend stops |

`Delivery.Intent` owns the state machine and all persisted transitions through
Ash actions. An update matches the stored status and attempt count, so a stale
snapshot cannot claim another attempt or replace a newer result. Commit retries
return the original row without replacing its payload or state.

The pending send claim records start time and atomically increments the attempt
count before the network call. Recovery reconciles the claimed attempt when the adapter supports it, or
records unknown. A late response cannot overwrite a newer attempt. Failed sends
have a bounded attempt budget. Unsupported operations are failed with a permanent
reason. Operator requeue preserves the intent and audit; explicitly retrying an
unknown visible reply adds one possible-duplicate notice. Requeue sets the budget
to the consumed attempt count plus one; it does not reset the count. Sent and
expired rows cannot return to a sendable state. It is never an automatic retry
policy.

Each confirmed chunk keeps its own provider ID, exact delivered text, and public
Message UUID. Missing provider identity never produces a synthetic platform ID.
An ambiguous acknowledgement remains unknown with sanitized diagnostics. If the
local statement transaction fails after a send, the retained claim prevents blind
resend and allows reconciliation. Failed and unknown intents do not invent public
statements. Referenced attachment bytes remain retained after the receiving Agent's
drive catalog or Binding disappears.

Delivery filters configured secrets immediately before invoking the provider.
Secret candidates shorter than 12 characters are excluded to avoid replacing
common short text. Public diagnostics use the secret sanitizer rather than
logging credential payloads.

Provider-native previews are transient renderers. Their versioned checkpoint,
sequence high water, first recorded provider message identity, and terminal
presentation live in the Delivery-owned `delivery_previews` row, keyed by
`(tenant_id, signal_id)`. Writers lock the source Signal before the preview row.
`Delivery.PreviewStates` owns these writes to the `Delivery.PreviewState`
resource. Its checkpoint update locks and loads the Signal, applies the
requested change, and persists the fenced checkpoint in one transaction.
Recovery, cleanup, and fallback use this same path. The preview process claims,
hands off, and checkpoints its surface through `Delivery.PreviewStates`
top-level transactions; the process itself opens no transaction. Signal deletion cascades to its preview. Its resource attributes validate the JSON checkpoint and nonnegative
sequence directly. `Delivery.ReplyPresentation` owns the renderer-safe presentation.
These facts let durable delivery settle or recover the visible surface. They do
not make a streamed draft an immutable model or conversation record. Native
conversations use Pod SSE and never start an external preview.

See [Signals](Signals.md) for intake and adapter contracts, [Sessions](Sessions.md)
for execution and recovery, [AIGateway](AIGateway.md) for model state,
[Browser Sessions](BrowserSessions.md) for authentication, and
[Human Offboarding](HumanOffboarding.md) for retained work authorization.
