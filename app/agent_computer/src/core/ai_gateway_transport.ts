import { match } from '@agentbull/active-support'
import type { TurnModelRef } from '../lanes/actor_lane'
import type { AIGatewayAPIKeyResponse } from '../lanes/rpc_lane'
import { createModel, type ModelConfig } from './llm'

const aiGatewayAPIKeyRefreshSkewMs = 60_000
const aiGatewayHTTPMaxAttempts = 3
const aiGatewayHTTPRefreshedKeyBackoffMs = 5_000

export type AIGatewayAPIKeyRefreshOptions = {
  forceRefresh?: boolean
}

export type AIGatewayAPIKeyRefresher = (options?: AIGatewayAPIKeyRefreshOptions) => Promise<AIGatewayAPIKeyResponse>

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
    apiKey: apiKey.apiKey,
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
    baseURL: apiKey.baseUrl.replace(/\/+$/, ''),
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
    headers.set('authorization', `Bearer ${currentAPIKey.apiKey}`)
    return fetch(input instanceof Request ? input.clone() : input, { ...init, headers })
  }

  return async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    const reusableInput = input instanceof Request ? input.clone() : input
    const signal = init?.signal ?? (reusableInput instanceof Request ? reusableInput.signal : undefined)

    // Proactive refresh: rotate the key before it expires, within the local skew window.
    if (Number(currentAPIKey.expiresAt) * 1000 <= Date.now() + aiGatewayAPIKeyRefreshSkewMs) {
      currentAPIKey = await refreshAPIKeyOrThrow(refreshAPIKey)
    }

    for (let attempt = 1; attempt <= aiGatewayHTTPMaxAttempts; attempt++) {
      const response = await sendWithKey(reusableInput, init)
      if (response.status !== 401 || !refreshAPIKey || attempt === aiGatewayHTTPMaxAttempts) return response

      await discardResponse(response)
      if (attempt > 1) await abortableDelay(aiGatewayHTTPRefreshedKeyBackoffMs, signal)
      signal?.throwIfAborted()
      currentAPIKey = await refreshAPIKeyOrThrow(refreshAPIKey, { forceRefresh: true })
    }

    throw new Error('unreachable AIGateway HTTP retry state')
  }
}

async function discardResponse(response: Response): Promise<void> {
  try {
    await response.body?.cancel()
  } catch {
    // The response is already being discarded; a close race must not hide the retry.
  }
}

function abortableDelay(delayMs: number, signal?: AbortSignal | null): Promise<void> {
  signal?.throwIfAborted()
  return new Promise((resolve, reject) => {
    const onAbort = (): void => {
      clearTimeout(timer)
      signal?.removeEventListener('abort', onAbort)
      reject(signal?.reason ?? new DOMException('The operation was aborted', 'AbortError'))
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolve()
    }, delayMs)
    signal?.addEventListener('abort', onAbort, { once: true })
  })
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
      stale: Number(currentAPIKey.expiresAt) * 1000 <= Date.now() + aiGatewayAPIKeyRefreshSkewMs
    })
      .with({ force: true }, () => refreshAPIKeyOrThrow(refreshAPIKey, { forceRefresh: true }))
      .with({ stale: true }, () => refreshAPIKeyOrThrow(refreshAPIKey))
      .otherwise(() => undefined)
    if (refreshed) {
      currentAPIKey = refreshed
    }

    return `Bearer ${currentAPIKey.apiKey}`
  }
}

/**
 * Refreshes the key or reports the missing refresh capability.
 */
async function refreshAPIKeyOrThrow(
  refreshAPIKey?: AIGatewayAPIKeyRefresher,
  options?: AIGatewayAPIKeyRefreshOptions
): Promise<AIGatewayAPIKeyResponse> {
  if (!refreshAPIKey) {
    throw new Error('AIGateway API key expired and no refresh callback is available')
  }
  return await refreshAPIKey(options)
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
