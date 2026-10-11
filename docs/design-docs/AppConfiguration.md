# App Configuration

Ankole reads settings from two places. The process environment provides values
that Ankole needs before it can start. AppConfigure stores values that an
operator can change while Ankole runs.

Put each setting in one place. Code must not ask AppConfigure for a value that
the process needs during startup.

## Settings Needed During Startup

The process environment provides startup settings such as:

- `DATABASE_URL`
- root secret material such as `SECRET_KEY_BASE`
- Phoenix host, port, TLS, and release-server settings
- database and HTTP pool sizes
- development and test paths

These values describe the process and its infrastructure. Restart the affected
process after you change one.

AppConfigure cannot provide a startup setting because PostgreSQL and its cache
may not exist yet.

## Settings That Operators Can Change

AppConfigure stores a declared set of settings in PostgreSQL. Operators, setup
flows, Ankole subsystems, and trusted Plugins can use them.

Examples include:

- the default locale
- tenant Agent execution limits
- plugin setup values
- chat and identity-provider settings that are not bootstrap requirements

AIGateway stores provider credentials in `ai_gateway_providers`. Agent model
preferences belong in `agents.options`.

AppConfigure is not a free-form key-value store. It rejects a key unless code
has registered that key.

## Declare Each Key Before Use

An `Ankole.AppConfigure.Definition` tells AppConfigure how to handle one key:

- a stable key
- a value schema
- the `encrypted` storage policy
- the ownership policy: `global` values only, or `tenant` values with Agent overrides
- an optional default value
- an optional generator
- an optional description
- the `console_writable` policy

The schema accepts only JSON-compatible values. AppConfigure checks values
before a write, after a read, and when it loads a default.

The registry rejects duplicate exact keys.

## Declare a Family of Keys

A `PatternDefinition` handles a family of keys. A plugin uses it when instance
IDs make the full key list unknown at startup.

An exact definition takes priority over a pattern. The registry rejects a key
when two patterns match it.

A pattern uses the same schema, encryption, default, generator, scope, and Console policies.

`console_writable: false` lets only the responsible subsystem change a value.
The Console can still read it. Use it when a Console edit would break the
identity-provider configuration, as it would for
`principals.identity_providers.active`, which the identity-provider pages write.
A client-side rule is not sufficient, because the REST API accepts a write that
only the Console refuses.

## How the Console Presents Keys

The Console settings list reads this policy and does not keep its own list of key
names.

- A key with `console_writable: false` moves into one collapsed group. An
  operator can open the group and read the current value, and a key that another
  page writes also links to that page.
- A declared key prefix, such as `observability.traces.`, replaces its member rows with one row
  and edits every member on one page. The key stays the save unit: the page
  writes each changed key separately, and it checks every changed value before
  the first write, so one rejected value does not leave the group part written.

The generic encrypted-value editor keeps input as an opaque string unless the
complete input is a valid JSON object or array. Thus, a secret such as `1234`,
`true`, or `{vault-token` does not change type by accident. A valid object or
array is structured data, not an opaque string. A subsystem that needs another
encrypted value shape must provide its own editor.

## Site and Tenant Values

Rows use `global`, `tenant:<tenant_id>`, or `agent:<agent_uid>` scopes. A
`global` definition permits only site values. A `tenant` definition resolves
an Agent override first when the caller passes `agent_id`, then the current
tenant, the site value, and the code default. The Agent must belong to the
process's tenant. Tenant reads require that context; a value payload cannot
select another tenant.

The multi-tenant migration adds the default tenant's ownership to existing
Agent rows. It keeps their scope, key, and encrypted value unchanged, so the
original encryption binding remains valid.

The settings page shows the site value and current tenant value in separate
columns. Site writes use `/api/v1/site/app-configurations`; tenant writes use
`/api/v1/app-configurations`. Both use the same validation and encryption owner.

AppConfigure tries the next choice only when a row is absent. A corrupt or
undecryptable row returns an error instead of hiding the problem.

`Ankole.AppConfigure.Resolution` returns the value and its `agent`, `tenant`, `global`, or `default` source.

Environment variables never override an AppConfigure value.

## Row Format in PostgreSQL

The `app_configurations` table stores one row for each `{scope, key}` pair. The table has these fields:

- `scope`
- `tenant_id`, null for global rows and a tenant foreign key for other rows
- `key`
- JSONB `value`
- `inserted_at`
- `updated_at`

The database allows only one row for each `{scope, key}` pair. It also checks
the scope and the value wrapper.

A plaintext value uses this envelope:

```json
{
  "type": "plaintext",
  "value": "en-US"
}
```

An encrypted value uses this envelope:

```json
{
  "type": "cipher",
  "value": "<sealed-json>"
}
```

The registered definition selects the valid wrapper type.

## How AppConfigure Protects Secrets

AppConfigure checks a secret and converts it to JSON before encryption.

`Ankole.AppConfigure.Crypto` gets the bootstrap secret from `Ankole.SecretKeyBase`. It serializes `[scope, key]` as the derivation context.

The module uses these kernel functions:

- `Ankole.Kernel.derive_key/3`
- `Ankole.Kernel.aead_encrypt/2`
- `Ankole.Kernel.aead_decrypt/2`

The encryption uses the scope and key. Copying encrypted text to another row
does not produce a valid value there.

The ETS cache keeps secrets encrypted. AppConfigure decrypts one only for a
typed read or an authorized Console request.

## Read and Change Values

Exact definitions use these public functions:

- `resolve/2` and `get/2`
- `put_global/2`
- `delete_global/1`
- `put_tenant_by_key/2`, `delete_tenant_by_key/1`, and their transaction forms
- `generate/1`

Runtime keys use the corresponding `*_by_key` functions. The registry must match each runtime key before the operation continues.

`update_global/2` holds a short per-key PostgreSQL advisory lock. The callback computes one replacement value and must not do external I/O.

AppConfigure checks a value before it commits the write. A successful database
commit means that the write succeeded.

After the commit, AppConfigure reloads the row into its cache. If that fails,
it removes the old cache entry and logs the error. The database write remains
successful, and a later read can load it again.

Deleting a tenant row restores global or default inheritance. Deleting a global row restores the code default when one exists.

## Cache Behavior

`Ankole.AppConfigure.Cache` keeps copies of database rows in ETS. It identifies
each copy by `{scope, key}`.

At startup, the cache tries to load every row. A cache miss reads the requested
row from PostgreSQL. The cache keeps that result only if no refresh started
after the miss began, because the result can be older than the write that
started the refresh.

The cache has no TTL and no public refresh operation. AppConfigure writes and deletes refresh the affected key.

The cache remembers whether a row exists separately from whether it is valid.
It never treats an invalid row as absent. PostgreSQL holds the original row.

## Generate Values Only on Request

A definition can provide a generator. `generate/1` checks the generated value
but does not store it.

The setup flow or responsible subsystem must store an accepted value. A read
never creates a row.

`runtime_fabric.worker_auth_key` is the installation key used for opaque Lark
profile names. It stays in the control plane. Each Worker generation uses its
own random credential, stored by AgentWorkers. Console writes to the profile
key are disabled because a replacement would change existing profile names.

## Custom Agent Computer Environment Variables

WorkerEnv stores operator-managed environment variables separately from
AppConfigure. Site values apply first, then tenant values, then Agent values.
Binding variables and explicit command variables apply afterwards. A WorkerEnv
value is a string; secret values use encrypted storage.

AppConfigure declarations do not export environment variables. RuntimeFabric
carries per-turn runtime facts separately. Runtime names use the
`ANKOLE_RUNTIME_` prefix, and operator WorkerEnv entries cannot use that namespace.

## Startup Order

The registry and cache start after `Ankole.Repo`. Boot-time consumers start after the AppConfigure processes.

The registry rebuilds all core declarations from one code catalog when it
starts. If the Control Plane Plugin Registry is running, AppConfigure also
restores the exact definitions and patterns from its active boot snapshot.
Thus, an AppConfigure Registry crash does not restart unrelated consumers or
leave the Console with a partial declaration set.

The catalog is the only registration path for core declarations. A config
owner reads and writes through its declared definition and does not register
at call time; a definition missing from the catalog fails its callers loudly.

Plugin declarations form one replaceable source. A new Plugin boot snapshot
replaces that complete source in one Registry call. This operation removes
declarations from inactive Plugins and does not change core declarations.

If a committed setting changes a live process, the subsystem that uses the
setting must apply it after the write.

## Rules

- Bootstrap configuration does not depend on Repo or AppConfigure.
- AppConfigure does not read OS environment variables.
- Every key has an exact definition or one unambiguous pattern.
- A definition controls validation, scope, encryption, and Console writes.
- Only a missing row permits fallback.
- PostgreSQL stores secret values as encrypted envelopes.
- Code defaults are effective values, not database rows.
- Reads never store generated values.
- A successful PostgreSQL commit means that a write succeeded.
- Ankole can rebuild the ETS cache from PostgreSQL.

Identity-provider settings belong to the tenant. Their encrypted rows move from
`global` to `tenant:<id>` in the release migration, which decrypts and encrypts
them with the new scope in one transaction. Generic settings cannot write these
keys; the identity-provider owner validates platform application assignment.
Signal binding secrets remain global because their key includes a hash of the
globally unique Agent UID and binding name. The binding lifecycle deletes them.
