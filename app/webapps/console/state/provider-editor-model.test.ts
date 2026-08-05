import { describe, expect, test } from 'bun:test'
import { nextProviderID, ProviderEditorModel } from './provider-editor-model'

describe('ProviderEditorModel', () => {
  test('uses the provider kind and the first available numeric suffix as a default id', () => {
    expect(nextProviderID('openrouter', [])).toBe('openrouter')
    expect(nextProviderID('openrouter', ['openrouter'])).toBe('openrouter-2')
    expect(nextProviderID('openrouter', ['openrouter', 'openrouter-2', 'openrouter-4'])).toBe('openrouter-3')
  })

  test('initializes once per provider source so background refreshes do not replace edits', () => {
    const model = new ProviderEditorModel()

    model.initialize('provider:openai', {
      providerID: 'openai',
      providerKind: 'openai',
      baseURL: 'https://api.example.com/v1',
      options: { api_key: '' }
    })
    expect(model.dirty.value).toBe(false)
    model.baseURL.value = 'https://proxy.example.com/v1'
    expect(model.dirty.value).toBe(true)

    model.initialize('provider:openai', {
      providerID: 'openai',
      providerKind: 'openai',
      baseURL: 'https://refetched.example.com/v1',
      options: { api_key: '' }
    })

    expect(model.baseURL.value).toBe('https://proxy.example.com/v1')

    model.initialize('provider:anthropic', {
      providerID: 'anthropic',
      providerKind: 'anthropic',
      baseURL: 'https://api.anthropic.com',
      options: { api_key: '' }
    })

    expect(model.providerID.value).toBe('anthropic')
    expect(model.baseURL.value).toBe('https://api.anthropic.com')
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('replaces the generated id when the provider kind changes', () => {
    const model = new ProviderEditorModel()

    model.initialize('new', {
      providerID: 'openai',
      providerKind: 'openai',
      baseURL: 'https://api.openai.com/v1',
      options: {}
    })
    model.changeKind({
      providerID: 'openrouter-2',
      providerKind: 'openrouter',
      baseURL: 'https://openrouter.ai/api/v1',
      options: {}
    })

    expect(model.providerID.value).toBe('openrouter-2')
    expect(model.providerKind.value).toBe('openrouter')
    model[Symbol.dispose]()
  })
})
