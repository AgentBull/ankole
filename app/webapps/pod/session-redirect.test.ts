import { expect, test } from 'bun:test'
import { QueryClient } from '@tanstack/react-query'
import { InternalAPIError } from '../common/internal-api-client'
import { createAppletRoutes } from './applet-routes'
import { watchPodSession } from './session-redirect'

function podLocation(pathname: string, search = '') {
  const visits: string[] = []
  return { visits, location: { pathname, search, assign: (url: string | URL) => void visits.push(String(url)) } }
}

const failure = (status: number, code: string) => () =>
  Promise.reject(new InternalAPIError(status, 'Unauthorized', { error: { code, message: code } }))

test('a request that loses the Pod session sends the open shell to sign-in once, returning to the current page', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const { visits, location } = podLocation('/pages/abc', '?view=grid')
  const stop = watchPodSession(client, location)

  await Promise.allSettled([
    client.fetchQuery({ queryKey: ['space'], queryFn: failure(401, 'unauthorized') }),
    client.fetchQuery({ queryKey: ['private'], queryFn: failure(401, 'unauthorized') }),
    client.fetchQuery({ queryKey: ['session'], queryFn: failure(401, 'unauthenticated') })
  ])

  expect(visits).toEqual(['/sessions/new?return_to=%2Fpages%2Fabc%3Fview%3Dgrid'])
  stop()
})

test('a failed save on the Pod home page signs in without a return path', async () => {
  const client = new QueryClient()
  const { visits, location } = podLocation('/')
  const stop = watchPodSession(client, location)

  await client
    .getMutationCache()
    .build(client, { mutationFn: failure(401, 'unauthorized') })
    .execute(undefined)
    .catch(() => undefined)

  expect(visits).toEqual(['/sessions/new'])
  stop()
})

test('an Applet route that answers 401 unauthorized itself keeps the user in the Pod', async () => {
  const originalFetch = globalThis.fetch
  const originalRequest = globalThis.Request
  const originalDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: { querySelector: () => ({ content: 'token' }), documentElement: { lang: '' } }
  })
  // Bun has no page origin, so the route's root-relative URL needs one.
  globalThis.Request = class extends originalRequest {
    constructor(input: RequestInfo | URL, init?: RequestInit) {
      super(typeof input === 'string' ? new URL(input, 'https://pod.ankole.test') : input, init)
    }
  }
  globalThis.fetch = (async (_request: Request) =>
    Response.json(
      { error: { code: 'unauthorized', message: 'Connect your CRM first' } },
      { status: 401 }
    )) as typeof fetch
  try {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { visits, location } = podLocation('/pages/crm')
    const stop = watchPodSession(client, location)
    const routes = createAppletRoutes('crm', 1, () => {})

    const failure = await client
      .fetchQuery({ queryKey: routes.key(), queryFn: () => routes.call({ method: 'GET', path: '/deals' }) })
      .catch(error => error)

    expect(failure).toBeInstanceOf(InternalAPIError)
    expect((failure as InternalAPIError).status).toBe(401)
    expect(visits).toEqual([])
    stop()
  } finally {
    globalThis.fetch = originalFetch
    globalThis.Request = originalRequest
    if (originalDocument) Object.defineProperty(globalThis, 'document', originalDocument)
    else Reflect.deleteProperty(globalThis, 'document')
  }
})

test('other failures stay with the section or form that sent them', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const { visits, location } = podLocation('/me')
  const stop = watchPodSession(client, location)

  await Promise.allSettled([
    client.fetchQuery({ queryKey: ['code'], queryFn: failure(401, 'invalid_code') }),
    client.fetchQuery({ queryKey: ['forbidden'], queryFn: failure(403, 'unauthorized') }),
    client.fetchQuery({ queryKey: ['network'], queryFn: () => Promise.reject(new Error('offline')) })
  ])
  stop()
  await client.fetchQuery({ queryKey: ['later'], queryFn: failure(401, 'unauthorized') }).catch(() => undefined)

  expect(visits).toEqual([])
})
