# BrainV3

Brain is the tenant-shared knowledge space. Agents, Humans, and background
learning write into a single body of pages and claims, and every read enforces
the querier's knowledge and disclosure boundaries. Brain replaces per-Agent
memory files: what one Agent learns, every authorized Principal can reach.

The Elixir control plane owns all Brain state and domain logic:

- A chat Session reaches Brain exclusively through the AIGateway-hosted `brain`
  tool, which executes inside the model Response.
- A Codex Background Agent Job reaches the read-only Brain subset through the
  Worker read-tool bridge, where `Ankole.Sessions.Tools.Brain` executes each
  call on the control plane. The Worker itself holds neither Brain state nor
  Brain logic; its local Brain tool acts solely as the transport codec for that
  bridge.

## Storage

Brain stores all durable state in PostgreSQL. Every primary key is an
application-generated UUIDv7; PostgreSQL never generates random UUIDs for these
tables.

| Table | What it stores |
| --- | --- |
| `brain_schema_packs` | One installed schema pack version with its frozen manifest |
| `brain_schema_types` | The tenant page-type registry, merged from the installed packs |
| `brain_schema_link_types` | The relation predicate vocabulary |
| `brain_schema_calibration_domains` | Named calibration domains for Take scorecards |
| `brain_sources` | Registered learning Sources and shipped-library projection sets with their revision fingerprints |
| `brain_objects` | One page per slug: type, subtype, title, Markdown body, and optional Brain Source body owner |
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

Vector search uses `pgvector` `halfvec` HNSW indexes, while full-text search
uses `pg_search` BM25 indexes with a configurable tokenizer. Entity resolution
matches exact slugs first, then slug redirects, normalized aliases, and finally
exact titles; when a name matches multiple pages, resolution returns candidates
rather than guessing, and fuzzy title similarity never establishes identity.

Because BM25 and HNSW indexes span shared physical tables, the search tokenizer
and embedding model are site-wide settings. By contrast, reranking runs at query
time without an index and is configured per tenant. Every query filters by
tenant, and schema packs and library projections are installed independently in
each tenant.

Brain includes installed relation names and their inverses in the prompt that
extracts claims from conversations. Those terms serve as a preferred vocabulary
rather than a closed set: the model may emit another relation label when no
installed term fits.

Operators create and replace page tags in the Console through the Object write
contract. Tags are exact, case-sensitive strings; the server trims surrounding
whitespace, rejects blank strings, and stores one row per distinct tag. If a
write omits `tags`, the server preserves the current set; passing `[]` clears
all tags. The Object content hash covers the tag set, each update snapshots the
previous tags alongside the `ObjectVersion` author, and page merges recompute
that hash after moving tags. In the Console editor, drafts hold tags as an array
and render one input per tag so embedded newlines and literal backslashes stay
inside a single tag. Rolling back to a prior version restores only `body` and
`meta`, leaving current tags unchanged.

`ObjectVersion.snapshot` writes immutable body, metadata, tag, and author
snapshots and requires the caller's Object write transaction, ensuring that a
failed edit never leaves an orphan history entry. Under the same Object row
lock, `Ankole.Brain.Chunks` reconciles chunk positions: its resource actions
create, replace, or delete projection rows, clearing the full vector state
whenever a chunk changes while keeping both the row and vector for unchanged
positions.

Embedding writes use a single atomic resource action that verifies the input
text, embedding timestamp, and model signature before committing. PostgreSQL
check constraints validate the complete vector state and reject partial success
or failure records. Embeddings use the Ash `:vector` type and
`AshPostgres.Extensions.Vector` to store 4,096 `float32` values in a PostgreSQL
`vector(4096)` column.

## Scope and Disclosure

Every claim, timeline event, and Markdown audience segment carries one
`audience_scope`:

- `world`: active Human members, Agents, and System Principals of the current
  tenant (Human guests do not receive `world`).
- `group:<name>`: members of one AuthZ Principal group.
- `principal:<uid>`: one specific Principal.

Every read enforces two boundaries in sequence:

1. **Knowledge boundary.** A querier can reach a row when the row's scope is in
   the querier's accessible scopes (its own `principal:<uid>` scope, its current
   `group:<name>` scopes, and `world` for eligible Principals), when the querier
   authored the row, or when an Agent that the querier owns authored or holds
   the row (though an Agent owner cannot reach `group:<name>` rows through its
   Agent). `Ankole.Brain.Access` enforces this rule through an SQL prefilter
   paired with an in-memory row filter.
2. **Disclosure boundary.** When other Principals can read the reply, disclosure
   narrows the result further: `relaxed` mode requires the asking Principal to
   satisfy the scope, whereas `strict` mode requires every present room member
   to satisfy it. The disclosure mode for group memory is configured per Agent.

In a native conversation, `strict` disclosure checks every room participant
except the Agent generating the current reply (other Agents in the room still
count as recipients). Scheduled replies with no human asker check that same
recipient set, and if the recipient set is empty or unresolved, Brain denies
disclosure. External IM conversations resolve recipients through the rules of
their IM provider.

Write eligibility mirrors read reachability: a writer may write any scope that
it can reach itself, while the system writer may write any scope. Both
`remember` and URL Source registration follow this rule. When the model omits an
explicit scope, Brain defaults to `principal:<asker_uid>` in a direct chat, the
backing Principal group in a member-backed group chat, and `principal:<agent_uid>`
on all other turns. When the model supplies an explicit scope, the write keeps
that scope if the writer is eligible; `ConfidentialityPolicy.md` guides model
scope selection.

Page bodies embed scopes inline using block-level Markdoc `audience` tags. The
Rust kernel owns the normative grammar (CommonMark plus root-level `audience`
tags and `[[slug]]` wikilinks, specified in [`BrainMarkdoc.md`](BrainMarkdoc.md)),
and `Ankole.Brain.Markdoc` delegates directly to that kernel parser with no
fallback path. Rendering a page strips segments that fail the caller's knowledge
or disclosure checks, and if a stored body fails to parse, Brain renders an
empty body rather than risking unfiltered disclosure.

## Pages, Facts, and Takes

A page (`brain_objects`) is the unit of curated knowledge: a unique slug under a
type-owned prefix (`people/`, `companies/`, `concepts/`, and so on), a Markdown
body, and append-only version snapshots. Concurrent edits coordinate via an
`expected_content_hash`; if the hash does not match the stored row, the control
plane rejects the write.

The `agent` page type and `agents/<uid>` slug namespace are reserved exclusively
for canonical pages of Agent Principals in the current tenant. Only the
Principal lifecycle can create these pages (using subtype `internal`); generic
Object writes, Source projections, and library projections cannot create them,
though knowledge and calibration writes to an existing Agent page remain valid.
Model-facing instructions state this rule up front, and the extraction prompt
omits `agent` from its page-type list so Skills, models, tools, automations, and
personas use ordinary knowledge types instead.

Shipped product knowledge, Plugin knowledge files, and published Skills project
into Brain through `library` Sources, which own the projected page bodies while
`managed_by_source_id` is set. Tenant claims, links, timelines, tags, and
aliases can still attach to those slugs, and although ordinary instance writes
cannot edit a managed body, an operator in the Console can fork a library
knowledge page into tenant ownership so later product upgrades leave its body
untouched (Skill discovery projections cannot be forked).

During a library sync, all directory and file reads for a projection set must
succeed before Brain projects updates or withdraws missing pages. If a shipped
file is removed, Brain withdraws its page while retaining attached claims and
links, restoring the page in place if the file later returns. If reading an
inventory fails, Brain leaves that set's pages and Source revision untouched
while allowing other sets to sync independently; if a file is read completely
but fails validation, Brain rejects that file and withdraws its projection.
Library writes lock the `Source` row before the `Object` row and verify archive
status and body ownership inside each page transaction (one page failure does
not roll back other pages), while archiving a Source commits together with page
withdrawal so an in-flight sync cannot resurrect an archived set.

A shipped Skill may declare `brain-recall-only: true` in its frontmatter. It
remains a standard Skill under its global name, but Ankole omits it from the
inline Skill catalog and instead projects only its name, description, and tags
into a `world`-scoped managed Object of reserved type `agent-skills` at
`lazyload-agent-skills/<skill-name>` (keeping the full `SKILL.md`, bundled
resources, and learned lessons inside the Skill loader). Before applying recall
limits or resolving Skill names, Brain filters `agent-skills` pages against the
querier Agent's effective Plugin and Skill configuration: disabling a Skill
hides it from discovery and loading without deleting the shared tenant row,
whereas removing the shipped file or `brain-recall-only` flag withdraws the
projection.

A claim (`brain_claims`) is one atomic assertion attached to a page or signal
channel. A PostgreSQL check constraint on `claim_type` separates two disjoint
families:

- **Facts** are bitemporal assertions carrying `valid_from`, an optional
  `valid_until`, a closed kind enum (`event`, `preference`, `commitment`,
  `belief`, `fact`), a notability level, and confidence on a `0.05` grid.
  Updating a Fact inserts a new row and links the prior row via `superseded_by`,
  preserving full history when Facts expire or change.
- **Takes** are predictions and judgments carrying an open kind string, a weight
  on the same `0.05` grid, and a resolution lifecycle (`graded_*`, `resolved_*`)
  that feeds calibration scorecards.

Writing a Fact runs semantic deduplication within the same parent, holder, and
`audience_scope`: if the nearest cosine neighbor is at or above `0.95`, Brain
merges identical assertions or supersedes the older Fact when the wording
changed. Takes never undergo semantic deduplication.

`Claim` resource actions govern insertion, expiry, consolidation, calibration,
and resolution:

- A Take can resolve at most once, so a stale read snapshot cannot overwrite a
  recorded verdict.
- Withdrawing a Source expires its Facts and deactivates its Takes in one
  transaction.
- Embedding updates compare the prior vector state before writing so a delayed
  embedding error cannot overwrite a newer successful vector, and late Fact
  deduplication clears any failed vector state while linking the superseded row
  to the current Fact.

## Schema Packs

Schema packs seed a tenant's ontology by declaring page types (with slug
prefixes and extractability flags), link predicates, and calibration domains.
Tenant setup installs the `general` base pack plus any selected industry packs,
materializing their manifests into the `brain_schema_*` tables, which serve as
the authoritative registry afterward. Packs merge by type name: an already
registered type keeps its core definition, a later pack may only append subtype
suggestions, and conflicting core declarations abort installation.

Pack, page-type, link-type, calibration-domain, and Take-assignment rows are all
Ash resources in `Ankole.Brain`. Registration actions keep the first declaring
pack and core type attributes immutable, while subtype additions merge via an
atomic SQL union that preserves first-seen order under concurrent writes.
Retrying a Take-to-domain assignment returns the originally recorded provenance
and confidence. PostgreSQL check constraints validate string arrays and
confidence bounds, and a composite tenant foreign key prevents a Take assignment
from pointing to another tenant's claim.

Vocabulary promotions, duplicate-page merge suggestions, and contradiction
triage rows each use Ash state machines:

- Operator reviews transition a row once, preventing stale UI snapshots from
  reversing a recorded decision.
- Retrying a proposal preserves its initial evidence, and the unique index on
  vocabulary suggestions spans both `pending` and `rejected` rows so concurrent
  sweeps cannot reopen a rejected term (while `approved` rows remain as audit
  records).
- Contradiction detection immediately records negative or low-confidence model
  verdicts as `dismissed`, leaving only `open` findings eligible for operator
  triage.

## Retrieval

`recall` fuses two candidate queries over rows reachable by the querier (for an
Agent querier, both queries filter out disabled lazy Skills before taking their
candidate limits):

1. **BM25 lexical search** across claim text and chunk text.
2. **Vector similarity search** across `halfvec` embeddings, using an HNSW index
   scan on the first 4,000 dimensions to select candidates and exact full-vector
   distances to order them.

In the Rust kernel, reciprocal-rank fusion (RRF) combines both candidate lists
into real additive scores, so any item returned by both routes receives the sum
of both RRF contributions. Before cross-encoder reranking, `Ankole.Brain.Recall`
filters chunk candidates through the caller's two-layer access and disclosure
boundary and caps candidates at two chunks per page slug so long source pages
cannot crowd distinct entity pages out of the rerank window. When
`brain.rerank_model` is configured, the cross-encoder reranks those capped
candidates (falling back to the RRF scores if the reranker times out). Recall
then applies domain scoring adjustments:

- **Facts** decay with age using `confidence * exp(-age / halflife)` based on
  per-kind halflives in `brain.forgetting`, whereas **Takes** use their stored
  weight directly. Returned claims carry their qualifying `context` alongside
  `text`, counting both toward `budget_tokens`.
- **Chunks** receive recall-time boosts (applied atop reranked scores) for graph
  adjacency when a page links to two or more hits, plus recency (from the page's
  `effective_date`) and salience (from the page's active Takes, combining count,
  mean weight, and the share held by Humans or Agents) strictly on hits backed
  by a BM25 lexical match; vector-only semantic hits keep a `1.0` metadata
  multiplier so fresh or salient pages do not outrank more relevant passages
  without lexical evidence.
- **Entity cards** resolve deterministically from exact normalized alias matches
  in the query (plus the resolved `entity` filter when supplied, bounded to its
  neighborhood) without a model call, returning up to three two-layer-filtered
  cards with aliases, relational graph edges, backlink counts, and top facts.

Result assembly packs ranked claims first, then matched entity cards, and
finally ranked chunks greedily: if one candidate exceeds the remaining token
budget, assembly skips it and continues scanning smaller items. For Chinese,
Japanese, and Korean text without spaces, chunk overlap splits on Unicode
grapheme boundaries.

For ambient turn memory, `context_pack` builds entity and channel cards (placing
current Facts first) within a fixed 4,000-token budget:

- On stateful Responses, opening injection records its item positions on the
  request; an opening retry may re-inject memory until the first Response
  completes, whereas subsequent tool rounds reuse the pack already in history.
- Compaction omits injected memory items from both retained user originals and
  summarization input.
- Each compaction checkpoint builds a fresh pack from the latest user task (in
  current input or in the original chain at the request's anchor across prior
  checkpoints), reserves that pack inside the checkpoint budget, and stores it
  outside the checkpoint output so provider replay places it ahead of retained
  user originals and the summary.

Both `context_pack` and `volunteer_pointers` run best-effort: if an unexpected
exception occurs, Brain returns an empty injection and emits a single warning
containing only the exception class and stacktrace (omitting exception messages
and function arguments) without aborting the Turn or altering token budgets.

Reading contradictions on a page fetches up to 20 `open` findings (newest first)
and batch-loads their counterpart claims, filtering each counterpart through the
caller's knowledge and disclosure boundaries before returning it. Read
projections return stored text verbatim once access and disclosure checks pass,
without stripping phrases via a prompt-injection blocklist; Skill lesson writes
enforce their own admission gate in `SkillLessons.md`.

## Tools

`Ankole.Brain.Tools` defines the model-facing catalog and executor. On stateful
chat Responses, AIGateway registers it as the hosted `brain` tool and executes
calls inline as the authenticated request subject (an Agent Turn or an OIDC
Human): that subject acts as the querier, while an Agent Turn's conversation
determines disclosure recipients and the default write scope. Workflow tasks
receive only the read-only hosted operations (`recall` and `get_page`).

Tool function schemas set `strict: false` so model calls can omit optional
parameters that do not apply to the chosen operation.

Codex Background Agent Jobs do not receive the AIGateway-hosted tool because
Codex code mode can invoke only tools declared directly to Codex. Instead, while
`brain.enabled` is `true`, Turn start populates `request_context.brain_tools`
with `Ankole.Sessions.Tools.Brain` declarations; the Worker registers those
exact schemas as dynamic Codex tools and forwards calls over the `tools.read`
RPC. On the control plane, `Ankole.Sessions.ReadToolBroker` validates arguments
against the same schema and `Ankole.Sessions.Tools.Brain` invokes
`Ankole.Brain.Tools` with the Job's Agent as querier and the source Signal's
`Ankole.Brain.RequestContext` as the disclosure boundary. If the Signal does not
belong to that Agent, the broker rejects the read. Otherwise, it returns the
exact JSON payload that the hosted tool returns, prepending the `skill_view`
load hint whenever the target is an `agent-skills` discovery page.

| Operation | What it does |
| --- | --- |
| `remember` | Writes one Fact or Take through the shared write contract |
| `put_page` | Creates a structured page or replaces an existing single-scope page body under `expected_revision` optimistic concurrency |
| `edit_page` | Applies exact-match surgical replacements inside caller-writable Markdoc spans under `expected_revision`, preserving hidden scopes and calibration scorecards and returning a compact unified diff |
| `learn_source` | Registers one web URL Source and starts a background learning run |
| `recall` | Fused retrieval over reachable claims, exact-alias entity cards, and chunks |
| `get_page` | Renders one page with its content `revision` and optional pruned Markdoc `content` (`include_content: true`); a lazy Skill record comes back with the hint to load it with `skill_view` |
| `forget` | Expires or retracts a claim; soft-deletes a page |
| `entity` | Resolves a name to a page through aliases; ambiguity returns candidates |
| `whoknows` | Reports which Principals' scopes hold knowledge on a topic |
| `synthesize` | Writes an analysis page from reachable knowledge, contested claims, and open gaps, at the caller's eligibility |
| `delta` | Reports knowledge changes since a cursor; excludes forgotten pages |

Unlike the model-callable operations above, `context_pack` and
`volunteer_pointers` power automatic memory injection on stateful Responses (see
`docs/design-docs/AIGateway.md` for item schemas and replay ordering). AIGateway
stores the caller's original request input separately from local context packs
and pointer lines, splicing them into a transient copy in a fixed order during
provider replay. Compaction checkpoints never reopen opening injection:
`volunteer_pointers` refreshes on new user input, each new checkpoint refreshes
its `context_pack` from the original task without mutating earlier stored
checkpoints, and if a checkpoint lacks a pack, that absence persists until the
next checkpoint or the daily `04:30` conversation reset.

## Learning

Three background pipelines extract knowledge without an explicit `remember` tool
call:

- **Signals learning** extracts durable claims from completed signal-channel
  conversation slices once a channel sits idle for
  `brain.signal_channel_batch_idle_time` seconds or when the conversation ends.
  Model extraction runs outside database transactions; before calling the model,
  exact alias matching gathers stored pages that the slice already mentions and
  injects their slugs into the prompt so the model reuses canonical slugs at
  write time (neither slug idempotency nor vector cosine similarity can unify
  alternate phrasings of the same entity afterward). At commit time, Brain locks
  the `Source` row, verifies that the starting watermark still matches (dropping
  stale runs without writing), and commits claims, entity links, and the new
  watermark in one transaction.
- **Source learning** maintains one `media` page for each registered `file`
  (UTF-8 text only) or `url` Source (which never produces entity slugs). Each
  run fetches the content, checks the revision fingerprint, extracts claims
  across every content window, and commits the Object, claims, and new
  fingerprint in one transaction under the `Source` row lock while expiring
  Facts from the prior revision. If every extracted item fails write validation,
  Brain rolls back the entire transaction without advancing the fingerprint so
  the run retries rather than marking an empty extraction complete. Fetching a
  `url` Source uses only the Brain maintainer Agent's `web_fetch` profile on the
  control plane (never dispatching to a Worker): if that profile is unconfigured,
  the run fails with `web_fetch_model_not_configured`, and upstream provider
  errors fail with the provider's reason.
- **OIDC Client Source learning** registers one `kind=oidc_client` Source per
  Client (`upstream_id=client_id`) from completed AIGateway requests, maintaining
  one Source-owned `media` page per `(Client, conversation)` pair without
  creating Signals, Channels, Bindings, Actors, or Agent runs.
  `OIDCClientConversations` builds the evidence transcript (stripping Brain
  injections, system instructions, reasoning traces, tool calls, and compaction
  checkpoints) while attributing the authenticated Human as the request
  submitter (rather than assuming that they spoke every line of a pasted
  dialogue) and marking assistant turns as generated output rather than proof of
  external events.

  Before building model windows, Brain splits dialogue turns into individual
  excerpts that retain request ID, parent ID, submitting Human, speaker label,
  and input-versus-output provenance; short excerpts pack into shared model
  calls without ever splitting a single encoded evidence record.

  Every 15 minutes by default (or immediately via **Learn now** in the Sources
  Console), self-healing scans all terminal request revisions, including
  lower-ID requests that finished out of order, and enqueues `LearnSource` for
  changed conversations. Extraction runs outside transactions; each conversation commit
  locks the `Source`, checks the prior projection, expires prior Source Facts on
  re-extraction, and writes the page, chunks, Claims, and learned revision in
  `Object.meta` atomically. If the model returns a non-object item, the run
  aborts before committing; a failing conversation stays pending without
  blocking sibling conversations, and messages appended mid-extraction are
  picked up on the next sweep.

  When `default_audience_scope` is unset, OIDC Client learning defaults to
  `principal:<submitting Human uid>`. First learning pins the resolved audience
  in page metadata for both the page body and extracted Claims: later edits to
  the Source default affect only unlearned conversations, archiving the Source
  fences subsequent commits while keeping stored knowledge, deleting the OIDC
  Client preserves both the Source and its pages, and historical requests
  without trusted Client provenance are never backfilled.

Across all extraction pipelines, granularity (one independently mutable
assertion per claim, `0.05`-grid confidence, and first-person conviction caps)
is guided by prompts while the server enforces structural invariants; JSON
integers `0` and `1` at the grid endpoints are accepted and stored as floats.

In live conversations, the system prompt never assumes that background learning
has already run: when a user explicitly asks the Agent to remember durable
information, the Agent must call `remember` and wait for tool success before
confirming that the memory was saved. Omitting `scope` preserves the
conversation's default audience, and if `remember` rejects an invalid Principal
UID, retrying must not widen the scope. When answering questions where current
status matters, the Agent cross-checks historical Brain claims against live
sources and states any remaining uncertainty in its reply or Background Job
brief.

## Dreaming and Self-Healing

Dreaming is the periodic maintenance pipeline scheduled by
`brain.dreaming_task_cron` (and triggerable on demand from the Brain health
Console). Both entry points share a single unique Oban job so concurrent
triggers deduplicate without altering the cron schedule, and manual triggers are
rejected while Brain is disabled. Dreaming runs ten phases sequentially,
recording any phase error without halting later phases:

1. **`consolidate`** summarizes dense Fact clusters into Takes held by `brain`
   while retaining the underlying Facts; those Takes surface in open threads
   until resolved or deactivated.
2. **`patterns`** detects recurring themes spanning at least three pages across
   up to 40 high-notability Facts per audience from the past 30 days, passing
   existing pattern pages for that audience so the model updates stable semantic
   topics at `analysis/patterns/<scope-hash>/<topic>` (never date-stamped daily
   digests). Each audience batch atomically commits updated pages and
   replacement `derived_from` links, requiring citations to reference supplied
   evidence, preserving the evidence's `audience_scope`, treating "no pattern"
   as a clean no-op, and excluding pattern pages themselves from future input
   evidence.
3. **`extract_timelines`** extracts dated timeline events from each audience
   segment using the Dreaming model, advancing `timelines_extracted_at` only
   after extraction succeeds so edited bodies stay pending.
4. **`grade_takes`** evaluates expired or stale Takes against reachable page
   evidence (`Ankole.Brain.Calibration`). A Take is expired once its calendar
   `until_date` precedes today (`Claims.write_take` rejects non-calendar values
   with `:invalid_until_date` across all writers), and stale when it has no
   `until_date` and is older than six months.

   When an expired Take receives a `correct`, `incorrect`, or `partial` verdict,
   grading resolves it in the same transaction via `Claims.resolve_take_in_tx/2`
   (the same step used by Console resolution, recording the Brain maintainer
   Agent in `resolved_by` rather than a Human): it sets `resolved_at`,
   `resolved_quality`, `resolved_outcome` (`true`, `false`, or `NULL` for
   `partial`), and `resolution_provenance = "dreaming grade"`, and deactivates
   the Take so it enters Brier scorecards immediately. Because resolution is
   immutable, a Human verdict committed while the model call was in flight wins.
   An `unresolvable` verdict leaves the Take queued for future evidence, and
   grading an open-ended stale Take records only its provisional grade without
   resolving it. If no Dreaming model is configured, the phase reports
   `skipped: dreaming_model_not_configured`, logs a warning, and surfaces that
   status on `/brain/health` under `grading`.

   Each round attempts at most 50 changed Takes in batches of up to 50, reading
   model settings and calibration domains at round start and re-verifying them
   under row lock at commit. A Take stores its request input hash (covering the
   exact prompt, evidence, installed domain names and pack mappings, provider,
   model, non-secret connection settings, and effective request options) only
   after a grade commits: unchanged hashes skip the model without counting
   toward the 50-item cap, failed calls or mid-call input edits record no hash
   so a later round retries, post-commit edits diverge from the saved hash to
   trigger re-grading, credential rotation leaves hashes valid, and upstream
   weight changes behind an unversioned model alias are undetectable.
5. **`calibration_profile`** renders each holder's Brier scorecard into the
   fenced calibration block on their page (`Ankole.Brain.Calibration` owns the
   Brier calculation shared with the expert directory).
6. **`contradictions`** evaluates newly paired claims sharing a page, holder,
   and `audience_scope` at most once per pair: high-confidence contradictions
   open triage rows, all other verdicts are stored as `dismissed`, and operator
   decisions (`resolved` or `dismissed`) apply only to `open` rows under a row
   lock.
7. **`schema_suggest`** counts recurring tags and subtypes, proposing a subtype
   at 20 pages and a page type at 100 pages. Console approvals and rejections
   persist as audit rows; approving a promotion registers the schema entry and
   migrates matching pages and slug references in one tenant transaction while
   keeping canonical `people/<uid>` Human Principal pages at their reserved
   slugs.
8. **`merge_suggest`** acts as the mechanical backstop behind write-time entity
   dedup, pairing live pages of the same type that share a normalized alias into
   `brain_merge_suggestions` (at most one row per pair permanently). Merges
   never run automatically: when an operator approves a pair in the Console, one
   transaction snapshots the canonical page in `brain_object_versions` (when the
   duplicate carries prose), strips generated calibration fences from the
   duplicate body, appends any non-blank duplicate prose onto the canonical body
   ahead of any canonical calibration scorecard, repoints claims, holders,
   timelines, aliases, tags, and links, reconciles canonical chunks and body
   edges, and converts the duplicate into a slug redirect, while refusing
   canonical Principal pages, library pages, and media-primitive pages.
9. **`purge`** permanently deletes soft-deleted pages whose retention TTL has
   expired.
10. **`skill_lessons`** runs Skill lesson maintenance; see
    `docs/design-docs/SkillLessons.md`.

On a separate cron schedule, **self-healing** embeds pending chunks and claims,
repairs missing projections, reports drift, and reconciles body-owned wikilink
and alias-mention edges mechanically without invoking a model. Link
reconciliation tracks its own `links_extracted_at` watermark independently of
`timelines_extracted_at`, deleting only stale edges with body provenance while
preserving manual or learned links and keeping existing edge IDs for unchanged
links.

Content edits advance an Object's logical `updated_at` timestamp: editing `body`
triggers both link reconciliation and timeline extraction, editing `title`
triggers timeline extraction (because the prompt includes the title), and
editing other metadata carries already completed watermarks forward without
marking earlier pending `body` or `title` work complete. Projection-only updates
leave `updated_at` unchanged, and creating a new target page or alias later does
not invalidate already reconciled body watermarks unless explicit reconciliation
reruns. Time decay writes nothing to disk: `recall` computes decayed Fact
confidence on read from `brain.forgetting`.

All background Brain model calls are stateless, tool-free, and history-free:

- Grading, contradiction detection, and pattern synthesis receive claim dates,
  context, attribution, and provenance (with grading additionally receiving the
  Take's time window and restricting evidence to `world` or the Take's own
  `audience_scope`).
- On-demand `synthesize` receives claim IDs, pages, holders, qualifying
  `context`, decayed Fact `effective_confidence` or Take `weight`, and open
  contradictions whose counterpart claims fall inside `world` or the synthesis
  scope while satisfying the caller's access and disclosure bounds, keeping Fact
  validity intervals separate from Take periods, surfacing contested points and
  open gaps, and reconciling `[[slug]]` wikilink and `derived_from` edges on the
  resulting analysis page.
- Every call tags AIGateway traces with a phase-specific `brain.*` caller so
  operators can inspect prompts and completions in Langfuse.

## Configuration

Operator settings are declared under `brain.*` `AppConfigure` keys:

- **Site keys:** `embedding_model` (with dimensions) and `search_tokenizer`.
- **Tenant keys** (inheriting site defaults when unset): `enabled`,
  `maintainer_agent_uid`, `rerank_model`, `chunking`, `forgetting`,
  `soft_delete_retention_hours`, the Dreaming
  and self-healing cron expressions, `signal_channel_batch_idle_time`,
  `skill_learning_enabled`, and `skill_learning_reflection_threshold`.

Brain delegates model profiles to the configured maintainer Agent (using `light`
for Signals and Source extraction, `heavy` for Dreaming, and `web_fetch` for URL
Source learning), so the Brain Console settings page links directly to that
Agent's model-profile editor rather than duplicating those three selectors.
Embedding and rerank models remain on the Brain settings page because they serve
shared retrieval rather than an Agent loop, though every Brain model call
(including embedding and rerank) executes as and bills usage to the maintainer
Agent. If the maintainer Agent is disabled, Brain reports unhealthy and halts
all model calls and control-plane URL fetches until an active Agent is restored
or selected, while keeping stored pages and lexical recall available.

`brain.forgetting` contains the five per-kind half-lives in days. The separate
`brain.soft_delete_retention_hours` setting controls how long soft-deleted Objects
remain eligible for restoration before Dreaming permanently removes them.
Reducing it can make existing Objects immediately eligible at the next purge.
The workspace editor shows the shared site embedding model and tokenizer as
read-only dependencies, and displays the effective scheduler timezone without
changing Pod-administrator permissions.

## Retrieval index recovery

Brain requires `pg_search` `0.25.11`, which is pinned in the development and
Compose PostgreSQL images; external PostgreSQL deployments must install and load
that exact extension version (see the
[database image upgrade procedure](../../tools/devkit/postgres-for-ankole/README.md)).

PostgreSQL base tables hold all authoritative Brain records, while
`Ankole.Brain.SearchIndexes` manages BM25 and HNSW index DDL and repairs
missing, invalid, or unready indexes. Because PostgreSQL catalog flags can still
mark an index valid when its native `pg_search` reader fails at query time,
`recall` surfaces the error for operator recovery rather than silently returning
empty results or bypassing the knowledge boundary.

The one-minute site Tick checks the saved tokenizer against actual BM25 index
definitions and usable flags before scheduling workspace work. The Console and
Brain health page expose `pending_rebuild`, `rebuilding`, `applied`, `failed`, or
`unknown` from that lifecycle. Reads perform no DDL. A tokenizer change is applied
by this maintenance path; rebuilding can interrupt retrieval and block writes.
Failed Tick jobs are recorded in server logs and retried by Oban. Running
`Ankole.Brain.SearchIndexes.ensure_current/0` from the release console performs
the same check and repair for manual operator recovery.

When a BM25 index reader fails, identify the affected index from the failing
query, confirm that the underlying base table is readable, and rebuild the index
during a maintenance window:

```sql
REINDEX INDEX public.brain_claims_bm25_idx;
-- Use brain_chunks_bm25_idx instead if the failing query reads brain_chunks.
```

`REINDEX INDEX` leaves base table rows untouched but may block concurrent
writes while rebuilding. Retry the failed `recall` afterward; if it still fails,
preserve the error output and verify the loaded `pg_search` library version
rather than resetting the database or bypassing access filters.

## Console

The Console `Brain` section provides object browsing with version history and
rollback, claim inspection and manual Take resolution, Source management
(register, learn now, archive), contradiction triage, duplicate-page merge
review, per-Principal knowledge audits, Principal-scoped search previews, health
counters, and the full-page Markdoc Object editor described in
[`BrainMarkdoc.md`](BrainMarkdoc.md). When loading a subsequent page of a
paginated Console list fails, already loaded rows remain visible above an
inline error and **Retry** button that fetches and appends the failed page.

### Resource write contracts

Every Brain table is backed by an Ash resource in the `Ankole.Brain` domain:

- `Object` actions separate user content edits (guarded by `content_hash`),
  Source projections (guarded by `managed_by_source_id`), ownership transfers,
  and maintenance watermarks (which never advance `updated_at`).
- `Source` actions keep upstream identity immutable, preserve initial facts on
  registration retries, and reject sync or extraction commits once archived.

`Ankole.Brain` is the domain façade. Resource reads go through Ash queries and
domain defines, and every multi-step write opens `Repo.transact_top_level/2`,
locks its target rows, composes its write steps, and commits atomically:

| Module | Operations |
|---|---|
| `Objects` / `Chunks` / `Links` | `create_object`, `update_object`, `upsert_source_projection`, `upsert_library_projection`, `soft_delete_object`, `rollback_object`, `fork_library_page`, `restore_object`, `reconcile_chunks`, `reconcile_object_links` |
| `Claims` | `write_fact`, `supersede_claim`, `expire_fact`, `deactivate_take`, `resolve_take`, `attach_claim_embedding`, `consolidate_facts` |
| `Sources` | `archive_source`, `update_source_default_scope` |
| `Promotion` / `Merge` / `Dreaming` | `approve_promotion`, `reject_promotion`, `approve_merge`, `reject_merge`, `decide_contradiction` |

`AnkoleWeb.JSONAPI.ConsoleRouter` mounts the `json_api` routes of `Ankole.Brain`
at `/api/v2/brain`. Resource listings run `:console_list` read actions returning
up to 100 rows, while Console mutations invoke generic actions on the target
resource (`console_create`, `console_update`, `fork_library_page`,
`console_rollback`, `console_forget`, `restore_object`, `console_supersede`,
`console_resolve`, `decide`, `console_approve`, `console_reject`,
`archive_source`, and `update_default_scope`) with the session Principal as the
Ash actor (`Ankole.Brain.Console`), delegating to the same domain functions and
`_in_tx` steps. Missing targets return HTTP 404; state conflicts
(`content_hash_conflict`, `object_deleted`, `slug_taken`, and `conflict`) return
HTTP 409; and all other domain rejections return HTTP 422 with the domain reason
as the error code.

`Ankole.Brain.ConsoleViews` exposes stateless Console views using
`Ash.DataLayer.Simple` without opening outer transactions of its own: health
snapshots, Object detail pages (passing `slug` as a query parameter so `/` slugs
work), page-type catalogs, Principal-scoped search previews (enforcing both
knowledge and disclosure boundaries), operator Principal audits (exposing full
claim detail), and manual Dreaming triggers. The Brain operations that those
views call own their own transactions.

Background pipelines likewise execute top-level writes through
`Repo.transact_top_level/2` in their owning modules: `Calibration.grade_takes/0`,
`Forget.forget_claim/3`, `Timelines.write_timeline/3`, `Patterns.run/0`,
`SourceLearning.learn/1`, `OIDCClientLearning.learn/1`,
`ConversationsLearning.process_conversation/1`, `LibraryKnowledge.sync/1`, and
`SchemaPacks.install_packs/1` (while tenant creation and initial setup call
`SchemaPacks.install_packs_in_tx/1` inside their enclosing transaction).

When `ConversationsLearning` commits a slice of memory items in one transaction,
validation runs before each item's first SQL write so an invalid item can be
skipped without aborting valid siblings. By contrast, `write_fact` locks and
re-reads its semantic-dedup target before inserting: if a concurrent writer
already superseded or expired that target, `write_fact` reruns the dedup lookup
against the replacement so two current Facts never commit side by side, and if
marking the superseded Fact fails after insertion (or if chunk reconciliation
fails after inserting a timeline event), the helper rolls back the caller's
transaction.

Every top-level Brain entry point rejects calls made inside an already open
transaction, while intra-domain composition helpers (`Objects.create_object_in_tx/1`,
`Chunks.reconcile_in_tx/1`, and peers) refuse to run outside a transaction. Both
`write_fact` and `supersede_claim` fetch new claim embeddings over the network
before opening a database transaction so connections never sit idle waiting on
network I/O.

In Ash queries, `Access` and `LazySkillVisibility` compose resource filters over
the `Claim` calculations `current?`, `live_parent?`, and
`current_external_fact?` and the `object` relationships on `Chunk` and
`Timeline`, while cross-domain reads (Conversations, Messages, Participants,
Signals, Principals, Agents, Jobs, and Agent Skills) go through their owning
domains' interfaces.

Multi-table analytical, retrieval, and DDL operations that do not project a
single Ash resource stay in Ecto or raw SQL and are explicitly allowlisted in
`app/control_plane/test/ankole/persistence_boundary.exs`:

- **Read models (M4):** Dreaming bucket and vocabulary counts, the
  duplicate-page alias scan, and `ConversationsLearning.known_pages/1` (Objects
  and ranked aliases).
- **Retrieval (M9):** candidate, graph-boost, and neighborhood queries in
  `Recall` plus the cosine Fact-dedup lookup in `Claims` (which select IDs and
  scores before loading full `Claim` and `Chunk` rows through Ash; the Ecto
  filter helpers `Claims.filter_live_parents/1`, `Claims.current_external_facts/1`,
  and the Ecto forms of `Access` and `LazySkillVisibility` exist solely for
  these M9 queries).
- **Set maintenance (M8):** page-merge foreign-key repointing statements and
  site-scoped index DDL in `SearchIndexes`.

Every Brain aggregate, Ash action, row lock, and native SQL query executes
through `Ankole.Repo` inside the calling process's tenant context and dynamic
repository; Brain callers cannot inject an alternate `Repo`. Links, tags,
aliases, and timeline rows preserve their native idempotency keys, merge
reparent actions deduplicate and repoint foreign keys while holding both Object
locks so the merge, slug redirect, and review verdict commit together, and
vector and BM25 queries use native PostgreSQL operators directly.
