---
title: Brain
description: Give Agents durable, traceable organizational memory from conversations, files, and web pages, with explicit disclosure boundaries.
section: User guide
order: 18
---

Brain derives searchable facts, judgments, events, and relationships from Pod pages and conversations. People and Agents maintain the same knowledge in Pod, while Brain preserves provenance and distinguishes current assertions from superseded ones.

## Maintain knowledge in Pod

`/AnkoleBrain` contains organization knowledge, Agent identity pages, skills, and generated analysis. Knowledge pages support Markdown, business properties, references, and revision history. People edit them in Pod; Agents use the shared Pod page tools. Page IDs stay stable when a page moves or its title changes.

A page’s knowledge panel shows the facts, timeline events, backlinks, and calibration scores that the reader can access. The Console’s **Objects** list opens these pages in Pod.

Knowledge enters Brain through these paths:

| Path | Result |
| --- | --- |
| An Agent calls `remember` | One atomic Fact or Take with provenance and a source node |
| A person or Agent updates Pod content | Search passages and page references update with the committed page revision |
| Conversation learning | Useful facts, judgments, and commitments are extracted from eligible direct-message and group conversations |
| A registered file or URL Source | Source content becomes a Pod knowledge page and can produce extracted claims |

Public Pod content participates in search. Organization rules in `AGENTS.md` and `DESIGN.md` guide behavior rather than serving as fact sources. Skills are searchable, but their instructions are not extracted as facts. Other business pages outside `/AnkoleBrain` can opt into fact extraction with the `extract_facts` property.

## Facts, judgments, and evidence

A **Fact** records an observation with confidence, time, provenance, and a holder. A **Take** records a judgment or prediction with a weight that can later be evaluated. A **Timeline** records a dated event. Typed links connect related pages.

Every claim and event has a source node. Its subject page is optional: a conversation can contain a useful commitment before anyone creates a separate entity page. The holder identifies who makes an assertion, while the subject identifies what the assertion concerns.

## Read and share knowledge

Knowledge uses the same current permissions as Drive and Pod. Sharing one page grants access to that page; sharing a container can include its descendants. Restricted page titles, metadata, content, facts, and events follow those boundaries. A claim about a public company can still remain private because its evidence comes from a restricted conversation.

Agent reads use the intersection of the Agent’s and requester’s access. In strict group disclosure mode, every participant considered present must also be able to read the source. Relaxed mode checks the Agent and requester. Membership or sharing changes affect subsequent reads immediately.

Conversation learning uses the conversation’s Drive root as the source. For explicit `remember` calls, the Agent uses the request’s source by default and can select another accessible source node according to organization rules in `AGENTS.md`. Ankole enforces the source’s current permissions when retrieving the result.

## Use memory in a task

Brain supplies bounded context about participants, mentioned entities, current facts, and open commitments when a conversation starts or resumes after compaction. Subsequent text turns can include pointers to matching names. The Agent can then use:

| Tool | Outcome |
| --- | --- |
| `remember` | Record one atomic Fact or Take |
| `recall` | Retrieve current claims, entity cards, page passages, and timeline passages |
| `entity` | Inspect a subject’s visible facts and relationships |
| `whoknows` | Find people, Agents, and organizations associated with a topic |
| `delta` | Read new and expired claims and events within a time range |
| `synthesize` | Write an analysis page backed by visible evidence |

Pod reads offer metadata, a compact outline, or the complete page. The outline keeps introductions and section headings, with long tables and code blocks folded. Agents request full content when the task needs it. Ambiguous names produce candidates for disambiguation.

Each skill has a home page at `/AnkoleBrain/skills/<name>` and supporting files beneath it. The runtime reads that home page as `SKILL.md`. Agents discover relevant skills through summaries and search, then read them through `skill_view`. Skill catalogs, content, and background Job materialization use the current requester and Agent permissions. The declared `ankole-runtime` determines where a skill runs.

## Keep knowledge current

Scheduled **Dreaming** consolidates evidence, generates analyses, extracts timeline events, evaluates due Takes, and detects contradictions. Operators resolve contradictions in the Console. Retrieval confidence decays with age according to the Fact’s kind; this changes ranking without rewriting the original confidence.

Page extraction commits only if its input revision still matches. Removing a source from Drive immediately removes its passages and derived claims from retrieval. Pod owns trash, restoration, permanent deletion, and page history. Archiving a registered Source stops future learning while preserving its Pod content.

Scheduled **self-healing** rebuilds stale chunks and embeddings, checks indexes, and queues eligible conversation slices. These search projections can be rebuilt from PostgreSQL content and structured records.

## Operate Brain

The Console provides **Claims**, **Contradictions**, **Sources**, **Search preview**, **Principal audit**, and **Health**. Operators can correct or expire claims, resolve Takes, inspect provenance, trigger Source learning, and diagnose missing model configuration.

Brain runs model calls as the tenant’s `ankole_brain` system Principal. Its effective `light` profile handles extraction, `heavy` handles synthesis and model-based maintenance, and `web_fetch` fetches URL Sources. Operators configure these profiles and `rerank` in the Console model-profile editor; the embedding model is a site setting. Missing optional models limit the corresponding capability; existing knowledge and full-text retrieval remain available. `brain.enabled` controls Brain tools, automatic context, and background learning without deleting stored knowledge.

See [Architecture](../architecture/), [AppConfigure](../app-configuration/), and [Skill Lessons](../skill-lessons/) for related contracts and settings.
