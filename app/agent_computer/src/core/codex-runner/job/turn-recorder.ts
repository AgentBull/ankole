import { jsonObject, ms, recordValue, stringArg, type JsonObject as JSONObject } from '@agentbull/active-support'
import { sanitizeTurnContent } from './turn-content'
import type { JobTurnRef } from '../../../lanes/session-lane'
import { type BackgroundAgentJobTurnUpsertResponse } from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { type RPCRequestInit } from '../../../lanes/rpc-contract'
import type { BackgroundAgentJobTurnPlan, BackgroundAgentJobTurnKind } from '../../background-agent-job-documents'
import type { JSONRPCMessage } from '../runtime/app-server-client'
import { boundedFilesChangedFromCodexDiff, normalizeCodexThreadUsage } from '../protocol'
import { boundedBackgroundAgentJobPaths } from '../../background-agent-job-handoff'
import type { WorkerTurnTrace } from '../../../observability/turn-tracing'
import { CodexTurnTrace } from './turn-tracing'
import { projectCodexToolItem, sameToolIdentity, type CodexToolItem } from './tool-item'
import type { DriveView } from '../../../drive/mounts'
import {
  agentMessagePayload,
  arrayValue,
  buildTurnUpsertRequest,
  collaborationToolName,
  collaborationToolOutcome,
  errorType,
  fallbackCollaborationTool,
  fileChangePaths,
  itemKey,
  now,
  parseJSONValue,
  persistTurnCheckpointWithRetry,
  planStatus,
  sameUserContent,
  shouldRecordItem,
  terminal,
  timestampDate,
  timestampSeconds,
  traceTurnError,
  traceTurnOutput,
  turnStatus,
  type DeferredCollaborationCall,
  type ItemEntry,
  type PendingCollaborationCall,
  type RuntimeTurn
} from './turn-recorder-helpers'

// Coalesce event bursts before a progress checkpoint. flush() still bypasses
// this delay at every durability boundary.
const checkpointDelayMs = ms('5s')
/** Child inputs kept per thread while their activity has not arrived. */
const maxUnmatchedChildInputs = 8

/**
 * Converts Codex events for one Job attempt into ordered durable Turn records.
 * Item keys make repeated events idempotent. flush() is the durability fence
 * before the Job status can commit.
 */
export class BackgroundAgentJobTurnRecorder {
  private driveWindow?: Map<string, number>
  private readonly turns = new Map<string, RuntimeTurn>()
  private readonly pendingCollaborationCalls = new Map<string, PendingCollaborationCall>()
  /** Activity-only calls per child thread, in arrival order, waiting for that thread's next input. */
  private readonly deferredCollaborationCalls = new Map<string, DeferredCollaborationCall[]>()
  /** Child inputs per thread, in arrival order, that arrived before their activity. */
  private readonly unmatchedChildInputs = new Map<string, string[]>()
  private leadThreadID: string | undefined
  private readonly timers = new Map<string, ReturnType<typeof setTimeout>>()
  private tail: Promise<void> = Promise.resolve()
  private checkpointError: unknown

  constructor(
    private readonly input: {
      jobID: string
      attempt: number
      actorTurn: JobTurnRef
      upsert: (
        request: RPCRequestInit<'background_agent_job.turn.upsert'>
      ) => Promise<BackgroundAgentJobTurnUpsertResponse>
      checkpointDelayMs?: number
      turnTrace?: WorkerTurnTrace
      driveView?: DriveView
    }
  ) {}

  async startDriveWindow(): Promise<void> {
    this.driveWindow = await this.input.driveView?.sequence()
  }

  async flushDriveWindow(): Promise<string> {
    const window = this.driveWindow
    this.driveWindow = undefined
    return window ? this.input.driveView!.flush(window) : ''
  }

  /**
   * Records a started Turn from the `{ threadId, turn }` shape that Codex
   * returns from `turn/start` and sends in `turn/started`. The session declares
   * `kind`; the recorder never infers it from items, so an automatic
   * compaction stays an item of the agent Turn that contains it.
   */
  recordTurnStarted(
    params: JSONObject,
    kind: BackgroundAgentJobTurnKind,
    input?: string,
    clientUserMessageID?: string
  ): void {
    const payload = recordValue(params.turn) ?? {}
    const runtimeTurnID = stringArg(payload, 'id')
    if (!runtimeTurnID) return
    const runtimeThreadID =
      stringArg(params, 'threadId') ??
      this.turns.get(runtimeTurnID)?.runtimeThreadID ??
      [...this.turns.values()].at(-1)?.runtimeThreadID
    if (!runtimeThreadID) return
    // Only the session starts a Turn with input, and only on the lead thread.
    if (input !== undefined) this.leadThreadID = runtimeThreadID

    let turn = this.turns.get(runtimeTurnID)
    if (!turn) {
      const startedAt = timestampSeconds(payload.startedAt) ?? now()
      turn = {
        runtimeThreadID,
        runtimeTurnID,
        kind,
        status: turnStatus(payload.status) ?? 'in_progress',
        revision: -1,
        items: new Map(),
        itemOrder: [],
        itemPositions: new Map(),
        nextTrajectoryPosition: 0,
        enqueuedItemKeys: new Set(),
        completedItemIDs: new Set(),
        modelToolIdentities: new Map(),
        toolItemIdentities: new Map(),
        toolItemExecutionMechanisms: new Map(),
        usedSkillNames: new Set(),
        filesChanged: new Set(),
        error: {},
        startedAt,
        trace: CodexTurnTrace.start(
          this.input.turnTrace,
          runtimeThreadID,
          runtimeTurnID,
          timestampDate(payload.startedAt),
          input
        ),
        dirty: true,
        redacted: false,
        contentTruncated: false
      }
      this.turns.set(runtimeTurnID, turn)
    }

    this.ensureInitialInput(turn, input, clientUserMessageID)
    if (input) turn.trace?.setInput(input)
    this.applyCanonicalItems(turn, payload)
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
      turn.trace?.finish(traceTurnError(turn), timestampDate(payload.completedAt), traceTurnOutput(payload))
      this.markDirty(turn, true)
    } else {
      this.markDirty(turn, true)
    }
  }

  handleNotification(message: JSONRPCMessage): void {
    const params = jsonObject(message.params)

    switch (message.method) {
      case 'turn/completed':
        this.completeTurn(params)
        return
      case 'item/started':
        this.startItem(params)
        return
      case 'item/completed':
        this.completeItem(params)
        return
      case 'rawResponseItem/completed':
        this.completeRawResponseItem(params)
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
    const resolvedTurnID = stringArg(params, 'turnId') ?? turnID
    if (!resolvedTurnID) return
    const turn = this.turns.get(resolvedTurnID)
    if (!turn) return
    const id = stringArg(params, 'itemId') ?? `request-user-input:${requestID ?? resolvedTurnID}`
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
    this.settleDeferredCollaborationCalls(turn.runtimeTurnID)
    turn.status = 'interrupted'
    turn.error = this.sanitizeObject({ ...turn.error, ...error }, turn)
    turn.completedAt ??= now()
    turn.activeItem = undefined
    turn.trace?.finish(errorType(turn.error) ?? 'codex_turn_interrupted')
    this.markDirty(turn, true)
  }

  finishTurn(turnID: string | undefined, status: 'failed' | 'stopped', error: JSONObject = {}): void {
    const turn = turnID ? this.turns.get(turnID) : undefined
    if (!turn || terminal(turn.status)) return
    this.settleDeferredCollaborationCalls(turn.runtimeTurnID)
    turn.status = status === 'failed' ? 'failed' : 'interrupted'
    turn.error = this.sanitizeObject(error, turn)
    turn.completedAt = now()
    turn.activeItem = undefined
    turn.trace?.finish(errorType(turn.error) ?? `codex_turn_${turn.status}`)
    this.markDirty(turn, true)
  }

  async flush(): Promise<void> {
    this.settleDeferredCollaborationCalls()
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

  private completeTurn(params: JSONObject): void {
    const payload = recordValue(params.turn) ?? {}
    const runtimeTurnID = stringArg(payload, 'id')
    if (!runtimeTurnID) return

    let turn = this.turns.get(runtimeTurnID)
    if (!turn) {
      this.recordTurnStarted(params, 'agent')
      turn = this.turns.get(runtimeTurnID)
    }
    if (!turn) return

    this.applyCanonicalItems(turn, payload, true)
    this.settleDeferredCollaborationCalls(runtimeTurnID)
    const reportedStatus = turnStatus(payload.status) ?? 'failed'
    const acceptsReportedTerminal = !terminal(turn.status) || reportedStatus === turn.status
    if (!terminal(turn.status)) turn.status = reportedStatus
    const payloadError = jsonObject(payload.error)
    if (acceptsReportedTerminal && Object.keys(payloadError).length > 0) {
      turn.error = this.sanitizeObject(payloadError, turn)
    }
    turn.completedAt ??= timestampSeconds(payload.completedAt) ?? now()
    turn.activeItem = undefined
    turn.trace?.finish(traceTurnError(turn), timestampDate(payload.completedAt), traceTurnOutput(payload))
    this.markDirty(turn, true)
  }

  private startItem(params: JSONObject): void {
    const turn = this.turn(params)
    const item = jsonObject(params.item)
    const id = stringArg(item, 'id')
    if (!turn || !id || !shouldRecordItem(item) || terminal(turn.status) || turn.completedItemIDs.has(id)) return
    const tool = projectCodexToolItem(item, turn.modelToolIdentities.get(id))
    if (!tool) return
    const { identity } = tool
    if (item.type !== 'collabAgentToolCall') turn.trace?.startTool(tool)
    if (turn.activeItem?.id === id && sameToolIdentity(turn.activeItem, identity)) return
    if (item.type === 'collabAgentToolCall') {
      if (this.pendingCollaborationCalls.has(id)) return
      turn.activeItem = { id, ...identity }
      this.markDirty(turn, true)
      return
    }
    turn.activeItem = { id, ...identity }
    this.markDirty(turn, true)
  }

  private completeItem(params: JSONObject): void {
    const turn = this.turn(params)
    const rawItem = jsonObject(params.item)
    const id = stringArg(rawItem, 'id')
    if (!turn || !id) return
    if (rawItem.type === 'subAgentActivity') {
      this.completeSubAgentActivity(turn, rawItem)
      return
    }
    if (!shouldRecordItem(rawItem)) return
    if (rawItem.type === 'collabAgentToolCall') {
      if (turn.activeItem?.id === id) {
        turn.activeItem = undefined
        this.markDirty(turn, true)
      }
      return
    }
    this.recordCompletedItem(turn, rawItem)
  }

  private recordCompletedItem(turn: RuntimeTurn, rawItem: JSONObject): void {
    const id = stringArg(rawItem, 'id')
    if (!id) return
    const redacted = turn.redacted
    const truncated = turn.contentTruncated
    const tool = projectCodexToolItem(rawItem, turn.modelToolIdentities.get(id))
    const item = this.canonicalItem(turn, rawItem, tool)
    const key = itemKey(item)
    if (!key) return
    const alreadyEnqueued = turn.enqueuedItemKeys.has(key)
    if (alreadyEnqueued && turn.activeItem?.id === id) {
      turn.activeItem = undefined
      this.markDirty(turn, true)
    }
    if (alreadyEnqueued) return
    const changed = JSON.stringify(turn.items.get(key)) !== JSON.stringify(item)
    if (changed) this.putCanonicalEntry(turn, { key, item })
    const tracked = this.trackCompletedItem(turn, item, tool)
    if (tracked && tool) turn.trace?.finishTool(tool)
    const cleared = turn.activeItem?.id === id
    if (cleared) turn.activeItem = undefined
    if (changed || tracked || cleared || redacted !== turn.redacted || truncated !== turn.contentTruncated) {
      this.markDirty(turn, true)
    }
  }

  private completeRawResponseItem(params: JSONObject): void {
    const item = recordValue(params.item) ?? {}
    if (item.type === 'agent_message') {
      // The child's turn can be unknown here; the thread ID alone routes the input.
      const threadID = stringArg(params, 'threadId')
      if (threadID) this.observeChildInput(threadID, agentMessagePayload(item.content))
      return
    }
    const callID = stringArg(item, 'call_id')
    if (!callID) return

    if (item.type === 'function_call') {
      const turn = this.turn(params)
      const name = stringArg(item, 'name')
      const namespace = stringArg(item, 'namespace')
      if (turn && name) turn.modelToolIdentities.set(callID, { ...(namespace ? { namespace } : {}), name })

      const tool = collaborationToolName(item)
      if (
        !tool ||
        !turn ||
        terminal(turn.status) ||
        turn.completedItemIDs.has(callID) ||
        this.pendingCollaborationCalls.has(callID)
      ) {
        return
      }
      const argumentsValue = parseJSONValue(item.arguments, {})
      this.pendingCollaborationCalls.set(callID, {
        runtimeTurnID: turn.runtimeTurnID,
        tool,
        arguments: argumentsValue
      })
      this.startItem(
        jsonObject({
          turnId: turn.runtimeTurnID,
          item: { type: 'dynamicToolCall', id: callID, namespace: 'collaboration', tool, arguments: argumentsValue }
        })
      )
      return
    }

    if (item.type !== 'function_call_output') return
    const pending = this.pendingCollaborationCalls.get(callID)
    if (!pending) return
    this.pendingCollaborationCalls.delete(callID)
    const turn = this.turns.get(pending.runtimeTurnID)
    if (!turn) return
    const output = collaborationToolOutcome(item.output, pending.activity)
    this.recordCompletedItem(
      turn,
      jsonObject({
        type: 'dynamicToolCall',
        id: callID,
        namespace: 'collaboration',
        tool: pending.tool,
        arguments: pending.arguments,
        arguments_source: 'raw_function_call',
        status: 'completed',
        contentItems: output,
        success: null,
        durationMs: null
      })
    )
  }

  private completeSubAgentActivity(turn: RuntimeTurn, item: JSONObject): void {
    const id = stringArg(item, 'id')
    const kind = stringArg(item, 'kind')
    const agentThreadID = stringArg(item, 'agentThreadId')
    const agentPath = stringArg(item, 'agentPath')
    if (!id || !kind || !agentThreadID || !agentPath) return
    const activity = { kind, agentThreadID, agentPath }
    const pending = this.pendingCollaborationCalls.get(id)
    if (pending) {
      pending.activity = activity
      return
    }

    const deferred = { runtimeTurnID: turn.runtimeTurnID, id, activity }
    if (kind !== 'started' && kind !== 'interacted') {
      this.recordDeferredCollaborationCall(deferred)
      return
    }
    const input = this.unmatchedChildInputs.get(agentThreadID)?.shift()
    if (input !== undefined) {
      this.recordDeferredCollaborationCall(deferred, input)
      return
    }
    const queue = this.deferredCollaborationCalls.get(agentThreadID) ?? []
    queue.push(deferred)
    this.deferredCollaborationCalls.set(agentThreadID, queue)
  }

  /**
   * A `started` activity takes the child's first turn input as its brief; an
   * `interacted` activity takes the child's next turn input as its message.
   * Without an input the record keeps the activity alone and says so.
   */
  private recordDeferredCollaborationCall(call: DeferredCollaborationCall, input?: string): void {
    const turn = this.turns.get(call.runtimeTurnID)
    if (!turn) return
    const { kind, agentPath } = call.activity
    const argumentsValue =
      input === undefined ? {} : kind === 'started' ? { message: input } : { target: agentPath, message: input }
    this.recordCompletedItem(
      turn,
      jsonObject({
        type: 'dynamicToolCall',
        id: call.id,
        namespace: 'collaboration',
        tool: fallbackCollaborationTool(kind),
        arguments: argumentsValue,
        arguments_source: input === undefined ? 'activity_fallback' : 'child_initial_input',
        status: 'completed',
        contentItems: collaborationToolOutcome('', call.activity),
        success: null,
        durationMs: null
      })
    )
  }

  /**
   * Inputs and activities of one child thread arrive in the same order on both
   * sides, so the oldest unmatched entry on either side pairs with the next
   * arrival on the other side.
   */
  private observeChildInput(threadID: string, text: string | undefined): void {
    if (!text || threadID === this.leadThreadID) return
    const deferred = this.deferredCollaborationCalls.get(threadID)?.shift()
    if (deferred) {
      this.recordDeferredCollaborationCall(deferred, text)
      return
    }
    const inputs = this.unmatchedChildInputs.get(threadID) ?? []
    inputs.push(text)
    if (inputs.length > maxUnmatchedChildInputs) inputs.shift()
    this.unmatchedChildInputs.set(threadID, inputs)
  }

  /** Records the deferred calls of one Turn, or of every Turn, at a durability point. */
  private settleDeferredCollaborationCalls(runtimeTurnID?: string): void {
    for (const [threadID, queue] of this.deferredCollaborationCalls) {
      const remaining = queue.filter(call => {
        if (runtimeTurnID !== undefined && call.runtimeTurnID !== runtimeTurnID) return true
        this.recordDeferredCollaborationCall(call)
        return false
      })
      if (remaining.length === 0) this.deferredCollaborationCalls.delete(threadID)
      else this.deferredCollaborationCalls.set(threadID, remaining)
    }
  }

  private updateTurnPlan(params: JSONObject): void {
    const turn = this.turn(params)
    if (!turn) return
    const steps = arrayValue(params.plan).flatMap(step => {
      const value = recordValue(step)
      const text = stringArg(value, 'step')
      const status = planStatus(value?.status)
      return text && status ? [{ step: text, status }] : []
    })
    const explanation = stringArg(params, 'explanation')
    const candidate = this.sanitizeObject(
      {
        ...(explanation ? { explanation } : {}),
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
    const diff = stringArg(params, 'diff')
    if (!turn || diff === undefined) return
    const handoff = boundedFilesChangedFromCodexDiff(diff)
    const before = JSON.stringify([...turn.filesChanged].sort())
    const wasTruncated = turn.contentTruncated
    turn.filesChanged = new Set(handoff.paths)
    turn.contentTruncated ||= handoff.truncated
    if (JSON.stringify(handoff.paths) !== before || turn.contentTruncated !== wasTruncated) this.markDirty(turn, false)
  }

  private turn(params: JSONObject): RuntimeTurn | undefined {
    const turnID = stringArg(params, 'turnId')
    return turnID ? this.turns.get(turnID) : [...this.turns.values()].at(-1)
  }

  private ensureInitialInput(turn: RuntimeTurn, input?: string, clientUserMessageID?: string): void {
    if (!input || turn.initialItemKey) return
    const id = clientUserMessageID ?? `${turn.runtimeTurnID}:input`
    const key = `client:${id}`
    turn.initialItemKey = key
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
    if (stringArg(payload, 'itemsView') === 'notLoaded') return
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
      const id = stringArg(rawItem, 'id')
      const tool = projectCodexToolItem(rawItem, id ? turn.modelToolIdentities.get(id) : undefined)
      const item = this.canonicalItem(turn, rawItem, tool)
      const key = itemKey(item)
      if (!key) continue
      if (completed) this.trackCompletedItem(turn, item, tool)
      const existingIndex = entries.findIndex(entry => entry.key === key)
      if (existingIndex >= 0) entries[existingIndex] = { key, item }
      else entries.push({ key, item })
    }
    return entries
  }

  private canonicalItem(turn: RuntimeTurn, value: JSONObject, tool: CodexToolItem | undefined): JSONObject {
    const identifiedValue = value.type === 'mcpToolCall' && tool ? jsonObject({ ...value, ...tool.identity }) : value
    const semanticValue =
      identifiedValue.type === 'reasoning'
        ? jsonObject({
            type: identifiedValue.type,
            id: identifiedValue.id,
            summary: arrayValue(identifiedValue.summary)
          })
        : identifiedValue
    const item = this.sanitizeObject(semanticValue, turn)
    if (item.type !== 'userMessage' || stringArg(item, 'clientId') || !turn.initialItemKey) return item

    const initial = turn.items.get(turn.initialItemKey)
    if (initial?.type !== 'userMessage' || !sameUserContent(initial.content, item.content)) return item

    const clientID = stringArg(initial, 'clientId') ?? stringArg(initial, 'id')
    return clientID ? jsonObject({ ...item, clientId: clientID }) : item
  }

  private putCanonicalEntry(turn: RuntimeTurn, entry: ItemEntry): void {
    if (!turn.items.has(entry.key)) {
      turn.itemOrder.push(entry.key)
      this.assignTrajectoryPosition(turn, entry.key)
    }
    turn.items.set(entry.key, entry.item)
  }

  private trackCompletedItem(turn: RuntimeTurn, item: JSONObject, tool: CodexToolItem | undefined): boolean {
    const id = stringArg(item, 'id')
    if (!id || turn.completedItemIDs.has(id)) return false
    turn.completedItemIDs.add(id)
    if (tool) turn.toolItemIdentities.set(id, tool.identity)
    if (tool?.executionMechanism) {
      turn.toolItemExecutionMechanisms.set(id, { ...tool.identity, execution_mechanism: tool.executionMechanism })
    }
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
    const sanitized = sanitizeTurnContent(value)
    turn.redacted ||= sanitized.redacted
    turn.contentTruncated ||= sanitized.truncated
    return sanitized.value
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
    const request = buildTurnUpsertRequest(this.input.jobID, this.input.attempt, turn)
    this.tail = this.tail
      .then(async () => {
        if (this.checkpointError) return
        await persistTurnCheckpointWithRetry(this.input.upsert, request)
      })
      .catch(error => {
        this.checkpointError ??= error
      })
  }
}
