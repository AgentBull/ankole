import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { and, asc, eq, isNull, sql } from 'drizzle-orm'
import type { AssistantMessage } from '@earendil-works/pi-ai'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import {
  AiAgentConversations,
  AiAgentLlmTurns,
  AiAgentMessages,
  type AiAgentConversationGeneration,
  type JsonObject,
  type JsonValue
} from '@/common/db-schema'
import type { AgentMessage, SessionTreeEntry } from './core'
import { numberFromPath, stringFromPath, toJsonObject, toJsonValue } from '@/common/json'

export type AiAgentMessageRole = 'user' | 'assistant' | 'tool' | 'im_ambient'
export type AiAgentMessageKind = 'normal' | 'summary' | 'introspection' | 'error'
export type AiAgentLlmTurnKind =
  | 'generation'
  | 'retry_generation'
  | 'compression'
  | 'ambient_recognizer'
  | 'overflow_retry'
export type AiAgentLlmTurnStatus = 'started' | 'succeeded' | 'failed' | 'cancelled'
export type AiAgentModelProfileName = 'primary' | 'light' | 'heavy'

export interface AiAgentConversationRoute {
  agentUid: string
  bindingName: string
  providerRealmId?: string | null
  providerRoomId: string
}

export interface ProviderRefs {
  event_id?: string
  message_ids?: string[]
  room_id?: string
  thread_id?: string
}

export interface PendingFollowup {
  actor?: JsonObject
  created_at: string
  event_id: string
  event_source: string
  provider_refs: JsonObject
  text: string
}

export interface PendingSteering {
  command_event_id: string
  created_at: string
  text: string
}

export interface AppendAiAgentMessageInput {
  agentMessage?: AgentMessage | AssistantMessage | JsonObject | null
  content: JsonValue[]
  conversationId: string
  eventId?: string | null
  eventSource?: string | null
  kind?: AiAgentMessageKind
  metadata?: JsonObject
  role: AiAgentMessageRole
  status?: 'generating' | 'complete'
}

export interface StartLlmTurnInput {
  agentUid: string
  conversationId: string
  kind: AiAgentLlmTurnKind
  model: string
  profile: AiAgentModelProfileName
  provider: string
  cacheRetention?: string
  inputMessageIds?: string[]
  inputSummaryMessageId?: string | null
  maxTokens?: number
  reasoning?: string
  requestContext?: JsonObject
  temperature?: number
  triggerEventId?: string | null
  triggerMessageId?: string | null
}

export class AiAgentConversationService {
  conversationKey(route: AiAgentConversationRoute): string {
    return [
      'ai_agent_conversation:v1',
      `agent:${route.agentUid}`,
      `binding:${route.bindingName}`,
      `realm:${route.providerRealmId ?? 'default'}`,
      `room:${route.providerRoomId}`
    ].join(':')
  }

  async getOrCreateActiveConversation(
    route: AiAgentConversationRoute,
    db: QueryExecutor = DB
  ): Promise<typeof AiAgentConversations.$inferSelect> {
    const existing = await this.getActiveConversation(route, db)
    if (existing) return existing

    const conversationKey = this.conversationKey(route)
    const [created] = await db
      .insert(AiAgentConversations)
      .values({
        id: genUUIDv7(),
        agentUid: route.agentUid,
        conversationKey,
        generation: jsonbParam({}),
        metadata: jsonbParam({
          route: routeJson(route)
        })
      })
      .returning()
    if (!created) throw new AiAgentConversationError('Failed to create active conversation')
    return created
  }

  async getActiveConversation(
    route: AiAgentConversationRoute,
    db: QueryExecutor = DB
  ): Promise<typeof AiAgentConversations.$inferSelect | undefined> {
    const conversationKey = this.conversationKey(route)
    const [existing] = await db
      .select()
      .from(AiAgentConversations)
      .where(
        and(
          eq(AiAgentConversations.agentUid, route.agentUid),
          eq(AiAgentConversations.conversationKey, conversationKey),
          isNull(AiAgentConversations.endedAt)
        )
      )
      .limit(1)

    return existing
  }

  async rolloverConversation(
    route: AiAgentConversationRoute,
    reason: 'new_session' | 'daily_reset',
    db: QueryExecutor = DB
  ): Promise<typeof AiAgentConversations.$inferSelect> {
    const existing = await this.getOrCreateActiveConversation(route, db)
    await db
      .update(AiAgentConversations)
      .set({
        endedAt: new Date(),
        generation: jsonbParam(cancelGeneration(existing.generation, reason, undefined)),
        metadata: sql`jsonb_set(${AiAgentConversations.metadata}, '{end_reason}', ${JSON.stringify(reason)}::jsonb, true)`,
        updatedAt: sql`now()`
      })
      .where(eq(AiAgentConversations.id, existing.id))

    const [created] = await db
      .insert(AiAgentConversations)
      .values({
        id: genUUIDv7(),
        agentUid: route.agentUid,
        conversationKey: existing.conversationKey,
        generation: jsonbParam({}),
        metadata: jsonbParam({
          route: routeJson(route),
          previous_conversation_id: existing.id,
          rollover_reason: reason
        })
      })
      .returning()
    if (!created) throw new AiAgentConversationError('Failed to rollover conversation')
    return created
  }

  async appendMessage(
    input: AppendAiAgentMessageInput,
    db: QueryExecutor = DB
  ): Promise<typeof AiAgentMessages.$inferSelect> {
    const [conversation] = await db
      .select({ agentUid: AiAgentConversations.agentUid })
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, input.conversationId))
      .limit(1)
    if (!conversation) throw new AiAgentConversationError(`Unknown conversation ${input.conversationId}`)

    const [inserted] = await db
      .insert(AiAgentMessages)
      .values({
        id: genUUIDv7(),
        agentUid: conversation.agentUid,
        conversationId: input.conversationId,
        role: input.role,
        kind: input.kind ?? 'normal',
        status: input.status ?? 'complete',
        content: jsonbParam(input.content),
        agentMessage: input.agentMessage ? jsonbParam(toJsonObject(input.agentMessage)) : null,
        eventSource: input.eventSource ?? null,
        eventId: input.eventId ?? null,
        metadata: jsonbParam(input.metadata ?? {})
      })
      .onConflictDoNothing()
      .returning()
    if (inserted) return inserted

    if (!input.eventSource || !input.eventId) throw new AiAgentConversationError('Failed to append message')
    const [existing] = await db
      .select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, input.conversationId),
          eq(AiAgentMessages.eventSource, input.eventSource),
          eq(AiAgentMessages.eventId, input.eventId)
        )
      )
      .limit(1)
    if (!existing) throw new AiAgentConversationError('Failed to load idempotent message')
    return existing
  }

  async renderedMessages(
    conversationId: string,
    db: QueryExecutor = DB
  ): Promise<Array<typeof AiAgentMessages.$inferSelect>> {
    const rows = await db
      .select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`
        )
      )
      .orderBy(asc(AiAgentMessages.createdAt), asc(AiAgentMessages.id))

    const latestSummaryIndex = rows.findLastIndex(row => row.kind === 'summary' && row.status === 'complete')
    if (latestSummaryIndex < 0) return rows

    const summary = rows[latestSummaryIndex]!
    const firstKept = stringFromPath(summary.metadata, ['compression', 'first_kept_message_id'])
    if (!firstKept) return rows.slice(latestSummaryIndex)
    const firstKeptIndex = rows.findIndex(row => row.id === firstKept)
    return [summary, ...rows.slice(firstKeptIndex < 0 ? latestSummaryIndex + 1 : firstKeptIndex)]
  }

  async sessionEntries(conversationId: string, db: QueryExecutor = DB): Promise<SessionTreeEntry[]> {
    const rows = await this.renderedMessages(conversationId, db)
    // Project Postgres rows into upstream pi `SessionTreeEntry[]` using the shared inclusion classifier, so
    // compaction sees exactly the rows the live context does. The rendered rows already form a linear path,
    // so `parentId` chains to the previous emitted entry; `timestamp` uses the upstream ISO format.
    let parentId: string | null = null
    return rows.flatMap<SessionTreeEntry>(row => {
      const projection = classifyRenderedRow(row)
      if (projection === 'skip') return []
      const id = row.id
      const timestamp = row.createdAt.toISOString()
      const entryParentId = parentId
      parentId = id
      if (projection === 'summary') {
        return [
          {
            type: 'compaction' as const,
            id,
            parentId: entryParentId,
            timestamp,
            summary: textFromContent(row.content),
            firstKeptEntryId: stringFromPath(row.metadata, ['compression', 'first_kept_message_id']) ?? id,
            tokensBefore: numberFromPath(row.metadata, ['compression', 'tokens_before']) ?? 0,
            details: row.metadata.compression
          }
        ]
      }
      return [
        {
          type: 'message' as const,
          id,
          parentId: entryParentId,
          timestamp,
          message: row.agentMessage as unknown as AgentMessage
        }
      ]
    })
  }

  async acquireGenerationLease(input: {
    conversationId: string
    eventId?: string | null
    triggerMessageId: string
  }): Promise<{ leaseId: string } | undefined> {
    const leaseId = genUUIDv7()
    const [row] = await DB.update(AiAgentConversations)
      .set({
        generation: jsonbParam(newGenerationLease(leaseId, input.triggerMessageId, input.eventId)),
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentConversations.id, input.conversationId),
          sql`(coalesce(${AiAgentConversations.generation}->>'lease_id', '') = '' or coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') <> '')`
        )
      )
      .returning()
    return row ? { leaseId } : undefined
  }

  async clearGenerationLease(conversationId: string, leaseId: string): Promise<boolean> {
    const [row] = await DB.update(AiAgentConversations)
      .set({ generation: jsonbParam({}), updatedAt: sql`now()` })
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.generation}->>'lease_id' = ${leaseId}`,
          sql`coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') = ''`
        )
      )
      .returning()
    return Boolean(row)
  }

  async generationCanCommit(conversationId: string, leaseId: string): Promise<boolean> {
    const [row] = await DB.select({ id: AiAgentConversations.id })
      .from(AiAgentConversations)
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.generation}->>'lease_id' = ${leaseId}`,
          sql`coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') = ''`
        )
      )
      .limit(1)
    return Boolean(row)
  }

  /**
   * Refresh the lease heartbeat while a run is parked (e.g. waiting on clarify).
   * Bumps `heartbeat_at` and pushes `expires_at` to now+5min, clamped to
   * `max_expires_at`. No-op (returns false) if the lease changed or was cancelled.
   */
  async touchGenerationHeartbeat(conversationId: string, leaseId: string): Promise<boolean> {
    const [row] = await DB.update(AiAgentConversations)
      .set({
        generation: sql`jsonb_set(
          jsonb_set(${AiAgentConversations.generation}, '{heartbeat_at}', to_jsonb(now()::text), true),
          '{expires_at}',
          to_jsonb(LEAST(now() + interval '5 minutes', (${AiAgentConversations.generation}->>'max_expires_at')::timestamptz)::text),
          true
        )`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.generation}->>'lease_id' = ${leaseId}`,
          sql`coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') = ''`
        )
      )
      .returning()
    return Boolean(row)
  }

  /**
   * Push the lease ceiling (`max_expires_at`) forward by `extraMs` so a clarify
   * wait window is not truncated by the 30-min run ceiling. Never lowers it.
   */
  async extendGenerationCeiling(conversationId: string, leaseId: string, extraMs: number): Promise<boolean> {
    const seconds = Math.ceil(extraMs / 1000)
    const [row] = await DB.update(AiAgentConversations)
      .set({
        generation: sql`jsonb_set(
          ${AiAgentConversations.generation},
          '{max_expires_at}',
          to_jsonb(GREATEST(
            coalesce((${AiAgentConversations.generation}->>'max_expires_at')::timestamptz, now()),
            now() + ${seconds} * interval '1 second'
          )::text),
          true
        )`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.generation}->>'lease_id' = ${leaseId}`,
          sql`coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') = ''`
        )
      )
      .returning()
    return Boolean(row)
  }

  async cancelGeneration(conversationId: string, reason: string, eventId?: string | null): Promise<void> {
    const [conversation] = await DB.select()
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, conversationId))
      .limit(1)
    if (!conversation) return
    await DB.update(AiAgentConversations)
      .set({
        generation: jsonbParam(cancelGeneration(conversation.generation, reason, eventId)),
        updatedAt: sql`now()`
      })
      .where(eq(AiAgentConversations.id, conversationId))
  }

  async appendPendingFollowup(conversationId: string, followup: PendingFollowup): Promise<void> {
    await DB.update(AiAgentConversations)
      .set({
        generation: sql`jsonb_set(${AiAgentConversations.generation}, '{pending_followups}', coalesce(${AiAgentConversations.generation}->'pending_followups', '[]'::jsonb) || ${jsonbParam([toJsonValue(followup)])}, true)`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          sql`not exists (select 1 from jsonb_array_elements(coalesce(${AiAgentConversations.generation}->'pending_followups', '[]'::jsonb)) item where item->>'event_id' = ${followup.event_id})`
        )
      )
  }

  async appendPendingSteering(conversationId: string, steering: PendingSteering): Promise<void> {
    await DB.update(AiAgentConversations)
      .set({
        generation: sql`jsonb_set(${AiAgentConversations.generation}, '{pending_steering}', coalesce(${AiAgentConversations.generation}->'pending_steering', '[]'::jsonb) || ${jsonbParam([toJsonValue(steering)])}, true)`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          sql`not exists (select 1 from jsonb_array_elements(coalesce(${AiAgentConversations.generation}->'pending_steering', '[]'::jsonb)) item where item->>'command_event_id' = ${steering.command_event_id})`
        )
      )
  }

  async removePendingFollowupByProviderMessageId(conversationId: string, providerMessageId: string): Promise<boolean> {
    return this.removePendingArrayItem<PendingFollowup>(conversationId, 'pending_followups', followup => {
      const refs = followup.provider_refs
      const messageIds = Array.isArray(refs.message_ids) ? refs.message_ids : []
      return messageIds.some(messageId => messageId === providerMessageId)
    })
  }

  async startLlmTurn(input: StartLlmTurnInput): Promise<typeof AiAgentLlmTurns.$inferSelect> {
    const [row] = await DB.insert(AiAgentLlmTurns)
      .values({
        id: genUUIDv7(),
        agentUid: input.agentUid,
        conversationId: input.conversationId,
        kind: input.kind,
        status: 'started',
        profile: input.profile,
        provider: input.provider,
        model: input.model,
        reasoning: input.reasoning ?? null,
        temperature: input.temperature === undefined ? null : String(input.temperature),
        maxTokens: input.maxTokens ?? null,
        cacheRetention: input.cacheRetention ?? null,
        triggerMessageId: input.triggerMessageId ?? null,
        triggerEventId: input.triggerEventId ?? null,
        inputMessageIds: jsonbParam(input.inputMessageIds ?? []),
        inputSummaryMessageId: input.inputSummaryMessageId ?? null,
        requestContext: jsonbParam(input.requestContext ?? {}),
        response: jsonbParam({}),
        usage: jsonbParam({}),
        providerMetadata: jsonbParam({})
      })
      .returning()
    if (!row) throw new AiAgentConversationError('Failed to start LLM turn')
    return row
  }

  async finishLlmTurn(input: {
    llmTurnId: string
    providerMetadata?: JsonObject
    response?: JsonObject
    status: AiAgentLlmTurnStatus
    usage?: JsonObject
  }): Promise<void> {
    await DB.update(AiAgentLlmTurns)
      .set({
        status: input.status,
        response: jsonbParam(input.response ?? {}),
        usage: jsonbParam(input.usage ?? {}),
        providerMetadata: jsonbParam(input.providerMetadata ?? {}),
        completedAt: new Date(),
        updatedAt: sql`now()`
      })
      .where(eq(AiAgentLlmTurns.id, input.llmTurnId))
  }

  private async removePendingArrayItem<T>(
    conversationId: string,
    key: 'pending_followups' | 'pending_steering',
    predicate: (item: T) => boolean
  ): Promise<boolean> {
    return DB.transaction(async tx => {
      const [conversation] = await tx
        .select()
        .from(AiAgentConversations)
        .where(eq(AiAgentConversations.id, conversationId))
        .for('update')
        .limit(1)
      if (!conversation) return false

      const values = Array.isArray(conversation.generation[key]) ? (conversation.generation[key] as T[]) : []
      const kept = values.filter(item => !predicate(item))
      if (kept.length === values.length) return false

      await tx
        .update(AiAgentConversations)
        .set({
          generation: sql`jsonb_set(${AiAgentConversations.generation}, ${sql.raw(`'{${key}}'`)}, ${jsonbParam(toJsonValue(kept))}, true)`,
          updatedAt: sql`now()`
        })
        .where(eq(AiAgentConversations.id, conversationId))
      return true
    })
  }
}

export const aiAgentConversationService = new AiAgentConversationService()

export function providerRefs(input: {
  eventId?: string | null
  providerMessageId?: string | null
  providerRoomId: string
  providerThreadId: string
}): ProviderRefs {
  return {
    event_id: input.eventId ?? undefined,
    message_ids: input.providerMessageId ? [input.providerMessageId] : [],
    room_id: input.providerRoomId,
    thread_id: input.providerThreadId
  }
}

export function textContent(text: string): JsonValue[] {
  return [{ type: 'text', text }]
}

export function textFromContent(content: JsonValue[]): string {
  return content
    .flatMap(block =>
      typeof block === 'object' && block !== null && !Array.isArray(block) && typeof block.text === 'string'
        ? [block.text]
        : []
    )
    .join('')
}

function routeJson(route: AiAgentConversationRoute): JsonObject {
  return {
    agent_uid: route.agentUid,
    binding_name: route.bindingName,
    provider_realm_id: route.providerRealmId ?? null,
    provider_room_id: route.providerRoomId
  }
}

function cancelGeneration(
  generation: AiAgentConversationGeneration,
  reason: string,
  eventId?: string | null
): AiAgentConversationGeneration {
  if (!generation.lease_id) return generation
  return {
    ...generation,
    cancelled_at: new Date().toISOString(),
    cancellation_reason: reason,
    cancelled_by_event_id: eventId ?? null
  }
}

/**
 * Build a fresh generation lease payload. Single source of truth shared by the conversation service and the
 * runtime, so the lease shape (timeouts, empty pending queues) cannot drift between call sites.
 */
export function newGenerationLease(
  leaseId: string,
  triggerMessageId: string,
  triggerEventId?: string | null
): JsonObject {
  const now = new Date()
  return {
    lease_id: leaseId,
    trigger_message_id: triggerMessageId,
    trigger_event_id: triggerEventId ?? null,
    started_at: now.toISOString(),
    heartbeat_at: now.toISOString(),
    expires_at: new Date(now.getTime() + 5 * 60 * 1000).toISOString(),
    max_expires_at: new Date(now.getTime() + 30 * 60 * 1000).toISOString(),
    cancelled_at: null,
    cancellation_reason: null,
    cancelled_by_event_id: null,
    pending_followups: [],
    pending_steering: []
  }
}

/**
 * Single source of truth for which rendered rows enter the model's view and compaction, and as what.
 * `render` (live context) and `sessionEntries` (compaction input) both consume this so their inclusion
 * rules cannot drift: ambient scene facts and failed/aborted assistants are dropped from both; every row
 * carrying an `agentMessage` (including introspection notes) is a message; summaries are summaries.
 */
export function classifyRenderedRow(row: typeof AiAgentMessages.$inferSelect): 'summary' | 'message' | 'skip' {
  if (row.kind === 'summary') return 'summary'
  if (row.role === 'im_ambient' && row.kind === 'normal') return 'skip'
  if (row.role === 'assistant' && row.kind === 'error') return 'skip'
  if (!row.agentMessage) return 'skip'
  return 'message'
}

export class AiAgentConversationError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AiAgentConversationError'
  }
}
