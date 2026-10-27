import { Socket } from 'phoenix'
import { Buffer } from 'node:buffer'
import { errorMessage, toError } from '../common/errors'
import { workerLogger } from '../worker/logging'
import { decodeEnvelope, encodeEnvelope, ProtocolVersion, Stream, type Envelope } from './envelope_proto'
import {
  RuntimeFabricTransportError,
  type EnvelopeSendOptions,
  type RuntimeFabricHost,
  type RuntimeFabricReceiveOutcome
} from './fabric'

/**
 * Phoenix Channel client for the RuntimeFabric worker connection.
 *
 * One WebSocket carries three logical streams from the Worker to the control
 * plane. Every envelope names its stream and carries a per-stream
 * `transport_seq` that starts at 1 on each join. The control plane answers a
 * push with a cumulative acknowledgement (`acked_seq`) and the remaining
 * `message_credit` and `byte_credit` of that stream. Credit bounds the window;
 * each push's own reply confirms its business outcome. A cumulative ACK only
 * confirms consumed sequence numbers, which can include business rejections. A
 * `flow_control` refusal did not consume its sequence number, so that
 * retry repeats the same seq; a `bad_sequence` reply means the streams are out
 * of step and the Worker rejoins, which resets both sides to 1.
 *
 * Commands and replies from the control plane share one sequence per
 * connection. The Worker accepts them in order into a bounded inbound queue
 * and acknowledges cumulatively on the `ack` event with its remaining queue
 * capacity. Replies already queued are delivered before the disconnect event.
 * An unanswered push fails; this transport stores no durable replay buffer.
 * The control plane repeats durable work through its own delivery records.
 */

export type RuntimeFabricStream = 'control' | 'durable' | 'telemetry'

type PushStatus = 'ok' | 'error' | 'timeout'

/** The subset of the Phoenix `Push` API this transport uses. */
export type ChannelPushLike = {
  receive(status: PushStatus, callback: (response?: unknown) => void): ChannelPushLike
}

/** The subset of the Phoenix `Channel` API this transport uses. */
export type ChannelLike = {
  state: string
  join(timeout?: number): ChannelPushLike
  leave(timeout?: number): ChannelPushLike
  push(event: string, payload: object, timeout?: number): ChannelPushLike
  on(event: string, callback: (payload: unknown) => void): number
  onClose(callback: () => void): number
  onError(callback: (reason?: unknown) => void): number
}

/** The subset of the Phoenix `Socket` API this transport uses. */
export type ChannelSocketLike = {
  channel(topic: string, params: object | (() => object)): ChannelLike
  connect(): void
  disconnect(callback?: () => void): void
  isConnected(): boolean
  onOpen(callback: () => void): unknown
  onClose(callback: (event: unknown) => void): unknown
  onError(callback: (error: unknown) => void): unknown
}

export type ChannelSocketOptions = {
  workerID: string
  workerAuthKey: string
}

export type ChannelTransportConfig = {
  endpoint: string
  workerID: string
  incarnationID: string
  workerAuthKey: string
}

export type ChannelTransportOptions = {
  /** Reports current capacity on every join and reconnect. */
  joinParams: () => WorkerJoinParams
  /** Stops execution whose connection fence the control plane has released. */
  onDisconnected?: (reason: string) => void
  /** Replaces the Phoenix socket; unit tests inject an in-memory double. */
  createSocket?: (endpoint: string, options: ChannelSocketOptions) => ChannelSocketLike
  pushTimeoutMs?: number
  readyWaitMs?: number
  flowControlBackoffMs?: { initial: number; max: number }
  inboundQueueLimit?: number
  inboundByteLimit?: number
  ackDelayMs?: number
  /** Delay before the transport reconnects after a normal close, by attempt. */
  reconnectDelayMs?: (tries: number) => number
  windows?: Partial<Record<RuntimeFabricStream, StreamWindowLimits>>
}

/** Credit and error metadata the control plane returns on a reply. */
export type StreamReply = {
  messageCredit?: number
  byteCredit?: number
  reason?: string
  expected?: number
}

/** Cumulative acknowledgement the Worker pushes for received commands and replies. */
export type InboundAck = { acked_seq: number; message_credit: number; byte_credit: number }

export type StreamWindowLimits = { maxMessages: number; maxBytes: number }

const defaultWindows: Record<RuntimeFabricStream, StreamWindowLimits> = {
  control: { maxMessages: 8, maxBytes: 1024 * 1024 },
  durable: { maxMessages: 64, maxBytes: 16 * 1024 * 1024 },
  telemetry: { maxMessages: 16, maxBytes: 4 * 1024 * 1024 }
}
const defaultPushTimeoutMs = 10_000
const defaultConnectTimeoutMs = 10_000
const defaultReadyWaitMs = 60_000
const defaultFlowControlBackoffMs = { initial: 50, max: 500 }
const defaultInboundQueueLimit = 1024
const defaultInboundByteLimit = 64 * 1024 * 1024
const defaultAckDelayMs = 20
const streamEnum: Record<RuntimeFabricStream, Stream> = {
  control: Stream.CONTROL,
  durable: Stream.DURABLE,
  telemetry: Stream.TELEMETRY
}
const resumeClockGapMs = 30_000
// Phoenix adds five header bytes and four metadata fields of at most 255 bytes each.
const maxEnvelopeBytes = 16 * 1024 * 1024 - (5 + 4 * 255)
const telemetryExportMethod = 'observability.spans.export'

export const runtimeFabricWorkerTopic = 'worker'

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

export type WorkerJoinParams = {
  incarnation_id: string
  max_slots: number
  available_slots: number
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
    transport: WorkerWebSocket as unknown as new (endpoint: string) => object,
    authToken: options.workerAuthKey,
    params: { worker_id: options.workerID },
    binaryType: 'arraybuffer',
    heartbeatIntervalMs: 15_000,
    reconnectAfterMs: reconnectDelayMs
  }) as unknown as ChannelSocketLike
}

function reconnectDelayMs(tries: number): number {
  return Math.min(5_000, 100 * 2 ** Math.min(tries, 6))
}

function closeCode(event: unknown): number | undefined {
  return typeof event === 'object' && event !== null && 'code' in event && typeof event.code === 'number'
    ? event.code
    : undefined
}

function closeFields(event: unknown) {
  const value = typeof event === 'object' && event !== null ? event : undefined
  return {
    close_code: closeCode(event),
    close_reason: value && 'reason' in value && typeof value.reason === 'string' ? value.reason : undefined,
    was_clean: value && 'wasClean' in value && typeof value.wasClean === 'boolean' ? value.wasClean : undefined
  }
}

function socketErrorFields(event: unknown) {
  if (event instanceof Error) return { error: event, error_type: event.name }
  const value = typeof event === 'object' && event !== null ? event : undefined
  const error = value && 'error' in value ? value.error : undefined
  const message = value && 'message' in value && typeof value.message === 'string' ? value.message : undefined
  const type = value && 'type' in value && typeof value.type === 'string' ? value.type : undefined
  const cause = error instanceof Error ? error : new Error(message || `WebSocket ${type ?? 'error'} event`)
  return { error: cause, error_type: error instanceof Error ? error.name : value?.constructor.name, event_type: type }
}

export function createChannelTransport(
  config: ChannelTransportConfig,
  options: ChannelTransportOptions
): RuntimeFabricHost {
  return new ChannelTransport(config, options)
}

class StreamWindow {
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

type StreamState = {
  nextSeq: number
  inFlight: Map<number, (outcome: PushOutcome) => void>
  paused: boolean
  creditWaiters: Array<() => void>
}

type PushOutcome =
  | { status: 'ok' }
  | { status: 'error'; reason: string; reply: StreamReply }
  | { status: 'timeout' }
  | { status: 'closed' }

class ChannelTransport implements RuntimeFabricHost {
  private readonly socket: ChannelSocketLike
  private channel: ChannelLike
  private readonly windows: Record<RuntimeFabricStream, StreamWindow>
  private readonly pushTimeoutMs: number
  private readonly readyWaitMs: number
  private readonly normalCloseReconnectDelayMs: (tries: number) => number
  private readonly flowControlBackoffMs: { initial: number; max: number }
  private readonly inboundQueueLimit: number
  private readonly inboundByteLimit: number
  private readonly ackDelayMs: number
  private readonly inbound: Array<{ outcome: RuntimeFabricReceiveOutcome; bytes: number }> = []
  private inboundBytes = 0
  private inboundWaiter: ((outcome: RuntimeFabricReceiveOutcome) => void) | undefined
  private inboundFailure: RuntimeFabricTransportError | undefined
  private readonly streams: Record<RuntimeFabricStream, StreamState> = {
    control: newStreamState(),
    durable: newStreamState(),
    telemetry: newStreamState()
  }
  private inboundNextSeq = 1
  private inboundAckedSeq = 0
  private ackTimer: ReturnType<typeof setTimeout> | undefined
  private readonly readyWaiters: Array<() => void> = []
  private ready = false
  private connectionID?: string
  private stopped = false
  // A new process has no channel yet; the clock starts at construction.
  private disconnectedSince: number | undefined = Date.now()
  private refusedReason: string | undefined
  private normalCloseReconnects = 0
  private reconnectTimer: ReturnType<typeof setTimeout> | undefined
  private reconnecting = false
  private lastEventLoopCheck = Date.now()
  private readonly eventLoopTimer: ReturnType<typeof setInterval>
  telemetryDropped = 0

  constructor(
    private readonly config: ChannelTransportConfig,
    private readonly options: ChannelTransportOptions
  ) {
    this.pushTimeoutMs = options.pushTimeoutMs ?? defaultPushTimeoutMs
    this.readyWaitMs = options.readyWaitMs ?? defaultReadyWaitMs
    this.normalCloseReconnectDelayMs = options.reconnectDelayMs ?? reconnectDelayMs
    this.flowControlBackoffMs = options.flowControlBackoffMs ?? defaultFlowControlBackoffMs
    this.inboundQueueLimit = options.inboundQueueLimit ?? defaultInboundQueueLimit
    this.inboundByteLimit = options.inboundByteLimit ?? defaultInboundByteLimit
    this.ackDelayMs = options.ackDelayMs ?? defaultAckDelayMs
    this.windows = {
      control: new StreamWindow(options.windows?.control ?? defaultWindows.control),
      durable: new StreamWindow(options.windows?.durable ?? defaultWindows.durable),
      telemetry: new StreamWindow(options.windows?.telemetry ?? defaultWindows.telemetry)
    }

    const createSocket = options.createSocket ?? createPhoenixSocket
    this.socket = createSocket(config.endpoint, { workerID: config.workerID, workerAuthKey: config.workerAuthKey })
    this.socket.onOpen(() => workerLogger.info('worker.fabric_connected', 'runtime fabric socket connected', {}))
    this.socket.onClose(event => this.onSocketClosed(event))
    this.socket.onError(error => {
      workerLogger.warning('worker.fabric_socket_error', 'runtime fabric socket error', socketErrorFields(error))
    })

    this.channel = this.createChannel()
    this.socket.connect()
    this.joinChannel()
    this.eventLoopTimer = setInterval(() => this.checkResume(), 1_000)
  }

  get isReady(): boolean {
    return this.ready
  }

  // `RuntimeFabricHost` hands these out as plain functions (`EnvelopeSender`),
  // so they must not depend on the call site keeping `this`.
  readonly sendEnvelope = async (envelope: Envelope, options: EnvelopeSendOptions = {}): Promise<void> => {
    options.signal?.throwIfAborted()
    this.ensureOpen()
    const stream = runtimeFabricStream(envelope)
    // The sequence number is assigned when the push happens; its varint adds
    // at most a few bytes, so the window accounts the unsequenced size.
    const size = this.seal(envelope, stream, 0).byteLength + 12
    if (size > maxEnvelopeBytes) {
      throw new RuntimeFabricTransportError('rejected', 'RuntimeFabric request exceeds the frame budget', {
        reason: 'frame_too_large'
      })
    }
    const window = this.windows[stream]

    if (stream === 'telemetry') {
      if (!window.tryAcquire(size)) {
        this.dropTelemetry(envelope, 'window_full')
        return
      }
    } else {
      await window.acquire(size, () => this.stopped, options.signal)
    }

    try {
      await this.deliver(stream, envelope, options)
    } finally {
      window.release(size)
    }
  }

  readonly receive = (timeoutMs: number): Promise<RuntimeFabricReceiveOutcome> => {
    this.ensureOpen()
    if (this.inboundFailure) throw this.inboundFailure

    const queued = this.inbound.shift()
    if (queued) {
      this.inboundBytes -= queued.bytes
      return Promise.resolve(queued.outcome)
    }

    return new Promise(resolve => {
      const timer = setTimeout(() => {
        this.inboundWaiter = undefined
        resolve({ kind: 'timeout' })
      }, timeoutMs)
      this.inboundWaiter = outcome => {
        clearTimeout(timer)
        this.inboundWaiter = undefined
        resolve(outcome)
      }
    })
  }

  stop(): void {
    if (this.stopped) return
    this.stopped = true
    this.ready = false
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer)
    if (this.ackTimer) clearTimeout(this.ackTimer)
    clearInterval(this.eventLoopTimer)
    this.settleInFlight({ status: 'closed' })
    this.wakeReadyWaiters()
    for (const window of Object.values(this.windows)) window.wake()
    try {
      this.channel.leave()
    } finally {
      this.socket.disconnect()
    }
  }

  private async deliver(stream: RuntimeFabricStream, envelope: Envelope, options: EnvelopeSendOptions): Promise<void> {
    let backoffMs = this.flowControlBackoffMs.initial
    let seq: number | undefined

    for (;;) {
      options.signal?.throwIfAborted()
      if (stream === 'telemetry') {
        if (!this.ready) {
          this.dropTelemetry(envelope, 'not_ready')
          return
        }
      } else {
        await this.awaitReady(options.signal)
      }
      await this.awaitUnpaused(stream, options.signal)
      options.signal?.throwIfAborted()

      const state = this.streams[stream]
      // A flow-control refusal did not consume its seq, so a retry repeats it.
      seq = seq ?? state.nextSeq
      if (seq !== state.nextSeq) {
        // Later pushes already used the following seqs; they fail with
        // `bad_sequence` and the rejoin resets both sides.
        throw new RuntimeFabricTransportError('socket_closed', 'socket_closed: stream sequence reset')
      }
      state.nextSeq = seq + 1

      const outcome = await this.push(stream, seq, this.seal(envelope, stream, seq), options)
      switch (outcome.status) {
        case 'ok':
          return
        case 'timeout':
          throw new RuntimeFabricTransportError('timeout', `timeout: ${stream} push was not answered`)
        case 'closed':
          throw new RuntimeFabricTransportError('socket_closed', 'socket_closed')
        case 'error':
          if (outcome.reason === 'bad_sequence') {
            throw new RuntimeFabricTransportError('socket_closed', 'socket_closed: stream sequence reset')
          }
          if (outcome.reason !== 'flow_control') {
            throw new RuntimeFabricTransportError('rejected', `rejected: ${outcome.reason}`, { reason: outcome.reason })
          }
          if (stream === 'telemetry') {
            this.dropTelemetry(envelope, 'flow_control')
            return
          }
          if (state.nextSeq === seq + 1) state.nextSeq = seq
          state.paused = true
          try {
            await this.awaitCredit(stream, backoffMs, options.signal)
          } finally {
            state.paused = false
            this.wakeStream(stream)
          }
          backoffMs = Math.min(this.flowControlBackoffMs.max, backoffMs * 2)
      }
    }
  }

  private push(
    stream: RuntimeFabricStream,
    seq: number,
    bytes: Buffer,
    options: EnvelopeSendOptions
  ): Promise<PushOutcome> {
    if (this.stopped || !this.ready) return Promise.resolve({ status: 'closed' })
    const state = this.streams[stream]
    const channel = this.channel
    const connectionID = this.connectionID!

    return new Promise(resolve => {
      const settle = (outcome: PushOutcome) => {
        if (state.inFlight.get(seq) !== settle) return
        state.inFlight.delete(seq)
        options.signal?.removeEventListener('abort', abort)
        resolve(outcome)
      }
      const abort = () => settle({ status: 'closed' })
      state.inFlight.set(seq, settle)
      options.signal?.addEventListener('abort', abort, { once: true })

      const currentConnection = () => this.ready && this.channel === channel && this.connectionID === connectionID

      let push: ChannelPushLike
      try {
        push = channel.push(stream, arrayBuffer(bytes), this.pushTimeoutMs)
        options.onSent?.(connectionID)
      } catch (error) {
        settle({ status: 'error', reason: errorMessage(error), reply: {} })
        return
      }
      push
        .receive('ok', response => {
          if (!currentConnection()) return
          const reply = streamReply(response)
          settle({ status: 'ok' })
          this.applyReply(stream, reply)
        })
        .receive('error', response => {
          if (!currentConnection()) return
          const reply = streamReply(response)
          // A consumed sequence is also acknowledged on a business rejection.
          // Preserve this push's explicit outcome before applying the cumulative ACK.
          settle({ status: 'error', reason: reply.reason ?? 'unknown', reply })
          this.applyReply(stream, reply)
          if (reply.reason === 'bad_sequence') this.resync('bad_sequence', { stream, expected: reply.expected })
        })
        .receive('timeout', () => {
          if (currentConnection()) settle({ status: 'timeout' })
        })
    })
  }

  // Credit is cumulative; a sequence ACK is not an earlier push's business result.
  private applyReply(stream: RuntimeFabricStream, reply: StreamReply): void {
    const state = this.streams[stream]
    if (reply.messageCredit !== undefined && reply.byteCredit !== undefined) {
      this.windows[stream].setCredit(reply.messageCredit, reply.byteCredit)
      if (reply.messageCredit > 0) {
        const waiters = state.creditWaiters.splice(0)
        for (const waiter of waiters) waiter()
      }
    }
  }

  private awaitCredit(stream: RuntimeFabricStream, backoffMs: number, signal?: AbortSignal): Promise<void> {
    const state = this.streams[stream]
    return waitForWake(state.creditWaiters, signal, backoffMs)
  }

  private awaitUnpaused(stream: RuntimeFabricStream, signal?: AbortSignal): Promise<void> {
    const state = this.streams[stream]
    if (!state.paused) return Promise.resolve()
    return waitForWake(state.creditWaiters, signal)
  }

  private wakeStream(stream: RuntimeFabricStream): void {
    const waiters = this.streams[stream].creditWaiters.splice(0)
    for (const waiter of waiters) waiter()
  }

  private resetStreams(): void {
    for (const stream of Object.keys(this.streams) as RuntimeFabricStream[]) {
      const state = this.streams[stream]
      state.nextSeq = 1
      state.paused = false
      this.windows[stream].resetCredit()
      this.wakeStream(stream)
    }
    this.inboundNextSeq = 1
    this.inboundAckedSeq = 0
  }

  // Leaves the channel and joins again. Both sides restart their sequences
  // at 1 on the new join, which is the only way to recover from a gap.
  private resync(reason: string, details: Record<string, unknown>): void {
    if (this.stopped) return
    workerLogger.error('worker.fabric_sequence_reset', 'runtime fabric stream sequence is out of step', {
      reason,
      ...details
    })
    this.onDisconnected(reason)
    const old = this.channel
    this.channel = this.createChannel()
    try {
      old.leave()
    } catch (error) {
      workerLogger.warning('worker.fabric_leave_failed', 'runtime fabric channel leave failed', {
        error: toError(error)
      })
    }
    this.joinChannel()
  }

  readonly awaitReady = async (signal?: AbortSignal): Promise<void> => {
    signal?.throwIfAborted()
    if (this.ready) return Promise.resolve()
    const deadline = Date.now() + this.readyWaitMs
    while (!this.ready) {
      this.ensureOpen()
      if (this.refusedReason) {
        throw new RuntimeFabricTransportError('rejected', `rejected: ${this.refusedReason}`, {
          reason: this.refusedReason
        })
      }
      if (Date.now() >= deadline) {
        throw new RuntimeFabricTransportError('socket_closed', 'socket_closed: control plane connection is not ready')
      }
      await waitForWake(this.readyWaiters, signal, deadline - Date.now())
    }
  }

  private createChannel(): ChannelLike {
    const channel = this.socket.channel(runtimeFabricWorkerTopic, this.options.joinParams)
    channel.on('command', payload => {
      if (this.channel === channel && this.ready) this.onCommand(payload)
    })
    channel.on('reply', payload => {
      if (this.channel === channel && this.ready) this.onReply(payload)
    })
    channel.onError(() => {
      if (this.channel === channel) this.onDisconnected('channel_error')
    })
    // Phoenix does not rejoin a channel the server closed, so the transport
    // replaces it and joins again with the same identity.
    channel.onClose(() => {
      if (this.stopped || this.channel !== channel) return
      this.onDisconnected('channel_closed')
      this.channel = this.createChannel()
      this.joinChannel()
    })
    return channel
  }

  private joinChannel(): void {
    if (this.stopped) return
    const channel = this.channel
    channel
      .join()
      .receive('ok', response => {
        if (!this.stopped && this.channel === channel) this.onJoined(response)
      })
      .receive('error', response => {
        if (this.stopped || this.channel !== channel) return
        const reason = replyReason(response)
        workerLogger.warning('worker.fabric_join_rejected', 'runtime fabric channel join rejected', { reason })
        // The control plane no longer accepts this process for its Agent.
        if (reason === 'stale_worker_generation') {
          this.refusedReason = reason
          this.wakeReadyWaiters()
        }
      })
      .receive('timeout', () => {
        if (this.stopped || this.channel !== channel) return
        workerLogger.warning('worker.fabric_join_timeout', 'runtime fabric channel join timed out', {})
      })
  }

  private onJoined(response: unknown): void {
    const connectionID =
      typeof response === 'object' && response !== null && 'connection_id' in response
        ? String(response.connection_id)
        : undefined
    if (!connectionID) {
      this.refusedReason = 'missing_connection_id'
      this.wakeReadyWaiters()
      return
    }
    if (this.ready) this.onDisconnected('connection_replaced')
    this.connectionID = connectionID
    workerLogger.info('worker.fabric_joined', 'runtime fabric channel joined', {
      worker_id: this.config.workerID,
      connection_id: connectionID ?? null
    })
    this.resetStreams()
    this.normalCloseReconnects = 0
    this.ready = true
    this.disconnectedSince = undefined
    this.wakeReadyWaiters()
  }

  isolationReason(maxDisconnectedMs: number): string | undefined {
    this.checkResume()
    if (this.refusedReason) return this.refusedReason
    if (this.disconnectedSince !== undefined && Date.now() - this.disconnectedSince >= maxDisconnectedMs) {
      return 'no_channel'
    }
    return undefined
  }

  private checkResume(): void {
    const now = Date.now()
    const gapMs = now - this.lastEventLoopCheck
    this.lastEventLoopCheck = now
    if (this.stopped || this.refusedReason || gapMs <= resumeClockGapMs) return

    // A paused VM can retain its socket and its disconnection clock. Give
    // the same process a new connection and a full isolation interval.
    workerLogger.info('worker.instance_resumed', 'worker event loop resumed', { gap_ms: gapMs })
    this.onDisconnected('instance_resumed')
    this.disconnectedSince = now
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = undefined
    }
    this.reconnectSocket()
  }

  private reconnectSocket(): void {
    if (this.stopped || this.reconnecting) return
    this.reconnecting = true
    this.socket.disconnect(() => {
      this.reconnecting = false
      if (!this.stopped) this.socket.connect()
    })
  }

  // Phoenix reconnects by itself only after an abnormal close, but the
  // control plane's server closes every WebSocket with code 1000 when it shuts
  // down. So the transport also reconnects after a normal close; the join
  // then decides if the control plane still accepts this process.
  private onSocketClosed(event: unknown): void {
    workerLogger.warning('worker.fabric_socket_closed', 'runtime fabric socket closed', closeFields(event))
    this.onDisconnected('socket_closed')
    if (this.stopped || this.reconnecting || closeCode(event) !== 1000 || this.reconnectTimer) return
    const delayMs = this.normalCloseReconnectDelayMs(this.normalCloseReconnects)
    this.normalCloseReconnects += 1
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined
      if (this.stopped || this.socket.isConnected()) return
      this.reconnectSocket()
    }, delayMs)
  }

  private onDisconnected(reason: string): void {
    if (this.stopped) return
    const wasReady = this.ready
    const connectionID = this.connectionID
    this.ready = false
    if (wasReady) this.disconnectedSince = Date.now()
    this.settleInFlight({ status: 'closed' })
    if (wasReady) {
      this.enqueueOutcome({ kind: 'disconnected', connectionID: connectionID!, reason }, 0)
      this.options.onDisconnected?.(reason)
      workerLogger.warning('worker.fabric_disconnected', 'runtime fabric connection lost', { reason })
    }
  }

  private onCommand(payload: unknown): void {
    this.acceptInbound(payload, 'command')
  }

  private onReply(payload: unknown): void {
    this.acceptInbound(payload, 'reply')
  }

  // Commands and replies share one sequence. A gap means this connection
  // missed a message, and only a rejoin brings both sides back in step. The
  // acknowledgement tells the control plane which seqs this Worker queued;
  // handling happens afterwards, and the durable answer is the Worker's own
  // later message, never this ack.
  private acceptInbound(payload: unknown, event: string): void {
    const decoded = this.decodeInbound(payload, event)
    if (!decoded) return
    const { envelope, bytes } = decoded

    const seq = Number(envelope.transportSeq)
    if (seq !== this.inboundNextSeq) {
      this.resync('inbound_sequence_gap', { event, expected: this.inboundNextSeq, received: seq })
      return
    }
    this.inboundNextSeq = seq + 1
    this.enqueue(envelope, bytes)
    if (this.stopped) return
    this.inboundAckedSeq = seq
    this.scheduleAck()
  }

  private scheduleAck(): void {
    if (this.ackTimer) return
    if (this.ackDelayMs <= 0) {
      this.sendAck()
      return
    }
    this.ackTimer = setTimeout(() => {
      this.ackTimer = undefined
      this.sendAck()
    }, this.ackDelayMs)
  }

  private sendAck(): void {
    if (this.stopped || this.channel.state !== 'joined') return
    const ack: InboundAck = {
      acked_seq: this.inboundAckedSeq,
      message_credit: Math.max(this.inboundQueueLimit - this.inbound.length, 0),
      byte_credit: Math.max(this.inboundByteLimit - this.inboundBytes, 0)
    }
    try {
      this.channel.push('ack', ack, this.pushTimeoutMs)
    } catch (error) {
      workerLogger.warning('worker.fabric_ack_failed', 'runtime fabric command ack failed', {
        acked_seq: ack.acked_seq,
        error: toError(error)
      })
    }
  }

  private decodeInbound(payload: unknown, event: string): { envelope: Envelope; bytes: number } | undefined {
    try {
      const bytes = inboundBytes(payload)
      const envelope = decodeEnvelope(bytes)
      if (envelope.protocolVersion !== ProtocolVersion.CURRENT) {
        throw new Error(`unsupported runtime fabric protocol version: ${envelope.protocolVersion}`)
      }
      return { envelope, bytes: bytes.byteLength }
    } catch (error) {
      workerLogger.error('worker.fabric_decode_failed', 'runtime fabric envelope rejected', {
        event,
        error: toError(error)
      })
      return undefined
    }
  }

  private enqueue(envelope: Envelope, bytes: number): void {
    this.enqueueOutcome({ kind: 'envelope', envelope }, bytes)
  }

  private enqueueOutcome(outcome: RuntimeFabricReceiveOutcome, bytes: number): void {
    if (this.inboundWaiter) {
      this.inboundWaiter(outcome)
      return
    }
    if (this.inbound.length >= this.inboundQueueLimit || this.inboundBytes + bytes > this.inboundByteLimit) {
      this.inboundFailure = new RuntimeFabricTransportError(
        'socket_closed',
        `socket_closed: inbound queue exceeded ${this.inboundQueueLimit} envelopes`
      )
      this.stop()
      return
    }
    this.inbound.push({ outcome, bytes })
    this.inboundBytes += bytes
  }

  private seal(envelope: Envelope, stream: RuntimeFabricStream, seq: number): Buffer {
    return encodeEnvelope({
      ...envelope,
      protocolVersion: ProtocolVersion.CURRENT,
      stream: streamEnum[stream],
      transportSeq: BigInt(seq)
    })
  }

  private dropTelemetry(envelope: Envelope, reason: string): void {
    this.telemetryDropped += 1
    workerLogger.warning('worker.telemetry_dropped', 'runtime fabric telemetry dropped', {
      reason,
      message_id: envelope.messageId,
      dropped_total: this.telemetryDropped
    })
  }

  private settleInFlight(outcome: PushOutcome): void {
    for (const state of Object.values(this.streams)) {
      for (const settle of state.inFlight.values()) settle(outcome)
    }
  }

  private wakeReadyWaiters(): void {
    const waiters = this.readyWaiters.splice(0)
    for (const waiter of waiters) waiter()
  }

  private ensureOpen(): void {
    if (this.stopped) {
      throw this.inboundFailure ?? new RuntimeFabricTransportError('socket_closed', 'socket_closed')
    }
  }
}

function waitForWake(waiters: Array<() => void>, signal?: AbortSignal, timeoutMs?: number): Promise<void> {
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

function arrayBuffer(bytes: Buffer): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}

function inboundBytes(payload: unknown): Buffer {
  if (payload instanceof ArrayBuffer) return Buffer.from(payload)
  if (payload instanceof Uint8Array) return Buffer.from(payload)
  throw new Error('binary payload expected')
}

function newStreamState(): StreamState {
  return { nextSeq: 1, inFlight: new Map(), paused: false, creditWaiters: [] }
}

function streamReply(response: unknown): StreamReply {
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
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function replyReason(response: unknown): string {
  if (typeof response === 'object' && response !== null && 'reason' in response) {
    return String(response.reason)
  }
  return response === undefined ? 'unknown' : errorMessage(response)
}
