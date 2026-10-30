import { useMutation } from '../tenant-context'
import type { AIGatewayModelCatalogEntry } from '../state/provider-settings'
import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import { Button, Input, Skeleton, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'

import { useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  deleteAgentModelProfileMutation,
  putAgentModelProfileMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { AIGatewayProviderKindItem } from '../state/provider-settings'
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
import { useEditorDraft } from '../use-editor-draft'
import type { AIGatewayProviderItem } from '../state/provider-settings'

const CUSTOM_PROFILE_NAME = /^[a-z][a-z0-9_-]{0,63}$/
const FIXED_PROFILE_NAMES = new Set<string>(PROFILE_NAMES)

export function CustomModelProfilesEditor({
  agentUID,
  error,
  loading,
  profiles,
  providers,
  providerKinds,
  modelCatalog,
  onDirtyChange
}: {
  agentUID: string
  error: unknown
  loading: boolean
  profiles: JSONObject
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: AIGatewayModelCatalogEntry[]
  onDirtyChange?: (dirty: boolean) => void
}) {
  const { t } = useTranslation()
  const [adding, setAdding] = useState(false)
  const [newProfileDirty, setNewProfileDirty] = useState(false)
  const [storedDirty, setStoredDirty] = useState<Record<string, boolean>>({})
  const customProfiles = Object.entries(profiles)
    .filter(([name, value]) => isCustomProfileName(name) && recordValue(value))
    .sort(([left], [right]) => left.localeCompare(right))
  const anyDirty =
    (adding && newProfileDirty) || customProfiles.some(([profileName]) => Boolean(storedDirty[profileName]))

  useEffect(() => {
    onDirtyChange?.(anyDirty)
    return () => onDirtyChange?.(false)
  }, [anyDirty, onDirtyChange])

  return (
    <section className="grid gap-4">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="grid gap-1">
          <h3 className="title-section">{t('console.models.custom_title')}</h3>
          <p className="text-sm leading-6 text-muted-foreground">{t('console.models.custom_description')}</p>
        </div>
        <Button
          disabled={adding}
          size="sm"
          type="button"
          onClick={() => {
            setNewProfileDirty(false)
            setAdding(true)
          }}>
          {t('console.models.add_custom_profile')}
        </Button>
      </div>
      <ErrorBlock error={error} />
      {loading ? <Skeleton className="h-48 w-full" aria-busy="true" /> : null}
      {adding ? (
        <NewCustomModelProfileEditor
          agentUID={agentUID}
          existingNames={new Set(Object.keys(profiles))}
          providers={providers}
          providerKinds={providerKinds}
          modelCatalog={modelCatalog}
          onDirtyChange={setNewProfileDirty}
          onClose={() => {
            setNewProfileDirty(false)
            setAdding(false)
          }}
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
          onDirtyChange={dirty =>
            setStoredDirty(current => (Boolean(current[name]) === dirty ? current : { ...current, [name]: dirty }))
          }
        />
      ))}
      {!loading && !adding && customProfiles.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('console.models.custom_empty')}</p>
      ) : null}
    </section>
  )
}

function hasNewCustomProfileEdits(name: string, draft: ProfileDraft): boolean {
  return Boolean(
    name.trim() ||
    draft.description.trim() ||
    draft.providerID ||
    draft.model.trim() ||
    draft.contextLength.trim() ||
    Object.keys(draft.providerOptions).length > 0
  )
}

function NewCustomModelProfileEditor({
  agentUID,
  existingNames,
  providers,
  providerKinds,
  modelCatalog,
  onDirtyChange,
  onClose
}: {
  agentUID: string
  existingNames: Set<string>
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: AIGatewayModelCatalogEntry[]
  onDirtyChange: (dirty: boolean) => void
  onClose: () => void
}) {
  const { t } = useTranslation()
  const [name, setName] = useState('')
  const [draft, setDraft] = useState<ProfileDraft>(emptyProfileDraft)
  const dirty = hasNewCustomProfileEdits(name, draft)

  useEffect(() => {
    onDirtyChange(dirty)
    return () => onDirtyChange(false)
  }, [dirty, onDirtyChange])
  // Blocks a repeat submit synchronously; `save.isPending` flips only after
  // the render that follows the first mutate.
  const pendingSubmission = useRef(false)
  const save = useMutation({
    ...putAgentModelProfileMutation(),
    onSuccess: (_response, variables) => {
      toast.success(t('console.models.saved', { profile: variables.path.profile }))
      onClose()
    },
    onError: mutationError => setDraft(current => ({ ...current, error: requestErrorMessage(mutationError) })),
    onSettled: () => {
      pendingSubmission.current = false
    }
  })

  const submit = () => {
    if (pendingSubmission.current) return
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
    pendingSubmission.current = true
    save.mutate({ body: { data: { attrs: built.body } }, path: { agent_uid: agentUID, profile } })
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
  onDirtyChange
}: {
  agentUID: string
  name: string
  profile: JSONObject
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: AIGatewayModelCatalogEntry[]
  onDirtyChange: (dirty: boolean) => void
}) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(CustomModelProfileModel)
  const pendingSubmission = useRef<ModelProfileSubmission>(undefined)
  const profileDraft = useMemo(() => draftFromProfile(profile), [profile])
  const draftStatus = useEditorDraft(model, {
    sourceKey: `agent:${agentUID}:${name}`,
    source: profileDraft
  })
  const isDirty = model.profile.dirty.value

  useEffect(() => {
    onDirtyChange(isDirty)
    return () => onDirtyChange(false)
  }, [isDirty, onDirtyChange])

  const save = useMutation({
    ...putAgentModelProfileMutation(),
    onSuccess: (response, variables) => {
      const submission = pendingSubmission.current
      pendingSubmission.current = undefined
      if (submission && variables.path.agent_uid === agentUID) {
        const result = model.markSaved(draftFromProfile(recordValue(response.model_profile) ?? {}), submission)
        if (result.hasUnsavedChanges) toast.info(t('console.models.saved_with_unsaved_changes', { profile: name }))
        else toast.success(t('console.models.saved', { profile: name }))
      }
    },
    onError: mutationError => {
      pendingSubmission.current = undefined
      model.update({ error: requestErrorMessage(mutationError) })
    }
  })
  const remove = useMutation({
    ...deleteAgentModelProfileMutation(),
    onSuccess: () => {
      toast.success(t('console.models.custom_deleted', { profile: name }))
    },
    onError: mutationError => model.update({ error: requestErrorMessage(mutationError) })
  })

  const submit = () => {
    if (pendingSubmission.current) return
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
    save.mutate({ body: { data: { attrs: built.body } }, path: { agent_uid: agentUID, profile: name } })
  }

  if (draftStatus !== 'ready') return <Skeleton className="h-48 w-full" aria-busy="true" />

  const signals = model.profile
  const draft: ProfileDraft = {
    description: signals.description.value,
    providerID: signals.providerID.value,
    model: signals.model.value,
    contextLength: signals.contextLength.value,
    providerOptions: signals.providerOptions.value,
    error: signals.error.value
  }

  return (
    <ModelProfileEditorCard
      profile={name}
      label={name}
      draft={draft}
      dirty={signals.dirty.value}
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

export function customProfileNameError(
  name: string,
  existingNames: Set<string>,
  t: ReturnType<typeof useTranslation>['t']
) {
  if (!CUSTOM_PROFILE_NAME.test(name)) return t('console.models.custom_name_invalid')
  if (FIXED_PROFILE_NAMES.has(name)) return t('console.models.custom_name_reserved')
  if (existingNames.has(name)) return t('console.models.custom_name_exists')
  return undefined
}
