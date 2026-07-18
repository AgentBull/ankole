import type { AgentMessage, ReplyPresentationEvent } from '../types'
import type { AgentConversationContextResponse, AIGatewayAPIKeyResponse, RPCRequester } from '../../lanes/rpc_lane'
import type { TurnSteerUpdate } from '../../lanes/actor_lane'
import type { BrowserRuntime } from '../../browser-runtime'

export type AIGatewayAPIKeyRequestOptions = {
  forceRefresh?: boolean
}

/**
 * Agent-scoped AIGateway key capability. It stays separate from the generic
 * RPC requester because the worker caches the key across model rounds and
 * callers force a refresh after a 401 or socket open failure.
 */
export type AIGatewayAPIKeyRequester = (
  agentUid: string,
  options?: AIGatewayAPIKeyRequestOptions
) => Promise<AIGatewayAPIKeyResponse>

export type TurnHandlerResult =
  | {
      kind: 'turn_completed'
      finalResponseID: string
      outcome: 'loop_finished' | 'iteration_exhausted'
    }
  | { kind: 'noop_completed'; reason: string }

/**
 * Capabilities every worker turn receives. `rpc` is the sole channel to
 * control-plane state; turn code names methods from `rpcMethods` and never
 * reaches PostgreSQL-owned semantics directly.
 */
type SharedTurnOptions = {
  workspaceRoot: string
  builtinSkillsRoot: string
  agentInstalledSkillsRoot: string
  internalSkillsRoot?: string
  rpc: RPCRequester
  requestAIGatewayAPIKey: AIGatewayAPIKeyRequester
  agentConversationContext?: AgentConversationContextResponse
  pollSteering?: () => TurnSteerUpdate[]
  abortSignal?: AbortSignal
  browserRuntime?: BrowserRuntime
}

export type TextTurnLoopOptions = SharedTurnOptions & {
  onPresentationEvent?: (event: ReplyPresentationEvent) => void | Promise<void>
  extraMessages?: AgentMessage[]
}

export type CodexJobOptions = SharedTurnOptions & {
  workspaceSessionsRoot: string
  sharedFsRoot: string
  userFilesRoot: string
  onSteeringApplied?: (update: TurnSteerUpdate) => Promise<void>
  onTurnActivity?: (description?: string) => void
}

export type TurnHandlerOptions = TextTurnLoopOptions & CodexJobOptions
