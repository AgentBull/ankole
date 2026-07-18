import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type AgentConversationContextResponse, type RPCRequester } from '../../lanes/rpc_lane'
import { materializeAgentLibraryDocuments } from './agent_library_documents'

export type AgentConversationContextOptions = {
  workspaceRoot: string
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
  materializeAgentLibraryDocuments(opts.workspaceRoot, context)
  return context
}
