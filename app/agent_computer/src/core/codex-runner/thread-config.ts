import { AIGATEWAY_PROVIDER_NAME, codexAIGatewayAuthConfig, encodeAIGatewayModelBinding } from './agent-home-config'
import type { CodexRuntimeConfig } from './runtime-config'

export function codexJobThreadConfig(input: {
  cwd: string
  codexHome: string
  env: Record<string, string>
  runtime: CodexRuntimeConfig
  traceparent?: string
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
          'x-ankole-aigateway-model-binding': encodeAIGatewayModelBinding(input.runtime),
          ...(input.traceparent ? { traceparent: input.traceparent } : {})
        },
        auth: codexAIGatewayAuthConfig(input.codexHome)
      }
    },
    features: {
      plugins: true,
      remote_plugin: false,
      remote_compaction_v2: input.runtime.remoteCompactionV2
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
  config.projects = { [input.cwd]: { trust_level: 'trusted' } }
  return config
}

function mergeConfig(base: Record<string, unknown>, overrides: Record<string, unknown>): Record<string, unknown> {
  const result = { ...base }
  for (const [key, value] of Object.entries(overrides)) {
    const current = result[key]
    result[key] = isTable(current) && isTable(value) ? mergeConfig(current, value) : value
  }
  return result
}

function isTable(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === 'object' && !Array.isArray(value) && !(value instanceof Date))
}
