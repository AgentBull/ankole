import { buttonVariants, Checkbox, cn, Input } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from '@tanstack/react-router'
import { createLocalUserMutation } from '../api/v2/generated/@tanstack/react-query.gen'
import { fromDocument } from '../api/json-api'
import { requestErrorCode, requestErrorDetailList } from '../../common/request-errors'
import { LabeledField, ResourceEditorPage } from '../console-form'
import { BackLink, PageStack } from '../console-page'
import { InitialPasswordReveal } from '../initial-password-reveal'
import { PrincipalEditorModel, type PrincipalDraftError } from '../state/principal-editor-model'
import { useEditorDraft } from '../use-editor-draft'

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

/** Localizes the write-endpoint failures this page can trigger: a taken email is a field error. */
export function principalRequestError(error: unknown, t: Translate): unknown {
  const emailTaken =
    requestErrorCode(error) === 'validation_failed' &&
    requestErrorDetailList(error).some(
      detail => detail.path === 'email' && typeof detail.message === 'string' && detail.message.includes('taken')
    )
  return emailTaken ? t('console.principals.email_taken') : (error ?? undefined)
}

/**
 * Creates a local human user in two stages on one route: the form, then the
 * one-time initial password. The password exists only in mutation data, so a
 * reload cannot bring it back.
 */
export function PrincipalCreatePage() {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(PrincipalEditorModel)
  const principalDraft = useMemo(() => ({ displayName: '', email: '' }), [])
  const draftStatus = useEditorDraft(model, {
    sourceKey: 'new',
    source: principalDraft
  })

  const create = useMutation({
    ...createLocalUserMutation()
  })

  if (create.data) {
    const created = fromDocument(create.data)
    return (
      <PageStack className="mx-auto w-full max-w-3xl">
        <div className="grid gap-3">
          <BackLink to="/access/principals" />
          <h2 className="text-2xl font-semibold tracking-normal">
            {t(
              created.local_credential_status === 'must_change'
                ? 'console.principals.initial_password_title'
                : 'console.principals.initial_password_title_static'
            )}
          </h2>
        </div>
        <div className="grid gap-5 border border-border bg-card p-5 md:p-6">
          <InitialPasswordReveal
            password={String(create.data.meta?.initial_password ?? '')}
            actions={
              <Link
                className={cn(buttonVariants({ size: 'sm' }))}
                to={`/access/principals/${encodeURIComponent(created.id)}`}>
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
    const draftError = model.draftError(true)
    if (draftError) {
      model.validationError.value = draftError
      return
    }
    create.mutate({ body: { data: { type: 'principal', attributes: model.createBody() } } })
  }

  return (
    <ResourceEditorPage
      title={t('console.principals.create_title')}
      description={t('console.principals.create_description')}
      backTo="/access/principals"
      dirty={model.dirty.value}
      validationError={
        model.validationError.value ? principalDraftErrorText(model.validationError.value, t) : undefined
      }
      error={principalRequestError(create.error, t)}
      submitting={create.isPending}
      submitUnavailable={draftStatus !== 'ready'}
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
