import type { TurnStart } from '../../actor_lane'
import { createCombinedAbortSignal } from '../../common/async'
import { lastNonEmpty } from '../../common/json-utils'
import { runAgentLoop } from '../agent-loop'
import { buildAgentSystemPrompt } from '../../prompts/system_prompt'
import { createComputerTools } from '../../tools/computer'
import { createReplyAttachmentStore } from '../../tools/computer/reply-attachment-tool'
import { createSkillTools } from '../../tools/library/skill-tools'
import { createScheduleTools } from '../../tools/schedule-tools'
import { createTodoTool, TodoStore } from '../../tools/todo-tool'
import type { FinalProposalBody } from '../../turn_envelopes'
import { currentChannelFromTurnStart, inputText } from './actor_input_text'
import {
  attachPendingEnvironmentInfoToUserMessage,
  attachPreviousChatHistoryToUserMessage,
  conversationContextFromHistory,
  inputAlreadyMaterialized
} from './conversation_history'
import { assertAIGatewayApiKeyMatchesTurn, runtimeModelFromAIGatewayApiKey } from './model_runtime'
import {
  assistantText,
  isLlmMessage,
  latestAssistantMessage,
  summarizeAgentMessages,
  userMessage
} from './turn_messages'
import { steeringMessages } from './turn_control'
import { TEXT_TURN_TIMEOUT_MS } from './turn_config'
import { resolveAgentConversationContext, resolveConversationHistory } from './turn_context'
import type { TextTurnLoopOptions } from './turn_options'
import { skillRootsFromOptions } from './turn_options'
import {
  createTurnTelemetry,
  finalProposalWithTelemetry,
  observeAgentEvent,
  scheduleSilentSuccessAllowed,
  scheduleSilentSuccessRequested,
  silentSuccessProposalWithTelemetry
} from './turn_telemetry'

/**
 * Runs one Ankole text turn inside Agent Computer.
 *
 * The control plane delivers actor inputs and an opaque `model_ref`; the worker
 * resolves an agent-scoped AIGateway API key over RuntimeFabric, builds one
 * local Responses API client, and lets the control plane own provider dispatch.
 * The worker keeps only the AIGateway key in memory.
 */
export async function runTextTurnLoop(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<FinalProposalBody> {
  const modelRef = turnStart.model_ref
  if (!modelRef) {
    throw new Error('LLM turn is missing a real model_ref')
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

  const model = runtimeModelFromAIGatewayApiKey(modelRef, apiKey, undefined, () =>
    opts.requestAIGatewayApiKey({
      ...apiKeyRequest,
      request_id: `ai-gateway-key-${crypto.randomUUID()}`
    })
  )
  const telemetry = createTurnTelemetry(modelRef, model)
  const agentConversationContext = await resolveAgentConversationContext(turnStart, opts)
  const history = await resolveConversationHistory(turnStart, opts, 'prompt')

  const conversation = conversationContextFromHistory(history, model, agentConversationContext)
  const todoStore = new TodoStore()
  const replyAttachmentStore = createReplyAttachmentStore()
  const rawPrompts = turnStart.inputs
    .filter(input => !inputAlreadyMaterialized(input, conversation))
    .map(input => userMessage(inputText(input.payload_json, input.type)))
  const withEnvironmentInfo = attachPendingEnvironmentInfoToUserMessage(
    conversation.messages,
    rawPrompts,
    conversation.pendingUserEnvironmentInfoLines
  )
  const { messages, prompts } = attachPreviousChatHistoryToUserMessage(
    withEnvironmentInfo.messages,
    withEnvironmentInfo.prompts,
    lastNonEmpty(conversation.previousChatHistorySummaries)
  )

  const systemPrompt = buildAgentSystemPrompt({
    workspaceRoot: opts.workspaceRoot,
    turnStart,
    agentConversationContext,
    currentChannel: currentChannelFromTurnStart(turnStart)
  })

  const turnTimeout = createCombinedAbortSignal(opts.abortSignal, TEXT_TURN_TIMEOUT_MS)
  try {
    const newMessages = await runAgentLoop(
      prompts,
      {
        systemPrompt,
        messages: [...messages, ...(opts.extraMessages ?? [])],
        tools: [
          createTodoTool(todoStore),
          ...createComputerTools({
            agentUid: turnStart.turn.actor.agent_uid,
            conversationId: turnStart.turn.actor.session_id,
            workspaceRoot: opts.workspaceRoot,
            replyAttachmentStore
          }),
          ...createScheduleTools({
            turnStart,
            requestScheduleRpc: opts.requestScheduleRpc
          }),
          ...createSkillTools(opts.workspaceRoot, {
            turn: turnStart.turn,
            enabledSkills: agentConversationContext.skills ?? [],
            skillRoots: skillRootsFromOptions(opts),
            requestSkillOverlay: opts.requestSkillOverlay,
            replaceSkillOverlay: opts.replaceSkillOverlay,
            clearSkillOverlay: opts.clearSkillOverlay
          })
        ]
      },
      {
        model,
        convertToLlm: messages => messages.flatMap(message => (isLlmMessage(message) ? [message] : [])),
        getSteeringMessages: async () => steeringMessages(turnStart, opts.pollSteering?.() ?? []),
        toolExecution: 'parallel',
        maxTurns: opts.maxSteps ?? 8,
        nudgeOnEmptyAfterTools: true,
        metadata: {
          agent_uid: turnStart.turn.actor.agent_uid,
          conversation_id: turnStart.turn.actor.session_id,
          llm_turn_id: turnStart.turn.llm_turn_id,
          profile: modelRef.profile,
          provider_id: modelRef.provider_id,
          ...(modelRef.provider_source ? { provider_source: modelRef.provider_source } : {})
        },
        headers: model.headers,
        maxTokens: typeof model.maxTokens === 'number' && model.maxTokens > 0 ? model.maxTokens : undefined,
        maxRetries: 2,
        maxRetryDelayMs: 2_000,
        timeoutMs: TEXT_TURN_TIMEOUT_MS
      },
      observeAgentEvent(telemetry),
      turnTimeout.signal
    )
    const latest = latestAssistantMessage(newMessages)
    if (latest?.stopReason === 'error' || latest?.stopReason === 'aborted') {
      throw new Error(
        latest.errorMessage ||
          (latest.stopReason === 'aborted' ? 'LLM provider call aborted' : 'LLM provider returned an error')
      )
    }
    const replyText = assistantText(latest)
    if (scheduleSilentSuccessRequested(replyText) && scheduleSilentSuccessAllowed(turnStart)) {
      return silentSuccessProposalWithTelemetry(telemetry)
    }
    if (!replyText) {
      throw new Error(`LLM turn completed without visible assistant text: ${summarizeAgentMessages(newMessages)}`)
    }
    return finalProposalWithTelemetry(replyText, telemetry, replyAttachmentStore)
  } finally {
    turnTimeout.cleanup()
  }
}
