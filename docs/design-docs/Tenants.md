# Tenants

A site is one Ankole deployment with shared infrastructure and trusted site
operators. A tenant owns its people, Agents, Brain, integrations, conversations,
and work. Every Principal belongs to one tenant. A site administrator can select
another tenant's data without changing their own identity or authorization.

Private SaaS builds present a tenant as a Pod. Self-service creation composes
`Tenants.create/1`, Human creation, an explicit external identity binding, and
the browser access proof in one transaction. The creator is an ordinary member.
The site administration assignment and AuthZ roles stay with their current
owners. A private migration adds the reserved-slug constraint; FOSS databases
keep the public slug contract.

## Durable ownership

`Ankole.Tenants` owns tenant lifecycle. PostgreSQL owns tenant membership and
lifecycle state. Tenant-owned schemas declare that ownership through
`Ankole.Schema`; `Ankole.Repo` requires a tenant context and adds its SQL
predicate before executing queries. A missing context fails. Site-owned schemas
and deliberate `Repo.across_tenants` operations remain explicit.

Oban job and peer tables are site-owned. The `oban` query option does not skip
tenant checks on business tables, subqueries or CTEs. Struct writes validate
their tenant; updates and deletes include ownership in their row filters.
List-form `insert_all` requires an explicit matching `tenant_id` on every row.
An explicit `Repo.across_tenants` context permits deliberate cross-tenant writes.

Raw SQL and SQL fragments do not receive tenant predicates from the Repo. Their
domain owner supplies the predicates or declares the operation as site-wide.
The tenancy guard test records reviewed functions and call counts for raw SQL,
SQL query fragments and `Repo.across_tenants`. New calls require that list to be
reviewed; changes within a recorded call still require normal code review.

Repo applies ownership to every tenant-owned query source. The root receives
a tenant predicate; tenant joins receive it in their `ON` condition, so an outer
join retains its meaning. Subqueries, CTEs, unions, updates, and deletes use the
same context. A tenant join from a site root also requires that context. Struct,
bulk, and conflict writes validate ownership and cannot change a row's tenant.

PostgreSQL RLS is not enabled. Repo isolation tests cover every tenant schema,
query forms, joins, bulk writes, upserts, and stale or foreign-tenant structs.
Raw SQL remains an explicit domain-owned boundary. Site-wide scans select only
the required identities, then enter each tenant before running domain work.
WorkAccess explicitly bounds the cross-tenant authorizer lookup by the selected
work tenant; this exception relies on globally unique Principal UIDs.

`Repo.with_tenant/2` restores the caller's context after success or failure.
Processes do not inherit it implicitly: authenticated HTTP and Worker entry
points establish it, long-lived processes set it during initialization, and
`Ankole.Job` records it in durable job arguments. A job whose tenant was deleted
is cancelled. Site jobs use explicit cross-tenant reads and enter each tenant
before calling tenant-owned work. RuntimeFabric still uses the fixed
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

## Site administration

Exactly one tenant is privileged. Its built-in `siteadmin` group controls site
administration through AuthZRoot. Console entry and site APIs use that same
owner. The private global AppConfigure key `tenants.privileged_tenant_id` stores
its stable ID. A slug change does not change this assignment. The upgrade
resolves the previous `tenants.privileged_slug` to its tenant ID and removes the
old key; a missing or invalid assignment stops the upgrade. AuthZ loads
permissions from the operator's own tenant. Selecting
a data tenant neither grants that tenant's groups to the operator nor changes
the author recorded on writes. Brain writes use the operator as writer inside
their own tenant, preserving group and private-claim write checks. Cross-tenant
site administration uses the system writer with the operator's full attribution.

The Console defaults to `/site-admin-console`. The startup setting
`ANKOLE_SITE_ADMIN_CONSOLE_PATH` can change it; invalid or occupied paths fail
startup. `/console` returns 404. The configured path is sent only with an
authenticated administrator response, rather than bundled into public assets.
Sign-in without a return path opens the Pod at `/pod`. The Pod
session response includes the Console URL only when the current Pod Human is a
siteadmin. The Pod sidebar then shows a Console link. The Console still
requires its own Console login.

Console data APIs accept `x-ankole-tenant`; without it they use the operator's
tenant. `/api/v1/site` APIs manage site resources and ignore that header. An
unknown or deleting selected tenant returns `data_tenant_unavailable`. The
Console clears an obsolete selection and reloads. Switching tenants reloads the
Console so drafts and cached results cannot move to another tenant. The URL
hands the selection to the new document, which commits it to sessionStorage.
A cancelled tenant-switch navigation leaves the old document and its selection
unchanged.
Console data selection is stored under the document's authentication reference.
Sign-out clears that selection. Confirming OIDC sign-out also clears the current
selection; cancelling keeps it. Another authentication cannot inherit it.

Creation installs the existing tenant scaffold and chosen Brain schema packs in
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
the realtime socket still check the target tenant. A page keeps its pinned
authentication after another tab selects an account. The private SaaS entry
retains its one-use handoff for entry without a shared proof.

Any active Human can sign in through their tenant's existing providers and use
the Conversation participant contract. No siteadmin gate applies to work entry,
and work login does not open management APIs. Pod login adds the new work
authentication to the browser's existing account collection. The sidebar account
menu lists each proved Pod identity with its tenant. Selecting one makes it the
browser default and opens its Pod. The menu also opens the existing account
chooser without signing out and preserves the return path. See
[Browser Sessions](BrowserSessions.md).

## Configuration and integrations

AppConfigure and WorkerEnv keep one inheritance order: site `global`, then
`tenant:<id>`, then `agent:<uid>` where the declaration permits it. Global rows
use `site_app_configurations` and `site_worker_envs`. Tenant and Agent rows use
tenant-owned `app_configurations` and `agent_computer_worker_envs`, with a
required `tenant_id`; a scope string does not replace Repo isolation. Infrastructure
providers and plugins remain site-owned. Identity providers and directory state
belong to a tenant. See [AppConfiguration](AppConfiguration.md).

A credential-bearing platform application can serve only one tenant. Bindings
and identity providers with directory synchronization participate, including
disabled configurations. Login-only identity providers do not. Saving an
unverifiable identity fails without writing. Slack resolves `auth.test.bot_id`
through `bots.info` to `app_id`; Discord and Telegram resolve their stable bot
IDs. Resolution happens before database transactions; the encrypted config row
also stores its public application ID. Transaction locks compare these stored
IDs, without decrypting other tenants' credentials or contacting their platforms.
Mix and Release also resolve legacy configurations before startup. A failure
includes the tenant and configuration key and aborts the upgrade; repair and
rerun the same migration. Completed rows remain idempotent.
See [Signals](Signals.md) for event routing and [Conversations](Conversations.md)
for shared history and provider Delivery.

## Suspension, deletion and recovery

Suspension blocks new work and Human OIDC access while preserving data. Already
admitted attempts can finish, including recovery after a process exit. Cleanup,
Worker release and durable delivery continue. Recovery scanners do not turn a
suspended tenant into an active one; admission still checks the durable tenant
state before starting new work. Stopping work, repairing configuration and
reviewing authorization remain available while suspended. Site maintenance
handles tenants independently. A missing Brain maintainer does not prevent
mechanical maintenance; shared search indexes are maintained once per site.

Deletion first marks the tenant as deleting, then uses HumanOffboarding to
revoke its people and stop their future work across tenants. Work in another
tenant stays stopped with its original authorizer; it cannot prevent deletion.
The existing work-review list shows missing or revoked Human authority in the
selected tenant. A paused cron rule can receive explicit new authority, then
resume through Cron. Other terminal work must be replaced through its owner.
Reauthorization records the previous UID and access version and does not
restart work. Already admitted attempts retain their existing
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
Unreferenced blob bytes remain the responsibility of the existing file GC.

A failed batch can retry from durable facts. Deletion is not an export or an
undo operation. Back up PostgreSQL, file storage, Agent Homes and the original
encryption key before an upgrade. Stop every old control-plane replica before
the tenant migration; this release uses Recreate. Existing data enters the
default tenant with existing UIDs and storage ownership intact. A conflicting
preexisting `siteadmin` group must be renamed manually before retrying migration.
Tenant columns use a constant default for existing rows, then drop that default;
new writes must provide ownership. The admin scope migration updates both stored
scope columns and audience tags in live Brain bodies and version snapshots.

`Ankole.Upgrade202610` owns the temporary data steps in one file. The
`mix ecto.migrate` alias and `Release.migrate` both call it after schema migration,
so `ecto.setup`, package scripts, `kit app-db` and `bun dev` also complete the
data upgrade. The file starts and stops only the processes its steps need.
An operator can repeat only the data steps with
`mix run --no-start -e 'Ankole.Upgrade202610.run()'` after schema migration,
with the original encryption key and every control-plane replica stopped.

Remove that file, its Mix alias, its Release call and its tests when every
supported direct-upgrade origin includes these steps and upgrade rehearsals
leave no old identity-provider scope, shared Slack/Teams binding key or missing
application identity. Keep Recreate until supported old and new versions can
safely share schema, writers and durable job arguments; simply
upgrading one deployment does not establish either removal condition.

This boundary provides tenant storage, scaffold creation, lifecycle, and work
entry. A private site account product can compose `Tenants.create/1`, Human
creation, and identity binding in the same Repo transaction. It does not replace
tenant isolation or create a second Principal model. Registration, email
credentials, self-service pages, and billing belong to that product. Trusted site
operators and control-plane plugins retain their infrastructure authority.
