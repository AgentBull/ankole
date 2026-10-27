import { describe, expect, it } from 'bun:test'
import { createWebTools, renderedFallbackFetch } from '../src/tools/web/web-tools'
import { jsonBytes, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import type { RPCRequester } from '../src/lanes/rpc_lane'
import type { JobTurnRef } from '../src/lanes/session_lane'

const turn: JobTurnRef = { session: { session_id: 'job:1000' }, job_id: 1000, attempt: 1, signal_id: 'input-1' }
const unusedRPC = (async () => {
  throw new Error('unexpected RPC')
}) as unknown as RPCRequester

describe('Job web tools adapter', () => {
  it('keeps a stable catalog without I/O and accepts long queries and HTTPS URLs', async () => {
    const tools = await createWebTools({ rpc: unusedRPC, turn })
    expect(tools.map(tool => tool.name)).toEqual(['web_search', 'web_fetch'])
    expect(tools[0]!.schema.parse({ query: 'q'.repeat(5000) })).toEqual({ query: 'q'.repeat(5000) })
    expect(() => tools[0]!.schema.parse({ query: '' })).toThrow()
    for (const url of ['https://example.com', 'HTTPS://EXAMPLE.COM', 'https://[::1]/']) {
      expect(() => tools[1]!.schema.parse({ urls: [url] })).not.toThrow()
    }
    for (const url of ['http://example.com', 'not a URL', 'data:text/plain,hi']) {
      expect(() => tools[1]!.schema.parse({ urls: [url] })).toThrow()
    }
    expect(() => tools[1]!.schema.parse({ urls: ['https://example.com'], result_offset: -1 })).toThrow()
  })

  it('carries the Job attempt, cancellation and page cache through successive byte windows', async () => {
    const args: unknown[] = []
    const signal = new AbortController().signal
    const cache = { 'https://example.com': { at: Date.now(), page: { text: 'full page' } } }
    const rpc = (async (method: unknown, payload: unknown, scope: unknown, options?: unknown) => {
      expect(method).toBe('tools.read')
      expect(scope).toEqual({ jobTurn: turn })
      expect(options).toMatchObject({ signal, retryOnDisconnect: true, timeoutMs: 180000 })
      const request = payload as { name: string; argumentsJson: Uint8Array; webCacheJson: Uint8Array }
      args.push(jsonObjectFromBytes(request.argumentsJson, 'args'))
      expect(jsonObjectFromBytes(request.webCacheJson, 'cache')).toEqual(args.length === 1 ? {} : cache)
      return { bodyJson: jsonBytes({ output: 'bounded page window', details: { results: [] }, web_cache: cache }) }
    }) as unknown as RPCRequester
    const fetch = (await createWebTools({ rpc, turn }))[1]!
    await fetch.execute('first', { urls: ['https://example.com'] }, signal)
    const result = await fetch.execute('next', { urls: ['https://example.com'], result_offset: 800 }, signal)
    expect(args).toEqual([{ urls: ['https://example.com'] }, { urls: ['https://example.com'], result_offset: 800 }])
    expect(result.content[0]).toEqual({ type: 'text', text: 'bounded page window' })
  })

  it('sends browser output back to the owner for the same result projection', async () => {
    const urls = ['https://example.com', 'https://192.168.1.20/']
    let calls = 0
    const rpc = (async (_method: unknown, payload: unknown) => {
      const request = payload as { renderedBodyJson?: Uint8Array }
      if (++calls === 1) {
        return { bodyJson: jsonBytes({ delegate: { name: '__rendered_web_fetch', arguments: { urls } } }) }
      }
      const body = jsonObjectFromBytes(request.renderedBodyJson!, 'rendered')!
      expect(body).toMatchObject({
        source: 'rendered_fallback',
        success: false,
        results: [
          { url: urls[0], text: 'public page' },
          { url: urls[1], error: 'blocked non-public URL by the security.ssrf_filter policy' }
        ]
      })
      return { bodyJson: jsonBytes({ output: 'owner-projected result', details: body }) }
    }) as unknown as RPCRequester
    const fetch = (
      await createWebTools({
        rpc,
        turn,
        renderedFallback: {
          fetchBatch: async received => {
            expect(received).toEqual(urls)
            return {
              results: [{ text: 'public page' }, { error: 'blocked non-public URL by the security.ssrf_filter policy' }]
            }
          }
        }
      })
    )[1]!
    expect((await fetch.execute('call', { urls })).content[0]).toEqual({ type: 'text', text: 'owner-projected result' })
    expect(calls).toBe(2)
  })

  it('propagates owner errors and preserves per-page failures and cancellation', async () => {
    const tools = await createWebTools({
      turn,
      rpc: (async () => {
        throw new Error('provider unavailable')
      }) as unknown as RPCRequester
    })
    await expect(tools[0]!.execute('search', { query: 'ankole' })).rejects.toThrow('provider unavailable')
    const body = await renderedFallbackFetch(['https://example.com', 'http://invalid.test'], {
      fetchBatch: async () => ({ results: [{ text: 'valid' }] })
    })
    expect(body).toMatchObject({
      success: false,
      results: [{ text: 'valid' }, { error: 'Only HTTPS URLs are supported.' }]
    })
    const unavailable = await renderedFallbackFetch(['https://example.com'], {
      fetchBatch: async () => {
        throw new Error('ankole-browser daemon unavailable')
      }
    })
    expect(unavailable).toMatchObject({ results: [{ error: 'ankole-browser daemon unavailable' }] })
    const timedOut = await renderedFallbackFetch(['https://example.com'], {
      fetchBatch: async () => {
        throw new Error('Playwright navigation timed out after 30000 ms')
      }
    })
    expect(timedOut).toMatchObject({ results: [{ error: 'Playwright navigation timed out after 30000 ms' }] })
    const pageFailure = await renderedFallbackFetch(['https://example.com'], {
      fetchBatch: async () => ({ results: [{ error: 'playwright browser session unavailable' }] })
    })
    expect(pageFailure).toMatchObject({ results: [{ error: 'playwright browser session unavailable' }] })
    const abort = new AbortController()
    abort.abort()
    await expect(
      renderedFallbackFetch(['https://example.com'], { fetchBatch: async () => ({}) }, abort.signal)
    ).rejects.toThrow('aborted')
  })
})
