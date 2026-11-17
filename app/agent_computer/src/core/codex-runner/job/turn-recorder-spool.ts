import { recordValue, safeJsonParse, stringArg } from '@agentbull/active-support'
import { Buffer } from 'node:buffer'
import { appendFile, readdir, readFile, stat, unlink } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { mkdirAgent } from '../../../common/agent-user'
import { writeFileAtomic } from '../../../common/atomic-write'
import { nodeErrorCode } from '../../../common/errors'
import type { BackgroundAgentJobTurnUpsertResponse } from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { RPCRequestInit } from '../../../lanes/rpc-contract'
import { sanitizePathSegment } from '../../agent-home-paths'
import {
  acknowledgeTurnItems,
  BackgroundAgentJobTurnPersistenceRejectedError,
  persistTurnCheckpointWithRetry,
  type RuntimeTurn
} from './turn-recorder-helpers'

export const DEFAULT_SPOOL_RETRY_BASE_MS = 15_000
export const DEFAULT_SPOOL_RETRY_MAX_MS = 5 * 60_000
export const DEFAULT_SPOOL_MAX_BYTES = 64 * 1024 * 1024
export const DEFAULT_SPOOL_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000

export function computeSpoolRetryDelayMs(
  retryIndex: number,
  baseDelayMs = DEFAULT_SPOOL_RETRY_BASE_MS,
  maxDelayMs = DEFAULT_SPOOL_RETRY_MAX_MS
): number {
  const exponent = Math.max(0, Math.min(retryIndex, 20))
  return Math.min(maxDelayMs, baseDelayMs * 2 ** exponent)
}

type SerializedSpoolLine = {
  v: 1
  jobId: string
  attempt: number
  runtimeThreadId: string
  runtimeTurnId: string
  kind: string
  status: string
  revision: number
  trajectoryB64: string
  turnItemsB64: string
  progressB64: string
  usageB64?: string
  errorB64: string
  startedAt: string
  completedAt?: string
}

export function turnSpoolDirectory(spoolRoot: string): string {
  return join(spoolRoot, 'turns')
}

export function turnSpoolFilePath(spoolRoot: string, runtimeTurnID: string): string {
  return join(turnSpoolDirectory(spoolRoot), `${sanitizePathSegment(runtimeTurnID)}.jsonl`)
}

function serializeSpoolRequest(request: RPCRequestInit<'background_agent_job.turn.upsert'>): string {
  const b64 = (bytes?: Uint8Array) => (bytes && bytes.byteLength > 0 ? Buffer.from(bytes).toString('base64') : '')
  const line: SerializedSpoolLine = {
    v: 1,
    jobId: request.jobId ?? '',
    attempt: request.attempt ?? 0,
    runtimeThreadId: request.runtimeThreadId ?? '',
    runtimeTurnId: request.runtimeTurnId ?? '',
    kind: request.kind ?? 'agent',
    status: request.status ?? 'in_progress',
    revision: request.revision ?? 0,
    trajectoryB64: b64(request.trajectoryJson),
    turnItemsB64: b64(request.turnItemsJson),
    progressB64: b64(request.progressJson),
    ...(request.usageJson && request.usageJson.byteLength > 0 ? { usageB64: b64(request.usageJson) } : {}),
    errorB64: b64(request.errorJson),
    startedAt: request.startedAt ?? '',
    ...(request.completedAt ? { completedAt: request.completedAt } : {})
  }
  return JSON.stringify(line)
}

function deserializeSpoolRequest(rawLine: string): RPCRequestInit<'background_agent_job.turn.upsert'> | undefined {
  const parsed = safeJsonParse(rawLine).unwrapOr(undefined)
  const rec = recordValue(parsed)
  if (!rec || rec.v !== 1) return undefined
  const jobId = stringArg(rec, 'jobId')
  const runtimeThreadId = stringArg(rec, 'runtimeThreadId')
  const runtimeTurnId = stringArg(rec, 'runtimeTurnId')
  const kind = stringArg(rec, 'kind')
  const status = stringArg(rec, 'status')
  const startedAt = stringArg(rec, 'startedAt')
  if (
    !jobId ||
    typeof rec.attempt !== 'number' ||
    !runtimeThreadId ||
    !runtimeTurnId ||
    !kind ||
    !status ||
    typeof rec.revision !== 'number' ||
    !startedAt
  ) {
    return undefined
  }
  const fromB64 = (key: string) => {
    const val = stringArg(rec, key)
    return val ? new Uint8Array(Buffer.from(val, 'base64')) : new Uint8Array(0)
  }
  const usageB64 = stringArg(rec, 'usageB64')
  const completedAt = stringArg(rec, 'completedAt')
  return {
    jobId,
    attempt: rec.attempt,
    runtimeThreadId,
    runtimeTurnId,
    kind,
    status,
    revision: rec.revision,
    trajectoryJson: fromB64('trajectoryB64'),
    turnItemsJson: fromB64('turnItemsB64'),
    progressJson: fromB64('progressB64'),
    ...(usageB64 ? { usageJson: new Uint8Array(Buffer.from(usageB64, 'base64')) } : {}),
    errorJson: fromB64('errorB64'),
    startedAt,
    ...(completedAt ? { completedAt } : {})
  }
}

async function appendTurnSpoolCheckpoints(
  spoolFilePath: string,
  requests: readonly RPCRequestInit<'background_agent_job.turn.upsert'>[]
): Promise<void> {
  if (requests.length === 0) return
  await mkdirAgent(dirname(spoolFilePath), 0o700)
  const content = `${requests.map(serializeSpoolRequest).join('\n')}\n`
  await appendFile(spoolFilePath, content, { mode: 0o600 })
}

async function settleTurnSpoolFile(
  spoolFilePath: string,
  remainingRequests: readonly RPCRequestInit<'background_agent_job.turn.upsert'>[]
): Promise<void> {
  if (remainingRequests.length === 0) {
    try {
      await unlink(spoolFilePath)
    } catch (error) {
      if (nodeErrorCode(error) !== 'ENOENT') throw error
    }
    return
  }
  await mkdirAgent(dirname(spoolFilePath), 0o700)
  const content = `${remainingRequests.map(serializeSpoolRequest).join('\n')}\n`
  await writeFileAtomic(spoolFilePath, content, 0o600)
}

export async function loadRetainedTurnSpoolFiles(spoolRoot: string): Promise<
  Array<{
    spoolFilePath: string
    requests: RPCRequestInit<'background_agent_job.turn.upsert'>[]
  }>
> {
  const dir = turnSpoolDirectory(spoolRoot)
  let names: string[]
  try {
    names = (await readdir(dir)).filter(name => name.endsWith('.jsonl'))
  } catch (error) {
    if (nodeErrorCode(error) === 'ENOENT') return []
    throw error
  }
  const dated: Array<{ name: string; filePath: string; mtimeMs: number }> = []
  for (const name of names) {
    const filePath = join(dir, name)
    try {
      const info = await stat(filePath)
      if (info.isFile()) dated.push({ name, filePath, mtimeMs: info.mtimeMs })
    } catch (error) {
      if (nodeErrorCode(error) !== 'ENOENT') throw error
    }
  }
  dated.sort((left, right) => left.mtimeMs - right.mtimeMs)

  const loaded: Array<{
    spoolFilePath: string
    requests: RPCRequestInit<'background_agent_job.turn.upsert'>[]
  }> = []
  for (const entry of dated) {
    let text: string
    try {
      text = await readFile(entry.filePath, 'utf8')
    } catch (error) {
      if (nodeErrorCode(error) === 'ENOENT') continue
      throw error
    }
    const requests = text
      .split('\n')
      .map(line => line.trim())
      .filter(Boolean)
      .flatMap(line => {
        const req = deserializeSpoolRequest(line)
        return req ? [req] : []
      })
    if (requests.length === 0) {
      await unlink(entry.filePath).catch(() => undefined)
      continue
    }
    loaded.push({ spoolFilePath: entry.filePath, requests })
  }
  return loaded
}

export async function enforceTurnSpoolSafetyCap(
  spoolRoot: string,
  options: {
    maxBytes?: number
    maxAgeMs?: number
    nowMs?: number
  } = {}
): Promise<string[]> {
  const maxBytes = options.maxBytes ?? DEFAULT_SPOOL_MAX_BYTES
  const maxAgeMs = options.maxAgeMs ?? DEFAULT_SPOOL_MAX_AGE_MS
  const nowMs = options.nowMs ?? Date.now()
  const dir = turnSpoolDirectory(spoolRoot)

  let names: string[]
  try {
    names = (await readdir(dir)).filter(name => name.endsWith('.jsonl'))
  } catch (error) {
    if (nodeErrorCode(error) === 'ENOENT') return []
    throw error
  }

  const entries: Array<{ filePath: string; size: number; mtimeMs: number }> = []
  for (const name of names) {
    const filePath = join(dir, name)
    try {
      const info = await stat(filePath)
      if (info.isFile()) entries.push({ filePath, size: info.size, mtimeMs: info.mtimeMs })
    } catch {
      // Concurrent settlement may have unlinked this file.
    }
  }

  const evicted: string[] = []
  const fresh: Array<{ filePath: string; size: number; mtimeMs: number }> = []
  for (const entry of entries) {
    if (nowMs - entry.mtimeMs > maxAgeMs) {
      await unlink(entry.filePath).catch(() => undefined)
      evicted.push(entry.filePath)
    } else {
      fresh.push(entry)
    }
  }

  let totalBytes = fresh.reduce((sum, item) => sum + item.size, 0)
  if (totalBytes <= maxBytes) return evicted

  fresh.sort((left, right) => left.mtimeMs - right.mtimeMs)
  for (const entry of fresh) {
    if (totalBytes <= maxBytes) break
    await unlink(entry.filePath).catch(() => undefined)
    totalBytes -= entry.size
    evicted.push(entry.filePath)
  }
  return evicted
}

type QueuedTurnCheckpoint = {
  runtimeTurnID?: string
  itemKeys: string[]
  request: RPCRequestInit<'background_agent_job.turn.upsert'>
  spoolFilePath?: string
  spooled: boolean
  attemptsMade: number
  fromRecoverySpool?: boolean
}

export class TurnCheckpointSpooler {
  private readonly pendingCheckpoints: QueuedTurnCheckpoint[] = []
  private tail: Promise<void> = Promise.resolve()
  private drainInFlight = false
  private recoveredSpoolLoaded = false
  private fatalRejection: unknown
  private lastTransientError: unknown
  private retryAttempt = 0
  private retryTimer: ReturnType<typeof setTimeout> | undefined
  private closed = false

  constructor(
    private readonly config: {
      upsert: (
        request: RPCRequestInit<'background_agent_job.turn.upsert'>
      ) => Promise<BackgroundAgentJobTurnUpsertResponse>
      lookupTurn: (runtimeTurnID: string) => RuntimeTurn | undefined
      spoolRoot?: string
      spoolRetryBaseDelayMs?: number
      spoolRetryMaxDelayMs?: number
      spoolMaxBytes?: number
      spoolMaxAgeMs?: number
      nowMs?: () => number
    }
  ) {}

  enqueue(
    runtimeTurnID: string,
    itemKeys: string[],
    request: RPCRequestInit<'background_agent_job.turn.upsert'>
  ): void {
    const spoolFilePath = this.config.spoolRoot ? turnSpoolFilePath(this.config.spoolRoot, runtimeTurnID) : undefined
    this.pendingCheckpoints.push({
      runtimeTurnID,
      itemKeys,
      request,
      spoolFilePath,
      spooled: false,
      attemptsMade: 0
    })
    this.scheduleDrainPass()
  }

  async flush(): Promise<void> {
    const needsRecoveryLoad = Boolean(this.config.spoolRoot && !this.recoveredSpoolLoaded)
    if (!this.drainInFlight && (this.pendingCheckpoints.length > 0 || needsRecoveryLoad) && !this.fatalRejection) {
      this.scheduleDrainPass()
    }
    await this.tail
    if (this.fatalRejection) throw this.fatalRejection
    if (this.pendingCheckpoints.length > 0 && this.lastTransientError) {
      throw this.lastTransientError
    }
  }

  close(): void {
    this.closed = true
    if (this.retryTimer) {
      clearTimeout(this.retryTimer)
      this.retryTimer = undefined
    }
  }

  private scheduleDrainPass(): void {
    if (this.retryTimer) {
      clearTimeout(this.retryTimer)
      this.retryTimer = undefined
    }
    if (this.drainInFlight) return
    this.drainInFlight = true
    this.tail = this.tail
      .then(async () => {
        try {
          await this.drainPendingCheckpoints()
        } finally {
          this.drainInFlight = false
        }
      })
      .catch(error => {
        this.fatalRejection ??= error
      })
  }

  private async drainPendingCheckpoints(): Promise<void> {
    if (this.config.spoolRoot && !this.recoveredSpoolLoaded) {
      this.recoveredSpoolLoaded = true
      await enforceTurnSpoolSafetyCap(this.config.spoolRoot, {
        maxBytes: this.config.spoolMaxBytes ?? DEFAULT_SPOOL_MAX_BYTES,
        maxAgeMs: this.config.spoolMaxAgeMs ?? DEFAULT_SPOOL_MAX_AGE_MS,
        nowMs: this.config.nowMs?.() ?? Date.now()
      })
      const recovered = await loadRetainedTurnSpoolFiles(this.config.spoolRoot)
      const recoveredEntries: QueuedTurnCheckpoint[] = []
      for (const file of recovered) {
        for (const request of file.requests) {
          recoveredEntries.push({
            runtimeTurnID: request.runtimeTurnId,
            itemKeys: [],
            request,
            spoolFilePath: file.spoolFilePath,
            spooled: true,
            attemptsMade: 0,
            fromRecoverySpool: true
          })
        }
      }
      if (recoveredEntries.length > 0) {
        this.pendingCheckpoints.unshift(...recoveredEntries)
      }
    }

    if (this.fatalRejection) return

    const dirtySpoolFiles = new Set<string>()
    try {
      while (this.pendingCheckpoints.length > 0) {
        // Append any unspooled entries (including checkpoints enqueued while an earlier RPC was in flight)
        // to their `.jsonl` spool file BEFORE dispatching the next RPC.
        await this.spoolPendingCheckpoints(dirtySpoolFiles)

        const head = this.pendingCheckpoints[0]!
        const maxAttempts = head.attemptsMade === 0 ? 3 : 1
        try {
          await persistTurnCheckpointWithRetry(this.config.upsert, head.request, maxAttempts)
          head.attemptsMade += maxAttempts
          this.pendingCheckpoints.shift()
          if (head.runtimeTurnID) {
            acknowledgeTurnItems(this.config.lookupTurn(head.runtimeTurnID), head.itemKeys)
          }
          if (head.spoolFilePath) {
            const remainingForFile = this.pendingCheckpoints.filter(
              candidate => candidate.spoolFilePath === head.spoolFilePath
            )
            if (remainingForFile.length === 0) {
              // Only unlink `turns/<turnId>.jsonl` once every queued checkpoint for that Turn has been acked!
              await settleTurnSpoolFile(head.spoolFilePath, [])
              dirtySpoolFiles.delete(head.spoolFilePath)
            } else {
              dirtySpoolFiles.add(head.spoolFilePath)
            }
          }
          this.lastTransientError = undefined
          this.retryAttempt = 0
        } catch (error) {
          head.attemptsMade += maxAttempts
          if (error instanceof BackgroundAgentJobTurnPersistenceRejectedError) {
            if (head.fromRecoverySpool) {
              // An earlier attempt's retained spool file was superseded on the control plane;
              // retire that obsolete spool entry without poisoning the current attempt.
              this.pendingCheckpoints.shift()
              if (head.spoolFilePath) {
                await this.settleRemainingForSpoolFile(head.spoolFilePath, dirtySpoolFiles)
              }
              continue
            }
            this.fatalRejection = error
            return
          }
          this.lastTransientError = error
          this.scheduleBackoffRetry()
          return
        }
      }
    } finally {
      for (const spoolFilePath of dirtySpoolFiles) {
        await this.settleRemainingForSpoolFile(spoolFilePath, dirtySpoolFiles)
      }
    }
  }

  private async spoolPendingCheckpoints(dirtySpoolFiles: Set<string>): Promise<void> {
    if (!this.config.spoolRoot) return

    let wroteSpool = false
    let batchPath: string | undefined
    let batchEntries: QueuedTurnCheckpoint[] = []

    const flushBatch = async (): Promise<void> => {
      if (!batchPath || batchEntries.length === 0) return
      await appendTurnSpoolCheckpoints(
        batchPath,
        batchEntries.map(item => item.request)
      )
      for (const item of batchEntries) {
        item.spooled = true
      }
      wroteSpool = true
      batchPath = undefined
      batchEntries = []
    }

    for (const entry of this.pendingCheckpoints) {
      if (entry.spooled || !entry.spoolFilePath) continue
      if (batchPath && batchPath !== entry.spoolFilePath) {
        await flushBatch()
      }
      batchPath = entry.spoolFilePath
      batchEntries.push(entry)
    }
    await flushBatch()

    if (wroteSpool) {
      const evicted = await enforceTurnSpoolSafetyCap(this.config.spoolRoot, {
        maxBytes: this.config.spoolMaxBytes ?? DEFAULT_SPOOL_MAX_BYTES,
        maxAgeMs: this.config.spoolMaxAgeMs ?? DEFAULT_SPOOL_MAX_AGE_MS,
        nowMs: this.config.nowMs?.() ?? Date.now()
      })
      if (evicted.length > 0) {
        const evictedSet = new Set(evicted)
        for (const path of evicted) {
          dirtySpoolFiles.delete(path)
        }
        for (const entry of this.pendingCheckpoints) {
          if (entry.spoolFilePath && evictedSet.has(entry.spoolFilePath)) {
            entry.spoolFilePath = undefined
          }
        }
      }
    }
  }

  private async settleRemainingForSpoolFile(spoolFilePath: string, dirtySpoolFiles: Set<string>): Promise<void> {
    const entriesForFile = this.pendingCheckpoints.filter(candidate => candidate.spoolFilePath === spoolFilePath)
    await settleTurnSpoolFile(
      spoolFilePath,
      entriesForFile.map(candidate => candidate.request)
    )
    for (const candidate of entriesForFile) {
      candidate.spooled = true
    }
    dirtySpoolFiles.delete(spoolFilePath)
  }

  private scheduleBackoffRetry(): void {
    if (this.closed || this.fatalRejection || this.retryTimer || this.pendingCheckpoints.length === 0) return
    const delayMs = computeSpoolRetryDelayMs(
      this.retryAttempt,
      this.config.spoolRetryBaseDelayMs ?? DEFAULT_SPOOL_RETRY_BASE_MS,
      this.config.spoolRetryMaxDelayMs ?? DEFAULT_SPOOL_RETRY_MAX_MS
    )
    this.retryAttempt += 1
    const timer = setTimeout(() => {
      this.retryTimer = undefined
      if (this.closed || this.fatalRejection || this.pendingCheckpoints.length === 0) return
      this.scheduleDrainPass()
    }, delayMs)
    timer.unref?.()
    this.retryTimer = timer
  }
}
