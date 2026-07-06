import { match } from '@pleisto/active-support'
import type { TurnModelRef, TurnStart } from '../../lanes/actor_lane'
import type { ModelConfig } from '../llm'
import { createModel } from '../llm'
import type { AIGatewayApiKeyRejected, AIGatewayApiKeyResponse } from '../../lanes/rpc_lane'

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
 * Verifies that the control-plane-issued key can only be used for this turn's
 * agent and for AIGateway bearer auth.
 */
export function assertAIGatewayApiKeyMatchesTurn(turnStart: TurnStart, apiKey: AIGatewayApiKeyResponse): void {
  if (
    apiKey.agent_uid !== turnStart.turn.actor.agent_uid ||
    apiKey.token_type !== 'Bearer' ||
    !apiKey.api_key ||
    !apiKey.base_url
  ) {
    throw new Error('AIGateway API key response does not match turn agent')
  }
}

/**
 * Creates a ModelConfig pointed at AIGateway for the selected turn model.
 *
 * HTTP and WebSocket transports share the same refresh callback so stateful
 * response.create can recover from both expiring and revoked keys.
 */
export function runtimeModelFromAIGatewayApiKey(
  modelRef: TurnModelRef,
  apiKey: AIGatewayApiKeyResponse,
  refreshApiKey?: AIGatewayApiKeyRefresher
): ModelConfig {
  const selector = aiGatewayModelSelector(modelRef)
  const { baseURL, fetch: gatewayFetch } = aiGatewayHttpClientFromApiKey(apiKey, refreshApiKey)
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
export function aiGatewayHttpClientFromApiKey(
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
  if ('code' in refreshed) {
    throw new Error(`AIGateway API key rejected: ${refreshed.code} ${refreshed.message ?? ''}`.trim())
  }
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
