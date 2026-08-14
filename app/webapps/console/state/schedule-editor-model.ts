import { batch, createModel, signal } from '@preact/signals-react'

/**
 * Editor model for one cron schedule.
 *
 * The wire shape splits across several JSON-value fields the backend validates
 * loosely (`schedule`, `delivery`, `payload`), so the model flattens them into
 * individually editable signals and reassembles them on save. `task` edits
 * `payload.task` — the self-contained standing instruction a direct-Agent
 * schedule must carry — while the rest of the stored payload passes through
 * untouched.
 */

export type CronStatus = 'active' | 'paused'

export type ScheduleKind = 'cron' | 'every'

export type ScheduleOccurrenceBound = { count: number } | { until: string }

export type DeliveryTargetDraft = {
  bindingName: string
  channelId: string
  threadId: string
}

export type ScheduleEditorDraft = {
  ownerSessionId: string
  bindingName: string
  name: string
  status: CronStatus | ''
  scheduleKind: ScheduleKind | ''
  cronExpression: string
  everyMs: string
  anchorAt: string
  timezone: string
  occurrences?: ScheduleOccurrenceBound
  deliveryTargets: DeliveryTargetDraft[]
  task: string
  payload: string
  hasAutomationJob: boolean
  idempotencyKey: string
}

export type CronCreateBody = {
  owner_session_id: string
  binding_name: string
  name: string
  status?: CronStatus
  schedule: Record<string, unknown>
  timezone?: string | null
  payload?: unknown
  delivery: { targets: DeliveryTarget[] }
  idempotency_key: string
}

export type CronUpdateBody = {
  name?: string
  schedule?: Record<string, unknown>
  timezone?: string | null
  payload?: unknown
  delivery?: { targets: DeliveryTarget[] }
}

type DeliveryTarget = {
  binding_name: string
  signal_channel_id: string
  provider_thread_id?: string
}

/** The stored delivery projection, including the legacy single-target shape. */
export type CronDeliveryProjection = {
  targets?: Array<{
    binding_name?: string
    signal_channel_id?: string
    provider_thread_id?: string
  }>
  signal_channel_id?: string
  provider_thread_id?: string
}

/**
 * Maps a stored delivery to editable target drafts.
 *
 * Early schedules stored one target's channel at the delivery top level with no
 * `targets` list (the control plane still accepts that shape on write). Mapping
 * it to an empty list made every such schedule uneditable: the editor showed
 * one blank target whose hidden binding never matched the schedule's binding,
 * so every save failed validation.
 */
export function deliveryTargetDrafts(
  delivery: CronDeliveryProjection | null | undefined,
  bindingName: string
): DeliveryTargetDraft[] {
  const targets = Array.isArray(delivery?.targets) ? delivery.targets : []
  if (targets.length > 0) {
    return targets.map(target => ({
      bindingName: target.binding_name ?? '',
      channelId: target.signal_channel_id ?? '',
      threadId: target.provider_thread_id ?? ''
    }))
  }

  const channelId = delivery?.signal_channel_id ?? ''
  if (!channelId) return []
  return [{ bindingName, channelId, threadId: delivery?.provider_thread_id ?? '' }]
}

/** Reads the normalized occurrence bound that the editor must preserve. */
export function scheduleOccurrenceBound(schedule: Record<string, unknown>): ScheduleOccurrenceBound | undefined {
  const occurrences = schedule.occurrences
  if (!occurrences || typeof occurrences !== 'object' || Array.isArray(occurrences)) return undefined

  const count = (occurrences as { count?: unknown }).count
  if (Number.isSafeInteger(count) && Number(count) > 0) return { count: Number(count) }

  const until = (occurrences as { until?: unknown }).until
  return typeof until === 'string' && until ? { until } : undefined
}

export function isMutableCronStatus(status: string): status is CronStatus {
  return status === 'active' || status === 'paused'
}

export const ScheduleEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const ownerSessionId = signal('')
  const bindingName = signal('')
  const name = signal('')
  const status = signal<CronStatus | ''>('')
  const scheduleKind = signal<ScheduleKind | ''>('cron')
  const cronExpression = signal('')
  const everyMs = signal('')
  const anchorAt = signal('')
  const timezone = signal('')
  const deliveryTargets = signal<DeliveryTargetDraft[]>([])
  const task = signal('')
  const payload = signal('{}')
  const hasAutomationJob = signal(false)
  const idempotencyKey = signal('')
  const initialDraft = signal<ScheduleEditorDraft>()
  const validationError = signal<string>()

  const apply = (draft: ScheduleEditorDraft) => {
    batch(() => {
      ownerSessionId.value = draft.ownerSessionId
      bindingName.value = draft.bindingName
      name.value = draft.name
      status.value = draft.status
      scheduleKind.value = draft.scheduleKind
      cronExpression.value = draft.cronExpression
      everyMs.value = draft.everyMs
      anchorAt.value = draft.anchorAt
      timezone.value = draft.timezone
      deliveryTargets.value =
        draft.deliveryTargets.length > 0 ? draft.deliveryTargets.map(target => ({ ...target })) : [emptyTarget()]
      task.value = draft.task
      payload.value = draft.payload
      hasAutomationJob.value = draft.hasAutomationJob
      idempotencyKey.value = draft.idempotencyKey
      validationError.value = undefined
    })
  }

  const buildSchedule = (): Record<string, unknown> | null => {
    const occurrences = initialDraft.value?.occurrences
    const kind = (scheduleKind.value || 'cron') as ScheduleKind
    if (kind === 'cron') {
      const expression = cronExpression.value.trim()
      if (!expression) return null
      const out: Record<string, unknown> = { kind: 'cron', expression }
      if (timezone.value.trim()) out.timezone = timezone.value.trim()
      if (occurrences) out.occurrences = { ...occurrences }
      return out
    }
    const ms = Number(everyMs.value)
    if (!Number.isFinite(ms) || ms <= 0) return null
    // The planner rejects an `every` schedule without an anchor; there is no
    // server-side default.
    const anchor = anchorAt.value.trim()
    if (!anchor) return null
    return {
      kind: 'every',
      every_ms: Math.floor(ms),
      anchor_at: anchor,
      ...(occurrences ? { occurrences: { ...occurrences } } : {})
    }
  }

  // The timezone field renders only for cron schedules, so a value typed
  // before switching kinds must not ride along and stick to an `every` row.
  const effectiveTimezone = (): string => ((scheduleKind.value || 'cron') === 'cron' ? timezone.value.trim() : '')

  const buildDelivery = (): { targets: DeliveryTarget[] } | null => {
    const targets = deliveryTargets.value.map(target => {
      const out: DeliveryTarget = {
        binding_name: target.bindingName.trim(),
        signal_channel_id: target.channelId.trim()
      }
      if (target.threadId.trim()) out.provider_thread_id = target.threadId.trim()
      return out
    })

    if (
      targets.length === 0 ||
      targets.some(target => !target.binding_name || !target.signal_channel_id) ||
      targets[0]?.binding_name !== bindingName.value.trim()
    ) {
      return null
    }

    const keys = targets.map(target =>
      [target.binding_name, target.signal_channel_id, target.provider_thread_id ?? ''].join('\u0000')
    )
    if (new Set(keys).size !== keys.length) return null
    return { targets }
  }

  const buildPayload = (): Record<string, unknown> | null => {
    const parsed = parseJSON(payload.value)
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return null
    const out = { ...(parsed as Record<string, unknown>) }
    const trimmedTask = task.value.trim()
    if (trimmedTask) out.task = trimmedTask
    else delete out.task
    return out
  }

  const taskSatisfied = (): boolean => hasAutomationJob.value || Boolean(task.value.trim())

  const scheduleFieldsChanged = (original: ScheduleEditorDraft): boolean =>
    original.scheduleKind !== scheduleKind.value ||
    original.cronExpression.trim() !== cronExpression.value.trim() ||
    original.everyMs.trim() !== everyMs.value.trim() ||
    original.anchorAt.trim() !== anchorAt.value.trim() ||
    original.timezone.trim() !== timezone.value.trim()

  const deliveryFieldsChanged = (original: ScheduleEditorDraft): boolean =>
    !sameJSON(normalizeDraftTargets(original.deliveryTargets), normalizeDraftTargets(deliveryTargets.value))

  return {
    sourceKey,
    ownerSessionId,
    bindingName,
    name,
    status,
    scheduleKind,
    cronExpression,
    everyMs,
    anchorAt,
    timezone,
    deliveryTargets,
    task,
    payload,
    hasAutomationJob,
    idempotencyKey,
    validationError,
    initialize(nextSourceKey: string, draft: ScheduleEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      apply(draft)
      initialDraft.value = { ...draft }
    },
    clearValidation() {
      validationError.value = undefined
    },
    setBindingName(value: string) {
      bindingName.value = value
      const targets = deliveryTargets.value.length > 0 ? deliveryTargets.value : [emptyTarget()]
      deliveryTargets.value = targets.map((target, index) => (index === 0 ? { ...target, bindingName: value } : target))
    },
    /** Sessions and bindings name resources inside one agent; a new agent starts them over. */
    resetAgentScope() {
      batch(() => {
        ownerSessionId.value = ''
        bindingName.value = ''
        deliveryTargets.value = [emptyTarget()]
      })
    },
    addDeliveryTarget() {
      deliveryTargets.value = [...deliveryTargets.value, emptyTarget()]
    },
    updateDeliveryTarget(index: number, update: Partial<DeliveryTargetDraft>) {
      deliveryTargets.value = deliveryTargets.value.map((target, targetIndex) =>
        targetIndex === index ? { ...target, ...update } : target
      )
    },
    removeDeliveryTarget(index: number) {
      if (index === 0) return
      deliveryTargets.value = deliveryTargets.value.filter((_target, targetIndex) => targetIndex !== index)
    },
    isComplete(): boolean {
      return Boolean(
        bindingName.value.trim() &&
        name.value.trim() &&
        taskSatisfied() &&
        buildSchedule() &&
        buildDelivery() &&
        buildPayload() !== null
      )
    },
    toCreateBody(): CronCreateBody | null {
      const schedule = buildSchedule()
      const delivery = buildDelivery()
      const nextPayload = buildPayload()
      const ownerSession = ownerSessionId.value.trim()
      const binding = bindingName.value.trim()
      const trimmedName = name.value.trim()
      const idempotency = idempotencyKey.value.trim()
      if (
        !ownerSession ||
        !binding ||
        !trimmedName ||
        !schedule ||
        !delivery ||
        !idempotency ||
        nextPayload === null ||
        !taskSatisfied()
      ) {
        return null
      }
      const body: CronCreateBody = {
        owner_session_id: ownerSession,
        binding_name: binding,
        name: trimmedName,
        schedule,
        delivery,
        idempotency_key: idempotency
      }
      body.status = status.value || 'active'
      body.timezone = effectiveTimezone() || null
      body.payload = nextPayload
      return body
    },
    toUpdateBody(): CronUpdateBody | null {
      const schedule = buildSchedule()
      const delivery = buildDelivery()
      const original = initialDraft.value
      const nextPayload = buildPayload()
      if (!schedule || !delivery || !original || nextPayload === null || !taskSatisfied()) return null
      const body: CronUpdateBody = {}
      const trimmedName = name.value.trim()
      if (!trimmedName) return null
      if (trimmedName !== original.name.trim()) body.name = trimmedName
      if (scheduleFieldsChanged(original)) body.schedule = schedule
      const tz = effectiveTimezone()
      if (tz !== original.timezone.trim()) body.timezone = tz || null
      if (deliveryFieldsChanged(original)) body.delivery = delivery
      if (!sameJSON(nextPayload, parseJSON(original.payload))) body.payload = nextPayload
      return body
    }
  }
})

function parseJSON(value: string): unknown {
  try {
    return JSON.parse(value || '{}')
  } catch {
    return null
  }
}

function sameJSON(left: unknown, right: unknown): boolean {
  return JSON.stringify(left) === JSON.stringify(right)
}

function emptyTarget(): DeliveryTargetDraft {
  return { bindingName: '', channelId: '', threadId: '' }
}

function normalizeDraftTargets(targets: DeliveryTargetDraft[]): DeliveryTargetDraft[] {
  return targets.map(target => ({
    bindingName: target.bindingName.trim(),
    channelId: target.channelId.trim(),
    threadId: target.threadId.trim()
  }))
}
