---
title: Brain
description: Give Agents durable, traceable organizational memory from conversations, files, and web pages, with explicit disclosure boundaries.
section: User guide
order: 18
---

Brain is Ankole's long-term memory system—inspired by GBrain and structured around an enterprise ontology similar to Palantir—that turns durable facts from conversations, files, and web pages into traceable organizational knowledge. Within explicit disclosure boundaries, Agents can recall, revise, and forget what Brain knows.

Rather than appending raw transcripts and calling them memory, Brain maintains an up-to-date model of people, organizations, events, judgments, and their relationships. As new evidence arrives, Brain reinforces earlier claims, supersedes outdated ones, or surfaces contradictions—while preserving both the underlying evidence and superseded states for review.

Every Agent within an Ankole tenant shares one knowledge space instead of copying data into isolated per-Agent silos. Because every memory carries its own audience scope, sharing storage never implies unrestricted disclosure.

## What Brain can learn

Knowledge enters Brain through three active paths:

| Path | Result | Conditions |
| --- | --- | --- |
| An Agent calls `remember` | One fact or judgment becomes durable immediately | The Agent must file one atomic claim, give its source, and select a valid audience scope |
| Signals learning processes a conversation | Useful facts, judgments, and open commitments can be learned without an explicit `remember` call | The channel must be a direct message or IM group, and the Brain maintainer Agent must have a usable `light` profile; group learning also needs a synchronized member permission group |
| An operator registers a Source | A file or web page becomes searchable and can produce extracted claims | Claim extraction needs the maintainer Agent's `light` profile; files must be deployment-readable, and files and fetched page text must be valid UTF-8 no larger than 10 MiB; URLs need the Agent's `web_fetch` profile |

Signals learning runs once an eligible channel goes idle or its conversation closes, reading the visible channel message slice rather than the Agent's internal model transcript. Extracted claims default to the other person's scope in direct messages and to the synchronized channel-member group's scope in group chats.

Once a `remember` call commits, its write persists even if a later step in the turn fails, is cancelled, or is retried—making an acknowledged memory a durable fact in its own right rather than a side effect of a completed reply.

Every registered Source carries a default audience scope; pick the narrowest scope that still serves its intended readers. Archiving a Source halts future extraction runs while keeping knowledge already learned from it intact.

## How Brain represents knowledge

Brain models several distinct record types because each answers a different kind of question:

- A **page** describes one stable subject—a person, company, event, project, document, or concept.
- A **Fact** records a single verifiable observation with its confidence, timestamp, source, holder, and audience scope.
- A **Take** captures a judgment, prediction, bet, or hypothesis held by a person, Agent, or Brain, carrying a weight so it can later be graded or resolved.
- A **Timeline** logs what happened to a subject and when.
- A **Link** connects two related pages.

Note that a claim's **holder** is the person or Agent asserting it rather than the subject of the sentence: if Alex says that a supplier is unreliable, Brain records a Take held by Alex, not a Fact held by the supplier.

Each claim must express a single atomic assertion that can change independently. Because Brain retains provenance alongside prior page revisions and superseded claims, correcting a claim updates the current view without erasing how that conclusion formed.

## How an Agent uses memory

Brain injects relevant memory automatically at two points: when a conversation starts (and again after context compaction), it assembles a bounded context pack covering participants, recently mentioned subjects, key current facts, and open commitments; on each subsequent text turn, it also points the Agent to named pages matching the incoming message.

Neither automatic injection makes an LLM call—if assembly times out or fails, Brain skips the injection so the turn proceeds normally. Treat recalled text as potentially stale or incomplete background data rather than instructions.

When a task calls for explicit memory lookup or updates, Agents invoke dedicated Brain tools:

| Tool | Outcome |
| --- | --- |
| `learn_source` | Registers one web URL as a Source and starts background learning |
| `recall` | Returns current Facts and Takes first, then relevant page passages within a token budget |
| `get_page` | Reads one complete filtered page by slug or natural-language name; ambiguous names return candidates instead of a guess |
| `entity` | Returns an entity card with selected facts, relationships, and a backlink count |
| `whoknows` | Ranks visible people, Agents, and companies whose stored knowledge matches a topic |
| `delta` | Reports new and expired claims and timeline events within a time range |
| `synthesize` | Uses recalled evidence to write a durable analysis page for one question |
| `forget` | Expires one Fact, deactivates one Take, or soft-deletes one page, with a recorded reason |

### Discover recall-only Skills

Shipped Skills that teach specialized SOPs can declare `brain-recall-only: true` so they stay out of every turn's prompt catalog while remaining discoverable through Brain when relevant.

For each recall-only Skill, Brain indexes only its `name`, `description`, and `tags` into a `world`-scoped discovery record named `lazyload-agent-skills/<skill-name>`, leaving the `SKILL.md` body, bundled files, and Agent-specific lessons in their authoritative stores to be read via `skill_view`. When `recall` surfaces such a record, the Agent calls `skill_view` (and calling `get_page` on that record delegates to `skill_view` automatically), which enforces `ankole-runtime`: loading the instructions on compatible surfaces, guiding the foreground Agent to delegate background-only Skills, and rejecting any other incompatible read.

Before returning candidates, Brain filters against the calling Agent's effective Agent Plugin and Skill settings so a disabled Skill can neither be discovered nor loaded. Because the shared discovery projection stays in storage while disabled, re-enabling the Skill restores discovery immediately without rebuilding the index.

When an Embedding model is configured, `recall` fuses full-text BM25 and vector candidates (falling back to full-text search alone when unconfigured), and when a Rerank model is configured, Brain re-orders the fused results with a cross-encoder.

## Knowledge and disclosure boundaries

Every protected paragraph, Fact, Take, and Timeline entry carries an explicit audience scope:

| Scope | Who can reach it |
| --- | --- |
| `world` | Active Human members (`membership = member`), active Agents, and System Principals in the tenant; external Guests (`membership = guest`) and inactive Principals are excluded |
| `group:<name>` | Current members of that permission group |
| `principal:<uid>` | Only that Principal |

Brain evaluates permission-group membership dynamically on every read and write, so when someone changes teams, future recall reflects their updated access immediately without rewriting historical records.

Authors can always read the Claims and Timeline entries that they wrote, and an Agent's human owner can inspect that Agent's private scope as well as knowledge authored or held by the Agent. Ownership does not grant backdoor access to group-scoped knowledge—the owner must belong to that permission group independently.

Group conversations enforce an additional disclosure check:

- **Strict** (default) discloses group-scoped memory only when every participant considered present in the room already has access to it.
- **Relaxed** checks only the person who asked the question, without letting other participants in the room narrow the results.

In one-on-one direct messages, both modes behave identically.

A Source or chat channel records provenance—where the evidence came from—without granting access to the extracted knowledge; always set the desired audience scope on the learned content itself. Within a tenant, page-level metadata (slug, title, object type, and existence) is visible across Principals, while protected sections and structured claims are filtered per viewer.

When an Agent calls `remember` explicitly, it chooses an audience scope using its `ConfidentialityPolicy.md` guidance. While Ankole enforces the chosen scope deterministically afterward, the initial scope choice is still a best-effort model judgment. Whenever you need compliance-grade isolation, restrict who can access the Agent through [Principals and permission groups](../principal-and-groups/) rather than relying solely on model classification.

## How knowledge stays current

Scheduled **Dreaming** runs perform the maintenance tasks that require model judgment:

- consolidating related Facts into a cautious Brain-held Take;
- spotting cross-page patterns and writing evidence-linked synthesis;
- extracting entity links and timeline events;
- grading due Takes and updating calibration summaries;
- flagging potential contradictions.

Dreaming never resolves a contradiction or overwrites conflicting Claims silently; instead, it logs the contradiction so a human operator can resolve or dismiss it in the Console.

As Facts age, Brain decays their retrieval ranking weight according to their kind—adjusting search order without altering stored confidence scores or audit history. Only an explicit `forget` call or operator action changes active validity: expiring a Fact, deactivating a Take, or soft-deleting a page (which remains restorable until the purge window expires), while keeping expired and superseded claims for audit and calibration.

Alongside Dreaming, scheduled **self-healing** maintains searchable projections without calling a reasoning model—repairing stale chunks and embeddings, verifying search indexes, and queueing eligible idle channel slices that still need learning.

## Operate Brain in the Console

In the Console, **Brain** gives operators direct visibility and control over the tenant's knowledge space:

- **Objects** inspects pages, rendered sections, facts, timelines, links, and revision history, with rollback, soft-delete, and restore actions.
- **Claims** lists Facts and Takes with their provenance and current status, plus controls to correct, forget, or resolve them.
- **Contradictions** queues detected conflicts for human resolution.
- **Sources** registers files and URLs, triggers extraction runs, and archives sources.
- **Search preview** tests `recall` as any chosen Principal and disclosure mode.
- **Principal audit** lists every record where a given Principal is the holder, author, or target audience.
- **Health** reports model readiness, learning backlogs, embedding errors, channel prerequisites, and index status.

Tenant settings select the Brain maintainer Agent and optional rerank model, while site settings select the embedding model and vector dimensions. Because every Brain model call executes as the maintainer Agent and attributes usage to it, keep that Agent enabled—disabling it marks Brain unhealthy and halts Brain model calls and URL Source fetching until you re-enable or replace it, though existing knowledge and full-text recall remain available.

| Owner and setting | What it enables |
| --- | --- |
| Maintainer Agent `light` profile | Signals learning and claim extraction from Sources |
| Maintainer Agent `heavy` profile | Model-dependent Dreaming phases and `synthesize` |
| Maintainer Agent `web_fetch` profile | Readable-text extraction for URL Sources; without it, URL Sources are not learned |
| Brain Embedding model | Vector recall and semantic Fact deduplication |
| Brain Rerank model | Cross-encoder ordering after retrieval fusion |

Leaving an optional model unconfigured narrows only that capability and surfaces clearly on **Brain → Health** instead of failing silently. Turning off `brain.enabled` removes Brain tools and automatic context injection and stops background jobs while leaving all stored knowledge intact.

Every tenant starts with the `general` schema pack, and during setup you can add domain packs for private equity and venture capital, public markets, consumer businesses, legal work, software, and consulting. All Agents in the tenant share the installed vocabulary.

## Current limits

Brain currently extracts conversation slices only from direct-message and IM-group channels, and registered Sources support files and web URLs—connector, webhook, and alert streams are not ingested directly.

Treat Brain as an evidence ledger rather than an infallible oracle: when a consequential decision depends on a stored claim, check its provenance source, timestamp, confidence, holder, and contradiction status.

For Brain's architectural boundaries, read [Architecture](../architecture/); for runtime keys, read [AppConfigure](../app-configuration/); and for procedural guardrails distilled from execution trajectories, read [Skill Lessons](../skill-lessons/).
