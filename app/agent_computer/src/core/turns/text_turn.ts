import type { TurnStart } from '../../lanes/actor_lane'
import { isRecord, type JsonObject } from '@pleisto/active-support'
import { assertRpcResponse, type AppConfigureResolveResponse } from '../../lanes/rpc_lane'
import { runAgentLoop } from '../agent-loop'
import { buildAgentSystemPrompt } from '../../prompts/system_prompt'
import { createComputerTools } from '../../tools/computer'
import { createSkillTools, type SkillFileRoots } from '../../tools/library/skill-tools'
import { createMemoryTools } from '../../tools/memory/memory-tools'
import { createScheduleTools } from '../../tools/schedule/schedule-tools'
import { createTodoTool, TodoStore } from '../../tools/todo/todo-tool'
import { createWebTools } from '../../tools/web/web-tools'
import { createCodexDelegateTool } from '../../tools/codex/codex-tool'
import { assistantText, userMessage } from '../llm'
import { currentChannelFromTurnStart, statefulTruncationFromActorEventPayload } from './actor_event_text'
import { actorEventUserContent } from './actor_event_content'
import { acquireTurnAIGatewayAccess } from './turn_aigateway_access'
import { actorEventEnvironmentInfoLines, prependEnvironmentInfoLinesToUserMessage } from './message_context'
import { steeringMessages } from './turn_control'
import { createTurnActivity } from './turn_activity'
import { resolveAgentConversationContext } from './turn_context'
import { agentRuntimePolicyFromTurnStart } from './turn_runtime_policy'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'

const silentSuccessMarker = '<silent_success/>'
const RemoteBrowserCdpConfigKey = 'worker.remote_browser_cdp_config'
const LocalBrowserIdleTtlMsKey = 'worker.local_browser_idle_ttl_ms'

type BrowserRuntimeConfig = {
  remoteCdpConfig: JsonObject | null
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
  const runtimePolicy = agentRuntimePolicyFromTurnStart(turnStart)
  const turnActivity = createTurnActivity({
    sourceSignal: opts.abortSignal,
    inactivityTimeoutMs: runtimePolicy.inactivityTimeoutMs
  })
  try {
    if (!modelRef) {
      throw new Error('worker run is missing a real model_ref')
    }

    const { model, aiGateway, visionFallbackModel } = await acquireTurnAIGatewayAccess(turnStart, {
      requestAIGatewayApiKey: opts.requestAIGatewayApiKey,
      runStep: turnActivity.runStep
    })
    const agentConversationContext = await turnActivity.runStep(
      resolveAgentConversationContext(turnStart, opts),
      'agent conversation context'
    )
    const aiGatewayConversationId = agentConversationContext.conversation?.id
    if (!aiGatewayConversationId) {
      throw new Error('agent conversation context is missing AIGateway conversation id')
    }
    const browserRuntimeConfig = await turnActivity.runStep(
      resolveBrowserRuntimeConfig(turnStart, opts),
      'browser runtime config'
    )
    const webTools = await turnActivity.runStep(
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
      'web tools availability'
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

function skillRootsFromOptions(opts: TextTurnLoopOptions): SkillFileRoots | undefined {
  if (!opts.builtinSkillsRoot || !opts.agentInstalledSkillsRoot) return undefined
  return {
    builtinSkillsRoot: opts.builtinSkillsRoot,
    agentInstalledSkillsRoot: opts.agentInstalledSkillsRoot,
    ...(opts.internalSkillsRoot ? { internalSkillsRoot: opts.internalSkillsRoot } : {})
  }
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
  assertRpcResponse<AppConfigureResolveResponse>(response, 'browser runtime config rejected')

  const remoteCdpConfig = response.values[RemoteBrowserCdpConfigKey]?.value
  const localBrowserIdleTtlMs = response.values[LocalBrowserIdleTtlMsKey]?.value

  return {
    remoteCdpConfig: isRecord(remoteCdpConfig) ? remoteCdpConfig : null,
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
