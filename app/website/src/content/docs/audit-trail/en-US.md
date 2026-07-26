---
title: Audit trail
description: How to read Ankole's audit surfaces — the Brain audit log, the control-plane structured logs, and what each records about who changed what and when.
section: User guide
order: 50
---

An audit trail is the durable record of who changed what, and when. Ankole does not have one audit log; it has several surfaces, each owned by a different subsystem, each recording the decisions that matter to it. This page is the operator's map of those surfaces — what each records, how to read it, and how to use them together.

The decisive property, stated up front: every audit surface is **durable PostgreSQL state or structured logs**, not ephemeral metrics. A record that was written survives the process that wrote it; a record that was never written cannot be reconstructed.

## The Brain audit log

The most structured audit surface. Every Brain knowledge write — a new entry, a block edit, a deletion, a restoration — produces an append-only audit row. Read it through:

```bash
curl https://ankole.example.com/api/v1/brain/audit-log \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Or narrow to one entry:

```bash
curl https://ankole.example.com/api/v1/brain/entries/<id>/audit-log \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Each row records who made the change (the actor), what kind of actor (human, agent, dreaming, source_learning, mechanical), what operation was performed, and when. Restorations are themselves audited — restoring a previous state adds a new audit row, it does not erase the one that made the change being undone.

This is the surface for "why does the agent believe that?" — the answer is in the audit trail, not in the model's current output.

## The AuthZ grant record

Every permission grant is a durable row in `permission_grants`. The grant's `principal_uid` or `group_id` names the owner; the `resource_pattern` and `action` name what it permits; timestamps record when it was created and last updated. There is no separate audit log for grants — the grant table itself is the record, because grants are append-mostly and changes are visible as row updates.

Read the grants through `GET /principals/:uid/grants` and `GET /principal-groups/:name/grants`. A grant that was added and later removed shows up in the table's history (if you keep PostgreSQL point-in-time recovery); a grant that exists now is what the system enforces.

## The structured control-plane logs

The control plane emits structured logs with a stable shape — an event name, a human message, and structured fields, at a severity from `debug` through `error`. These are the audit surface for operational events:

- provider calls (which provider, which model, the outcome)
- worker lifecycle (worker start, turn start, turn completion or error)
- signal events (what arrived, whether it was filtered or accepted)
- schedule fires (when, what outcome)

The logs are not PostgreSQL — they are whatever your log ingester receives. If you need them for audit, ship them to a durable store (a log index, an S3 archive) in real time. Logs that were never shipped are gone with the process.

See [Observability](../observability/) for the log knobs and how to read them.

## The actor-event and delivery rows

Every actor event (the durable inbox that drives sessions) and every delivery attempt is a row in PostgreSQL. These are not typically read for audit — they are operational state — but they form a record of what the system was asked to do and whether it was delivered. The Console's `/background-agent-jobs/:id` route shows a job's `attempts` and `error`; the `/ai-gateway/conversations` route shows the model calls a turn made.

## Using them together

A real audit question usually spans more than one surface:

| Question | Where to look |
|---|---|
| "Why does the agent believe X?" | Brain audit log |
| "Who gave this agent permission to do Y?" | `permission_grants` + `/principals/:uid/grants` |
| "What did the agent do on this turn?" | `/ai-gateway/conversations/:id/messages` |
| "Did the schedule fire?" | `/cron-schedules/:id/runs` |
| "Was a job's failure retried?" | `/background-agent-jobs/:id` (`attempts`, `error`) |
| "What did the worker log at that time?" | structured control-plane logs |

## What this guide is not

It is not a compliance framework — Ankole provides the surfaces, and your compliance posture decides how long to retain them. It is not a SIEM integration guide — the logs are structured JSON, and your ingester is your choice. And it is not a substitute for tested backups — the audit trail lives in PostgreSQL, and a database you cannot restore takes the trail with it.

## Next steps

- For the Brain audit surface, read [Brain](../brain/).
- For the permission model, read [Principal and AuthZ](../principal-authz/).
- For the log knobs, read [Observability](../observability/) and [Environment variables](../environment-variables/).
- For backup that protects the trail, read [Backup and restore](../backup-and-restore/).
