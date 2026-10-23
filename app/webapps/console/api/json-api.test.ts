import { afterEach, beforeEach, expect, test } from 'bun:test'
import { configureConsoleAPIClient } from './client'
import { client as siteV2Client } from './v2-site/generated/client.gen'
import { client as consoleV2Client } from './v2/generated/client.gen'
import { fromDocument, fromErrors, JSON_API_MEDIA_TYPE } from './json-api'
import { requestErrorCode, requestErrorDetailList, requestErrorMessage } from '../../common/request-errors'

const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
const previousDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
const previousFetch = globalThis.fetch
let requests: Request[]

beforeEach(() => {
  requests = []
  const meta: Record<string, string> = { 'csrf-token': 'csrf-1', 'ankole-authentication': 'account-a.1' }
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: {
      location: { origin: 'https://ankole.test' },
      sessionStorage: { getItem: (key: string) => (key.endsWith('account-a.1') ? 'tenant-a' : null) }
    }
  })
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: {
      querySelector: (selector: string) => {
        const name = /name="([^"]+)"/.exec(selector)?.[1]
        return name && meta[name] ? { content: meta[name] } : null
      }
    }
  })
})

afterEach(() => {
  globalThis.fetch = previousFetch
  for (const [name, descriptor] of [
    ['window', previousWindow],
    ['document', previousDocument]
  ] as const) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor)
    else Reflect.deleteProperty(globalThis, name)
  }
})

function respond(status: number, body: unknown, contentType = JSON_API_MEDIA_TYPE) {
  globalThis.fetch = (async (request: Request) => {
    requests.push(request)
    return new Response(JSON.stringify(body), { status, headers: { 'content-type': contentType } })
  }) as typeof fetch
}

test('a document becomes the flat Console record or record list', () => {
  const tenant = { id: 't-1', type: 'tenant', attributes: { name: 'Acme', status: 'active' } }

  expect(fromDocument({ data: tenant })).toEqual({ id: 't-1', name: 'Acme', status: 'active' })
  expect(fromDocument({ data: [tenant, { id: 't-2', type: 'tenant' }] })).toEqual([
    { id: 't-1', name: 'Acme', status: 'active' },
    { id: 't-2' }
  ])
})

test('JSON:API errors get the Console failure shape and other payloads stay the same', () => {
  const rejected = fromErrors({
    errors: [
      { status: '422', code: 'tenant_slug_taken', title: 'Rejected', detail: 'the domain operation was rejected' }
    ]
  })
  expect(requestErrorCode(rejected)).toBe('tenant_slug_taken')
  expect(requestErrorMessage(rejected)).toBe('the domain operation was rejected')

  const invalid = fromErrors({
    errors: [
      { code: 'required', detail: 'is required', source: { pointer: '/data/attributes/name' } },
      { code: 'invalid_attribute', detail: 'is invalid', source: { pointer: '/data/attributes/slug' } },
      { code: 'required', detail: 'is required', source: { pointer: '/data/label' } }
    ]
  })
  expect(requestErrorCode(invalid)).toBe('validation_failed')
  expect(requestErrorDetailList(invalid)).toEqual([
    { path: 'name', message: 'is required' },
    { path: 'slug', message: 'is invalid' },
    { path: 'label', message: 'is required' }
  ])

  const unauthorized = { error: { code: 'unauthorized', message: 'active administrator session required' } }
  expect(fromErrors(unauthorized)).toBe(unauthorized)
  expect(fromErrors({ errors: { detail: 'Internal Server Error' } })).toEqual({
    errors: { detail: 'Internal Server Error' }
  })
})

test('the v2 clients send JSON:API requests with the Console session and data context', async () => {
  respond(200, { data: [] })
  configureConsoleAPIClient()

  await consoleV2Client.get({ url: '/api/v2/agents', throwOnError: true })
  await siteV2Client.get({ url: '/api/v2/site/tenants', throwOnError: true })

  expect(
    requests.map(request => [
      request.url,
      request.headers.get('accept'),
      request.headers.get('x-csrf-token'),
      request.headers.get('x-ankole-authentication'),
      request.headers.get('x-ankole-tenant')
    ])
  ).toEqual([
    ['https://ankole.test/api/v2/agents', JSON_API_MEDIA_TYPE, 'csrf-1', 'account-a.1', 'tenant-a'],
    ['https://ankole.test/api/v2/site/tenants', JSON_API_MEDIA_TYPE, 'csrf-1', 'account-a.1', null]
  ])
})

test('a v2 client failure has the Console failure shape', async () => {
  respond(409, { errors: [{ status: '409', code: 'conflict', detail: 'reload it and try again' }] })
  configureConsoleAPIClient()

  const error = await consoleV2Client.get({ url: '/api/v2/agents', throwOnError: true }).catch(error => error)

  expect(error).toEqual({ error: { code: 'conflict', message: 'reload it and try again', details: [] } })
})
