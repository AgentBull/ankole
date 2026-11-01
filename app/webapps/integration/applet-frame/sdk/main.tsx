/** Browser integration of the real SDK; BaseAPI, channel, and host boundaries use explicit fixtures. */
import { useEffect, useState } from 'react'
import type { RecordsResult } from '@ankole/applet-sdk/types'
import { QueryClient } from '@tanstack/react-query'
import {
  defineApplet,
  createReadDenials,
  expectedVersions,
  useAggregate,
  useChannel,
  useRecords,
  useRoute,
  useRouteMutation,
  usePod
} from '@ankole/applet-sdk'
import type { AppletRuntime, RouteCall, BaseRecord, RecordWrite, TableEvent } from '@ankole/applet-sdk/types'
import { loadLocale } from '../../../common/i18n'
import { InternalAPIError } from '../../../common/internal-api-client'

await loadLocale('en-US')
const host = document.querySelector('#applet')!
let record: BaseRecord = {
  id: 'record',
  data: { amount: 1 },
  versions: { amount: 1 },
  created_at: '',
  updated_at: '',
  created_by: 'human',
  updated_by: 'human'
}
const tables = new Set<(event: TableEvent) => void>()
const baseReads = { records: 0, aggregate: 0 }
let tableRevoked = false
const events = new Map<string, Set<(payload: unknown) => void>>()
let sent: RecordWrite | undefined
let readStatus = 200
let routeStatus = 200
let routeValue = 1
let holdRoute = false
let routeAborted = 0
const routeCalls: { method: string; path: string; query?: unknown; body?: unknown }[] = []
let releaseDeniedWrite: (() => void) | undefined
let blockNextWrite = false
let failPendingWrite = false
const checkRead = () => {
  if (readStatus !== 200) {
    throw new InternalAPIError(readStatus, 'Fixture read failure', { error: { code: 'fixture_read_failure' } })
  }
}
let opens = 0,
  closes = 0
const retryReads = new URLSearchParams(location.search).has('retry')
const notifyDataOnly = new URLSearchParams(location.search).has('notify-data-only')
const client = new QueryClient({
  defaultOptions: {
    queries: {
      retry: retryReads ? 1 : false,
      retryDelay: 10_000,
      ...(notifyDataOnly ? { notifyOnChangeProps: ['data'] as const } : {})
    }
  }
})
const readDenials = createReadDenials(client.getQueryCache())
window.addEventListener('pagehide', readDenials.dispose, { once: true })
function tableChanged(event: TableEvent) {
  if (event.access_revoked) client.removeQueries({ queryKey: runtime.base.key('table') })
  else void client.invalidateQueries({ queryKey: runtime.base.key('table') })
  for (const notify of tables) notify(event)
}
function errorStatus(error: unknown) {
  return error instanceof InternalAPIError ? error.status : null
}
function readState(result: {
  data?: unknown
  error: unknown
  failureReason: unknown
  status: string
  isSuccess: boolean
  isError: boolean
  isPending: boolean
  isLoading: boolean
  isLoadingError: boolean
  isRefetchError: boolean
}) {
  if (result.isSuccess && result.data === undefined) throw new Error('A successful query must provide its data')
  return JSON.stringify({
    status: result.status,
    isSuccess: result.isSuccess,
    isError: result.isError,
    isPending: result.isPending,
    isLoading: result.isLoading,
    isLoadingError: result.isLoadingError,
    isRefetchError: result.isRefetchError,
    data: result.data !== undefined,
    error: errorStatus(result.error),
    failureReason: errorStatus(result.failureReason)
  })
}
const runtime: AppletRuntime = {
  pageID: 'sdk-fixture',
  instanceID: 'sdk-fixture',
  actions: ['node_view', 'node_contribute'],
  revision: 7,
  routes: {
    key: () => ['sdk-fixture', 'routes', 7],
    async call<T>({ method, path, ...request }: RouteCall) {
      routeCalls.push({ method, path, query: request.query, body: request.body })
      if (holdRoute && method === 'GET') {
        await new Promise<void>((_resolve, reject) => {
          request.signal?.addEventListener(
            'abort',
            () => {
              routeAborted++
              reject(request.signal?.reason)
            },
            { once: true }
          )
        })
      }
      if (routeStatus !== 200) {
        throw new InternalAPIError(routeStatus, 'Fixture route failure', { error: { code: 'fixture_route_failure' } })
      }
      if (method === 'POST') routeValue++
      return { value: routeValue } as T
    }
  },
  queryClient: client,
  readDenial: readDenials.get,
  base: {
    key: id => ['sdk-fixture', id],
    schema: async () => {
      throw new Error('This fixture only exercises record reads')
    },
    aggregate: async () => {
      baseReads.aggregate++
      checkRead()
      return { groups: [{ values: [], metrics: { count: 1 } }], data_version: record.versions.amount! }
    },
    records: async () => {
      baseReads.records++
      checkRead()
      return { records: [record], data_version: record.versions.amount!, complete: true }
    },
    write: async (_tableID, changes) => {
      try {
        if (blockNextWrite || readStatus === 403) {
          blockNextWrite = false
          await new Promise<void>(resolve => {
            releaseDeniedWrite = resolve
          })
        }
        checkRead()
        if (failPendingWrite) {
          readStatus = 503
          throw new Error('Fixture write failure')
        }
        sent = changes
        const update = changes.updates?.[0]
        if (update?.expected_versions.amount !== record.versions.amount) throw new Error('Edit conflict')
        record = {
          ...record,
          data: { ...record.data, ...update?.data },
          versions: { amount: record.versions.amount! + 1 }
        }
        return { records: [record], deleted_ids: [], data_version: record.versions.amount! }
      } finally {
        await client.invalidateQueries({ queryKey: runtime.base.key('table') })
      }
    },
    subscribe: (_id, listener) => {
      tables.add(listener)
      if (tableRevoked) listener({ access_revoked: true })
      return () => {
        tables.delete(listener)
      }
    }
  },
  pod: {
    request: async () => {
      throw new Error('No Pod API requests in this boundary fixture')
    }
  },
  channel: () => {
    opens++
    return {
      presence: () => [],
      subscribe: () => () => {},
      broadcast: async () => {},
      on: (event, listener) => {
        const set = events.get(event) ?? new Set()
        set.add(listener)
        events.set(event, set)
        return () => {
          set.delete(listener)
        }
      },
      close: () => {
        closes++
      }
    }
  }
}
function RouteChecks() {
  const runtime = usePod()
  const [enabled, setEnabled] = useState(false)
  const [id, setId] = useState('a/b 中文')
  const [success, setSuccess] = useState(0)
  const result = useRoute<{ value: number }, InternalAPIError, number>('GET /orders/:id', {
    params: { id },
    query: { tag: ['one', 'two'] },
    enabled,
    select: value => value.value,
    staleTime: Infinity
  })
  const save = useRouteMutation<{ value: number }>('POST /orders/:id', {
    onSuccess: () => setSuccess(value => value + 1),
    retry: false
  })
  return (
    <section>
      <output data-route-result>{readState(result)}</output>
      <output data-route-value>{result.data ?? ''}</output>
      <output data-route-error>{result.error?.status ?? ''}</output>
      <output data-route-success>{success}</output>
      <output data-route-pending>{result.isFetching ? 'pending' : ''}</output>
      <button onClick={() => setEnabled(true)}>Enable route</button>
      <button onClick={() => setId('next')}>Change route parameter</button>
      <button
        onClick={() => save.mutate({ params: { id }, query: { tag: ['one', 'two'] }, body: { note: 'Keep draft' } })}>
        Save route
      </button>
      <button onClick={() => void runtime.queryClient.invalidateQueries({ queryKey: runtime.routes.key() })}>
        Refresh routes
      </button>
    </section>
  )
}
function App() {
  const [crashed, setCrashed] = useState(false)
  const rows = useRecords('table')
  const aggregate = useAggregate('table', { metrics: [{ operation: 'count', alias: 'count' }] })
  const room = useChannel('room')
  const [edit, setEdit] = useState<BaseRecord>()
  const [readSnapshot, setReadSnapshot] = useState<RecordsResult>()
  const [received, setReceived] = useState(0)
  // Intentionally register before the channel effect creates its handle.
  const [off] = useState(() => room.on('message', () => setReceived(value => value + 1)))
  useEffect(() => off, [off])
  if (crashed) throw new Error('Fixture render failure')
  return (
    <section>
      <button onClick={() => setCrashed(true)}>Crash render</button>
      <RouteChecks />
      <output data-read-result>{readState(rows)}</output>
      <output data-aggregate-result>{readState(aggregate)}</output>
      <output data-read-identity>{readSnapshot === rows.data ? 'stable' : 'changed'}</output>
      <button onClick={() => setReadSnapshot(rows.data)}>Capture read result</button>
      <p data-current>{String(rows.data?.records[0]?.data.amount ?? '')}</p>
      <p data-aggregate>{String(aggregate.data?.groups[0]?.metrics.count ?? '')}</p>
      <p data-read-error>{rows.error instanceof InternalAPIError ? rows.error.status : ''}</p>
      <p data-aggregate-error>{aggregate.error instanceof InternalAPIError ? aggregate.error.status : ''}</p>
      <p data-received>{received}</p>
      <p data-write-pending>{rows.write.isPending ? 'pending' : ''}</p>
      <button
        disabled={!rows.data}
        onClick={() => {
          const current = rows.data?.records[0]
          if (current) setEdit(current)
        }}>
        Start edit
      </button>
      <button
        onClick={() => {
          record = { ...record, data: { amount: 42 }, versions: { amount: 2 } }
          tableChanged({ data_version: 2, changed_ids: [record.id] })
        }}>
        Other client writes
      </button>
      <button
        disabled={!edit}
        onClick={() => {
          if (edit) void rows.update(edit.id, { amount: 9 }, expectedVersions(edit, { amount: 9 })).catch(() => {})
        }}>
        Save original edit
      </button>
      {rows.write.error && <p role="alert">{rows.write.error.message}</p>}
    </section>
  )
}
const provider = defineApplet(App)
const controls = document.createElement('div')
controls.innerHTML =
  '<button data-emit>Emit fixture event</button><button data-unmount>Unmount SDK</button><button data-remount>Remount SDK</button><button data-reload hidden>Reload applet</button><output data-lifecycle></output><output data-request></output><output data-confirmed></output>'
document.body.append(controls)
const reloadApplet = controls.querySelector<HTMLButtonElement>('[data-reload]')!
const fixtureHost = window as Window & {
  __ANKOLE_APPLET_HOST__?: { error(frame: Window, error: unknown): void }
}
fixtureHost.__ANKOLE_APPLET_HOST__ = {
  error() {
    reloadApplet.hidden = false
  }
}
reloadApplet.addEventListener('click', () => {
  provider.destroy({ dom: host })
  reloadApplet.hidden = true
  provider.render({ dom: host, props: { runtime } })
})
provider.render({ dom: host, props: { runtime } })
for (const status of [200, 401, 403, 404, 503]) {
  const button = document.createElement('button')
  button.textContent = `Read status ${status}`
  button.addEventListener('click', () => {
    readStatus = status
    // No access_revoked event: this exercises an authoritative HTTP read independently of the live channel.
    void client.invalidateQueries({ queryKey: runtime.base.key('table') })
  })
  controls.append(button)
}
for (const status of [200, 401, 403, 404, 503]) {
  const button = document.createElement('button')
  button.textContent = `Route status ${status}`
  button.addEventListener('click', () => {
    routeStatus = status
    void client.invalidateQueries({ queryKey: runtime.routes.key() })
  })
  controls.append(button)
}
const hold = document.createElement('button')
hold.textContent = 'Hold route request'
hold.addEventListener('click', () => {
  holdRoute = true
  void client.invalidateQueries({ queryKey: runtime.routes.key() })
})
controls.append(hold)
const recoverWithoutRefetch = document.createElement('button')
recoverWithoutRefetch.textContent = 'Recover reads without refetch'
recoverWithoutRefetch.addEventListener('click', () => {
  readStatus = routeStatus = 200
})
controls.append(recoverWithoutRefetch)
const failRetry = document.createElement('button')
failRetry.textContent = 'Make retry unavailable'
failRetry.addEventListener('click', () => {
  readStatus = routeStatus = 503
})
controls.append(failRetry)
const manualWrite = document.createElement('button')
manualWrite.textContent = 'Write manual cache data'
manualWrite.addEventListener('click', () => {
  for (const query of client.getQueryCache().getAll()) {
    if (query.queryKey.includes('records')) {
      client.setQueryData(query.queryKey, {
        records: [{ ...record, data: { amount: 99 } }],
        data_version: 99,
        complete: true
      })
    }
    if (query.queryKey.includes('aggregate')) {
      client.setQueryData(query.queryKey, {
        groups: [{ values: [], metrics: { count: 99 } }],
        data_version: 99
      })
    }
    if (query.queryKey.includes('GET /orders/:id')) client.setQueryData(query.queryKey, { value: 99 })
  }
})
controls.append(manualWrite)
const cacheReadReport = document.createElement('output')
cacheReadReport.dataset.cacheReadStates = ''
controls.append(cacheReadReport)
const baseReadReport = document.createElement('output')
baseReadReport.dataset.baseReads = ''
controls.append(baseReadReport)
const revokeTable = document.createElement('button')
revokeTable.textContent = 'Revoke table access'
revokeTable.addEventListener('click', () => {
  readStatus = 403
  tableRevoked = true
  tableChanged({ access_revoked: true })
})
controls.append(revokeTable)
const restoreTable = document.createElement('button')
restoreTable.textContent = 'Restore table access'
restoreTable.addEventListener('click', () => {
  readStatus = 200
  tableRevoked = false
})
controls.append(restoreTable)
const routeReport = document.createElement('output')
routeReport.dataset.routeReport = ''
controls.append(routeReport)
const release = document.createElement('button')
release.textContent = 'Release denied write'
release.addEventListener('click', () => releaseDeniedWrite?.())
controls.append(release)
const block = document.createElement('button')
block.textContent = 'Block next write'
block.addEventListener('click', () => {
  blockNextWrite = true
})
controls.append(block)
const fail = document.createElement('button')
fail.textContent = 'Fail pending write and reads'
fail.addEventListener('click', () => {
  failPendingWrite = true
  releaseDeniedWrite?.()
})
controls.append(fail)
const report = () => {
  baseReadReport.textContent = JSON.stringify(baseReads)
  controls.querySelector('[data-lifecycle]')!.textContent = JSON.stringify({
    opens,
    closes,
    listeners: [...events.values()].reduce((total, set) => total + set.size, 0),
    nodes: host.childElementCount
  })
  controls.querySelector('[data-request]')!.textContent = JSON.stringify(sent)
  const confirmed = client.getQueriesData<RecordsResult>({
    queryKey: [...runtime.base.key('table'), 'records']
  })[0]?.[1]
  controls.querySelector('[data-confirmed]')!.textContent = String(confirmed?.records[0]?.data.amount ?? '')
  routeReport.textContent = JSON.stringify({ calls: routeCalls, aborted: routeAborted })
  cacheReadReport.textContent = JSON.stringify(
    Object.fromEntries(
      [
        ['records', 'records'],
        ['aggregate', 'aggregate'],
        ['route', 'GET /orders/:id']
      ].map(([name, key]) => {
        const state = client
          .getQueryCache()
          .getAll()
          .find(query => query.queryKey.includes(key))?.state
        return [
          name,
          state
            ? {
                error: errorStatus(state.error),
                failureReason: errorStatus(state.fetchFailureReason),
                status: state.status,
                data: state.data !== undefined,
                failures: state.fetchFailureCount,
                fetchStatus: state.fetchStatus
              }
            : null
        ]
      })
    )
  )
}
controls.querySelector('[data-emit]')!.addEventListener('click', () => {
  for (const listener of events.get('message') ?? []) listener({})
  report()
})
controls.querySelector('[data-unmount]')!.addEventListener('click', () => {
  provider.destroy({ dom: host })
  report()
})
controls.querySelector('[data-remount]')!.addEventListener('click', () => {
  provider.render({ dom: host, props: { runtime } })
  report()
})
setInterval(report, 50)
