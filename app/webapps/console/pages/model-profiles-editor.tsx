import { useMutation, Link } from '../tenant-context'
import type { AIGatewayModelCatalogEntry } from '../state/provider-settings'
import { recordValue } from '@agentbull/active-support'
import { Skeleton, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useQueryClient } from '@tanstack/react-query'
import { useLayoutEffect, useMemo, type ComponentProps } from 'react'
import type { TFunction } from 'i18next'
import { useTranslation } from 'react-i18next'

import { putAgentProviderHostedMutation } from '../api/v2/generated/@tanstack/react-query.gen'
import {
  deleteAgentModelProfile,
  putAgentModelProfile,
  deleteDefaultModelProfile,
  putDefaultModelProfile,
  deleteSystemModelProfile,
  putSystemModelProfile
} from '../api/v2/generated/sdk.gen'
import type { ListAgentModelProfilesResponse } from '../api/v2/generated/types.gen'
import type { AgentItem } from '../api/agents'
import type { AIGatewayProviderKindItem } from '../state/provider-settings'
import type { ModelProfileWriteRequest } from '../state/model-profiles-model'
import { ErrorBlock } from '../../common/error-block'
import {
  draftsFromEffective,
  resolvedProviderHosted,
  ModelProfilesModel,
  PROFILE_NAMES,
  type ModelProfileSubmission,
  type ProfileDraft,
  type ProfileName
} from '../state/model-profiles-model'
import { ModelProfileEditorCard, buildModelProfileWriteRequest } from './model-profile-editor-card'
import { useEditorDraft } from '../use-editor-draft'
import type { AIGatewayProviderItem } from '../state/provider-settings'

export function modelProfileLabel(t: TFunction, profile: ProfileName) {
  return t(`console.models.${profile}_label`)
}

export function profileDescription(t: TFunction, profile: ProfileName) {
  return t(`console.models.${profile}_description`)
}

export function profileSourceDescription(t: TFunction, profile: ProfileName, entry: unknown) {
  const resolved = recordValue(entry)
  const source = typeof resolved?.source === 'string' ? resolved.source : 'default'
  const sourceLabel = t(`console.models.source_${source}`)
  const resolvedFrom = resolved?.resolved_from_profile

  if (typeof resolvedFrom === 'string' && resolvedFrom !== profile) {
    return t('console.models.fallback_source', {
      profile: modelProfileLabel(t, resolvedFrom as ProfileName),
      source: sourceLabel
    })
  }

  return t('console.models.effective_source', { source: sourceLabel })
}

type ModelProfilesEditorProps = {
  agent: AgentItem
  error: unknown
  loading: boolean
  model?: InstanceType<typeof ModelProfilesModel>
  configuration: ListAgentModelProfilesResponse | undefined
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: AIGatewayModelCatalogEntry[]
}

type ProfilePersistence = { submission: ModelProfileSubmission } & (
  | { action: 'saved'; body: ModelProfileWriteRequest }
  | { action: 'cleared' }
)

export function useModelProfilesDraft(
  model: InstanceType<typeof ModelProfilesModel>,
  sourceKey: string,
  configuration: ListAgentModelProfilesResponse | undefined
) {
  const drafts = useMemo(() => configuration && draftsFromEffective(configuration.effective), [configuration])
  const status = useEditorDraft(model, { sourceKey, source: drafts })

  useLayoutEffect(() => {
    // Refresh inherited slots while the model preserves each unsaved draft.
    if (status === 'ready' && drafts) model.initialize(sourceKey, drafts)
  }, [drafts, model, sourceKey, status])

  return status
}

export function ModelProfilesEditor(props: ModelProfilesEditorProps) {
  return <AgentModelProfilesEditor key={props.agent.uid} {...props} />
}

function AgentModelProfilesEditor({
  agent,
  error,
  loading,
  model: externalModel,
  configuration,
  providers,
  providerKinds,
  modelCatalog
}: ModelProfilesEditorProps) {
  useSignals()
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const internalModel = useModel(ModelProfilesModel)
  const model = externalModel ?? internalModel
  const providerHosted = resolvedProviderHosted(configuration?.provider_hosted)
  const providerHostedOverrides = recordValue(configuration?.provider_hosted.overrides) ?? {}
  const draftStatus = useModelProfilesDraft(model, `agent:${agent.uid}`, configuration)

  const saveProviderHosted = useMutation({
    ...putAgentProviderHostedMutation(),
    onError: () => void queryClient.invalidateQueries()
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
          body: { data: { [capability]: next } }
        }),
      onReset: Object.hasOwn(providerHostedOverrides, capability)
        ? () =>
            saveProviderHosted.mutate({
              path: { agent_uid: agent.uid },
              body: { data: { [capability]: null } }
            })
        : undefined,
      resetLabel: t('console.models.restore_inheritance')
    }
  }

  return (
    <section id="model-profiles" className="grid min-w-0 scroll-mt-16 grid-cols-[minmax(0,1fr)] gap-4 [&>*]:min-w-0">
      <div className="grid gap-1">
        <h3 className="title-section">{t('console.models.title')}</h3>
        <p className="text-sm leading-6 text-muted-foreground">{t('console.models.description')}</p>
        {!loading && providers.length === 0 ? (
          <p className="text-sm leading-6 text-muted-foreground">
            {t('console.models.provider_none_hint')}{' '}
            <Link className="link" to="/providers/new">
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
      ) : configuration ? (
        <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-4 [&>*]:min-w-0">
          {PROFILE_NAMES.map(profile => (
            <ProfileEditor
              key={profile}
              target={{ agentUID: agent.uid }}
              profile={profile}
              model={model}
              configuration={configuration}
              providers={providers}
              providerKinds={providerKinds}
              modelCatalog={modelCatalog}
              providerHosted={providerHostedFor(profile)}
            />
          ))}
        </div>
      ) : null}
    </section>
  )
}

export function ProfileEditor({
  target,
  profile,
  model,
  configuration,
  providers,
  providerKinds,
  modelCatalog,
  providerHosted
}: {
  target: { agentUID: string } | { defaultsScope: 'tenant' | 'global' } | { systemUID: string }
  profile: ProfileName
  model: InstanceType<typeof ModelProfilesModel>
  configuration: ListAgentModelProfilesResponse
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: AIGatewayModelCatalogEntry[]
  providerHosted: ComponentProps<typeof ModelProfileEditorCard>['providerHosted']
}) {
  useSignals()
  const { t } = useTranslation()
  const signals = model.profiles[profile]
  const draft: ProfileDraft = {
    description: signals.description.value,
    providerID: signals.providerID.value,
    model: signals.model.value,
    contextLength: signals.contextLength.value,
    providerOptions: signals.providerOptions.value,
    error: signals.error.value
  }
  const hasOverride = Object.hasOwn(configuration.overrides, profile)
  const persist = useMutation({
    mutationFn: async (input: ProfilePersistence) => {
      if ('agentUID' in target) {
        const path = { agent_uid: target.agentUID, profile }
        const response =
          input.action === 'saved'
            ? await putAgentModelProfile({ path, body: { data: { attrs: input.body } }, throwOnError: true })
            : await deleteAgentModelProfile({ path, throwOnError: true })
        return response.data
      }

      if ('systemUID' in target) {
        const path = { uid: target.systemUID, profile }
        const response =
          input.action === 'saved'
            ? await putSystemModelProfile({ path, body: { data: { attrs: input.body } }, throwOnError: true })
            : await deleteSystemModelProfile({ path, throwOnError: true })
        return response.data
      }

      const response =
        input.action === 'saved'
          ? await putDefaultModelProfile({
              path: { profile },
              body: { data: { defaults_scope: target.defaultsScope, attrs: input.body } },
              throwOnError: true
            })
          : await deleteDefaultModelProfile({
              path: { profile },
              query: { defaults_scope: target.defaultsScope },
              throwOnError: true
            })
      return response.data
    }
  })
  const finishPersistence = (response: ListAgentModelProfilesResponse, input: ProfilePersistence) => {
    const result = model.markSaved(profile, response.effective, input.submission)
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
  const inherited = recordValue(configuration.inherited[profile])
  const inheritedHint =
    hasOverride && recordValue(inherited?.value)
      ? t('console.models.inherited_source', { source: t(`console.models.source_${inherited?.source}`) })
      : ''

  return (
    <div className="grid min-w-0 gap-2">
      <ErrorBlock error={persist.error} />
      <ModelProfileEditorCard
        profile={profile}
        label={modelProfileLabel(t, profile)}
        draft={draft}
        dirty={signals.dirty.value}
        hint={`${profileDescription(t, profile)} ${profileSourceDescription(t, profile, configuration.effective[profile])} ${inheritedHint}`}
        persistencePending={persist.isPending}
        providerHosted={providerHosted}
        deleteConfirm={{
          title: t('console.models.clear_title'),
          description: t('console.models.clear_description', { profile: modelProfileLabel(t, profile) }),
          confirmLabel: t('console.models.restore_inheritance')
        }}
        deleteDisabled={!hasOverride}
        deleteLabel={t('console.models.restore_inheritance')}
        providers={providers}
        providerKinds={providerKinds}
        modelCatalog={modelCatalog}
        onUpdate={patch => model.update(profile, patch)}
        onSave={submit}
        onDelete={() =>
          persist.mutate({ action: 'cleared', submission: model.submission(profile) }, { onSuccess: finishPersistence })
        }
      />
    </div>
  )
}
