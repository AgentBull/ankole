import { expect, test } from 'bun:test'
import { devMailboxPath, identityHeaders, podLocation, podRouteID } from './browser-context'

const id = '00112233-4455-6677-8899-aabbccddeeff'
const short = '0024h36h2ncsvrh6daqf6dvvqz'

test('browser context re-exports canonical Pod route helpers and omits absent document metadata', () => {
  expect(podLocation(`/pages/${id}`)).toEqual({ pathname: `/pages/${short}`, search: '' })
  expect(podRouteID(short)).toBe(id)
  expect(devMailboxPath()).toBeUndefined()
  expect(identityHeaders()).toEqual({})
})
