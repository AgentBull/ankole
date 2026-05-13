# AuthZ

BullX AuthZ is the authorization boundary for active Principals. It decides
whether one Principal may perform one action on one resource under
caller-provided request context. The first implementation adds static Principal
groups, Principal or group permission grants, and Cedar boolean conditions. It
deliberately omits computed groups and an AuthZ-specific decision cache until
real usage shows that those costs buy enough value.

## Scope

This design covers the framework-level authorization surface:

- Static groups whose members are Principals.
- Group membership management for Human, Agent, and future Principal types.
- Permission grants assigned directly to Principals or to groups.
- Resource-pattern and action authorization requests.
- Cedar boolean condition evaluation for request-time facts.
- Caller-provided authorization context normalization.
- Built-in `admin` group seed data and bootstrap-admin membership handoff from
  Principal activation metadata.
- Public API shape, persistence, failure behavior, and implementation handoff.

This design intentionally does not cover:

- Principal creation, external identity binding, activation codes, login auth
  codes, Web sessions, or provider login. Those remain in
  [Principal](Principal.md).
- Gateway signal contracts or channel actor matching.
- A BullX tenant model.
- Concrete application policy names for Web, Gateway, Runtime, Skills, Brain,
  Capability execution, Governance, Effects, or Agent runtime internals.
- Explicit deny grants and deny precedence.
- Computed groups, dynamic membership expression languages, or dependency-graph
  invalidation.
- An AuthZ-specific cache process or decision cache.
- A full Web UI for group and grant administration.
- Audit-log storage. Future audit or Governance designs consume AuthZ decisions
  but own their own durable records.

## Goals

- Make `principals.id` the only durable authorization subject id.
- Authorize Humans and Agents through the same API without treating Agents as
  second-class user accounts.
- Keep the first framework small: static groups, grants, and request conditions.
- Preserve a boring allow-any model: any applicable grant whose condition
  evaluates to `true` authorizes the request.
- Fail closed for disabled Principals, malformed requests, invalid grants, and
  Cedar errors.
- Store durable authorization facts in PostgreSQL with process-local state
  reconstructible after restart.
- Avoid Elixir callbacks, atoms, AST, or module/function strings inside runtime
  grant data.

## Cleanup plan

- **Dead code to delete:** none. AuthZ has no current implementation in this
  branch.
- **Duplicate logic to merge:** do not recreate the old `BullXAccounts`
  namespace or user-centered schema names. Move useful authorization semantics
  onto `Principal` subjects.
- **Existing utilities and patterns to reuse:** use `BullX.Principals` for
  subject loading, `BullX.Repo`, Ecto schemas, `BullX.Ecto.UUIDv7`, PostgreSQL
  constraints, and the existing `BullX.Ext` Rustler boundary for Cedar.
- **Code paths and contracts changing:** add a new `BullX.AuthZ` domain,
  AuthZ migrations, schemas, Cedar wrapper, bootstrap handoff, and public facade
  functions.
- **Invariants that must remain true:** AuthZ never creates, resolves, logs in,
  activates, or binds Principals; disabled Principals never authorize; Gateway
  actor identity remains channel-local until Principal AuthN resolves it; grant
  data is never evaluated as Elixir code; cache loss cannot lose durable
  authorization data.
- **Verification command:** run focused AuthZ tests and `bun precommit`.

## Existing system

`docs/design-docs/Principal.md` defines `principals` as the base identity table
and places Human and Agent facts in extension tables. `BullX.Principals` owns
Principal creation, external identity resolution, activation codes, bootstrap
activation, and login auth codes. Principal status is currently `active` or
`disabled`; only active Principals can act as business subjects.

The historical
[`BullXAccounts AuthZ` RFC](https://github.com/AgentBull/bullx/blob/7cff3d3306b712c8b20c413ceb8aeb0dcde5bcf3/rfcs/plans/0010_Accounts_AuthZ.md)
is a mechanics reference, not an architecture to preserve. This design keeps
the useful parts: groups, resource/action grants, Cedar request conditions,
fail-closed semantics, and bootstrap admin handoff. It replaces user-specific
names with Principal-centered names and drops computed groups plus the local
decision cache from the first implementation.

The existing `BullX.Ext` NIF boundary already carries CPU-heavy native helpers.
Cedar extends that boundary rather than adding a second native application. A
later authorization cache design uses `BullX.Cache` instead of adding a private
ETS owner process.

## Boundary with Principal AuthN

AuthZ consumes active Principals. It does not own identity, authentication, or
external binding.

AuthZ must not:

- create Principals;
- create Human or Agent extension rows;
- create channel bindings or login-subject bindings;
- issue activation codes or login auth codes;
- establish Web sessions;
- infer a Principal from a Gateway actor;
- authorize a disabled Principal.

Callers that start from a Gateway channel actor first call
`BullX.Principals.resolve_channel_actor/3` or another Principal AuthN facade
function. Callers that start from a Web session reload the durable Principal id
from PostgreSQL. Runtime code that starts from an Agent uses the Agent's
Principal id. After a current active Principal is available, callers ask AuthZ
for authorization.

Disabled Principals are denied before group lookup, grant lookup, or Cedar
evaluation. This check applies to Humans, Agents, and future Principal types.
Principal disable flows call `BullX.AuthZ.ensure_can_disable_principal/1`
before disabling a Principal so AuthZ can preserve the last active Human admin
invariant.

## Authorization model

Authorization asks whether one active Principal can perform one action on one
resource under one request context.

```elixir
%BullX.AuthZ.Request{
  principal_id: principal.id,
  resource: "gateway_channel:workplace-main",
  action: "write",
  context: %{"adapter" => "feishu"}
}
```

`resource` and `action` are non-empty strings. `resource` must not contain `*`.
The `*` character has wildcard meaning only inside persisted
`resource_pattern` values. `action` must not contain `:`, because permission
keys split at the final `:`. AuthZ never converts caller-provided resource,
action, or context values to atoms.

The public API accepts separate resource and action values, or a permission key:

```elixir
BullX.AuthZ.authorize(principal, "web_console", "read")
BullX.AuthZ.authorize(principal.id, "gateway_channel:workplace-main", "write", %{})
BullX.AuthZ.authorize_permission(principal, "gateway_channel:workplace-main:write", %{})
```

Permission keys split at the final `:`. Everything before it is the resource;
everything after it is the action. This allows resource names such as
`gateway_channel:<channel_id>` without adding ARN syntax.

### Resource and action naming

AuthZ does not define a full policy catalog, but subsystems use a consistent
resource naming shape:

- `<domain>`
- `<domain>:<id>`
- `<domain>:<id>:<child>`

Examples:

- `web_console`
- `gateway_channel:<channel_id>`
- `capability:<capability_key>`
- `agent:<agent_id>`
- `work:<work_id>`

Common action names are `read`, `write`, `manage`, `execute`, `approve`, and
`cancel`. These names are conventions, not implied permissions. Subsystems may
define additional action names when their design docs explain the contract.

### Resource patterns

Permission grants use resource patterns, not a global resource table. Resource
and action names are application-defined strings. AuthZ defines only parsing and
matching rules; later subsystem designs decide which concrete strings they
enforce.

Example permission keys:

- `web_console:read`
- `web_console:write`
- `gateway_channel:<channel_id>:write`
- `gateway_channel:*:write`
- `capability:browser_use:execute`

`*` is the only wildcard in `resource_pattern`. A pattern may contain zero or
one `*`; grant writes reject patterns with more than one wildcard. `*` matches
any character sequence inside the resource string, including `:`. All other
characters match literally. There is no `**`, character class, regular
expression, or hierarchy-specific operator.

Actions match exactly. `write` does not imply `read`. If a subsystem wants both
actions, it creates both grants.

### Decision flow

`BullX.AuthZ.authorize/4` follows this order:

1. Normalize the request.
2. Load the current Principal from PostgreSQL when the caller passes an id or
   stale struct.
3. Return `{:error, :not_found}` if the Principal is missing.
4. Return `{:error, :principal_disabled}` if the Principal is disabled.
5. Load the Principal's static groups.
6. Fetch grants assigned directly to the Principal or to any group.
7. Filter grants by action and resource pattern.
8. Evaluate applicable grants' Cedar conditions with normalized request
   context.
9. Return `:ok` if any applicable grant evaluates to `true`.
10. Return `{:error, :forbidden}` when no applicable grant allows the request.

Grant-level evaluation errors affect only that grant. They do not crash the
authorization request and do not authorize the request.

AuthZ may evaluate applicable grants in any order. Grant ordering has no
business meaning, and grants have no priority in this design.

Nil Principals, malformed Principal ids, empty resource strings, empty action
strings, resources containing `*`, actions containing `:`, invalid permission
keys, and non-Cedar-compatible contexts return `{:error, :invalid_request}`.
Well-formed ids that do not identify a Principal return `{:error, :not_found}`.

## Groups

Groups are named sets of Principals. The first implementation supports only
static groups.

`principal_groups.name` is the stable group key. It is globally unique,
lowercase, and immutable after insert. `built_in` marks groups created by
BullX. Public create/update APIs cannot set or clear `built_in`.

`principal_group_memberships` stores static membership only. A group can contain
any active or disabled Principal type. Disabled Principals may remain members so
operators can preserve administrative intent while the Principal is locked, but
authorization still denies them before group lookup matters.

`list_principal_groups/1` loads existing Principals regardless of status and
returns static group membership. Disabled status affects authorization
decisions, not membership introspection. `add_principal_to_group/2` also accepts
disabled Principals so operators can prepare or preserve membership while a
Principal is locked.

The built-in `admin` group is protected:

- AuthZ bootstrap creates it idempotently.
- It cannot be deleted through the public AuthZ API.
- Public membership APIs reject removing a membership when the removal would
  leave no static admin group members with `{:error, :last_admin_member}`.
- Public membership APIs reject removing a membership when the removal would
  leave no active Human admin members with
  `{:error, :last_active_human_admin}`.
- Principal disable flows must reject disabling the final active Human member of
  the built-in `admin` group unless an explicit recovery path is provided.
- It receives no magical authorization behavior.

The `admin` group authorizes nothing by itself. Subsystem seed data, operator
configuration, or future subsystem docs attach ordinary permission grants to it.
This keeps administrator power visible in the same grant table as every other
permission.

Recoverability is Human-centered in v1. Agents may be members of `admin` or
hold admin-like grants, but Agent-only administration does not count as a
recoverable management entry point. A disabled admin member may remain in the
group, but it does not count as an active administrator for this invariant.

This design seeds the built-in `admin` group and bootstrap membership only. It
does not create a universal action wildcard. Any subsystem that introduces an
AuthZ enforcement point must either seed ordinary grants for the built-in
`admin` group or explicitly document why setup/bootstrap remains outside AuthZ
until those grants exist.

AuthZ management surfaces use the same resource/action model as every other
subsystem. Expected resource names include `authz_group:<group_name>`,
`permission_grant:<grant_id>`, `permission_grant:*`, and
`principal:<principal_id>`, usually with action `manage`. This is a naming
convention for enforcement points, not a seeded policy catalog.

### Bootstrap admin handoff

Principal bootstrap activation uses `activation_codes.metadata.bootstrap = true`
and records `used_by_principal_id` when the code is consumed. AuthZ uses that
durable fact to assign initial administrator membership.

`BullX.AuthZ.Bootstrap` runs as a one-shot transient worker after
`BullX.Principals.Bootstrap`. It:

1. Exits normally with a warning when AuthZ tables do not exist.
2. Creates the built-in `admin` group if missing.
3. Finds consumed bootstrap activation-code rows with `used_by_principal_id`.
4. Adds the consumed Human Principal to the `admin` group idempotently.

The activation-code consumption path also calls an AuthZ handoff function after
it commits a bootstrap activation code. That function performs the same
idempotent membership insert. The worker remains necessary for recovery after
deploys, partial failures, or manual data repair.

Only activation codes with `metadata.bootstrap = true` can create automatic
admin membership, and only Human Principals can receive that bootstrap
membership. All other membership changes use normal group APIs.

## Permission grants

A permission grant assigns an allow condition to exactly one subject:

- one Principal; or
- one Principal group.

The schema uses nullable `principal_id` and `group_id` columns rather than a
polymorphic `{subject_type, subject_id}` pair. PostgreSQL can then enforce real
foreign keys to `principals` and `principal_groups`.

A grant is applicable when:

1. its subject is the request Principal or one of that Principal's groups;
2. its `action` equals the request action;
3. its `resource_pattern` matches the request resource.

After applicability is established, AuthZ evaluates the Cedar `condition`
expression. `condition = "true"` is unconditional after subject, resource, and
action matching. Empty conditions are invalid.

Multiple grants use allow-any semantics. AuthZ has no explicit deny grant and
no grant priority in the first implementation.

Public group deletion rejects deleting a group that still has permission grants
with `{:error, :group_has_grants}`. Callers must delete or move grants first so
operators do not lose permissions as an incidental side effect of group cleanup.
Membership rows may be deleted with the group.

## Cedar conditions

BullX permission grants store a Cedar boolean expression, not a complete Cedar
policy. The wrapper builds one synthetic policy after BullX has already matched
the grant subject, resource pattern, and action:

```cedar
permit(principal, action, resource)
when {
  <condition>
};
```

`<condition>` is parsed by Cedar. BullX never interprets it as Elixir code.

The Cedar wrapper lives in `BullX.AuthZ.Cedar` and calls NIF shims exposed from
`BullX.Ext`:

```elixir
@spec validate_condition(String.t()) :: :ok | {:error, String.t()}

@spec evaluate(String.t(), BullX.AuthZ.Request.t()) ::
        {:ok, boolean()} | {:error, String.t()}
```

The NIF code lives inside the existing `native/bullx_ext` Rustler crate. Do not
create a second native application or a second Rustler crate for Cedar.

The request passed to Cedar uses Principal-centered entity types:

```elixir
%{
  "principal" => %{
    "type" => "BullXPrincipal",
    "id" => principal_id,
    "attrs" => %{
      "id" => principal_id,
      "type" => Atom.to_string(principal.type),
      "status" => "active"
    }
  },
  "action" => %{"type" => "BullXAction", "id" => action},
  "resource" => %{"type" => "BullXResource", "id" => resource},
  "context" => %{"request" => caller_context}
}
```

The Rust side must construct Cedar request values through Cedar SDK
constructors rather than interpolating request strings into policy source. Only
the condition string is policy source.

The default Principal attributes intentionally exclude email, phone, channel
metadata, group names, Agent profile fields, and other profile data. Callers
that need profile-sensitive policy compute an explicit, approved fact and pass
that fact through `context.request`.

Grant writes validate `condition` through the Cedar wrapper before insert or
update. The wrapper must reject synthetic policy parse results unless they
contain exactly one `permit(principal, action, resource)` policy, no `forbid`,
no templates, no additional policies, exactly one `when` clause, and no
`unless` clause. The accepted `when` clause is evaluated as the grant condition.
The implementation must not rely on source-string equality after Cedar parsing,
because the Cedar parser may normalize whitespace, parentheses, or equivalent
syntax.

Both Cedar NIFs run on the dirty CPU scheduler. They return ordinary values or
`{:error, String.t()}` and must not panic on malformed policy source or
malformed request maps.

### Caller context

AuthZ does not execute Elixir predicate functions from permission grants. When
a condition depends on Elixir-side request facts, the enforcing code computes
those facts before calling AuthZ and passes them in request context.

Examples:

- A Phoenix plug computes whether the client IP is in an allowlist and passes
  `"ip_whitelisted" => true`.
- A Gateway handler computes whether a channel is open and passes
  `"channel_open" => true`.
- A Capability controller computes whether an approval is present and passes
  `"approval_granted" => true`.

Caller context is normalized into Cedar-compatible data and exposed under
`context.request`. The first implementation accepts booleans, strings, signed
64-bit integers, lists, and maps with atom or string keys. Atom keys are
stringified recursively. `nil`, floats, structs, PIDs, tuples, functions, and
other BEAM terms make the request invalid.

A missing or wrongly typed context field causes Cedar evaluation to fail closed
for that grant. This is not invalid persisted data by itself; the condition may
be valid for another enforcement path with a different context contract.

Each enforcement point that relies on Cedar request context must document the
context keys and value types it supplies. AuthZ normalizes and exposes caller
facts under `context.request`, but it does not infer subsystem-specific facts.

### Failure semantics

Grant condition evaluation fails closed:

- Cedar parse error -> grant does not allow.
- Cedar evaluation error -> grant does not allow.
- Cedar result is not boolean -> grant does not allow.
- Cedar decision `Allow` -> `{:ok, true}`.
- Cedar decision `Deny` with no evaluation error -> `{:ok, false}`.

Runtime invalid persisted conditions must emit `Logger.error/1` and telemetry
event `[:bullx, :authz, :invalid_persisted_data]`.

Measurements:

```elixir
%{count: 1}
```

Metadata:

```elixir
%{
  kind: :condition,
  id: Ecto.UUID.t(),
  action: String.t(),
  resource_pattern: String.t(),
  reason: term()
}
```

The event is for persisted data that write-time validation was expected to
reject but runtime still encounters. It must not be emitted for ordinary
authorization denials or valid Cedar conditions that evaluate to deny.

## Data model

All UUID primary keys use:

```elixir
@primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
```

Migrations must not add PostgreSQL-side UUID defaults such as
`gen_random_uuid()`.

### `principal_groups`

Columns:

- `id`: UUIDv7 primary key.
- `name`: required lowercase group key, globally unique.
- `description`: nullable text.
- `built_in`: required boolean, default `false`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Constraints and indexes:

- unique index on `name`;
- check constraint that `name <> ''`;
- check constraint that `name = lower(name)`;
- `name` is immutable through public update APIs;
- `built_in` is system-owned and cannot be changed through public create/update
  APIs;
- public delete rejects groups that still own permission grants with
  `{:error, :group_has_grants}`.

### `principal_group_memberships`

Columns:

- `principal_id`: foreign key to `principals.id`.
- `group_id`: foreign key to `principal_groups.id`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Constraints and indexes:

- composite primary key on `{principal_id, group_id}`;
- cascade delete when the Principal or group is deleted.

### `permission_grants`

Columns:

- `id`: UUIDv7 primary key.
- `principal_id`: nullable foreign key to `principals.id`.
- `group_id`: nullable foreign key to `principal_groups.id`.
- `resource_pattern`: required non-empty text.
- `action`: required non-empty text that must not contain `:`.
- `condition`: required Cedar boolean expression string, default `true`.
- `description`: nullable text.
- `metadata`: required JSONB object, default `{}`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Constraints and indexes:

- exactly one of `principal_id` or `group_id` is non-null;
- `resource_pattern` contains at most one `*`;
- `action` does not contain `:`;
- `metadata` is a JSON object;
- indexes on `principal_id`, `group_id`, and `action`;
- foreign keys cascade when the Principal or group is deleted. Public group
  deletion rejects groups with grants before the database cascade can remove
  permission rows.

The schema validates that `condition` parses as a Cedar boolean expression.

## Runtime and operations

The first implementation does not add an AuthZ supervisor or long-lived AuthZ
cache process. Authorization reads durable rows from PostgreSQL and evaluates
conditions synchronously. This keeps cache invalidation out of the first design
and avoids a new failure boundary.

`BullX.AuthZ.Bootstrap` is the only new OTP child. It is a one-shot transient
worker mounted after `BullX.Principals.Bootstrap` in `BullX.Application`. If
AuthZ tables do not exist yet, it logs a warning and exits normally so early
setup can still run migrations. Database errors after tables exist surface as
worker failures.

No process-local AuthZ state is durable truth. A later cache design may add
decision caching through `BullX.Cache`, but that design must include cache keys,
context hashing, invalidation rules, and multi-instance behavior.

## Public API shape

The public facade is `BullX.AuthZ`. Internal modules may live under
`BullX.AuthZ`, but Web, Gateway, Runtime, Capability, Agent, and setup code call
the facade rather than composing schemas directly.

AuthZ facade mutation functions do not self-authorize. They are domain
commands. Callers that expose group or grant mutation to a Human, Agent, API
token, or setup flow must authorize the acting Principal before invoking the
mutation command.

Enforcement code calls `authorize/4` when the failure reason matters.
`allowed?/4` is for convenience and UI gating.

Expected facade functions:

```elixir
@spec authorize(BullX.Principals.Principal.t() | Ecto.UUID.t(), String.t(), String.t()) ::
        :ok | {:error, :forbidden | :not_found | :principal_disabled | :invalid_request}

@spec authorize(BullX.Principals.Principal.t() | Ecto.UUID.t(), String.t(), String.t(), map()) ::
        :ok | {:error, :forbidden | :not_found | :principal_disabled | :invalid_request}

@spec authorize_permission(BullX.Principals.Principal.t() | Ecto.UUID.t(), String.t()) ::
        :ok | {:error, :forbidden | :not_found | :principal_disabled | :invalid_request}

@spec authorize_permission(BullX.Principals.Principal.t() | Ecto.UUID.t(), String.t(), map()) ::
        :ok | {:error, :forbidden | :not_found | :principal_disabled | :invalid_request}

@spec allowed?(BullX.Principals.Principal.t() | Ecto.UUID.t(), String.t(), String.t()) ::
        boolean()

@spec allowed?(BullX.Principals.Principal.t() | Ecto.UUID.t(), String.t(), String.t(), map()) ::
        boolean()

@spec list_principal_groups(BullX.Principals.Principal.t() | Ecto.UUID.t()) ::
        {:ok, [BullX.AuthZ.PrincipalGroup.t()]} | {:error, :not_found | :invalid_request}

@spec create_principal_group(map()) ::
        {:ok, BullX.AuthZ.PrincipalGroup.t()} | {:error, Ecto.Changeset.t()}

@spec update_principal_group(BullX.AuthZ.PrincipalGroup.t() | Ecto.UUID.t(), map()) ::
        {:ok, BullX.AuthZ.PrincipalGroup.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}

@spec delete_principal_group(BullX.AuthZ.PrincipalGroup.t() | Ecto.UUID.t()) ::
        :ok | {:error, :not_found | :built_in_group | :group_has_grants}

@spec add_principal_to_group(
        BullX.Principals.Principal.t() | Ecto.UUID.t(),
        BullX.AuthZ.PrincipalGroup.t() | Ecto.UUID.t()
      ) :: :ok | {:error, :not_found | :invalid_request}

@spec remove_principal_from_group(
        BullX.Principals.Principal.t() | Ecto.UUID.t(),
        BullX.AuthZ.PrincipalGroup.t() | Ecto.UUID.t()
      ) :: :ok | {:error, :not_found | :last_admin_member | :last_active_human_admin}

@spec create_permission_grant(map()) ::
        {:ok, BullX.AuthZ.PermissionGrant.t()} | {:error, Ecto.Changeset.t()}

@spec update_permission_grant(BullX.AuthZ.PermissionGrant.t() | Ecto.UUID.t(), map()) ::
        {:ok, BullX.AuthZ.PermissionGrant.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}

@spec delete_permission_grant(BullX.AuthZ.PermissionGrant.t() | Ecto.UUID.t()) ::
        :ok | {:error, :not_found}

@spec ensure_can_disable_principal(BullX.Principals.Principal.t() | Ecto.UUID.t()) ::
        :ok | {:error, :not_found | :invalid_request | :last_active_human_admin}

@spec reconcile_bootstrap_admin_membership() :: :ok | {:error, term()}
```

`authorize/3`, `authorize_permission/2`, and `allowed?/3` use empty context
`%{}`. `allowed?/3` and `allowed?/4` return `false` for every error.
`list_principal_groups/1` and `add_principal_to_group/2` accept disabled
Principals; disabled state changes authorization decisions, not membership
introspection or static membership writes.

Schema modules:

- `BullX.AuthZ.PrincipalGroup`
- `BullX.AuthZ.PrincipalGroupMembership`
- `BullX.AuthZ.PermissionGrant`

Supporting modules:

- `BullX.AuthZ.Request`
- `BullX.AuthZ.ResourcePattern`
- `BullX.AuthZ.Cedar`
- `BullX.AuthZ.Bootstrap`

## Error and failure behavior

Validation failures return changesets from create/update APIs. Public
authorization functions return tagged errors that preserve behavior-changing
causes: `:forbidden`, `:not_found`, `:principal_disabled`, and
`:invalid_request`.

Authorization never raises for normal denial, disabled Principal state, missing
rows, malformed ids, malformed permission keys, invalid request context, Cedar
parse errors, or Cedar evaluation errors.

Bootstrap worker failures behave as follows:

- Missing AuthZ tables during early setup log a warning and exit normally.
- Missing `principals` or `activation_codes` tables log a warning and exit
  normally, because AuthZ cannot reconcile bootstrap membership before
  Principal migrations exist.
- Database errors after required tables exist surface as worker failures.
- Reconciliation inserts are idempotent through the membership primary key.

Runtime invalid persisted grant conditions log an error and emit
`[:bullx, :authz, :invalid_persisted_data]`. Normal denials do not log as data
corruption.

## Security, privacy, and governance

AuthZ controls whether a Principal may attempt an action inside a subsystem. It
does not replace Governance for risky outbound Effects. Customer-facing,
financial, legal, or otherwise risky external actions still pass through
Governance before Effects happen.

Cedar conditions receive only explicit request context and the minimal
Principal attributes `id`, `type`, and `status`. AuthZ does not expose Human
email, phone, channel metadata, Agent profile data, external identity metadata,
or secrets to Cedar by default.

Permission grant metadata is for operator context and non-secret
troubleshooting. It must not store credentials, access tokens, refresh tokens,
private keys, or plaintext activation/login codes.

`BullX.AuthZ` is the only supported mutation path for group and grant changes.
This keeps high-sensitivity writes easy for future Audit or Governance layers
to wrap, instrument, or record consistently.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| Keep the old `BullXAccounts` user-centered namespace and table names | Rejected. New BullX uses Principals as durable subjects for Humans, Agents, and future actors. |
| Put AuthZ facade functions on `BullX.Principals` | Rejected. Principal AuthN owns identity and resolution; `BullX.AuthZ` is a separate authorization boundary that consumes Principal ids. |
| Implement computed groups in the first slice | Rejected. Static groups plus caller-provided Cedar context cover the first useful policies without cycle detection, expression validation, and cache invalidation machinery. |
| Add an AuthZ-specific decision cache immediately | Rejected. PostgreSQL reads and Cedar evaluation are simpler to reason about for the first implementation. A later cache can use `BullX.Cache` after real pressure appears. |
| Make `admin` group magical | Rejected. Administrator power stays visible as ordinary grants, not hidden in special-case authorization code. |
| Add explicit deny grants | Rejected. Allow-any semantics are enough for the first framework and avoid deny-precedence bugs. |
| Store complete Cedar policies in grants | Rejected. BullX already matches subject, resource, and action; grants need only a request condition. |
| Use Elixir callbacks or module/function strings for conditions | Rejected. Runtime grant data must be data, not executable code. |

## Implementation handoff

### Goal

Implement `BullX.AuthZ` as the Principal-centered authorization framework
described in this design.

### Context pointers

- `AGENTS.md`
- `docs/design-docs/Principal.md`
- `docs/design-docs/Configuration.md`
- `docs/design-docs/Cache.md`
- `lib/bullx/principals/`
- `lib/bullx/ext.ex`
- `native/bullx_ext/`
- `priv/repo/migrations/`
- `test/support/data_case.ex`

### Constraints

- Use `BullX.AuthZ`, not `BullXAccounts`.
- Use `principals.id` for direct grant subjects and group members.
- Generate UUID primary keys through `BullX.Ecto.UUIDv7`; do not use
  database-side UUID defaults.
- Keep groups static in the first implementation.
- Reject request resource strings containing `*`; wildcard matching belongs
  only to persisted `resource_pattern` values.
- Preserve admin recoverability when Principal status or admin membership
  changes.
- Keep AuthZ mutation functions as domain commands; callers authorize acting
  Principals before invoking them.
- Do not add AuthZ-specific caches, cache processes, computed groups, explicit
  deny grants, complete Cedar policy storage, or application-specific policy
  catalogs.
- Do not expose private Principal profile fields to Cedar by default.
- Do not add a long-lived AuthZ supervisor unless a new design states the
  failure boundary.

### Tasks

1. Add AuthZ schemas and migration.
   Owns: migration, `BullX.AuthZ.PrincipalGroup`,
   `BullX.AuthZ.PrincipalGroupMembership`, `BullX.AuthZ.PermissionGrant`.
   Depends on: Principal migrations.
   Acceptance: tables, constraints, indexes, UUIDv7 schemas, and changesets
   match this design.
   Verify: focused schema tests.

2. Add request normalization and resource-pattern matching.
   Owns: `BullX.AuthZ.Request`, `BullX.AuthZ.ResourcePattern`.
   Depends on: None.
   Acceptance: malformed principals, ids, permission keys, resource/action
   values, wildcard patterns, and context values return the documented errors.
   Verify: request and pattern unit tests.

3. Add static group APIs.
   Owns: `BullX.AuthZ` facade group functions.
   Depends on: Task 1.
   Acceptance: built-in flags are protected, names are immutable, membership
   writes are idempotent where appropriate, groups with grants are not deleted,
   final admin member removal is rejected, and disabled Principals can still be
   inspected or added to groups.
   Verify: group tests.

4. Add Cedar NIF and wrapper.
   Owns: `native/bullx_ext/src/cedar.rs`, `BullX.Ext`,
   `BullX.AuthZ.Cedar`.
   Depends on: Task 2.
   Acceptance: condition validation rejects injected policies structurally,
   evaluation uses Principal-centered Cedar request data, and malformed Cedar
   fails the grant.
   Verify: Cedar wrapper and NIF tests.

5. Add permission grant APIs.
   Owns: `BullX.AuthZ` facade grant functions and
   `BullX.AuthZ.PermissionGrant`.
   Depends on: Tasks 1 and 4.
   Acceptance: grants require exactly one subject, validate resource/action
   rules, validate conditions on write, and store only JSON-object metadata.
   Verify: grant tests.

6. Implement authorization decisions.
   Owns: `BullX.AuthZ.authorize/4`, `authorize_permission/3`, and `allowed?/4`.
   Depends on: Tasks 2, 3, 4, and 5.
   Acceptance: active Principals authorize through direct or group grants,
   disabled Principals deny before grant evaluation, allow-any semantics work,
   and grant-level failures fail closed.
   Verify: authorization tests.

7. Add admin recoverability protection.
   Owns: `BullX.AuthZ.ensure_can_disable_principal/1` and the Principal status
   update plus admin membership removal paths.
   Depends on: Task 3.
   Acceptance: disabling or removing admin membership from the final active
   Human member of `admin` is rejected unless an explicit recovery path is
   added; removing the final static admin group member is rejected; Agent admin
   membership does not satisfy the active Human recovery invariant.
   Verify: Principal status and membership removal guard tests.

8. Add bootstrap admin handoff.
   Owns: `BullX.AuthZ.Bootstrap`, `BullX.Application`, and the narrow
   activation-code handoff call.
   Depends on: Tasks 1 and 3.
   Acceptance: `admin` group is seeded idempotently, consumed bootstrap
   activation codes grant Human admin membership, non-bootstrap activation
   codes do not, non-Human Principal rows are skipped, and reconciliation can
   repair a missed handoff.
   Verify: bootstrap tests.

9. Add minimal enforcement integration only where this implementation slice
   needs it.
   Owns: Web, Gateway, Runtime, Capability, or Agent code only if the current
   implementation requires an enforcement point.
   Depends on: Task 6.
   Acceptance: enforcing code resolves or loads a Principal first, computes
   request facts explicitly, and calls the `BullX.AuthZ` facade.
   Verify: focused integration tests for any touched surface.

### Done when

- AuthZ migrations and schemas match the data model.
- `BullX.AuthZ` exposes the documented facade functions.
- AuthZ authorizes active Human and Agent Principals through direct and group
  grants.
- Disabled Principals, invalid requests, missing Principals, Cedar failures, and
  invalid persisted conditions fail closed.
- Principal disable and admin membership removal flows preserve admin
  recoverability.
- Built-in `admin` group and bootstrap activation handoff work idempotently.
- Tests cover schema constraints, groups, grants, resource patterns, request
  normalization, Cedar conditions, disabled Principal behavior, bootstrap
  membership, admin recoverability protection, and any touched enforcement
  integration.
- `bun precommit` passes.

Implementation stops and asks if a change would introduce computed groups,
explicit deny semantics, a policy catalog, a private AuthZ cache, a new
Principal type, external credential storage, or Governance/Effect behavior.

## Acceptance criteria

- `BullX.AuthZ` exists as the Principal-centered authorization namespace.
- `principal_groups`, `principal_group_memberships`, and `permission_grants`
  persist the described state with UUIDv7 primary keys and PostgreSQL
  constraints.
- Human and Agent Principals can both receive direct grants and group-based
  grants.
- Disabled Principals never authorize.
- Principal disable and admin membership removal flows cannot leave the
  Installation without an active Human admin unless a future design adds an
  explicit recovery path.
- The `admin` group is built in, protected, non-magical, and populated only by
  bootstrap activation metadata or normal membership APIs.
- Subsystems that introduce AuthZ enforcement seed ordinary `admin` grants or
  document their setup/bootstrap bypass behavior.
- Authorization uses resource-pattern plus exact-action matching and allow-any
  grant semantics.
- Request resource strings cannot contain `*`; wildcard matching exists only in
  persisted `resource_pattern` values.
- Cedar conditions evaluate only after subject, resource, and action matching;
  condition failures fail closed per grant.
- Caller-provided context is normalized to Cedar-compatible data under
  `context.request`.
- Enforcement points that rely on Cedar context document their context keys and
  value types.
- AuthZ mutation functions do not self-authorize; callers authorize the acting
  Principal before invoking them.
- Public group deletion rejects groups that still own permission grants.
- AuthZ never creates, authenticates, activates, logs in, or externally binds
  Principals.
- No AuthZ-specific cache or computed-group machinery is introduced in the first
  implementation.
- `bun precommit` passes.
