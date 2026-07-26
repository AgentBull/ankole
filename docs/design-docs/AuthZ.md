# AuthZ

AuthZ answers one question: can this Principal perform this action on this
resource? A Principal is the human or Agent responsible for the request.

PostgreSQL stores the permission rules for one Ankole deployment instance.
AuthZ manages subjects inside that instance. It does not create separate
organization boundaries or keep a worker-local access list.

AuthZ grants permission only through explicit allow rules. It has no deny rule.
If required data is missing, invalid, disabled, or unmatched, AuthZ denies the
request.

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

Rustler and napi-rs expose the same rules to host runtimes. The bindings only
convert values and errors.

Bun code does not implement another permission model. It calls the control
plane or evaluates data prepared by the control plane.

## Stored Groups and Grants

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
provider + external_kind + external_id
```

The `external_kind` field accepts these values:

- `directory_department`
- `im_group`

Provider names use lowercase local namespaces.
The row also stores `group_id`, JSON metadata, and timestamps.

### `permission_grants`

The table stores these fields:

- A UUIDv7 `id`.
- Either `principal_uid` or `group_id`.
- `resource_pattern`.
- `action`.
- `condition` with default `true`.
- Optional `description`.
- A JSON `metadata` object.
- Timestamps.

Exactly one owner field must exist.
An action cannot contain a colon.

The natural key contains owner, resource pattern, action, and condition.
Separate partial unique indexes cover Principal-owned and group-owned grants.

## Name Resources and Actions

A request names one concrete resource. It cannot contain `*`, `?`, brackets,
or braces.

A stored grant can use a glob pattern. Colons separate resource segments.

- `*` stays inside one segment.
- `**` can cross segment boundaries.

The kernel translates colons to path separators before `globset` matching.

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

Writes validate CEL syntax through the native kernel.
Writes also validate resource pattern syntax through the native kernel.

If stored CEL or a pattern is invalid, the kernel skips that group or grant,
returns a diagnostic, and denies by default.

The control plane logs these diagnostics with `authz.invalid_persisted_data`.
It also emits the `ankole.authz.invalid_persisted_data` telemetry event.

## Load the Data for One Decision

The control plane:

1. Checks the Principal UID, resource, action, and context.
2. Loads the Principal from PostgreSQL.
3. Loads explicit static group IDs.
4. Loads all computed group conditions.
5. Loads candidate grants for the requested actions.
6. Calls the Rust kernel with all loaded data.
7. Converts the kernel decision to an AuthZ result.

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

## Create the First Administrator

Root setup creates two built-in groups. The static `admin` group contains root
operators for the deployment instance.

AuthZ computes the `all_humans` group.
It uses this CEL condition:

```text
principal.type == "human" && principal.status == "active"
```

The first administrator must be an active human Principal. One transaction
creates both groups, adds that human to `admin`, and creates Console grants.

The same Principal can safely repeat the first claim. After that, another
Principal cannot claim the first-administrator role.

The built-in administrator receives these actions over `**`:

- `read`
- `update`
- `delete`
- `reset`
- `decrypt`
- `sync`

The setup bootstrap can repair these grants after root setup completes.

AuthZ prevents removal or disabling of the last active human administrator.

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

## Rules

- Use Principals as the only accountable subjects.
- Store permission rules in PostgreSQL.
- Give every grant exactly one owner.
- Match actions exactly.
- Evaluate only concrete request resources.
- Use the Rust kernel for shared rule evaluation.
- Skip invalid persisted rules and emit diagnostics.
- Deny by default.
- Protect the last active human administrator.

See [Principal](Principal.md) for identity and status rules.
