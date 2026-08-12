import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import { Button, Input, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebAgentControllerDeleteModelProfileMutation,
  ankoleWebAgentControllerPutModelProfileMutation
} from '../api/generated/@tanstack/react-query.gen'
import type {
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem
} from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { ErrorBlock } from '../../common/error-block'
import { LabeledField } from '../console-form'
import {
  CustomModelProfileModel,
  PROFILE_NAMES,
  draftFromProfile,
  emptyProfileDraft,
  type ModelProfileSubmission,
  type ProfileDraft
} from '../state/model-profiles-model'
import { ModelProfileEditorCard, buildModelProfileWriteRequest } from './model-profile-editor-card'

const CUSTOM_PROFILE_NAME = /^[a-z][a-z0-9_-]{0,63}$/
const FIXED_PROFILE_NAMES = new Set<string>(PROFILE_NAMES)

export function CustomModelProfilesEditor({
  agentUID,
  error,
  loading,
  onChanged,
  profiles,
  providers,
  providerKinds,
  modelCatalog
}: {
  agentUID: string
  error: unknown
  loading: boolean
  onChanged: () => void
  profiles: JSONObject
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: unknown
}) {
  const { t } = useTranslation()
  const [adding, setAdding] = useState(false)
  const customProfiles = Object.entries(profiles)
    .filter(([name, value]) => isCustomProfileName(name) && recordValue(value))
    .sort(([left], [right]) => left.localeCompare(right))

  return (
    <section className="grid gap-4">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="grid gap-1">
          <h3 className="text-lg font-semibold tracking-normal">{t('console.models.custom_title')}</h3>
          <p className="text-sm leading-6 text-muted-foreground">{t('console.models.custom_description')}</p>
        </div>
        <Button disabled={adding} size="sm" type="button" onClick={() => setAdding(true)}>
          {t('console.models.add_custom_profile')}
        </Button>
      </div>
      <ErrorBlock error={error} />
      {loading ? <span className="text-xs text-muted-foreground">{t('common.loading')}</span> : null}
      {adding ? (
        <NewCustomModelProfileEditor
          agentUID={agentUID}
          existingNames={new Set(Object.keys(profiles))}
          providers={providers}
          providerKinds={providerKinds}
          modelCatalog={modelCatalog}
          onChanged={onChanged}
          onClose={() => setAdding(false)}
        />
      ) : null}
      {customProfiles.map(([name, value]) => (
        <StoredCustomModelProfileEditor
          key={name}
          agentUID={agentUID}
          name={name}
          profile={recordValue(value) ?? {}}
          providers={providers}
          providerKinds={providerKinds}
          modelCatalog={modelCatalog}
          onChanged={onChanged}
        />
      ))}
      {!loading && !adding && customProfiles.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('console.models.custom_empty')}</p>
      ) : null}
    </section>
  )
}

function NewCustomModelProfileEditor({
  agentUID,
  existingNames,
  providers,
  providerKinds,
  modelCatalog,
  onChanged,
  onClose
}: {
  agentUID: string
  existingNames: Set<string>
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: unknown
  onChanged: () => void
  onClose: () => void
}) {
  const { t } = useTranslation()
  const [name, setName] = useState('')
  const [draft, setDraft] = useState<ProfileDraft>(emptyProfileDraft)
  const save = useMutation({
    ...ankoleWebAgentControllerPutModelProfileMutation(),
    onSuccess: (_response, variables) => {
      toast.success(t('console.models.saved', { profile: variables.path.profile }))
      onChanged()
      onClose()
    },
    onError: mutationError => setDraft(current => ({ ...current, error: requestErrorMessage(mutationError) }))
  })

  const submit = () => {
    const profile = name.trim()
    const nameError = customProfileNameError(profile, existingNames, t)
    if (nameError) {
      setDraft(current => ({ ...current, error: nameError }))
      return
    }

    const built = buildModelProfileWriteRequest({
      profile,
      draft,
      providers,
      providerKinds,
      t,
      includeDescription: true
    })
    if (!built.ok) {
      setDraft(current => ({ ...current, error: built.error }))
      return
    }

    setDraft(current => ({ ...current, error: undefined }))
    save.mutate({ body: built.body, path: { agent_uid: agentUID, profile } })
  }

  return (
    <ModelProfileEditorCard
      profile="custom"
      label={name.trim() || t('console.models.new_custom_profile')}
      draft={draft}
      dirty
      saveIncomplete={Boolean(customProfileNameError(name.trim(), existingNames, t))}
      nameField={
        <LabeledField
          label={t('console.models.custom_name')}
          description={t('console.models.custom_name_hint')}
          required>
          <Input
            autoFocus
            maxLength={64}
            value={name}
            onChange={event => {
              setName(event.target.value)
              setDraft(current => ({ ...current, error: undefined }))
            }}
          />
        </LabeledField>
      }
      showDescription
      persistencePending={save.isPending}
      deleteDisabled={false}
      deleteLabel={t('common.cancel')}
      providers={providers}
      providerKinds={providerKinds}
      modelCatalog={modelCatalog}
      onUpdate={patch => setDraft(current => ({ ...current, ...patch }))}
      onSave={submit}
      onDelete={onClose}
    />
  )
}

function StoredCustomModelProfileEditor({
  agentUID,
  name,
  profile,
  providers,
  providerKinds,
  modelCatalog,
  onChanged
}: {
  agentUID: string
  name: string
  profile: JSONObject
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: unknown
  onChanged: () => void
}) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(CustomModelProfileModel)
  const pendingSubmission = useRef<ModelProfileSubmission>(undefined)

  useEffect(() => {
    model.initialize(`agent:${agentUID}:${name}`, draftFromProfile(profile))
  }, [agentUID, model, name, profile])

  const save = useMutation({
    ...ankoleWebAgentControllerPutModelProfileMutation(),
    onSuccess: (response, variables) => {
      const submission = pendingSubmission.current
      pendingSubmission.current = undefined
      if (submission && variables.path.agent_uid === agentUID) {
        const result = model.markSaved(draftFromProfile(recordValue(response.model_profile) ?? {}), submission)
        if (result.hasUnsavedChanges) toast.info(t('console.models.saved_with_unsaved_changes', { profile: name }))
        else toast.success(t('console.models.saved', { profile: name }))
      }
      onChanged()
    },
    onError: mutationError => {
      pendingSubmission.current = undefined
      model.update({ error: requestErrorMessage(mutationError) })
    }
  })
  const remove = useMutation({
    ...ankoleWebAgentControllerDeleteModelProfileMutation(),
    onSuccess: () => {
      toast.success(t('console.models.custom_deleted', { profile: name }))
      onChanged()
    },
    onError: mutationError => model.update({ error: requestErrorMessage(mutationError) })
  })

  const submit = () => {
    const built = buildModelProfileWriteRequest({
      profile: name,
      draft: model.snapshot(),
      providers,
      providerKinds,
      t,
      includeDescription: true
    })
    if (!built.ok) {
      model.update({ error: built.error })
      return
    }

    model.update({ error: undefined })
    pendingSubmission.current = model.submission()
    save.mutate({ body: built.body, path: { agent_uid: agentUID, profile: name } })
  }

  const draft = model.snapshot()

  return (
    <ModelProfileEditorCard
      profile={name}
      label={name}
      draft={draft}
      dirty={model.profile.dirty.value}
      showDescription
      persistencePending={save.isPending || remove.isPending}
      deleteConfirm={{
        title: t('console.models.delete_custom_title'),
        description: t('console.models.delete_custom_description', { profile: name }),
        confirmLabel: t('common.delete')
      }}
      deleteDisabled={false}
      deleteLabel={t('common.delete')}
      providers={providers}
      providerKinds={providerKinds}
      modelCatalog={modelCatalog}
      onUpdate={patch => model.update(patch)}
      onSave={submit}
      onDelete={() => remove.mutate({ path: { agent_uid: agentUID, profile: name } })}
    />
  )
}

export function isCustomProfileName(name: string): boolean {
  return CUSTOM_PROFILE_NAME.test(name) && !FIXED_PROFILE_NAMES.has(name)
}

function customProfileNameError(name: string, existingNames: Set<string>, t: ReturnType<typeof useTranslation>['t']) {
  if (!CUSTOM_PROFILE_NAME.test(name)) return t('console.models.custom_name_invalid')
  if (FIXED_PROFILE_NAMES.has(name)) return t('console.models.custom_name_reserved')
  if (existingNames.has(name)) return t('console.models.custom_name_exists')
  return undefined
}
