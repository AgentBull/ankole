import { BasicIndex, createCollection, type SyncConfig } from '@tanstack/db'
import type { QueryClient } from '@tanstack/react-query'
import { authenticationRef, podID } from '../../common/browser-context'

export type PageMetadata = {
  id: string
  title?: string
  icon?: string | null
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
export function createPageMetadata() {
  let sync!: Parameters<SyncConfig<PageMetadata, string>['sync']>[0]
  let disposed = false
  let version = 0
  const changed = new Map<string, number>()
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

  function receive(pages: readonly PageMetadata[], readVersion = version, fromRead = false) {
    if (disposed) return
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
        updated_at: page.updated_at !== undefined ? page.updated_at : previous?.updated_at
      }
      if (
        previous &&
        previous.title === next.title &&
        previous.icon === next.icon &&
        previous.updated_at === next.updated_at
      ) {
        continue
      }
      sync.write({ type: previous ? 'update' : 'insert', value: next })
    }
    sync.commit()
  }

  return {
    collection,
    async read<T>(request: () => Promise<T>, pages: (result: T) => readonly PageMetadata[]): Promise<T> {
      const readVersion = version
      const result = await request()
      receive(
        pages(result).map(page => ({
          id: page.id,
          ...(page.title !== undefined ? { title: page.title } : {}),
          ...('icon' in page && page.icon !== undefined ? { icon: page.icon } : {}),
          ...(page.updated_at !== undefined ? { updated_at: page.updated_at } : {})
        })),
        readVersion,
        true
      )
      return result
    },
    update(patch: PageMetadata) {
      const hasIcon = 'icon' in patch && patch.icon !== undefined
      if (patch.title === undefined && !hasIcon && patch.updated_at === undefined) return
      changed.set(patch.id, ++version)
      receive([
        {
          id: patch.id,
          ...(patch.title !== undefined ? { title: patch.title } : {}),
          ...(hasIcon ? { icon: patch.icon } : {}),
          ...(patch.updated_at !== undefined ? { updated_at: patch.updated_at } : {})
        }
      ])
    },
    dispose() {
      disposed = true
      changed.clear()
      void collection.cleanup({ dependents: true })
    }
  }
}

const stores = new WeakMap<QueryClient, { scope: string; metadata: ReturnType<typeof createPageMetadata> }>()

export function pageMetadata(client: QueryClient) {
  const scope = JSON.stringify([authenticationRef(), podID()])
  let store = stores.get(client)
  if (!store || store.scope !== scope) {
    store?.metadata.dispose()
    store = { scope, metadata: createPageMetadata() }
    stores.set(client, store)
  }
  return store.metadata
}
