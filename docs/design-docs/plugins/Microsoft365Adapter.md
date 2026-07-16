# Microsoft 365 Adapter

The Microsoft 365 plugin connects one Microsoft tenant to Ankole through two
independent host-owned contracts:

- Microsoft Teams chat ingress and provider-visible output through
  SignalsGateway;
- optional Entra ID login and directory synchronization through Principals.

The two contracts may use apps in the same tenant, but they have separate
configuration and save boundaries and either can run without the other. The
plugin is trusted first-party Elixir code running in the control plane. Agent
Computer never talks to Microsoft directly.

For the shared boundaries, see `docs/design-docs/Plugins.md`,
`docs/design-docs/SignalsGateway.md`, and `docs/design-docs/Principal.md`.

## Stable Names

The public names are:

- plugin id: `microsoft365-adapter`;
- SignalsGateway adapter id: `teams`;
- identity-provider adapter id: `entra-id`;
- webhook handler ids: `teams` (kind `messages`) and `entra-id`
  (kind `directory`);
- chat configuration pattern: `signals_gateway.teams.bindings.<id>`;
- identity configuration pattern: `principals.identity_providers.entra-id.<id>`;
- subscription state pattern: `principals.entra_id.graph_subscriptions.<id>`;
- default platform-subject namespace: `entra-id-main`.

One `platformSubjectNamespace` represents one Entra tenant. Teams users are
Entra users: the chat adapter identifies authors by their Entra directory
object id (the activity's `aadObjectId`), so with the default namespace the
same person resolves to the same Principal whether they arrive through chat or
directory sync. The Teams-internal `29:` ids are provider metadata, never
subject identity.

## Webhook Model

Unlike the Lark and Slack adapters, Microsoft offers no outbound
long-connection transport: Azure Bot Service pushes Teams activities to an
HTTPS messaging endpoint and Graph pushes directory change notifications to an
HTTPS notification endpoint. The installation must therefore be reachable over
public HTTPS (a reverse proxy or tunnel is fine). Both pushes land on the
host's standardized webhook route:

- Azure Bot messaging endpoint (pasted into the Azure Bot registration):
  `https://<host>/webhooks/v1/teams/{appID}/messages`;
- Graph notification endpoint (set programmatically per provider):
  `https://<host>/webhooks/v1/entra-id/{provider_id}/directory`.

The Teams instance segment is the Microsoft App ID because Azure Bot
configures one endpoint per app while several bindings may share one app; the
handler verifies the connector JWT (audience must equal that app id) before
looking anything up, then fans the activity out to every enabled binding
configured with the app. Processing completes before the 200 is returned;
connector redelivery is absorbed by the gateway's
`(agent_uid, binding_name, source_event_id)` idempotency.

## Plugin Declaration

`Ankole.Plugins.Microsoft365Adapter` declares four contracts: the
`signals_gateway.adapter` (id `teams`), a `signals_gateway.webhook_handler`
for `teams/messages`, the `principals.identity_provider` (id `entra-id`), and
a second webhook handler for `entra-id/directory`.

The chat declaration exposes `Inbound` as the ingress module, `Outbox` as the
durable side-effect adapter, and `TeamsChannels` for binding-save
synchronization. There is no connection supervisor — webhooks have no
connection to own. Group-message modes `addressed_only`, `observe_all`, and
`may_intervene` are declared, with the manifest caveat below.

Inbound capabilities are `entry_receive`, `entry_removed`, `reaction_add`,
`reaction_remove`, and `action_event`. Outbound capabilities are `post_entry`,
`reply_entry`, `edit_entry`, `delete_entry`, `divider`, and `card` — and
deliberately not `add_reaction`/`remove_reaction` (Bot Framework cannot send
message reactions) nor `outbound_reconciliation` (the connector has no
read-back API, so a send interrupted mid-flight stays `unknown_after_send`).

The identity declaration exposes OIDC authorization and code exchange, full
directory synchronization, and realtime directory synchronization, with
`SubscriptionReconciler` as the save-time reconcile hook.

## Configuration

Chat configuration is encrypted and contains:

- `appID`: the Azure Bot registration's Microsoft App ID (a GUID);
- `appPassword`: the app's client secret;
- `botTenancy`: `single_tenant` (default) or `multi_tenant` — it selects the
  token tenant for Bot Connector calls (the app's own tenant vs. the literal
  `botframework.com`);
- `tenantID`: required for single-tenant apps;
- `platformSubjectNamespace`: defaults to `entra-id-main`;
- `userName`: outbound display name, default `Teams`;
- advanced `loginBaseURL` and `openIDMetadataURL` overrides for
  provider-compatible local testing.

Identity-provider configuration is also encrypted and contains:

- `tenantID`, `clientID`, and encrypted `clientSecret` for the Entra app
  registration;
- `oidc.enabled` and `oidc.scopes` (default
  `openid profile email User.Read`);
- `sync.contacts`, `sync.realtime`, `sync.pageSize`, `sync.groupsFilter`, and
  `sync.includeGuests`;
- `publicBaseURL`: the installation's public HTTPS address, required when
  realtime sync is enabled — Graph subscriptions are created from background
  jobs, which cannot derive the public URL from a request;
- advanced `loginBaseURL` and `graphBaseURL` overrides for testing.

Realtime sync is forced off when contact sync itself is off. Secrets are
resolved only at provider-call boundaries and must not be logged.

## Provider Library

Provider protocol code lives in `libs/microsoft_openapi`. The library owns:

- Entra v2.0 OAuth: authorization URLs, authorization-code exchange, and
  cached client-credentials tokens;
- Microsoft Graph requests, OData nextLink pagination, and Microsoft-shaped
  error classification including 429 Retry-After;
- Bot Connector REST calls: post/update/delete activity, conversation
  creation, team channel lists, and paged member streams;
- Bot Framework OpenID metadata and JWKS retrieval with a 24-hour cache and
  a rate-limited refetch on unknown key ids;
- pre-authorized and bearer-authenticated binary downloads.

The library performs no signature verification: validating connector JWTs is
a trust decision that the plugin makes through the Rust kernel's
`jwt_verify_jwk` (RS256 against the fetched JWK), checking issuer
`https://api.botframework.com`, audience, five minutes of leeway, and that the
token's service-URL claim matches the activity.

## Ingress

The webhook handler routes activity types:

- `message` becomes `entry_receive`, unless it carries an Adaptive Card
  submit envelope, in which case it becomes an action fact;
- `messageDelete` and `messageUpdate` with a soft-delete event type become
  `entry_removed`; edits and undeletes are ignored (the ingress contract has
  no entry editing);
- `messageReaction` becomes reaction facts, normalized from Teams reaction
  types;
- `conversationUpdate` and `installationUpdate` drive channel projection.

The stable provider identifiers derive from the Teams conversation algebra.
Channel activities carry `conversation.id` in the form
`19:…@thread.tacv2;messageid={threadRootId}`:

- `signal_channel_id = "teams:" <> URI-encoded base conversation id` (the part
  before `;messageid=`);
- `provider_thread_id = "teams:{base}:{threadRootId}"` when the conversation id
  carries a `;messageid=` thread segment (channel posts and their replies), nil
  for personal and group chats — never the activity's own id, which would
  fragment the inbound-batch key per message;
- `reply_to_source_entry_id = activity.replyToId` when present; because Teams
  can omit that field on inbound channel replies, the adapter falls back to the
  parsed thread root only when it differs from the current `activity.id`;
- `source_entry_id = activity.id`.

Personal chats are explicit. The adapter marks group and channel messages
explicit when a mention entity targets the bot (`mentioned.id == recipient.id`
— resolved per activity, no runtime identity call needed); SignalsGateway also
marks them explicit when their normalized reply target resolves to the current
agent's output. The bot's own `<at>` mention markup is stripped from visible
text; other mentions become structured mention data. Bot senders (`28:` ids)
are ignored.

By default Teams delivers only @bot messages in group chats and channels. The
`observe_all` and `may_intervene` modes additionally require the Teams app
manifest to grant RSC read permissions (`ChannelMessage.Read.Group`,
`ChatMessage.Read.Chat`); without them the transport simply never sees
unaddressed messages.

Inbound attachments cover file-consent attachments (pre-authorized download
URLs) and connector-hosted images (downloaded with the bot token), both
materialized through WorkerFiles.

## Channel Projection

Teams offers no "list every conversation this bot can see" API, so the
projection universe is the set of already-mirrored conversations: a team
becomes enumerable once any of its channels produced an activity
(installation `conversationUpdate` or a message), after which the connector's
channel-list and paged-member calls project its channels into gateway
channels and AuthZ groups. Standard-channel membership in Teams is team
membership, which `pagedmembers` reports per conversation.

The service URL is learned exclusively from inbound traffic and persisted in
channel mirror metadata; outbound work against a conversation whose mirror
never saw the provider fails with `missing_service_url` rather than guessing
a regional connector host.

## Outbox

All provider-visible effects originate from durable
`signal_gateway_outbox_entries`:

- post: `POST /v3/conversations/{base}/activities` — a new thread in a
  channel, a plain message in chats;
- reply: posting into `{base};messageid={root}` for channels, a plain post
  for chats;
- edit and delete: `PUT`/`DELETE` on the activity inside its thread
  conversation, with idempotent absent-target errors treated as applied;
- card: Adaptive Card 1.4 attachments rendered from the portable interactive
  output payload; submit actions carry a versioned data envelope that ingress
  decodes back into action facts;
- divider: a rule-plus-caption text message.

Markdown passes through nearly unchanged (Teams renders a CommonMark subset);
tables and horizontal rules are rewritten into readable text. Long content is
split within provider limits. Outbound file attachments are not supported and
fail loudly.

## Identity and Directory

Sign-in with Entra ID is an AuthN input to Principals. The host login flow
owns state verification and callback sessions; the adapter builds the
authorization URL, exchanges the code, and reads authoritative claims from
Graph `/me`. The subject's `external_id` is the Graph directory object id —
never the pairwise OIDC `sub` — which keeps login, directory sync, and Teams
chat authors on one identity.

Full synchronization walks Graph groups first (projected through the existing
external directory-group contract with `kind = "entra_group"` metadata; the
persistence enum stays `directory_department`), collects direct user members
per group, then walks users and applies memberships. Disabled accounts are
skipped and guests are skipped unless `sync.includeGuests` is set. Nested
groups are not expanded — each group projects its direct user members.

Realtime synchronization uses Graph change notifications: two subscriptions
per provider (`/users` and `/groups`, changeType `updated,deleted` — creation
and soft-deletion also arrive as `updated`). Directory subscriptions live at
most 41,760 minutes, are created with a 7-day expiration, and renew inside a
48-hour window from a periodic reconciler that also runs at boot and on
provider save. Subscription rows — including the per-subscription
`clientState` secret that authenticates notifications — are machine-managed
values in the declared encrypted subscription-state pattern. Notifications
carry only ids; handlers re-fetch the authoritative object before writing.
User deletions converge through group updates and periodic full sync.

## Operator Checklist

- Azure: create the Bot resource (single-tenant recommended), set the
  messaging endpoint to the `teams/messages` webhook URL, and note the App ID
  and client secret.
- Teams app manifest: bot id = App ID; add RSC permissions
  `ChannelMessage.Read.Group` and `ChatMessage.Read.Chat` when unaddressed
  group modes are wanted.
- Entra app registration for login/directory: delegated `User.Read` plus
  admin-consented application permissions `User.Read.All` and
  `Group.Read.All`; redirect URI = the host OIDC callback.
- The installation must be reachable over public HTTPS for both webhook
  endpoints.

## Ownership and Recovery

- Webhook delivery is transport, not durable truth.
- SignalsGateway owns provider mirrors, ingress admission, actor events,
  idempotency, and outbox state.
- Principals and AuthZ own subjects, external groups, memberships, and grants.
- AppConfigure owns encrypted operator configuration and the machine-managed
  subscription state.
- The plugin owns provider normalization, webhook authentication, and the
  subscription reconciler.
- Agent Computer receives accepted actor work and never receives Microsoft
  credentials.

After a control-plane restart, plugin discovery restores the supervised
children, the startup sync re-enqueues channel projection, the subscription
reconciler re-ensures Graph subscriptions, and PostgreSQL-backed gateway and
identity state continues from committed rows. Missed change notifications
while offline converge through periodic full sync.

## Deliberate Limits

The current contract does not include:

- outbound message reactions or outbound file attachments;
- outbound send reconciliation (no connector read-back API);
- inbound message-edit mirroring or undelete replay;
- proactively created personal conversations (output goes to mirrored
  conversations and channel posts only);
- message extensions, dialogs/task modules, invoke-based card flows, or Teams
  client SSO;
- the Bot Framework Emulator authentication path;
- sovereign clouds (Teams operated by 21Vianet does not support bots at all;
  US Gov is out of scope);
- Entra nested-group expansion or Graph delta-query incremental sync.

These omissions are contract boundaries. Adding one requires extending the
owning host contract when necessary, not bypassing it inside the provider
adapter.

## Verification

The repository verifies the adapter at three levels:

- `libs/microsoft_openapi/test/` for Entra OAuth, Graph pagination and error
  classification, Bot Connector calls, and JWKS caching;
- kernel tests for RS256 JWK verification;
- control-plane plugin tests for declarations, configuration, conversation
  algebra, inbound normalization, mention routing, connector JWT
  verification, outbox request mapping, webhook dispatch, directory sync,
  Graph subscription lifecycle, and notification handling.

There is no fake-provider E2E suite: no maintained open-source stand-in for
the Bot Framework connector plus Graph exists (the official Emulator is an
archived desktop app). A real Entra tenant + Azure Bot + Teams client smoke
test remains credentialed operator verification and has not been run for this
implementation.
