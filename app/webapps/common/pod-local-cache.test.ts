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

function createFakeIndexedDB() {
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
            if (!resolvedStores.has(storeName)) resolvedStores.set(storeName, new Map())
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
                  queueMicrotask(() => {
                    getReq.result = storeMap.get(key)
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
