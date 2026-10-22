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
import { useMemo, type ComponentType } from 'react'
import { useTranslation } from 'react-i18next'
import { availableLocaleIDs, nativeLocaleLabel } from '../../common/i18n'
import type { AppConfigurationItem } from '../api/generated/types.gen'
import { EncryptedValueInput } from '../encrypted-value-input'
import { JSONObjectField } from '../json-object-field'
import { JSONField, LabeledField } from '../console-form'
import {
  AI_GATEWAY_COMPACTION_FIELDS,
  aiGatewayCompactionDraft,
  serializeAIGatewayCompactionDraft,
  settingEditorKind,
  settingStringDraft,
  type AIGatewayCompactionDraft,
  type SettingEditorKind
} from '../state/setting-value-editor'
import { timeZoneCurrentTime, timeZoneOptions } from '../state/timezone-editor'

export type SettingValueEditorProps = {
  decrypt?: {
    onReveal: () => void
    revealed: boolean
    revealing: boolean
  }
  error?: string
  item: AppConfigurationItem
  onChange: (value: string) => void
  value: string
}

const SPECIFIC_SETTING_EDITORS: Partial<Record<SettingEditorKind, ComponentType<SettingValueEditorProps>>> = {
  aiGatewayCompaction: AIGatewayCompactionEditor,
  timezone: SystemTimeZoneEditor,
  locale: SystemLocaleEditor
}

/** Exact-key editors win; the remaining values use the smallest faithful generic control. */
export function SettingValueEditor(props: SettingValueEditorProps) {
  const { item } = props
  const kind = settingEditorKind(item.key, item.encrypted, item.value)
  const SpecificEditor = SPECIFIC_SETTING_EDITORS[kind]

  if (SpecificEditor) return <SpecificEditor {...props} />
  if (kind === 'encrypted') return <EncryptedSettingEditor {...props} />
  if (kind === 'boolean') return <BooleanSettingEditor {...props} />
  if (kind === 'number') return <NumberSettingEditor {...props} />
  if (kind === 'string') return <StringSettingEditor {...props} />
  if (kind === 'object') return <ObjectSettingEditor {...props} />
  return <StructuredSettingEditor {...props} />
}

function EncryptedSettingEditor({ decrypt, onChange, value }: SettingValueEditorProps) {
  const { t } = useTranslation()
  // A pristine stored secret arrives as the mask sentinel in the draft itself;
  // rendering the draft verbatim keeps a cleared field visibly empty.
  return (
    <LabeledField
      htmlFor="app-configuration-value"
      label={t('console.settings.value')}
      description={t('console.settings.encrypted_value_hint')}
      required>
      <EncryptedValueInput
        id="app-configuration-value"
        className="font-mono"
        revealLabel={t('console.settings.reveal')}
        revealed={decrypt?.revealed ?? false}
        revealing={decrypt?.revealing ?? false}
        value={value}
        onChange={event => onChange(event.target.value)}
        onReveal={decrypt?.onReveal ?? (() => undefined)}
      />
    </LabeledField>
  )
}

function BooleanSettingEditor({ onChange, value }: SettingValueEditorProps) {
  const { t } = useTranslation()
  return (
    <LabeledField label={t('console.settings.value')}>
      <div className="flex min-h-12 items-center justify-between border border-border bg-muted/30 px-4 py-3">
        <span className="text-sm text-foreground">
          {value === 'true' ? t('common.boolean_true') : t('common.boolean_false')}
        </span>
        <Switch
          aria-label={t('console.settings.value')}
          checked={value === 'true'}
          onCheckedChange={checked => onChange(checked ? 'true' : 'false')}
        />
      </div>
    </LabeledField>
  )
}

function NumberSettingEditor({ onChange, value }: SettingValueEditorProps) {
  const { t } = useTranslation()
  return (
    <LabeledField label={t('console.settings.value')} required>
      <Input type="number" step="any" value={value} onChange={event => onChange(event.target.value)} />
    </LabeledField>
  )
}

function StringSettingEditor({ onChange, value }: SettingValueEditorProps) {
  const { t } = useTranslation()
  return (
    <LabeledField label={t('console.settings.value')} required>
      <Input value={settingStringDraft(value)} onChange={event => onChange(JSON.stringify(event.target.value))} />
    </LabeledField>
  )
}

function StructuredSettingEditor({ error, onChange, value }: SettingValueEditorProps) {
  const { t } = useTranslation()
  return <JSONField error={error} label={t('console.settings.value')} value={value} minRows={10} onChange={onChange} />
}

function ObjectSettingEditor({ error, item, onChange, value }: SettingValueEditorProps) {
  const { t } = useTranslation()
  return (
    <JSONObjectField
      error={error}
      label={t('console.settings.value')}
      name={item.key}
      value={value}
      onChange={onChange}
    />
  )
}

function AIGatewayCompactionEditor({ onChange, value }: SettingValueEditorProps) {
  const { t } = useTranslation()
  const draft = aiGatewayCompactionDraft(value)
  const update = (patch: Partial<AIGatewayCompactionDraft>) =>
    onChange(serializeAIGatewayCompactionDraft({ ...draft, ...patch }))

  return (
    <div className="grid gap-6">
      {AI_GATEWAY_COMPACTION_FIELDS.map(field => (
        <LabeledField
          key={field.key}
          label={t(`console.settings.compaction_field_${field.key}`)}
          description={t(`console.settings.compaction_field_${field.key}_hint`, {
            max: field.max.toLocaleString()
          })}>
          <Input
            max={field.max}
            min={field.min}
            step={field.step ?? 1}
            type="number"
            value={draft.numbers[field.key] ?? ''}
            onChange={event => update({ numbers: { ...draft.numbers, [field.key]: event.target.value } })}
          />
        </LabeledField>
      ))}

      <LabeledField
        label={t('console.settings.compaction_upstream')}
        description={t('console.settings.compaction_upstream_hint')}>
        <Switch checked={draft.upstream} onCheckedChange={checked => update({ upstream: checked === true })} />
      </LabeledField>
    </div>
  )
}

function SystemLocaleEditor({ onChange, value }: SettingValueEditorProps) {
  const { t } = useTranslation()
  const locale = settingStringDraft(value)
  const locales = [...new Set([...availableLocaleIDs(), locale].filter(Boolean))]

  return (
    <LabeledField label={t('console.settings.locale_title')} description={t('console.settings.locale_hint')} required>
      <Select value={locale} onValueChange={nextLocale => nextLocale && onChange(JSON.stringify(nextLocale))}>
        <SelectTrigger className="w-full">
          <SelectValue>{selected => nativeLocaleLabel(selected ?? locale)}</SelectValue>
        </SelectTrigger>
        <SelectContent>
          {locales.map(option => (
            <SelectItem key={option} value={option}>
              <span>{nativeLocaleLabel(option)}</span>
              <span className="font-mono text-xs text-muted-foreground">{option}</span>
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </LabeledField>
  )
}

function SystemTimeZoneEditor({ onChange, value }: SettingValueEditorProps) {
  const { i18n, t } = useTranslation()
  const timeZone = settingStringDraft(value)
  const options = useMemo(() => timeZoneOptions(i18n.language, timeZone), [i18n.language, timeZone])
  const currentTime = timeZoneCurrentTime(timeZone, i18n.language)

  return (
    <LabeledField
      label={t('console.settings.timezone_title')}
      description={t('console.settings.timezone_hint')}
      required>
      <div className="grid gap-3">
        <CreatableCombobox
          ariaLabel={t('console.settings.timezone_title')}
          clearLabel={t('common.clear')}
          value={timeZone}
          options={options}
          placeholder={t('console.settings.timezone_placeholder')}
          emptyLabel={t('console.settings.timezone_empty')}
          createLabel={candidate => t('console.settings.timezone_use', { timezone: candidate })}
          triggerLabel={t('common.open')}
          onValueChange={nextTimeZone => onChange(JSON.stringify(nextTimeZone))}
          required
        />
        {currentTime ? (
          <div className="grid gap-1 border border-border bg-muted/20 px-4 py-3">
            <span className="text-xs text-muted-foreground">{t('console.settings.timezone_current_time')}</span>
            <span className="font-mono text-sm tabular-nums">{currentTime}</span>
          </div>
        ) : null}
      </div>
    </LabeledField>
  )
}
