import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../../common/i18n'
import { ContentScope } from '../content-context'
import { BaseViewContent } from '../base-views'
import type { BaseField, BaseRecord } from '@ankole/applet-sdk/types'

const count = Number(process.env.GALLERY_COUNT ?? 400)
const runs = Number(process.env.GALLERY_RUNS ?? 8)
const field: BaseField = {
  id: 'name',
  name: 'Name',
  description: '',
  type: 'text',
  config: {},
  is_primary: true,
  version: 1
}
const records: BaseRecord[] = Array.from({ length: count }, (_, index) => ({
  id: `019a0000-0000-7000-8000-${index.toString(16).padStart(12, '0')}`,
  data: { name: `Record ${index}` },
  versions: { name: 1 },
  created_at: '2026-11-05T00:00:00Z',
  updated_at: '2026-11-05T00:00:00Z',
  created_by: 'owner',
  updated_by: 'owner'
}))

function quantiles(samples: number[]) {
  const sorted = [...samples].sort((left, right) => left - right)
  const pick = (percentile: number) =>
    sorted[Math.min(sorted.length - 1, Math.ceil((percentile / 100) * sorted.length) - 1)]!
  return { p50: pick(50), p75: pick(75), p95: pick(95), min: sorted[0], max: sorted.at(-1) }
}

await loadLocale('en-US')
const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
const content = {
  realtime: { dispose() {} },
  base: { subscribe: () => () => {} },
  readDenial: () => undefined,
  dispose() {},
  pageHref: (id: string) => `/pages/${id}`
}

function renderGallery() {
  return renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <ContentScope value={content as never}>
        <BaseViewContent
          pageID="019a0000-0000-7000-8000-0000000000aa"
          tableID="table"
          tables={[]}
          fields={[field]}
          records={records}
          view={{ id: 'gallery', name: 'Gallery', type: 'gallery', config: {}, version: 0 }}
          editable={false}
          schemaEditable={false}
          create={async () => ({ records: [], deleted_ids: [], data_version: 1 })}
          update={async () => undefined}
          remove={async () => undefined}
          configure={() => undefined}
        />
      </ContentScope>
    </QueryClientProvider>
  )
}

let errors = 0
const samples: number[] = []
let bytes = 0
let cards = 0
for (let run = 0; run < runs; run += 1) {
  const start = performance.now()
  const html = renderGallery()
  samples.push(performance.now() - start)
  bytes = html.length
  cards = html.split('<article').length - 1
  if (cards !== count) errors += 1
  if (!html.includes('Record 0') || !html.includes(`Record ${count - 1}`)) errors += 1
}

console.log(JSON.stringify({ count, runs, errors, cards, bytes, ms: quantiles(samples) }, null, 2))
if (errors > 0) process.exitCode = 1
