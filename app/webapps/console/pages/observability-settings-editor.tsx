import {
  Badge,
  Button,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Switch
} from '@ankole/uikit'
import { RiAddLine, RiDeleteBin6Line, RiEyeLine } from '@remixicon/react'
import { useTranslation } from 'react-i18next'
import type { AppConfigurationItem } from '../api/generated/types.gen'
import { EncryptedValueInput } from '../encrypted-value-input'
import {
  OBSERVABILITY_TRACE_KEYS,
  OBSERVABILITY_TRACE_PROVIDERS,
  observabilityTraceDraft,
  type ObservabilityHeaderRow
} from '../state/observability-setting-editor'
import { SettingGroupField } from './setting-group-field'

export function ObservabilitySettingsEditor({
  drafts,
  headerRows,
  headerRevealing,
  items,
  onDraftChange,
  onHeaderRowsChange,
  onReplaceHeaders,
  onRestore,
  onRevealHeaders,
  saving
}: {
  drafts: Record<string, string>
  headerRows: ObservabilityHeaderRow[] | undefined
  headerRevealing: boolean
  items: AppConfigurationItem[]
  onDraftChange: (key: string, value: string) => void
  onHeaderRowsChange: (rows: ObservabilityHeaderRow[]) => void
  onReplaceHeaders: () => void
  onRestore: (item: AppConfigurationItem) => void
  onRevealHeaders: () => void
  saving: boolean
}) {
  const { t } = useTranslation()
  const draft = observabilityTraceDraft(drafts)
  const itemsByKey = new Map(items.map(item => [item.key, item]))
  const headers = itemsByKey.get(OBSERVABILITY_TRACE_KEYS.headers)

  return (
    <div className="grid gap-7">
      <p className="border border-warning/50 bg-warning/5 px-4 py-3 text-xs leading-5 text-muted-foreground">
        {t('console.settings.observability_restart_hint')}
      </p>

      <SettingGroupField
        item={itemsByKey.get(OBSERVABILITY_TRACE_KEYS.enabled)}
        label={t('console.settings.observability_enabled')}
        description={t('console.settings.observability_enabled_hint')}
        saving={saving}
        onRestore={onRestore}>
        <div className="flex min-h-12 items-center justify-between border border-border bg-muted/30 px-4 py-3">
          <span className="text-sm text-foreground">
            {draft.enabled ? t('console.status.enabled') : t('console.status.disabled')}
          </span>
          <Switch
            aria-label={t('console.settings.observability_enabled')}
            checked={draft.enabled}
            onCheckedChange={enabled => onDraftChange(OBSERVABILITY_TRACE_KEYS.enabled, String(enabled))}
          />
        </div>
      </SettingGroupField>

      <SettingGroupField
        item={itemsByKey.get(OBSERVABILITY_TRACE_KEYS.provider)}
        label={t('console.settings.observability_provider')}
        description={t('console.settings.observability_provider_hint')}
        saving={saving}
        onRestore={onRestore}>
        <Select
          value={draft.provider || null}
          onValueChange={provider =>
            provider && onDraftChange(OBSERVABILITY_TRACE_KEYS.provider, JSON.stringify(String(provider)))
          }>
          <SelectTrigger aria-label={t('console.settings.observability_provider')} className="w-full">
            <SelectValue placeholder={t('console.settings.observability_provider_placeholder')} />
          </SelectTrigger>
          <SelectContent>
            {OBSERVABILITY_TRACE_PROVIDERS.map(provider => (
              <SelectItem key={provider} value={provider}>
                {t(`console.settings.observability_provider_${provider}`)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </SettingGroupField>

      <SettingGroupField
        item={itemsByKey.get(OBSERVABILITY_TRACE_KEYS.endpoint)}
        label={t('console.settings.observability_endpoint')}
        description={t('console.settings.observability_endpoint_hint')}
        saving={saving}
        onRestore={onRestore}>
        <Input
          aria-label={t('console.settings.observability_endpoint')}
          required={draft.enabled}
          spellCheck={false}
          type="url"
          value={draft.endpoint}
          placeholder={endpointPlaceholder(draft.provider)}
          onChange={event => onDraftChange(OBSERVABILITY_TRACE_KEYS.endpoint, JSON.stringify(event.target.value))}
        />
      </SettingGroupField>

      <SettingGroupField
        item={headers}
        label={t('console.settings.observability_headers')}
        description={t(`console.settings.observability_headers_hint_${draft.provider || 'opentelemetry'}`)}
        saving={saving}
        onRestore={onRestore}>
        {headerRows ? (
          <div className="grid gap-3">
            {headerRows.length === 0 ? (
              <p className="border border-dashed border-border px-4 py-5 text-center text-sm text-muted-foreground">
                {t('console.settings.observability_headers_empty')}
              </p>
            ) : null}
            {headerRows.map((row, index) => (
              <div
                key={row.id}
                className="grid gap-2 border border-border bg-muted/20 p-3 sm:grid-cols-[1fr_1.4fr_auto]">
                <Input
                  aria-label={t('console.settings.observability_header_name', { number: index + 1 })}
                  className="font-mono text-xs"
                  placeholder={t('console.settings.observability_header_name_placeholder')}
                  required
                  spellCheck={false}
                  value={row.name}
                  onChange={event =>
                    onHeaderRowsChange(
                      headerRows.map(current =>
                        current.id === row.id ? { ...current, name: event.target.value } : current
                      )
                    )
                  }
                />
                <EncryptedValueInput
                  aria-label={t('console.settings.observability_header_value', { number: index + 1 })}
                  className="font-mono text-xs"
                  revealLabel={t('console.settings.reveal')}
                  revealed
                  value={row.value}
                  onChange={event =>
                    onHeaderRowsChange(
                      headerRows.map(current =>
                        current.id === row.id ? { ...current, value: event.target.value } : current
                      )
                    )
                  }
                />
                <Button
                  aria-label={t('console.settings.observability_remove_header', { number: index + 1 })}
                  size="icon-sm"
                  type="button"
                  variant="ghost"
                  onClick={() => onHeaderRowsChange(headerRows.filter(current => current.id !== row.id))}>
                  <RiDeleteBin6Line />
                </Button>
              </div>
            ))}
            <Button
              className="w-fit"
              size="sm"
              type="button"
              variant="outline"
              onClick={() => onHeaderRowsChange([...headerRows, newHeaderRow()])}>
              <RiAddLine />
              {t('console.settings.observability_add_header')}
            </Button>
          </div>
        ) : (
          <div className="flex flex-wrap items-center gap-2 border border-border bg-muted/20 px-4 py-4">
            <Badge variant="info">{t('console.status.encrypted')}</Badge>
            <span className="mr-auto text-xs leading-5 text-muted-foreground">
              {t('console.settings.observability_headers_masked')}
            </span>
            <Button disabled={headerRevealing} size="sm" type="button" variant="outline" onClick={onRevealHeaders}>
              <RiEyeLine />
              {t('console.settings.observability_reveal_headers')}
            </Button>
            <Button disabled={headerRevealing} size="sm" type="button" variant="ghost" onClick={onReplaceHeaders}>
              {t('console.settings.observability_replace_headers')}
            </Button>
          </div>
        )}
      </SettingGroupField>
    </div>
  )
}

let nextHeaderRowID = 0

function newHeaderRow(): ObservabilityHeaderRow {
  nextHeaderRowID += 1
  return { id: `new-${nextHeaderRowID}`, name: '', value: '' }
}

function endpointPlaceholder(provider: string): string {
  if (provider === 'langfuse') return 'https://cloud.langfuse.com/api/public/otel'
  if (provider === 'langsmith') return 'https://api.smith.langchain.com/otel'
  return 'https://collector.example.com'
}
