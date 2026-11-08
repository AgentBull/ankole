# postgresql operations

Choose the operation below, then read only its linked contract.

- [describe_table](describe_table.json): Read a cached table's columns, types, comments, key properties, and masked value profiles. sparse_order_key marks a ClickHouse sorting or primary key, which is not unique.
- [explain](explain.json): Show the database's estimated execution plan for one read-only query without running it.
- [metric_query](metric_query.json): Run a published Brain metric by its slug and immutable revision with typed parameters. Ankole compiles the metric's SQL deterministically, so the result matches every other caller of that revision.
- [probe_values](probe_values.json): Check real column values before concluding that a filter has no data: distinct lists the most frequent values, match finds case- and whitespace-insensitive matches for a value, and range reads the minimum, maximum, and non-null count. Sensitive columns return counts only.
- [query](query.json): Run one read-only SELECT or WITH query in a read-only session. The result is an evidence envelope: column types, at most max_rows rows, truncated when more rows exist, elapsed time, the executed SQL, the data timestamp, and warnings such as fanout_risk. Pass export to save every row to a Pod CSV file.
- [search_catalog](search_catalog.json): Search the cached catalog of tables, views, and columns by name and comment. A blank query lists the most frequently queried tables.
