import { jsonObject, type JsonObject } from '@pleisto/active-support'
import { mkdirSync } from 'node:fs'
import { dirname, relative } from 'node:path'
import { errorMessage } from '../../common/errors'
import type { TurnStart, TurnSteerUpdate } from '../../lanes/actor_lane'
import {
  assertRpcResponse,
  type AIGatewayApiKeyResponse,
  type SubagentDelegationResponse,
  type SubagentDelegationStatus
} from '../../lanes/rpc_lane'
import { prepareActorWorkspace } from '../../worker/workspace'
import { CodexAppServerClient, type JsonRpcMessage } from '../../tools/codex/app-server-client'
import { materializeCodexConfig } from '../../tools/codex/config'
import {
  approvalRejection,
  approvalRequestMethod,
  projectCodexNotification,
  stringValue,
  textInput
} from '../../tools/codex/protocol'
import { resolveCodexRuntimeConfig } from '../../tools/codex/runtime-config'
import { codexAppServerSandboxSpec, resolveCodexWorkdir } from '../../tools/codex/sandbox'
import { SubagentAuditBuffer } from '../../tools/subagent/audit'
import { buildSubagentProjection } from '../../tools/subagent/dynamic-tools'
import type { DynamicToolCallParams } from '../../tools/subagent/generated/protocol/v2/DynamicToolCallParams'
import { createSkillTools } from '../../tools/library/skill-tools'
import { createMemoryTools } from '../../tools/memory/memory-tools'
import { createWebTools } from '../../tools/web/web-tools'
import { httpClientFromAIGatewayApiKey } from '../aigateway_transport'
import { resolveAgentConversationContext } from './turn_context'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'

const terminalStatuses = new Set<SubagentDelegationStatus>(['succeeded', 'failed', 'stopped'])
const steerPollIntervalMs = 250

export async function runSubagentTurn(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<TurnHandlerResult> {
  const delegationId = delegationIdFromTurn(turnStart)
  const getDelegation = required(opts.getSubagentDelegation, 'subagent get')
  const updateStatus = required(opts.updateSubagentDelegationStatus, 'subagent status update')
  const initial = await getDelegation({
    request_id: `subagent-get-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    delegation_id: delegationId
  })
  assertRpcResponse<SubagentDelegationResponse>(initial, 'subagent delegation get rejected')

  if (terminalStatuses.has(initial.status)) {
    return { kind: 'noop_completed', reason: `subagent_${initial.status}` }
  }

  if (!opts.workspaceSessionsRoot || !opts.userFilesRoot) {
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
    agentUid: initial.agent_uid,
    requesters: opts
  })
  const materialized = materializeCodexConfig({
    workspaceRoot: parentWorkspaceRoot,
    delegationId,
    override: runtimeConfig.override,
    aiGatewayKey: runtimeConfig.aiGatewayKey
  })
  const sandbox = codexAppServerSandboxSpec({
    workspaceRoot: parentWorkspaceRoot,
    workdir,
    materialized
  })
  const audit = new SubagentAuditBuffer({
    delegationId,
    turn: turnStart.turn,
    append: opts.appendSubagentDelegationEvents,
    nextSeq: (initial.last_event_seq ?? -1) + 1
  })
  const projectionApiKey = runtimeConfig.aiGatewayKey ?? (await requestProjectionAIGatewayKey(turnStart, opts))
  const projectionAIGateway = httpClientFromAIGatewayApiKey(projectionApiKey, options =>
    requestProjectionAIGatewayKey(turnStart, opts, options)
  )
  const projectedTools = [
    ...createSkillTools(parentWorkspaceRoot, {
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
      replaceSkillOverlay: opts.replaceSkillOverlay
    }),
    ...(await createWebTools({ aiGateway: projectionAIGateway, abortSignal: opts.abortSignal })),
    ...createMemoryTools({
      turnStart,
      requestMemoryRpc: opts.requestMemoryRpc
        ? (method, request) =>
            opts.requestMemoryRpc!(method, {
              ...request,
              delegation_id: delegationId,
              delegation_scope: {
                session_id: initial.session_id,
                signal_channel_id: stringValue(initial.reply_route.signal_channel_id)
              }
            })
        : undefined
    })
  ].filter(tool => ['skill_view', 'web_search', 'memory_search', 'memory_browse'].includes(tool.name))
  const projection = buildSubagentProjection({
    tools: projectedTools,
    skills: agentContext.skills ?? [],
    soul: agentContext.soul ?? '',
    mission: agentContext.mission ?? '',
    onAudit: (eventType, payload) => audit.enqueue('tool', eventType, payload)
  })

  let client: CodexAppServerClient | undefined
  let runtimeThreadId = initial.runtime_thread_id
  let codexTurnId: string | undefined
  let outputText = ''
  let latestTokenUsage: JsonObject = {}
  let latestDiff = ''
  let finalizing = false
  let waitingOnUserInput = false
  let recoveryInFlight = false
  let transientRetries = 0
  let compactRetries = 0
  let newThreadRetries = 0
  let recreatedThreadDuringSetup = false
  let closing = false
  let steerTimer: ReturnType<typeof setInterval> | undefined
  let steerInFlight = false
  let resolveCompaction: (() => void) | undefined
  let rejectCompaction: ((error: Error) => void) | undefined
  let compactingThreadId: string | undefined
  let compactionTurnId: string | undefined
  const completedCompactionTurnIds = new Set<string>()
  let resolveDone!: () => void
  let rejectDone!: (error: Error) => void
  const done = new Promise<void>((resolve, reject) => {
    resolveDone = resolve
    rejectDone = reject
  })

  const commit = async (
    status: SubagentDelegationStatus,
    details: { result?: JsonObject; error?: JsonObject; metadata?: JsonObject } = {}
  ): Promise<void> => {
    if (finalizing) return
    finalizing = true
    try {
      audit.enqueue('audit', `status_${status}`, {
        status,
        ...(runtimeThreadId ? { runtime_thread_id: runtimeThreadId } : {}),
        ...details
      })
      await audit.flush()
      let committedStatus = status
      let committedDetails = details
      try {
        audit.throwIfFailed()
      } catch (error) {
        if (status !== 'stopped') {
          committedStatus = 'failed'
          committedDetails = {
            error: {
              code: 'audit_persistence_failed',
              summary: `Subagent audit persistence failed: ${errorMessage(error)}`
            }
          }
        }
      }
      const response = await updateStatus({
        request_id: `subagent-status-${crypto.randomUUID()}`,
        turn: turnStart.turn,
        delegation_id: delegationId,
        status: committedStatus,
        ...(runtimeThreadId ? { runtime_thread_id: runtimeThreadId } : {}),
        ...committedDetails
      })
      assertRpcResponse<SubagentDelegationResponse>(response, 'subagent status update rejected')
      resolveDone()
    } catch (error) {
      rejectDone(error instanceof Error ? error : new Error(String(error)))
    }
  }

  const interrupt = async (): Promise<void> => {
    if (!client || !runtimeThreadId || !codexTurnId) return
    await client.request('turn/interrupt', { threadId: runtimeThreadId, turnId: codexTurnId })
  }

  const startNewThread = async (): Promise<void> => {
    if (!client) throw new Error('codex app-server is not available')
    const started = jsonObject(
      await client.request('thread/start', {
        cwd: sandbox.codexCwd,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        threadSource: 'ankole',
        developerInstructions: projection.developerInstructions,
        dynamicTools: projection.dynamicTools,
        ...(runtimeConfig.modelOverride ? { model: runtimeConfig.modelOverride } : {})
      })
    )
    runtimeThreadId = stringValue(jsonObject(started.thread).id)
    if (!runtimeThreadId) throw new Error('codex app-server did not return a thread id')
    opts.onTurnActivity?.('codex:thread_started')
    audit.enqueue('process', 'thread_started', { thread_id: runtimeThreadId })
  }

  const startCodexTurn = async (input: string): Promise<void> => {
    if (!client || !runtimeThreadId) throw new Error('codex thread is not available')
    const startedTurn = jsonObject(
      await client.request('turn/start', {
        threadId: runtimeThreadId,
        input: textInput(input),
        cwd: sandbox.codexCwd,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' },
        ...(runtimeConfig.modelOverride ? { model: runtimeConfig.modelOverride } : {}),
        ...(jsonObject(initial.metadata).output_schema
          ? { outputSchema: jsonObject(initial.metadata).output_schema }
          : {})
      })
    )
    codexTurnId = stringValue(jsonObject(startedTurn.turn).id)
    if (!codexTurnId) throw new Error('codex app-server did not return a turn id')
    opts.onTurnActivity?.('codex:turn_started')
  }

  const compactThread = async (): Promise<void> => {
    if (!client || !runtimeThreadId) throw new Error('codex thread is not available for compaction')
    const compacted = new Promise<void>((resolve, reject) => {
      resolveCompaction = resolve
      rejectCompaction = reject
      compactingThreadId = runtimeThreadId
    })
    try {
      await client.request('thread/compact/start', { threadId: runtimeThreadId })
      await compacted
    } finally {
      resolveCompaction = undefined
      rejectCompaction = undefined
      compactingThreadId = undefined
      compactionTurnId = undefined
    }
  }

  const persistRuntimeThreadAnchor = async (reason: string): Promise<void> => {
    if (!runtimeThreadId) throw new Error('codex thread is not available for persistence')
    const response = await updateStatus({
      request_id: `subagent-thread-anchor-${crypto.randomUUID()}`,
      turn: turnStart.turn,
      delegation_id: delegationId,
      status: 'running',
      runtime_thread_id: runtimeThreadId,
      metadata: { runtime_thread_recreated_reason: reason }
    })
    assertRpcResponse<SubagentDelegationResponse>(response, 'subagent thread anchor update rejected')
  }

  const handleTurnCompleted = async (
    status: SubagentDelegationStatus,
    codexTurnStatus: string,
    error: JsonObject
  ): Promise<void> => {
    if (finalizing || waitingOnUserInput || recoveryInFlight) return

    if (status === 'succeeded') {
      await commit('succeeded', {
        result: {
          summary: outputText,
          output_text: outputText,
          codex_turn_status: codexTurnStatus,
          usage: latestTokenUsage,
          files_changed: filesChangedFromDiff(latestDiff)
        }
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

      if (retryKind === 'transient' && transientRetries < 3) {
        transientRetries += 1
        audit.enqueue('process', 'turn_retry', { kind: retryKind, attempt: transientRetries, error })
        await Bun.sleep(Math.min(250 * 2 ** (transientRetries - 1), 1_000))
        outputText = ''
        await startCodexTurn(retryContinuationInput())
        return
      }

      if (retryKind === 'context_overflow' && compactRetries < 1 && client && runtimeThreadId) {
        compactRetries += 1
        audit.enqueue('process', 'turn_compact_retry', { attempt: compactRetries, error })
        await compactThread()
        outputText = ''
        await startCodexTurn(retryContinuationInput())
        return
      }

      if (retryKind === 'unknown_session' && newThreadRetries < 1) {
        newThreadRetries += 1
        audit.enqueue('process', 'thread_recreated', { reason: 'unknown_session', error })
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

  const handleNotification = (message: JsonRpcMessage): void => {
    const projection = projectCodexNotification(message)
    opts.onTurnActivity?.(`codex:${projection.type}`)
    audit.enqueue(projection.type === 'stderr' ? 'process' : 'server_to_client', projection.type, jsonObject(message))

    if (message.method === 'item/completed') {
      const params = jsonObject(message.params)
      const item = jsonObject(params.item)
      if (item.type === 'contextCompaction' && stringValue(params.threadId) === compactingThreadId) {
        const completedTurnId = stringValue(params.turnId) ?? compactionTurnId
        if (completedTurnId) completedCompactionTurnIds.add(completedTurnId)
        resolveCompaction?.()
      }
    }

    if (projection.type === 'turn_started') {
      codexTurnId = projection.turnId ?? codexTurnId
      if (resolveCompaction && projection.turnId) compactionTurnId = projection.turnId
    } else if (projection.type === 'agent_delta') {
      outputText += projection.delta
    } else if (projection.type === 'token_usage') {
      latestTokenUsage = jsonObject(projection.usage.last)
    } else if (projection.type === 'turn_diff') {
      latestDiff = projection.diff
    } else if (projection.type === 'turn_completed' && !finalizing && !waitingOnUserInput) {
      const completedTurnId = stringValue(jsonObject(jsonObject(message.params).turn).id)
      if (completedTurnId && completedCompactionTurnIds.delete(completedTurnId)) return
      if (rejectCompaction && (!compactionTurnId || completedTurnId === compactionTurnId)) {
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

  const handleServerRequest = async (message: JsonRpcMessage, appServer: CodexAppServerClient): Promise<void> => {
    const method = typeof message.method === 'string' ? message.method : ''
    if (message.id === undefined) return
    opts.onTurnActivity?.(`codex:${method || 'server_request'}`)

    if (method === 'item/tool/requestUserInput') {
      const pending = jsonObject(message.params)
      audit.enqueue('server_request', 'request_user_input', pending)
      waitingOnUserInput = true
      try {
        await interrupt()
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
      audit.enqueue('server_request', 'approval_rejected', { method, params: jsonObject(message.params) })
      await appServer.respond(message.id, approvalRejection(method))
      await commit('failed', {
        error: { code: 'approval_disabled', summary: `Codex requested disabled approval: ${method}` }
      })
      return
    }

    await appServer.respondError(message.id, -32601, `Ankole does not implement Codex server request ${method}`)
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
    audit.enqueue('process', 'config_materialized', {
      mode: runtimeConfig.override?.mode ?? 'aigateway',
      codex_home: materialized.codexHome,
      workdir: sandbox.codexCwd
    })
    client = new CodexAppServerClient({
      cwd: sandbox.cwd,
      env: sandbox.env,
      commandArgv: sandbox.commandArgv,
      audit: (direction, message) => audit.enqueue(direction, 'json_rpc', { message }),
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

    if (runtimeThreadId) {
      try {
        await client.request('thread/resume', {
          threadId: runtimeThreadId,
          cwd: sandbox.codexCwd,
          approvalPolicy: 'never',
          sandbox: 'danger-full-access',
          developerInstructions: projection.developerInstructions
        })
        opts.onTurnActivity?.('codex:thread_resumed')
        audit.enqueue('process', 'thread_resumed', { thread_id: runtimeThreadId })
      } catch (error) {
        if (codexRetryKind({ message: errorMessage(error) }) !== 'unknown_session' || newThreadRetries >= 1) {
          throw error
        }
        newThreadRetries += 1
        recreatedThreadDuringSetup = true
        audit.enqueue('process', 'thread_recreated', {
          reason: 'unknown_session',
          previous_thread_id: runtimeThreadId
        })
        runtimeThreadId = undefined
      }
    }

    if (!runtimeThreadId) await startNewThread()

    const running = await updateStatus({
      request_id: `subagent-running-${crypto.randomUUID()}`,
      turn: turnStart.turn,
      delegation_id: delegationId,
      status: 'running',
      runtime_thread_id: runtimeThreadId,
      metadata: {
        codex_home_relative_path: relative(opts.workspaceSessionsRoot, dirname(materialized.codexHome)),
        codex_user_agent: stringValue(initializeResponse.userAgent),
        projected_tool_names: projection.dynamicTools.map(tool => tool.name),
        quarantined_tool_names: projection.quarantinedTools,
        projected_skill_count: projection.projectedSkillCount
      }
    })
    assertRpcResponse<SubagentDelegationResponse>(running, 'subagent running status rejected')

    const initialTurnInput = turnInput(turnStart, initial)
    await startCodexTurn(
      recreatedThreadDuringSetup ? recreatedThreadInput(initial, initialTurnInput) : initialTurnInput
    )

    steerTimer = setInterval(() => {
      if (steerInFlight || finalizing || !client || !runtimeThreadId || !codexTurnId) return
      const updates = opts.pollSteering?.() ?? []
      if (updates.length === 0) return
      steerInFlight = true
      void steerActiveTurn(client, runtimeThreadId, codexTurnId, updates, audit)
        .catch(error => commit('failed', { error: { code: 'steer_failed', summary: errorMessage(error) } }))
        .finally(() => {
          steerInFlight = false
        })
    }, steerPollIntervalMs)
    steerTimer.unref?.()

    await done
    return { kind: 'noop_completed', reason: 'subagent_delegation_committed' }
  } catch (error) {
    throw error
  } finally {
    if (steerTimer) clearInterval(steerTimer)
    opts.abortSignal?.removeEventListener('abort', onAbort)
    closing = true
    await client?.close()
    await audit.flush()
  }
}

function delegationIdFromTurn(turnStart: TurnStart): string {
  const fromContext = turnStart.request_context?.delegation_id
  if (typeof fromContext === 'string' && fromContext) return fromContext
  const sessionId = turnStart.turn.actor.session_id
  if (sessionId.startsWith('subagent:') && sessionId.length > 'subagent:'.length) {
    return sessionId.slice('subagent:'.length)
  }
  throw new Error('subagent turn is missing delegation id')
}

function turnInput(turnStart: TurnStart, delegation: SubagentDelegationResponse): string {
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

    return delegation.runtime_thread_id
      ? steering
      : `${delegation.prompt ?? ''}\n\nAdditional instructions from the parent agent:\n${steering}`.trim()
  }

  if (delegation.attempts > 1 && delegation.runtime_thread_id) {
    return 'Continue the delegated task. Re-check the acceptance criteria in the original brief before finishing.'
  }

  return delegation.prompt ?? ''
}

type CodexRetryKind = 'transient' | 'context_overflow' | 'unknown_session' | 'terminal'

function codexRetryKind(error: JsonObject): CodexRetryKind {
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

  const message = `${stringValue(error.message) ?? ''} ${stringValue(error.additionalDetails) ?? ''}`.toLowerCase()
  if (/unknown[-_ ]?(session|thread)|thread .*not found|no rollout found/.test(message)) return 'unknown_session'
  if (/context window|context length|too many tokens/.test(message)) return 'context_overflow'
  if (/model at capacity|systemerror|server overloaded|temporarily unavailable|error -32001/.test(message)) {
    return 'transient'
  }
  return 'terminal'
}

function retryContinuationInput(): string {
  return 'Continue the delegated task after the transient runtime error. Inspect the current workspace before repeating any side effect, then re-check the original acceptance criteria.'
}

function recreatedThreadInput(delegation: SubagentDelegationResponse, continuation: string): string {
  return `${delegation.prompt ?? ''}\n\nThe previous Codex thread could not be resumed. Inspect the existing working directory and continue from durable artifacts.\n\nCurrent continuation instructions:\n${continuation}\n\nRe-check every acceptance criterion before finishing.`.trim()
}

function filesChangedFromDiff(diff: string): string[] {
  const files = new Set<string>()
  for (const line of diff.split('\n')) {
    const match = /^(?:\+\+\+ b|--- a)\/(.+?)(?:\t.*)?$/.exec(line)
    if (match?.[1] && match[1] !== '/dev/null') files.add(match[1])
  }
  return [...files].sort()
}

async function steerActiveTurn(
  client: CodexAppServerClient,
  threadId: string,
  turnId: string,
  updates: TurnSteerUpdate[],
  audit: SubagentAuditBuffer
): Promise<void> {
  for (const update of updates) {
    const event = update.actorEvent
    if (!event) continue
    const command = jsonObject(jsonObject(jsonObject(event.payload_json).data).command)
    const text = stringValue(command.argsText)
    if (!text) continue
    await client.request('turn/steer', {
      threadId,
      expectedTurnId: turnId,
      input: textInput(text)
    })
    audit.enqueue('tool', 'turn_steer', { text, actor_event_id: event.actor_event_id })
  }
}

function abortReason(signal?: AbortSignal): string {
  if (!signal?.aborted) return 'stopped'
  return signal.reason instanceof Error ? signal.reason.message : String(signal.reason ?? 'stopped')
}

function required<T>(value: T | undefined, label: string): T {
  if (!value) throw new Error(`${label} RPC is not configured`)
  return value
}

async function requestProjectionAIGatewayKey(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions,
  options?: { forceRefresh?: boolean }
): Promise<AIGatewayApiKeyResponse> {
  const response = await opts.requestAIGatewayApiKey(
    {
      request_id: `subagent-projection-key-${crypto.randomUUID()}`,
      agent_uid: turnStart.turn.actor.agent_uid
    },
    options
  )
  assertRpcResponse<AIGatewayApiKeyResponse>(response, 'subagent projection AIGateway key rejected')
  return response
}
