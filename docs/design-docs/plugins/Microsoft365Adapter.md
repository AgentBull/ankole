# Microsoft 365 Adapter

The Microsoft 365 Adapter receives Teams messages, sends Agent replies, and
imports people and groups from Entra ID. Chat and identity use separate
settings. The control plane keeps all Microsoft credentials.

Read [SignalsGateway](../SignalsGateway.md), [Principal](../Principal.md), and
[Plugins](../Plugins.md) for the common message, identity, and Plugin rules.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `microsoft365-adapter` |
| API version | `1` |
| Signal adapter ID | `teams` |
| Signal configuration | `signals_gateway.teams.bindings.<id>` |
| Identity adapter ID | `entra-id` |
| Identity configuration | `principals.identity_providers.entra-id.<id>` |
| Subscription state | `principals.entra_id.graph_subscriptions.<id>` |
| Provider library | `libs/microsoft_openapi` |

The plugin also declares two webhook handlers. `teams` accepts `messages`.
`entra-id` accepts `directory`.

The signal adapter supports all three group modes. Inbound capabilities are
`entry_receive`, `entry_removed`, `reaction_add`, `reaction_remove`, and
`action_event`.

Outbound capabilities are `post_entry`, `reply_entry`, `edit_entry`,
`delete_entry`, `divider`, and `card`. The adapter does not declare outbound
reactions or outbound reconciliation.

The identity adapter supports OIDC authorization, code exchange, full directory
sync, and real-time directory sync.

## Receive Microsoft Webhooks

Azure Bot Service sends activities to this route:

```text
https://<host>/webhooks/v1/teams/<appID>/messages
```

Microsoft Graph sends directory notifications to this route:

```text
https://<host>/webhooks/v1/entra-id/<provider_id>/directory
```

The Teams handler checks the Bot Framework token before it loads a binding. The
token audience must match `appID`. The handler completes durable SignalsGateway
ingress before it returns status 200.

The directory handler checks the stored `clientState`. For an update, it fetches
the current Graph object before it changes Principal or AuthZ records. For a
group deletion, it disables the group by ID. It ignores user deletions until a
later full sync.

## Settings

The Teams configuration contains `appID`, encrypted `appPassword`,
`botTenancy`, and optional `tenantID`. It also contains
`platformSubjectNamespace` and `userName`.

The Entra ID configuration contains `tenantID`, `clientID`, and encrypted
`clientSecret`. The `oidc.*` fields control login. The `sync.*` fields control
full and real-time directory sync.

Real-time sync also requires `publicBaseURL`. `SubscriptionReconciler` uses this
URL to create the Graph notification route. It runs at startup, after the host
saves identity settings, and every six hours. AppConfigure stores subscription
IDs and `clientState` values under the subscription state key.

## Receive Teams Messages

The Teams handler accepts messages, soft deletes, reactions, Adaptive Card
submissions, and conversation events. It ignores message edits,
undeletes, and unsupported invoke activities.

Personal chats give explicit input. A mention entity for the current bot makes
a group or channel message explicit. SignalsGateway applies the configured
group policy to other messages.

The stable signal channel ID uses the base Teams conversation ID. Channel
threads use the thread root from the conversation ID. The activity ID is the
source entry ID.

The default `addressed_only` mode needs only normal bot delivery. The other
group modes require the Teams application to receive unaddressed messages.
The application manifest must grant the required RSC read permissions.

## Learn Channels and Send Replies

Teams has no API that lists every bot conversation. The adapter learns a
conversation when it receives a message. It then imports known channels and
members through connector APIs.

The adapter stores the regional service URL with the channel record. It cannot
guess this URL before it sees the conversation.

The adapter sends only operations already stored in the outbox. It can post,
reply, edit, delete, send a divider, or render an Adaptive Card. It cannot send
files or reactions.

Bot Framework has no read-back API for this path. An interrupted send can
remain `unknown_after_send`. The adapter does not claim reconciliation.

## Import People and Groups

OIDC login reads the current user through Microsoft Graph. The Graph directory
object ID becomes the external subject ID. Teams authors use the activity
`aadObjectId`, so chat and directory sync can resolve the same Principal.

Full sync reads groups before users. It keeps direct user memberships and does
not expand nested groups. Full sync skips disabled users. It also skips guest
users unless `sync.includeGuests` is true.

Graph subscriptions cover users and groups. The reconciler creates and renews
them. Periodic full sync repairs changes missed by notifications.

## Restart and Recovery

AppConfigure stores encrypted settings and subscription state. SignalsGateway
records messages, Agent work, and replies. Principals and AuthZ store people,
groups, memberships, and grants.

The adapter authenticates to Microsoft, converts events, and renews
subscriptions. Agent Computer never receives Microsoft credentials.

After a restart, startup sync enqueues a channel refresh for each enabled Teams
binding. `SubscriptionReconciler` also checks each active Entra provider and
ensures or removes its Graph subscriptions.

## Tests

The repository tests provider HTTP behavior, token verification, webhook
dispatch, normalization, outbox mapping, directory sync, and subscriptions.
A real Microsoft acceptance test needs operator credentials and a public HTTPS
deployment instance.

The implementation sources are:

- `plugins/microsoft365_adapter/lib/ankole/plugins/microsoft365_adapter.ex`
- `plugins/microsoft365_adapter/lib/ankole/plugins/microsoft365_adapter/`
- `libs/microsoft_openapi/`
