import { describe, expect, test } from 'bun:test'
import {
  densifyTimeBuckets,
  formatMetricValue,
  recordsToFinancialSeries,
  type AggregateGroup,
  type BaseField,
  type BaseRecord,
  type Metric,
  type RecordData
} from '../src/index'

function makeRecord(id: string, data: RecordData): BaseRecord {
  return {
    id,
    data,
    versions: {},
    created_at: '2026-11-05T00:00:00Z',
    updated_at: '2026-11-05T00:00:00Z',
    created_by: 'u_test',
    updated_by: 'u_test'
  }
}

describe('recordsToFinancialSeries', () => {
  test('extracts OHLC + volume for business_day in ascending order while counting invalid rows', () => {
    const records = [
      makeRecord('r2', { date: '2026-03-04', o: 102, h: 108, l: 101, c: 107, vol: 2400 }),
      makeRecord('r1', { date: '2026-03-03', o: '100.5', h: '104', l: '99.5', c: '102', vol: '1800' }),
      makeRecord('bad_date', { date: '2026-02-30', o: 100, h: 101, l: 99, c: 100 }),
      makeRecord('missing_ohlc', { date: '2026-03-05', o: 107, h: null, l: 105, c: 106 })
    ]

    const res = recordsToFinancialSeries(records, {
      timeField: 'date',
      timeUnit: 'business_day',
      openField: 'o',
      highField: 'h',
      lowField: 'l',
      closeField: 'c',
      volumeField: 'vol'
    })

    expect(res.skippedCount).toBe(2)
    expect(res.bars).toEqual([
      { time: '2026-03-03', open: 100.5, high: 104, low: 99.5, close: 102 },
      { time: '2026-03-04', open: 102, high: 108, low: 101, close: 107 }
    ])
    expect(res.volume).toEqual([
      { time: '2026-03-03', value: 1800 },
      { time: '2026-03-04', value: 2400 }
    ])
  })

  test('converts ISO-8601 strings and >= 1e11 millisecond numbers to integer UTC unix_seconds', () => {
    const records = [
      makeRecord('ms', { ts: 1767225660000, price: 51.25 }), // 1767225660s
      makeRecord('sec', { ts: 1767225600, price: 50.5 }), // 1767225600s
      makeRecord('iso', { ts: '2026-01-01T00:02:00Z', price: 52.0 }) // 1767225720s
    ]

    const res = recordsToFinancialSeries(records, {
      timeField: 'ts',
      timeUnit: 'unix_seconds',
      valueField: 'price'
    })

    expect(res.skippedCount).toBe(0)
    expect(res.bars).toEqual([
      { time: 1767225600, value: 50.5 },
      { time: 1767225660, value: 51.25 },
      { time: 1767225720, value: 52.0 }
    ])
  })

  test('throws on duplicate timestamps by default (`error`) and keeps latest entry when `onDuplicateTime: "last"`', () => {
    const dupRecords = [
      makeRecord('a', { date: '2026-04-01', close: 10, vol: 100 }),
      makeRecord('b', { date: '2026-04-01', close: 12.5, vol: 250 })
    ]

    expect(() =>
      recordsToFinancialSeries(dupRecords, {
        timeField: 'date',
        timeUnit: 'business_day',
        valueField: 'close'
      })
    ).toThrow(/Duplicate financial series timestamp: 2026-04-01/)

    const deduped = recordsToFinancialSeries(dupRecords, {
      timeField: 'date',
      timeUnit: 'business_day',
      valueField: 'close',
      volumeField: 'vol',
      onDuplicateTime: 'last'
    })
    expect(deduped.bars).toEqual([{ time: '2026-04-01', value: 12.5 }])
    expect(deduped.volume).toEqual([{ time: '2026-04-01', value: 250 }])
  })
})

describe('densifyTimeBuckets', () => {
  const metrics: Metric[] = [
    { alias: 'rows', operation: 'count' },
    { alias: 'revenue', operation: 'sum', field_id: 'f_rev' },
    { alias: 'avg_deal', operation: 'avg', field_id: 'f_rev' },
    { alias: 'unique_customers', operation: 'count_distinct', field_id: 'f_cust' }
  ]

  test('densifies day, Monday-aligned week, month, quarter, and year buckets with 0 for count/sum and null for avg/count_distinct', () => {
    // 1. Day (leap boundary check or month rollover)
    const dayGroups: AggregateGroup[] = [
      { values: ['2026-01-30'], metrics: { rows: 2, revenue: 200, avg_deal: 100, unique_customers: 2 } },
      { values: ['2026-02-01'], metrics: { rows: 1, revenue: 50, avg_deal: 50, unique_customers: 1 } },
      { values: [null], metrics: { rows: 3, revenue: 0, avg_deal: null, unique_customers: 1 } },
      { values: ['Other'], other: [true], metrics: { rows: 4, revenue: 90, avg_deal: 22.5, unique_customers: 4 } }
    ]
    const denseDays = densifyTimeBuckets(dayGroups, { bucket: 'day', metrics })
    expect(denseDays.map(g => g.values[0])).toEqual(['2026-01-30', '2026-01-31', '2026-02-01', null, 'Other'])
    expect(denseDays[1]?.metrics).toEqual({
      rows: 0,
      revenue: 0,
      avg_deal: null,
      unique_customers: null
    })
    expect(denseDays[1]?.metrics_text).toEqual({
      rows: '0',
      revenue: '0',
      avg_deal: null,
      unique_customers: null
    })

    // 2. Week (Monday-aligned: 2026-01-05 is Monday, 2026-01-12 is missing Monday, 2026-01-19 is Monday)
    const weekGroups: AggregateGroup[] = [
      { values: ['2026-01-07'], metrics: { rows: 5, revenue: 500, avg_deal: 100, unique_customers: 4 } }, // Wednesday -> aligns to Monday 2026-01-05
      { values: ['2026-01-19'], metrics: { rows: 2, revenue: 120, avg_deal: 60, unique_customers: 2 } }
    ]
    const denseWeeks = densifyTimeBuckets(weekGroups, { bucket: 'week', metrics })
    expect(denseWeeks.map(g => g.values[0])).toEqual(['2026-01-05', '2026-01-12', '2026-01-19'])
    expect(new Date('2026-01-12T00:00:00Z').getUTCDay()).toBe(1) // Monday = 1

    // 3. Month (across year boundary)
    const monthGroups: AggregateGroup[] = [
      { values: ['2025-11'], metrics: { rows: 1, revenue: 10, avg_deal: 10, unique_customers: 1 } },
      { values: ['2026-02'], metrics: { rows: 2, revenue: 30, avg_deal: 15, unique_customers: 2 } }
    ]
    expect(densifyTimeBuckets(monthGroups, { bucket: 'month', metrics }).map(g => g.values[0])).toEqual([
      '2025-11',
      '2025-12',
      '2026-01',
      '2026-02'
    ])

    // 4. Quarter (across year boundary)
    const quarterGroups: AggregateGroup[] = [
      { values: ['2025-Q3'], metrics: { rows: 1, revenue: 10, avg_deal: 10, unique_customers: 1 } },
      { values: ['2026-Q2'], metrics: { rows: 2, revenue: 30, avg_deal: 15, unique_customers: 2 } }
    ]
    expect(densifyTimeBuckets(quarterGroups, { bucket: 'quarter', metrics }).map(g => g.values[0])).toEqual([
      '2025-Q3',
      '2025-Q4',
      '2026-Q1',
      '2026-Q2'
    ])

    // 5. Year
    const yearGroups: AggregateGroup[] = [
      { values: ['2023'], metrics: { rows: 1, revenue: 10, avg_deal: 10, unique_customers: 1 } },
      { values: ['2026'], metrics: { rows: 2, revenue: 30, avg_deal: 15, unique_customers: 2 } }
    ]
    expect(densifyTimeBuckets(yearGroups, { bucket: 'year', metrics }).map(g => g.values[0])).toEqual([
      '2023',
      '2024',
      '2025',
      '2026'
    ])
  })

  test('densifies 2D grouped series across all secondary slices cleanly', () => {
    const groups2D: AggregateGroup[] = [
      { values: ['2026-Q1', 'Enterprise'], metrics: { rows: 3, revenue: 300, avg_deal: 100, unique_customers: 3 } },
      { values: ['2026-Q3', 'SMB'], metrics: { rows: 5, revenue: 100, avg_deal: 20, unique_customers: 5 } }
    ]

    const dense2D = densifyTimeBuckets(groups2D, { bucket: 'quarter', metrics })
    expect(dense2D.map(g => g.values)).toEqual([
      ['2026-Q1', 'Enterprise'],
      ['2026-Q1', 'SMB'],
      ['2026-Q2', 'Enterprise'],
      ['2026-Q2', 'SMB'],
      ['2026-Q3', 'Enterprise'],
      ['2026-Q3', 'SMB']
    ])
    expect(dense2D[1]?.metrics.rows).toBe(0)
    expect(dense2D[1]?.metrics.avg_deal).toBeNull()
  })
})

describe('formatMetricValue', () => {
  test('preserves full 20+ digit PostgreSQL numeric strings without IEEE-754 Number() rounding loss', () => {
    // `Number('12345678901234567891.09876543211234567899')` loses precision after 16 digits!
    const exactPgNumeric = '12345678901234567891.09876543211234567899'
    const lossyJsNumber = Number(exactPgNumeric)

    expect(formatMetricValue(lossyJsNumber, exactPgNumeric)).toBe('12,345,678,901,234,567,891.09876543211234567899')
  })

  test('applies precision rounding via BigInt, currency prefixes, percent suffixes, and null fallback', () => {
    const usdField: Pick<BaseField, 'config'> = {
      config: { format: 'currency', currency: 'USD', precision: 2 }
    }
    expect(formatMetricValue(null, '99999999999999999999.995', usdField)).toBe('$100,000,000,000,000,000,000.00')
    expect(formatMetricValue(null, '-4250.5', { config: { format: 'currency', currency: 'CNY', precision: 2 } })).toBe(
      '-¥4,250.50'
    )
    expect(formatMetricValue(null, '87.654', { config: { format: 'percent', precision: 1 } })).toBe('87.7%')
    expect(formatMetricValue(null, '-0.0001', { config: { precision: 2 } })).toBe('0.00')
    expect(formatMetricValue(null, null)).toBe('—')
  })
})
