# Ankole single-host Docker Compose

[简体中文](README.zh-Hans.md)

This Compose project runs a private Ankole deployment on a single Linux, macOS,
or Windows host capable of running Linux `amd64` or `arm64` containers. It runs
PostgreSQL, database migrations, the control plane, and Caddy for HTTPS, while
the control plane creates a dedicated Agent Computer Worker container for each
Agent over the Docker socket.

A site is one complete Ankole deployment and can host multiple tenants, each
with its own people, Agents, Brain, and integrations. Site operators manage
shared infrastructure and providers through the site-admin Console, which
defaults to `/site-admin-console`. To serve it at a different absolute path, set
`ANKOLE_SITE_ADMIN_CONSOLE_PATH` before startup and keep that setting in your
operator configuration. Regular users sign in through their tenant hostname or
OIDC application rather than the site-admin Console.

## Requirements

- A Linux, macOS, or Windows host that can run Linux `amd64` or `arm64`
  containers.
- Docker Engine with the Docker Compose plugin, or Docker Desktop.
- Inbound TCP ports `80` and `443`.
- A DNS name resolving to the host, or `ankole.localhost` for a local-only
  deployment.
- Enough host disk and memory for PostgreSQL, Agent drives, and one Worker
  container per active Agent.

Because the control plane mounts the host's Docker socket—which grants
root-equivalent control over the host—treat the host as a trusted first-party
compute boundary. Worker containers never receive the Docker socket or extra
kernel privileges; each container is the isolation boundary for a single Agent.

## Prepare configuration

```sh
cd tools/deploy/docker-compose
cp .env.example .env
chmod 600 .env
```

Generate four independent hexadecimal secrets:

```sh
openssl rand -hex 24
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
```

Set them in `.env` as `POSTGRES_PASSWORD`, `ANKOLE_SECRET_BASE`,
`RELEASE_COOKIE`, and `ANKOLE_FUNCTION_RUNTIME_TOKEN`. Keep `POSTGRES_PASSWORD`
in hexadecimal so it embeds safely into the database URL without escaping.

`RELEASE_COOKIE` sets the distributed Erlang cookie for this deployment.
Published control-plane images ship with the same built-in default cookie, so
leaving it unchanged exposes that cookie to anyone who can pull the image. In
addition, the control plane binds both EPMD and the Erlang distribution port to
the loopback interface so the node listens only on `127.0.0.1`, confining
distributed Erlang traffic to the host.

Set `ANKOLE_DOCKER_GID` to the numeric group ID of the Docker socket as seen
inside containers, allowing the unprivileged control-plane user to access the
socket. On Linux, inspect the group ID on the host:

```sh
stat -c %g /var/run/docker.sock
```

On macOS with Docker Desktop, the mounted socket inside containers always has
group `0` regardless of the host path's group, so set `ANKOLE_DOCKER_GID=0`. If
your Docker socket is not at `/var/run/docker.sock`, also set
`ANKOLE_DOCKER_SOCKET`.

For an Internet-facing deployment, set `ANKOLE_HOST` to a DNS name pointing at
the host and set `ACME_EMAIL` so Caddy can obtain and renew a public TLS
certificate automatically (ports `80` and `443` must be open through any
upstream router and host firewall).

For a local-only installation, use:

```dotenv
ANKOLE_HOST=ankole.localhost
ACME_EMAIL=admin@example.com
```

With `ankole.localhost`, Caddy issues certificates from its internal CA. After
first startup, copy the local root certificate out of the Caddy container and
trust it in your operating system's certificate store on each client machine:

```sh
docker compose cp \
  caddy:/data/caddy/pki/authorities/local/root.crt \
  ./ankole-local-ca.crt
```

Because production setup cookies carry the `Secure` attribute, browsers accept
them only over trusted HTTPS.

`worker-providers.yaml` seeds the initial Docker Worker provider—configuring its
Docker network, environment variables, stop grace period, and idle release
policy. By default it sets no CPU or memory cap, allowing each Worker container
to use all host CPUs and memory. To cap per-Worker resources, add `cpus` and
`memoryMiB` under `config`:

```yaml
    config: |
      socket: /var/run/docker.sock
      network: ankole_workers
      cpus: 2
      memoryMiB: 4096
```

The control plane reads `worker-providers.yaml` only when the provider table is
empty on first boot. Afterward, edit the provider in the Console under Settings;
updated resource limits take effect the next time the control plane replaces an
idle Worker. Provider credentials live in separate encrypted fields, and each
Agent stays bound to the provider chosen when it was created.

Each Agent gets a dedicated persistent volume mounted at `/workspace` and a
separate cache volume mounted at `/var/cache/ankole`. Replacing a container
keeps both volumes, rebuilding a Worker clears only the cache volume, and
deleting an Agent removes both volumes after its container has exited. Worker
workloads run as `uid 1000` without `sudo`.

## Start

```sh
docker compose pull
docker compose up -d
docker compose ps
```

Compose waits for PostgreSQL, database migrations, and the Agent Home migration
job to finish before starting the control plane and Caddy. No Worker containers
run yet: when you create an Agent, the control plane pulls the Worker image and
starts that Agent's Worker on demand.

Retrieve the initial setup activation code from the control-plane logs:

```sh
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"
```

Open `https://ANKOLE_HOST/setup`, enter the activation code, choose the Control
Plane Plugins to enable, and configure the identity provider for administrators.

Once setup completes, use the Console to configure model providers, model
profiles, Agent Library capabilities, Agents, channel bindings, and `WorkerEnv`
secrets. Never place model-provider API keys in `.env`.

## Function Runtime network

The Function Runtime and the control plane share the `ankole_functions` bridge
network so the Function Runtime can call back into the control plane, while
PostgreSQL stays isolated on the internal `ankole_backend` network. Whereas the
Helm chart enforces CIDR egress rules through a Kubernetes `NetworkPolicy`,
Compose relies on Docker bridge separation; on cloud VMs, set the hop limit for
instance metadata to `1` or block `169.254.169.254` from container subnets in
the host firewall.

## Worker containers

Each Worker container is named `ankole-ankole-<hash>-<generation>` and carries
the labels `ankole.installation=ankole`, `ankole.provider=docker`, and
`ankole.agent-uid=<Agent UID>`. Attached to `ankole_workers`, it can reach the
control plane and the public Internet—for browser automation, web fetches, and
package installation—while remaining isolated from PostgreSQL on
`ankole_backend`. On cloud VMs, enforce an instance-metadata hop limit of `1` or
block `169.254.169.254` from containers so a Worker cannot read host IAM
credentials. Compose itself does not track Worker containers; the control plane
manages their lifecycle, and the Console's Workers page displays their status.

By default, idle Workers remain running. Setting `idleReleaseAfter` (such as
`15m`) in the Worker provider YAML causes the control plane to remove idle
containers while keeping both the Agent Home and cache volumes; the next time
the Agent needs a Worker, a fresh container reattaches both volumes. Rebuilding
a Worker deletes only the cache volume, whereas deleting an Agent removes both
volumes after all of its containers have exited.

`ANKOLE_WORKER_INSTALLATION` (default `ankole`) prefixes Worker container names,
Agent volume names, and container labels. It must be 1–20 characters of
lowercase ASCII letters, digits, or hyphens, starting and ending with a letter
or digit (for example, `e2e-1011b01`). Never change it after first boot: under a
different label, the control plane creates new empty Agent Home volumes, loses
visibility into existing Worker containers, and can launch a duplicate Worker
for the same Agent.

## Image policy and upgrades

By default, `compose.yaml` pins the `2.0.0-alpha.24` pre-release control-plane
image—which embeds the Worker image built from the same source revision—along
with a pinned PostgreSQL digest. Always keep deployment files and container
images on the same release; moving tags such as `main-latest` can point to an
older release whose startup contract differs from these files.

The PostgreSQL container runs with locale `C.utf8` so fresh volumes initialize
as `UTF8`. Updating the image or Compose file does not re-encode an existing
database: check `SHOW server_encoding`, and if an existing database uses
`SQL_ASCII`, follow the
[backup and restore procedure](../../devkit/postgres-for-ankole/README.md)
rather than altering metadata in place.

For reproducible production rollouts, pin `ANKOLE_CONTROL_PLANE_IMAGE` in `.env`
to an immutable `sha256` digest (which also pins the matching Worker image), and
optionally pin `ANKOLE_POSTGRESQL_IMAGE`. Before upgrading, review `.env` for
both variables, because `.env` overrides take precedence over updated defaults
in `compose.yaml`.

If you are upgrading an older deployment whose `.env` lacks `RELEASE_COOKIE`,
append one before running `docker compose` (otherwise Compose aborts immediately
naming the missing variable):

```sh
printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
```

Before every upgrade, back up PostgreSQL, the file store, all Agent Homes, and
your `.env` secrets. For per-Agent volumes named without tenant identity, complete
the [Agent Home storage migration](../../../docs/upgrades/unified-drive.md#agent-home-storage-names)
before the final control-plane startup below. The default PostgreSQL image includes `pg_search` `0.26.4`
for both `amd64` and `arm64`. Update the SQL extension version inside PostgreSQL
before starting the control plane, then verify that both the installed extension
and the loaded library report `0.26.4`:

```sh
docker compose pull
docker compose stop
docker compose up -d postgresql
docker compose exec postgresql psql -U ankole -d ankole -v ON_ERROR_STOP=1 \
  -c "ALTER EXTENSION pg_search UPDATE TO '0.26.4'" \
  -c "SELECT extversion FROM pg_extension WHERE extname = 'pg_search'" \
  -c "SELECT * FROM paradedb.version_info()"
docker compose up -d --force-recreate
docker compose ps
```

`docker compose stop` halts the old control plane before migrations while
keeping Docker networks intact so Workers remain reachable, and the new control
plane starts only after both migration jobs succeed. Existing per-Agent Workers
reconnect automatically, and idle Workers with an outdated image are replaced on
idle. Expect a brief service interruption during this single-host upgrade.
Rolling back to an older container image cannot undo completed database
migrations—if an older release requires the previous schema, restore your
database backup. See the
[database image guide](../../devkit/postgres-for-ankole/README.md) for extension
and shared-library verification queries.

When upgrading from an earlier release that used pooled Workers, the
`migrate-agent-homes` service waits for the schema migration, stops any container
mounting the legacy `ankole_agents_data` volume, copies each active Agent's
directory into its tenant-qualified dedicated volume, adds its tenant ownership
label, chowns the files to `uid 1000`, and writes a completion marker
in the old volume (skipping orphan directories left behind by deleted
Agents and leaving `ankole_agents_data` intact). Ensure free disk space at least
matches the used size of `ankole_agents_data`. If any copy fails,
`migrate-agent-homes` exits non-zero so the control plane stays stopped;
re-running `docker compose up` retries unfinished Agents without overwriting
completed ones.

Inside each Worker, `/agents/<agent_uid>` symlinks to `/workspace`, where user
files, session workspaces, and Job workspaces remain. Shared Agent drives live
under `files_data` in the control plane. When upgrading from a release that
predates Agent drives, run this one-time import to copy installed Skills,
Automation Job scripts, and unsent legacy attachments into each Agent's drive:

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm -v ankole_agents_data:/agents control-plane \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

The import never overwrites existing drive files and logs any unreadable paths.
Confirm that all queued legacy attachments converted cleanly—resolving any
missing files reported by the import, since legacy outbound sends wait on
conversion—and verify both the migrated Agent Homes and the import output before
removing the legacy volume with `docker volume rm ankole_agents_data`.

## Backup

For a consistent backup, disable Agents first and let in-flight work finish.
While the control plane is still running, stop and remove Worker containers
cleanly and wait until the control plane records them absent; only then stop the
control plane (`docker compose stop` by itself leaves Worker containers
running). Back up storage only after every Agent Home writer has exited, and
store the original `ANKOLE_SECRET_BASE` in your secret manager so restored
deployments can decrypt provider and generation credentials.

With PostgreSQL still running, dump the database archive:

```sh
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

With Ankole stopped, snapshot or back up `ankole_files_data` alongside
`ankole_postgresql_data`—PostgreSQL holds the authoritative index of files in
`ankole_files_data`, so always back up and restore them as a pair. Back up every
Agent Home volume (`ankole-<installation>-<Agent hash>`) as well; volumes ending
in `-cache` are rebuildable and do not need backups. Periodically test restoring
the database, file store, and Agent Homes together on a separate host.

## Operations

```sh
# Service state
docker compose ps

# Worker containers
docker ps -a --filter label=ankole.installation=ankole

# All live logs of the Compose services
docker compose logs -f

# One service
docker compose logs -f control-plane

# One Worker
docker logs -f CONTAINER_NAME

# PostgreSQL extension check
docker compose exec postgresql \
  psql -U ankole -d ankole \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search', 'vector') ORDER BY extname"

# Stop services and keep data
docker ps -aq --filter label=ankole.installation=ankole | xargs -r docker rm -f
docker compose down

# Start them again
docker compose up -d
```

Always remove Worker containers before running `docker compose down`, because
Docker cannot tear down the `ankole_workers` network while Worker containers
remain attached; the control plane will recreate Workers on demand when started
again.

Never run `docker compose down -v` unless you intend to permanently erase the
PostgreSQL, file-store, and Caddy volumes and have a verified backup.

Compose rotates each container log at 20 MiB (keeping five rotated files), keeps
PostgreSQL on an internal Docker network, and publishes host ports only on
Caddy.

## Main settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `ANKOLE_HOST` | required | Public HTTPS hostname |
| `POSTGRES_PASSWORD` | required | Password for bundled PostgreSQL |
| `ANKOLE_SECRET_BASE` | required | Root application secret |
| `RELEASE_COOKIE` | required | Distributed Erlang cookie for this deployment |
| `ANKOLE_DOCKER_GID` | required | Numeric group ID of the Docker socket inside containers |
| `ANKOLE_DOCKER_SOCKET` | `/var/run/docker.sock` | Path to the Docker socket on the host |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | Control-plane database connection pool size |
| `ANKOLE_WORKER_INSTALLATION` | `ankole` | Installation prefix for Worker containers and Agent volumes; never change after first start |
| `ANKOLE_CONTROL_PLANE_IMAGE` | `2.0.0-alpha.24` image | Control-plane image or digest (also selects the matching Worker image) |
| `ANKOLE_FUNCTION_RUNTIME_TOKEN` | required | Shared internal token between the control plane and Function Runtime |
| `ANKOLE_FUNCTION_RUNTIME_IMAGE` | Matching release image | Stateless Applet and program execution runtime image |
| `ANKOLE_POSTGRESQL_IMAGE` | Digest in `compose.yaml` | PostgreSQL image or digest |

## Troubleshooting

- **`migrate` exits non-zero**: inspect `docker compose logs migrate postgresql`
  and verify `POSTGRES_PASSWORD`, any pre-existing database volume, and free
  disk space.
- **`control-plane` fails to start**: inspect
  `docker compose logs control-plane`.
- **Worker setup step stays incomplete or Workers report `docker_unreachable`**:
  the control plane cannot access the Docker socket. If the error mentions
  permission denied, `ANKOLE_DOCKER_GID` does not match the socket's group ID as
  seen inside containers (use `0` on macOS Docker Desktop).
- **An Agent's Worker never reaches Ready**: check the Console's Workers page
  for the latest container status and log tail, or run
  `docker logs CONTAINER_NAME`.
- **Browser setup reloads or fails**: check `docker compose logs caddy`, DNS
  resolution, inbound ports `80` and `443`, and local CA trust.
