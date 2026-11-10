import { isPrintSafeSvg } from '@ankole/uikit/viz/theme'
import { describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { writeContextGenerationFile } from '../src/cli/cli-guidance'
import { coerceTabularCell, injectDataIntoSpec, loadDataFile, parseDelimitedRecords } from '../src/cli/viz/data-loader'
import { designColorsToTokenOverrides, parseDesignFrontmatterColors } from '../src/cli/viz/design-palette'
import { CLI_CONTEXT_FILE_ENV, CLI_LEDGER_DIR_ENV } from '../src/core/execution/turn_runtime_env'

const VIZ_CLI_ENTRY = join(import.meta.dir, '../src/cli/viz/viz-cli.ts')

async function runVizProcess(
  args: string[],
  opts?: { cwd?: string; env?: Record<string, string | undefined>; stdinText?: string }
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const child = Bun.spawn([process.execPath, VIZ_CLI_ENTRY, ...args], {
    cwd: opts?.cwd ?? process.cwd(),
    env: opts?.env ?? process.env,
    stdin: opts?.stdinText !== undefined ? new Blob([opts.stdinText]) : 'ignore',
    stdout: 'pipe',
    stderr: 'pipe'
  })
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited
  ])
  return { stdout, stderr, exitCode }
}

describe('ankole-viz CLI, validator, pure-Bun Mermaid renderer, and data/design loaders', () => {
  it('prints help on stdout, emits first-use guidance once per context epoch on stderr, and writes Usage on malformed flags', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-viz-guidance-'))
    try {
      const ledgerDir = join(root, 'ledger')
      const contextFile = writeContextGenerationFile(root, 'conv-viz:epoch-1')
      const env = {
        ...process.env,
        [CLI_CONTEXT_FILE_ENV]: contextFile,
        [CLI_LEDGER_DIR_ENV]: ledgerDir
      }

      // First operational invocation emits first-use guidance on stderr while keeping stdout pure JSON.
      const first = await runVizProcess(['validate', 'mermaid', '--spec', 'flowchart LR\n  A --> B'], {
        cwd: root,
        env
      })
      expect(first.exitCode).toBe(0)
      expect(JSON.parse(first.stdout)).toEqual({ ok: true, valid: true, kind: 'mermaid' })
      expect(first.stderr).toContain('[ankole-cli first-use note: ankole-viz]')

      // Second invocation in the same context epoch keeps stderr completely silent.
      const second = await runVizProcess(['validate', 'mermaid', '--spec', 'flowchart TD\n  Start --> Done'], {
        cwd: root,
        env
      })
      expect(second.exitCode).toBe(0)
      expect(JSON.parse(second.stdout)).toEqual({ ok: true, valid: true, kind: 'mermaid' })
      expect(second.stderr).toBe('')

      // In a fresh context epoch, `--help` writes help to stdout and marks guidance seen.
      writeContextGenerationFile(root, 'conv-viz:epoch-2')
      const helpRes = await runVizProcess(['--help'], { cwd: root, env })
      expect(helpRes.exitCode).toBe(0)
      expect(helpRes.stderr).toBe('')
      expect(helpRes.stdout).toContain('ankole-viz validate')
      expect(helpRes.stdout).toContain('ankole-viz batch')
      expect(helpRes.stdout).toContain('--pdf-safe')

      const afterHelp = await runVizProcess(['validate', 'mermaid', '--spec', 'flowchart LR\n  X --> Y'], {
        cwd: root,
        env
      })
      expect(afterHelp.exitCode).toBe(0)
      expect(afterHelp.stderr).toBe('')

      // Malformed flags write Usage to stderr and exit 1 with empty stdout.
      const badFlag = await runVizProcess(['unknown-subcmd'], { cwd: root, env })
      expect(badFlag.exitCode).toBe(1)
      expect(badFlag.stdout).toBe('')
      expect(badFlag.stderr).toContain('Usage:')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('validates mermaid, infographic, chart, kline, and graph specs (valid & invalid, inline, stdin, and --data)', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-viz-validate-'))
    try {
      // 1. Mermaid valid & invalid
      const mmdOk = await runVizProcess(['validate', 'mermaid', '--spec', '-'], {
        cwd: root,
        stdinText: 'sequenceDiagram\n  Alice->>Bob: 你好'
      })
      expect(mmdOk.exitCode).toBe(0)
      expect(JSON.parse(mmdOk.stdout)).toEqual({ ok: true, valid: true, kind: 'mermaid' })

      const mmdBad = await runVizProcess(['validate', 'mermaid', '--spec', 'not_a_diagram_type %%% $$$'], {
        cwd: root
      })
      expect(mmdBad.exitCode).toBe(1)
      const mmdBadBody = JSON.parse(mmdBad.stdout)
      expect(mmdBadBody).toMatchObject({ ok: false, valid: false, kind: 'mermaid' })
      expect(mmdBadBody.errors.length).toBeGreaterThan(0)

      // 2. Infographic valid & invalid (also exercising `--kind` + `--input` aliases)
      const validInfographic = [
        'infographic list-row-simple-horizontal-arrow',
        'data',
        '  title 发布路径',
        '  items',
        '    - label 阶段一',
        '      desc 语法预检',
        '    - label 阶段二',
        '      desc 矢量导出'
      ].join('\n')
      const infoOk = await runVizProcess(['validate', '--kind', 'infographic', '--input', validInfographic], {
        cwd: root
      })
      expect(infoOk.exitCode).toBe(0)
      expect(JSON.parse(infoOk.stdout)).toEqual({ ok: true, valid: true, kind: 'infographic' })

      const infoBad = await runVizProcess(
        ['validate', 'infographic', '--spec', 'infographic unknown-nonexistent-template\ndata\n  title 坏模板'],
        { cwd: root }
      )
      expect(infoBad.exitCode).toBe(1)
      const infoBadBody = JSON.parse(infoBad.stdout)
      expect(infoBadBody).toMatchObject({ ok: false, valid: false, kind: 'infographic' })
      expect(infoBadBody.errors.join(' ')).toContain('Unknown infographic template')

      // 3. Statistical chart valid (with --data CSV) & invalid
      const csvPath = join(root, 'metrics.csv')
      writeFileSync(csvPath, 'quarter,code,revenue\n2026-Q1,000001,320.5\n2026-Q2,000002,410.25\n', 'utf8')
      const chartOk = await runVizProcess(
        ['validate', 'chart', '--spec', '{"type":"column","xField":"quarter","yField":"revenue"}', '--data', csvPath],
        { cwd: root }
      )
      expect(chartOk.exitCode).toBe(0)
      expect(JSON.parse(chartOk.stdout)).toEqual({ ok: true, valid: true, kind: 'chart' })

      const chartBad = await runVizProcess(['validate', 'chart', '--spec', '{"type":"unknown_type","data":[]}'], {
        cwd: root
      })
      expect(chartBad.exitCode).toBe(1)
      expect(JSON.parse(chartBad.stdout)).toMatchObject({ ok: false, valid: false, kind: 'chart' })

      // 4. Financial kline valid & invalid (high < low / invalid date)
      const klineOk = await runVizProcess(
        [
          'validate',
          'kline',
          '--spec',
          JSON.stringify({
            seriesType: 'candlestick',
            data: [
              { time: '2026-03-02', open: 10, high: 12, low: 9.5, close: 11.2, volume: 5000 },
              { time: '2026-03-03', open: 11.2, high: 12.5, low: 10.8, close: 12.1, volume: 6200 }
            ]
          })
        ],
        { cwd: root }
      )
      expect(klineOk.exitCode).toBe(0)
      expect(JSON.parse(klineOk.stdout)).toEqual({ ok: true, valid: true, kind: 'kline' })

      const klineBad = await runVizProcess(
        [
          'validate',
          'kline',
          '--spec',
          JSON.stringify({
            seriesType: 'candlestick',
            data: [{ time: '2026-02-30', open: 10, high: 8, low: 9, close: 8.5 }]
          })
        ],
        { cwd: root }
      )
      expect(klineBad.exitCode).toBe(1)
      expect(JSON.parse(klineBad.stdout)).toMatchObject({ ok: false, valid: false, kind: 'kline' })

      // 5. Network graph valid & invalid (dangling edge endpoint)
      const graphOk = await runVizProcess(
        [
          'validate',
          'graph',
          '--spec',
          JSON.stringify({
            nodes: [
              { id: 'n1', label: '网关' },
              { id: 'n2', label: '引擎' }
            ],
            edges: [{ source: 'n1', target: 'n2', label: '调用' }]
          })
        ],
        { cwd: root }
      )
      expect(graphOk.exitCode).toBe(0)
      expect(JSON.parse(graphOk.stdout)).toEqual({ ok: true, valid: true, kind: 'graph' })

      const graphBad = await runVizProcess(
        [
          'validate',
          'graph',
          '--spec',
          JSON.stringify({
            nodes: [{ id: 'n1', label: '网关' }],
            edges: [{ source: 'n1', target: 'missing_node' }]
          })
        ],
        { cwd: root }
      )
      expect(graphBad.exitCode).toBe(1)
      const graphBadBody = JSON.parse(graphBad.stdout)
      expect(graphBadBody).toMatchObject({ ok: false, valid: false, kind: 'graph' })
      expect(graphBadBody.errors.join(' ')).toContain('missing_node')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('renders Print-Safe Mermaid SVG in pure Bun with concrete hex palette, CJK text, and DESIGN.md frontmatter overrides', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-viz-mermaid-'))
    try {
      const designPath = join(root, 'custom-design.md')
      writeFileSync(
        designPath,
        [
          '---',
          'colors:',
          '  brand: "#1e4d6b"',
          '  chart-1: "#2a6f97"',
          '  paper: "#faf8f5"',
          '  ink: "#121518"',
          '  muted: "#586069"',
          '  line: "#dcd8d0"',
          '---',
          '# Custom Design Contract'
        ].join('\n'),
        'utf8'
      )

      const svgPath = join(root, 'architecture.svg')
      const dsl = 'flowchart LR\n  Ingest["数据采集 (CSV/JSONL)"] --> Export["矢量导出 PDF"]'
      const res = await runVizProcess(['mermaid', '--spec', dsl, '--design', designPath, '-o', svgPath], { cwd: root })
      expect(res.exitCode, res.stderr).toBe(0)
      const parsed = JSON.parse(res.stdout)
      expect(parsed).toMatchObject({
        ok: true,
        kind: 'mermaid',
        path: svgPath,
        format: 'svg',
        printSafe: true
      })
      expect(parsed.width).toBeGreaterThan(100)
      expect(parsed.height).toBeGreaterThan(40)

      const svg = readFileSync(svgPath, 'utf8')
      expect(isPrintSafeSvg(svg)).toBe(true)
      expect(svg).not.toContain('var(--')
      expect(svg).toContain('数据采集')
      expect(svg).toContain('矢量导出 PDF')
      // Verifies DESIGN.md paper background and ink foreground were materialized as concrete hex values.
      expect(svg.toLowerCase()).toContain('#faf8f5')
      expect(svg.toLowerCase()).toContain('#121518')

      // Dark mode with the same DESIGN.md preserves dark surface contrast rather than applying light paper/ink hexes.
      const darkSvgPath = join(root, 'architecture-dark.svg')
      const darkRes = await runVizProcess(
        ['mermaid', '--spec', dsl, '--theme', 'dark', '--design', designPath, '-o', darkSvgPath],
        { cwd: root }
      )
      expect(darkRes.exitCode, darkRes.stderr).toBe(0)
      const darkSvg = readFileSync(darkSvgPath, 'utf8')
      expect(isPrintSafeSvg(darkSvg)).toBe(true)
      expect(darkSvg.toLowerCase()).toContain('#0b0b0b')
      expect(darkSvg.toLowerCase()).not.toContain('#faf8f5')

      const parsedColors = parseDesignFrontmatterColors(readFileSync(designPath, 'utf8'))
      expect(designColorsToTokenOverrides(parsedColors, 'dark')).toEqual({ '--chart-1': '#2a6f97' })

      const defaultDesignColors = parseDesignFrontmatterColors(
        readFileSync(join(import.meta.dir, '../../library/templates/DESIGN.md'), 'utf8')
      )
      expect(designColorsToTokenOverrides(defaultDesignColors, 'dark')).toEqual({})
      expect(designColorsToTokenOverrides(defaultDesignColors, 'light')['--chart-1']).toBe('#2864b9')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('loads CSV, TSV, and JSONL datasets while preserving ISO dates and leading-zero security codes as strings', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-viz-dataloader-'))
    try {
      expect(coerceTabularCell('2026-03-15')).toBe('2026-03-15')
      expect(coerceTabularCell('2026-03')).toBe('2026-03')
      expect(coerceTabularCell('2026-Q4')).toBe('2026-Q4')
      expect(coerceTabularCell('000001')).toBe('000001')
      expect(coerceTabularCell('00700')).toBe('00700')
      expect(coerceTabularCell('128.75')).toBe(128.75)
      expect(coerceTabularCell('-42')).toBe(-42)
      expect(coerceTabularCell('0')).toBe(0)

      const csvContent = [
        'date,ticker,name,close,delta',
        '2026-03-10,000001,"平安银行 ""A股""",11.85,0.32',
        '2026-03-11,600519,"贵州茅台, SH",1680.5,-12.4'
      ].join('\r\n')
      const csvFile = join(root, 'quotes.csv')
      writeFileSync(csvFile, csvContent, 'utf8')

      const loadedCsv = await loadDataFile(csvFile)
      expect(loadedCsv).toEqual([
        { date: '2026-03-10', ticker: '000001', name: '平安银行 "A股"', close: 11.85, delta: 0.32 },
        { date: '2026-03-11', ticker: 600519, name: '贵州茅台, SH', close: 1680.5, delta: -12.4 }
      ])

      const tsvRows = parseDelimitedRecords('period\tcode\tcount\n2026-01\t002594\t950\n', '\t')
      expect(tsvRows).toEqual([{ period: '2026-01', code: '002594', count: 950 }])

      const jsonlFile = join(root, 'events.jsonl')
      writeFileSync(
        jsonlFile,
        '{"month":"2026-01","code":"000001","value":10}\n\n{"month":"2026-02","code":"000001","value":18}\n',
        'utf8'
      )
      const loadedJsonl = await loadDataFile(jsonlFile)
      expect(loadedJsonl).toEqual([
        { month: '2026-01', code: '000001', value: 10 },
        { month: '2026-02', code: '000001', value: 18 }
      ])

      const injectedGraph = injectDataIntoSpec(
        'graph',
        { layout: 'hierarchy' },
        { nodes: [{ id: 'a' }], edges: [{ source: 'a', target: 'a' }] }
      )
      expect(injectedGraph).toEqual({
        layout: 'hierarchy',
        nodes: [{ id: 'a' }],
        edges: [{ source: 'a', target: 'a' }]
      })

      // Rejects `kline --format svg` without `--pdf-safe` with an actionable Canvas explanation.
      const klineSvgErr = await runVizProcess(
        [
          'kline',
          '--spec',
          JSON.stringify({ data: [{ time: '2026-03-10', value: 100 }] }),
          '--format',
          'svg',
          '-o',
          join(root, 'kline.svg')
        ],
        { cwd: root }
      )
      expect(klineSvgErr.exitCode).toBe(1)
      expect(klineSvgErr.stderr).toContain('HTML5 Canvas')
      expect(klineSvgErr.stderr).toContain('--pdf-safe')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
