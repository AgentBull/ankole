import { Input, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { useNavigate, useParams } from 'react-router'
import {
  ankoleWebPrincipalControllerShowOptions,
  ankoleWebPrincipalControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import { LabeledField, ResourceEditorPage } from '../console-form'
import { PrincipalEditorModel } from '../state/principal-editor-model'
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

  useEffect(() => {
    if (!loadedPrincipal) return
    model.initialize(
      `principal:${loadedPrincipal.uid}`,
      { displayName: loadedPrincipal.display_name ?? '', email: loadedPrincipal.email ?? '' },
      // An email owned by a directory-synced external identity is not
      // editable here; the directory stays the source of truth.
      { emailLocked: loadedPrincipal.has_external_identity }
    )
  }, [loadedPrincipal, model])

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
    const draftError = model.draftError()
    if (draftError) {
      model.validationError.value = principalDraftErrorText(draftError, t)
      return
    }
    if (loadedPrincipal) update.mutate({ body: model.updateBody(), path: { uid: loadedPrincipal.uid } })
  }

  const emailLocked = model.emailLocked.value

  return (
    <ResourceEditorPage
      title={t('console.principals.edit_title')}
      backTo={detailPath}
      error={model.validationError.value ?? principalRequestError(update.error, t) ?? principal.error}
      submitting={update.isPending}
      submitDisabled={!model.dirty.value}
      onSubmit={submit}>
      <LabeledField label={t('console.principals.display_name')} required>
        <Input
          required
          value={model.displayName.value}
          onChange={event => (model.displayName.value = event.target.value)}
        />
      </LabeledField>
      <LabeledField
        label={t('console.principals.email')}
        description={emailLocked ? t('console.principals.email_managed') : undefined}
        required={!emailLocked}>
        <Input
          disabled={emailLocked}
          required={!emailLocked}
          type="email"
          value={model.email.value}
          onChange={event => (model.email.value = event.target.value)}
        />
      </LabeledField>
    </ResourceEditorPage>
  )
}
