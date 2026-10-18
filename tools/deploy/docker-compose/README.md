# Ankole single-host Docker Compose

[简体中文](README.zh-Hans.md)

This Compose project runs one private Ankole deployment instance on a Linux,
macOS, or Windows host. Docker must be able to run Linux `amd64` or `arm64`
containers. The project includes PostgreSQL, database migration, the control
plane, and Caddy HTTPS. The control plane creates one Agent Computer Worker
container for each Agent that needs one, through the Docker socket.

A site is one complete deployment. It may contain several tenants, each with
its own people, Agents, Brain and integrations. Site operators manage shared
providers and infrastructure. The administrator Console defaults to
`/site-admin-console`; `/console` returns 404 after this upgrade. Set
`ANKOLE_SITE_ADMIN_CONSOLE_PATH` before startup to choose another absolute path.
Keep that path in operator configuration. Normal users sign in through their
OIDC application rather than the site administration Console.

## Requirements

- A Linux, macOS, or Windows host that can run Linux `amd64` or `arm64`
  containers.
- Docker Engine with the Docker Compose plugin, or Docker Desktop.
- Public ports `80` and `443`.
- A DNS name that points to the host, or `ankole.localhost` for a local-only
  deployment.
- Host storage and memory sized for PostgreSQL, the Agent drives, and one
  Worker container for each Agent that runs.

The control plane mounts the Docker socket. Access to the socket is equal to
root access on the host; treat the host as a trusted first-party compute
boundary. The Worker containers get no socket and no extra kernel privileges:
each container is the isolation boundary of one Agent.

## Prepare configuration

```sh
cd tools/deploy/docker-compose
cp .env.example .env
chmod 600 .env
```

Generate three independent hexadecimal values:

```sh
openssl rand -hex 24
openssl rand -hex 32
openssl rand -hex 32
```

Put them in `.env` as `POSTGRES_PASSWORD`, `ANKOLE_SECRET_BASE`, and
`RELEASE_COOKIE`. Keep the hexadecimal form because it is safe in the database
URL.

`RELEASE_COOKIE` is the distributed Erlang cookie of this deployment. Every
pull of a published control-plane image holds the same built-in cookie, so a
deployment that keeps that cookie shares it with everyone who can pull the
image. The control plane also binds EPMD and the distribution port to the
loopback interface, because its node answers at the loopback address only.
Both hold the Erlang node of one deployment to that host.

Set `ANKOLE_DOCKER_GID` to the group of the Docker socket as containers see it.
The control plane runs as an unprivileged user and gets the socket through this
group. On Linux, read the group from the host:

```sh
stat -c %g /var/run/docker.sock
```

Docker Desktop on macOS gives containers a socket of group `0`, whatever the
host shows, so use `ANKOLE_DOCKER_GID=0` there.

Set `ANKOLE_DOCKER_SOCKET` when the socket is not `/var/run/docker.sock`.

For an Internet deployment, set `ANKOLE_HOST` to a DNS name that resolves to the
host and set `ACME_EMAIL`. Caddy obtains and renews the public TLS certificate.
The firewall and upstream router must allow ports `80` and `443`.

For a local-only installation, use:

```dotenv
ANKOLE_HOST=ankole.localhost
ACME_EMAIL=admin@example.com
```

Caddy then uses its local certificate authority. Copy its root certificate
after the first start and trust it on each client:

```sh
docker compose cp \
  caddy:/data/caddy/pki/authorities/local/root.crt \
  ./ankole-local-ca.crt
```

Use the operating system certificate tool to trust `ankole-local-ca.crt`.
Production setup cookies require trusted HTTPS.

`worker-providers.yaml` defines the initial Docker provider. Its YAML sets the
network, environment variables, stop grace period, and idle release. It sets
no CPU or memory limit, so each Worker container can use all CPUs and memory of
the host. To limit each Worker container, add `cpus` and `memoryMiB` to the
`config` text, for example under `network`:

```yaml
    config: |
      socket: /var/run/docker.sock
      network: ankole_workers
      cpus: 2
      memoryMiB: 4096
```

The seed is read only when the provider table is empty. After the first start,
edit the provider in Console under Settings; a new limit applies when the
control plane replaces an idle Worker. Credentials use separate encrypted
fields. Each Agent keeps its selected provider.

Each Agent has a persistent local volume at `/workspace` and a separate cache
volume at `/var/cache/ankole`. Container replacement preserves both volumes;
a rebuild removes only the cache. Deleting an Agent removes both volumes after
its container is gone. Workers run as uid 1000 and have no sudo.

## Start

```sh
docker compose pull
docker compose up -d
docker compose ps
```

Compose waits for PostgreSQL, the database migrations, and the Agent Home
migration service before it starts the control plane and Caddy. There is no Worker container yet: the control plane
creates the Worker of an Agent when the Agent is created, and pulls the Worker
image at that time.

Read the first setup activation code:

```sh
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"
```

Open `https://ANKOLE_HOST/setup`. Enter the code, select the Control Plane
Plugins, and configure the administrator identity provider.

After setup, use the Console to configure providers, model profiles, Agent
Library capabilities, Agents, channel bindings, and WorkerEnv secrets. Do not
put provider API keys in `.env`.

## Worker containers

Each Worker container is named `ankole-ankole-<hash>-<generation>` and has the
labels `ankole.installation=ankole`, `ankole.provider=docker`, and
`ankole.agent-uid=<Agent UID>`. It
joins the `ankole_workers` network, so it reaches the control plane and the
internet, for its browser, web fetches, and package installs, but not
PostgreSQL, which is only on the internal `ankole_backend` network. On a cloud
virtual machine, set the instance metadata hop limit to 1 or block
`169.254.169.254` for containers, so a Worker cannot take the credentials of
the machine. Compose does not manage these containers: the control plane
creates and deletes them, and the Console Workers page shows
their state.

An idle Worker keeps running by default. Set `idleReleaseAfter` in the Worker
provider YAML, for example `15m`, to delete idle containers. The Agent Home
and cache volumes stay. When the Agent needs a Worker, a new container mounts
both volumes. A rebuild deletes only the cache volume; Agent deletion removes
both volumes after all its containers are gone.

The installation label, `ANKOLE_WORKER_INSTALLATION` (default `ankole`), is
part of the names and labels of the Worker containers and Agent volumes. Use
1–20 lowercase letters, digits, or hyphens. The first and last characters must
be letters or digits; for example, `e2e-1011b01` is valid. Do not
change it after the first start. With a new label, the control plane creates
new, empty Agent Home volumes, and it does not see the running Workers, so it
can start a second Worker for an Agent.

## Image policy and upgrades

The defaults pin control plane `2.0.0-alpha.5` and the PostgreSQL digest in
`compose.yaml`. This is a pre-release. The control-plane image supplies the
Worker image of the same source revision.
Use deployment files and images from the same release. `main-latest` can point
to an older release whose startup contract does not match these files.

The PostgreSQL container uses `C.utf8` so an empty volume initializes with
UTF8. An image or configuration update does not convert an existing database.
Check `SHOW server_encoding`; for a SQL_ASCII database, use the separate
[backup and restore procedure](../../devkit/postgres-for-ankole/README.md)
before changing its encoding.

For a controlled deployment, set `ANKOLE_CONTROL_PLANE_IMAGE` in `.env` to an
immutable digest. That digest also fixes the Worker image. You can also pin
`ANKOLE_POSTGRESQL_IMAGE`. Before an upgrade, check both overrides in `.env`;
an old override takes precedence over the new deployment defaults.

This release requires `RELEASE_COOKIE` in `.env`. An upgraded deployment that
has no value stops at the first `docker compose` command with a message that
names the variable. Add it before the upgrade:

```sh
printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
```

Back up PostgreSQL, the file store, all Agent Homes, and the deployment
secrets before an upgrade. The PostgreSQL image supplies `pg_search` 0.25.11;
update its installed extension SQL before you start the new control plane:

```sh
docker compose pull
docker compose stop
docker compose up -d postgresql
docker compose exec postgresql psql -U ankole -d ankole -v ON_ERROR_STOP=1 \
  -c "ALTER EXTENSION pg_search UPDATE TO '0.25.11'"
docker compose up -d --force-recreate
docker compose ps
```

`stop` stops the old application before migration and keeps its networks.
The new control plane starts only after both migration services succeed.
During later upgrades, per-Agent Workers reconnect to the control plane; an
idle Worker is replaced when its image changes. This single-host upgrade has a
short service interruption. An old image cannot reverse a database migration.
Restore the database backup if the old application needs the old schema.
See the [database image procedure](../../devkit/postgres-for-ankole/README.md)
for extension and loaded-library checks.

For an upgrade from pooled Workers, `migrate-agent-homes` stops every container
that mounts the old `ankole_agents_data` volume. It copies the directory of each
Agent that still exists to that Agent's exclusive volume, changes ownership to
uid 1000, and records completion in the old volume. The old release did not
remove the Home of a deleted Agent. The service skips these orphan directories
and keeps the old volume. New Agents receive generated UIDs. Reserve as much free
disk space as the old volume uses. If a copy fails, the service fails and the
control plane does not start. A later `docker compose up` retries unfinished
copies. Completed copies are never applied again.

The old `/agents/<agent_uid>` path is a symbolic link to `/workspace` inside
each Worker. User files, session files, and Job workspaces stay in Agent Home.
The control plane keeps shared Agent drives in `files_data`. Import installed
Skills, Automation Job scripts, and unsent legacy attachments into those drives
once after an upgrade from a release without Agent drives:

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm -v ankole_agents_data:/agents control-plane \
  /app/bin/ankole eval 'Ankole.Release.import_agent_home("/agents")'
```

The import never replaces a drive file and reports files that it cannot read.
Verify that all queued attachments were converted, and resolve every missing
attachment reported by the import. Legacy sends wait for conversion.
Verify the migrated Agent Homes and the import report before you remove the
old volume with `docker volume rm ankole_agents_data`.

## Backup

Disable Agents and wait for active work to finish. Stop and remove their Worker
containers normally while the control plane is running. Wait for it to record
absence, then stop the control plane. Stopping Compose alone does not stop
Workers. Back up only after all Home writers have stopped. Keep the original
`ANKOLE_SECRET_BASE` in a secret manager; it decrypts provider and generation
credentials after restore.

Keep PostgreSQL running and create an archive:

```sh
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

Back up the `ankole_files_data` volume with a volume snapshot or a
filesystem-level backup while Ankole is stopped. PostgreSQL data is in
`ankole_postgresql_data`. PostgreSQL names the drive files that
`ankole_files_data` holds, so back up and restore the two together. Also back up each Agent Home volume, named `ankole-<installation>-<Agent hash>`.
Volumes whose names end in `-cache` need no backup. Test restoration of the
database, shared file store, and Agent Homes together on a separate host.

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

Remove the Worker containers before `docker compose down`: Compose cannot remove
the `ankole_workers` network while a Worker container is attached to it. The
control plane creates the Workers again when their Agents need them.

`docker compose down -v` deletes the PostgreSQL, file store, and Caddy volumes.
Do not run it unless permanent data deletion is intended and a tested backup
exists.

Compose rotates each container log at 20 MiB and retains five files.
PostgreSQL is on an internal Docker network. Only Caddy publishes host ports.

## Main settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `ANKOLE_HOST` | required | Public HTTPS host |
| `POSTGRES_PASSWORD` | required | Bundled PostgreSQL password |
| `ANKOLE_SECRET_BASE` | required | Root application secret |
| `RELEASE_COOKIE` | required | Distributed Erlang cookie of this deployment |
| `ANKOLE_DOCKER_GID` | required | Group of the Docker socket |
| `ANKOLE_DOCKER_SOCKET` | `/var/run/docker.sock` | Docker socket on the host |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | Control-plane database pool |
| `ANKOLE_WORKER_INSTALLATION` | `ankole` | Label in the names of the Worker containers and Agent volumes; do not change it after the first start |
| `ANKOLE_CONTROL_PLANE_IMAGE` | `2.0.0-alpha.5` image | Control-plane image or digest; it names the Worker image |
| `ANKOLE_POSTGRESQL_IMAGE` | Digest in `compose.yaml` | PostgreSQL image or digest |

## Troubleshooting

- If `migrate` exits, run `docker compose logs migrate postgresql`. Check the
  password, retained database volume, and available disk space.
- If `control-plane` does not start, run `docker compose logs control-plane`.
- If the Console setup shows the Worker step as incomplete, or the Workers page
  shows `docker_unreachable` as the last error of a Worker, the control plane
  cannot use the Docker socket. A permission error in that reason means that
  `ANKOLE_DOCKER_GID` is not the group of the socket as containers see it (`0`
  with Docker Desktop on macOS).
- If an Agent's Worker does not become ready, open the Console Workers page,
  which shows the latest reason and log lines of its container, or run
  `docker logs CONTAINER_NAME`.
- If the browser rejects setup, check the Caddy log, DNS, ports `80` and `443`,
  and certificate trust.
