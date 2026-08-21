import { isRecord } from '@agentbull/active-support'
import { AIGATEWAY_PROVIDER_NAME, codexAIGatewayAuthConfig, encodeAIGatewayModelBinding } from './agent-home-config'
import { AIGATEWAY_OBSERVABILITY_USER_ID_HEADER, aiGatewayTurnTraceHeaders } from '../ai_gateway_transport'
import type { TurnTracePropagation } from '../../observability/turn-tracing'
import type { CodexRuntimeConfig } from './runtime-config'

export function codexJobThreadConfig(input: {
  cwd: string
  codexHome: string
  env: Record<string, string>
  runtime: CodexRuntimeConfig
  turnTracePropagation?: TurnTracePropagation
  projectConfig?: Record<string, unknown>
}): Record<string, unknown> {
  const baseURL = input.runtime.aiGatewayKey.baseUrl.replace(/\/+$/, '')
  const config = mergeConfig(input.projectConfig ?? {}, {
    model_provider: 'ankole_aigateway',
    ...(input.runtime.modelProfile.modelReasoningEffort
      ? { model_reasoning_effort: input.runtime.modelProfile.modelReasoningEffort }
      : {}),
    model_providers: {
      ankole_aigateway: {
        name: AIGATEWAY_PROVIDER_NAME,
        base_url: baseURL,
        wire_api: 'responses',
        supports_websockets: true,
        http_headers: {
          'x-ankole-aigateway-model-binding': encodeAIGatewayModelBinding(input.runtime)
        },
        auth: codexAIGatewayAuthConfig(input.codexHome)
      }
    },
    features: {
      plugins: true,
      remote_plugin: false
    },
    skills: {
      config: [
        { name: 'skill-creator', enabled: false },
        { name: 'plugin-creator', enabled: false },
        { name: 'skill-installer', enabled: false }
      ]
    },
    shell_environment_policy: {
      inherit: 'all',
      set: input.env
    }
  })
  replaceTurnTraceHeaders(config, input.turnTracePropagation)
  config.projects = { [input.cwd]: { trust_level: 'trusted' } }
  return config
}

function replaceTurnTraceHeaders(config: Record<string, unknown>, propagation?: TurnTracePropagation): void {
  const modelProviders = config.model_providers
  if (!isRecord(modelProviders)) return
  const provider = modelProviders.ankole_aigateway
  if (!isRecord(provider)) return

  const httpHeaders = withoutTurnTraceHeaders(provider.http_headers)
  provider.http_headers = { ...httpHeaders, ...aiGatewayTurnTraceHeaders(propagation) }

  if (isRecord(provider.env_http_headers)) {
    provider.env_http_headers = withoutTurnTraceHeaders(provider.env_http_headers)
  }
}

function withoutTurnTraceHeaders(value: unknown): Record<string, unknown> {
  const headers = isRecord(value) ? { ...value } : {}
  for (const name of Object.keys(headers)) {
    const normalizedName = name.toLowerCase()
    if (normalizedName === 'traceparent' || normalizedName === AIGATEWAY_OBSERVABILITY_USER_ID_HEADER) {
      delete headers[name]
    }
  }
  return headers
}

function mergeConfig(base: Record<string, unknown>, overrides: Record<string, unknown>): Record<string, unknown> {
  const result = { ...base }
  for (const [key, value] of Object.entries(overrides)) {
    const current = result[key]
    result[key] = isRecord(current) && isRecord(value) ? mergeConfig(current, value) : value
  }
  return result
}
