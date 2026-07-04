import type { TurnStart } from '../../lanes/actor_lane'
import type { AgentConversationContext } from '../../lanes/rpc_lane'
import type { TextTurnLoopOptions } from './turn_options'

/**
 * Returns the already-resolved conversation context or asks the control plane.
 *
 * Tests and ambient turns can pass a context directly, but production text turns
 * must resolve it through RuntimeFabric so identity, prompt, and skill metadata
 * stay control-plane-owned.
 */
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
