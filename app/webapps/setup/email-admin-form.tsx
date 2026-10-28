import { Button, Checkbox, Field, FieldLabel, Input } from '@ankole/uikit'
import { toast } from '@ankole/uikit/components/sonner'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { requestSetupEmailOtp, verifySetupEmailOtp } from '../common/api/generated/sdk.gen'
import { CodeSentStatus } from '../common/code-sent-status'
import { EmailOtpInput } from '../common/email-otp-input'
import { ErrorBlock } from '../common/error-block'
import { EmailAdminModel } from './state/email-admin-model'

const smtpFields = [
  ['server', 'text', true],
  ['port', 'number', true],
  ['from', 'email', true],
  ['username', 'text', false],
  ['password', 'password', false]
] as const

const adminFields = [
  ['email', 'email', true],
  ['displayName', 'text', false]
] as const

export function EmailAdminForm() {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(EmailAdminModel)
  const id = useId()
  const send = useMutation({
    mutationFn: (_resend?: boolean) =>
      requestSetupEmailOtp({
        body: {
          data: {
            email: model.email.value,
            display_name: model.displayName.value,
            mail: {
              server: model.server.value,
              port: Number(model.port.value),
              from: model.from.value,
              username: model.username.value,
              password: model.password.value,
              ssl: model.ssl.value
            }
          }
        }
      }),
    onSuccess: (challenge, resend) => {
      model.receiveChallenge(challenge)
      verify.reset()
      if (resend) toast.success(t('common.authn.code_sent', { defaultValue: 'Verification code sent.' }))
    }
  })
  const verify = useMutation({
    mutationFn: () => verifySetupEmailOtp({ body: { data: { ...model.challenge.value!, code: model.code.value } } }),
    onSuccess: result => window.location.assign(result.returnTo)
  })
  const pending = send.isPending || verify.isPending

  function renderField([key, type, required]: (typeof smtpFields)[number] | (typeof adminFields)[number]) {
    return (
      <Field key={key}>
        <FieldLabel htmlFor={`${id}-${key}`}>{t(`setup.smtp_${key}`)}</FieldLabel>
        <Input
          id={`${id}-${key}`}
          type={type}
          required={required}
          autoComplete={key === 'password' ? 'new-password' : 'off'}
          min={key === 'port' ? 1 : undefined}
          max={key === 'port' ? 65535 : undefined}
          value={model[key].value}
          onChange={event => {
            model[key].value = event.target.value
          }}
        />
      </Field>
    )
  }

  return (
    <section className="grid gap-5">
      <ErrorBlock error={send.error ?? verify.error} />
      <form
        className="grid gap-6"
        onSubmit={event => {
          event.preventDefault()
          send.mutate(false)
        }}>
        <fieldset className="grid gap-6" disabled={pending || Boolean(model.challenge.value)}>
          <div className="grid gap-4">
            <div className="grid gap-1">
              <h3 className="text-sm font-semibold uppercase tracking-normal text-muted-foreground">
                {t('setup.smtp_section_title', { defaultValue: 'Outgoing mail (SMTP)' })}
              </h3>
              <p className="text-sm leading-6 text-muted-foreground">{t('setup.email_verification_required')}</p>
            </div>
            <div className="grid gap-4 md:grid-cols-2">
              {smtpFields.map(renderField)}
              <label className="flex items-center gap-2 text-sm md:col-span-2">
                <Checkbox
                  checked={model.ssl.value}
                  onCheckedChange={value => {
                    model.ssl.value = value === true
                  }}
                />
                {t('setup.smtp_ssl')}
              </label>
            </div>
          </div>

          <div className="grid gap-4 border-t border-border/70 pt-5">
            <div className="grid gap-1">
              <h3 className="text-sm font-semibold uppercase tracking-normal text-muted-foreground">
                {t('setup.admin_section_title')}
              </h3>
              <p className="text-sm leading-6 text-muted-foreground">{t('setup.admin_section_hint')}</p>
            </div>
            <div className="grid gap-4 md:grid-cols-2">{adminFields.map(renderField)}</div>
          </div>
        </fieldset>
        {!model.challenge.value && (
          <div className="flex flex-wrap items-center gap-3 border-t border-border/70 pt-5">
            <Button type="submit" disabled={pending}>
              {t('auth.send_code')}
            </Button>
          </div>
        )}
      </form>
      {model.challenge.value && (
        <form
          className="grid gap-4 border-t border-border/70 pt-5"
          onSubmit={event => {
            event.preventDefault()
            if (pending || model.code.value.length !== 6) return
            verify.mutate()
          }}>
          <CodeSentStatus email={model.email.value} />
          <Field>
            <FieldLabel htmlFor={`${id}-code`}>{t('auth.email_code')}</FieldLabel>
            <EmailOtpInput
              id={`${id}-code`}
              disabled={pending}
              value={model.code.value}
              onChange={value => {
                model.code.value = value
              }}
            />
          </Field>
          <div className="flex flex-wrap items-center gap-3 pt-1">
            <Button type="submit" disabled={pending || model.code.value.length !== 6}>
              {t('setup.verify_complete')}
            </Button>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button type="button" variant="outline" size="sm" disabled={pending} onClick={() => send.mutate(true)}>
              {t('auth.resend_code')}
            </Button>
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={pending}
              onClick={() => {
                send.reset()
                verify.reset()
                model.editMail()
              }}>
              {t('setup.edit_mail')}
            </Button>
          </div>
        </form>
      )}
    </section>
  )
}
