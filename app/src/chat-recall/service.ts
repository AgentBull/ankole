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

const DEFAULT_BM25_LIMIT = 120
const DEFAULT_VECTOR_LIMIT = 120
const DEFAULT_VECTOR_COARSE_LIMIT = 300
const RECALL_METADATA_PROJECTION_SQL = `
  d.metadata || jsonb_build_object(
    'author', d.author,
    'hasAttachments', jsonb_array_length(d.attachments) > 0,
    'hasLinks', jsonb_array_length(d.links) > 0,
    'mentionedAgent', jsonb_array_length(d.mentions) > 0,
    'reactions', d.reactions
  )
`

export interface ChatHistorySearchInput {
  agentUid: string
  currentRoomId?: string | null
  excludeConversationId?: string | null
  limit?: number
  query: string
  requesterExternalId?: string | null
  requesterPrincipalUid?: string | null
}

export interface ChatHistorySearchResult {
  available: boolean
  degradedReasons?: string[]
  unavailableReasons?: string[]
  query: string
  results: ChatHistorySearchHit[]
}

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

export interface ChatHistoryWindowMessage {
  authorId: string | null
  isAnchor: boolean
  messageId: string
  sentAt: Date | null
  text: string
}

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

export async function searchChatHistory(input: ChatHistorySearchInput): Promise<ChatHistorySearchResult> {
  return searchChatHistoryWithDependencies(input, defaultChatHistorySearchDependencies)
}

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

  const limit = Math.max(1, Math.min(input.limit ?? status.config.rerank.limit, 50))
  const bm25Query = normalizeChatRecallBm25Query(input.query)
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

export async function getConsoleChatRecallStatus(): Promise<ChatRecallStatus> {
  return getChatRecallStatus({ install: true })
}

export async function getConsoleChatRecallConfig(): Promise<NormalizedChatRecallConfig> {
  return normalizeChatRecallConfig(await appConfigService.get(ChatRecallConfigDefinition))
}

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

export async function testConsoleChatRecallEmbedding(): Promise<{ dimensions: number }> {
  const status = await getConsoleChatRecallStatus()
  if (!status.enabled) throw new Error(`chat recall is unavailable: ${status.disabledReasons.join('; ')}`)
  if (!status.embeddingProfile) throw new Error('embedding provider/model is not configured')
  return testChatRecallEmbedding(status.embeddingProfile)
}

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

function sqlString(value: string): string {
  return `'${value.replaceAll("'", "''")}'`
}

export function normalizeChatRecallBm25Query(query: string): string | null {
  const tokens = query.match(/[\p{L}\p{N}_]+/gu) ?? []
  const normalized = tokens.map(token => token.trim()).filter(Boolean)
  return normalized.length > 0 ? normalized.join(' ') : null
}

function searchRouteFailureReason(route: ChatHistorySearchRoute, error: unknown): string {
  return `${route} search failed: ${errorMessage(error).slice(0, 500)}`
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
