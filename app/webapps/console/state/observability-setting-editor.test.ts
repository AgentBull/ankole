import { describe, expect, test } from 'bun:test'
import {
  OBSERVABILITY_TRACE_KEYS,
  observabilityHeaderRows,
  observabilityHeadersValidationError,
  observabilityHeadersValue,
  observabilityTraceDraft,
  observabilityTraceValidationError,
  sameObservabilityHeaderRows
} from './observability-setting-editor'

describe('observability setting editor', () => {
  test('reads the four AppConfigure drafts without inventing defaults', () => {
    expect(
      observabilityTraceDraft({
        [OBSERVABILITY_TRACE_KEYS.enabled]: 'true',
        [OBSERVABILITY_TRACE_KEYS.provider]: '"langfuse"',
        [OBSERVABILITY_TRACE_KEYS.endpoint]: '"https://cloud.langfuse.com/api/public/otel"'
      })
    ).toEqual({
      enabled: true,
      provider: 'langfuse',
      endpoint: 'https://cloud.langfuse.com/api/public/otel'
    })
  })

  test('requires a provider and a base OTLP HTTP endpoint only when export is enabled', () => {
    expect(observabilityTraceValidationError({ enabled: false, provider: '', endpoint: '' })).toBeUndefined()
    expect(observabilityTraceValidationError({ enabled: true, provider: '', endpoint: '' })).toBe('provider_required')
    expect(observabilityTraceValidationError({ enabled: true, provider: 'langfuse', endpoint: '' })).toBe(
      'endpoint_required'
    )
    expect(
      observabilityTraceValidationError({
        enabled: true,
        provider: 'langfuse',
        endpoint: 'https://cloud.langfuse.com/api/public/otel/v1/traces'
      })
    ).toBe('endpoint_signal_path')
    expect(
      observabilityTraceValidationError({
        enabled: true,
        provider: 'langfuse',
        endpoint: 'https://cloud.langfuse.com/api/public/otel'
      })
    ).toBeUndefined()
  })

  test('round-trips encrypted headers through visual rows', () => {
    const rows = observabilityHeaderRows({ Authorization: 'Basic value', 'x-api-key': 'secret' })
    expect(rows).toEqual([
      { id: 'stored-0', name: 'Authorization', value: 'Basic value' },
      { id: 'stored-1', name: 'x-api-key', value: 'secret' }
    ])
    expect(observabilityHeadersValue(rows ?? [])).toEqual({
      Authorization: 'Basic value',
      'x-api-key': 'secret'
    })
  })

  test('rejects blank or case-insensitively duplicated header names', () => {
    expect(observabilityHeadersValidationError([{ id: '1', name: '', value: '' }])).toBe('header_name_required')
    expect(
      observabilityHeadersValidationError([
        { id: '1', name: 'Authorization', value: 'first' },
        { id: '2', name: 'authorization', value: 'second' }
      ])
    ).toBe('header_duplicate')
  })

  test('keeps an unrevealed secret distinct from an explicitly empty header map', () => {
    expect(sameObservabilityHeaderRows(undefined, undefined)).toBe(true)
    expect(sameObservabilityHeaderRows(undefined, [])).toBe(false)
    expect(sameObservabilityHeaderRows([], [])).toBe(true)
  })
})
