import type { TurnStart } from '../../lanes/actor_lane'
import { runAgentLoop } from '../agent-loop'
import { buildAgentSystemPrompt } from '../../prompts/system_prompt'
import { createComputerTools } from '../../tools/computer'
import { createSkillTools, type SkillFileRoots } from '../../tools/library/skill-tools'
import { createMemoryTools } from '../../tools/memory/memory-tools'
import { createScheduleTools } from '../../tools/schedule/schedule-tools'
import { createStandingOrdersTools } from '../../tools/channel/standing-orders-tool'
import { createTodoTool, TodoStore } from '../../tools/todo/todo-tool'
import { createCreateBackgroundJobTool } from '../../tools/background-agent-job/create-background-job'
import { createListBackgroundJobsTool } from '../../tools/background-agent-job/list-background-jobs'
import { createRespawnBackgroundJobTool } from '../../tools/background-agent-job/respawn-background-job'
import { createSendMessageToBackgroundJobTool } from '../../tools/background-agent-job/send-message-to-background-job'
import { createShowBackgroundJobDetailsTool } from '../../tools/background-agent-job/show-background-job-details'
import { createStopBackgroundJobTool } from '../../tools/background-agent-job/stop-background-job'
import { createClarifyTool } from '../../tools/clarify/clarify-tool'
import { createSourceLearningTurnTools } from '../../tools/brain/source-learning-turn'
import { loadEnabledSkillMCPServers, materializeMCPorterConfig, type MaterializedMCPorterConfig } from '../../tools/mcp'
import type { AgentTool } from '../types'
import { assistantText, userMessage, type UserMessage } from '../llm'
import { statefulTruncationFromActorEventPayload } from './actor_event_text'
import { actorEventUserContent } from './actor_event_content'
import { channelContextModelMessages } from './channel_context'
import { acquireTurnAIGatewayAccess } from './turn_ai_gateway_access'
import {
  actorEventEnvironmentInfoLines,
  prependEnvironmentInfoLinesToUserMessage,
  turnRequestEnvironmentInfoLines
} from './message_context'
import { steeringMessagesWithAcknowledgement } from './turn_control'
import { createTurnActivity } from './turn_activity'
import { resolveAgentConversationContext } from './turn_context'
import { agentRuntimePolicyFromTurnStart, webSearchIsProviderHosted } from './turn_runtime_policy'
import { createTurnWebTools, resolveRenderedFetchRuntimeConfig } from './rendered_fetch_runtime_config'
import { materializeLarkCredential, type MaterializedLarkCredential } from './lark-credential'
import { resolveAgentWorkerEnvParts } from './worker_env'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'
import { memoryRPCRequester, rpcMethods, scheduleRPCRequester, signalChannelRPCRequester } from '../../lanes/rpc_lane'
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
  let mcporterConfig: MaterializedMCPorterConfig | undefined
  let larkCredential: MaterializedLarkCredential | undefined
  try {
    if (!modelRef) {
      throw new Error('worker run is missing a real model_ref')
    }

    const { model, aiGateway, visionFallbackModel } = await acquireTurnAIGatewayAccess(turnStart, {
      requestAIGatewayAPIKey: opts.requestAIGatewayAPIKey,
      runStep: turnActivity.runStep
    })
    logAIGatewayRoute(opts, turnStart, model, aiGateway.baseURL)
    const agentConversationContext = await turnActivity.runStep(
      resolveAgentConversationContext(turnStart, opts),
      'agent conversation context'
    )
    const aiGatewayConversationID = agentConversationContext.conversation?.id
    if (!aiGatewayConversationID) {
      throw new Error('agent conversation context is missing AIGateway conversation id')
    }
    const conversationTimezone = agentConversationContext.conversation?.timezone || 'UTC'
    const actorEvent = turnStart.actor_event
    const learningTurn =
      actorEvent.type === 'brain.source.learn'
        ? createSourceLearningTurnTools({
            turnStart,
            agentHome: opts.agentHome,
            workspaceRoot: opts.workspaceRoot,
            requestMemoryRPC: memoryRPCRequester(opts.rpc, turnStart.turn)
          })
        : undefined
    const userPrompt = userMessage(
      await actorEventUserContent(actorEvent.payload_json, actorEvent.type, modelRef, {
        agentHome: opts.agentHome,
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
      const currentWorkerEnv = await turnActivity.runStep(
        resolveAgentWorkerEnvParts(turnStart.turn.actor.agent_uid, opts.rpc),
        'worker env'
      )
      larkCredential = materializeLarkCredential({
        agentUID: turnStart.turn.actor.agent_uid,
        agentHome: opts.agentHome,
        rpc: opts.rpc,
        workerEnv: currentWorkerEnv
      })
      const workerEnv = larkCredential.workerEnv.vars
      const runtimeEnv = { ...opts.runtimeEnv, ...larkCredential.runtimeEnv }
      const skillRoots = skillRootsFromOptions(opts)
      const mcpServers = await turnActivity.runStep(
        loadEnabledSkillMCPServers({
          enabledSkills: agentConversationContext.skills ?? [],
          skillRoots,
          runtime: 'main'
        }),
        'Skill MCP dependencies'
      )
      mcporterConfig = materializeMCPorterConfig(mcpServers)
      const toolWorkerEnv = { ...withoutBrowserMaterialSourceEnv(workerEnv), ...mcporterConfig.env }
      const webTools = await turnActivity.runStep(
        createTurnWebTools({
          aiGateway,
          renderedFetchRuntimeConfig,
          workerEnv,
          workspaceRoot: opts.workspaceRoot,
          browserRuntime: opts.browserRuntime
        }),
        'web tools'
      )
      const computerTools = createComputerTools({
        agentUID: turnStart.turn.actor.agent_uid,
        conversationID: turnStart.turn.actor.session_id,
        agentHome: opts.agentHome,
        workspaceRoot: opts.workspaceRoot,
        userFilesRoot: opts.userFilesRoot,
        workerEnv: toolWorkerEnv,
        runtimeEnv
      })
      const backgroundAgentJobTools = await turnActivity.runStep(
        resolveBackgroundAgentJobTools(turnStart, opts),
        'background agent job tool availability'
      )

      tools = [
        createTodoTool(new TodoStore()),
        ...computerTools,
        ...createScheduleTools({
          turnStart,
          requestScheduleRPC: scheduleRPCRequester(opts.rpc, turnStart.turn)
        }),
        ...createStandingOrdersTools({
          turnStart,
          requestSignalChannelRPC: signalChannelRPCRequester(opts.rpc, turnStart.turn)
        }),
        ...createMemoryTools({
          turnStart,
          requestMemoryRPC: memoryRPCRequester(opts.rpc, turnStart.turn)
        }),
        ...webTools.filter(tool => !webSearchIsProviderHosted(turnStart) || tool.name !== 'web_search'),
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

    const hostedTools = turnStart.hosted_tools ?? []

    opts.logger?.info('worker.turn_tools_resolved', 'worker turn tools resolved', {
      actor_event_id: turnStart.turn.actor_event_id,
      tool_count: tools.length,
      tool_names: tools.map(tool => tool.name),
      hosted_tool_count: hostedTools.length,
      hosted_tool_types: hostedTools.map(tool => tool.type)
    })

    const promptOptions = {
      userFilesRoot: opts.userFilesRoot,
      workspaceRoot: opts.workspaceRoot,
      turnStart,
      agentConversationContext,
      availableToolNames: tools.map(tool => tool.name)
    }
    const systemPrompt = buildAgentSystemPrompt(promptOptions)
    const prompt = prependEnvironmentInfoLinesToUserMessage(userPrompt, [
      ...actorEventEnvironmentInfoLines(actorEvent.payload_json, {
        timezone: conversationTimezone
      }),
      ...turnRequestEnvironmentInfoLines(turnStart)
    ])

    const latest = await runAgentLoop({
      model,
      systemPrompt,
      messages: [
        ...channelContextModelMessages(actorEvent.payload_json, { timezone: conversationTimezone }),
        prompt,
        ...(opts.extraMessages ?? [])
      ],
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
      hostedTools,
      abortSignal: turnActivity.signal,
      onActivity: turnActivity.touch,
      logger: opts.logger,
      onPresentationEvent: opts.onPresentationEvent,
      withActivitySuspended: turnActivity.withSuspended,
      getSteeringMessages: async () =>
        steeringMessagesWithAcknowledgement(turnStart, opts.pollSteering?.() ?? [], opts.onSteeringApplied),
      repairFinalResponse: message =>
        assistantText(message).trim() === '' ? emptyReplyObligationReminder(turnStart) : undefined
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
    try {
      mcporterConfig?.cleanup()
    } finally {
      try {
        larkCredential?.cleanup()
      } finally {
        turnActivity.cleanup()
      }
    }
  }
}

function logAIGatewayRoute(
  opts: TextTurnLoopOptions,
  turnStart: TurnStart,
  model: Parameters<typeof runAgentLoop>[0]['model'],
  baseURL: string
): void {
  opts.logger?.info('worker.aigateway_route_resolved', 'worker AIGateway route resolved', {
    actor_event_id: turnStart.turn.actor_event_id,
    model: model.name,
    provider: model.provider,
    selector: model.selector,
    ...safeAIGatewayRoute(baseURL)
  })
}

function safeAIGatewayRoute(baseURL: string): Record<string, string> {
  try {
    const url = new URL(baseURL)

    return {
      aigateway_scheme: url.protocol.replace(/:$/, ''),
      aigateway_host: url.host
    }
  } catch {
    return { aigateway_url_state: 'invalid' }
  }
}

async function resolveBackgroundAgentJobTools(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<AgentTool[]> {
  const response = await opts.rpc(rpcMethods.agentPluginList, {}, { turn: turnStart.turn })

  return [
    createCreateBackgroundJobTool({ turnStart, agentPluginCatalog: response.agentPlugins, rpc: opts.rpc }),
    createListBackgroundJobsTool({ turnStart, rpc: opts.rpc }),
    createShowBackgroundJobDetailsTool({ turnStart, rpc: opts.rpc }),
    createSendMessageToBackgroundJobTool({
      turnStart,
      rpc: opts.rpc,
      waitForSteering: opts.waitForSteering
    }),
    createRespawnBackgroundJobTool({ turnStart, agentsRoot: opts.agentsRoot, rpc: opts.rpc }),
    createStopBackgroundJobTool({ turnStart, rpc: opts.rpc })
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

/**
 * Names the turn's outstanding obligation after an empty final response.
 *
 * The control plane rejects a completion with no user-visible projection, and
 * that rejection surfaces only after the turn has ended, as a full turn retry.
 * This one bounded reminder settles the obligation inside the turn instead:
 * the loop injects it once, and a second empty response still ends the turn,
 * so the control-plane contract stays the authority on definite failure.
 */
function emptyReplyObligationReminder(turnStart: TurnStart): UserMessage {
  const lines = [
    'You ended your turn with no visible output. This turn was started by an event that requires one, and this turn cannot complete without it: nothing you did reaches the user unless the turn ends with final reply text, a clarify question, or a reply_attachment delivery.',
    'End the turn now with a short final reply. If you already delivered the result through reply_attachment or a generated image, reply with one short closing line. If you are blocked, state plainly what blocked you and what you need.'
  ]
  if (silentSuccessAllowed(turnStart)) {
    lines.push(
      `If this scheduled check found nothing that needs attention, reply exactly ${silentSuccessMarker} and nothing else.`
    )
  }
  return { role: 'user', content: lines.join('\n') }
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
