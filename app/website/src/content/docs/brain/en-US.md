---
title: Brain
description: The long-term memory of an Ankole installation — curated knowledge, source-chat recall, dreaming, and human oversight, with PostgreSQL rows as truth and Markdown as projection.
section: Developer guide
order: 104
---

Brain is the long-term memory of one accountable principal. It holds three things at once: the curated knowledge an agent works from, the recall path back to what was actually said in source chats, and a dreaming process that turns raw history into indexed episodes and proposed knowledge. A human reviews the proposals before they become fact. This page maps that model against the real code in `Ankole.Brain`.

The decisive property, stated up front: structured knowledge is durable truth, and Markdown is a projection of it — not the other way around. Brain coordinates evidence, curation, current knowledge, and human review. SignalsGateway still owns chat evidence; Brain owns retained source bytes, curated knowledge, dreaming state, and recovery records.

## Scope: who can see what

Every Brain read and write flows through a `Brain.Scope`, and that scope is derived only from the declaration on an AIGateway conversation — specifically `conversation.metadata["brain"]`. No channel event, no provider metadata, no ambient runtime state is consulted as a fallback. A scope carries an `owner_uid`, the set of `readable_store_keys`, one `writable_store_key`, and the `current_channel`. A special shared owner, `brain-shared`, exists for knowledge that spans principals.

This routing choice is deliberate. It keeps the permission boundary on the conversation declaration, where an operator can see and change it, instead of letting memory drift toward whoever happened to speak last.

## Durable truth versus projection

The model rests on a sharp split:

- **Structured knowledge** — entries, blocks, relations, citations — is durable truth, written through transactional operations with append-only audits. A batch either commits its mutations and its audits together, or it leaves no partial state.
- **Markdown projections, search results, injected context** are cheaper views rebuilt from that truth. Losing a projection is an inconvenience; losing a knowledge row is a change in what the agent believes.

All reads apply owner and readable-store predicates in SQL, so the scope is enforced at the database edge, not in application code that a caller could talk around.

## Recall: three channels, one result

When an agent turn needs memory, recall runs against two evidence sources in parallel and merges the results:

- **Chat recall** reads the immutable entries SignalsGateway mirrored, scoped to channels the conversation can see. It treats recalled messages as untrusted historical data, never as instructions — a notice to that effect rides with every result set.
- **Knowledge recall** reads curated Brain entries and blocks, using both BM25 keyword candidates and vector candidates over their embeddings, then merges and re-ranks within a result token budget.
- **Search** is the merged entry point: it runs the two channels in parallel, applies temporal decay so fresh evidence is favored, and returns one ranked set tagged with where each item came from.

Episodes are the bridge between chat and knowledge. An episode is a time-addressable summary index over immutable chat-layer facts — topic, summary, the source entry ids it covers, a time range, and an embedding. It is explicitly a navigation index; the notice that accompanies it tells the model the original messages are authoritative.

## Dreaming: turning history into indexed memory

Dreaming is the offline process that converts raw chat history into episodes and proposed knowledge, without a human in the loop for the model step. It runs in two stages with different frequencies and jobs.

**Stage A** is the channel-level summarizer. It scans channels with unprocessed entries and enqueues episode-summary jobs, each of which asks a light model profile to summarize a window of chat into an episode. An episode without a usable light profile on an agent that can see the channel is reported as unavailable, not silently skipped; dreaming disabled by configuration stops the stage cleanly.

**Stage B** is the lower-frequency, principal-level knowledge curation. It runs model inference outside the transaction, then commits the validated small operations, skill-overlay updates, and both material high-water marks together — so a partially applied run is retried rather than silently skipped. The output is proposed knowledge with evidence, not a silent edit to the knowledge base.

The two-stage split exists because the jobs have different cost and risk profiles. Stage A is cheap, frequent, and produces navigation aids; Stage B is expensive, infrequent, and proposes facts. Keeping them separate stops the expensive job from gating the cheap one.

## Write authority: who may put what

A knowledge write carries an explicit `WriteAuthority` with one of five modes: `:human`, `:agent`, `:dreaming`, `:source_learning`, or `:mechanical`. The mode decides what the write may cite and which document ids it may touch. Authored writes derive owner, store, and author from the trusted scope and actor; the operation payload cannot override them. The two actorless mechanical operations — `create_entry` and `delete_block` — cannot author content and require an explicit causal surface.

This is how Brain keeps dreaming and source-learning output from pretending to be a human decision. A dreaming proposal is a dreaming write, labeled as such, with its evidence attached — never a quiet promotion into authoritative knowledge.

## Human oversight

The model never edits knowledge unsupervised and never presents its own output as fact. The oversight surface lives behind console-scoped routes:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/brain/entries` | List curated knowledge entries |
| `GET` | `/brain/entries/:id` | Read one entry |
| `POST` | `/brain/entry-operations` | Apply a batch of knowledge operations |
| `GET` | `/brain/sources` | List retained sources |
| `POST` | `/brain/sources` | Add a source |
| `POST` | `/brain/sources/:document_id/learning-runs` | Run source learning |
| `GET` | `/brain/audit-log` | Read the append-only audit trail |
| `POST` | `/brain/audit-log/:audit_id/restorations` | Restore one audited change |
| `POST` | `/brain/dreaming-runs` | Trigger a dreaming run |
| `GET` | `/brain/dreaming-fitness` | Inspect whether dreaming is fit to run |
| `GET` | `/brain/status` | Brain health and configuration status |

The audit log is append-only, and every restoration is itself audited, so the history of what the agent believed — and who changed it — is reconstructable. Source withdrawal removes a retained source cleanly; it does not leave the agent citing bytes it can no longer read.

## What Brain is not

It is not a vector store with a chat log bolted on. The rows are the truth; the vectors and the Markdown are conveniences over them. It is not a place for the model to write whatever it wants — writes carry authority, evidence, and audit. And it is not the chat evidence owner; that stays with SignalsGateway. Brain's boundary is durable, reviewed, owner-scoped memory, plus the offline machinery that proposes what should go into it.

## Next steps

- For the chat evidence Brain recalls from, read the [SignalsGateway](../signals-gateway/) page.
- For the conversation declaration that scopes Brain, read the [AIGateway API](../ai-gateway/).
- For how recalled memory reaches a running turn, read the [Actor Runtime](../actor-runtime/) page.
