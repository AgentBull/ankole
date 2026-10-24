import { Button, Checkbox, Field, FieldLabel, Input } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { requestSetupEmailOtp, verifySetupEmailOtp } from '../common/api/generated/sdk.gen'
import { ErrorBlock } from '../common/error-block'
import { EmailAdminModel } from './state/email-admin-model'

export function EmailAdminForm() {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(EmailAdminModel)
  const id = useId()
  const send = useMutation({
    mutationFn: () =>
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
      })
  })
  const verify = useMutation({
    mutationFn: () => verifySetupEmailOtp({ body: { data: { ...send.data!, code: model.code.value } } }),
    onSuccess: result => window.location.assign(result.returnTo)
  })
  const pending = send.isPending || verify.isPending
  const fields = [
    ['server', 'text', true],
    ['port', 'number', true],
    ['from', 'email', true],
    ['username', 'text', false],
    ['password', 'password', false],
    ['displayName', 'text', false],
    ['email', 'email', true]
  ] as const
  return (
    <section className="grid gap-5">
      <p>{t('setup.email_verification_required')}</p>
      <ErrorBlock error={send.error ?? verify.error} />
      <form
        className="grid gap-5"
        onSubmit={event => {
          event.preventDefault()
          send.mutate()
        }}>
        <fieldset className="grid gap-4 md:grid-cols-2" disabled={pending || Boolean(send.data)}>
          {fields.map(([key, type, required]) => (
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
          ))}
          <label className="flex gap-2 items-center">
            <Checkbox
              checked={model.ssl.value}
              onCheckedChange={value => {
                model.ssl.value = value === true
              }}
            />
            {t('setup.smtp_ssl')}
          </label>
        </fieldset>
        {!send.data && (
          <Button type="submit" disabled={pending}>
            {t('auth.send_code')}
          </Button>
        )}
      </form>
      {send.data && (
        <form
          className="grid gap-4"
          onSubmit={event => {
            event.preventDefault()
            verify.mutate()
          }}>
          <p role="status">{t('auth.code_sent', { email: model.email.value })}</p>
          <Field>
            <FieldLabel htmlFor={`${id}-code`}>{t('auth.email_code')}</FieldLabel>
            <Input
              id={`${id}-code`}
              pattern="[0-9]{6}"
              maxLength={6}
              inputMode="numeric"
              autoComplete="one-time-code"
              required
              value={model.code.value}
              onChange={event => {
                model.code.value = event.target.value
              }}
            />
          </Field>
          <Button type="submit" disabled={pending}>
            {t('setup.verify_complete')}
          </Button>
          <Button
            type="button"
            variant="outline"
            disabled={pending}
            onClick={() => {
              send.reset()
              verify.reset()
              model.code.value = ''
            }}>
            {t('setup.edit_mail')}
          </Button>
        </form>
      )}
    </section>
  )
}
