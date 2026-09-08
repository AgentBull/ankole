import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { TokenQuota, TokenQuotaWriteRequest } from '../api/generated/types.gen'

export type TokenQuotaDraft = {
  periodDays: string
  periodStartAt: string
  limitTokens: string
}

export type TokenQuotaDraftError =
  | 'period_days_required'
  | 'period_days_invalid'
  | 'period_start_at_required'
  | 'period_start_at_invalid'
  | 'limit_tokens_required'
  | 'limit_tokens_invalid'

export type TokenQuotaSubmission =
  | { ok: true; body: TokenQuotaWriteRequest }
  | { ok: false; error: TokenQuotaDraftError }

// The field is a `datetime-local` control, so the draft holds the instant as
// the browser's local wall-clock time without an offset. The control plane
// stores a UTC instant; the two conversions below invert each other at second
// precision.
const dateTimeLocalPattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?$/

/** Formats a stored UTC instant as the local `datetime-local` value. */
export function dateTimeLocalValue(instant: string): string {
  const date = new Date(instant)
  if (Number.isNaN(date.getTime())) return ''
  const pad = (value: number) => String(value).padStart(2, '0')
  const day = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
  return `${day}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
}

/** Parses a local `datetime-local` value into a UTC ISO 8601 instant. */
export function instantFromDateTimeLocal(value: string): string | undefined {
  const text = value.trim()
  if (!dateTimeLocalPattern.test(text)) return undefined
  const date = new Date(text)
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString()
}

export function emptyTokenQuotaDraft(): TokenQuotaDraft {
  return { periodDays: '', periodStartAt: '', limitTokens: '' }
}

/** An Agent without a stored quota starts from an empty draft. */
export function draftFromTokenQuota(quota: TokenQuota | null | undefined): TokenQuotaDraft {
  if (!quota) return emptyTokenQuotaDraft()
  return {
    periodDays: String(quota.period_days),
    periodStartAt: dateTimeLocalValue(quota.period_start_at),
    limitTokens: String(quota.limit_tokens)
  }
}

export const TokenQuotaEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const periodDays = signal('')
  const periodStartAt = signal('')
  const limitTokens = signal('')
  const initialDraft = signal<TokenQuotaDraft>()
  const validationError = signal<TokenQuotaDraftError>()
  const dirty = computed(() => {
    const initial = initialDraft.value
    return Boolean(
      initial &&
      (periodDays.value !== initial.periodDays ||
        periodStartAt.value !== initial.periodStartAt ||
        limitTokens.value !== initial.limitTokens)
    )
  })

  return {
    sourceKey,
    periodDays,
    periodStartAt,
    limitTokens,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: TokenQuotaDraft) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        periodDays.value = draft.periodDays
        periodStartAt.value = draft.periodStartAt
        limitTokens.value = draft.limitTokens
        initialDraft.value = { ...draft }
        validationError.value = undefined
      })
    },
    clearValidation() {
      validationError.value = undefined
    },
    markSaved(draft: TokenQuotaDraft) {
      batch(() => {
        periodDays.value = draft.periodDays
        periodStartAt.value = draft.periodStartAt
        limitTokens.value = draft.limitTokens
        initialDraft.value = { ...draft }
        validationError.value = undefined
      })
    },
    submission(): TokenQuotaSubmission {
      if (!periodDays.value.trim()) return { ok: false, error: 'period_days_required' }
      const days = positiveInteger(periodDays.value)
      if (days === undefined) return { ok: false, error: 'period_days_invalid' }

      const startAt = periodStartAt.value.trim()
      if (!startAt) return { ok: false, error: 'period_start_at_required' }
      const periodStartInstant = instantFromDateTimeLocal(startAt)
      if (periodStartInstant === undefined) return { ok: false, error: 'period_start_at_invalid' }

      if (!limitTokens.value.trim()) return { ok: false, error: 'limit_tokens_required' }
      const limit = positiveInteger(limitTokens.value)
      if (limit === undefined) return { ok: false, error: 'limit_tokens_invalid' }

      return { ok: true, body: { period_days: days, period_start_at: periodStartInstant, limit_tokens: limit } }
    }
  }
})

function positiveInteger(value: string): number | undefined {
  const text = value.trim()
  if (!/^[0-9]+$/.test(text)) return undefined
  const parsed = Number(text)
  return Number.isSafeInteger(parsed) && parsed >= 1 ? parsed : undefined
}
