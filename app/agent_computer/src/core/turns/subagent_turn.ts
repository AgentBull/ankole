import { jsonObject, type JsonObject as JSONObject } from '@pleisto/active-support'
import { genericHash } from '@ankole/kernel'
import { mkdirSync, readFileSync } from 'node:fs'
import { errorMessage } from '../../common/errors'
import { toWorkspacePath, WORKSPACE_MODEL_ROOT } from '../../core/workspace-paths'
import type { TurnStart, TurnSteerUpdate } from '../../lanes/actor_lane'
import {
  assertRPCResponse,
  type AIGatewayAPIKeyResponse,
  type CodexAccountAuthUpdateResponse,
  type MemoryRPCMethod,
  type RPCSchemaByMethod,
  type SubagentDelegationResponse,
  type SubagentDelegationStatus,
  type SubagentTurnUsage
} from '../../lanes/rpc_lane'
import { prepareActorWorkspace } from '../../worker/workspace'
import { CodexAppServerClient, type JSONRPCMessage } from '../../tools/codex/app-server-client'
import { materializeCodexConfig } from '../../tools/codex/config'
import {
  approvalAcceptance,
  approvalRequestMethod,
  projectCodexNotification,
  stringValue,
  textInput
} from '../../tools/codex/protocol'
import { resolveCodexRuntimeConfig } from '../../tools/codex/runtime-config'
import { codexAppServerSandboxSpec, resolveCodexWorkdir } from '../../tools/codex/sandbox'
import { buildSubagentProjection, deepResearchToolNames } from '../../tools/subagent/dynamic-tools'
import type { DynamicToolCallParams } from '../../tools/subagent/generated/protocol/v2/DynamicToolCallParams'
import { materializeSubagentRuntimeFiles, SUBAGENT_SKILLS_SANDBOX_ROOT } from '../../tools/subagent/runtime-files'
import {
  createResearchDeliveryValidatorTool,
  evaluateDeepResearchArtifacts
} from '../../tools/subagent/research-artifacts'
import { createResearchEvidenceArchiveRuntime } from '../../tools/subagent/research-evidence-archive'
import { SubagentTurnRecorder } from '../../tools/subagent/turn-recorder'
import {
  pendingUserInputFromDynamicTool,
  SUBAGENT_USER_INPUT_TOOL_NAME,
  subagentUserInputToolSpec
} from '../../tools/subagent/user-input-bridge'
import { createMemoryTools } from '../../tools/memory/memory-tools'
import { createWebTools } from '../../tools/web/web-tools'
import { createBrowserTools } from '../../tools/browser/browser-tools'
import { createComputerToolContext } from '../../tools/computer'
import { httpClientFromAIGatewayAPIKey } from '../ai_gateway_transport'
import { resolveAgentConversationContext } from './turn_context'
import { resolveBrowserRuntimeConfig } from './browser_runtime_config'
import { resolveWorkerEnv } from './worker_env'
import { resolveDeepResearchRuntimeConfig } from './deep_research_runtime_config'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'

const terminalStatuses = new Set<SubagentDelegationStatus>(['succeeded', 'failed', 'stopped'])
const steerPollIntervalMs = 250

export async function runSubagentTurn(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<TurnHandlerResult> {
  const delegationID = delegationIDFromTurn(turnStart)
  const getDelegation = required(opts.getSubagentDelegation, 'subagent get')
  const updateStatus = required(opts.updateSubagentDelegationStatus, 'subagent status update')
  const initial = await getDelegation({
    request_id: `subagent-get-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    delegation_id: delegationID
  })
  assertRPCResponse<SubagentDelegationResponse>(initial, 'subagent delegation get rejected')
  const isDeepResearch = initial.runtime === 'deep_research'
  const researchMode = initial.mode ?? 'general'
  const delegationOutputSchema = optionalJSONObject(jsonObject(initial.metadata).output_schema)

  if (terminalStatuses.has(initial.status)) {
    return { kind: 'noop_completed', reason: `subagent_${initial.status}` }
  }

  if (!opts.workspaceSessionsRoot || !opts.sharedFsRoot || !opts.userFilesRoot) {
    throw new Error('subagent turn requires worker workspace roots')
  }

  const parentWorkspaceRoot = prepareActorWorkspace(
    { workspaceSessionsRoot: opts.workspaceSessionsRoot, userFilesRoot: opts.userFilesRoot },
    { agent_uid: initial.agent_uid, session_id: initial.session_id }
  )
  const workdir = resolveCodexWorkdir(parentWorkspaceRoot, initial.workdir)
  mkdirSync(workdir, { recursive: true })

  const agentContext = await resolveAgentConversationContext(turnStart, opts)
  const runtimeConfig = await resolveCodexRuntimeConfig({
    turn: turnStart.turn,
    delegation: initial,
    requesters: opts
  })
  const materialized = materializeCodexConfig({
    sharedFsRoot: opts.sharedFsRoot,
    runtime: runtimeConfig,
    enableMultiAgent: isDeepResearch
  })
  const turnRecorder = new SubagentTurnRecorder({
    delegationID,
    attempt: initial.attempts,
    actorTurn: turnStart.turn,
    upsert: required(opts.upsertSubagentDelegationTurn, 'subagent turn upsert')
  })
  let finalizing = false
  const projectionAPIKey =
    runtimeConfig.mode === 'aigateway'
      ? runtimeConfig.aiGatewayKey
      : await requestProjectionAIGatewayKey(turnStart, opts)
  const projectionAIGateway = httpClientFromAIGatewayAPIKey(projectionAPIKey, options =>
    requestProjectionAIGatewayKey(turnStart, opts, options)
  )
  const researchPolicy = isDeepResearch ? await resolveDeepResearchRuntimeConfig(turnStart, opts) : undefined
  const researchBudgetAbort = isDeepResearch ? new AbortController() : undefined
  const browserRuntimeConfig = await resolveBrowserRuntimeConfig(turnStart, opts)
  const workerEnv = await resolveWorkerEnv(turnStart, opts)
  const executionScopeID = `subagent:${delegationID}`
  const baseWebTools = await createWebTools({
    aiGateway: projectionAIGateway,
    abortSignal: opts.abortSignal,
    localBrowser: {
      agentUID: initial.agent_uid,
      executionScopeID,
      ssrfFilter: browserRuntimeConfig.ssrfFilter,
      ...(typeof browserRuntimeConfig.localBrowserIdleTtlMs === 'number'
        ? { localBrowserIdleTtlMs: browserRuntimeConfig.localBrowserIdleTtlMs }
        : {})
    }
  })
  const researchEvidenceArchive = isDeepResearch
    ? createResearchEvidenceArchiveRuntime({
        delegationID,
        workdir,
        sharedFsRoot: opts.sharedFsRoot
      })
    : undefined
  const webTools = researchEvidenceArchive
    ? researchEvidenceArchive.wrapTools(baseWebTools, 'lead', researchBudgetAbort?.signal)
    : baseWebTools
  const browserTools = createBrowserTools(
    createComputerToolContext({
      agentUID: initial.agent_uid,
      conversationID: executionScopeID,
      workspaceRoot: parentWorkspaceRoot,
      browserRemoteCDPConfig: browserRuntimeConfig.remoteCDPConfig,
      localBrowserIdleTtlMs: browserRuntimeConfig.localBrowserIdleTtlMs,
      ssrfFilter: browserRuntimeConfig.ssrfFilter
    })
  )
  const researchBrowserTools = researchEvidenceArchive
    ? researchEvidenceArchive.wrapTools(browserTools, 'lead', researchBudgetAbort?.signal)
    : browserTools
  const researchDeliveryValidator =
    isDeepResearch && researchEvidenceArchive
      ? createResearchDeliveryValidatorTool({
          workdir,
          mode: researchMode,
          delegation: initial,
          outputSchema: delegationOutputSchema,
          webArchives: () => researchEvidenceArchive.records
        })
      : undefined
  const projectedTools = [
    ...webTools,
    ...createMemoryTools({
      turnStart,
      requestMemoryRPC: opts.requestMemoryRPC
        ? <M extends MemoryRPCMethod>(method: M, payload: RPCSchemaByMethod[M]['request']) => {
            const scoped = {
              ...payload,
              delegation_id: delegationID,
              delegation_scope: {
                session_id: initial.session_id,
                signal_channel_id: stringValue(initial.reply_route.signal_channel_id)
              }
            }
            return opts.requestMemoryRPC!(method, scoped)
          }
        : undefined
    }),
    ...researchBrowserTools,
    ...(researchDeliveryValidator ? [researchDeliveryValidator] : [])
  ]
  const projection = buildSubagentProjection({
    tools: projectedTools,
    ...(isDeepResearch ? { allowedToolNames: deepResearchToolNames } : {})
  })
  projection.dynamicTools.push(subagentUserInputToolSpec())
  const runtimeFiles = await materializeSubagentRuntimeFiles({
    workspaceRoot: parentWorkspaceRoot,
    workdir,
    workdirForModel: toWorkspacePath(parentWorkspaceRoot, workdir),
    durableArtifactsRootForModel: `${WORKSPACE_MODEL_ROOT}/user-files`,
    soul: agentContext.soul ?? '',
    mission: agentContext.mission ?? '',
    brainSnapshot: agentContext.brain_snapshot,
    background: initial.background,
    notes: initial.notes,
    timezone: agentContext.conversation?.timezone,
    turn: turnStart.turn,
    enabledSkills: agentContext.skills ?? [],
    skillRoots:
      opts.builtinSkillsRoot && opts.agentInstalledSkillsRoot
        ? {
            builtinSkillsRoot: opts.builtinSkillsRoot,
            agentInstalledSkillsRoot: opts.agentInstalledSkillsRoot,
            ...(opts.internalSkillsRoot ? { internalSkillsRoot: opts.internalSkillsRoot } : {})
          }
        : undefined,
    requestSkillOverlay: opts.requestSkillOverlay,
    runtime: initial.runtime,
    researchMode,
    researchOutputSchema: isDeepResearch ? delegationOutputSchema : undefined,
    requiredBuiltinSkills: isDeepResearch ? ['deep-research'] : []
  })
  let sandbox: ReturnType<typeof codexAppServerSandboxSpec>
  try {
    sandbox = codexAppServerSandboxSpec({
      workspaceRoot: parentWorkspaceRoot,
      workdir,
      materialized,
      runtimeFiles,
      workerEnv
    })
  } catch (error) {
    runtimeFiles.cleanup()
    throw error
  }
  let client: CodexAppServerClient | undefined
  let runtimeThreadID = initial.runtime_thread_id
  let codexTurnID: string | undefined
  let outputText = ''
  let latestTokenUsage: SubagentTurnUsage | undefined
  const latestFilesChanged = new Set<string>()
  let waitingOnUserInput = false
  let recoveryInFlight = false
  let transientRetries = 0
  let compactRetries = 0
  let newThreadRetries = 0
  let emptyReportRetries = 0
  let researchBudgetExhausted = false
  let researchBudgetFinalizing = false
  let recreatedThreadDuringSetup = false
  let closing = false
  let thrownError: unknown
  let hasThrownError = false
  let turnResult: TurnHandlerResult | undefined
  let authReconcilePromise: Promise<JSONObject> | undefined
  let researchWallclockTimer: ReturnType<typeof setTimeout> | undefined
  let researchGraceTimer: ReturnType<typeof setTimeout> | undefined

  const reconcileCodexAuth = (): Promise<JSONObject> => {
    if (runtimeConfig.mode !== 'official_subscription') return Promise.resolve({ changed: false })
    authReconcilePromise ??= writebackCodexAuth({
      turnStart,
      delegationID,
      authPath: materialized.authPath,
      initialAuthHash: materialized.initialAuthHash,
      update: opts.updateCodexAccountAuth
    })
    return authReconcilePromise
  }

  let steerTimer: ReturnType<typeof setInterval> | undefined
  let steerInFlight = false
  let resolveCompaction: (() => void) | undefined
  let rejectCompaction: ((error: Error) => void) | undefined
  let compactingThreadID: string | undefined
  let compactionTurnID: string | undefined
  const completedCompactionTurnIDs = new Set<string>()
  let resolveDone!: () => void
  let rejectDone!: (error: Error) => void
  const done = new Promise<void>((resolve, reject) => {
    resolveDone = resolve
    rejectDone = reject
  })

  const commit = async (
    status: SubagentDelegationStatus,
    details: { result?: JSONObject; error?: JSONObject; metadata?: JSONObject } = {}
  ): Promise<void> => {
    if (finalizing) return
    finalizing = true
    try {
      if (status === 'waiting_on_user') {
        turnRecorder.interruptTurn(codexTurnID, {
          code: 'request_user_input',
          summary: 'Codex was interrupted while waiting for user input.'
        })
      } else if (status === 'failed' || status === 'stopped') {
        turnRecorder.finishTurn(codexTurnID, status, details.error)
      }
      await turnRecorder.flush()

      if (runtimeConfig.mode === 'official_subscription') {
        await reconcileCodexAuth()
      }
      const response = await updateStatus({
        request_id: `subagent-status-${crypto.randomUUID()}`,
        turn: turnStart.turn,
        delegation_id: delegationID,
        status,
        ...(runtimeThreadID ? { runtime_thread_id: runtimeThreadID } : {}),
        ...details
      })
      assertRPCResponse<SubagentDelegationResponse>(response, 'subagent status update rejected')
      resolveDone()
    } catch (error) {
      const failure = /subagent_pending_steer/.test(errorMessage(error))
        ? new SubagentPendingSteerError(error)
        : error instanceof Error
          ? error
          : new Error(String(error))
      rejectDone(failure)
    }
  }

  const interruptCodexTurn = async (threadID: string, turnID: string): Promise<void> => {
    if (!client) return
    await client.request('turn/interrupt', { ['threadId']: threadID, ['turnId']: turnID })
  }

  const interrupt = async (): Promise<void> => {
    if (!runtimeThreadID || !codexTurnID) return
    await interruptCodexTurn(runtimeThreadID, codexTurnID)
  }

  const observeResearchDelivery = (budgetCapped: boolean) =>
    evaluateDeepResearchArtifacts({
      workdir,
      mode: researchMode,
      delegation: initial,
      outputText,
      webArchives: researchEvidenceArchive?.records ?? [],
      outputSchema: delegationOutputSchema,
      budgetCapped
    })

  const finalizeResearchBudget = async (): Promise<void> => {
    if (!isDeepResearch || finalizing || researchBudgetFinalizing) return
    researchBudgetFinalizing = true
    recoveryInFlight = true
    try {
      await interrupt().catch(() => undefined)
      turnRecorder.interruptTurn(codexTurnID, {
        code: 'budget_exhausted',
        summary: 'Codex was interrupted after the Deep Research wallclock budget expired.'
      })
      const observation = observeResearchDelivery(true)
      await commit('failed', {
        result: {
          ...observation.result!,
          stop_reason: 'budget_capped',
          attempt: initial.attempts,
          ...(runtimeThreadID ? { runtime_thread_id: runtimeThreadID } : {}),
          codex_turn_status: 'budget_exhausted',
          ...(latestTokenUsage ? { usage: latestTokenUsage } : {}),
          files_changed: [...latestFilesChanged].sort()
        },
        error: {
          code: 'research_budget_exhausted',
          summary: 'Deep Research exhausted its wallclock budget and submission grace.',
          ...(observation.issues.length > 0 ? { delivery_issues: observation.issues } : {})
        },
        metadata: { research_artifacts_preserved: true, forced_submission: true, budget_exhausted: true }
      })
    } finally {
      recoveryInFlight = false
    }
  }

  const forceResearchSubmission = async (): Promise<void> => {
    if (!isDeepResearch || finalizing || researchBudgetExhausted) return
    researchBudgetExhausted = true
    researchBudgetAbort?.abort(new Error('Deep Research wallclock budget exhausted'))
    if (client && runtimeThreadID && codexTurnID) {
      await client
        .request('turn/steer', {
          ['threadId']: runtimeThreadID,
          ['expectedTurnId']: codexTurnID,
          input: textInput(
            'The research budget is exhausted. Stop new collection and use the submission grace to deliver the best supportable result from evidence already archived, satisfying the delivery and validation contracts.'
          )
        })
        .catch(() => undefined)
    }
    const graceMs = researchPolicy?.submissionGraceMs ?? 0
    if (graceMs === 0) {
      await finalizeResearchBudget()
      return
    }
    researchGraceTimer = setTimeout(() => void finalizeResearchBudget(), graceMs)
    researchGraceTimer.unref?.()
  }

  const startNewThread = async (): Promise<void> => {
    if (!client) throw new Error('codex app-server is not available')
    const started = jsonObject(
      await client.request('thread/start', {
        cwd: sandbox.codexCwd,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        threadSource: 'ankole',
        dynamicTools: projection.dynamicTools,
        ...(runtimeConfig.mode === 'aigateway' ? { model: runtimeConfig.modelOverride } : {})
      })
    )
    runtimeThreadID = stringValue(jsonObject(started.thread).id)
    if (!runtimeThreadID) throw new Error('codex app-server did not return a thread id')
    opts.onTurnActivity?.('codex:thread_started')
  }

  const startCodexTurn = async (input: string): Promise<void> => {
    if (!client || !runtimeThreadID) throw new Error('codex thread is not available')
    const clientUserMessageID = turnClientUserMessageID(turnStart)
    const startedTurn = jsonObject(
      await client.request('turn/start', {
        ['threadId']: runtimeThreadID,
        ...(clientUserMessageID ? { ['clientUserMessageId']: clientUserMessageID } : {}),
        input: textInput(input),
        cwd: sandbox.codexCwd,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' },
        ...(runtimeConfig.mode === 'aigateway' ? { model: runtimeConfig.modelOverride } : {}),
        ...(!isDeepResearch && delegationOutputSchema ? { outputSchema: delegationOutputSchema } : {})
      })
    )
    codexTurnID = stringValue(jsonObject(startedTurn.turn).id)
    if (!codexTurnID) throw new Error('codex app-server did not return a turn id')
    turnRecorder.recordTurnStarted(runtimeThreadID, jsonObject(startedTurn.turn), input, clientUserMessageID)
    opts.onTurnActivity?.('codex:turn_started')
  }

  const compactThread = async (): Promise<void> => {
    if (!client || !runtimeThreadID) throw new Error('codex thread is not available for compaction')
    const compacted = new Promise<void>((resolve, reject) => {
      resolveCompaction = resolve
      rejectCompaction = reject
      compactingThreadID = runtimeThreadID
    })
    try {
      await client.request('thread/compact/start', { ['threadId']: runtimeThreadID })
      await compacted
    } finally {
      resolveCompaction = undefined
      rejectCompaction = undefined
      compactingThreadID = undefined
      compactionTurnID = undefined
    }
  }

  const persistRuntimeThreadAnchor = async (reason: string): Promise<void> => {
    if (!runtimeThreadID) throw new Error('codex thread is not available for persistence')
    const response = await updateStatus({
      request_id: `subagent-thread-anchor-${crypto.randomUUID()}`,
      turn: turnStart.turn,
      delegation_id: delegationID,
      status: 'running',
      runtime_thread_id: runtimeThreadID,
      metadata: { runtime_thread_recreated_reason: reason }
    })
    assertRPCResponse<SubagentDelegationResponse>(response, 'subagent thread anchor update rejected')
  }

  const handleTurnCompleted = async (
    status: SubagentDelegationStatus,
    codexTurnStatus: string,
    error: JSONObject
  ): Promise<void> => {
    if (finalizing || waitingOnUserInput || recoveryInFlight) return

    if (status === 'succeeded') {
      if (!isDeepResearch && !stringValue(outputText)) {
        if (emptyReportRetries < 1) {
          emptyReportRetries += 1
          await startCodexTurn(
            'The delegated work produced no final report. Inspect the completed work and reply with a concise final report that states the outcome and verifies the acceptance criteria.'
          )
          return
        }

        await commit('failed', {
          error: {
            code: 'codex_empty_report',
            summary: 'Codex completed without a usable final report after one report retry.'
          }
        })
        return
      }

      let result: JSONObject = {
        summary: outputText,
        output_text: outputText,
        report: outputText,
        attempt: initial.attempts,
        workdir: initial.workdir ?? workdir,
        ...(runtimeThreadID ? { runtime_thread_id: runtimeThreadID } : {}),
        codex_turn_status: codexTurnStatus,
        ...(latestTokenUsage ? { usage: latestTokenUsage } : {}),
        files_changed: [...latestFilesChanged].sort()
      }

      if (isDeepResearch) {
        const observation = observeResearchDelivery(researchBudgetExhausted)
        result = {
          ...observation.result!,
          ...(researchBudgetExhausted ? { stop_reason: 'budget_capped' } : {}),
          attempt: initial.attempts,
          ...(runtimeThreadID ? { runtime_thread_id: runtimeThreadID } : {}),
          codex_turn_status: codexTurnStatus,
          ...(latestTokenUsage ? { usage: latestTokenUsage } : {}),
          files_changed: [...latestFilesChanged].sort()
        }
      }

      await commit('succeeded', {
        result,
        ...(researchBudgetExhausted ? { metadata: { forced_submission: true } } : {})
      })
      return
    }

    if (status === 'stopped') {
      await commit('stopped', {
        metadata: { stop_reason: stringValue(error.message) ?? 'codex_turn_interrupted' }
      })
      return
    }

    recoveryInFlight = true
    try {
      const retryKind = codexRetryKind(error)

      if (retryKind === 'transient') {
        if (transientRetries < 3) {
          transientRetries += 1
          await Bun.sleep(Math.min(250 * 2 ** (transientRetries - 1), 1_000))
          outputText = ''
          await startCodexTurn(retryContinuationInput())
          return
        }

        throw new SubagentCodexTransientError(error)
      }

      if (retryKind === 'context_overflow' && compactRetries < 1 && client && runtimeThreadID) {
        compactRetries += 1
        await compactThread()
        outputText = ''
        await startCodexTurn(retryContinuationInput())
        return
      }

      if (retryKind === 'unknown_session' && newThreadRetries < 1) {
        newThreadRetries += 1
        await turnRecorder.flush()
        await startNewThread()
        await persistRuntimeThreadAnchor('unknown_session')
        outputText = ''
        await startCodexTurn(recreatedThreadInput(initial, retryContinuationInput()))
        return
      }

      await commit('failed', {
        error: {
          code: stringValue(error.codexErrorInfo) ?? 'codex_turn_failed',
          summary: stringValue(error.message) ?? (outputText || `Codex turn ${codexTurnStatus}`),
          codex_turn_status: codexTurnStatus,
          codex_error: error
        }
      })
    } catch (recoveryError) {
      rejectDone(recoveryError instanceof Error ? recoveryError : new Error(String(recoveryError)))
    } finally {
      recoveryInFlight = false
    }
  }

  const handleNotification = (message: JSONRPCMessage): void => {
    if (finalizing) return
    turnRecorder.handleNotification(message)
    const params = jsonObject(message.params)
    const notificationThreadID = stringValue(params.threadId)
    const isLeadNotification = !notificationThreadID || notificationThreadID === runtimeThreadID
    const projection = projectCodexNotification(message)
    if (projection.type !== 'ignored') {
      opts.onTurnActivity?.(`codex:${isLeadNotification ? '' : 'child:'}${projection.type}`)
    }

    if (!isLeadNotification) return

    if (message.method === 'item/completed') {
      const item = jsonObject(params.item)
      if (item.type === 'contextCompaction' && stringValue(params['threadId']) === compactingThreadID) {
        const completedTurnID = stringValue(params['turnId']) ?? compactionTurnID
        if (completedTurnID) completedCompactionTurnIDs.add(completedTurnID)
        resolveCompaction?.()
      }
    }

    if (projection.type === 'turn_started') {
      codexTurnID = projection.turnID ?? codexTurnID
      if (resolveCompaction && projection.turnID) compactionTurnID = projection.turnID
    } else if (projection.type === 'agent_completed') {
      outputText = projection.text
    } else if (projection.type === 'token_usage') {
      latestTokenUsage = projection.usage
    } else if (projection.type === 'turn_diff') {
      for (const path of projection.filesChanged) latestFilesChanged.add(path)
    } else if (projection.type === 'turn_completed' && !finalizing && !waitingOnUserInput) {
      const completedTurnID = stringValue(jsonObject(jsonObject(message.params).turn).id)
      if (completedTurnID && completedCompactionTurnIDs.delete(completedTurnID)) return
      if (rejectCompaction && (!compactionTurnID || completedTurnID === compactionTurnID)) {
        rejectCompaction(
          new Error(
            stringValue(projection.error.message) ??
              `Codex compaction turn ${projection.codexTurnStatus} before contextCompaction completed`
          )
        )
        return
      }
      void handleTurnCompleted(projection.terminalStatus, projection.codexTurnStatus, projection.error)
    }
  }

  const handleServerRequest = async (message: JSONRPCMessage, appServer: CodexAppServerClient): Promise<void> => {
    if (finalizing) return
    const method = typeof message.method === 'string' ? message.method : ''
    if (message.id === undefined) return
    const params = jsonObject(message.params)
    const requestThreadID = stringValue(params.threadId)
    const isLeadRequest = !requestThreadID || requestThreadID === runtimeThreadID
    opts.onTurnActivity?.(`codex:${method || 'server_request'}`)

    const dynamicToolParams = method === 'item/tool/call' ? (message.params as DynamicToolCallParams) : undefined
    const bridgedUserInput = dynamicToolParams ? pendingUserInputFromDynamicTool(dynamicToolParams) : undefined

    if (method === 'item/tool/requestUserInput' || dynamicToolParams?.tool === SUBAGENT_USER_INPUT_TOOL_NAME) {
      if (!isLeadRequest) {
        await appServer.respondError(
          message.id,
          -32601,
          'Child agents cannot request user input directly; return the question to the lead agent.'
        )
        return
      }
      if (dynamicToolParams && !bridgedUserInput) {
        await appServer.respondError(message.id, -32602, `Invalid arguments for ${SUBAGENT_USER_INPUT_TOOL_NAME}`)
        return
      }
      const pending = bridgedUserInput ?? params
      const requestTurnID = stringValue(pending.turnId) ?? codexTurnID
      turnRecorder.recordRequestUserInput(requestTurnID, pending, message.id)
      waitingOnUserInput = true
      try {
        if (requestThreadID && requestTurnID) {
          await interruptCodexTurn(requestThreadID, requestTurnID).catch(() => undefined)
          turnRecorder.interruptTurn(requestTurnID, {
            code: 'request_user_input',
            summary: 'Codex requested user input.'
          })
        } else {
          await interrupt()
        }
        await commit('waiting_on_user', {
          metadata: { pending_user_input: pending }
        })
      } catch (error) {
        waitingOnUserInput = false
        rejectDone(error instanceof Error ? error : new Error(String(error)))
      }
      return
    }

    if (method === 'item/tool/call') {
      const response = await projection.handleToolCall(
        message.params as DynamicToolCallParams,
        opts.abortSignal ?? new AbortController().signal
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
    await interrupt().catch(() => undefined)
    await commit('failed', {
      error: { code: 'unsupported_server_request', summary: `Unsupported Codex server request: ${method}` }
    })
  }

  const onAbort = (): void => {
    if (finalizing) return
    void interrupt()
      .catch(() => undefined)
      .then(() =>
        commit('stopped', {
          metadata: { stop_reason: abortReason(opts.abortSignal) }
        })
      )
  }

  try {
    client = new CodexAppServerClient({
      cwd: sandbox.cwd,
      env: sandbox.env,
      commandArgv: sandbox.commandArgv,
      onNotification: handleNotification,
      onServerRequest: handleServerRequest,
      onExit: error => {
        if (!closing && !finalizing) {
          rejectDone(error)
        }
      }
    })

    opts.abortSignal?.addEventListener('abort', onAbort, { once: true })
    const initializeResponse = await client.initialize()
    await configureCodexSkills(client, sandbox.codexCwd, runtimeFiles.expectedSkillNames)

    if (runtimeThreadID) {
      try {
        await client.request('thread/resume', {
          ['threadId']: runtimeThreadID,
          cwd: sandbox.codexCwd,
          approvalPolicy: 'never',
          sandbox: 'danger-full-access'
        })
        opts.onTurnActivity?.('codex:thread_resumed')
      } catch (error) {
        const retryKind = codexRetryKind({ message: errorMessage(error) })
        if (retryKind === 'transient') throw new SubagentCodexTransientError(error)
        if (retryKind !== 'unknown_session' || newThreadRetries >= 1) throw error
        newThreadRetries += 1
        recreatedThreadDuringSetup = true
        runtimeThreadID = undefined
      }
    }

    if (!runtimeThreadID) await startNewThread()

    const running = await updateStatus({
      request_id: `subagent-running-${crypto.randomUUID()}`,
      turn: turnStart.turn,
      delegation_id: delegationID,
      status: 'running',
      runtime_thread_id: runtimeThreadID,
      metadata: {
        codex_account_id: initial.codex_account_id,
        codex_user_agent: stringValue(initializeResponse.userAgent),
        browser_execution_scope: executionScopeID,
        projected_tool_names: projection.dynamicTools.map(tool => tool.name),
        quarantined_tool_names: projection.quarantinedTools,
        shared_skill_count: runtimeFiles.expectedSkillNames.length
      }
    })
    assertRPCResponse<SubagentDelegationResponse>(running, 'subagent running status rejected')

    const initialTurnInput = turnInput(turnStart, initial)
    await startCodexTurn(
      recreatedThreadDuringSetup ? recreatedThreadInput(initial, initialTurnInput) : initialTurnInput
    )

    if (isDeepResearch && researchPolicy) {
      researchWallclockTimer = setTimeout(() => void forceResearchSubmission(), researchPolicy.wallclockBudgetMs)
      researchWallclockTimer.unref?.()
    }

    steerTimer = setInterval(() => {
      if (steerInFlight || finalizing || recoveryInFlight || !client || !runtimeThreadID || !codexTurnID) return
      const updates = opts.pollSteering?.() ?? []
      if (updates.length === 0) return
      steerInFlight = true
      void steerActiveTurn(
        client,
        runtimeThreadID,
        codexTurnID,
        updates,
        () => !finalizing,
        (eventID, text) => turnRecorder.recordSteering(codexTurnID, eventID, text),
        opts.onSteeringApplied
      )
        .catch(error => {
          if (finalizing) return
          finalizing = true
          rejectDone(error instanceof Error ? error : new Error(String(error)))
        })
        .finally(() => {
          steerInFlight = false
        })
    }, steerPollIntervalMs)
    steerTimer.unref?.()

    await done
    turnResult = { kind: 'noop_completed', reason: 'subagent_delegation_committed' }
  } catch (caughtError) {
    finalizing = true
    let error = caughtError
    turnRecorder.finishTurn(codexTurnID, 'failed', {
      code: 'subagent_runtime_exception',
      summary: errorMessage(error)
    })
    try {
      await turnRecorder.flush()
    } catch (trajectoryError) {
      error = trajectoryError
    }
    thrownError = error
    hasThrownError = true
  }

  if (steerTimer) clearInterval(steerTimer)
  if (researchWallclockTimer) clearTimeout(researchWallclockTimer)
  if (researchGraceTimer) clearTimeout(researchGraceTimer)
  opts.abortSignal?.removeEventListener('abort', onAbort)
  closing = true

  try {
    await client?.close()
  } catch (error) {
    if (!hasThrownError) {
      thrownError = error
      hasThrownError = true
    }
  }

  try {
    runtimeFiles.cleanup()
  } catch (error) {
    if (!hasThrownError) {
      thrownError = error
      hasThrownError = true
    }
  }

  try {
    if (runtimeConfig.mode === 'official_subscription' && !authReconcilePromise) {
      await reconcileCodexAuth()
    }
  } catch (error) {
    if (!hasThrownError) {
      thrownError = error
      hasThrownError = true
    }
  }

  try {
    await turnRecorder.flush()
  } catch (error) {
    if (!hasThrownError) {
      thrownError = error
      hasThrownError = true
    }
  }

  if (hasThrownError) throw thrownError

  if (!turnResult) {
    throw new Error('subagent turn ended without a result')
  }

  return turnResult
}

async function configureCodexSkills(
  client: CodexAppServerClient,
  cwd: string,
  expectedSkillNames: string[]
): Promise<string[]> {
  await client.request('skills/extraRoots/set', { extraRoots: [SUBAGENT_SKILLS_SANDBOX_ROOT] })
  const response = jsonObject(
    await client.request('skills/list', {
      cwds: [cwd],
      forceReload: true
    })
  )
  const entries = Array.isArray(response.data) ? response.data.map(jsonObject) : []
  const entry = entries.find(candidate => stringValue(candidate.cwd) === cwd) ?? entries[0]
  if (!entry) {
    if (expectedSkillNames.length === 0) return []
    throw new Error(`Codex skills/list returned no entry for ${cwd}`)
  }

  const errors = Array.isArray(entry.errors) ? entry.errors.map(jsonObject) : []
  if (errors.length > 0) {
    const summaries = errors
      .map(error => [stringValue(error.path), stringValue(error.message)].filter(Boolean).join(': '))
      .filter(Boolean)
    throw new Error(`Codex skill discovery failed: ${summaries.join('; ') || 'unknown skill error'}`)
  }

  const discovered = Array.isArray(entry.skills)
    ? entry.skills
        .map(jsonObject)
        .filter(skill => skill.enabled !== false)
        .map(skill => stringValue(skill.name))
        .filter((name): name is string => Boolean(name))
        .sort()
    : []
  const names = new Set(discovered)
  const missing = expectedSkillNames.filter(name => !names.has(name))
  if (missing.length > 0) throw new Error(`Codex did not discover enabled skills: ${missing.join(', ')}`)
  return discovered
}

async function writebackCodexAuth(input: {
  turnStart: TurnStart
  delegationID: string
  authPath?: string
  initialAuthHash?: string
  update: TextTurnLoopOptions['updateCodexAccountAuth']
}): Promise<JSONObject> {
  if (!input.authPath || !input.initialAuthHash) throw new Error('Codex account auth was not materialized')
  const authJSON = readFileSync(input.authPath, 'utf8')
  const finalHash = genericHash(Buffer.from(authJSON))
  if (finalHash === input.initialAuthHash) return { changed: false, auth_hash: finalHash }

  const update = required(input.update, 'Codex account auth update')
  let lastError: unknown
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      const response = await update({
        request_id: `codex-account-auth-update-${crypto.randomUUID()}`,
        turn: input.turnStart.turn,
        delegation_id: input.delegationID,
        auth_json: authJSON
      })
      assertRPCResponse<CodexAccountAuthUpdateResponse>(response, 'Codex account auth update rejected')
      return { changed: true, auth_hash: finalHash }
    } catch (error) {
      lastError = error
      if (attempt < 3) await Bun.sleep(50 * 2 ** (attempt - 1))
    }
  }
  throw lastError instanceof Error ? lastError : new Error(errorMessage(lastError))
}

function delegationIDFromTurn(turnStart: TurnStart): string {
  const fromContext = turnStart.request_context?.delegation_id
  if (typeof fromContext === 'string' && fromContext) return fromContext
  const sessionID = turnStart.turn.actor.session_id
  if (sessionID.startsWith('subagent:') && sessionID.length > 'subagent:'.length) {
    return sessionID.slice('subagent:'.length)
  }
  throw new Error('subagent turn is missing delegation id')
}

function turnInput(turnStart: TurnStart, delegation: SubagentDelegationResponse): string {
  let input: string

  if (turnStart.actor_event.type === 'command.steer') {
    const command = jsonObject(jsonObject(jsonObject(turnStart.actor_event.payload_json).data).command)
    const text = stringValue(command.argsText)
    const answers = jsonObject(command.answers)
    const answerText = Object.entries(answers)
      .map(([id, answer]) => `${id}: ${Array.isArray(answer) ? answer.join(', ') : String(answer)}`)
      .join('\n')
    const steering = [text, answerText ? `Answers to your questions:\n${answerText}` : undefined]
      .filter((line): line is string => Boolean(line))
      .join('\n\n')

    input = delegation.runtime_thread_id
      ? steering
      : `${appendRetrospectSource(delegation.task, delegation)}\n\nAdditional instructions from the caller:\n${steering}`.trim()
  } else if (delegation.attempts > 1 && delegation.runtime_thread_id) {
    input = 'Continue the delegated task. Re-check the acceptance criteria in the original task before finishing.'
  } else {
    input = appendRetrospectSource(delegation.task, delegation)
  }

  const pendingSteering = pendingSteeringInput(turnStart)
  return pendingSteering ? `${input}\n\nPending instructions for this delegation:\n${pendingSteering}`.trim() : input
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
      const answers = jsonObject(item.answers)
      const answerText = Object.entries(answers)
        .map(([id, answer]) => `${id}: ${Array.isArray(answer) ? answer.join(', ') : String(answer)}`)
        .join('\n')
      const instruction = [text, answerText ? `Answers:\n${answerText}` : undefined]
        .filter((line): line is string => Boolean(line))
        .join('\n')
      const eventID = stringValue(item.actor_event_id)
      return instruction ? `${eventID ? `[steer ${eventID}]\n` : ''}${instruction}` : ''
    })
    .filter(Boolean)
    .join('\n\n')
}

type CodexRetryKind = 'transient' | 'context_overflow' | 'unknown_session' | 'terminal'

function codexRetryKind(error: JSONObject): CodexRetryKind {
  const info = error.codexErrorInfo
  const infoName =
    typeof info === 'string'
      ? info
      : info && typeof info === 'object' && !Array.isArray(info)
        ? Object.keys(info)[0]
        : undefined
  if (infoName === 'contextWindowExceeded') return 'context_overflow'
  if (
    [
      'serverOverloaded',
      'internalServerError',
      'httpConnectionFailed',
      'responseStreamConnectionFailed',
      'responseStreamDisconnected',
      'responseTooManyFailedAttempts'
    ].includes(infoName ?? '')
  ) {
    return 'transient'
  }
  if (infoName && infoName !== 'other') return 'terminal'

  const message = `${stringValue(error.message) ?? ''} ${stringValue(error.additionalDetails) ?? ''}`.toLowerCase()
  if (/unknown[-_ ]?(session|thread)|thread .*not found|no rollout found/.test(message)) return 'unknown_session'
  if (/context window|context length|too many tokens/.test(message)) return 'context_overflow'
  if (
    /stream (?:disconnected|closed)(?: before completion)?|response stream .*?(?:disconnected|closed)|http(?: status)?[\s:]+(?:502|503|504)\b|model at capacity|systemerror|server overloaded|temporarily unavailable|error -32001/.test(
      message
    )
  ) {
    return 'transient'
  }
  return 'terminal'
}

function retryContinuationInput(): string {
  return 'Continue the delegated task after the transient runtime error. Inspect the current workspace before repeating any side effect, then re-check the original acceptance criteria.'
}

function recreatedThreadInput(delegation: SubagentDelegationResponse, continuation: string): string {
  const priorAttempts = delegation.attempt_history?.length
    ? `\n\nBounded history from prior execution attempts:\n${JSON.stringify(delegation.attempt_history, null, 2)}`
    : ''
  const task = appendRetrospectSource(delegation.task, delegation)
  return `${task}\n\nThe previous Codex thread could not be resumed. Inspect the existing working directory and continue from durable artifacts.${priorAttempts}\n\nCurrent continuation instructions:\n${continuation}\n\nRe-check every acceptance criterion before finishing.`.trim()
}

function appendRetrospectSource(task: string, delegation: SubagentDelegationResponse): string {
  if (delegation.runtime !== 'deep_research' || delegation.mode !== 'retrospect' || !delegation.source_forecast) {
    return task
  }
  const outcome =
    delegation.actual_outcome === undefined
      ? 'Resolve the actual outcome from the stored resolution rule and current evidence.'
      : `The resolved actual outcome is ${delegation.actual_outcome}.`
  return `${task}\n\nAuthoritative source forecast (do not replace it with a new forecast):\n${JSON.stringify(delegation.source_forecast, null, 2)}\n\n${outcome}`
}

async function steerActiveTurn(
  client: CodexAppServerClient,
  threadID: string,
  turnID: string,
  updates: TurnSteerUpdate[],
  acceptsOutcome: () => boolean,
  onTrajectorySteering: (eventID: string, text: string) => void,
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
      onTrajectorySteering(event.actor_event_id, text)
      await onSteeringApplied?.(update)
    } catch (error) {
      if (!acceptsOutcome()) continue
      if (!isSteerCompletionRace(error)) throw new SubagentSteerDeliveryError(error)
    }
  }
}

function isSteerCompletionRace(error: unknown): boolean {
  return /(?:turn\s+)?already (?:completed|finished)|turn .* (?:has )?(?:completed|finished)/i.test(errorMessage(error))
}

class SubagentCodexTransientError extends Error {
  readonly code = 'subagent_codex_transient'
  readonly retryable = true

  constructor(cause: unknown) {
    super(
      `Codex transient runtime failure requires durable retry: ${stringValue(jsonObject(cause).message) ?? errorMessage(cause)}`,
      { cause: cause instanceof Error ? cause : undefined }
    )
    this.name = 'SubagentCodexTransientError'
  }
}

class SubagentSteerDeliveryError extends Error {
  readonly code = 'subagent_steer_delivery_failed'
  readonly retryable = true

  constructor(cause: unknown) {
    super(`Subagent steer delivery failed: ${errorMessage(cause)}`, {
      cause: cause instanceof Error ? cause : undefined
    })
    this.name = 'SubagentSteerDeliveryError'
  }
}

class SubagentPendingSteerError extends Error {
  readonly code = 'subagent_pending_steer'
  readonly retryable = true

  constructor(cause: unknown) {
    super(`Subagent terminal commit deferred for pending steering: ${errorMessage(cause)}`, {
      cause: cause instanceof Error ? cause : undefined
    })
    this.name = 'SubagentPendingSteerError'
  }
}

function abortReason(signal?: AbortSignal): string {
  if (!signal?.aborted) return 'stopped'
  return signal.reason instanceof Error ? signal.reason.message : String(signal.reason ?? 'stopped')
}

function optionalJSONObject(value: unknown): JSONObject | undefined {
  const object = jsonObject(value)
  return Object.keys(object).length > 0 ? object : undefined
}

function required<T>(value: T | undefined, label: string): T {
  if (!value) throw new Error(`${label} RPC is not configured`)
  return value
}

async function requestProjectionAIGatewayKey(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions,
  options?: { forceRefresh?: boolean }
): Promise<AIGatewayAPIKeyResponse> {
  const response = await opts.requestAIGatewayAPIKey(
    {
      request_id: `subagent-projection-key-${crypto.randomUUID()}`,
      agent_uid: turnStart.turn.actor.agent_uid
    },
    options
  )
  assertRPCResponse<AIGatewayAPIKeyResponse>(response, 'subagent projection AIGateway key rejected')
  return response
}
