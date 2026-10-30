import { formatFileBytes } from '../../common/file-format'
import { expect, test } from 'bun:test'
import {
  PageSubpagesModel,
  fileExtensionBadge,
  isDocumentBodyEmpty,
  normalizeChildrenView,
  sortSubpages
} from './page-subpages'

test('normalizeChildrenView applies Feishu-style defaults and repairs partial metadata', () => {
  expect(normalizeChildrenView()).toEqual({
    collapsed: false,
    view: 'list',
    fieldOrder: ['created_by', 'updated_at', 'created_at'],
    visibleFields: ['created_by', 'updated_at']
  })

  expect(
    normalizeChildrenView({
      collapsed: true,
      view: 'grid',
      field_order: ['created_at', 'created_by'],
      visible_fields: ['created_at', 'unknown', 'created_by']
    })
  ).toEqual({
    collapsed: true,
    view: 'grid',
    fieldOrder: ['created_at', 'created_by', 'updated_at'],
    visibleFields: ['created_at', 'created_by']
  })
})

test('editors persist presentation patches while read-only viewers stay local to the session', () => {
  const patches: unknown[] = []
  const model = new PageSubpagesModel({})

  model.toggleCollapsed(false, patch => patches.push(patch))
  model.setView('grid', false, patch => patches.push(patch))
  expect(model.collapsed.value).toBe(true)
  expect(model.view.value).toBe('grid')
  expect(patches).toHaveLength(0)

  // Re-rendering with unchanged server metadata preserves the viewer's session override.
  model.syncFromServer({})
  expect(model.collapsed.value).toBe(true)

  // Once editing is granted, changes emit clean server patches and clear stale session overrides.
  model.setView('list', true, patch => patches.push(patch))
  expect(patches).toEqual([{ view: 'list' }])
  expect(model.collapsed.value).toBe(false)

  model.toggleField('created_at', true, patch => patches.push(patch))
  expect(model.visibleFields.value).toEqual(['created_by', 'updated_at', 'created_at'])
  expect(patches.at(-1)).toEqual({ visible_fields: ['created_by', 'updated_at', 'created_at'] })

  // Hiding a field preserves its slot inside fieldOrder so re-enabling restores its column position.
  model.stepField('created_at', -1, true, patch => patches.push(patch))
  expect(model.fieldOrder.value).toEqual(['created_by', 'created_at', 'updated_at'])
  model.toggleField('created_at', true, patch => patches.push(patch))
  expect(model.visibleFields.value).toEqual(['created_by', 'updated_at'])
  expect(model.fieldOrder.value).toEqual(['created_by', 'created_at', 'updated_at'])
  model.toggleField('created_at', true, patch => patches.push(patch))
  expect(model.visibleFields.value).toEqual(['created_by', 'created_at', 'updated_at'])
})

test('cycleSort cycles asc -> desc -> tree order and sortSubpages orders titles and timestamps', () => {
  const model = new PageSubpagesModel({})
  expect(model.sort.value).toBeNull()
  model.cycleSort('title')
  expect(model.sort.value).toEqual({ field: 'title', direction: 'asc' })
  model.cycleSort('title')
  expect(model.sort.value).toEqual({ field: 'title', direction: 'desc' })
  model.cycleSort('title')
  expect(model.sort.value).toBeNull()

  const pages = [
    {
      id: 'p1',
      title: ' Chapter 10 ',
      position: 'a0',
      created_at: '2026-10-01T10:00:00Z',
      updated_at: '2026-10-03T10:00:00Z'
    },
    {
      id: 'p2',
      title: 'Chapter 2',
      position: 'a1',
      created_at: '2026-10-02T10:00:00Z',
      updated_at: '2026-10-01T10:00:00Z'
    },
    {
      id: 'p3',
      title: '',
      position: 'a2',
      created_at: null,
      updated_at: '2026-10-02T10:00:00Z'
    }
  ]

  expect(sortSubpages(pages, null, 'Untitled').map(p => p.id)).toEqual(['p1', 'p2', 'p3'])
  expect(sortSubpages(pages, { field: 'title', direction: 'asc' }, 'Untitled').map(p => p.id)).toEqual([
    'p2',
    'p1',
    'p3'
  ])
  expect(sortSubpages(pages, { field: 'updated_at', direction: 'desc' }, 'Untitled').map(p => p.id)).toEqual([
    'p1',
    'p3',
    'p2'
  ])
  // Missing timestamps stay at the tail regardless of sort direction.
  expect(sortSubpages(pages, { field: 'created_at', direction: 'asc' }, 'Untitled').map(p => p.id)).toEqual([
    'p1',
    'p2',
    'p3'
  ])
  expect(sortSubpages(pages, { field: 'created_at', direction: 'desc' }, 'Untitled').map(p => p.id)).toEqual([
    'p2',
    'p1',
    'p3'
  ])
})

test('formatFileBytes and fileExtensionBadge format Grid file card metadata cleanly', () => {
  expect(formatFileBytes(0)).toBe('0 B')
  expect(formatFileBytes(512)).toBe('512 B')
  expect(formatFileBytes(1536)).toBe('1.5 KB')
  expect(formatFileBytes(2.5 * 1024 * 1024)).toBe('2.5 MB')
  expect(fileExtensionBadge('architecture-v2.pdf', 'application/pdf')).toBe('PDF')
  expect(fileExtensionBadge('README', 'text/markdown; charset=utf-8')).toBe('MARKDOWN')
  expect(fileExtensionBadge('', null)).toBe('FILE')
})

test('isDocumentBodyEmpty detects blank documents while preserving non-empty blocks and text', () => {
  expect(isDocumentBodyEmpty('<page/>')).toBe(true)
  expect(isDocumentBodyEmpty('<page><p/></page>')).toBe(true)
  expect(isDocumentBodyEmpty('<page><p></p><p/></page>')).toBe(true)
  expect(isDocumentBodyEmpty('<page><p>Intro</p></page>')).toBe(false)
  expect(isDocumentBodyEmpty('<page><p indent="1"/></page>')).toBe(false)
  expect(isDocumentBodyEmpty('<page><h1/></page>')).toBe(false)
  expect(isDocumentBodyEmpty('<page><hr/></page>')).toBe(false)
})
