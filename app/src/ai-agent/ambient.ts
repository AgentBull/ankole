import { redis } from 'bun'
import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { completeSimple, parseJsonWithRepair, type Message } from '@earendil-works/pi-ai'
import { and, asc, desc, eq, gt, inArray, sql } from 'drizzle-orm'
import { DB } from '@/common/database'
import { AiAgentConversations, AiAgentMessages, type JsonObject, type JsonValue } from '@/common/db-schema'
import { isJsonObject, toJsonValue } from '@/common/json'
import { logger } from '@/common/logger'
import { loadSystemTimezone } from '@/config/system'
import { createUserMessage } from './core'
import type { AiAgentRuntimeProfile } from './config'
import {
  aiAgentConversationService,
  textContent,
  textFromContent,
  type AiAgentConversationService
} from './conversation-service'
import {
  ambientReferenceSnippetsFromRows,
  buildMessageContextMetadata,
  mergeMessageContextMetadata
} from './message-context'
import { AMBIENT_RECOGNIZER_SYSTEM_PROMPT, buildAmbientRecognizerUserPrompt } from './prompts/ambient-prompt'

interface AmbientBatch {
  agentUid: string
  bindingName?: string
  conversationId: string
  providerRoomId: string
  providerThreadId: string
}

interface AmbientRecognizerResult {
  intervene: boolean
  reason_summary?: string
}

const UUID_MEMBER_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/**
 * Batches ambient (non-addressed) room messages per conversation and wakes the
 * recognizer when a batch is due.
 *
 * The Redis ZSET is the only wake ledger: member = conversation id, score = due
 * time. Batch payload (route, thread, first-seen anchor) is re-derived from PG,
 * where the ambient message rows already live, so the ledger survives process
 * restarts without a second in-memory bookkeeping copy.
 */
export class AiAgentAmbientBatcher {
  private readonly drainingMembers = new Set<string>()
  private readonly redisKey = 'bullx-agent:ai-agent:ambient-wake'

  constructor(private readonly conversations: AiAgentConversationService = aiAgentConversationService) {}

  async schedule(input: {
    agentUid: string
    bindingName?: string
    conversationId: string
    profile: AiAgentRuntimeProfile
    providerRoomId: string
    providerThreadId: string
  }): Promise<void> {
    const now = Date.now()
    // The hard cap anchors at the oldest unprocessed ambient message so a busy
    // room cannot push the batch window forward forever.
    const oldestPending = await this.oldestPendingAmbientRow(input.conversationId)
    const firstSeenMs = oldestPending?.createdAt.getTime() ?? now
    const dueAt = Math.min(now + input.profile.ambient.batchWindowMs, firstSeenMs + input.profile.ambient.hardCapMs)
    try {
      await redis.send('ZADD', [this.redisKey, String(dueAt), input.conversationId])
    } catch (error) {
      logger.warn(
        { error, conversationId: input.conversationId },
        'Ambient wake ZADD failed; batch will only recover via a later schedule or recovery drain'
      )
    }
  }

  async drainDue(
    input: AiAgentRuntimeProfile | { agentUid?: string; bindingName?: string; profile: AiAgentRuntimeProfile }
  ): Promise<Array<{ conversationId: string; providerRoomId: string; providerThreadId: string }>> {
    const profile = 'profile' in input ? input.profile : input
    const filter = 'profile' in input ? input : {}
    const now = Date.now()
    const members = await this.dueMembers(now)
    const intervened: Array<{ conversationId: string; providerRoomId: string; providerThreadId: string }> = []
    for (const member of members) {
      if (this.drainingMembers.has(member)) continue
      this.drainingMembers.add(member)
      try {
        const batch = await this.loadBatch(member)
        if (!batch) {
          await this.removeMember(member)
          continue
        }
        if (!this.matchesFilter(batch, filter)) continue
        await this.removeMember(member)
        const result = await this.recognize(batch.conversationId, profile)
        if (result?.intervene) {
          intervened.push({
            conversationId: batch.conversationId,
            providerRoomId: batch.providerRoomId,
            providerThreadId: batch.providerThreadId
          })
        }
      } finally {
        this.drainingMembers.delete(member)
      }
    }
    return intervened
  }

  async nextDueDelayMs(input: { agentUid?: string; bindingName?: string } = {}): Promise<number | undefined> {
    let redisEntries: unknown
    try {
      redisEntries = await redis.send('ZRANGE', [this.redisKey, '0', '-1', 'WITHSCORES'])
    } catch (error) {
      logger.warn({ error }, 'Ambient wake ZRANGE failed; next due time unknown')
      return undefined
    }
    if (!Array.isArray(redisEntries)) return undefined
    const entries = scoreEntries(redisEntries)
    if (entries.length === 0) return undefined

    let candidates = entries
    if (input.agentUid || input.bindingName) {
      const routes = await this.conversationRoutes(entries.map(([member]) => member))
      candidates = entries.filter(([member]) => {
        const route = routes.get(member)
        return route !== undefined && this.matchesFilter(route, input)
      })
    }
    if (candidates.length === 0) return undefined
    return Math.max(0, Math.min(...candidates.map(([, score]) => score)) - Date.now())
  }

  /** Re-derive the batch payload for a wake member from PG. */
  private async loadBatch(member: string): Promise<AmbientBatch | undefined> {
    if (!UUID_MEMBER_PATTERN.test(member)) return undefined
    const [conversation] = await DB.select({
      id: AiAgentConversations.id,
      agentUid: AiAgentConversations.agentUid,
      metadata: AiAgentConversations.metadata
    })
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, member))
      .limit(1)
    if (!conversation) return undefined

    const route = isJsonObject(conversation.metadata.route) ? conversation.metadata.route : {}
    const oldestPending = await this.oldestPendingAmbientRow(member)
    if (!oldestPending) return undefined
    const refs = isJsonObject(oldestPending.metadata.provider_refs) ? oldestPending.metadata.provider_refs : {}

    const providerRoomId = stringOrUndefined(route.provider_room_id) ?? stringOrUndefined(refs.room_id)
    const providerThreadId = stringOrUndefined(refs.thread_id) ?? providerRoomId
    if (!providerRoomId || !providerThreadId) return undefined
    return {
      agentUid: conversation.agentUid,
      bindingName: stringOrUndefined(route.binding_name),
      conversationId: conversation.id,
      providerRoomId,
      providerThreadId
    }
  }

  /** agentUid/bindingName per wake member, for filtered next-due queries. */
  private async conversationRoutes(
    members: string[]
  ): Promise<Map<string, { agentUid: string; bindingName?: string }>> {
    const ids = members.filter(member => UUID_MEMBER_PATTERN.test(member))
    const routes = new Map<string, { agentUid: string; bindingName?: string }>()
    if (ids.length === 0) return routes
    const rows = await DB.select({
      id: AiAgentConversations.id,
      agentUid: AiAgentConversations.agentUid,
      metadata: AiAgentConversations.metadata
    })
      .from(AiAgentConversations)
      .where(inArray(AiAgentConversations.id, ids))
    for (const row of rows) {
      const route = isJsonObject(row.metadata.route) ? row.metadata.route : {}
      routes.set(row.id, { agentUid: row.agentUid, bindingName: stringOrUndefined(route.binding_name) })
    }
    return routes
  }

  /** Oldest ambient message not yet consumed by an intervention (hard-cap anchor + thread source). */
  private async oldestPendingAmbientRow(
    conversationId: string
  ): Promise<{ createdAt: Date; metadata: JsonObject } | undefined> {
    const latestInterventionAt = await this.latestInterventionAt(conversationId)
    const [row] = await DB.select({ createdAt: AiAgentMessages.createdAt, metadata: AiAgentMessages.metadata })
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          eq(AiAgentMessages.role, 'im_ambient'),
          eq(AiAgentMessages.kind, 'normal'),
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`,
          latestInterventionAt ? gt(AiAgentMessages.createdAt, latestInterventionAt) : undefined
        )
      )
      .orderBy(asc(AiAgentMessages.createdAt), asc(AiAgentMessages.id))
      .limit(1)
    return row
  }

  private async latestInterventionAt(conversationId: string): Promise<Date | undefined> {
    const [latestIntervention] = await DB.select({ createdAt: AiAgentMessages.createdAt })
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          eq(AiAgentMessages.role, 'im_ambient'),
          eq(AiAgentMessages.kind, 'introspection'),
          sql`${AiAgentMessages.metadata}->'control'->>'type' = 'ambient_intervention'`
        )
      )
      .orderBy(desc(AiAgentMessages.createdAt), desc(AiAgentMessages.id))
      .limit(1)
    return latestIntervention?.createdAt
  }

  private async removeMember(member: string): Promise<void> {
    try {
      await redis.send('ZREM', [this.redisKey, member])
    } catch (error) {
      logger.warn({ error, member }, 'Ambient wake ZREM failed; member may be drained again')
    }
  }

  private async recognize(
    conversationId: string,
    profile: AiAgentRuntimeProfile
  ): Promise<AmbientRecognizerResult | undefined> {
    const latestInterventionAt = await this.latestInterventionAt(conversationId)

    const rows = await DB.select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          eq(AiAgentMessages.role, 'im_ambient'),
          eq(AiAgentMessages.kind, 'normal'),
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`,
          latestInterventionAt ? gt(AiAgentMessages.createdAt, latestInterventionAt) : undefined
        )
      )
      .orderBy(desc(AiAgentMessages.createdAt))
      .limit(12)
    if (rows.length === 0) return undefined

    const prompt = rows
      .slice()
      .reverse()
      .map(row => `- ${textFromContent(row.content)}`)
      .join('\n')

    const systemPrompt = AMBIENT_RECOGNIZER_SYSTEM_PROMPT
    const llmMessages: Message[] = [
      {
        role: 'user',
        timestamp: Date.now(),
        content: buildAmbientRecognizerUserPrompt(prompt)
      }
    ]
    const llmTurn = await this.conversations.startLlmTurn({
      agentUid: rows[0]!.agentUid,
      branchId: `conversation:${conversationId}:root`,
      callIndex: 0,
      conversationId,
      kind: 'ambient_recognizer',
      leaseId: genUUIDv7(),
      profile: 'light',
      provider: profile.lightModel.config.providerId,
      model: profile.lightModel.config.model,
      reasoning: profile.lightModel.config.reasoning,
      inputMessageIds: rows.map(row => row.id),
      requestContext: {
        ambient_rows: rows.length,
        llm_message_count: llmMessages.length,
        llm_message_roles: llmMessages.map(message => message.role),
        system_prompt: systemPrompt,
        tool_count: 0,
        tool_names: []
      },
      requestRefs: rows.map(row => ambientRowRef(row)),
      requestPatches: [
        {
          type: 'llm_tool_definitions',
          tools: []
        },
        {
          type: 'llm_request',
          reason: 'ambient_recognizer',
          system_prompt: systemPrompt,
          messages: toJsonValue(llmMessages)
        }
      ]
    })

    let rawText: string | undefined
    try {
      const response = await completeSimple(
        profile.lightModel.model,
        { systemPrompt, messages: llmMessages },
        profile.lightModel.options
      )
      const text = response.content
        .flatMap(block => (block.type === 'text' ? [block.text] : []))
        .join('')
        .trim()
      rawText = text
      const parsed = parseAmbientRecognizerResult(text)
      await this.conversations.finishLlmTurn({
        llmTurnId: llmTurn.id,
        status: 'succeeded',
        response: {
          raw_text: text,
          parsed: parsed as unknown as JsonObject,
          stop_reason: response.stopReason
        },
        usage: response.usage as unknown as JsonObject,
        providerMetadata: {
          pi_provider: profile.lightModel.config.piProvider,
          response_id: response.responseId ?? null
        }
      })
      if (parsed.intervene) {
        const reason = parsed.reason_summary || 'Ambient context suggests the agent should intervene.'
        const introspection = [
          'Ambient intervention trigger.',
          'Goal: offer one useful next action for the current room situation.',
          `Reason: ${reason}`,
          'Do not answer every ambient reference.',
          'Use tools only when needed; keep tool use bounded and stop once there is enough context to help.'
        ].join('\n')
        const ambientReferences = ambientReferenceSnippetsFromRows(rows.slice().reverse())
        const messageContext = buildMessageContextMetadata(
          {
            ambientReferences,
            sentAt: new Date(),
            timezone: await loadSystemTimezone()
          },
          []
        )
        await this.conversations.appendMessage({
          conversationId,
          role: 'im_ambient',
          kind: 'introspection',
          content: textContent(introspection),
          agentMessage: createUserMessage(introspection),
          metadata: mergeMessageContextMetadata(
            {
              control: { type: 'ambient_intervention' },
              llm_turn_id: llmTurn.id
            },
            messageContext
          )
        })
      }
      return parsed
    } catch (error) {
      await this.conversations.finishLlmTurn({
        llmTurnId: llmTurn.id,
        status: 'failed',
        response: { error: error instanceof Error ? error.message : String(error), raw_text: rawText ?? null }
      })
      return undefined
    }
  }

  private matchesFilter(
    batch: { agentUid: string; bindingName?: string },
    filter: { agentUid?: string; bindingName?: string }
  ): boolean {
    if (filter.agentUid && batch.agentUid && batch.agentUid !== filter.agentUid) return false
    if (filter.bindingName && batch.bindingName && batch.bindingName !== filter.bindingName) return false
    return true
  }

  private async dueMembers(now: number): Promise<string[]> {
    try {
      const redisDue = await redis.send('ZRANGEBYSCORE', [this.redisKey, '-inf', String(now)])
      return Array.isArray(redisDue) ? redisDue.map(String) : []
    } catch (error) {
      logger.warn({ error }, 'Ambient wake ZRANGEBYSCORE failed; no batches drained this pass')
      return []
    }
  }
}

function stringOrUndefined(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

export const aiAgentAmbientBatcher = new AiAgentAmbientBatcher()

function ambientRowRef(row: typeof AiAgentMessages.$inferSelect): JsonValue {
  return {
    type: 'ai_agent_message',
    id: row.id,
    role: row.role,
    kind: row.kind
  }
}

function scoreEntries(value: unknown[]): Array<[string, number]> {
  const entries: Array<[string, number]> = []
  for (let index = 0; index < value.length; index += 1) {
    const item = value[index]
    if (Array.isArray(item)) {
      const member = item[0]
      const score = Number(item[1])
      if (member !== undefined && Number.isFinite(score)) entries.push([String(member), score])
      continue
    }

    const score = Number(value[index + 1])
    if (Number.isFinite(score)) {
      entries.push([String(item), score])
      index += 1
    }
  }
  return entries
}

function parseAmbientRecognizerResult(text: string): AmbientRecognizerResult {
  const parsed = parseAmbientRecognizerJson(text)
  return {
    intervene: parsed.intervene === true,
    ...(typeof parsed.reason_summary === 'string' && parsed.reason_summary.trim()
      ? { reason_summary: parsed.reason_summary.trim() }
      : {})
  }
}

function parseAmbientRecognizerJson(text: string): Partial<AmbientRecognizerResult> {
  try {
    return parseJsonWithRepair<Partial<AmbientRecognizerResult>>(extractJsonObjectText(text))
  } catch (error) {
    const recovered = recoverAmbientRecognizerBoolean(text)
    if (recovered !== undefined) {
      return {
        intervene: recovered,
        reason_summary: recoverAmbientRecognizerReason(text)
      }
    }
    throw error
  }
}

function recoverAmbientRecognizerBoolean(text: string): boolean | undefined {
  if (/(^|[,{;\s])["']?intervene["']?\s*[:=]\s*true\b/i.test(text)) return true
  if (/(^|[,{;\s])["']?intervene["']?\s*[:=]\s*false\b/i.test(text)) return false
  return undefined
}

function recoverAmbientRecognizerReason(text: string): string | undefined {
  const match = text.match(/["']?reason_summary["']?\s*[:=]\s*["']?([^{}\n\r]+?)(?:["']?\s*[,}]|$)/i)
  const reason = match?.[1]?.trim()
  if (!reason) return undefined
  return reason.length > 240 ? `${reason.slice(0, 240)}...` : reason
}

function extractJsonObjectText(text: string): string {
  const trimmed = text.trim()
  const fenced = trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/i)
  const candidate = fenced?.[1]?.trim() ?? trimmed
  const firstBrace = candidate.indexOf('{')
  const lastBrace = candidate.lastIndexOf('}')
  if (firstBrace >= 0 && lastBrace > firstBrace) return candidate.slice(firstBrace, lastBrace + 1)
  return candidate
}
