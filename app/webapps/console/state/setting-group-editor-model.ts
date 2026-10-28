import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { TFunction } from 'i18next'
import { requestErrorMessage } from '../../common/request-errors'
import type { AppConfigurationItem, JsonValue } from '../api/configuration-types'
import { formatJSON, parseJSON } from '../console-primitives'
import { encryptedSettingValue } from './setting-editor-model'
import { ENCRYPTED_VALUE_MASK } from '../encrypted-value-input'
import {
  brainCanonicalDraft,
  brainModelDraft,
  brainModelRequiresDimensions,
  brainModelValue,
  brainSettingsValidationError,
  isBrainModelKey,
  sameBrainModelDraft,
  type BrainModelDraft
} from './brain-setting-editor'
import {
  OBSERVABILITY_TRACE_KEYS,
  observabilityHeaderRows,
  observabilityHeadersValidationError,
  observabilityHeadersValue,
  observabilityTraceDraft,
  observabilityTraceValidationError,
  sameObservabilityHeaderRows,
  type ObservabilityHeaderRow
} from './observability-setting-editor'
import type { SettingGroupID } from './setting-groups'

type GroupSource = { kind: SettingGroupID; items: AppConfigurationItem[] }
type SavedSetting = {
  key: string
  value: JsonValue
  text: string
  model?: BrainModelDraft
  headers?: ObservabilityHeaderRow[]
}

function draftText(kind: SettingGroupID, item: AppConfigurationItem): string {
  if (item.encrypted && kind !== 'smtp') {
    return item.present ? ENCRYPTED_VALUE_MASK : ''
  }
  if (kind === 'smtp') return formatJSON(item.public_value ?? {})
  return (kind === 'brain' ? brainCanonicalDraft(item.key, item.value) : undefined) ?? formatJSON(item.value ?? null)
}

/** Owns the task draft; one request commits all dirty fields in the task. */
export const SettingGroupEditorModel = createModel(() => {
  let source = Symbol()
  let headersSource = Symbol()
  let kind: SettingGroupID | undefined
  const sourceKey = signal<string>()
  const drafts = signal<Record<string, string>>({})
  const initial = signal<Record<string, string>>({})
  const brainModels = signal<Record<string, BrainModelDraft>>({})
  const initialBrainModels = signal<Record<string, BrainModelDraft>>({})
  // Undefined keeps the stored map opaque; [] is an explicit empty replacement.
  const headerRows = signal<ObservabilityHeaderRow[]>()
  const initialHeaderRows = signal<ObservabilityHeaderRow[]>()
  const validationError = signal<string>()
  const saving = signal(false)
  const headersDirty = computed(() => !sameObservabilityHeaderRows(headerRows.value, initialHeaderRows.value))
  const dirty = computed(
    () =>
      Object.entries(drafts.value).some(([key, value]) => value !== initial.value[key]) ||
      headersDirty.value ||
      Object.entries(brainModels.value).some(([key, draft]) => {
        const baseline = initialBrainModels.value[key]
        return !baseline || !sameBrainModelDraft(draft, baseline)
      })
  )

  return {
    sourceKey,
    drafts,
    brainModels,
    headerRows,
    validationError,
    saving,
    dirty,
    initialize(nextSourceKey: string, next: GroupSource) {
      if (sourceKey.value === nextSourceKey) return
      source = Symbol()
      headersSource = Symbol()
      kind = next.kind
      const texts = Object.fromEntries(next.items.map(item => [item.key, draftText(next.kind, item)]))
      const models = Object.fromEntries(
        next.items
          .filter(item => next.kind === 'brain' && isBrainModelKey(item.key))
          .map(item => [item.key, brainModelDraft(item.value)])
      )
      batch(() => {
        sourceKey.value = nextSourceKey
        drafts.value = texts
        initial.value = texts
        brainModels.value = models
        initialBrainModels.value = models
        headerRows.value = undefined
        initialHeaderRows.value = undefined
        validationError.value = undefined
        saving.value = false
      })
    },
    resetSource() {
      source = Symbol()
      headersSource = Symbol()
      kind = undefined
      batch(() => {
        sourceKey.value = undefined
        drafts.value = {}
        initial.value = {}
        brainModels.value = {}
        initialBrainModels.value = {}
        headerRows.value = undefined
        initialHeaderRows.value = undefined
        validationError.value = undefined
        saving.value = false
      })
    },
    setDraft(key: string, value: string) {
      batch(() => {
        drafts.value = { ...drafts.value, [key]: value }
        validationError.value = undefined
      })
    },
    setBrainModel(key: string, value: BrainModelDraft) {
      batch(() => {
        brainModels.value = { ...brainModels.value, [key]: { ...value } }
        validationError.value = undefined
      })
    },
    setHeaderRows(rows: ObservabilityHeaderRow[]) {
      headersSource = Symbol()
      batch(() => {
        headerRows.value = rows
        validationError.value = undefined
      })
    },
    async revealHeaders(request: () => Promise<JsonValue>, t: TFunction) {
      const requestedSource = source
      const requestedHeaders = headersSource
      const value = await request()
      if (source !== requestedSource || headersSource !== requestedHeaders) return
      const rows = observabilityHeaderRows(value)
      if (!rows) {
        validationError.value = t('console.settings.observability_headers_invalid')
        return
      }
      headersSource = Symbol()
      batch(() => {
        headerRows.value = rows
        initialHeaderRows.value = rows
      })
    },
    async save(
      items: AppConfigurationItem[],
      t: TFunction,
      request: (values: Record<string, JsonValue>) => Promise<unknown>,
      onSaved: (count: number, clean: boolean) => void
    ) {
      validationError.value = undefined
      if (kind === 'observability') {
        const traceError = observabilityTraceValidationError(observabilityTraceDraft(drafts.value))
        const headersError =
          headersDirty.value && headerRows.value ? observabilityHeadersValidationError(headerRows.value) : undefined
        if (traceError || headersError) {
          validationError.value = t(`console.settings.observability_error_${traceError ?? headersError}`)
          return
        }
      }
      if (kind === 'brain') {
        const error = brainSettingsValidationError(drafts.value, brainModels.value)
        if (error) {
          validationError.value = t(`console.settings.brain_error_${error.error}`, {
            key: error.key,
            field: error.field
          })
          return
        }
      }

      const entries: SavedSetting[] = []
      for (const item of items) {
        const text = drafts.value[item.key] ?? ''
        if (item.key === OBSERVABILITY_TRACE_KEYS.headers && kind === 'observability') {
          if (headersDirty.value && headerRows.value) {
            const headers = headerRows.value.map(row => ({ ...row }))
            entries.push({ key: item.key, value: observabilityHeadersValue(headers), text, headers })
          }
        } else if (kind === 'brain' && isBrainModelKey(item.key)) {
          const model = brainModels.value[item.key]
          const baseline = initialBrainModels.value[item.key]
          if (model && (!baseline || !sameBrainModelDraft(model, baseline))) {
            entries.push({
              key: item.key,
              value: brainModelValue(model, brainModelRequiresDimensions(item.key)),
              text,
              model: { ...model }
            })
          }
        } else if (text !== initial.value[item.key]) {
          const parsed =
            item.encrypted && kind !== 'smtp'
              ? { ok: true as const, value: encryptedSettingValue(text) }
              : parseJSON(text, item.key)
          if (!parsed.ok) {
            validationError.value = parsed.error
            return
          }
          entries.push({ key: item.key, value: parsed.value, text })
        }
      }
      if (!entries.length) return
      const requestedSource = source
      saving.value = true
      try {
        try {
          await request(Object.fromEntries(entries.map(entry => [entry.key, entry.value])))
        } catch (error) {
          if (source === requestedSource) validationError.value = requestErrorMessage(error)
          throw error
        }
        if (source !== requestedSource) return
        batch(() => {
          for (const entry of entries) {
            initial.value = { ...initial.value, [entry.key]: entry.text }
            if (entry.model) initialBrainModels.value = { ...initialBrainModels.value, [entry.key]: entry.model }
            if (entry.headers) initialHeaderRows.value = entry.headers
          }
        })
        onSaved(entries.length, !dirty.peek())
      } finally {
        if (source === requestedSource) saving.value = false
      }
    },
    async restore(
      key: string,
      request: () => Promise<AppConfigurationItem>,
      onRestored: (item: AppConfigurationItem) => void
    ) {
      const requestedSource = source
      const requestedText = drafts.peek()[key]
      const requestedModel = brainModels.peek()[key]
      const requestedHeaders = headersSource
      const item = await request()
      if (source !== requestedSource || kind === undefined) return
      const text = draftText(kind, item)
      batch(() => {
        if (drafts.value[key] === requestedText) drafts.value = { ...drafts.value, [key]: text }
        initial.value = { ...initial.value, [key]: text }
        if (kind === 'brain' && isBrainModelKey(key)) {
          const model = brainModelDraft(item.value)
          if (brainModels.value[key] === requestedModel) {
            brainModels.value = { ...brainModels.value, [key]: model }
          }
          initialBrainModels.value = { ...initialBrainModels.value, [key]: model }
        }
        if (kind === 'observability' && key === OBSERVABILITY_TRACE_KEYS.headers) {
          if (headersSource === requestedHeaders) headerRows.value = undefined
          headersSource = Symbol()
          initialHeaderRows.value = undefined
        }
        validationError.value = undefined
      })
      onRestored(item)
    }
  }
})
