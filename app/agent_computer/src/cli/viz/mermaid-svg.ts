import {
  isPrintSafeSvg,
  resolveVizTheme,
  sanitizeExportedSvg,
  type MarketConvention,
  type VizThemeMode,
  type VizThemePalette
} from '@ankole/uikit/viz/theme'
import { PeleError } from 'pele/core'
import { renderAsync } from 'pele/lazy'

export interface RenderMermaidSvgOptions {
  theme?: VizThemeMode
  marketConvention?: MarketConvention
  tokenOverrides?: Partial<Record<string, string>>
  width?: number
  height?: number
}

export interface RenderedMermaidSvg {
  svg: string
  width: number
  height: number
  printSafe: boolean
}

export function formatMermaidSyntaxError(error: unknown): string {
  if (error instanceof PeleError) {
    return error.message.trim()
  }
  if (error instanceof Error && error.message.trim()) {
    return error.message.trim()
  }
  return 'Invalid Mermaid syntax.'
}

function buildPeleTokenMap(palette: VizThemePalette): Record<string, string> {
  const seriesColors = [...palette.categorical, ...palette.extendedCategorical]
  const map: Record<string, string> = {
    '--pele-bg': palette.background,
    '--pele-fg': palette.foreground,
    '--pele-fg-on-light': '#18191a',
    '--pele-fg-on-dark': '#f4f4f2',
    '--pele-muted': palette.fgTertiary,
    '--pele-line': palette.fgSecondary,
    '--pele-surface': palette.layer01,
    '--pele-surface-alt': palette.isDark ? palette.layer02 : palette.border,
    '--pele-border': palette.borderStrong,
    '--pele-accent': palette.categorical[0],
    '--pele-critical': palette.down,
    '--pele-error': palette.down,
    '--pele-font': palette.fontSans,
    '--pele-font-mono': palette.fontMono,
    '--pele-radius': '4px',
    '--pele-zoom-top': '8px',
    '--pele-zoom-right': '8px',
    '--pele-zoom-bottom': 'auto',
    '--pele-zoom-left': 'auto',
    '--pele-zoom-cursor': 'pointer',
    '--_bg': palette.background,
    '--_fg': palette.foreground,
    '--_m': palette.fgTertiary,
    '--_l': palette.fgSecondary,
    '--_s': palette.layer01,
    '--_a': palette.isDark ? palette.layer02 : palette.border,
    '--_b': palette.borderStrong,
    '--_c': palette.categorical[0],
    '--_r': '4px',
    '--_fm': palette.fontMono,
    '--_hw': 'bold',
    '--_tw': 'bold',
    '--_w': 'bold'
  }
  for (let i = 0; i < seriesColors.length; i += 1) {
    map[`--pele-series-${i + 1}`] = seriesColors[i]!
  }
  return map
}

function replaceSingleLevelVars(input: string, tokens: Readonly<Record<string, string>>): string {
  return input.replace(/var\(\s*(--[a-zA-Z0-9_-]+)(?:\s*,\s*([^()]+))?\s*\)/g, (full, name: string, fb?: string) => {
    const resolved = tokens[name]
    if (resolved !== undefined) return resolved
    if (fb !== undefined) return fb.trim()
    return full
  })
}

function escapeXmlAttr(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/"/g, '&quot;')
}

/**
 * Resolves all Pele CSS custom properties (`--pele-*` and `--_*`) into concrete palette
 * values, strips inline custom property declarations, converts CSS `rx` styles to SVG
 * `rx` attributes, and inserts a solid background `<rect>` so offline PDF engines
 * (`typst` / `resvg`, `xelatex`, `weasyprint`) render standalone SVG output faithfully.
 */
export function materializePeleSvg(
  rawSvg: string,
  palette: VizThemePalette,
  dimensions?: { width?: number; height?: number }
): { svg: string; width: number; height: number } {
  const tokenMap = buildPeleTokenMap(palette)

  let output = rawSvg
  // Multi-pass resolution handles nested `var(--_bg: var(--pele-bg, #fff))` declarations.
  for (let pass = 0; pass < 4; pass += 1) {
    const next = replaceSingleLevelVars(output, tokenMap)
    // Harvest any newly materialized `--_foo: value` declarations from style attributes.
    const declRe = /(--_[a-zA-Z0-9_-]+)\s*:\s*([^;"]+)/g
    for (const match of next.matchAll(declRe)) {
      const propName = match[1]!
      const propVal = match[2]!.trim()
      if (propVal && !propVal.includes('var(--')) {
        tokenMap[propName] = propVal
      }
    }
    output = next
    if (!/var\(\s*--/.test(output)) break
  }

  // Final pass after harvesting internal `--_*` declarations.
  for (let pass = 0; pass < 2 && /var\(\s*--/.test(output); pass += 1) {
    output = replaceSingleLevelVars(output, tokenMap)
  }

  // Convert `style="rx:4px"` on `<rect>` elements into standard `rx="4"` SVG attributes for resvg.
  output = output.replace(/\sstyle="rx:\s*([\d.]+)(?:px)?\s*;?\s*"/gi, ' rx="$1"')

  // Strip `--_*` custom property declarations from inline style="..." attributes and escape quotes.
  output = output.replace(/\bstyle="([^"]*)"/g, (_full, styleContent: string) => {
    const kept = styleContent
      .split(';')
      .map(part => part.trim())
      .filter(part => part.length > 0 && !part.startsWith('--'))
    if (kept.length === 0) return ''
    return `style="${escapeXmlAttr(kept.join(';'))}"`
  })

  // Apply safety padding and palette sanitization via `@ankole/uikit/viz/theme`.
  output = sanitizeExportedSvg(output, palette, { safetyPaddingPx: 8 })

  // Read expanded viewBox dimensions and inject explicit width/height + solid background rect.
  let finalWidth = dimensions?.width ?? 480
  let finalHeight = dimensions?.height ?? 320

  const vbMatch = /\bviewBox\s*=\s*(['"])\s*([-+\d.]+)\s+([-+\d.]+)\s+([-+\d.]+)\s+([-+\d.]+)\s*\1/i.exec(output)
  let vbX = 0
  let vbY = 0
  let vbW = finalWidth
  let vbH = finalHeight

  if (vbMatch) {
    vbX = Number.parseFloat(vbMatch[2]!)
    vbY = Number.parseFloat(vbMatch[3]!)
    vbW = Number.parseFloat(vbMatch[4]!)
    vbH = Number.parseFloat(vbMatch[5]!)
    if (dimensions?.width && dimensions?.height) {
      finalWidth = Math.round(dimensions.width)
      finalHeight = Math.round(dimensions.height)
    } else if (dimensions?.width && vbW > 0) {
      finalWidth = Math.round(dimensions.width)
      finalHeight = Math.max(1, Math.round((dimensions.width * vbH) / vbW))
    } else if (dimensions?.height && vbH > 0) {
      finalHeight = Math.round(dimensions.height)
      finalWidth = Math.max(1, Math.round((dimensions.height * vbW) / vbH))
    } else {
      finalWidth = Math.max(1, Math.ceil(vbW))
      finalHeight = Math.max(1, Math.ceil(vbH))
    }
  }

  output = output.replace(/<svg\b([^>]*)>/i, (_openTag, attrs: string) => {
    let nextAttrs = attrs.replace(/\swidth\s*=\s*(['"])[^'"]*\1/i, '').replace(/\sheight\s*=\s*(['"])[^'"]*\1/i, '')
    nextAttrs = `${nextAttrs} width="${finalWidth}" height="${finalHeight}"`
    const bgRect = `<rect x="${vbX}" y="${vbY}" width="${vbW}" height="${vbH}" fill="${escapeXmlAttr(palette.background)}"/>`
    return `<svg${nextAttrs}>${bgRect}`
  })

  return { svg: output, width: finalWidth, height: finalHeight }
}

/**
 * Validates Mermaid diagram syntax directly in Bun via `pele` (`renderAsync`).
 */
export async function validateMermaidSyntax(source: string): Promise<{ ok: true } | { ok: false; errors: string[] }> {
  const trimmed = source.trim()
  if (!trimmed) {
    return { ok: false, errors: ['Mermaid diagram source is empty.'] }
  }
  try {
    await renderAsync(trimmed, { links: false, images: false, responsive: true })
    return { ok: true }
  } catch (error) {
    return { ok: false, errors: [formatMermaidSyntaxError(error)] }
  }
}

/**
 * Renders a Mermaid diagram directly in Bun via `pele` (`renderAsync`) into a Print-Safe SVG
 * without launching headless Chromium.
 */
export async function renderMermaidSvgInBun(
  source: string,
  options?: RenderMermaidSvgOptions
): Promise<RenderedMermaidSvg> {
  const trimmed = source.trim()
  if (!trimmed) {
    throw new Error('Mermaid diagram source is empty.')
  }

  const palette = resolveVizTheme(null, {
    theme: options?.theme ?? 'light',
    marketConvention: options?.marketConvention ?? 'intl',
    tokenOverrides: options?.tokenOverrides
  })

  let rendered
  try {
    rendered = await renderAsync(trimmed, {
      links: false,
      images: false,
      responsive: false,
      fontFamily: palette.fontSans,
      fontFamilyMono: palette.fontMono,
      ...(options?.width ? { maxWidth: options.width } : {})
    })
  } catch (error) {
    throw new Error(formatMermaidSyntaxError(error))
  }

  const materialized = materializePeleSvg(rendered.svg, palette, {
    width: options?.width,
    height: options?.height
  })
  const printSafe = isPrintSafeSvg(materialized.svg)
  if (!printSafe) {
    throw new Error('Rendered Mermaid SVG failed Print-Safe verification.')
  }

  return {
    svg: materialized.svg,
    width: materialized.width,
    height: materialized.height,
    printSafe
  }
}
