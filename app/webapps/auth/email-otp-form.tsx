import { Button, Field, FieldLabel, Input, InputOTP, InputOTPGroup, InputOTPSlot } from '@ankole/uikit'
import { toast } from '@ankole/uikit/components/sonner'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useId, useState, useRef, useCallback, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { requestEmailOtp, verifyEmailOtp } from '../common/api/generated/sdk.gen'
import { ErrorBlock } from '../common/error-block'
import { classifyLoginError, LoginModel } from './state/login-model'
import { SlotBoundary, SlotGate } from '../common/slots'
import { loginContextKey, type LoginContext } from './login-params'
import { useAuthSlots, type AuthAppSlots, type AuthChallengeState } from './slots'

type EmailOtpFormProps = {
  context?: LoginContext
  sendLabel?: string
  compactVerification?: boolean
  otpSlots?: boolean
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
  try {
    const saved = JSON.parse(sessionStorage.getItem(challengeStorageKey(scope)) ?? 'null') as SavedChallenge | null
    if (
      saved &&
      typeof saved.email === 'string' &&
      typeof saved.challengeID === 'string' &&
      typeof saved.resendUntil === 'number' &&
      Date.parse(saved.expiresAt) > Date.now()
    ) {
      return saved
    }
  } catch {
    // The form remains usable without browser storage.
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
  otpSlots = false,
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
      window.location.assign(result.returnTo)
    },
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
      className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-5"
      onSubmit={event => {
        event.preventDefault()
        if (pending || waiting || (!challengeID && !challengeReady)) return
        model.clearFormError()
        challengeID ? verify.mutate() : request.mutate()
      }}>
      <ErrorBlock error={classified ? undefined : error} />
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
          <p role="status" className="break-words text-sm text-muted-foreground">
            {t('auth.code_sent', { email: model.email.value })}
          </p>
          <Field>
            <FieldLabel htmlFor={codeID}>{t('auth.email_code')}</FieldLabel>
            {otpSlots ? (
              <InputOTP
                id={codeID}
                name="code"
                inputMode="numeric"
                pattern="[0-9]*"
                maxLength={6}
                autoComplete="one-time-code"
                required
                autoFocus
                disabled={pending || waiting}
                value={model.code.value}
                containerClassName="min-w-0 w-full"
                pasteTransformer={value => value.replace(/\D/g, '')}
                onChange={value => {
                  model.code.value = value
                  model.clearFormError()
                }}>
                <InputOTPGroup className="grid w-full max-w-80 grid-cols-6 gap-2">
                  {Array.from({ length: 6 }, (_, index) => (
                    <InputOTPSlot key={index} index={index} className="h-11 w-full text-base" />
                  ))}
                </InputOTPGroup>
              </InputOTP>
            ) : (
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
            )}
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
              ? t('saas.auth.resend_countdown', { seconds: model.resendSeconds.value })
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
