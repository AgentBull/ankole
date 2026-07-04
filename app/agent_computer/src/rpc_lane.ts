import type { ActorTurnRef } from './actor_lane'
import type { WorkerConfig } from './runtime'
import type { JsonObject, RuntimeFabricEnvelope } from './runtime_fabric'
import type { ReliableEnvelopeSender } from './runtime_fabric_sender'

export const rpcMethods = {
  aiGatewayApiKeyForCreateOrFindByAgent: 'ai_gateway.api_key_for.create_or_find_by_agent',
  agentConversationContextResolve: 'agent_conversation.context.resolve',
  appConfigureResolve: 'app_configure.resolve',
  scheduleCheckBackLaterCreate: 'schedule.check_back_later.create',
  scheduleCronList: 'schedule.cron.list',
  scheduleCronGet: 'schedule.cron.get',
  scheduleCronRuns: 'schedule.cron.runs',
  scheduleCronAdd: 'schedule.cron.add',
  scheduleCronUpdate: 'schedule.cron.update',
  scheduleCronPause: 'schedule.cron.pause',
  scheduleCronResume: 'schedule.cron.resume',
  scheduleCronRemove: 'schedule.cron.remove',
  scheduleCronRun: 'schedule.cron.run',
  skillsOverlayResolve: 'skills.overlay.resolve',
  skillsOverlayReplace: 'skills.overlay.replace'
} as const

export type RpcMethod = (typeof rpcMethods)[keyof typeof rpcMethods]

export type RpcRequest = {
  request_id: string
  method: RpcMethod | string
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

export type RuntimeSkillSummary = {
  skill_name: string
  description?: string
  default_enabled?: boolean
  source_kind?: 'builtin' | 'installed' | string
  relative_path?: string
  metadata?: JsonObject
  category?: string
  tags?: unknown[]
  skill_uri?: string
  has_agent_overlay?: boolean
}

export type AgentConversationContext = {
  request_id: string
  agent_uid: string
  session_id: string
  turn: ActorTurnRef
  agent?: {
    display_name?: string
    role?: string
  }
  conversation?: {
    id?: string
    key?: string
    started_at?: string | null
    timezone?: string | null
  }
  soul?: string
  mission?: string
  skills?: RuntimeSkillSummary[]
  cache_key?: string
}

export type AgentConversationContextRequest = {
  request_id: string
  turn: ActorTurnRef
}

export type ScheduleRpcRequest = JsonObject & {
  request_id: string
  turn_ref: ActorTurnRef
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

export type AIGatewayApiKeyRequest = {
  request_id: string
  agent_uid: string
}

export type AIGatewayApiKeyResponse = {
  request_id: string
  agent_uid: string
  api_key: string
  token_type: 'Bearer' | string
  expires_at: number
  expires_in: number
  scope: 'ai_gateway' | string
  base_url: string
}

export type AIGatewayApiKeyRejected = {
  request_id: string
  agent_uid: string
  code: string
  message?: string
}

export type AppConfigureResolveRequest = {
  request_id: string
  agent_uid: string
  keys: string[]
}

export type AppConfigureResolution = {
  value: unknown
  source: 'agent' | 'global' | 'default' | string
  scope?: string
}

export type AppConfigureResolveResponse = {
  request_id: string
  agent_uid: string
  values: Record<string, AppConfigureResolution>
}

export type AppConfigureResolveRejected = {
  request_id: string
  agent_uid: string
  code: string
  message?: string
}

export type RpcPayloadByMethod = {
  [rpcMethods.aiGatewayApiKeyForCreateOrFindByAgent]: AIGatewayApiKeyRequest
  [rpcMethods.agentConversationContextResolve]: AgentConversationContextRequest
  [rpcMethods.appConfigureResolve]: AppConfigureResolveRequest
  [rpcMethods.scheduleCheckBackLaterCreate]: ScheduleRpcRequest
  [rpcMethods.scheduleCronList]: ScheduleRpcRequest
  [rpcMethods.scheduleCronGet]: ScheduleRpcRequest
  [rpcMethods.scheduleCronRuns]: ScheduleRpcRequest
  [rpcMethods.scheduleCronAdd]: ScheduleRpcRequest
  [rpcMethods.scheduleCronUpdate]: ScheduleRpcRequest
  [rpcMethods.scheduleCronPause]: ScheduleRpcRequest
  [rpcMethods.scheduleCronResume]: ScheduleRpcRequest
  [rpcMethods.scheduleCronRemove]: ScheduleRpcRequest
  [rpcMethods.scheduleCronRun]: ScheduleRpcRequest
  [rpcMethods.skillsOverlayResolve]: SkillOverlayRequest
  [rpcMethods.skillsOverlayReplace]: SkillOverlayReplaceRequest
}

export const rpcTimeoutMs = 60_000

type RpcWaiter = {
  resolve: (response: RpcResponse | RpcError) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
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

export function rpcResponseEnvelopeBody(response: RpcResponse): {
  type: 'rpc_response'
  rpc_response: RpcResponse
} {
  return {
    type: 'rpc_response',
    rpc_response: response
  }
}

export function rpcErrorEnvelopeBody(error: RpcError): {
  type: 'rpc_error'
  rpc_error: RpcError
} {
  return {
    type: 'rpc_error',
    rpc_error: error
  }
}

export class RuntimeRpcClient {
  private waiters = new Map<string, RpcWaiter>()

  constructor(private readonly sendEnvelope: ReliableEnvelopeSender) {}

  async request<M extends RpcMethod>(
    method: M,
    payload: RpcPayloadByMethod[M],
    requestId: string
  ): Promise<RpcResponse | RpcError> {
    const request: RpcRequest = {
      request_id: requestId,
      method,
      payload_json: payload as JsonObject
    }

    const promise = new Promise<RpcResponse | RpcError>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.waiters.delete(requestId)
        reject(new Error(`RPC request timed out: ${method}`))
      }, rpcTimeoutMs)
      this.waiters.set(requestId, { resolve, reject, timeout })
    })

    try {
      await this.sendEnvelope({
        protocol_version: 1,
        message_id: `rpc-request-${crypto.randomUUID()}`,
        correlation_id: requestId,
        lane: 'LANE_RPC',
        durability: 'CONTROL_EPHEMERAL',
        body: rpcRequestEnvelopeBody(request)
      })
    } catch (error) {
      const waiter = this.waiters.get(requestId)
      if (waiter) {
        clearTimeout(waiter.timeout)
        this.waiters.delete(requestId)
      }
      throw error
    }

    return promise
  }

  resolve(response: RpcResponse | RpcError): void {
    const waiter = this.waiters.get(response.request_id)
    if (!waiter) return

    clearTimeout(waiter.timeout)
    this.waiters.delete(response.request_id)
    waiter.resolve(response)
  }
}

export async function handleWorkerRpcRequest(
  config: WorkerConfig,
  sendEnvelope: ReliableEnvelopeSender,
  activeTurns: number,
  request: RpcRequest
): Promise<void> {
  await sendEnvelope(workerRpcReplyEnvelope(dispatchWorkerRpcRequest(config, activeTurns, request), request.request_id))
}

export function dispatchWorkerRpcRequest(
  _config: WorkerConfig,
  _activeTurns: number,
  request: RpcRequest
): RpcResponse | RpcError {
  switch (request.method) {
    default:
      return {
        request_id: request.request_id,
        code: 'unknown_rpc_method',
        message: `unknown worker RPC method: ${request.method}`,
        details_json: {
          method: request.method
        }
      }
  }
}

function workerRpcReplyEnvelope(reply: RpcResponse | RpcError, requestId: string): RuntimeFabricEnvelope {
  return {
    protocol_version: 1,
    message_id: `rpc-reply-${crypto.randomUUID()}`,
    correlation_id: requestId,
    lane: 'LANE_RPC',
    durability: 'CONTROL_EPHEMERAL',
    body: 'code' in reply ? rpcErrorEnvelopeBody(reply) : rpcResponseEnvelopeBody(reply)
  }
}
