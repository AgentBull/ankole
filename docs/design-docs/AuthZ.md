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
turn_authority, authn}` struct. `principal` is the sole executing subject;
`ActorRef.from_actor/1` derives audit attribution. Browser, OIDC, and Worker
entry points attach verified authentication facts, which the snapshot exposes
at `context.request.authn` for CEL conditions. Explicit operation surfaces update
`context.request.surface` without changing the authentication evidence.

AI colleague calls use the colleague's own grants across Drive, Pod, Workflows,
scheduled checkbacks, and Background Agent Jobs. For a personal assistant,
`Principals.authority_uid/1` resolves the same-tenant owner; business snapshots
load the owner's grants and groups, including `all_humans`. Site Console and
Tenant Console operations use the assistant's own identity and grants. Mixed
authorization batches preserve that distinction for each resource.

The assistant remains the executing Principal for audit attribution, runtime
ownership and usage. Its private runtime root is distinct from the owner's Pod
private tree, and its own root grants remain available for execution.
`turn_authority`, `WorkAccess`, and
Automation Job attempt checks validate that the instruction is still current,
including its Human status and access version. These instruction checks do not
add a second resource subject.

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
authorization decisions evaluate against the privileged tenant. The executing Principal must pass these checks for every protected action.

When resolving a group target selector, AuthZ maps either a group UUID or a
group name to the stored canonical name. Because synchronized directory, IM, and
Signal source groups can contain colon-separated namespaces, the resolver first
confirms that the group exists in PostgreSQL before expanding the resource
target for standard grant evaluation.

For Drive nodes, `Files.Access.Graph` maintains the read-only anchor graph and
permission projection. On reads, `Ankole.AuthZ.Checks.DriveAnchorFilter` evaluates
that graph inside a repeatable-read transaction, attaches a single Page query
filter for permitted containers and self-scoped pages, and computes each
returned page's effective role from the same graph. Directory listing queries
select the navigation columns and use `C` collation for positions and names.
Explicit positions sort first; unpositioned nodes sort by name and ID, using the
same order for cursor comparisons, while detail reads load full document fields.
Tree writes acquire the tenant tree lock before resolving the nodes' current
private roots, then lock those roots in node ID order before checking turn
authority or locking rows. This keeps a concurrent cross-root move from changing
the required root locks. Content commits addressed by node ID take the shared
form of the same tree lock before resolving their current private root. This
keeps ancestor moves out of the short commit transaction while allowing content
commits to run concurrently; byte uploads happen before taking that lock.
`Ankole.AuthZ.Checks.LockedAccess` re-verifies access inside the write transaction,
and subsequent table mutations use internal Ash
operations within that transaction.

At the Elixir call boundary, `Ankole.Ash.read_authorized`,
`read_one_authorized`, and `run_action_authorized` require a full `Actor` and
enforce `authorize?: true`. Internal persistence helpers pass
`authorize?: false` only after their caller has already enforced external
authorization and lock ordering.

## How AuthZ Makes a Decision

Every authorization request supplies four inputs:

- One Principal UID in the active tenant context.
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
the Drive tree in `Repo.transact_top_level/2`. Cross-domain callers compose writes
inside their own transactions through `Ankole.AuthZ.Administration.Store` and
`Ankole.AuthZ.Administration.Grants` (for example,
`Store.replace_static_group_members/3` or `Grants.upsert_permission_grant/1`),
while synchronization adapters add or remove individual members via
`AuthZ.add_synced_group_member/3` and `remove_synced_group_member/3`. These
administration modules enforce last-administrator protection and prevent
operator mutations from modifying directory- or IM-synchronized groups. Ash
resource policies are not used for permission decisions.

Grant mutations follow a strict lock order so Drive anchor state stays consistent:

- Creating or upserting a grant acquires the Drive tree lock whenever the grant
  carries a Drive action or matches `tenant_console:drive_space` with the `update`
  action.
- Updating or deleting a grant first reads the existing rule; if either the
  existing rule or the proposed rule affects Drive access, AuthZ locks the Drive
  tree before locking the `Grant` row (otherwise it locks only the `Grant` row).
- Once locked, AuthZ re-reads the `Grant` row (and Console routes check the
  locked rule's Drive-grant policy first). If a concurrent write changed the rule
  so that it now affects Drive access when the Drive tree lock was not acquired,
  AuthZ returns a stale-write error so the caller can reload the `Grant` and
  retry.

On the read path, `Ankole.AuthZ.Engine.Snapshot` is a dedicated SQL read model
at the persistence boundary, while all other AuthZ reads use Ash queries. `Snapshot` loads the
Principal, static memberships, computed groups, and candidate grants in a single
tenant-bound SQL query; for Drive checks, PostgreSQL evaluates unconditional
Userset edges directly in SQL while including conditional Userset grants in the
snapshot for the Rust kernel. Conversation membership comes from a separate
tenant-bound Conversations read and supplies the participating root IDs; participants
receive view and contribute bits without creating derived grants.

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
- exactly one owner column: `principal_uid`, `group_id`, or `source_node_id`
- `source_action` (when owned by a Userset via `source_node_id`)
- `target_node_id` and `target_scope` (when targeting a Drive node)
- `resource_pattern`
- `action` (cannot contain a colon)
- `condition` (CEL expression, defaulting to `true`)
- optional `description`
- `metadata` (JSON object)
- timestamps

A grant's natural key comprises its owner, `resource_pattern`, `action`, and
`condition`, enforced by separate partial unique indexes for Principal, group,
and Userset owners. A Userset grant names one source node and one exact Drive
action; both the source node and the target node must belong to the grant's
tenant, and a node cannot reference itself.

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
  `tenant_console:drive_space`, `tenant_console:pod_settings`,
  `tenant_console:principals`, `tenant_console:principal:<uid>`,
  `tenant_console:group:pod_admin`, `tenant_console:invitations`, and
  `tenant_console:identity_providers`)
- **Runtime Agents**: `agent:<uid>`
- **Drive content**: `drive:space:**`, `drive:private:<uid>:**`,
  `drive:**:<node-id>:**`, or `drive:**:<node-id>:node`

The `site_console:drive` grant lets Site Console operators manage all Drive
spaces, including private roots, through its administrative entry points.
Administrative grants do not confer runtime Agent access. Tenant Console grants
do not grant access to private Drive content.

Actions are non-empty exact strings without colons. As a convenience,
`authorize_permission/3` also accepts a combined `<resource>:<action>` string
and splits it at the final colon.

## Add a CEL Condition

CEL conditions receive typed bindings depending on what they guard:

- **Computed group conditions** receive `principal`.
- **General grant conditions** receive `principal`, `resource`, `action`, and
  `context`.
- **Drive grant conditions** can reference only `principal` and `context`.

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

Across main turns, Workflow tasks, scheduled work and Background Agent Jobs,
business resource checks use the personal assistant owner's permissions or the
AI colleague's own permissions. Management resource checks use the executing
Agent's own permissions. The instruction's
retained Human identity and access version still fence whether that work may
continue.
Site Console cron creation schedules service work for the selected AI colleague and
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

### Node actions

Drive uses five exact action bits: `node_view` (`1`), `node_contribute` (`2`),
`node_edit` (`4`), `node_manage` (`8`), and `node_comment` (`16`). The roles are
`view` (`1`), `contribute` (`19`), `edit` (`23`), and `manage` (`31`). Each grant
stores one action; each Userset edge requires one exact source bit.

| Node kind | `node_contribute` | `node_edit` |
| --- | --- | --- |
| Base | Create, change and delete records; upload record attachments | Change schema and metadata; create child nodes |
| Folder or conversation root | Create child nodes and write initial file content | Rename, move or delete this node |
| File | No operation | Overwrite content, rename, move or delete this node |
| Document or Applet | No operation | Edit content and create child nodes |
| Public or private root | No operation | Create child nodes |

Initial file content means the file's `object_id` is null. Its first content
commit requires `node_contribute` on its parent; subsequent commits require
`node_edit` on the file. Creating children directly under public or private
roots requires `node_edit`. Existing conversation participants receive view and
contribute bits from the current membership facts; explicit ACLs may grant more.

Operators cannot create or delete Drive grants through the generic Console grant
API (which allows only `description` edits on existing Drive grants). Instead,
Pod sharing creates and removes Drive grants through AuthZ using a typed target
node and a `container` or `self` scope: `container` grants flow down to
inheriting child nodes, whereas `self` grants apply only to the target node.

During Drive access evaluation, the Rust kernel evaluates request-dependent CEL
conditions once, and PostgreSQL combines those results with direct grants, group
memberships, tree inheritance, and Userset edges via a recursive `UNION` that
computes the least fixed point. Self-referential cycles without a granted seed
confer zero permissions, and deleting a node (or any of its ancestors) removes
its entire subtree from normal authorization (see
[Pod content model](PodContentModel.md)).

Agent tool dispatch uses the executing Agent's declared tool catalog and active
Principal status. WorkAccess validates the retained Human status and access
version when present; resource owners then apply that Agent's grants. Human
resource conditions do not constrain a valid delegated call.

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

An authorized administrator can restore a suspended or offboarded Human with an
audit reason. AuthZ evaluates the restored Human against current grants and
memberships; the administrator is responsible for the permissions being restored.
The restoration transaction and provider restrictions are described in
[Human Offboarding](HumanOffboarding.md#restore-access-explicitly).

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
