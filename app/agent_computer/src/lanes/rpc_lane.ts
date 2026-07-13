import type { ActorEventEnvelope, ActorTurnRef } from './actor_lane'
import type { RuntimeFabricEnvelope } from '../fabric/fabric'
import type { EnvelopeSender } from '../fabric/fabric'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { InstalledSkillObservation } from '../skills/types'

/**
 * Worker-originated RuntimeFabric RPC operation registry.
 *
 * This table, `rpcOperationMeta`, and `RPCSchemaByMethod` are the Bun side of
 * the cross-language RPC contract. The Elixir side lives in
 * `Ankole.SignalsGateway.ActorRuntime.RPCLane`; both sides are pinned to the committed
 * `app/kernel/proto/ankole/runtime_fabric/v1/rpc_methods.json` by package-local
 * parity tests. Adding an operation means: one entry in each of the three
 * structures here, regenerating the JSON (`bun run gen:rpc-contract`), one
 * dispatch row plus one broker function on the Elixir side.
 */
export const rpcMethods = {
  aiGatewayAPIKeyForCreateOrFindByAgent: 'ai_gateway.api_key_for.create_or_find_by_agent',
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
  memorySearch: 'memory_search',
  memoryBrowse: 'memory_browse',
  memoryOpen: 'memory_open',
  memoryUpdate: 'memory_update',
  memoryHealthCheck: 'memory_health_check',
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
  skillsOverlayAppend: 'skills.overlay.append',
  skillsOverlayResolve: 'skills.overlay.resolve',
  skillsOverlayReplace: 'skills.overlay.replace',
  workerEnvResolve: 'worker_env.resolve'
} as const

export type RPCMethod = (typeof rpcMethods)[keyof typeof rpcMethods]

/**
 * Authorization semantics of one operation.
 *
 * `turn` operations echo the turn fence under the payload key `turn` and are
 * authorized per effect by `WorkerRouteAuth` (write additionally checks the
 * activation revision). `worker_agent` operations carry no turn fence; the
 * control-plane broker trusts the payload agent uid by design.
 */
export type RPCOperationMeta = { scope: 'worker_agent' } | { scope: 'turn'; effect: 'read' | 'write' }

export const rpcOperationMeta = {
  [rpcMethods.aiGatewayAPIKeyForCreateOrFindByAgent]: { scope: 'worker_agent' },
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
  [rpcMethods.memorySearch]: { scope: 'turn', effect: 'read' },
  [rpcMethods.memoryBrowse]: { scope: 'turn', effect: 'read' },
  [rpcMethods.memoryOpen]: { scope: 'turn', effect: 'read' },
  [rpcMethods.memoryUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.memoryHealthCheck]: { scope: 'turn', effect: 'read' },
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
  [rpcMethods.skillsOverlayAppend]: { scope: 'turn', effect: 'write' },
  [rpcMethods.skillsOverlayResolve]: { scope: 'turn', effect: 'read' },
  [rpcMethods.skillsOverlayReplace]: { scope: 'turn', effect: 'write' },
  [rpcMethods.workerEnvResolve]: { scope: 'worker_agent' }
} as const satisfies Record<RPCMethod, RPCOperationMeta>

/**
 * Wire frame of an RPC request. `method` stays `string` here because inbound
 * frames may name methods this worker build does not know; outbound method
 * safety is enforced by the typed `RuntimeRpcClient.request` signature.
 */
export type RPCRequest = {
  request_id: string
  method: string
  deadline_unix_ms?: number
  payload_json?: JSONObject
}

export type RPCResponse = {
  request_id: string
  payload_json?: JSONObject
}

export type RPCError = {
  request_id: string
  code: string
  message?: string
  details_json?: JSONObject
}

export type RPCRejectedResponse = {
  code: string
  message?: string
}

/**
 * Narrows a method result union by the presence of a `code` field. Sound for
 * wire frames (`RPCResponse` never carries `code`); for unwrapped `JSONObject`
 * responses it relies on first-party brokers never emitting `code` in success
 * payloads.
 */
export function isRPCRejected(response: unknown): response is RPCRejectedResponse {
  return Boolean(
    response &&
    typeof response === 'object' &&
    'code' in response &&
    typeof (response as { code?: unknown }).code === 'string'
  )
}

export function isRPCError(response: unknown): response is RPCError {
  return isRPCRejected(response) && typeof (response as { request_id?: unknown }).request_id === 'string'
}

export function rpcRejectedMessage(label: string, response: RPCRejectedResponse): string {
  return `${label}: ${response.code} ${response.message ?? ''}`.trim()
}

export function assertRPCResponse<TResponse>(
  response: TResponse | RPCRejectedResponse,
  label: string
): asserts response is TResponse {
  if (isRPCRejected(response)) throw new Error(rpcRejectedMessage(label, response))
}

/**
 * Base payload of every turn-scoped operation: the turn fence is echoed under
 * the `turn` key and checked by control-plane `WorkerRouteAuth` before dispatch.
 */
export type TurnScopedRPCRequest = {
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
  metadata?: JSONObject
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
  brain_snapshot?: RuntimeBrainSnapshot
  skills?: RuntimeSkillSummary[]
}

export type RuntimeBrainSnapshotEntry = {
  entry_id: string
  name: string
  markdown: string
  truncated: boolean
  store?: string
  type?: string
  lock_version?: number
  estimated_tokens?: number
}

export type RuntimeBrainSnapshot = {
  pinned_memo?: RuntimeBrainSnapshotEntry | null
  channel_entry?: RuntimeBrainSnapshotEntry | null
}

export type AgentConversationContextRequest = TurnScopedRPCRequest & {
  actor_event?: ActorEventEnvelope
}

export type ScheduleCheckBackLaterCreateRequest = TurnScopedRPCRequest & {
  tool_call_id: string
  idempotency_key: string
  reason: string
  check: string
  context_summary?: string
  quiet_success?: boolean
  schedule: JSONObject
  reply_route: JSONObject
}

export type ScheduleCronListRequest = TurnScopedRPCRequest

export type ScheduleCronTargetRequest = TurnScopedRPCRequest & {
  cron_schedule_id: string
}

export type ScheduleCronRunsRequest = ScheduleCronTargetRequest & {
  limit?: number
}

export type ScheduleCronAddRequest = TurnScopedRPCRequest & {
  binding_name: string
  name?: string
  schedule: JSONObject
  payload?: JSONObject
  delivery?: JSONObject
  idempotency_key: string
  failure_policy?: JSONObject
}

export type ScheduleCronUpdateRequest = ScheduleCronTargetRequest & {
  updates: JSONObject
}

export type MemoryDelegationScope = {
  session_id: string
  signal_channel_id?: string
}

/**
 * Brain operations carry the actor event so the control plane can resolve the
 * current channel; subagent turns additionally pin their delegation scope.
 */
export type MemoryRPCRequestBase = TurnScopedRPCRequest & {
  actor_event: ActorEventEnvelope
  delegation_id?: string
  delegation_scope?: MemoryDelegationScope
}

export type MemorySearchRequest = MemoryRPCRequestBase & {
  query: string
  layer?: 'chat' | 'knowledge' | 'all'
  channel_scope?: 'current_channel' | 'all_channels'
  channel_id?: string
  from?: string
  to?: string
  store?: 'current' | 'public'
  entry_type?: string
  author_kind?: 'human' | 'agent' | 'dreaming'
  limit?: number
}

export type MemoryBrowseRequest = MemoryRPCRequestBase & {
  document_id?: string
  channel_id?: string
  from?: string
  to?: string
  cursor?: string
  limit?: number
}

export type MemoryOpenRequest = MemoryRPCRequestBase & {
  entry_id?: string
  name?: string
  store?: 'current' | 'public'
  block_cursor?: string
  block_limit?: number
}

export type MemoryUpdateOperation =
  | {
      operation: 'create_entry'
      name: string
      type: string
      summary?: string
      aliases?: string[]
      properties?: JSONObject
    }
  | {
      operation: 'delete_entry'
      entry_id: string
      expected_entry_lock_version: number
    }
  | {
      operation: 'append_block'
      entry_id: string
      body: string
      expected_entry_lock_version: number
    }
  | {
      operation: 'edit_block'
      entry_id: string
      block_id: string
      body: string
      expected_block_lock_version: number
    }
  | {
      operation: 'delete_block'
      entry_id: string
      block_id: string
      expected_block_lock_version: number
    }
  | {
      operation: 'set_property'
      entry_id: string
      key: string
      value: unknown
      expected_entry_lock_version: number
    }
  | {
      operation: 'add_relation'
      entry_id: string
      target_entry_id: string
      predicate: string
      expected_entry_lock_version: number
    }
  | {
      operation: 'remove_relation'
      entry_id: string
      relation_id: string
      expected_entry_lock_version: number
    }
  | {
      operation: 'set_summary'
      entry_id: string
      summary: string
      expected_entry_lock_version: number
    }
  | {
      operation: 'set_aliases'
      entry_id: string
      aliases: string[]
      expected_entry_lock_version: number
    }

export type MemoryUpdateRequest = MemoryRPCRequestBase &
  MemoryUpdateOperation & {
    tool_call_id: string
  }

export type MemoryHealthCheckRequest = MemoryRPCRequestBase

export type SkillOverlayRequest = TurnScopedRPCRequest & {
  skill_name: string
}

export type SkillOverlayAppendRequest = SkillOverlayRequest & {
  content: string
}

export type SkillOverlayReplaceRequest = SkillOverlayRequest & {
  content: string
  overlay_json?: JSONObject
  expected_content_hash: string
}

export type SkillOverlayResponse = {
  request_id: string
  agent_uid: string
  session_id: string
  skill_name: string
  has_overlay: boolean
  overlay_json: JSONObject
  content_hash: string
}

export type InstalledSkillReplaceRequest = TurnScopedRPCRequest & {
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

export type AIGatewayAPIKeyRequest = {
  request_id: string
  agent_uid: string
}

export type AIGatewayAPIKeyResponse = {
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

export type WorkerEnvResolveRequest = {
  request_id: string
  agent_uid: string
}

/** Merged operator shell environment; secrets arrive decrypted and stay in memory. */
export type WorkerEnvResolveResponse = {
  request_id: string
  agent_uid: string
  vars: Record<string, string>
}

export type CodexAccountResolveRequest = TurnScopedRPCRequest & {
  delegation_id: string
}

export type CodexAccountResolveResponse = {
  request_id: string
  account_id: string
  auth_json: string
  auth_hash: string
}

export type CodexAccountAuthUpdateRequest = TurnScopedRPCRequest & {
  delegation_id: string
  auth_json: string
}

export type CodexAccountAuthUpdateResponse = {
  request_id: string
  account_id: string
}

export type SubagentDelegationStatus = 'queued' | 'running' | 'waiting_on_user' | 'succeeded' | 'failed' | 'stopped'

export type SubagentDelegationCreateRequest = TurnScopedRPCRequest & {
  tool_call_id: string
  title: string
  task: string
  background?: string
  notes?: string
  workdir?: string
  output_schema?: JSONObject
  metadata?: JSONObject
}

export type SubagentDelegationGetRequest = TurnScopedRPCRequest & {
  delegation_id: string
}

export type SubagentDelegationListRequest = TurnScopedRPCRequest

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
  runtime: 'task_worker'
  codex_account_id: string
  title: string
  task: string
  background?: string
  notes?: string
  reply_route: JSONObject
  attempts: number
  workdir?: string
  queued_at?: string
  started_at?: string
  completed_at?: string
  result?: JSONObject
  error?: JSONObject
  metadata?: JSONObject
  last_event_seq?: number
  attempt_history?: Array<{
    attempt: number
    event_types: string[]
    summary?: string
  }>
  result_ref?: JSONObject
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
  payload: JSONObject
  redaction?: JSONObject
  occurred_at?: string
}

export type SubagentDelegationEventAppendRequest = TurnScopedRPCRequest & {
  delegation_id: string
  events: SubagentDelegationAuditEvent[]
}

export type SubagentDelegationEventResponse = {
  request_id: string
  delegation_id: string
  events: Array<{ seq: number; event_id: string }>
  last_event_seq?: number
}

export type SubagentDelegationStatusUpdateRequest = TurnScopedRPCRequest & {
  delegation_id: string
  status: SubagentDelegationStatus
  runtime_thread_id?: string
  result?: JSONObject
  error?: JSONObject
  metadata?: JSONObject
}

/**
 * Request and response payload bound to each operation.
 *
 * Responses that are consumed field-by-field use precise types; schedule and
 * memory responses pass through to the model as JSON and deliberately stay
 * `JSONObject`.
 */
export type RPCSchemaByMethod = {
  [rpcMethods.aiGatewayAPIKeyForCreateOrFindByAgent]: {
    request: AIGatewayAPIKeyRequest
    response: AIGatewayAPIKeyResponse
  }
  [rpcMethods.agentConversationContextResolve]: {
    request: AgentConversationContextRequest
    response: AgentConversationContext
  }
  [rpcMethods.appConfigureResolve]: {
    request: AppConfigureResolveRequest
    response: AppConfigureResolveResponse
  }
  [rpcMethods.workerEnvResolve]: {
    request: WorkerEnvResolveRequest
    response: WorkerEnvResolveResponse
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
  [rpcMethods.memorySearch]: { request: MemorySearchRequest; response: JSONObject }
  [rpcMethods.memoryBrowse]: { request: MemoryBrowseRequest; response: JSONObject }
  [rpcMethods.memoryOpen]: { request: MemoryOpenRequest; response: JSONObject }
  [rpcMethods.memoryUpdate]: { request: MemoryUpdateRequest; response: JSONObject }
  [rpcMethods.memoryHealthCheck]: { request: MemoryHealthCheckRequest; response: JSONObject }
  [rpcMethods.scheduleCheckBackLaterCreate]: { request: ScheduleCheckBackLaterCreateRequest; response: JSONObject }
  [rpcMethods.scheduleCronList]: { request: ScheduleCronListRequest; response: JSONObject }
  [rpcMethods.scheduleCronGet]: { request: ScheduleCronTargetRequest; response: JSONObject }
  [rpcMethods.scheduleCronRuns]: { request: ScheduleCronRunsRequest; response: JSONObject }
  [rpcMethods.scheduleCronAdd]: { request: ScheduleCronAddRequest; response: JSONObject }
  [rpcMethods.scheduleCronUpdate]: { request: ScheduleCronUpdateRequest; response: JSONObject }
  [rpcMethods.scheduleCronPause]: { request: ScheduleCronTargetRequest; response: JSONObject }
  [rpcMethods.scheduleCronResume]: { request: ScheduleCronTargetRequest; response: JSONObject }
  [rpcMethods.scheduleCronRemove]: { request: ScheduleCronTargetRequest; response: JSONObject }
  [rpcMethods.scheduleCronRun]: { request: ScheduleCronTargetRequest; response: JSONObject }
  [rpcMethods.skillsInstalledReplace]: {
    request: InstalledSkillReplaceRequest
    response: InstalledSkillReplaceResponse
  }
  [rpcMethods.skillsOverlayAppend]: { request: SkillOverlayAppendRequest; response: SkillOverlayResponse }
  [rpcMethods.skillsOverlayResolve]: { request: SkillOverlayRequest; response: SkillOverlayResponse }
  [rpcMethods.skillsOverlayReplace]: { request: SkillOverlayReplaceRequest; response: SkillOverlayResponse }
}

/**
 * Shape of an injected RPC caller that converts control-plane errors into
 * thrown tool failures. The worker only packages requests and never applies
 * local fallback behavior for these operations.
 */
export type RPCRequester = <M extends RPCMethod>(
  method: M,
  payload: RPCSchemaByMethod[M]['request']
) => Promise<RPCSchemaByMethod[M]['response']>

export type ScheduleRPCMethod = Extract<RPCMethod, `schedule.${string}`>
export type MemoryRPCMethod = Extract<RPCMethod, `memory${string}`>

/**
 * Family-scoped requesters injected into schedule and memory tools. Payloads
 * are still checked per method; responses in these families are model-facing
 * passthrough JSON.
 */
export type ScheduleRPCRequester = <M extends ScheduleRPCMethod>(
  method: M,
  payload: RPCSchemaByMethod[M]['request']
) => Promise<JSONObject>

export type MemoryRPCRequester = <M extends MemoryRPCMethod>(
  method: M,
  payload: RPCSchemaByMethod[M]['request']
) => Promise<JSONObject>

export const rpcTimeoutMs = 60_000

type RPCWaiter = {
  resolve: (response: RPCResponse | RPCError) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
}

/**
 * Wraps a worker-originated RPC request in the RuntimeFabric body shape.
 */
export function rpcRequestEnvelopeBody(request: RPCRequest): {
  type: 'rpc_request'
  rpc_request: RPCRequest
} {
  return {
    type: 'rpc_request',
    rpc_request: request
  }
}

/**
 * Wraps a successful RPC response in the RuntimeFabric body shape.
 */
export function rpcResponseEnvelopeBody(response: RPCResponse): {
  type: 'rpc_response'
  rpc_response: RPCResponse
} {
  return {
    type: 'rpc_response',
    rpc_response: response
  }
}

/**
 * Wraps an RPC error in the RuntimeFabric body shape.
 */
export function rpcErrorEnvelopeBody(error: RPCError): {
  type: 'rpc_error'
  rpc_error: RPCError
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
export class RuntimeRPCClient {
  private waiters = new Map<string, RPCWaiter>()

  constructor(private readonly sendEnvelope: EnvelopeSender) {}

  /**
   * Sends one typed RPC request and waits for its reply.
   *
   * Returns the unwrapped response payload for the operation, or the RPC error
   * frame. This is the single point where wire payloads meet contract types.
   */
  async request<M extends RPCMethod>(
    method: M,
    payload: RPCSchemaByMethod[M]['request']
  ): Promise<RPCSchemaByMethod[M]['response'] | RPCError> {
    const requestID = payload.request_id
    const request: RPCRequest = {
      request_id: requestID,
      method,
      payload_json: payload as JSONObject
    }

    const promise = new Promise<RPCResponse | RPCError>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.waiters.delete(requestID)
        reject(new Error(`RPC request timed out: ${method}`))
      }, rpcTimeoutMs)
      this.waiters.set(requestID, { resolve, reject, timeout })
    })

    try {
      await this.sendEnvelope({
        protocol_version: 1,
        message_id: `rpc-request-${crypto.randomUUID()}`,
        correlation_id: requestID,
        lane: 'LANE_RPC',
        durability: 'CONTROL_EPHEMERAL',
        body: rpcRequestEnvelopeBody(request)
      })
    } catch (error) {
      const waiter = this.waiters.get(requestID)
      if (waiter) {
        clearTimeout(waiter.timeout)
        this.waiters.delete(requestID)
      }
      throw error
    }

    const reply = await promise
    if (isRPCError(reply)) return reply
    return (reply.payload_json ?? {}) as RPCSchemaByMethod[M]['response']
  }

  /**
   * Resolves a pending waiter from an incoming RPC response or error envelope.
   */
  resolve(response: RPCResponse | RPCError): void {
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
export async function handleWorkerRPCRequest(sendEnvelope: EnvelopeSender, request: RPCRequest): Promise<void> {
  await sendEnvelope(workerRPCReplyEnvelope(dispatchWorkerRPCRequest(request), request.request_id))
}

/**
 * Dispatches RPC methods implemented by the worker process.
 *
 * There are currently no worker-owned durable RPC methods. Unknown requests are
 * answered explicitly so caller bugs are visible instead of timing out.
 */
function dispatchWorkerRPCRequest(request: RPCRequest): RPCResponse | RPCError {
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
function workerRPCReplyEnvelope(reply: RPCResponse | RPCError, requestID: string): RuntimeFabricEnvelope {
  return {
    protocol_version: 1,
    message_id: `rpc-reply-${crypto.randomUUID()}`,
    correlation_id: requestID,
    lane: 'LANE_RPC',
    durability: 'CONTROL_EPHEMERAL',
    body: 'code' in reply ? rpcErrorEnvelopeBody(reply) : rpcResponseEnvelopeBody(reply)
  }
}
