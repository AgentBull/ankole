# App Configuration

Ankole reads settings from two distinct sources: the process environment
provides bootstrap values needed before the node can start, while AppConfigure
stores runtime settings in PostgreSQL so operators can update them while Ankole
runs.

Every setting belongs in exactly one of these two places. Application code must
never query AppConfigure for a value that the process requires during startup.

## Settings Needed During Startup

The process environment supplies infrastructure and bootstrap settings such as:

- `DATABASE_URL` and optional `BASE_DB_URLS` URLs for physical Base shards
- `ANKOLE_FUNCTION_RUNTIME_URL` and `ANKOLE_FUNCTION_RUNTIME_TOKEN`
- root secret material such as `SECRET_KEY_BASE`
- `ANKOLE_SITE_ADMIN_CONSOLE_PATH` along with Phoenix host, port, TLS, and release-server settings
- database and HTTP connection-pool sizes
- development and test filesystem paths

Because these values configure the OS process and its underlying infrastructure,
changing any of them requires restarting the affected process. AppConfigure
cannot serve startup settings because PostgreSQL and the ETS cache may not be
running yet when the node boots.

## Settings That Operators Can Change

AppConfigure stores a declared set of runtime settings in PostgreSQL for
operators, setup flows, Ankole subsystems, and trusted Plugins. Typical
AppConfigure settings include:

- the default locale
- tenant limits on Agent execution
- plugin setup values
- chat and identity-provider settings that are not needed during bootstrap

For example, `Ankole.Pod.Config` declares the tenant key
`pod.allow_external_guests` with a default value of `true`. When an operator
sets it to `false`, Ankole rejects guest invitations, new guest shares, and Pod
access by existing Guests, without modifying any Principal's stored membership.

Domain-specific credentials and preferences live in their owning tables rather
than AppConfigure: AIGateway stores provider credentials in
`ai_gateway_providers`, and Agent model preferences live in `agents.options`.
AppConfigure is not a free-form key-value store; it rejects any key that code
has not registered.

## Declare Each Key Before Use

Each `Ankole.AppConfigure.Definition` specifies how AppConfigure validates,
stores, and exposes a single key:

- a stable key name
- a value schema
- the `encrypted` storage policy
- the ownership policy: `global` (site-wide only), `pod` (`tenant:<id>` only, falling back directly to the code default), or `tenant` (`tenant:<id>` with optional Agent overrides and site inheritance)
- an optional default value
- an optional generator
- an optional description
- the `console_writable` policy

Schemas accept only JSON-compatible values. AppConfigure validates values before
writing to PostgreSQL, after reading from storage, and when loading a code
default. During registration, the registry rejects duplicate exact keys.

## Declare a Family of Keys

Plugins can declare a `PatternDefinition` to cover a family of keys when dynamic
instance IDs make the full list of keys unknown at startup. Exact definitions
always take priority over patterns, and the registry rejects any key that
matches two different patterns. A `PatternDefinition` carries the same schema,
encryption, default, generator, scope, and Console policies as an exact
definition.

Setting `console_writable: false` restricts writes to the owning subsystem while
still allowing operators to read the current value in the Console. Use this
policy whenever a raw edit would break invariants maintained by a dedicated
workflow—for example, `principals.identity_providers.active`, which only the
identity-provider pages may update. Enforcing this rule in AppConfigure rather
than only in the browser prevents callers from bypassing the Console through the
REST API.

## How the Console Presents Keys

The Console reads and writes site values through
`/api/v2/site/app-configurations` and tenant values through
`/api/v2/app-configurations` (placing generic action arguments inside `data`).
Typed Ash actions delegate to the AppConfigure owner, which validates and stores
each value before publishing the committed entry to the cache. List and detail
responses mask encrypted values; an operator can reveal a secret only through an
authorized `POST /:key/decryptions` call.

The Console is a site-administrator surface. Pod administrators use Pod Settings
for their existing workspace administration tasks. Configuration grouping does
not grant Pod administrators Console access or scheduling-timezone permissions.

The settings page has one explicit editing context: site configuration and
defaults, or overrides for the current data workspace. It names the workspace
even when the global tenant switcher is hidden. A tenant definition's site value
is an inheritable default, not an enforced ceiling. A stored override remains
independent even when it equals its fallback.

The default task view shows operational summaries, value sources, independent
overrides, and pending runtime changes. Brain, trace export, email verification,
SMTP, external guest access, and SaaS Turnstile have combined editors. The
read-only registry view lists exact definitions, pattern policies, and existing
concrete keys with scope, encryption, source, and read-only reasons. Authorized
secret reveals remain explicit. Search matches keys, named form fields, localized
descriptions, and migrated key aliases, then opens and focuses the matching task
field. Named links open the owning Console page and its relevant tab.

`PUT /groups/:group` accepts `data.values` and `data.reset_keys`. AppConfigure
checks the closed task membership and each touched key's update or reset grant,
locks the task's keys in order, validates the complete resulting configuration,
and commits one PostgreSQL transaction. A rejected member or reset rolls back the
whole batch. Cache refresh and visitor-access broadcasts run after commit.
Individual keys remain the storage unit, while raw Console updates and resets
of grouped keys are rejected. Library default maps also reject raw writes;
Library validates Plugin and Skill existence and publishes capability changes.
The external-guest task preserves both site defaults and per-workspace emergency
administration, publishing access rechecks to the affected workspaces.

The workspace Brain editor displays the site embedding model and tokenizer as
read-only dependencies. Five actually consumed Agent override keys offer a
read-only Agent inspection route, `GET /:key/agents/:agent_uid`; AppConfigure
validates that the Agent belongs to the current data workspace before resolving
its Agent, tenant, site, or code-default source. The Console does not expose an
Agent override write through this route.

Restore confirmation displays the stored value and actual next fallback value
and source, masking secrets. It cannot proceed when fallback resolution fails.
Time controls preserve storage units while presenting readable units; output
limits and disabled inactivity timeouts have explicit controls for `null` and
`0`. Retention reductions show irreversible-purge consequences before saving.

Inside the Console UI, editor models manage drafts, client-side validation,
request payloads, and asynchronous completion checks, while TanStack Query
manages per-request state and cache
invalidation. Editor models invoke request functions supplied by the page, and
only the completion of the active request can close the editor. Decryption
responses apply only to the draft that requested them: if the operator switches
settings or edits the draft while decryption is in flight, the late response
does not overwrite the current input. Likewise, save and restore responses
advance the saved baseline without discarding edits made after the request
started. Failed task requests trigger a readback while preserving the draft.

When editing an encrypted setting through the generic editor, the UI treats the
input as an opaque string unless the entire input parses as a valid JSON object
or array. That way, secrets that happen to look like primitives or partial JSON
(such as `1234`, `true`, or `{vault-token`) are never coerced to another type by
accident, while genuine JSON objects and arrays are stored as structured data.
Any subsystem that needs a different encrypted scalar type must supply its own
dedicated editor.

## Site, Pod, and Tenant Values

Stored rows use `global`, `tenant:<tenant_id>`, `agent:<agent_uid>`, or
`system:<uid>` scopes. Each definition's ownership policy governs which scopes
AppConfigure reads and accepts:

- A `global` definition accepts only site-wide values in `site_app_configurations`
  and resolves `"global"` followed by the code default.
- A `pod` definition (such as `i18n.default_locale`) belongs strictly to a Pod
  workspace (`tenant:<tenant_id>` in `app_configurations`). AppConfigure rejects
  `global` and `agent:<uid>` reads, writes, and deletes for `pod` keys, omits
  them from the site configuration catalog, and resolves `tenant:<tenant_id>`
  followed directly by the code default without consulting site storage.
- A `tenant` definition resolves values in priority order: an Agent override
  first (when the caller passes `agent_id`), then the current tenant's value,
  then the site value, and finally the code default.

System scopes accept registered system Principal UIDs and the nine fixed
`ai_gateway.model_profiles.<slot>` keys. ModelProfiles merges those overrides
with Pod and Site slots. Provider-hosted switches and custom aliases have no
system layer.

When resolving a `pod`, `tenant`, Agent, or system Principal value, the caller
must hold an active `Ankole.Repo` tenant context (and any `agent_id` must belong
to that tenant); a request payload cannot select a different tenant.

Some namespaces narrow write access further. Identity-provider settings
(`principals.identity_providers.*`) belong strictly to `tenant:<id>` without
inheriting a site default, and the generic settings endpoints reject writes to
these keys so the identity-provider subsystem can validate platform application
assignments. Signal binding secrets use `global` scope and a key derived from
the tenant and binding ID. The binding lifecycle owns these secrets and deletes
them when the binding is removed.

The Console writes site values through `/api/v2/site/app-configurations` and
workspace values through `/api/v2/app-configurations` under the same validation
and encryption rules. Each editor has one active context. For `pod` keys,
resetting a workspace value restores the code default directly.

During fallback resolution, AppConfigure moves to the next scope tier only when
no row exists at the current tier. If a row is corrupt or cannot be decrypted,
AppConfigure returns an error rather than masking the failure with a fallback
value. `Ankole.AppConfigure.Resolution` returns both the resolved value and its
source (`agent`, `system`, `tenant`, `global`, or `default`). OS environment variables
never override an AppConfigure key.

AIGateway owns the tenant-scoped `ai_gateway.model_profiles.<slot>` and
`ai_gateway.provider_hosted.<capability>` keys. Their schemas reject `nil` rows;
the dedicated model-profile API deletes the current layer's row to restore
inheritance. Model profiles merge each slot across the Agent or system Principal,
Pod, and Site before applying cross-slot fallback. Overrides, same-slot inherited
values, and final effective values are separate read contracts. Effective entries
retain `source` and `resolved_from_profile` metadata for runtime and Console consumers.

## Feature policies

`Ankole.Features.Config` registers boolean feature flags from the build's
`:feature_flags` application configuration. Each entry has the form
`{key, [default: boolean, client_visible: boolean]}`, where both `default` and
`client_visible` default to `false`, and registers one global AppConfigure key
named `features.<key>` (the AppConfigure Registry rejects duplicates at
startup).

Every stored feature policy uses this exact JSON object:

```json
{"enabled": true, "percent": 100, "targets": {}}
```

Here, `enabled` acts as the master switch, `targets` maps OpenFeature targeting
keys to explicit boolean overrides, and `percent` is an integer from `0` through
`100`. When `enabled` is `true`, evaluation checks `targets` first and otherwise
hashes `<key>:<targeting_key>` with SHA-256 to assign a deterministic rollout
bucket—so raising `percent` preserves every target that was already enabled.
Feature policies live exclusively in site storage and reject tenant or Agent
writes.

On the backend, AppConfigure owns flag metadata and defaults, while the official
OpenFeature provider reads registered `features.<key>` entries through
AppConfigure—reading from the ETS cache for ordinary evaluations and from
PostgreSQL for `_in_tx` evaluations (which require an active database
transaction). `evaluate_details/1` returns the SDK's
`OpenFeature.EvaluationDetails` (including the flag key), and callers can also
pass an explicit context to `evaluate_details/2` or `boolean_value/2`. The
Ankole facade populates the targeting key from the current request's tenant ID,
or `"site"` when no tenant context is bound; direct calls to the official
OpenFeature SDK use the caller-supplied OpenFeature context against cached
policies and likewise fall back to `"site"` when that context omits a targeting
key. HTML shell controllers use the bound request context, and login pages bind
the transaction context through the browser authentication owner before
evaluating flags. Runtime feature checks belong to each consuming subsystem,
whereas Plugin activation is fixed by the site's immutable boot snapshot.

For browser clients, `SpaController` serializes `client_visible` feature
evaluations into the HTML shell's `ankole-features` meta element and serves the
shell with `cache-control: private, no-store`. Before the first render,
`mountApp` initializes the official OpenFeature Web provider from that embedded
snapshot so React components can read flags through standard OpenFeature hooks,
while backend endpoints still evaluate features independently at their own
operation boundaries.

## Row Format in PostgreSQL

AppConfigure separates site and tenant data into two PostgreSQL tables:

- Global rows live in the site-owned `site_app_configurations` table
  (`SiteConfig` Ash resource), where `scope` is `"global"` and `{scope, key}` is
  the natural primary key.
- Tenant, Agent, and system Principal rows live in the tenant-owned
  `app_configurations` table (`AppConfig` Ash resource), which requires
  `tenant_id` and accepts `tenant:<id>`, `agent:<uid>`, or registered
  `system:<uid>` scopes. It uses `{tenant_id, scope, key}` as its natural primary
  key and enforces tenant isolation through `Ankole.Repo` on every read and write.

Both tables store `scope`, `key`, JSONB `value`, `inserted_at`, and
`updated_at`, with PostgreSQL constraints validating both `scope` and the JSONB
envelope. On both `AppConfig` and `SiteConfig`, the `put` action resolves the
registered definition, validates scope and input, and encrypts secrets before
upserting—serving both Console requests and boot-time subsystems. AppConfigure
picks the target resource from the scope and applies scope inheritance on reads.
Internally, `Envelope` defines the stored JSON wrapper tags and shape, while
`Codec` uses that contract for schema validation and encryption so the storage
type stays decoupled from the runtime configuration service.

For Signal Bindings, the `record_platform_application` action updates public
platform identity by merging only outer JSONB metadata while leaving the
encrypted value's ciphertext untouched. Deleting configuration rows—whether one
key or in bulk—goes through the shared `remove` action.

WorkerEnv follows the exact same table split: global variables live in
`site_worker_envs`, tenant and Agent variables live in
`agent_computer_worker_envs`, AEAD encryption binds each secret to its scope and
key, and ETS cache keys and invalidation messages include the tenant ID.

In PostgreSQL, a plaintext AppConfigure value uses this envelope:

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

Each key's registered definition determines which envelope type is valid.

## How AppConfigure Protects Secrets

Before encrypting a secret, AppConfigure validates it against its schema and
serializes it to JSON. `Ankole.AppConfigure.Crypto` reads the root secret from
`Ankole.SecretKeyBase`, serializes `[scope, key]` as the key-derivation context,
and calls three Rust kernel primitives:

- `Ankole.Kernel.derive_key/3`
- `Ankole.Kernel.aead_encrypt/2`
- `Ankole.Kernel.aead_decrypt/2`

Because key derivation binds ciphertext to `[scope, key]`, copying ciphertext to
another scope or key fails decryption. Moreover, the ETS cache stores encrypted
rows in sealed form; AppConfigure decrypts a secret only when serving a typed
domain read or an authorized Console decryption request.

Principal rename moves Agent overrides within the current tenant from
`agent:<old_uid>` to `agent:<new_uid>`. AppConfigure decrypts each encrypted value
under its old scope and encrypts it under the new scope in the rename transaction;
Worker environment secrets follow the same rule through their owning subsystem.

## Read and Change Values

Subsystems read and write statically declared keys through these public
functions:

- `resolve/2` and `get/2`
- `put_global/2`
- `delete_global/1`
- `put_tenant_by_key/2`, `delete_tenant_by_key/1`, and their `_in_tx` forms
- `get_override_by_key/2` for a single layer without inheritance, including `{:system, uid}`
- `put_system_by_key/3` and `delete_system_by_key/2` for registered system model slots
- `generate/1`

Dynamic pattern keys use the corresponding `*_by_key` functions, and the
registry must match the key before the operation proceeds.

`AppConfigure` is the Ash domain for `AppConfig` and `SiteConfig`. Top-level
mutators—`update_global/2`, `update_tenant/2`, and
`ensure_generated_global/1`—execute inside `Repo.transact_top_level/2` and
refresh the cache after commit (`update_global/2` also acquires a short per-key
PostgreSQL advisory lock, so its callback must compute the replacement value
purely without external I/O). When another domain composes configuration writes
inside its own transaction, it calls the `_in_tx` variants
(`update_tenant_in_tx/2`, `put_global_by_key_in_tx/2`,
`lock_global_by_key_in_tx/1`) and invokes `cache_committed_write/1` once its
outer transaction commits. Deleting a key executes as a single SQL statement and
needs no wrapping transaction.

AppConfigure validates every value before committing, and a committed PostgreSQL
write is immediately authoritative. After commit, AppConfigure reloads the row
into ETS; if that reload fails, AppConfigure evicts the stale cache entry and
logs an error, leaving the committed database row intact for subsequent reads to
load.

Deleting a tenant row restores inheritance from the global row or code default,
and deleting a global row restores the code default if one is defined.

## Cache Behavior

`Ankole.AppConfigure.Cache` caches database rows in ETS under
`{tenant_id, scope, key}` (using `nil` as `tenant_id` for site rows), with a
five-second TTL that covers both present and absent rows.

At startup, the cache preloads site rows. On a cache miss, the caller's own
process queries PostgreSQL using its current database connection and bound
tenant context; AppConfigure writes and deletes likewise reload the affected key
in the caller's process after commit. The cache GenServer owns only invalidation
tracking and ETS publication—it never borrows a caller's database connection.
Before publishing a row loaded after a cache miss, the cache compares read start
times against refresh generations and discards any miss result that started
before a concurrent refresh, preventing stale reads from overwriting newer
writes.

Finally, the cache tracks row existence separately from schema validity: it
never treats a corrupt or invalid row in PostgreSQL as absent.

## Generate Values Only on Request

A key definition can supply a `generator` function. Calling `generate/1`
produces and validates a candidate value in memory without writing to
PostgreSQL; the setup flow or owning subsystem must explicitly persist the
accepted value, and read calls never auto-generate rows.

For example, `runtime_fabric.worker_auth_key` is a generated installation key
that stays inside the control plane to derive opaque Lark profile names (whereas
individual Worker generations use separate random credentials managed by
`AgentWorkers`). This key sets `console_writable: false` because replacing it
would invalidate existing Lark profile names.

## Custom Agent Computer Environment Variables

`WorkerEnv` manages operator-defined environment variables for Agent Computer
separately from AppConfigure. At execution time, variables layer in order: site
values first, then tenant values, then Agent values, followed by Signal binding
variables and explicit per-command variables. Every `WorkerEnv` value is a
string, and secret variables use encrypted storage.

`EnvVar` (`tenant_id/scope/name`) and `SiteEnvVar` (`scope/name`) are Ash
resources whose `put` action owns variable-name validation, secret-flag
transitions, and AEAD encryption, and whose `remove` action handles both
single-variable deletion and Agent-cleanup deletion. Updating metadata alone
preserves the existing ciphertext, while overriding an inherited secret re-seals
it under the new scope before storage. All list and runtime reads go through
these same resources, while `WorkerEnv` applies tier inheritance and masks
secrets in API responses.

Operators manage variables through `/api/v2/site/worker-envs`,
`/api/v2/worker-envs`, and `/api/v2/agents/:agent_uid/worker-envs`, where
JSON:API policies authorize secret decryption separately from ordinary reads and
writes, and typed transport actions delegate to `WorkerEnv`. AppConfigure keys
are never exported as Worker environment variables; RuntimeFabric passes
per-turn runtime facts separately under the reserved `ANKOLE_RUNTIME_` prefix,
which operator `WorkerEnv` entries cannot use.

## Task-specific application and feedback

Trace export compares saved configuration with this process's attempted boot
configuration and exporter state. The Console keeps `pending_restart` or `failed`
visible until the process actually matches the saved settings. Control Plane
Plugin status reuses the compiled Plugin registry's configured-versus-active
projection. These observations describe the serving process.

Brain tokenizer status compares the saved tokenizer with PostgreSQL's actual
shared BM25 definitions and usable flags. The one-minute Brain Tick performs
index maintenance; configuration reads perform no DDL. The health page reports
pending maintenance, rebuilding, applied, failed, or unknown state. A failed
maintenance attempt leaves its failure status until repair or a matching index
is observed. Index maintenance can interrupt retrieval and block writes; server
logs identify failed Tick jobs for recovery.

The SMTP task returns a public projection of the encrypted object and a password
presence flag. Omitting `password` preserves the saved password; an explicit
replacement or empty string replaces it. `POST /authn.email.mail/tests` requires
configuration-update permission, merges the saved password into the draft, and
uses the real Mailer transport without writing configuration or issuing an OTP.
Success means the transport accepted the message. The UI binds test feedback to
the tested draft and permits saving independently of that test.

SaaS Turnstile uses a separate `saas.turnstile.enabled` flag. Enabling requires
both valid keys in the resulting task. Disabling preserves both credentials and
does not require decrypting them.

## Storage units and consolidated policies

`authn.email.send_limits` contains `window_seconds`, `per_email`, `per_source`,
and `per_channel`; `authn.email.failure_limits` contains `window_seconds`,
`per_email`, and `per_source`. Each map is one policy with one shared time window
and independently counted dimensions. The dimensions impose no numeric ordering.

`brain.forgetting` holds five per-kind decay half-lives in days.
`brain.soft_delete_retention_hours` separately controls permanent removal of
soft-deleted Objects. Both retain tenant inheritance. Worker readiness uses
`agent_workers.ready_timeout_seconds`, rendered-fetch idle release uses
`agent_workers.rendered_fetch_idle_ttl_ms`, and the background job cap uses
`background_agent_jobs.max_running_per_agent`.

## Startup Order

The AppConfigure Registry and Cache start immediately after `Ankole.Repo`, and
all boot-time configuration consumers start after AppConfigure.

When the Registry boots (or restarts after a crash), it rebuilds every core
declaration from a single compiled catalog, and—if the Control Plane Plugin
Registry is already running—restores exact definitions and patterns from the
active Plugin boot snapshot. As a result, a Registry restart neither cascades to
unrelated consumers nor leaves the Console with an incomplete set of
declarations.

Core subsystems must list their definitions in that central catalog rather than
registering keys lazily at call time; reading or writing an unregistered
definition raises an immediate error. Plugin declarations, meanwhile, live in a
single replaceable slot in the Registry: loading a new Plugin boot snapshot
atomically swaps the entire Plugin set, removing keys from deactivated Plugins
without touching core definitions.

When an operator updates a setting that affects a running process, the owning
subsystem is responsible for applying the new value after the write commits.

## Rules

- Bootstrap configuration never depends on `Ankole.Repo` or AppConfigure.
- AppConfigure never reads OS environment variables.
- Every key matches either one exact definition or one unambiguous pattern.
- Each definition governs validation, scope, encryption, and Console writability.
- Fallback inheritance applies only when a row is absent, never when it is corrupt.
- PostgreSQL stores secrets inside AEAD-encrypted envelopes bound to `[scope, key]`.
- Code defaults act as effective fallback values without creating database rows.
- Read operations never persist generated values.
- A committed PostgreSQL transaction is the sole proof of a successful write.
- Ankole can rebuild the entire ETS cache from PostgreSQL at any time.
