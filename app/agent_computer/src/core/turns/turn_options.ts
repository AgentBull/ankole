import type { AgentLoopLogger, Message, ReplyPresentationEvent } from '../types'
import type { AgentConversationContextResponse, AIGatewayAPIKeyResponse, RPCRequester } from '../../lanes/rpc_lane'
import type { TurnSteerUpdate } from '../../lanes/actor_lane'
import type { BrowserRuntime } from '../../browser-runtime'
import type { AmbientTextTurnRoute } from '../../prompts/ambient_prompt'

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
  agentsRoot: string
  agentHome: string
  workspaceRoot: string
  userFilesRoot: string
  builtinSkillsRoot: string
  agentInstalledSkillsRoot: string
  internalSkillsRoot?: string
  /** Trusted ephemeral variables derived for this Actor turn. */
  runtimeEnv?: Record<string, string>
  rpc: RPCRequester
  requestAIGatewayAPIKey: AIGatewayAPIKeyRequester
  logger?: AgentLoopLogger
  agentConversationContext?: AgentConversationContextResponse
  pollSteering?: () => TurnSteerUpdate[]
  waitForSteering?: (signal?: AbortSignal) => Promise<void>
  onSteeringApplied?: (update: TurnSteerUpdate) => Promise<void>
  pollDisabledSkills?: () => string[]
  abortSignal?: AbortSignal
  browserRuntime?: BrowserRuntime
}

export type TextTurnLoopOptions = SharedTurnOptions & {
  onPresentationEvent?: (event: ReplyPresentationEvent) => void | Promise<void>
  extraMessages?: Message[]
  /** Trusted ambient route committed by the control plane before this Text Turn. */
  ambientRoute?: AmbientTextTurnRoute
}

export type CodexJobOptions = SharedTurnOptions & {
  onTurnActivity?: (description?: string) => void
  /** Internal host/test override; production uses the bounded Codex first-progress deadline. */
  firstCodexProgressTimeoutMs?: number
}

export type TurnHandlerOptions = TextTurnLoopOptions & CodexJobOptions
