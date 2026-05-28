# Configuration

BullX configuration has two layers:

- bootstrap configuration read by Phoenix/Mix config before the application
  starts;
- runtime configuration declared with `BullX.Config` and optionally stored in
  PostgreSQL.

The implementation lives in `BullX.Config.*`.

## Bootstrap Config

`config/support/bootstrap.exs` loads dotenv files and parses required
environment variables for config files. It is used from `config/*.exs` and
`config/runtime.exs`, before Repo and the runtime config cache exist.

Bootstrap config owns values that must exist before the application starts,
including:

- `DATABASE_URL`
- `BULLX_SECRET_BASE`
- Phoenix endpoint secret material
- dev/test endpoint and asset-server settings

`BULLX_SECRET_BASE` is system-only and must be at least 64 characters. Runtime
code derives encryption and Phoenix secret material from it through `BullX.Ext`.

## Runtime Declaration

Config modules call `use BullX.Config` and declare values with `bullx_env/2`.
The macro generates bang accessors such as `some_key!/0` and registers metadata
used by the config cache, writer, and secret-key audit.

A declaration can set:

- logical key path;
- OS environment variable name;
- type;
- default;
- secret handling;
- generated secret handling;
- system-only behavior.

Secret keys are collected through `__bullx_secret_keys__/0`.

## Resolution Order

Runtime values resolve in this order:

1. database value in `app_configs`, when allowed for that key;
2. OS environment variable;
3. application env;
4. code default.

System-only declarations skip the database layer.

The database key format is `bullx.<path>`.

## Persistence

`app_configs` stores:

- `key` as primary key;
- `value`;
- `type`: `plain` or `secret`;
- timestamps.

Secrets are encrypted before storage and decrypted when loaded into the config
cache. Decryption failures remove the affected cached value and surface an
error instead of returning corrupted plaintext.

## Cache

`BullX.Config.Cache` is a GenServer that owns the ETS table
`:bullx_config_db`. At startup it loads all rows from `app_configs`; if the
database is unavailable, it starts with an empty cache so the rest of the app can
continue using environment and defaults.

`BullX.Config.refresh/1` and `refresh_all/0` reload database values into ETS.

## Write Path

`BullX.Config.Writer` writes runtime config:

- `put/2`
- `put_many/1`
- `delete/1`

After writing, it refreshes the ETS cache and synchronizes ReqLLM bridge config
when relevant.

Callers should use subsystem setup/write boundaries when they exist. Direct
Config writes are for generic config surfaces and tests.

## Generated Secrets

`BullX.Config.GeneratedSecret` supports generated secret declarations. Current
setup channel-source APIs expose generated-secret plumbing, but the in-tree IM
adapters currently return no generated secret fields.

## Current Config Modules

Current core config modules include:

- `BullX.Config.AIAgent`
- `BullX.Config.CacheSettings`
- `BullX.Config.I18n`
- `BullX.Config.Plugins`
- `BullX.Config.Principals`
- `BullX.Config.ReqLLM`
- plugin config modules declared by enabled plugins

## Supervision

`BullX.Config.Supervisor` starts:

- `BullX.Config.Cache`
- `BullX.Config.ReqLLM.BootSync`
- `BullX.Cache.Bootstrap`

The app-level cache bootstrap depends on runtime config and Redis, so it runs
after the config cache process starts.

## Invariants

- Bootstrap config must not depend on Repo or runtime config cache.
- Runtime database config is cached in ETS for reads.
- Secret values are stored encrypted in PostgreSQL.
- Config declarations, not call sites, define key metadata and type behavior.
- Plugin settings use the same config mechanism as core settings.
