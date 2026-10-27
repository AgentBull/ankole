import { batch, createModel, signal } from '@preact/signals-react'
import { requestErrorCode, requestErrorDetails } from '../../common/request-errors'
import { InternalAPIError } from '../../common/internal-api-client'

export type LoginFormError =
  | { kind: 'invalid_code' }
  | { kind: 'not_admin' }
  | { kind: 'account_disabled' }
  | { kind: 'sso_required' | 'reauthentication_required' }
  | { kind: 'locked'; remainingSeconds: number }

/**
 * Classifies a code verification failure into the inline form errors the login
 * form owns. Every other failure returns undefined and stays with the generic
 * request-error surface.
 */
export function classifyLoginError(error: unknown): LoginFormError | undefined {
  if (!(error instanceof InternalAPIError)) return undefined

  const code = requestErrorCode(error.payload)
  if (error.status === 401 && code === 'invalid_code') return { kind: 'invalid_code' }
  if (error.status === 403 && code === 'not_an_admin') return { kind: 'not_admin' }
  if (error.status === 403 && code === 'login_policy_rejected') return { kind: 'sso_required' }
  if (error.status === 403 && code === 'reauthentication_required') return { kind: 'reauthentication_required' }
  if (error.status === 403 && code === 'account_disabled') return { kind: 'account_disabled' }

  if (error.status === 429 && code === 'rate_limited') {
    const seconds = requestErrorDetails(error.payload).retryAfterSeconds
    if (typeof seconds === 'number' && seconds > 0) {
      return { kind: 'locked', remainingSeconds: Math.ceil(seconds) }
    }
  }

  return undefined
}

export function tickLockout(error: LoginFormError | undefined): LoginFormError | undefined {
  if (error?.kind !== 'locked') return error
  if (error.remainingSeconds <= 1) return undefined
  return { ...error, remainingSeconds: error.remainingSeconds - 1 }
}

export const LoginModel = createModel(() => {
  const email = signal('')
  const code = signal('')
  const formError = signal<LoginFormError>()
  const resendSeconds = signal(0)
  const resendUntil = signal(0)

  return {
    email,
    code,
    formError,
    resendSeconds,
    resendUntil,
    advanceLockout() {
      formError.value = tickLockout(formError.value)
    },
    startResendCooldown(seconds: number) {
      resendUntil.value = Date.now() + seconds * 1000
      resendSeconds.value = seconds
    },
    restoreResendCooldown(until: number) {
      resendUntil.value = until
      resendSeconds.value = Math.max(0, Math.ceil((until - Date.now()) / 1000))
    },
    updateResendCooldown() {
      const seconds = Math.max(0, Math.ceil((resendUntil.value - Date.now()) / 1000))
      resendSeconds.value = seconds
      if (seconds === 0) resendUntil.value = 0
    },
    clearResendCooldown() {
      resendUntil.value = 0
      resendSeconds.value = 0
    },
    reportLoginError(error: unknown) {
      formError.value = classifyLoginError(error)
    },
    /**
     * Clears the inline error when the person edits the code. A lockout
     * stays: it disables the submit until its countdown reaches zero.
     */
    clearFormError() {
      if (formError.value?.kind === 'locked') return
      formError.value = undefined
    },
    /**
     * Clears every inline error, including a lockout. The lockout is per
     * account on the server, so editing the email means a different account
     * and the client must not keep the form frozen for it.
     */
    changeAccount() {
      formError.value = undefined
    },
    resetCode() {
      batch(() => {
        code.value = ''
        formError.value = undefined
      })
    }
  }
})
