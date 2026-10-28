import { beforeAll, describe, expect, test } from 'bun:test'
import i18n, { loadLocale } from '../../common/i18n'
import type { AppConfigurationItem, AppConfigurationUpdateRequest } from '../api/configuration-types'
import { ENCRYPTED_VALUE_MASK } from '../encrypted-value-input'
import { seedEditorDraft } from '../use-editor-draft'
import {
  encryptedSettingValue,
  SettingEditorModel,
  settingDecryptedDraft,
  syncConsoleLocaleIfPrivileged
} from './setting-editor-model'

beforeAll(() => loadLocale('en-US'))
const t = i18n.getFixedT('en-US')

describe('SettingEditorModel', () => {
  test('reveals string secrets and keeps opaque secrets intact', () => {
    expect(settingDecryptedDraft('secret-token')).toBe('secret-token')
    expect(settingDecryptedDraft({ client_id: 'client' })).toBe('{"client_id":"client"}')
    expect(encryptedSettingValue('1234')).toBe('1234')
    expect(encryptedSettingValue('{vault-token')).toBe('{vault-token')
    expect(encryptedSettingValue('"token"')).toBe('"token"')
    expect(encryptedSettingValue('{"client_id":"client"}')).toEqual({ client_id: 'client' })
    expect(encryptedSettingValue('["first","second"]')).toEqual(['first', 'second'])
  })

  test('only reloads the same setting after an explicit reset', () => {
    using model = new SettingEditorModel()
    model.initialize('setting:timezone', '"UTC"')
    model.text.value = '"Asia/Singapore"'
    model.initialize('setting:timezone', '"Europe/London"')
    expect(model.text.value).toBe('"Asia/Singapore"')
    expect(model.dirty.value).toBe(true)
    model.resetSource()
    model.initialize('setting:timezone', '"Europe/London"')
    expect(model.text.value).toBe('"Europe/London"')
    expect(model.dirty.value).toBe(false)
  })

  test('revealing an encrypted value does not create an unsaved change', async () => {
    using model = new SettingEditorModel()
    model.initialize('setting:secret', ENCRYPTED_VALUE_MASK)
    await model.reveal(async () => 'secret')
    expect(model.text.value).toBe('secret')
    expect(model.revealed.value).toBe(true)
    expect(model.dirty.value).toBe(false)
  })

  test('ignores a reveal after selecting another setting and returning to the same setting', async () => {
    using model = new SettingEditorModel()
    model.initialize('setting:tenant:A', ENCRYPTED_VALUE_MASK)
    const response = Promise.withResolvers<string>()
    const pending = model.reveal(() => response.promise)
    model.initialize('setting:tenant:B', ENCRYPTED_VALUE_MASK)
    model.initialize('setting:tenant:A', ENCRYPTED_VALUE_MASK)
    response.resolve('earlier A secret')
    await pending
    expect(model.text.value).toBe(ENCRYPTED_VALUE_MASK)
    expect(model.revealed.value).toBe(false)
    expect(model.dirty.value).toBe(false)
  })

  test('keeps edits made while the same setting is being decrypted', async () => {
    using model = new SettingEditorModel()
    model.initialize('setting:tenant:secret', ENCRYPTED_VALUE_MASK)
    const response = Promise.withResolvers<string>()
    const pending = model.reveal(() => response.promise)
    model.text.value = 'replacement secret'
    response.resolve('stored secret')
    await pending
    expect(model.text.value).toBe('replacement secret')
    expect(model.dirty.value).toBe(true)
    expect(model.revealed.value).toBe(false)
  })

  test('returning from an unloaded setting still revokes the earlier reveal', async () => {
    using model = new SettingEditorModel()
    const a = 'setting:tenant:A'
    const b = 'setting:tenant:B'
    seedEditorDraft(model, a, ENCRYPTED_VALUE_MASK, false)
    const response = Promise.withResolvers<string>()
    const pending = model.reveal(() => response.promise)
    seedEditorDraft(model, b, undefined, false)
    seedEditorDraft(model, a, ENCRYPTED_VALUE_MASK, false)
    response.resolve('earlier A secret')
    await pending
    expect(model.text.value).toBe(ENCRYPTED_VALUE_MASK)
    expect(model.dirty.value).toBe(false)
  })

  for (const departure of ['loading selection', 'unmount']) {
    for (const operation of ['save', 'restore']) {
      test(`a late ${operation} cannot navigate after ${departure}`, async () => {
        using model = new SettingEditorModel()
        const a = 'setting:tenant:A'
        const b = 'setting:global:B'
        seedEditorDraft(model, a, '"A value"', false)
        const response = Promise.withResolvers<AppConfigurationItem>()
        const navigations: string[] = []
        const onComplete = () => navigations.push('/settings')
        const pending =
          operation === 'save'
            ? model.save(false, t, () => response.promise, onComplete)
            : model.restore(() => response.promise, onComplete)
        if (departure === 'unmount') {
          model.resetSource()
          model[Symbol.dispose]()
        } else {
          seedEditorDraft(model, b, undefined, false)
        }
        response.resolve(item('restored A value'))
        await pending
        expect(model.sourceKey.value).toBeUndefined()
        expect(navigations).toEqual([])
      })
    }
  }

  test('preserves the encrypted mask body and rejects a blank replacement before a request', async () => {
    using model = new SettingEditorModel()
    const bodies: AppConfigurationUpdateRequest[] = []
    const request = async (body: AppConfigurationUpdateRequest) => {
      bodies.push(body)
    }
    model.initialize('setting:tenant:secret', ENCRYPTED_VALUE_MASK)
    await model.save(true, t, request, () => {})
    expect(bodies).toEqual([{}])
    model.text.value = '  '
    await model.save(true, t, request, () => {})
    expect(bodies).toHaveLength(1)
    expect(model.validationError.value).toBeTruthy()
    model.text.value = '{vault-token'
    await model.save(true, t, request, () => {})
    model.text.value = '{"Authorization":"secret"}'
    await model.save(true, t, request, () => {})
    expect(bodies).toEqual([{}, { value: '{vault-token' }, { value: { Authorization: 'secret' } }])
    expect(model.validationError.value).toBeUndefined()
  })

  test('parses ordinary values before a request and retains edits made during a save', async () => {
    using model = new SettingEditorModel()
    model.initialize('setting:tenant:number', '10')
    const bodies: AppConfigurationUpdateRequest[] = []
    const response = Promise.withResolvers<void>()
    const request = (body: AppConfigurationUpdateRequest) => {
      bodies.push(body)
      return response.promise
    }
    const completions: boolean[] = []
    model.text.value = 'invalid json'
    await model.save(false, t, request, clean => completions.push(clean))
    expect(bodies).toEqual([])
    expect(model.validationError.value).toBeTruthy()
    model.text.value = '20'
    const pending = model.save(false, t, request, clean => completions.push(clean))
    model.text.value = '30'
    response.resolve()
    await pending
    expect(bodies).toEqual([{ value: 20 }])
    expect(completions).toEqual([false])
    expect(model.text.value).toBe('30')
    expect(model.dirty.value).toBe(true)
    model.text.value = '20'
    expect(model.dirty.value).toBe(false)
  })

  test('restoring a setting preserves edits made after the request began', async () => {
    using model = new SettingEditorModel()
    model.initialize('setting:tenant:A', '"previous"')
    const response = Promise.withResolvers<AppConfigurationItem>()
    const completions: boolean[] = []
    const pending = model.restore(
      () => response.promise,
      clean => completions.push(clean)
    )
    model.text.value = '"new draft"'
    response.resolve(item('restored value'))
    await pending
    expect(model.text.value).toBe('"new draft"')
    expect(model.dirty.value).toBe(true)
    expect(completions).toEqual([false])
    model.text.value = '"restored value"'
    expect(model.dirty.value).toBe(false)
  })

  test('a restore revokes pending decryption of the previous stored secret', async () => {
    using model = new SettingEditorModel()
    model.initialize('setting:tenant:A', ENCRYPTED_VALUE_MASK)
    const response = Promise.withResolvers<string>()
    const pending = model.reveal(() => response.promise)
    const completions: boolean[] = []
    await model.restore(
      async () => item(undefined, true),
      clean => completions.push(clean)
    )
    response.resolve('removed secret')
    await pending
    expect(model.text.value).toBe(ENCRYPTED_VALUE_MASK)
    expect(model.revealed.value).toBe(false)
    expect(model.dirty.value).toBe(false)
    expect(completions).toEqual([true])
  })

  for (const operation of ['reveal', 'save', 'restore']) {
    test(`a failed ${operation} rejects without reporting success or replacing the draft`, async () => {
      using model = new SettingEditorModel()
      model.initialize('setting:tenant:A', '"previous"')
      model.text.value = '"draft"'
      const failure = new Error('request failed')
      const request = async (): Promise<never> => {
        throw failure
      }
      const completions: boolean[] = []
      const pending =
        operation === 'save'
          ? model.save(false, t, request, clean => completions.push(clean))
          : operation === 'restore'
            ? model.restore(request, clean => completions.push(clean))
            : model.reveal(request)
      await expect(pending).rejects.toBe(failure)
      expect(completions).toEqual([])
      expect(model.text.value).toBe('"draft"')
      expect(model.dirty.value).toBe(true)
    })
  }

  test('switches the Console UI locale only when saving i18n.default_locale for the privileged tenant', async () => {
    const previousDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
    const documentElement = { lang: 'en-US' }
    Object.defineProperty(globalThis, 'document', {
      configurable: true,
      value: { documentElement }
    })

    try {
      await loadLocale('en-US')
      await i18n.changeLanguage('en-US')

      // Editing a non-privileged data tenant does not switch the Console UI language.
      await syncConsoleLocaleIfPrivileged({
        scope: 'tenant',
        key: 'i18n.default_locale',
        value: 'ja-JP',
        selectedTenantID: 'tenant-customer',
        privilegedTenantID: 'tenant-privileged'
      })
      expect(i18n.language).toBe('en-US')
      expect(documentElement.lang).toBe('en-US')

      // Editing with default (null) data context targets the privileged home tenant.
      await syncConsoleLocaleIfPrivileged({
        scope: 'tenant',
        key: 'i18n.default_locale',
        value: 'zh-Hans-CN',
        selectedTenantID: null,
        privilegedTenantID: undefined
      })
      expect(i18n.language).toBe('zh-Hans-CN')
      expect(documentElement.lang).toBe('zh-Hans-CN')

      // Editing with explicit privileged tenant selection also switches the Console UI.
      await syncConsoleLocaleIfPrivileged({
        scope: 'tenant',
        key: 'i18n.default_locale',
        value: 'ko-KR',
        selectedTenantID: 'tenant-privileged',
        privilegedTenantID: 'tenant-privileged'
      })
      expect(i18n.language).toBe('ko-KR')
      expect(documentElement.lang).toBe('ko-KR')
    } finally {
      await loadLocale('en-US')
      await i18n.changeLanguage('en-US')
      if (previousDocument) Object.defineProperty(globalThis, 'document', previousDocument)
      else Reflect.deleteProperty(globalThis, 'document')
    }
  })
})

function item(value: unknown, encrypted = false): AppConfigurationItem {
  return {
    key: 'A',
    value,
    encrypted,
    present: true,
    editable: true,
    default_present: true,
    overridden: false,
    kind: 'exact',
    scope: 'tenant',
    source: 'default'
  }
}
