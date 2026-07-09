import { describe, expect, it } from 'bun:test'
import type { JsonObject } from '@pleisto/active-support'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { runtimeFabricEncodeEnvelope, zstdCompressBlock, zstdDecompressBlock } from '@ankole/kernel'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createFileTransferLane } from '../src/lanes/file'
import { runtimeFabricFileProtocol } from '../src/fabric/fabric'
import {
  parseRuntimeFabricUrl,
  workerCapacityEnvelope,
  workerHeartbeatEnvelope,
  workerReadyEnvelope
} from '../src/worker/config'
import { handleWorkerRpcRequest, type RpcRequest } from '../src/lanes/rpc_lane'
import { workerProgressEnvelope } from '../src/fabric/envelopes'
import type { WorkerConfig } from '../src/worker/config'
import { prepareTurnWorkspace } from '../src/worker/workspace'
import { mailboxUpdatedFromEnvelope, turnStartFromEnvelope } from '../src/lanes/actor_lane'
import type { TurnStart } from '../src/lanes/actor_lane'
import { startTurnProgress, type ActiveTurn } from '../src/worker/active_turns'

describe('@ankole/agent-computer runtime', () => {
  it('parses RuntimeFabric URL auth without embedding worker identity', () => {
    expect(parseRuntimeFabricUrl('tcp://:secret@127.0.0.1:6010')).toMatchObject({
      workerAuthKey: 'secret',
      endpoint: 'tcp://127.0.0.1:6010'
    })

    expect(() => parseRuntimeFabricUrl('tcp://worker-a:secret@127.0.0.1:6010')).toThrow(/username/)
    expect(() => parseRuntimeFabricUrl('tcp://127.0.0.1:6010')).toThrow(/worker auth key/)

    expect(() => parseRuntimeFabricUrl('http://:secret@127.0.0.1:6010')).toThrow(/tcp/)
  })

  it('emits worker.ready without actor authority fields', () => {
    const config = workerConfig()
    const ready = workerReadyEnvelope(config)
    const heartbeat = workerHeartbeatEnvelope(config, 123)
    const capacity = workerCapacityEnvelope(config)

    expect(ready.body.type).toBe('worker_ready')
    expect(heartbeat.body.type).toBe('worker_heartbeat')
    expect(capacity.body.type).toBe('worker_capacity')
    expect(JSON.stringify(ready)).not.toContain('agent_uid')
    expect(JSON.stringify(ready)).not.toContain('actor_epoch')
    expect((ready.body.worker_ready as { capacity_json: unknown }).capacity_json).toMatchObject({
      max_turns: 9,
      available_turn_slots: 9
    })
    expect(capacity.body.worker_capacity as { available_turn_slots: number }).toMatchObject({
      available_turn_slots: 9
    })
    expect(runtimeFabricEncodeEnvelope(ready)).toBeInstanceOf(Buffer)
    expect(runtimeFabricEncodeEnvelope(heartbeat)).toBeInstanceOf(Buffer)
    expect(runtimeFabricEncodeEnvelope(capacity)).toBeInstanceOf(Buffer)
  })

  it('reports available capacity from configured concurrent turn slots', () => {
    const config = { ...workerConfig(), maxConcurrentTurns: 3 }
    const capacity = workerCapacityEnvelope(config, 1, 2)

    expect(capacity.body.worker_capacity).toMatchObject({
      available_turn_slots: 1,
      capacity_json: {
        max_turns: 3,
        available_turn_slots: 1
      },
      load_json: {
        active_turns: 2
      }
    })
  })

  it('emits worker progress as an ephemeral progress-lane keepalive', () => {
    const turn = actorTurnRef()
    const envelope = workerProgressEnvelope(turn, 'checkpoint', 'turn in progress', 'turn-start-1', {
      stage: 'llm'
    })

    expect(envelope.lane).toBe('LANE_PROGRESS')
    expect(envelope.durability).toBe('CONTROL_EPHEMERAL')
    expect(envelope.correlation_id).toBe('turn-start-1')
    expect(envelope.body.type).toBe('worker_progress')
    expect(envelope.body.worker_progress).toMatchObject({
      turn,
      kind: 'checkpoint',
      summary: 'turn in progress',
      refs_json: { stage: 'llm' }
    })
    expect(runtimeFabricEncodeEnvelope(envelope)).toBeInstanceOf(Buffer)
  })

  it('renews subagent progress only after observed runtime activity', async () => {
    const sent: unknown[] = []
    const active = {
      turnStart: { turn: actorTurnRef() } as TurnStart,
      correlationId: 'turn-start-1',
      steeringUpdates: [],
      abortController: new AbortController(),
      controlledStopRequested: false
    } satisfies ActiveTurn
    const reporter = startTurnProgress(
      async envelope => {
        sent.push(envelope)
      },
      active,
      { requireActivity: true, intervalMs: 5 }
    )

    await Bun.sleep(14)
    expect(sent).toHaveLength(1)

    reporter.touch('codex:agent_delta')
    await Bun.sleep(8)
    expect(sent).toHaveLength(2)

    await Bun.sleep(14)
    expect(sent).toHaveLength(2)
    reporter.stop()
  })

  it('prepares session workspace without projecting enabled skills', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-workspace-'))
    const actorEventId = '00000000-0000-0000-0000-000000000101'

    try {
      const config = workerConfigForRoot(root)
      mkdirSync(config.userFilesRoot, { recursive: true })

      const workspaceRoot = prepareTurnWorkspace(config, {
        turn: {
          actor: { agent_uid: 'agent-1', session_id: 'session-1' },
          activation_uid: 'activation-1',
          actor_epoch: 1,
          actor_event_id: actorEventId,
          revision: 0
        },
        actor_event: {
          actor_event_id: actorEventId,
          queue_sequence: 1,
          type: 'im.message.addressed',
          source_event_id: 'signal-entry-1',
          payload_json: {}
        },
        model_ref: { profile: 'primary', provider_id: 'openrouter-main', model: 'z-ai/glm-5.2' }
      })

      expect(existsSync(join(workspaceRoot, 'temp'))).toBe(true)
      expect(existsSync(join(workspaceRoot, 'user-files'))).toBe(true)
      expect(existsSync(join(workspaceRoot, 'library-containers'))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects mailbox updates without the journaled actor event', () => {
    expect(() =>
      mailboxUpdatedFromEnvelope({
        protocol_version: 1,
        message_id: 'mailbox-updated-missing-event',
        correlation_id: 'mailbox-updated-missing-event',
        lane: 'LANE_TURN',
        durability: 'CONTROL_EPHEMERAL',
        body: {
          type: 'mailbox_updated',
          mailbox_updated: {
            turn: {
              actor: { agent_uid: 'agent-1', session_id: 'session-1' },
              activation_uid: 'activation-1',
              actor_epoch: 1,
              actor_event_id: '00000000-0000-0000-0000-000000000001',
              revision: 1
            },
            reason: 'command.steer'
          }
        }
      })
    ).toThrow(/mailbox_updated\.actor_event is required/)
  })

  it('rejects turn_start envelopes without a durable turn fence', () => {
    expect(() =>
      turnStartFromEnvelope({
        protocol_version: 1,
        message_id: 'turn-start-missing-turn',
        lane: 'LANE_TURN',
        durability: 'CONTROL_DURABLE',
        body: {
          type: 'turn_start',
          turn_start: {
            actor_event: {
              actor_event_id: '00000000-0000-0000-0000-000000000001',
              queue_sequence: 1,
              type: 'im.message.addressed',
              source_event_id: 'source-1'
            }
          }
        }
      })
    ).toThrow(/turn_start\.turn is required/)
  })

  it('rejects unknown control-plane-initiated worker RPC requests', async () => {
    const sent: ReturnType<typeof workerReadyEnvelope>[] = []
    const request: RpcRequest = {
      request_id: 'worker-rpc-1',
      method: 'test.probe',
      payload_json: { probe: true }
    }

    await handleWorkerRpcRequest(async envelope => {
      sent.push(envelope)
    }, request)

    expect(sent).toHaveLength(1)
    expect(sent[0]!.lane).toBe('LANE_RPC')
    expect(sent[0]!.correlation_id).toBe('worker-rpc-1')
    expect(sent[0]!.body.type).toBe('rpc_error')
    expect(sent[0]!.body.rpc_error).toMatchObject({
      request_id: 'worker-rpc-1',
      code: 'unknown_rpc_method',
      details_json: { method: 'test.probe' }
    })
    expect(runtimeFabricEncodeEnvelope(sent[0]!)).toBeInstanceOf(Buffer)
  })

  it('returns RPC errors for unknown worker methods', async () => {
    const sent: ReturnType<typeof workerReadyEnvelope>[] = []

    await handleWorkerRpcRequest(
      async envelope => {
        sent.push(envelope)
      },
      {
        request_id: 'worker-rpc-unknown',
        method: 'worker.unknown',
        payload_json: {}
      }
    )

    expect(sent).toHaveLength(1)
    expect(sent[0]!.body.type).toBe('rpc_error')
    expect(sent[0]!.body.rpc_error).toMatchObject({
      request_id: 'worker-rpc-unknown',
      code: 'unknown_rpc_method',
      details_json: { method: 'worker.unknown' }
    })
    expect(runtimeFabricEncodeEnvelope(sent[0]!)).toBeInstanceOf(Buffer)
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
      mkdirSync(config.sharedFsRoot, { recursive: true })
      mkdirSync(config.userFilesRoot, { recursive: true })
      mkdirSync(config.agentInstalledSkillsRoot, { recursive: true })
      mkdirSync(config.workspaceSessionsRoot, { recursive: true })
      mkdirSync(config.builtinSkillsRoot, { recursive: true })

      const lane = createFileTransferLane(config, sender.sendFileFrame)
      const plainText = 'hello zstd world'
      const sourcePath = join(root, 'source.txt')
      writeFileSync(sourcePath, plainText)
      const compressed = await zstdCompressBlock(Buffer.from(plainText), 3)

      const transferId = 'transfer-1'
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('WRITE_OPEN'),
        Buffer.from(transferId),
        Buffer.from('/user_files/inbox/lark/message-1/hello.txt'),
        u64Frame(Buffer.byteLength(plainText))
      ])
      expect(frameFor(sentFrames, transferId, 'WRITE_READY')[3]).toEqual(u64Frame(creditWindow))

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('DATA'),
        Buffer.from(transferId),
        u64Frame(0),
        u64Frame(0),
        boolFrame(true),
        compressed
      ])
      expect(frameFor(sentFrames, transferId, 'CREDIT')[3]).toEqual(u64Frame(compressed.byteLength))

      await lane.handle([runtimeFabricFileProtocol, Buffer.from('WRITE_COMMIT'), Buffer.from(transferId)])

      expect(readFileSync(join(config.userFilesRoot, 'inbox/lark/message-1/hello.txt'), 'utf8')).toBe(plainText)
      const committed = frameFor(sentFrames, transferId, 'WRITE_COMMITTED')
      expect(committed[3]?.toString('utf8')).toBe('/user_files/inbox/lark/message-1/hello.txt')
      expect(readU64Frame(committed[4])).toBe(Buffer.byteLength(plainText))
      expect(committed[5]?.toString('utf8')).toMatch(/^[a-f0-9]{32}$/)

      const getTransferId = 'transfer-2'
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('READ_OPEN'),
        Buffer.from(getTransferId),
        Buffer.from('/user_files/inbox/lark/message-1/hello.txt'),
        Buffer.from('xxh3_128')
      ])
      const readReady = frameFor(sentFrames, getTransferId, 'READ_READY')
      expect(readReady[3]?.toString('utf8')).toBe('/user_files/inbox/lark/message-1/hello.txt')
      expect(readU64Frame(readReady[4])).toBe(Buffer.byteLength(plainText))
      await Bun.sleep(25)
      expect(dataChunks(sentFrames, getTransferId)).toHaveLength(0)

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('CREDIT'),
        Buffer.from(getTransferId),
        u64Frame(creditWindow)
      ])

      const readDone = await waitForFrame(sentFrames, getTransferId, 'READ_DONE')
      const getChunks = dataChunks(sentFrames, getTransferId)
      const decompressed = Buffer.concat(
        await Promise.all(getChunks.map(chunk => zstdDecompressBlock(chunk, 2 * 1024 * 1024)))
      )
      expect(decompressed.toString('utf8')).toBe(plainText)
      expect(readU64Frame(readDone[3])).toBe(getChunks.length)
      expect(readU64Frame(readDone[4])).toBe(Buffer.concat(getChunks).byteLength)

      const abortTransferId = 'transfer-read-abort'
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('READ_OPEN'),
        Buffer.from(abortTransferId),
        Buffer.from('/user_files/inbox/lark/message-1/hello.txt'),
        Buffer.from('none')
      ])
      expect(frameFor(sentFrames, abortTransferId, 'READ_READY')[3]?.toString('utf8')).toBe(
        '/user_files/inbox/lark/message-1/hello.txt'
      )
      await lane.handle([runtimeFabricFileProtocol, Buffer.from('READ_ABORT'), Buffer.from(abortTransferId)])
      await lane.handle([runtimeFabricFileProtocol, Buffer.from('CREDIT'), Buffer.from(abortTransferId), u64Frame(1)])
      expect(frameFor(sentFrames, abortTransferId, 'ERROR')[3]?.toString('utf8')).toBe('operation_failed')
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
      mkdirSync(join(config.userFilesRoot, 'inbox/lark/message-1'), { recursive: true })
      writeFileSync(join(config.userFilesRoot, 'inbox/lark/message-1/hello.txt'), 'hello world')

      const lane = createFileTransferLane(config, sender.sendFileFrame)
      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('LIST'),
        Buffer.from('list-1'),
        Buffer.from('/user_files/inbox'),
        boolFrame(true),
        u64Frame(1000)
      ])
      const listFrame = frameFor(sentFrames, 'list-1', 'LIST_OK')
      const entries = decodeEntries(listFrame[6]!)
      expect(entries).toContainEqual(
        expect.objectContaining({
          relative_path: 'inbox/lark/message-1/hello.txt',
          kind: 'file',
          size: 11
        })
      )

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('STAT'),
        Buffer.from('stat-1'),
        Buffer.from('/user_files/inbox/lark/message-1/hello.txt'),
        Buffer.from('xxh3_128')
      ])
      expect(frameFor(sentFrames, 'stat-1', 'STAT_OK')[7]?.toString('utf8')).toMatch(/^[a-f0-9]{32}$/)

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('MOVE'),
        Buffer.from('move-1'),
        Buffer.from('/user_files/inbox/lark/message-1/hello.txt'),
        Buffer.from('/user_files/inbox/lark/message-1/renamed.txt'),
        boolFrame(false)
      ])
      expect(existsSync(join(config.userFilesRoot, 'inbox/lark/message-1/hello.txt'))).toBe(false)
      expect(readFileSync(join(config.userFilesRoot, 'inbox/lark/message-1/renamed.txt'), 'utf8')).toBe('hello world')

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('DELETE'),
        Buffer.from('delete-1'),
        Buffer.from('/user_files/inbox/lark/message-1/renamed.txt'),
        boolFrame(false)
      ])
      expect(existsSync(join(config.userFilesRoot, 'inbox/lark/message-1/renamed.txt'))).toBe(false)
      expect(JSON.stringify(sentFrames)).not.toContain('sha256')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects unsafe file lane paths and transfer ids while allowing root lists', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-paths-'))
    const config = workerConfigForRoot(root)
    const sentFrames: Buffer[][] = []
    const lane = createFileTransferLane(config, async frames => {
      sentFrames.push(frames)
    })

    try {
      mkdirSync(config.userFilesRoot, { recursive: true })
      mkdirSync(config.agentInstalledSkillsRoot, { recursive: true })

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('LIST'),
        Buffer.from('list-root'),
        Buffer.from('/user_files'),
        boolFrame(false),
        u64Frame(1000)
      ])
      expect(frameFor(sentFrames, 'list-root', 'LIST_OK')[3]?.toString('utf8')).toBe('/user_files')

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
        Buffer.from('/user_files/safe.txt'),
        u64Frame(0)
      ])
      expect(errorMessageFor(sentFrames, '../bad-transfer')).toMatch(/invalid transfer_id/)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('resolves the workspace_sessions root and round-trips LIST and STAT', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-sessions-'))
    const config = workerConfigForRoot(root)
    const sentFrames: Buffer[][] = []
    const lane = createFileTransferLane(config, async frames => {
      sentFrames.push(frames)
    })

    try {
      mkdirSync(join(config.workspaceSessionsRoot, 'agent-1/session-1'), { recursive: true })
      writeFileSync(join(config.workspaceSessionsRoot, 'agent-1/session-1/log.txt'), 'logs')

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('LIST'),
        Buffer.from('list-sessions'),
        Buffer.from('/workspace_sessions/agent-1'),
        boolFrame(true),
        u64Frame(1000)
      ])
      const listFrame = frameFor(sentFrames, 'list-sessions', 'LIST_OK')
      expect(listFrame[3]?.toString('utf8')).toBe('/workspace_sessions/agent-1')
      const entries = decodeEntries(listFrame[6]!)
      expect(entries).toContainEqual(
        expect.objectContaining({
          relative_path: 'agent-1/session-1/log.txt',
          kind: 'file',
          size: 4
        })
      )

      await lane.handle([
        runtimeFabricFileProtocol,
        Buffer.from('STAT'),
        Buffer.from('stat-sessions'),
        Buffer.from('/workspace_sessions/agent-1/session-1/log.txt'),
        Buffer.from('xxh3_128')
      ])
      const statFrame = frameFor(sentFrames, 'stat-sessions', 'STAT_OK')
      expect(statFrame[3]?.toString('utf8')).toBe('/workspace_sessions/agent-1/session-1/log.txt')
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
    workerId: 'worker-a',
    workspaceRoot: '/workspace',
    workspaceSessionsRoot: '/workspace/.sessions',
    sharedFsRoot: '/workspace/shared',
    userFilesRoot: '/workspace/shared/user-files',
    agentInstalledSkillsRoot: '/workspace/shared/skills/agents',
    builtinSkillsRoot: '/repo/app/library/skills',
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
    workerId: 'worker-a',
    workspaceRoot: join(root, 'workspace'),
    workspaceSessionsRoot: join(root, 'workspace/.sessions'),
    sharedFsRoot: join(root, 'shared'),
    userFilesRoot: join(root, 'shared/user-files'),
    agentInstalledSkillsRoot: join(root, 'shared/skills/agents'),
    builtinSkillsRoot: join(root, 'builtin-skills'),
    maxConcurrentTurns: 9
  }
}

const creditWindow = 4 * 1024 * 1024

function frameFor(frames: Buffer[][], transferId: string, command: string): Buffer[] {
  const frameSet = frames.find(
    frame => frame[1]?.toString('utf8') === command && frame[2]?.toString('utf8') === transferId
  )
  expect(frameSet, `missing ${command} for ${transferId}`).toBeTruthy()
  return frameSet!
}

function errorMessageFor(frames: Buffer[][], transferId: string): string {
  return frameFor(frames, transferId, 'ERROR')[4]?.toString('utf8') ?? ''
}

async function waitForFrame(
  frames: Buffer[][],
  transferId: string,
  command: string,
  timeoutMs = 1000
): Promise<Buffer[]> {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    const matches = frames.filter(
      frame => frame[1]?.toString('utf8') === command && frame[2]?.toString('utf8') === transferId
    )
    if (matches.length > 0) return matches.at(-1)!
    await Bun.sleep(5)
  }

  throw new Error(`missing ${command} for ${transferId}`)
}

function dataChunks(frames: Buffer[][], transferId: string): Buffer[] {
  return frames
    .filter(frame => frame[1]?.toString('utf8') === 'DATA' && frame[2]?.toString('utf8') === transferId)
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

function decodeEntries(frame: Buffer): Array<JsonObject> {
  let offset = 0
  const count = frame.readUInt32BE(offset)
  offset += 4
  const entries: Array<JsonObject> = []

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
