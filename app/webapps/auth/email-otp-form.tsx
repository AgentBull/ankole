import { recordValue, safeJsonParse, stringArg } from '@agentbull/active-support'
import { Button, Field, FieldLabel, Input, StepTransition } from '@ankole/uikit'
import { toast } from '@ankole/uikit/components/sonner'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useId, useState, useRef, useCallback, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { requestEmailOtp, verifyEmailOtp } from '../common/api/generated/sdk.gen'
import { CodeSentStatus } from '../common/code-sent-status'
import { EmailOtpInput } from '../common/email-otp-input'
import { ErrorBlock } from '../common/error-block'
import { classifyLoginError, LoginModel } from './state/login-model'
import { SlotBoundary, SlotGate } from '../common/slots'
import { loginContextKey, type LoginContext } from './login-params'
import { useAuthSlots, type AuthAppSlots, type AuthChallengeState } from './slots'

type EmailOtpFormProps = {
  context?: LoginContext
  sendLabel?: string
  compactVerification?: boolean
  resendCooldownSeconds?: number
  persistChallenge?: boolean
  onStepChange?: (step: 'email' | 'code') => void
}

export function EmailOtpForm(props: EmailOtpFormProps) {
  const slot = useAuthSlots().emailOtpChallenge
  const scope = loginContextKey(props.context)
  return (
    <SlotGate slot={slot}>
      {enabled => <EmailOtpFields key={scope} {...props} scope={scope} slot={enabled ? slot : undefined} />}
    </SlotGate>
  )
}

type SavedChallenge = { email: string; challengeID: string; expiresAt: string; resendUntil: number }

function challengeStorageKey(scope: string) {
  return `ankole-email-otp:${scope}`
}

function readChallenge(scope: string): SavedChallenge | undefined {
  let raw: string | null = null
  try {
    raw = sessionStorage.getItem(challengeStorageKey(scope))
  } catch {
    // The form remains usable without browser storage.
    return undefined
  }
  const saved = raw ? recordValue(safeJsonParse(raw).unwrapOr(undefined)) : undefined
  const email = stringArg(saved, 'email')
  const challengeID = stringArg(saved, 'challengeID')
  const expiresAt = stringArg(saved, 'expiresAt')
  const resendUntil = saved?.resendUntil
  if (
    email !== undefined &&
    challengeID !== undefined &&
    expiresAt !== undefined &&
    typeof resendUntil === 'number' &&
    Date.parse(expiresAt) > Date.now()
  ) {
    return { email, challengeID, expiresAt, resendUntil }
  }
  return undefined
}

function saveChallenge(scope: string, saved?: SavedChallenge) {
  try {
    if (saved) sessionStorage.setItem(challengeStorageKey(scope), JSON.stringify(saved))
    else sessionStorage.removeItem(challengeStorageKey(scope))
  } catch {
    // The form remains usable without browser storage.
  }
}

function EmailOtpFields({
  context,
  scope,
  sendLabel,
  compactVerification = false,
  resendCooldownSeconds = 0,
  persistChallenge = false,
  onStepChange,
  slot
}: EmailOtpFormProps & { scope: string; slot: AuthAppSlots['emailOtpChallenge'] }) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(LoginModel)
  const lockout = model.formError.value
  useEffect(() => {
    if (lockout?.kind !== 'locked') return
    const timer = setTimeout(() => model.advanceLockout(), 1000)
    return () => clearTimeout(timer)
  }, [model, lockout])
  const [restored] = useState(() => {
    const saved = persistChallenge ? readChallenge(scope) : undefined
    if (saved) {
      model.email.value = saved.email
      model.restoreResendCooldown(saved.resendUntil)
    }
    return saved
  })
  useEffect(() => {
    if (restored) onStepChange?.('code')
  }, [onStepChange, restored])
  const resendUntil = model.resendUntil.value
  useEffect(() => {
    if (!resendUntil) return
    model.updateResendCooldown()
    const timer = setInterval(() => model.updateResendCooldown(), 1000)
    return () => clearInterval(timer)
  }, [model, resendUntil])
  const emailID = useId()
  const codeID = useId()
  // An accepted code starts a navigation. The form holds its accepted state until the browser leaves, and returns
  // to rest when the browser restores this page from its back-forward cache.
  const [redirecting, setRedirecting] = useState(false)
  useEffect(() => {
    const restore = (event: PageTransitionEvent) => {
      if (event.persisted) setRedirecting(false)
    }
    window.addEventListener('pageshow', restore)
    return () => window.removeEventListener('pageshow', restore)
  }, [])
  const challengeEnabled = slot !== undefined
  const [attempt, setAttempt] = useState({ enabled: challengeEnabled, number: 0 })
  if (attempt.enabled !== challengeEnabled) {
    setAttempt({ enabled: challengeEnabled, number: attempt.number + 1 })
  }
  const resetAttempt = () => setAttempt(current => ({ ...current, number: current.number + 1 }))
  const attemptKey = `${scope}:${model.email.value}:${attempt.number}`
  const currentAttempt = useRef(attemptKey)
  currentAttempt.current = attemptKey
  const [challenge, setChallenge] = useState<AuthChallengeState & { attemptKey: string }>()
  const [challengeID, setChallengeID] = useState<string | undefined>(restored?.challengeID)
  const challengeReady = !challengeEnabled || (challenge?.attemptKey === attemptKey && challenge.ready)
  const onChallengeStateChange = useCallback(
    (state: AuthChallengeState) => {
      if (currentAttempt.current === attemptKey) setChallenge({ ...state, attemptKey })
    },
    [attemptKey]
  )
  const challengeHeaders = challengeEnabled && challengeReady ? challenge?.headers : undefined
  const request = useMutation({
    mutationFn: (_resend?: boolean) =>
      requestEmailOtp({
        headers: challengeHeaders,
        body: { data: { ...context, email: model.email.value } }
      }),
    onSettled: resetAttempt,
    onSuccess: (result, resend) => {
      setChallengeID(result.challengeID)
      model.resetCode()
      if (resendCooldownSeconds) model.startResendCooldown(resendCooldownSeconds)
      if (persistChallenge) {
        saveChallenge(scope, {
          email: model.email.value,
          challengeID: result.challengeID,
          expiresAt: result.expiresAt,
          resendUntil: model.resendUntil.value
        })
      }
      verify.reset()
      onStepChange?.('code')
      if (resend) toast.success(t('common.authn.code_sent', { defaultValue: 'Verification code sent.' }))
    },
    onError: error => {
      const classified = classifyLoginError(error)
      if (challengeID && resendCooldownSeconds && classified?.kind === 'locked') {
        model.startResendCooldown(classified.remainingSeconds)
      } else {
        model.reportLoginError(error)
      }
    }
  })
  const verify = useMutation({
    mutationFn: () =>
      verifyEmailOtp({
        body: {
          data: {
            challengeID: challengeID!,
            code: model.code.value
          }
        }
      }),
    onSuccess: result => {
      if (persistChallenge) saveChallenge(scope)
      setRedirecting(true)
      window.location.assign(result.returnTo)
    },
    onError: error => {
      model.reportLoginError(error)
      // A rejected code cannot be edited into the right one, so the field empties for the next attempt. The
      // error stays until the person types.
      if (classifyLoginError(error)?.kind === 'invalid_code') model.code.value = ''
    }
  })
  const rejected = model.formError.value?.kind === 'invalid_code'
  const waiting = model.formError.value?.kind === 'locked'
  const pending = request.isPending || verify.isPending || redirecting
  // The code field is disabled while a request runs, so it cannot take focus when it mounts or when a code is
  // rejected. It takes focus as soon as the form can be typed in again: after a code is sent or sent again, and
  // after a wrong code.
  const codeReady = Boolean(challengeID) && !pending && !waiting
  useEffect(() => {
    if (codeReady) document.getElementById(codeID)?.focus()
  }, [codeID, codeReady, rejected])
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
      className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-5"
      onSubmit={event => {
        event.preventDefault()
        if (pending || waiting || (!challengeID && !challengeReady) || (challengeID && model.code.value.length !== 6)) {
          return
        }
        model.clearFormError()
        challengeID ? verify.mutate() : request.mutate()
      }}>
      <ErrorBlock error={classified ? undefined : error} />
      <StepTransition step={challengeID ? 'code' : 'email'} direction={challengeID ? 'forward' : 'back'}>
        <div className="grid min-w-0 gap-5">
          {(!challengeID || !compactVerification) && (
            <Field>
              <FieldLabel htmlFor={emailID}>{t('auth.email')}</FieldLabel>
              <Input
                id={emailID}
                type="email"
                name="email"
                autoComplete="email"
                required
                disabled={pending || Boolean(challengeID)}
                value={model.email.value}
                onChange={event => {
                  model.email.value = event.target.value
                  model.changeAccount()
                  resetAttempt()
                }}
              />
            </Field>
          )}
          {challengeID && (
            <>
              <CodeSentStatus email={model.email.value} />
              <Field>
                <FieldLabel htmlFor={codeID}>{t('auth.email_code')}</FieldLabel>
                <EmailOtpInput
                  id={codeID}
                  name="code"
                  disabled={pending || waiting}
                  invalid={rejected}
                  status={redirecting ? 'success' : verify.isPending ? 'verifying' : undefined}
                  value={model.code.value}
                  onChange={value => {
                    model.code.value = value
                    model.clearFormError()
                  }}
                />
              </Field>
            </>
          )}
        </div>
      </StepTransition>
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
        disabled={
          pending ||
          waiting ||
          (!challengeID && !challengeReady) ||
          Boolean(challengeID && model.code.value.length !== 6)
        }
        aria-busy={pending}>
        {pending ? t('common.loading') : challengeID ? t('auth.verify_code') : (sendLabel ?? t('auth.send_code'))}
      </Button>
      {challengeID && (
        <div className="flex flex-wrap gap-2">
          <Button
            type="button"
            variant="ghost"
            disabled={pending || waiting || !challengeReady || model.resendSeconds.value > 0}
            onClick={() => {
              model.clearFormError()
              request.mutate(true)
            }}>
            {model.resendSeconds.value > 0
              ? t('auth.resend_countdown', { seconds: model.resendSeconds.value })
              : t('auth.resend_code')}
          </Button>
          <Button
            type="button"
            variant="ghost"
            disabled={pending}
            onClick={() => {
              request.reset()
              verify.reset()
              setChallengeID(undefined)
              if (persistChallenge) saveChallenge(scope)
              model.resetCode()
              model.clearResendCooldown()
              resetAttempt()
              onStepChange?.('email')
            }}>
            {t('auth.change_email')}
          </Button>
        </div>
      )}
    </form>
  )
}
