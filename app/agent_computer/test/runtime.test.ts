import { describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { zstdCompressBlock, zstdDecompressBlock } from '@ankole/kernel'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { ActorTurnRef } from '../src/actor_lane'
import { createFileTransferState, fileTransferProtocol, handleFileTransferFrame } from '../src/file_transfer_lane'
import { finalProposalEnvelope } from '../src/turn_envelopes'
import { encodeEnvelope } from '../src/runtime_fabric'
import {
  parseRuntimeFabricUrl,
  workerCapacityEnvelope,
  workerHeartbeatEnvelope,
  workerReadyEnvelope
} from '../src/runtime'
import { handleWorkerRpcRequest, rpcMethods, type RpcRequest } from '../src/rpc_lane'
import { isRuntimeFabricBackpressure, reliableEnvelopeSender } from '../src/runtime_fabric_sender'
import type { WorkerConfig } from '../src/runtime'
import { prepareTurnWorkspace } from '../src/workspace'

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
      available_turn_slots: 1
    })
    expect(capacity.body.worker_capacity as { available_turn_slots: number }).toMatchObject({
      available_turn_slots: 1
    })
    expect(encodeEnvelope(ready)).toBeInstanceOf(Buffer)
    expect(encodeEnvelope(heartbeat)).toBeInstanceOf(Buffer)
    expect(encodeEnvelope(capacity)).toBeInstanceOf(Buffer)
  })

  it('prepares session workspace without projecting enabled skills', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-workspace-'))
    try {
      const config = workerConfigForRoot(root)
      mkdirSync(config.userFilesRoot, { recursive: true })

      const workspaceRoot = prepareTurnWorkspace(config, {
        turn: {
          actor: { agent_uid: 'agent-1', session_id: 'session-1' },
          activation_uid: 'activation-1',
          actor_epoch: 1,
          llm_turn_id: 'turn-1',
          revision: 0
        },
        inputs: [],
        model_ref: { profile: 'primary', provider_id: 'openrouter-main', model: 'z-ai/glm-5.2' }
      })

      expect(existsSync(join(workspaceRoot, 'temp'))).toBe(true)
      expect(existsSync(join(workspaceRoot, 'user-files'))).toBe(true)
      expect(existsSync(join(workspaceRoot, 'library-containers'))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('retries transient RuntimeFabric backpressure without hiding permanent send errors', async () => {
    const envelope = workerReadyEnvelope(workerConfig())
    let attempts = 0

    const sender = reliableEnvelopeSender(
      () => {
        attempts += 1
        if (attempts < 3) {
          throw new Error('backpressure')
        }
      },
      { initialDelayMs: 1, maxDelayMs: 1, maxAttempts: 4 }
    )

    await sender(envelope)
    expect(attempts).toBe(3)
    expect(isRuntimeFabricBackpressure(new Error('backpressure'))).toBe(true)

    let nonRetryAttempts = 0
    const nonRetryingSender = reliableEnvelopeSender(
      () => {
        nonRetryAttempts += 1
        throw new Error('socket_closed')
      },
      { initialDelayMs: 1, maxDelayMs: 1, maxAttempts: 4 }
    )

    await expect(nonRetryingSender(envelope)).rejects.toThrow('socket_closed')
    expect(nonRetryAttempts).toBe(1)
  })

  it('answers control-plane-initiated worker RPC requests', async () => {
    const sent: ReturnType<typeof workerReadyEnvelope>[] = []
    const request: RpcRequest = {
      request_id: 'worker-rpc-1',
      method: rpcMethods.workerRuntimeDescribe,
      payload_json: {}
    }

    await handleWorkerRpcRequest(
      workerConfig(),
      async envelope => {
        sent.push(envelope)
      },
      2,
      request
    )

    expect(sent).toHaveLength(1)
    expect(sent[0]!.lane).toBe('LANE_RPC')
    expect(sent[0]!.correlation_id).toBe('worker-rpc-1')
    expect(sent[0]!.body.type).toBe('rpc_response')
    expect(sent[0]!.body.rpc_response).toMatchObject({
      request_id: 'worker-rpc-1',
      payload_json: {
        worker_id: 'worker-a',
        runtime: 'bun',
        active_turns: 2
      }
    })
    expect(encodeEnvelope(sent[0]!)).toBeInstanceOf(Buffer)
  })

  it('returns RPC errors for unknown worker methods', async () => {
    const sent: ReturnType<typeof workerReadyEnvelope>[] = []

    await handleWorkerRpcRequest(
      workerConfig(),
      async envelope => {
        sent.push(envelope)
      },
      0,
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
    expect(encodeEnvelope(sent[0]!)).toBeInstanceOf(Buffer)
  })

  it('includes final proposal telemetry fields in durable envelopes', () => {
    const turn: ActorTurnRef = {
      actor: { agent_uid: 'agent-1', session_id: 'signal-channel:chat-1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      llm_turn_id: 'turn-telemetry-1',
      revision: 0
    }

    const envelope = finalProposalEnvelope(
      turn,
      {
        messages: [],
        reply: { text: 'done' },
        usage_json: { input: 11, output: 7, totalTokens: 18 },
        provider_metadata_json: { response_id: 'resp_123', response_model: 'google/gemini-3.5-flash' },
        stop_reason: 'stop',
        tool_results_json: [{ tool_call_id: 'call_1', tool_name: 'command', is_error: false }]
      },
      'turn-start-telemetry-1'
    )

    expect(envelope.body.type).toBe('turn_final_proposal')
    expect(envelope.body.turn_final_proposal).toMatchObject({
      usage_json: { input: 11, output: 7, totalTokens: 18 },
      provider_metadata_json: { response_id: 'resp_123', response_model: 'google/gemini-3.5-flash' },
      stop_reason: 'stop',
      tool_results_json: [{ tool_call_id: 'call_1', tool_name: 'command', is_error: false }]
    })
    expect(envelope.correlation_id).toBe('turn-start-telemetry-1')
    expect(encodeEnvelope(envelope)).toBeInstanceOf(Buffer)
  })

  it('handles worker file lane WRITE and READ through zstd DATA credit', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-'))
    const config = workerConfigForRoot(root)
    const sentFrames: Buffer[][] = []
    const sender = {
      sendFileFrame(frames: Buffer[]) {
        sentFrames.push(frames)
        return 'sent_or_queued'
      }
    }

    try {
      mkdirSync(config.sharedFsRoot, { recursive: true })
      mkdirSync(config.userFilesRoot, { recursive: true })
      mkdirSync(config.agentInstalledSkillsRoot, { recursive: true })
      mkdirSync(config.workspaceSessionsRoot, { recursive: true })
      mkdirSync(config.builtinSkillsRoot, { recursive: true })

      const state = createFileTransferState()
      const plainText = 'hello zstd world'
      const sourcePath = join(root, 'source.txt')
      writeFileSync(sourcePath, plainText)
      const compressed = await zstdCompressBlock(Buffer.from(plainText), 3)

      const transferId = 'transfer-1'
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('WRITE_OPEN'),
        Buffer.from(transferId),
        Buffer.from('/user_files/inbox/lark/message-1/hello.txt'),
        u64Frame(Buffer.byteLength(plainText))
      ])
      expect(frameFor(sentFrames, transferId, 'WRITE_READY')[3]).toEqual(u64Frame(creditWindow))

      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('DATA'),
        Buffer.from(transferId),
        u64Frame(0),
        u64Frame(0),
        boolFrame(true),
        compressed
      ])
      expect(frameFor(sentFrames, transferId, 'CREDIT')[3]).toEqual(u64Frame(compressed.byteLength))

      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('WRITE_COMMIT'),
        Buffer.from(transferId)
      ])

      expect(readFileSync(join(config.userFilesRoot, 'inbox/lark/message-1/hello.txt'), 'utf8')).toBe(plainText)
      const committed = frameFor(sentFrames, transferId, 'WRITE_COMMITTED')
      expect(committed[3]?.toString('utf8')).toBe('/user_files/inbox/lark/message-1/hello.txt')
      expect(readU64Frame(committed[4])).toBe(Buffer.byteLength(plainText))
      expect(committed[5]?.toString('utf8')).toMatch(/^[a-f0-9]{32}$/)

      const getTransferId = 'transfer-2'
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
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

      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
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
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('READ_OPEN'),
        Buffer.from(abortTransferId),
        Buffer.from('/user_files/inbox/lark/message-1/hello.txt'),
        Buffer.from('none')
      ])
      expect(frameFor(sentFrames, abortTransferId, 'READ_READY')[3]?.toString('utf8')).toBe(
        '/user_files/inbox/lark/message-1/hello.txt'
      )
      expect(state.gets.has(abortTransferId)).toBe(true)
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('READ_ABORT'),
        Buffer.from(abortTransferId)
      ])
      expect(state.gets.has(abortTransferId)).toBe(false)
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
      sendFileFrame(frames: Buffer[]) {
        sentFrames.push(frames)
        return 'sent_or_queued'
      }
    }

    try {
      mkdirSync(join(config.userFilesRoot, 'inbox/lark/message-1'), { recursive: true })
      writeFileSync(join(config.userFilesRoot, 'inbox/lark/message-1/hello.txt'), 'hello world')

      const state = createFileTransferState()
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
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

      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('STAT'),
        Buffer.from('stat-1'),
        Buffer.from('/user_files/inbox/lark/message-1/hello.txt'),
        Buffer.from('xxh3_128')
      ])
      expect(frameFor(sentFrames, 'stat-1', 'STAT_OK')[7]?.toString('utf8')).toMatch(/^[a-f0-9]{32}$/)

      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('MOVE'),
        Buffer.from('move-1'),
        Buffer.from('/user_files/inbox/lark/message-1/hello.txt'),
        Buffer.from('/user_files/inbox/lark/message-1/renamed.txt'),
        boolFrame(false)
      ])
      expect(existsSync(join(config.userFilesRoot, 'inbox/lark/message-1/hello.txt'))).toBe(false)
      expect(readFileSync(join(config.userFilesRoot, 'inbox/lark/message-1/renamed.txt'), 'utf8')).toBe('hello world')

      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
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
    builtinSkillsRoot: '/repo/app/library/skills'
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
    builtinSkillsRoot: join(root, 'builtin-skills')
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

function decodeEntries(frame: Buffer): Array<Record<string, unknown>> {
  let offset = 0
  const count = frame.readUInt32BE(offset)
  offset += 4
  const entries: Array<Record<string, unknown>> = []

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
