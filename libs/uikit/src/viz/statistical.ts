import { Renderer as SVGRenderer } from '@antv/g-svg'
import { corelib, extend, graphlib, plotlib, Runtime, type G2Spec } from '@antv/g2'
import {
  assignSeriesColors,
  resolveVizTheme,
  sanitizeExportedSvg,
  type MarketConvention,
  type SeriesColorDescriptor,
  type VizThemeMode,
  type VizThemePalette
} from './theme'

const RuntimeChart = extend(Runtime, {
  ...corelib(),
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

export type StatisticalChartType = StatisticalChartTier1Type | StatisticalChartTier2Type

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

function formatFallbackNumeric(raw: unknown): string {
  const num = toFiniteNumber(raw)
  if (num !== null) {
    return new Intl.NumberFormat(undefined, { maximumFractionDigits: 4 }).format(num)
  }
  if (raw === null || raw === undefined || raw === '') return '—'
  return String(raw)
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

function toFiniteNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value)
    if (Number.isFinite(parsed)) return parsed
  }
  return null
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
  palette: VizThemePalette
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
  const assigned = assignSeriesColors(descriptors, palette)
  return {
    domain: [...assigned.keys()],
    range: [...assigned.values()]
  }
}

function buildBaseG2Theme(palette: VizThemePalette): Record<string, unknown> {
  return {
    type: palette.isDark ? 'classicDark' : 'classic',
    color: palette.categorical[0],
    category10: [...palette.categorical, ...palette.extendedCategorical],
    category20: [...palette.categorical, ...palette.extendedCategorical],
    view: {
      viewFill: palette.background,
      plotFill: 'transparent',
      mainFill: 'transparent',
      contentFill: 'transparent'
    },
    axis: {
      labelFill: palette.fgSecondary,
      labelFontFamily: palette.fontSans,
      labelFontSize: 11,
      titleFill: palette.foreground,
      titleFontFamily: palette.fontSans,
      lineStroke: palette.border,
      tickStroke: palette.border,
      gridStroke: palette.border,
      gridLineDash: [3, 3]
    },
    legendCategory: {
      itemLabelFill: palette.fgSecondary,
      itemLabelFontFamily: palette.fontSans,
      itemLabelFontSize: 11,
      titleFill: palette.foreground,
      titleFontFamily: palette.fontSans
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

  const has1DCategoryColors =
    !seriesField &&
    (spec.type === 'column' || spec.type === 'bar') &&
    Boolean(spec.seriesMeta?.some(item => item.optionColor || item.isOther || item.isEmpty))

  const colorFieldForPalette =
    seriesField ??
    (['pie', 'donut', 'funnel', 'wordcloud'].includes(spec.type) || has1DCategoryColors ? xField : undefined)
  const colorScale = deriveColorScale(normalizedRows, colorFieldForPalette, spec.seriesMeta, palette)

  const animateEnabled = options?.forceNoAnimation ? false : (spec.animate ?? spec.renderer !== 'svg')
  const showLegend =
    spec.showLegend ?? Boolean(seriesField || ['pie', 'donut', 'funnel', 'wordcloud'].includes(spec.type))

  const titleConfig =
    spec.title || spec.subtitle
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

  const yAxisConfig =
    effectiveStackMode === 'percent' ? { labelFormatter: (val: number) => `${Math.round(val * 100)}%` } : true

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
        axis: { x: true, y: yAxisConfig },
        ...(cartesianTooltip !== false ? { tooltip: cartesianTooltip } : {}),
        ...(cartesianDataLabels ? { labels: cartesianDataLabels } : {}),
        ...(spec.type === 'bar' ? { coordinate: { transform: [{ type: 'transpose' }] } } : {}),
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'line': {
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
        scale: scaleConfig,
        style: { lineWidth: 2 },
        axis: { x: true, y: yAxisConfig },
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
        axis: { x: true, y: yAxisConfig },
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
            style: { fillOpacity: 0.24 },
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
            style: { lineWidth: 2 },
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
        children: [
          {
            type: 'interval',
            encode: {
              x: xField,
              y: yField,
              ...(seriesField ? { color: seriesField } : {})
            },
            style: { fill: palette.categorical[0] },
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
            style: { stroke: palette.categorical[2], lineWidth: 2 },
            axis: { y: { position: 'right', grid: null } },
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
        outerRadius: 0.85,
        ...(spec.type === 'donut' ? { innerRadius: 0.56 } : {})
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
                fill: '#ffffff',
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
        scale: scaleConfig,
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
          ...(seriesField ? { color: seriesField } : {}),
          ...(spec.sizeField ? { size: spec.sizeField } : {})
        },
        scale: scaleConfig,
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
        style: { inset: 0.5, fill: palette.categorical[2] },
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
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'heatmap': {
      primaryNode = {
        type: 'cell',
        data: normalizedRows,
        encode: {
          x: xField,
          y: yField,
          color: valueField
        },
        style: { inset: 0.5 },
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
            style: { fillOpacity: 0.22 },
            ...(animateEnabled === false ? { animate: false } : {})
          },
          {
            type: 'line',
            encode: {
              x: xField,
              y: yField,
              ...(seriesField ? { color: seriesField } : {})
            },
            style: { lineWidth: 2 },
            ...(animateEnabled === false ? { animate: false } : {})
          }
        ]
      }
      break
    }

    case 'waterfall': {
      const wfRows = buildWaterfallRows(rawRows, yField)
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
            range: [palette.up, palette.down, palette.categorical[2]]
          }
        },
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
        ...(animateEnabled === false ? { animate: false } : {})
      }
      break
    }

    case 'sunburst': {
      primaryNode = {
        type: 'partition',
        data: {
          value: buildHierarchyRoot(spec.data, xField, valueField)
        },
        encode: { value: 'value' },
        coordinate: { type: 'polar', innerRadius: 0.2 },
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
  }

  const refLineNodes = (spec.referenceLines ?? []).map(refLine => ({
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
