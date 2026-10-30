# Conversations

`Ankole.Conversations` owns shared conversations, room participation, and public
message records. A native conversation is a shared room for Humans and Agents
hosted directly by Ankole, whereas an external conversation is hosted on an
external messaging platform. Within either kind of room, each participating
Agent observes and speaks through its own execution Session.

Participants read the conversation as one shared transcript, while each Agent
runs its work independently through `Ankole.Sessions`. Separately, AIGateway
owns model Responses and model conversation state; model output enters public
conversation history only when the control plane commits a message.

## Owners and Stored Facts

| Owner | Contract |
| --- | --- |
| `Ankole.Conversations` | Conversation creation, participation, access checks, messages, and committed conversation events |
| `Ankole.Signals` | Acceptance of input with its source, source event ID, type, subject, data, explicit target, and sender |
| `Ankole.Sessions` | Ordered execution, admission, steering, retry, recovery, and completion |
| AIGateway | Model Responses, live model events, and model conversation history |
| Principal and AuthZ | Human and Agent identity, tenant ownership, and work authorization |

`Ankole.Conversations` persists public state across four tenant-scoped tables:

| Table | Stored facts |
| --- | --- |
| `conversations` | Public UUID, kind, room mode, access scope, optional Page, custom title, per-Agent model preferences, activity, sequence high water, external platform identity, and standing orders |
| `conversation_participants` | Conversation, Principal, role, Agent intervention setting, and personal pin, mute, and read position |
| `conversation_messages` | Public UUID, conversation, sequence, author name snapshot, kind, exact text, attachments, mentions, links, structured content, delivery key, reply reference, and execution provenance |
| `external_message_refs` | Platform message/thread/reply IDs, raw author, metadata, reactions, content hash, and observation times for an external Message |

Every table carries a `tenant_id` foreign key, includes `tenant_id` in all
primary and unique keys, and participates in tenant deletion.

`Ankole.Conversations` is the Ash domain for these four tables as well as the
inbound batch, input tombstone, Delivery intent, and preview state resources. It
defines one code-interface function per resource read or write action; callers
in other domains, web controllers, and plugins must go through those functions
rather than querying Ecto or `Ash.Query` directly.

Every multi-step entry point opens a top-level transaction through
`Repo.transact_top_level/2` (including `create`, `post`, `observe_entry`,
`claim_intent_dispatch`, and `PreviewStates.put_checkpoint`), acquires locks in
the global work lock order, and publishes events after commit. Calling a
top-level entry point inside an already open transaction raises
`Ankole.Errors.Framework.NestedOperation`; callers that already own a
transaction must invoke the corresponding `_in_tx` helper instead (such as
`create_in_tx/2`, `post_in_tx/3`, `detail_in_tx/3`, or
`Attachments.link_payload_in_tx/3`).

Cross-domain reads go through the owning domains' code interfaces. When locking
Principal or Signal rows, Conversations calls `Principals.lock_principals_in_tx/1`
and `Signals.lock_signals_in_tx/2`, which register every locked read with
`Ankole.LockOrder`; conversely, other domains lock a Conversation row through
`Conversations.lock_conversation_in_tx/2`. Queries filter on related rows using
resource-backed `exists` expressions rather than declaring Ash relationships,
keeping underlying Ecto structs unchanged. When one of a Message's native inputs
is removed, Ankole marks that Message `withdrawn` and excludes it from history,
model context, and detail reads.

Idempotency and monotonic sequences protect stored conversation history:

- Retrying a participant addition preserves the initial role, and retrying
  native room creation never overwrites stored fields. External observation
  updates may refresh message text and observation metadata, but never alter the
  platform identity or the initial observation timestamp.
- Each message receives a unique `seq` within its conversation. Before advancing
  a conversation's high-water sequence counter in PostgreSQL, writers lock the
  `conversations` row so stale snapshots cannot overwrite the counter, and
  deleting the latest message never reuses its sequence number. A reply
  reference must point to a message in the same tenant and conversation.
- Human messages carry no execution provenance, whereas Agent replies record the
  execution `session_id`, source `signal_id`, and `delivery_key` under a unique
  `(conversation, signal, delivery_key)` constraint. One Signal can therefore
  commit both a Clarify question and a final reply without duplicating either
  message on retry.
- Native messages snapshot a non-empty `author_display_name`. If an Agent is
  later deleted, foreign keys can null out its author UID and Signal reference
  independently while the recorded display name and Session ID keep group
  history legible. PostgreSQL check constraints verify Human provenance and
  Agent Session identity on every statement, and inserting an Agent message
  additionally requires an active Agent author and a valid source Signal.

## Native Room Access and Participants

A native room starts in `room_mode: dm` when created for one Human and one
Agent. Adding a second Human or Agent promotes the room to `group` permanently;
a `group` room never reverts to `dm`.

Room visibility follows `native_access_scope`:

- **`participants`** restricts access to explicit active room participants.
- **`anchor_page`** binds the room to a Pod Page and requires live `page_view`
  permission on that Page. Any Human who currently holds `page_view` can read
  the thread and post to join it (the first accepted message adds that Human as
  a participant in the same transaction). Every access check evaluates live Page
  and Principal state, so trashing or revoking access to the Page revokes room
  access immediately.

In the UI, the global Chat list shows only rooms where the current Human has a
participant row (and still holds Page access if the room uses `anchor_page`
scope). By contrast, a Page's own Chat list surfaces all shared rooms anchored
to that Page even before the viewer joins; unjoined viewers see no unread badge.

Room members, the room creator, Pod administrators, and managers of an anchor
Page can rename the room or invite participants, though changing an Agent's
intervention setting additionally requires `chat` permission on that Agent. The
participant action admits active Humans in the same tenant and Agents that the
caller may invoke, recording membership, title, and visibility changes as
compact `notice` messages carrying `rich_content.event`.

A Page viewer who has not joined a shared room can still save personal pin,
mute, and read preferences as an `observer`. Observers have no access when a
room uses `participants` scope and are omitted from both the member list and the
`dm`-versus-`group` participant count; sending a message or receiving an
explicit invitation promotes an observer to a full member. Each Human manages
their own pin state, mute state, and monotonic `last_read_seq`, while an Agent's
`may_intervene` flag controls whether that Agent receives unaddressed group
messages.

In group rooms, members can set or clear room-wide standing orders via the
`set_channel_standing_orders` tool (native `dm` rooms omit this tool). The room
stores the full policy text together with the Principal who set it, scoping its
effect to that room and each Agent's own permissions. An Agent with
`may_intervene: true` receives standing orders on both explicitly addressed and
ambient listening turns, and the tool response indicates whether the policy is
currently active for the calling Agent.

## External Message Batching

`Conversations.InboundBatches` implements one shared inbound batching policy
across all external IM adapters, scoping each batch by `(tenant, Agent, binding,
conversation, thread)`. Whether a newly observed message extends an open batch
depends on requester continuity, and the batch deadline commits in the same
transaction as its scheduled finalization job (if that job wakes early, it
reschedules itself for the persisted deadline). Under this boundary, IM adapters
handle wire protocols and platform identity mapping, `Conversations` manages
batching windows and source tombstones, and `Signals` accepts the finalized
input, so adding a new IM adapter never duplicates batching or crash-recovery
logic.

Once an outer intake transaction commits (whether for an immediate input, a
scheduled batch finalization, or an earlier batch finalized by a newer arrival),
it calls `Signals.publish_committed/1` to broadcast Session notifications and
wake ready Drivers, backed by a durable Driver wakeup job committed in the same
transaction.

`InboundBatch` resource actions govern transitions across `open`, `finalized`,
and `canceled`: only an `open` batch may mutate, every revision or terminal
transition increments the revision counter atomically (with PostgreSQL rejecting
negative revisions), and the stored deadline drives job scheduling rather than
defining batch status. Removing an external source message writes or refreshes
one shared tombstone via its resource action, and tombstone cleanup deletes only
rows past their persisted expiry.

For message edits and attachment arrivals, `Conversations.MessageInput` is a
pure calculation module (performing no database writes) that computes updated
source entries, text summaries, ambient batch facts, and deadlines for
attachment supplements. Both `Conversations.InputRevisions` (which handles
queued edits and intake revisions) and `Sessions.Revisions` (which handles
in-flight turn cancellation, retained side effects, and recovery) call
`MessageInput` inside their own transactions and locks. Inbound batching windows
and attachment-supplement waits remain distinct policies, and non-message Signal
sources bypass both.

## Accept a Human Message

Posting a native message requires room access for the authenticated Human plus
`chat` permission on `agent:<agent_uid>` for every addressed Agent (which must
be active in the Human's tenant).

Creating a room commits the `conversations` row, initial participants, the
opening Human message, and each addressed Agent's Signal and durable wakeup in
one transaction:

- Explicit `mentions` or `targetAgentUID` select the addressed Agents, and
  mentioning a non-member Agent that the Human has permission to invoke adds
  that Agent to the room in the same transaction.
- When no explicit target is supplied, a `dm` room addresses its active Agent,
  whereas a `group` room addresses only participating Agents with
  `may_intervene: true` (even if only one active Agent is in the room).
- If no Agent qualifies, Ankole still commits the Human message for human
  participants. An Agent woken via `may_intervene` may finish silently when it
  has nothing useful to add, whereas an explicitly addressed Agent follows the
  standard reply contract.

On a shared Page-anchored `dm` room, a Human with `page_view` can post a comment
even without `chat` permission on that room's Agent: the message adds the Human
as a participant, promotes the room to `group`, and creates no Agent Signal
unless the Human explicitly selects a permitted Agent target.

Only Human messages trigger this intake path; Agent replies and streamed output
never wake other Agents. Each addressed Agent receives a Signal routed to
`(agent_uid, "conversation:<conversation_id>")`, isolating queue admission,
steering, model-profile selection, and `Stop` commands per Agent slot (and
hiding queued-but-unadmitted inputs only from the Agent that owns that queue).

Subsequent Human posts commit the message alongside each addressed Agent's
Signal and wakeup job in one transaction using this CloudEvents envelope:

| Field | Value |
| --- | --- |
| Source | `conversation:<conversation_id>` |
| Source event ID | Human message ID |
| Type | `conversation.message.addressed` |
| Subject | Conversation ID |
| Target | Agent UID and execution session `conversation:<conversation_id>` |
| Sender | The authenticated Human UID |
| Data | Conversation ID, message IDs, author UID, model profile, exact message text, and trusted request IP |

`Ankole.Signals.accept_in_tx/1` inserts the `signals` row, assigns its
per-`(agent_uid, session_id)` queue sequence, and enqueues an `EnsureDriver`
job atomically (native conversations create neither Signal Bindings, external
references, nor Delivery intents). `WorkAccess` snapshots the Human's UID and
`access_version` on the Signal so execution admission can re-verify them at
start time. The Signal also records the trusted client IP in
`data.request_context` for downstream tool and Pod RPC condition checks; before
trusting that IP, the runtime verifies the Signal producer, native event type,
conversation source, and session key, and any derived background work inherits
the same Agent and `WorkAccess` identity (see [AuthZ](AuthZ.md)).

The browser generates client UUIDs for both conversations and messages:

- Retrying a request with identical UUIDs and payload fields (including
  canonical Page links, mentions, explicit Agent target, exact text, and
  attachments) idempotently returns the stored message and Signal, whereas
  reusing an ID with different fields fails with `conversation_conflict`.
- Once a native Conversation is deleted, its UUID is permanently retired by
  historical execution records and cannot be reused.
- Message text must be valid UTF-8 with no `NUL` bytes and at least one
  non-whitespace character; Ankole stores and compares the exact untrimmed text
  on retries. Unless `title_customized` is set by a manual rename, the room
  title defaults to the first non-empty line (up to 80 characters), and clearing
  a custom title restores that derived title.

Event publication happens strictly after PostgreSQL commits so rolled-back
transactions emit nothing. Top-level native `create`, `post`, and `queue`
operations return `publications` and `session_key`, and their `after_commit`
hook invokes `Conversations.Events.publish_committed/1` and emits a status
update via `Sessions.Events` (idempotent retries with no new publications emit
neither, while `EnsureDriver` guarantees crash recovery). Callers using
`create_in_tx/2` or `post_in_tx/3` inside a broader transaction must return
those publication structs to their outer transaction owner for post-commit
publishing: the publication guard rejects calls made inside an active process
transaction, and spawning an async `Task` inside a transaction is forbidden
because a new process lacks the caller's uncommitted transaction state and could
publish before commit.

If a tenant is suspended while an earlier admitted turn is still running,
admission can reject a queued follow-up without interrupting the active turn,
committing the rejection notice and completed follow-up Signal together before
notifying open browser tabs.

## Execute and Commit the Reply

Once admitted into the main `Sessions` loop, `Prompt.Input` reads the Human's
message text, and subsequent messages from the same Human can steer the active
Run.

When the turn finishes, `Sessions.Presentation` appends the visible Agent reply
directly inside the completion transaction without creating an external Delivery
intent; silent turns write no message, and `Notices` writes an immutable Agent-authored
notice whenever an input enters `dead_letter`.

The composite `(conversation, signal_id, delivery_key)` uniqueness constraint
prevents duplicate Agent messages if completion retries, though an upstream LLM
call interrupted before recording its journal can still re-execute during crash
recovery. Native conversation Sessions are exempt from the daily `04:30` model
conversation reset, and browser refreshes or reconnects always load the visible
transcript from `Ankole.Conversations` rather than AIGateway model history.

## Pod Browser API

The Pod browser API is mounted at `/api/v2/pod` behind the same session gate as
the Pod HTML shell: instance setup must be complete, the browser must present a
valid Human proof for the target Pod, and mutating requests must pass CSRF
validation. Request and response schemas are declared on Ash actions (generic
actions wrap inputs in `data` over `application/vnd.api+json`), exported to
`pod-v2.json` via `AnkoleWeb.JSONAPI.PodRouter.spec/0` (`mix ankole.openapi.check`
verifies and `--write` updates the spec), and compiled into TypeScript clients
by the webapps `openapi:generate` script. File transfers, Applet HTTP endpoints,
and SSE streams use their native transports.

Every Pod request derives its tenant from the authenticated Pod proof (switching
the selected data tenant in the Console never alters a Pod tab's tenant) and
enforces current Human status, room access scope, and guest admission under
`pod.allow_external_guests`. Both the Agent directory and model-profile lookups
expose only active Agents on which the Human holds `chat` permission.

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

Room detail responses list linked background executions as compact summaries
(ID, title, status, and timestamps). Calling
`GET /conversations/:id/executions/:kind/:run_id` accepts `background_agent_job`
or `workflow` plus a `ModelIntegerID`, verifies current room access and Session
ownership on every page, paginates Background Jobs with the Console turn cursor
and Workflows in call-sequence order, and returns public assistant text, tool
calls, results, and errors while omitting hidden system context and raw workflow
trigger arguments.

Room detail also exposes two room-wide views that apply the same access and
browser projection rules as timeline messages: `artifacts` lists visible saved
Page IDs and attachment groups (keyed by source Message ID across all
non-withdrawn messages up to the room's sequence high water, regardless of the
loaded timeline slice), and `pendingInteractions` lists each Agent's latest open
Clarify question and durable checkpoint state.

When a native Conversation is associated with a Pod Page via `page_id`, it can
be kept private to explicit participants or shared with Page viewers via
`anchor_page` scope; both the embedded Page Chat panel and the full-screen Chat
view render the same room and transcript, and deleting the Page or revoking
`page_view` immediately revokes `anchor_page` access.

Tool calls and Pod writes triggered by a message evaluate the addressing Human's
live permissions intersected with the Agent's permissions (preserving that same
`WorkAccess` identity across child tasks and requiring a fresh Page read before
mutating Page content); another participant's broader permissions never widen
access for that turn. In Pod rooms, generated documents and research reports
default to editable Pod Pages unless the user explicitly asks for a downloadable
file format, whereas external channels follow their own file-delivery rules.

In the browser, the open Pod document holds unsent drafts and pending client
UUIDs in memory across panel toggles, room switches, and Page navigation,
warning before tab close or reload whenever unsent work remains:

- Once the server acknowledges a new room, the client binds the draft to that
  saved Conversation; retrying an unconfirmed send with the same text and Agent
  reuses the original client UUIDs.
- If a user loses Page access while typing, the error screen lets them copy only
  their locally typed draft text without exposing any saved Page or room history.

Each projected message carries `id`, `seq`, `authorType` (`human` or `agent`),
`authorUID`, `authorDisplayName`, `authorArchived`, `kind` (`message` or
`notice`), `text`, `richContent`, `mentions` (Principal type, UID, and snapshot
`displayName`), `links`, `savedPages`, ISO 8601 `createdAt`, `signalID` (`null`
for Human messages), and `replyToMessageID`.

Each entry in `pendingQueues` reports one Agent's queued inputs, queue version,
pause flag, retry capability, and durable `workStatus` (`{state, retryAt}` where
`state` is `idle`, `queued`, `running`, or `retrying`, and `retryAt` is non-null
only for scheduled retries). `Sessions` computes `workStatus` from its durable
inbox by prioritizing ready admitted work ahead of queued inputs, and queued
inputs ahead of future retries (so a delayed retry never masks newer runnable
work). Paused unadmitted inputs do not count as runnable work: a room containing
only paused inputs reports `idle`, while releasing a single item via Steer moves
the Agent to `queued` or `running` without unpausing the rest of the queue.

`Conversations.get/3` reads the message window, pending queues, queue versions,
retry flags, durable Session statuses, member Principals, queued Message links,
pending Clarify checkpoints, and linked executions inside one transaction under
the Session advisory locks. Because Signal intake, admission, and reply commits
acquire those same locks, a detail read can never pair pre-reply messages with a
post-reply `idle` status. Browser serialization performs zero additional SQL
queries; room list endpoints batch-load work statuses, pending interactions, and
linked executions across rooms; and live tool-step activity remains an
independent transient stream that may sit slightly ahead of the last database
read.

Domain errors use the `{error: {code, message, details}}` envelope:

| HTTP status | Codes |
| --- | --- |
| 422 | `invalid_request`, `invalid_id`, `invalid_text`, `invalid_choice`, `participant_unavailable`, `cannot_remove_last_participant`, `anchor_page_required`, `invalid_execution_cursor` |
| 403 | `page_unavailable`, `forbidden`, `forbidden_room_operation` |
| 404 | `conversation_not_found`, `execution_not_found` |
| 409 | `agent_unavailable`, `conversation_conflict`, `conversation_busy`, `queue_changed`, `input_already_started`, `reply_unavailable`, `interaction_not_pending`, `requires_queue_for_profile` |

Missing or inactive session proofs return HTTP 401 (`unauthorized`), and unsafe
requests without valid CSRF proof are rejected before reaching domain actions.

## Pod Chat Workspace

Chat Home centers a greeting, Agent selector, and spacious composer with starter
prompts (shown while the draft is empty) above recent rooms, while the left
sidebar organizes pinned rooms, date-grouped threads, title and message search,
and badges for active work, pending Clarify questions, background tasks, and
unread messages. Committed room events and native Session transitions notify
open Pod tabs, coalescing sidebar refreshes over a 1,500 ms window and
re-evaluating participant and Page permissions on every refresh.

Inside a room, the header exposes inline title editing, participant controls,
share-link copy, and Markdown export, while keyboard shortcuts toggle in-room
search and the summary drawer:

- **Summary drawer:** lists participating Agents (with active models and
  per-Agent `may_intervene` toggles in group rooms; direct rooms always address
  their Agent) and Humans (using Principal avatars with initials fallbacks),
  plus room-wide referenced/saved Pages, attachment previews/downloads, and
  background executions regardless of how far back the timeline has scrolled.
- **In-room search:** pages backward through the message cache, flags partial
  results while loading or if a page fetch fails, halts pagination as soon as
  search closes, and highlights matches via browser text ranges without mutating
  message DOM nodes (updating highlights when a user expands collapsed tool
  output).

All surfaces, code blocks, selections, status pills, and composer focus rings
use semantic tokens from the shared Ankole UI kit across light and dark themes.
A reply's code blocks, inline code, and tables take the same forms as a
document's, because a reply can be saved as a page: 13 px source under a 32 px
toolbar on a light fill, and 14 px table cells on a hairline grid. Pickers, the
find bar, turn previews, and the jump to the latest message float over the
conversation as ceramic, and renaming a conversation edits its title where it
stands.
Messages and the composer share one 760 px column. Message text is 15 px on a
24 px line; names, work summaries, tool rows, and reply sources are 13 px. A
Human's message is a neutral ink-tinted bubble, aligned right for the viewer
and left for other Humans, and an Agent's reply is plain text on the page. The
viewer's own messages carry no name or avatar, and a message from the same
author within five minutes of the previous one continues it without repeating
them; in both cases the time appears on hover and the name stays available to
assistive technology. A finished turn's model appears in the tooltip of its
work summary. The composer is a paper writing surface whose edge darkens while
it has focus.

Each state of a turn has its own mark, so the person can tell at a glance
whether an Agent is working, needs them, or has stopped. In the sidebar, an
unread room shows a blue dot, a room that waits on a decision shows an amber dot
with a halo, and a room where an Agent is working or a background run is active
shows a turning neutral ring. While an Agent writes, a caret follows its last
words, and the composer offers a labelled Stop button next to Send. A turn that
fails reads "Failed after …" in the destructive colour with the failing step
marked, a stopped turn reads "Stopped after …", and a retryable turn offers a
labelled Retry reply action. A pending decision card has an amber edge and
heading, and its question and choices use the message type scale. Queued
messages offer a labelled Steer action, and a background run card counts its
time in minutes and hours once it runs past a minute.

In the timeline, compact event notices sit alongside attributed messages:

- Live turn previews track their triggering `sourceMessageID`, and interleaved
  replies link back to the question they answer and restore scroll focus there.
- Markdown rendering supports syntax-highlighted code, tables, math formulas,
  Page chips, and image lightboxes. Code text updates immediately while syntax
  highlighting waits for 150 ms of quiet; a highlighted result appears only for
  the exact text and language that produced it. Plain-text blocks use the native
  code presentation without loading the highlighter.
- While a turn runs, the active step stays visible above collapsed prior steps
  and reasoning; once the reply commits, the entire execution trace collapses
  above the answer, whereas stopped or failed turns keep their recorded steps
  expanded (including command strings, stdout/stderr, and exit codes when
  recorded).
- Linked Background Agent Jobs and Workflows appear once inside the live turn
  and then attach to the committed reply, opening paged read-only execution logs
  within the room's access boundary.
- Message actions support copying, quoting, eligible edits, Agent retries, and
  **Save to Pod** (displaying saved Pages as links beneath the source message).
  Saving a text message loads the document parser when the user submits the
  save dialog.

In the composer, users can combine `@` Agent and Human mentions, Page
references, `/` commands, file attachments, and per-Agent model-profile
overrides:

- **Input and completion:** IME composition Enter never submits a message.
  The textarea uses native `field-sizing: content` within its height limits;
  browsers without that capability use the measured-height fallback.
  Autocomplete popovers keep focus inside the textarea, respond to arrow keys,
  `Tab`, `Enter`, and `Escape`, and match multi-word names and Page titles.
  Selecting a completion restores the caret as React commits the updated
  input, before the user can type into the completed text.
  Removing a named Page-reference chip deletes only that structured reference
  while leaving surrounding prose untouched.
- **References and permissions:** Quoted messages and Page chips travel as
  structured message links into model context, though Agent tools still enforce
  live permissions when reading referenced Pages. Users without `chat`
  permission on an Agent can read its Clarify card but cannot submit an answer;
  sending, answering, and retrying all require an active, callable target Agent
  (edits retain their saved target Agent, and Clarify answers target the asking
  Agent).
- **Queue management:** Newly sent messages enter the target Agent's bounded,
  scrollable queue with single-line previews and controls to reorder, **Steer**
  into the active turn, edit, delete, or **Continue** a paused queue. **Take
  back** pulls a queued item's text, attachments, Page links, and Human mentions
  back into the composer (targeting that Agent's queue when the composer was
  empty without re-addressing other Agents, or appending when a draft already
  exists). In a single-Human room, unadmitted queued items appear only in the
  queue tray until a subsequent Agent reply commits (after which they appear in
  the timeline with a queued badge); in multi-Human rooms, queued items appear
  in the timeline immediately so teammates can see them.
- **Editing and conflict handling:** Only one composer edit is active at a time
  until saved or canceled, and `ArrowUp` in an empty composer opens the Human's
  latest editable queued item or latest eligible timeline message. A queued
  message addressed to multiple Agents remains editable only before any target
  Agent admits it (updating text, links, and Human mentions while keeping Agent
  targets fixed; once admitted or completed, multi-Agent messages require a new
  correction message). Saving checks the Agent's queue comparison token: on
  conflict, the composer keeps the local draft while letting the user inspect
  and explicitly load the server version (including reference-only changes).

Embedded Page Chat renders the exact same room inside a resizable side panel
with Page context controls, `participants`-versus-`anchor_page` scope switching,
and a link to open the full Chat workspace.

Asking an Agent about selected Page text goes through Page Chat. Selecting text
in a document and choosing `Ask Agent` in the selection toolbar opens Page Chat
(the open conversation, or the Page's latest one), quotes the selection in the
composer, and focuses it. The quote travels as a `{ kind: "page", id, quote }`
message link, so the Agent receives it as referenced user context and locates
the passage with a fresh Page read before editing. A draft quotes one passage at
a time: a quoted message and a Page selection replace each other. Choosing the
action changes nothing in the document and needs only access to Page Chat, not
edit permission.

## SSE and Visible History

`GET /conversations/:id/events` verifies room access before subscribing to
tenant-scoped Conversation, Agent Session, and AIGateway PubSub topics, always
subscribing before reading initial Driver snapshots so no delta falls between
the snapshot and stream start. Dynamic room participant changes update the
connection's Agent subscriptions live, and whenever an Agent switches model
conversations, the stream re-subscribes and emits any active display snapshot.

Before writing every business frame and every 15-second heartbeat (and
immediately upon any Page-permission broadcast), the stream re-verifies Human
status and room access. If access has been revoked, the server drops buffered
deltas, emits `access_revoked`, and closes the stream; the browser purges cached
room history and either shows locally typed drafts in the recovery screen or
returns to Chat Home.

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

Per-Agent 40 ms buffers coalesce `delta` and `reasoning_delta` chunks, flushing
immediately before any control frame and never mixing output from different
Agents. `ResponseStream` owns the live text and thinking snapshot, which the
Session Driver combines with persisted thinking summaries from earlier rounds of
the same turn: each `snapshot` carries a sequence watermark `seq` so buffered
events at or below `seq` are ignored, and new connections replace an Agent's
in-progress display before appending subsequent deltas. All streamed frames are
ephemeral views; only committed `conversation_messages` form durable history.

An `activity` frame carries `{conversationID, agentUID, sessionID, signalID,
responseID, epoch, revision, state, phase, tools}`, where `state` is `active`,
`unavailable`, or `settled`. Rather than creating a second execution state
machine, `activity` provides a bounded UI observation: `phase` stays distinct
from reasoning text (and stays visible alongside live text streaming until
`unavailable` or `settled` clears it), while `tools` lists ordered steps in the
current turn with bounded labels and durations (omitting raw arguments and
outputs). On connect, the stream verifies the workspace `epoch` and open Signal,
monitors the Driver, and sends the initial snapshot so late joiners see
Worker-capacity waits immediately. Monotonic `(epoch, revision)` checks drop
out-of-order frames and prevent settled epochs from reopening; Driver crashes,
retries, or SSE disconnects clear transient activity details back to durable
`workStatus` until a fresh connection receives a new snapshot; and `activity`
frames never trigger a full room reload.

`Conversations.Events` broadcasts public message commits, room deletions, and
Agent availability changes, while `Sessions.Events` broadcasts Signal intake,
queue edits, admissions, retries, and terminal turn completions (`turn_completed`
replaces a separate status broadcast on commit). Both map to the SSE
`conversation` event (note that on external channels, `turn_completed` proves
only that Delivery intents committed; public external messages appear once the
IM provider confirms delivery).

Every live Response frame carries `signalIDs` (drawn from the primary Signal and
steered Signals recorded in `session_round_states`, never guessed from cached
message sequences) plus `responseID` (isolating concurrent or retried model
Responses). When a committed Agent message arrives with matching `signalID`, or
when durable `workStatus` settles that Response silently, the browser swaps out
or clears the live preview. Because SSE never replays pre-subscription chunks, a
reconnecting client that missed `started` still renders incoming `delta` frames
via their embedded identity fields and fetches the complete reply on the next
`conversation` detail read.

On every initial connect and every `conversation` frame, the browser triggers a
fresh detail read started strictly after that event. Neither an older in-flight
`GET` nor a delayed `POST` response may overwrite newer state, and the browser
retains unconfirmed client message IDs for retry until they appear in committed
history.

Queue mutations (`POST /conversations/:id/queue`) require `agentUID` (a missing
transport field returns HTTP 400 with a JSON:API `errors` entry identifying that
field before domain code runs) and check the Agent's queue comparison token
under the Session lock; replaying an already committed retry command ID is
idempotent and neither duplicates the Signal nor re-snapshots model preferences:

- **`Stop`** cancels the active reply and pauses unadmitted queued inputs
  (including unapplied steers); even if no turn is currently running, `Stop`
  consumes the command and leaves the queue paused across page refreshes until
  **Continue** resumes the queue or **Steer** releases one specific item.
- **Stale queue edits** keep the user's draft; refreshing adopts the new
  comparison token automatically only when the server's saved text still matches
  the baseline, requiring an explicit user choice otherwise.
- **Last-turn edit and retry** delegate to `Commands` and `ModelHistory`:
  editing a single-target Human message reuses its persisted Signal target
  regardless of the current composer selector (whereas Human-only or
  multi-target messages require posting a correction), and **Retry** appears on
  the latest eligible failed reply (`Stop` and preflight notices are not
  retryable), capturing the room's current model preference while keeping
  already committed Pod Page, Base, and Applet writes intact. Native edits,
  regenerations, and logical queue removals invoke the message-change hook in
  the same transaction (expiring derived Brain Facts and rewinding the Brain
  learning cursor) while keeping removed message UUIDs reserved for idempotency
  and filtering them out of timeline reads, model context, and Brain extraction.

Timeline history reads return up to 500 visible messages alongside an
earlier-page cursor and the exact covered `seq` interval, letting the browser
splice older pages into its local cache without dropping newer messages or
resurrecting withdrawn ones.

## Clarify and Execution History

When an Agent calls Clarify in a native room, completion commits an Agent
message with `delivery_key: "clarify:<tool_call_id>"` whose
`rich_content.clarify` stores the prompt, choices, free-text flag, and
interaction ID, while reading mutable status (`pending`, `answered`, or
`superseded`) from the Delivery interaction checkpoint. If the turn produced
introductory prose alongside Clarify, the prose message commits before the
question and carries `rich_content.execution` (otherwise the Clarify message
carries it), clearing the Agent's live stream.

Submitting an answer (`POST .../interactions/:interaction_id/answer`) locks the
checkpoint inside a `Conversations` transaction so only the first answer to a
`pending` question commits (concurrent or late submissions receive HTTP 409
`interaction_not_pending`), recording the answering Human's UID, display name,
and `WorkAccess` identity, appending their reply message, waking the asking
Agent, and publishing after commit. Users can click a choice or type a quick
reply directly on the card, or open the question in the composer (which pins the
asking Agent as recipient and preserves drafts if dismissed) to attach files,
Page chips, quotes, or Human mentions; an attachment alone is a valid answer. If
an unanswered question sits above the loaded 500-message window, the UI surfaces
it in the timeline's attention banner and smoothly restores it to its inline
position once the user scrolls back to that message.

On turn completion, `Sessions.Presentation` builds `rich_content.execution` from
the durable turn journal and tool results, recording the reasoning summary,
ordered steps, tool outcomes, code-execution source/output, and durations
directly on the Agent reply. `execution.status` identifies completed, stopped,
and failed work; on a stopped or failed native turn, `Presentation` stores the
execution record on the turn's notice message and marks any missing or
interrupted tool results with that terminal turn outcome (merely emitting a tool
call never counts as tool completion without a recorded result).
Linked Background Agent Jobs and Workflows carry `sourceMessageID` from the
triggering Signal (attaching directly to that Human message on silent turns) and
render as inline cards backed by a read-only detail drawer.

## Agent Lifecycle and Scope

Disabling an Agent preserves all of its rooms and transcripts while blocking new
work: group rooms continue operating with remaining participants, and the Pod UI
displays a status banner so users can switch to or invite another Agent.
Permanently deleting an Agent deletes its `dm` rooms, whereas `group` rooms keep
their message history: Ankole removes only the deleted Agent's Session, Signals,
and participant row, nulls Principal and Signal foreign keys independently, and
displays historical messages under the snapshotted `author_display_name` with an
archived badge.

Native chat file uploads stage bytes through `Conversations.Attachments` and
`Files`, issuing a signed upload receipt bound to `(tenant, Human, client file
ID, SHA-256 digest, filename, size, content_type)`:

- Posting a Message verifies and binds those receipts in the same transaction;
  unused receipts expire after 24 hours (while idempotent retries of an already
  accepted Message remain valid, and unreferenced blobs follow the standard
  file-collection grace period). Uploading a chat attachment never auto-creates
  a Pod Page unless a user clicks **Save to Pod**.
- Only when an Agent admits an input from its queue does the runtime link
  accepted attachments into that Agent's drive (normalizing image inputs for
  vision). Browser downloads stream the Message's immutable blob digest gated by
  current room access, so subsequent edits in an Agent's drive never alter the
  chat download, and browser refreshes restore committed Message attachments
  while warning before discarding unsent local `File` selections.
- Outbound native Agent attachments (`reply_attachment` and hosted
  `image_generation`) apply the exact same validation and drive-confinement
  checks as external Delivery, retaining blob digests on the Message so **Save
  to Pod** references the same blob without copying bytes, and rendering
  attachment-only replies as visible messages. Inline `ankole:page/<page ID>`
  URIs are persisted as `{kind: "page", id}` message links whose targets still
  check `page_view` on read.

Either the room creator or a tenant administrator can delete a group room (other
Humans leave via the participant endpoint). Room deletion locks every
participating Agent's slot alongside the Conversation row, requiring
`forceStop: true` to stop active turns before deleting room records while
leaving saved Pod Pages intact (which show a deleted-source label
only once the source message row is gone). Scheduled cron deliveries and notices
can also post into a native room by UUID; participating Agents see those
committed messages on their next turn while the cron schedule keeps its own
isolated model history.

## Observe an External Conversation

External conversations are keyed uniquely by `(tenant_id, provider_conversation_id)`
using adapter-namespaced IDs such as `lark:oc_xxx`, storing neither an owning
Agent nor a Binding on the `conversations` row itself (Agents and Bindings
identify only the observing ingress or outbound Delivery). Adapters that
discover channels out of band (such as directory syncs) register them through
`Conversations.observe_external_conversation/3`.

On inbound events, `Conversations.Observe` normalizes the platform payload,
evaluates Binding filters against platform IDs, resolves the shared Conversation
UUID, and upserts the public `conversation_messages` row plus its
`external_message_refs` record, while `Signals` separately accepts any addressed
stimulus into the target Agent's `conversation:<uuid>` Session:

- Multiple Agents observing the same platform message (or an outbound Agent
  Delivery followed by the platform's own echo webhook) converge on one shared
  Message UUID and `seq`. If a user replies to an earlier ignored-but-retained
  batch observation, `Observe` promotes that observation into a public Message
  before linking the reply.
- Unmapped external senders and attachment-only posts are stored with nullable
  Principal UIDs and text; platform sender IDs and emoji reactions are recorded
  as observations rather than Ankole execution authority.
- Replies to already observed messages link by public Message UUID, while
  replies to unseen history retain the raw platform parent ID on
  `external_message_refs`. Platform edits update content in place without
  changing the Message UUID or `seq` (ignoring out-of-order older edits), and
  platform recalls delete the public statement while writing a tenant- and
  Conversation-scoped deletion tombstone keyed by platform message ID that
  blocks late arrivals and queued replies across every Agent and Binding in that
  room (even if the originally observing Agent is later removed).

Whenever an external edit or recall mutates a public statement, the transaction
calls `message_changed_in_tx` to invalidate derived Brain claims and rewind
learning: edits, supplements, and recalls on explicit inputs trigger input
revisions, whereas edits to background room chatter do not interrupt unrelated
turns, and duplicate webhooks do not reset Brain watermarks. Public record
mutations never invoke `Sessions` runtime processes, with one database-only
exception: deleting a shared Message calls
`Sessions.AmbientCuration.message_removed_in_tx/1` in the same transaction to
clear ambient-judgment anchors atomically so PostgreSQL anchor invariants hold
(`Sessions.Key` is used purely as a stateless key formatter).

## Read Shared History and Learn It

Reading native room detail runs against a single repeatable read-only snapshot,
loading a bounded message window alongside artifact-bearing messages (links,
attachments, and visible saved Pages) plus a separate bounded lookup for the
viewer's latest Human message.

In an external room, every participating Agent maintains its own Session, model
Responses, visible-branch read watermark, and ambient-judgment history while
reading from the shared public `conversation_messages` table and standing
orders:

- Before each model request, the Session snapshots a bounded slice of unread
  Messages and persists `conversation_read.max_seq` plus the exact `message_ids`
  on the request, filtering out its own prior replies by matching both author
  Agent UID and Session ID so another Agent's messages remain visible even
  though both Sessions share the `conversation:<uuid>` key string.
- Replayed model history preserves the exact background statements and quotes
  captured on completed rounds. Editing a background Message mid-turn neither
  interrupts the active turn nor changes the Message's `seq` (so later turns do
  not re-ingest edited messages below `max_seq`).
- At the terminal commit check, if an explicit triggering Message was withdrawn,
  the turn aborts with `:signal_canceled`. If only a background Message recorded
  in this turn's `conversation_read.message_ids` (excluding explicit input IDs)
  was deleted on the platform, the check returns `:signal_context_canceled`: the
  turn suppresses its drafted reply and posts a `context_withdrawn` notice
  instead.

Brain extraction shares a single `Source` and audience per conversation keyed by
Message `seq`, so having multiple Agents in one room never causes duplicate
claim extraction; editing or deleting an already learned statement rewinds that
Source watermark and withdraws its tracked claims before re-extracting. By
contrast, each Agent tracks its own ambient-curation progress independently via
`judged_until` in `session_ambient_judgments` with no shared cursor on
`conversations`.

## Deliver a Statement

`Conversations.post_in_tx/2` commits outbound Agent output to a validated
`Conversations.Target` (carrying target kind, Conversation UUID, optional
Binding and thread, and `primary` flag; `Target.for_reply/2` resolves turn reply
routes, while `for_delivery_in_tx/2` validates cron targets and Agent
membership, forbidding Bindings and threads on native targets and requiring a
Binding on external targets). Given a `Conversations.Statement` describing a reply or
notice, `post_in_tx/2` runs under the caller's Session lock, commits either a
native `conversation_messages` row or an external `deliveries` intent (using the
shared attachment contract, with only the `primary` target driving streaming
preview finalization and interactive Clarify cards), and returns a
`Conversations.PostResult` (`{messages, intents}`) whose messages the caller
publishes after commit.

For external platforms, `Conversations.Delivery` exposes the public
commit/dispatch/requeue interface over four internal modules:

- **`Delivery.Dispatch`** claims and sends pending intents.
- **`Delivery.Recovery`** classifies retries and ambiguous outcomes.
- **`Delivery.Mirror`** records provider-confirmed public `conversation_messages`.
- **`Delivery.Queries`** serves surface lookups and stopped-delivery views
  (`Delivery.sent_provider_message?/4` lets inbound adapters check whether a
  quoted platform message was sent by a local Binding). Turn completion and
  external delivery completion remain distinct durable facts.

| Status | Meaning |
| --- | --- |
| `pending` | Durable and awaiting delivery; a recorded send-start timestamp can indicate an in-flight attempt |
| `sent` | Provider success and canonical public statement were committed together |
| `failed` | A known failure; its reason and retry policy determine whether it can retry |
| `expired` | Expired before sending; the provider is not called |
| `unknown` | The send cannot be confirmed; automatic resend stops |

When a delivery stops in `failed` or `unknown`, PostgreSQL requires paired
`recovery_status` (`blocked`, `permanent`, or `exhausted`) and `recovery_reason`
columns (and forbids both on other statuses), while `possible_duplicate` and
`possible_duplicate_notice` track uncertain prior sends and their user-visible
warning. Adapter-specific continuation tokens (such as Feishu CardKit card IDs
and streaming cursors, or LINE's typed duplicate-retry gate) live in
`recovery_state`, where a PostgreSQL check constraint forbids control-plane
recovery keys and preserves adapter anchors across retries and requeues.

`Delivery.Intent` enforces all state transitions through optimistic Ash actions
that match both the stored `status` and `attempt_count` (making commit retries
idempotent and preventing stale workers from claiming extra attempts or
overwriting newer outcomes):

- Before calling the external API, `Dispatch` records the send-start timestamp
  and atomically increments `attempt_count`. If the process crashes or times out
  mid-call, `Recovery` reconciles the claimed attempt when the adapter supports
  reconciliation or marks the row `unknown` to block blind automatic resends
  (even if the local `Mirror` transaction failed after the provider accepted the
  send).
- Known failures retry within a bounded budget, whereas unsupported platform
  operations fail immediately as `permanent`, and `sent` or `expired` intents
  are terminal.
- An operator can manually requeue a stopped or `unknown` intent: requeue
  preserves the row and audit trail, sets the attempt budget to
  `consumed_attempts + 1` rather than resetting `attempt_count` to zero, and
  attaches one possible-duplicate warning when retrying an `unknown` visible
  reply.
- Every confirmed message chunk records its real platform message ID (never
  inventing synthetic IDs; ambiguous provider ACKs stay `unknown` with sanitized
  diagnostics), exact sent text, and public Message UUID, while `failed` and
  `unknown` intents never fabricate public transcript rows and retain referenced
  attachment blobs even if the Agent's drive or Binding is later deleted.
- Immediately before calling an adapter, `Delivery` scrubs configured secrets of
  12 or more characters (skipping shorter strings to avoid false-positive text
  corruptions) and runs public error diagnostics through the same secret
  sanitizer.

On platforms that support live streaming cards, transient previews store their
fenced checkpoint, sequence high water, initial platform message ID, and
terminal presentation in `delivery_previews` keyed by `(tenant_id, signal_id)`
(cascading on Signal deletion and validating JSON shape and non-negative
sequences on the `Delivery.PreviewState` resource). `Delivery.PreviewStates`
executes every claim, generation handoff, checkpoint write, cleanup, and
fallback inside its own top-level transaction (locking the `signals` row before
the `delivery_previews` row) so the transient preview process itself never holds
database transactions open.

Generation handoffs update both old and new preview owners atomically (rolling
back both on conflict so an abandoned preview card never receives further text,
and allowing a stopped preview to record a newer presentation only within its
current generation), while `Delivery.ReplyPresentation` formats renderer-safe
content. Durable `Delivery` uses these checkpoints to finalize or recover the
in-place platform message without treating streamed drafts as committed model or
conversation history; native Pod rooms stream over SSE and never create
`delivery_previews` rows.

See [Signals](Signals.md) for intake and adapter contracts,
[Sessions](Sessions.md) for execution and recovery, [AIGateway](AIGateway.md)
for model state, [Browser Sessions](BrowserSessions.md) for authentication, and
[Human Offboarding](HumanOffboarding.md) for retained work authorization.
