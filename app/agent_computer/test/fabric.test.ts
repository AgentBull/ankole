import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { runtimeFabricSealEnvelope } from '@ankole/kernel'
import { Buffer } from 'node:buffer'
import {
  createChannelTransport,
  runtimeFabricStream,
  runtimeFabricWorkerTopic,
  type ChannelLike,
  type ChannelPushLike,
  type ChannelSocketLike
} from '../src/fabric/channel_transport'
import {
  ActorKeySchema,
  ActorTurnRefSchema,
  AgentComputerWorkerHeartbeatSchema,
  AgentComputerWorkerReadySchema,
  createEnvelope,
  decodeEnvelope,
  encodeEnvelope,
  envelopeHeader,
  Stream,
  RPCRequestSchema,
  RPCResponseSchema,
  TurnControlSchema,
  type Envelope
} from '../src/fabric/envelope_proto'
import { RuntimeFabricTransportError } from '../src/fabric/fabric'

const config = {
  endpoint: 'ws://127.0.0.1:4000/runtime-fabric/worker',
  workerID: 'worker-a',
  incarnationID: 'incarnation-a',
  workerAuthKey: 'test-secret'
}

describe('RuntimeFabric channel transport', () => {
  it('joins the worker topic, sends ready on control, and opens the windows after the ack', async () => {
    const { socket, fabric } = connect()
    const channel = socket.current!
    // main.ts hands `sendEnvelope` and `receive` around as plain functions.
    const { sendEnvelope } = fabric

    expect(channel.topic).toBe(runtimeFabricWorkerTopic('worker-a'))
    expect(channel.params).toEqual({
      worker_id: 'worker-a',
      incarnation_id: 'incarnation-a',
      runtime: 'bun',
      version: 'test',
      max_turns: 4,
      available_turn_slots: 4
    })

    const send = sendEnvelope(heartbeatEnvelope())
    await tick()
    expect(channel.pushes).toHaveLength(0)

    channel.joinPush!.reply('ok', { connection_id: 'connection-1' })
    await tick()
    expect(channel.pushes).toHaveLength(1)
    expect(channel.pushes[0]!.event).toBe('control')
    expect(decodeEnvelope(channel.pushes[0]!.bytes()).body.case).toBe('workerReady')

    channel.pushes[0]!.reply('ok')
    await tick()
    expect(channel.pushes).toHaveLength(2)
    expect(channel.pushes[1]!.event).toBe('control')
    expect(decodeEnvelope(channel.pushes[1]!.bytes()).body.case).toBe('workerHeartbeat')

    channel.pushes[1]!.reply('ok')
    await send
    fabric.stop()
  })

  it('acknowledges a command by message id before the worker receives it', async () => {
    const { socket, fabric } = await connectReady()
    const channel = socket.current!
    const command = sealed(turnControlEnvelope('command-1'))

    channel.emit('command', arrayBuffer(command))
    await tick()

    expect(channel.pushes.at(-1)).toMatchObject({
      event: 'ack',
      payload: { acked_seq: 1, message_credit: 1023, byte_credit: expect.any(Number) }
    })
    expect(await fabric.receive(5)).toEqual({ kind: 'envelope', envelope: decodeEnvelope(command) })
    expect(await fabric.receive(5)).toEqual({ kind: 'timeout' })
    fabric.stop()
  })

  it('acknowledges replies on the shared inbound sequence and rejects bytes the kernel refuses', async () => {
    const { socket, fabric } = await connectReady()
    const channel = socket.current!
    const reply = sealed(rpcResponseEnvelope('request-1'), 1)
    const pushesBefore = channel.pushes.length

    channel.emit('reply', arrayBuffer(reply))
    channel.emit('command', arrayBuffer(Buffer.from('not-protobuf')))
    await tick()

    expect(channel.pushes).toHaveLength(pushesBefore + 1)
    expect(channel.pushes.at(-1)).toMatchObject({ event: 'ack', payload: { acked_seq: 1 } })
    expect(await fabric.receive(5)).toEqual({ kind: 'envelope', envelope: decodeEnvelope(reply) })
    expect(await fabric.receive(5)).toEqual({ kind: 'timeout' })
    fabric.stop()
  })

  it('rejoins when an inbound command skips a sequence number', async () => {
    const { socket, fabric } = await connectReady()
    const first = socket.current!

    first.emit('command', arrayBuffer(sealed(turnControlEnvelope('command-2'), 2)))
    await tick()

    const second = socket.current!
    expect(second).not.toBe(first)
    expect(second.joinPush).toBeDefined()
    expect(await fabric.receive(5)).toEqual({ kind: 'timeout' })
    fabric.stop()
  })

  it('numbers each stream from 1 per join and resolves pushes cumulatively', async () => {
    const { socket, fabric } = await connectReady()
    const channel = socket.current!
    const ready = channel.pushes[0]!
    expect(seqOf(ready)).toBe(1)

    const first = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    const second = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    const heartbeat = fabric.sendEnvelope(heartbeatEnvelope())
    await tick()

    const durable = channel.pushes.filter(push => push.event === 'durable')
    expect(durable.map(seqOf)).toEqual([1, 2])
    expect(seqOf(channel.pushes.filter(push => push.event === 'control').at(-1)!)).toBe(2)

    durable[1]!.reply('ok', { stream: 'durable', acked_seq: 2, message_credit: 62, byte_credit: 1024 })
    await first
    await second
    channel.pushes
      .filter(push => push.event === 'control')
      .at(-1)!
      .reply('ok')
    await heartbeat
    fabric.stop()
  })

  it('bounds the window by the credit the control plane returns', async () => {
    const { socket, fabric } = await connectReady()
    const channel = socket.current!

    const first = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    await tick()
    channel.pushes.at(-1)!.reply('ok', { stream: 'durable', acked_seq: 1, message_credit: 1, byte_credit: 1 << 20 })
    await first

    const second = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    const third = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    await tick()
    expect(channel.pushes.filter(push => push.event === 'durable')).toHaveLength(2)

    channel.pushes.at(-1)!.reply('ok', { stream: 'durable', acked_seq: 2, message_credit: 8, byte_credit: 1 << 20 })
    await second
    await tick()
    expect(channel.pushes.filter(push => push.event === 'durable')).toHaveLength(3)
    expect(seqOf(channel.pushes.at(-1)!)).toBe(3)
    channel.pushes.at(-1)!.reply('ok', { stream: 'durable', acked_seq: 3, message_credit: 8, byte_credit: 1 << 20 })
    await third
    fabric.stop()
  })

  it('rejoins on bad_sequence and fails the in-flight push', async () => {
    const { socket, fabric } = await connectReady()
    const first = socket.current!

    const send = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    await tick()
    first.pushes.at(-1)!.reply('error', { reason: 'bad_sequence', expected: 7 })

    expect(await send.catch(error => error)).toMatchObject({ code: 'socket_closed' })
    const second = socket.current!
    expect(second).not.toBe(first)
    expect(second.joinPush).toBeDefined()
    fabric.stop()
  })

  it('classifies every body into its stream', () => {
    expect(runtimeFabricStream(heartbeatEnvelope())).toBe('control')
    expect(runtimeFabricStream(rpcRequestEnvelope('observability.spans.export'))).toBe('telemetry')
    expect(runtimeFabricStream(rpcRequestEnvelope('actor_turn.complete'))).toBe('durable')
    expect(runtimeFabricStream(rpcResponseEnvelope('request-1'))).toBe('durable')
  })

  it('pushes each stream on its own event and retries durable flow control', async () => {
    const { socket, fabric } = await connectReady({ flowControlBackoffMs: { initial: 1, max: 1 } })
    const channel = socket.current!
    const send = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    await tick()

    const first = channel.pushes.at(-1)!
    expect(first.event).toBe('durable')
    first.reply('error', { reason: 'flow_control', stream: 'durable', acked_seq: 0, message_credit: 0, byte_credit: 0 })
    await Bun.sleep(5)

    // The rejected push kept its sequence number.
    const second = channel.pushes.at(-1)!
    expect(second).not.toBe(first)
    expect(second.event).toBe('durable')
    expect(second.bytes()).toEqual(first.bytes())
    expect(seqOf(second)).toBe(1)
    second.reply('ok', { stream: 'durable', acked_seq: 1, message_credit: 63, byte_credit: 1 << 20 })
    await send
    fabric.stop()
  })

  it('drops telemetry when its window is full and when the control plane applies flow control', async () => {
    const { socket, fabric } = await connectReady({ windows: { telemetry: { maxMessages: 1, maxBytes: 1024 } } })
    const channel = socket.current!

    const inFlight = fabric.sendEnvelope(rpcRequestEnvelope('observability.spans.export'))
    await fabric.sendEnvelope(rpcRequestEnvelope('observability.spans.export'))
    await tick()

    const telemetryPushes = channel.pushes.filter(push => push.event === 'telemetry')
    expect(telemetryPushes).toHaveLength(1)
    telemetryPushes[0]!.reply('error', { reason: 'flow_control' })
    await inFlight

    expect(channel.pushes.filter(push => push.event === 'telemetry')).toHaveLength(1)
    expect(fabric.telemetryDropped).toBe(2)
    fabric.stop()
  })

  it('surfaces rejections and unanswered pushes as typed transport errors', async () => {
    const { socket, fabric } = await connectReady()
    const channel = socket.current!

    const rejected = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    await tick()
    channel.pushes.at(-1)!.reply('error', { reason: 'wrong_stream' })
    expect(await rejected.catch(error => error)).toMatchObject({ code: 'rejected', message: 'rejected: wrong_stream' })

    const unanswered = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    await tick()
    channel.pushes.at(-1)!.reply('timeout')
    expect(await unanswered.catch(error => error)).toMatchObject({ code: 'timeout' })
    fabric.stop()
  })

  it('fails in-flight pushes on disconnect and sends ready again after the rejoin', async () => {
    const { socket, fabric } = await connectReady()
    const channel = socket.current!

    const inFlight = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    await tick()
    socket.close()
    expect(await inFlight.catch(error => error)).toMatchObject({ code: 'socket_closed' })

    const afterDrop = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    await tick()
    const pushesBeforeRejoin = channel.pushes.length

    socket.open()
    channel.joinPush!.reply('ok', { connection_id: 'connection-2' })
    await tick()
    const ready = channel.pushes.at(-1)!
    expect(channel.pushes).toHaveLength(pushesBeforeRejoin + 1)
    expect(ready.event).toBe('control')
    expect(decodeEnvelope(ready.bytes()).body.case).toBe('workerReady')

    ready.reply('ok')
    await tick()
    const durable = channel.pushes.at(-1)!
    expect(durable.event).toBe('durable')
    durable.reply('ok')
    await afterDrop
    fabric.stop()
  })

  it('replaces a channel the server closed and joins again', async () => {
    const { socket, fabric } = await connectReady()
    const first = socket.current!

    first.close()
    await tick()

    const second = socket.current!
    expect(second).not.toBe(first)
    expect(second.topic).toBe(first.topic)
    expect(second.joinPush).toBeDefined()
    fabric.stop()
  })

  it('rejects every operation after stop', async () => {
    const { socket, fabric } = await connectReady()

    fabric.stop()
    fabric.stop()

    expect(socket.disconnects).toBe(1)
    expect(await fabric.sendEnvelope(heartbeatEnvelope()).catch(error => error)).toMatchObject({
      code: 'socket_closed'
    })
    expect(() => fabric.receive(5)).toThrow(RuntimeFabricTransportError)
  })
})

type Options = Parameters<typeof createChannelTransport>[1]

function connect(options: Partial<Options> = {}) {
  const socket = new FakeSocket()
  const fabric = createChannelTransport(config, {
    readyEnvelope: () => readyEnvelope(),
    createSocket: () => socket,
    pushTimeoutMs: 50,
    readyWaitMs: 200,
    ackDelayMs: 0,
    ...options
  })
  return { socket, fabric: fabric as ReturnType<typeof createChannelTransport> & { telemetryDropped: number } }
}

async function connectReady(options: Partial<Options> = {}) {
  const connected = connect(options)
  connected.socket.current!.joinPush!.reply('ok', { connection_id: 'connection-1' })
  await tick()
  connected.socket.current!.pushes.at(-1)!.reply('ok')
  await tick()
  return connected
}

async function tick(): Promise<void> {
  await Bun.sleep(0)
  await Bun.sleep(0)
}

class FakePush implements ChannelPushLike {
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

class FakeChannel implements ChannelLike {
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

class FakeSocket implements ChannelSocketLike {
  current?: FakeChannel
  disconnects = 0
  private connected = false
  private readonly openHandlers: Array<() => void> = []
  private readonly closeHandlers: Array<(event: unknown) => void> = []

  channel(topic: string, params: object | (() => object)): FakeChannel {
    this.current = new FakeChannel(this, topic, params)
    return this.current
  }

  connect(): void {
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

  onError(): void {}

  /** Simulates a lost connection: the channel drops to errored and awaits a rejoin. */
  close(): void {
    this.connected = false
    if (this.current) this.current.state = 'errored'
    for (const handler of this.closeHandlers) handler({ code: 1006 })
  }

  /** Simulates a reconnect: Phoenix resends the join push of every channel. */
  open(): void {
    this.connected = true
    for (const handler of this.openHandlers) handler()
    this.current?.rejoin()
  }
}

function sealed(envelope: Envelope, seq = 1): Buffer {
  return Buffer.from(
    runtimeFabricSealEnvelope(encodeEnvelope({ ...envelope, stream: Stream.DURABLE, transportSeq: BigInt(seq) }))
  )
}

function seqOf(push: FakePush): number {
  return Number(decodeEnvelope(push.bytes()).transportSeq)
}

function arrayBuffer(bytes: Buffer): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}

function readyEnvelope(): Envelope {
  return createEnvelope({
    ...envelopeHeader(`worker-ready-${crypto.randomUUID()}`),
    body: {
      case: 'workerReady',
      value: create(AgentComputerWorkerReadySchema, {
        workerId: 'worker-a',
        incarnationId: 'incarnation-a',
        runtime: 'bun',
        version: 'test',
        maxTurns: 4,
        availableTurnSlots: 4
      })
    }
  })
}

function heartbeatEnvelope(): Envelope {
  return createEnvelope({
    ...envelopeHeader(`worker-heartbeat-${crypto.randomUUID()}`),
    body: {
      case: 'workerHeartbeat',
      value: create(AgentComputerWorkerHeartbeatSchema, {
        workerId: 'worker-a',
        incarnationId: 'incarnation-a',
        monotonicMs: 1n,
        activeTurns: 0,
        runtime: 'bun',
        version: 'test',
        maxTurns: 4,
        availableTurnSlots: 4
      })
    }
  })
}

function rpcRequestEnvelope(method: string): Envelope {
  const requestID = `request-${crypto.randomUUID()}`
  return createEnvelope({
    ...envelopeHeader(`rpc-${requestID}`, requestID),
    body: {
      case: 'rpcRequest',
      value: create(RPCRequestSchema, { requestId: requestID, method, payload: new Uint8Array(), agentUid: 'agent-a' })
    }
  })
}

function rpcResponseEnvelope(requestID: string): Envelope {
  return createEnvelope({
    ...envelopeHeader(`rpc-reply-${crypto.randomUUID()}`, requestID),
    body: {
      case: 'rpcResponse',
      value: create(RPCResponseSchema, { requestId: requestID, payload: new Uint8Array() })
    }
  })
}

function turnControlEnvelope(messageID: string): Envelope {
  return createEnvelope({
    ...envelopeHeader(messageID, 'turn-1'),
    body: {
      case: 'turnControl',
      value: create(TurnControlSchema, {
        turn: create(ActorTurnRefSchema, {
          actor: create(ActorKeySchema, { agentUid: 'agent-a', sessionId: 'session-1' }),
          activationUid: 'activation-1',
          actorEpoch: 1n,
          actorEventId: '00000000-0000-0000-0000-000000000101',
          revision: 0
        }),
        command: 'retry'
      })
    }
  })
}
