import { describe, expect, test } from 'bun:test'
import type {
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem
} from '../api/generated/types.gen'
import {
  modelOptionsForProfile,
  modelProfileRequestFields,
  profileUsesConfigurableModel,
  providersForProfile
} from '../pages/model-profile-options'

function provider(providerID: string, providerKind: string): AIGatewayProviderItem {
  return {
    connection_options: {},
    encrypted_options: {},
    id: providerID,
    provider_id: providerID,
    provider_kind: providerKind,
    provider_metadata: {}
  }
}

function kind(providerKind: string, capabilities: string[]): AIGatewayProviderKindItem {
  return {
    capabilities,
    capability_specs: [],
    connection_options: [],
    default_base_url: null,
    label: { default: providerKind },
    provider_kind: providerKind,
    runtime_provider_options: [],
    settings: []
  }
}

describe('model profile options', () => {
  test('keeps web search provider-only while adapting the backend write contract', () => {
    expect(profileUsesConfigurableModel('web_search')).toBe(false)
    expect(modelProfileRequestFields('web_search', { model: 'ignored', contextLength: '131072' })).toEqual({
      model: 'default'
    })
    expect(modelProfileRequestFields('primary', { model: 'gpt-5', contextLength: '131072' })).toEqual({
      model: 'gpt-5',
      context_length: 131072
    })
  })

  test('filters configured providers by the profile capability declared in ProviderDSL', () => {
    const providers = [
      provider('openai-main', 'openai'),
      provider('jina-main', 'jina'),
      provider('jina-search-main', 'jina_search')
    ]
    const kinds = [kind('openai', ['llm']), kind('jina', ['embedding', 'rerank']), kind('jina_search', ['web_search'])]

    expect(providersForProfile(providers, kinds, 'primary').map(item => item.provider_id)).toEqual(['openai-main'])
    expect(providersForProfile(providers, kinds, 'embedding').map(item => item.provider_id)).toEqual(['jina-main'])
    expect(providersForProfile(providers, kinds, 'web_search').map(item => item.provider_id)).toEqual([
      'jina-search-main'
    ])
  })

  test('turns catalog selectors into provider-local model choices', () => {
    const catalog = {
      data: [
        {
          id: 'openai-main/gpt-5',
          name: 'GPT-5',
          description: 'General model',
          architecture: { output_modalities: ['text'] },
          supported_parameters: ['tools']
        },
        {
          id: 'openai-main/gpt-image-1',
          name: 'GPT Image 1',
          architecture: { output_modalities: ['image'] },
          supported_parameters: []
        },
        {
          id: 'openai-main/tts-1',
          name: 'TTS 1',
          architecture: { output_modalities: ['audio'] },
          supported_parameters: []
        },
        {
          id: 'jina-main/jina-embeddings-v3',
          name: 'Jina Embeddings v3',
          architecture: { output_modalities: ['embeddings'] },
          supported_parameters: ['input', 'encoding_format']
        },
        {
          id: 'jina-main/jina-reranker-v2',
          name: 'Jina Reranker v2',
          architecture: { output_modalities: ['text'] },
          supported_parameters: ['query', 'documents', 'top_n']
        }
      ]
    }

    expect(modelOptionsForProfile(catalog, 'openai-main', 'primary')).toEqual([
      { value: 'gpt-5', label: 'GPT-5', description: 'gpt-5' }
    ])
    expect(modelOptionsForProfile(catalog, 'jina-main', 'embedding')).toEqual([
      { value: 'jina-embeddings-v3', label: 'Jina Embeddings v3', description: 'jina-embeddings-v3' }
    ])
    expect(modelOptionsForProfile(catalog, 'jina-main', 'rerank')).toEqual([
      { value: 'jina-reranker-v2', label: 'Jina Reranker v2', description: 'jina-reranker-v2' }
    ])
  })

  test('falls back to known provider models when upstream capability metadata is incomplete', () => {
    const catalog = { data: [{ id: 'custom-main/private-model', name: 'Private model' }] }

    expect(modelOptionsForProfile(catalog, 'custom-main', 'embedding')).toEqual([
      { value: 'private-model', label: 'Private model', description: 'private-model' }
    ])
  })
})
