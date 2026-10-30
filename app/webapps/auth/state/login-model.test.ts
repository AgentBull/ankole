import { describe, expect, test } from 'bun:test'
import { InternalAPIError } from '../../common/internal-api-client'
import { classifyLoginError, LoginModel, tickLockout } from './login-model'

describe('classifyLoginError', () => {
  test('maps the sign-in endpoint contract onto inline form errors', () => {
    expect(
      classifyLoginError(new InternalAPIError(401, 'Unauthorized', { errors: [{ code: 'invalid_code' }] }))
    ).toEqual({
      kind: 'invalid_code'
    })
    expect(
      classifyLoginError(new InternalAPIError(403, 'Forbidden', { errors: [{ code: 'login_policy_rejected' }] }))
    ).toEqual({
      kind: 'sso_required'
    })
    expect(
      classifyLoginError(new InternalAPIError(403, 'Forbidden', { errors: [{ code: 'reauthentication_required' }] }))
    ).toEqual({
      kind: 'reauthentication_required'
    })
    expect(
      classifyLoginError(new InternalAPIError(403, 'Forbidden', { errors: [{ code: 'account_disabled' }] }))
    ).toEqual({
      kind: 'account_disabled'
    })
    expect(
      classifyLoginError(
        new InternalAPIError(429, 'Too Many Requests', {
          errors: [{ code: 'rate_limited', meta: { details: { retryAfterSeconds: 42 } } }]
        })
      )
    ).toEqual({ kind: 'locked', remainingSeconds: 42 })
  })

  test('leaves unrecognized failures to the generic error surface', () => {
    expect(classifyLoginError(new Error('network down'))).toBeUndefined()
    expect(
      classifyLoginError(new InternalAPIError(404, 'Not Found', { errors: [{ code: 'no_local_provider' }] }))
    ).toBeUndefined()
    expect(classifyLoginError(new InternalAPIError(500, 'Internal Server Error', {}))).toBeUndefined()
    expect(
      classifyLoginError(new InternalAPIError(429, 'Too Many Requests', { errors: [{ code: 'rate_limited' }] }))
    ).toBeUndefined()
  })
})

describe('tickLockout', () => {
  test('counts a lockout down by seconds and recovers at zero', () => {
    const locked = { kind: 'locked', remainingSeconds: 2 } as const

    expect(tickLockout(locked)).toEqual({ kind: 'locked', remainingSeconds: 1 })
    expect(tickLockout({ kind: 'locked', remainingSeconds: 1 })).toBeUndefined()
    expect(tickLockout({ kind: 'invalid_code' })).toEqual({ kind: 'invalid_code' })
    expect(tickLockout(undefined)).toBeUndefined()
  })
})

describe('LoginModel', () => {
  test('stores classified failures and keeps a lockout across form edits', () => {
    const model = new LoginModel()

    model.reportLoginError(new InternalAPIError(401, 'Unauthorized', { errors: [{ code: 'invalid_code' }] }))
    expect(model.formError.value).toEqual({ kind: 'invalid_code' })
    model.clearFormError()
    expect(model.formError.value).toBeUndefined()

    model.reportLoginError(
      new InternalAPIError(429, 'Too Many Requests', {
        errors: [{ code: 'rate_limited', meta: { details: { retryAfterSeconds: 30 } } }]
      })
    )
    model.clearFormError()
    expect(model.formError.value).toEqual({ kind: 'locked', remainingSeconds: 30 })
    model[Symbol.dispose]()
  })

  test('changing the account releases a lockout', () => {
    const model = new LoginModel()

    model.reportLoginError(
      new InternalAPIError(429, 'Too Many Requests', {
        errors: [{ code: 'rate_limited', meta: { details: { retryAfterSeconds: 30 } } }]
      })
    )
    // The lock belongs to one account on the server; editing the email means
    // another account, so the form must not stay frozen for it.
    model.changeAccount()
    expect(model.formError.value).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('clears the previous code when a fresh challenge is sent', () => {
    const model = new LoginModel()
    model.email.value = 'alice@example.com'
    model.code.value = '123456'
    model.reportLoginError(new InternalAPIError(401, 'Unauthorized', { errors: [{ code: 'invalid_code' }] }))
    model.resetCode()
    expect(model.code.value).toBe('')
    expect(model.email.value).toBe('alice@example.com')
    expect(model.formError.value).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('starts, restores and clears the resend countdown without locking verification', () => {
    const model = new LoginModel()
    model.startResendCooldown(60)
    expect(model.resendSeconds.value).toBe(60)
    expect(model.formError.value).toBeUndefined()
    model.restoreResendCooldown(Date.now() - 1000)
    model.updateResendCooldown()
    expect(model.resendSeconds.value).toBe(0)
    model.clearResendCooldown()
    expect(model.resendUntil.value).toBe(0)
    model[Symbol.dispose]()
  })
})
