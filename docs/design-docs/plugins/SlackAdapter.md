# Slack Adapter

The Slack Adapter receives messages from one Slack app, sends Agent replies,
and imports people and user groups. Chat and identity use separate settings.
The control plane keeps all Slack tokens.

Read [SignalsGateway](../SignalsGateway.md), [Principal](../Principal.md), and
[Plugins](../Plugins.md) for the common message, identity, and Plugin rules.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `slack-adapter` |
| API version | `1` |
| Signal adapter ID | `slack` |
| Signal configuration | `signals_gateway.slack.bindings.<id>` |
| Identity adapter ID | `slack` |
| Identity configuration | `principals.identity_providers.slack.<id>` |
| Provider library | `libs/slack_openapi` |

The signal adapter supports all three group modes. They are
`addressed_only`, `observe_all`, and `may_intervene`.

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
| `botToken` | Required Bot User OAuth token |
| `appToken` | Required App-Level token for Socket Mode |
| `platformSubjectNamespace` | Selects the Principal subject namespace |
| `userName` | Sets the outbound display name |

The identity configuration contains `clientID`, `clientSecret`, and optional
`teamID`. It also contains `botToken` and `appToken` for directory work. The
`oidc.*` and `sync.*` fields control login and directory sync.

One `platformSubjectNamespace` identifies one Slack workspace. Do not change it
when only the workspace display name changes.

## Connect through Socket Mode

Socket Mode is the only event ingress path. The adapter does not expose Slack
HTTP Events API, slash-command, or request-signature routes.

Chat and identity work can share one Socket Mode connection when they use the
same app token and bot token. If the app token matches but the bot token does
not, the reconciler reports a credential conflict. `ConnectionReconciler`
selects the required connections, and `ConnectionSupervisor` runs them. A
restart rebuilds the connection list.

The Socket Mode client processes an event before it acknowledges it. Slack can
send the event again after a crash. Database keys prevent duplicate Ankole
records.

## Receive Messages and Learn Channels

The adapter accepts messages, deletions, reactions, Block Kit actions, and
channel events. It also accepts user and user-group events for
directory sync.

The adapter normalizes each accepted chat event and submits it through
SignalsGateway ingress. SignalsGateway owns the provider mirror and creates
ActorEvents.

The stable channel ID is `slack:<channel_id>`. The message timestamp is the
source entry ID. A reply uses the root message timestamp as its reply target.
Thread identity uses the channel ID and root timestamp.

Direct messages give explicit input. A mention of the current bot makes a group
message explicit. SignalsGateway applies the configured group policy to other
group messages.

The adapter ignores bot and app senders. It also ignores `message_changed`
because the common input format has no entry-edit event. A `message_deleted` event
becomes `entry_removed`.

The adapter downloads inbound files and stores successful downloads through
WorkerFiles. If a download fails, it logs the failure and keeps the provider
reference without a local file. A message that refers to a recent file or image
can reuse up to three attachments from the same sender and channel from the
previous 120 seconds.

Startup and refresh jobs materialize channel projections and AuthZ memberships
in PostgreSQL. Slack only transports the source events.

## Send Replies

The adapter sends only operations already stored in the outbox. It uses
`chat.postMessage`, `chat.update`, `chat.delete`, and reaction methods. It
renders cards as Block Kit and text as Slack `mrkdwn`.

The adapter supports one outbound attachment per outbox row. It uses Slack
external upload operations for that attachment. Long text can create more than
one Slack message.

Slack has no general idempotency key for `chat.postMessage`. Reconciliation
uses the recorded provider timestamp to check message history. A row without a
provider timestamp or a history response without that message returns
`unknown`. A Slack API failure returns an error.

## Import People and User Groups

OIDC login normalizes Slack claims. If a bot token is present, it also tries to
load the full user through `users.info`. The Principal login flow receives that
user, but AuthZ still decides whether the person can use Ankole.

Full sync imports users and user groups. Real-time user and user-group events
update the same Principal and AuthZ records. If a user-group event omits
members, the adapter requests the complete member list.

## Restart and Recovery

AppConfigure stores encrypted settings. SignalsGateway records messages, Agent
work, and replies. Principals and AuthZ store people, groups, memberships, and
grants.

A control-plane restart rebuilds Socket Mode connections. Startup jobs refresh
the stored channel records. Run a full directory sync when Slack and Ankole
might differ.

## Tests

The repository tests the provider library, declaration, event conversion,
stored replies, directory imports, and end-to-end flows with local HTTP fixtures.
Real Slack acceptance needs operator credentials that the repository does not
contain.

The implementation sources are:

- `plugins/slack_adapter/lib/ankole/plugins/slack_adapter.ex`
- `plugins/slack_adapter/lib/ankole/plugins/slack_adapter/`
- `libs/slack_openapi/`
