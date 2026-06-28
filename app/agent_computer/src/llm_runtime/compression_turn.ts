import type { TurnStart } from '../actor_lane'
import { createCombinedAbortSignal } from '../common/async'
import { lastNonEmpty } from '../common/json-utils'
import { runAgentLoop } from '../core'
import {
  buildCompactionHistoryUserPrompt,
  COMPACTION_FOCUS_INSTRUCTIONS,
  SUMMARIZATION_SYSTEM_PROMPT
} from '../prompts/compression-prompt'
import { visibleReplyProposal } from '../turn_envelopes'
import { conversationContextFromHistory, selectCompressionPrefix } from './conversation_history'
import { providerOptionsFromCredential, runtimeModelFromCredential } from './model_runtime'
import { COMPRESSION_TURN_TIMEOUT_MS } from './turn_config'
import { turnRefAfterSteeringDrain } from './turn_control'
import { resolveAgentConversationContext, resolveConversationHistory } from './turn_context'
import {
  assistantText,
  isLlmMessage,
  latestAssistantMessage,
  serializeConversationForCompression,
  stripCompactionScratch,
  summarizeAgentMessages,
  userMessage
} from './turn_messages'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'
import { createTurnTelemetry, observeAgentEvent } from './turn_telemetry'

export async function runCompressionTurn(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<TurnHandlerResult> {
  const agentConversationContext = await resolveAgentConversationContext(turnStart, opts)
  const history = await resolveConversationHistory(turnStart, opts, 'compression')
  const conversation = conversationContextFromHistory(history, undefined, agentConversationContext, {
    excludeActorInputIds: new Set(turnStart.inputs.map(input => input.actor_input_id))
  })
  const compaction = selectCompressionPrefix(conversation.compressibleMessages)

  if (!compaction) {
    return visibleReplyProposal('Conversation already fits in the active context.')
  }

  const credential = await opts.requestCredential({
    request_id: `llm-credential-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    agent_uid: turnStart.turn.actor.agent_uid,
    session_id: turnStart.turn.actor.session_id,
    profile: 'light',
    purpose: 'compression'
  })

  if ('code' in credential) {
    throw new Error(`credential rejected: ${credential.code} ${credential.message ?? ''}`.trim())
  }

  const model = runtimeModelFromCredential(credential)
  const providerOptions = providerOptionsFromCredential(credential, model.provider)
  const telemetry = createTurnTelemetry(credential, model)

  const prompt = buildCompactionHistoryUserPrompt({
    conversationText: serializeConversationForCompression(compaction.messages),
    customInstructions: COMPACTION_FOCUS_INSTRUCTIONS,
    previousChatHistory: lastNonEmpty(conversation.previousChatHistorySummaries)
  })

  const turnTimeout = createCombinedAbortSignal(opts.abortSignal, COMPRESSION_TURN_TIMEOUT_MS)
  try {
    const newMessages = await runAgentLoop(
      [userMessage(prompt)],
      {
        systemPrompt: SUMMARIZATION_SYSTEM_PROMPT,
        messages: [],
        tools: []
      },
      {
        model,
        convertToLlm: messages => messages.flatMap(message => (isLlmMessage(message) ? [message] : [])),
        maxTurns: 1,
        metadata: {
          agent_uid: turnStart.turn.actor.agent_uid,
          conversation_id: turnStart.turn.actor.session_id,
          llm_turn_id: turnStart.turn.llm_turn_id,
          profile: credential.profile,
          provider_id: credential.provider_id,
          provider_source: credential.provider_source,
          purpose: 'compression'
        },
        headers: model.headers,
        providerOptions,
        maxTokens: model.maxTokens > 0 ? model.maxTokens : undefined,
        maxRetries: 2,
        maxRetryDelayMs: 2_000,
        timeoutMs: COMPRESSION_TURN_TIMEOUT_MS
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

    const summaryText = stripCompactionScratch(assistantText(latest))
    if (!summaryText) {
      throw new Error(`Compression turn completed without summary text: ${summarizeAgentMessages(newMessages)}`)
    }

    if (!opts.commitConversationSummary) {
      throw new Error('conversation summary commit RPC is required')
    }

    await opts.commitConversationSummary({
      request_id: `conversation-summary-${crypto.randomUUID()}`,
      turn: turnRefAfterSteeringDrain(turnStart, opts.pollSteering?.() ?? []),
      summary: {
        text: summaryText,
        covered_message_ids: compaction.coveredMessageIds
      },
      ...(telemetry.usage ? { usage_json: telemetry.usage } : {}),
      provider_metadata_json: telemetry.providerMetadata
    })

    return { summaryCommitted: true }
  } finally {
    turnTimeout.cleanup()
  }
}
