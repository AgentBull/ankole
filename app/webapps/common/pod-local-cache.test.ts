import { afterEach, beforeEach, expect, test } from 'bun:test'
import {
  clearPodLocalCache,
  peekCachedPodRecentSearches,
  podCacheNamespace,
  readCachedPodPages,
  readCachedPodRecentSearches,
  writeCachedPodPages,
  writeCachedPodRecentSearches
} from './pod-local-cache'

const originalIndexedDB = Object.getOwnPropertyDescriptor(globalThis, 'indexedDB')

function createFakeIndexedDB(
  initialRecords: { namespace: string }[] = [],
  deliverRead: (complete: () => void) => void = queueMicrotask
) {
  const databases = new Map<string, Map<string, Map<string, unknown>>>()

  return {
    open(name: string, _version?: number) {
      const request: Record<string, any> = {
        result: null,
        onupgradeneeded: null,
        onsuccess: null,
        onerror: null,
        onblocked: null
      }
      queueMicrotask(() => {
        let stores = databases.get(name)
        const isNew = !stores
        if (!stores) {
          stores = new Map()
          databases.set(name, stores)
        }
        const resolvedStores = stores
        const db = {
          objectStoreNames: {
            contains: (storeName: string) => resolvedStores.has(storeName)
          },
          createObjectStore: (storeName: string) => {
            if (!resolvedStores.has(storeName)) {
              resolvedStores.set(storeName, new Map(initialRecords.map(record => [record.namespace, record])))
            }
            return {}
          },
          transaction: (storeName: string, _mode: string) => {
            const storeMap = resolvedStores.get(storeName) ?? new Map<string, unknown>()
            resolvedStores.set(storeName, storeMap)
            const tx: Record<string, any> = {
              oncomplete: null,
              onerror: null,
              onabort: null,
              objectStore: () => ({
                get(key: string) {
                  const getReq: Record<string, any> = { result: undefined, onsuccess: null, onerror: null }
                  const value = structuredClone(storeMap.get(key))
                  deliverRead(() => {
                    getReq.result = value
                    getReq.onsuccess?.()
                  })
                  return getReq
                },
                put(value: { namespace: string }) {
                  storeMap.set(value.namespace, structuredClone(value))
                  queueMicrotask(() => tx.oncomplete?.())
                },
                delete(key: string) {
                  storeMap.delete(key)
                  queueMicrotask(() => tx.oncomplete?.())
                },
                clear() {
                  storeMap.clear()
                  queueMicrotask(() => tx.oncomplete?.())
                }
              })
            }
            return tx
          }
        }
        request.result = db
        if (isNew) request.onupgradeneeded?.()
        request.onsuccess?.()
      })
      return request
    }
  }
}

beforeEach(async () => {
  Object.defineProperty(globalThis, 'indexedDB', {
    configurable: true,
    value: createFakeIndexedDB()
  })
  await clearPodLocalCache()
})

afterEach(async () => {
  await clearPodLocalCache()
  if (originalIndexedDB) Object.defineProperty(globalThis, 'indexedDB', originalIndexedDB)
  else Reflect.deleteProperty(globalThis, 'indexedDB')
})

test('pod-local-cache isolates page metadata and recent searches by (podId, principalUid) and clears scoped namespaces', async () => {
  expect(podCacheNamespace('pod-a', 'alice')).toBe('pod-a:alice')
  expect(podCacheNamespace('', 'alice')).toBeUndefined()
  expect(podCacheNamespace('pod-a', undefined)).toBeUndefined()

  await writeCachedPodPages('pod-a', 'alice', [
    { id: 'page-1', title: 'Architecture', icon: '📐', type: 'doc', updated_at: '2026-11-11T10:00:00Z' }
  ])
  await writeCachedPodPages('pod-a', 'alice', [{ id: 'page-1', title: 'Architecture v2' }])
  await writeCachedPodPages('pod-b', 'bob', [
    { id: 'page-9', title: 'Finance', icon: '💼', type: 'base', updated_at: '2026-11-11T11:00:00Z' }
  ])

  await writeCachedPodRecentSearches('pod-a', 'alice', [
    { id: 'q-1', query: 'oidc pkce', result_count: 4, updated_at: '2026-11-11T12:00:00Z' }
  ])

  expect(await readCachedPodPages('pod-a', 'alice')).toEqual([
    { id: 'page-1', title: 'Architecture v2', icon: '📐', type: 'doc', updated_at: '2026-11-11T10:00:00Z' }
  ])
  expect(await readCachedPodPages('pod-b', 'bob')).toEqual([
    { id: 'page-9', title: 'Finance', icon: '💼', type: 'base', updated_at: '2026-11-11T11:00:00Z' }
  ])
  expect(peekCachedPodRecentSearches('pod-a', 'alice')).toEqual([
    { id: 'q-1', query: 'oidc pkce', result_count: 4, updated_at: '2026-11-11T12:00:00Z' }
  ])
  expect(await readCachedPodRecentSearches('pod-b', 'bob')).toEqual([])

  await clearPodLocalCache({ podId: 'pod-a', principalUid: 'alice' })

  expect(await readCachedPodPages('pod-a', 'alice')).toEqual([])
  expect(await readCachedPodRecentSearches('pod-a', 'alice')).toEqual([])
  expect(await readCachedPodPages('pod-b', 'bob')).toHaveLength(1)
})

test('concurrent cold writes preserve page metadata and recent searches in the same namespace', async () => {
  const searches = [{ id: 'q-1', query: 'budget', result_count: 1, updated_at: '2026-11-14T10:00:00Z' }]
  await Promise.all([
    writeCachedPodPages('pod-a', 'alice', [{ id: 'page-1', title: 'Budget' }]),
    writeCachedPodPages('pod-a', 'alice', [{ id: 'page-2', title: 'Plans' }]),
    writeCachedPodRecentSearches('pod-a', 'alice', searches)
  ])

  expect(await readCachedPodPages('pod-a', 'alice')).toEqual([
    { id: 'page-1', title: 'Budget' },
    { id: 'page-2', title: 'Plans' }
  ])
  expect(await readCachedPodRecentSearches('pod-a', 'alice')).toEqual(searches)
})

test('a disk read started before sign-out cannot restore the cleared namespace', async () => {
  const record = {
    namespace: 'pod-a:alice',
    podId: 'pod-a',
    principalUid: 'alice',
    pages: { 'page-1': { id: 'page-1', title: 'Budget' } },
    recentSearches: [{ id: 'q-1', query: 'budget', result_count: 1, updated_at: '2026-11-14T10:00:00Z' }],
    updatedAt: Date.now()
  }
  const started = Promise.withResolvers<void>()
  let completeRead: () => void = () => {}
  Object.defineProperty(globalThis, 'indexedDB', {
    configurable: true,
    value: createFakeIndexedDB([record], complete => {
      completeRead = complete
      started.resolve()
    })
  })

  const reading = readCachedPodPages('pod-a', 'alice')
  await started.promise
  const clearing = clearPodLocalCache({ podId: 'pod-a', principalUid: 'alice' })
  completeRead()
  await clearing

  expect(await reading).toEqual([])
  expect(peekCachedPodRecentSearches('pod-a', 'alice')).toBeUndefined()
})
