import { describe, expect, test } from 'bun:test'
import { settingStringDraft, settingValueKind } from './setting-value-editor'

describe('setting value editor', () => {
  test('uses scalar controls for scalar JSON values', () => {
    expect(settingValueKind(true)).toBe('boolean')
    expect(settingValueKind(9)).toBe('number')
    expect(settingValueKind('UTC')).toBe('string')
  })

  test('reserves the JSON editor for arrays, objects, and null', () => {
    expect(settingValueKind({ mode: 'strict' })).toBe('structured')
    expect(settingValueKind(['one'])).toBe('structured')
    expect(settingValueKind(null)).toBe('structured')
  })

  test('unwraps a JSON string for the text input', () => {
    expect(settingStringDraft('"Asia/Shanghai"')).toBe('Asia/Shanghai')
  })
})
