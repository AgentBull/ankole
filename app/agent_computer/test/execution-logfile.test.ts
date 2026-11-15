import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  EXECUTION_HISTORY_REL_PATH,
  hasIncompatibleContinuationRuntime,
  materializeJobExecutionLogfile,
  TASK_LINEAGE_REL_PATH
} from '../src/core/codex-runner/job/execution-logfile'
import { recreatedThreadInput } from '../src/core/codex-runner/job/session-support'
import { changedWorkspacePaths, snapshotWorkspace } from '../src/core/codex-runner/job/workspace-snapshot'
import { jsonBytes } from '../src/fabric/envelope-proto'
import { RuntimeFabricTransportError } from '../src/fabric/fabric'
import { BackgroundAgentJobResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { RPCTimeoutError, type RPCRequester } from '../src/lanes/rpc-lane'
import type { JobTurnRef } from '../src/lanes/session-lane'

const jobTurn: JobTurnRef = {
  session: { session_id: 'job:2002' },
  job_id: 2002,
  attempt: 1,
  signal_id: '019a0000-0000-7000-8000-000000000001'
}

function makeTempDir(): string {
  return mkdtempSync(join(tmpdir(), 'ankole-exec-logfile-'))
}

describe('BackgroundAgentJob workspace execution logfile recovery', () => {
  it('reverses page order while preserving intra-page chronological order and excludes .ankole from workspace diffs', async () => {
    const root = makeTempDir()
    try {
      writeFileSync(join(root, 'deliverable.md'), 'initial draft\n')
      const before = await snapshotWorkspace(root)
      if ('skipped' in before) throw new Error('expected workspace snapshot')

      const lineage = {
        format: 'ankole_job_task_lineage',
        version: 1,
        workspace_owner_job_id: 2001,
        current_job_id: 2002,
        jobs: [
          {
            job_id: 2001,
            title: 'Build sales report',
            status: 'failed',
            attempts: 1,
            task: 'Create Pod Page and Base table with strict Q3 numbers.'
          },
          {
            job_id: 2002,
            title: 'Build sales report',
            status: 'running',
            attempts: 1,
            continued_from_job_id: 2001,
            task: 'Continue and finish verification.'
          }
        ],
        user_messages: [
          {
            job_id: 2001,
            attempt: 1,
            turn_id: 'turn-1',
            position: 3,
            kind: 'user_message',
            text: 'Correction: exclude internal test orders from Q3 revenue.'
          }
        ]
      }

      // TrajectoryReader serves newest page first ("head"), while lines inside each page are chronological.
      const newestPageLines = [
        JSON.stringify({
          job_id: 2001,
          position: 2,
          type: 'dynamicToolCall',
          tool: 'pages.create',
          output: [{ text: 'page_id=pg_991' }]
        }),
        JSON.stringify({
          job_id: 2001,
          position: 3,
          type: 'userMessage',
          text: 'Correction: exclude internal test orders from Q3 revenue.'
        })
      ]
      const olderPageLines = [
        JSON.stringify({ job_id: 2001, position: 0, type: 'plan', text: '1. Inspect CSV\n2. Create Pod Page' }),
        JSON.stringify({
          job_id: 2001,
          position: 1,
          type: 'commandExecution',
          command: 'wc -l sales.csv',
          exit_code: 0,
          output: '412 sales.csv\n'
        })
      ]

      const seenCursors: string[] = []
      const rpc = (async (_method: unknown, payload: unknown) => {
        const req = payload as { executionLogCursor?: string }
        seenCursors.push(req.executionLogCursor ?? '')
        if (req.executionLogCursor === 'head') {
          return create(BackgroundAgentJobResponseSchema, {
            status: 'running',
            task: 'Continue and finish verification.',
            executionLogJsonl: Buffer.from(`${newestPageLines.join('\n')}\n`, 'utf8'),
            executionLogNextCursor: 'cursor-older-1',
            taskLineageJson: jsonBytes(lineage)
          })
        }
        if (req.executionLogCursor === 'cursor-older-1') {
          return create(BackgroundAgentJobResponseSchema, {
            status: 'running',
            task: 'Continue and finish verification.',
            executionLogJsonl: Buffer.from(`${olderPageLines.join('\n')}\n`, 'utf8'),
            executionLogNextCursor: ''
          })
        }
        throw new Error(`unexpected cursor ${req.executionLogCursor}`)
      }) as RPCRequester

      const materialized = await materializeJobExecutionLogfile({
        rpc,
        jobTurn,
        jobID: '2002',
        projectRoot: root,
        reason: 'resume_failed'
      })

      expect(seenCursors).toEqual(['head', 'cursor-older-1'])
      expect(materialized).toEqual({
        reason: 'resume_failed',
        hasTaskLineage: true,
        hasExecutionHistory: true,
        historyLineCount: 4,
        historyTruncated: false
      })

      const savedLineage = JSON.parse(readFileSync(join(root, TASK_LINEAGE_REL_PATH), 'utf8'))
      expect(savedLineage).toEqual(lineage)

      const savedHistoryLines = readFileSync(join(root, EXECUTION_HISTORY_REL_PATH), 'utf8')
        .trim()
        .split('\n')
        .map(line => JSON.parse(line) as Record<string, unknown>)
      expect(savedHistoryLines[0]).toEqual({
        type: 'logfile_meta',
        version: 1,
        job_id: 2002,
        reason: 'resume_failed',
        line_count: 4,
        truncated: false
      })
      expect(savedHistoryLines.slice(1).map(item => item.position)).toEqual([0, 1, 2, 3])
      expect(JSON.stringify(savedHistoryLines[3])).toContain('page_id=pg_991')

      // Prompt references both real files and preserves source context + continuation.
      const job = create(BackgroundAgentJobResponseSchema, {
        task: 'Continue and finish verification.',
        continuedFromJobId: '2001'
      })
      const prompt = recreatedThreadInput(
        job,
        'Continue and finish verification.',
        { task: 'Create Pod Page and Base table with strict Q3 numbers.', finalReport: undefined },
        materialized
      )
      expect(prompt).toContain('.ankole/task-lineage.json')
      expect(prompt).toContain('.ankole/execution-history.jsonl')
      expect(prompt).toContain('Create Pod Page and Base table with strict Q3 numbers.')

      // Workspace snapshot ignores .ankole/* completely.
      const after = await snapshotWorkspace(root)
      if ('skipped' in after) throw new Error('expected workspace snapshot')
      expect(changedWorkspacePaths(before.files, after.files)).toEqual([])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('truncates oldest entries when exceeding maxBytes while keeping task-lineage.json intact', async () => {
    const root = makeTempDir()
    try {
      const lineage = { format: 'ankole_job_task_lineage', version: 1, jobs: [{ job_id: 2002, task: 'Root criteria' }] }
      const makeLine = (pos: number) =>
        JSON.stringify({ position: pos, type: 'commandExecution', output: 'x'.repeat(120) })

      const rpc = (async (_method: unknown, payload: unknown) => {
        const req = payload as { executionLogCursor?: string }
        if (req.executionLogCursor === 'head') {
          return create(BackgroundAgentJobResponseSchema, {
            executionLogJsonl: Buffer.from(`${makeLine(3)}\n${makeLine(4)}\n`, 'utf8'),
            executionLogNextCursor: 'older',
            taskLineageJson: jsonBytes(lineage)
          })
        }
        return create(BackgroundAgentJobResponseSchema, {
          executionLogJsonl: Buffer.from(`${makeLine(1)}\n${makeLine(2)}\n`, 'utf8'),
          executionLogNextCursor: ''
        })
      }) as RPCRequester

      // Budget fits 3 lines (~500 bytes), dropping position 1 while keeping 2, 3, 4 in order.
      const materialized = await materializeJobExecutionLogfile({
        rpc,
        jobTurn,
        jobID: '2002',
        projectRoot: root,
        reason: 'cold_idle_recycle',
        maxBytes: 540
      })

      expect(materialized.historyTruncated).toBe(true)
      expect(materialized.hasTaskLineage).toBe(true)
      expect(existsSync(join(root, TASK_LINEAGE_REL_PATH))).toBe(true)
      const records = readFileSync(join(root, EXECUTION_HISTORY_REL_PATH), 'utf8')
        .trim()
        .split('\n')
        .map(line => JSON.parse(line) as Record<string, unknown>)
      expect(records[0]?.truncated).toBe(true)
      expect(records.slice(1).map(item => item.position)).toEqual([2, 3, 4])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rethrows transient RPC transport errors and timeouts instead of starting an amnesic thread', async () => {
    const root = makeTempDir()
    try {
      const timeoutRPC = (async () => {
        throw new RPCTimeoutError('background_agent_job.get', true)
      }) as RPCRequester

      await expect(
        materializeJobExecutionLogfile({
          rpc: timeoutRPC,
          jobTurn,
          jobID: '2002',
          projectRoot: root,
          reason: 'resume_failed'
        })
      ).rejects.toBeInstanceOf(RPCTimeoutError)

      const transportRPC = (async () => {
        throw new RuntimeFabricTransportError('socket_closed', 'RuntimeFabric socket closed')
      }) as RPCRequester

      await expect(
        materializeJobExecutionLogfile({
          rpc: transportRPC,
          jobTurn,
          jobID: '2002',
          projectRoot: root,
          reason: 'resume_failed'
        })
      ).rejects.toBeInstanceOf(RuntimeFabricTransportError)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('detects provider or model changes only while holding the inherited source runtime_thread_id', async () => {
    const currentJob = create(BackgroundAgentJobResponseSchema, {
      runtimeThreadId: 'thread-openai-1',
      runtimeProjectionJson: jsonBytes({
        version: 1,
        model_ref: { provider_id: 'anthropic-main', model: 'claude-haiku-4-5' }
      })
    })
    const rpc = (async () =>
      create(BackgroundAgentJobResponseSchema, {
        runtimeThreadId: 'thread-openai-1',
        runtimeProjectionJson: jsonBytes({
          version: 1,
          model_ref: { provider_id: 'openai-main', model: 'gpt-5.4' }
        })
      })) as RPCRequester

    expect(
      await hasIncompatibleContinuationRuntime({
        rpc,
        jobTurn,
        jobID: '2002',
        sourceJobID: '2001',
        runtimeThreadID: 'thread-openai-1',
        currentJob
      })
    ).toBe(true)

    // Once the successor creates its own replacement thread, subsequent retries or
    // waiting_on_user resumes must NOT treat its own thread as incompatible.
    expect(
      await hasIncompatibleContinuationRuntime({
        rpc,
        jobTurn,
        jobID: '2002',
        sourceJobID: '2001',
        runtimeThreadID: 'thread-haiku-2',
        currentJob
      })
    ).toBe(false)

    const sameRPC = (async () =>
      create(BackgroundAgentJobResponseSchema, {
        runtimeThreadId: 'thread-openai-1',
        runtimeProjectionJson: jsonBytes({
          version: 1,
          model_ref: { provider_id: 'anthropic-main', model: 'claude-haiku-4-5' }
        })
      })) as RPCRequester

    expect(
      await hasIncompatibleContinuationRuntime({
        rpc: sameRPC,
        jobTurn,
        jobID: '2002',
        sourceJobID: '2001',
        runtimeThreadID: 'thread-openai-1',
        currentJob
      })
    ).toBe(false)
  })
})
