import { safeJsonParse } from '@agentbull/active-support'
import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { TFunction } from 'i18next'
import i18n, { availableLocaleIDs, loadLocale } from '../../common/i18n'
import type { AppConfigurationItem, AppConfigurationUpdateRequest } from '../api/configuration-types'
import { formatJSON, parseJSON } from '../console-primitives'
import { ENCRYPTED_VALUE_MASK, isEncryptedValueMask } from '../encrypted-value-input'

export async function syncConsoleLocaleIfPrivileged({
  scope,
  key,
  value,
  selectedTenantID,
  privilegedTenantID
}: {
  scope: 'global' | 'tenant'
  key: string
  value: unknown
  selectedTenantID: string | null
  privilegedTenantID: string | undefined
}): Promise<void> {
  if (scope !== 'tenant' || key !== 'i18n.default_locale') return
  if (selectedTenantID !== null && selectedTenantID !== privilegedTenantID) return
  if (typeof value !== 'string' || !availableLocaleIDs().includes(value)) return
  await loadLocale(value)
  if (typeof document !== 'undefined') document.documentElement.lang = value
  await i18n.changeLanguage(value)
}

export function settingDecryptedDraft(value: unknown): string {
  return typeof value === 'string' ? value : (JSON.stringify(value) ?? '')
}

export function encryptedSettingValue(text: string): unknown {
  // An opaque secret does not have to be JSON.
  const parsed = safeJsonParse(text).unwrapOr(undefined)
  return parsed !== null && typeof parsed === 'object' ? parsed : text
}

export const SettingEditorModel = createModel(() => {
  let source = Symbol()
  const sourceKey = signal<string>()
  const text = signal('')
  const revealed = signal(false)
  const validationError = signal<string>()
  const initialText = signal('')
  const dirty = computed(() => text.value !== initialText.value)

  const prepareUpdate = (encrypted: boolean, t: TFunction): AppConfigurationUpdateRequest | undefined => {
    validationError.value = undefined
    if (encrypted) {
      if (isEncryptedValueMask(text.value)) return {}
      if (!text.value.trim()) {
        validationError.value = t('common.field_required', { field: t('console.settings.value') })
        return
      }
      return { value: encryptedSettingValue(text.value) }
    }
    const parsed = parseJSON(text.value, t('console.settings.value'))
    if (!parsed.ok) {
      validationError.value = parsed.error
      return
    }
    return { value: parsed.value }
  }

  return {
    sourceKey,
    text,
    revealed,
    validationError,
    dirty,
    initialize(nextSourceKey: string, nextText: string) {
      if (sourceKey.value === nextSourceKey) return
      source = Symbol()
      batch(() => {
        sourceKey.value = nextSourceKey
        text.value = nextText
        initialText.value = nextText
        validationError.value = undefined
        revealed.value = false
      })
    },
    async reveal(request: () => Promise<unknown>) {
      const requestedSource = source
      const requestedText = text.peek()
      const value = await request()
      if (source !== requestedSource || text.peek() !== requestedText) return
      const nextText = settingDecryptedDraft(value)
      batch(() => {
        text.value = nextText
        initialText.value = nextText
        revealed.value = true
      })
    },
    async save(
      encrypted: boolean,
      t: TFunction,
      request: (body: AppConfigurationUpdateRequest) => Promise<unknown>,
      onSaved: (clean: boolean) => void
    ) {
      const body = prepareUpdate(encrypted, t)
      if (!body) return
      const requestedSource = source
      const sentText = text.peek()
      await request(body)
      if (source !== requestedSource) return
      initialText.value = sentText
      onSaved(!dirty.peek())
    },
    async restore(request: () => Promise<AppConfigurationItem>, onRestored: (clean: boolean) => void) {
      const requestedSource = source
      const requestedText = text.peek()
      const item = await request()
      if (source !== requestedSource) return
      const restoredText = item.encrypted ? (item.present ? ENCRYPTED_VALUE_MASK : '') : formatJSON(item.value ?? null)
      // A restore also revokes decryption of the previous stored value.
      source = Symbol()
      batch(() => {
        if (text.peek() === requestedText) text.value = restoredText
        initialText.value = restoredText
        validationError.value = undefined
        revealed.value = false
      })
      onRestored(!dirty.peek())
    },
    resetSource() {
      source = Symbol()
      batch(() => {
        sourceKey.value = undefined
        text.value = ''
        initialText.value = ''
        validationError.value = undefined
        revealed.value = false
      })
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})
