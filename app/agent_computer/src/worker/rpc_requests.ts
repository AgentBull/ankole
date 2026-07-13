import type { JsonObject as JSONObject } from '@pleisto/active-support'
import {
  RuntimeRPCClient,
  assertRPCResponse,
  isRPCError,
  rpcMethods,
  type AgentConversationContext,
  type AgentConversationContextRequest,
  type AIGatewayAPIKeyRequest,
  type AIGatewayAPIKeyResponse,
  type InstalledSkillReplaceRequest,
  type InstalledSkillReplaceResponse,
  type RPCError,
  type RPCMethod,
  type RPCRequester,
  type RPCSchemaByMethod,
  type SkillOverlayAppendRequest,
  type SkillOverlayReplaceRequest,
  type SkillOverlayRequest,
  type SkillOverlayResponse
} from '../lanes/rpc_lane'

const aiGatewayAPIKeyRefreshSkewMs = 60_000
const aiGatewayAPIKeyCache = new Map<string, AIGatewayAPIKeyResponse>()

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
  request: AIGatewayAPIKeyRequest,
  options: { forceRefresh?: boolean } = {}
): Promise<AIGatewayAPIKeyResponse | RPCError> {
  const cacheKey = request.agent_uid
  const cached = aiGatewayAPIKeyCache.get(cacheKey)
  if (!options.forceRefresh && cached && cached.expires_at * 1000 > Date.now() + aiGatewayAPIKeyRefreshSkewMs) {
    return { ...cached, request_id: request.request_id }
  }

  const response = await rpcClient.request(rpcMethods.aiGatewayAPIKeyForCreateOrFindByAgent, request)
  if (isRPCError(response)) return response

  aiGatewayAPIKeyCache.set(cacheKey, response)
  return response
}

/**
 * Loads the prompt-facing conversation context for one turn.
 *
 * A failed context lookup is fatal because the worker must not invent agent
 * identity, skill metadata, or conversation anchors locally.
 */
export async function requestAgentConversationContext(
  rpcClient: RuntimeRPCClient,
  request: AgentConversationContextRequest
): Promise<AgentConversationContext> {
  const response = await rpcClient.request(rpcMethods.agentConversationContextResolve, request)
  assertRPCResponse<AgentConversationContext>(response, 'agent conversation context RPC failed')
  return response
}

/**
 * Builds an injected RPC caller that converts control-plane errors into thrown
 * tool failures. Schedule and memory tools consume this seam; the operations
 * mutate durable PostgreSQL-owned state, so no local fallback is applied.
 */
export function throwingRPCRequester(rpcClient: RuntimeRPCClient, label: string): RPCRequester {
  return async <M extends RPCMethod>(method: M, payload: RPCSchemaByMethod[M]['request']) => {
    const response = await rpcClient.request(method, payload)
    assertRPCResponse<RPCSchemaByMethod[M]['response']>(response, label)
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
  rpcClient: RuntimeRPCClient,
  request: SkillOverlayRequest
): Promise<SkillOverlayResponse> {
  const response = await rpcClient.request(rpcMethods.skillsOverlayResolve, request)
  assertRPCResponse<SkillOverlayResponse>(response, 'skill overlay RPC failed')
  return response
}

/** Appends one note atomically to the DB-backed overlay for an enabled skill. */
export async function appendSkillOverlay(
  rpcClient: RuntimeRPCClient,
  request: SkillOverlayAppendRequest
): Promise<SkillOverlayResponse> {
  const response = await rpcClient.request(rpcMethods.skillsOverlayAppend, request)
  assertRPCResponse<SkillOverlayResponse>(response, 'skill overlay append RPC failed')
  return response
}

/**
 * Replaces the DB-backed overlay for an enabled skill.
 *
 * The caller supplies the content hash returned by a fresh resolve so the
 * control plane can reject a stale whole-overlay replacement.
 */
export async function replaceSkillOverlay(
  rpcClient: RuntimeRPCClient,
  request: SkillOverlayReplaceRequest
): Promise<SkillOverlayResponse> {
  const response = await rpcClient.request(rpcMethods.skillsOverlayReplace, request)
  assertRPCResponse<SkillOverlayResponse>(response, 'skill overlay replace RPC failed')
  return response
}

/**
 * Replaces the agent-installed skill registry from worker filesystem observations.
 */
export async function replaceInstalledSkillObservations(
  rpcClient: RuntimeRPCClient,
  request: InstalledSkillReplaceRequest
): Promise<InstalledSkillReplaceResponse> {
  const response = await rpcClient.request(rpcMethods.skillsInstalledReplace, request)
  assertRPCResponse<InstalledSkillReplaceResponse>(response, 'installed skill registry RPC failed')
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
