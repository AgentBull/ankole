import { PeleError } from 'pele/core'
import { renderAsync, type DiagramType } from 'pele/lazy'

export type MermaidThemeMode = 'light' | 'dark'

export interface RenderedMermaidDiagram {
  svg: string
  width: number
  height: number
  diagramType: DiagramType
}

const MAX_CACHE_ENTRIES = 48
const diagramCache = new Map<string, RenderedMermaidDiagram>()

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
    accent: '#1561ff',
    critical: '#d92d20'
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
    accent: '#77a9ff',
    critical: '#f97066'
  }
}

export function resolveActiveMermaidTheme(doc: Document | undefined = globalThis.document): MermaidThemeMode {
  return doc?.documentElement?.dataset?.theme === 'dark' ? 'dark' : 'light'
}

export function buildPelePaletteCssVars(theme: MermaidThemeMode): string {
  const p = MERMAID_PALETTES[theme]
  return [
    `--pele-bg:${p.bg}`,
    `--pele-fg:${p.fg}`,
    `--pele-fg-on-light:${p.fgOnLight}`,
    `--pele-fg-on-dark:${p.fgOnDark}`,
    `--pele-muted:${p.muted}`,
    `--pele-line:${p.line}`,
    `--pele-surface:${p.surface}`,
    `--pele-surface-alt:${p.surfaceAlt}`,
    `--pele-border:${p.border}`,
    `--pele-accent:${p.accent}`,
    `--pele-critical:${p.critical}`,
    `--pele-error:${p.critical}`,
    `--pele-font:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif`,
    `--pele-font-mono:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace`,
    `--pele-radius:6px`
  ].join(';')
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

export function getCachedMermaidDiagram(code: string, theme: MermaidThemeMode): RenderedMermaidDiagram | undefined {
  const key = `${theme}\0${code.trim()}`
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

  const cached = getCachedMermaidDiagram(trimmed, theme)
  if (cached) return cached

  const rendered = await renderAsync(trimmed, {
    links: false,
    images: false,
    responsive: true
  })

  const entry: RenderedMermaidDiagram = {
    svg: rendered.svg,
    width: Math.max(1, Math.ceil(rendered.width || 480)),
    height: Math.max(1, Math.ceil(rendered.height || 320)),
    diagramType: rendered.type
  }

  const key = `${theme}\0${trimmed}`
  if (diagramCache.has(key)) diagramCache.delete(key)
  diagramCache.set(key, entry)
  while (diagramCache.size > MAX_CACHE_ENTRIES) {
    const oldest = diagramCache.keys().next().value
    if (oldest === undefined) break
    diagramCache.delete(oldest)
  }

  return entry
}

export function formatMermaidRenderError(error: unknown): string {
  if (error instanceof PeleError) {
    return error.message.replace(/\s+/g, ' ').trim()
  }
  if (error instanceof Error && error.message) {
    return error.message.replace(/\s+/g, ' ').trim()
  }
  return 'Invalid Mermaid syntax'
}
