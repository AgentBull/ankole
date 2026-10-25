import { describe, expect, spyOn, test } from 'bun:test'
import { QueryClient, QueryObserver } from '@tanstack/react-query'
import type { DatabaseRecord, RecordsResult, TableEvent, TableSchema } from '@ankole/applet-sdk/types'
import { createDatabaseAPI, databaseHTTP } from '../database-api'
import { InternalAPIError } from '../../common/internal-api-client'
import { RealtimeRequestError, type PodRealtime, type TopicHandle } from '../realtime'

const tableID = 'table'
const turn = () => new Promise<void>(resolve => setTimeout(resolve, 0))

function record(id: string, value: string): DatabaseRecord {
  return {
    id,
    data: { name: value },
    versions: { name: 1 },
    created_at: '2026-10-18T00:00:00.000000Z',
    updated_at: '2026-10-18T00:00:00.000000Z',
    created_by: 'person',
    updated_by: 'person'
  }
}

function records(rows: DatabaseRecord[], version: number, complete = true): RecordsResult {
  return { records: rows, data_version: version, complete, page_token: complete ? null : 'next-page' }
}

function schema(version: number, count: number, mode: TableSchema['mode'] = 'local'): TableSchema {
  return {
    table: { id: tableID, page_id: 'database', name: 'Tasks', record_count: count, data_version: version },
    fields: [{ id: 'name', name: 'Name', type: 'text', config: {}, version: 1, is_primary: true }],
    views: [],
    mode
  }
}

class RealtimeBoundary {
  readonly ready = Promise.withResolvers<unknown>()
  readonly listeners = new Map<string, Set<(event: TableEvent) => void>>()
  readonly versions = new Set<(version: number | undefined) => void>()
  readonly handle: TopicHandle = {
    ready: this.ready.promise,
    push: async () => {
      throw new Error('These tests do not send channel commands')
    },
    on: (name, callback) => {
      const callbacks = this.listeners.get(name) ?? new Set()
      callbacks.add(callback)
      this.listeners.set(name, callbacks)
      return () => {
        callbacks.delete(callback)
      }
    },
    close: () => {
      this.listeners.clear()
    }
  }

  constructor(manualReady: boolean) {
    if (!manualReady) this.ready.resolve({})
  }

  join = async () => this.handle
  watchVersion = (_kind: string, _id: string, callback: (version: number | undefined) => void) => {
    this.versions.add(callback)
    return () => {
      this.versions.delete(callback)
    }
  }

  version(version: number | undefined) {
    for (const callback of this.versions) callback(version)
  }

  emit(name: string, event: TableEvent = {}) {
    for (const callback of this.listeners.get(name) ?? []) callback(event)
  }
}

function fixture(manualReady = false) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: Infinity } }
  })
  const realtime = new RealtimeBoundary(manualReady)
  const api = createDatabaseAPI(client, realtime as unknown as PodRealtime)
  const schemaSpy = spyOn(databaseHTTP, 'schema')
  const querySpy = spyOn(databaseHTTP, 'query')
  const notifications: TableEvent[] = []
  const waiting = new Set<{ version: number; resolve(event: TableEvent): void }>()
  let unsubscribe: (() => void) | undefined
  return {
    client,
    realtime,
    api,
    schemaSpy,
    querySpy,
    notifications,
    snapshot: () => client.getQueryData<RecordsResult>([...api.key(tableID), 'snapshot']),
    async subscribe() {
      unsubscribe = api.subscribe(tableID, event => {
        notifications.push(event)
        for (const waiter of waiting) {
          if (event.data_version === waiter.version) {
            waiting.delete(waiter)
            waiter.resolve(event)
          }
        }
      })
      await turn()
    },
    notified(version: number) {
      const previous = notifications.find(event => event.data_version === version)
      if (previous) return Promise.resolve(previous)
      return new Promise<TableEvent>(resolve => waiting.add({ version, resolve }))
    },
    unsubscribe() {
      unsubscribe?.()
      unsubscribe = undefined
    },
    dispose() {
      unsubscribe?.()
      client.clear()
      schemaSpy.mockRestore()
      querySpy.mockRestore()
    }
  }
}

describe('Database cache reconciliation', () => {
  for (const event of ['changed', 'schema_changed', 'version'] as const) {
    test(`one ${event} refreshes each active table read once with multiple subscribers`, async () => {
      const context = fixture()
      const aggregate = spyOn(databaseHTTP, 'aggregate')
      let version = 1
      context.schemaSpy.mockImplementation(async () => schema(version, 1, 'remote'))
      context.querySpy.mockImplementation(async () => records([record('a', `Value ${version}`)], version))
      aggregate.mockImplementation(async () => ({
        groups: [{ values: [], metrics: { count: version } }],
        data_version: version
      }))
      const recordsQuery = {
        queryKey: [...context.api.key(tableID), 'records', {}],
        queryFn: () => context.api.records(tableID, {})
      }
      const aggregateQuery = {
        queryKey: [...context.api.key(tableID), 'aggregate', {}],
        queryFn: () => context.api.aggregate(tableID, { metrics: [{ operation: 'count' as const, alias: 'count' }] })
      }
      const stop: (() => void)[] = []
      try {
        await context.subscribe()
        await Promise.all([context.client.fetchQuery(recordsQuery), context.client.fetchQuery(aggregateQuery)])
        // Separate SDK hooks share the records query and each keep a table subscription.
        for (let index = 0; index < 2; index++) {
          stop.push(new QueryObserver(context.client, recordsQuery).subscribe(() => {}))
          stop.push(context.api.subscribe(tableID, () => {}))
        }
        stop.push(new QueryObserver(context.client, aggregateQuery).subscribe(() => {}))
        stop.push(context.api.subscribe(tableID, () => {}))
        stop.push(
          new QueryObserver(context.client, {
            queryKey: [...context.api.key(tableID), 'schema'],
            queryFn: () => databaseHTTP.schema(tableID)
          }).subscribe(() => {})
        )
        context.schemaSpy.mockClear()
        context.querySpy.mockClear()
        aggregate.mockClear()
        version = 2
        if (event === 'version') context.realtime.version(version)
        else context.realtime.emit(event, { data_version: version, changed_ids: ['a'] })
        await context.notified(version)
        await turn()
        if (event !== 'version') expect(context.schemaSpy).toHaveBeenCalledTimes(1)
        expect(
          context.client.getQueryData<TableSchema>([...context.api.key(tableID), 'schema'])?.table.data_version
        ).toBe(version)
        expect(context.querySpy).toHaveBeenCalledTimes(1)
        expect(aggregate).toHaveBeenCalledTimes(1)
        expect(context.client.getQueryData<RecordsResult>(recordsQuery.queryKey)?.data_version).toBe(version)
        expect(context.client.getQueryData(aggregateQuery.queryKey)).toMatchObject({ data_version: version })
      } finally {
        for (const close of stop) close()
        aggregate.mockRestore()
        context.dispose()
      }
    })
  }

  test('active reads reuse one reconciled local snapshot across table subscribers', async () => {
    const context = fixture()
    const aggregate = spyOn(databaseHTTP, 'aggregate')
    let version = 1
    context.schemaSpy.mockImplementation(async () => ({ ...schema(version, 1), limits: { group_count: 1000 } }))
    context.querySpy.mockImplementation(async () => records([record('a', `Value ${version}`)], version))
    const query = {
      queryKey: [...context.api.key(tableID), 'records', {}],
      queryFn: () => context.api.records(tableID, {})
    }
    const stop: (() => void)[] = []
    try {
      await context.subscribe()
      await context.client.fetchQuery(query)
      for (let index = 0; index < 2; index++) {
        stop.push(new QueryObserver(context.client, query).subscribe(() => {}))
        stop.push(context.api.subscribe(tableID, () => {}))
      }
      stop.push(
        new QueryObserver(context.client, {
          queryKey: [...context.api.key(tableID), 'aggregate', {}],
          queryFn: () => context.api.aggregate(tableID, { metrics: [{ operation: 'count' as const, alias: 'count' }] })
        }).subscribe(() => {})
      )
      await turn()
      version = 2
      context.realtime.emit('changed', { data_version: version, changed_ids: ['a'] })
      await context.notified(version)
      await turn()
      expect(context.querySpy.mock.calls.map(([, query]) => query)).toEqual([{ local: true }, { ids: ['a'] }])
      expect(aggregate).not.toHaveBeenCalled()
      expect(context.client.getQueryData<RecordsResult>(query.queryKey)?.records[0]?.data.name).toBe('Value 2')
    } finally {
      for (const close of stop) close()
      aggregate.mockRestore()
      context.dispose()
    }
  })

  test('revocation evicts table reads without refetching, and a fresh subscription can read again', async () => {
    const context = fixture()
    const join = spyOn(context.realtime, 'join')
    const notifications: TableEvent[][] = [[], []]
    const stop: (() => void)[] = []
    context.schemaSpy.mockResolvedValue(schema(1, 1, 'remote'))
    context.querySpy.mockResolvedValue(records([record('a', 'Visible')], 1))
    const query = {
      queryKey: [...context.api.key(tableID), 'records', {}],
      queryFn: () => context.api.records(tableID, {})
    }
    try {
      await context.subscribe()
      await context.client.fetchQuery(query)
      for (const events of notifications) {
        stop.push(new QueryObserver(context.client, query).subscribe(() => {}))
        stop.push(context.api.subscribe(tableID, event => events.push(event)))
      }
      context.querySpy.mockClear()
      context.realtime.emit('access_revoked')
      await turn()
      expect(context.client.getQueriesData({ queryKey: context.api.key(tableID) })).toEqual([])
      expect(context.querySpy).not.toHaveBeenCalled()
      expect(notifications).toEqual([[{ access_revoked: true }], [{ access_revoked: true }]])
      for (const close of stop.splice(0)) close()
      context.unsubscribe()
      await context.subscribe()
      expect(join).toHaveBeenCalledTimes(2)
      expect((await context.client.fetchQuery(query)).records[0]?.data.name).toBe('Visible')
      expect(context.querySpy).toHaveBeenCalledTimes(1)
    } finally {
      for (const close of stop) close()
      join.mockRestore()
      context.dispose()
    }
  })

  for (const succeeds of [true, false]) {
    test(`the adapter refreshes cached reads after a ${succeeds ? 'successful' : 'failed'} write`, async () => {
      const context = fixture()
      const write = spyOn(databaseHTTP, 'write')
      context.schemaSpy.mockResolvedValue(schema(1, 1, 'remote'))
      context.querySpy.mockResolvedValue(records([record('a', 'Confirmed')], 1))
      const query = {
        queryKey: [...context.api.key(tableID), 'records', {}],
        queryFn: () => context.api.records(tableID, {})
      }
      const stop = new QueryObserver(context.client, query).subscribe(() => {})
      const error = new Error('Edit conflict')
      if (succeeds) write.mockResolvedValue({ records: [], deleted_ids: [], data_version: 2 })
      else write.mockRejectedValue(error)
      try {
        await context.client.fetchQuery(query)
        context.querySpy.mockClear()
        const result = context.api.write(tableID, { updates: [] })
        if (succeeds) await expect(result).resolves.toMatchObject({ data_version: 2 })
        else await expect(result).rejects.toBe(error)
        expect(context.querySpy).toHaveBeenCalledTimes(1)
      } finally {
        stop()
        write.mockRestore()
        context.dispose()
      }
    })
  }

  test('a paginated changed-ID response never removes the remaining changed rows', async () => {
    const context = fixture()
    const before = Array.from({ length: 301 }, (_, i) => record(String(i).padStart(3, '0'), 'before'))
    const after = before.map(row => record(row.id, 'after'))
    let version = 1
    context.schemaSpy.mockImplementation(async () => schema(version, before.length))
    context.querySpy.mockImplementation(async (_id, query) =>
      query.local ? records(version === 1 ? before : after, version) : records(after.slice(0, 200), 2, false)
    )
    try {
      await context.subscribe()
      expect((await context.api.records(tableID, {})).records).toHaveLength(301)
      version = 2
      context.realtime.emit('changed', { data_version: 2, changed_ids: after.map(row => row.id) })
      await context.notified(2)
      const result = await context.api.records(tableID, {})
      expect(result.records).toHaveLength(301)
      expect(result.records.every(row => row.data.name === 'after')).toBe(true)
      expect(result.data_version).toBe(2)
      expect(context.querySpy.mock.calls.filter(([, query]) => query.local)).toHaveLength(2)
    } finally {
      context.dispose()
    }
  })

  test('a late v2 response cannot replace a complete v3 snapshot', async () => {
    const context = fixture()
    const pending = Promise.withResolvers<RecordsResult>()
    const started = Promise.withResolvers<void>()
    let version = 1
    context.schemaSpy.mockImplementation(async () => schema(version, 2))
    context.querySpy.mockImplementation(async (_id, query) => {
      if (query.ids) {
        started.resolve()
        return pending.promise
      }
      return records([record('a', version === 1 ? 'a1' : 'a2'), record('b', version === 1 ? 'b1' : 'b3')], version)
    })
    try {
      await context.subscribe()
      await context.api.records(tableID, {})
      version = 2
      context.realtime.emit('changed', { data_version: 2, changed_ids: ['a'] })
      await started.promise
      version = 3
      context.realtime.emit('changed', { data_version: 3, changed_ids: ['b'] })
      await context.notified(3)
      expect((await context.api.records(tableID, {})).data_version).toBe(3)
      pending.resolve(records([record('a', 'a2')], 2))
      await turn()
      expect(context.snapshot()?.data_version).toBe(3)
      expect(context.snapshot()?.records.find(row => row.id === 'b')?.data.name).toBe('b3')
    } finally {
      pending.resolve(records([record('a', 'a2')], 2))
      context.dispose()
    }
  })

  test('a large changed value crossing the local byte threshold lets the server decide the next read', async () => {
    const context = fixture()
    const before = record('a', 'small')
    const after = record('a', '大'.repeat(1000))
    const localBytes = new TextEncoder().encode(JSON.stringify([before])).byteLength + 50
    let version = 1
    context.schemaSpy.mockImplementation(async () => ({
      ...schema(version, 1),
      limits: { group_count: 1000, local_bytes: localBytes }
    }))
    context.querySpy.mockImplementation(async (_id, query) => {
      if (query.ids) return records([after], 2)
      if (query.local) {
        if (version === 2) throw new InternalAPIError(409, 'Conflict', { error: { code: 'local_table_changed' } })
        return records([before], 1)
      }
      return records([after], 2)
    })
    try {
      await context.subscribe()
      expect((await context.api.records(tableID, {})).records[0]?.data.name).toBe('small')
      version = 2
      context.realtime.emit('changed', { data_version: 2, changed_ids: ['a'] })
      await context.notified(2)
      expect(context.snapshot()?.data_version).toBe(1)
      expect((await context.api.records(tableID, {})).records[0]?.data.name).toBe(after.data.name)
      await context.api.records(tableID, {})
      expect(context.querySpy.mock.calls.filter(([, query]) => query.local)).toHaveLength(2)
      expect(context.querySpy.mock.calls.filter(([, query]) => !query.local && !query.ids)).toHaveLength(2)
    } finally {
      context.dispose()
    }
  })

  test('crossing the local-table threshold switches the next read to server paging', async () => {
    const context = fixture()
    const initial = Array.from({ length: 5000 }, (_, i) => record(String(i).padStart(5, '0'), 'before'))
    const added = record('99999', 'added')
    let version = 1
    context.schemaSpy.mockImplementation(async () =>
      schema(version, version === 1 ? 5000 : 5001, version === 1 ? 'local' : 'remote')
    )
    context.querySpy.mockImplementation(async (_id, query) => {
      if (query.local) return records(initial, 1)
      if (query.ids) return records([added], 2)
      return records([...initial, added].slice(0, 100), 2, false)
    })
    try {
      await context.subscribe()
      expect((await context.api.records(tableID, { page_size: 100 })).records).toHaveLength(5000)
      version = 2
      context.realtime.emit('changed', { data_version: 2, changed_ids: [added.id] })
      await context.notified(2)
      const result = await context.api.records(tableID, { page_size: 100 })
      expect(result.records).toHaveLength(100)
      expect(result.complete).toBe(false)
      expect(result.page_token).toBe('next-page')
      expect(context.schemaSpy.mock.calls.length).toBeGreaterThanOrEqual(2)
      expect(context.querySpy.mock.calls.at(-1)?.[1]).toEqual({ page_size: 100 })
    } finally {
      context.dispose()
    }
  })

  for (const ending of ['unsubscribe', 'access_revoked'] as const) {
    test(`an in-flight response cannot repopulate an evicted snapshot after ${ending}`, async () => {
      const context = fixture()
      const pending = Promise.withResolvers<RecordsResult>()
      const started = Promise.withResolvers<void>()
      let version = 1
      context.schemaSpy.mockImplementation(async () => schema(version, 1))
      context.querySpy.mockImplementation(async (_id, query) => {
        if (query.ids) {
          started.resolve()
          return pending.promise
        }
        return records([record('a', 'before')], 1)
      })
      try {
        await context.subscribe()
        await context.api.records(tableID, {})
        version = 2
        context.realtime.emit('changed', { data_version: 2, changed_ids: ['a'] })
        await started.promise
        if (ending === 'access_revoked') context.realtime.emit('access_revoked')
        else {
          context.unsubscribe()
          context.client.removeQueries({ queryKey: context.api.key(tableID) })
        }
        expect(context.snapshot()).toBeUndefined()
        pending.resolve(records([record('a', 'after')], 2))
        await turn()
        expect(context.snapshot()).toBeUndefined()
      } finally {
        pending.resolve(records([record('a', 'after')], 2))
        context.dispose()
      }
    })
  }

  test('a channel readiness timeout keeps readable cached data and does not revoke access', async () => {
    const context = fixture(true)
    context.schemaSpy.mockResolvedValue(schema(1, 1))
    context.querySpy.mockResolvedValue(records([record('a', 'readable')], 1))
    try {
      await context.subscribe()
      await context.api.records(tableID, {})
      context.realtime.ready.reject(new Error('Connection response timed out'))
      await turn()
      expect(context.notifications.some(event => event.access_revoked)).toBe(false)
      expect(context.snapshot()?.records[0]?.data.name).toBe('readable')
    } finally {
      context.dispose()
    }
  })

  test('an explicit not-found channel rejection removes cached data and revokes access', async () => {
    const context = fixture(true)
    context.schemaSpy.mockResolvedValue(schema(1, 1))
    context.querySpy.mockResolvedValue(records([record('a', 'private')], 1))
    try {
      await context.subscribe()
      await context.api.records(tableID, {})
      context.realtime.ready.reject(new RealtimeRequestError({ reason: 'not_found' }))
      await turn()
      expect(context.notifications.some(event => event.access_revoked)).toBe(true)
      expect(context.snapshot()).toBeUndefined()
    } finally {
      context.dispose()
    }
  })
})

test('a late subscriber receives revocation without reopening the revoked channel', async () => {
  const context = fixture()
  const join = spyOn(context.realtime, 'join')
  const late: TableEvent[] = []
  let unsubscribe: (() => void) | undefined
  try {
    await context.subscribe()
    context.realtime.emit('access_revoked')
    unsubscribe = context.api.subscribe(tableID, event => late.push(event))
    expect(late).toEqual([{ access_revoked: true }])
    expect(join).toHaveBeenCalledTimes(1)
    context.realtime.emit('changed', { data_version: 2 })
    await turn()
    expect(late).toEqual([{ access_revoked: true }])
    unsubscribe()
    unsubscribe = undefined
    context.unsubscribe()
    await context.subscribe()
    expect(join).toHaveBeenCalledTimes(2)
  } finally {
    unsubscribe?.()
    join.mockRestore()
    context.dispose()
  }
})

test('local aggregation obeys the configured group bound through the server owner', async () => {
  const context = fixture()
  const aggregate = spyOn(databaseHTTP, 'aggregate')
  context.schemaSpy.mockResolvedValue({ ...schema(1, 2), limits: { group_count: 1 } })
  context.querySpy.mockResolvedValue(records([record('a', 'Alpha'), record('b', 'Beta')], 1))
  aggregate.mockRejectedValue(new Error('Group limit'))
  try {
    await expect(
      context.api.aggregate(tableID, {
        group_by: [{ field_id: 'name' }],
        metrics: [{ operation: 'count', alias: 'count' }]
      })
    ).rejects.toThrow('Group limit')
    expect(aggregate).toHaveBeenCalledTimes(1)
    expect(context.snapshot()?.records).toHaveLength(2)
  } finally {
    aggregate.mockRestore()
    context.dispose()
  }
})

test('local aggregation can answer within the configured bound without a redundant server query', async () => {
  const context = fixture()
  const aggregate = spyOn(databaseHTTP, 'aggregate')
  context.schemaSpy.mockResolvedValue({ ...schema(1, 2), limits: { group_count: 2 } })
  context.querySpy.mockResolvedValue(records([record('a', 'Alpha'), record('b', 'Beta')], 1))
  try {
    const result = await context.api.aggregate(tableID, {
      group_by: [{ field_id: 'name' }],
      metrics: [{ operation: 'count', alias: 'count' }]
    })
    expect(result.groups).toHaveLength(2)
    expect(aggregate).not.toHaveBeenCalled()
  } finally {
    aggregate.mockRestore()
    context.dispose()
  }
})

test('records and aggregates reuse an oversized-local conclusion until the table version changes', async () => {
  const context = fixture(),
    aggregate = spyOn(databaseHTTP, 'aggregate')
  let version = 1,
    localReads = 0
  context.schemaSpy.mockImplementation(async () => ({ ...schema(version, 1), limits: { group_count: 1000 } }))
  context.querySpy.mockImplementation(async (_id, query) => {
    if (query.local) {
      localReads++
      if (version === 1) throw new InternalAPIError(409, 'Conflict', { error: { code: 'local_table_changed' } })
    }
    return records([record('a', 'Value')], version)
  })
  aggregate.mockResolvedValue({ groups: [{ values: [], metrics: { count: 1 } }], data_version: 1 })
  try {
    await context.api.records(tableID, {})
    await context.api.records(tableID, { sort: [{ field_id: 'name', direction: 'asc' }] })
    await context.api.aggregate(tableID, { metrics: [{ operation: 'count', alias: 'count' }] })
    expect(localReads).toBe(1)
    expect(aggregate).toHaveBeenCalledTimes(1)
    version = 2
    await context.client.invalidateQueries({ queryKey: [...context.api.key(tableID), 'schema'] })
    await context.api.records(tableID, {})
    expect(localReads).toBe(2)
    expect(context.snapshot()?.data_version).toBe(2)
  } finally {
    aggregate.mockRestore()
    context.dispose()
  }
})

describe('versioned local database snapshots', () => {
  test.each(['records', 'aggregate'] as const)(
    '%s rejects a filter deleted between schema and record reads',
    async kind => {
      const context = fixture()
      const aggregate = spyOn(databaseHTTP, 'aggregate')
      const rejected = new InternalAPIError(422, 'Unprocessable Entity', { error: { code: 'unknown_field' } })
      const filter = { conjunction: 'and' as const, conditions: [{ field_id: 'name', operator: 'is_empty' as const }] }
      context.schemaSpy.mockResolvedValue({ ...schema(1, 1), limits: { group_count: 1000 } })
      context.querySpy.mockImplementation(async (_id, query) => {
        if (query.local) return records([{ ...record('a', 'Before deletion'), data: {} }], 2)
        throw rejected
      })
      aggregate.mockRejectedValue(rejected)
      try {
        const result =
          kind === 'records'
            ? context.api.records(tableID, { filter })
            : context.api.aggregate(tableID, { filter, metrics: [{ operation: 'count', alias: 'count' }] })
        await expect(result).rejects.toBe(rejected)
        expect(context.client.getQueryState([...context.api.key(tableID), 'schema'])?.isInvalidated).toBe(true)
        expect(context.client.getQueryState([...context.api.key(tableID), 'snapshot'])?.isInvalidated).toBe(true)
      } finally {
        aggregate.mockRestore()
        context.dispose()
      }
    }
  )

  test('a cached older snapshot is not evaluated with a newer schema', async () => {
    const context = fixture()
    const current = records([record('b', 'Current')], 2)
    context.schemaSpy.mockResolvedValue(schema(2, 1))
    context.client.setQueryData([...context.api.key(tableID), 'snapshot'], records([record('a', 'Old')], 1))
    context.querySpy.mockResolvedValue(current)
    try {
      expect(await context.api.records(tableID, {})).toEqual(current)
      expect(context.querySpy).toHaveBeenCalledTimes(1)
      expect(context.querySpy).toHaveBeenCalledWith(tableID, {})
      expect(context.client.getQueryState([...context.api.key(tableID), 'snapshot'])?.isInvalidated).toBe(true)
    } finally {
      context.dispose()
    }
  })
})
