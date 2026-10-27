# Conversations

`Ankole.Conversations` owns the shared conversation, participation, and public
message records. A native conversation is a shared room for Humans and Agents
hosted by Ankole. An external conversation is hosted by a platform. Each Agent
can observe and speak in the same room through its own execution session.

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
| `conversations` | Public UUID, kind, room mode, access scope, optional Page, custom title, per-Agent model preferences, activity, sequence high water, external platform identity, and standing orders |
| `conversation_participants` | Conversation, Principal, role, Agent intervention setting, and personal pin, mute, and read position |
| `conversation_messages` | Public UUID, conversation, sequence, author name snapshot, kind, exact text, attachments, mentions, links, structured content, delivery key, reply reference, and execution provenance |
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

Human messages have no execution provenance. Agent replies retain the execution
session ID, source Signal ID, and `delivery_key`. The unique key includes the
Conversation, Signal, and delivery key. One Signal can commit a Clarify message
and a final reply without duplicate messages on retry.

Native messages store a nonempty `author_display_name`. An Agent's deletion
can independently clear the author UID and Signal foreign keys. The recorded
name and Session identity keep group history readable. The database checks
native Human provenance and Agent Session identity at each statement; creation
also requires the active Agent author and source Signal.

## Native Room Access and Participants

A native room starts as `room_mode: dm` for one Human and one Agent. A second
Human or Agent promotes it to `group`. This mode cannot return to `dm`.

`native_access_scope: participants` admits explicit active participants.
`anchor_page` requires a Page and current `page_view` permission. A Human who
can view that Page can read and join its discussion. The first accepted message
adds that Human as a participant in the same transaction. The access check reads
current page and Principal state, including page removal.

The global Chat list includes only rooms with a participant row for the current
Human. An anchor-page room also requires current Page access. A Page's Chat list
includes its shared rooms before the Human joins. An unjoined viewer has no
unread indicator. Room members, the room creator, Pod administrators, and Page
managers of an anchor-page room can rename the room or invite participants.
Changing an Agent's intervention setting also requires `chat` permission for
that Agent.

The participant action admits Humans in the tenant and Agents that the Human
can invoke. It records member changes as lightweight `notice` messages with
`rich_content.event`. Title and visibility changes use the same event format.
A Page reader can store pin, mute, and read preferences as an observer.
An observer has no access in `participants` scope and does not appear in the
member list or room-mode count. A message or explicit invitation promotes the
observer to a member. Each Human owns their pin, mute, and monotonic
`last_read_seq`. Agent
`may_intervene` controls responses to messages without an explicit Agent target.

Group members can set or clear the room's standing orders through
`set_channel_standing_orders`. The room stores the complete policy and its setter.
Member-set policy applies within the room and the Agent's permissions.
An Agent with `may_intervene: true` receives these orders in both addressed and
listening turns. The tool reports whether the policy is active for that Agent.
Native direct rooms do not expose the tool.

## External Message Batching

`Conversations.InboundBatches` owns one shared batching policy for IM adapters.
A batch is scoped by tenant, Agent, binding, conversation, and thread. Requester
continuity decides whether an incoming observation can extend that batch. The
batch deadline and finalize job commit in the same transaction; an early wakeup
retries at the stored deadline. Adapters own platform wire formats and identity
observation, Conversations owns batching and source tombstones, and Signals accepts the
resulting stimulus. Adding an adapter does not copy these windows or recovery
rules into that adapter.

The outer intake transaction publishes its accepted Signals through
`Signals.publish_committed/1` after commit. This includes direct inputs,
scheduled batch finalization, and batches finalized by a later observation.
Publication sends Session notifications and wakes ready input. The same
transaction records the durable Driver wakeup.

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

The current Human must have room access. Creation and each selected Agent
target require `chat` permission on `agent:<agent_uid>`. The Agent must be active
and belong to the Human's tenant.

Creation commits the room, initial participants, first Human message, and each
selected Agent's input and durable wakeup in one transaction. Explicit
`mentions` or `targetAgentUID` select the addressed Agents. A mentioned Agent
with current invoke permission can join as part of that transaction. Without
an explicit target, a direct chat addresses its active Agent. A group addresses
only Agents with `may_intervene`, including when only one active Agent remains.
If no Agent qualifies, the
Human message still commits for the room's participants. A listening Agent can
finish silently when it has nothing to add. An explicitly addressed Agent uses
the normal reply contract.

A Page viewer can post to a shared direct room without permission to invoke
its Agent. The message joins the Human and promotes the room to a group. It
creates no Agent input when no permitted target is selected. Explicit Agent
targets require `chat` permission.

Only Human input starts this route. An Agent message or streamed output does
not wake another Agent. Each target uses `(agent_uid, session_id)` with the
shared Session ID `conversation:<conversation_id>`. Queue admission, steering,
model preference, and stop apply to that Agent's slot. Context filtering
excludes queued input only for the Agent that owns the queue.

A later message commits its message and each addressed Agent's Signal and
durable wakeup in one transaction. The signal has these values:

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
Retry matching includes canonical Page links, mentions, and the explicit Agent
target, as well as the original text and attachments.
Text must be valid UTF-8,
contain no NUL character, and be nonempty after whitespace is removed from both
ends. Storage and retry comparison retain the original text. The default title uses
the first nonempty line, up to 80 characters. A manual title sets
`title_customized`; clearing it restores the message-derived title.

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

The source Signal ID and delivery key prevent duplicate Agent messages when
completion is retried. This does not make upstream model requests execute exactly once. An
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
check the current Human and the room access scope.
All Pod requests require Guest admission under `pod.allow_external_guests`.
The Agent directory lists only active Agents for which the Human has `chat`
permission. Model profile lookup uses the same Agent permission check.

| Method and path | Contract |
| --- | --- |
| `GET /agents` | Active Agents that the Human can invoke |
| `GET /teammates` | Active Humans in the tenant, with an optional search query |
| `GET /conversations` | Accessible rooms with personal preferences, Agent identities, activity status, search, cursor pagination, and pinned-first or recent activity order |
| `POST /conversations` | Initial Agents and Humans, first message, optional Page and access scope |
| `GET /conversations/:id` | Room, participants, message window, room-wide artifacts and pending questions, Agent activities and queues, and linked background work |
| `GET /conversations/:id/executions/:kind/:run_id` | Read one page of a linked execution log with an optional opaque `cursor`; returns `text` and `nextCursor` |
| `PATCH /conversations/:id` | Title, access scope, or the current Human's pin, mute, and read position |
| `POST /conversations/:id/participants` | Add or remove participants, or change an Agent's intervention setting |
| `POST /conversations/:id/messages` | Human message with structured mentions, links, and optional Agent target |
| `POST /conversations/:id/queue` | Queue, stop, or retry command for the selected Agent |
| `POST /conversations/:id/interactions/:interaction_id/answer` | First accepted choice or message answer to a pending Clarify interaction, with optional references, Human mentions, and attachments |
| `GET /conversations/:id/events` | One SSE connection for room changes and all participating Agents |
| `GET /agents/:uid/model-profiles` | Available model profiles for that Agent |
| `GET /conversations/:id/model-profile` | Selected and active profile for the requested Agent |
| `PUT /conversations/:id/model-profile` | Store that Agent's selected profile |
| `DELETE /conversations/:id` | Authorized room deletion; `forceStop` stops active work before deletion |

Room details include all linked execution entries as lightweight metadata with
identity, title, status, and timestamps. Log
requests accept `background_agent_job` or `workflow` and the owning domain's
ModelIntegerID. Each page checks current room access and the execution's room
Session. Background Job pages use the existing Console turn cursor. Workflow
pages use call sequence order. Logs include public Agent output, tools, results,
and errors. They exclude hidden model context and workflow source arguments.

The `artifacts` field lists referenced and visible saved Page IDs, and attachment
groups with their source Message IDs. It covers non-withdrawn room messages
through the room's sequence high water, independent of the message window.
`pendingInteractions` reads each Agent's latest question and its durable
interaction state. These room-wide views use the same browser projection and
access scope as the timeline.

A native Conversation can belong to one Page. Conversations owns the stable
`page_id` association. A Page discussion can be private to participants or
shared with current Page viewers. Page Chat and the full Chat view use the same
room and committed history. A room in `anchor_page` scope loses access when its
Page is removed or the Human loses `page_view` permission.

An input records the Human who addressed the Agent. Tool and Pod operations
use that Human's current permissions intersected with the Agent's permissions.
Another participant's wider access cannot authorize this input. Derived work
keeps the same WorkAccess identity. The Page context requires a fresh read
before a change.

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

Each message contains `id`, `seq`, `authorType`, `authorUID`,
`authorDisplayName`, `authorArchived`, `kind`, `text`, `richContent`, `mentions`,
`links`, `savedPages`, `createdAt`, `signalID`, and `replyToMessageID`. `authorType` is `human` or
`agent`; `kind` is `message` or `notice`. Human `signalID` values are null.
Timestamps use ISO 8601.
Mentions identify selected Principals by type and UID. `displayName` carries
the visible name selected with the mention.

Each `pendingQueues` entry has its Agent's inputs, queue version, pause state,
retry capability, and durable `workStatus`. Work status contains `state` and
`retryAt`. State is `idle`, `queued`, `running`, or
`retrying`. `retryAt` is a timestamp for a scheduled retry and null otherwise.
Sessions derives this status from its durable inbox.
Ready admitted input takes priority over queued input, which takes priority
over future retries. An earlier retry must not hide later work that can run.
Paused, unadmitted queue inputs are not eligible work. A conversation with only
those inputs is idle; releasing one input can make it queued or running while
the remaining queue stays paused.

`Conversations.get/3` reads the message range, pending inputs, each Agent's queue
version, retry capability, and durable Session status in one transaction under
the Session advisory locks. Input acceptance, admission, and terminal
reply commits use the same lock. A detail read cannot combine messages from
before a native reply commit with an idle status from after that commit.
The same transaction reads member Principals, queued Message references,
pending interaction checkpoints, and linked execution facts. Browser projection
does not query the database. Room lists read work states, pending interactions,
and background executions in batches across the selected rooms. Activity
remains a separate temporary observation and can be newer than this detail.

Domain errors use the `{error: {code, message, details}}` envelope:

| HTTP status | Codes |
| --- | --- |
| 422 | `invalid_request`, `invalid_id`, `invalid_text`, `invalid_choice`, `participant_unavailable`, `cannot_remove_last_participant`, `anchor_page_required`, `invalid_execution_cursor` |
| 403 | `page_unavailable`, `forbidden`, `forbidden_room_operation` |
| 404 | `conversation_not_found`, `execution_not_found` |
| 409 | `agent_unavailable`, `conversation_conflict`, `conversation_busy`, `queue_changed`, `input_already_started`, `reply_unavailable`, `interaction_not_pending`, `requires_queue_for_profile` |

The session gate returns HTTP 401 with `unauthorized` when access is absent or
inactive. CSRF protection rejects an unsafe request without valid proof.

## Pod Chat Workspace

Chat Home centers the greeting, Agent selection, and large composer. Starter
suggestions appear while the draft is empty and fill it on selection. Recent
rooms provide direct entry. The sidebar
has personal pins, date groups, title and message search, and current work,
decision, background, and unread indicators.

Committed room changes and native Session status changes notify active Pod
tabs. The content channel coalesces sidebar refresh hints for 1,500 ms. Each
refreshed list applies current participant and Page access checks.

The room header provides inline title editing, participant management, link
copy, and Markdown export. The summary panel shows Agents and their models,
Humans, referenced and saved Pages, attachment previews and downloads, and
background work from the whole room. Loading earlier timeline messages does
not determine which artifacts exist. Participant avatars use each Principal's image with a name
fallback. Group members can set whether an Agent can answer unaddressed input;
direct input in a direct chat addresses its Agent. Keyboard
shortcuts open room search and the summary panel. Search loads earlier message
pages through the history cache and reports incomplete results while loading
or when a read fails. Closing search stops further page loads. Search uses
browser text highlights without changing the message DOM and updates when
recorded tool details open.

The workspace uses the shared Ankole UI kit theme. Message surfaces, command
output, text, selection, and status colors follow its semantic tokens in both
light and dark themes. The UI kit owns the composer's field and focus styles.

The timeline identifies each author and keeps room events compact. Turn previews
follow each reply's saved source Message ID. An interleaved reply links to its
original question and returns reading focus there. Markdown
supports highlighted code, tables, formulas, Page links, and image previews.
Completed work folds above the reply. Active work shows the current action and
folds earlier steps and reasoning. Failed and stopped work opens its recorded
details. Terminal steps show the command, output, and exit code when the tool
records these fields. Each background task appears once in its active source
turn, then under the corresponding saved reply. Background work opens a paged execution log within the
room's access boundary. Message actions provide copy, quotation, supported edits,
Agent retry, and Save to Pod. Saved Pages appear as links under their source.

The composer supports Agent and Human mentions, Page references, commands,
attachments, and independent model preferences. IME confirmation does not send
a message. Mention and command completion keeps focus in the composer and
supports arrow keys, Tab, Enter, and Escape. An open mention search accepts
names and Page titles with spaces. Page references and message quotes use the
message's stored links in the current model input and conversation
context. A reference identifies content; the Agent's tools check access when
they read it. A reader without Chat permission can view a question but cannot
submit its answer. Send and retry use the same submission decision. An explicit
recipient must be active in the room and callable by the viewer. Edits use their
saved Agent target, and answers use the question's Agent. New composer messages
use queued delivery. The queue has a bounded scroll area with one-line previews
and explicit order controls. Steer merges a selected
pending input into the current turn. Each Agent's queue supports steering, editing, reordering, removal,
and explicit resume after stop. Take back restores queued text, files, references,
and Human mentions. An empty draft targets that Agent's queue; other Agent
recipients are not replayed. It appends to an occupied draft. A shared queued
message can be edited only before every effective target starts. Editing compares
the saved text, references, and mentions. Removed Human mentions are removed from
the saved message; its Agent targets stay fixed. One composer edit stays active
until the Human saves or cancels it. Conflict recovery keeps the local draft and
reads the selected Agent's queue version. Loading the saved version explicitly
accepts its text and references, including when only references changed. The
empty-composer Up shortcut uses the same eligible latest Human message as the
timeline's edit action, or the Human's latest editable queued input.
In a room with one Human, input that is still unadmitted appears only in its
queue. A later Agent reply makes it visible in the timeline with a queued
badge. In a room with several Humans, the timeline shows the queued input too.
A Page reference uses a named chip; removing
the chip removes the reference and leaves ordinary draft text intact.
A completed message sent to several Agents requires a new correction message.
Page Chat uses the same room in a resizable
panel with Page context, room access selection, and a full-view link.

## SSE and Visible History

The SSE endpoint checks access before it subscribes. It subscribes to
Conversation events and to each participating Agent's Session and AIGateway
topics. Room changes update this subscription set. All topics are tenant-scoped.
The connection subscribes before reading current Driver snapshots.
An open stream subscribes to each Agent's current model conversation and restores
an available display snapshot when that identity changes.

Before each business frame and each 15-second heartbeat, it checks current
Human admission and room access. Page access broadcasts also trigger this
check. A failed check clears pending deltas, sends `access_revoked`, and closes
the connection. The browser removes cached history. It shows local unfinished
work in the recovery view, or returns to Chat Home when no local work remains.

| Event | JSON data | Meaning |
| --- | --- | --- |
| `connected` | `{conversationID}` | Room subscription is ready |
| `conversation` | `{conversationID}` | Committed messages, queues, participants, or execution status changed |
| `started` | `{conversationID, agentUID, responseID, signalIDs, agentName, turnStartedAt}` and optional `sessionID` | One Agent starts a model Response |
| `snapshot` | `{conversationID, agentUID, responseID, signalIDs, agentName, turnStartedAt, text, thinkingSummary, seq}` | Replace the current Response display when a connection or Agent subscription starts |
| `delta` | `{conversationID, agentUID, sessionID, responseID, signalIDs, text}` | Text for that Response |
| `reasoning_delta` | Same identity fields and `text` | Reasoning summary for that Response |
| `activity` | Current activity snapshot | Current phase and ordered tool steps |
| `access_revoked` | `{conversationID, reason}` | Room access has ended |

Text and reasoning deltas use a 40-millisecond buffer per Agent. Control frames
flush the buffer. One Agent's text cannot enter another Agent's buffer.

The ResponseStream owns the active text and thinking display snapshot. The
Driver combines recorded thinking from earlier model rounds with this snapshot.
A connection subscribes before it reads these views. Each snapshot sets a
Response sequence watermark; queued events at or below that watermark cannot
duplicate its prefix. A new connection replaces each active Agent's display
before it appends later deltas. Snapshots are temporary runtime views. Committed
Conversation messages own durable history.

An activity snapshot contains `conversationID`, `agentUID`, `sessionID`,
`signalID`, `responseID`, `epoch`, `revision`, `state`, `phase`, and `tools`.
Its state is `active`, `unavailable`, or `settled`; it is a display observation,
not a second execution lifecycle. Labels have bounded text and bindings, and
`tools` retains the ordered steps in the current turn, including completed
and failed steps with duration. Tool arguments and result bodies do not enter
this activity projection. The browser shows the active phase label even when
an active Response has a live text stream. The phase label is separate from the
recorded thinking summary. An unavailable or settled snapshot clears this label.

The stream subscribes before reading a bounded current Driver snapshot. It
checks the stored workspace epoch and open Signal before accepting active
details, and monitors the Driver. The initial frame includes the current
snapshot, so a late connection can show a capacity wait without replaying an
event log. Epoch and revision ordering reject older observations; a settled
epoch cannot reopen. Driver loss, retry, and disconnection clear transient
details and fall back to the durable status. While the connection is closed,
an active snapshot cannot restore these details. A new connection accepts its
current snapshot. An activity frame never triggers
a full history read.

`Conversations.Events` publishes a message event after a public statement commits.
Its status event covers Conversation deletion and Agent availability.
`Sessions.Events` owns acceptance, queue, admission, retry, and terminal state
notifications. A committed turn publishes one `turn_completed` notification in
place of a status notification. The SSE connection maps either to the
`conversation` frame. An external turn completion proves that its Delivery intents
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

The page reads detail again on every connection and `conversation` event. Each event must cause a read taken after that event; an older request
already in flight cannot satisfy it. A late POST response cannot replace more
recent history. The page keeps unconfirmed message IDs for retry and removes
them when those IDs appear in committed history. It clears live text when the
matching reply commits, or when a fresh execution status settles that same
Response without a visible reply.

Each Agent queue returns its pending inputs, durable pause state, comparison
token, and latest retryable message. Queue edits and reordering check that token
under the Session lock. Queue commands name their target Agent.
The Chat action requires `agentUID`. Ash validates required transport fields
before the domain operation. A missing field returns HTTP 400 with a JSON:API
`errors` entry that identifies the field.
A lost response to an already committed retry can replay the same command ID;
it does not create another input or recapture its model selection.

Stop cancels the current reply and pauses unadmitted inputs, including pending
steer messages. With no admitted input, the same transaction consumes the Stop
command and keeps the queued inputs paused. Refresh retains the pause. Continue
resumes the queue; Steer releases only its selected input. A stale edit retains the local draft. An
explicit refresh can adopt the new comparison token only while the saved text
still matches the original; a changed saved message requires an explicit choice.

Last-turn editing and regeneration reuse Commands and ModelHistory. A Human
message edit uses its persisted Signal targets, independent of the loaded
history and composer recipient. A single-target edit checks that Agent's queue
and work status. Human-only and multi-target inputs require a correction message.
The latest eligible failed reply
exposes Retry through the same capability predicate;
Stop and preflight notices do not become retryable merely because they are
notices. A new Human retry captures the current Chat model preference. Completed
Page, Base, and Applet changes remain. Native edits, regeneration, and logical
queue removal call the message-change lifecycle in their transaction,
invalidating affected Brain facts and rewinding its learning cursor. Removed
messages retain stable idempotency identities while a shared visibility query
excludes them from history, Main context, and Brain learning.

History reads return at most 500 visible statements and an earlier-message
cursor. The covered sequence interval lets the browser merge older windows into
its existing cache without discarding loaded history or restoring removed text.

## Clarify and Execution History

A native Clarify delivery commits an Agent message with
`delivery_key: "clarify:<tool_call_id>"`. Its `rich_content.clarify` holds the
question, choices, free-text setting, and interaction identity. The existing
Delivery interaction checkpoint owns mutable state: `pending`, `answered`, or
`superseded`. A message projection reads that state from the checkpoint.
When a completion includes prose and Clarify, the prose precedes the question.
The execution summary belongs to the prose, or to the question when there is
no prose. A committed question clears that Agent's live output.

Answer acceptance locks the checkpoint. Only the first pending answer commits;
another answer receives `interaction_not_pending` with HTTP 409. The accepted
answer records the Human's UID and name, adds their message, and wakes the
Agent that asked. The card offers direct choice and text answers. The Human can
also select its composer answer action to add references or files. The composer
shows the question and fixes the recipient to its Agent. Exiting this context
keeps the draft. Ordinary composer messages use the room's normal delivery rules.
Page references, quoted messages, Human mentions, exact text, and uploaded files
remain on the accepted Human message. A file can be the complete answer. The
answer uses that Human's WorkAccess identity. An unresolved question outside the loaded message window
appears at the timeline's attention area. Loading its original message restores
its historical position without a duplicate card.

The Conversations domain owns answer acceptance, its transaction, and publication
after commit. The browser action validates the transport fields and projects the
returned detail. Chat inputs share one typed Page and message-reference contract.

Reply completion derives `rich_content.execution` from the persisted model
turn journal and tool results. It includes the reasoning summary, ordered
steps, tool outcomes, and recorded durations. PostgreSQL keeps this history
with the reply. `execution.status` identifies completed, stopped, and failed
work. A stopped or failed native turn stores its execution in the existing
notice message. Completed tool results keep their recorded outcomes; a missing
or interrupted tool result has the turn's stopped or failed outcome.
The browser displays current work while it runs and collapses a completed turn
above its answer. Stopped and failed work stays open. Refresh reads the same
stored steps. Live steps use the Activity protocol's phase. Persisted program
steps read their code and result from the turn journal. Generating a paired tool
call does not complete its execution; a recorded result determines its outcome.
Linked Background Agent Jobs and Workflow runs use their owning domains'
records and results in inline cards and a read-only details panel.
Linked execution metadata includes `sourceMessageID` from the source Signal's
native Message reference. A silent turn attaches its linked executions to that
triggering Message.

## Agent Lifecycle and Scope

Disabling an Agent preserves its room and history. The Agent cannot accept
new work. A group can continue with its other participants. The browser shows
a status banner and lets the Human manage or select other Agents.

Permanent Agent deletion removes its `dm` rooms. A `group` room keeps its
messages and removes only that Agent's Session, Signals, and participation.
The historical display name and Session ID keep its messages readable with an
archived author label. Principal and Signal references can independently become
null under their foreign keys. The source Signal foreign key checks at commit.

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

The room creator or tenant administrator can delete a group. Another Human can
leave through the participant action. Deletion locks all Agent slots and the
Conversation. Active work requires `forceStop`; the operation stops it before
removing room records. Saved Pages keep their own lifecycle. A saved Page
reports a deleted source only when its source message is absent.

Cron reports and notices can target a native room through its UUID. Each
participating Agent reads those committed statements on its next request;
the cron rule keeps a separate model history.

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

A native room detail read uses one read-only, repeatable snapshot. It reads a
bounded history window and the messages that contain links, attachments, or
visible saved Pages. The latest Human input is a separate bounded lookup.

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
It owns reply eligibility, owner generation changes, the atomic transfer between
old and new owners, and the comparison of durable presentation revisions. A
transfer keeps an invisible old surface free of a continued presentation. A
rejected transfer rolls back both owners. A stopped preview can store a newer
presentation only for its current generation.
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
