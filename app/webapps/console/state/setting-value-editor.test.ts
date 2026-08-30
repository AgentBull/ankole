import { describe, expect, test } from 'bun:test'
import {
  pluginIDsFromDraft,
  pluginRestartRequired,
  settingEditorKind,
  settingStringDraft,
  settingValueKind,
  togglePluginID,
  unknownPluginIDs
} from './setting-value-editor'

describe('setting value editor', () => {
  test('uses the object editor only for JSON objects', () => {
    expect(settingValueKind({ mode: 'strict' })).toBe('object')
    expect(settingValueKind(['one'])).toBe('structured')
    expect(settingValueKind(null)).toBe('structured')
  })

  test('unwraps a JSON string for the text input', () => {
    expect(settingStringDraft('"Asia/Shanghai"')).toBe('Asia/Shanghai')
  })

  test('matches exact key editors before generic fallbacks', () => {
    expect(settingEditorKind('plugins.enabled_ids', false, [])).toBe('plugins')
    expect(settingEditorKind('system.timezone', false, 'Asia/Shanghai')).toBe('timezone')
    expect(settingEditorKind('i18n.default_locale', false, 'en-US')).toBe('locale')
    expect(settingEditorKind('runtime.secret', true, undefined)).toBe('encrypted')
    expect(settingEditorKind('feature.enabled', false, true)).toBe('boolean')
    expect(settingEditorKind('feature.config', false, {})).toBe('object')
  })

  test('normalizes plugin drafts and preserves undiscovered ids', () => {
    const selected = pluginIDsFromDraft('["slack", "future", "slack"]')
    expect(selected).toEqual(['future', 'slack'])
    expect(togglePluginID(selected, 'lark', true)).toEqual(['future', 'lark', 'slack'])
    expect(togglePluginID(selected, 'slack', false)).toEqual(['future'])
    expect(unknownPluginIDs(selected, ['slack', 'lark'])).toEqual(['future'])
  })

  test('derives restart state from runtime and next-start selection', () => {
    expect(pluginRestartRequired(true, true)).toBe(false)
    expect(pluginRestartRequired(false, false)).toBe(false)
    expect(pluginRestartRequired(true, false)).toBe(true)
    expect(pluginRestartRequired(false, true)).toBe(true)
  })
})
