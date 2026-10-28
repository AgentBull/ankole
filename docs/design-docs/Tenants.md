# Tenants

A site is a single Ankole deployment with shared infrastructure and trusted site
operators. Within a site, each tenant owns its people, Agents, Brain,
integrations, conversations, and work, and every Principal belongs to exactly
one tenant. A site administrator can inspect or manage another tenant's data
without changing their own identity or authorization.

Each standard tenant (`hybrid_tenant = false`) owns one Pod workspace. The
`tenants` table also defines `hybrid_tenant` (`boolean NOT NULL DEFAULT false`,
with transitions from `false` to `true` forbidden). When `hybrid_tenant` is
`true`, tenant creation skips default Agent and welcome Page scaffolding, and
workspace domains (`Pod`, `Files`, `Conversations`, `AgentWorkers`,
`FunctionRuntime`, `Signals`, and external `IdentityProviders`) reject
operations for that tenant while organization profile, member, invitation, and
personal account settings remain available.

Assigning site administrators and managing AuthZ roles belong to their
respective domain owners. Tenant creation and slug updates share the same
resource validation, enforcing format rules alongside the build's reserved-slug
list: a build can point `tenant_slug_blacklist` at a local TOML file containing
a `slugs` array, which compilation embeds into the `Tenant` resource and tracks
as an external dependency.

During initial setup, the company and business step updates the privileged
tenant's display name and slug through this same profile contract. The browser
setup session holds the selected industry packs until setup completion installs
them in the completion transaction.

## Base storage placement

A site uses one control-plane PostgreSQL database, while each tenant holds an
immutable `base_db_id` that locates its physical Base tables.
`Tenants.create_in_tx/1` hashes the tenant UUID across open shards with
`:erlang.phash2/2`, and callers can also pass an explicit configured shard ID
for dedicated tenants. A shard marked stock-only serves only tenants already
assigned to it plus new explicit assignments; if no shard is open for automatic
placement, creation fails with `no_allocatable_base_db`. Requests read the
tenant's shard assignment inside the control-plane transaction.

`BASE_DB_URLS` configures shards as a semicolon-separated list of `postgres://`,
`postgresql://`, or `ecto://` URLs (surrounding whitespace is trimmed). Each URL
carries query options for shard routing and pooling:

- `ankole_sharding`: a unique ID of 1 to 32 lowercase ASCII letters, digits, or
  underscores. A single-URL configuration may omit this parameter to use
  `base_default`, whereas multi-URL configurations must name every shard ID.
- `ankole_stock_only`: `true` or `false` (default `false`).
- `ankole_pool_size`: a positive integer.

On startup, Ankole rejects URLs that specify `sslmode` or contain duplicate or
unknown `ankole_*` keys. All shard connections run over the internal PostgreSQL
network.

| Environment | Default topology when `BASE_DB_URLS` is unset | Pool per shard |
| --- | --- | --- |
| Production (single DB) | `DATABASE_URL`, ID `base_default` | 10 |
| Development | `ankole_base_00` through `ankole_base_03` | 2 |
| Test | Four databases with `_test_<partition>` suffix | 2 |
| Multi-shard edition default | `ankole_base_00` through `ankole_base_07` | 5 |

Only development and test environments create missing databases automatically,
cloning `template0` with the control-plane locale provider, collation, and
character rules. Production operators provision independent databases up front;
a single-database deployment that shares `DATABASE_URL` needs no `CREATEDB`
privilege, and `BaseRepo` still maintains its own connection pool separate from
`Ankole.Repo`.

Every database requires PostgreSQL 18. At startup, Ankole verifies each
reachable shard's locale against the control plane and initializes the singleton
identity row in `public._ankole_shard`. If a shard is temporarily unreachable,
its pool reconnects independently while healthy shards continue serving traffic;
each new connection re-checks PostgreSQL version, locale, and shard identity in
`after_connect`, initializing `public._ankole_shard` transactionally if the
shard was first reached on reconnect. Startup fails if any reachable shard
mismatches its expected identity or locale, or if the configured topology omits
any assigned shard—even for a tenant that is currently being deleted. `BaseRepo`
uses unnamed prepared statements so it works cleanly behind PgBouncer
transaction pooling; for large tenants, operators can tune PgBouncer
`server_lifetime` to recycle backend catalog caches and raise PostgreSQL
`max_locks_per_transaction`.

Physical Base objects live in the per-tenant schema `t_<tenant_hex>`.
`BaseRepo.tenant_schema!/0` derives this schema name exclusively from the active
Repo tenant, so queries without a tenant context fail. Reviewed modules that
issue physical SQL declare `@raw_sql_scope :tenant_schema`, and static boundary
checks require every SQL statement in those modules to call a context-derived
schema helper—using a schema helper in one statement does not exempt other
queries in the same module. The query-escape inventory tracks all such calls.
During tenant deletion, Ankole drops physical tables in batches of 100 and then
drops the schema with a 15-second lock timeout before deleting the tenant row.

A single-database deployment can take one atomic `pg_dump`. When Base shards run
on independent PostgreSQL instances, every shard's point-in-time recovery target
must be at or ahead of the control-plane recovery target; a shard recovered to a
slightly newer timestamp can rebuild interrupted promotions on retry. If a
shard's schema version mismatches the application, Ankole rejects operations on
the affected tables until an operator repairs the shard.

## Durable ownership

`Ankole.Tenants` owns the tenant lifecycle, and PostgreSQL stores all tenant
membership and lifecycle state. Tenant-owned schemas declare their scope through
`Ankole.Ash.Resource`, and `Ankole.Repo` requires an active tenant context and
injects the `tenant_id` predicate before running any query; queries without a
tenant context fail. Site-owned schemas and deliberate `Repo.across_tenants`
blocks opt out explicitly.

The site-owned `Tenant` resource in `Ankole.Tenants` handles profile validation
and persistence through typed actions. Profile updates cannot set suspension or
deletion markers; dedicated lifecycle actions manage those markers instead,
preserving the original timestamp on repeated deletion requests and requiring a
deletion marker before the final destroy action can run. Each multi-step
lifecycle operation—create, scaffold, profile update, suspend, resume, begin
deletion, and privilege transfer—runs inside `Repo.transact_top_level/2`,
locking the site-administration row before the tenant row and enforcing
protected-tenant guards. Other domains and build extensions compose the same
steps inside an open transaction through `*_in_tx` helpers such as
`Tenants.create_in_tx/1`.

For Console management, `Tenant` exposes generic JSON:API actions at
`/api/v2/site/tenants` (list, Brain pack catalog, create, profile update,
`POST`/`DELETE …/suspension`, and begin deletion) and
`/api/v2/site/privileged-tenant` (read and transfer). Actual data removal runs
in a registered maintenance job that deletes external resources and durable
child rows in dependency order using tenant-scoped SQL before invoking the final
destroy action—never relying on an unbounded `ON DELETE CASCADE`.

Oban job and peer tables are site-owned, and passing the `oban` query option
never bypasses tenant checks on business tables, subqueries, or CTEs. Struct
writes validate their `tenant_id`, updates and deletes include `tenant_id` in
their `WHERE` filters, and list-form `insert_all` calls require an explicit,
matching `tenant_id` on every map unless wrapped in an explicit
`Repo.across_tenants` block. Likewise, `Ankole.Repo` does not rewrite raw SQL
strings or Ecto SQL fragments: the owning domain must supply explicit tenant
predicates or declare the statement as site-wide.

For Ecto queries, `Ankole.Repo` attaches tenant ownership to every tenant-owned
query source recursively:

- Root tables receive a `WHERE` predicate, while tenant-owned joins receive the
  predicate in their `ON` clause so `LEFT JOIN` semantics stay intact (joining a
  tenant table from a site-owned root also requires an active tenant context).
- Subqueries (`Ecto.SubQuery` and direct query sources, including those generated
  by Ash for relationships and aggregates), CTEs, unions, updates, and deletes
  all inherit and enforce the same tenant context based on each schema's
  declared ownership.
- Struct, bulk, and `ON CONFLICT` writes validate tenant ownership and forbid
  changing an existing row's `tenant_id`.

Tenant-owned Ash resources configure attribute tenancy with `global? false`,
while site-owned resources operate at site scope without a process tenant.
`Ankole.Ash` and domain code interfaces (`Ankole.Ash.default_options/0`) pass
the calling process's `Ankole.Repo` tenant into Ash, which populates the tenant
attribute; because `Ankole.Repo` independently scopes every SQL read and write,
a forged Ash `:tenant` option can never read or mutate another tenant's rows.
Cross-tenant Ash reads use dedicated global read actions inside an explicit
`Repo.across_tenants` block opened by `Ankole.Ash.read_across_tenants!/2` (if
invoked inside a tenant context, `Ankole.Repo` still restricts results to that
tenant). UUID and Principal attributes use domain codecs, and Ash state-machine
attributes wire their transition list into the Ecto enum codec so direct Ecto
callers also receive canonical atoms and invalid state strings fail at query
time.

Compile-time Ash verifiers and transformers enforce strict upsert rules on
tenant resources:

- Compilation rejects writable or accepted `tenant_id` attributes, upserts
  without explicit update fields, `tenant_id` inside update fields, atomic
  upserts, and Ash resource policies (on both site and tenant resources).
- The resource transformer injects a tenant condition into every tenant upsert,
  and `Ankole.Ash.DeclaredUpsert` forbids runtime overrides of the upsert
  contract: callers may choose a nonempty subset of an action's declared update
  fields (or the empty set when the action declares none), and may never add
  undeclared fields, replace a nonempty declaration with an empty list, alter
  tenancy, or attach atomics.
- `create_if_absent` retains and returns the existing row when repeated within
  the same tenant and never returns a colliding row from another tenant; creates
  that must fail on duplicates declare an explicit action condition.
- Global identities on tenant resources set `all_tenants? true` mapped to their
  PostgreSQL index names, and `Ankole.Repo` scopes scalar subqueries inside
  batch rows and conflict targets while scoping CTE joins inside the CTE body
  rather than projecting an outer `tenant_id` column.

Ash executes synchronously, and `Ankole.Ash` pins bulk-action concurrency to `1`.
Top-level transactions belong to `Repo.transact_top_level/2` and stateless
generic actions, firing `after_commit` callbacks only after the outer commit.
Resource `create`, `update`, and `destroy` actions compose inside the caller's
transaction (or run as a single statement when called standalone) without
auto-upgrading to atomic SQL unless they declare `require_atomic? true`, and
without transaction or action hooks. Validations and changes reject invalid
inputs before touching PostgreSQL so the enclosing transaction can still commit
compensation writes, mapping errors through `Ankole.Errors`. Database schema DDL
lives exclusively in Ecto migrations (`migrate? false`), which also install
required Ash SQL helper functions, and schema tests verify Ash constraint and
index names against the active edition's database.

Row-locking helpers register their table and row key via `lock_identity`
(populated automatically by `Ankole.Ash.read/2` for locked Ash reads) rather
than relying on the test harness to parse SQL predicates. `Repo.lock_all`
executes a single locking query—preserving `LIMIT` and `SKIP LOCKED`—and then
registers the returned keys; in tests, any application transaction that acquires
a tracked row lock without declaring `lock_identity` fails. If a native
PostgreSQL constraint rejects a write after Ash validation, the transaction
rolls back with the Ash changeset, and `Repo.transact` / `Repo.transaction`
unwrap that rollback into its `Ankole.Errors` class via
`Ankole.Errors.rollback_result/1` while passing non-Ash rollback values through
unchanged.

Ankole enforces tenant isolation in `Ankole.Repo` rather than PostgreSQL RLS,
backed by comprehensive Repo isolation tests across all tenant schemas, query
shapes, joins, bulk operations, upserts, and stale or cross-tenant structs.
Site-wide background scans read only minimal target IDs across tenants and then
enter each tenant's context before running domain logic. As one explicit
exception grounded in globally unique Principal UIDs, `WorkAccess` bounds its
cross-tenant authorizer lookup by the selected work tenant.

Process tenant context is always explicit: `Repo.with_tenant/2` restores the
previous context on exit or raise, and spawned processes never inherit tenancy
implicitly. Authenticated HTTP plugs and Worker endpoints set the context per
request, long-lived processes bind it during `init`, and `Ankole.Job` persists
`tenant_id` in durable job args (cancelling jobs whose tenant has been deleted,
while site-wide jobs scan across tenants and enter each tenant individually).
`RuntimeFabric` routes over the single `installation` namespace, relying on
globally unique `agent_uid` values to separate Agents. Release tasks and Mix
entry points must likewise enter each target tenant before writing tenant rows,
and their tests must start with no ambient tenant set in setup.

Within a tenant, natural names, email addresses, external subject bindings, and
Agent handles are unique, whereas Principal UIDs are globally unique opaque
identifiers. Historical attribution (`ankole:<tenant-id>:principal/<uid>`) and
work authorization (`human_uid`) are stored as plain text without foreign keys
so audit trails remain readable after Principal deletion, while `WorkAccess`
verifies live existence, status, and `access_version` before admitting work. By
contrast, every foreign key between tenant-owned tables is composite and
includes `tenant_id` on both child and parent—even when the row ID is globally
unique—backed by composite parent unique indexes so PostgreSQL blocks
cross-tenant references across Ash actions, upserts, and raw SQL (`ON DELETE SET NULL`
clears only the nullable reference column while keeping the child's
`tenant_id`). Site-owned browser proofs are shared across Pods.

## Site administration

Exactly one tenant holds site-administration privilege, stored under the private
global AppConfigure key `tenants.privileged_tenant_id` (unaffected by slug
renames). Its built-in `siteadmin` group governs Console access and site APIs
through `AuthZRoot`. Permissions always load from the operator's home tenant:
selecting another data tenant in the Console neither grants that tenant's group
memberships nor alters write attribution. When an operator edits Brain records
inside their own tenant, they act as the direct writer so group and
private-claim checks apply; cross-tenant administrative writes use the system
writer paired with full operator attribution.

Ankole serves the site administration Console at
`ANKOLE_SITE_ADMIN_CONSOLE_PATH` (default `/site-admin-console`), failing
startup if the path is invalid or collides with another route. Rather than
embedding that path in public frontend bundles, the server discloses it only in
authenticated siteadmin responses: signing in without a return URL opens `/` on
the canonical Pod host, and if the signed-in Human belongs to `siteadmin`, the
Pod session payload includes the Console URL so the Pod sidebar renders a
Console link (which still requires its own dedicated Console login).

Console `/api/v2` endpoints and native Agent file transfers honor the
`x-ankole-tenant` header—defaulting to the operator's own tenant when
omitted—and `AnkoleWeb.JSONAPI.Context` binds that tenant on `Ankole.Repo` for
the Ash action. Site-scoped `/api/v2/site` endpoints ignore `x-ankole-tenant`
and run without a Repo tenant. If `x-ankole-tenant` names an unknown or deleting
tenant, the server responds with `data_tenant_unavailable`, prompting the
Console to clear its stale selection and reload. Switching tenants in the UI
triggers a full document reload so unsaved drafts and cached query results never
bleed across tenants: the navigation URL passes the chosen tenant to the new
document, which persists it to `sessionStorage` keyed by the active
authentication reference (if navigation is cancelled, the current document and
selection stay intact). Signing out—or confirming an OIDC sign-out—clears the
stored selection, cancelling OIDC sign-out keeps it, and another login session
never inherits it.

Tenant-owned Console collections show all active and suspended tenants when the
operator has no data-tenant selection. Each tenant section uses a separate API
request, query-cache key, filter, and paging cursor. Rows identify their tenant,
and record links carry that tenant into the destination document, including when
the operator opens a new tab. The tenant filter can select one tenant or restore
the aggregate view. Links to editors for site resources preserve that selection, and site
queries share one cache entry across tenant sections.
Settings open in tenant scope by default. Selecting site scope opens one site
view while preserving the operator's tenant selection. Agent Library uses the
same boundary for site defaults and tenant defaults.
The browser preserves both standard and URL-safe Base64 cursors, including
padding, in the URL history so reload and previous-page navigation keep the
server's cursor intact.

Tenant-scoped Console extensions use the Console tenant-context hooks for
queries, mutations, links, and search parameters. Site-scoped extensions use
their site API contracts and render once.
Unknown Console routes render the route fallback without a data-tenant
selection.

Record forms require a data-tenant selection before they load a draft or send a
request. Creating a record binds it to that tenant. Switching tenants from an
existing record opens the destination tenant's collection; it does not transfer
the record. Site-owned resources, including tenants, AI providers, Worker
providers, and site configuration values, use their site API contracts.

Creating a tenant installs its workspace scaffold and selected Brain schema
packs in one transaction. Transferring site privilege requires an active Human
in the target tenant and runs under the standard administration lock order: in a
single transaction, Ankole updates `tenants.privileged_tenant_id`, moves the
built-in group and grants, removes the former `siteadmin` group's grants, and
refreshes affected Page permission anchors and inheriting descendants, leaving
exactly one privileged tenant. Operators cannot suspend or delete the privileged
tenant without transferring its role first.

## Pod administration

Every tenant includes a built-in `pod_admin` group that grants
`tenant_console:**` permissions within that Pod. Only active Human members may
belong to `pod_admin`—Guests and Agents are excluded—and Ankole rejects any
removal, role edit, or member exit that would leave zero active human Pod
administrators. Initial site bootstrap places the first administrator in both
`siteadmin` and `pod_admin`, while creating an additional tenant places its
initial administrator in that tenant's `pod_admin`.

Pod settings govern the workspace display name, default language
(`i18n.default_locale`), Guest admission, login policies, member directory,
credential assistance, invitations, and enterprise identity providers, whereas
personal account settings cover verified login-method updates and self-service
exit for unmanaged members (directory-synced members leave
through organization offboarding); see [Authentication](Authentication.md).

## Pod work entry

Each Pod workspace is served from its tenant slug host—`http://<tenant-slug>.ankole.localhost:4000/`
in local development and the configured Pod subdomain in production. Browser
URLs address Pages and Conversations as `/pages/<short-uuid>` and
`/conversations/<short-uuid>`, where the Rust kernel encodes the 16-byte UUID as
22-character unpadded base64url, while database columns, internal `ankole:page`
links, and `/api/v2/pod` payloads continue to use canonical hyphenated UUIDs.

The HTTP `Host` header alone selects the tenant: normal Pod URLs carry neither a
`/pod` prefix nor a `tenant_id` query parameter, and legacy-shaped requests
containing `/pod`, `?tenant_id=…`, or a full UUID in `/pages/:id` or
`/conversations/:id` redirect to the canonical Pod host and short-UUID URL.
Requests to unknown or unavailable tenant hosts fail closed. Once loaded, an
open browser tab pins both its authentication reference and tenant on API calls
and realtime sockets—ignoring conflicting tenant hints and keeping its pinned
account even if another tab switches the default browser account. Browser-group
and account-proof cookies are shared across Pod subdomains, while login ceremonies
start directly on the target Pod host.

Any active Human in a tenant can sign in via that tenant's enabled identity
providers and participate in Conversations without needing `siteadmin`, and a
Pod work session never unlocks Console management APIs. Signing into a Pod adds
that proved identity to the browser's multi-account keyring: the sidebar account
switcher lists every proved `(identity, tenant)` pair, lets the user switch Pods
and update the browser default, or opens the account chooser without signing out
while preserving the return path; see [Browser Sessions](BrowserSessions.md).

## Configuration and integrations

`AppConfigure` and `WorkerEnv` resolve settings in one fixed precedence order:
site `global`, then `tenant:<id>`, then `agent:<uid>` (for keys whose schema
permits tenant or Agent overrides). Site-global values live in
`site_app_configurations` and `site_worker_envs`, whereas tenant and Agent
overrides live in tenant-owned `app_configurations` and
`agent_computer_worker_envs` with a mandatory `tenant_id` enforced by
`Ankole.Repo` rather than trusting scope strings alone. Infrastructure providers
and plugins are site-owned, while identity providers and directory-sync state
are tenant-owned; see [AppConfiguration](AppConfiguration.md).

Credential-bearing external platform applications—across messaging Bindings and
directory-syncing identity providers, even when disabled—belong to at most one
tenant (login-only OIDC providers are excluded). Before starting a write
transaction, Ankole verifies the credential with the platform to resolve a
stable application identifier: Slack maps `auth.test.bot_id` via `bots.info` to
`app_id`, and Discord and Telegram query their bot endpoints for stable bot IDs;
if verification fails, the save aborts before writing. Encrypted config rows
also store that public application ID in plaintext so transactional assignment
locks can detect cross-tenant conflicts without decrypting another tenant's
secrets or calling external APIs inside the transaction. See
[Signals](Signals.md) for inbound routing and [Conversations](Conversations.md)
for shared rooms and outbound Delivery.

## Suspension, deletion and recovery

`Tenants.accepting_work?/1` checks whether a loaded tenant struct or tenant ID
can admit new work, and `Tenants.active_by_slug/1` applies the same check to an
exact slug lookup without entering a Repo tenant context (used by Pod host
routing and login, while existence checks and maintenance jobs use dedicated
readers).

Suspending a tenant blocks new work intake and Human OIDC sign-in while
keeping stored data intact:

- Runs and tasks that were already admitted finish normally—even across process
  restarts—along with Worker release, cleanup, and durable outbound Delivery.
- Workflow and Codex attempt admission acquire a shared lock on the tenant row
  before acquiring work locks, so any claim queued behind a concurrent
  suspension observes the committed suspended state and stops.
- Recovery scanners check durable tenant state before admitting fresh work and
  never reactivate a suspended tenant, while operators can still cancel work,
  repair configurations, and review authorization.
- Site maintenance processes each tenant independently so a missing Brain
  maintainer in one tenant does not block mechanical maintenance, and shared
  search indexes run once per site.

Deleting a tenant first sets its deletion marker and invokes `HumanOffboarding`
to revoke its Human Principals and halt their unstarted work across all tenants
(stopped cross-tenant work keeps its historical authorizer text without blocking
deletion; in the surviving tenant's work-review queue, operators can reauthorize
and resume a paused cron rule—recording the prior UID and `access_version`—or
replace terminal work through its owning domain, while already admitted attempts
run to completion). Agent teardown releases Workers and persistent disks, and
the background deletion job removes database rows in bounded, idempotent
single-table batches ordered from leaves to parents so foreign-key cascades
never delete bulk subtrees at once. For Pod content, batches delete
`base_records`, `base_views`, `base_fields`, `base_tables`, `page_user_states`,
`page_changes`, `page_contents`, and finally `pages` (deleting leaf pages before
parent pages), while PostgreSQL constraints and the final destroy transaction
prevent concurrent stragglers from leaving orphan rows, and the file garbage
collector reclaims unreferenced blobs.

Interrupted deletion batches resume safely from PostgreSQL state; tenant
deletion is irreversible and is neither a data export nor an undoable archive.

Together, these contracts let higher-level provisioning flows compose
`Tenants.create_in_tx/1`, Human creation, site credential binding, `pod_admin`
membership, and browser session activation inside one top-level transaction
without introducing a parallel Principal model, while keeping infrastructure
authority strictly with site operators and control-plane plugins.
