import { Button, Field, FieldError as UiFieldError, FieldGroup, FieldLabel, Input } from '@ankole/uikit'
import { revalidateLogic, useForm } from '@tanstack/react-form'
import { RiLoaderLine, RiLoginCircleLine } from '@remixicon/react'
import { useMutation } from '@tanstack/react-query'
import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { z } from 'zod'
import { defaultConfig } from '../common/config-fields'
import { ErrorBlock } from '../common/error-block'
import i18n from '../common/i18n'
import { putSetupIdentityProvider, createSetupLocalAdmin } from '../common/api/generated/sdk.gen'
import { PasswordInput } from '../common/password-input'
import { PasswordStrengthMeter } from '../common/password-strength-meter'
import type { IdentityAdapter } from './app'

const adminSchema = z
  .object({
    displayName: z.string(),
    email: z.email({ error: () => i18n.t('common.email_invalid') }),
    password: z.string().min(6, { error: () => i18n.t('common.password_too_short') }),
    confirmPassword: z.string()
  })
  .refine(input => input.password === input.confirmPassword, {
    error: () => i18n.t('common.password_mismatch'),
    path: ['confirmPassword']
  })

type AdminInput = z.infer<typeof adminSchema>

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
  const mutation = useMutation({
    mutationFn: async (input: AdminInput) => {
      await putSetupIdentityProvider({
        path: { provider_id: adapter.defaultProviderID },
        body: { data: { adapterID: adapter.adapterID, config: defaultConfig(adapter.fields), enabled: true } }
      })
      return createSetupLocalAdmin({
        body: {
          data: {
            display_name: input.displayName.trim() || undefined,
            email: input.email,
            password: input.password
          }
        }
      })
    },
    onSuccess: result => window.location.assign(result.returnTo)
  })
  const form = useForm({
    defaultValues: { displayName: '', email: '', password: '', confirmPassword: '' },
    validationLogic: revalidateLogic(),
    validators: { onDynamic: adminSchema },
    onSubmit: ({ value }) => {
      mutation.mutate(value)
    }
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
      <form
        className="grid gap-6"
        noValidate
        onSubmit={event => {
          event.preventDefault()
          event.stopPropagation()
          void form.handleSubmit()
        }}>
        <FieldGroup className="grid grid-cols-1 gap-5 md:grid-cols-2">
          <form.Field name="displayName">
            {field => (
              <Field className="md:col-span-2">
                <FieldLabel htmlFor={displayNameID}>{t('setup.admin_display_name')}</FieldLabel>
                <Input
                  autoComplete="name"
                  id={displayNameID}
                  name={field.name}
                  value={field.state.value}
                  onBlur={field.handleBlur}
                  onChange={event => field.handleChange(event.target.value)}
                />
              </Field>
            )}
          </form.Field>
          <form.Field name="email">
            {field => {
              const error = field.state.meta.errors[0]?.message
              return (
                <Field className="md:col-span-2">
                  <FieldLabel htmlFor={emailID}>{t('setup.admin_email')}</FieldLabel>
                  <Input
                    aria-invalid={error ? true : undefined}
                    autoComplete="username"
                    id={emailID}
                    name={field.name}
                    type="email"
                    value={field.state.value}
                    onBlur={field.handleBlur}
                    onChange={event => field.handleChange(event.target.value)}
                  />
                  {error ? <UiFieldError>{error}</UiFieldError> : null}
                </Field>
              )
            }}
          </form.Field>

          <form.Field name="password">
            {field => {
              const error = field.state.meta.errors[0]?.message
              return (
                <Field>
                  <FieldLabel htmlFor={passwordID}>{t('setup.admin_password')}</FieldLabel>
                  <PasswordInput
                    aria-invalid={error ? true : undefined}
                    autoComplete="new-password"
                    id={passwordID}
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
                  <FieldLabel htmlFor={confirmPasswordID}>{t('setup.admin_password_confirm')}</FieldLabel>
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
      </form>
    </section>
  )
}
