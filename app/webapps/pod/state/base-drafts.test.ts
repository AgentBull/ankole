import { expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { BaseCellModel } from './base-cell'
import { FieldEditorModel, fieldHasStoredValues } from './field-editor'
import { FieldInputModel } from './field-input'
import { TableWorkspaceModel } from './table-workspace'
import { sanitizeViewConfig } from '../base-page'
import { resolveVisibleFields } from '../base-field-types'
import { RecordTitle, formatRecordLabel } from '../base-field-value'
import type { BaseField, BaseRecord } from '@ankole/applet-sdk/types'

const field: BaseField = {
  id: 'price',
  name: 'Price',
  description: '',
  type: 'number',
  config: {},
  version: 1,
  is_primary: false
}

test('a cell preserves begin-of-edit versions across refocus, conflict and deliberate retry', async () => {
  const model = new BaseCellModel()
  model.begin({ price: 1 })
  model.begin({ price: 2 })
  const requests: unknown[] = []
  await expect(
    model.save('price', 10, { price: 2 }, async (value, versions) => {
      requests.push({ value, versions })
      throw new Error('Conflict')
    })
  ).rejects.toThrow('Conflict')
  expect(requests).toEqual([{ value: 10, versions: { price: 1 } }])
  expect(model.attempt.value?.value).toBe(10)
  expect(model.pending.value).toBe(false)
  await model.save(
    'price',
    10,
    { price: 2 },
    async (value, versions) => {
      requests.push({ value, versions })
    },
    true
  )
  expect(requests.at(-1)).toEqual({ value: 10, versions: { price: 2 } })
  expect(model.attempt.value).toBeUndefined()
})

test('a pending cell sends once, retains absence of an unwritten field and discard releases the edit', async () => {
  const model = new BaseCellModel(),
    gate = Promise.withResolvers<void>()
  let requests = 0
  model.begin({ other: 2 })
  const save = async (_value: unknown, versions: unknown) => {
    requests++
    expect(versions).toEqual({})
    await gate.promise
  }
  const pending = model.save('price', 0, { price: 4 }, save)
  await model.save('price', 20, { price: 4 }, save)
  expect(requests).toBe(1)
  gate.resolve()
  await pending
  model.discard()
  model.begin({ price: 5 })
  await model.save('price', 30, { price: 6 }, async (_value, versions) => {
    expect(versions).toEqual({ price: 5 })
  })
})

test('field definitions are seeded on open and type conversions use a coherent draft', () => {
  const model = new FieldEditorModel()
  model.load(field)
  model.setName('Unit price')
  model.setType('select')
  model.setOptions([
    { id: 'a', name: 'Open' },
    { id: 'b', name: '  ' }
  ])
  model.setMultiple(true)
  expect(model.baseVersion.value).toBe(1)
  expect(model.config.value).toEqual({ multiple: true, options: [{ id: 'a', name: 'Open' }] })
  expect(model.changesValues.value).toBe(true)
  model.load({ ...field, version: 3 })
  expect(model.name.value).toBe('Price')
  expect(model.baseVersion.value).toBe(3)
  expect(model.type.value).toBe('number')
  expect(model.confirmation.value).toBeUndefined()
})

test('a field description loads with its definition and changes no stored values', () => {
  const model = new FieldEditorModel()
  model.load({ ...field, description: 'CNY, tax included' })
  expect(model.description.value).toBe('CNY, tax included')
  model.setDescription('USD, before tax')
  expect(model.changesValues.value).toBe(false)
  expect(model.config.value).toEqual({})
  model.load(field)
  expect(model.description.value).toBe('')
})

test('input refetch preserves a dirty string; Escape resets to the current authoritative value', () => {
  const model = new FieldInputModel()
  model.load(1, 'number')
  model.edit('42')
  model.load(2, 'number')
  expect(model.draft.value).toBe('42')
  model.cancel(2, 'number')
  expect(model.draft.value).toBe('2')
  expect(model.dirty.value).toBe(false)
})

test('a shared view draft preserves its captured version; changing view resets draft and newRecord', () => {
  const model = new TableWorkspaceModel()
  model.load('grid')
  model.configure({ sort: [] }, 1)
  model.configure({ visible_fields: ['price'] }, 2)
  model.newRecord.value = true
  expect(model.draft.value?.version).toBe(1)
  model.select('gallery')
  expect(model.draft.value).toBeUndefined()
  expect(model.newRecord.value).toBe(false)
  expect(model.viewID.value).toBe('gallery')
})

test('acknowledgeDraft clears only the matching save sequence and preserves newer queued chart edits', () => {
  const model = new TableWorkspaceModel()
  try {
    model.load('chart')

    const seqA = model.configure({ chart: { chart_type: 'bar' } }, 1)
    const seqB = model.configure({ chart: { chart_type: 'line' } }, 1)

    expect(seqB).toBeGreaterThan(seqA)
    // Save A completes after Edit B has already been queued/dispatched: B's draft must survive.
    model.acknowledgeDraft(seqA)
    expect(model.draft.value).toEqual({
      config: { chart: { chart_type: 'line' } },
      version: 1,
      seq: seqB
    })

    // Save B completes when no newer edit occurred: draft clears.
    model.acknowledgeDraft(seqB)
    expect(model.draft.value).toBeUndefined()
  } finally {
    model[Symbol.dispose]()
  }
})

test('chart auto-save debounces edits, suppresses stale in-flight failure when a newer edit is queued, and surfaces terminal errors', async () => {
  const model = new TableWorkspaceModel({ autoSaveDelayMs: 20 })
  try {
    model.load('chart-1')
    model.observeViewVersions([{ id: 'chart-1', version: 3 }])

    const calls: Array<{ seq: number; targetVersion: number; chartType: string | undefined }> = []
    const gateA = Promise.withResolvers<void>()
    const gateB = Promise.withResolvers<void>()

    // Rapid edits coalesce within the debounce window.
    model.scheduleChartAutoSave({
      viewId: 'chart-1',
      config: { chart: { chart_type: 'bar' } },
      fallbackVersion: 3,
      persist: async (payload, targetVersion) => {
        calls.push({ seq: payload.seq, targetVersion, chartType: payload.config.chart?.chart_type })
      }
    })
    const seqA = model.scheduleChartAutoSave({
      viewId: 'chart-1',
      config: { chart: { chart_type: 'area' } },
      fallbackVersion: 3,
      persist: async (payload, targetVersion) => {
        calls.push({ seq: payload.seq, targetVersion, chartType: payload.config.chart?.chart_type })
        await gateA.promise
        throw new Error('Stale version conflict on A')
      }
    })

    await Bun.sleep(35)
    expect(calls).toEqual([{ seq: seqA, targetVersion: 3, chartType: 'area' }])

    // While A is still in flight, user makes edit B and its debounce timer fires so B is readyToSend.
    const seqB = model.scheduleChartAutoSave({
      viewId: 'chart-1',
      config: { chart: { chart_type: 'line' } },
      fallbackVersion: 3,
      persist: async (payload, targetVersion) => {
        calls.push({ seq: payload.seq, targetVersion, chartType: payload.config.chart?.chart_type })
        await gateB.promise
        return { version: 5 }
      }
    })
    await Bun.sleep(35)

    // Now A rejects! Because B is already queued, A's stale error is suppressed and B starts immediately.
    gateA.resolve()
    await Bun.sleep(10)
    expect(model.autoSaveError.value).toBeUndefined()
    expect(model.draft.value?.config).toEqual({ chart: { chart_type: 'line' } })
    expect(calls).toHaveLength(2)
    expect(calls[1]).toEqual({ seq: seqB, targetVersion: 3, chartType: 'line' })

    // B succeeds -> version advances to 5 and draft clears cleanly.
    gateB.resolve()
    await model.flushChartAutoSave()
    expect(model.draft.value).toBeUndefined()
    expect(model.autoSaveError.value).toBeUndefined()
    expect(model.knownViewVersion('chart-1', 3)).toBe(5)

    // Subsequent edit C fails with no newer edit queued -> error surfaces and draft remains for retry/discard.
    model.scheduleChartAutoSave({
      viewId: 'chart-1',
      config: { chart: { chart_type: 'pie' } },
      fallbackVersion: 5,
      persist: async (payload, targetVersion) => {
        calls.push({ seq: payload.seq, targetVersion, chartType: payload.config.chart?.chart_type })
        throw new Error('Terminal conflict on C')
      }
    })
    await model.flushChartAutoSave()
    expect(calls[2]?.targetVersion).toBe(5)
    expect(model.autoSaveError.value).toBeInstanceOf(Error)
    expect((model.autoSaveError.value as Error).message).toBe('Terminal conflict on C')
    expect(model.draft.value?.config).toEqual({ chart: { chart_type: 'pie' } })

    // Explicit discard clears both draft and surfaced error.
    model.discard()
    expect(model.draft.value).toBeUndefined()
    expect(model.autoSaveError.value).toBeUndefined()
  } finally {
    model[Symbol.dispose]()
  }
})

test('flushChartAutoSave before switching views preserves trailing queued chart save in order', async () => {
  const model = new TableWorkspaceModel({ autoSaveDelayMs: 500 })
  try {
    model.load('chart-1')
    model.observeViewVersions([
      { id: 'chart-1', version: 1 },
      { id: 'grid-2', version: 1 }
    ])

    const saved: Array<{ viewId: string; chartType: string | undefined; targetVersion: number }> = []
    const gateA = Promise.withResolvers<void>()

    model.scheduleChartAutoSave({
      viewId: 'chart-1',
      config: { chart: { chart_type: 'bar' } },
      fallbackVersion: 1,
      persist: async (payload, targetVersion) => {
        saved.push({ viewId: payload.viewId, chartType: payload.config.chart?.chart_type, targetVersion })
        await gateA.promise
        return { version: 2 }
      }
    })
    // Trigger A immediately, then queue B while A is in flight, then flush + switch view to grid-2.
    const flushA = model.flushChartAutoSave()
    await Bun.sleep(5)
    expect(saved).toHaveLength(1)

    model.scheduleChartAutoSave({
      viewId: 'chart-1',
      config: { chart: { chart_type: 'line' } },
      fallbackVersion: 1,
      persist: async (payload, targetVersion) => {
        saved.push({ viewId: payload.viewId, chartType: payload.config.chart?.chart_type, targetVersion })
        return { version: 3 }
      }
    })
    const flushB = model.flushChartAutoSave()
    model.select('grid-2')
    expect(model.viewID.value).toBe('grid-2')
    expect(model.draft.value).toBeUndefined()

    gateA.resolve()
    await Promise.all([flushA, flushB])
    expect(saved).toEqual([
      { viewId: 'chart-1', chartType: 'bar', targetVersion: 1 },
      { viewId: 'chart-1', chartType: 'line', targetVersion: 2 }
    ])
    expect(model.knownViewVersion('chart-1', 1)).toBe(3)
  } finally {
    model[Symbol.dispose]()
  }
})

test('switching from chart-1 after flushChartAutoSave and immediately editing chart-2 preserves chart-1 flushed save', async () => {
  const model = new TableWorkspaceModel({ autoSaveDelayMs: 500 })
  try {
    model.load('chart-1')
    model.observeViewVersions([
      { id: 'chart-1', version: 1 },
      { id: 'chart-2', version: 1 }
    ])
    const gateA = Promise.withResolvers<void>()
    const saved: Array<{ viewId: string; chartType: string | undefined }> = []

    model.scheduleChartAutoSave({
      viewId: 'chart-1',
      config: { chart: { chart_type: 'bar' } },
      fallbackVersion: 1,
      persist: async payload => {
        saved.push({ viewId: payload.viewId, chartType: payload.config.chart?.chart_type })
        await gateA.promise
        return { version: 2 }
      }
    })
    const flushA = model.flushChartAutoSave()
    await Bun.sleep(5)

    model.scheduleChartAutoSave({
      viewId: 'chart-1',
      config: { chart: { chart_type: 'line' } },
      fallbackVersion: 1,
      persist: async payload => {
        saved.push({ viewId: payload.viewId, chartType: payload.config.chart?.chart_type })
        return { version: 3 }
      }
    })
    const flushB = model.flushChartAutoSave()
    model.select('chart-2')
    model.scheduleChartAutoSave({
      viewId: 'chart-2',
      config: { chart: { chart_type: 'pie' } },
      fallbackVersion: 1,
      persist: async payload => {
        saved.push({ viewId: payload.viewId, chartType: payload.config.chart?.chart_type })
        return { version: 2 }
      }
    })
    gateA.resolve()
    await Promise.all([flushA, flushB])
    await model.flushChartAutoSave()

    expect(saved).toEqual([
      { viewId: 'chart-1', chartType: 'bar' },
      { viewId: 'chart-1', chartType: 'line' },
      { viewId: 'chart-2', chartType: 'pie' }
    ])
  } finally {
    model[Symbol.dispose]()
  }
})

test('switching across three views while the first save is in flight retains every flushed view save and drains queued work on dispose', async () => {
  const model = new TableWorkspaceModel({ autoSaveDelayMs: 500 })
  model.load('chart-1')
  model.observeViewVersions([
    { id: 'chart-1', version: 1 },
    { id: 'chart-2', version: 1 },
    { id: 'chart-3', version: 1 }
  ])
  const gate = Promise.withResolvers<void>()
  const saved: Array<{ viewId: string; chartType: string | undefined }> = []

  model.scheduleChartAutoSave({
    viewId: 'chart-1',
    config: { chart: { chart_type: 'bar' } },
    fallbackVersion: 1,
    persist: async payload => {
      saved.push({ viewId: payload.viewId, chartType: payload.config.chart?.chart_type })
      await gate.promise
      return { version: 2 }
    }
  })
  const flush1 = model.flushChartAutoSave()
  await Bun.sleep(5)

  model.scheduleChartAutoSave({
    viewId: 'chart-1',
    config: { chart: { chart_type: 'line' } },
    fallbackVersion: 1,
    persist: async payload => {
      saved.push({ viewId: payload.viewId, chartType: payload.config.chart?.chart_type })
      return { version: 3 }
    }
  })
  const flush2 = model.flushChartAutoSave()
  model.select('chart-2')

  model.scheduleChartAutoSave({
    viewId: 'chart-2',
    config: { chart: { chart_type: 'pie' } },
    fallbackVersion: 1,
    persist: async payload => {
      saved.push({ viewId: payload.viewId, chartType: payload.config.chart?.chart_type })
      return { version: 2 }
    }
  })
  const flush3 = model.flushChartAutoSave()
  model.select('chart-3')

  model.scheduleChartAutoSave({
    viewId: 'chart-3',
    config: { chart: { chart_type: 'area' } },
    fallbackVersion: 1,
    persist: async payload => {
      saved.push({ viewId: payload.viewId, chartType: payload.config.chart?.chart_type })
      return { version: 2 }
    }
  })

  // Unmount/dispose while chart-1:bar is still in flight and chart-1:line, chart-2:pie, chart-3:area are queued.
  model[Symbol.dispose]()
  gate.resolve()
  await Promise.all([flush1, flush2, flush3, model.flushChartAutoSave()])

  expect(saved).toEqual([
    { viewId: 'chart-1', chartType: 'bar' },
    { viewId: 'chart-1', chartType: 'line' },
    { viewId: 'chart-2', chartType: 'pie' },
    { viewId: 'chart-3', chartType: 'area' }
  ])
})

test('ending an unchanged or cancelled cell edit releases its stale baseline', async () => {
  const model = new BaseCellModel()
  model.begin({ price: 1 })
  model.end()
  model.begin({ price: 2 })
  await model.save('price', 12, { price: 3 }, async (_value, versions) => {
    expect(versions).toEqual({ price: 2 })
  })
})

test('renaming an existing link preserves default multiple semantics and its reverse pairing', () => {
  const model = new FieldEditorModel()
  const link: BaseField = { ...field, type: 'link', config: { table_id: 'target', reverse_field_id: 'reverse' } }
  model.load(link)
  model.setName('Renamed relation')
  expect(model.multiple.value).toBe(true)
  expect(model.bidirectional.value).toBe(true)
  expect(model.changesValues.value).toBe(false)
  expect(model.config.value).toBe(link.config)
  model.setMultiple(false)
  expect(model.changesValues.value).toBe(true)
  expect(model.config.value).toMatchObject({
    table_id: 'target',
    reverse_field_id: 'reverse',
    multiple: false,
    bidirectional: true
  })
})

test('display-field state and empty-column detection skip confirmation when no stored values exist', () => {
  const primaryField: BaseField = { ...field, id: 'title', name: 'Category', type: 'text', is_primary: true }
  const formulaField: BaseField = {
    ...field,
    id: 'total',
    name: 'Total',
    type: 'formula',
    config: { source: '[Price] * 2', result_type: 'number' }
  }
  const model = new FieldEditorModel()
  model.load(primaryField)
  expect(model.isPrimary.value).toBe(true)
  model.load(field)
  expect(model.isPrimary.value).toBe(false)
  model.setIsPrimary(true)
  expect(model.isPrimary.value).toBe(true)
  expect(model.changesValues.value).toBe(false)

  expect(fieldHasStoredValues(undefined, 10, 5)).toBe(false)
  expect(fieldHasStoredValues(primaryField, 0, undefined)).toBe(false)
  expect(fieldHasStoredValues(formulaField, 50, undefined)).toBe(false)
  expect(fieldHasStoredValues(field, 12, 0)).toBe(false)
  expect(fieldHasStoredValues(field, 12, 3)).toBe(true)
  expect(fieldHasStoredValues(field, 12, undefined)).toBe(true)
})

test('grid views allow hiding the display field while keeping at least one visible column', () => {
  const primaryField: BaseField = { ...field, id: 'title', name: 'Title', type: 'text', is_primary: true }
  const gridHiddenPrimary = sanitizeViewConfig({ visible_fields: ['price'] }, [primaryField, field], 'grid')
  expect(gridHiddenPrimary.visible_fields).toEqual(['price'])

  const gridDefaultType = sanitizeViewConfig({ visible_fields: ['price'] }, [primaryField, field])
  expect(gridDefaultType.visible_fields).toEqual(['price'])

  const gridFallback = sanitizeViewConfig({ visible_fields: ['deleted'] }, [primaryField, field], 'grid')
  expect(gridFallback.visible_fields).toEqual(['title'])

  const kanbanConfig = sanitizeViewConfig({ visible_fields: ['price'] }, [primaryField, field], 'kanban')
  expect(kanbanConfig.visible_fields).toEqual(['title', 'price'])

  expect(resolveVisibleFields([primaryField, field], undefined, 'grid').map(item => item.id)).toEqual([
    'title',
    'price'
  ])
  expect(resolveVisibleFields([primaryField, field], ['price'], 'kanban').map(item => item.id)).toEqual([
    'title',
    'price'
  ])
})

test('formatRecordLabel and RecordTitle format non-text display fields safely and fall back to short IDs when empty', () => {
  const selectPrimary: BaseField = {
    id: 'cat',
    name: 'Category',
    description: '',
    type: 'select',
    config: { options: [{ id: 'hw', name: 'Hardware' }] },
    version: 1,
    is_primary: true
  }
  const ownerPrimary: BaseField = {
    id: 'owner',
    name: 'Owner',
    description: '',
    type: 'user',
    config: {},
    version: 1,
    is_primary: true
  }
  const formulaPrimary: BaseField = {
    id: 'label',
    name: 'Label',
    description: '',
    type: 'formula',
    config: { source: '""', result_type: 'text' },
    version: 1,
    is_primary: true
  }
  const attachmentPrimary: BaseField = {
    id: 'files',
    name: 'Files',
    description: '',
    type: 'attachment',
    config: {},
    version: 1,
    is_primary: true
  }
  const record: BaseRecord = {
    id: '019a2b00-0000-7000-8000-000000abcdef',
    data: {
      cat: 'hw',
      owner: ['alice'],
      label: '',
      files: [{ path: 'pages/page-1/attachments/spec.pdf', name: 'spec.pdf' }]
    },
    versions: { cat: 1, owner: 1 },
    created_by: 'alice',
    updated_by: 'alice',
    created_at: '2026-11-09T00:00:00Z',
    updated_at: '2026-11-09T00:00:00Z'
  }
  expect(formatRecordLabel(record, selectPrimary)).toBe('Hardware')
  expect(formatRecordLabel(record, ownerPrimary, [{ principal_uid: 'alice', name: 'Alice Chen' }])).toBe('Alice Chen')
  expect(formatRecordLabel({ ...record, data: {} }, selectPrimary)).toBe('#abcdef')
  expect(formatRecordLabel(record, formulaPrimary)).toBe('#abcdef')

  const queryClient = new QueryClient()
  const attachmentTitleHtml = renderToStaticMarkup(
    createElement(
      QueryClientProvider,
      { client: queryClient },
      createElement(RecordTitle, { record, primary: attachmentPrimary })
    )
  )
  expect(attachmentTitleHtml).toContain('spec.pdf')
  expect(attachmentTitleHtml).not.toContain('<a')

  const emptyFormulaTitleHtml = renderToStaticMarkup(
    createElement(
      QueryClientProvider,
      { client: queryClient },
      createElement(RecordTitle, { record, primary: formulaPrimary })
    )
  )
  expect(emptyFormulaTitleHtml).toBe('#abcdef')
})
