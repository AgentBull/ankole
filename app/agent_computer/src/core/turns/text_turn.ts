import type { TurnStart } from '../../lanes/actor_lane'
import { runAgentLoop } from '../agent-loop'
import { buildAgentSystemPrompt } from '../../prompts/system_prompt'
import type { SkillFileRoots } from '../../tools/library/skill-tools'
import { loadEnabledSkillMCPServers } from '../../tools/mcp'
import { assistantText, BRAIN_OPERATIONS, userMessage, type HostedTool, type UserMessage } from '../llm'
import { actorEventUserContent } from './actor_event_content'
import { channelContextModelMessages } from './channel_context'
import { acquireTurnAIGatewayAccess } from './turn_ai_gateway_access'
import { workerTurnTrace } from '../../observability/turn-tracing'
import {
  actorEventEnvironmentInfoLines,
  prependEnvironmentInfoLinesToUserMessage,
  turnRequestEnvironmentInfoLines
} from './message_context'
import { steeringMessagesWithAcknowledgement } from './turn_control'
import { createTurnActivity } from './turn_activity'
import { resolveAgentConversationContext } from './turn_context'
import { agentRuntimePolicyFromTurnStart, statefulTruncationFromActorEventPayload } from './turn_runtime_policy'
import { resolveRenderedFetchRuntimeConfig } from './rendered_fetch_runtime_config'
import { scheduleTurnContextFromTurnStart } from './schedule_turn_context'
import { createTurnWebTools } from './turn_web_tools'
import { createTextTurnTools } from './text_turn_tools'
import { prepareExecutionMaterials, type PreparedExecutionMaterials } from '../execution/execution-materials'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'

// The Worker converts this exact reply to a scheduled no-op only when the
// request permits silent success.
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
  let executionMaterials: PreparedExecutionMaterials | undefined
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
    const userPrompt = userMessage(
      await actorEventUserContent(actorEvent.payload_json, actorEvent.type, modelRef, {
        agentHome: opts.agentHome,
        workspaceRoot: opts.workspaceRoot,
        visionFallbackModel,
        abortSignal: turnActivity.signal
      })
    )

    const renderedFetchRuntimeConfig = await turnActivity.runStep(
      resolveRenderedFetchRuntimeConfig(turnStart, opts.rpc),
      'rendered fetch runtime config'
    )
    const skillRoots = skillRootsFromOptions(opts)
    const mcpServers = await turnActivity.runStep(
      loadEnabledSkillMCPServers({
        enabledSkills: agentConversationContext.skills ?? [],
        skillRoots,
        runtime: 'main'
      }),
      'Skill MCP dependencies'
    )
    let webTools: Awaited<ReturnType<typeof createTurnWebTools>> | undefined
    executionMaterials = await turnActivity.runStep(
      prepareExecutionMaterials({
        agentUID: turnStart.turn.actor.agent_uid,
        agentHome: opts.agentHome,
        rpc: opts.rpc,
        bindingName: turnStart.actor_event.binding_name,
        runtimeEnv: opts.runtimeEnv,
        mcpServers,
        abortSignal: turnActivity.signal,
        consumeMaterialSourceEnv: async workerEnv => {
          webTools = await createTurnWebTools({
            turnStart,
            aiGateway,
            renderedFetchRuntimeConfig,
            workerEnv,
            workspaceRoot: opts.workspaceRoot,
            repeatFetchSessionKey: aiGatewayConversationID,
            browserRuntime: opts.browserRuntime
          })
        }
      }),
      'execution materials'
    )
    if (!webTools) throw new Error('worker execution materials did not prepare web tools')
    const resolvedTools = createTextTurnTools({
      turnStart,
      agentsRoot: opts.agentsRoot,
      agentHome: opts.agentHome,
      workspaceRoot: opts.workspaceRoot,
      userFilesRoot: opts.userFilesRoot,
      enabledSkills: agentConversationContext.skills ?? [],
      agentPluginCatalog: agentConversationContext.agentPlugins ?? [],
      skillRoots,
      rpc: opts.rpc,
      waitForSteering: opts.waitForSteering,
      workerEnv: executionMaterials.workerEnv,
      runtimeEnv: executionMaterials.runtimeEnv,
      webTools
    })
    const tools = toolsForAmbientRoute(resolvedTools, opts.ambientRoute)

    // A main Turn takes the whole Brain catalog and the memory injection; the
    // control plane declares `brain` only while `brain.enabled` is true.
    const hostedTools = hostedToolsForAmbientRoute(turnStart.hosted_tools ?? [], opts.ambientRoute).map(
      (tool): HostedTool => (tool.type === 'brain' ? { type: 'brain', inject: true } : tool)
    )

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
      turnStart: { ...turnStart, hosted_tools: hostedTools },
      agentConversationContext,
      availableToolNames: [...tools.map(tool => tool.name), ...hostedBrainOperationNames(hostedTools)],
      ambientRoute: opts.ambientRoute
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
      turnTrace: workerTurnTrace(turnStart),
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
        lacksVisibleReply(assistantText(message), turnStart) ? emptyReplyObligationReminder(turnStart) : undefined
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
    try {
      await executionMaterials?.cleanup()
    } finally {
      turnActivity.cleanup()
    }
  }
}

export function toolsForAmbientRoute<T extends { isReadOnly?: boolean }>(
  tools: T[],
  route: TextTurnLoopOptions['ambientRoute']
): T[] {
  if (!route) return tools
  if (route.action === 'NEW_WORK' && route.authority === 'NONE') return []
  if (route.action !== 'FOREGROUND_REPLY') return tools

  return tools.filter(tool => tool.isReadOnly === true)
}

export function hostedToolsForAmbientRoute<T extends { type: string }>(
  tools: T[],
  route: TextTurnLoopOptions['ambientRoute']
): T[] {
  if (!route) return tools
  if (route.action === 'NEW_WORK' && route.authority === 'NONE') return []
  if (route.action !== 'FOREGROUND_REPLY') return tools

  // A foreground reply keeps read-and-write memory: it speaks for the Agent in
  // the room, and a confirmation-only turn above has already dropped it.
  return tools.filter(tool => tool.type === 'web_search' || tool.type === 'brain')
}

/**
 * The model-facing names of the hosted Brain operations, so prompt guidance
 * about memory follows what AIGateway actually declares this turn.
 */
export function hostedBrainOperationNames(hostedTools: HostedTool[]): string[] {
  const brain = hostedTools.find(tool => tool.type === 'brain')
  if (!brain || brain.type !== 'brain') return []
  return [...(brain.operations ?? BRAIN_OPERATIONS)]
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

/**
 * The Worker does not decide whether an adopted Response chain has a visible
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
    return { kind: 'noop_completed', reason: 'schedule_silent_success', finalResponseID }
  }

  return { kind: 'turn_completed', finalResponseID, outcome }
}

function silentSuccessAllowed(turnStart: TurnStart): boolean {
  return scheduleTurnContextFromTurnStart(turnStart)?.silentSuccessAllowed === true
}

/**
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

function silentSuccessReply(replyText: string): boolean {
  return replyText.trim() === silentSuccessMarker
}

/**
 * A reply carries no usable visible content when it is blank, or when it is only
 * the silent-success sentinel on a turn that did not permit silent success. The
 * bounded empty-reply reminder then asks for a real visible reply instead of
 * letting the raw sentinel become the turn output and leak to the channel.
 */
function lacksVisibleReply(replyText: string, turnStart: TurnStart): boolean {
  if (replyText.trim() === '') return true
  return !silentSuccessAllowed(turnStart) && silentSuccessReply(replyText)
}
