import { basename } from 'node:path'
import { ms, type JsonObject as JSONObject } from '@agentbull/active-support'
import { errorMessage, toError } from '../../../common/errors'
import {
  formatDriveFlushSummary,
  type DriveFlushedFile,
  type DriveFlushResult,
  type DriveView
} from '../../../drive/mounts'
import type { BackgroundAgentJobResponse } from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { TurnSteerUpdate } from '../../../lanes/session-lane'
import type { BackgroundAgentJobStatus, BackgroundAgentJobTurnUsage } from '../../background-agent-job-documents'
import { boundedBackgroundAgentJobPaths, type BackgroundAgentJobPathHandoff } from '../../background-agent-job-handoff'
import type { CodexJobOptions } from '../options'
import { stringValue } from '../protocol'
import {
  AgentCodexRuntimeLostError,
  type AgentCodexRuntimeLease,
  type AgentCodexRuntimeSession
} from '../runtime/agent-runtime-manager'
import { CodexAppServerExitError, type CodexAppServerClient } from '../runtime/app-server-client'
import {
  classifyCodexRecoveryFailure,
  codexCredentialPoolExhaustion,
  transitionCodexRecovery,
  type CodexCredentialPoolExhaustion,
  type CodexRecoveryState
} from './recovery-policy'
import type { ThreadRecreateReason } from './execution-logfile'
import {
  artifactDiscoveryRoots,
  CodexCredentialPoolExhaustedError,
  CodexTurnNoProgressError,
  collectJobFilesChanged,
  compactContinuationInput,
  durableRetryError,
  ownerVisibleArtifactPaths,
  retryContinuationInput,
  steerActiveTurn,
  steerDisabledSkills
} from './session-support'
import type { PreparedCodexJobExecution } from './setup'
import type { CodexSkillUsageTracker } from './skill-usage'
import type { BackgroundAgentJobTurnRecorder } from './turn-recorder'
import type { WorkspaceSnapshot } from './workspace-snapshot'

// Detect an app-server that accepted turn/start but produced no event. This is
// not an overall Job timeout.
const defaultFirstCodexProgressTimeoutMs = ms('1m')

/**
 * Keeps Worker-local steering and Skill updates responsive without adding
 * RuntimeFabric traffic.
 */
const activeTurnUpdatePollIntervalMs = 250

export function startFirstProgressDeadlineTimer(input: {
  opts: CodexJobOptions
  jobID: string
  runtimeThreadID: () => string | undefined
  codexTurnID: () => string | undefined
  isStopped: () => boolean
  onClearTimer: () => void
  onTimeout: (error: Error) => void
}): ReturnType<typeof setTimeout> {
  const timeoutMs = input.opts.firstCodexProgressTimeoutMs ?? defaultFirstCodexProgressTimeoutMs
  const timer = setTimeout(() => {
    input.onClearTimer()
    if (input.isStopped()) return
    const error = new CodexTurnNoProgressError(timeoutMs)
    input.opts.logger?.warning(
      'worker.codex_turn_first_progress_timed_out',
      'Codex turn produced no runtime progress after turn/start',
      {
        job_id: input.jobID,
        runtime_thread_id: input.runtimeThreadID(),
        runtime_turn_id: input.codexTurnID(),
        timeout_ms: timeoutMs
      }
    )
    input.onTimeout(error)
  }, timeoutMs)
  timer.unref?.()
  return timer
}

export type JobCompletionState = 'complete' | 'incomplete'

export function parseJobCompletionState(outputText: string): JobCompletionState {
  return /^\s*(?:[-*]\s+)?(?:\*\*|`|#+\s*)?Outcome\s*:\s*(?:\*\*|`)?\s*incomplete\b/im.test(outputText)
    ? 'incomplete'
    : 'complete'
}

export function extractCitedDrivePaths(outputText: string): string[] {
  const matches = outputText.match(/\/drive\/(?!Library\/)[^\s`'")\]>]+/g) ?? []
  const cleaned = new Set<string>()
  for (const raw of matches) {
    const trimmed = raw.replace(/[.,;:!?]+$/, '')
    if (trimmed.length > '/drive/'.length && !trimmed.endsWith('/')) cleaned.add(trimmed)
  }
  return [...cleaned]
}

async function flushCitedDrivePaths(
  driveView: DriveView,
  paths: readonly string[],
  deliverablesMap: Map<string, DriveFlushedFile>,
  timeoutMs: number,
  abortSignal?: AbortSignal
): Promise<string[]> {
  if (paths.length === 0 || abortSignal?.aborted) return []
  const timeoutSignal = AbortSignal.timeout(timeoutMs)
  const signal = abortSignal ? AbortSignal.any([timeoutSignal, abortSignal]) : timeoutSignal
  const outcomes = await Promise.all(
    paths.map(async path => {
      try {
        const nodeId = await driveView.flushPath(path, signal)
        return { ok: true as const, path, nodeId }
      } catch {
        return { ok: false as const, path }
      }
    })
  )
  const failed: string[] = []
  for (const outcome of outcomes) {
    if (outcome.ok) {
      deliverablesMap.set(outcome.path, { path: outcome.path, nodeId: outcome.nodeId })
    } else {
      failed.push(outcome.path)
    }
  }
  return failed
}

async function abortableSleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (ms <= 0 || signal?.aborted) return
  await new Promise<void>(resolve => {
    const onAbort = () => {
      clearTimeout(timer)
      resolve()
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolve()
    }, ms)
    timer.unref?.()
    signal?.addEventListener('abort', onAbort, { once: true })
  })
}

export async function completeSucceededCodexTurn(input: {
  abortSignal?: AbortSignal
  isStopping: () => boolean
  driveFlush: DriveFlushResult
  driveDeliverables?: DriveFlushedFile[]
  driveView?: DriveView
  recordDriveDeliverables?: (files: readonly DriveFlushedFile[]) => void
  pendingDriveRetries?: number
  outputText: string
  emptyReportRetries: number
  root: string
  jobID: string
  attempt: number
  runtimeThreadID: string | undefined
  codexTurnStatus: string
  latestTokenUsage: BackgroundAgentJobTurnUsage | undefined
  completedFilesChanged: BackgroundAgentJobPathHandoff
  workspaceSnapshot: WorkspaceSnapshot | undefined
  logger: CodexJobOptions['logger']
  incrementEmptyReportRetries: () => void
  incrementPendingDriveRetries?: () => void
  startCodexTurn: (prompt: string) => Promise<void>
  commit: (status: BackgroundAgentJobStatus, details: { result?: JSONObject; error?: JSONObject }) => Promise<void>
}): Promise<void> {
  if (input.isStopping()) return
  if (input.driveFlush.status === 'failed') {
    const summary = formatDriveFlushSummary(input.driveFlush)
    await input.startCodexTurn(
      `${summary}\nResolve these Drive writes or report the saved recovery files before completing the Job.`
    )
    return
  }

  const deliverablesMap = new Map<string, DriveFlushedFile>(
    (input.driveDeliverables ?? input.driveFlush.files).map(file => [file.path, file])
  )
  for (const file of input.driveFlush.files) deliverablesMap.set(file.path, file)

  const citedPaths = extractCitedDrivePaths(input.outputText)

  if (input.driveFlush.status === 'pending') {
    const flushIncomplete = input.driveFlush.flush_incomplete === true
    const pathsToFlush = [...new Set([...input.driveFlush.paths, ...citedPaths])].filter(
      path => !deliverablesMap.has(path)
    )
    if (input.driveView && pathsToFlush.length > 0) {
      await flushCitedDrivePaths(input.driveView, pathsToFlush, deliverablesMap, 30_000, input.abortSignal)
      if (input.isStopping()) return
      input.recordDriveDeliverables?.([...deliverablesMap.values()])
    }
    // Keep driveFlush.paths authoritative so uncreated prose `/drive/...` mentions never stall completion.
    const unresolved = input.driveFlush.paths.filter(pendingPath => !deliverablesMap.has(pendingPath))
    if (unresolved.length > 0 || flushIncomplete) {
      if ((input.pendingDriveRetries ?? 0) < 1) {
        input.incrementPendingDriveRetries?.()
        const summary = formatDriveFlushSummary({ ...input.driveFlush, paths: unresolved })
        await input.startCodexTurn(
          `${summary}\nVerify that every required Drive deliverable has finished uploading before completing the Job.`
        )
        return
      }
      await input.commit('failed', {
        error: {
          code: 'drive_sync_incomplete',
          summary: formatDriveFlushSummary({ ...input.driveFlush, paths: unresolved }),
          pending_paths: unresolved,
          ...(flushIncomplete ? { flush_incomplete: true } : {})
        }
      })
      return
    }
  } else if (input.driveView) {
    // Cited path may be a non-existent example or directory; keep flushed deliverables authoritative.
    await flushCitedDrivePaths(
      input.driveView,
      citedPaths.filter(path => !deliverablesMap.has(path)),
      deliverablesMap,
      15_000,
      input.abortSignal
    )
    if (input.isStopping()) return
    input.recordDriveDeliverables?.([...deliverablesMap.values()])
  }

  const finalOutputText = input.outputText
  if (!stringValue(finalOutputText)) {
    if (input.emptyReportRetries < 1) {
      input.incrementEmptyReportRetries()
      await input.startCodexTurn(
        'The Job produced no final report. Inspect the completed work and reply with a concise final report that states the outcome and verifies the acceptance criteria.'
      )
      return
    }
    await input.commit('failed', {
      error: {
        code: 'codex_empty_report',
        summary: 'Codex completed without a final response after one report retry.'
      }
    })
    return
  }

  const deliverables = [...deliverablesMap.values()].map(item => {
    const name = basename(item.path)
    const rawMime = Bun.file(name).type.split(';')[0]?.trim() || 'application/octet-stream'
    return {
      path: item.path,
      node_id: item.nodeId,
      name,
      mime_type: rawMime
    }
  })

  const result = await buildSucceededJobResult({
    root: input.root,
    jobID: input.jobID,
    attempt: input.attempt,
    outputText: finalOutputText,
    completionState: parseJobCompletionState(finalOutputText),
    deliverables,
    runtimeThreadID: input.runtimeThreadID,
    codexTurnStatus: input.codexTurnStatus,
    latestTokenUsage: input.latestTokenUsage,
    completedFilesChanged: input.completedFilesChanged,
    workspaceSnapshot: input.workspaceSnapshot,
    logger: input.logger
  })
  if (input.isStopping()) return
  await input.commit('succeeded', { result })
}

async function buildSucceededJobResult(input: {
  root: string
  jobID: string
  attempt: number
  outputText: string
  completionState: JobCompletionState
  deliverables: Array<{ path: string; node_id: string; name: string; mime_type: string }>
  runtimeThreadID: string | undefined
  codexTurnStatus: string
  latestTokenUsage: BackgroundAgentJobTurnUsage | undefined
  completedFilesChanged: BackgroundAgentJobPathHandoff
  workspaceSnapshot: WorkspaceSnapshot | undefined
  logger: CodexJobOptions['logger']
}): Promise<JSONObject> {
  const { handoff: filesChanged, sources: filesChangedSources } = await collectJobFilesChanged({
    root: input.root,
    jobID: input.jobID,
    codexDiff: input.completedFilesChanged,
    beforeSnapshot: input.workspaceSnapshot,
    logger: input.logger
  })
  const artifactPaths = ownerVisibleArtifactPaths(input.root, filesChanged.paths)
  return {
    output_text: input.outputText,
    completion_state: input.completionState,
    stop_reason: 'completed',
    attempt: input.attempt,
    ...(input.runtimeThreadID ? { runtime_thread_id: input.runtimeThreadID } : {}),
    codex_turn_status: input.codexTurnStatus,
    ...(input.latestTokenUsage ? { usage: input.latestTokenUsage } : {}),
    ...(input.deliverables.length > 0 ? { deliverables: input.deliverables } : {}),
    files_changed: filesChanged,
    files_changed_source: filesChangedSources,
    project_path: input.root,
    artifacts: boundedBackgroundAgentJobPaths(artifactPaths, {
      totalCount: filesChanged.total_count,
      truncated: filesChanged.truncated || artifactPaths.length < filesChanged.paths.length
    }),
    artifact_roots: artifactDiscoveryRoots(input.root)
  }
}

export async function recoverOrCommitFailedCodexTurn(input: {
  abortSignal?: AbortSignal
  isStopping: () => boolean
  error: JSONObject
  codexTurnStatus: string
  outputText: string
  pendingCredentialPoolExhaustion: CodexCredentialPoolExhaustion | undefined
  recoveryState: CodexRecoveryState
  canCompact: boolean
  job: BackgroundAgentJobResponse
  setRecoveryState: (state: CodexRecoveryState) => void
  startCodexTurn: (prompt: string) => Promise<void>
  compactThread: () => Promise<void>
  replaceThreadAndStartTurn: (reason: ThreadRecreateReason, continuationPrompt: string) => Promise<void>
  commit: (status: BackgroundAgentJobStatus, details: { error: JSONObject }) => Promise<void>
}): Promise<void> {
  if (input.isStopping()) return
  const poolExhaustion = codexCredentialPoolExhaustion(input.error) ?? input.pendingCredentialPoolExhaustion
  if (poolExhaustion) throw new CodexCredentialPoolExhaustedError(poolExhaustion, input.error)

  const failure = classifyCodexRecoveryFailure(input.error)
  const decision = transitionCodexRecovery({
    stage: 'turn',
    failure,
    state: input.recoveryState,
    canCompact: input.canCompact
  })
  input.setRecoveryState(decision.nextState)

  if (decision.action === 'retry_turn') {
    await abortableSleep(decision.delayMs ?? 0, input.abortSignal)
    if (input.isStopping()) return
    await input.startCodexTurn(retryContinuationInput())
    return
  }
  if (decision.action === 'compact_then_retry') {
    await input.compactThread()
    if (input.isStopping()) return
    await input.startCodexTurn(compactContinuationInput(input.job.task))
    return
  }
  if (decision.action === 'replace_thread') {
    await input.replaceThreadAndStartTurn('turn_thread_lost', retryContinuationInput())
    return
  }
  if (decision.action === 'durable_retry') throw durableRetryError(input.error)

  await input.commit('failed', {
    error: {
      code: stringValue(input.error.codexErrorInfo) ?? 'codex_turn_failed',
      summary: stringValue(input.error.message) ?? (input.outputText || `Codex turn ${input.codexTurnStatus}`),
      codex_turn_status: input.codexTurnStatus,
      codex_error: input.error
    }
  })
}

export function startSessionActiveTurnUpdatePoll(input: {
  opts: CodexJobOptions
  prepared: PreparedCodexJobExecution
  skillUsage: CodexSkillUsageTracker
  turnRecorder: BackgroundAgentJobTurnRecorder
  appliedEventIDs: Set<string>
  state: () => {
    blocked: boolean
    client: CodexAppServerClient | undefined
    runtimeThreadID: string | undefined
    codexTurnID: string | undefined
  }
  isFinalizing: () => boolean
  setInFlight: (inFlight: boolean) => void
  trackInFlight?: (promise: Promise<void>) => void
  applyOriginalHumanRequest: (update: TurnSteerUpdate) => void
  onFatalError: (error: Error) => void
}): ReturnType<typeof setInterval> {
  const pendingUpdates: TurnSteerUpdate[] = []
  const removePendingUpdate = (update: TurnSteerUpdate) => {
    const index = pendingUpdates.indexOf(update)
    if (index !== -1) pendingUpdates.splice(index, 1)
  }
  const timer = setInterval(() => {
    // Apply Skill disables before the Codex readiness checks. A running Job
    // must stop exposing a disabled Skill while another update is in flight.
    const disabledSkills = input.opts.pollDisabledSkills?.() ?? []
    input.prepared.skills.loader.disable(disabledSkills)
    input.skillUsage.disable(disabledSkills)
    const { blocked, client, runtimeThreadID, codexTurnID } = input.state()
    if (blocked || !client || !runtimeThreadID || !codexTurnID) return
    const freshUpdates = input.opts.pollSteering?.() ?? []
    if (freshUpdates.length > 0) pendingUpdates.push(...freshUpdates)
    const disabledNotices = input.skillUsage.pendingDisabledNotices()
    if (pendingUpdates.length === 0 && disabledNotices.length === 0) return
    input.setInFlight(true)
    const batchUpdates = [...pendingUpdates]
    const updateRun = steerDisabledSkills(
      client,
      runtimeThreadID,
      codexTurnID,
      disabledNotices,
      () => !input.isFinalizing(),
      async (name, eventID, text) => {
        input.skillUsage.markNotified(name)
        input.turnRecorder.recordSteering(codexTurnID, eventID, text)
        await input.turnRecorder.flush()
      }
    )
      .then(() =>
        steerActiveTurn(
          client,
          runtimeThreadID,
          codexTurnID,
          batchUpdates,
          () => !input.isFinalizing(),
          async (eventID, text, update) => {
            input.applyOriginalHumanRequest(update)
            input.turnRecorder.recordSteering(codexTurnID, eventID, text)
            await input.turnRecorder.flush()
          },
          async update => {
            removePendingUpdate(update)
            if (!update.signal) return
            input.appliedEventIDs.add(update.signal.signal_id)
          },
          removePendingUpdate
        )
      )
      .catch(error => {
        input.onFatalError(toError(error))
      })
      .finally(() => {
        input.setInFlight(false)
      })
    input.trackInFlight?.(updateRun)
  }, activeTurnUpdatePollIntervalMs)
  timer.unref?.()
  return timer
}

export async function runCodexSessionWithCleanup(input: {
  execute: () => Promise<void>
  done: Promise<void>
  agentUID: string
  jobID: string
  opts: CodexJobOptions
  prepared: PreparedCodexJobExecution
  turnRecorder: BackgroundAgentJobTurnRecorder
  session: AgentCodexRuntimeSession
  isFinalizing: () => boolean
  markFinalizing: () => void
  codexTurnID: () => string | undefined
  stopTimersAndListeners: () => void
  onClosed?: () => void
  waitForTurnCompletionTail?: () => Promise<void>
  waitForActiveTurnUpdateTail?: () => Promise<void>
  runtimeLease: () => AgentCodexRuntimeLease | undefined
  durableJobStatusCommitted: () => boolean
}): Promise<void> {
  let thrownError: unknown
  let hasThrownError = false

  try {
    await input.execute()
  } catch (caughtError) {
    if (input.isFinalizing()) {
      try {
        await input.done
      } catch (finalizationError) {
        thrownError = finalizationError
        hasThrownError = true
      }
    } else {
      input.markFinalizing()
      // A shared app-server exit seen by this Job is the same retryable
      // runtime loss that registered threads receive from the fan-out.
      let error =
        caughtError instanceof CodexAppServerExitError
          ? new AgentCodexRuntimeLostError(input.agentUID, caughtError)
          : caughtError
      input.turnRecorder.finishTurn(input.codexTurnID(), 'failed', {
        code: 'background_agent_job_runtime_exception',
        summary: errorMessage(error)
      })
      try {
        await input.turnRecorder.flush()
      } catch (trajectoryError) {
        error = trajectoryError
      }
      thrownError = error
      hasThrownError = true
    }
  }

  input.stopTimersAndListeners()
  try {
    await input.waitForTurnCompletionTail?.()
  } catch {
    // A rejection inside turnCompletionTail is surfaced through done or post-commit logging.
  }
  try {
    await input.waitForActiveTurnUpdateTail?.()
  } catch {
    // A steering flush error is handled on the update poll itself or logged during teardown.
  }

  // After durable Job status commits, cleanup failures are diagnostic only.
  // Before the commit, a cleanup failure fails the Worker Turn.
  const captureCleanupError = (stage: string, error: unknown): void => {
    if (input.durableJobStatusCommitted()) {
      input.opts.logger?.warning(
        'worker.codex_job_post_commit_cleanup_failed',
        'Background Agent Job cleanup failed after its durable status commit',
        { job_id: input.jobID, stage, error: toError(error) }
      )
      return
    }
    if (hasThrownError) return
    thrownError = error
    hasThrownError = true
  }

  const lease = input.runtimeLease()
  if (lease) {
    try {
      await lease.runtime.cleanupSession(input.session)
    } catch (error) {
      captureCleanupError('runtime', error)
    }
  }
  try {
    await input.prepared.cleanup()
  } catch (error) {
    captureCleanupError('materials', error)
  }
  try {
    await input.turnRecorder.flush()
  } catch (error) {
    captureCleanupError('trajectory', error)
  } finally {
    input.turnRecorder.close()
  }
  try {
    await lease?.release()
  } catch (error) {
    captureCleanupError('lease', error)
  } finally {
    input.onClosed?.()
  }

  if (hasThrownError) throw thrownError
}
