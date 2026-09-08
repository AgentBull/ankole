import { describe, expect, test } from 'bun:test'
import {
  TokenQuotaEditorModel,
  dateTimeLocalValue,
  draftFromTokenQuota,
  emptyTokenQuotaDraft,
  instantFromDateTimeLocal
} from './token-quota-editor-model'

const storedQuota = { period_days: 7, period_start_at: '2026-09-09T00:00:00Z', limit_tokens: 1_000_000 }
const storedInstant = Date.parse(storedQuota.period_start_at)

describe('datetime-local conversion', () => {
  test('a stored instant round-trips through the local value in any time zone', () => {
    const local = dateTimeLocalValue(storedQuota.period_start_at)
    expect(local).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/)
    expect(Date.parse(instantFromDateTimeLocal(local)!)).toBe(storedInstant)
  })

  test('an incomplete or impossible value has no instant', () => {
    expect(instantFromDateTimeLocal('2026-09-09')).toBeUndefined()
    expect(instantFromDateTimeLocal('2026-13-09T00:00')).toBeUndefined()
    expect(instantFromDateTimeLocal('2026-09-09T00:00:00Z')).toBeUndefined()
    expect(dateTimeLocalValue('not a date')).toBe('')
  })
})

describe('draftFromTokenQuota', () => {
  test('reads the stored quota and falls back to an empty draft', () => {
    expect(draftFromTokenQuota(storedQuota)).toEqual({
      periodDays: '7',
      periodStartAt: dateTimeLocalValue(storedQuota.period_start_at),
      limitTokens: '1000000'
    })
    expect(draftFromTokenQuota(null)).toEqual(emptyTokenQuotaDraft())
    expect(draftFromTokenQuota(undefined)).toEqual(emptyTokenQuotaDraft())
  })
})

describe('TokenQuotaEditorModel', () => {
  test('keeps edits during refetch and resets when another Agent is selected', () => {
    const model = new TokenQuotaEditorModel()

    model.initialize('agent:alpha', draftFromTokenQuota(storedQuota))
    expect(model.dirty.value).toBe(false)
    model.limitTokens.value = '2000000'
    expect(model.dirty.value).toBe(true)

    model.initialize('agent:alpha', draftFromTokenQuota(storedQuota))
    expect(model.limitTokens.value).toBe('2000000')

    model.initialize('agent:beta', emptyTokenQuotaDraft())
    expect(model.periodDays.value).toBe('')
    expect(model.limitTokens.value).toBe('')
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('reports the first invalid field in field order', () => {
    const model = new TokenQuotaEditorModel()
    model.initialize('agent:alpha', emptyTokenQuotaDraft())

    expect(model.submission()).toEqual({ ok: false, error: 'period_days_required' })
    model.periodDays.value = '0'
    expect(model.submission()).toEqual({ ok: false, error: 'period_days_invalid' })
    model.periodDays.value = '1.5'
    expect(model.submission()).toEqual({ ok: false, error: 'period_days_invalid' })

    model.periodDays.value = '7'
    expect(model.submission()).toEqual({ ok: false, error: 'period_start_at_required' })
    model.periodStartAt.value = '2026-09-09'
    expect(model.submission()).toEqual({ ok: false, error: 'period_start_at_invalid' })
    model.periodStartAt.value = '2026-13-09T00:00'
    expect(model.submission()).toEqual({ ok: false, error: 'period_start_at_invalid' })

    model.periodStartAt.value = '2026-09-09T00:00'
    expect(model.submission()).toEqual({ ok: false, error: 'limit_tokens_required' })
    model.limitTokens.value = '-5'
    expect(model.submission()).toEqual({ ok: false, error: 'limit_tokens_invalid' })
    model[Symbol.dispose]()
  })

  test('builds the write request with the picked local time as a UTC instant', () => {
    const model = new TokenQuotaEditorModel()
    model.initialize('agent:alpha', emptyTokenQuotaDraft())

    model.periodDays.value = '7'
    model.periodStartAt.value = ` ${dateTimeLocalValue(storedQuota.period_start_at)} `
    model.limitTokens.value = '1000000'

    const submission = model.submission()
    expect(submission.ok).toBe(true)
    if (!submission.ok) return
    expect(submission.body.period_days).toBe(7)
    expect(submission.body.limit_tokens).toBe(1_000_000)
    expect(submission.body.period_start_at).toMatch(/Z$/)
    expect(Date.parse(submission.body.period_start_at)).toBe(storedInstant)
    model[Symbol.dispose]()
  })

  test('markSaved adopts the persisted quota as the clean draft', () => {
    const model = new TokenQuotaEditorModel()
    model.initialize('agent:alpha', emptyTokenQuotaDraft())

    model.periodDays.value = '7'
    model.validationError.value = 'limit_tokens_required'
    expect(model.dirty.value).toBe(true)

    model.markSaved(draftFromTokenQuota(storedQuota))
    expect(model.dirty.value).toBe(false)
    expect(model.periodStartAt.value).toBe(dateTimeLocalValue(storedQuota.period_start_at))
    expect(model.validationError.value).toBeUndefined()
    model[Symbol.dispose]()
  })
})
