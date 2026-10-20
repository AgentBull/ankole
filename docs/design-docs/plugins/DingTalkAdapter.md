# DingTalk Adapter

The DingTalk Adapter receives messages from one enterprise application and
sends Agent replies. It also imports DingTalk users and departments. One Stream
connection can serve both purposes, and the control plane keeps all credentials.

Read [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Plugins](../Plugins.md) for the common message, identity, and Plugin rules.

## Provider and Public Identity

The adapter reports an opaque `provider_conversation_id` and a
`provider_message_id`. Conversations resolves these to a shared public
Conversation UUID and Message UUID. All Agent observers of the same provider
conversation in one tenant read those same public facts. Each participating
Agent has its own `conversation:<public UUID>` Session; a Binding is its
observation and delivery route, not the owner of the platform room.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `dingtalk-adapter` |
| API version | `1` |
| Signal adapter ID | `dingtalk` |
| Signal configuration | `signals.dingtalk.bindings.<agent_uid>` |
| Identity adapter ID | `dingtalk` |
| Identity configuration | `principals.identity_providers.dingtalk.<id>` |
| Provider library | `plugins/dingtalk_adapter/lib/dingtalk_openapi` |

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
| `identityProvider` | References the identity provider that owns the Principal subject namespace; a single provider is adopted by default, several require a choice, `:standalone` keeps the adapter default |
| `userName` | Sets the outbound display name |

Identity settings use the same application credentials. `oidc.*` controls
login, while `sync.*` controls user and department import.

One Agent can have at most one enabled DingTalk binding. One `clientId` cannot
belong to two Agents. The binding save transaction validates both rules.

## Connect to DingTalk

`ConnectionReconciler` selects one Stream connection for each application.
Chat and identity work can share it. `Ankole.Plugins.ConnectionLifecycle`
supervises one Stream client for each connection. The client is a temporary
child. If it exits, `ConnectionLifecycle` restarts that key immediately once,
then waits 5 seconds and 30 seconds between further attempts. Other connections
stay connected.

Before each connection, the client gets a new Stream ticket. It handles pings,
disconnects, events, and callbacks. The Stream client acknowledges an event
after its handler finishes.

A crash before acknowledgement can make DingTalk send the event again. Database
keys stop that retry from creating duplicate Ankole records.

## Receive Messages

The robot message callback becomes `entry_receive`, and a card callback becomes
`action_event`. Direct messages always address the Agent. In a group, a
DingTalk mention must address the robot.

The opaque `provider_conversation_id` is `dingtalk:<encoded_conversation_id>`. DingTalk has no
anchored reply on this path, so provider thread ID and reply target are empty.

The enterprise `senderStaffId` identifies the sender. The adapter ignores a
message without that field and never uses an encrypted provider ID as a person.

DingTalk gives attachments short-lived download codes. Before ingress, the
adapter tries to download each attachment and store it in the file service
([Files](../Files.md)). If the download or the write fails, the adapter logs
the failure and emits the message without stored bytes. It never stores the temporary code or URL.

DingTalk does not provide inbound edit, recall, or reaction events for this
robot callback path.

## Send Replies

The adapter sends only operations already stored as Delivery intents. It can send
text, send one attachment, recall a message that it created, or send a template
card.

Text uses the DingTalk Markdown subset and can produce several provider
messages. Supported files use the provider media upload path. An unsupported
file type fails before the adapter reads its bytes.

Markdown conversion changes prose only. The kernel uses CommonMark source
positions to protect the original bytes of fenced, indented, and inline code.
The existing AI Card stream keeps its own rendering and paging rules.

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

The Signal checkpoint is the durable page ledger. It stores the source
text, `outTrackId`, and sealed state for each page. It also stores the last
presentation that recovery can render and any thought cleanup deadline. Sealed
pages do not change. Only the open tail page can receive Markdown updates.

`PreviewAdapter.put_thought_lease/4` computes the shared `cleanup_at` field.
The adapter supplies its lease duration and final-state flag. A final update or
an update without visible thought removes the deadline. Provider-specific
stream deadlines and page transitions stay in the adapter.

Working card updates never send plain text. If the template is missing, the
provider rejects the content, or an update would change a sealed page, the
durable final Delivery sends plain text. The checkpoint records each delivered
text chunk, so an intent retry resumes after the last recorded chunk.

The operator must build the template described in
`plugins/dingtalk_adapter/priv/card_template/README.md`.

## Import People and Departments

Login resolves the enterprise user ID before it returns a Principal. Full sync
reads departments, users, and memberships.

Real-time user events fetch the current user before each update. A user
departure records a provider restriction through `DirectoryAccess`, including
the last active Human administrator. The stable Stream `eventId` and each user
ID form the event deduplication key. The adapter retains `eventBornTime` when
present. A missing event ID fails processing so Stream requests redelivery.
An unknown subject remains blocked from later admission. A departure without
user IDs remains recorded for review and queues a full sync.

Full sync records a snapshot under the current provider configuration. Complete
department and user pagination is required; missing or repeated cursors fail
the sync. A successful current snapshot can provide evidence to clear a
provider restriction after review. Login and partial sync cannot provide that
evidence. No sync automatically restores a Human, clears a manual restriction,
or disables missing members. Department changes and organization removal
enqueue a full sync. See [Human Offboarding](../HumanOffboarding.md) for
restriction clearance and restoration.

## Restart and Recovery

AppConfigure stores encrypted settings. Conversations records public Messages and Delivery intents. Signals stores
authorized stimuli; Sessions owns Agent execution and recovery. Principals and AuthZ store people, groups, memberships, and
grants.

A control-plane restart rebuilds Stream connections. Full directory sync
repairs suspected identity drift. Agent Computer does not receive DingTalk
credentials.

## Tests

The repository tests the provider client, Stream dispatch, normalization,
intent operations, AI card checkpoints, login, and directory sync. A real
DingTalk acceptance test needs operator credentials and the configured card
template.

The implementation sources are:

- `plugins/dingtalk_adapter/lib/ankole/plugins/dingtalk_adapter.ex`
- `plugins/dingtalk_adapter/lib/ankole/plugins/dingtalk_adapter/`
- `plugins/dingtalk_adapter/lib/dingtalk_openapi/`
