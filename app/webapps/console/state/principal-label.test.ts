import { expect, test } from 'bun:test'
import { principalLabel } from './principal-label'

const principal = { display_name: null, email: null, id: 'research' }

test('uses display name, email, then the meaningful uid', () => {
  expect(principalLabel({ ...principal, display_name: 'Research', email: 'mail@example.test' })).toBe('Research')
  expect(principalLabel({ ...principal, email: 'mail@example.test' })).toBe('mail@example.test')
  expect(principalLabel(principal)).toBe('research')
})
