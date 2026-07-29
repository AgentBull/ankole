import { create, toJson as toJSON } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync
} from 'node:fs'
import { runtimeFabricValidateEnvelope, zstdCompressBlock, zstdDecompressBlock } from '@ankole/kernel'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createFileTransferLane } from '../src/lanes/file'
import { runtimeFabricFileProtocol } from '../src/fabric/fabric'
import {
  ActorEventEnvelopeSchema,
  createEnvelope,
  DurabilityClass,
  encodeEnvelope,
  envelopeHeader,
  envelopeProtocolVersion,
  EnvelopeSchema,
  jsonBytes,
  jsonObjectFromBytes,
  Lane,
  MailboxUpdatedSchema,
  RPCRequestSchema,
  TurnCompletionOutcome,
  TurnStartSchema,
  type Envelope
} from '../src/fabric/envelope_proto'
import {
  parseRuntimeFabricURL,
  workerCapacityEnvelope,
  workerHeartbeatEnvelope,
  workerReadyEnvelope
} from '../src/worker/config'
import { handleWorkerRPCRequest } from '../src/lanes/rpc_lane'
import { turnCompletedEnvelope, workerProgressEnvelope } from '../src/fabric/envelopes'
import type { WorkerConfig } from '../src/worker/config'
import { prepareTurnWorkspace } from '../src/worker/workspace'
import { actorTurnRefToProto, mailboxUpdatedFromEnvelope, turnStartFromEnvelope } from '../src/lanes/actor_lane'
import type { TurnStart } from '../src/lanes/actor_lane'
import { startTurnProgress, turnFailureDetails, type ActiveTurn } from '../src/worker/active_turns'
import { BackgroundAgentJobTurnPersistenceError } from '../src/core/codex-runner/turn-recorder'
import { agentHomePaths } from '../src/core/agent-home-paths'

function validatedBytes(envelope: Envelope): Buffer {
  const bytes = encodeEnvelope(envelope)
  runtimeFabricValidateEnvelope(bytes)
  return bytes
}

describe('@ankole/agent-computer runtime', () => {
  it('parses RuntimeFabric URL auth without embedding worker identity', () => {
    expect(parseRuntimeFabricURL('tcp://:secret@127.0.0.1:6010')).toMatchObject({
      workerAuthKey: 'secret',
      endpoint: 'tcp://127.0.0.1:6010'
    })

    expect(() => parseRuntimeFabricURL('tcp://worker-a:secret@127.0.0.1:6010')).toThrow(/username/)
    expect(() => parseRuntimeFabricURL('tcp://127.0.0.1:6010')).toThrow(/worker auth key/)

    expect(() => parseRuntimeFabricURL('http://:secret@127.0.0.1:6010')).toThrow(/tcp/)
  })

  it('emits worker.ready without actor authority fields', () => {
    const config = workerConfig()
    const ready = workerReadyEnvelope(config)
    const heartbeat = workerHeartbeatEnvelope(config, 123)
    const capacity = workerCapacityEnvelope(config)

    expect(ready.body.case).toBe('workerReady')
    expect(heartbeat.body.case).toBe('workerHeartbeat')
    expect(capacity.body.case).toBe('workerCapacity')
    expect(envelopeProtocolVersion).toBe(3)
    expect(ready.protocolVersion).toBe(envelopeProtocolVersion)
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
    expect(validatedBytes(ready)).toBeInstanceOf(Buffer)
    expect(validatedBytes(heartbeat)).toBeInstanceOf(Buffer)
    expect(validatedBytes(capacity)).toBeInstanceOf(Buffer)
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
    const details = turnFailureDetails(new BackgroundAgentJobTurnPersistenceError(new Error('RPC timed out')))

    expect(details).toMatchObject({
      error_code: 'background_agent_job_turn_persistence_failed',
      retryable: true
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

  it('emits worker progress as an ephemeral progress-lane keepalive', () => {
    const turn = actorTurnRef()
    const envelope = workerProgressEnvelope(turn, 'checkpoint', 'turn in progress', 'turn-start-1', {
      stage: 'llm'
    })

    expect(envelope.lane).toBe(Lane.PROGRESS)
    expect(envelope.durability).toBe(DurabilityClass.CONTROL_EPHEMERAL)
    expect(envelope.correlationId).toBe('turn-start-1')
    if (envelope.body.case !== 'workerProgress') throw new Error('expected workerProgress body')
    expect(envelope.body.value).toMatchObject({
      kind: 'checkpoint',
      summary: 'turn in progress'
    })
    expect(envelope.body.value.turn).toMatchObject({ actorEventId: turn.actor_event_id })
    expect(jsonObjectFromBytes(envelope.body.value.refsJson, 'refs_json')).toEqual({ stage: 'llm' })
    expect(validatedBytes(envelope)).toBeInstanceOf(Buffer)
  })

  it('encodes renderer-safe reply presentation progress for the control plane', () => {
    const turn = actorTurnRef()
    const envelope = workerProgressEnvelope(turn, 'reply_presentation', 'reply presentation updated', 'turn-start-1', {
      presentation_event: {
        kind: 'plan.snapshot',
        payload: { operation_id: 'todo', revision: 1 }
      }
    })

    expect(envelope.lane).toBe(Lane.PROGRESS)
    expect(envelope.durability).toBe(DurabilityClass.CONTROL_EPHEMERAL)
    expect(validatedBytes(envelope)).toBeInstanceOf(Buffer)
  })

  it('emits response-backed turn completion as replayable turn control', () => {
    const turn = actorTurnRef()
    const envelope = turnCompletedEnvelope(turn, 'resp_final_1', 'iteration_exhausted', 'turn-start-1')

    expect(envelope.lane).toBe(Lane.TURN)
    expect(envelope.durability).toBe(DurabilityClass.CONTROL_REPLAYABLE)
    expect(envelope.correlationId).toBe('turn-start-1')
    if (envelope.body.case !== 'turnCompleted') throw new Error('expected turnCompleted body')
    expect(envelope.body.value.turn).toEqual(actorTurnRefToProto(turn))
    expect(envelope.body.value.finalResponseId).toBe('resp_final_1')
    expect(envelope.body.value.outcome).toBe(TurnCompletionOutcome.ITERATION_EXHAUSTED)
    expect(validatedBytes(envelope)).toBeInstanceOf(Buffer)
  })

  it('renews a silent BackgroundAgentJob Turn independently of Codex notifications', async () => {
    const sent: unknown[] = []
    const active = {
      turnStart: { turn: actorTurnRef() } as TurnStart,
      correlationID: 'turn-start-1',
      steeringUpdates: [],
      abortController: new AbortController(),
      controlledStopRequested: false
    } satisfies ActiveTurn
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

  it('prepares session workspace without projecting enabled skills', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-workspace-'))
    const actorEventID = '00000000-0000-0000-0000-000000000101'

    try {
      const config = workerConfigForRoot(root)
      mkdirSync(agentHomePaths(config.agentsRoot, 'agent-1').userFiles, { recursive: true })

      const workspaceRoot = prepareTurnWorkspace(config, {
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

      expect(existsSync(join(workspaceRoot, 'temp'))).toBe(true)
      expect(existsSync(agentHomePaths(config.agentsRoot, 'agent-1').userFiles)).toBe(true)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects mailbox updates without the journaled actor event', () => {
    expect(() =>
      mailboxUpdatedFromEnvelope(
        createEnvelope({
          ...envelopeHeader('mailbox-updated-missing-event', Lane.TURN, DurabilityClass.CONTROL_EPHEMERAL),
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
          ...envelopeHeader('turn-start-missing-turn', Lane.TURN, DurabilityClass.CONTROL_REPLAYABLE),
          body: {
            case: 'turnStart',
            value: create(TurnStartSchema, {
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
        ...envelopeHeader('turn-start-runtime-env', Lane.TURN, DurabilityClass.CONTROL_REPLAYABLE),
        body: {
          case: 'turnStart',
          value: create(TurnStartSchema, {
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

  it('accepts only the image generation hosted-tool declaration on turn_start', () => {
    const hostedToolsEnvelope = (hostedTools: unknown): Envelope =>
      createEnvelope({
        ...envelopeHeader('turn-start-hosted-tools', Lane.TURN, DurabilityClass.CONTROL_REPLAYABLE),
        body: {
          case: 'turnStart',
          value: create(TurnStartSchema, {
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

    expect(turnStartFromEnvelope(hostedToolsEnvelope([{ type: 'image_generation' }])).hosted_tools).toEqual([
      { type: 'image_generation' }
    ])
    expect(() => turnStartFromEnvelope(hostedToolsEnvelope([{ type: 'function', name: 'untrusted' }]))).toThrow(
      /must declare only image_generation/
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
    expect(sent[0]!.lane).toBe(Lane.RPC)
    expect(sent[0]!.correlationId).toBe('worker-rpc-1')
    const body = sent[0]!.body
    if (body.case !== 'rpcError') throw new Error('expected rpcError body')
    expect(body.value).toMatchObject({
      requestId: 'worker-rpc-1',
      code: 'unknown_rpc_method'
    })
    expect(jsonObjectFromBytes(body.value.detailsJson, 'details_json')).toEqual({ method: 'test.probe' })
    expect(validatedBytes(sent[0]!)).toBeInstanceOf(Buffer)
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
    expect(validatedBytes(sent[0]!)).toBeInstanceOf(Buffer)
  })

  it('handles worker file lane WRITE and READ through zstd DATA credit', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-'))
    const config = workerConfigForRoot(root)
    const sentFrames: Buffer[][] = []
    const sender = {
      async sendFileFrame(frames: Buffer[]) {
        sentFrames.push(frames)
      }
    }

    try {
      const paths = agentHomePaths(config.agentsRoot, 'agent-1')
      mkdirSync(paths.userFiles, { recursive: true })
      mkdirSync(paths.installedSkills, { recursive: true })
      mkdirSync(paths.sessions, { recursive: true })
      mkdirSync(config.builtinSkillsRoot, { recursive: true })

      const lane = createFileTransferLane(config, sender.sendFileFrame)
      const plainText = 'hello zstd world'
      const sourcePath = join(root, 'source.txt')
      writeFileSync(sourcePath, plainText)
      const compressed = await zstdCompressBlock(Buffer.from(plainText), 3)

      const transferID = 'transfer-1'
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('WRITE_OPEN'),
        Buffer.from(transferID),
        Buffer.from('/user_files/agent-1/user-files/inbox/lark/message-1/hello.txt'),
        u64Frame(Buffer.byteLength(plainText))
      ])
      expect(frameFor(sentFrames, transferID, 'WRITE_READY')[3]).toEqual(u64Frame(creditWindow))

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('DATA'),
        Buffer.from(transferID),
        u64Frame(0),
        u64Frame(0),
        boolFrame(true),
        compressed
      ])
      expect(frameFor(sentFrames, transferID, 'CREDIT')[3]).toEqual(u64Frame(compressed.byteLength))

      await lane.handle([runtimeFabricFileProtocol, Buffer.from('WRITE_COMMIT'), Buffer.from(transferID)])

      expect(readFileSync(join(paths.userFiles, 'inbox/lark/message-1/hello.txt'), 'utf8')).toBe(plainText)
      const committed = frameFor(sentFrames, transferID, 'WRITE_COMMITTED')
      expect(committed[3]?.toString('utf8')).toBe('/user_files/agent-1/user-files/inbox/lark/message-1/hello.txt')
      expect(readU64Frame(committed[4])).toBe(Buffer.byteLength(plainText))
      expect(committed[5]?.toString('utf8')).toMatch(/^[a-f0-9]{32}$/)

      const documentTransferID = 'transfer-document'
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('WRITE_OPEN'),
        Buffer.from(documentTransferID),
        Buffer.from('/agent_home_documents/agent-1/SOUL.md'),
        u64Frame(Buffer.byteLength(plainText))
      ])
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('DATA'),
        Buffer.from(documentTransferID),
        u64Frame(0),
        u64Frame(0),
        boolFrame(true),
        compressed
      ])
      await lane.handle([runtimeFabricFileProtocol, Buffer.from('WRITE_COMMIT'), Buffer.from(documentTransferID)])
      expect(readFileSync(paths.soul, 'utf8')).toBe(plainText)
      expect(statSync(paths.soul).mode & 0o222).toBe(0)

      const getTransferID = 'transfer-2'
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('READ_OPEN'),
        Buffer.from(getTransferID),
        Buffer.from('/user_files/agent-1/user-files/inbox/lark/message-1/hello.txt'),
        Buffer.from('xxh3_128')
      ])
      const readReady = frameFor(sentFrames, getTransferID, 'READ_READY')
      expect(readReady[3]?.toString('utf8')).toBe('/user_files/agent-1/user-files/inbox/lark/message-1/hello.txt')
      expect(readU64Frame(readReady[4])).toBe(Buffer.byteLength(plainText))
      await Bun.sleep(25)
      expect(dataChunks(sentFrames, getTransferID)).toHaveLength(0)

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('CREDIT'),
        Buffer.from(getTransferID),
        u64Frame(creditWindow)
      ])

      const readDone = await waitForFrame(sentFrames, getTransferID, 'READ_DONE')
      const getChunks = dataChunks(sentFrames, getTransferID)
      const decompressed = Buffer.concat(
        await Promise.all(getChunks.map(chunk => zstdDecompressBlock(chunk, 2 * 1024 * 1024)))
      )
      expect(decompressed.toString('utf8')).toBe(plainText)
      expect(readU64Frame(readDone[3])).toBe(getChunks.length)
      expect(readU64Frame(readDone[4])).toBe(Buffer.concat(getChunks).byteLength)

      const missingTransferID = 'transfer-read-missing'
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('READ_OPEN'),
        Buffer.from(missingTransferID),
        Buffer.from('/user_files/agent-1/user-files/inbox/lark/message-1/missing.txt'),
        Buffer.from('none')
      ])
      expect(frameFor(sentFrames, missingTransferID, 'ERROR')[3]?.toString('utf8')).toBe('file_not_found')

      const directoryTransferID = 'transfer-read-directory'
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('READ_OPEN'),
        Buffer.from(directoryTransferID),
        Buffer.from('/user_files/agent-1/user-files/inbox/lark/message-1'),
        Buffer.from('none')
      ])
      expect(frameFor(sentFrames, directoryTransferID, 'ERROR')[3]?.toString('utf8')).toBe('not_regular_file')

      const abortTransferID = 'transfer-read-abort'
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('READ_OPEN'),
        Buffer.from(abortTransferID),
        Buffer.from('/user_files/agent-1/user-files/inbox/lark/message-1/hello.txt'),
        Buffer.from('none')
      ])
      expect(frameFor(sentFrames, abortTransferID, 'READ_READY')[3]?.toString('utf8')).toBe(
        '/user_files/agent-1/user-files/inbox/lark/message-1/hello.txt'
      )
      await lane.handle([runtimeFabricFileProtocol, Buffer.from('READ_ABORT'), Buffer.from(abortTransferID)])
      await lane.handle([runtimeFabricFileProtocol, Buffer.from('CREDIT'), Buffer.from(abortTransferID), u64Frame(1)])
      expect(frameFor(sentFrames, abortTransferID, 'ERROR')[3]?.toString('utf8')).toBe('operation_failed')

      const replacedPath = join(paths.userFiles, 'inbox/lark/message-1/replaced.txt')
      const replacementPath = join(paths.userFiles, 'inbox/lark/message-1/replacement.txt')
      writeFileSync(replacedPath, 'original bytes')

      const replacedTransferID = 'transfer-read-replaced'
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('READ_OPEN'),
        Buffer.from(replacedTransferID),
        Buffer.from('/user_files/agent-1/user-files/inbox/lark/message-1/replaced.txt'),
        Buffer.from('none')
      ])
      expect(frameFor(sentFrames, replacedTransferID, 'READ_READY')[3]?.toString('utf8')).toBe(
        '/user_files/agent-1/user-files/inbox/lark/message-1/replaced.txt'
      )

      writeFileSync(replacementPath, 'replacement bytes have a different size')
      renameSync(replacementPath, replacedPath)

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('CREDIT'),
        Buffer.from(replacedTransferID),
        u64Frame(creditWindow)
      ])

      const replacedError = await waitForFrame(sentFrames, replacedTransferID, 'ERROR')
      expect(replacedError[3]?.toString('utf8')).toBe('file_changed')
      expect(replacedError[4]?.toString('utf8')).toContain('file changed during read')
      expect(
        sentFrames.some(
          frames => frames[1]?.toString('utf8') === 'READ_DONE' && frames[2]?.toString('utf8') === replacedTransferID
        )
      ).toBe(false)
      expect(JSON.stringify(sentFrames)).not.toContain('object_key')
      expect(JSON.stringify(sentFrames)).not.toContain('sha256')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('handles file lane LIST, MOVE, DELETE, and XXH3 STAT observations', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-ops-'))
    const config = workerConfigForRoot(root)
    const sentFrames: Buffer[][] = []
    const sender = {
      async sendFileFrame(frames: Buffer[]) {
        sentFrames.push(frames)
      }
    }

    try {
      const userFilesRoot = agentHomePaths(config.agentsRoot, 'agent-1').userFiles
      mkdirSync(join(userFilesRoot, 'inbox/lark/message-1'), {
        recursive: true
      })
      writeFileSync(join(userFilesRoot, 'inbox/lark/message-1/hello.txt'), 'hello world')

      const lane = createFileTransferLane(config, sender.sendFileFrame)
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('LIST'),
        Buffer.from('list-1'),
        Buffer.from('/user_files/agent-1/user-files/inbox'),
        boolFrame(true),
        u64Frame(1000)
      ])
      const listFrame = frameFor(sentFrames, 'list-1', 'LIST_OK')
      const entries = decodeEntries(listFrame[6]!)
      expect(entries).toContainEqual(
        expect.objectContaining({
          relative_path: 'agent-1/user-files/inbox/lark/message-1/hello.txt',
          kind: 'file',
          size: 11
        })
      )

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('STAT'),
        Buffer.from('stat-1'),
        Buffer.from('/user_files/agent-1/user-files/inbox/lark/message-1/hello.txt'),
        Buffer.from('xxh3_128')
      ])
      expect(frameFor(sentFrames, 'stat-1', 'STAT_OK')[7]?.toString('utf8')).toMatch(/^[a-f0-9]{32}$/)

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('MOVE'),
        Buffer.from('move-1'),
        Buffer.from('/user_files/agent-1/user-files/inbox/lark/message-1/hello.txt'),
        Buffer.from('/user_files/agent-1/user-files/inbox/lark/message-1/renamed.txt'),
        boolFrame(false)
      ])
      expect(existsSync(join(userFilesRoot, 'inbox/lark/message-1/hello.txt'))).toBe(false)
      expect(readFileSync(join(userFilesRoot, 'inbox/lark/message-1/renamed.txt'), 'utf8')).toBe('hello world')

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('DELETE'),
        Buffer.from('delete-1'),
        Buffer.from('/user_files/agent-1/user-files/inbox/lark/message-1/renamed.txt'),
        boolFrame(false)
      ])
      expect(existsSync(join(userFilesRoot, 'inbox/lark/message-1/renamed.txt'))).toBe(false)
      expect(JSON.stringify(sentFrames)).not.toContain('sha256')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('overwrites with rename without deleting the target before a failed move', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-move-overwrite-'))
    const config = workerConfigForRoot(root)
    const sentFrames: Buffer[][] = []
    const lane = createFileTransferLane(config, async frames => {
      sentFrames.push(frames)
    })

    try {
      const userFilesRoot = agentHomePaths(config.agentsRoot, 'agent-1').userFiles
      mkdirSync(join(userFilesRoot, 'replace'), { recursive: true })
      writeFileSync(join(userFilesRoot, 'replace/source.txt'), 'new content')
      writeFileSync(join(userFilesRoot, 'replace/target.txt'), 'old content')

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('MOVE'),
        Buffer.from('move-overwrite-file'),
        Buffer.from('/user_files/agent-1/user-files/replace/source.txt'),
        Buffer.from('/user_files/agent-1/user-files/replace/target.txt'),
        boolFrame(true)
      ])

      frameFor(sentFrames, 'move-overwrite-file', 'MOVE_OK')
      expect(existsSync(join(userFilesRoot, 'replace/source.txt'))).toBe(false)
      expect(readFileSync(join(userFilesRoot, 'replace/target.txt'), 'utf8')).toBe('new content')

      mkdirSync(join(userFilesRoot, 'replace/source-dir'), { recursive: true })
      mkdirSync(join(userFilesRoot, 'replace/target-dir'), { recursive: true })
      writeFileSync(join(userFilesRoot, 'replace/source-dir/source.txt'), 'source content')
      writeFileSync(join(userFilesRoot, 'replace/target-dir/target.txt'), 'target content')

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('MOVE'),
        Buffer.from('move-overwrite-directory'),
        Buffer.from('/user_files/agent-1/user-files/replace/source-dir'),
        Buffer.from('/user_files/agent-1/user-files/replace/target-dir'),
        boolFrame(true)
      ])

      expect(errorMessageFor(sentFrames, 'move-overwrite-directory')).not.toBe('')
      expect(readFileSync(join(userFilesRoot, 'replace/source-dir/source.txt'), 'utf8')).toBe('source content')
      expect(readFileSync(join(userFilesRoot, 'replace/target-dir/target.txt'), 'utf8')).toBe('target content')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects unsafe file lane paths and transfer ids while allowing Agent-scoped lists', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-paths-'))
    const config = workerConfigForRoot(root)
    const sentFrames: Buffer[][] = []
    const lane = createFileTransferLane(config, async frames => {
      sentFrames.push(frames)
    })

    try {
      const paths = agentHomePaths(config.agentsRoot, 'agent-1')
      mkdirSync(paths.userFiles, { recursive: true })
      mkdirSync(paths.installedSkills, { recursive: true })

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('LIST'),
        Buffer.from('list-root'),
        Buffer.from('/user_files/agent-1/user-files'),
        boolFrame(false),
        u64Frame(1000)
      ])
      expect(frameFor(sentFrames, 'list-root', 'LIST_OK')[3]?.toString('utf8')).toBe('/user_files/agent-1/user-files')

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('STAT'),
        Buffer.from('absolute-path'),
        Buffer.from('/user_files//tmp/escape.txt'),
        Buffer.from('none')
      ])
      expect(errorMessageFor(sentFrames, 'absolute-path')).toMatch(/relative_path must not be absolute/)

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('STAT'),
        Buffer.from('parent-path'),
        Buffer.from('/user_files/../escape.txt'),
        Buffer.from('none')
      ])
      expect(errorMessageFor(sentFrames, 'parent-path')).toMatch(/invalid relative_path/)

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('STAT'),
        Buffer.from('bad-root'),
        Buffer.from('/unsupported/file.txt'),
        Buffer.from('none')
      ])
      expect(errorMessageFor(sentFrames, 'bad-root')).toMatch(/unsupported file root/)

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('WRITE_OPEN'),
        Buffer.from('../bad-transfer'),
        Buffer.from('/user_files/agent-1/user-files/safe.txt'),
        u64Frame(0)
      ])
      expect(errorMessageFor(sentFrames, '../bad-transfer')).toMatch(/invalid transfer_id/)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects file lane symlinks that resolve outside their configured root', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-symlink-'))
    const config = workerConfigForRoot(root)
    const sentFrames: Buffer[][] = []
    const lane = createFileTransferLane(config, async frames => {
      sentFrames.push(frames)
    })

    try {
      const userFilesRoot = agentHomePaths(config.agentsRoot, 'agent-1').userFiles
      mkdirSync(userFilesRoot, { recursive: true })
      const outsidePath = join(root, 'outside.txt')
      writeFileSync(outsidePath, 'secret')
      symlinkSync(outsidePath, join(userFilesRoot, 'escaped.txt'))

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('STAT'),
        Buffer.from('symlink-escape'),
        Buffer.from('/user_files/agent-1/user-files/escaped.txt'),
        Buffer.from('none')
      ])

      expect(errorMessageFor(sentFrames, 'symlink-escape')).toMatch(/path resolves outside root/)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('resolves the agent_sessions root and round-trips LIST and STAT', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-sessions-'))
    const config = workerConfigForRoot(root)
    const sentFrames: Buffer[][] = []
    const lane = createFileTransferLane(config, async frames => {
      sentFrames.push(frames)
    })

    try {
      const sessionsRoot = agentHomePaths(config.agentsRoot, 'agent-1').sessions
      mkdirSync(join(sessionsRoot, 'session-1'), {
        recursive: true
      })
      writeFileSync(join(sessionsRoot, 'session-1/log.txt'), 'logs')

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('LIST'),
        Buffer.from('list-sessions'),
        Buffer.from('/agent_sessions/agent-1/sessions'),
        boolFrame(true),
        u64Frame(1000)
      ])
      const listFrame = frameFor(sentFrames, 'list-sessions', 'LIST_OK')
      expect(listFrame[3]?.toString('utf8')).toBe('/agent_sessions/agent-1/sessions')
      const entries = decodeEntries(listFrame[6]!)
      expect(entries).toContainEqual(
        expect.objectContaining({
          relative_path: 'agent-1/sessions/session-1/log.txt',
          kind: 'file',
          size: 4
        })
      )

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('STAT'),
        Buffer.from('stat-sessions'),
        Buffer.from('/agent_sessions/agent-1/sessions/session-1/log.txt'),
        Buffer.from('xxh3_128')
      ])
      const statFrame = frameFor(sentFrames, 'stat-sessions', 'STAT_OK')
      expect(statFrame[3]?.toString('utf8')).toBe('/agent_sessions/agent-1/sessions/session-1/log.txt')
      expect(readU64Frame(statFrame[5])).toBe(4)

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('STAT'),
        Buffer.from('unknown-root'),
        Buffer.from('/shared_files/a.txt'),
        Buffer.from('none')
      ])
      expect(errorMessageFor(sentFrames, 'unknown-root')).toMatch(/unsupported file root/)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function workerConfig(): WorkerConfig {
  return {
    endpoint: 'tcp://127.0.0.1:6010',
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
    endpoint: 'tcp://127.0.0.1:6010',
    workerAuthKey: 'secret',
    workerID: 'worker-a',
    incarnationID: 'incarnation-a',
    agentsRoot: join(root, 'agents'),
    builtinSkillsRoot: join(root, 'builtin-skills'),
    maxConcurrentTurns: 9
  }
}

const creditWindow = 4 * 1024 * 1024

function frameFor(frames: Buffer[][], transferID: string, command: string): Buffer[] {
  const frameSet = frames.find(
    frame => frame[1]?.toString('utf8') === command && frame[2]?.toString('utf8') === transferID
  )
  expect(frameSet, `missing ${command} for ${transferID}`).toBeTruthy()
  return frameSet!
}

function errorMessageFor(frames: Buffer[][], transferID: string): string {
  return frameFor(frames, transferID, 'ERROR')[4]?.toString('utf8') ?? ''
}

async function waitForFrame(
  frames: Buffer[][],
  transferID: string,
  command: string,
  timeoutMs = 1000
): Promise<Buffer[]> {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    const matches = frames.filter(
      frame => frame[1]?.toString('utf8') === command && frame[2]?.toString('utf8') === transferID
    )
    if (matches.length > 0) return matches.at(-1)!
    await Bun.sleep(5)
  }

  throw new Error(`missing ${command} for ${transferID}`)
}

function dataChunks(frames: Buffer[][], transferID: string): Buffer[] {
  return frames
    .filter(frame => frame[1]?.toString('utf8') === 'DATA' && frame[2]?.toString('utf8') === transferID)
    .map(frame => frame[6] ?? Buffer.alloc(0))
}

function u64Frame(value: number): Buffer {
  const frame = Buffer.alloc(8)
  frame.writeBigUInt64BE(BigInt(value))
  return frame
}

function readU64Frame(frame: Buffer | undefined): number {
  expect(frame).toBeTruthy()
  return Number(frame!.readBigUInt64BE())
}

function boolFrame(value: boolean): Buffer {
  return Buffer.from([value ? 1 : 0])
}

function decodeEntries(frame: Buffer): Array<JSONObject> {
  let offset = 0
  const count = frame.readUInt32BE(offset)
  offset += 4
  const entries: Array<JSONObject> = []

  for (let index = 0; index < count; index += 1) {
    const relativePath = readSizedString(frame, offset)
    offset = relativePath.offset
    const kind = readSizedString(frame, offset)
    offset = kind.offset
    const size = Number(frame.readBigUInt64BE(offset))
    offset += 8
    const modified = Number(frame.readBigUInt64BE(offset))
    offset += 8
    entries.push({
      relative_path: relativePath.value,
      kind: kind.value,
      size,
      modified_unix_ms: modified
    })
  }

  return entries
}

function readSizedString(frame: Buffer, offset: number): { value: string; offset: number } {
  const size = frame.readUInt32BE(offset)
  const start = offset + 4
  const end = start + size
  return { value: frame.subarray(start, end).toString('utf8'), offset: end }
}
