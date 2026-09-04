import { afterEach, describe, expect, setSystemTime, test } from 'bun:test'
import { createConsoleTokens } from './tokens'

const origin = 'https://console.example'
const browserSessionGrant = 'urn:ankole:params:oauth:grant-type:browser-session'
const mintedAt = new Date('2026-09-04T00:00:00Z')

/** The server mints 30-minute access tokens; the console remints once 5 seconds remain. */
const lastCachedMoment = new Date('2026-09-04T00:29:54.999Z')
const refreshMoment = new Date('2026-09-04T00:29:55Z')

function tokenResponse(prefix: string) {
  return Response.json({
    access_token: `${prefix}-access`,
    expires_in: 1800,
    refresh_token: `${prefix}-refresh`,
    refresh_token_expires_in: 86_400
  })
}

function recordingFetch(handle: (request: Request, call: number) => Response | Promise<Response>) {
  const requests: Request[] = []
  const fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init)
    requests.push(request.clone())
    return handle(request, requests.length)
  }

  return { fetch, requests }
}

function pathOf(request: Request) {
  return new URL(request.url).pathname
}

async function grantOf(request: Request) {
  return ((await request.json()) as { grant_type: string }).grant_type
}

afterEach(() => setSystemTime())

describe('createConsoleTokens', () => {
  test('concurrent callers share one browser-session exchange', async () => {
    let release!: () => void
    const gate = new Promise<void>(resolve => {
      release = resolve
    })
    const { fetch, requests } = recordingFetch(async () => {
      await gate
      return tokenResponse('first')
    })
    const tokens = createConsoleTokens({ fetch, origin, csrfToken: 'csrf-1' })

    const pending = Promise.all([tokens.auth(), tokens.auth(), tokens.auth()])
    release()

    expect(await pending).toEqual(['first-access', 'first-access', 'first-access'])
    expect(requests).toHaveLength(1)
    expect(requests[0].method).toBe('POST')
    expect(requests[0].url).toBe(`${origin}/oauth/token`)
    expect(requests[0].headers.get('accept')).toBe('application/json')
    expect(requests[0].headers.get('content-type')).toBe('application/json')
    expect(requests[0].headers.get('x-csrf-token')).toBe('csrf-1')
    expect(await requests[0].json()).toEqual({ grant_type: browserSessionGrant })

    expect(await tokens.auth()).toBe('first-access')
    expect(requests).toHaveLength(1)
  })

  test('refreshes with the held refresh token before the access token expires', async () => {
    setSystemTime(mintedAt)
    const { fetch, requests } = recordingFetch((_request, call) => tokenResponse(call === 1 ? 'first' : 'second'))
    const tokens = createConsoleTokens({ fetch, origin, csrfToken: 'csrf-1' })
    expect(await tokens.auth()).toBe('first-access')

    setSystemTime(lastCachedMoment)
    expect(await tokens.auth()).toBe('first-access')
    expect(requests).toHaveLength(1)

    setSystemTime(refreshMoment)
    expect(await tokens.auth()).toBe('second-access')
    expect(requests).toHaveLength(2)
    expect(await requests[1].json()).toEqual({ grant_type: 'refresh_token', refresh_token: 'first-refresh' })
  })

  test('retries a bearer request exactly once after a 401', async () => {
    const { fetch, requests } = recordingFetch(async (request, call) => {
      if (pathOf(request) === '/oauth/token') return tokenResponse(call === 1 ? 'first' : 'second')
      return Response.json({ error: 'invalid_token' }, { status: 401 })
    })
    const tokens = createConsoleTokens({ fetch, origin, csrfToken: 'csrf-1' })
    const accessToken = await tokens.auth()

    const response = await tokens.fetch(`${origin}/api/v1/agents`, {
      body: '{"name":"a"}',
      headers: { authorization: `Bearer ${accessToken}` },
      method: 'POST'
    })

    expect(response.status).toBe(401)
    const apiRequests = requests.filter(request => pathOf(request) === '/api/v1/agents')
    expect(apiRequests).toHaveLength(2)
    expect(apiRequests[0].headers.get('authorization')).toBe('Bearer first-access')
    expect(apiRequests[1].headers.get('authorization')).toBe('Bearer second-access')
    expect(await apiRequests[1].text()).toBe('{"name":"a"}')
    const tokenRequests = requests.filter(request => pathOf(request) === '/oauth/token')
    expect(tokenRequests).toHaveLength(2)
    expect(await tokenRequests[1].json()).toEqual({ grant_type: 'refresh_token', refresh_token: 'first-refresh' })
    expect(await tokens.auth()).toBe('second-access')
  })

  test('passes a 401 through when the request carried no bearer token', async () => {
    const { fetch, requests } = recordingFetch(() => Response.json({ error: 'unauthorized' }, { status: 401 }))
    const tokens = createConsoleTokens({ fetch, origin, csrfToken: 'csrf-1' })

    const response = await tokens.fetch(`${origin}/api/v1/agents`)

    expect(response.status).toBe(401)
    expect(requests).toHaveLength(1)
  })

  test('keeps the held tokens when the refresh fails in transport', async () => {
    setSystemTime(mintedAt)
    let offline = false
    const { fetch, requests } = recordingFetch((_request, call) => {
      if (offline) throw new TypeError('Failed to fetch')
      return tokenResponse(call === 1 ? 'first' : 'second')
    })
    const tokens = createConsoleTokens({ fetch, origin, csrfToken: 'csrf-1' })
    await tokens.auth()

    setSystemTime(refreshMoment)
    offline = true
    await expect(tokens.auth()).rejects.toThrow('Failed to fetch')

    offline = false
    expect(await tokens.auth()).toBe('second-access')
    expect(requests).toHaveLength(3)
    expect(await requests[2].json()).toEqual({ grant_type: 'refresh_token', refresh_token: 'first-refresh' })
  })

  test('falls back to the browser session when the server rejects the refresh token', async () => {
    setSystemTime(mintedAt)
    const { fetch, requests } = recordingFetch(async (request, call) => {
      if ((await grantOf(request)) === 'refresh_token') {
        return Response.json({ error: 'invalid_grant', error_description: 'refresh token is invalid' }, { status: 400 })
      }
      return tokenResponse(call === 1 ? 'first' : 'second')
    })
    const tokens = createConsoleTokens({ fetch, origin, csrfToken: 'csrf-1' })
    await tokens.auth()

    setSystemTime(refreshMoment)
    expect(await tokens.auth()).toBe('second-access')
    expect(requests).toHaveLength(3)
    expect(await grantOf(requests[1])).toBe('refresh_token')
    expect(await grantOf(requests[2])).toBe(browserSessionGrant)
  })

  test('logout ends the browser session and drops the held tokens', async () => {
    const { fetch, requests } = recordingFetch((request, call) => {
      if (pathOf(request) === '/.internal-apis/session') return Response.json({ ok: true })
      return tokenResponse(call === 1 ? 'first' : 'second')
    })
    const tokens = createConsoleTokens({ fetch, origin, csrfToken: 'csrf-1' })
    await tokens.auth()

    await tokens.logout()

    expect(requests[1].method).toBe('DELETE')
    expect(requests[1].url).toBe(`${origin}/.internal-apis/session`)
    expect(requests[1].headers.get('x-csrf-token')).toBe('csrf-1')
    expect(await tokens.auth()).toBe('second-access')
    expect(await grantOf(requests[2])).toBe(browserSessionGrant)
  })
})
