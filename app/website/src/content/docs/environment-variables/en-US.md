---
title: Deployment environment variables
description: Reference the deployment settings that the control plane and Agent Computer Worker read at process start.
section: Reference
order: 202
---

This reference lists the startup environment variables read by the control plane and Agent Computer Worker for PostgreSQL, Pod Base shards, `ankole-function-runtime`, deployment secrets, the object store, and process tuning. Worker provider configurations live in PostgreSQL as YAML rather than environment variables.

For dynamic settings that operators can change while Ankole is running, see [Application configuration](../app-configuration/)—do not place `AppConfigure` keys in `.env` or a Kubernetes Secret.

## Bootstrap and secrets (process start)

Provide these variables before starting the control plane—either in `.env` for Docker Compose or in the bootstrap Secret referenced by the Helm chart:

| Variable | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | yes (`prod`) | PostgreSQL 18+ connection string for the control plane (`Ankole.Repo`) |
| `BASE_DB_URLS` | no | Optional `;`-separated PostgreSQL 18+ URLs for physical Pod Base shards (`Ankole.Pod.BaseRepo`), supporting query parameters `ankole_sharding`, `ankole_pool_size`, and `ankole_stock_only`. Defaults to `DATABASE_URL` as `base_default` when unset in single-database FOSS deployments; Ankole rejects `sslmode` in these URLs |
| `ANKOLE_SECRET_BASE` | yes (`prod`) | Site-wide secret base used to derive encryption and signing keys |
| `RELEASE_COOKIE` | yes (`prod`) | Distributed Erlang cookie shared by every control-plane node in the deployment |
| `ANKOLE_FUNCTION_RUNTIME_TOKEN` | yes (`prod`) | Shared bearer secret between the control plane and `ankole-function-runtime` |
| `ANKOLE_FUNCTION_RUNTIME_URL` | yes (`prod`) | Internal HTTP URL of `ankole-function-runtime` (for example `http://function-runtime:9000` in Compose or the headless Service URL in Kubernetes) |
| `POSTGRES_PASSWORD` | bundled PostgreSQL only | PostgreSQL password (required when bundled PostgreSQL is enabled; supplied through `DATABASE_URL` or an external Secret otherwise) |
| `ANKOLE_HOST` | Compose | Public DNS name that serves the deployment |
| `ACME_EMAIL` | Compose | Email address that Caddy uses for Let's Encrypt |
| `ANKOLE_DOCKER_GID` | Compose | Group ID of the Docker socket; the control plane runs as an unprivileged user and accesses the socket through this group |

Keep secret values inside `.env` or a Kubernetes Secret and never commit them to version control (the Docker Compose `.env.example` file shows the expected template). Workers require no static key in `.env` or the bootstrap Secret because the control plane mints a unique credential per Worker generation.

In the Helm chart's `values.yaml`, these settings map to `secrets.ankoleSecretBase`, `secrets.releaseCookie`, `secrets.functionRuntimeToken`, `secrets.databaseURL`, `secrets.baseDBURLs`, `secrets.postgresqlPassword`, `controlPlane.siteAdminConsolePath`, and `functionRuntime.*`.

## Runtime tuning (process environment)

Ankole reads these non-secret tuning variables at process startup for the control plane and `ankole-function-runtime`:

| Variable | Default | Meaning |
|---|---|---|
| `ANKOLE_ENV` | — | Deployment environment label (for example `prod`, `dev`) |
| `ANKOLE_LOG_LEVEL` | `info` | Log level (`debug`, `info`, `warning`, `error`) |
| `POOL_SIZE` | `10` | Control-plane `Ankole.Repo` connection pool size read directly by the BEAM process |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | Docker Compose `.env` variable that `compose.yaml` maps to `POOL_SIZE` |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | PostgreSQL `max_connections` setting for the bundled Compose server |
| `ANKOLE_SITE_ADMIN_CONSOLE_PATH` | `/site-admin-console` | URL path prefix for the Site Admin Console |
| `ANKOLE_FUNCTION_RUNTIME_IMAGE` | release default | Container image of `ankole-function-runtime` in Docker Compose |
| `ANKOLE_FUNCTION_RUNTIME_MAX_CONCURRENCY` | `32` | Maximum concurrent isolate executions per `ankole-function-runtime` container |
| `ANKOLE_LIBRARY_ROOT` | chart default | Path to the shipped Agent Library (`app/library`) |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | Path to internal Skill bundles |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | Overrides the AIGateway base URL when Workers reach AIGateway through an explicit internal address |

## File store (process start)

`ANKOLE_FILES_STORE` configures `Ankole.ObjectStore`, which backs each Agent's drive (attachments, generated images, sent files, installed Skills, Automation Job scripts, and saved files) along with Pod `file` pages, Pod document/Base/Chat attachments, and compiled Applet bundles. Workers never receive object-store credentials; all file bytes stream through the control plane. See [Control-plane drive and object storage](../drive-storage/) for all supported OpenDAL backends (`fs`, `s3`, `azblob`, `d1`, `cos`, `postgresql`, `oss`, `tos`, `gcs`, `sftp`, and `webdav`).

| Variable | Required | Meaning |
|---|---|---|
| `ANKOLE_FILES_STORE` | yes | `fs` for a directory on a persistent control-plane volume, or `s3` for Amazon S3 or an S3-compatible store such as Cloudflare R2 |
| `ANKOLE_FILES_FS_ROOT` | `fs` | Absolute directory path of the store; Docker Compose mounts the `files_data` volume at `/var/lib/ankole/files` |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | Target S3 bucket name |
| `ANKOLE_FILES_S3_REGION` | `s3` | Bucket region (`auto` for Cloudflare R2) |
| `ANKOLE_FILES_S3_ENDPOINT` | no | Custom endpoint URL for an S3-compatible store |
| `ANKOLE_FILES_S3_ROOT` | no | Object-key prefix inside the bucket |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID`, `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | no | Static S3 credentials; when omitted, Ankole uses the default AWS credential chain (including EKS Pod Identity) |

Use `fs` only with a single control-plane replica, and switch to `s3` (or another shared remote backend) whenever multiple control-plane replicas run. Because large `s3` writes use multipart uploads that leave orphaned parts if the control plane stops mid-transfer, configure a bucket lifecycle rule to abort incomplete multipart uploads.

## Worker Provider bootstrap

These startup variables identify the deployment and default Worker image. You configure individual Worker Providers under **Console → Workers → Providers** using YAML and separate encrypted credentials—once created, a provider's type, location, and persistent storage mode are immutable, while instance sizing or config changes roll out when an Agent is idle.

| Variable | Meaning |
|---|---|
| `ANKOLE_AGENT_COMPUTER_IMAGE` | Target Worker image matching the control-plane release |
| `ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT` | Default RuntimeFabric WebSocket URL |
| `ANKOLE_WORKER_INSTALLATION` | Installation label; defaults to `ankole` |
| `ANKOLE_WORKER_PROVIDERS_FILE` | Optional provider seed YAML file, imported once at bootstrap alongside existing Agent assignments |

In local development, `bun dev` mounts workspace source and internal Skills from `config/dev.exs`; production releases carry no development mounts.

## Provider egress proxy

Set standard proxy environment variables on the control-plane process whenever outbound traffic to model providers must traverse a proxy (lowercase forms such as `https_proxy` work identically):

| Variable | Meaning |
|---|---|
| `HTTPS_PROXY` | Proxy for HTTPS and secure WebSocket (`wss`) provider requests |
| `HTTP_PROXY` | Proxy for HTTP and WebSocket (`ws`) provider requests; also used for secure requests when neither `HTTPS_PROXY` nor `ALL_PROXY` is set |
| `ALL_PROXY` | Fallback proxy for provider requests when the protocol-specific variable is unset |
| `NO_PROXY` | Comma-separated hosts or domain suffixes that bypass the proxy and connect directly |

Proxy URLs accept `http`, `https`, `socks5`, or `socks5h` schemes (including embedded credentials when proxy authentication is required). `NO_PROXY` always takes precedence; otherwise, Ankole checks `HTTPS_PROXY`, `ALL_PROXY`, and `HTTP_PROXY` in order for secure requests, and `HTTP_PROXY` followed by `ALL_PROXY` for plain HTTP/WS requests. Restart the control plane after updating proxy variables.

## Worker-only environment (Agent Computer Worker)

The control plane injects these variables automatically when provisioning each Worker—operators never set them manually. Each Worker identifies its assigned Agent from `WORKER_ID`, whereas Session and Turn identifiers arrive dynamically in each `turn_start` frame rather than through environment variables.

| Variable | Meaning |
|---|---|
| `WORKER_ID` | Assigned Agent UID; the Worker serves only this Agent |
| `ANKOLE_RUNTIME_FABRIC_ENDPOINT` | `ws://` or `wss://` RuntimeFabric URL to which the Worker connects |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | Per-generation random credential; the control plane stores its digest and an encrypted copy for reconciliation retries |
| `ANKOLE_WORKER_STORAGE` | Storage preparation mode selected by the Worker Provider |

To customize Worker process variables across a provider, use provider YAML `env` or the Kubernetes `podTemplate` (for example, `ANKOLE_MAX_CONCURRENT_SLOTS` caps concurrent workspace and Codex turns per Worker at `12` by default, while pure model turns consume no Worker slot; changes replace idle Workers). Paths baked into the Worker image—including `ANKOLE_BROWSER_*` and `ANKOLE_BUILTIN_SKILLS_ROOT`—are fixed and cannot be overridden.

Inside the per-Agent environment editor, Ankole reserves `PATH`, `HOME`, `DATABASE_URL`, and any variable prefixed with `ANKOLE_`, though supported settings remain configurable in provider YAML; see [Environment variables](../worker-env/).

## Change deployment environment variables

After editing startup variables in Compose `.env` or Helm `values.yaml`, restart the affected service. Update Worker Provider settings directly in the Console—editing an already-imported seed file has no effect on existing providers—and Ankole will replace Workers with updated images or instance settings as their Agents become idle.

## Next steps

- For custom values that Agents use, read [Environment variables](../worker-env/).
- For runtime settings and the complete AppConfigure key list, read [AppConfigure](../app-configuration/).
- For the deployment variables in context, read the [deployment section of Quick start](../quickstart/#deployment).
