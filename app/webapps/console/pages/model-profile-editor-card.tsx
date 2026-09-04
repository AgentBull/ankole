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
  Switch
} from '@ankole/uikit'
import { RiArrowDownSLine } from '@remixicon/react'
import type { TFunction } from 'i18next'
import { useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import type {
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem,
  ModelProfileWriteRequest
} from '../api/generated/types.gen'
import { ErrorBlock } from '../../common/error-block'
import { ConfirmDeleteButton, LabeledField, SaveButton } from '../console-form'
import type { ProfileDraft } from '../state/model-profiles-model'
import {
  modelOptionsForProfile,
  modelProfileRequestFields,
  profileUsesConfigurableModel,
  providersForProfile
} from './model-profile-options'
import { ProviderSettingField, providerSettingLabel } from './provider-setting-field'
import {
  buildSettingOptions,
  requestSettings,
  settingValidationMessage,
  type ProviderSetting
} from './provider-settings'

export function ModelProfileEditorCard({
  profile,
  label,
  draft,
  dirty,
  required,
  hint,
  nameField,
  saveIncomplete,
  showDescription,
  persistencePending,
  providerHosted,
  deleteConfirm,
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
  saveIncomplete?: boolean
  showDescription?: boolean
  persistencePending: boolean
  /**
   * When set, this capability can be left to the Agent's language-model
   * Provider. `replacesProfile` states whether the Provider then owns the
   * capability outright. In that case the profile is not used, so the form is
   * disabled rather than hidden: the operator can still see the configuration
   * they would return to. A switch that only prefers the Provider keeps the
   * profile editable, because the profile still runs whenever the Provider
   * cannot.
   */
  providerHosted?: {
    checked: boolean
    pending: boolean
    label: string
    description: string
    replacesProfile: boolean
    onChange: (checked: boolean) => void
  }
  /** When set, the delete action asks for confirmation before it fires. */
  deleteConfirm?: { title: string; description?: string; confirmLabel: string }
  deleteDisabled: boolean
  deleteLabel: string
  providers: AIGatewayProviderItem[]
  providerKinds: AIGatewayProviderKindItem[]
  modelCatalog: unknown
  onUpdate: (patch: Partial<ProfileDraft>) => void
  /** Omit inside a parent form that owns persistence for this card. */
  onSave?: () => void
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
  const hasCompatibleProvider = profileProviders.length > 0
  const selectedModelLabel = modelOptions.find(option => option.value === draft.model)?.label ?? draft.model
  const configured = Boolean(providerID && (!configurableModel || draft.model))
  const needsAttention =
    Boolean(draft.error) ||
    Boolean(dirty) ||
    (required && !configured) ||
    Boolean(showDescription && !draft.description.trim())
  const requiredConfigurationMissing = Boolean(required && !configured)
  const changedDraftIncomplete = Boolean(dirty && (!configured || (showDescription && !draft.description.trim())))
  const incomplete = Boolean(saveIncomplete || requiredConfigurationMissing || changedDraftIncomplete)
  const disableSave = persistencePending || (!dirty && !requiredConfigurationMissing)
  const hostedActive = providerHosted?.checked === true && providerHosted.replacesProfile
  // `undefined` means the operator never toggled the card, so it follows
  // `needsAttention`. A card needing attention stays open regardless — the
  // manual choice applies once the attention state clears.
  const [manualOpen, setManualOpen] = useState<boolean>()
  const open = needsAttention || (manualOpen ?? false)
  const providerError = draft.error && !providerID.trim() ? draft.error : undefined
  const modelError =
    draft.error && providerID.trim() && configurableModel && !draft.model.trim() ? draft.error : undefined
  const formError = draft.error && !providerError && !modelError ? draft.error : undefined

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

  const card = (
    <Collapsible className="border border-border bg-card" open={open} onOpenChange={setManualOpen}>
      <div className="flex min-w-0 flex-wrap items-center justify-between gap-2">
        <CollapsibleTrigger className="group flex min-w-0 flex-1 basis-64 items-center gap-3 px-4 py-3 text-left outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring">
          <Badge className="shrink-0" variant={required ? 'default' : 'outline'}>
            {label}
          </Badge>
          <span className="min-w-0 flex-1 truncate text-xs text-muted-foreground">
            {configured
              ? [providerID, configurableModel ? selectedModelLabel : null].filter(Boolean).join(' · ')
              : t('console.models.not_configured')}
          </span>
          {required ? (
            <span className="shrink-0 text-xs text-muted-foreground">{t('console.models.required')}</span>
          ) : null}
          {dirty ? <span className="shrink-0 text-xs text-muted-foreground">{t('console.models.unsaved')}</span> : null}
          <RiArrowDownSLine
            className="size-4 shrink-0 transition-transform group-aria-expanded:rotate-180"
            aria-hidden
          />
        </CollapsibleTrigger>
        <div className="flex shrink-0 items-center gap-2 pr-4">
          {providerHosted ? (
            <label className="flex items-center gap-2 text-xs text-muted-foreground">
              <Switch
                aria-label={providerHosted.label}
                checked={providerHosted.checked}
                disabled={providerHosted.pending}
                onCheckedChange={providerHosted.onChange}
              />
              {providerHosted.label}
            </label>
          ) : null}
          {onSave ? (
            <SaveButton
              disabled={disableSave || hostedActive}
              incomplete={incomplete && !disableSave}
              loading={persistencePending}
              size="xs"
              type="submit">
              {t('common.save')}
            </SaveButton>
          ) : null}
          {deleteConfirm ? (
            <ConfirmDeleteButton
              confirm={deleteConfirm}
              label={deleteLabel}
              pending={deleteDisabled || persistencePending || hostedActive}
              onConfirm={onDelete}
            />
          ) : (
            <Button
              disabled={deleteDisabled || persistencePending || hostedActive}
              size="xs"
              type="button"
              variant="ghost"
              onClick={onDelete}>
              {deleteLabel}
            </Button>
          )}
        </div>
      </div>
      <CollapsibleContent className="grid gap-4 border-t border-border px-4 py-4">
        {/* Only the profile fields freeze while the provider hosts the
                capability. The header switch and the collapse trigger must stay
                operable, or turning hosting on would lock its own off switch. */}
        <fieldset className="contents" disabled={hostedActive}>
          {providerHosted ? (
            <p className="text-xs leading-5 text-muted-foreground">{providerHosted.description}</p>
          ) : null}
          {hint ? <p className="text-pretty text-xs leading-5 text-muted-foreground">{hint}</p> : null}
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
          {formError ? <ErrorBlock error={formError} /> : null}
          <div
            className={configurableModel ? 'grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_9rem]' : 'grid gap-4'}>
            <LabeledField label={t('console.models.provider')} error={providerError} required>
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
                <SelectContent
                  emptyLabel={
                    providers.length === 0 ? t('console.models.provider_none') : t('console.models.provider_empty')
                  }>
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
                <LabeledField label={t('console.models.model')} error={modelError} required>
                  <CreatableCombobox
                    ariaLabel={t('console.models.model')}
                    clearLabel={t('common.clear')}
                    disabled={!providerID}
                    required
                    options={modelOptions}
                    placeholder={
                      providerID
                        ? t('console.models.model_placeholder')
                        : t('console.models.provider_required_placeholder')
                    }
                    emptyLabel={t('console.models.model_empty')}
                    createLabel={value => t('console.models.model_use', { model: value })}
                    triggerLabel={t('common.open')}
                    value={draft.model}
                    onValueChange={value => onUpdate({ model: value, error: undefined })}
                  />
                </LabeledField>
                <LabeledField label={t('console.models.context')}>
                  <Input
                    disabled={!providerID}
                    inputMode="numeric"
                    placeholder={providerID ? undefined : t('console.models.provider_required_placeholder')}
                    value={draft.contextLength}
                    onChange={event => onUpdate({ contextLength: event.target.value })}
                  />
                </LabeledField>
              </>
            ) : null}
          </div>
          <div className="grid gap-3">
            <h4 className="text-sm font-medium">{t('console.models.provider_options')}</h4>
            {!hasCompatibleProvider ? (
              <p className="text-xs text-muted-foreground">{t('console.models.provider_options_unavailable')}</p>
            ) : !providerID ? (
              <p className="text-xs text-muted-foreground">{t('console.models.provider_options_select')}</p>
            ) : !selectedKind ? (
              <p className="text-xs text-muted-foreground">{t('console.models.provider_options_kind_unavailable')}</p>
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
        </fieldset>
      </CollapsibleContent>
    </Collapsible>
  )

  if (!onSave) return card

  return (
    <form
      noValidate
      onSubmit={event => {
        event.preventDefault()
        onSave()
      }}>
      {card}
    </form>
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
  if (includeDescription && !draft.description.trim()) {
    return { ok: false, error: t('console.models.custom_profile_description_required') }
  }
  if (!draft.providerID.trim()) {
    return { ok: false, error: t('common.field_required', { field: t('console.models.provider') }) }
  }
  if (profileUsesConfigurableModel(profile) && !draft.model.trim()) {
    return { ok: false, error: t('common.field_required', { field: t('console.models.model') }) }
  }

  const requestFields = modelProfileRequestFields(profile, draft)
  if (!requestFields.ok) {
    return { ok: false, error: settingValidationMessage(t('console.models.context'), requestFields.error) }
  }

  const selectedProvider = providers.find(provider => provider.provider_id === draft.providerID)
  const selectedKind = providerKinds.find(kind => kind.provider_kind === selectedProvider?.provider_kind)
  if (!selectedProvider || !selectedKind) {
    return { ok: false, error: t('console.models.provider_definition_unavailable') }
  }

  const builtOptions = buildSettingOptions(
    requestSettings(selectedKind),
    draft.providerOptions,
    settingValidationMessage,
    key => providerSettingLabel(t, key)
  )
  if (!builtOptions.ok) return builtOptions

  return {
    ok: true,
    body: {
      provider_id: draft.providerID,
      ...requestFields.fields,
      ...(includeDescription ? { description: draft.description.trim() } : {}),
      provider_options: builtOptions.value
    }
  }
}
