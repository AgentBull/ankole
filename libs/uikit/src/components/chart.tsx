import { useEffect, useId, useImperativeHandle, useMemo, useRef, useState, type ReactNode, type Ref } from 'react'
import { cn } from '../lib/utils'
import type { MountedStatisticalChart, PercentFallbackReason, StatisticalChartSpec } from '../viz/statistical'

export type {
  DonutCenterLabel,
  MountedStatisticalChart,
  PercentFallbackReason,
  StatisticalChartSpec,
  StatisticalChartTier1Type,
  StatisticalChartTier2Type,
  StatisticalChartType,
  StatisticalReferenceLine,
  StatisticalStackMode
} from '../viz/statistical'

export interface AnkoleChartSummaryTable {
  columns: readonly string[]
  rows: readonly (readonly (string | number | boolean | null | undefined)[])[]
}

export interface AnkoleChartHandle {
  exportSVG: () => Promise<string>
  exportPNG: (dpr?: number) => Promise<string>
}

export interface AnkoleChartProps {
  spec: StatisticalChartSpec
  ariaLabel?: string
  caption?: ReactNode
  summaryTable?: AnkoleChartSummaryTable
  defaultTableOpen?: boolean
  tableToggleLabel?: string
  allowExport?: boolean
  exportFilename?: string
  exportPngLabel?: string
  exportSvgLabel?: string
  eager?: boolean
  height?: number
  emptyState?: ReactNode
  className?: string
  ref?: Ref<AnkoleChartHandle>
}

function sanitizeDownloadStem(raw?: string): string {
  const cleaned = (raw ?? 'ankole-chart')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af_-]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return cleaned || 'ankole-chart'
}

function triggerHrefDownload(href: string, filename: string) {
  if (typeof document === 'undefined') return
  const link = document.createElement('a')
  link.href = href
  link.download = filename
  link.rel = 'noopener'
  document.body.appendChild(link)
  link.click()
  link.remove()
}

function triggerSvgBlobDownload(svgMarkup: string, filename: string) {
  if (typeof document === 'undefined' || typeof Blob === 'undefined') return
  const blob = new Blob([svgMarkup], { type: 'image/svg+xml;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  try {
    triggerHrefDownload(url, filename)
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }
}

function inferNegativePercentFallback(spec: StatisticalChartSpec): PercentFallbackReason | undefined {
  if (spec.stackMode !== 'percent' || !Array.isArray(spec.data)) return undefined
  const field = spec.yField ?? spec.valueField ?? 'value'
  for (const row of spec.data) {
    const raw = row[field]
    const num = typeof raw === 'number' ? raw : typeof raw === 'string' && raw.trim() !== '' ? Number(raw) : Number.NaN
    if (Number.isFinite(num) && num < 0) {
      return 'negative_values'
    }
  }
  return undefined
}

function deriveSummaryTable(spec: StatisticalChartSpec, explicit?: AnkoleChartSummaryTable): AnkoleChartSummaryTable {
  if (explicit) return explicit
  if (!Array.isArray(spec.data) || spec.data.length === 0) {
    return { columns: [], rows: [] }
  }
  const columnSet = new Set<string>()
  for (const row of spec.data.slice(0, 50)) {
    for (const key of Object.keys(row)) {
      if (!key.startsWith('__')) columnSet.add(key)
    }
  }
  const columns = [...columnSet]
  const rows = spec.data.slice(0, 200).map(row =>
    columns.map(col => {
      const val = row[col]
      if (val === null || val === undefined) return '—'
      if (typeof val === 'string' || typeof val === 'number' || typeof val === 'boolean') return val
      return JSON.stringify(val)
    })
  )
  return { columns, rows }
}

export function AnkoleChart({
  spec,
  ariaLabel,
  caption,
  summaryTable,
  defaultTableOpen = false,
  tableToggleLabel = 'Data table',
  allowExport = false,
  exportFilename,
  exportPngLabel = 'PNG',
  exportSvgLabel = 'SVG',
  eager = false,
  height = 320,
  emptyState,
  className,
  ref
}: AnkoleChartProps) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const mountedRef = useRef<MountedStatisticalChart | null>(null)
  const opQueueRef = useRef<Promise<void>>(Promise.resolve())
  const latestSpecRef = useRef(spec)
  latestSpecRef.current = spec

  const tableId = useId()
  const [isVisible, setIsVisible] = useState<boolean>(() => eager || typeof IntersectionObserver === 'undefined')
  const [tableOpen, setTableOpen] = useState<boolean>(defaultTableOpen)
  const [exportingKind, setExportingKind] = useState<'png' | 'svg' | null>(null)
  const [runtimeFallback, setRuntimeFallback] = useState<PercentFallbackReason | undefined>(undefined)
  const [renderError, setRenderError] = useState<string | null>(null)
  const [themeRevision, setThemeRevision] = useState(0)

  const fallbackReason = runtimeFallback ?? inferNegativePercentFallback(spec)
  const tableData = useMemo(() => deriveSummaryTable(spec, summaryTable), [spec, summaryTable])

  const isEmptyData = Array.isArray(spec.data) && spec.data.length === 0
  const resolvedHeight = spec.height ?? height

  useImperativeHandle(
    ref,
    () => ({
      async exportSVG() {
        if (!mountedRef.current) {
          throw new Error('Chart is not mounted yet.')
        }
        return mountedRef.current.exportSVG()
      },
      async exportPNG(dpr?: number) {
        if (!mountedRef.current) {
          throw new Error('Chart is not mounted yet.')
        }
        return mountedRef.current.exportPNG(dpr)
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
    if (typeof document === 'undefined' || typeof MutationObserver === 'undefined') return
    const observer = new MutationObserver(() => {
      setThemeRevision(prev => prev + 1)
    })
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['data-theme']
    })
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    if (!isVisible || isEmptyData) {
      setRenderError(null)
      return
    }
    const host = hostRef.current
    if (!host) return

    let cancelled = false
    let resizeObserver: ResizeObserver | null = null
    let mountPromise: Promise<void> | null = null

    const enqueueResize = (w: number, h: number) => {
      const handle = mountedRef.current
      if (!handle) return
      opQueueRef.current = opQueueRef.current
        .catch(() => {})
        .then(async () => {
          if (cancelled || mountedRef.current !== handle) return
          await handle.resize(w, h)
        })
        .catch(() => {})
    }

    const mountOrRecover = async () => {
      const rect = host.getBoundingClientRect()
      const w = latestSpecRef.current.width ?? Math.round(rect.width)
      const h = latestSpecRef.current.height ?? Math.round(rect.height || resolvedHeight)
      if (w <= 0 || h <= 0) {
        return
      }
      if (mountedRef.current) {
        enqueueResize(w, h)
        return
      }
      if (mountPromise) {
        await mountPromise
        if (!cancelled && mountedRef.current) {
          const latestRect = host.getBoundingClientRect()
          const latestW = latestSpecRef.current.width ?? Math.round(latestRect.width)
          const latestH = latestSpecRef.current.height ?? Math.round(latestRect.height || resolvedHeight)
          if (latestW > 0 && latestH > 0) {
            enqueueResize(latestW, latestH)
          }
        }
        return
      }

      mountPromise = (async () => {
        try {
          const { mountStatisticalChart } = await import('../viz/statistical')
          if (cancelled || mountedRef.current) return
          const initialSpecSnapshot = latestSpecRef.current
          const handle = await mountStatisticalChart(host, {
            ...initialSpecSnapshot,
            width: w,
            height: h
          })
          if (cancelled) {
            handle.destroy()
            return
          }
          mountedRef.current = handle
          setRenderError(null)
          setRuntimeFallback(handle.percentFallbackReason)
          if (latestSpecRef.current !== initialSpecSnapshot) {
            await handle.update(latestSpecRef.current)
            if (!cancelled && mountedRef.current === handle) {
              setRuntimeFallback(handle.percentFallbackReason)
            }
          }
        } catch (err) {
          if (!cancelled) {
            setRenderError(err instanceof Error ? err.message : String(err))
          }
        } finally {
          mountPromise = null
        }
      })()

      await mountPromise
    }

    void mountOrRecover()

    if (typeof ResizeObserver !== 'undefined') {
      resizeObserver = new ResizeObserver(() => {
        void mountOrRecover()
      })
      resizeObserver.observe(host)
    }

    return () => {
      cancelled = true
      resizeObserver?.disconnect()
      mountedRef.current?.destroy()
      mountedRef.current = null
    }
  }, [isEmptyData, isVisible, resolvedHeight, spec.renderer])

  useEffect(() => {
    void themeRevision
    const handle = mountedRef.current
    if (!handle) return
    opQueueRef.current = opQueueRef.current
      .catch(() => {})
      .then(async () => {
        if (mountedRef.current !== handle) return
        await handle.update(latestSpecRef.current)
        if (mountedRef.current === handle) {
          setRenderError(null)
          setRuntimeFallback(handle.percentFallbackReason)
        }
      })
      .catch(err => {
        if (mountedRef.current === handle) {
          setRenderError(err instanceof Error ? err.message : String(err))
        }
      })
  }, [spec, themeRevision])

  const accessibleLabel = ariaLabel ?? spec.title ?? `${spec.type} chart`
  const fileStem = sanitizeDownloadStem(exportFilename ?? ariaLabel ?? spec.title)
  const showExportControls = allowExport && !isEmptyData

  const handleExport = async (kind: 'png' | 'svg') => {
    const instance = mountedRef.current
    if (!instance || exportingKind) return
    setExportingKind(kind)
    try {
      if (kind === 'png') {
        const pngDataUrl = await instance.exportPNG(2)
        triggerHrefDownload(pngDataUrl, `${fileStem}.png`)
      } else {
        const svgMarkup = await instance.exportSVG()
        triggerSvgBlobDownload(svgMarkup, `${fileStem}.svg`)
      }
    } finally {
      setExportingKind(null)
    }
  }

  return (
    <figure className={cn('ankole-viz-figure content-object flex flex-col gap-3 bg-background p-4', className)}>
      {!isEmptyData && renderError && (
        <div
          role="alert"
          data-slot="chart-render-error"
          className="rounded-mini bg-layer-01 p-3 text-xs text-fg-secondary">
          {renderError}
        </div>
      )}

      <div
        ref={hostRef}
        role="img"
        aria-label={accessibleLabel}
        hidden={!isEmptyData && Boolean(renderError)}
        style={isEmptyData ? { minHeight: `${resolvedHeight}px` } : { height: `${resolvedHeight}px` }}
        className="relative w-full overflow-hidden">
        {isEmptyData && emptyState ? (
          <div className="flex h-full min-h-[inherit] items-center justify-center p-6 text-sm text-fg-tertiary">
            {emptyState}
          </div>
        ) : null}
      </div>

      {fallbackReason === 'negative_values' && (
        <p role="status" data-slot="percent-fallback-notice" className="text-xs text-fg-secondary">
          Displayed as stacked values because 100% stacked mode cannot normalize negative values.
        </p>
      )}

      {(caption || tableData.columns.length > 0 || showExportControls) && (
        <figcaption className="flex flex-wrap items-center justify-between gap-2 text-xs text-fg-tertiary">
          <div>{caption}</div>
          <div className="flex flex-wrap items-center gap-1.5">
            {showExportControls && (
              <>
                <button
                  type="button"
                  data-slot="chart-export-png"
                  disabled={exportingKind !== null}
                  onClick={() => void handleExport('png')}
                  className="rounded-mini border border-border px-2 py-1 text-xs font-medium text-fg-secondary hover:bg-layer-01 hover:text-foreground disabled:opacity-50">
                  {exportPngLabel}
                </button>
                <button
                  type="button"
                  data-slot="chart-export-svg"
                  disabled={exportingKind !== null}
                  onClick={() => void handleExport('svg')}
                  className="rounded-mini border border-border px-2 py-1 text-xs font-medium text-fg-secondary hover:bg-layer-01 hover:text-foreground disabled:opacity-50">
                  {exportSvgLabel}
                </button>
              </>
            )}
            {tableData.columns.length > 0 && (
              <button
                type="button"
                aria-expanded={tableOpen}
                aria-controls={tableId}
                onClick={() => setTableOpen(prev => !prev)}
                className="rounded-mini border border-border px-2 py-1 text-xs font-medium text-fg-secondary hover:bg-layer-01 hover:text-foreground">
                {tableToggleLabel}
              </button>
            )}
          </div>
        </figcaption>
      )}

      {tableOpen && tableData.columns.length > 0 && (
        <div id={tableId} className="max-h-64 overflow-auto border-t border-border pt-2">
          <table className="w-full border-collapse text-left text-xs tabular-nums">
            <caption className="sr-only">{accessibleLabel}</caption>
            <thead>
              <tr className="border-b border-border bg-layer-01">
                {tableData.columns.map(col => (
                  <th key={col} scope="col" className="px-2 py-1.5 font-semibold text-foreground">
                    {col}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {tableData.rows.map((row, rowIndex) => (
                <tr key={rowIndex} className="border-b border-border/60">
                  {row.map((cell, cellIndex) => (
                    <td key={cellIndex} className="px-2 py-1 text-fg-secondary">
                      {cell === null || cell === undefined ? '—' : String(cell)}
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
