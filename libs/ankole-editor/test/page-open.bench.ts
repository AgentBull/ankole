import { parseXml } from '../src/document/xml'
import { normalizedPageDocument, pageDocument } from '../src/editor/convert'

const blocks = Number(process.env.PAGE_BLOCKS ?? 400)
const runs = Number(process.env.PAGE_RUNS ?? 10)
const xml = `<page>${Array.from({ length: blocks }, (_, index) => `<h1>Section ${index}</h1><p>Paragraph ${index} with enough text to look like a real page.</p>`).join('')}</page>`

function quantiles(samples: number[]) {
  const sorted = [...samples].sort((left, right) => left - right)
  const pick = (percentile: number) =>
    sorted[Math.min(sorted.length - 1, Math.ceil((percentile / 100) * sorted.length) - 1)]!
  return { p50: pick(50), p75: pick(75), p95: pick(95), min: sorted[0], max: sorted.at(-1) }
}

function time(run: () => void) {
  const samples: number[] = []
  for (let index = 0; index < runs; index += 1) {
    const start = performance.now()
    run()
    samples.push(performance.now() - start)
  }
  return quantiles(samples)
}

const parsed = parseXml(xml)
let errors = 0
const once = normalizedPageDocument(parsed)
const twice = pageDocument(parsed)
if (!once.eq(twice)) errors += 1

process.stdout.write(
  `${JSON.stringify(
    {
      blocks,
      runs,
      errors,
      parseXml: time(() => parseXml(xml)),
      importMutableTree: time(() => pageDocument(parsed)),
      buildParsedTree: time(() => normalizedPageDocument(parsed))
    },
    null,
    2
  )}\n`
)
if (errors > 0) process.exitCode = 1
