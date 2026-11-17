import { jsonObject, type JsonObject as JSONObject } from '@agentbull/active-support'
import { Buffer } from 'node:buffer'
import { existsSync } from 'node:fs'
import { lstat, rename, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { chownAgentPath, mkdirAgent } from '../../../common/agent-user'
import { toError } from '../../../common/errors'
import { jsonObjectFromBytes } from '../../../fabric/envelope-proto'
import { isRuntimeFabricTransportError } from '../../../fabric/fabric'
import type { BackgroundAgentJobResponse } from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { RPCTimeoutError } from '../../../lanes/rpc-lane'
import type { JobTurnRef } from '../../../lanes/session-lane'
import type { AgentLoopLogger } from '../../types'
import type { CodexJobOptions } from '../options'
import { stringValue } from '../protocol'

export const EXECUTION_LOG_DIR = '.ankole'
export const EXECUTION_HISTORY_REL_PATH = '.ankole/execution-history.jsonl'
export const TASK_LINEAGE_REL_PATH = '.ankole/task-lineage.json'

const defaultMaxLogBytes = 2 * 1024 * 1024
const maxLogPages = 64

export type ThreadRecreateReason =
  | 'cold_idle_recycle'
  | 'resume_failed'
  | 'respawn_runtime_incompatible'
  | 'turn_thread_lost'
  | 'continuation_without_thread'
  | 'workspace_evicted'

export type MaterializedExecutionLog = {
  reason: ThreadRecreateReason
  hasTaskLineage: boolean
  hasExecutionHistory: boolean
  historyLineCount: number
  historyTruncated: boolean
}

/**
 * Checks whether a continued Job is still holding the inherited `runtime_thread_id`
 * of its source Job while its frozen `runtime_projection` switched `provider_id` or
 * `model`.
 *
 * Once the successor Job creates and persists its own replacement thread, its
 * `runtime_thread_id` diverges from `sourceJob.runtime_thread_id`, so subsequent
 * retries or `waiting_on_user` resumes keep the successor's own healthy thread.
 */
export async function hasIncompatibleContinuationRuntime(input: {
  rpc: CodexJobOptions['rpc']
  jobTurn: JobTurnRef
  jobID: string
  sourceJobID: string
  runtimeThreadID: string
  currentJob: BackgroundAgentJobResponse
  abortSignal?: AbortSignal
  logger?: AgentLoopLogger
}): Promise<boolean> {
  const { rpc, jobTurn, jobID, sourceJobID, runtimeThreadID, currentJob, abortSignal, logger } = input
  if (!runtimeThreadID) return false
  const currentBinding = extractModelBinding(currentJob.runtimeProjectionJson)
  if (!currentBinding) return false

  try {
    const sourceJob = await rpc(
      'background_agent_job.get',
      { jobId: sourceJobID },
      { jobTurn },
      { retryOnDisconnect: true }
    )
    if (!sourceJob.runtimeThreadId || sourceJob.runtimeThreadId !== runtimeThreadID) {
      return false
    }
    const sourceBinding = extractModelBinding(sourceJob.runtimeProjectionJson)
    if (!sourceBinding) return false
    return sourceBinding.providerID !== currentBinding.providerID || sourceBinding.model !== currentBinding.model
  } catch (error) {
    logger?.warning(
      'worker.codex_continuation_projection_unavailable',
      'the continued Job could not read its source Job runtime projection',
      {
        job_id: jobID,
        source_job_id: sourceJobID,
        error: toError(error)
      }
    )
    if (isRuntimeFabricTransportError(error) || error instanceof RPCTimeoutError || abortSignal?.aborted) {
      throw error
    }
    return false
  }
}

function extractModelBinding(projectionBytes: Uint8Array): { providerID: string; model: string } | undefined {
  if (projectionBytes.byteLength === 0) return undefined
  const projection = jsonObjectFromBytes(projectionBytes, 'Job runtime projection')
  const modelRef = jsonObject(projection?.model_ref)
  const providerID = stringValue(modelRef.provider_id)
  const model = stringValue(modelRef.model)
  if (!providerID || !model) return undefined
  return { providerID, model }
}

/**
 * Pages durable TurnItem records and the workspace task/steer lineage from the
 * control plane and writes them atomically under `<projectRoot>/.ankole/`.
 *
 * Each page returned by `TrajectoryReader` is chronological within the page
 * while `executionLogNextCursor` walks backward toward older pages, so the
 * Worker reverses the array of pages while preserving intra-page line order.
 *
 * Transient transport errors, RPC timeouts, and aborts rethrow so the Job
 * retries the attempt instead of starting an amnesic replacement thread.
 */
export async function materializeJobExecutionLogfile(input: {
  rpc: CodexJobOptions['rpc']
  jobTurn: JobTurnRef
  jobID: string
  projectRoot: string
  reason: ThreadRecreateReason
  maxBytes?: number
  abortSignal?: AbortSignal
  logger?: AgentLoopLogger
}): Promise<MaterializedExecutionLog> {
  const { rpc, jobTurn, jobID, projectRoot, reason, abortSignal, logger } = input
  const maxBytes = input.maxBytes ?? defaultMaxLogBytes

  let cursor = 'head'
  let taskLineageBytes: Uint8Array = new Uint8Array(0)
  const pagesNewestFirst: string[][] = []
  let usedBytes = 0
  let historyTruncated = false

  try {
    for (let pageIndex = 0; pageIndex < maxLogPages; pageIndex += 1) {
      abortSignal?.throwIfAborted()
      const page = await rpc(
        'background_agent_job.get',
        { jobId: jobID, executionLogCursor: cursor },
        { jobTurn },
        { retryOnDisconnect: true }
      )

      if (pageIndex === 0 && page.taskLineageJson.byteLength > 0) {
        taskLineageBytes = page.taskLineageJson
      }

      if (page.executionLogJsonl.byteLength > 0) {
        const text = Buffer.from(page.executionLogJsonl).toString('utf8')
        const pageLines = text.split('\n').filter(line => line.length > 0)
        const remainingBytes = maxBytes - usedBytes
        const selected = takeNewestLinesWithinBudget(pageLines, remainingBytes)
        if (selected.lines.length > 0) {
          pagesNewestFirst.push(selected.lines)
          usedBytes += selected.bytes
        }
        if (selected.truncated) {
          historyTruncated = true
          break
        }
      }

      const nextCursor = page.executionLogNextCursor
      if (!nextCursor) break
      if (pageIndex + 1 >= maxLogPages) {
        historyTruncated = true
        break
      }
      cursor = nextCursor
    }
  } catch (error) {
    if (isRuntimeFabricTransportError(error) || error instanceof RPCTimeoutError || abortSignal?.aborted) {
      throw error
    }
    logger?.warning(
      'worker.codex_execution_logfile_unavailable',
      'the Job could not read durable execution history for thread recreation',
      {
        job_id: jobID,
        reason,
        error: toError(error)
      }
    )
    return {
      reason,
      hasTaskLineage: false,
      hasExecutionHistory: false,
      historyLineCount: 0,
      historyTruncated: false
    }
  }

  // Reverse page order (oldest page first) while keeping each page's internal chronological order.
  const chronologicalLines = pagesNewestFirst.reverse().flat()
  const hasTaskLineage = taskLineageBytes.byteLength > 0
  const hasExecutionHistory = chronologicalLines.length > 0

  const ankoleDir = join(projectRoot, EXECUTION_LOG_DIR)
  await ensureSafeLogDirectory(ankoleDir)

  if (hasTaskLineage) {
    await writeAgentAtomicFile(join(projectRoot, TASK_LINEAGE_REL_PATH), taskLineageBytes)
  } else {
    await rm(join(projectRoot, TASK_LINEAGE_REL_PATH), { force: true })
  }

  if (hasExecutionHistory) {
    const header: JSONObject = {
      type: 'logfile_meta',
      version: 1,
      job_id: Number(jobID),
      reason,
      line_count: chronologicalLines.length,
      truncated: historyTruncated
    }
    const content = `${JSON.stringify(header)}\n${chronologicalLines.join('\n')}\n`
    await writeAgentAtomicFile(join(projectRoot, EXECUTION_HISTORY_REL_PATH), Buffer.from(content, 'utf8'))
  } else {
    await rm(join(projectRoot, EXECUTION_HISTORY_REL_PATH), { force: true })
  }

  return {
    reason,
    hasTaskLineage,
    hasExecutionHistory,
    historyLineCount: chronologicalLines.length,
    historyTruncated
  }
}

function takeNewestLinesWithinBudget(
  chronologicalPageLines: string[],
  budgetBytes: number
): { lines: string[]; bytes: number; truncated: boolean } {
  if (budgetBytes <= 0) return { lines: [], bytes: 0, truncated: chronologicalPageLines.length > 0 }

  const reversedSelected: string[] = []
  let bytes = 0
  let truncated = false

  for (let index = chronologicalPageLines.length - 1; index >= 0; index -= 1) {
    const line = chronologicalPageLines[index]!
    const lineBytes = Buffer.byteLength(line, 'utf8') + 1
    if (bytes + lineBytes > budgetBytes) {
      truncated = true
      break
    }
    reversedSelected.push(line)
    bytes += lineBytes
  }

  reversedSelected.reverse()
  return { lines: reversedSelected, bytes, truncated }
}

async function ensureSafeLogDirectory(dirPath: string): Promise<void> {
  if (existsSync(dirPath)) {
    const stat = await lstat(dirPath)
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      await rm(dirPath, { recursive: true, force: true })
    }
  }
  await mkdirAgent(dirPath)
}

async function writeAgentAtomicFile(targetPath: string, data: Uint8Array): Promise<void> {
  if (existsSync(targetPath)) {
    const existing = await lstat(targetPath)
    if (existing.isSymbolicLink() || existing.isDirectory()) {
      await rm(targetPath, { recursive: true, force: true })
    }
  }
  const tmpPath = `${targetPath}.tmp.${process.pid}.${Date.now()}`
  await writeFile(tmpPath, data, { mode: 0o644 })
  await chownAgentPath(tmpPath)
  await rename(tmpPath, targetPath)
}
