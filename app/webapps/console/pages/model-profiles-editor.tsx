import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import { Skeleton, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useEffect, useRef } from 'react'
import type { TFunction } from 'i18next'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'
import {
  ankoleWebAgentControllerDeleteModelProfileMutation,
  ankoleWebAgentControllerPutModelProfileMutation,
  ankoleWebAgentControllerPutProviderHostedMutation
} from '../api/generated/@tanstack/react-query.gen'
import type {
  AgentItem,
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem,
  ModelProfileWriteRequest,
  ProviderHostedCapabilities
} from '../api/generated/types.gen'
import { ErrorBlock } from '../../common/error-block'
import {
  draftFromProfile,
  ModelProfilesModel,
  PROFILE_NAMES,
  type ModelProfileSubmission,
  type ProfileDraft,
  type ProfileName
} from '../state/model-profiles-model'
import { ModelProfileEditorCard, buildModelProfileWriteRequest } from './model-profile-editor-card'
import { profileUsesConfigurableModel } from './model-profile-options'

const REQUIRED_PROFILES = new Set<string>(['primary', 'light', 'heavy'])

export function modelProfileLabel(t: TFunction, profile: ProfileName) {
  return t(`console.models.${profile}_label`)
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
  providerHosted,
  providers,
  providerKinds,
  modelCatalog
}: {
  agent: AgentItem
  error: unknown
  loading: boolean
  onChanged: () => void
  profiles: JSONObject
  providerHosted: ProviderHostedCapabilities
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
      const label = modelProfileLabel(t, profile)

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

  // One in-flight save or clear per profile: a repeat submit while the first
  // request runs would double-write and strand the submission bookkeeping.
  const persistProfile = (profile: ProfileName, submission: ModelProfileSubmission, body: ModelProfileWriteRequest) => {
    const key = profileSubmissionKey(agent.uid, profile)
    if (pendingSaveSubmissions.current.has(key) || pendingClearSubmissions.current.has(key)) return
    pendingSaveSubmissions.current.set(key, submission)
    saveProfile.mutate({ body, path: { agent_uid: agent.uid, profile } })
  }

  const clear = (profile: ProfileName) => {
    const key = profileSubmissionKey(agent.uid, profile)
    if (pendingSaveSubmissions.current.has(key) || pendingClearSubmissions.current.has(key)) return
    const submission = model.submission(profile)
    pendingClearSubmissions.current.set(key, submission)
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

  const saveProviderHosted = useMutation({
    ...ankoleWebAgentControllerPutProviderHostedMutation(),
    onSuccess: () => onChanged(),
    onError: () => onChanged()
  })

  const providerHostedCapability = (profile: ProfileName) => {
    if (profile === 'web_search' || profile === 'image_generate') return profile
    return undefined
  }

  const providerHostedFor = (profile: ProfileName) => {
    const capability = providerHostedCapability(profile)
    if (!capability) return undefined

    return {
      checked: providerHosted[capability],
      pending: saveProviderHosted.isPending,
      label: t(`console.models.provider_hosted_${capability}_label`),
      description: t(`console.models.provider_hosted_${capability}_description`),
      replacesProfile: true,
      onChange: (next: boolean) =>
        saveProviderHosted.mutate({
          path: { agent_uid: agent.uid },
          body: { [capability]: next }
        })
    }
  }

  // `mutation.variables` names only the latest call, so overlapping saves to
  // two profiles would drop the first card's pending state. The submission
  // maps track every in-flight profile; `isPending` keeps the render
  // subscription that the ref reads alone would not provide.
  const profilePersistencePending = (profile: ProfileName) => {
    const key = profileSubmissionKey(agent.uid, profile)
    return (
      (saveProfile.isPending && pendingSaveSubmissions.current.has(key)) ||
      (clearProfile.isPending && pendingClearSubmissions.current.has(key))
    )
  }

  return (
    <section id="model-profiles" className="grid min-w-0 scroll-mt-16 grid-cols-[minmax(0,1fr)] gap-4 [&>*]:min-w-0">
      <div className="grid gap-1">
        <h3 className="text-lg font-semibold tracking-normal">{t('console.models.title')}</h3>
        <p className="text-sm leading-6 text-muted-foreground">{t('console.models.description')}</p>
        {!loading && providers.length === 0 ? (
          <p className="text-sm leading-6 text-muted-foreground">
            {t('console.models.provider_none_hint')}{' '}
            <Link className="text-link underline-offset-4 hover:underline" to="/providers/new">
              {t('console.models.provider_none_action')}
            </Link>
          </p>
        ) : null}
      </div>
      <ErrorBlock error={error ?? saveProfile.error ?? clearProfile.error ?? saveProviderHosted.error} />
      {loading ? (
        <div className="grid gap-4" aria-busy="true">
          <Skeleton className="h-48 w-full" />
          <Skeleton className="h-48 w-full" />
          <Skeleton className="h-48 w-full" />
        </div>
      ) : (
        <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-4 [&>*]:min-w-0">
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
                label={modelProfileLabel(t, profile)}
                draft={draft}
                dirty={signals.dirty.value}
                required={required}
                hint={profileDescription(t, profile)}
                persistencePending={profilePersistencePending(profile)}
                providerHosted={providerHostedFor(profile)}
                deleteConfirm={
                  required
                    ? undefined
                    : {
                        title: t('console.models.clear_title'),
                        description: t('console.models.clear_description', { profile: modelProfileLabel(t, profile) }),
                        confirmLabel: t('console.models.clear')
                      }
                }
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
      )}
    </section>
  )
}

function profileSubmissionKey(agentUID: string, profile: ProfileName): string {
  return `${agentUID}:${profile}`
}
