---
title: Brain
description: Give Agents durable, traceable organizational memory from conversations, files, and web pages, with explicit disclosure boundaries.
section: User guide
order: 18
---

Brain is a long-term memory system inspired by GBrain. It turns durable information from conversations, files, and web pages into traceable organizational knowledge. Agents can recall, revise, and forget that knowledge within explicit disclosure boundaries.

Brain does not keep a growing transcript and call it memory. It maintains a current view of people, organizations, events, judgments, and their relationships. New evidence can support an earlier claim, replace it, or expose a contradiction. The evidence and earlier state remain available for review.

All Agents in one Ankole instance use the same knowledge space. Content is not copied into a private database for each Agent. Each memory carries its own audience scope, so shared storage does not mean unrestricted disclosure.

## What Brain can learn

Knowledge reaches Brain through three current paths:

| Path | Result | Conditions |
| --- | --- | --- |
| An Agent calls `remember` | One fact or judgment becomes durable immediately | The Agent must file one atomic claim, give its source, and select a valid audience scope |
| Signals learning processes a conversation | Useful facts, judgments, and open commitments can be learned without an explicit `remember` call | The channel must be a direct message or IM group, and `brain.extraction_model` must be configured; group learning also needs a synchronized member permission group |
| An operator registers a Source | A file or web page becomes searchable and can produce extracted claims | Claim extraction needs `brain.extraction_model`; files must be deployment-readable, and files and fetched page text must be valid UTF-8 no larger than 10 MiB; URLs also need a Web Fetch Provider |

Signals learning runs after an eligible channel becomes idle or its conversation ends. It reads the channel message slice, not the Agent's private model transcript. In a direct message, learned content defaults to the other person's scope. In a group, it defaults to the channel member group's scope.

Once `remember` succeeds, its write remains even if the rest of the turn later fails, is cancelled, or is retried. This makes an acknowledged memory a durable result rather than a side effect of a successful final reply.

Each registered Source has a default audience scope. Use the narrowest scope that still serves the intended readers. Archiving a Source stops later learning runs but does not remove knowledge already learned from it.

## How Brain represents knowledge

Brain keeps several forms of knowledge because they answer different questions:

- A **page** is the current description of one stable subject, such as a person, company, event, project, document, or concept.
- A **Fact** is one observation that can be checked or updated. It carries confidence, time, source, holder, and audience scope.
- A **Take** is a judgment, prediction, bet, or hunch held by a person, Agent, or Brain. It carries weight and can later be graded or resolved.
- A **Timeline** records what happened to a subject and when.
- A **Link** records a relationship between two pages.

The holder is the person or Agent that holds a claim. It is not the subject of the sentence. If Alex says that a supplier is unreliable, the Take is held by Alex; it is not a Fact held by the supplier.

One claim must contain one assertion that can change on its own. Brain keeps the source of each claim and retains earlier page versions and superseded claims. A correction changes the current view without erasing how that view formed.

## How an Agent uses memory

Brain supplies relevant memory in two ways. At the start of a conversation and after context compaction, it prepares a bounded context pack about participants, recently mentioned subjects, important current facts, and open commitments. On each text turn, it can also point the Agent to named pages that match the new message.

These injections make no model call of their own. If assembly times out or fails, they return nothing and the turn continues. Recalled text is background data, not an instruction, and can be stale or incomplete.

Agents can also use these tools when a task needs an explicit memory operation:

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

Some shipped Skills contain an SOP or method that is useful only when the current work matches it. A Skill can declare `brain-recall-only: true` so it stays out of the Skill catalog in every prompt and remains discoverable through Brain.

Brain indexes only the Skill's `name`, `description`, and `tags` in a world-scope discovery record named `lazyload-agent-skills/<skill-name>`. The Skill body, all other Skill files, and Agent-specific lessons stay with their existing owners and are read through `skill_view`. If `recall` returns such a record, the Agent calls `skill_view`, which applies `ankole-runtime`: it loads the instructions on a compatible execution surface, routes the Main Agent to a background-only Skill, and rejects any other incompatible read. `get_page` provides the same result by delegating the request to `skill_view`.

The current Agent's effective Agent Plugin and Skill settings apply before Brain selects candidates. A disabled Skill is not discoverable and cannot be loaded. Its shared discovery projection remains in storage, so re-enabling it restores access without rebuilding the projection.

Recall combines full-text and vector candidates when an Embedding model is available. It can rerank the result when a Rerank model is configured. Without an Embedding model, full-text recall still works. Without a Rerank model, recall keeps the fused order.

## Knowledge and disclosure boundaries

Each protected paragraph, Fact, Take, and Timeline entry uses one audience scope:

| Scope | Who can reach it |
| --- | --- |
| `world` | Any Principal in the instance |
| `group:<name>` | Current members of that permission group |
| `principal:<uid>` | Only that Principal |

Permission-group membership is checked when Brain reads or writes the content. A person's later team change therefore affects future recall without rewriting every memory.

An author can reach the Claims and Timeline entries that they wrote. An Agent owner can inspect that Agent's private scope and knowledge written or held by the Agent. Ownership does not let the owner read group knowledge through the Agent; the owner must independently belong to the group.

Group conversations add a second disclosure check:

- **Strict**, the default, discloses group-scoped memory only when every member considered present can already reach it.
- **Relaxed** checks the person who asked and does not let other present members narrow the result.

Both modes behave the same in a direct message.

A Source or channel records where evidence came from. It does not grant access to the learned knowledge. Set the audience scope on the learned content itself. Page metadata such as slug, title, type, and existence is visible inside the instance; protected page sections and structured claims are filtered.

An Agent uses its confidentiality guidance to select a scope for an active `remember` call. That classification is a best-effort model judgment. The application enforces the selected scope deterministically, but it cannot prove that the model classified the content correctly. For compliance-grade isolation, restrict who can access the Agent through [Principals and permission groups](../principal-and-groups/) instead of relying only on memory classification.

## How knowledge stays current

Dreaming is the scheduled maintenance window for knowledge that needs judgment. It can:

- consolidate related facts into a cautious Brain-held Take;
- find patterns across pages and write evidence-linked analysis;
- extract relationships and timeline events;
- grade due Takes and update calibration summaries;
- detect possible contradictions;
- propose schema terms when repeated evidence needs a clearer type.

Dreaming does not silently resolve a contradiction or rewrite its Claims. It records the finding for a person to resolve or dismiss in the Console. Schema suggestions also require approval before they change the instance vocabulary.

Facts lose ranking weight as they age according to their kind. This decay changes recall order, not the stored confidence or history. Explicit forgetting changes the current state: a Fact expires, a Take becomes inactive, or a page becomes soft-deleted. Soft-deleted pages can be restored before the configured purge window ends. Expired and superseded claims remain as audit and calibration history.

Self-healing maintains the searchable projections. It repairs stale chunks and embeddings, checks search indexes, and finds eligible channel slices that still need learning. This work does not call a reasoning model.

## Operate Brain in the Console

The **Brain** area gives operators a result-focused view of the knowledge space:

- **Objects** shows pages, their rendered content, facts, timelines, links, tags, versions, rollback, deletion, and restore actions.
- **Claims** shows Facts and Takes, their sources and current state, and actions to correct, forget, or resolve them.
- **Contradictions** holds findings for human review.
- **Suggestions** holds proposed vocabulary changes for approval or rejection.
- **Sources** registers files and URLs, starts learning, and archives sources.
- **Search preview** runs recall as a selected Principal and disclosure mode.
- **Principal audit** lists knowledge where one Principal is the holder, author, or audience.
- **Health** shows model readiness, learning backlog, embedding failures, channel prerequisites, and projection status.

The Brain settings select one instance-wide model for each system activity:

| Setting | What it enables |
| --- | --- |
| Embedding model | Vector recall and semantic Fact deduplication |
| Rerank model | Cross-encoder ordering after retrieval fusion |
| Web Fetch Provider | Readable-text extraction for URL Sources |
| Extraction model | Signals learning and claim extraction from Sources |
| Dreaming model | Model-dependent Dreaming phases and `synthesize` |

A missing optional model narrows the related capability instead of hiding the state. The Health page reports what is unavailable. Disabling Brain removes its tools and context injection and stops its background tasks; stored knowledge stays unchanged.

The `general` schema pack supplies a common vocabulary for every instance. Setup can also add packs for private equity and venture capital, public markets, consumer businesses, legal work, software, and consulting. All Agents share the installed vocabulary. Repeated concepts can become approval-gated schema suggestions instead of uncontrolled new types.

## Current limits

Brain currently learns conversation slices only from direct-message and IM-group channels. Registered Sources currently support files and URLs. It does not directly learn from connector, webhook, or alert Sources.

Brain is an evidence system, not a guarantee that every stored statement is true or complete. Use source, time, confidence, holder, and contradiction status when a decision needs stronger support.

For the system boundary around Brain, read [Architecture](../architecture/). For runtime settings, read [AppConfigure](../app-configuration/). For process guardrails learned from work trajectories, read [Skill Lessons](../skill-lessons/).
