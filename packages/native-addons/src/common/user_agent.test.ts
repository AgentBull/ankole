import { describe, expect, it } from 'bun:test'
import { uaParser } from '../../index.js'

describe('uaParser', () => {
  it('should parse user agent string', () => {
    const ua =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.1.2 Safari/537.36'
    const parsed = uaParser(ua)
    expect(parsed).toBeDefined()
    expect(parsed.name).toBe('Chrome')
    expect(parsed.version).toBe('123.1.2')
    expect(parsed.os).toBe('Mac OSX')
    expect(parsed.osVersion).toBe('10.15.7')
    expect(parsed.browserType).toBe('browser')
  })
})
