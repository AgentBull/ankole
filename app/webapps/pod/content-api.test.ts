import { expect, test } from 'bun:test'
import { limitPageTitle } from './content-api'

test('a Page title keeps 255 characters as people see them, not UTF-16 units', () => {
  const emoji = '😀'.repeat(255)
  expect(limitPageTitle(emoji)).toBe(emoji)
  expect(limitPageTitle(`${emoji}😀`)).toBe(emoji)
  const family = '👨‍👩‍👧'.repeat(256)
  expect([...new Intl.Segmenter().segment(limitPageTitle(family))]).toHaveLength(255)
  expect(limitPageTitle('short')).toBe('short')
})
