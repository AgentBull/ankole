# Slack Adapter

The Slack plugin connects one Slack app to Ankole through two independent
host-owned contracts:

- chat ingress and provider-visible output through SignalsGateway;
- optional login and directory synchronization through Principals.

The two contracts may use credentials from the same Slack app, but they have
separate configuration and save boundaries. The plugin is trusted first-party
Elixir code running in the control plane. Agent Computer never talks to Slack
directly.

For the shared boundaries, see `docs/design-docs/Plugins.md`,
`docs/design-docs/SignalsGateway.md`, and `docs/design-docs/Principal.md`.

## Stable Names

The public names are:

- plugin id: `slack-adapter`;
- SignalsGateway adapter id: `slack`;
- identity-provider adapter id: `slack`;
- chat configuration pattern: `signals_gateway.slack.bindings.<id>`;
- identity configuration pattern: `principals.identity_providers.slack.<id>`;
- default platform-subject namespace: `slack-main`.

One `platformSubjectNamespace` represents one Slack workspace. Installations
that connect several workspaces must give each workspace a distinct namespace.
The namespace participates in Principal resolution and must not be changed as
an incidental display-name edit.

## Plugin Declaration

`Ankole.Plugins.SlackAdapter` declares both contracts. The
`signals_gateway.adapter` declaration exposes:

- chat configuration metadata;
- `Inbound` as the adapter-facing ingress module;
- `Outbox` as the durable side-effect adapter;
- `ConnectionSupervisor` for Socket Mode runtime ownership;
- `Channels` for binding-save synchronization;
- group-message modes `addressed_only`, `observe_all`, and `may_intervene`.

Its inbound capabilities are:

- `entry_receive`;
- `entry_removed`;
- `reaction_add` and `reaction_remove`;
- `action_event`.

Its outbound capabilities are:

- `post_entry` and `reply_entry`;
- `edit_entry` and `delete_entry`;
- `add_reaction` and `remove_reaction`;
- `divider` and `card`;
- `outbound_reconciliation`.

The `principals.identity_provider` declaration exposes OIDC authorization and
code exchange, full directory synchronization, and realtime directory
synchronization. These declarations reference host-owned contracts. The plugin
does not own gateway rows, actor events, Principal rows, AuthZ grants, or the
identity-provider registry.

## Configuration

Chat configuration is encrypted and contains:

- `botToken`: required Bot User OAuth Token with the `xoxb-` prefix;
- `appToken`: required App-Level Token with the `xapp-` prefix and Socket Mode
  connection permission;
- `platformSubjectNamespace`: defaults to `slack-main`;
- `userName`: outbound display name, default `Slack`;
- `baseURL`: optional Web API base URL override for compatible local providers.

Identity-provider configuration is also encrypted and contains:

- `clientID` and encrypted `clientSecret` for Sign in with Slack;
- optional `teamID` to restrict login to one workspace;
- optional `botToken` for directory synchronization;
- optional `appToken` for realtime directory events;
- `oidc.enabled` and `oidc.scopes`;
- `sync.contacts`, `sync.websocket`, and `sync.pageSize`.

Contact synchronization requires a bot token. Realtime contact synchronization
also requires an app token and is disabled when contact synchronization itself
is disabled. Tokens are resolved only at provider-call boundaries and must not
be logged or included in process names.

## Provider Library

Provider protocol code lives in `libs/slack_openapi`. The library owns:

- authenticated Slack Web API requests and Slack-shaped error classification;
- cursor pagination;
- external file upload and private file download;
- OIDC authorization, token exchange, and user-info requests;
- Socket Mode URL discovery, WebSocket framing, reconnects, ping/pong handling,
  envelope dispatch, and acknowledgement.

The adapter owns Ankole-specific normalization, routing, persistence calls,
directory projection, Block Kit rendering, and outbox behavior. Provider
library structs and live connection state must not cross into PostgreSQL.

## Socket Mode Runtime

Only Socket Mode is supported for event ingress. The plugin does not expose an
HTTP Events API endpoint, slash-command endpoint, or request-signature surface.

The runtime derives a connection key from the first 16 hexadecimal characters
of the SHA-256 fingerprint of the app token:

```text
{"slack", app_token_fingerprint_prefix}
```

Chat bindings and realtime identity providers using the same app token share
one supervised connection. `ConnectionReconciler` rebuilds the desired set
from active configuration, `ConnectionSupervisor` owns one `ConnectionOwner`
per key, and the owner combines all chat and identity consumers into one
dispatcher. This registry is process state and is reconstructable after a
restart.

The Socket Mode client dispatches an envelope before acknowledging it. A crash
before acknowledgement can therefore cause Slack to redeliver the event. That
is intentional: SignalsGateway and directory writes provide durable
idempotency, while acknowledging first could lose an event permanently.
Dispatch runs outside the WebSocket receive loop so provider work does not
block frame processing.

The client handles provider disconnect requests, protocol ping/pong, fragmented
frames, connection renewal, and retry backoff. A disabled Socket Mode link or
invalid credentials are configuration failures; transient transport failures
remain supervised retries.

## Ingress

The dispatcher handles these event families:

- messages, message deletion, reactions, and Block Kit actions;
- channel membership, rename, deletion, and archive events;
- user and usergroup lifecycle events for directory synchronization.

Messages are normalized into `SignalsGateway.Ingress.emit_entry/3` inputs. The
stable provider identifiers are:

- `signal_channel_id = "slack:" <> channel_id`;
- `source_entry_id = message.ts`;
- `provider_thread_id = "slack:" <> channel_id <> ":" <> thread_ts` for
  threaded replies (and thread broadcasts), nil for top-level messages — never
  the message's own `ts`, which would fragment the inbound-batch key per
  message;
- `reply_to_source_entry_id = thread_ts` only when `thread_ts != ts`; a root
  event whose `thread_ts == ts` is not treated as a reply to itself;
- `source_event_id = Events API event_id`, falling back to the message timestamp
  only when the provider event lacks an id.

Direct messages are explicit. The adapter marks a group message explicit when
its structured Slack mention targets the current bot; SignalsGateway also marks
it explicit when the reply target resolves to the current agent's mirrored
output. The adapter removes the current-agent mention from visible text but
preserves other mentions as structured mention data. SignalsGateway binding
policy, not the adapter, decides whether any remaining unaddressed group message
is ignored, observed, or delivered as a possible intervention.

Bot and app senders are ignored, including the current bot user resolved with
`auth.test`. `message_changed` is ignored because the current ingress contract
does not expose entry editing. `message_deleted` becomes `entry_removed`.
Reactions target the mirrored message timestamp and Block Kit `block_actions`
become action facts.

Inbound attachments are represented as provider resources and may be
materialized through WorkerFiles. When Slack delivers a recent attachment and
an addressed text message as adjacent events, the adapter may backfill a small,
bounded set of recent attachments into the addressed message. This is an
adapter heuristic; it does not alter gateway batching semantics.

## Channel Projection

Channel synchronization uses Slack conversation and membership APIs to project
the provider-visible chat into SignalsGateway and AuthZ-owned records. Startup
sync and Oban refresh jobs reconcile channels without making the live transport
durable truth. Membership, rename, archive, and deletion events update the same
projection incrementally.

The bot can only mirror conversations visible to its token. Missing or
inaccessible conversations are provider visibility constraints, not reasons to
invent placeholder channels.

## Outbox

All provider-visible effects originate from durable
`signal_gateway_outbox_entries`. `Outbox` maps operations to Slack Web API
calls:

- post and reply: `chat.postMessage`;
- edit: `chat.update`;
- delete: `chat.delete`;
- reactions: `reactions.add` and `reactions.remove`;
- files: external upload URL, byte upload, and upload completion;
- cards: Block Kit blocks rendered by the plugin.

Ordinary Markdown is converted conservatively into Slack `mrkdwn`. Unsupported
Markdown constructs are emitted as readable text rather than approximated with
provider-specific behavior. Long content is split within provider limits while
preserving the first message as the reply target.

Slack does not provide a general idempotency key for `chat.postMessage`.
Outbox state remains the send authority, and `reconcile/1` uses the created
provider timestamp to inspect message history after an ambiguous outcome. A
positive lookup adopts the existing message; a negative or unavailable lookup
does not pretend the send was absent.

Rate-limit responses are classified as retryable and retain the provider retry
delay. There is no second in-memory per-channel send queue: the durable outbox
and its retry scheduler own ordering and recovery.

## Identity and Directory

Sign in with Slack is an AuthN input to Principals. The existing host login flow
owns state verification and callback session handling. The adapter exchanges
the authorization code, calls Slack user-info, and returns normalized claims.
It does not grant authorization by itself.

Directory synchronization imports Slack users as platform subjects in the
configured namespace. Slack usergroups are projected through the existing
external directory-group contract. The current persistence enum is named
`directory_department`; Slack metadata records `kind = "usergroup"` so the
provider meaning remains explicit without adding a parallel storage path.
Usergroups are flat and therefore have no parent relationship.

Full synchronization uses cursor-paginated users plus usergroups. Realtime
`team_join`, `user_change`, and subteam events update the same Principal and
AuthZ-owned records. If a realtime usergroup event indicates a truncated member
list, the adapter fetches the authoritative membership rather than treating the
partial list as complete.

## Ownership and Recovery

- Slack delivery is transport, not durable truth.
- SignalsGateway owns provider mirrors, ingress admission, actor events,
  idempotency, and outbox state.
- Principals and AuthZ own subjects, external groups, memberships, and grants.
- AppConfigure owns encrypted operator-managed configuration.
- The plugin owns provider normalization and supervised connection state.
- Agent Computer receives accepted actor work and never receives Slack tokens.

After a control-plane restart, plugin discovery restores the supervised
children, connection reconciliation recreates Socket Mode owners, startup jobs
refresh channel projection, and PostgreSQL-backed gateway and identity state
continues from committed rows.

## Deliberate Limits

The current contract does not include:

- HTTP Events API callbacks, slash commands, shortcuts, modals, or App Home;
- Enterprise Grid multi-organization routing or GovSlack endpoints;
- inbound message-edit mirroring;
- token rotation machinery;
- a process-local per-channel rate-limit queue;
- direct Slack access from Agent Computer.

These omissions are contract boundaries. Adding one requires extending the
owning host contract when necessary, not bypassing it inside the provider
adapter.

## Verification

The repository verifies the adapter at three levels:

- `libs/slack_openapi/test/` for Web API, pagination, OIDC, and Socket Mode;
- control-plane plugin tests for declaration, normalization, outbox, directory,
  and routing behavior;
- dedicated fake-provider E2E suites for transport, main chat flow, and
  lifecycle/directory behavior.

Runtime and provider E2E are deliberately outside the default fast test path.
A real Slack workspace smoke test remains credentialed operator verification;
the fake provider proves Ankole's boundary, not every behavior of Slack's
production platform.
