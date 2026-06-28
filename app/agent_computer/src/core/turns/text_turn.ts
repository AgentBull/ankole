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
import { assertCredentialMatchesTurn, providerOptionsFromCredential, runtimeModelFromCredential } from './model_runtime'
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
 * resolves credentials over the parent protocol, builds the concrete AI SDK
 * model inside Agent Computer, and lets Ankole's reusable agent loop own tool-call/result turns.
 * This keeps credentials memory-only and keeps provider-specific behavior inside
 * the migrated LLM adapter layer instead of hand-writing per-provider HTTP payloads.
 */
export async function runTextTurnLoop(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<FinalProposalBody> {
  const modelRef = turnStart.model_ref
  if (!modelRef) {
    throw new Error('LLM turn is missing a real model_ref')
  }

  const credential = await opts.requestCredential({
    request_id: `llm-credential-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    agent_uid: turnStart.turn.actor.agent_uid,
    session_id: turnStart.turn.actor.session_id,
    profile: modelRef.profile,
    purpose: 'ai_turn'
  })

  if ('code' in credential) {
    throw new Error(`credential rejected: ${credential.code} ${credential.message ?? ''}`.trim())
  }

  assertCredentialMatchesTurn(modelRef, credential)

  const model = runtimeModelFromCredential(credential)
  const providerOptions = providerOptionsFromCredential(credential, model.provider)
  const telemetry = createTurnTelemetry(credential, model)
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
          profile: credential.profile,
          provider_id: credential.provider_id,
          provider_source: credential.provider_source
        },
        headers: model.headers,
        providerOptions,
        maxTokens: model.maxTokens > 0 ? model.maxTokens : undefined,
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
