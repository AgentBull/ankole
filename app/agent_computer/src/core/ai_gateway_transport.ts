import { ms } from '@agentbull/active-support'
import { Buffer } from 'node:buffer'
import type { AIGatewayAPIKeyResponse } from '../lanes/rpc_lane'
import type { TurnTracePropagation } from '../observability/turn-tracing'

export const aiGatewayAPIKeyRefreshSkewMs = ms('1m')
const aiGatewayHTTPMaxAttempts = 3
const aiGatewayHTTPRefreshedKeyBackoffMs = ms('5s')
const noObservabilityUserID = 'none'

export const AIGATEWAY_OBSERVABILITY_USER_ID_HEADER = 'x-ankole-observability-user-id'

export type AIGatewayAPIKeyRefreshOptions = {
  forceRefresh?: boolean
}

export type AIGatewayAPIKeyRefresher = (options?: AIGatewayAPIKeyRefreshOptions) => Promise<AIGatewayAPIKeyResponse>

export type AIGatewayFetch = (
  input: Parameters<typeof fetch>[0],
  init?: Parameters<typeof fetch>[1]
) => Promise<Response>

/**
 * Builds the trusted trace headers for one AIGateway request.
 *
 * The user value uses an ASCII-safe base64url carrier. AIGateway decodes it
 * before it records `user.id`, and the carrier never reaches a model Provider.
 */
export function aiGatewayTurnTraceHeaders(turnTracePropagation?: TurnTracePropagation): Record<string, string> {
  if (!turnTracePropagation) return {}

  return {
    traceparent: turnTracePropagation.traceparent,
    [AIGATEWAY_OBSERVABILITY_USER_ID_HEADER]:
      turnTracePropagation.observabilityUserID === null
        ? noObservabilityUserID
        : Buffer.from(turnTracePropagation.observabilityUserID, 'utf8').toString('base64url')
  }
}

/**
 * Wraps fetch with proactive and reactive AIGateway bearer-token refresh.
 */
function aiGatewayFetch(
  initialAPIKey: AIGatewayAPIKeyResponse,
  refreshAPIKey?: AIGatewayAPIKeyRefresher,
  turnTracePropagation?: TurnTracePropagation
): AIGatewayFetch {
  let currentAPIKey = initialAPIKey
  const turnHeaders = aiGatewayTurnTraceHeaders(turnTracePropagation)

  function sendWithKey(input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) {
    const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined))
    headers.set('authorization', `Bearer ${currentAPIKey.apiKey}`)
    headers.delete('traceparent')
    headers.delete(AIGATEWAY_OBSERVABILITY_USER_ID_HEADER)
    for (const [name, value] of Object.entries(turnHeaders)) headers.set(name, value)
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
