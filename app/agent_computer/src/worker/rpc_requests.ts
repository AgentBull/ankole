import type { JsonObject } from '@pleisto/active-support'
import {
  RuntimeRpcClient,
  assertRpcResponse,
  isRpcError,
  rpcMethods,
  type AgentConversationContext,
  type AgentConversationContextRequest,
  type AIGatewayApiKeyRequest,
  type AIGatewayApiKeyResponse,
  type InstalledSkillReplaceRequest,
  type InstalledSkillReplaceResponse,
  type RpcError,
  type RpcMethod,
  type RpcRequester,
  type RpcSchemaByMethod,
  type SkillOverlayReplaceRequest,
  type SkillOverlayRequest,
  type SkillOverlayResponse
} from '../lanes/rpc_lane'

const aiGatewayApiKeyRefreshSkewMs = 60_000
const aiGatewayApiKeyCache = new Map<string, AIGatewayApiKeyResponse>()

/**
 * Resolves the agent-scoped AIGateway key over RuntimeFabric and caches it
 * until the local skew window.
 *
 * The key is scoped to the agent, not the turn, so reusing it avoids one RPC per
 * model round while still letting callers force a refresh after a 401 or socket
 * open failure.
 */
export async function requestAIGatewayApiKey(
  rpcClient: RuntimeRpcClient,
  request: AIGatewayApiKeyRequest,
  options: { forceRefresh?: boolean } = {}
): Promise<AIGatewayApiKeyResponse | RpcError> {
  const cacheKey = request.agent_uid
  const cached = aiGatewayApiKeyCache.get(cacheKey)
  if (!options.forceRefresh && cached && cached.expires_at * 1000 > Date.now() + aiGatewayApiKeyRefreshSkewMs) {
    return { ...cached, request_id: request.request_id }
  }

  const response = await rpcClient.request(rpcMethods.aiGatewayApiKeyForCreateOrFindByAgent, request)
  if (isRpcError(response)) return response

  aiGatewayApiKeyCache.set(cacheKey, response)
  return response
}

/**
 * Loads the prompt-facing conversation context for one turn.
 *
 * A failed context lookup is fatal because the worker must not invent agent
 * identity, skill metadata, or conversation anchors locally.
 */
export async function requestAgentConversationContext(
  rpcClient: RuntimeRpcClient,
  request: AgentConversationContextRequest
): Promise<AgentConversationContext> {
  const response = await rpcClient.request(rpcMethods.agentConversationContextResolve, request)
  assertRpcResponse<AgentConversationContext>(response, 'agent conversation context RPC failed')
  return response
}

/**
 * Builds an injected RPC caller that converts control-plane errors into thrown
 * tool failures. Schedule and memory tools consume this seam; the operations
 * mutate durable PostgreSQL-owned state, so no local fallback is applied.
 */
export function throwingRpcRequester(rpcClient: RuntimeRpcClient, label: string): RpcRequester {
  return async <M extends RpcMethod>(method: M, payload: RpcSchemaByMethod[M]['request']) => {
    const response = await rpcClient.request(method, payload)
    assertRpcResponse<RpcSchemaByMethod[M]['response']>(response, label)
    return response
  }
}

/**
 * Reads the DB-backed overlay for an enabled skill.
 *
 * Skill source files live on worker storage, but per-agent additions are
 * runtime state and must be resolved through RuntimeFabric.
 */
export async function requestSkillOverlay(
  rpcClient: RuntimeRpcClient,
  request: SkillOverlayRequest
): Promise<SkillOverlayResponse> {
  const response = await rpcClient.request(rpcMethods.skillsOverlayResolve, request)
  assertRpcResponse<SkillOverlayResponse>(response, 'skill overlay RPC failed')
  return response
}

/**
 * Replaces the DB-backed overlay for an enabled skill.
 *
 * The append tool performs read-modify-write above this layer; this helper keeps
 * the RPC surface narrow and explicit.
 */
export async function replaceSkillOverlay(
  rpcClient: RuntimeRpcClient,
  request: SkillOverlayReplaceRequest
): Promise<SkillOverlayResponse> {
  const response = await rpcClient.request(rpcMethods.skillsOverlayReplace, request)
  assertRpcResponse<SkillOverlayResponse>(response, 'skill overlay replace RPC failed')
  return response
}

/**
 * Replaces the agent-installed skill registry from worker filesystem observations.
 */
export async function replaceInstalledSkillObservations(
  rpcClient: RuntimeRpcClient,
  request: InstalledSkillReplaceRequest
): Promise<InstalledSkillReplaceResponse> {
  const response = await rpcClient.request(rpcMethods.skillsInstalledReplace, request)
  assertRpcResponse<InstalledSkillReplaceResponse>(response, 'installed skill registry RPC failed')
  return response
}

/**
 * Reads a string from either an RpcError details object or a plain JSON object.
 */
export function stringFromDetails(source: RpcError | JsonObject | undefined, key: string): string | undefined {
  const details = (source && 'details_json' in source ? source.details_json : source) as JsonObject | undefined
  const value = details?.[key]
  return typeof value === 'string' ? value : undefined
}
