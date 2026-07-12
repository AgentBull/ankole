import { describe, expect, test } from 'bun:test'
import { ProviderEditorModel } from './provider-editor-model'

describe('ProviderEditorModel', () => {
  test('initializes once per provider source so background refreshes do not replace edits', () => {
    const model = new ProviderEditorModel()

    model.initialize('provider:openai', {
      providerID: 'openai',
      providerKind: 'openai',
      baseURL: 'https://api.example.com/v1',
      options: { api_key: '' }
    })
    model.baseURL.value = 'https://proxy.example.com/v1'

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
    model[Symbol.dispose]()
  })
})
