---
title: Migrating from another system
description: There is no automatic migration tool. The path onto Ankole is a fresh deployment, reconfiguring providers, agents, and signal bindings, and recreating persona and memory by hand.
section: Getting started
order: 7
---

There is no migration tool that imports another self-hosted agent system into Ankole, and there is no plan to pretend one exists. This page tells you the truth about what moving onto Ankole involves, so you can decide whether and how to do it.

The decisive property, stated up front: Ankole does not read another system's database, flat-file memory, or chat logs. What you carry over, you recreate through the Console. The shortest honest summary is: deploy Ankole, configure providers and agents, re-create the persona documents you care about by hand, and accept that conversation history and runtime memory do not transfer.

## Why there is no importer

Ankole's durable state is shaped to its own model: Principals, agents, sessions, signal bindings, Brain knowledge rows, and actor events. None of those map cleanly onto another system's tables or files. A faithful importer would have to invent semantics the source system does not have — Ankole's Principal scoping, its signal-binding model, its Brain authority modes — and an importer that invented those would be worse than no importer, because it would produce a deployment that looks migrated but is not.

So the migration is a reconfiguration, not a conversion. The work is operator work, done through the Console, and the sections below are the order to do it in.

## Step 1: deploy Ankole

Stand up a fresh installation with [Installation](../installation/) or [Quick start](../quickstart/). Do not try to point Ankole at another system's PostgreSQL or Agent Home — the schemas are not compatible, and Ankole's bundled PostgreSQL carries the `pg_search` extension the source almost certainly does not have. Use a new database, a new Agent Home volume, and new bootstrap secrets.

## Step 2: configure providers and models

Re-create the upstream AI provider configuration through [Providers and models](../providers-and-models/). The provider credentials you used on the source system still work — bring the same API keys and endpoints — but enter them as new Ankole provider rows. Bind the required model profile slots (`primary`, `light`, `heavy`) and any optional slots the agent needs.

## Step 3: create agents and personas

Create each agent through [Agents](../agents/). For each one, re-author the persona documents by hand:

| Ankole document | What to put in it |
|---|---|
| `MISSION.md` | the agent's scope and responsibility |
| `SOUL.md` | tone, style, and guardrails |
| `DESIGN.md` | the working agreements and constraints the agent must honor |

If the source system had a single persona prompt, split it across these three by purpose rather than pasting it into one file. Ankole reads all three on every turn; the split is what makes each one addressable and reviewable.

## Step 4: connect chat platforms

Re-create signal bindings through [Signal bindings](../signal-bindings/) and the adapter page for each platform — [Lark](../adapters-lark/), [DingTalk](../adapters-dingtalk/), [Slack](../adapters-slack/), [Microsoft 365](../adapters-microsoft-365/), [Google Workspace](../adapters-google-workspace/). The bot applications on the chat-platform side can stay — reuse the existing app registrations and credentials — but bind them to the new Ankole agents.

Plan a cutover, not a parallel run: two systems answering in the same channel confuse users and can double-reply. Disable the source system's bot in the channel before enabling the Ankole binding, or move the channel in a planned window.

## What does not transfer

Be explicit about this, because it is where migration feels lossy:

- **Conversation history** — chat transcripts are not imported. Ankole starts each session fresh; past turns stay in the source system's logs, where they can still be read but no longer drive the agent.
- **Long-term memory** — there is no flat-file memory to copy in. Brain knowledge is operator-reviewed rows in PostgreSQL; re-create the handful of durable facts that matter as curated knowledge through the Brain surface.
- **Background jobs and schedules** — recreate any recurring schedules through [Schedules](../schedules/). In-flight jobs on the source system are not carried over.
- **Learned model behavior** — anything the source system tuned through prompt accumulation does not exist in Ankole until you put it into the persona documents or curated knowledge.

## Cutover checklist

1. Ankole deployed and healthy; one test agent runs a real turn.
2. Provider rows and model profiles bound for each agent.
3. Persona documents authored for each agent.
4. Signal bindings created but **disabled** on the production channels.
5. Source system's bots disabled in the channels you are moving.
6. Ankole bindings enabled; first real messages verified end to end.
7. Old deployment kept read-only for a window, then decommissioned.

## What this page is not

It is not a promise that migration is easy, and not a catalog of per-source-system importers. If your source system has a structured export that maps to Ankole's model, you can write your own importer against the Console API — but Ankole does not ship one, and a hand-recreated configuration that you understand beats an imported one that you do not.

## Next steps

- For the deployment that starts the migration, read [Installation](../installation/).
- For the operator surface you will spend most of the migration in, read [Console operations](../console-operations/).
- For the persona documents you will re-author, read [Agents](../agents/).
