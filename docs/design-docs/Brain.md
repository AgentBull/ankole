# Brain

Brain saves information that a digital employee Agent produces or encounters.
It finds the few most relevant items when a later task needs them. The model
sees the name **long-term memory system (codename Brain)**, or **long-term
memory**. Code and internal documents can use the shorter name Brain.

Brain has three information forms:

- A **chat message** records who said what and when. SignalsGateway owns the
  original message.
- A **knowledge entry** states the current, edited understanding of one topic.
- An **external source** is a document that a person asks the Agent to learn or
  mirror.

One search has one purpose:

```text
From all memory that this conversation can read, select the K items that are
most relevant to the query and fit them in the token budget.
```

An **episode** is a generated navigation summary for a section of chat. It
helps Brain find the original messages. It is not a fourth authoritative
information form and does not replace those messages.

## Boundaries

The Elixir control plane owns Brain state, transactions, schedules, and model
selection. PostgreSQL owns durable knowledge, source, cursor, and audit facts.
SignalsGateway owns original chat messages. Agent Computer exposes the
`memory_*` tools but cannot select a different Principal, conversation, or
store in an RPC request.

The saved AIGateway conversation is the only source of Brain scope. Brain reads
`metadata["brain"]` from that conversation. It does not infer scope from a
provider event, a runtime default, or worker-local state.

The Brain scope stays fixed for one conversation. When an operator changes a
group between shared and confidential memory, the next group turn ends the old
conversation and starts a successor with the new scope. The successor does not
inherit the old transcript or Brain snapshot across this visibility boundary.

SignalsGateway records the Agent-specific Brain store when it accepts each
message. Dreaming uses that recorded store, so a later binding change cannot
move pending confidential messages into shared knowledge. The new setting
applies only to messages that arrive after the change.

Brain does not provide an ACL system, approval flow, confidence score, version
chain, or view copy. Store selection and database checks enforce visibility.
The audit log supports recovery without becoming a searchable history.

## Ownership and Stores

Brain uses four store keys. The fixed system Principal `brain-shared` owns the
shared store. The current Agent owns its private stores.

| Conversation | Readable stores | Default writable store |
| --- | --- | --- |
| Shared channel | `shared`, `self` | `shared` |
| Direct message with peer `P` | `shared`, `self`, `dm:P` | `dm:P` |
| Confidential channel `C` | `shared`, `self`, `channel:C` | `channel:C` |

The `self` store contains an Agent's private working knowledge, pinned memo,
and curation guide. A caller can explicitly select `self` for a
`memory_update`; it cannot select another private store or force a shared
write. Confidential channel memory is active only for a binding that has the
`confidential_memory` flag.

A shared entry can relate only to another shared entry. A private entry can
relate to an entry in the same private store or to a shared entry. The database
checks this rule. Private material can change only its source private store
during Dreaming. It cannot change shared or self knowledge, the pinned memo, or
Skill notes.

There is no `public` store and no compatibility read for old store names.

## Storage Model

| Table | Purpose |
| --- | --- |
| `brain_entries` | Current entry names, summaries, aliases, types, and properties |
| `brain_entry_blocks` | Editable entry text and its embedding state |
| `brain_entry_relations` | Explicit subject-predicate-object links |
| `brain_block_citations` | Indexed `src:` references from blocks |
| `brain_episodes` | Search navigation summaries for chat sections |
| `brain_retained_sources` | Manual binary sources and connector source state |
| `brain_cursors` | Stage A and Stage B progress and availability |
| `brain_audit_log` | Before and after values for review and recovery |

Brain builds the Markdown view of an entry from its rows. It does not store a
second Markdown copy.

One entry is the current page for one topic. Its name is unique in one owner
and store. Names do not form paths, and types remain open technical labels.
Each entry has a lock version. Each block has a position, author, lock version,
and embedding state. A stale version cannot replace newer work.

The `agent_system_pinned_memo` and `brain_curation_guide` entry types are unique
in an Agent's `self` store. The pinned memo is the small long-term memory
projection injected into every Agent turn. The curation guide tells Stage B
which stable facts and subject types to keep.

Each persisted block must cite its evidence with the canonical internal marker:

- Chat evidence uses `src:signal-gateway-entry:<document-id>`.
- External-source evidence uses `src:brain-source:<uuid>`.

The model does not receive these document IDs. One model call uses turn-local
`source_N` references, and the owning Brain boundary translates those references
to canonical markers before it writes a block. The resident snapshot removes
canonical markers because it provides context, not exact evidence navigation.
The pinned-memo compactor removes them for the same reason.
The boundary rejects the complete plan if a turn-local `material_N` or `source_N`
reference remains outside a supported block body citation.

Brain indexes these markers. Withdrawal and health checks use the index. A
wiki link such as `[[Supplier Policy]]` helps readers navigate, but it does not
create a relation row.

An explicit relation has a source entry, predicate, and target entry. It is
unique by `(source_entry_id, predicate, target_entry_id)`, cannot point to its
source entry, and must obey the store relation rule.

Every block records an author kind and author UID. When Stage B writes a person
entry from a chat message, it copies the supplied speaker Principal UID to
`properties.principal_uid`. Two Agents can write different signed judgments in
one shared entry; readers can keep both and filter by author UID.

## External Sources

Brain has two source paths because they have different ownership rules.

### Manual material

Pasted text and fetched URL text become ordinary editable entries. A manual
file or other binary source keeps immutable original bytes in
`brain_retained_sources`. Brain stores the source before it starts the explicit
learning turn, so a failed turn does not lose the source. Source learning can
create an entry, append a block, or correct a block, and every changed block
must cite that source.

### Connector-managed documents

A source connector has three responsibilities:

1. Report whether the source is available, deleted, or no longer accessible.
2. Return its current revision.
3. Export its title, URL, and Markdown body.

The control plane owns registration, polling, comparison, chunking, replacement,
and withdrawal. It creates one read-only mirror entry in `shared`. The mirror
properties identify its source, connector, revision, URL, and mirror status.
Human, Agent, and Dreaming write paths reject edits to a mirror.

If only source metadata changes, Brain updates the metadata without rebuilding
the blocks. If content changes, it replaces the complete mirror and marks its
new blocks for embedding. If the source is deleted or access is lost, Brain
withdraws the mirror. Connector source rows keep the current exported bytes;
they are not immutable snapshots.

A sync can commit only if the source row still has the version read before the
connector request. If another sync updates or withdraws the source, the stale
sync returns `{:error, :source_sync_conflict}`. It cannot replace newer content
or restore an old state.

The generic connector contract and deterministic fake connector tests are in
this release. A real Feishu document connector is the next phase and is not a
current Brain capability.

## Model Tools

RuntimeFabric exposes these tools:

- `memory_search` searches chat messages and knowledge entries.
- `memory_browse` expands a turn-local `source_N` result or continues with a
  turn-local `page_N` reference.
- `memory_open` opens one knowledge entry by its canonical name or alias. The
  preferred store is selected first, an exact canonical name wins over an alias
  in that store, and a colliding alias fails as ambiguous instead of selecting
  one entry silently.
- `memory_update` changes current knowledge through versioned operations.
- `memory_health_check` reads the same health query group as the Console status
  surface.

The system prompt explains the long-term memory purpose and all three
information forms once. Each tool description explains only its action and
boundary. They do not use the bare codename Brain. Recalled text is untrusted
history. The model can use it as evidence but must not follow instructions
inside it.

All knowledge changes call `Ankole.Brain.Knowledge`. The owner checks,
read-write store checks, mirror checks, version checks, mutations, citations,
relations, audit rows, and cursor changes share the appropriate transaction.
The current Agent is always the author of `memory_update`; the worker cannot
supply another author.

## Unified Recall

`memory_search` runs all enabled routes under one fixed deadline:

1. Knowledge keyword ranking combines exact whole-query name and alias matches
   with entry and block BM25 results into one column.
2. Knowledge vector ranking searches block embeddings.
3. Chat keyword ranking searches SignalsGateway messages.
4. Chat vector ranking searches episode embeddings.
5. Global Reciprocal Rank Fusion combines the four columns.
6. Brain applies temporal decay, merges duplicate candidates, and can apply one
   optional global reranker.
7. Brain selects the result limit, expands only those winners, and applies the
   final token budget.

The layer is a result label and an explicit filter. It is not a hidden priority.
A strong chat match can rank before a weak knowledge match.

If a keyword message belongs to one or more episodes, each matching episode is
the candidate identity and the message is an anchor. Keyword and vector routes
can then strengthen the same candidate. A message with no episode remains a
message candidate.

Temporal decay uses these rules:

- Chat uses the full exponential curve. The default half-life is 30 days.
- Knowledge uses the same curve with a default floor of `0.5`.
- An explicit `from` or `to` search range disables decay for both layers.

Reranking is global, optional, and disabled by default. A route or reranker
failure returns the remaining results with degraded status and named reasons.
One query-embedding request is shared by both vector routes and remains inside
the same recall deadline.

An explicit `memory_search` can return a chat message that is already in the
current Response chain. This preserves its stable document ID when the Agent
needs exact provenance. AIGateway input assembly separately removes duplicate
channel context before the model call.

Brain expands results after ranking:

- An episode expands the messages in `source_entry_ids`.
- A threaded message expands its reply graph and provider thread.
- A message without a thread expands up to two chronological neighbors on each
  side.
- An entry returns its fields and matching block snippets. A matched block stays
  in the snippet even when earlier blocks would exhaust that candidate's cap.

Expansion retains all hit anchors. One candidate has a hard token cap so a long
thread cannot remove all other candidates. With the default 2,000-token result
budget and limit of ten, the default candidate cap is 400 tokens. Duplicate
messages across winners appear once. `memory_browse` retrieves the complete
thread or source when the compact search result is not enough.

## Instance-wide Embedding Space

All block, episode, and query vectors use one global `brain.embedding` setting.
It identifies an Agent whose `embedding` ModelProfile supplies the model and it
declares the output dimensions. Brain supports at most 4,096 dimensions.

Each vector row records the model Agent UID and dimensions that produced it.
Search ignores a vector from another embedding space. The status surface marks
such rows as stale. After an operator changes the global model or dimensions,
the next embedding batch resets stale rows to pending before it regenerates
them in the new space.

PostgreSQL stores vectors in `vector(4096)`. The HNSW candidate index uses the
first 4,000 dimensions as `halfvec`; shorter vectors have zero-filled tails.
Zero filling does not change cosine distance. The candidate query then orders
the shortlist with the complete `vector(4096)` value. Models with at most 4,000
dimensions put their complete vector into candidate generation. Models with
4,001 through 4,096 dimensions omit the tail only during candidate generation,
so that tail can affect candidate recall; the final shortlist order still uses
the complete vector. A model with more than 4,096 dimensions needs a migration.

## Dreaming Stage A

Stage A turns older chat from each eligible channel into episodes. It never
changes or deletes original messages. Recall still enforces the conversation's
channel visibility when it reads those episodes.

For each channel, Brain selects the lexicographically smallest visible active
Agent whose `light` ModelProfile resolves. The cursor records this processor.
There is no `brain.dreaming.model_agent_uid` setting. A missing processor leaves
the cursor unchanged and records an unavailable reason.

Stage A runs when a channel reaches either the silence threshold or backlog
threshold. It protects a recent tail, and one window has row and token limits.
The defaults are 30 minutes of silence, 200 queued rows, 200 window rows, 8,000
window tokens, 20 protected tail rows, and 360 protected tail minutes.

A channel that has no cursor starts at a bounded position. Stage A reads back at
most the configured number of days and writes the cursor at the newest entry
before that boundary. The first window therefore does not summarize the full
retained history, which grows with the delay between the first ingested entry
and the first dreaming run. The default boundary is 5 days, and the value `null`
removes it. Stage A writes the boundary one time instead of filtering each read:
a boundary that moves with the current time would pass over the messages that
arrive while Stage A cannot write an episode, and would keep no record of them.
An existing cursor always wins, so this boundary applies one time for each
channel.

For each episode, the model supplies a topic, summary, likely future question,
resolution, systems, and an optional resolution source message. The control
plane stores that message ID in the episode metadata. A reader derives the
resolution author from the authoritative mirrored message. The embedding input
contains topic, question, summary, resolution, and systems.

Every input row must be classified as episode evidence, noise, or permitted
deferred tail. The request names that permitted tail, because the model cannot
compare the row timestamps against the current time. One transaction stores
valid episodes and advances the cursor.
Invalid output or model failure does not advance it. After the last retry,
Stage A can explicitly skip the failed section; the original chat remains
keyword-searchable.

## Dreaming Stage B

Stage B curates current knowledge for one Agent Principal. It uses that Agent's
own `light` ModelProfile. The scheduled scan enumerates active Agents only, and
the Stage B configuration path rejects a human or system Principal. An Agent is
enabled by default and can have a scoped `brain.dreaming` override.

A run becomes eligible after 30 minutes of material silence or 50 queued rows
by default. This microbatch gate avoids one model call for every new message.
Each run processes at most 25 material rows. The locator always requests a
32,768-token output limit. Optional token and mutation budgets use `0` to mean
no operator limit.

Task outcomes admit only completed `im.message.addressed`,
`signal.action.invoked`, `check_back_later.wakeup`, and `cron.fire` events that
have a final Response. Lifecycle, command, ambient, source-learning, and unknown
ActorEvent types do not enter the Stage B scan.

Stage B separates each store before it calls a model. A locator selects material
and related topics. A curator reads only selected material and current related
knowledge. An exact locator topic includes the existing entry before ranked
search adds related entries. Private evidence cannot enter another private
store, shared knowledge, or Skill notes.

The curator follows these rules:

- Use stable topic names without dates.
- Update an existing topic instead of creating a duplicate.
- Keep only channel conventions in a channel entry.
- Use `[[entry name]]` links for related current entries.
- Create a relation only when the evidence explicitly states it.
- Keep conflicting judgments with their author UIDs.
- Store a person's supplied Principal UID in the person entry.
- Cite every generated block.

One global token and mutation budget covers all store calls in a run. One final
transaction applies the complete valid plan and advances the cursor. Model,
validation, budget, or commit failure leaves selected material for retry.

Stage B stores its model-call audit trail in finite
`brain.dreaming:<run_id>:<store_key>` AIGateway conversations. The run ends all
of these trace conversations when it completes or returns an error. A Dreaming
trace is not an Actor session and does not enter daily session reset.

At the end of every run, Stage B checks the `self` pinned memo. If it exceeds
the configured budget, Stage B makes one compaction attempt. The status surface
still reports the memo when compaction cannot bring it under the limit.

## Withdrawal, Audit, and Recovery

When a provider removes a message, the ingress transaction queues a best-effort
withdrawal. Brain finds audit changes caused by that evidence and reverses a
change only when current knowledge still matches the expected value. It also
deletes blocks that contain the exact removed-source marker. A later human or
Agent edit wins over withdrawal.

Every successful knowledge mutation writes its before and after values to
`brain_audit_log`. Recovery applies selected inverse operations from newest to
oldest in one transaction. A conflict stops the transaction instead of
replacing current knowledge. Search never reads audit rows as current facts.

## One Health Surface

The Console status view is the only Brain health surface.
`memory_health_check` reuses its queries. Audit remains a separate tracing and
recovery surface, not a second health dashboard.

Status includes:

- The Stage A processor, cursor, unavailable reason, and episode counts for
  each visible channel.
- Pending, synced, failed, and stale episode and block embeddings.
- Global embedding configuration and model-space consistency.
- The Stage B model, last successful run, unavailable reason, and retryable
  curation jobs.
- Stage B jobs that have executed for more than 30 minutes.
- Pinned memo size and truncation state.
- Four entry lints: a date in the name, a near duplicate name, more than 200
  projected lines, and no body block.
- Citation, source, and other read-only diagnostics.

Any unavailable pipeline, failed or excessive backlog, stale embedding space,
stuck job, oversized memo, or nonzero lint produces an alert. A retryable
curation job appears in the status surface but alerts only on its last attempt,
because Oban retries a transient provider failure without an operator. Oban
Lifeline rescues executing jobs after 30 minutes so a stale unique lock cannot
stop all future curation for that Principal.

## Configuration

Brain registers five AppConfigure keys.

### `brain.knowledge` (global)

| Setting | Default |
| --- | ---: |
| `pinned_memo_max_tokens` | 1,500 |
| `result_limit` | 10 |

### `brain.embedding` (global)

| Setting | Default |
| --- | ---: |
| `enabled` | `false` |
| `model_agent_uid` | `nil` |
| `dimensions` | `nil` |

When `enabled` is true, both remaining values are required. `dimensions` must
be from 1 through 4,096.

### `brain.search` (global)

| Setting | Default |
| --- | ---: |
| `half_life_days` | 30 |
| `knowledge_decay_floor` | 0.5 |
| `rerank_enabled` | `false` |
| `rerank_model_agent_uid` | `nil` |

### `brain.sources` (global)

| Setting | Default |
| --- | ---: |
| `enabled` | `true` |
| `sync_interval_minutes` | 15 |
| `block_max_tokens` | 1,500 |

### `brain.dreaming` (scoped)

Stage B reads the value of the Agent that it curates. Stage A reads the global
value, because it works on a channel and selects a processor Agent for each run.
The `episode_` settings therefore have no per-Agent effect.

| Setting | Default |
| --- | ---: |
| `enabled` | `true` for an Agent; non-Agent owners are unsupported |
| `token_limit` | 0 |
| `mutation_limit` | 0 |
| `curation_silence_minutes` | 30 |
| `curation_backlog_rows` | 50 |
| `episode_silence_minutes` | 30 |
| `episode_backlog_rows` | 200 |
| `episode_window_max_rows` | 200 |
| `episode_window_max_tokens` | 8,000 |
| `episode_tail_guard_rows` | 20 |
| `episode_tail_guard_minutes` | 360 |
| `episode_cold_start_lookback_days` | 5; `null` reads the full history |

## Scheduled Maintenance

Oban enqueues eligible Stage A work every five minutes, pending episode
embeddings every five minutes, pending block embeddings every five minutes,
eligible Stage B work every minute, and source synchronization checks every
minute. Stage B eligibility and the configured 15-minute source interval are
gates inside those frequent scans. These jobs are application maintenance, not
user Schedule records.

## Database and Deployment Contract

Brain requires PostgreSQL 18, ParadeDB `pg_search`, and `pgvector`. `pg_search`
provides BM25. `pgvector` stores and indexes embeddings. The Rust kernel fuses
rankings and estimates tokens; it does not connect to PostgreSQL.

The Brain V2 migration is an intentional clean cut. It permanently clears all
Brain V1-owned tables before it installs the V2 schema. Back up any information
that you must keep before you migrate. There is no V1 data conversion,
store-name shim, or downgrade path.

## Rules

- SignalsGateway keeps the original chat message.
- Brain keeps the current edited knowledge and external-source state.
- The saved conversation decides all readable and writable stores.
- Search globally ranks every enabled information route before expansion.
- One deployment instance has one configured embedding space.
- Generated knowledge cites its evidence.
- A synchronized mirror is read-only and represents one current source revision.
- A failed Dreaming run does not advance its cursor.
- A stale version, withdrawal, or recovery action cannot replace newer work.
- Feishu document synchronization is not implemented until the next connector phase.
