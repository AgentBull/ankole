import { create } from '@bufbuild/protobuf'
import { describe, expect, it, spyOn } from 'bun:test'
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
  JobTurnRefSchema,
  WorkerHeartbeatSchema,
  createEnvelope,
  decodeEnvelope,
  encodeEnvelope,
  ProtocolVersion,
  envelopeHeader,
  Stream,
  RPCRequestSchema,
  RPCResponseSchema,
  type Envelope
} from '../src/fabric/envelope_proto'
import { TurnControlSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { workerLogger } from '../src/worker/logging'
import { RuntimeFabricTransportError } from '../src/fabric/fabric'

const config = {
  endpoint: 'ws://127.0.0.1:4000/runtime-fabric/worker',
  workerID: 'worker-a',
  incarnationID: 'incarnation-a',
  workerAuthKey: 'test-secret'
}

describe('RuntimeFabric channel transport', () => {
  it('rejects a frame overflow before sending and keeps the sequence for the next request', async () => {
    const { socket, fabric } = await connectReady()
    const channel = socket.current!
    const oversized = rpcRequestEnvelope('pod.read')
    if (oversized.body.case !== 'rpcRequest') throw new Error('Expected an RPC request')
    oversized.body.value.payload = new Uint8Array(32 * 1024 * 1024)
    try {
      const rejected = fabric.sendEnvelope(oversized).catch(error => error)
      await tick()
      expect(channel.pushes).toHaveLength(0)
      expect(await rejected).toMatchObject({ code: 'rejected', reason: 'frame_too_large', retryable: false })

      const next = rpcRequestEnvelope('pod.read')
      if (next.body.case !== 'rpcRequest') throw new Error('Expected an RPC request')
      next.body.value.payload = new Uint8Array(16 * 1024 * 1024 - 2048)
      const sending = fabric.sendEnvelope(next)
      await tick()
      expect(channel.pushes).toHaveLength(1)
      expect(decodeEnvelope(channel.pushes[0]!.bytes()).transportSeq).toBe(1n)
      channel.pushes[0]!.reply('ok')
      await sending
    } finally {
      fabric.stop()
    }
  })

  it('join success opens the windows without a second admission message', async () => {
    const { socket, fabric } = connect()
    const channel = socket.current!
    // main.ts hands `sendEnvelope` and `receive` around as plain functions.
    const { sendEnvelope } = fabric

    expect(channel.topic).toBe(runtimeFabricWorkerTopic)
    expect(channel.params).toEqual({
      incarnation_id: 'incarnation-a',
      max_slots: 4,
      available_slots: 4
    })

    const send = sendEnvelope(heartbeatEnvelope())
    await tick()
    expect(channel.pushes).toHaveLength(0)

    channel.joinPush!.reply('ok', { connection_id: 'connection-1' })
    await tick()
    expect(channel.pushes).toHaveLength(1)
    expect(channel.pushes[0]!.event).toBe('control')
    expect(decodeEnvelope(channel.pushes[0]!.bytes()).body.case).toBe('workerHeartbeat')
    channel.pushes[0]!.reply('ok')
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

  it('rejects an older protocol before queueing the envelope', async () => {
    const { socket, fabric } = await connectReady()
    const log = spyOn(workerLogger, 'error').mockImplementation(() => undefined)
    try {
      const bytes = encodeEnvelope({
        ...turnControlEnvelope('old-protocol'),
        protocolVersion: 5,
        stream: Stream.DURABLE,
        transportSeq: 1n
      })
      socket.current!.emit('command', arrayBuffer(bytes))
      expect(await fabric.receive(5)).toEqual({ kind: 'timeout' })
      expect(log).toHaveBeenCalledWith(
        'worker.fabric_decode_failed',
        'runtime fabric envelope rejected',
        expect.objectContaining({ event: 'command' })
      )
    } finally {
      log.mockRestore()
      fabric.stop()
    }
  })

  it('acknowledges replies on the shared inbound sequence and rejects invalid protobuf bytes', async () => {
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
    expect(await fabric.receive(5)).toMatchObject({ kind: 'disconnected', connectionID: 'connection-1' })
    expect(await fabric.receive(5)).toEqual({ kind: 'timeout' })
    fabric.stop()
  })

  it('numbers streams per join and keeps each push business outcome separate from cumulative ACK', async () => {
    const { socket, fabric } = await connectReady()
    const channel = socket.current!
    expect(channel.pushes).toHaveLength(0)

    const first = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    const second = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete'))
    const heartbeat = fabric.sendEnvelope(heartbeatEnvelope())
    await tick()

    const durable = channel.pushes.filter(push => push.event === 'durable')
    expect(durable.map(seqOf)).toEqual([1, 2])
    expect(seqOf(channel.pushes.filter(push => push.event === 'control').at(-1)!)).toBe(1)

    durable[1]!.reply('ok', { stream: 'durable', acked_seq: 2, message_credit: 62, byte_credit: 1024 })
    await second
    durable[0]!.reply('error', { reason: 'run_closed', acked_seq: 2 })
    expect(await first.catch(error => error)).toMatchObject({ code: 'rejected', reason: 'run_closed' })
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

  it('fails in-flight pushes and resumes queued sends after the rejoin', async () => {
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
    expect(channel.pushes).toHaveLength(pushesBeforeRejoin + 1)
    const durable = channel.pushes.at(-1)!
    expect(durable.event).toBe('durable')
    expect(seqOf(durable)).toBe(1)
    durable.reply('ok')
    await afterDrop
    fabric.stop()
  })

  it('does not let a late old push callback settle a rejoined push with the same sequence', async () => {
    const { socket, fabric } = await connectReady()
    const channel = socket.current!
    const before = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete')).catch(error => error)
    await tick()
    const oldPush = channel.pushes.at(-1)!
    socket.close()
    expect(await before).toMatchObject({ code: 'socket_closed' })
    socket.open()
    channel.joinPush!.reply('ok', { connection_id: 'connection-2' })
    let settled = false
    const after = fabric.sendEnvelope(rpcRequestEnvelope('actor_turn.complete')).finally(() => {
      settled = true
    })
    await tick()
    const newPush = channel.pushes.at(-1)!
    expect(seqOf(oldPush)).toBe(1)
    expect(seqOf(newPush)).toBe(1)
    oldPush.reply('timeout')
    oldPush.reply('ok', { acked_seq: 9, message_credit: 0, byte_credit: 0 })
    oldPush.reply('error', { reason: 'bad_sequence', expected: 10 })
    await tick()
    expect(settled).toBe(false)
    expect(socket.current).toBe(channel)
    expect(fabric.isReady).toBe(true)
    newPush.reply('ok')
    await after
    fabric.stop()
  })

  it('delivers queued and already-handed replies before the connection loss event', async () => {
    for (const waiting of [false, true]) {
      const { socket, fabric } = await connectReady()
      const receive = waiting ? fabric.receive(50) : undefined
      const reply = sealed(rpcResponseEnvelope('reply-before-close'))
      socket.current!.emit('reply', arrayBuffer(reply))
      socket.close()
      expect(await (receive ?? fabric.receive(50))).toEqual({ kind: 'envelope', envelope: decodeEnvelope(reply) })
      expect(await fabric.receive(50)).toMatchObject({ kind: 'disconnected', connectionID: 'connection-1' })
      fabric.stop()
    }
  })

  it('cancels a send waiting for reconnect and never sends it after rejoin', async () => {
    const { socket, fabric } = await connectReady()
    const channel = socket.current!
    socket.close()
    const cancellation = new AbortController()
    const send = fabric
      .sendEnvelope(rpcRequestEnvelope('actor_turn.complete'), { signal: cancellation.signal })
      .catch(error => error)
    await tick()
    cancellation.abort(new DOMException('deadline', 'AbortError'))
    expect(await send).toMatchObject({ name: 'AbortError' })
    socket.open()
    channel.joinPush!.reply('ok', { connection_id: 'connection-2' })
    await tick()
    expect(channel.pushes.filter(push => push.event === 'durable')).toHaveLength(0)
    fabric.stop()
  })

  it('reconnects after the server closes the socket with a normal close', async () => {
    const lostConnections: string[] = []
    const { socket, fabric } = await connectReady({
      reconnectDelayMs: () => 0,
      onDisconnected: reason => lostConnections.push(reason)
    })
    const channel = socket.current!
    expect(socket.connects).toBe(1)

    // Phoenix does not reconnect after code 1000, which the control plane's
    // server sends to every socket when it shuts down.
    socket.close(1000)
    expect(lostConnections).toEqual(['socket_closed'])
    await afterTimers()
    expect(socket.disconnects).toBe(1)
    expect(socket.connects).toBe(2)

    socket.open()
    channel.joinPush!.reply('ok', { connection_id: 'connection-2' })
    await tick()
    expect(fabric.isolationReason(0)).toBeUndefined()
    socket.close(1006)
    socket.close(1006)
    expect(lostConnections).toEqual(['socket_closed', 'socket_closed'])
    fabric.stop()
  })

  it('leaves the reconnect after an abnormal close to Phoenix and stops reconnecting after stop', async () => {
    const { socket, fabric } = await connectReady({ reconnectDelayMs: () => 0 })

    socket.close(1006)
    await afterTimers()
    expect(socket.connects).toBe(1)

    fabric.stop()
    socket.close(1000)
    await afterTimers()
    expect(socket.connects).toBe(1)
  })

  it('logs the ErrorEvent cause and close code instead of converting the event to a string', async () => {
    const { socket, fabric } = await connectReady()
    const log = spyOn(workerLogger, 'warning').mockImplementation(() => undefined)
    try {
      const error = new Error('connection refused')
      error.name = 'NetworkError'
      socket.error(new ErrorEvent('error', { message: error.message, error }))
      expect(log).toHaveBeenCalledWith('worker.fabric_socket_error', 'runtime fabric socket error', {
        error,
        error_type: 'NetworkError',
        event_type: 'error'
      })
      socket.error(new ErrorEvent('error', { message: 'WebSocket upgrade failed' }))
      expect(log).toHaveBeenCalledWith('worker.fabric_socket_error', 'runtime fabric socket error', {
        error: expect.objectContaining({ message: 'WebSocket upgrade failed' }),
        error_type: 'ErrorEvent',
        event_type: 'error'
      })
      socket.close(1012, 'service restart', false)
      expect(log).toHaveBeenCalledWith('worker.fabric_socket_closed', 'runtime fabric socket closed', {
        close_code: 1012,
        close_reason: 'service restart',
        was_clean: false
      })
    } finally {
      log.mockRestore()
      fabric.stop()
    }
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

  it('reports no_channel only after the channel stays down for the limit', async () => {
    const { socket, fabric } = connect()
    // A process that never joined counts from its start.
    expect(fabric.isolationReason(0)).toBe('no_channel')
    expect(fabric.isolationReason(60_000)).toBeUndefined()

    socket.current!.joinPush!.reply('ok', { connection_id: 'connection-1' })
    await tick()
    expect(fabric.isolationReason(0)).toBeUndefined()

    socket.close()
    expect(fabric.isolationReason(0)).toBe('no_channel')
    expect(fabric.isolationReason(60_000)).toBeUndefined()
    fabric.stop()
  })

  it('isolates at once when the control plane refuses the join for a stale generation', async () => {
    const { socket, fabric } = connect()

    socket.current!.joinPush!.reply('error', { reason: 'protocol_mismatch' })
    await tick()
    expect(fabric.isolationReason(60_000)).toBeUndefined()

    socket.current!.joinPush!.reply('error', { reason: 'stale_worker_generation' })
    await tick()
    expect(fabric.isolationReason(60_000)).toBe('stale_worker_generation')
    fabric.stop()
  })

  it('reconnects the same process after a clock gap even when the old socket appears connected', async () => {
    let now = Date.now()
    const clock = spyOn(Date, 'now').mockImplementation(() => now)
    const { socket, fabric } = await connectReady()
    try {
      now += 300_001
      expect(fabric.isolationReason(300_000)).toBeUndefined()
      expect(fabric.isReady).toBe(false)
      expect(socket.disconnects).toBe(1)
      expect(socket.connects).toBe(2)

      socket.open()
      const channel = socket.current!
      expect(channel.params).toMatchObject({ incarnation_id: 'incarnation-a' })
      channel.joinPush!.reply('ok', { connection_id: 'connection-after-resume' })
      await tick()
      expect(fabric.isReady).toBe(true)
      expect(fabric.isolationReason(0)).toBeUndefined()
    } finally {
      fabric.stop()
      clock.mockRestore()
    }
  })

  it('resets isolation after a paused disconnected process resumes but still limits a continuous outage', () => {
    let now = Date.now()
    const clock = spyOn(Date, 'now').mockImplementation(() => now)
    const { socket, fabric } = connect()
    try {
      socket.close()
      now += 300_001
      expect(fabric.isolationReason(300_000)).toBeUndefined()
      expect(socket.connects).toBe(2)

      for (let i = 1; i <= 10; i++) {
        now += 30_000
        expect(fabric.isolationReason(300_000)).toBe(i === 10 ? 'no_channel' : undefined)
      }
      expect(socket.connects).toBe(2)
    } finally {
      fabric.stop()
      clock.mockRestore()
    }
  })

  it('does not revive a refused or stopped process after a clock gap', () => {
    for (const state of ['refused', 'stopped']) {
      let now = Date.now()
      const clock = spyOn(Date, 'now').mockImplementation(() => now)
      const { socket, fabric } = connect()
      try {
        if (state === 'refused') socket.current!.joinPush!.reply('error', { reason: 'stale_worker_generation' })
        else fabric.stop()

        now += 300_001
        const reason = fabric.isolationReason(300_000)
        if (state === 'refused') expect(reason).toBe('stale_worker_generation')
        expect(socket.connects).toBe(1)
      } finally {
        fabric.stop()
        clock.mockRestore()
      }
    }
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
    joinParams: () => ({ incarnation_id: config.incarnationID, max_slots: 4, available_slots: 4 }),
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
  return connected
}

async function tick(): Promise<void> {
  await Bun.sleep(0)
  await Bun.sleep(0)
}

async function afterTimers(): Promise<void> {
  await new Promise(resolve => setTimeout(resolve, 0))
  await tick()
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

function sealed(envelope: Envelope, seq = 1): Buffer {
  return Buffer.from(
    encodeEnvelope({
      ...envelope,
      protocolVersion: ProtocolVersion.CURRENT,
      stream: Stream.DURABLE,
      transportSeq: BigInt(seq)
    })
  )
}

function seqOf(push: FakePush): number {
  return Number(decodeEnvelope(push.bytes()).transportSeq)
}

function arrayBuffer(bytes: Buffer): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}

function heartbeatEnvelope(): Envelope {
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

function rpcRequestEnvelope(method: string): Envelope {
  const requestID = `request-${crypto.randomUUID()}`
  return createEnvelope({
    ...envelopeHeader(`rpc-${requestID}`),
    body: {
      case: 'rpcRequest',
      value: create(RPCRequestSchema, { requestId: requestID, method, payload: new Uint8Array() })
    }
  })
}

function rpcResponseEnvelope(requestID: string): Envelope {
  return createEnvelope({
    ...envelopeHeader(`rpc-reply-${crypto.randomUUID()}`),
    body: {
      case: 'rpcResponse',
      value: create(RPCResponseSchema, { requestId: requestID, payload: new Uint8Array() })
    }
  })
}

function turnControlEnvelope(messageID: string): Envelope {
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
