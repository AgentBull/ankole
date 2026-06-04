import { describe, expect, it } from 'bun:test'
import { identityProviderOidcCallbackPath, identityProviderOidcRedirectUri, requestPublicBaseUrl } from './oidc'

describe('identity provider OIDC callback URLs', () => {
  it('uses the sessions callback path expected by local Lark/Feishu OIDC apps', () => {
    const request = new Request('http://localhost:3000/api/identity-providers/lark-main/oidc/authorizations')

    expect(identityProviderOidcCallbackPath('lark-main')).toBe('/sessions/oidc/lark-main/callback')
    expect(requestPublicBaseUrl(request)).toBe('http://localhost:3000')
    expect(identityProviderOidcRedirectUri(requestPublicBaseUrl(request), 'lark-main')).toBe(
      'http://localhost:3000/sessions/oidc/lark-main/callback'
    )
  })

  it('normalizes trailing slashes on configured public base URLs', () => {
    expect(identityProviderOidcRedirectUri('https://agent.example.com///', 'lark-main')).toBe(
      'https://agent.example.com/sessions/oidc/lark-main/callback'
    )
  })
})
