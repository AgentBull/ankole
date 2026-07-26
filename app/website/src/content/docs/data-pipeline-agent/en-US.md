---
title: Data pipeline agent
description: How to set up an agent that runs a data transformation pipeline — fetch, transform, validate, and deliver — through shell tools and the Jupyter kernel, as a background job.
section: Guides
order: 338
---

A data pipeline agent runs a multi-step data transformation — fetch a source, clean and transform it, validate the output, and deliver the result. This is the shape of work that combines the shell tools (for fetching and running scripts) with the Jupyter kernel (for iterative data inspection), all inside a background job. This guide is the practical shape of that agent.

The decisive property, stated up front: a data pipeline is **a background job that runs shell and Python steps in sequence, not a real-time streaming system**. The agent fetches, transforms, validates, and delivers — and it reports success or failure when the job completes. The value is that the agent can adapt when a step fails (retry, adjust, escalate) rather than blindly running a fixed script.

## What you need

- **`web_fetch` profile bound** — if the data source is a public URL. For a database source, a connection string in WorkerEnv.
- **`primary` and `coding` profiles bound** — the agent writes or adjusts the transformation script.
- **The `jupyter-live-kernel` skill enabled** — for iterative data inspection when the pipeline needs exploration (schema check, anomaly detection).
- **A signal binding** to the channel where results or failures report.
- **A Codex account configured** — the pipeline runs as a background job on a Codex account.

## The pipeline steps

1. **Fetch** — the agent fetches the source data: `web_fetch` for a URL, `command` for a database query (through a CLI like `psql`), or reads a file from Agent Home.
2. **Transform** — the agent runs a Python script (through `command` or the Jupyter kernel) to clean, filter, aggregate, or reshape the data.
3. **Validate** — the agent checks the output: row count, schema, summary statistics, null checks. If validation fails, the agent reports and does not deliver.
4. **Deliver** — the agent writes the output to a file, posts it to the channel, or uploads it through the worker-file routes.

## The adaptivity that makes it an agent

A fixed script does steps 1-4 and either succeeds or fails. An agent does steps 1-4 and, when a step fails, adapts:

- **Fetch failed** — retry with a different URL, or report "source unavailable."
- **Transform failed** — inspect the data shape (through the Jupyter kernel), identify the anomaly (a new column, a type change), adjust the script, retry.
- **Validation failed** — report what failed (row count dropped 50%, schema changed) and ask for a decision.

This adaptivity is why the work is an agent job, not a cron script. The agent handles the common variations; it escalates the uncommon ones.

## A worked example

Set up a weekly data pipeline that fetches a CSV, cleans it, and delivers a summary:

1. Bind `web_fetch` (for the CSV URL), `primary`/`coding`, enable `jupyter-live-kernel`.
2. Create the agent, author `MISSION.md`: "Every Monday, fetch the weekly metrics CSV from <url>. Load it in a Jupyter kernel. Clean: drop rows with null IDs, normalize the date column. Validate: row count > 100, no nulls in critical columns. Deliver: post the cleaned summary as a Markdown table to the channel. If validation fails, report what failed and do not deliver."
3. Add a weekly schedule: `cron: "0 8 * * 1"`.
4. The agent delegates the pipeline to a background job. The job fetches, loads, cleans, validates, and delivers. If a step fails, the agent adapts or escalates.

## What this guide is not

It is not a streaming-data platform — the agent runs batch transformations, not real-time pipelines. It is not an ETL framework — the agent runs scripts through the shell and the Jupyter kernel; it does not replace Airflow or dbt. And it is not a data-quality monitoring system — it validates the output of its own pipeline; it does not monitor data quality across systems.

## Next steps

- For the Jupyter kernel skill, read [Jupyter data analysis](../jupyter-data-analysis/).
- For the shell tools, read [Code execution](../code-execution/).
- For background jobs, read [Background jobs](../background-jobs-ops/) and [Delegation patterns](../delegate-patterns/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
