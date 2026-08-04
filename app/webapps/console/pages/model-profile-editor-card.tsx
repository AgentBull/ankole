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
  SelectValue
} from '@ankole/uikit'
import { RiArrowDownSLine, RiSave3Line } from '@remixicon/react'
import type { TFunction } from 'i18next'
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import type {
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem,
  ModelProfileWriteRequest
} from '../api/generated/types.gen'
import { ErrorBlock } from '../console-primitives'
import { LabeledField } from '../console-form'
import type { ProfileDraft } from '../state/model-profiles-model'
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

export function ModelProfileEditorCard({
  profile,
  label,
  draft,
  dirty,
  required,
  hint,
  nameField,
  showDescription,
  persistencePending,
  deleteDisabled,
  deleteLabel,
  providers,
  providerKinds,
  modelCatalog,
  onUpdate,
  onSave,
  onDelete
}: {
  profile: string
  label: string
  draft: ProfileDraft
  dirty?: boolean
  required?: boolean
  hint?: string
  nameField?: ReactNode
  showDescription?: boolean
  persistencePending: boolean
  deleteDisabled: boolean
  deleteLabel: string
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: unknown
  onUpdate: (patch: Partial<ProfileDraft>) => void
  onSave: () => void
  onDelete: () => void
}) {
  const { t } = useTranslation()
  const providerID = draft.providerID
  const selectedProvider = providers.find(provider => provider.provider_id === providerID)
  const selectedKind = providerKinds.find(kind => kind.provider_kind === selectedProvider?.provider_kind)
  const profileProviders = providersForProfile(providers, providerKinds, profile)
  const optionSettings = requestSettings(selectedKind)
  const basicOptionSettings = optionSettings.filter(setting => !setting.advanced)
  const advancedOptionSettings = optionSettings.filter(setting => setting.advanced)
  const configurableModel = profileUsesConfigurableModel(profile)
  const modelOptions = configurableModel ? modelOptionsForProfile(modelCatalog, providerID, profile) : []

  const renderOptionSetting = (setting: ProviderSetting) => (
    <div key={setting.key} className={setting.type === 'map' ? 'md:col-span-2' : undefined}>
      <ProviderSettingField
        setting={setting}
        value={draft.providerOptions[setting.key]}
        onChange={value =>
          onUpdate({
            providerOptions: { ...draft.providerOptions, [setting.key]: value },
            error: undefined
          })
        }
      />
    </div>
  )

  return (
    <div className="grid gap-4 border border-border bg-card p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Badge variant={required ? 'default' : 'outline'}>{label}</Badge>
          {required ? <span className="text-xs text-muted-foreground">{t('console.models.required')}</span> : null}
          {dirty ? <span className="text-xs text-muted-foreground">{t('console.models.unsaved')}</span> : null}
        </div>
        <div className="flex gap-2">
          <Button disabled={persistencePending} size="xs" type="button" onClick={onSave}>
            <RiSave3Line data-icon="inline-start" />
            {t('common.save')}
          </Button>
          <Button
            disabled={deleteDisabled || persistencePending}
            size="xs"
            type="button"
            variant="ghost"
            onClick={onDelete}>
            {deleteLabel}
          </Button>
        </div>
      </div>
      {hint ? <p className="text-xs leading-5 text-muted-foreground">{hint}</p> : null}
      {nameField}
      {showDescription ? (
        <LabeledField label={t('console.models.custom_profile_description')} required>
          <Input
            maxLength={200}
            value={draft.description}
            onChange={event => onUpdate({ description: event.target.value, error: undefined })}
          />
        </LabeledField>
      ) : null}
      {draft.error ? <ErrorBlock error={draft.error} /> : null}
      <div className={configurableModel ? 'grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_128px]' : 'grid gap-4'}>
        <LabeledField label={t('console.models.provider')}>
          <Select
            value={draft.providerID}
            onValueChange={value => {
              const nextProviderID = String(value)
              onUpdate(
                nextProviderID === draft.providerID
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
                value={draft.model}
                onValueChange={value => onUpdate({ model: value, error: undefined })}
              />
            </LabeledField>
            <LabeledField label={t('console.models.context')}>
              <Input
                inputMode="numeric"
                value={draft.contextLength}
                onChange={event => onUpdate({ contextLength: event.target.value })}
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
              <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
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
                <CollapsibleContent className="grid grid-cols-1 gap-4 md:grid-cols-2">
                  {advancedOptionSettings.map(renderOptionSetting)}
                </CollapsibleContent>
              </Collapsible>
            ) : null}
          </>
        )}
      </div>
    </div>
  )
}

export function buildModelProfileWriteRequest({
  profile,
  draft,
  providers,
  providerKinds,
  t,
  includeDescription = false
}: {
  profile: string
  draft: ProfileDraft
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  t: TFunction
  includeDescription?: boolean
}): { ok: true; body: ModelProfileWriteRequest } | { ok: false; error: string } {
  const selectedProvider = providers.find(provider => provider.provider_id === draft.providerID)
  const selectedKind = providerKinds.find(kind => kind.provider_kind === selectedProvider?.provider_kind)
  if (!selectedProvider || !selectedKind) {
    return { ok: false, error: t('console.models.provider_definition_unavailable') }
  }

  const builtOptions = buildSettingOptions(requestSettings(selectedKind), draft.providerOptions, (field, reason) =>
    settingValidationMessage(t, field, reason)
  )
  if (!builtOptions.ok) return builtOptions

  return {
    ok: true,
    body: {
      provider_id: draft.providerID,
      ...modelProfileRequestFields(profile, draft),
      ...(includeDescription ? { description: draft.description.trim() } : {}),
      provider_options: builtOptions.value
    }
  }
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
