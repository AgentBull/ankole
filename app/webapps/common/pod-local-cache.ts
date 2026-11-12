export type CachedPodPageMetadata = {
  id: string
  title?: string
  icon?: string | null
  type?: string
  updated_at?: string | null
}

export type CachedPodRecentSearch = {
  id: string
  query: string
  result_count: number
  updated_at: string
}

type PodCacheRecord = {
  namespace: string
  podId: string
  principalUid: string
  pages: Record<string, CachedPodPageMetadata>
  recentSearches: CachedPodRecentSearch[]
  updatedAt: number
}

const DB_NAME = 'ankole-pod-local-cache'
const DB_VERSION = 1
const STORE_NAME = 'namespaces'
const MAX_CACHED_PAGES = 2000

const memoryNamespaces = new Map<string, PodCacheRecord>()
let cachedIndexedDB: IDBFactory | undefined
let dbPromise: Promise<IDBDatabase | null> | undefined

export function podCacheNamespace(podId?: string | null, principalUid?: string | null): string | undefined {
  if (!podId || !principalUid) return undefined
  return `${podId}:${principalUid}`
}

function openCacheDatabase(): Promise<IDBDatabase | null> {
  if (typeof indexedDB === 'undefined') {
    cachedIndexedDB = undefined
    dbPromise = undefined
    return Promise.resolve(null)
  }
  if (cachedIndexedDB !== indexedDB) {
    cachedIndexedDB = indexedDB
    dbPromise = undefined
  }
  if (!dbPromise) {
    dbPromise = new Promise(resolve => {
      try {
        const request = indexedDB.open(DB_NAME, DB_VERSION)
        request.onupgradeneeded = () => {
          const db = request.result
          if (!db.objectStoreNames.contains(STORE_NAME)) {
            db.createObjectStore(STORE_NAME, { keyPath: 'namespace' })
          }
        }
        request.onsuccess = () => resolve(request.result)
        request.onerror = () => resolve(null)
        request.onblocked = () => resolve(null)
      } catch {
        resolve(null)
      }
    })
  }
  return dbPromise
}

async function readRecordFromIDB(namespace: string): Promise<PodCacheRecord | undefined> {
  const cached = memoryNamespaces.get(namespace)
  if (cached) return cached
  const db = await openCacheDatabase()
  if (!db) return undefined
  return new Promise(resolve => {
    try {
      const tx = db.transaction(STORE_NAME, 'readonly')
      const req = tx.objectStore(STORE_NAME).get(namespace)
      req.onsuccess = () => {
        const value = req.result as PodCacheRecord | undefined
        if (value && typeof value === 'object') {
          memoryNamespaces.set(namespace, value)
          resolve(value)
        } else {
          resolve(undefined)
        }
      }
      req.onerror = () => resolve(undefined)
    } catch {
      resolve(undefined)
    }
  })
}

async function writeRecordToIDB(record: PodCacheRecord): Promise<void> {
  const db = await openCacheDatabase()
  if (!db) return
  memoryNamespaces.set(record.namespace, record)
  await new Promise<void>(resolve => {
    try {
      const tx = db.transaction(STORE_NAME, 'readwrite')
      tx.objectStore(STORE_NAME).put(record)
      tx.oncomplete = () => resolve()
      tx.onerror = () => resolve()
      tx.onabort = () => resolve()
    } catch {
      resolve()
    }
  })
}

export async function readCachedPodPages(
  podId?: string | null,
  principalUid?: string | null
): Promise<CachedPodPageMetadata[]> {
  const namespace = podCacheNamespace(podId, principalUid)
  if (!namespace) return []
  const record = await readRecordFromIDB(namespace)
  return record ? Object.values(record.pages) : []
}

export async function writeCachedPodPages(
  podId: string | null | undefined,
  principalUid: string | null | undefined,
  entries: readonly CachedPodPageMetadata[]
): Promise<void> {
  const namespace = podCacheNamespace(podId, principalUid)
  if (!namespace || !podId || !principalUid || entries.length === 0) return
  const existing = (await readRecordFromIDB(namespace)) ?? {
    namespace,
    podId,
    principalUid,
    pages: {},
    recentSearches: [],
    updatedAt: Date.now()
  }
  const merged: Record<string, CachedPodPageMetadata> = { ...existing.pages }
  for (const entry of entries) {
    if (!entry.id) continue
    merged[entry.id] = {
      id: entry.id,
      ...(entry.title !== undefined
        ? { title: entry.title }
        : merged[entry.id]?.title !== undefined
          ? { title: merged[entry.id]!.title }
          : {}),
      ...(entry.icon !== undefined
        ? { icon: entry.icon }
        : merged[entry.id]?.icon !== undefined
          ? { icon: merged[entry.id]!.icon }
          : {}),
      ...(entry.type !== undefined
        ? { type: entry.type }
        : merged[entry.id]?.type !== undefined
          ? { type: merged[entry.id]!.type }
          : {}),
      ...(entry.updated_at !== undefined
        ? { updated_at: entry.updated_at }
        : merged[entry.id]?.updated_at !== undefined
          ? { updated_at: merged[entry.id]!.updated_at }
          : {})
    }
  }
  const allEntries = Object.values(merged)
  if (allEntries.length > MAX_CACHED_PAGES) {
    allEntries.sort((a, b) => (b.updated_at ?? '').localeCompare(a.updated_at ?? ''))
    const trimmed: Record<string, CachedPodPageMetadata> = {}
    for (const item of allEntries.slice(0, MAX_CACHED_PAGES)) trimmed[item.id] = item
    await writeRecordToIDB({
      ...existing,
      pages: trimmed,
      updatedAt: Date.now()
    })
    return
  }
  await writeRecordToIDB({
    ...existing,
    pages: merged,
    updatedAt: Date.now()
  })
}

export async function readCachedPodRecentSearches(
  podId?: string | null,
  principalUid?: string | null
): Promise<CachedPodRecentSearch[]> {
  const namespace = podCacheNamespace(podId, principalUid)
  if (!namespace) return []
  const record = await readRecordFromIDB(namespace)
  return record?.recentSearches ?? []
}

export function peekCachedPodRecentSearches(
  podId?: string | null,
  principalUid?: string | null
): CachedPodRecentSearch[] | undefined {
  const namespace = podCacheNamespace(podId, principalUid)
  if (!namespace) return undefined
  return memoryNamespaces.get(namespace)?.recentSearches
}

export async function writeCachedPodRecentSearches(
  podId: string | null | undefined,
  principalUid: string | null | undefined,
  queries: readonly CachedPodRecentSearch[]
): Promise<void> {
  const namespace = podCacheNamespace(podId, principalUid)
  if (!namespace || !podId || !principalUid) return
  const existing = (await readRecordFromIDB(namespace)) ?? {
    namespace,
    podId,
    principalUid,
    pages: {},
    recentSearches: [],
    updatedAt: Date.now()
  }
  await writeRecordToIDB({
    ...existing,
    recentSearches: [...queries],
    updatedAt: Date.now()
  })
}

export async function clearPodLocalCache(scope?: {
  podId?: string | null
  principalUid?: string | null
}): Promise<void> {
  const namespace = podCacheNamespace(scope?.podId, scope?.principalUid)
  if (namespace) {
    memoryNamespaces.delete(namespace)
  } else {
    memoryNamespaces.clear()
  }
  const db = await openCacheDatabase()
  if (!db) return
  await new Promise<void>(resolve => {
    try {
      const tx = db.transaction(STORE_NAME, 'readwrite')
      const store = tx.objectStore(STORE_NAME)
      if (namespace) store.delete(namespace)
      else store.clear()
      tx.oncomplete = () => resolve()
      tx.onerror = () => resolve()
      tx.onabort = () => resolve()
    } catch {
      resolve()
    }
  })
}
