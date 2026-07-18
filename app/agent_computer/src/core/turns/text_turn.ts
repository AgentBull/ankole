import type { TurnStart } from '../../lanes/actor_lane'
import { runAgentLoop } from '../agent-loop'
import { systemPromptForConversation } from '../../prompts/system_prompt'
import { createComputerTools } from '../../tools/computer'
import { createSkillTools, type SkillFileRoots } from '../../tools/library/skill-tools'
import { createMemoryTools } from '../../tools/memory/memory-tools'
import { createScheduleTools } from '../../tools/schedule/schedule-tools'
import { createTodoTool, TodoStore } from '../../tools/todo/todo-tool'
import { createBackgroundAgentJobTool } from '../../tools/background-agent-job/background-agent-job-tool'
import { createClarifyTool } from '../../tools/clarify/clarify-tool'
import { createSourceLearningTurnTools } from '../../tools/brain/source-learning-turn'
import { createMCPTools } from '../../tools/mcp'
import type { AgentTool } from '../types'
import { assistantText, userMessage } from '../llm'
import { currentChannelFromTurnStart, statefulTruncationFromActorEventPayload } from './actor_event_text'
import { actorEventUserContent } from './actor_event_content'
import { channelContextModelMessages } from './channel_context'
import { acquireTurnAIGatewayAccess } from './turn_ai_gateway_access'
import {
  actorEventEnvironmentInfoLines,
  prependEnvironmentInfoLinesToUserMessage,
  turnRequestEnvironmentInfoLines
} from './message_context'
import { steeringMessages } from './turn_control'
import { createTurnActivity } from './turn_activity'
import { resolveAgentConversationContext } from './turn_context'
import { agentRuntimePolicyFromTurnStart } from './turn_runtime_policy'
import { createTurnWebTools, resolveRenderedFetchRuntimeConfig } from './rendered_fetch_runtime_config'
import { resolveWorkerEnv } from './worker_env'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'
import { memoryRPCRequester, rpcMethods, scheduleRPCRequester, type RuntimeSkillSummary } from '../../lanes/rpc_lane'
import { withoutBrowserMaterialSourceEnv } from '../../browser-runtime'

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
    const actorEvent = turnStart.actor_event
    const learningTurn =
      actorEvent.type === 'brain.source.learn'
        ? createSourceLearningTurnTools({
            turnStart,
            workspaceRoot: opts.workspaceRoot,
            requestMemoryRPC: memoryRPCRequester(opts.rpc, turnStart.turn)
          })
        : undefined
    const userPrompt = userMessage(
      await actorEventUserContent(actorEvent.payload_json, actorEvent.type, modelRef, {
        workspaceRoot: opts.workspaceRoot,
        visionFallbackModel,
        abortSignal: turnActivity.signal
      })
    )

    let tools: AgentTool[]

    if (learningTurn) {
      tools = learningTurn.tools
    } else {
      const renderedFetchRuntimeConfig = await turnActivity.runStep(
        resolveRenderedFetchRuntimeConfig(turnStart, opts.rpc),
        'rendered fetch runtime config'
      )
      const workerEnv = await turnActivity.runStep(resolveWorkerEnv(turnStart, opts.rpc), 'worker env')
      const toolWorkerEnv = withoutBrowserMaterialSourceEnv(workerEnv)
      const skillRoots = skillRootsFromOptions(opts)
      const mcpTools = await turnActivity.runStep(
        createMCPTools({
          enabledSkills: agentConversationContext.skills ?? [],
          skillRoots,
          turn: turnStart.turn,
          workerEnv: toolWorkerEnv,
          abortSignal: turnActivity.signal
        }),
        'MCP tools availability'
      )
      const webTools = await turnActivity.runStep(
        createTurnWebTools({
          aiGateway,
          renderedFetchRuntimeConfig,
          workerEnv,
          browserRuntime: opts.browserRuntime,
          abortSignal: turnActivity.signal
        }),
        'web tools availability'
      )
      const computerTools = createComputerTools({
        agentUID: turnStart.turn.actor.agent_uid,
        conversationID: turnStart.turn.actor.session_id,
        workspaceRoot: opts.workspaceRoot,
        workerEnv: toolWorkerEnv
      })
      const backgroundAgentJobTools = await turnActivity.runStep(
        resolveBackgroundAgentJobTools(turnStart, opts, agentConversationContext.skills ?? []),
        'background agent job tool availability'
      )

      tools = [
        createTodoTool(new TodoStore()),
        ...computerTools,
        ...createScheduleTools({
          turnStart,
          requestScheduleRPC: scheduleRPCRequester(opts.rpc, turnStart.turn)
        }),
        ...createMemoryTools({
          turnStart,
          requestMemoryRPC: memoryRPCRequester(opts.rpc, turnStart.turn)
        }),
        ...webTools,
        ...mcpTools,
        createClarifyTool(),
        ...backgroundAgentJobTools,
        ...createSkillTools(opts.workspaceRoot, {
          turn: turnStart.turn,
          enabledSkills: agentConversationContext.skills ?? [],
          skillRoots,
          rpc: opts.rpc
        })
      ]
    }

    const promptOptions = {
      workspaceRoot: opts.workspaceRoot,
      turnStart,
      agentConversationContext,
      currentChannel: currentChannelFromTurnStart(turnStart),
      availableToolNames: tools.map(tool => tool.name)
    }
    const systemPrompt = systemPromptForConversation(promptOptions)
    const prompt = prependEnvironmentInfoLinesToUserMessage(userPrompt, [
      ...actorEventEnvironmentInfoLines(actorEvent.payload_json, {
        timezone: agentConversationContext.conversation?.timezone
      }),
      ...turnRequestEnvironmentInfoLines(turnStart)
    ])

    const latest = await runAgentLoop({
      model,
      systemPrompt,
      messages: [...channelContextModelMessages(actorEvent.payload_json), prompt, ...(opts.extraMessages ?? [])],
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
      hostedTools: turnStart.hosted_tools,
      abortSignal: turnActivity.signal,
      onActivity: turnActivity.touch,
      onPresentationEvent: opts.onPresentationEvent,
      withActivitySuspended: turnActivity.withSuspended,
      getSteeringMessages: async () => steeringMessages(turnStart, opts.pollSteering?.() ?? [])
    })
    if (latest.message.stopReason === 'error' || latest.message.stopReason === 'aborted') {
      throw new Error(
        latest.message.errorMessage ||
          (latest.message.stopReason === 'aborted' ? 'LLM provider call aborted' : 'LLM provider returned an error')
      )
    }
    learningTurn?.assertCompleted()
    const replyText = assistantText(latest.message)
    return textTurnResultFromAssistantReply(turnStart, replyText, latest.responseID, latest.outcome)
  } finally {
    turnActivity.cleanup()
  }
}

async function resolveBackgroundAgentJobTools(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions,
  skills: RuntimeSkillSummary[]
): Promise<AgentTool[]> {
  const response = await opts.rpc(rpcMethods.agentPluginList, {}, { turn: turnStart.turn })

  return [
    createBackgroundAgentJobTool({
      turnStart,
      agentPluginCatalog: response.agentPlugins,
      standaloneSkillNames: skills.filter(skill => !skill.agentPluginId).map(skill => skill.skillName),
      rpc: opts.rpc
    })
  ]
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

function skillRootsFromOptions(opts: TextTurnLoopOptions): SkillFileRoots {
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
  return replyText.trim() === silentSuccessMarker
}
