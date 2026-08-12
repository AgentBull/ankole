import { describe, expect, test } from 'bun:test'
import type {
  AiGatewayProviderKindItem as AIGatewayProviderKindItem,
  AiGatewayProviderSetting as AIGatewayProviderSetting
} from '../api/generated/types.gen'
import {
  buildSettingOptions,
  connectionSettings,
  credentialSettings,
  humanizeKey,
  requestSettings,
  settingValidationMessage
} from '../pages/provider-settings'

function providerKind(providerKind: string): AIGatewayProviderKindItem {
  return {
    capabilities: ['llm'],
    capability_specs: [],
    connection_options: ['app_referer', 'app_title', 'headers'],
    credential_options: ['api_key'],
    default_base_url: 'https://api.example.test/v1',
    label: { default: providerKind },
    provider_kind: providerKind,
    runtime_provider_options: [
      'reasoningEffort',
      'enable_search',
      'thinking_budget',
      'repetition_penalty',
      'search_options',
      'mode',
      'strictJSONSchema'
    ],
    settings: [
      providerSetting('base_url', { advanced: providerKind === 'openrouter' }),
      providerSetting('api_key', { encrypted: true, required: true, scope: 'credential' }),
      providerSetting('app_referer', { advanced: providerKind === 'openrouter' }),
      providerSetting('app_title', { advanced: providerKind === 'openrouter' }),
      providerSetting('headers', { type: 'map', advanced: true }),
      providerSetting('reasoningEffort', {
        type: 'select',
        default: 'high',
        options: ['none', 'minimal', 'low', 'medium', 'high', 'xhigh'],
        scope: 'request'
      }),
      providerSetting('enable_search', { type: 'boolean', scope: 'request' }),
      providerSetting('thinking_budget', { type: 'integer', scope: 'request' }),
      providerSetting('repetition_penalty', { type: 'float', scope: 'request' }),
      providerSetting('search_options', { type: 'map', scope: 'request' }),
      providerSetting('mode', { scope: 'request' }),
      providerSetting('strictJSONSchema', { type: 'boolean', scope: 'request', advanced: true })
    ]
  }
}

function providerSetting(key: string, overrides: Partial<AIGatewayProviderSetting> = {}): AIGatewayProviderSetting {
  return {
    advanced: false,
    default: null,
    encrypted: false,
    key,
    options: [],
    required: false,
    scope: 'connection',
    type: 'string',
    ...overrides
  }
}

describe('provider settings', () => {
  test('selects only connection-scope settings in DSL order for the connection form', () => {
    const kind = providerKind('openai')

    expect(connectionSettings(kind).map(setting => setting.key)).toEqual([
      'base_url',
      'app_referer',
      'app_title',
      'headers'
    ])
    expect(credentialSettings(kind).map(setting => setting.key)).toEqual(['api_key'])
  })

  test('projects only request-scoped DSL settings for model profiles', () => {
    expect(requestSettings(providerKind('openai')).map(setting => [setting.key, setting.type])).toEqual([
      ['reasoningEffort', 'select'],
      ['enable_search', 'boolean'],
      ['thinking_budget', 'integer'],
      ['repetition_penalty', 'float'],
      ['search_options', 'map'],
      ['mode', 'string'],
      ['strictJSONSchema', 'boolean']
    ])
  })

  test('serializes smart field drafts using the DSL value types', () => {
    const result = buildSettingOptions(
      requestSettings(providerKind('openai')),
      {
        reasoningEffort: 'xhigh',
        enable_search: 'true',
        thinking_budget: '2048',
        repetition_penalty: '1.15',
        search_options: '{"freshness":"week"}',
        mode: 'balanced'
      },
      (field, error) => `${field}:${error}`
    )

    expect(result).toEqual({
      ok: true,
      value: {
        reasoningEffort: 'xhigh',
        enable_search: true,
        thinking_budget: 2048,
        repetition_penalty: 1.15,
        search_options: { freshness: 'week' },
        mode: 'balanced'
      }
    })
  })

  test('reports the specific invalid typed field', () => {
    const result = buildSettingOptions(
      requestSettings(providerKind('openai')),
      { thinking_budget: '2.5' },
      (field, error) => `${field}:${error}`
    )

    expect(result).toEqual({ ok: false, key: 'thinking_budget', error: 'Thinking budget:integer' })
  })

  test('rejects values outside a select setting declared options', () => {
    const result = buildSettingOptions(
      requestSettings(providerKind('openai')),
      { reasoningEffort: 'max' },
      (field, error) => `${field}:${error}`
    )

    expect(result).toEqual({ ok: false, key: 'reasoningEffort', error: 'Reasoning effort:selection' })
  })

  test('humanizes snake case and camel case option keys', () => {
    expect(humanizeKey('reasoningEffort')).toBe('Reasoning effort')
    expect(humanizeKey('strictJSONSchema')).toBe('Strict JSON schema')
    expect(humanizeKey('oauth')).toBe('OAuth')
  })

  test('maps every setting validation error to one operator-facing message', () => {
    // MF2 wraps interpolated values in Unicode bidi isolates (U+2068/U+2069).
    const isolated = (field: string) => `⁨${field}⁩`

    expect(settingValidationMessage('Context', 'required')).toBe(`${isolated('Context')} is required`)
    expect(settingValidationMessage('Context', 'integer')).toBe(`${isolated('Context')} must be an integer`)
    expect(settingValidationMessage('Context', 'number')).toBe(`${isolated('Context')} must be a number`)
    expect(settingValidationMessage('Headers', 'json_object')).toBe(`${isolated('Headers')} must be a JSON object`)
    expect(settingValidationMessage('Mode', 'selection')).toBe(
      `${isolated('Mode')} must be one of the available options`
    )
  })
})
