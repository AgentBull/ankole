import { HostedTool } from '../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { create, fromBinary, toBinary, toJson as toJSON } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { FileTransferError } from '../src/lanes/file/errors'
import { pullFile, pushBundle, pushFile } from '../src/lanes/file/relay'
import {
  SignalEnvelopeSchema,
  EnvelopeSchema,
  MailboxUpdatedSchema,
  TurnStartSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import {
  createEnvelope,
  decodeEnvelope,
  encodeEnvelope,
  ProtocolVersion,
  envelopeHeader,
  jsonObjectFromBytes,
  RPCRequestSchema,
  RPCResponseSchema,
  type Envelope
} from '../src/fabric/envelope_proto'
import { RuntimeFabricTransportError } from '../src/fabric/fabric'
import { parseRuntimeFabricEndpoint } from '../src/worker/config'
import { Slots } from '../src/worker/lifecycle_messages'
import { handleWorkerRPCRequest } from '../src/lanes/rpc_lane'
import { controlShutdownEnvelope } from '../src/fabric/envelopes'
import { workerProgressEnvelope } from '../src/lanes/session_lane'
import type { WorkerConfig } from '../src/worker/config'
import { prepareTurnWorkspace } from '../src/worker/workspace'
import { jobTurnRefToProto, mailboxUpdatedFromEnvelope, turnStartFromEnvelope } from '../src/lanes/session_lane'
import type { TurnStart } from '../src/lanes/session_lane'
import { ActiveTurn, ActiveTurns, startTurnProgress } from '../src/worker/active_turns'
import { WorkerDrainState } from '../src/worker/drain'
import type { BrowserRuntime } from '../src/browser-runtime'
import {
  ActorTurnAbortResponseSchema,
  ActorTurnAbortRequestSchema,
  WorkerFileTransferRequestSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { turnFailureDetails } from '../src/worker/turn_failure'
import { BackgroundAgentJobTurnPersistenceError } from '../src/core/codex-runner/job/turn-recorder'
import { RPCRejectedError, RPCTimeoutError, RuntimeRPCClient } from '../src/lanes/rpc_lane'
import { agentHomePaths } from '../src/core/agent-home-paths'

// Writes the version that the sending host supplies on the wire.
function sealed(envelope: Envelope): Envelope {
  return decodeEnvelope(encodeEnvelope({ ...envelope, protocolVersion: ProtocolVersion.CURRENT }))
}

describe('@ankole/agent-computer runtime', () => {
  for (const reason of ['draining', 'capacity'] as const) {
    it(`returns from ${reason} rejection before the receive loop supplies its ACK`, async () => {
      const sent: Envelope[] = []
      const send = async (envelope: Envelope) => {
        sent.push(envelope)
      }
      const rpc = new RuntimeRPCClient(send)
      const drain = new WorkerDrainState()
      if (reason === 'draining') drain.begin('sigterm')
      const active = new ActiveTurns(
        { ...workerConfig(), maxConcurrentSlots: 0 },
        {} as BrowserRuntime,
        send,
        rpc,
        drain,
        new Slots({ ...workerConfig(), maxConcurrentSlots: 0 }, drain, send)
      )
      const envelope = createEnvelope({
        ...envelopeHeader('turn-start-rejected'),
        body: {
          case: 'turnStart',
          value: create(TurnStartSchema, {
            mode: 'start',
            fetchRuntimeConfig: { ssrfFilter: true },
            turn: jobTurnRefToProto(jobTurnRef()),
            signal: create(SignalEnvelopeSchema, {
              signalId: jobTurnRef().signal_id,
              type: 'im.message.addressed'
            })
          })
        }
      })
      await active.start(envelope)
      expect(active.size).toBe(0)
      expect(drain.activeTaskCount).toBe(1)
      const request = sent[0]!.body
      if (request.case !== 'rpcRequest') throw new Error('expected abort RPC')
      rpc.resolve(
        create(RPCResponseSchema, {
          requestId: request.value.requestId,
          payload: toBinary(ActorTurnAbortResponseSchema, create(ActorTurnAbortResponseSchema))
        })
      )
      await Bun.sleep(0)
      expect(drain.activeTaskCount).toBe(0)
    })
  }

  it('parses a credential-free Worker Channel endpoint', () => {
    expect(parseRuntimeFabricEndpoint('ws://127.0.0.1:4000/runtime-fabric/worker/')).toBe(
      'ws://127.0.0.1:4000/runtime-fabric/worker'
    )
    expect(parseRuntimeFabricEndpoint('wss://ankole.example.com/runtime-fabric/worker')).toBe(
      'wss://ankole.example.com/runtime-fabric/worker'
    )
    expect(() => parseRuntimeFabricEndpoint('ws://:secret@127.0.0.1:4000/runtime-fabric/worker')).toThrow(/credentials/)
    expect(() => parseRuntimeFabricEndpoint('ws://127.0.0.1:4000')).toThrow(/path/)
    expect(() => parseRuntimeFabricEndpoint('ws://127.0.0.1:4000/runtime-fabric/worker?token=x')).toThrow(/path/)
    expect(() => parseRuntimeFabricEndpoint('tcp://127.0.0.1:6010')).toThrow(/ws:\/\/host:port\/path/)
    expect(() => parseRuntimeFabricEndpoint('http://127.0.0.1:4000/x')).toThrow(/ws:\/\/host:port\/path/)
  })

  it('includes an occupied workspace slot in a Job capacity rejection', async () => {
    const sent: Envelope[] = []
    const send = async (envelope: Envelope) => {
      sent.push(envelope)
    }
    const rpc = new RuntimeRPCClient(send)
    const config = { ...workerConfig(), maxConcurrentSlots: 1 }
    const drain = new WorkerDrainState()
    const slots = new Slots(config, drain, send)
    expect(slots.reserve()).toBe(true)
    const active = new ActiveTurns(config, {} as BrowserRuntime, send, rpc, drain, slots)
    await active.start(
      createEnvelope({
        ...envelopeHeader('occupied-workspace'),
        body: {
          case: 'turnStart',
          value: create(TurnStartSchema, {
            mode: 'start',
            fetchRuntimeConfig: { ssrfFilter: true },
            turn: jobTurnRefToProto(jobTurnRef()),
            signal: create(SignalEnvelopeSchema, {
              signalId: jobTurnRef().signal_id,
              type: 'im.message.addressed'
            })
          })
        }
      })
    )
    expect(active.size).toBe(0)
    expect(slots.used()).toBe(1)
    const request = sent[0]!.body
    if (request.case !== 'rpcRequest') throw new Error('expected abort RPC')
    const abort = fromBinary(ActorTurnAbortRequestSchema, request.value.payload)
    expect(abort.code).toBe('worker_busy')
    expect(jsonObjectFromBytes(abort.detailsJson, 'busy details')).toMatchObject({
      retryable: true,
      active_slots: 1,
      max_slots: 1
    })
    rpc.resolve(
      create(RPCResponseSchema, {
        requestId: request.value.requestId,
        payload: toBinary(ActorTurnAbortResponseSchema, create(ActorTurnAbortResponseSchema))
      })
    )
    await Bun.sleep(0)
    expect(drain.activeTaskCount).toBe(0)
  })

  it('reserves one shared slot and releases it for the next owner', () => {
    const slots = new Slots({ ...workerConfig(), maxConcurrentSlots: 1 }, new WorkerDrainState(), async () => {})
    expect(slots.available()).toBe(1)
    expect(slots.reserve()).toBe(true)
    expect(slots.used()).toBe(1)
    expect(slots.available()).toBe(0)
    expect(slots.reserve()).toBe(false)
    slots.release()
    expect(slots.available()).toBe(1)
    expect(slots.reserve()).toBe(true)
  })

  it('reports liveness, load, and capacity in one heartbeat', () => {
    const drain = new WorkerDrainState()
    for (let i = 0; i < 4; i++) drain.track(new Promise<void>(() => {}))
    const slots = new Slots({ ...workerConfig(), maxConcurrentSlots: 3 }, drain, async () => {})
    slots.reserve()
    slots.reserve()
    const heartbeat = sealed(slots.heartbeat())
    expect(heartbeat.protocolVersion).toBe(ProtocolVersion.CURRENT)
    if (heartbeat.body.case !== 'workerHeartbeat') throw new Error('expected heartbeat')
    expect(heartbeat.body.value).toMatchObject({
      incarnationId: 'incarnation-a',
      maxSlots: 3,
      activeSlots: 2,
      availableSlots: 1,
      activeTasks: 4,
      idleForMs: 0n
    })
    const wire = toJSON(EnvelopeSchema, heartbeat)
    expect(wire).not.toHaveProperty('workerId')
  })

  it('classifies exhausted BackgroundAgentJob Turn persistence as retryable worker infrastructure failure', () => {
    const failure = new BackgroundAgentJobTurnPersistenceError(
      new RPCRejectedError('checkpoint rejected', {
        code: 'rpc_handler_failed',
        retryable: true,
        details: { failure_id: 'failure-1' }
      })
    )
    const details = turnFailureDetails(failure)

    expect(details).toEqual({
      runtime: 'bun',
      error_code: 'background_agent_job_turn_persistence_failed',
      retryable: true
    })
  })

  it('retries a lost control-plane connection and fails an unexpected error loudly', () => {
    expect(turnFailureDetails(new RuntimeFabricTransportError('socket_closed', 'closed'))).toMatchObject({
      retryable: true
    })
    expect(turnFailureDetails(new RuntimeFabricTransportError('rejected', 'rejected'))).toMatchObject({
      retryable: false
    })
    expect(turnFailureDetails(new RuntimeFabricTransportError('timeout', 'push timeout'))).toMatchObject({
      error_code: 'runtime_fabric_timeout',
      retryable: true
    })
    expect(turnFailureDetails(new RPCTimeoutError('worker_env.resolve'))).toMatchObject({
      error_code: 'runtime_rpc_timeout',
      retryable: true
    })
    expect(turnFailureDetails(new Error('ECONNRESET while reading'))).toEqual({
      runtime: 'bun',
      retryable: false
    })
  })

  it('preserves the credential-pool recovery deadline in turn-error details', () => {
    const details = turnFailureDetails({
      code: 'credential_pool_exhausted',
      retryable: true,
      status: 429,
      retryAt: '2026-07-29T08:15:00.000Z',
      details: { retry_at: '2026-07-29T08:15:00.000Z' }
    })

    expect(details).toEqual({
      runtime: 'bun',
      error_code: 'credential_pool_exhausted',
      retryable: true,
      retry_at: '2026-07-29T08:15:00.000Z'
    })
  })

  it('marks an Agent token quota rejection non-retryable in turn-error details', () => {
    const details = turnFailureDetails({
      code: 'agent_token_quota_exceeded',
      retryable: false,
      status: 429
    })

    expect(details).toEqual({
      runtime: 'bun',
      error_code: 'agent_token_quota_exceeded',
      retryable: false
    })
  })

  it('keeps an accepted Job attempt alive with only its fence', () => {
    const envelope = sealed(workerProgressEnvelope(jobTurnRef()))
    if (envelope.body.case !== 'workerProgress') throw new Error('expected workerProgress')
    expect(envelope.body.value.turn).toMatchObject({
      jobId: 1000n,
      attempt: 1,
      signalId: jobTurnRef().signal_id
    })
  })

  it('reports process drain as ephemeral control traffic', () => {
    const envelope = controlShutdownEnvelope('sigterm')

    if (envelope.body.case !== 'controlShutdown') throw new Error('expected controlShutdown body')
    expect(envelope.body.value.reason).toBe('sigterm')
  })

  it('renews a silent BackgroundAgentJob Turn independently of Codex notifications', async () => {
    const sent: unknown[] = []
    const active = new ActiveTurn({ turn: jobTurnRef() } as unknown as TurnStart)
    const reporter = startTurnProgress(
      async envelope => {
        sent.push(envelope)
      },
      active,
      { intervalMs: 5 }
    )

    await Bun.sleep(18)
    expect(sent.length).toBeGreaterThanOrEqual(3)
    reporter.stop()
    const stoppedAt = sent.length
    await Bun.sleep(12)
    expect(sent).toHaveLength(stoppedAt)
  })

  for (const reason of ['background_agent_job_attempt_changed', 'run_closed']) {
    it(`stops an invalid attempt after progress is rejected with ${reason}`, async () => {
      const active = new ActiveTurn({ turn: jobTurnRef() } as unknown as TurnStart)
      let sends = 0
      const reporter = startTurnProgress(
        async () => {
          sends += 1
          throw new RuntimeFabricTransportError('rejected', reason, { reason })
        },
        active,
        { intervalMs: 5 }
      )

      try {
        await Bun.sleep(18)
        expect(active.abortSignal.aborted).toBe(true)
        expect(active.controlledStopReason).toBe(reason)
        expect(sends).toBe(1)
      } finally {
        reporter.stop()
      }
    })
  }

  for (const failure of [
    new RuntimeFabricTransportError('socket_closed', 'closed'),
    new RuntimeFabricTransportError('timeout', 'no ACK'),
    new RuntimeFabricTransportError('rejected', 'wrong_stream', { reason: 'wrong_stream' })
  ]) {
    it(`retains execution after an inconclusive progress failure: ${failure.message}`, async () => {
      const active = new ActiveTurn({ turn: jobTurnRef() } as unknown as TurnStart)
      let sends = 0
      const reporter = startTurnProgress(
        async () => {
          sends += 1
          if (sends === 1) throw failure
        },
        active,
        { intervalMs: 5 }
      )

      try {
        await Bun.sleep(18)
        expect(active.abortSignal.aborted).toBe(false)
        expect(sends).toBeGreaterThan(1)
      } finally {
        reporter.stop()
      }
    })
  }

  it('keeps a replacement running when an old in-flight progress request is rejected late', async () => {
    const previous = new ActiveTurn({ turn: jobTurnRef() } as unknown as TurnStart)
    const replacement = new ActiveTurn({ turn: { ...jobTurnRef(), attempt: 2 } } as unknown as TurnStart)
    let rejectPrevious!: (error: Error) => void
    const pending = new Promise<void>((_resolve, reject) => {
      rejectPrevious = reject
    })
    const oldReporter = startTurnProgress(async () => pending, previous, { intervalMs: 5 })
    const newReporter = startTurnProgress(async () => {}, replacement, { intervalMs: 5 })

    try {
      previous.requestControlledStop('retry', 'background_agent_job_attempt_changed')
      rejectPrevious(new RuntimeFabricTransportError('rejected', 'run_closed', { reason: 'run_closed' }))
      await Bun.sleep(12)
      expect(previous.controlledStopReason).toBe('background_agent_job_attempt_changed')
      expect(replacement.abortSignal.aborted).toBe(false)
    } finally {
      oldReporter.stop()
      newReporter.stop()
    }
  })

  it('queues a steer update until Codex polls it', () => {
    const turn = jobTurnRef()
    const active = new ActiveTurn({ turn } as unknown as TurnStart)

    active.pushSteering({
      signal: {
        signal_id: '00000000-0000-0000-0000-000000000102',
        type: 'command.steer'
      }
    })

    expect(active.pollSteering()).toHaveLength(1)
  })

  it('prepares the Job directory without allocating a Session workspace', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-workspace-'))
    try {
      const config = workerConfigForRoot(root)
      const workspaceRoot = prepareTurnWorkspace(config)

      expect(workspaceRoot).toBe(join(config.agentHomeRoot, 'jobs'))
      expect(existsSync(join(config.agentHomeRoot, 'sessions', '10000'))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects mailbox updates without the journaled actor event', () => {
    expect(() =>
      mailboxUpdatedFromEnvelope(
        createEnvelope({
          ...envelopeHeader('mailbox-updated-missing-event'),
          body: {
            case: 'mailboxUpdated',
            value: create(MailboxUpdatedSchema, {
              turn: jobTurnRefToProto(jobTurnRef())
            })
          }
        })
      )
    ).toThrow(/mailbox_updated\.signal is required/)
  })

  it('rejects turn_start envelopes without a durable turn fence', () => {
    expect(() =>
      turnStartFromEnvelope(
        createEnvelope({
          ...envelopeHeader('turn-start-missing-turn'),
          body: {
            case: 'turnStart',
            value: create(TurnStartSchema, {
              mode: 'start',
              fetchRuntimeConfig: { ssrfFilter: true },
              signal: create(SignalEnvelopeSchema, {
                signalId: '00000000-0000-0000-0000-000000000001',
                type: 'im.message.addressed'
              })
            })
          }
        })
      )
    ).toThrow(/turn_start\.turn is required/)
  })

  it('decodes turn runtime environment values from turn_start', () => {
    const turnStart = turnStartFromEnvelope(
      createEnvelope({
        ...envelopeHeader('turn-start-runtime-env'),
        body: {
          case: 'turnStart',
          value: create(TurnStartSchema, {
            mode: 'start',
            fetchRuntimeConfig: { ssrfFilter: true },
            turn: jobTurnRefToProto(jobTurnRef()),
            signal: create(SignalEnvelopeSchema, {
              signalId: '00000000-0000-0000-0000-000000000001',
              type: 'im.message.addressed'
            }),
            runtimeEnv: { ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL: 'human-alice' }
          })
        }
      })
    )

    expect(turnStart.runtime_env).toEqual({
      ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL: 'human-alice'
    })
  })

  it('projects the generated hosted-tool enum on turn_start', () => {
    const hostedToolsEnvelope = (hostedTools: HostedTool[]): Envelope =>
      createEnvelope({
        ...envelopeHeader('turn-start-hosted-tools'),
        body: {
          case: 'turnStart',
          value: create(TurnStartSchema, {
            mode: 'start',
            fetchRuntimeConfig: { ssrfFilter: true },
            turn: jobTurnRefToProto(jobTurnRef()),
            signal: create(SignalEnvelopeSchema, {
              signalId: '00000000-0000-0000-0000-000000000001',
              type: 'im.message.addressed'
            }),
            hostedTools
          })
        }
      })

    expect(
      turnStartFromEnvelope(hostedToolsEnvelope([HostedTool.IMAGE_GENERATION, HostedTool.WEB_SEARCH])).hosted_tools
    ).toEqual([HostedTool.IMAGE_GENERATION, HostedTool.WEB_SEARCH])
  })

  it('rejects unknown control-plane-initiated worker RPC requests', async () => {
    const sent: Envelope[] = []
    const request = create(RPCRequestSchema, {
      requestId: 'worker-rpc-1',
      method: 'test.probe'
    })

    await handleWorkerRPCRequest(async envelope => {
      sent.push(envelope)
    }, request)

    expect(sent).toHaveLength(1)
    const body = sent[0]!.body
    if (body.case !== 'rpcError') throw new Error('expected rpcError body')
    expect(body.value).toMatchObject({
      requestId: 'worker-rpc-1',
      code: 'unknown_rpc_method'
    })
    expect(jsonObjectFromBytes(body.value.detailsJson, 'details_json')).toEqual({ method: 'test.probe' })
  })

  it('returns RPC errors for unknown worker methods', async () => {
    const sent: Envelope[] = []

    await handleWorkerRPCRequest(
      async envelope => {
        sent.push(envelope)
      },
      create(RPCRequestSchema, {
        requestId: 'worker-rpc-unknown',
        method: 'worker.unknown'
      })
    )

    expect(sent).toHaveLength(1)
    const body = sent[0]!.body
    if (body.case !== 'rpcError') throw new Error('expected rpcError body')
    expect(body.value).toMatchObject({
      requestId: 'worker-rpc-unknown',
      code: 'unknown_rpc_method'
    })
    expect(jsonObjectFromBytes(body.value.detailsJson, 'details_json')).toEqual({ method: 'worker.unknown' })
  })

  it('pulls a relay upload into the Agent Home through an atomic rename', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-relay-pull-'))
    const config = workerConfigForRoot(root)
    const plainText = 'hello relay world'
    const relay = relayStub({ body: plainText })

    try {
      const paths = agentHomePaths(config.agentHomeRoot)
      mkdirSync(join(paths.home, 'files'), { recursive: true })

      const result = await pullFile(config, {
        ...transferRequest(relay, 'transfer-1', 'files/inbox/lark/message-1/hello.txt'),
        maxBytes: 1024n
      })

      expect(readFileSync(join(join(paths.home, 'files'), 'inbox/lark/message-1/hello.txt'), 'utf8')).toBe(plainText)
      expect(result).toEqual({ size: Buffer.byteLength(plainText) })
      expect(relay.requests).toEqual([{ method: 'GET', path: '/relay/transfer-1' }])
      expect(existsSync('/tmp/ankole-file-transfer/transfer-1')).toBe(false)

      // A Worker serves one Agent: a path that leaves its Agent Home is refused.
      const otherAgent = await pullFile(config, {
        ...transferRequest(relay, 'transfer-other-agent', '../agent-2/files/hello.txt'),
        maxBytes: 1024n
      }).catch(caught => caught)
      expect(otherAgent).toBeInstanceOf(Error)
      expect(otherAgent.message).toContain('invalid home_relative_path')
    } finally {
      relay.stop()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('cancels a slow relay body before atomic publication and removes its scratch bytes', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-relay-cancel-'))
    const config = workerConfigForRoot(root)
    let stream!: ReadableStreamDefaultController<Uint8Array>
    const relay = Bun.serve({
      port: 0,
      fetch: () =>
        new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              stream = controller
              controller.enqueue(new TextEncoder().encode('partial bytes'))
            }
          })
        )
    })
    const target = join(agentHomePaths(config.agentHomeRoot).home, 'kept.txt')
    mkdirSync(agentHomePaths(config.agentHomeRoot).home, { recursive: true })
    writeFileSync(target, 'original complete file')
    try {
      const signal = AbortSignal.timeout(50)
      await expect(
        pullFile(
          config,
          {
            transferId: 'cancelled-transfer',
            url: `http://127.0.0.1:${relay.port}/slow`,
            homeRelativePath: 'kept.txt',
            maxBytes: 1024n
          },
          signal
        )
      ).rejects.toBeInstanceOf(Error)
      expect(signal.aborted).toBe(true)
      expect(readFileSync(target, 'utf8')).toBe('original complete file')
      expect(existsSync('/tmp/ankole-file-transfer/cancelled-transfer')).toBe(false)
      try {
        stream.enqueue(new TextEncoder().encode('late remainder'))
        stream.close()
      } catch {}
      await Bun.sleep(10)
      expect(readFileSync(target, 'utf8')).toBe('original complete file')
    } finally {
      relay.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects an oversize or failed relay pull without leaving a partial file', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-relay-pull-bounds-'))
    const config = workerConfigForRoot(root)
    const relay = relayStub({ body: 'x'.repeat(64), status: 200 })

    try {
      const paths = agentHomePaths(config.agentHomeRoot)
      mkdirSync(join(paths.home, 'files'), { recursive: true })
      const request = transferRequest(relay, 'transfer-big', 'files/big.txt')

      const oversize = await pullFile(config, { ...request, maxBytes: 16n }).catch(caught => caught)
      expect(oversize).toBeInstanceOf(FileTransferError)
      expect(oversize.code).toBe('file_too_large')
      expect(existsSync(join(join(paths.home, 'files'), 'big.txt'))).toBe(false)
      expect(existsSync('/tmp/ankole-file-transfer/transfer-big')).toBe(false)

      relay.status = 410
      const failed = await pullFile(config, { ...request, maxBytes: 1024n }).catch(caught => caught)
      expect(failed.code).toBe('relay_failed')
      expect(failed.message).not.toContain('token')
      expect(existsSync(join(join(paths.home, 'files'), 'big.txt'))).toBe(false)

      const badTransfer = await pullFile(config, {
        ...request,
        transferId: '../bad-transfer',
        maxBytes: 1024n
      }).catch(caught => caught)
      expect(badTransfer.message).toMatch(/invalid transfer_id/)
    } finally {
      relay.stop()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('pushes a worker file to the relay and reports file identity errors', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-relay-push-'))
    const config = workerConfigForRoot(root)
    const relay = relayStub({})

    try {
      const paths = agentHomePaths(config.agentHomeRoot)
      mkdirSync(join(join(paths.home, 'files'), 'inbox'), { recursive: true })
      writeFileSync(join(join(paths.home, 'files'), 'inbox/hello.txt'), 'hello world')

      const result = await pushFile(config, {
        ...transferRequest(relay, 'push-1', 'files/inbox/hello.txt'),
        maxBytes: 1024n
      })
      expect(result).toEqual({ size: 11 })
      expect(relay.requests).toEqual([{ method: 'PUT', path: '/relay/push-1' }])
      expect(relay.received.get('/relay/push-1')?.toString('utf8')).toBe('hello world')
      expect(relay.receivedHeaders.get('/relay/push-1')?.get('content-length')).toBe('11')

      const tooLarge = await pushFile(config, {
        ...transferRequest(relay, 'push-large', 'files/inbox/hello.txt'),
        maxBytes: 4n
      }).catch(caught => caught)
      expect(tooLarge.code).toBe('file_too_large')
      expect(relay.requests).toHaveLength(1)

      const missing = await pushFile(config, {
        ...transferRequest(relay, 'push-missing', 'files/inbox/missing.txt'),
        maxBytes: 1024n
      }).catch(caught => caught)
      expect(missing.code).toBe('file_not_found')

      const directory = await pushFile(config, {
        ...transferRequest(relay, 'push-directory', 'files/inbox'),
        maxBytes: 1024n
      }).catch(caught => caught)
      expect(directory.code).toBe('not_regular_file')

      relay.status = 500
      const rejected = await pushFile(config, {
        ...transferRequest(relay, 'push-rejected', 'files/inbox/hello.txt'),
        maxBytes: 1024n
      }).catch(caught => caught)
      expect(rejected.code).toBe('relay_failed')
      relay.status = 200

      // The relay stub swaps the file while the PUT is in flight. The
      // replacement keeps the size and mtime, so only the inode check can
      // tell the control plane that the bytes it holds belong to another file.
      const swappedPath = join(join(paths.home, 'files'), 'inbox/swapped.txt')
      const replacementPath = join(join(paths.home, 'files'), 'inbox/replacement.txt')
      const sharedMtime = new Date(1_700_000_000_000)
      writeFileSync(swappedPath, 'original bytes')
      utimesSync(swappedPath, sharedMtime, sharedMtime)
      relay.onRequest = () => {
        writeFileSync(replacementPath, 'replaced bytes')
        utimesSync(replacementPath, sharedMtime, sharedMtime)
        renameSync(replacementPath, swappedPath)
      }
      const swapped = await pushFile(config, {
        ...transferRequest(relay, 'push-swapped', 'files/inbox/swapped.txt'),
        maxBytes: 1024n
      }).catch(caught => caught)
      expect(swapped.code).toBe('file_changed')
    } finally {
      relay.stop()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('pushes several worker files as one bundle in request order', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-relay-bundle-'))
    const config = workerConfigForRoot(root)
    const relay = relayStub({})
    const entry = (path: string, content: string) => {
      const name = Buffer.from(path)
      const header = Buffer.alloc(12 + name.byteLength)
      header.writeUInt32BE(name.byteLength, 0)
      name.copy(header, 4)
      header.writeBigUInt64BE(BigInt(Buffer.byteLength(content)), 4 + name.byteLength)
      return Buffer.concat([header, Buffer.from(content)])
    }

    try {
      const home = agentHomePaths(config.agentHomeRoot).home
      mkdirSync(join(home, 'jobs', '7', 'sub'), { recursive: true })
      writeFileSync(join(home, 'jobs', '7', 'a.txt'), 'alpha')
      writeFileSync(join(home, 'jobs', '7', 'sub', 'empty.txt'), '')
      const expected = Buffer.concat([entry('7/a.txt', 'alpha'), entry('7/sub/empty.txt', '')])

      const result = await pushBundle(config, {
        ...transferRequest(relay, 'bundle-1', 'jobs'),
        bundlePaths: ['7/a.txt', '7/sub/empty.txt']
      })
      expect(result).toEqual({ size: expected.length })
      expect(relay.received.get('/relay/bundle-1')).toEqual(expected)
      expect(relay.receivedHeaders.get('/relay/bundle-1')?.get('content-length')).toBe(String(expected.length))

      const tooLarge = await pushBundle(config, {
        ...transferRequest(relay, 'bundle-large', 'jobs'),
        bundlePaths: ['7/a.txt', '7/sub/empty.txt'],
        maxBytes: BigInt(expected.length - 1)
      }).catch(caught => caught)
      expect(tooLarge.code).toBe('file_too_large')

      const escaping = await pushBundle(config, {
        ...transferRequest(relay, 'bundle-escape', 'jobs'),
        bundlePaths: ['7/../../../outside.txt']
      }).catch(caught => caught)
      expect(escaping).toBeInstanceOf(Error)
      expect(relay.requests).toEqual([{ method: 'PUT', path: '/relay/bundle-1' }])
    } finally {
      relay.stop()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects unsafe file lane paths and escaping symlinks', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-paths-'))
    const config = workerConfigForRoot(root)

    try {
      const notesRoot = join(agentHomePaths(config.agentHomeRoot).home, 'notes')
      mkdirSync(notesRoot, { recursive: true })
      const outsidePath = join(root, 'outside.txt')
      writeFileSync(outsidePath, 'secret')
      symlinkSync(outsidePath, join(notesRoot, 'escaped.txt'))

      const relay = relayStub({ body: '' })
      const pushFor = (homeRelativePath: string) =>
        pushFile(config, transferRequest(relay, 'push-unsafe', homeRelativePath)).catch(
          (caught: Error) => caught.message
        )

      expect(await pushFor('/tmp/escape.txt')).toMatch(/home_relative_path must not be absolute/)
      expect(await pushFor('../escape.txt')).toMatch(/invalid home_relative_path/)
      expect(await pushFor('notes/escaped.txt')).toMatch(/path resolves outside the Agent Home/)
      expect(await pushFor('notes')).toMatch(/not a regular file: notes/)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function workerConfig(): WorkerConfig {
  return {
    endpoint: 'ws://127.0.0.1:4000/runtime-fabric/worker',
    workerAuthKey: 'secret',
    workerID: 'agent-1',
    incarnationID: 'incarnation-a',
    agentHomeRoot: '/workspace',
    builtinSkillsRoot: '/repo/app/library',
    browser: { daemonEntry: '/bin/true', runnerPath: '/bin/true', localChromiumExecutable: '/bin/true' },
    maxConcurrentSlots: 9
  }
}

function jobTurnRef() {
  return {
    session: {
      agent_uid: 'agent-1',
      session_id: 'job:1000'
    },
    job_id: 1000,
    attempt: 1,
    signal_id: '00000000-0000-0000-0000-000000000101'
  }
}

function workerConfigForRoot(root: string): WorkerConfig {
  return {
    endpoint: 'ws://127.0.0.1:4000/runtime-fabric/worker',
    workerAuthKey: 'secret',
    workerID: 'agent-1',
    incarnationID: 'incarnation-a',
    agentHomeRoot: join(root, 'workspace'),
    builtinSkillsRoot: join(root, 'builtin-skills'),
    browser: { daemonEntry: '/bin/true', runnerPath: '/bin/true', localChromiumExecutable: '/bin/true' },
    maxConcurrentSlots: 9
  }
}

type RelayStub = {
  url: string
  status: number
  requests: Array<{ method: string; path: string }>
  received: Map<string, Buffer>
  receivedHeaders: Map<string, Headers>
  onRequest?: () => void
  stop(): void
}

/**
 * Stands in for the control-plane relay endpoint: GET serves `body`, PUT
 * captures the request body. Both answer with `status`.
 */
function relayStub(options: { body?: string; status?: number }): RelayStub {
  const stub: RelayStub = {
    url: '',
    status: options.status ?? 200,
    requests: [],
    received: new Map(),
    receivedHeaders: new Map(),
    stop: () => undefined
  }
  const server = Bun.serve({
    port: 0,
    hostname: '127.0.0.1',
    async fetch(request) {
      const path = new URL(request.url).pathname
      stub.requests.push({ method: request.method, path })
      stub.onRequest?.()
      if (request.method === 'PUT') {
        stub.received.set(path, Buffer.from(await request.arrayBuffer()))
        stub.receivedHeaders.set(path, request.headers)
        return new Response(null, { status: stub.status })
      }
      return new Response(options.body ?? '', {
        status: stub.status,
        headers: { 'content-type': 'application/octet-stream' }
      })
    }
  })
  stub.url = `http://127.0.0.1:${server.port}`
  stub.stop = () => server.stop(true)
  return stub
}

function transferRequest(relay: RelayStub, transferID: string, homeRelativePath: string) {
  return create(WorkerFileTransferRequestSchema, {
    transferId: transferID,
    url: `${relay.url}/relay/${transferID}?token=secret-token`,
    homeRelativePath,
    maxBytes: 1024n,
    expiresAt: '2099-01-01T00:00:00Z'
  })
}
