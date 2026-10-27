import { batch, computed, createModel, signal } from '@preact/signals-react'
import { dateTimeLocalValue, instantFromDateTimeLocal } from './token-quota-editor-model'

export type ScheduleIntervalUnit = 'seconds' | 'minutes' | 'hours' | 'days'

const INTERVAL_UNIT_MS: Record<ScheduleIntervalUnit, number> = {
  seconds: 1_000,
  minutes: 60_000,
  hours: 3_600_000,
  days: 86_400_000
}

export function decomposeEveryMs(everyMs: string): { value: string; unit: ScheduleIntervalUnit } {
  const trimmed = everyMs.trim()
  if (!trimmed) return { value: '', unit: 'minutes' }
  const ms = Number(trimmed)
  if (!Number.isFinite(ms) || ms <= 0) return { value: trimmed, unit: 'seconds' }
  if (ms % INTERVAL_UNIT_MS.days === 0) return { value: String(ms / INTERVAL_UNIT_MS.days), unit: 'days' }
  if (ms % INTERVAL_UNIT_MS.hours === 0) return { value: String(ms / INTERVAL_UNIT_MS.hours), unit: 'hours' }
  if (ms % INTERVAL_UNIT_MS.minutes === 0) return { value: String(ms / INTERVAL_UNIT_MS.minutes), unit: 'minutes' }
  if (ms % INTERVAL_UNIT_MS.seconds === 0) return { value: String(ms / INTERVAL_UNIT_MS.seconds), unit: 'seconds' }
  return { value: String(ms / INTERVAL_UNIT_MS.seconds), unit: 'seconds' }
}

export function composeEveryMs(value: string, unit: ScheduleIntervalUnit): string {
  const trimmed = value.trim()
  if (!trimmed) return ''
  const num = Number(trimmed)
  if (!Number.isFinite(num) || num <= 0) return trimmed
  return String(Math.round(num * INTERVAL_UNIT_MS[unit]))
}

export type ScheduleFieldErrors = {
  ownerSessionId?: string
  name?: string
  task?: string
  cronExpression?: string
  interval?: string
  anchorAt?: string
  deliveryConversationIds?: Record<number, string>
}

/**
 * The `/api/v2` cron schedule types give `schedule`, `delivery`, and `payload`
 * as JSON objects. These types state their shape for the Console.
 */
export type ScheduleRecurrence = {
  kind: 'cron' | 'every'
  /** Crontab expression with five fields, or six fields with leading seconds. */
  expression?: string
  /** IANA timezone. A stored `cron` recurrence carries it. */
  timezone?: string
  every_ms?: number
  /** ISO 8601 instant that the interval counts from. */
  anchor_at?: string
  /** Exactly one of `count` (due slots to run) or `until` (inclusive cutoff instant). */
  occurrences?: { count?: number; until?: string }
}

/** A native conversation ID, or an external reply route of a binding. */
export type ScheduleDeliveryTarget =
  | { conversation_id: string }
  | { binding_name: string; conversation_id: string; provider_thread_id?: string }

/** Where the result of a fire goes; `quiet_success` sends no message for a fire with nothing to report. */
export type ScheduleDelivery = { targets: ScheduleDeliveryTarget[]; quiet_success?: boolean }

type CronScheduleWriteBody = {
  owner_session_id: string
  binding_name?: string
  name: string
  status?: CronStatus
  schedule: ScheduleRecurrence
  timezone?: string | null
  payload?: Record<string, unknown>
  delivery: ScheduleDelivery
  idempotency_key: string
}

type CronScheduleUpdateBody = Partial<
  Pick<CronScheduleWriteBody, 'name' | 'schedule' | 'timezone' | 'payload' | 'delivery'>
>

/**
 * Editor model for one cron schedule.
 *
 * The wire shape splits across the nested `schedule`, `delivery`, and `payload`
 * objects, so the model flattens them into individually editable signals and
 * reassembles them on save. `task` edits `payload.task` — the self-contained
 * standing instruction a direct-Agent schedule must carry — while the rest of
 * the stored payload passes through untouched.
 */

export type CronStatus = 'active' | 'paused'

export type ScheduleKind = ScheduleRecurrence['kind']

export type ScheduleOccurrenceBound = { count: number } | { until: string }

export type DeliveryTargetDraft = {
  bindingName: string
  conversationId: string
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

/** Maps stored delivery targets to editable drafts. */
export function deliveryTargetDrafts(delivery: ScheduleDelivery | null | undefined): DeliveryTargetDraft[] {
  return (delivery?.targets ?? []).map(target => ({
    bindingName: 'binding_name' in target ? target.binding_name : '',
    conversationId: target.conversation_id,
    threadId: 'provider_thread_id' in target ? (target.provider_thread_id ?? '') : ''
  }))
}

/** Reads the normalized occurrence bound that the editor must preserve. */
export function scheduleOccurrenceBound(
  schedule: Pick<ScheduleRecurrence, 'occurrences'>
): ScheduleOccurrenceBound | undefined {
  const bound = schedule.occurrences
  if (!bound) return undefined
  if (bound.count != null && bound.count > 0) return { count: bound.count }
  return bound.until ? { until: bound.until } : undefined
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
  const intervalValue = signal('')
  const intervalUnit = signal<ScheduleIntervalUnit>('minutes')
  const anchorAt = signal('')
  const anchorInput = signal('')
  const timezone = signal('')
  const deliveryTargets = signal<DeliveryTargetDraft[]>([])
  const task = signal('')
  const payload = signal('{}')
  const hasAutomationJob = signal(false)
  const idempotencyKey = signal('')
  const initialDraft = signal<ScheduleEditorDraft>()
  const validationError = signal<string>()
  const fieldErrors = signal<ScheduleFieldErrors>({})

  const apply = (draft: ScheduleEditorDraft) => {
    const decomposed = decomposeEveryMs(draft.everyMs)
    batch(() => {
      ownerSessionId.value = draft.ownerSessionId
      bindingName.value = draft.bindingName
      name.value = draft.name
      status.value = draft.status
      scheduleKind.value = draft.scheduleKind
      cronExpression.value = draft.cronExpression
      everyMs.value = draft.everyMs
      intervalValue.value = decomposed.value
      intervalUnit.value = decomposed.unit
      anchorAt.value = draft.anchorAt
      anchorInput.value = draft.anchorAt ? dateTimeLocalValue(draft.anchorAt) : ''
      timezone.value = draft.timezone
      deliveryTargets.value =
        draft.deliveryTargets.length > 0 ? draft.deliveryTargets.map(target => ({ ...target })) : [emptyTarget()]
      task.value = draft.task
      payload.value = draft.payload
      hasAutomationJob.value = draft.hasAutomationJob
      idempotencyKey.value = draft.idempotencyKey
      validationError.value = undefined
      fieldErrors.value = {}
    })
  }

  const buildSchedule = (): ScheduleRecurrence | null => {
    const occurrences = initialDraft.value?.occurrences
    const kind: ScheduleKind = scheduleKind.value || 'cron'
    if (kind === 'cron') {
      const expression = cronExpression.value.trim()
      if (!expression) return null
      const out: ScheduleRecurrence = { kind: 'cron', expression }
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

  const buildDelivery = (): ScheduleDelivery | null => {
    const targets: ScheduleDeliveryTarget[] = deliveryTargets.value.map(target => ({
      conversation_id: target.conversationId.trim(),
      ...(target.bindingName.trim() ? { binding_name: target.bindingName.trim() } : {}),
      ...(target.threadId.trim() ? { provider_thread_id: target.threadId.trim() } : {})
    }))

    if (
      targets.length === 0 ||
      targets.some(target => !target.conversation_id) ||
      deliveryTargets.value[0]?.bindingName.trim() !== bindingName.value.trim()
    ) {
      return null
    }

    const keys = deliveryTargets.value.map(target =>
      [target.conversationId.trim(), target.bindingName.trim(), target.threadId.trim()].join('\u0000')
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

  /** Whether any field differs from the initialized draft; false until a draft is loaded. */
  const dirty = computed(() => {
    const original = initialDraft.value
    if (!original) return false
    return (
      original.ownerSessionId !== ownerSessionId.value ||
      original.bindingName !== bindingName.value ||
      original.name !== name.value ||
      original.status !== status.value ||
      original.task !== task.value ||
      original.payload !== payload.value ||
      original.idempotencyKey !== idempotencyKey.value ||
      scheduleFieldsChanged(original) ||
      !sameJSON(meaningfulTargets(original.deliveryTargets), meaningfulTargets(deliveryTargets.value))
    )
  })

  return {
    sourceKey,
    ownerSessionId,
    bindingName,
    name,
    status,
    scheduleKind,
    cronExpression,
    everyMs,
    intervalValue,
    intervalUnit,
    anchorAt,
    anchorInput,
    timezone,
    deliveryTargets,
    task,
    payload,
    hasAutomationJob,
    idempotencyKey,
    validationError,
    fieldErrors,
    dirty,
    initialize(nextSourceKey: string, draft: ScheduleEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      apply(draft)
      initialDraft.value = { ...draft }
    },
    clearValidation() {
      validationError.value = undefined
      fieldErrors.value = {}
    },
    setIntervalValue(nextValue: string) {
      batch(() => {
        intervalValue.value = nextValue
        everyMs.value = composeEveryMs(nextValue, intervalUnit.value)
      })
    },
    setIntervalUnit(nextUnit: ScheduleIntervalUnit) {
      batch(() => {
        intervalUnit.value = nextUnit
        everyMs.value = composeEveryMs(intervalValue.value, nextUnit)
      })
    },
    setAnchorLocal(localValue: string) {
      batch(() => {
        anchorInput.value = localValue
        anchorAt.value = localValue.trim() ? (instantFromDateTimeLocal(localValue) ?? '') : ''
      })
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
        name.value.trim() && taskSatisfied() && buildSchedule() && buildDelivery() && buildPayload() !== null
      )
    },
    toCreateBody(idempotencyKeyOverride?: string): CronScheduleWriteBody | null {
      const schedule = buildSchedule()
      const delivery = buildDelivery()
      const nextPayload = buildPayload()
      const ownerSession = ownerSessionId.value.trim()
      const binding = bindingName.value.trim()
      const trimmedName = name.value.trim()
      const idempotency = (idempotencyKeyOverride ?? idempotencyKey.value).trim()
      if (
        !ownerSession ||
        !trimmedName ||
        !schedule ||
        !delivery ||
        !idempotency ||
        nextPayload === null ||
        !taskSatisfied()
      ) {
        return null
      }
      const body: CronScheduleWriteBody = {
        owner_session_id: ownerSession,
        ...(binding ? { binding_name: binding } : {}),
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
    toUpdateBody(): CronScheduleUpdateBody | null {
      const schedule = buildSchedule()
      const delivery = buildDelivery()
      const original = initialDraft.value
      const nextPayload = buildPayload()
      if (!schedule || !delivery || !original || nextPayload === null || !taskSatisfied()) return null
      const body: CronScheduleUpdateBody = {}
      const trimmedName = name.value.trim()
      if (!trimmedName) return null
      if (trimmedName !== original.name.trim()) body.name = trimmedName
      if (scheduleFieldsChanged(original)) body.schedule = schedule
      const tz = effectiveTimezone()
      if ((schedule.kind === 'cron' || original.scheduleKind === 'cron') && tz !== original.timezone.trim()) {
        body.timezone = tz || null
      }
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
  return { bindingName: '', conversationId: '', threadId: '' }
}

/** Targets the operator filled in; the editor's blank placeholder row counts as none. */
function meaningfulTargets(targets: DeliveryTargetDraft[]): DeliveryTargetDraft[] {
  return normalizeDraftTargets(targets).filter(target => target.bindingName || target.conversationId || target.threadId)
}

function normalizeDraftTargets(targets: DeliveryTargetDraft[]): DeliveryTargetDraft[] {
  return targets.map(target => ({
    bindingName: target.bindingName.trim(),
    conversationId: target.conversationId.trim(),
    threadId: target.threadId.trim()
  }))
}
