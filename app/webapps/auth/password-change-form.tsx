import { Button, Field, FieldError as UiFieldError, FieldLabel, toast } from '@ankole/uikit'
import { revalidateLogic, useForm } from '@tanstack/react-form'
import { RiLoaderLine } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { z } from 'zod'
import { ErrorBlock } from '../common/error-block'
import i18n from '../common/i18n'
import { InternalAPIError } from '../common/internal-api-client'
import { localPasswordChange } from '../common/api/generated/sdk.gen'
import { PasswordInput } from '../common/password-input'
import { PasswordStrengthMeter } from '../common/password-strength-meter'
import { LoginModel } from './state/login-model'

const changeSchema = z
  .object({
    newPassword: z.string().min(6, { error: () => i18n.t('common.password_too_short') }),
    confirmPassword: z.string()
  })
  .refine(input => input.newPassword === input.confirmPassword, {
    error: () => i18n.t('common.password_mismatch'),
    path: ['confirmPassword']
  })

/**
 * First-sign-in password change. The server holds a short-lived change ticket
 * in the session; an expired ticket sends the operator back to the login view.
 */
export function PasswordChangeForm({ model }: { model: InstanceType<typeof LoginModel> }) {
  useSignals()
  const { t } = useTranslation()
  const newPasswordID = useId()
  const confirmPasswordID = useId()
  const change = useMutation({
    mutationFn: (input: { newPassword: string }) =>
      localPasswordChange({
        body: {
          ...input,
          flow: new URLSearchParams(window.location.search).get('flow')
        }
      }),
    onSuccess: result => window.location.assign(result.returnTo),
    onError: error => {
      if (ticketExpired(error)) {
        toast.error(t('auth.change_expired'))
        model.backToLogin()
      }
    }
  })
  const form = useForm({
    defaultValues: { newPassword: '', confirmPassword: '' },
    validationLogic: revalidateLogic(),
    validators: { onDynamic: changeSchema },
    onSubmit: ({ value }) => {
      change.mutate({ newPassword: value.newPassword })
    }
  })

  return (
    <form
      className="grid gap-5"
      noValidate
      onSubmit={event => {
        event.preventDefault()
        event.stopPropagation()
        void form.handleSubmit()
      }}>
      <ErrorBlock error={change.error && !ticketExpired(change.error) ? change.error : undefined} />
      <form.Field name="newPassword">
        {field => {
          const error = field.state.meta.errors[0]?.message
          return (
            <Field>
              <FieldLabel htmlFor={newPasswordID}>{t('auth.new_password')}</FieldLabel>
              <PasswordInput
                aria-invalid={error ? true : undefined}
                autoComplete="new-password"
                id={newPasswordID}
                name={field.name}
                value={field.state.value}
                onBlur={field.handleBlur}
                onChange={event => field.handleChange(event.target.value)}
              />
              <PasswordStrengthMeter password={field.state.value} />
              {error ? <UiFieldError>{error}</UiFieldError> : null}
            </Field>
          )
        }}
      </form.Field>
      <form.Field name="confirmPassword">
        {field => {
          const error = field.state.meta.errors[0]?.message
          return (
            <Field>
              <FieldLabel htmlFor={confirmPasswordID}>{t('auth.confirm_new_password')}</FieldLabel>
              <PasswordInput
                aria-invalid={error ? true : undefined}
                autoComplete="new-password"
                id={confirmPasswordID}
                name={field.name}
                value={field.state.value}
                onBlur={field.handleBlur}
                onChange={event => field.handleChange(event.target.value)}
              />
              {error ? <UiFieldError>{error}</UiFieldError> : null}
            </Field>
          )
        }}
      </form.Field>
      <Button aria-busy={change.isPending} className="w-full" disabled={change.isPending} type="submit">
        {change.isPending ? t('auth.change_saving') : t('auth.change_submit')}
        {change.isPending ? <RiLoaderLine aria-hidden className="animate-spin" data-icon="inline-end" /> : null}
      </Button>
      <button className="link justify-self-start text-sm leading-5" type="button" onClick={() => model.backToLogin()}>
        {t('auth.back_to_sign_in')}
      </button>
    </form>
  )
}

function ticketExpired(error: unknown): boolean {
  return error instanceof InternalAPIError && error.status === 401
}
