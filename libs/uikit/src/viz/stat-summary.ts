import { formatFallbackNumeric, toFiniteNumber } from './format'
import type { StatisticalChartSpec } from './statistical'

export type StatTrendDirection = 'up' | 'down' | 'neutral'

export interface StatChartParts {
  valueText: string
  unit: string | undefined
  comparisonText: string
  trend: StatTrendDirection
}

/**
 * Resolves the trend of a `stat` comparison. An explicit trend from the spec or data wins;
 * otherwise the sign of the comparison value decides. Formatted comparisons such as `12.4%`
 * or `1,204` are parsed like `AnkoleStatCard` does, and `cn` conventions are already applied
 * by the palette.
 */
export function resolveStatTrend(explicit: unknown, comparison: unknown): StatTrendDirection {
  if (explicit === 'up' || explicit === 'down' || explicit === 'neutral') return explicit

  const number = toFiniteNumber(comparison)
  if (number !== null) return trendOf(number)

  if (typeof comparison === 'string') {
    const trimmed = comparison.trim()
    const formatted = Number.parseFloat(trimmed.replace(/[,%]/g, ''))
    if (Number.isFinite(formatted)) return trendOf(formatted)
    if (trimmed.startsWith('+') || trimmed.startsWith('▲')) return 'up'
    if (/^[-−]/.test(trimmed) || trimmed.startsWith('▼')) return 'down'
  }
  return 'neutral'
}

function trendOf(value: number): StatTrendDirection {
  if (value > 0) return 'up'
  if (value < 0) return 'down'
  return 'neutral'
}

/** Formats the comparison of a `stat` card without a leading direction glyph. */
export function formatStatComparison(comparison: unknown): string {
  if (typeof comparison === 'number' && Number.isFinite(comparison)) {
    return `${comparison > 0 ? '+' : ''}${comparison}`
  }
  if (typeof comparison === 'string') return comparison.replace(/^[▲▼]\s*/, '').trim()
  return ''
}

/** Returns the direction glyph shown beside a `stat` comparison. */
export function statTrendGlyph(trend: StatTrendDirection): string {
  if (trend === 'up') return '▲'
  if (trend === 'down') return '▼'
  return '—'
}

/**
 * Reads the single metric of a `stat` chart from its first data row, whether `data` is an
 * array of rows or one row object.
 */
export function statChartParts(spec: StatisticalChartSpec): StatChartParts {
  const row = (Array.isArray(spec.data) ? spec.data[0] : spec.data) ?? {}
  const valueField = spec.valueField ?? spec.yField ?? 'value'
  const formattedValue = spec.formattedValueField ? row[spec.formattedValueField] : undefined
  const comparison = spec.comparisonField ? row[spec.comparisonField] : undefined

  return {
    valueText:
      typeof formattedValue === 'string' && formattedValue !== ''
        ? formattedValue
        : formatFallbackNumeric(row[valueField]),
    unit: typeof spec.unit === 'string' ? spec.unit.trim() || undefined : undefined,
    comparisonText: formatStatComparison(comparison),
    trend: resolveStatTrend(spec.trendField ? row[spec.trendField] : undefined, comparison)
  }
}

/**
 * Describes the metric of a `stat` chart in one sentence for assistive technology. The
 * rendered G2 text is presentational inside the figure's `role="img"`, so the label carries
 * the value, unit, and comparison that the card shows.
 */
export function describeStatChart(spec: StatisticalChartSpec): string {
  const { valueText, unit, comparisonText, trend } = statChartParts(spec)
  const value = unit ? `${valueText} ${unit}` : valueText
  const comparison = comparisonText ? `${statTrendGlyph(trend)} ${comparisonText}` : ''
  const details = [comparison, spec.subtitle ? `(${spec.subtitle})` : ''].filter(Boolean).join(' ')
  const metric = details ? `${value}${comparison ? ', ' : ' '}${details}` : value
  return spec.title ? `${spec.title}: ${metric}` : metric
}
