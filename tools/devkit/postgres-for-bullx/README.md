# postgres-for-bullx

Ankole Agent development PostgreSQL image based on PostgreSQL 18.

Included extensions:

- `pg_search`
- `vector`

Build locally:

```sh
docker build -t postgres-for-bullx tools/devkit/postgres-for-bullx
```

The image follows the usual Postgres container environment variables:

- `POSTGRES_USER`, default `postgres`
- `POSTGRES_PASSWORD`, default `just4local-dev`
- `POSTGRES_DB`, default `POSTGRES_USER`
- `POSTGRES_HOST_AUTH_METHOD`, default `md5`

Initialization scripts can be mounted into `/docker-entrypoint-initdb.d`.
