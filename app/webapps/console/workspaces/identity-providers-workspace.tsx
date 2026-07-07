import {
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Checkbox,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow
} from '@ankole/uikit'
import { recordValue, type JsonObject } from '@pleisto/active-support'
import { RiAddLine, RiRefreshLine, RiSave3Line } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
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
import {
  ankoleWebIdentityProviderControllerAdaptersOptions,
  ankoleWebIdentityProviderControllerIndexOptions,
  ankoleWebIdentityProviderControllerPutProviderMutation,
  ankoleWebIdentityProviderControllerRunSyncMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { IdentityProviderAdapterItem, IdentityProviderItem } from '../api/generated/types.gen'
import { ErrorBlock, Field, ResourceTable, WorkspaceShell, useSelectFirst } from '../console-primitives'

type IdentityProviderDraft = {
  adapterId: string
  config: JsonObject
  enabled: boolean
  error?: string
  providerId: string
}

export function IdentityProvidersWorkspace() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const adapters = useQuery(ankoleWebIdentityProviderControllerAdaptersOptions())
  const providers = useQuery(ankoleWebIdentityProviderControllerIndexOptions())
  const identityAdapters = adapters.data?.data ?? []
  const identityProviders = providers.data?.data ?? []
  const [mode, setMode] = useState<'new' | 'edit'>('new')
  const [selectedId, setSelectedId] = useSelectFirst(
    identityProviders,
    provider => provider.provider_id,
    () => setMode('edit')
  )
  const selected = identityProviders.find(provider => provider.provider_id === selectedId)
  const [draft, setDraft] = useState<IdentityProviderDraft>(emptyIdentityProviderDraft(identityAdapters[0]))
  const activeAdapter =
    identityAdapters.find(adapter => adapter.adapter_id === draft.adapterId) ??
    identityAdapters.find(adapter => adapter.adapter_id === selected?.adapter_id) ??
    identityAdapters[0]
  const selectedAdapter = identityAdapters.find(adapter => adapter.adapter_id === selected?.adapter_id)
  const locale = i18n.language
  const refresh = () => void queryClient.invalidateQueries()
  const saveProvider = useMutation({
    ...ankoleWebIdentityProviderControllerPutProviderMutation(),
    onSuccess: response => {
      setMode('edit')
      setSelectedId(response.data.provider_id)
      refresh()
    }
  })
  const runSync = useMutation({ ...ankoleWebIdentityProviderControllerRunSyncMutation(), onSuccess: refresh })

  useEffect(() => {
    if (mode === 'edit' && selected) {
      setDraft(draftFromIdentityProvider(selected))
      return
    }

    if (mode === 'new' && identityAdapters[0]) setDraft(emptyIdentityProviderDraft(identityAdapters[0]))
  }, [mode, selected?.provider_id, identityAdapters])

  const save = () => {
    if (!activeAdapter) return

    const providerId = draft.providerId.trim()
    if (!providerId) {
      setDraft(current => ({ ...current, error: t('console.identity.provider_id_required') }))
      return
    }

    saveProvider.mutate({
      body: {
        adapter_id: activeAdapter.adapter_id,
        config: draft.config,
        enabled: draft.enabled
      },
      path: { provider_id: providerId }
    })
  }

  const canRunSync = Boolean(
    mode === 'edit' &&
    selected &&
    selected.enabled &&
    selectedAdapter &&
    identityProviderSupportsDirectoryFullSync(selectedAdapter) &&
    identityProviderSyncEnabled(selected)
  )

  return (
    <WorkspaceShell
      title={t('console.identity.title')}
      action={
        <Button
          size="sm"
          type="button"
          variant="outline"
          onClick={() => {
            setMode('new')
            setSelectedId(null)
          }}>
          <RiAddLine data-icon="inline-start" />
          {t('common.new')}
        </Button>
      }>
      <div className="grid gap-4 xl:grid-cols-[minmax(0,0.95fr)_minmax(420px,1.05fr)]">
        <div className="min-w-0">
          <ErrorBlock error={providers.error ?? adapters.error} />
          <ResourceTable
            columns={[
              t('console.identity.provider'),
              t('console.identity.adapter'),
              t('console.identity.sync'),
              t('console.identity.state')
            ]}
            empty={!providers.isLoading && identityProviders.length === 0}
            loading={providers.isLoading || adapters.isLoading}>
            {identityProviders.map(provider => (
              <TableRow
                key={provider.provider_id}
                data-state={provider.provider_id === selected?.provider_id ? 'selected' : undefined}
                className="cursor-pointer"
                onClick={() => {
                  setMode('edit')
                  setSelectedId(provider.provider_id)
                }}>
                <TableCell className="font-mono text-xs">{provider.provider_id}</TableCell>
                <TableCell>{provider.adapter_id}</TableCell>
                <TableCell>
                  <Badge variant={identityProviderSyncEnabled(provider) ? 'default' : 'outline'}>
                    {identityProviderSyncEnabled(provider) ? t('console.status.contacts') : t('console.status.off')}
                  </Badge>
                </TableCell>
                <TableCell>
                  <Badge variant={provider.enabled ? 'default' : 'secondary'}>
                    {provider.enabled ? t('console.status.enabled') : t('console.status.disabled')}
                  </Badge>
                </TableCell>
              </TableRow>
            ))}
          </ResourceTable>
        </div>

        <Card size="sm" className="min-w-0">
          <CardHeader>
            <CardTitle>{mode === 'new' ? t('console.identity.new') : selected?.provider_id}</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-4">
            <ErrorBlock error={draft.error ?? saveProvider.error ?? runSync.error} />
            <Field label={t('console.identity.adapter')}>
              <Select
                disabled={mode === 'edit'}
                value={activeAdapter?.adapter_id ?? ''}
                onValueChange={value => {
                  const adapter = identityAdapters.find(item => item.adapter_id === value)
                  if (adapter) setDraft(emptyIdentityProviderDraft(adapter))
                }}>
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {identityAdapters.map(adapter => (
                    <SelectItem key={adapter.adapter_id} value={adapter.adapter_id}>
                      {localizedUnknown(adapter.display_name, locale, adapter.adapter_id)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field label={t('console.identity.provider_id')}>
              <Input
                disabled={mode === 'edit'}
                value={draft.providerId}
                onChange={event => setDraft(current => ({ ...current, providerId: event.target.value }))}
              />
            </Field>
            <div className="flex items-center justify-between gap-4 border border-border/70 bg-card/60 p-4">
              <div className="grid gap-1">
                <span className="text-sm font-medium">{t('console.identity.enabled')}</span>
                <span className="text-xs text-muted-foreground">{t('console.identity.enabled_hint')}</span>
              </div>
              <Checkbox
                checked={draft.enabled}
                onCheckedChange={checked => setDraft(current => ({ ...current, enabled: checked === true }))}
              />
            </div>
            {activeAdapter ? (
              <ConfigFields
                config={draft.config}
                fieldGroupClassName="grid gap-4 md:grid-cols-2"
                fields={asConfigFields(activeAdapter.fields)}
                locale={locale}
                onChange={(path, value) =>
                  setDraft(current => ({ ...current, config: setPath(current.config, path, value) }))
                }
              />
            ) : null}
            <div className="flex flex-wrap gap-2">
              <Button disabled={!activeAdapter || saveProvider.isPending} size="sm" type="button" onClick={save}>
                <RiSave3Line data-icon="inline-start" />
                {t('common.save')}
              </Button>
              {canRunSync ? (
                <Button
                  disabled={runSync.isPending}
                  size="sm"
                  type="button"
                  variant="outline"
                  onClick={() => selected && runSync.mutate({ path: { provider_id: selected.provider_id } })}>
                  <RiRefreshLine data-icon="inline-start" />
                  {t('console.identity.run_full_sync')}
                </Button>
              ) : null}
            </div>
          </CardContent>
        </Card>
      </div>
    </WorkspaceShell>
  )
}

function emptyIdentityProviderDraft(adapter?: IdentityProviderAdapterItem): IdentityProviderDraft {
  return {
    adapterId: adapter?.adapter_id ?? '',
    config: defaultConfig(asConfigFields(adapter?.fields ?? [])),
    enabled: true,
    providerId: adapter?.default_provider_id ?? ''
  }
}

function draftFromIdentityProvider(provider: IdentityProviderItem): IdentityProviderDraft {
  return {
    adapterId: provider.adapter_id,
    config: recordValue(provider.config) ?? {},
    enabled: provider.enabled,
    providerId: provider.provider_id
  }
}

function asConfigFields(fields: readonly unknown[]): ConfigFieldDefinition[] {
  return fields.map(asConfigField)
}

function asConfigField(field: unknown) {
  return field as unknown as ConfigFieldDefinition
}

function localizedUnknown(value: unknown, locale: string, fallback: string): string {
  return localizedText(value as LocalizedText, locale) ?? fallback
}

function identityProviderSyncEnabled(provider: IdentityProviderItem): boolean {
  return getPath(recordValue(provider.config) ?? {}, 'sync.contacts') !== false
}

function identityProviderSupportsDirectoryFullSync(adapter: IdentityProviderAdapterItem): boolean {
  return adapter.capabilities.includes('directory_full_sync')
}
