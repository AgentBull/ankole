import type { JsonObject } from '@pleisto/active-support'
import type { TurnStart } from '../../lanes/actor_lane'
import type {
  AIGatewayApiKeyRejected,
  AIGatewayApiKeyRequest,
  AIGatewayApiKeyResponse,
  AppConfigureResolveRejected,
  AppConfigureResolveRequest,
  AppConfigureResolveResponse,
  CodexDelegationCreateRequest,
  CodexDelegationEventAppendRequest,
  CodexDelegationGetRequest,
  CodexDelegationRejected,
  CodexDelegationResponse,
  CodexDelegationStatusUpdateRequest
} from '../../lanes/rpc_lane'

export type CodexDelegationStatus = 'queued' | 'running' | 'waiting_on_user' | 'succeeded' | 'failed' | 'stopped'

export type CodexDelegateRequest = {
  prompt: string
  workdir?: string
  outputSchema?: unknown
}

export type CodexDelegationSnapshot = {
  delegation_id: string
  agent_uid: string
  session_id: string
  status: CodexDelegationStatus
  codex_thread_id?: string
  codex_turn_id?: string
  workdir: string
  queued_at_unix_ms: number
  started_at_unix_ms?: number
  completed_at_unix_ms?: number
  output_text?: string
  error?: string
  waiting_on_user?: JsonObject
  last_event_seq?: number
  result_ref?: JsonObject
}

export type CodexRuntimeRequesters = {
  requestAIGatewayApiKey: (
    request: AIGatewayApiKeyRequest,
    options?: { forceRefresh?: boolean }
  ) => Promise<AIGatewayApiKeyResponse | AIGatewayApiKeyRejected>
  requestAppConfigure?: (
    request: AppConfigureResolveRequest
  ) => Promise<AppConfigureResolveResponse | AppConfigureResolveRejected>
  createCodexDelegation?: (
    request: CodexDelegationCreateRequest
  ) => Promise<CodexDelegationResponse | CodexDelegationRejected>
  getCodexDelegationStatus?: (
    request: CodexDelegationGetRequest
  ) => Promise<CodexDelegationResponse | CodexDelegationRejected>
  appendCodexDelegationEvent?: (request: CodexDelegationEventAppendRequest) => Promise<unknown>
  updateCodexDelegationStatus?: (
    request: CodexDelegationStatusUpdateRequest
  ) => Promise<CodexDelegationResponse | CodexDelegationRejected>
}

export type CodexSubmitOptions = {
  turnStart: TurnStart
  workspaceRoot: string
  toolCallId: string
  request: CodexDelegateRequest
  requesters: CodexRuntimeRequesters
  signal?: AbortSignal
}

export const terminalStatuses = new Set<CodexDelegationStatus>(['succeeded', 'failed', 'stopped'])
