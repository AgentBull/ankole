import { redis } from 'bun'
import type { JsonObject } from '@/common/db-schema'

export type ExternalGatewayVisibleOutputEventType =
  | 'stream.started'
  | 'stream.delta'
  | 'stream.finished'
  | 'stream.failed'

export interface ExternalGatewayVisibleOutputStreamKey {
  agentUid: string
  sessionId: string
  streamId: string
}

export interface ExternalGatewayVisibleOutputEvent extends ExternalGatewayVisibleOutputStreamKey {
  at?: Date
  delta?: string
  metadata?: JsonObject
  sequence: number
  type: ExternalGatewayVisibleOutputEventType
}

export interface ExternalGatewayVisibleOutputRecord {
  event: ExternalGatewayVisibleOutputEvent
  redisId: string
}

export interface ReadExternalGatewayVisibleOutputInput extends ExternalGatewayVisibleOutputStreamKey {
  count?: number
  end?: string
  start?: string
}

export interface ExternalGatewayVisibleOutputStream {
  append(event: ExternalGatewayVisibleOutputEvent): Promise<string>
  delete(key: ExternalGatewayVisibleOutputStreamKey): Promise<void>
  read(input: ReadExternalGatewayVisibleOutputInput): Promise<ExternalGatewayVisibleOutputRecord[]>
}

/**
 * Weak visible streaming surface for in-progress agent output.
 *
 * Redis stream entries are intentionally not final output truth. They are for
 * live UI/provider progress only; final provider-visible side effects are
 * recovered through the agent/outbox boundary.
 */
export class BunRedisExternalGatewayVisibleOutputStream implements ExternalGatewayVisibleOutputStream {
  private readonly keyPrefix: string
  private readonly maxLen: number
  private readonly ttlSeconds: number

  constructor(options: { keyPrefix?: string; maxLen?: number; ttlSeconds?: number } = {}) {
    this.keyPrefix = options.keyPrefix ?? 'bullx-agent:external-gateway:visible-output'
    this.maxLen = options.maxLen ?? 500
    this.ttlSeconds = options.ttlSeconds ?? 3600
  }

  async append(event: ExternalGatewayVisibleOutputEvent): Promise<string> {
    const key = this.keyFor(event)
    const payload = JSON.stringify({
      ...event,
      at: (event.at ?? new Date()).toISOString()
    })

    const redisId = await redis.send('XADD', [key, 'MAXLEN', '~', String(this.maxLen), '*', 'payload', payload])
    if (this.ttlSeconds > 0) await redis.send('EXPIRE', [key, String(this.ttlSeconds)])

    return String(redisId)
  }

  async read(input: ReadExternalGatewayVisibleOutputInput): Promise<ExternalGatewayVisibleOutputRecord[]> {
    const rows = await redis.send('XRANGE', [
      this.keyFor(input),
      input.start ?? '-',
      input.end ?? '+',
      'COUNT',
      String(input.count ?? 100)
    ])

    if (!Array.isArray(rows)) return []

    return rows.flatMap(row => {
      const record = parseRedisStreamRecord(row)
      if (!record) return []

      try {
        const parsed = JSON.parse(record.payload) as ExternalGatewayVisibleOutputEvent & { at?: string }
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

  async delete(key: ExternalGatewayVisibleOutputStreamKey): Promise<void> {
    await redis.send('DEL', [this.keyFor(key)])
  }

  private keyFor(input: ExternalGatewayVisibleOutputStreamKey): string {
    return [
      this.keyPrefix,
      encodeURIComponent(input.agentUid),
      encodeURIComponent(input.sessionId),
      encodeURIComponent(input.streamId)
    ].join(':')
  }
}

export const externalGatewayVisibleOutputStream = new BunRedisExternalGatewayVisibleOutputStream()

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
