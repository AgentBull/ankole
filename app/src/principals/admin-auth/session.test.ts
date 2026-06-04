import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '../../common/tests/load-test-env'

await loadTestEnvFiles()

const {
  ADMIN_OIDC_STATE_COOKIE,
  ADMIN_SESSION_COOKIE,
  cookieHeader,
  createAdminSessionCookie,
  createOidcStateCookie,
  expiredCookieHeader,
  readAdminSessionCookie,
  readOidcStateCookie,
  safeReturnTo
} = await import('./session')

describe('admin auth session cookies', () => {
  it('seals and reads admin session payloads from HTTP-only cookies', () => {
    const sealed = createAdminSessionCookie({
      principalUid: 'alice',
      providerId: 'lark-main',
      externalId: 'user_123'
    })
    const header = cookieHeader(ADMIN_SESSION_COOKIE, sealed, { secure: false })
    const parsed = readAdminSessionCookie(header)

    expect(parsed).toMatchObject({
      principalUid: 'alice',
      providerId: 'lark-main',
      externalId: 'user_123'
    })
    expect(header).toContain('HttpOnly')
    expect(header).toContain('SameSite=Lax')
  })

  it('rejects tampered OIDC state cookies and clears cookies with Max-Age=0', () => {
    const sealed = createOidcStateCookie({
      providerId: 'lark-main',
      state: 'state',
      nonce: 'nonce',
      returnTo: '/admin',
      redirectUri: 'https://admin.example.com/sessions/oidc/lark-main/callback'
    })

    expect(readOidcStateCookie(`${ADMIN_OIDC_STATE_COOKIE}=${encodeURIComponent(sealed)}`)).toMatchObject({
      providerId: 'lark-main',
      state: 'state',
      nonce: 'nonce'
    })
    expect(readOidcStateCookie(`${ADMIN_OIDC_STATE_COOKIE}=${encodeURIComponent(`${sealed}x`)}`)).toBeUndefined()
    expect(readOidcStateCookie(`${ADMIN_OIDC_STATE_COOKIE}=%E0%A4%A`)).toBeUndefined()
    expect(expiredCookieHeader(ADMIN_OIDC_STATE_COOKIE, true)).toContain('Max-Age=0')
    expect(expiredCookieHeader(ADMIN_OIDC_STATE_COOKIE, true)).toContain('Secure')
  })

  it('only allows same-site return targets', () => {
    expect(safeReturnTo('/console/settings')).toBe('/console/settings')
    expect(safeReturnTo('https://evil.example.com/admin')).toBe('/console')
    expect(safeReturnTo('//evil.example.com/admin')).toBe('/console')
    expect(safeReturnTo(undefined)).toBe('/console')
  })
})
