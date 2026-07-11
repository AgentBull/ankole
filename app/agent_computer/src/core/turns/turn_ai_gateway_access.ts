import type { TurnStart } from '../../lanes/actor_lane'
import { assertRPCResponse, type AIGatewayAPIKeyResponse, type RPCError } from '../../lanes/rpc_lane'
import {
  httpClientFromAIGatewayAPIKey,
  modelConfigFromAIGatewayAPIKey,
  type AIGatewayAPIKeyRefreshOptions,
  type AIGatewayHTTPClient
} from '../ai_gateway_transport'
import type { ModelConfig } from '../llm'
import type { AIGatewayAPIKeyRequester } from './turn_options'

type AIGatewayAPIKeyResult = AIGatewayAPIKeyResponse | RPCError

export type TurnAIGatewayAccess = {
  model: ModelConfig
  visionFallbackModel?: ModelConfig
  aiGateway: AIGatewayHTTPClient
}

export type TurnAIGatewayAccessStep = <T>(promise: Promise<T>, step: string) => Promise<T>

export type AcquireTurnAIGatewayAccessOptions = {
  requestAIGatewayAPIKey: AIGatewayAPIKeyRequester
  requestIDPrefix?: string
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

  const requestIDPrefix = opts.requestIDPrefix ?? 'ai-gateway-key'
  const requestAPIKey = (refreshOptions?: AIGatewayAPIKeyRefreshOptions) =>
    opts.requestAIGatewayAPIKey(
      {
        request_id: `${requestIDPrefix}-${crypto.randomUUID()}`,
        agent_uid: turnStart.turn.actor.agent_uid
      },
      refreshOptions
    )

  const apiKey = await requestAPIKeyOrThrow(turnStart, requestAPIKey(), 'AIGateway API key', opts.runStep)
  const refreshAIGatewayAPIKey = (refreshOptions?: AIGatewayAPIKeyRefreshOptions) =>
    requestAPIKeyOrThrow(turnStart, requestAPIKey(refreshOptions), 'AIGateway API key refresh', opts.runStep)

  return {
    model: modelConfigFromAIGatewayAPIKey(modelRef, apiKey, refreshAIGatewayAPIKey),
    aiGateway: httpClientFromAIGatewayAPIKey(apiKey, refreshAIGatewayAPIKey),
    ...(modelRef.vision_fallback_model_ref
      ? {
          visionFallbackModel: modelConfigFromAIGatewayAPIKey(
            modelRef.vision_fallback_model_ref,
            apiKey,
            refreshAIGatewayAPIKey
          )
        }
      : {})
  }
}

async function requestAPIKeyOrThrow(
  turnStart: TurnStart,
  promise: Promise<AIGatewayAPIKeyResult>,
  step: string,
  runStep?: TurnAIGatewayAccessStep
): Promise<AIGatewayAPIKeyResponse> {
  const apiKey = await (runStep ? runStep(promise, step) : promise)
  assertRPCResponse<AIGatewayAPIKeyResponse>(apiKey, 'AIGateway API key rejected')

  assertAIGatewayAPIKeyMatchesTurn(turnStart, apiKey)
  return apiKey
}

function assertAIGatewayAPIKeyMatchesTurn(turnStart: TurnStart, apiKey: AIGatewayAPIKeyResponse): void {
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
