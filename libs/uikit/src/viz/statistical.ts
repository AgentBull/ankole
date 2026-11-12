import { Renderer as SVGRenderer } from '@antv/g-svg'
import { corelib, extend, graphlib, plotlib, Runtime, type G2Spec } from '@antv/g2'
import { formatFallbackNumeric, toFiniteNumber } from './format'
import { statChartParts, statTrendGlyph, type StatTrendDirection } from './stat-summary'
import {
  assignSeriesColors,
  pickReadableDataLabelInk,
  resolveVizTheme,
  sanitizeExportedSvg,
  type AssignSeriesColorsOptions,
  type MarketConvention,
  type SeriesColorDescriptor,
  type VizThemeMode,
  type VizThemePalette
} from './theme'

export { resolveStatTrend, type StatTrendDirection } from './stat-summary'

const BASE_CORELIB = corelib()

const RuntimeChart = extend(Runtime, {
  ...BASE_CORELIB,
  ...plotlib(),
  ...graphlib()
})

export type StatisticalChartTier1Type =
  | 'column'
  | 'bar'
  | 'line'
  | 'area'
  | 'combo'
  | 'pie'
  | 'donut'
  | 'funnel'
  | 'scatter'

export type StatisticalChartTier2Type =
  | 'histogram'
  | 'boxplot'
  | 'heatmap'
  | 'radar'
  | 'waterfall'
  | 'gauge'
  | 'treemap'
  | 'sunburst'
  | 'sankey'
  | 'wordcloud'
  | 'quantile_band'

/**
 * Single-value summaries. A `stat` chart renders one metric from the first data row: its
 * value, an optional unit, and an optional comparison with a trend.
 */
export type StatisticalSummaryType = 'stat'

export type StatisticalChartType = StatisticalChartTier1Type | StatisticalChartTier2Type | StatisticalSummaryType

export type StatisticalStackMode = 'grouped' | 'stacked' | 'percent'

export type PercentFallbackReason = 'negative_values'

export interface StatisticalReferenceLine {
  value: number
  label?: string
  color?: string
  axis?: 'y' | 'x'
}

export interface DonutCenterLabel {
  value: string
  title?: string
}

export interface StatisticalChartSpec {
  type: StatisticalChartType
  data: readonly Record<string, unknown>[] | Record<string, unknown>
  xField?: string
  yField?: string
  secondaryYField?: string
  seriesField?: string
  sizeField?: string
  valueField?: string
  sourceField?: string
  targetField?: string
  /** Lower bound of the shaded band of a `quantile_band` chart, for example p5. */
  bandLowField?: string
  /** Upper bound of the shaded band of a `quantile_band` chart, for example p95. */
  bandHighField?: string
  /** Legend and tooltip name of the band, for example `p5–p95`. */
  bandLabel?: string
  /** Unit shown beside the value of a `stat` chart, for example `ms`. */
  unit?: string
  /** Row field with the comparison value of a `stat` chart, for example `+12.4%`. */
  comparisonField?: string
  /** Row field with an explicit `stat` trend (`up`, `down`, or `neutral`). */
  trendField?: string
  /** Row field with the formatted value of a `stat` chart, used instead of a number format. */
  formattedValueField?: string
  xTitle?: string
  yTitle?: string
  secondaryYTitle?: string
  sizeTitle?: string
  seriesTitle?: string
  formattedYField?: string
  formattedSecondaryYField?: string
  shareTextField?: string
  showDataLabels?: boolean
  smooth?: boolean
  donutCenterLabel?: DonutCenterLabel
  seriesMeta?: readonly SeriesColorDescriptor[]
  stackMode?: StatisticalStackMode
  title?: string
  subtitle?: string
  showLegend?: boolean
  width?: number
  height?: number
  renderer?: 'canvas' | 'svg'
  theme?: VizThemeMode
  marketConvention?: MarketConvention
  tokenOverrides?: Partial<Record<string, string>>
  animate?: boolean
  referenceLines?: readonly StatisticalReferenceLine[]
  onElementClick?: (datum: Record<string, unknown>, nativeEvent?: unknown) => void
  g2Options?: Record<string, unknown>
}

export interface MountedStatisticalChart {
  readonly percentFallbackReason: PercentFallbackReason | undefined
  update: (nextSpec: StatisticalChartSpec) => Promise<void>
  resize: (width: number, height: number) => Promise<void>
  exportSVG: () => Promise<string>
  exportPNG: (dpr?: number) => Promise<string>
  destroy: () => void
}

export interface PreparedStatisticalSpec {
  g2Spec: G2Spec
  effectiveStackMode: StatisticalStackMode | undefined
  percentFallbackReason: PercentFallbackReason | undefined
}

const PERCENT_SHARE_FIELD = '__ankolePercentShare'
const PERCENT_SHARE_TEXT_FIELD = '__ankolePercentText'
const PIE_SHARE_TEXT_FIELD = '__ankolePieShareText'
const WATERFALL_START_FIELD = '__ankoleWfStart'
const WATERFALL_END_FIELD = '__ankoleWfEnd'
const WATERFALL_KIND_FIELD = '__ankoleWfKind'

function formatPercentageShare(share: number): string {
  const pct = Math.max(0, share * 100)
  return `${pct.toFixed(1).replace(/\.0$/, '')}%`
}

function formatRowMetricText(
  row: Record<string, unknown>,
  rawField: string,
  formattedField?: string,
  shareText?: string
): string {
  const baseText =
    formattedField && typeof row[formattedField] === 'string' && row[formattedField] !== ''
      ? (row[formattedField] as string)
      : formatFallbackNumeric(row[rawField])
  if (shareText && shareText.length > 0 && !baseText.includes(`(${shareText})`)) {
    return `${baseText} (${shareText})`
  }
  return baseText
}

/** Picks the readable foreground color for a `stat` trend from the resolved palette. */
function statTrendForeground(trend: StatTrendDirection, palette: VizThemePalette): string {
  if (trend === 'up') return palette.upForeground
  if (trend === 'down') return palette.downForeground
  return palette.fgSecondary
}

/** Builds one positioned G2 text mark for a `stat` card. */
function statTextMark(text: string, style: Record<string, unknown>, animate: boolean): Record<string, unknown> {
  return {
    type: 'text',
    tooltip: false,
    style: { text, ...style },
    ...(animate ? {} : { animate: false })
  }
}

/**
 * Lays out the single metric of a `stat` chart as positioned text marks. The marks follow the
 * resolved viz palette, so light/dark themes and `cn` market conventions need no extra work.
 */
function buildStatChartMarks(
  spec: StatisticalChartSpec,
  palette: VizThemePalette,
  animate: boolean
): Record<string, unknown>[] {
  const { valueText, unit, comparisonText, trend } = statChartParts(spec)
  const monoFamily = palette.fontMono || palette.fontSans

  const marks: Record<string, unknown>[] = []

  if (spec.title) {
    marks.push(
      statTextMark(
        spec.title,
        {
          x: '8%',
          y: '12%',
          textAlign: 'left',
          textBaseline: 'middle',
          fontSize: 12,
          fontWeight: 500,
          fontFamily: palette.fontSans,
          fill: palette.fgSecondary
        },
        animate
      )
    )
  }

  if (spec.subtitle) {
    marks.push(
      statTextMark(
        spec.subtitle,
        {
          x: '8%',
          y: '24%',
          textAlign: 'left',
          textBaseline: 'middle',
          fontSize: 11,
          fontFamily: palette.fontSans,
          fill: palette.fgTertiary
        },
        animate
      )
    )
  }

  marks.push(
    statTextMark(
      valueText,
      {
        x: '8%',
        y: '52%',
        textAlign: 'left',
        textBaseline: 'middle',
        fontSize: 30,
        fontWeight: 600,
        fontFamily: monoFamily,
        fill: palette.foreground
      },
      animate
    )
  )

  if (unit) {
    marks.push(
      statTextMark(
        unit,
        {
          x: '92%',
          y: '52%',
          textAlign: 'right',
          textBaseline: 'middle',
          fontSize: 14,
          fontFamily: monoFamily,
          fill: palette.fgSecondary
        },
        animate
      )
    )
  }

  if (comparisonText) {
    marks.push(
      statTextMark(
        `${statTrendGlyph(trend)} ${comparisonText}`,
        {
          x: '8%',
          y: '82%',
          textAlign: 'left',
          textBaseline: 'middle',
          fontSize: 12,
          fontWeight: 500,
          fontFamily: monoFamily,
          fill: statTrendForeground(trend, palette)
        },
        animate
      )
    )
  }

  return marks
}

/**
 * Checks whether a `percent` stack mode spec contains negative numeric values.
 */
export function detectPercentFallbackReason(
  data: StatisticalChartSpec['data'],
  metricField: string | undefined,
  stackMode: StatisticalStackMode | undefined
): PercentFallbackReason | undefined {
  if (stackMode !== 'percent' || !Array.isArray(data) || !metricField) return undefined
  for (const row of data) {
    const num = toFiniteNumber(row[metricField])
    if (num !== null && num < 0) {
      return 'negative_values'
    }
  }
  return undefined
}

function normalizePercentRows(
  rows: readonly Record<string, unknown>[],
  xField: string | undefined,
  metricField: string
): Record<string, unknown>[] {
  const bucketTotals = new Map<string, number>()
  for (const row of rows) {
    const bucketKey = xField ? String(row[xField] ?? '') : '__all__'
    const val = Math.max(0, toFiniteNumber(row[metricField]) ?? 0)
    bucketTotals.set(bucketKey, (bucketTotals.get(bucketKey) ?? 0) + val)
  }

  return rows.map(row => {
    const bucketKey = xField ? String(row[xField] ?? '') : '__all__'
    const total = bucketTotals.get(bucketKey) ?? 0
    const val = Math.max(0, toFiniteNumber(row[metricField]) ?? 0)
    const share = total > 0 ? val / total : 0
    return {
      ...row,
      ...(typeof row[PERCENT_SHARE_TEXT_FIELD] === 'string'
        ? {}
        : { [PERCENT_SHARE_TEXT_FIELD]: formatPercentageShare(share) }),
      [PERCENT_SHARE_FIELD]: share
    }
  })
}

function deriveColorScale(
  rows: readonly Record<string, unknown>[],
  colorField: string | undefined,
  seriesMeta: readonly SeriesColorDescriptor[] | undefined,
  palette: VizThemePalette,
  options?: AssignSeriesColorsOptions
): { domain: string[]; range: string[] } | undefined {
  if (!colorField && (!seriesMeta || seriesMeta.length === 0)) return undefined

  const descriptors: SeriesColorDescriptor[] = []
  const seen = new Set<string>()
  const metaMap = new Map((seriesMeta ?? []).map(item => [item.key, item]))

  if (seriesMeta && seriesMeta.length > 0) {
    for (const item of seriesMeta) {
      if (seen.has(item.key)) continue
      seen.add(item.key)
      descriptors.push(item)
    }
  }

  if (colorField) {
    for (const row of rows) {
      const raw = row[colorField]
      const isEmpty = raw === null || raw === undefined || raw === ''
      const key = isEmpty ? 'Empty' : String(raw)
      if (seen.has(key)) continue
      seen.add(key)
      const explicitMeta = metaMap.get(key)
      descriptors.push(
        explicitMeta ?? {
          key,
          isEmpty: isEmpty || key === 'Empty',
          isOther: key === 'Other' || Boolean(row.__isOther)
        }
      )
    }
  }

  if (descriptors.length === 0) return undefined
  const assigned = assignSeriesColors(descriptors, palette, options)
  return {
    domain: [...assigned.keys()],
    range: [...assigned.values()]
  }
}

/**
 * Preserves Munzner's expressiveness rule for 1D bar/column charts without explicit `:select`
 * option colors: normal categories share uniform primary Cobalt (`palette.categorical[0]`) so
 * position/length carries magnitude without false categorical hue noise, while residual `Other`
 * and `Empty` buckets step back into neutral mineral gray.
 */
function derive1DFocusColorScale(
  rows: readonly Record<string, unknown>[],
  xField: string,
  seriesMeta: readonly SeriesColorDescriptor[] | undefined,
  palette: VizThemePalette
): { domain: string[]; range: string[] } | undefined {
  const domain: string[] = []
  const range: string[] = []
  const seen = new Set<string>()
  const metaMap = new Map((seriesMeta ?? []).map(item => [item.key, item]))

  const pushKey = (key: string, isEmpty: boolean, isOther: boolean) => {
    if (seen.has(key)) return
    seen.add(key)
    domain.push(key)
    if (isEmpty) {
      range.push(palette.emptyColor)
    } else if (isOther) {
      range.push(palette.otherColor)
    } else {
      range.push(palette.categorical[0])
    }
  }

  if (seriesMeta) {
    for (const item of seriesMeta) {
      pushKey(item.key, Boolean(item.isEmpty), Boolean(item.isOther))
    }
  }

  for (const row of rows) {
    const raw = row[xField]
    const isEmptyRow = raw === null || raw === undefined || raw === ''
    const key = isEmptyRow ? 'Empty' : String(raw)
    const meta = metaMap.get(key)
    pushKey(
      key,
      Boolean(meta?.isEmpty || isEmptyRow || key === 'Empty'),
      Boolean(meta?.isOther || key === 'Other' || row.__isOther)
    )
  }

  return domain.length > 0 ? { domain, range } : undefined
}

const LIGHT_FUNNEL_PROGRESSION = ['#1b4d9b', '#2864b9', '#1c79b5', '#0f8ba3', '#049383', '#2e9e8f'] as const
const DARK_FUNNEL_PROGRESSION = ['#7ab4ff', '#5d98e7', '#4aa5cf', '#51c6b5', '#3e9e92', '#357e82'] as const

function deriveFunnelOrderedScale(
  rows: readonly Record<string, unknown>[],
  categoryKey: string,
  seriesMeta: readonly SeriesColorDescriptor[] | undefined,
  palette: VizThemePalette
): { domain: string[]; range: string[] } {
  const hasExplicitOptionColor = Boolean(seriesMeta?.some(item => Boolean(item.optionColor)))
  if (hasExplicitOptionColor) {
    const explicit = deriveColorScale(rows, categoryKey, seriesMeta, palette)
    if (explicit) return explicit
  }

  const ramp = palette.isDark ? DARK_FUNNEL_PROGRESSION : LIGHT_FUNNEL_PROGRESSION
  const metaMap = new Map((seriesMeta ?? []).map(item => [item.key, item]))
  const domain: string[] = []
  const range: string[] = []
  const seen = new Set<string>()
  let stageIdx = 0

  for (const row of rows) {
    const raw = row[categoryKey]
    const isEmptyRow = raw === null || raw === undefined || raw === ''
    const key = isEmptyRow ? 'Empty' : String(raw)
    if (seen.has(key)) continue
    seen.add(key)
    const meta = metaMap.get(key)
    domain.push(key)
    if (meta?.isEmpty || isEmptyRow || key === 'Empty') {
      range.push(palette.emptyColor)
    } else if (meta?.isOther || key === 'Other' || row.__isOther) {
      range.push(palette.otherColor)
    } else {
      const firstOverride =
        stageIdx === 0 && palette.categorical[0].toLowerCase() !== (palette.isDark ? '#5d98e7' : '#2864b9')
          ? palette.categorical[0]
          : undefined
      range.push(firstOverride ?? ramp[Math.min(stageIdx, ramp.length - 1)]!)
      stageIdx += 1
    }
  }

  return { domain, range }
}

function interpolateHexLinear(a: string, b: string, t: number): string {
  const parse = (hex: string): [number, number, number] => [
    Number.parseInt(hex.slice(1, 3), 16),
    Number.parseInt(hex.slice(3, 5), 16),
    Number.parseInt(hex.slice(5, 7), 16)
  ]
  if (!/^#[0-9a-fA-F]{6}$/.test(a) || !/^#[0-9a-fA-F]{6}$/.test(b)) return t < 0.5 ? a : b
  const [ar, ag, ab] = parse(a)
  const [br, bg, bb] = parse(b)
  const clamp = (v: number) =>
    Math.round(Math.min(255, Math.max(0, v)))
      .toString(16)
      .padStart(2, '0')
  return `#${clamp(ar + (br - ar) * t)}${clamp(ag + (bg - ag) * t)}${clamp(ab + (bb - ab) * t)}`
}

function samplePiecewiseColor(value: number, domain: readonly number[], range: readonly string[]): string {
  if (domain.length === 0 || range.length === 0) return '#2864b9'
  if (value <= domain[0]!) return range[0]!
  const lastIdx = Math.min(domain.length, range.length) - 1
  if (value >= domain[lastIdx]!) return range[lastIdx]!
  for (let i = 0; i < lastIdx; i += 1) {
    const d0 = domain[i]!
    const d1 = domain[i + 1]!
    if (value >= d0 && value <= d1) {
      const span = d1 - d0
      const t = span === 0 ? 0 : (value - d0) / span
      return interpolateHexLinear(range[i]!, range[i + 1]!, t)
    }
  }
  return range[lastIdx]!
}

function buildHeatmapColorScale(
  rows: readonly Record<string, unknown>[],
  valueField: string,
  palette: VizThemePalette
): { type: 'linear'; domain: number[]; range: string[] } {
  const nums: number[] = []
  for (const row of rows) {
    const val = toFiniteNumber(row[valueField])
    if (val !== null) nums.push(val)
  }

  const hasNegative = nums.some(n => n < 0)
  const hasPositive = nums.some(n => n > 0)

  if (hasNegative && hasPositive) {
    const maxAbs = Math.max(...nums.map(n => Math.abs(n)), 1e-9)
    const stops = palette.diverging.length
    const mid = (stops - 1) / 2
    const domain = Array.from({ length: stops }, (_, idx) => ((idx - mid) / mid) * maxAbs)
    return {
      type: 'linear',
      domain,
      range: [...palette.diverging]
    }
  }

  const minVal = nums.length > 0 ? Math.min(...nums) : 0
  const rawMax = nums.length > 0 ? Math.max(...nums) : 1
  const maxVal = rawMax > minVal ? rawMax : minVal + 1
  const stops = palette.sequential.length
  const domain = Array.from({ length: stops }, (_, idx) => minVal + (idx / Math.max(1, stops - 1)) * (maxVal - minVal))
  return {
    type: 'linear',
    domain,
    range: [...palette.sequential]
  }
}

function buildBaseG2Theme(palette: VizThemePalette): Record<string, unknown> {
  const themeFactory = (palette.isDark ? BASE_CORELIB['theme.classicDark'] : BASE_CORELIB['theme.classic']) as
    | ((options?: Record<string, unknown>) => Record<string, unknown>)
    | undefined
  const base = themeFactory ? themeFactory() : {}
  const baseView = (base.view as Record<string, unknown> | undefined) ?? {}
  const baseAxis = (base.axis as Record<string, unknown> | undefined) ?? {}
  const baseLegendCategory = (base.legendCategory as Record<string, unknown> | undefined) ?? {}
  const baseLegendContinuous = (base.legendContinuous as Record<string, unknown> | undefined) ?? {}
  const baseLabel = (base.label as Record<string, unknown> | undefined) ?? {}
  const baseTitle = (base.title as Record<string, unknown> | undefined) ?? {}
  const baseTooltip = (base.tooltip as { css?: Record<string, Record<string, unknown>> } | undefined) ?? {}
  const baseTooltipCss = baseTooltip.css ?? {}

  return {
    ...base,
    type: palette.isDark ? 'classicDark' : 'classic',
    color: palette.categorical[0],
    category10: [...palette.categorical, ...palette.extendedCategorical],
    category20: [...palette.categorical, ...palette.extendedCategorical],
    view: {
      ...baseView,
      viewFill: palette.background,
      plotFill: 'transparent',
      mainFill: 'transparent',
      contentFill: 'transparent'
    },
    axis: {
      ...baseAxis,
      labelFill: palette.fgSecondary,
      labelOpacity: 1,
      labelFontFamily: palette.fontSans,
      labelFontSize: 11,
      titleFill: palette.foreground,
      titleOpacity: 1,
      titleFontFamily: palette.fontSans,
      lineStroke: palette.border,
      lineStrokeOpacity: 0.72,
      tickStroke: palette.border,
      tickOpacity: 0,
      gridStroke: palette.border,
      gridStrokeOpacity: palette.isDark ? 0.48 : 0.58,
      gridLineDash: [3, 3]
    },
    legendCategory: {
      ...baseLegendCategory,
      itemLabelFill: palette.fgSecondary,
      itemLabelFillOpacity: 1,
      itemLabelFontFamily: palette.fontSans,
      itemLabelFontSize: 11,
      itemValueFill: palette.fgSecondary,
      itemValueFillOpacity: 0.85,
      navButtonFill: palette.fgSecondary,
      navPageNumFill: palette.fgTertiary,
      titleFill: palette.foreground,
      titleFillOpacity: 1,
      titleFontFamily: palette.fontSans
    },
    legendContinuous: {
      ...baseLegendContinuous,
      labelFill: palette.fgSecondary,
      labelFillOpacity: 1,
      titleFill: palette.foreground,
      titleFillOpacity: 1
    },
    label: {
      ...baseLabel,
      fill: palette.fgSecondary,
      fillOpacity: 1,
      fontSize: 11,
      fontFamily: palette.fontSans,
      connectorStroke: palette.borderStrong,
      connectorStrokeOpacity: 0.65
    },
    title: {
      ...baseTitle,
      titleFill: palette.foreground,
      titleFillOpacity: 1,
      titleFontFamily: palette.fontSans,
      subtitleFill: palette.fgSecondary,
      subtitleFillOpacity: 1,
      subtitleFontFamily: palette.fontSans
    },
    tooltip: {
      ...baseTooltip,
      css: {
        ...baseTooltipCss,
        '.g2-tooltip': {
          ...baseTooltipCss['.g2-tooltip'],
          'font-family': palette.fontSans,
          background: palette.layer01,
          color: palette.foreground,
          border: `1px solid ${palette.border}`,
          'box-shadow': '0 4px 12px rgba(0, 0, 0, 0.18)'
        },
        '.g2-tooltip-title': {
          ...baseTooltipCss['.g2-tooltip-title'],
          color: palette.foreground
        },
        '.g2-tooltip-list-item-name-label': {
          ...baseTooltipCss['.g2-tooltip-list-item-name-label'],
          color: palette.fgSecondary
        },
        '.g2-tooltip-list-item-value': {
          ...baseTooltipCss['.g2-tooltip-list-item-value'],
          color: palette.foreground,
          'font-family': palette.fontMono
        }
      }
    }
  }
}

function buildWaterfallRows(rows: readonly Record<string, unknown>[], yField: string): Record<string, unknown>[] {
  let running = 0
  return rows.map(row => {
    const isTotal = Boolean(row.isTotal || row.total)
    const rawVal = toFiniteNumber(row[yField]) ?? 0
    if (isTotal) {
      const end = rawVal !== 0 ? rawVal : running
      running = end
      return {
        ...row,
        [WATERFALL_START_FIELD]: 0,
        [WATERFALL_END_FIELD]: end,
        [WATERFALL_KIND_FIELD]: 'total'
      }
    }
    const start = running
    const end = running + rawVal
    running = end
    return {
      ...row,
      [WATERFALL_START_FIELD]: start,
      [WATERFALL_END_FIELD]: end,
      [WATERFALL_KIND_FIELD]: rawVal >= 0 ? 'up' : 'down'
    }
  })
}

function isRowList(data: StatisticalChartSpec['data']): data is readonly Record<string, unknown>[] {
  return Array.isArray(data)
}

function buildHierarchyRoot(
  data: StatisticalChartSpec['data'],
  labelField: string,
  valueField: string
): Record<string, unknown> {
  if (!isRowList(data)) {
    return data
  }
  return {
    name: 'root',
    children: data.map(row => ({
      name: String(row[labelField] ?? row.name ?? ''),
      value: Math.max(0, toFiniteNumber(row[valueField] ?? row.value) ?? 0)
    }))
  }
}

/**
 * Pure builder translating a `StatisticalChartSpec` and `VizThemePalette` into a native
 * G2 v5 specification (without HTML DOM `<foreignObject>` titles or legends) and reporting
 * any `percent` fallback reason.
 */
export function prepareStatisticalChartSpec(
  spec: StatisticalChartSpec,
  palette: VizThemePalette,
  options?: { disableHtmlTooltip?: boolean; forceNoAnimation?: boolean }
): PreparedStatisticalSpec {
  const xField = spec.xField ?? 'category'
  const yField = spec.yField ?? spec.valueField ?? 'value'
  const valueField = spec.valueField ?? spec.yField ?? 'value'
  const seriesField = spec.seriesField
  const rawRows: readonly Record<string, unknown>[] = Array.isArray(spec.data) ? spec.data : []

  const percentFallbackReason = detectPercentFallbackReason(spec.data, yField, spec.stackMode)
  const effectiveStackMode: StatisticalStackMode | undefined =
    spec.stackMode === 'percent' && percentFallbackReason ? 'stacked' : spec.stackMode

  const baseNormalizedRows =
    effectiveStackMode === 'percent' && Array.isArray(spec.data)
      ? normalizePercentRows(rawRows, xField, yField)
      : rawRows.map(row => {
          if (!seriesField) return row
          const rawSeries = row[seriesField]
          if (rawSeries === null || rawSeries === undefined || rawSeries === '') {
            return { ...row, [seriesField]: 'Empty' }
          }
          return row
        })

  const isPieOrDonut = spec.type === 'pie' || spec.type === 'donut'
  const pieTotal = isPieOrDonut
    ? baseNormalizedRows.reduce((acc, row) => acc + Math.max(0, toFiniteNumber(row[valueField]) ?? 0), 0)
    : 0

  const normalizedRows = isPieOrDonut
    ? baseNormalizedRows.map(row => {
        if (spec.shareTextField && typeof row[spec.shareTextField] === 'string') return row
        const val = Math.max(0, toFiniteNumber(row[valueField]) ?? 0)
        const share = pieTotal > 0 ? val / pieTotal : 0
        return {
          ...row,
          [PIE_SHARE_TEXT_FIELD]: formatPercentageShare(share)
        }
      })
    : baseNormalizedRows

  const activeYField = effectiveStackMode === 'percent' ? PERCENT_SHARE_FIELD : yField
  const tooltipDisabled = Boolean(options?.disableHtmlTooltip || spec.renderer === 'svg')

  const resolveShareText = (row: Record<string, unknown>): string | undefined => {
    if (spec.shareTextField && typeof row[spec.shareTextField] === 'string') {
      return row[spec.shareTextField] as string
    }
    if (effectiveStackMode === 'percent' && typeof row[PERCENT_SHARE_TEXT_FIELD] === 'string') {
      return row[PERCENT_SHARE_TEXT_FIELD] as string
    }
    if (isPieOrDonut && typeof row[PIE_SHARE_TEXT_FIELD] === 'string') {
      return row[PIE_SHARE_TEXT_FIELD] as string
    }
    return undefined
  }

  const cartesianTooltip = tooltipDisabled
    ? false
    : {
        title: (d: Record<string, unknown>) => String(d[xField] ?? ''),
        items: [
          (d: Record<string, unknown>) => ({
            name: seriesField ? String(d[seriesField] ?? '') : (spec.yTitle ?? yField),
            value: formatRowMetricText(
              d,
              yField,
              spec.formattedYField,
              effectiveStackMode === 'percent' ? resolveShareText(d) : undefined
            )
          })
        ]
      }

  const cartesianDataLabels = spec.showDataLabels
    ? [
        {
          text: (d: Record<string, unknown>) =>
            effectiveStackMode === 'percent'
              ? (resolveShareText(d) ?? formatRowMetricText(d, yField, spec.formattedYField))
              : formatRowMetricText(d, yField, spec.formattedYField),
          style: {
            fill: palette.fgSecondary,
            fontSize: 11,
            fontFamily: palette.fontSans,
            ...(spec.type === 'column' || spec.type === 'line' || spec.type === 'area' ? { dy: -8 } : {})
          },
          transform: [{ type: 'overlapHide' }]
        }
      ]
    : undefined

  const hasExplicit1DOptionColors =
    !seriesField &&
    (spec.type === 'column' || spec.type === 'bar') &&
    Boolean(spec.seriesMeta?.some(item => Boolean(item.optionColor)))

  const has1DResidualBuckets =
    !seriesField &&
    (spec.type === 'column' || spec.type === 'bar') &&
    !hasExplicit1DOptionColors &&
    Boolean(
      spec.seriesMeta?.some(item => item.isOther || item.isEmpty) ||
      normalizedRows.some(row => Boolean(row.__isOther) || row[xField] === 'Other' || row[xField] === 'Empty')
    )

  const has1DCategoryColors = hasExplicit1DOptionColors || has1DResidualBuckets

  const colorFieldForPalette =
    seriesField ?? (['pie', 'donut', 'wordcloud'].includes(spec.type) || hasExplicit1DOptionColors ? xField : undefined)

  const colorScale = has1DResidualBuckets
    ? derive1DFocusColorScale(normalizedRows, xField, spec.seriesMeta, palette)
    : deriveColorScale(normalizedRows, colorFieldForPalette, spec.seriesMeta, palette)

  const strokeColorScale = seriesField
    ? deriveColorScale(normalizedRows, seriesField, spec.seriesMeta, palette, { variant: 'stroke' })
    : undefined

  const animateEnabled = options?.forceNoAnimation ? false : (spec.animate ?? spec.renderer !== 'svg')
  const showLegend =
    spec.showLegend ?? Boolean(seriesField || ['pie', 'donut', 'funnel', 'wordcloud'].includes(spec.type))

  const titleConfig =
    spec.type !== 'stat' && (spec.title || spec.subtitle)
      ? {
          title: spec.title,
          subtitle: spec.subtitle ?? undefined,
          titleFill: palette.foreground,
          titleFontFamily: palette.fontSans,
          titleFontSize: 14,
          titleFontWeight: 600,
          subtitleFill: palette.fgSecondary,
          subtitleFontFamily: palette.fontSans,
          subtitleFontSize: 12
        }
      : undefined

  const legendConfig = showLegend
    ? {
        color: {
          position: 'bottom',
          itemLabelFill: palette.fgSecondary,
          itemLabelFontFamily: palette.fontSans
        }
      }
    : false

  const scaleConfig: Record<string, unknown> = {
    ...(colorScale ? { color: { domain: colorScale.domain, range: colorScale.range } } : {}),
    ...(effectiveStackMode === 'percent' ? { y: { domain: [0, 1], nice: false } } : {})
  }

  const xAxisConfig: Record<string, unknown> = {
    title: spec.xTitle ?? false
  }

  const yAxisConfig: Record<string, unknown> = {
    title: spec.yTitle ?? false,
    ...(effectiveStackMode === 'percent' ? { labelFormatter: (val: number) => `${Math.round(val * 100)}%` } : {})
  }

  const buildStackTransforms = (): Record<string, unknown>[] => {
    if (!seriesField) return []
    if (effectiveStackMode === 'stacked' || effectiveStackMode === 'percent') {
      return [{ type: 'stackY' }]
    }
    if (spec.type === 'column' || spec.type === 'bar') {
      return [{ type: 'dodgeX' }]
    }
    return []
  }

  let primaryNode: Record<string, unknown>

  switch (spec.type) {
    case 'column':
    case 'bar': {
      const isStacked = Boolean(seriesField && (effectiveStackMode === 'stacked' || effectiveStackMode === 'percent'))
      primaryNode = {
        type: 'interval',
        data: normalizedRows,
        encode: {
          x: xField,
          y: activeYField,
          ...(seriesField ? { color: seriesField } : has1DCategoryColors ? { color: xField } : {})
        },
        transform: buildStackTransforms(),
        scale: scaleConfig,
        style: isStacked
          ? { stroke: palette.background, lineWidth: 1 }
          : { radius: 2, ...(!seriesField && !has1DCategoryColors ? { fill: palette.categorical[0] } : {}) },
        axis: { x: xAxisConfig, y: yAxisConfig },
        ...(cartesianTooltip !== false ? { tooltip: cartesianTooltip } : {}),
        ...(cartesianDataLabels ? { labels: cartesianDataLabels } : {}),
        ...(spec.type === 'bar' ? { coordinate: { transform: [{ type: 'transpose' }] } } : {}),
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'line': {
      const lineScaleConfig: Record<string, unknown> = {
        ...scaleConfig,
        ...(strokeColorScale ? { color: { domain: strokeColorScale.domain, range: strokeColorScale.range } } : {})
      }
      primaryNode = {
        type: 'line',
        data: normalizedRows,
        encode: {
          x: xField,
          y: activeYField,
          ...(seriesField ? { color: seriesField } : {}),
          ...(spec.smooth ? { shape: 'smooth' } : {})
        },
        transform:
          seriesField && (effectiveStackMode === 'stacked' || effectiveStackMode === 'percent')
            ? [{ type: 'stackY' }]
            : [],
        scale: lineScaleConfig,
        style: {
          lineWidth: 2,
          lineCap: 'round',
          lineJoin: 'round',
          ...(!seriesField ? { stroke: palette.categoricalStrokes[0] } : {})
        },
        axis: { x: xAxisConfig, y: yAxisConfig },
        ...(cartesianTooltip !== false ? { tooltip: cartesianTooltip } : {}),
        ...(cartesianDataLabels ? { labels: cartesianDataLabels } : {}),
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'area': {
      const areaTransforms =
        seriesField && (effectiveStackMode === 'stacked' || effectiveStackMode === 'percent')
          ? [{ type: 'stackY' }]
          : []
      primaryNode = {
        type: 'view',
        data: normalizedRows,
        scale: scaleConfig,
        axis: { x: xAxisConfig, y: yAxisConfig },
        children: [
          {
            type: 'area',
            encode: {
              x: xField,
              y: activeYField,
              ...(seriesField ? { color: seriesField } : {}),
              ...(spec.smooth ? { shape: 'smooth' } : {})
            },
            transform: areaTransforms,
            style: {
              fillOpacity: seriesField ? 0.18 : 0.2,
              ...(!seriesField ? { fill: palette.categorical[0] } : {})
            },
            tooltip: false,
            ...(animateEnabled === false ? { animate: false } : {})
          },
          {
            type: 'line',
            encode: {
              x: xField,
              y: activeYField,
              ...(seriesField ? { color: seriesField } : {}),
              ...(spec.smooth ? { shape: 'smooth' } : {})
            },
            transform: areaTransforms,
            style: {
              lineWidth: 2,
              lineCap: 'round',
              lineJoin: 'round',
              ...(!seriesField ? { stroke: palette.categoricalStrokes[0] } : {})
            },
            ...(cartesianTooltip !== false ? { tooltip: cartesianTooltip } : {}),
            ...(cartesianDataLabels ? { labels: cartesianDataLabels } : {}),
            ...(animateEnabled === false ? { animate: false } : {})
          }
        ]
      }
      break
    }

    case 'combo': {
      const secondaryField = spec.secondaryYField ?? 'secondaryValue'
      const primaryComboTooltip = tooltipDisabled
        ? false
        : {
            title: (d: Record<string, unknown>) => String(d[xField] ?? ''),
            items: [
              (d: Record<string, unknown>) => ({
                name: seriesField ? String(d[seriesField] ?? '') : (spec.yTitle ?? yField),
                value: formatRowMetricText(d, yField, spec.formattedYField)
              })
            ]
          }
      const secondaryComboTooltip = tooltipDisabled
        ? false
        : {
            title: (d: Record<string, unknown>) => String(d[xField] ?? ''),
            items: [
              (d: Record<string, unknown>) => ({
                name: spec.secondaryYTitle ?? secondaryField,
                value: formatRowMetricText(d, secondaryField, spec.formattedSecondaryYField)
              })
            ]
          }
      primaryNode = {
        type: 'view',
        data: normalizedRows,
        ...(seriesField ? { scale: scaleConfig } : {}),
        children: [
          {
            type: 'interval',
            encode: {
              x: xField,
              y: yField,
              ...(seriesField ? { color: seriesField } : {})
            },
            ...(seriesField ? { transform: buildStackTransforms() } : {}),
            style: {
              ...(!seriesField ? { fill: palette.categorical[0] } : {}),
              fillOpacity: 0.84,
              radius: 2
            },
            axis: { x: xAxisConfig, y: { title: spec.yTitle ?? false } },
            ...(primaryComboTooltip !== false ? { tooltip: primaryComboTooltip } : {}),
            ...(cartesianDataLabels ? { labels: cartesianDataLabels } : {}),
            ...(animateEnabled === false ? { animate: false } : {})
          },
          {
            type: 'line',
            encode: {
              x: xField,
              y: secondaryField,
              ...(spec.smooth ? { shape: 'smooth' } : {})
            },
            scale: { y: { independent: true } },
            style: {
              stroke: palette.categoricalStrokes[2],
              lineWidth: 2.2,
              lineCap: 'round',
              lineJoin: 'round'
            },
            axis: { x: false, y: { position: 'right', grid: null, title: spec.secondaryYTitle ?? false } },
            ...(secondaryComboTooltip !== false ? { tooltip: secondaryComboTooltip } : {}),
            ...(animateEnabled === false ? { animate: false } : {})
          }
        ]
      }
      break
    }

    case 'pie':
    case 'donut': {
      const categoryKey = seriesField ?? xField
      const thetaCoordinate = {
        type: 'theta',
        outerRadius: 0.86,
        ...(spec.type === 'donut' ? { innerRadius: 0.62 } : {})
      }
      const pieTooltip = tooltipDisabled
        ? false
        : {
            title: (d: Record<string, unknown>) => String(d[categoryKey] ?? ''),
            items: [
              (d: Record<string, unknown>) => ({
                name: spec.yTitle ?? valueField,
                value: formatRowMetricText(d, valueField, spec.formattedYField, resolveShareText(d))
              })
            ]
          }
      const pieLabels = spec.showDataLabels
        ? [
            {
              text: (d: Record<string, unknown>) =>
                resolveShareText(d) ?? formatRowMetricText(d, valueField, spec.formattedYField),
              position: 'outside',
              style: {
                fill: palette.fgSecondary,
                fontSize: 11,
                fontFamily: palette.fontSans
              },
              transform: [{ type: 'overlapHide' }]
            }
          ]
        : undefined
      const intervalNode: Record<string, unknown> = {
        type: 'interval',
        data: normalizedRows,
        encode: {
          y: valueField,
          color: categoryKey
        },
        transform: [{ type: 'stackY' }],
        scale: scaleConfig,
        style: {
          stroke: palette.background,
          lineWidth: 1.5
        },
        axis: false,
        ...(pieTooltip !== false ? { tooltip: pieTooltip } : {}),
        ...(pieLabels ? { labels: pieLabels } : {}),
        ...(animateEnabled === false ? { animate: false } : {})
      }
      if (spec.type === 'donut' && spec.donutCenterLabel && normalizedRows.length > 0) {
        const hasCenterTitle = Boolean(spec.donutCenterLabel.title)
        const centerMarks: Record<string, unknown>[] = [
          {
            type: 'text',
            style: {
              text: spec.donutCenterLabel.value,
              x: '50%',
              y: hasCenterTitle ? '46%' : '50%',
              textAlign: 'center',
              textBaseline: 'middle',
              fontSize: 18,
              fontWeight: 600,
              fontFamily: palette.fontMono || palette.fontSans,
              fill: palette.foreground
            },
            tooltip: false,
            ...(animateEnabled === false ? { animate: false } : {})
          },
          ...(hasCenterTitle
            ? [
                {
                  type: 'text',
                  style: {
                    text: spec.donutCenterLabel.title,
                    x: '50%',
                    y: '58%',
                    textAlign: 'center',
                    textBaseline: 'middle',
                    fontSize: 11,
                    fontWeight: 500,
                    fontFamily: palette.fontSans,
                    fill: palette.fgSecondary
                  },
                  tooltip: false,
                  ...(animateEnabled === false ? { animate: false } : {})
                }
              ]
            : [])
        ]
        primaryNode = {
          type: 'view',
          coordinate: thetaCoordinate,
          children: [intervalNode, ...centerMarks]
        }
      } else {
        primaryNode = {
          ...intervalNode,
          coordinate: thetaCoordinate
        }
      }
      break
    }

    case 'funnel': {
      const categoryKey = seriesField ?? xField
      const funnelColorScale = deriveFunnelOrderedScale(normalizedRows, categoryKey, spec.seriesMeta, palette)
      const stageColorMap = new Map(funnelColorScale.domain.map((k, idx) => [k, funnelColorScale.range[idx]!]))
      const funnelTooltip = tooltipDisabled
        ? false
        : {
            title: (d: Record<string, unknown>) => String(d[categoryKey] ?? ''),
            items: [
              (d: Record<string, unknown>) => ({
                name: spec.yTitle ?? valueField,
                value: formatRowMetricText(d, valueField, spec.formattedYField)
              })
            ]
          }
      const funnelLabels = spec.showDataLabels
        ? [
            {
              text: (d: Record<string, unknown>) =>
                `${String(d[categoryKey] ?? '')}: ${formatRowMetricText(d, valueField, spec.formattedYField)}`,
              position: 'inside',
              style: {
                fill: (d: Record<string, unknown>) => {
                  const raw = d[categoryKey]
                  const key = raw === null || raw === undefined || raw === '' ? 'Empty' : String(raw)
                  return pickReadableDataLabelInk(stageColorMap.get(key) ?? palette.categorical[0])
                },
                fontSize: 11,
                fontFamily: palette.fontSans
              },
              transform: [{ type: 'overlapHide' }]
            }
          ]
        : undefined
      primaryNode = {
        type: 'interval',
        data: normalizedRows,
        encode: {
          x: xField,
          y: valueField,
          color: categoryKey,
          shape: 'funnel'
        },
        transform: [{ type: 'symmetryY' }],
        coordinate: { transform: [{ type: 'transpose' }] },
        scale: {
          ...scaleConfig,
          ...(funnelColorScale.domain.length > 0
            ? { color: { domain: funnelColorScale.domain, range: funnelColorScale.range } }
            : {})
        },
        style: {
          stroke: palette.background,
          lineWidth: 1.5
        },
        axis: false,
        ...(funnelTooltip !== false ? { tooltip: funnelTooltip } : {}),
        ...(funnelLabels ? { labels: funnelLabels } : {}),
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'scatter': {
      const scatterTooltip = tooltipDisabled
        ? false
        : {
            title: (d: Record<string, unknown>) =>
              seriesField ? String(d[seriesField] ?? '') : String(spec.title ?? ''),
            items: [
              (d: Record<string, unknown>) => ({
                name: spec.xTitle ?? xField,
                value: formatRowMetricText(d, xField)
              }),
              (d: Record<string, unknown>) => ({
                name: spec.yTitle ?? yField,
                value: formatRowMetricText(d, yField, spec.formattedYField)
              }),
              ...(spec.sizeField
                ? [
                    (d: Record<string, unknown>) => ({
                      name: spec.sizeTitle ?? spec.sizeField!,
                      value: formatRowMetricText(d, spec.sizeField!)
                    })
                  ]
                : [])
            ]
          }
      primaryNode = {
        type: 'point',
        data: normalizedRows,
        encode: {
          x: xField,
          y: yField,
          shape: 'point',
          ...(seriesField ? { color: seriesField } : {}),
          ...(spec.sizeField ? { size: spec.sizeField } : {})
        },
        scale: scaleConfig,
        style: {
          fillOpacity: 0.62,
          lineWidth: 1.2,
          ...(!seriesField ? { fill: palette.categorical[0], stroke: palette.categoricalStrokes[0] } : {})
        },
        axis: { x: xAxisConfig, y: { title: spec.yTitle ?? false } },
        ...(scatterTooltip !== false ? { tooltip: scatterTooltip } : {}),
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'histogram': {
      primaryNode = {
        type: 'rect',
        data: normalizedRows,
        encode: { x: spec.xField ?? yField },
        transform: [{ type: 'binX', y: 'count' }],
        style: { inset: 0.75, radius: 2, fill: palette.categorical[0] },
        axis: { x: xAxisConfig, y: yAxisConfig },
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'boxplot': {
      primaryNode = {
        type: 'boxplot',
        data: normalizedRows,
        encode: {
          x: xField,
          y: yField,
          ...(seriesField ? { color: seriesField } : {})
        },
        scale: scaleConfig,
        axis: { x: xAxisConfig, y: yAxisConfig },
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'heatmap': {
      const heatmapColorScale = buildHeatmapColorScale(normalizedRows, valueField, palette)
      const heatmapTooltip = tooltipDisabled
        ? false
        : {
            title: (d: Record<string, unknown>) => `${String(d[xField] ?? '')} · ${String(d[yField] ?? '')}`,
            items: [
              (d: Record<string, unknown>) => ({
                name: spec.yTitle ?? valueField,
                value: formatRowMetricText(d, valueField, spec.formattedYField)
              })
            ]
          }
      const heatmapLabels = spec.showDataLabels
        ? [
            {
              text: (d: Record<string, unknown>) => formatRowMetricText(d, valueField, spec.formattedYField),
              position: 'inside',
              style: {
                fill: (d: Record<string, unknown>) => {
                  const num = toFiniteNumber(d[valueField]) ?? 0
                  const cellHex = samplePiecewiseColor(num, heatmapColorScale.domain, heatmapColorScale.range)
                  return pickReadableDataLabelInk(cellHex)
                },
                fontSize: 11,
                fontFamily: palette.fontMono || palette.fontSans
              },
              transform: [{ type: 'overlapHide' }]
            }
          ]
        : undefined
      primaryNode = {
        type: 'cell',
        data: normalizedRows,
        encode: {
          x: xField,
          y: yField,
          color: valueField
        },
        scale: {
          color: heatmapColorScale
        },
        style: { inset: 1, radius: 2 },
        axis: { x: xAxisConfig, y: { title: spec.yTitle ?? false } },
        ...(heatmapTooltip !== false ? { tooltip: heatmapTooltip } : {}),
        ...(heatmapLabels ? { labels: heatmapLabels } : {}),
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'radar': {
      primaryNode = {
        type: 'view',
        data: normalizedRows,
        coordinate: { type: 'polar' },
        scale: {
          ...scaleConfig,
          x: { padding: 0.5, align: 0 }
        },
        children: [
          {
            type: 'area',
            encode: {
              x: xField,
              y: yField,
              ...(seriesField ? { color: seriesField } : {})
            },
            style: {
              fillOpacity: 0.2,
              ...(!seriesField ? { fill: palette.categorical[0] } : {})
            },
            ...(animateEnabled === false ? { animate: false } : {})
          },
          {
            type: 'line',
            encode: {
              x: xField,
              y: yField,
              ...(seriesField ? { color: seriesField } : {})
            },
            style: {
              lineWidth: 2,
              lineJoin: 'round',
              ...(!seriesField ? { stroke: palette.categoricalStrokes[0] } : {})
            },
            ...(animateEnabled === false ? { animate: false } : {})
          }
        ]
      }
      break
    }

    case 'waterfall': {
      const wfRows = buildWaterfallRows(rawRows, yField)
      const wfTooltip = tooltipDisabled
        ? false
        : {
            title: (d: Record<string, unknown>) => String(d[xField] ?? ''),
            items: [
              (d: Record<string, unknown>) => ({
                name: spec.yTitle ?? yField,
                value: formatRowMetricText(d, yField, spec.formattedYField)
              })
            ]
          }
      primaryNode = {
        type: 'interval',
        data: wfRows,
        encode: {
          x: xField,
          y: [WATERFALL_START_FIELD, WATERFALL_END_FIELD],
          color: WATERFALL_KIND_FIELD
        },
        scale: {
          color: {
            domain: ['up', 'down', 'total'],
            range: [palette.up, palette.down, palette.totalColor]
          }
        },
        style: { radius: 2 },
        axis: { x: xAxisConfig, y: yAxisConfig },
        ...(wfTooltip !== false ? { tooltip: wfTooltip } : {}),
        ...(cartesianDataLabels ? { labels: cartesianDataLabels } : {}),
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'gauge': {
      const gaugeDatum = Array.isArray(spec.data) ? (spec.data[0] ?? {}) : spec.data
      const target = toFiniteNumber(gaugeDatum.target ?? gaugeDatum[valueField]) ?? 0
      const total = toFiniteNumber(gaugeDatum.total ?? 100) ?? 100
      const name = String(gaugeDatum.name ?? gaugeDatum[xField] ?? spec.title ?? '')
      primaryNode = {
        type: 'gauge',
        data: {
          value: {
            target,
            total,
            name
          }
        },
        scale: {
          color: {
            range: [palette.categorical[0], palette.isDark ? palette.layer02 : palette.emptyColor]
          }
        },
        style: {
          pinFill: palette.background,
          textFill: palette.foreground,
          textFontFamily: palette.fontMono || palette.fontSans,
          textFontWeight: 600
        },
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'treemap': {
      primaryNode = {
        type: 'treemap',
        data: {
          value: buildHierarchyRoot(spec.data, xField, valueField)
        },
        encode: { value: 'value' },
        style: {
          rectStroke: palette.background,
          rectLineWidth: 1.5
        },
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'sunburst': {
      primaryNode = {
        type: 'partition',
        data: [buildHierarchyRoot(spec.data, xField, valueField)],
        encode: { value: 'value', name: 'name' },
        coordinate: { type: 'polar', innerRadius: 0.2 },
        style: {
          stroke: palette.background,
          lineWidth: 1.5
        },
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'sankey': {
      const sourceField = spec.sourceField ?? 'source'
      const targetField = spec.targetField ?? 'target'
      const links = Array.isArray(spec.data)
        ? spec.data.map(row => ({
            source: String(row[sourceField] ?? ''),
            target: String(row[targetField] ?? ''),
            value: Math.max(0, toFiniteNumber(row[valueField]) ?? 0)
          }))
        : ((spec.data as { links?: unknown[] }).links ?? [])
      primaryNode = {
        type: 'sankey',
        data: { value: { links } },
        layout: { nodeAlign: 'justify', nodePadding: 0.03 },
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'wordcloud': {
      primaryNode = {
        type: 'wordCloud',
        data: normalizedRows,
        encode: {
          text: spec.xField ?? 'text',
          value: valueField,
          color: seriesField ?? spec.xField ?? 'text'
        },
        scale: scaleConfig,
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'quantile_band': {
      const lowField = spec.bandLowField
      const highField = spec.bandHighField
      const hasBand = Boolean(lowField && highField)
      const bandName = spec.bandLabel ?? (lowField && highField ? `${lowField}–${highField}` : (spec.yTitle ?? yField))

      const quantileTooltip = tooltipDisabled
        ? false
        : {
            title: (d: Record<string, unknown>) => String(d[xField] ?? ''),
            items: [
              ...(hasBand
                ? [
                    (d: Record<string, unknown>) => ({
                      name: seriesField ? `${String(d[seriesField] ?? '')} · ${bandName}` : bandName,
                      value: `${formatFallbackNumeric(d[lowField!])} – ${formatFallbackNumeric(d[highField!])}`
                    })
                  ]
                : []),
              (d: Record<string, unknown>) => ({
                name: seriesField
                  ? `${String(d[seriesField] ?? '')} · ${spec.yTitle ?? yField}`
                  : (spec.yTitle ?? yField),
                value: formatRowMetricText(d, yField, spec.formattedYField)
              })
            ]
          }

      const quantileChildren: Record<string, unknown>[] = []

      if (hasBand) {
        quantileChildren.push({
          type: 'area',
          encode: {
            x: xField,
            y: highField,
            y1: lowField,
            ...(seriesField ? { color: seriesField } : {}),
            ...(spec.smooth ? { shape: 'smooth' } : {})
          },
          style: {
            fillOpacity: seriesField ? 0.14 : 0.16,
            ...(seriesField ? {} : { fill: palette.categorical[0] })
          },
          tooltip: false,
          ...(animateEnabled === false ? { animate: false } : {})
        })
      }

      quantileChildren.push({
        type: 'line',
        encode: {
          x: xField,
          y: activeYField,
          ...(seriesField ? { color: seriesField } : {}),
          ...(spec.smooth ? { shape: 'smooth' } : {})
        },
        style: {
          lineWidth: 2,
          lineCap: 'round',
          lineJoin: 'round',
          ...(seriesField ? {} : { stroke: palette.categoricalStrokes[0] })
        },
        ...(quantileTooltip !== false ? { tooltip: quantileTooltip } : {}),
        ...(cartesianDataLabels ? { labels: cartesianDataLabels } : {}),
        ...(animateEnabled === false ? { animate: false } : {})
      })

      primaryNode = {
        type: 'view',
        data: normalizedRows,
        scale: scaleConfig,
        axis: { x: xAxisConfig, y: yAxisConfig },
        children: quantileChildren
      }
      break
    }

    case 'stat': {
      primaryNode = {
        type: 'view',
        padding: 0,
        children: buildStatChartMarks(spec, palette, animateEnabled !== false)
      }
      break
    }
  }

  const refLineNodes = (spec.type === 'stat' ? [] : (spec.referenceLines ?? [])).map(refLine => ({
    type: refLine.axis === 'x' ? 'lineX' : 'lineY',
    data: [refLine.value],
    tooltip: false,
    style: {
      stroke: refLine.color ?? palette.borderStrong,
      lineDash: [4, 4],
      lineWidth: 1.5
    },
    ...(refLine.label
      ? {
          labels: [
            {
              text: refLine.label,
              position: 'right',
              fill: refLine.color ?? palette.fgSecondary,
              fontSize: 11,
              fontFamily: palette.fontSans
            }
          ]
        }
      : {})
  }))

  let rootSpec: Record<string, unknown>
  if (refLineNodes.length > 0) {
    if (primaryNode.type === 'view' && Array.isArray(primaryNode.children)) {
      rootSpec = {
        ...primaryNode,
        children: [...(primaryNode.children as unknown[]), ...refLineNodes]
      }
    } else {
      rootSpec = {
        type: 'view',
        children: [primaryNode, ...refLineNodes]
      }
    }
  } else {
    rootSpec = primaryNode
  }

  const g2Spec: Record<string, unknown> = {
    ...rootSpec,
    ...(spec.width ? { width: spec.width } : {}),
    ...(spec.height ? { height: spec.height } : {}),
    theme: buildBaseG2Theme(palette),
    ...(titleConfig ? { title: titleConfig } : {}),
    legend: legendConfig,
    ...(options?.disableHtmlTooltip || spec.renderer === 'svg' ? { interaction: { tooltip: false } } : {}),
    ...spec.g2Options
  }

  return {
    g2Spec: g2Spec as G2Spec,
    effectiveStackMode,
    percentFallbackReason
  }
}

async function svgMarkupToPngDataUrl(svgMarkup: string, width: number, height: number, dpr: number): Promise<string> {
  if (typeof document === 'undefined' || typeof Image === 'undefined') {
    throw new Error('PNG rasterization requires a browser DOM environment.')
  }
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(width * dpr))
  canvas.height = Math.max(1, Math.round(height * dpr))
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('Failed to acquire 2D canvas context.')
  ctx.scale(dpr, dpr)

  const url = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svgMarkup)}`
  await new Promise<void>((resolve, reject) => {
    const img = new Image()
    img.onload = () => {
      ctx.drawImage(img, 0, 0, width, height)
      resolve()
    }
    img.onerror = () => reject(new Error('Failed to load SVG into Image for PNG export.'))
    img.src = url
  })
  return canvas.toDataURL('image/png')
}

/**
 * Mounts an interactive or Print-Safe SVG statistical chart inside `host` using Ankole's
 * tree-shaken G2 v5 runtime.
 */
export async function mountStatisticalChart(
  host: HTMLElement,
  initialSpec: StatisticalChartSpec
): Promise<MountedStatisticalChart> {
  let currentSpec = initialSpec
  const rect = host.getBoundingClientRect()
  let currentWidth = initialSpec.width ?? Math.max(320, Math.round(rect.width) || 640)
  let currentHeight = initialSpec.height ?? Math.max(220, Math.round(rect.height) || 320)

  let palette = resolveVizTheme(host, {
    theme: currentSpec.theme,
    marketConvention: currentSpec.marketConvention,
    tokenOverrides: currentSpec.tokenOverrides
  })

  const useSvgRenderer = currentSpec.renderer === 'svg'
  host.replaceChildren()
  const chart = new RuntimeChart({
    container: host,
    width: currentWidth,
    height: currentHeight,
    autoFit: false,
    ...(useSvgRenderer ? { renderer: new SVGRenderer() as never } : {})
  })

  let prepared = prepareStatisticalChartSpec({ ...currentSpec, width: currentWidth, height: currentHeight }, palette, {
    forceNoAnimation: useSvgRenderer
  })

  const handleElementClick = (event: { data?: { data?: Record<string, unknown> } | Record<string, unknown> }) => {
    if (!currentSpec.onElementClick) return
    const rawData = event?.data
    const datum =
      rawData && typeof rawData === 'object' && 'data' in rawData && rawData.data && typeof rawData.data === 'object'
        ? (rawData.data as Record<string, unknown>)
        : (rawData as Record<string, unknown> | undefined)
    if (datum && typeof datum === 'object') {
      currentSpec.onElementClick(datum, event)
    }
  }

  chart.on('element:click', handleElementClick)
  chart.options(prepared.g2Spec)
  await chart.render()

  let destroyed = false

  const serializeLiveOrOffscreenSvg = async (): Promise<string> => {
    if (useSvgRenderer) {
      const svgEl = host.querySelector('svg')
      if (svgEl) {
        const raw = new XMLSerializer().serializeToString(svgEl)
        return sanitizeExportedSvg(raw, palette, { safetyPaddingPx: 8 })
      }
    }

    const tempHost = document.createElement('div')
    tempHost.style.cssText = `position:fixed;left:-99999px;top:-99999px;width:${currentWidth}px;height:${currentHeight}px;pointer-events:none;`
    document.body.appendChild(tempHost)
    const tempChart = new RuntimeChart({
      container: tempHost,
      width: currentWidth,
      height: currentHeight,
      autoFit: false,
      renderer: new SVGRenderer() as never
    })
    try {
      const exportPrepared = prepareStatisticalChartSpec(
        { ...currentSpec, width: currentWidth, height: currentHeight, renderer: 'svg' },
        palette,
        { disableHtmlTooltip: true, forceNoAnimation: true }
      )
      tempChart.options(exportPrepared.g2Spec)
      await tempChart.render()
      const svgEl = tempHost.querySelector('svg')
      if (!svgEl) {
        throw new Error('Failed to serialize G2 SVG output.')
      }
      const raw = new XMLSerializer().serializeToString(svgEl)
      return sanitizeExportedSvg(raw, palette, { safetyPaddingPx: 8 })
    } finally {
      tempChart.destroy()
      tempHost.remove()
    }
  }

  return {
    get percentFallbackReason() {
      return prepared.percentFallbackReason
    },
    async update(nextSpec: StatisticalChartSpec) {
      if (destroyed) return
      currentSpec = nextSpec
      if (nextSpec.width) currentWidth = nextSpec.width
      if (nextSpec.height) currentHeight = nextSpec.height
      palette = resolveVizTheme(host, {
        theme: currentSpec.theme,
        marketConvention: currentSpec.marketConvention,
        tokenOverrides: currentSpec.tokenOverrides
      })
      prepared = prepareStatisticalChartSpec({ ...currentSpec, width: currentWidth, height: currentHeight }, palette, {
        forceNoAnimation: useSvgRenderer
      })
      chart.clear(false)
      chart.options(prepared.g2Spec)
      await chart.render()
    },
    async resize(width: number, height: number) {
      if (destroyed) return
      const nextW = Math.max(120, Math.round(width))
      const nextH = Math.max(120, Math.round(height))
      if (nextW === currentWidth && nextH === currentHeight) return
      currentWidth = nextW
      currentHeight = nextH
      await chart.changeSize(currentWidth, currentHeight)
    },
    async exportSVG() {
      if (destroyed) throw new Error('Chart instance has been destroyed.')
      return serializeLiveOrOffscreenSvg()
    },
    async exportPNG(dpr = 2) {
      if (destroyed) throw new Error('Chart instance has been destroyed.')
      if (!useSvgRenderer) {
        const canvasEl = host.querySelector('canvas')
        if (canvasEl) {
          return canvasEl.toDataURL('image/png')
        }
      }
      const svg = await serializeLiveOrOffscreenSvg()
      return svgMarkupToPngDataUrl(svg, currentWidth, currentHeight, dpr)
    },
    destroy() {
      if (destroyed) return
      destroyed = true
      chart.off('element:click', handleElementClick)
      chart.destroy()
    }
  }
}
