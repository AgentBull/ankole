import { Input, Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import type { AiGatewayProviderItem as AIGatewayProviderItem } from '../api/generated/types.gen'
import { JSONField, LabeledField, SecretInput } from '../console-form'
import { encryptedOptionState, humanizeKey, settingDraftValue, type ProviderSetting } from './provider-settings'

const UNSET_BOOLEAN = '__unset__'
const UNSET_SELECT = '__unset_select__'

/** Renders one ProviderDSL setting using its projected type and storage metadata. */
export function ProviderSettingField({
  onChange,
  provider,
  setting,
  value
}: {
  onChange: (value: string) => void
  provider?: AIGatewayProviderItem
  setting: ProviderSetting
  value: unknown
}) {
  const { t } = useTranslation()
  const label = humanizeKey(setting.key)
  const draft = settingDraftValue(value)
  const defaultDraft = settingDraftValue(setting.default)

  if (setting.encrypted) {
    const state = encryptedOptionState(provider, setting.key)
    const description = state?.present
      ? t('console.providers.secret_keep', { masked: state.masked ?? '••••' })
      : t('console.providers.secret_hint')
    return (
      <LabeledField label={label} description={description} required={setting.required && !state?.present}>
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
        value={draft}
        onChange={onChange}
      />
    )
  }

  if (setting.type === 'boolean') {
    return (
      <LabeledField label={label} required={setting.required}>
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

  if (setting.type === 'select') {
    return (
      <LabeledField label={label} required={setting.required}>
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
    <LabeledField label={label} required={setting.required}>
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
