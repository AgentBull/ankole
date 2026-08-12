import {
  Button,
  Checkbox,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { recordValue } from '@agentbull/active-support'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { RiRefreshLine, RiShieldKeyholeLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ConfigFields,
  defaultConfig,
  getPath,
  localizedText,
  setPath,
  type ConfigFieldDefinition,
  type LocalizedText
} from '../../common/config-fields'
import i18n from '../../common/i18n'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebIdentityProviderControllerAdaptersOptions,
  ankoleWebIdentityProviderControllerIndexOptions,
  ankoleWebIdentityProviderControllerPutProviderMutation,
  ankoleWebIdentityProviderControllerRunSyncMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { IdentityProviderAdapterItem, IdentityProviderItem } from '../api/generated/types.gen'
import { LabeledField, ReadOnlyValue, ResourceEditorPage, StatusIndicator } from '../console-form'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import { IdentityEditorModel, type IdentityEditorDraft } from '../state/identity-editor-model'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'

export function IdentityProvidersListPage() {
  const { t } = useTranslation()
  const providers = useQuery(ankoleWebIdentityProviderControllerIndexOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const rows = (providers.data?.identity_providers ?? []).filter(provider =>
    matchesResourceSearch(searchQuery, provider.provider_id, provider.adapter_id, provider.enabled)
  )

  return (
    <ResourceListPage
      title={t('console.identity.title')}
      description={t('console.identity.description')}
      createTo="new"
      createLabel={t('console.identity.new')}
      columns={[
        t('console.identity.provider'),
        t('console.identity.adapter'),
        t('console.identity.sync'),
        t('console.identity.state')
      ]}
      isLoading={providers.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t('console.identity.empty_title')}
      emptyIcon={<RiShieldKeyholeLine aria-hidden />}
      emptyDescription={t('console.identity.empty_description')}
      error={providers.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      toolbar={
        <ResourceSearch
          label={t('console.identity.search')}
          placeholder={t('console.identity.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {rows.map(provider => (
        <TableRow key={provider.provider_id}>
          <TableCell className="font-mono text-xs">
            <Link
              className="text-foreground hover:text-link hover:underline"
              to={encodeURIComponent(provider.provider_id)}>
              {provider.provider_id}
            </Link>
          </TableCell>
          <TableCell>{provider.adapter_id}</TableCell>
          <TableCell>
            <StatusIndicator tone={syncEnabled(provider) ? 'info' : 'neutral'}>
              {syncEnabled(provider) ? t('console.status.contacts') : t('console.status.off')}
            </StatusIndicator>
          </TableCell>
          <TableCell>
            <StatusIndicator tone={provider.enabled ? 'positive' : 'neutral'}>
              {provider.enabled ? t('console.status.enabled') : t('console.status.disabled')}
            </StatusIndicator>
          </TableCell>
          <RowActions editTo={encodeURIComponent(provider.provider_id)} editLabel={t('common.edit')} />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function IdentityProviderEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(IdentityEditorModel)
  const params = useParams()
  const providerID = params.providerID
  const mode = providerID ? 'edit' : 'new'
  const locale = i18n.language

  const adapters = useQuery(ankoleWebIdentityProviderControllerAdaptersOptions())
  const providers = useQuery(ankoleWebIdentityProviderControllerIndexOptions())
  const identityAdapters = adapters.data?.identity_provider_adapters ?? []
  const selected = providers.data?.identity_providers.find(provider => provider.provider_id === providerID)

  // The first-adapter fallback is a new-mode default only. In edit mode a
  // stored adapter missing from the catalog (its plugin was disabled) must
  // render as itself and block Save, not silently rewrite the provider to a
  // different adapter with the old adapter's config.
  const activeAdapter =
    identityAdapters.find(adapter => adapter.adapter_id === model.adapterID.value) ??
    (mode === 'new' ? identityAdapters[0] : undefined)
  const selectedAdapter = identityAdapters.find(adapter => adapter.adapter_id === selected?.adapter_id)

  const ready = identityAdapters.length > 0 && (mode === 'new' || Boolean(selected))
  useEffect(() => {
    if (!ready) return
    if (mode === 'edit' && selected) {
      model.initialize(`provider:${selected.provider_id}`, formFromProvider(selected))
    } else if (mode === 'new') {
      model.initialize('new', emptyForm(identityAdapters[0]))
    }
  }, [identityAdapters, mode, model, providerID, ready, selected])

  const refresh = () => void queryClient.invalidateQueries()
  const saveProvider = useMutation({
    ...ankoleWebIdentityProviderControllerPutProviderMutation(),
    onSuccess: response => {
      toast.success(t('console.identity.saved', { id: response.identity_provider.provider_id }))
      refresh()
      navigate('/identity')
    }
  })
  const runSync = useMutation({
    ...ankoleWebIdentityProviderControllerRunSyncMutation(),
    onSuccess: () => {
      toast.success(t('console.identity.sync_started'))
      refresh()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const changeAdapter = (adapterID: string) => {
    const adapter = identityAdapters.find(item => item.adapter_id === adapterID)
    if (adapter) model.changeAdapter(emptyForm(adapter))
  }

  const submit = () => {
    model.clearValidation()
    if (!activeAdapter) return
    const trimmedID = model.providerID.value.trim()
    if (!trimmedID) {
      model.validationError.value = t('console.identity.provider_id_required')
      return
    }
    saveProvider.mutate({
      body: { adapter_id: activeAdapter.adapter_id, config: model.config.value, enabled: model.enabled.value },
      path: { provider_id: trimmedID }
    })
  }

  const canRunSync = Boolean(
    mode === 'edit' &&
    selected &&
    selected.enabled &&
    selectedAdapter &&
    selectedAdapter.capabilities.includes('directory_full_sync') &&
    syncEnabled(selected)
  )
  const activeFields = asConfigFields(activeAdapter?.fields ?? [])
  const submitDisabled = mode === 'edit' && !model.dirty.value

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.identity.new') : (providerID ?? '')}
      description={t('console.identity.editor_description')}
      backTo="/identity"
      error={model.validationError.value ?? saveProvider.error ?? adapters.error ?? providers.error}
      submitting={saveProvider.isPending}
      submitDisabled={submitDisabled}
      submitUnavailable={!ready || !activeAdapter}
      contentWidth="wide"
      onSubmit={submit}
      secondary={
        canRunSync ? (
          <Button
            disabled={runSync.isPending}
            size="sm"
            type="button"
            variant="outline"
            onClick={() => selected && runSync.mutate({ path: { provider_id: selected.provider_id } })}>
            <RiRefreshLine data-icon="inline-start" />
            {t('console.identity.run_full_sync')}
          </Button>
        ) : null
      }>
      <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
        <LabeledField label={t('console.identity.adapter')} required={mode === 'new'}>
          {mode === 'edit' ? (
            <ReadOnlyValue>
              {activeAdapter
                ? localizedUnknown(activeAdapter.display_name, locale, activeAdapter.adapter_id)
                : model.adapterID.value}
            </ReadOnlyValue>
          ) : (
            <Select
              value={model.adapterID.value || activeAdapter?.adapter_id || ''}
              onValueChange={value => changeAdapter(String(value))}>
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent emptyLabel={t('common.select_empty')}>
                {identityAdapters.map(adapter => (
                  <SelectItem key={adapter.adapter_id} value={adapter.adapter_id}>
                    {localizedUnknown(adapter.display_name, locale, adapter.adapter_id)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </LabeledField>
        <LabeledField
          label={t('console.identity.provider_id')}
          description={t('console.identity.provider_id_hint')}
          required={mode === 'new'}>
          {mode === 'edit' ? (
            <ReadOnlyValue mono>{model.providerID.value}</ReadOnlyValue>
          ) : (
            <Input
              required
              value={model.providerID.value}
              onChange={event => (model.providerID.value = event.target.value)}
            />
          )}
        </LabeledField>
      </div>

      <label className="flex items-center justify-between gap-4 border border-border bg-muted/30 p-4">
        <span className="grid gap-1">
          <span className="text-sm font-medium">{t('console.identity.enabled')}</span>
          <span className="text-xs text-muted-foreground">{t('console.identity.enabled_hint')}</span>
        </span>
        <Checkbox checked={model.enabled.value} onCheckedChange={checked => (model.enabled.value = checked === true)} />
      </label>

      {activeAdapter ? (
        <ConfigFields
          config={model.config.value}
          fields={activeFields}
          locale={locale}
          onChange={(path, value) => (model.config.value = setPath(model.config.value, path, value))}
          preservedSecretPaths={selected?.stored_secret_paths}
          preservedSecretPlaceholder={t('common.secret_saved_placeholder')}
        />
      ) : null}
    </ResourceEditorPage>
  )
}

function emptyForm(adapter?: IdentityProviderAdapterItem): IdentityEditorDraft {
  return {
    adapterID: adapter?.adapter_id ?? '',
    providerID: adapter?.default_provider_id ?? '',
    enabled: true,
    config: defaultConfig(asConfigFields(adapter?.fields ?? []))
  }
}

function formFromProvider(provider: IdentityProviderItem): IdentityEditorDraft {
  return {
    adapterID: provider.adapter_id,
    providerID: provider.provider_id,
    enabled: provider.enabled,
    config: recordValue(provider.config) ?? {}
  }
}

function asConfigFields(fields: readonly unknown[]): ConfigFieldDefinition[] {
  return fields.map(field => field as unknown as ConfigFieldDefinition)
}

function localizedUnknown(value: unknown, locale: string, fallback: string): string {
  return localizedText(value as LocalizedText, locale) ?? fallback
}

function syncEnabled(provider: IdentityProviderItem): boolean {
  return getPath(recordValue(provider.config) ?? {}, 'sync.contacts') !== false
}
