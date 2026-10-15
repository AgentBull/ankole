import { beforeAll, describe, expect, test } from 'bun:test'
import { MutationObserver, QueryClient } from '@tanstack/react-query'
import i18n, { loadLocale } from '../../common/i18n'
import type { AppConfigurationItem } from '../api/generated/types.gen'
import { ENCRYPTED_VALUE_MASK } from '../encrypted-value-input'
import { resolveEditorDraftIdentity, seedEditorDraft } from '../use-editor-draft'
import { BRAIN_FORGETTING_FIELDS, BRAIN_KEYS } from './brain-setting-editor'
import { OBSERVABILITY_TRACE_KEYS as TRACE } from './observability-setting-editor'
import { SettingGroupEditorModel } from './setting-group-editor-model'

beforeAll(() => loadLocale('en-US'))
const t = i18n.getFixedT('en-US')
const observability = [
  item(TRACE.enabled, false),
  item(TRACE.endpoint, ''),
  item(TRACE.provider, 'langfuse'),
  item(TRACE.headers, undefined, true)
]

describe('SettingGroupEditorModel', () => {
  test('seeds through the shared draft lifecycle without replacing edits on refetch', () => {
    using model = new SettingGroupEditorModel()
    const identity = resolveEditorDraftIdentity({ resource: 'setting-group', scope: 'tenant', group: 'observability' })
    seedEditorDraft(model, identity, { kind: 'observability', items: observability }, false)
    model.setDraft(TRACE.endpoint, '"https://collector.example.test"')
    seedEditorDraft(
      model,
      identity,
      { kind: 'observability', items: observability.map(row => ({ ...row, value: null })) },
      false
    )
    expect(model.drafts.value[TRACE.endpoint]).toBe('"https://collector.example.test"')
    expect(model.dirty.value).toBe(true)
  })

  test('leaves unread headers untouched and writes an explicitly empty replacement', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces', { kind: 'observability', items: observability })
    expect(model.drafts.value[TRACE.headers]).toBe(ENCRYPTED_VALUE_MASK)
    const writes: Array<{ key: string; value: unknown }> = []
    const request = async (key: string, value: unknown) => {
      writes.push({ key, value })
    }
    model.setDraft(TRACE.endpoint, '"https://collector.example.test"')
    await model.save(observability, t, request, () => {})
    expect(writes).toEqual([{ key: TRACE.endpoint, value: 'https://collector.example.test' }])
    model.setHeaderRows([])
    await model.save(observability, t, request, () => {})
    expect(writes[1]).toEqual({ key: TRACE.headers, value: {} })
    expect(model.headerRows.value).toEqual([])
    expect(model.dirty.value).toBe(false)
  })

  test('validates the whole group before the first request', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces', { kind: 'observability', items: observability })
    const writes: string[] = []
    const request = async (key: string) => {
      writes.push(key)
    }
    model.setDraft(TRACE.enabled, 'true')
    await model.save(observability, t, request, () => {})
    expect(model.validationError.value).toBeTruthy()
    model.setDraft(TRACE.endpoint, '"https://collector.example.test"')
    model.setHeaderRows([
      { id: '1', name: 'Authorization', value: 'first' },
      { id: '2', name: 'authorization', value: 'second' }
    ])
    await model.save(observability, t, request, () => {})
    expect(writes).toEqual([])
    expect(model.validationError.value).toBeTruthy()
    expect(model.dirty.value).toBe(true)
    expect(model.saving.value).toBe(false)
  })

  test('a malformed later key prevents the earlier key from being written', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces', { kind: 'observability', items: observability })
    model.setDraft(TRACE.endpoint, '"https://collector.example.test"')
    model.setDraft(TRACE.provider, '{')
    const writes: string[] = []
    await model.save(
      observability,
      t,
      async key => {
        writes.push(key)
      },
      () => {}
    )
    expect(writes).toEqual([])
    expect(model.validationError.value).toBeTruthy()
  })

  test('a failed key stops the batch, reports its reason, and only successful keys leave the retry', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces', { kind: 'observability', items: observability })
    model.setDraft(TRACE.enabled, 'true')
    model.setDraft(TRACE.endpoint, '"https://collector.example.test"')
    model.setDraft(TRACE.provider, '"langsmith"')
    const writes: string[] = []
    const completions: boolean[] = []
    await model.save(
      observability,
      t,
      async key => {
        expect(model.saving.value).toBe(true)
        writes.push(key)
        if (key === TRACE.endpoint) throw new Error('collector unavailable')
      },
      (_count, clean) => completions.push(clean)
    )
    expect(writes).toEqual([TRACE.enabled, TRACE.endpoint])
    expect(model.validationError.value).toContain(TRACE.endpoint)
    expect(model.validationError.value).toContain('collector unavailable')
    expect(model.drafts.value[TRACE.endpoint]).toBe('"https://collector.example.test"')
    expect(model.drafts.value[TRACE.provider]).toBe('"langsmith"')
    expect(model.dirty.value).toBe(true)
    expect(model.saving.value).toBe(false)
    expect(completions).toEqual([])

    writes.length = 0
    await model.save(
      observability,
      t,
      async key => {
        writes.push(key)
      },
      (_count, clean) => completions.push(clean)
    )
    expect(writes).toEqual([TRACE.endpoint, TRACE.provider])
    expect(completions).toEqual([true])
    expect(model.dirty.value).toBe(false)
    expect(model.validationError.value).toBeUndefined()
  })

  test('a successful header write rebaselines its sent snapshot and retains later edits', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces', { kind: 'observability', items: observability })
    model.setHeaderRows([{ id: '1', name: 'Authorization', value: 'sent secret' }])
    const response = Promise.withResolvers<void>()
    const writes: unknown[] = []
    const completions: boolean[] = []
    const pending = model.save(
      observability,
      t,
      (_key, value) => {
        writes.push(value)
        return response.promise
      },
      (_count, clean) => completions.push(clean)
    )
    model.setHeaderRows([{ id: '1', name: 'Authorization', value: 'newer secret' }])
    response.resolve()
    await pending
    expect(writes).toEqual([{ Authorization: 'sent secret' }])
    expect(completions).toEqual([false])
    expect(model.dirty.value).toBe(true)
    model.setHeaderRows([{ id: '1', name: 'Authorization', value: 'sent secret' }])
    expect(model.dirty.value).toBe(false)
  })

  test('an old save cannot rebaseline or finish another visit to the group', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces:tenant', { kind: 'observability', items: observability })
    model.setDraft(TRACE.provider, '"langsmith"')
    const response = Promise.withResolvers<void>()
    const completions: boolean[] = []
    const pending = model.save(
      observability,
      t,
      () => response.promise,
      (_count, clean) => completions.push(clean)
    )
    model.initialize('traces:global', { kind: 'observability', items: observability })
    model.initialize('traces:tenant', { kind: 'observability', items: observability })
    model.setDraft(TRACE.provider, '"opentelemetry"')
    response.resolve()
    await pending
    expect(completions).toEqual([])
    expect(model.drafts.value[TRACE.provider]).toBe('"opentelemetry"')
    expect(model.dirty.value).toBe(true)
    expect(model.saving.value).toBe(false)
  })

  test('selection invalidates pending headers and restore before the next group loads', async () => {
    using model = new SettingGroupEditorModel()
    const a = resolveEditorDraftIdentity({ resource: 'setting-group', scope: 'tenant', group: 'observability' })
    const b = resolveEditorDraftIdentity({ resource: 'setting-group', scope: 'global', group: 'observability' })
    seedEditorDraft(model, a, { kind: 'observability', items: observability }, false)
    const headerResponse = Promise.withResolvers<unknown>()
    const restoreResponse = Promise.withResolvers<AppConfigurationItem>()
    const reveals = model.revealHeaders(() => headerResponse.promise, t)
    const completions: string[] = []
    const restore = model.restore(
      TRACE.provider,
      () => restoreResponse.promise,
      row => completions.push(row.key)
    )
    seedEditorDraft(model, b, undefined, false)
    headerResponse.resolve({ Authorization: 'tenant secret' })
    restoreResponse.resolve(item(TRACE.provider, 'langsmith'))
    await Promise.all([reveals, restore])
    expect(completions).toEqual([])
    expect(model.sourceKey.value).toBeUndefined()
    expect(model.drafts.value).toEqual({})
    expect(model.brainModels.value).toEqual({})
    expect(model.headerRows.value).toBeUndefined()
  })

  for (const departure of ['loading scope selection', 'unmount']) {
    test(`a group save stops before Query can send the next key after ${departure}`, async () => {
      using model = new SettingGroupEditorModel()
      const a = resolveEditorDraftIdentity({ resource: 'setting-group', scope: 'tenant', group: 'observability' })
      const b = resolveEditorDraftIdentity({ resource: 'setting-group', scope: 'global', group: 'observability' })
      seedEditorDraft(model, a, { kind: 'observability', items: observability }, false)
      model.setDraft(TRACE.endpoint, '"https://collector.example.test"')
      model.setDraft(TRACE.provider, '"langsmith"')
      const started = Promise.withResolvers<void>()
      const response = Promise.withResolvers<void>()
      const writes: Array<{ scope: string; key: string }> = []
      const navigations: string[] = []
      const client = new QueryClient()
      const update = new MutationObserver<void, Error, { key: string }>(client, {
        mutationFn: ({ key }) => {
          writes.push({ scope: 'tenant', key })
          started.resolve()
          return response.promise
        },
        gcTime: 0
      })
      const pending = model.save(
        observability,
        t,
        key => update.mutate({ key }),
        () => navigations.push('/settings')
      )
      await started.promise
      if (departure === 'unmount') {
        model.resetSource()
        model[Symbol.dispose]()
      } else {
        seedEditorDraft(model, b, undefined, false)
      }
      update.setOptions({
        mutationFn: async ({ key }) => {
          writes.push({ scope: 'global', key })
        },
        gcTime: 0
      })
      response.resolve()
      await pending
      expect(writes).toEqual([{ scope: 'tenant', key: TRACE.endpoint }])
      expect(navigations).toEqual([])
      expect(model.sourceKey.value).toBeUndefined()
      expect(model.saving.value).toBe(false)
      client.clear()
    })
  }

  test('late header decryption cannot cross return visits or explicit replacements', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces:tenant', { kind: 'observability', items: observability })
    const oldResponse = Promise.withResolvers<unknown>()
    const oldReveal = model.revealHeaders(() => oldResponse.promise, t)
    model.initialize('traces:global', { kind: 'observability', items: observability })
    model.initialize('traces:tenant', { kind: 'observability', items: observability })
    oldResponse.resolve({ Authorization: 'old tenant secret' })
    await oldReveal
    expect(model.headerRows.value).toBeUndefined()

    const response = Promise.withResolvers<unknown>()
    const pending = model.revealHeaders(() => response.promise, t)
    model.setHeaderRows([])
    response.resolve({ Authorization: 'stored secret' })
    await pending
    expect(model.headerRows.value).toEqual([])
    expect(model.dirty.value).toBe(true)
  })

  test('revealing headers preserves sibling drafts and does not write the revealed map', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces', { kind: 'observability', items: observability })
    model.setDraft(TRACE.provider, '"langsmith"')
    await model.revealHeaders(async () => ({ Authorization: 'stored secret' }), t)
    expect(model.dirty.value).toBe(true)
    const writes: string[] = []
    await model.save(
      observability,
      t,
      async key => {
        writes.push(key)
      },
      () => {}
    )
    expect(writes).toEqual([TRACE.provider])
  })

  test('restores only the selected key and revokes its pending header reveal', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces', { kind: 'observability', items: observability })
    model.setDraft(TRACE.provider, '"langsmith"')
    const response = Promise.withResolvers<unknown>()
    const pending = model.revealHeaders(() => response.promise, t)
    await model.restore(
      TRACE.headers,
      async () => ({ ...item(TRACE.headers, undefined, true), present: false }),
      () => {}
    )
    response.resolve({ Authorization: 'removed secret' })
    await pending
    expect(model.headerRows.value).toBeUndefined()
    expect(model.drafts.value[TRACE.provider]).toBe('"langsmith"')
    const writes: string[] = []
    await model.save(
      observability,
      t,
      async key => {
        writes.push(key)
      },
      () => {}
    )
    expect(writes).toEqual([TRACE.provider])
  })

  test('restoring a key keeps edits made after the request began', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces', { kind: 'observability', items: observability })
    const response = Promise.withResolvers<AppConfigurationItem>()
    const pending = model.restore(
      TRACE.provider,
      () => response.promise,
      () => {}
    )
    model.setDraft(TRACE.provider, '"langsmith"')
    response.resolve(item(TRACE.provider, 'opentelemetry'))
    await pending
    expect(model.drafts.value[TRACE.provider]).toBe('"langsmith"')
    expect(model.dirty.value).toBe(true)
    model.setDraft(TRACE.provider, '"opentelemetry"')
    expect(model.dirty.value).toBe(false)
  })

  test('validates Brain options before writing and retains model edits made during save', async () => {
    using model = new SettingGroupEditorModel()
    const items = brainItems()
    model.initialize('brain', { kind: 'brain', items })
    const draft = {
      configured: true,
      providerID: 'openai',
      model: 'text-embedding',
      dimensions: '1024',
      providerOptions: '{'
    }
    const writes: Array<{ key: string; value: unknown }> = []
    const response = Promise.withResolvers<void>()
    const request = (key: string, value: unknown) => {
      writes.push({ key, value })
      return response.promise
    }
    model.setBrainModel(BRAIN_KEYS.embeddingModel, draft)
    await model.save(items, t, request, () => {})
    expect(writes).toEqual([])
    expect(model.validationError.value).toBeTruthy()
    model.setBrainModel(BRAIN_KEYS.embeddingModel, { ...draft, providerOptions: '{}' })
    const pending = model.save(items, t, request, () => {})
    model.setBrainModel(BRAIN_KEYS.embeddingModel, { ...draft, providerOptions: '{}', model: 'newer model' })
    response.resolve()
    await pending
    expect(writes).toEqual([
      {
        key: BRAIN_KEYS.embeddingModel,
        value: { provider_id: 'openai', model: 'text-embedding', dimensions: 1024 }
      }
    ])
    expect(model.brainModels.value[BRAIN_KEYS.embeddingModel]?.model).toBe('newer model')
    expect(model.dirty.value).toBe(true)
    model.setBrainModel(BRAIN_KEYS.embeddingModel, { ...draft, providerOptions: '{}' })
    expect(model.dirty.value).toBe(false)
    model.resetSource()
    model.initialize('traces', { kind: 'observability', items: observability })
    expect(model.brainModels.value).toEqual({})
  })

  test('a stale rejected write remains observable without changing the new draft', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces:tenant', { kind: 'observability', items: observability })
    model.setDraft(TRACE.provider, '"langsmith"')
    const response = Promise.withResolvers<void>()
    const pending = model.save(
      observability,
      t,
      () => response.promise,
      () => {}
    )
    model.initialize('traces:global', { kind: 'observability', items: observability })
    const failure = new Error('tenant request failed')
    response.reject(failure)
    await expect(pending).rejects.toBe(failure)
    expect(model.validationError.value).toBeUndefined()
    expect(model.dirty.value).toBe(false)
    expect(model.saving.value).toBe(false)
  })

  test('invalid header data is visible and request or completion exceptions do not disappear', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('traces', { kind: 'observability', items: observability })
    await model.revealHeaders(async () => 'invalid map', t)
    expect(model.validationError.value).toBeTruthy()
    const failure = new Error('unexpected failure')
    const request = async (): Promise<never> => {
      throw failure
    }
    await expect(model.revealHeaders(request, t)).rejects.toBe(failure)
    await expect(model.restore(TRACE.provider, request, () => {})).rejects.toBe(failure)
    model.setDraft(TRACE.provider, '"langsmith"')
    await expect(
      model.save(
        observability,
        t,
        async () => {},
        () => {
          throw failure
        }
      )
    ).rejects.toBe(failure)
    expect(model.saving.value).toBe(false)
  })
})

function item(key: string, value: unknown, encrypted = false): AppConfigurationItem {
  return {
    key,
    value,
    encrypted,
    present: true,
    editable: true,
    default_present: true,
    overridden: true,
    kind: 'exact',
    scope: 'tenant',
    source: 'tenant'
  }
}

function brainItems(): AppConfigurationItem[] {
  return [
    item(BRAIN_KEYS.embeddingModel, null),
    item(BRAIN_KEYS.rerankModel, null),
    item(BRAIN_KEYS.chunking, { chunk_size: 1024, chunk_overlap: 0, max_chars: 10_000, max_tokens: 2000 }),
    item(BRAIN_KEYS.forgetting, Object.fromEntries(BRAIN_FORGETTING_FIELDS.map(field => [field, 10]))),
    item(BRAIN_KEYS.dreamingTaskCron, '0 2 * * *'),
    item(BRAIN_KEYS.selfHealingTaskCron, '0 3 * * *'),
    item(BRAIN_KEYS.signalChannelBatchIdleTime, 30),
    item(BRAIN_KEYS.skillLearningReflectionThreshold, 2)
  ]
}
