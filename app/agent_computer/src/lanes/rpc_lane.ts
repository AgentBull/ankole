import type { ActorEventEnvelope, ActorTurnRef } from './actor_lane'
import type { RuntimeFabricEnvelope } from '../fabric/fabric'
import type { EnvelopeSender } from '../fabric/fabric'
import type { JsonObject } from '@pleisto/active-support'
import type { InstalledSkillObservation } from '../skills/types'

/**
 * Worker-originated RuntimeFabric RPC operation registry.
 *
 * This table, `rpcOperationMeta`, and `RpcSchemaByMethod` are the Bun side of
 * the cross-language RPC contract. The Elixir side lives in
 * `Ankole.SignalsGateway.ActorRuntime.RPCLane`; both sides are pinned to the committed
 * `app/kernel/proto/ankole/runtime_fabric/v1/rpc_methods.json` by package-local
 * parity tests. Adding an operation means: one entry in each of the three
 * structures here, regenerating the JSON (`bun run gen:rpc-contract`), one
 * dispatch row plus one broker function on the Elixir side.
 */
export const rpcMethods = {
  aiGatewayApiKeyForCreateOrFindByAgent: 'ai_gateway.api_key_for.create_or_find_by_agent',
  agentConversationContextResolve: 'agent_conversation.context.resolve',
  appConfigureResolve: 'app_configure.resolve',
  codexAccountResolve: 'codex.account.resolve',
  codexAccountAuthUpdate: 'codex.account.auth.update',
  subagentDelegationCreate: 'subagent.delegation.create',
  subagentDelegationGet: 'subagent.delegation.get',
  subagentDelegationList: 'subagent.delegation.list',
  subagentDelegationSteer: 'subagent.delegation.steer',
  subagentDelegationStop: 'subagent.delegation.stop',
  subagentDelegationEventAppend: 'subagent.delegation.event.append',
  subagentDelegationStatusUpdate: 'subagent.delegation.status.update',
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

/**
 * Authorization semantics of one operation.
 *
 * `turn` operations echo the turn fence under the payload key `turn` and are
 * authorized per effect by `WorkerRouteAuth` (write additionally checks the
 * activation revision). `worker_agent` operations carry no turn fence; the
 * control-plane broker trusts the payload agent uid by design.
 */
export type RpcOperationMeta = { scope: 'worker_agent' } | { scope: 'turn'; effect: 'read' | 'write' }

export const rpcOperationMeta = {
  [rpcMethods.aiGatewayApiKeyForCreateOrFindByAgent]: { scope: 'worker_agent' },
  [rpcMethods.agentConversationContextResolve]: { scope: 'turn', effect: 'read' },
  [rpcMethods.appConfigureResolve]: { scope: 'worker_agent' },
  [rpcMethods.codexAccountResolve]: { scope: 'turn', effect: 'read' },
  [rpcMethods.codexAccountAuthUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.subagentDelegationCreate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.subagentDelegationGet]: { scope: 'turn', effect: 'read' },
  [rpcMethods.subagentDelegationList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.subagentDelegationSteer]: { scope: 'turn', effect: 'write' },
  [rpcMethods.subagentDelegationStop]: { scope: 'turn', effect: 'write' },
  [rpcMethods.subagentDelegationEventAppend]: { scope: 'turn', effect: 'write' },
  [rpcMethods.subagentDelegationStatusUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.memoryNoteSave]: { scope: 'turn', effect: 'write' },
  [rpcMethods.memoryNoteUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.memoryNoteForget]: { scope: 'turn', effect: 'write' },
  [rpcMethods.memoryNoteList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.memorySearch]: { scope: 'turn', effect: 'read' },
  [rpcMethods.memoryBrowse]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCheckBackLaterCreate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCronGet]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCronRuns]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCronAdd]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronPause]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronResume]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronRemove]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCronRun]: { scope: 'turn', effect: 'write' },
  [rpcMethods.skillsInstalledReplace]: { scope: 'turn', effect: 'write' },
  [rpcMethods.skillsOverlayResolve]: { scope: 'turn', effect: 'read' },
  [rpcMethods.skillsOverlayReplace]: { scope: 'turn', effect: 'write' }
} as const satisfies Record<RpcMethod, RpcOperationMeta>

/**
 * Wire frame of an RPC request. `method` stays `string` here because inbound
 * frames may name methods this worker build does not know; outbound method
 * safety is enforced by the typed `RuntimeRpcClient.request` signature.
 */
export type RpcRequest = {
  request_id: string
  method: string
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

export type RpcRejectedResponse = {
  code: string
  message?: string
}

/**
 * Narrows a method result union by the presence of a `code` field. Sound for
 * wire frames (`RpcResponse` never carries `code`); for unwrapped `JsonObject`
 * responses it relies on first-party brokers never emitting `code` in success
 * payloads.
 */
export function isRpcRejected(response: unknown): response is RpcRejectedResponse {
  return Boolean(
    response &&
    typeof response === 'object' &&
    'code' in response &&
    typeof (response as { code?: unknown }).code === 'string'
  )
}

export function isRpcError(response: unknown): response is RpcError {
  return isRpcRejected(response) && typeof (response as { request_id?: unknown }).request_id === 'string'
}

export function rpcRejectedMessage(label: string, response: RpcRejectedResponse): string {
  return `${label}: ${response.code} ${response.message ?? ''}`.trim()
}

export function assertRpcResponse<TResponse>(
  response: TResponse | RpcRejectedResponse,
  label: string
): asserts response is TResponse {
  if (isRpcRejected(response)) throw new Error(rpcRejectedMessage(label, response))
}

/**
 * Base payload of every turn-scoped operation: the turn fence is echoed under
 * the `turn` key and checked by control-plane `WorkerRouteAuth` before dispatch.
 */
export type TurnScopedRpcRequest = {
  request_id: string
  turn: ActorTurnRef
}

export type RuntimeSkillSummary = {
  skill_name: string
  description?: string
  default_enabled?: boolean
  source_kind?: 'builtin' | 'installed' | string
  relative_path?: string
  skill_root?: 'library' | 'internal' | string
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

export type AgentConversationContextRequest = TurnScopedRpcRequest & {
  actor_event?: ActorEventEnvelope
}

export type ScheduleCheckBackLaterCreateRequest = TurnScopedRpcRequest & {
  tool_call_id: string
  idempotency_key: string
  reason: string
  check: string
  context_summary?: string
  schedule: JsonObject
  reply_route: JsonObject
}

export type ScheduleCronListRequest = TurnScopedRpcRequest

export type ScheduleCronTargetRequest = TurnScopedRpcRequest & {
  cron_schedule_id: string
}

export type ScheduleCronRunsRequest = ScheduleCronTargetRequest & {
  limit?: number
}

export type ScheduleCronAddRequest = TurnScopedRpcRequest & {
  binding_name: string
  name?: string
  schedule: JsonObject
  payload?: JsonObject
  delivery?: JsonObject
  idempotency_key: string
  failure_policy?: JsonObject
}

export type ScheduleCronUpdateRequest = ScheduleCronTargetRequest & {
  updates: JsonObject
}

export type MemoryDelegationScope = {
  session_id: string
  signal_channel_id?: string
}

/**
 * Memory operations carry the actor event so the control plane can resolve the
 * current channel; subagent turns additionally pin their delegation scope.
 */
export type MemoryRpcRequestBase = TurnScopedRpcRequest & {
  actor_event: ActorEventEnvelope
  delegation_id?: string
  delegation_scope?: MemoryDelegationScope
}

export type MemoryNoteSaveRequest = MemoryRpcRequestBase & {
  tool_call_id: string
  content: string
}

export type MemoryNoteUpdateRequest = MemoryRpcRequestBase & {
  tool_call_id: string
  note_id: string
  content: string
}

export type MemoryNoteForgetRequest = MemoryRpcRequestBase & {
  tool_call_id: string
  note_id: string
}

export type MemoryNoteListRequest = MemoryRpcRequestBase & {
  tool_call_id: string
}

export type MemorySearchRequest = MemoryRpcRequestBase & {
  query: string
  scope?: 'current_channel' | 'permitted_context'
  from?: string
  to?: string
  limit?: number
}

export type MemoryBrowseRequest = MemoryRpcRequestBase & {
  channel_id?: string
  from?: string
  to?: string
  cursor?: string
  limit?: number
}

export type SkillOverlayRequest = TurnScopedRpcRequest & {
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

export type InstalledSkillReplaceRequest = TurnScopedRpcRequest & {
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

export type CodexAccountResolveRequest = TurnScopedRpcRequest & {
  delegation_id: string
}

export type CodexAccountResolveResponse = {
  request_id: string
  account_id: string
  auth_json: string
  auth_hash: string
}

export type CodexAccountAuthUpdateRequest = TurnScopedRpcRequest & {
  delegation_id: string
  auth_json: string
}

export type CodexAccountAuthUpdateResponse = {
  request_id: string
  account_id: string
}

export type SubagentDelegationStatus = 'queued' | 'running' | 'waiting_on_user' | 'succeeded' | 'failed' | 'stopped'

export type SubagentDelegationCreateRequest = TurnScopedRpcRequest & {
  tool_call_id: string
  title: string
  prompt: string
  workdir?: string
  output_schema?: JsonObject
  metadata?: JsonObject
}

export type SubagentDelegationGetRequest = TurnScopedRpcRequest & {
  delegation_id: string
}

export type SubagentDelegationListRequest = TurnScopedRpcRequest

export type SubagentDelegationSteerRequest = SubagentDelegationGetRequest & {
  text?: string
  answers?: Record<string, string | string[]>
}

export type SubagentDelegationStopRequest = SubagentDelegationGetRequest & {
  reason?: string
}

export type SubagentDelegationResponse = {
  request_id: string
  delegation_id: string
  agent_uid: string
  session_id: string
  actor_event_id?: string
  tool_call_id?: string
  status: SubagentDelegationStatus
  runtime_thread_id?: string
  runtime: 'codex'
  codex_account_id: string
  title: string
  prompt?: string
  reply_route: JsonObject
  attempts: number
  workdir?: string
  queued_at?: string
  started_at?: string
  completed_at?: string
  result?: JsonObject
  error?: JsonObject
  metadata?: JsonObject
  last_event_seq?: number
  attempt_history?: Array<{
    attempt: number
    event_types: string[]
    summary?: string
  }>
  result_ref?: JsonObject
}

export type SubagentDelegationSummary = Pick<
  SubagentDelegationResponse,
  'delegation_id' | 'title' | 'status' | 'runtime' | 'attempts' | 'queued_at' | 'started_at' | 'completed_at'
>

export type SubagentDelegationListResponse = {
  request_id: string
  delegations: SubagentDelegationSummary[]
}

export type SubagentDelegationAuditEvent = {
  seq: number
  direction: string
  event_type: string
  payload: JsonObject
  redaction?: JsonObject
  occurred_at?: string
}

export type SubagentDelegationEventAppendRequest = TurnScopedRpcRequest & {
  delegation_id: string
  events: SubagentDelegationAuditEvent[]
}

export type SubagentDelegationEventResponse = {
  request_id: string
  delegation_id: string
  events: Array<{ seq: number; event_id: string }>
  last_event_seq?: number
}

export type SubagentDelegationStatusUpdateRequest = TurnScopedRpcRequest & {
  delegation_id: string
  status: SubagentDelegationStatus
  runtime_thread_id?: string
  result?: JsonObject
  error?: JsonObject
  metadata?: JsonObject
}

/**
 * Request and response payload bound to each operation.
 *
 * Responses that are consumed field-by-field use precise types; schedule and
 * memory responses pass through to the model as JSON and deliberately stay
 * `JsonObject`.
 */
export type RpcSchemaByMethod = {
  [rpcMethods.aiGatewayApiKeyForCreateOrFindByAgent]: {
    request: AIGatewayApiKeyRequest
    response: AIGatewayApiKeyResponse
  }
  [rpcMethods.agentConversationContextResolve]: {
    request: AgentConversationContextRequest
    response: AgentConversationContext
  }
  [rpcMethods.appConfigureResolve]: {
    request: AppConfigureResolveRequest
    response: AppConfigureResolveResponse
  }
  [rpcMethods.codexAccountResolve]: {
    request: CodexAccountResolveRequest
    response: CodexAccountResolveResponse
  }
  [rpcMethods.codexAccountAuthUpdate]: {
    request: CodexAccountAuthUpdateRequest
    response: CodexAccountAuthUpdateResponse
  }
  [rpcMethods.subagentDelegationCreate]: {
    request: SubagentDelegationCreateRequest
    response: SubagentDelegationResponse
  }
  [rpcMethods.subagentDelegationGet]: {
    request: SubagentDelegationGetRequest
    response: SubagentDelegationResponse
  }
  [rpcMethods.subagentDelegationList]: {
    request: SubagentDelegationListRequest
    response: SubagentDelegationListResponse
  }
  [rpcMethods.subagentDelegationSteer]: {
    request: SubagentDelegationSteerRequest
    response: SubagentDelegationResponse
  }
  [rpcMethods.subagentDelegationStop]: {
    request: SubagentDelegationStopRequest
    response: SubagentDelegationResponse
  }
  [rpcMethods.subagentDelegationEventAppend]: {
    request: SubagentDelegationEventAppendRequest
    response: SubagentDelegationEventResponse
  }
  [rpcMethods.subagentDelegationStatusUpdate]: {
    request: SubagentDelegationStatusUpdateRequest
    response: SubagentDelegationResponse
  }
  [rpcMethods.memoryNoteSave]: { request: MemoryNoteSaveRequest; response: JsonObject }
  [rpcMethods.memoryNoteUpdate]: { request: MemoryNoteUpdateRequest; response: JsonObject }
  [rpcMethods.memoryNoteForget]: { request: MemoryNoteForgetRequest; response: JsonObject }
  [rpcMethods.memoryNoteList]: { request: MemoryNoteListRequest; response: JsonObject }
  [rpcMethods.memorySearch]: { request: MemorySearchRequest; response: JsonObject }
  [rpcMethods.memoryBrowse]: { request: MemoryBrowseRequest; response: JsonObject }
  [rpcMethods.scheduleCheckBackLaterCreate]: { request: ScheduleCheckBackLaterCreateRequest; response: JsonObject }
  [rpcMethods.scheduleCronList]: { request: ScheduleCronListRequest; response: JsonObject }
  [rpcMethods.scheduleCronGet]: { request: ScheduleCronTargetRequest; response: JsonObject }
  [rpcMethods.scheduleCronRuns]: { request: ScheduleCronRunsRequest; response: JsonObject }
  [rpcMethods.scheduleCronAdd]: { request: ScheduleCronAddRequest; response: JsonObject }
  [rpcMethods.scheduleCronUpdate]: { request: ScheduleCronUpdateRequest; response: JsonObject }
  [rpcMethods.scheduleCronPause]: { request: ScheduleCronTargetRequest; response: JsonObject }
  [rpcMethods.scheduleCronResume]: { request: ScheduleCronTargetRequest; response: JsonObject }
  [rpcMethods.scheduleCronRemove]: { request: ScheduleCronTargetRequest; response: JsonObject }
  [rpcMethods.scheduleCronRun]: { request: ScheduleCronTargetRequest; response: JsonObject }
  [rpcMethods.skillsInstalledReplace]: {
    request: InstalledSkillReplaceRequest
    response: InstalledSkillReplaceResponse
  }
  [rpcMethods.skillsOverlayResolve]: { request: SkillOverlayRequest; response: SkillOverlayResponse }
  [rpcMethods.skillsOverlayReplace]: { request: SkillOverlayReplaceRequest; response: SkillOverlayResponse }
}

/**
 * Shape of an injected RPC caller that converts control-plane errors into
 * thrown tool failures. The worker only packages requests and never applies
 * local fallback behavior for these operations.
 */
export type RpcRequester = <M extends RpcMethod>(
  method: M,
  payload: RpcSchemaByMethod[M]['request']
) => Promise<RpcSchemaByMethod[M]['response']>

export type ScheduleRpcMethod = Extract<RpcMethod, `schedule.${string}`>
export type MemoryRpcMethod = Extract<RpcMethod, `memory${string}`>

/**
 * Family-scoped requesters injected into schedule and memory tools. Payloads
 * are still checked per method; responses in these families are model-facing
 * passthrough JSON.
 */
export type ScheduleRpcRequester = <M extends ScheduleRpcMethod>(
  method: M,
  payload: RpcSchemaByMethod[M]['request']
) => Promise<JsonObject>

export type MemoryRpcRequester = <M extends MemoryRpcMethod>(
  method: M,
  payload: RpcSchemaByMethod[M]['request']
) => Promise<JsonObject>

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

  constructor(private readonly sendEnvelope: EnvelopeSender) {}

  /**
   * Sends one typed RPC request and waits for its reply.
   *
   * Returns the unwrapped response payload for the operation, or the RPC error
   * frame. This is the single point where wire payloads meet contract types.
   */
  async request<M extends RpcMethod>(
    method: M,
    payload: RpcSchemaByMethod[M]['request']
  ): Promise<RpcSchemaByMethod[M]['response'] | RpcError> {
    const requestId = payload.request_id
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

    const reply = await promise
    if (isRpcError(reply)) return reply
    return (reply.payload_json ?? {}) as RpcSchemaByMethod[M]['response']
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
export async function handleWorkerRpcRequest(sendEnvelope: EnvelopeSender, request: RpcRequest): Promise<void> {
  await sendEnvelope(workerRpcReplyEnvelope(dispatchWorkerRpcRequest(request), request.request_id))
}

/**
 * Dispatches RPC methods implemented by the worker process.
 *
 * There are currently no worker-owned durable RPC methods. Unknown requests are
 * answered explicitly so caller bugs are visible instead of timing out.
 */
function dispatchWorkerRpcRequest(request: RpcRequest): RpcResponse | RpcError {
  return {
    request_id: request.request_id,
    code: 'unknown_rpc_method',
    message: `unknown worker RPC method: ${request.method}`,
    details_json: {
      method: request.method
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
