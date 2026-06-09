import { redis } from 'bun'
import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { completeSimple, parseJsonWithRepair, type Message } from '@earendil-works/pi-ai'
import { and, desc, eq, sql } from 'drizzle-orm'
import { DB } from '@/common/database'
import { AiAgentMessages, type JsonObject, type JsonValue } from '@/common/db-schema'
import { createUserMessage } from './core'
import type { AiAgentRuntimeProfile } from './config'
import {
  aiAgentConversationService,
  textContent,
  textFromContent,
  type AiAgentConversationService
} from './conversation-service'
import { toJsonValue } from '@/common/json'

interface AmbientBatch {
  agentUid: string
  bindingName?: string
  conversationId: string
  dueAt: Date
  firstSeenAt: Date
  providerRoomId: string
  providerThreadId: string
}

interface AmbientRecognizerResult {
  intervene: boolean
  reason_summary?: string
}

export class AiAgentAmbientBatcher {
  private readonly batches = new Map<string, AmbientBatch>()
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
    const key = this.batchKey(
      input.agentUid,
      input.bindingName,
      input.conversationId,
      input.providerRoomId,
      input.providerThreadId
    )
    const existing = this.batches.get(key)
    const firstSeenAt = existing?.firstSeenAt ?? new Date(now)
    const dueAt = new Date(
      Math.min(now + input.profile.ambient.batchWindowMs, firstSeenAt.getTime() + input.profile.ambient.hardCapMs)
    )
    this.batches.set(key, {
      agentUid: input.agentUid,
      bindingName: input.bindingName,
      conversationId: input.conversationId,
      dueAt,
      firstSeenAt,
      providerRoomId: input.providerRoomId,
      providerThreadId: input.providerThreadId
    })
    await redis.send('ZADD', [this.redisKey, String(dueAt.getTime()), key]).catch(() => undefined)
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
      const batch = this.batches.get(member) ?? this.batchFromMember(member)
      if (!batch) {
        await redis.send('ZREM', [this.redisKey, member]).catch(() => undefined)
        continue
      }
      if (!this.matchesFilter(batch, filter)) continue
      this.batches.delete(member)
      await redis.send('ZREM', [this.redisKey, member]).catch(() => undefined)
      const result = await this.recognize(batch.conversationId, profile)
      if (result?.intervene) {
        intervened.push({
          conversationId: batch.conversationId,
          providerRoomId: batch.providerRoomId,
          providerThreadId: batch.providerThreadId
        })
      }
    }
    return intervened
  }

  async nextDueDelayMs(input: { agentUid?: string; bindingName?: string } = {}): Promise<number | undefined> {
    const scores: number[] = []
    for (const batch of this.batches.values()) {
      if (this.matchesFilter(batch, input)) scores.push(batch.dueAt.getTime())
    }

    const redisEntries = await redis.send('ZRANGE', [this.redisKey, '0', '-1', 'WITHSCORES']).catch(() => [])
    if (Array.isArray(redisEntries)) {
      for (const [member, score] of scoreEntries(redisEntries)) {
        const batch = this.batches.get(member) ?? this.batchFromMember(member)
        if (batch && this.matchesFilter(batch, input)) scores.push(score)
      }
    }

    if (scores.length === 0) return undefined
    return Math.max(0, Math.min(...scores) - Date.now())
  }

  private async recognize(
    conversationId: string,
    profile: AiAgentRuntimeProfile
  ): Promise<AmbientRecognizerResult | undefined> {
    const rows = await DB.select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          eq(AiAgentMessages.role, 'im_ambient'),
          eq(AiAgentMessages.kind, 'normal'),
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`
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

    const systemPrompt =
      'Decide whether the AI coworker should proactively intervene in this room. Return only a strict JSON object, with no markdown.'
    const llmMessages: Message[] = [
      {
        role: 'user',
        timestamp: Date.now(),
        content: `Recent ambient room messages:\n${prompt}\n\nReturn {"intervene": boolean, "reason_summary": string}.`
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
        const introspection = parsed.reason_summary || 'Ambient context suggests the agent should intervene.'
        await this.conversations.appendMessage({
          conversationId,
          role: 'im_ambient',
          kind: 'introspection',
          content: textContent(introspection),
          agentMessage: createUserMessage(introspection),
          metadata: {
            control: { type: 'ambient_intervention' },
            llm_turn_id: llmTurn.id
          }
        })
      }
      return parsed
    } catch (error) {
      await this.conversations.finishLlmTurn({
        llmTurnId: llmTurn.id,
        status: 'failed',
        response: { error: error instanceof Error ? error.message : String(error) }
      })
      return undefined
    }
  }

  private batchKey(
    agentUid: string,
    bindingName: string | undefined,
    conversationId: string,
    providerRoomId: string,
    providerThreadId: string
  ): string {
    return JSON.stringify({
      agentUid,
      bindingName,
      conversationId,
      providerRoomId,
      providerThreadId
    })
  }

  private batchFromMember(member: string): AmbientBatch | undefined {
    try {
      const parsed = JSON.parse(member) as unknown
      if (typeof parsed !== 'object' || parsed === null) return undefined
      const batch = parsed as Partial<Record<keyof AmbientBatch, unknown>>
      if (
        typeof batch.conversationId !== 'string' ||
        typeof batch.providerRoomId !== 'string' ||
        typeof batch.providerThreadId !== 'string'
      ) {
        return undefined
      }
      return {
        agentUid: typeof batch.agentUid === 'string' ? batch.agentUid : '',
        bindingName: typeof batch.bindingName === 'string' ? batch.bindingName : undefined,
        conversationId: batch.conversationId,
        dueAt: new Date(0),
        firstSeenAt: typeof batch.firstSeenAt === 'string' ? new Date(batch.firstSeenAt) : new Date(0),
        providerRoomId: batch.providerRoomId,
        providerThreadId: batch.providerThreadId
      }
    } catch {
      return undefined
    }
  }

  private matchesFilter(batch: AmbientBatch, filter: { agentUid?: string; bindingName?: string }): boolean {
    if (filter.agentUid && batch.agentUid && batch.agentUid !== filter.agentUid) return false
    if (filter.bindingName && batch.bindingName && batch.bindingName !== filter.bindingName) return false
    return true
  }

  private async dueMembers(now: number): Promise<string[]> {
    const localDue = [...this.batches.entries()].filter(([, batch]) => batch.dueAt.getTime() <= now).map(([key]) => key)
    const redisDue = await redis.send('ZRANGEBYSCORE', [this.redisKey, '-inf', String(now)]).catch(() => [])
    if (!Array.isArray(redisDue)) return localDue
    return [...new Set([...localDue, ...redisDue.map(String)])]
  }
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
  const parsed = parseJsonWithRepair<Partial<AmbientRecognizerResult>>(extractJsonObjectText(text))
  return {
    intervene: parsed.intervene === true,
    ...(typeof parsed.reason_summary === 'string' && parsed.reason_summary.trim()
      ? { reason_summary: parsed.reason_summary.trim() }
      : {})
  }
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
