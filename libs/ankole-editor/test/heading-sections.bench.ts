import { headingSections } from '../src/editor/headings'
import { open } from './helpers'

const count = Number(process.env.HEADING_COUNT ?? 400)
const runs = Number(process.env.HEADING_RUNS ?? 10)
const source = Array.from({ length: count }, (_, index) => `# Section ${index}\n\nParagraph ${index}.`).join('\n\n')
const editor = open(source)

function quantiles(samples: number[]) {
  const sorted = [...samples].sort((left, right) => left - right)
  const pick = (percentile: number) =>
    sorted[Math.min(sorted.length - 1, Math.ceil((percentile / 100) * sorted.length) - 1)]!
  return { p50: pick(50), p75: pick(75), p95: pick(95), min: sorted[0], max: sorted.at(-1) }
}

let errors = 0
const samples: number[] = []
let sections = 0
for (let run = 0; run < runs; run += 1) {
  const start = performance.now()
  const found = headingSections(editor.state.doc)
  samples.push(performance.now() - start)
  sections = found.length
  if (found.length !== count) errors += 1
  for (let index = 1; index < found.length; index += 1) {
    if (found[index]!.pos < found[index - 1]!.pos) errors += 1
  }
}

console.log(JSON.stringify({ count, runs, errors, sections, ms: quantiles(samples) }, null, 2))
if (errors > 0) process.exitCode = 1
