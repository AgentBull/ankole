import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  utimesSync,
  writeFileSync
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { BackgroundAgentJobTurnUpsertResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { BackgroundAgentJobTurnRecorder } from '../src/core/codex-runner/job/turn-recorder'
import {
  computeSpoolRetryDelayMs,
  DEFAULT_SPOOL_RETRY_BASE_MS,
  enforceTurnSpoolSafetyCap,
  loadRetainedTurnSpoolFiles,
  TurnCheckpointSpooler,
  turnSpoolFilePath
} from '../src/core/codex-runner/job/turn-recorder-spool'
import { RPCTimeoutError } from '../src/lanes/rpc-lane'
import {
  actorTurn,
  commandItem,
  decodedUpsert,
  notification,
  startedTurn,
  type DecodedUpsert
} from './support/codex-turn-recorder'

describe('@ankole/agent-computer durable Turn checkpoint spool', () => {
  it('retains turns/<turnId>.jsonl until control-plane ack resolves and retries with exponential backoff', async () => {
    expect(DEFAULT_SPOOL_RETRY_BASE_MS).toBe(15_000)
    expect(computeSpoolRetryDelayMs(0)).toBe(15_000)
    expect(computeSpoolRetryDelayMs(1)).toBe(30_000)
    expect(computeSpoolRetryDelayMs(2)).toBe(60_000)
    expect(computeSpoolRetryDelayMs(10)).toBe(300_000)

    const spoolRoot = mkdtempSync(join(tmpdir(), 'ankole-turn-spool-'))
    const spoolFile = turnSpoolFilePath(spoolRoot, 'turn-1')
    let shouldFail = true
    let resolveAckGate!: () => void
    const ackGate = new Promise<void>(resolve => {
      resolveAckGate = resolve
    })
    let holdAck = false
    const delivered: DecodedUpsert[] = []

    const recorder = new BackgroundAgentJobTurnRecorder({
      jobID: '1000',
      attempt: 1,
      actorTurn,
      spoolRoot,
      checkpointDelayMs: 0,
      spoolRetryBaseDelayMs: 20,
      spoolRetryMaxDelayMs: 80,
      upsert: async request => {
        if (shouldFail) {
          throw new RPCTimeoutError('background_agent_job.turn.upsert', true)
        }
        if (holdAck) {
          // Verify spool file ALREADY exists on disk and is NOT unlinked before ack resolves!
          expect(existsSync(spoolFile)).toBe(true)
          await ackGate
        }
        delivered.push(decodedUpsert(request))
        return create(BackgroundAgentJobTurnUpsertResponseSchema, { jobId: request.jobId })
      }
    })

    try {
      recorder.recordTurnStarted({ threadId: 'thread-1', turn: startedTurn() }, 'agent', '持久化任务', 'event-1')
      await expect(recorder.flush()).rejects.toMatchObject({
        code: 'background_agent_job_turn_persistence_failed',
        retryable: true
      })
      // Unacknowledged spool file MUST remain on disk!
      expect(existsSync(spoolFile)).toBe(true)

      // Allow the next retry to proceed up to the ack gate, then hold before resolving ack.
      holdAck = true
      shouldFail = false
      await Bun.sleep(35)
      expect(existsSync(spoolFile)).toBe(true)
      expect(delivered).toHaveLength(0)

      // Once control-plane acknowledgment resolves, turns/<turnId>.jsonl is unlinked!
      resolveAckGate()
      await recorder.flush()
      expect(delivered).toHaveLength(1)
      expect(existsSync(spoolFile)).toBe(false)
    } finally {
      recorder.close()
      rmSync(spoolRoot, { recursive: true, force: true })
    }
  })

  it('spools checkpoints enqueued mid-RPC before sending, avoids premature unlink, and compacts remaining lines on failure', async () => {
    const spoolRoot = mkdtempSync(join(tmpdir(), 'ankole-turn-spool-race-'))
    const spoolFile = turnSpoolFilePath(spoolRoot, 'turn-1')
    let releaseFirstRpc!: () => void
    const firstRpcGate = new Promise<void>(resolve => {
      releaseFirstRpc = resolve
    })
    let callCount = 0
    let failThirdCheckpoint = false

    const spooler = new TurnCheckpointSpooler({
      spoolRoot,
      lookupTurn: () => undefined,
      upsert: async request => {
        callCount += 1
        // Every RPC must see its own revision already durably appended on disk!
        expect(existsSync(spoolFile)).toBe(true)
        const linesOnDisk = readFileSync(spoolFile, 'utf8').trim().split('\n').filter(Boolean)
        expect(linesOnDisk.some(line => JSON.parse(line).revision === request.revision)).toBe(true)

        if (callCount === 1) {
          await firstRpcGate
        }
        if (failThirdCheckpoint && request.revision === 2) {
          throw new RPCTimeoutError('background_agent_job.turn.upsert', true)
        }
        return create(BackgroundAgentJobTurnUpsertResponseSchema, { jobId: request.jobId })
      }
    })

    const makeRequest = (revision: number) => ({
      jobId: '1000',
      attempt: 1,
      runtimeThreadId: 'thread-1',
      runtimeTurnId: 'turn-1',
      kind: 'agent',
      status: 'in_progress',
      revision,
      trajectoryJson: new Uint8Array(),
      turnItemsJson: new Uint8Array(),
      progressJson: new Uint8Array(),
      errorJson: new Uint8Array(),
      startedAt: '2026-11-16T00:00:00.000Z'
    })

    try {
      spooler.enqueue('turn-1', [], makeRequest(0))
      await Bun.sleep(10)
      expect(callCount).toBe(1)

      // Enqueue C2 while C1 RPC is still in flight; C1 completion must NOT unlink `turn-1.jsonl`!
      spooler.enqueue('turn-1', [], makeRequest(1))
      releaseFirstRpc()
      await spooler.flush()

      expect(callCount).toBe(2)
      expect(existsSync(spoolFile)).toBe(false)

      // Now enqueue a batch where revision 0 succeeds and revision 2 fails:
      // `finally` compacts out acked revisions so only unacked revisions remain on disk.
      failThirdCheckpoint = true
      spooler.enqueue('turn-1', [], makeRequest(1))
      spooler.enqueue('turn-1', [], makeRequest(2))
      await expect(spooler.flush()).rejects.toMatchObject({
        code: 'background_agent_job_turn_persistence_failed',
        retryable: true
      })

      const retained = await loadRetainedTurnSpoolFiles(spoolRoot)
      expect(retained).toHaveLength(1)
      expect(retained[0]?.requests.map(req => req.revision)).toEqual([2])
    } finally {
      spooler.close()
      rmSync(spoolRoot, { recursive: true, force: true })
    }
  })

  it('replays retained turns/<turnId>.jsonl across recorder instances and enforces the 64 MiB / 7-day disk cap', async () => {
    const spoolRoot = mkdtempSync(join(tmpdir(), 'ankole-turn-spool-recover-'))
    const delivered: DecodedUpsert[] = []

    const firstRecorder = new BackgroundAgentJobTurnRecorder({
      jobID: '1000',
      attempt: 1,
      actorTurn,
      spoolRoot,
      checkpointDelayMs: 0,
      upsert: async () => {
        throw new RPCTimeoutError('background_agent_job.turn.upsert', true)
      }
    })

    try {
      firstRecorder.recordTurnStarted({ threadId: 'thread-1', turn: startedTurn() }, 'agent', '断线重传', 'event-1')
      firstRecorder.handleNotification(
        notification('item/completed', { item: commandItem('cmd-1', 'echo hi', 'hi', 'completed') })
      )
      await expect(firstRecorder.flush()).rejects.toThrow()
      firstRecorder.close()

      const spoolFile = turnSpoolFilePath(spoolRoot, 'turn-1')
      expect(existsSync(spoolFile)).toBe(true)

      // Second recorder instance replays the retained spool and unlinks it only after ack.
      const secondRecorder = new BackgroundAgentJobTurnRecorder({
        jobID: '1000',
        attempt: 1,
        actorTurn,
        spoolRoot,
        checkpointDelayMs: 0,
        upsert: async request => {
          delivered.push(decodedUpsert(request))
          return create(BackgroundAgentJobTurnUpsertResponseSchema, { jobId: request.jobId })
        }
      })
      await secondRecorder.flush()
      secondRecorder.close()

      expect(delivered.length).toBeGreaterThanOrEqual(1)
      expect(delivered[0]?.turn_items[0]?.item_key).toBe('client:event-1')
      expect(existsSync(spoolFile)).toBe(false)

      // Verify hard disk-safety cap (> 7 days age and > maxBytes oldest-first eviction).
      const turnsDir = join(spoolRoot, 'turns')
      mkdirSync(turnsDir, { recursive: true })
      const nowMs = Date.now()
      const expiredPath = join(turnsDir, 'turn-expired.jsonl')
      const olderBigPath = join(turnsDir, 'turn-old-big.jsonl')
      const newestPath = join(turnsDir, 'turn-newest.jsonl')
      writeFileSync(expiredPath, 'x'.repeat(128))
      writeFileSync(olderBigPath, 'y'.repeat(1_024))
      writeFileSync(newestPath, 'z'.repeat(512))

      const eightDaysAgoSec = (nowMs - 8 * 24 * 60 * 60 * 1000) / 1000
      const oneHourAgoSec = (nowMs - 3_600_000) / 1000
      const nowSec = nowMs / 1000
      utimesSync(expiredPath, eightDaysAgoSec, eightDaysAgoSec)
      utimesSync(olderBigPath, oneHourAgoSec, oneHourAgoSec)
      utimesSync(newestPath, nowSec, nowSec)

      await enforceTurnSpoolSafetyCap(spoolRoot, { maxBytes: 800, nowMs })
      expect(readdirSync(turnsDir)).toEqual(['turn-newest.jsonl'])
    } finally {
      firstRecorder.close()
      rmSync(spoolRoot, { recursive: true, force: true })
    }
  })
})
