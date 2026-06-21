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

/**
 * Seam for injecting fakes in tests. The two phases of a cycle — refilling the
 * queue and draining claimed batches — are overridable so the cycle's
 * concurrency and aggregation logic can be tested without a database.
 */
export interface EmbeddingCycleDependencies {
  enqueuePendingEmbeddings: (profile: ChatRecallEmbeddingProfile) => Promise<void>
  runClaimedEmbeddingBatch: (profile: ChatRecallEmbeddingProfile, maxAttempts: number) => Promise<EmbeddingBatchResult>
}

const defaultEmbeddingCycleDependencies: EmbeddingCycleDependencies = {
  enqueuePendingEmbeddings,
  runClaimedEmbeddingBatch
}

/**
 * Runs one enqueue-then-drain pass with a single claimed batch.
 *
 * The single-batch sibling of {@link runChatRecallEmbeddingCycle}; kept for
 * callers that want exactly one batch with no profile-level concurrency.
 */
export async function runChatRecallEmbeddingBatch(profile: ChatRecallEmbeddingProfile, maxAttempts: number) {
  await enqueuePendingEmbeddings(profile)
  return runClaimedEmbeddingBatch(profile, maxAttempts)
}

/**
 * Runs one full embedding cycle: refill the queue once, then drain up to
 * `concurrency` batches in parallel.
 *
 * Enqueue happens once up front (not per batch) because it is a single set-based
 * upsert that covers all pending work; the parallel claimers then pull disjoint
 * rows via `SKIP LOCKED`. If any batch rejects, the first failure is rethrown so
 * the caller (worker/runtime) records the error and backs off, but the other
 * batches are still awaited via `allSettled` first — a partial failure must not
 * leave sibling work running unobserved or rows stuck in `processing`.
 */
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

/**
 * Claims one batch of pending rows, embeds them, and stores the vectors.
 *
 * The count-mismatch check defends against a provider that returns fewer (or
 * more) vectors than inputs: row N's embedding must line up with row N by
 * position, so a length mismatch means the alignment is unsafe and the whole
 * batch is failed rather than stored against the wrong documents. On any error
 * the claimed rows are released back with an incremented attempt count (see
 * {@link failEmbeddingRows}) before the error propagates, so they retry later
 * instead of being stuck in `processing`.
 */
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

// Concurrency comes from operator config; clamp to at least 1 so a 0/NaN value
// never produces an empty batch array (which would silently embed nothing).
function embeddingCycleConcurrency(profile: ChatRecallEmbeddingProfile): number {
  return Math.max(1, Math.floor(profile.concurrency || 1))
}

/**
 * Probes the configured provider with one throwaway input.
 *
 * Used by the console "test" action to confirm credentials work and to learn the
 * model's true output dimension before committing it to config.
 */
export async function testChatRecallEmbedding(profile: ChatRecallEmbeddingProfile): Promise<{ dimensions: number }> {
  const [embedding] = await createEmbeddings(profile, ['BullX chat recall embedding readiness check'])
  if (!embedding) throw new Error('embedding provider returned no embedding')
  return { dimensions: embedding.length }
}

/**
 * Embeds a single search query at request time.
 *
 * Returns the vector together with its actual length so the search layer can pick
 * the matching index strategy (halfvec vs binary) for that dimension.
 */
export async function createQueryEmbedding(query: string, profile: ChatRecallEmbeddingProfile) {
  const [embedding] = await createEmbeddings(profile, [query])
  if (!embedding) throw new Error('embedding provider returned no embedding')
  return {
    dimensions: embedding.length,
    embedding
  }
}

/**
 * Reconciles the embedding queue with the current set of recall-eligible
 * messages for this profile.
 *
 * One set-based upsert is the whole queue refill: it inserts a `pending` row for
 * every message with non-empty `search_text` (the eligibility gate), and on
 * conflict it is careful to *not* disturb rows that are already `synced` and
 * whose `content_hash` still matches — those keep their status, dimensions, and
 * retry time so unchanged content is never needlessly re-embedded (re-embedding
 * costs a paid provider call). Only when the content hash differs, or the row was
 * never synced, is it reset to `pending` with `next_retry_at = now()` to be
 * picked up again. Newly empty/deleted messages drop out of recall via the
 * `chat_recall_embeddings` foreign-key cascade and the projection's explicit
 * delete, not here.
 */
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

/**
 * Atomically claims a batch of due rows and flips them to `processing`.
 *
 * `FOR UPDATE SKIP LOCKED` is what makes the configured concurrency safe: each
 * parallel claimer (and any other process/host) locks and takes a disjoint set
 * of rows instead of blocking on or double-processing the same ones. The filters
 * pick only work that is actually due — `pending` or `failed`, under the attempt
 * ceiling, past its `next_retry_at` backoff — and re-check `search_text <> ''` via
 * the join so a message emptied after enqueue is not embedded. Rows flip to
 * `processing` inside the same statement, so a crash leaves them claimed and they
 * become due again once their lock/lease is gone.
 */
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

/**
 * Writes one finished vector back, but only if the source content has not
 * changed under it.
 *
 * The `content_hash = ${row.contentHash}` predicate is the staleness re-check: a
 * message can be edited, re-projected, or deleted while its embedding was in
 * flight at the provider. If that happened, the row's hash no longer matches the
 * one captured at claim time (or the row is gone via cascade), the UPDATE matches
 * nothing, and this now-stale vector is silently discarded — which keeps a vector
 * for outdated or removed content from being resurrected into the index. The next
 * cycle re-enqueues the row against its new hash.
 */
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

/**
 * Marks a failed batch's rows for retry with capped exponential backoff.
 *
 * The backoff doubles per attempt (30s, 60s, ...) but is capped at one hour so a
 * persistent provider outage does not stretch retries out indefinitely. Once the
 * attempt count reaches `maxAttempts`, the row is parked for a full day instead of
 * being retried tightly — this keeps a permanently un-embeddable message (bad
 * content, model that rejects it) from churning the queue, while still letting it
 * recover on its own eventually. `last_error` is truncated so one huge provider
 * error body cannot bloat the row.
 */
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

/**
 * Calls the provider's OpenAI-compatible `/embeddings` endpoint for a batch.
 *
 * Talks the OpenAI embeddings wire format directly (rather than through the
 * vendored AI SDK) because all three supported providers expose it and recall
 * only needs this one shape. `dimensions` is sent only when the operator pinned
 * it, leaving the model's native size in effect otherwise. Provider-specific
 * extra headers from the resolved access are merged in for gateways that require
 * them.
 */
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

  // Pull the response body into the error on a non-2xx so a failed batch records
  // the provider's actual message (rate limit, bad model, ...) for the operator;
  // tolerate a body that cannot be read.
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

/**
 * Resolves the `/embeddings` URL, preferring the operator's base URL.
 *
 * Hosted providers (openai, openrouter) have a sensible public default, so a
 * missing base URL still works. `vllm` is self-hosted with no universal address,
 * so its fallback is empty on purpose — that forces the missing-base-URL error
 * instead of silently calling a public endpoint that does not exist.
 */
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

/**
 * Formats a vector as the `[1,2,3]` text literal pgvector expects.
 *
 * Validates first so a malformed vector cannot reach SQL as a `::vector` cast.
 */
export function vectorLiteral(embedding: readonly number[]): string {
  return `[${validateEmbedding(embedding, 0)
    .map(value => value.toString())
    .join(',')}]`
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * Checks that a provider returned a usable numeric vector.
 *
 * Rejects empty arrays and non-finite values (NaN/Infinity) before they reach
 * pgvector, where they would either error or corrupt distance math. The `index`
 * is only for a precise error message pointing at the offending batch item.
 */
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
