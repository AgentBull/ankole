---
name: postgresql
description: "Answer questions from a tenant PostgreSQL database with catalog search, value probes, plans, read-only queries, and published metrics."
---

# postgresql

Answer questions from a tenant PostgreSQL database with catalog search, value probes, plans, read-only queries, and published metrics.

Find the operation in [the operation index](references/index.md), then read only its linked JSON contract for inputs, outputs, and retry annotations.

Write the JSON argument object to a temporary file, then pass it over stdin so quotes and shell metacharacters remain data:

```sh
mcporter call 'postgresql.<tool-name>' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

After the call finishes, delete the temporary argument file and check the process exit code before parsing stdout.

Run `mcporter list` to discover the available connections. The default server is `postgresql`. Select `postgresql@<connection-slug>` for a particular database. If the intended database is unclear, ask the user to choose.

Applet routes and Actions use `await AnkoleRuntime.mcp.call(tool, args, { server: "postgresql", connection })` with the same contract.

Work from evidence. Start with `search_catalog` and `describe_table` to learn tables, columns, comments, keys, and masked value profiles. When a published metric covers the question, call `metric_query` with its slug and revision instead of writing SQL. Otherwise write one `SELECT` or `WITH` statement for `query`; bind values with `$1`, `$2`, … and pass them in `params`. Each statement runs in a read-only transaction with `statement_timeout` and `lock_timeout`; Ankole rejects writes, statement batches, and locking reads. Use `explain` (`EXPLAIN (FORMAT JSON)`, without running the statement) to check an expensive plan first.

Before you report that a filter matched nothing, call `probe_values` to check the real values, their case and whitespace, and the column's range. Sensitive columns return counts only.

Read the `query` evidence envelope before you answer: `truncated` means more rows exist than `rows` shows, so aggregate in SQL or pass `export` to save every row to a Pod CSV file. A `fanout_risk` warning means an aggregate over a join may count rows more than once; pre-aggregate the many side before joining. Cite `data_timestamp` and the executed `sql` with your answer.

`connection_forbidden` means the administrator has not made this connection available to you. Ask the user to request access; do not try another connection to work around it. `statement_timeout` and `scan_budget_exceeded` mean the statement exceeded the operator's budget: narrow it rather than retrying unchanged.

If no suitable connection is listed, direct the user to the tenant’s Connectors page, where an administrator adds the database.
