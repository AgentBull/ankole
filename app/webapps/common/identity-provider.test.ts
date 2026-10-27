import { expect, test } from 'bun:test'
import { unusedProviderID } from './identity-provider'

test('a new connection gets an unused provider ID without changing existing IDs', () => {
  expect(unusedProviderID('lark-main', [])).toBe('lark-main')
  expect(unusedProviderID('lark-main', ['lark-main', 'lark-main-2'])).toBe('lark-main-3')
})
