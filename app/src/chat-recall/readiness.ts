import { genericHash } from '@agentbull/bullx-native-addons'
import { DomainError } from '@/common/errors'
import { match, P } from '@pleisto/active-support'
import { sql } from 'drizzle-orm'
import { DB } from '@/common/database'
import { appConfigService } from '@/config/app-configure'
import { resolveLlmProviderApiAccess } from '@/llm-providers/service'
import {
  ChatRecallConfigDefinition,
  embeddingProfileFromConfig,
  normalizeChatRecallConfig,
  type NormalizedChatRecallConfig
} from './config'

// Recall needs both a BM25 keyword index (pg_search) and a vector index
// (pgvector). Either one missing disables recall, so both are tracked.
export type ChatRecallExtensionName = 'pg_search' | 'vector'
export type ChatRecallWorkerState = 'not_started' | 'running' | 'paused' | 'stopped' | 'failed'

export interface ChatRecallExtensionStatus {
  name: ChatRecallExtensionName
  available: boolean
  installed: boolean
  version: string | null
  error?: string
}

/**
 * One snapshot of whether recall can run and why it might not.
 *
 * `enabled` is the single yes/no gate the search service and worker check; it is
 * true only when `disabledReasons` is empty. The reasons list is kept human
 * readable so the console can show an operator exactly what to fix (missing
 * extension, unconfigured provider, schema error, ...) instead of a bare boolean.
 */
export interface ChatRecallStatus {
  enabled: boolean
  disabledReasons: string[]
  extensions: Record<ChatRecallExtensionName, ChatRecallExtensionStatus>
  config: NormalizedChatRecallConfig
  embeddingProfile?: ChatRecallEmbeddingProfile
  schemaReady: boolean
  schemaError?: string
  worker: {
    state: ChatRecallWorkerState
    lastError?: string
  }
  stats: {
    documents: number
    embeddingBacklog: number
    embeddingSynced: number
  }
}

/**
 * A resolved embedding target plus its derived identity.
 *
 * `profileId` is a stable hash of the identifying fields (see
 * {@link chatRecallEmbeddingProfileId}). It tags every embedding row so that
 * switching provider, model, or dimensions starts a fresh set of embeddings
 * instead of mixing vectors from different models in one index.
 */
export interface ChatRecallEmbeddingProfile {
  providerKind: 'openai' | 'openrouter' | 'vllm'
  providerId: string
  model: string
  dimensions?: number
  batchSize: number
  concurrency: number
  indexStrategy: 'auto' | 'halfvec_hnsw' | 'binary_quantized_hnsw' | 'exact_only'
  profileId: string
}

export interface ChatRecallRuntimeStateSnapshot {
  workerState?: ChatRecallWorkerState
  workerLastError?: string
}

/**
 * Computes the full readiness picture for recall in one pass.
 *
 * Accumulates reasons instead of failing fast: the console wants to show every
 * problem at once, so a missing extension does not hide an unconfigured provider.
 *
 * @param options.install When true, this call may actively create the pg_search
 *   extension and recall schema/indexes. The plain status path leaves it false so
 *   that read-only status checks never mutate the database; only deliberate
 *   start/reindex flows pass `install: true`.
 * @param options.runtime The live worker state owned by the runtime singleton,
 *   folded into the status so callers see one combined view.
 */
export async function getChatRecallStatus(
  options: { install?: boolean; runtime?: ChatRecallRuntimeStateSnapshot } = {}
): Promise<ChatRecallStatus> {
  const config = normalizeChatRecallConfig(await appConfigService.get(ChatRecallConfigDefinition))
  const extensions = await ensureRequiredExtensions(options.install ?? false)
  const disabledReasons: string[] = []

  if (!extensions.pg_search.available) disabledReasons.push('pg_search extension is not available')
  if (!extensions.vector.available) disabledReasons.push('pgvector extension is not available')
  if (!extensions.pg_search.installed) disabledReasons.push('pg_search extension is not installed')
  if (!extensions.vector.installed) disabledReasons.push('pgvector extension is not installed')
  if (!config.vector.enabled) disabledReasons.push('vector search is disabled')

  const rawProfile = embeddingProfileFromConfig(config)
  const embeddingProfile = rawProfile
    ? { ...rawProfile, profileId: chatRecallEmbeddingProfileId(rawProfile) }
    : undefined
  if (!embeddingProfile) disabledReasons.push('embedding provider/model is not configured')

  // Schema/index creation needs both extensions present; skip it (and report a
  // not-ready schema) rather than letting the DDL fail when an extension is gone.
  let schemaReady = false
  let schemaError: string | undefined
  if (extensions.pg_search.installed && extensions.vector.installed) {
    try {
      await ensureChatRecallSchema(embeddingProfile)
      schemaReady = true
    } catch (error) {
      schemaError = errorMessage(error)
      disabledReasons.push(`chat recall schema is not ready: ${schemaError}`)
    }
  }

  // Verify the embedding provider credentials actually resolve. A configured but
  // unreachable provider would otherwise look enabled until the first real call.
  if (embeddingProfile) {
    try {
      await resolveLlmProviderApiAccess(embeddingProfile.providerId)
    } catch (error) {
      disabledReasons.push(
        error instanceof DomainError ? error.message : `embedding provider is not ready: ${errorMessage(error)}`
      )
    }
  }

  // Stats query joins the recall tables, so it is only safe once the schema is
  // confirmed ready; otherwise report zeroes.
  const stats = schemaReady ? await loadStats() : { documents: 0, embeddingBacklog: 0, embeddingSynced: 0 }

  return {
    enabled: disabledReasons.length === 0,
    disabledReasons,
    extensions,
    config,
    embeddingProfile,
    schemaReady,
    schemaError,
    worker: {
      state: options.runtime?.workerState ?? 'not_started',
      lastError: options.runtime?.workerLastError
    },
    stats
  }
}

/**
 * Creates the BM25 index and, when a profile is given, the matching vector index.
 *
 * Uses `CREATE INDEX IF NOT EXISTS`, so it is safe to call on every status/start
 * pass — it is the idempotent "make sure the schema exists" step rather than a
 * one-time migration.
 */
export async function ensureChatRecallSchema(profile?: ChatRecallEmbeddingProfile): Promise<void> {
  await DB.execute(sql.raw(CREATE_BM25_INDEX_SQL))
  if (profile) await ensureVectorIndex(profile)
}

/**
 * Builds the HNSW vector index that fits the profile's strategy and vector size.
 *
 * The index choice is driven by the 4000-dimension halfvec ceiling in pgvector:
 * within it, `auto` and `halfvec_hnsw` build a half-precision (16-bit) HNSW index
 * that halves index size at negligible recall cost. Above that ceiling, halfvec
 * cannot be indexed, so `auto` falls through to a binary-quantized HNSW index
 * (1 bit per dimension) used as a coarse prefilter, with the exact distance
 * re-ranked at query time. `exact_only` deliberately builds no ANN index and
 * relies on exact scans.
 */
export async function ensureVectorIndex(profile: ChatRecallEmbeddingProfile): Promise<void> {
  if (profile.indexStrategy === 'exact_only') return

  // For `auto`, the configured dimensions may be unknown; fall back to the
  // dimension count already present in synced rows so the index still matches the
  // vectors on disk.
  const dimensions = profile.dimensions ?? (await syncedDimensionsForProfile(profile.profileId))
  if (!dimensions) return

  // Suffix keeps one index per (profile, dimensions, strategy) so that changing
  // any of them creates a new index next to the old one instead of colliding.
  const indexSuffix = genericHash(`${profile.profileId}:${dimensions}:${profile.indexStrategy}`).slice(0, 16)
  const profileLiteral = sqlLiteral(profile.profileId)
  await match<[ChatRecallEmbeddingProfile['indexStrategy'], boolean]>([profile.indexStrategy, dimensions <= 4000])
    .with(['auto', true], () => createHalfvecIndex(indexSuffix, dimensions, profileLiteral))
    .with(['halfvec_hnsw', true], () => createHalfvecIndex(indexSuffix, dimensions, profileLiteral))
    .with(['exact_only', P._], () => Promise.resolve())
    .otherwise(() => createBinaryQuantizedIndex(indexSuffix, dimensions, profileLiteral))
}

/**
 * Builds a half-precision cosine HNSW index, scoped to one profile and dimension.
 *
 * The partial `WHERE` (synced rows of this profile and dimension only) keeps the
 * index small and must stay aligned with the search query's filters, or the
 * planner will not use it. The `::halfvec(n)` cast in the index expression must
 * likewise match the cast the query uses.
 */
async function createHalfvecIndex(indexSuffix: string, dimensions: number, profileLiteral: string): Promise<void> {
  await DB.execute(
    sql.raw(`
    CREATE INDEX IF NOT EXISTS chat_recall_embeddings_${indexSuffix}_halfvec_hnsw_idx
    ON chat_recall_embeddings
    USING hnsw ((embedding::halfvec(${dimensions})) halfvec_cosine_ops)
    WHERE profile_id = ${profileLiteral} AND status = 'synced' AND dimensions = ${dimensions}
  `)
  )
}

/**
 * Builds a binary-quantized Hamming HNSW index for very high-dimension vectors.
 *
 * Used when dimensions exceed the halfvec ceiling. Each dimension collapses to a
 * single bit, so this index is a cheap coarse filter over Hamming distance; the
 * search query re-ranks the coarse hits with the exact cosine distance to recover
 * precision. Same partial-`WHERE` alignment requirement as the halfvec index.
 */
async function createBinaryQuantizedIndex(
  indexSuffix: string,
  dimensions: number,
  profileLiteral: string
): Promise<void> {
  await DB.execute(
    sql.raw(`
    CREATE INDEX IF NOT EXISTS chat_recall_embeddings_${indexSuffix}_binary_hnsw_idx
    ON chat_recall_embeddings
    USING hnsw ((binary_quantize(embedding)::bit(${dimensions})) bit_hamming_ops)
    WHERE profile_id = ${profileLiteral} AND status = 'synced' AND dimensions = ${dimensions}
  `)
  )
}

/**
 * Hashes the identifying embedding fields into one stable profile id.
 *
 * Only the fields that change the meaning of a vector are included (provider
 * kind, provider id, model, dimensions); batch size, concurrency, and index
 * strategy are tuning knobs that must not fork the embedding set. This id keys
 * the embedding rows and the per-profile indexes.
 */
export function chatRecallEmbeddingProfileId(
  profile: Pick<ChatRecallEmbeddingProfile, 'providerKind' | 'providerId' | 'model' | 'dimensions'>
): string {
  return genericHash(
    JSON.stringify({
      providerKind: profile.providerKind,
      providerId: profile.providerId,
      model: profile.model,
      dimensions: profile.dimensions ?? null
    })
  )
}

/**
 * Reports extension status and, when installing, tries to create what is safe.
 *
 * Only pg_search is auto-created here. pgvector is deliberately left out of the
 * install loop: it is expected to be provisioned with the database image, and
 * attempting to create it from the app would mask a real provisioning gap. A
 * failed `CREATE EXTENSION` is captured as a status error rather than thrown, so
 * one extension problem does not abort the whole readiness check.
 */
async function ensureRequiredExtensions(install: boolean) {
  const initial = await loadExtensionStatuses()
  if (!install) return initial

  const next: Record<ChatRecallExtensionName, ChatRecallExtensionStatus> = { ...initial }
  for (const name of ['pg_search'] as const) {
    // Skip when already installed, or when the extension is not even available to
    // install (so the error surfaced is "not available", not a create failure).
    if (next[name].installed || !next[name].available) continue
    try {
      await DB.execute(sql.raw(`CREATE EXTENSION IF NOT EXISTS ${name}`))
    } catch (error) {
      next[name] = {
        ...next[name],
        error: errorMessage(error)
      }
    }
  }

  // Re-read after the install attempt to get the true installed/version state,
  // but carry forward any create-time error message captured above.
  const loaded = await loadExtensionStatuses()
  return {
    pg_search: { ...loaded.pg_search, error: next.pg_search.error },
    vector: { ...loaded.vector, error: next.vector.error }
  }
}

/**
 * Reads, for each required extension, whether it is available to install and
 * whether it is currently installed.
 *
 * Joins the catalog of available extensions against installed ones: a row with a
 * `defaultVersion` means installable, an `installedVersion` means installed.
 */
async function loadExtensionStatuses(): Promise<Record<ChatRecallExtensionName, ChatRecallExtensionStatus>> {
  const rows = (await DB.execute(sql`
    SELECT
      available.name,
      available.default_version AS "defaultVersion",
      installed.extversion AS "installedVersion"
    FROM pg_available_extensions available
    LEFT JOIN pg_extension installed ON installed.extname = available.name
    WHERE available.name IN ('pg_search', 'vector')
  `)) as unknown as Array<{
    name: ChatRecallExtensionName
    defaultVersion: string | null
    installedVersion: string | null
  }>

  const status = {
    pg_search: extensionStatus('pg_search', rows),
    vector: extensionStatus('vector', rows)
  }
  return status
}

function extensionStatus(
  name: ChatRecallExtensionName,
  rows: readonly { name: string; defaultVersion: string | null; installedVersion: string | null }[]
): ChatRecallExtensionStatus {
  const row = rows.find(item => item.name === name)
  return {
    name,
    available: Boolean(row?.defaultVersion),
    installed: Boolean(row?.installedVersion),
    version: row?.installedVersion ?? null
  }
}

/**
 * Counts recall-eligible documents and embedding progress for the console.
 *
 * "Documents" counts messages with non-empty `search_text` — the same
 * eligibility gate the worker and search use — so backlog vs synced is measured
 * against the set that is actually meant to be embedded.
 */
async function loadStats(): Promise<ChatRecallStatus['stats']> {
  const rows = (await DB.execute(sql`
    SELECT
      (SELECT count(*)::int FROM external_messages WHERE search_text <> '') AS documents,
      COALESCE((SELECT count(*)::int FROM chat_recall_embeddings WHERE status <> 'synced'), 0) AS "embeddingBacklog",
      COALESCE((SELECT count(*)::int FROM chat_recall_embeddings WHERE status = 'synced'), 0) AS "embeddingSynced"
  `)) as unknown as Array<{ documents: number; embeddingBacklog: number; embeddingSynced: number }>

  return rows[0] ?? { documents: 0, embeddingBacklog: 0, embeddingSynced: 0 }
}

/**
 * Finds the dominant vector size already stored for a profile.
 *
 * Used when the config does not pin `dimensions` (e.g. an `auto` provider that
 * returns variable sizes): the index must be built for the size the rows on disk
 * actually have. Picks the most common dimension so a few stragglers from a model
 * change do not drive the index width.
 */
async function syncedDimensionsForProfile(profileId: string): Promise<number | undefined> {
  const rows = (await DB.execute(sql`
    SELECT dimensions
    FROM chat_recall_embeddings
    WHERE profile_id = ${profileId} AND status = 'synced'
    GROUP BY dimensions
    ORDER BY count(*) DESC
    LIMIT 1
  `)) as unknown as Array<{ dimensions: number }>

  return rows[0]?.dimensions
}

function sqlLiteral(value: string): string {
  return `'${value.replaceAll("'", "''")}'`
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// BM25 keyword index over the message projection. `search_text` (human prose)
// uses the Chinese-compatible analyzer so CJK and mixed-language messages
// tokenize sensibly; `metadata_text` (ids, names, urls) uses 2..3-gram tokens so
// partial matches on non-word strings still hit. `document_id` is the BM25 key,
// and `sent_at` is indexed so the reranker can apply recency without a separate
// lookup.
const CREATE_BM25_INDEX_SQL = `
  CREATE INDEX IF NOT EXISTS external_messages_chat_recall_bm25_idx
  ON external_messages
  USING bm25 (
    document_id,
    (search_text::pdb.chinese_compatible),
    (metadata_text::pdb.ngram(2, 3)),
    sent_at
  )
  WITH (key_field='document_id');
`
