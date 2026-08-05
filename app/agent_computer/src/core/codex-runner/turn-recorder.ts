import { jsonObject, type JsonObject as JSONObject } from '@agentbull/active-support'
import { sanitizeBinaryOutput, truncateUTF8Safe, utf8ByteLength } from '../../common/text-sanitize'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import { jsonBytes } from '../../fabric/envelope_proto'
import {
  RPCRejectedError,
  rpcRejectedMessage,
  type BackgroundAgentJobTurnUpsertResponse,
  type BackgroundAgentJobTurnPlan,
  type BackgroundAgentJobTurnProgress,
  type BackgroundAgentJobTurnKind,
  type BackgroundAgentJobTurnStatus,
  type BackgroundAgentJobTurnTrajectoryHeader,
  type BackgroundAgentJobTurnTrajectoryGroup,
  type BackgroundAgentJobTurnTrajectoryMessage,
  type BackgroundAgentJobTurnUsage,
  type RPCRequestInit
} from '../../lanes/rpc_lane'
import type { JSONRPCMessage } from './app-server-client'
import { boundedFilesChangedFromCodexDiff, normalizeCodexThreadUsage } from './protocol'
import type { ThreadItem } from './generated/protocol/v2/ThreadItem'
import { boundedBackgroundAgentJobPaths } from '../background-agent-job-handoff'

const checkpointDelayMs = 5_000
const maxStringBytes = 16 * 1_024
const maxToolArgumentsBytes = 64 * 1_024
const maxCollectionItems = 64
const maxMapKeyBytes = 256
const maxValueDepth = 8
const truncationMarker = '...[truncated]'
const redactionMarker = '[REDACTED]'

type RuntimeTurn = {
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
  anchoredItemKeys: Set<string>
  completedItemIDs: Set<string>
  toolItemNames: Map<string, string>
  usedSkillNames: Set<string>
  filesChanged: Set<string>
  initialItemKey?: string
  usage?: BackgroundAgentJobTurnUsage
  plan?: BackgroundAgentJobTurnPlan
  activeItem?: { id: string; name: string }
  error: JSONObject
  startedAt: string
  completedAt?: string
  dirty: boolean
  redacted: boolean
  contentTruncated: boolean
}

type SanitizeState = {
  redacted: boolean
  truncated: boolean
}

type ItemEntry = {
  key: string
  item: JSONObject
}

type CollabAgentToolCall = Extract<ThreadItem, { type: 'collabAgentToolCall' }>

export class BackgroundAgentJobTurnRecorder {
  private readonly turns = new Map<string, RuntimeTurn>()
  private readonly timers = new Map<string, ReturnType<typeof setTimeout>>()
  private tail: Promise<void> = Promise.resolve()
  private checkpointError: unknown

  constructor(
    private readonly input: {
      jobID: string
      attempt: number
      actorTurn: ActorTurnRef
      upsert: (
        request: RPCRequestInit<'background_agent_job.turn.upsert'>
      ) => Promise<BackgroundAgentJobTurnUpsertResponse>
      checkpointDelayMs?: number
    }
  ) {}

  recordTurnStarted(runtimeThreadID: string, payload: JSONObject, input?: string, clientUserMessageID?: string): void {
    this.startTurn(jsonObject({ threadId: runtimeThreadID, turn: payload }), input, clientUserMessageID)
  }

  handleNotification(message: JSONRPCMessage): void {
    const params = jsonObject(message.params)

    switch (message.method) {
      case 'turn/started':
        this.startTurn(params)
        return
      case 'turn/completed':
        this.completeTurn(params)
        return
      case 'item/started':
        this.startItem(params)
        return
      case 'item/completed':
        this.completeItem(params)
        return
      case 'turn/plan/updated':
        this.updateTurnPlan(params)
        return
      case 'thread/tokenUsage/updated':
        this.updateUsage(params)
        return
      case 'turn/diff/updated':
        this.updateDiff(params)
        return
      default:
        return
    }
  }

  recordRequestUserInput(turnID: string | undefined, params: JSONObject, requestID?: string | number): void {
    const resolvedTurnID = stringValue(params.turnId) ?? turnID
    if (!resolvedTurnID) return
    const turn = this.turns.get(resolvedTurnID)
    if (!turn) return
    const id = stringValue(params.itemId) ?? `request-user-input:${requestID ?? resolvedTurnID}`
    const args = Object.fromEntries(
      Object.entries(params).filter(([key]) => !['threadId', 'turnId', 'itemId'].includes(key))
    )
    const inserted = this.putAnchoredItem(turn, {
      type: 'dynamicToolCall',
      id,
      namespace: null,
      tool: 'request_user_input',
      arguments: args,
      status: 'inProgress',
      contentItems: null,
      success: null,
      durationMs: null
    })
    if (inserted) this.markDirty(turn, true)
  }

  recordSteering(turnID: string | undefined, eventID: string, text: string): void {
    if (!turnID) return
    const turn = this.turns.get(turnID)
    if (!turn) return
    const inserted = this.putAnchoredItem(turn, {
      type: 'userMessage',
      id: eventID,
      clientId: eventID,
      content: [{ type: 'text', text }]
    })
    if (inserted) this.markDirty(turn, true)
  }

  recordSkillUsed(turnID: string | undefined, skillName: string): void {
    if (!turnID || !skillName) return
    const turn = this.turns.get(turnID)
    if (!turn || turn.usedSkillNames.has(skillName)) return
    turn.usedSkillNames.add(skillName)
    this.markDirty(turn, true)
  }

  interruptTurn(turnID: string | undefined, error: JSONObject): void {
    const turn = turnID ? this.turns.get(turnID) : undefined
    if (!turn || (terminal(turn.status) && turn.status !== 'interrupted')) return
    turn.status = 'interrupted'
    turn.error = this.sanitizeObject({ ...turn.error, ...error }, turn)
    turn.completedAt ??= now()
    turn.activeItem = undefined
    this.markDirty(turn, true)
  }

  finishTurn(turnID: string | undefined, status: 'failed' | 'stopped', error: JSONObject = {}): void {
    const turn = turnID ? this.turns.get(turnID) : undefined
    if (!turn || terminal(turn.status)) return
    turn.status = status === 'failed' ? 'failed' : 'interrupted'
    turn.error = this.sanitizeObject(error, turn)
    turn.completedAt = now()
    turn.activeItem = undefined
    this.markDirty(turn, true)
  }

  async flush(): Promise<void> {
    for (const [turnID, timer] of this.timers) {
      clearTimeout(timer)
      this.timers.delete(turnID)
      const turn = this.turns.get(turnID)
      if (turn) this.enqueueCheckpoint(turn)
    }
    for (const turn of this.turns.values()) this.enqueueCheckpoint(turn)
    await this.tail
    if (this.checkpointError) throw this.checkpointError
  }

  private startTurn(params: JSONObject, input?: string, clientUserMessageID?: string): void {
    const payload = jsonObject(params.turn)
    const runtimeTurnID = stringValue(payload.id)
    if (!runtimeTurnID) return
    const runtimeThreadID =
      stringValue(params.threadId) ??
      this.turns.get(runtimeTurnID)?.runtimeThreadID ??
      [...this.turns.values()].at(-1)?.runtimeThreadID
    if (!runtimeThreadID) return

    let turn = this.turns.get(runtimeTurnID)
    if (!turn) {
      const startedAt = timestampSeconds(payload.startedAt) ?? now()
      turn = {
        runtimeThreadID,
        runtimeTurnID,
        kind: 'agent',
        status: turnStatus(payload.status) ?? 'in_progress',
        revision: -1,
        items: new Map(),
        itemOrder: [],
        itemPositions: new Map(),
        nextTrajectoryPosition: 0,
        enqueuedItemKeys: new Set(),
        anchoredItemKeys: new Set(),
        completedItemIDs: new Set(),
        toolItemNames: new Map(),
        usedSkillNames: new Set(),
        filesChanged: new Set(),
        error: {},
        startedAt,
        dirty: true,
        redacted: false,
        contentTruncated: false
      }
      this.turns.set(runtimeTurnID, turn)
    }

    this.ensureInitialInput(turn, input, clientUserMessageID)
    this.applyCanonicalItems(turn, payload)
    turn.kind = nextTurnKind(turn)
    const reportedStatus = turnStatus(payload.status)
    const acceptsReportedTerminal = !terminal(turn.status) || reportedStatus === turn.status
    if (!terminal(turn.status)) turn.status = reportedStatus ?? turn.status
    const payloadError = jsonObject(payload.error)
    if (acceptsReportedTerminal && Object.keys(payloadError).length > 0) {
      turn.error = this.sanitizeObject(payloadError, turn)
    }
    if (terminal(turn.status)) {
      turn.completedAt ??= timestampSeconds(payload.completedAt) ?? now()
      turn.activeItem = undefined
      this.markDirty(turn, true)
    } else {
      this.markDirty(turn, true)
    }
  }

  private completeTurn(params: JSONObject): void {
    const payload = jsonObject(params.turn)
    const runtimeTurnID = stringValue(payload.id)
    if (!runtimeTurnID) return

    let turn = this.turns.get(runtimeTurnID)
    if (!turn) {
      this.startTurn(params)
      turn = this.turns.get(runtimeTurnID)
    }
    if (!turn) return

    this.applyCanonicalItems(turn, payload, true)
    turn.kind = nextTurnKind(turn)
    const reportedStatus = turnStatus(payload.status) ?? 'failed'
    const acceptsReportedTerminal = !terminal(turn.status) || reportedStatus === turn.status
    if (!terminal(turn.status)) turn.status = reportedStatus
    const payloadError = jsonObject(payload.error)
    if (acceptsReportedTerminal && Object.keys(payloadError).length > 0) {
      turn.error = this.sanitizeObject(payloadError, turn)
    }
    turn.completedAt ??= timestampSeconds(payload.completedAt) ?? now()
    turn.activeItem = undefined
    this.markDirty(turn, true)
  }

  private startItem(params: JSONObject): void {
    const turn = this.turn(params)
    const item = jsonObject(params.item)
    const id = stringValue(item.id)
    if (!turn || !id || !shouldRecordItem(item)) return
    const name = toolName(item)
    if (!name) return
    if (turn.activeItem?.id === id && turn.activeItem.name === name) return
    turn.activeItem = { id, name }
    this.markDirty(turn, true)
  }

  private completeItem(params: JSONObject): void {
    const turn = this.turn(params)
    const rawItem = jsonObject(params.item)
    const id = stringValue(rawItem.id)
    if (!turn || !id || !shouldRecordItem(rawItem)) return
    const redacted = turn.redacted
    const truncated = turn.contentTruncated
    const item = this.canonicalItem(turn, rawItem)
    const key = itemKey(item)
    if (!key) return
    if (turn.enqueuedItemKeys.has(key)) {
      if (turn.activeItem?.id === id) {
        turn.activeItem = undefined
        this.markDirty(turn, true)
      }
      return
    }
    const changed = JSON.stringify(turn.items.get(key)) !== JSON.stringify(item)
    if (changed) this.putCanonicalEntry(turn, { key, item })
    const tracked = this.trackCompletedItem(turn, item)
    const cleared = turn.activeItem?.id === id
    if (cleared) turn.activeItem = undefined
    turn.kind = nextTurnKind(turn)
    if (changed || tracked || cleared || redacted !== turn.redacted || truncated !== turn.contentTruncated) {
      this.markDirty(turn, true)
    }
  }

  private updateTurnPlan(params: JSONObject): void {
    const turn = this.turn(params)
    if (!turn) return
    const steps = arrayValue(params.plan).flatMap(step => {
      const value = jsonObject(step)
      const text = stringValue(value.step)
      const status = planStatus(value.status)
      return text && status ? [{ step: text, status }] : []
    })
    const candidate = this.sanitizeObject(
      {
        ...(stringValue(params.explanation) ? { explanation: stringValue(params.explanation) } : {}),
        steps
      },
      turn
    ) as BackgroundAgentJobTurnPlan
    if (JSON.stringify(turn.plan) === JSON.stringify(candidate)) return
    turn.plan = candidate
    this.markDirty(turn, false)
  }

  private updateUsage(params: JSONObject): void {
    const turn = this.turn(params)
    if (!turn) return
    const usage = normalizeCodexThreadUsage(params.tokenUsage)
    if (!usage || JSON.stringify(turn.usage) === JSON.stringify(usage)) return
    turn.usage = usage
    this.markDirty(turn, false)
  }

  private updateDiff(params: JSONObject): void {
    const turn = this.turn(params)
    const diff = stringValue(params.diff)
    if (!turn || diff === undefined) return
    const handoff = boundedFilesChangedFromCodexDiff(diff)
    const before = JSON.stringify([...turn.filesChanged].sort())
    const wasTruncated = turn.contentTruncated
    turn.filesChanged = new Set(handoff.paths)
    turn.contentTruncated ||= handoff.truncated
    if (JSON.stringify(handoff.paths) !== before || turn.contentTruncated !== wasTruncated) this.markDirty(turn, false)
  }

  private turn(params: JSONObject): RuntimeTurn | undefined {
    const turnID = stringValue(params.turnId)
    return turnID ? this.turns.get(turnID) : [...this.turns.values()].at(-1)
  }

  private ensureInitialInput(turn: RuntimeTurn, input?: string, clientUserMessageID?: string): void {
    if (!input || turn.initialItemKey) return
    const id = clientUserMessageID ?? `${turn.runtimeTurnID}:input`
    const key = `client:${id}`
    turn.initialItemKey = key
    turn.anchoredItemKeys.add(key)
    if (turn.items.has(key)) return
    this.putAnchoredItem(
      turn,
      {
        type: 'userMessage',
        id,
        clientId: id,
        content: [{ type: 'text', text: input }]
      },
      true
    )
  }

  private applyCanonicalItems(turn: RuntimeTurn, payload: JSONObject, completed = false): void {
    if (stringValue(payload.itemsView) === 'notLoaded') return
    if (!Array.isArray(payload.items)) return
    for (const entry of this.itemEntries(payload.items, turn, completed)) {
      if (!turn.enqueuedItemKeys.has(entry.key)) this.putCanonicalEntry(turn, entry)
    }
  }

  private itemEntries(value: unknown, turn: RuntimeTurn, completed: boolean): ItemEntry[] {
    const entries: ItemEntry[] = []
    for (const raw of arrayValue(value)) {
      const rawItem = jsonObject(raw)
      if (!shouldRecordItem(rawItem)) continue
      const item = this.canonicalItem(turn, rawItem)
      const key = itemKey(item)
      if (!key) continue
      if (completed) this.trackCompletedItem(turn, item)
      const existingIndex = entries.findIndex(entry => entry.key === key)
      if (existingIndex >= 0) entries[existingIndex] = { key, item }
      else entries.push({ key, item })
    }
    return entries
  }

  private canonicalItem(turn: RuntimeTurn, value: JSONObject): JSONObject {
    const semanticValue =
      value.type === 'reasoning'
        ? jsonObject({ type: value.type, id: value.id, summary: arrayValue(value.summary) })
        : value
    const item = this.sanitizeObject(semanticValue, turn)
    if (item.type !== 'userMessage' || stringValue(item.clientId) || !turn.initialItemKey) return item

    const initial = turn.items.get(turn.initialItemKey)
    if (initial?.type !== 'userMessage' || !sameUserContent(initial.content, item.content)) return item

    const clientID = stringValue(initial.clientId) ?? stringValue(initial.id)
    return clientID ? jsonObject({ ...item, clientId: clientID }) : item
  }

  private putCanonicalEntry(turn: RuntimeTurn, entry: ItemEntry): void {
    if (!turn.items.has(entry.key)) {
      turn.itemOrder.push(entry.key)
      this.assignTrajectoryPosition(turn, entry.key)
    }
    turn.items.set(entry.key, entry.item)
  }

  private trackCompletedItem(turn: RuntimeTurn, item: JSONObject): boolean {
    const id = stringValue(item.id)
    if (!id || turn.completedItemIDs.has(id)) return false
    turn.completedItemIDs.add(id)
    const name = toolName(item)
    if (name) turn.toolItemNames.set(id, name)
    if (item.type === 'fileChange') {
      const handoff = boundedBackgroundAgentJobPaths([...turn.filesChanged, ...fileChangePaths(item.changes)])
      turn.filesChanged = new Set(handoff.paths)
      turn.contentTruncated ||= handoff.truncated
    }
    return true
  }

  private putAnchoredItem(turn: RuntimeTurn, value: JSONObject, prepend = false): boolean {
    const item = this.sanitizeObject(value, turn)
    const key = itemKey(item)
    if (!key) return false
    turn.anchoredItemKeys.add(key)
    if (turn.items.has(key)) return false
    turn.items.set(key, item)
    this.assignTrajectoryPosition(turn, key)
    if (prepend) turn.itemOrder.unshift(key)
    else turn.itemOrder.push(key)
    return true
  }

  private assignTrajectoryPosition(turn: RuntimeTurn, key: string): void {
    if (turn.itemPositions.has(key)) return
    turn.itemPositions.set(key, turn.nextTrajectoryPosition)
    turn.nextTrajectoryPosition += 1
  }

  private sanitizeObject(value: JSONObject, turn: RuntimeTurn): JSONObject {
    const state: SanitizeState = { redacted: false, truncated: false }
    const sanitized = jsonObject(sanitizeValue(value, state))
    turn.redacted ||= state.redacted
    turn.contentTruncated ||= state.truncated
    return sanitized
  }

  private markDirty(turn: RuntimeTurn, immediate: boolean): void {
    turn.dirty = true
    if (immediate) {
      const timer = this.timers.get(turn.runtimeTurnID)
      if (timer) clearTimeout(timer)
      this.timers.delete(turn.runtimeTurnID)
      this.enqueueCheckpoint(turn)
      return
    }
    if (this.timers.has(turn.runtimeTurnID)) return
    const timer = setTimeout(() => {
      this.timers.delete(turn.runtimeTurnID)
      this.enqueueCheckpoint(turn)
    }, this.input.checkpointDelayMs ?? checkpointDelayMs)
    timer.unref?.()
    this.timers.set(turn.runtimeTurnID, timer)
  }

  private enqueueCheckpoint(turn: RuntimeTurn): void {
    if (!turn.dirty) return
    turn.dirty = false
    turn.revision += 1
    const request = this.request(turn)
    this.tail = this.tail
      .then(async () => {
        if (this.checkpointError) return
        let persisted = false
        let lastError: unknown
        for (let attempt = 1; attempt <= 3; attempt += 1) {
          try {
            await this.input.upsert(request)
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
      })
      .catch(error => {
        this.checkpointError ??= error
      })
  }

  private request(turn: RuntimeTurn): RPCRequestInit<'background_agent_job.turn.upsert'> {
    const trajectoryGroups = pendingTrajectoryGroups(turn)
    for (const group of trajectoryGroups) {
      turn.enqueuedItemKeys.add(group.item_key)
      if (group.item_key !== turn.initialItemKey) {
        turn.items.delete(group.item_key)
        turn.itemOrder = turn.itemOrder.filter(key => key !== group.item_key)
      }
    }

    return {
      jobId: this.input.jobID,
      attempt: this.input.attempt,
      runtimeThreadId: turn.runtimeThreadID,
      runtimeTurnId: turn.runtimeTurnID,
      kind: turn.kind,
      status: turn.status,
      revision: turn.revision,
      trajectoryJson: jsonBytes(trajectoryHeader(turn)),
      trajectoryGroupsJson: jsonBytes(trajectoryGroups),
      progressJson: jsonBytes(progress(turn)),
      ...(turn.usage ? { usageJson: jsonBytes(turn.usage) } : {}),
      errorJson: jsonBytes(turn.error),
      startedAt: turn.startedAt,
      ...(turn.completedAt ? { completedAt: turn.completedAt } : {})
    }
  }
}

function progress(turn: RuntimeTurn): BackgroundAgentJobTurnProgress {
  const counts = new Map<string, number>()
  for (const name of turn.toolItemNames.values()) counts.set(name, (counts.get(name) ?? 0) + 1)
  const toolsUsed = [...counts.entries()]
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
    .map(([name, calls]) => ({ name, calls }))

  return {
    completed_items: turn.completedItemIDs.size,
    tool_calls: turn.toolItemNames.size,
    tools_used: toolsUsed,
    files_changed: [...turn.filesChanged].sort(),
    ...(turn.usedSkillNames.size > 0 ? { skills_used: [...turn.usedSkillNames].sort() } : {}),
    ...(turn.plan ? { plan: turn.plan } : {}),
    ...(turn.activeItem ? { active_item: turn.activeItem } : {})
  }
}

function planStatus(value: unknown): BackgroundAgentJobTurnPlan['steps'][number]['status'] | undefined {
  switch (value) {
    case 'pending':
      return 'pending'
    case 'inProgress':
    case 'in_progress':
      return 'in_progress'
    case 'completed':
      return 'completed'
    default:
      return undefined
  }
}

function toolName(value: JSONObject): string | undefined {
  switch (value.type) {
    case 'commandExecution':
      return 'shell'
    case 'fileChange':
      return 'apply_patch'
    case 'mcpToolCall': {
      const server = stringValue(value.server)
      const tool = stringValue(value.tool)
      return server && tool ? `${server}.${tool}` : undefined
    }
    case 'dynamicToolCall': {
      const tool = stringValue(value.tool)
      const namespace = stringValue(value.namespace)
      return tool ? (namespace ? `${namespace}.${tool}` : tool) : undefined
    }
    case 'collabAgentToolCall':
      return stringValue(value.tool) ? `collaboration.${stringValue(value.tool)}` : undefined
    case 'webSearch':
      return 'web_search'
    case 'imageView':
      return 'view_image'
    case 'sleep':
      return 'sleep'
    case 'imageGeneration':
      return 'image_generation'
    case 'contextCompaction':
      return 'context_compaction'
    default:
      return undefined
  }
}

function fileChangePaths(value: unknown): string[] {
  return arrayValue(value).flatMap(change => {
    const path = stringValue(jsonObject(change).path)
    return path ? [path] : []
  })
}

function trajectoryHeader(turn: RuntimeTurn): BackgroundAgentJobTurnTrajectoryHeader {
  const projectionState: SanitizeState = { redacted: turn.redacted, truncated: turn.contentTruncated }
  for (const key of turn.itemOrder) {
    const item = turn.items.get(key)
    if (item) projectThreadItem(item, projectionState)
  }
  const metadata = jsonObject({
    ...(projectionState.redacted ? { redacted: true } : {}),
    ...(projectionState.truncated ? { content_truncated: true } : {})
  })

  return {
    format: 'ankole_chatml',
    version: 1,
    ...(Object.keys(metadata).length > 0 ? { metadata } : {})
  }
}

function pendingTrajectoryGroups(turn: RuntimeTurn): BackgroundAgentJobTurnTrajectoryGroup[] {
  const state: SanitizeState = { redacted: turn.redacted, truncated: turn.contentTruncated }

  return turn.itemOrder.flatMap(key => {
    if (turn.enqueuedItemKeys.has(key)) return []
    const item = turn.items.get(key)
    const position = turn.itemPositions.get(key)
    if (!item || position === undefined) return []
    const messages = projectThreadItem(item, state)
    if (messages.length === 0) return []
    return [
      {
        position,
        item_key: key,
        messages: messages as BackgroundAgentJobTurnTrajectoryMessage[]
      }
    ]
  })
}

function projectThreadItem(value: JSONObject, state: SanitizeState): JSONObject[] {
  const item = value as unknown as ThreadItem
  switch (item.type) {
    case 'userMessage':
      return [
        jsonObject({
          id: item.clientId ?? item.id,
          role: 'user',
          content: userContent(item.content)
        })
      ]
    case 'hookPrompt':
      return [jsonObject({ id: item.id, role: 'developer', content: boundedJSONString(item.fragments, state) })]
    case 'agentMessage':
      return [
        jsonObject({
          id: item.id,
          role: 'assistant',
          content: item.text,
          metadata: { phase: item.phase ?? 'assistant' }
        })
      ]
    case 'plan':
      return [assistantPhase(item.id, item.text, 'plan')]
    case 'reasoning': {
      const summary = item.summary.filter(Boolean).join('\n')
      return summary ? [assistantPhase(item.id, summary, 'reasoning_summary')] : []
    }
    case 'commandExecution':
      return toolPair(
        item.id,
        toolName(value) ?? 'shell',
        { command: item.command, cwd: item.cwd },
        item.aggregatedOutput ?? '',
        { status: item.status, exit_code: item.exitCode, duration_ms: item.durationMs },
        state
      )
    case 'fileChange':
      return toolPair(
        item.id,
        toolName(value) ?? 'apply_patch',
        { changes: item.changes },
        '',
        { status: item.status },
        state
      )
    case 'mcpToolCall':
      return toolPair(
        item.id,
        toolName(value) ?? `${item.server}.${item.tool}`,
        item.arguments,
        item.result ?? item.error ?? '',
        { status: item.status, duration_ms: item.durationMs },
        state
      )
    case 'dynamicToolCall': {
      const name = toolName(value) ?? item.tool
      if (item.tool === 'request_user_input' && item.status === 'inProgress') {
        return [toolCallMessage(item.id, name, item.arguments, { status: 'pending_user_input' }, state)]
      }
      return toolPair(
        item.id,
        name,
        item.arguments,
        item.contentItems ?? '',
        { status: item.status, success: item.success, duration_ms: item.durationMs },
        state
      )
    }
    case 'collabAgentToolCall':
      return collabAgentToolPair(item, state)
    case 'webSearch':
      return toolPair(
        item.id,
        toolName(value) ?? 'web_search',
        { query: item.query, action: item.action },
        '',
        { status: 'completed' },
        state
      )
    case 'imageView':
      return toolPair(item.id, toolName(value) ?? 'view_image', { path: item.path }, '', { status: 'completed' }, state)
    case 'sleep':
      return toolPair(
        item.id,
        toolName(value) ?? 'sleep',
        { duration_ms: item.durationMs },
        '',
        { status: 'completed' },
        state
      )
    case 'imageGeneration':
      return toolPair(item.id, toolName(value) ?? 'image_generation', item, '', { status: 'completed' }, state)
    case 'enteredReviewMode':
      return [assistantPhase(item.id, item.review, 'entered_review_mode')]
    case 'exitedReviewMode':
      return [assistantPhase(item.id, item.review, 'exited_review_mode')]
    case 'contextCompaction':
      return toolPair(item.id, toolName(value) ?? 'context_compaction', {}, '', { status: 'completed' }, state)
    default:
      return []
  }
}

function collabAgentToolPair(item: CollabAgentToolCall, state: SanitizeState): JSONObject[] {
  return toolPair(
    item.id,
    `collaboration.${item.tool}`,
    collabAgentToolArguments(item),
    collabAgentToolOutcome(item),
    { status: item.status },
    state
  )
}

function collabAgentToolArguments(item: CollabAgentToolCall): JSONObject {
  switch (item.tool) {
    case 'spawnAgent':
      return jsonObject({
        ...(item.prompt === null ? {} : { prompt: item.prompt }),
        ...(item.model === null ? {} : { model: item.model }),
        ...(item.reasoningEffort === null ? {} : { reasoning_effort: item.reasoningEffort })
      })
    case 'sendInput':
      return jsonObject({
        receiver_thread_ids: item.receiverThreadIds,
        ...(item.prompt === null ? {} : { input: item.prompt })
      })
    case 'resumeAgent':
    case 'wait':
    case 'closeAgent':
      return jsonObject({ receiver_thread_ids: item.receiverThreadIds })
    default:
      return unsupportedCollabAgentTool(item.tool)
  }
}

function collabAgentToolOutcome(item: CollabAgentToolCall): JSONObject {
  const threadIDs = [...new Set([...item.receiverThreadIds, ...Object.keys(item.agentsStates)])]
  return jsonObject({
    status: item.status,
    agents: threadIDs.map(threadID => {
      const agent = item.agentsStates[threadID]
      return {
        thread_id: threadID,
        ...(agent ? { status: agent.status } : {}),
        ...(agent?.message === null || agent?.message === undefined ? {} : { message: agent.message })
      }
    })
  })
}

function unsupportedCollabAgentTool(tool: never): never {
  throw new Error(`Unsupported collaboration tool: ${String(tool)}`)
}

function assistantPhase(id: string, content: string, phase: string): JSONObject {
  return jsonObject({ id, role: 'assistant', content, metadata: { phase } })
}

function toolPair(
  id: string,
  name: string,
  args: unknown,
  result: unknown,
  metadata: unknown,
  state: SanitizeState
): JSONObject[] {
  return [
    toolCallMessage(id, name, args, undefined, state),
    jsonObject({
      id: `${id}:result`,
      role: 'tool',
      tool_call_id: id,
      name,
      content: typeof result === 'string' ? result : boundedJSONString(result ?? '', state),
      metadata
    })
  ]
}

function toolCallMessage(id: string, name: string, args: unknown, metadata: unknown, state: SanitizeState): JSONObject {
  return jsonObject({
    id: `${id}:call`,
    role: 'assistant',
    content: '',
    tool_calls: [
      {
        id,
        type: 'function',
        function: { name, arguments: boundedJSONString(args ?? {}, state) }
      }
    ],
    ...(metadata ? { metadata } : {})
  })
}

function userContent(content: unknown): string | JSONObject[] {
  const items = arrayValue(content).map(item => jsonObject(item))
  if (items.every(item => item.type === 'text')) return items.map(item => stringValue(item.text) ?? '').join('')
  return items
}

function sameUserContent(left: unknown, right: unknown): boolean {
  const leftContent = userContent(left)
  const rightContent = userContent(right)
  return typeof leftContent === 'string' && typeof rightContent === 'string'
    ? leftContent === rightContent
    : JSON.stringify(leftContent) === JSON.stringify(rightContent)
}

function itemKey(item: JSONObject): string | undefined {
  const id = stringValue(item.id)
  if (!id) return undefined
  return item.type === 'userMessage' && stringValue(item.clientId) ? `client:${stringValue(item.clientId)}` : id
}

function shouldRecordItem(item: JSONObject): boolean {
  return item.type !== 'subAgentActivity'
}

function turnKind(items: JSONObject[]): BackgroundAgentJobTurnKind {
  return items.some(item => item.type === 'contextCompaction') ? 'compaction' : 'agent'
}

function nextTurnKind(turn: RuntimeTurn): BackgroundAgentJobTurnKind {
  return turn.kind === 'compaction' ? 'compaction' : turnKind([...turn.items.values()])
}

function turnStatus(value: unknown): BackgroundAgentJobTurnStatus | undefined {
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

function terminal(status: BackgroundAgentJobTurnStatus): boolean {
  return status === 'completed' || status === 'failed' || status === 'interrupted'
}

function sanitizeValue(value: unknown, state: SanitizeState, depth = 0, key?: string): unknown {
  if (key && sensitiveKey(key)) {
    state.redacted = true
    return redactionMarker
  }
  if (depth > maxValueDepth) {
    state.truncated = true
    return truncationMarker
  }
  if (typeof value === 'string') return sanitizeString(value, state)
  if (typeof value === 'number' || typeof value === 'boolean' || value === null) return value
  if (Array.isArray(value)) {
    if (value.length > maxCollectionItems) state.truncated = true
    return value.slice(0, maxCollectionItems).map(item => sanitizeValue(item, state, depth + 1))
  }
  if (value && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
    if (entries.length > maxCollectionItems) state.truncated = true
    return Object.fromEntries(
      entries
        .slice(0, maxCollectionItems)
        .map(([nestedKey, nested]) => [
          sanitizeMapKey(nestedKey, state),
          sanitizeValue(nested, state, depth + 1, nestedKey)
        ])
    )
  }
  return null
}

function sanitizeMapKey(value: string, state: SanitizeState): string {
  const key = sanitizeBinaryOutput(value)
  if (key !== value) state.truncated = true
  if (utf8ByteLength(key) <= maxMapKeyBytes) return key
  state.truncated = true
  return `${truncateUTF8Safe(key, maxMapKeyBytes - utf8ByteLength(truncationMarker))}${truncationMarker}`
}

function sanitizeString(value: string, state: SanitizeState): string {
  let text = sanitizeBinaryOutput(value)
  if (text !== value) state.truncated = true
  const redacted = redactText(text)
  if (redacted !== text) state.redacted = true
  text = redacted
  if (utf8ByteLength(text) <= maxStringBytes) return text
  state.truncated = true
  return truncateUTF8Window(text, maxStringBytes)
}

function redactText(value: string): string {
  return value
    .replace(/-----BEGIN [^-\n]*PRIVATE KEY-----[\s\S]*?-----END [^-\n]*PRIVATE KEY-----/gi, redactionMarker)
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, `Bearer ${redactionMarker}`)
    .replace(/\bsk-[A-Za-z0-9_-]{8,}/g, redactionMarker)
    .replace(/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g, redactionMarker)
    .replace(
      /\b(api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|session[_-]?token|password|passphrase|secret|credential|authorization|cookie|private[_-]?key|signature)\b(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)/gi,
      (_match, label: string, separator: string) => `${label}${separator}${redactionMarker}`
    )
}

function sensitiveKey(value: string): boolean {
  const key = value
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .replace(/-/g, '_')
    .toLowerCase()
  return /(?:^|_)(?:authorization|proxy_authorization|apikey|api_key|token|access_token|refresh_token|id_token|auth_token|bearer_token|session_token|secret|client_secret|password|password_hash|passphrase|cookie|set_cookie|signature|credential|credentials|private_key|private_key_pem|secret_access_key|access_key_id)$/.test(
    key
  )
}

function boundedJSONString(value: unknown, state: SanitizeState): string {
  const serialized = JSON.stringify(value ?? null)
  if (utf8ByteLength(serialized) <= maxToolArgumentsBytes) return serialized
  state.truncated = true
  // The preview is encoded once more as a JSON string, where quotes and
  // backslashes can double. Half the budget is therefore a hard upper bound.
  const preview = truncateUTF8Window(serialized, (maxToolArgumentsBytes - 1_024) / 2)
  return JSON.stringify({ truncated: true, preview })
}

function truncateUTF8Window(value: string, maxBytes: number): string {
  if (utf8ByteLength(value) <= maxBytes) return value
  const available = Math.max(0, maxBytes - utf8ByteLength(truncationMarker))
  const headBytes = Math.ceil(available / 2)
  const tailBytes = available - headBytes
  return `${truncateUTF8Safe(value, headBytes)}${truncationMarker}${truncateUTF8SuffixSafe(value, tailBytes)}`
}

function truncateUTF8SuffixSafe(value: string, maxBytes: number): string {
  if (maxBytes <= 0) return ''
  if (utf8ByteLength(value) <= maxBytes) return value

  let low = 0
  let high = value.length
  let best = ''
  while (low <= high) {
    const middle = Math.floor((low + high) / 2)
    let start = middle
    const current = value.charCodeAt(start)
    const previous = value.charCodeAt(start - 1)
    if (current >= 0xdc00 && current <= 0xdfff && previous >= 0xd800 && previous <= 0xdbff) start += 1
    const candidate = value.slice(start)
    if (utf8ByteLength(candidate) <= maxBytes) {
      best = candidate
      high = middle - 1
    } else {
      low = middle + 1
    }
  }
  return best
}

function timestampSeconds(value: unknown): string | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? new Date(value * 1_000).toISOString() : undefined
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function now(): string {
  return new Date().toISOString()
}

class BackgroundAgentJobTurnPersistenceRejectedError extends Error {
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
    super(`BackgroundAgentJob Turn persistence failed: ${cause instanceof Error ? cause.message : String(cause)}`, {
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
