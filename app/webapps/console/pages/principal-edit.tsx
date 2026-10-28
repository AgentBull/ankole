import { useMutation, useQuery, useNavigate } from '../tenant-context'
import { Input, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'

import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { useParams } from '@tanstack/react-router'
import { getPrincipalOptions, updateHumanMutation } from '../api/v2/generated/@tanstack/react-query.gen'
import { fromDocument } from '../api/json-api'
import { requestErrorCode } from '../../common/request-errors'
import { EditorNotFound, LabeledField, ResourceEditorPage } from '../console-form'
import { PrincipalEditorModel } from '../state/principal-editor-model'
import { useEditorDraft } from '../use-editor-draft'
import { principalDraftErrorText, principalRequestError } from './principal-create'

export function PrincipalEditPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const model = useModel(PrincipalEditorModel)
  const params = useParams({ strict: false })
  const uid = params.uid ?? ''
  const detailPath = `/access/principals/${encodeURIComponent(uid)}`
  const principal = useQuery({ ...getPrincipalOptions({ path: { uid } }), select: data => fromDocument(data) })
  const loadedPrincipal = principal.data
  const principalDraft = useMemo(
    () =>
      loadedPrincipal
        ? { displayName: loadedPrincipal.display_name ?? '', email: loadedPrincipal.email ?? '' }
        : undefined,
    [loadedPrincipal]
  )
  const draftStatus = useEditorDraft(model, {
    sourceKey: uid ? `principal:${uid}` : 'new',
    source: principalDraft,
    absent: () => requestErrorCode(principal.error) === 'not_found'
  })

  const update = useMutation({
    ...updateHumanMutation(),
    mutationKey: ['principal-update', uid]
  })

  const submit = () => {
    model.clearValidation()
    const draftError = model.draftError()
    if (draftError) {
      model.validationError.value = draftError
      return
    }
    if (!loadedPrincipal) return
    void model
      .save(
        () =>
          update.mutateAsync({
            body: { data: { type: 'principal', id: loadedPrincipal.id, attributes: model.updateBody() } },
            path: { uid: loadedPrincipal.id }
          }),
        clean => {
          toast.success(t('console.principals.profile_saved'))
          if (clean) void navigate({ to: detailPath })
        }
      )
      .catch(() => {
        /* The mutation owns the displayed request error. */
      })
  }

  if (draftStatus === 'absent') {
    return <EditorNotFound backTo="/access/principals" message={t('console.not_found.description')} />
  }

  return (
    <ResourceEditorPage
      title={t('console.principals.edit_title')}
      backTo={detailPath}
      dirty={model.dirty.value}
      validationError={
        model.validationError.value ? principalDraftErrorText(model.validationError.value, t) : undefined
      }
      error={principalRequestError(update.error, t) ?? principal.error}
      submitting={update.isPending}
      submitDisabled={!model.dirty.value}
      submitUnavailable={draftStatus !== 'ready'}
      onSubmit={submit}>
      <LabeledField label={t('console.principals.display_name')} required>
        <Input
          required
          disabled={update.isPending || draftStatus !== 'ready'}
          value={model.displayName.value}
          onChange={event => (model.displayName.value = event.target.value)}
        />
      </LabeledField>
      <LabeledField label={t('console.principals.email')}>
        <Input
          disabled={update.isPending || draftStatus !== 'ready'}
          type="email"
          value={model.email.value}
          onChange={event => (model.email.value = event.target.value)}
        />
      </LabeledField>
    </ResourceEditorPage>
  )
}
