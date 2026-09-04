import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import type { AIGatewayHTTPClient } from '../src/core/ai_gateway_transport'
import { createWebTools as createProductionWebTools, type CreateWebToolsOptions } from '../src/tools/web/web-tools'
import { WEB_FETCH_BUDGET_CHARS } from '../src/tools/web/fetched-page-text'

let repeatFetchSessionSequence = 0

function createWebTools(opts: Omit<CreateWebToolsOptions, 'repeatFetchSessionKey'>) {
  return createProductionWebTools({
    ...opts,
    repeatFetchSessionKey: `web-tools-test-${++repeatFetchSessionSequence}`
  })
}

function textOf(result: { content: Array<{ type: string; text?: string }> }): string {
  const part = result.content[0]
  expect(part?.type).toBe('text')
  return part?.text ?? ''
}

describe('web tools', () => {
  let workspaceRoot: string

  beforeEach(() => {
    workspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-web-tools-'))
  })

  afterEach(() => {
    rmSync(workspaceRoot, { recursive: true, force: true })
  })

  it('accepts non-empty search queries beyond the former 500-character ceiling', async () => {
    const tools = await createWebTools({
      aiGateway: {
        baseURL: 'https://control.test/api/v1/ai-gateway',
        fetch: async () => jsonResponse({})
      },
      workspaceRoot
    })
    const webSearch = tools.find(tool => tool.name === 'web_search')

    expect(webSearch!.schema.parse({ query: 'q'.repeat(5_000) })).toEqual({ query: 'q'.repeat(5_000) })
    expect(() => webSearch!.schema.parse({ query: '' })).toThrow()
  })

  it('keeps the tool catalog stable and resolves semantic selectors only when a tool runs', async () => {
    const requests: Array<{ url: string; body?: unknown }> = []
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async (input, init) => {
        requests.push({
          url: input instanceof Request ? input.url : String(input),
          body: init?.body ? JSON.parse(String(init.body)) : undefined
        })
        return jsonResponse(
          { error: { code: 'model_profile_not_configured', message: 'web profile is not configured' } },
          422
        )
      }
    }

    const tools = await createWebTools({ aiGateway: client, workspaceRoot })
    const webSearch = tools.find(tool => tool.name === 'web_search')
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    expect(tools.map(tool => tool.name)).toEqual(['web_search', 'web_fetch'])
    await expect(webSearch!.execute('call-search', { query: 'ankole' })).rejects.toThrow(
      'AIGateway web tool request failed with HTTP 422: model_profile_not_configured: web profile is not configured'
    )
    await expect(webFetch!.execute('call-fetch', { urls: ['https://example.com'] })).rejects.toThrow(
      'AIGateway web tool request failed with HTTP 422: model_profile_not_configured: web profile is not configured'
    )
    expect(requests).toEqual([
      {
        url: 'https://control.test/api/v1/ai-gateway/web_search',
        body: { model: 'web_search.default', query: 'ankole' }
      },
      {
        url: 'https://control.test/api/v1/ai-gateway/web_fetch',
        body: { model: 'web_fetch.default', urls: ['https://example.com'] }
      }
    ])
  })

  it('surfaces direct AIGateway failures without silently shrinking the tool catalog', async () => {
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () => jsonResponse({ error: { code: 'temporarily_unavailable', message: 'try again' } }, 503)
    }

    const tools = await createWebTools({ aiGateway: client, workspaceRoot })
    const webSearch = tools.find(tool => tool.name === 'web_search')

    expect(tools.map(tool => tool.name)).toEqual(['web_search', 'web_fetch'])
    await expect(webSearch!.execute('call-search', { query: 'ankole' })).rejects.toThrow(
      'AIGateway web tool request failed with HTTP 503: temporarily_unavailable: try again'
    )
  })

  it('uses the rendered web_fetch fallback when provider-backed fetch is unavailable', async () => {
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () =>
        jsonResponse(
          { error: { code: 'model_profile_not_configured', message: 'web fetch profile is not configured' } },
          422
        )
    }

    const tools = await createWebTools({
      aiGateway: client,
      workspaceRoot,
      renderedFallback: {
        fetchBatch: async urls => ({
          results: urls.map(url => ({
            url,
            title: 'Local Example',
            text: 'Rendered fallback text',
            backend: 'chromium',
            adapter: 'chromium',
            session: 'web-fetch-conversation-1'
          }))
        })
      }
    })

    expect(tools.map(tool => tool.name)).toEqual(['web_search', 'web_fetch'])

    const webFetch = tools.find(tool => tool.name === 'web_fetch')
    const result = await webFetch!.execute('call-fetch', { urls: ['https://example.com'] })
    expect(textOf(result)).toContain('Rendered fallback text')
    expect(textOf(result)).toContain('Source: rendered_fallback')
    expect(textOf(result)).not.toContain('browser')
    expect(textOf(result)).not.toContain('Chromium')
    expect(textOf(result)).not.toContain('CDP')
    expect(result.details).toMatchObject({
      success: true,
      source: 'rendered_fallback',
      results: [
        {
          url: 'https://example.com',
          title: 'Local Example',
          source: 'rendered_fallback',
          text_chars: 'Rendered fallback text'.length,
          truncated: false
        }
      ]
    })
    expect(JSON.stringify(result.details)).not.toContain('Rendered fallback text')
  })

  it('registers provider-backed tools and calls AIGateway with semantic selectors', async () => {
    const requests: Array<{ url: string; body?: unknown }> = []
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway/',
      fetch: async (input, init) => {
        const url = input instanceof Request ? input.url : String(input)
        const body = init?.body ? (JSON.parse(String(init.body)) as JSONObject) : undefined
        requests.push({ url, body })

        if (url.endsWith('/web_search')) {
          return jsonResponse({
            success: true,
            query: body?.query,
            results: [{ title: 'Result', url: 'https://example.com', snippet: 'Snippet' }]
          })
        }

        return jsonResponse({
          success: true,
          results: [{ url: 'https://example.com', title: 'Example', text: 'Extracted text' }]
        })
      }
    }

    const tools = await createWebTools({ aiGateway: client, workspaceRoot })
    const webSearch = tools.find(tool => tool.name === 'web_search')
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    expect(webSearch).toBeTruthy()
    expect(webFetch).toBeTruthy()
    expect(webSearch!.describeActivity(webSearch!.schema.parse({ query: '  lark\ncard input  ' }))).toEqual({
      key: 'signals_gateway.reply.activity.web_search',
      bindings: { query: 'lark card input' }
    })
    expect(
      webFetch!.describeActivity(
        webFetch!.schema.parse({ urls: ['https://example.com/private?token=must-not-survive'] })
      )
    ).toEqual({
      key: 'signals_gateway.reply.activity.web_fetch_target',
      bindings: { target: 'example.com', count: 1 }
    })

    const searchResult = await webSearch!.execute('call-search', { query: 'ankole', limit: 2 })
    expect(textOf(searchResult)).toContain('Result')
    expect(requests[0]).toEqual({
      url: 'https://control.test/api/v1/ai-gateway/web_search',
      body: { model: 'web_search.default', query: 'ankole', limit: 2 }
    })

    const fetchResult = await webFetch!.execute('call-fetch', { urls: ['https://example.com'] })
    expect(textOf(fetchResult)).toContain('Extracted text')
    expect(
      webFetch!.describeCompletedActivity?.(
        webFetch!.schema.parse({ urls: ['https://example.com/private?token=must-not-survive'] }),
        fetchResult.details
      )
    ).toEqual({
      key: 'signals_gateway.reply.activity.web_fetch_target',
      bindings: { target: '《Example》 · example.com', count: 1 }
    })
    expect(requests[1]).toEqual({
      url: 'https://control.test/api/v1/ai-gateway/web_fetch',
      body: { model: 'web_fetch.default', urls: ['https://example.com'] }
    })
  })

  it('surfaces AIGateway web tool errors without a local fallback', async () => {
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () => {
        return jsonResponse({ error: { code: 'upstream_error', message: 'provider failed' } }, 502)
      }
    }

    const tools = await createWebTools({ aiGateway: client, workspaceRoot })
    const webSearch = tools.find(tool => tool.name === 'web_search')

    await expect(webSearch!.execute('call-search', { query: 'ankole' })).rejects.toThrow(
      'AIGateway web tool request failed with HTTP 502: upstream_error: provider failed'
    )
  })

  it('uses rendered web_fetch fallback when AIGateway provider fetch fails', async () => {
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () => {
        return jsonResponse({ error: { code: 'upstream_error', message: 'provider failed' } }, 502)
      }
    }

    const tools = await createWebTools({
      aiGateway: client,
      workspaceRoot,
      renderedFallback: {
        fetchBatch: async urls => ({ results: urls.map(url => ({ url, text: 'Recovered through rendered fallback' })) })
      }
    })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const result = await webFetch!.execute('call-fetch', { urls: ['https://example.com'] })

    expect(textOf(result)).toContain('Recovered through rendered fallback')
    expect(textOf(result)).toContain('Source: rendered_fallback')
    expect(result.details).toMatchObject({
      success: true,
      source: 'rendered_fallback',
      fallback_from: 'aigateway',
      fallback_reason: 'AIGateway web tool request failed with HTTP 502: upstream_error: provider failed'
    })
  })

  it('rejects private-network URLs in local web_fetch by default', async () => {
    const fetched: string[] = []
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () => jsonResponse({ error: { code: 'model_profile_not_configured' } }, 422)
    }

    const tools = await createWebTools({
      aiGateway: client,
      workspaceRoot,
      renderedFallback: {
        fetchBatch: async urls => {
          fetched.push(...urls)
          return { results: urls.map(url => ({ url, text: 'Fetched public page' })) }
        }
      }
    })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const result = await webFetch!.execute('call-fetch', {
      urls: ['https://192.168.1.20/console', 'https://example.com']
    })

    expect(fetched).toEqual(['https://example.com'])
    expect(result.details).toMatchObject({
      success: false,
      source: 'rendered_fallback',
      results: [
        {
          url: 'https://192.168.1.20/console',
          error: 'blocked non-public URL by the security.ssrf_filter policy'
        },
        { url: 'https://example.com', text_chars: 'Fetched public page'.length, truncated: false }
      ]
    })
  })

  it('keeps intranet URLs reachable only when SSRF filtering is explicitly disabled', async () => {
    const fetched: string[] = []
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () => jsonResponse({ error: { code: 'model_profile_not_configured' } }, 422)
    }

    const tools = await createWebTools({
      aiGateway: client,
      workspaceRoot,
      renderedFallback: {
        ssrfFilter: false,
        fetchBatch: async urls => {
          fetched.push(...urls)
          return { results: urls.map(url => ({ url, text: 'Intranet page text' })) }
        }
      }
    })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const result = await webFetch!.execute('call-fetch', {
      urls: ['https://192.168.1.20/console', 'https://169.254.169.254/latest/meta-data/']
    })

    expect(fetched).toEqual(['https://192.168.1.20/console'])
    expect(result.details).toMatchObject({
      success: false,
      source: 'rendered_fallback',
      results: [
        { url: 'https://192.168.1.20/console', text_chars: 'Intranet page text'.length, truncated: false },
        {
          url: 'https://169.254.169.254/latest/meta-data/',
          error: 'blocked rendered fetch to cloud metadata endpoint'
        }
      ]
    })
  })

  it('returns a neutral rendered-fallback unavailable error for web_fetch', async () => {
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () => jsonResponse({ error: { code: 'model_profile_not_configured' } }, 422)
    }

    const tools = await createWebTools({
      aiGateway: client,
      workspaceRoot,
      renderedFallback: {
        fetchBatch: async () => {
          throw new Error('browser daemon connection failed: connect ENOENT /run/ankole-browser/socket/browser.sock')
        }
      }
    })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const result = await webFetch!.execute('call-fetch', { urls: ['https://example.com'] })

    expect(textOf(result)).toContain('rendered fallback is temporarily unavailable')
    expect(textOf(result)).toContain('Source: rendered_fallback')
    expect(textOf(result)).not.toContain('browser')
    expect(textOf(result)).not.toContain('/run/ankole-browser')
    expect(textOf(result)).not.toContain('Chromium')
    expect(textOf(result)).not.toContain('CDP')
    expect(result.details).toMatchObject({
      success: false,
      source: 'rendered_fallback',
      results: [
        {
          url: 'https://example.com',
          error: 'rendered fallback is temporarily unavailable',
          source: 'rendered_fallback'
        }
      ]
    })
  })
  it('keeps the request order and the successful pages when one rendered result carries an error', async () => {
    const batches: string[][] = []
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () => jsonResponse({ error: { code: 'model_profile_not_configured' } }, 422)
    }

    const tools = await createWebTools({
      aiGateway: client,
      workspaceRoot,
      renderedFallback: {
        fetchBatch: async urls => {
          batches.push(urls)
          return {
            results: [
              { url: urls[0], title: 'Page A', text: 'Text of page A' },
              { url: urls[1], error: 'navigation timeout', error_code: 'timeout' }
            ]
          }
        }
      }
    })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const result = await webFetch!.execute('call-fetch', {
      urls: ['https://a.example/', 'https://192.168.1.20/console', 'https://b.example/']
    })

    expect(batches).toEqual([['https://a.example/', 'https://b.example/']])
    expect(textOf(result)).toContain('Text of page A')
    expect(textOf(result)).toContain('Error: navigation timeout')
    expect(result.details).toMatchObject({
      success: false,
      source: 'rendered_fallback',
      results: [
        { url: 'https://a.example/', title: 'Page A', text_chars: 'Text of page A'.length, truncated: false },
        { url: 'https://192.168.1.20/console', error: 'blocked non-public URL by the security.ssrf_filter policy' },
        { url: 'https://b.example/', error: 'navigation timeout' }
      ]
    })
  })

  it('bounds one long page, stores its full text, and points at the omitted middle', async () => {
    const page = Array.from({ length: 6_000 }, (_, line) => `line ${line} ${'p'.repeat(20)}`).join('\n')
    expect(page.length).toBeGreaterThan(WEB_FETCH_BUDGET_CHARS * 2)

    const tools = await createWebTools({
      aiGateway: fetchProviderClient({ results: [{ url: 'https://rogo.ai/', title: 'Rogo', text: page }] }),
      workspaceRoot
    })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const result = await webFetch!.execute('call-fetch', { urls: ['https://rogo.ai/'] })
    const text = textOf(result)

    expect(text.length).toBeLessThan(WEB_FETCH_BUDGET_CHARS + 1_000)
    expect(text).toContain(`the last`)
    expect(text).toContain(`of ${page.length}.`)

    const storedPath = storedPageFrom(text)
    expect(readFileSync(storedPath, 'utf8')).toBe(page)
    expect(result.details).toMatchObject({
      results: [{ url: 'https://rogo.ai/', truncated: true, text_chars: page.length, stored_path: storedPath }]
    })

    // The offset must land on the first line the result did not show, so the
    // model's first read_file continues the page instead of repeating it.
    const offset = Number(/offset=(\d+)/.exec(text)?.[1])
    const head = text.slice(text.indexOf('\nline 0 '), text.indexOf('... [middle omitted'))
    const lastShownLine = Number(/line (\d+) /.exec(head.trimEnd().split('\n').at(-1) ?? '')?.[1])
    expect(offset).toBe(lastShownLine + 2)
    expect(page.split('\n')[offset - 1]).toBe(`line ${lastShownLine + 1} ${'p'.repeat(20)}`)
  })

  it('keeps the truncation pointer above the page text so a head-only projection retains it', async () => {
    const page = 'x'.repeat(WEB_FETCH_BUDGET_CHARS * 2)
    const tools = await createWebTools({
      aiGateway: fetchProviderClient({ results: [{ url: 'https://example.com/long', text: page }] }),
      workspaceRoot
    })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const text = textOf(await webFetch!.execute('call-fetch', { urls: ['https://example.com/long'] }))

    expect(text.indexOf('Read the omitted middle with:')).toBeLessThan(text.indexOf('xxxx'))
    // The page holds no line break, so the head stops inside line 1 and the
    // pointer re-reads that line from its start instead of skipping its rest.
    expect(text).toContain('offset=1 limit=200')
  })

  it('divides one call budget so a large page cannot starve the small pages', async () => {
    const small = 'small page text'
    const large = 'L'.repeat(WEB_FETCH_BUDGET_CHARS * 3)
    const tools = await createWebTools({
      aiGateway: fetchProviderClient({
        results: [
          { url: 'https://example.com/large', text: large },
          { url: 'https://example.com/small', text: small }
        ]
      }),
      workspaceRoot
    })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const result = await webFetch!.execute('call-fetch', {
      urls: ['https://example.com/large', 'https://example.com/small']
    })

    expect(textOf(result)).toContain(small)
    expect(textOf(result).length).toBeLessThan(WEB_FETCH_BUDGET_CHARS + 1_000)
    expect(result.details).toMatchObject({
      results: [{ url: 'https://example.com/large', truncated: true }, { truncated: false }]
    })
  })

  it('returns a bounded result and says the full text is missing when the workspace cannot be written', async () => {
    const page = 'y'.repeat(WEB_FETCH_BUDGET_CHARS * 2)
    const tools = await createWebTools({
      aiGateway: fetchProviderClient({ results: [{ url: 'https://example.com/long', text: page }] }),
      workspaceRoot: join(workspaceRoot, 'missing-parent', '\0invalid')
    })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const result = await webFetch!.execute('call-fetch', { urls: ['https://example.com/long'] })

    expect(textOf(result)).toContain('The full text could not be saved.')
    expect(textOf(result)).not.toContain('read_file path=')
    expect(textOf(result).length).toBeLessThan(WEB_FETCH_BUDGET_CHARS + 1_000)
    expect(result.details).toMatchObject({ results: [{ truncated: true, stored: false }] })
  })

  it('leaves a page that fits whole and stores nothing', async () => {
    const page = 'short enough to keep'
    const tools = await createWebTools({
      aiGateway: fetchProviderClient({ results: [{ url: 'https://example.com', text: page }] }),
      workspaceRoot
    })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const result = await webFetch!.execute('call-fetch', { urls: ['https://example.com'] })

    expect(textOf(result)).toContain(page)
    expect(textOf(result)).not.toContain('Truncated:')
    expect(readdirSync(workspaceRoot)).toEqual([])
  })

  it('serves a repeated URL from the session cache without a new fetch', async () => {
    const requests: unknown[] = []
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async (_input, init) => {
        requests.push(JSON.parse(String(init?.body)))
        return jsonResponse({
          success: true,
          results: [{ url: 'https://example.com', title: 'Example', text: 'Extracted text' }]
        })
      }
    }
    const tools = await createWebTools({ aiGateway: client, workspaceRoot })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const first = await webFetch!.execute('call-1', { urls: ['https://example.com'] })
    const second = await webFetch!.execute('call-2', { urls: ['https://example.com'] })

    expect(requests).toHaveLength(1)
    expect(textOf(first)).not.toContain('[Repeat fetch:')
    expect(textOf(second)).toContain('[Repeat fetch:')
    expect(textOf(second)).toContain('Extracted text')
    expect(second.details).toMatchObject({ results: [{ url: 'https://example.com', repeat_fetch: true }] })
  })

  it('keeps repeat-fetch results across tool catalogs for the same session only', async () => {
    const requests: unknown[] = []
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async (_input, init) => {
        requests.push(JSON.parse(String(init?.body)))
        return jsonResponse({
          success: true,
          results: [{ url: 'https://example.com/across-turns', text: 'Session result' }]
        })
      }
    }
    const firstCatalog = await createProductionWebTools({
      aiGateway: client,
      workspaceRoot,
      repeatFetchSessionKey: 'conversation-a'
    })
    const nextTurnCatalog = await createProductionWebTools({
      aiGateway: client,
      workspaceRoot,
      repeatFetchSessionKey: 'conversation-a'
    })
    const otherSessionCatalog = await createProductionWebTools({
      aiGateway: client,
      workspaceRoot,
      repeatFetchSessionKey: 'conversation-b'
    })

    await firstCatalog
      .find(tool => tool.name === 'web_fetch')!
      .execute('call-1', {
        urls: ['https://example.com/across-turns']
      })
    const repeated = await nextTurnCatalog
      .find(tool => tool.name === 'web_fetch')!
      .execute('call-2', {
        urls: ['https://example.com/across-turns']
      })
    await otherSessionCatalog
      .find(tool => tool.name === 'web_fetch')!
      .execute('call-3', {
        urls: ['https://example.com/across-turns']
      })

    expect(requests).toHaveLength(2)
    expect(textOf(repeated)).toContain('[Repeat fetch:')
    expect(repeated.details).toMatchObject({ results: [{ repeat_fetch: true }] })
  })

  it('fetches only the uncached URLs of a batch and keeps the request order', async () => {
    const bodies: Array<{ urls: string[] }> = []
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async (_input, init) => {
        const body = JSON.parse(String(init?.body)) as { urls: string[] }
        bodies.push(body)
        return jsonResponse({
          success: true,
          results: body.urls.map(url => ({ url, text: `Text of ${url}` }))
        })
      }
    }
    const tools = await createWebTools({ aiGateway: client, workspaceRoot })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    await webFetch!.execute('call-1', { urls: ['https://a.example/'] })
    const result = await webFetch!.execute('call-2', { urls: ['https://a.example/', 'https://b.example/'] })

    expect(bodies.map(body => body.urls)).toEqual([['https://a.example/'], ['https://b.example/']])
    const text = textOf(result)
    expect(text).toContain('[Repeat fetch:')
    expect(text.indexOf('Text of https://a.example/')).toBeLessThan(text.indexOf('Text of https://b.example/'))
    expect(result.details).toMatchObject({
      results: [{ url: 'https://a.example/', repeat_fetch: true }, { url: 'https://b.example/' }]
    })
  })

  it('does not serve failed fetches from the repeat cache', async () => {
    let calls = 0
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () => {
        calls += 1
        return jsonResponse({ success: false, results: [{ url: 'https://example.com', error: 'boom' }] })
      }
    }
    const tools = await createWebTools({ aiGateway: client, workspaceRoot })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    await webFetch!.execute('call-1', { urls: ['https://example.com'] })
    await webFetch!.execute('call-2', { urls: ['https://example.com'] })

    expect(calls).toBe(2)
  })

  it('labels a script shell, tells the model to change source, and keeps it out of the repeat cache', async () => {
    const shell = `You need to enable JavaScript to run this app. ${'Application shell placeholder. '.repeat(4)}`
    let calls = 0
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () => {
        calls += 1
        return jsonResponse({ success: true, results: [{ url: 'https://spa.example/', text: shell }] })
      }
    }
    const tools = await createWebTools({ aiGateway: client, workspaceRoot })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const first = await webFetch!.execute('call-1', { urls: ['https://spa.example/'] })
    await webFetch!.execute('call-2', { urls: ['https://spa.example/'] })

    expect(textOf(first)).toContain('[Not rendered:')
    expect(first.details).toMatchObject({ results: [{ url: 'https://spa.example/', render_warning: 'script_shell' }] })
    expect(calls).toBe(2)
  })

  it('labels an extraction that produced no text', async () => {
    const tools = await createWebTools({
      aiGateway: fetchProviderClient({ success: true, results: [{ url: 'https://empty.example/', text: '' }] }),
      workspaceRoot
    })
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    const result = await webFetch!.execute('call-1', { urls: ['https://empty.example/'] })

    expect(textOf(result)).toContain('[No text:')
    expect(result.details).toMatchObject({ results: [{ url: 'https://empty.example/', render_warning: 'empty_text' }] })
  })
})

function storedPageFrom(text: string): string {
  const path = /Full text: (\S+)/.exec(text)?.[1]
  expect(path).toBeTruthy()
  return path!
}

function fetchProviderClient(fetchBody: unknown): AIGatewayHTTPClient {
  return {
    baseURL: 'https://control.test/api/v1/ai-gateway',
    fetch: async () => jsonResponse(fetchBody)
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' }
  })
}
