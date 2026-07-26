---
title: Scheduled report agent
description: How to set up an agent that generates a recurring report — fetches data, formats it, and delivers on a schedule.
section: Guides
order: 345
---

A scheduled report agent runs on a cadence, gathers the data the report needs, formats it, and delivers it to the channel. This is a variant of the [daily briefing bot](../daily-briefing-bot/) focused on structured data output rather than research — a metrics dashboard, a usage summary, a compliance check. This guide is the practical shape of that agent.

The decisive property, stated up front: the report is **data-driven and structured, not narrative**. The agent fetches numbers, formats them into a table or a summary, and posts it. The value is consistency — the same report, in the same format, on the same schedule, every time. If the format drifts, the report is broken.

## What you need

- **`primary` profile bound** — for formatting and anomaly detection.
- **A signal binding** to the channel where the report posts.
- **A schedule** — daily, weekly, or monthly. See [Cron schedules](../cron-schedules-ops/).
- **A data source** — a database query (through `command` with `psql` or similar), an API endpoint (through `web_fetch`), or a file on Agent Home.

## The workflow

1. **The schedule fires.**
2. **The agent fetches the data** — runs the query, calls the API, or reads the file.
3. **The agent formats** — structures the data into a report: a Markdown table, a bullet summary, or a structured document.
4. **The agent checks for anomalies** — compares this run's numbers to the expected range or the previous run. If a number is out of range, flag it.
5. **The agent delivers** — posts the report to the channel.

## The report template

A good scheduled report is consistent. Define the template in the persona:

```text
**Weekly metrics — <date range>**
| Metric | This week | Last week | Change |
|---|---|---|---|
| Active users | 1,234 | 1,100 | +12.2% |
| API calls | 45.6k | 42.1k | +8.3% |
| Error rate | 0.3% | 0.2% | +50% ⚠️ |

**Anomalies**: Error rate increased 50% — investigate.
```

The anomaly flag is what makes this an agent, not a cron job. A cron script sends the table; the agent notices the error rate spiked and calls it out.

## What the persona controls

- **The data query** — the exact SQL, API endpoint, or file path.
- **The format** — table, bullets, or prose. Consistent across runs.
- **The anomaly rules** — "flag if error rate > 0.5%, or if any metric changes by more than 20% week-over-week."
- **The delivery** — "post to #metrics at 9 AM Monday."
- **What to do on anomaly** — "flag in the report and @-mention the on-call. Do not investigate autonomously."

## A worked example

Set up a weekly usage report agent:

1. Bind `primary`/`light` + store the database connection string in WorkerEnv (`DB_READONLY_URL`).
2. Author `MISSION.md`: "Every Monday at 9 AM, query the read-only database for last week's metrics. Format as a Markdown table. Flag any metric that changed more than 20% week-over-week. Post to #metrics. If an anomaly is flagged, @-mention @on-call."
3. Add a weekly schedule: `cron: "0 9 * * 1"`.
4. The agent runs the query through `command` (`psql $DB_READONLY_URL -c "..."`), formats the table, checks for anomalies, and posts.

## Delegate the data fetch

For a slow query or a multi-source report, delegate the data gathering to a background job (see [Delegation patterns](../delegate-patterns/)). The job fetches; the agent formats and delivers when the job completes.

## What this guide is not

It is not a BI dashboard — the agent posts a text report to a channel; it does not render charts or serve an interactive UI. It is not a monitoring system — the report is periodic, not real-time; for real-time alerts, use the [alert triage agent](../alert-triage-agent/). And it is not a data pipeline — the report reads data; it does not transform or store it.

## Next steps

- For scheduling, read [Cron schedules](../cron-schedules-ops/).
- For the daily-briefing pattern (a related scheduled agent), read [A daily briefing bot](../daily-briefing-bot/).
- For shell commands (database queries), read [Code execution](../code-execution/).
- For delegation, read [Delegation patterns](../delegate-patterns/).
