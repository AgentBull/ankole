import { utimesSync } from 'node:fs'
import { lstat, readdir, rm, statfs } from 'node:fs/promises'
import { join } from 'node:path'
import { mkdirAgentSync } from '../common/agent-user'
import { nodeErrorCode } from '../common/errors'
import { agentHomePaths, jobWorkspacePath, sessionWorkspacePath } from '../core/agent-home-paths'
import type { WorkerConfig } from './config'

export const DEFAULT_WORKSPACE_MAX_INACTIVE_MS = 14 * 24 * 60 * 60 * 1000
export const DEFAULT_WORKSPACE_MAX_COUNT = 256
export const DEFAULT_WORKSPACE_MIN_FREE_BYTES = 512 * 1024 * 1024
export const DEFAULT_WORKSPACE_MIN_FREE_RATIO = 0.05
export const RETAINED_JOB_LOOKUP_BATCH_SIZE = 2048

const retainedWorkspaces = new Map<string, number>()
const inFlightEvictions = new Map<string, Promise<void>>()

export async function acquireSessionWorkspace(config: Pick<WorkerConfig, 'agentHomeRoot'>, workspaceID: number) {
  const path = sessionWorkspacePath(config.agentHomeRoot, workspaceID)
  const release = await acquireWorkspace(path)
  try {
    prepareActorWorkspace(config, workspaceID)
    return { path, release }
  } catch (error) {
    release()
    throw error
  }
}

export function acquireJobWorkspace(agentHomeRoot: string, jobID: string): Promise<() => void> {
  return acquireWorkspace(jobWorkspacePath(agentHomeRoot, jobID))
}

async function acquireWorkspace(path: string): Promise<() => void> {
  const release = retainWorkspaceRef(retainedWorkspaces, path)
  try {
    await inFlightEvictions.get(path)?.catch(() => undefined)
    return release
  } catch (error) {
    release()
    throw error
  }
}

function retainWorkspaceRef(table: Map<string, number>, key: string): () => void {
  table.set(key, (table.get(key) ?? 0) + 1)
  let released = false
  return () => {
    if (released) return
    released = true
    const next = (table.get(key) ?? 1) - 1
    if (next <= 0) table.delete(key)
    else table.set(key, next)
  }
}

export function prepareTurnWorkspace(config: Pick<WorkerConfig, 'agentHomeRoot'>): string {
  const paths = prepareAgentHome(config.agentHomeRoot)
  return paths.jobs
}

function prepareActorWorkspace(config: Pick<WorkerConfig, 'agentHomeRoot'>, workspaceID: number): string {
  prepareAgentHome(config.agentHomeRoot)
  const sessionRoot = sessionWorkspacePath(config.agentHomeRoot, workspaceID)
  mkdirAgentSync(sessionRoot)
  mkdirAgentSync(join(sessionRoot, 'temp'))
  try {
    const now = new Date()
    utimesSync(sessionRoot, now, now)
  } catch {
    // Ignore filesystems that disallow utimes on non-owned mounts.
  }

  return sessionRoot
}

/**
 * Creates missing directories of the Agent Home without cleaning existing
 * contents. Worker readiness creates the Agent Home itself at startup.
 */
function prepareAgentHome(agentHomeRoot: string) {
  const paths = agentHomePaths(agentHomeRoot)
  mkdirAgentSync(paths.codexHome, 0o700)
  mkdirAgentSync(paths.sessions)
  mkdirAgentSync(paths.jobs)
  return paths
}

export type DiskSpaceSnapshot = {
  freeBytes: number
  totalBytes: number
}

export type EvictInactiveWorkspacesOptions = {
  activeSessionIDs?: Iterable<string>
  activeJobIDs?: Iterable<string>
  evictJobs?: boolean
  resolveRetainedJobIDs?: (candidateJobIDs: string[]) => Promise<ReadonlySet<string> | Iterable<string>>
  maxInactiveMs?: number
  maxWorkspaceCount?: number
  minFreeBytes?: number
  minFreeRatio?: number
  nowMs?: number
  getDiskSpace?: (homeRoot: string) => Promise<DiskSpaceSnapshot | undefined>
}

export type EvictInactiveWorkspacesResult = {
  evictedSessions: string[]
  evictedJobs: string[]
}

type CandidateWorkspace = {
  kind: 'session' | 'job'
  id: string
  path: string
  lastActiveMs: number
}

/**
 * Evicts inactive `/workspace/sessions/*` and `/workspace/jobs/*` directories
 * older than 14 days, or LRU-oldest inactive directories when workspace count
 * or disk usage crosses high-water marks. Active in-flight session/job IDs and
 * `/workspace/shared` (and all other Agent Home paths) are never touched.
 */
export async function evictInactiveWorkspaces(
  agentHomeRoot: string,
  options: EvictInactiveWorkspacesOptions = {}
): Promise<EvictInactiveWorkspacesResult> {
  const paths = agentHomePaths(agentHomeRoot)
  const nowMs = options.nowMs ?? Date.now()
  const maxInactiveMs = options.maxInactiveMs ?? DEFAULT_WORKSPACE_MAX_INACTIVE_MS
  const maxWorkspaceCount = options.maxWorkspaceCount ?? DEFAULT_WORKSPACE_MAX_COUNT
  const minFreeBytes = options.minFreeBytes ?? DEFAULT_WORKSPACE_MIN_FREE_BYTES
  const minFreeRatio = options.minFreeRatio ?? DEFAULT_WORKSPACE_MIN_FREE_RATIO
  const readDiskSpace = options.getDiskSpace ?? defaultDiskSpace

  const activeSessions = new Set<string>()
  if (options.activeSessionIDs) {
    for (const id of options.activeSessionIDs) activeSessions.add(String(id))
  }
  const activeJobs = new Set<string>()
  if (options.activeJobIDs) {
    for (const id of options.activeJobIDs) activeJobs.add(String(id))
  }

  const [sessionScan, jobScan] = await Promise.all([
    scanWorkspaceBucket(paths.sessions, 'session', activeSessions, nowMs),
    scanWorkspaceBucket(paths.jobs, 'job', activeJobs, nowMs)
  ])

  let activeCount = sessionScan.activeCount + jobScan.activeCount
  if (options.evictJobs === false) {
    activeCount += jobScan.candidates.length
    jobScan.candidates.length = 0
  } else if (jobScan.candidates.length > 0 && options.resolveRetainedJobIDs) {
    try {
      const retainedSet = new Set<string>()
      for (let i = 0; i < jobScan.candidates.length; i += RETAINED_JOB_LOOKUP_BATCH_SIZE) {
        const batchIds = jobScan.candidates.slice(i, i + RETAINED_JOB_LOOKUP_BATCH_SIZE).map(candidate => candidate.id)
        const retained = await options.resolveRetainedJobIDs(batchIds)
        for (const id of retained) retainedSet.add(id)
      }
      const evictableJobs: CandidateWorkspace[] = []
      for (const candidate of jobScan.candidates) {
        if (retainedSet.has(candidate.id)) {
          activeJobs.add(candidate.id)
          activeCount += 1
        } else {
          evictableJobs.push(candidate)
        }
      }
      jobScan.candidates = evictableJobs
    } catch {
      // Fail-safe: skip job eviction when control-plane retention lookup fails.
      activeCount += jobScan.candidates.length
      jobScan.candidates.length = 0
    }
  }

  const inactive: CandidateWorkspace[] = [...sessionScan.candidates, ...jobScan.candidates]
  const evictedSessions: string[] = []
  const evictedJobs: string[] = []

  const evict = async (candidate: CandidateWorkspace): Promise<void> => {
    const activeByID = candidate.kind === 'session' ? activeSessions.has(candidate.id) : activeJobs.has(candidate.id)
    if (retainedWorkspaces.has(candidate.path) || activeByID) {
      activeCount += 1
      return
    }
    const previous = inFlightEvictions.get(candidate.path)
    if (previous) {
      await previous
      return
    }
    const removal = rm(candidate.path, { recursive: true, force: true })
    inFlightEvictions.set(candidate.path, removal)
    try {
      await removal
    } finally {
      inFlightEvictions.delete(candidate.path)
    }
    if (candidate.kind === 'session') evictedSessions.push(candidate.id)
    else evictedJobs.push(candidate.id)
  }

  // 1. Age-based eviction (> 14 days inactive).
  const remaining: CandidateWorkspace[] = []
  for (const candidate of inactive) {
    if (nowMs - candidate.lastActiveMs > maxInactiveMs) {
      await evict(candidate)
    } else {
      remaining.push(candidate)
    }
  }

  // Sort remaining inactive directories LRU-first (oldest `lastActiveMs` first).
  remaining.sort((left, right) => left.lastActiveMs - right.lastActiveMs)

  // 2. Count high-bound LRU eviction.
  while (remaining.length > 0 && activeCount + remaining.length > maxWorkspaceCount) {
    const oldest = remaining.shift()!
    await evict(oldest)
  }

  // 3. Free-disk high-water mark LRU eviction.
  while (remaining.length > 0) {
    const space = await readDiskSpace(paths.home)
    if (!space || !isDiskBelowWatermark(space, minFreeBytes, minFreeRatio)) break
    const oldest = remaining.shift()!
    await evict(oldest)
  }

  return { evictedSessions, evictedJobs }
}

function isDiskBelowWatermark(space: DiskSpaceSnapshot, minFreeBytes: number, minFreeRatio: number): boolean {
  if (space.freeBytes < minFreeBytes) return true
  if (space.totalBytes > 0 && space.freeBytes / space.totalBytes < minFreeRatio) return true
  return false
}

async function defaultDiskSpace(homeRoot: string): Promise<DiskSpaceSnapshot | undefined> {
  try {
    const stats = await statfs(homeRoot)
    const blockSize = Number(stats.bsize)
    return {
      freeBytes: Number(stats.bavail) * blockSize,
      totalBytes: Number(stats.blocks) * blockSize
    }
  } catch {
    return undefined
  }
}

async function scanWorkspaceBucket(
  bucketRoot: string,
  kind: 'session' | 'job',
  activeIDs: ReadonlySet<string>,
  nowMs: number
): Promise<{ activeCount: number; candidates: CandidateWorkspace[] }> {
  let entries
  try {
    entries = await readdir(bucketRoot, { withFileTypes: true })
  } catch (error) {
    if (nodeErrorCode(error) === 'ENOENT') return { activeCount: 0, candidates: [] }
    throw error
  }

  let activeCount = 0
  const candidates: CandidateWorkspace[] = []
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.isSymbolicLink()) continue
    const id = entry.name
    const dirPath = join(bucketRoot, id)
    if (activeIDs.has(id) || retainedWorkspaces.has(dirPath)) {
      activeCount += 1
      continue
    }
    let dirInfo
    try {
      dirInfo = await lstat(dirPath)
    } catch (error) {
      if (nodeErrorCode(error) === 'ENOENT') continue
      throw error
    }
    if (!dirInfo.isDirectory() || dirInfo.isSymbolicLink()) continue
    // Protect fresh `.project-init-*` atomic staging directories created within the last hour.
    if (id.startsWith('.project-init-') && nowMs - dirInfo.mtimeMs < 60 * 60 * 1000) {
      activeCount += 1
      continue
    }
    const lastActiveMs = await directoryLatestMtimeMs(dirPath, dirInfo.mtimeMs)
    candidates.push({ kind, id, path: dirPath, lastActiveMs })
  }
  return { activeCount, candidates }
}

async function directoryLatestMtimeMs(dirPath: string, initialMtimeMs: number): Promise<number> {
  let latest = initialMtimeMs
  let children
  try {
    children = await readdir(dirPath, { withFileTypes: true })
  } catch {
    return latest
  }
  for (const child of children) {
    try {
      const childPath = join(dirPath, child.name)
      const info = await lstat(childPath)
      if (info.mtimeMs > latest) latest = info.mtimeMs
    } catch {
      // Ignore concurrently removed scratch entries.
    }
  }
  return latest
}
