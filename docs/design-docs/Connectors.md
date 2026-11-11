# Connectors

`Ankole.Connectors` owns tenant application credentials, personal OAuth
connections, external subscriptions, and the internal MCP gateway. Platform
plugins implement their upstream protocols. Both Agent Workers and Function
Runtime consume the same explicit Toolkit contracts through MCPorter.
The plugin registry validates each `connectors.connector` declaration against
its required `tools/0` and `call/3` callbacks at startup.

## Tenant connections and credential ownership

A tenant administrator manages first-party applications through the Pod
Connectors page and its typed `/api/v2/pod/connectors` API. Each application has
a tenant-unique slug, a platform, an authentication scheme, public metadata,
and a row-encrypted root secret. Local application configurations use `mode = local`;
Ankole Cloud configurations use `mode = cloud` and reference the official application
without copying its secret into the Pod. One active local connection per platform can
be the default. The database prevents the same external application identity from
being active in two tenants. A caller names its connection explicitly when it
needs a particular account; the gateway never substitutes another account
following an authentication failure.
Selecting another default replaces the previous default for that platform in
the same transaction; a failed save preserves the previous selection. Default
selection is serialized per tenant and platform, including when no connection
exists. Identity-provider and IM configuration saves make the first imported
connection the default and preserve it when adding other applications. Those
saves resolve or create their shared application root under the same lock, so
concurrent identity and IM setup reuse one connection.

The `connectors.cloud_provider` plugin contract supplies the available managed
connections and JSON-serializable authorization, execution, and subscription
operations. The FOSS core depends only on this contract. A SaaS deployment
registers its in-process provider; a remote provider can use the same contract
with a Cloud account and an explicit consuming Pod scope.

Store presents available Cloud configurations without writing a row for every
Pod. The first authorization, credential binding, or subscription materializes
one Cloud root per platform under the existing configuration lock. Explicit
selectors retain their connection. Without a selector, an active local
configuration takes priority over Cloud; multiple local configurations use the
administrator's default. Adding a local application can therefore require a
member to authorize that application on their next default call. Existing
subscriptions retain their `auth_config_id` until deliberately migrated.

`connector_auth_configs` owns application roots. `connector_connected_accounts`
owns installation slots and OAuth tokens. A human account records both its
owner's Principal UID and access version; an application account represents an
installation or workspace. Saving a GitHub App installation ID creates its
application account without storing a derived installation token. The configured
installation is the default; callers may select another saved account explicitly.
`connector_oauth_sessions` holds short-lived OAuth
state, and `connector_triggers` tracks external subscriptions that require
explicit creation and deletion upstream. These are tenant Ash resources with
UUIDv7 identifiers. Secret ciphertext uses `SecretKeyBase` with the purpose,
tenant ID, and owning row ID as its encryption context.

Identity-provider and IM behavior remains in its owning AppConfigure key.
Those configurations reference `authConfigId`, and IM Signal Bindings also
carry an `auth_config_id` foreign key. The control plane resolves the reference
when reading the configuration; the database envelope contains the reference
and behavior settings. Existing configuration forms can supply credentials,
which their save operation merges into the connection credential store. The startup importer
processes existing identity and IM configurations before plugin connections
start. It merges complementary credentials for the same external application
and reports conflicting field names without exposing their values. Current
configuration saves rely on the vault's database constraint for tenant ownership.
The AppConfigure identity scan serves the historical import before vault rows
exist. Principal renames update connection ownership, personal account keys,
and pending OAuth actors while preserving external workspace identifiers.

Pod identity-provider forms and Console identity-provider and IM forms share
the connection selector. It displays the current connection even when disabled,
so an administrator can replace it without re-entering credentials. Choosing a
different connection clears the previous credential fields from the draft and
preserves the owning subsystem's behavior settings. When editing a shared
`platform_app` or `identity_app` connection, the credentials form includes the
platform's messaging and identity fields once each. An administrator can add
missing credentials, and blank inputs preserve saved values. Creating a
connection still uses the fields required by the selected authentication scheme.
The Console forms select existing connections through
the read-only `/api/v2/connector-catalog` and `/api/v2/connector-auth-configs`
operations. Console authorization uses the site operator's grants, while
`x-ankole-tenant` selects the data tenant. Both operations delegate to Connectors
and return its public projection; they do not return stored credentials or
require the site operator to have a Principal in the selected tenant.
The identity and messaging configuration pages remain editable when their
connection is disabled, so an operator can adjust behavior or select a
replacement connection. Their runtime configuration reads reject the disabled
connection, and scheduled directory scans skip it while continuing with other
providers.

The catalog names each platform with a localized text map. When one connector
serves several platforms, such as Feishu and Lark, its module exports
`platform_name/1`. Connectors then adds a localized `platform_name`, chosen by
the connection's public metadata, to that connection's public projection, so a
connection card names the platform the connection actually calls.

For Microsoft 365, Entra ID's `clientID`/`clientSecret` and Teams'
`appID`/`appPassword` names resolve the same application credential. Either
configuration can reuse a connection created from the other form. Rotation
updates both names when they contain the same secret. If an
imported connection contains separate secrets under both names, each consumer
keeps its own stored secret.

A Slack connection can hold both bot tokens and its distinct OIDC client
credentials. An administrator can add either credential set to the same root.
When a client-only connection gains bot tokens, Ankole resolves the bot's real
application ID through Slack before completing the connection's application
identity. The original client ID must remain unchanged. The database reserves
both the verified application ID and `platform_client_id` across active tenant
connections, so adding bot credentials does not release the original client
identity. Identity-provider and IM configuration saves use the same identity rules.

The external application identity is stable for the lifetime of a connection;
administrators create a separate connection for a different application.
Changes to credentials, authentication metadata, or application status increment
the application's secret version and invalidate OAuth refresh leases. Connection
names, slugs, and default selection preserve in-flight refreshes, as do saves
that submit the same credentials and metadata. Identity-provider and IM
configuration saves use the same version and lease rules. The plugin connection reconcilers receive a
change notification and rebuild affected connections from the current credential.
Disabling an application immediately rejects new gateway credential resolution and changes
the desired state of its external subscriptions. Plugin reconcilers close its
running IM and directory connections and discard their restart configuration.
A failed configuration read can preserve a live connection, but cannot preserve
a root that the administrator explicitly disabled, even when another
configuration in the same tenant is unreadable.

## Personal authorization and token lifetime

Connectors owns personal-token storage and refresh. FeishuOpenAPI receives the
resolved `user_access_token` explicitly from its caller.

Members initiate OAuth for themselves; administrators can connect an
application workspace. The Pod connection form displays the control plane's
OAuth callback URL and platform-specific setup instructions for registration in
the external application. When a member
returns from a cancelled authorization, the page preserves the requested
connection and scopes so they can retry the same consent. A successful claim
directs them back to their conversation or Applet to retry the task, and the
page removes the requested connection and scopes from its address so that a
reload shows the connected account instead of starting the authorization again.
A member can
start a personal event subscription before connecting an account. The selected
trigger declares its required OAuth scopes; missing grants lead to the same
authorization flow. The return URL carries the subscription's event type and
resource, so cancellation and successful authorization restore the draft.
When the flow starts in an Applet's Automation panel, the return URL also keeps
the Page and Job. Creating a subscription offers a return link that selects the
new event source in that Job. The member explicitly connects it; an unavailable
Job or source displays an error without selecting a replacement. Application
and personal authorization keep their respective subject kinds across consent.
Existing subscriptions let their account owner authorize and retry; administrators
see which owner must supply the grant.
The Pod accepts only local absolute paths as OAuth return destinations; missing or invalid destinations use the connection page.
The authorization request uses PKCE and a one-use state
digest. The public callback exchanges the authorization code and stores sealed
pending tokens after checking the provider's external subject. The browser then
claims the completion code through its authenticated Pod session. Claiming
checks the original actor, tenant, live Human work access, and expiry before
storing the connection. A reconnect leaves the current connection available
until the new grant is claimed successfully. Progressive authorization requests
include the selected personal or team account's existing granted scopes together
with the newly required scopes, so connecting another Toolkit preserves the
earlier grant. Reauthorization also preserves these scopes when the account has
expired.

The connection page separates the current member's personal accounts from team
integrations. `scope=mine` projects only the signed-in member's human accounts,
including for an administrator; `scope=team` projects shared application accounts.
Members and their personal assistants resolve personal credentials through the
Human Principal's authority. Administrators can disconnect a failing account
from subscription management, but cannot execute with another member's credentials
or attach a new consumer to that member's personal subscription.
Adding consumers to a team event source requires Pod administrator permission,
including application-level sources that do not use a ConnectedAccount.

Figma supports both personal and team access tokens. Stripe, Sentry, and Zendesk
use administrator-managed team credentials. Each platform adapter validates the
credentials against its account endpoint before Connectors saves them and returns
the external account identity to the browser. Personal binding accepts only the
platform's user-facing credential fields. Consent errors carry an absolute Pod
URL, the connection, subject kind, required scopes, and task intent. Personal
token links open the member's credential form; team-token links open the
administrator's shared credential form. A permanently expired shared account
continues to return a team reconnect link on subsequent calls.
The gateway derives a task return path from the verified native conversation
RunRef or the signed Applet Page and Job context. After binding, the member can
select **Return to task**. External IM calls retain the instruction to resume
their original conversation rather than linking to a different Pod conversation.

Official Cloud OAuth applications belong to Ankole. Cloud holds their encrypted
refresh tokens; the Pod stores an `upstream_connection_id` beside its local
account ownership, access version, scopes, status, and public metadata. The local
refresh worker skips Cloud accounts. Local OAuth and user-supplied tokens remain
encrypted in the Pod and reach Cloud only as inline execution credentials.
The provider owns each consuming Pod's trusted origin and redirects OAuth results
there after validating its own state and PKCE. The Pod exchanges the one-use
Cloud ticket, then uses its existing authenticated completion-code claim.

A successful reconnect preserves the local account ID and all subscription
references. The account transaction records the replacement Cloud reference and
queues an idempotent handover through Oban. Cloud transfers existing subscriptions
before removing the prior grant. Once the handover completes, Connectors queues
failed subscriptions for reconciliation with the replacement credential. Local
account reconnection performs the same recovery in its account transaction.
Subscription IDs, consumer bindings, and deletion intent survive this recovery.
An abandoned callback leaves the live account
untouched. Disconnect and Human offboarding revoke local authority in the owning
transaction and queue Cloud cleanup for execution after commit. Principal rename
changes the local owner and account key without revoking the Cloud grant.

For adaptive tools, an explicit application account selects that workspace even
when the caller has a personal grant. Without an account selector, a saved
personal grant takes precedence when its scopes satisfy the operation. An adapter
can authorize the application form of the same employee operation by resolving a
verified employee ID; Lark approval-task queries use this path when personal
consent is unavailable or insufficient. Otherwise Ankole requests fresh consent.
Lark calendar and task operations select personal or application resources through
`resource_scope`; personal resource requests require personal consent.
A permanent token-refresh failure also returns this consent link on the failed
call, so the member can reconnect immediately. Consent links use the tenant's
canonical Pod origin and can be opened from external IM messages. When a native
room turn hits `consent_required`, `Ankole.Connectors.Gateway` mints the consent
session with a `/connectors` popup return marker and attaches a structured
`connector_auth` prompt to the tool envelope. At turn completion, `Posting`
commits a live `ConnectorAuthCardView` message alongside a `connector_auth_waits`
row so `Accounts.put_tokens_in_tx/5` resolves the pending external wait and
wakes the blocked Agent automatically once the Human finishes authorization in
the popup window (and if the Human completes consent before `Posting` commits
the blocked turn's final reply, `AuthWaits.activate_or_complete_in_tx/4`
resolves the newly opened checkpoint immediately in the same transaction).

Lark personal grants include `offline_access` and
`contact:user.employee_id:readonly` for refresh and employee identification.
Personal calendar subscriptions request `calendar:calendar.event:read` when
needed; an existing `calendar:calendar:readonly` or `calendar:calendar` grant
also satisfies this requirement.
Creating or retrying a subscription checks the account's current grants and
returns its owner's consent link before attempting an upstream subscription.
Team OAuth subscriptions request any missing permissions through the team's
authorization flow while preserving the account's existing granted scopes.
An identity provider can merge these grants into sign-in; that opt-in path uses
the same v2 authorization-code and refresh protocol as personal connections.
Linear application authorization uses `actor=app`, while member authorization
uses the member's upstream identity. Its account metadata includes the upstream
member's name for display. GitHub App connections include OAuth client credentials
for human authorization. GitHub App user authorization omits OAuth scopes; OAuth
Apps request the declared GitHub scopes. Enterprise GitHub connections derive the
website origin and `/api/uploads` endpoint from their REST API origin unless the
administrator supplies explicit URLs.

Application tokens that can be reproduced from a root credential use a node
cache keyed by tenant, application, secret version, and installation account.
Concurrent misses for one cache key share a fetch; a slow application does not
block token requests for other applications. The cache does not persist these
tokens. OAuth credentials use a 30-second
PostgreSQL refresh lease. The refresh owner performs the upstream request
outside the transaction, then checks the lease, credential version, application
secret version and status, and current Human access before accepting the result.
It reads the Human owner from the locked account, so a Principal rename during
the upstream request preserves the rotating grant. Human offboarding revokes the
same account within its Principal transaction and prevents a late refresh from
restoring that grant.
Transient failures retain the connection and impose a 30-second cooldown;
explicit grant invalidation expires it. An hourly job renews refresh grants
within seven days of expiry. A grant that has expired or failed continuously
for four days requires fresh authorization. The same hourly maintenance removes
expired OAuth sessions, including abandoned callbacks and completed claims.

Disabling a Human increments their access version and revokes their personal
connections in the same transaction. Gateway requests check live membership and
connection status. Existing work owners stop personal Jobs and sources through
their WorkAccess lifecycle. Subscription teardown can use the last stored token
to unsubscribe without reviving a revoked account. When the platform confirms
that the subscription or its authorization is unavailable, Ankole removes the
local subscription reference. Transient upstream failures remain visible and
retryable.

Tenant deletion removes external subscriptions before deleting connection
credentials. If an upstream service refuses the unsubscribe, the tenant deletion
job preserves those credentials and retries through its job lifecycle.

## Tool contracts and execution authority

Skill MCP credential metadata uses the Library source cache, keyed by tenant and
immutable metadata object IDs; each lookup reads the current Skill file references.

A plugin contributes the `connectors.connector` contract and explicit
`ToolSpec` declarations. A ToolSpec owns its name, argument and result schemas,
read/write annotations, required subject, upstream authentication mode, scopes,
and platform operation. These declarations also generate Skill metadata, a
compact operation index, individual tool references, and Applet toolkit types.
Static declarations compile their input and output validators once while keeping
the original JSON Schemas for discovery and generated contracts. Dynamic Skill
schemas use the same validation owner at invocation time.
The Agent finds the operation in the index and reads its individual contract;
external operations are not added to the model's native tool registry.

Cloud-backed platform plugins own the public tool names, input and output
schemas, scope requirements, and event types. Their checked-in catalog pins the
upstream toolkit version, and `mix ankole.toolkits --write` generates the same
Skill references and Applet types as native plugins. Cloud uses inline credentials
and that exact version for execution. Replacing an upstream operation with a
native platform call preserves this public contract and the account reference.
Maintainers provide a project key through `COMPOSIO_API_KEY` and run
`bun run connectors:sync-catalog` to check the pinned upstream metadata against
the reviewed selection in `plugins/cloud_connectors_adapter/selection.json`.
The matching `catalog/<platform>.json` file owns the pinned version. After
editing either, run `bun run connectors:sync-catalog --write`, then run
`MIX_ENV=test mix ankole.toolkits --write` from `app/control_plane`. The importer
preserves complete JSON Schema definitions and references; generated TypeScript
aliases represent recursive types. The platform result projection omits optional
null-valued fields only when their schema rejects null, while preserving
required fields and explicitly nullable values.

The internal Toolkit endpoint is
`/api/internal/mcp/toolkits/:toolkit?connection=:slug&account=:account_key`.
The Skill proxy endpoint is `/api/internal/mcp/skills/:skill/:server`. It resolves
the installed Skill's declared remote MCP service and injects its credential
inside the control plane. Worker calls use active Turn authority. Function
Runtime calls use invocation-scoped credentials for the caller and page owner;
the trusted host keeps these credentials outside the Applet isolate. Tool calls
from a read-only route must select tools declared read-only. Signed contexts
can discover the MCP protocol before business authorization, so a missing caller
identity reaches the Applet as an actionable tool error. Function Runtime
preserves the control plane's remaining invocation budget through its internal
WebSocket bridge, including `ctx.remainingMs()` and host MCP calls.

File tools stream uploads from Pod file references and save downloads to an
explicit Pod destination. Saving a download changes the destination Page, so
these tools require a route that permits writes even when the upstream request
uses HTTP GET. To replace an existing file Page, the caller supplies its observed
`object_id` as `destination.base_object_id`; Pod rejects a stale version with
`manifest_changed` and preserves the current file. A Worker uploads a generated
local file through `ankole-pod files.upload` before passing its returned Pod
reference to an external upload tool.

For a Background Agent Job, the Skill proxy uses the Job's admitted Skill
selection together with current enablement and background runtime eligibility.
Worker environment snapshots exclude Skill-declared upstream MCP credentials at
capture and before transmission to the Worker.

Human authority and upstream token type are separate decisions. A personal
assistant can act for its current Human owner. An application identity does not
invent a Human actor. For example, Lark approvals can use an application token
with a verified employee `user_id`, while personal calendar operations require
the employee's OAuth grant. Missing consent returns a link to the authenticated
Connectors flow. Multiple installation slots require an explicit account choice.
Applet code receives the complete gateway error in `HttpError.details`, including
authorization links, retry delays, and completed resource identifiers. The error's
code, message, retryability, and request-sent flag remain available on the error
itself. This lets an Applet ask for consent or recover a completed step without
repeating an external write.

Lark resolves an employee from identity providers that reference the selected
application. A separate bot application can explicitly select its shared
directory through `identityProvider`; matching a platform domain alone does not
establish a shared employee namespace. A Lark OAuth login can identify its account
with an app-specific `open_id` when employee-ID permission is unavailable. The
account records that identifier type, so employee-bound operations still require
a verified `user_id` and never treat an `open_id` as an employee identifier.

Lark approval definitions and instance reads use application tokens. The newer
`tasks/add_sign` and `tasks/rollback` endpoints use human OAuth tokens, as required
by Lark; they do not inject an application-bound `user_id`. Task-list callers name
the requested `topic`. Approval-list times accept ISO 8601 and reach Lark as Unix
milliseconds; calendar anchors use seconds. Event patches update event details,
and `calendar_manage_attendees` owns adding and removing attendees. Creating an
event can also add attendees and returns the created event ID if that later step
fails. Image uploads return `image_key`; other message files return `file_key`.
GitHub issue-label replacement requires an explicit `labels` list, including an
empty list to clear labels. Repository-content paths preserve directory segments.

An HTTP 401 invalidates only the token used by that request and resolves the same
account through the shared refresh lease or application-token cache. A late
rejection cannot invalidate a newer token. The gateway retries a read-only or
explicitly idempotent operation at most once. Other writes, uploads, and file
downloads that write to Drive require explicit retry after credential recovery.
Cloud applies the same rules when the execution service returns a platform HTTP
error inside a successful transport response. Rejection of the execution service's
own API key is a service availability error and does not invalidate the member's
platform credentials.
Git authentication returns the token that passed the repository access check.
An account without a refresh token, or a permanently rejected refresh grant,
requires authorization for that same account kind. A temporary refresh failure
remains retryable. Lark's token-invalid response codes also invalidate the token
used by the request, allowing the next call to refresh it.

## External events and subscription reconciliation

Application-wide streams use `connector://<auth_config_id>/<stream>` references.
Resource subscriptions use `connector-trigger://<trigger_id>`. Signal Bindings
own all routing and fan-out to Jobs or Agents. A trigger therefore holds no Job
or Binding foreign key; removing one consumer does not delete a subscription
needed by another consumer. If deletion overlaps an in-flight subscription
creation, the reconciler preserves the subscription identity and removes it
upstream before deleting the local trigger.

Administrators can inspect and cancel application-wide event bindings while the
connection is disabled. Runtime credential reads and inbound events reject the
disabled connection. Enabling the connection preserves each binding's configured
state.

The reconciler reads active bindings as desired state, acquires a short lease,
and calls the platform adapter outside a transaction. The adapter adopts an
existing subscription by its deterministic callback address or resource scope
before creating one. After an external change, the reconciler reads the current
desired state again. A binding added during unsubscribe therefore starts another
reconciliation. An ambiguous or failed result marks the trigger degraded; the
management API exposes an explicit retry operation. Retry locks the current
trigger, preserves its deletion intent, and queues reconciliation in the same
transaction. Provider status notifications cannot replace a pending deletion or
its recorded failure. An active reconciliation lease returns `connector_trigger_busy`,
so the current owner can record the upstream result before another attempt.
If a Cloud endpoint or token refresh is already leased, the reconciliation job
releases its local lease and retries automatically without degrading the
subscription.

For Trello, reconciliation recreates a webhook removed by grant revocation and
enables an existing webhook when the subscription is desired. For Stripe, Cloud
stores the webhook ID and signing secret in the same transaction. If creation
completed externally but Cloud has not saved that result, reconciliation replaces
only the orphan with the same Cloud callback URL to obtain its signing secret.

Failed subscriptions retain the provider's code, message, details, and retry
information after removing credentials. The Automation panel displays that
diagnosis and links to the exact connection and subscription for repair. A
successful reconciliation clears the recorded failure. GitHub subscription
requests recover a rejected token without replaying hook creation automatically.
The scheduler checks desired subscriptions every minute. While the Applet
Automation panel is open, it refreshes subscription status every five seconds
so members can see when an asynchronous subscription becomes ready or fails.
The Connectors page uses the account status returned with each subscription
refresh to offer reauthorization when a grant expires.
Ankole shows account owners their subscriptions and Pod administrators all
subscriptions. A personal assistant uses its Human owner's account
identity. Revoked accounts remain visible so their owners can repair or remove
subscriptions. The list checks membership and administrator status once and
selects the owned account IDs in one query.

Inbound routes include the tenant ID:
`/webhooks/connectors/:tenant_id/auth/:auth_config_id` and
`/webhooks/connectors/:tenant_id/triggers/:trigger_id`. The control plane selects
the tenant before loading verification material. Verified events enter
`Signals.Dispatch`; acknowledgement follows the durable receipt and destination
Run or Signal transaction. Application-level Lark events share the same upstream
connection as identity sync and IM consumers. Lark card callbacks use their
protocol's verifier: legacy flat callbacks use the card signature, while current
events use the event envelope. Both carry the operator, message context, and
action into the same durable business event. A card without a chat ID can still
trigger a business action; the native chat adapter runs only when chat context
exists. Current callbacks acknowledge acceptance with a short toast, and legacy
HTTP callbacks return an empty object. Approval execution and card updates run
as the destination Action after acceptance.

Cloud receives public callbacks on `console.<domain>`. After verifying the
platform's signature, it resolves the consuming Pod scope before calling
`Connectors.receive_cloud_delivery/1`. A `trigger_event` delivery names the local
trigger and a stable delivery ID; `Signals` owns durable fan-out and duplicate
suppression. A `trigger_status` delivery updates the subscription's operational
status and diagnosis. Cloud acknowledges event acceptance only after the Pod's
Signal transaction succeeds. Google Analytics has no inbound subscription;
scheduled automation can query its reports through the same Toolkit.

The Cloud connector catalog exposes these platform contracts:

| Platform | Member or team credential | Inbound events |
| --- | --- | --- |
| GitLab | OAuth | Merge requests, pushes, issues, and completed pipelines |
| Typeform | OAuth | Form submissions |
| Salesforce | OAuth | Lead and Contact creation; standard and custom object updates |
| Trello | OAuth | Card creation, changes, and moves |
| Calendly | OAuth | Personal or organization invitee creation and cancellation |
| Google Analytics | OAuth | Scheduled report queries |
| Google Calendar | OAuth | Event creation, updates, and cancellation |
| Stripe | Team token | Completed checkouts, paid invoices, and successful payments |
| Sentry | Team token | Issues and project error alerts |
| Zendesk | Team credentials | Ticket creation and updates |
| Figma | Personal or team token | File updates, comments, and library publication in a file, project, or team |

Google Calendar and Salesforce use account-scoped polling connections with
short-lived access tokens. Other event sources use native platform Webhooks.
Cloud shares an external endpoint among subscriptions for the same account and
resource, and removes it when the final consumer disconnects. Sentry's Internal
Integration requires the administrator to register the callback shown in the
subscription page; signed events are filtered to the selected project.
Calendly defaults to the connected member's events, and Figma defaults to a
file; the subscription form exposes the broader scopes explicitly. Stripe and
Zendesk subscriptions use the selected account without requesting a redundant
resource identifier.

Each event carries an Ankole-owned data envelope:
`{resource: {id, attributes}, changes}`. The resource ID identifies the platform
object, while the delivery ID controls duplicate suppression. Attributes contain
the platform's resource fields; consumers tolerate optional fields. Changes
contains the supplied field diff, or an empty object when the platform provides
none.

## Database connections

The `database-connectors` Plugin declares the `postgresql`, `mysql`, and
`clickhouse` connectors. Their adapters export `read_query/4`,
`fetch_catalog/3`, and `mark_catalog/2`, and Connectors treats such a
connection as a database connection. A database connection holds only application credentials: the
host, port, database, TLS mode, CA certificate, and sample exclusions live in
public metadata, while the username and password live in the sealed root
secret. It has no connected accounts or OAuth grants, and the credentials never
reach Workers or Applets. [Database Connectors](plugins/DatabaseConnectors.md)
specifies the engines, execution guards, and tools.

Connection-level authorization uses the AuthZ resource
`connector_connection:<auth_config_id>` and the action `query`. When an
administrator saves a database connection, the connection form chooses who may
query it. "All members and AI colleagues" grants `query` to the built-in
`all_humans` and `all_agents` groups; "selected groups and Agents" grants it to
each chosen group and Agent Principal. Connectors replaces the connection's
`query` grants in the save transaction. A new connection without a choice uses
the first option, and an update without a choice keeps the current grants. The
connection projection's `access` field reads the choice back from those grants.
Every tool call and every `run_read_query/5` call checks membership, the
connection's active status, and this grant before reading credentials. An
Agent, including a personal assistant, uses its own grants.

Connectors caches each database connection's catalog in
`connector_db_catalog_tables` and `connector_db_catalog_columns`. The cache is
rebuildable: the external database stays authoritative, and a refresh replaces
all of the connection's rows. Saving a database connection queues
`Ankole.Connectors.Jobs.RefreshDatabaseCatalog`, and an administrator refreshes
on demand through `POST /api/v2/pod/connectors/auth-configs/:id/refresh-catalog`
(the connection card's **Refresh catalog** action). The adapter reads the
external catalog outside any transaction; Connectors then replaces the cached
rows in one transaction under a per-connection advisory lock. Table rows record
the kind, comment, row estimate, primary key, query-history count, and fetch
time. Column rows record the type, nullability, comment, primary-key, unique,
and foreign-key properties, the sensitivity flag, and a sampled profile.
ClickHouse sorting and primary keys appear only as `sparse_order_key`, because
they order sparse index granules and never promise uniqueness. Before storing a
profile, Connectors removes `sample_values`, `min`, and `max` from every
sensitive column. When an administrator saves a database connection,
Connectors asks the adapter's `mark_catalog/2` which cached columns the saved
settings make sensitive and clears their profiles in the save transaction; the
queued refresh then rebuilds the other profiles. A `pg_search` BM25 index on
each table's `search_text` (schema, table, column names, and comments) serves
`search_catalog`; `Ankole.SearchIndexes` maintains it with the other BM25
indexes.

After replacing the rows, Connectors compares the previous snapshot with the
new one and reports each table or column that disappeared to
`Ankole.Brain.connector_columns_missing_in_tx/2`. A snapshot that stopped at
the `catalog_tables` budget is incomplete: Connectors still reports missing
columns of the tables it holds, but it never reports a table as missing,
because the table may lie beyond the budget. The refresh-catalog response
carries `table_count`, `fetched_at`, and `complete`, which is false when the
budget cut the catalog.

`Ankole.Connectors.run_read_query(actor, connection, sql, params \\ [], opts \\ [])`
is the core read interface for callers outside the gateway, such as Brain
metric bindings. `actor` is an `Ankole.AuthZ.Actor` or a Principal, and
`connection` is a connection ID or slug. The statement is one `SELECT` or `WITH`
query whose positional `params` use the engine's placeholders: `$1` for
PostgreSQL, `?` for MySQL, and `{p1:Type}` for ClickHouse. `opts` accepts
`max_rows`, which the operator budget caps, and `export`, a Pod destination that
requires an `Ankole.AuthZ.Actor`. The result is `{:ok, envelope}` or
`{:error, reason}`. The evidence envelope contains `columns` (each with `name`
and `type`), `rows`, `row_count`, `truncated`, `elapsed_ms`, the executed
`sql`, the `data_timestamp` at which execution started, `warnings` (such as
`fanout_risk`), and `file` when an export saved every row. The gateway's
`query` tool returns the same envelope.

Tenant teardown deletes catalog columns and tables before connection roots.

## Persistence and lock order

Principal authorization uses rank 3. Application roots, connected accounts, and
OAuth sessions use rank 6, with roots before their dependents. Jobs and Bindings
precede connector triggers at rank 7. Delivery receipts and Runs use rank 8.
When `Accounts.put_tokens_in_tx/5` wakes blocked room turns after storing fresh
tokens at rank 6, `Ankole.Connectors.AuthWaits` acquires `Sessions` (`9`),
`Conversations` and `Signals` (`11`), and `connector_auth_waits` (`12`) in
strictly ascending order before resolving each matching interaction checkpoint.
Network requests never hold these row locks. Tenant teardown removes Signal
Bindings, connector auth waits, and triggers before accounts and roots,
preserving foreign-key order.

Related contracts: [Plugins](Plugins.md), [MCP-backed Skills](MCPBackedSkills.md),
[Signals](Signals.md), [Automation Jobs](AutomationJobs.md),
[Human Offboarding](HumanOffboarding.md).
