import { describe, expect, test } from 'bun:test'
import i18n from '../../common/i18n'
import { providerSettingPresentation, selectControlValue, UNSET_SELECT } from './provider-setting-field'

describe('provider setting presentation', () => {
  test('keeps undeclared ProviderDSL keys readable without inventing product copy', () => {
    const t = i18n.getFixedT('en-US')

    expect(providerSettingPresentation(t, 'strictJSONSchema')).toEqual({ label: 'Strict JSON schema' })
  })

  test('names the upstream transport control by the feature it switches', () => {
    const t = i18n.getFixedT('en-US')

    expect(providerSettingPresentation(t, 'upstream_transport')).toEqual({ label: 'WebSocket' })
  })
})

describe('select control value', () => {
  test('an explicit draft always wins', () => {
    expect(selectControlValue('oauth', 'api_key', true)).toBe('oauth')
    expect(selectControlValue('oauth', 'api_key', false)).toBe('oauth')
  })

  test('a blank draft that keeps the stored value presents the sentinel, never the DSL default', () => {
    expect(selectControlValue('', 'api_key', true)).toBe(UNSET_SELECT)
  })

  test('a blank draft for a new record preselects the DSL default', () => {
    expect(selectControlValue('', 'api_key', false)).toBe('api_key')
    expect(selectControlValue('', '', false)).toBe(UNSET_SELECT)
  })
})
