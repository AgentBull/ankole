import { expect, test } from 'bun:test'
import { podLocation, podRouteID } from './browser-context'

const id = '00112233-4455-6677-8899-aabbccddeeff'
const short = 'ABEiM0RVZneImaq7zN3u_w'

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
