import { isRecord } from '@agentbull/active-support'
import { validateInfographicSyntax } from '@ankole/uikit/viz/infographic'
import type { MarketConvention, VizThemeMode } from '@ankole/uikit/viz/theme'
import { existsSync, statSync } from 'node:fs'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, extname, resolve } from 'node:path'
import { emitFirstUseGuidance, installStdoutEpipeGuard, markHelpSeen } from '../cli-guidance'
import { helpRequested } from '../primitives'
import { VizBrowserSession, type HarnessChromeMode, type VizRenderOutput } from './browser-renderer'
import { injectDataIntoSpec, loadDataFile } from './data-loader'
import { loadDesignTokenOverrides } from './design-palette'
import { renderMermaidSvgInBun } from './mermaid-svg'
import {
  VIZ_KINDS,
  validateAndNormalizeChartSpec,
  validateAndNormalizeGraphSpec,
  validateAndNormalizeKlineSpec,
  validateByKind,
  type VizKind
} from './validator'

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
                    histogram, boxplot, heatmap, radar, waterfall, gauge, treemap, sunburst, sankey, wordcloud).
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

class CliUsageError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'CliUsageError'
  }
}

interface ParsedFlags {
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

function parseCliFlags(argv: string[]): ParsedFlags {
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

function assertAllowedFlags(options: ReadonlyMap<string, string | boolean>, allowed: readonly string[]): void {
  const allowedSet = new Set(allowed)
  for (const key of options.keys()) {
    if (!allowedSet.has(key)) {
      throw new CliUsageError(`Unsupported option: ${key}`)
    }
  }
}

function getStringFlag(options: ReadonlyMap<string, string | boolean>, ...names: string[]): string | undefined {
  for (const name of names) {
    const val = options.get(name)
    if (typeof val === 'string') return val
  }
  return undefined
}

function parsePositiveNumber(raw: string | undefined, flagName: string): number | undefined {
  if (raw === undefined) return undefined
  const num = Number(raw)
  if (!Number.isFinite(num) || num <= 0) {
    throw new CliUsageError(`${flagName} must be a positive number (received "${raw}").`)
  }
  return num
}

function parseVizKind(raw: string | undefined): VizKind {
  if (!raw || !(VIZ_KINDS as readonly string[]).includes(raw)) {
    throw new CliUsageError(`Invalid visualization kind "${raw ?? ''}". Expected one of: ${VIZ_KINDS.join(', ')}.`)
  }
  return raw as VizKind
}

function parseThemeFlag(raw: string | undefined): VizThemeMode {
  if (raw === undefined) return 'light'
  if (raw === 'light' || raw === 'dark') return raw
  throw new CliUsageError(`Invalid --theme "${raw}". Expected "light" or "dark".`)
}

function parseMarketFlag(raw: string | undefined): MarketConvention | undefined {
  if (raw === undefined) return undefined
  if (raw === 'intl' || raw === 'cn') return raw
  throw new CliUsageError(`Invalid --market "${raw}". Expected "intl" or "cn".`)
}

function parseChromeFlag(raw: string | undefined): HarnessChromeMode {
  if (raw === undefined) return 'bare'
  if (raw === 'bare' || raw === 'card') return raw
  throw new CliUsageError(`Invalid --chrome "${raw}". Expected "bare" or "card".`)
}

function parseFormatFlag(raw: string | undefined): 'svg' | 'png' | undefined {
  if (raw === undefined) return undefined
  if (raw === 'svg' || raw === 'png') return raw
  throw new CliUsageError(`Invalid --format "${raw}". Expected "svg" or "png".`)
}

let cachedStdinPromise: Promise<string> | null = null
function readStdinOnce(): Promise<string> {
  if (!cachedStdinPromise) {
    cachedStdinPromise = new Response(Bun.stdin.stream()).text()
  }
  return cachedStdinPromise
}

function tryResolveExistingFile(candidate: string, searchDirs: readonly string[]): string | undefined {
  if (candidate.includes('\n') || candidate.includes('\r') || candidate.length > 1024) {
    return undefined
  }
  for (const base of searchDirs) {
    try {
      const full = resolve(base, candidate)
      if (existsSync(full) && statSync(full).isFile()) {
        return full
      }
    } catch {
      // Ignore path errors for inline DSL/JSON payloads.
    }
  }
  return undefined
}

function looksLikeMissingFilePath(raw: string, expectsJson: boolean): boolean {
  const trimmed = raw.trim()
  if (!trimmed || trimmed.includes('\n') || trimmed.includes('\r')) return false
  if (expectsJson) {
    return !trimmed.startsWith('{') && !trimmed.startsWith('[')
  }
  return (
    trimmed.startsWith('./') ||
    trimmed.startsWith('../') ||
    trimmed.startsWith('/') ||
    /\.(?:mmd|mermaid|infographic|dsl|txt|md|json)$/i.test(trimmed)
  )
}

async function loadSpecText(
  specArg: string,
  expectsJson: boolean,
  searchDirs: readonly string[]
): Promise<{ text: string; sourceFile?: string }> {
  if (specArg === '-') {
    return { text: await readStdinOnce() }
  }
  const resolvedFile = tryResolveExistingFile(specArg, searchDirs)
  if (resolvedFile) {
    return { text: await readFile(resolvedFile, 'utf8'), sourceFile: resolvedFile }
  }
  if (looksLikeMissingFilePath(specArg, expectsJson)) {
    throw new Error(`Spec file not found: ${specArg}`)
  }
  return { text: specArg }
}

function resolveDataInputPath(dataArg: string, searchDirs: readonly string[]): string {
  const found = tryResolveExistingFile(dataArg, searchDirs)
  return found ?? resolve(searchDirs[0]!, dataArg)
}

interface RenderJobConfig {
  kind: VizKind
  specInput: string | Record<string, unknown>
  dataPath?: string
  outputPath: string
  explicitFormat?: 'svg' | 'png'
  theme: VizThemeMode
  explicitMarket?: MarketConvention
  designPath?: string
  chrome: HarnessChromeMode
  width?: number
  height?: number
  dpr?: number
  pdfSafe: boolean
  searchDirs: readonly string[]
}

async function executeRenderJob(
  job: RenderJobConfig,
  getBrowserSession: () => VizBrowserSession
): Promise<VizRenderOutput> {
  const cwd = job.searchDirs[0] ?? process.cwd()
  const resolvedOutput = resolve(cwd, job.outputPath)
  const extFormat =
    extname(resolvedOutput).toLowerCase() === '.png'
      ? 'png'
      : extname(resolvedOutput).toLowerCase() === '.svg'
        ? 'svg'
        : undefined

  if (job.kind === 'kline') {
    const requestedKlineFormat = job.explicitFormat ?? extFormat ?? 'png'
    if (requestedKlineFormat === 'svg' && !job.pdfSafe) {
      throw new Error('kline renders on HTML5 Canvas and requires --format png or --pdf-safe.')
    }
  }

  const format: 'svg' | 'png' = job.kind === 'kline' ? 'png' : (job.explicitFormat ?? extFormat ?? 'svg')

  let resolvedDesignPath = job.designPath
  if (resolvedDesignPath) {
    const foundDesign = tryResolveExistingFile(resolvedDesignPath, job.searchDirs)
    if (foundDesign) resolvedDesignPath = foundDesign
  }
  const { tokenOverrides } = await loadDesignTokenOverrides({
    designPath: resolvedDesignPath,
    theme: job.theme,
    cwd
  })

  if (job.kind === 'mermaid') {
    const dslText =
      typeof job.specInput === 'string'
        ? (await loadSpecText(job.specInput, false, job.searchDirs)).text
        : JSON.stringify(job.specInput)

    const market = job.explicitMarket ?? 'intl'
    const rendered = await renderMermaidSvgInBun(dslText, {
      theme: job.theme,
      marketConvention: market,
      tokenOverrides,
      width: job.width,
      height: job.height
    })

    if (format === 'svg') {
      await mkdir(dirname(resolvedOutput), { recursive: true })
      await writeFile(resolvedOutput, rendered.svg, 'utf8')
      return {
        ok: true,
        kind: 'mermaid',
        path: resolvedOutput,
        format: 'svg',
        width: rendered.width,
        height: rendered.height,
        printSafe: rendered.printSafe
      }
    }

    const effectiveWidth = job.pdfSafe ? Math.max(job.width ?? rendered.width, 960) : (job.width ?? rendered.width)
    const effectiveDpr = job.pdfSafe ? Math.max(job.dpr ?? 2, 2) : (job.dpr ?? 2)
    return getBrowserSession().renderJob({
      outputPath: resolvedOutput,
      dpr: effectiveDpr,
      payload: {
        kind: 'mermaid',
        svgMarkup: rendered.svg,
        format: 'png',
        theme: job.theme,
        market,
        chrome: job.chrome,
        tokenOverrides,
        width: effectiveWidth,
        height: job.height ?? rendered.height,
        pdfSafe: job.pdfSafe
      }
    })
  }

  if (job.kind === 'infographic') {
    const dslText =
      typeof job.specInput === 'string'
        ? (await loadSpecText(job.specInput, false, job.searchDirs)).text
        : JSON.stringify(job.specInput)

    const syntax = validateInfographicSyntax(dslText)
    if (!syntax.ok) {
      throw new Error(`Invalid infographic syntax: ${syntax.errors.join('; ')}`)
    }

    const market = job.explicitMarket ?? 'intl'
    const effectiveDpr = job.pdfSafe ? Math.max(job.dpr ?? 2, 2) : (job.dpr ?? 2)
    return getBrowserSession().renderJob({
      outputPath: resolvedOutput,
      dpr: effectiveDpr,
      payload: {
        kind: 'infographic',
        source: dslText,
        format,
        theme: job.theme,
        market,
        chrome: job.chrome,
        tokenOverrides,
        ...(job.width ? { width: job.width } : {}),
        ...(job.height ? { height: job.height } : {}),
        pdfSafe: job.pdfSafe
      }
    })
  }

  // JSON-based grammars: `chart`, `kline`, `graph`
  let rawObj: unknown
  if (typeof job.specInput === 'string') {
    const { text } = await loadSpecText(job.specInput, true, job.searchDirs)
    try {
      rawObj = JSON.parse(text)
    } catch (error) {
      throw new Error(`Invalid JSON spec for ${job.kind}: ${error instanceof Error ? error.message : String(error)}`)
    }
  } else {
    rawObj = job.specInput
  }

  if (!isRecord(rawObj)) {
    throw new Error(`${job.kind} spec must be a JSON object.`)
  }

  let mergedObj: Record<string, unknown> = rawObj
  if (job.dataPath) {
    const loadedData = await loadDataFile(resolveDataInputPath(job.dataPath, job.searchDirs), cwd)
    mergedObj = injectDataIntoSpec(job.kind, rawObj, loadedData)
  }

  if (job.kind === 'chart') {
    const validated = validateAndNormalizeChartSpec(mergedObj)
    if (!validated.ok) {
      throw new Error(`Invalid chart spec: ${validated.errors.join('; ')}`)
    }
    const spec = validated.spec
    const market = job.explicitMarket ?? spec.marketConvention ?? 'intl'
    const baseWidth = job.width ?? spec.width ?? 760
    const effectiveWidth = job.pdfSafe && format === 'png' ? Math.max(baseWidth, 960) : baseWidth
    const effectiveHeight = job.height ?? spec.height ?? 420
    const effectiveDpr = job.pdfSafe ? Math.max(job.dpr ?? 2, 2) : (job.dpr ?? 2)

    return getBrowserSession().renderJob({
      outputPath: resolvedOutput,
      dpr: effectiveDpr,
      payload: {
        kind: 'chart',
        spec,
        format,
        theme: job.theme,
        market,
        chrome: job.chrome,
        tokenOverrides,
        width: effectiveWidth,
        height: effectiveHeight,
        pdfSafe: job.pdfSafe,
        ...(spec.title ? { cardTitle: spec.title } : {}),
        ...(spec.subtitle ? { cardSubtitle: spec.subtitle } : {})
      }
    })
  }

  if (job.kind === 'kline') {
    const validated = validateAndNormalizeKlineSpec(mergedObj)
    if (!validated.ok) {
      throw new Error(`Invalid kline spec: ${validated.errors.join('; ')}`)
    }
    const { spec, title, subtitle } = validated
    const market = job.explicitMarket ?? spec.marketConvention ?? 'intl'
    const baseWidth = job.width ?? spec.width ?? 840
    const effectiveWidth = job.pdfSafe ? Math.max(baseWidth, 960) : baseWidth
    const effectiveHeight = job.height ?? spec.height ?? 460
    const effectiveDpr = job.pdfSafe ? Math.max(job.dpr ?? 2, 2) : (job.dpr ?? 2)

    return getBrowserSession().renderJob({
      outputPath: resolvedOutput,
      dpr: effectiveDpr,
      payload: {
        kind: 'kline',
        spec,
        format: 'png',
        theme: job.theme,
        market,
        chrome: job.chrome,
        tokenOverrides,
        width: effectiveWidth,
        height: effectiveHeight,
        pdfSafe: job.pdfSafe,
        ...(title ? { cardTitle: title } : {}),
        ...(subtitle ? { cardSubtitle: subtitle } : {})
      }
    })
  }

  const validated = validateAndNormalizeGraphSpec(mergedObj)
  if (!validated.ok) {
    throw new Error(`Invalid graph spec: ${validated.errors.join('; ')}`)
  }
  const { spec, title, subtitle } = validated
  const market = job.explicitMarket ?? 'intl'
  const baseWidth = job.width ?? spec.width ?? 800
  const effectiveWidth = job.pdfSafe && format === 'png' ? Math.max(baseWidth, 960) : baseWidth
  const effectiveHeight = job.height ?? spec.height ?? 520
  const effectiveDpr = job.pdfSafe ? Math.max(job.dpr ?? 2, 2) : (job.dpr ?? 2)

  return getBrowserSession().renderJob({
    outputPath: resolvedOutput,
    dpr: effectiveDpr,
    payload: {
      kind: 'graph',
      spec,
      format,
      theme: job.theme,
      market,
      chrome: job.chrome,
      tokenOverrides,
      width: effectiveWidth,
      height: effectiveHeight,
      pdfSafe: job.pdfSafe,
      ...(title ? { cardTitle: title } : {}),
      ...(subtitle ? { cardSubtitle: subtitle } : {})
    }
  })
}

async function runValidateSubcommand(rest: string[], cwd: string): Promise<number> {
  const { positionals, options } = parseCliFlags(rest)
  assertAllowedFlags(options, ['--spec', '--input', '--data', '--kind'])

  const kindArg = positionals[0] ?? getStringFlag(options, '--kind')
  if (positionals.length > 1) {
    throw new CliUsageError(`Unexpected positional argument: ${positionals[1]}`)
  }
  const kind = parseVizKind(kindArg)
  const specArg = getStringFlag(options, '--spec', '--input')
  if (specArg === undefined) {
    throw new CliUsageError('validate requires --spec <dsl-or-json|path|->')
  }
  const dataArg = getStringFlag(options, '--data')
  const searchDirs = [cwd]

  if (kind === 'mermaid' || kind === 'infographic') {
    if (dataArg !== undefined) {
      throw new CliUsageError(`--data is not supported for ${kind} validation.`)
    }
    const { text } = await loadSpecText(specArg, false, searchDirs)
    const result = await validateByKind(kind, text)
    process.stdout.write(`${JSON.stringify(result)}\n`)
    return result.valid ? 0 : 1
  }

  const { text } = await loadSpecText(specArg, true, searchDirs)
  let parsedSpec: unknown
  try {
    parsedSpec = JSON.parse(text)
  } catch (error) {
    const invalidJsonResult = {
      ok: false as const,
      valid: false as const,
      kind,
      errors: [`Invalid JSON spec: ${error instanceof Error ? error.message : String(error)}`]
    }
    process.stdout.write(`${JSON.stringify(invalidJsonResult)}\n`)
    return 1
  }

  if (dataArg !== undefined && isRecord(parsedSpec)) {
    const loadedData = await loadDataFile(resolveDataInputPath(dataArg, searchDirs), cwd)
    parsedSpec = injectDataIntoSpec(kind, parsedSpec, loadedData)
  }

  const result = await validateByKind(kind, parsedSpec)
  process.stdout.write(`${JSON.stringify(result)}\n`)
  return result.valid ? 0 : 1
}

async function runSingleRenderSubcommand(kind: VizKind, rest: string[], cwd: string): Promise<number> {
  const { positionals, options } = parseCliFlags(rest)
  if (positionals.length > 0) {
    throw new CliUsageError(`Unexpected positional argument "${positionals[0]}" for ${kind}.`)
  }

  const commonFlags = [
    '--spec',
    '--input',
    '-o',
    '--output',
    '--format',
    '--theme',
    '--design',
    '--chrome',
    '--width',
    '--height',
    '--dpr',
    '--pdf-safe'
  ]
  const allowedByKind: Record<VizKind, string[]> = {
    mermaid: [...commonFlags, '--market'],
    infographic: [...commonFlags, '--market'],
    chart: [...commonFlags, '--data', '--market'],
    kline: [...commonFlags, '--data', '--market'],
    graph: [...commonFlags, '--data', '--market']
  }
  assertAllowedFlags(options, allowedByKind[kind])

  const specArg = getStringFlag(options, '--spec', '--input')
  if (specArg === undefined) {
    throw new CliUsageError(`${kind} requires --spec <spec|path|->`)
  }
  const outputArg = getStringFlag(options, '-o', '--output')
  if (!outputArg) {
    throw new CliUsageError(`${kind} requires -o <path>`)
  }

  let session: VizBrowserSession | null = null
  const getSession = (): VizBrowserSession => {
    if (!session) session = new VizBrowserSession()
    return session
  }

  try {
    const result = await executeRenderJob(
      {
        kind,
        specInput: specArg,
        dataPath: getStringFlag(options, '--data'),
        outputPath: outputArg,
        explicitFormat: parseFormatFlag(getStringFlag(options, '--format')),
        theme: parseThemeFlag(getStringFlag(options, '--theme')),
        explicitMarket: parseMarketFlag(getStringFlag(options, '--market')),
        designPath: getStringFlag(options, '--design'),
        chrome: parseChromeFlag(getStringFlag(options, '--chrome')),
        width: parsePositiveNumber(getStringFlag(options, '--width'), '--width'),
        height: parsePositiveNumber(getStringFlag(options, '--height'), '--height'),
        dpr: parsePositiveNumber(getStringFlag(options, '--dpr'), '--dpr'),
        pdfSafe: options.get('--pdf-safe') === true,
        searchDirs: [cwd]
      },
      getSession
    )
    process.stdout.write(`${JSON.stringify(result)}\n`)
    return 0
  } finally {
    if (session) {
      await (session as VizBrowserSession).close()
    }
  }
}

function coerceBatchJobConfig(
  rawJob: unknown,
  index: number,
  defaults: {
    theme?: VizThemeMode
    market?: MarketConvention
    design?: string
    chrome?: HarnessChromeMode
    dpr?: number
    pdfSafe?: boolean
  },
  searchDirs: readonly string[]
): RenderJobConfig {
  if (!isRecord(rawJob)) {
    throw new Error(`Batch job at index ${index} must be a JSON object.`)
  }
  const kind = parseVizKind(typeof rawJob.kind === 'string' ? rawJob.kind : undefined)
  const rawSpec = rawJob.spec ?? rawJob.input
  if (typeof rawSpec !== 'string' && !isRecord(rawSpec)) {
    throw new Error(`Batch job at index ${index} (${kind}) requires a string or object "spec".`)
  }
  const rawOutput = rawJob.output ?? rawJob.out ?? rawJob.path
  if (typeof rawOutput !== 'string' || !rawOutput.trim()) {
    throw new Error(`Batch job at index ${index} (${kind}) requires a non-empty string "output" path.`)
  }

  const theme = rawJob.theme !== undefined ? parseThemeFlag(String(rawJob.theme)) : (defaults.theme ?? 'light')
  const explicitMarket =
    rawJob.market !== undefined
      ? parseMarketFlag(String(rawJob.market))
      : rawJob.marketConvention !== undefined
        ? parseMarketFlag(String(rawJob.marketConvention))
        : defaults.market
  const chrome = rawJob.chrome !== undefined ? parseChromeFlag(String(rawJob.chrome)) : (defaults.chrome ?? 'bare')
  const explicitFormat = rawJob.format !== undefined ? parseFormatFlag(String(rawJob.format)) : undefined
  const designPath = typeof rawJob.design === 'string' ? rawJob.design : defaults.design
  const dataPath = typeof rawJob.data === 'string' ? rawJob.data : undefined
  const width =
    rawJob.width !== undefined ? parsePositiveNumber(String(rawJob.width), `jobs[${index}].width`) : undefined
  const height =
    rawJob.height !== undefined ? parsePositiveNumber(String(rawJob.height), `jobs[${index}].height`) : undefined
  const dpr = rawJob.dpr !== undefined ? parsePositiveNumber(String(rawJob.dpr), `jobs[${index}].dpr`) : defaults.dpr
  const pdfSafe =
    typeof rawJob.pdfSafe === 'boolean'
      ? rawJob.pdfSafe
      : typeof rawJob.pdf_safe === 'boolean'
        ? rawJob.pdf_safe
        : (defaults.pdfSafe ?? false)

  return {
    kind,
    specInput: rawSpec,
    dataPath,
    outputPath: rawOutput,
    explicitFormat,
    theme,
    explicitMarket,
    designPath,
    chrome,
    width,
    height,
    dpr,
    pdfSafe,
    searchDirs
  }
}

async function runBatchSubcommand(rest: string[], cwd: string): Promise<number> {
  const { positionals, options } = parseCliFlags(rest)
  if (positionals.length > 0) {
    throw new CliUsageError(`Unexpected positional argument "${positionals[0]}" for batch.`)
  }
  assertAllowedFlags(options, [
    '--spec',
    '--input',
    '--theme',
    '--market',
    '--design',
    '--chrome',
    '--dpr',
    '--pdf-safe'
  ])

  const specArg = getStringFlag(options, '--spec', '--input')
  if (specArg === undefined) {
    throw new CliUsageError('batch requires --spec <manifest.json|path|->')
  }

  const { text, sourceFile } = await loadSpecText(specArg, true, [cwd])
  let parsedManifest: unknown
  try {
    parsedManifest = JSON.parse(text)
  } catch (error) {
    throw new Error(`Invalid batch manifest JSON: ${error instanceof Error ? error.message : String(error)}`)
  }

  const searchDirs = sourceFile && dirname(sourceFile) !== cwd ? [cwd, dirname(sourceFile)] : [cwd]

  let rawJobs: unknown[]
  let manifestDefaults: {
    theme?: VizThemeMode
    market?: MarketConvention
    design?: string
    chrome?: HarnessChromeMode
    dpr?: number
    pdfSafe?: boolean
  } = {
    theme: options.has('--theme') ? parseThemeFlag(getStringFlag(options, '--theme')) : undefined,
    market: parseMarketFlag(getStringFlag(options, '--market')),
    design: getStringFlag(options, '--design'),
    chrome: options.has('--chrome') ? parseChromeFlag(getStringFlag(options, '--chrome')) : undefined,
    dpr: parsePositiveNumber(getStringFlag(options, '--dpr'), '--dpr'),
    pdfSafe: options.get('--pdf-safe') === true ? true : undefined
  }

  if (Array.isArray(parsedManifest)) {
    rawJobs = parsedManifest
  } else if (isRecord(parsedManifest) && Array.isArray(parsedManifest.jobs)) {
    rawJobs = parsedManifest.jobs
    manifestDefaults = {
      theme:
        manifestDefaults.theme ??
        (parsedManifest.theme !== undefined ? parseThemeFlag(String(parsedManifest.theme)) : undefined),
      market:
        manifestDefaults.market ??
        (parsedManifest.market !== undefined ? parseMarketFlag(String(parsedManifest.market)) : undefined),
      design:
        manifestDefaults.design ?? (typeof parsedManifest.design === 'string' ? parsedManifest.design : undefined),
      chrome:
        manifestDefaults.chrome ??
        (parsedManifest.chrome !== undefined ? parseChromeFlag(String(parsedManifest.chrome)) : undefined),
      dpr:
        manifestDefaults.dpr ??
        (parsedManifest.dpr !== undefined
          ? parsePositiveNumber(String(parsedManifest.dpr), 'manifest.dpr')
          : undefined),
      pdfSafe:
        manifestDefaults.pdfSafe ??
        (typeof parsedManifest.pdfSafe === 'boolean'
          ? parsedManifest.pdfSafe
          : typeof parsedManifest.pdf_safe === 'boolean'
            ? parsedManifest.pdf_safe
            : undefined)
    }
  } else {
    throw new Error('Batch manifest must be a JSON array of jobs or an object with a "jobs" array.')
  }

  if (rawJobs.length === 0) {
    throw new Error('Batch manifest must contain at least one job.')
  }

  const jobConfigs = rawJobs.map((job, idx) => coerceBatchJobConfig(job, idx, manifestDefaults, searchDirs))

  let session: VizBrowserSession | null = null
  const getSession = (): VizBrowserSession => {
    if (!session) session = new VizBrowserSession()
    return session
  }

  try {
    const results: VizRenderOutput[] = []
    for (const cfg of jobConfigs) {
      results.push(await executeRenderJob(cfg, getSession))
    }
    process.stdout.write(`${JSON.stringify({ ok: true, results })}\n`)
    return 0
  } finally {
    if (session) {
      await (session as VizBrowserSession).close()
    }
  }
}

export async function runVizCli(argv = process.argv.slice(2), cwd = process.cwd()): Promise<number> {
  if (argv.length === 0) {
    process.stderr.write(`${VIZ_CLI_USAGE}\n`)
    return 1
  }

  if (argv[0] === 'help' || helpRequested(argv)) {
    markHelpSeen({ commandKey: 'ankole-viz' })
    process.stdout.write(VIZ_CLI_HELP)
    return 0
  }

  const [subcommand, ...rest] = argv
  const validSubcommands = new Set(['validate', 'batch', ...VIZ_KINDS])
  if (!subcommand || !validSubcommands.has(subcommand)) {
    process.stderr.write(`Unknown subcommand "${subcommand ?? ''}".\n${VIZ_CLI_USAGE}\n`)
    return 1
  }

  await emitFirstUseGuidance({
    commandKey: 'ankole-viz',
    guidance: VIZ_FIRST_USE_GUIDANCE
  })

  try {
    if (subcommand === 'validate') {
      return await runValidateSubcommand(rest, cwd)
    }
    if (subcommand === 'batch') {
      return await runBatchSubcommand(rest, cwd)
    }
    return await runSingleRenderSubcommand(subcommand as VizKind, rest, cwd)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (error instanceof CliUsageError) {
      process.stderr.write(`${message}\n${VIZ_CLI_USAGE}\n`)
    } else {
      process.stderr.write(`${message}\n`)
    }
    return 1
  }
}

if (import.meta.main) {
  installStdoutEpipeGuard(process.stdout)
  const code = await runVizCli()
  process.exit(code)
}
