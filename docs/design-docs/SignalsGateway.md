# SignalsGateway

SignalsGateway connects external messaging platforms to Agents. It records
incoming messages, starts Agent work, and sends the resulting replies.

AIGateway separately stores model Responses and their history.

## Four Records in One Message Flow

One incoming message can produce four different records:

- `IngressFact` describes one event in Ankole's common input format.
- The provider mirror records the latest known state of the channel and message.
- `ActorEvent` records one item of work for an Agent session.
- An outbox row records one operation that Ankole must send to the provider.

Batches combine nearby messages. Tombstones stop a removed message from
reappearing after late provider delivery.

SignalsGateway stores these tables in PostgreSQL:

| Table | What it stores |
| --- | --- |
| `signal_gateway_bindings` | One configured provider connection for one Agent |
| `signal_gateway_channels` | The latest known state of one provider channel |
| `signal_gateway_entries` | The latest known state of one provider message |
| `signal_gateway_input_tombstones` | Removed messages that late delivery must not restore |
| `signal_gateway_inbound_batches` | Nearby messages waiting to become one Agent input |
| `signal_gateway_webhook_endpoints` | Callback capabilities that wake one Agent session |
| `actor_events` | Work that an Agent session must process |
| `actor_event_deliveries` | Attempts to send that work to a worker |
| `actor_session_workspaces` | Stable workspace identity for one Agent session |
| `signal_gateway_outbox_entries` | Operations that Ankole must send to a provider |

## Use a Different ID for Each Record

Each ID below identifies a different thing:

| Identifier | Meaning |
| --- | --- |
| `source_event_id` | One provider or internal input event |
| `source_entry_id` | One provider message, post, or comment |
| `attachment_id` | One PostgreSQL-owned attachment key, stored in entry attachment JSON |
| `actor_events.id` | One Ankole work item |
| `ai_message_id` | One stored AIGateway message |

The following key pairs prevent duplicate records:

| Key | Purpose |
| --- | --- |
| `(agent_uid, binding_name)` | Selects one configured provider connection. |
| `(signal_channel_id, source_entry_id)` | Selects one provider mirror entry. |
| `(agent_uid, binding_name, source_event_id)` | Prevents duplicate ActorEvents for provider redelivery. |
| `(agent_uid, binding_name, outbound_key)` | Prevents duplicate provider operations. |

An ActorEvent from a provider channel normally uses that channel for its
`session_id`. An internal source can select a Session directly.

## Connect an Agent to a Provider

A binding connects one Agent to one registered adapter. It records the adapter,
the settings to use, an optional filter, and an enabled flag.

The binding does not contain provider secrets. The adapter reads `config_ref`
through its own configuration API.

A binding update treats `config` as a patch. It keeps fields that the request
does not contain, so an operator can change routing without re-entering stored
provider secrets.

Each `signals_gateway.adapter` declaration must set `adapter_category` to one
of these values:

- `enterprise_im` identifies an enterprise messaging adapter. Lark, Slack,
  Microsoft Teams, DingTalk, and WeCom use this category.
- `consumer_im` identifies a consumer messaging adapter. Telegram and Discord
  use this category.

The category is catalog metadata. The adapter catalog, documentation, and
Console use it to group adapters. It does not control identity admission,
authorization, routing, capabilities, or default policies. A binding does not
store the category; each catalog read gets it from the current adapter
declaration. A missing or unknown category makes the declaration invalid.

The Console edit read returns normal configuration values, omits every
adapter-declared encrypted value, and lists only the paths that already contain
a secret. A binding update keeps the stored encrypted value when its patch
omits that field or sends an empty value. The browser never receives the stored
secret.

Disabling a binding sets its enabled flag to false. It does not remove the
binding, its configuration, or the `(agent_uid, binding_name)` history key. The
Console hides disabled bindings by default and lets an operator show, edit, or
enable them again.

An enabled binding can still have an `unavailable_reason`. SignalsGateway then
rejects new input without deleting the configuration.

For a group message that does not address the Agent, the binding chooses one
policy:

- `ignore` stores nothing and does not wake the Agent.
- `record_only` stores the message but does not wake the Agent.
- `may_intervene` stores the message and can let the Agent decide whether to reply.

The default policy is `record_only`.

A CEL expression can filter input. An empty expression accepts all input.

## What an Adapter Must Provide

Plugins declare adapters under `signals_gateway.adapter`. The Plugin registry
loads declarations at startup, and `Ankole.SignalsGateway.Adapters` checks them.

An ingress adapter can declare these input capabilities:

- entry receipt
- entry lifecycle
- reaction changes
- provider actions

The adapter converts provider data to Ankole's common format before it calls
SignalsGateway. SignalsGateway rejects data that PostgreSQL cannot store before
it acknowledges the provider.

Provider data and stored JSON use string keys. The outer Elixir input map uses
atom keys. `Ingress` converts inner JSON keys once and rejects mixed or
colliding keys.

An outbound adapter can declare these capabilities:

- `post_entry`
- `reply_entry`
- `edit_entry`
- `delete_entry`
- `add_reaction`
- `remove_reaction`
- `divider`
- `card`
- `outbound_reconciliation`

Every outbound adapter implements `send/1`. An adapter that declares
`outbound_reconciliation` also implements `reconcile/1`. Callback result maps
use atom keys.

SignalsGateway filters provider-visible text immediately before it calls an
outbound or reply-preview adapter. The filter replaces the exact RuntimeFabric
worker authentication key and the declared or custom WorkerEnv secrets of that
Agent. It does not redact content only because it looks like a JWT, bearer
token, private key, or credential assignment. If it cannot resolve the
configured secret set, it does not call the provider adapter.

Two values stay outside the set. A secret shorter than 12 bytes is not replaced,
because replacing a short common string would corrupt each reply. An
adapter-minted provider token is not replaced either: reading one requires the
provider to be reachable, which would make every reply depend on provider
health, and the adapter already gives that short-lived token to the Worker
shell.

Provider-specific setup and webhook behavior belong in each Plugin document.

## Receive a Capability Callback

A Worker can mint one callback capability for its current Agent session through
`create-webhook-cli`. It selects `one_shot` or `standing`, a label, and an
expiry time. `list-webhooks-cli` lists safe endpoint metadata, and
`cancel-webhook-cli` makes an endpoint terminal. The Console can list and
cancel endpoints for one Agent session. Neither list surface returns the
callback URL or its digest.

The callback path is
`/webhooks/v1/event-callbacks/wh_<43-character-base64url-token>`. Creation
returns the full URL once. PostgreSQL stores only its SHA-256 digest. A request
body can contain at most 1 MiB. SignalsGateway stores only `content-type`,
`x-hub-signature-256`, and headers whose names start with `ce-` or `x-github-`.
It discards authentication and all other HTTP headers. Ankole redacts
`/webhooks/v1/event-callbacks/*` in its request logs. An ingress, proxy, or CDN
in front of Ankole must apply the same redaction to its access logs.

SignalsGateway checks the endpoint and writes its consumer record in one
PostgreSQL transaction before it returns success. The record is a
`webhook.received` ActorEvent by default. If the endpoint names an automation
job, the record is a durable run that contains the same CloudEvents envelope.
A `one_shot` endpoint accepts one callback. A `standing` endpoint accepts each
delivery with at-least-once semantics and does not deduplicate it. A callback
to a known terminal endpoint returns success without a new record. An unknown
capability returns 404.

`create-webhook-cli --automation-job-id <id>` binds a new endpoint to an active
job for the same Agent. Endpoints do not support rebinding. The Agent cancels
the old endpoint and creates a new one.

The capability authorizes a wake-up only. Its headers and body are untrusted
input. The Agent must read the external system's authoritative state before it
makes a consequential change. The owning Agent Plugin must create, reconcile,
and remove the external task or hook.

## Receive an Event

Adapters call `Ankole.SignalsGateway.Ingress` to report a new message, removal,
reaction, or provider action.

Entry receipt follows this sequence:

1. Resolve the binding.
2. Convert the input to `IngressFact`.
3. Apply the binding filter.
4. Admit the author (see "Admit the Author" below).
5. Update the local provider copy when the policy permits it.
6. Update or finalize an inbound batch when the entry is IM traffic.
7. Write an ActorEvent when the Agent must do work.
8. Notify ActorRuntime after the transaction commits.

A filtered event returns `filtered` successfully. SignalsGateway stores no
provider copy or ActorEvent for it.

## Admit the Author

`IdentityAdmission` maps the entry author to a Principal before any durable
write. Adapters supply candidate subject ids in stability order plus a display
name; they do not resolve or create Principals themselves.

Identification is automatic and best effort. An existing platform-subject
binding for any candidate id wins, then the owner of the platform-reported
email, then the owner of the mobile number. When the exact ids miss and the
adapter declares an `author_hydrator`, the gateway fetches the sender's contact
profile once to feed the contact match. An identity provider that cannot
auto-map simply has no matching rows; that case needs no declaration.

What an unmatched sender means is the binding's `unmatched_sender_policy`:

- `manual_review` (default): the sender gets no processing at all — no
  provider copy, no inbound batch. A message that
  addresses the Agent records one row in `identity_mapping_requests` and
  answers with one fixed localized notice that tells the sender to ask an
  administrator to bind the account. Unaddressed group chatter from an
  unmatched sender is ignored silently.
- `create_standalone`: the gateway creates a standalone human Principal for
  the sender and serves them at once.

A sender whose Principal is disabled is ignored without a notice.

Every admitted sender also joins the binding's `signal_source` AuthZ group
(`signal_source:<agent_uid>:<binding_name>`), so permission policy can address
"users of this signal source". Directory sync maintains the matching
provider-wide group (`<provider_id>:members:all`); the difference between the
two expresses "third-party users of a source".

Reactions and provider actions do not pass identity admission. A card action
resolves its operator through the reply-interaction flow instead.

Every direct message gives the Agent explicit input.
A structured Agent mention makes a group message explicit.
A reply target that points to the Agent also makes the group reply explicit.
A human reply in a provider thread where the Agent has already written an entry
also gives the Agent explicit input.

Commands are valid only for explicit Agent input.
The gateway ignores command-like text in an unaddressed group message.

Reactions update the stored provider message but do not wake the Agent. A
reaction for an unknown message returns `ignored_unknown_entry`.

Removal deletes the stored provider message and creates a tombstone. The
tombstone blocks a late copy of the removed message for 24 hours.

A provider acknowledgement confirms receipt only. It is not an Agent reply and
cannot contain model-generated text.

## Resolve a Reply Interaction

A clarification interaction is durable state in the source ActorEvent
checkpoint. The first authorized callback for the current interaction changes
it from `pending` to `answered`, stores the normalized answer and operator, and
creates one `signal.action.invoked` ActorEvent. A repeated callback does not
create another event.

A newer human message or control command can change a pending interaction to
`superseded`. An answered or superseded interaction cannot return to `pending`,
even if an older provider checkpoint write finishes later.

The durable state projects each terminal result into `ReplyPresentation`.
An answered projection contains bounded plain display text from the accepted
answer. A superseded projection contains no answer. Adapters can choose how to
render this projection, but they do not decide which callback wins.

## Combine Nearby Messages before Waking the Agent

SignalsGateway can combine nearby chat messages into one ActorEvent. It keeps a
separate provider copy of every original message.

Addressed batches use adaptive settle windows:

- Normal text waits 1,000 milliseconds.
- Attachments wait 1,200 milliseconds.
- Long text waits 2,000 milliseconds.

Neutral text keeps a 600 millisecond settle window. An attachment does not make
an otherwise neutral group message address the Agent.

An adapter that must fetch attachment bytes first writes a pending attachment
observation. While it holds the existing entry lock, SignalsGateway assigns each
new attachment a PostgreSQL sequence ID that starts at 10000. A later
observation with the same source entry ID and provider reference reuses that ID
and replaces the pending state with `complete` or `failed`. The attachment
window starts at the pending observation, not after the download. An open batch
waits for all pending attachments, with a four second materialization cap.

An addressed batch accepts at most eight entries.
Its normal text budget is 4,000 characters.
Long-text continuation can extend the batch to 8,000 characters.

For `may_intervene` messages, the batch waits 15 seconds after the newest
message and never remains open longer than five minutes.

A `may_intervene` ActorEvent stores a hash of the current conversation scene and
expires five minutes after the batch closes.

Immediately before execution, ActorRuntime checks the expiry time, current
binding policy, and scene hash.

ActorRuntime completes stale events without calling a model. It also skips an
older event when a newer event covers the same Session and channel.

### Ambient Judgments and the Channel Cursor

The Worker recognizer reports one action through the
`signal_channel.ambient_judgment.record` RPC operation before a visible turn
starts or the event completes silently. The action is `NOOP`,
`FOREGROUND_REPLY`, `NEW_WORK`, or `HANDOFF`. `NEW_WORK` also reports whether a
direct human request, a standing order, or neither source authorizes the work.
The recognizer never creates a Job.

The ambient admission transaction gives the recognizer at most eight live Job
candidates. Every candidate belongs to the same Agent, owner Session, signal
channel, and binding. If more candidates exist, the list is incomplete and
`HANDOFF` is unavailable.

The judgment operation rechecks the binding, expiry, and scene hash. One
transaction stores the first canonical judgment, advances the channel
`ambient_judged_until` cursor to the batch watermark, and applies an accepted
`asked_by` attribution. A `HANDOFF` transaction also locks the exact live Job,
rechecks its owner Session and reply route, and appends one idempotent
`command.steer` that contains only the new messages. A retry returns the first
action and target instead of replacing them.

The ambient payload splits observations at the cursor. `observed_messages`
holds only messages after the cursor, merged with the triggering batch.
`backdrop_messages` holds up to ten already-judged rows for continuity. A
superseded event never judges its messages; they stay in the next event's
`observed_messages` window.

An accepted `asked_by` names one mirrored human message in the judged batch.
The control plane stores it on the ActorEvent, and outbound replies anchor to
that entry instead of the batch tail. A failed validation records a degraded
attribution and the wake stays proactive.

`FOREGROUND_REPLY` cannot create or respawn a Job. `NEW_WORK` without a direct
request or matching standing order starts a confirmation-only Text Turn with
no local or provider-hosted tools. An authorized `NEW_WORK` enters the normal
owner Text Turn, which still applies the standard approval and Job policies.

### Channel Standing Orders

A channel row can hold member-set standing orders: durable free-text policy
for proactive behavior in that room. Any channel member sets or clears them
through the Agent with the `set_channel_standing_orders` tool, which records
the asking author; the console reads and writes them through the
signal-channel standing-orders endpoints. Orders drive behavior only on
bindings whose group message mode is `may_intervene`: only there do envelope
payloads carry them, the recognizer prompt renders them as room policy, and
the main turn shows them beside the channel context. On other bindings the
stored text stays inert.

## Deliver Work to an Agent

ActorEvent payloads use CloudEvents 1.0 envelopes. The envelope preserves
normalized session, channel, entry, command, action, and lifecycle data.

Common ActorEvent types include:

- `im.message.addressed`
- `im.message.may_intervene`
- `signal.action.invoked`
- `signal.entry.removed`
- `command.new`
- `command.steer`
- `command.llm_help`
- `command.llm`
- `check_back_later.wakeup`
- `cron.fire`
- `webhook.received`
- `background_agent_job.completed`
- `background_agent_job.failed`
- `background_agent_job.waiting`
- `workflow.run.completed`
- `workflow.run.failed`
- `workflow.run.attention`
- `workflow.task.dispatch`
- `workflow.task.wakeup`
- `workflow.task.message`

`input_state` is `open` or `dead_letter`. Normal completion sets `completed_at`
and keeps the row as history.

### Async Work Units

BackgroundAgentJobs, Workflow runs, and Workflow tasks are async work units
that follow one actor contract on top of ActorEvents:

1. **Address and ownership.** The session id is the address. The
   `owner_session_id` recorded at creation is the parent: a main session owns
   its Jobs and runs, a run owns its task calls, and a task session owns the
   Jobs it delegates. Tool access stays Agent-scoped; the tree only routes
   signals.
2. **Mail in.** A parent sends asynchronous, idempotent mail
   (`command.steer` for Jobs, `workflow.task.message` for tasks). Mail wakes a
   hibernating unit and queues behind a live turn. Bounded synchronous
   observation (`wait_reply`) is a per-kind capability, not part of the
   contract.
3. **Signals up, one level.** Each unit emits exactly one idempotent terminal
   event to its parent, plus at most one live attention signal
   (`background_agent_job.waiting`, `workflow.run.attention`) when it cannot
   proceed without input. An intermediate owner coalesces: a run aggregates
   task outcomes into one terminal event and rate-limits attention with an
   hour-bucket source id. Progress is never pushed; parents pull through the
   show tools.
4. **Durable handoff.** Terminal payloads carry enough durable fact that the
   dead-letter notice can deliver the outcome without the Agent runtime that
   failed to relay it.

Hibernation is state, not process: a sleeping Workflow task is a durable row
plus a scheduled wake event, and holds no Worker resources. See
[Workflow](Workflow.md) and [BackgroundAgentJob](BackgroundAgentJob.md) for the
per-kind lifecycles.

ActorRuntime orders open events with `queue_sequence` for each Session. Each
delivery row records one worker attempt and its turn fence.

An `actor_session_workspaces` row identifies a real Actor session. Some Actor
sessions, such as Background Agent Jobs, do not have an AIGateway conversation.
The daily reset selects an active conversation only when its subject and key
match an Actor session workspace. It also excludes Background Agent Job
execution sessions. AIGateway conversations that store internal traces do not
enter this lifecycle.

At the configured 04:30 local boundary, daily reset enqueues one
`session.reset_due` lifecycle barrier for each due session. The barrier waits
behind earlier work. It then ends the current conversation and creates the
successor under the same session key.

A Worker `actor_turn.abort` leaves the ActorEvent open. ActorRuntime tries again
and invalidates the old turn fence.

`/llm` creates `command.llm_help`. ActorRuntime returns localized usage plus
the current Agent's custom model names and descriptions. This command does not
start a worker Turn, interrupt live work, or supersede a pending interaction.

`/llm <profile> [message]` creates `command.llm`. The profile and stripped
message body are separate ActorEvent fields. A profile with no message is a
valid worker Turn. The event queues as normal input when another Turn is live;
it does not steer or cancel that Turn. ActorRuntime resolves the custom profile
for this Turn only. The next normal input uses `primary`. `/retry` copies the
logical profile from the original ActorEvent and resolves its current binding.

A bare `/retry` controls only the live Turn in its current Session. Retrying a
terminal Turn requires an exact target: the user replies to that Agent message
with `/retry`, or sends `/retry actor-event::<id>`. Ingress resolves a replied-to
provider message through its succeeded durable-reply Outbox row. It does not use
the provider thread root or select a recent channel or Session event. An
explicit ActorEvent id must have a visible durable reply in the invoking
binding and channel. If the local Entry mirror is missing after a confirmed
provider send, the Outbox row also makes an unmentioned group reply explicit.
Ingress does not invent the missing reply content.

Ingress assigns an exact retry command to the target ActorEvent's Session before
it appends the command. ActorRuntime therefore serializes the command and the
replacement under the existing single-Session lock. It revalidates the exact
terminal target and either replays that ActorEvent or refuses; it never selects
a substitute. The replacement keeps the target event's input, execution route,
and frozen scheduled delivery. It takes `sender_key` from the retry command, so
the user who requested the new execution is its runtime requester; the replayed
payload still contains the original input author. A target that is no longer
the Session tail, crosses a conversation reset, or contains unsafe external
effects cannot be replayed.

When a command does not identify an exact target, the reply explains the two
supported target forms. When a resolved target can no longer be replayed, the
reply says to send the original request again. A `command.retry` control row
does not itself advance the retry tail. A successful terminal retry appends a
replacement ActorEvent, and that replacement does advance the tail. All other
intermediate ActorEvents remain retry fences.

After five retryable abort results, ActorRuntime moves the event to `dead_letter`.
For a visible chat message, the same transaction records a localized failure
notice for the provider. The notice hides the Worker error by default. When the
installation-wide `signals_gateway.show_dead_letter_error_details` AppConfigure
setting is `true`, it appends a bounded and redacted error preview. If the
channel takes no replies, or its channel or binding row is deleted, the notice
has no route. ActorRuntime then logs the skipped notice and keeps the
`dead_letter` row as the record. It does not fail the transaction, because that
transaction can also be a Worker takeover.

SignalsGateway rejects a late result while the source message has an active
tombstone. A removed message cannot produce a later reply.

## Choose How to Reply

Each mirrored channel has one `reply_mode`:

- `none` permits no provider-visible output.
- `channel` permits a top-level provider post.
- `entry` permits a reply that targets a source entry.

The commit uses `reply_mode` and the source entry. Both are durable rows. A
final Agent answer normally becomes `reply` for an entry-capable channel. It
becomes `post` when only channel output is available. The commit never guesses
a route or a message to reply to.

The send uses the adapter's declared operations. The commit does not, because a
plugin can be absent when the intent is stored, and a failed commit also fails
the transaction that stores it. If the adapter cannot reply to an entry but can
post, the dispatch records `post` on that row and sends it. Other unsupported
route or capability combinations produce an `unsupported` outbox state.

A channel with `reply_mode: none`, or one whose channel or binding row is
deleted, can hold no provider-visible message at all. A Turn that ends on such a
channel completes and stores no outbox row. Its answer stays in the AIGateway
transcript, and one warning names the actor event, binding, and channel. The
Turn does not fail, because a failed Turn is retried and every retry costs
another model call while the route stays exactly as unreachable.

## Store a Reply before Sending It

When an Agent turn ends, SignalsGateway stores every provider operation before
it sends anything. The same transaction completes the ActorEvent.

A `cron.fire` event can contain more than one delivery target. One completion
uses the same final AIGateway message and stores one outbox row for each target.
The target tuple contributes a stable hash to the outbox key, so two channels
on the same binding remain separate idempotent operations. Each row keeps its
own status, attempt count, error, deadline, and provider result.

The primary target can finalize the live preview. Other targets use top-level
posts with the same final text and attachments. They do not carry the mutable
reply presentation or share the primary source entry and preview state. A
missing binding, channel, adapter, or provider failure affects only that
target's dispatch; it does not roll back the Turn completion or another
target's intent. The dispatcher and every adapter still process one row and one
provider target at a time.

Outbox operations are:

- `post`
- `reply`
- `edit`
- `delete`
- `reaction_add`
- `reaction_remove`
- `divider`
- `card`

Outbox states are:

- `created`
- `sending`
- `succeeded`
- `failed`
- `unsupported`
- `unknown_after_send`

The dispatcher claims a row in one transaction, calls the provider without a
database lock, and then stores the result in another transaction.

Retryable failures use delays from five seconds to five minutes. Every delivery
class stops at `max_attempts`, which defaults to ten. The row remains stored with
an `exhausted` recovery state and no next deadline.

An adapter can classify a durable reply failure as `permanent` or
`operator_action_required`. A permanent failure stops immediately. An
operator-action failure stays blocked until the binding is saved after a repair.
That save gives the same row one more provider call. An explicit
`requeue_outbox` action also gives one stopped durable row one more call; it does
not reset the attempt audit or create another intent.

The Signal Routing page in Console lists the latest 100 stopped durable replies.
For a safely requeueable row, its Retry action calls `requeue_outbox` for that
same row, so an operator can grant one provider call without creating a second
reply intent. A row without visible reply text remains visible but has no Retry
action.

A `sending` row can recover after 60 seconds. SignalsGateway asks the provider
for its result only when the adapter supports that check and has enough IDs.

Otherwise, SignalsGateway sets `unknown_after_send`. If the row is a visible
durable reply, SignalsGateway writes a localized possible-duplicate notice into
that same reply and retries only inside its remaining attempt budget. The notice
stays on an explicit requeue. An uncertain operation without visible reply text
stops because it cannot tell the recipient that a resend can duplicate the
operation.

After provider success, SignalsGateway updates its copy of the provider message.
It also links a final reply to `ai_message_id` when available.

When an exact `/retry` supersedes a completed or failed turn, the same actor
transaction stores one delete outbox intent for each known provider reply. A
completed Response also becomes `retracted`; a failed Response remains an error
audit fact. A provider deletion failure does not stop the replacement turn. The
outbox records its retries and final result.

## Show Progress before the Final Reply

A live preview can show model progress, but Ankole can lose it. It is not the
final reply record.

Agent Computer sends progress text as an i18n key with bounded display
bindings. `ReplyPresentation` resolves the key with the installation locale
before it stores or renders the projection. It accepts a literal label from an
older Worker, but new tool activity, Turn phases, memory receipts, and schedule
receipts do not own translated text.

The preview follows one immutable AIGateway Turn stream. Its presentation owner
is one ActorEvent and can change when `/steer` adds a visible reply fragment.
An adapter updates only the provider message that belongs to the current owner.

After the first successful preview, the ActorEvent stores the provider message
ID. The final outbox can edit that message instead of sending another one.

After an active `/steer` event is stored, the current owner stays active. It
continues to receive presentation updates from the model round that is already
running. The stored delivery and `mailbox_updated` message only queue the steer;
they do not change the preview owner.

When the Worker sends `turn_accepted` for the steer revision, SignalsGateway
freezes the old owner with the provider-neutral `continued` state. This state
keeps displayed answers, plans, results, and activity, removes transient
thought, and does not mark a live plan as completed or cancelled. After that
provider update commits, SignalsGateway makes the steer ActorEvent the new
owner. If no old provider message exists, it switches the owner without creating
an empty continued message. This prevents an old provider call from running
behind a card that SignalsGateway already marked as continued.

An exact-revision `turn_accepted` retry repeats the same idempotent owner
handoff. A redelivered envelope can repair a failure between the durable
acceptance update and the preview operation. A delivery that terminal
completion already superseded cannot trigger a late handoff.

If the old provider update fails, SignalsGateway persists the intended
`continued` checkpoint with `refresh_pending` and switches the owner. The
existing preview recovery path then finishes the old card. A provider failure
does not block a durable steer from reaching the Worker.

Every owner checkpoint stores the immutable Turn stream ID and an owner
generation. A provider task can write a checkpoint only for its generation.
This fence prevents an old update from replacing a newer card after a handoff.
Consecutive accepted steer events repeat the same owner change. If the current
Turn finishes at an older revision, SignalsGateway does not hand off the owner.
It supersedes the stale delivery attempt, keeps the steer ActorEvent open, and
starts that event as the next Turn.

If the same sender adds a contiguous attachment while that ActorEvent is still
running, SignalsGateway can supersede the incomplete input. A reply edge to
another message or another structured mention prevents this association. The
gateway retracts the generating Response, invalidates the old turn fence, adds
the attachment to the same ActorEvent, and runs that event again after
materialization. The preview edits the same provider message to say that the
full request is being analyzed again. Late output from the old fence cannot
replace the new run.

SignalsGateway does not replay a turn after it observes a tool call, a tool
result, or a committed outbox operation. Those facts can represent an external
write whose result is unknown. In that case the attachment becomes a new
addressed turn after the current turn. The ActorEvent row lock decides a race
with normal completion: supersession wins by invalidating the old delivery, or
completion wins and the attachment becomes the next turn.

The final reply waits up to 30 seconds for the preview to finish. If preview
delivery fails, the stored outbox operation still sends the answer.

At Turn completion, the latest visible steer delivery with `revision <= R`
owns the final reply and outbox. A steer delivery with `revision > R` stays open
and starts the next Turn. An aborted attempt keeps all ActorEvents and preview
checkpoints for retry.

## Which Component Does What

SignalsGateway does these actions:

- accept provider input in Ankole's common format
- store the latest known provider state
- write ActorEvents
- insert durable automation job runs for bound callbacks
- deliver work to Agent sessions
- store and send provider operations
- update temporary reply previews

AIGateway stores model Responses and their continuation chains.
Principal identifies the human or Agent responsible for an action.
AuthZ checks permissions and stores Principal groups.
The Plugin registry finds adapters and starts them.
RuntimeFabric carries worker messages and checks their protocol.

## Rules

- A provider redelivery cannot create a duplicate ActorEvent for the same binding.
- Each provider operation stored in PostgreSQL has one outbox key.
- One scheduled result has one target-scoped outbox key for each delivery target.
- A provider acknowledgement never depends on model execution.
- A provider mirror records provider state and never replaces an ActorEvent.
- A live preview never replaces a stored final reply.
- One reply-preview generation can update only its presentation owner.
- A removed source cannot commit a late Agent result while its tombstone is active.
- A queued `may_intervene` event cannot run after its scene or binding policy changes.
- An uncertain visible final reply can retry only inside its attempt budget and
  tells the recipient that the recovered reply can be a duplicate.
