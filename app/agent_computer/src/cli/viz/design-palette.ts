import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import type { VizThemeMode } from '@ankole/uikit/viz/theme'

const FRONTMATTER_RE = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/

function stripYamlScalar(raw: string): string {
  const trimmed = raw.trim()
  if (!trimmed) return ''
  if (trimmed.startsWith('"')) {
    const endQuote = trimmed.indexOf('"', 1)
    if (endQuote > 0) return trimmed.slice(1, endQuote).trim()
  }
  if (trimmed.startsWith("'")) {
    const endQuote = trimmed.indexOf("'", 1)
    if (endQuote > 0) return trimmed.slice(1, endQuote).trim()
  }
  const commentIdx = trimmed.search(/\s+#/)
  return (commentIdx >= 0 ? trimmed.slice(0, commentIdx) : trimmed).trim()
}

function isPlausibleColorValue(value: string): boolean {
  const v = value.trim()
  if (!v) return false
  return /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(v) || /^(?:rgb|hsl|oklch)a?\(/i.test(v)
}

/**
 * Extracts key-value entries from the `colors:` section of a `DESIGN.md` YAML frontmatter block.
 */
export function parseDesignFrontmatterColors(markdown: string): Record<string, string> {
  const clean = markdown.charCodeAt(0) === 0xfeff ? markdown.slice(1) : markdown
  const match = FRONTMATTER_RE.exec(clean)
  if (!match) return {}

  const yamlBody = match[1]!
  const lines = yamlBody.split(/\r?\n/)
  const colors: Record<string, string> = {}

  let inColors = false
  let colorsIndent = 0
  let currentSubKey: string | null = null
  let currentSubIndent = 0

  for (const line of lines) {
    if (!line.trim() || line.trimStart().startsWith('#')) continue

    const indent = line.length - line.trimStart().length
    const trimmed = line.trim()

    if (!inColors) {
      if (/^colors\s*:\s*(?:#.*)?$/.test(trimmed)) {
        inColors = true
        colorsIndent = indent
        currentSubKey = null
      }
      continue
    }

    if (indent <= colorsIndent) {
      inColors = false
      currentSubKey = null
      continue
    }

    if (currentSubKey && indent > currentSubIndent) {
      const subMatch = /^value\s*:\s*(.+)$/.exec(trimmed)
      if (subMatch) {
        const val = stripYamlScalar(subMatch[1]!)
        if (isPlausibleColorValue(val)) {
          colors[currentSubKey] = val
        }
      }
      continue
    }

    currentSubKey = null
    const kvMatch = /^([a-zA-Z0-9_-]+)\s*:\s*(.*)$/.exec(trimmed)
    if (!kvMatch) continue

    const key = kvMatch[1]!.toLowerCase()
    const rawRest = kvMatch[2]!
    if (!rawRest || (rawRest.startsWith('#') && !/^#[0-9a-fA-F]{3,8}\b/.test(rawRest))) {
      currentSubKey = key
      currentSubIndent = indent
      continue
    }

    const val = stripYamlScalar(rawRest)
    if (isPlausibleColorValue(val)) {
      colors[key] = val
    }
  }

  return colors
}

const STOCK_LIGHT_DESIGN_CHART_DEFAULTS: Readonly<Record<string, ReadonlySet<string>>> = {
  'chart-1': new Set(['#2864b9', '#b31b5d']),
  'chart-2': new Set(['#049383', '#009d9a']),
  'chart-3': new Set(['#be8100', '#0f62fe']),
  'chart-4': new Set(['#b3395a', '#f1c21b']),
  'chart-5': new Set(['#a665b0', '#a56eff']),
  'chart-up': new Set(['#19875c', '#0f8a5f']),
  'chart-down': new Set(['#c1384b', '#c81e3a'])
}

function pickChartTokenOverride(
  colors: Readonly<Record<string, string>>,
  key: string,
  isDark: boolean
): string | undefined {
  if (isDark) {
    const explicitDark = colors[`${key}-dark`]
    if (explicitDark) return explicitDark
  }
  const raw = colors[key]
  if (!raw) return undefined
  if (isDark && STOCK_LIGHT_DESIGN_CHART_DEFAULTS[key]?.has(raw.trim().toLowerCase())) {
    return undefined
  }
  return raw
}

/**
 * Converts parsed `DESIGN.md` `colors:` entries into `tokenOverrides` for `resolveVizTheme`.
 * When `theme === 'dark'`, surface and foreground overrides (`paper`, `ink`, `muted`, `line`)
 * and uncustomized stock light-mode chart defaults are intentionally omitted so dark-mode
 * contrast and luminous Ceramic Glaze chart ramps are preserved.
 */
export function designColorsToTokenOverrides(
  colors: Readonly<Record<string, string>>,
  theme: VizThemeMode = 'light'
): Partial<Record<string, string>> {
  const overrides: Record<string, string> = {}
  const isDark = theme === 'dark'

  const explicitChart1 = pickChartTokenOverride(colors, 'chart-1', isDark)
  const fallbackBrand = isDark
    ? (colors['accent-on-dark'] ?? colors.brand ?? colors.primary)
    : (colors.brand ?? colors.primary)
  const hasStockDefaultChart1 = Boolean(
    colors['chart-1'] && STOCK_LIGHT_DESIGN_CHART_DEFAULTS['chart-1']?.has(colors['chart-1'].trim().toLowerCase())
  )
  const chart1 = explicitChart1 ?? (hasStockDefaultChart1 ? undefined : fallbackBrand)

  if (chart1) overrides['--chart-1'] = chart1
  const chart2 = pickChartTokenOverride(colors, 'chart-2', isDark)
  if (chart2) overrides['--chart-2'] = chart2
  const chart3 = pickChartTokenOverride(colors, 'chart-3', isDark)
  if (chart3) overrides['--chart-3'] = chart3
  const chart4 = pickChartTokenOverride(colors, 'chart-4', isDark)
  if (chart4) overrides['--chart-4'] = chart4
  const chart5 = pickChartTokenOverride(colors, 'chart-5', isDark)
  if (chart5) overrides['--chart-5'] = chart5
  const chartUp = pickChartTokenOverride(colors, 'chart-up', isDark)
  if (chartUp) overrides['--chart-up'] = chartUp
  const chartDown = pickChartTokenOverride(colors, 'chart-down', isDark)
  if (chartDown) overrides['--chart-down'] = chartDown
  const chartTotal = pickChartTokenOverride(colors, 'chart-total', isDark)
  if (chartTotal) overrides['--chart-total'] = chartTotal

  if (!isDark) {
    const paper = colors.paper ?? colors.canvas ?? colors.background
    if (paper) overrides['--background'] = paper
    if (colors['layer-01']) overrides['--layer-01'] = colors['layer-01']
    if (colors['layer-02'] ?? paper) overrides['--layer-02'] = (colors['layer-02'] ?? paper)!

    const ink = colors.ink ?? colors['text-primary'] ?? colors.foreground
    if (ink) overrides['--foreground'] = ink

    const muted = colors.muted ?? colors['text-secondary']
    if (muted) overrides['--fg-secondary'] = muted
    if (colors['text-placeholder']) overrides['--fg-tertiary'] = colors['text-placeholder']

    const line = colors.line ?? colors['border-subtle'] ?? colors.border
    if (line) overrides['--border'] = line
    if (colors['border-strong']) overrides['--border-strong'] = colors['border-strong']
  }

  return overrides
}

/**
 * Discovers an explicit `--design <path>` or auto-discovered `DESIGN.md` contract on disk
 * (`./DESIGN.md`, `/drive/DESIGN.md`, `/workspace/DESIGN.md`) and resolves theme token overrides.
 */
export async function loadDesignTokenOverrides(opts: {
  designPath?: string
  theme?: VizThemeMode
  cwd?: string
}): Promise<{ designFile?: string; tokenOverrides?: Partial<Record<string, string>> }> {
  const cwd = opts.cwd ?? process.cwd()
  const theme = opts.theme ?? 'light'

  let targetFile: string | undefined
  if (opts.designPath) {
    const candidate = resolve(cwd, opts.designPath)
    if (!existsSync(candidate)) {
      throw new Error(`Design file not found: ${opts.designPath}`)
    }
    targetFile = candidate
  } else {
    for (const candidate of [resolve(cwd, 'DESIGN.md'), '/drive/DESIGN.md', '/workspace/DESIGN.md']) {
      if (existsSync(candidate)) {
        targetFile = candidate
        break
      }
    }
  }

  if (!targetFile) {
    return {}
  }

  const markdown = await readFile(targetFile, 'utf8')
  const colors = parseDesignFrontmatterColors(markdown)
  const overrides = designColorsToTokenOverrides(colors, theme)
  return {
    designFile: targetFile,
    ...(Object.keys(overrides).length > 0 ? { tokenOverrides: overrides } : {})
  }
}
