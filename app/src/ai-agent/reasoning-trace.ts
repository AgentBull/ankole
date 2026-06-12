import { redis } from 'bun'
import { ms } from '@pleisto/active-support'
import type { AgentEvent, AgentMessage } from './core'
import type { JsonObject } from '@/common/db-schema'
import { createSealedCookieCodec } from '@/common/sealed-cookie'
import { SecretKeyPurpose } from '@/common/kms'
import { isJsonObject } from '@/common/json'

const REASONING_TRACE_TOKEN_CONTEXT = 'ai-agent:reasoning-trace:v1'
const REASONING_TRACE_TOKEN_VERSION = 'bullx.reasoning_trace_token.v1'
const REASONING_TRACE_TOKEN_MAX_AGE_MS = ms('30d')
export const REASONING_TRACE_TTL_MS = ms('24h')

export type ReasoningTraceEventType =
  | 'trace.started'
  | 'reasoning.delta'
  | 'reasoning.replace'
  | 'tool.started'
  | 'tool.updated'
  | 'tool.ended'
  | 'trace.finished'
  | 'trace.failed'

export type ReasoningTraceToolStatus = 'running' | 'succeeded' | 'failed'

export interface ReasoningTraceKey {
  agentUid: string
  conversationId: string
  traceId: string
}

export interface ReasoningTraceRef extends ReasoningTraceKey {
  bindingName: string
  expiresAt: string
  providerRoomId?: string
  providerThreadId?: string
  traceUrl?: string
}

export interface ReasoningTraceTokenPayload extends ReasoningTraceKey {
  bindingName: string
  expiresAt: number
  issuedAt: number
  providerRoomId?: string
  providerThreadId?: string
  version: typeof REASONING_TRACE_TOKEN_VERSION
}

export interface ReasoningTraceEvent extends ReasoningTraceKey {
  at?: Date
  delta?: string
  metadata?: JsonObject
  sequence: number
  status?: ReasoningTraceToolStatus
  text?: string
  toolCallId?: string
  toolName?: string
  type: ReasoningTraceEventType
}

export interface ReasoningTraceRecord {
  event: ReasoningTraceEvent
  redisId: string
}

export interface ReadReasoningTraceInput extends ReasoningTraceKey {
  count?: number
  end?: string
  start?: string
}

export interface ReasoningTraceStream {
  append(event: ReasoningTraceEvent): Promise<string>
  delete(key: ReasoningTraceKey): Promise<void>
  exists(key: ReasoningTraceKey): Promise<boolean>
  read(input: ReadReasoningTraceInput): Promise<ReasoningTraceRecord[]>
  touch(key: ReasoningTraceKey): Promise<void>
}

export class BunRedisReasoningTraceStream implements ReasoningTraceStream {
  private readonly keyPrefix: string
  private readonly maxLen: number
  private readonly ttlSeconds: number

  constructor(options: { keyPrefix?: string; maxLen?: number; ttlSeconds?: number } = {}) {
    this.keyPrefix = options.keyPrefix ?? 'bullx-agent:ai-agent:reasoning-trace'
    this.maxLen = options.maxLen ?? 5_000
    this.ttlSeconds = options.ttlSeconds ?? Math.floor(REASONING_TRACE_TTL_MS / 1000)
  }

  async append(event: ReasoningTraceEvent): Promise<string> {
    const key = this.keyFor(event)
    const payload = JSON.stringify({
      ...event,
      at: (event.at ?? new Date()).toISOString()
    })
    const redisId = await redis.send('XADD', [key, 'MAXLEN', '~', String(this.maxLen), '*', 'payload', payload])
    await this.touch(event)
    return String(redisId)
  }

  async read(input: ReadReasoningTraceInput): Promise<ReasoningTraceRecord[]> {
    const rows = await redis.send('XRANGE', [
      this.keyFor(input),
      input.start ?? '-',
      input.end ?? '+',
      'COUNT',
      String(input.count ?? 200)
    ])
    if (!Array.isArray(rows)) return []

    return rows.flatMap(row => {
      const record = parseRedisStreamRecord(row)
      if (!record) return []

      try {
        const parsed = JSON.parse(record.payload) as ReasoningTraceEvent & { at?: string }
        return [
          {
            redisId: record.redisId,
            event: {
              ...parsed,
              at: parsed.at ? new Date(parsed.at) : undefined
            }
          }
        ]
      } catch {
        return []
      }
    })
  }

  async touch(key: ReasoningTraceKey): Promise<void> {
    if (this.ttlSeconds > 0) await redis.send('EXPIRE', [this.keyFor(key), String(this.ttlSeconds)])
  }

  async delete(key: ReasoningTraceKey): Promise<void> {
    await redis.send('DEL', [this.keyFor(key)])
  }

  async exists(key: ReasoningTraceKey): Promise<boolean> {
    const result = await redis.send('EXISTS', [this.keyFor(key)])
    return Number(result) > 0
  }

  private keyFor(input: ReasoningTraceKey): string {
    return [
      this.keyPrefix,
      encodeURIComponent(input.agentUid),
      encodeURIComponent(input.conversationId),
      encodeURIComponent(input.traceId)
    ].join(':')
  }
}

export const aiAgentReasoningTraceStream = new BunRedisReasoningTraceStream()

const reasoningTraceTokenCodec = createSealedCookieCodec(
  SecretKeyPurpose.AI_AGENT_REASONING_TRACE,
  REASONING_TRACE_TOKEN_CONTEXT
)

export function createReasoningTraceToken(input: {
  agentUid: string
  bindingName: string
  conversationId: string
  providerRoomId?: string
  providerThreadId?: string
  traceId: string
}): { expiresAt: Date; token: string } {
  const issuedAt = Date.now()
  const expiresAt = issuedAt + REASONING_TRACE_TOKEN_MAX_AGE_MS
  const token = reasoningTraceTokenCodec.seal({
    ...input,
    expiresAt,
    issuedAt,
    version: REASONING_TRACE_TOKEN_VERSION
  } satisfies ReasoningTraceTokenPayload)
  return { expiresAt: new Date(expiresAt), token }
}

export function readReasoningTraceToken(token: string): ReasoningTraceTokenPayload | undefined {
  const payload = reasoningTraceTokenCodec.read<ReasoningTraceTokenPayload>(token)
  if (!payload || payload.version !== REASONING_TRACE_TOKEN_VERSION) return undefined
  if (
    !payload.agentUid ||
    !payload.bindingName ||
    !payload.conversationId ||
    !payload.traceId ||
    typeof payload.agentUid !== 'string' ||
    typeof payload.bindingName !== 'string' ||
    typeof payload.conversationId !== 'string' ||
    typeof payload.traceId !== 'string'
  ) {
    return undefined
  }
  return payload
}

export class ReasoningTraceRecorder {
  private closed = false
  private lastReasoningText = ''
  private sequence = 0

  constructor(
    private readonly key: ReasoningTraceKey,
    private readonly stream: ReasoningTraceStream = aiAgentReasoningTraceStream
  ) {}

  async start(metadata: JsonObject = {}): Promise<void> {
    await this.append('trace.started', { metadata })
  }

  touch(): Promise<void> {
    return this.stream.touch(this.key)
  }

  async recordAgentEvent(event: AgentEvent): Promise<void> {
    if (this.closed) return
    if (event.type === 'message_update' && event.message.role === 'assistant') {
      await this.recordAssistantReasoning(event.message)
      return
    }
    if (event.type === 'tool_execution_start') {
      await this.append('tool.started', {
        toolCallId: event.toolCallId,
        toolName: event.toolName,
        status: 'running'
      })
      return
    }
    if (event.type === 'tool_execution_update') {
      await this.append('tool.updated', {
        toolCallId: event.toolCallId,
        toolName: event.toolName,
        status: 'running'
      })
      return
    }
    if (event.type === 'tool_execution_end') {
      await this.append('tool.ended', {
        toolCallId: event.toolCallId,
        toolName: event.toolName,
        status: event.isError ? 'failed' : 'succeeded'
      })
      return
    }
    if (event.type === 'turn_end' && event.message.role === 'assistant') {
      await this.recordAssistantReasoning(event.message)
    }
  }

  async finish(status: 'succeeded' | 'failed' | 'cancelled' | 'fenced' | undefined): Promise<void> {
    if (this.closed) return
    this.closed = true
    await this.append(status === 'succeeded' ? 'trace.finished' : 'trace.failed', {
      metadata: { status: status ?? 'failed' }
    })
  }

  private async recordAssistantReasoning(message: AgentMessage): Promise<void> {
    const text = assistantReasoningText(message)
    if (!text || text === this.lastReasoningText) return
    if (text.startsWith(this.lastReasoningText)) {
      const delta = text.slice(this.lastReasoningText.length)
      this.lastReasoningText = text
      await this.append('reasoning.delta', { delta })
      return
    }
    this.lastReasoningText = text
    await this.append('reasoning.replace', { text })
  }

  private append(
    type: ReasoningTraceEventType,
    extra: Omit<Partial<ReasoningTraceEvent>, keyof ReasoningTraceKey | 'sequence' | 'type'> = {}
  ): Promise<string> {
    return this.stream.append({
      ...this.key,
      sequence: this.sequence++,
      type,
      ...extra
    })
  }
}

function assistantReasoningText(message: AgentMessage): string {
  if (message.role !== 'assistant' || !Array.isArray(message.content)) return ''
  return message.content
    .flatMap(block => {
      if (!isJsonObject(block)) return []
      if (block.type !== 'thinking') return []
      if (typeof block.thinking === 'string') return [block.thinking]
      if (typeof block.text === 'string') return [block.text]
      return []
    })
    .join('\n')
}

function parseRedisStreamRecord(row: unknown): { payload: string; redisId: string } | undefined {
  if (!Array.isArray(row) || row.length < 2) return undefined

  const redisId = String(row[0])
  const fields = row[1]
  if (!Array.isArray(fields)) return undefined

  for (let index = 0; index < fields.length; index += 2) {
    if (String(fields[index]) === 'payload') {
      const payload = fields[index + 1]
      return typeof payload === 'string' ? { payload, redisId } : undefined
    }
  }

  return undefined
}
