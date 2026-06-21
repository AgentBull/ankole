import { redis } from 'bun'
import { ms } from '@pleisto/active-support'
import type { AgentEvent, AgentMessage } from './core'
import type { JsonObject } from '@/common/db-schema'
import { createSealedCookieCodec } from '@/common/sealed-cookie'
import { SecretKeyPurpose } from '@/common/kms'
import { isJsonObject } from '@/common/json'

// Domain-separation context for the sealed token codec, so a reasoning-trace
// token can never be mistaken for a sealed value from another feature.
const REASONING_TRACE_TOKEN_CONTEXT = 'ai-agent:reasoning-trace:v1'
// Stamped into every token; a token whose version does not match on read is
// rejected, giving a clean break if the payload shape ever changes.
const REASONING_TRACE_TOKEN_VERSION = 'bullx.reasoning_trace_token.v1'
// How long a share link stays valid. Outlives the stream TTL on purpose: a stale
// link should report "expired trace" (the stream is gone) rather than fail to
// authorize, which would look like a permissions bug.
const REASONING_TRACE_TOKEN_MAX_AGE_MS = ms('30d')
// How long the live trace stream survives in Redis after its last write. A trace
// is an ephemeral "watch it think" view, not durable history, so it self-expires.
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

/** Append-only event log for one reasoning trace, abstracted so the Redis-stream backing can be swapped or faked in tests. */
export interface ReasoningTraceStream {
  append(event: ReasoningTraceEvent): Promise<string>
  delete(key: ReasoningTraceKey): Promise<void>
  exists(key: ReasoningTraceKey): Promise<boolean>
  read(input: ReadReasoningTraceInput): Promise<ReasoningTraceRecord[]>
  touch(key: ReasoningTraceKey): Promise<void>
}

/** Redis Streams implementation: one stream key per trace, capped in length and self-expiring so traces never accumulate unbounded. */
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
    // `MAXLEN ~` is the approximate trim: Redis caps the stream near maxLen but
    // may keep a few extra entries, which is far cheaper than an exact trim on
    // every append. `*` lets Redis assign the monotonic entry id (also the cursor).
    const redisId = await redis.send('XADD', [key, 'MAXLEN', '~', String(this.maxLen), '*', 'payload', payload])
    // Every append slides the TTL forward, so an actively-streaming trace stays
    // alive and only expires once writes stop for the full window.
    await this.touch(event)
    return String(redisId)
  }

  /** Reads a window of trace events. `start`/`end`/`count` map straight onto `XRANGE`; the HTTP layer passes an exclusive `(<id>` start to poll only what is new since the last cursor. */
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
              // Stored as ISO text; rehydrate to a Date, leaving it undefined if absent.
              at: parsed.at ? new Date(parsed.at) : undefined
            }
          }
        ]
      } catch {
        // A single unparseable entry is dropped rather than failing the whole
        // read — one corrupt record must not blank the viewer.
        return []
      }
    })
  }

  /** Resets the trace's TTL to the full window. Called after every append and on demand by the run's liveness beat, so a long live run keeps its trace from expiring mid-stream. */
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

  // Stream key from the trace's identity triple. Each part is URL-encoded so a
  // delimiter character inside an id cannot collide two distinct traces onto one
  // key (or let one key be addressed as another).
  private keyFor(input: ReasoningTraceKey): string {
    return [
      this.keyPrefix,
      encodeURIComponent(input.agentUid),
      encodeURIComponent(input.conversationId),
      encodeURIComponent(input.traceId)
    ].join(':')
  }
}

/** Process-wide singleton backing live reasoning traces. */
export const aiAgentReasoningTraceStream = new BunRedisReasoningTraceStream()

// Seals/opens the share token with a key dedicated to this purpose. The token is
// the capability a chat user clicks to view a trace, so it must be tamper-proof
// (signed+encrypted) and self-describing — it carries the trace identity and the
// binding needed to re-authorize the viewer, not just an opaque id.
const reasoningTraceTokenCodec = createSealedCookieCodec(
  SecretKeyPurpose.AI_AGENT_REASONING_TRACE,
  REASONING_TRACE_TOKEN_CONTEXT
)

/** Mints a sealed share token granting view access to one trace, stamped with an expiry the reader enforces. The returned `expiresAt` is surfaced so the caller can show/record when the link dies. */
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

/**
 * Opens and validates a share token, returning its payload or `undefined` if the
 * token is forged, expired (the codec enforces max-age), the wrong version, or
 * missing a required field. The explicit field re-checks are deliberate: the
 * static type describes the *minting* shape, but at read time the payload is
 * attacker-influenced bytes, so the identity fields are re-asserted as non-empty
 * strings before any of them is trusted to address a stream or authorize a view.
 */
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

/**
 * Translates the live agent event loop into the trace event log a viewer
 * consumes. One recorder is bound to one trace for one run attempt. It owns two
 * pieces of per-trace state: a monotonically increasing `sequence` so the viewer
 * can order events, and `lastReasoningText` so reasoning is emitted as small
 * deltas rather than re-sending the whole growing thought each tick (see
 * {@link recordAssistantReasoning}). `closed` latches at the terminal event so a
 * late stray event after finish cannot append past the end.
 */
export class ReasoningTraceRecorder {
  private closed = false
  private lastReasoningText = ''
  private sequence = 0

  constructor(
    private readonly key: ReasoningTraceKey,
    private readonly stream: ReasoningTraceStream = aiAgentReasoningTraceStream
  ) {}

  /** Emits the opening event; `metadata` carries run context the viewer header shows. */
  async start(metadata: JsonObject = {}): Promise<void> {
    await this.append('trace.started', { metadata })
  }

  /** Slides the underlying stream's TTL forward without writing an event — the run's liveness beat calls this to keep a long trace alive. */
  touch(): Promise<void> {
    return this.stream.touch(this.key)
  }

  /** Routes one agent-loop event to its trace event. Reasoning updates and the assistant `turn_end` become reasoning deltas; tool start/update/end become tool-status events. Other event kinds are ignored. */
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
    // `turn_end` re-reads the final assistant message; the dedup in
    // `recordAssistantReasoning` keeps this from re-emitting text already streamed
    // via `message_update`, so it only catches reasoning that arrived all at once.
    if (event.type === 'turn_end' && event.message.role === 'assistant') {
      await this.recordAssistantReasoning(event.message)
    }
  }

  /**
   * Writes the terminal event and latches the recorder closed. Anything other
   * than `succeeded` is recorded as `trace.failed` with the real status in
   * metadata, so the viewer can show "cancelled" / "fenced" distinctly while
   * still treating them all as a non-success end. Idempotent via `closed`.
   */
  async finish(status: 'succeeded' | 'failed' | 'cancelled' | 'fenced' | undefined): Promise<void> {
    if (this.closed) return
    this.closed = true
    await this.append(status === 'succeeded' ? 'trace.finished' : 'trace.failed', {
      metadata: { status: status ?? 'failed' }
    })
  }

  /**
   * Emits the model's reasoning incrementally. The thinking text grows by
   * appending, so when the new text extends the last (`startsWith`) only the
   * suffix is sent as a `reasoning.delta` — the common case, keeping each event
   * tiny. If the text diverges instead (a rewrite, or a fresh thinking block) the
   * full text is sent as a `reasoning.replace` so the viewer resyncs. Unchanged
   * or empty text is skipped, which is what de-dupes the `turn_end` re-read.
   */
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

  // Stamps the trace identity and the next sequence number onto an event before
  // it hits the stream. `sequence++` is the per-event ordinal the viewer orders by.
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

// Pulls the model's thinking out of an assistant message: concatenates every
// `thinking` block. Tolerates both block shapes (`thinking` and `text` fields)
// because providers differ in which one carries hidden-CoT content.
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

// Unpacks one `XRANGE` row — `[id, [field, value, field, value, ...]]` — into the
// id and the `payload` field's value. Scans field pairs by stride of two and
// returns undefined on any shape it does not recognize, so a malformed row is
// skipped by the caller rather than throwing.
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
