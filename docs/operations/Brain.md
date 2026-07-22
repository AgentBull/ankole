# Deploy and Operate Brain

Brain stores current knowledge, external-source state, Dreaming progress, and
audit records in the control-plane PostgreSQL database. SignalsGateway stores
the original chat messages. The Console Brain status view is the one health
surface for both stores and processing pipelines.

## Prepare PostgreSQL

Brain requires PostgreSQL 18 with the `pg_search` and `vector` extensions.
PostgreSQL must preload `pg_search`. Check the server in `DATABASE_URL` before
you run a migration:

```sql
SHOW server_version_num;
SHOW shared_preload_libraries;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

`server_version_num` must be at least `180000`.
`shared_preload_libraries` must contain `pg_search`, and both extensions must be
available. Restart PostgreSQL after you change its preload setting.

The migration installs both extensions. Check them after migration:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_search', 'vector')
ORDER BY extname;
```

Do not replace these extensions with PostgreSQL full-text search or an external
vector database. Brain uses their indexes inside control-plane transactions.

## Apply the Brain V2 Clean Cut

The Brain V2 migration has no V1 conversion or downgrade path. It permanently
clears all Brain V1-owned tables before it installs the V2 schema. Back up any
information that you must keep before you migrate. Do not add a compatibility
read for V1 store names.

The local Devkit PostgreSQL image has the required extensions:

```sh
bun run services:start
bun run kit app-db migrate
```

If you choose to rebuild a disposable local database, this command deletes the
complete application database:

```sh
bun run kit app-db rebuild --yes
```

Back up required data before you run it. For a release or Helm deployment,
check PostgreSQL and take a backup first. Run the migration init container
before the new control plane starts. Do not run V1 and V2 control planes on one
database.

After migration, confirm the fixed shared Principal and the new stores:

```sql
SELECT uid, type
FROM principals
WHERE uid = 'brain-shared';

SELECT owner_uid, store_key, count(*)
FROM brain_entries
GROUP BY owner_uid, store_key
ORDER BY owner_uid, store_key;
```

Valid store keys are `shared`, `self`, `dm:<principal-uid>`, and
`channel:<channel-id>`. There is no `public` compatibility store.

## Configure Models

Configure model providers and Agent ModelProfiles in the Console. The database
stores model and provider choices. Do not put model IDs or API keys in Brain
environment variables.

| Profile | Use | Requirement |
| --- | --- | --- |
| `primary` | Normal Agent turns and `memory_*` tool selection | Required for Agent work |
| `light` | Stage A episodes and Stage B locator and curator calls | Required on the Agent that owns that work |
| `embedding` | All entry, episode, and query vectors | Required on the global embedding model Agent |
| `rerank` | Optional global search reranking | Required only when reranking is enabled |

Stage B uses the curated Agent's own `light` profile. Human and system
Principals cannot own a Stage B run. Stage A selects the
lexicographically smallest visible active channel member whose `light` profile
resolves. There is no `brain.dreaming.model_agent_uid` setting.

Configure one installation-wide vector space in the global `brain.embedding`
key:

```json
{
  "enabled": true,
  "model_agent_uid": "agent-uid-with-embedding-profile",
  "dimensions": 1024
}
```

Use the exact output dimensions of the selected model. Brain accepts 1 through
4,096. A missing Agent, profile, or dimension makes vector processing
unavailable and creates a status alert. PostgreSQL stores a zero-filled
`vector(4096)` envelope, so more than 4,096 dimensions needs a migration. The
HNSW shortlist uses the first 4,000 dimensions and the final order uses the
complete stored vector.

### Change the embedding model safely

Change the global setting first. The next block or episode embedding batch
calls `Ankole.Brain.Embedding.prepare_space/2`, which changes vectors from
another model space back to `pending`. Run the two embedding batches until
their pending counts reach zero:

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.embed_pending_blocks(500))'
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.embed_pending_episodes(500))'
```

Do not compare or keep vectors from two models or dimensions. Each synced row
records `embedding_model_agent_uid` and `embedding_dimensions`, and the status
view reports any stale rows.

Configure optional reranking through `brain.search`. Its model Agent must have
a `rerank` profile. Reranking is disabled by default so its provider call is
not on the normal recall path.

## Configure Runtime Policy

Brain registers five AppConfigure keys. The design document lists every field
and default. The main operator decisions are:

- `brain.embedding` selects one global vector space. It is disabled until an
  operator selects a model Agent and dimensions.
- `brain.search` sets the 30-day half-life, the `0.5` knowledge decay floor,
  and optional reranking.
- `brain.dreaming` can override enablement and microbatch limits for an Agent.
  Agents are enabled by default. Human and system Principals have no Stage B
  consumption surface.
- `brain.sources` enables connector polling, with a 15-minute default interval
  and a 1,500-token block limit.
- `brain.knowledge` sets the 1,500-token pinned memo budget and the default
  result limit of ten.

Stage B becomes eligible after its configured silence period or backlog count.
The defaults are 30 minutes or 50 rows. A `token_limit` or `mutation_limit` of
`0` means that no operator limit is set. A model, validation, budget, or commit
failure leaves its cursor unchanged.

## Read the Status Surface

Open the Console Brain status view for the Agent. The `memory_health_check` tool
uses the same query group, so do not operate a second review-candidate health
list.

The top-level status is `error` when at least one alert exists. Investigate the
first causal alert:

1. **Embedding configuration.** Fix a disabled, incomplete, or unresolved
   `brain.embedding` setting before you work on pending vector counts.
2. **Stale embedding space.** Regenerate rows whose model Agent or dimensions
   differ from the global setting.
3. **Stage A availability.** Check each channel processor and its `light`
   profile. A failed selection appears in `unavailable_reason`.
4. **Stage B availability.** Check the curated Principal's `light` profile and
   last successful run.
5. **Stuck curation.** Oban Lifeline rescues an executing Stage B job after 30
   minutes. Check retries and provider failures if the same Principal returns.
6. **Backlog or failed embeddings.** Fix the provider or profile, then run the
   affected batch again.
7. **Content discipline.** Resolve dated names, near duplicates, entries over
   200 projected lines, zero-body entries, an oversized pinned memo, and source
   or citation diagnostics through normal versioned Brain operations.

Read the same payload in a release shell when the Console is unavailable:

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.status("agent-uid"), limit: :infinity)'
```

Useful database checks are:

```sql
SELECT embedding_state, embedding_model_agent_uid, embedding_dimensions, count(*)
FROM brain_entry_blocks
GROUP BY embedding_state, embedding_model_agent_uid, embedding_dimensions
ORDER BY embedding_state, embedding_model_agent_uid, embedding_dimensions;

SELECT embedding_state, embedding_model_agent_uid, embedding_dimensions, count(*)
FROM brain_episodes
GROUP BY embedding_state, embedding_model_agent_uid, embedding_dimensions
ORDER BY embedding_state, embedding_model_agent_uid, embedding_dimensions;

SELECT scope_kind, scope_key, cursor_entry_observed_at,
       unavailable_reason, metadata, updated_at
FROM brain_cursors
ORDER BY scope_kind, scope_key;

SELECT state, worker, args, attempted_at, attempt, max_attempts
FROM oban_jobs
WHERE worker LIKE 'Ankole.Brain.Jobs.%'
ORDER BY inserted_at DESC
LIMIT 100;
```

Do not move a cursor by hand to hide a model or write failure.

## Run Maintenance Manually

Run one Stage B curation for a Principal:

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.run_dreaming("agent-uid"), limit: :infinity)'
```

A successful change returns `status: :completed`. No eligible new material
returns `status: :no_new_material`.

Run pending embedding batches:

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.embed_pending_blocks(500))'
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.embed_pending_episodes(500))'
```

Synchronize one registered connector source by its row UUID:

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.SourceSync.sync("source-row-uuid"), limit: :infinity)'
```

The generic connector runtime is present, but Ankole does not yet ship a real
Feishu document connector. Use this command only for a connector that the
installation has registered. Chat through the Lark adapter is independent of
document-source synchronization.

## Inspect Sources

Manual files have `capture_method = 'file'`. Their original bytes are immutable
and they require an explicit source-learning turn. Connector rows use their
connector ID as `capture_method`; they keep the current revision and current
exported body.

```sql
SELECT document_id, capture_method, connector_id, revision, sync_state, lock_version,
       title, source_url, byte_size, sha256, last_synced_at
FROM brain_retained_sources
ORDER BY inserted_at DESC;
```

A connector mirror is one read-only `external_document` entry in `shared`.
An unchanged revision only updates the check time. A changed revision with the
same content can update metadata without replacing blocks. Changed content
replaces the complete entry. A `deleted` or `access_lost` source withdraws it.
Do not edit mirror rows or remove the mirror property by SQL.

Concurrent syncs use the source row version read before connector I/O. A stale
result returns `{:error, :source_sync_conflict}` and does not change the source
or mirror. Scheduled jobs retry this error. Run the manual command again after
a conflict.

Pasted text and fetched URL text are ordinary editable entries; they are not
immutable connector snapshots.

## Review and Recover Knowledge

Use the Console audit view to filter changes by store, action, author, Dreaming
run, and date. Preview a batch recovery before you confirm it. The control plane
reverses selected changes from newest to oldest in one transaction.

If current knowledge no longer matches the recorded value, recovery returns a
conflict and changes nothing. Apply manual corrections through Brain operations
so version checks, citations, and audit records remain intact. Search never
uses audit rows as current knowledge.

When a provider removes a source chat message, Brain withdraws only changes
that still match their expected values and blocks with the exact source marker.
It never replaces a later edit.

## Scheduled Jobs

Oban runs frequent scans and applies eligibility gates inside them:

- Stage A eligibility: every five minutes.
- Episode embeddings: every five minutes.
- Block embeddings: every five minutes.
- Stage B eligibility: every minute.
- Connector source eligibility: every minute, with the configured source
  interval applied per source.

These are control-plane maintenance jobs, not user Schedule records.

## Run the Dedicated Acceptance Suite

The real-model Brain suite is not part of the default gate or
`tools/e2e/run --all`:

```sh
OPENROUTER_API_KEY=... tools/e2e/run --brain-real-llm
```

Run one case by ExUnit tag:

```sh
tools/e2e/run --brain-real-llm --only brain_dm_isolation
tools/e2e/run --brain-real-llm --only brain_unified_recall_ranking
tools/e2e/run --brain-real-llm --only brain_episode_paraphrase
tools/e2e/run --brain-real-llm --only brain_dreaming_convergence
tools/e2e/run --brain-real-llm --only brain_source_mirror_sync
tools/e2e/run --brain-real-llm --only brain_retraction
```

Fake Feishu replaces only the client UI. The suite still traverses Lark
transport, SignalsGateway, ActorRuntime, Docker Agent Computer, OpenRouter,
Brain RPC, PostgreSQL, and the outbox. The source mirror case uses the
documented deterministic fake connector because the real Feishu document
connector belongs to the next phase.

When a case fails, find the first failed boundary: PostgreSQL prerequisites,
model profiles, ingress and Actor placement, worker image, model tool choice,
Brain RPC, database transaction, or outbox delivery. A provider quota or
transport failure is an external blocker; it does not justify a weaker storage
assertion.
