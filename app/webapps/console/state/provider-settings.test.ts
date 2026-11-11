import { describe, expect, test } from 'bun:test'
import { ENCRYPTED_VALUE_MASK } from '../encrypted-value-input'
import type {
  AIGatewayCredentialPoolEntry,
  AIGatewayProviderKindItem,
  ProviderSetting as AIGatewayProviderSetting
} from './provider-settings'
import {
  buildSettingOptions,
  connectionSettings,
  credentialSettings,
  decryptedCredentialFieldText,
  entryHasSecretField,
  requestSettings,
  secretCredentialSettings
} from './provider-settings'

function providerKind(providerKind: string): AIGatewayProviderKindItem {
  return {
    capabilities: ['llm'],
    default_base_url: 'https://api.example.test/v1',
    label: { default: providerKind },
    provider_kind: providerKind,
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
      providerSetting('serviceTier', { options: ['fast', 'flex'], scope: 'request', advanced: true }),
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
    expect(requestSettings(providerKind('openai'), 'llm').map(setting => [setting.key, setting.type])).toEqual([
      ['reasoningEffort', 'select'],
      ['enable_search', 'boolean'],
      ['thinking_budget', 'integer'],
      ['repetition_penalty', 'float'],
      ['search_options', 'map'],
      ['mode', 'string'],
      ['serviceTier', 'string'],
      ['strictJSONSchema', 'boolean']
    ])
  })

  test('offers a request setting only on the profiles whose capability reads it', () => {
    const kind: AIGatewayProviderKindItem = {
      ...providerKind('cloudflare'),
      capabilities: ['web_search', 'image_generate', 'speech'],
      settings: [
        providerSetting('engine', { scope: 'request', capabilities: ['web_search'] }),
        providerSetting('steps', { scope: 'request', type: 'integer', capabilities: ['image_generate'] }),
        providerSetting('user', { scope: 'request' })
      ]
    }
    const keys = (capability: string) => requestSettings(kind, capability).map(setting => setting.key)

    expect(keys('web_search')).toEqual(['engine', 'user'])
    expect(keys('image_generate')).toEqual(['steps', 'user'])
    // A setting that names no capability serves them all.
    expect(keys('speech')).toEqual(['user'])
  })

  test('serializes smart field drafts using the DSL value types', () => {
    const result = buildSettingOptions(
      requestSettings(providerKind('openai'), 'llm'),
      {
        reasoningEffort: 'xhigh',
        enable_search: 'true',
        thinking_budget: '2048',
        repetition_penalty: '1.15',
        search_options: '{"freshness":"week"}',
        mode: 'balanced',
        serviceTier: 'provider-native-tier'
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
        mode: 'balanced',
        serviceTier: 'provider-native-tier'
      }
    })
  })

  test('omits a blank service tier while accepting declared and custom values', () => {
    const settings = requestSettings(providerKind('openai'), 'llm')
    const message = (field: string, error: string) => `${field}:${error}`

    expect(buildSettingOptions(settings, { serviceTier: '' }, message)).toEqual({ ok: true, value: {} })
    expect(buildSettingOptions(settings, { serviceTier: 'flex' }, message)).toEqual({
      ok: true,
      value: { serviceTier: 'flex' }
    })
    expect(buildSettingOptions(settings, { serviceTier: 'provider-native-tier' }, message)).toEqual({
      ok: true,
      value: { serviceTier: 'provider-native-tier' }
    })
  })

  test('reports the specific invalid typed field', () => {
    const result = buildSettingOptions(
      requestSettings(providerKind('openai'), 'llm'),
      { thinking_budget: '2.5' },
      (field, error) => `${field}:${error}`
    )

    expect(result).toEqual({ ok: false, key: 'thinking_budget', error: 'Thinking budget:integer' })
  })

  test('rejects values outside a select setting declared options', () => {
    const result = buildSettingOptions(
      requestSettings(providerKind('openai'), 'llm'),
      { reasoningEffort: 'max' },
      (field, error) => `${field}:${error}`
    )

    expect(result).toEqual({ ok: false, key: 'reasoningEffort', error: 'Reasoning effort:selection' })
  })

  test('omits unmodified encrypted masks while serializing replacement secrets', () => {
    const settings = credentialSettings(providerKind('openai'))
    const message = (field: string, error: string) => `${field}:${error}`

    expect(buildSettingOptions(settings, { api_key: ENCRYPTED_VALUE_MASK }, message)).toEqual({ ok: true, value: {} })
    expect(buildSettingOptions(settings, { api_key: 'sk-replacement' }, message)).toEqual({
      ok: true,
      value: { api_key: 'sk-replacement' }
    })
  })

  test('filters non-secret account metadata out of secretCredentialSettings and checks present_fields', () => {
    const chatgptKind: AIGatewayProviderKindItem = {
      capabilities: ['llm'],
      default_base_url: 'https://chatgpt.com/backend-api/codex',
      label: { default: 'ChatGPT' },
      provider_kind: 'chatgpt_subscription',
      settings: [
        providerSetting('access_token', { encrypted: true, required: true, scope: 'credential' }),
        providerSetting('refresh_token', { encrypted: true, scope: 'credential' }),
        providerSetting('id_token', { encrypted: true, scope: 'credential' }),
        providerSetting('account_id', { encrypted: true, scope: 'credential' }),
        providerSetting('plan_type', { encrypted: true, scope: 'credential' }),
        providerSetting('email', { encrypted: true, scope: 'credential' }),
        providerSetting('last_refresh', { encrypted: true, scope: 'credential' }),
        providerSetting('fedramp', { encrypted: true, type: 'boolean', scope: 'credential' }),
        providerSetting('auth_type', {
          encrypted: true,
          type: 'select',
          options: ['oauth', 'enterprise_access_token'],
          scope: 'credential'
        })
      ]
    }

    expect(secretCredentialSettings(chatgptKind).map(setting => setting.key)).toEqual([
      'access_token',
      'refresh_token',
      'id_token'
    ])

    const defaultEntry: AIGatewayCredentialPoolEntry = {
      id: 'default',
      label: 'Default',
      source: 'provider_default',
      priority: 0,
      credential_present: true,
      present_fields: [],
      status: 'ok',
      request_count: 0,
      rate_limits: {},
      usage: {}
    }
    expect(entryHasSecretField(defaultEntry, 'api_key')).toBe(false)

    const populatedEntry: AIGatewayCredentialPoolEntry = {
      ...defaultEntry,
      source: 'manual',
      present_fields: ['api_key']
    }
    expect(entryHasSecretField(populatedEntry, 'api_key')).toBe(true)
    expect(entryHasSecretField(populatedEntry, 'access_token')).toBe(false)

    expect(decryptedCredentialFieldText({ api_key: 'sk-live', empty: '' }, 'api_key')).toBe('sk-live')
    expect(decryptedCredentialFieldText({ api_key: 'sk-live', empty: '' }, 'empty')).toBeUndefined()
  })
})
