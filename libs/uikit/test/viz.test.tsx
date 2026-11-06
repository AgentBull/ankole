import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
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
  resolveSelectOptionColor,
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
import { prepareStatisticalChartSpec, type StatisticalChartType } from '../src/viz/statistical'

const FORBIDDEN_EAGER_SPECIFIERS = new Set([
  '@antv/g2',
  '@antv/g6',
  '@antv/g-svg',
  '@antv/infographic',
  'lightweight-charts'
])

function resolveLocalModulePath(fromFile: string, specifier: string): string | null {
  if (!specifier.startsWith('.')) return null
  const base = resolve(dirname(fromFile), specifier)
  for (const candidate of [base, `${base}.ts`, `${base}.tsx`, resolve(base, 'index.ts'), resolve(base, 'index.tsx')]) {
    if (existsSync(candidate)) return candidate
  }
  return null
}

function extractStaticRuntimeSpecifiers(sourceCode: string): string[] {
  const withoutComments = sourceCode.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1')

  const specifiers: string[] = []
  // Match top-level static `import ... from '...'` and `export ... from '...'`, skipping `import type` and `export type`.
  const stmtRe = /\b(?:import|export)\s+(?!type\b)([\s\S]*?)\s+from\s+['"]([^'"]+)['"]/g
  for (const match of withoutComments.matchAll(stmtRe)) {
    const clause = match[1]!.trim()
    const spec = match[2]!
    // Check if every named specifier inside `{ ... }` is marked `type`, e.g. `import { type Foo, type Bar } from '...'`.
    if (clause.startsWith('{') && clause.endsWith('}')) {
      const inner = clause
        .slice(1, -1)
        .split(',')
        .map(part => part.trim())
        .filter(Boolean)
      if (inner.length > 0 && inner.every(part => part.startsWith('type '))) {
        continue
      }
    }
    specifiers.push(spec)
  }

  const sideEffectImportRe = /\bimport\s+['"]([^'"]+)['"]/g
  for (const match of withoutComments.matchAll(sideEffectImportRe)) {
    specifiers.push(match[1]!)
  }

  return specifiers
}

describe('Bundle isolation invariant (`libs/uikit/src/index.ts`)', () => {
  test('never statically imports @antv/*, lightweight-charts, or eager components/graph across the entire index closure', () => {
    const entryFile = resolve(import.meta.dir, '../src/index.ts')
    const eagerGraphFile = resolve(import.meta.dir, '../src/components/graph.tsx')
    const visited = new Set<string>()
    const queue = [entryFile]
    const externalImports = new Set<string>()

    while (queue.length > 0) {
      const current = queue.shift()!
      if (visited.has(current)) continue
      visited.add(current)

      const content = readFileSync(current, 'utf8')
      const specs = extractStaticRuntimeSpecifiers(content)
      for (const spec of specs) {
        if (spec.startsWith('.')) {
          const resolved = resolveLocalModulePath(current, spec)
          expect(resolved).not.toBeNull()
          expect(resolved).not.toBe(eagerGraphFile)
          if (resolved && !visited.has(resolved)) {
            queue.push(resolved)
          }
        } else {
          externalImports.add(spec)
        }
      }
    }

    for (const ext of externalImports) {
      expect(FORBIDDEN_EAGER_SPECIFIERS.has(ext)).toBe(false)
      expect(ext.startsWith('@antv/')).toBe(false)
    }
  })
})

describe('Theme tokens & pure viz theme utilities (`viz/theme.ts`)', () => {
  test('defines dedicated --chart-* CSS custom properties in light, dark, and @theme inline blocks', () => {
    const css = readFileSync(resolve(import.meta.dir, '../src/theme.css'), 'utf8')
    expect(css).toContain('--chart-up: #0f8a5f;')
    expect(css).toContain('--chart-down: #c81e3a;')
    expect(css).toContain('--chart-up: #2ec28b;')
    expect(css).toContain('--chart-down: #f2556a;')
    expect(css).toContain('--chart-1: #b31b5d;')
    expect(css).toContain('--chart-1: #d83d82;')
    expect(css).toContain('--chart-other: var(--color-gray-50);')
    expect(css).toContain('--chart-empty: var(--color-gray-30);')
    expect(css).toContain('--chart-empty: var(--color-gray-70);')
    expect(css).toContain('--color-chart-up: var(--chart-up);')
    expect(css).toContain('--color-chart-5: var(--chart-5);')
  })

  test('resolves light/dark palettes and swaps up/down tokens cleanly for Mainland China A-share (`cn`) convention', () => {
    const lightIntl = resolveVizTheme(null, { theme: 'light', marketConvention: 'intl' })
    const lightCn = resolveVizTheme(null, { theme: 'light', marketConvention: 'cn' })
    expect(lightIntl.isDark).toBe(false)
    expect(lightIntl.up).toBe('#0f8a5f')
    expect(lightIntl.down).toBe('#c81e3a')
    expect(lightCn.up).toBe('#c81e3a')
    expect(lightCn.down).toBe('#0f8a5f')
    expect(lightCn.upSubtle).toBe(lightIntl.downSubtle)
    expect(lightCn.downForeground).toBe(lightIntl.upForeground)

    const darkIntl = resolveVizTheme(null, {
      theme: 'dark',
      marketConvention: 'intl',
      tokenOverrides: { '--chart-1': '#123456' }
    })
    expect(darkIntl.isDark).toBe(true)
    expect(darkIntl.up).toBe('#2ec28b')
    expect(darkIntl.down).toBe('#f2556a')
    expect(darkIntl.categorical[0]).toBe('#123456')
    expect(darkIntl.otherColor).not.toBe(darkIntl.emptyColor)
  })

  test('assigns series colors strictly in rank order (never hashing) while honoring optionColor, Other, and Empty', () => {
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

    expect(orderA.get('North America')).toBe(palette.categorical[0])
    expect(orderA.get('APAC')).toBe(palette.categorical[1])
    // Rank-order proof: when APAC ranks #1, it receives slot 0 rather than a hash-derived slot.
    expect(orderB.get('APAC')).toBe(palette.categorical[0])
    expect(orderB.get('North America')).toBe(palette.categorical[1])

    expect(orderA.get('Priority')).toBe(resolveSelectOptionColor('teal', false))
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
  test('falls back from percent to stacked on negative values, guards zero-sum buckets, and supports all 19 chart types', () => {
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
      'wordcloud'
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
    expect(intlColored[0]?.color).toBe('#0f8a5f')
    expect(intlColored[1]?.color).toBe('#c81e3a')
    expect(intlColored[2]?.color).toBe('#112233')

    const cnColored = colorizeVolumePoints(volume, candles, cnPalette)
    expect(cnColored[0]?.color).toBe('#c81e3a')
    expect(cnColored[1]?.color).toBe('#0f8a5f')
    expect(mapPriceScaleMode('logarithmic')).toBe(1)
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
