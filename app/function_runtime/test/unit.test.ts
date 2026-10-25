import { describe, expect, test } from 'bun:test'
import { CodeCache } from '../main/code_cache.ts'
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
