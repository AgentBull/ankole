import { expect, test } from 'bun:test'
import { createElement, useState } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { boundTable } from '../src/bindings'
import { AppletRuntimeProvider, useTable } from '../src/index'
import type { AppletRuntime, BaseRecord, RecordWrite } from '../src/types'

test('logical edits use physical field IDs and versions from the captured edit snapshot', async () => {
  const writes: RecordWrite[] = []
  const table = boundTable(
    'orders',
    { tableId: 'table-b', fields: { amount: 'b-amount', status: 'b-status' }, status: 'ready', missing: [] },
    async changes => {
      writes.push(changes)
      return { records: [], deleted_ids: [], data_version: 9 }
    }
  )
  const captured: BaseRecord = {
    id: 'row',
    data: { 'b-amount': 10 },
    versions: { 'b-amount': 3, 'b-status': 8 },
    created_at: '',
    updated_at: '',
    created_by: 'owner',
    updated_by: 'owner'
  }
  expect(table.read(captured)).toEqual({ amount: 10 })
  await table.update(captured, { amount: 20 })
  expect(writes).toEqual([{ updates: [{ id: 'row', data: { 'b-amount': 20 }, expected_versions: { 'b-amount': 3 } }] }])
  expect(() => table.patch({ unknown: 1 })).toThrow('Unconfigured Applet binding: orders.unknown')
  await table.remove(captured)
  expect(writes[1]).toEqual({ deletes: [{ id: 'row', expected_versions: { 'b-amount': 3, 'b-status': 8 } }] })
})

test('unconfigured slots expose their status and cannot write an empty or stale table ID', () => {
  let writes = 0
  const table = boundTable(
    'orders',
    { tableId: 'table-b', fields: { amount: null }, status: 'missing_fields', missing: ['amount'] },
    async () => {
      writes++
      return { records: [], deleted_ids: [], data_version: 0 }
    }
  )
  expect(table.configured).toBe(false)
  expect(table.status).toBe('missing_fields')
  expect(() => table.create({ amount: 1 })).toThrow('Unconfigured Applet binding')
  expect(writes).toBe(0)
})

test('a retained useTable helper captured before rebinding still writes to its original table ID', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const calls: Array<{ tableID: string; changes: RecordWrite }> = []
  const unused = async () => {
    throw new Error('Unused in useTable rebind test')
  }
  const runtime: AppletRuntime = {
    pageID: 'applet-rebind',
    title: 'Orders',
    embedded: false,
    instanceID: 'inst-rebind',
    actions: ['node_view', 'node_contribute'],
    revision: 1,
    bindings: {
      orders: {
        tableId: 'table-a',
        fields: { amount: 'a-amount' },
        status: 'ready',
        missing: [],
        description: null
      }
    },
    queryClient: client,
    readDenial: () => undefined,
    routes: { key: () => ['routes'], call: unused },
    runs: { key: id => ['run', id], get: unused, subscribe: () => () => {} },
    base: {
      key: id => ['base', id],
      schema: unused,
      records: unused,
      aggregate: unused,
      write: async (tableID, changes) => {
        calls.push({ tableID, changes })
        return { records: [], deleted_ids: [], data_version: calls.length }
      },
      subscribe: () => () => {}
    },
    pod: {
      request: unused,
      fileURL: () => '',
      navigateToPage() {},
      openChat() {},
      principals: async () => []
    },
    theme: 'light',
    channel() {
      throw new Error('Unused in useTable rebind test')
    }
  }

  let retainedBeforeRebind: ReturnType<typeof useTable> | undefined
  let latestAfterRebind: ReturnType<typeof useTable> | undefined

  function Probe() {
    const [rebound, setRebound] = useState(false)
    const orders = useTable('orders')
    if (!rebound) {
      retainedBeforeRebind = orders
      runtime.bindings = {
        orders: {
          tableId: 'table-b',
          fields: { amount: 'b-amount' },
          status: 'ready',
          missing: [],
          description: 'Rebound orders table'
        }
      }
      setRebound(true)
    } else {
      latestAfterRebind = orders
    }
    return createElement('span', { 'data-table': orders.tableId ?? '' })
  }

  try {
    const html = renderToStaticMarkup(
      createElement(
        QueryClientProvider,
        { client },
        createElement(AppletRuntimeProvider, { runtime, children: createElement(Probe) })
      )
    )
    expect(html).toContain('data-table="table-b"')
    expect(retainedBeforeRebind?.tableId).toBe('table-a')
    expect(latestAfterRebind?.tableId).toBe('table-b')

    const capturedRowA: BaseRecord = {
      id: 'row-a',
      data: { 'a-amount': 15 },
      versions: { 'a-amount': 4 },
      created_at: '',
      updated_at: '',
      created_by: 'owner',
      updated_by: 'owner'
    }
    await retainedBeforeRebind!.update(capturedRowA, { amount: 42 })

    // Retained helper bypasses the rebound mutation observer and targets table-a directly with table-a's field IDs.
    expect(client.getMutationCache().getAll()).toHaveLength(0)
    expect(calls).toEqual([
      {
        tableID: 'table-a',
        changes: { updates: [{ id: 'row-a', data: { 'a-amount': 42 }, expected_versions: { 'a-amount': 4 } }] }
      }
    ])
  } finally {
    client.clear()
  }
})
