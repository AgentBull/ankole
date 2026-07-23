# Ankole single-host Docker Compose

[简体中文](README.zh-Hans.md)

This Compose project runs a production Ankole installation on one Linux host.
It includes PostgreSQL, database migration, worker-key bootstrap, the control
plane, one Agent Computer worker, and Caddy HTTPS.

## Requirements

- A Linux `amd64` or `arm64` host.
- Docker Engine with the Docker Compose plugin.
- Public ports `80` and `443`.
- A DNS name that points to the host, or `ankole.localhost` for a local-only
  installation.
- Host storage and memory sized for PostgreSQL, Agent Home, and the selected
  model workload.

The worker gets `SYS_ADMIN` and unconfined seccomp and system-path profiles.
This is required for strong bubblewrap isolation. Treat the host and worker as
a trusted first-party compute boundary. Do not expose the Docker socket to the
worker.

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
openssl rand -hex 24
```

Put them in `.env` as `POSTGRES_PASSWORD`, `ANKOLE_SECRET_BASE`, and
`ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`. Keep the hexadecimal form because it is
safe in the database and RuntimeFabric URLs.

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

## Start

```sh
docker compose pull
docker compose up -d
docker compose ps
```

Compose waits for PostgreSQL, runs all pending migrations, stores the worker
authentication key, and then starts the control plane. The Worker and Caddy
start after the control-plane service starts.

Read the first setup activation code:

```sh
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"
```

Open `https://ANKOLE_HOST/setup`. Enter the code, select the Control Plane
Plugins, and configure the administrator identity provider.

After setup, use the Console to configure providers, model profiles, Agent
Library capabilities, Agents, channel bindings, and WorkerEnv secrets. Do not
put provider API keys in `.env`.

## Image policy and upgrades

The default images are the `main-latest` GitHub Container Registry images. The
control-plane and worker tags move together only after the RuntimeFabric
workflow verifies the pair.

For a controlled deployment, set both `ANKOLE_CONTROL_PLANE_IMAGE` and
`ANKOLE_WORKER_IMAGE` in `.env` to immutable digests from the same verified
pair. You can also pin `ANKOLE_POSTGRESQL_IMAGE`.

Back up PostgreSQL and Agent Home before an upgrade. Then run:

```sh
docker compose pull
docker compose down
docker compose up -d --force-recreate
docker compose ps
```

`down` keeps all named volumes but stops the old application before migration.
The new start runs the migration and bootstrap services again before the new
control plane starts. This single-host upgrade has a short service interruption.
A rollback to an old image does not reverse a database migration. Restore the
database backup if the old application also needs the old schema.

## Backup

Create a PostgreSQL archive:

```sh
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

Back up the `ankole_agents_data` volume with a volume snapshot or a
filesystem-level backup while Ankole is stopped. PostgreSQL data is in
`ankole_postgresql_data`. Test database and Agent Home restore together on a
separate host.

## Operations

```sh
# Service state
docker compose ps

# All live logs
docker compose logs -f

# One service
docker compose logs -f control-plane
docker compose logs -f worker

# PostgreSQL extension check
docker compose exec postgresql \
  psql -U ankole -d ankole \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search', 'vector') ORDER BY extname"

# Stop services and keep data
docker compose down

# Start them again
docker compose up -d
```

`docker compose down -v` deletes the PostgreSQL, Agent Home, and Caddy volumes.
Do not run it unless permanent data deletion is intended and a tested backup
exists.

Compose rotates each container log at 20 MiB and retains five files. PostgreSQL
and RuntimeFabric are on an internal Docker network. Only Caddy publishes host
ports.

## Main settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `ANKOLE_HOST` | required | Public HTTPS host |
| `POSTGRES_PASSWORD` | required | Bundled PostgreSQL password |
| `ANKOLE_SECRET_BASE` | required | Root application secret |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | required | Shared Worker authentication key |
| `ANKOLE_MAX_CONCURRENT_TURNS` | `9` | Maximum turns on the single Worker |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | Control-plane database pool |
| `ANKOLE_CONTROL_PLANE_IMAGE` | `main-latest` image | Control-plane image or digest |
| `ANKOLE_WORKER_IMAGE` | `main-latest` image | Worker image or digest |
| `ANKOLE_POSTGRESQL_IMAGE` | `main-latest` image | PostgreSQL image or digest |

## Troubleshooting

- If `migrate` exits, run `docker compose logs migrate postgresql`. Check the
  password, retained database volume, and available disk space.
- If `control-plane` does not start, run
  `docker compose logs bootstrap-worker-auth-key control-plane`.
- If the Worker reconnects repeatedly, confirm that the Worker key in `.env`
  did not change after the first start.
- If the browser rejects setup, check the Caddy log, DNS, ports `80` and `443`,
  and certificate trust.
- If the host kernel rejects the worker security options, use a supported Linux
  Docker host. Do not remove the isolation settings without an equivalent
  sandbox.
