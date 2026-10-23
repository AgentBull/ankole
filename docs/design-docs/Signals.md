# Signals

Signals owns durable stimuli for Agent work. Every producer calls
`Ankole.Signals.accept/1` or `Ankole.Signals.accept_in_tx/2`. A Signal names its
source, event identity, facts, authorization, and execution target.

[Conversations](Conversations.md) owns shared conversations, participants,
public Messages, provider observations, and external Delivery. [Sessions](Sessions.md)
owns execution, input ordering, recovery, and the model history connection.
[AIGateway](AIGateway.md) owns model requests, Responses, and model session state.

## One Intake

`accept/1` runs the `intake` generic action of `Signal` (the define
`Ankole.Signals.intake/1`) and returns `{:ok, %Ankole.Signals.Signal{}}` or
`{:error, reason}`. `accept_in_tx/2` has the same result and requires the caller
to own a transaction. Use the latter when the stimulus must commit with a
Message, schedule execution, Job result, or Workflow result.

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

The intake also stores a private `producer` value. Core code sets `kernel` when
it derives a stimulus from a Message, schedule, task, or control action. Generic
CloudEvents and webhook intake set `external`; event fields cannot select this
value. It does not enter the CloudEvent envelope or change authorization.
Sessions uses it before it interprets internal event types. A source/id collision
between producers returns an error and leaves the accepted facts unchanged.

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

The producer does not store a second envelope. `Signal.envelope/1` builds the
CloudEvents 1.0 representation from these fields. It keeps extension facts
without letting them replace canonical event fields.

The intake resolves the target, validates the facts, locks the Agent's Session,
allocates `queue_sequence`, and inserts the Signal. PostgreSQL prevents a second
Signal with the same `(tenant_id, agent_uid, source, source_event_id)`. A repeat
returns the first Signal, including its first target and facts. Changing a
subscription does not move an accepted event to another Session. Several rules
that match the same event for the same Agent also return that one Signal.

In the same transaction, intake records a durable
`Ankole.Sessions.Jobs.EnsureDriver` job. It does not start a Driver inside that
transaction. `accept/1` can wake the Session immediately after a real commit;
the job repairs a lost wakeup. An outer rollback removes both the Signal and
its wakeup. Callers do not add their own intake or transaction hook.

## Queue State

`Ankole.Signals.Signal` owns the queue state through AshStateMachine actions.
The allowed states are `queued`, `running`, `completed`, and `dead_letter`.
Intake creates `queued` work. Admission records `running`; a retry deadline
returns it to `queued`. Completion can settle either live state, including an
Ambient NOOP that never starts a model turn. Neither terminal state can restart.
A retry of terminal work creates a new Signal with a new source event identity.

`available_at` is a deadline, and `last_attempt_at` records the latest admission.
A deferred Signal retains that admission history. These timestamps do not select
its state. Each admission increments `attempt_count` once. Capacity failures have
a separate counter; an admission refund cannot subtract a capacity attempt.
Triage retries keep `last_attempt_at` empty until a real turn starts.

PostgreSQL requires completion time only for `completed` work, and dead-letter
time and an object reason only for `dead_letter` work. Live work cannot carry
terminal evidence, and `running` requires an admission time. Actions and bulk
revocation use the caller's transaction and tenant context. Signal
writes do not start a second transaction owner.

`Ankole.Signals` is the Signals Ash domain (`Signal`, `Binding`,
`WebhookEndpoint`). Other domains use its defines (`get_signal`, `list_signals`,
`update_metadata_signal`, `revise_input_signal`, `reauthorize_signal`,
`remove_signal`, `get_binding`, `list_bindings`, `get_webhook_endpoint`,
`list_webhook_endpoints`) and its composition functions for a transaction that
they own: `accept_in_tx/2`, `lock_signal_in_tx/2`, `lock_session_signal_in_tx/3`,
`lock_signals_in_tx/3` (a keyword filter, queue order unless `sort:` gives
another order, an optional `limit:`, row lock identity),
`transition_in_tx/4` (one queue state transition of a locked Signal),
`reset_attempts_in_tx/3`, and `signals_for_entry_in_tx/5`. The Session queue
reads are `session_queue/3` and `session_status_signal/3`. Human revocation of
unstarted Signals is `stop_human_work_in_tx/4`. A read across tenants runs in
`Repo.across_tenants/1`: Signals use the Work provenance read action
`work_across_tenants` (`due_sessions_across_tenants/1`,
`count_admitted_attempts_for_human/2`), and Bindings and Endpoints use their
`lookup_across_tenants` read action.

Binding and Endpoint writes with more than one step are generic actions that
own their transaction: `assign_binding`, `reassign_binding`,
`put_cloud_binding`, `move_cloud_binding`, `disable_binding`,
`create_webhook_endpoint`, `cancel_webhook_endpoint`, and `receive_webhook`.
`Bindings` and `Webhooks` keep their public functions and give back the domain
reason with `Ankole.Errors.reason/1`. A Binding assignment refreshes the
configuration cache after its commit.

An unresolved dead-lettered Signal remains visible in access review. Review
states are separate from reauthorizable states: review cannot restart terminal
work or change its recorded authority.

## Execution Target and Reply Route

An explicit target has one of these forms:

| Target | Result |
| --- | --- |
| `%{agent_uid: uid, session_id: key}` | Work for that Agent and Session |
| `%{agent_uid: uid, conversation_id: uuid}` | Work for a participating Agent in that Conversation |
| `{:conversation, uuid}` | Work for the single Agent of a native Conversation |

A Conversation target resolves to `conversation:<uuid>`. An external
Conversation can contain several Agents. Its target must name the Agent;
the native tuple cannot select an arbitrary participant. Each Agent has its
own Session and model state for the same shared Conversation.

Generic event sources may target `main` or an ordinary custom Session.
`job:<id>` and `wf_task:<id>` are private work-unit Sessions; only their
internal producers may dispatch or control them. An Endpoint or webhook
Binding that selects either prefix returns `invalid_signal_target`.

A reply route is a separate fact. `reply_route` can carry `binding_name`,
`conversation_id`, `provider_thread_id`, and `provider_message_id`.
`binding_name` is stored as `reply_binding_name`. The Signal source remains the
producer namespace. An internal producer does not create a Binding to name
itself, and a Binding does not own a Conversation.

`message_id` identifies an optional public Message that caused the Signal.
An IM batch also keeps all of its public Message IDs in `data.message_ids`.
These IDs are not provider message IDs or AIGateway message IDs.

`Signals.Target.parse/1` is the route-target parser shared by Binding, webhook,
CloudEvents, and intake. It returns `{:conversation, uuid}` or `{:session, key}`
and rejects mixed targets. `Sessions.Key.routable?/1` enforces the private-work
boundary. A reply route remains a separate delivery fact.

`Signals.Types` explicitly declares whether each code-produced type supersedes
a pending interaction. Undeclared types, including external CloudEvents types,
preserve the pending interaction. Intake takes the Session lock before insert
and then applies interaction supersession through `Delivery.Interactions`
and records the durable EnsureDriver wakeup in the same transaction. Opening a
late clarification uses the same declared superseding types. Only a kernel
`session.reset_due` Signal acts as a reset barrier for an interaction answer.
The provider-removal lifecycle type is `conversation.message.removed`.

`accept_in_tx/2` returns the accepted Signal as a pending publication fact.
Its outer transaction owner calls `Signals.publish_committed/1` in the same
process after commit. The `intake` action declares the same publication with
`after_commit`, and a call inside another transaction raises
`Ankole.Errors.Framework.NestedOperation`. Publication sends a Session state notification,
calls the `ensure_driver/1` startup fast path, and publishes ready Signal IDs
on the Session input topic. Drivers read the durable input; an observation or
raw Conversation message cannot create a second input through PubSub.
The publication guard checks only the current process. A Task cannot be used
inside the transaction to publish pending facts.

## Attribution and Runtime Scope

`sender` names the accountable Principal when one exists. WorkAccess captures
`authorization_kind`, `human_uid`, and `human_access_version`. A producer with
an existing authorization snapshot passes it unchanged. New Human input uses
the observed Human version; later identity updates cannot renew old work.

Internal service work and capability callbacks use an explicit service
snapshot. An unknown sender remains `review_required`. A source rule, an
ambient observation, or arbitrary event data cannot borrow a Binding owner's
Human permissions. Sessions checks the snapshot before a new execution
attempt. An already admitted run can finish. See
[Human Offboarding](HumanOffboarding.md).

Runtime scope comes from the persisted Signal, public Message authors, and
the Conversation audience. `Ankole.Brain.RequestContext` validates the owned
Signal at the Session boundary and builds the typed Brain context. Sessions
passes that context to AIGateway as an internal option. Caller metadata on the
public AIGateway API does not grant a runtime context or interpret a Signal.
Conversation background messages are readable context; they do not change the
authorization of the current request.

## Bindings

`Ankole.Signals.Binding` is a routing rule for one Agent and adapter.
`Ankole.Signals.Bindings` owns its configuration and lifecycle. Its resource
actions persist configuration replacement, disabling, and removal in the
caller's transaction. Its typed JSON fields reject runtime values before SQL;
BindingFilters owns CEL validation and Target owns route parsing. Adapter save
hooks run after commit.
`signal_bindings` stores the Agent, name, adapter, configuration reference,
filter, target, policies, and enabled state. The globally unique Agent UID and
binding name identify the row; every query also enforces its tenant scope.

An adapter reads secrets through its own AppConfigure contract. A Binding
contains a `config_ref`, not the provider secret. A `config` update is a patch:
omitted fields keep their stored values. Console edit reads omit encrypted
values and list only paths that already have a secret. An omitted or empty
secret field keeps the stored encrypted value.

Disabling a Binding retains its rule, configuration, and history. Console
hides disabled rules by default and can show, edit, or enable them. An enabled
Binding with an `unavailable_reason` rejects new input until its configuration
is repaired. Disabling one observer does not make a shared Conversation
unreadable for other Agents.

Adapter categories group the catalog; they do not grant authority or determine
routing. The ten messaging adapters declare `enterprise_im`, `consumer_im`,
or `email`. The built-in `cloudevents` source uses `event_source` and has no
IM group-message or sender-mapping policy.

### Filters

`filters` is empty or contains exactly one `cel` expression. An empty filter
accepts all input. Binding writes validate CEL syntax. Evaluation happens
before durable observation or Signal insertion and fails closed on an invalid
stored expression.

For CloudEvents, `signal` is the complete incoming event, and `binding` contains
the rule's name and adapter. For example:

```text
signal.type == 'issue.changed' && signal.data.priority == 'urgent'
```

For provider observations, the filter sees normalized `signal.channel`,
`signal.entry`, lifecycle, reaction, action, and command facts. In this filter
vocabulary, `signal.channel.id` is the opaque `provider_conversation_id` and
`signal.entry.id` is the `provider_message_id`. Filtering precedes public
Conversation identity allocation. These names describe filter input, not
separate persisted Channel or Entry records.

## CloudEvents HTTP Intake

An operator creates an Endpoint with `event_format: "cloudevents"`, a label,
mode, and future expiry through `POST /api/v2/webhook-endpoints` (JSON:API). The
Console webhook permission controls creation. Creation returns the capability
URL once. The Console and safe list API keep the Endpoint ID and metadata,
and do not return the token or its digest.

Create a `cloudevents` Binding for each subscription. Its configuration names
`webhook_endpoint_id`; its reference is `webhook-endpoint://<endpoint UUID>`.
The Binding supplies `agent_uid` and one target:

| Target | Session selection |
| --- | --- |
| `{"conversation_id": "<UUID>"}` | That Agent's Session in a Conversation where it participates |
| `{"session_id": "<key>"}` | One fixed ordinary Session |

Console configuration uses `target_kind`: `conversation` or `session`, with
`target_id` naming the Conversation UUID or fixed Session key. Neither target
can select a private Job or Workflow Session.

Send one structured JSON event to the returned URL:

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

The route uses the Endpoint capability, not a browser login or CSRF token.
PostgreSQL stores only the token's SHA-256 digest. Matching the token also
selects the Endpoint's tenant before any business read or write. The callback
body can contain at most 1 MiB.

The supported transport is the
[CloudEvents 1.0 structured JSON format](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/formats/json-format.md)
over HTTP. Required attributes are `specversion: "1.0"`, nonempty `id`,
nonempty `type`, and a nonempty URI-reference `source`. Relative sources are
valid. `subject` is optional; when present it is nonempty. `time` is optional
RFC 3339 time and defaults to acceptance time. The optional `dataschema`
is an absolute URI; `datacontenttype` is a media type. See the
[CloudEvents context attribute rules](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md#context-attributes).

`data` keeps any PostgreSQL-storable JSON value without an IM interpretation.
Strings and object keys must be valid UTF-8 and cannot contain NUL bytes.
Legal scalar extensions, including trace attributes, remain top-level envelope
facts. Names use lowercase letters and digits; values use the CloudEvents
Boolean, Integer, or String type, or JSON null. Invalid attributes fail before
any Signal or wakeup is stored. This endpoint does not accept binary-mode
CloudEvents or `data_base64`; the latter returns 422 with
`unsupported_cloudevent_binary_data`.

All enabled, available Endpoint subscriptions are evaluated in one transaction.
Each match calls the same `Signals.accept_in_tx/2`. A routing failure rolls
back the full fanout. Multiple Agents receive independent Signals with the
original event source and ID. Producer redelivery returns existing Signal IDs
without changing the original facts. A request with no matches is ignored.

| HTTP status | Meaning |
| --- | --- |
| `202` | Accepted or ignored; the JSON result includes `status` and `signal_ids` |
| `400` | Invalid JSON |
| `404` | Unknown capability or wrong Endpoint format |
| `415` | The request is not structured CloudEvents JSON |
| `422` | Invalid event, unsupported binary data, or routing failure |

`one_shot` changes from `armed` to `fired` only after it accepts at least one
Signal. `standing` remains `active`. Expired or cancelled Endpoints are
terminal and return an ignored result without new work. Suspended tenants
also accept no work. `DELETE /api/v2/webhook-endpoints/:id` cancels the
Endpoint. A known terminal capability remains safe for producer redelivery.

`WebhookEndpoint` owns these transitions through AshStateMachine, including
the atomic expiry sweep. The callback transaction commits the state and its
consumer together. PostgreSQL requires `fired_at` for a fired Endpoint and
`cancelled_at` for a cancelled Endpoint, and rejects conflicting evidence.
The create action fixes the initial state from the immutable mode. Later
transitions cannot change that mode. Fire and cancel actions require their
corresponding timestamp before SQL.

## Raw Capability Callbacks

A Worker requests a raw Endpoint through `create-webhook-cli`, with a label,
future expiry, and `one_shot` or `standing` mode. The Endpoint belongs to its
Agent and long-lived Session. `list-webhooks-cli` returns safe metadata, and
`cancel-webhook-cli` makes the Endpoint terminal. Native Sessions need no
provider Binding or reply route.

The raw callback path is
`/webhooks/v1/event-callbacks/wh_<43-character-base64url-token>`.
Creation returns the full URL once. Raw requests also have a 1 MiB body limit.
The receipt keeps only `content-type`, `x-hub-signature-256`, and headers whose
names start with `ce-` or `x-github-`; it discards authentication and other
headers. Request logs redact both capability paths. A proxy or CDN must also
redact them in its access logs.

`Ankole.Signals.Webhooks` locks the Endpoint and records a `webhook.received`
Signal before it returns HTTP 204. A standing raw Endpoint gives each callback
a new event ID and has at-least-once semantics. A one-shot Endpoint accepts one
callback. Known terminal Endpoints return success without a new record;
unknown capabilities return 404.

`create-webhook-cli --automation-job-id <id>` binds a raw Endpoint to an active
Automation Job for the same Agent. The callback creates a durable Job run
with the same receipt envelope. `Signals.Trigger.deliver_in_tx/5` owns this
Signal-or-AutomationJob dispatch for Webhook and Schedule triggers. The Endpoint
uses strong foreign keys. An Endpoint cannot be rebound; cancel it and
create another one. See [Automation Jobs](AutomationJobs.md).

A capability authorizes a stimulus only. Its body and headers are untrusted
input. The Agent must read the external system's authoritative state before
it makes a consequential change. The owning Agent Plugin creates, reconciles,
and removes the external hook. Signals does not store a second external task
or hook lifecycle.

## Observe a Provider Message

All ten messaging adapters use the same durable path:

```text
Provider event
  -> Plugin observe_module
  -> Conversations.Observe
  -> shared Conversation + Message + ExternalMessageRef
  -> Signals.accept_in_tx
  -> Agent's Session
```

Lark, Slack, Microsoft Teams, DingTalk, WeCom, Telegram, Discord, LINE,
WhatsApp, and Email supply provider protocol facts. They do not write
Conversation records or Signal rows directly. The public observation methods
include `emit_entry/4`, `emit_entry_with_attachments/5`, `emit_entry_deferred/5`,
`emit_entry_removed/4`, `emit_reaction/4`, and `emit_action/4` on
`Ankole.Conversations.Observe`.

Observation normalizes the provider input, resolves the Binding, applies its
filter, resolves reply references, and admits the sender. When policy permits
recording, the transaction writes the public Message and its external
reference. All observers of the same `(tenant_id, provider_conversation_id)`
use the same Conversation and Message facts. Each observer Agent becomes a
participant. A Binding identifies its observation and delivery route; it does
not divide the platform room into private Agent copies.

Entry authors report provider subjects and profile observations. Raw
`principal_uid`, `agent_uid`, `human_access_version`, and top-level `sender_key`
are rejected at this boundary. Identity admission supplies the Principal and
access version. Managed actions keep their separately verified operator UID.
Input channel fields use the nested `channel` map; diagnostic provider facts
use `raw_payload`.

`Conversations.Attachments` owns attachment storage, download results, and
reuse on redelivery. Observe owns the order of pending and final observations.
LINE and WhatsApp share its deferred attachment operation: it commits pending
attachment IDs before starting the tenant-bound task and admits the
final result through a fresh Binding lookup. Redelivery keeps the first
observation time. A task admission error returns to the provider for retry;
a missing task supervisor fails the request. Lark uses its
all-consumers pending barrier.

`Conversations.MessageInput` owns entry text/list merging and pending
attachment deadlines. An empty pending set has no deadline. An initial batch
uses its aggregation window; an input revision becomes available immediately.
Initial batches and input revisions use these respective scheduling rules.

An observed result contains `conversation` and `message_observation`. The
latter contains `message`, `external_ref`, and its observation status. Public
Message ID and sequence come from `Conversations.Message`; provider identity,
content hash, raw author, attachments, and provider result facts come from
`ExternalMessageRef`. An unknown author remains Unknown on the Message while
the external reference retains the reported author. A Principal-looking
provider ID does not select that Principal.

Addressed IM input becomes `conversation.message.addressed`. Its source is
`signal://<adapter>/<encoded provider_conversation_id>`, its execution target
is the participating Agent's `conversation:<public UUID>` Session, and its
reply route retains the actual Binding and provider anchor. Nearby IM
observations can become one Signal; `data.message_ids` includes every public
Message that the batch itself supplied. There is no frozen main history
snapshot in the Signal. Sessions reads unread shared messages before each
model request and records the bounded read with model history.

Native Human messages use the same intake. Their source is
`conversation:<public UUID>`, event ID is the public Message ID, and Message
plus Signal commit together. They need no provider observation or Delivery.
See [Conversations](Conversations.md) for native posting, provider lifecycle,
attachment handling, batching, and external replies.

## Admit the Provider Author

`Ankole.Conversations.IdentityAdmission` maps a reported sender to a Principal.
Adapters supply stable subject candidates and a display name; they do not
create or select Principals themselves.

The first existing platform-subject binding wins. If none matches, admission
tries the platform-reported email, then mobile number. When the adapter has an
`author_hydrator`, one contact fetch can supply missing verified contact facts.
A failed hydration logs a warning and continues without those facts.

`Ankole.Signals.SubjectNamespace` selects the subject namespace:

- A referenced identity provider names that provider's namespace.
- `:standalone` keeps the adapter's default namespace.
- Without a reference, one configured matching provider supplies its namespace;
  with none or several providers, the adapter default applies.

The catalog includes disabled configured providers and the standalone choice.
The field is required only when several providers exist and is omitted when
none exists. A configuration write rejects an unknown reference or a missing
reference when several providers exist. Enabling or moving a Binding keeps
the stored reference. Identities stored under the adapter default remain there
until an operator binds them. See [Principal](Principal.md).

Direct messages, structured Agent mentions, replies to that Agent, and replies
inside a provider thread where the Agent has participated are explicit input.
Commands are valid only in explicit input. Reactions update external facts
without a model wakeup. Provider card actions resolve the operator through the
durable reply interaction owner.

For an unaddressed group message, the Binding selects:

- `ignore`: skip identity admission and public observation; keep the complete
  provider fact in its inbound batch for later reply references.
- `record_only`: admit and record the message without waking the Agent.
- `may_intervene`: admit and record the message for an ambient decision.

The default is `record_only`. Ambient judgments and their cursor belong to
each Agent's Session. They cannot mark another Agent's shared messages as
already judged. See [Sessions](Sessions.md).

For a sender with no identity match, `unmatched_sender_policy` selects:

- `manual_review` (default): no processing Message or inbound batch. An
  addressed message records one `identity_mapping_requests` row and one fixed
  localized mapping notice. The notice Delivery retains the refused sender
  under `metadata.unmatched_sender` for adapters that need a recipient.
  Unaddressed chatter is ignored silently.
- `create_standalone`: create a Human Principal with a new UUIDv7 and serve
  that account. Without an identity binding or verified contact match, a
  provider ID equal to an existing Principal UID creates a separate
  account.

A disabled Human is ignored without a notice. Admission locks an admitted
Human and records `access_version` with the observation. Batches and ambient
work retain that version. Every admitted sender also joins the Binding's
`signal_source:<agent_uid>:<binding_name>` AuthZ group. Directory sync owns the
provider-wide `<provider_id>:members:all` group; the difference identifies
third-party users of a source.

## Provider Application Ownership

A credential-bearing platform application belongs to one tenant. Bindings
and directory-sync identity providers share the binding-assignment lock during
saves, including disabled configuration. The same tenant can share an
application when the adapter permits it. Another tenant receives a conflict;
an unverifiable credential fails without a write. Login-only identity
providers are excluded because their callback uses the login transaction's
tenant and opens no message connection or directory synchronization.

Slack resolves stable `app_id` through `auth.test` and `bots.info`. Socket Mode
validates the connected application before it acknowledges or dispatches an
event. Discord and Telegram resolve stable bot IDs through their provider
APIs. Token rotation does not change the application's tenant. Repair or
remove an invalid credential before saving a cross-tenant configuration whose
ownership cannot be verified.

Some adapter configuration keys hash `[agent_uid, binding_name]` and remain
in AppConfigure's global storage because that key is globally unique. Agent
deletion removes the owned configuration. Adapter processes enter the
Binding's tenant before they read or write business facts.

## Control Plane Plugin Contract

Plugins declare `signals.adapter`; `Ankole.Signals.Adapters` validates active
declarations from the immutable Plugin registry snapshot. `observe_module`
implements provider input callbacks. `deliver_module` implements
`Ankole.Conversations.Delivery.Adapter.deliver/1`. A declared
`outbound_reconciliation` capability also requires `reconcile/1`. Callback
result maps have atom keys. `preview_module` implements the optional
recoverable provider preview contract. See [Plugins](Plugins.md) and
[Conversations](Conversations.md).

Input capabilities are `entry_receive`, `entry_removed`, `reaction_add`,
`reaction_remove`, and `action_event`. Provider operations can declare
`post_entry`, `reply_entry`, `edit_entry`, `delete_entry`, `add_reaction`,
`remove_reaction`, `divider`, `card`, and `outbound_reconciliation`. These
capability names describe provider operations, not stored domain entities.

A Plugin with HTTP provider callbacks declares `signals.webhook_handler`.
The host routes POST and GET to
`/webhooks/v1/<handler_id>/<instance_id>/<kind>` and passes the method, parsed
body, query, headers, and exact bytes. GET has no body. The handler verifies
the provider protocol and completes durable observation before it returns
success. A provider acknowledgement never waits for model execution.

Long connections use `Ankole.Plugins.ConnectionLifecycle`. The adapter builds
one connection specification per enabled Binding and, when shared, active
identity provider, from stored configuration alone. Equal connection keys share
one process. Different app secrets for the same key are rejected. Lark, Slack,
and DingTalk SDK clients are temporary children. A failed connection retries
once immediately, then after 5 and 30 seconds; other keys remain connected. A
connection is stopped only after a reconciliation pass reads all Bindings and
identity providers successfully and no specification needs it.

The connection Registry retains the last successful start configuration and
consumers so a replacement reconciler can recover a blocked Binding. A stop
removes them; a late retry cannot restore a removed connection.

Outer Elixir observation maps use atom keys. Provider data and persisted JSON
use string keys. Observation normalizes those keys once and rejects mixed or
colliding keys before a provider acknowledgement. Adapters update their own
Conversation metadata through `Conversations.External.update_metadata/2`
under the Conversation lock. Monotonic provider facts therefore cannot move
backwards on concurrent redelivery.

## Storage and Rules

| Table | Owner and fact |
| --- | --- |
| `signals` | Signals; accepted stimuli and their Session consumption lifecycle |
| `signal_bindings` | Signals.Bindings; configured routing rules |
| `signal_webhook_endpoints` | Signals.Webhooks; callback capabilities and terminal state |
| `conversations`, `conversation_messages`, `external_message_refs` | Conversations; shared public history and provider references |
| `conversation_inbound_batches`, `conversation_input_tombstones` | Conversations; input batching and removal facts |
| `deliveries` | Conversations.Delivery; provider intents, attempts, and results |
| `sessions`, `session_round_states` | Sessions; execution context and recovery |

- One accepted event has one Signal per Agent, source, and source event ID.
- Event source, public Conversation identity, execution target, and provider
  reply route remain distinct facts.
- Human authorization comes from the observed Principal version; background
  context and service events do not renew it.
- Message observation and its stimulus commit together when work is required.
- A rolled-back transaction publishes no conversation event or live wakeup.
- Provider acknowledgements depend on durable acceptance, never on a model
  reply.
- Provider confirmation commits an Agent Message through Conversations;
  an unconfirmed send does not invent a public Message.
- Runtime and model history remain separate from shared public history.

## Future Host and Event Source Contracts

The contract review for Jira and Salesforce requires no new conversation or
queue owner.

| Platform fact | Owning contract | Identity and result |
| --- | --- | --- |
| Jira issue comment | Conversation host `observe` and `deliver` | The issue comment space supplies one opaque provider conversation ID; each comment supplies its provider message ID. `external_kind: issue`, `reply_mode: entry`, and an explicit addressed Signal type use the observation contract. A confirmed comment send or edit uses Delivery and the same external reference. |
| Salesforce record change | Event source and `Signals.accept_in_tx/2` | The record ID is the CloudEvent subject; the change is JSON data. Source and event ID deduplicate the stimulus. A subscription names its Agent and ordinary Session. The event creates no Conversation or Message. |
| Salesforce comment space, if later supported | Conversation host `observe` and `deliver` | The platform's actual comment space is the Conversation; observed comments and confirmed replies follow the host contract. A record change must not fabricate a comment. |

A future host declares its provider configuration, identity mapping, and
Delivery adapter in the plugin catalog. Its catalog category is display
metadata; adding that category does not change Conversation identity, Signal
acceptance, execution ownership, or authorization. A comment author uses the
Principal mapping and WorkAccess snapshot. An unknown author cannot
borrow the integration owner's authority. Several Agents observing the same
comment space share its public Messages and keep their own Sessions.
