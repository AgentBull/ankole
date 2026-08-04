import { batch, createModel, signal } from '@preact/signals-react'

/**
 * Editor model for one cron schedule.
 *
 * The wire shape splits across several JSON-value fields the backend validates
 * loosely (`schedule`, `delivery`, `payload`), so the model flattens them into
 * individually editable signals and reassembles them on save.
 */

export type CronStatus = 'active' | 'paused'

export type ScheduleKind = 'cron' | 'every'

export type ScheduleEditorDraft = {
  sessionId: string
  bindingName: string
  name: string
  status: CronStatus | ''
  scheduleKind: ScheduleKind | ''
  cronExpression: string
  everyMs: string
  anchorAt: string
  timezone: string
  deliveryChannelId: string
  deliveryThreadId: string
  payload: string
  idempotencyKey: string
}

export type CronCreateBody = {
  session_id: string
  binding_name: string
  name: string
  status?: CronStatus
  schedule: Record<string, unknown>
  timezone?: string | null
  payload?: unknown
  delivery: { signal_channel_id: string; provider_thread_id?: string }
  idempotency_key: string
}

export type CronUpdateBody = {
  name?: string
  schedule?: Record<string, unknown>
  timezone?: string | null
  payload?: unknown
  delivery?: { signal_channel_id: string; provider_thread_id?: string }
}

export const ScheduleEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const sessionId = signal('')
  const bindingName = signal('')
  const name = signal('')
  const status = signal<CronStatus | ''>('')
  const scheduleKind = signal<ScheduleKind | ''>('cron')
  const cronExpression = signal('')
  const everyMs = signal('')
  const anchorAt = signal('')
  const timezone = signal('')
  const deliveryChannelId = signal('')
  const deliveryThreadId = signal('')
  const payload = signal('{}')
  const idempotencyKey = signal('')
  const initialDraft = signal<ScheduleEditorDraft>()
  const validationError = signal<string>()

  const apply = (draft: ScheduleEditorDraft) => {
    batch(() => {
      sessionId.value = draft.sessionId
      bindingName.value = draft.bindingName
      name.value = draft.name
      status.value = draft.status
      scheduleKind.value = draft.scheduleKind
      cronExpression.value = draft.cronExpression
      everyMs.value = draft.everyMs
      anchorAt.value = draft.anchorAt
      timezone.value = draft.timezone
      deliveryChannelId.value = draft.deliveryChannelId
      deliveryThreadId.value = draft.deliveryThreadId
      payload.value = draft.payload
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

  const buildDelivery = (): { signal_channel_id: string; provider_thread_id?: string } | null => {
    const signal_channel_id = deliveryChannelId.value.trim()
    if (!signal_channel_id) return null
    const out: { signal_channel_id: string; provider_thread_id?: string } = { signal_channel_id }
    if (deliveryThreadId.value.trim()) out.provider_thread_id = deliveryThreadId.value.trim()
    return out
  }

  const buildPayload = (): unknown => {
    try {
      return JSON.parse(payload.value || '{}')
    } catch {
      return null
    }
  }

  const scheduleFieldsChanged = (original: ScheduleEditorDraft): boolean =>
    original.scheduleKind !== scheduleKind.value ||
    original.cronExpression.trim() !== cronExpression.value.trim() ||
    original.everyMs.trim() !== everyMs.value.trim() ||
    original.anchorAt.trim() !== anchorAt.value.trim() ||
    original.timezone.trim() !== timezone.value.trim()

  const deliveryFieldsChanged = (original: ScheduleEditorDraft): boolean =>
    original.deliveryChannelId.trim() !== deliveryChannelId.value.trim() ||
    original.deliveryThreadId.trim() !== deliveryThreadId.value.trim()

  return {
    sourceKey,
    sessionId,
    bindingName,
    name,
    status,
    scheduleKind,
    cronExpression,
    everyMs,
    anchorAt,
    timezone,
    deliveryChannelId,
    deliveryThreadId,
    payload,
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
    toCreateBody(): CronCreateBody | null {
      const schedule = buildSchedule()
      const delivery = buildDelivery()
      const nextPayload = buildPayload()
      const session = sessionId.value.trim()
      const binding = bindingName.value.trim()
      const trimmedName = name.value.trim()
      const idempotency = idempotencyKey.value.trim()
      if (!session || !binding || !trimmedName || !schedule || !delivery || !idempotency || nextPayload === null) {
        return null
      }
      const body: CronCreateBody = {
        session_id: session,
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
      if (!schedule || !delivery || !original || nextPayload === null) return null
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
