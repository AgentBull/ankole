import { expect, test } from 'bun:test'
import { limitPageTitle } from './content-api'

test('a Page title keeps 255 code points without splitting a character', () => {
  const emoji = '😀'.repeat(255)
  expect(limitPageTitle(emoji)).toBe(emoji)
  expect(limitPageTitle(`${emoji}😀`)).toBe(emoji)
  // Each accented letter is one grapheme cluster of two code points, as the control plane counts them
  expect(limitPageTitle('é'.repeat(128))).toBe('é'.repeat(127))
  expect(limitPageTitle('short')).toBe('short')
})

test('an edit over the limit keeps the existing title and shortens only the inserted text', () => {
  const previous = 'a'.repeat(250)
  expect(limitPageTitle(`${'x'.repeat(10)}${previous}`, previous)).toBe(`${'x'.repeat(5)}${previous}`)
  // A family emoji is one grapheme cluster of five code points
  const family = '👨‍👩‍👧'
  expect(limitPageTitle(`a${family.repeat(2)}${previous.slice(1)}`, previous)).toBe(`a${family}${previous.slice(1)}`)
})

test('a legacy title above the limit can still lose text', () => {
  const legacy = 'a'.repeat(300)
  expect(limitPageTitle(legacy.slice(1), legacy)).toBe(legacy.slice(1))
  expect(limitPageTitle(`${legacy}b`, legacy)).toBe(legacy)
})
