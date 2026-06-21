import { recallRerank } from '@agentbull/bullx-native-addons'
import { isPlainObject, match, P } from '@pleisto/active-support'
import { and, asc, desc, eq, lt, gt, sql } from 'drizzle-orm'
import { DB } from '@/common/database'
import {
  AiAgentMessages,
  ExternalMessages,
  PrincipalExternalIdentities,
  Principals,
  type JsonObject
} from '@/common/db-schema'
import type { ConfigureJsonValue } from '@/common/db-schema/app-configure'
import { wrapWebContent } from '@/security/external-content'
import { appConfigService } from '@/config/app-configure'
import {
  ChatRecallConfigDefinition,
  normalizeChatRecallConfig,
  type ChatRecallConfig,
  type NormalizedChatRecallConfig
} from './config'
import { createQueryEmbedding, testChatRecallEmbedding, vectorLiteral } from './embeddings'
import { getChatRecallStatus, type ChatRecallEmbeddingProfile, type ChatRecallStatus } from './readiness'

// Per-route candidate caps. Each route over-fetches well beyond the final
// `limit` so the reranker has a deep enough pool to fuse and re-order; the
// binary-quantized path fetches an even wider coarse set (300) before exact
// re-ranking trims it back to 120.
const DEFAULT_BM25_LIMIT = 120
const DEFAULT_VECTOR_LIMIT = 120
const DEFAULT_VECTOR_COARSE_LIMIT = 300
// Recomputes the same derived metadata shape the projection stored, inline in SQL,
// so the candidate rows carry the reranker's metadata signals without a second
// query. Must stay in step with `recallDocumentMetadata` in projection.ts.
const RECALL_METADATA_PROJECTION_SQL = `
  d.metadata || jsonb_build_object(
    'author', d.author,
    'hasAttachments', jsonb_array_length(d.attachments) > 0,
    'hasLinks', jsonb_array_length(d.links) > 0,
    'mentionedAgent', jsonb_array_length(d.mentions) > 0,
    'reactions', d.reactions
  )
`

/**
 * One recall query plus the identity and context that scope it.
 *
 * `agentUid` and the requester identity together drive authorization (the agent
 * must have observed the room and the requester must be a member).
 * `currentRoomId` is not a filter but a reranker signal (same-room hits score
 * higher). `excludeConversationId` keeps the agent's own live conversation out of
 * the results. The requester can be given pre-resolved (`requesterPrincipalUid`)
 * or by external id, which is resolved on demand.
 */
export interface ChatHistorySearchInput {
  agentUid: string
  currentRoomId?: string | null
  excludeConversationId?: string | null
  limit?: number
  query: string
  requesterExternalId?: string | null
  requesterPrincipalUid?: string | null
}

/**
 * Outcome of a recall search.
 *
 * `available` distinguishes "recall could not run at all" (false) from "recall ran
 * and these are the hits, possibly empty" (true). `degradedReasons` is the partial
 * case: recall ran but at least one route failed, so results may be thinner than
 * usual. `unavailableReasons` explains an `available: false`.
 */
export interface ChatHistorySearchResult {
  available: boolean
  degradedReasons?: string[]
  unavailableReasons?: string[]
  query: string
  results: ChatHistorySearchHit[]
}

/**
 * One reranked recall result.
 *
 * `routeRanks` records the position this document reached in each route that
 * found it (input to rank fusion); `scoreBreakdown` is the reranker's per-factor
 * explanation. `window` is the surrounding messages around the matched anchor, so
 * the caller sees the hit in context rather than as an isolated line.
 */
export interface ChatHistorySearchHit {
  documentId: string
  roomId: string
  messageId: string
  sentAt: Date | null
  score: number
  routeRanks: Record<string, number>
  scoreBreakdown: JsonObject
  window: ChatHistoryWindowMessage[]
}

/** One message in a hit's surrounding context; `isAnchor` marks the matched one. */
export interface ChatHistoryWindowMessage {
  authorId: string | null
  isAnchor: boolean
  messageId: string
  sentAt: Date | null
  text: string
}

// The two retrieval routes that are fused: BM25 keyword search and vector
// similarity search.
export type ChatHistorySearchRoute = 'bm25' | 'vector'

export interface ChatHistorySearchCandidateRow {
  authorId: string | null
  documentId: string
  hasAttachments: boolean
  hasLinks: boolean
  isDm: boolean
  mentionedAgent: boolean
  messageId: string
  metadata: JsonObject
  rank: number
  roomId: string
  route: ChatHistorySearchRoute
  score: number
  searchText: string
  sentAt: Date | null
}

interface NativeRerankResult {
  results: Array<{
    id: string
    score: number
    scoreBreakdown?: JsonObject
  }>
}

/**
 * Injectable collaborators for the search pipeline.
 *
 * Exists so the orchestration in {@link searchChatHistoryWithDependencies} can be
 * tested against fakes (no database, no embedding provider, deterministic rerank
 * and clock). Production wiring is {@link defaultChatHistorySearchDependencies}.
 */
export interface ChatHistorySearchDependencies {
  getStatus: () => Promise<ChatRecallStatus>
  loadMessageWindow: (roomId: string, messageId: string, sentAt: Date | null) => Promise<ChatHistoryWindowMessage[]>
  nowMs: () => number
  rerank: (snapshot: unknown) => NativeRerankResult
  resolveRequesterPrincipalUid: (externalId: string | undefined) => Promise<string | undefined>
  searchBm25: (
    input: ChatHistorySearchInput,
    requesterPrincipalUid: string,
    bm25Query: string
  ) => Promise<ChatHistorySearchCandidateRow[]>
  searchVector: (
    input: ChatHistorySearchInput,
    requesterPrincipalUid: string,
    profile: ChatRecallEmbeddingProfile
  ) => Promise<ChatHistorySearchCandidateRow[]>
}

const defaultChatHistorySearchDependencies: ChatHistorySearchDependencies = {
  getStatus: getChatRecallStatus,
  loadMessageWindow,
  nowMs: () => Date.now(),
  rerank: snapshot => recallRerank(snapshot) as NativeRerankResult,
  resolveRequesterPrincipalUid,
  searchBm25,
  searchVector
}

/**
 * Public entry: searches prior chat history for the given query and identity.
 *
 * Thin wrapper that binds the production dependencies; all logic lives in
 * {@link searchChatHistoryWithDependencies}.
 */
export async function searchChatHistory(input: ChatHistorySearchInput): Promise<ChatHistorySearchResult> {
  return searchChatHistoryWithDependencies(input, defaultChatHistorySearchDependencies)
}

/**
 * Runs the full recall pipeline: fan out to the search routes, fuse and rerank,
 * then hydrate each hit with its surrounding message window.
 *
 * Degrade-don't-fail is the central design choice. The two routes run
 * concurrently via `allSettled`; if some succeed the result is still `available`
 * with `degradedReasons`, and only an all-routes-failed outcome is reported
 * `unavailable`. Two early returns short-circuit before any search: recall not
 * enabled/configured (unavailable), and an unresolved requester — which returns
 * `available` with no results rather than an error, because "we cannot identify
 * you, so you can see nothing" is an empty authorized set, not a failure.
 */
export async function searchChatHistoryWithDependencies(
  input: ChatHistorySearchInput,
  dependencies: ChatHistorySearchDependencies
): Promise<ChatHistorySearchResult> {
  const status = await dependencies.getStatus()
  if (!status.enabled || !status.embeddingProfile) {
    return {
      available: false,
      unavailableReasons: status.disabledReasons,
      query: input.query,
      results: []
    }
  }

  // No resolvable principal means no authorized rooms. Return an empty but
  // available result so the caller reports "nothing found" rather than an error.
  const requesterPrincipalUid =
    input.requesterPrincipalUid ??
    (await dependencies.resolveRequesterPrincipalUid(input.requesterExternalId ?? undefined))
  if (!requesterPrincipalUid) {
    return {
      available: true,
      query: input.query,
      results: []
    }
  }

  // Clamp the caller's limit into 1..50 even though config is already bounded,
  // because `input.limit` comes straight from the tool call.
  const limit = Math.max(1, Math.min(input.limit ?? status.config.rerank.limit, 50))
  const bm25Query = normalizeChatRecallBm25Query(input.query)
  // BM25 is only attempted when normalization yields a searchable token; a query
  // of pure punctuation/operators would otherwise become an empty or invalid
  // pg_search query. Vector search always runs since it embeds the raw query.
  const routeTasks: Array<{
    route: ChatHistorySearchRoute
    promise: Promise<ChatHistorySearchCandidateRow[]>
  }> = [
    ...(bm25Query
      ? [
          {
            route: 'bm25' as const,
            promise: dependencies.searchBm25(input, requesterPrincipalUid, bm25Query)
          }
        ]
      : []),
    {
      route: 'vector',
      promise: dependencies.searchVector(input, requesterPrincipalUid, status.embeddingProfile)
    }
  ]

  // `allSettled` so one route's failure (e.g. embedding provider down) never sinks
  // the other; failures become degraded reasons while successes still produce hits.
  const settledRoutes = await Promise.allSettled(routeTasks.map(task => task.promise))
  const routeRows: ChatHistorySearchCandidateRow[] = []
  const degradedReasons: string[] = []
  let successfulRoutes = 0
  for (let index = 0; index < settledRoutes.length; index += 1) {
    const settled = settledRoutes[index]!
    const route = routeTasks[index]!.route
    if (settled.status === 'fulfilled') {
      successfulRoutes += 1
      routeRows.push(...settled.value)
      continue
    }
    degradedReasons.push(searchRouteFailureReason(route, settled.reason))
  }

  // Every attempted route failed: recall is unavailable, not just degraded.
  if (successfulRoutes === 0) {
    return {
      available: false,
      degradedReasons: degradedReasons.length > 0 ? degradedReasons : undefined,
      unavailableReasons: degradedReasons.length > 0 ? degradedReasons : ['chat history recall search failed'],
      query: input.query,
      results: []
    }
  }

  const candidates = mergeCandidates(routeRows)
  if (candidates.length === 0) {
    return {
      available: true,
      degradedReasons: degradedReasons.length > 0 ? degradedReasons : undefined,
      query: input.query,
      results: []
    }
  }

  // Hand the fused candidate pool to the native reranker. The TypeScript side
  // supplies every fact the scoring needs (ranks, timestamps, text, metadata
  // signals) so the native function stays a deterministic pure transform. Vector
  // is weighted slightly above BM25 (1.1 vs 1) to favor semantic matches when both
  // routes agree. `dedupeKey` collapses the same room+message arriving from both
  // routes; `windowKey` (room) lets MMR diversify away from many hits in one room.
  const reranked = dependencies.rerank({
    limit,
    nowMs: dependencies.nowMs(),
    options: {
      rrfK: status.config.rerank.rrfK,
      recencyHalfLifeDays: status.config.rerank.recencyHalfLifeDays,
      mmrLambda: status.config.rerank.mmrLambda,
      routeWeights: {
        bm25: 1,
        vector: 1.1
      }
    },
    candidates: candidates.map(candidate => ({
      id: candidate.documentId,
      routeRanks: candidate.routeRanks,
      sentAtMs: candidate.sentAt?.getTime(),
      text: candidate.searchText,
      dedupeKey: `${candidate.roomId}:${candidate.messageId}`,
      windowKey: candidate.roomId,
      // Relevance signals beyond text match: messages in the current room,
      // direct messages, ones that addressed/mentioned the agent, or authored by
      // the requester are boosted; `ambientObservedOnly` (a group message the agent
      // merely overheard, neither DM nor mention) is the weakest signal. `'self'`
      // is the sentinel author id for the agent's own messages.
      metadataSignals: {
        sameCurrentRoom: input.currentRoomId === candidate.roomId,
        isDm: candidate.isDm,
        addressedOrMentioned: candidate.mentionedAgent,
        authorIsRequester: candidate.authorId !== null && candidate.authorId === input.requesterExternalId,
        authorIsAgent: candidate.authorId === 'self',
        hasLink: candidate.hasLinks,
        hasAttachment: candidate.hasAttachments,
        ambientObservedOnly: !candidate.mentionedAgent && !candidate.isDm
      }
    }))
  }) as NativeRerankResult

  // Rehydrate full candidate rows by id and load each hit's context window. The
  // missing-candidate guard is defensive: the reranker only echoes ids it was
  // given, so a miss would mean a contract break, not normal flow.
  const candidateById = new Map(candidates.map(candidate => [candidate.documentId, candidate]))
  const hits: ChatHistorySearchHit[] = []
  for (const result of reranked.results) {
    const candidate = candidateById.get(result.id)
    if (!candidate) continue
    hits.push({
      documentId: candidate.documentId,
      roomId: candidate.roomId,
      messageId: candidate.messageId,
      sentAt: candidate.sentAt,
      score: result.score,
      routeRanks: candidate.routeRanks,
      scoreBreakdown: result.scoreBreakdown ?? {},
      window: await dependencies.loadMessageWindow(candidate.roomId, candidate.messageId, candidate.sentAt)
    })
  }

  return {
    available: true,
    degradedReasons: degradedReasons.length > 0 ? degradedReasons : undefined,
    query: input.query,
    results: hits
  }
}

/**
 * Renders a search result into the plain text the agent tool returns to the LLM.
 *
 * Each hit shows its context window with the matched line marked `>>`. Message
 * text is passed through {@link wrapWebContent} as untrusted `web_fetch` content:
 * recalled chat is third-party input, so wrapping defends against prompt-injection
 * and special-token forgery hidden in past messages. Availability/degraded notes
 * are surfaced as leading lines so the agent can tell apart "nothing matched" from
 * "recall could not fully run".
 */
export function formatChatHistorySearchResult(result: ChatHistorySearchResult): string {
  if (!result.available) return `Chat history recall is unavailable: ${(result.unavailableReasons ?? []).join('; ')}`
  const degraded = result.degradedReasons?.length
    ? `Chat history recall degraded: ${result.degradedReasons.join('; ')}`
    : undefined
  if (result.results.length === 0) return [degraded, 'No matching chat history found.'].filter(Boolean).join('\n')

  const rendered = result.results
    .map((hit, index) => {
      const lines = hit.window.map(message => {
        const anchor = message.isAnchor ? '>> ' : '   '
        const time = message.sentAt ? message.sentAt.toISOString() : 'unknown-time'
        const author = message.authorId ?? 'unknown'
        return `${anchor}[${time}] ${author}: ${wrapWebContent(message.text, 'web_fetch')}`
      })
      return `${index + 1}. room=${hit.roomId} message=${hit.messageId} score=${hit.score.toFixed(4)}\n${lines.join('\n')}`
    })
    .join('\n\n')
  return [degraded, rendered].filter(Boolean).join('\n\n')
}

/** Console status read; uses `install: true` so opening the page provisions schema. */
export async function getConsoleChatRecallStatus(): Promise<ChatRecallStatus> {
  return getChatRecallStatus({ install: true })
}

/** Returns the current recall config (defaulted) for the console editor. */
export async function getConsoleChatRecallConfig(): Promise<NormalizedChatRecallConfig> {
  return normalizeChatRecallConfig(await appConfigService.get(ChatRecallConfigDefinition))
}

/**
 * Applies a partial config edit from the console and returns the new status.
 *
 * Merges per nested section (vector/rerank/worker) so a patch that touches one
 * sub-object does not wipe sibling fields the operator left unchanged — a shallow
 * top-level spread alone would drop the untouched keys inside each section.
 */
export async function updateConsoleChatRecallConfig(input: ChatRecallConfig): Promise<ChatRecallStatus> {
  const current = await getConsoleChatRecallConfig()
  const next = normalizeChatRecallConfig({
    ...current,
    ...input,
    vector: {
      ...current.vector,
      ...input.vector
    },
    rerank: {
      ...current.rerank,
      ...input.rerank
    },
    worker: {
      ...current.worker,
      ...input.worker
    }
  })
  await appConfigService.set(ChatRecallConfigDefinition, next as unknown as ConfigureJsonValue)
  return getConsoleChatRecallStatus()
}

/** Console "test embedding" action; fails loudly when recall is not ready. */
export async function testConsoleChatRecallEmbedding(): Promise<{ dimensions: number }> {
  const status = await getConsoleChatRecallStatus()
  if (!status.enabled) throw new Error(`chat recall is unavailable: ${status.disabledReasons.join('; ')}`)
  if (!status.embeddingProfile) throw new Error('embedding provider/model is not configured')
  return testChatRecallEmbedding(status.embeddingProfile)
}

/**
 * Maps a platform external id to the local principal that may search.
 *
 * Resolves only active human principals via a trusted `platform_subject`
 * identity, so a bot id or an unmatched/inactive external id yields no principal —
 * which the caller treats as "no authorized rooms" rather than an error.
 */
async function resolveRequesterPrincipalUid(externalId: string | undefined): Promise<string | undefined> {
  if (!externalId) return undefined
  const [row] = await DB.select({ uid: Principals.uid })
    .from(PrincipalExternalIdentities)
    .innerJoin(Principals, eq(Principals.uid, PrincipalExternalIdentities.principalUid))
    .where(
      and(
        eq(PrincipalExternalIdentities.kind, 'platform_subject'),
        eq(PrincipalExternalIdentities.externalId, externalId),
        eq(Principals.type, 'human'),
        eq(Principals.status, 'active')
      )
    )
    .limit(1)
  return row?.uid
}

/**
 * BM25 keyword-search route over the message projection.
 *
 * Matches the query against either the prose `search_text` or the structured
 * `metadata_text` (so a file name or person matches even when the body does not),
 * ranked by pg_search's `pdb.score`. Authorization and current-conversation
 * exclusion are applied as SQL predicates, and `search_text <> ''` enforces recall
 * eligibility. Returns rows already tagged with their 1-based rank for fusion.
 */
async function searchBm25(
  input: ChatHistorySearchInput,
  requesterPrincipalUid: string,
  bm25Query: string
): Promise<ChatHistorySearchCandidateRow[]> {
  const rows = (await DB.execute(sql`
    SELECT
      d.document_id AS "documentId",
      d.room_id AS "roomId",
      d.message_id AS "messageId",
      d.author_id AS "authorId",
      d.search_text AS "searchText",
      ${sql.raw(RECALL_METADATA_PROJECTION_SQL)} AS metadata,
      d.sent_at AS "sentAt",
      r.is_dm AS "isDm",
      pdb.score(d.document_id) AS score
    FROM external_messages d
    JOIN external_rooms r ON r.id = d.room_id
    WHERE (d.search_text @@@ ${bm25Query} OR d.metadata_text @@@ ${bm25Query})
      AND d.search_text <> ''
      AND ${authorizedDocumentPredicate(input.agentUid, requesterPrincipalUid)}
      AND ${currentConversationExclusionPredicate(input.excludeConversationId)}
    ORDER BY score DESC
    LIMIT ${DEFAULT_BM25_LIMIT}
  `)) as unknown as Array<
    Omit<ChatHistorySearchCandidateRow, 'rank' | 'route' | 'hasAttachments' | 'hasLinks' | 'mentionedAgent'>
  >

  return rows.map((row, index) => candidateFromRow(row, index + 1, 'bm25'))
}

/**
 * Vector-similarity route: embeds the query, then runs the search variant whose
 * index matches the chosen strategy and the embedding's dimension.
 *
 * The dispatch mirrors {@link ensureVectorIndex} exactly — same strategy and the
 * same 4000-dim halfvec ceiling — so the query path always uses the index that was
 * actually built. `exact_only` skips ANN entirely; within the ceiling `auto`/
 * `halfvec_hnsw` use the half-precision index; above it (the `otherwise`) it falls
 * to the binary-quantized coarse-then-exact path.
 */
async function searchVector(
  input: ChatHistorySearchInput,
  requesterPrincipalUid: string,
  profile: ChatRecallEmbeddingProfile
): Promise<ChatHistorySearchCandidateRow[]> {
  const { dimensions, embedding } = await queryEmbedding(input.query, profile)
  return match<[ChatRecallEmbeddingProfile['indexStrategy'], boolean]>([profile.indexStrategy, dimensions <= 4000])
    .with(['exact_only', P._], () => searchVectorExact(input, requesterPrincipalUid, profile, embedding))
    .with(['auto', true], () => searchVectorHalfvec(input, requesterPrincipalUid, profile, embedding, dimensions))
    .with(['halfvec_hnsw', true], () =>
      searchVectorHalfvec(input, requesterPrincipalUid, profile, embedding, dimensions)
    )
    .otherwise(() => searchVectorBinary(input, requesterPrincipalUid, profile, embedding, dimensions))
}

/**
 * Half-precision vector search, ordered by cosine distance.
 *
 * Casts both the stored column and the query vector to `halfvec(n)` so the
 * comparison uses the same half-precision HNSW index built for this profile; the
 * cast and the partial-index filters (`profile_id`, `status='synced'`,
 * `dimensions`) must match the index definition or the planner falls back to a
 * scan. `score` is reported as `1 - distance` (cosine similarity) while the
 * `ORDER BY` stays on raw distance ascending.
 *
 * Built with `sql.raw` (not parameterized `sql`) because the pgvector casts and
 * the literal vector must appear verbatim in the statement; injection is contained
 * by {@link vectorLiteral} (numeric-only) and {@link sqlString} for identifiers.
 */
async function searchVectorHalfvec(
  input: ChatHistorySearchInput,
  requesterPrincipalUid: string,
  profile: ChatRecallEmbeddingProfile,
  embedding: number[],
  dimensions: number
): Promise<ChatHistorySearchCandidateRow[]> {
  const vector = vectorLiteral(embedding)
  const rows = (await DB.execute(
    sql.raw(`
    SELECT
      d.document_id AS "documentId",
      d.room_id AS "roomId",
      d.message_id AS "messageId",
      d.author_id AS "authorId",
      d.search_text AS "searchText",
      ${RECALL_METADATA_PROJECTION_SQL} AS metadata,
      d.sent_at AS "sentAt",
      r.is_dm AS "isDm",
      1 - ((e.embedding::halfvec(${dimensions})) <=> (('${vector}'::vector)::halfvec(${dimensions}))) AS score
    FROM chat_recall_embeddings e
    JOIN external_messages d ON d.document_id = e.document_id
    JOIN external_rooms r ON r.id = d.room_id
    WHERE e.profile_id = ${sqlString(profile.profileId)}
      AND e.status = 'synced'
      AND e.dimensions = ${dimensions}
      AND d.search_text <> ''
      AND ${authorizedDocumentPredicateSql(input.agentUid, requesterPrincipalUid)}
      AND ${currentConversationExclusionPredicateSql(input.excludeConversationId)}
    ORDER BY (e.embedding::halfvec(${dimensions})) <=> (('${vector}'::vector)::halfvec(${dimensions})) ASC
    LIMIT ${DEFAULT_VECTOR_LIMIT}
  `)
  )) as unknown as Array<
    Omit<ChatHistorySearchCandidateRow, 'rank' | 'route' | 'hasAttachments' | 'hasLinks' | 'mentionedAgent'>
  >

  return rows.map((row, index) => candidateFromRow(row, index + 1, 'vector'))
}

/**
 * Two-phase vector search for very high-dimension vectors above the halfvec ceiling.
 *
 * Phase 1 (`coarse`) uses the binary-quantized Hamming HNSW index — 1 bit per
 * dimension — to cheaply shortlist a wide candidate set (`DEFAULT_VECTOR_COARSE_LIMIT`).
 * Phase 2 re-ranks only that shortlist by the exact cosine distance on the full
 * vectors and trims to `DEFAULT_VECTOR_LIMIT`. This recovers the precision the
 * 1-bit quantization loses while still avoiding an exact scan over the whole table.
 * Same `sql.raw`/literal-vector rationale as the halfvec variant.
 */
async function searchVectorBinary(
  input: ChatHistorySearchInput,
  requesterPrincipalUid: string,
  profile: ChatRecallEmbeddingProfile,
  embedding: number[],
  dimensions: number
): Promise<ChatHistorySearchCandidateRow[]> {
  const vector = vectorLiteral(embedding)
  const rows = (await DB.execute(
    sql.raw(`
    WITH coarse AS (
      SELECT e.document_id
      FROM chat_recall_embeddings e
      JOIN external_messages d ON d.document_id = e.document_id
      JOIN external_rooms r ON r.id = d.room_id
      WHERE e.profile_id = ${sqlString(profile.profileId)}
        AND e.status = 'synced'
        AND e.dimensions = ${dimensions}
        AND d.search_text <> ''
        AND ${authorizedDocumentPredicateSql(input.agentUid, requesterPrincipalUid)}
        AND ${currentConversationExclusionPredicateSql(input.excludeConversationId)}
      ORDER BY binary_quantize(e.embedding)::bit(${dimensions})
        <~> binary_quantize('${vector}'::vector)::bit(${dimensions}) ASC
      LIMIT ${DEFAULT_VECTOR_COARSE_LIMIT}
    )
    SELECT
      d.document_id AS "documentId",
      d.room_id AS "roomId",
      d.message_id AS "messageId",
      d.author_id AS "authorId",
      d.search_text AS "searchText",
      ${RECALL_METADATA_PROJECTION_SQL} AS metadata,
      d.sent_at AS "sentAt",
      r.is_dm AS "isDm",
      1 - (e.embedding <=> '${vector}'::vector) AS score
    FROM coarse
    JOIN chat_recall_embeddings e ON e.document_id = coarse.document_id
    JOIN external_messages d ON d.document_id = e.document_id
    JOIN external_rooms r ON r.id = d.room_id
    WHERE e.profile_id = ${sqlString(profile.profileId)}
    ORDER BY e.embedding <=> '${vector}'::vector ASC
    LIMIT ${DEFAULT_VECTOR_LIMIT}
  `)
  )) as unknown as Array<
    Omit<ChatHistorySearchCandidateRow, 'rank' | 'route' | 'hasAttachments' | 'hasLinks' | 'mentionedAgent'>
  >

  return rows.map((row, index) => candidateFromRow(row, index + 1, 'vector'))
}

/**
 * Exact cosine vector search with no ANN index.
 *
 * Used for the `exact_only` strategy and as the small-corpus choice: scans the
 * synced rows of the profile and orders by true cosine distance. Accurate but
 * O(rows), so it is deliberately reserved for installs that opt out of an ANN
 * index rather than used as the default.
 */
async function searchVectorExact(
  input: ChatHistorySearchInput,
  requesterPrincipalUid: string,
  profile: ChatRecallEmbeddingProfile,
  embedding: number[]
): Promise<ChatHistorySearchCandidateRow[]> {
  const vector = vectorLiteral(embedding)
  const rows = (await DB.execute(
    sql.raw(`
    SELECT
      d.document_id AS "documentId",
      d.room_id AS "roomId",
      d.message_id AS "messageId",
      d.author_id AS "authorId",
      d.search_text AS "searchText",
      ${RECALL_METADATA_PROJECTION_SQL} AS metadata,
      d.sent_at AS "sentAt",
      r.is_dm AS "isDm",
      1 - (e.embedding <=> '${vector}'::vector) AS score
    FROM chat_recall_embeddings e
    JOIN external_messages d ON d.document_id = e.document_id
    JOIN external_rooms r ON r.id = d.room_id
    WHERE e.profile_id = ${sqlString(profile.profileId)}
      AND e.status = 'synced'
      AND d.search_text <> ''
      AND ${authorizedDocumentPredicateSql(input.agentUid, requesterPrincipalUid)}
      AND ${currentConversationExclusionPredicateSql(input.excludeConversationId)}
    ORDER BY e.embedding <=> '${vector}'::vector ASC
    LIMIT ${DEFAULT_VECTOR_LIMIT}
  `)
  )) as unknown as Array<
    Omit<ChatHistorySearchCandidateRow, 'rank' | 'route' | 'hasAttachments' | 'hasLinks' | 'mentionedAgent'>
  >

  return rows.map((row, index) => candidateFromRow(row, index + 1, 'vector'))
}

async function queryEmbedding(
  query: string,
  profile: ChatRecallEmbeddingProfile
): Promise<{
  dimensions: number
  embedding: number[]
}> {
  return createQueryEmbedding(query, profile)
}

/**
 * The recall access-control rule, as a parameterized SQL fragment.
 *
 * A row is visible only when both halves hold: the agent has observed the row's
 * room (via {@link recordAgentRoomObservation}) and the requester is a recorded
 * member of it (via {@link recordRoomMembershipFromMessage}). Enforcing this as a
 * `WHERE`-level `EXISTS` pair — rather than filtering after fetch — keeps
 * unauthorized rooms out of the result and out of the rank pool entirely. The
 * twin {@link authorizedDocumentPredicateSql} below produces the same logic as a
 * raw string for the `sql.raw` vector queries.
 */
function authorizedDocumentPredicate(agentUid: string, requesterPrincipalUid: string) {
  return sql`
    EXISTS (
      SELECT 1
      FROM external_agent_room_observations agent_room
      WHERE agent_room.room_id = d.room_id
        AND agent_room.agent_uid = ${agentUid}
    )
    AND EXISTS (
      SELECT 1
      FROM external_room_memberships member
      WHERE member.room_id = d.room_id
        AND member.principal_uid = ${requesterPrincipalUid}
    )
  `
}

// Raw-string twin of authorizedDocumentPredicate, embedded into the sql.raw
// vector queries. Values are escaped via sqlString. The two must stay identical in
// meaning so authorization does not differ between the keyword and vector routes.
function authorizedDocumentPredicateSql(agentUid: string, requesterPrincipalUid: string): string {
  return `
    EXISTS (
      SELECT 1
      FROM external_agent_room_observations agent_room
      WHERE agent_room.room_id = d.room_id
        AND agent_room.agent_uid = ${sqlString(agentUid)}
    )
    AND EXISTS (
      SELECT 1
      FROM external_room_memberships member
      WHERE member.room_id = d.room_id
        AND member.principal_uid = ${sqlString(requesterPrincipalUid)}
    )
  `
}

/**
 * Excludes messages that already belong to the agent's current conversation.
 *
 * Without this, recall would surface the very messages the agent is responding to
 * right now as if they were separate memories. A null/empty exclude id means there
 * is nothing to exclude, so the predicate is just `true`. The match links a recall
 * document to a transcript turn by room id plus message id inside the turn's
 * `provider_refs`, and the `transcript_effect IS NULL` clause skips synthetic
 * transcript entries so only real provider-backed turns are excluded.
 */
function currentConversationExclusionPredicate(excludeConversationId?: string | null) {
  return match(excludeConversationId)
    .with(P.nullish, () => sql`true`)
    .with('', () => sql`true`)
    .otherwise(
      conversationId => sql`
        NOT EXISTS (
          SELECT 1
          FROM ${AiAgentMessages} current_message
          WHERE current_message.conversation_id = ${conversationId}
            AND current_message.metadata->'transcript_effect' IS NULL
            AND current_message.metadata->'provider_refs'->>'room_id' = d.room_id
            AND current_message.metadata->'provider_refs'->'message_ids' ? d.message_id
        )
      `
    )
}

// Raw-string twin of currentConversationExclusionPredicate for the sql.raw vector
// queries; same exclusion logic.
function currentConversationExclusionPredicateSql(excludeConversationId?: string | null): string {
  return match(excludeConversationId)
    .with(P.nullish, () => 'TRUE')
    .with('', () => 'TRUE')
    .otherwise(
      conversationId => `
        NOT EXISTS (
          SELECT 1
          FROM ai_agent_messages current_message
          WHERE current_message.conversation_id = ${sqlString(conversationId)}
            AND current_message.metadata->'transcript_effect' IS NULL
            AND current_message.metadata->'provider_refs'->>'room_id' = d.room_id
            AND current_message.metadata->'provider_refs'->'message_ids' ? d.message_id
        )
      `
    )
}

/**
 * Shapes a raw search row into a candidate, lifting the metadata signals up to
 * top-level booleans the reranker reads.
 *
 * `rank` is the row's 1-based position within its own route, which rank fusion
 * later combines across routes. Falls back to an empty object when metadata is not
 * a plain object so the signal reads are always safe.
 */
function candidateFromRow(
  row: Omit<ChatHistorySearchCandidateRow, 'rank' | 'route' | 'hasAttachments' | 'hasLinks' | 'mentionedAgent'>,
  rank: number,
  route: ChatHistorySearchCandidateRow['route']
): ChatHistorySearchCandidateRow {
  const metadata = isPlainObject(row.metadata) ? (row.metadata as JsonObject) : {}
  return {
    ...row,
    metadata,
    rank,
    route,
    hasAttachments: metadata.hasAttachments === true,
    hasLinks: metadata.hasLinks === true,
    mentionedAgent: metadata.mentionedAgent === true
  }
}

/**
 * Folds the per-route rows into one candidate per document, preserving each
 * route's rank.
 *
 * A document found by both routes must appear once but remember where it ranked in
 * each, so `routeRanks` accumulates the best (lowest) rank seen per route — that
 * map is what feeds reciprocal-rank fusion in the reranker. The top-level
 * score/route/rank track the single best-scoring route, used only as a tiebreak
 * fallback; fusion itself reads `routeRanks`.
 */
function mergeCandidates(rows: ChatHistorySearchCandidateRow[]) {
  const byId = new Map<string, ChatHistorySearchCandidateRow & { routeRanks: Record<string, number> }>()
  for (const row of rows) {
    const existing = byId.get(row.documentId)
    if (!existing) {
      byId.set(row.documentId, {
        ...row,
        routeRanks: { [row.route]: row.rank }
      })
      continue
    }
    existing.routeRanks[row.route] = Math.min(existing.routeRanks[row.route] ?? row.rank, row.rank)
    if (row.score > existing.score) {
      existing.score = row.score
      existing.route = row.route
      existing.rank = row.rank
    }
  }
  return [...byId.values()]
}

/**
 * Loads the matched message plus up to two messages on each side, in time order.
 *
 * The window gives the agent enough surrounding context to read a hit as part of a
 * conversation instead of a bare line. The "before" rows are fetched newest-first
 * for the `LIMIT 2` to take the two nearest, then reversed so the final array is
 * chronological. `anchorSentAt` falls back to the row's `sentAt`/`createdAt` when
 * the caller did not pass a time, so a message without an observed send time still
 * gets a window. Returns empty when the anchor has since been deleted.
 */
async function loadMessageWindow(
  roomId: string,
  messageId: string,
  sentAt: Date | null
): Promise<ChatHistoryWindowMessage[]> {
  const anchorRows = await DB.select()
    .from(ExternalMessages)
    .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, messageId)))
    .limit(1)
  const anchor = anchorRows[0]
  if (!anchor) return []
  const anchorSentAt = sentAt ?? anchor.sentAt ?? anchor.createdAt
  const [before, after] = await Promise.all([
    DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, roomId), lt(ExternalMessages.sentAt, anchorSentAt)))
      .orderBy(desc(ExternalMessages.sentAt))
      .limit(2),
    DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, roomId), gt(ExternalMessages.sentAt, anchorSentAt)))
      .orderBy(asc(ExternalMessages.sentAt))
      .limit(2)
  ])
  return [...before.reverse(), anchor, ...after].map(message => ({
    authorId: message.authorId,
    isAnchor: message.messageId === messageId,
    messageId: message.messageId,
    sentAt: message.sentAt,
    text: message.text ?? ''
  }))
}

// Quotes and escapes a string for inline use in the `sql.raw` vector queries.
// Doubles single quotes; only used for already-trusted identifiers (uids, profile
// ids), never free-form user text.
function sqlString(value: string): string {
  return `'${value.replaceAll("'", "''")}'`
}

/**
 * Reduces a raw query to a safe BM25 query, or null when nothing is searchable.
 *
 * pg_search treats characters like `*`, `:`, `"`, `(` as query operators, so a
 * user query passed through verbatim can be a parse error or behave unexpectedly.
 * This keeps only letters, numbers, and underscores (Unicode-aware, so CJK text is
 * preserved) and space-joins them, yielding a plain term query. A query with no
 * such tokens returns null, which is the signal upstream to skip the BM25 route.
 */
export function normalizeChatRecallBm25Query(query: string): string | null {
  const tokens = query.match(/[\p{L}\p{N}_]+/gu) ?? []
  const normalized = tokens.map(token => token.trim()).filter(Boolean)
  return normalized.length > 0 ? normalized.join(' ') : null
}

// Builds a degraded/unavailable reason for one route, truncating the provider
// error so a huge message body does not bloat the result.
function searchRouteFailureReason(route: ChatHistorySearchRoute, error: unknown): string {
  return `${route} search failed: ${errorMessage(error).slice(0, 500)}`
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
