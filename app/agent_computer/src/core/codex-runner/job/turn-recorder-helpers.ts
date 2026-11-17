import {
  jsonObject,
  recordValue,
  safeJsonParse,
  stringArg,
  type JsonObject as JSONObject
} from '@agentbull/active-support'
import { errorMessage } from '../../../common/errors'
import {
  isConcreteDriveFilePath,
  type DriveFlushedFile,
  type DriveFlushResult,
  type DriveView,
  type DriveWriteError
} from '../../../drive/mounts'
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
  request: RPCRequestInit<'background_agent_job.turn.upsert'>,
  maxAttempts = 3
): Promise<void> {
  let persisted = false
  let lastError: unknown
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
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
      if (attempt < maxAttempts) await Bun.sleep(50 * 2 ** (attempt - 1))
    }
  }
  if (!persisted) throw new BackgroundAgentJobTurnPersistenceError(lastError)
}

export function prepareTurnUpsertCheckpoint(
  jobID: string,
  attempt: number,
  turn: RuntimeTurn
): {
  request: RPCRequestInit<'background_agent_job.turn.upsert'>
  itemKeys: string[]
} {
  const turnItems = pendingTurnItems(turn)
  const itemKeys = turnItems.map(entry => entry.item_key)
  for (const key of itemKeys) {
    turn.enqueuedItemKeys.add(key)
  }

  return {
    itemKeys,
    request: {
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
}

export function acknowledgeTurnItems(turn: RuntimeTurn | undefined, itemKeys: readonly string[]): void {
  if (!turn || itemKeys.length === 0) return
  const removable = new Set<string>()
  for (const key of itemKeys) {
    if (key !== turn.initialItemKey) {
      turn.items.delete(key)
      removable.add(key)
    }
  }
  if (removable.size > 0) {
    turn.itemOrder = turn.itemOrder.filter(key => !removable.has(key))
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

const pendingPathsFlushTimeoutMs = 120_000
const fallbackStatConcurrency = 8

export function mergeDriveWindows(
  retained: Map<string, number> | undefined,
  current: Map<string, number> | undefined
): Map<string, number> | undefined {
  if (!retained) return current ? new Map(current) : undefined
  if (!current) return new Map(retained)
  const merged = new Map(retained)
  for (const [mountKey, seq] of current) {
    const prev = merged.get(mountKey)
    merged.set(mountKey, prev === undefined ? seq : Math.min(prev, seq))
  }
  return merged
}

export function recordFlushedDriveDeliverables(
  pendingDrivePaths: Set<string>,
  driveDeliverables: Map<string, DriveFlushedFile>,
  files: readonly DriveFlushedFile[]
): void {
  for (const file of files) {
    pendingDrivePaths.delete(file.path)
    driveDeliverables.set(file.path, file)
  }
}

async function flushCandidateDrivePaths(
  driveView: DriveView,
  candidates: string[],
  signal: AbortSignal
): Promise<{ flushed: string[]; pending: string[]; files: DriveFlushedFile[]; errors?: DriveWriteError[] }> {
  if (typeof driveView.flushPaths === 'function') {
    const result = await driveView.flushPaths(candidates, signal)
    return {
      flushed: result.flushed,
      pending: result.pending,
      files: result.files ?? [],
      ...(result.errors ? { errors: result.errors } : {})
    }
  }
  const files: DriveFlushedFile[] = []
  const flushed: string[] = []
  const pending: string[] = []
  let nextIndex = 0
  const workerCount = Math.min(fallbackStatConcurrency, candidates.length)
  await Promise.all(
    Array.from({ length: workerCount }, async () => {
      while (nextIndex < candidates.length) {
        const path = candidates[nextIndex++]!
        try {
          const nodeId = await driveView.flushPath(path, signal)
          flushed.push(path)
          files.push({ path, nodeId })
        } catch {
          pending.push(path)
        }
      }
    })
  )
  return { flushed, pending, files }
}

export async function flushRecorderDriveWindow(
  driveView: DriveView | undefined,
  window: Map<string, number> | undefined,
  pendingDrivePaths: Set<string>,
  driveDeliverables: Map<string, DriveFlushedFile>
): Promise<DriveFlushResult> {
  if (!driveView) return { status: 'flushed', files: [] }

  let files: DriveFlushedFile[] = []
  let pendingReason: string | undefined
  let flushIncomplete = false

  if (window) {
    const result = await driveView.flush(window)
    recordFlushedDriveDeliverables(pendingDrivePaths, driveDeliverables, result.files)
    files = [...result.files]
    if (result.status === 'failed') {
      for (const err of result.errors) pendingDrivePaths.delete(err.path)
      return result
    }
    if (result.status === 'pending') {
      for (const path of result.paths) {
        if (isConcreteDriveFilePath(path)) pendingDrivePaths.add(path)
      }
      pendingReason = result.reason
      if (result.flush_incomplete) flushIncomplete = true
    }
  }

  for (const path of pendingDrivePaths) {
    if (!isConcreteDriveFilePath(path)) pendingDrivePaths.delete(path)
  }

  if (pendingDrivePaths.size > 0) {
    const candidates = [...pendingDrivePaths]
    const signal = AbortSignal.timeout(pendingPathsFlushTimeoutMs)
    const batch = await flushCandidateDrivePaths(driveView, candidates, signal)
    if (batch.files.length > 0) {
      recordFlushedDriveDeliverables(pendingDrivePaths, driveDeliverables, batch.files)
      const existingPaths = new Set(files.map(file => file.path))
      for (const file of batch.files) {
        if (!existingPaths.has(file.path)) {
          existingPaths.add(file.path)
          files.push(file)
        }
      }
    } else if (batch.flushed.length > 0) {
      for (const path of batch.flushed) pendingDrivePaths.delete(path)
    }
    if (batch.errors?.length) {
      for (const err of batch.errors) pendingDrivePaths.delete(err.path)
      return { status: 'failed', errors: batch.errors, files }
    }
  }

  if (pendingDrivePaths.size > 0 || flushIncomplete) {
    return {
      status: 'pending',
      files,
      paths: [...pendingDrivePaths],
      ...(flushIncomplete ? { flush_incomplete: true } : {}),
      ...(pendingReason ? { reason: pendingReason } : {})
    }
  }
  return { status: 'flushed', files }
}
