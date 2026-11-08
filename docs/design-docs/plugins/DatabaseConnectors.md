# Database Connectors

The `database-connectors` Plugin lets Agents and Applets read a tenant's
PostgreSQL, MySQL, and ClickHouse databases. It declares one
`connectors.connector` adapter per engine. Connectors owns the connection
credentials, the connection-level `query` permission, and the rebuildable
catalog cache; this Plugin owns the engine protocols and the execution guards.
See [Connectors](../Connectors.md#database-connections) for the shared
connection, authorization, cache, and `run_read_query/5` contracts, and
[Plugins](../Plugins.md) for the Plugin contract.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `database-connectors` (`activation: :always`) |
| Connector and toolkit IDs | `postgresql`, `mysql`, `clickhouse` |
| Authentication scheme | `password` |
| Public fields | `host`, `port`, `database`, `tls_mode`, `ca_certificate`, `sample_exclusions` |
| Credential fields | `username`, `password` |
| Operator budgets | `connectors.database.limits` (tenant-overridable AppConfigure key) |
| Tools | `search_catalog`, `describe_table`, `probe_values`, `explain`, `query`, `metric_query` |

All six tools carry `readOnlyHint: true`. One ToolSpec declaration per tool
generates the Worker Skill references under `app/library/agent-plugins/<toolkit>`
and the Applet `AnkoleRuntime.mcp` types.

## Network policy

Before every PostgreSQL or MySQL connect, the adapter resolves the configured
host and passes every resolved address through
`Ankole.Kernel.validate_ip_addresses/2` with the tenant's
`security.ssrf_filter` value, the same check that `Ankole.Files.HTTP` applies.
The driver then connects to the validated address, so a DNS answer that
changes after the check cannot redirect the session. Cloud metadata addresses
are always rejected; private, loopback, link-local, and CGNAT addresses are
rejected while the operator enables the filter. TLS keeps the configured host
name for SNI and certificate verification; when that host is an IP literal,
verification checks the certificate against the address. The `tls_mode` field
selects `verify` (the default; system certificate authorities or the supplied
PEM certificate), `require` (encryption without verification), or `disable`.
When verification fails, the call returns `database_unavailable` with a
`reason` that names the failed check, such as `unknown_ca` or
`hostname_check_failed`.

ClickHouse uses its HTTP(S) SQL interface through `Ankole.Files.HTTP`, which
applies the same policy and the egress proxy. The adapter passes that client
the same TLS options as the PostgreSQL and MySQL drivers, so all three modes
and the PEM certificate apply; `disable` sends plain HTTP. The default port is
8443 (HTTPS); a plain HTTP server usually listens on 8123.

## Execution guards

Every statement that a caller supplies to `query` or `explain` first passes
`Ankole.Kernel.sql_inspect/2` in the engine's dialect. The kernel accepts one
`SELECT` or `WITH` query and rejects the input with `empty`, `parse_error`,
`multiple_statements`, `not_read_only`, `locking_clause`, or
`side_effect_function`. The kernel raises `side_effect_function` when any part
of the statement, including a table function or a `LATERAL` call, calls a
built-in function of the dialect that has effects outside the query result,
such as PostgreSQL `pg_notify`, advisory locks, `dblink`, or `pg_sleep`, MySQL
`GET_LOCK` or `SLEEP`, or ClickHouse `url`, `remote`, `s3`, or `sleep`. It
matches the last part of the name case-insensitively, so a schema-qualified
call also fails. Because the check is syntactic, the statement then runs in a
read-only session, and the database role of the connection governs which
user-defined and extension functions the statement may execute:

- PostgreSQL connects with `default_transaction_read_only=on` and runs each
  statement in a transaction that sets `READ ONLY`, `SET LOCAL
  statement_timeout`, and `SET LOCAL lock_timeout`.
- MySQL sets `SET SESSION TRANSACTION READ ONLY` and `max_execution_time` on
  connect and streams each statement through a server-side cursor inside a
  transaction. `explain` reads its one-row plan without a cursor, because
  MySQL 8.4 crashes when `EXPLAIN FORMAT=JSON` runs through one. The same
  `mysql` connector serves MariaDB, which sets `max_statement_time` instead of
  `max_execution_time`.
- ClickHouse requests send `readonly=1`, `max_execution_time`,
  `max_bytes_to_read`, `max_result_rows`, and `result_overflow_mode=break`, and
  bind parameters natively as `{p1:Type}` placeholders. The `limit` setting
  caps the outermost result at the rows that the adapter fetches, because
  `max_result_rows` stops only at a block boundary and one block of wide rows
  can exceed the response budget. Requests also send
  `http_write_exception_in_output_format=0`, so an error that occurs after the
  response has started arrives as plain text after the last row instead of as a
  row of the result.

The adapter fetches at most `max_rows + 1` rows through the cursor or the
server-side result limit instead of rewriting the statement, so the
statement's own `ORDER BY` and `LIMIT` keep their meaning and the extra row
sets `truncated`. Rows also stop at `max_result_bytes`, and the same
byte-bounded consumer reads export previews, plans, probes, and catalog
samples. A plan or probe that exceeds the budget returns `result_too_large`
instead of a partial result, and the probes of one call share the budget.
Decimals, integers
beyond 2^53, and temporal values reach the caller as strings; ClickHouse
results use `JSONCompactEachRowWithNamesAndTypes` with 64-bit integers and
decimals quoted, so `UInt64` and `Decimal` values keep full precision and
their declared scale, while NULLs, arrays, and maps stay JSON values. PostgreSQL and ClickHouse report column types;
MySQL's driver does not, so the envelope names each MySQL column's type from its
first non-null value. A `fanout_risk` result from `sql_inspect` becomes a
`fanout_risk` warning in the envelope.

With an `export` destination, `query` streams every row, up to
`max_export_rows`, into a Pod CSV file and returns the leading rows that fit
`max_rows` and `max_result_bytes` as the preview. Saving the file changes the destination Page, so a
read-only route rejects an export with `read_only_route`. When the database
fails after the export has started, for example when ClickHouse reaches
`max_execution_time` while rows are streaming, the adapter aborts the upload,
so the destination Page receives no file, and returns the database's own
error code and message. ClickHouse reports such a failure after its last row
as an `__exception__` marker and plain-text lines. The adapter reads the whole
report, up to 64 KiB, and takes the message from its first `Code:` line on,
including when ClickHouse closes the connection right after the report.

Each call opens a short-lived connection in a supervised task. The task ends
after the statement budget plus a connect allowance, or at the gateway
deadline when that comes first. Failures return structured codes:
`statement_timeout`, `lock_timeout`, `not_read_only`, `scan_budget_exceeded`
(ClickHouse), `query_failed` with the database's message, `database_unavailable`,
`database_host_blocked`, `result_too_large`, `table_not_cataloged`, and
`connection_forbidden`.

## Operator budgets

`connectors.database.limits` holds positive integers, and a tenant can
override the site value:

| Key | Default | Meaning |
| --- | --- | --- |
| `statement_timeout_ms` | 15000 | Statement and session time budget |
| `lock_timeout_ms` | 2000 | PostgreSQL lock wait |
| `max_rows` | 500 | Rows returned per query |
| `max_result_bytes` | 2000000 | Approximate size of each query result, export preview, plan, probe call, and table sample |
| `max_scanned_bytes` | 10000000000 | ClickHouse `max_bytes_to_read` |
| `max_export_rows` | 1000000 | Rows written by one export |
| `probe_count` | 10 | Probes per `probe_values` call |
| `catalog_tables` | 5000 | Tables cached per refresh |
| `profile_tables` | 100 | Tables sampled per refresh |
| `sample_rows` | 1000 | Rows sampled per profiled table |

## Catalog refresh

`fetch_catalog/3` reads tables, views, columns, comments, row estimates, and
keys from `pg_catalog`, `information_schema`, or `system.tables` and
`system.columns`. PostgreSQL and MySQL report primary keys, single-column
unique keys, and foreign keys. ClickHouse reports its sorting key (or primary
key) as the table's `sparse_order_key`, which lists the key expressions in
order as ClickHouse prints them, such as `toDate(ts)` or
`toStartOfInterval(ts, toIntervalHour(1))`, and sets `sparse_order_key` on
each column that one of those expressions reads. That key is not unique and
never identifies a row.
The adapter asks for one table more than `catalog_tables`. When that extra
table arrives, the adapter caches the first `catalog_tables` tables in schema
and name order and reports the snapshot as incomplete. Connectors records
that outcome as `catalog_complete` on every cached table row of the snapshot,
next to the shared `fetched_at`. The connection JSON that the Pod and Console
read carries `catalog` with the cached `table_count` and `complete`. When the
cache holds only the first tables, the Pod connection card names that count
and asks the reader to have a site administrator raise `catalog_tables`,
because `connectors.database.limits` is a tenant setting that only the site
administration Console edits. `catalog` is null for a connection that has no
cached tables.

The refresh also counts recent queries per table from `pg_stat_statements`,
`performance_schema.events_statements_summary_by_digest`, or
`system.query_log` when the connection's role can read them; `sql_inspect`
names the tables in each recorded statement. These counts order search
results and decide which tables to profile, and no tool exposes the query
history itself.

For the most queried (then largest) `profile_tables` tables, the refresh reads
`sample_rows` rows of the non-sensitive columns and records each column's null
fraction, distinct count in the sample, up to ten frequent values, a
low-cardinality flag, and the minimum and maximum. A column is sensitive when
its name suggests personal or secret data (for example password, token, email,
phone, address, birth date, salary, card or account numbers, or their Chinese
equivalents), when its type holds binary or location data, or when the
connection's `sample_exclusions` names it as `column`, `table.column`, or
`schema.table.column` (`*` matches any name). The refresh never selects a
sensitive column's values, so its profile stays empty and `probe_values`
returns counts only. The cache records each column's type and sensitivity at
refresh time, and `mark_catalog/2` applies the connection's current
exclusions and the heuristics again whenever `describe_table` or
`probe_values` reads the cache, so an exclusion takes effect as soon as an
administrator saves it.

## Tools

- `search_catalog` searches the cached tables and columns with BM25; a blank
  query lists the most frequently queried tables. Its `complete` field is
  false when the last refresh stopped at `catalog_tables`, so an Agent treats
  a table missing from the results as possibly uncached rather than absent.
- `describe_table` returns one cached table with its columns, key properties,
  and masked profiles. A name that exists in several schemas returns
  `table_ambiguous` with the candidate schemas.
- `probe_values` runs up to `probe_count` probes on one table so a caller can
  diagnose an empty result: `distinct` lists the most frequent values, `match`
  counts exact matches and lists case- and whitespace-insensitive near
  matches, and `range` reads the minimum, maximum, and non-null count. Because
  sensitivity depends on column types, a table without cached columns returns
  `table_not_cataloged` until an administrator refreshes the catalog.
- `explain` returns the estimated plan (`EXPLAIN (FORMAT JSON)`,
  `EXPLAIN FORMAT=JSON`, or `EXPLAIN`) without running the statement.
- `query` runs one guarded statement and returns the evidence envelope.
- `metric_query` runs a published Brain metric revision through
  `Ankole.Brain.execute_metric/4`; Brain compiles the metric and calls
  `Ankole.Connectors.run_read_query/5` for connector bindings.
