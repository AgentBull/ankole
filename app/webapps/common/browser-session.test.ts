import { client } from './api/generated/client.gen'
import { afterEach, beforeEach, expect, test } from 'bun:test'
import {
  applyDataTenantNavigation,
  dataTenantID,
  endSiteSession,
  selectDataTenant,
  withDataContext
} from './browser-session'

const previous = Object.getOwnPropertyDescriptor(globalThis, 'window')
const previousDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
const previousFetch = globalThis.fetch
let currentURL: URL
let requestedURL: URL | undefined
let storage: Map<string, string>
let selectedAuthentication: string

beforeEach(() => {
  currentURL = new URL('https://ankole.test/operator/agents?sort=name')
  client.setConfig({ baseUrl: currentURL.origin })
  requestedURL = undefined
  selectedAuthentication = 'account-a.1'
  storage = new Map([['ankole.console.data-tenant:account-a.1', 'tenant-a']])
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
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: {
      querySelector: (selector: string) =>
        selector.includes('ankole-authentication')
          ? { content: selectedAuthentication }
          : selector.includes('csrf-token')
            ? { content: 'session-csrf' }
            : null
    }
  })
})

afterEach(() => {
  if (previous) Object.defineProperty(globalThis, 'window', previous)
  else Reflect.deleteProperty(globalThis, 'window')
  if (previousDocument) Object.defineProperty(globalThis, 'document', previousDocument)
  else Reflect.deleteProperty(globalThis, 'document')
  globalThis.fetch = previousFetch
})

test('ending a site session keeps the next login from inheriting the old data tenant', async () => {
  const requests: Array<{ path: string; method: string; csrf: string | null }> = []
  globalThis.fetch = (async (request: Request) => {
    expect(dataTenantID()).toBeNull()
    requests.push({
      path: new URL(request.url).pathname,
      method: request.method,
      csrf: request.headers.get('x-csrf-token')
    })
    return Response.json({})
  }) as typeof fetch

  await endSiteSession()

  expect(requests).toEqual([{ path: '/.internal-apis/session', method: 'DELETE', csrf: 'session-csrf' }])
  const tenants: (string | null)[] = []
  const transport = (async (request: Request) => {
    tenants.push(request.headers.get('x-ankole-tenant'))
    return Response.json({})
  }) as typeof fetch
  await withDataContext(transport)('https://ankole.test/api/v2/agents')
  expect(tenants).toEqual([null])
})

test('a failed sign-out request still clears the browser selection before redirecting to sign-in', async () => {
  globalThis.fetch = (async (_path: string, _init?: RequestInit) =>
    Response.json({ error: 'unavailable' }, { status: 503 })) as typeof fetch

  await expect(endSiteSession()).rejects.toMatchObject({ status: 503 })

  expect(dataTenantID()).toBeNull()
})

test('cancelling a tenant switch cannot send an old draft to the requested tenant', async () => {
  selectDataTenant('tenant-b')
  expect(dataTenantID()).toBe('tenant-a')
  const tenants: (string | null)[] = []
  const transport = (async (request: Request) => {
    tenants.push(request.headers.get('x-ankole-tenant'))
    return new Response('{}')
  }) as typeof fetch
  await withDataContext(transport)('https://ankole.test/api/v1/worker-envs/TOKEN', { method: 'PUT' })
  await withDataContext(transport)('https://ankole.test/api/v2/agents', { method: 'POST' })
  expect(tenants).toEqual(['tenant-a', 'tenant-a'])
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
  await request('https://ankole.test/api/v2/principals/author', { headers: { 'x-ankole-tenant': 'author-tenant' } })
  await request('https://ankole.test/api/v1/site/app-configurations')
  await request('https://ankole.test/api/v2/site/tenants')
  expect(tenants).toEqual(['author-tenant', null, null])
})

test('a new document for another authentication has its own Console data selection', () => {
  expect(dataTenantID()).toBe('tenant-a')
  selectedAuthentication = 'account-b.2'
  expect(dataTenantID()).toBeNull()
  selectedAuthentication = 'account-a.1'
  expect(dataTenantID()).toBe('tenant-a')
})
