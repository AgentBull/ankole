import { aiGatewayAPIKeyRefreshSkewMs } from '../core/ai_gateway_transport'
import {
  RPCRejectedError,
  RuntimeRPCClient,
  type AIGatewayAPIKeyResponse,
  type ControlPlaneOwnedRPCMethod,
  type RPCCallOptions,
  type RPCFrame,
  type RPCRequestInit,
  type RPCRequester,
  type RPCRejection,
  type RPCResponseOf
} from '../lanes/rpc_lane'

/** The bound Agent's key, shared across Turns in this Worker process. */
let cachedAIGatewayAPIKey: AIGatewayAPIKeyResponse | undefined

function isRejection(value: RPCResponseOf<ControlPlaneOwnedRPCMethod> | RPCRejection): value is RPCRejection {
  return !('$typeName' in value)
}

/**
 * Builds the single RPC caller injected into turn code. It converts
 * control-plane rejections into thrown `RPCRejectedError`s and never applies
 * local fallback behavior: these operations reach durable PostgreSQL-owned
 * state.
 */
export function throwingRPCRequester(rpcClient: RuntimeRPCClient, signal?: AbortSignal): RPCRequester {
  return async <M extends ControlPlaneOwnedRPCMethod>(
    method: M,
    payload: RPCRequestInit<M>,
    frame: RPCFrame<M>,
    options?: RPCCallOptions
  ) => {
    const response = await rpcClient.request(method, payload, frame, { ...options, signal: options?.signal ?? signal })
    if (isRejection(response)) throw new RPCRejectedError(method, response)
    return response
  }
}

/**
 * Resolves the bound Agent's AIGateway key over RuntimeFabric and caches it
 * until the local skew window.
 *
 * The control plane takes the Agent from the Worker connection. The key is
 * scoped to the Agent, not the turn, so reusing it avoids one RPC per model
 * round while still letting callers force a refresh after a 401 or socket
 * open failure.
 */
export async function requestAIGatewayAPIKey(
  rpcClient: RuntimeRPCClient,
  options: { forceRefresh?: boolean; signal?: AbortSignal } = {}
): Promise<AIGatewayAPIKeyResponse> {
  const method = 'ai_gateway.api_key_for.create_or_find_by_agent'
  const cached = cachedAIGatewayAPIKey
  if (!options.forceRefresh && cached && Number(cached.expiresAt) * 1000 > Date.now() + aiGatewayAPIKeyRefreshSkewMs) {
    return cached
  }

  const response = await rpcClient.request(method, {}, undefined, { retryOnDisconnect: true, signal: options.signal })
  if (isRejection(response)) throw new RPCRejectedError('AIGateway API key rejected', response)

  cachedAIGatewayAPIKey = response
  return response
}
