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

export type ChatRecallExtensionName = 'pg_search' | 'vector'
export type ChatRecallWorkerState = 'not_started' | 'running' | 'paused' | 'stopped' | 'failed'

export interface ChatRecallExtensionStatus {
  name: ChatRecallExtensionName
  available: boolean
  installed: boolean
  version: string | null
  error?: string
}

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

  if (embeddingProfile) {
    try {
      await resolveLlmProviderApiAccess(embeddingProfile.providerId)
    } catch (error) {
      disabledReasons.push(
        error instanceof DomainError ? error.message : `embedding provider is not ready: ${errorMessage(error)}`
      )
    }
  }

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

export async function ensureChatRecallSchema(profile?: ChatRecallEmbeddingProfile): Promise<void> {
  await DB.execute(sql.raw(CREATE_BM25_INDEX_SQL))
  if (profile) await ensureVectorIndex(profile)
}

export async function ensureVectorIndex(profile: ChatRecallEmbeddingProfile): Promise<void> {
  if (profile.indexStrategy === 'exact_only') return

  const dimensions = profile.dimensions ?? (await syncedDimensionsForProfile(profile.profileId))
  if (!dimensions) return

  const indexSuffix = genericHash(`${profile.profileId}:${dimensions}:${profile.indexStrategy}`).slice(0, 16)
  const profileLiteral = sqlLiteral(profile.profileId)
  await match<[ChatRecallEmbeddingProfile['indexStrategy'], boolean]>([profile.indexStrategy, dimensions <= 4000])
    .with(['auto', true], () => createHalfvecIndex(indexSuffix, dimensions, profileLiteral))
    .with(['halfvec_hnsw', true], () => createHalfvecIndex(indexSuffix, dimensions, profileLiteral))
    .with(['exact_only', P._], () => Promise.resolve())
    .otherwise(() => createBinaryQuantizedIndex(indexSuffix, dimensions, profileLiteral))
}

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

async function ensureRequiredExtensions(install: boolean) {
  const initial = await loadExtensionStatuses()
  if (!install) return initial

  const next: Record<ChatRecallExtensionName, ChatRecallExtensionStatus> = { ...initial }
  for (const name of ['pg_search'] as const) {
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

  const loaded = await loadExtensionStatuses()
  return {
    pg_search: { ...loaded.pg_search, error: next.pg_search.error },
    vector: { ...loaded.vector, error: next.vector.error }
  }
}

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

async function loadStats(): Promise<ChatRecallStatus['stats']> {
  const rows = (await DB.execute(sql`
    SELECT
      (SELECT count(*)::int FROM external_messages WHERE search_text <> '') AS documents,
      COALESCE((SELECT count(*)::int FROM chat_recall_embeddings WHERE status <> 'synced'), 0) AS "embeddingBacklog",
      COALESCE((SELECT count(*)::int FROM chat_recall_embeddings WHERE status = 'synced'), 0) AS "embeddingSynced"
  `)) as unknown as Array<{ documents: number; embeddingBacklog: number; embeddingSynced: number }>

  return rows[0] ?? { documents: 0, embeddingBacklog: 0, embeddingSynced: 0 }
}

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
