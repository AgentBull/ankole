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
  CodexDelegationRejected,
  CodexDelegationResponse,
  CodexDelegationStatusUpdateRequest,
  SkillOverlayReplaceRequest,
  SkillOverlayRequest,
  SkillOverlayResponse
} from '../../lanes/rpc_lane'
import type { ScheduleRpcRequester } from '../../tools/schedule/schedule-tools'
import type { TurnSteerUpdate } from '../../lanes/actor_lane'

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
export type CodexDelegationEventAppendRequester = (
  request: CodexDelegationEventAppendRequest
) => Promise<CodexDelegationEventResponse | CodexDelegationRejected>
export type CodexDelegationStatusUpdateRequester = (
  request: CodexDelegationStatusUpdateRequest
) => Promise<CodexDelegationResponse | CodexDelegationRejected>
export type SkillOverlayRequester = (request: SkillOverlayRequest) => Promise<SkillOverlayResponse>
export type SkillOverlayReplaceRequester = (request: SkillOverlayReplaceRequest) => Promise<SkillOverlayResponse>

export type TurnHandlerResult = { kind: 'aigateway_response' } | { kind: 'noop_completed'; reason: string }

export type TextTurnLoopOptions = {
  workspaceRoot: string
  builtinSkillsRoot?: string
  agentInstalledSkillsRoot?: string
  requestAIGatewayApiKey: AIGatewayApiKeyRequester
  requestAppConfigure?: AppConfigureRequester
  createCodexDelegation?: CodexDelegationCreateRequester
  appendCodexDelegationEvent?: CodexDelegationEventAppendRequester
  updateCodexDelegationStatus?: CodexDelegationStatusUpdateRequester
  requestAgentConversationContext?: AgentConversationContextRequester
  requestScheduleRpc?: ScheduleRpcRequester
  requestSkillOverlay?: SkillOverlayRequester
  replaceSkillOverlay?: SkillOverlayReplaceRequester
  agentConversationContext?: AgentConversationContext
  pollSteering?: () => TurnSteerUpdate[]
  abortSignal?: AbortSignal
  extraMessages?: AgentMessage[]
}

/**
 * Returns the skill source roots when both roots are available.
 */
export function skillRootsFromOptions(
  opts: TextTurnLoopOptions
): { builtinSkillsRoot: string; agentInstalledSkillsRoot: string } | undefined {
  if (!opts.builtinSkillsRoot || !opts.agentInstalledSkillsRoot) return undefined
  return {
    builtinSkillsRoot: opts.builtinSkillsRoot,
    agentInstalledSkillsRoot: opts.agentInstalledSkillsRoot
  }
}
