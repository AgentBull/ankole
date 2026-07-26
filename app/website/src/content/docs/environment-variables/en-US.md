---
title: Environment variables
description: The complete reference — bootstrap process env (deployment-time), runtime tuning env, worker-only env, and the AppConfigure keys that hold operator-managed runtime settings.
section: Reference
order: 202
---

Ankole reads configuration from two places with deliberately different lifecycles. **Process environment variables** carry deployment-time facts and secrets that must exist before PostgreSQL is reachable — set once, at process start, in `.env` (Compose) or a Kubernetes Secret (Helm). **AppConfigure keys** carry operator-managed runtime settings — changeable through the Console at runtime, stored in PostgreSQL. This page is the reference for both, grouped by where they apply.

The decisive property, stated up front: do not mix the two. Bootstrap environment variables are not a second Console, and AppConfigure keys are not a second `.env`. If a setting can wait until PostgreSQL is up, it belongs in AppConfigure; if it cannot, it belongs in the environment.

## Bootstrap and secrets (process start)

These must exist before the control plane starts. Set them in `.env` for Docker Compose, or in the Secret the Helm chart reads.

| Variable | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | yes | the PostgreSQL connection string for the control plane |
| `ANKOLE_SECRET_BASE` | yes | the installation-wide secret base; used to derive other keys |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | yes | the auth key workers present to RuntimeFabric |
| `POSTGRES_PASSWORD` | bundled PostgreSQL only | the PostgreSQL password (required when the bundled PostgreSQL is enabled; provided by an external Secret otherwise) |
| `ANKOLE_HOST` | Compose | the DNS name the deployment is served on |
| `ACME_EMAIL` | Compose | the email Caddy uses for Let's Encrypt |

Keep these in `.env` or the Secret, never in version control. The Docker Compose `.env.example` is the canonical starting set; the Helm chart's `values.yaml` documents the Kubernetes-side equivalents (`ankoleSecretBase`, `workerAuthKey`, `postgresqlPassword`).

## Runtime tuning (process environment)

These are read at startup and tune a running process. They are not secrets.

| Variable | Default | Meaning |
|---|---|---|
| `ANKOLE_ENV` | — | the deployment environment label (for example `prod`, `dev`) |
| `ANKOLE_LOG_LEVEL` | `info` | the log level (`debug`, `info`, `warning`, `error`) |
| `ANKOLE_LOG_FORMAT` | `json` | the log line format (`json` for ingestion, `pretty` for local reading) |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | the control-plane database connection pool size |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | the PostgreSQL `max_connections` setting for the bundled server |
| `ANKOLE_MAX_CONCURRENT_TURNS` | `9` | the cap on concurrent actor turns |
| `ANKOLE_LIBRARY_ROOT` | chart default | the path to the shipped Agent Library (`app/library`) |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | the path to internal skill bundles |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | override the AIGateway base URL (rarely needed) |
| `ANKOLE_RUNTIME_FABRIC_BIND_ENDPOINT` | — | the RuntimeFabric bind endpoint |

## Worker-only environment (Agent Computer)

The worker reads a small, fixed set of environment variables. Actor identity is **not** among them — it arrives in `turn_start`, not in the environment. These are set by the managed worker bootstrap, not by the operator.

| Variable | Meaning |
|---|---|
| `WORKER_ID` | the worker identity (for example `worker-local-1`) |
| `RUNTIME_FABRIC_URL` | the RuntimeFabric URL, carrying the worker auth key |
| `ANKOLE_AGENTS_ROOT` | the root of the shared `/agents` workspace mount |
| `ANKOLE_AGENT_COMPUTER_IMAGE` | the Agent Computer image the worker runs |
| `ANKOLE_VERSION` | the Ankole version label |

The worker-side browser, bubblewrap, Codex, and skills paths (`ANKOLE_BROWSER_*`, `ANKOLE_BWRAP_PATH`, `ANKOLE_CODEX_BINARY`, `ANKOLE_BUILTIN_SKILLS_ROOT`, and so on) are set by the worker image and are not operator-tunable. Reserved worker-env names (`PATH`, `HOME`, `DATABASE_URL`, anything starting with `ANKOLE_` except the fixed set above) cannot be overridden through WorkerEnv — see [WorkerEnv secrets](../worker-env/) for the operator-managed shell environment.

## AppConfigure keys (runtime, operator-managed)

AppConfigure keys live in PostgreSQL and are changed through the Console. Each one has a declared key, a scope, a schema, a default, and an encrypted flag. The ones an operator actually touches:

### AI agent

| Key | Meaning |
|---|---|
| `ai_agent.max_iterations` | the agent loop iteration budget |
| `ai_agent.max_output_tokens` | the per-turn output token cap |
| `ai_agent.inactivity_timeout_ms` | how long a turn may be inactive before it is reaped |
| `ai_agent.library.agent_plugin_defaults` | global default enablement for Agent Plugins |
| `ai_agent.library.skill_defaults` | global default enablement for skills |

### AI gateway and memory

| Key | Meaning |
|---|---|
| `ai_gateway.compaction` | AIGateway conversation compaction policy |
| `brain.knowledge` | Brain curated-knowledge settings |
| `brain.dreaming` | Brain dreaming enablement and schedule |
| `brain.embedding` | Brain embedding model settings |
| `brain.search` | Brain recall search settings |
| `brain.sources` | Brain retained-source settings |

### Identity, plugins, and system

| Key | Meaning |
|---|---|
| `principals.identity_providers.active` | which identity provider is active for admin sign-in |
| `principals.identity_providers.directory_full_sync_interval_hours` | how often to fully sync directory groups |
| `plugins.enabled_ids` | the global list of enabled Control Plane Plugins (applied on next start) |
| `system.timezone` | the installation default timezone |
| `i18n.default_locale` | the installation default locale |

### Runtime fabric and worker

| Key | Meaning |
|---|---|
| `runtime_fabric.worker_auth_key` | the worker auth key (also derivable from the bootstrap env) |
| `agent_computer.background_agent_job.max_turns_per_worker` | the per-worker turn cap for Background Agent Jobs |
| `worker.rendered_fetch_idle_ttl_ms` | the idle TTL for rendered web-fetch results |
| `security.ssrf_filter` | when true, model-controlled URL fetches reject private and loopback hosts |

### Setup and bootstrap

| Key | Meaning |
|---|---|
| `setup.bootstrap_activation_code` | the first-visit activation code (read via `kit show bootstrap-activation-code`) |
| `setup.completed` | whether setup has been completed |

## How to change each kind

- **Bootstrap and secrets** — edit `.env` (Compose) or the Secret (Helm) and restart. Do not put these in AppConfigure.
- **Runtime tuning env** — edit the deployment's environment and restart the control plane.
- **AppConfigure keys** — change through the Console (`PUT /app-configurations/:key`), or through the Console route specific to the subsystem (provider config, binding config, and so on). Most take effect immediately; the few that affect boot (notably `plugins.enabled_ids`) take effect on the next process start.

## Next steps

- For the operator shell-environment store, read [WorkerEnv secrets](../worker-env/).
- For the Console route that changes AppConfigure, read the [Console API reference](../console-api/).
- For the deployment variables in context, read the [installation guide](../installation/).
