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
| `conversation_participants` | Conversation, Principal, role, Agent intervention setting, and personal pin, mute, read position, and last visit |
| `conversation_messages` | Public UUID, conversation, sequence, author name snapshot, kind, exact text, mentions, links, structured content, delivery key, reply reference, and execution provenance |
| `message_attachments` | Ordered attachment descriptors, frozen `file_objects` references, and optional source node IDs |
| `delivery_attachments` | Ordered delivery descriptors and object references while delivery remains pending, failed, or unknown |
| `external_message_refs` | Platform message/thread/reply IDs, raw author, metadata, reactions, content hash, and observation times for an external Message |

Every table carries a `tenant_id` foreign key, includes `tenant_id` in all
primary and unique keys, and participates in tenant deletion.

Conversations creates a stable Drive conversation root in the same transaction
as each native or external conversation. The root owns conversation files and
provides the `source_node_id` for learned claims and timeline events. Its read
permissions follow the conversation membership through the Drive access graph.

`Ankole.Conversations` is the Ash domain for these tables as well as the
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
`Attachments.prepare_payload_in_tx/2`).

Cross-domain reads go through the owning domains' code interfaces. When locking
Principal or Signal rows, Conversations calls `Principals.lock_principals_in_tx/1`
and `Signals.lock_signals_in_tx/2`, which register every locked read with
`Ankole.LockOrder`; conversely, other domains lock a Conversation row through
`Conversations.lock_conversation_in_tx/2`. Queries filter on related rows using
resource-backed `exists` expressions. Message attachment projections load their
ordered relation rows. When one of a Message's native inputs
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

For an active Human member, Pod New Chat defaults to their personal assistant.
Bootstrap reads an existing assistant without creating one. On first send the
frontend ensures that assistant, then calls the ordinary Conversation create
and send path. If sending fails after creation, retry uses the same assistant
and message draft. Guests use their existing grants and AI-colleague choices.
The Chat sidebar combines existing IM conversations with callable AI colleagues
(`agent:<uid>` `chat`, which AI colleague creation grants to `all_humans` by
default and operators can narrow or revoke).
Each colleague opens at `/dm/<uid>`; the browser creates a room only on first send.

Mention candidates include the caller's existing assistant and its local
`ai`, `assistant`, `pa`, and translated assistant aliases. Shared content can
resolve another assistant's existing mention without adding it to search
candidates or granting permission to wake it. Shared attribution uses the
assistant's short name together with its owner's current display name;
historical message reads resolve that display from the current Principal.

A personal-assistant room is a private task owned by its Human. A colleague DM
binds `dm_human_uid` and `dm_colleague_uid` to one unique tenant-local pair.
Creation reuses that pair even when callers submit different room UUIDs. Both
columns reference their typed Principal records with `ON UPDATE CASCADE`;
deferred foreign-key checks let the parallel Principal cascade paths settle.
The migration binds the latest historical DM for each pair and leaves the other
historical rooms unbound. Only bound rooms use the colleague DM identity and
`/dm/<uid>` route. Unbound historical rooms keep their own titles and
`/conversations/<id>` routes. Explicit `room_mode: group` creates an independent
room, even when the same people already share another group.

Adding participants to an assistant task or bound colleague DM requires a new
group, which the room header starts from its labelled button. In every room
kind, the header's participant avatars open a popover that lists everyone in
the room. When starting the new group, the browser preselects the current
Human and colleague, carries the associated Page link, and preserves the
original private transcript. A personal assistant cannot join a group. In an assistant task, colleague mentions remain
structured instructions for the assistant; intake neither adds the colleague
nor emits a room input to it. Ordinary unbound rooms may promote to `group`;
a group never reverts to `dm`.

Room visibility follows `native_access_scope`:

- **`participants`** restricts access to explicit active room participants.
- **`anchor_page`** binds the room to a Pod Page and requires live `node_view`
  permission on that Page. Any Human who currently holds `node_view` can read
  the thread and post to join it (the first accepted message adds that Human as
  a participant in the same transaction). Every access check evaluates live Page
  and Principal state, so trashing or revoking access to the Page revokes room
  access immediately.

- **`agent_peer`** isolates a delegated exchange between two Agents. Its
  `(origin_conversation_id, peer_sender_uid, peer_target_uid)` tuple is unique
  within the tenant while the origin exists. Agent UIDs follow Principal
  renames through foreign keys. Delegation cards in the origin conversation
  distinguish queued, running, retrying, and pending-decision states, and
  stopping an exchange cancels unstarted queued inputs alongside interrupting
  active work. The origin's authorized Humans may inspect its public messages
  and tool steps through the exchange drawer; owning the target Agent does not
  grant Human access to other people's exchanges.

Global Chat and Recents exclude `anchor_page` and `agent_peer` rooms. Comments
use the former internally, and the origin's timeline exposes the latter.
The Page Assistant panel lists only the viewer's private assistant tasks bound
to that Page. Guests do not receive that panel.

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
their own pin state, mute state, monotonic `last_read_seq`, and `last_visited_at`, while an Agent's
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

On a shared Page-anchored `dm` room, a Human with `node_view` can post a comment
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
  on retries. When a room is created, Ankole seeds its initial title from the
  first non-empty line of the opening message or attachment filename (up to 40
  characters). Once the opening Human message's turn is admitted in a
  personal-assistant or group room, Ankole asynchronously asks the admitted
  Agent's `light` model profile once for a concise title in the message's
  language (up to 40 characters), stores it in `metadata.generated_title`, and
  updates `title` with a status broadcast unless the Human has manually renamed
  the room (`title_customized`). Clearing a custom title restores
  `metadata.generated_title` when present, or falls back to the 40-character
  opening heading; colleague DMs skip title generation because Pod presents them
  under the colleague's name.

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

## Peer Delegation

`send_to_agent` accepts a colleague UID, message, optional Page IDs and optional
priority flag. `Agents.MessagingPolicy` admits personal-assistant-to-colleague
work under the owner's frozen Human WorkAccess and current chat permission.
The colleague uses its own resource permissions. A missing target Page grant
returns all missing IDs and whether the assistant can share, before accepting
any delegation. The assistant applies the sharing implied by the user's request
with incremental `pages.update_sharing`, then resends.

The exchange's messages and Signals form a durable mailbox. A successful send
returns immediately. The origin records an outbound entry, and a colleague's
committed reply records an inbound entry and one input to the original
assistant Session. Pod shows each delegation as one row: the colleague's name,
the task, and its current state. Pod attaches the reply to the nearest earlier
delegation of the same exchange, where the row shows the beginning of the
answer, its linked Pages, and the time the colleague took. Only the latest
delegation of an exchange follows the colleague's live state and offers Stop.
A details drawer shows the whole exchange, its state, and Stop.
Sessions can consume already queued replies to the same Human request together
when preparing the assistant's first model request. Silent completion sends no
input. External IM receives only final assistant conclusions or interactive
questions, rather than process cards.
Jobs resolve their durable owner and reply route; cron delegation requires one
native report destination. A source without an origin returns
`origin_conversation_required`.

Both send and reply commit acquire all participating Session advisory locks in
sorted order before the workspace fence, then origin and exchange rows in UUID
order before Signal locks. Notifications run after commit. Deleting an origin
queues stops for its exchanges in the deletion transaction; the foreign key
clears their origin and keeps the exchange history.

Process cards advance `sequence_high_water` only. Human messages, ordinary
Agent replies and interactive questions also advance `last_notifiable_seq` and
`last_activity_at`. Unread state compares the Human's read position with the
notifiable watermark. Peer work and pending questions contribute to the origin's
row status without manufacturing unread messages.

The drawer pages public messages and tool summaries and subscribes directly to
the exchange's SSE stream, authorized through `originConversationID`; it omits
reasoning summaries, while the card lets the Human stop queued, running,
retrying, or waiting work.

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
recovery. Conversation Sessions rotate cold large model contexts according to
`sessions.wake_recycle` (see [Sessions](Sessions.md)), while browser refreshes
and reconnects always load the visible transcript from `Ankole.Conversations`
rather than AIGateway model history.

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
| `GET /agents` | Callable AI colleagues with role and `directConversationID`, plus the viewer's personal-assistant availability |
| `GET /teammates` | Active Humans in the tenant, with an optional search query |
| `GET /conversations` | Accessible rooms with personal preferences, Agent identities, activity status, search, cursor pagination, and pinned-first or recent interaction order; `imOnly` excludes personal-assistant tasks |
| `POST /conversations` | Initial Agents and Humans, first message, optional Page, access scope and explicit `roomMode`; bound colleague DMs reuse their identity |
| `GET /conversations/attention` | Accessible rooms with unread messages, pending interactions or active work, including downstream peer work |
| `POST /next-steps` | The personal assistant's open next steps for the current Human's chat home; `refresh` asks for another menu and `locale` sets the writing language |
| `POST /next-steps/:id/choose` | Record that the current Human chose one of their offered next steps |
| `POST /conversations/:id/reply-suggestion` | One line the Human may send after the latest Agent reply, or no text when the room or reply does not qualify |
| `GET /conversations/:id/peer-exchanges/:exchange_id` | Paginated public exchange messages, execution summaries and live state; access follows the origin |
| `POST /conversations/:id/peer-exchanges/:exchange_id/stop` | Stop the colleague's exchange through the ordinary Session command owner |
| `GET /conversations/:id` | Room, participants, message window, room-wide artifacts and pending questions, Agent activities and queues, and linked background work |
| `GET /conversations/:id/executions/:kind/:run_id` | Read one bounded page of a linked Background Job or Workflow with structured status, plan, outcome, pending questions, thread summaries, and execution items (`cursor` and `nextCursor`) |
| `POST /conversations/:id/executions/:kind/:run_id/stop` | Stop an active linked Background Job or Workflow when the Human may command its owning Agent |
| `POST /conversations/:id/executions/background_agent_job/:run_id/messages` | Send a live steer message, answer pending questions, or resume a terminal Background Job in the same workspace (`clientMessageKey`) |
| `PATCH /conversations/:id` | Title, access scope, or the current Human's pin, mute, and read position |
| `POST /conversations/:id/participants` | Add or remove participants, or change an Agent's intervention setting |
| `POST /conversations/:id/messages` | Human message with structured mentions, links, and optional Agent target |
| `POST /conversations/:id/queue` | Queue, stop, or retry command for the selected Agent |
| `POST /conversations/:id/interactions/:interaction_id/answer` | First accepted choice, form `values`, or message answer to a pending Clarify interaction, with optional references, Human mentions, and attachments |
| `POST /conversations/:id/action-cards/:card_id/resolve` | Confirm or cancel a native room `ActionCard` and return updated room detail |
| `GET /action-cards/:card_id` | Inspect a standalone `ActionCard` opened via `/?actionCard=<uuid>` from an external channel |
| `POST /action-cards/:card_id/resolve` | Confirm or cancel a standalone `ActionCard` from Pod WebUI |
| `GET /interactions/:interaction_id` | Inspect a Clarify form opened via `/?interaction=<source_signal_id>:<interaction_id>` from an external channel |
| `POST /interactions/:interaction_id/answer` | Submit form `values` for that Clarify from Pod WebUI |
| `GET /conversations/:id/events` | One SSE connection for room changes and all participating Agents |
| `GET /agents/:uid/model-profiles` | Available model profiles for that Agent |
| `GET /conversations/:id/model-profile` | Selected and active profile for the requested Agent |
| `PUT /conversations/:id/model-profile` | Store that Agent's selected profile |
| `DELETE /conversations/:id` | Authorized room deletion; `forceStop` stops active work before deletion |

On `GET /conversations/:id`, the Pod API lists linked Background Agent Jobs and
Workflows with their current status, timestamps, step or task counts, plan
progress, continuation links (`continuedFromJobID` and `successorJobID`), stop
eligibility, and latest summary preview (omitting internal
`skill_lesson_reflection` jobs and empty JSON placeholders). Whenever a linked
job or workflow starts, checkpoints a turn, changes status, or updates a task,
the control plane publishes a room status event on `GET /conversations/:id/events`
so open rooms refresh both timeline cards and inspector queries immediately.
When the user is loading another inspector page during such a refresh, the
browser lets that page finish and then rereads every loaded page, so one click
always adds the requested page. Calling `GET /conversations/:id/executions/:kind/:run_id` accepts
`background_agent_job` or `workflow` plus a `ModelIntegerID`, verifies current
room access and Session ownership on every page, and paginates Background Jobs
with the bounded `TrajectoryReader` cursor and Workflows in call-sequence order.
For each page, the Pod API returns structured narrative messages, client steer
messages as the text the Human sent (without the original Human request that the
Worker prepends for the model), reasoning summaries, plan checklists, pending Clarify questions,
subthread summaries, and typed tool steps (`skill`, `command`, `patch`,
`search`, `collab`, and `tool`), while stripping `<skill>` system prompt bodies
and hidden model context. When an authorized Human stops a run through
`POST /conversations/:id/executions/:kind/:run_id/stop` or sends follow-up text
and question answers through
`POST /conversations/:id/executions/background_agent_job/:run_id/messages`, the
control plane routes live jobs to `BackgroundAgentJobs.steer_from_client` and
respawns terminal jobs without an existing successor in the same workspace under
inherited Human work authorization.

Room detail also exposes room-wide and window-scoped views that apply the same
access and browser projection rules as timeline messages: `artifacts` lists
visible saved Page IDs and attachment groups (keyed by source Message ID across
all non-withdrawn messages up to the room's sequence high water, regardless of
the loaded timeline slice), `pendingInteractions` lists each Agent's latest open
Clarify question and durable checkpoint state, and `editableInputs` lists the
viewer's non-withdrawn Human messages in the loaded window with their addressed
`agentUIDs` and whether a later Human participant message supersedes editing
(`supersededByParticipant`).

The embedded Assistant panel binds a private personal-assistant conversation to
the current Page through `page_id`. The Human can also open that conversation
in the full Chat workspace. Page comments use internal `anchor_page` conversations;
deleting the Page or revoking `node_view` revokes access to those conversations.

Ankole retains the addressing Human's `WorkAccess` identity across child tasks
and checks that authority when admitting work. Drive and Pod resource operations
authorize the executing Agent's Principal as their single subject; another
participant's permissions never widen that Agent's access. Content writes also
require the current read revision. In Pod rooms, generated documents and research reports
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

New Chat opens a personal-assistant task with a greeting, starter prompts and
composer. The sidebar header offers this action below both tabs to formal
members, with Command/Control+Shift+O. The sidebar stays on the tab where the
member started New Chat, including after the first message opens the task.

While the composer is empty, the chat home shows the personal assistant's
next-step menu in place of the fixed starter prompts. A menu offers 4 to 7
concrete steps, recommended step first, each with its expected outcome, effort
and reason to start now; at most one step is an ambitious 10x step.
`Conversations.NextSteps` writes the menu with the personal assistant's `light`
model profile (or `primary` when `light` is unset) from what the Human can
already see: attention rooms, recent rooms, recently updated pages and recent
Brain knowledge. The server trims and bounds every field, keeps only the first
ambitious flag, and writes no menu from a reply with fewer than 4 complete
steps. `next_step_suggestions` stores each offered step for its Human: all steps
of one menu share `last_offered_at`, `position` keeps their order, and
`offer_count` counts the menus that offered a step. The chat home reuses the
latest menu until it is 24 hours old, until every step in it has been chosen,
or until the Human chooses Show others. A step that two menus offered without
being chosen is retired until retention removes it, and a chosen step is not
offered again; the model receives both lists only as steps to avoid. Choosing a
step records the choice and fills the composer with the step's title and
expected result, which the Human edits and sends as a new task. When no menu
exists or a new one cannot be written, the home shows the fixed starter
prompts; a failed refresh keeps a menu that is less than a day old and tells
the Human that no other steps are available. Steps older than 30 days are
deleted when the next menu is written. A colleague DM instead shows the
colleague's name, `@uid`, and role above a composer with a fixed recipient at
`/dm/<uid>`; `/?agent=<uid>` redirects there.

Chat shows pinned rooms once, then a collapsible Assistant section, then one
list containing existing IM rooms and available colleagues. Until the room list
and the IM room list both arrive, Chat shows only a loading placeholder, so no
row moves when the full list lands. Pod then keeps the unfiltered lists for the
rest of the page session, and a return to Chat from Home shows them at once
while they refresh in place. The Assistant
section starts collapsed and exposes only pending questions, active work and
unread tasks. A click anywhere on a section heading expands or collapses that
section, and keyboard users toggle it with its chevron. Expanding the Assistant
section shows the five latest tasks; Show all lists the rest of the history,
and the filter above the list searches it. Task rows are one line;
IM rooms and colleagues use two lines, with the name and time above the latest
message or the colleague's role. Every list names an Agent by its display name
followed by its `@uid`, marks a DM with the colleague's avatar, a group with a
group mark, and a task with a conversation mark. Home interleaves Pages and
conversations, retaining at most three attention items ahead of ordinary
recents: pending decisions first, relevant unread comments second, and running
work third. Both tab badges use the same count: Chat counts unread IM and
pending decisions, and Home counts Pages with relevant unread comments.

A group invites into itself. An assistant task offers Start a group and a DM
offers New group; both leave the source conversation unchanged. That dialog
takes a group name, the members (the source conversation's other members start
checked), and a first message prefilled with the Pages the source referenced,
and it explains which of these is still missing before it can create the group. Committed room events and native Session transitions notify
open Pod tabs, coalescing sidebar refreshes over a 1,500 ms window and
re-evaluating participant and Page permissions on every refresh.

Inside a colleague DM, the header identifies the colleague by display name and
UID. Task and group headers let participants edit the conversation title.
Global search finds callable colleagues by UID, display name, or role and opens
their stable DM, including colleagues the Human has not contacted yet. It also
lists accessible rooms whose title or message text matches, and a message match
shows a one-line excerpt of the latest matching message. Choosing that result
opens the room at the message: Pod loads up to ten pages of older history to
reach it, then opens in-room search with the query and selects the match inside
that message.
When a Human enters a room that has messages from others after their read
position, the timeline opens at the first of those messages under a New messages
divider, unless Pod still holds the Human's reading position from an earlier
visit to that room in the same session.
The divider stays at the read position the Human had on entry while the visit
marks the room read, and Pod shows it only when the loaded history reaches that
position.
Creating a group from a private conversation prefills its referenced Page links
for the Human to review and edit; the new group receives those references, while
the private conversation keeps its transcript and membership.
Room controls offer participant management, share-link copy, and Markdown export,
while keyboard shortcuts toggle in-room search and the summary drawer.
A room has one right sidebar, which shows the summary, a linked execution or
colleague exchange, or an attachment preview; opening one replaces the other.
The summary is a 296 px drawer beside the full chat. On desktop an execution or
a file takes everything right of a 300 px chat column instead: the sidebar
slides in from the room's right edge while the chat narrows into that column
over the same motion, and it slides back out while the chat widens again. A room
narrower than 760 px lays the sidebar over the chat instead, and phones and the
Page assistant panel open executions in a slide-over sheet and attachments in a
dialog:

- **Summary drawer:** lists participating Agents (with active models and
  per-Agent `may_intervene` toggles in group rooms; direct rooms always address
  their Agent) and Humans (using Principal avatars with initials fallbacks),
  plus room-wide referenced/saved Pages, attachment previews/downloads, and
  background executions regardless of how far back the timeline has scrolled.
  `Escape` closes only the topmost layer: while an attachment preview or another
  popup is open, the drawer and the inspector pane leave the key to that popup,
  even before focus has moved into it.
- **In-room search:** pages backward through the message cache, flags partial
  results while loading or if a page fetch fails, halts pagination as soon as
  search closes, and highlights matches via browser text ranges without mutating
  message DOM nodes (updating highlights when a user expands collapsed tool
  output).

All surfaces, code blocks, selections, status pills, and composer focus rings
use semantic tokens from the shared Ankole UI kit across light and dark themes.
A reply's code blocks, inline code, and tables share the document type scale:
13 px source under a 32 px toolbar on a light fill, and 14 px table cells on a
hairline grid. Pickers, the
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
unread room shows a blue dot, a room that waits on a decision shows an amber
"Needs you" badge, and a room where an Agent is working or a background run is
active shows a turning neutral ring. A question that a delegated colleague asks
in the original conversation carries the colleague's name in its heading. While
an Agent works, its live work summary renders an indeterminate loading spinner
alongside the active phase or tool step; while it writes, a caret follows its
last words, and the composer offers a labelled Stop button next to Send. Once
settled, the collapsed work summary shows "Work steps" (or "Thinking" or "Model
usage" when no tools ran) together with the reported model and token usage,
while a failed turn reads "Failed" in the destructive colour with the failing
step marked, a stopped turn reads "Stopped", and a retryable turn offers a
labelled Retry reply action. Because an Agent often recovers from a failed step
and still completes its turn, Pod judges the turn by `execution.status` alone:
a completed turn with failed steps shows the number of failed steps in the
warning colour, such as "Work steps · 1 error", and stays collapsed so people
can still find and report the error. A pending decision card has an amber edge
and heading, and its question and choices use the message type scale. Queued
messages offer a labelled Steer action, and a background run card counts its
time in minutes and hours once it runs past a minute.

In the timeline, compact event notices sit alongside attributed messages:

- Live turn previews track their triggering `sourceMessageID`, and interleaved
  replies link back to the question they answer and restore scroll focus there.
- Markdown rendering supports syntax-highlighted code, tables, math formulas,
  Page chips, image lightboxes, and sandboxed Mermaid diagrams. For
  Agent-authored messages only, a unified remark AST pass (paired with
  `Ankole.Kernel.repair_generated_markdown/1` on outbound IM delivery) repairs
  escaped structural newlines, trailing whitespace inside bold delimiters, and
  accidental single-tilde strikethrough in ordinary text. It preserves code,
  HTML, inline and reference links, images, reference definitions, and `$` / `$$`
  math. Human-authored messages use standard Markdown rendering. During streaming,
  Pod renders the entire available message as one Markdown document, preserving
  nested block boundaries and references defined elsewhere in the message. Pod marks its
  HTML shell and interactive regions (`pre`, `code`, `.katex`, Mermaid viewers,
  and choice/approval cards) with `translate="no"` to ask translation tools to
  leave their DOM unchanged. Fenced `mermaid` blocks render
  through `pele` into SVG hosted inside an isolated `iframe srcDoc` (`sandbox=""`
  and `script-src 'none'`), offering Diagram/Source tabs, PNG copy/download, a
  double-buffered pan/zoom lightbox that keeps the prior bitmap visible until the
  re-rasterized scale commits, and automatic source-code fallback on incomplete
  or invalid syntax (external IM adapters preserve fenced `mermaid` code blocks
  directly). PNG export preserves the diagram's aspect ratio and rejects diagrams
  that exceed 16 million pixels or 16,384 pixels on either side even at `1x`.
  Code text updates immediately while syntax highlighting waits for
  150 ms of quiet; a highlighted result appears only for the exact text and
  language that produced it. Plain-text blocks use the native code presentation
  without loading the highlighter.
- While a turn runs, the active step stays visible above collapsed prior steps
  and reasoning. When the person expands or collapses the live work summary,
  Pod keeps that choice for the rest of the turn while new steps and model
  Responses arrive, and opens the summary again only when the turn newly needs
  their attention. Once the reply commits, the entire execution trace collapses
  above the answer, whereas stopped or failed turns keep their recorded steps
  expanded (including command strings, stdout/stderr, and exit codes when
  recorded).
- Linked Background Agent Jobs and Workflows appear once inside the live turn
  and then attach to the committed reply, collapsing respawn continuation chains
  onto the latest job card and hiding duplicate launch tool steps in the turn's
  work trace when their card is present (while keeping failed launch steps and
  non-expandable Skill load badges visible). Selecting a linked execution or
  colleague exchange opens it in the room's right sidebar on desktop (falling
  back to a slide-over sheet on phones and in the Page assistant panel)
  with narrative progress, collapsible tool groups, subthread filters, inline
  Stop controls, and a composer for steering, answering pending questions, or
  continuing a finished Background Job.
- Message actions support copying, quoting, eligible edits, Agent retries, and
  multi-message selection, while file attachments offer **Save file to Pod** and
  messages display Pages created from that turn as links beneath the source
  message. Selecting messages opens a sticky toolbar to copy or download a
  Markdown excerpt that preserves code-block whitespace, or render a shareable
  PNG card from an offscreen CSS-inlined DOM clone with deterministic DPR
  scaling (`3x` -> `2x` -> `1x`) under the same browser canvas pixel budgets
  (surfacing an explicit `needsPagination` prompt to narrow the selection or
  export Markdown when even `1x` exceeds canvas limits).

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
- **File attachments:** Each selected file uploads as soon as it is added and
  appears as a card with a thumbnail, its name, and its size. An image shows
  itself, and any other file shows its extension.
  While a file uploads, the card shows the bytes sent against the total and
  its remove control shows a progress ring, which turns into the cross on
  hover or keyboard focus; removing the card cancels the upload. A failed
  upload keeps the file and offers a retry. Sending waits until every file
  has finished uploading. Selecting the card opens the same attachment preview
  as a sent attachment, which shows a PDF in the
  [PDF viewer](PodContentModel.md#pdf-viewer).
- **References and permissions:** Quoted messages and Page chips travel as
  structured message links into model context, though Agent tools still enforce
  live permissions when reading referenced Pages. Users without `chat`
  permission on an Agent can read its Clarify card but cannot submit an answer;
  sending, answering, and retrying all require an active, callable target Agent
  (edits retain their saved target Agent, and Clarify answers target the asking
  Agent).
- **Follow-up steering and queue management:** When every addressed Agent is
  idle, pressing `Enter` sends with `steer` delivery so the message enters the
  conversation timeline directly, shows live reply progress immediately, and
  starts a turn (even if a paused follow-up queue holds deferred items, in which
  case `Command+Shift+Enter` / `Control+Shift+Enter` or the send-options menu
  appends a `queue` item instead). While an addressed Agent turn is active,
  `Enter` follows the user's follow-up preference (`steer` by default, persisted
  in browser storage and switchable to `queue` from the send-options menu beside
  the send button), and `Command+Shift+Enter` / `Control+Shift+Enter` sends the
  alternate mode (`queue` when `Enter` steers, or `steer` when `Enter` queues);
  when the room's selected model profile differs from an addressed Agent's
  active-turn profile, follow-ups automatically use `queue` delivery. The
  bounded, scrollable queue tray renders only when at least one Agent holds
  `queue`-mode items, providing single-line previews and controls to reorder,
  **Steer** into the active turn (or **Send** immediately from an idle paused
  queue, moving the item into the timeline ahead of deferred `queue` items),
  edit, retract, or **Continue** a paused queue. **Take back** (or `Alt+ArrowUp`
  in an empty composer, which pops the viewer's most recent `queue` item) pulls
  a queued item's text, attachments, Page links, and Human mentions back into
  the composer (targeting that Agent's queue when the composer was empty without
  re-addressing other Agents, or appending when a draft already exists). In a
  single-Human room, unadmitted `queue` items appear only in the queue tray
  until a subsequent Agent reply commits (after which they appear in the
  timeline with a queued badge), whereas `steer` messages stay directly in the
  timeline; in multi-Human rooms, queued items appear in the timeline
  immediately so teammates can see them. The attachment count opens the queued
  files for preview and download without taking the message back into the
  composer.
- **Reply suggestion:** After an Agent reply in a room whose only human
  participant is the viewer, Pod shows one suggested next message as inline
  ghost text with a trailing `⇥ Tab` keycap inside the empty composer once the
  room is completely idle—with no pending question, prepared confirmation card,
  queued input, active Agent turn, linked Background Agent Job, running
  Workflow, or active colleague exchange. `Conversations.ReplySuggestion`
  verifies that idle room state in a repeatable-read snapshot before drafting
  the line with the replying Agent's `light` model profile (or `primary` when
  `light` is unset) from the last eight messages, in the language the Human
  writes in the room, and returns no text for a multi-line reply, a reply over
  120 characters, or one that repeats the Human's last message. Pressing `Tab`
  in the empty composer or clicking the `⇥ Tab` keycap fills the draft. Typing
  or new work hides it, and after the Human passes over three suggestions in a
  row Pod stops showing suggestions in that room for the rest of the visit.
  Ankole stores no suggestion.
- **Editing and conflict handling:** Editing a queued item (`action: "edit"`)
  loads that item into the composer, whereas editing a committed timeline
  message (`action: "edit_last"`) opens an inline editor directly inside that
  message bubble so the bottom composer preserves its unsent draft, Page
  references, mentions, attachments, and Clarify answer target untouched. Any of
  the viewer's non-withdrawn, single-Agent timeline messages without a later
  message from another Human participant can be edited inline—including while
  the target Agent is actively streaming or holds queued follow-ups—and opening
  or canceling the inline editor leaves active work undisturbed. From an empty
  composer, `ArrowUp` edits the viewer's latest queued item or opens inline edit
  on the latest editable timeline message, and pressing `Escape` twice within
  600 ms enters timeline backtrack mode (`ArrowUp` and `ArrowDown` move across
  editable Human messages, `Enter` opens the inline editor, and `Escape`
  returns focus to the composer without dismissing an enclosing mobile `PageChat`
  `Sheet`, while inner dialogs, menus, and listboxes keep their own keyboard
  handling). A queued message addressed to multiple Agents
  remains editable only before any target Agent admits it (updating text, links,
  and Human mentions while keeping Agent targets fixed; committed Human-only,
  multi-Agent, or teammate-superseded messages explain why inline editing is
  unavailable). Saving checks the Agent's queue comparison token and baseline
  snapshot: on conflict, the editor keeps local changes while letting the user
  inspect and explicitly load the server version (including reference-only or
  mention-only changes). While a new message is being sent, the Human can
  continue editing the composer draft or select another quotation; confirmation
  clears only the captured draft when its text, references, and mentions still
  match.

The resizable Assistant panel shows the current Human's private conversation
with their personal assistant, Page context controls, and a link to the full
Chat workspace. Guests do not have this panel.

Selecting text in a document and choosing `Ask assistant` in the selection
toolbar opens the Assistant panel (the open private conversation, or the Page's
latest personal-assistant conversation), quotes the selection in the
composer, and focuses it. The quote travels as a `{ kind: "page", id, quote }`
message link, so the Agent receives it as referenced user context and locates
the passage with a fresh Page read before editing. A draft quotes one passage at
a time: a quoted message and a Page selection replace each other. Choosing the
action changes nothing in the document and needs only access to the Assistant panel, not
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
replaces a separate status broadcast on commit). Once a native conversation
write or queue mutation commits in PostgreSQL, `Sessions.notify_committed`
notifies Oban's `conversations` queue immediately and sends `:reconcile_inbox`
to any live registered `Driver` for the affected Sessions so new turns, mid-turn
steers, and stops take effect without waiting on periodic queue staging. Both
event streams map to the SSE `conversation` event (note that on external
channels, `turn_completed` proves only that Delivery intents committed; public
external messages appear once the IM provider confirms delivery).

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

- **`Stop`** cancels the active reply and converts any unadmitted inputs
  (including unapplied steers) to paused `queue` items: when unadmitted inputs
  remain or when `Stop` is issued explicitly while no turn is active, the
  Agent's queue stays paused across page refreshes until **Continue** resumes it,
  **Steer** releases or drains the remaining `queue` items, or **Take back**
  retracts the last `queue` item; stopping an active turn with an empty queue
  cancels that turn while leaving subsequent follow-ups unpaused.
- **Stale queue edits** keep the user's draft; refreshing adopts the new
  comparison token automatically only when the server's saved text still matches
  the baseline, requiring an explicit user choice otherwise.
- **Timeline edit and retry** coordinate `Conversations.NativeEdit`, `Commands`,
  and `ModelHistory`: editing a single-target Human message (`edit_last`)
  reuses its persisted Signal target regardless of the current composer selector
  and rejects edits superseded by a later message from another Human participant
  with `reply_unavailable` (Human-only and multi-target messages likewise
  require posting a correction). Inside one lock-ordered transaction,
  `NativeEdit` locks the Principal catalog, Agent Workflow and Background Job
  slot tables, candidate runs and active job turns, Session advisory locks, and
  Session workspace rows before verifying room topology, queue versions, and
  message compare-and-swap tokens. Once those checks pass, `NativeEdit` cancels
  running Workflows, Background Agent Jobs (including continuation successors
  linked through `continued_from_job_id`), and delegated peer exchanges spawned
  from the reverted Signals, fences participating Session workspaces so live
  `Driver` streams, in-flight tool tasks, and open Worker workspaces close
  immediately, and supersedes pending Clarify and ActionCard interactions from
  the reverted Signals. It then marks the edited Signal and later Signals
  `removed` (withdrawing later Human messages while keeping their UUIDs reserved
  against late `POST` replay), deletes committed Agent replies and notices from
  the edited message onward, retracts `:generating` and `:complete` AIGateway
  Responses (including tool journals and `:checkpoint` rows) back to the
  reverted Signals, clears any paused queue flag on the target Agent, updates
  the message in place (clearing structured Clarify `interaction_answer` fields
  whenever the edited text differs), and accepts a fresh
  `conversation.message.addressed` Signal (`id: "edit:" <> command_id`) using
  the room's current model preference. **Retry** (`regenerate`) appears on the latest eligible reply or
  dead-letter notice (`Stop` and preflight notices are not retryable), replacing
  only that final reply while keeping already committed Pod Page, Base, and
  Applet writes intact across both edits and retries. Native edits,
  regenerations, and logical queue removals invoke the message-change hook in
  the same transaction (expiring derived Brain Facts and rewinding the Brain
  learning cursor) and filter withdrawn messages out of timeline reads, model
  context, and Brain extraction.

Timeline history reads return up to 500 visible messages alongside an
earlier-page cursor, `editableInputs` for that window, and the exact covered
`seq` interval, letting the browser splice older pages into its local cache,
retain older `editableInputs` outside a refreshed slice, and mark earlier viewer
messages superseded whenever a newer slice includes a message from another Human
participant.

## Clarify, Action Cards, and Execution History

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
Page chips, quotes, or Human mentions; an attachment alone is a valid answer. A
typed answer in Pod keeps its full text and indentation, while the free-text
input on an external channel's card accepts at most 1,000 characters. If
an unanswered question sits above the loaded 500-message window, the UI surfaces
it in the timeline's attention banner and smoothly restores it to its inline
position once the user scrolls back to that message.

A Clarify can carry a form instead of choices. `Delivery.ClarifyForm` owns the
field contract: one to five fields, each with a snake_case `id`, a `label`,
optional `help`, `required` (default `true`), an optional `default`, and a type
(`text`, `number`, `date`, `select`, `multi_select`, or `boolean`) with
type-specific bounds, and at least one field must be required so that a
submission always carries an answer. The `clarify` tool validates the
definition before it records the question, so a repeated ID or option value, a
minimum above its maximum, an invalid default, or a form without a required
field returns `invalid_arguments` with the exact problem to the model. Every
surface renders a `boolean` field as a Yes/No choice that starts empty, so a
required boolean means that the person chose. The message's
`rich_content.clarify.fields` carries the definition for display, while the
pending interaction entry in the Delivery checkpoint holds the authoritative
`form` (`question` and `fields`).

Every answer surface validates a submission against that checkpoint entry. An
invalid submission returns HTTP 422 `invalid_form_answer` with one code per
field (`required`, `too_long`, `out_of_range`, `invalid_date`, `not_an_option`,
`too_few`, `too_many`, `not_an_integer`, or `invalid`), never echoes the
submitted value, and leaves the question pending. The first valid submission
records a `form` answer that holds the typed values (option `value`s for select
fields and ISO dates) and a readable summary built from the field labels. The
room message shows that summary, and the asking Agent receives the summary and
the typed values as JSON through `interaction_answer` on its reply Signal. The
composer remains the way to answer a form in the Human's own words.

When an Agent opens a Clarify, Ankole supersedes that Agent's older pending
Clarify in the same Session; Action Cards keep their own lifecycle.

Every external form Clarify carries a link to
`https://<slug>.<site>/?interaction=<source_signal_id>:clarify:<tool_call_id>`,
which opens a standalone Pod dialog; opening it never answers the question, and
a reply in the channel supersedes the form like any other message.
`Delivery.Posting` chooses the surface from the primary target's adapter. When
the adapter declares the `form` outbound capability (Feishu/Lark and Microsoft
Teams), Posting commits a clarify reply whose presentation holds one `form`
control with the typed fields and a `link` control to the Pod dialog, and the
channel card renders both. Every other channel receives an ordinary final reply
with the question, the field labels, and the link. Either way, Posting opens the
pending interaction with its form.

A card form submits through the `ankole.interactive_output.action.v1` callback
with `answerKind: "form"` and the field values in `formValue`.
`ClarifyForm.card_values/2` reads the strings that card inputs submit (numbers,
`true`/`false`, a date with an optional time zone, and comma-joined
multi-select values) before `ClarifyForm.answer/2` validates them against the
pending interaction's form. An invalid submission leaves the question pending
and returns a localized notice that names each rejected field and its problem:
Feishu/Lark, whose adapter declares `action_notice`, shows it as a toast on the
callback, and Teams, whose `Action.Submit` callback has no response, receives it
as a reply. Interaction IDs,
revisions, control IDs, and duplicate or stale callbacks follow the same rules
as choice buttons. The first valid submission records the `form` answer, and a
channel that refreshes its card replaces the form with the answer summary.

A question from a native room follows the room answer path. For an external
question answered in Pod, Ankole records the first valid submission on the
source checkpoint and wakes the asking Agent with a kernel
`signal.action.invoked` Signal on the source Session and reply route, or
through the peer answer path when a colleague asked. Answering an external
question requires an active Human, the same rule that the channel's card
buttons apply, and a colleague's question additionally requires `chat`
permission on that colleague. The standalone dialog shows every allowed viewer
that a question was answered and by whom, but it shows the text of an external
answer only to the Human who gave it; room members see a native answer in the
room anyway.

A colleague's peer Clarify is projected into the original conversation with
its attribution and original checkpoint identity. Answering there records the
Human's response in both transcripts and directly wakes the colleague. Normal
messages to the assistant preserve the question; priority instructions to that
exchange and Stop supersede it. External Bot callbacks follow the frozen origin
route to that same checkpoint. Peer Action Cards belong to the origin's
approval surface and resume the colleague after execution.

The origin's conversation events refresh its peer cards and their details
alongside its transcript. A card reflects the colleague's current state even
when its details drawer is closed: answering resumes progress, and completion
clears the pending-decision label and Stop control.
The delegation receipt tells the assistant that the colleague owns the task's
questions and will deliver them directly to the Human. The assistant can finish
independent work and end its turn while the exchange continues.

When an Agent needs a Human to authorize a high-privilege mutation that exceeds
the Agent's own grants, calling `propose_action_card` drafts an `ActionCard` row
(`conversation_action_cards`, lock rank `11`) for one of seven typed actions:
`brain.object.create`, `pod.knowledge.save`, `pod.page.set_sharing`, `pod.page.delete`,
`pod.page.restore`, `pod.base.delete_table`, or `conversation.add_participants`. Drafting requires the
Agent to hold `node_view` on the target node (or participate in the target
native room for `conversation.add_participants`), snapshots optimistic
preconditions (`expected_sharing_version`, `expected_updated_at` +
`expected_deleted` + `expected_revision`, `expected_name` +
`expected_schema_version` + `expected_data_version` + `expected_updated_at`, or
native room identity), and commits an interactive card
(`delivery_key: "action_card:<tool_call_id>"`, interaction ID
`"action_card:<card_id>"`). The Web card displays the proposed grant subjects,
roles, scopes and conditions, or the named participants to add. For a knowledge
change, the card displays the page title, the captured base revision, and an
expanded diff. The Human can expand the complete Markdown draft, including its
metadata, before confirming. The client receives the base revision as a
projection of the card's `expected_revision` precondition. Knowledge change
approvals are drafted in native rooms. A `brain.object.create` card captures an
installed, writable ontology category, a title and the complete Markdown draft.
Confirmation creates the object with the category's entity type under the
Human's authority; it does not require an existing knowledge object. In external IM, the Agent supplies the
draft and page link for an owner to review and save in Pod. Generic native
clarification endpoints reject ActionCard interaction IDs; resolution belongs
to the ActionCard operation and its resource authorization checks.

Confirming or canceling an `ActionCard` (`POST .../action-cards/:card_id/resolve`
in Pod WebUI, or interactive button callbacks `confirm` / `cancel` on external IM
channels) acquires outer locks in strict rank order before touching the card row:
`page-tree` (`2`) and `page-root` (`2.5`), `Principals` (`3`), `Sessions`
(`9`/`10`), `Conversations`, `conversation_action_cards` (`11`), `Signals`
(`11`), and `pages` / Base (`12`). Under those locks,
`Ankole.Conversations.ActionCards` verifies the confirming Human's live
Principal permission (`node_manage`, `node_edit`, `:delete_table`, or room
invite authority) and captured preconditions. For deletion and restoration, it
reads the target Page and Base versions after acquiring their write locks, so a
concurrent writer that commits while confirmation waits invalidates the card:

- Matching preconditions execute the domain mutation in the same control-plane
  transaction, transition the card from `prepared` to `executed` (for
  `pod.base.delete_table`, `executed` means `Bases.Delete.mark_in_tx/1` committed
  `deleting_at` and registered the asynchronous shard-drop cleanup job), and
  enqueue a `conversation.action_card.executed` wakeup Signal for the drafting
  Agent.
- Precondition mismatches transition the card to `stale` with an explanatory
  `resolution_note` in the same transaction without mutating target state,
  whereas `cancel` transitions it to `cancelled` silently without waking the
  Agent. Withdrawing the source message cancels an open `prepared` card.
- External channels follow explicit capability tiers: Tier 1 adapters with
  `PreviewAdapter.refresh/2` (Feishu/Lark, Slack, Discord, Telegram, Microsoft
  Teams, and WeCom AI Bot when `response_url` is available) refresh the original
  card in place to remove buttons and display the outcome; Tier 2 button-callback
  adapters without preview-adapter card refresh (LINE, WhatsApp, DingTalk, and
  WeCom AI Bot fallback) enforce server-side
  idempotency on the locked card row, reject unlinked external clicks without
  creating Principal records, and send one settlement receipt
  (`outbound_key: "action-card-settlement:<card_id>"`, plus at most one duplicate
  or unauthorized notice per external sender recorded in `notified_senders`);
  Tier 3 channels without interactive card callbacks (Email and WeCom Customer
  Service) render a read-only summary with a confirmation link
  (`https://<slug>.<site>/?actionCard=<card_id>`) that opens the standalone
  confirmation dialog in Pod WebUI.

On turn completion, `Sessions.Presentation` builds `rich_content.execution` from
the durable turn journal and tool results, recording the reasoning summary,
ordered steps, tool outcomes, code-execution source/output, and durations
directly on the Agent reply. Each step stores an excerpt of at most 8,000
characters for its input and its output: the input keeps its opening, and the
output keeps its opening and its last 5,000 characters, so a long command still
shows its exit status and the failures and summary it prints at the end. When a
person expands a command step, Pod scrolls its output to that end. Pod renders
an `apply_patch` step as the files it changes, each with its added and
removed line counts and changed lines, and marks a patch whose excerpt ends
before `*** End Patch`. `execution.status` identifies completed, stopped,
and failed work; on a stopped or failed native turn, `Presentation` stores the
execution record on the turn's notice message and marks any missing or
interrupted tool results with that terminal turn outcome (merely emitting a tool
call never counts as tool completion without a recorded result).

A step also keeps the activity label that people saw while its call ran:
`label_key` names a `conversations.delivery.reply.activity.*` message and
`label_bindings` fills it in, so Pod names the step in the reader's language.
The Session turn keeps that label with the tool result in the round journal. A
control-plane tool's label comes from its activity callback, and a Worker
tool's label is the last one that the Worker reported for the call. A step
recorded without a label keeps its `title`. A step's output leaves out the retry
hint that Ankole appends to every tool error for the model.

A label names what the step works on when that object helps a reader follow the
work: a file read names its path, and a code or file search names its query.
The Worker labels a shell command by its action and program, such as
`Running tests · bun test`, and never copies the command's arguments into the
label, because external conversations show the same labels in their live
previews; the full command stays in the step's input. The Worker labels a
command as a read only when no program in it can write, so a pipeline such as
`ls && rm -rf build` or `cat a > b` reads as `Running command · ls` or
`Running command · cat`.

Pod folds each run of two or more consecutive steps that only read the
workspace (reading files, searching code or file paths, and listing
directories) into one collapsed row that counts them, such as
`Read 4 files · Searched 9 times · Listed 2 directories`. Every other step keeps
its own row, so edits, tests, and commits stay visible at a glance, and
expanding the row lists each read with its details. The collapsed row shows a
spinner while one of its reads runs, and otherwise marks a read that failed or
stopped.

While an Agent works, Pod names every running step in the work header, joined
by ` · ` when steps run in parallel, and keeps the steps in one folded list.
The list therefore keeps its shape and its open or closed state however many
steps run at once. Only the thinking before the first step folds the work
summary away; after that, the summary stays open while the model thinks between
steps, and its reasoning moves into a collapsed Thinking row inside it, so
whatever the reader opened in the list survives those pauses.

The execution record also carries `execution.usage`, which `AIGateway.turn_usage/1`
sums from the usage ledger rows of the turn's Signal on completed, stopped, and
failed turns. The sum covers every attempt and every side call of the turn, such
as a vision fallback or a compaction that the turn needed. `usage.models` lists
each model that served the turn with its requested `provider_id/model`, the
model that the Provider reported when it differs, the requested profile and the
profile that served it when they differ, and its own totals. Every level carries
`rounds`, `reported_rounds`, and `input_tokens`, `output_tokens`,
`cached_input_tokens`, `cache_creation_input_tokens`, and `reasoning_tokens`;
a token total is `null` when no
round reported that count. A turn without ledger rows has no `usage`.
`Ankole.Pod.Chat.Execution` declares the execution record's fields for the Pod
API, so the generated Pod client derives the record's steps and usage types
from that declaration.

Pod shows that usage in the work header of everyone who can see the reply: a
quiet line at the right end names the main model and the reported input and
output tokens, such as `gpt-5.5 · 12.4K tokens`. When some rounds did not
report, the line reads `≥12.4K tokens (2 rounds not reported)`; when no round
reported, it reads `Usage not reported`. A reply without tool steps still shows
the header so that its usage stays visible. Expanding the header lists each
model's rounds and its input, output, cached, and reasoning tokens, and a
profile fallback such as `light → primary`.

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

Native chat file uploads stage an immutable `file_objects` object through
`Conversations.Attachments` and `Files`. Ankole signs a receipt bound to the
tenant, Human, client upload ID, object ID, checksum, filename, size, and content
type. Posting a Message verifies that receipt, completes the object, creates a
file node in the conversation root, and records a `message_attachments` row in
one transaction. Unused receipts expire after 24 hours; exact retries of an
accepted Message remain valid. The object collector handles unreferenced staged
uploads according to the Files lifecycle.

`message_attachments` owns each attachment's position, immutable `object_id`,
optional `node_id`, and provider/display metadata. The public Message
`attachments` array is a projection of those rows. Attachments awaiting provider
download or pointing to provider-only content have metadata with no object yet.
A later observation preserves the first stable attachment identity and already
stored bytes. Before a committed Signal becomes prompt-visible, its Messages
hold the frozen object references and its files belong to the conversation root.
Ignored group batches keep the existing short-lived staging behavior until they
are mirrored; unreferenced staged objects follow the Files collection deadline.
Every participant receives view, contribute, and edit access to the conversation root.
Participants can revise, rename, and delete its files and folders, including files
created by another participant. Message attachments retain their frozen objects.
For external IM conversations, the authorization snapshot includes the resolved
DM peer and the current members of the conversation's Principal Group, as well
as observing Agents. Group membership changes take effect through the same
Principal/AuthZ projection used for disclosure.
Membership does not grant node manage access; an Agent reads and changes nodes
under its own Principal permissions.

Pod shows each Message attachment as a file card. Selecting the card opens the
attachment preview, which owns **Download original** and **Open in new tab**.
In a desktop room the preview opens in the room's right sidebar, takes focus,
and closes with `Escape` or its close button, which returns focus to the card;
the sidebar also closes once no card for that file remains, for example when
its queued message is taken back. On phones, in the Page assistant panel, and
in other places that show chat files, the preview opens in a dialog;
for a file type that Pod cannot render, the preview shows the file's type and
size together with those two actions. Reply cards place **Save to Pod** beside
the card as a separate button.
The preview renders the formats that the Pod file page renders: images
(PNG, JPEG, GIF, WebP, AVIF, BMP, and SVG, up to 16 MiB), PDFs, audio and
video, CSV and TSV as the file page's UTF-8 table (the first 64 KiB and at most
500 rows), workbooks (`.xlsx`, `.xlsm`, `.xls`, `.xlsb`, and `.ods`) as a
read-only sheet view, `.pptx` slides, Markdown rendered as in chat messages, and
other text or code files as highlighted source (the first 64 KiB; HTML stays
source). When an attachment records no media type or only
`application/octet-stream`, Pod chooses the preview from the file extension,
and the control plane serves the file with the media type that `MIME.from_path/1`
derives from its name.
Browser downloads identify an attachment by conversation ID, Message ID, and
zero-based position, so same-name files remain distinct. The Worker command is
`ankole-pod chat attachment get <conversation_id> <message_id> <position> --to <worker-path>`.
Both routes read the Message's frozen object through current room membership.
Changing a file node's content, moving it, or deleting it does not change the
Message download. Browser refresh restores committed attachment descriptors and
warns before discarding unsent local `File` selections. **Save to Pod** references
the same object without copying its bytes.

Outbound native Agent attachments (`reply_attachment` and hosted image
generation) use the same node authorization and conversation-root destination
checks as external Delivery. An attachment from a conversation root can only be
sent to that conversation; an authorized file from another root can be sent to
any reachable conversation. Message rows freeze the selected object, and
attachment-only replies are visible statements. Inline `ankole:page/<page ID>`
URIs become `{kind: "page", id}` links whose targets check `node_view` on read.

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
- At the terminal commit check, withdrawing an explicit triggering Message
  aborts the turn with `:signal_canceled`. Withdrawing background context leaves
  the current task and answer valid; future context reads omit that Message,
  while the model history already consumed by the running task stays intact.

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
  attachment objects even if the source node or Binding is later deleted.
  `delivery_attachments` also pins objects for pending intents. When an intent
  becomes sent or expired, Ankole clears its object and node references while
  retaining the ordered descriptor metadata for audit. A confirmed public
  Message owns its separate frozen object reference in the same transaction.
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
