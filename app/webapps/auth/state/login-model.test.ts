import { describe, expect, test } from 'bun:test'
import { InternalAPIError } from '../../common/internal-api-client'
import { classifyLoginError, formatRetryDelay, LoginModel, tickLockout } from './login-model'

describe('classifyLoginError', () => {
  test('maps the sign-in endpoint contract onto inline form errors', () => {
    expect(classifyLoginError(new InternalAPIError(401, 'Unauthorized', { error: 'invalid_credentials' }))).toEqual({
      kind: 'invalid_credentials'
    })
    expect(classifyLoginError(new InternalAPIError(403, 'Forbidden', { error: 'not_an_admin' }))).toEqual({
      kind: 'not_admin'
    })
    expect(classifyLoginError(new InternalAPIError(403, 'Forbidden', { error: 'account_disabled' }))).toEqual({
      kind: 'account_disabled'
    })
    expect(
      classifyLoginError(
        new InternalAPIError(429, 'Too Many Requests', { error: 'retry_locked', retryAfterSeconds: 42 })
      )
    ).toEqual({ kind: 'locked', remainingSeconds: 42 })
  })

  test('leaves unrecognized failures to the generic error surface', () => {
    expect(classifyLoginError(new Error('network down'))).toBeUndefined()
    expect(classifyLoginError(new InternalAPIError(404, 'Not Found', { error: 'no_local_provider' }))).toBeUndefined()
    expect(classifyLoginError(new InternalAPIError(500, 'Internal Server Error', {}))).toBeUndefined()
    expect(
      classifyLoginError(new InternalAPIError(429, 'Too Many Requests', { error: 'retry_locked' }))
    ).toBeUndefined()
  })
})

describe('formatRetryDelay', () => {
  test('reports exact seconds below 90 and rounded-up minutes from 90', () => {
    expect(formatRetryDelay(1)).toEqual({ unit: 'seconds', seconds: 1 })
    expect(formatRetryDelay(89)).toEqual({ unit: 'seconds', seconds: 89 })
    expect(formatRetryDelay(90)).toEqual({ unit: 'minutes', minutes: 2 })
    expect(formatRetryDelay(120)).toEqual({ unit: 'minutes', minutes: 2 })
    expect(formatRetryDelay(121)).toEqual({ unit: 'minutes', minutes: 3 })
    expect(formatRetryDelay(1800)).toEqual({ unit: 'minutes', minutes: 30 })
  })
})

describe('tickLockout', () => {
  test('counts a lockout down by seconds and recovers at zero', () => {
    const locked = { kind: 'locked', remainingSeconds: 2 } as const

    expect(tickLockout(locked)).toEqual({ kind: 'locked', remainingSeconds: 1 })
    expect(tickLockout({ kind: 'locked', remainingSeconds: 1 })).toBeUndefined()
    expect(tickLockout({ kind: 'invalid_credentials' })).toEqual({ kind: 'invalid_credentials' })
    expect(tickLockout(undefined)).toBeUndefined()
  })
})

describe('LoginModel', () => {
  test('stores classified failures and keeps a lockout across form edits', () => {
    const model = new LoginModel()

    model.reportLoginError(new InternalAPIError(401, 'Unauthorized', { error: 'invalid_credentials' }))
    expect(model.formError.value).toEqual({ kind: 'invalid_credentials' })
    model.clearFormError()
    expect(model.formError.value).toBeUndefined()

    model.reportLoginError(
      new InternalAPIError(429, 'Too Many Requests', { error: 'retry_locked', retryAfterSeconds: 30 })
    )
    model.clearFormError()
    expect(model.formError.value).toEqual({ kind: 'locked', remainingSeconds: 30 })
    model[Symbol.dispose]()
  })

  test('changing the account releases a lockout', () => {
    const model = new LoginModel()

    model.reportLoginError(
      new InternalAPIError(429, 'Too Many Requests', { error: 'retry_locked', retryAfterSeconds: 30 })
    )
    // The lock belongs to one account on the server; editing the email means
    // another account, so the form must not stay frozen for it.
    model.changeAccount()
    expect(model.formError.value).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('switches views and drops stale errors on each transition', () => {
    const model = new LoginModel()

    model.reportLoginError(new InternalAPIError(401, 'Unauthorized', { error: 'invalid_credentials' }))
    model.enterChangePassword()
    expect(model.view.value).toBe('change_password')
    expect(model.formError.value).toBeUndefined()

    model.backToLogin()
    expect(model.view.value).toBe('login')
    model[Symbol.dispose]()
  })
})
