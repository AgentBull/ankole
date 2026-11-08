import type { Query, QueryClient, QueryKey } from '@tanstack/react-query'
import type { AggregateResult, BaseAPI } from './types'

/**
 * Keep an aggregate current when another table it read changes, such as a linked table in a path or a child table in
 * a metric. The caller already subscribes to the queried table, so this function watches only the other tables that
 * the cached result's `data_versions` names and drops each watch when the table leaves that set.
 */
export function followAggregateTables(base: BaseAPI, client: QueryClient, tableID: string, queryKey: QueryKey) {
  const cache = client.getQueryCache()
  // An Applet builds its query key in its own frame, while the Pod page owns the cache. The page cannot sort that
  // object's keys, so `hashKey` here would differ from the cache's hash; only the cache can name its own query.
  let hash: string | undefined
  const isAggregate = (query: Query) => (hash ??= cache.find({ queryKey, exact: true })?.queryHash) === query.queryHash
  const watched = new Map<string, () => void>()
  const read = () => client.getQueryData<AggregateResult>(queryKey)?.data_versions ?? {}
  const sync = () => {
    const tables = new Set(Object.keys(read()))
    tables.delete(tableID)
    for (const [id, stop] of watched) {
      if (tables.has(id)) continue
      watched.delete(id)
      stop()
    }
    for (const id of tables) {
      if (watched.has(id)) continue
      watched.set(
        id,
        base.subscribe(id, event => {
          // Periodic version checks report an unchanged version; only a different or unknown version refetches.
          if (event.data_version !== undefined && event.data_version === read()[id]) return
          void client.invalidateQueries({ queryKey, exact: true })
        })
      )
    }
  }
  const unsubscribe = cache.subscribe(event => {
    if (isAggregate(event.query)) sync()
  })
  sync()
  return () => {
    unsubscribe()
    for (const stop of watched.values()) stop()
    watched.clear()
  }
}
