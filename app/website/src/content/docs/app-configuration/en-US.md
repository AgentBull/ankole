---
title: AppConfigure
description: The operator-managed runtime configuration store — what it is, how it differs from environment variables, the scopes, the encryption, and the decrypt permission.
section: User guide
order: 43
---

AppConfigure is the database-backed runtime configuration store for Ankole. It holds the settings an operator changes through the Console while the installation is running — AI agent limits, Brain dreaming, directory sync intervals, plugin enablement, and more. This page is the operator-facing view of what AppConfigure is, how it differs from environment variables, and how to work with it.

The decisive property, stated up front: AppConfigure is **runtime-changeable, PostgreSQL-backed configuration**. It is not environment variables (which are deployment-time), and it is not a free-form key-value store (every key is declared at boot by the subsystem that owns it). Change a key through the Console, and it takes effect — for most keys immediately, for a few on the next process start.

## How it differs from environment variables

Ankole reads configuration from two places with different lifecycles:

| | Environment variables | AppConfigure |
|---|---|---|
| Lifecycle | set at process start, requires restart to change | changed through the Console at runtime |
| Storage | the deployment's `.env` or Secret | PostgreSQL (`app_configurations` table) |
| What belongs here | bootstrap secrets, database URL, ports, log level | agent settings, Brain config, plugin enablement, sync intervals |
| Encrypted | some (worker auth key) | per-key: the `encrypted` flag on each definition |

If a setting can wait until PostgreSQL is up, it belongs in AppConfigure. If it cannot — it is needed before PostgreSQL is reachable — it belongs in the environment. See [Environment variables](../environment-variables/) for the full split.

## The Console surface

AppConfigure keys are managed through four Console routes:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/app-configurations` | List console-visible entries (metadata, not encrypted values) |
| `GET` | `/app-configurations/:key` | Read one entry |
| `PUT` | `/app-configurations/:key` | Store one value |
| `DELETE` | `/app-configurations/:key` | Reset one value to its default |
| `POST` | `/app-configurations/:key/decryptions` | Reveal one encrypted value |

Listing and reading return metadata and non-encrypted values. An encrypted key's value is not returned on read — only the decrypt action reveals it, and decrypt is a separately authorized action.

## Scopes

AppConfigure entries carry a scope:

- **`global`** — one value for the entire installation. Most keys are global.
- **`agent:<uid>`** — per-agent override of a global default. A subsystem declares a key with an agent scope when individual agents need different settings.

The scope is part of the key's definition, not something the operator picks. A global key takes one value; an agent-scoped key takes a global default plus per-agent overrides.

## Encryption

Each AppConfigure definition carries an `encrypted` flag. When `true`:

- The value is encrypted at rest in PostgreSQL, using the kernel-backed AEAD primitive.
- The `GET` route does not return the value — it returns metadata only.
- The `POST .../decryptions` route reveals the value, and it is a separately authorized action (distinct from `read`).

This is the same model as [WorkerEnv secrets](../worker-env/) — but AppConfigure is for subsystem-owned configuration, while WorkerEnv is for the agent's shell environment.

## The keys an operator touches

The full list is in [Environment variables](../environment-variables/) under "AppConfigure keys." The ones operators touch most often:

- **AI agent limits** — `ai_agent.max_iterations`, `max_output_tokens`, `inactivity_timeout_ms`
- **Brain** — `brain.dreaming`, `brain.knowledge`, `brain.embedding`, `brain.search`, `brain.sources`
- **Plugins** — `plugins.enabled_ids` (takes effect on next start)
- **Directory sync** — `principals.identity_providers.directory_full_sync_interval_hours`
- **SSRF** — `security.ssrf_filter`
- **Background jobs** — `agent_computer.background_agent_job.max_turns_per_worker`

## When changes take effect

- **Most keys** take effect immediately — the next read picks up the new value.
- **`plugins.enabled_ids`** takes effect on the next process start, because activating or deactivating a plugin adds or removes supervised children.
- **Encrypted keys** (provider credentials, secrets) are decrypted on the next read — no restart needed, but a running turn that already resolved the old value keeps it until the turn ends.

## What this guide is not

It is not a configuration reference — the full key list with descriptions is in [Environment variables](../environment-variables/). It is not a way to add new keys at runtime — every key is declared by a subsystem at boot, and an undeclared key cannot be stored. And it is not a substitute for the Console's per-subsystem routes; a provider credential is better set through `/ai-gateway/providers/:id` than through the raw AppConfigure key.

## Next steps

- For the full key list, read [Environment variables](../environment-variables/).
- For the Console surface, read [Console operations](../console-operations/) and the [Console API reference](../console-api/).
- For encrypted shell secrets (a different store), read [WorkerEnv secrets](../worker-env/).
