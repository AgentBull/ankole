# AuthZ

AuthZ answers one question: can this Principal perform this action on this
resource? A Principal is the human or Agent responsible for the request.

PostgreSQL stores permission rules per tenant. Group names are unique within
a tenant. Tenant resource checks use the selected tenant. Site Console checks
find the Principal and grants in the privileged tenant. This tenant limits
the authorization lookup; it does not own the site Console resources. A
separate data tenant selects the records that a Console operation reads or
writes. Snapshots last for one request.

AuthZ grants permission only through explicit allow rules. It has no deny rule.
If required data is missing, invalid, disabled, or unmatched, AuthZ denies the
request.

## Ash actors and execution

External protected actions receive `%Ankole.AuthZ.Actor{principal,
interactive_principal, turn_authority, authn, interactive_authn}`. The Principal supplies identity;
`ActorRef.from_actor/1` supplies audit attribution. Browser, OIDC, and worker
entries supply verified authentication facts. These include source scope,
provider, methods, ceremony start, authentication time, surface, and IP.
The snapshot places them at `context.request.authn` for CEL conditions.
An Agent uses its own authentication facts. `interactive_authn` contains the
Human's evidence and applies only to the Human's permission check. An explicit
operation surface, such as `conversation` or `agent_tool`, selects
`context.request.surface` without changing the authentication evidence.

`Ankole.AuthZ.Extension` owns the compile-time `authz` declarations.
`Ankole.AuthZ.Authorizer` is the runtime Ash authorizer. The declaration names
the scope, target parameter resolvers, and allowed actions. Resource verifiers
check coverage and resolvers. The Domain verifier requires every exposed
JSON:API resource to declare the native authorizer and extension, and requires
JSON:API authorization. Verifier diagnostics fail the build through
`warnings_as_errors`. The verifiers inspect the native authorizer contract
without depending on its permission engine.

Setup, login, and site credential entry actions declare both `scope(:public)`
and `check: :public`. These actions do not require a tenant Principal. Their
own authentication and setup checks validate the browser proof or activation
credential. The verifier rejects a public check in a protected scope.

`ActorGuardrail` checks active status, tenant scope, and Guest admission.
`GrantCheck` evaluates concrete resources and actions with the decision snapshot
and Kernel. Target selectors resolve in the data tenant. A site request without
a data tenant resolves in the privileged tenant. Site decisions then use the
privileged tenant. An interactive Human and an Agent must both pass their checks.

`Pod.Access.Graph` owns the read-only anchor graph and permission projection.
`PodAnchorFilter` evaluates that graph in a repeatable-read transaction
and adds one Page query filter for permitted containers and self pages. Its
result projection computes each page's role from that same graph. Directory
queries select only the navigation fields covered by the directory index;
a detail read loads the document fields. The `position` column uses `C`
collation for both ordering and cursor comparisons.
`LockedAccess` checks records inside the transaction, after the owner takes tree
and row locks. Table writes use internal Ash operations in that transaction.

`Ankole.Ash.read_authorized`, `read_one_authorized`, and
`run_action_authorized` require a full Actor and force `authorize?: true`.
Internal persistence helpers use `authorize?: false`. Their caller owns the
external authorization decision and lock order.

## How AuthZ Makes a Decision

An authorization request contains these values:

- One Principal UID.
- One concrete resource.
- One exact action or a list of exact actions.
- One JSON context object.

A grant permits one action only when:

1. The Principal is active.
2. The grant belongs to the Principal or one of its groups.
3. The action matches exactly.
4. The resource pattern matches the concrete resource.
5. The CEL condition returns true.

Any failed check denies the action. A batch stops at its first denied action.

`Ankole.AuthZ.authorize_checks/3` accepts independent resource/action checks
with atom keys and loads one snapshot. Optional `grant_ids` restricts a check
to those grants. AuthZ owns input validation and the kernel wire format. The kernel
returns one boolean per check in request order. It evaluates computed groups
once and uses one CEL environment. A check can restrict itself to named grant
IDs from that snapshot; an empty set denies the check. The kernel still checks
the subject, action, pattern, and condition. This permits a caller to distinguish
direct shares from inherited access without another permission model.
Repeated diagnostics for the same stored error appear once per call.

## Split Work between Elixir and Rust

The Elixir control plane:

- stores groups, memberships, external bindings, and grants
- creates the first administrator
- protects the last active human administrator
- checks and normalizes request fields
- loads all data needed for one decision
- returns the public result

The Rust kernel:

- checks and evaluates CEL
- checks and matches resource patterns
- evaluates computed groups
- evaluates grants and batches

Elixir passes the kernel all data for one decision. The kernel never reads
PostgreSQL or changes Ankole data. It does not know about setup sessions or
first-administrator rules.

Rustler exposes the evaluator to the Elixir control plane. The bindings only
convert values and errors.

Bun code calls the control plane for permission decisions.

## Stored Groups and Grants

`Ankole.AuthZ` is the Ash domain of the four stored resource types. Their typed
actions own field validation, native constraint errors, and persistence.
Group conditions and grant rules use the Kernel syntax validators.
Metadata uses the durable JSON object type.

Each aggregate write that locks a group, a Principal, or the Pod tree runs in
`Repo.transact_top_level/2`, and the `/api/v2` Console routes use generic
actions on `Group`, `Membership`, and `Grant`. `Store` and `Grants` run the
steps and lock contracts inside the caller's transaction: another domain calls
them, for example `Store.replace_static_group_members/3` or
`Grants.upsert_permission_grant/1`.
They protect the last administrator and distinguish operator groups from
groups owned by directory and conversation synchronization. Grant creation
and upsert hold the Pod tree lock when the grant has a Page action or matches
`tenant_console:pod_space` with the `update` action. Grant update and deletion
read the current rule, then lock the Pod tree before the Grant row if the
current or proposed rule affects Pod access. Other changes lock only the
Grant row. Each operation checks the locked rule again. A concurrent change
that makes the current or proposed rule affect Pod access returns the
stale-write error. The caller reloads the Grant and retries. Console checks
the locked rule's Page-grant policy before this concurrency rejection.
`AuthZ.add_synced_group_member/3` and `remove_synced_group_member/3` change one member of a synchronized group for
an adapter that observes the change. Ash policies do not make permission
decisions.

`Ankole.AuthZ.Snapshot` assembles the decision snapshot for each check. It is a
read model in the persistence boundary. One tenant-bound SQL statement loads
the Principal, static memberships, computed groups, and candidate grants.
The Pod snapshot includes conditional Userset grants. PostgreSQL evaluates
unconditional Userset edges directly.
`AuthZ.restoration_review/1` is the other read model. The other AuthZ reads
use Ash queries.

Membership admission preserves its first timestamp. External bindings use
their tenant-scoped composite key. Grant upserts use the partial
natural indexes for a Principal, a group, or a Userset and update only
descriptive fields.
An ensure operation returns the stored group identity without replacing its
shape or metadata. Built-in group identity and computation are immutable in
the update action.

### `principal_groups`

The table stores these fields:

- A UUIDv7 `id`.
- A unique lowercase `name`.
- A nonempty `display_name`.
- A `domain`.
- A `kind`.
- A `built_in` flag.
- Optional `computed_condition` and `description`.
- A JSON `metadata` object.
- Timestamps.

The `domain` field accepts these values:

- `operator`
- `directory`
- `im_group`
- `signal_source`

The `kind` field accepts `static` or `computed`.
A static group cannot contain `computed_condition`.
A computed group requires a valid CEL condition.
Every computed group must use the `operator` domain.

### `principal_group_memberships`

This table records explicit membership in static groups.
Its composite primary key is:

```text
principal_uid + group_id
```

The table also stores `inserted_at`. The kernel evaluates computed group
membership when needed and does not create a row here.

### `principal_group_external_bindings`

The table maps an external group identity to one AuthZ group.
Its composite primary key is:

```text
tenant_id + provider + external_kind + external_id
```

The `external_kind` field accepts these values:

- `directory_department`
- `im_group`

Provider names use lowercase local namespaces.
The row also stores `group_id`, JSON metadata, and timestamps.

### `permission_grants`

The table stores these fields:

- A UUIDv7 `id`.
- One owner, `principal_uid`, `group_id`, or `source_page_id`.
- `source_action` for a Userset owner.
- `target_page_id` and `target_scope` for a page target.
- `resource_pattern`.
- `action`.
- `condition` with default `true`.
- Optional `description`.
- A JSON `metadata` object.
- Timestamps.

Exactly one owner field must exist.
An action cannot contain a colon.

The natural key contains owner, resource pattern, action, and condition.
Separate partial unique indexes cover Principal, group, and Userset grants.
A Userset names one source Page and one exact page action. Both source and
target Pages must belong to the grant's tenant. A Page cannot reference itself.

## Name Resources and Actions

A request names one concrete resource. It cannot contain `*`, `?`, brackets,
or braces.

A stored grant can use a glob pattern. Colons separate resource segments.

- `*` stays inside one segment.
- `**` can cross segment boundaries.

The kernel translates colons to path separators before `globset` matching.

Site Console resources use `site_console:`. Pod space administration checks
`tenant_console:pod_space`. Runtime Agent resources use `agent:<uid>` and
`agent:<uid>:tool:<name>`. Pod grants use
`pod:space:**`, `pod:private:<uid>:**`, `pod:**:<page-id>:**`, or
`pod:**:<page-id>:page`. A bare `**` grant is invalid. Console administration
does not give runtime Agent or Private access.

Actions are nonempty exact strings.
They cannot contain a colon.

`authorize_permission` also accepts `<resource>:<action>` and splits at the
final colon.

## Add a CEL Condition

Computed group conditions receive this CEL value:

- `principal`

Grant conditions receive these CEL values:

- `principal`
- `resource`
- `action`
- `context`

Request fields are available under `context.request`. `principal.membership`
is `member` or `guest` for Humans, and null for Agents and System Principals.
Page conditions can use only `principal` and `context`. The Kernel traverses
the CEL AST and tracks comprehension bindings when it checks free variables.

HTTP and WebSocket adapters supply the request IP and surface. Applet tasks
carry that context to each capability call. Native conversation Signals store
the trusted input IP in `data.request_context`. Runtime tools and Pod RPC
read this field only from a kernel-produced native input with matching
conversation and session keys. Derived work follows the stored Job, Workflow,
Schedule, or Automation owner to that input. Each link must retain the Agent
and WorkAccess identity. An absent or invalid link supplies no trusted IP.
Runtime requests set the surface to `agent_tool` or `agent_rpc`. Tool checks
receive the public tool name and normalized arguments in `context.request.args`
at preparation and dispatch. Worker transport names and arguments do not
change this authorization input. Request bodies cannot supply trusted IP facts.

Human-derived work checks the Human's `invoke` grant for each tool and uses
the intersection of Human and Agent permissions for Pod access. This applies
to main turns, Workflow tasks, scheduled work, and Background Agent Jobs.
Service autonomous work uses Agent permissions.

Writes validate CEL syntax and free variables through the native kernel.
Writes also validate resource pattern syntax through the native kernel.

If stored CEL or a pattern is invalid, the kernel skips that group or grant,
returns a diagnostic, and denies by default.

The control plane logs these diagnostics with `authz.invalid_persisted_data`.
It also emits the `ankole.authz.invalid_persisted_data` telemetry event.

## Load the Data for One Decision

The control plane:

1. Checks the Principal UID, resource, action, and context.
2. Loads the Principal, group state, and candidate grants in one SQL snapshot.
3. Calls the Rust kernel with the snapshot.
4. Converts the kernel decision to an AuthZ result.

SQL narrows the possible grants for speed. The kernel still checks the owner,
action, pattern, and condition.

The kernel can return these decision statuses:

- `allow`
- `deny`
- `principal_disabled`
- `invalid_request`

The Elixir API returns `:ok` only for `allow`.
Boolean `allowed?` returns false for every error or denial.

## Manage Groups

`Ankole.AuthZ` supports these group operations:

- List, read, create, update, and delete operator groups.
- List static members and group grants.
- Add or remove static membership.
- Preview a computed condition against active Principals.
- Summarize stored members and owned grants.

Group names are stable lowercase keys. Previewing a computed group does not
write membership rows.

The API rejects deletion of built-in groups.
Updates cannot change their name, kind, built-in flag, or computed condition.

Directory synchronization changes only memberships from that directory. It
does not change operator groups or another provider's bindings.

Chat group synchronization uses the `im_group` domain. Domain checks stop one
provider path from changing another kind of group.

## Manage Grants

`Ankole.AuthZ` supports these grant operations:

- List Principal-owned or group-owned grants.
- Create a grant.
- Upsert a grant by its natural key.
- Update a grant by ID.
- Delete a grant by ID.

For an existing natural key, an upsert changes only the description, metadata,
and `updated_at`.

### Page Actions

The Pod page domain reserves `page_view`, `page_edit`, and `page_manage`.
The Console grant API rejects Page grant creation and deletion. It permits
only description changes on a Page grant. Pod sharing writes Page grants
through AuthZ with a typed target Page and a `container` or `self` scope.
`container` grants pass to children that inherit permissions. `self` grants
apply to the target Page only. Each action is exact. A role writes the set of
actions that the role requires.

The Kernel evaluates request-dependent conditions once. PostgreSQL combines
those results with direct grants, groups, inheritance, and Userset edges.
A recursive `UNION` computes the least fixed point. Cycles with no granted
seed give no permission. A deleted Page or ancestor removes the subtree from
normal authorization. See [Pod content model](PodContentModel.md).

## Create the First Administrator

Every tenant receives the computed `all_humans` group. The privileged tenant
also receives the built-in static `siteadmin` group. A site administrator must
be an active human Principal in that tenant and a member of that group.
A same-named group in another tenant does not grant site access.

AuthZ computes the `all_humans` group.
It uses this CEL condition:

```text
principal.type == "human" && principal.membership == "member" && principal.status == "active"
```

The first administrator must be an active Human member. Guests cannot join
the built-in administrator group. One transaction
creates both groups, adds that human to `siteadmin`, and creates Console grants.

The same Principal can safely repeat the first claim. After that, another
Principal cannot claim the first-administrator role.

The built-in administrator receives these actions over `site_console:**`
and `tenant_console:**`:

- `read`
- `update`
- `delete`
- `reset`
- `decrypt`
- `sync`

The setup bootstrap can repair these grants after root setup completes.

AuthZ prevents manual removal or disabling of the last active Human
administrator. Confirmed provider departure can disable that Human. The public
setup remains closed. `recover_admin_in_tx/1` permits the audited operator
recovery described in [Human Offboarding](HumanOffboarding.md) only when no
active administrator remains.

`restoration_review/1` projects direct grants, static memberships, computed
group rules, and all Userset grants in the selected tenant for explicit approval
before Human restoration. Each Userset entry includes its source Page and action,
target Page and scope, resource pattern, action, and condition. Entries are sorted
by ID. Its fingerprint includes this rule set and the Human access version. AuthZ
editors remove unwanted permissions; restoration records the approved projection.

## Public Functions

`Ankole.AuthZ` provides these decision functions:

- `authorize/4`
- `authorize_all/4`
- `authorize_permission/3`
- `allowed?/4`
- `authorize_decision/4`
- `authorize_all_decision/4`

It also exposes data builders for tests and explicit cross-process calls. Write
functions return detailed domain errors.

## Site Administration

`tenants.privileged_tenant_id` selects the privileged tenant by its stable ID. A
slug change does not change this assignment. The key is not writable in
the generic settings editor. `Tenants.transfer_site_administration/2` owns the
transaction that locks this configuration and the target tenant, makes the
selected active human a site administrator, and transfers the role. Suspending
or deleting the privileged tenant is rejected. Deleting the old group's grants
refreshes each affected Page anchor and its inheriting descendants in the same
transaction. Site resources use the
`site_console:` AuthZ namespace. All Web Console modules use this namespace, including
modules that operate on a selected data tenant. The `/api/v2/site/` routes
manage site resources; the other Console routes can manage tenant data.
The authorization lookup stays in the privileged tenant in both cases.

## Rules

- Use Principals as the only accountable subjects.
- Store permission rules in PostgreSQL.
- Give every grant exactly one owner.
- Match actions exactly.
- Evaluate only concrete request resources.
- Use the Rust kernel for shared rule evaluation.
- Skip invalid persisted rules and emit diagnostics.
- Deny by default.
- Protect the last active Human administrator during manual operations.

See [Principal](Principal.md) for identity and status rules.
