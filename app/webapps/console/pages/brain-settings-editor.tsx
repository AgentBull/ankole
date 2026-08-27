import {
  CronEditor,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Switch,
  Textarea,
  type CronEditorLabels
} from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import type { AppConfigurationItem } from '../api/generated/types.gen'
import {
  BRAIN_CHUNKING_FIELDS,
  BRAIN_CRON_KEYS,
  BRAIN_FORGETTING_FIELDS,
  BRAIN_KEYS,
  BRAIN_MAX_EMBEDDING_DIMENSIONS,
  BRAIN_MODEL_KEYS,
  BRAIN_SEARCH_TOKENIZERS,
  brainModelRequiresDimensions,
  brainNumberDraft,
  brainNumberMapDraft,
  brainNumberMapText,
  brainNumberText,
  brainStringDraft,
  type BrainModelDraft
} from '../state/brain-setting-editor'
import { settingDescription } from '../state/setting-description'
import { SettingGroupField } from './setting-group-field'

function cronEditorLabels(t: TFunction): CronEditorLabels {
  return {
    mode: t('common.cron_mode'),
    modes: {
      every_minutes: t('common.cron_mode_every_minutes'),
      hourly: t('common.cron_mode_hourly'),
      daily: t('common.cron_mode_daily'),
      weekly: t('common.cron_mode_weekly'),
      monthly: t('common.cron_mode_monthly'),
      custom: t('common.cron_mode_custom')
    },
    interval: t('common.cron_interval'),
    minute: t('common.cron_minute'),
    time: t('common.cron_time'),
    weekday: t('common.cron_weekday'),
    weekdays: [
      t('common.cron_weekday_sun'),
      t('common.cron_weekday_mon'),
      t('common.cron_weekday_tue'),
      t('common.cron_weekday_wed'),
      t('common.cron_weekday_thu'),
      t('common.cron_weekday_fri'),
      t('common.cron_weekday_sat')
    ],
    dayOfMonth: t('common.cron_day_of_month'),
    expression: t('common.cron_expression')
  }
}

export function BrainSettingsEditor({
  drafts,
  items,
  models,
  onDraftChange,
  onModelChange,
  onRestore,
  saving
}: {
  drafts: Record<string, string>
  items: AppConfigurationItem[]
  models: Record<string, BrainModelDraft>
  onDraftChange: (key: string, value: string) => void
  onModelChange: (key: string, draft: BrainModelDraft) => void
  onRestore: (item: AppConfigurationItem) => void
  saving: boolean
}) {
  const { t } = useTranslation()
  const itemsByKey = new Map(items.map(item => [item.key, item]))
  const cronLabels = cronEditorLabels(t)
  const enabled = drafts[BRAIN_KEYS.enabled] === 'true'
  const skillLearningEnabled = drafts[BRAIN_KEYS.skillLearningEnabled] === 'true'
  const tokenizer = brainStringDraft(drafts[BRAIN_KEYS.searchTokenizer])
  const chunking = brainNumberMapDraft(drafts[BRAIN_KEYS.chunking], BRAIN_CHUNKING_FIELDS)
  const forgetting = brainNumberMapDraft(drafts[BRAIN_KEYS.forgetting], BRAIN_FORGETTING_FIELDS)

  const field = (key: string, label: string, children: React.ReactNode) => {
    const item = itemsByKey.get(key)
    return (
      <SettingGroupField
        item={item}
        label={label}
        description={(item && settingDescription(t, item)) ?? ''}
        saving={saving}
        onRestore={onRestore}>
        {children}
      </SettingGroupField>
    )
  }

  return (
    <div className="grid gap-7">
      {field(
        BRAIN_KEYS.enabled,
        t('console.settings.brain_enabled'),
        <div className="flex min-h-12 items-center justify-between border border-border bg-muted/30 px-4 py-3">
          <span className="text-sm text-foreground">
            {enabled ? t('console.status.enabled') : t('console.status.disabled')}
          </span>
          <Switch
            aria-label={t('console.settings.brain_enabled')}
            checked={enabled}
            onCheckedChange={next => onDraftChange(BRAIN_KEYS.enabled, String(next))}
          />
        </div>
      )}

      {BRAIN_MODEL_KEYS.map(key =>
        models[key] ? (
          <BrainModelFieldGroup
            key={key}
            configurationKey={key}
            draft={models[key]}
            item={itemsByKey.get(key)}
            saving={saving}
            onChange={draft => onModelChange(key, draft)}
            onRestore={onRestore}
          />
        ) : null
      )}

      {field(
        BRAIN_KEYS.searchTokenizer,
        t('console.settings.brain_search_tokenizer'),
        <Select
          value={tokenizer}
          onValueChange={value =>
            typeof value === 'string' && value && onDraftChange(BRAIN_KEYS.searchTokenizer, JSON.stringify(value))
          }>
          <SelectTrigger aria-label={t('console.settings.brain_search_tokenizer')} className="w-full">
            <SelectValue>{value => t(`console.settings.brain_search_tokenizer_${String(value)}`)}</SelectValue>
          </SelectTrigger>
          <SelectContent>
            {BRAIN_SEARCH_TOKENIZERS.map(option => (
              <SelectItem key={option} value={option}>
                {t(`console.settings.brain_search_tokenizer_${option}`)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      )}

      {field(
        BRAIN_KEYS.chunking,
        t('console.settings.brain_chunking'),
        <NumberMapInputs
          fields={BRAIN_CHUNKING_FIELDS}
          labelPrefix="console.settings.brain_chunking_"
          values={chunking}
          onChange={values => onDraftChange(BRAIN_KEYS.chunking, brainNumberMapText(values))}
        />
      )}

      {field(
        BRAIN_KEYS.forgetting,
        t('console.settings.brain_forgetting'),
        <NumberMapInputs
          fields={BRAIN_FORGETTING_FIELDS}
          labelPrefix="console.settings.brain_forgetting_"
          values={forgetting}
          onChange={values => onDraftChange(BRAIN_KEYS.forgetting, brainNumberMapText(values))}
        />
      )}

      {BRAIN_CRON_KEYS.map(key =>
        field(
          key,
          t(
            key === BRAIN_KEYS.dreamingTaskCron
              ? 'console.settings.brain_dreaming_task_cron'
              : 'console.settings.brain_self_healing_task_cron'
          ),
          <CronEditor
            disabled={saving}
            labels={cronLabels}
            value={brainStringDraft(drafts[key])}
            onChange={expression => onDraftChange(key, JSON.stringify(expression))}
          />
        )
      )}

      {field(
        BRAIN_KEYS.signalChannelBatchIdleTime,
        t('console.settings.brain_signal_channel_batch_idle_time'),
        <Input
          aria-label={t('console.settings.brain_signal_channel_batch_idle_time')}
          min={1}
          type="number"
          value={brainNumberDraft(drafts[BRAIN_KEYS.signalChannelBatchIdleTime])}
          onChange={event => onDraftChange(BRAIN_KEYS.signalChannelBatchIdleTime, brainNumberText(event.target.value))}
        />
      )}

      {field(
        BRAIN_KEYS.skillLearningEnabled,
        t('console.settings.brain_skill_learning_enabled'),
        <div className="flex min-h-12 items-center justify-between border border-border bg-muted/30 px-4 py-3">
          <span className="text-sm text-foreground">
            {skillLearningEnabled ? t('console.status.enabled') : t('console.status.disabled')}
          </span>
          <Switch
            aria-label={t('console.settings.brain_skill_learning_enabled')}
            checked={skillLearningEnabled}
            onCheckedChange={next => onDraftChange(BRAIN_KEYS.skillLearningEnabled, String(next))}
          />
        </div>
      )}

      {field(
        BRAIN_KEYS.skillLearningReflectionThreshold,
        t('console.settings.brain_skill_learning_reflection_threshold'),
        <Input
          aria-label={t('console.settings.brain_skill_learning_reflection_threshold')}
          min={2}
          type="number"
          value={brainNumberDraft(drafts[BRAIN_KEYS.skillLearningReflectionThreshold])}
          onChange={event =>
            onDraftChange(BRAIN_KEYS.skillLearningReflectionThreshold, brainNumberText(event.target.value))
          }
        />
      )}
    </div>
  )
}

function BrainModelFieldGroup({
  configurationKey,
  draft,
  item,
  onChange,
  onRestore,
  saving
}: {
  configurationKey: string
  draft: BrainModelDraft
  item?: AppConfigurationItem
  onChange: (draft: BrainModelDraft) => void
  onRestore: (item: AppConfigurationItem) => void
  saving: boolean
}) {
  const { t } = useTranslation()
  const label = t(`console.settings.brain_${configurationKey.slice('brain.'.length)}`)
  const requiresDimensions = brainModelRequiresDimensions(configurationKey)

  return (
    <SettingGroupField
      item={item}
      label={label}
      description={(item && settingDescription(t, item)) ?? ''}
      saving={saving}
      onRestore={onRestore}>
      <div className="grid gap-3 border border-border bg-muted/20 p-4">
        <div className="flex min-h-8 items-center justify-between">
          <span className="text-sm text-foreground">
            {draft.configured ? t('console.settings.brain_model_configured') : t('console.settings.brain_model_off')}
          </span>
          <Switch
            aria-label={t('console.settings.brain_model_configured_toggle', { model: label })}
            checked={draft.configured}
            onCheckedChange={configured => onChange({ ...draft, configured })}
          />
        </div>

        {draft.configured ? (
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="grid gap-1.5 text-xs text-muted-foreground">
              {t('console.settings.brain_model_provider_id')}
              <Input
                required
                spellCheck={false}
                value={draft.providerID}
                onChange={event => onChange({ ...draft, providerID: event.target.value })}
              />
            </label>
            <label className="grid gap-1.5 text-xs text-muted-foreground">
              {t('console.settings.brain_model_name')}
              <Input
                required
                spellCheck={false}
                value={draft.model}
                onChange={event => onChange({ ...draft, model: event.target.value })}
              />
            </label>
            {requiresDimensions ? (
              <label className="grid gap-1.5 text-xs text-muted-foreground">
                {t('console.settings.brain_model_dimensions')}
                <Input
                  max={BRAIN_MAX_EMBEDDING_DIMENSIONS}
                  min={1}
                  required
                  type="number"
                  value={draft.dimensions}
                  onChange={event => onChange({ ...draft, dimensions: event.target.value })}
                />
              </label>
            ) : null}
            <label className="grid gap-1.5 text-xs text-muted-foreground sm:col-span-2">
              {t('console.settings.brain_model_provider_options')}
              <Textarea
                className="min-h-20 font-mono text-xs"
                placeholder="{}"
                spellCheck={false}
                value={draft.providerOptions}
                onChange={event => onChange({ ...draft, providerOptions: event.target.value })}
              />
            </label>
          </div>
        ) : null}
      </div>
    </SettingGroupField>
  )
}

function NumberMapInputs({
  fields,
  labelPrefix,
  onChange,
  values
}: {
  fields: readonly string[]
  labelPrefix: string
  onChange: (values: Record<string, string>) => void
  values: Record<string, string>
}) {
  const { t } = useTranslation()

  return (
    <div className="grid gap-3 sm:grid-cols-2">
      {fields.map(field => (
        <label key={field} className="grid gap-1.5 text-xs text-muted-foreground">
          {t(`${labelPrefix}${field}`)}
          <Input
            min={0}
            required
            type="number"
            value={values[field] ?? ''}
            onChange={event => onChange({ ...values, [field]: event.target.value })}
          />
        </label>
      ))}
    </div>
  )
}
