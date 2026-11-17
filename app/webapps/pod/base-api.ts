import { t } from 'i18next'
import { withRecordIDs } from '@ankole/applet-sdk/records'
import type { InfiniteData, QueryClient } from '@tanstack/react-query'
import type {
  AggregateQuery,
  AggregateResult,
  BaseAPI,
  BaseField,
  BaseRecord,
  BaseView,
  RecordQuery,
  RecordWrite,
  RecordsResult,
  TableEvent,
  TableSchema,
  WriteResult
} from '@ankole/applet-sdk/types'
import { contentKeys } from './content-api'
import { aggregateLocalRecords, queryLocalRecords } from './state/table-query'
import { isRealtimeAccessDenied, type PodRealtime, type TopicHandle } from './realtime'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode } from '../common/request-errors'
import { canAggregateLocally, canQueryLocally } from './state/local-query'
import { INFINITE_RECORDS_SEGMENT } from './use-infinite-base-records'

import {
  podBaseTables,
  podBaseTableCreate,
  podBaseTableRename,
  podBaseTableConfigure,
  podBaseTableDelete,
  podBaseSchema,
  podBaseQuery,
  podBaseAggregate,
  podBaseWrite,
  podBaseFieldCreate,
  podBaseFieldUpdate,
  podBaseFieldDelete,
  podBaseViewCreate,
  podBaseViewUpdate,
  podBaseViewDelete
} from './api/generated/sdk.gen'

export const baseHTTP = {
  tables: (pageID: string, signal?: AbortSignal) => podBaseTables({ path: { page_id: pageID }, signal }),
  createTable: (pageID: string, name: string) =>
    podBaseTableCreate({ path: { page_id: pageID }, body: { data: { name } } }),
  renameTable: (id: string, name: string) => podBaseTableRename({ path: { id }, body: { data: { name } } }),
  describeTable: (id: string, description: string) =>
    podBaseTableConfigure({ path: { id }, body: { data: { description } } }),
  removeTable: (tableID: string) => podBaseTableDelete({ path: { id: tableID } }),
  schema: (tableID: string, signal?: AbortSignal): Promise<TableSchema> =>
    podBaseSchema({ path: { id: tableID }, signal }),
  query: (tableID: string, body: RecordQuery, signal?: AbortSignal): Promise<RecordsResult> => {
    const { group, groups, ...rest } = body
    const wire = Array.isArray(group)
      ? { ...rest, groups: [...(groups ?? []), ...group] }
      : { ...rest, ...(group ? { group } : {}), ...(groups ? { groups } : {}) }
    return podBaseQuery({ path: { id: tableID }, body: { data: wire }, signal })
  },
  aggregate: (tableID: string, body: AggregateQuery): Promise<AggregateResult> =>
    podBaseAggregate({ path: { id: tableID }, body: { data: body } }),
  write: (tableID: string, body: RecordWrite): Promise<WriteResult> =>
    podBaseWrite({ path: { id: tableID }, body: { data: withRecordIDs(body) } }),
  createField: (tableID: string, body: Partial<BaseField>) =>
    podBaseFieldCreate({ path: { id: tableID }, body: { data: body } }),
  updateField: (fieldID: string, patch: Partial<BaseField> & { clear_invalid?: boolean }, version: number) =>
    podBaseFieldUpdate({ path: { id: fieldID }, body: { data: { ...patch, version } } }),
  removeField: (fieldID: string, version: number) => podBaseFieldDelete({ path: { id: fieldID }, query: { version } }),
  createView: (tableID: string, body: Partial<BaseView>) =>
    podBaseViewCreate({ path: { id: tableID }, body: { data: body } }),
  updateView: (viewID: string, patch: Partial<BaseView>, version: number) =>
    podBaseViewUpdate({ path: { id: viewID }, body: { data: { ...patch, version } } }),
  removeView: (viewID: string, version: number) => podBaseViewDelete({ path: { id: viewID }, query: { version } })
}

const tableKey = (tableID: string) => [...contentKeys.all, 'table', tableID]

type CachedInfiniteRecords = InfiniteData<RecordsResult, string | undefined>

function queryReferencedFields(query: RecordQuery): Set<string> {
  const referenced = new Set<string>()
  for (const condition of query.filter?.conditions ?? []) referenced.add(condition.field_id)
  for (const sort of query.sort ?? []) referenced.add(sort.field_id)
  const slices = [
    ...(Array.isArray(query.group) ? query.group : query.group ? [query.group] : []),
    ...(query.groups ?? [])
  ]
  for (const slice of slices) referenced.add(slice.field_id)
  return referenced
}

function queryUsesVolatileOrderingOrSearch(query: RecordQuery, fields: readonly BaseField[] | undefined): boolean {
  if (query.search && query.search.trim() !== '') return true
  if (!fields) return false
  const byID = new Map(fields.map(field => [field.id, field]))
  for (const fieldID of queryReferencedFields(query)) {
    const field = byID.get(fieldID)
    if (!field) return true
    if (
      field.type === 'formula' ||
      field.type === 'updated_at' ||
      field.type === 'updated_by' ||
      field.config.volatile
    ) {
      return true
    }
  }
  return false
}

function isInfiniteQueryCurrentForEvent(
  querySpec: RecordQuery,
  data: CachedInfiniteRecords | undefined,
  event: TableEvent,
  fields: readonly BaseField[] | undefined
): boolean {
  return (
    !event.schema_changed &&
    !event.resync &&
    event.data_version !== undefined &&
    !queryUsesVolatileOrderingOrSearch(querySpec, fields) &&
    Boolean(data?.pages.length) &&
    data!.pages.every(page => page.data_version >= event.data_version!)
  )
}

export function trimInfiniteRecordQueriesToFirstPage(
  client: QueryClient,
  prefix: readonly unknown[],
  shouldSkip?: (querySpec: RecordQuery, data: CachedInfiniteRecords) => boolean
) {
  for (const entry of client.getQueryCache().findAll({ queryKey: [...prefix, INFINITE_RECORDS_SEGMENT] })) {
    const data = entry.state.data as CachedInfiniteRecords | undefined
    if (data && data.pages.length > 1) {
      const querySpec = (entry.queryKey[prefix.length + 1] ?? {}) as RecordQuery
      if (shouldSkip?.(querySpec, data)) continue
      client.setQueryData<CachedInfiniteRecords>(entry.queryKey, {
        pages: data.pages.slice(0, 1),
        pageParams: data.pageParams.slice(0, 1)
      })
    }
  }
}

export function reconcileInfiniteRecordQueries(
  client: QueryClient,
  prefix: readonly unknown[],
  options: {
    fields?: readonly BaseField[]
    updatedRecords: readonly BaseRecord[]
    deletedIDs: readonly string[]
    dataVersion: number
    forceRefetch?: boolean
    touchedFields?: ReadonlySet<string>
  }
): Set<string> {
  const refetchHashes = new Set<string>()
  const updatedByID = new Map(options.updatedRecords.map(record => [record.id, record]))
  const deletedSet = new Set(options.deletedIDs)

  for (const entry of client.getQueryCache().findAll({ queryKey: [...prefix, INFINITE_RECORDS_SEGMENT] })) {
    const data = entry.state.data as CachedInfiniteRecords | undefined
    if (!data || data.pages.length === 0) {
      refetchHashes.add(entry.queryHash)
      continue
    }
    const querySpec = (entry.queryKey[prefix.length + 1] ?? {}) as RecordQuery
    if (
      !options.forceRefetch &&
      !queryUsesVolatileOrderingOrSearch(querySpec, options.fields) &&
      data.pages.every(page => page.data_version >= options.dataVersion)
    ) {
      continue
    }
    const existingByID = new Map<string, BaseRecord>()
    for (const page of data.pages) {
      for (const record of page.records) existingByID.set(record.id, record)
    }

    const referenced = queryReferencedFields(querySpec)
    let orderOrMembershipChanged =
      Boolean(options.forceRefetch) ||
      data.pages.some(page => page.data_version + 1 !== options.dataVersion) ||
      queryUsesVolatileOrderingOrSearch(querySpec, options.fields)

    if (!orderOrMembershipChanged && options.touchedFields) {
      for (const fieldID of options.touchedFields) {
        if (referenced.has(fieldID)) {
          orderOrMembershipChanged = true
          break
        }
      }
    }

    if (!orderOrMembershipChanged) {
      for (const record of options.updatedRecords) {
        const previous = existingByID.get(record.id)
        if (!previous) {
          orderOrMembershipChanged = true
          break
        }
        for (const fieldID of referenced) {
          if (JSON.stringify(previous.data[fieldID] ?? null) !== JSON.stringify(record.data[fieldID] ?? null)) {
            orderOrMembershipChanged = true
            break
          }
        }
        if (orderOrMembershipChanged) break
      }
    }

    if (orderOrMembershipChanged) {
      if (data.pages.length > 1) {
        client.setQueryData<CachedInfiniteRecords>(entry.queryKey, {
          pages: data.pages.slice(0, 1),
          pageParams: data.pageParams.slice(0, 1)
        })
      }
      refetchHashes.add(entry.queryHash)
      continue
    }

    client.setQueryData<CachedInfiniteRecords>(entry.queryKey, {
      ...data,
      pages: data.pages.map(page => ({
        ...page,
        data_version: options.dataVersion,
        records: page.records
          .filter(record => !deletedSet.has(record.id))
          .map(record => updatedByID.get(record.id) ?? record)
      }))
    })
  }
  return refetchHashes
}

export const baseTablesQuery = (pageID: string) => ({
  queryKey: [...contentKeys.page(pageID), 'tables'],
  queryFn: ({ signal }: { signal: AbortSignal }) => baseHTTP.tables(pageID, signal)
})

export const baseSchemaQuery = (tableID: string) => ({
  queryKey: [...tableKey(tableID), 'schema'],
  queryFn: ({ signal }: { signal: AbortSignal }) => baseHTTP.schema(tableID, signal)
})

/** Start the first table's reads while the page's editor modules load. */
export function prefetchBase(client: QueryClient, pageID: string) {
  return client
    .fetchQuery(baseTablesQuery(pageID))
    .then(({ tables }) => tables[0] && client.prefetchQuery(baseSchemaQuery(tables[0].id)))
    .catch(() => {
      // The mounted queries display failures and provide their retry controls.
    })
}

export function createBaseAPI(client: QueryClient, realtime: PodRealtime): BaseAPI {
  const key = tableKey
  const subscriptions = new Map<
    string,
    {
      callbacks: Set<(event: TableEvent) => void>
      handle?: TopicHandle
      timer?: ReturnType<typeof setTimeout>
      unwatch?: () => void
      change: number
      revoked: boolean
    }
  >()
  const schema = (tableID: string) => client.fetchQuery(baseSchemaQuery(tableID))
  const snapshotKey = (tableID: string) => [...key(tableID), 'snapshot']
  const remoteAtVersion = (tableID: string, version: number) => {
    const snapshot = client.getQueryCache().find({ queryKey: snapshotKey(tableID), exact: true })
    return (
      snapshot?.meta?.data_version === version &&
      snapshot.state.error instanceof InternalAPIError &&
      requestErrorCode(snapshot.state.error.payload) === 'local_table_changed'
    )
  }
  const snapshot = (tableID: string, version: number) =>
    client.fetchQuery({
      queryKey: snapshotKey(tableID),
      meta: { data_version: version },
      queryFn: async ({ signal }) => {
        const result = await baseHTTP.query(tableID, { local: true }, signal)
        if (!result.complete) {
          throw new Error(t('pod.content.this_table_exceeds_the_local_query_limit_reload_its_schema'))
        }
        return result
      }
    })
  const tableChanged = async (tableID: string, error: unknown) => {
    if (
      !(error instanceof InternalAPIError) ||
      error.status !== 409 ||
      requestErrorCode(error.payload) !== 'local_table_changed'
    ) {
      throw error
    }
    // Keep this failed snapshot's query metadata: the same version must not retry a known oversized local read.
    await client.invalidateQueries({ queryKey: [...key(tableID), 'schema'], exact: true })
  }
  const localSnapshot = async (tableID: string, definition: TableSchema) => {
    let all: RecordsResult
    try {
      all = await snapshot(tableID, definition.table.data_version)
    } catch (error) {
      await tableChanged(tableID, error)
      return
    }
    if (all.data_version !== definition.table.data_version) {
      await Promise.all([
        client.invalidateQueries({ queryKey: [...key(tableID), 'schema'], exact: true, refetchType: 'none' }),
        client.invalidateQueries({ queryKey: snapshotKey(tableID), exact: true, refetchType: 'none' })
      ])
      return
    }
    return all
  }
  return {
    key,
    schema,
    async records(tableID, query) {
      const definition = await schema(tableID)
      if (remoteAtVersion(tableID, definition.table.data_version) || !canQueryLocally(definition, query)) {
        return baseHTTP.query(tableID, query)
      }
      const all = await localSnapshot(tableID, definition)
      if (!all) return baseHTTP.query(tableID, query)
      const records = queryLocalRecords(all.records, definition.fields, query)
      return { ...all, records, complete: true, page_token: null }
    },
    async aggregate(tableID, query) {
      const definition = await schema(tableID)
      if (remoteAtVersion(tableID, definition.table.data_version) || !canAggregateLocally(definition, query)) {
        return baseHTTP.aggregate(tableID, query)
      }
      const all = await localSnapshot(tableID, definition)
      if (!all) return baseHTTP.aggregate(tableID, query)
      const result = aggregateLocalRecords(all.records, definition.fields, query, all.data_version, definition.timezone)
      // PostgreSQL owns the configured result bound; use it when the schema cannot establish parity.
      if (definition.limits?.group_count === undefined || result.groups.length > definition.limits.group_count) {
        return baseHTTP.aggregate(tableID, query)
      }
      return result
    },
    async write(tableID, changes) {
      const prefix = key(tableID)
      let result: WriteResult | undefined
      try {
        result = await baseHTTP.write(tableID, changes)
        return result
      } finally {
        const definition = client.getQueryData<TableSchema>([...prefix, 'schema'])
        if (result) {
          if (definition && definition.table.data_version < result.data_version) {
            client.setQueryData<TableSchema>([...prefix, 'schema'], {
              ...definition,
              table: { ...definition.table, data_version: result.data_version }
            })
          }
          const touchedFields = new Set<string>()
          for (const update of changes.updates ?? []) {
            for (const fieldID of Object.keys(update.data)) touchedFields.add(fieldID)
          }
          const forceRefetch = Boolean(changes.creates?.length || changes.upserts?.length)
          const refetchHashes = reconcileInfiniteRecordQueries(client, prefix, {
            fields: definition?.fields,
            updatedRecords: result.records,
            deletedIDs: result.deleted_ids,
            dataVersion: result.data_version,
            forceRefetch,
            touchedFields
          })
          await client.invalidateQueries({
            queryKey: prefix,
            predicate: query =>
              query.queryKey[prefix.length] !== INFINITE_RECORDS_SEGMENT || refetchHashes.has(query.queryHash)
          })
        } else {
          trimInfiniteRecordQueriesToFirstPage(client, prefix)
          await client.invalidateQueries({ queryKey: prefix })
        }
      }
    },
    subscribe(tableID, callback) {
      let entry = subscriptions.get(tableID)
      if (!entry) {
        entry = { callbacks: new Set(), change: 0, revoked: false }
        subscriptions.set(tableID, entry)
        const owned = entry
        const active = () => subscriptions.get(tableID) === owned && !owned.revoked
        const revoke = () => {
          if (!active()) return
          owned.revoked = true
          clearTimeout(owned.timer)
          client.removeQueries({ queryKey: key(tableID) })
          for (const notify of owned.callbacks) notify({ access_revoked: true })
          owned.handle?.close()
        }
        const joinFailed = (error: unknown) => {
          if (isRealtimeAccessDenied(error)) revoke()
        }
        owned.unwatch = realtime.watchVersion('tables', tableID, version => {
          if (!active()) return
          const definition = client.getQueryData<TableSchema>([...key(tableID), 'schema'])
          const actual =
            client.getQueryData<RecordsResult>([...key(tableID), 'snapshot'])?.data_version ??
            definition?.table.data_version
          if (version === undefined) {
            revoke()
            return
          }
          if (version !== actual || definition?.fields.some(field => field.config.volatile)) {
            const prefix = key(tableID)
            const versionEvent: TableEvent = { data_version: version }
            const isCurrentInfinite = (querySpec: RecordQuery, data: CachedInfiniteRecords | undefined) =>
              isInfiniteQueryCurrentForEvent(querySpec, data, versionEvent, definition?.fields)
            trimInfiniteRecordQueriesToFirstPage(client, prefix, isCurrentInfinite)
            void client.invalidateQueries({
              queryKey: prefix,
              predicate: query => {
                if (query.queryKey[prefix.length] === INFINITE_RECORDS_SEGMENT) {
                  const data = query.state.data as CachedInfiniteRecords | undefined
                  const querySpec = (query.queryKey[prefix.length + 1] ?? {}) as RecordQuery
                  if (isCurrentInfinite(querySpec, data)) return false
                }
                return true
              }
            })
            for (const notify of owned.callbacks) notify(versionEvent)
          }
        })
        void realtime
          .join(`table:${tableID}`)
          .then(handle => {
            if (!active()) {
              handle.close()
              return
            }
            owned.handle = handle
            const changed = (event: TableEvent) => {
              if (!active()) return
              const change = ++owned.change
              clearTimeout(owned.timer)
              owned.timer = setTimeout(async () => {
                const current = () => active() && change === owned.change
                const snapshotKey = [...key(tableID), 'snapshot']
                const prefix = key(tableID)
                let fetchedUpdate: RecordsResult | undefined
                let loadedDefinition: TableSchema | undefined
                try {
                  // The server owns both row and byte limits. A write can change the mode.
                  const definition = await client.fetchQuery({
                    queryKey: [...prefix, 'schema'],
                    queryFn: ({ signal }) => baseHTTP.schema(tableID, signal),
                    staleTime: 0
                  })
                  loadedDefinition = definition
                  if (!current()) return
                  const changedIDs = event.changed_ids ?? []
                  const infiniteEntries = client
                    .getQueryCache()
                    .findAll({ queryKey: [...prefix, INFINITE_RECORDS_SEGMENT] })
                  const hasPatchableInfinite =
                    event.data_version !== undefined &&
                    infiniteEntries.some(entry => {
                      const data = entry.state.data as CachedInfiniteRecords | undefined
                      const querySpec = (entry.queryKey[prefix.length + 1] ?? {}) as RecordQuery
                      if (isInfiniteQueryCurrentForEvent(querySpec, data, event, definition.fields)) return false
                      return Boolean(
                        data &&
                        data.pages.length > 0 &&
                        data.pages.every(page => page.data_version + 1 === event.data_version)
                      )
                    })
                  const isSnapshotCurrent = (snap: RecordsResult | undefined) =>
                    definition.mode === 'local' &&
                    !event.schema_changed &&
                    !event.resync &&
                    event.data_version !== undefined &&
                    Boolean(snap?.complete) &&
                    snap!.data_version >= event.data_version
                  const previous = client.getQueryData<RecordsResult>(snapshotKey)
                  const canPatchLocal =
                    definition.mode === 'local' &&
                    Boolean(previous) &&
                    !isSnapshotCurrent(previous) &&
                    event.data_version === previous!.data_version + 1 &&
                    definition.table.data_version === event.data_version &&
                    !event.schema_changed &&
                    !event.resync
                  const canPatchInfinite =
                    hasPatchableInfinite &&
                    !event.schema_changed &&
                    !event.resync &&
                    definition.table.data_version === event.data_version &&
                    changedIDs.length <= 200

                  if (canPatchLocal || canPatchInfinite) {
                    fetchedUpdate = changedIDs.length
                      ? await baseHTTP.query(tableID, { ids: changedIDs })
                      : { records: [], data_version: event.data_version!, complete: true, page_token: null }
                  }
                  if (!current()) return

                  if (canPatchLocal && previous && fetchedUpdate) {
                    const unchanged = client.getQueryData(snapshotKey) === previous
                    if (
                      unchanged &&
                      fetchedUpdate.complete &&
                      !fetchedUpdate.page_token &&
                      fetchedUpdate.data_version === event.data_version
                    ) {
                      const removed = new Set([...(event.deleted_ids ?? []), ...changedIDs])
                      const records = [
                        ...previous.records.filter(record => !removed.has(record.id)),
                        ...fetchedUpdate.records
                      ]
                      client.setQueryData(snapshotKey, {
                        ...previous,
                        records,
                        data_version: event.data_version
                      })
                    } else if (unchanged) await client.invalidateQueries({ queryKey: snapshotKey, exact: true })
                  } else if (definition.mode === 'remote') {
                    client.removeQueries({ queryKey: snapshotKey, exact: true })
                  } else if (!isSnapshotCurrent(client.getQueryData<RecordsResult>(snapshotKey))) {
                    await client.invalidateQueries({ queryKey: snapshotKey, exact: true })
                  }
                } catch {
                  if (current()) await client.invalidateQueries({ queryKey: snapshotKey, exact: true })
                }
                if (current()) {
                  const knownFields = (loadedDefinition ?? client.getQueryData<TableSchema>([...prefix, 'schema']))
                    ?.fields
                  const isCurrentInfinite = (querySpec: RecordQuery, data: CachedInfiniteRecords | undefined) =>
                    isInfiniteQueryCurrentForEvent(querySpec, data, event, knownFields)
                  let refetchInfiniteHashes: Set<string> | undefined
                  if (
                    fetchedUpdate &&
                    fetchedUpdate.complete &&
                    !fetchedUpdate.page_token &&
                    fetchedUpdate.data_version === event.data_version &&
                    loadedDefinition?.table.data_version === event.data_version &&
                    !event.schema_changed &&
                    !event.resync &&
                    event.data_version !== undefined
                  ) {
                    refetchInfiniteHashes = reconcileInfiniteRecordQueries(client, prefix, {
                      fields: loadedDefinition.fields,
                      updatedRecords: fetchedUpdate.records,
                      deletedIDs: event.deleted_ids ?? [],
                      dataVersion: event.data_version
                    })
                  } else {
                    trimInfiniteRecordQueriesToFirstPage(client, prefix, isCurrentInfinite)
                  }
                  const canKeepCurrentVersion =
                    !event.schema_changed &&
                    !event.resync &&
                    event.data_version !== undefined &&
                    !knownFields?.some(field => field.config.volatile)
                  void client.invalidateQueries({
                    queryKey: prefix,
                    predicate: query => {
                      const segment = query.queryKey[prefix.length]
                      if (segment === 'records' || segment === 'aggregate') {
                        if (canKeepCurrentVersion) {
                          const cached = query.state.data as { data_version?: number } | undefined
                          if (typeof cached?.data_version === 'number' && cached.data_version >= event.data_version!) {
                            return false
                          }
                        }
                        return true
                      }
                      if (segment === INFINITE_RECORDS_SEGMENT) {
                        const data = query.state.data as CachedInfiniteRecords | undefined
                        const querySpec = (query.queryKey[prefix.length + 1] ?? {}) as RecordQuery
                        if (isCurrentInfinite(querySpec, data)) return false
                        return refetchInfiniteHashes ? refetchInfiniteHashes.has(query.queryHash) : true
                      }
                      return false
                    }
                  })
                  for (const notify of owned.callbacks) notify(event)
                }
              }, 300)
            }
            handle.on('changed', changed)
            handle.on('schema_changed', event => changed({ ...event, schema_changed: true }))
            handle.on('rejoined', () => changed({ resync: true }))
            handle.on('access_revoked', revoke)
            void handle.ready.catch(joinFailed)
          })
          .catch(joinFailed)
      }
      entry.callbacks.add(callback)
      if (entry.revoked) callback({ access_revoked: true })
      const owned = entry
      return () => {
        owned.callbacks.delete(callback)
        if (!owned.callbacks.size) {
          clearTimeout(owned.timer)
          owned.unwatch?.()
          owned.handle?.close()
          subscriptions.delete(tableID)
        }
      }
    }
  }
}
