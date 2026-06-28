import type { LanguageModel } from '@/ai-gateway-client/provider'
import {
  loadApiKey,
  withoutTrailingSlash,
  withUserAgentSuffix,
  type FetchFunction
} from '@/ai-gateway-client/provider-utils'
import { OpenResponsesLanguageModel } from './responses/open-responses-language-model'
import type { OpenResponsesModelId } from './responses/open-responses-language-model-options'

export interface AIGatewayResponsesModelSettings {
  /**
   * Base URL for the AIGateway API, normally ending in `/api/v1/ai-gateway`.
   */
  baseURL: string

  /**
   * Agent-scoped AIGateway API key minted by the control plane.
   */
  apiKey?: string

  /**
   * Provider name for AI SDK telemetry and providerOptions routing.
   */
  name?: string

  /**
   * Additional request headers.
   */
  headers?: Record<string, string>

  /**
   * Custom fetch implementation used by the worker to refresh AIGateway keys.
   */
  fetch?: FetchFunction
}

/**
 * Creates Ankole's worker-side AIGateway Responses model.
 *
 * The worker intentionally exposes only the OpenResponses LLM surface.
 * Provider credentials, adapter selection, embeddings, and rerank stay behind
 * the control-plane AIGateway API.
 */
export function createAIGatewayResponsesModel(
  options: AIGatewayResponsesModelSettings,
  modelId: string
): LanguageModel {
  const baseURL = withoutTrailingSlash(options.baseURL)
  const providerName = options.name ?? 'ai-gateway'

  const getHeaders = () =>
    withUserAgentSuffix(
      {
        Authorization: `Bearer ${loadApiKey({
          apiKey: options.apiKey,
          environmentVariableName: 'ANKOLE_AI_GATEWAY_API_KEY',
          description: 'Ankole AIGateway'
        })}`,
        ...options.headers
      },
      `com.agentbull.ankole-ai-gateway.client`
    )

  return new OpenResponsesLanguageModel(modelId as OpenResponsesModelId, {
    provider: `${providerName}.responses`,
    url: ({ path }) => `${baseURL}${path}`,
    headers: getHeaders,
    fetch: options.fetch,
    fileIdPrefixes: ['file-']
  })
}
