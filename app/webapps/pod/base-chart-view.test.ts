import { describe, expect, test } from 'bun:test'
import type { AggregateGroup, BaseField } from '@ankole/applet-sdk/types'
import {
  buildAggregateQueryFromSpec,
  buildChartDataset,
  buildDrilldownGroupSlices,
  canUseCumulative,
  collectMissingChartSlots,
  deriveDefaultChartSpec,
  serializeResolvedToViewConfig
} from './state/chart-view'
import { nextViewName, sanitizeViewConfig } from './base-page'
import { parseViewConfig, resolveChartSpec, type ViewConfig } from './state/view-config'

const operations = {
  count: 'Count',
  count_distinct: 'Count distinct',
  sum: 'Sum',
  avg: 'Average',
  min: 'Min',
  max: 'Max'
}

const textField: BaseField = {
  id: 'f-title',
  name: 'Title',
  description: '',
  type: 'text',
  config: {},
  version: 1,
  is_primary: true
}

const selectField: BaseField = {
  id: 'f-region',
  name: 'Region',
  description: '',
  type: 'select',
  config: {
    options: [
      { id: 'opt-east', name: 'East', color: 'teal' },
      { id: 'opt-west', name: 'West', color: 'blue' },
      { id: 'opt-south', name: 'South' }
    ]
  },
  version: 1,
  is_primary: false
}

const dateField: BaseField = {
  id: 'f-date',
  name: 'Order Date',
  description: '',
  type: 'datetime',
  config: {},
  version: 1,
  is_primary: false
}

const revenueField: BaseField = {
  id: 'f-rev',
  name: 'Revenue',
  description: '',
  type: 'number',
  config: { format: 'currency', currency: 'USD', precision: 2 },
  version: 1,
  is_primary: false
}

describe('deriveDefaultChartSpec', () => {
  test('renders a runnable KPI stat count on an empty schema without blank state', () => {
    const resolved = deriveDefaultChartSpec([])
    expect(resolved.chartType).toBe('stat')
    expect(resolved.groupBy).toEqual([])
    expect(resolved.metrics).toEqual([{ operation: 'count', alias: 'count' }])
  })

  test('defaults to column count with Top 10 + Other on text-only tables', () => {
    const resolved = deriveDefaultChartSpec([textField])
    expect(resolved.chartType).toBe('column')
    expect(resolved.groupBy).toEqual([{ field_id: 'f-title' }])
    expect(resolved.metrics).toEqual([{ operation: 'count', alias: 'count' }])
    expect(resolved.topN?.limit).toBe(10)
    expect(resolved.topN?.include_other).toBe(true)
  })

  test('defaults to monthly line sum on tables with datetime and numeric fields', () => {
    const resolved = deriveDefaultChartSpec([textField, selectField, dateField, revenueField])
    expect(resolved.chartType).toBe('line')
    expect(resolved.groupBy).toEqual([{ field_id: 'f-date', bucket: 'month' }])
    expect(resolved.metrics).toEqual([{ operation: 'sum', field_id: 'f-rev', alias: 'm0' }])
    expect(resolved.topN).toBeNull()
  })
})

describe('missing field preservation & in-place detection', () => {
  test('sanitizeViewConfig keeps deleted chart field references intact for in-place repair', () => {
    const chartCfg: ViewConfig = {
      type: 'chart',
      chart: {
        chart_type: 'column',
        query: {
          group_by: [{ field_id: null, missing_field_id: 'deleted-dim' }],
          metrics: [{ operation: 'sum', field_id: 'deleted-num', alias: 'm0' }]
        }
      }
    }
    const sanitized = sanitizeViewConfig(chartCfg, [textField, revenueField], 'chart')
    expect(sanitized.chart?.query?.group_by?.[0]?.missing_field_id).toBe('deleted-dim')
    expect(sanitized.chart?.query?.metrics?.[0]?.field_id).toBe('deleted-num')

    const resolved = deriveDefaultChartSpec([textField, revenueField], sanitized.chart)
    const missing = collectMissingChartSlots(resolved, [textField, revenueField])
    expect(missing).toEqual([
      { kind: 'group_0', missingFieldId: 'deleted-dim', required: true },
      { kind: 'metric_0', missingFieldId: 'deleted-num', required: true }
    ])
  })
})

describe('buildChartDataset & rank-order colors', () => {
  test('preserves select option colors, ranks Top-N before Other and Empty, and never treats 0 or false as Empty', () => {
    const resolved = deriveDefaultChartSpec([selectField, revenueField], {
      chart_type: 'column',
      query: {
        group_by: [{ field_id: 'f-region' }],
        metrics: [{ operation: 'sum', field_id: 'f-rev', alias: 'm0' }]
      }
    })

    const groups: AggregateGroup[] = [
      {
        values: ['opt-south'],
        value_json: ['"opt-south"'],
        other: [false],
        metrics: { m0: 500 },
        metrics_text: { m0: '500.00' }
      },
      {
        values: ['opt-east'],
        value_json: ['"opt-east"'],
        other: [false],
        metrics: { m0: 1200 },
        metrics_text: { m0: '1200.00' }
      },
      {
        // PostgreSQL key-folding returns null value + other=[true] for the folded tail
        values: [null],
        value_json: ['null'],
        other: [true],
        metrics: { m0: 900 },
        metrics_text: { m0: '900.00' }
      },
      {
        // Independent Empty bucket has null value + other=[false]
        values: [null],
        value_json: ['null'],
        other: [false],
        metrics: { m0: 2000 },
        metrics_text: { m0: '2000.00' }
      }
    ]

    const dataset = buildChartDataset(groups, resolved, [selectField, revenueField], {
      empty: 'Empty',
      other: 'Other',
      categoryFallback: 'All',
      operations
    })

    expect(dataset.rows.map(r => r.x)).toEqual(['South', 'East', 'Other', 'Empty'])
    // Ranked: non-other/non-empty by total desc (East=1200, South=500), then Other, then Empty!
    expect(dataset.seriesMeta).toEqual([
      { key: 'East', isEmpty: false, isOther: false, optionColor: 'teal' },
      { key: 'South', isEmpty: false, isOther: false, optionColor: undefined },
      { key: 'Other', isEmpty: false, isOther: true, optionColor: undefined },
      { key: 'Empty', isEmpty: true, isOther: false, optionColor: undefined }
    ])
    expect(dataset.summaryTable.rows[1]).toEqual(['East', '$1,200.00'])
  })

  test('densifies missing monthly buckets and accumulates running totals only for sum/count', () => {
    expect(canUseCumulative([{ operation: 'sum' }])).toBe(true)
    expect(canUseCumulative([{ operation: 'count' }])).toBe(true)
    expect(canUseCumulative([{ operation: 'avg' }])).toBe(false)
    expect(canUseCumulative([{ operation: 'count_distinct' }])).toBe(false)

    const resolved = deriveDefaultChartSpec([dateField, revenueField], {
      chart_type: 'line',
      query: {
        group_by: [{ field_id: 'f-date', bucket: 'month' }],
        metrics: [{ operation: 'sum', field_id: 'f-rev', alias: 'm0' }]
      },
      display: {
        fill_missing_buckets: true,
        cumulative: true
      }
    })

    const sparse: AggregateGroup[] = [
      {
        values: ['2026-01'],
        value_json: ['"2026-01"'],
        other: [false],
        metrics: { m0: 100 },
        metrics_text: { m0: '100' }
      },
      {
        values: ['2026-03'],
        value_json: ['"2026-03"'],
        other: [false],
        metrics: { m0: 50 },
        metrics_text: { m0: '50' }
      }
    ]

    const dataset = buildChartDataset(sparse, resolved, [dateField, revenueField], {
      empty: 'Empty',
      other: 'Other',
      categoryFallback: 'All',
      operations
    })

    expect(dataset.rows.map(r => ({ x: r.x, y: r.y }))).toEqual([
      { x: '2026-01', y: 100 },
      { x: '2026-02', y: 100 },
      { x: '2026-03', y: 150 }
    ])
    expect(dataset.firstChronologicalBucketJson).toBe('"2026-01"')
  })
})

describe('buildDrilldownGroupSlices & buildAggregateQueryFromSpec', () => {
  test('constructs exact 2D, cumulative, Empty, and Other exclusion GroupSlice[]', () => {
    const groupBy = [{ field_id: 'f-date', bucket: 'month' as const }, { field_id: 'f-region' }]
    const allGroups: AggregateGroup[] = [
      {
        values: ['2026-01', 'opt-east'],
        value_json: ['"2026-01"', '"opt-east"'],
        other: [false, false],
        metrics: { m0: 100 }
      },
      {
        values: ['2026-02', 'opt-west'],
        value_json: ['"2026-02"', '"opt-west"'],
        other: [false, false],
        metrics: { m0: 80 }
      },
      {
        values: ['2026-02', null],
        value_json: ['"2026-02"', 'null'],
        other: [false, true],
        metrics: { m0: 25 }
      },
      {
        values: ['2026-02', null],
        value_json: ['"2026-02"', 'null'],
        other: [false, false],
        metrics: { m0: 10 }
      }
    ]

    // 1. Cumulative through period on 2D Other slice
    const otherSlices = buildDrilldownGroupSlices({
      clickedGroup: allGroups[2]!,
      allGroups,
      groupBy,
      periodMode: 'through_period',
      firstChronologicalBucketJson: '"2026-01"'
    })
    expect(otherSlices).toEqual([
      {
        field_id: 'f-date',
        bucket: 'month',
        value_json: '"2026-02"',
        cumulative_from_json: '"2026-01"'
      },
      {
        field_id: 'f-region',
        other_exclude_values_json: ['"opt-east"', '"opt-west"']
      }
    ])

    // 2. Single period on Empty slice
    const emptySlices = buildDrilldownGroupSlices({
      clickedGroup: allGroups[3]!,
      allGroups,
      groupBy,
      periodMode: 'single_period',
      firstChronologicalBucketJson: '"2026-01"'
    })
    expect(emptySlices).toEqual([
      { field_id: 'f-date', bucket: 'month', value_json: '"2026-02"' },
      { field_id: 'f-region', value: null }
    ])
  })

  test('orders 2D time+category aggregate queries chronologically first, then by ranking metric', () => {
    const resolved = deriveDefaultChartSpec([dateField, selectField, revenueField], {
      chart_type: 'column',
      query: {
        group_by: [{ field_id: 'f-date', bucket: 'month' }, { field_id: 'f-region' }],
        metrics: [{ operation: 'sum', field_id: 'f-rev', alias: 'm0' }],
        top_n: { limit: 5, by: 'm0', direction: 'desc', include_other: true }
      }
    })
    const query = buildAggregateQueryFromSpec(resolved, [dateField, selectField, revenueField], undefined)
    expect(query.order_by).toEqual([
      { group_index: 0, direction: 'asc' },
      { metric_alias: 'm0', direction: 'desc' }
    ])
    expect(query.top_n).toEqual({
      limit: 5,
      include_other: true,
      target_group_index: 1
    })
  })
})

describe('Notion-parity UX contracts: naming, lossless display serialization, sorting, omit_zero & donut total', () => {
  test('nextViewName generates non-colliding sequential view names', () => {
    expect(nextViewName([], 'Chart')).toBe('Chart')
    expect(nextViewName([{ name: 'Chart' }], 'Chart')).toBe('Chart 2')
    expect(nextViewName([{ name: 'Chart' }, { name: 'Chart 2' }], 'Chart')).toBe('Chart 3')
    expect(nextViewName([{ name: 'Monthly Revenue' }], 'Monthly Revenue')).toBe('Monthly Revenue 2')
  })

  test('serializeResolvedToViewConfig preserves 100% of display settings without loss across edits', () => {
    const initial: ViewConfig = {
      type: 'chart',
      filter: { conjunction: 'and', conditions: [{ field_id: 'f-region', operator: 'is_not_empty' }] },
      chart: {
        chart_type: 'line',
        query: {
          group_by: [{ field_id: 'f-date', bucket: 'month' }],
          metrics: [{ operation: 'sum', field_id: 'f-rev', alias: 'm0' }]
        },
        display: {
          sort_mode: 'key_asc',
          stack_mode: 'stacked',
          cumulative: true,
          fill_missing_buckets: true,
          omit_zero: true,
          show_data_labels: true,
          smooth: true,
          show_legend: false,
          height: 'xl',
          reference_lines: [{ value: 50_000, label: 'Quota', color: '#10b981' }],
          caption: 'Q4 target trajectory'
        }
      }
    }

    const resolved = deriveDefaultChartSpec([dateField, selectField, revenueField], resolveChartSpec(initial))
    // Simulate changing time bucket in capsule bar
    const serialized = serializeResolvedToViewConfig(initial, {
      ...resolved,
      groupBy: [{ field_id: 'f-date', bucket: 'quarter' }]
    })
    const parsed = parseViewConfig(serialized)
    expect(parsed.success).toBe(true)
    if (!parsed.success) return

    expect(parsed.data.filter).toEqual(initial.filter)
    expect(parsed.data.chart?.query?.group_by).toEqual([{ field_id: 'f-date', bucket: 'quarter' }])
    expect(parsed.data.chart?.display).toEqual({
      sort_mode: 'key_asc',
      stack_mode: 'stacked',
      cumulative: true,
      fill_missing_buckets: true,
      omit_zero: true,
      show_data_labels: true,
      smooth: true,
      show_legend: false,
      height: 'xl',
      reference_lines: [{ value: 50_000, label: 'Quota', color: '#10b981' }],
      caption: 'Q4 target trajectory'
    })
  })

  test('funnel on :select defaults to option_order and sorts groups in schema option order while keeping drilldown index aligned', () => {
    const resolved = deriveDefaultChartSpec([selectField, revenueField], {
      chart_type: 'funnel',
      query: {
        group_by: [{ field_id: 'f-region' }],
        metrics: [{ operation: 'sum', field_id: 'f-rev', alias: 'm0' }]
      }
    })
    expect(resolved.sortMode).toBe('option_order')

    // Raw groups arrive out of option order (South, Empty, West, Other, East)
    const groups: AggregateGroup[] = [
      {
        values: ['opt-south'],
        value_json: ['"opt-south"'],
        other: [false],
        metrics: { m0: 900 },
        metrics_text: { m0: '900' }
      },
      { values: [null], value_json: ['null'], other: [false], metrics: { m0: 50 }, metrics_text: { m0: '50' } },
      {
        values: ['opt-west'],
        value_json: ['"opt-west"'],
        other: [false],
        metrics: { m0: 300 },
        metrics_text: { m0: '300' }
      },
      { values: [null], value_json: ['null'], other: [true], metrics: { m0: 120 }, metrics_text: { m0: '120' } },
      {
        values: ['opt-east'],
        value_json: ['"opt-east"'],
        other: [false],
        metrics: { m0: 600 },
        metrics_text: { m0: '600' }
      }
    ]

    const dataset = buildChartDataset(groups, resolved, [selectField, revenueField], {
      empty: 'Empty',
      other: 'Other',
      categoryFallback: 'All',
      operations
    })

    // Schema order is East -> West -> South, followed by Other, followed by Empty
    expect(dataset.rows.map(r => r.x)).toEqual(['East', 'West', 'South', 'Other', 'Empty'])
    expect(dataset.rows.map(r => r.__formattedY)).toEqual(['$600.00', '$300.00', '$900.00', '$120.00', '$50.00'])
    // Verify __groupIndex maps 1:1 to dataset.processedGroups for click-to-drill-down
    dataset.rows.forEach(row => {
      const idx = row.__groupIndex as number
      expect(dataset.processedGroups[idx]).toBeDefined()
    })
    expect(dataset.processedGroups[0]?.values[0]).toBe('opt-east')
    expect(dataset.processedGroups[3]?.other?.[0]).toBe(true)
    expect(dataset.processedGroups[4]?.values[0]).toBeNull()
  })

  test('omit_zero skips synthetic zero-fill and removes zero-valued buckets while computing donut center total on scalar fields', () => {
    const donutResolved = deriveDefaultChartSpec([selectField, revenueField], {
      chart_type: 'donut',
      query: {
        group_by: [{ field_id: 'f-region' }],
        metrics: [{ operation: 'sum', field_id: 'f-rev', alias: 'm0' }]
      },
      display: {
        omit_zero: true
      }
    })

    const groups: AggregateGroup[] = [
      {
        values: ['opt-east'],
        value_json: ['"opt-east"'],
        other: [false],
        metrics: { m0: 1200 },
        metrics_text: { m0: '1200' }
      },
      {
        values: ['opt-west'],
        value_json: ['"opt-west"'],
        other: [false],
        metrics: { m0: 0 },
        metrics_text: { m0: '0' }
      },
      {
        values: ['opt-south'],
        value_json: ['"opt-south"'],
        other: [false],
        metrics: { m0: 500 },
        metrics_text: { m0: '500' }
      }
    ]

    const dataset = buildChartDataset(groups, donutResolved, [selectField, revenueField], {
      empty: 'Empty',
      other: 'Other',
      categoryFallback: 'All',
      operations
    })

    expect(dataset.rows.map(r => r.x)).toEqual(['East', 'South'])
    expect(dataset.donutCenterLabel).toEqual({
      value: '$1,700.00',
      title: 'Sum · Revenue'
    })

    // Multi-select (:array) donut omits center total to avoid double-counting overlapping memberships
    const multiSelectField: BaseField = {
      ...selectField,
      config: { ...selectField.config, multiple: true }
    }
    const multiDataset = buildChartDataset(groups, donutResolved, [multiSelectField, revenueField], {
      empty: 'Empty',
      other: 'Other',
      categoryFallback: 'All',
      operations
    })
    expect(multiDataset.donutCenterLabel).toBeUndefined()
  })
})

describe('exact chart totals', () => {
  const labels = { empty: 'Empty', other: 'Other', categoryFallback: 'All', operations }
  const groups: AggregateGroup[] = [
    { values: ['2026-03'], metrics: { m0: 0.02 }, metrics_text: { m0: '0.02' } },
    { values: ['2026-01'], metrics: { m0: 9007199254740992 }, metrics_text: { m0: '9007199254740992.01' } }
  ]

  test('accumulates by period independently of display order and zero filling, preserving exact amounts', () => {
    for (const fillMissing of [false, true]) {
      const resolved = deriveDefaultChartSpec([dateField, revenueField], {
        chart_type: 'line',
        query: {
          group_by: [{ field_id: dateField.id, bucket: 'month' }],
          metrics: [{ operation: 'sum', field_id: revenueField.id, alias: 'm0' }]
        },
        display: { sort_mode: 'key_desc', cumulative: true, fill_missing_buckets: fillMissing }
      })
      const dataset = buildChartDataset(groups, resolved, [dateField, revenueField], labels)
      const byPeriod = new Map(dataset.processedGroups.map(group => [group.values[0], group.metrics_text?.m0]))
      expect(byPeriod.get('2026-01')).toBe('9007199254740992.01')
      expect(byPeriod.get('2026-03')).toBe('9007199254740992.03')
      expect(dataset.firstChronologicalBucketJson).toBe('"2026-01"')
      expect(dataset.rows[0]?.x).toBe('2026-03')
    }
  })

  test('shows an exact donut total rather than summing rounded drawing coordinates', () => {
    const resolved = deriveDefaultChartSpec([textField, revenueField], {
      chart_type: 'donut',
      query: {
        group_by: [{ field_id: textField.id }],
        metrics: [{ operation: 'sum', field_id: revenueField.id, alias: 'm0' }]
      }
    })
    const dataset = buildChartDataset(groups, resolved, [textField, revenueField], labels)
    expect(dataset.donutCenterLabel?.value).toBe('$9,007,199,254,740,992.03')
  })
})
