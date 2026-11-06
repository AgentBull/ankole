export type MarketConvention = 'intl' | 'cn'

export type VizThemeMode = 'auto' | 'light' | 'dark'

export interface ResolveVizThemeOptions {
  theme?: VizThemeMode
  marketConvention?: MarketConvention
  tokenOverrides?: Partial<Record<string, string>>
}

export interface VizThemePalette {
  isDark: boolean
  marketConvention: MarketConvention
  background: string
  layer01: string
  layer02: string
  foreground: string
  fgSecondary: string
  fgTertiary: string
  border: string
  borderStrong: string
  fontSans: string
  fontMono: string
  categorical: readonly [string, string, string, string, string]
  extendedCategorical: readonly string[]
  otherColor: string
  emptyColor: string
  up: string
  upForeground: string
  upSubtle: string
  down: string
  downForeground: string
  downSubtle: string
}

export interface SeriesColorDescriptor {
  key: string
  isOther?: boolean
  isEmpty?: boolean
  optionColor?: string | null
}

const DEFAULT_FONT_SANS = "'IBMPlexSansCN', 'Helvetica Neue', Arial, sans-serif"
const DEFAULT_FONT_MONO = "'IBMPlexMonoCN', 'SFMono-Regular', Consolas, 'Liberation Mono', monospace"

const LIGHT_FALLBACKS = {
  background: '#fffefd',
  layer01: '#f4f4f2',
  layer02: '#fffefd',
  foreground: '#18191a',
  fgSecondary: '#47494a',
  fgTertiary: '#636566',
  border: '#e5e4e1',
  borderStrong: '#87898a',
  chart1: '#b31b5d',
  chart2: '#009d9a',
  chart3: '#0f62fe',
  chart4: '#f1c21b',
  chart5: '#a56eff',
  extendedCategorical: ['#e26300', '#0077c8', '#1a8a3c', '#c9256f', '#0140cc', '#006162', '#6524b8'] as const,
  otherColor: '#87898a',
  emptyColor: '#cbcac7',
  up: '#0f8a5f',
  upForeground: '#086646',
  upSubtle: '#e6f6ef',
  down: '#c81e3a',
  downForeground: '#9e142c',
  downSubtle: '#fdecef'
} as const

const DARK_FALLBACKS = {
  background: '#18191a',
  layer01: '#232526',
  layer02: '#343637',
  foreground: '#f4f4f2',
  fgSecondary: '#cbcac7',
  fgTertiary: '#abaaa7',
  border: '#343637',
  borderStrong: '#87898a',
  chart1: '#d83d82',
  chart2: '#08bdba',
  chart3: '#78a9ff',
  chart4: '#f1c21b',
  chart5: '#be95ff',
  extendedCategorical: ['#ff8233', '#45b3ff', '#43c76b', '#ff72ad', '#4a88ff', '#44e2df', '#b791ff'] as const,
  otherColor: '#87898a',
  emptyColor: '#47494a',
  up: '#2ec28b',
  upForeground: '#5cdba9',
  upSubtle: '#193028',
  down: '#f2556a',
  downForeground: '#ff8594',
  downSubtle: '#381e24'
} as const

const OPTION_RAMP_LIGHT: Record<string, string> = {
  brand: '#e10059',
  pink: '#e10059',
  rose: '#e10059',
  blue: '#1561ff',
  teal: '#008583',
  purple: '#8838f2',
  violet: '#8838f2',
  green: '#1a8a3c',
  emerald: '#1a8a3c',
  orange: '#b94f00',
  cyan: '#0077c8',
  magenta: '#c9256f',
  yellow: '#916d00',
  amber: '#916d00',
  red: '#d1270e',
  gray: '#636566',
  grey: '#636566',
  neutral: '#636566',
  slate: '#636566'
}

const OPTION_RAMP_DARK: Record<string, string> = {
  brand: '#ff4669',
  pink: '#ff4669',
  rose: '#ff4669',
  blue: '#4a88ff',
  teal: '#00a3a0',
  purple: '#a066ff',
  violet: '#a066ff',
  green: '#24a94f',
  emerald: '#24a94f',
  orange: '#e26300',
  cyan: '#1294eb',
  magenta: '#ea468d',
  yellow: '#f3c11c',
  amber: '#f3c11c',
  red: '#f14d32',
  gray: '#87898a',
  grey: '#87898a',
  neutral: '#87898a',
  slate: '#87898a'
}

const STATIC_COLOR_TOKENS: Record<string, string> = {
  '--color-white': '#ffffff',
  '--color-black': '#000000',
  '--color-paper': '#fffefd',
  '--color-gray-10': '#f4f4f2',
  '--color-gray-20': '#e5e4e1',
  '--color-gray-30': '#cbcac7',
  '--color-gray-40': '#abaaa7',
  '--color-gray-50': '#87898a',
  '--color-gray-60': '#636566',
  '--color-gray-70': '#47494a',
  '--color-gray-80': '#343637',
  '--color-gray-90': '#232526',
  '--color-gray-100': '#18191a',
  '--color-brand-50': '#ff4669',
  '--color-brand-60': '#e10059',
  '--color-blue-50': '#4a88ff',
  '--color-blue-60': '#1561ff',
  '--color-teal-50': '#00a3a0',
  '--color-teal-60': '#008583',
  '--color-purple-50': '#a066ff',
  '--color-purple-60': '#8838f2',
  '--color-green-50': '#24a94f',
  '--color-green-60': '#1a8a3c',
  '--color-orange-50': '#e26300',
  '--color-orange-60': '#b94f00',
  '--color-cyan-50': '#1294eb',
  '--color-cyan-60': '#0077c8',
  '--color-magenta-50': '#ea468d',
  '--color-magenta-60': '#c9256f',
  '--color-yellow-30': '#f3c11c',
  '--color-yellow-50': '#b28700',
  '--color-yellow-60': '#916d00',
  '--color-red-50': '#f14d32',
  '--color-red-60': '#d1270e'
}

function detectDomDark(target: Element | null): boolean {
  if (!target) return false
  const themedAncestor = typeof target.closest === 'function' ? target.closest('[data-theme]') : null
  const themeAttr =
    themedAncestor?.getAttribute('data-theme') ??
    target.getAttribute('data-theme') ??
    (typeof document !== 'undefined' ? document.documentElement?.getAttribute('data-theme') : null)
  return themeAttr === 'dark'
}

function resolveVarTokenValue(raw: string, fallback: string): string {
  const trimmed = raw.trim()
  if (!trimmed) return fallback
  const varMatch = /^var\(\s*(--[a-zA-Z0-9-_]+)(?:\s*,\s*([^)]+))?\s*\)$/.exec(trimmed)
  if (varMatch) {
    const refName = varMatch[1]!
    const refFallback = varMatch[2]?.trim()
    return STATIC_COLOR_TOKENS[refName] ?? refFallback ?? fallback
  }
  if (trimmed.includes('var(--')) return fallback
  return trimmed
}

function pickToken(
  tokenName: `--${string}`,
  styles: CSSStyleDeclaration | null,
  overrides: Partial<Record<string, string>> | undefined,
  fallback: string
): string {
  if (overrides) {
    const bareName = tokenName.slice(2)
    const camelName = bareName.replace(/-([a-z0-9])/g, (_, ch: string) => ch.toUpperCase())
    const overrideValue = overrides[tokenName] ?? overrides[bareName] ?? overrides[camelName]
    if (overrideValue && overrideValue.trim()) {
      return resolveVarTokenValue(overrideValue, fallback)
    }
  }
  const computed = styles?.getPropertyValue(tokenName)?.trim()
  if (computed) {
    return resolveVarTokenValue(computed, fallback)
  }
  return fallback
}

/**
 * Resolves Ankole visualization tokens from DOM computed styles or deterministic
 * light/dark fallback tables, decoupling directional market colors (`intl` vs `cn`)
 * from UI status tokens.
 */
export function resolveVizTheme(root?: Element | null, options?: ResolveVizThemeOptions): VizThemePalette {
  const mode = options?.theme ?? 'auto'
  const marketConvention: MarketConvention = options?.marketConvention ?? 'intl'
  const target = root === undefined ? (typeof document !== 'undefined' ? document.documentElement : null) : root
  const domIsDark = detectDomDark(target)
  const isDark = mode === 'dark' ? true : mode === 'light' ? false : domIsDark

  const canUseComputedStyles =
    Boolean(target) &&
    typeof window !== 'undefined' &&
    typeof window.getComputedStyle === 'function' &&
    (mode === 'auto' || domIsDark === isDark)
  const styles = canUseComputedStyles && target ? window.getComputedStyle(target) : null

  const defaults = isDark ? DARK_FALLBACKS : LIGHT_FALLBACKS
  const overrides = options?.tokenOverrides

  const baseUp = pickToken('--chart-up', styles, overrides, defaults.up)
  const baseUpForeground = pickToken('--chart-up-foreground', styles, overrides, defaults.upForeground)
  const baseUpSubtle = pickToken('--chart-up-subtle', styles, overrides, defaults.upSubtle)
  const baseDown = pickToken('--chart-down', styles, overrides, defaults.down)
  const baseDownForeground = pickToken('--chart-down-foreground', styles, overrides, defaults.downForeground)
  const baseDownSubtle = pickToken('--chart-down-subtle', styles, overrides, defaults.downSubtle)

  const swapDirectional = marketConvention === 'cn'

  const chart1 = pickToken('--chart-1', styles, overrides, defaults.chart1)
  const chart2 = pickToken('--chart-2', styles, overrides, defaults.chart2)
  const chart3 = pickToken('--chart-3', styles, overrides, defaults.chart3)
  const chart4 = pickToken('--chart-4', styles, overrides, defaults.chart4)
  const chart5 = pickToken('--chart-5', styles, overrides, defaults.chart5)

  return {
    isDark,
    marketConvention,
    background: pickToken('--background', styles, overrides, defaults.background),
    layer01: pickToken('--layer-01', styles, overrides, defaults.layer01),
    layer02: pickToken('--layer-02', styles, overrides, defaults.layer02),
    foreground: pickToken('--foreground', styles, overrides, defaults.foreground),
    fgSecondary: pickToken('--fg-secondary', styles, overrides, defaults.fgSecondary),
    fgTertiary: pickToken('--fg-tertiary', styles, overrides, defaults.fgTertiary),
    border: pickToken('--border', styles, overrides, defaults.border),
    borderStrong: pickToken('--border-strong', styles, overrides, defaults.borderStrong),
    fontSans: pickToken('--font-family-sans', styles, overrides, DEFAULT_FONT_SANS),
    fontMono: pickToken('--font-family-mono', styles, overrides, DEFAULT_FONT_MONO),
    categorical: [chart1, chart2, chart3, chart4, chart5],
    extendedCategorical: [...defaults.extendedCategorical],
    otherColor: pickToken('--chart-other', styles, overrides, defaults.otherColor),
    emptyColor: pickToken('--chart-empty', styles, overrides, defaults.emptyColor),
    up: swapDirectional ? baseDown : baseUp,
    upForeground: swapDirectional ? baseDownForeground : baseUpForeground,
    upSubtle: swapDirectional ? baseDownSubtle : baseUpSubtle,
    down: swapDirectional ? baseUp : baseDown,
    downForeground: swapDirectional ? baseUpForeground : baseDownForeground,
    downSubtle: swapDirectional ? baseUpSubtle : baseDownSubtle
  }
}

/**
 * Maps Ankole select-option ramp names (`brand`, `blue`, `teal`, `purple`, `green`,
 * `orange`, `cyan`, `magenta`, `yellow`, `red`, `gray`) or explicit hex colors to
 * concrete fill colors for the active theme.
 */
export function resolveSelectOptionColor(colorName: string | undefined | null, isDark: boolean): string | undefined {
  if (!colorName) return undefined
  const normalized = colorName.trim().toLowerCase()
  if (!normalized) return undefined
  if (/^#(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/.test(normalized)) {
    if (normalized.length === 4) {
      const r = normalized[1]!
      const g = normalized[2]!
      const b = normalized[3]!
      return `#${r}${r}${g}${g}${b}${b}`
    }
    return normalized
  }
  const table = isDark ? OPTION_RAMP_DARK : OPTION_RAMP_LIGHT
  return table[normalized]
}

/**
 * Assigns deterministic colors to chart series in rank order (`0, 1, 2, ...`):
 * - `isEmpty` -> `palette.emptyColor`
 * - `isOther` -> `palette.otherColor`
 * - `optionColor` -> resolved Base select option color
 * - Otherwise -> `palette.categorical` followed by `palette.extendedCategorical` in rank order
 *   (never hashing category strings, and never colliding with neutral gray).
 */
export function assignSeriesColors(
  seriesKeys: readonly SeriesColorDescriptor[],
  palette: VizThemePalette
): Map<string, string> {
  const result = new Map<string, string>()
  const rankPool = [...palette.categorical, ...palette.extendedCategorical]
  let rankIndex = 0

  for (const descriptor of seriesKeys) {
    if (result.has(descriptor.key)) continue
    if (descriptor.isEmpty) {
      result.set(descriptor.key, palette.emptyColor)
      continue
    }
    if (descriptor.isOther) {
      result.set(descriptor.key, palette.otherColor)
      continue
    }
    const explicit = resolveSelectOptionColor(descriptor.optionColor, palette.isDark)
    if (explicit) {
      result.set(descriptor.key, explicit)
      continue
    }
    const slotColor = rankPool[rankIndex % rankPool.length]!
    rankIndex += 1
    result.set(descriptor.key, slotColor)
  }

  return result
}

const EXTERNAL_SVG_URL_PATTERNS: readonly RegExp[] = [
  /\b(?:xlink:)?href\s*=\s*['"]\s*https?:\/\//i,
  /\bsrc\s*=\s*['"]\s*https?:\/\//i,
  /url\(\s*['"]?\s*https?:\/\//i,
  /@import\s+(?:url\(\s*)?['"]?\s*https?:\/\//i,
  /<\?xml-stylesheet\b[^>]*\bhref\s*=\s*['"]\s*https?:\/\//i
]

/**
 * Verifies whether an SVG string is self-contained and safe for offline vector PDF/print
 * pipelines: rejects `<foreignObject>`, unresolved `var(--...)`, and external `http(s)://`
 * resource references while permitting standard XML namespace declarations.
 */
export function isPrintSafeSvg(svg: string): boolean {
  const trimmed = svg.trim()
  if (!trimmed || !/<svg[\s>]/i.test(trimmed)) return false
  if (/<\s*foreignobject\b/i.test(trimmed)) return false
  if (/var\(\s*--/i.test(trimmed)) return false
  for (const pattern of EXTERNAL_SVG_URL_PATTERNS) {
    if (pattern.test(trimmed)) return false
  }
  return true
}

function buildPaletteTokenLookup(palette: VizThemePalette): Record<string, string> {
  return {
    ...STATIC_COLOR_TOKENS,
    '--background': palette.background,
    '--color-background': palette.background,
    '--layer-01': palette.layer01,
    '--color-layer-01': palette.layer01,
    '--layer-02': palette.layer02,
    '--color-layer-02': palette.layer02,
    '--foreground': palette.foreground,
    '--color-foreground': palette.foreground,
    '--text-primary': palette.foreground,
    '--fg-primary': palette.foreground,
    '--color-fg-primary': palette.foreground,
    '--fg-secondary': palette.fgSecondary,
    '--color-fg-secondary': palette.fgSecondary,
    '--text-secondary': palette.fgSecondary,
    '--muted-foreground': palette.fgSecondary,
    '--fg-tertiary': palette.fgTertiary,
    '--color-fg-tertiary': palette.fgTertiary,
    '--border': palette.border,
    '--color-border': palette.border,
    '--border-subtle': palette.border,
    '--border-strong': palette.borderStrong,
    '--font-family-sans': palette.fontSans,
    '--font-sans': palette.fontSans,
    '--font-family-mono': palette.fontMono,
    '--font-mono': palette.fontMono,
    '--chart-1': palette.categorical[0],
    '--color-chart-1': palette.categorical[0],
    '--chart-2': palette.categorical[1],
    '--color-chart-2': palette.categorical[1],
    '--chart-3': palette.categorical[2],
    '--color-chart-3': palette.categorical[2],
    '--chart-4': palette.categorical[3],
    '--color-chart-4': palette.categorical[3],
    '--chart-5': palette.categorical[4],
    '--color-chart-5': palette.categorical[4],
    '--chart-other': palette.otherColor,
    '--color-chart-other': palette.otherColor,
    '--chart-empty': palette.emptyColor,
    '--color-chart-empty': palette.emptyColor,
    '--chart-up': palette.up,
    '--color-chart-up': palette.up,
    '--chart-up-foreground': palette.upForeground,
    '--color-chart-up-foreground': palette.upForeground,
    '--chart-up-subtle': palette.upSubtle,
    '--color-chart-up-subtle': palette.upSubtle,
    '--chart-down': palette.down,
    '--color-chart-down': palette.down,
    '--chart-down-foreground': palette.downForeground,
    '--color-chart-down-foreground': palette.downForeground,
    '--chart-down-subtle': palette.downSubtle,
    '--color-chart-down-subtle': palette.downSubtle
  }
}

export interface SanitizeExportedSvgOptions {
  safetyPaddingPx?: number
}

/**
 * Resolves known `var(--...)` CSS custom properties to concrete palette values, ensures
 * root `xmlns="http://www.w3.org/2000/svg"`, and optionally expands `viewBox` by
 * `safetyPaddingPx` so wide CJK glyphs and axis labels never clip during export.
 */
export function sanitizeExportedSvg(
  svg: string,
  palette: VizThemePalette,
  options?: SanitizeExportedSvgOptions
): string {
  if (!svg.trim()) return svg
  const tokenMap = buildPaletteTokenLookup(palette)

  let output = svg.replace(/var\(\s*(--[a-zA-Z0-9-_]+)(?:\s*,\s*([^)]+))?\s*\)/g, (full, name: string, fb?: string) => {
    const direct = tokenMap[name]
    if (direct) return direct
    if (fb && !fb.includes('var(--')) return fb.trim()
    return full
  })

  output = output.replace(/<svg\b([^>]*)>/i, (openTag, attrs: string) => {
    let nextAttrs = attrs
    if (!/\bxmlns\s*=/.test(nextAttrs)) {
      nextAttrs = ` xmlns="http://www.w3.org/2000/svg"${nextAttrs}`
    }

    const pad = options?.safetyPaddingPx ?? 0
    if (pad > 0) {
      const viewBoxMatch = /\bviewBox\s*=\s*(['"])\s*([-+\d.]+)\s+([-+\d.]+)\s+([-+\d.]+)\s+([-+\d.]+)\s*\1/i.exec(
        nextAttrs
      )
      if (viewBoxMatch) {
        const quote = viewBoxMatch[1]!
        const x = Number.parseFloat(viewBoxMatch[2]!)
        const y = Number.parseFloat(viewBoxMatch[3]!)
        const w = Number.parseFloat(viewBoxMatch[4]!)
        const h = Number.parseFloat(viewBoxMatch[5]!)
        if (Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(w) && Number.isFinite(h)) {
          const expanded = `${x - pad} ${y - pad} ${w + pad * 2} ${h + pad * 2}`
          nextAttrs = nextAttrs.replace(viewBoxMatch[0], `viewBox=${quote}${expanded}${quote}`)
        }
      } else {
        const widthMatch = /\bwidth\s*=\s*(['"])([-+\d.]+)(?:px)?\1/i.exec(nextAttrs)
        const heightMatch = /\bheight\s*=\s*(['"])([-+\d.]+)(?:px)?\1/i.exec(nextAttrs)
        if (widthMatch && heightMatch) {
          const w = Number.parseFloat(widthMatch[2]!)
          const h = Number.parseFloat(heightMatch[2]!)
          if (Number.isFinite(w) && w > 0 && Number.isFinite(h) && h > 0) {
            nextAttrs = `${nextAttrs} viewBox="${-pad} ${-pad} ${w + pad * 2} ${h + pad * 2}"`
          }
        }
      }
    }

    return `<svg${nextAttrs}>`
  })

  return output
}
