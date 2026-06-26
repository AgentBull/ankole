import type { JsonObject } from './runtime_fabric'
import type { ActorTurnRef } from './actor_lane'

export const rpcMethods = {
  llmProviderResolveCredential: 'llm_provider.resolve_credential',
  agentProfileResolve: 'agent_profile.resolve',
  runtimeTurnContextResolve: 'runtime.turn_context.resolve',
  skillsOverlayResolve: 'skills.overlay.resolve',
  skillsOverlayReplace: 'skills.overlay.replace',
  skillsOverlayClear: 'skills.overlay.clear'
} as const

export type RpcMethod = (typeof rpcMethods)[keyof typeof rpcMethods]

export type RpcRequest = {
  request_id: string
  method: RpcMethod
  deadline_unix_ms?: number
  payload_json?: JsonObject
}

export type RpcResponse = {
  request_id: string
  payload_json?: JsonObject
}

export type RpcError = {
  request_id: string
  code: string
  message?: string
  details_json?: JsonObject
}

export type AgentProfile = {
  request_id: string
  agent_uid: string
  display_name: string
  role?: string
}

export type AgentProfileRequest = {
  request_id: string
  turn: ActorTurnRef
  agent_uid: string
  session_id: string
}

export type RuntimeSkillSummary = {
  skill_name: string
  description?: string
  default_enabled?: boolean
  source_kind?: 'builtin' | 'installed' | string
  relative_path?: string
  metadata?: JsonObject
  category?: string
  tags?: unknown[]
  file_path?: string
  has_agent_overlay?: boolean
}

export type RuntimeConversationMessage = {
  id?: string
  role?: string
  kind?: string
  content?: unknown
  metadata?: JsonObject
  inserted_at?: string | null
}

export type TurnRuntimeContext = {
  request_id: string
  agent_uid: string
  session_id: string
  turn: ActorTurnRef
  soul?: string
  mission?: string
  skills?: RuntimeSkillSummary[]
  conversation?: {
    messages?: RuntimeConversationMessage[]
  }
  overlay_digest?: string
}

export type TurnContextRequest = {
  request_id: string
  turn: ActorTurnRef
}

export type SkillOverlayRequest = {
  request_id: string
  turn: ActorTurnRef
  skill_name: string
}

export type SkillOverlayReplaceRequest = SkillOverlayRequest & {
  content: string
  overlay_json?: JsonObject
}

export type SkillOverlayResponse = {
  request_id: string
  agent_uid: string
  session_id: string
  skill_name: string
  has_overlay: boolean
  overlay_json: JsonObject
  content_hash?: string
}

export type LlmProviderCredentialRequest = {
  request_id: string
  turn: ActorTurnRef
  agent_uid: string
  session_id: string
  profile: string
  purpose: 'ai_turn' | 'codex_subagent' | 'live_check'
}

export type LlmProviderCredentialResponse = {
  request_id: string
  agent_uid: string
  session_id: string
  profile: string
  provider_id: string
  provider_source: string
  model: string
  base_url?: string
  connection_options_json?: JsonObject
  provider_options_json?: JsonObject
  credential: string
  credential_mode: string
  source_metadata_json?: JsonObject
}

export type LlmProviderCredentialRejected = {
  request_id: string
  agent_uid: string
  session_id: string
  profile: string
  code: string
  message?: string
}

export type RpcPayloadByMethod = {
  [rpcMethods.llmProviderResolveCredential]: LlmProviderCredentialRequest
  [rpcMethods.agentProfileResolve]: AgentProfileRequest
  [rpcMethods.runtimeTurnContextResolve]: TurnContextRequest
  [rpcMethods.skillsOverlayResolve]: SkillOverlayRequest
  [rpcMethods.skillsOverlayReplace]: SkillOverlayReplaceRequest
  [rpcMethods.skillsOverlayClear]: SkillOverlayRequest
}

export function rpcRequestEnvelopeBody(request: RpcRequest): {
  type: 'rpc_request'
  rpc_request: RpcRequest
} {
  return {
    type: 'rpc_request',
    rpc_request: request
  }
}
