import { create, toBinary, toJson as toJSON } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync
} from 'node:fs'
import { runtimeFabricSealEnvelope } from '@ankole/kernel'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  createFileLaneState,
  FileTransferError,
  handleWorkerFileDelete,
  handleWorkerFileList,
  handleWorkerFileMove,
  handleWorkerFilePull,
  handleWorkerFilePush
} from '../src/lanes/file'
import {
  ActorEventEnvelopeSchema,
  createEnvelope,
  decodeEnvelope,
  DurabilityClass,
  encodeEnvelope,
  envelopeHeader,
  EnvelopeSchema,
  jsonBytes,
  jsonObjectFromBytes,
  Lane,
  MailboxUpdatedSchema,
  RPCRequestSchema,
  RPCResponseSchema,
  TurnStartSchema,
  type Envelope
} from '../src/fabric/envelope_proto'
import { parseRuntimeFabricEndpoint } from '../src/worker/config'
import { workerCapacityEnvelope, workerHeartbeatEnvelope, workerReadyEnvelope } from '../src/worker/lifecycle_messages'
import { handleWorkerRPCRequest } from '../src/lanes/rpc_lane'
import { controlShutdownEnvelope, workerProgressEnvelope } from '../src/fabric/envelopes'
import type { WorkerConfig } from '../src/worker/config'
import { prepareActorWorkspace, prepareTurnWorkspace } from '../src/worker/workspace'
import { actorTurnRefToProto, mailboxUpdatedFromEnvelope, turnStartFromEnvelope } from '../src/lanes/actor_lane'
import type { TurnStart } from '../src/lanes/actor_lane'
import { ActiveTurn, ActiveTurns, startTurnProgress } from '../src/worker/active_turns'
import { WorkerDrainState } from '../src/worker/drain'
import type { BrowserRuntime } from '../src/browser-runtime'
import {
  ActorTurnAbortResponseSchema,
  WorkerFileTransferRequestSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { turnFailureDetails } from '../src/worker/turn_failure'
import { BackgroundAgentJobTurnPersistenceError } from '../src/core/codex-runner/job/turn-recorder'
import { RPCRejectedError, RuntimeRPCClient } from '../src/lanes/rpc_lane'
import { agentHomePaths } from '../src/core/agent-home-paths'

// Runs the same seal the dealer send path applies, so assertions read the
// header the control plane receives, not the partial header the host built.
function sealed(envelope: Envelope): Envelope {
  return decodeEnvelope(runtimeFabricSealEnvelope(encodeEnvelope(envelope)))
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
        { ...workerConfig(), maxConcurrentTurns: 0 },
        {} as BrowserRuntime,
        send,
        rpc,
        drain
      )
      const envelope = createEnvelope({
        ...envelopeHeader('turn-start-rejected'),
        body: {
          case: 'turnStart',
          value: create(TurnStartSchema, {
            workspaceId: 10_000n,
            turn: actorTurnRefToProto(actorTurnRef()),
            actorEvent: create(ActorEventEnvelopeSchema, {
              actorEventId: actorTurnRef().actor_event_id,
              queueSequence: 1n,
              type: 'im.message.addressed',
              sourceEventId: 'source-1'
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

  it('parses a credential-free RuntimeFabric endpoint and selects the transport', () => {
    expect(parseRuntimeFabricEndpoint('ws://127.0.0.1:4000/runtime-fabric/worker/')).toEqual({
      transport: 'channel',
      endpoint: 'ws://127.0.0.1:4000/runtime-fabric/worker'
    })
    expect(parseRuntimeFabricEndpoint('wss://ankole.example.com/runtime-fabric/worker')).toEqual({
      transport: 'channel',
      endpoint: 'wss://ankole.example.com/runtime-fabric/worker'
    })
    expect(parseRuntimeFabricEndpoint('tcp://127.0.0.1:6010')).toEqual({
      transport: 'zmq',
      endpoint: 'tcp://127.0.0.1:6010'
    })
    expect(() => parseRuntimeFabricEndpoint('ws://:secret@127.0.0.1:4000/runtime-fabric/worker')).toThrow(/credentials/)
    expect(() => parseRuntimeFabricEndpoint('ws://127.0.0.1:4000')).toThrow(/path/)
    expect(() => parseRuntimeFabricEndpoint('ws://127.0.0.1:4000/runtime-fabric/worker?token=x')).toThrow(/path/)
    expect(() => parseRuntimeFabricEndpoint('tcp://127.0.0.1:6010/path')).toThrow(/tcp:\/\/host:port/)
    expect(() => parseRuntimeFabricEndpoint('tcp://127.0.0.1')).toThrow(/tcp:\/\/host:port/)
    expect(() => parseRuntimeFabricEndpoint('http://127.0.0.1:4000/x')).toThrow(/tcp:\/\/host:port, ws/)
  })

  it('emits worker.ready without actor authority fields', () => {
    const config = workerConfig()
    const ready = workerReadyEnvelope(config)
    const heartbeat = workerHeartbeatEnvelope(config, 123)
    const capacity = workerCapacityEnvelope(config)

    expect(ready.body.case).toBe('workerReady')
    expect(heartbeat.body.case).toBe('workerHeartbeat')
    expect(capacity.body.case).toBe('workerCapacity')
    expect(ready.body.value).toMatchObject({ incarnationId: 'incarnation-a' })
    expect(heartbeat.body.value).toMatchObject({ incarnationId: 'incarnation-a' })
    expect(capacity.body.value).toMatchObject({ incarnationId: 'incarnation-a' })
    const readyJSON = JSON.stringify(toJSON(EnvelopeSchema, ready))
    expect(readyJSON).not.toContain('agentUid')
    expect(readyJSON).not.toContain('actorEpoch')
    if (ready.body.case !== 'workerReady') throw new Error('expected workerReady body')
    expect(ready.body.value.maxTurns).toBe(9)
    expect(ready.body.value.availableTurnSlots).toBe(9)
    if (heartbeat.body.case !== 'workerHeartbeat') throw new Error('expected workerHeartbeat body')
    expect(heartbeat.body.value).toMatchObject({
      activeTurns: 0,
      availableTurnSlots: 9,
      maxTurns: 9,
      runtime: 'bun',
      version: '0.1.0'
    })
    if (capacity.body.case !== 'workerCapacity') throw new Error('expected workerCapacity body')
    expect(capacity.body.value.maxTurns).toBe(9)
    expect(capacity.body.value.activeTurns).toBe(0)
    expect(capacity.body.value.availableTurnSlots).toBe(9)
    expect(sealed(ready).lane).toBe(Lane.CONTROL)
    expect(sealed(heartbeat).durability).toBe(DurabilityClass.CONTROL_EPHEMERAL)
    expect(sealed(capacity).lane).toBe(Lane.CONTROL)
  })

  it('reports available capacity from configured concurrent turn slots', () => {
    const config = { ...workerConfig(), maxConcurrentTurns: 3 }
    const capacity = workerCapacityEnvelope(config, 1, 2)

    if (capacity.body.case !== 'workerCapacity') throw new Error('expected workerCapacity body')
    expect(capacity.body.value.maxTurns).toBe(3)
    expect(capacity.body.value.activeTurns).toBe(2)
    expect(capacity.body.value.availableTurnSlots).toBe(1)
  })

  it('classifies exhausted BackgroundAgentJob Turn persistence as retryable worker infrastructure failure', () => {
    const failure = new BackgroundAgentJobTurnPersistenceError(
      new RPCRejectedError('checkpoint rejected', {
        code: 'rpc_handler_failed',
        details: { failure_id: 'failure-1', retryable: true }
      })
    )
    const details = turnFailureDetails(failure)

    expect(details).toMatchObject({
      error_code: 'background_agent_job_turn_persistence_failed',
      retryable: true,
      aigateway: {
        code: 'background_agent_job_turn_persistence_failed',
        details_json: {
          retryable: true,
          rpc_code: 'rpc_handler_failed',
          rpc_details: { failure_id: 'failure-1', retryable: true }
        }
      }
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

    expect(details).toMatchObject({
      error_code: 'credential_pool_exhausted',
      retryable: true,
      retry_at: '2026-07-29T08:15:00.000Z',
      aigateway: {
        code: 'credential_pool_exhausted',
        status: 429,
        details_json: { retry_at: '2026-07-29T08:15:00.000Z' }
      }
    })
  })

  it('marks an Agent token quota rejection non-retryable in turn-error details', () => {
    const details = turnFailureDetails({
      code: 'agent_token_quota_exceeded',
      retryable: false,
      status: 429
    })

    expect(details).toMatchObject({
      llm_error_kind: 'quota',
      error_code: 'agent_token_quota_exceeded',
      retryable: false,
      aigateway: { code: 'agent_token_quota_exceeded', status: 429 }
    })
  })

  it('emits worker progress as an ephemeral progress-lane keepalive', () => {
    const turn = actorTurnRef()
    const envelope = workerProgressEnvelope(turn, 'checkpoint', 'turn in progress', 'turn-start-1', {
      stage: 'llm'
    })

    expect(sealed(envelope).lane).toBe(Lane.PROGRESS)
    expect(sealed(envelope).durability).toBe(DurabilityClass.CONTROL_EPHEMERAL)
    expect(envelope.correlationId).toBe('turn-start-1')
    if (envelope.body.case !== 'workerProgress') throw new Error('expected workerProgress body')
    expect(envelope.body.value).toMatchObject({
      kind: 'checkpoint',
      summary: 'turn in progress'
    })
    expect(envelope.body.value.turn).toMatchObject({ actorEventId: turn.actor_event_id })
    expect(jsonObjectFromBytes(envelope.body.value.refsJson, 'refs_json')).toEqual({ stage: 'llm' })
  })

  it('encodes renderer-safe reply presentation progress for the control plane', () => {
    const turn = actorTurnRef()
    const envelope = workerProgressEnvelope(turn, 'reply_presentation', 'reply presentation updated', 'turn-start-1', {
      presentation_event: {
        kind: 'plan.snapshot',
        payload: { operation_id: 'todo', revision: 1 }
      }
    })

    expect(sealed(envelope).lane).toBe(Lane.PROGRESS)
    expect(sealed(envelope).durability).toBe(DurabilityClass.CONTROL_EPHEMERAL)
  })

  it('reports process drain as ephemeral control traffic', () => {
    const envelope = controlShutdownEnvelope('sigterm')

    expect(sealed(envelope).lane).toBe(Lane.CONTROL)
    expect(sealed(envelope).durability).toBe(DurabilityClass.CONTROL_EPHEMERAL)
    if (envelope.body.case !== 'controlShutdown') throw new Error('expected controlShutdown body')
    expect(envelope.body.value.reason).toBe('sigterm')
  })

  it('renews a silent BackgroundAgentJob Turn independently of Codex notifications', async () => {
    const sent: unknown[] = []
    const active = new ActiveTurn({ turn: actorTurnRef() } as TurnStart, 'turn-start-1')
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

  it('wakes foreground observation without consuming the queued steer update', async () => {
    const turn = actorTurnRef()
    const active = new ActiveTurn({ turn } as TurnStart, 'turn-start-steering')

    const waiting = active.waitForSteering()
    active.pushSteering({
      turn: { ...turn, revision: turn.revision + 1 },
      actorEvent: {
        actor_event_id: '00000000-0000-0000-0000-000000000102',
        queue_sequence: 2,
        type: 'command.steer',
        source_event_id: 'steer-source'
      }
    })

    await waiting
    await expect(active.waitForSteering()).resolves.toBeUndefined()
    expect(active.pollSteering()).toHaveLength(1)
  })

  it('prepares session workspace without projecting enabled skills', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-workspace-'))
    const actorEventID = '00000000-0000-0000-0000-000000000101'

    try {
      const config = workerConfigForRoot(root)
      mkdirSync(agentHomePaths(config.agentsRoot, 'agent-1').userFiles, { recursive: true })

      const workspaceRoot = prepareTurnWorkspace(config, {
        workspace_id: 10_000,
        turn: {
          actor: { agent_uid: 'agent-1', session_id: 'session-1' },
          activation_uid: 'activation-1',
          actor_epoch: 1,
          actor_event_id: actorEventID,
          revision: 0
        },
        actor_event: {
          actor_event_id: actorEventID,
          queue_sequence: 1,
          type: 'im.message.addressed',
          source_event_id: 'signal-entry-1',
          payload_json: {}
        },
        model_ref: {
          profile: 'primary',
          provider_id: 'openrouter-main',
          model: 'z-ai/glm-5.2'
        }
      })

      expect(workspaceRoot).toBe(join(config.agentsRoot, 'agent-1', 'sessions', '10000'))
      expect(existsSync(join(workspaceRoot, 'temp'))).toBe(true)
      expect(existsSync(agentHomePaths(config.agentsRoot, 'agent-1').userFiles)).toBe(true)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('moves the legacy Base64URL workspace into its numeric Session directory', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-workspace-migration-'))

    try {
      const config = workerConfigForRoot(root)
      const actor = { agent_uid: 'agent-1', session_id: 'provider:chat/a' }
      const legacyRoot = join(
        agentHomePaths(config.agentsRoot, actor.agent_uid).sessions,
        Buffer.from(actor.session_id, 'utf8').toString('base64url')
      )
      mkdirSync(legacyRoot, { recursive: true })
      writeFileSync(join(legacyRoot, 'retained.txt'), 'keep me')

      const workspaceRoot = prepareActorWorkspace(config, actor, 10_000)

      expect(workspaceRoot).toBe(join(config.agentsRoot, 'agent-1', 'sessions', '10000'))
      expect(readFileSync(join(workspaceRoot, 'retained.txt'), 'utf8')).toBe('keep me')
      expect(existsSync(legacyRoot)).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('fails closed when both legacy and numeric Session directories exist', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-workspace-conflict-'))

    try {
      const config = workerConfigForRoot(root)
      const actor = { agent_uid: 'agent-1', session_id: 'provider:chat/a' }
      const sessions = agentHomePaths(config.agentsRoot, actor.agent_uid).sessions
      mkdirSync(join(sessions, Buffer.from(actor.session_id, 'utf8').toString('base64url')), { recursive: true })
      mkdirSync(join(sessions, '10000'), { recursive: true })

      expect(() => prepareActorWorkspace(config, actor, 10_000)).toThrow('Session workspace migration conflict')
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
              turn: actorTurnRefToProto(actorTurnRef()),
              reason: 'command.steer'
            })
          }
        })
      )
    ).toThrow(/mailbox_updated\.actor_event is required/)
  })

  it('rejects turn_start envelopes without a durable turn fence', () => {
    expect(() =>
      turnStartFromEnvelope(
        createEnvelope({
          ...envelopeHeader('turn-start-missing-turn'),
          body: {
            case: 'turnStart',
            value: create(TurnStartSchema, {
              workspaceId: 10_000n,
              actorEvent: create(ActorEventEnvelopeSchema, {
                actorEventId: '00000000-0000-0000-0000-000000000001',
                queueSequence: 1n,
                type: 'im.message.addressed',
                sourceEventId: 'source-1'
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
            workspaceId: 10_000n,
            turn: actorTurnRefToProto(actorTurnRef()),
            actorEvent: create(ActorEventEnvelopeSchema, {
              actorEventId: '00000000-0000-0000-0000-000000000001',
              queueSequence: 1n,
              type: 'im.message.addressed',
              sourceEventId: 'source-1'
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

  it('accepts only supported hosted-tool declarations on turn_start', () => {
    const hostedToolsEnvelope = (hostedTools: unknown): Envelope =>
      createEnvelope({
        ...envelopeHeader('turn-start-hosted-tools'),
        body: {
          case: 'turnStart',
          value: create(TurnStartSchema, {
            workspaceId: 10_000n,
            turn: actorTurnRefToProto(actorTurnRef()),
            actorEvent: create(ActorEventEnvelopeSchema, {
              actorEventId: '00000000-0000-0000-0000-000000000001',
              queueSequence: 1n,
              type: 'im.message.addressed',
              sourceEventId: 'source-1'
            }),
            hostedToolsJson: jsonBytes(hostedTools as never)
          })
        }
      })

    expect(
      turnStartFromEnvelope(hostedToolsEnvelope([{ type: 'image_generation' }, { type: 'web_search' }])).hosted_tools
    ).toEqual([{ type: 'image_generation' }, { type: 'web_search' }])
    expect(() => turnStartFromEnvelope(hostedToolsEnvelope([{ type: 'computer_use' }]))).toThrow(
      /must declare a supported hosted tool type/
    )
    expect(() => turnStartFromEnvelope(hostedToolsEnvelope([{ type: 'function', name: 'untrusted' }]))).toThrow(
      /must declare a supported hosted tool type/
    )
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
    expect(sealed(sent[0]!).lane).toBe(Lane.RPC)
    expect(sent[0]!.correlationId).toBe('worker-rpc-1')
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

  it('pulls a relay upload into a worker root through an atomic rename', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-relay-pull-'))
    const config = workerConfigForRoot(root)
    const state = createFileLaneState()
    const plainText = 'hello relay world'
    const relay = relayStub({ body: plainText })

    try {
      const paths = agentHomePaths(config.agentsRoot, 'agent-1')
      mkdirSync(paths.userFiles, { recursive: true })

      const result = await handleWorkerFilePull(config, state, {
        ...transferRequest(relay, 'transfer-1', 'user_files', 'agent-1/user-files/inbox/lark/message-1/hello.txt'),
        maxBytes: 1024n
      })

      expect(readFileSync(join(paths.userFiles, 'inbox/lark/message-1/hello.txt'), 'utf8')).toBe(plainText)
      expect(result).toMatchObject({
        root: 'user_files',
        relativePath: 'agent-1/user-files/inbox/lark/message-1/hello.txt',
        size: BigInt(Buffer.byteLength(plainText))
      })
      expect(result.xxh3128).toMatch(/^[a-f0-9]{32}$/)
      expect(relay.requests).toEqual([{ method: 'GET', path: '/relay/transfer-1' }])
      expect(existsSync('/tmp/ankole-file-transfer/transfer-1')).toBe(false)

      const document = await handleWorkerFilePull(config, state, {
        ...transferRequest(relay, 'transfer-document', 'agent_home_documents', 'agent-1/SOUL.md'),
        maxBytes: 1024n
      })
      expect(document.size).toBe(BigInt(Buffer.byteLength(plainText)))
      expect(readFileSync(paths.soul, 'utf8')).toBe(plainText)
      expect(statSync(paths.soul).mode & 0o222).toBe(0)
    } finally {
      relay.stop()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects an oversize or failed relay pull without leaving a partial file', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-relay-pull-bounds-'))
    const config = workerConfigForRoot(root)
    const state = createFileLaneState()
    const relay = relayStub({ body: 'x'.repeat(64), status: 200 })

    try {
      const paths = agentHomePaths(config.agentsRoot, 'agent-1')
      mkdirSync(paths.userFiles, { recursive: true })
      const request = transferRequest(relay, 'transfer-big', 'user_files', 'agent-1/user-files/big.txt')

      const oversize = await handleWorkerFilePull(config, state, { ...request, maxBytes: 16n }).catch(caught => caught)
      expect(oversize).toBeInstanceOf(FileTransferError)
      expect(oversize.code).toBe('file_too_large')
      expect(existsSync(join(paths.userFiles, 'big.txt'))).toBe(false)
      expect(existsSync('/tmp/ankole-file-transfer/transfer-big')).toBe(false)

      relay.status = 410
      const failed = await handleWorkerFilePull(config, state, { ...request, maxBytes: 1024n }).catch(caught => caught)
      expect(failed.code).toBe('relay_failed')
      expect(failed.message).not.toContain('token')
      expect(existsSync(join(paths.userFiles, 'big.txt'))).toBe(false)

      const badTransfer = await handleWorkerFilePull(config, state, {
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
    const state = createFileLaneState()
    const relay = relayStub({})

    try {
      const paths = agentHomePaths(config.agentsRoot, 'agent-1')
      mkdirSync(join(paths.userFiles, 'inbox'), { recursive: true })
      writeFileSync(join(paths.userFiles, 'inbox/hello.txt'), 'hello world')

      const result = await handleWorkerFilePush(config, state, {
        ...transferRequest(relay, 'push-1', 'user_files', 'agent-1/user-files/inbox/hello.txt'),
        maxBytes: 1024n
      })
      expect(result).toMatchObject({
        root: 'user_files',
        relativePath: 'agent-1/user-files/inbox/hello.txt',
        size: 11n
      })
      expect(result.xxh3128).toMatch(/^[a-f0-9]{32}$/)
      expect(relay.requests).toEqual([{ method: 'PUT', path: '/relay/push-1' }])
      expect(relay.received.get('/relay/push-1')?.toString('utf8')).toBe('hello world')
      expect(relay.receivedHeaders.get('/relay/push-1')?.get('content-length')).toBe('11')

      const tooLarge = await handleWorkerFilePush(config, state, {
        ...transferRequest(relay, 'push-large', 'user_files', 'agent-1/user-files/inbox/hello.txt'),
        maxBytes: 4n
      }).catch(caught => caught)
      expect(tooLarge.code).toBe('file_too_large')
      expect(relay.requests).toHaveLength(1)

      const missing = await handleWorkerFilePush(config, state, {
        ...transferRequest(relay, 'push-missing', 'user_files', 'agent-1/user-files/inbox/missing.txt'),
        maxBytes: 1024n
      }).catch(caught => caught)
      expect(missing.code).toBe('file_not_found')

      const directory = await handleWorkerFilePush(config, state, {
        ...transferRequest(relay, 'push-directory', 'user_files', 'agent-1/user-files/inbox'),
        maxBytes: 1024n
      }).catch(caught => caught)
      expect(directory.code).toBe('not_regular_file')

      relay.status = 500
      const rejected = await handleWorkerFilePush(config, state, {
        ...transferRequest(relay, 'push-rejected', 'user_files', 'agent-1/user-files/inbox/hello.txt'),
        maxBytes: 1024n
      }).catch(caught => caught)
      expect(rejected.code).toBe('relay_failed')
      relay.status = 200

      // The relay stub swaps the file while the PUT is in flight. The
      // replacement keeps the size and mtime, so only the inode check can
      // tell the control plane that the bytes it holds belong to another file.
      const swappedPath = join(paths.userFiles, 'inbox/swapped.txt')
      const replacementPath = join(paths.userFiles, 'inbox/replacement.txt')
      const sharedMtime = new Date(1_700_000_000_000)
      writeFileSync(swappedPath, 'original bytes')
      utimesSync(swappedPath, sharedMtime, sharedMtime)
      relay.onRequest = () => {
        writeFileSync(replacementPath, 'replaced bytes')
        utimesSync(replacementPath, sharedMtime, sharedMtime)
        renameSync(replacementPath, swappedPath)
      }
      const swapped = await handleWorkerFilePush(config, state, {
        ...transferRequest(relay, 'push-swapped', 'user_files', 'agent-1/user-files/inbox/swapped.txt'),
        maxBytes: 1024n
      }).catch(caught => caught)
      expect(swapped.code).toBe('file_changed')
    } finally {
      relay.stop()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('lists, moves, and deletes worker files through typed requests', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-ops-'))
    const config = workerConfigForRoot(root)
    const state = createFileLaneState()

    try {
      const userFilesRoot = agentHomePaths(config.agentsRoot, 'agent-1').userFiles
      mkdirSync(join(userFilesRoot, 'inbox/lark/message-1'), { recursive: true })
      writeFileSync(join(userFilesRoot, 'inbox/lark/message-1/hello.txt'), 'hello world')

      const listing = handleWorkerFileList(config, {
        root: 'user_files',
        relativePath: 'agent-1/user-files/inbox',
        recursive: true,
        maxEntries: 1000n
      } as never)
      expect(listing.relativePath).toBe('agent-1/user-files/inbox')
      expect(listing.entries).toContainEqual(
        expect.objectContaining({
          relativePath: 'agent-1/user-files/inbox/lark/message-1/hello.txt',
          kind: 'file',
          size: 11n
        })
      )

      const rootListing = handleWorkerFileList(config, {
        root: 'user_files',
        relativePath: 'agent-1/user-files',
        recursive: false,
        maxEntries: 1n
      } as never)
      expect(rootListing.truncated).toBe(false)
      expect(rootListing.entries).toHaveLength(1)

      const moved = await handleWorkerFileMove(config, state, {
        root: 'user_files',
        fromRelativePath: 'agent-1/user-files/inbox/lark/message-1/hello.txt',
        toRelativePath: 'agent-1/user-files/inbox/lark/message-1/renamed.txt',
        overwrite: false
      } as never)
      expect(moved.toRelativePath).toBe('agent-1/user-files/inbox/lark/message-1/renamed.txt')
      expect(existsSync(join(userFilesRoot, 'inbox/lark/message-1/hello.txt'))).toBe(false)
      expect(readFileSync(join(userFilesRoot, 'inbox/lark/message-1/renamed.txt'), 'utf8')).toBe('hello world')

      writeFileSync(join(userFilesRoot, 'inbox/lark/message-1/target.txt'), 'old content')
      const blocked = await handleWorkerFileMove(config, state, {
        root: 'user_files',
        fromRelativePath: 'agent-1/user-files/inbox/lark/message-1/renamed.txt',
        toRelativePath: 'agent-1/user-files/inbox/lark/message-1/target.txt',
        overwrite: false
      } as never).catch(caught => caught)
      expect(blocked.message).toMatch(/already exists/)
      await handleWorkerFileMove(config, state, {
        root: 'user_files',
        fromRelativePath: 'agent-1/user-files/inbox/lark/message-1/renamed.txt',
        toRelativePath: 'agent-1/user-files/inbox/lark/message-1/target.txt',
        overwrite: true
      } as never)
      expect(readFileSync(join(userFilesRoot, 'inbox/lark/message-1/target.txt'), 'utf8')).toBe('hello world')

      const directoryDelete = await handleWorkerFileDelete(config, state, {
        root: 'user_files',
        relativePath: 'agent-1/user-files/inbox',
        recursive: false
      } as never).catch(caught => caught)
      expect(directoryDelete.message).toMatch(/recursive=true/)

      const deleted = await handleWorkerFileDelete(config, state, {
        root: 'user_files',
        relativePath: 'agent-1/user-files/inbox/lark/message-1/target.txt',
        recursive: false
      } as never)
      expect(deleted.relativePath).toBe('agent-1/user-files/inbox/lark/message-1/target.txt')
      expect(existsSync(join(userFilesRoot, 'inbox/lark/message-1/target.txt'))).toBe(false)

      const sessionsRoot = agentHomePaths(config.agentsRoot, 'agent-1').sessions
      mkdirSync(join(sessionsRoot, 'session-1'), { recursive: true })
      writeFileSync(join(sessionsRoot, 'session-1/log.txt'), 'logs')
      const sessions = handleWorkerFileList(config, {
        root: 'agent_sessions',
        relativePath: 'agent-1/sessions',
        recursive: true,
        maxEntries: 1000n
      } as never)
      expect(sessions.entries).toContainEqual(
        expect.objectContaining({ relativePath: 'agent-1/sessions/session-1/log.txt', kind: 'file', size: 4n })
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects unsafe file lane roots, paths, and escaping symlinks', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-paths-'))
    const config = workerConfigForRoot(root)
    const state = createFileLaneState()

    try {
      const userFilesRoot = agentHomePaths(config.agentsRoot, 'agent-1').userFiles
      mkdirSync(userFilesRoot, { recursive: true })
      const outsidePath = join(root, 'outside.txt')
      writeFileSync(outsidePath, 'secret')
      symlinkSync(outsidePath, join(userFilesRoot, 'escaped.txt'))

      const deleteFor = (relativePath: string, fileRoot = 'user_files') =>
        handleWorkerFileDelete(config, state, { root: fileRoot, relativePath, recursive: false } as never).catch(
          caught => caught.message
        )

      expect(await deleteFor('/tmp/escape.txt')).toMatch(/relative_path must not be absolute/)
      expect(await deleteFor('../escape.txt')).toMatch(/invalid relative_path/)
      expect(await deleteFor('agent-1/user-files/a.txt', 'unsupported')).toMatch(/unsupported file root/)
      expect(await deleteFor('agent-1/user-files/escaped.txt')).toMatch(/path resolves outside root/)
      expect(await deleteFor('agent-1/other/a.txt')).toMatch(/does not match user_files layout/)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function workerConfig(): WorkerConfig {
  return {
    endpoint: 'ws://127.0.0.1:4000/runtime-fabric/worker',
    transport: 'channel',
    workerAuthKey: 'secret',
    workerID: 'worker-a',
    incarnationID: 'incarnation-a',
    agentsRoot: '/agents',
    builtinSkillsRoot: '/repo/app/library',
    maxConcurrentTurns: 9
  }
}

function actorTurnRef() {
  return {
    actor: {
      agent_uid: 'agent-1',
      session_id: 'session-1'
    },
    activation_uid: 'activation-1',
    actor_epoch: 1,
    actor_event_id: '00000000-0000-0000-0000-000000000101',
    revision: 0
  }
}

function workerConfigForRoot(root: string): WorkerConfig {
  return {
    endpoint: 'ws://127.0.0.1:4000/runtime-fabric/worker',
    transport: 'channel',
    workerAuthKey: 'secret',
    workerID: 'worker-a',
    incarnationID: 'incarnation-a',
    agentsRoot: join(root, 'agents'),
    builtinSkillsRoot: join(root, 'builtin-skills'),
    maxConcurrentTurns: 9
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

function transferRequest(relay: RelayStub, transferID: string, root: string, relativePath: string) {
  return create(WorkerFileTransferRequestSchema, {
    transferId: transferID,
    url: `${relay.url}/relay/${transferID}?token=secret-token`,
    root,
    relativePath,
    maxBytes: 1024n,
    expiresAt: '2099-01-01T00:00:00Z'
  })
}
