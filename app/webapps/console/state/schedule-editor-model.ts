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
  bindingName: string
  name: string
  status: CronStatus | ''
  scheduleKind: ScheduleKind | ''
  cronExpression: string
  everyMs: string
  anchorAt: string
  timezone: string
  staggerMs: string
  deliveryChannelId: string
  deliveryThreadId: string
  payload: string
  idempotencyKey: string
}

export type CronCreateBody = {
  binding_name: string
  name?: string | null
  status?: CronStatus
  schedule: Record<string, unknown>
  timezone?: string | null
  payload?: unknown
  delivery: { signal_channel_id: string; provider_thread_id?: string }
  idempotency_key: string
  failure_policy?: Record<string, unknown>
}

export type CronUpdateBody = {
  name?: string | null
  schedule?: Record<string, unknown>
  timezone?: string | null
  payload?: unknown
  delivery?: { signal_channel_id: string; provider_thread_id?: string }
  failure_policy?: Record<string, unknown>
}

export const ScheduleEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const bindingName = signal('')
  const name = signal('')
  const status = signal<CronStatus | ''>('')
  const scheduleKind = signal<ScheduleKind | ''>('cron')
  const cronExpression = signal('')
  const everyMs = signal('')
  const anchorAt = signal('')
  const timezone = signal('')
  const staggerMs = signal('0')
  const deliveryChannelId = signal('')
  const deliveryThreadId = signal('')
  const payload = signal('{}')
  const idempotencyKey = signal('')
  const validationError = signal<string>()

  const apply = (draft: ScheduleEditorDraft) => {
    batch(() => {
      bindingName.value = draft.bindingName
      name.value = draft.name
      status.value = draft.status
      scheduleKind.value = draft.scheduleKind
      cronExpression.value = draft.cronExpression
      everyMs.value = draft.everyMs
      anchorAt.value = draft.anchorAt
      timezone.value = draft.timezone
      staggerMs.value = draft.staggerMs
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
      const stagger = Number(staggerMs.value)
      if (Number.isFinite(stagger) && stagger > 0) out.stagger_ms = Math.floor(stagger)
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

  return {
    sourceKey,
    bindingName,
    name,
    status,
    scheduleKind,
    cronExpression,
    everyMs,
    anchorAt,
    timezone,
    staggerMs,
    deliveryChannelId,
    deliveryThreadId,
    payload,
    idempotencyKey,
    validationError,
    initialize(nextSourceKey: string, draft: ScheduleEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      apply(draft)
    },
    clearValidation() {
      validationError.value = undefined
    },
    toCreateBody(): CronCreateBody | null {
      const schedule = buildSchedule()
      const delivery = buildDelivery()
      const binding = bindingName.value.trim()
      const idempotency = idempotencyKey.value.trim()
      if (!binding || !schedule || !delivery || !idempotency) return null
      const body: CronCreateBody = {
        binding_name: binding,
        schedule,
        delivery,
        idempotency_key: idempotency
      }
      const trimmedName = name.value.trim()
      if (trimmedName) body.name = trimmedName
      const currentStatus = status.value || 'active'
      body.status = currentStatus
      const tz = timezone.value.trim()
      body.timezone = tz || null
      body.payload = buildPayload()
      return body
    },
    toUpdateBody(): CronUpdateBody | null {
      const schedule = buildSchedule()
      const delivery = buildDelivery()
      if (!schedule || !delivery) return null
      const body: CronUpdateBody = { schedule, delivery }
      const trimmedName = name.value.trim()
      body.name = trimmedName || null
      const tz = timezone.value.trim()
      body.timezone = tz || null
      body.payload = buildPayload()
      return body
    }
  }
})
