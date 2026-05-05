# RFC 0001: Global Dynamic Configuration

- **Author**: Boris Ding
- **Created**: 2026-04-19

## 1. Purpose

Introduce a single, global configuration model for BullX that covers both:

- the existing bootstrap/config-script layer under `config/`
- the new runtime dynamic configuration layer used from application code

The resulting system must be usable from any part of BullX: `BullXWeb`, `Gateway`, `Runtime`, `Brain`, `Skills`, and any future namespace under `BullX`.

The system introduced by this RFC must satisfy the following runtime properties:

- Values resolve in this order: **PostgreSQL override -> OS environment -> application config -> default**.
- Invalid higher-priority values are **skipped**, not fatal: if a database value cannot be cast **or fails its declared Zoi constraint**, BullX falls back to the OS environment; if the OS environment value is also invalid or absent, BullX falls back to application config and then the default.
- Reads are served from **ETS-backed cache**, not direct database queries.
- Writes explicitly refresh the cache; **PostgreSQL `LISTEN/NOTIFY` is not used**.
- `.env` files are supported for bootstrapping the OS environment layer without changing the priority model above.
- Runtime settings may declare **Zoi schemas** to constrain legal values beyond primitive type casting.

This RFC introduces the configuration infrastructure itself. It does **not** attempt to migrate every existing BullX setting onto the new runtime system in one pass, but it does require that the current `config/*.exs` files become part of the same managed configuration story rather than remaining an unrelated side path.

## 2. Context

BullX currently has Phoenix's default `config/*.exs` layout:

- `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/prod.exs`, and `config/runtime.exs` together define the bootstrap behavior of the application.
- `config/runtime.exs` reads selected OS environment variables during boot.
- There is no project-level configuration library, no runtime cache, no persisted config table, and no unified API for changing config at runtime.
- Environment parsing logic is currently embedded directly in config scripts instead of being managed by a shared BullX-owned abstraction.

This RFC must also fit BullX's architectural constraints from [`AGENTS.md`](../../AGENTS.md):

- PostgreSQL is the system of record.
- Process-local state must be reconstructible on restart.
- Configuration is **cross-cutting infrastructure**, not owned by a single subsystem.

That last point is load-bearing. This RFC does **not** place configuration under `BullX.Runtime`, `BullXGateway`, or `BullXWeb`; it introduces `BullX.Config` as root-level shared infrastructure, similar in reach to `BullX.Repo`.

## 3. Design Decisions

### 3.1 One configuration system, two execution phases

BullX needs two different configuration paths:

1. **Bootstrap configuration**

   These values are needed before `BullX.Repo` and before the runtime config cache exists. Examples:

   - `BullX.Repo` connection settings
   - `BullXWeb.Endpoint` boot settings
   - `BULLX_SECRET_BASE`
   - `PORT`
   - `PHX_SERVER`

   Bootstrap configuration remains physically expressed through `config/*.exs`, because Elixir and Phoenix expect that boot path. However, after this RFC those files are no longer ad hoc; they become thin wrappers around a shared BullX-owned helper loaded from `config/support/bootstrap.exs`.

   Bootstrap configuration is allowed to read from `.env`-backed OS environment variables, but it does **not** read from PostgreSQL because the Repo has not started yet.

2. **Runtime dynamic configuration**

   These values are used after the application is booted and may be changed without restarting the node. They are the subject of this RFC and will be declared through `BullX.Config`.

This split is intentional. Any setting that is required to start the Repo or Phoenix endpoint is out of scope for the PostgreSQL-backed layer.

This RFC therefore treats the existing `config/*.exs` files as the **bootstrap branch** of BullX's unified configuration system, not as a separate legacy mechanism.

### 3.2 Existing `config/*.exs` are brought under BullX-owned management

After this RFC, the five existing config scripts remain in place:

- `config/config.exs`
- `config/dev.exs`
- `config/test.exs`
- `config/prod.exs`
- `config/runtime.exs`

But they must no longer each own their own environment parsing logic.

Instead, all environment-sensitive behavior inside those files must go through a shared helper module loaded from `config/support/bootstrap.exs`, tentatively named `BullX.Config.Bootstrap`.

That helper owns:

- dotenv file selection and loading
- typed environment parsing for bootstrap variables
- shared conventions such as environment-name mapping and precedence

This is the mechanism by which the existing Phoenix/Ecto config files become part of the unified config story.

Static compile-time literals that are not deployment-specific may remain directly in config files. Examples include:

- frontend asset tool versions and args
- tailwind version and args
- live reload regexes
- static `force_ssl` structure in `config/prod.exs`

The key rule is narrower and more useful than "move every literal out of config files":

- if a value is environment-derived, deployment-specific, duplicated across config files, or parsed from OS env, it must be routed through the shared bootstrap helper
- if a value is purely static compile-time build metadata, it may stay inline

### 3.3 Exact precedence for runtime dynamic configuration

For all runtime dynamic variables declared through the new `BullX.Config` DSL, the resolution order is:

1. `app_configs` row in PostgreSQL, cached in ETS
2. OS environment variable
3. application config (`config :bullx, ...`) for boot/static values
4. default declared in code

The application-config layer is intentionally below database and OS environment. It exists for boot/static values that are naturally expressed as Elixir terms, such as module lists or adapter child specs. Operator-editable scalar settings should still prefer the database/OS layers.

Concretely, the new DSL must generate declarations with:

- `binding_order: [BullX.Config.DatabaseBinding, BullX.Config.SystemBinding, BullX.Config.ApplicationBinding]`
- `binding_skip: [:system, :config]`
- `cached: false`

These defaults are deliberate:

- `BullX.Config.DatabaseBinding` makes PostgreSQL the highest-priority runtime source.
- `BullX.Config.SystemBinding` replaces Skogsra's built-in `:system` binding so BullX can skip invalid environment values instead of treating them as terminal failures.
- `BullX.Config.ApplicationBinding` replaces Skogsra's built-in `:config` binding so BullX can validate and skip invalid app-config values consistently.
- `binding_skip: [:system, :config]` removes Skogsra's built-in `:system` and `:config` layers so only BullX-owned bindings participate.
- `cached: false` disables Skogsra's `:persistent_term` cache for runtime dynamic variables because BullX's authoritative hot-reload cache is ETS.

### 3.4 Validation model: cast first, then Zoi

BullX runtime dynamic configuration needs two distinct validation layers:

1. **Type casting**

   Skogsra is responsible for turning raw input values into Elixir values of the declared type, for example:

   - `"42"` -> `42` for `:integer`
   - `"true"` -> `true` for `:boolean`
   - `"https://..."` -> a validated custom type if a Skogsra type module is used

2. **Value constraints**

   Zoi is responsible for constraining the resulting Elixir value to the legal domain for that setting, for example:

   - integer range checks such as `1..65_535`
   - enum-like value sets
   - URL shape and hostname requirements
   - list/map structure constraints
   - custom refinement rules

For runtime dynamic settings, the validation pipeline is:

```text
raw source value
-> Skogsra.Type.cast/2
-> Zoi.parse/2 when a zoi schema is declared
-> accept current source or fall through to next source
```

This distinction matters:

- Skogsra answers "can this source be interpreted as the right Elixir type?"
- Zoi answers "is this typed value legal for this BullX setting?"

### 3.5 Why BullX needs custom Skogsra bindings

Skogsra's extension point for custom resolution order is `Skogsra.Binding`, not a custom "provider" behaviour. This RFC therefore uses three BullX-specific bindings:

- `BullX.Config.DatabaseBinding`
- `BullX.Config.SystemBinding`
- `BullX.Config.ApplicationBinding`

Both bindings must return **raw source values**, not typed values:

- Database binding reads the raw string from ETS and returns that raw string to Skogsra.
- System binding constructs the OS env var name via `Skogsra.Env.gen_namespace/gen_app_name/gen_keys` (because `os_env/1` only generates a name when `:system` appears in `binding_order`) and reads it with `System.get_env/1`, then returns that raw string to Skogsra.
- Application binding reads `Application.get_env/2` through the declared key path and returns that value to Skogsra.

When a setting declares `zoi:`, the binding may perform a provisional `Skogsra.Type.cast(env, raw)` only so the candidate can be validated before resolution continues. The binding must **not** return the casted value, because `Skogsra.Binding` applies the authoritative cast after the binding returns. If the provisional cast or Zoi validation fails, the binding returns `nil` (the Skogsra convention for "not found, try next binding") so Skogsra continues to the next binding or the default. This is the mechanism that makes "invalid value -> skip -> fallback" deterministic for both database and OS environment inputs without breaking custom Skogsra types.

### 3.6 Why BullX disables Skogsra caching for runtime values

Skogsra's default cache uses `:persistent_term`, which is optimized for fast reads but expensive reloads. That works against this RFC's requirements:

- reads should go through BullX-owned ETS cache,
- hot reload should be cheap and predictable,
- write-path invalidation should not require `:persistent_term` churn for every variable.

Therefore, runtime dynamic variables in BullX must use `cached: false`, while BullX's own ETS cache stores only raw database overrides.

### 3.7 `.env` files belong to the OS-environment layer, not a new priority layer

This RFC does **not** add ".env" as a fourth runtime priority. Instead:

- `.env` files are loaded at the top of `config/runtime.exs`
- the resulting values are merged into the process environment
- runtime dynamic variables still see them only through `BullX.Config.SystemBinding`

This preserves the runtime model:

- database
- OS environment
- application config
- default

while still supporting `.env`, `.env.local`, `.env.dev`, `.env.test`, and `.env.prod`.

At the bootstrap phase, the same dotenv load order is also used by the shared config helper in `config/support/bootstrap.exs`, so the current `config/*.exs` files and the runtime dynamic layer observe one coherent OS-environment view.

## 4. Scope

### 4.1 In scope

- Add the dependencies needed for runtime dynamic config and dotenv support.
- Normalize the existing `config/*.exs` files so they participate in the unified BullX configuration model through a shared bootstrap helper.
- Add a new `app_configs` table.
- Add root-level `BullX.Config` infrastructure under `lib/bullx/config/`.
- Add a top-level `BullX.Config.Supervisor` under `BullX.Application`.
- Add a config-script helper under `config/support/` for dotenv loading and typed bootstrap env parsing.
- Add Zoi-backed value constraints for both runtime dynamic settings and bootstrap env parsing.
- Add narrow `type: :generated_secret` support for control-plane configuration surfaces that must create a secret on behalf of an external platform.
- Add test coverage for:
  - database > env > application config > default precedence
  - invalid database value falling back to env/application config/default
  - invalid environment value falling back to default
  - Zoi-invalid database or env values falling back correctly for runtime dynamic settings
  - explicit cache refresh on write/delete
  - dotenv file merge order
  - bootstrap helper behavior used by the existing config scripts, including Zoi validation
- Add developer documentation for `.env` usage and the new runtime config model.

### 4.2 Out of scope

- A control-plane UI for browsing or editing config values.
- KMS integration or external secret-management services.
- PostgreSQL `LISTEN/NOTIFY`.
- Cross-node cache invalidation across a multi-node BullX cluster. BullX does not support multi-node deployments in this RFC; single-node operation is the only supported topology. Multi-node is deferred to a future RFC.
- Migrating every existing BullX setting to the new runtime DSL.
- A full declaration registry that lets arbitrary raw database writes be validated against all known setting schemas before persistence.

The low-level writer stores raw strings for plain settings and AEAD-encrypted ciphertext for secret settings. Type casting and Zoi validation happen on **read** through the runtime resolution pipeline, and on **bootstrap parse** through the shared config helper.

## 5. Dependencies

`mix.exs` is modified as follows:

- **Add** `{:skogsra, "~> 2.5"}`
- **Add** `{:dotenvy, "~> 1.1"}`
- **Add** `{:zoi, "~> 0.17"}`
- **Keep** the existing `:ecto_sql` and `:postgrex` entries as-is

This RFC must not downgrade or duplicate BullX's existing Ecto/PostgreSQL dependencies. The project already depends on `:ecto_sql` and `:postgrex`.

## 6. Target Structure

After this RFC, the repo contains the following new or modified files:

```text
lib/bullx/
├── application.ex                        (MODIFIED)
├── config.ex                             (NEW — shared DSL + facade)
└── config/
    ├── app_config.ex                     (NEW — Ecto schema)
    ├── application_binding.ex            (NEW — application config Skogsra binding)
    ├── cache.ex                          (NEW — ETS-backed cache process)
    ├── crypto.ex                         (NEW — AEAD encrypt/decrypt for secret values)
    ├── database_binding.ex               (NEW — PostgreSQL/ETS Skogsra binding)
    ├── generated_secret.ex               (NEW — generated secret helper and type)
    ├── secret_keys.ex                    (NEW — compile-time secret key registry)
    ├── secrets.ex                        (NEW — bootstrap-only declarations in the shared DSL)
    ├── supervisor.ex                     (NEW — top-level config supervisor)
    ├── system_binding.ex                 (NEW — strict OS-env Skogsra binding)
    ├── validation.ex                     (NEW — shared cast + Zoi validation helpers)
    └── writer.ex                         (NEW — persistence + refresh API)

config/
├── config.exs                            (MODIFIED)
├── dev.exs                               (MODIFIED)
├── prod.exs                              (MODIFIED)
├── runtime.exs                           (MODIFIED)
├── test.exs                              (MODIFIED)
└── support/
    └── bootstrap.exs                     (NEW — shared bootstrap helper for config scripts)

mix.exs                                   (MODIFIED)
.gitignore                                (MODIFIED)
.env.example                              (NEW)

priv/repo/migrations/
└── <timestamp>_create_app_configs.exs    (NEW)

test/bullx/
├── application_test.exs                  (MODIFIED)
└── config/
    ├── cache_test.exs                    (NEW)
    ├── dotenv_test.exs                   (NEW)
    ├── generated_secret_test.exs         (NEW)
    ├── precedence_test.exs               (NEW)
    └── writer_test.exs                   (NEW)

test/support/bullx/config/
└── test_settings.ex                      (NEW — test-only declaration module)

README.md                                 (MODIFIED)
README.zh-Hans.md                         (MODIFIED)
README.ja.md                              (MODIFIED)
```

No Phoenix UI file under `lib/bullx_web/` is touched by this RFC.

The five existing files under `config/` remain first-class citizens; they are not deleted or bypassed.

## 7. Module Specifications

### 7.1 `BullX.Config`

`lib/bullx/config.ex` is the global public entrypoint for runtime dynamic configuration.

It has three responsibilities:

1. Provide the shared DSL for declaring BullX runtime settings.
2. Expose a small facade over write/refresh operations.
3. Serve as the root namespace for future domain-specific config modules such as `BullX.Config.Gateway`, `BullX.Config.Runtime`, or `BullX.Config.Web`.

The module shape should be:

```elixir
defmodule BullX.Config do
  @moduledoc """
  Global runtime configuration infrastructure shared by all BullX modules.

  Runtime settings declared through this namespace resolve in the following
  order: PostgreSQL override, OS environment, application config, then code
  default.

  Settings declared with `secret: true` are stored encrypted at rest.
  `BullX.Config.put/2` encrypts transparently; reads from ETS always return
  plaintext.
  """

  defmacro __using__(_opts) do
    quote do
      use Skogsra
      import BullX.Config, only: [bullx_env: 1, bullx_env: 2]
      Module.register_attribute(__MODULE__, :bullx_secret_keys, accumulate: true)
      @before_compile BullX.Config
    end
  end

  defmacro __before_compile__(env) do
    secret_keys = Module.get_attribute(env.module, :bullx_secret_keys) || []
    quote do
      def __bullx_secret_keys__, do: unquote(secret_keys)
    end
  end

  defmacro bullx_env(name, opts \\ []) do
    {key, opts} = Keyword.pop(opts, :key, name)
    {secret, opts} = Keyword.pop(opts, :secret, false)

    merged_opts =
      Keyword.merge(
        [
          binding_order: [
            BullX.Config.DatabaseBinding,
            BullX.Config.SystemBinding,
            BullX.Config.ApplicationBinding
          ],
          binding_skip: [:system, :config],
          cached: false
        ],
        opts
      )

    db_key = compute_db_key(key)

    secret_ast =
      if secret do
        quote do: @bullx_secret_keys(unquote(db_key))
      end

    quote do
      unquote(secret_ast)
      app_env(unquote(name), :bullx, unquote(key), unquote(merged_opts))
    end
  end

  def put(key, value), do: BullX.Config.Writer.put(key, value)
  def delete(key), do: BullX.Config.Writer.delete(key)
  def refresh(key), do: BullX.Config.Cache.refresh(key)
  def refresh_all, do: BullX.Config.Cache.refresh_all()

  defp compute_db_key(key) do
    key_parts = key |> List.wrap() |> Enum.map(&Atom.to_string/1)
    Enum.join(["bullx" | key_parts], ".")
  end
end
```

Important constraints:

- This module is a **shared root namespace**, not a subsystem module.
- Future runtime config declaration modules must `use BullX.Config`, not raw `use Skogsra`.
- The public BullX DSL is intentionally **single-name**: the generated function name and BullX config key are the same by default. An optional `key:` escape hatch exists for rare cases, but redundant `function_name, keys` pairs are not the normal authoring model.
- The DSL must support an optional `zoi:` option whose value is a Zoi schema or a zero-arity function returning a Zoi schema.
- The DSL must support an optional `secret: true` flag. When set, `BullX.Config.put/2` encrypts the value before storage and the cache decrypts it on load. The encryption is transparent to all consumers — reads always return plaintext.
- The DSL must support the BullX-specific type alias `type: :generated_secret`. `BullX.Config` expands this alias to `BullX.Config.GeneratedSecret` before delegating to Skogsra.
- This RFC does **not** add production settings yet; end-to-end behavior is proven through a test-only declaration module in `test/support`.

Example declaration:

```elixir
defmodule BullX.Config.Runtime do
  use BullX.Config

  @envdoc false
  bullx_env :max_upload_size,
    type: :integer,
    default: 10_485_760,
    zoi: Zoi.integer() |> Zoi.min(1) |> Zoi.max(104_857_600)
end
```

### 7.2 `config/support/bootstrap.exs`

Add `config/support/bootstrap.exs`, loaded via `Code.require_file/2` from the existing config scripts.

This file defines the bootstrap helper module, tentatively:

```elixir
defmodule BullX.Config.Bootstrap do
  def load_dotenv!(opts)
  def env_string(name, default \\ nil)
  def env_integer(name, default \\ nil)
  def env_boolean(name, default \\ nil)
  def env!(name, parser)
  def validate!(value, opts)
  def profile_name(config_env)
end
```

The exact helper API may differ slightly, but the responsibilities are fixed:

- load the appropriate `.env*` files
- map `config_env()` to BullX dotenv profile names
- provide typed env parsing for bootstrap values
- support optional `zoi:` validation for bootstrap values
- centralize all direct `System.get_env/1` access used by `config/*.exs`

Important constraint:

- after this RFC, config scripts must not contain ad hoc `System.get_env/1` lookups or duplicated parsing logic
- bootstrap env lookups in `config/*.exs` must go through `BullX.Config.Bootstrap`

This requirement is what "support existing config files under unified config management" means in practice.

Bootstrap helper semantics:

- if a required bootstrap value is missing, it raises
- if a bootstrap value is present but fails parsing or Zoi validation, it raises with a contextual error
- if an optional bootstrap value is missing, the declared default is used

### 7.3 `BullX.Config.Supervisor`

`lib/bullx/config/supervisor.ex` is a normal top-level supervisor with exactly one child in this RFC:

- `BullX.Config.Cache`

Its presence is deliberate even with a single child, because configuration is global infrastructure and will likely gain additional workers later.

### 7.4 `BullX.Config.Validation`

`lib/bullx/config/validation.ex` centralizes Zoi validation so the same rules are applied by:

- `BullX.Config.DatabaseBinding`
- `BullX.Config.SystemBinding`
- `BullX.Config.ApplicationBinding`
- `BullX.Config.Bootstrap`

Required responsibilities:

- extract `:zoi` metadata from a Skogsra env or caller opts
- normalize either a direct Zoi schema or a zero-arity function returning a schema
- run `Zoi.parse/2`
- expose a helper for validating a raw runtime source when a binding needs to probe a candidate before returning the raw value to Skogsra
- return `{:ok, value}` on success
- return `{:error, :invalid}` for runtime fallback paths
- raise a descriptive error for bootstrap fail-fast paths

This module exists to prevent the same Zoi resolution and error-shaping logic from being duplicated across bindings and config scripts.

**Default value and Zoi:** Skogsra returns the declared `default:` value directly when all bindings fail, without passing it through Zoi. A `default:` that violates the declared Zoi constraint is therefore a silent coding error — it will be returned as-is and will not be caught at runtime. Declaration authors are responsible for ensuring that the default satisfies the constraint. There is no compile-time enforcement in this RFC.

### 7.5 `BullX.Config.AppConfig`

`lib/bullx/config/app_config.ex` defines the persisted row shape:

```elixir
defmodule BullX.Config.AppConfig do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "app_configs" do
    field :value, :string
    field :type, Ecto.Enum, values: [:plain, :secret], default: :plain
    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:key, :value, :type])
    |> validate_required([:key, :value])
  end
end
```

The migration creates:

- table name: `app_configs`
- primary key: `key`, type `:text`
- `value`, type `:text`, `null: false`
- `type`, a PostgreSQL enum `app_config_type` with values `'plain'` and `'secret'`, `null: false`, `default: 'plain'`
- `inserted_at` and `updated_at`, type `:utc_datetime`

### 7.5a `BullX.Config.Crypto`

`lib/bullx/config/crypto.ex` provides AEAD encrypt/decrypt for secret `app_configs` rows.

- Uses `BullX.Ext.aead_encrypt/2` and `BullX.Ext.aead_decrypt/2` (XChaCha20-Poly1305 NIF).
- Derives a per-key cipher key using `BullX.Ext.derive_key/3` with `BULLX_SECRET_BASE`, sub-key prefix `"app_configs/<db_key>"`, and context `"value"`.
- Returns `{:ok, binary()}` on success, `{:error, reason}` on failure.

### 7.5b `BullX.Config.SecretKeys`

`lib/bullx/config/secret_keys.ex` provides a runtime query for whether a DB key was declared with `secret: true`.

- Lazily scans `:code.all_loaded()` for any module under the `BullX.Config.*` namespace that exports `__bullx_secret_keys__/0`.
- Collects all returned key strings into a `MapSet` cached in `:persistent_term`.
- Exposes `secret?(key) :: boolean()`.

The `__bullx_secret_keys__/0` function is generated on every `use BullX.Config` module by the `@before_compile BullX.Config` callback. It returns the list of DB key strings that were declared with `secret: true` in that module.

### 7.5c `BullX.Config.GeneratedSecret`

`lib/bullx/config/generated_secret.ex` provides the implementation behind the BullX DSL type `:generated_secret`.

A generated secret is a value BullX creates for an external platform to verify BullX-originated configuration such as a webhook verifier. The operator supplies the platform credential; BullX supplies the generated secret.

Declaration contract:

```elixir
bullx_env :external_webhook_secret_token,
  type: :generated_secret,
  secret: true
```

`type: :generated_secret` defines generation and validation semantics. `secret: true` is orthogonal: it controls encryption at rest, write-only public payload behavior, and redaction.

Required API:

```elixir
defmodule BullX.Config.GeneratedSecret do
  use Skogsra.Type

  @spec generate(keyword()) :: String.t()
  def generate(opts \\ [])

  @impl Skogsra.Type
  def cast(value)
end
```

Required behavior:

- `generate/1` creates a high-entropy URL-safe string from cryptographic random bytes.
- The default entropy is at least 256 bits.
- `cast/1` accepts only non-empty binary values that satisfy the generated-secret character and length constraints.
- `cast/1` does **not** generate missing values.
- Missing generated secrets are filled by the owning control-plane normalization path before persistence, not by runtime reads.
- Generated secrets that are persisted through `BullX.Config.put/2` are encrypted whenever their containing config key is declared with `secret: true`.

Configuration surfaces that need field descriptors expose the generated-secret type directly:

```elixir
%{
  "path" => ["transport", "secret_token"],
  "type" => :generated_secret,
  "secret" => true
}
```

Semantics:

- `type: :generated_secret` means the UI must not render the field as an operator-supplied credential.
- `secret: true` means the field is write-only after persistence and is redacted in public payloads.
- A UI may expose copy and rotate actions for generated secrets. Rotation calls `BullX.Config.GeneratedSecret.generate/1`; it does not accept arbitrary replacement text.
- Derived values such as callback URLs remain read-only information outside the persisted config value.

### 7.6 `BullX.Config.Cache`

`lib/bullx/config/cache.ex` is the ETS-backed cache owner.

Responsibilities:

- create a named ETS table on boot,
- load all database overrides into ETS during `init/1`,
- expose read access for bindings,
- expose explicit refresh functions for write-path invalidation.

Required behavior:

- Table name: `:bullx_config_db`
- ETS options: `[:named_table, :protected, read_concurrency: true]`
- Read API:
  - `get_raw(key) :: {:ok, binary()} | :error`
- Refresh API:
  - `refresh(key) :: :ok`
  - `refresh_all() :: :ok`

Implementation notes:

- `refresh/1` must reload exactly one key from PostgreSQL and either update or delete the ETS entry.
- `refresh_all/0` must reload the full table.
- Reads must never hit the database directly.
- Because the ETS table is `:protected`, only the owning `Cache` process may write to it. `refresh/1` and `refresh_all/0` must be implemented as `GenServer.call/2` so that callers can rely on the refresh having completed before the call returns.
- `get_raw/1` must return `:error` rather than raising if the ETS table does not yet exist (for example during the window between a `Cache` crash and its restart). Concretely, wrap the `:ets.lookup` call in a `try/rescue` that catches `ArgumentError` and returns `:error`.
- If the database query in `init/1` fails — for example because the `app_configs` table does not yet exist when the application starts before migrations have run — the cache must log a warning and start with an empty ETS table rather than crashing. In the degraded state the database source is silently absent; every variable resolves through OS environment, application config, and then its code default until the application is restarted after a successful migration.
- When loading a row with `type: :secret`, the Cache must decrypt the stored ciphertext using `BullX.Config.Crypto.decrypt/2` before writing the plaintext to ETS. ETS always holds plaintext; all consumers read plaintext regardless of how the value is stored. If decryption fails, the key is deleted from ETS (not inserted with ciphertext) and a warning is logged.

### 7.7 `BullX.Config.DatabaseBinding`

`lib/bullx/config/database_binding.ex` implements `Skogsra.Binding`.

Responsibilities:

- derive the BullX database key from `Skogsra.Env`,
- read the raw value from ETS,
- cast it according to the declared Skogsra type,
- validate the casted value against the declared Zoi schema when present,
- return `{:error, :invalid}` when either step fails so resolution can continue.

Required key format:

- application prefix: `bullx`
- separator: `.`
- examples:
  - `bullx.test_integer`
  - `bullx.gateway_webhook_timeout_ms`
  - `bullx.runtime_max_concurrency`

The binding must derive the database key as:

```text
<app_name>.<key>
```

where `app_name` is `:bullx` and `key` comes from the BullX config declaration.

The binding must **never** call `String.to_atom/1`.

Required behavior sketch:

```elixir
def get_env(%Skogsra.Env{} = env, _state) do
  key = to_db_key(env)

  case BullX.Config.Cache.get_raw(key) do
    {:ok, raw} ->
      case BullX.Config.Validation.validate_runtime_raw(env, raw) do
        :ok ->
          {:ok, raw}

        {:error, :invalid} ->
          nil
      end

    :error ->
      nil
  end
end
```

### 7.8 `BullX.Config.SystemBinding`

`lib/bullx/config/system_binding.ex` also implements `Skogsra.Binding`.

This is a strict replacement for Skogsra's built-in `:system` binding for BullX runtime dynamic variables.

Responsibilities:

- construct the OS env name with `Skogsra.Env.gen_namespace/gen_app_name/gen_keys`,
- read the raw string with `System.get_env/1`,
- when `zoi:` is declared, provisionally cast the raw value so it can be validated,
- return `{:ok, raw}` on success so Skogsra performs the final cast,
- return `nil` instead of terminally failing when the env value is malformed.

This module is what makes these runtime flows valid:

1. database value malformed -> try OS env
2. database missing -> malformed OS env -> use default

Without this custom binding, BullX cannot guarantee the "skip invalid value and continue" requirement.

### 7.9 `BullX.Config.ApplicationBinding`

`lib/bullx/config/application_binding.ex` implements `Skogsra.Binding` for boot/static values stored in application config.

Responsibilities:

- follow the declared Skogsra key path against `Application.fetch_env/2`,
- support nested keyword-list and map paths,
- validate candidate values through `BullX.Config.Validation.validate_runtime_raw/2`,
- return `nil` instead of terminally failing when the configured value is malformed.

This binding is what lets domain-specific modules such as `BullX.Config.Gateway` expose complex static values without direct `Application.get_env/2` calls in subsystem code.

### 7.10 `BullX.Config.Writer`

`lib/bullx/config/writer.ex` is the only supported write path for persisted config.

Required API:

- `put(key, value) when is_binary(key) and is_binary(value)`
- `delete(key) when is_binary(key)`

Required behavior:

- `put/2`
  - checks `BullX.Config.SecretKeys.secret?/1` to determine storage type
  - if secret: encrypts value with `BullX.Config.Crypto.encrypt/2`, stores ciphertext, sets `type: :secret`
  - if plain: stores value as-is, sets `type: :plain`
  - upserts into `app_configs` (conflict target: primary key)
  - replaces `value`, `type`, and `updated_at` on conflict
  - refreshes the key in ETS after commit
- `delete/1`
  - deletes the row by primary key
  - refreshes the key in ETS after delete

The encryption decision is driven entirely by the `bullx_env` declaration (`secret: true`). Call sites always use `BullX.Config.put/2` and do not need to know whether a key is secret.

Important non-goal:

- `Writer` does not validate the value against a declared type at write time.
- `Writer` does not resolve Zoi schemas before persistence.
- `Writer` does not generate missing generated secrets.
- Invalid strings may be persisted; they are ignored at read time by the bindings.

Generated secret creation belongs to the control-plane boundary that owns the configuration shape. That boundary must generate or rotate the value before calling `BullX.Config.put/2`.

**Known limitation:** `put/2` and `delete/1` call `Cache.refresh/1` after the database operation. If `BullX.Config.Cache` is in a crash-restart cycle at that moment, the refresh call will fail and the database and ETS cache will be transiently inconsistent. The inconsistency self-heals on the next `Cache` restart because `init/1` reloads all rows from PostgreSQL. No retry or rollback logic is required in `Writer`.

### 7.10 Bootstrap dotenv behavior

The bootstrap helper in `config/support/bootstrap.exs` must map BullX environments to dotenv filenames as follows:

| `config_env()` | dotenv profile |
| --- | --- |
| `:dev` | `dev` |
| `:test` | `test` |
| `:prod` | `prod` |
| anything else | `Atom.to_string(config_env())` |

The merge order for files must be:

### Development

1. `.env`
2. `.env.dev`
3. `.env.local`
4. existing `System.get_env()`

### Test

1. `.env`
2. `.env.test`
3. existing `System.get_env()`

### Production

1. `.env`
2. `.env.prod`
3. existing `System.get_env()`

This means:

- `.env.local` is supported, but only for local development.
- later `.env*` files override earlier `.env*` files before the merged result is applied to the process environment.
- exported shell variables always win over file-based values.
- `.env` values become part of the OS environment layer seen by runtime dynamic config.

The implementation must use `Dotenvy.source!/2` with:

- `require_files: false`
- a side effect that writes merged values into the process environment

### 7.11 `config/*.exs`

All existing config scripts must require the shared bootstrap helper before reading environment values:

```elixir
Code.require_file("support/bootstrap.exs", __DIR__)
```

Expected usage pattern:

- `config/runtime.exs` uses `BullX.Config.Bootstrap.load_dotenv!/1` and typed env helpers
- `config/dev.exs`, `config/test.exs`, and `config/prod.exs` remain the environment-specific composition layer for Phoenix/Ecto defaults
- `config/config.exs` remains the compile-time common layer

The RFC does **not** require extracting every static compile-time literal from these files. It does require that their environment-dependent behavior be standardized through the bootstrap helper.

### 7.12 `config/runtime.exs`

`config/runtime.exs` must be modified in two ways:

1. At the very top, before any `System.get_env/1` lookups, load dotenv values:

```elixir
BullX.Config.Bootstrap.load_dotenv!(
  root: Path.expand("..", __DIR__),
  env: config_env()
)
```

2. Continue to configure bootstrap settings directly from the OS environment for all environments where appropriate.

The existing environment-specific config files remain the fallback for bootstrap settings in `dev` and `test`, but `runtime.exs` may overlay them when OS env values are present.

Examples of valid bootstrap behavior after this RFC:

- `.env.local` can define `PORT=4100` in development and the endpoint uses it.
- `.env.test` can define `POOL_SIZE=5` for tests.
- exported shell variables such as `PORT=4200 mix phx.server` override all `.env*` files.
- production still raises on missing required boot variables such as `DATABASE_URL` and `BULLX_SECRET_BASE`.
- bootstrap values such as `PORT` may additionally be constrained with Zoi, for example to `1..65_535`

Bootstrap parsing is intentionally **fail-fast**. The "invalid value falls back to the next layer" rule in this RFC applies to **runtime dynamic settings**, not to mandatory boot-time values.

### 7.13 Existing Phoenix/Ecto settings remain supported

This RFC must preserve support for the values already represented in BullX's current config files, including at least:

- `BullX.Repo` settings
- `BullXWeb.Endpoint` settings
- logger settings
- Swoosh adapter settings
- Phoenix framework settings already present in `config/config.exs`, `dev.exs`, `test.exs`, and `prod.exs`

Support here means:

- these settings continue to work after the refactor
- any env-derived portion of their configuration flows through `BullX.Config.Bootstrap`
- any bootstrap setting that needs a legal-value constraint may use Zoi in that helper path
- settings that are bootstrap-only remain bootstrap-only; they are not forced into the PostgreSQL-backed runtime layer

## 8. Application Tree

`BullX.Application.start/2` must include `BullX.Config.Supervisor` as a top-level child.

The child order must become:

```elixir
children = [
  BullXWeb.Telemetry,
  BullX.Repo,
  BullX.Config.Supervisor,
  {DNSCluster, query: Application.get_env(:bullx, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: BullX.PubSub},
  BullX.Skills.Supervisor,
  BullXBrain.Supervisor,
  BullX.Runtime.Supervisor,
  BullXGateway.CoreSupervisor,
  BullXWeb.Endpoint
]
```

The placement is deliberate:

- `BullX.Config.Supervisor` must start after `BullX.Repo`
- it must start before any subsystem or endpoint that may eventually consume runtime dynamic configuration

## 9. Tests

### 9.1 Test-only declaration module

Add `test/support/bullx/config/test_settings.ex` with a small config module that uses the real BullX DSL:

```elixir
defmodule BullX.Config.TestSettings do
  use BullX.Config

  @envdoc false
  bullx_env :test_integer,
    type: :integer,
    default: 10,
    zoi: Zoi.integer() |> Zoi.min(1) |> Zoi.max(20)

  @envdoc false
  bullx_env :test_boolean,
    type: :boolean,
    default: false

  @envdoc false
  bullx_env :test_mode,
    type: :binary,
    default: "safe",
    zoi: Zoi.enum(["safe", "fast", "strict"])

  @envdoc false
  bullx_env :test_generated_secret,
    type: :generated_secret,
    secret: true
end
```

No production code should depend on this module. It exists only to exercise the real runtime dynamic config pipeline in tests.

### 9.2 `test/bullx/config/precedence_test.exs`

This file must prove:

- valid database override beats env and default
- malformed database override falls back to env
- Zoi-invalid database override falls back to env
- Zoi-invalid env override falls back to default
- missing database override with malformed env falls back to default
- missing database override with missing env uses default
- custom Skogsra types resolve correctly from both the database binding and the OS-environment binding

These tests should use `BullX.DataCase` because they depend on `BullX.Repo`.

**ETS isolation:** ETS is not reset by the database sandbox. Each test that writes to `app_configs` must restore ETS state on exit. The recommended pattern is an `on_exit` hook that calls `BullX.Config.Cache.refresh_all/0`; after the sandbox rolls back the database transaction, `refresh_all/0` re-syncs ETS from the now-empty database view.

**Database sandbox visibility:** `BullX.Config.Cache` is a long-running process that uses its own database connection outside the test sandbox transaction. To make a test's `app_configs` insert visible to `Cache.refresh/1`, the test setup must explicitly allow the cache process to participate in the sandbox:

```elixir
setup do
  Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), GenServer.whereis(BullX.Config.Cache))
  on_exit(fn -> BullX.Config.Cache.refresh_all() end)
  :ok
end
```

Without `Sandbox.allow`, `Cache.refresh/1` reads from its own connection and sees the pre-test database state, causing precedence assertions to fail silently.

### 9.3 `test/bullx/config/cache_test.exs`

This file must prove:

- the ETS table is populated on boot
- `refresh/1` updates a changed row
- `refresh/1` deletes a removed row
- `refresh_all/0` reloads the table

### 9.4 `test/bullx/config/writer_test.exs`

This file must prove:

- `BullX.Config.Writer.put/2` upserts into the database and refreshes ETS
- `BullX.Config.Writer.delete/1` deletes and refreshes ETS
- `BullX.Config.put/2` and `BullX.Config.delete/1` delegate correctly

### 9.5 `test/bullx/config/dotenv_test.exs`

This file must exercise the bootstrap helper with temporary `.env*` files and prove:

- development load order is `.env -> .env.dev -> .env.local -> existing system env`
- test load order is `.env -> .env.test -> existing system env`
- `.env.local` is ignored in test mode
- typed bootstrap env readers parse expected values and fail fast on malformed required values
- bootstrap helpers can apply Zoi constraints and raise on Zoi-invalid values

The tests must restore all modified environment variables on exit.

### 9.6 `test/bullx/application_test.exs`

Modify the existing file to add a new assertion that:

- `BullX.Config.Supervisor` is running
- `BullX.Config.Cache` is running

Do **not** add `BullX.Config.Supervisor` to the existing "zero children" assertion; unlike the empty subsystem supervisors from RFC-0, it intentionally has one child in this RFC.

### 9.7 `test/bullx/config/generated_secret_test.exs`

This file must prove:

- `BullX.Config.GeneratedSecret.generate/1` returns a non-empty URL-safe binary.
- generated values contain at least 256 bits of entropy by default.
- `BullX.Config.GeneratedSecret.cast/1` accepts generated values.
- `cast/1` rejects empty, malformed, or too-short values.
- `cast/1` does not create a replacement value when input is missing.
- a `bullx_env` declaration with `type: :generated_secret` uses `BullX.Config.GeneratedSecret` for casting.

## 10. Documentation

### 10.1 `.env.example`

Add `.env.example` at repo root with representative bootstrap variables only, for example:

```dotenv
# Phoenix / endpoint
PORT=4000
PHX_SERVER=true

# Ecto / PostgreSQL
DATABASE_URL=ecto://postgres:postgres@localhost/bullx_dev
POOL_SIZE=10

# Secrets
BULLX_SECRET_BASE=replace-me
```

This file is documentation, not a secret-bearing file.

### 10.2 `.gitignore`

Adjust `.gitignore` so that repo-root `.env.local` is ignored explicitly.

This RFC does **not** require ignoring `.env`, `.env.dev`, or `.env.test`; those files may contain non-secret team defaults and may be committed if desired.

### 10.3 READMEs

Update the English, Simplified Chinese, and Japanese READMEs with:

- the new `.env` support
- the load order of `.env`, `.env.dev`, `.env.test`, and `.env.local`
- a short explanation of bootstrap config vs runtime dynamic config
- that runtime settings may declare legal-value constraints with Zoi in addition to primitive types
- that the existing `config/*.exs` files are still the bootstrap entrypoints, now standardized through shared BullX config helpers
- an example of editing a dynamic value through `BullX.Config.put/2`

The README text must be high-level; the RFC remains the source of implementation detail.

## 11. Non-Goals and Invariants

The executing agent must not:

- place the config infrastructure under `BullX.Runtime`, `BullXGateway`, or `BullXWeb`
- use PostgreSQL `LISTEN/NOTIFY`
- read runtime dynamic settings directly from the database on every call
- leave Skogsra runtime variables on `cached: true`
- rely on Skogsra's built-in `:config` binding for runtime dynamic settings
- call `String.to_atom/1` on database keys
- introduce Phoenix UI work under `lib/bullx_web/`
- leave direct `System.get_env/1` parsing duplicated across `config/*.exs`
- duplicate Zoi validation logic instead of routing it through shared config validation helpers
- generate random configuration values from Skogsra cast/read paths

The executing agent must preserve these invariants:

- `BullX.Config` is root-level shared infrastructure
- the existing `config/*.exs` files remain the bootstrap branch of that infrastructure
- bootstrap settings are configured before Repo start and do not depend on PostgreSQL-backed config
- runtime dynamic settings resolve in exactly this order: database, OS env, application config, default
- runtime dynamic settings may additionally constrain legal values with Zoi after type casting
- runtime dynamic config reads are served from ETS
- write-path refresh is explicit and local to the node; multi-node deployments are not supported and `BullX.Config.put/2` makes no guarantees about other nodes
- generated secrets are created by explicit control-plane write paths, then persisted and redacted like other secrets

**Multi-node note:** In a hypothetical multi-node deployment, `BullX.Config.put/2` refreshes only the calling node's ETS cache. Other nodes continue serving stale values until restarted or explicitly refreshed. This is a known non-goal. Operators running multi-node BullX must restart all nodes after a config change, or wait for a future RFC that addresses cross-node invalidation.

## 12. Acceptance Criteria

A coding agent has completed this RFC when all of the following hold:

1. `mix deps.get` adds `skogsra`, `dotenvy`, and `zoi`, and does not duplicate or downgrade existing `:ecto_sql` / `:postgrex` dependencies.
2. `mix ecto.migrate` creates the `app_configs` table with the schema described in §7.3.
3. `mix compile --warnings-as-errors` succeeds.
4. `mix format --check-formatted` succeeds.
5. `mix test` passes, including the new precedence, cache, writer, and dotenv tests.
6. `mix precommit` passes end-to-end.
7. Starting BullX in development with only `.env.local` present correctly affects bootstrap settings loaded from `config/runtime.exs`.
8. For a runtime dynamic variable declared with `bullx_env`, a malformed database override falls back to a valid OS environment value.
9. For a runtime dynamic variable declared with `bullx_env`, a malformed OS environment value falls back to the code default.
10. The application supervision tree contains `BullX.Config.Supervisor` between `BullX.Repo` and the subsystem supervisors.
11. The existing files under `config/` still drive BullX bootstrap behavior, but all env-derived logic inside them is routed through the shared bootstrap helper rather than scattered direct parsing.
12. For a runtime dynamic variable declared with `bullx_env` and a `zoi:` schema, a Zoi-invalid database or environment value is rejected and the next fallback source is used.
13. For a bootstrap value loaded through `BullX.Config.Bootstrap`, a Zoi-invalid value raises a descriptive startup error instead of being silently accepted.
14. `BullX.Config.GeneratedSecret.generate/1` creates valid high-entropy generated secrets, `cast/1` validates but never generates values, and `type: :generated_secret` is usable from the BullX config DSL.

If any criterion fails, the RFC is not complete.
