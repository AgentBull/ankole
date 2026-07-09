import type { AgentMessage } from '../types'
import type {
  AgentConversationContext,
  AgentConversationContextRequest,
  AIGatewayApiKeyRejected,
  AIGatewayApiKeyRequest,
  AIGatewayApiKeyResponse,
  AppConfigureResolveRejected,
  AppConfigureResolveRequest,
  AppConfigureResolveResponse,
  SubagentDelegationCreateRequest,
  SubagentDelegationEventAppendRequest,
  SubagentDelegationEventResponse,
  SubagentDelegationGetRequest,
  SubagentDelegationListRequest,
  SubagentDelegationListResponse,
  SubagentDelegationRejected,
  SubagentDelegationResponse,
  SubagentDelegationStatusUpdateRequest,
  SubagentDelegationSteerRequest,
  SubagentDelegationStopRequest,
  MemoryRpcRequest,
  RpcMethod,
  SkillOverlayReplaceRequest,
  SkillOverlayRequest,
  SkillOverlayResponse
} from '../../lanes/rpc_lane'
import type { ScheduleRpcRequester } from '../../tools/schedule/schedule-tools'
import type { TurnSteerUpdate } from '../../lanes/actor_lane'
import type { JsonObject } from '@pleisto/active-support'

export type AIGatewayApiKeyRequestOptions = {
  forceRefresh?: boolean
}

export type AIGatewayApiKeyRequester = (
  request: AIGatewayApiKeyRequest,
  options?: AIGatewayApiKeyRequestOptions
) => Promise<AIGatewayApiKeyResponse | AIGatewayApiKeyRejected>

export type AgentConversationContextRequester = (
  request: AgentConversationContextRequest
) => Promise<AgentConversationContext>
export type AppConfigureRequester = (
  request: AppConfigureResolveRequest
) => Promise<AppConfigureResolveResponse | AppConfigureResolveRejected>
export type SubagentDelegationCreateRequester = (
  request: SubagentDelegationCreateRequest
) => Promise<SubagentDelegationResponse | SubagentDelegationRejected>
export type SubagentDelegationGetRequester = (
  request: SubagentDelegationGetRequest
) => Promise<SubagentDelegationResponse | SubagentDelegationRejected>
export type SubagentDelegationListRequester = (
  request: SubagentDelegationListRequest
) => Promise<SubagentDelegationListResponse | SubagentDelegationRejected>
export type SubagentDelegationSteerRequester = (
  request: SubagentDelegationSteerRequest
) => Promise<SubagentDelegationResponse | SubagentDelegationRejected>
export type SubagentDelegationStopRequester = (
  request: SubagentDelegationStopRequest
) => Promise<SubagentDelegationResponse | SubagentDelegationRejected>
export type SubagentDelegationEventAppendRequester = (
  request: SubagentDelegationEventAppendRequest
) => Promise<SubagentDelegationEventResponse | SubagentDelegationRejected>
export type SubagentDelegationStatusUpdateRequester = (
  request: SubagentDelegationStatusUpdateRequest
) => Promise<SubagentDelegationResponse | SubagentDelegationRejected>
export type SkillOverlayRequester = (request: SkillOverlayRequest) => Promise<SkillOverlayResponse>
export type SkillOverlayReplaceRequester = (request: SkillOverlayReplaceRequest) => Promise<SkillOverlayResponse>
export type MemoryRpcRequester = (method: RpcMethod, request: MemoryRpcRequest) => Promise<JsonObject>

export type TurnHandlerResult = { kind: 'aigateway_response' } | { kind: 'noop_completed'; reason: string }

export type TextTurnLoopOptions = {
  workspaceRoot: string
  workspaceSessionsRoot?: string
  userFilesRoot?: string
  builtinSkillsRoot?: string
  agentInstalledSkillsRoot?: string
  internalSkillsRoot?: string
  requestAIGatewayApiKey: AIGatewayApiKeyRequester
  requestAppConfigure?: AppConfigureRequester
  createSubagentDelegation?: SubagentDelegationCreateRequester
  getSubagentDelegation?: SubagentDelegationGetRequester
  listSubagentDelegations?: SubagentDelegationListRequester
  steerSubagentDelegation?: SubagentDelegationSteerRequester
  stopSubagentDelegation?: SubagentDelegationStopRequester
  appendSubagentDelegationEvents?: SubagentDelegationEventAppendRequester
  updateSubagentDelegationStatus?: SubagentDelegationStatusUpdateRequester
  requestAgentConversationContext?: AgentConversationContextRequester
  requestScheduleRpc?: ScheduleRpcRequester
  requestMemoryRpc?: MemoryRpcRequester
  requestSkillOverlay?: SkillOverlayRequester
  replaceSkillOverlay?: SkillOverlayReplaceRequester
  agentConversationContext?: AgentConversationContext
  pollSteering?: () => TurnSteerUpdate[]
  onTurnActivity?: (description?: string) => void
  abortSignal?: AbortSignal
  extraMessages?: AgentMessage[]
}
