# postgres-for-ankole

Ankole Agent development PostgreSQL image based on PostgreSQL 18.

Included extensions:

- `pg_search` 0.25.11, from the ParadeDB PostgreSQL 18 RPM
- `vector`
- `pg_trgm` (PostgreSQL contrib, present in the base image)

PostgreSQL packages use the official `download.postgresql.org` repositories.
The image installs `pgvector_18` without the optional LLVM JIT package.

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

New clusters use UTF8 for the template databases and `POSTGRES_DB`, including
when the container locale is `C`. The devkit also creates new application
databases with UTF8 from `template0`.

An image update does not change the encoding of an existing database or its
templates. Check `SHOW server_encoding` in the application database. To change
an existing encoding, create a logical backup with `pg_dump --encoding=UTF8`,
restore it into a separate UTF8 database, and verify the data before switching
the control plane. Keep the original database for recovery. Do not change
`pg_database.encoding` directly.

Before running Ankole migrations, verify the server rather than assuming the
image tag is sufficient:

```sql
SHOW server_version_num;          -- must be PostgreSQL 18 (>= 180000)
SHOW shared_preload_libraries;    -- must include pg_search

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector', 'pg_trgm')
ORDER BY name;
```

The fresh-install baseline installs `vector` in `public` before `pg_search`;
`pg_search` requires it. The BrainV3 migration also installs `pg_trgm`. The
packages must be available in this image for the migrations to run.

Apply pending migrations the usual way:

```sh
bun run kit app-db migrate
```

For an existing database, changing the image does not update the installed
extension SQL. Back up the database and stop the control plane for a
maintenance window. Start PostgreSQL with this image, then run in the
application database:

```sql
ALTER EXTENSION pg_search UPDATE TO '0.25.11';

SELECT extversion FROM pg_extension WHERE extname = 'pg_search';
SELECT * FROM paradedb.version_info();
```

Both the installed extension and the loaded library must be 0.25.11. Then
apply Ankole migrations and repeat a Brain text recall before you start the
control plane. Existing BM25 indexes that contain only text do not need a
rebuild for this version change. For a failed native index reader, use the
[Brain index recovery procedure](../../../docs/design-docs/BrainV3.md#retrieval-index-recovery).

The image has no optional LLVM JIT provider. PostgreSQL does not use JIT when
the provider is absent; no configuration change is required.
