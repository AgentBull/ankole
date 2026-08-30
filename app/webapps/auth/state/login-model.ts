import { batch, createModel, effect, signal } from '@preact/signals-react'
import { InternalAPIError } from '../../common/internal-api-client'

export type LoginView = 'login' | 'change_password'

export type LoginFormError =
  | { kind: 'invalid_credentials' }
  | { kind: 'not_admin' }
  | { kind: 'account_disabled' }
  | { kind: 'locked'; remainingSeconds: number }

export type RetryDelay = { unit: 'seconds'; seconds: number } | { unit: 'minutes'; minutes: number }

/** Formats a lockout delay as exact seconds, or rounded-up minutes from 90s. */
export function formatRetryDelay(seconds: number): RetryDelay {
  if (seconds < 90) return { unit: 'seconds', seconds }
  return { unit: 'minutes', minutes: Math.ceil(seconds / 60) }
}

/**
 * Classifies a password sign-in failure into the inline form errors the login
 * form owns. Every other failure returns undefined and stays with the generic
 * request-error surface.
 */
export function classifyLoginError(error: unknown): LoginFormError | undefined {
  if (!(error instanceof InternalAPIError)) return undefined

  const code = payloadField(error.payload, 'error')
  if (error.status === 401 && code === 'invalid_credentials') return { kind: 'invalid_credentials' }
  if (error.status === 403 && code === 'not_an_admin') return { kind: 'not_admin' }
  if (error.status === 403 && code === 'account_disabled') return { kind: 'account_disabled' }

  if (error.status === 429 && code === 'retry_locked') {
    const seconds = payloadField(error.payload, 'retryAfterSeconds')
    if (typeof seconds === 'number' && seconds > 0) return { kind: 'locked', remainingSeconds: Math.ceil(seconds) }
  }

  return undefined
}

/** Advances the lockout countdown by one second; at zero the form recovers. */
export function tickLockout(error: LoginFormError | undefined): LoginFormError | undefined {
  if (error?.kind !== 'locked') return error
  if (error.remainingSeconds <= 1) return undefined
  return { kind: 'locked', remainingSeconds: error.remainingSeconds - 1 }
}

export const LoginModel = createModel(() => {
  const view = signal<LoginView>('login')
  const formError = signal<LoginFormError>()

  // Every locked state schedules exactly one 1s timer: each tick writes a new
  // value, which re-runs the effect. Disposal and recovery clear the timer.
  effect(() => {
    const current = formError.value
    if (current?.kind !== 'locked') return

    const timer = setTimeout(() => {
      formError.value = tickLockout(current)
    }, 1000)

    return () => clearTimeout(timer)
  })

  return {
    view,
    formError,
    reportLoginError(error: unknown) {
      formError.value = classifyLoginError(error)
    },
    /**
     * Clears the inline error when the operator edits the password. A lockout
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
    enterChangePassword() {
      batch(() => {
        view.value = 'change_password'
        formError.value = undefined
      })
    },
    backToLogin() {
      batch(() => {
        view.value = 'login'
        formError.value = undefined
      })
    }
  }
})

function payloadField(payload: unknown, field: string): unknown {
  if (payload && typeof payload === 'object' && field in payload) {
    return (payload as Record<string, unknown>)[field]
  }

  return undefined
}
