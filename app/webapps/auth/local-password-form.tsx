import { Button, Field, FieldLabel, Input } from '@ankole/uikit'
import { RiLoaderLine } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useId, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { ErrorBlock } from '../common/error-block'
import { internalAPIPost } from '../common/internal-api-client'
import { PasswordInput } from '../common/password-input'
import { classifyLoginError, formatRetryDelay, LoginModel, type LoginFormError } from './state/login-model'

type LoginResult = { status: 'ok'; returnTo: string } | { status: 'password_change_required' }

/** Email-and-password sign-in for the built-in local identity provider. */
export function LocalPasswordForm({ model }: { model: InstanceType<typeof LoginModel> }) {
  useSignals()
  const { t } = useTranslation()
  const emailID = useId()
  const passwordID = useId()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const login = useMutation({
    mutationFn: (input: { email: string; password: string }) => {
      // Mirrors the OIDC path: the page URL carries the destination and the
      // server clamps it to a safe same-origin path.
      const returnTo = new URLSearchParams(window.location.search).get('return_to')
      return internalAPIPost<LoginResult>(
        '/.internal-apis/sessions/local-password',
        returnTo ? { ...input, returnTo } : input
      )
    },
    onSuccess: result => {
      if (result.status === 'ok') window.location.assign(result.returnTo)
      else model.enterChangePassword()
    },
    onError: error => model.reportLoginError(error)
  })
  const formError = model.formError.value
  const locked = formError?.kind === 'locked'
  // Classified failures render inline below; everything else keeps the
  // generic surface. Deriving from the mutation error (not the model) keeps a
  // cleared inline error from resurfacing as raw text.
  const genericError = login.error && !classifyLoginError(login.error) ? login.error : undefined

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (locked || login.isPending) return
    model.clearFormError()
    login.mutate({ email, password })
  }

  const editPassword = (value: string) => {
    setPassword(value)
    model.clearFormError()
  }

  // A lockout is per account on the server, so an email edit unfreezes the
  // form for the other account; the server still enforces the real limit.
  const editEmail = (value: string) => {
    setEmail(value)
    model.changeAccount()
  }

  return (
    <form className="grid gap-5" onSubmit={submit}>
      <ErrorBlock error={genericError} />
      <Field>
        <FieldLabel htmlFor={emailID}>{t('auth.email')}</FieldLabel>
        <Input
          autoComplete="username"
          id={emailID}
          name="email"
          required
          type="email"
          value={email}
          onChange={event => editEmail(event.target.value)}
        />
      </Field>
      <Field>
        <FieldLabel htmlFor={passwordID}>{t('auth.password')}</FieldLabel>
        <PasswordInput
          autoComplete="current-password"
          id={passwordID}
          name="password"
          required
          value={password}
          onChange={event => editPassword(event.target.value)}
        />
      </Field>
      {formError ? (
        <p role="alert" className="text-sm leading-5 text-destructive">
          {formErrorText(formError, t)}
        </p>
      ) : null}
      <Button aria-busy={login.isPending} className="w-full" disabled={login.isPending || locked} type="submit">
        {login.isPending ? t('auth.signing_in') : t('auth.sign_in')}
        {login.isPending ? <RiLoaderLine aria-hidden className="animate-spin" data-icon="inline-end" /> : null}
      </Button>
      <p className="ak-muted text-sm">{t('auth.forgot_password_hint')}</p>
    </form>
  )
}

function formErrorText(error: LoginFormError, t: (key: string, values?: Record<string, unknown>) => string): string {
  switch (error.kind) {
    case 'invalid_credentials':
      return t('auth.invalid_credentials')
    case 'not_admin':
      return t('auth.not_admin')
    case 'account_disabled':
      return t('auth.account_disabled')
    case 'locked': {
      const delay = formatRetryDelay(error.remainingSeconds)
      return delay.unit === 'seconds'
        ? t('auth.locked_seconds', { seconds: delay.seconds })
        : t('auth.locked_minutes', { minutes: delay.minutes })
    }
  }
}
