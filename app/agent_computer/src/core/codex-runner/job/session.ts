import { compareCodePointStrings } from '../../../common/ordering'
import { jsonObject, ms, type JsonObject as JSONObject } from '@agentbull/active-support'
import { existsSync, realpathSync, statSync } from 'node:fs'
import { resolve } from 'node:path'
import { errorMessage, toError } from '../../../common/errors'
import { jsonBytes } from '../../../fabric/envelope_proto'
import type { TurnStart, TurnSteerUpdate } from '../../../lanes/actor_lane'
import { rpcMethods, type BackgroundAgentJobResponse } from '../../../lanes/rpc_lane'
import type {
  BackgroundAgentJobStatus,
  BackgroundAgentJobTurnKind,
  BackgroundAgentJobTurnUsage
} from '../../background-agent-job-documents'
import {
  CodexAppServerClient,
  CodexAppServerExitError,
  CodexAppServerRPCError,
  type JSONRPCMessage
} from '../runtime/app-server-client'
import type { DynamicToolCallParams } from '../generated/protocol/v2/DynamicToolCallParams'
import {
  boundedBackgroundAgentJobPaths,
  emptyBackgroundAgentJobPathHandoff,
  mergeBackgroundAgentJobPathHandoffs,
  type BackgroundAgentJobPathHandoff
} from '../../background-agent-job-handoff'
import { pathIsWithin } from '../../path-boundary'
import {
  approvalAcceptance,
  approvalRequestMethod,
  projectCodexNotification,
  stringValue,
  textInput
} from '../protocol'
import type { CodexJobOptions, TurnHandlerResult } from '../../turns/turn_options'
import { pendingParentInputFromDynamicTool, PARENT_INPUT_TOOL_NAME } from './parent-input'
import {
  classifyCodexRecoveryFailure,
  codexCredentialPoolExhaustion,
  initialCodexRecoveryState,
  transitionCodexRecovery,
  type CodexCredentialPoolExhaustion,
  type CodexRecoveryState
} from './recovery-policy'
import type { PreparedCodexJobExecution } from './setup'
import { codexJobModelProfile, type CodexAIGatewayModelProfile } from '../runtime-config'
import { BackgroundAgentJobTurnRecorder } from './turn-recorder'
import { workerTurnTrace } from '../../../observability/turn-tracing'
import {
  agentCodexRuntimeManager,
  AgentCodexRuntimeLostError,
  type AgentCodexRuntimeLease,
  type AgentCodexRuntimeSession
} from '../runtime/agent-runtime-manager'
import { CodexSkillUsageTracker, skillDisabledNotice } from './skill-usage'
import { fetchReplayTurnItems, wireItemsFromTurnItems } from './thread-replay'

/**
 * Keeps Worker-local steering and Skill updates responsive without adding
 * RuntimeFabric traffic.
 */
const activeTurnUpdatePollIntervalMs = 250
// Detect an app-server that accepted turn/start but produced no event. This is
// not an overall Job timeout.
const defaultFirstCodexProgressTimeoutMs = ms('1m')

export async function runCodexJobSession(
  turnStart: TurnStart,
  opts: CodexJobOptions,
  jobID: string,
  job: BackgroundAgentJobResponse,
  prepared: PreparedCodexJobExecution
): Promise<TurnHandlerResult> {
  return new CodexJobSession(turnStart, opts, jobID, job, prepared).run()
}

/**
 * Owns one durable Job attempt and its Codex thread set.
 * A terminal Worker result follows the Turn-record flush and durable Job-status
 * commit.
 */
class CodexJobSession implements AgentCodexRuntimeSession {
  private readonly turnRecorder: BackgroundAgentJobTurnRecorder
  private readonly modelProfile: CodexAIGatewayModelProfile
  private readonly expectedSkillNames: string[]
  private readonly skillUsage: CodexSkillUsageTracker
  private readonly done: Promise<void>
  private resolveDone!: () => void
  private rejectDone!: (error: Error) => void

  private client: CodexAppServerClient | undefined
  private runtimeLease: AgentCodexRuntimeLease | undefined
  private runtimeThreadID: string | undefined
  private codexTurnID: string | undefined
  private outputText = ''
  private latestTokenUsage: BackgroundAgentJobTurnUsage | undefined
  private completedFilesChanged: BackgroundAgentJobPathHandoff = emptyBackgroundAgentJobPathHandoff()
  private activeFilesChanged: BackgroundAgentJobPathHandoff = emptyBackgroundAgentJobPathHandoff()
  private waitingOnUserInput = false
  private recoveryInFlight = false
  private completionPending = false
  private recoveryState: CodexRecoveryState = initialCodexRecoveryState
  private pendingCredentialPoolExhaustion: CodexCredentialPoolExhaustion | undefined
  private emptyReportRetries = 0
  private recreatedThreadOnResume = false
  private replayedThreadOnResume = false
  private suppressRuntimeCapture = false
  private finalizing = false
  private closing = false
  private acceptingServerRequests = true
  private runtimeCleaned = false
  private durableJobStatusCommitted = false
  private readonly toolAbortController = new AbortController()
  private turnResult: TurnHandlerResult | undefined
  private activeTurnUpdateTimer: ReturnType<typeof setInterval> | undefined
  private firstProgressTimer: ReturnType<typeof setTimeout> | undefined
  private leadRuntimeProgressVersion = 0
  private activeTurnUpdateInFlight = false
  private compaction: CompactionHandshake | undefined

  constructor(
    private readonly turnStart: TurnStart,
    private readonly opts: CodexJobOptions,
    private readonly jobID: string,
    private readonly job: BackgroundAgentJobResponse,
    private readonly prepared: PreparedCodexJobExecution
  ) {
    this.runtimeThreadID = job.runtimeThreadId || undefined
    this.modelProfile = codexJobModelProfile(turnStart)
    this.expectedSkillNames = prepared.skills.loadable.map(skill => skill.skillName).sort(compareCodePointStrings)
    this.skillUsage = new CodexSkillUsageTracker({
      availableSkillNames: this.expectedSkillNames,
      mcpServers: prepared.skills.mcpServers,
      attemptHistory: job.attemptHistory
    })
    this.turnRecorder = new BackgroundAgentJobTurnRecorder({
      jobID,
      attempt: job.attempts,
      actorTurn: turnStart.turn,
      turnTrace: workerTurnTrace(turnStart),
      upsert: request => opts.rpc(rpcMethods.backgroundAgentJobTurnUpsert, request, { turn: turnStart.turn })
    })
    this.done = new Promise<void>((resolve, reject) => {
      this.resolveDone = resolve
      this.rejectDone = reject
    })
  }

  async run(): Promise<TurnHandlerResult> {
    let thrownError: unknown
    let hasThrownError = false

    try {
      await this.execute()
      this.turnResult = {
        kind: 'noop_completed',
        reason: 'background_agent_job_committed'
      }
    } catch (caughtError) {
      if (this.finalizing) {
        try {
          await this.done
          this.turnResult = {
            kind: 'noop_completed',
            reason: 'background_agent_job_committed'
          }
        } catch (finalizationError) {
          thrownError = finalizationError
          hasThrownError = true
        }
      } else {
        this.finalizing = true
        // A shared app-server exit seen by this Job is the same retryable
        // runtime loss that registered threads receive from the fan-out.
        let error =
          caughtError instanceof CodexAppServerExitError
            ? new AgentCodexRuntimeLostError(this.job.agentUid, caughtError)
            : caughtError
        this.turnRecorder.finishTurn(this.codexTurnID, 'failed', {
          code: 'background_agent_job_runtime_exception',
          summary: errorMessage(error)
        })
        try {
          await this.turnRecorder.flush()
        } catch (trajectoryError) {
          error = trajectoryError
        }
        thrownError = error
        hasThrownError = true
      }
    }

    if (this.activeTurnUpdateTimer) clearInterval(this.activeTurnUpdateTimer)
    this.clearFirstProgressDeadline()
    this.opts.abortSignal?.removeEventListener('abort', this.onAbort)
    this.closing = true

    // After durable Job status commits, cleanup failures are diagnostic only.
    // Before the commit, a cleanup failure fails the Worker Turn.
    const captureCleanupError = (stage: string, error: unknown): void => {
      if (this.durableJobStatusCommitted) {
        this.opts.logger?.warning(
          'worker.codex_job_post_commit_cleanup_failed',
          'Background Agent Job cleanup failed after its durable status commit',
          { job_id: this.jobID, stage, error: toError(error) }
        )
        return
      }
      if (hasThrownError) return
      thrownError = error
      hasThrownError = true
    }

    if (this.runtimeLease && !this.runtimeCleaned) {
      try {
        await this.runtimeLease.runtime.cleanupSession(this)
        this.runtimeCleaned = true
      } catch (error) {
        captureCleanupError('runtime', error)
      }
    }
    try {
      await this.prepared.cleanup()
    } catch (error) {
      captureCleanupError('materials', error)
    }
    try {
      await this.turnRecorder.flush()
    } catch (error) {
      captureCleanupError('trajectory', error)
    }
    try {
      await this.runtimeLease?.release()
    } catch (error) {
      captureCleanupError('lease', error)
    }

    if (hasThrownError) throw thrownError
    if (!this.turnResult) throw new Error('background agent job turn ended without a result')
    return this.turnResult
  }

  private async execute(): Promise<void> {
    const abortSignal = this.opts.abortSignal
    abortSignal?.addEventListener('abort', this.onAbort, { once: true })
    if (abortSignal?.aborted) this.onAbort()
    if (await this.finishClaimedFinalization()) return

    this.runtimeLease = await agentCodexRuntimeManager.acquire({
      ...this.prepared.runtimeAcquire,
      logger: this.opts.logger,
      ...(abortSignal ? { abortSignal } : {})
    })
    this.client = this.runtimeLease.runtime.client
    const initializeResponse = jsonObject(this.runtimeLease.runtime.initializeResponse)
    if (await this.finishClaimedFinalization()) return

    await this.runtimeLease.runtime.ensureAgentPlugins({
      cwd: this.prepared.runtimeAcquire.agentHome,
      prepared: this.prepared.preparedAgentPlugins
    })
    if (await this.finishClaimedFinalization()) return

    const resumeOutcome = this.prepared.replaceLegacySkillThread
      ? await this.replaceLostThread()
      : await this.resumeExistingThread()
    this.recreatedThreadOnResume = resumeOutcome === 'recreated'
    this.replayedThreadOnResume = resumeOutcome === 'replayed'
    if (await this.finishClaimedFinalization()) return
    if (!this.runtimeThreadID) await this.startNewThread()
    if (await this.finishClaimedFinalization()) return
    abortSignal?.throwIfAborted()
    await this.publishRunningStatus(initializeResponse)
    if (await this.finishClaimedFinalization()) return

    const initialTurnInput = turnInput(this.turnStart, this.job)
    const effectiveTurnInput = this.recreatedThreadOnResume
      ? recreatedThreadInput(this.job, initialTurnInput, await this.continuationSourceContext())
      : initialTurnInput
    await this.startCodexTurn(effectiveTurnInput)
    if (await this.finishClaimedFinalization()) return
    this.startActiveTurnUpdatePoll()
    await this.done
  }

  private async resumeExistingThread(): Promise<'none' | 'resumed' | 'replayed' | 'recreated'> {
    if (!this.runtimeThreadID || !this.client || !this.runtimeLease) return 'none'
    const resumedThreadID = this.runtimeThreadID
    try {
      await this.runtimeLease.runtime.resumeRoot(resumedThreadID, this, async () => {
        await this.client!.request('thread/resume', {
          ['threadId']: resumedThreadID,
          cwd: this.prepared.project.root,
          runtimeWorkspaceRoots: [this.prepared.project.root],
          approvalPolicy: 'never',
          sandbox: 'danger-full-access',
          modelProvider: 'ankole_aigateway',
          config: this.prepared.threadConfig,
          model: this.modelProfile.model
        })
      })
      this.opts.onTurnActivity?.('codex:thread_resumed')
      return 'resumed'
    } catch (error) {
      const decision = transitionCodexRecovery({
        stage: 'resume',
        failure: classifyCodexRecoveryFailure(
          error instanceof CodexAppServerRPCError ? error.details : { message: errorMessage(error) }
        ),
        state: this.recoveryState
      })
      this.recoveryState = decision.nextState
      if (decision.action === 'durable_retry') {
        throw durableRetryError(
          error instanceof CodexAppServerRPCError ? error.details : { message: errorMessage(error) }
        )
      }
      if (decision.action !== 'replace_thread') throw error
      return this.replaceLostThread()
    }
  }

  /**
   * Rebuilds the runtime thread after native state is gone or its frozen
   * capability projection is obsolete.
   *
   * The ladder is: replay the control plane's stored turn items into a fresh
   * thread; when the store has nothing to replay or the inject fails, keep
   * the fresh thread and let the recreated-thread input continue from the
   * durable Workspace instead. Both outcomes are disclosed through the Job's
   * runtime metadata.
   */
  private async replaceLostThread(): Promise<'replayed' | 'recreated'> {
    let wireItems: ReturnType<typeof wireItemsFromTurnItems> = []
    try {
      const stored = await fetchReplayTurnItems(this.opts.rpc, this.turnStart.turn, this.jobID)
      wireItems = wireItemsFromTurnItems(stored)
    } catch (error) {
      this.opts.logger?.warning(
        'worker.codex_thread_replay_fetch_failed',
        'stored turn items were not readable for thread replay',
        { job_id: this.jobID, error: toError(error) }
      )
    }

    this.runtimeThreadID = undefined
    await this.startNewThread()
    if (wireItems.length === 0) return 'recreated'

    this.suppressRuntimeCapture = true
    try {
      await this.client!.request('thread/inject_items', {
        ['threadId']: this.runtimeThreadID,
        items: wireItems
      })
    } catch (error) {
      this.opts.logger?.warning(
        'worker.codex_thread_replay_inject_failed',
        'stored turn items could not be injected into the replacement thread',
        { job_id: this.jobID, error: toError(error) }
      )
      return 'recreated'
    } finally {
      this.suppressRuntimeCapture = false
    }

    this.opts.onTurnActivity?.('codex:thread_replayed')
    return 'replayed'
  }

  /**
   * Fetches the terminal source Job's task and final report for a continued
   * Job whose thread context could not be restored. Both facts are durable on
   * the source Job row; absence of either keeps the rebuild honest instead of
   * blocking it.
   */
  private async continuationSourceContext(): Promise<ContinuationSourceContext | undefined> {
    const sourceJobID = this.job.continuedFromJobId
    if (!sourceJobID) return undefined
    try {
      const source = await this.opts.rpc(
        rpcMethods.backgroundAgentJobGet,
        { jobId: sourceJobID },
        { turn: this.turnStart.turn }
      )
      return {
        task: stringValue(source.task),
        finalReport: stringValue(source.resultOutputText)
      }
    } catch (error) {
      this.opts.logger?.warning(
        'worker.codex_continuation_source_unavailable',
        'the continued Job could not read its source Job for the rebuilt thread seed',
        {
          job_id: this.jobID,
          source_job_id: sourceJobID,
          error: toError(error)
        }
      )
      return undefined
    }
  }

  private async publishRunningStatus(initializeResponse: JSONObject): Promise<void> {
    if (!this.runtimeThreadID) throw new Error('codex thread is not available')
    const { projection, project, skills } = this.prepared
    await this.opts.rpc(
      rpcMethods.backgroundAgentJobStatusUpdate,
      {
        jobId: this.jobID,
        status: 'running',
        runtimeThreadId: this.runtimeThreadID,
        metadataJson: jsonBytes({
          codex_user_agent: stringValue(initializeResponse.userAgent),
          job_project_cwd: project.root,
          job_workspace: project.root,
          codex_app_server_pid: this.client?.processID,
          mcp_server_names: skills.mcpServers.map(server => server.name).sort(compareCodePointStrings),
          ...(this.recreatedThreadOnResume
            ? {
                runtime_checkpoint_recreated: true,
                runtime_checkpoint_recovery: 'new_thread_from_bounded_history'
              }
            : {}),
          ...(this.replayedThreadOnResume
            ? {
                runtime_checkpoint_recreated: true,
                runtime_checkpoint_recovery: 'replayed_from_transcript'
              }
            : {}),
          projected_tool_names: projection.dynamicTools.map(tool => tool.name),
          quarantined_tool_names: projection.quarantinedTools,
          shared_skill_count: this.expectedSkillNames.length
        })
      },
      { turn: this.turnStart.turn }
    )
  }

  private async commit(
    status: BackgroundAgentJobStatus,
    details: {
      result?: JSONObject
      error?: JSONObject
      metadata?: JSONObject
    } = {}
  ): Promise<void> {
    if (!this.claimFinalization()) return
    await this.commitClaimed(status, details)
  }

  private claimFinalization(): boolean {
    if (this.finalizing) return false
    this.finalizing = true
    return true
  }

  private async commitClaimed(
    status: BackgroundAgentJobStatus,
    details: {
      result?: JSONObject
      error?: JSONObject
      metadata?: JSONObject
    } = {}
  ): Promise<void> {
    try {
      if (status === 'waiting_on_user') {
        this.turnRecorder.interruptTurn(this.codexTurnID, {
          code: 'request_user_input',
          summary: 'Codex was interrupted while waiting for user input.'
        })
      } else if (status === 'failed' || status === 'stopped') {
        this.turnRecorder.finishTurn(this.codexTurnID, status, details.error)
      }
      await this.turnRecorder.flush()
      await this.opts.rpc(
        rpcMethods.backgroundAgentJobStatusUpdate,
        {
          jobId: this.jobID,
          status,
          ...(this.runtimeThreadID ? { runtimeThreadId: this.runtimeThreadID } : {}),
          ...(details.result ? { resultJson: jsonBytes(details.result) } : {}),
          ...(details.error ? { errorJson: jsonBytes(details.error) } : {}),
          ...(details.metadata ? { metadataJson: jsonBytes(details.metadata) } : {})
        },
        { turn: this.turnStart.turn }
      )
      this.durableJobStatusCommitted = true
      this.resolveDone()
    } catch (error) {
      this.rejectDone(toError(error))
    }
  }

  private async interruptCodexTurn(threadID: string, turnID: string): Promise<void> {
    if (!this.client) return
    await this.client.request('turn/interrupt', {
      ['threadId']: threadID,
      ['turnId']: turnID
    })
  }

  private async interrupt(): Promise<void> {
    if (!this.runtimeThreadID || !this.codexTurnID) return
    await this.interruptCodexTurn(this.runtimeThreadID, this.codexTurnID)
  }

  private async startNewThread(): Promise<void> {
    if (!this.client || !this.runtimeLease) throw new Error('codex app-server is not available')
    const started = jsonObject(
      await this.client.request('thread/start', {
        cwd: this.prepared.project.root,
        runtimeWorkspaceRoots: [this.prepared.project.root],
        experimentalRawEvents: true,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        modelProvider: 'ankole_aigateway',
        config: this.prepared.threadConfig,
        threadSource: 'ankole',
        dynamicTools: this.prepared.projection.dynamicTools,
        model: this.modelProfile.model
      })
    )
    this.runtimeThreadID = stringValue(jsonObject(started.thread).id)
    if (!this.runtimeThreadID) throw new Error('codex app-server did not return a thread id')
    await this.runtimeLease.runtime.registerRoot(this.runtimeThreadID, this)
    this.opts.onTurnActivity?.('codex:thread_started')
  }

  private async startCodexTurn(input: string): Promise<void> {
    if (!this.client || !this.runtimeThreadID) throw new Error('codex thread is not available')
    const clientUserMessageID = turnClientUserMessageID(this.turnStart)
    const progressVersion = this.leadRuntimeProgressVersion
    this.clearFirstProgressDeadline()
    const startedTurn = jsonObject(
      await this.client.request('turn/start', {
        ['threadId']: this.runtimeThreadID,
        ...(clientUserMessageID ? { ['clientUserMessageId']: clientUserMessageID } : {}),
        input: textInput(input),
        cwd: this.prepared.project.root,
        runtimeWorkspaceRoots: [this.prepared.project.root],
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' },
        model: this.modelProfile.model,
        ...(this.modelProfile.modelReasoningEffort ? { effort: this.modelProfile.modelReasoningEffort } : {})
      })
    )
    this.codexTurnID = stringValue(jsonObject(startedTurn.turn).id)
    if (!this.codexTurnID) throw new Error('codex app-server did not return a turn id')
    this.turnRecorder.recordTurnStarted(
      { threadId: this.runtimeThreadID, turn: jsonObject(startedTurn.turn) },
      'agent',
      input,
      clientUserMessageID
    )
    if (this.leadRuntimeProgressVersion === progressVersion) this.armFirstProgressDeadline()
    this.opts.onTurnActivity?.('codex:turn_started')
  }

  private armFirstProgressDeadline(): void {
    const timeoutMs = this.opts.firstCodexProgressTimeoutMs ?? defaultFirstCodexProgressTimeoutMs
    this.firstProgressTimer = setTimeout(() => {
      this.firstProgressTimer = undefined
      if (this.finalizing || this.closing) return
      const error = new CodexTurnNoProgressError(timeoutMs)
      this.opts.logger?.warning(
        'worker.codex_turn_first_progress_timed_out',
        'Codex turn produced no runtime progress after turn/start',
        {
          job_id: this.jobID,
          runtime_thread_id: this.runtimeThreadID,
          runtime_turn_id: this.codexTurnID,
          timeout_ms: timeoutMs
        }
      )
      this.rejectDone(error)
    }, timeoutMs)
    this.firstProgressTimer.unref?.()
  }

  private noteLeadRuntimeProgress(): void {
    this.leadRuntimeProgressVersion += 1
    this.clearFirstProgressDeadline()
  }

  private clearFirstProgressDeadline(): void {
    if (!this.firstProgressTimer) return
    clearTimeout(this.firstProgressTimer)
    this.firstProgressTimer = undefined
  }

  /**
   * Codex accepts the next input only after the compaction Turn has finished:
   * its `contextCompaction` item completes while the Compact task is still
   * active, and a `turn/start` sent in that gap is rejected as not steerable.
   * The handshake therefore ends on the compaction Turn's `turn/completed`.
   */
  private async compactThread(): Promise<void> {
    const client = this.client
    const threadID = this.runtimeThreadID
    if (!client || !threadID) throw new Error('codex thread is not available for compaction')
    const compacted = new Promise<void>((resolve, reject) => {
      this.compaction = { threadID, resolve, reject }
    })
    try {
      await client.request('thread/compact/start', { ['threadId']: threadID })
      await compacted
    } finally {
      this.compaction = undefined
    }
  }

  private async persistRuntimeThreadAnchor(reason: string): Promise<void> {
    if (!this.runtimeThreadID) throw new Error('codex thread is not available for persistence')
    await this.opts.rpc(
      rpcMethods.backgroundAgentJobStatusUpdate,
      {
        jobId: this.jobID,
        status: 'running',
        runtimeThreadId: this.runtimeThreadID,
        metadataJson: jsonBytes({ runtime_thread_recreated_reason: reason })
      },
      { turn: this.turnStart.turn }
    )
  }

  private async handleTurnCompleted(
    status: BackgroundAgentJobStatus,
    codexTurnStatus: string,
    error: JSONObject
  ): Promise<void> {
    if (this.finalizing || this.waitingOnUserInput || this.recoveryInFlight || this.completionPending) return

    if (status === 'succeeded' && this.runtimeLease) {
      // The lead Turn can finish before child threads. Commit success only
      // after all threads owned by this Job session are idle.
      this.completionPending = true
      try {
        await this.runtimeLease.runtime.waitForSessionTurnsIdle(this)
      } finally {
        this.completionPending = false
      }
      if (this.finalizing || this.waitingOnUserInput || this.recoveryInFlight) return
    }

    if (status === 'succeeded') {
      if (!stringValue(this.outputText)) {
        if (this.emptyReportRetries < 1) {
          this.emptyReportRetries += 1
          await this.startCodexTurn(
            'The Job produced no final report. Inspect the completed work and reply with a concise final report that states the outcome and verifies the acceptance criteria.'
          )
          return
        }
        await this.commit('failed', {
          error: {
            code: 'codex_empty_report',
            summary: 'Codex completed without a final response after one report retry.'
          }
        })
        return
      }

      const filesChanged = this.completedFilesChanged
      const artifactPaths = ownerVisibleArtifactPaths(this.prepared.project.root, filesChanged.paths)
      await this.commit('succeeded', {
        result: {
          output_text: this.outputText,
          stop_reason: 'completed',
          attempt: this.job.attempts,
          ...(this.runtimeThreadID ? { runtime_thread_id: this.runtimeThreadID } : {}),
          codex_turn_status: codexTurnStatus,
          ...(this.latestTokenUsage ? { usage: this.latestTokenUsage } : {}),
          files_changed: filesChanged,
          project_path: this.prepared.project.root,
          artifacts: boundedBackgroundAgentJobPaths(artifactPaths, {
            totalCount: filesChanged.total_count,
            truncated: filesChanged.truncated || artifactPaths.length < filesChanged.paths.length
          }),
          artifact_roots: artifactDiscoveryRoots(this.prepared.project.root)
        }
      })
      return
    }

    if (status === 'stopped') {
      await this.commit('stopped', {
        metadata: {
          stop_reason: stringValue(error.message) ?? 'codex_turn_interrupted'
        }
      })
      return
    }

    this.recoveryInFlight = true
    try {
      const poolExhaustion = codexCredentialPoolExhaustion(error) ?? this.pendingCredentialPoolExhaustion
      if (poolExhaustion) throw new CodexCredentialPoolExhaustedError(poolExhaustion, error)

      const failure = classifyCodexRecoveryFailure(error)
      const decision = transitionCodexRecovery({
        stage: 'turn',
        failure,
        state: this.recoveryState,
        canCompact: Boolean(this.client && this.runtimeThreadID)
      })
      this.recoveryState = decision.nextState

      if (decision.action === 'retry_turn') {
        await Bun.sleep(decision.delayMs ?? 0)
        this.outputText = ''
        await this.startCodexTurn(retryContinuationInput())
        return
      }
      if (decision.action === 'compact_then_retry') {
        await this.compactThread()
        this.outputText = ''
        await this.startCodexTurn(retryContinuationInput())
        return
      }
      if (decision.action === 'replace_thread') {
        await this.turnRecorder.flush()
        const outcome = await this.replaceLostThread()
        await this.persistRuntimeThreadAnchor(
          outcome === 'replayed' ? 'replayed_from_transcript' : 'new_thread_from_bounded_history'
        )
        this.outputText = ''
        if (outcome === 'replayed') {
          await this.startCodexTurn(retryContinuationInput())
        } else {
          await this.startCodexTurn(
            recreatedThreadInput(this.job, retryContinuationInput(), await this.continuationSourceContext())
          )
        }
        return
      }
      if (decision.action === 'durable_retry') throw durableRetryError(error)

      await this.commit('failed', {
        error: {
          code: stringValue(error.codexErrorInfo) ?? 'codex_turn_failed',
          summary: stringValue(error.message) ?? (this.outputText || `Codex turn ${codexTurnStatus}`),
          codex_turn_status: codexTurnStatus,
          codex_error: error
        }
      })
    } catch (recoveryError) {
      this.rejectDone(toError(recoveryError))
    } finally {
      this.recoveryInFlight = false
    }
  }

  handleRuntimeNotification(message: JSONRPCMessage): void {
    if (this.finalizing) return
    // Injected replay items echo back as ordinary runtime notifications. They
    // restate history the control plane already stores, so recording them
    // would duplicate the turn content stream.
    if (this.suppressRuntimeCapture) return
    const projection = projectCodexNotification(message)
    if (projection.type === 'turn_started') {
      this.turnRecorder.recordTurnStarted(jsonObject(message.params), this.declareTurnKind(projection))
    } else {
      this.turnRecorder.handleNotification(message)
    }
    if (projection.type === 'ignored') return
    const isLeadNotification = !projection.threadID || projection.threadID === this.runtimeThreadID
    this.opts.onTurnActivity?.(`codex:${isLeadNotification ? '' : 'child:'}${projection.type}`)
    if (isLeadNotification) this.noteLeadRuntimeProgress()

    // Child-thread items also carry Skill-usage evidence.
    if (projection.type === 'item_started') {
      this.recordUsedSkills(this.skillUsage.observeItem(projection.item), projection.turnID)
      return
    }

    if (projection.type === 'mcp_server_startup_failed') {
      if (!this.runtimeThreadID || isLeadNotification) {
        this.opts.logger?.warning('worker.codex_mcp_server_unavailable', 'Codex MCP server is unavailable', {
          server: projection.server,
          status: 'failed',
          ...(projection.failureReason ? { failure_reason: projection.failureReason } : {}),
          error: projection.error
        })
      }
      return
    }

    if (!isLeadNotification) return

    if (projection.type === 'credential_pool_exhausted') {
      this.pendingCredentialPoolExhaustion = projection.exhaustion
    } else if (projection.type === 'turn_started') {
      this.pendingCredentialPoolExhaustion = undefined
      this.rollActiveFilesChanged()
      this.codexTurnID = projection.turnID ?? this.codexTurnID
    } else if (projection.type === 'agent_completed') {
      this.outputText = projection.text
    } else if (projection.type === 'token_usage') {
      this.latestTokenUsage = projection.usage
    } else if (projection.type === 'turn_diff') {
      this.activeFilesChanged = projection.filesChanged
    } else if (projection.type === 'turn_completed' && !this.finalizing && !this.waitingOnUserInput) {
      if (this.settleCompaction(projection)) return
      this.rollActiveFilesChanged()
      // This runs outside any awaiting caller: a notification handler cannot
      // await it. Its own failure paths (waiting for child threads, retrying an
      // empty report) end the Job through `rejectDone`, so the rejection reaches
      // the Job instead of the process.
      this.handleTurnCompleted(projection.terminalStatus, projection.codexTurnStatus, projection.error).catch(error => {
        this.rejectDone(toError(error))
      })
    }
  }

  /**
   * Only the Turn that answers this session's `thread/compact/start` is a
   * compaction Turn. Codex returns no turn id from that request and reports
   * the Turn through `turn/started` before its contextCompaction item
   * completes, so the first Turn started on the compacting thread is that
   * Turn. Every other Turn is an agent Turn, including one that Codex compacts
   * automatically part-way through.
   */
  private declareTurnKind(projection: { threadID?: string; turnID?: string }): BackgroundAgentJobTurnKind {
    const compaction = this.compaction
    if (!compaction || projection.threadID !== compaction.threadID || compaction.turnID !== undefined) {
      return 'agent'
    }
    compaction.turnID = projection.turnID
    return 'compaction'
  }

  /**
   * Ends the compaction handshake when its own Turn completes. A Turn that
   * completes on the compacting thread before Codex reported the compaction
   * Turn can only be that Turn. Every other completion belongs to the Job.
   */
  private settleCompaction(projection: { turnID?: string; codexTurnStatus: string; error: JSONObject }): boolean {
    const compaction = this.compaction
    if (!compaction || (compaction.turnID !== undefined && projection.turnID !== compaction.turnID)) return false
    if (projection.codexTurnStatus === 'completed') {
      compaction.resolve()
    } else {
      compaction.reject(
        new Error(stringValue(projection.error.message) ?? `Codex compaction turn ${projection.codexTurnStatus}`)
      )
    }
    return true
  }

  /** Folds the running Turn's diff into the Job-wide total and starts a fresh one. */
  private rollActiveFilesChanged(): void {
    this.completedFilesChanged = mergeBackgroundAgentJobPathHandoffs(
      this.completedFilesChanged,
      this.activeFilesChanged
    )
    this.activeFilesChanged = emptyBackgroundAgentJobPathHandoff()
  }

  async handleRuntimeServerRequest(message: JSONRPCMessage, appServer: CodexAppServerClient): Promise<void> {
    if (!this.acceptingServerRequests || this.finalizing) {
      if (message.id !== undefined) {
        await appServer.respondError(message.id, -32001, 'Background agent Job is cleaning up')
      }
      return
    }
    const method = typeof message.method === 'string' ? message.method : ''
    if (message.id === undefined) return
    const params = jsonObject(message.params)
    const requestThreadID = stringValue(params.threadId)
    const isLeadRequest = !requestThreadID || requestThreadID === this.runtimeThreadID
    if (isLeadRequest) this.noteLeadRuntimeProgress()
    this.opts.onTurnActivity?.(`codex:${method || 'server_request'}`)

    const dynamicToolParams = method === 'item/tool/call' ? (message.params as DynamicToolCallParams) : undefined
    const bridgedUserInput = dynamicToolParams ? pendingParentInputFromDynamicTool(dynamicToolParams) : undefined
    if (method === 'item/tool/requestUserInput' || dynamicToolParams?.tool === PARENT_INPUT_TOOL_NAME) {
      if (!isLeadRequest) {
        await appServer.respondError(
          message.id,
          -32601,
          'Child agents cannot request user input directly; return the question to the lead agent.'
        )
        return
      }
      if (dynamicToolParams && !bridgedUserInput) {
        await appServer.respondError(message.id, -32602, `Invalid arguments for ${PARENT_INPUT_TOOL_NAME}`)
        return
      }
      const pending = bridgedUserInput ?? params
      const requestTurnID = stringValue(pending.turnId) ?? this.codexTurnID
      this.turnRecorder.recordRequestUserInput(requestTurnID, pending, message.id)
      this.waitingOnUserInput = true
      if (!this.claimFinalization()) {
        await appServer.respondError(message.id, -32001, 'Background agent Job is already finalizing')
        return
      }
      try {
        if (requestThreadID && requestTurnID) {
          await this.interruptCodexTurn(requestThreadID, requestTurnID).catch(() => undefined)
          this.turnRecorder.interruptTurn(requestTurnID, {
            code: 'request_user_input',
            summary: 'Codex requested user input.'
          })
        } else {
          await this.interrupt()
        }
        await appServer.respondError(message.id, -32002, 'Background agent Job is waiting for parent input')
        this.scheduleClaimedCommit('waiting_on_user', { metadata: { pending_user_input: pending } })
      } catch (error) {
        this.waitingOnUserInput = false
        this.rejectDone(toError(error))
      }
      return
    }

    if (method === 'item/tool/call') {
      try {
        const response = await this.prepared.projection.handleToolCall(
          message.params as DynamicToolCallParams,
          this.toolAbortController.signal
        )
        for (const name of this.prepared.skills.takeLoadedNames()) {
          this.recordUsedSkills(this.skillUsage.recordLoaded(name))
        }
        await appServer.respond(message.id, response)
      } catch (error) {
        await appServer.respondError(
          message.id,
          this.toolAbortController.signal.aborted ? -32001 : -32603,
          this.toolAbortController.signal.aborted
            ? 'Background agent Job cancelled the tool call during cleanup'
            : errorMessage(error)
        )
      }
      return
    }
    if (approvalRequestMethod(method)) {
      await appServer.respond(message.id, approvalAcceptance(method, params))
      return
    }

    await appServer.respondError(message.id, -32601, `Ankole does not implement Codex server request ${method}`)
    if (!isLeadRequest) return
    await this.interrupt().catch(() => undefined)
    if (this.claimFinalization()) {
      this.scheduleClaimedCommit('failed', {
        error: {
          code: 'unsupported_server_request',
          summary: `Unsupported Codex server request: ${method}`
        }
      })
    }
  }

  private readonly onAbort = (): void => {
    if (!this.claimFinalization()) return
    void this.interrupt().catch(() => undefined)
    void this.commitClaimed('stopped', {
      metadata: { stop_reason: abortReason(this.opts.abortSignal) }
    })
  }

  private scheduleClaimedCommit(
    status: BackgroundAgentJobStatus,
    details: { result?: JSONObject; error?: JSONObject; metadata?: JSONObject }
  ): void {
    // Defer this commit until the server-request handler returns. Runtime
    // cleanup waits for all handlers and would otherwise wait for itself.
    setTimeout(() => void this.commitClaimed(status, details), 0)
  }

  private async finishClaimedFinalization(): Promise<boolean> {
    if (!this.finalizing) return false
    await this.done
    return true
  }

  prepareForRuntimeCleanup(): void {
    this.acceptingServerRequests = false
    if (!this.toolAbortController.signal.aborted) {
      this.toolAbortController.abort(new DOMException('Background agent Job is cleaning up', 'AbortError'))
    }
  }

  handleRuntimeLost(error: AgentCodexRuntimeLostError): void {
    if (this.closing) return
    this.prepareForRuntimeCleanup()
    this.rejectDone(error)
  }

  /**
   * Sends queued runtime updates only while the current Codex Turn can accept them.
   *
   * The queues keep updates through setup, recovery, and another update in
   * flight. A later poll retries them after the blocking state ends.
   */
  private startActiveTurnUpdatePoll(): void {
    this.activeTurnUpdateTimer = setInterval(() => {
      // Apply Skill disables before the Codex readiness checks. A running Job
      // must stop exposing a disabled Skill while another update is in flight.
      const disabledSkills = this.opts.pollDisabledSkills?.() ?? []
      this.prepared.skills.loader.disable(disabledSkills)
      this.skillUsage.disable(disabledSkills)
      if (
        this.activeTurnUpdateInFlight ||
        this.finalizing ||
        this.completionPending ||
        this.recoveryInFlight ||
        !this.client ||
        !this.runtimeThreadID ||
        !this.codexTurnID
      ) {
        return
      }
      const updates = this.opts.pollSteering?.() ?? []
      const disabledNotices = this.skillUsage.pendingDisabledNotices()
      if (updates.length === 0 && disabledNotices.length === 0) return
      this.activeTurnUpdateInFlight = true
      void steerDisabledSkills(
        this.client!,
        this.runtimeThreadID!,
        this.codexTurnID!,
        disabledNotices,
        () => !this.finalizing,
        async (name, eventID, text) => {
          this.skillUsage.markNotified(name)
          this.turnRecorder.recordSteering(this.codexTurnID, eventID, text)
          await this.turnRecorder.flush()
        }
      )
        .then(() =>
          steerActiveTurn(
            this.client!,
            this.runtimeThreadID!,
            this.codexTurnID!,
            updates,
            () => !this.finalizing,
            async (eventID, text) => {
              this.turnRecorder.recordSteering(this.codexTurnID, eventID, text)
              await this.turnRecorder.flush()
            },
            async update => {
              this.turnStart.turn.revision = Math.max(this.turnStart.turn.revision, update.turn.revision)
              await this.opts.onSteeringApplied?.(update)
            }
          )
        )
        .catch(error => {
          if (this.finalizing) return
          this.finalizing = true
          this.rejectDone(toError(error))
        })
        .finally(() => {
          this.activeTurnUpdateInFlight = false
        })
    }, activeTurnUpdatePollIntervalMs)
    this.activeTurnUpdateTimer.unref?.()
  }

  private recordUsedSkills(skillNames: string[], turnID = this.codexTurnID): void {
    for (const name of skillNames) this.turnRecorder.recordSkillUsed(turnID, name)
  }
}

/** One `thread/compact/start` in flight; `turnID` arrives with the Turn's `turn/started`. */
type CompactionHandshake = {
  threadID: string
  turnID?: string
  resolve(): void
  reject(error: Error): void
}

function turnInput(turnStart: TurnStart, job: BackgroundAgentJobResponse): string {
  if (turnStart.actor_event.type === 'command.steer') {
    const command = jsonObject(jsonObject(jsonObject(turnStart.actor_event.payload_json).data).command)
    const message = stringValue(command.argsText)
    if (!message) throw new Error('BackgroundAgentJob message command is missing argsText')
    return message
  }

  if (job.attempts > 1 && job.runtimeThreadId) {
    return 'Continue the Job task. Re-check the acceptance criteria in the original task before finishing.'
  }

  return job.task
}

function ownerVisibleArtifactPaths(projectRoot: string, filesChanged: string[]): string[] {
  const artifacts = new Set<string>()
  for (const path of filesChanged) {
    const artifact = ownerVisibleArtifactPath(projectRoot, path)
    if (artifact) artifacts.add(artifact)
  }
  return [...artifacts].sort(compareCodePointStrings)
}

function artifactDiscoveryRoots(projectRoot: string): BackgroundAgentJobPathHandoff {
  return boundedBackgroundAgentJobPaths([projectRoot])
}

function ownerVisibleArtifactPath(projectRoot: string, changedPath: string): string | undefined {
  const hostPath = changedPath.startsWith('/') ? resolve(changedPath) : resolve(projectRoot, changedPath)
  if (!existsSync(hostPath)) return undefined

  try {
    const realRoot = realpathSync(projectRoot)
    const realPath = realpathSync(hostPath)
    if (!pathIsWithin(realRoot, realPath) || !statSync(realPath).isFile()) return undefined
    return realPath
  } catch {
    return undefined
  }
}

function turnClientUserMessageID(turnStart: TurnStart): string | undefined {
  if (turnStart.actor_event.type === 'command.steer') return turnStart.actor_event.actor_event_id
  return undefined
}

function retryContinuationInput(): string {
  return 'Continue the Job task after the transient runtime error. Inspect the current workspace before repeating any side effect, then re-check the original acceptance criteria.'
}

type ContinuationSourceContext = {
  task?: string | undefined
  finalReport?: string | undefined
}

function recreatedThreadInput(
  job: BackgroundAgentJobResponse,
  continuation: string,
  source?: ContinuationSourceContext
): string {
  const priorAttempts = job.attemptHistory?.length
    ? `\n\nBounded history from prior execution attempts:\n${JSON.stringify(job.attemptHistory, null, 2)}`
    : ''
  const sourceContext = source?.task
    ? `\n\nThis Job continues terminal Job ${job.continuedFromJobId}. Its original task:\n${source.task}\n\nIts final report:\n${source.finalReport ?? '(the source Job recorded no final report)'}`
    : ''
  return `${job.task}\n\nThe previous Codex thread could not be resumed. Inspect the existing working directory and continue from durable artifacts.${sourceContext}${priorAttempts}\n\nCurrent continuation instructions:\n${continuation}\n\nRe-check every acceptance criterion before finishing.`.trim()
}

async function steerActiveTurn(
  client: CodexAppServerClient,
  threadID: string,
  turnID: string,
  updates: TurnSteerUpdate[],
  acceptsOutcome: () => boolean,
  onTrajectorySteering: (eventID: string, text: string) => Promise<void>,
  onSteeringApplied?: (update: TurnSteerUpdate) => Promise<void>
): Promise<void> {
  for (const update of updates) {
    const event = update.actorEvent
    if (!event) continue
    const command = jsonObject(jsonObject(jsonObject(event.payload_json).data).command)
    const text = stringValue(command.argsText)
    if (!text) continue
    try {
      await client.request('turn/steer', {
        ['threadId']: threadID,
        ['expectedTurnId']: turnID,
        ['clientUserMessageId']: event.actor_event_id,
        input: textInput(text)
      })
      if (!acceptsOutcome()) continue
      await onTrajectorySteering(event.actor_event_id, text)
      await onSteeringApplied?.(update)
    } catch (error) {
      if (!acceptsOutcome()) continue
      if (!isSteerCompletionRace(error)) throw new BackgroundAgentJobMessageDeliveryError(error)
    }
  }
}

async function steerDisabledSkills(
  client: CodexAppServerClient,
  threadID: string,
  turnID: string,
  skillNames: string[],
  acceptsOutcome: () => boolean,
  onApplied: (name: string, eventID: string, text: string) => Promise<void>
): Promise<void> {
  for (const name of skillNames) {
    const eventID = `skill-disabled:${name}`
    const text = skillDisabledNotice(name)
    try {
      await client.request('turn/steer', {
        ['threadId']: threadID,
        ['expectedTurnId']: turnID,
        ['clientUserMessageId']: eventID,
        input: textInput(text)
      })
      if (acceptsOutcome()) await onApplied(name, eventID, text)
    } catch (error) {
      if (!acceptsOutcome()) continue
      if (!isSteerCompletionRace(error)) throw new BackgroundAgentJobMessageDeliveryError(error)
    }
  }
}

function isSteerCompletionRace(error: unknown): boolean {
  return /^(?:no active turn to steer|(?:turn\s+)?already (?:completed|finished)|turn .* (?:has )?(?:completed|finished))$/i.test(
    errorMessage(error).trim()
  )
}

class CodexJobTransientError extends Error {
  readonly code = 'codex_job_transient'
  readonly retryable = true

  constructor(cause: unknown) {
    super(
      `Codex transient runtime failure requires durable retry: ${stringValue(jsonObject(cause).message) ?? errorMessage(cause)}`,
      { cause: cause instanceof Error ? cause : undefined }
    )
    this.name = 'CodexJobTransientError'
  }
}

/**
 * An app-server internal failure is infrastructure, not the task failing: the
 * process (or its agent loop) died and a replacement serves the next attempt.
 * The runtime-exception code keeps the control plane's retry accounting on the
 * uncharged infrastructure ladder.
 */
class CodexRuntimeInternalError extends Error {
  readonly code = 'background_agent_job_runtime_exception'
  readonly retryable = true

  constructor(cause: unknown) {
    super(
      `Codex app-server internal failure requires durable retry: ${stringValue(jsonObject(cause).message) ?? errorMessage(cause)}`,
      { cause: cause instanceof Error ? cause : undefined }
    )
    this.name = 'CodexRuntimeInternalError'
  }
}

function durableRetryError(cause: JSONObject): Error {
  const message = `${stringValue(cause.message) ?? ''}`.toLowerCase()
  if (cause.code === -32603 || message.includes('agent loop died')) return new CodexRuntimeInternalError(cause)
  return new CodexJobTransientError(cause)
}

class CodexTurnNoProgressError extends Error {
  readonly code = 'codex_turn_no_progress'
  readonly retryable = true

  constructor(timeoutMs: number) {
    super(`Codex turn produced no runtime progress within ${timeoutMs}ms after turn/start`)
    this.name = 'CodexTurnNoProgressError'
  }
}

class CodexCredentialPoolExhaustedError extends Error {
  readonly code = 'credential_pool_exhausted'
  readonly retryable = true
  readonly status = 429
  readonly retryAt: string | undefined
  readonly details: JSONObject

  constructor(exhaustion: CodexCredentialPoolExhaustion, cause: JSONObject) {
    const retrySuffix = exhaustion.retryAt ? ` retry_at=${exhaustion.retryAt}` : ''
    super(`AIGateway credential pool exhausted.${retrySuffix}`, {
      cause: new Error(stringValue(cause.message) ?? 'Codex reported an exhausted credential pool')
    })
    this.name = 'CodexCredentialPoolExhaustedError'
    this.retryAt = exhaustion.retryAt
    this.details = exhaustion.retryAt ? { retry_at: exhaustion.retryAt } : {}
  }
}

class BackgroundAgentJobMessageDeliveryError extends Error {
  readonly code = 'background_agent_job_steer_delivery_failed'
  readonly retryable = true

  constructor(cause: unknown) {
    super(`BackgroundAgentJob steer delivery failed: ${errorMessage(cause)}`, {
      cause: cause instanceof Error ? cause : undefined
    })
    this.name = 'BackgroundAgentJobMessageDeliveryError'
  }
}

function abortReason(signal?: AbortSignal): string {
  if (!signal?.aborted) return 'stopped'
  return signal.reason instanceof Error ? signal.reason.message : String(signal.reason ?? 'stopped')
}
