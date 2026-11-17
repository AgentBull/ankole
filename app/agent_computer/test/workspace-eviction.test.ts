import { describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, utimesSync, watch, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  DEFAULT_WORKSPACE_MAX_INACTIVE_MS,
  evictInactiveWorkspaces,
  acquireJobWorkspace,
  acquireSessionWorkspace
} from '../src/worker/workspace'

function setAgeDays(dirPath: string, nowMs: number, daysAgo: number): void {
  const sec = (nowMs - daysAgo * 24 * 60 * 60 * 1000) / 1000
  utimesSync(dirPath, sec, sec)
}

describe('Worker /workspace inactive session and Job LRU eviction', () => {
  for (const kind of ['session', 'job'] as const) {
    it(`waits for an in-flight ${kind} deletion before reusing its directory`, async () => {
      const root = mkdtempSync(join(tmpdir(), 'ankole-workspace-race-'))
      const id = 91001
      const path = join(root, kind === 'session' ? 'sessions' : 'jobs', String(id))
      mkdirSync(path, { recursive: true })
      for (let index = 0; index < 2048; index++) writeFileSync(join(path, `old-${index}`), 'old')
      setAgeDays(path, Date.now(), 30)
      let deleting = true
      let acquiredDuringDeletion = false
      let started = false
      let release: (() => void) | undefined
      const acquisition = Promise.withResolvers<() => void>()
      const watcher = watch(path, (event, name) => {
        if (event !== 'rename' || started || !name || existsSync(join(path, String(name)))) return
        started = true
        acquiredDuringDeletion = deleting
        const retained =
          kind === 'session'
            ? acquireSessionWorkspace({ agentHomeRoot: root }, id).then(lease => lease.release)
            : acquireJobWorkspace(root, String(id))
        retained.then(acquisition.resolve, acquisition.reject)
      })
      try {
        const eviction = evictInactiveWorkspaces(root, {
          maxWorkspaceCount: 0,
          getDiskSpace: async () => undefined
        }).finally(() => {
          deleting = false
        })
        release = await acquisition.promise
        mkdirSync(path, { recursive: true })
        writeFileSync(join(path, 'new-work'), 'new')
        await eviction
        expect(acquiredDuringDeletion).toBe(true)
        expect(existsSync(join(path, 'new-work'))).toBe(true)
        expect(readdirSync(path).some(name => name.startsWith('old-'))).toBe(false)
      } finally {
        watcher.close()
        release?.()
        rmSync(root, { recursive: true, force: true })
      }
    })
  }

  it('evicts inactive workspaces older than 14 days while preserving active IDs and /workspace/shared', async () => {
    expect(DEFAULT_WORKSPACE_MAX_INACTIVE_MS).toBe(14 * 24 * 60 * 60 * 1000)

    const root = mkdtempSync(join(tmpdir(), 'ankole-ws-evict-age-'))
    const nowMs = Date.now()
    try {
      const sessionsDir = join(root, 'sessions')
      const jobsDir = join(root, 'jobs')
      const sharedDir = join(root, 'shared')
      mkdirSync(sessionsDir, { recursive: true })
      mkdirSync(jobsDir, { recursive: true })
      mkdirSync(sharedDir, { recursive: true })

      // `/workspace/shared` aged 60 days MUST NEVER be touched!
      const sharedArtifact = join(sharedDir, 'team-cache.json')
      writeFileSync(sharedArtifact, '{"keep":true}')
      setAgeDays(sharedArtifact, nowMs, 60)
      setAgeDays(sharedDir, nowMs, 60)

      // Inactive > 14d session & job -> evicted
      const staleSession = join(sessionsDir, '10001')
      const staleJob = join(jobsDir, '2001')
      mkdirSync(staleSession)
      mkdirSync(staleJob)
      setAgeDays(staleSession, nowMs, 16)
      setAgeDays(staleJob, nowMs, 20)

      // Active in-flight > 14d session & job -> NEVER evicted!
      const activeOldSession = join(sessionsDir, '10002')
      const activeOldJob = join(jobsDir, '2002')
      const retainedOwnerJob = join(jobsDir, '2003')
      mkdirSync(activeOldSession)
      mkdirSync(activeOldJob)
      mkdirSync(retainedOwnerJob)
      setAgeDays(activeOldSession, nowMs, 30)
      setAgeDays(activeOldJob, nowMs, 30)
      setAgeDays(retainedOwnerJob, nowMs, 30)

      // Recent inactive session & job (< 14d) -> kept
      const freshSession = join(sessionsDir, '10003')
      const freshJob = join(jobsDir, '2004')
      mkdirSync(freshSession)
      mkdirSync(freshJob)
      setAgeDays(freshSession, nowMs, 2)
      setAgeDays(freshJob, nowMs, 3)

      const { release: releaseSession } = await acquireSessionWorkspace({ agentHomeRoot: root }, 10002)
      const releaseOwnerJob = await acquireJobWorkspace(root, '2003')
      try {
        const outcome = await evictInactiveWorkspaces(root, {
          nowMs,
          activeJobIDs: ['2002'],
          getDiskSpace: async () => ({ freeBytes: 10 * 1024 * 1024 * 1024, totalBytes: 50 * 1024 * 1024 * 1024 })
        })

        expect(outcome.evictedSessions).toEqual(['10001'])
        expect(outcome.evictedJobs).toEqual(['2001'])
        expect(readdirSync(sessionsDir).sort()).toEqual(['10002', '10003'])
        expect(readdirSync(jobsDir).sort()).toEqual(['2002', '2003', '2004'])
        expect(existsSync(sharedArtifact)).toBe(true)
      } finally {
        releaseSession()
        releaseOwnerJob()
      }
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('evicts oldest inactive workspaces first when count exceeds bound or free disk drops below high-water mark', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-ws-evict-lru-'))
    const nowMs = Date.now()
    try {
      const sessionsDir = join(root, 'sessions')
      const jobsDir = join(root, 'jobs')
      mkdirSync(sessionsDir, { recursive: true })
      mkdirSync(jobsDir, { recursive: true })

      // 4 recent workspaces with distinct ages: s-oldest (10d), j-second (8d), s-third (5d), j-newest (1d), plus 1 active (12d)
      const sOldest = join(sessionsDir, '10010')
      const sActive = join(sessionsDir, '10011')
      const sThird = join(sessionsDir, '10012')
      const jSecond = join(jobsDir, '3010')
      const jNewest = join(jobsDir, '3011')
      for (const dir of [sOldest, sActive, sThird, jSecond, jNewest]) mkdirSync(dir)
      setAgeDays(sActive, nowMs, 12)
      setAgeDays(sOldest, nowMs, 10)
      setAgeDays(jSecond, nowMs, 8)
      setAgeDays(sThird, nowMs, 5)
      setAgeDays(jNewest, nowMs, 1)

      // 1. Count cap = 4 (1 active + 3 inactive) -> evicts `10010` (10d) only.
      const countOutcome = await evictInactiveWorkspaces(root, {
        nowMs,
        activeSessionIDs: ['10011'],
        maxWorkspaceCount: 4,
        getDiskSpace: async () => ({ freeBytes: 10 * 1024 * 1024 * 1024, totalBytes: 50 * 1024 * 1024 * 1024 })
      })
      expect(countOutcome).toEqual({ evictedSessions: ['10010'], evictedJobs: [] })

      // 2. Disk pressure: free disk starts below 512 MiB and recovers after 2 more evictions (`3010` then `10012`).
      let diskChecks = 0
      const diskOutcome = await evictInactiveWorkspaces(root, {
        nowMs,
        activeSessionIDs: ['10011'],
        minFreeBytes: 512 * 1024 * 1024,
        getDiskSpace: async () => {
          diskChecks += 1
          return {
            freeBytes: diskChecks <= 2 ? 128 * 1024 * 1024 : 2 * 1024 * 1024 * 1024,
            totalBytes: 20 * 1024 * 1024 * 1024
          }
        }
      })
      expect(diskOutcome).toEqual({ evictedSessions: ['10012'], evictedJobs: ['3010'] })
      expect(readdirSync(sessionsDir)).toEqual(['10011'])
      expect(readdirSync(jobsDir)).toEqual(['3011'])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('never evicts waiting_on_user or queued-resume Job workspaces returned by resolveRetainedJobIDs under age, count, or disk pressure', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-ws-evict-retained-'))
    const nowMs = Date.now()
    try {
      const sessionsDir = join(root, 'sessions')
      const jobsDir = join(root, 'jobs')
      mkdirSync(sessionsDir, { recursive: true })
      mkdirSync(jobsDir, { recursive: true })

      const waitingOnUserJob = join(jobsDir, '4001')
      const queuedResumeJob = join(jobsDir, '4002')
      const terminalJob = join(jobsDir, '4003')
      const freshSession = join(sessionsDir, '20001')
      for (const dir of [waitingOnUserJob, queuedResumeJob, terminalJob, freshSession]) mkdirSync(dir)

      // Both retained jobs are 30 days old (> 14 days), exceed maxWorkspaceCount, and face low disk space!
      setAgeDays(waitingOnUserJob, nowMs, 30)
      setAgeDays(queuedResumeJob, nowMs, 25)
      setAgeDays(terminalJob, nowMs, 20)
      setAgeDays(freshSession, nowMs, 1)

      let queriedCandidates: string[] = []
      let diskChecks = 0
      const outcome = await evictInactiveWorkspaces(root, {
        nowMs,
        maxWorkspaceCount: 2,
        minFreeBytes: 512 * 1024 * 1024,
        resolveRetainedJobIDs: async candidateJobIDs => {
          queriedCandidates = [...candidateJobIDs].sort()
          return new Set(['4001', '4002'])
        },
        getDiskSpace: async () => {
          diskChecks += 1
          return {
            freeBytes: diskChecks === 1 ? 64 * 1024 * 1024 : 4 * 1024 * 1024 * 1024,
            totalBytes: 20 * 1024 * 1024 * 1024
          }
        }
      })

      expect(queriedCandidates).toEqual(['4001', '4002', '4003'])
      // Terminal job `4003` (age > 14d) and `20001` (count/disk cap because `4001`+`4002` count as 2 active) are evicted,
      // while `4001` and `4002` are completely preserved!
      expect(outcome.evictedJobs).toEqual(['4003'])
      expect(outcome.evictedSessions).toEqual(['20001'])
      expect(readdirSync(jobsDir).sort()).toEqual(['4001', '4002'])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('preserves all Job workspaces fail-safely when resolveRetainedJobIDs rejects or evictJobs is false while still evicting expired sessions', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-ws-evict-failsafe-'))
    const nowMs = Date.now()
    try {
      const sessionsDir = join(root, 'sessions')
      const jobsDir = join(root, 'jobs')
      mkdirSync(sessionsDir, { recursive: true })
      mkdirSync(jobsDir, { recursive: true })

      const expiredSessionA = join(sessionsDir, '30001')
      const expiredSessionB = join(sessionsDir, '30002')
      const oldWaitingJob = join(jobsDir, '5001')
      for (const dir of [expiredSessionA, expiredSessionB, oldWaitingJob]) mkdirSync(dir)
      setAgeDays(expiredSessionA, nowMs, 20)
      setAgeDays(expiredSessionB, nowMs, 20)
      setAgeDays(oldWaitingJob, nowMs, 30)

      // 1. Disconnected fabric (`evictJobs: false`) skips Job eviction and evicts expired sessions.
      const offlineOutcome = await evictInactiveWorkspaces(root, {
        nowMs,
        evictJobs: false,
        getDiskSpace: async () => ({ freeBytes: 10 * 1024 * 1024 * 1024, totalBytes: 50 * 1024 * 1024 * 1024 })
      })
      expect(offlineOutcome).toEqual({ evictedSessions: ['30001', '30002'], evictedJobs: [] })
      expect(readdirSync(jobsDir)).toEqual(['5001'])

      // Recreate an expired session and simulate RPC timeout/failure in `resolveRetainedJobIDs`.
      mkdirSync(expiredSessionA)
      setAgeDays(expiredSessionA, nowMs, 18)

      const rpcErrorOutcome = await evictInactiveWorkspaces(root, {
        nowMs,
        resolveRetainedJobIDs: async () => {
          throw new Error('rpc_disconnected')
        },
        getDiskSpace: async () => ({ freeBytes: 10 * 1024 * 1024 * 1024, totalBytes: 50 * 1024 * 1024 * 1024 })
      })
      expect(rpcErrorOutcome).toEqual({ evictedSessions: ['30001'], evictedJobs: [] })
      expect(readdirSync(jobsDir)).toEqual(['5001'])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('scopes retained workspace locks by full path so another agent home can still evict the same ID', async () => {
    const rootA = mkdtempSync(join(tmpdir(), 'ankole-ws-root-a-'))
    const rootB = mkdtempSync(join(tmpdir(), 'ankole-ws-root-b-'))
    const nowMs = Date.now()
    try {
      const staleB = join(rootB, 'jobs', '9001')
      mkdirSync(staleB, { recursive: true })
      setAgeDays(staleB, nowMs, 30)

      const releaseA = await acquireJobWorkspace(rootA, '9001')
      try {
        const outcome = await evictInactiveWorkspaces(rootB, {
          nowMs,
          getDiskSpace: async () => ({ freeBytes: 10 * 1024 * 1024 * 1024, totalBytes: 50 * 1024 * 1024 * 1024 })
        })
        expect(outcome.evictedJobs).toEqual(['9001'])
      } finally {
        releaseA()
      }
    } finally {
      rmSync(rootA, { recursive: true, force: true })
      rmSync(rootB, { recursive: true, force: true })
    }
  })

  it('batches resolveRetainedJobIDs queries at 2048 candidates so extra retained workspaces are never evicted', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-ws-batch-retain-'))
    const nowMs = Date.now()
    try {
      const jobsDir = join(root, 'jobs')
      mkdirSync(jobsDir, { recursive: true })
      const expected = new Set<string>()
      for (let i = 1; i <= 2050; i += 1) {
        const id = String(10_000 + i)
        expected.add(id)
        const dir = join(jobsDir, id)
        mkdirSync(dir)
        setAgeDays(dir, nowMs, 30)
      }

      const batches: number[] = []
      const outcome = await evictInactiveWorkspaces(root, {
        nowMs,
        resolveRetainedJobIDs: async candidateJobIDs => {
          batches.push(candidateJobIDs.length)
          if (candidateJobIDs.length > 2048) throw new Error('too_many_retained_workspace_candidates')
          return new Set(candidateJobIDs)
        },
        getDiskSpace: async () => ({ freeBytes: 10 * 1024 * 1024 * 1024, totalBytes: 50 * 1024 * 1024 * 1024 })
      })

      expect(batches).toEqual([2048, 2])
      expect(outcome.evictedJobs).toEqual([])
      expect(readdirSync(jobsDir).length).toBe(2050)
      expect(new Set(readdirSync(jobsDir))).toEqual(expected)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
