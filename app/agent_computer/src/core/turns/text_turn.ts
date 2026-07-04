import type { TurnStart } from '../../actor_lane'
import { createCombinedAbortSignal } from '../../common/async'
import { runAgentLoop } from '../agent-loop'
import { buildAgentSystemPrompt } from '../../prompts/system_prompt'
import { createComputerTools } from '../../tools/computer'
import { createSkillTools } from '../../tools/library/skill-tools'
import { createScheduleTools } from '../../tools/schedule-tools'
import { createTodoTool, TodoStore } from '../../tools/todo-tool'
import { createWebTools } from '../../tools/web-tools'
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
import { TEXT_TURN_TIMEOUT_MS } from './turn_config'
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
  if (!modelRef) {
    throw new Error('worker run is missing a real model_ref')
  }

  const apiKeyRequest = {
    request_id: `ai-gateway-key-${crypto.randomUUID()}`,
    agent_uid: turnStart.turn.actor.agent_uid
  }
  const apiKey = await opts.requestAIGatewayApiKey(apiKeyRequest)

  if ('code' in apiKey) {
    throw new Error(`AIGateway API key rejected: ${apiKey.code} ${apiKey.message ?? ''}`.trim())
  }

  assertAIGatewayApiKeyMatchesTurn(turnStart, apiKey)

  const refreshAIGatewayApiKey = (refreshOptions?: { forceRefresh?: boolean }) =>
    opts.requestAIGatewayApiKey(
      {
        ...apiKeyRequest,
        request_id: `ai-gateway-key-${crypto.randomUUID()}`
      },
      refreshOptions
    )

  const model = runtimeModelFromAIGatewayApiKey(modelRef, apiKey, refreshAIGatewayApiKey)
  const aiGateway = aiGatewayHttpClientFromApiKey(apiKey, refreshAIGatewayApiKey)
  const visionFallbackModel = modelRef.vision_fallback_model_ref
    ? runtimeModelFromAIGatewayApiKey(modelRef.vision_fallback_model_ref, apiKey, refreshAIGatewayApiKey)
    : undefined
  const agentConversationContext = await resolveAgentConversationContext(turnStart, opts)
  const aiGatewayConversationId = agentConversationContext.conversation?.id
  if (!aiGatewayConversationId) {
    throw new Error('agent conversation context is missing AIGateway conversation id')
  }
  const browserRuntimeConfig = await resolveBrowserRuntimeConfig(turnStart, opts)
  const webTools = await createWebTools({
    aiGateway,
    localBrowser: {
      agentUid: turnStart.turn.actor.agent_uid,
      executionScopeId: turnStart.turn.actor.session_id ?? turnStart.turn.actor.agent_uid,
      ...(typeof browserRuntimeConfig.localBrowserIdleTtlMs === 'number'
        ? { localBrowserIdleTtlMs: browserRuntimeConfig.localBrowserIdleTtlMs }
        : {})
    }
  })

  const todoStore = new TodoStore()
  const actorEvent = turnStart.actor_event
  const turnTimeout = createCombinedAbortSignal(opts.abortSignal, TEXT_TURN_TIMEOUT_MS)
  try {
    const prompt = prependEnvironmentInfoLinesToUserMessage(
      userMessage(
        await actorEventUserContent(actorEvent.payload_json, actorEvent.type, modelRef, {
          workspaceRoot: opts.workspaceRoot,
          visionFallbackModel,
          abortSignal: turnTimeout.signal
        })
      ),
      actorEventEnvironmentInfoLines(actorEvent.payload_json, {
        timezone: agentConversationContext.conversation?.timezone
      })
    )

    const systemPrompt = buildAgentSystemPrompt({
      workspaceRoot: opts.workspaceRoot,
      turnStart,
      agentConversationContext,
      currentChannel: currentChannelFromTurnStart(turnStart)
    })

    const latest = await runAgentLoop({
      model,
      systemPrompt,
      messages: [prompt, ...(opts.extraMessages ?? [])],
      modelInputModalities: modelRef.input_modalities,
      visionFallbackModel,
      stateful: {
        actorEventId: actorEvent.actor_event_id,
        conversationId: aiGatewayConversationId,
        truncation: statefulTruncationFromActorEventPayload(actorEvent.payload_json)
      },
      tools: [
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
        ...webTools,
        ...createSkillTools(opts.workspaceRoot, {
          turn: turnStart.turn,
          enabledSkills: agentConversationContext.skills ?? [],
          skillRoots: skillRootsFromOptions(opts),
          requestSkillOverlay: opts.requestSkillOverlay,
          replaceSkillOverlay: opts.replaceSkillOverlay
        })
      ],
      abortSignal: turnTimeout.signal,
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
    turnTimeout.cleanup()
  }
}

export function textTurnResultFromAssistantReply(turnStart: TurnStart, replyText: string): TurnHandlerResult {
  if (silentSuccessAllowed(turnStart) && silentSuccessReply(replyText)) {
    return { kind: 'noop_completed', reason: 'schedule_silent_success' }
  }

  if (!replyText) {
    throw new Error('worker run completed without visible assistant text')
  }

  return { kind: 'aigateway_response' }
}

function silentSuccessAllowed(turnStart: TurnStart): boolean {
  return turnStart.request_context?.silent_success_allowed === true
}

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

function silentSuccessReply(replyText: string): boolean {
  const text = replyText.trim()
  return text === '' || text === silentSuccessMarker
}
