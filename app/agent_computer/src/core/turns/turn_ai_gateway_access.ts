import type { TurnStart } from '../../lanes/actor_lane'
import type { AIGatewayAPIKeyResponse } from '../../lanes/rpc_lane'
import {
  httpClientFromAIGatewayAPIKey,
  modelConfigFromAIGatewayAPIKey,
  type AIGatewayAPIKeyRefreshOptions,
  type AIGatewayHTTPClient
} from '../ai_gateway_transport'
import type { ModelConfig } from '../llm'
import type { AIGatewayAPIKeyRequester } from './turn_options'
import { turnTracePropagationFromTurnStart } from '../../observability/turn-tracing'

export type TurnAIGatewayAccess = {
  model: ModelConfig
  visionFallbackModel?: ModelConfig
  aiGateway: AIGatewayHTTPClient
}

export type TurnAIGatewayAccessStep = <T>(promise: Promise<T>, step: string) => Promise<T>

export type AcquireTurnAIGatewayAccessOptions = {
  requestAIGatewayAPIKey: AIGatewayAPIKeyRequester
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

  const requestAPIKey = (refreshOptions?: AIGatewayAPIKeyRefreshOptions) =>
    opts.requestAIGatewayAPIKey(turnStart.turn.actor.agent_uid, refreshOptions)

  const apiKey = await requestVerifiedAPIKey(turnStart, requestAPIKey(), 'AIGateway API key', opts.runStep)
  const refreshAIGatewayAPIKey = (refreshOptions?: AIGatewayAPIKeyRefreshOptions) =>
    requestVerifiedAPIKey(turnStart, requestAPIKey(refreshOptions), 'AIGateway API key refresh', opts.runStep)
  const turnTracePropagation = turnTracePropagationFromTurnStart(turnStart)
  const actorSessionID = turnStart.turn.actor.session_id

  return {
    model: modelConfigFromAIGatewayAPIKey(
      modelRef,
      apiKey,
      refreshAIGatewayAPIKey,
      turnTracePropagation,
      actorSessionID
    ),
    aiGateway: httpClientFromAIGatewayAPIKey(apiKey, refreshAIGatewayAPIKey, turnTracePropagation, actorSessionID),
    ...(modelRef.vision_fallback_model_ref
      ? {
          visionFallbackModel: modelConfigFromAIGatewayAPIKey(
            modelRef.vision_fallback_model_ref,
            apiKey,
            refreshAIGatewayAPIKey,
            turnTracePropagation,
            actorSessionID
          )
        }
      : {})
  }
}

async function requestVerifiedAPIKey(
  turnStart: TurnStart,
  promise: Promise<AIGatewayAPIKeyResponse>,
  step: string,
  runStep?: TurnAIGatewayAccessStep
): Promise<AIGatewayAPIKeyResponse> {
  const apiKey = await (runStep ? runStep(promise, step) : promise)
  assertAIGatewayAPIKeyMatchesTurn(turnStart, apiKey)
  return apiKey
}

function assertAIGatewayAPIKeyMatchesTurn(turnStart: TurnStart, apiKey: AIGatewayAPIKeyResponse): void {
  if (
    apiKey.agentUid !== turnStart.turn.actor.agent_uid ||
    apiKey.tokenType !== 'Bearer' ||
    apiKey.scope !== 'ai_gateway' ||
    !apiKey.apiKey ||
    !apiKey.baseUrl
  ) {
    throw new Error('AIGateway API key response does not match turn agent or auth contract')
  }
}
