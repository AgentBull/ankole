import { redis } from 'bun'
import type { JsonObject } from '@/common/db-schema'

/**
 * Lifecycle of one visible output stream as the user sees it.
 *
 * `delta` carries the incremental visible text; `started`/`finished`/`failed`
 * are the boundaries. These describe the user-facing surface only — internal
 * agent reasoning is never emitted here, so a consumer replaying these events
 * sees exactly what the human would see, not the chain of thought behind it.
 */
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

/**
 * One event in a visible output stream.
 *
 * `sequence` is the producer's own monotonic counter and is the field
 * consumers should order and de-duplicate on. The Redis stream id is storage
 * detail (and is only approximately ordered under `MAXLEN ~` trimming), so it
 * must not be used as the logical order key.
 */
export interface ExternalGatewayVisibleOutputEvent extends ExternalGatewayVisibleOutputStreamKey {
  at?: Date
  delta?: string
  metadata?: JsonObject
  sequence: number
  type: ExternalGatewayVisibleOutputEventType
}

/** A stored event paired with the Redis entry id it was read back from. */
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
    // Bounded both ways on purpose. The stream is live-progress only, so capping
    // length and giving every key an hour TTL keeps Redis memory flat without a
    // sweeper. Losing old entries is acceptable here: final user-visible output
    // is recovered through the agent/outbox path, not from this buffer.
    this.maxLen = options.maxLen ?? 500
    this.ttlSeconds = options.ttlSeconds ?? 3600
  }

  /** Appends one event and returns the Redis entry id. */
  async append(event: ExternalGatewayVisibleOutputEvent): Promise<string> {
    const key = this.keyFor(event)
    const payload = JSON.stringify({
      ...event,
      at: (event.at ?? new Date()).toISOString()
    })

    // `MAXLEN ~` lets Redis trim in whole macro-nodes instead of exactly: cheaper
    // than precise trimming, and a few extra entries past the cap do not matter
    // for a progress buffer. Refresh the TTL on every append so an actively
    // streaming key never expires mid-stream; only idle keys age out.
    const redisId = await redis.send('XADD', [key, 'MAXLEN', '~', String(this.maxLen), '*', 'payload', payload])
    if (this.ttlSeconds > 0) await redis.send('EXPIRE', [key, String(this.ttlSeconds)])

    return String(redisId)
  }

  /**
   * Reads back a range of stream events.
   *
   * Defaults to the full range (`-` .. `+`). Malformed or unparseable entries
   * are silently skipped rather than failing the whole read: a single corrupt
   * payload must not break live progress for the rest of the stream.
   */
  async read(input: ReadExternalGatewayVisibleOutputInput): Promise<ExternalGatewayVisibleOutputRecord[]> {
    const rows = await redis.send('XRANGE', [
      this.keyFor(input),
      input.start ?? '-',
      input.end ?? '+',
      'COUNT',
      String(input.count ?? 100)
    ])

    if (!Array.isArray(rows)) return []

    // `flatMap` with an empty array is the drop: any row that fails shape or JSON
    // parsing contributes nothing instead of throwing. The stored `at` is an ISO
    // string, so rehydrate it to a Date for callers.
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

  /**
   * Builds the Redis key for a stream. Each id component is percent-encoded so
   * a colon inside an id (the key separator) cannot blur the boundary between
   * components and make two distinct streams share a key.
   */
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

/**
 * Pulls the entry id and `payload` field out of one raw XRANGE row.
 *
 * An XRANGE entry is `[id, [field, value, field, value, ...]]`. The field list
 * is walked two at a time to find the `payload` pair. Returns undefined for any
 * shape that does not match, so the caller can drop it instead of throwing.
 */
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
