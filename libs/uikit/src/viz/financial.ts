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

    const defaultSeriesType: FinancialMainSeriesType =
      chartMode === 'yield_curve'
        ? 'line'
        : (spec.seriesType ?? (spec.data[0] && isOhlcPoint(spec.data[0]) ? 'candlestick' : 'line'))

    const primaryLineColor = spec.color ?? palette.categorical[2]

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
        s.setData(spec.data as CandlestickData<HorzItem>[])
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
        s.setData(spec.data as BarData<HorzItem>[])
        mainSeries = s
        break
      }
      case 'baseline': {
        const firstPoint = spec.data[0]
        const inferredBase =
          spec.basePrice ?? (firstPoint ? (isOhlcPoint(firstPoint) ? firstPoint.close : firstPoint.value) : 0)
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
        const singleValues: SingleValueData<HorzItem>[] = spec.data.map(pt =>
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
        const singleValues: SingleValueData<HorzItem>[] = spec.data.map(pt =>
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
        const singleValues: SingleValueData<HorzItem>[] = spec.data.map(pt =>
          isOhlcPoint(pt) ? { time: pt.time, value: pt.close } : { time: pt.time, value: pt.value }
        )
        s.setData(singleValues)
        mainSeries = s
        break
      }
    }

    const lastPt = spec.data[spec.data.length - 1]
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
      markersPlugin = createSeriesMarkers(mainSeries, [...spec.markers])
    }

    // Pane 0 overlays (e.g. MA5, MA20, BOLL).
    if (spec.overlays && spec.overlays.length > 0) {
      const overlayDescriptors = spec.overlays.map((ov, idx) => ({
        key: ov.id ?? ov.title ?? `overlay-${idx}`,
        optionColor: ov.color ?? null
      }))
      const overlayColors = assignSeriesColors(overlayDescriptors, palette)

      spec.overlays.forEach((ov, idx) => {
        const key = ov.id ?? ov.title ?? `overlay-${idx}`
        const resolvedColor =
          ov.color ?? overlayColors.get(key) ?? palette.categorical[idx % palette.categorical.length]!
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
          s.setData([...ov.data])
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
          s.setData([...ov.data])
          extraSeries.push(s)
        }
      })
    }

    let nextAutoPaneIndex = 1

    // Convenience volume sub-pane at paneIndex = 1.
    if (spec.volume && spec.volume.length > 0) {
      const volPaneIdx = nextAutoPaneIndex++
      const s = chart.addSeries(
        HistogramSeries,
        {
          priceFormat: { type: 'volume' },
          priceLineVisible: false
        },
        volPaneIdx
      )
      s.setData(colorizeVolumePoints(spec.volume, spec.data, palette))
      volumeSeries = s
      const panes = chart.panes()
      if (panes[volPaneIdx]) {
        panes[volPaneIdx]!.setHeight(Math.max(64, Math.round(currentHeight * 0.22)))
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
        const subColors = assignSeriesColors(seriesDescriptors, palette)

        paneSpec.series.forEach((item, idx) => {
          const key = item.id ?? item.title ?? `sub-${paneIdx}-${idx}`
          const resolvedColor =
            item.color ?? subColors.get(key) ?? palette.categorical[idx % palette.categorical.length]!

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
              ? colorizeVolumePoints(item.data, spec.data, palette)
              : item.data.map(pt => ({
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
            s.setData(item.data.map(pt => ({ time: pt.time, value: pt.value })))
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
            s.setData(item.data.map(pt => ({ time: pt.time, value: pt.value })))
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
        lastMainDirection = point.close >= point.open ? 'up' : 'down'
        lastMainValue = point.close
      } else {
        lastMainDirection = lastMainValue === null || point.value >= lastMainValue ? 'up' : 'down'
        lastMainValue = point.value
      }
      mainSeries.update(point as never)
    },
    appendVolumePoint(point, direction) {
      if (destroyed || !volumeSeries) return
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
