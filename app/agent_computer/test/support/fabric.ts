import { create } from '@bufbuild/protobuf'
import { Buffer } from 'node:buffer'
import {
  createChannelTransport,
  type ChannelLike,
  type ChannelPushLike,
  type ChannelSocketLike
} from '../../src/fabric/channel-transport'
import {
  createEnvelope,
  decodeEnvelope,
  encodeEnvelope,
  envelopeHeader,
  JobTurnRefSchema,
  ProtocolVersion,
  RPCRequestSchema,
  RPCResponseSchema,
  Stream,
  WorkerHeartbeatSchema,
  type Envelope
} from '../../src/fabric/envelope-proto'
import { TurnControlSchema } from '../../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'

export const fabricTestConfig = {
  endpoint: 'ws://127.0.0.1:4000/runtime-fabric/worker',
  workerID: 'worker-a',
  incarnationID: 'incarnation-a',
  workerAuthKey: 'test-secret'
}

export type TransportOptions = Parameters<typeof createChannelTransport>[1]

export function connect(options: Partial<TransportOptions> = {}) {
  const socket = new FakeSocket()
  const fabric = createChannelTransport(fabricTestConfig, {
    joinParams: () => ({ incarnation_id: fabricTestConfig.incarnationID, max_slots: 4, available_slots: 4 }),
    createSocket: () => socket,
    pushTimeoutMs: 50,
    readyWaitMs: 200,
    ackDelayMs: 0,
    ...options
  })
  return { socket, fabric: fabric as ReturnType<typeof createChannelTransport> & { telemetryDropped: number } }
}

export async function connectReady(options: Partial<TransportOptions> = {}) {
  const connected = connect(options)
  connected.socket.current!.joinPush!.reply('ok', { connection_id: 'connection-1' })
  await tick()
  return connected
}

export async function tick(): Promise<void> {
  await Bun.sleep(0)
  await Bun.sleep(0)
}

export async function afterTimers(): Promise<void> {
  await new Promise(resolve => setTimeout(resolve, 0))
  await tick()
}

export class FakePush implements ChannelPushLike {
  private readonly hooks: Array<{ status: string; callback: (response?: unknown) => void }> = []
  private settled?: { status: string; response?: unknown }

  constructor(
    readonly event: string,
    readonly payload: unknown
  ) {}

  receive(status: 'ok' | 'error' | 'timeout', callback: (response?: unknown) => void): FakePush {
    if (this.settled?.status === status) callback(this.settled.response)
    this.hooks.push({ status, callback })
    return this
  }

  reply(status: 'ok' | 'error' | 'timeout', response?: unknown): void {
    this.settled = { status, response }
    for (const hook of this.hooks) {
      if (hook.status === status) hook.callback(response)
    }
  }

  bytes(): Buffer {
    return Buffer.from(this.payload as ArrayBuffer)
  }
}

export class FakeChannel implements ChannelLike {
  state = 'closed'
  joinPush?: FakePush
  readonly pushes: FakePush[] = []
  private readonly handlers = new Map<string, Array<(payload: unknown) => void>>()
  private readonly closeHandlers: Array<() => void> = []

  params: object = {}

  constructor(
    readonly socket: FakeSocket,
    readonly topic: string,
    private readonly paramsSource: object | (() => object)
  ) {}

  join(): FakePush {
    this.state = 'joining'
    // Phoenix resolves a params closure when it sends each join.
    this.params = typeof this.paramsSource === 'function' ? this.paramsSource() : this.paramsSource
    this.joinPush = new FakePush('phx_join', this.params)
    this.joinPush.receive('ok', () => {
      this.state = 'joined'
    })
    return this.joinPush
  }

  leave(): FakePush {
    this.state = 'closed'
    return new FakePush('phx_leave', {})
  }

  push(event: string, payload: object): FakePush {
    if (this.state !== 'joined') throw new Error(`tried to push '${event}' before joining`)
    const push = new FakePush(event, payload)
    this.pushes.push(push)
    return push
  }

  on(event: string, callback: (payload: unknown) => void): number {
    this.handlers.set(event, [...(this.handlers.get(event) ?? []), callback])
    return this.handlers.size
  }

  onClose(callback: () => void): number {
    this.closeHandlers.push(callback)
    return this.closeHandlers.length
  }

  onError(): number {
    return 0
  }

  emit(event: string, payload: unknown): void {
    for (const handler of this.handlers.get(event) ?? []) handler(payload)
  }

  close(): void {
    this.state = 'closed'
    for (const handler of this.closeHandlers) handler()
  }

  /** Phoenix resends the same join push on reconnect, so its hooks fire again. */
  rejoin(): void {
    this.state = 'joining'
  }
}

export class FakeSocket implements ChannelSocketLike {
  current?: FakeChannel
  connects = 0
  disconnects = 0
  private connected = false
  private readonly openHandlers: Array<() => void> = []
  private readonly closeHandlers: Array<(event: unknown) => void> = []
  private readonly errorHandlers: Array<(event: unknown) => void> = []

  channel(topic: string, params: object | (() => object)): FakeChannel {
    this.current = new FakeChannel(this, topic, params)
    return this.current
  }

  connect(): void {
    this.connects += 1
    this.connected = true
  }

  disconnect(callback?: () => void): void {
    this.disconnects += 1
    this.connected = false
    callback?.()
  }

  isConnected(): boolean {
    return this.connected
  }

  onOpen(callback: () => void): void {
    this.openHandlers.push(callback)
  }

  onClose(callback: (event: unknown) => void): void {
    this.closeHandlers.push(callback)
  }

  onError(callback: (event: unknown) => void): void {
    this.errorHandlers.push(callback)
  }

  error(event: unknown): void {
    for (const handler of this.errorHandlers) handler(event)
  }

  /** Simulates a lost connection: the channel drops to errored and awaits a rejoin. */
  close(code = 1006, reason = '', wasClean = false): void {
    this.connected = false
    if (this.current) this.current.state = 'errored'
    for (const handler of this.closeHandlers) handler(new CloseEvent('close', { code, reason, wasClean }))
  }

  /** Simulates a reconnect: Phoenix resends the join push of every channel. */
  open(): void {
    this.connected = true
    for (const handler of this.openHandlers) handler()
    this.current?.rejoin()
  }
}

export function sealed(envelope: Envelope, seq = 1): Buffer {
  return Buffer.from(
    encodeEnvelope({
      ...envelope,
      protocolVersion: ProtocolVersion.CURRENT,
      stream: Stream.DURABLE,
      transportSeq: BigInt(seq)
    })
  )
}

export function seqOf(push: FakePush): number {
  return Number(decodeEnvelope(push.bytes()).transportSeq)
}

export function arrayBuffer(bytes: Buffer): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}

export function heartbeatEnvelope(): Envelope {
  return createEnvelope({
    ...envelopeHeader(`worker-heartbeat-${crypto.randomUUID()}`),
    body: {
      case: 'workerHeartbeat',
      value: create(WorkerHeartbeatSchema, {
        incarnationId: 'incarnation-a',
        activeSlots: 0,
        maxSlots: 4,
        availableSlots: 4
      })
    }
  })
}

export function rpcRequestEnvelope(method: string): Envelope {
  const requestID = `request-${crypto.randomUUID()}`
  return createEnvelope({
    ...envelopeHeader(`rpc-${requestID}`),
    body: {
      case: 'rpcRequest',
      value: create(RPCRequestSchema, { requestId: requestID, method, payload: new Uint8Array() })
    }
  })
}

export function rpcResponseEnvelope(requestID: string): Envelope {
  return createEnvelope({
    ...envelopeHeader(`rpc-reply-${crypto.randomUUID()}`),
    body: {
      case: 'rpcResponse',
      value: create(RPCResponseSchema, { requestId: requestID, payload: new Uint8Array() })
    }
  })
}

export function turnControlEnvelope(messageID: string): Envelope {
  return createEnvelope({
    ...envelopeHeader(messageID),
    body: {
      case: 'turnControl',
      value: create(TurnControlSchema, {
        turn: create(JobTurnRefSchema, {
          jobId: 1000n,
          attempt: 1,
          signalId: '00000000-0000-0000-0000-000000000101'
        }),
        command: 'retry'
      })
    }
  })
}
