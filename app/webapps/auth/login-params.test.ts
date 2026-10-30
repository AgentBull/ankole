import { expect, test } from 'bun:test'
import { loginContextKey, readLoginSearch, signInReturnTo } from './login-params'

test('readLoginSearch returns empty query, context, and authorizationParams on plain /sessions/new', () => {
  const parsed = readLoginSearch('')
  expect(parsed.query).toEqual({})
  expect(parsed.context).toEqual({})
  expect(parsed.authorizationParams.toString()).toBe('')
})

test('readLoginSearch maps ceremony query parameters for providers, email OTP, and SSO authorization', () => {
  const parsed = readLoginSearch(
    '?oauth_request=018f0000-0000-7000-8000-000000000001&console_return=sealed-console-ticket&tenant_id=018f0000-0000-7000-8000-000000000099&return_to=%2Fme&prompt=login&switch=1&reauth=ticket&invitation_token=inv-token'
  )
  expect(parsed.query).toEqual({
    oauth_request: '018f0000-0000-7000-8000-000000000001',
    console_return: 'sealed-console-ticket',
    tenant_id: '018f0000-0000-7000-8000-000000000099',
    prompt: 'login',
    switch: '1',
    reauth: 'ticket',
    invitation_token: 'inv-token'
  })
  expect(parsed.context).toEqual({
    oauthRequest: '018f0000-0000-7000-8000-000000000001',
    consoleReturn: 'sealed-console-ticket',
    tenantID: '018f0000-0000-7000-8000-000000000099',
    returnTo: '/me',
    prompt: 'login',
    reauth: 'ticket',
    invitationToken: 'inv-token'
  })
  expect(parsed.authorizationParams.get('switch')).toBeNull()
  expect(parsed.authorizationParams.get('tenant_id')).toBeNull()
  expect(parsed.authorizationParams.get('oauth_request')).toBe('018f0000-0000-7000-8000-000000000001')
  expect(parsed.authorizationParams.get('console_return')).toBe('sealed-console-ticket')
  expect(parsed.authorizationParams.get('return_to')).toBe('/me')
  expect(parsed.authorizationParams.get('invitation_token')).toBe('inv-token')
})

test('loginContextKey isolates distinct ceremonies while remaining stable across plain reloads', () => {
  expect(loginContextKey({})).toBe(loginContextKey(undefined))
  expect(loginContextKey({ oauthRequest: 'req-a' })).not.toBe(loginContextKey({ oauthRequest: 'req-b' }))
  expect(loginContextKey({ tenantID: 'pod-a' })).not.toBe(loginContextKey({ tenantID: 'pod-b' }))
  expect(loginContextKey({ consoleReturn: 'ret-a' })).not.toBe(loginContextKey({ consoleReturn: 'ret-b' }))
})

const origin = 'https://ankole.example'
test.each([
  null,
  '',
  '//evil.example',
  '/\\evil.example',
  '/\t/evil.example',
  '/a/..//evil.example',
  '/a/%2e%2e//evil.example',
  'https://evil.example',
  '/sessions/logged-out?return_to=/',
  '/a/../sessions/logged-out'
])('post-logout sign-in rejects external or looping destination %s', value => {
  expect(signInReturnTo(value, origin)).toBe('/sessions/new')
})
test('post-logout sign-in preserves the local destination, query, and fragment', () => {
  expect(signInReturnTo('/site-admin-console/tenants?sort=name#active', origin)).toBe(
    '/site-admin-console/tenants?sort=name#active'
  )
})
