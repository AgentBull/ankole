---
title: Alert triage agent
description: How to set up an agent that watches alerts, classifies severity, drafts a runbook, and escalates before taking risky action — combining webhooks, Brain knowledge, and escalation discipline.
section: Guides
order: 333
---

An alert triage agent watches incoming alerts, classifies their severity, drafts an initial assessment, prepares a runbook, and escalates to a human before taking any risky action. This guide is the practical shape of that agent — combining event-driven triggers, Brain knowledge, and the escalate-first discipline.

The decisive property, stated up front: the agent **triages, it does not remediate without approval**. It reads the alert, classifies it, gathers context, and proposes an action. A human approves before anything risky runs. The agent's value is speed of assessment, not autonomy of action.

## What you need

- **A webhook binding** — alerts arrive as webhook events through a `signals_gateway.webhook_handler` plugin, or as messages in a monitoring channel. See [Automation blueprints](../automation-blueprints/).
- **`primary` profile bound** — triage requires reasoning about the alert's context and severity.
- **`web_search`/`web_fetch` profiles (optional)** — for looking up error messages or known issues in public docs.
- **Brain knowledge curated** — your runbooks, known-issue patterns, service dependency map, and on-call roster.

## The triage workflow

1. **An alert arrives** — through a webhook or a channel message (PagerDuty, Datadog, Grafana, a custom monitor).
2. **The agent classifies** — severity (critical/warning/info), affected service, blast radius. Brain knowledge provides the service dependency map and known-issue patterns.
3. **The agent gathers context** — reads recent logs (if accessible), checks Brain for similar past incidents, searches for the error message if it is unfamiliar.
4. **The agent drafts a runbook** — what to check, what to try, what not to touch. From Brain knowledge and the alert's specifics.
5. **The agent escalates** — posts the classification and the runbook to the on-call channel, asking for approval before any action. "This looks like a database connection pool exhaustion. Runbook: check `pg_stat_activity`, consider restarting the worker. Shall I proceed, or will you handle it?"

## What the persona controls

The persona (`MISSION.md`) is the safety boundary:

- **Severity thresholds** — "classify as critical if the alert affects user-facing availability; warning if it is an internal metric; info if it is a capacity notification."
- **What to propose, what to do** — "propose diagnostics and non-destructive checks. Never propose a restart, a migration, or a config change without explicit human approval."
- **Escalation targets** — "escalate to @on-call for critical; post to #ops for warning; log silently for info."
- **Known-issue shortcuts** — "if the alert matches a known-issue pattern in Brain, point to the known fix and skip the full triage."

## The known-issue pattern

The most valuable Brain knowledge for triage is the **known-issue pattern**: a mapping from a symptom (error message, metric threshold) to a diagnosis and a fix. Curate these as the agent encounters incidents:

- "If the error is `ECONNREFUSED` on port 5432, check whether PostgreSQL is running — see the database runbook."
- "If the `memory_usage` metric exceeds 90%, check for a memory leak in the worker — restart the worker pod."

Each known-issue entry lets the agent skip the full triage and point straight to the fix, saving minutes on repeat incidents.

## A worked example

Set up an alert triage agent for a Kubernetes deployment:

1. Create a webhook handler plugin (or bind to the monitoring channel) that delivers alerts as actor events.
2. Create the agent, bind `primary`/`light`/`heavy` + `web_search` (for error lookup) + `embedding` (for Brain recall).
3. Author `MISSION.md`: "Triage alerts in #on-call. Classify severity, gather context from Brain, draft a runbook. Escalate to @on-call before any action. Known-issue shortcuts: check Brain first."
4. Curate Brain knowledge: service dependency map, runbooks for the top 5 incident types, on-call roster.
5. Send a test alert; watch the agent classify, draft, and escalate.
6. After each incident, add the pattern to Brain as a known-issue entry.

## What this guide is not

It is not an auto-remediation system — the agent proposes; the human approves. It is not a monitoring replacement — your monitoring stack (Prometheus, Datadog, CloudWatch) detects the problem; the agent triages what was detected. And it is not a substitute for a human on-call — the agent handles the first five minutes of assessment; the human handles the decision and the action.

## Next steps

- For webhook triggers, read [Automation blueprints](../automation-blueprints/).
- For Brain knowledge curation, read [Brain sources](../brain-sources/) and [Brain review](../brain-review-ops/).
- For incident response (what happens after triage), read [Incident response](../incident-response/).
- For the escalation discipline, read [Customer support agent](../customer-support-agent/) (same shape, different domain).
