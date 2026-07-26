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
- Agent runtime limits and Agent overrides
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
- the `scoped` or `global` scope policy
- an optional default value
- an optional generator
- an optional description
- the `console_writable` policy
- an optional `worker_env_name`

The schema accepts only JSON-compatible values. AppConfigure checks values
before a write, after a read, and when it loads a default.

`worker_env_name` sends the chosen value to Agent Computer as a POSIX
environment variable.

The registry rejects duplicate exact keys. It also rejects duplicate `worker_env_name` values.

## Declare a Family of Keys

A `PatternDefinition` handles a family of keys. A plugin uses it when instance
IDs make the full key list unknown at startup.

An exact definition takes priority over a pattern. The registry rejects a key
when two patterns match it.

A pattern uses the same schema, encryption, default, generator, scope, and Console policies. Patterns do not declare `worker_env_name` exports.

`console_writable: false` lets only the responsible subsystem change a value.
The Console can still read it. Use it when a Console edit would break the
deployment instance, as it would for `runtime_fabric.worker_auth_key`, which the release
bootstrap generates and every Worker authenticates with, and for
`principals.identity_providers.active`, which the identity-provider pages write.
A client-side rule is not sufficient, because the REST API accepts a write that
only the Console refuses.

## How the Console Presents Keys

The Console settings list reads this policy and does not keep its own list of key
names.

- A key with `console_writable: false` moves into one collapsed group. An
  operator can open the group and read the current value, and a key that another
  page writes also links to that page.
- A declared key prefix, such as `brain.`, replaces its member rows with one row
  and edits every member on one page. The key stays the save unit: the page
  writes each changed key separately, and it checks every changed value before
  the first write, so one rejected value does not leave the group part written.

## Global Values and Agent Overrides

Each row applies either to the complete deployment instance or to one Agent:

- `global` identifies the Ankole deployment instance.
- `agent:<agent_uid>` identifies one Agent override.

A scoped definition allows both forms. A global definition rejects Agent
overrides.

The Agent UID stays in the row's scope, not in its key. The global value and
Agent overrides use the same key.

## How AppConfigure Chooses a Value

For an Agent, AppConfigure checks these values in order:

1. the current Agent row
2. the global row
3. the code default

A read without an Agent starts with the global row. A global definition never
checks an Agent row.

AppConfigure tries the next choice only when a row is absent. A corrupt or
undecryptable row returns an error instead of hiding the problem.

`Ankole.AppConfigure.Resolution` returns the value and its `agent`, `global`, or `default` source.

Environment variables never override an AppConfigure value.

## Row Format in PostgreSQL

The `app_configurations` table stores one row for each `{scope, key}` pair. The table has these fields:

- `scope`
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
- `put_global/2` and `put_for_agent/3`
- `delete_global/1` and `delete_for_agent/2`
- `generate/1`

Runtime keys use the corresponding `*_by_key` functions. The registry must match each runtime key before the operation continues.

`update_global/2` holds a short per-key PostgreSQL advisory lock. The callback computes one replacement value and must not do external I/O.

AppConfigure checks a value before it commits the write. A successful database
commit means that the write succeeded.

After the commit, AppConfigure reloads the row into its cache. If that fails,
it removes the old cache entry and logs the error. The database write remains
successful, and a later read can load it again.

Deleting an Agent row restores global or default inheritance. Deleting a global row restores the code default when one exists.

## Cache Behavior

`Ankole.AppConfigure.Cache` keeps copies of database rows in ETS. It identifies
each copy by `{scope, key}`.

At startup, the cache tries to load every row. A cache miss reads the requested
row from PostgreSQL.

The cache has no TTL and no public refresh operation. AppConfigure writes and deletes refresh the affected key.

The cache remembers whether a row exists separately from whether it is valid.
It never treats an invalid row as absent. PostgreSQL holds the original row.

## Generate Values Only on Request

A definition can provide a generator. `generate/1` checks the generated value
but does not store it.

The setup flow or responsible subsystem must store an accepted value. A read
never creates a row.

ActorRuntime reads `runtime_fabric.worker_auth_key` through AppConfigure before
it prepares Worker startup data.

## Send Selected Values to Agent Computer

An exact definition can send its chosen value to one Agent Computer environment
variable. `worker_env_name` names that variable.

WorkerEnv combines these values with custom operator entries before each Agent
execution. It then applies the correct Agent override.

WorkerEnv controls reserved names, merge order, custom secrets, and process
injection. AppConfigure supplies only its declared values.

WorkerEnv contains static operator-managed values. It does not carry facts that
change for each Actor Turn. RuntimeFabric `turn_start` carries those facts in a
separate runtime environment map. Runtime environment names use the
`ANKOLE_RUNTIME_` prefix, and operator WorkerEnv entries cannot use that
namespace.

## Startup Order

The registry and cache start after `Ankole.Repo`. Boot-time consumers start after the AppConfigure processes.

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
