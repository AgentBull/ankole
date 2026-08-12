import { client } from './generated/client.gen'
import {
  ankoleWebAuthControllerDeleteSession,
  ankoleWebAuthControllerOauthToken as ankoleWebAuthControllerOAuthToken
} from './generated/sdk.gen'
import type { ConsoleTokenResponse } from './generated/types.gen'

type TokenState = {
  accessExpiresAt: number
  accessToken: string
  refreshExpiresAt: number
  refreshToken: string
}

const browserSessionGrant = 'urn:ankole:params:oauth:grant-type:browser-session'
let tokens: TokenState | null = null
let tokenRequest: Promise<TokenState> | null = null
let configured = false

/** Configures the generated console API client for same-origin bearer requests. */
export function configureConsoleAPIClient() {
  if (configured) return
  configured = true

  client.setConfig({
    auth: () => ensureAccessToken(),
    ['baseUrl']: window.location.origin,
    credentials: 'same-origin',
    fetch: consoleAPIFetch as typeof fetch
  })
}

/** Clears the in-memory bearer credentials. */
function clearConsoleTokens() {
  tokens = null
  tokenRequest = null
}

/** Ends the browser admin session and removes in-memory bearer credentials. */
export async function logoutConsoleSession() {
  clearConsoleTokens()
  await ankoleWebAuthControllerDeleteSession({
    headers: consoleSessionHeaders(),
    throwOnError: true
  })
}

async function ensureAccessToken(): Promise<string> {
  if (tokens && Date.now() < preRefreshAt(tokens)) return tokens.accessToken
  return (await runTokenRequest(mintTokens)).accessToken
}

async function forceRefreshAccessToken(): Promise<string> {
  return (await runTokenRequest(mintTokens)).accessToken
}

/**
 * Refreshes with the held refresh token and falls back to a browser-session
 * exchange when the server rejects it (key rotation, revocation). The
 * generated client throws parsed HTTP bodies as plain values; a transport
 * failure throws an Error instance. A server rejection discards the dead
 * token, because `auth()` runs before every request and would fail every call
 * until a page reload. A transport error rethrows and keeps the tokens for a
 * later retry.
 */
async function mintTokens(): Promise<TokenState> {
  if (tokens && Date.now() < tokens.refreshExpiresAt) {
    try {
      return await refreshTokens(tokens.refreshToken)
    } catch (error) {
      if (error instanceof Error) throw error
      tokens = null
    }
  }

  return exchangeBrowserSession()
}

async function runTokenRequest(factory: () => Promise<TokenState>): Promise<TokenState> {
  if (!tokenRequest) {
    tokenRequest = factory()
      .then(next => {
        tokens = next
        return next
      })
      .finally(() => {
        tokenRequest = null
      })
  }

  return tokenRequest
}

async function exchangeBrowserSession(): Promise<TokenState> {
  const { data } = await ankoleWebAuthControllerOAuthToken({
    body: {
      grant_type: browserSessionGrant
    },
    headers: consoleSessionHeaders(),
    throwOnError: true
  })

  return tokenState(data)
}

async function refreshTokens(refreshToken: string): Promise<TokenState> {
  const { data } = await ankoleWebAuthControllerOAuthToken({
    body: {
      grant_type: 'refresh_token',
      refresh_token: refreshToken
    },
    headers: consoleSessionHeaders(),
    throwOnError: true
  })

  return tokenState(data)
}

function tokenState(response: ConsoleTokenResponse): TokenState {
  const now = Date.now()

  return {
    accessExpiresAt: now + response.expires_in * 1000,
    accessToken: response.access_token,
    refreshExpiresAt: now + response.refresh_token_expires_in * 1000,
    refreshToken: response.refresh_token
  }
}

function preRefreshAt(state: TokenState): number {
  const ttl = state.accessExpiresAt - Date.now()
  const skew = Math.min(60_000, Math.max(5_000, ttl * 0.1))
  return state.accessExpiresAt - skew
}

async function consoleAPIFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const request = new Request(input, init)
  const retrySource = request.clone()
  const response = await fetch(request)
  const authorization = request.headers.get('authorization') ?? ''

  if (response.status !== 401 || !authorization.toLowerCase().startsWith('bearer ')) {
    return response
  }

  const accessToken = await forceRefreshAccessToken()
  const retryHeaders = new Headers(retrySource.headers)
  retryHeaders.set('authorization', `Bearer ${accessToken}`)

  return fetch(new Request(retrySource, { headers: retryHeaders }))
}

function consoleSessionHeaders(): Record<string, string> {
  const headers: Record<string, string> = { accept: 'application/json' }
  const csrfToken = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content

  if (csrfToken) headers['x-csrf-token'] = csrfToken

  return headers
}
