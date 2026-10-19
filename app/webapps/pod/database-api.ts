import { t } from 'i18next'
import type { QueryClient } from '@tanstack/react-query'
import type {
  AggregateQuery,
  AggregateResult,
  DatabaseAPI,
  DatabaseField,
  DatabaseView,
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

import {
  podDatabaseTables,
  podDatabaseTableCreate,
  podDatabaseSchema,
  podDatabaseQuery,
  podDatabaseAggregate,
  podDatabaseWrite,
  podDatabaseFieldCreate,
  podDatabaseFieldUpdate,
  podDatabaseFieldDelete,
  podDatabaseViewCreate,
  podDatabaseViewUpdate,
  podDatabaseViewDelete
} from '../common/api/generated/sdk.gen'

export const databaseHTTP = {
  tables: (pageID: string) => podDatabaseTables({ path: { page_id: pageID } }),
  createTable: (pageID: string, name: string) => podDatabaseTableCreate({ path: { page_id: pageID }, body: { name } }),
  schema: (tableID: string): Promise<TableSchema> => podDatabaseSchema({ path: { id: tableID } }),
  query: (tableID: string, body: RecordQuery): Promise<RecordsResult> =>
    podDatabaseQuery({ path: { id: tableID }, body }),
  aggregate: (tableID: string, body: AggregateQuery): Promise<AggregateResult> =>
    podDatabaseAggregate({ path: { id: tableID }, body }),
  write: (tableID: string, body: RecordWrite): Promise<WriteResult> =>
    podDatabaseWrite({ path: { id: tableID }, body }),
  createField: (tableID: string, body: Partial<DatabaseField>) =>
    podDatabaseFieldCreate({ path: { id: tableID }, body }),
  updateField: (fieldID: string, patch: Partial<DatabaseField> & { clear_invalid?: boolean }, version: number) =>
    podDatabaseFieldUpdate({ path: { id: fieldID }, body: { ...patch, version } }),
  removeField: (fieldID: string, version: number) =>
    podDatabaseFieldDelete({ path: { id: fieldID }, body: { version } }),
  createView: (tableID: string, body: Partial<DatabaseView>) => podDatabaseViewCreate({ path: { id: tableID }, body }),
  updateView: (viewID: string, patch: Partial<DatabaseView>, version: number) =>
    podDatabaseViewUpdate({ path: { id: viewID }, body: { ...patch, version } }),
  removeView: (viewID: string, version: number) => podDatabaseViewDelete({ path: { id: viewID }, body: { version } })
}

export function createDatabaseAPI(client: QueryClient, realtime: PodRealtime): DatabaseAPI {
  const key = (tableID: string) => [...contentKeys.all, 'table', tableID]
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
  const schema = (tableID: string) =>
    client.fetchQuery({ queryKey: [...key(tableID), 'schema'], queryFn: () => databaseHTTP.schema(tableID) })
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
      queryFn: async () => {
        const result = await databaseHTTP.query(tableID, { local: true })
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
        return databaseHTTP.query(tableID, query)
      }
      const all = await localSnapshot(tableID, definition)
      if (!all) return databaseHTTP.query(tableID, query)
      const records = queryLocalRecords(all.records, definition.fields, query)
      return { ...all, records, complete: true, page_token: null }
    },
    async aggregate(tableID, query) {
      const definition = await schema(tableID)
      if (remoteAtVersion(tableID, definition.table.data_version) || !canAggregateLocally(definition, query)) {
        return databaseHTTP.aggregate(tableID, query)
      }
      const all = await localSnapshot(tableID, definition)
      if (!all) return databaseHTTP.aggregate(tableID, query)
      const result = aggregateLocalRecords(all.records, definition.fields, query, all.data_version, definition.timezone)
      // PostgreSQL owns the configured result bound; use it when the schema cannot establish parity.
      if (definition.limits?.group_count === undefined || result.groups.length > definition.limits.group_count) {
        return databaseHTTP.aggregate(tableID, query)
      }
      return result
    },
    write: databaseHTTP.write,
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
            void client.invalidateQueries({ queryKey: key(tableID) })
            for (const notify of owned.callbacks) notify({ data_version: version })
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
              if (event.schema_changed) void client.invalidateQueries({ queryKey: [...key(tableID), 'schema'] })
              clearTimeout(owned.timer)
              owned.timer = setTimeout(async () => {
                const current = () => active() && change === owned.change
                const snapshotKey = [...key(tableID), 'snapshot']
                try {
                  // The server owns both row and byte limits. A write can change the mode.
                  const definition = await client.fetchQuery({
                    queryKey: [...key(tableID), 'schema'],
                    queryFn: () => databaseHTTP.schema(tableID),
                    staleTime: 0
                  })
                  if (!current()) return
                  const previous = client.getQueryData<RecordsResult>(snapshotKey)
                  if (
                    definition.mode === 'local' &&
                    previous &&
                    event.data_version === previous.data_version + 1 &&
                    definition.table.data_version === event.data_version &&
                    !event.schema_changed
                  ) {
                    const changedIDs = event.changed_ids ?? []
                    const update = changedIDs.length
                      ? await databaseHTTP.query(tableID, { ids: changedIDs })
                      : { records: [], data_version: event.data_version, complete: true, page_token: null }
                    // A late response must not replace a newer snapshot, or restore revoked data.
                    if (!current()) return
                    const unchanged = client.getQueryData(snapshotKey) === previous
                    if (
                      unchanged &&
                      update.complete &&
                      !update.page_token &&
                      update.data_version === event.data_version
                    ) {
                      const removed = new Set([...(event.deleted_ids ?? []), ...changedIDs])
                      const records = [...previous.records.filter(record => !removed.has(record.id)), ...update.records]
                      // This checks the actual client candidate; the server's full local response is authoritative.
                      if (
                        definition.limits?.local_bytes !== undefined &&
                        new TextEncoder().encode(JSON.stringify(records)).byteLength > definition.limits.local_bytes
                      ) {
                        await client.invalidateQueries({ queryKey: snapshotKey, exact: true })
                      } else {
                        client.setQueryData(snapshotKey, {
                          ...previous,
                          records,
                          data_version: event.data_version
                        })
                      }
                    } else if (unchanged) await client.invalidateQueries({ queryKey: snapshotKey, exact: true })
                  } else if (definition.mode === 'remote') {
                    client.removeQueries({ queryKey: snapshotKey, exact: true })
                  } else await client.invalidateQueries({ queryKey: snapshotKey, exact: true })
                } catch {
                  if (current()) await client.invalidateQueries({ queryKey: snapshotKey, exact: true })
                }
                if (current()) for (const notify of owned.callbacks) notify(event)
              }, 300)
            }
            handle.on('changed', changed)
            handle.on('schema_changed', event => changed({ ...event, schema_changed: true }))
            handle.on('access_revoked', revoke)
            void handle.ready.catch(joinFailed)
          })
          .catch(joinFailed)
      }
      entry.callbacks.add(callback)
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
