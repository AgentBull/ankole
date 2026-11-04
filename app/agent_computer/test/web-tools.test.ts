import { mkdirAgentSync } from '../src/common/agent-user'
import { createContainerComputer } from '../src/tools/computer/computer'
import { describe, expect, it } from 'bun:test'
import { createWebTools, renderedFallbackFetch } from '../src/tools/web/web-tools'
import {
  create,
  createEnvelope,
  encodeEnvelope,
  jsonBytes,
  jsonObjectFromBytes,
  RPCRequestSchema
} from '../src/fabric/envelope_proto'
import { toBinary } from '@bufbuild/protobuf'
import { ReadToolRequestSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { RPCRequester } from '../src/lanes/rpc_lane'
import { jobTurnRefToProto, type JobTurnRef } from '../src/lanes/session_lane'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { readTool, updateReadToolCache } from '../src/core/read-tools'
import type { JsonObject } from '@agentbull/active-support'

const turn: JobTurnRef = { session: { session_id: 'job:1000' }, job_id: 1000, attempt: 1, signal_id: 'input-1' }
const unusedRPC = (async () => {
  throw new Error('unexpected RPC')
}) as unknown as RPCRequester

describe('Job web tools adapter', () => {
  it('keeps a rendered continuation inside one real protobuf frame without resending the expired page', async () => {
    const url = 'https://example.com/long'
    const signal = new AbortController().signal
    const text = '\u0001'.repeat(2_000_000)
    const rendered = {
      results: [
        {
          url,
          text,
          total_characters: 2_000_009,
          stored_characters: 2_000_000,
          tail: `${'\u0001'.repeat(159_992)}REAL-END`,
          metadata: { source: 'rendered_fallback' }
        }
      ]
    }
    const cache = { [url]: { at: 1, page: { text } } }
    let calls = 0
    const rpc = (async (_method: unknown, value: unknown, scope: unknown) => {
      expect(scope).toEqual({ jobTurn: turn })
      const payload = value as {
        name: string
        argumentsJson: Uint8Array
        webCacheJson?: Uint8Array
        renderedBodyJson?: Uint8Array
      }
      const wire = encodeEnvelope(
        createEnvelope({
          body: {
            case: 'rpcRequest',
            value: create(RPCRequestSchema, {
              requestId: 'read',
              method: 'tools.read',
              jobTurn: jobTurnRefToProto(turn),
              payload: toBinary(ReadToolRequestSchema, create(ReadToolRequestSchema, payload))
            })
          }
        })
      )
      expect(wire.byteLength).toBeLessThan(16 * 1024 * 1024 - 1025)
      if (++calls === 1) {
        expect(jsonObjectFromBytes(payload.webCacheJson!, 'cache')).toEqual(cache)
        return { bodyJson: jsonBytes({ delegate: { name: '__rendered_web_fetch', arguments: { urls: [url] } } }) }
      }
      expect(payload.webCacheJson).toBeUndefined()
      expect(jsonObjectFromBytes(payload.renderedBodyJson!, 'rendered')).toEqual(rendered)
      expect(payload.renderedBodyJson!.byteLength).toBeGreaterThan(8 * 1024 * 1024)
      return { bodyJson: jsonBytes({ output: '', details: { results: [] } }) }
    }) as unknown as RPCRequester
    await readTool(
      rpc,
      turn,
      'web_fetch',
      { urls: [url], _workspace_page: 0 },
      {
        cache,
        signal,
        renderedFetch: async (urls, receivedSignal) => {
          expect(urls).toEqual([url])
          expect(receivedSignal).toBe(signal)
          return rendered
        }
      }
    )
    expect(calls).toBe(2)
    expect(cache[url]!.at).toBe(1)
  })

  it('keeps workspace browser counts and the original tail and refuses a silently truncated result', async () => {
    const body = 'a'.repeat(2_000_000)
    const tail = 'ORIGINAL-END\n'
    const result = await renderedFallbackFetch(
      ['https://example.com/long'],
      {
        fetchBatch: async (urls, _signal, mode) => {
          expect(urls).toEqual(['https://example.com/long'])
          expect(mode).toBe('workspace')
          return { results: [{ text: body, total_characters: 3_000_000, stored_characters: body.length, tail }] }
        }
      },
      undefined,
      'workspace'
    )
    expect(result.results).toMatchObject([
      { text: body, total_characters: 3_000_000, stored_characters: body.length, tail }
    ])
    const invalid = await renderedFallbackFetch(
      ['https://example.com/long'],
      {
        fetchBatch: async () => ({ results: [{ text: 'unknown truncated prefix' }] })
      },
      undefined,
      'workspace'
    )
    expect(invalid.results).toMatchObject([{ error: 'Invalid workspace page counts or tail from the browser' }])
  })

  it('bounds the existing cache to its 100 newest owner-returned pages', () => {
    const cache: JsonObject = {}
    for (let at = 0; at < 101; at++) updateReadToolCache(cache, { [`url-${at}`]: { at, page: { text: 'page' } } })
    expect(Object.keys(cache)).toHaveLength(100)
    expect(cache['url-0']).toBeUndefined()
    expect(cache['url-100']).toBeDefined()
  })

  it('never caches failed or degraded workspace pages', async () => {
    for (const failure of [{ error: '' }, { render_warning: 'script_shell' }]) {
      let calls = 0
      const rpc = (async (_method: unknown, payload: unknown) => {
        calls++
        const request = payload as { webCacheJson: Uint8Array }
        expect(jsonObjectFromBytes(request.webCacheJson, 'cache')).toEqual({})
        return {
          bodyJson: jsonBytes({
            output: '',
            details: {
              results: [{ url: 'https://example.com', text: '', total_characters: 0, stored_characters: 0, ...failure }]
            },
            web_cache: {}
          })
        }
      }) as unknown as RPCRequester
      const fetch = (
        await createWebTools({
          rpc,
          turn,
          workspaceRoot: '/unused',
          computer: createContainerComputer('/unused', '/unused')
        })
      )[1]!
      await fetch.execute('first', { urls: ['https://example.com'] })
      await fetch.execute('repeat', { urls: ['https://example.com'] })
      expect(calls).toBe(2)
    }
  })

  it('reuses a multi-URL workspace cache with one selected page per bounded RPC frame', async () => {
    const root = mkdtempSync(join(tmpdir(), 'web-cache-'))
    mkdirAgentSync(root, 0o700)
    const urls = Array.from({ length: 5 }, (_, index) => `https://example.com/${index}`)
    const body = '\0'.repeat(2_000_000)
    const hits = new Map<string, number>()
    let calls = 0
    const rpc = (async (_method: unknown, payload: unknown) => {
      calls++
      const request = payload as { argumentsJson: Uint8Array; webCacheJson: Uint8Array }
      const args = jsonObjectFromBytes(request.argumentsJson, 'args')!
      expect(args.urls).toEqual(urls)
      const url = urls[Number(args._workspace_page)]!
      const cache = jsonObjectFromBytes(request.webCacheJson, 'cache')!
      const keys = Object.keys(cache)
      expect(keys).toEqual(calls <= urls.length ? [] : [url])
      expect(request.argumentsJson.byteLength + request.webCacheJson.byteLength).toBeLessThan(16 * 1024 * 1024)
      const cached = cache[url] as { at: number; page: JsonObject } | undefined
      if (cached) expect(cached.at).toBe(1700000000000)
      if (!cached) hits.set(url, (hits.get(url) || 0) + 1)
      const page = cached?.page || {
        url,
        text: body,
        total_characters: 2_000_000,
        stored_characters: 2_000_000,
        source: 'jina_reader'
      }
      return {
        bodyJson: jsonBytes({
          output: '',
          details: { results: [{ ...page, repeat_fetch: Boolean(cached), cache_at: 1700000000000 }] },
          web_cache: {}
        })
      }
    }) as unknown as RPCRequester
    try {
      const fetch = (
        await createWebTools({ rpc, turn, workspaceRoot: root, computer: createContainerComputer(root, root) })
      )[1]!
      const first = await fetch.execute('first', { urls })
      const repeated = await fetch.execute('repeat', { urls })
      expect(calls).toBe(10)
      expect([...hits.values()]).toEqual([1, 1, 1, 1, 1])
      expect(first.content[0]).toMatchObject({ text: expect.stringContaining('Cached repeat: false.') })
      expect(repeated.content[0]).toMatchObject({
        text: expect.stringContaining('Source: jina_reader\nCached repeat: true.')
      })
      expect(
        (repeated.details.results as JsonObject[]).every(
          page => page.repeat_fetch === true && page.source === 'jina_reader'
        )
      ).toBe(true)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it('keeps a stable catalog without I/O and accepts long queries and HTTPS URLs', async () => {
    const tools = await createWebTools({
      rpc: unusedRPC,
      turn,
      workspaceRoot: '/unused',
      computer: createContainerComputer('/unused', '/unused')
    })
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
    expect(() => tools[1]!.schema.parse({ urls: ['https://example.com'], _workspace_page: 0 })).toThrow()
  })

  it('carries the Job attempt, cancellation and original batch while transferring one page at a time', async () => {
    const args: unknown[] = []
    const signal = new AbortController().signal
    const urls = ['https://example.com/first', 'https://example.com/second']
    const rpc = (async (method: unknown, payload: unknown, scope: unknown, options?: unknown) => {
      expect(method).toBe('tools.read')
      expect(scope).toEqual({ jobTurn: turn })
      expect(options).toMatchObject({ signal, retryOnDisconnect: true, timeoutMs: 180000 })
      const request = payload as { name: string; argumentsJson: Uint8Array; webCacheJson?: Uint8Array }
      args.push(jsonObjectFromBytes(request.argumentsJson, 'args'))
      expect(jsonObjectFromBytes(request.webCacheJson!, 'cache')).toEqual({})
      return {
        bodyJson: jsonBytes({
          output: '',
          details: {
            results: [
              {
                url: urls[args.length - 1],
                text: 'full page',
                total_characters: 9,
                stored_characters: 9,
                cache_at: 1700000000000
              }
            ]
          }
        })
      }
    }) as unknown as RPCRequester
    const fetch = (
      await createWebTools({
        rpc,
        turn,
        workspaceRoot: '/unused',
        computer: createContainerComputer('/unused', '/unused')
      })
    )[1]!
    const result = await fetch.execute('batch', { urls }, signal)
    expect(args).toEqual([
      { urls, _workspace_page: 0 },
      { urls, _workspace_page: 1 }
    ])
    expect(result.content[0]).toMatchObject({ type: 'text', text: expect.stringContaining('full page') })
    expect(result.details.results).toHaveLength(2)
    expect(JSON.stringify(result.details)).not.toContain('full page')
  })

  it('sends browser output back to the owner for the same result projection', async () => {
    const urls = ['https://example.com', 'https://192.168.1.20/']
    let calls = 0
    const rpc = (async (_method: unknown, payload: unknown) => {
      const request = payload as { renderedBodyJson?: Uint8Array }
      if (++calls % 2 === 1) {
        return {
          bodyJson: jsonBytes({
            delegate: { name: '__rendered_web_fetch', arguments: { urls: [urls[(calls - 1) / 2]] } }
          })
        }
      }
      const body = jsonObjectFromBytes(request.renderedBodyJson!, 'rendered')!
      expect(body).toMatchObject({
        source: 'rendered_fallback',
        results:
          calls === 2
            ? [{ url: urls[0], text: 'public page' }]
            : [{ url: urls[1], error: 'blocked non-public URL by the security.ssrf_filter policy' }]
      })
      const page =
        calls === 2
          ? { url: urls[0], text: 'public page', total_characters: 11, stored_characters: 11, cache_at: 1700000000000 }
          : {
              url: urls[1],
              text: '',
              error: 'blocked non-public URL by the security.ssrf_filter policy',
              total_characters: 0,
              stored_characters: 0
            }
      return { bodyJson: jsonBytes({ output: '', details: { results: [page] } }) }
    }) as unknown as RPCRequester
    const fetch = (
      await createWebTools({
        rpc,
        turn,
        workspaceRoot: '/unused',
        computer: createContainerComputer('/unused', '/unused'),
        renderedFallback: {
          fetchBatch: async received => {
            expect(received).toEqual([urls[calls === 1 ? 0 : 1]!])
            return {
              results:
                calls === 1
                  ? [{ text: 'public page', total_characters: 11, stored_characters: 11 }]
                  : [{ error: 'blocked non-public URL by the security.ssrf_filter policy' }]
            }
          }
        }
      })
    )[1]!
    const result = await fetch.execute('call', { urls })
    expect(result.content[0]).toMatchObject({ text: expect.stringContaining('public page') })
    expect(result.details.results).toMatchObject([
      {},
      { error: 'blocked non-public URL by the security.ssrf_filter policy' }
    ])
    expect(calls).toBe(4)
  })

  it('propagates owner errors and preserves per-page failures and cancellation', async () => {
    const tools = await createWebTools({
      turn,
      workspaceRoot: '/unused',
      computer: createContainerComputer('/unused', '/unused'),
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
