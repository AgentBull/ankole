---
title: Knowledge base curator
description: How to set up an agent that curates Brain knowledge — reviews dreaming proposals, merges duplicates, retires stale entries, and keeps the knowledge base clean.
section: Guides
order: 355
---

A knowledge base curator agent keeps Brain knowledge accurate and current — reviews dreaming proposals, identifies duplicate or contradictory entries, retires stale knowledge, and proposes merges. This is the maintenance side of [Brain review](../brain-review-ops/), automated into a recurring task. This guide is the practical shape of that agent.

The decisive property, stated up front: the agent **proposes changes, it does not apply them silently**. Every curation action — merge, retire, update — is a proposal that a human reviews through the Brain audit trail. The value is in doing the tedious comparison work (finding duplicates, checking staleness) that a human would skip, not in bypassing human review.

## What you need

- **`primary` and `embedding` profiles bound** — comparing knowledge entries requires reasoning and recall.
- **A signal binding** to the channel where curation proposals post.
- **A schedule** — weekly is a good cadence for curation. See [Cron schedules](../cron-schedules-ops/).
- **Brain knowledge with some history** — curation is most valuable once the knowledge base has accumulated entries over time.

## The curation tasks

1. **Review dreaming proposals** — check `GET /brain/audit-log` for entries with `dreaming` authority. For each, propose approve or reject based on accuracy and relevance.
2. **Find duplicates** — recall similar entries through `memory_search`; if two entries say the same thing in different words, propose a merge.
3. **Find contradictions** — if two entries disagree (one says "the API returns XML," another says "JSON"), flag the conflict for human resolution.
4. **Retire stale entries** — if an entry references a service, config, or process that no longer exists, propose retirement.
5. **Report** — a structured proposal: what to approve, what to reject, what to merge, what to retire, with evidence for each.

## The proposal format

```text
**Weekly curation proposal — <date>**
**Approve** (dreaming proposals that look right):
- <entry>: <why it's accurate>
**Reject** (dreaming proposals that look wrong):
- <entry>: <why it's wrong>
**Merge** (duplicates):
- <entry A> + <entry B>: <they say the same thing; merge into one>
**Retire** (stale):
- <entry>: <references the old auth service that was replaced>
**Contradictions** (need human resolution):
- <entry A> says X; <entry B> says Y. Which is current?
```

The human reviews the proposal and applies the changes through `POST /brain/entry-operations` or the restoration routes.

## What the persona controls

- **Curation scope** — "review dreaming proposals, find duplicates, and retire entries older than 6 months that reference deprecated services."
- **Staleness rules** — "an entry is stale if it references a service not in the current service map, or if it was last updated more than 90 days ago and the topic is fast-moving."
- **Merge policy** — "propose merging only when the entries are truly redundant, not when they cover related but distinct topics."
- **What not to do** — "do not apply changes directly. Propose only. Do not delete entries — propose retirement."

## A worked example

Set up a weekly knowledge curator:

1. Create the agent, bind `primary`/`embedding`.
2. Author `MISSION.md`: "Every Monday, review Brain knowledge. Check the audit log for unreviewed dreaming proposals. Search for duplicates. Flag entries referencing deprecated services. Propose: approve, reject, merge, retire. Post the proposal to the channel. Do not apply changes."
3. Add a weekly schedule: `cron: "0 8 * * 1"`.
4. The agent reads the audit log, searches for duplicates, checks for staleness, and posts the proposal.
5. A human reviews the proposal and applies the changes through the Brain review surface.

## What this guide is not

It is not an auto-editor — the agent proposes; the human applies. It is not a knowledge-base migration tool — curation cleans existing entries; migration between systems is a different task. And it is not a substitute for the [Brain review](../brain-review-ops/) surface — it proposes changes that are applied through that surface.

## Next steps

- For the Brain review surface, read [Brain review](../brain-review-ops/).
- For Brain sources (the input to the knowledge base), read [Brain sources](../brain-sources/).
- For the Brain concept page, read [Brain](../brain/).
- For scheduling, read [Cron schedules](../cron-schedules-ops/).
