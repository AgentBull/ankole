---
title: Log analyzer
description: How to set up an agent that reads structured logs, finds patterns and anomalies, and reports what matters — combining log reading with reasoning.
section: Guides
order: 352
---

A log analyzer agent reads a batch of structured logs, finds patterns (recurring errors, latency spikes, unusual event sequences), and reports what matters — not every line, but the signal. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **finds signal in noise, it does not dump logs**. It reads hundreds or thousands of lines, identifies the patterns that matter (a new error type, a latency regression, a spike in a specific event), and reports those. The value is in the filtering and the reasoning, not in the reading.

## What you need

- **`primary` profile bound** — pattern recognition across logs requires reasoning.
- **A signal binding** to the channel where analysis reports post.
- **A way to deliver the logs** — a file on Agent Home, a pasted batch, or logs fetched through `web_fetch` from a log ingester's API.
- **A schedule** (optional) — for recurring analysis, or on-demand when something seems wrong.

## The workflow

1. **Logs arrive** — a file, a pasted batch, or fetched from an API.
2. **The agent reads** — parses the structured JSON lines, groups by event name, severity, and timestamp.
3. **The agent finds patterns** — recurring errors, latency spikes, unusual event sequences, error-rate changes, new event types that appeared since the last analysis.
4. **The agent classifies** — known issue (matches a Brain entry), new issue (not seen before), anomaly (a metric is out of its normal range).
5. **The agent reports** — a structured summary: what it found, how many times, the time window, the severity, and whether it matches a known issue.

## What makes it an agent, not grep

`grep` finds lines that match a pattern. An agent reasons:

- **"This error appeared 47 times in the last hour, but zero times in the previous 24 hours. Something changed."** — a rate-change detection that grep cannot do.
- **"These five errors all trace back to the same upstream timeout. The root cause is the provider, not our code."** — a causal chain that requires reading multiple log lines and connecting them.
- **"This is the same pattern as the known issue in Brain (issue #123). Point to its fix."** — a recall-based classification.

## A worked example

Set up an agent that analyzes hourly logs:

1. Bind `primary`/`light` + `embedding` (for known-issue recall).
2. Author `MISSION.md`: "Read the hourly log batch. Find: new error types, error-rate spikes (>2x previous hour), latency outliers. Classify each as known (check Brain) or new. Report: what, how many, time window, severity, known-issue link. Do not dump raw logs."
3. Set up log delivery to a file on Agent Home (or fetch from your ingester's API through `web_fetch`).
4. Add an hourly schedule: `cron: "0 * * * *"`.
5. The agent reads, finds patterns, classifies, and posts the summary.

## What this guide is not

It is not a SIEM — the agent reads logs and reasons; it does not do real-time correlation across systems. It is not a dashboard — the agent posts a text summary; it does not render charts. And it is not a replacement for your log ingester — the agent reads what the ingester collected; it does not collect logs itself.

## Next steps

- For reading logs, read [Log reading](../log-reading/) and [Observability](../observability/).
- For Brain known-issue recall, read [Brain](../brain/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
- For the alert triage pattern (a related operational agent), read [Alert triage agent](../alert-triage-agent/).
