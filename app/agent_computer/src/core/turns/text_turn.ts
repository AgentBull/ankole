import type { TurnStart } from '../../lanes/actor_lane'
import { isRecord } from '@pleisto/active-support'
import { runAgentLoop } from '../agent-loop'
import { buildAgentSystemPrompt } from '../../prompts/system_prompt'
import { createComputerTools } from '../../tools/computer'
import { createSkillTools } from '../../tools/library/skill-tools'
import { createMemoryTools } from '../../tools/memory/memory-tools'
import { createScheduleTools } from '../../tools/schedule/schedule-tools'
import { createTodoTool, TodoStore } from '../../tools/todo/todo-tool'
import { createWebTools } from '../../tools/web/web-tools'
import { createCodexDelegateTool } from '../../tools/codex/codex-tool'
import { assistantText, userMessage } from '../llm'
import { currentChannelFromTurnStart, statefulTruncationFromActorEventPayload } from './actor_event_text'
import { actorEventUserContent } from './actor_event_content'
import {
  aiGatewayHttpClientFromApiKey,
  assertAIGatewayApiKeyMatchesTurn,
  runtimeModelFromAIGatewayApiKey
} from './model_runtime'
import { actorEventEnvironmentInfoLines, prependEnvironmentInfoLinesToUserMessage } from './message_context'
import { steeringMessages } from './turn_control'
import { TEXT_TURN_DEFAULT_INACTIVITY_TIMEOUT_MS } from './turn_config'
import { resolveAgentConversationContext } from './turn_context'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'
import { skillRootsFromOptions } from './turn_options'

const silentSuccessMarker = '<silent_success/>'
const RemoteBrowserCdpConfigKey = 'worker.remote_browser_cdp_config'
const LocalBrowserIdleTtlMsKey = 'worker.local_browser_idle_ttl_ms'

type BrowserRuntimeConfig = {
  remoteCdpConfig: Record<string, unknown> | null
  localBrowserIdleTtlMs?: number
}

type AgentRuntimePolicy = {
  maxOutputTokens?: number
  inactivityTimeoutMs: number
}

/**
 * Runs one Ankole text turn inside Agent Computer.
 *
 * The control plane delivers actor events and an opaque `model_ref`; the worker
 * resolves an agent-scoped AIGateway API key over RuntimeFabric, builds one
 * local Responses API client, and lets the control plane own provider dispatch.
 * The worker keeps only the AIGateway key in memory.
 */
export async function runTextTurnLoop(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<TurnHandlerResult> {
  const modelRef = turnStart.model_ref
  const runtimePolicy = agentRuntimePolicyFromTurnStart(turnStart)
  const turnActivity = createAgentActivityWatchdog(opts.abortSignal, runtimePolicy.inactivityTimeoutMs)
  try {
    if (!modelRef) {
      throw new Error('worker run is missing a real model_ref')
    }

    const apiKeyRequest = {
      request_id: `ai-gateway-key-${crypto.randomUUID()}`,
      agent_uid: turnStart.turn.actor.agent_uid
    }
    const apiKey = await abortableTurnStep(
      opts.requestAIGatewayApiKey(apiKeyRequest),
      turnActivity.signal,
      'AIGateway API key',
      turnActivity.touch
    )

    if ('code' in apiKey) {
      throw new Error(`AIGateway API key rejected: ${apiKey.code} ${apiKey.message ?? ''}`.trim())
    }

    assertAIGatewayApiKeyMatchesTurn(turnStart, apiKey)

    const refreshAIGatewayApiKey = (refreshOptions?: { forceRefresh?: boolean }) =>
      abortableTurnStep(
        opts.requestAIGatewayApiKey(
          {
            ...apiKeyRequest,
            request_id: `ai-gateway-key-${crypto.randomUUID()}`
          },
          refreshOptions
        ),
        turnActivity.signal,
        'AIGateway API key refresh',
        turnActivity.touch
      )

    const model = runtimeModelFromAIGatewayApiKey(modelRef, apiKey, refreshAIGatewayApiKey)
    const aiGateway = aiGatewayHttpClientFromApiKey(apiKey, refreshAIGatewayApiKey)
    const visionFallbackModel = modelRef.vision_fallback_model_ref
      ? runtimeModelFromAIGatewayApiKey(modelRef.vision_fallback_model_ref, apiKey, refreshAIGatewayApiKey)
      : undefined
    const agentConversationContext = await abortableTurnStep(
      resolveAgentConversationContext(turnStart, opts),
      turnActivity.signal,
      'agent conversation context',
      turnActivity.touch
    )
    const aiGatewayConversationId = agentConversationContext.conversation?.id
    if (!aiGatewayConversationId) {
      throw new Error('agent conversation context is missing AIGateway conversation id')
    }
    const browserRuntimeConfig = await abortableTurnStep(
      resolveBrowserRuntimeConfig(turnStart, opts),
      turnActivity.signal,
      'browser runtime config',
      turnActivity.touch
    )
    const webTools = await abortableTurnStep(
      createWebTools({
        aiGateway,
        abortSignal: turnActivity.signal,
        localBrowser: {
          agentUid: turnStart.turn.actor.agent_uid,
          executionScopeId: turnStart.turn.actor.session_id ?? turnStart.turn.actor.agent_uid,
          ...(typeof browserRuntimeConfig.localBrowserIdleTtlMs === 'number'
            ? { localBrowserIdleTtlMs: browserRuntimeConfig.localBrowserIdleTtlMs }
            : {})
        }
      }),
      turnActivity.signal,
      'web tools availability',
      turnActivity.touch
    )

    const todoStore = new TodoStore()
    const actorEvent = turnStart.actor_event
    const prompt = prependEnvironmentInfoLinesToUserMessage(
      userMessage(
        await actorEventUserContent(actorEvent.payload_json, actorEvent.type, modelRef, {
          workspaceRoot: opts.workspaceRoot,
          visionFallbackModel,
          abortSignal: turnActivity.signal
        })
      ),
      actorEventEnvironmentInfoLines(actorEvent.payload_json, {
        timezone: agentConversationContext.conversation?.timezone
      })
    )

    const tools = [
      createTodoTool(todoStore),
      ...createComputerTools({
        agentUid: turnStart.turn.actor.agent_uid,
        conversationId: turnStart.turn.actor.session_id,
        workspaceRoot: opts.workspaceRoot,
        browserRemoteCdpConfig: browserRuntimeConfig.remoteCdpConfig,
        localBrowserIdleTtlMs: browserRuntimeConfig.localBrowserIdleTtlMs
      }),
      ...createScheduleTools({
        turnStart,
        requestScheduleRpc: opts.requestScheduleRpc
      }),
      ...createMemoryTools({
        turnStart,
        requestMemoryRpc: opts.requestMemoryRpc
      }),
      ...webTools,
      createCodexDelegateTool({
        turnStart,
        workspaceRoot: opts.workspaceRoot,
        requestAIGatewayApiKey: opts.requestAIGatewayApiKey,
        requestAppConfigure: opts.requestAppConfigure,
        createCodexDelegation: opts.createCodexDelegation,
        getCodexDelegationStatus: opts.getCodexDelegationStatus,
        appendCodexDelegationEvent: opts.appendCodexDelegationEvent,
        updateCodexDelegationStatus: opts.updateCodexDelegationStatus
      }),
      ...createSkillTools(opts.workspaceRoot, {
        turn: turnStart.turn,
        enabledSkills: agentConversationContext.skills ?? [],
        skillRoots: skillRootsFromOptions(opts),
        requestSkillOverlay: opts.requestSkillOverlay,
        replaceSkillOverlay: opts.replaceSkillOverlay
      })
    ]

    const systemPrompt = buildAgentSystemPrompt({
      workspaceRoot: opts.workspaceRoot,
      turnStart,
      agentConversationContext,
      currentChannel: currentChannelFromTurnStart(turnStart),
      availableToolNames: tools.map(tool => tool.name)
    })

    const latest = await runAgentLoop({
      model,
      systemPrompt,
      messages: [prompt, ...(opts.extraMessages ?? [])],
      modelInputModalities: modelRef.input_modalities,
      visionFallbackModel,
      maxTokens: runtimePolicy.maxOutputTokens,
      stateful: {
        actorEventId: actorEvent.actor_event_id,
        conversationId: aiGatewayConversationId,
        truncation: statefulTruncationFromActorEventPayload(actorEvent.payload_json)
      },
      tools,
      abortSignal: turnActivity.signal,
      onActivity: turnActivity.touch,
      withActivitySuspended: turnActivity.withSuspended,
      getSteeringMessages: async () => steeringMessages(turnStart, opts.pollSteering?.() ?? [])
    })
    if (latest?.stopReason === 'error' || latest?.stopReason === 'aborted') {
      throw new Error(
        latest.errorMessage ||
          (latest.stopReason === 'aborted' ? 'LLM provider call aborted' : 'LLM provider returned an error')
      )
    }
    const replyText = assistantText(latest)
    return textTurnResultFromAssistantReply(turnStart, replyText)
  } finally {
    turnActivity.cleanup()
  }
}

function abortableTurnStep<T>(
  promise: Promise<T>,
  signal: AbortSignal,
  step: string,
  onActivity?: (description?: string) => void
): Promise<T> {
  if (signal.aborted) return Promise.reject(turnAbortError(signal, step))
  onActivity?.(`${step}:start`)

  return new Promise<T>((resolve, reject) => {
    const onAbort = () => {
      signal.removeEventListener('abort', onAbort)
      reject(turnAbortError(signal, step))
    }

    signal.addEventListener('abort', onAbort, { once: true })
    promise.then(
      value => {
        signal.removeEventListener('abort', onAbort)
        onActivity?.(`${step}:done`)
        resolve(value)
      },
      error => {
        signal.removeEventListener('abort', onAbort)
        reject(error)
      }
    )
  })
}

function agentRuntimePolicyFromTurnStart(turnStart: TurnStart): AgentRuntimePolicy {
  const rawPolicy = turnStart.request_context?.ai_agent
  const policy = isRecord(rawPolicy) ? rawPolicy : {}
  const maxOutputTokens = positiveInteger(policy.max_output_tokens)
  const modelMaxCompletionTokens = positiveInteger(turnStart.model_ref?.max_completion_tokens)
  const inactivityTimeoutMs =
    nonNegativeInteger(policy.inactivity_timeout_ms) ?? TEXT_TURN_DEFAULT_INACTIVITY_TIMEOUT_MS

  return {
    ...(maxOutputTokens ? { maxOutputTokens: clampPositiveInteger(maxOutputTokens, modelMaxCompletionTokens) } : {}),
    inactivityTimeoutMs
  }
}

function positiveInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) && value > 0 ? value : undefined
}

function nonNegativeInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : undefined
}

function clampPositiveInteger(value: number, ceiling: number | undefined): number {
  return ceiling ? Math.min(value, ceiling) : value
}

function createAgentActivityWatchdog(
  sourceSignal: AbortSignal | undefined,
  inactivityTimeoutMs: number
): {
  signal: AbortSignal
  touch: (description?: string) => void
  withSuspended: <T>(description: string, fn: () => Promise<T>) => Promise<T>
  cleanup: () => void
} {
  const controller = new AbortController()
  let timeout: ReturnType<typeof setTimeout> | undefined
  let suspended = 0
  const enabled = Number.isFinite(inactivityTimeoutMs) && inactivityTimeoutMs > 0

  const clear = (): void => {
    if (!timeout) return
    clearTimeout(timeout)
    timeout = undefined
  }

  const abort = (reason: unknown): void => {
    clear()
    if (!controller.signal.aborted) controller.abort(reason)
  }

  const touch = (): void => {
    if (!enabled || suspended > 0 || controller.signal.aborted) return
    clear()
    timeout = setTimeout(() => {
      abort(
        new DOMException(`Timed out after ${inactivityTimeoutMs}ms without model/provider activity`, 'TimeoutError')
      )
    }, inactivityTimeoutMs)
  }

  const withSuspended = async <T>(_description: string, fn: () => Promise<T>): Promise<T> => {
    suspended += 1
    clear()
    try {
      return await fn()
    } finally {
      suspended = Math.max(0, suspended - 1)
      touch()
    }
  }

  const onSourceAbort = (): void => abort(sourceSignal?.reason)

  if (sourceSignal?.aborted) {
    abort(sourceSignal.reason)
  } else {
    sourceSignal?.addEventListener('abort', onSourceAbort, { once: true })
    touch()
  }

  return {
    signal: controller.signal,
    touch,
    withSuspended,
    cleanup: () => {
      clear()
      sourceSignal?.removeEventListener('abort', onSourceAbort)
    }
  }
}

function turnAbortError(signal: AbortSignal, step: string): Error {
  const reason = signal.reason
  const message = reason instanceof Error ? reason.message : typeof reason === 'string' ? reason : 'turn aborted'
  return new Error(`${step} aborted: ${message}`)
}

/**
 * Converts final assistant text into the worker's turn result contract.
 *
 * Empty visible text is only allowed for inputs that explicitly permit
 * schedule-origin silent success; otherwise it is treated as a worker failure so
 * the caller does not mistake no output for a completed user reply.
 */
export function textTurnResultFromAssistantReply(turnStart: TurnStart, replyText: string): TurnHandlerResult {
  if (silentSuccessAllowed(turnStart) && silentSuccessReply(replyText)) {
    return { kind: 'noop_completed', reason: 'schedule_silent_success' }
  }

  if (!replyText) {
    throw new Error('worker run completed without visible assistant text')
  }

  return { kind: 'aigateway_response' }
}

/**
 * Reads the per-turn flag that permits a no-visible-text completion.
 */
function silentSuccessAllowed(turnStart: TurnStart): boolean {
  return turnStart.request_context?.silent_success_allowed === true
}

/**
 * Resolves browser runtime knobs from AppConfigure.
 *
 * Browser backend configuration is runtime-owned operator state, so it comes
 * through the same control-plane RPC path as other process-independent config.
 */
async function resolveBrowserRuntimeConfig(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<BrowserRuntimeConfig> {
  if (!opts.requestAppConfigure) return { remoteCdpConfig: null }

  const response = await opts.requestAppConfigure({
    request_id: `app-configure-browser-${crypto.randomUUID()}`,
    agent_uid: turnStart.turn.actor.agent_uid,
    keys: [RemoteBrowserCdpConfigKey, LocalBrowserIdleTtlMsKey]
  })
  if ('code' in response) {
    throw new Error(`browser runtime config rejected: ${response.code} ${response.message ?? ''}`.trim())
  }

  const remoteCdpConfig = response.values[RemoteBrowserCdpConfigKey]?.value
  const localBrowserIdleTtlMs = response.values[LocalBrowserIdleTtlMsKey]?.value

  return {
    remoteCdpConfig:
      remoteCdpConfig && typeof remoteCdpConfig === 'object' && !Array.isArray(remoteCdpConfig)
        ? (remoteCdpConfig as Record<string, unknown>)
        : null,
    ...(typeof localBrowserIdleTtlMs === 'number' && Number.isFinite(localBrowserIdleTtlMs)
      ? { localBrowserIdleTtlMs }
      : {})
  }
}

/**
 * Detects the explicit silent-success marker used by schedule wakeups.
 */
function silentSuccessReply(replyText: string): boolean {
  const text = replyText.trim()
  return text === '' || text === silentSuccessMarker
}
