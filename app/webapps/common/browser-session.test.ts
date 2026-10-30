import { client } from './api/generated/client.gen'
import { afterEach, beforeEach, expect, test } from 'bun:test'
import {
  applyDataTenantNavigation,
  dataTenantID,
  endAccountSession,
  endBrowserSession,
  selectDataTenant,
  withDataContext
} from './browser-session'

const previous = Object.getOwnPropertyDescriptor(globalThis, 'window')
const previousDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
const previousFetch = globalThis.fetch
let currentURL: URL
let requestedURL: URL | undefined
let storage: Map<string, string>
let local: Map<string, string>
let selectedAuthentication: string
let selectedPrincipal: string

function mockStorage(backing: Map<string, string>): Storage {
  return {
    get length() {
      return backing.size
    },
    key(index: number) {
      return [...backing.keys()][index] ?? null
    },
    getItem(key: string) {
      return backing.get(key) ?? null
    },
    setItem(key: string, value: string) {
      backing.set(key, value)
    },
    removeItem(key: string) {
      backing.delete(key)
    },
    clear() {
      backing.clear()
    }
  }
}

beforeEach(() => {
  currentURL = new URL('https://ankole.test/operator/agents?sort=name')
  client.setConfig({ baseUrl: currentURL.origin })
  requestedURL = undefined
  selectedAuthentication = 'account-a.1'
  selectedPrincipal = 'usr_alice'
  storage = new Map([['ankole.console.data-tenant:account-a.1', 'tenant-a']])
  local = new Map()
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
      localStorage: mockStorage(local),
      sessionStorage: mockStorage(storage)
    }
  })
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: {
      querySelector: (selector: string) =>
        selector.includes('ankole-authentication')
          ? { content: selectedAuthentication }
          : selector.includes('ankole-pod')
            ? { content: 'pod-privileged' }
            : selector.includes('ankole-principal')
              ? { content: selectedPrincipal }
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

test('ending the browser session keeps the next login from inheriting the old data tenant', async () => {
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

  await endBrowserSession()

  expect(requests).toEqual([{ path: '/api/v2/browser/session', method: 'DELETE', csrf: 'session-csrf' }])
  const tenants: (string | null)[] = []
  const transport = (async (request: Request) => {
    tenants.push(request.headers.get('x-ankole-tenant'))
    return Response.json({})
  }) as typeof fetch
  await withDataContext(transport)('https://ankole.test/api/v2/agents')
  expect(tenants).toEqual([null])
})

test('ending a single account session revokes only the pinned Pod access and clears its data tenant', async () => {
  const requests: Array<{
    path: string
    method: string
    csrf: string | null
    authentication: string | null
    pod: string | null
  }> = []
  globalThis.fetch = (async (request: Request) => {
    expect(dataTenantID()).toBeNull()
    requests.push({
      path: new URL(request.url).pathname,
      method: request.method,
      csrf: request.headers.get('x-csrf-token'),
      authentication: request.headers.get('x-ankole-authentication'),
      pod: request.headers.get('x-ankole-pod')
    })
    return Response.json({})
  }) as typeof fetch

  await endAccountSession()

  expect(requests).toEqual([
    {
      path: '/api/v2/browser/authentications/current',
      method: 'DELETE',
      csrf: 'session-csrf',
      authentication: 'account-a.1',
      pod: 'pod-privileged'
    }
  ])
})

test('a failed sign-out request still clears the browser selection before redirecting to sign-in', async () => {
  globalThis.fetch = (async (_path: string, _init?: RequestInit) =>
    Response.json({ error: 'unavailable' }, { status: 503 })) as typeof fetch

  await expect(endBrowserSession()).rejects.toMatchObject({ status: 503 })

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
  await withDataContext(transport)('https://ankole.test/api/v2/worker-envs/TOKEN', { method: 'PUT' })
  await withDataContext(transport)('https://ankole.test/api/v2/agents', { method: 'POST' })
  expect(tenants).toEqual(['tenant-a', 'tenant-a'])
  expect(requestedURL?.searchParams.get('data_tenant')).toBe('tenant-b')
})

test('switching an existing editor to another tenant leaves the old record route', () => {
  selectDataTenant('tenant-b', '/operator/identity')
  expect(requestedURL?.pathname).toBe('/operator/identity')
  expect(requestedURL?.searchParams.get('data_tenant')).toBe('tenant-b')
  expect(dataTenantID()).toBe('tenant-a')
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

test('explicit author context, non-v2 paths, and site requests cannot inherit the selected data tenant', async () => {
  const tenants: (string | null)[] = []
  const transport = (async (request: Request) => {
    tenants.push(request.headers.get('x-ankole-tenant'))
    return new Response('{}')
  }) as typeof fetch
  const request = withDataContext(transport)
  await request('https://ankole.test/api/v2/principals/author', { headers: { 'x-ankole-tenant': 'author-tenant' } })
  await request('https://ankole.test/api/v1/agents')
  await request('https://ankole.test/api/v2/site/app-configurations')
  await request('https://ankole.test/api/v2/site/tenants')
  expect(tenants).toEqual(['author-tenant', null, null, null])
})

test('a new document for another authentication has its own Console data selection', () => {
  expect(dataTenantID()).toBe('tenant-a')
  selectedAuthentication = 'account-b.2'
  expect(dataTenantID()).toBeNull()
  selectedAuthentication = 'account-a.1'
  expect(dataTenantID()).toBe('tenant-a')
})

test('ending a single account session wipes Pod drafts and comment quotes only for that Pod and Principal', async () => {
  local.set('ankole.pod.comments:pod-privileged:usr_alice:page-1', '{"quote":"secret"}')
  local.set('ankole.pod.comments:pod-privileged:usr_bob:page-1', '{"quote":"keep-bob"}')
  local.set('ankole.pod.comments:pod-other:usr_alice:page-1', '{"quote":"keep-other-pod"}')
  storage.set('ankole.pod.document-draft:pod-privileged:usr_alice:page-1', '{"xml":"<page><p>secret</p></page>"}')
  storage.set('ankole.pod.document-draft:pod-privileged:usr_bob:page-1', '{"xml":"<page><p>keep</p></page>"}')
  globalThis.fetch = (async (_request: Request) => Response.json({})) as typeof fetch

  await endAccountSession()

  expect(local.has('ankole.pod.comments:pod-privileged:usr_alice:page-1')).toBe(false)
  expect(storage.has('ankole.pod.document-draft:pod-privileged:usr_alice:page-1')).toBe(false)
  expect(local.get('ankole.pod.comments:pod-privileged:usr_bob:page-1')).toBe('{"quote":"keep-bob"}')
  expect(local.get('ankole.pod.comments:pod-other:usr_alice:page-1')).toBe('{"quote":"keep-other-pod"}')
  expect(storage.get('ankole.pod.document-draft:pod-privileged:usr_bob:page-1')).toBe(
    '{"xml":"<page><p>keep</p></page>"}'
  )
})

test('ending the browser session wipes all Pod drafts and comment quotes across storage buckets', async () => {
  local.set('ankole.pod.comments:pod-privileged:usr_alice:page-1', '{"quote":"secret"}')
  local.set('ankole.pod.comments:pod-other:usr_bob:page-2', '{"drafts":{"new":"reply"}}')
  local.set('ankole.pod.stats-preference', 'true')
  storage.set('ankole.pod.document-draft:pod-privileged:usr_alice:page-1', '{"xml":"<page><p>secret</p></page>"}')
  storage.set('ankole.pod.document-draft:pod-other:usr_bob:page-2', '{"xml":"<page><p>other</p></page>"}')
  globalThis.fetch = (async (_request: Request) => Response.json({})) as typeof fetch

  await endBrowserSession()

  expect([...local.keys()]).toEqual(['ankole.pod.stats-preference'])
  expect([...storage.keys()]).toEqual([])
})
