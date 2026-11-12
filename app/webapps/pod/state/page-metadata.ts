import { BasicIndex, createCollection, type SyncConfig } from '@tanstack/db'
import type { QueryClient } from '@tanstack/react-query'
import { authenticationRef, podID, principalUID } from '../../common/browser-context'
import { readCachedPodPages, readCachedPodRecentSearches, writeCachedPodPages } from '../../common/pod-local-cache'

export type PageMetadata = {
  id: string
  title?: string
  icon?: string | null
  type?: string
  updated_at?: string | null
}

function isOlderSnapshot(incoming?: string | null, existing?: string | null): boolean {
  if (!incoming || !existing) return false
  const incomingTime = Date.parse(incoming)
  const existingTime = Date.parse(existing)
  if (!Number.isFinite(incomingTime) || !Number.isFinite(existingTime)) return false
  return incomingTime < existingTime
}

/** The shared display fields of Pages read in this Pod session. Query owns requests and membership. */
export function createPageMetadata(persistence?: { podId?: string | null; principalUid?: string | null }) {
  let sync!: Parameters<SyncConfig<PageMetadata, string>['sync']>[0]
  let disposed = false
  let version = 0
  const changed = new Map<string, number>()
  const listeners = new Set<() => void>()
  const collection = createCollection<PageMetadata, string>({
    getKey: page => page.id,
    startSync: true,
    gcTime: Infinity,
    sync: {
      sync(params) {
        sync = params
        params.markReady()
      }
    }
  })
  collection.createIndex(page => page.id, { indexType: BasicIndex })

  function receive(pages: readonly PageMetadata[], readVersion = version, fromRead = false, persist = true) {
    if (disposed) return
    let wrote = false
    const writtenEntries: PageMetadata[] = []
    sync.begin()
    for (const page of new Map(pages.map(page => [page.id, page])).values()) {
      // A read already in flight when a rename/icon write completed cannot undo that write.
      if ((changed.get(page.id) ?? 0) > readVersion) continue
      const previous = collection.get(page.id)
      if (fromRead && isOlderSnapshot(page.updated_at, previous?.updated_at)) continue
      const hasIcon = 'icon' in page && page.icon !== undefined
      const next: PageMetadata = {
        id: page.id,
        title: page.title ?? previous?.title,
        icon: hasIcon ? page.icon : previous?.icon,
        type: page.type ?? previous?.type,
        updated_at: page.updated_at !== undefined ? page.updated_at : previous?.updated_at
      }
      if (
        previous &&
        previous.title === next.title &&
        previous.icon === next.icon &&
        previous.type === next.type &&
        previous.updated_at === next.updated_at
      ) {
        continue
      }
      sync.write({ type: previous ? 'update' : 'insert', value: next })
      writtenEntries.push(next)
      wrote = true
    }
    sync.commit()
    if (wrote) {
      if (persist && persistence?.podId && persistence.principalUid) {
        void writeCachedPodPages(persistence.podId, persistence.principalUid, writtenEntries)
      }
      for (const listener of listeners) listener()
    }
  }

  if (persistence?.podId && persistence.principalUid) {
    const hydrateVersion = version
    void readCachedPodPages(persistence.podId, persistence.principalUid).then(entries => {
      if (entries.length > 0) receive(entries, hydrateVersion, true, false)
    })
    void readCachedPodRecentSearches(persistence.podId, persistence.principalUid)
  }

  return {
    collection,
    values(): PageMetadata[] {
      return [...collection.values()]
    },
    subscribe(listener: () => void): () => void {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    async read<T>(request: () => Promise<T>, pages: (result: T) => readonly PageMetadata[]): Promise<T> {
      const readVersion = version
      const result = await request()
      receive(
        pages(result).map(page => ({
          id: page.id,
          ...(page.title !== undefined ? { title: page.title } : {}),
          ...('icon' in page && page.icon !== undefined ? { icon: page.icon } : {}),
          ...(page.type !== undefined ? { type: page.type } : {}),
          ...(page.updated_at !== undefined ? { updated_at: page.updated_at } : {})
        })),
        readVersion,
        true
      )
      return result
    },
    update(patch: PageMetadata) {
      const hasIcon = 'icon' in patch && patch.icon !== undefined
      if (patch.title === undefined && !hasIcon && patch.type === undefined && patch.updated_at === undefined) return
      changed.set(patch.id, ++version)
      receive([
        {
          id: patch.id,
          ...(patch.title !== undefined ? { title: patch.title } : {}),
          ...(hasIcon ? { icon: patch.icon } : {}),
          ...(patch.type !== undefined ? { type: patch.type } : {}),
          ...(patch.updated_at !== undefined ? { updated_at: patch.updated_at } : {})
        }
      ])
    },
    dispose() {
      disposed = true
      changed.clear()
      listeners.clear()
      void collection.cleanup({ dependents: true })
    }
  }
}

const stores = new WeakMap<QueryClient, { scope: string; metadata: ReturnType<typeof createPageMetadata> }>()

export function pageMetadata(client: QueryClient) {
  const currentPodID = podID()
  const currentPrincipalUID = principalUID()
  const scope = JSON.stringify([authenticationRef() ?? currentPrincipalUID, currentPodID])
  let store = stores.get(client)
  if (!store || store.scope !== scope) {
    store?.metadata.dispose()
    store = {
      scope,
      metadata: createPageMetadata({ podId: currentPodID, principalUid: currentPrincipalUID })
    }
    stores.set(client, store)
  }
  return store.metadata
}
