import { jsonObject, type JsonObject as JSONObject } from '@agentbull/active-support'
import { errorMessage, toError } from '../../../common/errors'
import { compareCodePointStrings } from '../../../common/ordering'
import { jsonBytes } from '../../../fabric/envelope-proto'
import type { BackgroundAgentJobResponse } from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { isRuntimeFabricTransportError } from '../../../fabric/fabric'
import type { RPCRequestInit } from '../../../lanes/rpc-contract'
import { RPCTimeoutError } from '../../../lanes/rpc-lane'
import type { JobTurnRef } from '../../../lanes/session-lane'
import type { BackgroundAgentJobStatus, BackgroundAgentJobTurnUsage } from '../../background-agent-job-documents'
import type { DynamicToolCallParams } from '../generated/protocol/v2/DynamicToolCallParams'
import type { CodexJobOptions } from '../options'
import { approvalAcceptance, approvalRequestMethod, stringValue, textInput } from '../protocol'
import type { CodexAIGatewayModelProfile } from '../runtime-config'
import type { AgentCodexRuntimeLease, AgentCodexRuntimeSession } from '../runtime/agent-runtime-manager'
import { CodexAppServerRPCError, type CodexAppServerClient, type JSONRPCMessage } from '../runtime/app-server-client'
import {
  hasIncompatibleContinuationRuntime,
  materializeJobExecutionLogfile,
  type MaterializedExecutionLog,
  type ThreadRecreateReason
} from './execution-logfile'
import { PARENT_INPUT_TOOL_NAME, pendingParentInputFromDynamicTool } from './parent-input'
import { classifyCodexRecoveryFailure, transitionCodexRecovery, type CodexRecoveryState } from './recovery-policy'
import { durableRetryError, fetchContinuationSourceContext, type ContinuationSourceContext } from './session-support'
import type { PreparedCodexJobExecution } from './setup'
import type { CodexSkillUsageTracker } from './skill-usage'
import type { BackgroundAgentJobTurnRecorder } from './turn-recorder'

export async function publishRunningJobStatus(input: {
  rpc: CodexJobOptions['rpc']
  jobTurn: JobTurnRef
  jobID: string
  runtimeThreadID: string
  initializeResponse: JSONObject
  prepared: PreparedCodexJobExecution
  processID: number | undefined
  compactionSeq: number
  recreatedThreadOnResume: boolean
  recreatedThreadReason?: ThreadRecreateReason | undefined
  expectedSkillCount: number
}): Promise<void> {
  const {
    rpc,
    jobTurn,
    jobID,
    runtimeThreadID,
    initializeResponse,
    prepared,
    processID,
    compactionSeq,
    recreatedThreadOnResume,
    recreatedThreadReason,
    expectedSkillCount
  } = input
  const { projection, project, skills } = prepared
  const threadFeatures = jsonObject(prepared.threadConfig.features)
  await rpc(
    'background_agent_job.status.update',
    {
      jobId: jobID,
      status: 'running',
      runtimeThreadId: runtimeThreadID,
      metadataJson: jsonBytes({
        paused_at: null,
        codex_user_agent: stringValue(initializeResponse.userAgent),
        job_project_cwd: project.root,
        job_workspace: project.root,
        codex_app_server_pid: processID,
        cli_compaction_seq: compactionSeq,
        mcp_server_names: skills.mcpServers.map(server => server.name).sort(compareCodePointStrings),
        ...(recreatedThreadOnResume
          ? {
              runtime_checkpoint_recreated: true,
              runtime_checkpoint_recovery: 'new_thread_from_logfile',
              ...(recreatedThreadReason ? { runtime_thread_recreated_reason: recreatedThreadReason } : {})
            }
          : {}),
        projected_tool_names: projection.dynamicTools.map(tool => tool.name),
        quarantined_tool_names: projection.quarantinedTools,
        child_dynamic_tools_inherited: threadFeatures.multi_agent_v2_dynamic_tools === true,
        code_mode: jsonObject(threadFeatures.code_mode).enabled === true,
        shared_skill_count: expectedSkillCount
      })
    },
    { jobTurn }
  )
}

export async function persistRuntimeThreadAnchor(input: {
  rpc: CodexJobOptions['rpc']
  jobTurn: JobTurnRef
  jobID: string
  runtimeThreadID: string
  reason: string
  recovery?: string
}): Promise<void> {
  await input.rpc(
    'background_agent_job.status.update',
    {
      jobId: input.jobID,
      status: 'running',
      runtimeThreadId: input.runtimeThreadID,
      metadataJson: jsonBytes({
        runtime_thread_recreated_reason: input.reason,
        ...(input.recovery ? { runtime_checkpoint_recovery: input.recovery } : {})
      })
    },
    { jobTurn: input.jobTurn }
  )
}

export async function commitJobStatusWithAck(
  rpc: CodexJobOptions['rpc'],
  request: RPCRequestInit<'background_agent_job.status.update'>,
  jobTurn: JobTurnRef
): Promise<void> {
  for (;;) {
    try {
      await rpc('background_agent_job.status.update', request, { jobTurn })
      return
    } catch (error) {
      if (
        !(error instanceof RPCTimeoutError) &&
        !(isRuntimeFabricTransportError(error) && ['socket_closed', 'timeout'].includes(error.code))
      ) {
        throw error
      }
      await Bun.sleep(100)
    }
  }
}

export function shouldRecycleColdIdleThread(
  initialJobMetadata: JSONObject | undefined,
  opts: CodexJobOptions
): boolean {
  const pausedAtRaw = stringValue(initialJobMetadata?.paused_at)
  if (!pausedAtRaw) return false
  const pausedMs = Date.parse(pausedAtRaw)
  if (!Number.isFinite(pausedMs)) return false
  const idleMs = Date.now() - pausedMs
  const minIdleMs = opts.coldIdleRecycleMs ?? 10 * 60_000
  if (idleMs < minIdleMs) return false

  const usage = jsonObject(initialJobMetadata?.latest_token_usage)
  const lastCallTokens = Number(jsonObject(usage.last_model_call).total_tokens ?? 0)
  const contextTokens = Number.isFinite(lastCallTokens) ? lastCallTokens : 0
  const minTokens = opts.coldIdleMinTokens ?? 128_000
  return contextTokens >= minTokens
}

export async function resumeAndInjectCodexRootThread(input: {
  runtimeLease: { runtime: Pick<AgentCodexRuntimeLease['runtime'], 'resumeRoot'> }
  client: Pick<CodexAppServerClient, 'request'>
  session: AgentCodexRuntimeSession
  resumedThreadID: string
  savedJobThreadID: string
  prepared: PreparedCodexJobExecution
  model: string
}): Promise<void> {
  const { runtimeLease, client, session, resumedThreadID, savedJobThreadID, prepared, model } = input
  await runtimeLease.runtime.resumeRoot(resumedThreadID, session, async () => {
    await client.request('thread/resume', {
      ['threadId']: resumedThreadID,
      ...(prepared.resumePath && resumedThreadID === savedJobThreadID ? { path: prepared.resumePath } : {}),
      cwd: prepared.project.root,
      runtimeWorkspaceRoots: [prepared.project.root],
      approvalPolicy: 'never',
      sandbox: 'danger-full-access',
      modelProvider: 'ankole_aigateway',
      config: prepared.threadConfig,
      model
    })
  })
  // Resume keeps the recorded initial instructions. Add the current drive
  // rules to the native transcript before the next turn.
  await client.request('thread/inject_items', {
    ['threadId']: resumedThreadID,
    items: [
      {
        type: 'message',
        role: 'developer',
        content: [{ type: 'input_text', text: prepared.threadConfig.developer_instructions }]
      }
    ]
  })
}

export type ResumeCodexThreadResult =
  | { outcome: 'none' }
  | { outcome: 'resumed' }
  | {
      outcome: 'recreated'
      reason: ThreadRecreateReason
      source: ContinuationSourceContext | undefined
      logfile: MaterializedExecutionLog
    }

export async function resumeExistingCodexRootThread(input: {
  runtimeLease: { runtime: Pick<AgentCodexRuntimeLease['runtime'], 'resumeRoot'> } | undefined
  client: Pick<CodexAppServerClient, 'request'> | undefined
  session: AgentCodexRuntimeSession
  runtimeThreadID: string | undefined
  jobID: string
  job: BackgroundAgentJobResponse
  jobTurn: JobTurnRef
  initialJobMetadata: JSONObject | undefined
  prepared: PreparedCodexJobExecution
  model: string
  recoveryState: CodexRecoveryState
  opts: CodexJobOptions
  setRecoveryState: (state: CodexRecoveryState) => void
  publishCliContextId: () => void
  replaceLostThread: (
    reason: ThreadRecreateReason,
    retireThreadID?: string
  ) => Promise<Extract<ResumeCodexThreadResult, { outcome: 'recreated' }>>
}): Promise<ResumeCodexThreadResult> {
  const {
    runtimeLease,
    client,
    session,
    runtimeThreadID,
    jobID,
    job,
    jobTurn,
    initialJobMetadata,
    prepared,
    model,
    opts
  } = input
  if (!client || !runtimeLease) return { outcome: 'none' }
  if (!runtimeThreadID) {
    return job.continuedFromJobId ? input.replaceLostThread('continuation_without_thread') : { outcome: 'none' }
  }
  if (prepared.workspaceRecreated) {
    opts.logger?.info(
      'worker.codex_job_workspace_evicted',
      'Starting a replacement Codex Job thread because the inherited Job workspace was recreated',
      { job_id: jobID, thread_id: runtimeThreadID }
    )
    return input.replaceLostThread('workspace_evicted', runtimeThreadID)
  }
  if (job.continuedFromJobId) {
    const incompatible = await hasIncompatibleContinuationRuntime({
      rpc: opts.rpc,
      jobTurn,
      jobID,
      sourceJobID: job.continuedFromJobId,
      runtimeThreadID,
      currentJob: job,
      abortSignal: opts.abortSignal,
      logger: opts.logger
    })
    if (incompatible) {
      opts.logger?.info(
        'worker.codex_job_respawn_runtime_incompatible',
        'Starting a replacement Codex Job thread because the respawned Job switched model bindings',
        { job_id: jobID, source_job_id: job.continuedFromJobId, thread_id: runtimeThreadID }
      )
      return input.replaceLostThread('respawn_runtime_incompatible', runtimeThreadID)
    }
  }
  if (shouldRecycleColdIdleThread(initialJobMetadata, opts)) {
    opts.logger?.info(
      'worker.codex_job_cold_idle_recycle',
      'Recycling cold large Codex Job thread instead of replaying an uncached transcript',
      { job_id: jobID, thread_id: runtimeThreadID }
    )
    return input.replaceLostThread('cold_idle_recycle', runtimeThreadID)
  }
  try {
    await resumeAndInjectCodexRootThread({
      runtimeLease,
      client,
      session,
      resumedThreadID: runtimeThreadID,
      savedJobThreadID: job.runtimeThreadId,
      prepared,
      model
    })
    input.publishCliContextId()
    return { outcome: 'resumed' }
  } catch (error) {
    const decision = transitionCodexRecovery({
      stage: 'resume',
      failure: classifyCodexRecoveryFailure(
        error instanceof CodexAppServerRPCError ? error.details : { message: errorMessage(error) }
      ),
      state: input.recoveryState
    })
    input.setRecoveryState(decision.nextState)
    if (decision.action === 'durable_retry') {
      throw durableRetryError(
        error instanceof CodexAppServerRPCError ? error.details : { message: errorMessage(error) }
      )
    }
    if (decision.action !== 'replace_thread') throw error
    return input.replaceLostThread('resume_failed', runtimeThreadID)
  }
}

export async function prepareReplacementCodexRootThread(input: {
  runtimeLease: AgentCodexRuntimeLease | undefined
  session: AgentCodexRuntimeSession
  jobTurn: JobTurnRef
  jobID: string
  continuedFromJobID: string | undefined
  projectRoot: string
  reason: ThreadRecreateReason
  retireThreadID?: string | undefined
  opts: CodexJobOptions
  startNewThread: () => Promise<void>
}): Promise<Extract<ResumeCodexThreadResult, { outcome: 'recreated' }>> {
  const [source, logfile] = await Promise.all([
    input.continuedFromJobID
      ? fetchContinuationSourceContext({
          rpc: input.opts.rpc,
          jobTurn: input.jobTurn,
          jobID: input.jobID,
          sourceJobID: input.continuedFromJobID,
          abortSignal: input.opts.abortSignal,
          logger: input.opts.logger
        })
      : Promise.resolve(undefined),
    materializeJobExecutionLogfile({
      rpc: input.opts.rpc,
      jobTurn: input.jobTurn,
      jobID: input.jobID,
      projectRoot: input.projectRoot,
      reason: input.reason,
      abortSignal: input.opts.abortSignal,
      logger: input.opts.logger
    })
  ])
  if (input.retireThreadID && input.runtimeLease) {
    await input.runtimeLease.runtime.retireRoot(input.retireThreadID, input.session)
  }
  await input.startNewThread()
  return { outcome: 'recreated', reason: input.reason, source, logfile }
}

export async function replaceCodexThreadAndStartTurn(input: {
  isStopping: () => boolean
  flushTurnRecorder: () => Promise<void>
  previousThreadID: string | undefined
  replaceThreadAndPrepareHistory: (
    reason: ThreadRecreateReason,
    retireThreadID?: string
  ) => Promise<Extract<ResumeCodexThreadResult, { outcome: 'recreated' }>>
  currentThreadID: () => string | undefined
  rpc: CodexJobOptions['rpc']
  jobTurn: JobTurnRef
  jobID: string
  reason: ThreadRecreateReason
  buildPrompt: (
    source: Extract<ResumeCodexThreadResult, { outcome: 'recreated' }>['source'],
    logfile: Extract<ResumeCodexThreadResult, { outcome: 'recreated' }>['logfile']
  ) => string
  startCodexTurn: (prompt: string) => Promise<void>
  retireFailedReplacement: (threadID: string) => Promise<void>
}): Promise<void> {
  if (input.isStopping()) return
  await input.flushTurnRecorder()
  if (input.isStopping()) return
  const { source, logfile } = await input.replaceThreadAndPrepareHistory(input.reason, input.previousThreadID)
  if (input.isStopping()) return
  const newThreadID = input.currentThreadID()
  if (!newThreadID) throw new Error('codex thread is not available for persistence')
  await persistRuntimeThreadAnchor({
    rpc: input.rpc,
    jobTurn: input.jobTurn,
    jobID: input.jobID,
    runtimeThreadID: newThreadID,
    reason: input.reason,
    recovery: 'new_thread_from_logfile'
  })
  if (input.isStopping()) return
  try {
    await input.startCodexTurn(input.buildPrompt(source, logfile))
  } catch (error) {
    await input.retireFailedReplacement(newThreadID)
    throw error
  }
}

export async function startNewCodexRootThread(input: {
  runtimeLease: AgentCodexRuntimeLease
  client: CodexAppServerClient
  session: AgentCodexRuntimeSession
  prepared: PreparedCodexJobExecution
  model: string
}): Promise<string> {
  const { runtimeLease, client, session, prepared, model } = input
  const started = jsonObject(
    await client.request('thread/start', {
      cwd: prepared.project.root,
      runtimeWorkspaceRoots: [prepared.project.root],
      experimentalRawEvents: true,
      approvalPolicy: 'never',
      sandbox: 'danger-full-access',
      modelProvider: 'ankole_aigateway',
      config: prepared.threadConfig,
      developerInstructions: stringValue(prepared.threadConfig.developer_instructions),
      threadSource: 'ankole',
      dynamicTools: prepared.projection.dynamicTools,
      model
    })
  )
  const runtimeThreadID = stringValue(jsonObject(started.thread).id)
  if (!runtimeThreadID) throw new Error('codex app-server did not return a thread id')
  await runtimeLease.runtime.registerRoot(runtimeThreadID, session)
  return runtimeThreadID
}

export async function startCodexTurnOnThread(input: {
  client: CodexAppServerClient
  runtimeThreadID: string
  projectRoot: string
  modelProfile: CodexAIGatewayModelProfile
  prompt: string
  clientUserMessageID?: string
}): Promise<JSONObject> {
  const { client, runtimeThreadID, projectRoot, modelProfile, prompt, clientUserMessageID } = input
  const startedTurn = jsonObject(
    await client.request('turn/start', {
      ['threadId']: runtimeThreadID,
      ...(clientUserMessageID ? { ['clientUserMessageId']: clientUserMessageID } : {}),
      input: textInput(prompt),
      cwd: projectRoot,
      runtimeWorkspaceRoots: [projectRoot],
      approvalPolicy: 'never',
      sandboxPolicy: { type: 'dangerFullAccess' },
      model: modelProfile.model,
      ...(modelProfile.modelReasoningEffort ? { effort: modelProfile.modelReasoningEffort } : {})
    })
  )
  return jsonObject(startedTurn.turn)
}

export async function dispatchRuntimeServerRequest(input: {
  message: JSONRPCMessage
  appServer: CodexAppServerClient
  acceptingServerRequests: boolean
  finalizing: boolean
  runtimeThreadID: string | undefined
  codexTurnID: string | undefined
  compactionSeq: number
  latestTokenUsage: BackgroundAgentJobTurnUsage | undefined
  prepared: PreparedCodexJobExecution
  skillUsage: CodexSkillUsageTracker
  turnRecorder: BackgroundAgentJobTurnRecorder
  toolAbortSignal: AbortSignal
  noteLeadRuntimeProgress: () => void
  recordUsedSkills: (names: string[]) => void
  setWaitingOnUserInput: (waiting: boolean) => void
  claimFinalization: () => boolean
  interruptTurn: (threadID?: string, turnID?: string) => Promise<void>
  scheduleClaimedCommit: (
    status: BackgroundAgentJobStatus,
    details: { result?: JSONObject; error?: JSONObject; metadata?: JSONObject }
  ) => void
  rejectDone: (error: Error) => void
}): Promise<void> {
  const { message, appServer } = input
  if (!input.acceptingServerRequests || input.finalizing) {
    if (message.id !== undefined) {
      await appServer.respondError(message.id, -32001, 'Background agent Job is cleaning up')
    }
    return
  }
  const method = typeof message.method === 'string' ? message.method : ''
  if (message.id === undefined) return
  const params = jsonObject(message.params)
  const requestThreadID = stringValue(params.threadId)
  const isLeadRequest = !requestThreadID || requestThreadID === input.runtimeThreadID
  if (isLeadRequest) input.noteLeadRuntimeProgress()

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
    const requestTurnID = stringValue(pending.turnId) ?? input.codexTurnID
    input.turnRecorder.recordRequestUserInput(requestTurnID, pending, message.id)
    input.setWaitingOnUserInput(true)
    if (!input.claimFinalization()) {
      await appServer.respondError(message.id, -32001, 'Background agent Job is already finalizing')
      return
    }
    try {
      if (requestThreadID && requestTurnID) {
        await input.interruptTurn(requestThreadID, requestTurnID).catch(() => undefined)
        input.turnRecorder.interruptTurn(requestTurnID, {
          code: 'request_user_input',
          summary: 'Codex requested user input.'
        })
      } else {
        await input.interruptTurn().catch(() => undefined)
      }
      await appServer.respondError(message.id, -32002, 'Background agent Job is waiting for parent input')
      input.scheduleClaimedCommit('waiting_on_user', {
        metadata: {
          pending_user_input: pending,
          paused_at: new Date().toISOString(),
          cli_compaction_seq: input.compactionSeq,
          ...(input.latestTokenUsage ? { latest_token_usage: input.latestTokenUsage } : {})
        }
      })
    } catch (error) {
      input.setWaitingOnUserInput(false)
      input.rejectDone(toError(error))
    }
    return
  }

  if (method === 'item/tool/call') {
    try {
      const response = await input.prepared.projection.handleToolCall(
        message.params as DynamicToolCallParams,
        input.toolAbortSignal
      )
      for (const name of input.prepared.skills.takeLoadedNames()) {
        input.recordUsedSkills(input.skillUsage.recordLoaded(name))
      }
      await appServer.respond(message.id, response)
    } catch (error) {
      await appServer.respondError(
        message.id,
        input.toolAbortSignal.aborted ? -32001 : -32603,
        input.toolAbortSignal.aborted
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
  if (!input.claimFinalization()) return
  await input.interruptTurn().catch(() => undefined)
  input.scheduleClaimedCommit('failed', {
    error: {
      code: 'unsupported_server_request',
      summary: `Unsupported Codex server request: ${method}`
    }
  })
}
