import { expect, test } from 'bun:test'
import { workspaceFetchText } from '../src/browser/browser-session'
import { BrowserMaxResponseBytes, successResponse } from '../src/protocol'

test('workspace text preserves a complete article beyond the default fetch prefix', () => {
  const text = `START\n${'ordinary article line\n'.repeat(35_000)}TRUE-ARTICLE-END\n`
  const page = workspaceFetchText(text)
  expect(page).toEqual({ text, total_characters: text.length, stored_characters: text.length })
  expect(page.text.endsWith('TRUE-ARTICLE-END\n')).toBe(true)
})

test('workspace text caps Unicode code points and retains the real bounded tail', () => {
  const text = `${'e\u0301🚀\n'.repeat(600_000)}TRUE-END\n`
  const page = workspaceFetchText(text)
  expect(page.total_characters).toBe(2_400_009)
  expect(page.stored_characters).toBe(2_000_000)
  expect([...page.text].length).toBe(2_000_000)
  expect(page.text.isWellFormed()).toBe(true)
  expect(page.text).not.toContain('TRUE-END')
  expect(page.tail!.endsWith('TRUE-END\n')).toBe(true)
  expect(page.tail!.isWellFormed()).toBe(true)
  expect(Buffer.byteLength(page.tail!)).toBeLessThanOrEqual(160_000)
})

test('one worst-case escaped workspace page fits the actual browser response bound', () => {
  const page = workspaceFetchText(`${'\u0001'.repeat(2_000_001)}REAL-END`)
  const wire = `${JSON.stringify(successResponse({ id: 'fetch', route: 'route', session: 'session' }, { results: [page] }))}\n`
  expect(Buffer.byteLength(wire)).toBeGreaterThan(8 * 1024 * 1024)
  expect(Buffer.byteLength(wire)).toBeLessThan(BrowserMaxResponseBytes)
  expect(page.tail!.endsWith('REAL-END')).toBe(true)
})

test('workspace text rejects malformed Unicode instead of inventing character counts', () => {
  expect(() => workspaceFetchText(`text\ud800`)).toThrow('invalid Unicode')
})
