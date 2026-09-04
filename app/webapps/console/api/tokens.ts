import { client } from './generated/client.gen'

type ConsoleTokenResponse = {
  access_token: string
  expires_in: number
  refresh_token: string
  refresh_token_expires_in: number
}

type TokenState = {
  accessExpiresAt: number
  accessToken: string
  refreshExpiresAt: number
  refreshToken: string
}

export type ConsoleTokensDeps = {
  /** Same-origin transport for the session-backed endpoints and the bearer API requests. */
  fetch: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>
  origin: string
  /** The CSRF token that the Phoenix shell renders; absent outside a browser session. */
  csrfToken?: string
}

export type ConsoleTokens = {
  /** Resolves a live access token for the generated client's `auth` hook. */
  auth: () => Promise<string>
  /** Transport for the generated client; retries a bearer request once with a reminted token after a 401. */
  fetch: typeof globalThis.fetch
  /** Ends the browser admin session and removes the in-memory bearer credentials. */
  logout: () => Promise<void>
}

const browserSessionGrant = 'urn:ankole:params:oauth:grant-type:browser-session'
/** Remint while this much access-token lifetime remains, so a request in flight does not carry an expired token. */
const refreshMargin = 5_000

/** Creates the bearer-token lifecycle for one browser admin session. */
export function createConsoleTokens({ fetch, origin, csrfToken }: ConsoleTokensDeps): ConsoleTokens {
  let tokens: TokenState | null = null
  let tokenRequest: Promise<TokenState> | null = null

  async function auth(): Promise<string> {
    if (tokens && tokens.accessExpiresAt - Date.now() > refreshMargin) return tokens.accessToken
    return (await remint()).accessToken
  }

  function remint(): Promise<TokenState> {
    tokenRequest ??= mintTokens()
      .then(next => {
        tokens = next
        return next
      })
      .finally(() => {
        tokenRequest = null
      })

    return tokenRequest
  }

  /**
   * Refreshes with the held refresh token and falls back to a browser-session
   * exchange when the server rejects it (key rotation, revocation). A server
   * rejection arrives as a thrown parsed body and discards the dead token,
   * because `auth()` runs before every request and would fail every call until
   * a page reload. A transport failure arrives as an Error instance, rethrows,
   * and keeps the tokens for a later retry.
   */
  async function mintTokens(): Promise<TokenState> {
    if (tokens && Date.now() < tokens.refreshExpiresAt) {
      try {
        return await requestTokens({ grant_type: 'refresh_token', refresh_token: tokens.refreshToken })
      } catch (error) {
        if (error instanceof Error) throw error
        tokens = null
      }
    }

    return requestTokens({ grant_type: browserSessionGrant })
  }

  async function requestTokens(grant: Record<string, string>): Promise<TokenState> {
    const response = (await sessionRequest('/oauth/token', 'POST', grant)) as ConsoleTokenResponse
    const now = Date.now()

    return {
      accessExpiresAt: now + response.expires_in * 1000,
      accessToken: response.access_token,
      refreshExpiresAt: now + response.refresh_token_expires_in * 1000,
      refreshToken: response.refresh_token
    }
  }

  /** Session-backed JSON request: cookie plus CSRF header. Throws the parsed body of a non-2xx response. */
  async function sessionRequest(path: string, method: 'DELETE' | 'POST', body?: Record<string, string>) {
    const headers: Record<string, string> = { accept: 'application/json' }
    if (csrfToken) headers['x-csrf-token'] = csrfToken
    if (body) headers['content-type'] = 'application/json'

    const response = await fetch(`${origin}${path}`, {
      body: body && JSON.stringify(body),
      credentials: 'same-origin',
      headers,
      method
    })
    const payload: unknown = await response.json()

    if (!response.ok) throw payload
    return payload
  }

  async function apiFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    const request = new Request(input, init)
    const retrySource = request.clone()
    const response = await fetch(request)
    const authorization = request.headers.get('authorization') ?? ''

    if (response.status !== 401 || !authorization.toLowerCase().startsWith('bearer ')) {
      return response
    }

    const { accessToken } = await remint()
    const retryHeaders = new Headers(retrySource.headers)
    retryHeaders.set('authorization', `Bearer ${accessToken}`)

    return fetch(new Request(retrySource, { headers: retryHeaders }))
  }

  async function logout(): Promise<void> {
    tokens = null
    tokenRequest = null
    await sessionRequest('/.internal-apis/session', 'DELETE')
  }

  return { auth, fetch: apiFetch as typeof globalThis.fetch, logout }
}

let browserTokens: ConsoleTokens | undefined

function consoleTokens(): ConsoleTokens {
  browserTokens ??= createConsoleTokens({
    csrfToken: document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content,
    fetch: globalThis.fetch,
    origin: window.location.origin
  })

  return browserTokens
}

/** Configures the generated console API client for same-origin bearer requests. */
export function configureConsoleAPIClient() {
  const tokens = consoleTokens()

  client.setConfig({
    auth: tokens.auth,
    baseUrl: window.location.origin,
    credentials: 'same-origin',
    fetch: tokens.fetch
  })
}

/** Ends the browser admin session and removes the in-memory bearer credentials. */
export function logoutConsoleSession() {
  return consoleTokens().logout()
}
