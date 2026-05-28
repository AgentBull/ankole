# AuthZ

AuthZ authorizes actions for BullX Principals. It uses persisted groups and
permission grants, CEL conditions, and resource-pattern matching. The
implementation lives in `BullX.AuthZ` and `BullX.AuthZ.*`.

## Responsibility

AuthZ owns:

- Principal groups;
- static group memberships;
- computed group membership evaluation;
- permission grants;
- root admin initialization;
- last active human admin protection;
- authorization decisions.

AuthZ does not own Principal creation, channel identity verification, bootstrap
code storage, login auth codes, MailBox delivery, or AIAgent conversation state.

## Data Model

`principal_groups` stores:

- `name`, unique and lowercase;
- `kind`: `static` or `computed`;
- optional `description`;
- optional `computed_condition`;
- `built_in`.

Static groups must not have `computed_condition`. Computed groups must have a
non-empty CEL condition.

`principal_group_memberships` stores static group membership by composite
primary key:

- `principal_id`
- `group_id`

`permission_grants` stores allow grants:

- exactly one of `principal_id` or `group_id`;
- `resource_pattern`;
- `action`;
- `condition`, defaulting to `true`;
- optional `description`;
- `metadata` JSON object.

The database constrains grant ownership, non-empty resource/action, actions
without colons, and at most one wildcard in the resource pattern.

## Built-In Groups

AuthZ manages two built-in groups:

- `admin`: static group.
- `all_humans`: computed group with condition
  `principal.type == "human" && principal.status == "active"`.

Built-in groups are created idempotently. Public group updates cannot set the
`built_in` flag.

## Root Initialization

`BullX.AuthZ.root_initialized?/0` is true when AuthZ storage is ready and the
built-in groups exist.

`ensure_root_init_open/0` returns `:ok` only while there is no active human
admin membership.

`root_init_admin/1` accepts an active Human Principal, locks the admin group,
re-checks that root init is still open, and inserts the admin membership.
Agents cannot become the first admin.

## Authorization Flow

`authorize/4` performs this flow:

1. load the Principal and require `status = active`;
2. collect static group memberships;
3. evaluate computed groups;
4. load candidate permission grants for the Principal or any effective group
   with the exact requested action;
5. validate persisted grant shape and CEL conditions;
6. match each grant's resource pattern against the requested resource;
7. evaluate the grant condition with the request environment;
8. allow if any valid loaded grant allows.

`allowed?/4` wraps `authorize/4` and returns a boolean.

`authorize_permission/3` accepts a single permission key formatted as
`<resource>:<action>` and delegates to `authorize/4`.

## Request Environment

CEL conditions receive:

- `principal`
- `resource`
- `action`
- `context`

The Principal object includes id, type, status, display name, bio, and avatar
URL. Caller-supplied context is normalized through `BullX.AuthZ.Request`.

AuthZ and MailBox both use CEL support, but they are separate business
surfaces. AuthZ evaluates permission grants; MailBox evaluates delivery rules.

## Resource Patterns

`BullX.AuthZ.ResourcePattern` validates persisted patterns and matches them via
the Rust-backed AuthZ rule engine.

Caller request resources are validated separately and must not contain
wildcards.

## Public API

Current `BullX.AuthZ` functions include:

- `authorize/3`
- `authorize/4`
- `authorize_permission/2`
- `authorize_permission/3`
- `allowed?/3`
- `allowed?/4`
- `list_principal_groups/1`
- `create_principal_group/1`
- `update_principal_group/2`
- `delete_principal_group/1`
- `add_principal_to_group/2`
- `remove_principal_from_group/2`
- `create_permission_grant/1`
- `upsert_permission_grant/1`
- `update_permission_grant/2`
- `delete_permission_grant/1`
- `ensure_can_disable_principal/1`
- `root_initialized?/0`
- `ensure_root_init_open/0`
- `root_init_admin/1`
- `ensure_built_in_admin_group/0`
- `ensure_built_in_all_humans_group/0`

## Failure Semantics

Authorization returns `{:ok, :allow}` or `{:error, reason}`.

Typical denial reasons include inactive or missing Principals, no matching
grant, invalid request data, and invalid persisted grant/group data.

Invalid persisted grant or computed-group data is emitted as telemetry
diagnostics and does not become an allow decision.

Deleting a built-in group returns `{:error, :built_in_group}`. Removing the last
active human admin or disabling the last active human admin is rejected.

## Invariants

- AuthZ is allow-list based; no grant means denial.
- Principal status is checked before grant evaluation.
- A grant belongs to exactly one Principal or one group.
- Group names are lowercase stable keys.
- Root init can create only the first active human admin membership.
- AuthZ does not mutate Principal identity records except through explicit
  status-safety checks owned by callers.
