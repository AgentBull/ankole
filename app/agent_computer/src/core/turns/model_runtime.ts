import type { TurnModelRef, TurnStart } from '../../actor_lane'
import type { Model } from '../../ai-gateway-client/ankole'
import { createAIGatewayResponsesModel } from '../../ai-gateway-client/ai-gateway-provider'
import type { AIGatewayApiKeyRejected, AIGatewayApiKeyResponse } from '../../rpc_lane'

const aiGatewayApiKeyRefreshSkewMs = 60_000

export type AIGatewayApiKeyRefresher = () => Promise<AIGatewayApiKeyResponse | AIGatewayApiKeyRejected>

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

export function runtimeModelFromAIGatewayApiKey(
  modelRef: TurnModelRef,
  apiKey: AIGatewayApiKeyResponse,
  selector = aiGatewayModelSelector(modelRef),
  refreshApiKey?: AIGatewayApiKeyRefresher
): Model {
  const modelSelector = selector
  const baseUrl = apiKey.base_url.replace(/\/+$/, '')
  const gatewayFetch = aiGatewayFetch(apiKey, refreshApiKey) as unknown as typeof fetch
  const sdkModel = createAIGatewayResponsesModel(
    {
      name: 'ankole-ai-gateway',
      apiKey: apiKey.api_key,
      baseURL: baseUrl,
      fetch: gatewayFetch
    },
    modelSelector
  )

  return {
    id: modelSelector,
    name: selector === `${modelRef.provider_id}/${modelRef.model}` ? modelRef.model : selector,
    api: 'open-responses',
    provider: 'ai-gateway',
    baseUrl,
    input: ['text', 'image'],
    sdkModel
  }
}

export function aiGatewayModelSelector(modelRef: TurnModelRef): string {
  if (modelRef.provider_id === 'ai_gateway') {
    return modelRef.model
  }

  return `${modelRef.provider_id}/${modelRef.model}`
}

function aiGatewayFetch(initialApiKey: AIGatewayApiKeyResponse, refreshApiKey?: AIGatewayApiKeyRefresher) {
  let currentApiKey = initialApiKey

  async function refreshOrThrow(): Promise<void> {
    if (!refreshApiKey) {
      throw new Error('AIGateway API key expired and no refresh callback is available')
    }
    const refreshed = await refreshApiKey()
    if ('code' in refreshed) {
      throw new Error(`AIGateway API key rejected: ${refreshed.code} ${refreshed.message ?? ''}`.trim())
    }
    currentApiKey = refreshed
  }

  function sendWithKey(input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) {
    const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined))
    headers.set('authorization', `Bearer ${currentApiKey.api_key}`)
    return fetch(input, { ...init, headers })
  }

  return async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    // Proactive refresh: rotate the key before it expires, within the local skew window.
    if (currentApiKey.expires_at * 1000 <= Date.now() + aiGatewayApiKeyRefreshSkewMs) {
      await refreshOrThrow()
    }

    const response = await sendWithKey(input, init)

    // Reactive refresh: a key can be revoked server-side before its stated expiry. On a 401 the
    // request has not started streaming, so refetch the key once and retry the request, instead of
    // hard-failing the turn when an operator rotates or revokes the worker key mid-session.
    if (response.status === 401 && refreshApiKey) {
      try {
        await response.body?.cancel()
      } catch {
        // ignore: discarding the unauthorized response body before retrying
      }
      await refreshOrThrow()
      return sendWithKey(input, init)
    }

    return response
  }
}
