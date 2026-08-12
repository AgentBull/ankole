import {
  CreatableCombobox,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Switch
} from '@ankole/uikit'
import type { TFunction } from 'i18next'
import { useTranslation } from 'react-i18next'
import { JSONField, LabeledField, SecretInput } from '../console-form'
import { humanizeKey, settingDraftValue, type ProviderSetting } from './provider-settings'

const UNSET_BOOLEAN = '__unset__'
const UNSET_SELECT = '__unset_select__'
const UNSET_SERVICE_TIER = '__unset_service_tier__'

export function providerSettingPresentation(t: TFunction, key: string): { label: string; description?: string } {
  switch (key) {
    case 'reasoningEffort':
      return {
        label: t('console.providers.reasoning_effort'),
        description: t('console.providers.reasoning_effort_hint')
      }
    case 'reasoningSummary':
      return {
        label: t('console.providers.reasoning_summary'),
        description: t('console.providers.reasoning_summary_hint')
      }
    case 'serviceTier':
      return {
        label: t('console.providers.service_tier'),
        description: t('console.providers.service_tier_hint')
      }
    case 'textVerbosity':
      return {
        label: t('console.providers.text_verbosity'),
        description: t('console.providers.text_verbosity_hint')
      }
    case 'upstream_transport':
      return { label: 'WebSocket' }
    default:
      return { label: humanizeKey(key) }
  }
}

/** Renders one ProviderDSL setting using its projected type and storage metadata. */
export function ProviderSettingField({
  onChange,
  secretPresent,
  setting,
  value
}: {
  onChange: (value: string) => void
  secretPresent?: boolean
  setting: ProviderSetting
  value: unknown
}) {
  const { t } = useTranslation()
  const { label, description } = providerSettingPresentation(t, setting.key)
  const draft = settingDraftValue(value)
  const defaultDraft = settingDraftValue(setting.default)

  if (setting.encrypted) {
    const description = secretPresent
      ? t('console.providers.secret_keep', { masked: '••••' })
      : t('console.providers.secret_hint')
    return (
      <LabeledField label={label} description={description} required={setting.required && !secretPresent}>
        <SecretInput placeholder="sk-..." value={draft} onChange={event => onChange(event.target.value)} />
      </LabeledField>
    )
  }

  if (setting.type === 'map') {
    return (
      <JSONField
        label={label}
        description={t('console.providers.map_hint')}
        minRows={4}
        required={setting.required}
        value={draft}
        onChange={onChange}
      />
    )
  }

  if (setting.type === 'boolean') {
    return (
      <LabeledField label={label} description={description} required={setting.required}>
        <Select
          value={draft || UNSET_BOOLEAN}
          onValueChange={next => onChange(String(next) === UNSET_BOOLEAN ? '' : String(next))}>
          <SelectTrigger className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value={UNSET_BOOLEAN}>{t('common.unset')}</SelectItem>
            <SelectItem value="true">{t('common.boolean_true')}</SelectItem>
            <SelectItem value="false">{t('common.boolean_false')}</SelectItem>
          </SelectContent>
        </Select>
      </LabeledField>
    )
  }

  if (
    setting.key === 'upstream_transport' &&
    setting.type === 'select' &&
    setting.options.includes('sse') &&
    setting.options.includes('websocket')
  ) {
    const enabled = (draft || defaultDraft) === 'websocket'

    return (
      <LabeledField label={label} description={description} required={setting.required}>
        <div className="flex min-h-12 items-center justify-between border border-border bg-muted/30 px-4 py-3">
          <span className="text-sm text-foreground">{t('common.enable')}</span>
          <Switch
            aria-label={label}
            checked={enabled}
            onCheckedChange={checked => onChange(checked ? 'websocket' : 'sse')}
          />
        </div>
      </LabeledField>
    )
  }

  if (setting.key === 'serviceTier' && setting.type === 'string') {
    const options = [
      { value: UNSET_SERVICE_TIER, label: t('common.unset') },
      ...setting.options.map(option => ({ value: option }))
    ]

    return (
      <LabeledField label={label} description={description} required={setting.required}>
        <CreatableCombobox
          ariaLabel={label}
          clearLabel={t('common.clear')}
          value={draft}
          options={options}
          createLabel={tier => t('console.providers.service_tier_use', { tier })}
          triggerLabel={t('common.open')}
          onValueChange={next => onChange(next === UNSET_SERVICE_TIER ? '' : next)}
        />
      </LabeledField>
    )
  }

  if (setting.type === 'select') {
    return (
      <LabeledField label={label} description={description} required={setting.required}>
        <Select
          value={draft || defaultDraft || UNSET_SELECT}
          onValueChange={next => onChange(String(next) === UNSET_SELECT ? '' : String(next))}>
          <SelectTrigger className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value={UNSET_SELECT}>{t('common.unset')}</SelectItem>
            {setting.options.map(option => (
              <SelectItem key={option} value={option}>
                {option}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </LabeledField>
    )
  }

  const numeric = setting.type === 'integer' || setting.type === 'float'

  return (
    <LabeledField label={label} description={description} required={setting.required}>
      <Input
        type={numeric ? 'number' : 'text'}
        step={setting.type === 'integer' ? 1 : numeric ? 'any' : undefined}
        placeholder={setting.default != null ? String(setting.default) : undefined}
        value={draft}
        onChange={event => onChange(event.target.value)}
      />
    </LabeledField>
  )
}
