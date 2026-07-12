import { describe, expect, test } from 'bun:test'
import { IdentityEditorModel } from './identity-editor-model'

describe('IdentityEditorModel', () => {
  test('switching adapter resets all adapter-owned fields together', () => {
    const model = new IdentityEditorModel()

    model.initialize('new', {
      adapterID: 'oidc',
      providerID: 'company',
      enabled: true,
      config: { issuer: 'https://id.example.com' }
    })
    model.changeAdapter({
      adapterID: 'google',
      providerID: 'google-workspace',
      enabled: true,
      config: { domain: 'example.com' }
    })

    expect(model.adapterID.value).toBe('google')
    expect(model.providerID.value).toBe('google-workspace')
    expect(model.config.value).toEqual({ domain: 'example.com' })
    model[Symbol.dispose]()
  })
})
