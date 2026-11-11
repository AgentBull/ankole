import {
  buildPeleCssVarsString,
  parseSvgDimensions,
  resolveVizTheme,
  type VizThemePalette
} from '@ankole/uikit/viz/theme'
import { PeleError } from 'pele/core'
import { renderAsync, type DiagramType } from 'pele/lazy'

export type MermaidThemeMode = 'light' | 'dark'
export type ChatDiagramKind = 'mermaid' | 'infographic'

export interface RenderedMermaidDiagram {
  svg: string
  width: number
  height: number
  diagramType: DiagramType | 'infographic'
}

const MAX_CACHE_ENTRIES = 48
const diagramCache = new Map<string, RenderedMermaidDiagram>()

// A downloaded diagram names the Pod's faces first. When the Worker rasterises an exported SVG, it maps the aliases
// `IBMPlexSansCN` and `IBMPlexMonoCN` to its installed fonts, so each list names that alias next.
export const DIAGRAM_HOST_FONT_SANS =
  "'AgentBullSansGB','IBMPlexSansCN','PingFang SC','Hiragino Sans GB','Microsoft YaHei','Noto Sans CJK SC',system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif"
export const DIAGRAM_HOST_FONT_MONO =
  "'AgentBullMono','IBMPlexMonoCN',ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace"

export const MERMAID_PALETTES: Record<
  MermaidThemeMode,
  {
    bg: string
    fg: string
    fgOnLight: string
    fgOnDark: string
    muted: string
    line: string
    surface: string
    surfaceAlt: string
    border: string
    accent: string
    critical: string
  }
> = {
  light: {
    bg: '#fffefd',
    fg: '#18191a',
    fgOnLight: '#18191a',
    fgOnDark: '#f4f4f2',
    muted: '#636566',
    line: '#47494a',
    surface: '#f4f4f2',
    surfaceAlt: '#e5e4e1',
    border: '#cbcac7',
    accent: '#2864b9',
    critical: '#c1384b'
  },
  dark: {
    bg: '#18191a',
    fg: '#f4f4f2',
    fgOnLight: '#18191a',
    fgOnDark: '#f4f4f2',
    muted: '#abaaa7',
    line: '#cbcac7',
    surface: '#232526',
    surfaceAlt: '#343637',
    border: '#47494a',
    accent: '#5d98e7',
    critical: '#eb6b7d'
  }
}

export function resolveActiveMermaidTheme(doc: Document | undefined = globalThis.document): MermaidThemeMode {
  return doc?.documentElement?.dataset?.theme === 'dark' ? 'dark' : 'light'
}

function resolveChatMermaidPalette(theme: MermaidThemeMode): VizThemePalette {
  const p = MERMAID_PALETTES[theme]
  return resolveVizTheme(null, {
    theme,
    tokenOverrides: {
      '--background': p.bg,
      '--foreground': p.fg,
      '--fg-secondary': p.line,
      '--fg-tertiary': p.muted,
      '--layer-01': p.surface,
      '--layer-02': p.surfaceAlt,
      '--border': p.surfaceAlt,
      '--border-strong': p.border,
      '--chart-1': p.accent,
      '--chart-down': p.critical
    }
  })
}

export function buildPelePaletteCssVars(theme: MermaidThemeMode): string {
  return buildPeleCssVarsString(resolveChatMermaidPalette(theme), {
    radius: '6px',
    fontSans: DIAGRAM_HOST_FONT_SANS,
    fontMono: DIAGRAM_HOST_FONT_MONO
  })
}

/**
 * Expands the SVG `viewBox` by `pad` pixels on all four sides so wide CJK glyphs rendered
 * with sandbox fallback fonts never clip against node or canvas boundaries.
 */
export function expandSvgViewBox(svg: string, pad = 6): { svg: string; width?: number; height?: number } {
  if (pad <= 0) return { svg }
  let nextWidth: number | undefined
  let nextHeight: number | undefined
  const updated = svg.replace(/<svg\b([^>]*)>/i, (_full, attrs: string) => {
    const vbMatch = /\bviewBox\s*=\s*(['"])\s*([-+\d.]+)\s+([-+\d.]+)\s+([-+\d.]+)\s+([-+\d.]+)\s*\1/i.exec(attrs)
    if (!vbMatch) return `<svg${attrs}>`
    const quote = vbMatch[1]!
    const x = Number.parseFloat(vbMatch[2]!)
    const y = Number.parseFloat(vbMatch[3]!)
    const w = Number.parseFloat(vbMatch[4]!)
    const h = Number.parseFloat(vbMatch[5]!)
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(w) || !Number.isFinite(h)) {
      return `<svg${attrs}>`
    }
    nextWidth = Math.max(1, Math.ceil(w + pad * 2))
    nextHeight = Math.max(1, Math.ceil(h + pad * 2))
    const nextAttrs = attrs.replace(
      vbMatch[0],
      `viewBox=${quote}${x - pad} ${y - pad} ${w + pad * 2} ${h + pad * 2}${quote}`
    )
    return `<svg${nextAttrs}>`
  })
  return { svg: updated, width: nextWidth, height: nextHeight }
}

export function injectStandaloneSvgTheme(svg: string, theme: MermaidThemeMode): string {
  const paletteVars = buildPelePaletteCssVars(theme)
  const bg = MERMAID_PALETTES[theme].bg
  const styleTag = `<style>:root,svg{${paletteVars};background:${bg};font-family:var(--pele-font);}</style>`
  const openTagEnd = svg.indexOf('>')
  if (openTagEnd === -1) return svg
  let openTag = svg.slice(0, openTagEnd + 1)
  if (!/\bxmlns=/.test(openTag)) {
    openTag = `${openTag.slice(0, -1)} xmlns="http://www.w3.org/2000/svg">`
  }
  return openTag + styleTag + svg.slice(openTagEnd + 1)
}

function cacheKey(kind: ChatDiagramKind, theme: MermaidThemeMode, code: string): string {
  return `${kind}\0${theme}\0${code.trim()}`
}

function storeCachedDiagram(key: string, entry: RenderedMermaidDiagram): void {
  if (diagramCache.has(key)) diagramCache.delete(key)
  diagramCache.set(key, entry)
  while (diagramCache.size > MAX_CACHE_ENTRIES) {
    const oldest = diagramCache.keys().next().value
    if (oldest === undefined) break
    diagramCache.delete(oldest)
  }
}

export function getCachedChatDiagram(
  code: string,
  theme: MermaidThemeMode,
  kind: ChatDiagramKind = 'mermaid'
): RenderedMermaidDiagram | undefined {
  const key = cacheKey(kind, theme, code)
  const hit = diagramCache.get(key)
  if (!hit) return undefined
  diagramCache.delete(key)
  diagramCache.set(key, hit)
  return hit
}

export async function renderMermaidDiagram(code: string, theme: MermaidThemeMode): Promise<RenderedMermaidDiagram> {
  const trimmed = code.trim()
  if (!trimmed) {
    throw new Error('Empty Mermaid source')
  }

  const cached = getCachedChatDiagram(trimmed, theme, 'mermaid')
  if (cached) return cached

  const rendered = await renderAsync(trimmed, {
    links: false,
    images: false,
    responsive: true
  })

  const padded = expandSvgViewBox(rendered.svg, 6)
  const entry: RenderedMermaidDiagram = {
    svg: padded.svg,
    width: padded.width ?? Math.max(1, Math.ceil(rendered.width || 480)),
    height: padded.height ?? Math.max(1, Math.ceil(rendered.height || 320)),
    diagramType: rendered.type
  }

  storeCachedDiagram(cacheKey('mermaid', theme, trimmed), entry)
  return entry
}

export async function renderInfographicDiagram(code: string, theme: MermaidThemeMode): Promise<RenderedMermaidDiagram> {
  const trimmed = code.trim()
  if (!trimmed) {
    throw new Error('Empty Infographic source')
  }

  const cached = getCachedChatDiagram(trimmed, theme, 'infographic')
  if (cached) return cached

  const { mountInfographicAsync, validateInfographicSyntax } = await import('@ankole/uikit/viz/infographic')
  const validation = validateInfographicSyntax(trimmed)
  if (!validation.ok) {
    throw new Error(validation.errors[0] ?? 'Invalid Infographic syntax')
  }

  if (typeof globalThis.document === 'undefined' || !globalThis.document.body) {
    throw new Error('DOM environment required to render Infographic')
  }

  const container = globalThis.document.createElement('div')
  container.setAttribute('data-theme', theme)
  container.style.cssText = 'position:fixed;left:-9999px;top:0;width:760px;visibility:hidden;pointer-events:none;'
  globalThis.document.body.appendChild(container)

  try {
    const mounted = await mountInfographicAsync(container, trimmed, {
      theme,
      zoom: false,
      width: 760
    })
    try {
      const { svg } = await mounted.exportSVG()
      const dims = parseSvgDimensions(svg)
      const entry: RenderedMermaidDiagram = {
        svg,
        width: dims.width,
        height: dims.height,
        diagramType: 'infographic'
      }
      storeCachedDiagram(cacheKey('infographic', theme, trimmed), entry)
      return entry
    } finally {
      mounted.destroy()
    }
  } finally {
    container.remove()
  }
}

export async function renderChatDiagram(
  code: string,
  theme: MermaidThemeMode,
  kind: ChatDiagramKind = 'mermaid'
): Promise<RenderedMermaidDiagram> {
  return kind === 'infographic' ? renderInfographicDiagram(code, theme) : renderMermaidDiagram(code, theme)
}

export function formatMermaidRenderError(error: unknown): string {
  if (error instanceof PeleError) {
    return error.message.replace(/\s+/g, ' ').trim()
  }
  if (error instanceof Error && error.message) {
    return error.message.replace(/\s+/g, ' ').trim()
  }
  return 'Invalid diagram syntax'
}
