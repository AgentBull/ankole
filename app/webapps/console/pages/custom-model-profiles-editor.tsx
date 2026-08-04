import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import { Button, Input, toast } from '@ankole/uikit'
import { useMutation } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
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
import { ErrorBlock } from '../console-primitives'
import { LabeledField } from '../console-form'
import { PROFILE_NAMES, emptyProfileDraft, type ProfileDraft } from '../state/model-profiles-model'
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
    if (!draft.description.trim()) {
      setDraft(current => ({ ...current, error: t('console.models.custom_profile_description_required') }))
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
  const { t } = useTranslation()
  const source = profileDraft(profile)
  const serializedSource = JSON.stringify(source)
  const [draft, setDraft] = useState<ProfileDraft>(source)

  useEffect(() => setDraft(source), [serializedSource])

  const save = useMutation({
    ...ankoleWebAgentControllerPutModelProfileMutation(),
    onSuccess: response => {
      setDraft(profileDraft(recordValue(response.model_profile) ?? {}))
      toast.success(t('console.models.saved', { profile: name }))
      onChanged()
    },
    onError: mutationError => setDraft(current => ({ ...current, error: requestErrorMessage(mutationError) }))
  })
  const remove = useMutation({
    ...ankoleWebAgentControllerDeleteModelProfileMutation(),
    onSuccess: () => {
      toast.success(t('console.models.custom_deleted', { profile: name }))
      onChanged()
    },
    onError: mutationError => setDraft(current => ({ ...current, error: requestErrorMessage(mutationError) }))
  })

  const submit = () => {
    if (!draft.description.trim()) {
      setDraft(current => ({ ...current, error: t('console.models.custom_profile_description_required') }))
      return
    }

    const built = buildModelProfileWriteRequest({
      profile: name,
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
    save.mutate({ body: built.body, path: { agent_uid: agentUID, profile: name } })
  }

  return (
    <ModelProfileEditorCard
      profile={name}
      label={name}
      draft={draft}
      dirty={!sameProfileDraft(source, draft)}
      showDescription
      persistencePending={save.isPending || remove.isPending}
      deleteDisabled={false}
      deleteLabel={t('common.delete')}
      providers={providers}
      providerKinds={providerKinds}
      modelCatalog={modelCatalog}
      onUpdate={patch => setDraft(current => ({ ...current, ...patch }))}
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

function profileDraft(profile: JSONObject): ProfileDraft {
  return {
    description: stringValue(profile.description),
    providerID: stringValue(profile.provider_id),
    model: stringValue(profile.model),
    contextLength: profile.context_length ? String(profile.context_length) : '',
    providerOptions: recordValue(profile.provider_options) ?? {}
  }
}

function sameProfileDraft(left: ProfileDraft, right: ProfileDraft): boolean {
  return (
    left.description === right.description &&
    left.providerID === right.providerID &&
    left.model === right.model &&
    left.contextLength === right.contextLength &&
    JSON.stringify(left.providerOptions) === JSON.stringify(right.providerOptions)
  )
}

function stringValue(value: unknown): string {
  return typeof value === 'string' ? value : ''
}
