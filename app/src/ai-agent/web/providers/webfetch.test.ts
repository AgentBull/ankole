import { describe, expect, it } from 'bun:test'
import { __webfetchInternals, webfetchProvider } from './webfetch'

describe('webfetch UA sampling', () => {
  it('returns a stable UA per domain until the cache expires', () => {
    const { sampleUserAgent, uaCache } = __webfetchInternals
    uaCache.clear()
    const first = sampleUserAgent('example.com')
    const second = sampleUserAgent('example.com')
    expect(first).toBe(second)
    expect(first).toContain('Mozilla')

    uaCache.set('example.com', { ua: 'STALE-UA', expiresAt: Date.now() - 1 })
    expect(sampleUserAgent('example.com')).not.toBe('STALE-UA')
  })
})

describe('webfetch html helpers', () => {
  it('extracts decoded HTML titles and only treats real HTML-looking bodies as HTML', () => {
    expect(__webfetchInternals.extractTitle('<html><head><title>Hello &amp; Bye</title></head></html>')).toBe(
      'Hello & Bye'
    )
    expect(__webfetchInternals.extractTitle('<html><body>no title</body></html>')).toBe('')
    expect(__webfetchInternals.looksLikeHtml('<!DOCTYPE html><html><body>x</body></html>')).toBe(true)
    expect(__webfetchInternals.looksLikeHtml('{"json":true}')).toBe(false)
  })
})

describe('webfetchProvider.extract', () => {
  it('fetches html and returns the title plus markdown', async () => {
    const server = Bun.serve({
      port: 0,
      fetch: () =>
        new Response(
          '<html><head><title>Doc Title</title></head><body><main><h1>Hi</h1><p>body text</p></main></body></html>',
          { headers: { 'content-type': 'text/html' } }
        )
    })
    try {
      const results = (await webfetchProvider.extract?.({ urls: [`http://localhost:${server.port}/`] })) ?? []
      expect(results[0]?.title).toBe('Doc Title')
      expect(results[0]?.text).toContain('Hi')
      expect(results[0]?.text).toContain('body text')
      expect(results[0]?.error).toBeUndefined()
    } finally {
      server.stop()
    }
  })

  it('records a per-URL error on a failing status without throwing', async () => {
    const server = Bun.serve({ port: 0, fetch: () => new Response('nope', { status: 500 }) })
    try {
      const results = (await webfetchProvider.extract?.({ urls: [`http://localhost:${server.port}/`] })) ?? []
      expect(results[0]?.error).toContain('HTTP 500')
    } finally {
      server.stop()
    }
  })

  it('records an error for an invalid URL', async () => {
    const results = (await webfetchProvider.extract?.({ urls: ['not-a-url'] })) ?? []
    expect(results[0]?.error).toBe('invalid URL')
  })

  it('rejects non-textual content types instead of returning garbage', async () => {
    const server = Bun.serve({
      port: 0,
      fetch: () => new Response('％PDF-1.7 binary', { headers: { 'content-type': 'application/pdf' } })
    })
    try {
      const results = (await webfetchProvider.extract?.({ urls: [`http://localhost:${server.port}/`] })) ?? []
      expect(results[0]?.error).toContain('unsupported content type')
    } finally {
      server.stop()
    }
  })
})
