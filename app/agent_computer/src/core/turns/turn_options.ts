import type { AgentMessage } from '../types'
import type {
  AgentConversationContext,
  AgentConversationContextRequest,
  ConversationHistoryRequest,
  ConversationHistoryResponse,
  ConversationSummaryCommitRequest,
  ConversationSummaryCommitResponse,
  ConversationSummaryCommitRejected,
  AIGatewayApiKeyRejected,
  AIGatewayApiKeyRequest,
  AIGatewayApiKeyResponse,
  SkillOverlayReplaceRequest,
  SkillOverlayRequest,
  SkillOverlayResponse
} from '../../rpc_lane'
import type { ScheduleRpcRequester } from '../../tools/schedule-tools'
import type { FinalProposalBody } from '../../turn_envelopes'
import type { TurnSteerUpdate } from '../../actor_lane'

export type AIGatewayApiKeyRequester = (
  request: AIGatewayApiKeyRequest
) => Promise<AIGatewayApiKeyResponse | AIGatewayApiKeyRejected>

export type AgentConversationContextRequester = (
  request: AgentConversationContextRequest
) => Promise<AgentConversationContext>
export type ConversationHistoryRequester = (request: ConversationHistoryRequest) => Promise<ConversationHistoryResponse>
export type ConversationSummaryCommitter = (
  request: ConversationSummaryCommitRequest
) => Promise<ConversationSummaryCommitResponse | ConversationSummaryCommitRejected>
export type SkillOverlayRequester = (request: SkillOverlayRequest) => Promise<SkillOverlayResponse>
export type SkillOverlayReplaceRequester = (request: SkillOverlayReplaceRequest) => Promise<SkillOverlayResponse>

export type TurnHandlerResult = FinalProposalBody | { summaryCommitted: boolean }

export type TextTurnLoopOptions = {
  workspaceRoot: string
  builtinSkillsRoot?: string
  agentInstalledSkillsRoot?: string
  requestAIGatewayApiKey: AIGatewayApiKeyRequester
  requestAgentConversationContext?: AgentConversationContextRequester
  requestConversationHistory?: ConversationHistoryRequester
  commitConversationSummary?: ConversationSummaryCommitter
  requestScheduleRpc?: ScheduleRpcRequester
  requestSkillOverlay?: SkillOverlayRequester
  replaceSkillOverlay?: SkillOverlayReplaceRequester
  clearSkillOverlay?: SkillOverlayRequester
  agentConversationContext?: AgentConversationContext
  conversationHistory?: ConversationHistoryResponse
  pollSteering?: () => TurnSteerUpdate[]
  abortSignal?: AbortSignal
  maxSteps?: number
  extraMessages?: AgentMessage[]
}

export function skillRootsFromOptions(
  opts: TextTurnLoopOptions
): { builtinSkillsRoot: string; agentInstalledSkillsRoot: string } | undefined {
  if (!opts.builtinSkillsRoot || !opts.agentInstalledSkillsRoot) return undefined
  return {
    builtinSkillsRoot: opts.builtinSkillsRoot,
    agentInstalledSkillsRoot: opts.agentInstalledSkillsRoot
  }
}
