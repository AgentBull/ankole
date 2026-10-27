# Signals

Signals owns durable stimuli for Agent work. Every producer submits work by
calling `Ankole.Signals.accept/1` or `Ankole.Signals.accept_in_tx/1` with a
Signal that names its source, event identity, payload facts, authorization, and
execution target.

Surrounding domains own the adjacent boundaries: [Conversations](Conversations.md)
owns shared conversations, participants, public Messages, provider observations,
and external Delivery; [Sessions](Sessions.md) owns execution, input ordering,
recovery, and the link to model history; and [AIGateway](AIGateway.md) owns
model requests, Responses, and model session state.

## One Intake

`accept/1` runs in a top-level transaction (`Repo.transact_top_level/2`) and
returns `{:ok, %Ankole.Signals.Signal{}}` or `{:error, reason}`.
`accept_in_tx/1` returns the same result inside a caller-owned transaction; use
it whenever the stimulus must commit atomically alongside a Message, scheduled
execution, Job result, or Workflow result.

```elixir
Ankole.Signals.accept(%{
  source: "https://example.com/issues",
  id: "issue-42-revision-3",
  type: "issue.changed",
  subject: "issue/42",
  time: DateTime.utc_now(:microsecond),
  data: %{"priority" => "urgent"},
  target: %{agent_uid: agent_uid, session_id: "issue-triage"},
  sender: nil,
  authorization: Ankole.Principals.WorkAccess.service()
})
```

Alongside the public attributes, intake records a private `producer` marker.
Core control-plane code sets `kernel` when deriving a stimulus from a Message,
schedule, task, or control action, whereas generic CloudEvents and webhook
intake always set `external`. Event payload fields cannot choose this marker,
and it neither enters the CloudEvent envelope nor alters authorization; Sessions
checks it before interpreting internal event types. If two different producers
collide on the same source and event ID, intake returns an error and leaves the
already accepted record unchanged.

The canonical event fields are:

| Intake field | Stored field | Meaning |
| --- | --- | --- |
| `source` | `source` | Producer namespace |
| `id` | `source_event_id` | Stable event ID within that source |
| `type` | `type` | Stimulus type |
| `subject` | `subject` | Optional producer subject |
| `time` | `occurred_at` | Event time; acceptance time when absent |
| `data` | `data` | JSON event value, including arrays, scalars, and null |
| `extensions` | `extensions` | Additional CloudEvents context attributes |

Producers do not persist a separate raw envelope. Instead, `Signal.envelope/1`
reconstructs the CloudEvents 1.0 view from these columns, preserving extension
attributes without allowing them to overwrite canonical event fields.

During intake, Ankole resolves the target, validates the attributes, locks the
Agent's Session, allocates `queue_sequence`, and inserts the Signal. PostgreSQL
enforces uniqueness on `(tenant_id, agent_uid, source, source_event_id)`. If a
producer redelivers the same event—or if multiple routing rules match the same
event for the same Agent—intake returns the original Signal with its initial
target and facts. Updating a subscription later does not move an already
accepted Signal to another Session.

For batch writes, `accept_all/1` and `accept_all_in_tx/1` accept a list of
stimuli in a single transaction: intake locks all target Sessions in lock order
with one statement, checks existing Signals in one query, and writes new rows in
one bulk insert, issuing at most one sequence read and one wakeup job per
Session. If any stimulus in the batch is invalid, intake rejects the entire
list.

Every intake transaction also enqueues a durable
`Ankole.Sessions.Jobs.EnsureDriver` job without starting a Driver inside the
transaction. `accept/1` wakes the Session immediately after commit for low
latency, while `EnsureDriver` repairs any missed wakeup. If an outer transaction
rolls back, PostgreSQL discards both the Signal and its wakeup job, so callers
do not add custom intake or transaction hooks.

## Queue State

`Ankole.Signals.Signal` manages queue lifecycle transitions through
AshStateMachine across four states: `queued`, `running`, `completed`, and
`dead_letter`. Intake inserts work as `queued`; admission transitions it to
`running`, and deferring a retry returns it to `queued`. Completion can settle a
Signal from either live state—including an ambient `NOOP` that finishes without
starting a model turn. Once a Signal enters `completed` or `dead_letter`, it
never restarts; retrying terminal work creates a new Signal with a fresh source
event ID.

Two timestamps track scheduling and attempts without determining queue state on
their own: `available_at` records the readiness deadline, and `last_attempt_at`
records the latest admission (preserved across retry deferrals, though ambient
triage retries leave `last_attempt_at` empty until a full turn begins). Each
admission increments `attempt_count` once. Provider-capacity waits use a
separate counter, and refunding an admission never decrements a capacity
attempt.

Database constraints tie evidence columns to queue state: PostgreSQL requires a
completion timestamp only on `completed` rows, requires a dead-letter timestamp
and JSON-object reason only on `dead_letter` rows, forbids terminal columns on
live rows, and requires an admission timestamp whenever a row is `running`.
Single-row actions and bulk revocations run inside the caller's transaction and
tenant context without opening a nested transaction owner.

`Ankole.Signals` is the Ash domain that owns `Signal`, `Binding`, and
`WebhookEndpoint`. Other domains interact with Signals through three sets of
interfaces:

- **Domain defines and readers:** `get_signal`, `list_signals`,
  `update_metadata_signal`, `revise_input_signal`, `reauthorize_signal`,
  `remove_signal`, `get_binding`, `list_bindings`, `get_webhook_endpoint`,
  `list_webhook_endpoints`, and the Session queue readers `session_queue/3` and
  `session_status_signal/3`.
- **Transactional composition helpers (`*_in_tx`):** `accept_in_tx/1`,
  `lock_signal_in_tx/1`, `lock_session_signal_in_tx/2`, `lock_signals_in_tx/2`
  (accepting a keyword filter, queue order unless overridden by `sort:`, an
  optional `limit:`, and row-lock identity), `transition_in_tx/3` (advancing one
  locked Signal), `reset_attempts_in_tx/2`, `signals_for_entry_in_tx/4`, and
  `stop_human_work_in_tx/3` (revoking unstarted Signals for an offboarded
  Human).
- **Cross-tenant readers (`Repo.across_tenants/1`):** Signals exposes the
  `work_across_tenants` read action (`due_sessions_across_tenants/1` and
  `count_admitted_attempts_for_human/2`), while Bindings and WebhookEndpoints
  expose `lookup_across_tenants`.

Multi-step writes on Bindings and WebhookEndpoints—`assign_binding`,
`reassign_binding`, `put_cloud_binding`, `move_cloud_binding`,
`disable_binding`, `create_webhook_endpoint`, `cancel_webhook_endpoint`, and
`receive_webhook`—run inside `Repo.transact_top_level/2` in `Bindings` and
`Webhooks`. Console `/api/v2` routes expose generic actions for managing both
resources, and assigning a Binding refreshes the configuration cache after
commit.

Unresolved `dead_letter` Signals remain visible in operator access review.
However, review status is distinct from reauthorizable state: reviewing a
terminal Signal neither restarts it nor alters its recorded authority.

## Execution Target and Reply Route

Callers specify an explicit execution target in one of three forms:

| Target | Result |
| --- | --- |
| `%{agent_uid: uid, session_id: key}` | Work for that Agent and Session |
| `%{agent_uid: uid, conversation_id: uuid}` | Work for a participating Agent in that Conversation |
| `{:conversation, uuid}` | Work for the single Agent of a native Conversation |

A Conversation target resolves to the Session key `conversation:<uuid>`. Because
an external Conversation can include multiple Agents—each maintaining its own
Session and model state over the shared Conversation—external callers must name
`agent_uid` explicitly; the `{:conversation, uuid}` shorthand works only for
single-Agent native Conversations.

Generic event sources may target `main` or any ordinary named Session. By
contrast, `job:<id>` and `wf_task:<id>` identify private work-unit Sessions that
only their internal producers may dispatch or control; if a WebhookEndpoint or
Binding targets either prefix, validation fails with `invalid_signal_target`.

Delivery routing stays separate from execution targeting. `reply_route` can
carry `binding_name` (persisted as `reply_binding_name`), `conversation_id`,
`provider_thread_id`, and `provider_message_id`, while the Signal's `source`
continues to name the producer namespace. Internal producers never synthesize a
Binding to identify themselves, and a Binding does not own a Conversation.

When a public Message triggers a Signal, `message_id` stores that Message's
UUID, and batched IM Signals also list all contributing public Message UUIDs in
`data.message_ids`. These UUIDs always refer to `Conversations.Message` rows,
never provider message IDs or AIGateway message IDs.

Bindings, webhooks, CloudEvents, and core intake share `Signals.Target.parse/1`
to parse route targets into `{:conversation, uuid}` or `{:session, key}` while
rejecting mixed target maps, and `Sessions.Key.routable?/1` enforces the
private-work boundary. Reply routes remain independent delivery metadata.

`Signals.Types` declares which internal, code-produced Signal types supersede a
pending user interaction; any undeclared type—including external CloudEvents
types—leaves pending interactions open. During intake, Ankole acquires the
Session lock before inserting the Signal, applies interaction supersession
through `Delivery.Interactions`, and writes the durable `EnsureDriver` job in
the same transaction. Opening a late clarification checks the same superseding
type list. Only a kernel-produced `session.reset_due` Signal acts as a reset
barrier for an interaction answer. When an external provider deletes a message,
Ankole uses the `conversation.message.removed` lifecycle type.

For post-commit wakeup, `accept_in_tx/1` returns the accepted Signal as a
pending publication token so the outer transaction owner can call
`Signals.publish_committed/1` in the same process after commit. `accept/1`
wires that same call into `after_commit` on `Repo.transact_top_level/2` (and
raises `Ankole.Errors.Framework.NestedOperation` if called inside an open
transaction). `publish_committed/1` broadcasts a Session state update, triggers
the `ensure_driver/1` fast path, and publishes ready Signal IDs on the Session
input topic. Drivers always load work from PostgreSQL, so neither a raw
observation nor a PubSub message can fabricate a second input. Because the
publication guard inspects only the current process's transaction state,
transactional code must never spawn a Task to publish pending Signals.

## Attribution and Runtime Scope

When a stimulus has an accountable Principal, `sender` identifies them and
`WorkAccess` snapshots `authorization_kind`, `human_uid`, and
`human_access_version`. Callers that already hold a frozen authorization
snapshot pass it through unchanged, while new Human input captures the Human's
current version so later identity edits cannot revive stale work.

Internal service tasks and capability callbacks carry an explicit service
authorization snapshot, whereas an unmapped external sender stays
`review_required`. Source routing rules, ambient room observations, and event
payload fields can never borrow the Human permissions of a Binding's creator.
Sessions re-verifies the frozen snapshot before starting each execution attempt,
while runs that are already admitted finish normally; see
[Human Offboarding](HumanOffboarding.md).

At model-request time, runtime scope derives from the persisted Signal, public
Message authors, and Conversation participants. `Ankole.Brain.RequestContext`
validates the owned Signal at the Session boundary and constructs a typed Brain
context, which Sessions passes to AIGateway through an internal option. Caller
metadata on the public AIGateway API never grants runtime context or interprets
a Signal, and unread background Messages provide conversational context without
altering the requester's authorization.

## Bindings

`Ankole.Signals.Binding` defines a routing rule connecting one Agent to one
adapter, and `Ankole.Signals.Bindings` manages its configuration and lifecycle.
Resource actions persist configuration updates, disabling, and deletion inside
the caller's transaction: typed JSON attributes reject invalid runtime values
before SQL, `BindingFilters` compiles and checks CEL expressions, and `Target`
validates route targets. Adapter save hooks run after commit—if a hook fails,
Ankole logs the failure without failing the committed save, and delivery or
preview wakeups proceed independently. Each `signal_bindings` row stores the
Agent, binding name, adapter, configuration reference, filter, target, policies,
and enabled flag; rows are uniquely identified by `(agent_uid, name)` and
always queried under tenant scope.

Creating or re-enabling a Binding invokes the site's `:enable_signal_binding`
Plugin hooks inside the write transaction with `agent_uid`, `name`, `adapter`,
`config_ref`, and `enabled: true`. Editing or moving an already enabled Binding
preserves its admission, and both messaging adapters and CloudEvents share the
same write boundary and row-lock order.

Bindings store only a `config_ref` pointer rather than raw provider secrets,
which adapters read through their own AppConfigure contracts. Updating `config`
applies as a patch where omitted keys retain their stored values. Console edit
reads strip encrypted secret values—listing only which secret paths are
populated—and omitting or sending an empty secret field preserves the existing
encrypted value.

Disabling a Binding keeps its routing rule, configuration, and history intact.
The Console hides disabled Bindings by default while still letting operators
reveal, edit, or re-enable them. If an enabled Binding carries an
`unavailable_reason`, Ankole rejects new input on that Binding until an operator
repairs its configuration, though disabling one observer never prevents other
Agents from reading a shared Conversation.

Adapter categories (`enterprise_im`, `consumer_im`, `email` across the ten
messaging adapters, and `event_source` for built-in `cloudevents`) organize the
Console catalog without granting permissions or altering routing. Unlike IM
adapters, `cloudevents` carries no group-message or sender-mapping policies.

In the Console JSON:API, `GET /api/v2/signal-adapters` and
`GET /api/v2/signal-bindings` (guarded by `read` on
`site_console:signal_bindings`) serve the adapter catalog and binding list.
Per-Agent routes expose read, edit, and delete at
`/api/v2/agents/:agent_uid/signal-bindings/:binding_name` and create or enable
at `PUT /api/v2/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name`,
delegating commit and adapter-hook authority to `Ankole.Signals.Bindings` (and
omitting secrets from edit responses). Editing a Binding on the same Agent
requires `update` on `site_console:agent:<agent_uid>:signal_bindings`; moving a
Binding to another Agent checks `delete` on the source Agent's resource and
`update` on the exact target Agent's resource, leaving both Bindings untouched
if either check fails. Operators requeue failed deliveries via
`POST /api/v2/agents/:agent_uid/signal-deliveries/requeue`, which enforces the
durable Outbox admission rules.

### Filters

A Binding's `filters` map is either empty—accepting all events—or holds a
single `cel` expression. Writes compile the CEL expression up front and return
the compiler's syntax diagnostic if it is invalid. At runtime, Ankole evaluates
the filter before recording a durable observation or inserting a Signal, failing
closed if a stored expression cannot evaluate.

Creating, editing, or moving a messaging Binding commits `filters` in the same
transaction as the Binding and adapter configuration. Omitting `filters` when
editing or moving keeps the existing filter for the same adapter, whereas
creating a new Binding or switching adapters starts with an empty filter, and
passing an explicit `{}` clears the filter. If the supplied filter is invalid,
Ankole aborts the entire transaction, leaving both source and target Bindings
unchanged on a move.

For CloudEvents, `signal` exposes the incoming event envelope and `binding`
exposes the rule's name and adapter:

```text
signal.type == 'issue.changed' && signal.data.priority == 'urgent'
```

For provider message observations, `signal` exposes normalized `signal.channel`,
`signal.entry`, lifecycle, reaction, action, and command fields, where
`signal.channel.id` is the opaque `provider_conversation_id` and
`signal.entry.id` is `provider_message_id`. Because filtering runs before Ankole
allocates a public Conversation UUID, `channel` and `entry` name filter inputs
rather than persisted database tables.

## CloudEvents HTTP Intake

Operators provision a CloudEvents Endpoint through
`POST /api/v2/webhook-endpoints` (JSON:API, guarded by the Console webhook
permission) with `event_format: "cloudevents"`, a label, a mode, and a future
expiration timestamp. Creation returns the capability URL once; subsequent
Console and list reads expose only the Endpoint ID and safe metadata, never the
bearer token or its digest.

Each subscriber Agent binds to that Endpoint through a `cloudevents` Binding
whose configuration sets `webhook_endpoint_id` (`webhook-endpoint://<endpoint UUID>`)
along with `agent_uid` and one target:

| Target | Session selection |
| --- | --- |
| `{"conversation_id": "<UUID>"}` | That Agent's Session in a Conversation where it participates |
| `{"session_id": "<key>"}` | One fixed ordinary Session |

In Console forms, `target_kind` (`conversation` or `session`) and `target_id`
specify the Conversation UUID or Session key; neither option may target a
private Job or Workflow Session.

Producers deliver one structured CloudEvent per HTTP POST to the capability URL:

```http
POST /signals/v1/cloudevents/wh_<capability>
Content-Type: application/cloudevents+json

{
  "specversion": "1.0",
  "source": "https://example.com/issues",
  "id": "issue-42-revision-3",
  "type": "issue.changed",
  "data": {"priority": "urgent"}
}
```

Authentication relies solely on the URL capability token rather than browser
sessions or CSRF tokens. PostgreSQL stores only the token's SHA-256 digest, and
matching that digest establishes the Endpoint's tenant context before any
domain read or write runs. Request bodies are capped at 1 MiB.

Ankole accepts the
[CloudEvents 1.0 structured JSON format](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/formats/json-format.md)
over HTTP. Every event must include `specversion: "1.0"`, a nonempty `id`, a
nonempty `type`, and a nonempty URI-reference `source` (relative URI references
are allowed). Optional standard attributes follow the
[CloudEvents context attribute rules](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md#context-attributes):
`subject` must be nonempty when present, `time` must be RFC 3339 (defaulting to
acceptance time), `dataschema` must be an absolute URI, and `datacontenttype`
must be a valid media type.

The `data` field preserves any PostgreSQL-storable JSON value—without applying
IM message parsing—provided all strings and object keys are valid, NUL-free
UTF-8. Valid scalar CloudEvents extensions (such as distributed-tracing
attributes) stay on the top-level envelope: attribute names must use lowercase
ASCII letters and digits, and values must be CloudEvents Booleans, Integers,
Strings, or JSON `null`. Requests with invalid attributes fail before Ankole
writes any Signal or wakeup job. Binary-mode CloudEvents and `data_base64` are
not supported; sending `data_base64` returns HTTP 422 with
`unsupported_cloudevent_binary_data`.

Ankole evaluates all enabled, available Bindings on the Endpoint inside a single
transaction, calling `Signals.accept_in_tx/1` for each match so that multiple
matching Agents receive independent Signals carrying the original `source` and
`id`. If routing fails for any subscriber, the entire fanout rolls back.
Producer redeliveries return the already created Signal IDs without mutating
stored facts, and events that match zero filters return an ignored `202`
response.

| HTTP status | Meaning |
| --- | --- |
| `202` | Accepted or ignored; the JSON result includes `status` and `signal_ids` |
| `400` | Invalid JSON |
| `404` | Unknown capability or wrong Endpoint format |
| `415` | The request is not structured CloudEvents JSON |
| `422` | Invalid event, unsupported binary data, or routing failure |

Endpoint lifecycle depends on mode: a `one_shot` Endpoint transitions from
`armed` to `fired` only after accepting at least one Signal, whereas a
`standing` Endpoint stays `active`. Expired or cancelled Endpoints are terminal
and return an ignored response without creating work, as do Endpoints belonging
to a suspended tenant. `DELETE /api/v2/webhook-endpoints/:id` cancels an
Endpoint, and terminal capabilities remain idempotent on producer redelivery.

`WebhookEndpoint` enforces these state transitions—including atomic expiry
sweeps—through AshStateMachine, committing the Endpoint transition and accepted
Signals in the same transaction. Create actions set the initial state from the
immutable `mode`, fire and cancel actions require `fired_at` or `cancelled_at`
before SQL, and PostgreSQL constraints reject missing or conflicting terminal
timestamps.

## Raw Capability Callbacks

Inside a Worker, an Agent provisions a raw callback Endpoint for its own
long-lived Session by running `create-webhook-cli` with a label, future expiry,
and `one_shot` or `standing` mode; native Sessions require neither a provider
Binding nor a reply route. `list-webhooks-cli` inspects safe Endpoint metadata,
and `cancel-webhook-cli` transitions the Endpoint to its terminal cancelled
state.

Raw callbacks post to
`/webhooks/v1/event-callbacks/wh_<43-character-base64url-token>`, which
`create-webhook-cli` prints once at creation. Payloads are capped at 1 MiB, and
the stored receipt retains only `content-type`, `x-hub-signature-256`, and
headers prefixed with `ce-` or `x-github-`, stripping `authorization` and all
other headers. Ankole redacts both CloudEvents and raw capability tokens in
request logs, and any upstream proxy or CDN must redact those URL paths in its
access logs as well.

When a callback arrives, `Ankole.Signals.Webhooks` locks the Endpoint and
commits a `webhook.received` Signal before returning HTTP 204. Standing raw
Endpoints assign each delivery a fresh event ID with at-least-once semantics,
whereas one-shot Endpoints accept a single callback; subsequent deliveries to a
known terminal Endpoint return 204 without recording new work, and unknown
tokens return 404.

Passing `--automation-job-id <id>` to `create-webhook-cli` binds the raw
Endpoint to an active Automation Job owned by the same Agent so each callback
starts a durable Job run with the same receipt envelope.
`Signals.Trigger.deliver_in_tx/4` shares this Signal-or-AutomationJob dispatch
path across Webhook and Schedule triggers. Because the Endpoint uses strong
foreign keys and cannot be rebound, changing targets requires cancelling the
Endpoint and creating a new one; see [Automation Jobs](AutomationJobs.md).

A capability URL authorizes only stimulus delivery—its body and headers remain
untrusted input, so an Agent must read authoritative state from the external
system before taking consequential action. The owning Agent Plugin creates,
reconciles, and deletes the remote webhook registration; Signals does not track
external hook state.

## Observe a Provider Message

All ten messaging adapters—Lark, Slack, Microsoft Teams, DingTalk, WeCom,
Telegram, Discord, LINE, WhatsApp, and Email—feed inbound events through one
durable pipeline rather than writing Conversation or Signal rows directly:

```text
Provider event
  -> Plugin observe_module
  -> Conversations.Observe
  -> shared Conversation + Message + ExternalMessageRef
  -> Signals.accept_in_tx
  -> Agent's Session
```

Adapters translate provider protocol payloads and invoke the entry points on
`Ankole.Conversations.Observe`: `emit_entry/4`, `emit_entry_with_attachments/5`,
`emit_entry_deferred/5`, `emit_entry_removed/4`, `emit_reaction/4`, and
`emit_action/4`.

During observation, `Conversations.Observe` normalizes the payload, resolves the
Binding, evaluates its CEL filter, resolves reply anchors, and runs sender
identity admission. When policy allows recording, the transaction persists the
public Message alongside its `ExternalMessageRef`. Every Binding observing the
same `(tenant_id, provider_conversation_id)` shares one Conversation and Message
stream, adding each observer Agent as a participant—a Binding defines an
observation and delivery route rather than partitioning an external room into
per-Agent copies.

At this boundary, adapters report only provider subject identifiers and profile
observations: `Conversations.Observe` rejects caller-supplied `principal_uid`,
`agent_uid`, `human_access_version`, and top-level `sender_key`, relying on
identity admission to resolve the Principal and access version (while managed
card actions preserve their separately verified operator UID). Channel metadata
travels inside the nested `channel` map, and raw diagnostic payloads live under
`raw_payload`.

Attachment downloads and observation ordering split cleanly between two modules:
`Conversations.Attachments` manages blob storage, download outcomes, and
redelivery reuse, while `Conversations.Observe` orders pending and final
observations. LINE and WhatsApp share `emit_entry_deferred/5`, which commits
pending attachment IDs before spawning a tenant-bound download task and admits
the completed observation through a fresh Binding lookup (preserving the initial
observation timestamp on redelivery; if task admission fails transiently, the
error propagates to the provider for retry, and if the task supervisor is
missing, the request fails). Lark instead uses its all-consumers pending
barrier.

`Conversations.MessageInput` merges text and attachment lists and tracks
pending-attachment deadlines: observations with no pending attachments carry no
deadline, initial inbound batches wait for their aggregation window, and edits
or revisions become available immediately.

Completed observations return `conversation` and `message_observation` (bundling
`message`, `external_ref`, and the observation status). `Conversations.Message`
supplies the public UUID and sequence number, while `ExternalMessageRef` stores
the provider message ID, content hash, raw reported author, attachments, and
provider delivery metadata. If the sender cannot be mapped, the public Message
records an Unknown author while `ExternalMessageRef` keeps the raw provider
author; even if a raw provider ID looks like a Principal UID, Ankole never binds
it to that Principal automatically.

When an IM message addresses an Agent, observation accepts a
`conversation.message.addressed` Signal whose `source` is
`signal://<adapter>/<encoded provider_conversation_id>`, whose target is that
Agent's `conversation:<public UUID>` Session, and whose `reply_route` records
the Binding and provider thread/message anchor. Rapid consecutive IM messages
can coalesce into one Signal whose `data.message_ids` lists every public Message
contributed by that batch. Signals never embed a frozen snapshot of room
history; instead, Sessions reads unread shared Messages right before each model
request and records that watermark alongside model history.

Native Pod messages enter through the same Signal intake—using
`conversation:<public UUID>` as `source` and the public Message UUID as event
ID—committing the Message and Signal in one transaction without provider
observation or Delivery; see [Conversations](Conversations.md) for native
posting, provider lifecycle, attachments, batching, and outbound replies.

## Admit the Provider Author

`Ankole.Conversations.IdentityAdmission` resolves an external sender to a
Principal. Adapters supply stable candidate subject IDs and a display name
without creating or choosing Principals on their own.

Identity admission checks existing platform-subject bindings first and picks the
first match. If no subject binding matches, it falls back to a platform-verified
email address and then a verified mobile number; when the adapter declares an
`author_hydrator`, admission can make a single contact fetch to populate missing
verified contact fields (logging a warning and continuing without them if the
fetch fails).

`Ankole.Signals.SubjectNamespace` chooses which namespace scopes those external
subjects:

- An explicit identity-provider reference selects that provider's namespace.
- `:standalone` selects the adapter's default namespace.
- When the reference is omitted, a single configured matching identity provider
  supplies its namespace automatically; if zero or multiple matching providers
  exist, the adapter's default namespace applies.

The Console namespace picker lists disabled configured identity providers
alongside the `:standalone` option, omits the field when no matching provider
exists, and requires an explicit choice when multiple providers exist (writes
reject unknown references or a missing reference when multiple providers exist).
Enabling or moving a Binding preserves its stored namespace reference, and
identities recorded under the adapter default stay there until an operator
rebinds them; see [Principal](Principal.md).

Direct messages, structured Agent mentions, direct replies to an Agent, and
replies inside a provider thread where that Agent has already spoken count as
explicit input. Slash commands are accepted only in explicit input, emoji
reactions update external metadata without waking a model turn, and interactive
card actions resolve the clicking operator through the durable reply-interaction
owner.

For unaddressed group messages, each Binding configures one of three policies
(defaulting to `record_only`):

- `ignore`: skip identity admission and public Message creation, keeping the raw
  provider entry only in the inbound batch for later reply-reference lookups.
- `record_only`: admit the sender and record the public Message without waking
  the Agent.
- `may_intervene`: admit the sender, record the public Message, and enqueue an
  ambient triage input.

Ambient judgments and their read cursors are private to each Agent's Session, so
one Agent's triage never marks shared room Messages as judged for another Agent;
see [Sessions](Sessions.md).

When a sender matches no Principal, `unmatched_sender_policy` governs admission:

- `manual_review` (default): skips public Message creation and batching. If the
  message explicitly addressed the Agent, Ankole writes one
  `identity_mapping_requests` row and enqueues one localized mapping notice
  (preserving the unmapped sender under `metadata.unmatched_sender` for adapters
  that require a recipient address), whereas unaddressed group chatter is
  dropped silently.
- `create_standalone`: provisions a new Human Principal with a fresh UUIDv7 and
  admits the message under that account. Without an identity binding or verified
  contact match, Ankole creates a separate Principal even if the raw provider ID
  matches an existing Principal UID.

Messages from disabled Humans are dropped silently without sending a notice.
When admission succeeds, Ankole locks the Human row, captures `access_version`
on the observation (preserved across inbound batches and ambient triage), and
adds the Principal to the Binding's `signal_source:<agent_uid>:<binding_name>`
AuthZ group. Comparing that group against the directory-synced
`<provider_id>:members:all` group distinguishes external guests from
organization members on a given source.

## Provider Application Ownership

Every credential-bearing external platform application belongs to at most one
tenant. Saving a Binding or a directory-syncing identity provider—even while
disabled—acquires the shared binding-assignment lock. Multiple Bindings within
the same tenant can share one platform application when the adapter supports it,
whereas another tenant attempting to claim the same application receives a
conflict, and unverifiable credentials fail before writing. Login-only OIDC
identity providers are exempt because their callbacks bind tenant scope through
signed outbound OIDC state without opening message streams or directory sync.

Before opening a database transaction, adapters resolve a stable platform
application identifier: Slack calls `auth.test` and `bots.info` to resolve
`app_id` (and Socket Mode re-verifies the connected `app_id` before
acknowledging or dispatching events), while Discord and Telegram query their
bot APIs for stable bot IDs. Rotating tokens therefore preserves tenant
ownership; if an existing credential has expired and blocks cross-tenant
verification, an operator must repair or delete that configuration first.

Adapters whose configuration keys hash `[agent_uid, binding_name]` store secrets
in AppConfigure's global table because `agent_uid` is globally unique, and
deleting an Agent purges its owned configurations. At runtime, adapter worker
processes always enter the Binding's tenant context before reading or writing
domain tables.

## Control Plane Plugin Contract

Control-plane Plugins register messaging and event integrations by declaring
`signals.adapter`, which `Ankole.Signals.Adapters` validates against the
immutable Plugin registry snapshot:

- `observe_module` handles inbound provider events and returns atom-keyed result
  maps.
- `deliver_module` implements `Ankole.Conversations.Delivery.Adapter.deliver/1`
  (plus `reconcile/1` whenever the adapter declares `outbound_reconciliation`).
- `preview_module` optionally implements recoverable live reply previews.

See [Plugins](Plugins.md) and [Conversations](Conversations.md).

Adapters declare supported inbound capabilities (`entry_receive`,
`entry_removed`, `reaction_add`, `reaction_remove`, `action_event`) and outbound
provider operations (`post_entry`, `reply_entry`, `edit_entry`, `delete_entry`,
`add_reaction`, `remove_reaction`, `divider`, `card`,
`outbound_reconciliation`). These capability flags describe protocol operations
rather than separate persisted tables.

Document-comment integrations reuse the same Conversation observation and
Delivery contracts, while structured record mutations set the record ID as the
CloudEvent `subject` and enter through `Signals.accept_in_tx/1` with stable
deduplication IDs and explicit Agent/Session targets. Catalog categories remain
UI display labels without affecting routing or permissions, and comment authors
go through standard Principal mapping and `WorkAccess` snapshots rather than
inheriting the integration creator's permissions.

Plugins that receive provider HTTP webhooks declare `signals.webhook_handler`.
Ankole routes `POST` and `GET` requests at
`/webhooks/v1/<handler_id>/<instance_id>/<kind>` to the handler along with the
HTTP method, parsed body (`nil` on `GET`), query parameters, headers, and raw
request bytes. Each handler verifies provider signatures and commits durable
observation before returning `2xx`—webhook acknowledgements never block on model
execution.

Persistent streaming transports (such as Lark, Slack Socket Mode, and DingTalk)
run under `Ankole.Plugins.ConnectionLifecycle`. From stored configuration alone,
each adapter derives one connection specification per enabled Binding (and per
shared active identity provider); specifications with identical connection keys
share a single connection process, while conflicting app secrets for the same
key are rejected. Temporary SDK client processes run under that connection,
retrying a failed connection immediately once, then after 5 seconds and 30
seconds without disrupting other keys. Ankole stops a running connection only
after a full reconciliation pass cleanly reads every Binding and identity
provider and confirms that no active specification references that key.

To survive reconciler restarts, the connection Registry caches the last
successful start configuration and consumer set so a new reconciler can recover
a blocked Binding; an explicit stop purges that entry so a late retry timer
cannot resurrect a removed connection.

At the boundary between Elixir and persisted JSON, outer observation maps use
atom keys while provider payloads and stored JSON maps use string keys;
`Conversations.Observe` normalizes keys once and rejects mixed or colliding key
names before acknowledging the provider webhook. When adapters persist
conversation-level watermarks or cursors, they call
`Conversations.External.update_metadata/2` under the Conversation row lock so
concurrent redeliveries cannot regress monotonic provider state.

## Storage and Rules

| Table | Owner and fact |
| --- | --- |
| `signals` | Signals; accepted stimuli and their Session consumption lifecycle |
| `signal_bindings` | Signals.Bindings; configured routing rules |
| `signal_webhook_endpoints` | Signals.Webhooks; callback capabilities and terminal state |
| `conversations`, `conversation_messages`, `external_message_refs` | Conversations; shared public history and provider references |
| `conversation_inbound_batches`, `conversation_input_tombstones` | Conversations; input batching and removal facts |
| `deliveries`, `delivery_previews` | Conversations.Delivery; provider intents, live preview state, attempts, and results |
| `sessions`, `session_round_states` | Sessions; execution context and recovery |

Core invariants across these tables:

- Each accepted event produces at most one Signal per `(tenant_id, agent_uid, source, source_event_id)`.
- Event source, public Conversation UUID, Session execution target, and provider
  reply route remain separate, orthogonal attributes.
- Human work authorization freezes the observed Principal's `access_version`;
  background room messages and service events never renew it.
- Whenever a provider message requires Agent work, the Message observation and
  its Signal commit in the same transaction.
- Rolled-back transactions never emit Conversation PubSub events or live Driver
  wakeups.
- Webhook acknowledgements wait only for durable database acceptance, never for
  a model reply.
- Outbound Agent statements enter public Conversation history only after
  provider confirmation—an unconfirmed Delivery attempt never fabricates a
  public Message.
- Session runtime state and AIGateway model history stay distinct from shared
  public Conversation history.
