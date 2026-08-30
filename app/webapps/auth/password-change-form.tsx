import { Button, Field, FieldError as UiFieldError, FieldLabel, toast } from '@ankole/uikit'
import { Field as FormField, Form, useForm } from '@formisch/react'
import { RiLoaderLine } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import * as v from 'valibot'
import { ErrorBlock } from '../common/error-block'
import i18n from '../common/i18n'
import { InternalAPIError, internalAPIPost } from '../common/internal-api-client'
import { PasswordInput } from '../common/password-input'
import { PasswordStrengthMeter } from '../common/password-strength-meter'
import { LoginModel } from './state/login-model'

const changeSchema = v.pipe(
  v.object({
    newPassword: v.pipe(
      v.string(),
      v.minLength(6, () => i18n.t('common.password_too_short'))
    ),
    confirmPassword: v.string()
  }),
  v.forward(
    v.partialCheck(
      [['newPassword'], ['confirmPassword']],
      input => input.newPassword === input.confirmPassword,
      () => i18n.t('common.password_mismatch')
    ),
    ['confirmPassword']
  )
)

/**
 * First-sign-in password change. The server holds a short-lived change ticket
 * in the session; an expired ticket sends the operator back to the login view.
 */
export function PasswordChangeForm({ model }: { model: InstanceType<typeof LoginModel> }) {
  useSignals()
  const { t } = useTranslation()
  const newPasswordID = useId()
  const confirmPasswordID = useId()
  const form = useForm({
    schema: changeSchema,
    initialInput: { newPassword: '', confirmPassword: '' },
    validate: 'submit',
    revalidate: 'input'
  })
  const change = useMutation({
    mutationFn: (input: { newPassword: string }) =>
      internalAPIPost<{ returnTo: string }>('/.internal-apis/sessions/local-password/change', input),
    onSuccess: result => window.location.assign(result.returnTo),
    onError: error => {
      if (ticketExpired(error)) {
        toast.error(t('auth.change_expired'))
        model.backToLogin()
      }
    }
  })

  return (
    <Form className="grid gap-5" of={form} onSubmit={output => change.mutate({ newPassword: output.newPassword })}>
      <ErrorBlock error={change.error && !ticketExpired(change.error) ? change.error : undefined} />
      <FormField of={form} path={['newPassword']}>
        {field => (
          <Field>
            <FieldLabel htmlFor={newPasswordID}>{t('auth.new_password')}</FieldLabel>
            <PasswordInput
              {...field.props}
              aria-invalid={field.errors ? true : undefined}
              autoComplete="new-password"
              id={newPasswordID}
              value={String(field.input ?? '')}
              onChange={event => field.onChange(event.target.value)}
            />
            <PasswordStrengthMeter password={String(field.input ?? '')} />
            {field.errors ? <UiFieldError>{field.errors[0]}</UiFieldError> : null}
          </Field>
        )}
      </FormField>
      <FormField of={form} path={['confirmPassword']}>
        {field => (
          <Field>
            <FieldLabel htmlFor={confirmPasswordID}>{t('auth.confirm_new_password')}</FieldLabel>
            <PasswordInput
              {...field.props}
              aria-invalid={field.errors ? true : undefined}
              autoComplete="new-password"
              id={confirmPasswordID}
              value={String(field.input ?? '')}
              onChange={event => field.onChange(event.target.value)}
            />
            {field.errors ? <UiFieldError>{field.errors[0]}</UiFieldError> : null}
          </Field>
        )}
      </FormField>
      <Button aria-busy={change.isPending} className="w-full" disabled={change.isPending} type="submit">
        {change.isPending ? t('auth.change_saving') : t('auth.change_submit')}
        {change.isPending ? <RiLoaderLine aria-hidden className="animate-spin" data-icon="inline-end" /> : null}
      </Button>
      <button
        className="justify-self-start text-sm leading-5 text-link underline underline-offset-4 hover:text-link/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/30"
        type="button"
        onClick={() => model.backToLogin()}>
        {t('auth.back_to_sign_in')}
      </button>
    </Form>
  )
}

function ticketExpired(error: unknown): boolean {
  return error instanceof InternalAPIError && error.status === 401
}
