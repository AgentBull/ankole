# postgres-for-ankole

This directory builds the PostgreSQL 18 development image for Ankole, bundling
the extensions that Ankole requires:

- `pg_search` 0.25.11 (from the ParadeDB PostgreSQL 18 RPM)
- `vector` (`pgvector_18`, installed without the optional LLVM JIT package)
- `pg_trgm` (from PostgreSQL `contrib` in the base image)

All PostgreSQL server and `contrib` packages are installed from the official
`download.postgresql.org` repositories.

PostgreSQL must load `pg_search` via `shared_preload_libraries` at server
startup. The image's default `CMD` enables this setting automatically; if you
override the container `command` or mount a custom `postgresql.conf`, keep
`pg_search` in `shared_preload_libraries`. Enabling it on a running server
requires a full PostgreSQL restart rather than a configuration reload.

Build the image locally:

```sh
docker build -t postgres-for-ankole tools/devkit/postgres-for-ankole
```

Run it directly with the same password used by the Compose service in the
devkit:

```sh
docker run --rm -p 5433:5432 \
  -e POSTGRES_PASSWORD=just4local-dev \
  postgres-for-ankole
```

The container accepts the standard PostgreSQL entrypoint environment variables:

- `POSTGRES_USER` (default: `postgres`)
- `POSTGRES_PASSWORD` (default: `just4local-dev`)
- `POSTGRES_DB` (default: value of `POSTGRES_USER`)
- `POSTGRES_HOST_AUTH_METHOD` (default: `md5`)

You can mount custom initialization scripts into `/docker-entrypoint-initdb.d`.

Newly initialized clusters create both the template databases and `POSTGRES_DB`
with `UTF8` encoding even when the container locale is `C`, and the devkit
creates new application databases from `template0` with `UTF8` as well.

Updating the container image leaves the encoding of existing databases and
templates unchanged. Check `SHOW server_encoding` in the application database;
if you need to convert an existing database to `UTF8`, take a logical dump with
`pg_dump --encoding=UTF8`, restore it into a fresh `UTF8` database, and verify
the restored data before switching the control plane over. Retain the original
database for recovery, and never mutate `pg_database.encoding` directly.

Before running Ankole migrations, query the live server directly instead of
relying on the image tag alone:

```sql
SHOW server_version_num;          -- must be PostgreSQL 18 (>= 180000)
SHOW shared_preload_libraries;    -- must include pg_search

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector', 'pg_trgm')
ORDER BY name;
```

Ankole migrations install `vector` (a dependency of `pg_search`), `pg_search`,
and `pg_trgm`, so all three extensions must be available on the server before
migrations run.

Apply pending migrations with the devkit command:

```sh
bun run kit app-db migrate
```

When upgrading an existing database, swapping the container image updates the
shared library on disk without updating the SQL catalog definitions of installed
extensions. Back up the database first and stop the control plane for a
maintenance window. Then start PostgreSQL with the updated image and run the
following SQL in the application database:

```sql
ALTER EXTENSION pg_search UPDATE TO '0.25.11';

SELECT extversion FROM pg_extension WHERE extname = 'pg_search';
SELECT * FROM paradedb.version_info();
```

Confirm that both the installed extension version and the loaded shared library
report `0.25.11`. Next, apply Ankole migrations and verify a Brain text recall
query before restarting the control plane. Text-only BM25 indexes do not need to
be rebuilt when upgrading to `0.25.11`; if a native index reader fails to open,
follow the
[index recovery procedure for Brain](../../../docs/design-docs/BrainV3.md#retrieval-index-recovery).
