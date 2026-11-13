import { useMutation, Link } from '../tenant-context'
import type { AIGatewayModelCatalogEntry } from '../state/provider-settings'
import { recordValue } from '@agentbull/active-support'
import { Skeleton, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useQueryClient } from '@tanstack/react-query'
import { useLayoutEffect, useMemo, useState, type ComponentProps } from 'react'
import type { TFunction } from 'i18next'
import { useTranslation } from 'react-i18next'

import { putAgentProviderHostedMutation } from '../api/v2/generated/@tanstack/react-query.gen'
import {
  deleteAgentModelProfile,
  putAgentModelProfile,
  putAgentProviderHosted,
  deleteDefaultModelProfile,
  putDefaultModelProfile,
  putDefaultProviderHosted,
  deleteSystemModelProfile,
  putSystemModelProfile
} from '../api/v2/generated/sdk.gen'
import type { ListAgentModelProfilesResponse } from '../api/v2/generated/types.gen'
import type { AgentItem } from '../api/agents'
import type { AIGatewayProviderKindItem } from '../state/provider-settings'
import type { ModelProfileWriteRequest } from '../state/model-profiles-model'
import { ErrorBlock } from '../../common/error-block'
import { ConfirmDeleteButton } from '../console-form'
import {
  draftsFromEffective,
  layerOverrides,
  profileSource,
  resolvedProviderHosted,
  ModelProfilesModel,
  PROFILE_NAMES,
  type ModelProfileLayer,
  type ModelProfileSubmission,
  type ProfileName
} from '../state/model-profiles-model'
import { ModelProfileEditorCard, buildModelProfileWriteRequest } from './model-profile-editor-card'
import { OcrExistingScansDialog, ocrExistingScansQuestion, type UnreadScans } from './ocr-existing-scans-dialog'
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

type ModelProfileTarget = { agentUID: string } | { defaultsScope: 'tenant' | 'global' } | { systemUID: string }

function profileLayer(target: ModelProfileTarget): ModelProfileLayer {
  if ('agentUID' in target) return 'agent'
  if ('systemUID' in target) return 'system'
  return target.defaultsScope
}

/** Labels a card header with the layer that its effective value comes from. */
function profileSourceBadge(t: TFunction, source: ReturnType<typeof profileSource>) {
  switch (source.kind) {
    case 'own':
      return { label: t(`console.models.own_source_${source.layer}`), own: true }
    case 'fallback':
      return {
        label: t('console.models.fallback_badge', { profile: modelProfileLabel(t, source.profile) }),
        own: false
      }
    case 'inherited':
      return {
        label:
          source.source === 'default'
            ? t('console.models.source_default')
            : t('console.models.inherited_badge', { source: t(`console.models.source_${source.source}`) }),
        own: false
      }
    case 'none':
      return undefined
  }
}

async function deleteProfileOverride(target: ModelProfileTarget, profile: ProfileName) {
  if ('agentUID' in target) {
    return (await deleteAgentModelProfile({ path: { agent_uid: target.agentUID, profile }, throwOnError: true })).data
  }
  if ('systemUID' in target) {
    return (await deleteSystemModelProfile({ path: { uid: target.systemUID, profile }, throwOnError: true })).data
  }
  return (
    await deleteDefaultModelProfile({
      path: { profile },
      query: { defaults_scope: target.defaultsScope },
      throwOnError: true
    })
  ).data
}

/**
 * Removes every override that one layer stores, so each slot follows the
 * next layer again. The slots clear one by one; when a call fails, the slots
 * cleared before it stay cleared, the page refreshes, and the operator can
 * run it again for the rest.
 */
export function RestoreAllInheritanceButton({
  configuration,
  model,
  target
}: {
  configuration: ListAgentModelProfilesResponse | undefined
  model: InstanceType<typeof ModelProfilesModel>
  target: ModelProfileTarget
}) {
  useSignals()
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const layer = profileLayer(target)
  const overrides = layerOverrides(configuration)
  const count = overrides.profiles.length + overrides.hosted.length
  const restore = useMutation({
    mutationFn: async () => {
      const submissions = overrides.profiles.map(profile => [profile, model.submission(profile)] as const)
      let latest: ListAgentModelProfilesResponse | undefined
      for (const [profile] of submissions) latest = await deleteProfileOverride(target, profile)
      if (overrides.hosted.length > 0) {
        const reset = Object.fromEntries(overrides.hosted.map(capability => [capability, null]))
        if ('agentUID' in target) {
          await putAgentProviderHosted({
            path: { agent_uid: target.agentUID },
            body: { data: reset },
            throwOnError: true
          })
        } else if ('defaultsScope' in target) {
          await putDefaultProviderHosted({
            body: { data: { defaults_scope: target.defaultsScope, ...reset } },
            throwOnError: true
          })
        }
      }
      return { latest, submissions }
    },
    onSuccess: ({ latest, submissions }) => {
      if (latest) {
        for (const [profile, submission] of submissions) model.markSaved(profile, latest.effective, submission)
      }
      toast.success(t('console.models.restore_all_done', { count }))
    },
    onError: () => void queryClient.invalidateQueries()
  })

  return (
    <div className="grid justify-items-start gap-2">
      <ErrorBlock error={restore.error} />
      <ConfirmDeleteButton
        confirm={{
          title: t('console.models.restore_all_title'),
          description: t(`console.models.restore_all_description_${layer}`, { count }),
          confirmLabel: t('console.models.restore_all')
        }}
        label={count > 0 ? t('console.models.restore_all_count', { count }) : t('console.models.restore_all')}
        pending={restore.isPending || count === 0}
        size="sm"
        variant="outline"
        onConfirm={() => restore.mutate()}
      />
    </div>
  )
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
  /** Card headers name models from the catalog, so the cards wait for it rather than show raw model IDs first. */
  modelCatalogPending: boolean
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
  modelCatalog,
  modelCatalogPending
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
      {configuration ? (
        <RestoreAllInheritanceButton configuration={configuration} model={model} target={{ agentUID: agent.uid }} />
      ) : null}
      {draftStatus === 'loading' || modelCatalogPending ? (
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
  target: ModelProfileTarget
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
  const draft = signals.draft.value
  const hasOverride = Object.hasOwn(configuration.overrides, profile)
  const [existingScans, setExistingScans] = useState<{ unread: UnreadScans | undefined } | null>(null)
  const persist = useMutation({
    mutationFn: async (input: ProfilePersistence) => {
      if (input.action === 'cleared') return deleteProfileOverride(target, profile)

      if ('agentUID' in target) {
        const path = { agent_uid: target.agentUID, profile }
        const response = await putAgentModelProfile({ path, body: { data: { attrs: input.body } }, throwOnError: true })
        return response.data
      }

      if ('systemUID' in target) {
        const path = { uid: target.systemUID, profile }
        const response = await putSystemModelProfile({
          path,
          body: { data: { attrs: input.body } },
          throwOnError: true
        })
        return response.data
      }

      const response = await putDefaultModelProfile({
        path: { profile },
        body: { data: { defaults_scope: target.defaultsScope, attrs: input.body } },
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
    // OCR costs money for every page, so the scans uploaded before this model wait for an explicit answer.
    // Nothing is asked when reading them is already on, or when no scan is waiting and none is still being listed.
    if (profile === 'ocr' && input.action === 'saved' && 'defaultsScope' in target) {
      void ocrExistingScansQuestion(target.defaultsScope).then(
        question => {
          const waiting = !question.unread || question.unread.files > 0 || question.unread.counting
          if (!question.enabled && waiting) setExistingScans({ unread: question.unread })
        },
        () => undefined
      )
    }
  }
  const submit = () => {
    if (persist.isPending) return
    const built = buildModelProfileWriteRequest({
      profile,
      draft: model.snapshot(profile),
      providers,
      providerKinds,
      modelCatalog,
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
  const layer = profileLayer(target)
  // Site values are the base layer, so removing one clears the slot rather than restoring inheritance.
  const clearLabel = layer === 'global' ? t('common.clear') : t('console.models.restore_inheritance')
  const source = profileSource(layer, profile, hasOverride, configuration.effective[profile])
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
        source={profileSourceBadge(t, source)}
        saveNotice={layer !== 'global' && !hasOverride ? t('console.models.save_creates_override') : undefined}
        persistencePending={persist.isPending}
        providerHosted={providerHosted}
        deleteConfirm={{
          title: t('console.models.clear_title'),
          description: t(
            layer === 'global' ? 'console.models.clear_site_description' : 'console.models.clear_description',
            {
              profile: modelProfileLabel(t, profile)
            }
          ),
          confirmLabel: clearLabel
        }}
        deleteDisabled={!hasOverride}
        deleteLabel={clearLabel}
        providers={providers}
        providerKinds={providerKinds}
        modelCatalog={modelCatalog}
        onUpdate={patch => model.update(profile, patch)}
        onSave={submit}
        onDelete={() =>
          persist.mutate({ action: 'cleared', submission: model.submission(profile) }, { onSuccess: finishPersistence })
        }
      />
      {'defaultsScope' in target ? (
        <OcrExistingScansDialog
          scope={target.defaultsScope}
          unread={existingScans?.unread}
          open={existingScans !== null}
          onOpenChange={open => {
            if (!open) setExistingScans(null)
          }}
        />
      ) : null}
    </div>
  )
}
