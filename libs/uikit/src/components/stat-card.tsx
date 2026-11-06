import type { ReactNode } from 'react'
import { cn } from '../lib/utils'
import type { MarketConvention } from '../viz/theme'

export type StatTrendDirection = 'up' | 'down' | 'neutral'

export interface AnkoleSparklineProps {
  values: readonly number[]
  width?: number
  height?: number
  trend?: StatTrendDirection
  marketConvention?: MarketConvention
  showArea?: boolean
  ariaLabel?: string
  className?: string
}

function inferTrendFromValues(values: readonly number[]): StatTrendDirection {
  const finite = values.filter(v => Number.isFinite(v))
  if (finite.length < 2) return 'neutral'
  const first = finite[0]!
  const last = finite[finite.length - 1]!
  if (last > first) return 'up'
  if (last < first) return 'down'
  return 'neutral'
}

function inferTrendFromDelta(delta: string | number | null | undefined): StatTrendDirection {
  if (typeof delta === 'number') {
    if (delta > 0) return 'up'
    if (delta < 0) return 'down'
    return 'neutral'
  }
  if (typeof delta === 'string') {
    const trimmed = delta.trim()
    if (trimmed.startsWith('+') || trimmed.startsWith('▲')) return 'up'
    if (trimmed.startsWith('-') || trimmed.startsWith('−') || trimmed.startsWith('▼')) return 'down'
    const numeric = Number.parseFloat(trimmed.replace(/[,%]/g, ''))
    if (Number.isFinite(numeric)) {
      if (numeric > 0) return 'up'
      if (numeric < 0) return 'down'
    }
  }
  return 'neutral'
}

function directionalTokens(trend: StatTrendDirection, marketConvention: MarketConvention) {
  if (trend === 'neutral') {
    return {
      stroke: 'var(--fg-tertiary)',
      subtle: 'var(--layer-01)',
      text: 'var(--fg-secondary)',
      glyph: '—'
    }
  }
  const usePositiveTokens = marketConvention === 'cn' ? trend === 'down' : trend === 'up'
  return {
    stroke: usePositiveTokens ? 'var(--chart-up)' : 'var(--chart-down)',
    subtle: usePositiveTokens ? 'var(--chart-up-subtle)' : 'var(--chart-down-subtle)',
    text: usePositiveTokens ? 'var(--chart-up-foreground)' : 'var(--chart-down-foreground)',
    glyph: trend === 'up' ? '▲' : '▼'
  }
}

export function AnkoleSparkline({
  values,
  width = 96,
  height = 28,
  trend,
  marketConvention = 'intl',
  showArea = true,
  ariaLabel = 'Sparkline trend',
  className
}: AnkoleSparklineProps) {
  const cleanValues = values.filter(v => Number.isFinite(v))
  const resolvedTrend = trend ?? inferTrendFromValues(cleanValues)
  const tokens = directionalTokens(resolvedTrend, marketConvention)

  const pad = 2
  const innerW = Math.max(4, width - pad * 2)
  const innerH = Math.max(4, height - pad * 2)

  let linePath = ''
  let areaPath = ''

  if (cleanValues.length === 1) {
    const midY = pad + innerH / 2
    linePath = `M ${pad} ${midY} L ${pad + innerW} ${midY}`
  } else if (cleanValues.length >= 2) {
    const min = Math.min(...cleanValues)
    const max = Math.max(...cleanValues)
    const span = max - min
    const coords = cleanValues.map((val, idx) => {
      const x = pad + (idx / (cleanValues.length - 1)) * innerW
      const y = span === 0 ? pad + innerH / 2 : pad + innerH - ((val - min) / span) * innerH
      return [Number(x.toFixed(2)), Number(y.toFixed(2))] as const
    })
    linePath = coords.map(([x, y], idx) => `${idx === 0 ? 'M' : 'L'} ${x} ${y}`).join(' ')
    const firstX = coords[0]![0]
    const lastX = coords[coords.length - 1]![0]
    const bottomY = Number((pad + innerH).toFixed(2))
    areaPath = `${linePath} L ${lastX} ${bottomY} L ${firstX} ${bottomY} Z`
  }

  return (
    <svg
      role="img"
      aria-label={ariaLabel}
      data-slot="sparkline"
      data-trend={resolvedTrend}
      data-market-convention={marketConvention}
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      className={cn('shrink-0 overflow-visible', className)}>
      {showArea && areaPath && <path d={areaPath} fill={tokens.stroke} fillOpacity={0.14} />}
      {linePath && (
        <path
          d={linePath}
          fill="none"
          stroke={tokens.stroke}
          strokeWidth={1.75}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      )}
    </svg>
  )
}

export interface AnkoleStatCardProps {
  label: ReactNode
  value: ReactNode
  delta?: string | number | null
  trend?: StatTrendDirection
  marketConvention?: MarketConvention
  baseline?: ReactNode
  caption?: ReactNode
  sparklineValues?: readonly number[]
  sparklineLabel?: string
  className?: string
}

export function AnkoleStatCard({
  label,
  value,
  delta,
  trend,
  marketConvention = 'intl',
  baseline,
  caption,
  sparklineValues,
  sparklineLabel,
  className
}: AnkoleStatCardProps) {
  const hasDelta = delta !== undefined && delta !== null && String(delta).trim() !== ''
  const resolvedTrend = trend ?? (hasDelta ? inferTrendFromDelta(delta) : inferTrendFromValues(sparklineValues ?? []))
  const tokens = directionalTokens(resolvedTrend, marketConvention)

  const formattedDelta =
    typeof delta === 'number'
      ? `${delta > 0 ? '+' : ''}${delta}`
      : typeof delta === 'string'
        ? delta.replace(/^[▲▼]\s*/, '')
        : ''

  return (
    <div
      data-slot="stat-card"
      data-trend={resolvedTrend}
      data-market-convention={marketConvention}
      className={cn('content-object flex flex-col justify-between gap-2 bg-background p-4', className)}>
      <div className="flex items-start justify-between gap-3">
        <span className="text-xs font-medium text-fg-secondary">{label}</span>
        {sparklineValues && sparklineValues.length > 0 && (
          <AnkoleSparkline
            values={sparklineValues}
            trend={resolvedTrend}
            marketConvention={marketConvention}
            ariaLabel={sparklineLabel ?? (typeof label === 'string' ? `${label} trend` : 'Metric sparkline')}
          />
        )}
      </div>

      <div className="flex flex-wrap items-baseline gap-2">
        <div className="font-mono text-2xl leading-tight font-semibold text-foreground tabular-nums">{value}</div>
        {hasDelta && (
          <span
            data-slot="stat-delta"
            style={{
              color: tokens.text,
              backgroundColor: tokens.subtle
            }}
            className="inline-flex items-center gap-1 rounded-mini px-1.5 py-0.5 font-mono text-xs leading-4 font-medium tabular-nums">
            <span aria-hidden="true">{tokens.glyph}</span>
            <span>{formattedDelta}</span>
          </span>
        )}
      </div>

      {(baseline || caption) && (
        <div className="flex flex-col gap-0.5 text-xs text-fg-tertiary tabular-nums">
          {baseline && <span data-slot="stat-baseline">{baseline}</span>}
          {caption && <span data-slot="stat-caption">{caption}</span>}
        </div>
      )}
    </div>
  )
}
