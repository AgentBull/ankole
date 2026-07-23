# Feishu and Lark Adapter

The Lark Adapter receives Feishu or Lark messages and sends Agent replies. It
also imports users and departments. Chat and identity use separate settings,
and the control plane keeps all provider credentials.

Read [SignalsGateway](../SignalsGateway.md), [Principal](../Principal.md), and
[Plugins](../Plugins.md) for the common message, identity, and Plugin rules.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `lark-adapter` |
| API version | `1` |
| Signal adapter ID | `lark` |
| Signal configuration | `signals_gateway.lark.bindings.<agent_uid>` |
| Identity adapter ID | `lark` |
| Identity configuration | `principals.identity_providers.lark.<id>` |
| Provider library | `libs/feishu_openapi` |

The signal adapter supports `addressed_only`, `observe_all`, and
`may_intervene`.

Inbound capabilities are `entry_receive`, `entry_removed`, `reaction_add`,
`reaction_remove`, and `action_event`.

Outbound capabilities are `post_entry`, `reply_entry`, `edit_entry`,
`delete_entry`, `outbound_reconciliation`, `add_reaction`, `remove_reaction`,
`divider`, and `card`.

The identity adapter supports OIDC authorization, code exchange, full directory
sync, and real-time directory sync.

## Settings

The chat configuration contains these fields:

| Field | Purpose |
| --- | --- |
| `appID` | Required self-built application ID |
| `appSecret` | Required encrypted application secret |
| `domain` | Selects `feishu` or `lark` |
| `platformSubjectNamespace` | Selects the Principal subject namespace |
| `userName` | Sets the outbound display name |

The SignalsGateway binding, not these AppConfigure settings, selects how the
Agent handles unaddressed group messages.

Bot identity is not an AppConfigure setting. Each live chat connection resolves
the bot `open_id` from `bot/v3/info` and keeps it only in its process-local
consumer config as `runtimeBotOpenID`. If this lookup fails, group mentions fail
closed until a later connection can resolve the identity.

Identity settings use `appID`, `appSecret`, and `domain`. `oidc.*` controls
login, while `sync.*` controls user and department import.

One Agent can have at most one enabled Lark binding. One `appID` cannot belong
to two Agents. The binding save transaction validates both rules.

## Connect to Feishu or Lark

One `domain` and `appID` pair identifies an application. `ConnectionReconciler`
selects the required pairs, and `ConnectionSupervisor` runs one long connection
for each pair.

Chat and identity work can share a connection when the pair and secret match.
Conflicting secrets make that connection unavailable. A restart rebuilds the
in-memory connection list.

The WebSocket client handles reconnects, provider pings, fragments, and event
dispatch. It acknowledges events after their handlers complete. Provider
redelivery is safe because host writes are idempotent.

A multi-node Installation must assign each application connection to one node.
The local registry cannot make that assignment across nodes.

## Receive Messages and Actions

The adapter normalizes messages, recalls, reactions, and card actions, then
submits them through SignalsGateway ingress. SignalsGateway owns the provider
mirror and creates ActorEvents.

The stable channel ID is `lark:<encoded_chat_id>`. The provider message ID is
the source entry ID. Reply and thread identifiers use provider root IDs when
they are present.

Direct messages give explicit input. A structured mention of the current bot
makes a group message explicit. SignalsGateway applies the binding policy to
other group messages.

`user_id` identifies the sender. The adapter keeps `open_id` and `union_id` as
provider details and ignores a sender without `user_id`.

Reaction events use the operator `user_id` when it is present. They use the
operator `open_id` as the stable reaction actor key when Feishu omits
`user_id`.

The adapter supports text, rich posts, stickers, images, files, audio, media,
video, locations, shared chats, and shared users. For a provider file, the
adapter first submits a durable `pending` observation with the provider
reference. It does this for every matching chat consumer before the first
download starts. The adapter then downloads the bytes and stores successful
downloads through WorkerFiles. It submits `complete` or `failed` with the same
source entry ID. A failed download keeps the provider reference without a local
file.

The pending observation time is the attachment settle anchor. A slow download
does not move the 1,200 millisecond quiet window. SignalsGateway can wait up to
four seconds for materialization before it releases pending work.

If a message with a structured mention has no attachment but refers to a recent
file or image, the adapter can reuse up to three attachments from the same
sender and channel from the previous 120 seconds.

A recall emits `entry_removed`. A reaction updates the stored message but does
not wake the Agent. A card action always wakes the Agent.

## Send Replies

The adapter sends only operations already stored in the outbox. It can post,
reply, edit, delete, reconcile, change reactions, send dividers, and send cards.

The adapter uploads WorkerFiles before it sends image or file messages. Text
messages use provider UUIDs derived from outbox idempotency keys. Reconciliation
checks the recorded provider message ID.

If a referenced WorkerFiles attachment is missing, not a regular file, too
large, or outside the supported attachment contract, the adapter marks the
durable reply as requiring operator action. SignalsGateway blocks that row
instead of retrying the same invalid attachment forever. The Worker file
protocol reports `file_not_found` and `not_regular_file`; the adapter never
classifies these failures from their human-readable messages.

If a reply target no longer exists, the adapter can post to the chat instead.
If Lark rejects a final edit because of its edit limit, the adapter can send a
new message.

## Show a Live CardKit Reply

`CardKit` can open, update, finish, and refresh a preview. It keeps an ordered
chain of cards for each visible Agent turn.

The preview coalesces CardKit changes and starts at most one provider sync for a
turn each second. The Feishu client handles explicit provider rate-limit
responses without placing unrelated replies in one shared queue.

The ActorEvent checkpoint is the durable CardKit ledger. It records card IDs,
message IDs, source pages, the active page, stream state, the last confirmed
presentation, and the sequence high-water mark. A restarted process renders
the durable active page as one complete card and replaces the existing message.
It then uses whole-message card edits for that page. It does not infer the
element topology of an old provider card. If the answer needs another page, the
sealed recovered page stays inline and the new tail returns to CardKit.

Each provider mutation uses a strictly increasing sequence. A retry reuses the
same logical UUID and sequence. A changed mutation gets a later sequence.

Working cards use CardKit element and content mutations. Finalization replaces
an existing streamed message with one complete closed card and records that
page as inline. It does not send terminal element batches against provider
topology that can have changed. A card created from an already terminal reply
stays CardKit because its complete content was sent once.

The renderer aims to stay below 24 KiB and 160 elements. It splits Markdown into
source pages of about 12 KiB without changing the stored Markdown.

Only the final open card can show temporary thought, progress, or actions.
Closed cards do not change. If later output would change a closed card, the
final outbox sends a consistent fallback instead.

The stream lease is nine minutes. A known closed-stream error reopens the active
stream. A missing card or an element-topology conflict replaces the active
message with one complete card without sending a second message. Authentication
and permission errors require operator action.

Preview updates can disappear. The final assistant reply remains in the outbox.
SignalsGateway records that reply only after the provider confirms it.

## Let a Job Use Lark Tools

An enabled `lark` Agent Plugin can use a compatible Lark binding. WorkerEnv
resolves one tenant token when the turn starts. It projects these variables:

- `LARKSUITE_CLI_APP_ID`
- `LARKSUITE_CLI_TENANT_ACCESS_TOKEN`
- `LARKSUITE_CLI_BRAND`
- `LARKSUITE_CLI_DEFAULT_AS=bot`
- `LARKSUITE_CLI_STRICT_MODE=bot`

WorkerEnv never sends `appSecret`.

The Agent Plugin enables Skills. The signal binding supplies credentials only
and cannot make a Skill available.

## Import People and Departments

OIDC login resolves the person to `user_id`. Full sync writes users, departments,
and memberships to Principal and AuthZ records.

Real-time user events upsert the user data in the event when it contains a
`user_id`. An incomplete user event, a department event, or a scope change
enqueues a full sync. Disabling WebSocket sync does not disable full directory
sync.

Authentication does not grant console access. AuthZ must resolve the person as
an active human administrator.

## Restart and Recovery

AppConfigure stores encrypted settings. SignalsGateway records messages, Agent
work, and replies. Principals and AuthZ store people, departments, memberships,
and grants.

The adapter converts provider events, runs connections, renders CardKit, and
classifies provider errors. Agent Computer never receives the application
secret.

A control-plane restart rebuilds long connections. The startup job refreshes
stored IM groups, and a full directory sync repairs identity drift. CardKit
checkpoints and outbox rows in PostgreSQL let provider delivery continue. If a
durable reply succeeded while its preview checkpoint stayed open, startup uses
the outbox terminal presentation to replace and close the original card.

## Tests

The repository tests the provider library, declarations, connection handling,
event conversion, stored replies, CardKit recovery, login, and directory sync.
Real provider acceptance needs operator credentials and a compatible client.

The implementation sources are:

- `plugins/lark_adapter/lib/ankole/plugins/lark_adapter.ex`
- `plugins/lark_adapter/lib/ankole/plugins/lark_adapter/`
- `libs/feishu_openapi/`
