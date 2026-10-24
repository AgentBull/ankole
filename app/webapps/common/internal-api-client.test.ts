import { afterEach, beforeEach, expect, test } from 'bun:test'
import { client } from './api/generated/client.gen'
import { createSetupSession, verifyEmailOtp } from './api/generated/sdk.gen'
import { podAgents, conversationDetail } from '../pod/api/generated/sdk.gen'
import { client as podClient } from '../pod/api/generated/client.gen'
import { InternalAPIError } from './internal-api-client'
import { classifyLoginError } from '../auth/state/login-model'
import { conversationNotFound } from '../pod/api'

const originalFetch = globalThis.fetch
const originalDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
let token: string | undefined
beforeEach(() => {
  token = 'first-token'
  client.setConfig({ baseUrl: 'https://ankole.test' })
  podClient.setConfig({ baseUrl: 'https://ankole.test' })
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: {
      querySelector: () => (token ? { content: token } : null)
    }
  })
})
afterEach(() => {
  globalThis.fetch = originalFetch
  if (originalDocument) Object.defineProperty(globalThis, 'document', originalDocument)
  else Reflect.deleteProperty(globalThis, 'document')
})

test('generated operations return payloads and read the current CSRF token for every same-origin request', async () => {
  const requests: Request[] = []
  globalThis.fetch = (async (request: Request) => {
    requests.push(request)
    return Response.json({ ok: true })
  }) as typeof fetch
  expect(await createSetupSession({ body: { data: { activation_code: 'CODE', locale: 'en-US' } } })).toEqual({
    ok: true
  })
  token = 'second-token'
  await podAgents()
  expect(
    requests.map(request => [new URL(request.url).pathname, request.method, request.headers.get('x-csrf-token')])
  ).toEqual([
    ['/api/v2/browser/setup/sessions', 'POST', 'first-token'],
    ['/api/v2/pod/agents', 'GET', 'second-token']
  ])
  expect(await requests[0]!.json()).toEqual({ data: { activation_code: 'CODE', locale: 'en-US' } })
  expect(client.getConfig().credentials).toBe('same-origin')
  expect(requests.every(request => request.headers.get('x-ankole-tenant') === null)).toBe(true)
  token = undefined
  await expect(podAgents()).rejects.toThrow('CSRF token is missing')
  expect(requests).toHaveLength(2)
})

test.each([
  [401, { errors: [{ code: 'invalid_code' }] }],
  [403, { errors: [{ code: 'not_an_admin' }] }],
  [429, { errors: [{ code: 'rate_limited', meta: { details: { retryAfterSeconds: 30 } } }] }],
  [404, { error: { code: 'conversation_not_found', message: 'Conversation not found' } }]
])(
  'HTTP %s preserves InternalAPIError status, payload, rejection and product classification',
  async (status, payload) => {
    globalThis.fetch = (async (_request: Request) => Response.json(payload, { status })) as typeof fetch
    const error = await conversationDetail({ path: { id: 'gone' } }).catch(error => error)
    expect(error).toBeInstanceOf(InternalAPIError)
    expect(error.status).toBe(status)
    expect(error.payload).toEqual(payload)
    expect(conversationNotFound(error)).toBe(status === 404)
    if (status === 429) expect(classifyLoginError(error)?.kind).toBe('locked')
  }
)

test('structured API failures render their message while preserving the error code and response', async () => {
  const payload = { error: { code: 'creation_unavailable', message: 'Creation unavailable' } }
  globalThis.fetch = (async (_request: Request) => Response.json(payload, { status: 503 })) as typeof fetch
  const error = await conversationDetail({ path: { id: 'unavailable' } }).catch(error => error)
  expect(error).toBeInstanceOf(InternalAPIError)
  expect(error.message).toBe('Creation unavailable')
  expect(error.status).toBe(503)
  expect(error.payload).toEqual(payload)
  expect(conversationNotFound(error)).toBe(false)
})

test.each([
  ['', {}],
  ['upstream unavailable', 'upstream unavailable']
])('empty and non-JSON error bodies preserve payloads', async (body, payload) => {
  globalThis.fetch = (async (_request: Request) =>
    new Response(body, { status: 503, statusText: 'Unavailable' })) as typeof fetch
  await expect(
    verifyEmailOtp({ body: { data: { code: '123456', challengeID: 'challenge-id', flow: 'login-flow' } } })
  ).rejects.toMatchObject({
    name: 'InternalAPIError',
    status: 503,
    payload
  })
})

test('network rejection keeps the original error identity', async () => {
  const offline = new TypeError('offline')
  globalThis.fetch = (async (_request: Request): Promise<Response> => {
    throw offline
  }) as typeof fetch
  await expect(podAgents()).rejects.toBe(offline)
})

test('a JSON:API error document renders the text of its first error', async () => {
  const payload = {
    errors: [{ status: '404', code: 'not_found', title: 'NotFound', detail: 'the resource was not found' }]
  }
  globalThis.fetch = (async (_request: Request) => Response.json(payload, { status: 404 })) as typeof fetch
  const error = await conversationDetail({ path: { id: 'gone' } }).catch(error => error)
  expect(error).toBeInstanceOf(InternalAPIError)
  expect(error.message).toBe('the resource was not found')
  expect(error.payload).toEqual(payload)
})
