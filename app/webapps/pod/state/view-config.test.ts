import { expect, test } from 'bun:test'
import { isUnconfiguredChartSpec, parseEmbedView, parseViewConfig, type ViewConfig } from './view-config'

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

test('chart view configurations preserve nested AggregateQuery, encoding, display, and scrubbed missing_field_id markers', () => {
  const chartConfig: ViewConfig = {
    type: 'chart',
    chart: {
      chart_type: 'combo',
      query: {
        group_by: [
          { field_id: 'created', bucket: 'month' },
          { field_id: null, missing_field_id: 'deleted-region' }
        ],
        metrics: [
          { operation: 'sum', field_id: 'revenue', alias: 'rev' },
          { operation: 'count_distinct', field_id: 'customer', alias: 'customers' }
        ],
        top_n: { group_index: 1, limit: 5, by: 'rev', direction: 'desc', include_other: true },
        omit_empty: false
      },
      encoding: {
        secondary_metric_aliases: ['customers']
      },
      display: {
        sort_mode: 'option_order',
        stack_mode: 'stacked',
        fill_missing_buckets: true,
        omit_zero: true,
        show_data_labels: true,
        smooth: true,
        show_legend: false,
        height: 'lg',
        reference_lines: [{ value: 100_000, label: 'Target', color: '#10b981' }],
        caption: 'Monthly revenue and active customers'
      }
    }
  }
  expect(parseEmbedView(JSON.stringify(chartConfig))).toEqual({ kind: 'inline', config: chartConfig })
  expect(isUnconfiguredChartSpec({ type: 'chart' })).toBe(true)
  expect(isUnconfiguredChartSpec(chartConfig)).toBe(false)
  expect(parseEmbedView(JSON.stringify({ type: 'chart', chart: { chart_type: 'unknown-3d-pie' } }))).toEqual({
    kind: 'invalid'
  })
})
