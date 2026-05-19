# AuthZ

BullX AuthZ is the authorization boundary for active Principals. It decides
whether one Principal may perform one action on one resource under
caller-provided request context. The first implementation adds static Principal
groups, CEL-based computed Principal groups, Principal or group permission
grants, and CEL boolean conditions. Computed group membership is effective
state, not persisted membership rows; `all_humans` is the built-in computed group
for active Human Principals.

## Scope

This design covers the framework-level authorization surface:

- Static groups whose members are Principals.
- CEL computed groups whose effective members are derived from Principal facts.
- Group membership management for Human, Agent, and future Principal types.
- Permission grants assigned directly to Principals or to groups.
- Resource-pattern and action authorization requests.
- CEL boolean condition evaluation for request-time facts.
- Caller-provided authorization context normalization.
- Built-in `admin` and `all_humans` group seed data, plus bootstrap-admin
  membership handoff from Principal activation metadata.
- Public API shape, persistence, failure behavior, and implementation handoff.

This design intentionally does not cover:

- Principal creation, external identity binding, activation codes, login auth
  codes, Web sessions, or provider login. Those remain in
  [Principal](Principal.md).
- External Event contracts or channel actor matching.
- A BullX tenant model.
- Concrete application policy names for Web, Workflow, Skills, Brain, Workflow
  Node execution, Capability use, high-risk external actions, or AIAgent runtime
  internals.
- Explicit deny grants and deny precedence.
- Computed group dependency graphs, computed groups that depend on other groups,
  or cache invalidation for computed memberships.
- An AuthZ-specific cache process or decision cache.
- A full Web UI for group and grant administration.
- Audit-log storage. Future Audit, Workflow, Capability, or high-risk external
  action designs consume AuthZ decisions but own their own durable records.

## Goals

- Make `principals.id` the only durable authorization subject id.
- Authorize Humans and Agents through the same API without treating Agents as
  second-class user accounts.
- Keep the first framework small: static groups, CEL computed groups, grants,
  and request conditions.
- Preserve a boring allow-any model: any applicable grant whose condition
  evaluates to `true` authorizes the request.
- Fail closed for disabled Principals, malformed requests, invalid grants, and
  CEL errors.
- Store durable authorization facts in PostgreSQL with process-local state
  reconstructible after restart.
- Avoid Elixir callbacks, atoms, AST, or module/function strings inside runtime
  grant data.

## Existing system

`docs/design-docs/Principal.md` defines `principals` as the base identity table
and places Human and Agent facts in extension tables. `BullX.Principals` owns
Principal creation, external identity resolution, activation codes, bootstrap
activation, and login auth codes. Principal status is currently `active` or
`disabled`; only active Principals can act as business subjects.

AuthZ keeps the framework small: static groups, CEL computed groups,
resource/action grants, request-time conditions, fail-closed semantics, and
bootstrap admin handoff. The first implementation does not add a local decision
cache or computed group dependency graph.

The existing `BullX.Ext` NIF boundary already carries CPU-heavy native helpers.
CEL condition compilation and evaluation extend that boundary rather than
adding a second native application. A later authorization cache design uses
`BullX.Cache` instead of adding a private ETS owner process.

## Boundary with Principal AuthN

AuthZ consumes active Principals. It does not own identity, authentication, or
external binding.

AuthZ must not:

- create Principals;
- create Human or Agent extension rows;
- create channel bindings or login-subject bindings;
- issue activation codes or login auth codes;
- establish Web sessions;
- infer a Principal from an external actor;
- authorize a disabled Principal.

Callers that start from a channel actor first call
`BullX.Principals.resolve_channel_actor/3` or another Principal AuthN facade
function. Callers that start from a Web session reload the durable Principal id
from PostgreSQL. Runtime code that starts from an Agent uses the Agent's
Principal id. After a current active Principal is available, callers ask AuthZ
for authorization.

Disabled Principals are denied before group lookup, grant lookup, or CEL
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
  resource: "workspace_channel:main",
  action: "write",
  context: %{"adapter" => "chat"}
}
```

`resource` and `action` are non-empty strings. `resource` must not contain glob
wildcard metacharacters such as `*`, `?`, character classes, or alternates.
Wildcard meaning exists only inside persisted `resource_pattern` values.
`action` must not contain `:`, because permission keys split at the final `:`.
AuthZ never converts caller-provided resource, action, or context values to
atoms.

The public API accepts separate resource and action values, or a permission key:

```elixir
BullX.AuthZ.authorize(principal, "web_console", "read")
BullX.AuthZ.authorize(principal.id, "workspace_channel:main", "write", %{})
BullX.AuthZ.authorize_permission(principal, "workspace_channel:main:write", %{})
```

Permission keys split at the final `:`. Everything before it is the resource;
everything after it is the action. This allows resource names such as
`workspace_channel:<channel_id>` without adding ARN syntax.

### Resource and action naming

AuthZ does not define a full policy catalog, but subsystems use a consistent
resource naming shape:

- `<domain>`
- `<domain>:<id>`
- `<domain>:<id>:<child>`

Examples:

- `web_console`
- `workspace_channel:<channel_id>`
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
- `workspace_channel:<channel_id>:write`
- `workspace_channel:general:write`
- `capability:browser_use:execute`

`resource_pattern` uses a Rust `globset`-backed resource glob. A pattern without
glob metacharacters matches exact string equality. BullX normalizes `:` as the
resource hierarchy separator before matching. `*` and `?` match within one
resource segment; recursive `**` patterns may cross segment boundaries. For
example, `workspace:*` matches `workspace:team`, while
`workspace:**:member` can match `workspace:team:channel:member`. Character
classes and alternates follow `globset` syntax. Grant writes reject empty or
invalid glob patterns. Request resources are still literal resource strings and
must not contain wildcards.

Actions match exactly. `write` does not imply `read`. If a subsystem wants both
actions, it creates both grants.

### Decision flow

`BullX.AuthZ.authorize/4` follows this order:

1. Normalize the request.
2. Load the current Principal from PostgreSQL when the caller passes an id or
   stale struct.
3. Return `{:error, :not_found}` if the Principal is missing.
4. Return `{:error, :principal_disabled}` if the Principal is disabled.
5. Load the Principal's static groups and evaluate computed groups.
6. Fetch grants assigned directly to the Principal or to any group, narrowed by
   exact action.
7. Build the AuthZ CEL evaluation environment and loaded-grant list.
8. Call the Rust NIF once to evaluate the loaded grants. The NIF filters
   resource patterns, registers CEL variables/functions, evaluates grant
   conditions, and returns allow/deny plus safe diagnostics.
9. Return `:ok` if the NIF returns allow.
10. Return `{:error, :forbidden}` when no loaded grant allows the request.

Grant-level evaluation errors affect only that grant. They do not crash the
authorization request and do not authorize the request.

Elixir and PostgreSQL own Principal lookup, group lookup, subject filtering,
and action filtering before the Rust decision call. The Rust NIF receives grants
that are already subject-matched and action-matched; it does not re-implement
Principal, group, or action lookup.

Rust may evaluate matching loaded grants in any order. Grant ordering has no
business meaning, and grants have no priority in this design.

Nil Principals, malformed Principal ids, empty resource strings, empty action
strings, resources containing `*`, actions containing `:`, invalid permission
keys, and non-CEL-compatible contexts return `{:error, :invalid_request}`.
Well-formed ids that do not identify a Principal return `{:error, :not_found}`.

## Groups

Groups are named sets of Principals. The first implementation supports static
groups and CEL-based computed groups.

`principal_groups.name` is the stable group key. It is globally unique,
lowercase, and immutable after insert. `kind` is a native PostgreSQL enum with
values `static` and `computed`, and is immutable after insert. `built_in` marks
groups created by BullX. Public create/update APIs cannot set or clear
`built_in`.

`principal_group_memberships` stores static membership only. A static group can
contain any active or disabled Principal type. Disabled Principals may remain
members so operators can preserve administrative intent while the Principal is
locked, but authorization still denies them before group lookup matters.

Computed group membership is derived from the group's `computed_condition` CEL
expression and is never written to `principal_group_memberships`.

`list_principal_groups/1` loads existing Principals regardless of status and
returns effective group membership: static membership plus computed groups whose
conditions evaluate to `true`. Disabled status affects authorization decisions,
not membership introspection. `add_principal_to_group/2` also accepts disabled
Principals so operators can prepare or preserve membership while a Principal is
locked.

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

Admin recoverability checks and the corresponding membership removal or
Principal disable write must run in one database transaction. The implementation
must lock the relevant admin group membership and Principal rows, or use an
equivalent serializable transaction strategy, so concurrent removals or disables
cannot bypass the last-active-Human-admin invariant.

Computed group conditions use the same shared CEL runtime as grant conditions,
but they run in a smaller environment. The top-level variables are:

- `principal`, with string fields `id`, `type`, and `status`.

Computed group conditions do not receive `resource`, `action`, caller-provided
`context.request`, Human profile fields, Agent profile fields, external identity
metadata, or credentials. A computed group decides whether a Principal is an
effective member of the group, not whether one request is authorized.

The first implementation does not allow computed groups to reference static
groups, computed groups, or permission grants. This avoids dependency graphs,
cycles, and cache invalidation rules while still restoring the durable computed
group concept. A future design may add group-reference facts if a concrete
policy needs them.

Write-time validation compiles `computed_condition` as CEL. With the current
`cel` crate API, compile validation does not prove the expression returns a
boolean. Runtime compile errors, execution errors, and non-boolean results make
that computed group evaluate to `false` for the current Principal and emit
invalid-persisted-data telemetry.

Static group membership APIs reject adding or removing members for computed
groups with `{:error, :computed_group}`.

The built-in `all_humans` group is a computed group:

- AuthZ bootstrap creates a `principal_groups` row with `name = "all_humans"`,
  `kind = "computed"`, `built_in = true`, and:

  ```cel
  principal.type == "human" && principal.status == "active"
  ```

  so permission grants can target it.
- Active Human Principals are effective members without
  `principal_group_memberships` rows.
- Disabled Human Principals, Agent Principals, Service Principals, System
  Principals, and unknown Principal types are not effective members.
- Public membership APIs reject adding or removing members for `all_humans`
  with `{:error, :computed_group}`.
- `list_principal_groups/1` includes `all_humans` for active Human Principals
  and omits it for everyone else.
- `all_humans` receives no magical authorization behavior. It authorizes only
  through ordinary permission grants assigned to the group.

`all_humans` is not a setup-local allowlist, provider audience, or channel
allowlist. It is ordinary computed group data owned by AuthZ.

This design seeds the built-in `admin` and `all_humans` groups, plus bootstrap
admin membership only. It does not create a universal action wildcard. Any
subsystem that introduces an AuthZ enforcement point must either seed ordinary
grants for the built-in groups it expects setup/bootstrap to use, or explicitly
document why setup/bootstrap remains outside AuthZ until those grants exist.

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
2. Creates the built-in `admin` and `all_humans` groups if missing.
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

After applicability is established, AuthZ evaluates the CEL `condition`
expression. `condition = "true"` is unconditional after subject, resource, and
action matching. Empty conditions are invalid.

Multiple grants use allow-any semantics. AuthZ has no explicit deny grant and
no grant priority in the first implementation.

Public group deletion rejects deleting a group that still has permission grants
with `{:error, :group_has_grants}`. Callers must delete or move grants first so
operators do not lose permissions as an incidental side effect of group cleanup.
Membership rows may be deleted with the group.

## CEL conditions

BullX permission grants store one CEL boolean expression. AuthZ loads candidate
grants by subject and action; the Rust decision call matches `resource_pattern`
before evaluating `condition`. `condition` is only a request-time predicate:

```cel
principal.type == "human" && context.request.ip_whitelisted
```

`condition` is parsed and executed by CEL. BullX never interprets it as Elixir
code, never wraps it in a larger policy document, and never interpolates request
data into expression source.

AuthZ uses the shared rule-engine CEL support for expression compilation and
JSON-compatible input conversion. Shared Elixir wrappers live in
`BullX.RuleEngine.CEL` and `BullX.RuleEngine.JSON`; shared Rust CEL utilities
live under `native/bullx_ext/src/rule_engine/cel.rs`. AuthZ-specific grant
decision and computed-group logic lives in `BullX.AuthZ.CEL` and
`native/bullx_ext/src/rule_engine/authz.rs`, and calls NIF shims exposed from
`BullX.Ext`:

```elixir
@spec validate_condition(String.t()) :: :ok | {:error, String.t()}

@spec evaluate_grants(BullX.AuthZ.CEL.Env.t(), [BullX.AuthZ.CEL.LoadedGrant.t()]) ::
        {:allow, [BullX.AuthZ.CEL.InvalidGrant.t()]}
        | {:deny, [BullX.AuthZ.CEL.InvalidGrant.t()]}
        | {:error, String.t()}

@spec evaluate_computed_groups(
        BullX.AuthZ.CEL.PrincipalEnv.t(),
        [BullX.AuthZ.CEL.LoadedComputedGroup.t()]
      ) ::
        {:ok, [Ecto.UUID.t()], [BullX.AuthZ.CEL.InvalidComputedGroup.t()]}
        | {:error, String.t()}
```

The NIF code lives inside the existing `native/bullx_ext` Rustler crate. The
first implementation uses the `cel` crate from `cel-rust/cel-rust` inside that
rule-engine NIF boundary. Do not create a second native application or a second
Rustler crate for CEL.

`BullX.Ext` is allowed to own this deterministic AuthZ decision slice. It is
not limited to small utility functions. The boundary is acceptable because Rust
receives all durable facts as explicit arguments and performs no cross-language
side effects: no PostgreSQL access, network calls, wall-clock reads, random
sources, process messaging, or secret reads.

The minimal NIF boundary structs are:

```elixir
%BullX.AuthZ.CEL.Env{
  principal: %{
    "id" => principal_id,
    "type" => Atom.to_string(principal.type),
    "status" => "active"
  },
  action: action,
  resource: resource,
  context: %{"request" => caller_context}
}

%BullX.AuthZ.CEL.LoadedGrant{
  id: grant_id,
  resource_pattern: resource_pattern,
  condition: condition
}

%BullX.AuthZ.CEL.InvalidGrant{
  id: grant_id,
  kind:
    :resource_pattern
    | :condition_compile
    | :condition_execution
    | :condition_result_type,
  resource_pattern: resource_pattern,
  reason: reason
}

%BullX.AuthZ.CEL.PrincipalEnv{
  principal: %{
    "id" => principal_id,
    "type" => Atom.to_string(principal.type),
    "status" => Atom.to_string(principal.status)
  }
}

%BullX.AuthZ.CEL.LoadedComputedGroup{
  id: group_id,
  condition: computed_condition
}

%BullX.AuthZ.CEL.InvalidComputedGroup{
  id: group_id,
  kind:
    :condition_compile
    | :condition_execution
    | :condition_result_type,
  reason: reason
}
```

`BullX.AuthZ.authorize/4` loads the current Principal before condition
evaluation and builds this explicit evaluation environment. The NIF must not
query PostgreSQL, infer Principal attributes from `principal_id`, or filter by
subject or action.

There are no `BullXPrincipal`, `BullXAction`, or `BullXResource` entity
wrappers. The CEL wrapper constructs `Context::default()` and registers exactly
these top-level variables:

- `principal` for both computed group conditions and grant conditions;
- `action`, `resource`, and `context` only for grant conditions.

The wrapper must not expose the whole request under an implicit root object. If
BullX later wants that shape, the condition syntax must change to
`request.principal...`.

With the current `cel` crate API, `Program::compile(source)` parses and
constructs a `Program`; it does not prove that the result type is boolean.
`validate_condition/1` is v1 write-time syntax/compile validation only.
Unknown variables, missing functions, wrong argument types, and wrong result
types may fail at runtime and fail closed for that grant. Expressions such as
`"hello"`, `123`, `principal.id`, and `context.request.some_map` may compile and
must fail closed when evaluation returns a non-boolean value.

`evaluate_computed_groups/2` receives the already-built
`BullX.AuthZ.CEL.PrincipalEnv` struct and a list of computed group ids and
conditions. Elixir must not call a generic CEL evaluator once per computed
group. The Rust function evaluates each computed group condition against only
the Principal environment, returns matching group ids, and returns invalid
computed-group diagnostics for malformed persisted rows.

`evaluate_grants/2` receives the already-built `BullX.AuthZ.CEL.Env` struct and
a list of loaded grants. Elixir must not call a generic CEL evaluator once per
grant. The Rust function owns runtime resource-glob matching and CEL condition
evaluation in the same loaded-grant decision call. Write-time validation may
call the Rust resource-glob validator for operator feedback, but authorization
runtime must not return to Elixir for per-grant glob matching.

Rust resource-pattern tests must cover exact matches, `*`, valid recursive `**`
patterns over `:`-separated resource strings, invalid glob syntax, and the fact
that non-matching resource globs skip CEL evaluation for that grant.

The Rust function then owns the runtime decision loop:

1. Filter each loaded grant by `resource_pattern` against the request resource.
2. Construct one `Context::default()` for the request environment.
3. Register the documented top-level variables and AuthZ function registry.
4. Compile and execute each matching grant's CEL condition.
5. Short-circuit on the first boolean `true`.
6. Return `:deny` plus invalid-grant diagnostics when no matching grant allows.

Top-level `{:error, reason}` is reserved for malformed evaluation input that
prevents the NIF from constructing or running the AuthZ decision at all.
Grant-level CEL compile errors, CEL execution errors, non-boolean CEL results,
and invalid stored resource patterns are reported as `InvalidGrant`
diagnostics. Grant-level failures fail closed for that grant only and do not
make the whole authorization request invalid. `BullX.AuthZ.authorize/4` still
returns `:ok` only on allow and `{:error, :forbidden}` when no grant allows.

Allow-any short-circuiting is permitted. If Rust returns allow before evaluating
later grants, AuthZ is not required to scan unevaluated grants just to discover
invalid persisted data.

If runtime caching becomes necessary, a separate cache design must define cached
program keys, invalidation, function registry versioning, and multi-instance
behavior.

The default Principal attributes intentionally exclude email, phone, channel
metadata, group names, Agent profile fields, and other profile data. Callers
that need profile-sensitive policy compute an explicit, approved fact and pass
that fact through `context.request`.

Grant writes validate `condition` through the CEL wrapper before insert or
update. The wrapper only needs expression compilation. It does not inspect
synthetic policy envelopes, because CEL stores no policy document for an
attacker to extend.

Rule-engine CEL NIFs run on the dirty CPU scheduler. They return ordinary
values or `{:error, String.t()}` and must not panic on malformed expressions or
malformed request maps.

AuthZ and EventBus may both use shared CEL support and Rust-owned decision
logic, but they are different business surfaces. EventBus matcher owns route
table snapshots, rule priority, target selection, and TargetSession handoff.
AuthZ owns a loaded-grant decision over subject, action, resource pattern, and
request facts. AuthZ must not reuse EventBus `RoutingContext`, target
semantics, priority semantics, Blackhole behavior, or session/window logic.

CEL's standard function names are not Elixir names. For example, CEL has
`endsWith`, not `ends_with`, and it has no built-in `in_cidr` operator. When an
AuthZ enforcement path needs a domain function, `BullX.AuthZ.CEL` registers it
explicitly through `context.add_function(...)`. V1 write-time validation remains
syntax/compile validation only; unknown custom functions, missing functions, and
wrong function argument types may fail at runtime and fail closed for that
grant.

Registered AuthZ CEL functions must be deterministic, side-effect-free, bounded
in CPU and memory, and independent of wall-clock time, random sources,
PostgreSQL, network calls, process state, and secrets. When a condition depends
on time, request location, or policy state, the caller passes an explicit fact
such as `"now"`, `"ip_whitelisted"`, or `"within_business_hours"` through
`context.request`. EventBus matcher functions and AuthZ functions are
registered independently.

### Caller context

AuthZ does not execute Elixir predicate functions from permission grants. When
a condition depends on Elixir-side request facts, the enforcing code computes
those facts before calling AuthZ and passes them in request context.

Examples:

- A Phoenix plug computes whether the client IP is in an allowlist and passes
  `"ip_whitelisted" => true`.
- A transport handler computes whether a channel is open and passes
  `"channel_open" => true`.
- A Capability controller computes whether an approval is present and passes
  `"approval_granted" => true`.

A caller context is normalized into CEL-compatible data and exposed under
`context.request`. The CEL implementation intentionally accepts JSON-compatible
values: booleans, strings, signed 64-bit integers, finite floats, `nil`, lists,
and maps with atom or string keys. CEL has distinct numeric types; conditions
must use explicit conversions when they mix integers, unsigned integers, and
doubles.

Atom keys are stringified recursively. Structs, PIDs, tuples, functions, atoms
as values, and other BEAM terms make the request invalid.

CEL dot access is suitable only for identifier-shaped map keys. Enforcement
points should use CEL identifier-compatible `snake_case` context keys when they
intend dot access such as `context.request.ip_whitelisted`. Keys containing
`-`, `.`, spaces, or leading digits remain accessible through map index syntax,
such as `context.request["ip-whitelisted"]`.

A missing or wrongly typed context field that is required to determine the CEL
result causes an execution error, and execution errors fail closed for that
grant. CEL logical operators and macros have standard CEL error-absorption
semantics, so enforcement-point docs and tests must cover missing-field
behavior explicitly. Conditions should use `has(...)` or map-presence checks to
guard optional context fields.

Each enforcement point that relies on CEL request context must document the
context keys and value types it supplies. AuthZ normalizes and exposes caller
facts under `context.request`, but it does not infer subsystem-specific facts.

### Failure semantics

Grant condition evaluation fails closed:

- Invalid stored resource pattern -> grant does not allow.
- CEL compile error -> grant does not allow.
- CEL execution error -> grant does not allow.
- CEL result is not boolean -> grant does not allow.
- CEL result `true` -> grant allows.
- CEL result `false` -> grant does not allow.

CEL compile errors in persisted computed group conditions or grant conditions,
non-boolean condition results, and invalid stored resource patterns may emit
`Logger.error/1` and telemetry event
`[:bullx, :authz, :invalid_persisted_data]`.

CEL execution errors caused by missing or wrongly typed caller context fields
fail closed for that grant but are not emitted as invalid persisted data by
default. Normal denials and valid conditions evaluating to `false` do not emit
this telemetry.

Measurements:

```elixir
%{count: 1}
```

Metadata:

```elixir
%{
  kind:
    :computed_group_condition_compile
    | :computed_group_condition_execution
    | :computed_group_condition_result_type
    | :resource_pattern
    | :condition_compile
    | :condition_result_type,
  id: Ecto.UUID.t(),
  action: String.t() | nil,
  resource_pattern: String.t() | nil,
  reason: term()
}
```

The event is for persisted data that write-time validation was expected to
reject but runtime still encounters. Allow-any short-circuiting means AuthZ may
return allow without discovering invalid persisted data in later unevaluated
grants.

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
- `kind`: native PostgreSQL enum `principal_group_kind` with values `static` and
  `computed`, default `static`.
- `description`: nullable text.
- `computed_condition`: nullable CEL expression string expected to evaluate to
  boolean.
- `built_in`: required boolean, default `false`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Constraints and indexes:

- unique index on `name`;
- check constraint that `name <> ''`;
- check constraint that `name = lower(name)`;
- `kind = 'static'` requires `computed_condition IS NULL`;
- `kind = 'computed'` requires non-empty `computed_condition`;
- `name` and `kind` are immutable through public update APIs;
- `built_in` is system-owned and cannot be changed through public create/update
  APIs;
- public delete rejects groups that still own permission grants with
  `{:error, :group_has_grants}`.

The schema validates `computed_condition` through the shared CEL wrapper for
computed groups. With the current `cel` crate API, write-time validation does
not prove the expression returns a boolean.

### `principal_group_memberships`

Columns:

- `principal_id`: foreign key to `principals.id`.
- `group_id`: foreign key to `principal_groups.id`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Constraints and indexes:

- composite primary key on `{principal_id, group_id}`;
- cascade delete when the Principal or group is deleted.

This table stores static memberships only. Public AuthZ membership APIs reject
attempts to add or remove membership for computed groups. Direct database writes
that insert membership rows for computed groups are out-of-contract; effective
membership is computed at read time.

### `permission_grants`

Columns:

- `id`: UUIDv7 primary key.
- `principal_id`: nullable foreign key to `principals.id`.
- `group_id`: nullable foreign key to `principal_groups.id`.
- `resource_pattern`: required non-empty text.
- `action`: required non-empty text that must not contain `:`.
- `condition`: required CEL expression string expected to evaluate to boolean,
  default `true`.
- `description`: nullable text.
- `metadata`: required JSONB object, default `{}`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Constraints and indexes:

- exactly one of `principal_id` or `group_id` is non-null;
- `resource_pattern` is non-empty and must pass Rust resource-glob validation;
- `action` does not contain `:`;
- `metadata` is a JSON object;
- indexes on `principal_id`, `group_id`, and `action`;
- partial unique index on
  `(principal_id, resource_pattern, action, condition)` where `principal_id IS
  NOT NULL`, for idempotent Principal grant upsert;
- partial unique index on `(group_id, resource_pattern, action, condition)`
  where `group_id IS NOT NULL`, for idempotent group grant upsert;
- foreign keys cascade when the Principal or group is deleted. Public group
  deletion rejects groups with grants before the database cascade can remove
  permission rows.

The schema validates that `condition` compiles as a CEL expression. With the
current `cel` crate API, write-time validation does not prove the expression
returns a boolean.

## Runtime and operations

The first implementation does not add an AuthZ supervisor or long-lived AuthZ
cache process. Authorization reads durable rows from PostgreSQL and evaluates
loaded grants synchronously through one Rust NIF decision call. This keeps cache
invalidation out of the first design and avoids a new failure boundary.

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
`BullX.AuthZ`, but Web, Runtime, Capability, AIAgent, and setup code call
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
      ) :: :ok | {:error, :not_found | :invalid_request | :computed_group}

@spec remove_principal_from_group(
        BullX.Principals.Principal.t() | Ecto.UUID.t(),
        BullX.AuthZ.PrincipalGroup.t() | Ecto.UUID.t()
      ) ::
        :ok
        | {:error, :not_found | :last_admin_member | :last_active_human_admin | :computed_group}

@spec create_permission_grant(map()) ::
        {:ok, BullX.AuthZ.PermissionGrant.t()} | {:error, Ecto.Changeset.t()}

@spec upsert_permission_grant(map()) ::
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
introspection or static membership writes. Static membership writes reject
computed groups with `{:error, :computed_group}`.

Schema modules:

- `BullX.AuthZ.PrincipalGroup`
- `BullX.AuthZ.PrincipalGroupMembership`
- `BullX.AuthZ.PermissionGrant`

Supporting modules:

- `BullX.AuthZ.Request`
- `BullX.AuthZ.ResourcePattern`
- `BullX.AuthZ.CEL`
- `BullX.AuthZ.Bootstrap`

## Error and failure behavior

Validation failures return changesets from create/update APIs. Public
authorization functions return tagged errors that preserve behavior-changing
causes: `:forbidden`, `:not_found`, `:principal_disabled`, and
`:invalid_request`.

Authorization never raises for normal denial, disabled Principal state, missing
rows, malformed ids, malformed permission keys, invalid request context, CEL
compile errors, or CEL execution errors.

Bootstrap worker failures behave as follows:

- Missing AuthZ tables during early setup log a warning and exit normally.
- Missing `principals` or `activation_codes` tables log a warning and exit
  normally, because AuthZ cannot reconcile bootstrap membership before
  Principal migrations exist.
- Database errors after required tables exist surface as worker failures.
- Reconciliation inserts are idempotent through the membership primary key.

Runtime invalid persisted grant conditions log an error and emit
`[:bullx, :authz, :invalid_persisted_data]`; invalid persisted computed group
conditions do the same and make that computed group evaluate to `false`. Normal
denials do not log as data corruption. Missing or wrongly typed caller context
fields fail closed for the affected grant but are not invalid-persisted-data
telemetry by default.

## Security, privacy, and governance

AuthZ controls whether a Principal may attempt an action inside a subsystem. It
does not replace explicit approval or policy gates for risky external side
effects. Customer-facing, financial, legal, or otherwise risky external actions
should pass through the approval or policy path defined by the owning Target,
Workflow, Capability, or Governance design before the side effect executes.

Computed group CEL conditions receive only the minimal Principal attributes
`id`, `type`, and `status`. Permission grant CEL conditions additionally receive
explicit caller-provided request context under `context.request`, plus request
`resource` and `action`. AuthZ does not expose Human email, phone, channel
metadata, Agent profile data, external identity metadata, or secrets to CEL by
default.

Permission grant metadata is for operator context and non-secret
troubleshooting. It must not store credentials, access tokens, refresh tokens,
private keys, or plaintext activation/login codes.

`BullX.AuthZ` is the only supported mutation path for group and grant changes.
This keeps high-sensitivity writes easy for future Audit, Workflow, or operator
review layers to wrap, instrument, or record consistently.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| Keep the `BullXAccounts` user-centered namespace and table names | Rejected. New BullX uses Principals as durable subjects for Humans, Agents, and future Principal types. |
| Put AuthZ facade functions on `BullX.Principals` | Rejected. Principal AuthN owns identity and resolution; `BullX.AuthZ` is a separate authorization boundary that consumes Principal ids. |
| Restore the legacy JSON computed-group expression language | Rejected. CEL is now the shared rule expression boundary for AuthZ and EventBus-adjacent code, so computed groups use CEL instead of a second JSON DSL. |
| Let computed groups depend on other groups | Rejected. The first Principal-derived computed groups cover `all_humans` without cycles, dependency validation, or invalidation machinery. |
| Add an AuthZ-specific decision cache immediately | Rejected. PostgreSQL reads and CEL evaluation are simpler to reason about for the first implementation. A later cache can use `BullX.Cache` after real pressure appears. |
| Make `admin` group magical | Rejected. Administrator power stays visible as ordinary grants, not hidden in special-case authorization code. |
| Add explicit deny grants | Rejected. Allow-any semantics are enough for the first framework and avoid deny-precedence bugs. |
| Keep Cedar and synthetic permit policy wrapping | Rejected. AuthZ already matches subject, resource, and action; CEL avoids synthetic policy construction, Cedar entity construction, and structural policy-envelope validation. |
| Reuse the EventBus matcher runtime directly | Rejected. EventBus matcher is a route-table and TargetSession handoff boundary. AuthZ needs a separate loaded-grant decision call over subject-filtered grants, resource patterns, action, and request facts. |
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
- `docs/design-docs/eventbus/Matcher.md`
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
- Keep computed groups Principal-derived in the first implementation; do not let
  computed groups depend on request context, other groups, permission grants, or
  external identity records.
- Reject request resource strings containing wildcard metacharacters; glob
  matching belongs only to persisted `resource_pattern` values.
- Preserve admin recoverability when Principal status or admin membership
  changes.
- Keep AuthZ mutation functions as domain commands; callers authorize acting
  Principals before invoking them.
- Do not add AuthZ-specific caches, cache processes, explicit deny grants,
  complete policy storage, or application-specific policy catalogs.
- Do not expose private Principal profile fields to CEL by default.
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

2. Add request normalization and resource-pattern validation.
   Owns: `BullX.AuthZ.Request`, `BullX.AuthZ.ResourcePattern`.
   Depends on: None.
   Acceptance: malformed principals, ids, permission keys, resource/action
   values, wildcard patterns, and context values return the documented errors.
   Runtime resource-pattern matching belongs to the Rust decision call in
   Task 4 and must satisfy the same semantics as the Elixir validation/test
   support.
   Verify: request and pattern unit tests.

3. Add group APIs and computed groups.
   Owns: `BullX.AuthZ` facade group functions.
   Depends on: Task 1.
   Acceptance: built-in flags are protected, names are immutable, membership
   writes are idempotent where appropriate, groups with grants are not deleted,
   final admin member removal is rejected, and disabled Principals can still be
   inspected or added to static groups; computed group conditions are validated
   on write; computed groups cannot receive manual membership edits;
   `all_humans` is seeded as a built-in computed group and appears as an
   effective group only for active Human Principals.
   Verify: group tests.

4. Add CEL NIF and wrapper.
   Owns: shared `native/bullx_ext/src/rule_engine/cel.rs`,
   AuthZ-specific `native/bullx_ext/src/rule_engine/authz.rs`,
   `BullX.RuleEngine.CEL`, `BullX.RuleEngine.JSON`, `BullX.Ext`, and
   `BullX.AuthZ.CEL`; removes `native/bullx_ext/src/cedar.rs`,
   `BullX.AuthZ.Cedar`, and the `cedar-policy` dependency when no caller
   remains.
   Depends on: Task 2.
   Acceptance: condition validation compiles CEL expressions with the chosen
   shared rule-engine CEL runtime; computed group evaluation uses one Rust call
   over loaded computed groups; grant evaluation uses one Rust decision call,
   registers only the documented top-level variables, performs resource-pattern
   matching, reports computed-group and grant-level diagnostics, runs on the
   dirty CPU scheduler, and fails closed for malformed CEL and non-boolean
   results.
   Verify: CEL wrapper and NIF tests.

5. Add permission grant APIs.
   Owns: `BullX.AuthZ` facade grant functions and
   `BullX.AuthZ.PermissionGrant`.
   Depends on: Tasks 1 and 4.
   Acceptance: grants require exactly one subject, validate resource/action
   rules, validate conditions on write, store only JSON-object metadata, and
   support idempotent `upsert_permission_grant/1` by subject,
   `resource_pattern`, `action`, and `condition`.
   Verify: grant tests.

6. Implement authorization decisions.
   Owns: `BullX.AuthZ.authorize/4`, `authorize_permission/3`, and `allowed?/4`.
   Depends on: Tasks 2, 3, 4, and 5.
   Acceptance: active Principals authorize through direct or group grants,
   disabled Principals deny before grant evaluation, allow-any semantics work,
   action mismatch never authorizes, computed group and grant-level failures
   fail closed, and runtime computed-group and grant evaluation use batched Rust
   NIF calls rather than one generic CEL call per row.
   Verify: authorization tests.

7. Add admin recoverability protection.
   Owns: `BullX.AuthZ.ensure_can_disable_principal/1` and the Principal status
   update plus admin membership removal paths.
   Depends on: Task 3.
   Acceptance: disabling or removing admin membership from the final active
   Human member of `admin` is rejected unless an explicit recovery path is
   added; removing the final static admin group member is rejected; Agent admin
   membership does not satisfy the active Human recovery invariant; checks and
   writes run in one transaction with row locks or an equivalent serializable
   strategy.
   Verify: Principal status and membership removal guard tests.

8. Add bootstrap admin handoff.
   Owns: `BullX.AuthZ.Bootstrap`, `BullX.Application`, and the narrow
   activation-code handoff call.
   Depends on: Tasks 1 and 3.
   Acceptance: `admin` and `all_humans` groups are seeded idempotently,
   consumed bootstrap activation codes grant Human admin membership,
   non-bootstrap activation codes do not, non-Human Principal rows are skipped,
   and reconciliation can repair a missed handoff.
   Verify: bootstrap tests.

9. Add minimal enforcement integration only where this implementation slice
   needs it.
   Owns: Web, Runtime, Capability, or Agent code only if the current
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
- Disabled Principals, invalid requests, missing Principals, CEL failures, and
  invalid persisted conditions fail closed.
- Principal disable and admin membership removal flows preserve admin
  recoverability.
- Built-in `admin` and `all_humans` groups and bootstrap activation handoff work
  idempotently.
- Tests cover schema constraints, groups, grants, resource patterns, request
  normalization, action mismatch denial, CEL conditions, grant-level CEL
  compile/execution/non-boolean failures, computed group CEL
  compile/execution/non-boolean failures, missing context fail-closed behavior
  without invalid-persisted-data telemetry, disabled Principal behavior,
  bootstrap membership, Rust resource-pattern edge cases, admin recoverability
  protection, concurrent admin remove/disable behavior when the current test
  framework can express it, and any touched enforcement integration.
- `bun precommit` passes.

Implementation stops and asks if a change would introduce computed group
dependencies on other groups, request context, external identities, or grants;
explicit deny semantics; a policy catalog; a private AuthZ cache; a new
Principal type; external credential storage; Workflow policy-gate behavior;
approval behavior; TargetSession behavior; or high-risk external action
execution behavior.

## Acceptance criteria

- `BullX.AuthZ` exists as the Principal-centered authorization namespace.
- `principal_groups`, `principal_group_memberships`, and `permission_grants`
  persist the described state with UUIDv7 primary keys and PostgreSQL
  constraints.
- Human and Agent Principals can both receive direct grants and group-based
  grants.
- Computed groups derive effective membership from Principal CEL conditions and
  never persist computed memberships as rows.
- Disabled Principals never authorize.
- Principal disable and admin membership removal flows cannot leave the
  Installation without an active Human admin unless a future design adds an
  explicit recovery path.
- The `admin` group is built in, protected, non-magical, and populated only by
  bootstrap activation metadata or normal membership APIs.
- Subsystems that introduce AuthZ enforcement seed ordinary `admin` grants or
  document their setup/bootstrap bypass behavior.
- Subsystems that seed grants across retries use
  `BullX.AuthZ.upsert_permission_grant/1` instead of writing
  `permission_grants` directly.
- Authorization uses resource-pattern plus exact-action matching and allow-any
  grant semantics.
- Request resource strings cannot contain wildcard metacharacters; glob matching
  exists only in persisted `resource_pattern` values.
- CEL conditions evaluate only after subject, resource, and action matching;
  compile errors, execution errors, and non-boolean results fail closed per
  grant.
- Caller-provided context is normalized to CEL-compatible data under
  `context.request`.
- Enforcement points that rely on CEL context document their context keys and
  value types.
- AuthZ mutation functions do not self-authorize; callers authorize the acting
  Principal before invoking them.
- Public group deletion rejects groups that still own permission grants.
- AuthZ never creates, authenticates, activates, logs in, or externally binds
  Principals.
- No AuthZ-specific cache or computed-group dependency graph is introduced in the
  first implementation.
- `bun precommit` passes.
