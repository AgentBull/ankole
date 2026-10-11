import type { AgentLoopLogger } from '../types'
import type { AIGatewayAPIKeyResponse, RPCRequester } from '../../lanes/rpc_lane'
import type { TurnSteerUpdate } from '../../lanes/actor_lane'
import type { BrowserRuntime } from '../../browser-runtime'
import type { Drive } from '../../drive/drive'

export type AIGatewayAPIKeyRequestOptions = {
  forceRefresh?: boolean
}

/**
 * AIGateway key capability of the bound Agent. It stays separate from the
 * generic RPC requester because the worker caches the key across model rounds
 * and callers force a refresh after a 401 or socket open failure.
 */
export type AIGatewayAPIKeyRequester = (options?: AIGatewayAPIKeyRequestOptions) => Promise<AIGatewayAPIKeyResponse>

/**
 * Capabilities every worker turn receives. `rpc` is the sole channel to
 * control-plane state; turn code names methods from `rpcOperations` and never
 * reaches PostgreSQL-owned semantics directly.
 */
type SharedTurnOptions = {
  agentHome: string
  workspaceRoot: string
  /** The Agent's drive in the control plane: the files that other people see or receive. */
  drive: Drive
  builtinSkillsRoot: string
  agentInstalledSkillsRoot: string
  internalSkillsRoot?: string
  /** Trusted ephemeral variables derived for this Actor turn. */
  runtimeEnv?: Record<string, string>
  rpc: RPCRequester
  requestAIGatewayAPIKey: AIGatewayAPIKeyRequester
  logger?: AgentLoopLogger
  pollSteering?: () => TurnSteerUpdate[]
  pollDisabledSkills?: () => string[]
  abortSignal?: AbortSignal
  browserRuntime?: BrowserRuntime
}

export type CodexJobOptions = SharedTurnOptions & {
  /** Internal host/test override; production uses the bounded Codex first-progress deadline. */
  firstCodexProgressTimeoutMs?: number
}
