import type { MarketConvention, VizThemeMode } from '@ankole/uikit/viz/theme'
import type { HarnessChromeMode } from './browser-renderer'
import { VIZ_KINDS, type VizKind } from './validator'

export const VIZ_CLI_USAGE = [
  'Usage:',
  '  ankole-viz --help',
  '  ankole-viz validate <mermaid|infographic|chart|kline|graph> --spec <dsl-or-json|path|-> [--data <path>]',
  '  ankole-viz mermaid --spec <dsl|path|-> -o <path> [--format svg|png] [--theme light|dark] [--design <path>] [--width <n>] [--height <n>] [--dpr <n>] [--pdf-safe]',
  '  ankole-viz chart --spec <json|path|-> [--data <csv|tsv|json|jsonl>] -o <path> [--format svg|png] [--theme light|dark] [--market intl|cn] [--design <path>] [--chrome bare|card] [--width <n>] [--height <n>] [--dpr <n>] [--pdf-safe]',
  '  ankole-viz kline --spec <json|path|-> [--data <csv|tsv|json|jsonl>] -o <path> [--format png|svg] [--theme light|dark] [--market intl|cn] [--design <path>] [--chrome bare|card] [--width <n>] [--height <n>] [--dpr <n>] [--pdf-safe]',
  '  ankole-viz graph --spec <json|path|-> [--data <json>] -o <path> [--format svg|png] [--theme light|dark] [--design <path>] [--width <n>] [--height <n>] [--dpr <n>] [--pdf-safe]',
  '  ankole-viz infographic --spec <dsl|path|-> -o <path> [--format svg|png] [--theme light|dark] [--market intl|cn] [--design <path>] [--width <n>] [--height <n>] [--dpr <n>] [--pdf-safe]',
  '  ankole-viz batch --spec <manifest.json|path|->'
].join('\n')

export const VIZ_FIRST_USE_GUIDANCE = [
  'Pass tabular/OHLCV datasets on disk via --data <file.csv|tsv|json|jsonl> instead of inlining large arrays in --spec.',
  'Use `ankole-viz validate <kind> --spec <...>` or `ankole-viz mermaid --format svg` for instant pure-Bun checks (<30ms).',
  'Pass `--pdf-safe` when exporting figures for Typst/Pandoc PDFs; templates using <foreignObject> or HTML5 Canvas auto-export 2x lossless PNG.',
  'Keep `--market intl` (green-up/red-down) by default; pass `--market cn` only for Mainland China A-share equities/indices.',
  'Run `ankole-viz --help` for full subcommand options and batch manifest schema.'
].join('\n')

export const VIZ_CLI_HELP = `${VIZ_CLI_USAGE}

Unified offline visualization validator and exporter powered by @ankole/uikit/viz engines.
Operational commands write pure JSON to stdout; diagnostics and usage notes go to stderr.

Subcommands:
  validate <kind>   Validate Mermaid, AntV Infographic DSL, Statistical Chart, K-Line, or Graph specs in Bun.
                    Exits 0 with {"ok":true,"valid":true,"kind":...} or exits 1 with {"ok":false,"valid":false,"errors":[...]}.
  mermaid           Render Mermaid flow/sequence/state/ER/class diagrams via Pele (<30ms pure-Bun SVG; Chromium for PNG).
  chart             Render AntV G2 v5 statistical charts (column, bar, line, area, combo, pie, donut, funnel, scatter,
                    histogram, boxplot, heatmap, radar, waterfall, gauge, treemap, sunburst, sankey, wordcloud, stat,
                    quantile_band).
  kline             Render TradingView Lightweight Charts v5 financial candlestick/baseline/yield-curve PNGs.
  graph             Render AntV G6 v5 network topologies (force, hierarchy, combo, radial).
  infographic       Render @antv/infographic narrative diagrams (SWOT, timelines, pros/cons, roadmaps, hierarchies).
  batch             Render multiple visualization jobs reusing a single headless Chromium session.

Common Options:
  --spec, --input <val>   Inline DSL/JSON string, file path on disk, or \`-\` to read UTF-8 from stdin.
  --data <path>           Load .csv, .tsv, .json, or .jsonl rows from disk into spec.data (or nodes/edges for graph).
                          CSV/TSV preserves ISO dates (YYYY-MM-DD, YYYY-MM, YYYY-QN) and leading-zero codes (000001).
  -o, --output <path>     Output file path (.svg or .png).
  --format <svg|png>      Explicit output format (defaults to -o extension, or png for kline and svg otherwise).
  --theme <light|dark>    Theme palette mode (default: light).
  --market <intl|cn>      Directional convention: intl = green-up/red-down (default), cn = A-share red-up/green-down.
  --design <path>         DESIGN.md path for YAML frontmatter colors: overrides (auto-discovers ./DESIGN.md, /drive/DESIGN.md).
  --chrome <bare|card>    Framing mode: bare (default, clean figure for Markdown/PDF captions) or card (bordered title header).
  --width <n>             Explicit width in CSS pixels.
  --height <n>            Explicit height in CSS pixels.
  --dpr <n>               Device pixel ratio for PNG rasterization (default: 2).
  --pdf-safe              Guarantee Print-Safe output for Typst/WeasyPrint/XeLaTeX. Rewrites .svg to 1920px+ lossless .png
                          when <foreignObject> (infographic) or HTML5 Canvas (kline) cannot emit vector-only SVG.

Batch Manifest (--spec <manifest.json>):
  Accepts either a JSON array of job objects or {"jobs": [...], "theme"?: "light", "market"?: "intl", "design"?: "...", "pdfSafe"?: true}.
  Each job supports: {"kind": "mermaid|chart|kline|graph|infographic", "spec": <string|object>, "data"?: "<path>", "output": "<path>", ...}.
`

export class CliUsageError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'CliUsageError'
  }
}

export interface ParsedFlags {
  positionals: string[]
  options: Map<string, string | boolean>
}

const BOOLEAN_FLAGS = new Set(['--pdf-safe', '--help', '-h'])
const VALUE_FLAGS = new Set([
  '--spec',
  '--input',
  '--data',
  '-o',
  '--output',
  '--format',
  '--theme',
  '--market',
  '--design',
  '--chrome',
  '--width',
  '--height',
  '--dpr',
  '--kind'
])

export function parseCliFlags(argv: string[]): ParsedFlags {
  const positionals: string[] = []
  const options = new Map<string, string | boolean>()

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i]!
    if (BOOLEAN_FLAGS.has(token)) {
      options.set(token, true)
      continue
    }

    if (token.startsWith('--') && token.includes('=')) {
      const eqIdx = token.indexOf('=')
      const flag = token.slice(0, eqIdx)
      const val = token.slice(eqIdx + 1)
      if (BOOLEAN_FLAGS.has(flag)) {
        if (val === 'true' || val === '1') options.set(flag, true)
        else if (val === 'false' || val === '0') options.set(flag, false)
        else throw new CliUsageError(`Invalid boolean value for ${flag}: ${val}`)
        continue
      }
      if (!VALUE_FLAGS.has(flag)) {
        throw new CliUsageError(`Unknown option: ${flag}`)
      }
      options.set(flag, val)
      continue
    }

    if (VALUE_FLAGS.has(token)) {
      const next = argv[i + 1]
      if (next === undefined) {
        throw new CliUsageError(`Missing value for ${token}`)
      }
      options.set(token, next)
      i += 1
      continue
    }

    if (token.startsWith('-') && token !== '-') {
      throw new CliUsageError(`Unknown option: ${token}`)
    }

    positionals.push(token)
  }

  return { positionals, options }
}

export function assertAllowedFlags(options: ReadonlyMap<string, string | boolean>, allowed: readonly string[]): void {
  const allowedSet = new Set(allowed)
  for (const key of options.keys()) {
    if (!allowedSet.has(key)) {
      throw new CliUsageError(`Unsupported option: ${key}`)
    }
  }
}

export function getStringFlag(options: ReadonlyMap<string, string | boolean>, ...names: string[]): string | undefined {
  for (const name of names) {
    const val = options.get(name)
    if (typeof val === 'string') return val
  }
  return undefined
}

export function parsePositiveNumber(raw: string | undefined, flagName: string): number | undefined {
  if (raw === undefined) return undefined
  const num = Number(raw)
  if (!Number.isFinite(num) || num <= 0) {
    throw new CliUsageError(`${flagName} must be a positive number (received "${raw}").`)
  }
  return num
}

export function parseVizKind(raw: string | undefined): VizKind {
  if (!raw || !(VIZ_KINDS as readonly string[]).includes(raw)) {
    throw new CliUsageError(`Invalid visualization kind "${raw ?? ''}". Expected one of: ${VIZ_KINDS.join(', ')}.`)
  }
  return raw as VizKind
}

export function parseThemeFlag(raw: string | undefined): VizThemeMode {
  if (raw === undefined) return 'light'
  if (raw === 'light' || raw === 'dark') return raw
  throw new CliUsageError(`Invalid --theme "${raw}". Expected "light" or "dark".`)
}

export function parseMarketFlag(raw: string | undefined): MarketConvention | undefined {
  if (raw === undefined) return undefined
  if (raw === 'intl' || raw === 'cn') return raw
  throw new CliUsageError(`Invalid --market "${raw}". Expected "intl" or "cn".`)
}

export function parseChromeFlag(raw: string | undefined): HarnessChromeMode {
  if (raw === undefined) return 'bare'
  if (raw === 'bare' || raw === 'card') return raw
  throw new CliUsageError(`Invalid --chrome "${raw}". Expected "bare" or "card".`)
}

export function parseFormatFlag(raw: string | undefined): 'svg' | 'png' | undefined {
  if (raw === undefined) return undefined
  if (raw === 'svg' || raw === 'png') return raw
  throw new CliUsageError(`Invalid --format "${raw}". Expected "svg" or "png".`)
}
