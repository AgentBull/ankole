import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { AIGatewayHTTPClient } from '../src/core/ai_gateway_transport'
import { createWebTools } from '../src/tools/web/web-tools'

function textOf(result: { content: Array<{ type: string; text?: string }> }): string {
  const part = result.content[0]
  expect(part?.type).toBe('text')
  return part?.text ?? ''
}

describe('web tools', () => {
  it('accepts non-empty search queries beyond the former 500-character ceiling', async () => {
    const tools = await createWebTools({
      aiGateway: {
        baseURL: 'https://control.test/api/v1/ai-gateway',
        fetch: async () => jsonResponse({})
      }
    })
    const webSearch = tools.find(tool => tool.name === 'web_search')

    expect(webSearch!.schema.parse({ query: 'q'.repeat(5_000) })).toEqual({ query: 'q'.repeat(5_000) })
    expect(() => webSearch!.schema.parse({ query: '' })).toThrow()
  })

  it('keeps the tool catalog stable and reports unavailable providers at execution time', async () => {
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () =>
        new Response(
          JSON.stringify({
            web_search: { available: false, reason: 'model_profile_not_configured' },
            web_fetch: { available: false, reason: 'model_profile_not_configured' }
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )
    }

    const tools = await createWebTools({ aiGateway: client })
    const webSearch = tools.find(tool => tool.name === 'web_search')
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    expect(tools.map(tool => tool.name)).toEqual(['web_search', 'web_fetch'])
    await expect(webSearch!.execute('call-search', { query: 'ankole' })).rejects.toThrow(
      'web_search is unavailable: model_profile_not_configured'
    )
    await expect(webFetch!.execute('call-fetch', { urls: ['https://example.com'] })).rejects.toThrow(
      'web_fetch is unavailable: model_profile_not_configured'
    )
  })

  it('surfaces availability lookup failures without silently shrinking the tool catalog', async () => {
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () => jsonResponse({ error: { code: 'temporarily_unavailable', message: 'try again' } }, 503)
    }

    const tools = await createWebTools({ aiGateway: client })
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
        jsonResponse({
          web_search: { available: true, model: 'web_search.default' },
          web_fetch: { available: false, reason: 'model_profile_not_configured' }
        })
    }

    const tools = await createWebTools({
      aiGateway: client,
      renderedFallback: {
        fetchURL: async ({ url }) => ({
          url,
          title: 'Local Example',
          text: 'Rendered fallback text',
          backend: 'chromium',
          adapter: 'chromium',
          session: 'web-fetch-conversation-1'
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
          text: 'Rendered fallback text',
          metadata: {
            source: 'rendered_fallback'
          }
        }
      ]
    })
  })

  it('registers provider-backed tools and calls AIGateway with resolved models', async () => {
    const requests: Array<{ url: string; body?: unknown }> = []
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway/',
      fetch: async (input, init) => {
        const url = input instanceof Request ? input.url : String(input)
        const body = init?.body ? (JSON.parse(String(init.body)) as JSONObject) : undefined
        requests.push({ url, body })

        if (url.endsWith('/web_tools')) {
          return jsonResponse({
            web_search: { available: true, model: 'web_search.default' },
            web_fetch: { available: true, model: 'web_fetch.default' }
          })
        }

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

    const tools = await createWebTools({ aiGateway: client })
    const webSearch = tools.find(tool => tool.name === 'web_search')
    const webFetch = tools.find(tool => tool.name === 'web_fetch')

    expect(webSearch).toBeTruthy()
    expect(webFetch).toBeTruthy()

    const searchResult = await webSearch!.execute('call-search', { query: 'ankole', limit: 2 })
    expect(textOf(searchResult)).toContain('Result')
    expect(requests[1]).toEqual({
      url: 'https://control.test/api/v1/ai-gateway/web_search',
      body: { model: 'web_search.default', query: 'ankole', limit: 2 }
    })

    const fetchResult = await webFetch!.execute('call-fetch', { urls: ['https://example.com'] })
    expect(textOf(fetchResult)).toContain('Extracted text')
    expect(requests[2]).toEqual({
      url: 'https://control.test/api/v1/ai-gateway/web_fetch',
      body: { model: 'web_fetch.default', urls: ['https://example.com'] }
    })
  })

  it('surfaces AIGateway web tool errors without a local fallback', async () => {
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async input => {
        const url = input instanceof Request ? input.url : String(input)
        if (url.endsWith('/web_tools')) {
          return jsonResponse({
            web_search: { available: true, model: 'web_search.default' }
          })
        }

        return jsonResponse({ error: { code: 'upstream_error', message: 'provider failed' } }, 502)
      }
    }

    const tools = await createWebTools({ aiGateway: client })
    const webSearch = tools.find(tool => tool.name === 'web_search')

    await expect(webSearch!.execute('call-search', { query: 'ankole' })).rejects.toThrow(
      'AIGateway web tool request failed with HTTP 502: upstream_error: provider failed'
    )
  })

  it('uses rendered web_fetch fallback when AIGateway provider fetch fails', async () => {
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async input => {
        const url = input instanceof Request ? input.url : String(input)
        if (url.endsWith('/web_tools')) {
          return jsonResponse({
            web_fetch: { available: true, model: 'web_fetch.default' }
          })
        }

        return jsonResponse({ error: { code: 'upstream_error', message: 'provider failed' } }, 502)
      }
    }

    const tools = await createWebTools({
      aiGateway: client,
      renderedFallback: {
        fetchURL: async ({ url }) => ({ url, text: 'Recovered through rendered fallback' })
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
      fetch: async () =>
        jsonResponse({
          web_fetch: { available: false, reason: 'model_profile_not_configured' }
        })
    }

    const tools = await createWebTools({
      aiGateway: client,
      renderedFallback: {
        fetchURL: async ({ url }) => {
          fetched.push(url)
          return { url, text: 'Fetched public page' }
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
        { url: 'https://example.com', text: 'Fetched public page' }
      ]
    })
  })

  it('keeps intranet URLs reachable only when SSRF filtering is explicitly disabled', async () => {
    const fetched: string[] = []
    const client: AIGatewayHTTPClient = {
      baseURL: 'https://control.test/api/v1/ai-gateway',
      fetch: async () =>
        jsonResponse({
          web_fetch: { available: false, reason: 'model_profile_not_configured' }
        })
    }

    const tools = await createWebTools({
      aiGateway: client,
      renderedFallback: {
        ssrfFilter: false,
        fetchURL: async ({ url }) => {
          fetched.push(url)
          return { url, text: 'Intranet page text' }
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
        { url: 'https://192.168.1.20/console', text: 'Intranet page text' },
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
      fetch: async () =>
        jsonResponse({
          web_fetch: { available: false, reason: 'model_profile_not_configured' }
        })
    }

    const tools = await createWebTools({
      aiGateway: client,
      renderedFallback: {
        fetchURL: async () => {
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
          metadata: { source: 'rendered_fallback' }
        }
      ]
    })
  })
})

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' }
  })
}
