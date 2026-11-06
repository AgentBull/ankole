import { isPrintSafeSvg } from '@ankole/uikit/viz/theme'
import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { inflateSync } from 'node:zlib'
import { mkdirAgent } from '../../../src/common/agent-user'
import { agentProcessArgv } from '../../../src/core/execution/process-group'

const PNG_MAGIC = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])

function assertValidPng(filePath: string): { buffer: Buffer; width: number; height: number } {
  const buffer = readFileSync(filePath)
  expect(buffer.subarray(0, 8)).toEqual(PNG_MAGIC)
  const width = buffer.readUInt32BE(16)
  const height = buffer.readUInt32BE(20)
  expect(width).toBeGreaterThan(0)
  expect(height).toBeGreaterThan(0)
  return { buffer, width, height }
}

/**
 * Decodes an 8-bit RGB/RGBA PNG buffer and counts green-dominant vs red-dominant
 * saturated pixels so `intl` (green-up/red-down) vs `cn` (red-up/green-down)
 * candlestick bodies are verified at the rendered pixel level.
 */
function countDirectionalPixels(png: Buffer): { greenPixels: number; redPixels: number } {
  const width = png.readUInt32BE(16)
  const height = png.readUInt32BE(20)
  const bitDepth = png[24]!
  const colorType = png[25]!
  expect(bitDepth).toBe(8)
  expect(colorType === 2 || colorType === 6).toBe(true)

  const channels = colorType === 6 ? 4 : 3
  const stride = width * channels
  const idatChunks: Buffer[] = []

  let offset = 8
  while (offset + 8 <= png.length) {
    const length = png.readUInt32BE(offset)
    const type = png.subarray(offset + 4, offset + 8).toString('ascii')
    const dataStart = offset + 8
    const dataEnd = dataStart + length
    if (type === 'IDAT') {
      idatChunks.push(png.subarray(dataStart, dataEnd))
    } else if (type === 'IEND') {
      break
    }
    offset = dataEnd + 4
  }

  const raw = inflateSync(Buffer.concat(idatChunks))
  const recon = new Uint8Array(height * stride)

  const paeth = (a: number, b: number, c: number): number => {
    const p = a + b - c
    const pa = Math.abs(p - a)
    const pb = Math.abs(p - b)
    const pc = Math.abs(p - c)
    if (pa <= pb && pa <= pc) return a
    return pb <= pc ? b : c
  }

  for (let y = 0; y < height; y += 1) {
    const filterType = raw[y * (stride + 1)]!
    const srcRow = y * (stride + 1) + 1
    const dstRow = y * stride
    for (let x = 0; x < stride; x += 1) {
      const byte = raw[srcRow + x]!
      const left = x >= channels ? recon[dstRow + x - channels]! : 0
      const up = y > 0 ? recon[dstRow - stride + x]! : 0
      const upLeft = y > 0 && x >= channels ? recon[dstRow - stride + x - channels]! : 0
      if (filterType === 0) recon[dstRow + x] = byte
      else if (filterType === 1) recon[dstRow + x] = (byte + left) & 0xff
      else if (filterType === 2) recon[dstRow + x] = (byte + up) & 0xff
      else if (filterType === 3) recon[dstRow + x] = (byte + ((left + up) >> 1)) & 0xff
      else recon[dstRow + x] = (byte + paeth(left, up, upLeft)) & 0xff
    }
  }

  let greenPixels = 0
  let redPixels = 0
  for (let i = 0; i < recon.length; i += channels) {
    const r = recon[i]!
    const g = recon[i + 1]!
    const b = recon[i + 2]!
    const a = channels === 4 ? recon[i + 3]! : 255
    if (a < 200) continue
    if (g > 110 && g - r > 55 && g - b > 25) {
      greenPixels += 1
    } else if (r > 150 && r - g > 80 && r - b > 60) {
      redPixels += 1
    }
  }

  return { greenPixels, redPixels }
}

describe('ankole-viz inside the packaged Worker container', () => {
  let root: string

  const runAsAgent = (argv: string[], timeout = 30_000) => {
    const wrapped = agentProcessArgv(argv)
    return spawnSync(wrapped[0]!, wrapped.slice(1), {
      cwd: root,
      encoding: 'utf8',
      timeout,
      env: {
        ...process.env,
        HOME: root
      }
    })
  }

  beforeAll(async () => {
    root = await mkdtemp('/tmp/ankole-viz-image-')
    await mkdirAgent(root, 0o755)
    expect(process.env.ANKOLE_VIZ_HARNESS_JS).toBe('/opt/ankole-viz/dist/harness-entry.js')
    expect(existsSync('/opt/ankole-viz/dist/harness-entry.js')).toBe(true)
  })

  afterAll(async () => {
    if (root) {
      await rm(root, { recursive: true, force: true })
    }
  })

  test('renders Mermaid, G2 statistical charts, K-line (intl vs cn), G6 graphs, Print-Safe Infographics, batch jobs, and compiles a Pandoc+Typst PDF report', () => {
    // 1. `ankole-viz mermaid` -> Print-Safe `.svg` with CJK text
    const mermaidOut = join(root, 'flow.svg')
    const mmdRes = runAsAgent([
      'ankole-viz',
      'mermaid',
      '--spec',
      'flowchart LR\n  Source["原始行情 CSV"] --> Engine["可视化引擎"] --> Report["投研报告 PDF"]',
      '-o',
      mermaidOut
    ])
    expect(mmdRes.status, `${mmdRes.stderr}\n${mmdRes.stdout}`).toBe(0)
    const mmdJson = JSON.parse(mmdRes.stdout)
    expect(mmdJson).toMatchObject({ ok: true, kind: 'mermaid', path: mermaidOut, format: 'svg', printSafe: true })
    const mmdSvg = readFileSync(mermaidOut, 'utf8')
    expect(isPrintSafeSvg(mmdSvg)).toBe(true)
    expect(mmdSvg).toContain('原始行情 CSV')
    expect(mmdSvg).toContain('投研报告 PDF')

    // 2. `ankole-viz chart` with `--data` CSV -> Print-Safe `.svg` & `.png`
    const salesCsv = join(root, 'sales.csv')
    writeFileSync(
      salesCsv,
      ['quarter,code,revenue', '2026-Q1,000001,180', '2026-Q2,000002,245', '2026-Q3,000003,310'].join('\n'),
      'utf8'
    )
    const chartSpec = JSON.stringify({
      type: 'column',
      xField: 'quarter',
      yField: 'revenue',
      title: '季度营收趋势'
    })
    const chartSvgOut = join(root, 'chart.svg')
    const chartPngOut = join(root, 'chart.png')

    const chartSvgRes = runAsAgent(['ankole-viz', 'chart', '--spec', chartSpec, '--data', salesCsv, '-o', chartSvgOut])
    expect(chartSvgRes.status, `${chartSvgRes.stderr}\n${chartSvgRes.stdout}`).toBe(0)
    expect(JSON.parse(chartSvgRes.stdout)).toMatchObject({
      ok: true,
      kind: 'chart',
      path: chartSvgOut,
      format: 'svg',
      printSafe: true
    })
    expect(isPrintSafeSvg(readFileSync(chartSvgOut, 'utf8'))).toBe(true)

    const chartPngRes = runAsAgent([
      'ankole-viz',
      'chart',
      '--spec',
      chartSpec,
      '--data',
      salesCsv,
      '--format',
      'png',
      '-o',
      chartPngOut
    ])
    expect(chartPngRes.status, `${chartPngRes.stderr}\n${chartPngRes.stdout}`).toBe(0)
    expect(JSON.parse(chartPngRes.stdout)).toMatchObject({ ok: true, kind: 'chart', format: 'png', printSafe: true })
    assertValidPng(chartPngOut)

    // 3. `ankole-viz kline` `--market intl` vs `--market cn` -> `.png` with distinct directional colors
    // All 4 sessions are strong bull (close > open) candles so `intl` paints green bodies and `cn` paints red bodies!
    const bullOhlcCsv = join(root, 'bull-ohlc.csv')
    writeFileSync(
      bullOhlcCsv,
      [
        'time,open,high,low,close,volume',
        '2026-03-02,100,115,99,114,25000',
        '2026-03-03,114,130,113,128,31000',
        '2026-03-04,128,146,127,144,29000',
        '2026-03-05,144,162,143,160,36000'
      ].join('\n'),
      'utf8'
    )
    const klineSpec = JSON.stringify({ seriesType: 'candlestick', showVolume: false, attributionLogo: true })
    const klineIntlOut = join(root, 'kline-intl.png')
    const klineCnOut = join(root, 'kline-cn.png')

    const klineIntlRes = runAsAgent([
      'ankole-viz',
      'kline',
      '--spec',
      klineSpec,
      '--data',
      bullOhlcCsv,
      '--market',
      'intl',
      '-o',
      klineIntlOut
    ])
    expect(klineIntlRes.status, `${klineIntlRes.stderr}\n${klineIntlRes.stdout}`).toBe(0)

    const klineCnRes = runAsAgent([
      'ankole-viz',
      'kline',
      '--spec',
      klineSpec,
      '--data',
      bullOhlcCsv,
      '--market',
      'cn',
      '-o',
      klineCnOut
    ])
    expect(klineCnRes.status, `${klineCnRes.stderr}\n${klineCnRes.stdout}`).toBe(0)

    const intlPng = assertValidPng(klineIntlOut)
    const cnPng = assertValidPng(klineCnOut)
    expect(intlPng.buffer.equals(cnPng.buffer)).toBe(false)

    const intlColors = countDirectionalPixels(intlPng.buffer)
    const cnColors = countDirectionalPixels(cnPng.buffer)
    expect(intlColors.greenPixels).toBeGreaterThan(intlColors.redPixels)
    expect(cnColors.redPixels).toBeGreaterThan(cnColors.greenPixels)

    // 4. `ankole-viz graph` -> Print-Safe `.svg`
    const graphSvgOut = join(root, 'topology.svg')
    const graphRes = runAsAgent([
      'ankole-viz',
      'graph',
      '--spec',
      JSON.stringify({
        layout: 'hierarchy',
        nodes: [
          { id: 'gateway', label: '接入网关', ramp: 'brand' },
          { id: 'kernel', label: 'Rust 内核', ramp: 'blue' },
          { id: 'worker', label: 'Agent 工作节点', ramp: 'teal' }
        ],
        edges: [
          { source: 'gateway', target: 'kernel', label: 'gRPC' },
          { source: 'kernel', target: 'worker', label: 'Fabric' }
        ]
      }),
      '-o',
      graphSvgOut
    ])
    expect(graphRes.status, `${graphRes.stderr}\n${graphRes.stdout}`).toBe(0)
    expect(JSON.parse(graphRes.stdout)).toMatchObject({
      ok: true,
      kind: 'graph',
      path: graphSvgOut,
      format: 'svg',
      printSafe: true
    })
    expect(isPrintSafeSvg(readFileSync(graphSvgOut, 'utf8'))).toBe(true)

    // 5. `ankole-viz infographic --pdf-safe -o out.svg` -> automatically falls back to `out.png`
    const requestedInfoSvg = join(root, 'roadmap.svg')
    const expectedInfoPng = join(root, 'roadmap.png')
    const infographicDsl = [
      'infographic list-row-simple-horizontal-arrow',
      'data',
      '  title 季度执行路线图',
      '  items',
      '    - label 阶段一',
      '      desc 数据治理与校验',
      '    - label 阶段二',
      '      desc 自动化研报发布'
    ].join('\n')

    const infoRes = runAsAgent([
      'ankole-viz',
      'infographic',
      '--spec',
      infographicDsl,
      '--pdf-safe',
      '-o',
      requestedInfoSvg
    ])
    expect(infoRes.status, `${infoRes.stderr}\n${infoRes.stdout}`).toBe(0)
    const infoBody = JSON.parse(infoRes.stdout)
    expect(infoBody).toMatchObject({
      ok: true,
      kind: 'infographic',
      path: expectedInfoPng,
      format: 'png',
      printSafe: true,
      fallbackReason: 'foreignObject'
    })
    expect(infoBody.width).toBeGreaterThanOrEqual(1920)
    assertValidPng(expectedInfoPng)

    // 6. `ankole-viz batch` rendering multiple charts in a single Chromium session
    const batchManifestPath = join(root, 'manifest.json')
    const batchChartOut = join(root, 'batch-line.svg')
    const batchKlineOut = join(root, 'batch-kline.png')
    writeFileSync(
      batchManifestPath,
      JSON.stringify({
        pdfSafe: true,
        jobs: [
          {
            kind: 'chart',
            spec: { type: 'line', xField: 'quarter', yField: 'revenue' },
            data: salesCsv,
            output: batchChartOut
          },
          {
            kind: 'kline',
            spec: { seriesType: 'candlestick' },
            data: bullOhlcCsv,
            market: 'cn',
            output: batchKlineOut
          }
        ]
      }),
      'utf8'
    )
    const batchRes = runAsAgent(['ankole-viz', 'batch', '--spec', batchManifestPath], 45_000)
    expect(batchRes.status, `${batchRes.stderr}\n${batchRes.stdout}`).toBe(0)
    const batchBody = JSON.parse(batchRes.stdout)
    expect(batchBody.ok).toBe(true)
    expect(batchBody.results).toHaveLength(2)
    expect(batchBody.results[0]).toMatchObject({ kind: 'chart', path: batchChartOut, format: 'svg', printSafe: true })
    expect(batchBody.results[1]).toMatchObject({
      kind: 'kline',
      path: batchKlineOut,
      format: 'png',
      printSafe: true,
      fallbackReason: 'canvas'
    })

    // 7. Compile a Markdown report embedding the exported SVG and PNG figures via `pandoc --pdf-engine=typst` -> `.pdf`
    // and rasterize page 1 with `pdftoppm -png` verifying non-empty rendered PDF output.
    const reportMdPath = join(root, 'report.md')
    const reportPdfPath = join(root, 'report.pdf')
    const page1Prefix = join(root, 'report-page1')
    writeFileSync(
      reportMdPath,
      [
        '# 2026 季度统一可视化投研报告',
        '',
        '![系统数据链路](flow.svg)',
        '',
        '![季度营收柱状图](chart.svg)',
        '',
        '![网络拓扑结构](topology.svg)',
        '',
        '![A股多头K线走势](kline-cn.png)',
        '',
        '![阶段执行路线图](roadmap.png)'
      ].join('\n'),
      'utf8'
    )

    const pandocRes = runAsAgent(
      ['pandoc', reportMdPath, '--pdf-engine=typst', '-V', 'mainfont=IBM Plex Sans SC', '-o', reportPdfPath],
      45_000
    )
    expect(pandocRes.status, `${pandocRes.stderr}\n${pandocRes.stdout}`).toBe(0)
    expect(statSync(reportPdfPath).size).toBeGreaterThan(5_000)

    const ppmRes = runAsAgent([
      'pdftoppm',
      '-png',
      '-r',
      '150',
      '-f',
      '1',
      '-l',
      '1',
      '-singlefile',
      reportPdfPath,
      page1Prefix
    ])
    expect(ppmRes.status, `${ppmRes.stderr}\n${ppmRes.stdout}`).toBe(0)
    const rasterizedPage = assertValidPng(`${page1Prefix}.png`)
    expect(rasterizedPage.width).toBeGreaterThan(800)
    expect(rasterizedPage.height).toBeGreaterThan(1000)
  }, 120_000)
})
