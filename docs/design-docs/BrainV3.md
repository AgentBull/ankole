# Brain

Brain derives searchable facts, timelines and typed relationships from Pod content and conversations. Humans and Agents maintain shared knowledge in Pod. PostgreSQL owns the documents, their history, authorization, claims and graph; the Rust kernel supplies stateless parsing, chunking and ranking primitives.

## Knowledge pages and identity

`Brain` is an independent top-level knowledge root, with `system_key = ankole_brain`. Its visible first-level directories correspond to installed `brain_schema_types.slug_prefix` values and are maintained by schema installation and promotion. The internal `ankole_brain_sources` anchor is hidden from the UI and Drive. Active members and Agents can read the Brain root by default; Pod administrators manage it. Personal assistant identity pages stop permission inheritance and grant access to the owner and assistant. Skills and runtime contracts belong to the Library domain and have their own tables.

The immutable identity of a knowledge page is `pages.id`, a UUIDv7. `pages` owns its parentage, content type, ACL anchors, title, revision, business `metadata` and system `upstream_state`; `page_contents` stores Page XML. The knowledge editor presents semantic Markdown content separately from YAML frontmatter metadata. The kernel converts XML and metadata to and from OKF Markdown, including nested metadata, code, tables, page mentions, images and attachments.

`Ankole.Pod.Knowledge` owns each atomic knowledge save. A caller supplies the current `base_revision`, XML and metadata; a stale revision returns a conflict with the current page. A successful save updates content and metadata together and appends a `PageSnapshot` in the same transaction. Knowledge snapshots are exempt from the document checkpoint throttle and age-based expiry. Restore creates a new revision. Pod owns rename, move, sharing, trash and restoration.

Principals owns internal identity paths (`people/<uid>` and `agents/<uid>`). Renaming a display title does not rename that path. Content edits preserve the identity fields. Disabling a Principal marks its profile `metadata.archived = true` in the same transaction; enabling it removes that marker. Disabling or restoring a member also updates their assistant's profile. Archived profiles retain their content, UUID and graph references and remain available as historical evidence.

Brain reads `brain_page_nodes`, a read-only view over those Pod records. `Brain.Objects` resolves paths, aliases and names and composes internal writes through the Pod owner. Brain resolves relative paths from the independent Brain root and addresses pages elsewhere by their immutable IDs. Pod preserves page IDs when users rename or move pages. When a page leaves a path under `Brain`, Brain records that prior path in `brain_slug_aliases`; changes in other spaces cannot replace those redirects. Graph edges, claims, timelines, tags and aliases continue to reference the same UUID without rewriting every dependent row.

Creating an entity requires an unused destination path. Automatic learning resolves existing page IDs, paths, titles and aliases before creating an entity, preserving the existing document and metadata. Name-based reuse also checks the entity type, so a report and a company with the same name keep separate identities. New automatic entity pages use the installed type's directory and contain identity metadata; their assertions keep the originating source. Writers update a page through the knowledge save contract using its current revision. Ankole preserves business metadata as entered; Brain projects `effective_date` only when the value is a valid ISO calendar date.

`brain_links` retains typed relationships through `from_page_id`, `to_page_id`, `link_type`, `link_source` and `origin_page_id`. Page mentions and metadata references produce `references` edges. Model analysis can produce semantic edges such as `derived_from`. A merge reparents the merged page's relations and children in one transaction. Brain redirects its known paths under `Brain` to the surviving page.

## Atomic knowledge and authorization

`brain_claims` holds Facts and Takes; `brain_timelines` holds dated events. Every row has a required `source_node_id` and an optional `subject_page_id`. A conversation fact can have no entity subject while retaining the conversation root as its permission source. Source and subject are separate: attaching a private assertion to a public entity does not publish the assertion.

A member-held Take records the Principal's canonical Page UUID as `holder`;
`world` and `brain` identify the two shared holders. Session memory writes,
Principal audits and retrieval diversity use this same identity. Live-claim
queries exclude a deleted source Page as well as a deleted subject Page.

Brain uses the current Page authorization graph. For each reader, the graph supplies separate `self_bits` and `container_bits`. A live non-anchor node is visible when its anchor appears in the reachable containers; an anchor node is visible when its own ID appears in the reachable pages. This distinction preserves single-page sharing, inheritance changes, moves and trash behavior.

For a human request, Brain intersects the requester and Agent's reachable bits before issuing candidate queries. Strict rooms also intersect every present recipient; unattended work uses the Agent's own rights. Both retrieval candidate limits and knowledge panels apply this same predicate. Revoking a source grant changes subsequent reads immediately, including reads of already extracted claims. Global Agent contracts are loaded as the Agent itself; their access contract is specified in [Agent Workers](AgentWorkers.md).

Facts preserve provenance, effective dates and optional qualifying context. Confidence follows the supported weight grid. Semantic deduplication compares only current facts with the same nullable subject, the same source node and the same embedding signature. Sources with identical current readers still remain distinct. Superseding an assertion inserts the replacement and marks the prior row in one transaction. Takes preserve their holder, weight, prediction period and immutable resolution result. Timeline deduplication also includes the source node, including for events with no subject.

The Pod knowledge panel computes visible claims, timelines, backlinks and calibration scores at read time. A claim or timeline appears on its subject page and its source page, with the same source permission filter in both places. An empty scorecard has no Brier score. Users edit the page in Pod and can inspect its knowledge alongside the content without copying projections into the document.

`Ankole.Brain.Browser` projects the workspace ontology graph for `/meta/brain` under the caller's live Page authorization predicate. The response pairs each visible ontology category (`entity_type` and `primitive` from `brain_schema_types`) with visible Brain objects (`subtype` and nearest visible `parent_id`, skipping unreadable intermediate nodes) and deduplicated directed edges across five relation kinds: `hierarchy` (`contains`), `ownership` (`assists` and `owned_by` from Principal records), `semantic` and `reference` (`brain_links`), and `evidence` (`evidences`, `holds_take` and `involves` derived from authorized current claims and timelines). Pod renders this projection through `@ankole/uikit/components/graph` (`@antv/g6`) with network, hierarchy, category-combo and radial layouts alongside interactive entity and relation layer filters.

## Retrieval and progressive reads

Brain indexes live business content in its own knowledge tree and supported documents, Bases and applets in Space. Private and conversation roots do not enter the public document index; their atomic assertions and timeline passages retain their own source visibility. Skill packages and Agent contracts remain outside this index.

`brain_chunks` is a rebuildable projection keyed by page ID and chunk position. Each row records its source Page, optional subject Page, page revision and chunking signature. Body chunks use their Page as the subject; timeline chunks copy the timeline’s explicit subject, including an absent subject. Page type and body emptiness do not imply a timeline subject. Reconciliation locks and rereads the current page. When text, content kind, source and chunking signature match at the same position, reconciliation advances the page revision and preserves the vector and its model signature. A change to those inputs invalidates the embedding. A delayed embedding response only commits if the input revision, chunking signature, text and prior embedding state still match. Model-signature filtering excludes obsolete vectors while self-healing computes replacements.

`recall` combines BM25 lexical candidates with vector candidates using reciprocal-rank fusion. Vector search selects HNSW candidates from the first 4,000 dimensions and orders them by full-vector distance. Brain applies source visibility before candidate limits, caps chunks to two per page before optional reranking, then applies fact decay, lexical recency and salience, and graph adjacency. Provider reranking timeouts fall back to fusion scores. Results pack claims, entity cards and excerpts in that order. Brain measures the serialized JSON response, including provenance and envelope fields, with the kernel's `o200k_base` tokenizer. It skips entries that do not fit rather than clipping their evidence or qualifications. An empty result still includes the response envelope.

`Pod.Knowledge` owns the reading-depth projection used by Pod and Brain knowledge reads. L0 returns page identity, revision and a summary of at most 100 `o200k_base` tokens. L1 returns core metadata, an introduction preview with a 400-token content budget and an explicit shortening notice when needed, every H2 heading and visible child summaries. L2 returns complete OKF Markdown with metadata. A full parent read includes visible child summaries instead of recursively concatenating child documents. `entity` adds the live knowledge panel to the page overview. Background Jobs materialize their admitted Skill packages from the Library tables through the Worker skill contract.

`context_pack` and volunteer pointers assemble bounded ambient memory. Stateful turns reuse the opening injection; compaction builds a fresh pack from the current task. Unexpected ambient-memory errors emit a warning and return an empty injection without aborting the user's turn. Explicit retrieval errors remain visible to callers and operators.

Search results for ordinary Pod document chunks have no `subject_page_id`.
Console accepts that nullable field while retaining the source Page identity.
Scalar retrieval and maintenance queries select the fields they consume;
vector similarity operations load embeddings when their calculation needs them.

## Tools and learning

Conversation and source extraction distinguish useful assertions from subjects worth a separate page. Both receive mentioned page identities matched by title and alias, plus the installed type vocabulary and its meanings. Brain reuses existing identities, leaves ambiguous subjects empty, and preserves useful assertions even when they need no entity page. Prompts distinguish continuing projects from one-off tasks, procedures from their versions, and actual artifacts from proposed work. They retain speaker attribution and distinguish plans, suggestions and queued actions from observed outcomes.

Brain extracts substantive research conclusions, business outcomes, decisions, commitments, preferences and reusable knowledge. Routine assistant progress, completion, delivery, formatting and validation messages stay in the source history. A source containing only such execution activity produces no derived assertions or entities. When execution messages accompany useful material, Brain extracts the useful material, including business acceptance, human commitments and reusable tool limitations.

A report retains its own page, complete content, history and permissions. Extraction assigns each assertion to the entity it describes, reusing or creating that entity as needed, while keeping the report's ID as `source_node_id`. Assertions about the report itself can use the report as their subject; an unidentified speaker's assertion can have no subject. Reading a company page reveals report-derived assertions only to readers who can read that report. Relearning the report replaces its own automatic assertions regardless of which companies they describe.

The `brain` tool provides `remember`, `recall`, `entity`, `whoknows`, `synthesize`, `delta` and `write_object`. An object write specifies an installed category and title for creation, or an object UUID for revision, plus Markdown and `base_revision`. A writer whose Agent and requester both have edit rights saves through `Pod.Knowledge`. Otherwise the tool returns a concrete native Action Card proposal: `brain.object.create` or `pod.knowledge.save`. An authorized human approves the change; revision conflicts preserve the newer content. The Worker projection `/drive/Brain` is read-only.

`remember` defaults its source to the current conversation. It can attach a claim to an existing entity or leave its subject empty. Its result includes the claim and source IDs and a JSON string status (`inserted`, `duplicate` or `superseded`) for conversation history and model continuation. `whoknows` ranks colleagues from visible evidence. `delta` lists facts and events changed during a requested period. `synthesize` retains the recalled evidence and creates an analysis page whose initial reader set is contained in the intersection of all evidence readers; it records typed evidence links and marks the page as generated analysis. Brain converts dates and timestamps in recalled evidence to ISO 8601 JSON strings before requesting the analysis.

`SourceLearning` extracts outside the write transaction and checks the source revision again while committing. A changed or deleted page, or a page moved outside the eligible extraction paths, rejects a late result. Registered Source runs and page extraction share `upstream_state.facts_revision`. A committed revision is extracted once; a later page revision replaces earlier automatic facts from that source without expiring manually recorded facts. Source synchronization state remains in `upstream_state`, outside exported business metadata. If every extracted item fails validation, the transaction rolls back and the source remains retryable.

Automatic fact extraction applies to business knowledge and explicitly opted-in content. Generated synthesis pages are excluded. Library-owned Agent contracts and Skills are outside the Page extraction pipeline. Brain object creation derives `metadata.entity_type` from the installed ontology category; Principal lifecycle operations own the internal people and Agent objects. A business Page's manager can enable learning from Pod; setting `metadata.extract_facts: true` schedules existing eligible content throughout that subtree. Moving a Page schedules extraction for eligible content in the moved subtree. Page extraction commits hold a shared Page tree lock while checking the current revision and extraction eligibility, so a Page setting change or move cannot race that decision. Disabling learning stops future extraction and rejects queued commits unless another ancestor still enables it; previously extracted facts remain. Conversation learning uses the conversation root as the source. Source adapters retain their upstream identity and revision; archive rejects later extraction commits. Ordinary trash removes chunks and expires or deactivates claims sourced by the deleted subtree. Restoration rebuilds searchable passages immediately and schedules eligible pages for fresh fact extraction.

Dreaming consolidates assertions, evaluates Takes, detects contradictions and proposes schema promotion or entity merges for review. It writes source-specific pattern pages in Brain's `analysis` category and delegates their visibility to the source Page. Source ACL changes therefore apply to later reads, and private conversation evidence stays private. Timeline extraction stores its processed page revision in `upstream_state`; changed pages are reconsidered. Background learning does not rewrite Agent contracts or skills. Self-healing reconciles stale page/chunk revisions and rebuilds missing or obsolete vectors. Brain background writes publish tree/content invalidation after the outer transaction commits, so open views and `/drive/Brain` refresh the committed content.

## Configuration

Operator settings are declared under `brain.*` `AppConfigure` keys:

- **Site keys:** `embedding_model` (with dimensions) and `search_tokenizer`.
- **Tenant keys** (inheriting site defaults when unset): `enabled`, `chunking`,
  `forgetting`, the Dreaming and self-healing cron
  expressions, `signal_channel_batch_idle_time`, `skill_learning_enabled`, and
  `skill_learning_reflection_threshold`.

Brain model, embedding, and rerank calls execute as the tenant's `ankole_brain`
system Principal. Extraction uses effective `light`, Dreaming uses effective
`heavy` with a `primary` fallback, URL Source learning uses effective
`web_fetch`, and reranking uses effective `rerank`, including Agent-initiated
recall. Model profiles merge each slot across `ankole_brain -> Pod -> Site`
before applying cross-slot fallbacks, as documented in [AIGateway](AIGateway.md).
A Pod configured with only `primary` can run extraction and Dreaming without an
Agent; embedding, URL fetching, and reranking require specialized configuration.
Operators edit Brain's overrides in the `ankole_brain` editor on Console
`/model-profiles`. The Brain settings page links each dependency to that editor.

Embedding uses the Site-level `brain.embedding_model`. Before saving a change
to its signature (Provider kind, model, or dimensions), the Console asks the
operator to confirm that self-healing will re-embed content in batches, old
vectors will be excluded from recall until replaced, and embedding calls will
incur usage costs. Changing Provider options or switching to another Provider
of the same kind with the same model and dimensions does not change the
signature. Confirmation saves the setting normally; signature-aware retrieval
and self-healing manage the transition.

Every Brain LLM call records usage with origin `brain` and does not consume an
Agent quota. Embedding and rerank do not write LLM ledger rows. Take grading and
automatic resolution store `ankole_brain`'s tenant-qualified ActorRef in
`graded_by` and `resolved_by`. Maintenance writes use the `:system` writer and
can write every authorized source node. Brain attributes its extracted facts, consolidated Takes,
timelines, and generated analysis pages to `ankole_brain`. Writes
performed on behalf of a human retain that human's attribution. Model execution
identity and audit attribution do not change the Drive permission rules.

`brain.forgetting` contains the five per-kind half-lives in days. Pod owns Page trash
retention and permanent removal for knowledge pages, using the same lifecycle as
other Pod content.

Explicit forgetting records the reason, caller and timestamp in the knowledge
Page's metadata and revision history in the same transaction as trashing it.
The transaction owner publishes tree invalidation after commit.

The workspace editor shows the shared site embedding model and tokenizer as
read-only dependencies, and displays the effective scheduler timezone without
changing Pod-administrator permissions.

## Retrieval index recovery

Brain requires `pg_search` `0.26.4`, which is pinned in Ankole's PostgreSQL
image source; external PostgreSQL deployments must install and load
that exact extension version (see the
[database image upgrade procedure](../../tools/devkit/postgres-for-ankole/README.md)).
Container deployments allocate 1 GiB of shared memory for parallel queries.
Operators size shared memory and the container memory limit for their query
concurrency. Prepared BM25 plans preserve bound source-node filters while returning
scored rows across index segments.

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

## Console and persistence owners

Console provides read-only knowledge browsing with links to Pod, claim inspection and Take resolution, Source management, contradiction triage, merge review, Principal audits, scoped search and health. Paginated failures keep loaded rows and offer retry. Pod owns document editing and history.

`Ankole.Brain` declares resources and cross-domain interfaces. Procedural owners compose Ash operations inside one `Repo.transact_top_level` transaction. Pod owns page content and snapshots; `Claims` owns assertion lifecycle; `Sources` owns upstream identity and archive state; `Links` owns typed relations and aliases. Source and page revision fences guard their respective commits. Stateless Console views and the Console promotion and merge review actions delegate transaction ownership to these domain entrypoints.
