import { Input, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { useNavigate, useParams } from 'react-router'
import {
  ankoleWebPrincipalControllerShowOptions,
  ankoleWebPrincipalControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import { requestErrorCode } from '../../common/request-errors'
import { EditorNotFound, LabeledField, ResourceEditorPage } from '../console-form'
import { PrincipalEditorModel } from '../state/principal-editor-model'
import { useEditorDraft } from '../use-editor-draft'
import { principalDraftErrorText, principalRequestError } from './principal-create'

/** Edits the display name and email of one human user. */
export function PrincipalEditPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(PrincipalEditorModel)
  const params = useParams()
  const uid = params.uid ?? ''
  const detailPath = `/access/principals/${encodeURIComponent(uid)}`
  const principal = useQuery(ankoleWebPrincipalControllerShowOptions({ path: { uid } }))
  const loadedPrincipal = principal.data?.principal
  const emailRequired = Boolean(loadedPrincipal?.email || loadedPrincipal?.local_credential)
  const principalDraft = useMemo(
    () =>
      loadedPrincipal
        ? { displayName: loadedPrincipal.display_name ?? '', email: loadedPrincipal.email ?? '' }
        : undefined,
    [loadedPrincipal]
  )
  const draftStatus = useEditorDraft(model, {
    identity: { resource: 'principal', uid },
    source: principalDraft,
    absent: () => requestErrorCode(principal.error) === 'not_found'
  })

  const update = useMutation({
    ...ankoleWebPrincipalControllerUpdateMutation(),
    onSuccess: () => {
      toast.success(t('console.principals.profile_saved'))
      void queryClient.invalidateQueries()
      navigate(detailPath)
    }
  })

  const submit = () => {
    model.clearValidation()
    const draftError = model.draftError(emailRequired)
    if (draftError) {
      model.validationError.value = draftError
      return
    }
    if (loadedPrincipal) update.mutate({ body: model.updateBody(), path: { uid: loadedPrincipal.uid } })
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
          value={model.displayName.value}
          onChange={event => (model.displayName.value = event.target.value)}
        />
      </LabeledField>
      <LabeledField label={t('console.principals.email')} required={emailRequired}>
        <Input
          required={emailRequired}
          type="email"
          value={model.email.value}
          onChange={event => (model.email.value = event.target.value)}
        />
      </LabeledField>
    </ResourceEditorPage>
  )
}
