import { QueryClient } from '@tanstack/react-query'
import { previewRecordList } from '@ankole/applet-sdk/records'
import type { BaseRecord } from '@ankole/applet-sdk/types'
import { contentKeys, cachedPageMap, type NavigationPage } from '../content-api'
import { pageAncestors } from './page-location'
import { pageHrefFor } from '../use-page-metadata'

const pageCount = 2000
const lookups = 400
const renders = 40
const idAt = (index: number) => `019a0000-0000-7000-8000-${index.toString(16).padStart(12, '0')}`

function quantiles(samples: number[]) {
  const sorted = [...samples].sort((left, right) => left - right)
  const pick = (percentile: number) =>
    sorted[Math.min(sorted.length - 1, Math.ceil((percentile / 100) * sorted.length) - 1)]!
  return { p50: pick(50), p75: pick(75), p95: pick(95) }
}

function legacyLookup(id: string) {
  const pages = new Map<string, NavigationPage>()
  for (const [, data] of client.getQueriesData<{ path?: NavigationPage[] }>({ queryKey: contentKeys.all })) {
    for (const page of data?.path ?? []) pages.set(page.id, page)
  }
  const page = [...pages.values()].find(item => item.id === id)
  if (!page) return
  pageAncestors(page, pages)
  return page.id
}

const client = new QueryClient()
const pages: NavigationPage[] = Array.from({ length: pageCount }, (_, index) => ({
  id: idAt(index),
  name: `Page ${index}`,
  parent_id: index === 0 ? null : idAt(index - 1),
  position: String(index).padStart(6, '0'),
  type: 'doc',
  title: `Page ${index}`,
  inherit_permissions: true,
  metadata: {},
  actions: ['node_view'],
  role: 'view',
  has_children: index !== pageCount - 1
}))
client.setQueryData(contentKeys.navigation(), { path: pages })
cachedPageMap(client)

const records: BaseRecord[] = Array.from({ length: pageCount }, (_, index) => ({
  id: idAt(index),
  data: { name: `Row ${index}` },
  versions: {},
  created_at: '2026-11-05T00:00:00Z',
  updated_at: '2026-11-05T00:00:00Z',
  created_by: 'owner',
  updated_by: 'owner'
}))

function runPages(kind: 'scan' | 'index') {
  const start = performance.now()
  let found = 0
  for (let step = 0; step < lookups; step += 1) {
    const id = idAt(step)
    if (kind === 'scan') {
      if (legacyLookup(id)) found += 1
    } else if (pageHrefFor(client, id)) found += 1
  }
  return { ms: performance.now() - start, found }
}

function copyRecords() {
  return records.map(record => record)
}

function runRecords(kind: 'copy' | 'stable') {
  const start = performance.now()
  let same = 0
  for (let step = 0; step < renders; step += 1) {
    const next = kind === 'copy' ? copyRecords() : previewRecordList(records, [])
    if (next === records) same += 1
  }
  return { ms: performance.now() - start, same }
}

runPages('scan')
runPages('index')
runRecords('copy')
runRecords('stable')

const scan = []
const indexed = []
const copy = []
const stable = []
for (let index = 0; index < 10; index += 1) {
  scan.push(runPages('scan'))
  indexed.push(runPages('index'))
  copy.push(runRecords('copy'))
  stable.push(runRecords('stable'))
}

console.log(
  JSON.stringify(
    {
      pages: pageCount,
      lookups,
      pageLookup: {
        scan: quantiles(scan.map(sample => sample.ms)),
        index: quantiles(indexed.map(sample => sample.ms)),
        found: indexed.at(-1)?.found
      },
      renders,
      recordList: {
        copy: quantiles(copy.map(sample => sample.ms)),
        stable: quantiles(stable.map(sample => sample.ms)),
        stableHits: stable.at(-1)?.same
      }
    },
    null,
    2
  )
)
