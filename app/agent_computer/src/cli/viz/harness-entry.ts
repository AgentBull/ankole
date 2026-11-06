import { mountFinancialChart, type FinancialChartSpec } from '@ankole/uikit/viz/financial'
import { mountGraphViz, type GraphVizSpec } from '@ankole/uikit/viz/graph'
import { mountInfographicAsync } from '@ankole/uikit/viz/infographic'
import { mountStatisticalChart, type StatisticalChartSpec } from '@ankole/uikit/viz/statistical'
import {
  isPrintSafeSvg,
  resolveVizTheme,
  sanitizeExportedSvg,
  type MarketConvention,
  type VizThemeMode,
  type VizThemePalette
} from '@ankole/uikit/viz/theme'

export type HarnessChromeMode = 'bare' | 'card'

export type HarnessJobPayload =
  | {
      kind: 'chart'
      spec: StatisticalChartSpec
      format: 'svg' | 'png'
      theme: VizThemeMode
      market: MarketConvention
      chrome: HarnessChromeMode
      tokenOverrides?: Partial<Record<string, string>>
      width: number
      height: number
      pdfSafe: boolean
      cardTitle?: string
      cardSubtitle?: string
    }
  | {
      kind: 'kline'
      spec: FinancialChartSpec
      format: 'png'
      theme: VizThemeMode
      market: MarketConvention
      chrome: HarnessChromeMode
      tokenOverrides?: Partial<Record<string, string>>
      width: number
      height: number
      pdfSafe: boolean
      cardTitle?: string
      cardSubtitle?: string
    }
  | {
      kind: 'graph'
      spec: GraphVizSpec
      format: 'svg' | 'png'
      theme: VizThemeMode
      market: MarketConvention
      chrome: HarnessChromeMode
      tokenOverrides?: Partial<Record<string, string>>
      width: number
      height: number
      pdfSafe: boolean
      cardTitle?: string
      cardSubtitle?: string
    }
  | {
      kind: 'infographic'
      source: string
      format: 'svg' | 'png'
      theme: VizThemeMode
      market: MarketConvention
      chrome: HarnessChromeMode
      tokenOverrides?: Partial<Record<string, string>>
      width?: number
      height?: number
      pdfSafe: boolean
      cardTitle?: string
      cardSubtitle?: string
    }
  | {
      kind: 'mermaid'
      svgMarkup: string
      format: 'png'
      theme: VizThemeMode
      market: MarketConvention
      chrome: HarnessChromeMode
      tokenOverrides?: Partial<Record<string, string>>
      width: number
      height: number
      pdfSafe: boolean
      cardTitle?: string
      cardSubtitle?: string
    }

export interface HarnessJobOutcome {
  svg?: string
  svgWidth?: number
  svgHeight?: number
  isPrintSafe: boolean
  needsPngCapture: boolean
  fallbackReason?: 'foreignObject' | 'canvas'
}

export interface AnkoleVizBrowserHarness {
  runJob: (job: HarnessJobPayload) => Promise<HarnessJobOutcome>
  cleanup: () => void
}

declare global {
  interface Window {
    __ANKOLE_VIZ_HARNESS__?: AnkoleVizBrowserHarness
  }
}

const CJK_FONT_SANS = "'IBMPlexSansCN', 'IBM Plex Sans SC', 'Noto Sans CJK SC', 'PingFang SC', sans-serif"
const CJK_FONT_MONO =
  "'IBMPlexMonoCN', 'IBMPlexMonoSCHalf', 'IBM Plex Mono', 'SFMono-Regular', Consolas, 'Liberation Mono', monospace"

let activeDestroy: (() => void) | null = null

function nextFrame(): Promise<void> {
  return new Promise(resolve => {
    requestAnimationFrame(() => {
      requestAnimationFrame(() => resolve())
    })
  })
}

function applyPaletteToRoot(palette: VizThemePalette): void {
  const root = document.documentElement
  root.setAttribute('data-theme', palette.isDark ? 'dark' : 'light')
  const props: Record<string, string> = {
    '--background': palette.background,
    '--color-background': palette.background,
    '--layer-01': palette.layer01,
    '--color-layer-01': palette.layer01,
    '--layer-02': palette.layer02,
    '--color-layer-02': palette.layer02,
    '--foreground': palette.foreground,
    '--color-foreground': palette.foreground,
    '--fg-secondary': palette.fgSecondary,
    '--color-fg-secondary': palette.fgSecondary,
    '--fg-tertiary': palette.fgTertiary,
    '--color-fg-tertiary': palette.fgTertiary,
    '--border': palette.border,
    '--color-border': palette.border,
    '--border-strong': palette.borderStrong,
    '--font-family-sans': CJK_FONT_SANS,
    '--font-family-mono': CJK_FONT_MONO,
    '--chart-1': palette.categorical[0],
    '--chart-2': palette.categorical[1],
    '--chart-3': palette.categorical[2],
    '--chart-4': palette.categorical[3],
    '--chart-5': palette.categorical[4],
    '--chart-other': palette.otherColor,
    '--chart-empty': palette.emptyColor,
    '--chart-total': palette.totalColor,
    '--chart-up': palette.up,
    '--chart-up-foreground': palette.upForeground,
    '--chart-up-subtle': palette.upSubtle,
    '--chart-down': palette.down,
    '--chart-down-foreground': palette.downForeground,
    '--chart-down-subtle': palette.downSubtle
  }
  for (const [k, v] of Object.entries(props)) {
    root.style.setProperty(k, v)
  }
}

function createStageElements(
  palette: VizThemePalette,
  chrome: HarnessChromeMode,
  cardTitle?: string,
  cardSubtitle?: string
): { stage: HTMLDivElement; mount: HTMLDivElement } {
  let rootHost = document.getElementById('viz-root')
  if (!rootHost) {
    rootHost = document.createElement('div')
    rootHost.id = 'viz-root'
    document.body.appendChild(rootHost)
  }
  rootHost.innerHTML = ''

  const stage = document.createElement('div')
  stage.id = 'viz-stage'
  if (chrome === 'card') {
    stage.style.cssText = [
      'display:inline-flex',
      'flex-direction:column',
      'gap:10px',
      'box-sizing:border-box',
      `background:${palette.background}`,
      `border:1px solid ${palette.border}`,
      'padding:16px',
      `color:${palette.foreground}`,
      `font-family:${CJK_FONT_SANS}`
    ].join(';')

    if (cardTitle || cardSubtitle) {
      const header = document.createElement('div')
      header.style.cssText = 'display:flex;flex-direction:column;gap:3px;'
      if (cardTitle) {
        const h = document.createElement('div')
        h.textContent = cardTitle
        h.style.cssText = `font-size:15px;font-weight:600;line-height:1.35;color:${palette.foreground};`
        header.appendChild(h)
      }
      if (cardSubtitle) {
        const sub = document.createElement('div')
        sub.textContent = cardSubtitle
        sub.style.cssText = `font-size:12px;font-weight:400;line-height:1.4;color:${palette.fgSecondary};`
        header.appendChild(sub)
      }
      stage.appendChild(header)
    }
  } else {
    stage.style.cssText = [
      'display:inline-block',
      'box-sizing:border-box',
      `background:${palette.background}`,
      'padding:0',
      'margin:0',
      'border:none',
      `color:${palette.foreground}`,
      `font-family:${CJK_FONT_SANS}`
    ].join(';')
  }

  const mount = document.createElement('div')
  mount.id = 'viz-mount'
  mount.style.cssText = 'position:relative;box-sizing:border-box;margin:0;padding:0;'
  stage.appendChild(mount)
  rootHost.appendChild(stage)

  return { stage, mount }
}

function parseSvgDimensions(svg: string, fallbackW: number, fallbackH: number): { width: number; height: number } {
  const vb = /\bviewBox\s*=\s*(['"])\s*([-+\d.]+)\s+([-+\d.]+)\s+([-+\d.]+)\s+([-+\d.]+)\s*\1/i.exec(svg)
  if (vb) {
    const w = Number.parseFloat(vb[4]!)
    const h = Number.parseFloat(vb[5]!)
    if (Number.isFinite(w) && w > 0 && Number.isFinite(h) && h > 0) {
      return { width: Math.ceil(w), height: Math.ceil(h) }
    }
  }
  const wAttr = /\bwidth\s*=\s*(['"])([-+\d.]+)(?:px)?\1/i.exec(svg)
  const hAttr = /\bheight\s*=\s*(['"])([-+\d.]+)(?:px)?\1/i.exec(svg)
  const w = wAttr ? Number.parseFloat(wAttr[2]!) : Number.NaN
  const h = hAttr ? Number.parseFloat(hAttr[2]!) : Number.NaN
  return {
    width: Number.isFinite(w) && w > 0 ? Math.ceil(w) : fallbackW,
    height: Number.isFinite(h) && h > 0 ? Math.ceil(h) : fallbackH
  }
}

function addCardFrameToSvg(svg: string, palette: VizThemePalette): string {
  const vb = /\bviewBox\s*=\s*(['"])\s*([-+\d.]+)\s+([-+\d.]+)\s+([-+\d.]+)\s+([-+\d.]+)\s*\1/i.exec(svg)
  if (!vb) return svg
  const x = Number.parseFloat(vb[2]!)
  const y = Number.parseFloat(vb[3]!)
  const w = Number.parseFloat(vb[4]!)
  const h = Number.parseFloat(vb[5]!)
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(w) || !Number.isFinite(h)) {
    return svg
  }
  const pad = 12
  const nx = x - pad
  const ny = y - pad
  const nw = w + pad * 2
  const nh = h + pad * 2
  const frameRect = `<rect x="${nx + 0.5}" y="${ny + 0.5}" width="${nw - 1}" height="${nh - 1}" fill="${palette.background}" stroke="${palette.border}" stroke-width="1"/>`
  return svg
    .replace(vb[0], `viewBox="${nx} ${ny} ${nw} ${nh}"`)
    .replace(/<svg\b([^>]*)>/i, (_m, attrs: string) => `<svg${attrs}>${frameRect}`)
}

function cleanupActive(): void {
  if (activeDestroy) {
    try {
      activeDestroy()
    } catch {
      // Ignore cleanup errors between jobs.
    }
    activeDestroy = null
  }
}

async function runJob(job: HarnessJobPayload): Promise<HarnessJobOutcome> {
  cleanupActive()

  const mergedOverrides: Partial<Record<string, string>> = {
    '--font-family-sans': CJK_FONT_SANS,
    '--font-family-mono': CJK_FONT_MONO,
    ...job.tokenOverrides
  }

  // Apply unswapped base (`intl`) CSS custom properties on `:root` because each `@ankole/uikit/viz/*`
  // engine calls `resolveVizTheme(container, { marketConvention: job.market })` and swaps `--chart-up`
  // and `--chart-down` once when `marketConvention === 'cn'`.
  const rootBasePalette = resolveVizTheme(null, {
    theme: job.theme,
    marketConvention: 'intl',
    tokenOverrides: mergedOverrides
  })
  applyPaletteToRoot(rootBasePalette)

  const palette = resolveVizTheme(null, {
    theme: job.theme,
    marketConvention: job.market,
    tokenOverrides: mergedOverrides
  })
  await document.fonts.ready

  const { mount } = createStageElements(palette, job.chrome, job.cardTitle, job.cardSubtitle)

  if (job.kind === 'chart') {
    mount.style.width = `${job.width}px`
    mount.style.height = `${job.height}px`

    const chartSpec: StatisticalChartSpec = {
      ...job.spec,
      // Avoid rendering duplicate title inside G2 when card header already displays it in PNG mode.
      ...(job.chrome === 'card' && job.format === 'png' && job.cardTitle
        ? { title: undefined, subtitle: undefined }
        : {}),
      width: job.width,
      height: job.height,
      renderer: 'svg',
      theme: job.theme,
      marketConvention: job.market,
      tokenOverrides: mergedOverrides,
      animate: false
    }

    const mounted = await mountStatisticalChart(mount, chartSpec)
    activeDestroy = () => mounted.destroy()
    await nextFrame()

    if (job.format === 'svg') {
      let svg = await mounted.exportSVG()
      if (job.chrome === 'card') {
        svg = addCardFrameToSvg(svg, palette)
      }
      const printSafe = isPrintSafeSvg(svg)
      if (!printSafe && job.pdfSafe) {
        return {
          isPrintSafe: true,
          needsPngCapture: true,
          fallbackReason: 'foreignObject'
        }
      }
      const dims = parseSvgDimensions(svg, job.width, job.height)
      return {
        svg,
        svgWidth: dims.width,
        svgHeight: dims.height,
        isPrintSafe: printSafe,
        needsPngCapture: false
      }
    }

    return {
      isPrintSafe: true,
      needsPngCapture: true
    }
  }

  if (job.kind === 'kline') {
    mount.style.width = `${job.width}px`
    mount.style.height = `${job.height}px`

    const klineSpec: FinancialChartSpec = {
      ...job.spec,
      width: job.width,
      height: job.height,
      theme: job.theme,
      marketConvention: job.market,
      tokenOverrides: mergedOverrides,
      attributionLogo: job.spec.attributionLogo ?? true
    }

    const mounted = mountFinancialChart(mount, klineSpec)
    activeDestroy = () => mounted.destroy()
    mounted.fitContent()
    await nextFrame()

    return {
      isPrintSafe: true,
      needsPngCapture: true,
      ...(job.pdfSafe ? { fallbackReason: 'canvas' } : {})
    }
  }

  if (job.kind === 'graph') {
    mount.style.width = `${job.width}px`
    mount.style.height = `${job.height}px`

    const graphSpec: GraphVizSpec = {
      ...job.spec,
      width: job.width,
      height: job.height,
      theme: job.theme,
      renderer: 'svg',
      animate: false,
      interactive: false
    }

    const mounted = await mountGraphViz(mount, graphSpec)
    activeDestroy = () => mounted.destroy()
    await nextFrame()

    if (job.format === 'svg') {
      let svg = await mounted.exportSVG()
      if (job.chrome === 'card') {
        svg = addCardFrameToSvg(svg, palette)
      }
      const printSafe = isPrintSafeSvg(svg)
      if (!printSafe && job.pdfSafe) {
        return {
          isPrintSafe: true,
          needsPngCapture: true,
          fallbackReason: 'foreignObject'
        }
      }
      const dims = parseSvgDimensions(svg, job.width, job.height)
      return {
        svg,
        svgWidth: dims.width,
        svgHeight: dims.height,
        isPrintSafe: printSafe,
        needsPngCapture: false
      }
    }

    return {
      isPrintSafe: true,
      needsPngCapture: true
    }
  }

  if (job.kind === 'infographic') {
    if (job.width) {
      mount.style.width = `${job.width}px`
    }
    if (job.height) {
      mount.style.height = `${job.height}px`
    }

    const mounted = await mountInfographicAsync(mount, job.source, {
      theme: job.theme,
      marketConvention: job.market,
      tokenOverrides: mergedOverrides,
      zoom: false,
      ...(job.width ? { width: job.width } : {}),
      ...(job.height ? { height: job.height } : {})
    })
    activeDestroy = () => mounted.destroy()
    await document.fonts.ready
    await nextFrame()

    const { svg: rawSvg, isPrintSafe } = await mounted.exportSVG()
    const svg = sanitizeExportedSvg(rawSvg, palette, { safetyPaddingPx: 8 })
    const safe = isPrintSafe && isPrintSafeSvg(svg)

    if (job.format === 'svg' && (!job.pdfSafe || safe)) {
      const finalSvg = job.chrome === 'card' ? addCardFrameToSvg(svg, palette) : svg
      const dims = parseSvgDimensions(finalSvg, job.width ?? 800, job.height ?? 480)
      return {
        svg: finalSvg,
        svgWidth: dims.width,
        svgHeight: dims.height,
        isPrintSafe: safe,
        needsPngCapture: false
      }
    }

    // Ensure crisp 1920px+ physical width when rasterizing to PNG (especially under --pdf-safe).
    const liveSvg = mount.querySelector('svg')
    const targetCssWidth = Math.max(job.width ?? 960, job.pdfSafe ? 960 : (job.width ?? 800))
    mount.style.width = `${targetCssWidth}px`
    mount.style.height = job.height ? `${job.height}px` : 'auto'
    if (liveSvg) {
      liveSvg.style.width = `${targetCssWidth}px`
      liveSvg.style.height = job.height ? `${job.height}px` : 'auto'
      liveSvg.style.display = 'block'
    }
    await nextFrame()

    return {
      isPrintSafe: true,
      needsPngCapture: true,
      ...(job.format === 'svg' && job.pdfSafe && !safe ? { fallbackReason: 'foreignObject' } : {})
    }
  }

  // `mermaid` PNG rasterization path
  mount.style.width = `${job.width}px`
  mount.innerHTML = job.svgMarkup
  const svgNode = mount.querySelector('svg')
  if (svgNode) {
    svgNode.style.width = `${job.width}px`
    svgNode.style.height = job.height ? `${job.height}px` : 'auto'
    svgNode.style.display = 'block'
  }
  await document.fonts.ready
  await nextFrame()

  return {
    isPrintSafe: true,
    needsPngCapture: true
  }
}

if (typeof window !== 'undefined') {
  window.__ANKOLE_VIZ_HARNESS__ = {
    runJob,
    cleanup: cleanupActive
  }
}
