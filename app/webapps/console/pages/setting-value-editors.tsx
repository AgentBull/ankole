import {
  Badge,
  Checkbox,
  CreatableCombobox,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Switch
} from '@ankole/uikit'
import { RiRestartLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useDeferredValue, useMemo, useState, type ComponentType } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'
import { availableLocaleIDs, nativeLocaleLabel } from '../../common/i18n'
import {
  ankoleWebAgentControllerIndexOptions,
  ankoleWebControlPlanePluginControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { AppConfigurationItem, ControlPlanePluginItem } from '../api/generated/types.gen'
import { ErrorBlock } from '../console-primitives'
import { ENCRYPTED_VALUE_MASK, EncryptedValueInput } from '../encrypted-value-input'
import { JSONObjectField } from '../json-object-field'
import { JSONField, LabeledField, ResourceSearch } from '../console-shell'
import { localizedJSONText } from '../state/agent-library-capabilities'
import { matchesResourceSearch } from '../state/resource-search'
import {
  brainEmbeddingAgentOptions,
  brainEmbeddingDraft,
  pluginIDsFromDraft,
  pluginRestartRequired,
  serializeBrainEmbeddingDraft,
  settingEditorKind,
  settingStringDraft,
  togglePluginID,
  unknownPluginIDs,
  type BrainEmbeddingDraft,
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
  brainEmbedding: BrainEmbeddingEditor,
  plugins: PluginsEnabledIDsEditor,
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

function EncryptedSettingEditor({ decrypt, item, onChange, value }: SettingValueEditorProps) {
  const { t } = useTranslation()
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
        value={value || (item.present ? ENCRYPTED_VALUE_MASK : '')}
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
        <span className="text-sm text-foreground">{value === 'true' ? 'true' : 'false'}</span>
        <Switch checked={value === 'true'} onCheckedChange={checked => onChange(checked ? 'true' : 'false')} />
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

function BrainEmbeddingEditor({ onChange, value }: SettingValueEditorProps) {
  const { t } = useTranslation()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const options = brainEmbeddingAgentOptions(agents.data?.agents ?? [])
  const draft = brainEmbeddingDraft(value)
  const selected = options.find(option => option.uid === draft.modelAgentUID)
  const unavailableSelection = Boolean(agents.isSuccess && draft.modelAgentUID && !selected)
  const editableDraft = unavailableSelection ? { ...draft, modelAgentUID: '' } : draft
  const update = (patch: Partial<BrainEmbeddingDraft>) =>
    onChange(serializeBrainEmbeddingDraft({ ...editableDraft, ...patch }))

  return (
    <div className="grid gap-5">
      <LabeledField
        label={t('console.settings.brain_embedding_enabled')}
        description={t('console.settings.brain_embedding_enabled_hint')}>
        <div className="flex min-h-12 items-center justify-between border border-border bg-muted/30 px-4 py-3">
          <span className="text-sm text-foreground">
            {draft.enabled ? t('console.status.enabled') : t('console.status.disabled')}
          </span>
          <Switch checked={draft.enabled} onCheckedChange={enabled => update({ enabled })} />
        </div>
      </LabeledField>

      <LabeledField
        label={t('console.settings.brain_embedding_agent')}
        description={t('console.settings.brain_embedding_agent_hint')}
        required={draft.enabled}>
        <Select
          disabled={!draft.enabled || agents.isLoading || options.length === 0}
          value={draft.modelAgentUID}
          onValueChange={modelAgentUID => modelAgentUID && update({ modelAgentUID: String(modelAgentUID) })}>
          <SelectTrigger className="w-full">
            <SelectValue placeholder={t('console.settings.brain_embedding_agent_placeholder')}>
              {modelAgentUID => {
                const option = options.find(item => item.uid === modelAgentUID)
                return option?.displayName ? `${option.displayName} · ${option.uid}` : (option?.uid ?? modelAgentUID)
              }}
            </SelectValue>
          </SelectTrigger>
          <SelectContent>
            {options.map(option => (
              <SelectItem key={option.uid} value={option.uid}>
                <span className="grid min-w-0 gap-0.5">
                  <span>{option.displayName ? `${option.displayName} · ${option.uid}` : option.uid}</span>
                  <span className="font-mono text-xs text-muted-foreground">
                    {option.providerID} · {option.model}
                  </span>
                </span>
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <ErrorBlock error={agents.error} />
        {agents.isSuccess && options.length === 0 ? (
          <p className="border border-warning/50 bg-warning/5 px-4 py-3 text-xs leading-5 text-muted-foreground">
            {t('console.settings.brain_embedding_no_agents')}{' '}
            <Link className="text-foreground underline underline-offset-4" to="/agents">
              {t('console.settings.brain_embedding_open_agents')}
            </Link>
          </p>
        ) : null}
        {unavailableSelection ? (
          <p className="border border-warning/50 bg-warning/5 px-4 py-3 text-xs leading-5 text-muted-foreground">
            {t('console.settings.brain_embedding_unavailable_agent', { uid: draft.modelAgentUID })}
          </p>
        ) : null}
      </LabeledField>

      <LabeledField
        label={t('console.settings.brain_embedding_dimensions')}
        description={t('console.settings.brain_embedding_dimensions_hint')}
        required={draft.enabled}>
        <Input
          disabled={!draft.enabled}
          max={4_096}
          min={1}
          required={draft.enabled}
          step={1}
          type="number"
          value={draft.dimensions}
          onChange={event => update({ dimensions: event.target.value })}
        />
      </LabeledField>

      {selected ? (
        <div className="flex flex-wrap gap-2 border border-border bg-muted/20 px-4 py-3">
          <Badge variant="secondary">{selected.providerID}</Badge>
          <Badge variant="outline">{selected.model}</Badge>
        </div>
      ) : null}
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
          value={timeZone}
          options={options}
          placeholder={t('console.settings.timezone_placeholder')}
          emptyLabel={t('console.settings.timezone_empty')}
          createLabel={candidate => t('console.settings.timezone_use', { timezone: candidate })}
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

function PluginsEnabledIDsEditor({ onChange, value }: SettingValueEditorProps) {
  const { i18n, t } = useTranslation()
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const catalog = useQuery(ankoleWebControlPlanePluginControllerIndexOptions())
  const selectedIDs = pluginIDsFromDraft(value)
  const discoveredPlugins = catalog.data?.control_plane_plugins ?? []
  const filteredPlugins = discoveredPlugins.filter(plugin =>
    matchesResourceSearch(
      deferredQuery,
      plugin.id,
      localizedJSONText(plugin.display_name, i18n.language),
      localizedJSONText(plugin.description, i18n.language)
    )
  )
  const undiscoveredIDs = unknownPluginIDs(
    selectedIDs,
    discoveredPlugins.map(plugin => plugin.id)
  ).filter(id => matchesResourceSearch(deferredQuery, id, t('console.settings.plugin_not_discovered')))
  const update = (pluginID: string, selected: boolean) =>
    onChange(JSON.stringify(togglePluginID(selectedIDs, pluginID, selected), null, 2))

  return (
    <div className="grid gap-4">
      <div className="grid gap-1">
        <h3 className="text-sm font-semibold">{t('console.settings.plugins_title')}</h3>
        <p className="text-xs leading-5 text-muted-foreground">{t('console.settings.plugins_hint')}</p>
      </div>
      <ResourceSearch
        label={t('console.settings.plugin_search')}
        placeholder={t('console.settings.plugin_search_placeholder')}
        value={query}
        onChange={setQuery}
      />
      <ErrorBlock error={catalog.error} />
      <div className="grid gap-3 sm:grid-cols-2">
        {filteredPlugins.map(plugin => (
          <PluginChoiceCard
            key={plugin.id}
            plugin={plugin}
            selected={selectedIDs.includes(plugin.id)}
            onChange={selected => update(plugin.id, selected)}
          />
        ))}
        {undiscoveredIDs.map(pluginID => (
          <label
            key={pluginID}
            className="flex min-w-0 items-start gap-3 border border-warning/50 bg-warning/5 px-4 py-4">
            <Checkbox checked onCheckedChange={checked => update(pluginID, checked === true)} />
            <span className="grid min-w-0 flex-1 gap-2">
              <span className="break-all font-mono text-sm font-semibold">{pluginID}</span>
              <span className="text-xs leading-5 text-muted-foreground">
                {t('console.settings.plugin_not_discovered_hint')}
              </span>
              <Badge variant="warning">{t('console.settings.plugin_not_discovered')}</Badge>
            </span>
          </label>
        ))}
      </div>
      {!catalog.isLoading && filteredPlugins.length === 0 && undiscoveredIDs.length === 0 ? (
        <p className="border border-border bg-muted/20 px-4 py-6 text-center text-sm text-muted-foreground">
          {query ? t('console.empty.no_results_title') : t('console.settings.no_plugins')}
        </p>
      ) : null}
    </div>
  )
}

function PluginChoiceCard({
  onChange,
  plugin,
  selected
}: {
  onChange: (selected: boolean) => void
  plugin: ControlPlanePluginItem
  selected: boolean
}) {
  const { i18n, t } = useTranslation()
  const restartRequired = pluginRestartRequired(plugin.active, selected)
  return (
    <label className="flex min-w-0 items-start gap-3 border border-border/70 bg-card/60 px-4 py-4">
      <Checkbox checked={selected} onCheckedChange={checked => onChange(checked === true)} />
      <span className="grid min-w-0 flex-1 gap-2">
        <span className="break-words text-sm font-semibold leading-5">
          {localizedJSONText(plugin.display_name, i18n.language) || plugin.id}
        </span>
        <span className="break-all font-mono text-[11px] text-muted-foreground">{plugin.id}</span>
        {plugin.description ? (
          <span className="whitespace-pre-wrap break-words text-xs leading-5 text-muted-foreground">
            {localizedJSONText(plugin.description, i18n.language)}
          </span>
        ) : null}
        <span className="flex flex-wrap gap-1.5 pt-1">
          <Badge variant={plugin.active ? 'success' : 'outline'}>
            {plugin.active
              ? t('console.agent_library_capabilities.active_now')
              : t('console.agent_library_capabilities.inactive_now')}
          </Badge>
          <Badge variant={selected ? 'secondary' : 'outline'}>
            {selected
              ? t('console.agent_library_capabilities.enabled_next_start')
              : t('console.agent_library_capabilities.disabled_next_start')}
          </Badge>
          {restartRequired ? (
            <Badge variant="warning">
              <RiRestartLine aria-hidden />
              {t('console.agent_library_capabilities.restart_required')}
            </Badge>
          ) : null}
        </span>
      </span>
    </label>
  )
}
