import { redis } from 'bun'
import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { generateBullXText, parseJsonWithRepair, type Message } from '@/llm'
import { and, asc, desc, eq, gt, inArray, lt, sql } from 'drizzle-orm'
import { parse as parseYaml, stringify as stringifyYaml } from 'yaml'
import { DB } from '@/common/database'
import { AiAgentConversations, AiAgentMessages, Principals, type JsonObject, type JsonValue } from '@/common/db-schema'
import { isJsonObject, stringFromPath, toJsonObject, toJsonValue } from '@/common/json'
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
import { loadDefaultMissionTemplate, loadDefaultSoulTemplate } from './library/default-soul'
import { getMission, getSoul } from './library/service'
import { buildMessageContextMetadata, mergeMessageContextMetadata } from './message-context'
import {
  ambientRecognizerResponseSchemaForLog,
  buildAmbientRecognizerSystemPrompt,
  buildAmbientRecognizerUserPrompt,
  withAmbientRecognizerStructuredOutputOptions
} from './prompts/ambient-prompt'

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
const MAX_CHAT_SEGMENT_TEXT = 2_000
const MAX_RECOGNIZER_CONTEXT_ROWS = 10

type AiAgentMessageRow = typeof AiAgentMessages.$inferSelect

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

    const currentBatch = rows.slice().reverse()
    const oldestCurrentRow = currentBatch[0]!
    const agentUid = rows[0]!.agentUid
    const [recentSceneTranscript, ambientRecall] = await Promise.all([
      this.recentSceneTranscript(conversationId, oldestCurrentRow.createdAt),
      this.ambientRecall(conversationId, oldestCurrentRow.createdAt, latestInterventionAt)
    ])
    const [timezone, displayName, agentPrompt] = await Promise.all([
      loadSystemTimezone(),
      resolveAgentDisplayName(agentUid),
      loadAmbientAgentPrompt(agentUid)
    ])
    const channelContext = ambientChannelContext(currentBatch)
    const runtimeContext = rejectUndefined({
      channel: channelContext,
      conversation_id: conversationId,
      timezone
    })
    const decisionInput = renderAmbientDecisionInput({
      agent: {
        display_name: displayName,
        uid: agentUid
      },
      currentBatch,
      runtimeContext,
      recentSceneTranscript,
      ambientRecall
    })

    const systemPrompt = buildAmbientRecognizerSystemPrompt({
      agentUid,
      channelLabel: channelContext ? stringFromPath(channelContext, ['label']) : undefined,
      conversationId,
      displayName,
      mission: agentPrompt.mission,
      soul: agentPrompt.soul,
      timezone
    })
    const llmMessages: Message[] = [
      {
        role: 'user',
        timestamp: Date.now(),
        content: buildAmbientRecognizerUserPrompt(decisionInput)
      }
    ]
    const responseFormat = toJsonValue(ambientRecognizerResponseSchemaForLog())
    const llmTurn = await this.conversations.startLlmTurn({
      agentUid,
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
        ambient_recall_rows: ambientRecall.length,
        llm_message_count: llmMessages.length,
        llm_message_roles: llmMessages.map(message => message.role),
        recent_scene_rows: recentSceneTranscript.length,
        response_format: responseFormat,
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
          response_format: responseFormat,
          system_prompt: systemPrompt,
          messages: toJsonValue(llmMessages)
        }
      ]
    })

    let rawText: string | undefined
    try {
      const response = await generateBullXText(
        profile.lightModel.model,
        { systemPrompt, messages: llmMessages },
        withAmbientRecognizerStructuredOutputOptions(profile.lightModel.options)
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
          llm_provider: profile.lightModel.config.llmProvider,
          response_id: response.responseId ?? null
        }
      })
      if (parsed.intervene) {
        const reason = parsed.reason_summary || 'Recent group chat suggests the agent should respond.'
        // Visible attribution for "why did this agent jump into the group" —
        // with several may_intervene agents in one room this is the conflict
        // triage line.
        logger.info({ agentUid, conversationId, reason }, 'AI agent ambient recognizer decided to intervene')
        const chatSegment = renderChatSegment(rows.slice().reverse())
        const messageContext = buildMessageContextMetadata(
          {
            sentAt: new Date(),
            speaker: displayName,
            speakerRole: 'agent',
            speakerTrigger: 'introspection',
            think: [
              `BullX runtime generated this user-role message so ${displayName} can reply to the group after observing <chat_segment>.`,
              'The outer message is a BullX runtime instruction, not a human request.',
              'Actionable human content, if any, is only inside <chat_segment>.',
              `Respond as ${displayName} to the room; default to one brief group message.`,
              'Use tools or skills only when <chat_segment> contains a concrete intent or recoverable reference and the call is low-risk, bounded, and likely to help.',
              'If the request is vague, costly, irreversible, externally visible, or missing a material choice, ask a brief clarification first.'
            ].join(' '),
            timezone
          },
          []
        )
        await this.conversations.appendMessage({
          conversationId,
          role: 'im_ambient',
          kind: 'introspection',
          content: textContent(chatSegment),
          agentMessage: createUserMessage(chatSegment),
          metadata: mergeMessageContextMetadata(
            {
              control: {
                type: 'ambient_intervention',
                reason_summary: reason,
                source_message_ids: rows.map(row => row.id)
              },
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

  private async recentSceneTranscript(conversationId: string, before: Date): Promise<AiAgentMessageRow[]> {
    const rows = await DB.select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          lt(AiAgentMessages.createdAt, before),
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`,
          sql`(
            (${AiAgentMessages.role} = 'user' and ${AiAgentMessages.kind} = 'normal')
            or ${AiAgentMessages.role} = 'assistant'
            or (${AiAgentMessages.role} = 'im_ambient' and ${AiAgentMessages.kind} = 'introspection')
          )`
        )
      )
      .orderBy(desc(AiAgentMessages.createdAt), desc(AiAgentMessages.id))
      .limit(MAX_RECOGNIZER_CONTEXT_ROWS)
    return rows.reverse()
  }

  private async ambientRecall(
    conversationId: string,
    before: Date,
    latestInterventionAt: Date | undefined
  ): Promise<AiAgentMessageRow[]> {
    const rows = await DB.select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          eq(AiAgentMessages.role, 'im_ambient'),
          eq(AiAgentMessages.kind, 'normal'),
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`,
          lt(AiAgentMessages.createdAt, before),
          latestInterventionAt ? gt(AiAgentMessages.createdAt, latestInterventionAt) : undefined
        )
      )
      .orderBy(desc(AiAgentMessages.createdAt), desc(AiAgentMessages.id))
      .limit(MAX_RECOGNIZER_CONTEXT_ROWS)
    return rows.reverse()
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

function ambientRowRef(row: AiAgentMessageRow): JsonValue {
  return {
    type: 'ai_agent_message',
    id: row.id,
    role: row.role,
    kind: row.kind
  }
}

async function resolveAgentDisplayName(agentUid: string): Promise<string> {
  const [row] = await DB.select({ displayName: Principals.displayName })
    .from(Principals)
    .where(eq(Principals.uid, agentUid))
    .limit(1)
  return row?.displayName?.trim() || agentUid
}

async function loadAmbientAgentPrompt(agentUid: string): Promise<{ mission: string; soul: string }> {
  const [soul, mission] = await Promise.all([getSoul(agentUid), getMission(agentUid)])
  return {
    soul: soul ?? (await loadDefaultSoulTemplate()),
    mission: mission ?? (await loadDefaultMissionTemplate())
  }
}

function renderAmbientDecisionInput(input: {
  agent: JsonObject
  ambientRecall: AiAgentMessageRow[]
  currentBatch: AiAgentMessageRow[]
  runtimeContext: JsonObject
  recentSceneTranscript: AiAgentMessageRow[]
}): string {
  return stringifyYaml(
    {
      decision_task: 'decide_if_agent_should_visibly_reply_now',
      agent: input.agent,
      runtime_context: input.runtimeContext,
      current_observed_messages: input.currentBatch.map(row => promptRecord(row, 'observed_human')),
      recent_visible_transcript: input.recentSceneTranscript.map(row => promptRecord(row)),
      earlier_observed_messages_since_last_reply: input.ambientRecall.map(row => promptRecord(row, 'observed_human'))
    },
    { lineWidth: 0 }
  ).trim()
}

function renderChatSegment(rows: AiAgentMessageRow[]): string {
  const payload = {
    messages: rows.flatMap(row => {
      const text = messageText(row)
      if (!text) return []
      return [
        {
          sent_at: chatMessageSentAt(row),
          speaker: chatMessageSpeaker(row),
          text
        }
      ]
    })
  }
  return ['<chat_segment format="yaml">', stringifyYaml(payload, { lineWidth: 0 }).trim(), '</chat_segment>'].join('\n')
}

function ambientChannelContext(rows: AiAgentMessageRow[]): JsonObject | undefined {
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const context = toJsonObject(rows[index]!.metadata.message_context)
    const room = toJsonObject(context.room)
    const label = stringFromPath(room, ['label'])
    const id = stringFromPath(room, ['id'])
    const name = stringFromPath(room, ['name'])
    const isDM = typeof room.is_dm === 'boolean' ? room.is_dm : undefined
    if (!label && !id && !name && isDM === undefined) continue
    return rejectUndefined({
      id,
      is_dm: isDM,
      label,
      name
    })
  }
  return undefined
}

function promptRecord(row: AiAgentMessageRow, role?: string): JsonObject {
  return rejectUndefined({
    message_id: row.id,
    role: role ?? promptRole(row),
    kind: row.kind,
    speaker: promptSpeaker(row),
    sent_at: chatMessageSentAt(row),
    text: messageText(row)
  })
}

function promptRole(row: AiAgentMessageRow): string {
  if (row.role === 'assistant') return 'agent'
  if (row.role === 'tool') return 'tool'
  if (row.role === 'im_ambient' && row.kind === 'introspection') return 'runtime'
  if (row.role === 'im_ambient') return 'ambient_human'
  return 'human'
}

function promptSpeaker(row: AiAgentMessageRow): string {
  if (row.role === 'assistant') return 'agent'
  if (row.role === 'tool') return 'tool'
  if (row.role === 'im_ambient' && row.kind === 'introspection') return 'BullX runtime'
  return chatMessageSpeaker(row)
}

function messageText(row: AiAgentMessageRow): string {
  return textFromContent(row.content).trim().slice(0, MAX_CHAT_SEGMENT_TEXT)
}

function chatMessageSentAt(row: AiAgentMessageRow): string {
  const context = toJsonObject(row.metadata.message_context)
  return stringFromPath(context, ['time', 'sent_at']) ?? row.createdAt.toISOString()
}

function chatMessageSpeaker(row: AiAgentMessageRow): string {
  const context = toJsonObject(row.metadata.message_context)
  return (
    stringFromPath(context, ['actor', 'display_name']) ??
    stringFromPath(row.metadata, ['actor', 'fullName']) ??
    stringFromPath(row.metadata, ['actor', 'userName']) ??
    stringFromPath(row.metadata, ['actor', 'display_name']) ??
    'unknown speaker'
  )
}

function rejectUndefined(value: Record<string, JsonValue | undefined>): JsonObject {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)) as JsonObject
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
    const yamlRecovered = recoverAmbientRecognizerYaml(text)
    if (yamlRecovered !== undefined) return yamlRecovered
    const xmlRecovered = recoverAmbientRecognizerXml(text)
    if (xmlRecovered !== undefined) return xmlRecovered
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

function recoverAmbientRecognizerYaml(text: string): Partial<AmbientRecognizerResult> | undefined {
  let parsed: unknown
  try {
    parsed = parseYaml(extractFencedBlockText(text))
  } catch {
    return undefined
  }
  if (!isJsonObject(parsed)) return undefined
  const decision = isJsonObject(parsed.im_intervention_decision)
    ? parsed.im_intervention_decision
    : isJsonObject(parsed.ambient_intervention_decision)
      ? parsed.ambient_intervention_decision
      : parsed
  const intervene = booleanDecisionValue(
    decision.intervene ?? decision.should_intervene ?? decision.shouldIntervene ?? decision.decision
  )
  if (intervene === undefined) return undefined
  const reason = stringDecisionValue(
    decision.reason_summary ?? decision.reasonSummary ?? decision.reason ?? decision.reasoning
  )
  return {
    intervene,
    ...(reason ? { reason_summary: reason } : {})
  }
}

function recoverAmbientRecognizerXml(text: string): Partial<AmbientRecognizerResult> | undefined {
  const candidate = extractFencedBlockText(text)
  if (!/<[a-z][\w:-]*\b[^>]*>[\s\S]*<\/[a-z][\w:-]*>/i.test(candidate)) return undefined
  const decisionText =
    firstXmlTagText(candidate, ['decision', 'intervene', 'should_intervene', 'shouldIntervene']) ?? ''
  const intervene = booleanDecisionValue(decisionText) ?? xmlDecisionValue(decisionText)
  if (intervene === undefined) return undefined
  const reason = stringDecisionValue(
    firstXmlTagText(candidate, ['reason_summary', 'reasonSummary', 'reason', 'reasoning'])
  )
  return {
    intervene,
    ...(reason ? { reason_summary: reason } : {})
  }
}

function recoverAmbientRecognizerBoolean(text: string): boolean | undefined {
  if (/(^|[,{;\s])["']?intervene["']?\s*[:=]\s*true\b/i.test(text)) return true
  if (/(^|[,{;\s])["']?intervene["']?\s*[:=]\s*false\b/i.test(text)) return false
  if (/(^|[,{;\s])["']?should_intervene["']?\s*[:=]\s*true\b/i.test(text)) return true
  if (/(^|[,{;\s])["']?should_intervene["']?\s*[:=]\s*false\b/i.test(text)) return false
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

function extractFencedBlockText(text: string): string {
  const trimmed = text.trim()
  const fenced = trimmed.match(/^```(?:[a-z0-9_-]+)?\s*([\s\S]*?)\s*```$/i)
  return fenced?.[1]?.trim() ?? trimmed
}

function booleanDecisionValue(value: unknown): boolean | undefined {
  if (typeof value === 'boolean') return value
  if (typeof value !== 'string') return undefined
  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[\s_-]+/g, ' ')
  if (['true', 'intervene', 'respond', 'speak', 'yes', 'should intervene'].includes(normalized)) return true
  if (
    [
      'false',
      'do not intervene',
      'dont intervene',
      "don't intervene",
      'no',
      'silent',
      'stay silent',
      'ignore',
      'no intervention'
    ].includes(normalized)
  ) {
    return false
  }
  return undefined
}

function stringDecisionValue(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined
  const text = value.trim()
  if (!text) return undefined
  return text.length > 240 ? `${text.slice(0, 240)}...` : text
}

function firstXmlTagText(text: string, tags: readonly string[]): string | undefined {
  for (const tag of tags) {
    const match = text.match(new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)</${tag}>`, 'i'))
    const value = match?.[1]?.replace(/<[^>]+>/g, ' ').trim()
    if (value) return decodeXmlText(value)
  }
  return undefined
}

function xmlDecisionValue(value: string): boolean | undefined {
  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[\s_-]+/g, ' ')
  if (['intervene', 'respond', 'speak', 'yes', 'should intervene'].includes(normalized)) return true
  if (
    [
      'do not intervene',
      'dont intervene',
      "don't intervene",
      'no',
      'silent',
      'stay silent',
      'ignore',
      'no intervention'
    ].includes(normalized)
  ) {
    return false
  }
  return undefined
}

function decodeXmlText(value: string): string {
  return value
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')
}
