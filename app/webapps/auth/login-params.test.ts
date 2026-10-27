import { expect, test } from 'bun:test'
import { loginContextKey, readLoginSearch } from './login-params'

test('readLoginSearch returns empty query, context, and authorizationParams on plain /sessions/new', () => {
  const parsed = readLoginSearch('')
  expect(parsed.query).toEqual({})
  expect(parsed.context).toEqual({})
  expect(parsed.authorizationParams.toString()).toBe('')
})

test('readLoginSearch maps ceremony query parameters for providers, email OTP, and SSO authorization', () => {
  const parsed = readLoginSearch(
    '?oauth_request=018f0000-0000-7000-8000-000000000001&purpose=console&return_to=%2Fme&prompt=login&switch=1&reauth=ticket&invitation_token=inv-token'
  )
  expect(parsed.query).toEqual({
    oauth_request: '018f0000-0000-7000-8000-000000000001',
    purpose: 'console',
    prompt: 'login',
    switch: '1',
    reauth: 'ticket',
    invitation_token: 'inv-token'
  })
  expect(parsed.context).toEqual({
    oauthRequest: '018f0000-0000-7000-8000-000000000001',
    purpose: 'console',
    returnTo: '/me',
    prompt: 'login',
    reauth: 'ticket',
    invitationToken: 'inv-token'
  })
  expect(parsed.authorizationParams.get('switch')).toBeNull()
  expect(parsed.authorizationParams.get('oauth_request')).toBe('018f0000-0000-7000-8000-000000000001')
  expect(parsed.authorizationParams.get('return_to')).toBe('/me')
  expect(parsed.authorizationParams.get('invitation_token')).toBe('inv-token')
})

test('loginContextKey isolates distinct ceremonies while remaining stable across plain reloads', () => {
  expect(loginContextKey({})).toBe(loginContextKey(undefined))
  expect(loginContextKey({ oauthRequest: 'req-a' })).not.toBe(loginContextKey({ oauthRequest: 'req-b' }))
})
