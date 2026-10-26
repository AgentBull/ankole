---
title: Audit trail
description: How to read Ankole's audit surfaces — the AuthZ grant record, the control-plane structured logs, and what each records about who changed what and when.
section: Developer guide
order: 125
---

An audit trail is the durable record of who changed what, and when. Ankole does not have one audit log; it has several surfaces, each owned by a different subsystem, each recording the decisions that matter to it. This page is the operator's map of those surfaces — what each records, how to read it, and how to use them together.

The decisive property, stated up front: every audit surface is **durable PostgreSQL state or structured logs**, not ephemeral metrics. A record that was written survives the process that wrote it; a record that was never written cannot be reconstructed.

## AuthZ grants, human access, and invitations

Every permission grant is a durable row in `permission_grants`. Each grant belongs to one `principal_uid`, one `group_id`, or one Userset page audience (`source_page_id` and `source_action`), and Pod ACL grants anchor to `pages` rows through `target_page_id` and `target_scope`. The `resource_pattern`, `action`, and `condition` name what the grant permits, and timestamps record when it was created and last updated. There is no separate audit log for grants — `permission_grants` itself is the record.

Human account lifecycle changes and workspace invitations also write durable PostgreSQL rows:

- `human_access_events` records each access disable, restoration, or directory-driven transition, including actor, source, previous and current status, `access_version`, and any `released_identifiers`.
- `human_access_restrictions` stores active restrictions with `:suspended` or `:offboarded` dispositions and reasons.
- `pod_invitations` records Pod workspace invitations, membership kind (`member` or `guest`), quota (`used_count`), and creator (`created_by_principal_uid`).

Read Principal and group grants through `GET /api/v2/principals/:uid/grants` and `GET /api/v2/principal-groups/:name/grants`. A grant that was added and later removed remains in PostgreSQL point-in-time recovery history; the rows currently present are what the system enforces.

## The structured control-plane logs

The control plane emits structured logs with a stable shape — an event name, a human message, and structured fields, at a severity from `debug` through `error`. These are the audit surface for operational events:

- provider calls (which provider, which model, the outcome)
- worker lifecycle (worker start, turn start, turn completion or error)
- signal events (what arrived, whether it was filtered or accepted)
- schedule fires (when, what outcome)

The logs are not PostgreSQL — they are whatever your log ingester receives. If you need them for audit, ship them to a durable store (a log index, an S3 archive) in real time. Logs that were never shipped are gone with the process.

See [Environment variables](../environment-variables/) for log settings and [Read Ankole logs](../log-reading/) for a diagnostic method.

## The Signal and delivery rows

Every Signal (the durable inbox that drives sessions) and every delivery attempt is a row in PostgreSQL. These are operational state, and they also form a record of what the system was asked to do and whether it was delivered. The Console API route `/api/v2/background-agent-jobs/:id` shows a job's `attempts` and `error`; `/api/v2/ai-gateway/conversations` shows the model calls a turn made.

## Using them together

A real audit question usually spans more than one surface:

| Question | Where to look |
|---|---|
| "Who gave this agent or page audience permission to do Y?" | `permission_grants` + `/api/v2/principals/:uid/grants` / `/api/v2/principal-groups/:name/grants` |
| "Why was a human account suspended, offboarded, or invited?" | `human_access_events`, `human_access_restrictions`, and `pod_invitations` |
| "What did the agent do on this turn?" | `/api/v2/ai-gateway/conversations/:id/messages` |
| "Did the schedule fire?" | `/api/v2/cron-schedules/:id/runs` |
| "Was a job's failure retried?" | `/api/v2/background-agent-jobs/:id` (`attempts`, `error`) |
| "What did the worker log at that time?" | structured control-plane logs |

## What this guide is not

It is not a compliance framework — Ankole provides the surfaces, and your compliance posture decides how long to retain them. It is not a SIEM integration guide — the logs are structured JSON, and your ingester is your choice. And it is not a substitute for tested backups — the audit trail lives in PostgreSQL, and a database you cannot restore takes the trail with it.

## Next steps

- For the permission model, read [Principal and AuthZ](../principal-authz/).
- For log settings and diagnosis, read [Environment variables](../environment-variables/) and [Read Ankole logs](../log-reading/).
- For backup that protects the trail, read [Backup and restore](../backup-and-restore/).
