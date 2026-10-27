# Microsoft 365 Adapter

The Microsoft 365 Adapter receives Microsoft Teams messages, sends Agent
replies, and imports users and groups from Microsoft Entra ID. Teams chat
bindings and Entra ID identity providers use separate settings, while all
Microsoft credentials remain on the control plane.

See [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Plugins](../Plugins.md) for the shared messaging, identity, and Plugin
contracts.

## Provider and Public Identity

On inbound Teams activities, the adapter reports an opaque
`provider_conversation_id` and `provider_message_id`, which `Conversations`
resolves to a shared public Conversation UUID and Message UUID. Every Agent
observing that Teams conversation within the same tenant reads those shared
public records while running in its own `conversation:<public UUID>` Session—a
Binding defines an observation and delivery route rather than owning the Teams
channel or chat.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `microsoft365-adapter` |
| API version | `1` |
| Signal adapter ID | `teams` |
| Signal configuration | `signals.teams.bindings.<id>` |
| Identity adapter ID | `entra-id` |
| Identity configuration | `principals.identity_providers.entra-id.<id>` |
| Subscription state | `principals.entra_id.graph_subscriptions.<id>` |
| Provider library | `plugins/microsoft365_adapter/lib/microsoft_openapi` |

The plugin registers two HTTP webhook handlers: `teams` handles `messages`, and
`entra-id` handles `directory`.

The `teams` Signal adapter supports all three group-message modes, inbound
capabilities `entry_receive`, `entry_removed`, `reaction_add`,
`reaction_remove`, and `action_event`, and outbound capabilities `post_entry`,
`reply_entry`, `edit_entry`, `delete_entry`, `divider`, and `card` (without
outbound reactions or `outbound_reconciliation`).

The `entra-id` identity adapter supports OIDC authorization, OIDC code exchange,
full directory sync, and real-time directory sync.

## Receive Microsoft Webhooks

Azure Bot Service posts Teams activities to:

```text
https://<host>/webhooks/v1/teams/<appID>/messages
```

Microsoft Graph posts Entra ID change notifications to:

```text
https://<host>/webhooks/v1/entra-id/<provider_id>/directory
```

Before loading any binding, the Teams handler verifies the Bot Framework JWT:
its `aud` claim must match `<appID>` and its `serviceurl` claim must match the
activity payload's `serviceUrl`. The handler then completes durable
`Conversations.Observe` before returning HTTP `200`.

On the Entra ID webhook, the handler verifies the stored `clientState` secret:
user or group updates re-fetch the live object from Microsoft Graph before
mutating `Principal` or `AuthZ` rows, group deletions disable the corresponding
group by ID, and user deletions wait for the next full directory sync.

## Settings

Teams chat bindings configure `appID`, encrypted `appPassword`, `botTenancy`,
optional `tenantID`, `userName`, and `identityProvider` (referencing the Entra
ID identity provider that owns the Principal subject namespace, with a single
configured provider adopted automatically by default).

Entra ID identity providers configure `tenantID`, `clientID`, and encrypted
`clientSecret`, using `oidc.*` keys for sign-in and `sync.*` keys for full and
real-time directory imports. Enabling real-time Graph notifications also
requires `publicBaseURL`: `SubscriptionReconciler` uses that URL to register and
renew Graph change subscriptions at node startup, after saving identity
settings, and every six hours, persisting subscription IDs and `clientState`
secrets in `AppConfigure` under `principals.entra_id.graph_subscriptions.<id>`.

## Receive Teams Messages

The Teams webhook handler processes messages, soft deletes, emoji reactions,
Adaptive Card action submissions, and conversation-update events, while ignoring
message edits, undeletes, and unsupported invoke activities.

Personal 1-on-1 chats always count as explicit input; in group chats and Teams
channels, an @-mention entity targeting the current bot counts as explicit
input, while other messages follow the binding's group-message policy. While the
default `addressed_only` mode works with standard Bot Framework delivery,
`observe_all` and `may_intervene` require the Teams app manifest to grant the
Resource-Specific Consent (RSC) read permissions needed to receive unaddressed
messages.

The adapter derives `provider_conversation_id` from the base Teams conversation
ID—anchoring channel threads on the thread root parsed from the conversation
ID—and uses the Bot Framework activity ID as `provider_message_id`.

## Observe Conversations and Deliver Replies

Because Microsoft Teams offers no API to enumerate all conversations in which a
bot is installed, the adapter discovers conversations organically when messages
arrive, recording the activity's regional `serviceUrl` on the channel record
(which cannot be guessed beforehand) and importing known channels and members
through Bot Connector APIs.

Outbound execution processes only durable Delivery intents: posting, replying,
editing, deleting, sending dividers, and rendering Adaptive Cards (outbound file
uploads and emoji reactions are not supported). Before paging text at 12,000
graphemes, the Rust kernel converts prose Markdown once while using CommonMark
byte spans to preserve fenced, indented, and inline code verbatim.

Because Bot Framework provides no outbound read-back endpoint on this path, the
adapter omits `outbound_reconciliation` and settles uncertain sends as
`unknown`; operators can manually requeue a visible durable reply once with a
possible-duplicate notice, while other uncertain operations stay stopped.

## Import People and Groups

OIDC sign-in loads the signed-in user from Microsoft Graph and uses the Entra
directory object ID as `external_id`; because Teams activities carry that same
ID in `aadObjectId`, Teams chat senders and synced Entra users resolve to the
same Principal automatically.

Full directory sync imports groups before users, recording direct user
memberships without expanding nested groups and skipping disabled accounts (plus
guest accounts unless `sync.includeGuests` is `true`). `SubscriptionReconciler`
maintains Graph change subscriptions for users and groups, while periodic full
syncs heal any notifications missed in transit.

## Restart and Recovery

PostgreSQL persists encrypted settings and Graph subscription state in
`AppConfigure`, public Messages and Delivery intents in `Conversations`,
accepted stimuli in `Signals`, execution state in `Sessions`, and people,
groups, memberships, and grants in `Principals` and `AuthZ`. Agent Computer
never receives Microsoft credentials. On control-plane startup, background jobs
refresh stored channel metadata for enabled Teams bindings, and
`SubscriptionReconciler` ensures or prunes Graph subscriptions across active
Entra ID providers.

## Tests

Automated tests cover `microsoft_openapi` HTTP behavior, Bot Framework JWT
verification, webhook routing, activity normalization, Delivery intent mapping,
Entra directory sync, and Graph subscription lifecycle; live Microsoft 365
acceptance testing requires operator credentials and a publicly reachable HTTPS
endpoint.

Implementation paths:

- `plugins/microsoft365_adapter/lib/ankole/plugins/microsoft365_adapter.ex`
- `plugins/microsoft365_adapter/lib/ankole/plugins/microsoft365_adapter/`
- `plugins/microsoft365_adapter/lib/microsoft_openapi/`
