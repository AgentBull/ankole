# Ankole Brain: Curated Knowledge, Dreaming, and Human Oversight

Status: final design  
Date: 2026-07-12

This document is the canonical English design for Brain. Its Chinese counterpart is
`internals/docs/Brain.zh.md`. A behavior change must update both documents.

Brain replaces the former Memory design. Chat recall, curated knowledge, dreaming,
review support, and recovery now belong to one subsystem and one relational model.

---

## 1. What Brain Is

Brain is Ankole's long-term memory capability. It has three parts:

- **curated knowledge**, which stores the system's current understanding as editable entries;
- **dreaming**, the background process that consolidates evidence and derives bounded conclusions;
- **human oversight**, which lets people inspect, correct, and clean up memory after the fact.

Brain is a built-in AIGateway capability. AIGateway owns stateful conversations,
messages, and model calls. Brain owns durable knowledge and recall for a Principal.

A Principal is an installation-wide accountable subject. Agents, humans, and API
callers are all Principals. Memory therefore belongs to a Principal, not to a worker
process or provider adapter.

The public Elixir context is `Ankole.Brain`. Chat recall, knowledge, dreaming, review,
and recovery live behind that facade. Persistent tables use the `brain_` prefix.

Model-facing tool names remain `memory_*`. "Memory" is the clearest term for a model,
while `Brain` is the product and code-level subsystem name.

Ankole has no released legacy contract for the removed Memory v1 storage. The old
`memory_notes` mechanism and old `memory_*` tables are deleted rather than preserved
through compatibility branches.

---

## 2. Background

### 2.1 Problems Brain Must Solve

Four user stories define the requirement.

**Preferences and working state change.**

A user may once prefer barbecue and later become vegetarian. An append-only log gives
both statements equal standing.

Brain must express that a newer state replaces an older one while keeping the original
conversation available for recall.

**Digital employees need a continuing view of the outside world.**

Policy changes, earnings reports, and company announcements happen independently of
conversation.

Brain must turn scattered evidence into an entry that answers, for example, "What do
we currently know about Kweichow Moutai?"

Facts, rumors, and inferences must remain distinguishable within that current view.

**Experience should improve later work.** A recovered failure or human correction
should become a relevant caution the next time the same kind of task is performed.
It should not remain buried in chat history.

**Long-running work requires human oversight.** Ankole tasks may last weeks or months.
Requirements, repositories, dependencies, and priorities change during that time.
Goal revision is normal, not exceptional.

An agent may detect that reality and memory diverge, but the task owner decides what
the goal should become. The same applies to accumulated memory: only a person can
reliably decide which decisions, lessons, and records still matter.

Automatic policies are not enough. "Keep the newest" can delete an old lesson that
still holds. "Keep the most frequent" can preserve an early false assumption.
Low-frequency review at milestones is the durable quality boundary.

Goal correction and memory maintenance therefore share one workbench: people inspect
and edit the memory itself.

### 2.2 Sources of the Design

The design compares public implementations and documented product behavior. The table
states what Ankole adopts and what it deliberately rejects.

| Source | What it is | Adopted | Rejected |
| --- | --- | --- | --- |
| BullBrain | The original internal intent for ontology-backed, reasoning-oriented memory | User stories; entities and relations; batch induction across evidence | Observer-specific copies, inference-level rows, extract-on-arrival, graph propagation |
| Claude Tag | Anthropic's Slack-based digital employee | Public versus DM memory routing | — |
| openclaw | An open-source personal assistant with Markdown memory | Progressive disclosure, pre-compaction flush, hybrid retrieval, time decay, source rehydration | Filesystem truth |
| hermes-agent | An open-source personal agent framework | Hard resident-memory budget and threat scanning | — |
| EverOS / EverCore | A benchmark-oriented memory system | Skill-note add/revise rules, budgets, hypothesis promotion, task context as a retrieval key | Case storage, model-scored promotion, MongoDB + Elasticsearch + Milvus |
| Honcho | A memory service organized by observer and observed subject | Exclude a background process's own output from its trigger count | N-by-N observer copies |
| llm-wiki | A hermes-agent skill implementing wiki-shaped knowledge | One directly editable current page and review-time lint checks | Manually maintained directory files |
| Open Knowledge Format | Google's open knowledge exchange format | `type` as the only required ontology field | — |
| [Harness Engineering for Self-Improvement](https://lilianweng.github.io/posts/2026-07-04-harness/) | Lilian Weng's review of agent self-improvement | ACE as the loop shape; evaluators and permissions remain outside the loop | Letting an agent rewrite its own runtime framework |

Section 16 records implementation-level correspondences.

### 2.3 Terminology

**Principal** is the installation-wide accountable subject. **AIGateway** is the
stateful model gateway. **SignalsGateway** receives provider facts and mirrors external
messages in `signal_gateway_entries`.

**Kernel** is the Rust computation boundary. It owns pure mechanics such as crypto,
protocol validation, provider adaptation, and RRF. It does not connect to PostgreSQL.

**AppConfigure** stores operator-managed runtime settings. Environment variables are
reserved for process bootstrap. **Oban** is Ankole's PostgreSQL-backed job queue.

**BM25** is keyword relevance scoring, provided by ParadeDB `pg_search`. **Embedding**
turns text into a vector for semantic retrieval; vectors use `pgvector`.

**RRF**, or Reciprocal Rank Fusion, deterministically combines ranked lists. **Rerank**
uses a specialized model for an optional second ordering pass.

**Optimistic locking** rejects a write when its expected version is stale. The caller
reopens the current entry and retries. **DM** means a one-to-one private conversation.

---

## 3. Design Axioms

These five axioms resolve conflicts between individual design choices.

**Axiom 1: prefer short, flat, fast, and obvious.** Complex memory systems can produce
impressive individual recalls but become fragile over time. Brain keeps consistency
best-effort and harmless on failure.

Hard guarantees come only from mechanical rules such as database constraints and
structural isolation. They do not depend on a model behaving perfectly.

**Axiom 2: use an ontology philosophically, but keep the implementation direct.** The
world contains entities and relations. Brain represents that with one entry `type`,
one relation table, and attributed body blocks.

**Axiom 3: defend explicitly against ghost memory.** Ghost memory is a stale fact that
a long-running agent repeats as if it were current. It comes from searchable old
versions and from presenting old chat as current truth.

Brain keeps only the current searchable knowledge version, encourages dates in factual
prose, and teaches one operating rule: open an entry for current state; search chat for
original words.

**Axiom 4: human oversight is mandatory and retrospective.** Agent edits take effect
immediately. There is no approval queue. People can inspect everything, edit directly,
and run a review when they choose.

This accepts a bounded period in which a bad edit may be live. Requiring approval for
every write would consume attention, block long work, and eventually become blind
rubber-stamping.

**Axiom 5: wrong memory is worse than low recall.** Missing context can be recovered by
asking or searching again. Incorrect context is likely to be used confidently.

Generated summaries are navigation aids, never returned as factual ground truth.
Every conclusion must be traceable to original evidence.

---

## 4. The Three Memory Layers

| Layer | Question answered | Storage | Lifecycle |
| --- | --- | --- | --- |
| **Chat** | What happened, and who said what when? | `signal_gateway_entries` plus timeline index `brain_episodes` | Provider mirrors update or disappear with provider facts; episodes append |
| **Knowledge** | What do we currently know about a subject? | Curated `brain_entries` | In-place replacement; only the current version is searchable |
| **Procedural** | What should be remembered when using a skill? | `agent_skill_overlays`, owned by `AIAgent.Library` | Rewritten and compacted in place |

The system prompt states the operating rule explicitly: open an entry for current
state; search chat for original words.

---

## 5. Curated Knowledge Data Model

Relational rows are durable truth. Markdown is a live projection assembled for people
and models. It is not a storage format.

This keeps fields queryable and mutations precise while preserving a document-shaped
read surface.

### 5.1 Entries

One subject has one entry, such as `Kweichow Moutai`, `Project Alpha`, or
`Investment Research Discipline`.

```text
brain_entries
├── id: uuid (UUIDv7, generated by the application)
├── owner_uid: text, FK → principals.uid
├── store_key: text                         -- 'public' or 'dm:<peer_principal_uid>'
├── name: text                              -- unique within owner and store
├── type: text                              -- free-form entity type
├── summary: text                           -- shared by lists, search, and memo pointers
├── aliases: text[]
├── properties: jsonb
├── search_text: text                       -- materialized name+aliases+summary text, entry BM25 target (§7.2)
├── lock_version: integer
├── inserted_at / updated_at: timestamptz
└── UNIQUE(owner_uid, store_key, name)
```

Names are flat. Ambiguity is handled by naming convention, such as
`Zhang Wei (customer)`, rather than by a path hierarchy.

`type` is the minimal ontology. The first use creates a type; there is no type
registry. This matches OKF's decision that `type` is the only required field.

### 5.2 Body Blocks

Entry prose is stored as attributed blocks.

```text
brain_entry_blocks
├── id: uuid (UUIDv7)
├── entry_id: uuid, FK → brain_entries
├── owner_uid: text
├── store_key: text
├── position: integer
├── body: text
├── author_kind: text                       -- human | agent | dreaming
├── author_uid: text, nullable              -- nullable after its Principal is deleted
├── embedding: text, nullable               -- pgvector literal
├── embedding_dimensions: integer, nullable
├── embedding_state: text                   -- pending | synced | failed
├── embedding_error: text, nullable         -- failure reason surfaced by health checks (§11.4)
├── lock_version: integer                   -- block-level optimistic lock for edit/delete (§5.5)
├── inserted_at / updated_at: timestamptz
└── indexes on entry order, scope, author, and embedding state
```

Blocks exist for attribution, not layout. Dreaming output must be filterable with
`author_kind = 'dreaming'` and recoverable by author and time range.

The author is the last editor of a block. Earlier edits live only in the audit log.
Mechanical actions do not author blocks: conversation bootstrap creates an empty entry,
and source withdrawal deletes an existing block. Their audit rows have no actor and use
`metadata.surface` to record the exact cause.
Judgments include attribution and date in prose, for example:

```text
Current assessment (fundamentals agent, 2026-07-12): ...
```

Certainty is expressed in language. Confirmed facts are direct; rumors say
"reportedly" or "unverified"; conditional inferences state their premise. Brain has no
numeric confidence field.

Disagreement is valuable page content. Different agents place attributed judgments
next to one another instead of creating perspective-specific copies.

`owner_uid` and `store_key` deliberately repeat entry scope on every block. BM25 and
vector retrieval query blocks directly and must constrain Principal and store before
ranking, not after taking a global top-k.

The duplication cannot drift because blocks are created under a fixed entry and the
operation set cannot move an entry between stores.

### 5.3 Relations

Relations are first-class subject-predicate-object triples, not facts parsed from prose.

```text
brain_entry_relations
├── id: uuid (UUIDv7)
├── owner_uid: text
├── store_key: text
├── source_entry_id: uuid, FK → brain_entries
├── predicate: text
├── target_entry_id: uuid, FK → brain_entries
├── inserted_at: timestamptz
├── UNIQUE(source_entry_id, predicate, target_entry_id)
└── INDEX(target_entry_id)
```

Entries and relations form the vertex and edge tables required by PostgreSQL SQL/PGQ.
Before PGQ is available, bounded recursive CTEs handle the few required multi-hop
queries.

Predicates are free text. A registry is justified only after a predicate recurs and
needs structured constraints.

A DM entry may point to an entry in the public store. A public entry may never point
to a DM entry. The database enforces this direction.

`[[Entry Name]]` in prose is navigation, not a formal relation. The projection renders
formal relations from the relation table and computes backlinks live.

If prose and relation rows disagree, both remain visible. The inconsistency is then
inspectable instead of being silently resolved by a parser.

### 5.4 Provenance: Quote the Evidence

Every conclusion must lead back to original evidence. Provenance is a writing
convention rather than a dependency graph.

```markdown
The manager asked us to avoid highly leveraged property stocks
("Avoid highly leveraged property stocks where possible" — Zhang, 2026-06-28,
src:signal-gateway-entry:Qm3xVd…)
```

A citation contains a relevant quote, speaker, date, and source identifier. For chat,
the identifier is the globally unique `signal_gateway_entries.document_id` used by the
chat BM25 index.

The mirror's database key is `(channel_id, provider_message_id)`. A provider message id
is only unique within a channel, so it cannot be used alone as an address.

Agents pass the document id to `memory_browse` to expand the original and nearby
messages. Console uses the same id as a clickable message address.

The quotation is itself a defense. If the original becomes unreachable, the page
still preserves what was cited and when.

A recalled source has one additional best-effort behavior: blocks containing its
`src:` identifier are deleted, while audit data remains recoverable. Uncited blocks
are preserved.

Web and document sources use a URL or document locator.

Brain does not store entry-to-source dependency rows. Other source changes are handled
during later dreaming or human review. That machinery would serve an immutable version
graph, which Brain deliberately does not have.

### 5.5 Projection and Mutation

`memory_open` assembles one Markdown document: title, type, properties, ordered body
blocks, formal relations, and live backlinks.

Writes use small structured operations rather than whole-page replacement:

- create or delete an entry;
- append, edit, or delete one block;
- add or remove one relation;
- set one property;
- set summary or aliases.

Each audit record has a precise intent. Editing one block costs fewer tokens than
rewriting a page, and independent blocks have a smaller conflict surface.

`lock_version` handles remaining conflicts. A stale mutation fails; the caller reopens
the current projection and retries. There is no lock service or write queue.

Console uses the same contract. Prose uses a text editor, while relations, properties,
and aliases use structured controls.

### 5.6 Current State Plus a Write-Only Audit Log

Brain has no version chain. Entries and blocks update in place, and every searchable
surface exposes only the current state.

Each mutation appends an audit record. Runtime search, recall, injection, and default
views never read audit history.

Audit is a fuse for attribution, accidental deletion recovery, and batch recovery from
a bad dreaming run. It is not a second memory system.

---

## 6. Isolation and Routing

Each Principal has a public store and one DM store per conversation peer.

| Conversation | Reads | Writes |
| --- | --- | --- |
| Group | `public` | `public` |
| DM | `dm:<peer_uid>` plus read-only `public` | only `dm:<peer_uid>` |

Isolation is structural, not policy-driven. A DM conversation has no call path that
writes to the public store. Brain does not add ACLs, visibility fields, or a content
classifier that pretends to detect paraphrased leaks.

All DMs with one peer share one store, so memory survives conversation boundaries.

There is no "private channel" memory category. Group knowledge is public to that
Principal. A confidential group gets a separate agent, whose new Principal naturally
owns an isolated Brain.

AIGateway conversation metadata declares whether a conversation is public or a DM and,
for a DM, identifies the peer Principal. Callers must declare this honestly.

Memory routing follows the declared conversation, not the interface that triggered it.
A future public Workflow triggered from a DM still writes public memory if its own
conversation is declared public.

---

## 7. Read Path

### 7.1 Resident Injection: the Agent Pinned Memo

Every agent has one `type=agent_system_pinned_memo` entry in its public store. It is an
ordinary curated entry whose body supplies the agent's resident brief when a new
conversation starts.

The model does not receive the generic entry projection used by `memory_open`. Snapshot
construction emits only resident body text, falling back to the summary when an entry
has no body. Entry and block IDs, store/type/lock metadata, audit authors, database
timestamps, properties, relations, and backlinks remain control-plane data.

The resident text has a hard budget, default 1,500 tokens. Counting uses the kernel's
fixed o200k estimator, so the budget does not change when the conversation model
changes.

If the memo exceeds the budget, only truncated resident text is injected. Dreaming must
rewrite it back under budget. Review also reports the violation.

Only one entry is resident because every injected token is paid on every conversation.
Every resident item must be self-contained and actionable without retrieval: it states
enough subject or scope, trigger, required behavior, and relevant failure behavior for
the agent to apply it directly. Topic labels, entry names, knowledge/rule pointers,
directories, and counts are not resident information. An instruction to open a
specific entry belongs here only when opening it is itself the required behavior.

Larger or infrequent knowledge remains available through search and open. This keeps
progressive disclosure, but its directory belongs to the retrieval system rather than
the resident prompt.

When a group channel has a channel entry, that entry is injected too. Its stable link
is `properties.channel_id`; a display-name change does not break lookup.

Pinned and channel entries become saved context at conversation start. Writes during
the conversation persist immediately but do not mutate that conversation's system
prompt. The model is told what the saved context is for, that it may not include later
changes, and when freshness or exact provenance justifies retrieval; it is not shown
the storage-oriented "Brain snapshot" envelope.

These surfaces are high-risk because malicious instructions would persist across every
future conversation. Writes therefore pass a best-effort threat scan for prompt
injection and exfiltration patterns.

A hit rejects the mutation with a readable reason. Ordinary entries are not scanned;
they load on demand and are explicitly wrapped as untrusted historical content.

### 7.2 Search

The tool shape is `memory_search(query, layer, channel_scope, ...)`.

`layer` and `channel_scope` are independent axes. `layer` is `chat`, `knowledge`, or
`all` (default). `channel_scope` is `current_channel` (default) or `all_channels`, and
only affects chat hits.

Knowledge store visibility follows Section 6 and does not depend on channel scope.
Results state their layer, and knowledge hits precede original chat hits.

Knowledge search has six steps:

1. **BM25.** `pg_search` indexes entry name, aliases, summary, and body blocks. Chinese
   text uses the built-in `pdb.jieba` tokenizer.
2. **Vector retrieval.** `pgvector` searches block embeddings by cosine distance. The
   embedded text is entry name + type + block body; timestamps are omitted.
3. **RRF.** Kernel combines keyword and vector ranks with deterministic Reciprocal Rank
   Fusion. Chat recall uses the same function.
4. **Time decay.** The fused score is multiplied by exponential decay, enabled by
   default with a 30-day half-life. Raw route scores remain available for diagnosis.
5. **Scope and filters.** Principal and store constraints are inside both retrieval
   queries. Type, `author_kind`, and an optional narrower store filter apply afterward.
6. **Optional rerank.** When enabled in AppConfigure, a configured rerank model reorders
   fused candidates. It is disabled by default.

Keyword retrieval is precise for names, codes, and aliases. Vector retrieval covers
semantic paraphrase, such as asking about overseas expansion when the page says
"internationalization."

The embedding and rerank provider paths already exist in AIGateway and kernel. Brain
reuses them rather than adding another provider layer.

Chat retrieval preserves the existing design in Section 9. Both routes run in parallel.
If one fails, the other returns and `degraded_reasons` names the unavailable route.

Every parallel route batch has one wall-clock deadline. Routes unfinished at that
deadline are stopped and reported in input order. Knowledge runs entry BM25, block
BM25, and vector retrieval as one flat batch rather than nesting task groups.

Brain never silently returns a narrower scope than requested.

One search returns at most 10 hits and about 2,000 tokens by default, stopping at the
first limit reached. Narrow results can be refined with another query.

The full result is wrapped as untrusted historical content. Models must treat it as
evidence, never as instructions.

### 7.3 Tool Surface

| Tool | Purpose | Contract |
| --- | --- | --- |
| `memory_search` | Search | Independent `layer` and `channel_scope`; optional chat time range |
| `memory_open` | Open knowledge | Name, alias, or stable id; returns attributed projection, relations, and backlinks |
| `memory_update` | Mutate knowledge | One structured operation with server-derived owner, store, and author |
| `memory_browse` | Read original chat | Channel/time/cursor browsing and source-id expansion |
| `memory_health_check` | Review diagnostics | Read-only Brain health report |
| `skill_append` / `skill_replace` | Maintain skill notes | Owned by `AIAgent.Library`; rules in Section 8.2 |

In a DM, `memory_open` prefers the peer DM entry when both stores contain the same name.
The caller may explicitly narrow to the public store.

---

## 8. Write Path

Knowledge enters entries through three channels.

1. **Working habit.** The system prompt asks the agent to write explicit preferences,
   corrections, decisions, and durable external facts during normal work.
2. **Pre-compaction inventory.** Before AIGateway compacts context, the agent gets one
   reminder to persist anything important that has not been written yet.
3. **Dreaming.** Background consolidation and inference process new material in batches.

The compaction reminder is one-shot for a history prefix. Once context is compacted,
unwritten knowledge is no longer recoverable from the model context.

External events need no fourth ingestion table. News and announcements can enter as
SignalsGateway channel messages, or an agent can write facts discovered during
research.

Both routes reuse the same mirror, source identifier, and dreaming cursor.

Brain permanently excludes extract-on-every-message pipelines. They pay for material
that may never matter and persist the first extraction error as durable memory.

### 8.1 Two Destinations for Self-Improvement

Lessons go to existing owners:

- general lessons become blocks in the pinned memo or another knowledge entry;
- skill-specific cautions become `agent_skill_overlays` through `skill_append` or
  `skill_replace`.

Brain writes skill overlays but does not own their storage or loading lifecycle.

### 8.2 Rules for Skill Notes

The rules are adapted from EverOS:

1. Choose exactly one of **add**, **revise**, or **do not write**. Compare the new lesson
   with existing notes. At least 60% core-step overlap means revise; lower overlap with
   every note means add; no new information means do not write.
2. Keep the complete overlay near a 2,000-token budget. Replace weaker examples, merge
   repeated steps, and compress prose. Never turn revision into blind append.
3. Write each note as **situation → caution**. The situation is a self-contained
   statement, at most 50 tokens, and acts as the retrieval key.
4. Mark an unverified method as a hypothesis. Promote it only after later evidence and
   rewrite it around the stronger evidence.
5. Dreaming-authored notes end with attribution, for example
   `(dreaming, 2026-07-12)`. This is a text convention, not a schema change.

### 8.3 Triggers

At task completion, preserve a lesson when the task recovered from an error, a person
corrected the agent, or a non-obvious multi-step process succeeded.

Dreaming performs a second pass. It merges repeated lessons and catches experience that
an interrupted or incomplete task failed to summarize.

### 8.4 Boundaries of Self-Improvement

Brain does not:

- create new skills silently;
- build a case database or copy task trajectories;
- track skill usage or auto-archive skills;
- use a model's self-score to promote its own output;
- modify the agent runtime framework.

Self-improvement stops at knowledge and skill notes.

---

## 9. Chat Recall and Dreaming

### 9.1 Chat Recall

The chat layer answers "what happened?" It preserves four capabilities from Memory v1.

**Original-message search.** A `pg_search` BM25 index is keyed by
`signal_gateway_entries.document_id` and searches the canonical `text`,
structured JSONB `author` and `metadata`, and `provider_thread_id` fields
directly. Chinese text fields use `pdb.jieba`; channel-name matching joins the
owning channel instead of copying its name into every entry.

A hit expands two messages before and after the anchor as local context.

**Browsing.** `memory_browse` reads original messages by channel, time range, and cursor.
It is a sorted database query and does not require a model.

**Scope.** Search defaults to the current channel. `channel_scope=all_channels` searches
all channels visible to the Principal.

From a group conversation, that scope excludes every DM channel. From a DM, it includes
visible groups and the current peer DM, but never DMs with other people.

**Episodes.** `brain_episodes` stores generated timeline indexes over chat history. A
model segments a message window into episodes; retrieval hits an episode and then
hydrates original messages.

An episode may claim overlapping message positions. Noise and unfinished topics have
explicit outcomes. Output is mechanically validated, and the cursor advances in the
same transaction as the accepted episode set.

Repeatedly malformed windows can be skipped with an operator-visible error. Episodes
are shared channel assets, so multiple agents in one group do not pay to summarize the
same material again.

An episode is navigation only. Returned facts always come from original messages.
If any source anchor disappears, the episode is omitted instead of becoming a ghost
summary.

Original results include speaker, timestamp, and channel. Episode results carry an
explicit "AI-generated navigation summary" label. Degradation is always reported.

### 9.2 Dreaming: the Only Background Organizer

Episode generation and knowledge consolidation both scan new material by cursor. Two
cursor systems and two schedulers would duplicate work, so dreaming owns both as two
stages with different frequencies.

**Stage A: channel-level episode generation.** This is the episode pipeline described
above. It runs when a channel is quiet for 30 minutes or has 200 unprocessed messages.
Oban uniqueness prevents concurrent work for one channel.

The operator configures a model-owning Principal. Stage A resolves that Principal's
`light` and `embedding` profiles. Missing configuration reports unavailable and does
not advance the cursor.

**Stage B: Principal-level knowledge consolidation.** Stage B runs by default at local
04:30 for enabled Principals. The schedule is configurable and independent from Actor
Runtime daily reset.

An operator may also trigger it manually from Console or the command line.

Stage B reads material after two high-water marks: visible channel messages and
explicitly completed Actor turns. It never treats an arbitrary AIGateway Message row as
one unit of evidence. DM material stays in the matching peer DM store; other material
goes to `public`.

The two material kinds have different authority. A `signal_message` is original source
evidence for claims about people, teams, channels, preferences, decisions, and the
external world. A `task_outcome` is a semantic projection of one completed Actor turn:
the normalized request, final visible reply, and tool names with call/result counts. It
exists only to recover reusable workflow lessons. Provider request metadata, tool
arguments, search queries, tool outputs, call IDs, and intermediate Response items are
not Dreaming evidence, and the task outcome may not support claims about the user or
world.

Stage B performs four jobs.

1. **Merge and update.** New evidence is incorporated into relevant entries. Obsolete
   prose is rewritten, not appended beside its replacement.
2. **Handle contradictions.** A resolvable contradiction is corrected. An unresolved
   one remains explicit, such as "the filing says X; the manager said Y on July 10 —
   unresolved."
3. **Induce patterns.** Cross-message and cross-time conclusions become attributed
   blocks with dates and source ids. A valid pattern needs multiple pieces of evidence.
4. **Maintain navigation.** Stage B compacts the pinned memo into self-contained
   resident rules, merges skill notes, and refreshes summaries or aliases made stale
   by body edits.

Induction also covers the agent's work process. A task has one immediate chance to save
a lesson and one later dreaming pass to catch a missed correction or recovery.

Stage B follows these constraints:

- It runs only when a visible signal or completed Actor turn is new. Dreaming traces do
  not have an Actor-turn completion fence and do not count as task input.
- It reads Stage A episodes first, then hydrates original evidence only for topics worth
  processing.
- It opens complete entry state, including relations and backlinks, but gives the model
  only semantic content and opaque edit handles. Store routing, audit fields, database
  timestamps, hashes, and lock versions remain server-side; the server attaches current
  concurrency fences after model output.
- Before writing a `src:` citation, it rechecks that the mirror row still exists and
  that its `content_hash` is unchanged.
- It resolves the model-owning Principal's `heavy` profile.
- Stage A, the Stage B locator, and the Stage B curator declare their JSON envelopes
  through AIGateway structured output rather than prompt examples. Fixed outputs use
  strict schemas; the curator's dynamic operation values remain subject to the same
  server-side operation and domain validation before any write.
- Each curator call already owns one server-selected store, so its output contains only
  `operations` and `skill_updates`; the model never echoes a store key. Enabled skills
  expose only name, description, and current overlay, while overlay hashes remain
  server-side for compare-and-swap.
- Model-facing evidence timestamps use the configured local timezone. UTC instants and
  cursor ordering remain server-side.
- Each run has limits for material, model tokens, and mutations. The defaults are 240
  material items, unlimited tokens, and unlimited mutations; zero means unlimited.
- Every output is attributed to `dreaming` and can be filtered or recovered by author
  and time range.

Stage B is enabled per Principal. Agents default to enabled; humans default to disabled
because humans do not currently have the agent knowledge-consumption surface.

---

## 10. The Self-Improvement Loop

Brain maps to the ACE framework: Generator, Reflector, and Curator operate over an
editable playbook, while evaluation remains outside the loop.

| ACE role | Ankole counterpart |
| --- | --- |
| Generator | Normal work; trajectories already persist in AIGateway |
| Reflector | Immediate task summary and Stage B dreaming |
| Curator playbook | Knowledge entries and skill notes, changed through small operations |
| Evaluator outside the loop | People, audit recovery, and `AIAgent.Library` lifecycle |

The final row is the safety boundary. A self-improvement loop optimizes the signals it
receives. If evaluation or permission becomes part of the loop, the loop can learn to
game it.

People and audit history therefore remain outside Brain's automatic improvement path.

---

## 11. Human Oversight

Oversight is retrospective. Brain has no approval flow or confirmation queue. People
have three working surfaces plus audit history.

### 11.1 Inspect at Any Time

People can search and open entries through Console or by asking an agent in a
conversation.

### 11.2 Console Editing

The Console knowledge surface is a wiki editor over relational truth.

The list filters by type, update time, and author. Entry details show attributed blocks,
formal relations, and clickable source ids. Prose uses text editing; relations and
properties use structured controls.

Human and agent mutations use the same operation path. They differ only by attribution.

### 11.3 Audit Log

```text
brain_audit_log
├── id: uuid (UUIDv7)
├── owner_uid / store_key
├── actor_kind / actor_uid                  -- human | agent | dreaming; both nullable for mechanical actions
├── action: text
├── entry_id / block_id / relation_id
├── before / after: jsonb
├── metadata: jsonb                         -- required causal surface plus batch keys; dreaming's per-run run_id locates one night's changes for batch recovery
└── inserted_at: timestamptz
```

`action` uses the same vocabulary as the mutation surface: `create_entry`,
`delete_entry`, `append_block`, `edit_block`, `delete_block`, `set_property`,
`add_relation`, `remove_relation`, `set_summary`, and `set_aliases`.

The audit log is append-only and absent from runtime reads. It exists for attribution,
single-change restore, and batch recovery. Actorless mechanical rows remain explicit:
`conversation_snapshot` identifies empty pinned-entry bootstrap and `source_withdrawal`
identifies exact-source deletion.

### 11.4 Brain Review Skill

`brain-review` runs only when a person explicitly asks to review memory.

It covers curated knowledge, the pinned memo, and skill notes. The interview begins
with read-only health checks:

- isolated entries with no relation or prose reference;
- projections longer than 200 lines;
- entries older than the latest related chat evidence by more than 90 days;
- a pinned memo over its injection budget;
- blocks whose `embedding_state` is `failed`.

The agent also surfaces unresolved contradictions, dreaming-authored inference blocks,
and possibly stale skill notes.

The person decides in ordinary language. The agent applies those decisions as normal
entry mutations, and the person's statement remains available as source chat.

Review has no fixed calendar. Milestones, not elapsed time, are the useful trigger.

---

## 12. Kernel and Configuration

### 12.1 Kernel

Kernel adds one RRF function. It accepts ranked identifier lists and returns the fused
order. It is pure in-memory computation.

Brain reuses `universal_ai_client` embedding providers for OpenAI, OpenRouter, Jina,
and Google, plus rerank adapters for OpenRouter and Jina.

The ownership boundary does not change: kernel never reads PostgreSQL.

### 12.2 AppConfigure

| Key | Content |
| --- | --- |
| `brain.knowledge` | Pinned memo budget, default 1,500 o200k tokens; search result limit, default 10 |
| `brain.dreaming` | Stage B enablement and schedule, model owner, Stage A triggers, and material/token/mutation budgets |
| `brain.search` | Decay half-life, default 30 days; optional rerank settings, disabled by default |

Model selection always resolves through `ModelProfiles`. Brain settings never name an
upstream provider directly.

---

## 13. Acceptance

Acceptance is a small real-model end-to-end suite, run separately from the default fast
test path:

```bash
tools/e2e/run --brain-real-llm
```

The suite tag is `brain_real_llm`; `tools/e2e/run --all` does not include it implicitly.

Fake Feishu replaces only the difficult-to-automate human client. The path still uses
the Lark adapter, SignalsGateway, ActorRuntime, a Docker Agent Computer worker,
OpenRouter, Brain RPC, PostgreSQL, and the provider outbox.

Assertions inspect the tool journal, current relation state, audit recovery data, and a
succeeded outbox. They do not snapshot prompt wording.

| # | Scenario | Promise verified |
| --- | --- | --- |
| 1 | Preference changes from barbecue to vegetarian; later recall exposes only the current preference | Replacement prevents ghost memory |
| 2 | A rumor is marked unverified, then an official announcement replaces it with a citation | Facts, rumors, and inference stay distinguishable |
| 3 | DM knowledge is absent from group recall; DM can read public knowledge | Isolation is structural |
| 4 | Dreaming consolidates repeated evidence; a second run with no new material writes nothing | Attribution and self-output exclusion |
| 5 | Review surfaces stale or conflicting content and applies a person's spoken decision | Human oversight closes the loop |
| 6 | A human correction becomes a skill note visible on the next skill load | Procedural self-improvement |
| 7 | Recalling a cited message deletes matching blocks, preserves uncited blocks, and leaves recoverable audit | Best-effort source withdrawal |

Research benchmarks and Honcho comparisons are separate future work.

---

## 14. Explicit Non-Goals

| Non-goal | Reason |
| --- | --- |
| Searchable version chains | Old searchable versions create ghost memory; audit is recovery, not history browsing |
| Approval flows or proposal queues | Oversight is retrospective and human attention is limited |
| Brain ACL or visibility model | Structural public/DM stores provide the chosen boundary |
| Source dependency rows | Quoted evidence stays readable; withdrawal uses `src:` matching |
| Structured claim table | Claims live in attributed prose; structured relations already have a table |
| Numeric confidence | Certainty is expressed in language, without undefined 0.x semantics |
| Observer-specific perspective copies | Attributed disagreement belongs on one page |
| Case database or trajectory copies | Trajectories already live in AIGateway |
| Forecast scoring ledger | Future evaluation can use original AIGateway trajectories |
| Skill usage counts or automatic archival | This belongs to future `AIAgent.Library` work |
| Extract knowledge from every incoming message | It pays continuously and persists first-pass errors |
| Separate external-event ingestion table | Channels and agent research already use one source mirror and cursor model |
| Entity-type or predicate registry | Add constraints only after recurring query needs justify them |
| A second durable store outside PostgreSQL | PostgreSQL is the installation's durable truth |
| Silent skill creation or runtime self-modification | Self-improvement ends at knowledge and skill notes |
| Cross-installation or SaaS tenant semantics | One Ankole Installation is the product boundary |

---

## 15. Decision Record

These decisions are settled. A later review should evaluate consistency inside them
unless an assumption recorded here has changed.

### 15.1 Oversight Is Fully Retrospective

**Question:** Should memory writes require human approval?

**Options:** approve every write; approve only goal and discipline entries; or let all
writes take effect immediately and review them later.

**Decision:** all writes are retrospective-review writes.

**Reason:** approval consumes attention and blocks long-running work. Repeated requests
eventually become blind approval and remove the substance of oversight.

**Accepted cost:** an incorrect edit may remain active until discovered. Visibility,
direct correction, and audit recovery bound that cost.

### 15.2 Keep Only the Current Version

**Question:** Should an edited entry preserve searchable historical versions?

**Options:** an immutable version chain; or in-place replacement plus an audit stream
that runtime never reads.

**Decision:** in-place replacement plus audit.

**Reason:** people use the latest page, and searchable older facts are the direct cause
of ghost memory.

**Accepted cost:** Brain loses a fine-grained history browser. Audit preserves the two
required capabilities: trace and restore.

### 15.3 One Pinned Memo Is the Resident Surface

**Question:** What memory enters every agent conversation automatically?

**Options:** inject nothing; inject a generated directory card; or inject one
agent-maintained pinned memo.

**Decision:** inject one pinned memo under a hard budget.

**Reason:** pure search fails when an agent does not know that a discipline exists.
Critical guidance must be present before action. Generated counts and directory cards
add less value than a short document written for the model.

**Accepted cost:** the memo can become stale or oversized. Dreaming, the hard budget,
and human review maintain it.

### 15.4 Flat Names, Type as a Field, Relations as Rows

**Question:** Should entries use hierarchical paths or flat names?

**Decision:** use flat names, one type field, and first-class relation rows.

**Reason:** a path gives the world one tree, while real subjects belong to many
structures. A company can be in an industry, index, and supply chain at once.

The vertex-plus-edge shape also aligns with SQL/PGQ without a schema migration.

**Accepted cost:** grouping comes from queries rather than free path prefixes.

### 15.5 Relational Storage, Markdown Projection

**Question:** Is Markdown the durable representation or a generated read surface?

**Decision:** normalized rows and JSONB are truth; Markdown is a projection.

**Reason:** parsing structure back out of prose creates another fragile contract.
Dreaming output must be filtered and recovered by author, and relations must be
queryable without interpreting text.

**Accepted cost:** writing becomes a set of structured operations rather than replacing
one file.

### 15.6 Principal Stores Instead of a Permission System

**Question:** How should memory be isolated across agents, people, groups, and DMs?

**Decision:** each Principal owns memory, divided into public and per-peer DM stores.

**Reason:** a visibility validator can catch copied text but cannot catch a paraphrased
leak. Structural routing prevents the forbidden public write path instead of pretending
to understand content.

A confidential group uses a dedicated agent and therefore a dedicated Principal.

**Accepted cost:** agents may duplicate knowledge about the same subject. This matches
the product model that each digital employee has its own brain.

### 15.7 Provenance Is a Quotation Convention

**Question:** Does traceability require a source dependency graph?

**Decision:** quote the evidence and include speaker, date, and source locator in prose.

**Reason:** dependency invalidation belongs to an immutable version architecture. Brain
has only one current version. The quotation remains readable if the source disappears,
and the id opens it while it exists.

**Accepted cost:** most source changes are reconciled later by dreaming or review.
Provider recall retains the narrower best-effort withdrawal behavior.

### 15.8 Dreaming Is Required and Owns Episode Generation

**Question:** Should Brain have a background organizer, and should it be separate from
the existing episode pipeline?

**Decision:** dreaming is required and contains episode generation as Stage A plus
knowledge consolidation as Stage B.

**Reason:** induction, contradiction detection, and lesson extraction require multiple
samples across time. Per-message extraction is both expensive and locally blind.

Two cursor systems over the same messages would duplicate storage and scheduling.
Stage A naturally provides the coarse index used by Stage B.

**Accepted cost:** dreaming is Brain's largest model consumer. New-material gating and
per-run budgets limit it.

### 15.9 Dreaming Writes Attributed Blocks on the Entry

**Question:** Should inferred conclusions live in a separate reasoning store?

**Decision:** write them into the entry and attribute each block to `dreaming`.

**Reason:** a separate store creates two truths, two retrieval paths, and two review
surfaces. Attribution keeps inference visible, filterable, and recoverable beside facts.

**Accepted cost:** one page contains content with different epistemic status. Attribution,
dates, and explicit wording distinguish it.

### 15.10 Hybrid Search Ships in the Initial Design

**Question:** Is BM25 enough, or should Brain ship BM25 plus vector retrieval?

**Decision:** use BM25 and vectors, fuse them with RRF, and make model rerank optional.

**Reason:** Chinese paraphrases often share meaning without words. The closest comparable
curated-memory system, openclaw, also defaults to hybrid retrieval.

Embedding, rerank, and the chat vector pipeline already existed, so this is reuse rather
than a new provider subsystem.

**Accepted cost:** body blocks need an asynchronous embedding pipeline and search has an
additional degradable route.

### 15.11 Deliver the Complete Small System

**Question:** Should this design be staged into partial releases?

**Decision:** deliver the complete design as one coherent feature.

**Reason:** transitional architectures tend to become permanent. This design is already
the reduced complete shape; removing another boundary would make it internally false.

Research benchmarks, skill creation, and skill-usage analytics remain explicitly
separate future projects.

---

## 16. Implementation References

This section records the external implementation ideas behind the less obvious
boundaries. It is evidence for the design, not a requirement to copy another runtime.

The comparison commits used during design were Honcho `0cb0c9ab`, openclaw
`4b33199a65a`, hermes-agent `3a1a3c7e6`, and EverOS `29d555c`.

Reference material falls into four reuse classes:

- prompts, regex patterns, formulas, thresholds, and checklists can be adapted as data;
- pure functions can be translated across languages with behavior-preserving tests;
- PostgreSQL predicates and constraints can be translated into Ecto or SQL;
- filesystem, SQLite, asyncio, or Node mechanics are control-flow references only.

### 16.1 Temporal Decay

The multiplier is:

```text
exp(-ln(2) / half_life_days * age_days)
```

At the default 30-day half-life, a 30-day-old result receives a multiplier of 0.5.
Only the fused score changes; raw BM25 and vector scores remain diagnostic fields.

The reference is openclaw `extensions/memory-core/src/memory/temporal-decay.ts`, applied
by `hybrid.ts`. Brain translates the pure formula and its boundary tests into Elixir.

Openclaw exempts evergreen files. Brain reaches the same intent through `updated_at`:
an entry maintained by dreaming is fresh, while neglected content decays.

### 16.2 Threat Scan Before Resident Writes

The pinned memo and channel entry enter every conversation prompt. A malicious line can
therefore persist until someone removes it.

The reference is hermes-agent `tools/memory_tool.py` plus
`tools/threat_patterns.py`, using its strict scope.

Brain adapts the threat inventory, NFKC normalization, invisible-character checks, and
the 65,536-character scan cap. A minimal Chinese high-signal pattern set supplements
the English source.

The scan remains best-effort. It protects only resident entries and does not pretend to
be a general content-security classifier.

### 16.3 Exclude Dreaming Output from Its Trigger

If Stage B counts its own previous output as new material, every run creates the next
run's trigger. Brain excludes `author_kind='dreaming'` and the dedicated dreaming
conversation prefix.

Honcho's `src/dreamer/dream_scheduler.py` counts direct observations rather than the
dreamer's derived output. Openclaw's `dreaming-repair.ts` detects self-ingested dreaming
corpora. Brain preserves the same invariant in PostgreSQL.

The reference also supports a minimum interval, one in-flight run per key, and advancing
the baseline only after real work commits.

### 16.4 Recheck Sources Before Dreaming Writes

Evidence can be recalled or edited between scan and write. Stage B rehydrates every
cited `document_id` against the current mirror and verifies `content_hash` before
committing a source-bearing block.

Openclaw's `short-term-promotion.ts` uses the same decision shape for file-backed
memory. Brain keeps the recheck behavior but targets PostgreSQL mirror rows.

### 16.5 Skill-Note Rules

EverOS `memory_layer/prompts/en/agent_prompts.py` provides the 60% add/revise threshold,
the roughly 2,000-token whole-overlay budget, hypothesis promotion, and a 50-token task
context key.

Its extractor preselects nearby skills before asking the model to compare them.

Brain deliberately removes EverOS numeric confidence anchors and model-scored automatic
promotion. They conflict with the no-numeric-confidence and external-evaluator decisions.

### 16.6 Review-Time Health Checks

The `llm-wiki` skill in hermes-agent calls this operation lint. Its checklist covers
orphan pages, broken links, stale content, and oversized pages.

Brain adapts only checks that PostgreSQL does not already enforce: isolation,
projection size, 90-day staleness against current chat, pinned-memo budget, and
failed embeddings. Relation endpoints are foreign keys with cascading deletion, so
the file-wiki broken-link check has no relational counterpart. All checks are
read-only.

### 16.7 Additional Reused Assets

- **RRF:** Honcho `src/utils/search.py`, `reciprocal_rank_fusion`, with `k=60`. Brain
  translates the generic pure function into Rust and validates identical ranking.
- **Dreaming rewrite and compaction prompts:** EverOS
  `memory_layer/prompts/zh/profile_prompts.py`. Brain reuses add/update/delete/none,
  evidence dates, deduplication, and compact-over-budget behavior.
- **Induction discipline:** Honcho `src/dreamer/specialists.py`. A pattern needs at
  least two sources, must not restate one fact as a pattern, and must link evidence.
- **Resident budget:** hermes-agent `tools/memory_tool.py` and openclaw
  `memory-budget.ts`. Brain uses a fixed tokenizer rather than model-specific counting.
- **Pre-compaction inventory:** openclaw `flush-plan.ts`. Ankole already had the
  one-shot pre-compaction nudge and changes only its Brain tool wording.
- **Public/DM routing:** `internals/docs/ClaudeTagInspiration.zh.md`, derived from Claude
  Tag's published workspace-memory behavior.
- **Default result count:** EverOS uses 10 for fixed top-k skill selection. Brain chooses
  the same narrow default and retains an explicit hard limit.
- **Stage B material cap:** openclaw limits one sweep to 240 messages. Brain uses 240 as
  the default per-Principal cap.

---

## 17. Current Implementation Mapping

This section maps the design to the current repository. It describes the landed shape,
not a compatibility or migration plan.

### 17.1 Context and Removed Surfaces

`Ankole.Brain` replaces `Ankole.Memory`. Persistent tables are `brain_entries`,
`brain_entry_blocks`, `brain_entry_relations`, `brain_audit_log`, `brain_episodes`, and
`brain_cursors`.

The old `memory_notes` storage, prompt section, context injection, RPC methods, and
configuration key are absent. The pinned memo and channel entries own resident context.

Chat BM25 remains on `signal_gateway_entries`; Brain does not copy original messages.

### 17.2 Conversation Visibility and Store Routing

ActorRuntime creates or continues AIGateway conversations with Brain metadata derived
from channel kind and DM peer Principal.

Brain RPC resolves the conversation and trusts only that durable declaration. Workers
cannot supply owner, store, or author as authority.

The current conversation kinds are group and DM. A future kind must declare whether it
maps to public or DM semantics rather than adding another store model.

### 17.3 Chat Scope

`layer` and `channel_scope` are separate request fields. `current_channel` is the default.
`all_channels` uses `SignalsGateway.visible_channels(principal_uid)`.

Visibility combines human AuthZ membership with the host-owned current binding-membership
facts projected by provider adapters. Provider-specific group metadata is not a Brain
visibility input; SignalsGateway owns the normalized membership shape and the query.

### 17.4 Retrieval

All three production BM25 indexes use the `pg_search` built-in `pdb.jieba` tokenizer:

- `signal_gateway_entries_brain_bm25_index`;
- `brain_entries_bm25_index`;
- `brain_entry_blocks_bm25_index`.

Block embeddings are stored as vector literals with dimensions and state. A model
dimension change does not require a schema migration; retrieval compares only matching
dimensions.

There is no vector index. Curated knowledge is small enough for a scoped sequential
scan. An operator can clear old vectors back to `pending` to regenerate them.

RRF is an existing kernel NIF used by both knowledge and chat recall. Time decay and
optional rerank apply after fusion.

### 17.5 Dreaming and Withdrawal

`brain_cursors` uses `(scope_kind, scope_key)`. Stage A owns channel rows. Stage B owns
Principal rows with separate watermarks for visible mirror messages and completed Actor
turns. The task cursor advances by `(completed_at, actor_event_id)`, including past
completed events that cannot produce a routable task outcome, but never past the first
routable outcome not consumed by the run's material/token prefix.

Dreaming conversations use the `brain.dreaming:` key prefix and do not count as future
material. Entry-side trigger checks also exclude dreaming-authored blocks.

Provider recall deletes the mirror row inside the existing ingress lifecycle transaction
and enqueues source withdrawal with the row's `document_id`.

The withdrawal job removes blocks containing the exact `src:<document_id>` marker and
leaves recoverable audit. Source rehydration covers the scan-to-write race.

AIGateway's existing pre-compaction nudge points the worker at the Brain write tools.

### 17.6 RPC, Worker, and Console

RuntimeFabric registers `memory_search`, `memory_browse`, `memory_open`,
`memory_update`, and `memory_health_check` in the shared RPC contract.

The main agent and subagents receive the same Brain tools. Skill notes use the existing
append and replace overlay RPCs.

Threat scanning is a pure Elixir control-plane module and only guards resident entry
writes. It does not move into kernel.

`Ankole.Brain` is the public control-plane context seam. Human list, open, mutation,
audit, recovery, paging, source-resolution, and supervision projections run through
`Ankole.Brain.Supervision`; Phoenix owns only authorization, parameter translation,
cursor encoding, and HTTP response envelopes. RuntimeFabric narrows read capabilities
through `Brain.Scope` rather than editing scope fields in an adapter.

Console exposes entry listing, detail, operations, source browsing, audit listing,
single and batch restore, health review support, and manual dreaming. OpenAPI-generated
clients use the same HTTP contract.

### 17.7 Configuration Mapping

| Removed key | Current owner |
| --- | --- |
| `memory.notes` | Removed without replacement |
| `memory.recall.enabled` / `model_agent_uid` | `brain.dreaming` |
| `memory.recall.episode_*` | Stage A fields in `brain.dreaming` |
| `memory.recall.default_limit` / `max_limit` | `brain.knowledge` |
| `memory.recall.hot_context_hours` / `hot_context_entries` | `brain.search` |

The seven acceptance stories in Section 13 run through the existing E2E framework. Brain
adds a dedicated suite, not a second testing architecture.
