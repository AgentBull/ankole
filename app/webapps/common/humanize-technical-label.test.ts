import { describe, expect, test } from 'bun:test'
import { humanizeTechnicalLabel } from './humanize-technical-label'

describe('humanizeTechnicalLabel', () => {
  test('preserves the approved casing of technical terms', () => {
    expect(humanizeTechnicalLabel('oauth')).toBe('OAuth')
    expect(humanizeTechnicalLabel('oidc_provider_id')).toBe('OIDC provider ID')
    expect(humanizeTechnicalLabel('strictJSONSchema')).toBe('Strict JSON schema')
  })

  test('turns an enum value into a sentence-case label', () => {
    expect(humanizeTechnicalLabel('enterprise_access_token')).toBe('Enterprise access token')
  })
})
