import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import { Skeleton, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useMemo, type ComponentProps } from 'react'
import type { TFunction } from 'i18next'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'
import { ankoleWebAgentControllerPutProviderHostedMutation } from '../api/generated/@tanstack/react-query.gen'
import {
  ankoleWebAgentControllerDeleteModelProfile,
  ankoleWebAgentControllerPutModelProfile
} from '../api/generated/sdk.gen'
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
import { useEditorDraft } from '../use-editor-draft'

const REQUIRED_PROFILES = new Set<string>(['primary', 'light', 'heavy'])

export function modelProfileLabel(t: TFunction, profile: ProfileName) {
  return t(`console.models.${profile}_label`)
}

function profileDescription(t: TFunction, profile: ProfileName) {
  return t(`console.models.${profile}_description`)
}

type ModelProfilesEditorProps = {
  agent: AgentItem
  error: unknown
  loading: boolean
  onChanged: () => void
  profiles: JSONObject
  providerHosted: ProviderHostedCapabilities
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: unknown
}

type ProfilePersistence = { submission: ModelProfileSubmission } & (
  | { action: 'saved'; body: ModelProfileWriteRequest }
  | { action: 'cleared' }
)

export function ModelProfilesEditor(props: ModelProfilesEditorProps) {
  return <AgentModelProfilesEditor key={props.agent.uid} {...props} />
}

function AgentModelProfilesEditor({
  agent,
  error,
  loading,
  onChanged,
  profiles,
  providerHosted,
  providers,
  providerKinds,
  modelCatalog
}: ModelProfilesEditorProps) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(ModelProfilesModel)
  const modelProfileDrafts = useMemo(
    () =>
      loading
        ? undefined
        : Object.fromEntries(
            PROFILE_NAMES.map(profile => [profile, draftFromProfile(recordValue(profiles[profile]) ?? {})])
          ),
    [loading, profiles]
  )
  const draftStatus = useEditorDraft(model, {
    identity: { resource: 'model-profiles', agentUID: agent.uid },
    source: modelProfileDrafts
  })

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
      <ErrorBlock error={error ?? saveProviderHosted.error} />
      {draftStatus === 'loading' ? (
        <div className="grid gap-4" aria-busy="true">
          <Skeleton className="h-48 w-full" />
          <Skeleton className="h-48 w-full" />
          <Skeleton className="h-48 w-full" />
        </div>
      ) : (
        <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-4 [&>*]:min-w-0">
          {PROFILE_NAMES.map(profile => (
            <ProfileEditor
              key={profile}
              agentUID={agent.uid}
              profile={profile}
              model={model}
              providers={providers}
              providerKinds={providerKinds}
              modelCatalog={modelCatalog}
              providerHosted={providerHostedFor(profile)}
              onChanged={onChanged}
            />
          ))}
        </div>
      )}
    </section>
  )
}

function ProfileEditor({
  agentUID,
  profile,
  model,
  providers,
  providerKinds,
  modelCatalog,
  providerHosted,
  onChanged
}: {
  agentUID: string
  profile: ProfileName
  model: InstanceType<typeof ModelProfilesModel>
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: unknown
  providerHosted: ComponentProps<typeof ModelProfileEditorCard>['providerHosted']
  onChanged: () => void
}) {
  useSignals()
  const { t } = useTranslation()
  const signals = model.profiles[profile]
  const draft = model.snapshot(profile)
  const required = REQUIRED_PROFILES.has(profile)
  const configured = Boolean(draft.providerID && (!profileUsesConfigurableModel(profile) || draft.model))
  const persist = useMutation({
    mutationFn: async (input: ProfilePersistence) => {
      const path = { agent_uid: agentUID, profile }
      const response =
        input.action === 'saved'
          ? await ankoleWebAgentControllerPutModelProfile({ path, body: input.body, throwOnError: true })
          : await ankoleWebAgentControllerDeleteModelProfile({ path, throwOnError: true })
      return response.data
    },
    onSuccess: () => onChanged()
  })
  const finishPersistence = (response: { model_profile?: unknown }, input: ProfilePersistence) => {
    const result = model.markSaved(
      profile,
      draftFromProfile(recordValue(response.model_profile) ?? {}),
      input.submission
    )
    const messageKey = result.hasUnsavedChanges ? `${input.action}_with_unsaved_changes` : input.action
    const message = t(`console.models.${messageKey}`, { profile: modelProfileLabel(t, profile) })
    if (result.hasUnsavedChanges) toast.info(message)
    else toast.success(message)
  }
  const submit = () => {
    if (persist.isPending) return
    const built = buildModelProfileWriteRequest({
      profile,
      draft: model.snapshot(profile),
      providers,
      providerKinds,
      t
    })
    if (!built.ok) {
      model.update(profile, { error: built.error })
      return
    }
    model.update(profile, { error: undefined })
    persist.mutate(
      { action: 'saved', submission: model.submission(profile), body: built.body },
      { onSuccess: finishPersistence }
    )
  }
  return (
    <div className="grid min-w-0 gap-2">
      <ErrorBlock error={persist.error} />
      <ModelProfileEditorCard
        profile={profile}
        label={modelProfileLabel(t, profile)}
        draft={draft}
        dirty={signals.dirty.value}
        required={required}
        hint={profileDescription(t, profile)}
        persistencePending={persist.isPending}
        providerHosted={providerHosted}
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
        onUpdate={patch => model.update(profile, patch)}
        onSave={submit}
        onDelete={() =>
          required
            ? model.clear(profile)
            : persist.mutate(
                { action: 'cleared', submission: model.submission(profile) },
                { onSuccess: finishPersistence }
              )
        }
      />
    </div>
  )
}
