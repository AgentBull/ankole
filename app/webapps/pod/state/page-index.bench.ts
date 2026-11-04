import { QueryClient, QueryObserver } from '@tanstack/react-query'
import { cachedPages, contentKeys, type NavigationPage } from '../content-api'

const pageCount = Number(process.env.PAGE_INDEX_PAGES ?? 2000)
const observers = Number(process.env.PAGE_INDEX_OBSERVERS ?? 200)
const runs = Number(process.env.PAGE_INDEX_RUNS ?? 10)
const idAt = (index: number) => `019a0000-0000-7000-8000-${index.toString(16).padStart(12, '0')}`

function quantiles(samples: number[]) {
  const sorted = [...samples].sort((left, right) => left - right)
  const pick = (percentile: number) =>
    sorted[Math.min(sorted.length - 1, Math.ceil((percentile / 100) * sorted.length) - 1)]!
  return { p50: pick(50), p75: pick(75), p95: pick(95), min: sorted[0], max: sorted.at(-1) }
}

function pages(): NavigationPage[] {
  return Array.from({ length: pageCount }, (_, index) => ({
    id: idAt(index),
    name: `Page ${index}`,
    parent_id: null,
    position: String(index).padStart(6, '0'),
    type: 'doc',
    title: `Page ${index}`,
    inherit_permissions: true,
    metadata: {},
    actions: ['node_view'],
    role: 'view',
    has_children: false
  }))
}

function subscribeClosedRows() {
  const client = new QueryClient()
  client.setQueryData(contentKeys.navigation(), { path: pages() })
  const indexed = cachedPages(client)
  let errors = 0
  const stops: Array<() => void> = []
  const start = performance.now()
  for (let index = 0; index < observers; index += 1) {
    const observer = new QueryObserver(client, {
      queryKey: contentKeys.children('space', idAt(index)),
      queryFn: () => ({ pages: [], pageParams: [] }),
      enabled: false
    })
    stops.push(observer.subscribe(() => {}))
  }
  const ms = performance.now() - start
  const identityChanged = cachedPages(client) !== indexed
  if (cachedPages(client).length !== pageCount) errors += 1
  for (const stop of stops) stop()
  client.clear()
  return { ms, errors, identityChanged, pages: pageCount, observers }
}

const samples = []
for (let run = 0; run < runs; run += 1) samples.push(subscribeClosedRows())
const errors = samples.reduce((sum, sample) => sum + sample.errors, 0)

console.log(
  JSON.stringify(
    {
      pageCount,
      observers,
      runs,
      errors,
      work: {
        observers,
        pages: pageCount,
        identityChanged: samples.filter(sample => sample.identityChanged).length
      },
      ms: quantiles(samples.map(sample => sample.ms))
    },
    null,
    2
  )
)
if (errors > 0) process.exitCode = 1
