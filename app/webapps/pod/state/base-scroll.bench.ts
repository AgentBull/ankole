import { Virtualizer } from '@tanstack/react-virtual'
import { baseGridRowEstimate } from '../base-row-size'

const count = Number(process.env.BASE_SCROLL_COUNT ?? 2000)
const actual = Number(process.env.BASE_SCROLL_ACTUAL ?? 32)
const viewport = Number(process.env.BASE_SCROLL_VIEWPORT ?? 640)
const runs = Number(process.env.BASE_SCROLL_RUNS ?? 10)
const previousEstimate = 48

function quantiles(samples: number[]) {
  const sorted = [...samples].sort((left, right) => left - right)
  const pick = (percentile: number) =>
    sorted[Math.min(sorted.length - 1, Math.ceil((percentile / 100) * sorted.length) - 1)]!
  return { p50: pick(50), p75: pick(75), p95: pick(95), min: sorted[0], max: sorted.at(-1) }
}

function scrollGrid(estimate: number) {
  let offset = 0
  let errors = 0
  const virtualizer = new Virtualizer({
    count,
    estimateSize: () => estimate,
    overscan: 8,
    getItemKey: index => index,
    getScrollElement: () => null,
    initialRect: { width: 800, height: viewport },
    observeElementRect: (_instance, callback) => {
      callback({ width: 800, height: viewport })
    },
    observeElementOffset: (_instance, callback) => {
      callback(offset, false)
    },
    scrollToFn: next => {
      offset = typeof next === 'number' ? next : offset
    }
  })
  const seen = new Set<number>()
  const start = performance.now()
  const limit = count * actual
  while (offset < limit) {
    const items = virtualizer.getVirtualItems()
    if (items.length === 0) {
      errors += 1
      break
    }
    for (const item of items) {
      if (seen.has(item.index)) continue
      seen.add(item.index)
      virtualizer.resizeItem(item.index, actual)
    }
    offset += viewport
    virtualizer.scrollOffset = offset
    virtualizer.scrollDirection = 'forward'
  }
  const ms = performance.now() - start
  if (seen.size !== count) errors += 1
  return { ms, errors, measured: virtualizer.itemSizeCache.size, seen: seen.size }
}

const productEstimate = baseGridRowEstimate()
const previous: ReturnType<typeof scrollGrid>[] = []
const current: ReturnType<typeof scrollGrid>[] = []
for (let run = 0; run < runs; run += 1) {
  previous.push(scrollGrid(previousEstimate))
  current.push(scrollGrid(productEstimate))
}

function report(samples: ReturnType<typeof scrollGrid>[]) {
  return {
    errors: samples.reduce((sum, sample) => sum + sample.errors, 0),
    work: { rowsMeasured: samples.at(-1)?.measured ?? 0, rowsVisited: samples.at(-1)?.seen ?? 0 },
    ms: quantiles(samples.map(sample => sample.ms))
  }
}

console.log(
  JSON.stringify(
    {
      count,
      actual,
      viewport,
      runs,
      previousEstimate,
      productEstimate,
      previous: report(previous),
      product: report(current)
    },
    null,
    2
  )
)
