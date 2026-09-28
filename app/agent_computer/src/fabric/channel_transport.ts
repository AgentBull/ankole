import { Socket } from 'phoenix'
import * as kernel from '../../../kernel'
import { Buffer } from 'node:buffer'
import { errorMessage, toError } from '../common/errors'
import { workerLogger } from '../worker/logging'
import { decodeEnvelope, encodeEnvelope, Stream, type Envelope } from './envelope_proto'
import { RuntimeFabricTransportError, type RuntimeFabricHost, type RuntimeFabricReceiveOutcome } from './fabric'

/**
 * Phoenix Channel client for the RuntimeFabric worker connection.
 *
 * One WebSocket carries three logical streams from the Worker to the control
 * plane. Every envelope names its stream and carries a per-stream
 * `transport_seq` that starts at 1 on each join. The control plane answers a
 * push with a cumulative acknowledgement (`acked_seq`) and the remaining
 * `message_credit` and `byte_credit` of that stream; the Worker resolves every
 * in-flight push up to `acked_seq` and bounds its window by the credit. A
 * rejected push did not consume its sequence number, so a `flow_control`
 * retry repeats the same seq; a `bad_sequence` reply means the streams are out
 * of step and the Worker rejoins, which resets both sides to 1.
 *
 * Commands and replies from the control plane share one sequence per
 * connection. The Worker accepts them in order into a bounded inbound queue
 * and acknowledges cumulatively on the `ack` event with its remaining queue
 * capacity. Nothing is buffered across a lost connection: an unanswered push
 * fails, and the control plane repeats durable work through its own delivery
 * records.
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
  /** Builds the `worker_ready` envelope sent after every successful join. */
  readyEnvelope: () => Envelope
  /** Replaces the Phoenix socket; unit tests inject an in-memory double. */
  createSocket?: (endpoint: string, options: ChannelSocketOptions) => ChannelSocketLike
  pushTimeoutMs?: number
  readyWaitMs?: number
  flowControlBackoffMs?: { initial: number; max: number }
  inboundQueueLimit?: number
  inboundByteLimit?: number
  ackDelayMs?: number
  windows?: Partial<Record<RuntimeFabricStream, StreamWindowLimits>>
}

/** Cumulative acknowledgement and credit the control plane returns on a reply. */
export type StreamReply = {
  stream?: RuntimeFabricStream
  ackedSeq?: number
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
const readyRetryMs = { initial: 1_000, max: 5_000 }
const telemetryExportMethod = 'observability.spans.export'

export const runtimeFabricWorkerTopic = (workerID: string): string => `worker/installation/${workerID}`

/** Classifies an envelope into the stream that carries it. */
export function runtimeFabricStream(envelope: Envelope): RuntimeFabricStream {
  switch (envelope.body.case) {
    case 'workerReady':
    case 'workerHeartbeat':
    case 'workerCapacity':
    case 'controlShutdown':
      return 'control'
    case 'rpcRequest':
      return envelope.body.value.method === telemetryExportMethod ? 'telemetry' : 'durable'
    default:
      return 'durable'
  }
}

export type WorkerJoinParams = {
  worker_id: string
  incarnation_id: string
  runtime: string
  version: string
  max_turns: number
  available_turn_slots: number
}

export function joinParams(envelope: Envelope): WorkerJoinParams {
  if (envelope.body.case !== 'workerReady') {
    throw new Error(`join params need a workerReady envelope, got ${envelope.body.case ?? 'an empty body'}`)
  }
  const ready = envelope.body.value
  return {
    worker_id: ready.workerId,
    incarnation_id: ready.incarnationId,
    runtime: ready.runtime,
    version: ready.version,
    max_turns: ready.maxTurns,
    available_turn_slots: ready.availableTurnSlots
  }
}

export function createPhoenixSocket(endpoint: string, options: ChannelSocketOptions): ChannelSocketLike {
  // The auth key travels as the Phoenix auth token in the WebSocket
  // subprotocol, never in the URL. `worker_id` is a query parameter and is
  // not a secret.
  return new Socket(endpoint, {
    transport: WebSocket as unknown as new (endpoint: string) => object,
    authToken: options.workerAuthKey,
    params: { worker_id: options.workerID },
    binaryType: 'arraybuffer',
    heartbeatIntervalMs: 15_000,
    reconnectAfterMs: tries => Math.min(5_000, 100 * 2 ** Math.min(tries, 6))
  }) as unknown as ChannelSocketLike
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

  async acquire(bytes: number, closed: () => boolean): Promise<void> {
    while (!this.tryAcquire(bytes)) {
      if (closed()) throw new RuntimeFabricTransportError('socket_closed', 'socket_closed')
      await new Promise<void>(resolve => this.waiters.push(resolve))
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

  get creditMessages(): number | undefined {
    return this.credit?.messages
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
  private readonly flowControlBackoffMs: { initial: number; max: number }
  private readonly inboundQueueLimit: number
  private readonly inboundByteLimit: number
  private readonly ackDelayMs: number
  private readonly inbound: Array<{ envelope: Envelope; bytes: number }> = []
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
  private stopped = false
  private readyAttempt = 0
  private readyRetryTimer: ReturnType<typeof setTimeout> | undefined
  telemetryDropped = 0

  constructor(
    private readonly config: ChannelTransportConfig,
    private readonly options: ChannelTransportOptions
  ) {
    this.pushTimeoutMs = options.pushTimeoutMs ?? defaultPushTimeoutMs
    this.readyWaitMs = options.readyWaitMs ?? defaultReadyWaitMs
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
    this.socket.onClose(() => this.onDisconnected('socket_closed'))
    this.socket.onError(error => {
      workerLogger.warning('worker.fabric_socket_error', 'runtime fabric socket error', { error: toError(error) })
    })

    this.channel = this.createChannel()
    this.socket.connect()
    this.joinChannel()
  }

  get isReady(): boolean {
    return this.ready
  }

  // `RuntimeFabricHost` hands these out as plain functions (`EnvelopeSender`),
  // so they must not depend on the call site keeping `this`.
  readonly sendEnvelope = async (envelope: Envelope): Promise<void> => {
    this.ensureOpen()
    const stream = runtimeFabricStream(envelope)
    // The sequence number is assigned when the push happens; its varint adds
    // at most a few bytes, so the window accounts the unsequenced size.
    const size = this.seal(envelope, stream, 0).byteLength + 12
    const window = this.windows[stream]

    if (stream === 'telemetry') {
      if (!window.tryAcquire(size)) {
        this.dropTelemetry(envelope, 'window_full')
        return
      }
    } else {
      await window.acquire(size, () => this.stopped)
    }

    try {
      await this.deliver(stream, envelope)
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
      return Promise.resolve({ kind: 'envelope', envelope: queued.envelope })
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
    if (this.readyRetryTimer) clearTimeout(this.readyRetryTimer)
    if (this.ackTimer) clearTimeout(this.ackTimer)
    this.settleInFlight({ status: 'closed' })
    this.wakeReadyWaiters()
    for (const window of Object.values(this.windows)) window.wake()
    try {
      this.channel.leave()
    } finally {
      this.socket.disconnect()
    }
  }

  private async deliver(stream: RuntimeFabricStream, envelope: Envelope): Promise<void> {
    let backoffMs = this.flowControlBackoffMs.initial
    let seq: number | undefined

    for (;;) {
      if (stream === 'telemetry') {
        if (!this.ready) {
          this.dropTelemetry(envelope, 'not_ready')
          return
        }
      } else {
        await this.awaitReady()
      }
      await this.awaitUnpaused(stream)

      const state = this.streams[stream]
      // A rejected push did not consume its seq, so a retry repeats it.
      seq = seq ?? state.nextSeq
      if (seq !== state.nextSeq) {
        // Later pushes already used the following seqs; they fail with
        // `bad_sequence` and the rejoin resets both sides.
        throw new RuntimeFabricTransportError('socket_closed', 'socket_closed: stream sequence reset')
      }
      state.nextSeq = seq + 1

      const outcome = await this.push(stream, seq, this.seal(envelope, stream, seq))
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
            throw new RuntimeFabricTransportError('rejected', `rejected: ${outcome.reason}`)
          }
          if (stream === 'telemetry') {
            this.dropTelemetry(envelope, 'flow_control')
            return
          }
          if (state.nextSeq === seq + 1) state.nextSeq = seq
          state.paused = true
          try {
            await this.awaitCredit(stream, backoffMs)
          } finally {
            state.paused = false
            this.wakeStream(stream)
          }
          backoffMs = Math.min(this.flowControlBackoffMs.max, backoffMs * 2)
      }
    }
  }

  private push(stream: RuntimeFabricStream, seq: number, bytes: Buffer): Promise<PushOutcome> {
    if (this.stopped || !this.ready) return Promise.resolve({ status: 'closed' })
    const state = this.streams[stream]

    return new Promise(resolve => {
      const settle = (outcome: PushOutcome) => {
        if (!state.inFlight.delete(seq)) return
        resolve(outcome)
      }
      state.inFlight.set(seq, settle)

      let push: ChannelPushLike
      try {
        push = this.channel.push(stream, arrayBuffer(bytes), this.pushTimeoutMs)
      } catch (error) {
        settle({ status: 'error', reason: errorMessage(error), reply: {} })
        return
      }
      push
        .receive('ok', response => {
          const reply = streamReply(response)
          this.applyReply(stream, reply)
          settle({ status: 'ok' })
        })
        .receive('error', response => {
          const reply = streamReply(response)
          this.applyReply(stream, reply)
          if (reply.reason === 'bad_sequence') this.resync('bad_sequence', { stream, expected: reply.expected })
          settle({ status: 'error', reason: reply.reason ?? 'unknown', reply })
        })
        .receive('timeout', () => settle({ status: 'timeout' }))
    })
  }

  // A reply carries the cumulative acknowledgement of its stream: every earlier
  // in-flight push up to `acked_seq` is done, and the credit bounds the window.
  private applyReply(stream: RuntimeFabricStream, reply: StreamReply): void {
    const state = this.streams[stream]
    if (reply.ackedSeq !== undefined) {
      for (const [seq, settle] of state.inFlight) {
        if (seq <= reply.ackedSeq) settle({ status: 'ok' })
      }
    }
    if (reply.messageCredit !== undefined && reply.byteCredit !== undefined) {
      this.windows[stream].setCredit(reply.messageCredit, reply.byteCredit)
      if (reply.messageCredit > 0) {
        const waiters = state.creditWaiters.splice(0)
        for (const waiter of waiters) waiter()
      }
    }
  }

  private awaitCredit(stream: RuntimeFabricStream, backoffMs: number): Promise<void> {
    const state = this.streams[stream]
    return new Promise(resolve => {
      const timer = setTimeout(() => {
        const index = state.creditWaiters.indexOf(waiter)
        if (index >= 0) state.creditWaiters.splice(index, 1)
        resolve()
      }, backoffMs)
      const waiter = () => {
        clearTimeout(timer)
        resolve()
      }
      state.creditWaiters.push(waiter)
    })
  }

  private awaitUnpaused(stream: RuntimeFabricStream): Promise<void> {
    const state = this.streams[stream]
    if (!state.paused) return Promise.resolve()
    return new Promise(resolve => state.creditWaiters.push(resolve))
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

  private awaitReady(): Promise<void> {
    if (this.ready) return Promise.resolve()
    if (this.stopped) throw new RuntimeFabricTransportError('socket_closed', 'socket_closed')

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        remove()
        reject(new RuntimeFabricTransportError('socket_closed', 'socket_closed: control plane connection is not ready'))
      }, this.readyWaitMs)
      const waiter = () => {
        clearTimeout(timer)
        if (this.ready) {
          resolve()
        } else if (this.stopped) {
          reject(new RuntimeFabricTransportError('socket_closed', 'socket_closed'))
        } else {
          this.readyWaiters.push(waiter)
        }
      }
      const remove = () => {
        const index = this.readyWaiters.indexOf(waiter)
        if (index >= 0) this.readyWaiters.splice(index, 1)
      }
      this.readyWaiters.push(waiter)
    })
  }

  private createChannel(): ChannelLike {
    // Admission runs inside the control plane's `join/3`, so the join payload
    // carries the `worker_ready` fields. Phoenix evaluates the closure on every
    // join and rejoin, so a reconnect reports the current slot count.
    const channel = this.socket.channel(runtimeFabricWorkerTopic(this.config.workerID), () =>
      joinParams(this.options.readyEnvelope())
    )
    channel.on('command', payload => this.onCommand(payload))
    channel.on('reply', payload => this.onReply(payload))
    channel.onError(() => this.onDisconnected('channel_error'))
    // Phoenix does not rejoin a channel the server closed, so the transport
    // replaces it and joins again with the same identity.
    channel.onClose(() => {
      this.onDisconnected('channel_closed')
      if (this.stopped || this.channel !== channel) return
      this.channel = this.createChannel()
      this.joinChannel()
    })
    return channel
  }

  private joinChannel(): void {
    if (this.stopped) return
    this.channel
      .join()
      .receive('ok', response => this.onJoined(response))
      .receive('error', response => {
        workerLogger.warning('worker.fabric_join_rejected', 'runtime fabric channel join rejected', {
          reason: replyReason(response)
        })
      })
      .receive('timeout', () => {
        workerLogger.warning('worker.fabric_join_timeout', 'runtime fabric channel join timed out', {})
      })
  }

  private onJoined(response: unknown): void {
    const connectionID =
      typeof response === 'object' && response !== null && 'connection_id' in response
        ? String(response.connection_id)
        : undefined
    workerLogger.info('worker.fabric_joined', 'runtime fabric channel joined', {
      worker_id: this.config.workerID,
      connection_id: connectionID ?? null
    })
    this.resetStreams()
    this.sendReady()
  }

  // Admission is the first message on every connection. Until the control
  // plane acknowledges it, nothing else may be sent, so a new connection can
  // never deliver work under the fence of an old one.
  private sendReady(): void {
    if (this.stopped || this.channel.state !== 'joined') return
    let bytes: Buffer
    const control = this.streams.control
    const seq = control.nextSeq
    try {
      bytes = this.seal(this.options.readyEnvelope(), 'control', seq)
    } catch (error) {
      workerLogger.error('worker.fabric_ready_invalid', 'worker ready envelope is invalid', { error: toError(error) })
      return
    }

    control.nextSeq = seq + 1
    this.channel
      .push('control', arrayBuffer(bytes), this.pushTimeoutMs)
      .receive('ok', response => {
        this.applyReply('control', streamReply(response))
        this.readyAttempt = 0
        this.ready = true
        this.wakeReadyWaiters()
        workerLogger.notice('worker.ready_sent', 'worker ready acknowledged', {
          endpoint: this.config.endpoint,
          worker_id: this.config.workerID
        })
      })
      .receive('error', response => {
        // Ready was not accepted, so its seq is free again for the retry.
        if (control.nextSeq === seq + 1) control.nextSeq = seq
        this.retryReady(replyReason(response))
      })
      .receive('timeout', () => this.retryReady('timeout'))
  }

  private retryReady(reason: string): void {
    if (this.stopped) return
    this.readyAttempt += 1
    const delayMs = Math.min(readyRetryMs.max, readyRetryMs.initial * 2 ** Math.min(this.readyAttempt - 1, 4))
    workerLogger.warning('worker.fabric_ready_rejected', 'worker ready was not accepted', {
      reason,
      retry_in_ms: delayMs
    })
    this.readyRetryTimer = setTimeout(() => {
      this.readyRetryTimer = undefined
      this.sendReady()
    }, delayMs)
  }

  private onDisconnected(reason: string): void {
    if (this.stopped) return
    const wasReady = this.ready
    this.ready = false
    if (this.readyRetryTimer) {
      clearTimeout(this.readyRetryTimer)
      this.readyRetryTimer = undefined
    }
    this.settleInFlight({ status: 'closed' })
    if (wasReady) {
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
      // The kernel stays the single semantic checker for received envelopes;
      // structural decoding uses the codec generated from envelope.proto.
      kernel.runtimeFabricValidateEnvelope(bytes)
      return { envelope: decodeEnvelope(bytes), bytes: bytes.byteLength }
    } catch (error) {
      workerLogger.error('worker.fabric_decode_failed', 'runtime fabric envelope rejected', {
        event,
        error: toError(error)
      })
      return undefined
    }
  }

  private enqueue(envelope: Envelope, bytes: number): void {
    if (this.inboundWaiter) {
      this.inboundWaiter({ kind: 'envelope', envelope })
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
    this.inbound.push({ envelope, bytes })
    this.inboundBytes += bytes
  }

  private seal(envelope: Envelope, stream: RuntimeFabricStream, seq: number): Buffer {
    try {
      const sequenced = { ...envelope, stream: streamEnum[stream], transportSeq: BigInt(seq) }
      return Buffer.from(kernel.runtimeFabricSealEnvelope(encodeEnvelope(sequenced)))
    } catch (error) {
      throw new RuntimeFabricTransportError('invalid_envelope', `invalid_envelope: ${errorMessage(error)}`, {
        cause: error
      })
    }
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
  const stream = record.stream
  return {
    stream: stream === 'control' || stream === 'durable' || stream === 'telemetry' ? stream : undefined,
    ackedSeq: optionalNumber(record.acked_seq),
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
