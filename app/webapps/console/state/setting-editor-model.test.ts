import { describe, expect, test } from 'bun:test'
import { SettingEditorModel } from './setting-editor-model'

describe('SettingEditorModel', () => {
  test('only reloads the same setting after an explicit reset', () => {
    const model = new SettingEditorModel()

    model.initialize('setting:timezone', '"UTC"')
    model.text.value = '"Asia/Singapore"'
    model.initialize('setting:timezone', '"Europe/London"')
    expect(model.text.value).toBe('"Asia/Singapore"')

    model.resetSource()
    model.initialize('setting:timezone', '"Europe/London"')
    expect(model.text.value).toBe('"Europe/London"')
    model[Symbol.dispose]()
  })
})
