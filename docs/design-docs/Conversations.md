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
| `conversations` | Public UUID, native/external kind, title, activity, sequence high water, external platform identity, and standing orders |
| `conversation_participants` | Conversation, Principal, and role; native creation admits one Human owner and one Agent, external rooms can have multiple Agents |
| `conversation_messages` | Public UUID, conversation, sequence, author, kind, exact text, attachments, public reply reference, and execution provenance |
| `external_message_refs` | Platform message/thread/reply IDs, raw author, metadata, reactions, content hash, and observation times for an external Message |

Each table has a tenant foreign key. Primary and unique keys include
`tenant_id`. The tenant deletion owner includes all four tables.

A message sequence is unique within its conversation. Writers lock the
conversation before they allocate the next sequence from its retained high water.
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

`Conversations.MessageInput` computes message-backed input revisions without
database writes. It updates source entries, their summary, ambient batch facts,
and the attachment supplement deadline. Both `Conversations.InputRevisions`
and `Sessions.Revisions` use this calculation. The former owns queued changes
and revision intake; the latter owns in-flight cancellation, retained effects,
and recovery. Each caller keeps its existing transaction and locks. Inbound
batch windows and supplement waiting remain separate policies. Other Signal
sources do not need this message representation or these revision rules.

## Accept a Human Message

The current Human must participate in the conversation. Every active Agent in
that Human's tenant is available for a new conversation. Native conversations
do not require a configured provider binding or a separate enable flag.

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
| Data | Conversation ID, message ID, author UID, and exact message text |

`Ankole.Signals.accept_in_tx/2` stores the input in `signals`, allocates its
Agent/Session queue position, and commits an EnsureDriver job in the same
transaction. Native conversations create no Signal Binding, external reference,
or Delivery intent. WorkAccess freezes the Human UID and access version;
admission checks those facts again when execution starts.

The browser generates the conversation and message UUIDs. A retry with the
same IDs and facts reuses the stored message and signal. Reusing an ID for
different facts returns `conversation_conflict`. Text must be valid UTF-8,
contain no NUL character, and be nonempty after whitespace is removed from both
ends. Storage and retry comparison retain the original text. The title uses
the first nonempty line, up to 80 characters.

The control plane wakes the Driver and publishes conversation events after
the transaction commits. A rollback publishes no event and leaves no accepted
message or signal. Public publishing entry points reject an outer transaction.
A transaction owner uses `create_in_tx/3` or the Human `post_in_tx/4`, retains
the returned `publications`, and calls `publish_committed/1` after commit.
The durable EnsureDriver job remains the recovery wakeup path.

When a tenant is suspended, admission can reject a queued follow-up while the
earlier admitted turn continues. The notice and completed follow-up commit
together; the page receives message and status events after that commit.

## Execute and Commit the Reply

The native signal enters the existing main Session loop. `Prompt.Input` reads
the Human message text. A follow-up from the same Human can join the active
Run through the existing steering path.

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

The internal API is mounted at `/.internal-apis/pod`. It uses the same
access gate as the Pod shell: setup must be complete, and the browser
must have an active site administrator session. Unsafe requests require CSRF
proof. These routes are excluded from the public Console OpenAPI contract.
`InternalAPISpec` selects the private router operations for build-time client
generation. Controllers and domain functions retain runtime validation;
generation does not add request casting middleware. `mix ankole.openapi.check`
checks both contracts (`--write` updates them); the webapps `openapi:generate`
script generates both clients.

The authenticated Principal determines the tenant. A Console data tenant
selection cannot change the Pod tenant. Read, write, and SSE operations
check that the current Human participates in the conversation.

| Method and path | Contract |
| --- | --- |
| `GET /agents` | `{agents: [{uid, displayName}]}` for active Agents |
| `GET /conversations` | `{conversations: [...]}` with the latest 100 participating conversations, ordered by recent activity |
| `POST /conversations` | Accepts `conversationID`, `agentUID`, `messageID`, and `text`; returns the committed conversation detail |
| `GET /conversations/:id` | Returns conversation detail, the latest 500 messages in sequence order, and execution status |
| `POST /conversations/:id/messages` | Accepts `messageID` and `text`; returns the committed conversation detail |
| `GET /conversations/:id/events` | SSE for committed changes, current activity, and subsequent live model text |

Both POST operations return HTTP 200 on success. Conversation summaries contain
`id`, `title`, `agent` (`uid`, `displayName`, `active`), and `lastActivityAt`.
Detail responses contain `conversation`, `messages`, and `status`.

Each message contains `id`, `seq`, `authorType`, `authorUID`, `kind`, `text`,
`createdAt`, `signalID`, and `replyToMessageID`. `authorType` is `human` or
`agent`; `kind` is `message` or `notice`. Human `signalID` values are null.
Timestamps use ISO 8601.

Status contains `state`, `retryAt`, and `activity`. State is `idle`, `queued`, `running`, or
`retrying`. `retryAt` is a timestamp for a scheduled retry and null otherwise.
Sessions derives this status from its durable inbox.
Ready admitted input takes priority over queued input, which takes priority
over future retries. An earlier retry must not hide later work that can run.

Domain errors use the `{error: {code, message, details}}` envelope:

| HTTP status | Codes |
| --- | --- |
| 422 | `invalid_request`, `invalid_id`, `invalid_text` |
| 404 | `conversation_not_found` |
| 409 | `agent_unavailable`, `conversation_conflict` |

The session gate returns HTTP 401 with `unauthorized` when access is absent or
inactive. CSRF protection rejects an unsafe request without valid proof.

## SSE and Visible History

The SSE endpoint checks access before it subscribes. It combines the native
conversation's tenant-scoped PubSub topic with AIGateway events for that
conversation's Agent and model conversation. The connection sends a `: ping`
comment every 15 seconds and removes both subscriptions when it closes.

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

Conversation events are published after acceptance, admission, retry,
completion, or dead-letter commit. Agent disablement, enablement, and permanent
deletion also publish `status` after commit.

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

## Agent Lifecycle and Scope

Disabling an Agent preserves its native conversations and history. Reads stay
available; new conversations and messages return `agent_unavailable`. Pod
disables the composer and explains that the Agent is unavailable.

Permanent Agent deletion removes its native conversations, participants, and
messages before it deletes the Principal and its signals. This order satisfies
the message's source signal foreign key. Existing pages refresh on the status
event, remove cached detail on `conversation_not_found`, and close SSE.

Native conversations currently support text only. Their model tool contract
omits `reply_attachment` and hosted `image_generation`. Cron reports and notices
can target a native conversation through its UUID. Its own execution Session
reads those committed statements on the next request; the cron rule keeps a
separate model history. Native multi-person and multi-Agent creation, native
attachments, and conversation rename, deletion, search, stop, and regenerate
controls remain outside the current Pod interface.

## Observe an External Conversation

An external identity is unique by `(tenant_id, provider_conversation_id)`.
The provider ID includes the adapter namespace, such as `lark:oc_xxx`. The
conversation stores neither an Agent host nor a Binding host. Agent and Binding
identify the receiving observation entrance or the sending Delivery.

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
edits, supplements, and removals retain their revision rules; changing a
background statement does not create a revision. A duplicate observation does
not reset learning. Durable jobs and facts own crash recovery.

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

`Conversations.post_in_tx/3` is the statement operation. A validated
`Conversations.Target` supplies its kind, Conversation UUID, Binding, thread,
and primary flag. `Target.for_reply/2` resolves a reply route;
`for_delivery_in_tx/3` validates a cron destination and Agent participation.
Native destinations accept no Binding or thread. External destinations require
a Binding. The same target declares whether attachment tools are available.

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
opaque provider references. Work completion and delivery completion are
separate facts.

| Status | Meaning |
| --- | --- |
| `pending` | Durable and awaiting delivery; a recorded send-start timestamp can indicate an in-flight attempt |
| `sent` | Provider success and canonical public statement were committed together |
| `failed` | A known failure; its reason and retry policy determine whether it can retry |
| `expired` | Expired before sending; the provider is not called |
| `unknown` | The send cannot be confirmed; automatic resend stops |

The pending send claim records start time and attempt count before the network
call. Recovery reconciles the claimed attempt when the adapter supports it, or
records unknown. A late response cannot overwrite a newer attempt. Failed sends
have a bounded attempt budget. Unsupported operations are failed with a permanent
reason. Operator requeue preserves the intent and audit; explicitly retrying an
unknown visible reply adds one possible-duplicate notice. It is never an automatic
retry policy.

Each confirmed chunk keeps its own provider ID, exact delivered text, and public
Message UUID. Missing provider identity never produces a synthetic platform ID.
An ambiguous acknowledgement remains unknown with sanitized diagnostics. If the
local statement transaction fails after a send, the retained claim prevents blind
resend and allows reconciliation. Failed and unknown intents do not invent public
statements. Referenced attachment bytes remain retained after the receiving Agent's
drive catalog or Binding disappears.

Delivery filters configured secrets immediately before invoking the provider.
Secret candidates shorter than 12 characters are excluded to avoid replacing
common short text. Public diagnostics use the existing sanitizer rather than
logging credential payloads.

Provider-native previews are transient renderers. Their versioned checkpoint,
sequence high water, first recorded provider message identity, and terminal
presentation live in the Delivery-owned `delivery_previews` row, keyed by
`(tenant_id, signal_id)`. Writers lock the source Signal before the preview row.
`Delivery.PreviewState` owns these writes; Signal deletion cascades to its
preview. `Delivery.ReplyPresentation` owns the renderer-safe presentation.
These facts let durable delivery settle or recover the visible surface. They do
not make a streamed draft an immutable model or conversation record. Native
conversations use Pod SSE and never start an external preview.

See [Signals](Signals.md) for intake and adapter contracts, [Sessions](Sessions.md)
for execution and recovery, [AIGateway](AIGateway.md) for model state,
[Browser Sessions](BrowserSessions.md) for authentication, and
[Human Offboarding](HumanOffboarding.md) for retained work authorization.

The public record owner does not invoke Session execution. One transactional
exception remains: removing a shared Message calls
`Sessions.AmbientCuration.message_removed_in_tx/2` so every Agent's accepted
ambient judgment loses its anchor atomically. The database requires accepted
judgments to retain an anchor. `Sessions.Key` is a pure value-format dependency;
it performs no Session execution.
