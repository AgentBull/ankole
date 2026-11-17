use super::*;

fn ok(sql: &str, dialect: &str) -> JSONValue {
    match inspect(sql, dialect) {
        Ok(value) => value,
        Err(error) => panic!("{sql} failed: {error:?}"),
    }
}

fn code(sql: &str, dialect: &str) -> &'static str {
    match inspect(sql, dialect) {
        Ok(value) => panic!("{sql} passed: {value}"),
        Err(error) => error.code,
    }
}

#[test]
fn postgres_query_facts() {
    let result = ok(
        "WITH recent AS (SELECT * FROM sales.orders WHERE created_at >= DATE '2024-01-01') \
         SELECT c.region, SUM(r.amount) FROM recent r JOIN crm.public.customers c ON c.id = r.customer_id \
         WHERE c.status IN ('active', 'trial') AND r.amount > -5 GROUP BY c.region LIMIT 10",
        "postgres",
    );
    assert_eq!(
        result["tables"],
        json!([
            { "catalog": null, "schema": "sales", "name": "orders" },
            { "catalog": "crm", "schema": "public", "name": "customers" },
        ])
    );
    // `recent` is a CTE without aggregation, so SUM over the join can fan out.
    assert_eq!(result["fanout_risk"], true);
}

#[test]
fn mysql_query_facts() {
    let result = ok(
        "SELECT `name`, COUNT(DISTINCT user_id) FROM shop.`events` \
         WHERE kind LIKE 'click%' AND 3 < score AND active = TRUE AND note = NULL LIMIT 5, 20",
        "mysql",
    );
    assert_eq!(
        result["tables"],
        json!([{ "catalog": null, "schema": "shop", "name": "events" }])
    );
    assert_eq!(result["fanout_risk"], false);
}

#[test]
fn clickhouse_query_facts() {
    let result = ok(
        "SELECT day, sumIf(amount, ok), uniqExact(user) FROM analytics.hits \
         WHERE day BETWEEN '2024-01-01' AND '2024-01-31' GROUP BY day \
         HAVING sumIf(amount, ok) >= 100.5 LIMIT 100",
        "clickhouse",
    );
    assert_eq!(
        result["tables"],
        json!([{ "catalog": null, "schema": "analytics", "name": "hits" }])
    );
    assert_eq!(result["fanout_risk"], false);
}

#[test]
fn generic_query_facts() {
    let result = ok(
        "SELECT a FROM t1 UNION ALL SELECT b FROM (SELECT b FROM t2 WHERE x <> 'y') s",
        "generic",
    );
    assert_eq!(
        result["tables"],
        json!([
            { "catalog": null, "schema": null, "name": "t1" },
            { "catalog": null, "schema": null, "name": "t2" },
        ])
    );
    assert_eq!(result["fanout_risk"], false);
}

#[test]
fn table_functions_and_cte_names_are_not_tables() {
    let result = ok(
        "WITH t AS (SELECT 1 AS n) SELECT * FROM t, generate_series(1, 3)",
        "postgres",
    );
    assert_eq!(result["tables"], json!([]));
}

#[test]
fn rejects_writes() {
    for (sql, dialect) in [
        ("INSERT INTO t VALUES (1)", "postgres"),
        ("UPDATE t SET a = 1", "mysql"),
        ("DELETE FROM t", "generic"),
        ("DROP TABLE t", "clickhouse"),
        ("CREATE TABLE t (a int)", "postgres"),
        ("EXPLAIN SELECT 1", "postgres"),
        ("SELECT * INTO t2 FROM t", "postgres"),
        (
            "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d",
            "postgres",
        ),
        (
            "WITH i AS (INSERT INTO t VALUES (1) RETURNING id) SELECT id FROM i",
            "postgres",
        ),
    ] {
        assert_eq!(code(sql, dialect), "not_read_only", "{sql}");
    }
}

#[test]
fn rejects_locking_clauses() {
    assert_eq!(
        code("SELECT * FROM t FOR UPDATE", "postgres"),
        "locking_clause"
    );
    assert_eq!(
        code("SELECT * FROM (SELECT * FROM t FOR SHARE) s", "postgres"),
        "locking_clause"
    );
    assert_eq!(
        code("SELECT * FROM t FOR UPDATE", "mysql"),
        "locking_clause"
    );
    assert_eq!(
        code("SELECT * FROM t WHERE a = 1 LOCK IN SHARE MODE", "mysql"),
        "locking_clause"
    );
    // The words inside a string literal are not a locking clause.
    assert_eq!(
        code("SELECT 'LOCK IN SHARE MODE' FROM", "mysql"),
        "parse_error"
    );
}

#[test]
fn rejects_bad_input() {
    assert_eq!(code("", "postgres"), "empty");
    assert_eq!(code("  \n ", "postgres"), "empty");
    assert_eq!(code(";", "postgres"), "empty");
    assert_eq!(
        code("SELECT 1; SELECT 2", "postgres"),
        "multiple_statements"
    );
    assert_eq!(code("SELEC 1", "postgres"), "parse_error");
    assert_eq!(code("SELECT 1", "oracle"), "parse_error");
    let large = format!("SELECT '{}'", "a".repeat(MAX_SQL_BYTES));
    assert_eq!(code(&large, "postgres"), "parse_error");
}

#[test]
fn fanout_heuristic() {
    let risky = [
        "SELECT c.region, SUM(o.amount) FROM customers c JOIN orders o ON o.cid = c.id GROUP BY c.region",
        "SELECT COUNT(*) FROM a JOIN b ON a.id = b.aid",
        "SELECT SUM(amount) FROM a, b",
    ];
    for sql in risky {
        assert_eq!(ok(sql, "postgres")["fanout_risk"], true, "{sql}");
    }
    let safe = [
        // No join.
        "SELECT SUM(amount) FROM orders",
        // A join without an aggregate.
        "SELECT * FROM a JOIN b ON a.id = b.aid",
        // Duplicate-insensitive aggregates.
        "SELECT MAX(o.amount), COUNT(DISTINCT o.id) FROM c JOIN o ON o.cid = c.id",
        // The 1:N side is pre-aggregated in a derived table.
        "SELECT c.region, SUM(o.total) FROM customers c \
         LEFT JOIN (SELECT cid, SUM(amount) AS total FROM orders GROUP BY cid) o ON o.cid = c.id \
         GROUP BY c.region",
        // The 1:N side is pre-aggregated in a CTE.
        "WITH o AS (SELECT cid, SUM(amount) AS total FROM orders GROUP BY cid) \
         SELECT SUM(o.total) FROM customers c JOIN o ON o.cid = c.id",
    ];
    for sql in safe {
        assert_eq!(ok(sql, "postgres")["fanout_risk"], false, "{sql}");
    }
    // The outer query aggregates over a single relation, but an inner join
    // in a subquery aggregates over its own join.
    let nested = ok(
        "SELECT SUM(x) FROM (SELECT SUM(b.v) AS x FROM a JOIN b ON a.id = b.aid GROUP BY a.id) s",
        "postgres",
    );
    assert_eq!(nested["fanout_risk"], true);
}

#[test]
fn rejects_side_effect_functions() {
    for (sql, dialect, function) in [
        ("SELECT pg_notify('c', 'x')", "postgres", "pg_notify"),
        (
            "SELECT pg_catalog.PG_NOTIFY('c', 'x')",
            "postgres",
            "PG_NOTIFY",
        ),
        (
            "SELECT * FROM t WHERE pg_try_advisory_xact_lock(1)",
            "postgres",
            "pg_try_advisory_xact_lock",
        ),
        (
            "SELECT pg_advisory_unlock_all()",
            "postgres",
            "pg_advisory_unlock_all",
        ),
        (
            "SELECT * FROM t WHERE id IN (SELECT pg_terminate_backend(pid) FROM s)",
            "postgres",
            "pg_terminate_backend",
        ),
        (
            "WITH w AS (SELECT set_config('a.b', '1', false)) SELECT * FROM w",
            "postgres",
            "set_config",
        ),
        (
            "SELECT * FROM dblink('host=x', 'SELECT 1') AS d(a int)",
            "postgres",
            "dblink",
        ),
        (
            "SELECT * FROM t, LATERAL public.dblink_exec('host=x', 'DELETE FROM y') d",
            "postgres",
            "dblink_exec",
        ),
        (
            "SELECT * FROM t ORDER BY pg_sleep_for('1 hour')",
            "postgres",
            "pg_sleep_for",
        ),
        ("SELECT lo_export(1, '/tmp/x')", "postgres", "lo_export"),
        ("SELECT coalesce(nextval('s'), 0)", "postgres", "nextval"),
        ("SELECT GET_LOCK('a', 10)", "mysql", "GET_LOCK"),
        ("SELECT * FROM t WHERE SLEEP(5) = 0", "mysql", "SLEEP"),
        (
            "SELECT (SELECT BENCHMARK(1000000, MD5('a')))",
            "mysql",
            "BENCHMARK",
        ),
        ("SELECT LOAD_FILE('/etc/passwd')", "mysql", "LOAD_FILE"),
        (
            "SELECT SOURCE_POS_WAIT('log', 4)",
            "mysql",
            "SOURCE_POS_WAIT",
        ),
        (
            "SELECT sleepEachRow(1) FROM t",
            "clickhouse",
            "sleepEachRow",
        ),
        (
            "SELECT * FROM url('http://x/a.csv', CSV)",
            "clickhouse",
            "url",
        ),
        (
            "SELECT * FROM remoteSecure('host:9440', db.t)",
            "clickhouse",
            "remoteSecure",
        ),
        (
            "SELECT * FROM s3('https://b/k.parquet')",
            "clickhouse",
            "s3",
        ),
        (
            "SELECT count() FROM executable('x.sh', TSV, 'a String')",
            "clickhouse",
            "executable",
        ),
        ("SELECT pg_notify('c', 'x')", "generic", "pg_notify"),
        ("SELECT sleep(1)", "generic", "sleep"),
        ("SELECT * FROM file('a.csv')", "generic", "file"),
    ] {
        let error = inspect(sql, dialect).expect_err(sql);
        assert_eq!(error.code, "side_effect_function", "{sql}");
        assert!(
            error.message.starts_with(function),
            "{sql}: {}",
            error.message
        );
    }
}

#[test]
fn ordinary_functions_pass() {
    for dialect in ["postgres", "mysql", "clickhouse", "generic"] {
        ok(
            "SELECT lower(name), coalesce(region, 'none'), sum(amount) FROM orders \
             WHERE upper(status) = 'PAID' GROUP BY 1, 2",
            dialect,
        );
    }
    ok(
        "SELECT date_trunc('month', created_at), sum(amount) FROM orders \
         CROSS JOIN LATERAL generate_series(1, 3) g GROUP BY 1",
        "postgres",
    );
    // Each denylist belongs to its own dialect.
    ok("SELECT sleep(1)", "postgres");
    ok("SELECT pg_notify('c', 'x')", "mysql");
}

#[test]
fn window_functions_are_not_aggregates() {
    let result = ok(
        "SELECT SUM(amount) OVER (PARTITION BY cid) FROM a JOIN b ON a.id = b.aid",
        "postgres",
    );
    assert_eq!(result["fanout_risk"], false);
}

#[test]
fn deeply_nested_queries_fail_cleanly_on_small_thread_stacks() {
    let deep_parens = format!("SELECT {}1{}", "(".repeat(2_000), ")".repeat(2_000));
    let deep_and = std::iter::repeat_n("a=1", 80_000)
        .collect::<Vec<_>>()
        .join(" OR ");
    let queries = [
        deep_parens,
        format!("SELECT a FROM t WHERE {deep_and}"),
        format!("SELECT a FROM t ORDER BY {deep_and}"),
        format!("SELECT coalesce({deep_and}, false) FROM t"),
        format!("SELECT a FROM t JOIN u ON {deep_and}"),
        format!("SELECT a FROM t WHERE {deep_and} +"),
        format!("DELETE FROM t WHERE {deep_and}"),
        format!("SELECT 1::int{}", "[]".repeat(80_000)),
        format!("CREATE TABLE t(x int{})", "[]".repeat(80_000)),
        std::iter::repeat_n("SELECT 1", 30_000)
            .collect::<Vec<_>>()
            .join(" UNION ALL "),
    ];

    let handle = std::thread::Builder::new()
        .stack_size(512 * 1024)
        .spawn(move || {
            for sql in queries {
                assert_eq!(code(&sql, "postgres"), "parse_error");
            }
            assert_eq!(
                code(
                    &format!(
                        "SELECT * FROM t{}{}",
                        " JOIN t".repeat(20_000),
                        " ON true".repeat(20_000)
                    ),
                    "postgres"
                ),
                "parse_error"
            );
            for sql in [
                format!(
                    "SELECT * FROM t{}",
                    " PIVOT(SUM(x) FOR y IN(1))".repeat(20_000)
                ),
                format!(
                    "SELECT * FROM t MATCH_RECOGNIZE (PATTERN ({}A{}) DEFINE A AS true)",
                    "(".repeat(20_000),
                    ")".repeat(20_000)
                ),
            ] {
                assert_eq!(code(&sql, "generic"), "parse_error");
            }
        })
        .unwrap();
    handle.join().unwrap();
}

#[test]
fn independent_expressions_do_not_share_a_depth_budget() {
    let projection = std::iter::repeat_n("1 + 2", 2_000)
        .collect::<Vec<_>>()
        .join(", ");
    ok(&format!("SELECT {projection}"), "postgres");
    ok("SELECT 1 + 2 UNION ALL SELECT 3 + 4", "postgres");
}

#[test]
fn dialect_readonly_fallback_accepts_unparsed_select_and_preserves_rejections() {
    // Postgres-wire engines (such as DuckDB / CedarDB / custom extensions) accept `SELECT *
    // EXCEPT (...)`, which PostgreSqlDialect rejects at the AST grammar layer, triggering the
    // token-level readonly fallback.
    let dialect_sql = "SELECT * EXCEPT (secret_hash) FROM users WHERE active = true;";
    assert!(
        Parser::new(&PostgreSqlDialect {})
            .try_with_sql(dialect_sql)
            .and_then(|mut p| p.parse_statements())
            .is_err()
    );
    assert_eq!(
        ok(dialect_sql, "postgres"),
        json!({ "tables": [], "fanout_risk": false, "dialect_fallback": true })
    );

    // String literals `'update'` and `';'` tokenize as SingleQuotedString and are never falsely rejected.
    let literal_sql =
        "SELECT * EXCEPT (secret_hash) FROM users WHERE action = 'update' AND sep <> ';';";
    assert_eq!(
        ok(literal_sql, "postgres"),
        json!({ "tables": [], "fanout_risk": false, "dialect_fallback": true })
    );

    // Non-SELECT statements, multi-statements, locking clauses, and side-effect functions remain rejected
    // both via AST and when embedded inside dialect-fallback queries.
    assert_eq!(code("SHOW TABLES", "mysql"), "not_read_only");
    assert!(inspect("SHOW ENGINE ROCKSDB TRANSACTION STATUS", "mysql").is_err());
    assert_eq!(
        code("SELECT 1; SELECT 2", "postgres"),
        "multiple_statements"
    );
    assert!(
        inspect(
            "SELECT * EXCEPT (secret_hash) FROM users; SELECT 2",
            "postgres"
        )
        .is_err()
    );
    assert_eq!(
        code("SELECT * FROM t FOR UPDATE", "postgres"),
        "locking_clause"
    );
    assert!(
        inspect(
            "SELECT * EXCEPT (secret_hash) FROM users FOR UPDATE",
            "postgres"
        )
        .is_err()
    );
    assert!(
        inspect(
            "SELECT * EXCEPT (secret_hash), pg_terminate_backend(1) FROM users",
            "postgres"
        )
        .is_err()
    );
    assert!(
        inspect(
            "SELECT * EXCEPT (secret_hash), set_config('work_mem', '64MB', true) FROM users",
            "postgres"
        )
        .is_err()
    );
    assert!(
        inspect(
            "SELECT * EXCEPT (secret_hash), sleep(5) FROM users",
            "mysql"
        )
        .is_err()
    );
}
