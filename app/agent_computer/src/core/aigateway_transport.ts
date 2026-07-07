import { match } from '@pleisto/active-support'
import type { TurnModelRef } from '../lanes/actor_lane'
import { assertRpcResponse, type AIGatewayApiKeyRejected, type AIGatewayApiKeyResponse } from '../lanes/rpc_lane'
import { createModel, type ModelConfig } from './llm'

const aiGatewayApiKeyRefreshSkewMs = 60_000

export type AIGatewayApiKeyRefreshOptions = {
  forceRefresh?: boolean
}

export type AIGatewayApiKeyRefresher = (
  options?: AIGatewayApiKeyRefreshOptions
) => Promise<AIGatewayApiKeyResponse | AIGatewayApiKeyRejected>

export type AIGatewayFetch = (
  input: Parameters<typeof fetch>[0],
  init?: Parameters<typeof fetch>[1]
) => Promise<Response>

export interface AIGatewayHttpClient {
  baseURL: string
  fetch: AIGatewayFetch
}

/**
 * Creates a ModelConfig pointed at AIGateway for the selected worker model.
 *
 * HTTP and WebSocket transports share the same refresh callback so stateful
 * response.create can recover from both expiring and revoked keys.
 */
export function modelConfigFromAIGatewayApiKey(
  modelRef: TurnModelRef,
  apiKey: AIGatewayApiKeyResponse,
  refreshApiKey?: AIGatewayApiKeyRefresher
): ModelConfig {
  const selector = aiGatewayModelSelector(modelRef)
  const { baseURL, fetch: gatewayFetch } = httpClientFromAIGatewayApiKey(apiKey, refreshApiKey)
  const authorization = aiGatewayAuthorization(apiKey, refreshApiKey)

  return createModel({
    apiKey: apiKey.api_key,
    baseURL,
    selector,
    name: modelRef.model,
    provider: modelRef.provider_id,
    fetch: gatewayFetch as never,
    responseWebSocket: {
      kind: 'aigateway-websocket',
      url: aiGatewayWebSocketUrl(baseURL),
      authorization
    }
  })
}

/**
 * Builds the small HTTP client used by worker tools that call AIGateway.
 */
export function httpClientFromAIGatewayApiKey(
  apiKey: AIGatewayApiKeyResponse,
  refreshApiKey?: AIGatewayApiKeyRefresher
): AIGatewayHttpClient {
  return {
    baseURL: apiKey.base_url.replace(/\/+$/, ''),
    fetch: aiGatewayFetch(apiKey, refreshApiKey)
  }
}

/**
 * Converts the control-plane model reference into the selector accepted by
 * AIGateway.
 */
export function aiGatewayModelSelector(modelRef: TurnModelRef): string {
  if (modelRef.provider_id === 'ai_gateway') {
    return modelRef.model
  }

  return `${modelRef.provider_id}/${modelRef.model}`
}

/**
 * Wraps fetch with proactive and reactive AIGateway bearer-token refresh.
 */
function aiGatewayFetch(
  initialApiKey: AIGatewayApiKeyResponse,
  refreshApiKey?: AIGatewayApiKeyRefresher
): AIGatewayFetch {
  let currentApiKey = initialApiKey

  function sendWithKey(input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) {
    const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined))
    headers.set('authorization', `Bearer ${currentApiKey.api_key}`)
    return fetch(input, { ...init, headers })
  }

  return async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    // Proactive refresh: rotate the key before it expires, within the local skew window.
    if (currentApiKey.expires_at * 1000 <= Date.now() + aiGatewayApiKeyRefreshSkewMs) {
      currentApiKey = await refreshApiKeyOrThrow(refreshApiKey)
    }

    const response = await sendWithKey(input, init)

    // Reactive refresh: a key can be revoked server-side before its stated expiry.
    if (response.status === 401 && refreshApiKey) {
      try {
        await response.body?.cancel()
      } catch {
        // ignore: discarding the unauthorized response body before retrying
      }
      currentApiKey = await refreshApiKeyOrThrow(refreshApiKey, { forceRefresh: true })
      return sendWithKey(input, init)
    }

    return response
  }
}

/**
 * Returns the WebSocket authorization header value for the current key.
 *
 * The stateful WebSocket path can request a forced refresh after pre-open
 * failures where no response.create was sent.
 */
function aiGatewayAuthorization(initialApiKey: AIGatewayApiKeyResponse, refreshApiKey?: AIGatewayApiKeyRefresher) {
  let currentApiKey = initialApiKey

  return async (options?: AIGatewayApiKeyRefreshOptions) => {
    const refreshed = await match({
      force: Boolean(options?.forceRefresh && refreshApiKey),
      stale: currentApiKey.expires_at * 1000 <= Date.now() + aiGatewayApiKeyRefreshSkewMs
    })
      .with({ force: true }, () => refreshApiKeyOrThrow(refreshApiKey, { forceRefresh: true }))
      .with({ stale: true }, () => refreshApiKeyOrThrow(refreshApiKey))
      .otherwise(() => undefined)
    if (refreshed) {
      currentApiKey = refreshed
    }

    return `Bearer ${currentApiKey.api_key}`
  }
}

/**
 * Refreshes the key or throws the rejection as a worker-visible error.
 */
async function refreshApiKeyOrThrow(
  refreshApiKey?: AIGatewayApiKeyRefresher,
  options?: AIGatewayApiKeyRefreshOptions
): Promise<AIGatewayApiKeyResponse> {
  if (!refreshApiKey) {
    throw new Error('AIGateway API key expired and no refresh callback is available')
  }
  const refreshed = await refreshApiKey(options)
  assertRpcResponse<AIGatewayApiKeyResponse>(refreshed, 'AIGateway API key rejected')
  return refreshed
}

/**
 * Derives the stateful Responses WebSocket URL from the AIGateway base URL.
 */
function aiGatewayWebSocketUrl(baseUrl: string): string {
  const url = new URL(`${baseUrl.replace(/\/+$/, '')}/responses`)
  match(url.protocol)
    .with('http:', () => {
      url.protocol = 'ws:'
    })
    .with('https:', () => {
      url.protocol = 'wss:'
    })
    .otherwise(() => undefined)
  return url.toString()
}
