# BrainV3

Brain is the tenant-shared knowledge space. Agents, humans, and background
learning write into one body of pages and claims, and every read applies the
querier's knowledge boundary. Brain replaces per-agent memory files: what one
Agent learns, every authorized Principal can reach.

The Elixir control plane owns all Brain state and logic. A chat Session
reaches Brain only through the AIGateway-hosted `brain` tool, which executes
inside the Response. A codex Job reaches the read subset through the Worker
read-tool bridge, where `Ankole.Sessions.Tools.Brain` executes each call. The
Worker holds no Brain state and no Brain logic; its Brain tool is the transport
codec for that bridge.

## Storage

Brain stores its state in PostgreSQL. Every primary key is an application
generated UUIDv7; the database never generates a random UUID for these tables.

| Table | What it stores |
| --- | --- |
| `brain_schema_packs` | One installed schema pack version with its frozen manifest |
| `brain_schema_types` | The tenant page-type registry, merged from the installed packs |
| `brain_schema_link_types` | The relation predicate vocabulary |
| `brain_schema_calibration_domains` | Named calibration domains for Take scorecards |
| `brain_sources` | Registered learning Sources and shipped-library projection sets with their revision fingerprints |
| `brain_objects` | One page per slug: type, subtype, title, Markdown body and optional Brain Source body owner |
| `brain_object_versions` | Append-only body, metadata, tag, and author snapshots |
| `brain_chunks` | Retrieval chunks of page bodies, with BM25 text and vector columns |
| `brain_claims` | Atomic assertions: bitemporal Facts and calibratable Takes |
| `brain_timelines` | Dated events attached to entity pages |
| `brain_links` | Typed edges between pages |
| `brain_tags` | Persisted tags attached to tenant pages |
| `brain_schema_suggestions` | Vocabulary promotion evidence and operator decisions |
| `brain_slug_aliases` | Old slugs that still resolve after a rename |
| `brain_object_aliases` | Alternate names that entity resolution matches |
| `brain_take_domain_assignments` | Which calibration domains one Take belongs to |
| `brain_contradictions` | Judged claim pairs with verdict and triage status |

Vector search uses `pgvector` `halfvec` HNSW indexes; text search uses
`pg_search` BM25 indexes with a configurable tokenizer. Entity identity uses
exact slugs, redirects, normalized aliases, then exact titles. Ambiguous
matches return candidates; fuzzy titles do not establish identity.

The tokenizer and embedding model are site settings because BM25 and HNSW
indexes cover the shared physical tables. Rerank is a tenant setting and does
not define an index. Every query still filters by tenant.
Schema packs and library projections are installed separately in each tenant.

Installed relation names and inverse names feed the conversation extraction
prompt. They are preferred vocabulary, not a closed set: other
labels are valid when no installed term fits.

The Console creates and replaces page tags through the Object write
contract. Tags are exact, case-sensitive strings; input trims surrounding
whitespace, rejects blank values, and stores one row per distinct tag. An
omitted `tags` field keeps the current set; `[]` clears it. The content hash
covers the tag set, and each update snapshots the previous tags with the
ObjectVersion author. Merge refreshes that hash after tags move.
The Console draft keeps tags as an array and edits each tag in a separate
field. Embedded line breaks and literal backslashes stay inside that tag.
Version rollback restores only body and meta; it does not restore tags.

`ObjectVersion.snapshot` owns immutable body, metadata, tag, and author snapshots.
It requires the object writer's transaction, so a failed edit cannot
leave history without the corresponding page change. `Ankole.Brain.Chunks`
reconciles positions under the current Object row lock. Its resource actions
create, replace, or remove projection rows; replacement clears the full vector
state. An unchanged position retains its row and vector. Embedding results use
one atomic action that compares the input text, embedding timestamp, and model
signature before it commits. PostgreSQL checks the complete vector state and
rejects partial success or failure records. Embeddings use the Ash `:vector`
type and `AshPostgres.Extensions.Vector` to store 4096 float32 values in the
PostgreSQL `vector(4096)` column.

## Scope and Disclosure

Every claim, timeline row, and Markdown audience block carries one
`audience_scope`:

- `world`: active Human members, Agents, and System Principals of the current
  tenant. Human guests do not receive this scope.
- `group:<name>`: members of one AuthZ Principal group.
- `principal:<uid>`: one Principal.

Two boundaries apply on every read, in order:

1. **Knowledge boundary.** A querier reaches a row when the row's scope is in
   the querier's accessible scopes (own principal scope, current group scopes,
   and `world` for an eligible Principal), when the querier authored the row,
   or when an Agent the querier owns authored or holds it. An owner cannot
   reach group-scoped rows through its Agent. `Ankole.Brain.Access` owns this
   rule and applies it as an SQL prefilter plus a row filter.
2. **Disclosure boundary.** A reply that other Principals can see narrows
   further: relaxed mode requires the asker to satisfy the scope, strict mode
   requires every present member to satisfy it. Group-memory disclosure mode
   is an Agent setting.

For a native conversation, strict disclosure checks every participant except
the Agent that produces the current answer. Other Agents remain recipients.
A scheduled reply without an asker uses the same recipient set. An empty or
unresolved set denies disclosure. IM conversations use their provider recipient
rules.

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
whose scope the querier cannot reach or disclose, and an unparseable body
renders empty instead of leaking unfiltered content.

## Pages, Facts, and Takes

A page (`brain_objects`) is the unit of curated knowledge: one slug under a
type-owned prefix (`people/`, `companies/`, `concepts/`, ...), a Markdown
body, and append-only versions. Concurrent edits use an expected content
hash; a mismatch rejects the write.

The `agent` type and `agents/<uid>` namespace are reserved for the canonical
pages of this instance's Agent Principals. Only the Principal lifecycle can
create them, with subtype `internal`. Generic writes, Source projections,
library projections cannot create these identities.
Knowledge and calibration updates to an existing Agent page remain valid.
Model-facing instructions explain this boundary before a write, and the
extraction type list excludes `agent`: Skills, models, tools, automations,
and assistant personas use ordinary knowledge types, not Principal pages.

Library projections use `library` Sources. Product and Plugin knowledge
files and published Skills own their bodies while `managed_by_source_id`
is set. Claims, links, timelines, tags, and aliases can attach to the slug.
Instance writes cannot edit a managed body. The Console can fork a knowledge
page into tenant ownership; later product updates then leave that body alone.
Skill discovery records cannot be forked. Removing a shipped file withdraws
its page and preserves attached data; a returning file restores the page in
place. Directory and file reads must complete before a set projects pages or
withdraws missing pages. Inventory read failures preserve that set's pages
and Source revision; other sets synchronize independently. A complete read of an
invalid file rejects the file and withdraws its projection.

Library writes lock the Source before the Object and check archive state
and body ownership in the page transaction. Source archive and withdrawal
commit together, so a running sync cannot restore an archived inventory.
One page failure does not roll back other pages.

A shipped Skill can declare `brain-recall-only: true`. It remains one standard
Skill with its global Skill name, but it is absent from the model-visible Skill
catalog. The library sweep projects only its name, description, and tags into
a world-visible managed Object of type `agent-skills` at
`lazyload-agent-skills/<skill-name>`; the full `SKILL.md`, resources, and Agent
lesson remain in the Skill loader. The `agent-skills` type and slug prefix are
reserved for this projection. An Agent's current effective Plugin and Skill
settings filter these records before retrieval limits and name resolution.
Disabling a Skill prevents discovery and loading without deleting its shared
tenant projection; removing the shipped file or the metadata declaration
withdraws the projection.

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

Claim resource actions own insertion, expiry, consolidation, calibration, and
resolution. A stored Take can resolve once; a stale snapshot cannot replace its
decision. Source withdrawal commits Fact expiry and Take deactivation together.
Embedding results compare the prior vector state before they write, so a late
failure cannot erase a successful rebuild. Late Fact dedup clears the complete
failed vector state while it links the historical assertion to the current one.

## Schema Packs

A schema pack seeds the instance ontology: page types with slug prefixes and
extractability, link types, and calibration domains. Setup installs the
`general` base pack plus the selected industry packs; installation
materializes the manifests into the `brain_schema_*` tables, which are
authoritative afterwards. Packs merge by name: a type registered by an
earlier install keeps its row, and a later pack can only widen subtype
suggestions. Conflicting declarations fail the install.

The pack, type, relation, calibration-domain, and Take-assignment rows are Ash
resources of the `Ankole.Brain` domain. Register actions keep the first declaring
pack and core type facts immutable. Subtype additions use one SQL union that
preserves first-seen order and cannot lose a concurrent addition. Take/domain
assignment retries return the first stored provenance and confidence. Native
checks enforce the string-array and confidence contracts. A composite tenant
foreign key prevents a Take assignment from referencing another tenant's claim.

Vocabulary and merge proposals, and contradiction findings, have resource-owned
state machines. A review changes the stored state once; an old snapshot cannot
reverse a decision. Proposal retries preserve the first evidence. The vocabulary
identity index covers both pending and rejected rows, so a concurrent suggestion
cannot reopen a rejected term. Approved rows remain audit records. Contradiction
recording classifies negative or low-confidence model verdicts as dismissed;
only open findings accept an operator decision.

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
  recency from the page's effective date, and salience from the page's active
  Takes (count, average weight, and the share held by people or Agents),
  with the high-emotion tag boost. These factors are calculated at
  recall time.
- An optional cross-encoder rerank over the fused chunk candidates when
  `brain.rerank_model` is configured; a timeout keeps the fusion order.

`context_pack` assembles the ambient injection for a turn: cards for the
resolved entities and channel, current facts first, under a fixed 4,000-token
budget. Opening injection records its item positions on each stateful request.
An opening retry can inject memory until its first Response is complete. Later
tool rounds use the pack already in history. Compaction excludes these items
from user originals and summary input. Each checkpoint refreshes its pack from
the latest user task in the current input or the original chain at the request's
anchor, through earlier checkpoints. It reserves the fresh pack in the
checkpoint budget and stores it outside the output, before retained user
originals and the summary when the provider replays it.

Context assembly and volunteer pointers are best effort. An unexpected
exception returns an empty result and emits one warning with the
failure class and stack locations. Logs omit exception messages and function
arguments. The warning does not stop the Turn or change the injection budget.

Page contradiction reads select at most twenty open findings, newest first,
and load their counterpart claims in one batch. Each counterpart still passes
the reader and disclosure checks before it enters the result.

Read projections preserve stored text after access and disclosure checks.
They do not remove words with an injection phrase blacklist. Skill lesson
writes use their own content admission gate (see `SkillLessons.md`).

## Tools

`Ankole.Brain.Tools` is the model-facing catalog and executor. AIGateway
declares it as the hosted `brain` tool and executes each call inside the
Response as the request subject: an Agent Turn or an OIDC Human. The subject
is the querier; a Turn's conversation supplies the disclosure recipients and
the default write scope. A workflow task gets the read-only subset `recall`
and `get_page` of the hosted tool.

A codex Job does not receive the hosted tool, because in Codex code mode the
model can call only the tools that Codex itself declared. When `brain.enabled`
is true, the turn start carries the `Ankole.Sessions.Tools.Brain` declarations
in `request_context.brain_tools`; the Worker declares them to Codex unchanged
as dynamic Job tools and sends each call through the `tools.read` RPC.
`Ankole.Sessions.ReadToolBroker` validates the arguments against the same
declaration and
`Ankole.Sessions.Tools.Brain` runs the operation through the same
`Ankole.Brain.Tools` executor, with the Job's Agent as the querier and the
`Ankole.Brain.RequestContext` of the Job's Signal as the disclosure boundary.
A Signal that the Agent does not own refuses the read. The result text is the
JSON document the hosted tool would return, with the lazy Skill hint first when
it names a Skill discovery record.

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
| `delta` | Reports knowledge changes since a cursor; excludes forgotten pages |

`context_pack` and `volunteer_pointers` serve the memory injection of a
stateful Response rather than the model. `docs/design-docs/AIGateway.md`
describes the declaration, the public items, and the injection. Request input
stores the caller's originals. Packs and pointer lines are separate local facts;
provider replay adds them to a copy in a fixed order. Checkpoints do not reopen
opening injection; pointers refresh for new user input. Each new
checkpoint refreshes its pack from the original task. Stored checkpoints are
not rewritten. A checkpoint's missing pack lasts until a later checkpoint or the
conversation reset at 04:30.

## Learning

Background learning writes memory without a `remember` call:

- **Signals learning** extracts durable claims from finished signal-channel
  conversation slices. A channel batch enters extraction after
  `brain.signal_channel_batch_idle_time` seconds of silence or at
  conversation end. Extraction runs before the commit transaction; the
  commit compares the starting watermark under the Source row lock and
  writes claims, entity links, and the Source watermark in one transaction.
  A run from an older watermark writes nothing. Before the model call, exact alias matching collects
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
  replacement as done. `url` Sources use only the Brain maintainer Agent's
  `web_fetch` profile. Without that profile the run fails with
  `web_fetch_model_not_configured`; a failed provider request fails it with
  the provider's reason. Brain sends no request to a Worker. `file` Sources
  accept UTF-8 text only.

- **OIDC Client Source learning** registers `kind=oidc_client` with
  `upstream_id=client_id` from stored AIGateway requests. A Client has one
  Source; each Client/conversation pair has one Source-owned `media` page.
  The authenticated Human remains the submission identity, not the assumed
  speaker of every line in a submitted transcript. Model output is attributed
  as generated text, not as evidence that an external event occurred.
  `OIDCClientConversations` owns the Gateway evidence projection and excludes
  Brain injection, instructions, reasoning, tool records, and checkpoints.
  This path adds no Signals, Channels, Bindings, Actors, or Agent execution.

  Brain splits dialogue text before it encodes extraction excerpts. Every
  excerpt keeps the request ID, parent ID, submission identity, speaker, and
  submitted-input or generated-output field. Short excerpts share one model
  call; the window builder never splits an encoded evidence record.

  Self-healing scans terminal request revisions and enqueues `LearnSource` for
  changed material. The default self-healing interval is 15 minutes. The
  Sources Console also supports Learn now. Revisions include every terminal
  request and its state, so a lower-ID request that finishes later is not lost.
  Extraction runs outside the transaction. Each material commit locks the
  Source, checks the previous projection, and writes the page, chunks, Claims,
  and learned revision in `Object.meta` together. A changed conversation is
  extracted again; the commit expires that page's previous Source facts.
  A failed material remains pending while other conversations can proceed.
  An extraction response with a non-object item fails before any commit.
  An append during extraction remains discoverable on the next sweep.

  An unset `default_audience_scope` uses `principal:<submitting Human uid>`.
  The configured default is captured in the page metadata on first learning,
  and both the original text and extracted Claims use it. Changing the Source
  default applies to conversations not yet learned; it does not change stored
  audiences. Archiving fences later commits and retains stored knowledge.
  Client deletion retains the Source and its evidence. Historical requests
  without trusted Client origin are not backfilled.

Extraction quality is a prompt contract: one independently changeable
assertion per item, confidence on the grid, first-person conviction caps.
The server enforces only the mechanical gates. JSON integers at the grid
endpoints (`0` and `1`) are valid and are stored as floats.

The conversation prompt does not promise that background learning has run.
An explicit request to remember durable information uses `remember`, and a
successful tool result is required before the Agent reports a saved memory.
An omitted scope retains the conversation audience. Retrying a rejected
Principal UID must not widen that audience. The Agent uses relevant history
already in context and retrieves more when needed. When current status
matters, it checks historical claims against available sources and carries
remaining uncertainty into its answer or background Job handoff.

## Dreaming and Self-Healing

Dreaming is the instance maintenance round, scheduled by
`brain.dreaming_task_cron`. The Brain health Console can also enqueue a round
immediately. Both entrypoints use the same unique Oban job; a queued or
running round is not duplicated, and a manual request does not change the
schedule. A disabled Brain rejects manual requests. Phases run in order and
one failing phase is recorded without blocking the rest:

1. `consolidate` — writes dense fact buckets as takes held by `brain` and
   keeps the source facts. These takes can appear in open threads until
   they are resolved or deactivated.
2. `patterns` — finds recurring themes across at least three distinct pages
   using up to 40 recent high-notability facts per audience from the last
   30 days. Existing patterns from that audience are supplied to the model
   to update the same semantic topic. Pages use
   `analysis/patterns/<scope-hash>/<topic>`, never a date-based daily digest.
   Each audience batch commits pages and replacement `derived_from` links
   together; citations must name supplied evidence and each body keeps the
   evidence audience. No useful pattern is a successful no-op. Generated
   pattern pages are excluded as new evidence.
3. `extract_timelines` — extracts dated events from each audience passage.
   It requires the Dreaming model and advances `timelines_extracted_at` only
   after successful extraction. A changed body remains pending.
4. `grade_takes` — grades expired or stale Takes against page evidence
   (`Ankole.Brain.Calibration`). A Take is expired when its `until_date`, a
   date column, is before today, and stale when it has no due date and is
   older than six months. `Claims.write_take` rejects a due date that is not
   one calendar date with `:invalid_until_date`, for every writer. A verdict
   of `correct`, `incorrect`, or `partial` on an expired Take is also its
   resolution: the same commit writes `resolved_at`, `resolved_quality`,
   `resolved_outcome` (`true`, `false`, or NULL for `partial`),
   and `resolution_provenance` `dreaming grade` through the same resolve
   step (`Claims.resolve_take_in_tx/2`) that the Console uses, with the Brain
   maintainer Agent's actor reference in `resolved_by`, and deactivates the
   Take, so it leaves the candidate set and enters the scorecards without a
   manual resolve. A Console resolve stores the Human's actor reference instead.
   Resolution stays immutable, so a Take that a Human resolved during the
   model call keeps the Human's verdict. An
   `unresolvable` verdict keeps the Take in the queue for later evidence, and
   a stale Take without a due date keeps only its grade, because its period is
   still open. Without a Dreaming model the phase reports
   `skipped: dreaming_model_not_configured`; the Dreaming job logs every
   skipped phase as a warning, and `/brain/health` reports the same state
   under `grading`. A Take records the input hash only after a
   successful grade. The hash covers the exact prompt, selected evidence,
   installed domain names and pack mapping, provider, model, credential-free
   connection settings, and request options with provider defaults. Model
   configuration and domains are read once per round and again at commit.
   Unchanged inputs skip the model. Each round attempts
   at most 50 changed inputs; cached Takes do not consume that limit. Batches
   contain at most 50 Takes. Before commit, the owner locks the Take and checks
   its eligibility and current inputs again. Failed calls and results for inputs
   that changed during the call record no new hash and retry in a later round.
   A change after the commit check remains different from the saved request hash
   and triggers a later grade. Credential rotation does not invalidate grades.
   An upstream change behind the same unversioned model name cannot be detected.
5. `calibration_profile` — writes each holder's Brier scorecard into the
   fenced calibration section of the holder page (`Ankole.Brain.Calibration`
   owns the Brier formula; the expert directory reads the same function).
6. `contradictions` — judges newest claim pairs once per pair; confident
   contradictions open triage rows, everything else lands dismissed. An
   operator decision (`resolved` or `dismissed`) applies only to an open row,
   under a row lock.
7. `schema_suggest` — counts vocabulary terms in tags and subtypes. At 20
   pages it proposes a subtype; at 100 pages it proposes a type. The Console
   retains approval and rejection records. Approval registers the schema and
   updates affected pages and slug references in one tenant transaction.
   Promotion keeps each Human Principal's canonical `people/<uid>` page in
   place. Other tagged person pages can move to the new type.
8. `merge_suggest` — the mechanical backstop behind write-time entity
   dedup: pairs live pages of one type that share a normalized alias
   into `brain_merge_suggestions`, one row per
   pair forever. Nothing merges automatically; a Console approval merges
   the pair in one transaction (claims, holders, timelines, aliases,
   tags, and links repoint, the duplicate becomes a slug redirect), and canonical
   Principal pages, library pages, media-primitive pages, and duplicates
   with a written body are refused.
9. `purge` — hard-deletes soft-deleted pages past the TTL.
10. `skill_lessons` — see `docs/design-docs/SkillLessons.md`.

Self-healing runs on its own cron: it embeds pending rows, repairs missing
projections, and reports drift. It reconciles body-owned wikilink and alias
mention edges without a Dreaming model. `links_extracted_at` records this
mechanical work independently of timeline extraction. Reconciliation removes
only stale edges with its own body provenance and keeps manual or learned
relations. Unchanged edges keep their IDs. Content writes advance the logical `updated_at` timestamp. A body edit
triggers both passes; a title edit also triggers timeline extraction because
the title is part of its model input. Other field edits carry completed
watermarks to the new timestamp. They do not complete pending work for an
earlier body or title. Projection-only writes preserve the logical timestamp.
A later target or alias creation does not by
itself invalidate this body watermark; explicit reconciliation can retry an
unresolved reference. Time decay itself stores nothing: ranking
recomputes effective confidence on read, and `brain.forgetting` holds the
halflives.

These model calls are stateless and have no tools or conversation history.
Grading, contradiction checks, and pattern detection receive available claim
dates, context, attribution, and provenance. Grading also receives the Take's
period and provenance. On-demand synthesis receives claim IDs, pages, holders,
and provenance, with Fact validity dates and Take periods kept separate.
Brain model calls set a phase-specific `brain.*` caller in AIGateway traces,
so operators can inspect each prompt and result in Langfuse.

## Configuration

Operator settings live under declared `brain.*` AppConfigure keys. The site
owns `embedding_model` with its dimensions and `search_tokenizer`. Tenant
settings include `enabled`, `maintainer_agent_uid`, `rerank_model`, `chunking`,
`forgetting`, the two cron expressions, `signal_channel_batch_idle_time`,
`skill_learning_enabled`, and `skill_learning_reflection_threshold`; a missing
tenant override inherits the site value.

The selected maintainer Agent supplies `light` for Signals and Source
extraction, `heavy` for Dreaming, and `web_fetch` for URL Source learning. The
Brain settings editor selects the Agent and links to that Agent's model profile
editor; it does not duplicate those three profile controls. Embedding and
rerank stay in the Brain editor because they serve Brain retrieval rather
than one Agent's model loop. All Brain model calls, including embedding
and rerank, execute as the selected Agent and attribute usage to that Agent.
The selected Agent must be active. Disabling it makes Brain unhealthy and
stops all model calls and local URL fetching until the Agent is enabled or
replaced. Stored knowledge and pure-text recall remain available during that
state.

## Retrieval index recovery

Brain requires `pg_search` 0.25.11. The development and Compose PostgreSQL
image pins this version. External PostgreSQL installations must supply the
same extension and loaded library; see the
[database image upgrade procedure](../../tools/devkit/postgres-for-ankole/README.md).

PostgreSQL base tables hold the knowledge facts. `Ankole.Brain.SearchIndexes`
owns the BM25 and HNSW index definitions and repairs missing, invalid, or
unready indexes. PostgreSQL can report an index as valid even when its native
search reader fails. Such a failure needs operator recovery; recall does not
replace the knowledge boundary with an empty result or a different query.

If a BM25 index reader fails, identify the failing BM25 index
from the query and confirm the base table is readable. In a maintenance
window, rebuild that index in the application database:

```sql
REINDEX INDEX public.brain_claims_bm25_idx;
-- Use brain_chunks_bm25_idx instead if the failing query reads brain_chunks.
```

This command can block concurrent access while it rebuilds the index. It does
not change the base rows. Repeat the failed recall after the rebuild. If it
still fails, retain the error and inspect the installed `pg_search` version;
do not reset the database or bypass the read boundary.

## Console

The Console `Brain` area gives operators: object browsing with version
history and rollback, claim listing with take resolution, source management
(register, learn, archive), contradiction triage, duplicate-page merge decisions, per-principal knowledge audit,
search preview as any Principal, and health counters. The implementation in
[`BrainMarkdoc.md`](BrainMarkdoc.md) includes a full-page Object source editor
with segment preview, diagnostics, and server-authoritative save validation.

Lists keep loaded rows visible when a later page fails to load. The error and
Retry control appear below those rows. Retry requests the failed page and adds
its rows to the same list.

### Resource write contracts

All Brain rows use Ash resources of the `Ankole.Brain` domain. Object actions
keep content edits, Source projections, ownership changes, and maintenance stamps
separate. Content edits compare the stored content hash. Projection writes check
the stored Source owner. Maintenance stamps do not advance the content clock.
Source actions keep upstream identity immutable and reject sync and extraction
writes after archive. Registration retries keep the first Source facts.

`Ankole.Brain` is the domain interface. Resource reads use Ash queries and
domain functions. Each multi-step operation runs in
`Repo.transact_top_level/2`, locks its rows, runs its write steps, and commits
them together:

| Module | Operations |
|---|---|
| `Objects` / `Chunks` / `Links` | `create_object`, `update_object`, `upsert_source_projection`, `upsert_library_projection`, `soft_delete_object`, `rollback_object`, `fork_library_page`, `restore_object`, `reconcile_chunks`, `reconcile_object_links` |
| `Claims` | `write_fact`, `supersede_claim`, `expire_fact`, `deactivate_take`, `resolve_take`, `attach_claim_embedding`, `consolidate_facts` |
| `Sources` | `archive_source`, `update_source_default_scope` |
| `Promotion` / `Merge` / `Dreaming` | `approve_promotion`, `reject_promotion`, `approve_merge`, `reject_merge`, `decide_contradiction` |

The Console API at `/api/v2/brain` (`AnkoleWeb.JSONAPI.ConsoleRouter`) gives
the `json_api` routes of `Ankole.Brain`. Each list is a `:console_list` read
action that gives the first 100 rows. A Console write is a generic action on
its subject resource (`console_create`, `console_update`, `fork_library_page`,
`console_rollback`, `console_forget`, `restore_object`, `console_supersede`,
`console_resolve`, `decide`, `console_approve`, `console_reject`,
`archive_source`, `update_default_scope`): the Principal of the session is the
Ash actor (`Ankole.Brain.Console`), and the action runs the same `_in_tx` steps
or top-level domain function. A missing target gives 404, and a reason that
conflicts with the current state (`content_hash_conflict`, `object_deleted`,
`slug_taken`, `conflict`) gives 409; another domain reason gives 422 with the
reason as the code.

`Ankole.Brain.ConsoleViews` supplies the health snapshot, the object page, the
object types, the search preview, the per-principal audit, and the Dreaming
trigger at `/api/v2/brain`. These generic transport actions return typed maps.
They use the simple data layer and do not start a transaction. The Brain
operations that they call own their transactions. The object page accepts
`slug` as a query parameter, so slugs can contain `/`. Search preview applies
the selected Principal's knowledge and disclosure boundaries; the operator
audit can read the full claim detail.

Background Brain writes also run in `Repo.transact_top_level/2` in their owning
modules: `Calibration.grade_takes/0`, `Forget.forget_claim/3`,
`Timelines.write_timeline/3`, `Patterns.run/0`, `SourceLearning.learn/1`,
`OIDCClientLearning.learn/1`, `ConversationsLearning.process_conversation/1`,
`LibraryKnowledge.sync/1`, and `SchemaPacks.install_packs/1`.
Tenant creation and setup completion install the schema packs in their own
transaction with `SchemaPacks.install_packs_in_tx/1`.

A conversation slice writes its memory items in one transaction and keeps the
transaction after an item fails validation. So an item write gives an error
only before its first write. A Fact write locks its semantic dedup target and
reads it again before it inserts the new Fact. When a concurrent write
superseded or expired the target, the dedup query runs again and finds the
replacement, so a slice never commits two current Facts. When the old Fact
cannot be marked after the insert, the Fact write rolls back the transaction of
its caller. A timeline write rolls back the same way when the chunk projection
of its host fails after the insert.

Each top-level Brain operation rejects a caller transaction before it writes. A
step that runs in the transaction of another operation is an `_in_tx` function
of the owning module, for example `Objects.create_object_in_tx/1` or
`Chunks.reconcile_in_tx/1`. An `_in_tx` function refuses to run outside a
transaction. `write_fact` and `supersede_claim` request the embedding of new
claim text from the network before they open a transaction, so no transaction
waits for the network.

The knowledge boundary (`Access`) and the lazy Skill projection
(`LazySkillVisibility`) filter Ash queries. Their filters use the Claim
calculations `current?`, `live_parent?`, and `current_external_fact?`, and the
`object` relationships of Chunk and Timeline. Conversations, Messages,
Participants, Signals, Principals, Agents, Jobs, and Agent Skills are read
through the defines and functions of their own domains.

Some reads are not reads of one resource. They stay Ecto or SQL queries, give
values and not resource rows, and are registered in the persistence boundary
(`app/control_plane/test/ankole/persistence_boundary.exs`):

- Read models (M4): the Dreaming bucket and term-usage counts, the
  duplicate-page scan, and the known pages of a learning transcript
  (`ConversationsLearning.known_pages/1`, Objects and their ranked aliases).
- Retrieval (M9): the candidate, boost, and neighborhood queries of `Recall`,
  and the semantic Fact dedup query of `Claims`. They select identifiers and
  values; the ranked Claims, Chunks, and dedup targets load through Ash. The
  Ecto forms of `Claims.filter_live_parents/1`, `Claims.current_external_facts/1`,
  and of the Claim, Chunk, and Link filters of `Access` and
  `LazySkillVisibility` serve only these queries.
- Set maintenance (M8): the merge repoint statements and the index DDL of
  `SearchIndexes` (site scope: the indexes cover the tables of all tenants).

Brain aggregates, Ash actions, row locks, and native queries use `Ankole.Repo`
in the same process transaction. The process tenant and dynamic repository apply
to the whole operation. Brain options cannot select a second Repo.

Links, tags, names, and timeline events retain their native retry keys. Merge
reparent actions own the native deduplication and foreign-key updates while the
merge holds both Object locks. The merge, redirect, and review decision commit
in one transaction. Native vector and full-text queries retain their storage
and query operators.
