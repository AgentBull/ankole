import { describe, expect, test } from 'bun:test'
import { ModelProfilesModel, PROFILE_NAMES } from './model-profiles-model'

describe('ModelProfilesModel', () => {
  test('exposes and initializes the web search profile', () => {
    const model = new ModelProfilesModel()

    expect(PROFILE_NAMES).toContain('web_search')
    model.initialize('agent:alpha', {
      web_search: { providerID: 'jina-search-main', model: 'default' }
    })

    expect(model.snapshot('web_search')).toMatchObject({
      providerID: 'jina-search-main',
      model: 'default'
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
