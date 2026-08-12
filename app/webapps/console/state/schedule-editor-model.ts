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
    const kind = (scheduleKind.value || 'cron') as ScheduleKind
    if (kind === 'cron') {
      const expression = cronExpression.value.trim()
      if (!expression) return null
      const out: Record<string, unknown> = { kind: 'cron', expression }
      if (timezone.value.trim()) out.timezone = timezone.value.trim()
      return out
    }
    const ms = Number(everyMs.value)
    if (!Number.isFinite(ms) || ms <= 0) return null
    const out: Record<string, unknown> = { kind: 'every', every_ms: Math.floor(ms) }
    if (anchorAt.value.trim()) out.anchor_at = anchorAt.value.trim()
    return out
  }

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
      const currentStatus = status.value || 'active'
      body.status = currentStatus
      const tz = timezone.value.trim()
      body.timezone = tz || null
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
      const tz = timezone.value.trim()
      if (scheduleFieldsChanged(original)) body.schedule = schedule
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
