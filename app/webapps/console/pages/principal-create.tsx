import { buttonVariants, Checkbox, cn, Input } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'
import { ankoleWebPrincipalControllerCreateMutation } from '../api/generated/@tanstack/react-query.gen'
import { requestErrorCode } from '../../common/request-errors'
import { LabeledField, ResourceEditorPage } from '../console-form'
import { BackLink, PageStack } from '../console-page'
import { InitialPasswordReveal } from '../initial-password-reveal'
import { PrincipalEditorModel, type PrincipalDraftError } from '../state/principal-editor-model'

type Translate = (key: string, values?: Record<string, unknown>) => string

export function principalDraftErrorText(error: PrincipalDraftError, t: Translate): string {
  switch (error) {
    case 'display_name_required':
      return t('common.field_required', { field: t('console.principals.display_name') })
    case 'email_required':
      return t('common.field_required', { field: t('console.principals.email') })
    case 'email_invalid':
      return t('common.email_invalid')
  }
}

/** Localizes the write-endpoint error codes this page can trigger. */
export function principalRequestError(error: unknown, t: Translate): unknown {
  switch (requestErrorCode(error)) {
    case 'email_taken':
      return t('console.principals.email_taken')
    default:
      return error ?? undefined
  }
}

/**
 * Creates a local human user in two stages on one route: the form, then the
 * one-time initial password. The password exists only in mutation data, so a
 * reload cannot bring it back.
 */
export function PrincipalCreatePage() {
  useSignals()
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const model = useModel(PrincipalEditorModel)

  useEffect(() => {
    model.initialize('new', { displayName: '', email: '' })
  }, [model])

  const create = useMutation({
    ...ankoleWebPrincipalControllerCreateMutation(),
    onSuccess: () => void queryClient.invalidateQueries()
  })

  if (create.data) {
    const created = create.data.principal
    return (
      <PageStack className="mx-auto w-full max-w-3xl">
        <div className="grid gap-3">
          <BackLink to="/access/principals" />
          <h2 className="text-2xl font-semibold tracking-normal">
            {t(
              created.local_credential?.status === 'must_change'
                ? 'console.principals.initial_password_title'
                : 'console.principals.initial_password_title_static'
            )}
          </h2>
        </div>
        <div className="grid gap-5 border border-border bg-card p-5 md:p-6">
          <InitialPasswordReveal
            password={create.data.initial_password}
            actions={
              <Link
                className={cn(buttonVariants({ size: 'sm' }))}
                to={`/access/principals/${encodeURIComponent(created.uid)}`}>
                {t('console.principals.view_user')}
              </Link>
            }
          />
        </div>
      </PageStack>
    )
  }

  const submit = () => {
    model.clearValidation()
    const draftError = model.draftError()
    if (draftError) {
      model.validationError.value = principalDraftErrorText(draftError, t)
      return
    }
    create.mutate({ body: model.createBody() })
  }

  return (
    <ResourceEditorPage
      title={t('console.principals.create_title')}
      description={t('console.principals.create_description')}
      backTo="/access/principals"
      error={model.validationError.value ?? principalRequestError(create.error, t)}
      submitting={create.isPending}
      submitLabel={t('console.principals.create_submit')}
      onSubmit={submit}>
      <LabeledField label={t('console.principals.display_name')} required>
        <Input
          required
          value={model.displayName.value}
          onChange={event => (model.displayName.value = event.target.value)}
        />
      </LabeledField>
      <LabeledField label={t('console.principals.email')} required>
        <Input
          required
          type="email"
          value={model.email.value}
          onChange={event => (model.email.value = event.target.value)}
        />
      </LabeledField>
      <MustChangePasswordField
        checked={model.mustChangePassword.value}
        onChange={checked => (model.mustChangePassword.value = checked)}
      />
    </ResourceEditorPage>
  )
}

/** Shared "must change password at first sign-in" choice for create and reset. */
export function MustChangePasswordField({
  checked,
  onChange
}: {
  checked: boolean
  onChange: (checked: boolean) => void
}) {
  const { t } = useTranslation()

  return (
    <label className="flex items-start gap-3">
      <Checkbox checked={checked} onCheckedChange={value => onChange(value === true)} />
      <span className="grid gap-1">
        <span className="text-sm leading-5">{t('console.principals.must_change_password')}</span>
        <span className="text-xs leading-5 text-muted-foreground">
          {t('console.principals.must_change_password_hint')}
        </span>
      </span>
    </label>
  )
}
