---
title: Deployment environment variables
description: Reference the deployment settings that the control plane and Agent Computer Worker read at process start.
section: Reference
order: 202
---

This page lists only the deployment environment variables that Ankole reads at process start. They connect PostgreSQL, establish instance secrets, start RuntimeFabric, and tune control-plane and Worker processes.

The [AppConfigure](../app-configuration/) guide now owns the runtime settings that an administrator can change while the instance runs. Do not put those settings in `.env` or a Kubernetes Secret.

## Bootstrap and secrets (process start)

These must exist before the control plane starts. Set them in `.env` for Docker Compose, or in the Secret the Helm chart reads.

| Variable | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | yes | the PostgreSQL connection string for the control plane |
| `ANKOLE_SECRET_BASE` | yes | the instance-wide secret base; used to derive other keys |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | yes | the auth key workers present to RuntimeFabric |
| `POSTGRES_PASSWORD` | bundled PostgreSQL only | the PostgreSQL password (required when the bundled PostgreSQL is enabled; provided by an external Secret otherwise) |
| `ANKOLE_HOST` | Compose | the DNS name the deployment is served on |
| `ACME_EMAIL` | Compose | the email Caddy uses for Let's Encrypt |

Keep these values in `.env` or a Secret. Never commit them to version control. The Docker Compose `.env.example` is the starting configuration.

The Helm chart `values.yaml` lists the related Kubernetes values: `ankoleSecretBase`, `workerAuthKey`, and `postgresqlPassword`.

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

## Worker-only environment (Agent Computer Worker)

The worker reads a small, fixed set of environment variables. Actor identity is **not** among them — it arrives in `turn_start`, not in the environment. These are set by the managed worker bootstrap, not by the operator.

| Variable | Meaning |
|---|---|
| `WORKER_ID` | the worker identity (for example `worker-local-1`) |
| `ANKOLE_RUNTIME_FABRIC_ENDPOINT` | the RuntimeFabric TCP endpoint |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | the RuntimeFabric worker auth key; it is separate from the endpoint |
| `ANKOLE_AGENTS_ROOT` | the root of the shared `/agents` workspace mount |
| `ANKOLE_AGENT_COMPUTER_IMAGE` | the Agent Computer Worker image the worker runs |
| `ANKOLE_VERSION` | the Ankole version label |

The Worker image sets the browser, Bubblewrap, Codex, and Skill paths. These include `ANKOLE_BROWSER_*`, `ANKOLE_BWRAP_PATH`, `ANKOLE_CODEX_BINARY`, and `ANKOLE_BUILTIN_SKILLS_ROOT`. An administrator cannot change these paths.

`PATH`, `HOME`, `DATABASE_URL`, and names that start with `ANKOLE_` are reserved and cannot be changed in the Console. See [Environment variables](../worker-env/) for custom Agent values.

## Change deployment environment variables

- With Docker Compose, change `.env` and restart the affected containers.
- With Kubernetes, change the Helm values or the related Secret and restart the affected workloads.

A process reads these variables only when it starts. Changing a file or Secret without restarting the process does not change the current runtime.

## Next steps

- For custom values that Agents use, read [Environment variables](../worker-env/).
- For runtime settings and the complete AppConfigure key list, read [AppConfigure](../app-configuration/).
- For the deployment variables in context, read the [deployment section of Quick start](../quickstart/#deployment).
