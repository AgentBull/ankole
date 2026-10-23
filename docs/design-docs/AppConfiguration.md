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

Settings operations use `/api/v2/site/app-configurations` for site values and
`/api/v2/app-configurations` for tenant values. Typed Ash actions call the
AppConfigure owner. The owner validates and stores each value, then publishes
its committed cache value. List and detail responses mask encrypted values;
only an authorized `POST /:key/decryptions` reveals a value. Generic action
write bodies put their arguments in `data`.

The Console settings list reads this policy and does not keep its own list of key
names.

- A key with `console_writable: false` moves into one collapsed group. An
  operator can open the group and read the current value, and a key that another
  page writes also links to that page.
- A declared key prefix, such as `observability.traces.`, replaces its member rows with one row
  and edits every member on one page. The key stays the save unit: its editor
  model writes each changed key separately and validates all changed drafts locally
  before the first write. Each successful write updates only that key's saved
  baseline. A server rejection stops the remaining writes, keeps earlier
  successful writes, and leaves failed and unsent drafts in the editor.

Decryption applies only to the draft that requested it. A response that arrives
after the operator selects another setting or changes the draft does not replace
the current input. Save and restore responses update the saved baseline and keep
edits made after the request began. Editor models own drafts, validation, write
bodies, and asynchronous completion checks. They call the request functions that
the page provides, and only a current completion can close the editor. A group
model also owns the save batch state. TanStack Query owns individual request
state and cache refresh.

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

Identity-provider settings (`principals.identity_providers.*`) belong to a
tenant (`tenant:<id>`) and do not inherit a site default. Generic settings
cannot write these keys; the identity-provider owner validates platform
application assignment. Signal binding secrets are global (`global`) because
their key includes a hash of the globally unique Agent UID and binding name; the
binding lifecycle deletes them.

The settings page shows the site value and current tenant value in separate
columns. Site writes use `/api/v2/site/app-configurations`; tenant writes use
`/api/v2/app-configurations`. Both use the same validation and encryption owner.

AppConfigure tries the next choice only when a row is absent. A corrupt or
undecryptable row returns an error instead of hiding the problem.

`Ankole.AppConfigure.Resolution` returns the value and its `agent`, `tenant`, `global`, or `default` source.

Environment variables never override an AppConfigure value.

## Row Format in PostgreSQL

Global rows use the site-owned `site_app_configurations` table and the
`SiteConfig` schema. Their scope is `global`, and `{scope, key}` is unique.
Tenant and Agent rows use the tenant-owned `app_configurations` table and
`AppConfig` schema. That table requires `tenant_id`, accepts `tenant:<id>` or
`agent:<uid>` scopes, and makes `{tenant_id, scope, key}` unique. Repo checks
the tenant on reads and writes.

Both tables store `scope`, `key`, JSONB `value`, `inserted_at`, and `updated_at`.
The database checks the scope and the value wrapper. `AppConfig` and `SiteConfig`
are Ash resources with these natural primary keys. Their `put` action resolves
the registered definition, validates the scope and input, and encrypts secrets
before its upsert. Both the Console and boot-time owners use this action.
AppConfigure selects the owning resource from the scope and applies the
scope inheritance order.
`Envelope` owns the stored wrapper's tags and shape. `Codec` consumes that
contract for definition validation and encryption; the storage type does not
depend on the runtime configuration owner.

Signal Bindings record public platform identity through the resources'
`record_platform_application` action. It merges only the outer JSONB metadata;
the encrypted value keeps its exact ciphertext. Configuration deletion uses
the same `remove` action for individual and bulk callers.

WorkerEnv uses the same separation: global rows use `site_worker_envs`, and
Tenant and Agent rows use `agent_computer_worker_envs`. Encryption binds each
value to its scope and key.
Caches include the tenant in their identity and invalidation message.

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

`AppConfigure` is the Ash domain of `AppConfig` and `SiteConfig`.
`update_global/2`, `update_tenant/2`, and `ensure_generated_global/1` are
generic actions that own their transaction and refresh the cache after the
commit. Another domain's action uses the transaction forms
(`update_tenant_in_tx/3`, `put_global_by_key_in_tx/3`,
`lock_global_by_key_in_tx/2`) and then calls `cache_committed_write/1` after its
own commit. A delete is one statement and needs no transaction.

AppConfigure checks a value before it commits the write. A successful database
commit means that the write succeeded.

After the commit, AppConfigure reloads the row into its cache. If that fails,
it removes the old cache entry and logs the error. The database write remains
successful, and a later read can load it again.

Deleting a tenant row restores global or default inheritance. Deleting a global row restores the code default when one exists.

## Cache Behavior

`Ankole.AppConfigure.Cache` keeps copies of database rows in ETS. It identifies
each copy by `{tenant_id, scope, key}`. Site entries use a `nil` tenant.

At startup, the cache tries to load the site rows. A cache miss reads the requested
row from PostgreSQL. The cache keeps that result only if no refresh started
after the miss began, because the result can be older than the write that
started the refresh.

Each entry expires after five seconds, including an absent row. AppConfigure
writes and deletes refresh the affected key after commit. The cache checks
refresh generations and read start times before it publishes a loaded row. Both
cache misses and refreshes read in the caller's process with its current
connection and tenant. The cache process only owns invalidation and publication;
it does not borrow a writer's database connection.

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

`EnvVar` and `SiteEnvVar` are Ash resources with natural identities
`tenant_id/scope/name` and `scope/name`. The `put` action owns name validation,
secret-state changes, and encryption. A metadata-only write keeps the stored
ciphertext. An inherited secret is sealed for the new scope before storage.
The `remove` action owns individual and Agent-cleanup deletion. All list and
execution reads use the same resources. WorkerEnv owns tier inheritance and
response masking. The JSON:API policy checks reveal authorization separately
from reads and writes. Site, tenant, and Agent operations use
`/api/v2/site/worker-envs`, `/api/v2/worker-envs`, and
`/api/v2/agents/:agent_uid/worker-envs`. Typed transport actions call WorkerEnv;
the storage resources keep validation and encrypted value ownership.

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
