import { jsonObject, type JsonObject as JSONObject } from '@agentbull/active-support'
import { toError } from '../../../common/errors'
import { compareCodePointStrings } from '../../../common/ordering'
import { jsonBytes, jsonObjectFromBytes } from '../../../fabric/envelope-proto'
import type { BackgroundAgentJobResponse } from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { TurnStart, TurnSteerUpdate } from '../../../lanes/session-lane'
import { workerTurnTrace } from '../../../observability/turn-tracing'
import type {
  BackgroundAgentJobStatus,
  BackgroundAgentJobTurnKind,
  BackgroundAgentJobTurnUsage
} from '../../background-agent-job-documents'
import {
  emptyBackgroundAgentJobPathHandoff,
  mergeBackgroundAgentJobPathHandoffs,
  type BackgroundAgentJobPathHandoff
} from '../../background-agent-job-handoff'
import type { CodexJobOptions } from '../options'
import { projectCodexNotification, stringValue } from '../protocol'
import { codexJobModelProfile, type CodexAIGatewayModelProfile } from '../runtime-config'
import {
  agentCodexRuntimeManager,
  AgentCodexRuntimeLostError,
  type AgentCodexRuntimeLease,
  type AgentCodexRuntimeSession
} from '../runtime/agent-runtime-manager'
import { CodexAppServerClient, type JSONRPCMessage } from '../runtime/app-server-client'
import {
  initialCodexRecoveryState,
  type CodexCredentialPoolExhaustion,
  type CodexRecoveryState
} from './recovery-policy'
import type { ThreadRecreateReason } from './execution-logfile'
import {
  commitJobStatusWithAck,
  dispatchRuntimeServerRequest,
  persistRuntimeThreadAnchor,
  prepareReplacementCodexRootThread,
  publishRunningJobStatus,
  resumeExistingCodexRootThread,
  startCodexTurnOnThread,
  startNewCodexRootThread,
  type ResumeCodexThreadResult
} from './session-runtime-ops'
import {
  abortReason,
  recreatedThreadInput,
  snapshotJobWorkspace,
  turnClientUserMessageID,
  turnInput,
  updateOriginalHumanRequestInstructions,
  type CompactionHandshake
} from './session-support'
import {
  completeSucceededCodexTurn,
  recoverOrCommitFailedCodexTurn,
  runCodexSessionWithCleanup,
  startFirstProgressDeadlineTimer,
  startSessionActiveTurnUpdatePoll
} from './session-turn-lifecycle'
import type { PreparedCodexJobExecution } from './setup'
import { CodexSkillUsageTracker } from './skill-usage'
import { BackgroundAgentJobTurnRecorder } from './turn-recorder'
import type { WorkspaceSnapshot } from './workspace-snapshot'

/**
 * Lead items that show the model continued to work after a message. A
 * runtime-generated item, such as an automatic compaction, does not make the
 * previous message provisional.
 */
const workItemTypes = new Set([
  'commandExecution',
  'fileChange',
  'mcpToolCall',
  'dynamicToolCall',
  'collabAgentToolCall',
  'subAgentActivity',
  'webSearch'
])

export async function runCodexJobSession(
  turnStart: TurnStart,
  opts: CodexJobOptions,
  jobID: string,
  job: BackgroundAgentJobResponse,
  prepared: PreparedCodexJobExecution
): Promise<void> {
  return new CodexJobSession(turnStart, opts, jobID, job, prepared).run()
}

/**
 * Owns one durable Job attempt and its Codex thread set.
 * A terminal Worker result follows the Turn-record flush and durable Job-status
 * commit.
 */
class CodexJobSession implements AgentCodexRuntimeSession {
  private readonly appliedEventIDs = new Set<string>()
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
  private originalHumanRequest: string | undefined
  private latestTokenUsage: BackgroundAgentJobTurnUsage | undefined
  private completedFilesChanged: BackgroundAgentJobPathHandoff = emptyBackgroundAgentJobPathHandoff()
  private activeFilesChanged: BackgroundAgentJobPathHandoff = emptyBackgroundAgentJobPathHandoff()
  /** Workspace files before the attempt's first Turn; the result diffs the final state against it. */
  private workspaceSnapshot: WorkspaceSnapshot | undefined
  private waitingOnUserInput = false
  private recoveryInFlight = false
  private completionPending = false
  private turnCompletionTail: Promise<void> = Promise.resolve()
  private readonly completedTurns = new Set<string>()
  private recoveryState: CodexRecoveryState = initialCodexRecoveryState
  private pendingCredentialPoolExhaustion: CodexCredentialPoolExhaustion | undefined
  private emptyReportRetries = 0
  private recreatedThreadOnResume = false
  private recreatedThreadReason: ThreadRecreateReason | undefined
  private finalizing = false
  private closing = false
  private acceptingServerRequests = true
  private durableJobStatusCommitted = false
  private readonly toolAbortController = new AbortController()
  private activeTurnUpdateTimer: ReturnType<typeof setInterval> | undefined
  private firstProgressTimer: ReturnType<typeof setTimeout> | undefined
  private leadRuntimeProgressVersion = 0
  private activeTurnUpdateInFlight = false
  private compaction: CompactionHandshake | undefined
  private compactionSeq = 0
  private readonly initialJobMetadata: JSONObject | undefined

  constructor(
    private readonly turnStart: TurnStart,
    private readonly opts: CodexJobOptions,
    private readonly jobID: string,
    private readonly job: BackgroundAgentJobResponse,
    private readonly prepared: PreparedCodexJobExecution
  ) {
    this.appliedEventIDs.add(turnStart.signal.signal_id)
    this.runtimeThreadID = job.runtimeThreadId || undefined
    this.originalHumanRequest = stringValue(turnStart.request_context?.original_human_request)
    this.initialJobMetadata = jsonObjectFromBytes(job.metadataJson, 'Job metadata') ?? undefined
    const savedCompactionSeq = Number(this.initialJobMetadata?.cli_compaction_seq ?? 0)
    this.compactionSeq = Number.isSafeInteger(savedCompactionSeq) && savedCompactionSeq >= 0 ? savedCompactionSeq : 0
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
      turnTrace: workerTurnTrace(turnStart, job.agentUid),
      driveView: prepared.driveView,
      upsert: request => opts.rpc('background_agent_job.turn.upsert', request, { jobTurn: turnStart.turn })
    })
    this.done = new Promise<void>((resolve, reject) => {
      this.resolveDone = resolve
      this.rejectDone = reject
    })
  }

  async run(): Promise<void> {
    await runCodexSessionWithCleanup({
      execute: () => this.execute(),
      done: this.done,
      agentUID: this.job.agentUid,
      jobID: this.jobID,
      opts: this.opts,
      prepared: this.prepared,
      turnRecorder: this.turnRecorder,
      session: this,
      isFinalizing: () => this.finalizing,
      markFinalizing: () => {
        this.finalizing = true
      },
      codexTurnID: () => this.codexTurnID,
      stopTimersAndListeners: () => {
        if (this.activeTurnUpdateTimer) clearInterval(this.activeTurnUpdateTimer)
        this.clearFirstProgressDeadline()
        this.opts.abortSignal?.removeEventListener('abort', this.onAbort)
        this.closing = true
      },
      runtimeLease: () => this.runtimeLease,
      durableJobStatusCommitted: () => this.durableJobStatusCommitted
    })
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

    await this.runtimeLease.runtime.ensureAgentPlugins(this.prepared.preparedAgentPlugins)
    if (await this.finishClaimedFinalization()) return

    const resumeResult = await this.resumeExistingThread()
    this.recreatedThreadOnResume = resumeResult.outcome === 'recreated'
    if (await this.finishClaimedFinalization()) return
    if (!this.runtimeThreadID) await this.startNewThread()
    if (await this.finishClaimedFinalization()) return
    abortSignal?.throwIfAborted()

    const initialTurnInput = turnInput(this.turnStart, this.job)
    const effectiveTurnInput =
      resumeResult.outcome === 'recreated'
        ? recreatedThreadInput(this.job, initialTurnInput, resumeResult.source, resumeResult.logfile)
        : initialTurnInput

    this.workspaceSnapshot = await snapshotJobWorkspace(this.prepared.project.root, this.jobID, this.opts.logger)
    if (await this.finishClaimedFinalization()) return
    await this.publishRunningStatus(initializeResponse)
    if (await this.finishClaimedFinalization()) return
    try {
      await this.startCodexTurn(effectiveTurnInput)
    } catch (error) {
      if (this.recreatedThreadOnResume && this.runtimeThreadID && this.runtimeLease) {
        await this.runtimeLease.runtime.retireRoot(this.runtimeThreadID, this).catch(() => undefined)
      }
      throw error
    }
    if (await this.finishClaimedFinalization()) return
    this.startActiveTurnUpdatePoll()
    await this.done
  }

  private async resumeExistingThread(): Promise<ResumeCodexThreadResult> {
    return resumeExistingCodexRootThread({
      runtimeLease: this.runtimeLease,
      client: this.client,
      session: this,
      runtimeThreadID: this.runtimeThreadID,
      jobID: this.jobID,
      job: this.job,
      jobTurn: this.turnStart.turn,
      initialJobMetadata: this.initialJobMetadata,
      prepared: this.prepared,
      model: this.modelProfile.model,
      recoveryState: this.recoveryState,
      opts: this.opts,
      setRecoveryState: state => {
        this.recoveryState = state
      },
      publishCliContextId: () => this.publishCliContextId(),
      replaceLostThread: (reason, retireThreadID) => this.replaceThreadAndPrepareHistory(reason, retireThreadID)
    })
  }

  private async replaceThreadAndPrepareHistory(
    reason: ThreadRecreateReason,
    retireThreadID?: string
  ): Promise<Extract<ResumeCodexThreadResult, { outcome: 'recreated' }>> {
    return prepareReplacementCodexRootThread({
      runtimeLease: this.runtimeLease,
      session: this,
      jobTurn: this.turnStart.turn,
      jobID: this.jobID,
      continuedFromJobID: this.job.continuedFromJobId,
      projectRoot: this.prepared.project.root,
      reason,
      retireThreadID,
      opts: this.opts,
      startNewThread: async () => {
        this.recreatedThreadReason = reason
        this.runtimeThreadID = undefined
        await this.startNewThread()
      }
    })
  }

  private async replaceThreadAndStartTurn(reason: ThreadRecreateReason, continuationPrompt: string): Promise<void> {
    await this.turnRecorder.flush()
    const previousThreadID = this.runtimeThreadID
    const { source, logfile } = await this.replaceThreadAndPrepareHistory(reason, previousThreadID)
    if (!this.runtimeThreadID) throw new Error('codex thread is not available for persistence')
    const newThreadID = this.runtimeThreadID
    await persistRuntimeThreadAnchor({
      rpc: this.opts.rpc,
      jobTurn: this.turnStart.turn,
      jobID: this.jobID,
      runtimeThreadID: newThreadID,
      reason,
      recovery: 'new_thread_from_logfile'
    })
    try {
      await this.startCodexTurn(recreatedThreadInput(this.job, continuationPrompt, source, logfile))
    } catch (error) {
      if (this.runtimeLease) {
        await this.runtimeLease.runtime.retireRoot(newThreadID, this).catch(() => undefined)
      }
      throw error
    }
  }

  private async publishRunningStatus(initializeResponse: JSONObject): Promise<void> {
    if (!this.runtimeThreadID) throw new Error('codex thread is not available')
    await publishRunningJobStatus({
      rpc: this.opts.rpc,
      jobTurn: this.turnStart.turn,
      jobID: this.jobID,
      runtimeThreadID: this.runtimeThreadID,
      initializeResponse,
      prepared: this.prepared,
      processID: this.client?.processID,
      compactionSeq: this.compactionSeq,
      recreatedThreadOnResume: this.recreatedThreadOnResume,
      recreatedThreadReason: this.recreatedThreadReason,
      expectedSkillCount: this.expectedSkillNames.length
    })
  }

  private async commit(
    status: BackgroundAgentJobStatus,
    details: { result?: JSONObject; error?: JSONObject; metadata?: JSONObject } = {}
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
    details: { result?: JSONObject; error?: JSONObject; metadata?: JSONObject } = {}
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
      await commitJobStatusWithAck(
        this.opts.rpc,
        {
          jobId: this.jobID,
          status,
          appliedSignalIds: [...this.appliedEventIDs],
          ...(this.runtimeThreadID ? { runtimeThreadId: this.runtimeThreadID } : {}),
          ...(details.result ? { resultJson: jsonBytes(details.result) } : {}),
          ...(details.error ? { errorJson: jsonBytes(details.error) } : {}),
          ...(details.metadata ? { metadataJson: jsonBytes(details.metadata) } : {})
        },
        this.turnStart.turn
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
    this.runtimeThreadID = await startNewCodexRootThread({
      runtimeLease: this.runtimeLease,
      client: this.client,
      session: this,
      prepared: this.prepared,
      model: this.modelProfile.model
    })
    this.compactionSeq = 0
    this.publishCliContextId()
  }

  private publishCliContextId(): void {
    if (!this.runtimeThreadID) return
    this.prepared.updateCliContextId(`${this.jobID}:thread:${this.runtimeThreadID}:cmp:${this.compactionSeq}`)
  }

  private async startCodexTurn(input: string): Promise<void> {
    if (!this.client || !this.runtimeThreadID) throw new Error('codex thread is not available')
    await this.turnRecorder.startDriveWindow()
    this.outputText = ''
    const clientUserMessageID = turnClientUserMessageID(this.turnStart)
    const progressVersion = this.leadRuntimeProgressVersion
    this.clearFirstProgressDeadline()
    const turn = await startCodexTurnOnThread({
      client: this.client,
      runtimeThreadID: this.runtimeThreadID,
      projectRoot: this.prepared.project.root,
      modelProfile: this.modelProfile,
      prompt: input,
      clientUserMessageID
    })
    this.codexTurnID = stringValue(turn.id)
    if (!this.codexTurnID) throw new Error('codex app-server did not return a turn id')
    this.turnRecorder.recordTurnStarted({ threadId: this.runtimeThreadID, turn }, 'agent', input, clientUserMessageID)
    if (this.leadRuntimeProgressVersion === progressVersion) this.armFirstProgressDeadline()
  }

  private armFirstProgressDeadline(): void {
    this.firstProgressTimer = startFirstProgressDeadlineTimer({
      opts: this.opts,
      jobID: this.jobID,
      runtimeThreadID: () => this.runtimeThreadID,
      codexTurnID: () => this.codexTurnID,
      isStopped: () => this.finalizing || this.closing,
      onClearTimer: () => {
        this.firstProgressTimer = undefined
      },
      onTimeout: error => this.rejectDone(error)
    })
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

    const driveSummary = await this.turnRecorder
      .flushDriveWindow()
      .catch(flushError => `Drive synchronization is still pending: ${String(flushError)}`)
    if (status === 'succeeded') {
      await completeSucceededCodexTurn({
        driveSummary,
        outputText: this.outputText,
        emptyReportRetries: this.emptyReportRetries,
        root: this.prepared.project.root,
        jobID: this.jobID,
        attempt: this.job.attempts,
        runtimeThreadID: this.runtimeThreadID,
        codexTurnStatus,
        latestTokenUsage: this.latestTokenUsage,
        completedFilesChanged: this.completedFilesChanged,
        workspaceSnapshot: this.workspaceSnapshot,
        logger: this.opts.logger,
        appendOutputText: suffix => {
          this.outputText += suffix
          return this.outputText
        },
        incrementEmptyReportRetries: () => {
          this.emptyReportRetries += 1
        },
        startCodexTurn: prompt => this.startCodexTurn(prompt),
        commit: (nextStatus, details) => this.commit(nextStatus, details)
      })
      return
    }

    if (status === 'stopped') {
      await this.commit('stopped', {
        metadata: {
          stop_reason: stringValue(error.message) ?? 'codex_turn_interrupted',
          ...(driveSummary ? { drive_sync: driveSummary } : {})
        }
      })
      return
    }

    this.recoveryInFlight = true
    if (driveSummary) this.outputText += `\n\n${driveSummary}`
    try {
      await recoverOrCommitFailedCodexTurn({
        error,
        codexTurnStatus,
        outputText: this.outputText,
        pendingCredentialPoolExhaustion: this.pendingCredentialPoolExhaustion,
        recoveryState: this.recoveryState,
        canCompact: Boolean(this.client && this.runtimeThreadID),
        job: this.job,
        setRecoveryState: nextState => {
          this.recoveryState = nextState
        },
        startCodexTurn: prompt => this.startCodexTurn(prompt),
        compactThread: () => this.compactThread(),
        replaceThreadAndStartTurn: (reason, prompt) => this.replaceThreadAndStartTurn(reason, prompt),
        commit: (nextStatus, details) => this.commit(nextStatus, details)
      })
    } catch (recoveryError) {
      this.rejectDone(toError(recoveryError))
    } finally {
      this.recoveryInFlight = false
    }
  }

  handleRuntimeNotification(message: JSONRPCMessage): void {
    if (this.finalizing) return
    const projection = projectCodexNotification(message)
    if (projection.type === 'turn_started') {
      this.turnRecorder.recordTurnStarted(jsonObject(message.params), this.declareTurnKind(projection))
    } else {
      this.turnRecorder.handleNotification(message)
    }
    if (projection.type === 'ignored') return
    const isLeadNotification = !projection.threadID || projection.threadID === this.runtimeThreadID
    if (isLeadNotification) this.noteLeadRuntimeProgress()

    // Child-thread items also carry Skill-usage evidence.
    if (projection.type === 'item_started') {
      if (isLeadNotification && workItemTypes.has(stringValue(projection.item.type) ?? '')) this.outputText = ''
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
      this.outputText = ''
      this.pendingCredentialPoolExhaustion = undefined
      this.rollActiveFilesChanged()
      this.codexTurnID = projection.turnID ?? this.codexTurnID
    } else if (projection.type === 'agent_completed') {
      // Codex permits a missing phase for legacy models. Intermediate messages
      // remain in the trajectory but cannot satisfy the final-report contract.
      if (projection.phase === null || projection.phase === 'final_answer') this.outputText = projection.text
    } else if (projection.type === 'token_usage') {
      this.latestTokenUsage = projection.usage
    } else if (projection.type === 'turn_diff') {
      this.activeFilesChanged = projection.filesChanged
    } else if (projection.type === 'compaction_completed' && !this.compaction) {
      this.compactionSeq += 1
      this.publishCliContextId()
    } else if (projection.type === 'turn_completed' && !this.finalizing && !this.waitingOnUserInput) {
      const threadID = projection.threadID ?? this.runtimeThreadID
      if (threadID && projection.turnID) {
        const key = JSON.stringify([threadID, projection.turnID])
        if (this.completedTurns.has(key)) return
        this.completedTurns.add(key)
      }
      // Recovery waits for this handshake, so it must bypass the completion tail.
      if (this.settleCompaction(projection)) return
      this.rollActiveFilesChanged()
      // A retry can complete in the same stdout chunk as its turn/start reply.
      // Keep that completion until the previous recovery has finished.
      this.turnCompletionTail = this.turnCompletionTail
        .then(() => this.handleTurnCompleted(projection.terminalStatus, projection.codexTurnStatus, projection.error))
        .catch(error => this.rejectDone(toError(error)))
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
      this.compactionSeq += 1
      this.publishCliContextId()
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
    await dispatchRuntimeServerRequest({
      message,
      appServer,
      acceptingServerRequests: this.acceptingServerRequests,
      finalizing: this.finalizing,
      runtimeThreadID: this.runtimeThreadID,
      codexTurnID: this.codexTurnID,
      compactionSeq: this.compactionSeq,
      latestTokenUsage: this.latestTokenUsage,
      prepared: this.prepared,
      skillUsage: this.skillUsage,
      turnRecorder: this.turnRecorder,
      toolAbortSignal: this.toolAbortController.signal,
      noteLeadRuntimeProgress: () => this.noteLeadRuntimeProgress(),
      recordUsedSkills: names => this.recordUsedSkills(names),
      setWaitingOnUserInput: waiting => {
        this.waitingOnUserInput = waiting
      },
      claimFinalization: () => this.claimFinalization(),
      interruptTurn: (threadID, turnID) =>
        threadID && turnID ? this.interruptCodexTurn(threadID, turnID) : this.interrupt(),
      scheduleClaimedCommit: (status, details) => this.scheduleClaimedCommit(status, details),
      rejectDone: error => this.rejectDone(error)
    })
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

  private applyOriginalHumanRequest(update: TurnSteerUpdate): void {
    const instructions = stringValue(this.prepared.threadConfig.developer_instructions) ?? ''
    const updated = updateOriginalHumanRequestInstructions(instructions, this.originalHumanRequest, update)
    if (!updated) return
    this.prepared.threadConfig.developer_instructions = updated.instructions
    this.originalHumanRequest = updated.originalHumanRequest
  }

  private startActiveTurnUpdatePoll(): void {
    this.activeTurnUpdateTimer = startSessionActiveTurnUpdatePoll({
      opts: this.opts,
      prepared: this.prepared,
      skillUsage: this.skillUsage,
      turnRecorder: this.turnRecorder,
      appliedEventIDs: this.appliedEventIDs,
      state: () => ({
        blocked: this.activeTurnUpdateInFlight || this.finalizing || this.completionPending || this.recoveryInFlight,
        client: this.client,
        runtimeThreadID: this.runtimeThreadID,
        codexTurnID: this.codexTurnID
      }),
      isFinalizing: () => this.finalizing,
      setInFlight: inFlight => {
        this.activeTurnUpdateInFlight = inFlight
      },
      applyOriginalHumanRequest: update => this.applyOriginalHumanRequest(update),
      onFatalError: error => {
        if (this.finalizing) return
        this.finalizing = true
        this.rejectDone(error)
      }
    })
  }

  private recordUsedSkills(skillNames: string[], turnID = this.codexTurnID): void {
    for (const name of skillNames) this.turnRecorder.recordSkillUsed(turnID, name)
  }
}
