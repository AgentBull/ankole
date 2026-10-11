import { afterEach, beforeEach, expect, test } from 'bun:test'
import { applyDataTenantNavigation, dataTenantID, selectDataTenant, withDataContext } from './data-context'

const previous = Object.getOwnPropertyDescriptor(globalThis, 'window')
let currentURL: URL
let requestedURL: URL | undefined
let storage: Map<string, string>

beforeEach(() => {
  currentURL = new URL('https://ankole.test/operator/agents?sort=name')
  requestedURL = undefined
  storage = new Map([['ankole.console.data-tenant', 'tenant-a']])
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: {
      location: {
        get href() {
          return currentURL.href
        },
        get origin() {
          return currentURL.origin
        },
        // A cancelled browser navigation keeps the old document alive.
        assign(value: string | URL) {
          requestedURL = new URL(value)
        }
      },
      history: {
        state: null,
        replaceState(_state: unknown, _title: string, url: string | URL) {
          currentURL = new URL(url)
        }
      },
      sessionStorage: {
        getItem(key: string) {
          return storage.get(key) ?? null
        },
        setItem(key: string, value: string) {
          storage.set(key, value)
        },
        removeItem(key: string) {
          storage.delete(key)
        }
      }
    }
  })
})

afterEach(() => {
  if (previous) Object.defineProperty(globalThis, 'window', previous)
  else Reflect.deleteProperty(globalThis, 'window')
})

test('cancelling a tenant switch cannot send an old draft to the requested tenant', async () => {
  selectDataTenant('tenant-b')
  expect(dataTenantID()).toBe('tenant-a')
  const tenants: (string | null)[] = []
  const transport = (async (request: Request) => {
    tenants.push(request.headers.get('x-ankole-tenant'))
    return new Response('{}')
  }) as typeof fetch
  await withDataContext(transport)('https://ankole.test/api/v1/agents', { method: 'POST' })
  expect(tenants).toEqual(['tenant-a'])
  expect(requestedURL?.searchParams.get('data_tenant')).toBe('tenant-b')
})

test('a new document consumes the navigation request before creating its router', () => {
  selectDataTenant('tenant-b')
  currentURL = requestedURL!
  applyDataTenantNavigation()
  expect(dataTenantID()).toBe('tenant-b')
  expect(currentURL.search).toBe('?sort=name')
  selectDataTenant(null)
  currentURL = requestedURL!
  applyDataTenantNavigation()
  expect(dataTenantID()).toBeNull()
})

test('explicit author context and site requests cannot inherit the selected data tenant', async () => {
  const tenants: (string | null)[] = []
  const transport = (async (request: Request) => {
    tenants.push(request.headers.get('x-ankole-tenant'))
    return new Response('{}')
  }) as typeof fetch
  const request = withDataContext(transport)
  await request('https://ankole.test/api/v1/principals/author', { headers: { 'x-ankole-tenant': 'author-tenant' } })
  await request('https://ankole.test/api/v1/site/tenants')
  expect(tenants).toEqual(['author-tenant', null])
})
