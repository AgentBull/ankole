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
  categoricalStrokes: readonly [string, string, string, string, string]
  extendedCategorical: readonly string[]
  extendedCategoricalStrokes: readonly string[]
  otherColor: string
  emptyColor: string
  totalColor: string
  sequential: readonly string[]
  diverging: readonly string[]
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

export interface AssignSeriesColorsOptions {
  variant?: 'fill' | 'stroke'
}

const DEFAULT_FONT_SANS = "'IBMPlexSansCN', 'Helvetica Neue', Arial, sans-serif"
const DEFAULT_FONT_MONO = "'IBMPlexMonoCN', 'SFMono-Regular', Consolas, 'Liberation Mono', monospace"

const LIGHT_FALLBACKS = {
  background: '#ffffff',
  layer01: '#f8f8f8',
  layer02: '#ffffff',
  foreground: '#424242',
  fgSecondary: '#5e5e5e',
  fgTertiary: '#929292',
  border: '#d3d3d3',
  borderStrong: '#929292',
  chart1: '#2864b9',
  chart2: '#049383',
  chart3: '#be8100',
  chart4: '#b3395a',
  chart5: '#a665b0',
  chart1Stroke: '#0c58b4',
  chart2Stroke: '#008475',
  chart3Stroke: '#ad7300',
  chart4Stroke: '#a8234c',
  chart5Stroke: '#9852a4',
  extendedCategorical: ['#be582c', '#3b8549', '#0084a4', '#7d5dc0', '#8f8824'] as const,
  extendedCategoricalStrokes: ['#b44514', '#1d7b33', '#007795', '#6f49ba', '#7e7710'] as const,
  otherColor: '#949698',
  emptyColor: '#d4d3d0',
  totalColor: '#3f5368',
  sequential: ['#dcf3ff', '#b6daf2', '#90bee1', '#699ecd', '#467db9', '#275da5', '#0b378d'] as const,
  divergingIntl: ['#9d1f40', '#c36573', '#e1aeb3', '#f4f4f2', '#98cbb6', '#2f9b79', '#00684e'] as const,
  up: '#19875c',
  upForeground: '#0d6946',
  upSubtle: '#e6f5ee',
  down: '#c1384b',
  downForeground: '#992235',
  downSubtle: '#fbecee'
} as const

const DARK_FALLBACKS = {
  background: '#0b0b0b',
  layer01: '#000000',
  layer02: '#0b0b0b',
  foreground: '#ffffff',
  fgSecondary: '#f8f8f8',
  fgTertiary: '#d3d3d3',
  border: '#1c1c1e',
  borderStrong: '#929292',
  chart1: '#5d98e7',
  chart2: '#51c6b5',
  chart3: '#ecb457',
  chart4: '#db6b83',
  chart5: '#d497de',
  chart1Stroke: '#6aa6f8',
  chart2Stroke: '#3dd3c0',
  chart3Stroke: '#f9bc50',
  chart4Stroke: '#eb718c',
  chart5Stroke: '#dfa2ea',
  extendedCategorical: ['#eb8b61', '#70b87b', '#4bb9db', '#b69bef', '#bab65c'] as const,
  extendedCategoricalStrokes: ['#f99063', '#75c682', '#3cc6ec', '#c1a6fc', '#c7c364'] as const,
  otherColor: '#6e7173',
  emptyColor: '#434648',
  totalColor: '#7d94ad',
  sequential: ['#1e2735', '#2c3e56', '#3b5b7c', '#4879a3', '#529aca', '#5abdf2', '#9fe0ff'] as const,
  divergingIntl: ['#fc8999', '#bc5f6d', '#6e3c43', '#232526', '#1d5946', '#269573', '#48cba1'] as const,
  up: '#43c291',
  upForeground: '#6edab0',
  upSubtle: '#193027',
  down: '#eb6b7d',
  downForeground: '#ff94a2',
  downSubtle: '#361e24'
} as const

const OPTION_RAMP_LIGHT: Record<string, string> = {
  brand: '#b3395a',
  pink: '#b3395a',
  rose: '#b3395a',
  blue: '#2864b9',
  teal: '#049383',
  purple: '#7d5dc0',
  violet: '#7d5dc0',
  green: '#3b8549',
  emerald: '#3b8549',
  orange: '#be582c',
  cyan: '#0084a4',
  magenta: '#a665b0',
  yellow: '#be8100',
  amber: '#be8100',
  red: '#c1403e',
  gray: '#6e7173',
  grey: '#6e7173',
  neutral: '#6e7173',
  slate: '#6e7173'
}

const OPTION_RAMP_LIGHT_STROKE: Record<string, string> = {
  brand: '#a8234c',
  pink: '#a8234c',
  rose: '#a8234c',
  blue: '#0c58b4',
  teal: '#008475',
  purple: '#6f49ba',
  violet: '#6f49ba',
  green: '#1d7b33',
  emerald: '#1d7b33',
  orange: '#b44514',
  cyan: '#007795',
  magenta: '#9852a4',
  yellow: '#ad7300',
  amber: '#ad7300',
  red: '#b32b29',
  gray: '#5a5d5f',
  grey: '#5a5d5f',
  neutral: '#5a5d5f',
  slate: '#5a5d5f'
}

const OPTION_RAMP_DARK: Record<string, string> = {
  brand: '#db6b83',
  pink: '#db6b83',
  rose: '#db6b83',
  blue: '#5d98e7',
  teal: '#51c6b5',
  purple: '#b69bef',
  violet: '#b69bef',
  green: '#70b87b',
  emerald: '#70b87b',
  orange: '#eb8b61',
  cyan: '#4bb9db',
  magenta: '#d497de',
  yellow: '#ecb457',
  amber: '#ecb457',
  red: '#e9756e',
  gray: '#8b8e90',
  grey: '#8b8e90',
  neutral: '#8b8e90',
  slate: '#8b8e90'
}

const OPTION_RAMP_DARK_STROKE: Record<string, string> = {
  brand: '#eb718c',
  pink: '#eb718c',
  rose: '#eb718c',
  blue: '#6aa6f8',
  teal: '#3dd3c0',
  purple: '#c1a6fc',
  violet: '#c1a6fc',
  green: '#75c682',
  emerald: '#75c682',
  orange: '#f99063',
  cyan: '#3cc6ec',
  magenta: '#dfa2ea',
  yellow: '#f9bc50',
  amber: '#f9bc50',
  red: '#f77e77',
  gray: '#9ca0a3',
  grey: '#9ca0a3',
  neutral: '#9ca0a3',
  slate: '#9ca0a3'
}

const STATIC_COLOR_TOKENS: Record<string, string> = {
  '--color-white': '#ffffff',
  '--color-black': '#000000',
  '--color-gray-10': '#fbfbfb',
  '--color-gray-20': '#f8f8f8',
  '--color-gray-30': '#f4f4f4',
  '--color-gray-40': '#e0e0e0',
  '--color-gray-50': '#d3d3d3',
  '--color-gray-60': '#b6b6b6',
  '--color-gray-70': '#929292',
  '--color-gray-80': '#5e5e5e',
  '--color-gray-90': '#424242',
  '--color-gray-100': '#1c1c1e',
  '--color-brand-50': '#ff5468',
  '--color-brand-60': '#ff4669',
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

function resolveStrokeVariant(
  fillValue: string,
  defaultFill: string,
  defaultStroke: string,
  strokeTokenName: `--${string}`,
  overrides: Partial<Record<string, string>> | undefined
): string {
  if (overrides) {
    const bareName = strokeTokenName.slice(2)
    const camelName = bareName.replace(/-([a-z0-9])/g, (_, ch: string) => ch.toUpperCase())
    const explicitStroke = overrides[strokeTokenName] ?? overrides[bareName] ?? overrides[camelName]
    if (explicitStroke && explicitStroke.trim()) {
      return resolveVarTokenValue(explicitStroke, defaultStroke)
    }
  }
  return fillValue.toLowerCase() === defaultFill.toLowerCase() ? defaultStroke : fillValue
}

/**
 * Resolves Ankole visualization tokens from DOM computed styles or deterministic
 * light/dark fallback tables, decoupling directional market colors (`intl` vs `cn`)
 * from UI status tokens and providing mark-size-compensated stroke, sequential,
 * and zero-anchored diverging scales.
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

  const chart1Stroke = resolveStrokeVariant(
    chart1,
    defaults.chart1,
    defaults.chart1Stroke,
    '--chart-1-stroke',
    overrides
  )
  const chart2Stroke = resolveStrokeVariant(
    chart2,
    defaults.chart2,
    defaults.chart2Stroke,
    '--chart-2-stroke',
    overrides
  )
  const chart3Stroke = resolveStrokeVariant(
    chart3,
    defaults.chart3,
    defaults.chart3Stroke,
    '--chart-3-stroke',
    overrides
  )
  const chart4Stroke = resolveStrokeVariant(
    chart4,
    defaults.chart4,
    defaults.chart4Stroke,
    '--chart-4-stroke',
    overrides
  )
  const chart5Stroke = resolveStrokeVariant(
    chart5,
    defaults.chart5,
    defaults.chart5Stroke,
    '--chart-5-stroke',
    overrides
  )

  const diverging = swapDirectional ? [...defaults.divergingIntl].reverse() : [...defaults.divergingIntl]

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
    categoricalStrokes: [chart1Stroke, chart2Stroke, chart3Stroke, chart4Stroke, chart5Stroke],
    extendedCategorical: [...defaults.extendedCategorical],
    extendedCategoricalStrokes: [...defaults.extendedCategoricalStrokes],
    otherColor: pickToken('--chart-other', styles, overrides, defaults.otherColor),
    emptyColor: pickToken('--chart-empty', styles, overrides, defaults.emptyColor),
    totalColor: pickToken('--chart-total', styles, overrides, defaults.totalColor),
    sequential: [...defaults.sequential],
    diverging,
    up: swapDirectional ? baseDown : baseUp,
    upForeground: swapDirectional ? baseDownForeground : baseUpForeground,
    upSubtle: swapDirectional ? baseDownSubtle : baseUpSubtle,
    down: swapDirectional ? baseUp : baseDown,
    downForeground: swapDirectional ? baseUpForeground : baseDownForeground,
    downSubtle: swapDirectional ? baseUpSubtle : baseDownSubtle
  }
}

function normalizeExplicitHex(normalized: string): string | undefined {
  if (!/^#(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/.test(normalized)) return undefined
  if (normalized.length === 4) {
    const r = normalized[1]!
    const g = normalized[2]!
    const b = normalized[3]!
    return `#${r}${r}${g}${g}${b}${b}`
  }
  return normalized
}

/**
 * Maps Ankole select-option ramp names (`brand`, `blue`, `teal`, `purple`, `green`,
 * `orange`, `cyan`, `magenta`, `yellow`, `red`, `gray`) or explicit hex colors to
 * concrete area-fill colors for the active theme.
 */
export function resolveSelectOptionColor(colorName: string | undefined | null, isDark: boolean): string | undefined {
  if (!colorName) return undefined
  const normalized = colorName.trim().toLowerCase()
  if (!normalized) return undefined
  const hex = normalizeExplicitHex(normalized)
  if (hex) return hex
  const table = isDark ? OPTION_RAMP_DARK : OPTION_RAMP_LIGHT
  return table[normalized]
}

/**
 * Maps Ankole select-option ramp names or explicit hex colors to mark-size-compensated
 * stroke colors for thin `2px` lines, radar outlines, and scatter borders.
 */
export function resolveSelectOptionStrokeColor(
  colorName: string | undefined | null,
  isDark: boolean
): string | undefined {
  if (!colorName) return undefined
  const normalized = colorName.trim().toLowerCase()
  if (!normalized) return undefined
  const hex = normalizeExplicitHex(normalized)
  if (hex) return hex
  const table = isDark ? OPTION_RAMP_DARK_STROKE : OPTION_RAMP_LIGHT_STROKE
  return table[normalized]
}

function parseRgbChannels(color: string): readonly [number, number, number] | null {
  const trimmed = color.trim().toLowerCase()
  const hex = normalizeExplicitHex(trimmed)
  if (hex) {
    const r = Number.parseInt(hex.slice(1, 3), 16)
    const g = Number.parseInt(hex.slice(3, 5), 16)
    const b = Number.parseInt(hex.slice(5, 7), 16)
    if (Number.isFinite(r) && Number.isFinite(g) && Number.isFinite(b)) {
      return [r, g, b]
    }
  }
  const rgbMatch = /^rgba?\(\s*([\d.]+)\s*[,\s]\s*([\d.]+)\s*[,\s]\s*([\d.]+)/.exec(trimmed)
  if (rgbMatch) {
    const r = Math.min(255, Math.max(0, Number.parseFloat(rgbMatch[1]!)))
    const g = Math.min(255, Math.max(0, Number.parseFloat(rgbMatch[2]!)))
    const b = Math.min(255, Math.max(0, Number.parseFloat(rgbMatch[3]!)))
    if (Number.isFinite(r) && Number.isFinite(g) && Number.isFinite(b)) {
      return [r, g, b]
    }
  }
  return null
}

function srgbChannelToLinear(channel255: number): number {
  const c = channel255 / 255
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
}

const DARK_INK_LUMINANCE =
  0.2126 * srgbChannelToLinear(0x18) + 0.7152 * srgbChannelToLinear(0x19) + 0.0722 * srgbChannelToLinear(0x1a)

/**
 * Computes WCAG 2.1 relative luminance against `#18191a` charcoal ink vs `#ffffff` white
 * and returns whichever foreground maximizes contrast on `fillColor` (deterministic across
 * Canvas, SVG, and offline `resvg` PDF export).
 */
export function pickReadableDataLabelInk(fillColor: string, fallback = '#ffffff'): string {
  const rgb = parseRgbChannels(fillColor)
  if (!rgb) return fallback
  const lum =
    0.2126 * srgbChannelToLinear(rgb[0]) + 0.7152 * srgbChannelToLinear(rgb[1]) + 0.0722 * srgbChannelToLinear(rgb[2])
  const contrastDark = (lum + 0.05) / (DARK_INK_LUMINANCE + 0.05)
  const contrastWhite = 1.05 / (lum + 0.05)
  return contrastDark >= contrastWhite ? '#18191a' : '#ffffff'
}

/**
 * Assigns deterministic colors to chart series in rank order (`0, 1, 2, ...`):
 * - `isEmpty` -> `palette.emptyColor`
 * - `isOther` -> `palette.otherColor`
 * - `optionColor` -> resolved Base select option fill or stroke color
 * - Otherwise -> `palette.categorical` / `categoricalStrokes` followed by `extendedCategorical`
 *   in rank order (never hashing category strings, and never colliding with neutral gray).
 */
export function assignSeriesColors(
  seriesKeys: readonly SeriesColorDescriptor[],
  palette: VizThemePalette,
  options?: AssignSeriesColorsOptions
): Map<string, string> {
  const useStroke = options?.variant === 'stroke'
  const result = new Map<string, string>()
  const rankPool = useStroke
    ? [...palette.categoricalStrokes, ...palette.extendedCategoricalStrokes]
    : [...palette.categorical, ...palette.extendedCategorical]
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
    const explicit = useStroke
      ? resolveSelectOptionStrokeColor(descriptor.optionColor, palette.isDark)
      : resolveSelectOptionColor(descriptor.optionColor, palette.isDark)
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
    '--chart-total': palette.totalColor,
    '--color-chart-total': palette.totalColor,
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
