# DingTalk Adapter

The DingTalk Adapter receives messages from one enterprise application and
sends Agent replies. It also imports DingTalk users and departments. One Stream
connection can serve both purposes, and the control plane keeps all credentials.

Read [SignalsGateway](../SignalsGateway.md), [Principal](../Principal.md), and
[Plugins](../Plugins.md) for the common message, identity, and Plugin rules.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `dingtalk-adapter` |
| API version | `1` |
| Signal adapter ID | `dingtalk` |
| Signal configuration | `signals_gateway.dingtalk.bindings.<agent_uid>` |
| Identity adapter ID | `dingtalk` |
| Identity configuration | `principals.identity_providers.dingtalk.<id>` |
| Provider library | `libs/dingtalk_openapi` |

The signal adapter supports only `addressed_only`. DingTalk does not deliver
unaddressed group messages to the robot.

Inbound capabilities are `entry_receive` and `action_event`. Outbound
capabilities are `post_entry`, `delete_entry`, and `card`.

The identity adapter supports OIDC authorization, code exchange, full directory
sync, and real-time directory sync.

## Settings

The chat configuration contains these fields:

| Field | Purpose |
| --- | --- |
| `clientId` | Required enterprise application key |
| `clientSecret` | Required encrypted application secret |
| `robotCode` | Overrides the robot code |
| `cardTemplateId` | Selects the DingTalk AI card template |
| `group_message_mode` | Must be `addressed_only` |
| `platformSubjectNamespace` | Selects the Principal subject namespace |
| `userName` | Sets the outbound display name |

Identity settings use the same application credentials. `oidc.*` controls
login, while `sync.*` controls user and department import.

One Agent can have at most one enabled DingTalk binding. One `clientId` cannot
belong to two Agents. The binding save transaction validates both rules.

## Connect to DingTalk

`ConnectionReconciler` selects one Stream connection for each application.
Chat and identity work can share it. `ConnectionSupervisor` runs each connection.

Before each connection, the client gets a new Stream ticket. It handles pings,
disconnects, events, and callbacks. The Stream client acknowledges an event
after its handler finishes.

A crash before acknowledgement can make DingTalk send the event again. Database
keys stop that retry from creating duplicate Ankole records.

## Receive Messages

The robot message callback becomes `entry_receive`, and a card callback becomes
`action_event`. Direct messages always address the Agent. In a group, a
DingTalk mention must address the robot.

The stable channel ID is `dingtalk:<encoded_conversation_id>`. DingTalk has no
anchored reply on this path, so provider thread ID and reply target are empty.

The enterprise `senderStaffId` identifies the sender. The adapter ignores a
message without that field and never uses an encrypted provider ID as a person.

DingTalk gives attachments short-lived download codes. Before ingress, the
adapter tries to download each attachment and save it through WorkerFiles. If
the download or write fails, the adapter logs the failure and emits the message
without a local file. It never stores the temporary code or URL.

DingTalk does not provide inbound edit, recall, or reaction events for this
robot callback path.

## Send Replies

The adapter sends only operations already stored in the outbox. It can send
text, send one attachment, recall a message that it created, or send a template
card.

Text uses the DingTalk Markdown subset and can produce several provider
messages. Supported files use the provider media upload path. An unsupported
file type fails before the adapter reads its bytes.

Recall requires the `processQueryKey` from an earlier adapter send. The adapter
rejects a target without this key.

DingTalk has no general idempotency key or history query for this API. A crash
after a send can create a duplicate. The adapter cannot reconcile an uncertain
send.

## Show a Live AI Card

`AICard` shows the reply preview. It uses the configured `cardTemplateId` and a
deterministic `outTrackId` for each page.

DingTalk owns the card state transition. A stream stays open until the adapter
sends `isFinalize`, and `isError` selects the failed state. The template does
not use a custom flow-status variable.

The ActorEvent checkpoint is the durable page ledger. It stores the source
text, `outTrackId`, and sealed state for each page. It also stores the last
presentation that recovery can render and any thought cleanup deadline. Sealed
pages do not change. Only the open tail page can receive Markdown updates.

Working card updates never send plain text. If the template is missing, the
provider rejects the content, or an update would change a sealed page, the
durable final outbox sends plain text. The checkpoint records each delivered
text chunk, so an outbox retry resumes after the last recorded chunk.

The operator must build the template described in
`plugins/dingtalk_adapter/priv/card_template/README.md`.

## Import People and Departments

Login resolves the enterprise user ID before it returns a Principal. Full sync
reads departments, users, and memberships.

Real-time user events fetch the current user before each update. A user
departure disables the named subject. Department changes, organization
removal, and incomplete user events enqueue a full sync.

## Restart and Recovery

AppConfigure stores encrypted settings. SignalsGateway records messages, Agent
work, and replies. Principals and AuthZ store people, groups, memberships, and
grants.

A control-plane restart rebuilds Stream connections. Full directory sync
repairs suspected identity drift. Agent Computer does not receive DingTalk
credentials.

## Tests

The repository tests the provider client, Stream dispatch, normalization,
outbox operations, AI card checkpoints, login, and directory sync. A real
DingTalk acceptance test needs operator credentials and the configured card
template.

The implementation sources are:

- `plugins/dingtalk_adapter/lib/ankole/plugins/dingtalk_adapter.ex`
- `plugins/dingtalk_adapter/lib/ankole/plugins/dingtalk_adapter/`
- `libs/dingtalk_openapi/`
