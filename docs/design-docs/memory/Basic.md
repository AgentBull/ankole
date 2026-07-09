# Memory Basic

Memory is Ankole's channel-scoped long-term memory and historical recall
subsystem. It is owned by the control plane, backed by PostgreSQL, and exposed
to workers through RuntimeFabric RPC and a small tool surface.

This document is the public design-doc entrypoint. The detailed v1 design,
research notes, and implementation rationale live in
`internals/docs/Memory.zh.md`.

## Position

Memory exists because Ankole agents work in places, not only in one private
chat. A useful agent must remember stable channel facts and be able to search
past provider-visible conversation history without pretending that generated
summaries are facts.

The core rule is:

```text
Memory belongs to the channel/place where it was observed.
```

For a DM channel, this naturally behaves like per-person memory. For a group
channel, it behaves like shared place memory: team decisions, channel rules,
and long-running project context.

## Ownership

The control plane owns durable memory semantics:

- PostgreSQL tables, migrations, constraints, and search indexes;
- `Ankole.Memory` note CRUD, browse, search, summary, embedding, and cursor
  behavior;
- AppConfigure declarations for `memory.notes` and `memory.recall`;
- Oban jobs for summary and embedding work;
- RuntimeFabric RPC handlers for worker memory tools.

The Bun worker owns only the model-facing tool definitions and turn integration:

- `memory_note`;
- `memory_search`;
- `memory_browse`;
- current-channel note injection into addressed and ambient turns;
- the system prompt guidance that tells the model when to search memory.

The kernel owns the provider-neutral token estimator:

- `Ankole.Kernel.estimate_o200k_base_tokens/1`;
- Rust `o200k_base` counting through `tiktoken-rs`.

Workers must not create process-local memory state that affects PostgreSQL
truth. Reads and writes that affect memory go through the control plane.

## Principles

Memory v1 follows a small set of deliberately conservative rules:

- original provider messages are ground truth;
- LLM episode summaries are navigation indexes, not facts;
- recall is a model-invoked tool, not broad automatic prompt injection;
- current-channel recall is the default path;
- cross-channel recall is explicit and constrained to channels the agent has
  observed;
- BM25 and vector routes degrade independently;
- a bad summary window must not burn model calls forever;
- token budgets use `o200k_base` estimation independent of the selected model
  provider.

## Layer A: Curated Notes

Layer A is small, curated, and injected into the current turn. It is the
Ankole equivalent of a channel-scoped `MEMORY.md`.

Rows live in `memory_notes` and are scoped to:

```text
{agent_uid, signal_channel_id}
```

Limits are part of the contract:

- at most 40 notes per agent/channel;
- at most 500 characters per note;
- when full, `memory_note.save` returns `memory_note_limit_reached`;
- the agent must list, merge, update, or forget notes before saving more.

The `memory_note` tool supports only current-channel scope:

- `save`;
- `update`;
- `forget`;
- `list`.

Notes are injected into both addressed and ambient turn contexts. They are
powerful because they enter the prompt; that is an accepted v1 tradeoff, bounded
by current-channel scope, the small cap, and explicit list/update/forget tools.

Before automatic AIGateway compaction, Ankole may inject a one-time trusted
nudge into the normal agent/tool loop asking the agent to persist durable facts
through `memory_note`. This is intentionally not placed in the internal
summarizer path because that path cannot call tools.

## Layer B: Historical Recall

Layer B searches and browses historical provider-visible messages. Its ground
truth is `signal_gateway_entries`.

Phase 1 has no model dependency:

- ParadeDB BM25 over `signal_gateway_entries`;
- `memory_browse` for exact channel/time transcript browsing.

Before `document_id` is used as ParadeDB BM25 `key_field`, the database must
enforce it as unique. The intended document identity remains derived from:

```text
{signal_channel_id, source_entry_id}
```

Search results must be treated as untrusted historical content. BM25 hits
return the original anchor message plus a small original-message window around
it. Vector hits return the episode as a route marker, but still expand back to
the original source messages. The model must use those original messages as
ground truth.

Current-channel `memory_search` excludes hot context:

- entries from roughly the last 2 hours;
- or the latest 80 observed current-channel entries before the current turn.

That recent material should already be in the active turn context. When exact
recent transcript rows are needed, callers should use `memory_browse` with an
explicit time range.

Cross-channel search only includes channels observed through `actor_events`.
When the current channel is not `im_dm`, cross-channel search excludes `im_dm`
sources to avoid leaking private DM content into a group context.

## Phase 2: Episodes And Embeddings

Phase 2 adds semantic recall:

- `memory_episodes`;
- `memory_channel_cursors`;
- channel summary jobs;
- embedding jobs;
- exact pgvector scan by embedding dimension;
- BM25/vector reciprocal-rank fusion.

Phase 2 is disabled by default. It requires:

```text
memory.recall.enabled = true
memory.recall.model_agent_uid = <agent uid>
```

The configured model owner must exist and have both:

- a `light` profile for summary generation;
- an `embedding` profile for vector generation.

If the configured model owner is missing, deleted, or lacks either profile,
summary and embedding jobs report unavailable and do not advance cursors. The
operator-visible reason is:

```text
memory.recall.model_agent_uid 指向的 agent 无 light/embedding profile
```

Valid episodes are append-only. Embedding text is:

```text
topic <> "\n" <> summary
```

If embedding fails after a valid episode is created, the episode remains durable
with `embedding_state = 'failed'`. Search degrades to BM25 and reports the
vector-route degradation.

Summary windows are gated by silence/backlog thresholds and a young-tail guard.
Deferred entries are allowed only in the protected young tail; aged-out tail
entries must be assigned, marked noise, or otherwise consumed. If LLM output is
invalid through the worker's final retry, the window is skipped, the cursor
advances, and telemetry records the skipped span. BM25 still covers those
messages because the original rows remain in `signal_gateway_entries`.

## Tool Surface

The model-facing tools are intentionally narrow:

- `memory_note` manages current-channel Layer A notes;
- `memory_search` searches historical memory, defaulting to `permitted_context`,
  with `scope = current_channel | permitted_context`, optional time range,
  default limit 5, and max limit 10;
- `memory_browse` browses original transcript rows by channel/time/cursor,
  defaulting to current channel; explicit `channel_id` must be inside the same
  permitted context.

The system prompt includes a Memory Recall section. Before answering questions
about prior work, decisions, dates, people, preferences, or channel history,
the model should call `memory_search`. If recall is unavailable or inconclusive,
it should say so instead of inventing certainty.

## Degradation

Memory should degrade rather than fail the turn:

- `memory.recall` disabled means Phase 2 is unavailable, but Phase 1 BM25 and
  browse remain useful;
- BM25 parser-hostile user queries are normalized before hitting ParadeDB;
- BM25 failure must not prevent vector search from running;
- vector/model failure must not prevent BM25 results from being returned;
- unavailable summary/embedding jobs do not advance cursors;
- valid episodes with failed embeddings stay inspectable and retryable.

The main exception is note writes: Layer A limits are hard. When the note list
is full, the write is rejected until the agent or a human merges, updates, or
forgets existing notes.

## Known V1 Tradeoffs

Layer A notes can create durable prompt pressure because channel participants
can ask the agent to save notes that later enter the system prompt. V1 accepts
that tradeoff and bounds it through scope, small limits, visibility, and
explicit editing tools.

Episode summaries may be wrong. They are deliberately not treated as facts.
They are only used to locate original messages.

Historical recall only covers provider-visible rows mirrored into
`signal_gateway_entries`. If an ingress policy chose not to mirror a message,
memory cannot recover it later.

Memory v1 is not a knowledge graph, profile engine, contradiction resolver, or
fact-extraction system. Those belong to the future Brain layer.
