import { describe, expect, test } from 'bun:test'
import { IdentitySetupModel } from './identity-setup-model'

describe('IdentitySetupModel', () => {
  test('initializes once and switches all adapter-owned fields together', () => {
    const model = new IdentitySetupModel()

    model.initialize('setup-identity', {
      adapterID: 'oidc',
      providerID: 'company',
      config: { issuer: 'https://id.example.com' }
    })
    model.providerID.value = 'edited-company'
    model.initialize('setup-identity', {
      adapterID: 'google',
      providerID: 'ignored-refetch',
      config: {}
    })

    expect(model.submission()).toEqual({
      adapterID: 'oidc',
      providerID: 'edited-company',
      config: { issuer: 'https://id.example.com' }
    })

    model.changeAdapter({
      adapterID: 'google',
      providerID: 'google-workspace',
      config: { domain: 'example.com' }
    })

    expect(model.submission()).toEqual({
      adapterID: 'google',
      providerID: 'google-workspace',
      config: { domain: 'example.com' }
    })
    model[Symbol.dispose]()
  })
})
