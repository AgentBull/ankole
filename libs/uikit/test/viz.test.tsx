import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  AnkoleChart,
  AnkoleFinancialChart,
  AnkoleGraph,
  AnkoleInfographic,
  AnkoleSparkline,
  AnkoleStatCard,
  assignSeriesColors,
  isPrintSafeSvg,
  pickReadableDataLabelInk,
  resolveSelectOptionColor,
  resolveSelectOptionStrokeColor,
  resolveVizTheme,
  sanitizeExportedSvg,
  type DonutCenterLabel
} from '../src/index'
import { colorizeVolumePoints, mapPriceScaleMode } from '../src/viz/financial'
import {
  BUILTIN_INFOGRAPHIC_TEMPLATES,
  buildOfflineIconSymbolSvg,
  offlineInfographicResourceLoader,
  validateInfographicSyntax
} from '../src/viz/infographic'
import { prepareStatisticalChartSpec, resolveStatTrend, type StatisticalChartType } from '../src/viz/statistical'

describe('Theme tokens & pure viz theme utilities (`viz/theme.ts`)', () => {
  test('resolves light/dark palettes, monotonic sequential ramps, zero-anchored diverging scales, and cn convention swap', () => {
    const srgbLuminance = (hex: string): number => {
      const ch = [hex.slice(1, 3), hex.slice(3, 5), hex.slice(5, 7)].map(p => {
        const c = Number.parseInt(p, 16) / 255
        return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
      })
      return 0.2126 * ch[0]! + 0.7152 * ch[1]! + 0.0722 * ch[2]!
    }

    const lightIntl = resolveVizTheme(null, { theme: 'light', marketConvention: 'intl' })
    const lightCn = resolveVizTheme(null, { theme: 'light', marketConvention: 'cn' })
    expect(lightIntl.isDark).toBe(false)
    expect(lightIntl.up).toBe('#19875c')
    expect(lightIntl.down).toBe('#c1384b')
    expect(lightCn.up).toBe('#c1384b')
    expect(lightCn.down).toBe('#19875c')
    expect(lightCn.upSubtle).toBe(lightIntl.downSubtle)
    expect(lightCn.downForeground).toBe(lightIntl.upForeground)
    expect(lightIntl.totalColor).toBe('#3f5368')
    expect(lightIntl.categoricalStrokes[0]).toBe('#0c58b4')
    expect(lightIntl.diverging[3]).toBe('#f4f4f2')
    expect(lightCn.diverging[3]).toBe('#f4f4f2')
    expect(lightCn.diverging[0]).toBe(lightIntl.diverging[6])
    expect(lightCn.diverging[6]).toBe(lightIntl.diverging[0])

    // Light mode sequential: dark-is-more on matte paper (strictly decreasing luminance)
    for (let i = 1; i < lightIntl.sequential.length; i += 1) {
      expect(srgbLuminance(lightIntl.sequential[i]!)).toBeLessThan(srgbLuminance(lightIntl.sequential[i - 1]!))
    }

    const darkIntl = resolveVizTheme(null, {
      theme: 'dark',
      marketConvention: 'intl',
      tokenOverrides: { '--chart-1': '#123456' }
    })
    expect(darkIntl.isDark).toBe(true)
    expect(darkIntl.up).toBe('#43c291')
    expect(darkIntl.down).toBe('#eb6b7d')
    expect(darkIntl.categorical[0]).toBe('#123456')
    expect(darkIntl.categoricalStrokes[0]).toBe('#123456')
    expect(darkIntl.categoricalStrokes[1]).toBe('#3dd3c0')
    expect(darkIntl.otherColor).not.toBe(darkIntl.emptyColor)
    expect(darkIntl.diverging[3]).toBe('#232526')

    // Dark mode sequential: light-is-more on graphite (strictly increasing luminance)
    for (let i = 1; i < darkIntl.sequential.length; i += 1) {
      expect(srgbLuminance(darkIntl.sequential[i]!)).toBeGreaterThan(srgbLuminance(darkIntl.sequential[i - 1]!))
    }

    expect(pickReadableDataLabelInk('#2864b9')).toBe('#ffffff')
    expect(pickReadableDataLabelInk('#b3395a')).toBe('#ffffff')
    expect(pickReadableDataLabelInk('#ecb457')).toBe('#18191a')
    expect(pickReadableDataLabelInk('#51c6b5')).toBe('#18191a')
    expect(pickReadableDataLabelInk('#dcf3ff')).toBe('#18191a')
  })

  test('assigns series fill and stroke colors strictly in rank order (never hashing) while honoring optionColor, Other, and Empty', () => {
    const palette = resolveVizTheme(null, { theme: 'light' })

    const orderA = assignSeriesColors(
      [
        { key: 'North America' },
        { key: 'APAC' },
        { key: 'Priority', optionColor: 'teal' },
        { key: 'Other', isOther: true },
        { key: 'Empty', isEmpty: true }
      ],
      palette
    )
    const orderB = assignSeriesColors([{ key: 'APAC' }, { key: 'North America' }], palette)
    const strokeOrder = assignSeriesColors(
      [{ key: 'North America' }, { key: 'Priority', optionColor: 'teal' }],
      palette,
      { variant: 'stroke' }
    )

    expect(orderA.get('North America')).toBe(palette.categorical[0])
    expect(orderA.get('APAC')).toBe(palette.categorical[1])
    // Rank-order proof: when APAC ranks #1, it receives slot 0 rather than a hash-derived slot.
    expect(orderB.get('APAC')).toBe(palette.categorical[0])
    expect(orderB.get('North America')).toBe(palette.categorical[1])

    expect(orderA.get('Priority')).toBe(resolveSelectOptionColor('teal', false))
    expect(strokeOrder.get('North America')).toBe(palette.categoricalStrokes[0])
    expect(strokeOrder.get('Priority')).toBe(resolveSelectOptionStrokeColor('teal', false))
    expect(orderA.get('Other')).toBe(palette.otherColor)
    expect(orderA.get('Empty')).toBe(palette.emptyColor)

    const eightSeries = assignSeriesColors(
      Array.from({ length: 8 }, (_, idx) => ({ key: `Series ${idx + 1}` })),
      palette
    )
    for (const color of eightSeries.values()) {
      expect(color).not.toBe(palette.otherColor)
      expect(color).not.toBe(palette.emptyColor)
    }
  })

  test('validates Print-Safe SVGs and sanitizes CSS variables, xmlns, and CJK viewBox padding', () => {
    const palette = resolveVizTheme(null, { theme: 'light' })

    expect(
      isPrintSafeSvg('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"><rect fill="#0f62fe"/></svg>')
    ).toBe(true)
    expect(
      isPrintSafeSvg(
        '<svg xmlns="http://www.w3.org/2000/svg"><foreignObject width="50" height="20"><div>bad</div></foreignObject></svg>'
      )
    ).toBe(false)
    expect(isPrintSafeSvg('<svg xmlns="http://www.w3.org/2000/svg"><rect fill="var(--chart-1)"/></svg>')).toBe(false)
    expect(
      isPrintSafeSvg('<svg xmlns="http://www.w3.org/2000/svg"><image href="https://cdn.example.com/logo.png"/></svg>')
    ).toBe(false)

    const dirty = '<svg viewBox="0 0 200 100"><rect fill="var(--chart-1)" stroke="var(--border)"/></svg>'
    const sanitized = sanitizeExportedSvg(dirty, palette, { safetyPaddingPx: 10 })
    expect(isPrintSafeSvg(sanitized)).toBe(true)
    expect(sanitized).toContain('xmlns="http://www.w3.org/2000/svg"')
    expect(sanitized).toContain('viewBox="-10 -10 220 120"')
    expect(sanitized).toContain(palette.categorical[0])
  })
})

describe('Statistical & financial pure spec builders', () => {
  test('falls back from percent to stacked on negative values, guards zero-sum buckets, and supports all 21 chart types', () => {
    const palette = resolveVizTheme(null, { theme: 'light' })

    const fallback = prepareStatisticalChartSpec(
      {
        type: 'column',
        stackMode: 'percent',
        xField: 'quarter',
        yField: 'pnl',
        seriesField: 'segment',
        data: [
          { quarter: '2026-Q1', segment: 'Core', pnl: 120 },
          { quarter: '2026-Q1', segment: 'Labs', pnl: -30 }
        ],
        referenceLines: [{ value: 0, label: 'Breakeven' }]
      },
      palette
    )
    expect(fallback.percentFallbackReason).toBe('negative_values')
    expect(fallback.effectiveStackMode).toBe('stacked')

    const zeroBucket = prepareStatisticalChartSpec(
      {
        type: 'area',
        stackMode: 'percent',
        xField: 'month',
        yField: 'rev',
        seriesField: 'tier',
        data: [
          { month: '2026-01', tier: 'Pro', rev: 0 },
          { month: '2026-01', tier: 'Free', rev: 0 },
          { month: '2026-02', tier: 'Pro', rev: 60 },
          { month: '2026-02', tier: 'Free', rev: 40 }
        ]
      },
      palette
    )
    expect(zeroBucket.percentFallbackReason).toBeUndefined()
    expect(zeroBucket.effectiveStackMode).toBe('percent')
    const serialized = JSON.stringify(zeroBucket.g2Spec)
    expect(serialized).not.toContain('NaN')

    const allTypes: StatisticalChartType[] = [
      'column',
      'bar',
      'line',
      'area',
      'combo',
      'pie',
      'donut',
      'funnel',
      'scatter',
      'histogram',
      'boxplot',
      'heatmap',
      'radar',
      'waterfall',
      'gauge',
      'treemap',
      'sunburst',
      'sankey',
      'wordcloud',
      'quantile_band',
      'stat'
    ]
    for (const chartType of allTypes) {
      const built = prepareStatisticalChartSpec(
        {
          type: chartType,
          data: [
            { category: 'A', series: 'S1', value: 10, secondaryValue: 4, source: 'A', target: 'B', text: 'Alpha' },
            { category: 'B', series: 'S2', value: 25, secondaryValue: 8, source: 'B', target: 'C', text: 'Beta' }
          ]
        },
        palette
      )
      expect(built.g2Spec).toBeDefined()
    }
  })

  test('colors volume bars automatically by candle direction and marketConvention', () => {
    const intlPalette = resolveVizTheme(null, { theme: 'light', marketConvention: 'intl' })
    const cnPalette = resolveVizTheme(null, { theme: 'light', marketConvention: 'cn' })
    const candles = [
      { time: '2026-01-02', open: 100, high: 110, low: 98, close: 108 },
      { time: '2026-01-03', open: 108, high: 109, low: 95, close: 97 }
    ]
    const volume = [
      { time: '2026-01-02', value: 1500 },
      { time: '2026-01-03', value: 2100 },
      { time: '2026-01-03', value: 500, color: '#112233' }
    ]

    const intlColored = colorizeVolumePoints(volume, candles, intlPalette)
    expect(intlColored[0]?.color).toBe('#19875c')
    expect(intlColored[1]?.color).toBe('#c1384b')
    expect(intlColored[2]?.color).toBe('#112233')

    const cnColored = colorizeVolumePoints(volume, candles, cnPalette)
    expect(cnColored[0]?.color).toBe('#c1384b')
    expect(cnColored[1]?.color).toBe('#19875c')
    expect(mapPriceScaleMode('logarithmic')).toBe(1)
  })

  test('enforces 1D uniform Cobalt focus with neutral Other/Empty, zero-anchored diverging heatmaps, IBCS waterfall totals, and dynamic funnel label contrast', () => {
    const lightPalette = resolveVizTheme(null, { theme: 'light' })
    const darkPalette = resolveVizTheme(null, { theme: 'dark' })

    // 1D bar/column without optionColor keeps uniform primary Cobalt on normal categories (no rainbow circus)
    const oneDimRanking = prepareStatisticalChartSpec(
      {
        type: 'column',
        xField: 'customer',
        yField: 'arr',
        seriesMeta: [
          { key: 'Acme', isOther: false, isEmpty: false },
          { key: 'Globex', isOther: false, isEmpty: false },
          { key: 'Other', isOther: true, isEmpty: false },
          { key: 'Empty', isOther: false, isEmpty: true }
        ],
        data: [
          { customer: 'Acme', arr: 500 },
          { customer: 'Globex', arr: 320 },
          { customer: 'Other', arr: 120, __isOther: true },
          { customer: 'Empty', arr: 40 }
        ]
      },
      lightPalette
    )
    const oneDimScale = (oneDimRanking.g2Spec as { scale?: { color?: { domain: string[]; range: string[] } } }).scale
      ?.color
    expect(oneDimScale).toEqual({
      domain: ['Acme', 'Globex', 'Other', 'Empty'],
      range: [
        lightPalette.categorical[0],
        lightPalette.categorical[0],
        lightPalette.otherColor,
        lightPalette.emptyColor
      ]
    })
    expect((oneDimRanking.g2Spec as { legend?: unknown }).legend).toBe(false)

    // Mixed negative-and-positive heatmap anchors 0 strictly to neutral surface midpoint
    const mixedHeatmap = prepareStatisticalChartSpec(
      {
        type: 'heatmap',
        xField: 'sector',
        yField: 'quarter',
        valueField: 'mom',
        showDataLabels: true,
        data: [
          { sector: 'Cloud', quarter: 'Q1', mom: -12 },
          { sector: 'Cloud', quarter: 'Q2', mom: 0 },
          { sector: 'AI', quarter: 'Q2', mom: 36 }
        ]
      },
      darkPalette
    )
    const hmScale = (mixedHeatmap.g2Spec as { scale?: { color?: { type: string; domain: number[]; range: string[] } } })
      .scale?.color
    expect(hmScale?.type).toBe('linear')
    expect(hmScale?.domain[3]).toBe(0)
    expect(hmScale?.domain[0]).toBe(-36)
    expect(hmScale?.domain[6]).toBe(36)
    expect(hmScale?.range).toEqual([...darkPalette.diverging])

    // Waterfall separates total bars into neutral slate totalColor rather than categorical slot 3
    const wfPrepared = prepareStatisticalChartSpec(
      {
        type: 'waterfall',
        xField: 'step',
        yField: 'delta',
        data: [
          { step: 'Q1 ARR', delta: 100 },
          { step: 'Churn', delta: -15 },
          { step: 'Ending ARR', delta: 85, isTotal: true }
        ]
      },
      lightPalette
    )
    const wfScale = (wfPrepared.g2Spec as { scale?: { color?: { domain: string[]; range: string[] } } }).scale?.color
    expect(wfScale?.range).toEqual([lightPalette.up, lightPalette.down, lightPalette.totalColor])

    // Funnel inside labels dynamically choose high-contrast ink over dark vs bright stage fills
    const funnelDark = prepareStatisticalChartSpec(
      {
        type: 'funnel',
        xField: 'stage',
        valueField: 'leads',
        showDataLabels: true,
        data: [
          { stage: 'Visited', leads: 1000 },
          { stage: 'Activated', leads: 420 }
        ]
      },
      darkPalette
    )
    const funnelLabelFill = (
      funnelDark.g2Spec as {
        labels?: { style?: { fill?: (d: Record<string, unknown>) => string } }[]
      }
    ).labels?.[0]?.style?.fill
    expect(typeof funnelLabelFill).toBe('function')
    expect(funnelLabelFill?.({ stage: 'Visited', leads: 1000 })).toBe('#18191a')
  })

  test('builds semantic formatted tooltips, data labels, smooth curves, and donut center total without internal key leaks', () => {
    const palette = resolveVizTheme(null, { theme: 'light' })

    const percentPrepared = prepareStatisticalChartSpec(
      {
        type: 'column',
        stackMode: 'percent',
        xField: 'x',
        yField: 'y',
        seriesField: 'series',
        yTitle: 'SUM(Revenue)',
        formattedYField: '__formattedY',
        showDataLabels: true,
        data: [
          { x: 'Q1', series: 'Enterprise', y: 1200, __formattedY: '$1,200.00' },
          { x: 'Q1', series: 'Self-Serve', y: 800, __formattedY: '$800.00' }
        ]
      },
      palette
    )

    const g2Col = percentPrepared.g2Spec as Record<string, unknown>
    const colData = g2Col.data as Record<string, unknown>[]
    const colTooltip = g2Col.tooltip as {
      title: (d: Record<string, unknown>) => string
      items: ((d: Record<string, unknown>) => { name: string; value: string })[]
    }
    expect(colTooltip.title(colData[0]!)).toBe('Q1')
    expect(colTooltip.items[0]!(colData[0]!)).toEqual({
      name: 'Enterprise',
      value: '$1,200.00 (60%)'
    })
    const colLabels = g2Col.labels as { text: (d: Record<string, unknown>) => string }[]
    expect(colLabels[0]!.text(colData[0]!)).toBe('60%')

    const smoothLine = prepareStatisticalChartSpec(
      {
        type: 'line',
        smooth: true,
        xField: 'x',
        yField: 'y',
        yTitle: 'Orders',
        formattedYField: '__formattedY',
        data: [{ x: '2026-01', y: 42, __formattedY: '42' }]
      },
      palette
    )
    expect((smoothLine.g2Spec as { encode?: { shape?: string } }).encode?.shape).toBe('smooth')

    const centerLabel: DonutCenterLabel = { value: '$2,000.00', title: 'SUM(Revenue)' }
    const donutPrepared = prepareStatisticalChartSpec(
      {
        type: 'donut',
        xField: 'x',
        valueField: 'y',
        yTitle: 'SUM(Revenue)',
        formattedYField: '__formattedY',
        donutCenterLabel: centerLabel,
        data: [
          { x: 'East', y: 1500, __formattedY: '$1,500.00' },
          { x: 'West', y: 500, __formattedY: '$500.00' }
        ]
      },
      palette
    )
    const donutSpec = donutPrepared.g2Spec as { type?: string; children?: Record<string, unknown>[] }
    expect(donutSpec.type).toBe('view')
    expect(donutSpec.children?.length).toBe(3)
    const intervalChild = donutSpec.children?.[0] as {
      data: Record<string, unknown>[]
      tooltip: { items: ((d: Record<string, unknown>) => { name: string; value: string })[] }
    }
    expect(intervalChild.tooltip.items[0]!(intervalChild.data[0]!)).toEqual({
      name: 'SUM(Revenue)',
      value: '$1,500.00 (75%)'
    })
    expect((donutSpec.children?.[1] as { style?: { text?: string } })?.style?.text).toBe('$2,000.00')
    expect((donutSpec.children?.[2] as { style?: { text?: string } })?.style?.text).toBe('SUM(Revenue)')

    for (const mode of ['light', 'dark'] as const) {
      const modePalette = resolveVizTheme(null, { theme: mode })
      const piePrepared = prepareStatisticalChartSpec(
        {
          type: 'pie',
          xField: 'x',
          valueField: 'y',
          data: [
            { x: '進行中', y: 5 },
            { x: '已完成', y: 3 }
          ]
        },
        modePalette
      )
      const g2Theme = (piePrepared.g2Spec as { theme?: Record<string, Record<string, unknown>> }).theme
      expect(Array.isArray(g2Theme?.legendCategory?.itemSpacing)).toBe(true)
      expect(typeof g2Theme?.legendCategory?.itemMarkerSize).toBe('number')
      expect(typeof g2Theme?.axis?.labelSpacing).toBe('number')
    }

    const colAxis = (percentPrepared.g2Spec as { axis?: { x?: { title?: unknown }; y?: { title?: unknown } } }).axis
    expect(colAxis?.x?.title).toBe(false)
    expect(colAxis?.y?.title).toBe('SUM(Revenue)')

    const sunburstPrepared = prepareStatisticalChartSpec(
      {
        type: 'sunburst',
        xField: 'x',
        valueField: 'y',
        data: [
          { x: 'Core', y: 60 },
          { x: 'Edge', y: 40 }
        ]
      },
      palette
    )
    expect(Array.isArray((sunburstPrepared.g2Spec as { data?: unknown }).data)).toBe(true)
  })

  test('renders metric cards and quantile bands from the same theme tokens, trend conventions, and accessibility contract', () => {
    const intlPalette = resolveVizTheme(null, { theme: 'light', marketConvention: 'intl' })
    const cnPalette = resolveVizTheme(null, { theme: 'light', marketConvention: 'cn' })

    const stat = prepareStatisticalChartSpec(
      {
        type: 'stat',
        title: 'Median latency',
        subtitle: 'vs. previous period',
        unit: 'ms',
        valueField: 'p50',
        comparisonField: 'delta',
        data: [{ p50: 182, delta: '+12.4%' }]
      },
      intlPalette
    )
    const statSpec = stat.g2Spec as {
      type?: string
      padding?: number
      title?: unknown
      legend?: unknown
      children?: { style?: Record<string, unknown> }[]
    }
    expect(statSpec.type).toBe('view')
    expect(statSpec.padding).toBe(0)
    expect(statSpec.title).toBeUndefined()
    expect(statSpec.legend).toBe(false)
    expect((statSpec.children ?? []).map(child => String(child.style?.text))).toEqual([
      'Median latency',
      'vs. previous period',
      '182',
      'ms',
      '▲ +12.4%'
    ])
    expect(statSpec.children?.at(-1)?.style?.fill).toBe(intlPalette.upForeground)

    const explicitDown = prepareStatisticalChartSpec(
      {
        type: 'stat',
        valueField: 'p50',
        formattedValueField: 'p50Text',
        comparisonField: 'delta',
        trendField: 'trend',
        data: [{ p50: 182, p50Text: '182 ms', delta: '+12.4%', trend: 'down' }]
      },
      intlPalette
    )
    const downTexts = (explicitDown.g2Spec as { children?: { style?: Record<string, unknown> }[] }).children ?? []
    expect(String(downTexts.at(-1)?.style?.text)).toBe('▼ +12.4%')
    expect(downTexts.at(-1)?.style?.fill).toBe(intlPalette.downForeground)

    // The palette already follows the market convention, so a positive `cn` delta uses the red ramp.
    const cnStat = prepareStatisticalChartSpec(
      {
        type: 'stat',
        valueField: 'value',
        comparisonField: 'delta',
        data: [{ value: 1, delta: '+1.0%' }]
      },
      cnPalette
    )
    const cnTexts = (cnStat.g2Spec as { children?: { style?: Record<string, unknown> }[] }).children ?? []
    expect(cnTexts.at(-1)?.style?.fill).toBe(cnPalette.upForeground)
    expect(cnPalette.upForeground).toBe(intlPalette.downForeground)

    expect(resolveStatTrend(undefined, '+3')).toBe('up')
    expect(resolveStatTrend(undefined, '−3')).toBe('down')
    expect(resolveStatTrend('neutral', '+3')).toBe('neutral')
    expect(resolveStatTrend(undefined, undefined)).toBe('neutral')

    const band = prepareStatisticalChartSpec(
      {
        type: 'quantile_band',
        xField: 'bucket',
        yField: 'p50',
        bandLowField: 'p5',
        bandHighField: 'p95',
        bandLabel: 'p5–p95',
        data: [
          { bucket: '10:00', p50: 120, p5: 80, p95: 190 },
          { bucket: '11:00', p50: 140, p5: 95, p95: 210 }
        ]
      },
      intlPalette
    )
    const bandSpec = band.g2Spec as {
      type?: string
      data?: unknown
      children?: Record<string, unknown>[]
    }
    expect(bandSpec.type).toBe('view')
    expect(Array.isArray(bandSpec.data)).toBe(true)

    const [areaMark, lineMark] = bandSpec.children ?? []
    expect(areaMark?.type).toBe('area')
    expect(areaMark?.encode).toEqual({ x: 'bucket', y: 'p95', y1: 'p5' })
    const areaStyle = areaMark?.style as { fill?: string } | undefined
    expect(areaStyle?.fill).toBe(intlPalette.categorical[0])
    expect(areaMark?.tooltip).toBe(false)

    expect(lineMark?.type).toBe('line')
    expect(lineMark?.encode).toMatchObject({ x: 'bucket', y: 'p50' })
    const tooltip = lineMark?.tooltip as {
      items: ((d: Record<string, unknown>) => { name: string; value: string })[]
    }
    expect(tooltip.items[0]!({ bucket: '10:00', p5: 80, p50: 120, p95: 190 })).toEqual({
      name: 'p5–p95',
      value: '80 – 190'
    })
    expect(tooltip.items[1]!({ bucket: '10:00', p5: 80, p50: 120, p95: 190 })).toEqual({
      name: 'p50',
      value: '120'
    })

    const lineOnly = prepareStatisticalChartSpec(
      { type: 'quantile_band', xField: 'bucket', yField: 'p50', data: [{ bucket: '10:00', p50: 120 }] },
      intlPalette
    )
    const lineOnlyChildren = (lineOnly.g2Spec as { children?: Record<string, unknown>[] }).children ?? []
    expect(lineOnlyChildren.map(child => child.type)).toEqual(['line'])
  })
})

describe('Infographic syntax validation & offline icon symbol loader (`viz/infographic.ts`)', () => {
  test('validates built-in infographic templates and rejects empty or malformed syntax', () => {
    expect(BUILTIN_INFOGRAPHIC_TEMPLATES).toContain('list-row-simple-horizontal-arrow')
    expect(BUILTIN_INFOGRAPHIC_TEMPLATES).toContain('sequence-timeline-simple')
    expect(BUILTIN_INFOGRAPHIC_TEMPLATES).toContain('compare-swot')
    expect(BUILTIN_INFOGRAPHIC_TEMPLATES).toContain('compare-hierarchy-left-right-circle-node-pill-badge')

    const validDsl = [
      'infographic sequence-timeline-simple',
      'data',
      '  title Product Roadmap',
      '  items',
      '    - label Wave 1',
      '      desc Core Viz Engine',
      '      icon rocket'
    ].join('\n')
    expect(validateInfographicSyntax(validDsl)).toEqual({ ok: true })

    expect(validateInfographicSyntax('   ').ok).toBe(false)
    expect(validateInfographicSyntax('just_a_random_word').ok).toBe(false)
    expect(validateInfographicSyntax('infographic nonexistent-template-xyz\ndata\n  title Test').ok).toBe(false)
  })

  test('resolves semantic and unknown icons into <symbol viewBox="0 0 24 24"> with zero fetch calls', async () => {
    const originalFetch = globalThis.fetch
    globalThis.fetch = (() => {
      throw new Error('External network fetch is forbidden in offline infographic loader!')
    }) as unknown as typeof fetch

    try {
      for (const keyword of ['check', 'star', 'rocket', 'database', 'warning', 'unknown-custom-glyph-99']) {
        const svg = buildOfflineIconSymbolSvg(keyword)
        expect(svg).toContain('<symbol')
        expect(svg).toContain('viewBox="0 0 24 24"')
        expect(isPrintSafeSvg(`<svg xmlns="http://www.w3.org/2000/svg"><defs>${svg}</defs></svg>`)).toBe(true)

        const symbolEl = await offlineInfographicResourceLoader({ data: keyword })
        expect(symbolEl.tagName.toLowerCase()).toBe('symbol')
        expect(symbolEl.getAttribute('viewBox')).toBe('0 0 24 24')
      }
    } finally {
      globalThis.fetch = originalFetch
    }
  })
})

describe('Thin lazy React visualization wrappers', () => {
  test('renders AnkoleStatCard and AnkoleSparkline with tabular-nums, directional glyphs, and cn market swap', () => {
    const intlHtml = renderToStaticMarkup(
      <AnkoleStatCard
        label="Quarterly ARR"
        value="$4,820,000"
        delta="+14.2%"
        baseline="vs. Q4 2025"
        caption="Audited billing ledger"
        sparklineValues={[380, 410, 405, 455, 482]}
      />
    )
    expect(intlHtml).toContain('tabular-nums')
    expect(intlHtml).toContain('▲')
    expect(intlHtml).toContain('var(--chart-up)')
    expect(intlHtml).toContain('role="img"')
    expect(intlHtml).toContain('vs. Q4 2025')
    expect(intlHtml).toContain('Audited billing ledger')

    const cnHtml = renderToStaticMarkup(
      <AnkoleStatCard
        label="CSI 300"
        value="3,980.15"
        delta="+1.85%"
        sparklineValues={[3900, 3940, 3980]}
        marketConvention="cn"
      />
    )
    expect(cnHtml).toContain('▲')
    expect(cnHtml).toContain('var(--chart-down-foreground)')
    expect(cnHtml).toContain('var(--chart-down)')

    const downSpark = renderToStaticMarkup(<AnkoleSparkline values={[100, 92, 85]} marketConvention="intl" />)
    expect(downSpark).toContain('data-trend="down"')
    expect(downSpark).toContain('var(--chart-down)')
  })

  test('renders semantic <figure>, accessible summary tables, and percent fallback notices across lazy wrappers', () => {
    const chartHtml = renderToStaticMarkup(
      <AnkoleChart
        defaultTableOpen
        allowExport
        caption="Segment contribution"
        spec={{
          type: 'column',
          title: 'Operating Margin',
          stackMode: 'percent',
          yField: 'margin',
          data: [
            { segment: 'Cloud', margin: 45 },
            { segment: 'Hardware', margin: -8 }
          ]
        }}
      />
    )
    expect(chartHtml).toContain('<figure')
    expect(chartHtml).toContain('ankole-viz-figure')
    expect(chartHtml).toContain('negative values')
    expect(chartHtml).toContain('<caption class="sr-only">Operating Margin</caption>')
    expect(chartHtml).toContain('data-slot="chart-export-png"')
    expect(chartHtml).toContain('data-slot="chart-export-svg"')
    expect(chartHtml).toContain('<th scope="col"')
    expect(chartHtml).toContain('Segment contribution')

    const finHtml = renderToStaticMarkup(
      <AnkoleFinancialChart
        title="AAPL Daily"
        defaultTableOpen
        spec={{
          data: [{ time: '2026-01-02', open: 180, high: 185, low: 179, close: 184 }]
        }}
      />
    )
    expect(finHtml).toContain('ankole-viz-figure')
    expect(finHtml).toContain('<th scope="col"')
    expect(finHtml).toContain('184')

    const infoHtml = renderToStaticMarkup(
      <AnkoleInfographic
        title="Release Flow"
        defaultOutlineOpen
        source={'infographic list-row-simple-horizontal-arrow\ndata\n  items\n    - label Plan\n    - label Ship'}
      />
    )
    expect(infoHtml).toContain('ankole-viz-figure')
    expect(infoHtml).toContain('Release Flow')
    expect(infoHtml).toContain('Plan')

    const graphHtml = renderToStaticMarkup(
      <AnkoleGraph ariaLabel="Entity Graph" nodes={[{ id: 'n1', label: 'Node 1' }]} edges={[]} />
    )
    expect(graphHtml).toBeDefined()
  })
})
