# App Configuration

Ankole configuration has two separate surfaces:

- bootstrap configuration read from the process environment before the
  application starts;
- AppConfigure values read from and written to PostgreSQL while the application
  is running.

The boundary is deliberately sharp. Bootstrap configuration describes how the
process starts. AppConfigure describes operator-managed runtime settings inside
an already-running Ankole installation. A value belongs to one surface, not both.

## Bootstrap Configuration

Bootstrap configuration is read during Phoenix/Mix configuration and application
startup, before Repo, AppConfigure, setup, plugins, or agents can be trusted.

Bootstrap configuration owns process and infrastructure facts, including:

- `DATABASE_URL`;
- root secret material such as `SECRET_KEY_BASE`;
- Phoenix endpoint host, port, TLS, and release-server settings;
- database and HTTP pool sizes;
- Redis connection settings such as `REDIS_URL`;
- local development and test-only paths.

These values are deployment facts. Changing them requires changing the process
environment and restarting the affected process.

AppConfigure must not be used to discover bootstrap values. In particular, Redis
URLs, database URLs, endpoint settings, pool sizes, and root secret material are
not runtime settings, because the application may need them before PostgreSQL or
the AppConfigure cache is available.

## AppConfigure

AppConfigure is Ankole's database-backed runtime configuration store. It holds a
small declared set of settings that operators, setup flows, console pages, and
trusted plugins can change while the application is running.

Typical AppConfigure values include:

- default locale and other operator-visible product settings;
- LLM provider credentials and model preferences;
- agent runtime limits and per-agent overrides;
- plugin-owned setup values;
- chat-channel or identity-provider settings that are not required to boot the
  process.

AppConfigure is not a generic key-value store. Every key must be declared by its
owning subsystem or accepted by a registered pattern. The declaration defines
the key's schema, encryption policy, optional default, and human-facing
description.

The implementation should use an explicit AppConfigure namespace, such as
`Ankole.AppConfigure.*`, so application code does not confuse runtime database
settings with bootstrap environment configuration.

Native cryptographic and low-level shared semantics come from `app/kernel`.
Elixir code imports them through the Rustler NIF module `Ankole.Kernel`; Bun
loads the same Rust core through the kernel's Node-API binding. AppConfigure
should call the kernel boundary for key derivation and AEAD operations instead
of implementing its own crypto helpers inside the control-plane app.

## Declaration

Each AppConfigure definition declares:

- stable key, for example `i18n.default_locale` or `llm.openai.api_key`;
- value schema;
- whether the stored value is encrypted at rest;
- optional code default;
- optional description for setup and admin surfaces.

Values are JSON-compatible: null, booleans, numbers, strings, arrays, and
objects. AppConfigure does not store arbitrary Elixir terms, because the durable
storage is PostgreSQL `jsonb` and encrypted values are sealed from serialized
JSON.

The schema is part of the key contract. It plays the same role that Zod plays in
the Bun implementation: values are validated before persistence, after database
reads, and before code defaults are accepted. The Elixir implementation may use
Elixir-native schema modules, but it must preserve the same behavior instead of
using ad hoc casts at call sites.

Pattern definitions are allowed when the concrete key set is only known at
runtime, for example plugin-owned provider instances. Exact definitions take
precedence over patterns. If more than one pattern matches one key, the key is
rejected so validation and encryption policy never depend on load order.

Unknown keys are rejected before persistence. This keeps the runtime
configuration surface bounded and prevents typo-created database rows.
Duplicate exact keys and duplicate pattern ids are rejected at registration
time.

## Scope

Every AppConfigure row has a scope. Scope is independent from the logical key:

- `global` means the current Ankole installation;
- `agent:<agent_id>` means one agent-specific override.

The agent id is chosen by the agent subsystem and must be stable. It should not
be embedded in the key path.

This keeps global and per-agent configuration in one table while preserving a
simple mental model: the same key can have one installation-wide value and zero
or more agent-specific overrides.

## Resolution

Effective reads use this fallback order:

1. current agent scope, when the caller has a current agent;
2. `global`;
3. the definition's code default, when one exists.

If there is no current agent, the read starts at `global` and then falls back to
the code default.

Fallback applies only to missing rows. A row that exists but cannot be
decrypted, decoded, or validated is a storage error. It should not silently
inherit the next value, because invalid stored configuration usually means
corruption, a broken migration, or mismatched secret material.

Environment variables are not part of AppConfigure resolution.

## Persistence

The table is `app_configure`.

It stores one row per `{scope, key}`:

- `scope` as text, required;
- `key` as text, required;
- `value` as `jsonb`, required;
- `created_at`;
- `updated_at`.

The unique key is `{scope, key}`.

`scope` has a database check constraint:

```sql
scope = 'global' OR scope ~ '^agent:.+$'
```

`value` is a self-describing envelope:

```json
{
  "type": "plaintext",
  "value": "en-US"
}
```

Encrypted values use the same envelope shape:

```json
{
  "type": "cipher",
  "value": "<sealed-json>"
}
```

The database should check that `value` is a JSON object containing `type` and
`value`. The application definition decides whether `plaintext` or `cipher` is
valid for a key.

The envelope keeps storage self-describing and leaves room for future sidecar
fields without adding a separate column for each storage concern.

## Read API

The public read API should make the resolution context explicit:

- `get(definition, agent_id: id)` resolves `agent:<id>`, `global`, then default;
- `get(definition)` resolves `global` then default;
- `get_by_key(key, agent_id: id)` is reserved for registered pattern-backed
  keys.

Setup and console surfaces often need to show where a value came from. For those
surfaces, the read result should include the effective source, such as
`:agent`, `:global`, or `:default`. Runtime call sites that only need the value
may use a value-only helper.

## Write API

Writes always target one concrete scope:

- `put_global(definition, value)`;
- `put_for_agent(agent_id, definition, value)`;
- `delete_global(definition)`;
- `delete_for_agent(agent_id, definition)`.

Deleting an agent row makes that agent inherit the global row. Deleting a global
row makes all non-overridden agents inherit the code default, if one exists.

Writes validate through the registered definition before touching PostgreSQL.
Encrypted definitions serialize the JSON value, derive row-specific key material
through `Ankole.Kernel.derive_key/3` from the bootstrap root secret plus `scope`
and `key`, seal the serialized value through `Ankole.Kernel.aead_encrypt/2`, and
store the sealed string in a `cipher` envelope.

After a successful write, the process-local cache is updated or evicted for the
affected `{scope, key}`. PostgreSQL remains the durable source of truth.

## Cache

`Ankole.AppConfigure.Cache` owns a reconstructible ETS projection of concrete
database rows keyed by `{scope, key}`.

Normal reads do not query PostgreSQL on every call. The effective read path
checks cached concrete rows in fallback order and only uses the definition
default when no scoped row exists.

The ETS projection stores row state, not only successful values. A row that
exists but cannot be decrypted, decoded, or validated is cached as a storage
error marker for that `{scope, key}`. Effective resolution must stop on that
marker instead of treating the row as missing and falling through to the next
scope.

The cache has no TTL by default. Configuration is a small declared surface, not
a request cache. Updates happen through AppConfigure writes and deletes.
Startup builds the ETS projection from PostgreSQL, and a cache miss may load the
single missing `{scope, key}` from PostgreSQL. There is no public refresh API:
runtime configuration changes go through AppConfigure, so the write path is the
cache invalidation path.

## Secrets

Secret values are encrypted before persistence and decrypted only into the
process-local AppConfigure cache or the immediate runtime caller.

Encryption key derivation includes an unambiguous serialized pair of `scope` and
`key`, so ciphertext from one row cannot be copied to another row and still
decrypt as a valid value.
Derivation, encryption, and decryption are kernel operations:
`Ankole.Kernel.derive_key/3`, `Ankole.Kernel.aead_encrypt/2`, and
`Ankole.Kernel.aead_decrypt/2`.

Setup and console surfaces should display secret metadata or redacted values,
not plaintext. Runtime consumers that need plaintext read through the typed
AppConfigure API.

## Generated Secrets

Generated secrets are runtime configuration behavior, not bootstrap behavior. A
definition may describe how to generate a missing value, but a generated value
is only persisted when an owning setup or write path accepts it.

Generated defaults are not silently inserted during normal reads.

## Supervision

`Ankole.AppConfigure.Cache` starts after `Ankole.Repo` and before subsystems that
consume runtime configuration at boot.

Subsystems that project AppConfigure into runtime state, such as LLM provider
bridges or I18n catalog reloads, should subscribe to explicit post-write hooks
from their owning write path.

Redis cache bootstrap reads Redis connection settings from bootstrap
configuration. It must not wait for AppConfigure.

## Invariants

- Bootstrap configuration must not depend on Repo or AppConfigure.
- AppConfigure must not read OS environment variables.
- Every AppConfigure value resolves through current agent, global, then code
  default.
- Scope lives in `app_configure.scope`, not inside the key path.
- Missing rows may inherit; invalid rows must fail visibly.
- Secret values are stored encrypted in PostgreSQL.
- Code defaults are effective values, not rows that need to be backfilled.
- Plugin settings use the same AppConfigure mechanism as core settings.
