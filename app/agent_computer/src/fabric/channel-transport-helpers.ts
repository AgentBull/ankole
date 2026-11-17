import { isNumber } from '@agentbull/active-support'
import { Socket } from 'phoenix'
import { Buffer } from 'node:buffer'
import { errorMessage } from '../common/errors'
import { workerLogger } from '../worker/logging'
import type { Envelope } from './envelope-proto'
import { RuntimeFabricTransportError } from './fabric'
import type {
  ChannelSocketLike,
  ChannelSocketOptions,
  RuntimeFabricStream,
  StreamReply,
  StreamWindowLimits
} from './channel-transport'

const defaultConnectTimeoutMs = 10_000
const telemetryExportMethod = 'observability.spans.export'

export type StreamState = {
  nextSeq: number
  inFlight: Map<number, (outcome: PushOutcome) => void>
  paused: boolean
  creditWaiters: Array<() => void>
}

export type PushOutcome =
  | { status: 'ok' }
  | { status: 'error'; reason: string; reply: StreamReply }
  | { status: 'timeout' }
  | { status: 'closed' }

/** Classifies an envelope into the stream that carries it. */
export function runtimeFabricStream(envelope: Envelope): RuntimeFabricStream {
  switch (envelope.body.case) {
    case 'workerHeartbeat':
    case 'controlShutdown':
      return 'control'
    case 'rpcRequest':
      return envelope.body.value.method === telemetryExportMethod ? 'telemetry' : 'durable'
    default:
      return 'durable'
  }
}

export function createPhoenixSocket(
  endpoint: string,
  options: ChannelSocketOptions,
  connectTimeoutMs = defaultConnectTimeoutMs
): ChannelSocketLike {
  // Each Phoenix reconnect creates a WebSocket. Bound the entire handshake,
  // then let Phoenix apply its existing backoff after the abnormal close.
  class WorkerWebSocket extends WebSocket {
    private readonly connectTimer: ReturnType<typeof setTimeout>

    constructor(url: string, protocols?: string | string[]) {
      super(url, protocols)
      this.connectTimer = setTimeout(() => {
        if (this.readyState !== WebSocket.CONNECTING) return
        workerLogger.warning('worker.fabric_connect_timeout', 'runtime fabric socket connection timed out', {
          error_type: 'connect_timeout',
          timeout_ms: connectTimeoutMs
        })
        this.close(4000, 'connection timeout')
      }, connectTimeoutMs)
      this.addEventListener('open', () => clearTimeout(this.connectTimer), { once: true })
      this.addEventListener('close', () => clearTimeout(this.connectTimer), { once: true })
    }

    override close(code?: number, reason?: string): void {
      clearTimeout(this.connectTimer)
      super.close(code, reason)
    }
  }

  // The auth key travels as the Phoenix auth token in the WebSocket
  // subprotocol, never in the URL. `worker_id` is a query parameter and is
  // not a secret.
  return new Socket(endpoint, {
    transport: WorkerWebSocket,
    authToken: options.workerAuthKey,
    params: { worker_id: options.workerID },
    binaryType: 'arraybuffer',
    heartbeatIntervalMs: 15_000,
    reconnectAfterMs: reconnectDelayMs
  })
}

export function reconnectDelayMs(tries: number): number {
  return Math.min(5_000, 100 * 2 ** Math.min(tries, 6))
}

export function closeCode(event: unknown): number | undefined {
  return typeof event === 'object' && event !== null && 'code' in event && typeof event.code === 'number'
    ? event.code
    : undefined
}

export function closeFields(event: unknown) {
  const value = typeof event === 'object' && event !== null ? event : undefined
  return {
    close_code: closeCode(event),
    close_reason: value && 'reason' in value && typeof value.reason === 'string' ? value.reason : undefined,
    was_clean: value && 'wasClean' in value && typeof value.wasClean === 'boolean' ? value.wasClean : undefined
  }
}

export function socketErrorFields(event: unknown) {
  if (event instanceof Error) return { error: event, error_type: event.name }
  const value = typeof event === 'object' && event !== null ? event : undefined
  const error = value && 'error' in value ? value.error : undefined
  const message = value && 'message' in value && typeof value.message === 'string' ? value.message : undefined
  const type = value && 'type' in value && typeof value.type === 'string' ? value.type : undefined
  const cause = error instanceof Error ? error : new Error(message || `WebSocket ${type ?? 'error'} event`)
  return { error: cause, error_type: error instanceof Error ? error.name : value?.constructor.name, event_type: type }
}

export class StreamWindow {
  private count = 0
  private bytes = 0
  private credit: { messages: number; bytes: number } | undefined
  private readonly waiters: Array<() => void> = []

  constructor(private readonly limits: StreamWindowLimits) {}

  tryAcquire(bytes: number): boolean {
    if (!this.fits(bytes)) return false
    this.count += 1
    this.bytes += bytes
    return true
  }

  async acquire(bytes: number, closed: () => boolean, signal?: AbortSignal): Promise<void> {
    while (!this.tryAcquire(bytes)) {
      signal?.throwIfAborted()
      if (closed()) throw new RuntimeFabricTransportError('socket_closed', 'socket_closed')
      await waitForWake(this.waiters, signal)
    }
  }

  release(bytes: number): void {
    this.count -= 1
    this.bytes -= bytes
    this.wake()
  }

  /** Bounds the window by the control plane's remaining credit for this stream. */
  setCredit(messages: number, bytes: number): void {
    this.credit = { messages, bytes }
    this.wake()
  }

  resetCredit(): void {
    this.credit = undefined
    this.wake()
  }

  wake(): void {
    const waiters = this.waiters.splice(0)
    for (const waiter of waiters) waiter()
  }

  // One push is always allowed when nothing is in flight: the reply to it
  // refreshes the credit, so an exhausted credit cannot stall the stream.
  private fits(bytes: number): boolean {
    if (this.count === 0) return true
    const maxMessages = Math.min(this.limits.maxMessages, this.credit?.messages ?? Number.POSITIVE_INFINITY)
    const maxBytes = Math.min(this.limits.maxBytes, this.credit?.bytes ?? Number.POSITIVE_INFINITY)
    return this.count < maxMessages && this.bytes + bytes <= maxBytes
  }
}

export function waitForWake(waiters: Array<() => void>, signal?: AbortSignal, timeoutMs?: number): Promise<void> {
  signal?.throwIfAborted()
  return new Promise((resolve, reject) => {
    const remove = () => {
      const index = waiters.indexOf(wake)
      if (index >= 0) waiters.splice(index, 1)
      if (timer !== undefined) clearTimeout(timer)
      signal?.removeEventListener('abort', abort)
    }
    const wake = () => {
      remove()
      resolve()
    }
    const abort = () => {
      remove()
      reject(signal!.reason)
    }
    const timer = timeoutMs === undefined ? undefined : setTimeout(wake, timeoutMs)
    waiters.push(wake)
    signal?.addEventListener('abort', abort, { once: true })
  })
}

export function arrayBuffer(bytes: Buffer): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}

export function inboundBytes(payload: unknown): Buffer {
  if (payload instanceof ArrayBuffer) return Buffer.from(payload)
  if (payload instanceof Uint8Array) return Buffer.from(payload)
  throw new Error('binary payload expected')
}

export function newStreamState(): StreamState {
  return { nextSeq: 1, inFlight: new Map(), paused: false, creditWaiters: [] }
}

export function streamReply(response: unknown): StreamReply {
  if (typeof response !== 'object' || response === null) return {}
  const record = response as Record<string, unknown>
  return {
    messageCredit: optionalNumber(record.message_credit),
    byteCredit: optionalNumber(record.byte_credit),
    reason: typeof record.reason === 'string' ? record.reason : undefined,
    expected: optionalNumber(record.expected)
  }
}

function optionalNumber(value: unknown): number | undefined {
  return isNumber(value, true) ? value : undefined
}

export const DEFAULT_INBOUND_MESSAGE_DEDUP_LIMIT = 2_048

/**
 * Bounded O(1) LRU set of processed inbound `message_id`s across reconnects.
 * JavaScript `Set` iterates in insertion order, so deleting and re-adding moves
 * a seen ID to the most-recently-used tail while `keys().next()` yields the oldest.
 */
export class InboundMessageDedup {
  private readonly seen = new Set<string>()
  private readonly maxEntries: number

  constructor(maxEntries = DEFAULT_INBOUND_MESSAGE_DEDUP_LIMIT) {
    this.maxEntries = Math.max(1, maxEntries)
  }

  get size(): number {
    return this.seen.size
  }

  hasAndTouch(messageID: string): boolean {
    if (!messageID || !this.seen.has(messageID)) return false
    this.seen.delete(messageID)
    this.seen.add(messageID)
    return true
  }

  record(messageID: string): void {
    if (!messageID) return
    if (this.seen.has(messageID)) {
      this.seen.delete(messageID)
    } else if (this.seen.size >= this.maxEntries) {
      const oldest = this.seen.keys().next().value
      if (oldest !== undefined) this.seen.delete(oldest)
    }
    this.seen.add(messageID)
  }
}

export function replyReason(response: unknown): string {
  if (typeof response === 'object' && response !== null && 'reason' in response) {
    return String(response.reason)
  }
  return response === undefined ? 'unknown' : errorMessage(response)
}
