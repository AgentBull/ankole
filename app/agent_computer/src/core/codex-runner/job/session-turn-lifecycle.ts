import { ms, type JsonObject as JSONObject } from '@agentbull/active-support'
import { errorMessage, toError } from '../../../common/errors'
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

export async function completeSucceededCodexTurn(input: {
  driveSummary: string
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
  appendOutputText: (suffix: string) => string
  incrementEmptyReportRetries: () => void
  startCodexTurn: (prompt: string) => Promise<void>
  commit: (status: BackgroundAgentJobStatus, details: { result?: JSONObject; error?: JSONObject }) => Promise<void>
}): Promise<void> {
  if (input.driveSummary.includes('Drive write failed:')) {
    await input.startCodexTurn(
      `${input.driveSummary}\nResolve these Drive writes or report the saved recovery files before completing the Job.`
    )
    return
  }
  const finalOutputText = input.driveSummary ? input.appendOutputText(`\n\n${input.driveSummary}`) : input.outputText
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

  const result = await buildSucceededJobResult({
    root: input.root,
    jobID: input.jobID,
    attempt: input.attempt,
    outputText: finalOutputText,
    runtimeThreadID: input.runtimeThreadID,
    codexTurnStatus: input.codexTurnStatus,
    latestTokenUsage: input.latestTokenUsage,
    completedFilesChanged: input.completedFilesChanged,
    workspaceSnapshot: input.workspaceSnapshot,
    logger: input.logger
  })
  await input.commit('succeeded', { result })
}

async function buildSucceededJobResult(input: {
  root: string
  jobID: string
  attempt: number
  outputText: string
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
    stop_reason: 'completed',
    attempt: input.attempt,
    ...(input.runtimeThreadID ? { runtime_thread_id: input.runtimeThreadID } : {}),
    codex_turn_status: input.codexTurnStatus,
    ...(input.latestTokenUsage ? { usage: input.latestTokenUsage } : {}),
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
    await Bun.sleep(decision.delayMs ?? 0)
    await input.startCodexTurn(retryContinuationInput())
    return
  }
  if (decision.action === 'compact_then_retry') {
    await input.compactThread()
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
  applyOriginalHumanRequest: (update: TurnSteerUpdate) => void
  onFatalError: (error: Error) => void
}): ReturnType<typeof setInterval> {
  const timer = setInterval(() => {
    // Apply Skill disables before the Codex readiness checks. A running Job
    // must stop exposing a disabled Skill while another update is in flight.
    const disabledSkills = input.opts.pollDisabledSkills?.() ?? []
    input.prepared.skills.loader.disable(disabledSkills)
    input.skillUsage.disable(disabledSkills)
    const { blocked, client, runtimeThreadID, codexTurnID } = input.state()
    if (blocked || !client || !runtimeThreadID || !codexTurnID) return
    const updates = input.opts.pollSteering?.() ?? []
    const disabledNotices = input.skillUsage.pendingDisabledNotices()
    if (updates.length === 0 && disabledNotices.length === 0) return
    input.setInFlight(true)
    void steerDisabledSkills(
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
          updates,
          () => !input.isFinalizing(),
          async (eventID, text, update) => {
            input.applyOriginalHumanRequest(update)
            input.turnRecorder.recordSteering(codexTurnID, eventID, text)
            await input.turnRecorder.flush()
          },
          async update => {
            if (!update.signal) return
            input.appliedEventIDs.add(update.signal.signal_id)
          }
        )
      )
      .catch(error => {
        input.onFatalError(toError(error))
      })
      .finally(() => {
        input.setInFlight(false)
      })
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
  }
  try {
    await lease?.release()
  } catch (error) {
    captureCleanupError('lease', error)
  }

  if (hasThrownError) throw thrownError
}
