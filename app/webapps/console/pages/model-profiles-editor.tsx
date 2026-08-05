import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import { toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useEffect, useRef } from 'react'
import type { TFunction } from 'i18next'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebAgentControllerDeleteModelProfileMutation,
  ankoleWebAgentControllerPutModelProfileMutation
} from '../api/generated/@tanstack/react-query.gen'
import type {
  AgentItem,
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem,
  ModelProfileWriteRequest
} from '../api/generated/types.gen'
import { ErrorBlock } from '../console-primitives'
import {
  ModelProfilesModel,
  PROFILE_NAMES,
  type ModelProfileSubmission,
  type ProfileDraft,
  type ProfileName
} from '../state/model-profiles-model'
import { ModelProfileEditorCard, buildModelProfileWriteRequest } from './model-profile-editor-card'
import { profileUsesConfigurableModel } from './model-profile-options'

const REQUIRED_PROFILES = new Set<string>(['primary', 'light', 'heavy'])

function profileLabel(t: TFunction, profile: ProfileName) {
  return profile === 'coding' ? t('console.models.background_agent_jobs') : profile
}

function profileDescription(t: TFunction, profile: ProfileName) {
  return t(`console.models.${profile}_description`)
}

export function ModelProfilesEditor({
  agent,
  error,
  loading,
  onChanged,
  profiles,
  providers,
  providerKinds,
  modelCatalog
}: {
  agent: AgentItem
  error: unknown
  loading: boolean
  onChanged: () => void
  profiles: JSONObject
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: unknown
}) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(ModelProfilesModel)
  const currentAgentUID = useRef(agent.uid)
  currentAgentUID.current = agent.uid
  const pendingSaveSubmissions = useRef(new Map<string, ModelProfileSubmission>())
  const pendingClearSubmissions = useRef(new Map<string, ModelProfileSubmission>())

  const finishPersistence = (
    savedAgentUID: string,
    profile: ProfileName,
    submission: ModelProfileSubmission,
    persistedProfile: unknown,
    action: 'saved' | 'cleared'
  ) => {
    if (currentAgentUID.current === savedAgentUID) {
      const result = model.markSaved(profile, draftFromProfile(recordValue(persistedProfile) ?? {}), submission)
      const messageKey = result.hasUnsavedChanges ? `${action}_with_unsaved_changes` : action
      const label = profileLabel(t, profile)

      if (result.hasUnsavedChanges) toast.info(t(`console.models.${messageKey}`, { profile: label }))
      else toast.success(t(`console.models.${messageKey}`, { profile: label }))
    }
    onChanged()
  }

  const saveProfile = useMutation({
    ...ankoleWebAgentControllerPutModelProfileMutation(),
    onSuccess: (response, variables) => {
      const profile = variables.path.profile as ProfileName
      const key = profileSubmissionKey(variables.path.agent_uid, profile)
      const submission = pendingSaveSubmissions.current.get(key)
      pendingSaveSubmissions.current.delete(key)
      if (submission) {
        finishPersistence(variables.path.agent_uid, profile, submission, response.model_profile, 'saved')
      } else onChanged()
    },
    onError: (_error, variables) => {
      pendingSaveSubmissions.current.delete(
        profileSubmissionKey(variables.path.agent_uid, variables.path.profile as ProfileName)
      )
    }
  })
  const clearProfile = useMutation({
    ...ankoleWebAgentControllerDeleteModelProfileMutation(),
    onSuccess: (response, variables) => {
      const profile = variables.path.profile as ProfileName
      const key = profileSubmissionKey(variables.path.agent_uid, profile)
      const submission = pendingClearSubmissions.current.get(key)
      pendingClearSubmissions.current.delete(key)
      if (submission) {
        finishPersistence(variables.path.agent_uid, profile, submission, response.model_profile, 'cleared')
      } else onChanged()
    },
    onError: (_error, variables) => {
      pendingClearSubmissions.current.delete(
        profileSubmissionKey(variables.path.agent_uid, variables.path.profile as ProfileName)
      )
    }
  })

  useEffect(() => {
    if (loading) return
    model.initialize(
      `agent:${agent.uid}`,
      Object.fromEntries(
        PROFILE_NAMES.map(profile => [profile, draftFromProfile(recordValue(profiles[profile]) ?? {})])
      )
    )
  }, [agent.uid, loading, model, profiles])

  const updateDraft = (profile: ProfileName, patch: Partial<ProfileDraft>) => model.update(profile, patch)

  const persistProfile = (profile: ProfileName, submission: ModelProfileSubmission, body: ModelProfileWriteRequest) => {
    pendingSaveSubmissions.current.set(profileSubmissionKey(agent.uid, profile), submission)
    saveProfile.mutate({ body, path: { agent_uid: agent.uid, profile } })
  }

  const clear = (profile: ProfileName) => {
    const submission = model.submission(profile)
    pendingClearSubmissions.current.set(profileSubmissionKey(agent.uid, profile), submission)
    clearProfile.mutate({ path: { agent_uid: agent.uid, profile } })
  }

  const submit = (profile: ProfileName) => {
    const draft = model.snapshot(profile)
    const built = buildModelProfileWriteRequest({
      profile,
      draft,
      providers,
      providerKinds,
      t
    })
    if (!built.ok) {
      updateDraft(profile, { error: built.error })
      return
    }

    updateDraft(profile, { error: undefined })
    persistProfile(profile, model.submission(profile), built.body)
  }

  const persistencePending = saveProfile.isPending || clearProfile.isPending

  return (
    <section id="model-profiles" className="grid scroll-mt-16 gap-4">
      <div className="grid gap-1">
        <h3 className="text-lg font-semibold tracking-normal">{t('console.models.title')}</h3>
        <p className="text-sm leading-6 text-muted-foreground">{t('console.models.description')}</p>
      </div>
      <ErrorBlock error={error ?? saveProfile.error ?? clearProfile.error} />
      {loading ? <span className="text-xs text-muted-foreground">{t('common.loading')}</span> : null}
      <div className="grid gap-4">
        {PROFILE_NAMES.map(profile => {
          const signals = model.profiles[profile]
          const draft: ProfileDraft = {
            description: signals.description.value,
            providerID: signals.providerID.value,
            model: signals.model.value,
            contextLength: signals.contextLength.value,
            providerOptions: signals.providerOptions.value,
            error: signals.error.value
          }
          const configurableModel = profileUsesConfigurableModel(profile)
          const configured = Boolean(draft.providerID && (!configurableModel || draft.model))
          const required = REQUIRED_PROFILES.has(profile)

          return (
            <ModelProfileEditorCard
              key={profile}
              profile={profile}
              label={profileLabel(t, profile)}
              draft={draft}
              dirty={signals.dirty.value}
              required={required}
              hint={profileDescription(t, profile)}
              persistencePending={persistencePending}
              deleteDisabled={!configured}
              deleteLabel={t('console.models.clear')}
              providers={providers}
              providerKinds={providerKinds}
              modelCatalog={modelCatalog}
              onUpdate={patch => updateDraft(profile, patch)}
              onSave={() => submit(profile)}
              onDelete={() => (required ? model.clear(profile) : clear(profile))}
            />
          )
        })}
      </div>
    </section>
  )
}

export function draftFromProfile(profile: JSONObject): ProfileDraft {
  return {
    description: asString(profile.description),
    providerID: asString(profile.provider_id),
    model: asString(profile.model),
    contextLength: profile.context_length ? String(profile.context_length) : '',
    providerOptions: recordValue(profile.provider_options) ?? {}
  }
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function profileSubmissionKey(agentUID: string, profile: ProfileName): string {
  return `${agentUID}:${profile}`
}
