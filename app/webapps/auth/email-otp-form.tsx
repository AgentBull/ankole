import { Button, Field, FieldLabel, Input } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useId, useState, useRef, useCallback } from 'react'
import { useTranslation } from 'react-i18next'
import { requestEmailOtp, verifyEmailOtp } from '../common/api/generated/sdk.gen'
import { ErrorBlock } from '../common/error-block'
import { classifyLoginError, LoginModel } from './state/login-model'
import { SlotBoundary, SlotGate } from '../common/slots'
import { useAuthSlots, type AuthAppSlots, type AuthChallengeState } from './slots'

export function EmailOtpForm({ flow }: { flow: string }) {
  const slot = useAuthSlots().emailOtpChallenge
  return (
    <SlotGate slot={slot}>
      {enabled => <EmailOtpFields key={flow} flow={flow} slot={enabled ? slot : undefined} />}
    </SlotGate>
  )
}

function EmailOtpFields({ flow, slot }: { flow: string; slot: AuthAppSlots['emailOtpChallenge'] }) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(LoginModel)
  const emailID = useId()
  const codeID = useId()
  const challengeEnabled = slot !== undefined
  const [attempt, setAttempt] = useState({ enabled: challengeEnabled, number: 0 })
  if (attempt.enabled !== challengeEnabled) {
    setAttempt({ enabled: challengeEnabled, number: attempt.number + 1 })
  }
  const resetAttempt = () => setAttempt(current => ({ ...current, number: current.number + 1 }))
  const attemptKey = `${flow}:${model.email.value}:${attempt.number}`
  const currentAttempt = useRef(attemptKey)
  currentAttempt.current = attemptKey
  const [challenge, setChallenge] = useState<AuthChallengeState & { attemptKey: string }>()
  const challengeReady = !challengeEnabled || (challenge?.attemptKey === attemptKey && challenge.ready)
  const onChallengeStateChange = useCallback(
    (state: AuthChallengeState) => {
      if (currentAttempt.current === attemptKey) setChallenge({ ...state, attemptKey })
    },
    [attemptKey]
  )
  const challengeHeaders = challengeEnabled && challengeReady ? challenge?.headers : undefined
  const request = useMutation({
    mutationFn: () =>
      requestEmailOtp({ headers: challengeHeaders, body: { data: { flow, email: model.email.value } } }),
    onSettled: resetAttempt,
    onSuccess: () => {
      model.resetCode()
      verify.reset()
    },
    onError: error => model.reportLoginError(error)
  })
  const verify = useMutation({
    mutationFn: () =>
      verifyEmailOtp({
        body: {
          data: {
            flow,
            challengeID: request.data!.challengeID,
            code: model.code.value
          }
        }
      }),
    onSuccess: result => window.location.assign(result.returnTo),
    onError: error => model.reportLoginError(error)
  })
  const waiting = model.formError.value?.kind === 'locked'
  const pending = request.isPending || verify.isPending
  const error = verify.error ?? request.error
  const classified = error ? classifyLoginError(error) : undefined
  const formError = model.formError.value
  const errorText =
    formError?.kind === 'locked'
      ? t('auth.code_retry', { seconds: formError.remainingSeconds })
      : formError
        ? t(`auth.${formError.kind}`)
        : undefined

  return (
    <form
      className="grid gap-5"
      onSubmit={event => {
        event.preventDefault()
        if (pending || waiting || (!request.data && !challengeReady)) return
        model.clearFormError()
        request.data ? verify.mutate() : request.mutate()
      }}>
      <ErrorBlock error={classified ? undefined : error} />
      <Field>
        <FieldLabel htmlFor={emailID}>{t('auth.email')}</FieldLabel>
        <Input
          id={emailID}
          type="email"
          name="email"
          autoComplete="email"
          required
          disabled={pending || Boolean(request.data)}
          value={model.email.value}
          onChange={event => {
            model.email.value = event.target.value
            model.changeAccount()
            resetAttempt()
          }}
        />
      </Field>
      {request.data && (
        <>
          <p role="status" className="text-sm text-muted-foreground">
            {t('auth.code_sent', { email: model.email.value })}
          </p>
          <Field>
            <FieldLabel htmlFor={codeID}>{t('auth.email_code')}</FieldLabel>
            <Input
              id={codeID}
              name="code"
              inputMode="numeric"
              pattern="[0-9]{6}"
              maxLength={6}
              autoComplete="one-time-code"
              required
              autoFocus
              disabled={pending || waiting}
              value={model.code.value}
              onChange={event => {
                model.code.value = event.target.value
                model.clearFormError()
              }}
            />
          </Field>
        </>
      )}
      {slot && (
        <SlotBoundary>
          <slot.Component key={attemptKey} attemptKey={attemptKey} onChallengeStateChange={onChallengeStateChange} />
        </SlotBoundary>
      )}
      {errorText && (
        <p role="alert" className="text-sm text-destructive-foreground">
          {errorText}
        </p>
      )}
      <Button
        type="submit"
        className="w-full"
        disabled={pending || waiting || (!request.data && !challengeReady)}
        aria-busy={pending}>
        {pending ? t('common.loading') : request.data ? t('auth.verify_code') : t('auth.send_code')}
      </Button>
      {request.data && (
        <div className="flex gap-3">
          <Button
            type="button"
            variant="ghost"
            disabled={pending || waiting || !challengeReady}
            onClick={() => request.mutate()}>
            {t('auth.resend_code')}
          </Button>
          <Button
            type="button"
            variant="ghost"
            disabled={pending}
            onClick={() => {
              request.reset()
              verify.reset()
              model.resetCode()
              resetAttempt()
            }}>
            {t('auth.change_email')}
          </Button>
        </div>
      )}
    </form>
  )
}
