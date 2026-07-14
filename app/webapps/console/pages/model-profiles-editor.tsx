import { recordValue, type JsonObject as JSONObject } from '@pleisto/active-support'
import {
  Badge,
  Button,
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
  CreatableCombobox,
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
import { RiArrowDownSLine, RiSave3Line } from '@remixicon/react'
import { useMutation } from '@tanstack/react-query'
import { useEffect } from 'react'
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
  CodexAccountItem
} from '../api/generated/types.gen'
import { ErrorBlock } from '../console-primitives'
import { LabeledField } from '../console-shell'
import { ModelProfilesModel, PROFILE_NAMES, type ProfileDraft, type ProfileName } from '../state/model-profiles-model'
import {
  modelOptionsForProfile,
  modelProfileRequestFields,
  profileUsesConfigurableModel,
  providersForProfile
} from './model-profile-options'
import { ProviderSettingField } from './provider-setting-field'
import {
  buildSettingOptions,
  requestSettings,
  type ProviderSetting,
  type SettingValidationError
} from './provider-settings'

const REQUIRED_PROFILES = new Set<string>(['primary', 'light', 'heavy'])

export function ModelProfilesEditor({
  agent,
  error,
  loading,
  onChanged,
  profiles,
  providers,
  providerKinds,
  modelCatalog,
  codexAccounts
}: {
  agent: AgentItem
  error: unknown
  loading: boolean
  onChanged: () => void
  profiles: JSONObject
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: unknown
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

    const selectedProvider = providers.find(provider => provider.provider_id === draft.providerID)
    const selectedKind = providerKinds.find(kind => kind.provider_kind === selectedProvider?.provider_kind)
    if (!selectedProvider || !selectedKind) {
      updateDraft(profile, { error: t('console.models.provider_definition_unavailable') })
      return
    }

    const builtOptions = buildSettingOptions(requestSettings(selectedKind), draft.providerOptions, (field, reason) =>
      settingValidationMessage(t, field, reason)
    )
    if (!builtOptions.ok) {
      updateDraft(profile, { error: builtOptions.error })
      return
    }
    saveProfile.mutate({
      body: {
        provider_id: draft.providerID,
        ...modelProfileRequestFields(profile, draft),
        provider_options: builtOptions.value
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
          const draft = model.profiles[profile]
          const providerID = draft.providerID.value
          const selectedProvider = providers.find(provider => provider.provider_id === providerID)
          const selectedKind = providerKinds.find(kind => kind.provider_kind === selectedProvider?.provider_kind)
          const profileProviders = providersForProfile(providers, providerKinds, profile)
          const optionSettings = requestSettings(selectedKind)
          const basicOptionSettings = optionSettings.filter(setting => !setting.advanced)
          const advancedOptionSettings = optionSettings.filter(setting => setting.advanced)
          const configurableModel = profileUsesConfigurableModel(profile)
          const modelOptions = configurableModel ? modelOptionsForProfile(modelCatalog, providerID, profile) : []
          const configured = Boolean(
            draft.codexAccountID.value || (draft.providerID.value && (!configurableModel || draft.model.value))
          )
          const subscriptionCoding = profile === 'coding' && Boolean(draft.codexAccountID.value)
          const renderOptionSetting = (setting: ProviderSetting) => (
            <div key={setting.key} className={setting.type === 'map' ? 'md:col-span-2' : undefined}>
              <ProviderSettingField
                setting={setting}
                value={draft.providerOptions.value[setting.key]}
                onChange={value =>
                  updateDraft(profile, {
                    providerOptions: {
                      ...draft.providerOptions.value,
                      [setting.key]: value
                    },
                    error: undefined
                  })
                }
              />
            </div>
          )
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
              {draft.error.value ? <ErrorBlock error={draft.error.value} /> : null}
              {profile === 'coding' ? (
                <LabeledField
                  label={t('console.models.coding_runtime')}
                  description={t('console.models.coding_runtime_hint')}>
                  <Select
                    value={draft.codexAccountID.value || 'aigateway'}
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
                  <div
                    className={
                      configurableModel ? 'grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_128px]' : 'grid gap-4'
                    }>
                    <LabeledField label={t('console.models.provider')}>
                      <Select
                        value={draft.providerID.value}
                        onValueChange={value => {
                          const nextProviderID = String(value)
                          updateDraft(
                            profile,
                            nextProviderID === draft.providerID.value
                              ? { providerID: nextProviderID }
                              : {
                                  providerID: nextProviderID,
                                  ...(configurableModel ? { model: '', contextLength: '' } : {}),
                                  providerOptions: {},
                                  error: undefined
                                }
                          )
                        }}>
                        <SelectTrigger className="w-full">
                          <SelectValue placeholder={t('console.models.provider_placeholder')} />
                        </SelectTrigger>
                        <SelectContent>
                          {profileProviders.map(provider => (
                            <SelectItem key={provider.provider_id} value={provider.provider_id}>
                              {provider.provider_id}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </LabeledField>
                    {configurableModel ? (
                      <>
                        <LabeledField label={t('console.models.model')}>
                          <CreatableCombobox
                            options={modelOptions}
                            placeholder={t('console.models.model_placeholder')}
                            emptyLabel={t('console.models.model_empty')}
                            createLabel={value => t('console.models.model_use', { model: value })}
                            value={draft.model.value}
                            onValueChange={value => updateDraft(profile, { model: value, error: undefined })}
                          />
                        </LabeledField>
                        <LabeledField label={t('console.models.context')}>
                          <Input
                            inputMode="numeric"
                            value={draft.contextLength.value}
                            onChange={event => updateDraft(profile, { contextLength: event.target.value })}
                          />
                        </LabeledField>
                      </>
                    ) : null}
                  </div>
                  <div className="grid gap-3">
                    <h4 className="text-sm font-medium">{t('console.models.provider_options')}</h4>
                    {!providerID ? (
                      <p className="text-xs text-muted-foreground">{t('console.models.provider_options_select')}</p>
                    ) : !selectedKind ? (
                      <p className="text-xs text-muted-foreground">{t('common.loading')}</p>
                    ) : optionSettings.length === 0 ? (
                      <p className="text-xs text-muted-foreground">{t('console.models.provider_options_empty')}</p>
                    ) : (
                      <>
                        {basicOptionSettings.length > 0 ? (
                          <div className="grid gap-4 md:grid-cols-2">
                            {basicOptionSettings.map(renderOptionSetting)}
                          </div>
                        ) : null}
                        {advancedOptionSettings.length > 0 ? (
                          <Collapsible className="grid gap-4" defaultOpen={false}>
                            <CollapsibleTrigger className="flex w-full items-center justify-between gap-3 border border-border bg-muted/40 px-4 py-3 text-left text-sm font-medium">
                              <span>{t('common.advanced_settings')}</span>
                              <span className="flex items-center gap-2 text-xs text-muted-foreground">
                                {advancedOptionSettings.length}
                                <RiArrowDownSLine className="size-4" aria-hidden />
                              </span>
                            </CollapsibleTrigger>
                            <CollapsibleContent className="grid gap-4 md:grid-cols-2">
                              {advancedOptionSettings.map(renderOptionSetting)}
                            </CollapsibleContent>
                          </Collapsible>
                        ) : null}
                      </>
                    )}
                  </div>
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
    providerOptions: recordValue(profile.provider_options) ?? {}
  }
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function settingValidationMessage(t: TFunction, field: string, error: SettingValidationError): string {
  switch (error) {
    case 'required':
      return t('common.field_required', { field })
    case 'json_object':
      return t('common.must_be_json_object', { field })
    case 'integer':
      return t('common.must_be_integer', { field })
    case 'number':
      return t('common.must_be_number', { field })
    case 'selection':
      return t('common.must_be_valid_selection', { field })
  }
}
