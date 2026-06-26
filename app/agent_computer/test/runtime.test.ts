import { describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { ActorTurnRef } from '../src/actor_lane'
import { createFileTransferState, fileTransferProtocol, handleFileTransferFrame } from '../src/file_transfer_lane'
import { finalProposalEnvelope } from '../src/turn_envelopes'
import { encodeEnvelope } from '../src/runtime_fabric'
import { parseWorkerEnv, workerCapacityEnvelope, workerHeartbeatEnvelope, workerReadyEnvelope } from '../src/runtime'
import { isRuntimeFabricBackpressure, reliableEnvelopeSender } from '../src/runtime_fabric_sender'
import type { WorkerConfig } from '../src/runtime'
import { prepareTurnWorkspace } from '../src/workspace'

describe('@ankole/agent-computer runtime', () => {
  it('parses worker env without actor-specific startup args', () => {
    expect(
      parseWorkerEnv(
        workerEnv({
          ANKOLE_RUNTIME_FABRIC_ENDPOINT: 'tcp://127.0.0.1:6010',
          ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN: 'secret',
          ANKOLE_AGENT_COMPUTER_WORKER_ID: 'worker-a',
          ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID: 'worker-a-1',
          ANKOLE_WORKSPACE_ROOT: '/workspace',
          ANKOLE_WORKSPACE_SESSIONS_ROOT: '/workspace/.sessions',
          ANKOLE_SHARED_FS_ROOT: '/workspace/shared',
          ANKOLE_USER_FILES_ROOT: '/workspace/shared/user-files',
          ANKOLE_AGENT_INSTALLED_SKILLS_ROOT: '/workspace/shared/skills/agents',
          ANKOLE_BUILTIN_SKILLS_ROOT: '/repo/app/library/skills'
        })
      )
    ).toMatchObject({
      workerId: 'worker-a',
      workerInstanceId: 'worker-a-1',
      workspaceRoot: '/workspace',
      workspaceSessionsRoot: '/workspace/.sessions',
      sharedFsRoot: '/workspace/shared'
    })

    expect(() =>
      parseWorkerEnv(
        workerEnv({
          ANKOLE_RUNTIME_FABRIC_ENDPOINT: 'tcp://127.0.0.1:6010',
          ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN: 'secret',
          ANKOLE_AGENT_COMPUTER_WORKER_ID: 'worker-a',
          ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID: 'worker-a-1',
          ANKOLE_AGENT_UID: 'agent-1'
        })
      )
    ).toThrow(/must not be set/)

    expect(() =>
      parseWorkerEnv(
        workerEnv({
          ANKOLE_RUNTIME_FABRIC_ENDPOINT: 'tcp://127.0.0.1:6010',
          ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN: 'secret',
          ANKOLE_AGENT_COMPUTER_WORKER_ID: 'worker-a',
          ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID: 'worker-a-1',
          DATABASE_URL: 'postgres://localhost/test'
        })
      )
    ).toThrow(/DATABASE_URL/)
  })

  it('rejects worker startup outside the Agent Computer Docker image', () => {
    expect(() =>
      parseWorkerEnv({
        ANKOLE_RUNTIME_FABRIC_ENDPOINT: 'tcp://127.0.0.1:6010',
        ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN: 'secret',
        ANKOLE_AGENT_COMPUTER_WORKER_ID: 'worker-a',
        ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID: 'worker-a-1'
      })
    ).toThrow(/Docker image/)
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

  it('handles worker file lane PUT and GET through root plus relative_path', async () => {
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
      const transferId = 'transfer-1'
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('PUT_BEGIN'),
        Buffer.from(transferId),
        Buffer.from(
          JSON.stringify({
            root: 'user_files',
            relative_path: 'inbox/lark/message-1/hello.txt',
            content_encoding: 'identity',
            original_size: 11
          })
        )
      ])
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('PUT_CHUNK'),
        Buffer.from(transferId),
        Buffer.from('0'),
        Buffer.from('hello world')
      ])
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('PUT_COMMIT'),
        Buffer.from(transferId)
      ])

      expect(readFileSync(join(config.userFilesRoot, 'inbox/lark/message-1/hello.txt'), 'utf8')).toBe('hello world')
      const putCommitAck = ackPayload(sentFrames, transferId, 'PUT_COMMIT')
      expect(putCommitAck.xxh3_128).toMatch(/^[a-f0-9]{32}$/)
      expect(JSON.stringify(putCommitAck)).not.toContain('sha256')

      const getTransferId = 'transfer-2'
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('GET'),
        Buffer.from(getTransferId),
        Buffer.from(
          JSON.stringify({
            root: 'user_files',
            relative_path: 'inbox/lark/message-1/hello.txt',
            content_encoding: 'identity'
          })
        )
      ])

      const chunks = sentFrames
        .filter(frames => frames[1]?.toString('utf8') === 'GET_CHUNK')
        .map(frames => frames[4]?.toString('utf8') ?? '')
        .join('')
      expect(chunks).toBe('hello world')
      const getBegin = payloadFor(sentFrames, getTransferId, 'GET_BEGIN')
      expect(getBegin.xxh3_128).toBe(putCommitAck.xxh3_128)
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
        Buffer.from(JSON.stringify({ root: 'user_files', relative_path: 'inbox', recursive: true }))
      ])
      const listPayload = payloadFor(sentFrames, 'list-1', 'LIST_RESULT')
      expect(listPayload.entries).toContainEqual(
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
        Buffer.from(
          JSON.stringify({
            root: 'user_files',
            relative_path: 'inbox/lark/message-1/hello.txt',
            fingerprint: 'xxh3_128'
          })
        )
      ])
      expect(ackPayload(sentFrames, 'stat-1', 'STAT').xxh3_128).toMatch(/^[a-f0-9]{32}$/)

      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('MOVE'),
        Buffer.from('move-1'),
        Buffer.from(
          JSON.stringify({
            root: 'user_files',
            from_relative_path: 'inbox/lark/message-1/hello.txt',
            to_relative_path: 'inbox/lark/message-1/renamed.txt'
          })
        )
      ])
      expect(existsSync(join(config.userFilesRoot, 'inbox/lark/message-1/hello.txt'))).toBe(false)
      expect(readFileSync(join(config.userFilesRoot, 'inbox/lark/message-1/renamed.txt'), 'utf8')).toBe('hello world')

      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('DELETE'),
        Buffer.from('delete-1'),
        Buffer.from(JSON.stringify({ root: 'user_files', relative_path: 'inbox/lark/message-1/renamed.txt' }))
      ])
      expect(existsSync(join(config.userFilesRoot, 'inbox/lark/message-1/renamed.txt'))).toBe(false)
      expect(JSON.stringify(sentFrames)).not.toContain('sha256')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('handles worker file lane zstd wire encoding without changing stored bytes', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-file-lane-zstd-'))
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

      const plainText = 'hello zstd world'
      const sourcePath = join(root, 'source.txt')
      writeFileSync(sourcePath, plainText)
      const compressed = spawnSync('zstd', ['-q', '-c', sourcePath])
      expect(compressed.status).toBe(0)

      const state = createFileTransferState()
      const transferId = 'transfer-zstd-put'
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('PUT_BEGIN'),
        Buffer.from(transferId),
        Buffer.from(
          JSON.stringify({
            root: 'user_files',
            relative_path: 'inbox/lark/message-1/zstd.txt',
            content_encoding: 'zstd',
            original_size: Buffer.byteLength(plainText)
          })
        )
      ])
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('PUT_CHUNK'),
        Buffer.from(transferId),
        Buffer.from('0'),
        compressed.stdout
      ])
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('PUT_COMMIT'),
        Buffer.from(transferId)
      ])

      expect(readFileSync(join(config.userFilesRoot, 'inbox/lark/message-1/zstd.txt'), 'utf8')).toBe(plainText)

      const getTransferId = 'transfer-zstd-get'
      await handleFileTransferFrame(config, sender, state, [
        fileTransferProtocol,
        Buffer.from('GET'),
        Buffer.from(getTransferId),
        Buffer.from(
          JSON.stringify({
            root: 'user_files',
            relative_path: 'inbox/lark/message-1/zstd.txt',
            content_encoding: 'zstd'
          })
        )
      ])

      const compressedGet = Buffer.concat(
        sentFrames
          .filter(frames => frames[1]?.toString('utf8') === 'GET_CHUNK')
          .filter(frames => frames[2]?.toString('utf8') === getTransferId)
          .map(frames => frames[4] ?? Buffer.alloc(0))
      )
      const decompressed = spawnSync('zstd', ['-q', '-d', '-c'], { input: compressedGet })
      expect(decompressed.status).toBe(0)
      expect(decompressed.stdout.toString('utf8')).toBe(plainText)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function workerConfig(): WorkerConfig {
  return {
    endpoint: 'tcp://127.0.0.1:6010',
    preAuthToken: 'secret',
    workerId: 'worker-a',
    workerInstanceId: 'worker-a-1',
    workspaceRoot: '/workspace',
    workspaceSessionsRoot: '/workspace/.sessions',
    sharedFsRoot: '/workspace/shared',
    userFilesRoot: '/workspace/shared/user-files',
    agentInstalledSkillsRoot: '/workspace/shared/skills/agents',
    builtinSkillsRoot: '/repo/app/library/skills'
  }
}

function workerEnv(env: Record<string, string>): Record<string, string> {
  return {
    ANKOLE_AGENT_COMPUTER_CONTAINER: '1',
    ...env
  }
}

function workerConfigForRoot(root: string): WorkerConfig {
  return {
    endpoint: 'tcp://127.0.0.1:6010',
    preAuthToken: 'secret',
    workerId: 'worker-a',
    workerInstanceId: 'worker-a-1',
    workspaceRoot: join(root, 'workspace'),
    workspaceSessionsRoot: join(root, 'workspace/.sessions'),
    sharedFsRoot: join(root, 'shared'),
    userFilesRoot: join(root, 'shared/user-files'),
    agentInstalledSkillsRoot: join(root, 'shared/skills/agents'),
    builtinSkillsRoot: join(root, 'builtin-skills')
  }
}

function payloadFor(frames: Buffer[][], transferId: string, command: string): Record<string, any> {
  const frameSet = frames.find(
    frame => frame[1]?.toString('utf8') === command && frame[2]?.toString('utf8') === transferId
  )
  expect(frameSet, `missing ${command} for ${transferId}`).toBeTruthy()
  return JSON.parse(frameSet![3]!.toString('utf8'))
}

function ackPayload(frames: Buffer[][], transferId: string, command: string): Record<string, any> {
  const payload = frames
    .filter(frame => frame[1]?.toString('utf8') === 'ACK' && frame[2]?.toString('utf8') === transferId)
    .map(frame => JSON.parse(frame[3]!.toString('utf8')))
    .find(payload => payload.command === command)
  expect(payload, `missing ${command} ACK for ${transferId}`).toBeTruthy()
  expect(payload.command).toBe(command)
  return payload
}
