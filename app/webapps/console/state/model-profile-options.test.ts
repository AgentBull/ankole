import { describe, expect, test } from 'bun:test'
import type {
  AiGatewayModelCatalogEntry as AIGatewayModelCatalogEntry,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem
} from '../api/generated/types.gen'
import {
  modelOptionsForProfile,
  modelProfileRequestFields,
  profileUsesConfigurableModel,
  providersForProfile
} from '../pages/model-profile-options'
import type { AIGatewayProviderItem } from './provider-settings'

function provider(providerID: string, providerKind: string): AIGatewayProviderItem {
  return {
    connection_options: {},
    credential_pool: { entries: [], strategy: 'fill_first' },
    id: providerID,
    provider_id: providerID,
    provider_kind: providerKind,
    provider_metadata: {}
  }
}

function kind(providerKind: string, capabilities: string[]): AIGatewayProviderKindItem {
  return {
    capabilities,
    default_base_url: null,
    label: { default: providerKind },
    provider_kind: providerKind,
    settings: []
  }
}

describe('model profile options', () => {
  test('keeps web profiles provider-only while adapting the backend write contract', () => {
    for (const profile of ['web_search', 'web_fetch'] as const) {
      expect(profileUsesConfigurableModel(profile)).toBe(false)
      expect(modelProfileRequestFields(profile, { model: 'ignored', contextLength: '131072' })).toEqual({
        ok: true,
        fields: { model: 'default' }
      })
    }
    expect(modelProfileRequestFields('primary', { model: 'gpt-5', contextLength: '131072' })).toEqual({
      ok: true,
      fields: { model: 'gpt-5', context_length: 131072 }
    })
    expect(modelProfileRequestFields('vision_fallback', { model: 'gpt-5-vision', contextLength: '' })).toEqual({
      ok: true,
      fields: { model: 'gpt-5-vision' }
    })
  })

  test('rejects a context length that is not a positive integer instead of dropping it', () => {
    for (const contextLength of ['8k', 'abc', '12.5', '0', '-4', '1e6']) {
      expect(modelProfileRequestFields('primary', { model: 'gpt-5', contextLength })).toEqual({
        ok: false,
        error: 'integer'
      })
    }
    expect(modelProfileRequestFields('primary', { model: 'gpt-5', contextLength: ' 200000 ' })).toEqual({
      ok: true,
      fields: { model: 'gpt-5', context_length: 200_000 }
    })
  })

  test('filters configured providers by the profile capability declared in ProviderDSL', () => {
    const providers = [
      provider('openai-main', 'openai'),
      provider('jina-main', 'jina'),
      provider('jina-search-main', 'jina_search'),
      provider('jina-reader-main', 'jina_reader'),
      provider('parallel-main', 'parallel'),
      provider('openrouter-images', 'openrouter')
    ]
    const kinds = [
      kind('openai', ['llm']),
      kind('jina', ['embedding', 'rerank']),
      kind('jina_search', ['web_search']),
      kind('jina_reader', ['web_fetch']),
      kind('parallel', ['web_search', 'web_fetch']),
      kind('openrouter', ['llm', 'image_generate'])
    ]

    expect(providersForProfile(providers, kinds, 'primary').map(item => item.provider_id)).toEqual([
      'openai-main',
      'openrouter-images'
    ])
    expect(providersForProfile(providers, kinds, 'vision_fallback').map(item => item.provider_id)).toEqual([
      'openai-main',
      'openrouter-images'
    ])
    expect(providersForProfile(providers, kinds, 'web_search').map(item => item.provider_id)).toEqual([
      'jina-search-main',
      'parallel-main'
    ])
    expect(providersForProfile(providers, kinds, 'web_fetch').map(item => item.provider_id)).toEqual([
      'jina-reader-main',
      'parallel-main'
    ])
    expect(providersForProfile(providers, kinds, 'image_generate').map(item => item.provider_id)).toEqual([
      'openrouter-images'
    ])
  })

  test('shows no providers until capability metadata is available', () => {
    const providers = [provider('openai-main', 'openai'), provider('jina-main', 'jina')]

    expect(providersForProfile(providers, [], 'primary')).toEqual([])
  })

  test('filters typed provider-local model choices by capability and image input', () => {
    const catalog: AIGatewayModelCatalogEntry[] = [
      {
        provider_id: 'openai-main',
        model: 'gpt-5',
        name: 'GPT-5',
        description: 'General model',
        capability: 'llm',
        image_input: false
      },
      {
        provider_id: 'openai-main',
        model: 'gpt-5-vision',
        name: 'GPT-5 Vision',
        description: '',
        capability: 'llm',
        image_input: true
      },
      {
        provider_id: 'openrouter-images',
        model: 'openai/gpt-image-2',
        name: 'GPT Image 2',
        description: '',
        capability: 'image_generate',
        image_input: false
      },
      {
        provider_id: 'openai-main',
        model: 'tts-1',
        name: 'TTS 1',
        description: '',
        capability: 'other',
        image_input: false
      },
      {
        provider_id: 'jina-main',
        model: 'jina-embeddings-v3',
        name: 'Jina Embeddings v3',
        description: '',
        capability: 'embedding',
        image_input: false
      },
      {
        provider_id: 'jina-main',
        model: 'jina-reranker-v2',
        name: 'Jina Reranker v2',
        description: '',
        capability: 'rerank',
        image_input: false
      }
    ]
    expect(modelOptionsForProfile(catalog, 'openai-main', 'primary')).toEqual([
      { value: 'gpt-5', label: 'GPT-5', description: 'gpt-5' },
      { value: 'gpt-5-vision', label: 'GPT-5 Vision', description: 'gpt-5-vision' }
    ])
    expect(modelOptionsForProfile(catalog, 'openai-main', 'vision_fallback')).toEqual([
      { value: 'gpt-5-vision', label: 'GPT-5 Vision', description: 'gpt-5-vision' }
    ])
    expect(modelOptionsForProfile(catalog, 'jina-main', 'primary')).toEqual([])
    expect(modelOptionsForProfile(catalog, 'openrouter-images', 'image_generate')).toEqual([
      { value: 'openai/gpt-image-2', label: 'GPT Image 2', description: 'openai/gpt-image-2' }
    ])
  })

  test('shows account models for a ChatGPT subscription provider', () => {
    const catalog: AIGatewayModelCatalogEntry[] = [
      {
        provider_id: 'chatgpt_subscription',
        model: 'gpt-5.6-sol',
        name: 'GPT-5.6 Sol',
        description: 'Frontier coding model.',
        capability: 'llm',
        image_input: true
      }
    ]

    expect(modelOptionsForProfile(catalog, 'chatgpt_subscription', 'primary')).toEqual([
      {
        value: 'gpt-5.6-sol',
        label: 'GPT-5.6 Sol',
        description: 'gpt-5.6-sol'
      }
    ])
  })
})
