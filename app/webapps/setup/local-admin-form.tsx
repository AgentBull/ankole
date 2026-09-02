import { Button, Field, FieldError as UiFieldError, FieldGroup, FieldLabel, Input } from '@ankole/uikit'
import { Field as FormField, Form, useForm } from '@formisch/react'
import { RiLoaderLine, RiLoginCircleLine } from '@remixicon/react'
import { useMutation } from '@tanstack/react-query'
import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import * as v from 'valibot'
import { defaultConfig } from '../common/config-fields'
import { ErrorBlock } from '../common/error-block'
import i18n from '../common/i18n'
import { internalAPIPost, internalAPIPut } from '../common/internal-api-client'
import { PasswordInput } from '../common/password-input'
import { PasswordStrengthMeter } from '../common/password-strength-meter'
import type { IdentityAdapter } from './app'

const adminSchema = v.pipe(
  v.object({
    displayName: v.string(),
    email: v.pipe(
      v.string(),
      v.email(() => i18n.t('common.email_invalid'))
    ),
    password: v.pipe(
      v.string(),
      v.minLength(6, () => i18n.t('common.password_too_short'))
    ),
    confirmPassword: v.string()
  }),
  v.forward(
    v.partialCheck(
      [['password'], ['confirmPassword']],
      input => input.password === input.confirmPassword,
      () => i18n.t('common.password_mismatch')
    ),
    ['confirmPassword']
  )
)

type AdminInput = v.InferOutput<typeof adminSchema>

/**
 * Creates the first administrator for the built-in local provider and
 * completes setup. The credentials are component-transient: they never enter
 * a shared model. The provider PUT is idempotent, so one resubmit reruns the
 * whole chain after any failure.
 */
export function LocalAdminForm({ adapter }: { adapter: IdentityAdapter }) {
  const { t } = useTranslation()
  const displayNameID = useId()
  const emailID = useId()
  const passwordID = useId()
  const confirmPasswordID = useId()
  const form = useForm({
    schema: adminSchema,
    initialInput: { displayName: '', email: '', password: '', confirmPassword: '' },
    validate: 'submit',
    revalidate: 'input'
  })
  const mutation = useMutation({
    mutationFn: async (input: AdminInput) => {
      await internalAPIPut(
        `/.internal-apis/setup/identity-providers/${encodeURIComponent(adapter.defaultProviderID)}`,
        {
          adapterID: adapter.adapterID,
          config: defaultConfig(adapter.fields),
          enabled: true
        }
      )
      return internalAPIPost<{ returnTo?: string }>('/.internal-apis/setup/local-admin', {
        display_name: input.displayName.trim() || undefined,
        email: input.email,
        password: input.password
      })
    },
    onSuccess: result => window.location.assign(result.returnTo ?? '/console')
  })

  return (
    <section className="grid gap-5">
      <div className="grid gap-1">
        <h2 className="text-sm font-semibold uppercase tracking-normal text-muted-foreground">
          {t('setup.admin_section_title')}
        </h2>
        <p className="text-sm leading-6 text-muted-foreground">{t('setup.admin_section_hint')}</p>
      </div>
      <ErrorBlock error={mutation.error} />
      <Form className="grid gap-6" of={form} onSubmit={output => mutation.mutate(output)}>
        <FieldGroup className="grid grid-cols-1 gap-5 md:grid-cols-2">
          <FormField of={form} path={['displayName']}>
            {field => (
              <Field className="md:col-span-2">
                <FieldLabel htmlFor={displayNameID}>{t('setup.admin_display_name')}</FieldLabel>
                <Input
                  {...field.props}
                  autoComplete="name"
                  id={displayNameID}
                  value={String(field.input ?? '')}
                  onChange={event => field.onChange(event.target.value)}
                />
              </Field>
            )}
          </FormField>
          <FormField of={form} path={['email']}>
            {field => (
              <Field className="md:col-span-2">
                <FieldLabel htmlFor={emailID}>{t('setup.admin_email')}</FieldLabel>
                <Input
                  {...field.props}
                  aria-invalid={field.errors ? true : undefined}
                  autoComplete="username"
                  id={emailID}
                  type="email"
                  value={String(field.input ?? '')}
                  onChange={event => field.onChange(event.target.value)}
                />
                {field.errors ? <UiFieldError>{field.errors[0]}</UiFieldError> : null}
              </Field>
            )}
          </FormField>

          <FormField of={form} path={['password']}>
            {field => (
              <Field>
                <FieldLabel htmlFor={passwordID}>{t('setup.admin_password')}</FieldLabel>
                <PasswordInput
                  {...field.props}
                  aria-invalid={field.errors ? true : undefined}
                  autoComplete="new-password"
                  id={passwordID}
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
                <FieldLabel htmlFor={confirmPasswordID}>{t('setup.admin_password_confirm')}</FieldLabel>
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
        </FieldGroup>

        <div className="flex flex-wrap items-center gap-3 border-t border-border/70 pt-5">
          <Button aria-busy={mutation.isPending} disabled={mutation.isPending} type="submit">
            {mutation.isPending ? t('setup.creating_admin') : t('setup.create_admin')}
            {mutation.isPending ? (
              <RiLoaderLine aria-hidden className="animate-spin" data-icon="inline-end" />
            ) : (
              <RiLoginCircleLine aria-hidden data-icon="inline-end" />
            )}
          </Button>
        </div>
      </Form>
    </section>
  )
}
