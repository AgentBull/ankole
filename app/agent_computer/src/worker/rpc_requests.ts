import { aiGatewayAPIKeyRefreshSkewMs } from '../core/ai_gateway_transport'
import {
  RPCRejectedError,
  RuntimeRPCClient,
  rpcMethods,
  type AIGatewayAPIKeyResponse,
  type ControlPlaneOwnedRPCMethod,
  type RPCFrame,
  type RPCRequestInit,
  type RPCRequester,
  type RPCRejection,
  type RPCResponseOf
} from '../lanes/rpc_lane'

/** Agent-scoped key cache shared across Turns in this Worker process. */
const aiGatewayAPIKeyCache = new Map<string, AIGatewayAPIKeyResponse>()

function isRejection(value: RPCResponseOf<ControlPlaneOwnedRPCMethod> | RPCRejection): value is RPCRejection {
  return !('$typeName' in value)
}

/**
 * Builds the single RPC caller injected into turn code. It converts
 * control-plane rejections into thrown `RPCRejectedError`s and never applies
 * local fallback behavior: these operations reach durable PostgreSQL-owned
 * state.
 */
export function throwingRPCRequester(rpcClient: RuntimeRPCClient): RPCRequester {
  return async <M extends ControlPlaneOwnedRPCMethod>(
    method: M,
    payload: RPCRequestInit<M>,
    frame: RPCFrame<M>,
    options?: { timeoutMs?: number }
  ) => {
    const response = await rpcClient.request(method, payload, frame, options)
    if (isRejection(response)) throw new RPCRejectedError(method, response)
    return response
  }
}

/**
 * Resolves the agent-scoped AIGateway key over RuntimeFabric and caches it
 * until the local skew window.
 *
 * The key is scoped to the agent, not the turn, so reusing it avoids one RPC
 * per model round while still letting callers force a refresh after a 401 or
 * socket open failure.
 */
export async function requestAIGatewayAPIKey(
  rpcClient: RuntimeRPCClient,
  agentUid: string,
  options: { forceRefresh?: boolean } = {}
): Promise<AIGatewayAPIKeyResponse> {
  const method = rpcMethods.aiGatewayAPIKeyForCreateOrFindByAgent
  const cached = aiGatewayAPIKeyCache.get(agentUid)
  if (!options.forceRefresh && cached && Number(cached.expiresAt) * 1000 > Date.now() + aiGatewayAPIKeyRefreshSkewMs) {
    return cached
  }

  const response = await rpcClient.request(method, {}, { agentUid })
  if (isRejection(response)) throw new RPCRejectedError('AIGateway API key rejected', response)

  aiGatewayAPIKeyCache.set(agentUid, response)
  return response
}
