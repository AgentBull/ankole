import { useEffect, useId, useImperativeHandle, useMemo, useRef, useState, type ReactNode, type Ref } from 'react'
import { cn } from '../lib/utils'
import type {
  FinancialChartSpec,
  FinancialMainPoint,
  FinancialVolumePoint,
  MountedFinancialChart
} from '../viz/financial'

export type {
  FinancialChartMode,
  FinancialChartSpec,
  FinancialMainPoint,
  FinancialMainSeriesType,
  FinancialOhlcPoint,
  FinancialOverlaySpec,
  FinancialPriceScaleMode,
  FinancialSingleValuePoint,
  FinancialSubPaneSeriesSpec,
  FinancialSubPaneSpec,
  FinancialTime,
  FinancialVolumePoint,
  MountedFinancialChart
} from '../viz/financial'

export interface AnkoleFinancialChartHandle {
  appendPoint: (point: FinancialMainPoint) => void
  appendVolumePoint: (point: FinancialVolumePoint, direction?: 'up' | 'down') => void
  fitContent: () => void
  exportPNG: () => string
}

export interface AnkoleFinancialChartProps {
  spec: FinancialChartSpec
  title?: ReactNode
  subtitle?: ReactNode
  ariaLabel?: string
  caption?: ReactNode
  defaultTableOpen?: boolean
  tableToggleLabel?: string
  eager?: boolean
  height?: number
  emptyState?: ReactNode
  className?: string
  ref?: Ref<AnkoleFinancialChartHandle>
}

function buildOhlcSummaryTable(spec: FinancialChartSpec): {
  columns: readonly string[]
  rows: readonly (readonly (string | number)[])[]
} {
  if (spec.data.length === 0) return { columns: [], rows: [] }
  const first = spec.data[0]!
  const isOhlc = 'open' in first && 'high' in first && 'low' in first && 'close' in first
  const volumeByTime = new Map<string, number>()
  for (const v of spec.volume ?? []) {
    volumeByTime.set(typeof v.time === 'object' ? JSON.stringify(v.time) : String(v.time), v.value)
  }
  const hasVol = volumeByTime.size > 0
  const columns = isOhlc
    ? hasVol
      ? ['Time', 'Open', 'High', 'Low', 'Close', 'Volume']
      : ['Time', 'Open', 'High', 'Low', 'Close']
    : hasVol
      ? ['Time', 'Value', 'Volume']
      : ['Time', 'Value']

  const rows = spec.data.slice(-200).map(pt => {
    const timeLabel = typeof pt.time === 'object' ? JSON.stringify(pt.time) : String(pt.time)
    const vol = volumeByTime.get(timeLabel)
    if ('open' in pt && 'high' in pt && 'low' in pt && 'close' in pt) {
      return hasVol
        ? [timeLabel, pt.open, pt.high, pt.low, pt.close, vol ?? '—']
        : [timeLabel, pt.open, pt.high, pt.low, pt.close]
    }
    return hasVol ? [timeLabel, pt.value, vol ?? '—'] : [timeLabel, pt.value]
  })

  return { columns, rows }
}

export function AnkoleFinancialChart({
  spec,
  title,
  subtitle,
  ariaLabel = 'Financial market chart',
  caption,
  defaultTableOpen = false,
  tableToggleLabel = 'OHLC summary',
  eager = false,
  height = 380,
  emptyState,
  className,
  ref
}: AnkoleFinancialChartProps) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const mountedRef = useRef<MountedFinancialChart | null>(null)
  const latestSpecRef = useRef(spec)
  latestSpecRef.current = spec

  const tableId = useId()
  const [isVisible, setIsVisible] = useState<boolean>(() => eager || typeof IntersectionObserver === 'undefined')
  const [tableOpen, setTableOpen] = useState<boolean>(defaultTableOpen)

  const summaryTable = useMemo(() => buildOhlcSummaryTable(spec), [spec])
  const resolvedHeight = spec.height ?? height
  const isEmpty = spec.data.length === 0

  useImperativeHandle(
    ref,
    () => ({
      appendPoint(point) {
        mountedRef.current?.appendPoint(point)
      },
      appendVolumePoint(point, direction) {
        mountedRef.current?.appendVolumePoint(point, direction)
      },
      fitContent() {
        mountedRef.current?.fitContent()
      },
      exportPNG() {
        if (!mountedRef.current) {
          throw new Error('Financial chart is not mounted yet.')
        }
        return mountedRef.current.exportPNG()
      }
    }),
    []
  )

  useEffect(() => {
    if (isVisible || eager) {
      setIsVisible(true)
      return
    }
    const host = hostRef.current
    if (!host || typeof IntersectionObserver === 'undefined') {
      setIsVisible(true)
      return
    }
    const observer = new IntersectionObserver(
      entries => {
        if (entries.some(entry => entry.isIntersecting)) {
          setIsVisible(true)
          observer.disconnect()
        }
      },
      { rootMargin: '300px' }
    )
    observer.observe(host)
    return () => observer.disconnect()
  }, [eager, isVisible])

  useEffect(() => {
    if (!isVisible || isEmpty) return
    const host = hostRef.current
    if (!host) return

    let cancelled = false
    let resizeObserver: ResizeObserver | null = null

    const mountOrResize = async () => {
      const rect = host.getBoundingClientRect()
      const w = latestSpecRef.current.width ?? Math.round(rect.width)
      const h = latestSpecRef.current.height ?? Math.round(rect.height || resolvedHeight)
      if (w <= 0 || h <= 0) return
      if (mountedRef.current) {
        mountedRef.current.resize(w, h)
        return
      }
      const { mountFinancialChart } = await import('../viz/financial')
      if (cancelled || mountedRef.current) return
      mountedRef.current = mountFinancialChart(host, {
        ...latestSpecRef.current,
        width: w,
        height: h
      })
    }

    void mountOrResize()

    if (typeof ResizeObserver !== 'undefined') {
      resizeObserver = new ResizeObserver(() => {
        void mountOrResize()
      })
      resizeObserver.observe(host)
    }

    return () => {
      cancelled = true
      resizeObserver?.disconnect()
      mountedRef.current?.destroy()
      mountedRef.current = null
    }
  }, [isEmpty, isVisible, resolvedHeight, spec.mode])

  useEffect(() => {
    mountedRef.current?.update(spec)
  }, [spec])

  return (
    <figure className={cn('ankole-viz-figure content-object flex flex-col gap-3 bg-background p-4', className)}>
      {(title || subtitle) && (
        <div className="flex flex-col gap-0.5">
          {title && <div className="text-sm font-semibold text-foreground">{title}</div>}
          {subtitle && <div className="text-xs text-fg-secondary">{subtitle}</div>}
        </div>
      )}

      <div
        ref={hostRef}
        role="img"
        aria-label={ariaLabel}
        style={{ minHeight: `${resolvedHeight}px` }}
        className="relative w-full overflow-hidden">
        {isEmpty && emptyState ? (
          <div className="flex h-full min-h-[inherit] items-center justify-center p-6 text-sm text-fg-tertiary">
            {emptyState}
          </div>
        ) : null}
      </div>

      {(caption || summaryTable.columns.length > 0) && (
        <figcaption className="flex flex-wrap items-center justify-between gap-2 text-xs text-fg-tertiary">
          <div>{caption}</div>
          {summaryTable.columns.length > 0 && (
            <button
              type="button"
              aria-expanded={tableOpen}
              aria-controls={tableId}
              onClick={() => setTableOpen(prev => !prev)}
              className="rounded-mini border border-border px-2 py-1 text-xs font-medium text-fg-secondary hover:bg-layer-01 hover:text-foreground">
              {tableToggleLabel}
            </button>
          )}
        </figcaption>
      )}

      {tableOpen && summaryTable.columns.length > 0 && (
        <div id={tableId} className="max-h-64 overflow-auto border-t border-border pt-2">
          <table className="w-full border-collapse text-left font-mono text-xs tabular-nums">
            <thead>
              <tr className="border-b border-border bg-layer-01">
                {summaryTable.columns.map(col => (
                  <th key={col} scope="col" className="px-2 py-1.5 font-sans font-semibold text-foreground">
                    {col}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {summaryTable.rows.map((row, rowIndex) => (
                <tr key={rowIndex} className="border-b border-border/60">
                  {row.map((cell, cellIndex) => (
                    <td key={cellIndex} className="px-2 py-1 text-fg-secondary">
                      {String(cell)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </figure>
  )
}

export function AnkoleYieldCurveChart(props: AnkoleFinancialChartProps) {
  return (
    <AnkoleFinancialChart
      ariaLabel="Yield curve chart"
      {...props}
      spec={{ ...props.spec, mode: 'yield_curve', seriesType: props.spec.seriesType ?? 'line' }}
    />
  )
}
