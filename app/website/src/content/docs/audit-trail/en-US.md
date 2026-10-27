---
title: Audit trail
description: How to read Ankole's audit surfaces — the AuthZ grant record, the control-plane structured logs, and what each records about who changed what and when.
section: Developer guide
order: 125
---

An audit trail records who changed what, and when. Rather than funneling everything into a single monolithic audit log, Ankole distributes audit records across the subsystems that own each decision. This page maps those surfaces for operators—what each one captures, how to read it, and how to combine them during an investigation.

Every audit surface in Ankole rests on **durable PostgreSQL tables or structured control-plane logs** rather than ephemeral metrics: once written or shipped, a record survives process restarts, whereas anything never persisted or shipped cannot be reconstructed afterward.

## AuthZ grants, human access, and invitations

Every permission grant lives as a durable row in `permission_grants`. Each grant attaches to one `principal_uid`, one `group_id`, or one Userset page audience (`source_page_id` and `source_action`), while Pod ACL grants anchor to `pages` rows via `target_page_id` and `target_scope`. On each row, `resource_pattern`, `action`, and `condition` specify what the grant permits, and timestamps record when the row was created and last updated. Because `permission_grants` itself is the authoritative record, Ankole maintains no separate grant-audit table.

Account-access transitions and workspace invitations likewise commit durable rows in PostgreSQL:

- `human_access_events` records every access suspension, restoration, or directory-driven transition, capturing the actor, source, previous and current status, `access_version`, and any `released_identifiers`.
- `human_access_restrictions` stores active restrictions alongside their `:suspended` or `:offboarded` disposition and reason.
- `pod_invitations` records Pod workspace invitations, membership kind (`member` or `guest`), usage counter (`used_count`), and creator (`created_by_principal_uid`).

Inspect active Principal and group grants through `GET /api/v2/principals/:uid/grants` and `GET /api/v2/principal-groups/:name/grants`. While Ankole enforces only the rows currently present in `permission_grants`, grants that were added and later revoked remain preserved in PostgreSQL point-in-time recovery history.

## The structured control-plane logs

The control plane emits structured JSON logs with a consistent shape—an event name, a human-readable message, structured metadata fields, and a severity level from `debug` through `error`. These logs capture operational activity:

- provider calls (which provider, which model, and the outcome)
- worker lifecycle (worker boot, turn start, and turn completion or failure)
- signal events (what arrived and whether it was filtered or admitted)
- schedule executions (when a cron schedule fired and its outcome)

Unlike database tables, control-plane logs persist only where your log collector stores them. If you rely on logs for auditing, ship them in real time to a durable sink such as a log index or an S3 archive; unshipped logs disappear when the container or process exits.

See [Environment variables](../environment-variables/) for log configuration and [Read Ankole logs](../log-reading/) for diagnostic workflows.

## The Signal and delivery rows

Every Signal (the durable inbox entry that wakes a Session) and every outbound delivery attempt persists as a row in PostgreSQL, serving both as live operational state and as a record of what Ankole was asked to do and whether delivery succeeded. Through the Console API, `/api/v2/background-agent-jobs/:id` exposes a job's `attempts` and `error`, and `/api/v2/ai-gateway/conversations` lists the model calls that each turn executed.

## Using them together

Real audit questions usually span multiple surfaces:

| Question | Where to look |
|---|---|
| "Who gave this agent or page audience permission to do Y?" | `permission_grants` + `/api/v2/principals/:uid/grants` / `/api/v2/principal-groups/:name/grants` |
| "Why was a human account suspended, offboarded, or invited?" | `human_access_events`, `human_access_restrictions`, and `pod_invitations` |
| "What did the agent do on this turn?" | `/api/v2/ai-gateway/conversations/:id/messages` |
| "Did the schedule fire?" | `/api/v2/cron-schedules/:id/runs` |
| "Was a job's failure retried?" | `/api/v2/background-agent-jobs/:id` (`attempts`, `error`) |
| "What did the worker log at that time?" | structured control-plane logs |

## What this guide is not

This page is not a compliance framework—Ankole provides the audit records, while your organization's compliance posture governs how long to retain them. Nor is it a SIEM integration guide: Ankole emits structured JSON logs that you can forward to whichever collector you run. Finally, audit tables are no substitute for tested backups—because core audit state lives in PostgreSQL, losing an unbacked database loses the trail with it.

## Next steps

- For the permission model, read [Principal and AuthZ](../principal-authz/).
- For log settings and diagnosis, read [Environment variables](../environment-variables/) and [Read Ankole logs](../log-reading/).
- For backup that protects the trail, read [Backup and restore](../backup-and-restore/).
