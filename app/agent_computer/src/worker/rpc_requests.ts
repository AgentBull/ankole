import type { JsonObject as JSONObject } from '@pleisto/active-support'
import {
  RuntimeRPCClient,
  assertRPCResponse,
  rpcMethods,
  type AIGatewayAPIKeyRequest,
  type AIGatewayAPIKeyResponse,
  type RPCError,
  type RPCMethod,
  type RPCRequester,
  type RPCSchemaByMethod
} from '../lanes/rpc_lane'

const aiGatewayAPIKeyRefreshSkewMs = 60_000
const aiGatewayAPIKeyCache = new Map<string, AIGatewayAPIKeyResponse>()

/**
 * Generates the wire request id for one RPC call. The id is an opaque
 * correlation token; the method-derived prefix only aids log reading.
 */
function rpcRequestID(method: RPCMethod): string {
  return `${method.replaceAll(/[^a-zA-Z0-9]+/g, '-')}-${crypto.randomUUID()}`
}

/**
 * Builds the single RPC caller injected into turn code. It generates request
 * ids, converts control-plane rejections into thrown `RPCRejectedError`s, and
 * never applies local fallback behavior: these operations reach durable
 * PostgreSQL-owned state.
 */
export function throwingRPCRequester(rpcClient: RuntimeRPCClient): RPCRequester {
  return async <M extends RPCMethod>(method: M, payload: Omit<RPCSchemaByMethod[M]['request'], 'request_id'>) => {
    // The compiler cannot prove Omit<T, K> & { K } = T for a generic T.
    const request = { ...payload, request_id: rpcRequestID(method) } as RPCSchemaByMethod[M]['request']
    const response = await rpcClient.request(method, request)
    assertRPCResponse<RPCSchemaByMethod[M]['response']>(response, method)
    return response
  }
}

/**
 * Resolves the agent-scoped AIGateway key over RuntimeFabric and caches it
 * until the local skew window.
 *
 * The key is scoped to the agent, not the turn, so reusing it avoids one RPC per
 * model round while still letting callers force a refresh after a 401 or socket
 * open failure.
 */
export async function requestAIGatewayAPIKey(
  rpcClient: RuntimeRPCClient,
  request: Omit<AIGatewayAPIKeyRequest, 'request_id'>,
  options: { forceRefresh?: boolean } = {}
): Promise<AIGatewayAPIKeyResponse> {
  const method = rpcMethods.aiGatewayAPIKeyForCreateOrFindByAgent
  const requestID = rpcRequestID(method)
  const cacheKey = request.agent_uid
  const cached = aiGatewayAPIKeyCache.get(cacheKey)
  if (!options.forceRefresh && cached && cached.expires_at * 1000 > Date.now() + aiGatewayAPIKeyRefreshSkewMs) {
    return { ...cached, request_id: requestID }
  }

  const response = await rpcClient.request(method, { ...request, request_id: requestID })
  assertRPCResponse<AIGatewayAPIKeyResponse>(response, 'AIGateway API key rejected')

  aiGatewayAPIKeyCache.set(cacheKey, response)
  return response
}

/**
 * Reads a string from either an RPCError details object or a plain JSON object.
 */
export function stringFromDetails(source: RPCError | JSONObject | undefined, key: string): string | undefined {
  const details = (source && 'details_json' in source ? source.details_json : source) as JSONObject | undefined
  const value = details?.[key]
  return typeof value === 'string' ? value : undefined
}
