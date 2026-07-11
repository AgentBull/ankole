import type { AgentMessage } from '../types'
import type {
  AgentConversationContext,
  AgentConversationContextRequest,
  AIGatewayApiKeyRequest,
  AIGatewayApiKeyResponse,
  AppConfigureResolveRequest,
  AppConfigureResolveResponse,
  CodexAccountAuthUpdateRequest,
  CodexAccountAuthUpdateResponse,
  CodexAccountResolveRequest,
  CodexAccountResolveResponse,
  SubagentDelegationCreateRequest,
  SubagentDelegationEventAppendRequest,
  SubagentDelegationEventResponse,
  SubagentDelegationGetRequest,
  SubagentDelegationListRequest,
  SubagentDelegationListResponse,
  SubagentDelegationResponse,
  SubagentDelegationStatusUpdateRequest,
  SubagentDelegationSteerRequest,
  SubagentDelegationStopRequest,
  MemoryRpcRequester,
  RpcError,
  ScheduleRpcRequester,
  SkillOverlayReplaceRequest,
  SkillOverlayRequest,
  SkillOverlayResponse
} from '../../lanes/rpc_lane'
import type { TurnSteerUpdate } from '../../lanes/actor_lane'

export type AIGatewayApiKeyRequestOptions = {
  forceRefresh?: boolean
}

export type AIGatewayApiKeyRequester = (
  request: AIGatewayApiKeyRequest,
  options?: AIGatewayApiKeyRequestOptions
) => Promise<AIGatewayApiKeyResponse | RpcError>

export type AgentConversationContextRequester = (
  request: AgentConversationContextRequest
) => Promise<AgentConversationContext>
export type AppConfigureRequester = (
  request: AppConfigureResolveRequest
) => Promise<AppConfigureResolveResponse | RpcError>
export type CodexAccountResolveRequester = (
  request: CodexAccountResolveRequest
) => Promise<CodexAccountResolveResponse | RpcError>
export type CodexAccountAuthUpdateRequester = (
  request: CodexAccountAuthUpdateRequest
) => Promise<CodexAccountAuthUpdateResponse | RpcError>
export type SubagentDelegationCreateRequester = (
  request: SubagentDelegationCreateRequest
) => Promise<SubagentDelegationResponse | RpcError>
export type SubagentDelegationGetRequester = (
  request: SubagentDelegationGetRequest
) => Promise<SubagentDelegationResponse | RpcError>
export type SubagentDelegationListRequester = (
  request: SubagentDelegationListRequest
) => Promise<SubagentDelegationListResponse | RpcError>
export type SubagentDelegationSteerRequester = (
  request: SubagentDelegationSteerRequest
) => Promise<SubagentDelegationResponse | RpcError>
export type SubagentDelegationStopRequester = (
  request: SubagentDelegationStopRequest
) => Promise<SubagentDelegationResponse | RpcError>
export type SubagentDelegationEventAppendRequester = (
  request: SubagentDelegationEventAppendRequest
) => Promise<SubagentDelegationEventResponse | RpcError>
export type SubagentDelegationStatusUpdateRequester = (
  request: SubagentDelegationStatusUpdateRequest
) => Promise<SubagentDelegationResponse | RpcError>
export type SkillOverlayRequester = (request: SkillOverlayRequest) => Promise<SkillOverlayResponse>
export type SkillOverlayReplaceRequester = (request: SkillOverlayReplaceRequest) => Promise<SkillOverlayResponse>

export type TurnHandlerResult =
  | {
      kind: 'turn_completed'
      finalResponseId: string
      outcome: 'loop_finished' | 'iteration_exhausted'
    }
  | { kind: 'noop_completed'; reason: string }

export type TextTurnLoopOptions = {
  workspaceRoot: string
  workspaceSessionsRoot?: string
  sharedFsRoot?: string
  userFilesRoot?: string
  builtinSkillsRoot?: string
  agentInstalledSkillsRoot?: string
  internalSkillsRoot?: string
  requestAIGatewayApiKey: AIGatewayApiKeyRequester
  requestAppConfigure?: AppConfigureRequester
  resolveCodexAccount?: CodexAccountResolveRequester
  updateCodexAccountAuth?: CodexAccountAuthUpdateRequester
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
  onSteeringApplied?: (update: TurnSteerUpdate) => Promise<void>
  onTurnActivity?: (description?: string) => void
  abortSignal?: AbortSignal
  extraMessages?: AgentMessage[]
}
