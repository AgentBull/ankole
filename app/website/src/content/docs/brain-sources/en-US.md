---
title: Brain sources
description: How to manage retained source documents Brain can learn from — add, list, read, trigger learning runs, and withdraw sources.
section: User guide
order: 55
---

Brain sources are retained documents the agent can learn from — uploaded reference material, imported knowledge, policy documents. Unlike curated knowledge entries (which the operator writes directly), sources are raw material that Brain's learning process extracts knowledge from, producing `source_learning`-authority proposals a human reviews. This page is the operator's task-oriented view of the source management surface.

The decisive property, stated up front: a source is **raw material, not knowledge**. Adding a source does not change what the agent knows; running a learning run on it produces proposed knowledge that must be reviewed before it becomes authoritative. The source is the input; the reviewed knowledge is the output.

## List sources

```bash
curl https://ankole.example.com/api/v1/brain/sources \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /brain/sources` lists retained sources. Each carries a `document_id` (of the form `brain-source:<id>`), its content hash, and metadata.

## Add a source

```bash
curl -X POST https://ankole.example.com/api/v1/brain/sources \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "document_id": "brain-source:onboarding-doc", "content": "..." }'
```

`POST /brain/sources` stores a source document. The content is retained; Brain can learn from it when you trigger a learning run.

## Read a source

```bash
curl https://ankole.example.com/api/v1/brain/sources/<document_id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN"

curl https://ankole.example.com/api/v1/brain/sources/<document_id>/raw \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /brain/sources/:document_id` returns the source's metadata; `/raw` returns its content.

## Trigger a learning run

```bash
curl -X POST https://ankole.example.com/api/v1/brain/sources/<document_id>/learning-runs \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`POST /brain/sources/:document_id/learning-runs` triggers a learning run on one source. Brain reads the source, extracts knowledge, and produces proposals with `source_learning` authority. These proposals appear in the Brain audit log for review — they do not become authoritative until a human approves them through the [Brain review](../brain-review-ops/) surface.

## Withdraw a source

Withdrawing a source removes it from Brain's retained set. Source withdrawal is clean — it does not delete the knowledge that was already extracted and reviewed from the source; it stops future learning runs from reading it. Use withdrawal when a source is outdated or was added by mistake.

## How sources relate to knowledge entries

| | Sources | Knowledge entries |
|---|---|---|
| What it is | raw document (reference material, policy) | curated fact (durable truth) |
| Who creates it | operator uploads | operator authors, or dreaming/source-learning proposes + human reviews |
| Authority | none (it is input) | `human`, `agent`, `dreaming`, `source_learning`, `mechanical` |
| Learning | Brain learns from it through a learning run | it is what Brain learned — already reviewed |
| Appears in audit log | no (it is not a knowledge write) | yes (every write is audited) |

A source feeds the knowledge base; it is not part of it. Adding a good source and running learning produces knowledge; removing the source does not unlearn what was already approved.

## A worked example

1. `POST /brain/sources` — upload the company onboarding handbook as a source.
2. `POST /brain/sources/<id>/learning-runs` — let Brain extract knowledge from it.
3. `GET /brain/audit-log` — review the `source_learning` proposals.
4. `POST /brain/entry-operations` — approve the ones that are right, restore the ones that are wrong.
5. The approved proposals are now `source_learning`-authority knowledge entries the agent recalls.

## What this guide is not

It is not the Brain concept page — for the memory model, recall, and dreaming, read [Brain](../brain/). It is not the knowledge-review guide — for reviewing proposals, read [Brain review](../brain-review-ops/). And it is not the memory-tools guide — for the agent's `memory_search` and `memory_open` tools, read [Memory](../memory/).

## Next steps

- For the Brain concept page, read [Brain](../brain/).
- For reviewing learning proposals, read [Brain review](../brain-review-ops/).
- For the agent's memory tools, read [Memory](../memory/).
- For the Console routes, read the [Console API reference](../console-api/).
