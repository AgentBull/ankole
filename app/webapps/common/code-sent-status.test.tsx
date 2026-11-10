import { expect, test } from 'bun:test'
import { devMailboxPath } from './browser-context'

function withDevMailboxMeta(content: string) {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'document')
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: {
      querySelector: (selector: string) => (selector === 'meta[name="ankole-dev-mailbox"]' ? { content } : null)
    }
  })
  try {
    return devMailboxPath()
  } finally {
    if (previous) Object.defineProperty(globalThis, 'document', previous)
    else Reflect.deleteProperty(globalThis, 'document')
  }
}

test('devMailboxPath accepts only origin-relative paths', () => {
  expect(withDevMailboxMeta('/dev/mailbox')).toBe('/dev/mailbox')
  expect(withDevMailboxMeta('//evil.example/mailbox')).toBeUndefined()
  expect(withDevMailboxMeta('https://evil.example/mailbox')).toBeUndefined()
  expect(withDevMailboxMeta('')).toBeUndefined()
})
