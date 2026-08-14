import { describe, expect, test } from 'bun:test'
import { encryptedSettingValue, SettingEditorModel, settingDecryptedDraft } from './setting-editor-model'

describe('SettingEditorModel', () => {
  test('reveals a string secret without adding JSON quotes', () => {
    expect(settingDecryptedDraft('secret-token')).toBe('secret-token')
    expect(settingDecryptedDraft({ client_id: 'client' })).toBe('{"client_id":"client"}')
  })

  test('keeps opaque secrets intact and parses only structured JSON', () => {
    expect(encryptedSettingValue('1234')).toBe('1234')
    expect(encryptedSettingValue('{vault-token')).toBe('{vault-token')
    expect(encryptedSettingValue('"token"')).toBe('"token"')
    expect(encryptedSettingValue('{"client_id":"client"}')).toEqual({ client_id: 'client' })
    expect(encryptedSettingValue('["first","second"]')).toEqual(['first', 'second'])
  })

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
    model.reveal(settingDecryptedDraft('secret'))

    expect(model.text.value).toBe('secret')
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })
})
