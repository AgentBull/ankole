import { Input, Select, SelectContent, SelectItem, SelectTrigger, SelectValue, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { useNavigate } from '@tanstack/react-router'
import { createMemberMutation } from '../api/v2/generated/@tanstack/react-query.gen'
import { requestErrorCode, requestErrorDetailList } from '../../common/request-errors'
import { LabeledField, ResourceEditorPage } from '../console-form'
import { PrincipalEditorModel, type PrincipalDraftError } from '../state/principal-editor-model'
import { useEditorDraft } from '../use-editor-draft'

type Translate = (key: string, values?: Record<string, unknown>) => string

export function principalDraftErrorText(error: PrincipalDraftError, t: Translate): string {
  switch (error) {
    case 'display_name_required':
      return t('common.field_required', { field: t('console.principals.display_name') })
    case 'email_invalid':
      return t('common.email_invalid')
  }
}

/** Localizes the write-endpoint failures this page can trigger: a taken email is a field error. */
export function principalRequestError(error: unknown, t: Translate): unknown {
  const code = requestErrorCode(error)
  const emailTaken =
    code === 'email_taken' ||
    requestErrorDetailList(error).some(
      detail =>
        detail.code === 'email_taken' ||
        (detail.path === 'email' &&
          (detail.code === 'taken' ||
            detail.kind === 'taken' ||
            (typeof detail.message === 'string' && detail.message.includes('taken'))))
    )
  return emailTaken ? t('console.principals.email_taken') : (error ?? undefined)
}

/** Creates a pending Pod member. The member proves their login credential separately. */
export function PrincipalCreatePage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const model = useModel(PrincipalEditorModel)
  const principalDraft = useMemo(() => ({ displayName: '', email: '' }), [])
  const draftStatus = useEditorDraft(model, {
    sourceKey: 'new',
    source: principalDraft
  })

  const create = useMutation({
    ...createMemberMutation(),
    onSuccess: created => {
      toast.success(t('console.principals.created'))
      return navigate({ to: `/access/principals/${encodeURIComponent(created.uid)}` })
    }
  })

  const submit = () => {
    model.clearValidation()
    const draftError = model.draftError(true)
    if (draftError) {
      model.validationError.value = draftError
      return
    }
    create.mutate({ body: { data: model.createBody() } })
  }

  return (
    <ResourceEditorPage
      title={t('console.principals.create_title')}
      description={t('console.principals.create_description')}
      backTo="/access/principals"
      dirty={!create.isSuccess && model.dirty.value}
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
          disabled={create.isPending}
          value={model.displayName.value}
          onChange={event => (model.displayName.value = event.target.value)}
        />
      </LabeledField>
      <LabeledField label={t('console.principals.email')} required>
        <Input
          required
          disabled={create.isPending}
          type="email"
          value={model.email.value}
          onChange={event => (model.email.value = event.target.value)}
        />
      </LabeledField>
      <LabeledField label={t('console.principals.membership')} description={t('console.principals.membership_hint')}>
        <Select
          disabled={create.isPending}
          value={model.membership.value}
          onValueChange={value => {
            if (value) model.membership.value = value
          }}>
          <SelectTrigger aria-label={t('console.principals.membership')}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="member">{t('console.principals.membership_member')}</SelectItem>
            <SelectItem value="guest">{t('console.principals.membership_guest')}</SelectItem>
          </SelectContent>
        </Select>
      </LabeledField>
    </ResourceEditorPage>
  )
}
