//! Read-only inspection of one SQL query.
//!
//! The control plane uses this module before it sends model-written SQL to an
//! external database. `inspect` accepts exactly one `SELECT` or `WITH` query and
//! rejects writes, locking clauses, calls to built-in functions with side
//! effects, and other statements. For an accepted query
//! it returns the referenced base tables, columns, aggregate functions, literal
//! predicates in `WHERE` and `HAVING`, and join facts. The module does no I/O and
//! keeps no state.
//!
//! The check is syntactic. It recognizes side-effecting built-in functions by
//! name, but it cannot see what a user-defined function does, so the caller
//! must also open a read-only session with a role that may execute only the
//! functions it trusts.

use std::collections::{HashMap, HashSet};
use std::ops::ControlFlow;

use serde_json::{Value as JSONValue, json};
use sqlparser::ast::{
    BinaryOperator, DuplicateTreatment, Expr, Function, FunctionArguments, GroupByExpr,
    LimitClause, ObjectName, Query, Select, SetExpr, Statement, TableFactor, UnaryOperator, Value,
    Visit, Visitor, visit_expressions,
};
use sqlparser::dialect::{
    ClickHouseDialect, Dialect, GenericDialect, MySqlDialect, PostgreSqlDialect,
};
use sqlparser::parser::Parser;
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
/// The success value is a JSON object with string keys: `kind`, `tables`,
/// `columns`, `aggregates`, `literals`, `joins`, `group_by`, `limit`, and
/// `fanout_risk`. `Ankole.Kernel.sql_inspect/2` documents each key.
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

    let statements = Parser::new(dialect.as_ref())
        .with_recursion_limit(MAX_AST_DEPTH)
        .try_with_sql(sql)
        .and_then(|mut parser| parser.parse_statements())
        .map_err(|error| {
            // sqlparser does not parse the MySQL `LOCK IN SHARE MODE` suffix.
            if has_lock_in_share_mode(dialect.as_ref(), sql) {
                InspectError::new("locking_clause", "LOCK IN SHARE MODE locks rows")
            } else {
                InspectError::parse(error.to_string())
            }
        })?;
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
    let Statement::Query(query) = statement else {
        return Err(InspectError::not_read_only(
            "only SELECT and WITH queries are allowed",
        ));
    };

    let mut inspector = Inspector {
        side_effects,
        ..Inspector::default()
    };
    if let ControlFlow::Break(error) = statement.visit(&mut inspector) {
        return Err(error);
    }
    Ok(inspector.finish(query))
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
type ColumnRef = (Option<String>, String);

#[derive(Default)]
struct Inspector {
    /// Denylists of side-effecting built-in functions for the dialect.
    side_effects: &'static [&'static [&'static str]],
    /// Lower-case CTE name to whether the CTE is pre-aggregated.
    ctes: HashMap<String, bool>,
    tables: Vec<TableRef>,
    columns: Vec<ColumnRef>,
    aggregates: Vec<String>,
    literals: Vec<JSONValue>,
    joins: usize,
    group_by: bool,
    fanout_risk: bool,
    depth: usize,
}

impl Inspector {
    fn finish(self, query: &Query) -> JSONValue {
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
        let columns: Vec<JSONValue> = self
            .columns
            .into_iter()
            .map(|(table, name)| json!({ "table": table, "name": name }))
            .collect();
        json!({
            "kind": if query.with.is_some() { "with" } else { "select" },
            "tables": tables,
            "columns": columns,
            "aggregates": self.aggregates,
            "literals": self.literals,
            "joins": self.joins,
            "group_by": self.group_by,
            "limit": outer_limit(query),
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
                        let table = (None, table.schema_name.clone(), name.clone());
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
            .flat_map(|list| list.iter())
            .any(|entry| match entry.strip_suffix('*') {
                Some(prefix) => lower.starts_with(prefix),
                None => lower == *entry,
            });
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
        self.joins += select
            .from
            .iter()
            .map(|from| from.joins.len())
            .sum::<usize>();
        self.group_by |= match &select.group_by {
            GroupByExpr::All(_) => true,
            GroupByExpr::Expressions(expressions, _) => !expressions.is_empty(),
        };
        for predicate in [&select.selection, &select.having].into_iter().flatten() {
            collect_literals(predicate, &mut self.literals);
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
            TableFactor::NestedJoin {
                table_with_joins, ..
            } => self.joins += table_with_joins.joins.len(),
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
        let column = match expr {
            Expr::Function(function) => {
                self.check_function(&function.name)?;
                if let Some(name) = aggregate_name(function)
                    && !self.aggregates.contains(&name)
                {
                    self.aggregates.push(name);
                }
                None
            }
            _ => column_ref(expr),
        };
        if let Some(column) = column
            && !self.columns.contains(&column)
        {
            self.columns.push(column);
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

/// Returns `(qualifier, name)` for a column reference. The qualifier is every
/// part before the column name, joined with `.`, as written.
fn column_ref(expr: &Expr) -> Option<ColumnRef> {
    match expr {
        Expr::Identifier(ident) => Some((None, ident.value.clone())),
        Expr::CompoundIdentifier(parts) => {
            let (name, qualifier) = parts.split_last()?;
            let qualifier: Vec<&str> = qualifier.iter().map(|part| part.value.as_str()).collect();
            Some((Some(qualifier.join(".")), name.value.clone()))
        }
        _ => None,
    }
}

/// Returns the lower-case aggregate name, or `count_distinct` for
/// `COUNT(DISTINCT ...)`. Window calls with `OVER` are not aggregates.
fn aggregate_name(function: &Function) -> Option<String> {
    if function.over.is_some() {
        return None;
    }
    let name = function.name.0.last()?.as_ident()?.value.to_lowercase();
    let base = name.strip_suffix("if").unwrap_or(&name);
    if !AGGREGATES.contains(&name.as_str()) && !AGGREGATES.contains(&base) {
        return None;
    }
    if name == "count" && is_distinct(function) {
        return Some("count_distinct".to_string());
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
            if let Some((qualifier, _)) = column_ref(arg) {
                references += 1;
                let table = qualifier
                    .as_deref()
                    .and_then(|qualifier| qualifier.rsplit('.').next())
                    .map(str::to_lowercase);
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

/// Collects `column <op> literal` comparisons from the boolean structure of a
/// predicate. Negated forms (`NOT`, `NOT IN`, `NOT LIKE`) and subqueries are skipped.
fn collect_literals(expr: &Expr, out: &mut Vec<JSONValue>) {
    let mut push = |column: ColumnRef, operator: &str, values: Vec<JSONValue>| {
        out.push(json!({
            "column": column.1,
            "table": column.0,
            "operator": operator,
            "values": values,
        }));
    };
    match expr {
        Expr::Nested(inner) => collect_literals(inner, out),
        Expr::BinaryOp {
            left,
            op: BinaryOperator::And | BinaryOperator::Or,
            right,
        } => {
            collect_literals(left, out);
            collect_literals(right, out);
        }
        Expr::BinaryOp { left, op, right } => {
            let Some((operator, flipped)) = comparison(op) else {
                return;
            };
            if let (Some(column), Some(value)) = (column_operand(left), literal(right)) {
                push(column, operator, vec![value]);
            } else if let (Some(column), Some(value)) = (column_operand(right), literal(left)) {
                push(column, flipped, vec![value]);
            }
        }
        Expr::InList {
            expr,
            list,
            negated: false,
        } => {
            let values: Option<Vec<JSONValue>> = list.iter().map(literal).collect();
            if let (Some(column), Some(values)) = (column_operand(expr), values) {
                push(column, "in", values);
            }
        }
        Expr::Like {
            negated: false,
            any: false,
            expr,
            pattern,
            ..
        } => {
            if let (Some(column), Some(value)) = (column_operand(expr), literal(pattern)) {
                push(column, "like", vec![value]);
            }
        }
        Expr::ILike {
            negated: false,
            any: false,
            expr,
            pattern,
            ..
        } => {
            if let (Some(column), Some(value)) = (column_operand(expr), literal(pattern)) {
                push(column, "ilike", vec![value]);
            }
        }
        Expr::Between {
            expr,
            negated: false,
            low,
            high,
        } => {
            if let (Some(column), Some(low), Some(high)) =
                (column_operand(expr), literal(low), literal(high))
            {
                push(column.clone(), ">=", vec![low]);
                push(column, "<=", vec![high]);
            }
        }
        _ => {}
    }
}

/// Returns the operator name and its mirror for `literal <op> column`.
fn comparison(op: &BinaryOperator) -> Option<(&'static str, &'static str)> {
    match op {
        BinaryOperator::Eq => Some(("=", "=")),
        BinaryOperator::NotEq => Some(("<>", "<>")),
        BinaryOperator::Lt => Some(("<", ">")),
        BinaryOperator::LtEq => Some(("<=", ">=")),
        BinaryOperator::Gt => Some((">", "<")),
        BinaryOperator::GtEq => Some((">=", "<=")),
        _ => None,
    }
}

fn column_operand(expr: &Expr) -> Option<ColumnRef> {
    match expr {
        Expr::Nested(inner) => column_operand(inner),
        _ => column_ref(expr),
    }
}

/// Converts a literal operand to JSON. Casts and typed strings such as
/// `DATE '2024-01-01'` yield their literal. Placeholders are not literals.
fn literal(expr: &Expr) -> Option<JSONValue> {
    match expr {
        Expr::Nested(inner) | Expr::Cast { expr: inner, .. } => literal(inner),
        Expr::TypedString(typed) => typed.value.clone().into_string().map(JSONValue::from),
        Expr::UnaryOp {
            op: UnaryOperator::Minus,
            expr: inner,
        } => match inner.as_ref() {
            Expr::Value(value) => match &value.value {
                Value::Number(number, _) => number_json(&format!("-{number}")),
                _ => None,
            },
            _ => None,
        },
        Expr::Value(value) => match &value.value {
            Value::Number(number, _) => number_json(number),
            Value::Boolean(boolean) => Some(JSONValue::Bool(*boolean)),
            Value::Null => Some(JSONValue::Null),
            Value::Placeholder(_) => None,
            other => other.clone().into_string().map(JSONValue::from),
        },
        _ => None,
    }
}

/// Integers stay exact. Other numbers become a float, or the source text when a
/// float cannot hold them.
fn number_json(number: &str) -> Option<JSONValue> {
    if let Ok(integer) = number.parse::<i64>() {
        return Some(integer.into());
    }
    if let Ok(integer) = number.parse::<u64>() {
        return Some(integer.into());
    }
    number
        .parse::<f64>()
        .ok()
        .and_then(serde_json::Number::from_f64)
        .map(JSONValue::Number)
        .or_else(|| Some(JSONValue::String(number.to_string())))
}

fn outer_limit(query: &Query) -> Option<u64> {
    let limit = match &query.limit_clause {
        Some(LimitClause::LimitOffset {
            limit: Some(limit), ..
        })
        | Some(LimitClause::OffsetCommaLimit { limit, .. }) => Some(limit),
        _ => query
            .fetch
            .as_ref()
            .and_then(|fetch| fetch.quantity.as_ref()),
    }?;
    match limit {
        Expr::Value(value) => match &value.value {
            Value::Number(number, _) => number.parse().ok(),
            _ => None,
        },
        _ => None,
    }
}

#[cfg(test)]
mod tests {
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
        assert_eq!(result["kind"], "with");
        assert_eq!(
            result["tables"],
            json!([
                { "catalog": null, "schema": "sales", "name": "orders" },
                { "catalog": "crm", "schema": "public", "name": "customers" },
            ])
        );
        assert!(result["columns"].as_array().is_some_and(|columns| {
            columns.contains(&json!({ "table": "c", "name": "region" }))
                && columns.contains(&json!({ "table": null, "name": "created_at" }))
        }));
        assert_eq!(result["aggregates"], json!(["sum"]));
        assert_eq!(
            result["literals"],
            json!([
                { "column": "created_at", "table": null, "operator": ">=", "values": ["2024-01-01"] },
                { "column": "status", "table": "c", "operator": "in", "values": ["active", "trial"] },
                { "column": "amount", "table": "r", "operator": ">", "values": [-5] },
            ])
        );
        assert_eq!(result["joins"], 1);
        assert_eq!(result["group_by"], true);
        assert_eq!(result["limit"], 10);
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
        assert_eq!(result["kind"], "select");
        assert_eq!(
            result["tables"],
            json!([{ "catalog": null, "schema": "shop", "name": "events" }])
        );
        assert_eq!(result["aggregates"], json!(["count_distinct"]));
        assert_eq!(
            result["literals"],
            json!([
                { "column": "kind", "table": null, "operator": "like", "values": ["click%"] },
                { "column": "score", "table": null, "operator": ">", "values": [3] },
                { "column": "active", "table": null, "operator": "=", "values": [true] },
                { "column": "note", "table": null, "operator": "=", "values": [null] },
            ])
        );
        assert_eq!(result["group_by"], false);
        assert_eq!(result["limit"], 20);
    }

    #[test]
    fn clickhouse_query_facts() {
        let result = ok(
            "SELECT day, sumIf(amount, ok), uniqExact(user) FROM analytics.hits \
             WHERE day BETWEEN '2024-01-01' AND '2024-01-31' GROUP BY day \
             HAVING sumIf(amount, ok) >= 100.5 LIMIT 100",
            "clickhouse",
        );
        assert_eq!(result["aggregates"], json!(["sumif", "uniqexact"]));
        assert_eq!(
            result["literals"],
            json!([
                { "column": "day", "table": null, "operator": ">=", "values": ["2024-01-01"] },
                { "column": "day", "table": null, "operator": "<=", "values": ["2024-01-31"] },
            ])
        );
        assert_eq!(result["limit"], 100);
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
        assert_eq!(
            result["literals"],
            json!([{ "column": "x", "table": null, "operator": "<>", "values": ["y"] }])
        );
        assert_eq!(result["limit"], JSONValue::Null);
        assert_eq!(result["aggregates"], json!([]));
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
        assert_eq!(nested["joins"], 1);
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
        assert_eq!(result["aggregates"], json!([]));
        assert_eq!(result["fanout_risk"], false);
    }

    #[test]
    fn deeply_nested_queries_fail_cleanly_on_small_thread_stacks() {
        let deep_parens = format!("SELECT {}1{}", "(".repeat(2_000), ")".repeat(2_000));
        let deep_and = std::iter::repeat_n("a = 1", 2_000)
            .collect::<Vec<_>>()
            .join(" AND ");
        let deep_where = format!("SELECT a FROM t WHERE {deep_and}");

        let handle = std::thread::Builder::new()
            .stack_size(512 * 1024)
            .spawn(move || {
                assert_eq!(code(&deep_parens, "postgres"), "parse_error");
                assert_eq!(code(&deep_where, "postgres"), "parse_error");
            })
            .unwrap();
        handle.join().unwrap();
    }
}
