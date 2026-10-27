# Slack Adapter

The Slack Adapter receives events from one Slack application over Socket Mode,
sends Agent replies, and synchronizes Slack workspace members and user groups.
Chat bindings and identity providers use separate settings, while all Slack
tokens remain on the control plane.

See [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Plugins](../Plugins.md) for the shared messaging, identity, and Plugin
contracts.

## Provider and Public Identity

On inbound events, the adapter reports an opaque `provider_conversation_id` and
`provider_message_id`, which `Conversations` resolves to a shared public
Conversation UUID and Message UUID. Every Agent observing that Slack channel or
DM within the same tenant reads those shared public records while running in its
own `conversation:<public UUID>` Session—a Binding defines an observation and
delivery route rather than owning the Slack channel.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `slack-adapter` |
| API version | `1` |
| Signal adapter ID | `slack` |
| Signal configuration | `signals.slack.bindings.<id>` |
| Identity adapter ID | `slack` |
| Identity configuration | `principals.identity_providers.slack.<id>` |
| Provider library | `plugins/slack_adapter/lib/slack_openapi` |

The Signal adapter supports all three group-message modes (`addressed_only`,
`observe_all`, and `may_intervene`), inbound capabilities `entry_receive`,
`entry_removed`, `reaction_add`, `reaction_remove`, and `action_event`, and
outbound capabilities `post_entry`, `reply_entry`, `edit_entry`, `delete_entry`,
`outbound_reconciliation`, `add_reaction`, `remove_reaction`, `divider`, and
`card`.

On the identity side, the adapter supports OIDC authorization, OIDC code
exchange, full directory sync, and real-time directory sync.

## Settings

Chat bindings configure these fields:

| Field | Purpose |
| --- | --- |
| `botToken` | Required Bot User OAuth token |
| `appToken` | Required App-Level token for Socket Mode |
| `identityProvider` | References the identity provider that owns the Principal subject namespace; a single provider is adopted by default, several require a choice, `:standalone` keeps the adapter default |
| `userName` | Sets the outbound display name |

Identity-provider configurations store `clientID`, `clientSecret`, optional
`teamID`, plus `botToken` and `appToken` for directory sync, using `oidc.*` and
`sync.*` keys to govern login and directory imports. Linking `identityProvider`
selects which Slack workspace namespace resolves inbound message authors;
bindings with no Slack identity provider—or set explicitly to `:standalone`—use
the default `slack-main` namespace.

## Connect through Socket Mode

All inbound Slack events arrive over Socket Mode—the adapter exposes no HTTP
Events API, slash-command, or Slack request-signature endpoints.

Chat bindings and real-time directory sync share a single Socket Mode WebSocket
whenever both `appToken` and `botToken` match; if `appToken` matches while
`botToken` differs, `ConnectionReconciler` flags a credential conflict.
`Ankole.Plugins.ConnectionLifecycle` supervises one temporary Socket Mode client
per connection key: if a client exits, `ConnectionLifecycle` restarts it
immediately once and then backs off to 5 seconds and 30 seconds while leaving
other connections undisturbed, rebuilding active connections on node restart.

When a Socket Mode client starts, it resolves its bot identity once and shares
that result across co-located consumers; if that lookup fails, startup aborts
and retries on the next reconciliation pass, whereas already healthy connections
compare only configured credentials so a transient Slack API hiccup never
evicts their resolved bot identity. Each incoming Socket Mode envelope is
acknowledged only after its handler commits, and Ankole's durable database keys
deduplicate any events replayed after a crash.

## Observe Messages and Provider Conversations

The Socket Mode listener accepts messages, `message_deleted` events (mapped to
`entry_removed`), emoji reactions, Block Kit interactive actions, public/private
channel events (including their distinct rename event types), and real-time user
and user-group directory events. Messages from bots or apps—as well as
`message_changed` edits—are ignored. Chat events normalize through
`Conversations.Observe` and enqueue required work via
`Ankole.Signals.accept_in_tx/1`.

Conversations use `provider_conversation_id` `slack:<channel_id>` and use the
Slack message `ts` as `provider_message_id`. Thread replies set the root message
`ts` as their reply target and track `(channel_id, thread_ts)` separately from
the public Conversation UUID. Direct messages and channel messages that
@-mention the current bot count as explicit input—and once the Agent replies
inside a Slack thread, subsequent human replies in that thread continue to count
as explicit input without needing another @-mention—while other channel messages
follow the binding's group-message policy. Note that in the Slack App
configuration, **App Home** must enable the **Messages Tab** and allow users to
send messages (`message.im` and `im:*` scopes deliver DM events, whereas the
App Home toggle unlocks the DM composer in Slack clients).

For inbound file attachments, the adapter first writes a durable `pending`
attachment projection with a stable numeric attachment ID, downloads the file
into the file service ([Files](../Files.md)), and marks the attachment
`complete` (or `failed` while retaining the Slack file metadata without local
bytes). When a user mentions the Agent and refers to an earlier upload without
re-attaching it, the adapter can reuse up to three files uploaded by that same
sender in the same channel within the previous 120 seconds. Background startup
and refresh jobs sync channel metadata and `AuthZ` memberships into PostgreSQL
so Slack serves strictly as the event transport.

## Send Replies

Outbound execution processes only durable Delivery intents—calling
`chat.postMessage`, `chat.update`, `chat.delete`, and reaction endpoints,
formatting rich cards with Block Kit and prose with Slack `mrkdwn`.

Each streaming Agent reply owns one or more Slack messages inside the target
thread, persisting their Slack `ts` values in the Signal's PostgreSQL reply
checkpoint and updating them in place via `chat.update` so restarts and final
delivery repaint the same Slack messages rather than posting duplicates (long
replies split across multiple messages in the same thread). Interactive Block
Kit buttons carry the full Ankole interaction protocol: on click, the adapter
resolves the Slack user to an active Principal and repaints answered or
superseded controls; because Slack message blocks lack inline text-input
submission, free-text clarifications prompt the user to reply directly in the
Slack thread.

Each Delivery intent can include one outbound file attachment, uploaded via
Slack's three-step external upload flow (`files.getUploadURLExternal`, byte
upload, and `files.completeUploadExternal`) alongside the separate text/Block
Kit message. Transient transport, `429` rate-limit, and `5xx` errors follow the
standard retry schedule, whereas deterministic Slack errors—such as a missing
`files:write` scope—block the intent for operator repair (recording the Slack
error code and required scope without storing the raw payload). Because
`chat.postMessage` accepts no caller idempotency key, `outbound_reconciliation`
checks channel history for the recorded Slack `ts`—returning `unknown` if no
timestamp was recorded or if history omits that message, and returning an error
if the Slack history call itself fails.

## Slack App Capabilities

In the Slack App configuration:

- **App-Level Token:** requires `connections:write`.
- **Bot Token:** requires `app_mentions:read`, channel and message read scopes
  across all desired conversation types, `chat:write`, `reactions:read`,
  `reactions:write`, `files:read`, `files:write`, and `users:read` (plus
  `users:read.email` and `usergroups:read` when directory sync is enabled).
- **Features:** enable **Socket Mode**, **Event Subscriptions**, and
  **Interactivity**—Socket Mode multiplexes both Events API frames and Block Kit
  button payloads over its outbound WebSocket without requiring any public
  inbound webhook URL (see the website Quick start guide for the full manifest
  list).

## Import People and User Groups

During OIDC sign-in, the adapter normalizes Slack identity claims—enriching them
via `users.info` whenever a `botToken` is configured—before handing the user to
`Principals` and `AuthZ`. Full directory sync imports workspace members and user
groups, and real-time user / user-group Socket Mode events update the same
`Principal` and `AuthZ` tables (fetching the full member roster whenever a
user-group event omits member IDs).

## Restart and Recovery

PostgreSQL persists encrypted tokens in `AppConfigure`, public Messages and
Delivery intents in `Conversations`, accepted stimuli in `Signals`, execution
state in `Sessions`, and people, groups, memberships, and grants in `Principals`
and `AuthZ`. Control-plane restarts automatically reconnect Socket Mode clients
and refresh cached channel metadata; operators run a full directory sync
whenever Slack and Ankole may have drifted.

## Tests

Automated tests cover `slack_openapi`, plugin declarations, Socket Mode event
normalization, checkpointed outbound replies, directory sync, and end-to-end
flows against local HTTP fixtures; live Slack acceptance testing requires
operator workspace tokens outside the repository.

Implementation paths:

- `plugins/slack_adapter/lib/ankole/plugins/slack_adapter.ex`
- `plugins/slack_adapter/lib/ankole/plugins/slack_adapter/`
- `plugins/slack_adapter/lib/slack_openapi/`
