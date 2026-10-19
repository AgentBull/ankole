import { expect, test } from 'bun:test'
import { resolveRoute, useRoute, useRouteMutation } from '../src/index'

test('route substitution encodes each value as one segment and does not replace query values', () => {
  expect(resolveRoute('POST /orders/:id/items/:item', { id: 'a/b %中文', item: ':id' })).toEqual({
    method: 'POST',
    path: '/orders/a%2Fb%20%25%E4%B8%AD%E6%96%87/items/%3Aid'
  })
  expect(resolveRoute('GET /orders')).toEqual({ method: 'GET', path: '/orders' })
  expect(() => resolveRoute('GET /orders/:id')).toThrow('Missing route parameter: id')
  expect(() => resolveRoute('GET /orders/:id', { id: '' })).toThrow('Missing route parameter: id')
})

test('query and mutation hooks reject the wrong HTTP method before issuing requests', () => {
  // These calls intentionally model untyped JavaScript from an authored applet.
  // @ts-expect-error A read must never automatically retry a write.
  expect(() => useRoute('POST /orders')).toThrow('useRoute requires a GET route')
  // @ts-expect-error Mutations use the non-GET route declarations.
  expect(() => useRouteMutation('GET /orders')).toThrow('useRouteMutation requires a POST, PUT, PATCH or DELETE route')
})
