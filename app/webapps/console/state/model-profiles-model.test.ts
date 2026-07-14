import { describe, expect, test } from 'bun:test'
import { ModelProfilesModel } from './model-profiles-model'

describe('ModelProfilesModel', () => {
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
