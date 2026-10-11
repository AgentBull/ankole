import { expect, test } from 'bun:test'
import { principalLabel } from './principal-label'

const principal = { display_name: null, email: null, handle: null, uid: 'opaque-uid' }

test('uses the display name before other identifiers', () => {
  expect(principalLabel({ ...principal, display_name: 'Name', email: 'mail@example.test', handle: 'handle' })).toBe(
    'Name'
  )
})
test('uses email before handle and UID', () => {
  expect(principalLabel({ ...principal, email: 'mail@example.test', handle: 'handle' })).toBe('mail@example.test')
})
test('uses handle before UID', () => {
  expect(principalLabel({ ...principal, handle: 'handle' })).toBe('handle')
})
test('uses UID when the other names are absent', () => {
  expect(principalLabel(principal)).toBe('opaque-uid')
})
test('preserves an empty display name', () => {
  expect(principalLabel({ ...principal, display_name: '', email: 'mail@example.test' })).toBe('')
})
