import type { AgentMessage } from '../types'
import type {
  AgentConversationContext,
  AgentConversationContextRequest,
  AIGatewayAPIKeyRequest,
  AIGatewayAPIKeyResponse,
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
  MemoryRPCRequester,
  RPCError,
  ScheduleRPCRequester,
  SkillOverlayAppendRequest,
  SkillOverlayReplaceRequest,
  SkillOverlayRequest,
  SkillOverlayResponse,
  WorkerEnvResolveRequest,
  WorkerEnvResolveResponse
} from '../../lanes/rpc_lane'
import type { TurnSteerUpdate } from '../../lanes/actor_lane'

export type AIGatewayAPIKeyRequestOptions = {
  forceRefresh?: boolean
}

export type AIGatewayAPIKeyRequester = (
  request: AIGatewayAPIKeyRequest,
  options?: AIGatewayAPIKeyRequestOptions
) => Promise<AIGatewayAPIKeyResponse | RPCError>

export type AgentConversationContextRequester = (
  request: AgentConversationContextRequest
) => Promise<AgentConversationContext>
export type AppConfigureRequester = (
  request: AppConfigureResolveRequest
) => Promise<AppConfigureResolveResponse | RPCError>
export type WorkerEnvRequester = (request: WorkerEnvResolveRequest) => Promise<WorkerEnvResolveResponse | RPCError>
export type CodexAccountResolveRequester = (
  request: CodexAccountResolveRequest
) => Promise<CodexAccountResolveResponse | RPCError>
export type CodexAccountAuthUpdateRequester = (
  request: CodexAccountAuthUpdateRequest
) => Promise<CodexAccountAuthUpdateResponse | RPCError>
export type SubagentDelegationCreateRequester = (
  request: SubagentDelegationCreateRequest
) => Promise<SubagentDelegationResponse | RPCError>
export type SubagentDelegationGetRequester = (
  request: SubagentDelegationGetRequest
) => Promise<SubagentDelegationResponse | RPCError>
export type SubagentDelegationListRequester = (
  request: SubagentDelegationListRequest
) => Promise<SubagentDelegationListResponse | RPCError>
export type SubagentDelegationSteerRequester = (
  request: SubagentDelegationSteerRequest
) => Promise<SubagentDelegationResponse | RPCError>
export type SubagentDelegationStopRequester = (
  request: SubagentDelegationStopRequest
) => Promise<SubagentDelegationResponse | RPCError>
export type SubagentDelegationEventAppendRequester = (
  request: SubagentDelegationEventAppendRequest
) => Promise<SubagentDelegationEventResponse | RPCError>
export type SubagentDelegationStatusUpdateRequester = (
  request: SubagentDelegationStatusUpdateRequest
) => Promise<SubagentDelegationResponse | RPCError>
export type SkillOverlayRequester = (request: SkillOverlayRequest) => Promise<SkillOverlayResponse>
export type SkillOverlayAppendRequester = (request: SkillOverlayAppendRequest) => Promise<SkillOverlayResponse>
export type SkillOverlayReplaceRequester = (request: SkillOverlayReplaceRequest) => Promise<SkillOverlayResponse>

export type TurnHandlerResult =
  | {
      kind: 'turn_completed'
      finalResponseID: string
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
  requestAIGatewayAPIKey: AIGatewayAPIKeyRequester
  requestAppConfigure?: AppConfigureRequester
  requestWorkerEnv?: WorkerEnvRequester
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
  requestScheduleRPC?: ScheduleRPCRequester
  requestMemoryRPC?: MemoryRPCRequester
  requestSkillOverlay?: SkillOverlayRequester
  appendSkillOverlay?: SkillOverlayAppendRequester
  replaceSkillOverlay?: SkillOverlayReplaceRequester
  agentConversationContext?: AgentConversationContext
  pollSteering?: () => TurnSteerUpdate[]
  onSteeringApplied?: (update: TurnSteerUpdate) => Promise<void>
  onTurnActivity?: (description?: string) => void
  abortSignal?: AbortSignal
  extraMessages?: AgentMessage[]
}
