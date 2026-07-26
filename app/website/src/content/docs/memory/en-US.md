---
title: Long-term memory
description: Learn how Ankole turns conversations, tasks, and external sources into evolving memory, and how to inspect and correct Agent knowledge and Skill experience.
section: User guide
order: 30
---

Long-term memory does not exist to find more old messages. It lets an Agent revise its understanding of the world and its work when new evidence arrives.

Assume that you said, “I like barbecue,” two years ago. Last month, you said, “I am now vegetarian.” A vector search can retrieve both statements but cannot know that the second statement changes the meaning of the first one.

The Ankole long-term memory module has the codename **Brain**. It connects source evidence, curated current knowledge, background Dreaming, external-source learning, and Skill experience.

## Memory is not a chat archive

An append-only chat log can answer “what did someone say.” It cannot answer “what should the Agent believe now.” A durable memory system must do three more jobs:

- **Memory compaction:** Merge related information from several conversations into one stable topic.
- **Memory evolution:** Revise old knowledge when new facts arrive and retain the useful time boundary.
- **Conflict handling:** Separate a correction, a source disagreement, an unverified claim, and an Agent inference.

Brain maintains two forms of knowledge. The world model contains entries for people, organizations, projects, policies, and their relations.

Reasoning memory contains judgments, experience, and working methods that the Agent induces or deduces.

## What long-term memory contains

| Part | Question that it answers | Can it be used directly as fact? |
|---|---|---|
| **Chat message** | Who said what and when? | It proves only that the statement was made |
| **External source** | Which text, web page, or file did the Agent read? | It is evidence, but each claim can still be wrong |
| **Episode summary** | What was one section of chat about? | No. It only locates original messages |
| **Knowledge entry** | What is the current understanding of one topic? | It is current, cited, and correctable knowledge |
| **Pinned memo** | Which rules must be present on every turn? | It is a compact projection of knowledge |
| **Skill Overlay** | What must this Agent remember when it uses one Skill? | It is procedural experience for one Agent |

One knowledge entry owns one stable topic. It can contain a name, type, aliases, summary, properties, body blocks, and relations to other entries.

Entries and relations form a small world model. For example, a person can belong to an organization, or a project can be affected by a policy. Brain stores a relation only when evidence states it. A model guess does not become a graph edge.

A knowledge entry is not unquestionable truth. It is the best current understanding that the Agent formed from visible evidence. It retains sources, authors, time, and audit records.

## Dreaming turns information into knowledge

**Dreaming** is the background curation process in Brain. It does not call a model after each message. It waits until the conversation is quiet or enough material has accumulated.

This process lets the Agent see a complete discussion and reduces repeated model input.

### Stage A builds an episode index

Stage A processes older messages for each channel. It divides one chat window into one or more episodes. A branch can become a separate episode. Noise can be ignored. An unfinished topic can wait for the next batch.

Each episode contains a topic, summary, likely future question, resolution, related systems, and the original message that supports the resolution.

An episode is only a navigation aid. Stage A does not replace or delete source messages. Brain expands the original chat when an Agent needs to quote or verify the episode.

Brain saves the episode and its cursor in one transaction only after the model output passes validation. A failure does not advance the cursor. The source messages remain available to keyword search if a section is skipped.

### Stage B curates current knowledge

Stage B processes material for one Agent. It first scans episode summaries and a lightweight material index. It then opens only the relevant source messages, current entries, and enabled Skills.

Stage B can create entries, change or remove old blocks, and update summaries, aliases, properties, and relations. It also compacts the pinned memo and writes reusable lessons to Skill Overlays.

A chat message can support a claim about a person, team, decision, or the external world. A task outcome proves only how the Agent performed a task. It does not prove that the final answer was correct.

A normal success does not automatically become experience. A human correction, error recovery, or a non-obvious multi-step success can justify a reusable working lesson.

Stage B changes take effect immediately and enter the audit trail in the same transaction. Human supervision happens after the change. A person can inspect, correct, or restore it without approving every curation action first.

<details>
<summary>Advanced: default Dreaming thresholds</summary>

Stage A runs after 30 quiet minutes or after a channel has 200 queued messages. One window contains at most 200 rows and about 8,000 tokens. It protects the latest 20 rows and the latest 360 minutes.

Stage B runs after 30 quiet minutes or after 50 material rows are queued. One run reads at most 240 material rows. Both stages use the `light` model profile.

These values are advanced instance or Agent settings. A scan can run often, but it calls a model only when the eligibility condition is true.

</details>

## Deductive and inductive memory

Brain does more than copy statements. It can form a new judgment under evidence constraints, but deduction and induction have different roles.

### Deduction: derive the meaning of known facts

Deduction starts with known facts and explicit relations. It answers, “What do these facts mean for the current task?” The Agent reopens relevant entries and sources, then reasons with the current context.

A durable deduction must remain conditional and record its Dreaming author, date, and evidence. An inferred relation does not enter the graph. Only a relation that a source states can become a structured relation.

### Induction: find a pattern across observations

Induction combines observations from different messages or times into a trend, preference, rule, or working lesson. One event cannot become a durable pattern. The current rule requires at least two distinct evidence items.

The result updates the entry that owns the topic. Brain does not create one new memory for each observation. Later evidence can narrow, revise, or reject the induction.

A Dreaming result does not gain more authority because it is more complete. New raw material triggers the next run, and every durable conclusion keeps a path back to its sources.

## How memory compacts and evolves

Stage B uses this general sequence for one material batch:

1. Separate source messages, task outcomes, and temporary state.
2. Find the stable topic for each material item and open current entries.
3. Compare new evidence with current content and update an existing topic when possible.
4. Rewrite obsolete content and retain the useful effective dates and sources.
5. Update summaries, aliases, explicit relations, the pinned memo, and related Skill experience.
6. Commit knowledge, Skill Overlay, audit, and cursor changes in one transaction.

In the earlier food example, the current entry must not list “likes barbecue” and “is vegetarian” without an explanation. It can say that the old preference applied before a date and that the current preference applies after it.

Brain does not use “the newest message always wins”:

| New situation | Brain treatment |
|---|---|
| Explicit correction or a new effective date | Rewrite the old content and state the time boundary |
| Two reliable sources disagree | Keep both and mark the conflict as **unresolved** |
| An unverified claim | Mark it as **unverified** |
| An Agent judgment from evidence | Use conditional language and retain the Dreaming author and date |
| A human correction | Keep the human revision; an old restore cannot overwrite a later edit |

The current release does not use one numeric confidence score to make this decision. Time, source, speaker, explicit correction, and unresolved status remain visible in the content and audit record.

## Learn external knowledge, not only conversations

Open **Knowledge → Materials → Ask an Agent to learn a source**. Select the Agent and memory scope, and then provide one of these source types:

| Source type | Brain treatment |
|---|---|
| **Pasted text** | Create an editable external-document entry |
| **Web URL** | Fetch the page body and create an editable external-document entry |
| **PDF or other file** | Save immutable source bytes, then ask the Agent to read and integrate the file |

Brain stores a file before the learning task starts. The source is not lost if a Worker is unavailable or if the learning run fails. You can retry the same stored source.

A source is evidence, not final knowledge. The Agent should place separate topics in focused entries and cite the source. Learn the source again or correct affected entries when the original changes.

An external-system event can also enter the Agent through a signal source. For fast-changing values, such as prices or inventory, query the owning system during the task.

Brain should retain stable conclusions, causes, effective dates, and source routes.

If the instance has a source Connector, Brain can also synchronize a versioned external document. The document is a read-only mirror. Brain replaces it when the source changes and withdraws it when the source is deleted or access is lost.

<details>
<summary>Advanced: source lifecycle differences</summary>

Pasted text and fetched web content become ordinary entries that a person or Agent can edit. A file retains its source bytes, and each learned block must cite that file.

A Connector mirror belongs to the external system and cannot be edited in Ankole. Change the source in its owning system. Put a local judgment in a separate entry that cites the mirror.

Removing a source does not blindly remove all derived knowledge. Brain uses exact citations and later edits when it decides what it can restore. An old automated action cannot overwrite content that a person changed later.

</details>

## Skill Overlays improve working methods

A knowledge entry answers, “What is true now?” A Skill answers, “How should this kind of work be done?” Putting all working lessons in the knowledge base would mix facts with procedures.

Ankole therefore stores a **Skill Overlay** for each Agent and Skill. The Console calls it **Skill experience**. It is added to the built-in Skill and does not modify the base Skill or affect another Agent.

An Agent can add experience while it works. Dreaming can also extract experience from a correction, error recovery, or a reusable complex procedure. The next time the Skill loads, the Agent receives the base instructions and the Overlay.

Dreaming can update only an enabled Skill. It cannot create a new Skill. It can emit no update when nothing changed. It must revise existing experience instead of appending a near-duplicate.

Open **Knowledge → Skill experience** to inspect the content. Use **Agent Library** to change or remove it. If the Skill is disabled, the Overlay remains stored but does not enter the Agent context.

<details>
<summary>Advanced: Skill Overlay write rules</summary>

New experience first states the situation and then the caution. Dreaming adds a date. One situation is at most 50 tokens by default, and the complete Overlay is at most 2,000 tokens.

Dreaming must replace highly overlapping experience instead of appending it. A content-version check rejects a stale save if Dreaming changed the Overlay while a person was editing it.

Material from a direct message or confidential channel cannot update a global Skill Overlay. Private content cannot change how the Agent works in another context.

</details>

## How an Agent recalls memory

Each turn receives a small pinned memo. It contains only rules that must apply without a search and has a fixed token budget. The Agent searches for all other knowledge when it needs it.

One `memory_search` runs these routes inside the current conversation scope:

1. Keyword search over knowledge entry fields and body blocks.
2. Vector search over knowledge blocks.
3. Keyword search over source chat messages.
4. Vector search over episode summaries.

Brain fuses the four rankings, applies temporal decay, and can use an optional reranker. Chat receives full age decay. Knowledge receives bounded decay and does not disappear only because it was not recently edited.

Brain expands only the winning candidates. An episode expands its source messages. A message in a thread expands the thread. A message without a thread receives nearby chronological context.

Brain then fits the most relevant items into the total token budget. It limits one long candidate so that it cannot remove all other results. The Agent can use `memory_browse` to open the full thread or source.

Embeddings are optional. Keyword search, entries, audits, and Dreaming still work without a vector model. The missing capability is semantic recall for synonyms and related wording.

## Memory scope controls visibility

Each knowledge item has an Agent owner and a store:

| Store | Use it for |
|---|---|
| **Shared** | Company knowledge, common rules, and team facts used by several conversations |
| **Agent self** | The Agent's pinned memo, durable role knowledge, and working methods |
| **Direct message** | Durable context between one person and the Agent |
| **Channel only** | Material that only one confidential channel can read |

A shared channel reads shared and Agent-self knowledge and writes to shared by default. A direct message also reads its private store and writes to that store by default.

The **Memory scope** on a [signal routing rule](../signal-bindings/) selects shared or channel-only memory for a chat channel. Do not put customer data or isolated project material in shared for convenience.

One conversation keeps one fixed memory scope. A changed signal routing rule applies to the next conversation. Ankole does not move old conversation content across the new visibility boundary.

## Long-term memory functions in the Console

The **Knowledge** page has six tabs. They share the same owner Principal selector, but each tab owns one task:

| Tab | What you can do |
|---|---|
| **Entries** | Search, create, and edit current knowledge, and maintain the curation guide |
| **Materials** | Inspect retained files and Connector sources, including learning or sync state |
| **Skill experience** | Inspect Skill Overlays written by Dreaming or the Agent |
| **Status** | Check Dreaming, embeddings, the pinned memo, jobs, and knowledge quality |
| **Audit** | Filter, preview, and restore knowledge changes |
| **Dreaming** | Run Stage B for one Agent and inspect Dreaming fitness |

### Entries and the curation guide

1. Open **Knowledge → Entries**.
2. Select the **Owner** Principal.
3. Search by name, alias, summary, or body.
4. Open more filters when you need type, store, author, or update-time filters.
5. Open an entry and inspect its blocks, sources, and relations.

The entry editor has **Edit**, **Projection**, and **Audit** tabs. Edit changes metadata, body blocks, and relations. Projection shows the Markdown that the Agent reads and links to cited sources.

Enter a reason when you correct a body block. Each block keeps its latest author and version. An edit does not remove history.

The **Curation guide** is above the entry list. Each Principal can have one guide in its self store, and only a person can edit it. It defines domain types, page thresholds, taxonomy, and update rules for Dreaming.

Do not store temporary progress, one-time errors, or unverified guesses as durable knowledge.

### Materials and Skill experience

The **Materials** tab lists retained binary files and Connector-managed sources. Pasted text and web content become knowledge entries, so the Console opens the new entry instead of adding it to this list.

Open a retained file to inspect its learning state, download the immutable original, retry a failed learning task, and open entries that cite it.

The **Skill experience** tab is a read-only summary. Use **Edit in Agent Library** to change or remove the Skill Overlay.

### Dreaming and Dreaming fitness

Open **Knowledge → Dreaming**, select an Agent, and select **Run curation now**. This action runs only Stage B for the selected Agent. It does not run channel-level Stage A.

The result reports the material count, knowledge-operation count, and Skill-experience update count.

The page also shows **Dreaming fitness**. It measures the share of mature Dreaming block writes that a person did not change or remove. It is a review signal, not a knowledge-accuracy or model-quality score.

### Audit and restoration

Open **Knowledge → Audit**. You can filter by store, action, actor, Dreaming run, and date.

Preview the before and after values before a restore. You can restore one record or select several records for one atomic restore. The batch runs newest first. If one current value changed, the complete batch writes nothing.

A restoration creates a new audit record. A deleted entry keeps its audit trail, and the delete record can restore the complete entry.

During review, look for:

- temporary state written as a durable fact;
- expired rules that can still affect decisions;
- duplicate or contradictory entries;
- strong claims without a source;
- Skill experience that is obsolete or duplicated.

### Status

**Knowledge → Status** is the single health surface for long-term memory. It shows alerts, episode and entry-block vectors, global embedding config, Stage A channels, Stage B, pinned-memo budgets, stuck jobs, and knowledge lints.

Knowledge lints count dated names, near-duplicate names, oversized entries, and entries with no body. The page reports these problems. It does not rewrite knowledge.

## Advanced: Brain settings in AppConfigure

<details>
<summary>Show the five Brain settings</summary>

Open **AppConfigure** and select the **Brain** group. The Console currently exposes five settings:

| Setting | Scope | Purpose |
|---|---|---|
| `brain.knowledge` | Global | Pinned-memo budget and recall result count |
| `brain.dreaming` | Global default with Agent overrides | Stage A and Stage B eligibility and run budgets |
| `brain.embedding` | Global | The single vector model and output dimensions |
| `brain.search` | Global | Time decay and optional reranking |
| `brain.sources` | Global | Connector-source polling and chunking |

### `brain.knowledge`

| Field | Default | Purpose |
|---|---:|---|
| `pinned_memo_max_tokens` | `1500` | Maximum pinned-memo tokens on one turn |
| `result_limit` | `10` | Maximum recall candidates |

### `brain.dreaming`

The Console provides a dedicated form and separates **Stage A · channel episodes** from **Stage B · Agent knowledge**.

Stage A reads the global values:

| Console field | Default |
|---|---:|
| Channel quiet period | 30 minutes |
| Channel backlog rows | 200 |
| First-run lookback | 5 days |
| Window rows | 200 |
| Window tokens | 8,000 |
| Protected tail rows | 20 |
| Protected tail age | 360 minutes |

Stage B reads the effective value for the selected Agent:

| Console field | Default |
|---|---:|
| Dreaming | Follow default; enabled for Agents |
| Curation quiet period | 30 minutes |
| Curation backlog rows | 50 |
| Material limit | 240 |
| Token limit | 0, which means no limit |
| Knowledge operation limit | 0, which means no limit |

**Read the full retained history** stores `null` for first-run lookback. A value of `0` starts at the current message. Stage A values apply to the instance and not to the processor Agent selected for one run.

### `brain.embedding`

The Console provides an enable switch, **Embedding model Agent**, and **Output dimensions**. The Agent list contains only active Agents with a configured `embedding` ModelProfile.

When enabled, select an Agent and enter the exact model vector size from 1 through 4096. Knowledge blocks, episodes, and query vectors use this one instance-wide vector space.

One private deployment instance uses one global vector space. After a model or dimension change, Ankole marks old vectors for replacement and rebuilds them in the background.

### `brain.search`

| Field | Default | Purpose |
|---|---:|---|
| `half_life_days` | `30` | Time-decay half-life for chat messages |
| `knowledge_decay_floor` | `0.5` | Minimum time-decay multiplier for knowledge |
| `rerank_enabled` | `false` | Enable the global reranker |
| `rerank_model_agent_uid` | `null` | Agent that provides the `rerank` ModelProfile |

Make keyword and embedding search reliable before you add rerank. A reranker adds one model call to each recall.

### `brain.sources`

| Field | Default | Purpose |
|---|---:|---|
| `enabled` | `true` | Poll Connector-managed external sources |
| `sync_interval_minutes` | `15` | Default synchronization interval |
| `block_max_tokens` | `1500` | Token limit for one synchronized document block |

This setting controls Connector sync only. It does not disable manual pasted text, web fetches, or file uploads.

</details>

## Check memory health

Open **Knowledge → Status**. Inspect **Active alerts** first, and then inspect the named pipeline in page order.

- **A new entry is missing from search:** Try an exact keyword. If only semantic search fails, inspect the embedding configuration and backlog.
- **The Agent remembers something wrong:** Correct the entry. Restore the audited batch if you must undo all its changes.
- **A source remains in learning:** Open the source state, then inspect Background Agent Jobs and Workers.
- **The same fact appears several times:** Merge duplicate content and add common aliases to the retained entry.
- **Dreaming has no new result for a long time:** Check the Agent `light` model profile and the unavailable reason or failed task on the status page.
- **Group material appears in the wrong store:** Inspect the signal routing rule and memory scope for that Channel Provider.
