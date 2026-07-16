import { describe, expect, test } from 'bun:test'
import { ModelProfilesModel, PROFILE_NAMES } from './model-profiles-model'

describe('ModelProfilesModel', () => {
  test('exposes and initializes provider-backed web profiles', () => {
    const model = new ModelProfilesModel()

    expect(PROFILE_NAMES).toContain('web_search')
    expect(PROFILE_NAMES).toContain('web_fetch')
    expect(PROFILE_NAMES).toContain('image_generate')
    model.initialize('agent:alpha', {
      web_search: { providerID: 'jina-search-main', model: 'default' },
      web_fetch: { providerID: 'jina-reader-main', model: 'default' },
      image_generate: { providerID: 'openrouter-main', model: 'openai/gpt-image-2' }
    })

    expect(model.snapshot('web_search')).toMatchObject({
      providerID: 'jina-search-main',
      model: 'default'
    })
    expect(model.snapshot('web_fetch')).toMatchObject({
      providerID: 'jina-reader-main',
      model: 'default'
    })
    expect(model.snapshot('image_generate')).toMatchObject({
      providerID: 'openrouter-main',
      model: 'openai/gpt-image-2'
    })
    model[Symbol.dispose]()
  })

  test('saving or refreshing one profile does not replace another unsaved draft', () => {
    const model = new ModelProfilesModel()

    model.initialize('agent:alpha', {
      primary: { providerID: 'openai', model: 'gpt-5' },
      light: { providerID: 'openai', model: 'gpt-5-mini' }
    })
    model.update('light', { model: 'local-unsaved-model' })
    model.initialize('agent:alpha', {
      primary: { providerID: 'anthropic', model: 'claude' },
      light: { providerID: 'openai', model: 'server-refetch' }
    })

    expect(model.snapshot('light').model).toBe('local-unsaved-model')

    model.clear('light')
    expect(model.snapshot('light')).toEqual({
      codexAccountID: '',
      providerID: '',
      model: '',
      contextLength: '',
      providerOptions: {},
      error: undefined
    })
    model[Symbol.dispose]()
  })
})
