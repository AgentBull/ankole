import { expect, test } from 'bun:test'
import { QueryClient, QueryObserver } from '@tanstack/react-query'
import { followAggregateTables } from '../src/aggregate-tables'
import type { AggregateResult, BaseAPI, TableEvent } from '../src/types'

const turn = () => new Promise<void>(resolve => setTimeout(resolve, 0))

function fixture(results: AggregateResult[], queryKeyHashFn?: (queryKey: readonly unknown[]) => string) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity, queryKeyHashFn } } })
  const listeners = new Map<string, Set<(event: TableEvent) => void>>()
  const unused = async () => {
    throw new Error('This fixture exercises aggregate subscriptions')
  }
  let reads = 0
  const base: BaseAPI = {
    key: tableID => ['table', tableID],
    schema: unused,
    records: unused,
    write: unused,
    aggregate: async () => results[Math.min(reads++, results.length - 1)]!,
    subscribe(tableID, callback) {
      const callbacks = listeners.get(tableID) ?? new Set()
      callbacks.add(callback)
      listeners.set(tableID, callbacks)
      return () => {
        callbacks.delete(callback)
        if (!callbacks.size) listeners.delete(tableID)
      }
    }
  }
  const query = { metrics: [{ operation: 'sum' as const, field_id: 'amount', alias: 'total' }] }
  const queryKey = [...base.key('orders'), 'aggregate', query]
  const observer = new QueryObserver(client, { queryKey, queryFn: () => base.aggregate('orders', query) })
  return {
    client,
    queryKey,
    listeners,
    reads: () => reads,
    emit: (tableID: string, event: TableEvent) => listeners.get(tableID)?.forEach(callback => callback(event)),
    observe: () => observer.subscribe(() => {}),
    follow: () => followAggregateTables(base, client, 'orders', queryKey)
  }
}

const crossTable = (items: number): AggregateResult => ({
  groups: [],
  data_version: 4,
  data_versions: { orders: 4, items }
})

test('an edit on a child table refetches the aggregate that read it', async () => {
  const context = fixture([crossTable(7), crossTable(8)])
  const stopObserving = context.observe()
  const stop = context.follow()
  try {
    await turn()
    expect(context.reads()).toBe(1)
    // The caller owns the queried table's subscription; the follower watches only the other tables it read.
    expect([...context.listeners.keys()]).toEqual(['items'])
    context.emit('items', { data_version: 7 })
    await turn()
    expect(context.reads()).toBe(1)
    context.emit('items', { data_version: 8, changed_ids: ['item-1'] })
    await turn()
    expect(context.reads()).toBe(2)
    expect(context.client.getQueryData<AggregateResult>(context.queryKey)?.data_versions?.items).toBe(8)
  } finally {
    stop()
    stopObserving()
    context.client.clear()
  }
})

test('the follower drops a table that leaves the dependency set and every table when it stops', async () => {
  const context = fixture([crossTable(7), { groups: [], data_version: 5, data_versions: { orders: 5 } }])
  const stopObserving = context.observe()
  const stop = context.follow()
  try {
    await turn()
    expect([...context.listeners.keys()]).toEqual(['items'])
    context.emit('items', { resync: true })
    await turn()
    expect(context.reads()).toBe(2)
    expect(context.listeners.size).toBe(0)
  } finally {
    stop()
    stopObserving()
    context.client.clear()
  }

  const remaining = fixture([crossTable(7)])
  const stopRemaining = remaining.observe()
  const follow = remaining.follow()
  await turn()
  expect(remaining.listeners.has('items')).toBe(true)
  follow()
  expect(remaining.listeners.size).toBe(0)
  stopRemaining()
  remaining.client.clear()
})

test('a single-table aggregate subscribes to no other table', async () => {
  const context = fixture([{ groups: [], data_version: 1 }])
  const stopObserving = context.observe()
  const stop = context.follow()
  try {
    await turn()
    expect(context.reads()).toBe(1)
    expect(context.listeners.size).toBe(0)
  } finally {
    stop()
    stopObserving()
    context.client.clear()
  }
})

test('the follower finds its aggregate however the cache hashes the query key', async () => {
  // A host page cache cannot sort the keys of an object from an Applet frame, so its hash differs from hashKey.
  const context = fixture([crossTable(7), crossTable(8)], queryKey => JSON.stringify(queryKey))
  const stopObserving = context.observe()
  const stop = context.follow()
  try {
    await turn()
    expect([...context.listeners.keys()]).toEqual(['items'])
    context.emit('items', { data_version: 8 })
    await turn()
    expect(context.reads()).toBe(2)
  } finally {
    stop()
    stopObserving()
    context.client.clear()
  }
})
