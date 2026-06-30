import type { TurnStart } from '../../actor_lane'
import { createCombinedAbortSignal } from '../../common/async'
import { lastNonEmpty } from '../../common/json-utils'
import { runAgentLoop } from '../agent-loop'
import {
  buildCompactionHistoryUserPrompt,
  COMPACTION_FOCUS_INSTRUCTIONS,
  SUMMARIZATION_SYSTEM_PROMPT
} from '../../prompts/compression-prompt'
import { visibleReplyProposal } from '../../turn_envelopes'
import { conversationContextFromHistory, selectCompressionPrefix } from './conversation_history'
import { runtimeModelFromAIGatewayApiKey } from './model_runtime'
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

  const apiKeyRequest = {
    request_id: `ai-gateway-key-${crypto.randomUUID()}`,
    agent_uid: turnStart.turn.actor.agent_uid
  }
  const apiKey = await opts.requestAIGatewayApiKey(apiKeyRequest)

  if ('code' in apiKey) {
    throw new Error(`AIGateway API key rejected: ${apiKey.code} ${apiKey.message ?? ''}`.trim())
  }

  const lightModelRef = { profile: 'light', provider_id: 'ai_gateway', model: 'light' }
  const model = runtimeModelFromAIGatewayApiKey(lightModelRef, apiKey, 'light', () =>
    opts.requestAIGatewayApiKey({
      ...apiKeyRequest,
      request_id: `ai-gateway-key-${crypto.randomUUID()}`
    })
  )
  const telemetry = createTurnTelemetry(lightModelRef, model)

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
          profile: lightModelRef.profile,
          provider_id: lightModelRef.provider_id,
          purpose: 'compression'
        },
        headers: model.headers,
        maxTokens: typeof model.maxTokens === 'number' && model.maxTokens > 0 ? model.maxTokens : undefined,
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

    const commitResult = await opts.commitConversationSummary({
      request_id: `conversation-summary-${crypto.randomUUID()}`,
      turn: turnRefAfterSteeringDrain(turnStart, opts.pollSteering?.() ?? []),
      summary: {
        text: summaryText,
        covered_message_ids: compaction.coveredMessageIds
      },
      ...(telemetry.usage ? { usage_json: telemetry.usage } : {}),
      provider_metadata_json: telemetry.providerMetadata
    })

    if ('code' in commitResult) {
      // The control plane refused the summary commit (stale fence, lease mismatch, concurrent
      // change, or conversation ended). The summary is an optimization, not durable truth — the
      // un-compressed transcript still lives in PostgreSQL and the next turn rebuilds context from
      // it — so do NOT fail the turn. Record the rejection and complete as a benign no-op.
      console.warn(`conversation summary commit rejected: ${commitResult.code} ${commitResult.message ?? ''}`.trim())
      return { summaryCommitted: false }
    }

    return { summaryCommitted: true }
  } finally {
    turnTimeout.cleanup()
  }
}
