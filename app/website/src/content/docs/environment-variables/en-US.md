---
title: Deployment environment variables
description: Reference the deployment settings that the control plane and Agent Computer Worker read at process start.
section: Reference
order: 202
---

These are startup variables for PostgreSQL, deployment secrets, the file store, and process settings. Worker provider settings are stored in PostgreSQL as YAML.

The [AppConfigure](../app-configuration/) guide now owns the runtime settings that an administrator can change while the instance runs. Do not put those settings in `.env` or a Kubernetes Secret.

## Bootstrap and secrets (process start)

These must exist before the control plane starts. Set them in `.env` for Docker Compose, or in the Secret the Helm chart reads.

| Variable | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | yes | the PostgreSQL connection string for the control plane |
| `ANKOLE_SECRET_BASE` | yes | the instance-wide secret base; used to derive other keys |
| `RELEASE_COOKIE` | yes | the distributed Erlang cookie; every control-plane node of the deployment uses the same value |
| `POSTGRES_PASSWORD` | bundled PostgreSQL only | the PostgreSQL password (required when the bundled PostgreSQL is enabled; provided by an external Secret otherwise) |
| `ANKOLE_HOST` | Compose | the DNS name the deployment is served on |
| `ACME_EMAIL` | Compose | the email Caddy uses for Let's Encrypt |
| `ANKOLE_DOCKER_GID` | Compose | the group ID of the Docker socket; the control plane runs as an unprivileged user and uses the socket through this group |

Keep these values in `.env` or a Secret. Never commit them to version control. The Docker Compose `.env.example` is the starting configuration.

Workers need no key in `.env` or the Secret: the control plane gives each Worker its own credential.

The Helm chart `values.yaml` lists the related Kubernetes values: `ankoleSecretBase`, `releaseCookie`, `databaseURL`, and `postgresqlPassword`.

## Runtime tuning (process environment)

These are read at startup and tune a running process. They are not secrets.

| Variable | Default | Meaning |
|---|---|---|
| `ANKOLE_ENV` | — | the deployment environment label (for example `prod`, `dev`) |
| `ANKOLE_LOG_LEVEL` | `info` | the log level (`debug`, `info`, `warning`, `error`) |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | the control-plane database connection pool size |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | the PostgreSQL `max_connections` setting for the bundled server |
| `ANKOLE_LIBRARY_ROOT` | chart default | the path to the shipped Agent Library (`app/library`) |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | the path to internal skill bundles |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | override the AIGateway base URL (rarely needed) |

## File store (process start)

The control plane keeps each Agent's drive in a file store: attachments, generated images, sent files, installed Skills, Automation Job scripts, and files that Agents save. Workers never receive storage credentials; file bytes pass through the control plane.

| Variable | Required | Meaning |
|---|---|---|
| `ANKOLE_FILES_STORE` | yes | `fs` for a directory on a persistent control-plane volume, or `s3` for Amazon S3 or an S3-compatible store such as Cloudflare R2 |
| `ANKOLE_FILES_FS_ROOT` | `fs` | the absolute directory of the store; Docker Compose uses the `files_data` volume at `/var/lib/ankole/files` |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | the bucket |
| `ANKOLE_FILES_S3_REGION` | `s3` | the region; Cloudflare R2 uses `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | no | the endpoint of an S3-compatible store |
| `ANKOLE_FILES_S3_ROOT` | no | a key prefix inside the bucket |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID`, `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | no | static credentials; without them the default AWS credential chain applies, including EKS Pod Identity |

An `fs` store allows one control-plane replica. Use `s3` when more than one control-plane replica runs.

A large `s3` write is a multipart upload. If the control plane stops during the upload, the parts stay in the bucket, so give the bucket a lifecycle rule that aborts incomplete multipart uploads.

## Worker Provider bootstrap

These startup values identify this deployment and the target Worker image. Configure each provider in **Console → Workers → Providers** with YAML and separate encrypted credentials. The provider type, location, and persistent storage cannot change after creation. Instance settings take effect when the Agent is idle.

| Variable | Meaning |
|---|---|
| `ANKOLE_AGENT_COMPUTER_IMAGE` | Target Worker image of the control-plane release |
| `ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT` | Default RuntimeFabric WebSocket URL |
| `ANKOLE_WORKER_INSTALLATION` | Installation label; default `ankole` |
| `ANKOLE_WORKER_PROVIDERS_FILE` | Optional provider seed YAML file; imported once with assignment of existing Agents |

`bun dev` uses source and internal Skill mounts from `config/dev.exs`. A release has no development mounts.

## Provider egress proxy

Set these standard variables on the control-plane process when model-provider
traffic must use an outbound proxy. Lowercase forms such as `https_proxy` also
work.

| Variable | Meaning |
|---|---|
| `HTTPS_PROXY` | proxy for HTTPS and secure WebSocket (`wss`) provider requests |
| `HTTP_PROXY` | proxy for HTTP and WebSocket (`ws`) provider requests; secure requests also use it when no `HTTPS_PROXY` or `ALL_PROXY` value exists |
| `ALL_PROXY` | fallback proxy for provider requests when the protocol-specific variable is absent |
| `NO_PROXY` | comma-separated hosts or domain suffixes that must connect directly |

Proxy URLs can use `http`, `https`, `socks5`, or `socks5h`, including embedded
credentials when the proxy requires authentication. `NO_PROXY` always wins.
For secure requests, Ankole tries `HTTPS_PROXY`, then `ALL_PROXY`, then
`HTTP_PROXY`. For plain requests, it tries `HTTP_PROXY`, then `ALL_PROXY`.
Restart the control plane after you change these variables.

## Worker-only environment (Agent Computer Worker)

The control plane sets these variables when it creates a Worker. Operators do not set them. The Worker learns its Agent from `WORKER_ID`; the Session and the Turn arrive in each `turn_start`, not in the environment.

| Variable | Meaning |
|---|---|
| `WORKER_ID` | the Agent UID; the Worker serves only this Agent |
| `ANKOLE_RUNTIME_FABRIC_ENDPOINT` | the `ws://` or `wss://` RuntimeFabric URL that the Worker connects to |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | Random generation credential; the control plane saves its digest and encrypted retry value |
| `ANKOLE_WORKER_STORAGE` | Storage preparation mode set by the provider |

Worker environment overrides belong to provider YAML `env`, or the Kubernetes `podTemplate`. `ANKOLE_MAX_CONCURRENT_SLOTS` limits environment workspaces and Codex turns on one Worker; its default is 12. Model turns use no Worker slot. Instance changes replace the Worker when idle.

The Worker image sets the browser and Skill paths. These include `ANKOLE_BROWSER_*` and `ANKOLE_BUILTIN_SKILLS_ROOT`. An administrator cannot change these paths.

`PATH`, `HOME`, `DATABASE_URL`, and names that start with `ANKOLE_` are reserved in the Agent environment editor. This restriction does not prohibit the supported settings in provider YAML. See [Environment variables](../worker-env/).

## Change deployment environment variables

Change startup variables in Compose `.env` or the Helm values and restart the affected process. Edit provider settings in the Console; changing an imported seed file does not update an existing provider. Image or instance-setting changes replace Workers when their Agents are idle.

## Next steps

- For custom values that Agents use, read [Environment variables](../worker-env/).
- For runtime settings and the complete AppConfigure key list, read [AppConfigure](../app-configuration/).
- For the deployment variables in context, read the [deployment section of Quick start](../quickstart/#deployment).
