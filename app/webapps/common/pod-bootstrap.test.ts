import { afterEach, expect, test } from 'bun:test'
import { QueryClient } from '@tanstack/react-query'
import { podAgents } from '../pod/api/generated/sdk.gen'
import { client as podClient } from '../pod/api/generated/client.gen'
import { podSocketEndpoint } from '../pod/realtime'
import { watchPodSession } from '../pod/session-redirect'
import {
  authenticationRef,
  identityHeaders,
  isDesktopRuntime,
  podID,
  podPublicOrigin,
  principalUID,
  replacePrincipalUID
} from './browser-context'
import { InternalAPIError } from './internal-api-client'
import { getPodRuntimeBootstrap, setPodRuntimeBootstrap, type PodRuntimeBootstrap } from './pod-bootstrap'

const originalFetch = globalThis.fetch
const originalDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')

const sampleBootstrap = (overrides: Partial<PodRuntimeBootstrap> = {}): PodRuntimeBootstrap => ({
  mode: 'desktop',
  platform: 'macos',
  workspaceKey: 'https://acme.ankole.test::01950000-0000-7000-8000-000000000001::alice',
  podOrigin: 'https://acme.ankole.test',
  siteOrigin: 'https://ankole.test',
  tenantId: '01950000-0000-7000-8000-000000000001',
  tenantSlug: 'acme',
  tenantDisplayName: 'Acme Workspace',
  principalUid: 'alice',
  principalDisplayName: 'Alice',
  activePlugins: ['base'],
  features: { desktop_pdf: true },
  locale: 'zh-Hans-CN',
  ...overrides
})

afterEach(() => {
  setPodRuntimeBootstrap(undefined)
  globalThis.fetch = originalFetch
  if (originalDocument) Object.defineProperty(globalThis, 'document', originalDocument)
  else Reflect.deleteProperty(globalThis, 'document')
})

test('desktop runtime bootstrap supplies Pod context, origins, and platform dataset without HTML meta tags', () => {
  const dataset: Record<string, string | undefined> = {}
  const documentElement = { dataset, lang: 'en-US' }
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: {
      documentElement,
      querySelector: () => null
    }
  })

  setPodRuntimeBootstrap(sampleBootstrap())

  expect(isDesktopRuntime()).toBe(true)
  expect(dataset.ankoleDesktop).toBe('macos')
  expect(documentElement.lang).toBe('zh-Hans-CN')
  expect(authenticationRef()).toBeUndefined()
  expect(podID()).toBe('01950000-0000-7000-8000-000000000001')
  expect(principalUID()).toBe('alice')
  expect(podPublicOrigin()).toBe('https://acme.ankole.test')
  expect(getPodRuntimeBootstrap()?.siteOrigin).toBe('https://ankole.test')
  expect(identityHeaders()).toEqual({
    'x-ankole-pod': '01950000-0000-7000-8000-000000000001'
  })

  replacePrincipalUID('alice-renamed')
  expect(principalUID()).toBe('alice-renamed')

  setPodRuntimeBootstrap(undefined)
  expect(isDesktopRuntime()).toBe(false)
  expect(dataset.ankoleDesktop).toBeUndefined()
})

test('desktop runtime omits x-csrf-token when HTML meta tags are absent while preserving x-ankole-pod and accept-language', async () => {
  const requests: Request[] = []
  podClient.setConfig({ baseUrl: 'https://ankole.local' })
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: {
      documentElement: { dataset: {}, lang: 'en-US' },
      querySelector: () => null
    }
  })
  globalThis.fetch = (async (request: Request) => {
    requests.push(request)
    return Response.json({ agents: [] })
  }) as typeof fetch

  setPodRuntimeBootstrap(sampleBootstrap({ locale: 'ja-JP' }))
  await podAgents()

  expect(requests).toHaveLength(1)
  expect(requests[0]!.headers.get('x-csrf-token')).toBeNull()
  expect(requests[0]!.headers.get('x-ankole-authentication')).toBeNull()
  expect(requests[0]!.headers.get('x-ankole-pod')).toBe('01950000-0000-7000-8000-000000000001')
  expect(requests[0]!.headers.get('accept-language')).toBe('ja-JP')

  setPodRuntimeBootstrap(undefined)
  await expect(podAgents()).rejects.toThrow('CSRF token is missing')
})

test('podSocketEndpoint derives wss and ws endpoints from desktop podOrigin and keeps relative path on web', () => {
  expect(podSocketEndpoint(undefined)).toBe('/pod/socket')
  expect(podSocketEndpoint('https://acme.ankole.test')).toBe('wss://acme.ankole.test/pod/socket')
  expect(podSocketEndpoint('http://127.0.0.1:4000')).toBe('ws://127.0.0.1:4000/pod/socket')

  setPodRuntimeBootstrap(sampleBootstrap({ podOrigin: 'https://pod.ankole.cloud' }))
  expect(podSocketEndpoint()).toBe('wss://pod.ankole.cloud/pod/socket')
})

test('watchPodSession notifies desktop onSessionExpired once instead of navigating to /sessions/new', async () => {
  let expiredCalls = 0
  const visits: string[] = []
  setPodRuntimeBootstrap(
    sampleBootstrap({
      onSessionExpired: () => {
        expiredCalls += 1
      }
    })
  )

  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const stop = watchPodSession(client, {
    pathname: '/pages/home',
    search: '',
    assign: url => {
      visits.push(String(url))
    }
  })

  const unauthorized = () =>
    Promise.reject(
      new InternalAPIError(401, 'Unauthorized', {
        error: { code: 'unauthorized', message: 'Unauthorized' }
      })
    )

  await Promise.allSettled([
    client.fetchQuery({ queryKey: ['first'], queryFn: unauthorized }),
    client.fetchQuery({ queryKey: ['second'], queryFn: unauthorized })
  ])

  expect(expiredCalls).toBe(1)
  expect(visits).toEqual([])
  stop()
})
