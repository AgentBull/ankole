# postgres-for-ankole

Ankole Agent development PostgreSQL image based on PostgreSQL 18.

Included extensions:

- `pg_search`
- `vector`

`pg_search` must be present in `shared_preload_libraries` when PostgreSQL
starts. The image's default command enables it; preserve that setting if you
override `command` or `postgresql.conf`. Adding the setting to a running server
requires a PostgreSQL restart, not a reload.

Build locally:

```sh
docker build -t postgres-for-ankole tools/devkit/postgres-for-ankole
```

Run it directly with the same setting used by the devkit Compose service:

```sh
docker run --rm -p 5433:5432 \
  -e POSTGRES_PASSWORD=just4local-dev \
  postgres-for-ankole
```

The image follows the usual Postgres container environment variables:

- `POSTGRES_USER`, default `postgres`
- `POSTGRES_PASSWORD`, default `just4local-dev`
- `POSTGRES_DB`, default `POSTGRES_USER`
- `POSTGRES_HOST_AUTH_METHOD`, default `md5`

Initialization scripts can be mounted into `/docker-entrypoint-initdb.d`.

Before running Ankole migrations, verify the server rather than assuming the
image tag is sufficient:

```sql
SHOW server_version_num;          -- must be PostgreSQL 18 (>= 180000)
SHOW shared_preload_libraries;    -- must include pg_search

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

The Brain migration creates the two extensions in the application database.
After migration, both must be installed:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_search', 'vector')
ORDER BY extname;
```

Ankole has no compatibility migration from the unreleased Memory schema to
Brain. For a stale local database, rebuild it explicitly after starting this
image:

```sh
bun run kit app-db rebuild --yes
```

For a fresh or already-Brain database, keep the data and apply only pending
migrations:

```sh
bun run kit app-db migrate
```
