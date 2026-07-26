---
title: Brain review
description: How to review and curate what an agent remembers — read knowledge entries, inspect the audit trail, restore previous states, and run dreaming on demand.
section: User guide
order: 51
---

Brain holds the agent's long-term memory — curated knowledge, source-chat recall, dreaming proposals. A human reviews this memory to keep it accurate, remove stale facts, and approve or reject what dreaming proposed. This page is the operator's task-oriented view of that review surface, through the Console's `/brain/*` routes.

The decisive property, stated up front: Brain knowledge is **human-reviewed durable truth**. Dreaming proposes; the operator decides. Nothing dreaming produced becomes authoritative knowledge without a reviewed write. The review surface is where that human oversight happens.

## Read knowledge entries

```bash
curl https://ankole.example.com/api/v1/brain/entries \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /brain/entries` lists the curated knowledge entries the agent holds. Read one with `GET /brain/entries/:id`. Each entry carries its type, store key, summary, properties, and the audit trail of who changed it and when.

## Read the audit trail

```bash
curl https://ankole.example.com/api/v1/brain/audit-log \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl https://ankole.example.com/api/v1/brain/entries/<id>/audit-log \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

The audit log is append-only — every knowledge write, deletion, and restoration produces a row. This is the surface for "why does the agent believe that?" The row names the actor (human, agent, dreaming, source_learning, mechanical), the operation, and the timestamp.

## Apply knowledge operations

```bash
curl -X POST https://ankole.example.com/api/v1/brain/entry-operations \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "operations": [ ... ] }'
```

`POST /brain/entry-operations` applies a batch of knowledge mutations — create entries, update blocks, delete blocks. A batch either commits all its mutations and audits together, or leaves no partial state. The operator's authority mode is `human`; the operations carry that authority into the write.

## Restore a previous state

```bash
curl -X POST https://ankole.example.com/api/v1/brain/audit-log/restorations \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "audit_id": "<audit-id>" }'

curl -X POST https://ankole.example.com/api/v1/brain/audit-log/<audit_id>/restorations \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Restoration undoes a specific audited change by applying its inverse. The restoration itself is audited — it adds a new audit row, it does not erase the one that made the original change. Use restoration when a knowledge write was wrong; do not use it casually, because each restoration is a new decision in the trail.

## Manage sources

```bash
curl https://ankole.example.com/api/v1/brain/sources \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl -X POST https://ankole.example.com/api/v1/brain/sources \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "document_id": "brain-source:...", ... }'

curl -X POST https://ankole.example.com/api/v1/brain/sources/<document_id>/learning-runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

Sources are retained documents Brain can learn from — uploaded reference material, imported knowledge. List them, add one, and trigger a learning run to let Brain extract knowledge from the source. Source learning produces `source_learning`-authority writes, labeled as such.

## Run dreaming on demand

```bash
curl https://ankole.example.com/api/v1/brain/dreaming-fitness \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl -X POST https://ankole.example.com/api/v1/brain/dreaming-runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /brain/dreaming-fitness` tells you whether dreaming is fit to run — whether the configuration is enabled, whether a usable light profile exists, whether there are unprocessed entries. `POST /brain/dreaming-runs` triggers a run manually. Dreaming's output is proposed knowledge with `dreaming` authority — it does not become authoritative until a human reviews it.

## Check Brain health

```bash
curl https://ankole.example.com/api/v1/brain/status \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /brain/status` shows Brain's configuration and health — whether knowledge is enabled, whether dreaming is enabled, whether the embedding model is configured. Use it as the first check when Brain seems not to be working.

## A worked review session

1. `GET /brain/entries` — scan what the agent currently knows.
2. `GET /brain/audit-log` — check recent changes, especially any from `dreaming` or `agent` authority.
3. If a dreaming proposal is wrong, `POST /brain/audit-log/<id>/restorations` to undo it.
4. If a fact is stale, `POST /brain/entry-operations` with a delete or update.
5. `POST /brain/dreaming-runs` if you want Brain to process recent history — then review the proposals.

## What this guide is not

It is not the Brain concept page — for the memory model, recall, and dreaming internals, read [Brain](../brain/). It is not the memory-tools guide — for the tools the agent uses during a turn, read [Memory](../memory/). And it is not a substitute for the audit-trail page — for the cross-subsystem audit map, read [Audit trail](../audit-trail/).

## Next steps

- For the Brain concept page, read [Brain](../brain/).
- For the agent's memory tools, read [Memory](../memory/).
- For the audit map, read [Audit trail](../audit-trail/).
- For the Console routes, read the [Console API reference](../console-api/).
