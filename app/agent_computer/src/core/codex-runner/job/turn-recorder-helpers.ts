import {
  jsonObject,
  recordValue,
  safeJsonParse,
  stringArg,
  type JsonObject as JSONObject
} from '@agentbull/active-support'
import { errorMessage } from '../../../common/errors'
import { jsonBytes } from '../../../fabric/envelope-proto'
import type { BackgroundAgentJobTurnUpsertResponse } from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { RPCRequestInit } from '../../../lanes/rpc-contract'
import { RPCRejectedError, rpcRejectedMessage } from '../../../lanes/rpc-lane'
import type {
  BackgroundAgentJobTurnItemEntry,
  BackgroundAgentJobTurnKind,
  BackgroundAgentJobTurnPlan,
  BackgroundAgentJobTurnProgress,
  BackgroundAgentJobTurnStatus,
  BackgroundAgentJobTurnTrajectoryHeader,
  BackgroundAgentJobTurnUsage
} from '../../background-agent-job-documents'
import { compareToolIdentity, toolIdentityKey, type ToolExecutionMechanism, type ToolIdentity } from './tool-item'
import type { CodexTurnTrace } from './turn-tracing'

export type RuntimeTurn = {
  runtimeThreadID: string
  runtimeTurnID: string
  kind: BackgroundAgentJobTurnKind
  status: BackgroundAgentJobTurnStatus
  revision: number
  items: Map<string, JSONObject>
  itemOrder: string[]
  itemPositions: Map<string, number>
  nextTrajectoryPosition: number
  enqueuedItemKeys: Set<string>
  completedItemIDs: Set<string>
  modelToolIdentities: Map<string, ToolIdentity>
  toolItemIdentities: Map<string, ToolIdentity>
  toolItemExecutionMechanisms: Map<string, ToolExecutionMechanism>
  usedSkillNames: Set<string>
  filesChanged: Set<string>
  initialItemKey?: string
  usage?: BackgroundAgentJobTurnUsage
  plan?: BackgroundAgentJobTurnPlan
  activeItem?: { id: string } & ToolIdentity
  error: JSONObject
  startedAt: string
  completedAt?: string
  trace: CodexTurnTrace | undefined
  dirty: boolean
  redacted: boolean
  contentTruncated: boolean
}

export type ItemEntry = {
  key: string
  item: JSONObject
}

export type CollaborationActivity = {
  kind: string
  agentThreadID: string
  agentPath: string
}

export type PendingCollaborationCall = {
  runtimeTurnID: string
  tool: string
  arguments: unknown
  activity?: CollaborationActivity
}

/**
 * A collaboration call known only from its parent-scoped activity. Code mode
 * calls the collaboration tools inside the JavaScript executor, so no raw
 * `function_call` carries the arguments. Codex delivers the brief to the child
 * thread as a raw `agent_message` item, and that item holds the plaintext.
 */
export type DeferredCollaborationCall = {
  runtimeTurnID: string
  id: string
  activity: CollaborationActivity
}

export async function persistTurnCheckpointWithRetry(
  upsert: (
    request: RPCRequestInit<'background_agent_job.turn.upsert'>
  ) => Promise<BackgroundAgentJobTurnUpsertResponse>,
  request: RPCRequestInit<'background_agent_job.turn.upsert'>
): Promise<void> {
  let persisted = false
  let lastError: unknown
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      await upsert(request)
      persisted = true
      break
    } catch (error) {
      if (error instanceof RPCRejectedError) {
        // Domain rejections are authoritative. An explicitly retryable
        // internal read rejection is infrastructure failure and follows
        // the same bounded retry path as transport loss.
        if (!error.retryable) {
          throw new BackgroundAgentJobTurnPersistenceRejectedError(error.rejection)
        }
      }
      lastError = error
      if (attempt < 3) await Bun.sleep(50 * 2 ** (attempt - 1))
    }
  }
  if (!persisted) throw new BackgroundAgentJobTurnPersistenceError(lastError)
}

export function buildTurnUpsertRequest(
  jobID: string,
  attempt: number,
  turn: RuntimeTurn
): RPCRequestInit<'background_agent_job.turn.upsert'> {
  const turnItems = pendingTurnItems(turn)
  // Items leave memory before PostgreSQL acknowledges this request. Retries
  // use this serialized request. A permanent failure makes flush() fail, so
  // the Job attempt fails and the next attempt resumes the saved thread.
  for (const entry of turnItems) {
    turn.enqueuedItemKeys.add(entry.item_key)
    if (entry.item_key !== turn.initialItemKey) {
      turn.items.delete(entry.item_key)
      turn.itemOrder = turn.itemOrder.filter(key => key !== entry.item_key)
    }
  }

  return {
    jobId: jobID,
    attempt,
    runtimeThreadId: turn.runtimeThreadID,
    runtimeTurnId: turn.runtimeTurnID,
    kind: turn.kind,
    status: turn.status,
    revision: turn.revision,
    trajectoryJson: jsonBytes(trajectoryHeader(turn)),
    turnItemsJson: jsonBytes(turnItems),
    progressJson: jsonBytes(progress(turn)),
    ...(turn.usage ? { usageJson: jsonBytes(turn.usage) } : {}),
    errorJson: jsonBytes(turn.error),
    startedAt: turn.startedAt,
    ...(turn.completedAt ? { completedAt: turn.completedAt } : {})
  }
}

function progress(turn: RuntimeTurn): BackgroundAgentJobTurnProgress {
  const counts = new Map<string, ToolIdentity & { calls: number }>()
  for (const identity of turn.toolItemIdentities.values()) {
    const key = toolIdentityKey(identity)
    const existing = counts.get(key)
    counts.set(key, { ...identity, calls: (existing?.calls ?? 0) + 1 })
  }
  const toolsUsed = [...counts.values()].sort(compareToolIdentity)
  const executionCounts = new Map<string, ToolExecutionMechanism & { calls: number }>()
  for (const execution of turn.toolItemExecutionMechanisms.values()) {
    const key = `${toolIdentityKey(execution)}\u0000${execution.execution_mechanism}`
    const existing = executionCounts.get(key)
    executionCounts.set(key, { ...execution, calls: (existing?.calls ?? 0) + 1 })
  }
  const toolExecutionMechanisms = [...executionCounts.values()].sort((left, right) => {
    const identityOrder = compareToolIdentity(left, right)
    if (identityOrder !== 0) return identityOrder
    return left.execution_mechanism < right.execution_mechanism ? -1 : 1
  })

  return {
    completed_items: turn.completedItemIDs.size,
    tool_calls: turn.toolItemIdentities.size,
    tools_used: toolsUsed,
    ...(toolExecutionMechanisms.length > 0 ? { tool_execution_mechanisms: toolExecutionMechanisms } : {}),
    files_changed: [...turn.filesChanged].sort(),
    ...(turn.usedSkillNames.size > 0 ? { skills_used: [...turn.usedSkillNames].sort() } : {}),
    ...(turn.plan ? { plan: turn.plan } : {}),
    ...(turn.activeItem ? { active_item: turn.activeItem } : {})
  }
}

export function planStatus(value: unknown): BackgroundAgentJobTurnPlan['steps'][number]['status'] | undefined {
  switch (value) {
    case 'pending':
      return 'pending'
    case 'inProgress':
      return 'in_progress'
    case 'completed':
      return 'completed'
    default:
      return undefined
  }
}

export function fileChangePaths(value: unknown): string[] {
  return arrayValue(value).flatMap(change => {
    const path = stringArg(recordValue(change), 'path')
    return path ? [path] : []
  })
}

function trajectoryHeader(turn: RuntimeTurn): BackgroundAgentJobTurnTrajectoryHeader {
  const metadata = jsonObject({
    ...(turn.redacted ? { redacted: true } : {}),
    ...(turn.contentTruncated ? { content_truncated: true } : {})
  })

  return {
    format: 'ankole_chatml',
    version: 1,
    ...(Object.keys(metadata).length > 0 ? { metadata } : {})
  }
}

function pendingTurnItems(turn: RuntimeTurn): BackgroundAgentJobTurnItemEntry[] {
  return turn.itemOrder.flatMap(key => {
    if (turn.enqueuedItemKeys.has(key)) return []
    const item = turn.items.get(key)
    const position = turn.itemPositions.get(key)
    if (!item || position === undefined) return []
    return [{ position, item_key: key, item }]
  })
}

// Normalize current namespaced calls and retained dotted call records to this
// stable collaboration activity vocabulary.
const collaborationV2Tools = new Set([
  'spawn_agent',
  'send_message',
  'followup_task',
  'interrupt_agent',
  'list_agents',
  'wait_agent'
])

export function collaborationToolName(item: JSONObject): string | undefined {
  const namespace = stringArg(item, 'namespace')
  const name = stringArg(item, 'name')
  if (!name) return undefined
  if (namespace === 'collaboration' && collaborationV2Tools.has(name)) return name
  if (!name.startsWith('collaboration.')) return undefined
  const tool = name.slice('collaboration.'.length)
  return collaborationV2Tools.has(tool) ? tool : undefined
}

export function fallbackCollaborationTool(kind: string): string {
  switch (kind) {
    case 'started':
      return 'spawn_agent'
    case 'interrupted':
      return 'interrupt_agent'
    default:
      return 'agent_interaction'
  }
}

export function collaborationToolOutcome(output: unknown, activity?: CollaborationActivity): unknown {
  const parsedOutput = parseJSONValue(output, '')
  if (!activity) return parsedOutput
  return {
    output: parsedOutput,
    agents: [
      {
        thread_id: activity.agentThreadID,
        path: activity.agentPath,
        activity: activity.kind
      }
    ]
  }
}

/**
 * A parent-to-child agent message carries a routing header as `input_text`
 * and the message itself as an `encrypted_content` part, which the pinned
 * Codex fills with the plaintext.
 */
export function agentMessagePayload(content: unknown): string | undefined {
  const payload = arrayValue(content).flatMap(part => {
    const value = recordValue(part)
    return value?.type === 'encrypted_content' ? [stringArg(value, 'encrypted_content') ?? ''] : []
  })
  return payload.join('') || undefined
}

export function parseJSONValue(value: unknown, emptyValue: unknown): unknown {
  if (typeof value !== 'string') return value ?? emptyValue
  if (!value.trim()) return emptyValue
  return safeJsonParse(value).unwrapOr(value)
}

function userContent(content: unknown): string | JSONObject[] {
  const items = arrayValue(content).map(item => jsonObject(item))
  if (items.every(item => item.type === 'text')) return items.map(item => stringArg(item, 'text') ?? '').join('')
  return items
}

export function sameUserContent(left: unknown, right: unknown): boolean {
  const leftContent = userContent(left)
  const rightContent = userContent(right)
  return typeof leftContent === 'string' && typeof rightContent === 'string'
    ? leftContent === rightContent
    : JSON.stringify(leftContent) === JSON.stringify(rightContent)
}

export function itemKey(item: JSONObject): string | undefined {
  const id = stringArg(item, 'id')
  if (!id) return undefined
  const clientId = stringArg(item, 'clientId')
  return item.type === 'userMessage' && clientId ? `client:${clientId}` : id
}

export function shouldRecordItem(item: JSONObject): boolean {
  return item.type !== 'subAgentActivity'
}

export function turnStatus(value: unknown): BackgroundAgentJobTurnStatus | undefined {
  switch (value) {
    case 'inProgress':
    case 'in_progress':
      return 'in_progress'
    case 'completed':
    case 'failed':
    case 'interrupted':
      return value
    default:
      return undefined
  }
}

export function terminal(status: BackgroundAgentJobTurnStatus): boolean {
  return status === 'completed' || status === 'failed' || status === 'interrupted'
}

export function traceTurnOutput(payload: JSONObject): unknown {
  for (const value of arrayValue(payload.items).reverse()) {
    const item = recordValue(value)
    const text = item?.type === 'agentMessage' ? stringArg(item, 'text') : undefined
    if (text) return text
  }

  return undefined
}

export function traceTurnError(turn: RuntimeTurn): string | undefined {
  if (turn.status === 'completed') return undefined
  return errorType(turn.error) ?? `codex_turn_${turn.status}`
}

export function errorType(error: JSONObject): string | undefined {
  const code = stringArg(error, 'code')
  return code && code.trim() ? code : undefined
}

export function timestampSeconds(value: unknown): string | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? new Date(value * 1_000).toISOString() : undefined
}

export function timestampDate(value: unknown): Date | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? new Date(value * 1_000) : undefined
}

export function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

export function now(): string {
  return new Date().toISOString()
}

export class BackgroundAgentJobTurnPersistenceRejectedError extends Error {
  readonly code = 'background_agent_job_turn_persistence_rejected'
  readonly retryable = false
  readonly details: JSONObject

  constructor(response: { code: string; message?: string; details?: JSONObject }) {
    super(rpcRejectedMessage('background agent job turn checkpoint rejected', response))
    this.name = 'BackgroundAgentJobTurnPersistenceRejectedError'
    this.details = persistenceRejectionDetails(response, false)
  }
}

export class BackgroundAgentJobTurnPersistenceError extends Error {
  readonly code = 'background_agent_job_turn_persistence_failed'
  readonly retryable = true
  readonly details: JSONObject

  constructor(cause: unknown) {
    super(`BackgroundAgentJob Turn persistence failed: ${errorMessage(cause)}`, {
      cause: cause instanceof Error ? cause : undefined
    })
    this.name = 'BackgroundAgentJobTurnPersistenceError'
    this.details =
      cause instanceof RPCRejectedError ? persistenceRejectionDetails(cause.rejection, true) : { retryable: true }
  }
}

function persistenceRejectionDetails(
  response: { code: string; message?: string; details?: JSONObject },
  retryable: boolean
): JSONObject {
  return {
    retryable,
    rpc_code: response.code,
    ...(response.details ? { rpc_details: response.details } : {})
  }
}
