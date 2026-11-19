// Enforces the layer rules in docs/design-docs/DesignSystem.md: components and product code read semantic (L1)
// and component (L2) tokens only, every size comes from a ladder, and the dark theme only remaps names that the
// light theme declares.
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import { describe, expect, test } from 'bun:test'

const repo = resolve(import.meta.dirname, '../../..')
const SKIP_DIRS = new Set(['node_modules', 'dist', 'output', 'generated', 'integration', '.astro'])
const SOURCE = /\.(tsx|ts|css)$/
const TEST = /\.(test|spec|unit\.spec)\.tsx?$/

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name)
    if (statSync(full).isDirectory()) {
      if (!SKIP_DIRS.has(name)) walk(full, out)
    } else if (SOURCE.test(name) && !TEST.test(name)) {
      out.push(full)
    }
  }
  return out
}

const files = [
  ...walk(join(repo, 'libs/uikit/src/components')),
  join(repo, 'libs/uikit/src/styles.css'),
  ...walk(join(repo, 'app/webapps'))
]
const read = (file: string) => readFileSync(file, 'utf8')
const rel = (file: string) => relative(repo, file)

const HUES =
  'gray|brand|red|orange|yellow|green|teal|cyan|blue|purple|magenta|deeppurple|rose|amber|orchid|royalblue|manatee|navy|lime|pampas'
const UTILITY_PREFIX =
  '(?:bg|text|border(?:-[trblxyse])?|ring(?:-offset)?|divide|fill|stroke|outline|from|to|via|placeholder|caret|decoration|shadow)'
const LEGACY_COLORS = [
  'foreground',
  'background',
  'background-secondary',
  'background-tertiary',
  'background-overlay',
  'background-overlay-secondary',
  'background-overlay-tertiary',
  'background-overlay-inverse',
  'card',
  'card-foreground',
  'popover',
  'popover-foreground',
  'muted',
  'muted-foreground',
  'accent',
  'accent-foreground',
  'secondary',
  'secondary-foreground',
  'border',
  'input',
  'sidebar-foreground',
  'sidebar-accent',
  'sidebar-accent-foreground',
  'primary-foreground',
  'primary-disabled-foreground',
  'destructive-foreground',
  'warning-foreground',
  'success-foreground',
  'info-foreground',
  'chart-up-foreground',
  'chart-down-foreground'
]
const LEGACY_VARS = [
  ...LEGACY_COLORS,
  'text-primary',
  'text-secondary',
  'text-placeholder',
  'text-disabled',
  'text-on-color'
]

const paletteUtility = new RegExp(`(?<![\\w-])${UTILITY_PREFIX}-(?:${HUES})-\\d+(?:/\\d+)?(?![\\w-])`, 'g')
const tailwindDefaultPalette = new RegExp(
  `(?<![\\w-])${UTILITY_PREFIX}-(?:slate|zinc|neutral|stone|emerald|sky|indigo|violet|fuchsia|pink|amber|yellow|red|green|blue|orange|gray)-(?:50|[1-9]00|950)(?:/\\d+)?(?![\\w-])`,
  'g'
)
const paletteVar = new RegExp(`var\\(--color-(?:${HUES})-\\d+\\)`, 'g')
const legacyUtility = new RegExp(`(?<![\\w-])${UTILITY_PREFIX}-(?:${LEGACY_COLORS.join('|')})(?![\\w-])`, 'g')
const legacyVar = new RegExp(`var\\(--(?:color-)?(?:${LEGACY_VARS.join('|')})[,)]`, 'g')
const arbitraryText = /(?<![\w-])(?:text|leading)-\[\d+(?:\.\d+)?(?:px|rem)?\]/g
const arbitraryRadius = /(?<![\w-])rounded(?:-[a-z]+)?-\[\d+(?:\.\d+)?px\]/g
// Initials and emoji that scale with the box holding them keep their size and carry a `/* glyph */` note.
const cssFontSize = /font-size:\s*\d+(?:\.\d+)?px;(?!\s*\/\* glyph \*\/)/g
const cssHex = /#[0-9a-fA-F]{3,8}\b/g

// Agent-authored chart specifications and viz overrides read the legacy names through these lookup tables
// (see "Applet CSS contract" in DesignSystem.md).
const LEGACY_NAME_CONTRACT = new Set([
  'libs/uikit/src/viz/theme.ts',
  'libs/uikit/src/viz/graph-layout.ts',
  'app/webapps/pod/chat/mermaid/mermaid-renderer.ts'
])

function violations(pattern: RegExp, filter: (file: string) => boolean = () => true) {
  const found: string[] = []
  for (const file of files) {
    if (!filter(file)) continue
    const text = read(file)
    for (const match of text.matchAll(pattern)) found.push(`${rel(file)}: ${match[0]}`)
  }
  return found
}

describe('design system layers', () => {
  test('components and product code never name a palette step', () => {
    expect(violations(paletteUtility)).toEqual([])
    expect(violations(paletteVar)).toEqual([])
  })

  test('Tailwind default palette colours are not used', () => {
    expect(violations(tailwindDefaultPalette)).toEqual([])
  })

  test('only canonical semantic names are used', () => {
    expect(violations(legacyUtility)).toEqual([])
    expect(violations(legacyVar, file => !LEGACY_NAME_CONTRACT.has(rel(file)))).toEqual([])
  })

  test('type sizes and radii come from the ladders', () => {
    expect(violations(arbitraryText)).toEqual([])
    expect(violations(arbitraryRadius)).toEqual([])
    expect(violations(cssFontSize, file => file.endsWith('.css'))).toEqual([])
  })

  test('product stylesheets take colours from tokens', () => {
    // The emoji picker's swatches show the Unicode skin tones themselves, which no theme changes.
    const exempt = new Set(['libs/uikit/src/styles.css', 'libs/uikit/src/components/emoji-picker.css'])
    expect(violations(cssHex, file => file.endsWith('.css') && !exempt.has(rel(file)))).toEqual([])
  })

  test('the dark theme remaps only names the light theme declares', () => {
    const theme = read(join(repo, 'libs/uikit/src/theme.css'))
    const block = (header: string) => {
      const start = theme.indexOf('{', theme.indexOf(header)) + 1
      let depth = 1
      let end = start
      while (depth > 0) {
        const char = theme[end++]
        if (char === '{') depth += 1
        if (char === '}') depth -= 1
      }
      return theme.slice(start, end - 1)
    }
    const names = (body: string) => new Set([...body.matchAll(/^\s*(--[\w-]+)\s*:/gm)].map(match => match[1]))
    const light = names(block(':root {'))
    const dark = [...names(block("[data-theme='dark'] {"))].filter(name => !light.has(name))
    expect(dark).toEqual([])
  })
})
