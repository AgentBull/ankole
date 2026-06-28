import type { TurnStart } from '../../actor_lane'
import type { AgentConversationContext, ConversationHistoryRequest, ConversationHistoryResponse } from '../../rpc_lane'
import type { TextTurnLoopOptions } from './turn_options'

export async function resolveAgentConversationContext(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<AgentConversationContext> {
  if (opts.agentConversationContext) return opts.agentConversationContext
  if (!opts.requestAgentConversationContext) {
    throw new Error('agent conversation context RPC is required')
  }

  return await opts.requestAgentConversationContext({
    request_id: `agent-conversation-context-${crypto.randomUUID()}`,
    turn: turnStart.turn
  })
}

export async function resolveConversationHistory(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions,
  purpose: ConversationHistoryRequest['purpose']
): Promise<ConversationHistoryResponse> {
  if (opts.conversationHistory && opts.conversationHistory.purpose === purpose) return opts.conversationHistory
  if (!opts.requestConversationHistory) {
    throw new Error('conversation history RPC is required')
  }

  return await opts.requestConversationHistory({
    request_id: `conversation-history-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    purpose
  })
}
