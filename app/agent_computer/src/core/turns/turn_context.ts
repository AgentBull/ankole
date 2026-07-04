import type { TurnStart } from '../../actor_lane'
import type { AgentConversationContext } from '../../rpc_lane'
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
