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

  test('tracks value changes as the drawer draft', () => {
    const model = new SettingEditorModel()

    model.initialize('setting:timezone', '"UTC"')
    expect(model.dirty.value).toBe(false)

    model.text.value = '"Asia/Singapore"'
    expect(model.dirty.value).toBe(true)
    model.text.value = '"UTC"'
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('revealing an encrypted value does not create an unsaved change', () => {
    const model = new SettingEditorModel()

    model.initialize('setting:secret', '••••••••')
    model.reveal('"secret"')

    expect(model.text.value).toBe('"secret"')
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })
})
