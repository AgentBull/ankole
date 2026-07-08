import { recordValue, type JsonObject } from '@pleisto/active-support'
import {
  Badge,
  Button,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  toast
} from '@ankole/uikit'
import { RiSave3Line } from '@remixicon/react'
import { useMutation } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebAiGatewayProviderControllerDeleteModelProfileMutation,
  ankoleWebAiGatewayProviderControllerPutModelProfileMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { AgentItem, AiGatewayProviderItem } from '../api/generated/types.gen'
import { ErrorBlock, formatJson, parseObjectDraft } from '../console-primitives'
import { JsonField, LabeledField } from '../console-shell'

const PROFILE_NAMES = ['primary', 'light', 'heavy', 'embedding', 'rerank'] as const
const REQUIRED_PROFILES = new Set<string>(['primary', 'light', 'heavy'])

type ProfileDraft = {
  providerId: string
  model: string
  contextLength: string
  providerOptions: string
  error?: string
}

export function ModelProfilesEditor({
  agent,
  error,
  loading,
  onChanged,
  profiles,
  providers
}: {
  agent: AgentItem
  error: unknown
  loading: boolean
  onChanged: () => void
  profiles: JsonObject
  providers: AiGatewayProviderItem[]
}) {
  const { t } = useTranslation()
  const [drafts, setDrafts] = useState<Record<string, ProfileDraft>>({})
  const saveProfile = useMutation({
    ...ankoleWebAiGatewayProviderControllerPutModelProfileMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.models.saved', { profile: variables.path.profile }))
      onChanged()
    }
  })
  const clearProfile = useMutation({
    ...ankoleWebAiGatewayProviderControllerDeleteModelProfileMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.models.cleared', { profile: variables.path.profile }))
      onChanged()
    }
  })

  useEffect(() => {
    setDrafts(
      Object.fromEntries(
        PROFILE_NAMES.map(profile => [profile, draftFromProfile(recordValue(profiles[profile]) ?? {})])
      )
    )
  }, [agent.uid, profiles])

  const updateDraft = (profile: string, patch: Partial<ProfileDraft>) => {
    setDrafts(current => ({ ...current, [profile]: { ...(current[profile] ?? emptyProfileDraft()), ...patch } }))
  }

  const submit = (profile: string) => {
    const draft = drafts[profile] ?? emptyProfileDraft()
    const parsedOptions = parseObjectDraft(draft.providerOptions, 'provider_options')
    if (!parsedOptions.ok) {
      updateDraft(profile, { error: parsedOptions.error })
      return
    }
    const contextLength = draft.contextLength.trim() ? Number.parseInt(draft.contextLength, 10) : undefined
    saveProfile.mutate({
      body: {
        provider_id: draft.providerId,
        model: draft.model,
        context_length: Number.isFinite(contextLength) ? contextLength : undefined,
        provider_options: parsedOptions.value
      },
      path: { agent_uid: agent.uid, profile }
    })
  }

  return (
    <section className="grid gap-4">
      <div className="grid gap-1">
        <h3 className="text-lg font-semibold tracking-normal">{t('console.models.title')}</h3>
        <p className="text-sm leading-6 text-muted-foreground">{t('console.models.description')}</p>
      </div>
      <ErrorBlock error={error ?? saveProfile.error ?? clearProfile.error} />
      {loading ? <span className="text-xs text-muted-foreground">{t('common.loading')}</span> : null}
      <div className="grid gap-4">
        {PROFILE_NAMES.map(profile => {
          const draft = drafts[profile] ?? emptyProfileDraft()
          const configured = Boolean(draft.providerId && draft.model)
          return (
            <div key={profile} className="grid gap-4 border border-border bg-card p-4">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex items-center gap-2">
                  <Badge variant={REQUIRED_PROFILES.has(profile) ? 'default' : 'outline'}>{profile}</Badge>
                  {REQUIRED_PROFILES.has(profile) ? (
                    <span className="text-xs text-muted-foreground">{t('console.models.required')}</span>
                  ) : null}
                </div>
                <div className="flex gap-2">
                  <Button disabled={saveProfile.isPending} size="xs" type="button" onClick={() => submit(profile)}>
                    <RiSave3Line data-icon="inline-start" />
                    {t('common.save')}
                  </Button>
                  <Button
                    disabled={REQUIRED_PROFILES.has(profile) || !configured || clearProfile.isPending}
                    size="xs"
                    type="button"
                    variant="ghost"
                    onClick={() => clearProfile.mutate({ path: { agent_uid: agent.uid, profile } })}>
                    {t('console.models.clear')}
                  </Button>
                </div>
              </div>
              {draft.error ? <ErrorBlock error={draft.error} /> : null}
              <div className="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_128px]">
                <LabeledField label={t('console.models.provider')}>
                  <Select
                    value={draft.providerId}
                    onValueChange={value => updateDraft(profile, { providerId: String(value) })}>
                    <SelectTrigger className="w-full">
                      <SelectValue placeholder={t('console.models.provider_placeholder')} />
                    </SelectTrigger>
                    <SelectContent>
                      {providers.map(provider => (
                        <SelectItem key={provider.provider_id} value={provider.provider_id}>
                          {provider.provider_id}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </LabeledField>
                <LabeledField label={t('console.models.model')}>
                  <Input
                    placeholder="gpt-5"
                    value={draft.model}
                    onChange={event => updateDraft(profile, { model: event.target.value })}
                  />
                </LabeledField>
                <LabeledField label={t('console.models.context')}>
                  <Input
                    inputMode="numeric"
                    value={draft.contextLength}
                    onChange={event => updateDraft(profile, { contextLength: event.target.value })}
                  />
                </LabeledField>
              </div>
              <JsonField
                label={t('console.models.provider_options')}
                minRows={3}
                value={draft.providerOptions}
                onChange={value => updateDraft(profile, { providerOptions: value })}
              />
            </div>
          )
        })}
      </div>
    </section>
  )
}

function emptyProfileDraft(): ProfileDraft {
  return {
    providerId: '',
    model: '',
    contextLength: '',
    providerOptions: '{}'
  }
}

function draftFromProfile(profile: JsonObject): ProfileDraft {
  return {
    providerId: asString(profile.provider_id),
    model: asString(profile.model),
    contextLength: profile.context_length ? String(profile.context_length) : '',
    providerOptions: formatJson(recordValue(profile.provider_options) ?? {})
  }
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : ''
}
