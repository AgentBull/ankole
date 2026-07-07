import type { TurnStart } from '../../lanes/actor_lane'
import { assertRpcResponse, type AIGatewayApiKeyRejected, type AIGatewayApiKeyResponse } from '../../lanes/rpc_lane'
import {
  httpClientFromAIGatewayApiKey,
  modelConfigFromAIGatewayApiKey,
  type AIGatewayApiKeyRefreshOptions,
  type AIGatewayHttpClient
} from '../aigateway_transport'
import type { ModelConfig } from '../llm'
import type { AIGatewayApiKeyRequester } from './turn_options'

type AIGatewayApiKeyResult = AIGatewayApiKeyResponse | AIGatewayApiKeyRejected

export type TurnAIGatewayAccess = {
  model: ModelConfig
  visionFallbackModel?: ModelConfig
  aiGateway: AIGatewayHttpClient
}

export type TurnAIGatewayAccessStep = <T>(promise: Promise<T>, step: string) => Promise<T>

export type AcquireTurnAIGatewayAccessOptions = {
  requestAIGatewayApiKey: AIGatewayApiKeyRequester
  requestIdPrefix?: string
  runStep?: TurnAIGatewayAccessStep
}

/**
 * Acquires AIGateway access handles for one worker turn.
 *
 * The control plane owns provider credentials and model binding. The worker asks
 * RuntimeFabric for an agent-scoped AIGateway key, validates that every initial
 * and refreshed key still belongs to this turn's agent, then exposes only the
 * local model and tool HTTP handles to turn orchestration.
 */
export async function acquireTurnAIGatewayAccess(
  turnStart: TurnStart,
  opts: AcquireTurnAIGatewayAccessOptions
): Promise<TurnAIGatewayAccess> {
  const modelRef = turnStart.model_ref
  if (!modelRef) {
    throw new Error('turn is missing a real model_ref')
  }

  const requestIdPrefix = opts.requestIdPrefix ?? 'ai-gateway-key'
  const requestApiKey = (refreshOptions?: AIGatewayApiKeyRefreshOptions) =>
    opts.requestAIGatewayApiKey(
      {
        request_id: `${requestIdPrefix}-${crypto.randomUUID()}`,
        agent_uid: turnStart.turn.actor.agent_uid
      },
      refreshOptions
    )

  const apiKey = await requestApiKeyOrThrow(turnStart, requestApiKey(), 'AIGateway API key', opts.runStep)
  const refreshAIGatewayApiKey = (refreshOptions?: AIGatewayApiKeyRefreshOptions) =>
    requestApiKeyOrThrow(turnStart, requestApiKey(refreshOptions), 'AIGateway API key refresh', opts.runStep)

  return {
    model: modelConfigFromAIGatewayApiKey(modelRef, apiKey, refreshAIGatewayApiKey),
    aiGateway: httpClientFromAIGatewayApiKey(apiKey, refreshAIGatewayApiKey),
    ...(modelRef.vision_fallback_model_ref
      ? {
          visionFallbackModel: modelConfigFromAIGatewayApiKey(
            modelRef.vision_fallback_model_ref,
            apiKey,
            refreshAIGatewayApiKey
          )
        }
      : {})
  }
}

async function requestApiKeyOrThrow(
  turnStart: TurnStart,
  promise: Promise<AIGatewayApiKeyResult>,
  step: string,
  runStep?: TurnAIGatewayAccessStep
): Promise<AIGatewayApiKeyResponse> {
  const apiKey = await (runStep ? runStep(promise, step) : promise)
  assertRpcResponse<AIGatewayApiKeyResponse>(apiKey, 'AIGateway API key rejected')

  assertAIGatewayApiKeyMatchesTurn(turnStart, apiKey)
  return apiKey
}

function assertAIGatewayApiKeyMatchesTurn(turnStart: TurnStart, apiKey: AIGatewayApiKeyResponse): void {
  if (
    apiKey.agent_uid !== turnStart.turn.actor.agent_uid ||
    apiKey.token_type !== 'Bearer' ||
    apiKey.scope !== 'ai_gateway' ||
    !apiKey.api_key ||
    !apiKey.base_url
  ) {
    throw new Error('AIGateway API key response does not match turn agent or auth contract')
  }
}
