# AuthZ

AuthZ answers one question: can this Principal perform this action on this
resource? A Principal is the Human or Agent accountable for the request.

PostgreSQL stores permission rules per tenant, and group names are unique within
each tenant. When checking a tenant resource, AuthZ evaluates rules in the
selected tenant. When checking a Site Console operation, AuthZ looks up the
Principal and grants in the privileged tenant instead; that tenant scopes only
the authorization lookup and does not own the site-level resources themselves,
while a separate data tenant identifies which tenant's records the Console
operation reads or writes. Each authorization snapshot lasts for a single
request.

AuthZ grants permission solely through explicit allow rules—it has no deny
rules. Whenever required data is missing, invalid, disabled, or unmatched, AuthZ
denies the request by default.

## Ash actors and execution

External protected actions receive an `%Ankole.AuthZ.Actor{principal,
interactive_principal, turn_authority, authn, interactive_authn}` struct. On
this struct, `principal` identifies the acting subject and
`ActorRef.from_actor/1` derives audit attribution. Browser, OIDC, and Worker
entry points attach verified authentication facts—source scope, provider,
authentication methods, ceremony start, authentication time, surface, and
client IP—which the decision snapshot exposes at `context.request.authn` for CEL
conditions. An Agent carries its own authentication facts in `authn`, while
`interactive_authn` holds the Human's authentication evidence and applies only
to the Human's permission check. When a caller sets an explicit operation
surface (such as `conversation` or `agent_tool`), AuthZ updates
`context.request.surface` without modifying the underlying authentication
evidence.

At compile time, resources declare authorization rules through
`Ankole.AuthZ.Extension` (`authz` blocks), specifying the scope, target
parameter resolvers, and allowed actions, while `Ankole.AuthZ.Authorizer`
enforces those rules as the runtime Ash authorizer. Resource verifiers validate
action coverage and parameter resolvers, and the Domain verifier requires every
exposed JSON:API resource to declare both the native authorizer and extension
with JSON:API authorization enabled. These verifiers inspect the authorizer
contract directly without calling the runtime permission engine, and any
verifier diagnostic fails the build under `warnings_as_errors`.

Public bootstrap actions—setup, login, and site credential entry—declare both
`scope(:public)` and `check: :public`. Because they run before a user holds a
tenant Principal, their own authentication and setup checks validate the browser
proof or activation credential instead. The compile-time verifier rejects
`check: :public` inside any protected scope.

During protected execution, `Ankole.AuthZ.Checks.ActorGuardrail` verifies active
status, tenant scope, and Guest admission, and `Ankole.AuthZ.Checks.GrantCheck`
evaluates concrete resources and actions against the decision snapshot in the
Rust kernel. Target parameter selectors resolve in the data tenant (or in the
privileged tenant when a site request has no data tenant), after which site
authorization decisions evaluate against the privileged tenant. Whenever both an
interactive Human and an Agent appear on the Actor, both Principals must pass
their respective checks.

When resolving a group target selector, AuthZ maps either a group UUID or a
group name to the stored canonical name. Because synchronized directory, IM, and
Signal source groups can contain colon-separated namespaces, the resolver first
confirms that the group exists in PostgreSQL before expanding the resource
target for standard grant evaluation.

For Pod content, `Pod.Access.Graph` maintains the read-only anchor graph and
permission projection. On reads, `Ankole.AuthZ.Checks.PodAnchorFilter` evaluates
that graph inside a repeatable-read transaction, attaches a single Page query
filter for permitted containers and self-scoped pages, and computes each
returned page's effective role from the same graph. Directory listing queries
select only the navigation columns covered by the directory index (using `C`
collation on `position` for both sorting and cursor comparisons), while detail
reads load full document fields. On writes, `Ankole.AuthZ.Checks.LockedAccess`
re-verifies access inside the write transaction after the caller acquires tree
and row locks, and subsequent table mutations use internal Ash operations within
that transaction.

At the Elixir call boundary, `Ankole.Ash.read_authorized`,
`read_one_authorized`, and `run_action_authorized` require a full `Actor` and
enforce `authorize?: true`. Internal persistence helpers pass
`authorize?: false` only after their caller has already enforced external
authorization and lock ordering.

## How AuthZ Makes a Decision

Every authorization request supplies four inputs:

- One Principal UID.
- One concrete resource.
- One exact action or a list of exact actions.
- One JSON context object.

A grant authorizes an action only when all five conditions hold:

1. The Principal is active.
2. The grant belongs to the Principal or to one of its groups.
3. The grant's action matches the requested action exactly.
4. The grant's resource pattern matches the concrete resource.
5. The grant's CEL condition evaluates to `true`.

If any check fails, AuthZ denies the action; in a multi-action check, evaluation
stops at the first denied action.

For multi-target checks, `Ankole.AuthZ.authorize_checks/3` accepts a list of
independent resource/action checks keyed by atoms and loads a single decision
snapshot. AuthZ validates the inputs and serializes the wire payload for the
Rust kernel, which evaluates computed groups once in a shared CEL environment
and returns one boolean per check in request order. An individual check can pass
`grant_ids` to restrict evaluation to specific grant IDs within that snapshot
(an empty `grant_ids` list denies the check immediately while non-empty lists
still verify subject, action, pattern, and CEL condition). Callers use
`grant_ids` to distinguish direct shares from inherited permissions without
introducing a second permission model. If multiple checks encounter the same
invalid stored rule, AuthZ emits that diagnostic only once per call.

## Split Work between Elixir and Rust

The Elixir control plane:

- stores groups, memberships, external bindings, and grants in PostgreSQL
- creates the first administrator and protects the last active Human administrator
- validates and normalizes incoming request fields
- loads all data required for one decision in a single snapshot
- maps kernel outcomes to public Elixir results

The Rust kernel:

- parses and evaluates CEL expressions
- validates and matches resource glob patterns
- evaluates computed group memberships
- evaluates individual grants and check batches

Elixir passes all required state for a decision into the Rust kernel by value.
The kernel never queries PostgreSQL, mutates Ankole state, or handles setup
sessions and first-administrator rules. Rustler bindings convert values and
errors across the NIF boundary without adding business logic, and Bun Worker
processes call the Elixir control plane whenever they need a permission check.

## Stored Groups and Grants

`Ankole.AuthZ` is the Ash domain for the four stored authorization resources.
Their typed actions enforce field validation, database constraint mapping, and
persistence, calling Rust kernel validators for group CEL conditions and grant
patterns and storing `metadata` as a JSON object.

Console routes under `/api/v2` invoke generic actions on `Group`, `Membership`,
and `Grant`, wrapping every aggregate write that locks a group, a Principal, or
the Pod tree in `Repo.transact_top_level/2`. Cross-domain callers compose writes
inside their own transactions through `Ankole.AuthZ.Administration.Store` and
`Ankole.AuthZ.Administration.Grants` (for example,
`Store.replace_static_group_members/3` or `Grants.upsert_permission_grant/1`),
while synchronization adapters add or remove individual members via
`AuthZ.add_synced_group_member/3` and `remove_synced_group_member/3`. These
administration modules enforce last-administrator protection and prevent
operator mutations from modifying directory- or IM-synchronized groups. Ash
resource policies are not used for permission decisions.

Grant mutations follow a strict lock order so Pod anchor state stays consistent:

- Creating or upserting a grant acquires the Pod tree lock whenever the grant
  carries a Page action or matches `tenant_console:pod_space` with the `update`
  action.
- Updating or deleting a grant first reads the existing rule; if either the
  existing rule or the proposed rule affects Pod access, AuthZ locks the Pod
  tree before locking the `Grant` row (otherwise it locks only the `Grant` row).
- Once locked, AuthZ re-reads the `Grant` row (and Console routes check the
  locked rule's Page-grant policy first). If a concurrent write changed the rule
  so that it now affects Pod access when the Pod tree lock was not acquired,
  AuthZ returns a stale-write error so the caller can reload the `Grant` and
  retry.

On the read path, `Ankole.AuthZ.Engine.Snapshot` and
`AuthZ.restoration_review/1` act as dedicated SQL read models at the persistence
boundary, while all other AuthZ reads use Ash queries. `Snapshot` loads the
Principal, static memberships, computed groups, and candidate grants in a single
tenant-bound SQL query; for Pod checks, PostgreSQL evaluates unconditional
Userset edges directly in SQL while including conditional Userset grants in the
snapshot for the Rust kernel.

Idempotent writes preserve existing identity: re-admitting a static group member
keeps its original `inserted_at` timestamp, external group bindings key on their
tenant-scoped composite primary key, `ensure` operations return an existing
group without overwriting its shape or metadata, built-in group identity and CEL
conditions are immutable on update, and grant upserts match partial natural
unique indexes (for Principal, group, or Userset owners) and update only
descriptive fields.

### `principal_groups`

`principal_groups` stores these columns:

- `id` (UUIDv7)
- `name` (unique lowercase key within the tenant)
- `display_name` (non-empty string)
- `domain` (`operator`, `directory`, `im_group`, or `signal_source`)
- `kind` (`static` or `computed`)
- `built_in` (boolean flag)
- optional `computed_condition` and `description`
- `metadata` (JSON object)
- timestamps

Static groups cannot set `computed_condition`. Computed groups must belong to
the `operator` domain and supply a valid CEL expression in `computed_condition`.

### `principal_group_memberships`

`principal_group_memberships` records explicit memberships in static groups
using the composite primary key:

```text
principal_uid + group_id
```

Each row also stores `inserted_at`. Computed groups never write rows here; the
Rust kernel evaluates their membership on demand.

### `principal_group_external_bindings`

`principal_group_external_bindings` maps an external group identifier to one
AuthZ group using the composite primary key:

```text
tenant_id + provider + external_kind + external_id
```

Here, `external_kind` is either `directory_department` or `im_group`, `provider`
uses a lowercase local namespace, and the row stores `group_id`, JSON
`metadata`, and timestamps.

### `permission_grants`

`permission_grants` stores these columns:

- `id` (UUIDv7)
- exactly one owner column: `principal_uid`, `group_id`, or `source_page_id`
- `source_action` (when owned by a Userset via `source_page_id`)
- `target_page_id` and `target_scope` (when targeting a Pod Page)
- `resource_pattern`
- `action` (cannot contain a colon)
- `condition` (CEL expression, defaulting to `true`)
- optional `description`
- `metadata` (JSON object)
- timestamps

A grant's natural key comprises its owner, `resource_pattern`, `action`, and
`condition`, enforced by separate partial unique indexes for Principal, group,
and Userset owners. A Userset grant names one source Page and one exact page
action; both the source Page and the target Page must belong to the grant's
tenant, and a Page cannot reference itself.

## Name Resources and Actions

Authorization requests must name a concrete resource without glob metacharacters
(`*`, `?`, brackets, or braces). Stored grants, by contrast, can use
colon-delimited glob patterns, which the Rust kernel translates to path
separators before matching with `globset`:

- `*` matches within a single colon-separated segment.
- `**` matches across segment boundaries (though a bare `**` grant is invalid).

Resource namespaces separate administrative and runtime scopes:

- **Site Console**: `site_console:`
- **Pod administration**: `tenant_console:` (including
  `tenant_console:pod_space`, `tenant_console:pod_settings`,
  `tenant_console:principals`, `tenant_console:principal:<uid>`,
  `tenant_console:group:pod_admin`, `tenant_console:invitations`, and
  `tenant_console:identity_providers`)
- **Runtime Agents**: `agent:<uid>` and `agent:<uid>:tool:<name>`
- **Pod content**: `pod:space:**`, `pod:private:<uid>:**`,
  `pod:**:<page-id>:**`, or `pod:**:<page-id>:page`

Administrative grants (`site_console:` and `tenant_console:`) never confer
runtime Agent access or access to a Human's private Pod space.

Actions are non-empty exact strings without colons. As a convenience,
`authorize_permission/3` also accepts a combined `<resource>:<action>` string
and splits it at the final colon.

## Add a CEL Condition

CEL conditions receive typed bindings depending on what they guard:

- **Computed group conditions** receive `principal`.
- **General grant conditions** receive `principal`, `resource`, `action`, and
  `context`.
- **Pod Page grant conditions** can reference only `principal` and `context`.

Within these bindings, `principal.membership` is `"member"` or `"guest"` for
Humans and `null` for Agents and System Principals, while request metadata lives
under `context.request`. When validating CEL expressions on write, the Rust
kernel walks the AST and tracks comprehension loop variables to reject unknown
free variables; writes also validate `resource_pattern` syntax in the kernel.

Trusted request context comes only from verified transport boundaries, never
from caller-supplied request bodies:

- Direct HTTP and WebSocket adapters populate the client IP and surface, and
  Applet tasks forward that context to capability calls.
- Native conversation Signals persist the trusted client IP in
  `data.request_context`. Runtime tools and Pod RPCs accept that IP only from a
  kernel-produced native input with matching conversation and session keys;
  derived work (Background Agent Jobs, Workflows, Schedules, and Automations)
  traces its stored owner chain back to that originating input, requiring every
  hop to preserve the Agent and `WorkAccess` identity (a missing or broken link
  yields no trusted IP).
- Runtime Agent requests set `context.request.surface` to `agent_tool` or
  `agent_rpc`. Tool checks pass the public tool name and normalized arguments in
  `context.request.args` during both preparation and dispatch; internal Worker
  transport names and wire arguments do not alter this authorization input.

When an Agent acts on behalf of a Human—across main turns, Workflow tasks,
scheduled work, and Background Agent Jobs—AuthZ requires the Human's `invoke`
grant for each tool and intersects the Human's and Agent's permissions for Pod
access. Autonomous service work uses the Agent's own permissions.
Site Console cron creation schedules service work for the selected Agent and
records the administrator as the audit actor.

If a persisted CEL expression or resource pattern is corrupt or invalid at
evaluation time, the Rust kernel skips that group or grant, records a
diagnostic, and denies by default. The control plane logs these diagnostics
under `authz.invalid_persisted_data` and emits the
`ankole.authz.invalid_persisted_data` telemetry event.

## Load the Data for One Decision

To evaluate a decision, the Elixir control plane:

1. Validates the Principal UID, concrete resource, action, and context.
2. Loads the Principal, group state, and candidate grants in one SQL snapshot
   (narrowing candidate grants in SQL for speed while leaving full verification
   to the kernel).
3. Passes the snapshot to the Rust kernel, which checks owner, action, pattern,
   and CEL condition.
4. Maps the kernel's status (`allow`, `deny`, `principal_disabled`, or
   `invalid_request`) to the public Elixir result: `authorize/4` returns `:ok`
   only for `allow`, and `allowed?/4` returns `false` on any denial or error.

## Manage Groups

`Ankole.AuthZ` provides operations to:

- list, read, create, update, and delete `operator` groups
- list static group members and group-owned grants
- add or remove static group memberships
- preview a computed group's CEL condition against active Principals (without
  writing membership rows)
- summarize stored member counts and owned grants

Group `name` values are stable lowercase identifiers. Built-in groups cannot be
deleted, and updates to a built-in group cannot alter its `name`, `kind`,
`built_in` flag, or `computed_condition`.

Domain boundaries isolate group synchronization: directory sync updates only
memberships bound to that directory provider without touching `operator` groups
or other providers' bindings, and chat group sync operates strictly within the
`im_group` domain.

## Manage Grants

`Ankole.AuthZ` provides operations to:

- list Principal-owned or group-owned grants
- create a grant or upsert one by its natural key (updating only `description`,
  `metadata`, and `updated_at` when the natural key already exists)
- update or delete a grant by ID

### Page Actions

Pod Page permissions use four reserved actions—`page_view` (bit `1`),
`page_write_records` (bit `2`), `page_edit` (bit `4`), and `page_manage` (bit
`8`)—which combine into the four Pod roles: `view` (mask `1`), `contribute`
(mask `3`), `edit` (mask `7`), and `manage` (mask `15`). Each stored row in
`permission_grants` holds a single exact action (so assigning a role writes the
set of actions required by that role), and each recursive Userset edge checks
one exact source bit. For Human-driven Agent work, Ankole intersects the Human
and Agent bitmasks.

Operators cannot create or delete Page grants through the generic Console grant
API (which allows only `description` edits on existing Page grants). Instead,
Pod sharing creates and removes Page grants through AuthZ using a typed target
Page and a `container` or `self` scope: `container` grants flow down to
inheriting child Pages, whereas `self` grants apply only to the target Page.

During Pod access evaluation, the Rust kernel evaluates request-dependent CEL
conditions once, and PostgreSQL combines those results with direct grants, group
memberships, tree inheritance, and Userset edges via a recursive `UNION` that
computes the least fixed point. Self-referential cycles without a granted seed
confer zero permissions, and deleting a Page (or any of its ancestors) removes
its entire subtree from normal authorization (see
[Pod content model](PodContentModel.md)).

## Create the First Administrator

Every tenant starts with two built-in groups:

- `all_humans`, a computed group defined by:

  ```text
  principal.type == "human" && principal.membership == "member" && principal.status == "active"
  ```

- `pod_admin`, a static group that grants administrative actions over
  `tenant_console:**` within that tenant.

In addition, the privileged tenant receives the built-in static `siteadmin`
group. A site administrator must be an active Human member of the privileged
tenant who belongs to `siteadmin`; a group named `siteadmin` in any other tenant
confers no site access. Only active Human members can join `siteadmin` or
`pod_admin`—Guests and Agents are rejected.

During first-time site setup, a single transaction creates these built-in
groups, adds the first Human to both `siteadmin` and `pod_admin`, and grants
`read`, `update`, `delete`, `reset`, `decrypt`, and `sync` over both
`site_console:**` and `tenant_console:**` to `siteadmin` (and over
`tenant_console:**` to `pod_admin`). That first Principal can safely repeat the
initial claim idempotently, after which no other Principal can claim the
first-administrator role; setup bootstrap can also repair missing built-in
grants after root setup finishes. Creating an additional tenant places its
initial administrator in that tenant's `pod_admin` group with those same six
actions over `tenant_console:**`.

AuthZ blocks manual operations from removing or disabling the last active Human
administrator in `siteadmin` or in any tenant's `pod_admin` group. Only a
confirmed enterprise-provider departure can disable that last Human, and public
setup remains closed afterward. If no active administrator remains, an operator
can run `mix ankole.admin.recover` (optionally with `--tenant SLUG`), which
invokes `recover_admin_in_tx/1` or `recover_pod_admin_in_tx/1` for the audited
recovery procedure described in [Human Offboarding](HumanOffboarding.md).

Before restoring a suspended or offboarded Human, `restoration_review/1` builds
an approval projection of the tenant's direct grants, static memberships,
computed group rules, and all Userset grants (sorted by ID, including source
Page and action, target Page and scope, `resource_pattern`, `action`, and
`condition`), together with a fingerprint over that rule set and the Human's
access version. Administrators can prune unwanted permissions in AuthZ first,
and the restoration record captures the approved projection.

## Public Functions

`Ankole.AuthZ` exposes six primary decision functions:

- `authorize/4`
- `authorize_all/4`
- `authorize_permission/3`
- `allowed?/4`
- `authorize_decision/4`
- `authorize_all_decision/4`

It also provides snapshot/data builders for tests and explicit cross-process
calls, while administrative write functions return structured domain errors.

## Site Administration

`tenants.privileged_tenant_id` identifies the privileged tenant by its immutable
ID (so renaming a tenant's slug does not alter site-admin ownership) and is
marked non-writable in the generic settings editor. Transferring site
administration runs through `Tenants.transfer_site_administration/2`, which
locks both `tenants.privileged_tenant_id` and the target tenant in one
transaction, ensures the chosen active Human is a site administrator, transfers
the role, and refreshes every Page anchor (and inheriting descendants) affected
by deleting the old group's grants. Ankole rejects suspending or deleting the
privileged tenant.

All Web Console modules authorize against the `site_console:` namespace—even
modules that read or write records in a selected data tenant. While
`/api/v2/site/` routes operate on site-owned resources and other Console routes
operate on tenant data, AuthZ always evaluates the caller's `site_console:`
grants in the privileged tenant.

## Rules

- Use Principals as the sole accountable subjects.
- Persist all permission rules in PostgreSQL.
- Assign each grant to exactly one owner (Principal, group, or Userset).
- Match action names exactly without wildcards or colons.
- Evaluate authorization checks only against concrete resource identifiers.
- Run shared pattern, computed-group, and CEL evaluation in the Rust kernel.
- Skip invalid persisted rules, emit diagnostics, and deny by default.
- Grant access only through explicit allow rules; deny everything else by default.
- Prevent manual operations from removing or disabling the last active Human administrator.

See [Principal](Principal.md) for Principal identity and status rules.
