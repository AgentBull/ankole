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
import { useMemo, useState, type ComponentType } from 'react'
import { useTranslation } from 'react-i18next'
import { availableLocaleIDs, nativeLocaleLabel } from '../../common/i18n'
import type { AppConfigurationItem } from '../api/configuration-types'
import { EncryptedValueInput } from '../encrypted-value-input'
import { JSONObjectField } from '../json-object-field'
import { JSONField, LabeledField } from '../console-form'
import {
  AI_GATEWAY_COMPACTION_FIELDS,
  aiGatewayCompactionDraft,
  serializeAIGatewayCompactionDraft,
  settingEditorKind,
  settingStringDraft,
  SETTING_DURATIONS,
  SETTING_DURATION_UNITS,
  settingDurationParts,
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
  required?: boolean
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

  if (kind === 'optionalTokens') return <OptionalTokensEditor {...props} />
  if (kind === 'duration') return <DurationSettingEditor {...props} />
  if (kind === 'limits') return <LimitsSettingEditor {...props} />
  if (SpecificEditor) return <SpecificEditor {...props} />
  if (kind === 'encrypted') return <EncryptedSettingEditor {...props} />
  if (kind === 'boolean') return <BooleanSettingEditor {...props} />
  if (kind === 'number') return <NumberSettingEditor {...props} />
  if (kind === 'string') return <StringSettingEditor {...props} />
  if (kind === 'object') return <ObjectSettingEditor {...props} />
  return <StructuredSettingEditor {...props} />
}

function OptionalTokensEditor({ value, onChange }: SettingValueEditorProps) {
  const { t } = useTranslation()
  const enabled = value !== 'null'
  return (
    <div className="grid gap-3">
      <label className="flex items-center gap-3">
        <Switch
          checked={enabled}
          onCheckedChange={next => onChange(next ? '' : 'null')}
          aria-label={t('console.settings.explicit_output_limit')}
        />
        {t(enabled ? 'console.settings.explicit_output_limit' : 'console.settings.no_explicit_limit')}
      </label>
      {enabled ? (
        <Input
          type="number"
          min={1}
          step={1}
          required
          value={value}
          aria-label={t('console.settings.output_tokens')}
          onChange={event => onChange(event.target.value)}
        />
      ) : null}
      <p className="text-xs text-muted-foreground">{t('console.settings.model_limits_still_apply')}</p>
    </div>
  )
}

function DurationSettingEditor({ item, value, onChange }: SettingValueEditorProps) {
  const { t } = useTranslation()
  const policy = SETTING_DURATIONS[item.key]!
  const units = SETTING_DURATION_UNITS
  const [unitID, setUnitID] = useState<string>(() => settingDurationParts(item.key, Number(value))?.unit ?? 'seconds')
  const unit = units.find(candidate => candidate.id === unitID)!
  const watchdog = item.key === 'ai_agent.inactivity_timeout_ms'
  const enabled = !watchdog || value !== '0'
  const numeric = value.trim() === '' ? '' : String((Number(value) * policy.seconds) / unit.seconds)
  return (
    <div className="grid gap-3">
      {watchdog ? (
        <label className="flex items-center gap-3">
          <Switch
            checked={enabled}
            onCheckedChange={next => onChange(next ? '' : '0')}
            aria-label={t('console.settings.enable_inactivity_timeout')}
          />
          {t(enabled ? 'console.settings.enable_inactivity_timeout' : 'console.settings.inactivity_timeout_disabled')}
        </label>
      ) : null}
      {enabled ? (
        <div className="flex flex-wrap items-center gap-2">
          <Input
            className="w-44"
            type="number"
            step="any"
            required
            min={(policy.min * policy.seconds) / unit.seconds}
            max={policy.max === undefined ? undefined : (policy.max * policy.seconds) / unit.seconds}
            value={numeric}
            aria-label={t('console.settings.duration')}
            onChange={event => {
              const next = event.target.value
              onChange(next === '' ? '' : String((Number(next) * unit.seconds) / policy.seconds))
            }}
          />
          <Select value={unitID} onValueChange={next => next && setUnitID(String(next))}>
            <SelectTrigger aria-label={t('console.settings.duration_unit')} className="w-40">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {units.map(candidate => (
                <SelectItem key={candidate.id} value={candidate.id}>
                  {t(`console.settings.unit_${candidate.id}`)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      ) : null}
      <p className="text-xs text-muted-foreground">
        {t('console.settings.stored_duration', {
          value: value || '—',
          unit:
            policy.seconds === 0.001
              ? t('console.settings.unit_milliseconds')
              : policy.seconds === 60
                ? t('console.settings.unit_minutes')
                : policy.seconds === 3600
                  ? t('console.settings.unit_hours')
                  : policy.seconds === 86400
                    ? t('console.settings.unit_days')
                    : t('console.settings.unit_seconds')
        })}
      </p>
      {['pod.trash_retention_days', 'brain.soft_delete_retention_hours'].includes(item.key) &&
      numeric !== '' &&
      Number(value) < Number(item.value) ? (
        <p role="status" className="text-sm text-warning-foreground">
          {t('console.settings.value_change', {
            current: item.value,
            next: Number(value),
            unit: t(policy.seconds === 86400 ? 'console.settings.unit_days' : 'console.settings.unit_hours')
          })}{' '}
          · {t('console.settings.retention_warning')}
        </p>
      ) : null}
    </div>
  )
}

function LimitsSettingEditor({ item, value, onChange }: SettingValueEditorProps) {
  const { t } = useTranslation()
  let draft: Record<string, unknown> = {}
  try {
    const parsed = JSON.parse(value)
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) draft = parsed
  } catch {
    /* The field keeps invalid drafts visible. */
  }
  const fields = Object.keys(item.value && typeof item.value === 'object' ? item.value : draft).sort((a, b) =>
    a === 'window_seconds' ? -1 : b === 'window_seconds' ? 1 : a.localeCompare(b)
  )
  return (
    <div className="grid gap-4">
      {fields.map(field => (
        <LabeledField key={field} label={t(`console.settings.limit_${field}`, { defaultValue: field })} required>
          {SETTING_DURATIONS[`${item.key}.${field}`] ? (
            <div data-setting-field={field}>
              <DurationSettingEditor
                item={{ ...item, key: `${item.key}.${field}`, value: draft[field] }}
                value={draft[field] == null ? '' : String(draft[field])}
                onChange={next => onChange(JSON.stringify({ ...draft, [field]: next === '' ? null : Number(next) }))}
              />
            </div>
          ) : (
            <Input
              data-setting-field={field}
              type="number"
              min={1}
              max={item.key.startsWith('authn.email.') ? 86400 : undefined}
              step={1}
              required
              value={typeof draft[field] === 'number' ? String(draft[field]) : ''}
              onChange={event =>
                onChange(
                  JSON.stringify({ ...draft, [field]: event.target.value === '' ? null : Number(event.target.value) })
                )
              }
            />
          )}
        </LabeledField>
      ))}
    </div>
  )
}

function EncryptedSettingEditor({ decrypt, onChange, value, required = true }: SettingValueEditorProps) {
  const { t } = useTranslation()
  // A pristine stored secret arrives as the mask sentinel in the draft itself;
  // rendering the draft verbatim keeps a cleared field visibly empty.
  return (
    <LabeledField
      htmlFor="app-configuration-value"
      label={t('console.settings.value')}
      description={t('console.settings.encrypted_value_hint')}
      required={required}>
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

function StringSettingEditor({ onChange, value, required = true }: SettingValueEditorProps) {
  const { t } = useTranslation()
  return (
    <LabeledField label={t('console.settings.value')} required={required}>
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
