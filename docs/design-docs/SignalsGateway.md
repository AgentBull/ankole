# SignalsGateway

SignalsGateway connects external messaging platforms to Agents. It records
incoming messages, starts Agent work, and sends the resulting replies.

AIGateway separately stores model Responses and their history.

## Platform application ownership

A platform application used by credential-bearing configuration belongs to one
tenant. Bindings and identity providers with directory sync share the existing
binding-assignment lock during saves, including disabled configurations. The
same tenant can share an application where its adapter permits it. A different
tenant receives a conflict; an unverifiable credential fails without a write.
Login-only identity providers do not participate because callbacks use the login
transaction's tenant and those configurations neither open message connections
nor synchronize a directory.

Slack resolves a bot token through `auth.test` and then `bots.info` to obtain the
stable `app_id`. Socket Mode validates the connected application's identity
before acknowledging or dispatching events. Discord and Telegram resolve stable
bot IDs through their existing platform APIs. Token rotation cannot change the
application's tenant. Repair or remove an invalid old credential before saving
a cross-tenant configuration whose ownership cannot be verified.

Slack and Teams binding configuration keys hash `[agent_uid, binding_name]`.
They remain in AppConfigure's global storage because the key is globally unique;
the owning Agent's deletion removes the configuration. Adapter processes enter
the binding's tenant before reading or writing business records.

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
| `actor_session_workspaces` | Stable workspace identity and writer epoch for one Agent session |
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
- `consumer_im` identifies a consumer messaging adapter. Telegram, Discord,
  LINE, and WhatsApp use this category.
- `email` identifies the Email adapter, whose senders are identified only by
  explicit `email` identity bindings.

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

- `ignore` skips identity admission and does not mirror the message or wake the Agent. The inbound batch retains the complete message and raw provider data for later reply references.
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

An adapter that receives events over long connections declares its connections
with `use Ankole.Plugins.ConnectionLifecycle`. The adapter builds one connection
spec for each enabled binding. If its identity provider shares the connection,
the adapter also builds one spec for each active identity provider.
`ConnectionLifecycle` merges the specs that have the same connection key,
refuses two specs for one key that have different app secrets, and supervises
one connection process for each key. Lark, Slack, and DingTalk use the SDK
client as this process. Their clients are temporary children. If a client
exits, `ConnectionLifecycle` restarts that key immediately once, then waits
5 seconds and 30 seconds between further attempts. Other keys stay connected.
It stops a process that no spec wants only after a pass that read all bindings
and identity providers without an error.

The connection Registry keeps the last successful start config and consumers.
A new reconciler can use them to resume a connection while its binding is
blocked. A stop removes those arguments, so a late retry cannot restore a
connection that the successful snapshot no longer needs.

An adapter can also keep its own provider fact on the channel mirror through
`update_channel_metadata`, which applies the adapter's function to the stored
channel metadata under the channel row lock that ingress takes. A monotonic
value, such as the newest provider time the adapter has seen, therefore cannot
move backwards through a concurrent or redelivered event.

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

`send/1` receives provider operations only. When an adapter also declares a
reply-preview module, SignalsGateway finalizes a durable AI reply row through
that module instead of calling `send/1`: it reloads the source ActorEvent,
builds one request from the row and the stored checkpoint, and records the
result as the row outcome. Reconciling such a row repeats the same finalize,
because the preview checkpoint records every provider mutation. A finalize can
answer `unknown`, which the row records as `unknown_after_send`.

The checkpoint keys that name a provider surface belong to the reply-preview
module. SignalsGateway asks that module which provider ids the checkpoint holds
and whether the surface still accepts updates; it never reads provider
vocabulary from the checkpoint. A provider entry that the module reports is a
deletion target for `/retry` and the anchor that an inbound card callback must
name. A module can also answer that the surface cannot show a presentation and
plain text must go through the durable outbox instead; SignalsGateway then
stops the preview without a retry.

When a reply-preview module sends its first provider message, it records the
sent checkpoint and the first source entry in one transaction. The first source
entry wins, and recording the same entry is idempotent. A conflict with another
source entry keeps the sent checkpoint committed and returns the source error.
Recovery uses that checkpoint and does not send the completed message again.

A version 2 reply-preview checkpoint keeps lifecycle, interaction, owner,
deadline, and presentation fields at the top level. It keeps provider fields
under `adapter_state`. Reply-preview modules receive one flattened logical view,
so they do not know how PostgreSQL separates the fields. A flat version 1 row
remains readable. Its next checkpoint write converts it to version 2 and
replaces the complete adapter state. The legacy reader can be removed only
after every supported upgrade has run and PostgreSQL contains no flat
reply-preview checkpoint.

SignalsGateway filters provider-visible text immediately before it calls an
outbound or reply-preview adapter. The filter replaces the exact
operator-configured WorkerEnv secrets of that Agent. It does not redact content only because it looks like a JWT, bearer
token, private key, or credential assignment. If it cannot resolve the
configured secret set, it does not call the provider adapter.

Two values stay outside the set. A secret shorter than 12 bytes is not replaced,
because replacing a short common string would corrupt each reply. An
adapter-minted provider token is not replaced either: reading one requires the
provider to be reachable, which would make every reply depend on provider
health, and the adapter already gives that short-lived token to the Worker
shell.

A plugin whose provider delivers events over HTTP declares a
`signals_gateway.webhook_handler`. The host routes POST and GET requests to
`/webhooks/v1/<handler_id>/<instance_id>/<kind>` to that handler for each
declared kind and passes the request method, the parsed body, the query, the
headers, and the exact request bytes. A GET carries no body, and a provider
uses it to verify that it owns the callback URL. The handler authenticates the
provider itself, usually with a signature over those bytes, and completes
durable ingress before it returns success.

Provider-specific setup and webhook behavior belong in each Plugin document.

## Receive a Capability Callback

A Worker can request one callback capability for its current Agent session through
`create-webhook-cli`. It selects `one_shot` or `standing`, a label, and an
expiry time. `list-webhooks-cli` lists safe endpoint metadata, and
`cancel-webhook-cli` makes an endpoint terminal. The Console can list and
cancel endpoints for one Agent session. Neither list surface returns the
callback URL or its digest.

The callback path is
`/webhooks/v1/event-callbacks/wh_<43-character-base64url-token>`. Creation
returns the full URL once. SignalsGateway generates the token for each new
endpoint. PostgreSQL stores only its SHA-256 digest. A request
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
profile once to feed the contact match. A hydration failure, or a profile
without email and mobile, is logged as a warning and the match continues
without it. An identity provider that cannot auto-map simply has no matching
rows; that case needs no declaration.

The platform-subject namespace of a binding is the identity provider it
references. Enterprise IM adapters declare an `identityProvider` field of type
`identity_provider` with the identity-provider adapter id; the host owns the
rule in `Ankole.SignalsGateway.SubjectNamespace`:

- an identity provider id names that provider's namespace;
- the standalone value `:standalone` keeps the adapter default namespace;
- no reference adopts the single configured provider of the adapter, so a
  provider added after the binding takes effect at once; with none or several
  providers the adapter default applies.

The binding catalog serves the field as a select over the configured
providers, disabled ones included, plus the standalone choice; it is required
only while several providers exist and is omitted while none exists. A config
write rejects a missing reference while several providers exist and rejects an
unknown reference; enabling or moving a binding sends no config and keeps its
reference. Identities recorded under the adapter default before a provider
existed stay in that namespace until an operator binds them.

Reply references determine whether an IM message addresses the Agent before
identity admission. A reply to this Agent or a reference in a thread where
this Agent participated still requires admission. Unaddressed group messages
with `ignore` skip admission: they do not create or refresh a Principal,
identity binding, or group membership. Their complete message and raw provider
data remain in the inbound batch for later references. Other group policies,
direct messages, and addressed messages use the admission rules below.

What an unmatched sender means is the binding's `unmatched_sender_policy`:

- `manual_review` (default): the sender gets no processing at all — no
  provider copy, no inbound batch. A message that
  addresses the Agent records one row in `identity_mapping_requests` and
  answers with one fixed localized notice that tells the sender to ask an
  administrator to bind the account. The notice outbox row records the
  refused sender under `metadata.unmatched_sender`, because the message it
  replies to is never mirrored and an adapter whose route needs a recipient
  must read it from the row. Unaddressed group chatter from an
  unmatched sender is ignored silently.
- `create_standalone`: the gateway creates a standalone human Principal for
  the sender with a new opaque UUIDv7 UID and serves them at once. An external
  subject equal to an existing Principal UID does not select that Principal.
  Without an identity binding or verified contact match, the standalone
  policy creates a separate account; `manual_review` holds the sender for
  an operator to bind.

For messages that require admission, a sender whose Principal is disabled is
ignored without a notice. Admission
locks the Human and captures `access_version` before it stores the observation.
Batched and Ambient work retain that observed version; later contact updates
cannot renew it. ActorEvents store `authorization_kind`, `human_uid`, and
`human_access_version`, as defined in [Human Offboarding](HumanOffboarding.md).
Each new execution attempt checks these fields before it admits an input.
An already admitted run can finish. Revocation removes only the disabled
Human's pending work from a shared Agent or Session.

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
and replaces the pending state with `complete` or `failed`. A completed
observation carries `blob_ref` and the drive `path` of bytes that the file
service holds ([Files](Files.md)). A later observation without them never
replaces a stored attachment, so a redelivered event cannot take a completed
download away. The stored bytes serve every Agent, so with an adapter that
writes the pending observation (Lark, Slack, Discord, Telegram, WhatsApp,
LINE, and email), an attachment that one Agent's adapter downloaded is not
downloaded again for another Agent. DingTalk, WeCom, and Microsoft 365 write no
pending observation and download the attachment for each Agent; the file
service keeps one copy of the bytes. The gateway names the content in each
Agent's drive when it mirrors the entry and again before it delivers an
ActorEvent. The attachment
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

The control-plane ambient recognizer records one action through
`AmbientCuration.record_judgment/4` before a visible turn starts or the
event completes silently. This operation takes the Agent and Session key,
the event ID, and the validated route. It locks the same Session and event
before it checks current database facts. The Driver owns recognition and uses the light
model for a visible ambient reply. The action is `NOOP`,
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
- `input.revised`
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

Conversations orders open events with `queue_sequence`. Admission selects the
Main, Ambient, Scheduled, or WorkflowTask owner before it constructs a run.
Each owner supplies admission, tools, instructions, input, repair, termination,
and completion projection. Finite Outcome atoms share one classifier and are
encoded as strings only at storage and public boundaries.

One `:gen_statem` owns each Agent and Session through a `:global` name. Admission
selects Driver for a model loop or JobDriver for Codex Job supervision. Run does
not contain Job attempt fields. Their state is derived from PostgreSQL input,
Conversations' `conversation_round_states`, and the AIGateway Response tape. It retires after five idle
minutes. A new input wakes it immediately; the per-minute Reconciler repairs
lost wakeups, including runs that crashed after admission without another input.

`actor_session_workspaces` stores the stable workspace ID and epoch. Admission
increments the epoch and the trigger's `attempt_count` under the row lock.
Control-plane tool writes, round recording, and terminal commits check that
epoch in their transaction. Typed loop progress commits with the model request.
Tool results, local result effects, and consumed wait events enter the tape and
round state in one transaction. Recovery reads recorded todo state rather than
executing the Session tool again. Tool receipts hold committed control-plane results until
that transaction records them, so recovery does not repeat a domain write.

Recovery counts an appended input as consumed only when a complete row in the
visible run tape records it. Admission and preparation defer inbox messages.
After the tape is restored, the Driver processes the durable inbox before it
continues model or tool I/O. This includes a stop that arrived while the Driver
was absent. Short database transitions run in the state callback. Model streams,
tools, and Worker I/O use supervised tasks.

Tool definitions, results, waits, Driver state, and pending calls use typed
structs. Domain operations return explicit events for delivery. If the caller
still owns a transaction, delivery inserts a unique EnsureDriver job. An error
in an after-commit notification cannot replace a committed tool receipt.

The Driver runs ordinary and Workflow model requests on the control plane.
Environment tools request a Worker only when needed. WorkerAcquisition retains
one acquisition state across the Run and reuses a ready Workspace. WorkerRoute
owns route-error classification and marks unusable routes before it returns the
error. Tool declarations own receipt, delivery, activity, and description policy.
Control-plane Skill and Web tools serve both ordinary turns and Codex Jobs
through the same fenced read-tool RPC. Codex Jobs retain their Worker execution
and Job attempt budgets. A lost environment result is probed
on the current Worker; an unknown unsafe call is recorded as interrupted.

The daily reset enqueues a `session.reset_due` barrier at the configured 04:30
local boundary. It waits behind earlier input, ends the current conversation,
and creates its successor under the same Session key. Internal trace
conversations and Job execution Sessions do not enter this lifecycle.

A retryable provider-capacity failure waits 30, 120, 300, then 750 seconds.
Other retryable failures start at 5 seconds and double to a 120-second ceiling.
FailureDiagnostics owns failure categories and the canonical `retry_at`
DateTime. TurnErrorClassifier supplies the shared retry delay; API, log, and trace
boundaries encode timestamps once. The sixth admission writes input dead-letter state. After a crash, the Driver
uses the persisted `last_attempt_at` as the backoff start. A planned Driver
shutdown refunds one admission; a stale Driver refunds it on a best-effort
basis while its input stays open. Job failures use the Job owner's separate
claim and execution budgets.

`/llm` creates `command.llm_help`. Conversations.Commands returns localized usage plus
the current Agent's custom model names and descriptions. This command does not
start a worker Turn, interrupt live work, or supersede a pending interaction.

`/llm <profile> [message]` creates `command.llm`. The profile and stripped
message body are separate ActorEvent fields. A profile with no message is a
valid control-plane run. The event queues as normal input when another Turn is live;
it does not steer or cancel that Turn. Conversations resolves the custom profile
for this Turn only. The next normal input uses `primary`. `/retry` copies the
logical profile from the original ActorEvent and resolves its current binding.

A bare `/retry` controls only the live run in its current Session. Before any
tool call, it retracts the request and repeats the original input. After a tool
call, it cancels pending work, keeps the tape and committed results, and injects
the retry instruction on that tape. Retrying a
terminal Turn requires an exact target: the user replies to that Agent message
with `/retry`, or sends `/retry actor-event::<id>`. Ingress resolves a replied-to
provider message through its succeeded durable-reply Outbox row. It does not use
the provider thread root or select a recent channel or Session event. An
explicit ActorEvent id must have a visible durable reply in the invoking
binding and channel. If the local Entry mirror is missing after a confirmed
provider send, the Outbox row also makes an unmentioned group reply explicit.
Ingress does not invent the missing reply content.

Ingress assigns an exact retry command to the target ActorEvent's Session before
it appends the command. The Driver therefore serializes the command and its
replacement with the Session epoch. It revalidates the exact
terminal target and either replays that ActorEvent or refuses; it never selects
a substitute. The replacement keeps the target event's input, execution route,
and frozen scheduled delivery. It takes `sender_key` from the retry command, so
the user who requested the new execution is its runtime requester; the replayed
payload still contains the original input author. A target that is no longer
the Session tail, crosses a conversation reset, or shares its Response with
other inputs cannot be retried as one exact input.

Bare and targeted retries use the same history rule. A suffix that contains
tool calls or results stays visible. The replacement asks for another answer
to the original input, using the recorded results without repeating committed
effects. Only a suffix with no tool calls or results is retracted and replayed.
Failed Responses remain audit facts outside visible history. A target whose
failed Response contains tool fragments is still refused. Manual recovery is
required because these effects are outside the model's history.

When a command does not identify an exact target, the reply explains the two
supported target forms. When a resolved target can no longer be replayed, the
reply says to send the original request again. A `command.retry` control row
does not itself advance the retry tail. A successful terminal retry appends a
replacement ActorEvent, and that replacement does advance the tail. All other
intermediate ActorEvents remain retry fences.

An unretryable failure or exhausted admission budget moves the read input to
`dead_letter`. Run first records pending committed tool results in the tape.
For a visible chat message, the same transaction records a localized failure
notice for the provider. The notice hides the Worker error by default. When the
installation-wide `signals_gateway.show_dead_letter_error_details` AppConfigure
setting is `true`, it appends a bounded and redacted error preview. If the
channel takes no replies, or its channel or binding row is deleted, the notice
has no route. Conversations then logs the skipped notice and keeps the
`dead_letter` row as the record. It does not fail the transaction, because that
transaction also closes the run.

A conversation turn can also stop before any Worker attempt. When the Agent's
model profile is unavailable or the Agent is at its
[token quota](AgentTokenQuota.md), Conversations completes the read input in the
same transaction that preserves committed tool results and records one
localized notice for a channel-reply-eligible event. An ambient `may_intervene` event completes without a notice. A turn that
crosses the token quota while it runs reaches `dead_letter` through the normal
abort path, and its notice uses the quota text instead of the retry text.

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

Each dispatch deadline and its Oban job commit in the same domain transaction.
The existing minute Reconciler calls the Outbox owner to restore due dispatch
jobs that are missing. The query selects only outbox keys and tenant IDs. An
index excludes succeeded, unsupported, and stopped rows that have no automatic
recovery deadline. An available, scheduled, retryable, or executing job prevents a
new job, so recovery preserves the job's current deadline and retry count. A
discarded or pruned job does not stop delivery; the Outbox row owns that decision.
Recovery does not restart blocked, permanent, or exhausted deliveries.

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

A `sending` row can recover after 60 seconds. Only a durable AI reply with a
reply presentation and an adapter that declares `outbound_reconciliation` can
be reconciled. SignalsGateway repeats preview finalization when the source
ActorEvent and preview module are available; otherwise it calls the provider
reconciliation function.

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
completed Response becomes `retracted` only if the suffix has no tool calls or
results; otherwise the tape stays visible. A failed Response remains an error
audit fact. A provider deletion failure does not stop the replacement turn. The
outbox records its retries and final result.

## Show Progress before the Final Reply

A preview is a recoverable projection, separate from the durable final reply.
The Driver sends activity as an i18n key with bounded display bindings.
`ReplyPresentation` resolves it with the installation locale.

The stream identity stays on the trigger ActorEvent. Its reply owner is the
last input on that stream which `AIReplyPreview.channel_reply_eligible?/1`
accepts. Ordinary appended IM input and `/steer` use the same `continue_on/2`
handoff. `input.revised` and an internal retry instruction keep the previous
reply owner. Input that has not reached the model remains open for the next run.

Handoff freezes the old provider message with the `continued` state. It keeps
displayed answers, plans, results, and activity, removes transient thought, and
keeps live plans live. It then switches to the new owner. If no old provider
message exists, it creates no empty continued message. A failed provider update
stores `refresh_pending`; the existing recovery job finishes that old message.

Each checkpoint stores its stream ID and owner generation. Old provider tasks
cannot replace a newer generation. On Driver recovery, the tape identifies
already-injected input and the preview restores the persisted reply owner with
a new generation. Repeated input wakeups do not create another handoff.

An edit, attachment supplement, or withdrawal before a tool call cancels and
retracts the model request, then prepares the current input again. After a tool
call, the Driver keeps the tape, cancels pending work, and injects the revision.
A partial withdrawal follows this rule; withdrawal of the only input stops the
run. Committed effects remain visible to the model.

The terminal source check includes explicit input and referenced channel
context. If only a context message was withdrawn, the run stops and commits a
notice to a surviving input. The notice asks the user to send the question
again. It does not contain the old partial answer or the withdrawn text. If
explicit input was also withdrawn, the ordinary input-withdrawal rule wins.
The notice does not undo committed tool effects.

After a successful preview, the ActorEvent stores the provider message ID. The
final Outbox can edit that message. An adapter with no preview or edit support
gets one final message. The final reply waits up to 30 seconds for the preview;
a provider failure leaves the durable Outbox responsible for delivery.

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
- A conversation turn for an Agent at its token quota completes with a notice
  and starts no Worker turn.
