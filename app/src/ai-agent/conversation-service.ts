import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { and, asc, eq, isNull, sql } from 'drizzle-orm'
import type { AssistantMessage } from '@/llm'
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
  | 'scheduled_task'
  | 'checkback_generation'
  | 'compression'
  | 'ambient_recognizer'
  | 'overflow_retry'
export type AiAgentLlmTurnStatus = 'started' | 'succeeded' | 'failed' | 'cancelled'
export type AiAgentModelProfileName = 'primary' | 'light' | 'heavy'

const MAX_PENDING_FOLLOWUPS = 10_000

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
  agent_message?: JsonObject
  created_at: string
  event_id: string
  event_source: string
  provider_refs: JsonObject
  room?: JsonObject
  sent_at?: string
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
  branchId?: string | null
  callIndex?: number | null
  parentBranchId?: string | null
  conversationId: string
  kind: AiAgentLlmTurnKind
  leaseId?: string | null
  model: string
  profile: AiAgentModelProfileName
  provider: string
  cacheRetention?: string
  inputMessageIds?: string[]
  inputSummaryMessageId?: string | null
  maxTokens?: number
  reasoning?: string
  requestContext?: JsonObject
  requestPatches?: JsonValue[]
  requestRefs?: JsonValue[]
  temperature?: number
  toolResults?: JsonValue[]
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

  /**
   * Active, uncancelled-lease conversations for one binding — the crash-recovery
   * candidate set. Keeps the `generation->>'lease_id'` / `cancelled_at` JSON-path
   * predicate inside the generation-state home instead of the runtime.
   */
  async findRecoverableGenerations(
    agentUid: string,
    bindingName: string
  ): Promise<Array<typeof AiAgentConversations.$inferSelect>> {
    return DB.select()
      .from(AiAgentConversations)
      .where(
        and(
          eq(AiAgentConversations.agentUid, agentUid),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.metadata}->'route'->>'binding_name' = ${bindingName}`,
          sql`coalesce(${AiAgentConversations.generation}->>'lease_id', '') <> ''`,
          sql`coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') = ''`
        )
      )
  }

  async rolloverConversation(
    route: AiAgentConversationRoute,
    reason: 'new_session' | 'daily_reset',
    db: QueryExecutor = DB,
    options: { sourceEventId?: string } = {}
  ): Promise<typeof AiAgentConversations.$inferSelect> {
    if (db === DB) {
      return DB.transaction(tx => this.rolloverConversation(route, reason, tx, options))
    }

    const conversationKey = this.conversationKey(route)
    await (db as QueryExecutor & { execute(query: unknown): Promise<unknown> }).execute(
      sql`select pg_advisory_xact_lock(hashtext(${conversationKey}))`
    )

    const existing = await this.getActiveConversation(route, db)
    if (existing && rolloverSourceEventId(existing.metadata) === options.sourceEventId && options.sourceEventId) {
      return existing
    }

    if (existing) {
      await db
        .update(AiAgentConversations)
        .set({
          endedAt: new Date(),
          generation: jsonbParam(cancelGeneration(existing.generation, reason, undefined)),
          metadata: sql`jsonb_set(${AiAgentConversations.metadata}, '{end_reason}', ${JSON.stringify(reason)}::jsonb, true)`,
          updatedAt: sql`now()`
        })
        .where(eq(AiAgentConversations.id, existing.id))
    }

    const [created] = await db
      .insert(AiAgentConversations)
      .values({
        id: genUUIDv7(),
        agentUid: route.agentUid,
        conversationKey,
        generation: jsonbParam({}),
        metadata: jsonbParam({
          route: routeJson(route),
          ...(existing ? { previous_conversation_id: existing.id } : {}),
          rollover_reason: reason,
          ...(options.sourceEventId ? { rollover_source_event_id: options.sourceEventId } : {})
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
   * Process-liveness heartbeat, driven by a wall-clock interval while a run is
   * in flight. Unlike {@link touchGenerationHeartbeat} it also pushes the
   * `max_expires_at` ceiling forward, because liveness makes no statement about
   * progress — a healthy long-thinking model may stream nothing for half an
   * hour. Lease expiry therefore means exactly one thing: the owning process
   * stopped beating (crashed, or lost the conversation). Runaway-run protection
   * lives in the stall watchdog and `maxTurns`, not here.
   */
  async touchGenerationLiveness(conversationId: string, leaseId: string): Promise<boolean> {
    const [row] = await DB.update(AiAgentConversations)
      .set({
        generation: sql`${AiAgentConversations.generation} || jsonb_build_object(
          'heartbeat_at', now()::text,
          'expires_at', (now() + interval '5 minutes')::text,
          'max_expires_at', GREATEST(
            coalesce((${AiAgentConversations.generation}->>'max_expires_at')::timestamptz, now()),
            now() + interval '5 minutes'
          )::text
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
   * Record the live streaming-card message of the current attempt on its lease.
   * The handle only lives in process memory; if the process dies mid-run, this
   * ref is what lets crash recovery and lease takeover delete the orphaned
   * "thinking" card instead of leaving it spinning in the chat forever.
   */
  async recordGenerationStreamingCard(
    conversationId: string,
    leaseId: string,
    card: { provider_message_id: string; provider_room_id?: string; provider_thread_id?: string }
  ): Promise<boolean> {
    const [row] = await DB.update(AiAgentConversations)
      .set({
        generation: sql`${AiAgentConversations.generation} || ${jsonbParam({ streaming_card: card })}`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.generation}->>'lease_id' = ${leaseId}`
        )
      )
      .returning()
    return Boolean(row)
  }

  async recordGenerationReasoningTrace(
    conversationId: string,
    leaseId: string,
    trace: NonNullable<AiAgentConversationGeneration['reasoning_trace']>
  ): Promise<boolean> {
    const [row] = await DB.update(AiAgentConversations)
      .set({
        generation: sql`${AiAgentConversations.generation} || ${jsonbParam({ reasoning_trace: trace })}`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.generation}->>'lease_id' = ${leaseId}`
        )
      )
      .returning()
    return Boolean(row)
  }

  /**
   * Cancel the active lease in place (single-statement jsonb merge, so concurrent
   * pending-queue appends are preserved). `expectedLeaseId` scopes the cancel to
   * one lease: a no-op if that lease was already replaced by a newer generation.
   */
  async cancelGeneration(
    conversationId: string,
    reason: string,
    eventId?: string | null,
    expectedLeaseId?: string
  ): Promise<void> {
    const conditions = [
      eq(AiAgentConversations.id, conversationId),
      sql`coalesce(${AiAgentConversations.generation}->>'lease_id', '') <> ''`
    ]
    if (expectedLeaseId) conditions.push(sql`${AiAgentConversations.generation}->>'lease_id' = ${expectedLeaseId}`)
    await DB.update(AiAgentConversations)
      .set({
        generation: sql`${AiAgentConversations.generation} || ${jsonbParam({
          cancelled_at: new Date().toISOString(),
          cancellation_reason: reason,
          cancelled_by_event_id: eventId ?? null
        })}`,
        updatedAt: sql`now()`
      })
      .where(and(...conditions))
  }

  /**
   * Next free `call_index` for a lease. Crash recovery reruns a lease whose
   * earlier calls already recorded turns; starting again at 0 would violate the
   * per-lease unique index and silently kill the recovered run.
   */
  async nextLlmTurnCallIndex(conversationId: string, leaseId: string): Promise<number> {
    const [row] = await DB.select({ max: sql<number | null>`max(${AiAgentLlmTurns.callIndex})` })
      .from(AiAgentLlmTurns)
      .where(and(eq(AiAgentLlmTurns.conversationId, conversationId), eq(AiAgentLlmTurns.leaseId, leaseId)))
    return (row?.max ?? -1) + 1
  }

  /**
   * Settle `started` turns abandoned by a dead or wedged run (process loss, or a
   * lease takeover) so the audit trail does not show phantom in-flight calls.
   * Turns the run already settled (succeeded/cancelled/failed) are untouched.
   */
  async failAbandonedLlmTurns(conversationId: string, leaseId: string, error: string): Promise<number> {
    const rows = await DB.update(AiAgentLlmTurns)
      .set({
        status: 'failed',
        completedAt: sql`now()`,
        response: sql`${AiAgentLlmTurns.response} || ${jsonbParam({ error_message: error })}`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentLlmTurns.conversationId, conversationId),
          eq(AiAgentLlmTurns.leaseId, leaseId),
          eq(AiAgentLlmTurns.status, 'started')
        )
      )
      .returning({ id: AiAgentLlmTurns.id })
    return rows.length
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
          sql`jsonb_array_length(coalesce(${AiAgentConversations.generation}->'pending_followups', '[]'::jsonb)) < ${MAX_PENDING_FOLLOWUPS}`,
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
        leaseId: input.leaseId ?? null,
        callIndex: input.callIndex ?? null,
        branchId: input.branchId ?? null,
        parentBranchId: input.parentBranchId ?? null,
        triggerMessageId: input.triggerMessageId ?? null,
        triggerEventId: input.triggerEventId ?? null,
        inputMessageIds: jsonbParam(input.inputMessageIds ?? []),
        inputSummaryMessageId: input.inputSummaryMessageId ?? null,
        requestContext: jsonbParam(input.requestContext ?? {}),
        requestRefs: jsonbParam(input.requestRefs ?? []),
        requestPatches: jsonbParam(input.requestPatches ?? []),
        response: jsonbParam({}),
        toolResults: jsonbParam(input.toolResults ?? []),
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
    toolResults?: JsonValue[]
    usage?: JsonObject
  }): Promise<void> {
    await DB.update(AiAgentLlmTurns)
      .set({
        status: input.status,
        response: jsonbParam(input.response ?? {}),
        toolResults: jsonbParam(input.toolResults ?? []),
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

/** Build the `provider_refs` metadata sub-object as a durable {@link JsonObject} (see {@link ProviderRefs} for the shape). */
export function providerRefs(input: {
  eventId?: string | null
  providerMessageId?: string | null
  providerRoomId: string
  providerThreadId: string
}): JsonObject {
  return {
    event_id: input.eventId ?? null,
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

/**
 * Single builder for the `metadata.route` envelope shared by conversation rows
 * (room-scoped) and message rows (thread-scoped). Both `provider_room_id` and
 * `provider_thread_id` are always present (null when not applicable) so the shape
 * cannot diverge between its two producers (conversation service + runtime).
 */
export function buildRouteMetadata(input: {
  agentUid: string
  bindingName: string
  providerRealmId?: string | null
  providerRoomId?: string | null
  providerThreadId?: string | null
}): JsonObject {
  return {
    agent_uid: input.agentUid,
    binding_name: input.bindingName,
    provider_realm_id: input.providerRealmId ?? null,
    provider_room_id: input.providerRoomId ?? null,
    provider_thread_id: input.providerThreadId ?? null
  }
}

function routeJson(route: AiAgentConversationRoute): JsonObject {
  return buildRouteMetadata({
    agentUid: route.agentUid,
    bindingName: route.bindingName,
    providerRealmId: route.providerRealmId,
    providerRoomId: route.providerRoomId
  })
}

function rolloverSourceEventId(metadata: JsonObject): string | undefined {
  const value = metadata.rollover_source_event_id
  return typeof value === 'string' && value.length > 0 ? value : undefined
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

/** True when the generation holds an active (uncancelled) lease. */
export function isActiveGeneration(generation: { lease_id?: unknown; cancelled_at?: unknown }): boolean {
  return typeof generation.lease_id === 'string' && generation.lease_id.length > 0 && !generation.cancelled_at
}

/**
 * True when an active lease has outlived `expires_at`, i.e. the run stopped
 * heartbeating (wedged provider stream, wedged tool, or a crashed process whose
 * recovery also died). Healthy runs keep `expires_at` ahead of now via
 * `touchGenerationHeartbeat`. Accepts both ISO (lease creation) and PostgreSQL
 * text (heartbeat refresh) timestamp formats; an unparseable or missing
 * `expires_at` counts as not expired so a malformed lease is never force-taken.
 */
export function isExpiredGeneration(
  generation: { lease_id?: unknown; cancelled_at?: unknown; expires_at?: unknown },
  at: Date = new Date()
): boolean {
  if (!isActiveGeneration(generation)) return false
  if (typeof generation.expires_at !== 'string') return false
  const expiresAt = Date.parse(generation.expires_at)
  return Number.isFinite(expiresAt) && expiresAt < at.getTime()
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
