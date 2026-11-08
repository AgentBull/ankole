---
name: business-metrics
description: "Answer quantitative business questions from Pod Bases and connected databases with approved Brain metric definitions, exact server-side numbers, and cited evidence. Use for counts, sums, rates, rankings, trends, comparisons, and metric definitions."
default_enabled: true
ankole-runtime: any
category: data
tags: [Metrics, Data, Base, Database, Brain]
---

# Business metrics

This Skill owns how an Agent answers a question whose answer is a number from business data, and how the organization's metric definitions (口径) are kept in Brain. A wrong number that looks right is the worst outcome. Report only numbers that a server-side query returned in this turn, and cite how you got them.

## Know the three sources

- **Brain** holds meaning. `metrics/<name>` objects are metric definitions with a published, versioned executable spec. `datasets/<name>` objects describe a Base table or an external table: business meaning, grain, keys, joins, and which column identifies which Brain entity. Read them with the `brain` tool (`recall`, `entity`). An alias in the user's message already gives you a pointer to the matching object.
- **Pod Bases** hold the team's own ledgers. Use `ankole-pod base.schema`, `base.query`, and `base.aggregate`. Field and table `description` values state units, currency, and tax handling. Aggregates return exact decimals in `metrics_text`.
- **Database connections** (PostgreSQL, MySQL, ClickHouse) hold external OLTP and OLAP data. Use the connection's operation index and call `search_catalog`, `describe_table`, `probe_values`, `explain`, `query`, and `metric_query` through `mcporter`, as the connection's own Skill describes. Every call is read-only and budgeted; credentials never reach you.

## Choose the path by caller

- **Deterministic carriers** (Applet dashboards, Base metric charts, scheduled checks, Automation code) execute only a pinned published metric with its `revision` and typed parameters. An Applet backend calls `AnkoleRuntime.metrics.query(metric, {revision, params})`; it works on `GET` routes. An Agent calls the `brain` tool operation `metric_query` with `metric_slug`, `revision`, and `params`. A database connection's own `metric_query` tool runs the same metrics. When an entry returns `metric_not_found`, `metric_revision_not_found`, `metric_needs_review`, `invalid_metric_params`, or `dimension_not_addible`, surface that error. Never substitute another column, write ad hoc SQL, or call a model to fill the gap.
- **Interactive conversations** follow the four states below.

## Follow the four states in a conversation

1. **A published metric matches.** Find it with `recall` or the alias pointer. Execute it with the `brain` tool operation `metric_query` (`metric_slug`, `revision`, and `params`, where `params.dimensions` lists the dimensions); this works for Base metrics without any database connection, and a connection's own `metric_query` tool returns the same result. Add only the time window and dimensions the metric allows. Answer with its `metrics_text` value and label it `[已认证口径 <name> v<revision>]`. If the user asks "what if" with a different rule, give the certified value first, then the alternative value labelled `沙盘推演（未改动正式口径）`.
2. **No metric matches, the data exists, and the question has one meaning** (for example "how many M2-40V units did Shopify sell yesterday"). Inspect the schema quietly, confirm filter values exist, compute, and answer directly. Add one grey line that states the temporary basis: table, filters, time field, and exclusions, as `[按临时口径计算：…]`. Do not ask to save it.
3. **No metric matches, the data exists, and the business meaning is ambiguous** (net margin with or without freight and duty, order date or delivery date, refunds deducted or not). First inspect which fields actually exist. Then ask one native choice card with two or three plain-language options built from those real fields. After the owner chooses, compute and answer, then offer a light card to save the choice as a `metrics/` object (see "Save a definition").
4. **The core data is missing** (for example ROI with no advertising spend connected). Say exactly which parts exist and which table or field is missing. Do not approximate it with a similar column.

## Bind every part of the question before you compute

- **Concept**: map each business word to a dataset, field, or metric. Prefer a published metric or dataset description over guessing from a column name.
- **Value**: Base select fields store option IDs; take them from `base.schema`. For text values and external columns, confirm the stored form with `base.query` `text_contains` or `probe_values` (case, whitespace, codes such as `PA` for Pennsylvania).
- **Time**: Base buckets use `system.timezone`. For external data, state the column and time zone you used. Calendar words ("last month") mean a closed calendar period unless the user says rolling.
- **Path**: join only along declared Base `link` fields or the dataset's declared `joins_to` keys. A declared join path is indivisible: do not drop a bridge table or skip a hop.

## Compute only on the server

- **Base, one table or linked tables in one Base**: `base.aggregate`. It supports link-path dimensions, `EXISTS` filters, and child metrics that are pre-aggregated per parent, so a one-to-many link never inflates a parent-level sum.
- **External database**: `explain` first for a new or broad query, then `query`. A large result is saved as a file; continue with DuckDB in the Worker on that file, not in your head.
- **Across Bases or across systems**: export each side (Base `._abase/.../.export` or a `query` file), join on a declared business key (`unique_field_ids` or a dataset key) in DuckDB, and check key uniqueness before you sum.
- Ratios: compute numerator and denominator totals, then divide. Do not average per-row or per-day ratios. Cast to a decimal type before dividing in SQL, and put conditions on aggregates in `HAVING`.

## Check the result before you answer

- An empty or zero result usually means a wrong filter value. Run `probe_values` (or a Base `text_contains` query) on every literal before you report "0" or "none".
- When `query` returns `"fanout_risk"` in `warnings`, or you joined a one-to-many relation yourself, recompute with the child pre-aggregated and compare.
- Compare row counts with an independent count of the population when the number drives a decision.
- When `truncated` is true, the answer covers only the returned rows; say so or rerun as a file export.
- Never write a number that you did not read from a result. Quote `metrics_text` for Base and the returned value for databases.

## Cite the evidence

End every numeric answer with the evidence it rests on: the metric or dataset object, the executed spec or SQL, the data version or data timestamp, and the row count. Keep it short; one line per source is enough.

## Save a definition

- A `datasets/` object declares `source` (`{kind: base, table_id}` or `{kind: connector, connection, schema?, table}`), `grain`, optional `primary_key`, `business_key`, `entity_key` (`{key, entity_type, namespace}`), and `joins_to` (`{dataset, keys: [{from, to}], cardinality}`). Without `source` it is a draft.
- A `metrics/` object declares `aliases`, `dataset`, `grain`, `unit`, `numerator`, optional `denominator`, `time_field`, `parameters` (`{name, type, required?, default?}`), and `addible_dimensions`. A Base dataset uses `spec`: the `base.aggregate` JSON with `{"$param": name}` placeholders. A connector dataset uses `sql` with positional parameters plus `columns`, the source columns it reads. Connector SQL owns its own grouping; requested dimensions are only checked against the allowlist. Write inclusions, exclusions, and a counterexample in the body.
- Save with the `brain` tool `write_object`. An invalid definition is rejected with `invalid_metric_definition` or `invalid_dataset_definition` and the failing key. When you or the requester cannot edit Brain directly, the tool returns an Action Card; an authorized person approves it, and the next question uses state 1. A changed executable definition publishes a new revision; to withdraw a metric, set `status: retired`.
- Entity objects declare row keys with `identifiers` (for example `{erp.supplier_id: S-0042}`) so results can point back to the entity.
- When a person corrects a metric, revise its object at once; Brain stores the change as a new revision and keeps the history.
- Record a business finding that came from data with `remember`: the entity as subject, the query and data timestamp in the context. Record findings that matter for decisions, not raw rows.
