import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type AgentConversationContextResponse, type RPCRequester } from '../../lanes/rpc_lane'
import { materializeAgentLibraryDocuments } from './agent_library_documents'
import { agentHomePaths } from '../agent-home-paths'

export type AgentConversationContextOptions = {
  agentsRoot: string
  agentHome: string
  rpc: RPCRequester
  agentConversationContext?: AgentConversationContextResponse
}

/**
 * Returns the already-resolved conversation context or asks the control plane.
 *
 * Ambient turns pass the context they already resolved; production text turns
 * must resolve it through RuntimeFabric so identity, prompt, and skill metadata
 * stay control-plane-owned.
 */
export async function resolveAgentConversationContext(
  turnStart: TurnStart,
  opts: AgentConversationContextOptions
): Promise<AgentConversationContextResponse> {
  const context =
    opts.agentConversationContext ??
    (await opts.rpc(rpcMethods.agentConversationContextResolve, {}, { turn: turnStart.turn }))
  const paths = agentHomePaths(opts.agentsRoot, turnStart.turn.actor.agent_uid)
  if (paths.home !== opts.agentHome) throw new Error('turn Agent Home does not match actor identity')
  return materializeAgentLibraryDocuments(paths, context)
}
