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
| `actor_events` | Work that an Agent session must process |
| `actor_event_deliveries` | Attempts to send that work to a worker |
| `signal_gateway_outbox_entries` | Operations that Ankole must send to a provider |

## Use a Different ID for Each Record

Each ID below identifies a different thing:

| Identifier | Meaning |
| --- | --- |
| `source_event_id` | One provider or internal input event |
| `source_entry_id` | One provider message, post, or comment |
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

When a binding update changes group memory between shared and confidential,
the next turn in each affected group starts a new AIGateway conversation. This
prevents the old transcript and Brain snapshot from crossing the new memory
boundary.

Each accepted message records its Brain store for every receiving Agent. A
later binding update does not reclassify messages that are still waiting for
Dreaming. It changes the route only for later ingress.

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

## Receive an Event

Adapters call `Ankole.SignalsGateway.Ingress` to report a new message, removal,
reaction, or provider action.

Entry receipt follows this sequence:

1. Resolve the binding.
2. Convert the input to `IngressFact`.
3. Apply the binding filter.
4. Update the local provider copy when the policy permits it.
5. Update or finalize an inbound batch when the entry is IM traffic.
6. Write an ActorEvent when the Agent must do work.
7. Notify ActorRuntime after the transaction commits.

A filtered event returns `filtered` successfully. SignalsGateway stores no
provider copy or ActorEvent for it.

Every direct message gives the Agent explicit input.
A structured Agent mention makes a group message explicit.
A reply target that points to the Agent also makes the group reply explicit.

Commands are valid only for explicit Agent input.
The gateway ignores command-like text in an unaddressed group message.

Reactions update the stored provider message but do not wake the Agent. A
reaction for an unknown message returns `ignored_unknown_entry`.

Removal deletes the stored provider message and creates a tombstone. The
tombstone blocks a late copy of the removed message for 24 hours.

A provider acknowledgement confirms receipt only. It is not an Agent reply and
cannot contain model-generated text.

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
observation. A later observation with the same source entry ID replaces it with
`complete` or `failed`. The attachment window starts at the pending observation,
not after the download. An open batch waits for all pending attachments, with a
four second materialization cap.

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
- `check_back_later.wakeup`
- `cron.fire`
- `background_agent_job.completed`
- `background_agent_job.failed`
- `background_agent_job.waiting`

`input_state` is `open` or `dead_letter`. Normal completion sets `completed_at`
and keeps the row as history.

ActorRuntime orders open events with `queue_sequence` for each Session. Each
delivery row records one worker attempt and its turn fence.

A worker `turn_error` leaves the ActorEvent open. ActorRuntime tries again and
invalidates the old turn fence.

After five `turn_error` results, ActorRuntime moves the event to `dead_letter`.
For a visible chat message, the same transaction records a localized failure
notice for the provider.

SignalsGateway rejects a late result while the source message has an active
tombstone. A removed message cannot produce a later reply.

## Choose How to Reply

Each mirrored channel has one `reply_mode`:

- `none` permits no provider-visible output.
- `channel` permits a top-level provider post.
- `entry` permits a reply that targets a source entry.

The outbox checks `reply_mode` and the adapter's declared operations. It never
guesses a route or a message to reply to.

A final Agent answer normally becomes `reply` for an entry-capable channel.
It becomes `post` when only channel output is available.

Unsupported route or capability combinations produce an `unsupported` outbox state.

## Store a Reply before Sending It

When an Agent turn ends, SignalsGateway stores every provider operation before
it sends anything. The same transaction completes the ActorEvent.

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

Ordinary failures retry after delays from five seconds to five minutes. Delivery
stops at `max_attempts`, which defaults to ten.

Final AI replies continue every 15 minutes after that limit because Ankole has
already committed to showing them to the user.

An adapter can classify a durable reply failure as `operator_action_required`.
SignalsGateway then blocks the row without another automatic retry. Saving the
binding after the operator repairs the attachment or configuration wakes the
blocked row.

A `sending` row can recover after 60 seconds. SignalsGateway asks the provider
for its result only when the adapter supports that check and has enough IDs.

Otherwise, SignalsGateway sets `unknown_after_send` and does not resend. A
resend could create a duplicate message.

After provider success, SignalsGateway updates its copy of the provider message.
It also links a final reply to `ai_message_id` when available.

When `/retry` supersedes a completed or failed turn, the same actor transaction
stores one delete outbox intent for each known provider reply. A completed
Response also becomes `retracted`; a failed Response remains an error audit
fact. A provider deletion failure does not stop the replacement turn. The
outbox records its retries and final result.

## Show Progress before the Final Reply

A live preview can show model progress, but Ankole can lose it. It is not the
final reply record.

The preview follows AIGateway progress for one ActorEvent. An adapter can update
one provider message as new text arrives.

After the first successful preview, the ActorEvent stores the provider message
ID. The final outbox can edit that message instead of sending another one.

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

## Which Component Does What

SignalsGateway does these actions:

- accept provider input in Ankole's common format
- store the latest known provider state
- write ActorEvents
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
- A provider acknowledgement never depends on model execution.
- A provider mirror records provider state and never replaces an ActorEvent.
- A live preview never replaces a stored final reply.
- A removed source cannot commit a late Agent result while its tombstone is active.
- A queued `may_intervene` event cannot run after its scene or binding policy changes.
- An uncertain provider send never causes an automatic duplicate send.
