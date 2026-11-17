//! Read-only inspection of one SQL query.
//!
//! The control plane uses this module before it sends model-written SQL to an
//! external database. `inspect` accepts exactly one `SELECT` or `WITH` query and
//! rejects writes, locking clauses, calls to built-in functions with side
//! effects, and other statements. For an accepted query
//! it returns the referenced base tables and whether a join carries fan-out
//! aggregation risk. The module does no I/O and keeps no state.
//!
//! The check is syntactic. It recognizes side-effecting built-in functions by
//! name, but it cannot see what a user-defined function does, so the caller
//! must also open a read-only session with a role that may execute only the
//! functions it trusts.

use std::collections::{HashMap, HashSet};
use std::ops::ControlFlow;

use serde_json::{Value as JSONValue, json};
use sqlparser::ast::{
    DuplicateTreatment, Expr, Function, FunctionArguments, GroupByExpr, InTarget, ObjectName,
    Query, Select, SetExpr, Statement, TableFactor, Visit, Visitor, visit_expressions,
};
use sqlparser::dialect::{
    ClickHouseDialect, Dialect, GenericDialect, MySqlDialect, PostgreSqlDialect,
};
use sqlparser::parser::{Parser, ParserError};
use sqlparser::tokenizer::{Token, Tokenizer};

/// Inputs larger than this fail with `parse_error`.
pub const MAX_SQL_BYTES: usize = 1024 * 1024;
const MAX_AST_DEPTH: usize = 256;
const STACK_RED_ZONE: usize = 2 * 1024 * 1024;
const STACK_GROW_BYTES: usize = 8 * 1024 * 1024;

/// Aggregate function names, in lower case. ClickHouse `-If` combinators such as
/// `sumIf` also count as aggregates.
const AGGREGATES: &[&str] = &[
    "sum",
    "count",
    "avg",
    "min",
    "max",
    "array_agg",
    "string_agg",
    "group_concat",
    "listagg",
    "json_agg",
    "jsonb_agg",
    "json_object_agg",
    "jsonb_object_agg",
    "json_arrayagg",
    "json_objectagg",
    "bool_and",
    "bool_or",
    "every",
    "bit_and",
    "bit_or",
    "bit_xor",
    "stddev",
    "stddev_pop",
    "stddev_samp",
    "std",
    "variance",
    "var_pop",
    "var_samp",
    "median",
    "mode",
    "percentile_cont",
    "percentile_disc",
    "corr",
    "covar_pop",
    "covar_samp",
    "any_value",
    "approx_count_distinct",
    "uniq",
    "uniqexact",
    "uniqcombined",
    "grouparray",
    "groupuniqarray",
    "quantile",
    "quantiles",
    "quantileexact",
    "argmin",
    "argmax",
    "topk",
];

/// Aggregates whose result does not change when a join repeats input rows.
const DUPLICATE_INSENSITIVE: &[&str] = &[
    "min",
    "max",
    "bool_and",
    "bool_or",
    "every",
    "bit_and",
    "bit_or",
    "any_value",
    "approx_count_distinct",
    "uniq",
    "uniqexact",
    "uniqcombined",
    "groupuniqarray",
    "argmin",
    "argmax",
];

/// Built-in PostgreSQL functions with effects outside the query result: they
/// notify listeners, take locks that outlive the statement, signal or
/// reconfigure the server, write WAL, files, large objects, or replication
/// state, reach another server, or sleep through the time budget. A `READ
/// ONLY` transaction still allows most of them. Names are lower case, and a
/// trailing `*` matches a prefix.
const POSTGRES_SIDE_EFFECTS: &[&str] = &[
    "pg_notify",
    "pg_advisory_*",
    "pg_try_advisory_*",
    "pg_cancel_backend",
    "pg_terminate_backend",
    "pg_reload_conf",
    "pg_rotate_logfile",
    "pg_log_backend_memory_contexts",
    "pg_log_standby_snapshot",
    "pg_switch_wal",
    "pg_switch_xlog",
    "pg_create_restore_point",
    "pg_backup_start",
    "pg_backup_stop",
    "pg_start_backup",
    "pg_stop_backup",
    "pg_wal_replay_pause",
    "pg_wal_replay_resume",
    "pg_promote",
    "pg_logical_emit_message",
    "pg_logical_slot_get_changes",
    "pg_logical_slot_get_binary_changes",
    "pg_create_physical_replication_slot",
    "pg_create_logical_replication_slot",
    "pg_copy_physical_replication_slot",
    "pg_copy_logical_replication_slot",
    "pg_drop_replication_slot",
    "pg_replication_slot_advance",
    "pg_replication_origin_create",
    "pg_replication_origin_drop",
    "pg_replication_origin_advance",
    "pg_replication_origin_session_setup",
    "pg_replication_origin_session_reset",
    "pg_replication_origin_xact_setup",
    "pg_replication_origin_xact_reset",
    "pg_stat_reset*",
    "pg_stat_statements_reset",
    "set_config",
    "nextval",
    "setval",
    "lo_import",
    "lo_export",
    "lo_unlink",
    "lo_create",
    "lo_creat",
    "lo_from_bytea",
    "lo_put",
    "lowrite",
    "lo_truncate",
    "lo_truncate64",
    "pg_file_write",
    "pg_file_rename",
    "pg_file_unlink",
    "pg_file_sync",
    "dblink",
    "dblink_*",
    "pg_sleep*",
];

/// Built-in MySQL and MariaDB functions that take named locks, read server
/// files, or wait through the time budget.
const MYSQL_SIDE_EFFECTS: &[&str] = &[
    "get_lock",
    "release_lock",
    "release_all_locks",
    "sleep",
    "benchmark",
    "load_file",
    "master_pos_wait",
    "source_pos_wait",
    "master_gtid_wait",
    "wait_for_executed_gtid_set",
];

/// ClickHouse requests run with `readonly=1`. These functions still sleep
/// through the time budget or reach files, processes, and external systems.
const CLICKHOUSE_SIDE_EFFECTS: &[&str] = &[
    "sleep",
    "sleepeachrow",
    "url",
    "urlcluster",
    "remote",
    "remotesecure",
    "mysql",
    "postgresql",
    "mongodb",
    "redis",
    "sqlite",
    "jdbc",
    "odbc",
    "s3",
    "s3cluster",
    "gcs",
    "azureblobstorage",
    "azureblobstoragecluster",
    "hdfs",
    "hdfscluster",
    "iceberg",
    "deltalake",
    "hudi",
    "file",
    "filecluster",
    "executable",
];

/// A rejection. `code` is one of `parse_error`, `multiple_statements`,
/// `not_read_only`, `locking_clause`, `side_effect_function`, or `empty`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InspectError {
    pub code: &'static str,
    pub message: String,
}

impl InspectError {
    pub fn parse(message: impl Into<String>) -> Self {
        Self::new("parse_error", message)
    }

    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    fn not_read_only(message: impl Into<String>) -> Self {
        Self::new("not_read_only", message)
    }

    pub fn to_json(&self) -> JSONValue {
        json!({ "code": self.code, "message": self.message })
    }
}

/// Inspects one read-only query. `dialect` is `postgres`, `mysql`,
/// `clickhouse`, or `generic`.
///
/// The success value is a JSON object with string keys `tables` and
/// `fanout_risk`, plus optional `"dialect_fallback": true` when
/// `try_dialect_readonly_fallback` validates an engine-specific `SELECT` or
/// `WITH` query that `sqlparser`'s grammar rejected. `Ankole.Kernel.sql_inspect/2`
/// documents the primary keys.
pub fn inspect(sql: &str, dialect: &str) -> Result<JSONValue, InspectError> {
    stacker::maybe_grow(STACK_RED_ZONE, STACK_GROW_BYTES, || {
        inspect_inner(sql, dialect)
    })
}

fn inspect_inner(sql: &str, dialect: &str) -> Result<JSONValue, InspectError> {
    let (dialect, side_effects): (Box<dyn Dialect>, &'static [&'static [&'static str]]) =
        match dialect {
            "postgres" => (Box::new(PostgreSqlDialect {}), &[POSTGRES_SIDE_EFFECTS]),
            "mysql" => (Box::new(MySqlDialect {}), &[MYSQL_SIDE_EFFECTS]),
            "clickhouse" => (Box::new(ClickHouseDialect {}), &[CLICKHOUSE_SIDE_EFFECTS]),
            "generic" => (
                Box::new(GenericDialect {}),
                &[
                    POSTGRES_SIDE_EFFECTS,
                    MYSQL_SIDE_EFFECTS,
                    CLICKHOUSE_SIDE_EFFECTS,
                ],
            ),
            other => return Err(InspectError::parse(format!("unsupported dialect {other}"))),
        };
    if sql.len() > MAX_SQL_BYTES {
        return Err(InspectError::parse(format!(
            "SQL exceeds the maximum size of {MAX_SQL_BYTES} bytes"
        )));
    }
    if sql.trim().is_empty() {
        return Err(InspectError::new("empty", "SQL is empty"));
    }

    let statements = match Parser::new(dialect.as_ref())
        .with_recursion_limit(MAX_AST_DEPTH)
        .try_with_sql(sql)
        .and_then(|mut parser| parser.parse_statements())
    {
        Ok(statements) => statements,
        Err(error) => {
            // sqlparser does not parse the MySQL `LOCK IN SHARE MODE` suffix.
            if has_lock_in_share_mode(dialect.as_ref(), sql) {
                return Err(InspectError::new(
                    "locking_clause",
                    "LOCK IN SHARE MODE locks rows",
                ));
            }
            if matches!(error, ParserError::ParserError(_))
                && let Ok(fallback) =
                    try_dialect_readonly_fallback(sql, dialect.as_ref(), side_effects)
            {
                return Ok(fallback);
            }
            return Err(InspectError::parse(error.to_string()));
        }
    };
    let statement = match statements.as_slice() {
        [] => return Err(InspectError::new("empty", "SQL contains no statement")),
        [statement] => statement,
        _ => {
            return Err(InspectError::new(
                "multiple_statements",
                "SQL must contain exactly one statement",
            ));
        }
    };
    if !matches!(statement, Statement::Query(_)) {
        return Err(InspectError::not_read_only(
            "only SELECT and WITH queries are allowed",
        ));
    }

    let mut inspector = Inspector {
        side_effects,
        ..Inspector::default()
    };
    if let ControlFlow::Break(error) = statement.visit(&mut inspector) {
        return Err(error);
    }
    Ok(inspector.finish())
}

const FALLBACK_DENIED_KEYWORDS: &[&str] = &[
    "INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "TRUNCATE", "CREATE", "GRANT", "REVOKE", "SET",
    "RESET", "COPY", "CALL", "DO", "EXEC", "EXECUTE", "MERGE", "REPLACE", "LOAD", "VACUUM",
    "ANALYZE", "ATTACH", "DETACH", "PRAGMA", "USE", "LOCK", "UNLOCK", "INTO", "OUTFILE",
    "DUMPFILE",
];

const FALLBACK_DANGLING_TAIL_KEYWORDS: &[&str] = &[
    "SELECT",
    "WITH",
    "FROM",
    "WHERE",
    "JOIN",
    "INNER",
    "LEFT",
    "RIGHT",
    "FULL",
    "CROSS",
    "ON",
    "USING",
    "GROUP",
    "ORDER",
    "PARTITION",
    "BY",
    "HAVING",
    "LIMIT",
    "OFFSET",
    "UNION",
    "INTERSECT",
    "EXCEPT",
    "AS",
    "AND",
    "OR",
    "NOT",
    "IN",
    "IS",
    "LIKE",
    "ILIKE",
    "BETWEEN",
    "CASE",
    "WHEN",
    "THEN",
    "ELSE",
];

const FALLBACK_SIDE_EFFECT_FUNCTIONS: &[&str] = &[
    "sleep",
    "sleepeachrow",
    "benchmark",
    "get_lock",
    "release_lock",
    "release_all_locks",
    "load_file",
    "nextval",
    "setval",
    "currval",
    "lastval",
];

fn matches_denylist(lower: &str, list: &[&str]) -> bool {
    list.iter().any(|entry| match entry.strip_suffix('*') {
        Some(prefix) => lower.starts_with(prefix),
        None => lower == *entry,
    })
}

fn is_postgres_side_effect(lower: &str) -> bool {
    matches_denylist(lower, POSTGRES_SIDE_EFFECTS)
}

/// Token-level fallback when `sqlparser`'s grammar rejects dialect-specific `SELECT` / `WITH`
/// syntax (never invoked when AST parsing succeeded and rejected the statement semantically, or
/// when recursion depth was exceeded).
fn try_dialect_readonly_fallback(
    sql: &str,
    dialect: &dyn Dialect,
    side_effects: &[&[&str]],
) -> Result<JSONValue, ()> {
    let raw_tokens = Tokenizer::new(dialect, sql).tokenize().map_err(|_| ())?;
    let mut tokens: Vec<&Token> = raw_tokens
        .iter()
        .filter(|token| !matches!(token, Token::Whitespace(_)))
        .collect();
    while matches!(tokens.last(), Some(Token::SemiColon)) {
        tokens.pop();
    }
    if tokens.is_empty() || tokens.iter().any(|token| matches!(token, Token::SemiColon)) {
        return Err(());
    }

    let Some(Token::Word(first)) = tokens.first() else {
        return Err(());
    };
    if first.quote_style.is_some()
        || !matches!(first.value.to_ascii_uppercase().as_str(), "SELECT" | "WITH")
    {
        return Err(());
    }

    match tokens.last() {
        Some(Token::Word(last))
            if last.quote_style.is_none()
                && FALLBACK_DANGLING_TAIL_KEYWORDS
                    .contains(&last.value.to_ascii_uppercase().as_str()) =>
        {
            return Err(());
        }
        Some(
            Token::Comma
            | Token::Period
            | Token::DoubleColon
            | Token::Plus
            | Token::Minus
            | Token::Div
            | Token::Mod
            | Token::Eq
            | Token::Neq
            | Token::Lt
            | Token::Gt
            | Token::LtEq
            | Token::GtEq,
        ) => return Err(()),
        _ => {}
    }

    let mut paren_depth: usize = 0;
    let mut bracket_depth: usize = 0;
    let mut brace_depth: usize = 0;

    for (index, token) in tokens.iter().enumerate() {
        match token {
            Token::LParen => {
                paren_depth += 1;
                if paren_depth > MAX_AST_DEPTH {
                    return Err(());
                }
            }
            Token::RParen => {
                paren_depth = paren_depth.checked_sub(1).ok_or(())?;
            }
            Token::LBracket => {
                bracket_depth += 1;
                if bracket_depth > MAX_AST_DEPTH {
                    return Err(());
                }
            }
            Token::RBracket => {
                bracket_depth = bracket_depth.checked_sub(1).ok_or(())?;
            }
            Token::LBrace => {
                brace_depth += 1;
                if brace_depth > MAX_AST_DEPTH {
                    return Err(());
                }
            }
            Token::RBrace => {
                brace_depth = brace_depth.checked_sub(1).ok_or(())?;
            }
            Token::Word(word) => {
                if word.quote_style.is_none() {
                    let upper = word.value.to_ascii_uppercase();
                    if FALLBACK_DENIED_KEYWORDS.contains(&upper.as_str()) {
                        return Err(());
                    }
                    if upper == "FOR"
                        && let Some(Token::Word(next)) = tokens.get(index + 1)
                        && next.quote_style.is_none()
                        && matches!(
                            next.value.to_ascii_uppercase().as_str(),
                            "UPDATE" | "SHARE" | "NO" | "KEY"
                        )
                    {
                        return Err(());
                    }
                }

                let lower = word.value.to_ascii_lowercase();
                if is_postgres_side_effect(&lower)
                    || matches_denylist(&lower, FALLBACK_SIDE_EFFECT_FUNCTIONS)
                {
                    return Err(());
                }
                if matches!(tokens.get(index + 1), Some(Token::LParen))
                    && side_effects
                        .iter()
                        .any(|list| matches_denylist(&lower, list))
                {
                    return Err(());
                }
            }
            _ => {}
        }
    }

    if paren_depth != 0 || bracket_depth != 0 || brace_depth != 0 {
        return Err(());
    }

    Ok(json!({
        "tables": [],
        "fanout_risk": false,
        "dialect_fallback": true,
    }))
}

fn has_lock_in_share_mode(dialect: &dyn Dialect, sql: &str) -> bool {
    let Ok(tokens) = Tokenizer::new(dialect, sql).tokenize() else {
        return false;
    };
    let words: Vec<Option<String>> = tokens
        .iter()
        .filter(|token| !matches!(token, Token::Whitespace(_)))
        .map(|token| match token {
            Token::Word(word) if word.quote_style.is_none() => Some(word.value.to_uppercase()),
            _ => None,
        })
        .collect();
    words.windows(4).any(|window| {
        matches!(window, [Some(a), Some(b), Some(c), Some(d)]
            if a == "LOCK" && b == "IN" && c == "SHARE" && d == "MODE")
    })
}

type TableRef = (Option<String>, Option<String>, String);

#[derive(Default)]
struct Inspector {
    /// Denylists of side-effecting built-in functions for the dialect.
    side_effects: &'static [&'static [&'static str]],
    /// Lower-case CTE name to whether the CTE is pre-aggregated.
    ctes: HashMap<String, bool>,
    tables: Vec<TableRef>,
    fanout_risk: bool,
    depth: usize,
}

impl Inspector {
    fn finish(self) -> JSONValue {
        let ctes = self.ctes;
        let tables: Vec<JSONValue> = self
            .tables
            .into_iter()
            .filter(|(catalog, schema, name)| {
                catalog.is_some() || schema.is_some() || !ctes.contains_key(&name.to_lowercase())
            })
            .map(|(catalog, schema, name)| {
                json!({ "catalog": catalog, "schema": schema, "name": name })
            })
            .collect();
        json!({
            "tables": tables,
            "fanout_risk": self.fanout_risk,
        })
    }

    fn add_table(&mut self, name: &ObjectName) {
        if let Some(table) = table_ref(name)
            && !self.tables.contains(&table)
        {
            self.tables.push(table);
        }
    }

    fn add_set_expr_tables(&mut self, body: &SetExpr) {
        let mut stack = vec![body];
        while let Some(current) = stack.pop() {
            match current {
                SetExpr::SetOperation { left, right, .. } => {
                    stack.push(right);
                    stack.push(left);
                }
                // PostgreSQL `TABLE name` reads a whole table.
                SetExpr::Table(table) => {
                    if let Some(name) = &table.table_name {
                        let table = (
                            None,
                            table
                                .schema_name
                                .as_ref()
                                .map(|schema| schema.value.clone()),
                            name.value.clone(),
                        );
                        if !self.tables.contains(&table) {
                            self.tables.push(table);
                        }
                    }
                }
                _ => {}
            }
        }
    }

    /// Rejects a call whose last name part is a denylisted built-in, so a
    /// schema-qualified call such as `pg_catalog.pg_notify` also fails.
    fn check_function(&self, name: &ObjectName) -> ControlFlow<InspectError> {
        let Some(function) = name.0.last().and_then(|part| part.as_ident()) else {
            return ControlFlow::Continue(());
        };
        let lower = function.value.to_lowercase();
        let denied = self
            .side_effects
            .iter()
            .any(|list| matches_denylist(&lower, list));
        if denied {
            ControlFlow::Break(InspectError::new(
                "side_effect_function",
                format!(
                    "{} has side effects outside the query result",
                    function.value
                ),
            ))
        } else {
            ControlFlow::Continue(())
        }
    }
}

impl Visitor for Inspector {
    type Break = InspectError;

    fn pre_visit_statement(&mut self, statement: &Statement) -> ControlFlow<InspectError> {
        // A data-modifying CTE body is a nested INSERT, UPDATE, DELETE, or MERGE statement.
        if matches!(statement, Statement::Query(_)) {
            ControlFlow::Continue(())
        } else {
            ControlFlow::Break(InspectError::not_read_only(
                "the query contains a statement that is not a SELECT",
            ))
        }
    }

    fn pre_visit_query(&mut self, query: &Query) -> ControlFlow<InspectError> {
        if self.depth >= MAX_AST_DEPTH {
            return ControlFlow::Break(InspectError::parse(
                "SQL exceeds maximum expression nesting depth",
            ));
        }
        self.depth += 1;
        if !query.locks.is_empty() {
            return ControlFlow::Break(InspectError::new(
                "locking_clause",
                "FOR UPDATE and FOR SHARE lock rows",
            ));
        }
        if let Some(with) = &query.with {
            for cte in &with.cte_tables {
                self.ctes.insert(
                    cte.alias.name.value.to_lowercase(),
                    query_pre_aggregated(&cte.query),
                );
            }
        }
        self.add_set_expr_tables(&query.body);
        ControlFlow::Continue(())
    }

    fn post_visit_query(&mut self, _query: &Query) -> ControlFlow<InspectError> {
        self.depth = self.depth.saturating_sub(1);
        ControlFlow::Continue(())
    }

    fn pre_visit_select(&mut self, select: &Select) -> ControlFlow<InspectError> {
        if select.into.is_some() {
            return ControlFlow::Break(InspectError::not_read_only("SELECT INTO writes a table"));
        }
        self.fanout_risk |= select_fanout_risk(select, &self.ctes);
        ControlFlow::Continue(())
    }

    fn pre_visit_table_factor(&mut self, factor: &TableFactor) -> ControlFlow<InspectError> {
        match factor {
            TableFactor::Table {
                name, args: None, ..
            } => self.add_table(name),
            // A table factor with arguments is a table function such as `generate_series(1, 3)`.
            TableFactor::Table { name, .. } | TableFactor::Function { name, .. } => {
                self.check_function(name)?
            }
            _ => {}
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<InspectError> {
        if self.depth >= MAX_AST_DEPTH {
            return ControlFlow::Break(InspectError::parse(
                "SQL exceeds maximum expression nesting depth",
            ));
        }
        self.depth += 1;
        match expr {
            Expr::Function(function) => {
                self.check_function(&function.name)?;
            }
            Expr::In {
                target: InTarget::Table { name, args, .. },
                ..
            } => {
                if args.is_some() {
                    self.check_function(name)?;
                } else {
                    self.add_table(name);
                }
            }
            _ => {}
        }
        ControlFlow::Continue(())
    }

    fn post_visit_expr(&mut self, _expr: &Expr) -> ControlFlow<InspectError> {
        self.depth = self.depth.saturating_sub(1);
        ControlFlow::Continue(())
    }
}

/// Splits `[catalog.][schema.]name`. Names with more than three parts keep the last three.
fn table_ref(name: &ObjectName) -> Option<TableRef> {
    let mut parts = name
        .0
        .iter()
        .rev()
        .filter_map(|part| part.as_ident().map(|ident| ident.value.clone()));
    let table = parts.next()?;
    let schema = parts.next();
    let catalog = parts.next();
    Some((catalog, schema, table))
}

/// Returns the table qualifier (if any) for a column reference.
fn column_table_qualifier(expr: &Expr) -> Option<Option<&str>> {
    match expr {
        Expr::Identifier(_) => Some(None),
        Expr::CompoundIdentifier(parts) => {
            let (_name, qualifier) = parts.split_last()?;
            Some(qualifier.last().map(|part| part.value.as_str()))
        }
        _ => None,
    }
}

/// Returns the lower-case aggregate name. Window calls with `OVER` are not aggregates.
fn aggregate_name(function: &Function) -> Option<String> {
    if function.over.is_some() {
        return None;
    }
    let name = function.name.0.last()?.as_ident()?.value.to_lowercase();
    let base = name.strip_suffix("if").unwrap_or(&name);
    if !AGGREGATES.contains(&name.as_str()) && !AGGREGATES.contains(&base) {
        return None;
    }
    Some(name)
}

fn is_distinct(function: &Function) -> bool {
    matches!(&function.args, FunctionArguments::List(list)
        if list.duplicate_treatment == Some(DuplicateTreatment::Distinct))
}

fn duplicate_sensitive(function: &Function, name: &str) -> bool {
    let base = name.strip_suffix("if").unwrap_or(name);
    !is_distinct(function)
        && !DUPLICATE_INSENSITIVE.contains(&name)
        && !DUPLICATE_INSENSITIVE.contains(&base)
}

/// A query is pre-aggregated when its body is one `SELECT` with `GROUP BY`,
/// `DISTINCT`, or an aggregate in the projection.
fn query_pre_aggregated(query: &Query) -> bool {
    let SetExpr::Select(select) = query.body.as_ref() else {
        return false;
    };
    let grouped = match &select.group_by {
        GroupByExpr::All(_) => true,
        GroupByExpr::Expressions(expressions, _) => !expressions.is_empty(),
    };
    grouped
        || select.distinct.is_some()
        || visit_expressions(&select.projection, |expr| match expr {
            Expr::Function(function) if aggregate_name(function).is_some() => {
                ControlFlow::Break(())
            }
            _ => ControlFlow::Continue(()),
        })
        .is_break()
}

/// Fan-out heuristic for one `SELECT`.
///
/// A join can repeat the rows of one side, so a duplicate-sensitive aggregate
/// such as `SUM` or `COUNT` over the join can count the same row more than once.
/// The heuristic flags a `SELECT` when all of these hold:
///
/// - The `FROM` clause has two or more relations (`JOIN` or comma join).
/// - Its projection or `HAVING` calls a duplicate-sensitive aggregate. `MIN`,
///   `MAX`, and `DISTINCT` aggregates such as `COUNT(DISTINCT ...)` are
///   duplicate-insensitive.
/// - That aggregate reads `*`, an unqualified column, or a column whose
///   qualifier is not a pre-aggregated derived table or CTE.
///
/// The heuristic is conservative. It does not read join keys, so it also flags
/// safe N:1 joins. The caller treats the flag as a warning.
fn select_fanout_risk(select: &Select, ctes: &HashMap<String, bool>) -> bool {
    let mut factors = Vec::new();
    for from in &select.from {
        push_factors(&from.relation, &mut factors);
        for join in &from.joins {
            push_factors(&join.relation, &mut factors);
        }
    }
    if factors.len() < 2 {
        return false;
    }
    let pre_aggregated: HashSet<String> = factors
        .iter()
        .filter_map(|factor| match factor {
            TableFactor::Derived {
                subquery,
                alias: Some(alias),
                ..
            } if query_pre_aggregated(subquery) => Some(alias.name.value.to_lowercase()),
            TableFactor::Table {
                name,
                alias,
                args: None,
                ..
            } if name.0.len() == 1 => {
                let table = table_ref(name)?.2.to_lowercase();
                (ctes.get(&table) == Some(&true)).then(|| match alias {
                    Some(alias) => alias.name.value.to_lowercase(),
                    None => table,
                })
            }
            _ => None,
        })
        .collect();
    let mut scan = FanoutScan {
        pre_aggregated,
        depth: 0,
        risk: false,
    };
    let _ = select.projection.visit(&mut scan);
    let _ = select.having.visit(&mut scan);
    scan.risk
}

fn push_factors<'a>(factor: &'a TableFactor, out: &mut Vec<&'a TableFactor>) {
    let mut stack = vec![factor];
    while let Some(current) = stack.pop() {
        if let TableFactor::NestedJoin {
            table_with_joins, ..
        } = current
        {
            for join in table_with_joins.joins.iter().rev() {
                stack.push(&join.relation);
            }
            stack.push(&table_with_joins.relation);
        } else {
            out.push(current);
        }
    }
}

/// Finds risky aggregate calls of one `SELECT`. Subqueries are scanned when the
/// inspector visits their own `SELECT`, so this scan skips them.
struct FanoutScan {
    pre_aggregated: HashSet<String>,
    depth: usize,
    risk: bool,
}

impl Visitor for FanoutScan {
    type Break = ();

    fn pre_visit_query(&mut self, _query: &Query) -> ControlFlow<()> {
        self.depth += 1;
        ControlFlow::Continue(())
    }

    fn post_visit_query(&mut self, _query: &Query) -> ControlFlow<()> {
        self.depth -= 1;
        ControlFlow::Continue(())
    }

    fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<()> {
        let Expr::Function(function) = expr else {
            return ControlFlow::Continue(());
        };
        if self.depth > 0 {
            return ControlFlow::Continue(());
        }
        let Some(name) = aggregate_name(function) else {
            return ControlFlow::Continue(());
        };
        if !duplicate_sensitive(function, &name) {
            return ControlFlow::Continue(());
        }
        let mut references = 0;
        let mut outside_pre_aggregated = false;
        let _ = visit_expressions(&function.args, |arg| {
            if let Some(qualifier) = column_table_qualifier(arg) {
                references += 1;
                let table = qualifier.map(str::to_lowercase);
                outside_pre_aggregated |=
                    !table.is_some_and(|table| self.pre_aggregated.contains(&table));
            }
            ControlFlow::<()>::Continue(())
        });
        if references == 0 || outside_pre_aggregated {
            self.risk = true;
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }
}

#[cfg(test)]
mod tests;
