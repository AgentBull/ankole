import Big from 'big.js'
import { densifyTimeBuckets, formatMetricValue } from '@ankole/applet-sdk'
import type {
  AggregateGroup,
  AggregateOrderBy,
  AggregateQuery,
  BaseField,
  GroupSlice,
  Metric,
  MetricOperation,
  TimeBucket,
  Value
} from '@ankole/applet-sdk/types'
import type {
  AnkoleChartSummaryTable,
  DonutCenterLabel,
  SeriesColorDescriptor,
  StatisticalStackMode
} from '@ankole/uikit'
import { displayValue, effectiveFieldType, fieldOptions } from '../base-field-types'
import type {
  ChartFieldRef,
  ChartGroupBy,
  ChartHeightPreset,
  ChartMetric,
  ChartReferenceLine,
  ChartSortMode,
  ChartTopN,
  ChartViewSpec,
  ChartViewType,
  ViewConfig
} from './view-config'

export const STACKABLE_TYPES = new Set<ChartViewType>(['column', 'bar', 'area'])
export const ONE_DIM_ONLY_TYPES = new Set<ChartViewType>(['pie', 'donut', 'funnel'])

export const CHART_HEIGHT_PX: Record<ChartHeightPreset, number> = {
  sm: 240,
  md: 320,
  lg: 420,
  xl: 520
}

export type MissingChartSlotKind =
  | 'group_0'
  | 'group_1'
  | 'metric_0'
  | 'metric_1'
  | 'scatter_x'
  | 'scatter_y'
  | 'scatter_size'
  | 'scatter_color'

export interface MissingChartSlot {
  kind: MissingChartSlotKind
  missingFieldId: string
  required: boolean
}

export interface ResolvedChartConfig {
  chartType: ChartViewType
  groupBy: ChartGroupBy[]
  metrics: ChartMetric[]
  topN: ChartTopN | null
  omitEmpty: boolean
  sortMode: ChartSortMode
  stackMode: StatisticalStackMode
  cumulative: boolean
  fillMissingBuckets: boolean
  omitZero: boolean
  showDataLabels: boolean
  smooth: boolean
  showLegend?: boolean
  height: ChartHeightPreset
  referenceLines: ChartReferenceLine[]
  scatterX?: ChartFieldRef
  scatterY?: ChartFieldRef
  scatterSize?: ChartFieldRef
  scatterColor?: ChartFieldRef
  caption?: string
}

export type DrilldownPeriodMode = 'through_period' | 'single_period'

export function isDatetimeField(field: BaseField | undefined): boolean {
  return Boolean(field && effectiveFieldType(field) === 'datetime')
}

export function isNumericField(field: BaseField | undefined): boolean {
  return Boolean(field && effectiveFieldType(field) === 'number')
}

export function compatibleMetricFields(fields: readonly BaseField[], operation: MetricOperation): BaseField[] {
  if (operation === 'sum' || operation === 'avg') {
    return fields.filter(isNumericField)
  }
  if (operation === 'min' || operation === 'max') {
    return fields.filter(f => {
      const eff = effectiveFieldType(f)
      return eff === 'number' || eff === 'text' || eff === 'datetime'
    })
  }
  return [...fields]
}

export function canUseCumulative(metrics: readonly Pick<ChartMetric, 'operation'>[]): boolean {
  return metrics.length > 0 && metrics.every(m => m.operation === 'count' || m.operation === 'sum')
}

/**
 * Derives a complete, immediately runnable chart configuration from a table's fields
 * when the view has partial or empty chart settings (zero-blank-state smart defaults).
 */
export function deriveDefaultChartSpec(fields: readonly BaseField[], partial?: ChartViewSpec): ResolvedChartConfig {
  const explicitType = partial?.chart_type
  const dateField =
    fields.find(f => f.type === 'datetime') ??
    fields.find(f => f.type === 'created_at' || f.type === 'updated_at') ??
    fields.find(isDatetimeField)
  const selectField = fields.find(f => f.type === 'select')
  const numericFields = fields.filter(f => f.type === 'number')
  const anyNumericField = numericFields[0] ?? fields.find(isNumericField)
  const fallbackCategoryField =
    selectField ?? fields.find(f => f.is_primary) ?? fields.find(f => f.type !== 'attachment')

  const chartType: ChartViewType =
    explicitType ??
    (fields.length === 0 ? 'stat' : dateField ? 'line' : selectField || fallbackCategoryField ? 'column' : 'stat')

  let groupBy: ChartGroupBy[]
  if (partial?.query?.group_by !== undefined) {
    groupBy = ONE_DIM_ONLY_TYPES.has(chartType)
      ? partial.query.group_by.slice(0, 1)
      : partial.query.group_by.slice(0, 2)
  } else if (chartType === 'stat') {
    groupBy = dateField ? [{ field_id: dateField.id, bucket: 'month' }] : []
  } else if (chartType === 'scatter') {
    groupBy = []
  } else if (dateField && (chartType === 'line' || chartType === 'area')) {
    groupBy = [{ field_id: dateField.id, bucket: 'month' }]
  } else if (selectField) {
    groupBy = [{ field_id: selectField.id }]
  } else if (dateField) {
    groupBy = [{ field_id: dateField.id, bucket: 'month' }]
  } else if (fallbackCategoryField) {
    groupBy = [{ field_id: fallbackCategoryField.id }]
  } else {
    groupBy = []
  }

  // Ensure datetime dimensions have a default bucket when omitted
  groupBy = groupBy.map(g => {
    const field = g.field_id ? fields.find(f => f.id === g.field_id) : undefined
    if (field && isDatetimeField(field) && !g.bucket) {
      return { ...g, bucket: 'month' }
    }
    return g
  })

  let metrics: ChartMetric[]
  if (partial?.query?.metrics && partial.query.metrics.length > 0) {
    metrics = partial.query.metrics.slice(0, chartType === 'combo' ? 2 : 1)
  } else if (anyNumericField) {
    metrics = [{ operation: 'sum', field_id: anyNumericField.id, alias: 'm0' }]
  } else {
    metrics = [{ operation: 'count', alias: 'count' }]
  }

  if (chartType === 'combo' && metrics.length < 2) {
    const secondNumeric = numericFields[1]
    metrics = [
      metrics[0]!,
      secondNumeric
        ? { operation: 'sum', field_id: secondNumeric.id, alias: 'm1' }
        : { operation: 'count', alias: 'm1' }
    ]
  }

  const firstGroupField = groupBy[0]?.field_id ? fields.find(f => f.id === groupBy[0]!.field_id) : undefined
  const isFirstTimeOrdered = Boolean(groupBy[0]?.bucket || (firstGroupField && isDatetimeField(firstGroupField)))
  const hasCategoricalTarget =
    groupBy.length === 2 || (groupBy.length === 1 && Boolean(firstGroupField && !isDatetimeField(firstGroupField)))

  const explicitSortMode = partial?.display?.sort_mode
  let sortMode: ChartSortMode
  if (explicitSortMode) {
    sortMode =
      explicitSortMode === 'option_order' && firstGroupField?.type !== 'select'
        ? isFirstTimeOrdered
          ? 'key_asc'
          : 'metric_desc'
        : explicitSortMode
  } else if (isFirstTimeOrdered) {
    sortMode = 'key_asc'
  } else if (firstGroupField?.type === 'select' && chartType === 'funnel') {
    sortMode = 'option_order'
  } else {
    sortMode = 'metric_desc'
  }

  let topN: ChartTopN | null
  if (partial?.query?.top_n !== undefined) {
    topN = partial.query.top_n ?? null
  } else if (chartType !== 'stat' && chartType !== 'scatter' && hasCategoricalTarget) {
    const targetIdx = groupBy.length === 2 ? 1 : 0
    topN = {
      target_group_index: targetIdx,
      limit: 10,
      by: metrics[0]?.alias ?? 'count',
      direction: sortMode === 'metric_asc' ? 'asc' : 'desc',
      include_other: true
    }
  } else {
    topN = null
  }

  const omitEmpty = partial?.query?.omit_empty ?? false
  const stackMode: StatisticalStackMode = partial?.display?.stack_mode ?? 'grouped'
  const cumulative = canUseCumulative(metrics) ? Boolean(partial?.display?.cumulative) : false
  const fillMissingBuckets = partial?.display?.fill_missing_buckets ?? true
  const omitZero = Boolean(partial?.display?.omit_zero)
  const showDataLabels = Boolean(partial?.display?.show_data_labels)
  const smooth = Boolean(partial?.display?.smooth)
  const showLegend = partial?.display?.show_legend
  const height: ChartHeightPreset = partial?.display?.height ?? 'md'
  const referenceLines: ChartReferenceLine[] = partial?.display?.reference_lines ?? []

  const defaultScatterX = partial?.encoding?.x ?? (anyNumericField ? { field_id: anyNumericField.id } : undefined)
  const secondNum = numericFields[1] ?? anyNumericField
  const defaultScatterY = partial?.encoding?.y ?? (secondNum ? { field_id: secondNum.id } : undefined)

  return {
    chartType,
    groupBy,
    metrics,
    topN,
    omitEmpty,
    sortMode,
    stackMode,
    cumulative,
    fillMissingBuckets,
    omitZero,
    showDataLabels,
    smooth,
    showLegend,
    height,
    referenceLines,
    scatterX: defaultScatterX,
    scatterY: defaultScatterY,
    scatterSize: partial?.encoding?.size,
    scatterColor: partial?.encoding?.color ?? (selectField ? { field_id: selectField.id } : undefined),
    caption: partial?.display?.caption
  }
}

function slotMissingFieldId(slot: ChartFieldRef | undefined, knownIds: ReadonlySet<string>): string | undefined {
  if (!slot) return undefined
  if (typeof slot.missing_field_id === 'string' && slot.missing_field_id.length > 0) {
    return slot.missing_field_id
  }
  if (typeof slot.field_id === 'string' && slot.field_id.length > 0 && !knownIds.has(slot.field_id)) {
    return slot.field_id
  }
  return undefined
}

/**
 * Inspects a chart spec against `fields` and returns any slot whose referenced field was deleted.
 */
export function collectMissingChartSlots(
  resolved: ResolvedChartConfig,
  fields: readonly BaseField[]
): MissingChartSlot[] {
  const knownIds = new Set(fields.map(f => f.id))
  const missing: MissingChartSlot[] = []

  if (resolved.chartType === 'scatter') {
    const xMissing = slotMissingFieldId(resolved.scatterX, knownIds)
    if (xMissing) missing.push({ kind: 'scatter_x', missingFieldId: xMissing, required: true })
    const yMissing = slotMissingFieldId(resolved.scatterY, knownIds)
    if (yMissing) missing.push({ kind: 'scatter_y', missingFieldId: yMissing, required: true })
    const sizeMissing = slotMissingFieldId(resolved.scatterSize, knownIds)
    if (sizeMissing) missing.push({ kind: 'scatter_size', missingFieldId: sizeMissing, required: false })
    const colorMissing = slotMissingFieldId(resolved.scatterColor, knownIds)
    if (colorMissing) missing.push({ kind: 'scatter_color', missingFieldId: colorMissing, required: false })
    return missing
  }

  const g0Missing = slotMissingFieldId(resolved.groupBy[0], knownIds)
  if (g0Missing) {
    missing.push({ kind: 'group_0', missingFieldId: g0Missing, required: resolved.chartType !== 'stat' })
  }
  const g1Missing = slotMissingFieldId(resolved.groupBy[1], knownIds)
  if (g1Missing) {
    missing.push({ kind: 'group_1', missingFieldId: g1Missing, required: false })
  }

  const m0 = resolved.metrics[0]
  if (m0 && m0.operation !== 'count') {
    const m0Missing = slotMissingFieldId(m0, knownIds) ?? (!m0.field_id ? 'unassigned' : undefined)
    if (m0Missing) missing.push({ kind: 'metric_0', missingFieldId: m0Missing, required: true })
  } else if (m0) {
    const m0Missing = slotMissingFieldId(m0, knownIds)
    if (m0Missing) missing.push({ kind: 'metric_0', missingFieldId: m0Missing, required: true })
  }

  if (resolved.chartType === 'combo' && resolved.metrics[1]) {
    const m1 = resolved.metrics[1]
    const m1Missing =
      m1.operation !== 'count'
        ? (slotMissingFieldId(m1, knownIds) ?? (!m1.field_id ? 'unassigned' : undefined))
        : slotMissingFieldId(m1, knownIds)
    if (m1Missing) missing.push({ kind: 'metric_1', missingFieldId: m1Missing, required: true })
  }

  return missing
}

export function serializeResolvedToViewConfig(baseConfig: ViewConfig, next: ResolvedChartConfig): ViewConfig {
  const cleanGroupBy: ChartGroupBy[] = next.groupBy
    .filter(g => Boolean(g.field_id || g.missing_field_id))
    .map(g => ({
      ...(g.field_id !== undefined ? { field_id: g.field_id } : {}),
      ...(g.missing_field_id ? { missing_field_id: g.missing_field_id } : {}),
      ...(g.bucket ? { bucket: g.bucket } : {})
    }))

  const cleanMetrics: ChartMetric[] = next.metrics.map(m => ({
    operation: m.operation,
    ...(m.operation === 'count' && !m.field_id && !m.missing_field_id
      ? {}
      : m.field_id !== undefined
        ? { field_id: m.field_id }
        : {}),
    ...(m.missing_field_id ? { missing_field_id: m.missing_field_id } : {}),
    alias: m.alias
  }))

  const cleanSlot = (slot: ChartFieldRef | undefined): ChartFieldRef | undefined => {
    if (!slot) return undefined
    if (slot.missing_field_id) {
      return { field_id: null, missing_field_id: slot.missing_field_id }
    }
    if (typeof slot.field_id === 'string' && slot.field_id.length > 0) {
      return { field_id: slot.field_id }
    }
    return undefined
  }

  const xSlot = cleanSlot(next.scatterX)
  const ySlot = cleanSlot(next.scatterY)
  const sizeSlot = cleanSlot(next.scatterSize)
  const colorSlot = cleanSlot(next.scatterColor)
  const secondaryAliases = next.chartType === 'combo' && cleanMetrics[1] ? [cleanMetrics[1].alias] : undefined

  const chart: ChartViewSpec = {
    chart_type: next.chartType,
    query: {
      group_by: cleanGroupBy,
      metrics: cleanMetrics,
      top_n: next.topN,
      omit_empty: next.omitEmpty
    },
    ...(xSlot || ySlot || sizeSlot || colorSlot || secondaryAliases
      ? {
          encoding: {
            ...(xSlot ? { x: xSlot } : {}),
            ...(ySlot ? { y: ySlot } : {}),
            ...(sizeSlot ? { size: sizeSlot } : {}),
            ...(colorSlot ? { color: colorSlot } : {}),
            ...(secondaryAliases ? { secondary_metric_aliases: secondaryAliases } : {})
          }
        }
      : {}),
    display: {
      sort_mode: next.sortMode,
      stack_mode: next.stackMode,
      cumulative: canUseCumulative(cleanMetrics) ? next.cumulative : false,
      fill_missing_buckets: next.fillMissingBuckets,
      ...(next.omitZero ? { omit_zero: true } : {}),
      ...(next.showDataLabels ? { show_data_labels: true } : {}),
      ...(next.smooth ? { smooth: true } : {}),
      ...(next.showLegend !== undefined ? { show_legend: next.showLegend } : {}),
      ...(next.height !== 'md' ? { height: next.height } : {}),
      ...(next.referenceLines.length > 0 ? { reference_lines: next.referenceLines } : {}),
      ...(next.caption ? { caption: next.caption } : {})
    }
  }

  const cleanedRoot: ViewConfig = { ...baseConfig, type: 'chart', chart }
  delete cleanedRoot.chart_type
  delete cleanedRoot.group_by
  delete cleanedRoot.metrics
  delete cleanedRoot.order_by
  delete cleanedRoot.top_n
  delete cleanedRoot.omit_empty
  delete cleanedRoot.encoding
  delete cleanedRoot.display
  return cleanedRoot
}

export function buildAggregateQueryFromSpec(
  resolved: ResolvedChartConfig,
  fields: readonly BaseField[],
  filter: ViewConfig['filter']
): AggregateQuery {
  const knownIds = new Set(fields.map(f => f.id))
  const validGroups = resolved.groupBy
    .filter(
      (g): g is { field_id: string; bucket?: TimeBucket } => typeof g.field_id === 'string' && knownIds.has(g.field_id)
    )
    .map(g => ({
      field_id: g.field_id,
      ...(g.bucket ? { bucket: g.bucket } : {})
    }))

  const validMetrics: Metric[] = resolved.metrics.map(m => ({
    operation: m.operation,
    ...(typeof m.field_id === 'string' && knownIds.has(m.field_id) ? { field_id: m.field_id } : {}),
    alias: m.alias
  }))

  const primaryAlias = validMetrics[0]?.alias ?? 'count'
  const firstGroupField = validGroups[0] ? fields.find(f => f.id === validGroups[0]!.field_id) : undefined
  const isFirstTimeOrdered = Boolean(validGroups[0]?.bucket || (firstGroupField && isDatetimeField(firstGroupField)))

  const orderBy: AggregateOrderBy[] = []
  if (validGroups.length === 1) {
    if (resolved.sortMode === 'key_asc') {
      orderBy.push({ group_index: 0, direction: 'asc' })
    } else if (resolved.sortMode === 'key_desc') {
      orderBy.push({ group_index: 0, direction: 'desc' })
    } else if (resolved.sortMode === 'metric_asc') {
      orderBy.push({ metric_alias: primaryAlias, direction: 'asc' })
    } else {
      orderBy.push({
        metric_alias: resolved.topN?.by ?? primaryAlias,
        direction: resolved.topN?.direction ?? 'desc'
      })
    }
  } else if (validGroups.length === 2) {
    if (resolved.sortMode === 'key_desc') {
      orderBy.push({ group_index: 0, direction: 'desc' })
      orderBy.push({
        metric_alias: resolved.topN?.by ?? primaryAlias,
        direction: resolved.topN?.direction ?? 'desc'
      })
    } else if (resolved.sortMode === 'key_asc' || isFirstTimeOrdered) {
      orderBy.push({ group_index: 0, direction: 'asc' })
      orderBy.push({
        metric_alias: resolved.topN?.by ?? primaryAlias,
        direction: resolved.topN?.direction ?? 'desc'
      })
    } else if (resolved.sortMode === 'metric_asc') {
      orderBy.push({ metric_alias: primaryAlias, direction: 'asc' })
    } else {
      orderBy.push({
        metric_alias: resolved.topN?.by ?? primaryAlias,
        direction: resolved.topN?.direction ?? 'desc'
      })
    }
  }

  let topN: AggregateQuery['top_n']
  if (resolved.topN && validGroups.length > 0) {
    const rawTarget =
      resolved.topN.target_group_index ?? resolved.topN.group_index ?? (validGroups.length === 2 ? 1 : 0)
    const targetIdx = Math.min(rawTarget, validGroups.length - 1)
    // Do not fold chronological X-axis buckets into "Other" unless explicitly targeting series dimension
    if (!(targetIdx === 0 && isFirstTimeOrdered)) {
      topN = {
        limit: resolved.topN.limit,
        include_other: resolved.topN.include_other ?? true,
        target_group_index: targetIdx
      }
    }
  }

  return {
    ...(filter ? { filter } : {}),
    ...(validGroups.length > 0 ? { group_by: validGroups } : {}),
    metrics: validMetrics.length > 0 ? validMetrics : [{ operation: 'count', alias: 'count' }],
    ...(orderBy.length > 0 ? { order_by: orderBy } : {}),
    ...(topN ? { top_n: topN } : {}),
    ...(resolved.omitEmpty ? { omit_empty: true } : {})
  }
}

export function formatDimensionBucketLabel(
  rawVal: Value,
  isOther: boolean,
  field: BaseField | undefined,
  bucket: TimeBucket | undefined,
  labels: { empty: string; other: string }
): { key: string; isEmpty: boolean; isOther: boolean; optionColor?: string } {
  if (isOther) {
    return { key: labels.other, isEmpty: false, isOther: true }
  }
  if (rawVal === null || rawVal === undefined) {
    return { key: labels.empty, isEmpty: true, isOther: false }
  }
  if (bucket && typeof rawVal === 'string') {
    return { key: rawVal, isEmpty: false, isOther: false }
  }
  if (field?.type === 'select') {
    const opt = fieldOptions(field).find(o => o.id === rawVal)
    if (opt) {
      return {
        key: opt.name,
        isEmpty: false,
        isOther: false,
        ...(opt.color ? { optionColor: opt.color } : {})
      }
    }
  }
  if (field?.type === 'checkbox') {
    return { key: rawVal ? 'true' : 'false', isEmpty: false, isOther: false }
  }
  if (field) {
    return { key: displayValue(field, rawVal), isEmpty: false, isOther: false }
  }
  return { key: String(rawVal), isEmpty: false, isOther: false }
}

export function toChartNumeric(val: Value | undefined, textVal?: string | null): number | null {
  if (typeof textVal === 'string' && textVal.trim() !== '') {
    const n = Number(textVal)
    if (Number.isFinite(n)) return n
  }
  if (typeof val === 'number' && Number.isFinite(val)) return val
  if (typeof val === 'string' && val.trim() !== '') {
    const n = Number(val)
    if (Number.isFinite(n)) return n
  }
  return null
}

export interface BuiltChartDataset {
  rows: Record<string, unknown>[]
  seriesMeta: SeriesColorDescriptor[]
  summaryTable: AnkoleChartSummaryTable
  processedGroups: AggregateGroup[]
  firstChronologicalBucketJson: string | null
  donutCenterLabel?: DonutCenterLabel
}

/**
 * Transforms raw `AggregateGroup[]` from `useAggregate` into G2 chart rows, rank-ordered
 * `SeriesColorDescriptor[]`, and an accessible summary table.
 */
export function buildChartDataset(
  rawGroups: readonly AggregateGroup[],
  resolved: ResolvedChartConfig,
  fields: readonly BaseField[],
  labels: { empty: string; other: string; categoryFallback: string; operations: MetricOperationLabels }
): BuiltChartDataset {
  const g0 = resolved.groupBy[0]
  const g1 = resolved.groupBy[1]
  const field0 = g0?.field_id ? fields.find(f => f.id === g0.field_id) : undefined
  const field1 = g1?.field_id ? fields.find(f => f.id === g1.field_id) : undefined

  const shouldDensify = Boolean(g0?.bucket && resolved.fillMissingBuckets !== false && !resolved.omitZero)
  const densified = shouldDensify
    ? densifyTimeBuckets(rawGroups, { bucket: g0!.bucket!, metrics: resolved.metrics })
    : rawGroups.slice()

  const chronologicalGroups = g0?.bucket
    ? [...densified].sort((a, b) => String(a.values[0]).localeCompare(String(b.values[0]), 'en'))
    : densified
  const firstBucket = chronologicalGroups.find(
    group => !group.other?.[0] && group.values[0] !== null && group.values[0] !== undefined
  )
  const firstChronologicalBucketJson = firstBucket
    ? (firstBucket.value_json?.[0] ?? JSON.stringify(firstBucket.values[0]))
    : null

  const applyCumulative = resolved.cumulative && canUseCumulative(resolved.metrics) && Boolean(g0)
  let processedGroups = densified
  if (applyCumulative) {
    const runningBySeries = new Map<string, Record<string, Big>>()
    const accumulated = new Map<AggregateGroup, AggregateGroup>()
    for (const group of chronologicalGroups) {
      if (group.other?.[0] || group.values[0] === null || group.values[0] === undefined) continue

      const seriesKey =
        group.values.length > 1
          ? JSON.stringify({ o: Boolean(group.other?.[1]), j: group.value_json?.[1] ?? group.values[1] })
          : '__1d__'
      let acc = runningBySeries.get(seriesKey)
      if (!acc) {
        acc = {}
        runningBySeries.set(seriesKey, acc)
      }

      const nextMetrics: Record<string, Value> = { ...group.metrics }
      const nextTexts: Record<string, string | null> = { ...group.metrics_text }
      for (const m of resolved.metrics) {
        const delta = group.metrics_text?.[m.alias] ?? String(group.metrics[m.alias] ?? 0)
        const total = (acc[m.alias] ?? new Big(0)).plus(delta)
        acc[m.alias] = total
        nextMetrics[m.alias] = Number(total)
        nextTexts[m.alias] = total.toFixed()
      }
      accumulated.set(group, { ...group, metrics: nextMetrics, metrics_text: nextTexts })
    }
    processedGroups = densified.map(group => accumulated.get(group) ?? group)
  }

  // Bucket filling and accumulation use chronological order; the chart uses the author's sort.
  if (g0?.bucket && (resolved.sortMode === 'key_asc' || resolved.sortMode === 'key_desc')) {
    const direction = resolved.sortMode === 'key_desc' ? -1 : 1
    processedGroups = [...processedGroups].sort((a, b) => {
      const rank = (group: AggregateGroup) => (group.other?.[0] ? 1 : group.values[0] == null ? 2 : 0)
      const rankDifference = rank(a) - rank(b)
      if (rankDifference) return rankDifference
      return direction * String(a.values[0]).localeCompare(String(b.values[0]), 'en')
    })
  }

  const primaryMetric = resolved.metrics[0]
  const secondaryMetric = resolved.chartType === 'combo' ? resolved.metrics[1] : undefined
  const primaryField = primaryMetric?.field_id ? fields.find(f => f.id === primaryMetric.field_id) : undefined
  const secondaryField = secondaryMetric?.field_id ? fields.find(f => f.id === secondaryMetric.field_id) : undefined
  const primaryAlias = primaryMetric?.alias ?? 'count'

  if (resolved.omitZero) {
    processedGroups = processedGroups.filter(group => {
      const num = toChartNumeric(group.metrics[primaryAlias], group.metrics_text?.[primaryAlias])
      return num !== 0
    })
  }

  if (g0 && field0?.type === 'select') {
    const options = fieldOptions(field0)
    const optionIndex = new Map(options.map((opt, idx) => [opt.id, idx]))
    const optionName = new Map(options.map(opt => [opt.id, opt.name]))
    const bucketRank = (group: AggregateGroup): number => {
      if (group.other?.[0]) return 1
      if (group.values[0] === null || group.values[0] === undefined) return 2
      return 0
    }
    if (resolved.sortMode === 'option_order') {
      processedGroups = [...processedGroups].sort((a, b) => {
        const rDiff = bucketRank(a) - bucketRank(b)
        if (rDiff !== 0) return rDiff
        if (bucketRank(a) !== 0) return 0
        const idxA = optionIndex.get(String(a.values[0])) ?? Number.MAX_SAFE_INTEGER
        const idxB = optionIndex.get(String(b.values[0])) ?? Number.MAX_SAFE_INTEGER
        return idxA - idxB
      })
    } else if (resolved.sortMode === 'key_asc' || resolved.sortMode === 'key_desc') {
      const dir = resolved.sortMode === 'key_asc' ? 1 : -1
      processedGroups = [...processedGroups].sort((a, b) => {
        const rDiff = bucketRank(a) - bucketRank(b)
        if (rDiff !== 0) return rDiff
        if (bucketRank(a) !== 0) return 0
        const nameA = optionName.get(String(a.values[0])) ?? displayValue(field0, a.values[0])
        const nameB = optionName.get(String(b.values[0])) ?? displayValue(field0, b.values[0])
        return dir * nameA.localeCompare(nameB)
      })
    }
  }

  const rows: Record<string, unknown>[] = []
  const colorMetaOrder = new Map<string, { descriptor: SeriesColorDescriptor; total: number }>()
  let donutSum = new Big(0)

  processedGroups.forEach((group, groupIndex) => {
    const xFormatted = g0
      ? formatDimensionBucketLabel(group.values[0] ?? null, Boolean(group.other?.[0]), field0, g0.bucket, labels)
      : { key: labels.categoryFallback, isEmpty: false, isOther: false }

    const sFormatted = g1
      ? formatDimensionBucketLabel(group.values[1] ?? null, Boolean(group.other?.[1]), field1, g1.bucket, labels)
      : undefined

    const primaryNum = toChartNumeric(group.metrics[primaryAlias], group.metrics_text?.[primaryAlias])
    const primaryFormatted = formatMetricValue(
      group.metrics[primaryAlias],
      group.metrics_text?.[primaryAlias],
      primaryField
    )
    if (primaryNum !== null) {
      donutSum = donutSum.plus(group.metrics_text?.[primaryAlias] ?? String(primaryNum))
    }

    const secondaryAlias = secondaryMetric?.alias
    const secondaryNum = secondaryAlias
      ? toChartNumeric(group.metrics[secondaryAlias], group.metrics_text?.[secondaryAlias])
      : undefined
    const secondaryFormatted = secondaryAlias
      ? formatMetricValue(group.metrics[secondaryAlias], group.metrics_text?.[secondaryAlias], secondaryField)
      : undefined

    const colorTarget = sFormatted ?? xFormatted
    const existingMeta = colorMetaOrder.get(colorTarget.key)
    const contribution = Math.abs(primaryNum ?? 0)
    if (!existingMeta) {
      colorMetaOrder.set(colorTarget.key, {
        descriptor: {
          key: colorTarget.key,
          isEmpty: colorTarget.isEmpty,
          isOther: colorTarget.isOther,
          optionColor: colorTarget.optionColor
        },
        total: contribution
      })
    } else {
      existingMeta.total += contribution
    }

    rows.push({
      x: xFormatted.key,
      ...(sFormatted ? { series: sFormatted.key } : {}),
      y: primaryNum,
      __formattedY: primaryFormatted,
      ...(secondaryNum !== undefined ? { y2: secondaryNum, __formattedY2: secondaryFormatted } : {}),
      __groupIndex: groupIndex,
      __isOther: Boolean(colorTarget.isOther)
    })
  })

  // Sort series descriptors in global rank order (non-other/non-empty by descending total first, then Other, then Empty)
  const seriesMeta = [...colorMetaOrder.values()]
    .sort((a, b) => {
      const rankBucket = (d: SeriesColorDescriptor) => (d.isEmpty ? 2 : d.isOther ? 1 : 0)
      const rbDiff = rankBucket(a.descriptor) - rankBucket(b.descriptor)
      if (rbDiff !== 0) return rbDiff
      if (b.total !== a.total) return b.total - a.total
      return a.descriptor.key < b.descriptor.key ? -1 : a.descriptor.key > b.descriptor.key ? 1 : 0
    })
    .map(entry => entry.descriptor)

  const summaryColumns: string[] = [
    field0?.name ?? labels.categoryFallback,
    ...(field1 ? [field1.name] : []),
    primaryMetric ? formatMetricHeader(primaryMetric, primaryField, labels.operations) : labels.operations.count,
    ...(secondaryMetric ? [formatMetricHeader(secondaryMetric, secondaryField, labels.operations)] : [])
  ]

  const summaryRows = processedGroups.slice(0, 200).map((group, idx) => {
    const row = rows[idx]!
    const pFormatted = formatMetricValue(group.metrics[primaryAlias], group.metrics_text?.[primaryAlias], primaryField)
    const cells: (string | number | boolean | null)[] = [String(row.x ?? '')]
    if (field1) cells.push(String(row.series ?? ''))
    cells.push(pFormatted)
    if (secondaryMetric) {
      const sAlias = secondaryMetric.alias
      cells.push(formatMetricValue(group.metrics[sAlias], group.metrics_text?.[sAlias], secondaryField))
    }
    return cells
  })

  const donutCenterLabel: DonutCenterLabel | undefined =
    resolved.chartType === 'donut' &&
    processedGroups.length > 0 &&
    canUseCumulative(resolved.metrics) &&
    (!field0 || effectiveFieldType(field0) !== 'array')
      ? {
          value: formatMetricValue(null, donutSum.toFixed(), primaryField),
          title: primaryMetric
            ? formatMetricHeader(primaryMetric, primaryField, labels.operations)
            : labels.operations.count
        }
      : undefined

  return {
    rows,
    seriesMeta,
    summaryTable: { columns: summaryColumns, rows: summaryRows },
    processedGroups,
    firstChronologicalBucketJson,
    ...(donutCenterLabel ? { donutCenterLabel } : {})
  }
}

export type MetricOperationLabels = Record<MetricOperation, string>

/** Names a metric in the viewer's language, such as "Sum · Revenue", for axis titles, table headers and KPI labels. */
export function formatMetricHeader(
  metric: ChartMetric,
  field: BaseField | undefined,
  operations: MetricOperationLabels
): string {
  if (metric.operation === 'count' && !field) return operations.count
  return `${operations[metric.operation]} · ${field?.name ?? ''}`
}

/**
 * Builds `GroupSlice[]` for `useRecords` drill-down from a clicked `AggregateGroup`,
 * preserving exact date buckets, cumulative ranges, `"Empty"` (`null`), and `"Other"` exclusions.
 */
export function buildDrilldownGroupSlices(options: {
  clickedGroup: AggregateGroup
  allGroups: readonly AggregateGroup[]
  groupBy: readonly ChartGroupBy[]
  periodMode: DrilldownPeriodMode
  firstChronologicalBucketJson: string | null
}): GroupSlice[] {
  const { clickedGroup, allGroups, groupBy, periodMode, firstChronologicalBucketJson } = options
  const slices: GroupSlice[] = []

  groupBy.forEach((dim, idx) => {
    if (!dim.field_id) return
    const isOther = Boolean(clickedGroup.other?.[idx])
    const rawVal = clickedGroup.values[idx] ?? null
    const valJson =
      clickedGroup.value_json && idx < clickedGroup.value_json.length
        ? clickedGroup.value_json[idx]
        : rawVal === null
          ? 'null'
          : JSON.stringify(rawVal)

    if (isOther) {
      const excluded = new Set<string>()
      for (const candidate of allGroups) {
        if (candidate.other?.[idx]) continue
        const cVal = candidate.values[idx]
        if (cVal === null || cVal === undefined) continue
        const cJson =
          candidate.value_json && idx < candidate.value_json.length ? candidate.value_json[idx] : JSON.stringify(cVal)
        if (typeof cJson === 'string' && cJson !== 'null') {
          excluded.add(cJson)
        }
      }
      slices.push({
        field_id: dim.field_id,
        ...(dim.bucket ? { bucket: dim.bucket } : {}),
        other_exclude_values_json: [...excluded]
      })
      return
    }

    if (rawVal === null || valJson === 'null' || valJson === null) {
      slices.push({
        field_id: dim.field_id,
        ...(dim.bucket ? { bucket: dim.bucket } : {}),
        value: null
      })
      return
    }

    const useCumulativeRange =
      idx === 0 && periodMode === 'through_period' && typeof firstChronologicalBucketJson === 'string'

    slices.push({
      field_id: dim.field_id,
      ...(dim.bucket ? { bucket: dim.bucket } : {}),
      value_json: valJson,
      ...(useCumulativeRange ? { cumulative_from_json: firstChronologicalBucketJson } : {})
    })
  })

  return slices
}
