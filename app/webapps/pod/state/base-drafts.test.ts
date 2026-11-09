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

test('a shared view draft preserves its captured version; changing view resets pagination and draft', () => {
  const model = new TableWorkspaceModel()
  model.load('grid')
  model.configure({ sort: [] }, 1)
  model.configure({ visible_fields: ['price'] }, 2)
  expect(model.draft.value?.version).toBe(1)
  model.next('cursor-1')
  model.next('cursor-2')
  model.previous()
  expect(model.pageToken.value).toBe('cursor-1')
  model.select('gallery')
  expect(model.draft.value).toBeUndefined()
  expect(model.history.value).toEqual([])
  expect(model.pageToken.value).toBeUndefined()
  expect(model.viewID.value).toBe('gallery')
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
