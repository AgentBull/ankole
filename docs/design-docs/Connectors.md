# Connectors

`Ankole.Connectors` owns tenant application credentials, personal OAuth
connections, external subscriptions, and the internal MCP gateway. Platform
plugins implement their upstream protocols. Both Agent Workers and Function
Runtime consume the same explicit Toolkit contracts through MCPorter.

## Tenant connections and credential ownership

A tenant administrator manages first-party applications through the Pod
Connectors page and its typed `/api/v2/pod/connectors` API. Each application has
a tenant-unique slug, a platform, an authentication scheme, public metadata,
and a row-encrypted root secret. One active connection per platform can be the
default. The database prevents the same external application identity from
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

Members initiate OAuth for themselves; administrators can connect an
application workspace. The Pod connection form displays the control plane's
OAuth callback URL for registration in the external application. When a member
returns from a cancelled authorization, the page preserves the requested
connection and scopes so they can retry the same consent. A successful claim
directs them back to their conversation or Applet to retry the task. A member can
start a personal event subscription before connecting an account. The selected
trigger declares its required OAuth scopes; missing grants lead to the same
authorization flow. The return URL carries the subscription's event type and
resource, so cancellation and successful authorization restore the draft.
Existing subscriptions let their account owner authorize and retry; administrators
see which owner must supply the grant.
The authorization request uses PKCE and a one-use state
digest. The public callback exchanges the authorization code and stores sealed
pending tokens after checking the provider's external subject. The browser then
claims the completion code through its authenticated Pod session. Claiming
checks the original actor, tenant, live Human work access, and expiry before
storing the connection. A reconnect leaves the current connection available
until the new grant is claimed successfully. Progressive authorization requests
include the member's previously granted scopes together with the newly required
scopes, so connecting another Toolkit preserves the earlier grant.

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
canonical Pod origin and can be opened from external IM messages.

Lark personal grants include `offline_access` and
`contact:user.employee_id:readonly` for refresh and employee identification.
Personal calendar subscriptions request `calendar:calendar.event:read` when
needed; an existing `calendar:calendar:readonly` or `calendar:calendar` grant
also satisfies this requirement.
Creating or retrying a subscription checks the account's current grants and
returns its owner's consent link before attempting an upstream subscription.
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
for four days requires fresh authorization.

Disabling a Human increments their access version and revokes their personal
connections in the same transaction. Gateway requests check live membership and
connection status. Existing work owners stop personal Jobs and sources through
their WorkAccess lifecycle. Subscription teardown can use the last stored token
to unsubscribe without reviving a revoked account. An upstream refusal leaves
a visible degraded subscription for administrator repair.

Tenant deletion removes external subscriptions before deleting connection
credentials. If an upstream service refuses the unsubscribe, the tenant deletion
job preserves those credentials and retries through its job lifecycle.

## Tool contracts and execution authority

A plugin contributes the `connectors.connector` contract and explicit
`ToolSpec` declarations. A ToolSpec owns its name, argument and result schemas,
read/write annotations, required subject, upstream authentication mode, scopes,
and platform operation. These declarations also generate Skill metadata, a
compact operation index, individual tool references, and Applet toolkit types.
The Agent finds the operation in the index and reads its individual contract;
external operations are not added to the model's native tool registry.

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

When Lark reports an invalid access token, or Linear returns HTTP 401, the adapter
invalidates only the credential used by that request. A subsequent call uses the
shared refresh owner. Ankole does not replay a failed write automatically. Linear
also returns the personal authorization link so the member can reconnect.

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
transaction. An active reconciliation lease returns `connector_trigger_busy`,
so the current owner can record the upstream result before another attempt.
The scheduler checks desired subscriptions every minute. While the Applet
Automation panel is open, it refreshes subscription status every five seconds
so members can see when an asynchronous subscription becomes ready or fails.
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

## Persistence and lock order

Principal authorization uses rank 3. Application roots, connected accounts, and
OAuth sessions use rank 6, with roots before their dependents. Jobs and Bindings
precede connector triggers at rank 7. Delivery receipts and Runs use rank 8.
Network requests never hold these row locks. Tenant teardown removes Signal
Bindings and triggers before accounts and roots, preserving foreign-key order.

Related contracts: [Plugins](Plugins.md), [MCP-backed Skills](MCPBackedSkills.md),
[Signals](Signals.md), [Automation Jobs](AutomationJobs.md),
[Human Offboarding](HumanOffboarding.md).
