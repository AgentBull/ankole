import type { TurnStart } from '../../lanes/actor_lane'
import { runAgentLoop } from '../agent-loop'
import { buildAgentSystemPrompt } from '../../prompts/system_prompt'
import type { SkillFileRoots } from '../../tools/library/skill-tools'
import { loadEnabledSkillMCPServers, materializeMCPorterConfig, type MaterializedMCPorterConfig } from '../../tools/mcp'
import { assistantText, userMessage, type UserMessage } from '../llm'
import { actorEventUserContent } from './actor_event_content'
import { actorEventText } from './actor_event_text'
import { brainTurnInjections, resolveBrainEnabled, type BrainTurnInjections } from './brain_context'
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
import { materializeLarkCredential, type MaterializedLarkCredential } from '../execution/lark-credential'
import { resolveAgentWorkerEnvParts } from '../execution/worker_env'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'
import { withoutBrowserMaterialSourceEnv } from '../../browser-runtime'

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
    // Resolved once and reused for tool registration and both memory
    // injections; a failed read leaves Brain off for this turn.
    const confirmationOnly = opts.ambientRoute?.action === 'NEW_WORK' && opts.ambientRoute.authority === 'NONE'
    const brainEnabled = confirmationOnly
      ? false
      : await turnActivity.runStep(resolveBrainEnabled(turnStart, opts.rpc, opts.logger), 'brain runtime config')
    const currentWorkerEnv = await turnActivity.runStep(
      resolveAgentWorkerEnvParts(turnStart.turn.actor.agent_uid, opts.rpc, turnStart.actor_event.binding_name),
      'worker env'
    )
    larkCredential = materializeLarkCredential({
      agentUID: turnStart.turn.actor.agent_uid,
      agentHome: opts.agentHome,
      rpc: opts.rpc,
      workerEnv: currentWorkerEnv,
      bindingName: turnStart.actor_event.binding_name
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
        repeatFetchSessionKey: aiGatewayConversationID,
        browserRuntime: opts.browserRuntime
      }),
      'web tools'
    )
    const resolvedTools = createTextTurnTools({
      turnStart,
      agentsRoot: opts.agentsRoot,
      agentHome: opts.agentHome,
      workspaceRoot: opts.workspaceRoot,
      userFilesRoot: opts.userFilesRoot,
      enabledSkills: agentConversationContext.skills ?? [],
      agentPluginCatalog: agentConversationContext.agentPlugins ?? [],
      skillRoots,
      brainEnabled,
      rpc: opts.rpc,
      waitForSteering: opts.waitForSteering,
      workerEnv: toolWorkerEnv,
      runtimeEnv,
      webTools
    })
    const tools = toolsForAmbientRoute(resolvedTools, opts.ambientRoute)

    const hostedTools = hostedToolsForAmbientRoute(turnStart.hosted_tools ?? [], opts.ambientRoute)

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
      availableToolNames: tools.map(tool => tool.name),
      ambientRoute: opts.ambientRoute
    }
    const systemPrompt = buildAgentSystemPrompt(promptOptions)
    // Both memory injections run in parallel, stay zero-model, and degrade
    // silently to nothing. The control plane owns the context-pack slot
    // (conversation start and after each compaction); every other turn
    // returns an empty pack.
    const memoryInjections: BrainTurnInjections = brainEnabled
      ? await turnActivity.runStep(
          brainTurnInjections(
            opts.rpc,
            turnStart,
            actorEventText(actorEvent.payload_json, actorEvent.type),
            opts.logger
          ),
          'brain memory injections'
        )
      : { pointerLines: [], packMessages: [] }
    const prompt = prependEnvironmentInfoLinesToUserMessage(userPrompt, [
      ...actorEventEnvironmentInfoLines(actorEvent.payload_json, {
        timezone: conversationTimezone
      }),
      ...turnRequestEnvironmentInfoLines(turnStart),
      ...memoryInjections.pointerLines
    ])

    const latest = await runAgentLoop({
      model,
      turnTrace: workerTurnTrace(turnStart),
      systemPrompt,
      messages: [
        ...channelContextModelMessages(actorEvent.payload_json, { timezone: conversationTimezone }),
        ...memoryInjections.packMessages,
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

  return tools.filter(tool => tool.type === 'web_search')
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
    return { kind: 'noop_completed', reason: 'schedule_silent_success' }
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
