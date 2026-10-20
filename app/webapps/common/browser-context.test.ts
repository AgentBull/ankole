import { expect, test } from 'bun:test'
import vectors from '../../kernel/test/vectors/pod_url.json'
import { podLocation, podRouteID } from './browser-context'

const id = '00112233-4455-6677-8899-aabbccddeeff'
const short = 'ABEiM0RVZneImaq7zN3u_w'

type RouteVector = {
  path: string
  query: Record<string, string>
  expected_path: string
  expected_query: Record<string, string>
}

type InvalidRouteVector = { path: string; query: Record<string, string> }

test('Pod browser paths use URL UUIDs without changing durable identity', () => {
  expect(podLocation(`/pages/${id}`)).toEqual({ pathname: `/pages/${short}`, search: '' })
  expect(podLocation(`/conversations/${id}`)).toEqual({ pathname: `/conversations/${short}`, search: '' })
  expect(podLocation(`/pages/${id}`, { chat: id, tenant_id: 'obsolete' })).toEqual({
    pathname: `/pages/${short}`,
    search: `?chat=${short}`
  })
  expect(podRouteID(short)).toBe(id)
  expect(podRouteID(id)).toBe(id)
  expect(podRouteID(`${short.slice(0, -1)}x`)).toBeUndefined()
  expect(podLocation(`/pages/${id}`, { chat: 'new' }).search).toBe('?chat=new')
})

test('Pod browser paths match the shared control-plane vectors', () => {
  for (const route of vectors.routes as RouteVector[]) {
    const location = podLocation(route.path, route.query)
    expect(location.pathname).toBe(route.expected_path)
    expect(Object.fromEntries(new URLSearchParams(location.search))).toEqual(route.expected_query)
  }
})

test('malformed Pod route IDs fail closed', () => {
  for (const route of vectors.invalid_routes as InvalidRouteVector[]) {
    expect(() => podLocation(route.path, route.query)).toThrow('Invalid Pod route ID')
  }
})
