import {
  AreaSeries,
  BarSeries,
  BaselineSeries,
  CandlestickSeries,
  ColorType,
  createChart,
  createSeriesMarkers,
  createYieldCurveChart,
  HistogramSeries,
  LineSeries,
  PriceScaleMode,
  type BarData,
  type CandlestickData,
  type HistogramData,
  type IChartApiBase,
  type ISeriesApi,
  type ISeriesMarkersPluginApi,
  type SeriesMarker,
  type SeriesType,
  type SingleValueData,
  type Time
} from 'lightweight-charts'
import {
  assignSeriesColors,
  resolveVizTheme,
  type MarketConvention,
  type VizThemeMode,
  type VizThemePalette
} from './theme'

export type FinancialTime = Time | number

export type FinancialChartMode = 'standard' | 'yield_curve'

export type FinancialMainSeriesType = 'candlestick' | 'bar' | 'baseline' | 'line' | 'area'

export type FinancialPriceScaleMode = 'normal' | 'logarithmic' | 'percentage' | 'indexedTo100'

export interface FinancialOhlcPoint<HorzItem = FinancialTime> {
  time: HorzItem
  open: number
  high: number
  low: number
  close: number
}

export interface FinancialSingleValuePoint<HorzItem = FinancialTime> {
  time: HorzItem
  value: number
}

export type FinancialMainPoint<HorzItem = FinancialTime> =
  | FinancialOhlcPoint<HorzItem>
  | FinancialSingleValuePoint<HorzItem>

export interface FinancialVolumePoint<HorzItem = FinancialTime> {
  time: HorzItem
  value: number
  color?: string
}

export interface FinancialOverlaySpec<HorzItem = FinancialTime> {
  id?: string
  title?: string
  type?: 'line' | 'area'
  color?: string
  lineWidth?: 1 | 2 | 3 | 4
  data: readonly FinancialSingleValuePoint<HorzItem>[]
}

export interface FinancialSubPaneSeriesSpec<HorzItem = FinancialTime> {
  id?: string
  title?: string
  type: 'histogram' | 'line' | 'area'
  color?: string
  lineWidth?: 1 | 2 | 3 | 4
  colorByMainDirection?: boolean
  data: readonly FinancialVolumePoint<HorzItem>[]
}

export interface FinancialSubPaneSpec<HorzItem = FinancialTime> {
  paneIndex?: number
  height?: number
  series: readonly FinancialSubPaneSeriesSpec<HorzItem>[]
}

export interface FinancialChartSpec<HorzItem = FinancialTime> {
  mode?: FinancialChartMode
  seriesType?: FinancialMainSeriesType
  data: readonly FinancialMainPoint<HorzItem>[]
  overlays?: readonly FinancialOverlaySpec<HorzItem>[]
  volume?: readonly FinancialVolumePoint<HorzItem>[]
  subPanes?: readonly FinancialSubPaneSpec<HorzItem>[]
  markers?: readonly SeriesMarker<HorzItem>[]
  priceScaleMode?: FinancialPriceScaleMode
  basePrice?: number
  color?: string
  width?: number
  height?: number
  theme?: VizThemeMode
  marketConvention?: MarketConvention
  tokenOverrides?: Partial<Record<string, string>>
  attributionLogo?: boolean
}

export interface MountedFinancialChart<HorzItem = FinancialTime> {
  update: (nextSpec: FinancialChartSpec<HorzItem>) => void
  appendPoint: (point: FinancialMainPoint<HorzItem>) => void
  appendVolumePoint: (point: FinancialVolumePoint<HorzItem>, direction?: 'up' | 'down') => void
  fitContent: () => void
  resize: (width: number, height: number) => void
  exportPNG: () => string
  destroy: () => void
}

export function mapPriceScaleMode(mode: FinancialPriceScaleMode | undefined): PriceScaleMode {
  switch (mode) {
    case 'logarithmic':
      return PriceScaleMode.Logarithmic
    case 'percentage':
      return PriceScaleMode.Percentage
    case 'indexedTo100':
      return PriceScaleMode.IndexedTo100
    case 'normal':
    default:
      return PriceScaleMode.Normal
  }
}

function isOhlcPoint<HorzItem>(point: FinancialMainPoint<HorzItem>): point is FinancialOhlcPoint<HorzItem> {
  return 'open' in point && 'high' in point && 'low' in point && 'close' in point
}

function financialTimeIdentity(time: unknown): string | null {
  if (typeof time === 'number') {
    return Number.isFinite(time) ? `n:${time}` : null
  }
  if (typeof time === 'string') {
    const trimmed = time.trim()
    return trimmed.length > 0 ? `s:${trimmed}` : null
  }
  if (time && typeof time === 'object') {
    const bd = time as { year?: unknown; month?: unknown; day?: unknown }
    if (typeof bd.year === 'number' && typeof bd.month === 'number' && typeof bd.day === 'number') {
      if (!Number.isFinite(bd.year) || !Number.isFinite(bd.month) || !Number.isFinite(bd.day)) return null
      return `b:${bd.year}-${String(bd.month).padStart(2, '0')}-${String(bd.day).padStart(2, '0')}`
    }
    return `o:${JSON.stringify(time)}`
  }
  return null
}

function comparableFinancialTime(time: unknown): number | string | null {
  if (typeof time === 'number') {
    return Number.isFinite(time) ? time : null
  }
  if (typeof time === 'string') {
    const trimmed = time.trim()
    if (!trimmed) return null
    if (/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) {
      const parsed = Date.parse(`${trimmed}T00:00:00Z`)
      return Number.isFinite(parsed) ? parsed : trimmed
    }
    if (/^-?\d+(?:\.\d+)?$/.test(trimmed)) {
      const num = Number(trimmed)
      if (Number.isFinite(num)) return num
    }
    const parsed = Date.parse(trimmed)
    return Number.isFinite(parsed) ? parsed : trimmed
  }
  if (time && typeof time === 'object') {
    const bd = time as { year?: unknown; month?: unknown; day?: unknown }
    if (typeof bd.year === 'number' && typeof bd.month === 'number' && typeof bd.day === 'number') {
      const utc = Date.UTC(bd.year, bd.month - 1, bd.day)
      return Number.isFinite(utc) ? utc : null
    }
    return JSON.stringify(time)
  }
  return null
}

function sortAndDedupeByTime<HorzItem, P extends { time: HorzItem }>(points: readonly P[]): P[] {
  const prepared: { point: P; key: string; sortVal: number | string; index: number }[] = []
  for (let i = 0; i < points.length; i += 1) {
    const point = points[i]!
    const key = financialTimeIdentity(point.time)
    const sortVal = comparableFinancialTime(point.time)
    if (key === null || sortVal === null) continue
    prepared.push({ point, key, sortVal, index: i })
  }

  prepared.sort((a, b) => {
    if (typeof a.sortVal === 'number' && typeof b.sortVal === 'number') {
      if (a.sortVal !== b.sortVal) return a.sortVal - b.sortVal
      return a.index - b.index
    }
    const cmp = String(a.sortVal).localeCompare(String(b.sortVal))
    return cmp !== 0 ? cmp : a.index - b.index
  })

  const deduped: P[] = []
  const indexByKey = new Map<string, number>()
  for (const entry of prepared) {
    const existingIdx = indexByKey.get(entry.key)
    if (existingIdx !== undefined) {
      deduped[existingIdx] = entry.point
    } else {
      indexByKey.set(entry.key, deduped.length)
      deduped.push(entry.point)
    }
  }
  return deduped
}

/**
 * Normalizes main financial series data prior to `lightweight-charts` `setData()`:
 * filters non-finite numbers, clamps inverted OHLC `high`/`low` bounds, sorts ascending by time,
 * and deduplicates identical timestamps keeping the latest point.
 */
export function normalizeFinancialMainData<HorzItem>(
  points: readonly FinancialMainPoint<HorzItem>[]
): FinancialMainPoint<HorzItem>[] {
  const valid: FinancialMainPoint<HorzItem>[] = []
  for (const pt of points) {
    if (isOhlcPoint(pt)) {
      if (
        !Number.isFinite(pt.open) ||
        !Number.isFinite(pt.high) ||
        !Number.isFinite(pt.low) ||
        !Number.isFinite(pt.close)
      ) {
        continue
      }
      const high = Math.max(pt.open, pt.high, pt.low, pt.close)
      const low = Math.min(pt.open, pt.high, pt.low, pt.close)
      valid.push(high === pt.high && low === pt.low ? pt : { ...pt, high, low })
    } else if (Number.isFinite(pt.value)) {
      valid.push(pt)
    }
  }
  return sortAndDedupeByTime(valid)
}

/**
 * Normalizes single-value or volume series points (finite values, ascending time, latest wins on duplicate time).
 */
export function normalizeFinancialSingleSeries<HorzItem, P extends { time: HorzItem; value: number }>(
  points: readonly P[]
): P[] {
  return sortAndDedupeByTime(points.filter(pt => Number.isFinite(pt.value)))
}

function hexWithAlpha(hexColor: string, alphaHex: string): string {
  const clean = hexColor.trim()
  if (/^#[0-9a-fA-F]{6}$/.test(clean)) {
    return `${clean}${alphaHex}`
  }
  return clean
}

/**
 * Colors volume or histogram points using `palette.up` / `palette.down` whenever an individual
 * point omits an explicit `color`.
 */
export function colorizeVolumePoints<HorzItem>(
  volume: readonly FinancialVolumePoint<HorzItem>[],
  mainData: readonly FinancialMainPoint<HorzItem>[],
  palette: VizThemePalette
): HistogramData<HorzItem>[] {
  const directionByTime = new Map<string, 'up' | 'down'>()
  let prevCloseOrValue: number | null = null

  for (const point of mainData) {
    const key = typeof point.time === 'object' ? JSON.stringify(point.time) : String(point.time)
    if (isOhlcPoint(point)) {
      directionByTime.set(key, point.close >= point.open ? 'up' : 'down')
      prevCloseOrValue = point.close
    } else {
      const dir = prevCloseOrValue === null || point.value >= prevCloseOrValue ? 'up' : 'down'
      directionByTime.set(key, dir)
      prevCloseOrValue = point.value
    }
  }

  return volume.map(item => {
    if (item.color) {
      return { time: item.time, value: item.value, color: item.color }
    }
    const key = typeof item.time === 'object' ? JSON.stringify(item.time) : String(item.time)
    const dir = directionByTime.get(key) ?? 'up'
    return {
      time: item.time,
      value: item.value,
      color: dir === 'up' ? palette.up : palette.down
    }
  })
}

/**
 * Mounts a TradingView `lightweight-charts` v5 instance inside `host`, supporting standard
 * time-based charts and yield-curve charts, OHLC / single-value series, pane-0 overlays,
 * synchronized multi-pane indicators (Volume, MACD, RSI), markers, and live streaming updates.
 */
export function mountFinancialChart<HorzItem = FinancialTime>(
  host: HTMLElement,
  initialSpec: FinancialChartSpec<HorzItem>
): MountedFinancialChart<HorzItem> {
  const rect = host.getBoundingClientRect()
  let currentWidth = initialSpec.width ?? Math.max(320, Math.round(rect.width) || 640)
  let currentHeight = initialSpec.height ?? Math.max(260, Math.round(rect.height) || 360)
  const chartMode: FinancialChartMode = initialSpec.mode ?? 'standard'

  let palette = resolveVizTheme(host, {
    theme: initialSpec.theme,
    marketConvention: initialSpec.marketConvention,
    tokenOverrides: initialSpec.tokenOverrides
  })

  const buildChartOptions = (spec: FinancialChartSpec<HorzItem>, activePalette: VizThemePalette) => ({
    width: currentWidth,
    height: currentHeight,
    layout: {
      attributionLogo: spec.attributionLogo ?? true,
      background: { type: ColorType.Solid, color: activePalette.background },
      textColor: activePalette.fgSecondary,
      fontFamily: activePalette.fontMono,
      panes: {
        separatorColor: activePalette.border,
        separatorHoverColor: activePalette.borderStrong,
        enableResize: true
      }
    },
    grid: {
      vertLines: { color: activePalette.border },
      horzLines: { color: activePalette.border }
    },
    crosshair: {
      vertLine: { color: activePalette.borderStrong, labelBackgroundColor: activePalette.layer01 },
      horzLine: { color: activePalette.borderStrong, labelBackgroundColor: activePalette.layer01 }
    },
    rightPriceScale: {
      borderColor: activePalette.border,
      mode: mapPriceScaleMode(spec.priceScaleMode)
    },
    timeScale: {
      borderColor: activePalette.border,
      timeVisible: true,
      secondsVisible: false
    }
  })

  const chart: IChartApiBase<HorzItem> =
    chartMode === 'yield_curve'
      ? (createYieldCurveChart(host, buildChartOptions(initialSpec, palette)) as unknown as IChartApiBase<HorzItem>)
      : (createChart(host, buildChartOptions(initialSpec, palette)) as unknown as IChartApiBase<HorzItem>)

  let mainSeries: ISeriesApi<SeriesType, HorzItem> | null = null
  let volumeSeries: ISeriesApi<'Histogram', HorzItem> | null = null
  let extraSeries: ISeriesApi<SeriesType, HorzItem>[] = []
  let markersPlugin: ISeriesMarkersPluginApi<HorzItem> | null = null
  let lastMainDirection: 'up' | 'down' = 'up'
  let lastMainValue: number | null = null
  let destroyed = false

  const clearSeries = () => {
    if (markersPlugin) {
      markersPlugin.detach()
      markersPlugin = null
    }
    for (const s of extraSeries) {
      try {
        chart.removeSeries(s)
      } catch {
        // Ignore already removed series when panes collapse.
      }
    }
    extraSeries = []
    if (volumeSeries) {
      try {
        chart.removeSeries(volumeSeries)
      } catch {
        // Ignore already removed series.
      }
      volumeSeries = null
    }
    if (mainSeries) {
      try {
        chart.removeSeries(mainSeries)
      } catch {
        // Ignore already removed series.
      }
      mainSeries = null
    }
  }

  const applySpec = (spec: FinancialChartSpec<HorzItem>) => {
    palette = resolveVizTheme(host, {
      theme: spec.theme,
      marketConvention: spec.marketConvention,
      tokenOverrides: spec.tokenOverrides
    })
    if (spec.width) currentWidth = spec.width
    if (spec.height) currentHeight = spec.height

    chart.applyOptions(buildChartOptions(spec, palette) as never)
    clearSeries()

    const normalizedMain = normalizeFinancialMainData(spec.data)
    const defaultSeriesType: FinancialMainSeriesType =
      chartMode === 'yield_curve'
        ? 'line'
        : (spec.seriesType ?? (normalizedMain[0] && isOhlcPoint(normalizedMain[0]) ? 'candlestick' : 'line'))

    const primaryLineColor = spec.color ?? palette.categoricalStrokes[0]

    switch (defaultSeriesType) {
      case 'candlestick': {
        const s = chart.addSeries(
          CandlestickSeries,
          {
            upColor: palette.up,
            downColor: palette.down,
            borderUpColor: palette.up,
            borderDownColor: palette.down,
            wickUpColor: palette.up,
            wickDownColor: palette.down
          },
          0
        )
        s.setData(normalizedMain.filter(isOhlcPoint) as CandlestickData<HorzItem>[])
        mainSeries = s
        break
      }
      case 'bar': {
        const s = chart.addSeries(
          BarSeries,
          {
            upColor: palette.up,
            downColor: palette.down
          },
          0
        )
        s.setData(normalizedMain.filter(isOhlcPoint) as BarData<HorzItem>[])
        mainSeries = s
        break
      }
      case 'baseline': {
        const firstPoint = normalizedMain[0]
        const rawBase =
          spec.basePrice ?? (firstPoint ? (isOhlcPoint(firstPoint) ? firstPoint.close : firstPoint.value) : 0)
        const inferredBase = Number.isFinite(rawBase) ? rawBase : 0
        const s = chart.addSeries(
          BaselineSeries,
          {
            baseValue: { type: 'price', price: inferredBase },
            topLineColor: palette.up,
            topFillColor1: hexWithAlpha(palette.up, '40'),
            topFillColor2: hexWithAlpha(palette.up, '05'),
            bottomLineColor: palette.down,
            bottomFillColor1: hexWithAlpha(palette.down, '05'),
            bottomFillColor2: hexWithAlpha(palette.down, '40')
          },
          0
        )
        const singleValues: SingleValueData<HorzItem>[] = normalizedMain.map(pt =>
          isOhlcPoint(pt) ? { time: pt.time, value: pt.close } : { time: pt.time, value: pt.value }
        )
        s.setData(singleValues)
        mainSeries = s
        break
      }
      case 'area': {
        const s = chart.addSeries(
          AreaSeries,
          {
            lineColor: primaryLineColor,
            topColor: hexWithAlpha(primaryLineColor, '45'),
            bottomColor: hexWithAlpha(primaryLineColor, '05'),
            lineWidth: 2
          },
          0
        )
        const singleValues: SingleValueData<HorzItem>[] = normalizedMain.map(pt =>
          isOhlcPoint(pt) ? { time: pt.time, value: pt.close } : { time: pt.time, value: pt.value }
        )
        s.setData(singleValues)
        mainSeries = s
        break
      }
      case 'line':
      default: {
        const s = chart.addSeries(
          LineSeries,
          {
            color: primaryLineColor,
            lineWidth: 2
          },
          0
        )
        const singleValues: SingleValueData<HorzItem>[] = normalizedMain.map(pt =>
          isOhlcPoint(pt) ? { time: pt.time, value: pt.close } : { time: pt.time, value: pt.value }
        )
        s.setData(singleValues)
        mainSeries = s
        break
      }
    }

    const lastPt = normalizedMain[normalizedMain.length - 1]
    if (lastPt) {
      if (isOhlcPoint(lastPt)) {
        lastMainDirection = lastPt.close >= lastPt.open ? 'up' : 'down'
        lastMainValue = lastPt.close
      } else {
        lastMainValue = lastPt.value
      }
    }

    // Attach markers on main series if provided (not applicable on numeric yield curves without markers).
    if (mainSeries && spec.markers && spec.markers.length > 0) {
      markersPlugin = createSeriesMarkers(mainSeries, sortAndDedupeByTime(spec.markers))
    }

    // Pane 0 overlays (e.g. MA5, MA20, BOLL).
    if (spec.overlays && spec.overlays.length > 0) {
      const overlayDescriptors = spec.overlays.map((ov, idx) => ({
        key: ov.id ?? ov.title ?? `overlay-${idx}`,
        optionColor: ov.color ?? null
      }))
      const overlayColors = assignSeriesColors(overlayDescriptors, palette, { variant: 'stroke' })

      spec.overlays.forEach((ov, idx) => {
        const key = ov.id ?? ov.title ?? `overlay-${idx}`
        const resolvedColor =
          ov.color ?? overlayColors.get(key) ?? palette.categoricalStrokes[idx % palette.categoricalStrokes.length]!
        const overlayData = normalizeFinancialSingleSeries(ov.data)
        if (ov.type === 'area') {
          const s = chart.addSeries(
            AreaSeries,
            {
              title: ov.title,
              lineColor: resolvedColor,
              topColor: hexWithAlpha(resolvedColor, '30'),
              bottomColor: hexWithAlpha(resolvedColor, '04'),
              lineWidth: ov.lineWidth ?? 1,
              priceLineVisible: false
            },
            0
          )
          s.setData(overlayData)
          extraSeries.push(s)
        } else {
          const s = chart.addSeries(
            LineSeries,
            {
              title: ov.title,
              color: resolvedColor,
              lineWidth: ov.lineWidth ?? 2,
              priceLineVisible: false
            },
            0
          )
          s.setData(overlayData)
          extraSeries.push(s)
        }
      })
    }

    let nextAutoPaneIndex = 1

    // Convenience volume sub-pane at paneIndex = 1.
    if (spec.volume && spec.volume.length > 0) {
      const normalizedVolume = normalizeFinancialSingleSeries(spec.volume)
      if (normalizedVolume.length > 0) {
        const volPaneIdx = nextAutoPaneIndex++
        const s = chart.addSeries(
          HistogramSeries,
          {
            priceFormat: { type: 'volume' },
            priceLineVisible: false
          },
          volPaneIdx
        )
        s.setData(colorizeVolumePoints(normalizedVolume, normalizedMain, palette))
        volumeSeries = s
        const panes = chart.panes()
        if (panes[volPaneIdx]) {
          panes[volPaneIdx]!.setHeight(Math.max(64, Math.round(currentHeight * 0.22)))
        }
      }
    }

    // Additional synchronized sub-panes (paneIndex >= 1, e.g. MACD, RSI, KDJ).
    if (spec.subPanes && spec.subPanes.length > 0) {
      for (const paneSpec of spec.subPanes) {
        const paneIdx = Math.max(1, paneSpec.paneIndex ?? nextAutoPaneIndex++)
        if (paneIdx >= nextAutoPaneIndex) {
          nextAutoPaneIndex = paneIdx + 1
        }
        const seriesDescriptors = paneSpec.series.map((item, idx) => ({
          key: item.id ?? item.title ?? `sub-${paneIdx}-${idx}`,
          optionColor: item.color ?? null
        }))
        const subColors = assignSeriesColors(seriesDescriptors, palette, { variant: 'stroke' })

        paneSpec.series.forEach((item, idx) => {
          const key = item.id ?? item.title ?? `sub-${paneIdx}-${idx}`
          const resolvedColor =
            item.color ?? subColors.get(key) ?? palette.categoricalStrokes[idx % palette.categoricalStrokes.length]!
          const normalizedItemData = normalizeFinancialSingleSeries(item.data)

          if (item.type === 'histogram') {
            const s = chart.addSeries(
              HistogramSeries,
              {
                title: item.title,
                color: resolvedColor,
                priceLineVisible: false
              },
              paneIdx
            )
            const histData: HistogramData<HorzItem>[] = item.colorByMainDirection
              ? colorizeVolumePoints(normalizedItemData, normalizedMain, palette)
              : normalizedItemData.map(pt => ({
                  time: pt.time,
                  value: pt.value,
                  color: pt.color ?? (pt.value >= 0 ? palette.up : palette.down)
                }))
            s.setData(histData)
            if (!volumeSeries && item.colorByMainDirection) {
              volumeSeries = s
            } else {
              extraSeries.push(s)
            }
          } else if (item.type === 'area') {
            const s = chart.addSeries(
              AreaSeries,
              {
                title: item.title,
                lineColor: resolvedColor,
                topColor: hexWithAlpha(resolvedColor, '33'),
                bottomColor: hexWithAlpha(resolvedColor, '05'),
                lineWidth: item.lineWidth ?? 2,
                priceLineVisible: false
              },
              paneIdx
            )
            s.setData(normalizedItemData.map(pt => ({ time: pt.time, value: pt.value })))
            extraSeries.push(s)
          } else {
            const s = chart.addSeries(
              LineSeries,
              {
                title: item.title,
                color: resolvedColor,
                lineWidth: item.lineWidth ?? 2,
                priceLineVisible: false
              },
              paneIdx
            )
            s.setData(normalizedItemData.map(pt => ({ time: pt.time, value: pt.value })))
            extraSeries.push(s)
          }
        })

        if (paneSpec.height) {
          const panes = chart.panes()
          if (panes[paneIdx]) {
            panes[paneIdx]!.setHeight(paneSpec.height)
          }
        }
      }
    }

    chart.timeScale().fitContent()
  }

  applySpec(initialSpec)

  return {
    update(nextSpec) {
      if (destroyed) return
      applySpec(nextSpec)
    },
    appendPoint(point) {
      if (destroyed || !mainSeries) return
      if (isOhlcPoint(point)) {
        if (
          !Number.isFinite(point.open) ||
          !Number.isFinite(point.high) ||
          !Number.isFinite(point.low) ||
          !Number.isFinite(point.close)
        ) {
          return
        }
        const normalized: FinancialOhlcPoint<HorzItem> = {
          ...point,
          high: Math.max(point.open, point.high, point.low, point.close),
          low: Math.min(point.open, point.high, point.low, point.close)
        }
        lastMainDirection = normalized.close >= normalized.open ? 'up' : 'down'
        lastMainValue = normalized.close
        mainSeries.update(normalized as never)
      } else {
        if (!Number.isFinite(point.value)) return
        lastMainDirection = lastMainValue === null || point.value >= lastMainValue ? 'up' : 'down'
        lastMainValue = point.value
        mainSeries.update(point as never)
      }
    },
    appendVolumePoint(point, direction) {
      if (destroyed || !volumeSeries || !Number.isFinite(point.value)) return
      const dir = direction ?? lastMainDirection
      volumeSeries.update({
        time: point.time,
        value: point.value,
        color: point.color ?? (dir === 'up' ? palette.up : palette.down)
      } as never)
    },
    fitContent() {
      if (destroyed) return
      chart.timeScale().fitContent()
    },
    resize(width, height) {
      if (destroyed) return
      currentWidth = Math.max(120, Math.round(width))
      currentHeight = Math.max(120, Math.round(height))
      chart.resize(currentWidth, currentHeight, true)
    },
    exportPNG() {
      if (destroyed) throw new Error('Financial chart instance has been destroyed.')
      return chart.takeScreenshot(true, false).toDataURL('image/png')
    },
    destroy() {
      if (destroyed) return
      destroyed = true
      if (markersPlugin) {
        markersPlugin.detach()
        markersPlugin = null
      }
      chart.remove()
    }
  }
}
