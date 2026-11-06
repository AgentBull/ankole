import Big from 'big.js'
import type { AggregateGroup, BaseField, BaseRecord, FieldType, Metric, RecordData, TimeBucket, Value } from './types'

export type FinancialTimeUnit = 'business_day' | 'unix_seconds'

export type DuplicateTimeStrategy = 'error' | 'last'

export type FinancialTimeValue<Unit extends FinancialTimeUnit> = Unit extends 'business_day' ? string : number

export type FinancialOhlcBar<TTime extends string | number = string | number> = {
  time: TTime
  open: number
  high: number
  low: number
  close: number
}

export type FinancialValueBar<TTime extends string | number = string | number> = {
  time: TTime
  value: number
}

export type FinancialVolumeBar<TTime extends string | number = string | number> = {
  time: TTime
  value: number
}

type FinancialSeriesBaseMapping<Unit extends FinancialTimeUnit> = {
  timeField: string
  timeUnit: Unit
  volumeField?: string
  onDuplicateTime?: DuplicateTimeStrategy
}

export type FinancialOhlcMapping<Unit extends FinancialTimeUnit = FinancialTimeUnit> =
  FinancialSeriesBaseMapping<Unit> & {
    openField: string
    highField: string
    lowField: string
    closeField: string
    valueField?: undefined
  }

export type FinancialValueMapping<Unit extends FinancialTimeUnit = FinancialTimeUnit> =
  FinancialSeriesBaseMapping<Unit> & {
    valueField: string
    openField?: undefined
    highField?: undefined
    lowField?: undefined
    closeField?: undefined
  }

export type FinancialSeriesMapping<Unit extends FinancialTimeUnit = FinancialTimeUnit> =
  | FinancialOhlcMapping<Unit>
  | FinancialValueMapping<Unit>

export type FinancialSeriesResult<TBar, TTime extends string | number> = {
  bars: TBar[]
  volume: FinancialVolumeBar<TTime>[]
  skippedCount: number
}

const BUSINESS_DAY_RE = /^(\d{4})-(\d{2})-(\d{2})$/
const PURE_NUMERIC_RE = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/
const DECIMAL_NUMBER_RE = /^([+-])?(?:(\d+)(?:\.(\d*))?|\.(\d+))(?:[eE]([+-]?\d+))?$/

function isValidBusinessDay(value: unknown): value is string {
  if (typeof value !== 'string') return false
  const trimmed = value.trim()
  const match = BUSINESS_DAY_RE.exec(trimmed)
  if (!match) return false
  const year = Number(match[1])
  const month = Number(match[2])
  const day = Number(match[3])
  if (month < 1 || month > 12 || day < 1 || day > 31) return false
  const utc = new Date(Date.UTC(year, month - 1, day))
  return utc.getUTCFullYear() === year && utc.getUTCMonth() === month - 1 && utc.getUTCDate() === day
}

function normalizeBusinessDay(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return isValidBusinessDay(trimmed) ? trimmed : null
}

function toUnixSecondsFromNumber(num: number): number | null {
  if (!Number.isFinite(num)) return null
  return Math.abs(num) >= 1e11 ? Math.floor(num / 1000) : Math.floor(num)
}

function normalizeUnixSeconds(value: unknown): number | null {
  if (typeof value === 'number') {
    return toUnixSecondsFromNumber(value)
  }
  if (typeof value === 'string') {
    const trimmed = value.trim()
    if (!trimmed) return null
    if (PURE_NUMERIC_RE.test(trimmed)) {
      return toUnixSecondsFromNumber(Number(trimmed))
    }
    const parsedMs = Date.parse(trimmed)
    if (Number.isNaN(parsedMs)) return null
    return Math.floor(parsedMs / 1000)
  }
  return null
}

function parseFiniteNumber(value: unknown): number | null {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : null
  }
  if (typeof value === 'string') {
    const trimmed = value.trim()
    if (!trimmed) return null
    const parsed = Number(trimmed)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

function isOhlcMapping<Unit extends FinancialTimeUnit>(
  mapping: FinancialSeriesMapping<Unit>
): mapping is FinancialOhlcMapping<Unit> {
  return typeof mapping.openField === 'string'
}

/**
 * Extracts and validates financial OHLC or single-value time series (plus optional volume)
 * from Base records without synthesizing fake OHLC bars or indicator values.
 */
export function recordsToFinancialSeries<Unit extends FinancialTimeUnit>(
  records: readonly Pick<BaseRecord, 'data'>[],
  mapping: FinancialOhlcMapping<Unit>
): FinancialSeriesResult<FinancialOhlcBar<FinancialTimeValue<Unit>>, FinancialTimeValue<Unit>>
export function recordsToFinancialSeries<Unit extends FinancialTimeUnit>(
  records: readonly Pick<BaseRecord, 'data'>[],
  mapping: FinancialValueMapping<Unit>
): FinancialSeriesResult<FinancialValueBar<FinancialTimeValue<Unit>>, FinancialTimeValue<Unit>>
export function recordsToFinancialSeries<Unit extends FinancialTimeUnit>(
  records: readonly Pick<BaseRecord, 'data'>[],
  mapping: FinancialSeriesMapping<Unit>
): FinancialSeriesResult<
  FinancialOhlcBar<FinancialTimeValue<Unit>> | FinancialValueBar<FinancialTimeValue<Unit>>,
  FinancialTimeValue<Unit>
> {
  type TTime = FinancialTimeValue<Unit>
  type TBar = FinancialOhlcBar<TTime> | FinancialValueBar<TTime>

  const duplicateStrategy: DuplicateTimeStrategy = mapping.onDuplicateTime ?? 'error'
  const ohlcMode = isOhlcMapping(mapping)

  const extracted: {
    time: TTime
    bar: TBar
    volume: number | null
  }[] = []
  let skippedCount = 0

  for (const record of records) {
    const data: RecordData = record.data
    const rawTime = data[mapping.timeField]
    const parsedTime =
      mapping.timeUnit === 'business_day' ? normalizeBusinessDay(rawTime) : normalizeUnixSeconds(rawTime)

    if (parsedTime === null) {
      skippedCount += 1
      continue
    }

    const time = parsedTime as TTime

    if (ohlcMode) {
      const open = parseFiniteNumber(data[mapping.openField])
      const high = parseFiniteNumber(data[mapping.highField])
      const low = parseFiniteNumber(data[mapping.lowField])
      const close = parseFiniteNumber(data[mapping.closeField])
      if (open === null || high === null || low === null || close === null) {
        skippedCount += 1
        continue
      }
      const volume = mapping.volumeField ? parseFiniteNumber(data[mapping.volumeField]) : null
      extracted.push({
        time,
        bar: { time, open, high, low, close },
        volume
      })
    } else {
      const val = parseFiniteNumber(data[mapping.valueField])
      if (val === null) {
        skippedCount += 1
        continue
      }
      const volume = mapping.volumeField ? parseFiniteNumber(data[mapping.volumeField]) : null
      extracted.push({
        time,
        bar: { time, value: val },
        volume
      })
    }
  }

  extracted.sort((a, b) => {
    if (typeof a.time === 'number' && typeof b.time === 'number') {
      return a.time - b.time
    }
    return String(a.time) < String(b.time) ? -1 : String(a.time) > String(b.time) ? 1 : 0
  })

  const deduped: typeof extracted = []
  for (const item of extracted) {
    const prev = deduped[deduped.length - 1]
    if (prev && prev.time === item.time) {
      if (duplicateStrategy === 'error') {
        throw new Error(`Duplicate financial series timestamp: ${String(item.time)}`)
      }
      deduped[deduped.length - 1] = item
    } else {
      deduped.push(item)
    }
  }

  const bars: TBar[] = []
  const volume: FinancialVolumeBar<TTime>[] = []
  for (const item of deduped) {
    bars.push(item.bar)
    if (item.volume !== null) {
      volume.push({ time: item.time, value: item.volume })
    }
  }

  return { bars, volume, skippedCount }
}

export type DensifyTimeBucketsOptions = {
  bucket: TimeBucket
  metrics: readonly Pick<Metric, 'alias' | 'operation'>[]
}

const MONTH_KEY_RE = /^(\d{4})-(\d{2})$/
const QUARTER_KEY_RE = /^(\d{4})-Q([1-4])$/
const YEAR_KEY_RE = /^(\d{4})$/
const MONDAY_EPOCH_MS = Date.UTC(1970, 0, 5)

function pad2(n: number): string {
  return String(n).padStart(2, '0')
}

function pad4(n: number): string {
  return String(n).padStart(4, '0')
}

function formatUtcDate(ms: number): string {
  const d = new Date(ms)
  return `${pad4(d.getUTCFullYear())}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}`
}

function alignUtcDateToMonday(ms: number): number {
  const d = new Date(ms)
  const dayOfWeek = d.getUTCDay()
  const offsetFromMonday = (dayOfWeek + 6) % 7
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - offsetFromMonday)
}

function parseBucketOrdinal(rawKey: unknown, bucket: TimeBucket): { canonicalKey: string; ordinal: number } | null {
  if (typeof rawKey !== 'string') return null
  const key = rawKey.trim()
  if (!key) return null

  switch (bucket) {
    case 'day': {
      if (!isValidBusinessDay(key)) return null
      const [y, m, d] = key.split('-').map(Number)
      const ms = Date.UTC(y!, m! - 1, d!)
      return { canonicalKey: key, ordinal: Math.round(ms / 86_400_000) }
    }
    case 'week': {
      if (!isValidBusinessDay(key)) return null
      const [y, m, d] = key.split('-').map(Number)
      const mondayMs = alignUtcDateToMonday(Date.UTC(y!, m! - 1, d!))
      return {
        canonicalKey: formatUtcDate(mondayMs),
        ordinal: Math.round((mondayMs - MONDAY_EPOCH_MS) / (7 * 86_400_000))
      }
    }
    case 'month': {
      const match = MONTH_KEY_RE.exec(key)
      if (!match) return null
      const year = Number(match[1])
      const month = Number(match[2])
      if (month < 1 || month > 12) return null
      return { canonicalKey: `${pad4(year)}-${pad2(month)}`, ordinal: year * 12 + (month - 1) }
    }
    case 'quarter': {
      const match = QUARTER_KEY_RE.exec(key)
      if (!match) return null
      const year = Number(match[1])
      const quarter = Number(match[2])
      return { canonicalKey: `${pad4(year)}-Q${quarter}`, ordinal: year * 4 + (quarter - 1) }
    }
    case 'year': {
      const match = YEAR_KEY_RE.exec(key)
      if (!match) return null
      const year = Number(match[1])
      return { canonicalKey: pad4(year), ordinal: year }
    }
  }
}

function formatBucketOrdinal(ordinal: number, bucket: TimeBucket): string {
  switch (bucket) {
    case 'day':
      return formatUtcDate(ordinal * 86_400_000)
    case 'week':
      return formatUtcDate(MONDAY_EPOCH_MS + ordinal * 7 * 86_400_000)
    case 'month': {
      const year = Math.floor(ordinal / 12)
      const month = ordinal - year * 12 + 1
      return `${pad4(year)}-${pad2(month)}`
    }
    case 'quarter': {
      const year = Math.floor(ordinal / 4)
      const quarter = ordinal - year * 4 + 1
      return `${pad4(year)}-Q${quarter}`
    }
    case 'year':
      return pad4(ordinal)
  }
}

function buildEmptyBucketMetrics(metrics: readonly Pick<Metric, 'alias' | 'operation'>[]): {
  metrics: Record<string, Value>
  metrics_text: Record<string, string | null>
} {
  const metricValues: Record<string, Value> = {}
  const metricTexts: Record<string, string | null> = {}

  for (const metric of metrics) {
    if (metric.operation === 'count' || metric.operation === 'sum') {
      metricValues[metric.alias] = 0
      metricTexts[metric.alias] = '0'
    } else {
      metricValues[metric.alias] = null
      metricTexts[metric.alias] = null
    }
  }

  return { metrics: metricValues, metrics_text: metricTexts }
}

function serializeSliceId(group: AggregateGroup): string {
  if (group.values.length <= 1) return '__1d__'
  const restValues = group.values.slice(1)
  const restJson = group.value_json
    ? group.value_json.slice(1)
    : restValues.map(v => (v === null ? null : JSON.stringify(v)))
  const restOther = group.other ? group.other.slice(1) : restValues.map(() => false)
  return JSON.stringify({ j: restJson, o: restOther })
}

/**
 * Fills missing chronological buckets (`day`, Monday-aligned `week`, `month`, `quarter`, `year`)
 * between the earliest and latest non-null bucket key across 1D or 2D `AggregateGroup[]`.
 *
 * Missing `count` and `sum` metrics receive `0` (`metrics_text: '0'`), while `avg`, `min`, `max`,
 * and `count_distinct` receive `null` (`metrics_text: null`). `null` ("Empty") and `other` buckets
 * are preserved unchanged.
 */
export function densifyTimeBuckets(
  groups: readonly AggregateGroup[],
  options: DensifyTimeBucketsOptions
): AggregateGroup[] {
  if (groups.length === 0) return []

  const passthroughGroups: AggregateGroup[] = []
  const datedGroups: {
    group: AggregateGroup
    canonicalKey: string
    ordinal: number
    sliceId: string
  }[] = []

  let minOrdinal = Infinity
  let maxOrdinal = -Infinity

  for (const group of groups) {
    const isTimeOther = Boolean(group.other?.[0])
    const rawTime = group.values[0]
    if (isTimeOther || rawTime === null || rawTime === undefined) {
      passthroughGroups.push(group)
      continue
    }

    const parsed = parseBucketOrdinal(rawTime, options.bucket)
    if (!parsed) {
      passthroughGroups.push(group)
      continue
    }

    if (parsed.ordinal < minOrdinal) minOrdinal = parsed.ordinal
    if (parsed.ordinal > maxOrdinal) maxOrdinal = parsed.ordinal

    const normalizedGroup: AggregateGroup =
      parsed.canonicalKey === rawTime
        ? group
        : {
            ...group,
            values: [parsed.canonicalKey, ...group.values.slice(1)],
            ...(group.value_json
              ? { value_json: [JSON.stringify(parsed.canonicalKey), ...group.value_json.slice(1)] }
              : {})
          }

    datedGroups.push({
      group: normalizedGroup,
      canonicalKey: parsed.canonicalKey,
      ordinal: parsed.ordinal,
      sliceId: serializeSliceId(normalizedGroup)
    })
  }

  if (!Number.isFinite(minOrdinal) || !Number.isFinite(maxOrdinal) || datedGroups.length === 0) {
    return groups.slice()
  }

  const hasValueJson = groups.some(g => Array.isArray(g.value_json))
  const hasOtherFlags = groups.some(g => Array.isArray(g.other))

  const slices = new Map<
    string,
    {
      restValues: Value[]
      restValueJson: (string | null)[]
      restOther: boolean[]
      byKey: Map<string, AggregateGroup>
    }
  >()

  for (const entry of datedGroups) {
    let slice = slices.get(entry.sliceId)
    if (!slice) {
      const restValues = entry.group.values.slice(1)
      const restValueJson = entry.group.value_json
        ? entry.group.value_json.slice(1)
        : restValues.map(v => (v === null ? null : JSON.stringify(v)))
      const restOther = entry.group.other ? entry.group.other.slice(1) : restValues.map(() => false)
      slice = {
        restValues,
        restValueJson,
        restOther,
        byKey: new Map()
      }
      slices.set(entry.sliceId, slice)
    }
    slice.byKey.set(entry.canonicalKey, entry.group)
  }

  const allKeys: string[] = []
  for (let ord = minOrdinal; ord <= maxOrdinal; ord += 1) {
    allKeys.push(formatBucketOrdinal(ord, options.bucket))
  }

  const result: AggregateGroup[] = []
  for (const key of allKeys) {
    for (const slice of slices.values()) {
      const existing = slice.byKey.get(key)
      if (existing) {
        result.push(existing)
      } else {
        const emptyMetrics = buildEmptyBucketMetrics(options.metrics)
        const synthesized: AggregateGroup = {
          values: [key, ...slice.restValues],
          ...(hasValueJson || slice.restValues.length > 0
            ? { value_json: [JSON.stringify(key), ...slice.restValueJson] }
            : { value_json: [JSON.stringify(key)] }),
          ...(hasOtherFlags || slice.restOther.some(Boolean) ? { other: [false, ...slice.restOther] } : {}),
          metrics: emptyMetrics.metrics,
          metrics_text: emptyMetrics.metrics_text
        }
        result.push(synthesized)
      }
    }
  }

  for (const passthrough of passthroughGroups) {
    result.push(passthrough)
  }

  return result
}

const CURRENCY_SYMBOLS: Record<string, string> = {
  USD: '$',
  CNY: '¥',
  RMB: '¥',
  JPY: '¥',
  EUR: '€',
  GBP: '£',
  HKD: 'HK$',
  KRW: '₩',
  INR: '₹',
  CAD: 'CA$',
  AUD: 'A$',
  CHF: 'CHF '
}

function resolveCurrencyPrefix(config: Record<string, unknown>): string {
  for (const key of ['currency_symbol', 'symbol', 'prefix']) {
    const val = config[key]
    if (typeof val === 'string' && val.length > 0) return val
  }
  const currency = config.currency
  if (typeof currency === 'string' && currency.trim().length > 0) {
    const upper = currency.trim().toUpperCase()
    return CURRENCY_SYMBOLS[upper] ?? `${upper} `
  }
  return '$'
}

/**
 * Formats `textValue ?? value` without IEEE-754 `Number()` precision loss on high-precision
 * PostgreSQL `numeric` strings, applying `field?.config` (`precision`, `format`, currency prefix,
 * percent suffix, and thousands separators).
 */
export function formatMetricValue(
  value: Value | undefined,
  textValue?: string | null,
  field?: (Pick<BaseField, 'config'> & { type?: FieldType }) | null
): string {
  const source = textValue !== undefined && textValue !== null ? textValue : value
  if (source === null || source === undefined || source === '') return '—'

  let rawStr: string
  if (typeof source === 'string') {
    rawStr = source.trim()
    if (!rawStr) return '—'
  } else if (typeof source === 'number') {
    if (!Number.isFinite(source)) return '—'
    rawStr = String(source)
  } else if (typeof source === 'boolean') {
    return source ? 'true' : 'false'
  } else {
    return JSON.stringify(source)
  }

  const match = DECIMAL_NUMBER_RE.exec(rawStr)
  if (!match) return rawStr
  const exponent = Number(match[5] ?? 0)
  if (!Number.isInteger(exponent) || Math.abs(exponent) > 10_000) return rawStr
  const decimal = new Big(rawStr.replace(/^\+/, ''))

  const config = field?.config ?? {}
  const format = typeof config.format === 'string' ? config.format.trim().toLowerCase() : ''
  const rawPrecision =
    typeof config.precision === 'number'
      ? config.precision
      : typeof config.decimals === 'number'
        ? config.decimals
        : format === 'integer'
          ? 0
          : undefined

  const sourcePrecision = Math.max(0, (match[3] ?? match[4] ?? '').length - exponent)
  const precision =
    rawPrecision !== undefined && Number.isInteger(rawPrecision) && rawPrecision >= 0 ? rawPrecision : sourcePrecision
  const rounded = decimal.toFixed(precision, Big.roundHalfUp)
  const negative = rounded.startsWith('-') && !new Big(rounded).eq(0)
  const [intDigits = '0', fracDigits = ''] = rounded.replace(/^-/, '').split('.')

  const useGrouping = config.use_grouping !== false && config.thousands_separator !== false
  const formattedInt = useGrouping ? intDigits.replace(/\B(?=(\d{3})+(?!\d))/g, ',') : intDigits
  const formattedNumber = fracDigits.length > 0 ? `${formattedInt}.${fracDigits}` : formattedInt

  let prefix = ''
  if (format === 'currency') {
    prefix = resolveCurrencyPrefix(config)
  } else if (typeof config.prefix === 'string') {
    prefix = config.prefix
  }

  let suffix = ''
  if (format === 'percent' || format === 'percentage') {
    suffix = typeof config.suffix === 'string' ? config.suffix : '%'
  } else if (typeof config.suffix === 'string') {
    suffix = config.suffix
  }

  return `${negative ? '-' : ''}${prefix}${formattedNumber}${suffix}`
}
