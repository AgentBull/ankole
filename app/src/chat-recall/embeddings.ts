import { match } from '@pleisto/active-support'
import { sql } from 'drizzle-orm'
import { DB } from '@/common/database'
import { resolveLlmProviderApiAccess } from '@/llm-providers/service'
import type { ChatRecallEmbeddingProfile } from './readiness'

export interface EmbeddingBatchRow {
  contentHash: string
  documentId: string
  profileId: string
  searchText: string
}

export interface EmbeddingBatchResult {
  claimed: number
  synced: number
}

export interface EmbeddingCycleDependencies {
  enqueuePendingEmbeddings: (profile: ChatRecallEmbeddingProfile) => Promise<void>
  runClaimedEmbeddingBatch: (profile: ChatRecallEmbeddingProfile, maxAttempts: number) => Promise<EmbeddingBatchResult>
}

const defaultEmbeddingCycleDependencies: EmbeddingCycleDependencies = {
  enqueuePendingEmbeddings,
  runClaimedEmbeddingBatch
}

export async function runChatRecallEmbeddingBatch(profile: ChatRecallEmbeddingProfile, maxAttempts: number) {
  await enqueuePendingEmbeddings(profile)
  return runClaimedEmbeddingBatch(profile, maxAttempts)
}

export async function runChatRecallEmbeddingCycle(
  profile: ChatRecallEmbeddingProfile,
  maxAttempts: number,
  dependencies: EmbeddingCycleDependencies = defaultEmbeddingCycleDependencies
): Promise<EmbeddingBatchResult> {
  await dependencies.enqueuePendingEmbeddings(profile)
  const concurrency = embeddingCycleConcurrency(profile)
  const batches = await Promise.allSettled(
    Array.from({ length: concurrency }, () => dependencies.runClaimedEmbeddingBatch(profile, maxAttempts))
  )
  const firstFailure = batches.find(batch => batch.status === 'rejected')
  if (firstFailure?.status === 'rejected') throw firstFailure.reason

  return batches.reduce(
    (total, batch) => {
      if (batch.status !== 'fulfilled') return total
      return {
        claimed: total.claimed + batch.value.claimed,
        synced: total.synced + batch.value.synced
      }
    },
    { claimed: 0, synced: 0 } satisfies EmbeddingBatchResult
  )
}

async function runClaimedEmbeddingBatch(
  profile: ChatRecallEmbeddingProfile,
  maxAttempts: number
): Promise<EmbeddingBatchResult> {
  const rows = await claimEmbeddingRows(profile, maxAttempts)
  if (rows.length === 0) return { claimed: 0, synced: 0 } satisfies EmbeddingBatchResult

  try {
    const embeddings = await createEmbeddings(
      profile,
      rows.map(row => row.searchText)
    )
    if (embeddings.length !== rows.length) {
      throw new Error(`embedding response count mismatch: expected ${rows.length}, got ${embeddings.length}`)
    }

    for (let index = 0; index < rows.length; index += 1) {
      const row = rows[index]!
      const embedding = embeddings[index]!
      await storeEmbedding(row, profile, embedding)
    }

    return { claimed: rows.length, synced: rows.length } satisfies EmbeddingBatchResult
  } catch (error) {
    await failEmbeddingRows(rows, maxAttempts, errorMessage(error))
    throw error
  }
}

function embeddingCycleConcurrency(profile: ChatRecallEmbeddingProfile): number {
  return Math.max(1, Math.floor(profile.concurrency || 1))
}

export async function testChatRecallEmbedding(profile: ChatRecallEmbeddingProfile): Promise<{ dimensions: number }> {
  const [embedding] = await createEmbeddings(profile, ['BullX chat recall embedding readiness check'])
  if (!embedding) throw new Error('embedding provider returned no embedding')
  return { dimensions: embedding.length }
}

export async function createQueryEmbedding(query: string, profile: ChatRecallEmbeddingProfile) {
  const [embedding] = await createEmbeddings(profile, [query])
  if (!embedding) throw new Error('embedding provider returned no embedding')
  return {
    dimensions: embedding.length,
    embedding
  }
}

async function enqueuePendingEmbeddings(profile: ChatRecallEmbeddingProfile): Promise<void> {
  await DB.execute(sql`
    INSERT INTO chat_recall_embeddings (
      document_id,
      profile_id,
      provider_kind,
      provider_id,
      model,
      dimensions,
      content_hash,
      status,
      next_retry_at
    )
    SELECT
      document_id,
      ${profile.profileId},
      ${profile.providerKind},
      ${profile.providerId},
      ${profile.model},
      ${profile.dimensions ?? 0},
      content_hash,
      'pending',
      now()
    FROM external_messages
    WHERE search_text <> ''
    ON CONFLICT (document_id, profile_id) DO UPDATE SET
      provider_kind = EXCLUDED.provider_kind,
      provider_id = EXCLUDED.provider_id,
      model = EXCLUDED.model,
      dimensions = CASE
        WHEN chat_recall_embeddings.status = 'synced'
          AND chat_recall_embeddings.content_hash = EXCLUDED.content_hash
        THEN chat_recall_embeddings.dimensions
        ELSE EXCLUDED.dimensions
      END,
      content_hash = EXCLUDED.content_hash,
      status = CASE
        WHEN chat_recall_embeddings.content_hash = EXCLUDED.content_hash
          AND chat_recall_embeddings.status = 'synced'
        THEN chat_recall_embeddings.status
        ELSE 'pending'
      END,
      next_retry_at = CASE
        WHEN chat_recall_embeddings.content_hash = EXCLUDED.content_hash
          AND chat_recall_embeddings.status = 'synced'
        THEN chat_recall_embeddings.next_retry_at
        ELSE now()
      END,
      updated_at = now()
  `)
}

async function claimEmbeddingRows(
  profile: ChatRecallEmbeddingProfile,
  maxAttempts: number
): Promise<EmbeddingBatchRow[]> {
  const rows = (await DB.execute(sql`
    WITH claimed AS (
      SELECT e.document_id, e.profile_id
      FROM chat_recall_embeddings e
      JOIN external_messages d ON d.document_id = e.document_id
      WHERE e.profile_id = ${profile.profileId}
        AND e.status IN ('pending', 'failed')
        AND e.attempt_count < ${maxAttempts}
        AND e.next_retry_at <= now()
        AND d.search_text <> ''
      ORDER BY e.updated_at ASC
      LIMIT ${profile.batchSize}
      FOR UPDATE SKIP LOCKED
    )
    UPDATE chat_recall_embeddings e
    SET status = 'processing',
        locked_at = now(),
        updated_at = now()
    FROM claimed
    JOIN external_messages d ON d.document_id = claimed.document_id
    WHERE e.document_id = claimed.document_id
      AND e.profile_id = claimed.profile_id
    RETURNING
      e.document_id AS "documentId",
      e.profile_id AS "profileId",
      e.content_hash AS "contentHash",
      d.search_text AS "searchText"
  `)) as unknown as EmbeddingBatchRow[]

  return rows
}

async function storeEmbedding(
  row: EmbeddingBatchRow,
  profile: ChatRecallEmbeddingProfile,
  embedding: number[]
): Promise<void> {
  await DB.execute(sql`
    UPDATE chat_recall_embeddings
    SET status = 'synced',
        provider_kind = ${profile.providerKind},
        provider_id = ${profile.providerId},
        model = ${profile.model},
        dimensions = ${embedding.length},
        embedding = ${vectorLiteral(embedding)}::vector,
        attempt_count = 0,
        locked_at = NULL,
        last_error = NULL,
        next_retry_at = now(),
        updated_at = now()
    WHERE document_id = ${row.documentId}
      AND profile_id = ${row.profileId}
      AND content_hash = ${row.contentHash}
  `)
}

async function failEmbeddingRows(
  rows: readonly EmbeddingBatchRow[],
  maxAttempts: number,
  reason: string
): Promise<void> {
  for (const row of rows) {
    await DB.execute(sql`
      UPDATE chat_recall_embeddings
      SET status = 'failed',
          attempt_count = attempt_count + 1,
          locked_at = NULL,
          last_error = ${reason.slice(0, 2_000)},
          next_retry_at = CASE
            WHEN attempt_count + 1 >= ${maxAttempts} THEN now() + interval '1 day'
            ELSE now() + make_interval(secs => LEAST(3600, pow(2, attempt_count + 1)::int * 30))
          END,
          updated_at = now()
      WHERE document_id = ${row.documentId}
        AND profile_id = ${row.profileId}
    `)
  }
}

async function createEmbeddings(profile: ChatRecallEmbeddingProfile, input: string[]): Promise<number[][]> {
  const access = await resolveLlmProviderApiAccess(profile.providerId)
  const endpoint = embeddingsEndpoint(access.baseUrl, profile.providerKind)
  const body: Record<string, unknown> = {
    model: profile.model,
    input
  }
  if (profile.dimensions) body.dimensions = profile.dimensions

  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${access.apiKey}`,
      'content-type': 'application/json',
      ...access.providerOptions.headers
    },
    body: JSON.stringify(body)
  })

  if (!response.ok) {
    const text = await response.text().catch(() => '')
    throw new Error(`embedding request failed: ${response.status} ${response.statusText}${text ? ` ${text}` : ''}`)
  }

  const json = (await response.json()) as {
    data?: Array<{ embedding?: number[] }>
  }
  const embeddings = json.data?.map((item, index) => validateEmbedding(item.embedding, index))
  if (!embeddings) throw new Error('embedding response missing data')
  return embeddings
}

function embeddingsEndpoint(baseUrl: string | null, providerKind: ChatRecallEmbeddingProfile['providerKind']): string {
  const fallback = match(providerKind)
    .with('openrouter', () => 'https://openrouter.ai/api/v1')
    .with('vllm', () => '')
    .with('openai', () => 'https://api.openai.com/v1')
    .exhaustive()
  const base = (baseUrl ?? fallback).replace(/\/+$/, '')
  if (!base) throw new Error('embedding provider baseUrl is required')
  return `${base}/embeddings`
}

export function vectorLiteral(embedding: readonly number[]): string {
  return `[${validateEmbedding(embedding, 0)
    .map(value => value.toString())
    .join(',')}]`
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function validateEmbedding(embedding: unknown, index: number): number[] {
  if (!Array.isArray(embedding) || embedding.length === 0) {
    throw new Error(`embedding response item ${index} is missing an embedding vector`)
  }
  return embedding.map((value, position) => {
    const number = Number(value)
    if (!Number.isFinite(number)) {
      throw new Error(`embedding response item ${index} has a non-finite value at ${position}`)
    }
    return number
  })
}
