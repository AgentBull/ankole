import { ConnectorConfigFields } from '../connector-config-fields'
import { TableRow, useQuery, Link } from '../tenant-context'
import { DirectoryAccessSection } from './directory-access'
import { Skeleton, SwitchRow, TableCell } from '@ankole/uikit'
import { recordValue } from '@agentbull/active-support'
import { ShieldKeyholeRegular } from '@ankole/uikit/icons'

import { useDeferredValue, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useParams } from '@tanstack/react-router'
import { type ConfigFieldDefinition, type LocalizedText, getPath, localizedText } from '../../common/config-fields'
import i18n from '../../common/i18n'
import {
  listIdentityProviderAdaptersOptions,
  listIdentityProvidersOptions
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { ListIdentityProviderAdaptersResponse, ListIdentityProvidersResponse } from '../api/v2/generated/types.gen'
import { EditorNotFound, LabeledField, ReadOnlyValue, ResourceEditorPage, StatusIndicator } from '../console-form'
import { ResourceListPage, ResourceSearch, RowViewAction } from '../console-list-page'
import { PodSettingsLinkBanner } from '../pod-settings-banner'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { IdentitySubNav } from './identity-mappings'

type IdentityProviderItem = ListIdentityProvidersResponse['identity_providers'][number]
type IdentityProviderAdapterItem = Omit<
  ListIdentityProviderAdaptersResponse['identity_provider_adapters'][number],
  'fields' | 'display_name'
> & { fields: ConfigFieldDefinition[]; display_name?: LocalizedText }

export function IdentityProvidersListPage() {
  const { t } = useTranslation()
  const providers = useQuery(listIdentityProvidersOptions())
  const adapters = useQuery(listIdentityProviderAdaptersOptions())
  const adapterByID = useMemo(
    () =>
      new Map(
        ((adapters.data?.identity_provider_adapters ?? []) as IdentityProviderAdapterItem[]).map(adapter => [
          adapter.adapter_id,
          adapter
        ])
      ),
    [adapters.data]
  )
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const locale = i18n.language
  const providerLabel = (provider: { adapter_id: string; display_name?: { [key: string]: unknown } | null }) =>
    localizedText(provider.display_name, locale) ??
    localizedText(adapterByID.get(provider.adapter_id)?.display_name, locale) ??
    provider.adapter_id
  const rows = (providers.data?.identity_providers ?? []).filter(provider =>
    matchesResourceSearch(
      searchQuery,
      provider.provider_id,
      provider.adapter_id,
      providerLabel(provider),
      provider.enabled ? t('console.status.enabled') : t('console.status.disabled'),
      syncEnabled(provider) ? t('console.status.contacts') : t('console.status.off')
    )
  )

  return (
    <ResourceListPage
      title={t('console.identity.title')}
      description={t('console.identity.description')}
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
      emptyIcon={<ShieldKeyholeRegular aria-hidden />}
      emptyDescription={t('console.identity.empty_description')}
      error={providers.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      subNav={
        <div className="grid gap-4">
          <IdentitySubNav />
          <PodSettingsLinkBanner section="providers" />
        </div>
      }
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
            <Link data-row-link className="text-fg-primary" to={encodeURIComponent(provider.provider_id)}>
              {provider.provider_id}
            </Link>
          </TableCell>
          <TableCell>{providerLabel(provider)}</TableCell>
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
          <RowViewAction
            label={t('common.view_details_for', { name: provider.provider_id })}
            to={encodeURIComponent(provider.provider_id)}
          />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function IdentityProviderEditorPage() {
  const { t } = useTranslation()
  const params = useParams({ strict: false })
  const providerID = params.providerID
  const locale = i18n.language

  const adapters = useQuery(listIdentityProviderAdaptersOptions())
  const providers = useQuery({
    ...listIdentityProvidersOptions(),
    refetchOnMount: 'always'
  })
  const identityAdapters = (adapters.data?.identity_provider_adapters ?? []) as IdentityProviderAdapterItem[]
  const selected = providerID
    ? providers.data?.identity_providers.find(provider => provider.provider_id === providerID)
    : undefined
  const selectedAdapter = selected
    ? identityAdapters.find(adapter => adapter.adapter_id === selected.adapter_id)
    : undefined

  if (!providerID || (providers.isSuccess && !providers.isFetching && !selected)) {
    return <EditorNotFound backTo="/identity" message={t('console.not_found.description')} />
  }

  const adapterDisplay = selectedAdapter
    ? (localizedText(selectedAdapter.display_name, locale) ?? selectedAdapter.adapter_id)
    : undefined

  return (
    <ResourceEditorPage
      readOnly
      fieldsDisabled
      title={providerID}
      description={t('console.identity.editor_description')}
      backTo="/identity"
      error={adapters.error ?? providers.error}
      contentWidth="wide"
      supplementary={
        selected && selectedAdapter?.capabilities.includes('directory_full_sync') ? (
          <DirectoryAccessSection key={selected.provider_id} providerID={selected.provider_id} />
        ) : undefined
      }>
      <PodSettingsLinkBanner section="providers" />
      <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
        <LabeledField label={t('console.identity.adapter')}>
          <ReadOnlyValue>
            {adapterDisplay ??
              (adapters.isPending || providers.isPending ? (
                <Skeleton className="h-4 w-40" />
              ) : (
                (selected?.adapter_id ?? '')
              ))}
          </ReadOnlyValue>
        </LabeledField>
        <LabeledField label={t('console.identity.provider_id')}>
          <ReadOnlyValue mono>{selected?.provider_id ?? providerID}</ReadOnlyValue>
        </LabeledField>
      </div>

      <SwitchRow
        rowClassName="flex items-center justify-between gap-4 border border-border-subtle bg-layer-03/30 p-4"
        label={
          <span className="grid gap-1">
            <span className="text-sm font-medium">{t('console.identity.enabled')}</span>
            <span className="text-xs text-fg-secondary">{t('console.identity.enabled_hint')}</span>
          </span>
        }
        labelFirst
        checked={selected?.enabled === true}
        disabled
        onCheckedChange={() => {}}
      />

      {selected && selectedAdapter ? (
        <ConnectorConfigFields
          pluginId={selectedAdapter.plugin_id ?? selectedAdapter.adapter_id}
          onConnectionChange={() => {}}
          config={recordValue(selected.config) ?? {}}
          fields={selectedAdapter.fields}
          locale={locale}
          onChange={() => {}}
          preservedSecretPaths={selected.stored_secret_paths}
          preservedSecretPlaceholder={t('common.secret_saved_placeholder')}
        />
      ) : null}
    </ResourceEditorPage>
  )
}

function syncEnabled(provider: IdentityProviderItem): boolean {
  return getPath(recordValue(provider.config) ?? {}, 'sync.contacts') !== false
}
