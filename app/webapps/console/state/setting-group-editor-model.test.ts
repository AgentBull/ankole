import { beforeAll, describe, expect, test } from 'bun:test'
import { MutationObserver, QueryClient } from '@tanstack/react-query'
import i18n, { loadLocale } from '../../common/i18n'
import type { AppConfigurationItem } from '../api/configuration-types'
import { ENCRYPTED_VALUE_MASK } from '../encrypted-value-input'
import { seedEditorDraft } from '../use-editor-draft'
import { OBSERVABILITY_TRACE_KEYS as TRACE } from './observability-setting-editor'
import { SettingGroupEditorModel } from './setting-group-editor-model'

beforeAll(() => loadLocale('en-US'))
const t = i18n.getFixedT('en-US')
function item(key: string, value: unknown, encrypted = false): AppConfigurationItem {
  return {
    key,
    value,
    encrypted,
    present: value !== undefined,
    editable: true,
    kind: 'exact',
    default_present: true,
    source: 'default',
    overridden: false,
    scope: 'global'
  }
}
const traces = [
  item(TRACE.enabled, false),
  item(TRACE.endpoint, ''),
  item(TRACE.provider, 'langfuse'),
  item(TRACE.headers, undefined, true)
]

describe('atomic settings drafts', () => {
  test('refetch preserves edits and opaque headers are omitted until explicitly replaced', async () => {
    using model = new SettingGroupEditorModel()
    const rows = traces.map(row => (row.key === TRACE.headers ? { ...row, present: true } : row))
    const source = { kind: 'observability' as const, items: rows }
    seedEditorDraft(model, 'site', source, false)
    expect(model.drafts.value[TRACE.headers]).toBe(ENCRYPTED_VALUE_MASK)
    model.setDraft(TRACE.endpoint, '"https://collector.example.test"')
    seedEditorDraft(model, 'site', source, false)
    const writes: Record<string, unknown>[] = []
    await model.save(
      rows,
      t,
      async values => {
        writes.push(values)
      },
      () => {}
    )
    expect(writes).toEqual([{ [TRACE.endpoint]: 'https://collector.example.test' }])
    model.setHeaderRows([])
    await model.save(
      rows,
      t,
      async values => {
        writes.push(values)
      },
      () => {}
    )
    expect(writes[1]).toEqual({ [TRACE.headers]: {} })
    expect(model.dirty.value).toBe(false)
  })

  test('incomplete connections and malformed later fields prevent every write', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('site', { kind: 'observability', items: traces })
    model.setDraft(TRACE.enabled, 'true')
    let writes = 0
    const request = async () => {
      writes++
    }
    await model.save(traces, t, request, () => {})
    expect(writes).toBe(0)
    expect(model.validationError.value).toBeTruthy()
    model.setDraft(TRACE.endpoint, '"https://collector.example.test"')
    model.setDraft(TRACE.provider, '{')
    await model.save(traces, t, request, () => {})
    expect(writes).toBe(0)
    expect(model.dirty.value).toBe(true)
  })

  test('server rejection keeps all baselines and retry sends the complete batch', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('site', { kind: 'observability', items: traces })
    model.setDraft(TRACE.enabled, 'true')
    model.setDraft(TRACE.endpoint, '"https://collector.example.test"')
    const writes: Record<string, unknown>[] = []
    await expect(
      model.save(
        traces,
        t,
        async values => {
          writes.push(values)
          throw new Error('rejected')
        },
        () => {}
      )
    ).rejects.toThrow('rejected')
    expect(model.dirty.value).toBe(true)
    expect(model.saving.value).toBe(false)
    let clean = false
    await model.save(
      traces,
      t,
      async values => {
        writes.push(values)
      },
      (_count, savedClean) => {
        clean = savedClean
      }
    )
    expect(writes).toHaveLength(2)
    expect(writes[1]).toEqual(writes[0])
    expect(Object.keys(writes[0]!)).toHaveLength(2)
    expect(clean).toBe(true)
  })

  test('acknowledging a sent header snapshot preserves later edits', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('site', { kind: 'observability', items: traces })
    model.setHeaderRows([{ id: '1', name: 'Authorization', value: 'sent' }])
    const response = Promise.withResolvers<void>()
    const pending = model.save(
      traces,
      t,
      () => response.promise,
      () => {}
    )
    model.setHeaderRows([{ id: '1', name: 'Authorization', value: 'later' }])
    response.resolve()
    await pending
    expect(model.headerRows.value?.[0]?.value).toBe('later')
    expect(model.dirty.value).toBe(true)
  })

  test('an atomic Query completion cannot navigate or alter a newly selected workspace', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('a', { kind: 'observability', items: traces })
    model.setDraft(TRACE.endpoint, '"https://collector.example.test"')
    const response = Promise.withResolvers<void>()
    const client = new QueryClient()
    const update = new MutationObserver<void, Error, Record<string, unknown>>(client, {
      mutationFn: () => response.promise,
      gcTime: 0
    })
    let navigated = false
    const pending = model.save(
      traces,
      t,
      values => update.mutate(values),
      () => {
        navigated = true
      }
    )
    await Promise.resolve()
    model.resetSource()
    model.initialize('b', { kind: 'observability', items: traces })
    response.resolve()
    await pending
    expect(navigated).toBe(false)
    expect(model.dirty.value).toBe(false)
    expect(model.sourceKey.value).toBe('b')
    client.clear()
  })

  test('SMTP drafts use public fields and retain passwords through omission', async () => {
    using model = new SettingGroupEditorModel()
    const smtp = {
      ...item('authn.email.mail', undefined, true),
      present: true,
      public_value: { server: 'old.example', from: 'sender@example.test' },
      secret_present: true
    }
    model.initialize('smtp', { kind: 'smtp', items: [smtp] })
    expect(model.drafts.value[smtp.key]).not.toContain('password')
    model.setDraft(smtp.key, JSON.stringify({ server: 'new.example', from: 'sender@example.test' }))
    let sent: Record<string, unknown> = {}
    await model.save(
      [smtp],
      t,
      async values => {
        sent = values
      },
      () => {}
    )
    expect(sent[smtp.key]).toEqual({ server: 'new.example', from: 'sender@example.test' })
  })

  test('late reveals and resets cannot overwrite edits or another source', async () => {
    using model = new SettingGroupEditorModel()
    model.initialize('a', { kind: 'observability', items: traces })
    const reveal = Promise.withResolvers<unknown>()
    const pending = model.revealHeaders(() => reveal.promise, t)
    model.setHeaderRows([{ id: '1', name: 'Authorization', value: 'local' }])
    reveal.resolve({ Authorization: 'remote' })
    await pending
    expect(model.headerRows.value?.[0]?.value).toBe('local')
    const reset = Promise.withResolvers<AppConfigurationItem>()
    const restoring = model.restore(
      TRACE.endpoint,
      () => reset.promise,
      () => {
        throw new Error('stale completion')
      }
    )
    model.resetSource()
    model.initialize('b', { kind: 'observability', items: traces })
    reset.resolve(item(TRACE.endpoint, 'https://a.example'))
    await restoring
    expect(model.drafts.value[TRACE.endpoint]).toBe('""')
  })
})
