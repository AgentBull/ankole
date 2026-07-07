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
  CodexDelegationCreateRequest,
  CodexDelegationEventAppendRequest,
  CodexDelegationEventResponse,
  CodexDelegationGetRequest,
  CodexDelegationRejected,
  CodexDelegationResponse,
  CodexDelegationStatusUpdateRequest,
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
export type CodexDelegationCreateRequester = (
  request: CodexDelegationCreateRequest
) => Promise<CodexDelegationResponse | CodexDelegationRejected>
export type CodexDelegationGetRequester = (
  request: CodexDelegationGetRequest
) => Promise<CodexDelegationResponse | CodexDelegationRejected>
export type CodexDelegationEventAppendRequester = (
  request: CodexDelegationEventAppendRequest
) => Promise<CodexDelegationEventResponse | CodexDelegationRejected>
export type CodexDelegationStatusUpdateRequester = (
  request: CodexDelegationStatusUpdateRequest
) => Promise<CodexDelegationResponse | CodexDelegationRejected>
export type SkillOverlayRequester = (request: SkillOverlayRequest) => Promise<SkillOverlayResponse>
export type SkillOverlayReplaceRequester = (request: SkillOverlayReplaceRequest) => Promise<SkillOverlayResponse>
export type MemoryRpcRequester = (method: RpcMethod, request: MemoryRpcRequest) => Promise<JsonObject>

export type TurnHandlerResult = { kind: 'aigateway_response' } | { kind: 'noop_completed'; reason: string }

export type TextTurnLoopOptions = {
  workspaceRoot: string
  builtinSkillsRoot?: string
  agentInstalledSkillsRoot?: string
  internalSkillsRoot?: string
  requestAIGatewayApiKey: AIGatewayApiKeyRequester
  requestAppConfigure?: AppConfigureRequester
  createCodexDelegation?: CodexDelegationCreateRequester
  getCodexDelegationStatus?: CodexDelegationGetRequester
  appendCodexDelegationEvent?: CodexDelegationEventAppendRequester
  updateCodexDelegationStatus?: CodexDelegationStatusUpdateRequester
  requestAgentConversationContext?: AgentConversationContextRequester
  requestScheduleRpc?: ScheduleRpcRequester
  requestMemoryRpc?: MemoryRpcRequester
  requestSkillOverlay?: SkillOverlayRequester
  replaceSkillOverlay?: SkillOverlayReplaceRequester
  agentConversationContext?: AgentConversationContext
  pollSteering?: () => TurnSteerUpdate[]
  abortSignal?: AbortSignal
  extraMessages?: AgentMessage[]
}
