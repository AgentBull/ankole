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

  test('does not mark options dirty when keys are reordered with identical values', () => {
    using model = new ProviderEditorModel()

    model.initialize('provider:openrouter', {
      providerID: 'openrouter',
      providerKind: 'openrouter',
      baseURL: 'https://openrouter.ai/api/v1',
      options: { app_referer: 'https://ankole.test', app_title: 'Ankole' }
    })
    expect(model.dirty.value).toBe(false)

    model.options.value = { app_title: 'Ankole', app_referer: 'https://ankole.test' }
    expect(model.dirty.value).toBe(false)

    model.setOption('app_title', 'Ankole Console')
    expect(model.dirty.value).toBe(true)
  })
})

describe('Provider save acknowledgement', () => {
  const initial = { providerID: 'openai', providerKind: 'openai', baseURL: 'initial', options: {} }

  test('confirms the sent snapshot and preserves edits made while the request is pending', async () => {
    using model = new ProviderEditorModel()
    model.initialize('provider:openai', initial)
    model.baseURL.value = 'sent-A'
    const request = Promise.withResolvers<string>()
    const completions: boolean[] = []
    const pending = model.save(
      draft => {
        expect(draft.baseURL).toBe('sent-A')
        return request.promise
      },
      (_response, clean) => completions.push(clean)
    )
    model.baseURL.value = 'unsent-B'
    request.resolve('saved-A')
    await pending
    expect(model.baseURL.value).toBe('unsent-B')
    expect(model.dirty.value).toBe(true)
    expect(completions).toEqual([false])

    await model.save(
      async draft => {
        expect(draft.baseURL).toBe('unsent-B')
        return 'saved-B'
      },
      (_response, clean) => completions.push(clean)
    )
    expect(completions).toEqual([false, true])
    expect(model.dirty.value).toBe(false)
  })

  test('normal success acknowledges the snapshot and permits the original success navigation', async () => {
    using model = new ProviderEditorModel()
    model.initialize('new', initial)
    model.baseURL.value = 'sent-A'
    const navigations: string[] = []
    await model.save(
      async () => ({ providerID: 'openai' }),
      (response, clean) => {
        expect(clean).toBe(true)
        if (clean) navigations.push(`/providers/${response.providerID}`)
      }
    )
    expect(model.dirty.value).toBe(false)
    expect(navigations).toEqual(['/providers/openai'])
  })

  test('leaving and revisiting the same resource revokes old completion and feedback', async () => {
    using model = new ProviderEditorModel()
    model.initialize('provider:openai', initial)
    model.baseURL.value = 'sent-A'
    const request = Promise.withResolvers<void>()
    let completed = false
    const pending = model.save(
      () => request.promise,
      () => {
        completed = true
      }
    )
    model.resetSource()
    model.initialize('provider:other', { ...initial, providerID: 'other' })
    model.resetSource()
    model.initialize('provider:openai', initial)
    model.baseURL.value = 'new-visit'
    request.resolve()
    await pending
    expect(completed).toBe(false)
    expect(model.baseURL.value).toBe('new-visit')
    expect(model.dirty.value).toBe(true)
  })
})
