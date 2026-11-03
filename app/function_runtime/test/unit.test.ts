import { describe, expect, test } from 'bun:test'
import { CodeCache } from '../main/code_cache.ts'
import { InvocationCapacity } from '../main/capacity.ts'
import { matchRoute, validateRoutes } from '../main/routes.ts'

describe('Applet routes', () => {
  test('literal paths win over parameters and parameters decode once', () => {
    const routes = validateRoutes({ 'GET /orders/:id': () => {}, 'GET /orders/new': () => {} })
    expect(matchRoute(routes, 'GET', '/orders/new').route?.key).toBe('GET /orders/new')
    expect(matchRoute(routes, 'GET', '/orders/a%2Fb').params).toEqual({ id: 'a/b' })
    expect(matchRoute(routes, 'POST', '/orders/new').status).toBe(405)
    expect(matchRoute(routes, 'GET', '/orders/%').status).toBe(400)
  })
  test('conflicting route patterns are rejected', () => {
    expect(() => validateRoutes({ 'GET /:a': () => {}, 'GET /:b': () => {} })).toThrow('conflicting')
  })
})

test('code cache evicts least recently used entries within its byte budget', () => {
  const cache = new CodeCache(65)
  cache.put('a', { source: 'a', env: {} })
  cache.put('b', { source: 'b', env: {} })
  cache.get('a')
  cache.put('c', { source: 'c', env: {} })
  expect(cache.get('a')?.source).toBe('a')
  expect(cache.get('b')).toBeUndefined()
  expect(cache.get('c')?.source).toBe('c')
})

test('the configured concurrency ceiling applies across foreground and background work', () => {
  const capacity = new InvocationCapacity(24, 6, 1536, 2)
  const route = capacity.acquire('route', 128)!
  const action = capacity.acquire('action', 192)!
  expect(capacity.acquire('route', 1)).toBeNull()
  expect(capacity.acquire('action', 1)).toBeNull()
  action()
  expect(capacity.acquire('route', 128)).not.toBeNull()
  route()
})

test('foreground reservations count toward their headroom without wasting the shared heap budget', () => {
  const capacity = new InvocationCapacity()
  const routes = Array.from({ length: 4 }, () => capacity.acquire('route', 128))
  const actions = Array.from({ length: 5 }, () => capacity.acquire('action', 192))
  expect([...routes, ...actions].every(Boolean)).toBe(true)
  expect(capacity.usedHeapMb).toBe(1472)
  expect(capacity.acquire('action', 192)).toBeNull()
  routes.forEach(release => release!())
  const sixth = capacity.acquire('action', 192)
  expect(sixth).not.toBeNull()
  expect(capacity.acquire('action', 1)).toBeNull()
  expect(capacity.acquire('route', 128)).not.toBeNull()
  sixth!()
  sixth!()
  actions.forEach(release => release!())
  expect(capacity.usedHeapMb).toBe(128)
})
