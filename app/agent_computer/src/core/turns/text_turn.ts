import type { TurnStart } from '../../lanes/actor_lane'
import { runAgentLoop } from '../agent-loop'
import { buildAgentSystemPrompt } from '../../prompts/system_prompt'
import { createComputerTools } from '../../tools/computer'
import { createSkillTools, type SkillFileRoots } from '../../tools/library/skill-tools'
import { createMemoryTools } from '../../tools/memory/memory-tools'
import { createScheduleTools } from '../../tools/schedule/schedule-tools'
import { createTodoTool, TodoStore } from '../../tools/todo/todo-tool'
import { createWebTools } from '../../tools/web/web-tools'
import { createSubagentTool } from '../../tools/subagent/subagent-tool'
import { createClarifyTool } from '../../tools/clarify/clarify-tool'
import { assistantText, userMessage } from '../llm'
import { currentChannelFromTurnStart, statefulTruncationFromActorEventPayload } from './actor_event_text'
import { actorEventUserContent } from './actor_event_content'
import { acquireTurnAIGatewayAccess } from './turn_ai_gateway_access'
import { actorEventEnvironmentInfoLines, prependEnvironmentInfoLinesToUserMessage } from './message_context'
import { steeringMessages } from './turn_control'
import { createTurnActivity } from './turn_activity'
import { resolveAgentConversationContext } from './turn_context'
import { agentRuntimePolicyFromTurnStart } from './turn_runtime_policy'
import { resolveBrowserRuntimeConfig } from './browser_runtime_config'
import { resolveWorkerEnv } from './worker_env'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'

const silentSuccessMarker = '<silent_success/>'

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
      requestAIGatewayAPIKey: opts.requestAIGatewayAPIKey,
      runStep: turnActivity.runStep
    })
    const agentConversationContext = await turnActivity.runStep(
      resolveAgentConversationContext(turnStart, opts),
      'agent conversation context'
    )
    const aiGatewayConversationID = agentConversationContext.conversation?.id
    if (!aiGatewayConversationID) {
      throw new Error('agent conversation context is missing AIGateway conversation id')
    }
    const browserRuntimeConfig = await turnActivity.runStep(
      resolveBrowserRuntimeConfig(turnStart, opts),
      'browser runtime config'
    )
    const workerEnv = await turnActivity.runStep(resolveWorkerEnv(turnStart, opts), 'worker env')
    const webTools = await turnActivity.runStep(
      createWebTools({
        aiGateway,
        abortSignal: turnActivity.signal,
        localBrowser: {
          agentUID: turnStart.turn.actor.agent_uid,
          executionScopeID: turnStart.turn.actor.session_id ?? turnStart.turn.actor.agent_uid,
          blockPrivateNetwork: browserRuntimeConfig.blockPrivateNetwork,
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
        agentUID: turnStart.turn.actor.agent_uid,
        conversationID: turnStart.turn.actor.session_id,
        workspaceRoot: opts.workspaceRoot,
        browserRemoteCDPConfig: browserRuntimeConfig.remoteCDPConfig,
        localBrowserIdleTtlMs: browserRuntimeConfig.localBrowserIdleTtlMs,
        blockPrivateNetwork: browserRuntimeConfig.blockPrivateNetwork,
        workerEnv
      }),
      ...createScheduleTools({
        turnStart,
        requestScheduleRPC: opts.requestScheduleRPC
      }),
      ...createMemoryTools({
        turnStart,
        requestMemoryRPC: opts.requestMemoryRPC
      }),
      ...webTools,
      createClarifyTool(),
      createSubagentTool({
        turnStart,
        createSubagentDelegation: opts.createSubagentDelegation,
        getSubagentDelegation: opts.getSubagentDelegation,
        listSubagentDelegations: opts.listSubagentDelegations,
        steerSubagentDelegation: opts.steerSubagentDelegation,
        stopSubagentDelegation: opts.stopSubagentDelegation
      }),
      ...createSkillTools(opts.workspaceRoot, {
        turn: turnStart.turn,
        enabledSkills: agentConversationContext.skills ?? [],
        skillRoots: skillRootsFromOptions(opts),
        requestSkillOverlay: opts.requestSkillOverlay,
        appendSkillOverlay: opts.appendSkillOverlay,
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
      maxModelIterations: runtimePolicy.maxIterations,
      stateful: {
        actorEventID: actorEvent.actor_event_id,
        conversationID: aiGatewayConversationID,
        truncation: statefulTruncationFromActorEventPayload(actorEvent.payload_json)
      },
      tools,
      abortSignal: turnActivity.signal,
      onActivity: turnActivity.touch,
      withActivitySuspended: turnActivity.withSuspended,
      getSteeringMessages: async () => steeringMessages(turnStart, opts.pollSteering?.() ?? [])
    })
    if (latest.message.stopReason === 'error' || latest.message.stopReason === 'aborted') {
      throw new Error(
        latest.message.errorMessage ||
          (latest.message.stopReason === 'aborted' ? 'LLM provider call aborted' : 'LLM provider returned an error')
      )
    }
    const replyText = assistantText(latest.message)
    return textTurnResultFromAssistantReply(turnStart, replyText, latest.responseID, latest.outcome)
  } finally {
    turnActivity.cleanup()
  }
}

/**
 * Converts final assistant text into the worker's turn result contract.
 *
 * The worker does not decide whether an adopted Response chain has a visible
 * projection. SignalsGateway may find clarify or attachment output even when
 * the final assistant text is empty, and rejects an actually empty chain at
 * the durable completion boundary.
 */
export function textTurnResultFromAssistantReply(
  turnStart: TurnStart,
  replyText: string,
  finalResponseID: string,
  outcome: 'loop_finished' | 'iteration_exhausted'
): TurnHandlerResult {
  if (outcome === 'loop_finished' && silentSuccessAllowed(turnStart) && silentSuccessReply(replyText)) {
    return { kind: 'noop_completed', reason: 'schedule_silent_success' }
  }

  return { kind: 'turn_completed', finalResponseID, outcome }
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
 * Detects the explicit silent-success marker used by schedule wakeups.
 */
function silentSuccessReply(replyText: string): boolean {
  const text = replyText.trim()
  return text === '' || text === silentSuccessMarker
}
