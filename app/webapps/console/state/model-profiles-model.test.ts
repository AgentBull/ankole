import { describe, expect, test } from 'bun:test'
import { ModelProfilesModel, PROFILE_NAMES } from './model-profiles-model'

describe('ModelProfilesModel', () => {
  test('exposes and initializes every provider-backed profile', () => {
    const model = new ModelProfilesModel()

    expect(PROFILE_NAMES).toContain('web_search')
    expect(PROFILE_NAMES).toContain('web_fetch')
    expect(PROFILE_NAMES).toContain('image_generate')
    expect(PROFILE_NAMES).toContain('vision_fallback')
    model.initialize('agent:alpha', {
      vision_fallback: { providerID: 'openrouter-main', model: 'google/gemini-vision' },
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
    expect(model.snapshot('vision_fallback')).toMatchObject({
      providerID: 'openrouter-main',
      model: 'google/gemini-vision'
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
    expect(model.snapshot('primary')).toMatchObject({ providerID: 'anthropic', model: 'claude' })

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

  test('keeps post-submission edits dirty while applying the persisted profile as the new source', () => {
    const model = new ModelProfilesModel()
    model.initialize('agent:alpha', {
      primary: { providerID: 'openai', model: 'original-model' }
    })
    model.update('primary', { model: 'submitted-model' })
    const submission = model.submission('primary')

    model.update('primary', { model: 'newer-unsaved-model' })
    const result = model.markSaved('primary', { providerID: 'openai', model: 'submitted-model' }, submission)

    expect(result).toEqual({ hasUnsavedChanges: true })
    expect(model.profiles.primary.source.value).toMatchObject({ model: 'submitted-model' })
    expect(model.snapshot('primary')).toMatchObject({ model: 'newer-unsaved-model' })
    expect(model.profiles.primary.dirty.value).toBeTrue()

    model.initialize('agent:alpha', {
      primary: { providerID: 'openai', model: 'submitted-model' }
    })
    expect(model.snapshot('primary')).toMatchObject({ model: 'newer-unsaved-model' })

    const newerSubmission = model.submission('primary')
    expect(model.markSaved('primary', { providerID: 'openai', model: 'newer-unsaved-model' }, newerSubmission)).toEqual(
      { hasUnsavedChanges: false }
    )
    expect(model.profiles.primary.dirty.value).toBeFalse()
    model[Symbol.dispose]()
  })
})
