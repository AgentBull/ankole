import type { JsonObject } from '@pleisto/active-support'
import {
  RuntimeRpcClient,
  assertRpcResponse,
  isRpcError,
  rpcMethods,
  type AgentConversationContext,
  type AgentConversationContextRequest,
  type AIGatewayApiKeyRejected,
  type AIGatewayApiKeyRequest,
  type AIGatewayApiKeyResponse,
  type AppConfigureResolveRejected,
  type AppConfigureResolveRequest,
  type AppConfigureResolveResponse,
  type SubagentDelegationCreateRequest,
  type SubagentDelegationEventAppendRequest,
  type SubagentDelegationEventResponse,
  type SubagentDelegationGetRequest,
  type SubagentDelegationListRequest,
  type SubagentDelegationListResponse,
  type SubagentDelegationRejected,
  type SubagentDelegationResponse,
  type SubagentDelegationStatusUpdateRequest,
  type SubagentDelegationSteerRequest,
  type SubagentDelegationStopRequest,
  type InstalledSkillReplaceRequest,
  type InstalledSkillReplaceResponse,
  type MemoryRpcRequest,
  type RpcError,
  type RpcMethod,
  type RpcResponse,
  type ScheduleRpcRequest,
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
): Promise<AIGatewayApiKeyResponse | AIGatewayApiKeyRejected> {
  const cacheKey = request.agent_uid
  const cached = aiGatewayApiKeyCache.get(cacheKey)
  if (!options.forceRefresh && cached && cached.expires_at * 1000 > Date.now() + aiGatewayApiKeyRefreshSkewMs) {
    return { ...cached, request_id: request.request_id }
  }

  const response = await rpcClient.request(
    rpcMethods.aiGatewayApiKeyForCreateOrFindByAgent,
    request,
    request.request_id
  )
  if (isRpcError(response)) {
    return {
      request_id: request.request_id,
      agent_uid: stringFromDetails(response, 'agent_uid') || request.agent_uid,
      code: response.code,
      message: response.message
    }
  }

  const apiKey = response.payload_json as AIGatewayApiKeyResponse
  aiGatewayApiKeyCache.set(cacheKey, apiKey)
  return apiKey
}

/**
 * Resolves runtime configuration keys through the control-plane owner.
 *
 * Worker code must not read operator-managed config from env after boot; values
 * such as browser backend settings are runtime facts owned outside this process.
 */
export async function requestAppConfigure(
  rpcClient: RuntimeRpcClient,
  request: AppConfigureResolveRequest
): Promise<AppConfigureResolveResponse | AppConfigureResolveRejected> {
  const response = await rpcClient.request(rpcMethods.appConfigureResolve, request, request.request_id)
  if (isRpcError(response)) {
    return {
      request_id: request.request_id,
      agent_uid: stringFromDetails(response, 'agent_uid') || request.agent_uid,
      code: response.code,
      message: response.message
    }
  }

  return response.payload_json as AppConfigureResolveResponse
}

export async function createSubagentDelegation(
  rpcClient: RuntimeRpcClient,
  request: SubagentDelegationCreateRequest
): Promise<SubagentDelegationResponse | SubagentDelegationRejected> {
  return requestSubagent<SubagentDelegationCreateRequest, SubagentDelegationResponse>(
    rpcClient,
    rpcMethods.subagentDelegationCreate,
    request
  )
}

export async function getSubagentDelegation(
  rpcClient: RuntimeRpcClient,
  request: SubagentDelegationGetRequest
): Promise<SubagentDelegationResponse | SubagentDelegationRejected> {
  return requestSubagent<SubagentDelegationGetRequest, SubagentDelegationResponse>(
    rpcClient,
    rpcMethods.subagentDelegationGet,
    request
  )
}

export async function listSubagentDelegations(
  rpcClient: RuntimeRpcClient,
  request: SubagentDelegationListRequest
): Promise<SubagentDelegationListResponse | SubagentDelegationRejected> {
  return requestSubagent<SubagentDelegationListRequest, SubagentDelegationListResponse>(
    rpcClient,
    rpcMethods.subagentDelegationList,
    request
  )
}

export async function steerSubagentDelegation(
  rpcClient: RuntimeRpcClient,
  request: SubagentDelegationSteerRequest
): Promise<SubagentDelegationResponse | SubagentDelegationRejected> {
  return requestSubagent<SubagentDelegationSteerRequest, SubagentDelegationResponse>(
    rpcClient,
    rpcMethods.subagentDelegationSteer,
    request
  )
}

export async function stopSubagentDelegation(
  rpcClient: RuntimeRpcClient,
  request: SubagentDelegationStopRequest
): Promise<SubagentDelegationResponse | SubagentDelegationRejected> {
  return requestSubagent<SubagentDelegationStopRequest, SubagentDelegationResponse>(
    rpcClient,
    rpcMethods.subagentDelegationStop,
    request
  )
}

export async function appendSubagentDelegationEvents(
  rpcClient: RuntimeRpcClient,
  request: SubagentDelegationEventAppendRequest
): Promise<SubagentDelegationEventResponse | SubagentDelegationRejected> {
  return requestSubagent<SubagentDelegationEventAppendRequest, SubagentDelegationEventResponse>(
    rpcClient,
    rpcMethods.subagentDelegationEventAppend,
    request
  )
}

export async function updateSubagentDelegationStatus(
  rpcClient: RuntimeRpcClient,
  request: SubagentDelegationStatusUpdateRequest
): Promise<SubagentDelegationResponse | SubagentDelegationRejected> {
  return requestSubagent<SubagentDelegationStatusUpdateRequest, SubagentDelegationResponse>(
    rpcClient,
    rpcMethods.subagentDelegationStatusUpdate,
    request
  )
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
  const response = await rpcClient.request(rpcMethods.agentConversationContextResolve, request, request.request_id)
  assertRpcResponse<RpcResponse>(response, 'agent conversation context RPC failed')
  return response.payload_json as AgentConversationContext
}

/**
 * Sends a schedule RPC and converts control-plane errors into tool failures.
 *
 * Scheduling changes are durable PostgreSQL-owned state, so the worker only
 * packages the request and never applies local fallback behavior.
 */
export async function requestScheduleRpc(
  rpcClient: RuntimeRpcClient,
  method: RpcMethod,
  request: ScheduleRpcRequest
): Promise<JsonObject> {
  const response = await rpcClient.request(method, request as never, request.request_id)
  assertRpcResponse<RpcResponse>(response, 'schedule RPC failed')
  return (response.payload_json ?? {}) as JsonObject
}

/**
 * Sends a Memory RPC and converts control-plane errors into tool failures.
 */
export async function requestMemoryRpc(
  rpcClient: RuntimeRpcClient,
  method: RpcMethod,
  request: MemoryRpcRequest
): Promise<JsonObject> {
  const response = await rpcClient.request(method, request as never, request.request_id)
  assertRpcResponse<RpcResponse>(response, 'memory RPC failed')
  return (response.payload_json ?? {}) as JsonObject
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
  const response = await rpcClient.request(rpcMethods.skillsOverlayResolve, request, request.request_id)
  assertRpcResponse<RpcResponse>(response, 'skill overlay RPC failed')
  return response.payload_json as SkillOverlayResponse
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
  const response = await rpcClient.request(rpcMethods.skillsOverlayReplace, request, request.request_id)
  assertRpcResponse<RpcResponse>(response, 'skill overlay replace RPC failed')
  return response.payload_json as SkillOverlayResponse
}

/**
 * Replaces the agent-installed skill registry from worker filesystem observations.
 */
export async function replaceInstalledSkillObservations(
  rpcClient: RuntimeRpcClient,
  request: InstalledSkillReplaceRequest
): Promise<InstalledSkillReplaceResponse> {
  const response = await rpcClient.request(rpcMethods.skillsInstalledReplace, request, request.request_id)
  assertRpcResponse<RpcResponse>(response, 'installed skill registry RPC failed')
  return response.payload_json as InstalledSkillReplaceResponse
}

/**
 * Reads a string from either an RpcError details object or a plain JSON object.
 */
export function stringFromDetails(source: RpcError | JsonObject | undefined, key: string): string | undefined {
  const details = (source && 'details_json' in source ? source.details_json : source) as JsonObject | undefined
  const value = details?.[key]
  return typeof value === 'string' ? value : undefined
}

async function requestSubagent<TRequest extends { request_id: string }, TResponse>(
  rpcClient: RuntimeRpcClient,
  method: RpcMethod,
  request: TRequest
): Promise<TResponse | SubagentDelegationRejected> {
  const response = await rpcClient.request(method, request as never, request.request_id)
  if (isRpcError(response)) return subagentRejected(response, request)
  return response.payload_json as TResponse
}

function subagentRejected(response: RpcError, request: { request_id: string }): SubagentDelegationRejected {
  return {
    request_id: request.request_id,
    code: response.code,
    message: response.message
  }
}
