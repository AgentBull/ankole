# AuthZ

AuthZ authorizes actions for Ankole Principals. It is the durable permission
boundary for one Ankole Installation, not a SaaS tenant boundary and not a
runtime-local ACL cache.

The model is deliberately small:

- Principals are the subjects.
- Groups collect Principals through static membership or computed rules.
- Permission grants attach to exactly one Principal or one group.
- A request asks whether one Principal can perform one exact action on one
  concrete resource.
- The answer is allow only when an effective grant matches owner, action,
  resource pattern, and condition.

There are no deny grants. Missing, malformed, disabled, or ambiguous state
fails closed.

## Responsibility

AuthZ owns:

- Principal groups;
- static group memberships;
- computed group rules;
- external directory bindings for groups;
- permission grants;
- root admin initialization;
- last active human admin protection;
- resource/action request normalization;
- kernel snapshot assembly;
- kernel result interpretation;
- authorization decision ownership.

AuthZ does not own:

- Principal creation or lifecycle identity facts;
- external identity binding rows for humans and agents;
- channel actor verification;
- setup sessions, OIDC handshakes, or one-time login codes;
- chat room/message projection, delivery, or outbox state;
- agent conversations, LLM turns, memory, mission, soul, or runtime profiles;
- AppConfigure values or plugin configuration.

Those subsystems may call AuthZ and store `principal_uid` references, but AuthZ
owns only the policy facts and allow/deny decision.

## Runtime Placement And Kernel Boundary

The durable AuthZ domain belongs to the Elixir control plane and PostgreSQL.
The control plane should own group/grant writes, root bootstrap, admin safety,
and the public authorization facade.

`app/kernel` should own shared native mechanisms where exact parity matters
across host runtimes. For AuthZ, that means the pure rule-engine semantics:

- CEL validation and evaluation;
- resource-pattern validation;
- resource-pattern matching;
- computed group evaluation from a Principal snapshot;
- grant evaluation from an explicit authorization snapshot;
- batch decision evaluation for repeated checks over the same snapshot.

Placement should bias toward the kernel whenever a behavior can be expressed as
a deterministic function over explicit inputs without storage, network, runtime
process state, or product lifecycle ownership. If the same validation,
normalization, matcher, evaluator, or decision algorithm would otherwise be
implemented in both Elixir and Bun, put the shared behavior in the Rust core
first and expose it through bindings.

The kernel must not own AuthZ product state. It should not read PostgreSQL,
create groups, grant permissions, know setup sessions, decide who the first
admin is, or mutate Principal status. It should evaluate explicit inputs and
return explicit outputs. PostgreSQL rows must be loaded, locked, normalized,
filtered, and assembled into snapshots before crossing into the kernel. The
kernel should not receive a database connection, table name, query builder,
repository module, transaction handle, or storage-backed lazy lookup callback.

Elixir and Bun should not grow separate implementations of AuthZ rule semantics.
When a behavior needs to mean the same thing in both runtimes, the Rust core is
the source of that behavior, with Rustler and napi-rs bindings translating host
types and errors only.

Bun runtimes may execute agent work, AI proxy calls, or integration code. When
Bun needs an authorization decision, it should call the control-plane boundary
or receive a decision/snapshot produced by that boundary. The existence of
kernel bindings does not make Bun a second AuthZ owner. Bun code must not invent
parallel groups, grants, or Principal authority.

## Facade

The intended Elixir facade should live under `Ankole.AuthZ`. It should expose
domain operations rather than table-shaped helpers:

- authorize one action for a Principal, resource, and JSON context;
- authorize multiple actions for the same Principal/resource/context in one
  snapshot;
- return boolean checks for low-risk UI visibility paths;
- parse compact permission keys shaped as `<resource>:<action>`;
- list, create, update, and delete Principal groups;
- add and remove static group memberships;
- create, upsert, update, and delete permission grants;
- create or update external group bindings from identity-provider sync;
- ensure built-in groups exist;
- check whether root initialization is open;
- claim the first active human admin;
- prevent disabling or removing the last active human admin.

The facade should return explicit domain errors for operator-facing flows.
Boolean convenience calls may collapse denials to `false`, but they should not
hide diagnostics from write paths or bootstrap flows.

The facade should build kernel-ready snapshots from PostgreSQL state, call the
kernel rule engine for deterministic evaluation, and translate kernel results
back into AuthZ domain results.

## Tables

The table names below describe the intended durable model. Ankole may implement
them through Ecto schemas, but the database contract matters more than the
module names.

### `principal_groups`

`principal_groups` stores authorization groups:

- opaque row `id`;
- lowercase unique `name`;
- display `display_name`;
- `kind`: `static` or `computed`;
- optional `description`;
- optional `computed_condition`;
- `built_in`;
- `metadata` as a JSON object;
- timestamps.

Static groups must not have `computed_condition`. Computed groups must have a
non-empty CEL condition that can be evaluated against a Principal snapshot.

Group names are stable policy keys. They should be normalized to lowercase at
API edges and constrained lowercase in storage.

Built-in groups are rows, not hard-coded branches. They can own grants the same
way operator-created groups do, while still being protected from deletion or
shape drift.

### `principal_group_memberships`

`principal_group_memberships` stores explicit membership for static groups:

- `principal_uid`, referencing `principals.uid`;
- `group_id`, referencing `principal_groups.id`;
- timestamps.

The composite key is:

```text
principal_uid + group_id
```

Computed group membership is never stored here. The rule engine derives it from
`principal_groups.computed_condition` at authorization time.

Manual membership changes to computed groups must be rejected.

### `principal_group_external_bindings`

`principal_group_external_bindings` stores external directory bindings for
static groups:

- `provider`;
- `external_id`;
- `group_id`, referencing `principal_groups.id`;
- `metadata` as a JSON object;
- timestamps.

The primary key is:

```text
provider + external_id
```

Identity-provider sync owns these rows. A provider department, team, or role can
feed one Ankole static group without making the external directory id the group
id. If the external directory renames or reshapes a unit, the binding can move to
another local group while grants remain attached to Ankole group rows.

This table is not a Principal external identity table. It maps directory group
facts to AuthZ groups, while `principal_external_identities` maps provider
subjects to Principals.

### `permission_grants`

`permission_grants` stores allow grants:

- opaque row `id`;
- exactly one owner: `principal_uid` or `group_id`;
- `resource_pattern`;
- exact `action`;
- CEL `condition`, defaulting to `true`;
- optional `description`;
- `metadata` as a JSON object;
- timestamps.

The database should enforce:

- exactly one owner;
- non-empty `resource_pattern`;
- non-empty `action`;
- no colon inside `action`;
- JSON-object `metadata`;
- indexes for principal-owned grants, group-owned grants, and action lookup;
- idempotent upsert keys for owner + resource pattern + action + condition.

Grant writes should validate resource patterns and CEL conditions before
persisting. Authorization should still revalidate persisted grant shape and
fail closed if stored data becomes invalid.

## Built-In Groups

AuthZ manages two initial built-in groups:

- `admin`: static group.
- `all_humans`: computed group with condition
  `principal.type == "human" && principal.status == "active"`.

Built-in groups are created idempotently. If a same-name row already exists but
does not match the expected built-in shape, initialization must fail with a
conflict instead of silently adopting or mutating the row.

Public group updates must not set or clear the `built_in` flag. Deleting a
built-in group is rejected.

## Root Initialization

`root_initialized?/0` means the AuthZ storage surface is ready and the built-in
groups have the expected shape. It is a storage/bootstrap readiness check, not a
claim-state check.

Root initialization is open only while the built-in `admin` group has no
membership. The first admin claim must:

- accept only an active human Principal;
- reject agents and disabled humans;
- ensure the built-in `all_humans` group exists;
- ensure the built-in `admin` group exists;
- lock the Principal and admin group;
- re-check that root initialization is still open;
- insert the admin membership in the same transaction.

This is a setup/AuthZ flow layered on top of Principals. Principals supplies the
human subject; AuthZ owns the admin group, membership, and close-root decision.

Product setup may expose a higher-level "installation claimed" state once there
is an explicit active human admin. That projection must not be collapsed into
`root_initialized?/0`, because failed or invalid root-claim attempts should not
make AuthZ appear unready after the built-in groups already exist.

## Authorization Flow

Authorization checks one Principal, one concrete resource, and one exact action:

1. normalize the Principal UID, resource, action, and JSON context;
2. load the Principal and require `status = active`;
3. load static group memberships for that Principal;
4. load all computed groups and their conditions;
5. load candidate grants for the Principal, static groups, and computed groups
   with the requested action;
6. build an explicit decision snapshot for the kernel;
7. evaluate computed group membership from the Principal snapshot;
8. reject invalid persisted computed group conditions as diagnostics;
9. match each candidate grant by effective owner and exact action;
10. match the grant resource pattern against the concrete request resource;
11. evaluate the grant condition with the request environment;
12. allow if any valid candidate grant matches.

Batch authorization uses the same model for multiple actions against the same
Principal, resource, and context. It should load the Principal, effective group
inputs, and candidate grants once, then evaluate actions in caller order with
default-deny semantics.

Steps 1 through 6 are control-plane responsibilities. Steps 7 through 12 are
kernel rule-engine responsibilities over the snapshot. The boundary is important:
database loading and product policy stay in AuthZ, while low-level rule meaning
stays in `app/kernel`.

## Kernel Decision Snapshot

The kernel authorization input should be a plain, host-neutral snapshot:

- `principal`: UID, type, status, display name, and avatar URL;
- `static_group_ids`: explicit static memberships already loaded from storage;
- `computed_groups`: ids and CEL conditions for candidate computed groups;
- `grants`: candidate grants with owner, resource pattern, action, and condition;
- `resource`: one concrete request resource;
- `action` or `actions`: one exact action or an ordered batch;
- `context`: JSON request context.

The kernel authorization output should be explicit:

- decision status;
- effective group ids;
- denied action for batch checks;
- diagnostics for invalid persisted group or grant data.

The snapshot is not a cache format and not a durable record. It is a boundary
object that lets the control plane keep ownership of storage while the kernel
keeps ownership of deterministic rule evaluation.

## Request Vocabulary

A permission is a `resource + action` pair.

Resources are colon-hierarchical keys, such as:

```text
agent:researcher
chat:channel:abc
work:item:123
```

Actions are exact tokens, such as:

```text
read
invoke
update
disable
```

The compact permission-key form uses the last colon as separator:

```text
<resource>:<action>
```

Grant resource patterns may use the AuthZ resource glob syntax. Request
resources must be concrete and must not contain glob characters, so callers
cannot ask broad questions such as "do I have anything matching this pattern?"
through a single authorization check.

Actions must not contain colons. Colon hierarchy belongs to resource keys and
the compact permission-key separator.

## Request Environment

CEL conditions receive:

- `principal`;
- `resource`;
- `action`;
- `context`.

The Principal object includes:

- `uid`;
- `type`;
- `status`;
- `displayName`;
- `avatarUrl`.

Caller-supplied context must be a JSON object. The rule engine should expose it
under a stable namespace such as `context.request` so future system context can
be added without colliding with caller fields.

## Resource Patterns And CEL

Resource-pattern and CEL semantics should be shared through `app/kernel`. That
gives Elixir and Bun one implementation for:

- validating grant resource patterns;
- matching grant patterns against concrete request resources;
- validating CEL expressions;
- evaluating computed group membership;
- evaluating grant conditions;
- reporting diagnostics for invalid persisted policy data.

Invalid persisted computed group conditions, resource patterns, or grant
conditions must never become an allow decision. They should produce diagnostics
for operators and otherwise behave as non-matching policy.

## Identity-Provider Sync

Identity-provider sync may create or update:

- human Principals;
- Principal external identities;
- static Principal groups;
- static group memberships;
- external group bindings.

AuthZ should own the group and membership writes, even when identity-provider
sync is the caller. The identity provider supplies directory facts; AuthZ owns
how those facts become local groups and grants.

Directory group membership should materialize into static group membership
rows. Computed groups remain local CEL rules and should not be used as the
target of external binding sync.

## Failure Semantics

Authorization returns allow or a domain denial/error. Typical denial reasons
include:

- missing Principal;
- disabled Principal;
- malformed request resource, action, or context;
- no matching grant;
- invalid persisted group condition;
- invalid persisted grant resource pattern;
- invalid persisted grant condition.

Invalid persisted policy data is a security-relevant operator problem, but it
does not make a request allowed.

Write paths should reject invalid group, membership, grant, and binding shapes
before storage. Authorization paths should still protect themselves against
bad persisted data.

Removing an admin member or disabling a Principal must preserve at least one
active human admin. The check should be transactional where concurrent admin
removal or disable operations could otherwise observe stale state.

## Invariants

- AuthZ is allow-list based; no grant means denial.
- Principals are subjects; groups and grants are policy facts.
- A grant belongs to exactly one Principal or one group.
- Static memberships are stored rows.
- Computed memberships are evaluated, not stored.
- External group bindings feed static groups, not computed groups.
- Built-in groups are protected rows with expected shape.
- Root initialization can create only the first active human admin membership.
- Principal status is checked before grant evaluation can allow.
- Request resources are concrete, while grant resources may be patterns.
- Actions are exact tokens and do not contain colons.
- CEL and resource-pattern behavior must not drift between Elixir and Bun.
- Invalid persisted policy fails closed and emits diagnostics.
- AuthZ does not mutate Principal identity records except through explicit
  status-safety checks owned by the caller.
