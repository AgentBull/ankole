import { match } from '@pleisto/active-support'
import type { TurnModelRef } from '../lanes/actor_lane'
import { assertRPCResponse, type AIGatewayAPIKeyResponse, type RPCError } from '../lanes/rpc_lane'
import { createModel, type ModelConfig } from './llm'

const aiGatewayAPIKeyRefreshSkewMs = 60_000

export type AIGatewayAPIKeyRefreshOptions = {
  forceRefresh?: boolean
}

export type AIGatewayAPIKeyRefresher = (
  options?: AIGatewayAPIKeyRefreshOptions
) => Promise<AIGatewayAPIKeyResponse | RPCError>

export type AIGatewayFetch = (
  input: Parameters<typeof fetch>[0],
  init?: Parameters<typeof fetch>[1]
) => Promise<Response>

export interface AIGatewayHTTPClient {
  baseURL: string
  fetch: AIGatewayFetch
}

/**
 * Creates a ModelConfig pointed at AIGateway for the selected worker model.
 *
 * HTTP and WebSocket transports share the same refresh callback so stateful
 * response.create can recover from both expiring and revoked keys.
 */
export function modelConfigFromAIGatewayAPIKey(
  modelRef: TurnModelRef,
  apiKey: AIGatewayAPIKeyResponse,
  refreshAPIKey?: AIGatewayAPIKeyRefresher
): ModelConfig {
  const selector = aiGatewayModelSelector(modelRef)
  const { baseURL, fetch: gatewayFetch } = httpClientFromAIGatewayAPIKey(apiKey, refreshAPIKey)
  const authorization = aiGatewayAuthorization(apiKey, refreshAPIKey)

  return createModel({
    apiKey: apiKey.api_key,
    baseURL,
    selector,
    name: modelRef.model,
    provider: modelRef.provider_id,
    fetch: gatewayFetch as never,
    responseWebSocket: {
      kind: 'aigateway-websocket',
      url: aiGatewayWebSocketURL(baseURL),
      authorization
    }
  })
}

/**
 * Builds the small HTTP client used by worker tools that call AIGateway.
 */
export function httpClientFromAIGatewayAPIKey(
  apiKey: AIGatewayAPIKeyResponse,
  refreshAPIKey?: AIGatewayAPIKeyRefresher
): AIGatewayHTTPClient {
  return {
    baseURL: apiKey.base_url.replace(/\/+$/, ''),
    fetch: aiGatewayFetch(apiKey, refreshAPIKey)
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
  initialAPIKey: AIGatewayAPIKeyResponse,
  refreshAPIKey?: AIGatewayAPIKeyRefresher
): AIGatewayFetch {
  let currentAPIKey = initialAPIKey

  function sendWithKey(input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) {
    const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined))
    headers.set('authorization', `Bearer ${currentAPIKey.api_key}`)
    return fetch(input, { ...init, headers })
  }

  return async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    // Proactive refresh: rotate the key before it expires, within the local skew window.
    if (currentAPIKey.expires_at * 1000 <= Date.now() + aiGatewayAPIKeyRefreshSkewMs) {
      currentAPIKey = await refreshAPIKeyOrThrow(refreshAPIKey)
    }

    const response = await sendWithKey(input, init)

    // Reactive refresh: a key can be revoked server-side before its stated expiry.
    if (response.status === 401 && refreshAPIKey) {
      try {
        await response.body?.cancel()
      } catch {
        // ignore: discarding the unauthorized response body before retrying
      }
      currentAPIKey = await refreshAPIKeyOrThrow(refreshAPIKey, { forceRefresh: true })
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
function aiGatewayAuthorization(initialAPIKey: AIGatewayAPIKeyResponse, refreshAPIKey?: AIGatewayAPIKeyRefresher) {
  let currentAPIKey = initialAPIKey

  return async (options?: AIGatewayAPIKeyRefreshOptions) => {
    const refreshed = await match({
      force: Boolean(options?.forceRefresh && refreshAPIKey),
      stale: currentAPIKey.expires_at * 1000 <= Date.now() + aiGatewayAPIKeyRefreshSkewMs
    })
      .with({ force: true }, () => refreshAPIKeyOrThrow(refreshAPIKey, { forceRefresh: true }))
      .with({ stale: true }, () => refreshAPIKeyOrThrow(refreshAPIKey))
      .otherwise(() => undefined)
    if (refreshed) {
      currentAPIKey = refreshed
    }

    return `Bearer ${currentAPIKey.api_key}`
  }
}

/**
 * Refreshes the key or throws the rejection as a worker-visible error.
 */
async function refreshAPIKeyOrThrow(
  refreshAPIKey?: AIGatewayAPIKeyRefresher,
  options?: AIGatewayAPIKeyRefreshOptions
): Promise<AIGatewayAPIKeyResponse> {
  if (!refreshAPIKey) {
    throw new Error('AIGateway API key expired and no refresh callback is available')
  }
  const refreshed = await refreshAPIKey(options)
  assertRPCResponse<AIGatewayAPIKeyResponse>(refreshed, 'AIGateway API key rejected')
  return refreshed
}

/**
 * Derives the stateful Responses WebSocket URL from the AIGateway base URL.
 */
function aiGatewayWebSocketURL(baseURL: string): string {
  const url = new URL(`${baseURL.replace(/\/+$/, '')}/responses`)
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
