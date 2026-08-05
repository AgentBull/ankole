import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import {
  connectRuntimeFabric,
  createRuntimeFabricHost,
  runtimeFabricFileProtocol,
  RuntimeFabricTransportError,
  type RuntimeFabricPhysicalTransport
} from '../src/fabric/fabric'
import {
  AgentComputerWorkerReadySchema,
  createEnvelope,
  decodeEnvelope,
  encodeEnvelope,
  envelopeHeader,
  type Envelope
} from '../src/fabric/envelope_proto'
import { runtimeFabricSealEnvelope } from '@ankole/kernel'
import { Buffer } from 'node:buffer'

describe('RuntimeFabric host adapter', () => {
  it('retries bounded native backpressure before reporting send success', async () => {
    const transport = new TestRuntimeFabricTransport()
    transport.envelopeSendErrors.push(new Error('backpressure'), new Error('backpressure'))
    const fabric = createRuntimeFabricHost(transport, {
      initialDelayMs: 1,
      maxDelayMs: 1,
      maxAttempts: 4
    })

    await fabric.sendEnvelope(testEnvelope())

    expect(transport.sentEnvelopes).toHaveLength(1)
    expect(transport.envelopeSendAttempts).toBe(3)
  })

  it('translates native send errors and does not retry non-backpressure failures', async () => {
    const transport = new TestRuntimeFabricTransport()
    transport.envelopeSendErrors.push(new Error('socket_closed'))
    const fabric = createRuntimeFabricHost(transport, {
      initialDelayMs: 1,
      maxDelayMs: 1,
      maxAttempts: 4
    })

    const error = await fabric.sendEnvelope(testEnvelope()).catch(caught => caught)

    expect(error).toBeInstanceOf(RuntimeFabricTransportError)
    expect(error).toMatchObject({ code: 'socket_closed', message: 'socket_closed' })
    expect(transport.envelopeSendAttempts).toBe(1)
  })

  it('classifies timeout and decodes a single envelope frame through the native codec', async () => {
    const transport = new TestRuntimeFabricTransport()
    // A received frame always left a peer's kernel, so it arrives sealed.
    const wireFrame = runtimeFabricSealEnvelope(encodeEnvelope(testEnvelope()))
    transport.receives.push(null, [Buffer.from(wireFrame)])
    const fabric = createRuntimeFabricHost(transport)

    expect(await fabric.receive(5)).toEqual({ kind: 'timeout' })
    expect(await fabric.receive(5)).toEqual({ kind: 'envelope', envelope: decodeEnvelope(wireFrame) })
  })

  it('owns an idempotent dealer stop and rejects later transport operations', async () => {
    const transport = new TestRuntimeFabricTransport()
    const fabric = createRuntimeFabricHost(transport)

    fabric.stop()
    fabric.stop()
    const sendError = await fabric.sendEnvelope(testEnvelope()).catch(caught => caught)
    const receiveError = await fabric.receive(5).catch(caught => caught)

    expect(transport.stopAttempts).toBe(1)
    expect(sendError).toMatchObject({ code: 'socket_closed' })
    expect(receiveError).toMatchObject({ code: 'socket_closed' })
  })

  it('translates native dealer construction failures at the production seam', () => {
    expect(() => connectRuntimeFabric({ endpoint: '', workerID: 'worker-a', workerAuthKey: 'test-secret' })).toThrow(
      expect.objectContaining({
        name: 'RuntimeFabricTransportError',
        code: 'invalid_config'
      })
    )
  })

  it('shares bounded backpressure retry across worker-file sends', async () => {
    const transport = new TestRuntimeFabricTransport()
    transport.fileSendErrors.push(new Error('backpressure'), new Error('backpressure'))
    const fabric = createRuntimeFabricHost(transport, {
      initialDelayMs: 1,
      maxDelayMs: 1,
      maxAttempts: 3
    })
    const frames = [runtimeFabricFileProtocol, Buffer.from('STAT'), Buffer.from('transfer-1')]

    await fabric.sendFileFrame(frames)

    expect(transport.fileSendAttempts).toBe(3)
    expect(transport.sentFileFrames).toEqual([frames])
  })

  it('reports exhausted backpressure as a typed transport error', async () => {
    const transport = new TestRuntimeFabricTransport()
    transport.envelopeSendErrors.push(new Error('backpressure'), new Error('backpressure'), new Error('backpressure'))
    const fabric = createRuntimeFabricHost(transport, {
      initialDelayMs: 1,
      maxDelayMs: 1,
      maxAttempts: 3
    })

    const error = await fabric.sendEnvelope(testEnvelope()).catch(caught => caught)

    expect(error).toMatchObject({ code: 'backpressure' })
    expect(transport.envelopeSendAttempts).toBe(3)
  })

  it('classifies worker-file multipart without changing its frames', async () => {
    const transport = new TestRuntimeFabricTransport()
    const frames = [runtimeFabricFileProtocol, Buffer.from('STAT'), Buffer.from('transfer-1')]
    transport.receives.push(frames)
    const fabric = createRuntimeFabricHost(transport)

    expect(await fabric.receive(5)).toEqual({ kind: 'worker_file', frames })
  })

  it('rejects malformed raw receive shapes and native decode failures', async () => {
    const transport = new TestRuntimeFabricTransport()
    transport.receives.push(
      [],
      [Buffer.from('envelope-a'), Buffer.from('envelope-b')],
      [Buffer.from('not-protobuf')],
      new Error('timeout')
    )
    const fabric = createRuntimeFabricHost(transport)

    expect(await fabric.receive(5).catch(caught => caught)).toMatchObject({ code: 'invalid_frame' })
    expect(await fabric.receive(5).catch(caught => caught)).toMatchObject({ code: 'invalid_frame' })
    expect(await fabric.receive(5).catch(caught => caught)).toMatchObject({ code: 'decode_failed' })
    expect(await fabric.receive(5).catch(caught => caught)).toMatchObject({ code: 'timeout' })
  })
})

class TestRuntimeFabricTransport implements RuntimeFabricPhysicalTransport {
  readonly sentEnvelopes: Buffer[] = []
  readonly sentFileFrames: Buffer[][] = []
  readonly envelopeSendErrors: Error[] = []
  readonly fileSendErrors: Error[] = []
  readonly receives: Array<Buffer[] | null | Error> = []
  envelopeSendAttempts = 0
  fileSendAttempts = 0
  stopAttempts = 0

  sendEnvelope(envelope: Buffer): void {
    this.envelopeSendAttempts += 1
    const error = this.envelopeSendErrors.shift()
    if (error) throw error
    this.sentEnvelopes.push(envelope)
  }

  sendFileFrame(frames: Buffer[]): void {
    this.fileSendAttempts += 1
    const error = this.fileSendErrors.shift()
    if (error) throw error
    this.sentFileFrames.push(frames)
  }

  async recvRawAsync(_timeoutMs: number): Promise<Buffer[] | null> {
    const next = this.receives.shift() ?? null
    if (next instanceof Error) throw next
    return next
  }

  stop(): void {
    this.stopAttempts += 1
  }
}

function testEnvelope(): Envelope {
  return createEnvelope({
    ...envelopeHeader('worker-ready-test'),
    sentAtUnixMs: 0n,
    body: {
      case: 'workerReady',
      value: create(AgentComputerWorkerReadySchema, {
        workerId: 'worker-a',
        incarnationId: '11111111-1111-4111-8111-111111111111',
        runtime: 'bun',
        version: 'test',
        maxTurns: 1,
        availableTurnSlots: 1
      })
    }
  })
}
