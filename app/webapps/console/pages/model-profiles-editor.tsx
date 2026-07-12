import { recordValue, type JsonObject as JSONObject } from '@pleisto/active-support'
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
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { RiSave3Line } from '@remixicon/react'
import { useMutation } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebAgentControllerDeleteModelProfileMutation,
  ankoleWebAgentControllerPutModelProfileMutation
} from '../api/generated/@tanstack/react-query.gen'
import type {
  AgentItem,
  AiGatewayProviderItem as AIGatewayProviderItem,
  CodexAccountItem
} from '../api/generated/types.gen'
import { ErrorBlock, formatJSON, parseObjectDraft } from '../console-primitives'
import { JSONField, LabeledField } from '../console-shell'
import { ModelProfilesModel, PROFILE_NAMES, type ProfileDraft, type ProfileName } from '../state/model-profiles-model'

const REQUIRED_PROFILES = new Set<string>(['primary', 'light', 'heavy'])

export function ModelProfilesEditor({
  agent,
  error,
  loading,
  onChanged,
  profiles,
  providers,
  codexAccounts
}: {
  agent: AgentItem
  error: unknown
  loading: boolean
  onChanged: () => void
  profiles: JSONObject
  providers: AIGatewayProviderItem[]
  codexAccounts: CodexAccountItem[]
}) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(ModelProfilesModel)
  const saveProfile = useMutation({
    ...ankoleWebAgentControllerPutModelProfileMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.models.saved', { profile: variables.path.profile }))
      onChanged()
    }
  })
  const clearProfile = useMutation({
    ...ankoleWebAgentControllerDeleteModelProfileMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.models.cleared', { profile: variables.path.profile }))
      model.clear(variables.path.profile as ProfileName)
      onChanged()
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

  const submit = (profile: ProfileName) => {
    const draft = model.snapshot(profile)
    if (profile === 'coding' && draft.codexAccountID) {
      saveProfile.mutate({
        body: { codex_account_id: draft.codexAccountID },
        path: { agent_uid: agent.uid, profile }
      })
      return
    }

    const parsedOptions = parseObjectDraft(draft.providerOptions, 'provider_options')
    if (!parsedOptions.ok) {
      updateDraft(profile, { error: parsedOptions.error })
      return
    }
    const contextLength = draft.contextLength.trim() ? Number.parseInt(draft.contextLength, 10) : undefined
    saveProfile.mutate({
      body: {
        provider_id: draft.providerID,
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
          const draft = model.snapshot(profile)
          const configured = Boolean(draft.codexAccountID || (draft.providerID && draft.model))
          const subscriptionCoding = profile === 'coding' && Boolean(draft.codexAccountID)
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
              {profile === 'coding' ? (
                <LabeledField
                  label={t('console.models.coding_runtime')}
                  description={t('console.models.coding_runtime_hint')}>
                  <Select
                    value={draft.codexAccountID || 'aigateway'}
                    onValueChange={value =>
                      updateDraft(profile, {
                        codexAccountID: String(value) === 'aigateway' ? '' : String(value)
                      })
                    }>
                    <SelectTrigger className="w-full">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="aigateway">{t('console.models.aigateway')}</SelectItem>
                      {codexAccounts.map(account => (
                        <SelectItem key={account.account_id} value={account.account_id}>
                          {account.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </LabeledField>
              ) : null}
              {!subscriptionCoding ? (
                <>
                  <div className="grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_128px]">
                    <LabeledField label={t('console.models.provider')}>
                      <Select
                        value={draft.providerID}
                        onValueChange={value => updateDraft(profile, { providerID: String(value) })}>
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
                  <JSONField
                    label={t('console.models.provider_options')}
                    minRows={3}
                    value={draft.providerOptions}
                    onChange={value => updateDraft(profile, { providerOptions: value })}
                  />
                </>
              ) : null}
            </div>
          )
        })}
      </div>
    </section>
  )
}

function draftFromProfile(profile: JSONObject): ProfileDraft {
  return {
    codexAccountID: asString(profile.codex_account_id),
    providerID: asString(profile.provider_id),
    model: asString(profile.model),
    contextLength: profile.context_length ? String(profile.context_length) : '',
    providerOptions: formatJSON(recordValue(profile.provider_options) ?? {})
  }
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : ''
}
