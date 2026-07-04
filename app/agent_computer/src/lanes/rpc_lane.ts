import type { ActorEventEnvelope, ActorTurnRef } from './actor_lane'
import type { WorkerConfig } from '../worker/config'
import type { JsonObject, RuntimeFabricEnvelope } from '../fabric/fabric'
import type { ReliableEnvelopeSender } from '../fabric/sender'

export const rpcMethods = {
  aiGatewayApiKeyForCreateOrFindByAgent: 'ai_gateway.api_key_for.create_or_find_by_agent',
  agentConversationContextResolve: 'agent_conversation.context.resolve',
  appConfigureResolve: 'app_configure.resolve',
  codexDelegationCreate: 'codex.delegation.create',
  codexDelegationGet: 'codex.delegation.get',
  codexDelegationEventAppend: 'codex.delegation.event.append',
  codexDelegationStatusUpdate: 'codex.delegation.status.update',
  memoryNoteSave: 'memory_note.save',
  memoryNoteUpdate: 'memory_note.update',
  memoryNoteForget: 'memory_note.forget',
  memoryNoteList: 'memory_note.list',
  memorySearch: 'memory_search',
  memoryBrowse: 'memory_browse',
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
  skillsInstalledReplace: 'skills.installed.replace',
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
  memory_notes?: RuntimeMemoryNote[]
  skills?: RuntimeSkillSummary[]
  cache_key?: string
}

export type RuntimeMemoryNote = {
  id: string
  agent_uid?: string
  channel_id?: string
  content: string
  source?: JsonObject
  created_at?: string | null
  updated_at?: string | null
}

export type AgentConversationContextRequest = {
  request_id: string
  turn: ActorTurnRef
  actor_event?: ActorEventEnvelope
}

export type ScheduleRpcRequest = JsonObject & {
  request_id: string
  turn_ref: ActorTurnRef
}

export type MemoryRpcRequest = JsonObject & {
  request_id: string
  turn_ref: ActorTurnRef
  actor_event: ActorEventEnvelope
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

export type InstalledSkillObservation = {
  skill_name: string
  relative_path?: string
  description: string
  default_enabled?: boolean
  metadata?: JsonObject
  content_hash?: string
  xxh3_128?: string
  file_count?: number
}

export type InstalledSkillReplaceRequest = {
  request_id: string
  turn: ActorTurnRef
  observations: InstalledSkillObservation[]
}

export type InstalledSkillReplaceResponse = {
  request_id: string
  agent_uid: string
  session_id: string
  changed: boolean
  skills: number
  files: number
  content_hash: string
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

export type CodexDelegationCreateRequest = {
  request_id: string
  agent_uid: string
  session_id: string
  actor_event_id?: string
  tool_call_id?: string
  workdir?: string
  status?: string
  metadata?: JsonObject
}

export type CodexDelegationGetRequest = {
  request_id: string
  delegation_id: string
  agent_uid: string
}

export type CodexDelegationResponse = {
  request_id: string
  delegation_id: string
  agent_uid: string
  session_id: string
  status: string
  codex_thread_id?: string
  workdir?: string
  queued_at?: string
  started_at?: string
  completed_at?: string
  result?: JsonObject
  error?: JsonObject
  metadata?: JsonObject
  last_event_seq?: number
  result_ref?: JsonObject
}

export type CodexDelegationEventAppendRequest = {
  request_id: string
  delegation_id: string
  agent_uid: string
  seq: number
  direction: string
  event_type: string
  payload: JsonObject
  redaction?: JsonObject
  occurred_at?: string
}

export type CodexDelegationEventResponse = {
  request_id: string
  delegation_id: string
  agent_uid: string
  seq: number
  event_id: string
}

export type CodexDelegationStatusUpdateRequest = {
  request_id: string
  delegation_id: string
  agent_uid: string
  status: string
  codex_thread_id?: string
  result?: JsonObject
  error?: JsonObject
  metadata?: JsonObject
}

export type CodexDelegationRejected = {
  request_id: string
  agent_uid: string
  code: string
  message?: string
}

export type RpcPayloadByMethod = {
  [rpcMethods.aiGatewayApiKeyForCreateOrFindByAgent]: AIGatewayApiKeyRequest
  [rpcMethods.agentConversationContextResolve]: AgentConversationContextRequest
  [rpcMethods.appConfigureResolve]: AppConfigureResolveRequest
  [rpcMethods.codexDelegationCreate]: CodexDelegationCreateRequest
  [rpcMethods.codexDelegationGet]: CodexDelegationGetRequest
  [rpcMethods.codexDelegationEventAppend]: CodexDelegationEventAppendRequest
  [rpcMethods.codexDelegationStatusUpdate]: CodexDelegationStatusUpdateRequest
  [rpcMethods.memoryNoteSave]: MemoryRpcRequest
  [rpcMethods.memoryNoteUpdate]: MemoryRpcRequest
  [rpcMethods.memoryNoteForget]: MemoryRpcRequest
  [rpcMethods.memoryNoteList]: MemoryRpcRequest
  [rpcMethods.memorySearch]: MemoryRpcRequest
  [rpcMethods.memoryBrowse]: MemoryRpcRequest
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
  [rpcMethods.skillsInstalledReplace]: InstalledSkillReplaceRequest
  [rpcMethods.skillsOverlayResolve]: SkillOverlayRequest
  [rpcMethods.skillsOverlayReplace]: SkillOverlayReplaceRequest
}

export const rpcTimeoutMs = 60_000

type RpcWaiter = {
  resolve: (response: RpcResponse | RpcError) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
}

/**
 * Wraps a worker-originated RPC request in the RuntimeFabric body shape.
 */
export function rpcRequestEnvelopeBody(request: RpcRequest): {
  type: 'rpc_request'
  rpc_request: RpcRequest
} {
  return {
    type: 'rpc_request',
    rpc_request: request
  }
}

/**
 * Wraps a successful RPC response in the RuntimeFabric body shape.
 */
export function rpcResponseEnvelopeBody(response: RpcResponse): {
  type: 'rpc_response'
  rpc_response: RpcResponse
} {
  return {
    type: 'rpc_response',
    rpc_response: response
  }
}

/**
 * Wraps an RPC error in the RuntimeFabric body shape.
 */
export function rpcErrorEnvelopeBody(error: RpcError): {
  type: 'rpc_error'
  rpc_error: RpcError
} {
  return {
    type: 'rpc_error',
    rpc_error: error
  }
}

/**
 * Tracks worker-originated RuntimeFabric RPC calls until the matching response
 * or error envelope arrives.
 *
 * RPC is control-lane traffic, not durable actor truth. The timeout prevents a
 * missing control-plane reply from parking the turn loop forever.
 */
export class RuntimeRpcClient {
  private waiters = new Map<string, RpcWaiter>()

  constructor(private readonly sendEnvelope: ReliableEnvelopeSender) {}

  /**
   * Sends one typed RPC request and waits for its reply.
   */
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

  /**
   * Resolves a pending waiter from an incoming RPC response or error envelope.
   */
  resolve(response: RpcResponse | RpcError): void {
    const waiter = this.waiters.get(response.request_id)
    if (!waiter) return

    clearTimeout(waiter.timeout)
    this.waiters.delete(response.request_id)
    waiter.resolve(response)
  }
}

/**
 * Handles a control-plane-originated RPC request by sending an RPC reply.
 */
export async function handleWorkerRpcRequest(
  config: WorkerConfig,
  sendEnvelope: ReliableEnvelopeSender,
  activeTurns: number,
  request: RpcRequest
): Promise<void> {
  await sendEnvelope(workerRpcReplyEnvelope(dispatchWorkerRpcRequest(config, activeTurns, request), request.request_id))
}

/**
 * Dispatches RPC methods implemented by the worker process.
 *
 * There are currently no worker-owned durable RPC methods. Unknown requests are
 * answered explicitly so caller bugs are visible instead of timing out.
 */
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

/**
 * Builds the RuntimeFabric envelope for an RPC reply.
 */
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
