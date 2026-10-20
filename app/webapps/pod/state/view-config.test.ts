import { expect, test } from 'bun:test'
import { parseEmbedView, parseViewConfig, type ViewConfig } from './view-config'

test('persisted inline configurations reject malformed domain shapes before a renderer consumes them', () => {
  for (const config of [
    { type: 'calendar' },
    { type: 'grid', visible_fields: {} },
    { type: 'grid', group_field_id: [] },
    { type: 'gallery', cover_field_id: [] },
    { type: 'grid', filter: { conjunction: 'or', conditions: {} } },
    { type: 'grid', sort: [{ field_id: 'name', direction: 'sideways' }] },
    { type: 'missing' },
    []
  ]) {
    expect(parseEmbedView(JSON.stringify(config))).toEqual({ kind: 'invalid' })
  }
  expect(parseEmbedView('{broken')).toEqual({ kind: 'invalid' })
})

test('saved references and inline settings retain their distinct meaning and all supported settings', () => {
  expect(parseEmbedView('view-id')).toEqual({ kind: 'saved', id: 'view-id' })
  expect(parseEmbedView()).toEqual({ kind: 'saved' })
  const config: ViewConfig = {
    type: 'kanban',
    group_field_id: 'status',
    visible_fields: ['name'],
    filter: {
      conjunction: 'or',
      conditions: [
        { field_id: 'name', operator: 'is', value: 'A' },
        { field_id: 'name', operator: 'is', value: 'B' }
      ]
    },
    sort: [{ field_id: 'name', direction: 'asc' }]
  }
  expect(parseEmbedView(`  ${JSON.stringify(config)}`)).toEqual({ kind: 'inline', config })
  expect(parseViewConfig(config).success).toBe(true)
  expect(parseEmbedView(JSON.stringify({ type: 'grid' }))).toEqual({ kind: 'inline', config: { type: 'grid' } })
})
