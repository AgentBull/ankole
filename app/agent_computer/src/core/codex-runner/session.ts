import { jsonObject, type JsonObject as JSONObject } from '@pleisto/active-support'
import { genericHash } from '@ankole/kernel'
import { existsSync, readFileSync, realpathSync, statSync } from 'node:fs'
import { resolve } from 'node:path'
import { errorMessage } from '../../common/errors'
import { jsonBytes } from '../../fabric/envelope_proto'
import type { TurnStart, TurnSteerUpdate } from '../../lanes/actor_lane'
import {
  rpcMethods,
  type BackgroundAgentJobResponse,
  type BackgroundAgentJobStatus,
  type BackgroundAgentJobTurnUsage,
  type RPCRequester
} from '../../lanes/rpc_lane'
import { CodexAppServerClient, CodexAppServerRPCError, type JSONRPCMessage } from '../../tools/codex/app-server-client'
import type { DynamicToolCallParams } from '../../tools/codex/generated/protocol/v2/DynamicToolCallParams'
import {
  boundedBackgroundAgentJobPaths,
  emptyBackgroundAgentJobPathHandoff,
  mergeBackgroundAgentJobPathHandoffs,
  type BackgroundAgentJobPathHandoff
} from '../background-agent-job-handoff'
import { pathIsWithin } from '../path-boundary'
import {
  approvalAcceptance,
  approvalRequestMethod,
  projectCodexNotification,
  stringValue,
  textInput
} from '../../tools/codex/protocol'
import type { TurnHandlerResult } from '../turns/turn_options'
import { installAndTrustAgentPlugins, type PreparedAgentPlugins } from './agent-plugin-materializer'
import { pendingParentInputFromDynamicTool, PARENT_INPUT_TOOL_NAME } from './parent-input'
import {
  classifyCodexRecoveryFailure,
  initialCodexRecoveryState,
  transitionCodexRecovery,
  type CodexRecoveryState
} from './recovery-policy'
import type { PreparedCodexJobExecution } from './setup'
import { BackgroundAgentJobTurnRecorder } from './turn-recorder'
import { CodexNoProgressGuard, type CodexNoProgressViolation } from './no-progress-guard'

const steerPollIntervalMs = 250

export async function runCodexJobSession(input: PreparedCodexJobExecution): Promise<TurnHandlerResult> {
  return new CodexJobSession(input).run()
}

class CodexJobSession {
  private readonly turnRecorder: BackgroundAgentJobTurnRecorder
  private readonly threadModel: string | undefined
  private readonly done: Promise<void>
  private resolveDone!: () => void
  private rejectDone!: (error: Error) => void

  private client: CodexAppServerClient | undefined
  private runtimeThreadID: string | undefined
  private codexTurnID: string | undefined
  private outputText = ''
  private latestTokenUsage: BackgroundAgentJobTurnUsage | undefined
  private completedFilesChanged: BackgroundAgentJobPathHandoff = emptyBackgroundAgentJobPathHandoff()
  private activeFilesChanged: BackgroundAgentJobPathHandoff = emptyBackgroundAgentJobPathHandoff()
  private waitingOnUserInput = false
  private recoveryInFlight = false
  private recoveryState: CodexRecoveryState = initialCodexRecoveryState
  private emptyReportRetries = 0
  private recreatedThreadOnResume = false
  private finalizing = false
  private closing = false
  private turnResult: TurnHandlerResult | undefined
  private authReconcilePromise: Promise<JSONObject> | undefined

  private steerTimer: ReturnType<typeof setInterval> | undefined
  private steerInFlight = false
  private resolveCompaction: (() => void) | undefined
  private rejectCompaction: ((error: Error) => void) | undefined
  private compactingThreadID: string | undefined
  private compactionTurnID: string | undefined
  private readonly completedCompactionTurnIDs = new Set<string>()
  private readonly noProgressGuard = new CodexNoProgressGuard()
  private noProgressFailureInFlight = false

  constructor(private readonly input: PreparedCodexJobExecution) {
    this.runtimeThreadID = input.job.runtimeThreadId || undefined
    this.threadModel = input.runtimeConfig.mode === 'aigateway' ? input.runtimeConfig.modelOverride : undefined
    this.turnRecorder = new BackgroundAgentJobTurnRecorder({
      jobID: input.jobID,
      attempt: input.job.attempts,
      actorTurn: input.turnStart.turn,
      upsert: request =>
        input.opts.rpc(rpcMethods.backgroundAgentJobTurnUpsert, request, { turn: input.turnStart.turn })
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
        let error = caughtError
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

    if (this.steerTimer) clearInterval(this.steerTimer)
    this.input.opts.abortSignal?.removeEventListener('abort', this.onAbort)
    this.closing = true

    const captureCleanupError = (error: unknown): void => {
      if (hasThrownError) return
      thrownError = error
      hasThrownError = true
    }

    try {
      await this.client?.close()
    } catch (error) {
      captureCleanupError(error)
    }
    try {
      await this.input.cleanup()
    } catch (error) {
      captureCleanupError(error)
    }
    try {
      if (this.input.runtimeConfig.mode === 'official_subscription' && !this.authReconcilePromise) {
        await this.reconcileCodexAuth()
      }
    } catch (error) {
      captureCleanupError(error)
    }
    try {
      await this.turnRecorder.flush()
    } catch (error) {
      captureCleanupError(error)
    }

    if (hasThrownError) throw thrownError
    if (!this.turnResult) throw new Error('background agent job turn ended without a result')
    return this.turnResult
  }

  private async execute(): Promise<void> {
    const { sandbox } = this.input
    const abortSignal = this.input.opts.abortSignal
    abortSignal?.addEventListener('abort', this.onAbort, { once: true })
    if (abortSignal?.aborted) this.onAbort()
    if (await this.finishClaimedFinalization()) return

    this.client = new CodexAppServerClient({
      cwd: sandbox.cwd,
      env: sandbox.env,
      commandArgv: sandbox.commandArgv,
      onNotification: this.handleNotification,
      onServerRequest: this.handleServerRequest,
      onExit: error => {
        if (!this.closing && !this.finalizing) this.rejectDone(error)
      }
    })

    const initializeResponse = await this.client.initialize()
    if (await this.finishClaimedFinalization()) return
    await installAndTrustAgentPlugins(this.client, sandbox.codexCwd, this.input.preparedAgentPlugins)
    if (await this.finishClaimedFinalization()) return
    const expectedSkillNames = [
      ...this.input.runtimeFiles.expectedSkillNames,
      ...this.input.preparedAgentPlugins.expectedSkillNames
    ].sort(compareCodePoints)
    await configureCodexSkills(
      this.client,
      sandbox.codexCwd,
      this.input.runtimeFiles.skillsRoot,
      this.input.runtimeFiles.expectedSkillNames,
      this.input.preparedAgentPlugins
    )
    if (await this.finishClaimedFinalization()) return

    this.recreatedThreadOnResume = await this.resumeExistingThread()
    if (await this.finishClaimedFinalization()) return
    if (!this.runtimeThreadID) await this.startNewThread()
    if (await this.finishClaimedFinalization()) return
    await this.publishRunningStatus(initializeResponse, expectedSkillNames)
    if (await this.finishClaimedFinalization()) return

    const initialTurnInput = turnInput(this.input.turnStart, this.input.job)
    await this.startCodexTurn(
      this.recreatedThreadOnResume ? recreatedThreadInput(this.input.job, initialTurnInput) : initialTurnInput
    )
    if (await this.finishClaimedFinalization()) return
    this.startSteeringPoll()
    await this.done
  }

  private async resumeExistingThread(): Promise<boolean> {
    if (!this.runtimeThreadID || !this.client) return false
    try {
      await this.client.request('thread/resume', {
        ['threadId']: this.runtimeThreadID,
        cwd: this.input.sandbox.codexCwd,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        ...(this.threadModel ? { model: this.threadModel } : {})
      })
      this.input.opts.onTurnActivity?.('codex:thread_resumed')
      return false
    } catch (error) {
      const decision = transitionCodexRecovery({
        stage: 'resume',
        failure: classifyCodexRecoveryFailure(
          error instanceof CodexAppServerRPCError ? error.details : { message: errorMessage(error) }
        ),
        state: this.recoveryState
      })
      this.recoveryState = decision.nextState
      if (decision.action === 'durable_retry') throw new CodexJobTransientError(error)
      if (decision.action !== 'replace_thread') throw error
      if (this.input.job.continuedFromJobId) {
        throw new Error('Respawned background agent job could not resume its source Codex thread')
      }
      this.runtimeThreadID = undefined
      return true
    }
  }

  private async publishRunningStatus(initializeResponse: JSONObject, expectedSkillNames: string[]): Promise<void> {
    if (!this.runtimeThreadID) throw new Error('codex thread is not available')
    const { opts, turnStart, jobID, job, sandbox, jobProject, mcpServers, projection } = this.input
    await opts.rpc(
      rpcMethods.backgroundAgentJobStatusUpdate,
      {
        jobId: jobID,
        status: 'running',
        runtimeThreadId: this.runtimeThreadID,
        metadataJson: jsonBytes({
          codex_account_id: job.codexAccountId,
          codex_user_agent: stringValue(initializeResponse.userAgent),
          job_project_cwd: sandbox.codexCwd,
          job_workspace: jobProject.root,
          mcp_server_names: mcpServers.map(server => server.name).sort(compareCodePoints),
          ...(this.recreatedThreadOnResume
            ? {
                runtime_checkpoint_recreated: true,
                runtime_checkpoint_recovery: 'new_thread_from_bounded_history'
              }
            : {}),
          projected_tool_names: projection.dynamicTools.map(tool => tool.name),
          quarantined_tool_names: projection.quarantinedTools,
          shared_skill_count: expectedSkillNames.length
        })
      },
      { turn: turnStart.turn }
    )
  }

  private reconcileCodexAuth(): Promise<JSONObject> {
    if (this.input.runtimeConfig.mode !== 'official_subscription') return Promise.resolve({ changed: false })
    this.authReconcilePromise ??= writebackCodexAuth({
      turnStart: this.input.turnStart,
      jobID: this.input.jobID,
      authPath: this.input.materialized.authPath,
      initialAuthHash: this.input.materialized.initialAuthHash,
      rpc: this.input.opts.rpc
    })
    return this.authReconcilePromise
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
      if (this.input.runtimeConfig.mode === 'official_subscription') await this.reconcileCodexAuth()

      await this.input.opts.rpc(
        rpcMethods.backgroundAgentJobStatusUpdate,
        {
          jobId: this.input.jobID,
          status,
          ...(this.runtimeThreadID ? { runtimeThreadId: this.runtimeThreadID } : {}),
          ...(details.result ? { resultJson: jsonBytes(details.result) } : {}),
          ...(details.error ? { errorJson: jsonBytes(details.error) } : {}),
          ...(details.metadata ? { metadataJson: jsonBytes(details.metadata) } : {})
        },
        { turn: this.input.turnStart.turn }
      )
      this.resolveDone()
    } catch (error) {
      const failure = /background_agent_job_pending_steer/.test(errorMessage(error))
        ? new BackgroundAgentJobPendingSteerError(error)
        : error instanceof Error
          ? error
          : new Error(String(error))
      this.rejectDone(failure)
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
    if (!this.client) throw new Error('codex app-server is not available')
    const started = jsonObject(
      await this.client.request('thread/start', {
        cwd: this.input.sandbox.codexCwd,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        threadSource: 'ankole',
        dynamicTools: this.input.projection.dynamicTools,
        ...(this.threadModel ? { model: this.threadModel } : {})
      })
    )
    this.runtimeThreadID = stringValue(jsonObject(started.thread).id)
    if (!this.runtimeThreadID) throw new Error('codex app-server did not return a thread id')
    this.input.opts.onTurnActivity?.('codex:thread_started')
  }

  private async startCodexTurn(input: string): Promise<void> {
    if (!this.client || !this.runtimeThreadID) throw new Error('codex thread is not available')
    const clientUserMessageID = turnClientUserMessageID(this.input.turnStart)
    const startedTurn = jsonObject(
      await this.client.request('turn/start', {
        ['threadId']: this.runtimeThreadID,
        ...(clientUserMessageID ? { ['clientUserMessageId']: clientUserMessageID } : {}),
        input: textInput(input),
        cwd: this.input.sandbox.codexCwd,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' },
        ...(this.threadModel ? { model: this.threadModel } : {})
      })
    )
    this.codexTurnID = stringValue(jsonObject(startedTurn.turn).id)
    if (!this.codexTurnID) throw new Error('codex app-server did not return a turn id')
    this.turnRecorder.recordTurnStarted(this.runtimeThreadID, jsonObject(startedTurn.turn), input, clientUserMessageID)
    this.input.opts.onTurnActivity?.('codex:turn_started')
  }

  private async compactThread(): Promise<void> {
    if (!this.client || !this.runtimeThreadID) throw new Error('codex thread is not available for compaction')
    const compacted = new Promise<void>((resolve, reject) => {
      this.resolveCompaction = resolve
      this.rejectCompaction = reject
      this.compactingThreadID = this.runtimeThreadID
    })
    try {
      await this.client.request('thread/compact/start', {
        ['threadId']: this.runtimeThreadID
      })
      await compacted
    } finally {
      this.resolveCompaction = undefined
      this.rejectCompaction = undefined
      this.compactingThreadID = undefined
      this.compactionTurnID = undefined
    }
  }

  private async persistRuntimeThreadAnchor(reason: string): Promise<void> {
    if (!this.runtimeThreadID) throw new Error('codex thread is not available for persistence')
    await this.input.opts.rpc(
      rpcMethods.backgroundAgentJobStatusUpdate,
      {
        jobId: this.input.jobID,
        status: 'running',
        runtimeThreadId: this.runtimeThreadID,
        metadataJson: jsonBytes({ runtime_thread_recreated_reason: reason })
      },
      { turn: this.input.turnStart.turn }
    )
  }

  private async handleTurnCompleted(
    status: BackgroundAgentJobStatus,
    codexTurnStatus: string,
    error: JSONObject
  ): Promise<void> {
    if (this.finalizing || this.waitingOnUserInput || this.recoveryInFlight) return

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
      const artifactPaths = ownerVisibleArtifactPaths(this.input.jobProject, filesChanged.paths)
      await this.commit('succeeded', {
        result: {
          output_text: this.outputText,
          stop_reason: 'completed',
          attempt: this.input.job.attempts,
          ...(this.runtimeThreadID ? { runtime_thread_id: this.runtimeThreadID } : {}),
          codex_turn_status: codexTurnStatus,
          ...(this.latestTokenUsage ? { usage: this.latestTokenUsage } : {}),
          files_changed: filesChanged,
          project_path: this.input.jobProject.root,
          artifacts: boundedBackgroundAgentJobPaths(artifactPaths, {
            totalCount: filesChanged.total_count,
            truncated: filesChanged.truncated || artifactPaths.length < filesChanged.paths.length
          }),
          artifact_roots: artifactDiscoveryRoots(this.input.jobProject)
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
        if (this.input.job.continuedFromJobId) {
          throw new Error('Respawned background agent job lost its source Codex thread')
        }
        await this.turnRecorder.flush()
        await this.startNewThread()
        await this.persistRuntimeThreadAnchor('unknown_session')
        this.outputText = ''
        await this.startCodexTurn(recreatedThreadInput(this.input.job, retryContinuationInput()))
        return
      }
      if (decision.action === 'durable_retry') throw new CodexJobTransientError(error)

      await this.commit('failed', {
        error: {
          code: stringValue(error.codexErrorInfo) ?? 'codex_turn_failed',
          summary: stringValue(error.message) ?? (this.outputText || `Codex turn ${codexTurnStatus}`),
          codex_turn_status: codexTurnStatus,
          codex_error: error
        }
      })
    } catch (recoveryError) {
      this.rejectDone(recoveryError instanceof Error ? recoveryError : new Error(String(recoveryError)))
    } finally {
      this.recoveryInFlight = false
    }
  }

  private readonly handleNotification = (message: JSONRPCMessage): void => {
    if (this.finalizing) return
    this.turnRecorder.handleNotification(message)
    const noProgressViolation = this.noProgressGuard.recordNotification(message, this.runtimeThreadID)
    if (noProgressViolation && !this.noProgressFailureInFlight) {
      this.noProgressFailureInFlight = true
      void this.failNoProgress(noProgressViolation)
    }
    const params = jsonObject(message.params)
    const notificationThreadID = stringValue(params.threadId)
    const isLeadNotification = !notificationThreadID || notificationThreadID === this.runtimeThreadID
    const projection = projectCodexNotification(message)
    if (projection.type !== 'ignored') {
      this.input.opts.onTurnActivity?.(`codex:${isLeadNotification ? '' : 'child:'}${projection.type}`)
    }
    if (!isLeadNotification) return

    if (message.method === 'item/completed') {
      const item = jsonObject(params.item)
      if (item.type === 'contextCompaction' && stringValue(params['threadId']) === this.compactingThreadID) {
        const completedTurnID = stringValue(params['turnId']) ?? this.compactionTurnID
        if (completedTurnID) this.completedCompactionTurnIDs.add(completedTurnID)
        this.resolveCompaction?.()
      }
    }

    if (projection.type === 'turn_started') {
      this.completedFilesChanged = mergeBackgroundAgentJobPathHandoffs(
        this.completedFilesChanged,
        this.activeFilesChanged
      )
      this.activeFilesChanged = emptyBackgroundAgentJobPathHandoff()
      this.codexTurnID = projection.turnID ?? this.codexTurnID
      if (this.resolveCompaction && projection.turnID) this.compactionTurnID = projection.turnID
    } else if (projection.type === 'agent_completed') {
      this.outputText = projection.text
    } else if (projection.type === 'token_usage') {
      this.latestTokenUsage = projection.usage
    } else if (projection.type === 'turn_diff') {
      this.activeFilesChanged = projection.filesChanged
    } else if (projection.type === 'turn_completed' && !this.finalizing && !this.waitingOnUserInput) {
      const completedTurnID = stringValue(jsonObject(jsonObject(message.params).turn).id)
      if (completedTurnID && this.completedCompactionTurnIDs.delete(completedTurnID)) return
      if (this.rejectCompaction && (!this.compactionTurnID || completedTurnID === this.compactionTurnID)) {
        this.rejectCompaction(
          new Error(
            stringValue(projection.error.message) ??
              `Codex compaction turn ${projection.codexTurnStatus} before contextCompaction completed`
          )
        )
        return
      }
      this.completedFilesChanged = mergeBackgroundAgentJobPathHandoffs(
        this.completedFilesChanged,
        this.activeFilesChanged
      )
      this.activeFilesChanged = emptyBackgroundAgentJobPathHandoff()
      void this.handleTurnCompleted(projection.terminalStatus, projection.codexTurnStatus, projection.error)
    }
  }

  private readonly handleServerRequest = async (
    message: JSONRPCMessage,
    appServer: CodexAppServerClient
  ): Promise<void> => {
    if (this.finalizing) return
    const method = typeof message.method === 'string' ? message.method : ''
    if (message.id === undefined) return
    const params = jsonObject(message.params)
    const requestThreadID = stringValue(params.threadId)
    this.noProgressGuard.recordProgress(requestThreadID ?? this.runtimeThreadID)
    const isLeadRequest = !requestThreadID || requestThreadID === this.runtimeThreadID
    this.input.opts.onTurnActivity?.(`codex:${method || 'server_request'}`)

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
        await this.commit('waiting_on_user', {
          metadata: { pending_user_input: pending }
        })
      } catch (error) {
        this.waitingOnUserInput = false
        this.rejectDone(error instanceof Error ? error : new Error(String(error)))
      }
      return
    }

    if (method === 'item/tool/call') {
      const response = await this.input.projection.handleToolCall(
        message.params as DynamicToolCallParams,
        this.input.opts.abortSignal ?? new AbortController().signal
      )
      await appServer.respond(message.id, response)
      return
    }
    if (approvalRequestMethod(method)) {
      await appServer.respond(message.id, approvalAcceptance(method, params))
      return
    }

    await appServer.respondError(message.id, -32601, `Ankole does not implement Codex server request ${method}`)
    if (!isLeadRequest) return
    await this.interrupt().catch(() => undefined)
    await this.commit('failed', {
      error: {
        code: 'unsupported_server_request',
        summary: `Unsupported Codex server request: ${method}`
      }
    })
  }

  private readonly onAbort = (): void => {
    if (!this.claimFinalization()) return
    void this.interrupt().catch(() => undefined)
    void this.client?.close().catch(() => undefined)
    void this.commitClaimed('stopped', {
      metadata: { stop_reason: abortReason(this.input.opts.abortSignal) }
    })
  }

  private async finishClaimedFinalization(): Promise<boolean> {
    if (!this.finalizing) return false
    await this.done
    return true
  }

  private async failNoProgress(violation: CodexNoProgressViolation): Promise<void> {
    this.input.opts.onTurnActivity?.('codex:no_progress')
    await this.interrupt().catch(() => undefined)
    await this.commit('failed', {
      error: {
        code: 'codex_no_progress',
        summary: `Codex made ${violation.consecutiveModelCalls} consecutive model calls without an observable item, plan, diff, or tool request.`,
        consecutive_model_calls: violation.consecutiveModelCalls,
        ...(violation.threadID ? { runtime_thread_id: violation.threadID } : {}),
        usage: violation.usage
      }
    })
  }

  private startSteeringPoll(): void {
    this.steerTimer = setInterval(() => {
      if (
        this.steerInFlight ||
        this.finalizing ||
        this.recoveryInFlight ||
        !this.client ||
        !this.runtimeThreadID ||
        !this.codexTurnID
      ) {
        return
      }
      const updates = this.input.opts.pollSteering?.() ?? []
      if (updates.length === 0) return
      this.steerInFlight = true
      void steerActiveTurn(
        this.client,
        this.runtimeThreadID,
        this.codexTurnID,
        updates,
        () => !this.finalizing,
        async (eventID, text) => {
          this.turnRecorder.recordSteering(this.codexTurnID, eventID, text)
          await this.turnRecorder.flush()
        },
        this.input.opts.onSteeringApplied
      )
        .catch(error => {
          if (this.finalizing) return
          this.finalizing = true
          this.rejectDone(error instanceof Error ? error : new Error(String(error)))
        })
        .finally(() => {
          this.steerInFlight = false
        })
    }, steerPollIntervalMs)
    this.steerTimer.unref?.()
  }
}

export async function configureCodexSkills(
  client: Pick<CodexAppServerClient, 'request'>,
  cwd: string,
  skillsRoot: string,
  expectedStandaloneSkillNames: string[],
  preparedAgentPlugins: PreparedAgentPlugins
): Promise<string[]> {
  await client.request('skills/extraRoots/set', {
    extraRoots: [skillsRoot]
  })
  const before = await listCodexSkills(client, cwd)
  const beforeByName = new Map(before.map(skill => [skill.name, skill]))

  for (const agentPlugin of preparedAgentPlugins.agentPlugins) {
    const enabledNames = new Set(agentPlugin.enabledSkillNames)
    for (const memberName of agentPlugin.memberSkillNames) {
      const codexName = `${agentPlugin.manifestName}:${memberName}`
      const skill = beforeByName.get(codexName)
      if (!skill) throw new Error(`Codex did not discover Agent Plugin Skill ${codexName}`)
      if (!skill.path.startsWith('/')) {
        throw new Error(`Codex returned a non-absolute path for Agent Plugin Skill ${codexName}: ${skill.path}`)
      }
      const enabled = enabledNames.has(memberName)
      const response = jsonObject(
        await client.request('skills/config/write', {
          path: skill.path,
          enabled
        })
      )
      if (response.effectiveEnabled !== enabled) {
        throw new Error(`Codex did not persist Agent Plugin Skill state for ${codexName}`)
      }
    }
  }

  const discovered = await listCodexSkills(client, cwd)
  const discoveredByName = new Map(discovered.map(skill => [skill.name, skill]))
  const missingStandalone = expectedStandaloneSkillNames.filter(name => discoveredByName.get(name)?.enabled !== true)
  if (missingStandalone.length > 0) {
    throw new Error(`Codex did not discover enabled standalone Skills: ${missingStandalone.join(', ')}`)
  }
  for (const agentPlugin of preparedAgentPlugins.agentPlugins) {
    const enabledNames = new Set(agentPlugin.enabledSkillNames)
    for (const memberName of agentPlugin.memberSkillNames) {
      const codexName = `${agentPlugin.manifestName}:${memberName}`
      const expected = enabledNames.has(memberName)
      const actual = discoveredByName.get(codexName)?.enabled
      if (actual !== expected) {
        throw new Error(`Codex Agent Plugin Skill state mismatch for ${codexName}: expected ${expected}`)
      }
    }
  }
  return discovered
    .filter(skill => skill.enabled)
    .map(skill => skill.name)
    .sort(compareCodePoints)
}

async function listCodexSkills(
  client: Pick<CodexAppServerClient, 'request'>,
  cwd: string
): Promise<Array<{ name: string; path: string; enabled: boolean }>> {
  const response = jsonObject(await client.request('skills/list', { cwds: [cwd], forceReload: true }))
  const entries = Array.isArray(response.data) ? response.data.map(jsonObject) : []
  const entry = entries.find(candidate => stringValue(candidate.cwd) === cwd) ?? entries[0]
  if (!entry) return []
  const errors = Array.isArray(entry.errors) ? entry.errors.map(jsonObject) : []
  if (errors.length > 0) {
    const summaries = errors
      .map(error => [stringValue(error.path), stringValue(error.message)].filter(Boolean).join(': '))
      .filter(Boolean)
    throw new Error(`Codex skill discovery failed: ${summaries.join('; ') || 'unknown skill error'}`)
  }
  if (!Array.isArray(entry.skills)) return []
  return entry.skills.map(jsonObject).map((skill, index) => {
    const name = stringValue(skill.name)
    const path = stringValue(skill.path)
    if (!name || !path || typeof skill.enabled !== 'boolean') {
      throw new Error(`Codex skills/list returned an invalid Skill at index ${index}`)
    }
    return { name, path, enabled: skill.enabled }
  })
}

async function writebackCodexAuth(input: {
  turnStart: TurnStart
  jobID: string
  authPath?: string
  initialAuthHash?: string
  rpc: RPCRequester
}): Promise<JSONObject> {
  if (!input.authPath || !input.initialAuthHash) throw new Error('Codex account auth was not materialized')
  const authJSON = readFileSync(input.authPath, 'utf8')
  const finalHash = genericHash(Buffer.from(authJSON))
  if (finalHash === input.initialAuthHash) return { changed: false, auth_hash: finalHash }

  let lastError: unknown
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      await input.rpc(
        rpcMethods.codexAccountAuthUpdate,
        { jobId: input.jobID, authJson: authJSON },
        { turn: input.turnStart.turn }
      )
      return { changed: true, auth_hash: finalHash }
    } catch (error) {
      lastError = error
      if (attempt < 3) await Bun.sleep(50 * 2 ** (attempt - 1))
    }
  }
  throw lastError instanceof Error ? lastError : new Error(errorMessage(lastError))
}

function turnInput(turnStart: TurnStart, job: BackgroundAgentJobResponse): string {
  let input: string
  if (turnStart.actor_event.type === 'command.steer') {
    const command = jsonObject(jsonObject(jsonObject(turnStart.actor_event.payload_json).data).command)
    const message = stringValue(command.argsText)
    if (!message) throw new Error('BackgroundAgentJob message command is missing argsText')
    input = message
  } else if (job.attempts > 1 && job.runtimeThreadId) {
    input = 'Continue the Job task. Re-check the acceptance criteria in the original task before finishing.'
  } else {
    input = job.task
  }
  const pendingSteering = pendingSteeringInput(turnStart)
  return pendingSteering ? `${input}\n\nPending instructions for this job:\n${pendingSteering}`.trim() : input
}

function ownerVisibleArtifactPaths(project: PreparedCodexJobExecution['jobProject'], filesChanged: string[]): string[] {
  const artifacts = new Set<string>()
  for (const path of filesChanged) {
    const artifact = ownerVisibleArtifactPath(project, path)
    if (artifact) artifacts.add(artifact)
  }
  return [...artifacts].sort(compareCodePoints)
}

function artifactDiscoveryRoots(project: PreparedCodexJobExecution['jobProject']): BackgroundAgentJobPathHandoff {
  return boundedBackgroundAgentJobPaths([project.root])
}

function ownerVisibleArtifactPath(
  project: PreparedCodexJobExecution['jobProject'],
  changedPath: string
): string | undefined {
  const hostPath = changedPath.startsWith('/') ? resolve(changedPath) : resolve(project.root, changedPath)
  if (!existsSync(hostPath)) return undefined

  try {
    const realRoot = realpathSync(project.root)
    const realPath = realpathSync(hostPath)
    if (!pathIsWithin(realRoot, realPath) || !statSync(realPath).isFile()) return undefined
    return realPath
  } catch {
    return undefined
  }
}

function turnClientUserMessageID(turnStart: TurnStart): string | undefined {
  if (turnStart.actor_event.type === 'command.steer') return turnStart.actor_event.actor_event_id
  const pending = turnStart.request_context?.pending_steering
  if (!Array.isArray(pending)) return undefined
  return stringValue(jsonObject(pending[0]).actor_event_id)
}

function pendingSteeringInput(turnStart: TurnStart): string {
  const pending = turnStart.request_context?.pending_steering
  if (!Array.isArray(pending)) return ''
  return pending
    .map(value => {
      const item = jsonObject(value)
      const text = stringValue(item.text)
      const eventID = stringValue(item.actor_event_id)
      return text ? `${eventID ? `[steer ${eventID}]\n` : ''}${text}` : ''
    })
    .filter(Boolean)
    .join('\n\n')
}

function retryContinuationInput(): string {
  return 'Continue the Job task after the transient runtime error. Inspect the current workspace before repeating any side effect, then re-check the original acceptance criteria.'
}

function recreatedThreadInput(job: BackgroundAgentJobResponse, continuation: string): string {
  const priorAttempts = job.attemptHistory?.length
    ? `\n\nBounded history from prior execution attempts:\n${JSON.stringify(job.attemptHistory, null, 2)}`
    : ''
  return `${job.task}\n\nThe previous Codex thread could not be resumed. Inspect the existing working directory and continue from durable artifacts.${priorAttempts}\n\nCurrent continuation instructions:\n${continuation}\n\nRe-check every acceptance criterion before finishing.`.trim()
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

class BackgroundAgentJobPendingSteerError extends Error {
  readonly code = 'background_agent_job_pending_steer'
  readonly retryable = true

  constructor(cause: unknown) {
    super(`BackgroundAgentJob terminal commit deferred for pending steering: ${errorMessage(cause)}`, {
      cause: cause instanceof Error ? cause : undefined
    })
    this.name = 'BackgroundAgentJobPendingSteerError'
  }
}

function abortReason(signal?: AbortSignal): string {
  if (!signal?.aborted) return 'stopped'
  return signal.reason instanceof Error ? signal.reason.message : String(signal.reason ?? 'stopped')
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}
