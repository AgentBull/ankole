# Brain deployment and operations

Brain keeps chat recall, curated knowledge, dreaming cursors, and audit records
in the same PostgreSQL database as the control plane. Markdown returned by
`memory_open` is a projection; it is not a second store to back up or repair.

## PostgreSQL prerequisites

Use PostgreSQL 18 with the `pg_search` and `vector` extension packages
installed. `pg_search` must be in `shared_preload_libraries` before the server
starts. A configuration reload is not enough after changing this setting;
restart PostgreSQL.

Run these checks against the exact database server used by `DATABASE_URL`
before migrations:

```sql
SHOW server_version_num;
SHOW shared_preload_libraries;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

`server_version_num` must be at least `180000`, both extension packages must be
available, and the preload list must contain `pg_search`. The application
migration runs `CREATE EXTENSION IF NOT EXISTS` for both extensions and creates
the BM25 indexes. Verify the installed state afterwards:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_search', 'vector')
ORDER BY extname;
```

Do not substitute PostgreSQL full-text search or an external vector database
when an extension is unavailable. That would change Brain's transactional and
degradation guarantees.

## Create, rebuild, and migrate

For local development, the devkit image already contains both extensions and
starts PostgreSQL with `shared_preload_libraries=pg_search`:

```sh
bun run services:start
```

Ankole has not shipped a Memory-to-Brain compatibility migration. A local
database whose original Memory migration was already recorded must be rebuilt;
editing the old migration file does not make Ecto rerun that version:

```sh
bun run kit app-db rebuild --yes
```

This command is destructive. Back up any data that matters first. A fresh
installation, or a database that already has the Brain schema, should keep its
data and apply only pending migrations:

```sh
bun run kit app-db migrate
```

For releases and Helm deployments, check the PostgreSQL server first, take a
backup, then let the control-plane migration init container run once before the
new control plane starts. Never point old and new control-plane versions at the
same database during this unreleased schema replacement.

## Model profiles

Model selection is PostgreSQL-backed runtime configuration. Configure provider
rows and agent ModelProfiles through the console; do not put model ids or API
keys into Brain environment variables.

| Profile | Required for | Policy |
| --- | --- | --- |
| `primary` | Normal agent turns that call `memory_*` tools | Required for the agent's normal work |
| `light` | Dreaming stage A episode summarization | Required on the global `brain.dreaming.model_agent_uid` |
| `heavy` | Dreaming stage B knowledge consolidation | Required on each enabled principal's scoped model owner |
| `embedding` | Episode, knowledge-block, and query vectors | Required on the global `brain.dreaming.model_agent_uid`; failures remain visible and BM25 continues |
| `rerank` | Optional search reranking | Configure only when `brain.search.rerank_enabled=true` |

Set the global `brain.dreaming.model_agent_uid` to one model owner with `light`
and `embedding` profiles. Stage A, block indexing, and query embeddings all use
that same owner so stored and query vectors are comparable. For each principal
whose stage B is enabled, configure its scoped `brain.dreaming.model_agent_uid`
with a `heavy` profile; it may be the same owner. Missing profiles are an
explicit unavailable state: cursors must not advance as if work succeeded. If
reranking is enabled, `brain.search` must also name a model owner with a
`rerank` profile.

## Stage B budgeting and cursor safety

Stage B uses the scoped `heavy` profile twice per participating store. A
locator first reads episode summaries plus a bounded preview index and selects
a chronological material prefix and topic queries. Brain then retrieves the
related current knowledge projections and sends only that selected prefix's
full originals to the curator. Public and DM stores remain separate model
calls.

When `brain.dreaming.token_limit` is non-zero, it covers the exact serialized
inputs plus the configured output reservation for every locator and curator
call in the run, across all stores. A run commits only the complete global
material prefix actually sent to curators. Anything excluded by the locator or
budget remains behind the principal high-water marks for a later run. Invalid
locator output, model failure, insufficient budget, or mutation failure leaves
the cursor unchanged. `0` keeps the documented unlimited behavior.

## Operational checks

The current knowledge state lives in `brain_entries`, `brain_entry_blocks`, and
`brain_entry_relations`. `brain_audit_log` is append-only recovery evidence;
normal retrieval never reads it. `brain_cursors` shows stage A channel progress
and stage B principal progress. `brain_episodes` is the chat navigation index.

Useful checks:

```sql
SELECT owner_uid, store_key, name, type, lock_version, updated_at
FROM brain_entries
ORDER BY updated_at DESC;

SELECT owner_uid, store_key, author_kind, embedding_state, count(*)
FROM brain_entry_blocks
GROUP BY owner_uid, store_key, author_kind, embedding_state;

SELECT scope_kind, scope_key, cursor_entry_observed_at, unavailable_reason, updated_at
FROM brain_cursors
ORDER BY scope_kind, scope_key;

SELECT actor_kind, action, entry_id, block_id, before, after, inserted_at
FROM brain_audit_log
ORDER BY inserted_at DESC
LIMIT 100;
```

The Console Knowledge list searches names, aliases, summaries, and blocks and
uses stable cursor pagination; filters never turn into an unbounded table scan
in the browser. Its **Review audit** page can filter by store, action, actor,
dreaming run id, and date. Batch recovery is deliberately preview-first: select
the exact audit rows, confirm them, and the server applies their inverse actions
newest-first in one transaction. A concurrent change to any affected field
causes the whole selection to fail with a conflict instead of overwriting newer
work. Use the dreaming run-id filter to inspect and, when needed, reverse one
bad run without treating the audit log as a versioned knowledge source.

An operator may trigger one synchronous stage B pass through the public facade
inside a release:

```sh
/app/bin/ankole eval 'IO.inspect(Ankole.Brain.run_dreaming("agent-uid"), limit: :infinity)'
```

The expected terminal status is `:completed` when new material was committed or
`:no_new_material` when the principal cursor was already current. Do not move a
cursor manually to hide a failing model or invalid mutation.

`memory_health_check` is the read-only opening step of a human-requested review,
not a periodic repair job. Human decisions should be applied through the same
structured Brain operations used by agents so lock versions and audit snapshots
remain intact.

## Dedicated real-model acceptance

The Brain suite is deliberately outside the default test gate and outside
`tools/e2e/run --all`:

```sh
OPENROUTER_API_KEY=... tools/e2e/run --brain-real-llm
```

Focused reruns use ExUnit tags, for example:

```sh
tools/e2e/run --brain-real-llm --only brain_dm_isolation
tools/e2e/run --brain-real-llm --only brain_dreaming_idempotence
tools/e2e/run --brain-real-llm --only brain_retraction
```

Fake Feishu replaces only the difficult-to-automate client. The suite still
uses the real Lark transport, SignalsGateway ingress, ActorRuntime, Docker
worker, OpenRouter model, Brain RPC, PostgreSQL transaction, outbox dispatch,
and platform mirror. It asserts model tool journals, structured database state,
audit recovery data, and succeeded outbox rows; it does not snapshot prompt
wording.

When a run fails, classify the first broken boundary before changing the test:

1. PostgreSQL package/preload/migration failure;
2. provider or model-profile unavailable;
3. ingress, actor placement, or stale worker image;
4. model tool choice or Brain RPC rejection;
5. database invariant, cursor, or audit mismatch;
6. outbox/provider delivery failure.

Provider transport and quota failures are external blockers, not evidence that
a database assertion should be weakened.
