import { create } from '@bufbuild/protobuf'
import type { ActorEventEnvelope, ActorTurnRef } from './actor_lane'
import type { EnvelopeSender } from '../fabric/fabric'
import {
  createEnvelope,
  DurabilityClass,
  envelopeHeader,
  jsonBytes,
  jsonObjectFromBytes,
  Lane,
  RPCErrorSchema,
  RPCRequestSchema,
  RPCResponseSchema,
  safeNumberFromBigInt,
  type Envelope,
  type RPCErrorMessage,
  type RPCRequestMessage,
  type RPCResponseMessage
} from '../fabric/envelope_proto'
import { jsonObject, type JsonObject as JSONObject } from '@pleisto/active-support'
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
  agentPluginList: 'agent_plugin.list',
  backgroundAgentJobCreate: 'background_agent_job.create',
  backgroundAgentJobGet: 'background_agent_job.get',
  backgroundAgentJobList: 'background_agent_job.list',
  backgroundAgentJobSteer: 'background_agent_job.steer',
  backgroundAgentJobStop: 'background_agent_job.stop',
  backgroundAgentJobTurnUpsert: 'background_agent_job.turn.upsert',
  backgroundAgentJobStatusUpdate: 'background_agent_job.status.update',
  memorySearch: 'memory_search',
  memoryBrowse: 'memory_browse',
  memoryOpen: 'memory_open',
  memoryUpdate: 'memory_update',
  memoryHealthCheck: 'memory_health_check',
  scheduleCheckBackLaterCreate: 'schedule.check_back_later.create',
  scheduleCheckBackLaterList: 'schedule.check_back_later.list',
  scheduleCheckBackLaterGet: 'schedule.check_back_later.get',
  scheduleCheckBackLaterUpdate: 'schedule.check_back_later.update',
  scheduleCheckBackLaterCancel: 'schedule.check_back_later.cancel',
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
  [rpcMethods.agentPluginList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.backgroundAgentJobCreate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.backgroundAgentJobGet]: { scope: 'turn', effect: 'read' },
  [rpcMethods.backgroundAgentJobList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.backgroundAgentJobSteer]: { scope: 'turn', effect: 'write' },
  [rpcMethods.backgroundAgentJobStop]: { scope: 'turn', effect: 'write' },
  [rpcMethods.backgroundAgentJobTurnUpsert]: { scope: 'turn', effect: 'write' },
  [rpcMethods.backgroundAgentJobStatusUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.memorySearch]: { scope: 'turn', effect: 'read' },
  [rpcMethods.memoryBrowse]: { scope: 'turn', effect: 'read' },
  [rpcMethods.memoryOpen]: { scope: 'turn', effect: 'read' },
  [rpcMethods.memoryUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.memoryHealthCheck]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCheckBackLaterCreate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCheckBackLaterList]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCheckBackLaterGet]: { scope: 'turn', effect: 'read' },
  [rpcMethods.scheduleCheckBackLaterUpdate]: { scope: 'turn', effect: 'write' },
  [rpcMethods.scheduleCheckBackLaterCancel]: { scope: 'turn', effect: 'write' },
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

/**
 * Thrown when the control plane rejects an RPC operation. Carries the rejection
 * frame so callers that map rejection codes onto domain errors keep typed
 * access instead of parsing the message.
 */
export class RPCRejectedError extends Error {
  constructor(
    label: string,
    readonly rejection: RPCRejectedResponse
  ) {
    super(rpcRejectedMessage(label, rejection))
  }
}

export function assertRPCResponse<TResponse>(
  response: TResponse | RPCRejectedResponse,
  label: string
): asserts response is TResponse {
  if (isRPCRejected(response)) throw new RPCRejectedError(label, response)
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
  agent_plugin_id?: string
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
  design?: string
  /** Exact system instructions captured by the first stored Response in this conversation. */
  system_prompt_snapshot?: string
  brain_snapshot?: RuntimeBrainSnapshot
  skills?: RuntimeSkillSummary[]
}

export type RuntimeBrainSnapshotEntry = {
  resident_text: string
  truncated: boolean
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

export type ScheduleCheckBackLaterListRequest = TurnScopedRPCRequest & {
  limit?: number
}

export type ScheduleCheckBackLaterTargetRequest = TurnScopedRPCRequest & {
  scheduled_event_id: string
}

export type ScheduleCheckBackLaterUpdateRequest = ScheduleCheckBackLaterTargetRequest & {
  tool_call_id: string
  idempotency_key: string
  updates: JSONObject
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

export type MemoryJobScope = {
  session_id: string
  signal_channel_id?: string
}

/**
 * Brain operations carry the actor event so the control plane can resolve the
 * current channel; Job turns additionally pin their owner scope.
 */
export type MemoryRPCRequestBase = TurnScopedRPCRequest & {
  actor_event: ActorEventEnvelope
  job_id?: string
  job_scope?: MemoryJobScope
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
  job_id: string
}

export type CodexAccountResolveResponse = {
  request_id: string
  account_id: string
  auth_json: string
  auth_hash: string
}

export type CodexAccountAuthUpdateRequest = TurnScopedRPCRequest & {
  job_id: string
  auth_json: string
}

export type CodexAccountAuthUpdateResponse = {
  request_id: string
  account_id: string
}

export type AgentPluginCatalogSkill = {
  catalog_name: string
  codex_name: string
}

export type AgentPluginCatalogEntry = {
  id: string
  description: string
  version: string
  content_hash: string
  skills: AgentPluginCatalogSkill[]
}

export type AgentPluginListRequest = TurnScopedRPCRequest

export type AgentPluginListResponse = {
  request_id: string
  agent_uid: string
  agent_plugins: AgentPluginCatalogEntry[]
}

export type BackgroundAgentJobStatus = 'queued' | 'running' | 'waiting_on_user' | 'succeeded' | 'failed' | 'stopped'

const backgroundAgentJobStatuses = new Set<BackgroundAgentJobStatus>([
  'queued',
  'running',
  'waiting_on_user',
  'succeeded',
  'failed',
  'stopped'
])

export type BackgroundAgentJobWorkspaceMount = {
  id: string
  source: string
  access: 'read_only' | 'read_write'
}

type BackgroundAgentJobCreateBase = TurnScopedRPCRequest & {
  source_tool_call_id: string
  title: string
  task: string
  background?: string
  notes?: string
  agent_plugin_ids?: string[]
  skill_names?: string[]
  workspace_mounts?: BackgroundAgentJobWorkspaceMount[]
  model?: string
  reasoning_effort?: 'minimal' | 'low' | 'medium' | 'high' | 'xhigh'
}

export type BackgroundAgentJobCreateRequest = BackgroundAgentJobCreateBase

type BackgroundAgentJobByIDRequest = TurnScopedRPCRequest & {
  job_id: string
}

export type BackgroundAgentJobGetRequest = BackgroundAgentJobByIDRequest & {
  trajectory_limit?: number
  trajectory_cursor?: string
}

export type BackgroundAgentJobListRequest = TurnScopedRPCRequest

export type BackgroundAgentJobSteerRequest = BackgroundAgentJobByIDRequest & {
  text?: string
  answers?: Record<string, string | string[]>
}

export type BackgroundAgentJobStopRequest = BackgroundAgentJobByIDRequest & {
  reason?: string
}

type BackgroundAgentJobResponseBase = {
  request_id: string
  job_id: string
  agent_uid: string
  owner_session_id: string
  source_actor_event_id?: string
  source_tool_call_id?: string
  status: BackgroundAgentJobStatus
  runtime_thread_id?: string
  codex_account_id: string
  title: string
  task: string
  background?: string
  notes?: string
  reply_route: JSONObject
  attempts: number
  agent_plugin_ids: string[]
  skill_names: string[]
  workspace_mounts: BackgroundAgentJobWorkspaceMount[]
  model?: string
  reasoning_effort?: 'minimal' | 'low' | 'medium' | 'high' | 'xhigh'
  queued_at?: string
  started_at?: string
  completed_at?: string
  result?: JSONObject
  error?: JSONObject
  metadata?: JSONObject
  execution?: BackgroundAgentJobExecution
  attempt_history?: Array<{
    attempt: number
    turn_statuses: BackgroundAgentJobTurnStatus[]
    summary?: string
  }>
  result_ref?: BackgroundAgentJobResultRef
}

export type BackgroundAgentJobResultRef = {
  type: 'background_agent_job'
  job_id: string
}

export type BackgroundAgentJobResponse = BackgroundAgentJobResponseBase

export function decodeBackgroundAgentJobResponse(value: unknown): BackgroundAgentJobResponse {
  const job = jsonObject(value)
  const requiredStrings = [
    'request_id',
    'job_id',
    'agent_uid',
    'owner_session_id',
    'codex_account_id',
    'title',
    'task'
  ] as const
  for (const key of requiredStrings) {
    if (!backgroundAgentJobString(job[key])) throw new Error(`BackgroundAgentJob response ${key} is required`)
  }
  if (!backgroundAgentJobStatuses.has(job.status as BackgroundAgentJobStatus)) {
    throw new Error(`BackgroundAgentJob response has invalid status: ${String(job.status)}`)
  }
  if (!Number.isSafeInteger(job.attempts) || Number(job.attempts) < 0) {
    throw new Error('BackgroundAgentJob response attempts must be a nonnegative integer')
  }
  if (!isBackgroundAgentJobObject(job.reply_route)) {
    throw new Error('BackgroundAgentJob response reply_route must be an object')
  }

  const agentPluginIDs = decodeBackgroundAgentJobStringArray(job.agent_plugin_ids, 'agent_plugin_ids')
  const skillNames = decodeBackgroundAgentJobStringArray(job.skill_names, 'skill_names')
  const workspaceMounts = backgroundAgentJobArray(job.workspace_mounts, 'workspace_mounts').map((value, index) => {
    const mount = jsonObject(value)
    const id = backgroundAgentJobString(mount.id)
    const source = backgroundAgentJobString(mount.source)
    const access = mount.access
    if (!id || !source || (access !== 'read_only' && access !== 'read_write')) {
      throw new Error(`BackgroundAgentJob response workspace_mounts[${index}] is invalid`)
    }
    return { id, source, access: access as 'read_only' | 'read_write' }
  })
  assertUniqueBackgroundAgentJobStrings(agentPluginIDs, 'agent_plugin_ids')
  assertUniqueBackgroundAgentJobStrings(skillNames, 'skill_names')
  assertUniqueBackgroundAgentJobStrings(
    workspaceMounts.map(mount => mount.id),
    'workspace mount ids'
  )

  const reasoningEffort = job.reasoning_effort
  if (
    reasoningEffort !== undefined &&
    !['minimal', 'low', 'medium', 'high', 'xhigh'].includes(String(reasoningEffort))
  ) {
    throw new Error(`BackgroundAgentJob response reasoning_effort is invalid: ${String(reasoningEffort)}`)
  }
  return {
    ...(job as unknown as BackgroundAgentJobResponse),
    agent_plugin_ids: agentPluginIDs,
    skill_names: skillNames,
    workspace_mounts: workspaceMounts,
    ...(reasoningEffort
      ? {
          reasoning_effort: reasoningEffort as BackgroundAgentJobResponse['reasoning_effort']
        }
      : {})
  }
}

function backgroundAgentJobArray(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`BackgroundAgentJob response ${label} must be an array`)
  return value
}

function decodeBackgroundAgentJobStringArray(value: unknown, label: string): string[] {
  return backgroundAgentJobArray(value, label).map((item, index) => {
    if (typeof item !== 'string' || !item) {
      throw new Error(`BackgroundAgentJob response ${label}[${index}] must be a nonempty string`)
    }
    return item
  })
}

function assertUniqueBackgroundAgentJobStrings(values: string[], label: string): void {
  if (new Set(values).size !== values.length) throw new Error(`BackgroundAgentJob response ${label} must be unique`)
}

function isBackgroundAgentJobObject(value: unknown): value is JSONObject {
  return Boolean(value && typeof value === 'object' && !Array.isArray(value))
}

function backgroundAgentJobString(value: unknown): string | undefined {
  return typeof value === 'string' && value ? value : undefined
}

export type BackgroundAgentJobSummary = {
  job_id: string
  title: string
  status: BackgroundAgentJobStatus
  agent_plugin_ids: string[]
  attempts: number
  queued_at?: string
  started_at?: string
  completed_at?: string
}

export type BackgroundAgentJobListResponse = {
  request_id: string
  jobs: BackgroundAgentJobSummary[]
}

export type BackgroundAgentJobTurnStatus = 'in_progress' | 'completed' | 'failed' | 'interrupted'
export type BackgroundAgentJobTurnKind = 'agent' | 'compaction'

export type BackgroundAgentJobTurnTrajectoryContentPart = JSONObject & {
  type: string
}

export type BackgroundAgentJobTurnTrajectoryToolCall = JSONObject & {
  id: string
  type: 'function'
  function: JSONObject & {
    name: string
    arguments: string
  }
}

export type BackgroundAgentJobTurnTrajectoryMessage =
  | (JSONObject & {
      id?: string
      role: 'user' | 'developer'
      content: string | BackgroundAgentJobTurnTrajectoryContentPart[]
      metadata?: JSONObject
    })
  | (JSONObject & {
      id?: string
      role: 'assistant'
      content: string
      tool_calls?: BackgroundAgentJobTurnTrajectoryToolCall[]
      metadata?: JSONObject
    })
  | (JSONObject & {
      id?: string
      role: 'tool'
      tool_call_id: string
      name: string
      content: string
      metadata?: JSONObject
    })

export type BackgroundAgentJobTurnTrajectoryMetadata = JSONObject & {
  redacted?: boolean
  content_truncated?: boolean
}

export type BackgroundAgentJobTurnTrajectory = JSONObject & {
  format: 'ankole_chatml'
  version: 1
  messages: BackgroundAgentJobTurnTrajectoryMessage[]
  metadata?: BackgroundAgentJobTurnTrajectoryMetadata
}

export type BackgroundAgentJobTurnTrajectoryGroup = JSONObject & {
  position: number
  item_key: string
  messages: BackgroundAgentJobTurnTrajectoryMessage[]
}

export type BackgroundAgentJobTurnUsageBreakdown = JSONObject & {
  total_tokens: number
  input_tokens: number
  cached_input_tokens: number
  output_tokens: number
  reasoning_output_tokens: number
}

export type BackgroundAgentJobTurnUsage = JSONObject & {
  thread_total: BackgroundAgentJobTurnUsageBreakdown
  last_model_call: BackgroundAgentJobTurnUsageBreakdown
  model_context_window?: number
}

export type BackgroundAgentJobTurnPlan = JSONObject & {
  explanation?: string
  steps: Array<
    JSONObject & {
      step: string
      status: 'pending' | 'in_progress' | 'completed'
    }
  >
}

export type BackgroundAgentJobTurnToolUsage = JSONObject & {
  name: string
  calls: number
}

export type BackgroundAgentJobTurnActiveItem = JSONObject & {
  id: string
  name: string
}

export type BackgroundAgentJobTurnProgress = JSONObject & {
  completed_items: number
  tool_calls: number
  tools_used: BackgroundAgentJobTurnToolUsage[]
  files_changed: string[]
  plan?: BackgroundAgentJobTurnPlan
  active_item?: BackgroundAgentJobTurnActiveItem
}

export type BackgroundAgentJobExecution = {
  attempt: number
  current?: {
    runtime_turn_id: string
    kind: BackgroundAgentJobTurnKind
    status: BackgroundAgentJobTurnStatus
  }
  lead_turn_number: number
  threads: { total: number; child: number }
  turns: { lead: number; child: number; compaction: number; active: number }
  progress: Omit<BackgroundAgentJobTurnProgress, 'active_item'> & {
    active_items: Array<{ scope: 'lead' | 'child'; name: string }>
  }
  usage?: BackgroundAgentJobTurnUsage
  trajectory_page: BackgroundAgentJobTurnTrajectory & { next_cursor?: string }
  updated_at: string
}

export type BackgroundAgentJobTurn = {
  id?: string
  attempt: number
  runtime_thread_id: string
  runtime_turn_id: string
  kind: BackgroundAgentJobTurnKind
  status: BackgroundAgentJobTurnStatus
  revision: number
  trajectory: BackgroundAgentJobTurnTrajectory
  progress: BackgroundAgentJobTurnProgress
  usage?: BackgroundAgentJobTurnUsage | null
  error: JSONObject
  started_at: string
  completed_at?: string
  inserted_at?: string
  updated_at?: string
}

export type BackgroundAgentJobTurnUpsertRequest = TurnScopedRPCRequest & {
  job_id: string
  attempt: number
  runtime_thread_id: string
  runtime_turn_id: string
  kind: BackgroundAgentJobTurnKind
  status: BackgroundAgentJobTurnStatus
  revision: number
  trajectory: BackgroundAgentJobTurnTrajectory
  trajectory_groups: BackgroundAgentJobTurnTrajectoryGroup[]
  progress: BackgroundAgentJobTurnProgress
  usage?: BackgroundAgentJobTurnUsage
  error?: JSONObject
  started_at: string
  completed_at?: string
}

export type BackgroundAgentJobTurnUpsertResponse = {
  request_id: string
  job_id: string
  turn: BackgroundAgentJobTurn
}

export type BackgroundAgentJobStatusUpdateRequest = TurnScopedRPCRequest & {
  job_id: string
  status: BackgroundAgentJobStatus
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
  [rpcMethods.agentPluginList]: {
    request: AgentPluginListRequest
    response: AgentPluginListResponse
  }
  [rpcMethods.backgroundAgentJobCreate]: {
    request: BackgroundAgentJobCreateRequest
    response: BackgroundAgentJobResponse
  }
  [rpcMethods.backgroundAgentJobGet]: {
    request: BackgroundAgentJobGetRequest
    response: BackgroundAgentJobResponse
  }
  [rpcMethods.backgroundAgentJobList]: {
    request: BackgroundAgentJobListRequest
    response: BackgroundAgentJobListResponse
  }
  [rpcMethods.backgroundAgentJobSteer]: {
    request: BackgroundAgentJobSteerRequest
    response: BackgroundAgentJobResponse
  }
  [rpcMethods.backgroundAgentJobStop]: {
    request: BackgroundAgentJobStopRequest
    response: BackgroundAgentJobResponse
  }
  [rpcMethods.backgroundAgentJobTurnUpsert]: {
    request: BackgroundAgentJobTurnUpsertRequest
    response: BackgroundAgentJobTurnUpsertResponse
  }
  [rpcMethods.backgroundAgentJobStatusUpdate]: {
    request: BackgroundAgentJobStatusUpdateRequest
    response: BackgroundAgentJobResponse
  }
  [rpcMethods.memorySearch]: { request: MemorySearchRequest; response: JSONObject }
  [rpcMethods.memoryBrowse]: { request: MemoryBrowseRequest; response: JSONObject }
  [rpcMethods.memoryOpen]: { request: MemoryOpenRequest; response: JSONObject }
  [rpcMethods.memoryUpdate]: { request: MemoryUpdateRequest; response: JSONObject }
  [rpcMethods.memoryHealthCheck]: { request: MemoryHealthCheckRequest; response: JSONObject }
  [rpcMethods.scheduleCheckBackLaterCreate]: { request: ScheduleCheckBackLaterCreateRequest; response: JSONObject }
  [rpcMethods.scheduleCheckBackLaterList]: { request: ScheduleCheckBackLaterListRequest; response: JSONObject }
  [rpcMethods.scheduleCheckBackLaterGet]: { request: ScheduleCheckBackLaterTargetRequest; response: JSONObject }
  [rpcMethods.scheduleCheckBackLaterUpdate]: { request: ScheduleCheckBackLaterUpdateRequest; response: JSONObject }
  [rpcMethods.scheduleCheckBackLaterCancel]: { request: ScheduleCheckBackLaterTargetRequest; response: JSONObject }
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
 * Shape of the injected RPC caller every turn capability goes through. It
 * generates request ids, converts control-plane rejections into thrown
 * `RPCRejectedError`s, and never applies local fallback behavior.
 */
export type RPCRequester = <M extends RPCMethod>(
  method: M,
  payload: Omit<RPCSchemaByMethod[M]['request'], 'request_id'>
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
  payload: Omit<RPCSchemaByMethod[M]['request'], 'request_id'>
) => Promise<JSONObject>

export type MemoryRPCRequester = <M extends MemoryRPCMethod>(
  method: M,
  payload: Omit<RPCSchemaByMethod[M]['request'], 'request_id'>
) => Promise<JSONObject>

const rpcTimeoutMs = 300_000

type RPCWaiter = {
  resolve: (response: RPCResponse | RPCError) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
}

/**
 * Converts a decoded RPC request message into the wire-frame DTO the worker
 * dispatch and RPC payload contracts use.
 */
export function rpcRequestFromProto(request: RPCRequestMessage): RPCRequest {
  return {
    request_id: request.requestId,
    method: request.method,
    ...(request.deadlineUnixMs !== 0n
      ? { deadline_unix_ms: safeNumberFromBigInt(request.deadlineUnixMs, 'rpc_request.deadline_unix_ms') }
      : {}),
    payload_json: jsonObjectFromBytes(request.payloadJson, 'rpc_request.payload_json')
  }
}

export function rpcResponseFromProto(response: RPCResponseMessage): RPCResponse {
  return {
    request_id: response.requestId,
    payload_json: jsonObjectFromBytes(response.payloadJson, 'rpc_response.payload_json')
  }
}

export function rpcErrorFromProto(error: RPCErrorMessage): RPCError {
  return {
    request_id: error.requestId,
    code: error.code,
    ...(error.message ? { message: error.message } : {}),
    details_json: jsonObjectFromBytes(error.detailsJson, 'rpc_error.details_json')
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
      await this.sendEnvelope(
        createEnvelope({
          ...envelopeHeader(
            `rpc-request-${crypto.randomUUID()}`,
            Lane.RPC,
            DurabilityClass.CONTROL_EPHEMERAL,
            requestID
          ),
          body: {
            case: 'rpcRequest',
            value: create(RPCRequestSchema, {
              requestId: request.request_id,
              method: request.method,
              payloadJson: jsonBytes(request.payload_json)
            })
          }
        })
      )
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
function workerRPCReplyEnvelope(reply: RPCResponse | RPCError, requestID: string): Envelope {
  return createEnvelope({
    ...envelopeHeader(`rpc-reply-${crypto.randomUUID()}`, Lane.RPC, DurabilityClass.CONTROL_EPHEMERAL, requestID),
    body:
      'code' in reply
        ? {
            case: 'rpcError',
            value: create(RPCErrorSchema, {
              requestId: reply.request_id,
              code: reply.code,
              message: reply.message ?? '',
              detailsJson: jsonBytes(reply.details_json)
            })
          }
        : {
            case: 'rpcResponse',
            value: create(RPCResponseSchema, {
              requestId: reply.request_id,
              payloadJson: jsonBytes(reply.payload_json)
            })
          }
  })
}
