# BrainV3

Brain is the instance-shared knowledge space. Agents, humans, and background
learning write into one body of pages and claims, and every read applies the
querier's knowledge boundary. Brain replaces per-agent memory files: what one
Agent learns, every authorized Principal can reach.

The Elixir control plane owns all Brain state and logic. A model reaches Brain
only through the AIGateway-hosted `brain` tool, which executes inside the
Response; the Worker holds no Brain state and no Brain tool code.

## Storage

Brain stores its state in PostgreSQL. Every primary key is an application
generated UUIDv7; the database never generates a random UUID for these tables.

| Table | What it stores |
| --- | --- |
| `brain_schema_packs` | One installed schema pack version with its frozen manifest |
| `brain_schema_types` | The instance page-type registry, merged from the installed packs |
| `brain_schema_link_types` | The relation predicate vocabulary |
| `brain_schema_calibration_domains` | Named calibration domains for Take scorecards |
| `brain_sources` | Registered learning Sources and shipped-library projection sets with their revision fingerprints |
| `brain_objects` | One page per slug: type, subtype, title, Markdown body, emotional weight, and optional Brain Source body owner |
| `brain_object_versions` | Append-only page history with author and content hash |
| `brain_chunks` | Retrieval chunks of page bodies, with BM25 text and vector columns |
| `brain_claims` | Atomic assertions: bitemporal Facts and calibratable Takes |
| `brain_timelines` | Dated events attached to entity pages |
| `brain_links` | Typed edges between pages |
| `brain_tags` | Free classification labels on pages |
| `brain_slug_aliases` | Old slugs that still resolve after a rename |
| `brain_object_aliases` | Alternate names that entity resolution matches |
| `brain_take_domain_assignments` | Which calibration domains one Take belongs to |
| `brain_contradictions` | Judged claim pairs with verdict and triage status |
| `brain_schema_suggestions` | Model-proposed vocabulary and type changes waiting for an operator |

Vector search uses `pgvector` `halfvec` HNSW indexes; text search uses
`pg_search` BM25 indexes with a configurable tokenizer; entity matching uses
`pg_trgm`. The BrainV3 migration installs all three extensions.

## Scope and Disclosure

Every claim, timeline row, and Markdown audience block carries one
`audience_scope`:

- `world`: every Principal of the instance.
- `group:<name>`: members of one AuthZ Principal group.
- `principal:<uid>`: one Principal.

Two boundaries apply on every read, in order:

1. **Knowledge boundary.** A querier reaches a row when the row's scope is in
   the querier's accessible scopes (`world`, own principal scope, and current
   group scopes), when the querier authored the row, or when an Agent the
   querier owns authored or holds it — except group-scoped rows, which an
   owner cannot reach through its Agent. `Ankole.Brain.Access` owns this rule
   and applies it as an SQL prefilter plus a row filter.
2. **Disclosure boundary.** A reply that other Principals can see narrows
   further: relaxed mode requires the asker to satisfy the scope, strict mode
   requires every present member to satisfy it. Group-memory disclosure mode
   is an Agent setting.

Writer eligibility mirrors the read rule: a writer can write a scope it can
itself reach; the system writer can write every scope.

`remember` and URL Source registration use the same scope rule. If the model
omits the scope, a private chat uses the asking Principal, a member-backed
group chat uses its Principal group, and other turns use the Agent Principal.
If the model selects a scope explicitly, the write keeps that scope after the
writer eligibility check. `ConfidentialityPolicy.md` guides this selection.

Page bodies carry scopes inline as `audience` tags in Markdoc tag syntax.
The normative grammar — CommonMark plus one root-level `audience` tag plus
`[[slug]]` wikilinks — is owned by the native kernel and specified in
[`BrainMarkdoc.md`](BrainMarkdoc.md). `Ankole.Brain.Markdoc` delegates to that
kernel parser without a compatibility path. A page render removes the segments
whose scope the querier cannot reach or disclose, and a body that no longer
parses renders empty instead of leaking unfiltered content.

## Pages, Facts, and Takes

A page (`brain_objects`) is the unit of curated knowledge: one slug under a
type-owned prefix (`people/`, `companies/`, `concepts/`, ...), a Markdown
body, and append-only versions. Concurrent edits use an expected content
hash; a mismatch rejects the write.

Shipped knowledge files project through `library` Sources. The file remains
authoritative while `managed_by_source_id` is set, so an operator can attach
claims and links but cannot edit the projected page body. An instance-owned
page at the same slug shadows the file. Forking an ordinary managed knowledge
page makes it an instance page. Removing a shipped set soft-deletes its managed
pages and keeps their instance-owned periphery so the same set can restore in
place.

A shipped Skill can declare `brain-recall-only: true`. It remains one standard
Skill with its global Skill name, but it is absent from the model-visible Skill
catalog. The library sweep projects only its name, description, and tags into
a world-visible managed Object of type `agent-skills` at
`lazyload-agent-skills/<skill-name>`; the full `SKILL.md`, resources, and Agent
lesson remain in the Skill loader. The `agent-skills` type and slug prefix are
reserved for this projection. An Agent's current effective Plugin and Skill
settings filter these records before retrieval limits and name resolution.
Disabling a Skill prevents discovery and loading without deleting its global
projection; removing the shipped file or the metadata declaration withdraws
the projection.

A claim is one atomic assertion attached to a page or a signal channel.
`claim_type` separates two families with disjoint field sets, enforced by a
database check:

- **Facts** are bitemporal: `valid_from`, optional `valid_until`, a closed
  kind list (`event`, `preference`, `commitment`, `belief`, `fact`), a
  notability level, and a confidence on a 0.05 grid. A change inserts a new
  row and connects the old one through `superseded_by`; expiry keeps history.
- **Takes** are predictions and judgments: an open kind string, a weight on
  the same grid, and a resolution lifecycle (`graded_*`, `resolved_*`) that
  feeds calibration.

Fact writes run semantic dedup inside the same parent, holder, and audience
scope: the top cosine neighbor at or above 0.95 merges as a duplicate or
supersedes when the text changed. Takes never enter dedup.

Internal terminal claims (extraction watermarks) use the provenance prefix
`ankole-brain-internal:`; every recall, BM25, and vector path excludes them.

## Schema Packs and Vocabulary

A schema pack seeds the instance ontology: page types with slug prefixes and
extractability, link types, and calibration domains. Setup installs the
`general` base pack plus the selected industry packs; installation
materializes the manifests into the `brain_schema_*` tables, which are
authoritative afterwards. Packs merge by name: a type registered by an
earlier install keeps its row, and a later pack can only widen subtype
suggestions. Conflicting declarations fail the install.

Admission of a new free-text name follows one rule: installed schema types
and subtypes always win, then the global vocabulary file
(`app/library/schema-pack/vocabulary.yml`) supplies preferred terms for the
free naming surfaces (subtype and tag). An agent consults the vocabulary
before it invents a new name; the Dreaming `schema_suggest` phase proposes
promotions for recurring unregistered terms, and an operator decides them in
the Console. `Ankole.Brain.Promotion` applies an approved suggestion under a
row lock, and only a pending suggestion is decidable.

## Retrieval

`recall` fuses two candidate routes over the querier-reachable rows. For an
Agent, current lazy-Skill visibility is part of the base query, before either
route takes its candidate limit:

1. BM25 over claim text and chunk text.
2. Vector search over `halfvec` embeddings: an HNSW scan on the first 4000
   dimensions selects candidates, the full vector orders them exactly.

The Rust kernel's reciprocal-rank fusion combines the routes and returns real
additive scores: an id both routes found carries the sum of both
contributions. The fused score then multiplies through the ranking factors:

- Facts: effective confidence under time decay,
  `confidence * exp(-age / halflife)`, with per-kind halflives from
  `brain.forgetting`. Takes use their weight.
- Chunks: a graph adjacency boost for pages linked to at least two hits,
  recency from the page's effective date, and salience from emotional weight
  and take density.
- An optional cross-encoder rerank over the fused chunk candidates when
  `brain.rerank_model` is configured; a timeout keeps the fusion order.

`context_pack` assembles the ambient injection for a turn: cards for the
resolved entities and channel, current facts first, under a fixed budget.

## Tools

`Ankole.Brain.Tools` is the model-facing catalog and executor. AIGateway
declares it as the hosted `brain` tool and executes each call inside the
Response as the request subject: an Agent Turn, a codex Job, or an OIDC Human.
The subject is the querier; a Turn's conversation supplies the disclosure
recipients and the default write scope. A Job and a workflow task get the
read-only subset `recall` and `get_page`.

| Operation | What it does |
| --- | --- |
| `remember` | Writes one Fact or Take through the shared write contract |
| `learn_source` | Registers one web URL Source and starts a background learning run |
| `recall` | Fused retrieval over reachable claims and chunks |
| `get_page` | Renders one page; a lazy Skill record comes back with the hint to load it with `skill_view` |
| `forget` | Expires or retracts a claim; soft-deletes a page |
| `entity` | Resolves a name to a page through aliases; ambiguity returns candidates |
| `whoknows` | Reports which Principals' scopes hold knowledge on a topic |
| `synthesize` | Writes an analysis page from reachable knowledge, at the caller's eligibility |
| `delta` | Reports knowledge changes since a cursor |

`context_pack` and `volunteer_pointers` serve the memory injection of a
stateful Response rather than the model. `docs/design-docs/AIGateway.md`
describes the declaration, the public items, and the injection.

## Learning

Two background paths write memory without a `remember` call:

- **Signals learning** extracts durable claims from finished signal-channel
  conversation slices. A channel batch enters extraction after
  `brain.signal_channel_batch_idle_time` seconds of silence or at
  conversation end. Extraction runs before the commit transaction; the
  commit writes claims, entity links, and the extraction watermark terminal
  in one transaction, so a replay of the same slice fails its commit instead
  of double-writing. Before the model call, exact alias matching collects
  the stored pages the slice already names, and the prompt lists them with
  the rule to reuse their slugs — write-time dedup of named entities, since
  neither slug idempotency nor vector similarity recognizes the same entity
  under a second wording. Source learning does not carry this list: its
  extraction produces no entity slugs.
- **Source learning** keeps one `media` page per registered `file` or `url`
  Source. A run fetches the content, compares the fingerprint, extracts
  claims from every content window, and commits object, claim, and revision
  changes in one transaction under a Source row lock. Relearning expires the
  previous revision's facts in the same transaction. An extraction whose
  items all fail write validation rolls the run back whole: the fingerprint
  does not advance, so the run retries instead of recording an empty
  replacement as done. `url` Sources first use the Brain maintainer Agent's
  `web_fetch` profile. If that profile is absent or its provider request
  fails, the Worker uses its supervised `ankole-browser` runtime. `file`
  Sources accept UTF-8 text only.

Extraction quality is a prompt contract: one independently changeable
assertion per item, confidence on the grid, first-person conviction caps.
The server enforces only the mechanical gates.

## Dreaming and Self-Healing

Dreaming is the instance maintenance round, scheduled by
`brain.dreaming_task_cron`. Phases run in order and one failing phase is
recorded without blocking the rest:

1. `consolidate` — promotes dense fact buckets into curated page text.
2. `patterns` — writes cross-page pattern notes.
3. `extract_links` — materializes typed links from page text.
4. `emotional_weight` — recomputes page salience inputs.
5. `grade_takes` — grades expired or stale Takes against page evidence
   (`Ankole.Brain.Calibration`).
6. `calibration_profile` — writes each holder's Brier scorecard into the
   fenced calibration section of the holder page (`Ankole.Brain.Calibration`
   owns the Brier formula; the expert directory reads the same function).
7. `contradictions` — judges newest claim pairs once per pair; confident
   contradictions open triage rows, everything else lands dismissed. An
   operator decision (`resolved` or `dismissed`) applies only to an open row,
   under a row lock.
8. `schema_suggest` — proposes vocabulary and type promotions.
9. `merge_suggest` — the mechanical backstop behind write-time entity
   dedup: pairs live pages of one type that share a normalized alias or
   carry near-identical titles into `brain_merge_suggestions`, one row per
   pair forever. Nothing merges automatically; a Console approval merges
   the pair in one transaction (claims, holders, timelines, tags, aliases,
   and links repoint, the duplicate becomes a slug redirect), and canonical
   Principal pages, library pages, media-primitive pages, and duplicates
   with a written body are refused.
10. `purge` — hard-deletes soft-deleted pages past the TTL.
11. `skill_lessons` — see `docs/design-docs/SkillLessons.md`.

Self-healing runs on its own cron: it embeds pending rows, repairs missing
projections, and reports drift. Time decay itself stores nothing: ranking
recomputes effective confidence on read, and `brain.forgetting` holds the
halflives.

## Configuration

Operator settings live under declared `brain.*` AppConfigure keys: `enabled`,
`maintainer_agent_uid`, the instance-wide `embedding_model` with dimensions,
the instance-wide `rerank_model`, `search_tokenizer`, `chunking`, `forgetting`,
the two cron expressions, `signal_channel_batch_idle_time`,
`skill_learning_enabled`, and `skill_learning_reflection_threshold`.

The selected maintainer Agent supplies `light` for Signals and Source
extraction, `heavy` for Dreaming, and `web_fetch` for URL Source learning. The
Brain settings editor selects the Agent and links to that Agent's model profile
editor; it does not duplicate those three profile controls. Embedding and
rerank stay in the Brain editor because they belong to the instance knowledge
space, not one Agent's model loop. All Brain model calls, including embedding
and rerank, execute as the selected Agent and attribute usage to that Agent.
The selected Agent must be active. Disabling it makes Brain unhealthy and
stops all model calls and local URL fetching until the Agent is enabled or
replaced. Stored knowledge and pure-text recall remain available during that
state.

## Console

The Console `Brain` area gives operators: object browsing with version
history and rollback, claim listing with take resolution, source management
(register, learn, archive), contradiction triage, schema suggestion
decisions, duplicate-page merge decisions, per-principal knowledge audit,
search preview as any Principal, and health counters. The implementation in
[`BrainMarkdoc.md`](BrainMarkdoc.md) includes a full-page Object source editor
with segment preview, diagnostics, and server-authoritative save validation.
