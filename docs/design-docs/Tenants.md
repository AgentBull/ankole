# Tenants

A site is one Ankole deployment with shared infrastructure and trusted site
operators. A tenant owns its people, Agents, Brain, integrations, conversations,
and work. Every Principal belongs to one tenant. A site administrator can select
another tenant's data without changing their own identity or authorization.

Private SaaS builds present a tenant as a Pod. Self-service creation composes
`Tenants.create/1`, Human creation, an explicit external identity binding, and
the browser access proof in one transaction. The creator is an ordinary member.
The site administration assignment and AuthZ roles belong to their domain
owners. SaaS databases enforce the reserved-slug constraint; FOSS databases
use the public slug contract.

## Durable ownership

`Ankole.Tenants` owns tenant lifecycle. PostgreSQL owns tenant membership and
lifecycle state. Tenant-owned schemas declare that ownership through
`Ankole.Ash.Resource`; `Ankole.Repo` requires a tenant context and adds its SQL
predicate before executing queries. A missing context fails. Site-owned schemas
and deliberate `Repo.across_tenants` operations are explicit.

The site-owned `Tenant` resource belongs to the `Ankole.Tenants` domain. Its
typed actions own profile validation and persistence. Profile writes cannot set
suspension or deletion markers. Dedicated lifecycle actions set those markers;
repeated deletion preserves the first deletion time. The final destroy action
requires a deletion marker. Each lifecycle operation (scaffold, profile
change, suspend, resume, begin deletion, site-administration transfer) and the
creation are generic actions of `Tenant`. A lifecycle action locks the
site-administration row and then the tenant row in its own transaction, and
checks the protected tenant. Another domain does the same steps in its
transaction through the `_in_tx` functions, for example `Tenants.create_in_tx/2`
in the SaaS Pod creation. The site JSON:API serves these actions at
`/api/v2/site/tenants` (list, Brain pack names, create, profile change,
suspension as `POST`/`DELETE …/suspension`, begin deletion) and
`/api/v2/site/privileged-tenant` (read, transfer). The
deletion job is a registered set maintenance module: it removes external
resources and durable child rows in dependency order with tenant-scoped SQL
before it calls the final destroy action. No generic cascade replaces that
lifecycle.

Oban job and peer tables are site-owned. The `oban` query option does not skip
tenant checks on business tables, subqueries or CTEs. Struct writes validate
their tenant; updates and deletes include ownership in their row filters.
List-form `insert_all` requires an explicit matching `tenant_id` on every row.
An explicit `Repo.across_tenants` context permits deliberate cross-tenant writes.

Raw SQL and SQL fragments do not receive tenant predicates from the Repo. Their
domain owner supplies the predicates or declares the operation as site-wide.

Repo applies ownership to every tenant-owned query source. The root receives
a tenant predicate; tenant joins receive it in their `ON` condition, so an outer
join keeps its meaning. Subqueries, CTEs, unions, updates, and deletes use the
same context. A tenant join from a site root also requires that context. Struct,
bulk, and conflict writes validate ownership and cannot change a row's tenant.
Nested Ecto queries receive the same recursive checks whether the source is a
direct query or an `Ecto.SubQuery`. This includes the direct query sources that
Ash uses for related resources and aggregates. Their declared schemas define
their site or tenant ownership.

Tenant-owned Ash resources use attribute tenancy with `global? false`.
`Ankole.Repo` owns the tenant context. `Ankole.Ash` and each domain code
interface (`Ankole.Ash.default_options/0`) give Ash the tenant of the calling
process. Site-owned resources have site scope and need no process tenant. Ash
assigns the tenant attribute. The Repo scopes each Ash read and write, so a
forged tenant option cannot read or write the rows of another tenant. A
dedicated global read action reads all tenants only in an explicit
`Repo.across_tenants` block, which `Ankole.Ash.read_across_tenants!/2` opens;
in a tenant context, the Repo limits it to that tenant. UUID and Principal
attributes use their domain codecs. Ash state fields use the transition list to
configure the Ecto enum codec, so Ecto callers also receive canonical atoms and
a query rejects a state value outside the list.

The resource transformer adds a tenant condition to each tenant resource upsert.
`create_if_absent` keeps the first row and returns it on a repeated creation
in the same tenant. It never returns a conflicting row from another tenant.
Creates that must reject a conflict declare their explicit action condition.
For tenant resources, compilation rejects writable or accepted `tenant_id`,
upserts without explicit fields, tenant ownership in those fields, and atomic
upserts. Resource policies are forbidden for both site and tenant resources.
`Ankole.Ash.DeclaredUpsert` rejects runtime overrides of the upsert contract.
Ash tenant upserts enforce the action's declared tenant condition. A caller can
select a nonempty subset of that action's declared update fields; it cannot add
fields, change tenant ownership, or add atomics. An action that declares no
update fields permits only that empty set, and a caller cannot replace a
nonempty declaration with an empty override. Global identities of tenant
resources set `all_tenants? true` and use their PostgreSQL index names.
The Repo scopes scalar queries inside batch rows and conflict queries. A CTE
join uses its scoped inner query rather than a tenant column on its projection.

Ash runs synchronously. All bulk actions use `Ankole.Ash`, which fixes their
concurrency at one. A generic action owns its transaction. It must be the
top-level call, and its `after_commit` function runs only after its commit. A
create, update, or destroy action runs in the transaction of its generic action,
or alone as one statement. It does not upgrade itself to an atomic write; an
action that must be atomic declares `require_atomic? true`. Rejection occurs in
changes or validations before database execution, so the generic action can
commit compensation. Transaction hooks and action hooks are rejected on resource
actions. The default error handler of each resource action gives the declared
exceptions of `Ankole.Errors`.
Ecto migrations own the database tables through `migrate? false` and
install the SQL expression functions that Ash requires. The schema test checks
resource constraint and index mappings against the selected edition's database.

Work lock functions declare the table and row key with `lock_identity`;
`Ankole.Ash.read/2` gives it for an Ash read with a lock. The test
checker does not infer keys from query predicates. `Repo.lock_all` checks the
actual returned keys for a selection after its single locking query. It preserves
query limits and `SKIP LOCKED` behavior. An application transaction with a tracked
row lock and no declared identity fails in tests.

Native constraints can reject a write after validation. They roll back the
current transaction with the Ash changeset. `Repo.transact` and
`Repo.transaction` give that rollback as its Ash error class
(`Ankole.Errors.rollback_result/1`) and give other rollback reasons without
change.

PostgreSQL RLS is not enabled. Repo isolation tests cover every tenant schema,
query forms, joins, bulk writes, upserts, and stale or foreign-tenant structs.
Raw SQL is an explicit domain-owned boundary. Site-wide scans select only
the required identities, then enter each tenant before running domain work.
WorkAccess explicitly bounds the cross-tenant authorizer lookup by the selected
work tenant; this exception relies on globally unique Principal UIDs.

`Repo.with_tenant/2` restores the caller's context after success or failure.
Processes do not inherit it implicitly: authenticated HTTP and Worker entry
points establish it, long-lived processes set it during initialization, and
`Ankole.Job` records it in durable job arguments. A job whose tenant was deleted
is cancelled. Site jobs use explicit cross-tenant reads and enter each tenant
before calling tenant-owned work. RuntimeFabric uses the fixed
`installation` namespace; globally unique Agent UIDs separate its routes.

Release and Mix entry points must enter each target tenant's context before
they write tenant data. Tests of these entry points must start without a tenant
context; test setup must not supply the context that the entry point must set.

Natural names, email addresses, external identities and Agent handles are unique
inside a tenant. Principal UIDs are opaque and globally unique. Attribution uses
`ankole:<tenant-id>:principal/<uid>` text without a foreign key, so the original
reference remains readable after deletion. A work authorization's `human_uid`
is also text without a foreign key; WorkAccess checks its current existence,
status and access version before admitting work.

Every foreign key between tenant-owned tables includes the child and parent
`tenant_id`. A globally unique row ID does not replace that ownership check.
PostgreSQL rejects a foreign parent on direct resource actions, upserts, and raw
SQL. Parent composite unique indexes support these foreign keys. The constraints
enforce their declared delete and update actions; `SET NULL` clears only the
optional reference and preserves the child's tenant. Site-owned browser proofs
are shared across Pods. Work authorizer references and historical attribution
use their explicit contracts without a foreign key.

## Site administration

Exactly one tenant is privileged. Its built-in `siteadmin` group controls site
administration through AuthZRoot. Console entry and site APIs use that same
owner. The private global AppConfigure key `tenants.privileged_tenant_id` stores
its stable ID. A slug change does not change this assignment. AuthZ loads
permissions from the operator's own tenant. Selecting
a data tenant neither grants that tenant's groups to the operator nor changes
the author recorded on writes. Brain writes use the operator as writer inside
their own tenant, preserving group and private-claim write checks. Cross-tenant
site administration uses the system writer with the operator's full attribution.

The site administration Console is served at the configured
`ANKOLE_SITE_ADMIN_CONSOLE_PATH` (default `/site-admin-console`); invalid or
occupied paths fail startup. The configured path is sent only with an
authenticated administrator response, rather than bundled into public assets.
Sign-in without a return path opens the Pod at `/pod`. The Pod
session response includes the Console URL only when the current Pod Human is a
siteadmin. The Pod sidebar then shows a Console link. The Console
requires its own Console login.

Console operations under `/api/v2` and native Agent file transfers accept
`x-ankole-tenant`; without it they use the operator's tenant. `/api/v2/site`
operations manage site resources and ignore that header. The v2 routers give
the selected tenant of `Ankole.Repo` to the Ash action
(`AnkoleWeb.JSONAPI.Policy`); a v2 site route gets no tenant. An
unknown or deleting selected tenant returns `data_tenant_unavailable`. The
Console clears an obsolete selection and reloads. Switching tenants reloads the
Console so drafts and cached results cannot move to another tenant. The URL
hands the selection to the new document, which commits it to sessionStorage.
A cancelled tenant-switch navigation leaves the old document and its selection
unchanged.
Console data selection is stored under the document's authentication reference.
Sign-out clears that selection. Confirming OIDC sign-out also clears the current
selection; cancelling keeps it. Another authentication cannot inherit it.

Creation installs the tenant scaffold and chosen Brain schema packs in
one transaction. Privilege transfer requires an active target Human, moves the
built-in group and grants, and leaves one privileged tenant. The transfer locks
the assignment row and target tenant in the same order as other administration
operations. The privileged
tenant cannot be suspended or deleted; transfer its role first.

## Pod work entry

The work shell belongs to the tenant's slug host: locally,
`http://<tenant-slug>.ankole.localhost:4000/`; production uses the configured Pod
subdomain. Pages and Conversations use `/pages/<short-uuid>` and
`/conversations/<short-uuid>`. Kernel encodes each UUID's 16 bytes as canonical,
unpadded base64url (22 characters). Durable storage, internal `ankole:page`
references and the private browser API at `/.internal-apis/pod` keep full UUIDs.

The Host selects the tenant. Normal navigation does not carry `tenant_id` or
use a `/pod` prefix. Legacy browser paths redirect to the canonical host and
short path. Unknown or unavailable tenant hosts fail closed. Open documents
pin their authentication and tenant on API requests; a conflicting tenant hint
cannot override the Host. The site shares its browser group and independent
account proof cookies across Pod subdomains. Login flows, API authorization and
the realtime socket check the target tenant. A page keeps its pinned
authentication after another tab selects an account. The private SaaS entry
uses its one-use handoff for entry without a shared proof.

Any active Human can sign in through their tenant's configured providers and use
the Conversation participant contract. No siteadmin gate applies to work entry,
and work login does not open management APIs. Pod login adds the new work
authentication to the browser's account collection. The sidebar account
menu lists each proved Pod identity with its tenant. Selecting one makes it the
browser default and opens its Pod. The menu also opens the account
chooser without signing out and preserves the return path. See
[Browser Sessions](BrowserSessions.md).

## Configuration and integrations

AppConfigure and WorkerEnv keep one inheritance order: site `global`, then
`tenant:<id>`, then `agent:<uid>` where the declaration permits it. Global rows
use `site_app_configurations` and `site_worker_envs`. Tenant and Agent rows use
tenant-owned `app_configurations` and `agent_computer_worker_envs`, with a
required `tenant_id`; a scope string does not replace Repo isolation. Infrastructure
providers and plugins are site-owned. Identity providers and directory state
belong to a tenant. See [AppConfiguration](AppConfiguration.md).

A credential-bearing platform application can serve only one tenant. Bindings
and identity providers with directory synchronization participate, including
disabled configurations. Login-only identity providers do not. Saving an
unverifiable identity fails without writing. Slack resolves `auth.test.bot_id`
through `bots.info` to `app_id`; Discord and Telegram resolve their stable bot
IDs. Resolution happens before database transactions; the encrypted config row
also stores its public application ID. Transaction locks compare these stored
IDs, without decrypting other tenants' credentials or contacting their platforms.
See [Signals](Signals.md) for event routing and [Conversations](Conversations.md)
for shared history and provider Delivery.

## Suspension, deletion and recovery

`Tenants.accepting_work?/1` owns the new-work state check. It accepts a loaded
tenant or reads the current state by ID. `Tenants.active_by_slug/1` applies that
check to an exact slug lookup without selecting a tenant context. Pod hosts and
login use this lookup; existence checks and maintenance use their own readers.

Suspension blocks new work and Human OIDC access while preserving data. Already
admitted attempts can finish, including recovery after a process exit. Workflow
and Codex attempt admission hold a shared tenant lock before work locks. A claim
that waits behind suspension checks the committed tenant state. Cleanup,
Worker release and durable delivery continue. Recovery scanners do not turn a
suspended tenant into an active one; admission checks the durable tenant
state before starting new work. Stopping work, repairing configuration and
reviewing authorization are available while suspended. Site maintenance
handles tenants independently. A missing Brain maintainer does not prevent
mechanical maintenance; shared search indexes are maintained once per site.

Deletion first marks the tenant as deleting, then uses HumanOffboarding to
revoke its people and stop their future work across tenants. Work in another
tenant stays stopped with its original authorizer; it cannot prevent deletion.
The work-review list shows missing or revoked Human authority in the
selected tenant. A paused cron rule can receive explicit new authority, then
resume through Cron. Other terminal work must be replaced through its owner.
Reauthorization records the previous UID and access version and does not
restart work. Already admitted attempts follow their
completion contract. Agent cleanup releases Workers and persistent storage.
The deletion job processes bounded, idempotent batches; PostgreSQL constraints
and the final transaction prevent a concurrent write from leaving orphan rows.
Its table list names child rows before their parents, so each batch deletes rows
of one table and the cascade foreign keys do not carry bulk data. The Pod content
tables enter the list as `db_records`, `db_views`,
`db_fields`, `db_tables`, `page_user_states`, `page_changes`, `page_contents`,
then `pages`.
Page batches delete leaves first, so a parent cannot cascade through a large
subtree in one batch.
Unreferenced blob bytes belong to the file garbage collector.

A failed batch can retry from durable facts. Deletion is not an export or an
undo operation.

This boundary provides tenant storage, scaffold creation, lifecycle, and work
entry. A private site account product can compose `Tenants.create/1`, Human
creation, and identity binding in the same Repo transaction. It does not replace
tenant isolation or create a second Principal model. Registration, email
credentials, self-service pages, and billing belong to that product. Trusted site
operators and control-plane plugins hold infrastructure authority.
