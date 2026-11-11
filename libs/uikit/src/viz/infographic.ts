import {
  exportToSVG,
  getTemplate,
  Infographic,
  loadSVGResource,
  parseSyntax,
  registerResourceLoader,
  type InfographicOptions
} from '@antv/infographic'
import { isPrintSafeSvg, resolveVizTheme, sanitizeExportedSvg, type MarketConvention, type VizThemeMode } from './theme'

export const BUILTIN_INFOGRAPHIC_TEMPLATES = [
  'list-row-simple-horizontal-arrow',
  'list-row-horizontal-icon-arrow',
  'list-column-simple-vertical-arrow',
  'list-column-done-list',
  'list-grid-badge-card',
  'list-grid-compact-card',
  'list-pyramid-rounded-rect-node',
  'sequence-timeline-simple',
  'sequence-timeline-rounded-rect-node',
  'sequence-steps-simple',
  'sequence-snake-steps-simple',
  'sequence-funnel-simple',
  'sequence-roadmap-vertical-simple',
  'compare-swot',
  'compare-binary-horizontal-simple-fold',
  'compare-hierarchy-left-right-circle-node-pill-badge',
  'compare-hierarchy-left-right-circle-node-plain-text',
  'relation-circle-icon-badge',
  'relation-network-simple-circle-node',
  'chart-column-simple'
] as const

export type BuiltinInfographicTemplate = (typeof BUILTIN_INFOGRAPHIC_TEMPLATES)[number]

const SEMANTIC_ICON_PATHS: Record<string, string> = {
  check:
    '<path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>',
  star: '<path d="M12 3.2l2.7 5.5 6.1.9-4.4 4.3 1 6.1L12 17.1 6.6 20l1-6.1-4.4-4.3 6.1-.9L12 3.2z" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/>',
  arrow:
    '<path d="M4 12h15m0 0l-5.5-5.5M19 12l-5.5 5.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
  user: '<circle cx="12" cy="8" r="3.6" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M5 20c0-3.6 3.1-6 7-6s7 2.4 7 6" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/>',
  chart:
    '<path d="M4 19.5h16M7.5 16v-5M12 16V7M16.5 16v-8" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
  clock:
    '<circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M12 7.5v5l3.2 2" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>',
  shield:
    '<path d="M12 3.2l7 2.8v5.4c0 4.6-3 7.9-7 9.4-4-1.5-7-4.8-7-9.4V6l7-2.8z" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/>',
  rocket:
    '<path d="M14.5 4.5c2.5-.5 4.5 0 5 0.5s1 2.5.5 5c-.7 3.3-3.5 6.1-6.8 6.8l-3.7-3.7c.7-3.3 3.5-6.1 6.8-6.8z" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/><path d="M9.5 13.5L6 15l1.5 3.5L11 17M5.5 18.5l2-2" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
  bulb: '<path d="M9 17.5h6M10 20.5h4M8.5 14.2C7 13 6.2 11.2 6.5 9.1 6.9 6.2 9.3 4 12.2 4c3.2 0 5.6 2.6 5.3 5.8-.2 1.8-1 3.3-2.3 4.4-.5.5-.7 1.1-.7 1.8h-5c0-.7-.2-1.3-.7-1.8z" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>',
  warning:
    '<path d="M12 4l8.8 15.5H3.2L12 4z" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/><path d="M12 10v4.2M12 17.2h.01" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
  code: '<path d="M8.5 8.5L4.5 12l4 3.5M15.5 8.5l4 3.5-4 3.5M13.2 6.5l-2.4 11" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>',
  database:
    '<ellipse cx="12" cy="6.2" rx="7" ry="2.7" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M5 6.2v11.6c0 1.5 3.1 2.7 7 2.7s7-1.2 7-2.7V6.2M5 12c0 1.5 3.1 2.7 7 2.7s7-1.2 7-2.7" fill="none" stroke="currentColor" stroke-width="1.9"/>',
  cloud:
    '<path d="M7.2 18.5h10.1a3.7 3.7 0 0 0 .5-7.4A5.5 5.5 0 0 0 7.1 9.6a4.4 4.4 0 0 0 .1 8.9z" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"/>',
  flag: '<path d="M5.5 20.5V4.5m0 0h11.5l-2.2 4.2 2.2 4.3H5.5" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>',
  search:
    '<circle cx="11" cy="11" r="6.2" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M15.6 15.6L20 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
  lock: '<rect x="5.5" y="10.5" width="13" height="9.5" rx="2" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M8.5 10.5V7.8a3.5 3.5 0 0 1 7 0v2.7" fill="none" stroke="currentColor" stroke-width="1.9"/>',
  globe:
    '<circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="1.9"/><path d="M3.8 12h16.4M12 3.5c2.4 2.3 3.7 5.3 3.7 8.5S14.4 18.2 12 20.5C9.6 18.2 8.3 15.2 8.3 12S9.6 5.8 12 3.5z" fill="none" stroke="currentColor" stroke-width="1.7"/>',
  target:
    '<circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="1.9"/><circle cx="12" cy="12" r="4.5" fill="none" stroke="currentColor" stroke-width="1.9"/><circle cx="12" cy="12" r="1.4" fill="currentColor"/>'
}

const DEFAULT_BADGE_ICON_PATH =
  '<rect x="4.5" y="4.5" width="15" height="15" rx="4" fill="none" stroke="currentColor" stroke-width="1.9"/><circle cx="12" cy="12" r="3" fill="currentColor"/>'

function matchIconKeyword(rawName: string): string {
  const cleaned = rawName
    .trim()
    .toLowerCase()
    .replace(/^ref:(?:search|custom|icon|svg):/, '')
  for (const [keyword, pathMarkup] of Object.entries(SEMANTIC_ICON_PATHS)) {
    if (cleaned === keyword || cleaned.includes(keyword)) {
      return pathMarkup
    }
  }
  if (cleaned.includes('success') || cleaned.includes('done') || cleaned.includes('tick')) {
    return SEMANTIC_ICON_PATHS.check!
  }
  if (cleaned.includes('time') || cleaned.includes('schedule') || cleaned.includes('history')) {
    return SEMANTIC_ICON_PATHS.clock!
  }
  if (cleaned.includes('person') || cleaned.includes('team') || cleaned.includes('member')) {
    return SEMANTIC_ICON_PATHS.user!
  }
  if (cleaned.includes('trend') || cleaned.includes('bar') || cleaned.includes('metric') || cleaned.includes('stat')) {
    return SEMANTIC_ICON_PATHS.chart!
  }
  if (cleaned.includes('alert') || cleaned.includes('error') || cleaned.includes('risk')) {
    return SEMANTIC_ICON_PATHS.warning!
  }
  if (cleaned.includes('security') || cleaned.includes('safe') || cleaned.includes('guard')) {
    return SEMANTIC_ICON_PATHS.shield!
  }
  if (cleaned.includes('idea') || cleaned.includes('light') || cleaned.includes('tip')) {
    return SEMANTIC_ICON_PATHS.bulb!
  }
  if (cleaned.includes('launch') || cleaned.includes('fast') || cleaned.includes('boost')) {
    return SEMANTIC_ICON_PATHS.rocket!
  }
  return DEFAULT_BADGE_ICON_PATH
}

/**
 * Produces a deterministic, offline-safe `<symbol viewBox="0 0 24 24">` markup string for any
 * icon keyword without contacting `api.iconify.design` or external icon search endpoints.
 */
export function buildOfflineIconSymbolSvg(iconName: string): string {
  const inner = matchIconKeyword(iconName || 'badge')
  return `<symbol xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">${inner}</symbol>`
}

/**
 * Offline resource loader registered with `@antv/infographic` at module load so every icon
 * lookup resolves synchronously from local SVG geometry with zero network requests.
 */
export async function offlineInfographicResourceLoader(config: {
  source?: string
  data: string
  format?: string
  encoding?: string
}): Promise<SVGSymbolElement> {
  const symbolSvg = buildOfflineIconSymbolSvg(config?.data ?? 'badge')
  if (typeof DOMParser !== 'undefined') {
    const parsed = loadSVGResource(symbolSvg)
    if (parsed) return parsed
  }
  if (typeof document !== 'undefined' && typeof document.createElementNS === 'function') {
    const symbolEl = document.createElementNS('http://www.w3.org/2000/svg', 'symbol')
    symbolEl.setAttribute('viewBox', '0 0 24 24')
    symbolEl.innerHTML = matchIconKeyword(config?.data ?? 'badge')
    return symbolEl
  }
  const attrs = new Map<string, string>([
    ['xmlns', 'http://www.w3.org/2000/svg'],
    ['viewBox', '0 0 24 24']
  ])
  return {
    id: '',
    tagName: 'symbol',
    nodeName: 'symbol',
    namespaceURI: 'http://www.w3.org/2000/svg',
    outerHTML: symbolSvg,
    innerHTML: matchIconKeyword(config?.data ?? 'badge'),
    getAttribute: (name: string) => attrs.get(name) ?? null,
    setAttribute: (name: string, val: string) => {
      attrs.set(name, String(val))
    },
    hasAttribute: (name: string) => attrs.has(name),
    cloneNode: () => offlineInfographicResourceLoader(config)
  } as unknown as SVGSymbolElement
}

let resourceLoaderRegistered = false
function ensureOfflineResourceLoader(): void {
  if (resourceLoaderRegistered) return
  resourceLoaderRegistered = true
  registerResourceLoader(offlineInfographicResourceLoader)
}
ensureOfflineResourceLoader()

/**
 * Strips explicit `ref:search:` or `ref:remote:` / `ref:url:` directives from Infographic DSL
 * so `@antv/infographic`'s built-in resource router always delegates to the offline local
 * `<symbol>` loader instead of issuing remote HTTP requests.
 */
export function sanitizeInfographicSource(source: string): string {
  return source.replace(/\bref:search:(?:[a-z]+:)?([^\s]+)/gi, '$1').replace(/\bref:(?:remote|url):[^\s]+/gi, 'shield')
}

export type InfographicSyntaxValidationResult = { ok: true } | { ok: false; errors: string[] }

/**
 * Validates `@antv/infographic` DSL syntax prior to mounting. Rejects empty inputs, syntax/schema
 * errors, unknown template names, and incomplete blocks missing `template`/`design` or `data`.
 */
export function validateInfographicSyntax(source: string): InfographicSyntaxValidationResult {
  if (!source || !source.trim()) {
    return { ok: false, errors: ['Infographic syntax source is empty.'] }
  }

  const { options, errors } = parseSyntax(source)
  if (errors.length > 0) {
    return {
      ok: false,
      errors: errors.map(err => `Line ${err.line} (${err.path}): ${err.message}`)
    }
  }

  const hasTemplateOrDesign = Boolean(options.template || options.design)
  if (!hasTemplateOrDesign) {
    return {
      ok: false,
      errors: ['Infographic syntax must declare a template or design block.']
    }
  }

  if (options.template && !getTemplate(options.template)) {
    return {
      ok: false,
      errors: [`Unknown infographic template "${options.template}".`]
    }
  }

  const data = options.data as Record<string, unknown> | undefined
  if (!data || typeof data !== 'object') {
    return {
      ok: false,
      errors: ['Infographic syntax must include a non-empty data block.']
    }
  }

  const hasAnyItems = Object.values(data).some(
    val => (Array.isArray(val) && val.length > 0) || (typeof val === 'string' && val.trim().length > 0)
  )
  if (!hasAnyItems) {
    return {
      ok: false,
      errors: ['Infographic data block does not contain any items or text fields.']
    }
  }

  return { ok: true }
}

export interface InfographicMountOptions {
  theme?: VizThemeMode
  zoom?: boolean | 'auto'
  marketConvention?: MarketConvention
  tokenOverrides?: Partial<Record<string, string>>
  width?: number | string
  height?: number | string
}

export interface MountedInfographic {
  exportSVG: () => Promise<{ svg: string; isPrintSafe: boolean }>
  exportPNG: (options?: { dpr?: number }) => Promise<string>
  destroy: () => void
}

function bindSvgWheelZoom(svg: SVGSVGElement, mode: boolean | 'auto'): () => void {
  if (mode === false) return () => {}
  const vbAttr = svg.getAttribute('viewBox')
  if (!vbAttr) return () => {}
  const parts = vbAttr
    .trim()
    .split(/[\s,]+/)
    .map(Number)
  if (parts.length !== 4 || parts.some(n => !Number.isFinite(n))) return () => {}

  if (mode === 'auto') {
    const hostRect = svg.parentElement?.getBoundingClientRect()
    const vbWidth = parts[2]!
    const vbHeight = parts[3]!
    if (hostRect && hostRect.width > 0 && vbWidth <= hostRect.width * 1.15 && vbHeight <= 900) {
      return () => {}
    }
  }

  let [vx, vy, vw, vh] = parts as [number, number, number, number]
  const baseW = vw
  const baseH = vh

  const onWheel = (event: WheelEvent) => {
    if (!event.ctrlKey && !event.metaKey) return
    event.preventDefault()
    const factor = event.deltaY > 0 ? 1.12 : 0.89
    const nextW = Math.min(baseW * 3, Math.max(baseW * 0.3, vw * factor))
    const nextH = Math.min(baseH * 3, Math.max(baseH * 0.3, vh * factor))
    vx += (vw - nextW) / 2
    vy += (vh - nextH) / 2
    vw = nextW
    vh = nextH
    svg.setAttribute('viewBox', `${vx} ${vy} ${vw} ${vh}`)
  }

  svg.addEventListener('wheel', onWheel, { passive: false })
  return () => svg.removeEventListener('wheel', onWheel)
}

/**
 * Mounts an `@antv/infographic` diagram inside `host` using Ankole's offline icon registry,
 * theme palette, and Print-Safe SVG / high-DPI PNG export contracts.
 */
export async function mountInfographicAsync(
  host: HTMLElement,
  source: string,
  options?: InfographicMountOptions
): Promise<MountedInfographic> {
  ensureOfflineResourceLoader()

  const validation = validateInfographicSyntax(source)
  if (!validation.ok) {
    throw new Error(validation.errors.join('; '))
  }

  const sanitizedSource = sanitizeInfographicSource(source)
  const { options: parsedDsl } = parseSyntax(sanitizedSource)

  const palette = resolveVizTheme(host, {
    theme: options?.theme,
    marketConvention: options?.marketConvention,
    tokenOverrides: options?.tokenOverrides
  })

  const mergedOptions: Partial<InfographicOptions> = {
    ...parsedDsl,
    container: host,
    editable: false,
    ...(options?.width !== undefined ? { width: options.width } : {}),
    ...(options?.height !== undefined ? { height: options.height } : {}),
    theme: palette.isDark ? 'dark' : (parsedDsl.theme ?? 'light'),
    themeConfig: {
      ...parsedDsl.themeConfig,
      colorBg: palette.background,
      colorPrimary: palette.categorical[0],
      palette: [...palette.categorical, ...palette.extendedCategorical],
      base: {
        ...parsedDsl.themeConfig?.base,
        text: {
          ...parsedDsl.themeConfig?.base?.text,
          'font-family': palette.fontSans,
          fill: palette.foreground
        }
      }
    }
  }

  const instance = new Infographic(mergedOptions)

  await new Promise<void>((resolve, reject) => {
    let settled = false
    const onLoaded = () => {
      if (settled) return
      settled = true
      cleanup()
      resolve()
    }
    const onError = (err: unknown) => {
      if (settled) return
      settled = true
      cleanup()
      reject(err instanceof Error ? err : new Error(String(err)))
    }
    const cleanup = () => {
      instance.off('loaded', onLoaded)
      instance.off('error', onError)
    }
    instance.on('loaded', onLoaded)
    instance.on('error', onError)
    instance.render()
  })

  const svgNode = host.querySelector('svg')
  const unbindZoom = svgNode ? bindSvgWheelZoom(svgNode, options?.zoom ?? 'auto') : () => {}
  let destroyed = false

  return {
    async exportSVG() {
      if (destroyed) throw new Error('Infographic instance has been destroyed.')
      const liveSvg = host.querySelector('svg')
      if (!liveSvg) {
        throw new Error('Infographic SVG element is not mounted.')
      }
      const exportedNode = await exportToSVG(liveSvg, { embedResources: false })
      const rawSvg = new XMLSerializer().serializeToString(exportedNode)
      const sanitized = sanitizeExportedSvg(rawSvg, palette, { safetyPaddingPx: 8 })
      return {
        svg: sanitized,
        isPrintSafe: isPrintSafeSvg(sanitized)
      }
    },
    async exportPNG(exportOptions) {
      if (destroyed) throw new Error('Infographic instance has been destroyed.')
      return instance.toDataURL({
        type: 'png',
        dpr: exportOptions?.dpr ?? 2
      })
    },
    destroy() {
      if (destroyed) return
      destroyed = true
      unbindZoom()
      instance.destroy()
    }
  }
}
