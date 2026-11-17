import { create } from '@bufbuild/protobuf'
import { describe, expect, test } from 'bun:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { emptyBackgroundAgentJobPathHandoff } from '../src/core/background-agent-job-handoff'
import {
  completeSucceededCodexTurn,
  recoverOrCommitFailedCodexTurn,
  extractCitedDrivePaths,
  parseJobCompletionState
} from '../src/core/codex-runner/job/session-turn-lifecycle'
import { BackgroundAgentJobTurnRecorder } from '../src/core/codex-runner/job/turn-recorder'
import { DriveView, type DriveFlushResult } from '../src/drive/mounts'
import type { RcCall } from '../src/drive/rclone-control'
import {
  BackgroundAgentJobResponseSchema,
  BackgroundAgentJobTurnUpsertResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

describe('Codex turn completion lifecycle (L-01..L-03)', () => {
  test('stopping during retry backoff prevents the next turn', async () => {
    let stopping = false
    const effects: string[] = []
    const recovery = recoverOrCommitFailedCodexTurn({
      isStopping: () => stopping,
      error: { codexErrorInfo: 'serverOverloaded' },
      codexTurnStatus: 'failed',
      outputText: '',
      pendingCredentialPoolExhaustion: undefined,
      recoveryState: { transientRetries: 0, compactRetries: 0, newThreadRetries: 0 },
      canCompact: false,
      job: create(BackgroundAgentJobResponseSchema),
      setRecoveryState: () => {},
      startCodexTurn: async () => {
        effects.push('turn')
      },
      compactThread: async () => {
        effects.push('compact')
      },
      replaceThreadAndStartTurn: async () => {
        effects.push('replace')
      },
      commit: async () => {
        effects.push('commit')
      }
    })
    stopping = true
    await expect(
      recovery.then(() => {
        expect(effects).toEqual([])
      })
    ).resolves.toBeUndefined()
  })

  test('abortSignal immediately wakes retry sleep and pending Drive status keeps driveFlush.paths authoritative over prose /drive/ mentions', async () => {
    const controller = new AbortController()
    const effects: string[] = []
    const t0 = Date.now()
    const recovery = recoverOrCommitFailedCodexTurn({
      abortSignal: controller.signal,
      isStopping: () => controller.signal.aborted,
      error: { codexErrorInfo: 'serverOverloaded' },
      codexTurnStatus: 'failed',
      outputText: '',
      pendingCredentialPoolExhaustion: undefined,
      recoveryState: { transientRetries: 0, compactRetries: 0, newThreadRetries: 0 },
      canCompact: false,
      job: create(BackgroundAgentJobResponseSchema),
      setRecoveryState: () => {},
      startCodexTurn: async () => {
        effects.push('turn')
      },
      compactThread: async () => {
        effects.push('compact')
      },
      replaceThreadAndStartTurn: async () => {
        effects.push('replace')
      },
      commit: async () => {
        effects.push('commit')
      }
    })
    controller.abort()
    await recovery
    expect(Date.now() - t0).toBeLessThan(250)
    expect(effects).toEqual([])

    const root = await mkdtemp(join(tmpdir(), 'codex-prose-drive-'))
    try {
      const commits: Array<{ status: string; details: unknown }> = []
      const driveView = Object.assign(Object.create(DriveView.prototype) as DriveView, {
        flushPath: async (path: string) => {
          if (path === '/drive/Private/example-in-prose.md') throw new Error('not_a_real_file')
          return 'node-1'
        }
      })
      await completeSucceededCodexTurn({
        isStopping: () => false,
        driveFlush: {
          status: 'pending',
          paths: [],
          files: [{ path: '/drive/Private/real.md', nodeId: 'node-real' }]
        },
        driveView,
        outputText: 'Done! See `/drive/Private/example-in-prose.md` for reference.',
        emptyReportRetries: 0,
        root,
        jobID: '101',
        attempt: 1,
        runtimeThreadID: 'thr_1',
        codexTurnStatus: 'completed',
        latestTokenUsage: undefined,
        completedFilesChanged: emptyBackgroundAgentJobPathHandoff(),
        workspaceSnapshot: undefined,
        logger: undefined,
        incrementEmptyReportRetries: () => {},
        startCodexTurn: async () => {},
        commit: async (status, details) => {
          commits.push({ status, details })
        }
      })
      expect(commits).toHaveLength(1)
      expect(commits[0]!.status).toBe('succeeded')
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  test('stopping while cited Drive writes flush prevents a verification turn and terminal commit', async () => {
    const root = await mkdtemp(join(tmpdir(), 'codex-stop-flush-'))
    const flushing = Promise.withResolvers<string>()
    let stopping = false
    const effects: string[] = []
    const driveView = Object.assign(Object.create(DriveView.prototype) as DriveView, {
      flushPath: () => flushing.promise
    })
    try {
      const completion = completeSucceededCodexTurn({
        isStopping: () => stopping,
        driveFlush: { status: 'pending', paths: ['/drive/report.xlsx'], files: [], flush_incomplete: true },
        driveView,
        outputText: 'Saved /drive/report.xlsx',
        emptyReportRetries: 0,
        root,
        jobID: '101',
        attempt: 1,
        runtimeThreadID: 'thread',
        codexTurnStatus: 'completed',
        latestTokenUsage: undefined,
        completedFilesChanged: emptyBackgroundAgentJobPathHandoff(),
        workspaceSnapshot: undefined,
        logger: undefined,
        incrementEmptyReportRetries: () => {},
        startCodexTurn: async () => {
          effects.push('turn')
        },
        commit: async () => {
          effects.push('commit')
        }
      })
      stopping = true
      flushing.resolve('node')
      await completion
      expect(effects).toEqual([])
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })
  test('parses Outcome: incomplete vs complete and extracts cited /drive paths', () => {
    expect(parseJobCompletionState('All acceptance criteria verified.\nOutcome: complete')).toBe('complete')
    expect(parseJobCompletionState('Saved partial draft.\n**Outcome: incomplete**\nMissing Q4 feed.')).toBe(
      'incomplete'
    )
    expect(
      extractCitedDrivePaths('Saved report to `/drive/Private/Reports/q4.xlsx` and /drive/Space/summary.md.')
    ).toEqual(['/drive/Private/Reports/q4.xlsx', '/drive/Space/summary.md'])
  })

  test('never commits succeeded when Drive writes failed or remain pending', async () => {
    const root = await mkdtemp(join(tmpdir(), 'codex-lifecycle-'))
    try {
      const startedPrompts: string[] = []
      const commits: Array<{ status: string; details: unknown }> = []

      await completeSucceededCodexTurn({
        isStopping: () => false,
        driveFlush: {
          status: 'failed',
          errors: [{ path: '/drive/Private/out.xlsx', failure: 'HTTP 503', recovery: '/drive-recovery/out.xlsx' }],
          files: []
        },
        outputText: 'Generated /drive/Private/out.xlsx',
        emptyReportRetries: 0,
        root,
        jobID: '101',
        attempt: 1,
        runtimeThreadID: 'thr_1',
        codexTurnStatus: 'completed',
        latestTokenUsage: undefined,
        completedFilesChanged: emptyBackgroundAgentJobPathHandoff(),
        workspaceSnapshot: undefined,
        logger: undefined,
        incrementEmptyReportRetries: () => {},
        startCodexTurn: async prompt => {
          startedPrompts.push(prompt)
        },
        commit: async (status, details) => {
          commits.push({ status, details })
        }
      })

      expect(commits).toEqual([])
      expect(startedPrompts).toHaveLength(1)
      expect(startedPrompts[0]).toContain('Drive write failed: /drive/Private/out.xlsx')

      // Pending upload: first attempt asks Codex to verify; second attempt fails with drive_sync_incomplete
      let pendingRetries = 0
      await completeSucceededCodexTurn({
        isStopping: () => false,
        driveFlush: { status: 'pending', paths: ['/drive/Private/big.zip'], files: [] },
        pendingDriveRetries: pendingRetries,
        outputText: 'Uploaded /drive/Private/big.zip',
        emptyReportRetries: 0,
        root,
        jobID: '101',
        attempt: 1,
        runtimeThreadID: 'thr_1',
        codexTurnStatus: 'completed',
        latestTokenUsage: undefined,
        completedFilesChanged: emptyBackgroundAgentJobPathHandoff(),
        workspaceSnapshot: undefined,
        logger: undefined,
        incrementEmptyReportRetries: () => {},
        incrementPendingDriveRetries: () => {
          pendingRetries += 1
        },
        startCodexTurn: async prompt => {
          startedPrompts.push(prompt)
        },
        commit: async (status, details) => {
          commits.push({ status, details })
        }
      })
      expect(pendingRetries).toBe(1)
      expect(commits).toEqual([])

      await completeSucceededCodexTurn({
        isStopping: () => false,
        driveFlush: { status: 'pending', paths: ['/drive/Private/big.zip'], files: [] },
        pendingDriveRetries: pendingRetries,
        outputText: 'Uploaded /drive/Private/big.zip',
        emptyReportRetries: 0,
        root,
        jobID: '101',
        attempt: 1,
        runtimeThreadID: 'thr_1',
        codexTurnStatus: 'completed',
        latestTokenUsage: undefined,
        completedFilesChanged: emptyBackgroundAgentJobPathHandoff(),
        workspaceSnapshot: undefined,
        logger: undefined,
        incrementEmptyReportRetries: () => {},
        startCodexTurn: async () => {},
        commit: async (status, details) => {
          commits.push({ status, details })
        }
      })
      expect(commits).toHaveLength(1)
      expect(commits[0]?.status).toBe('failed')
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  test('records completion_state and flushed Drive deliverables on succeeded commit', async () => {
    const root = await mkdtemp(join(tmpdir(), 'codex-lifecycle-ok-'))
    try {
      type CommitDetails = Parameters<Parameters<typeof completeSucceededCodexTurn>[0]['commit']>[1]
      let committed: { status: string; details: CommitDetails } | undefined
      await completeSucceededCodexTurn({
        isStopping: () => false,
        driveFlush: {
          status: 'flushed',
          files: [{ path: '/drive/Private/q4-forecast.xlsx', nodeId: '019a2b00-0000-7000-8000-000000000099' }]
        },
        outputText: 'Saved `/drive/Private/q4-forecast.xlsx`.\nOutcome: incomplete\nWaiting for FX rates.',
        emptyReportRetries: 0,
        root,
        jobID: '102',
        attempt: 1,
        runtimeThreadID: 'thr_2',
        codexTurnStatus: 'completed',
        latestTokenUsage: undefined,
        completedFilesChanged: emptyBackgroundAgentJobPathHandoff(),
        workspaceSnapshot: undefined,
        logger: undefined,
        incrementEmptyReportRetries: () => {},
        startCodexTurn: async () => {},
        commit: async (status, details) => {
          committed = { status, details }
        }
      })

      expect(committed?.status).toBe('succeeded')
      expect(committed?.details.result?.completion_state).toBe('incomplete')
      expect(committed?.details.result?.deliverables).toEqual([
        {
          path: '/drive/Private/q4-forecast.xlsx',
          node_id: '019a2b00-0000-7000-8000-000000000099',
          name: 'q4-forecast.xlsx',
          mime_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        }
      ])
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  test('persists unresolved pending Drive paths across verification Turns when Turn 2 writes and cites nothing', async () => {
    const root = await mkdtemp(join(tmpdir(), 'codex-lifecycle-pending-turns-'))
    try {
      type CommitDetails = Parameters<Parameters<typeof completeSucceededCodexTurn>[0]['commit']>[1]

      const runTwoTurnScenario = async (turn2ResolvesNodeID?: string) => {
        let seq = 0
        let turnNumber = 0
        const mockDriveView = Object.assign(Object.create(DriveView.prototype) as DriveView, {
          sequence: async () => new Map([['scope_1', ++seq]]),
          flush: async (): Promise<DriveFlushResult> => {
            turnNumber += 1
            if (turnNumber === 1) {
              return { status: 'pending', paths: ['/drive/report.xlsx'], files: [] }
            }
            return { status: 'flushed', files: [] }
          },
          flushPaths: undefined,
          flushPath: async (path: string): Promise<string> => {
            if (turnNumber >= 2 && turn2ResolvesNodeID && path === '/drive/report.xlsx') {
              return turn2ResolvesNodeID
            }
            throw new Error(`still uploading ${path}`)
          }
        })

        const recorder = new BackgroundAgentJobTurnRecorder({
          jobID: '205',
          attempt: 1,
          actorTurn: { session: { session_id: 'job:205' }, signal_id: 'sig-205', job_id: 205, attempt: 1 },
          driveView: mockDriveView,
          upsert: async () => create(BackgroundAgentJobTurnUpsertResponseSchema, { jobId: '205' })
        })

        let pendingRetries = 0
        const startedPrompts: string[] = []
        const commits: Array<{ status: string; details: CommitDetails }> = []

        try {
          // Turn 1: writes /drive/report.xlsx, flush returns pending
          await recorder.startDriveWindow()
          const flush1 = await recorder.flushDriveWindow()
          expect(flush1).toEqual({ status: 'pending', paths: ['/drive/report.xlsx'], files: [] })

          await completeSucceededCodexTurn({
            isStopping: () => false,
            driveFlush: flush1,
            driveDeliverables: recorder.getDriveDeliverables(),
            driveView: mockDriveView,
            recordDriveDeliverables: files => recorder.recordDriveDeliverables(files),
            pendingDriveRetries: pendingRetries,
            outputText: 'Generated /drive/report.xlsx.',
            emptyReportRetries: 0,
            root,
            jobID: '205',
            attempt: 1,
            runtimeThreadID: 'thr_205',
            codexTurnStatus: 'completed',
            latestTokenUsage: undefined,
            completedFilesChanged: emptyBackgroundAgentJobPathHandoff(),
            workspaceSnapshot: undefined,
            logger: undefined,
            incrementEmptyReportRetries: () => {},
            incrementPendingDriveRetries: () => {
              pendingRetries += 1
            },
            startCodexTurn: async prompt => {
              startedPrompts.push(prompt)
              await recorder.startDriveWindow()
            },
            commit: async (status, details) => {
              commits.push({ status, details })
            }
          })

          expect(pendingRetries).toBe(1)
          expect(startedPrompts).toHaveLength(1)
          expect(commits).toEqual([])

          // Verification Turn 2: writes NO new files (`flush(window2)` returns `{ status: 'flushed', files: [] }`)
          // and cites NO `/drive/...` paths in `outputText`!
          const flush2 = await recorder.flushDriveWindow()
          await completeSucceededCodexTurn({
            isStopping: () => false,
            driveFlush: flush2,
            driveDeliverables: recorder.getDriveDeliverables(),
            driveView: mockDriveView,
            recordDriveDeliverables: files => recorder.recordDriveDeliverables(files),
            pendingDriveRetries: pendingRetries,
            outputText: 'Checked upload status and summarized results.',
            emptyReportRetries: 0,
            root,
            jobID: '205',
            attempt: 1,
            runtimeThreadID: 'thr_205',
            codexTurnStatus: 'completed',
            latestTokenUsage: undefined,
            completedFilesChanged: emptyBackgroundAgentJobPathHandoff(),
            workspaceSnapshot: undefined,
            logger: undefined,
            incrementEmptyReportRetries: () => {},
            incrementPendingDriveRetries: () => {
              pendingRetries += 1
            },
            startCodexTurn: async prompt => {
              startedPrompts.push(prompt)
            },
            commit: async (status, details) => {
              commits.push({ status, details })
            }
          })

          return commits
        } finally {
          recorder.close()
        }
      }

      // Case A: flushPath('/drive/report.xlsx') still fails on Turn 2 -> MUST commit 'failed' (drive_sync_incomplete)!
      const caseACommits = await runTwoTurnScenario(undefined)
      expect(caseACommits).toHaveLength(1)
      expect(caseACommits[0]?.status).toBe('failed')
      expect(caseACommits[0]?.details.error).toMatchObject({
        code: 'drive_sync_incomplete',
        pending_paths: ['/drive/report.xlsx']
      })

      // Case B: flushPath('/drive/report.xlsx') resolves during Turn 2 -> records deliverable and commits 'succeeded'!
      const resolvedNodeID = '019a2b00-0000-7000-8000-000000000205'
      const caseBCommits = await runTwoTurnScenario(resolvedNodeID)
      expect(caseBCommits).toHaveLength(1)
      expect(caseBCommits[0]?.status).toBe('succeeded')
      expect(caseBCommits[0]?.details.result?.deliverables).toEqual([
        {
          path: '/drive/report.xlsx',
          node_id: resolvedNodeID,
          name: 'report.xlsx',
          mime_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        }
      ])
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  test('recovers from transient ankole/flush RC failure across Turn 1 -> Turn 2 without poisoning pendingDrivePaths with /drive/*', async () => {
    const root = await mkdtemp(join(tmpdir(), 'codex-lifecycle-rc-transient-'))
    try {
      type CommitDetails = Parameters<Parameters<typeof completeSucceededCodexTurn>[0]['commit']>[1]

      const sequences = new Map<string, number>([
        ['scope_s1', 10],
        ['chat_c1', 4],
        ['library_l1', 1]
      ])
      let failFlushCalls = true
      const observedFlushWindows: Array<{ fs: string; since_seq: number }> = []
      const statRemotes: string[] = []

      const rc = (async (method: string, body: Record<string, unknown>) => {
        if (method === 'ankole/sequence') {
          const fs = String(body.fs)
          return { sequence: sequences.get(fs) ?? 0 }
        }
        if (method === 'ankole/flush') {
          const fs = String(body.fs)
          const sinceSeq = Number(body.since_seq ?? 0)
          observedFlushWindows.push({ fs, since_seq: sinceSeq })
          if (failFlushCalls) {
            throw new Error('Drive did not answer rclone ankole/flush before its deadline.')
          }
          if (fs === 'scope_s1' && sinceSeq <= 10) {
            return {
              files: [
                {
                  Path: 'exports/summary.csv',
                  NodeID: '019a2b00-0000-7000-8000-000000000301',
                  Failure: '',
                  Recovery: ''
                }
              ]
            }
          }
          return { files: [] }
        }
        if (method === 'ankole/flush-paths') {
          return { files: [] }
        }
        if (method === 'operations/stat') {
          statRemotes.push(String(body.remote))
          return { item: null }
        }
        throw new Error(`unexpected rc method: ${method}`)
      }) as RcCall

      const driveView = new DriveView(
        'view-rc-transient',
        { key: 'scope_s1', path: '/tmp/scope_s1', references: 1, token: 't', endpoint: 'http://dav.test' },
        { key: 'chat_c1', path: '/tmp/chat_c1', references: 1, token: 't', endpoint: 'http://dav.test' },
        { key: 'library_l1', path: '/tmp/library_l1', references: 1, token: 't', endpoint: 'http://dav.test' },
        '/tmp/recovery',
        async () => {},
        () => {},
        rc
      )

      const recorder = new BackgroundAgentJobTurnRecorder({
        jobID: '301',
        attempt: 1,
        actorTurn: { session: { session_id: 'job:301' }, signal_id: 'sig-301', job_id: 301, attempt: 1 },
        driveView,
        upsert: async () => create(BackgroundAgentJobTurnUpsertResponseSchema, { jobId: '301' })
      })

      let pendingRetries = 0
      const startedPrompts: string[] = []
      const commits: Array<{ status: string; details: CommitDetails }> = []

      try {
        // Turn 1 starts at scope_s1=10, chat_c1=4; during Turn 1 sequence advances to scope_s1=11 (exports/summary.csv written).
        await recorder.startDriveWindow()
        sequences.set('scope_s1', 11)
        sequences.set('chat_c1', 5)

        const flush1 = await recorder.flushDriveWindow()
        expect(flush1).toMatchObject({
          status: 'pending',
          paths: [],
          files: [],
          flush_incomplete: true
        })

        await completeSucceededCodexTurn({
          isStopping: () => false,
          driveFlush: flush1,
          driveDeliverables: recorder.getDriveDeliverables(),
          driveView,
          recordDriveDeliverables: files => recorder.recordDriveDeliverables(files),
          pendingDriveRetries: pendingRetries,
          outputText: 'Saved deliverable to Drive.',
          emptyReportRetries: 0,
          root,
          jobID: '301',
          attempt: 1,
          runtimeThreadID: 'thr_301',
          codexTurnStatus: 'completed',
          latestTokenUsage: undefined,
          completedFilesChanged: emptyBackgroundAgentJobPathHandoff(),
          workspaceSnapshot: undefined,
          logger: undefined,
          incrementEmptyReportRetries: () => {},
          incrementPendingDriveRetries: () => {
            pendingRetries += 1
          },
          startCodexTurn: async prompt => {
            startedPrompts.push(prompt)
            // Turn 2 startDriveWindow() sees sequence=11/5, must retain min(since_seq)=10/4!
            await recorder.startDriveWindow()
          },
          commit: async (status, details) => {
            commits.push({ status, details })
          }
        })

        expect(pendingRetries).toBe(1)
        expect(startedPrompts).toHaveLength(1)
        expect(commits).toEqual([])
        expect(statRemotes).not.toContain('*')

        // Turn 2: RC recovers; flushDriveWindow() re-flushes the retained window (since_seq=10) and succeeds!
        observedFlushWindows.length = 0
        failFlushCalls = false

        const flush2 = await recorder.flushDriveWindow()
        expect(observedFlushWindows).toContainEqual({ fs: 'scope_s1', since_seq: 10 })
        expect(observedFlushWindows).toContainEqual({ fs: 'chat_c1', since_seq: 4 })
        expect(flush2).toEqual({
          status: 'flushed',
          files: [{ path: '/drive/exports/summary.csv', nodeId: '019a2b00-0000-7000-8000-000000000301' }]
        })
        expect(statRemotes).not.toContain('*')

        await completeSucceededCodexTurn({
          isStopping: () => false,
          driveFlush: flush2,
          driveDeliverables: recorder.getDriveDeliverables(),
          driveView,
          recordDriveDeliverables: files => recorder.recordDriveDeliverables(files),
          pendingDriveRetries: pendingRetries,
          outputText: 'Verified exports/summary.csv upload.',
          emptyReportRetries: 0,
          root,
          jobID: '301',
          attempt: 1,
          runtimeThreadID: 'thr_301',
          codexTurnStatus: 'completed',
          latestTokenUsage: undefined,
          completedFilesChanged: emptyBackgroundAgentJobPathHandoff(),
          workspaceSnapshot: undefined,
          logger: undefined,
          incrementEmptyReportRetries: () => {},
          incrementPendingDriveRetries: () => {
            pendingRetries += 1
          },
          startCodexTurn: async prompt => {
            startedPrompts.push(prompt)
          },
          commit: async (status, details) => {
            commits.push({ status, details })
          }
        })

        expect(commits).toHaveLength(1)
        expect(commits[0]?.status).toBe('succeeded')
        expect(commits[0]?.details.result?.deliverables).toEqual([
          {
            path: '/drive/exports/summary.csv',
            node_id: '019a2b00-0000-7000-8000-000000000301',
            name: 'summary.csv',
            mime_type: 'text/csv'
          }
        ])
      } finally {
        recorder.close()
      }
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  test('batches > 64 pending Drive paths into one ankole/flush-paths call per mount and bounds operations/stat concurrency', async () => {
    const scopePendingRemotes = Array.from({ length: 68 }, (_, idx) => `batch/part-${String(idx).padStart(2, '0')}.csv`)
    const chatPendingRemotes = Array.from({ length: 4 }, (_, idx) => `notes/item-${idx}.md`)

    const flushPathsCalls: Array<{ fs: string; paths: string[]; hasSignal: boolean }> = []
    let activeStatCalls = 0
    let maxConcurrentStatCalls = 0
    let totalStatCalls = 0

    const rc = (async (method: string, body: Record<string, unknown>, signal?: AbortSignal) => {
      if (method === 'ankole/sequence') {
        return { sequence: 1 }
      }
      if (method === 'ankole/flush') {
        const fs = String(body.fs)
        if (fs === 'scope_s1') {
          return { background: true, pending_paths: scopePendingRemotes }
        }
        if (fs === 'chat_c1') {
          return { background: true, pending_paths: chatPendingRemotes }
        }
        return { files: [] }
      }
      if (method === 'ankole/flush-paths') {
        const fs = String(body.fs)
        const paths = (body.paths as string[]) ?? []
        flushPathsCalls.push({ fs, paths, hasSignal: signal instanceof AbortSignal && !signal.aborted })
        if (fs === 'scope_s1') {
          // First 50 return NodeID directly from write state; remaining 18 are clean and resolved via operations/stat.
          return {
            files: paths.slice(0, 50).map((remote, idx) => ({
              Path: remote,
              NodeID: `node-scope-${String(idx).padStart(2, '0')}`,
              Failure: '',
              Recovery: ''
            }))
          }
        }
        return {
          files: paths.map((remote, idx) => ({
            Path: remote,
            NodeID: `node-chat-${idx}`,
            Failure: '',
            Recovery: ''
          }))
        }
      }
      if (method === 'operations/stat') {
        totalStatCalls += 1
        activeStatCalls += 1
        maxConcurrentStatCalls = Math.max(maxConcurrentStatCalls, activeStatCalls)
        await Bun.sleep(5)
        activeStatCalls -= 1
        const remote = String(body.remote)
        return { item: { ID: `stat-${remote.replace(/\//g, '-')}` } }
      }
      throw new Error(`unexpected rc method: ${method}`)
    }) as RcCall

    const driveView = new DriveView(
      'view-batch-68',
      { key: 'scope_s1', path: '/tmp/scope_s1', references: 1, token: 't', endpoint: 'http://dav.test' },
      { key: 'chat_c1', path: '/tmp/chat_c1', references: 1, token: 't', endpoint: 'http://dav.test' },
      { key: 'library_l1', path: '/tmp/library_l1', references: 1, token: 't', endpoint: 'http://dav.test' },
      '/tmp/recovery',
      async () => {},
      () => {},
      rc
    )

    const recorder = new BackgroundAgentJobTurnRecorder({
      jobID: '302',
      attempt: 1,
      actorTurn: { session: { session_id: 'job:302' }, signal_id: 'sig-302', job_id: 302, attempt: 1 },
      driveView,
      upsert: async () => create(BackgroundAgentJobTurnUpsertResponseSchema, { jobId: '302' })
    })

    try {
      await recorder.startDriveWindow()
      const flushResult = await recorder.flushDriveWindow()

      expect(flushPathsCalls).toHaveLength(2)
      expect(flushPathsCalls.find(call => call.fs === 'scope_s1')).toEqual({
        fs: 'scope_s1',
        paths: scopePendingRemotes,
        hasSignal: true
      })
      expect(flushPathsCalls.find(call => call.fs === 'chat_c1')).toEqual({
        fs: 'chat_c1',
        paths: chatPendingRemotes,
        hasSignal: true
      })

      expect(totalStatCalls).toBe(18)
      expect(maxConcurrentStatCalls).toBeGreaterThan(1)
      expect(maxConcurrentStatCalls).toBeLessThanOrEqual(8)

      expect(flushResult.status).toBe('flushed')
      expect(flushResult.files).toHaveLength(72)
      expect(recorder.getDriveDeliverables()).toHaveLength(72)
    } finally {
      recorder.close()
    }
  })

  test('handleRuntimeLost rejects an in-flight thread compaction handshake so cleanup does not hang', async () => {
    const { CodexJobSession } = await import('../src/core/codex-runner/job/session')
    const { createCodexSessionLifecycle } = await import('../src/core/codex-runner/job/session-lifecycle-machine')
    const { runSessionThreadCompaction } = await import('../src/core/codex-runner/job/session-support')
    const { runCodexSessionWithCleanup } = await import('../src/core/codex-runner/job/session-turn-lifecycle')
    const { AgentCodexRuntimeLostError } = await import('../src/core/codex-runner/runtime/agent-runtime-manager')

    const lifecycle = createCodexSessionLifecycle()
    const done = Promise.withResolvers<void>()
    void done.promise.catch(() => {})
    const session = Object.create(CodexJobSession.prototype) as InstanceType<typeof CodexJobSession>
    Object.assign(session, {
      lifecycle,
      compaction: undefined,
      rejectDone: (error: Error) => done.reject(error)
    })

    let compactionSettled = false
    const compaction = runSessionThreadCompaction({
      isStopping: () => lifecycle.isStopping(),
      client: { request: async () => ({}) } as never,
      runtimeThreadID: 'thread-1',
      setCompaction: value => {
        ;(session as unknown as { compaction: unknown }).compaction = value
      }
    }).catch(() => {
      compactionSettled = true
    })

    // Let `thread/compact/start` settle so execution suspends awaiting the compaction notification.
    await Bun.sleep(0)

    const effects: string[] = []
    const cleanup = runCodexSessionWithCleanup({
      execute: () => done.promise,
      done: done.promise,
      agentUID: 'agent-1',
      jobID: '999',
      opts: {} as never,
      prepared: { cleanup: async () => effects.push('materials') } as never,
      turnRecorder: { finishTurn: () => {}, flush: async () => {}, close: () => effects.push('recorder') } as never,
      session,
      isFinalizing: () => lifecycle.isFinalizing(),
      markFinalizing: () => lifecycle.markUnhandledFailure('runtime_lost'),
      codexTurnID: () => undefined,
      stopTimersAndListeners: () => lifecycle.enterCleanup(),
      waitForTurnCompletionTail: () => compaction,
      runtimeLease: () =>
        ({
          runtime: { cleanupSession: async () => effects.push('runtime') },
          release: async () => effects.push('release')
        }) as never,
      durableJobStatusCommitted: () => false
    })

    session.handleRuntimeLost(new AgentCodexRuntimeLostError('agent-1', new Error('Codex app-server exited')))

    await expect(cleanup).rejects.toThrow('Codex app-server exited')
    expect(compactionSettled).toBe(true)
    expect(effects).toEqual(['runtime', 'materials', 'recorder', 'release'])
    lifecycle.close()
  })
})
