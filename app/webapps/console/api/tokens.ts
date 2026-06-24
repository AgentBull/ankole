import { apiDelete, apiPost } from '../../common/api'
import { client } from './generated/client.gen'

type TokenResponse = {
  access_token: string
  expires_in: number
  refresh_token: string
  refresh_token_expires_in: number
  scope: string
  token_type: 'Bearer'
}

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
export function configureConsoleApiClient() {
  if (configured) return
  configured = true

  client.setConfig({
    auth: () => ensureAccessToken(),
    baseUrl: window.location.origin,
    fetch: consoleApiFetch as typeof fetch
  })
}

/** Clears the in-memory bearer credentials. */
export function clearConsoleTokens() {
  tokens = null
  tokenRequest = null
}

/** Ends the browser admin session and removes in-memory bearer credentials. */
export async function logoutConsoleSession() {
  clearConsoleTokens()
  await apiDelete('/.internal-apis/session')
}

async function ensureAccessToken(): Promise<string> {
  const now = Date.now()
  if (tokens && now < preRefreshAt(tokens)) return tokens.accessToken

  const next = await runTokenRequest(() => {
    if (tokens && now < tokens.refreshExpiresAt) return refreshTokens(tokens.refreshToken)
    return exchangeBrowserSession()
  })

  return next.accessToken
}

async function forceRefreshAccessToken(): Promise<string> {
  const next = await runTokenRequest(async () => {
    if (tokens && Date.now() < tokens.refreshExpiresAt) {
      try {
        return await refreshTokens(tokens.refreshToken)
      } catch {
        clearConsoleTokens()
      }
    }

    return exchangeBrowserSession()
  })

  return next.accessToken
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
  const response = await apiPost<TokenResponse>('/.internal-apis/oauth/token', {
    grant_type: browserSessionGrant
  })

  return tokenState(response)
}

async function refreshTokens(refreshToken: string): Promise<TokenState> {
  const response = await apiPost<TokenResponse>('/.internal-apis/oauth/token', {
    grant_type: 'refresh_token',
    refresh_token: refreshToken
  })

  return tokenState(response)
}

function tokenState(response: TokenResponse): TokenState {
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

async function consoleApiFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const request = new Request(input, init)
  const retrySource = request.clone()
  const response = await fetch(request)

  if (response.status !== 401) return response

  const accessToken = await forceRefreshAccessToken()
  const retryHeaders = new Headers(retrySource.headers)
  retryHeaders.set('authorization', `Bearer ${accessToken}`)

  return fetch(new Request(retrySource, { headers: retryHeaders }))
}
