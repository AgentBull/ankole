import {
  Badge,
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
import { recordValue, type JsonObject as JSONObject } from '@pleisto/active-support'
import { RiRefreshLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useNavigate, useParams } from 'react-router'
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
import { LabeledField, ResourceEditorPage, ResourceListPage, RowActions } from '../console-shell'

export function IdentityProvidersListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const providers = useQuery(ankoleWebIdentityProviderControllerIndexOptions())
  const rows = providers.data?.identity_providers ?? []

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
      emptyTitle={t('console.identity.empty_title')}
      emptyDescription={t('console.identity.empty_description')}
      error={providers.error}>
      {rows.map(provider => (
        <TableRow
          key={provider.provider_id}
          className="cursor-pointer"
          onClick={() => navigate(encodeURIComponent(provider.provider_id))}>
          <TableCell className="font-mono text-xs">{provider.provider_id}</TableCell>
          <TableCell>{provider.adapter_id}</TableCell>
          <TableCell>
            <Badge variant={syncEnabled(provider) ? 'default' : 'outline'}>
              {syncEnabled(provider) ? t('console.status.contacts') : t('console.status.off')}
            </Badge>
          </TableCell>
          <TableCell>
            <Badge variant={provider.enabled ? 'default' : 'secondary'}>
              {provider.enabled ? t('console.status.enabled') : t('console.status.disabled')}
            </Badge>
          </TableCell>
          <RowActions editTo={encodeURIComponent(provider.provider_id)} editLabel={t('common.edit')} />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

type IdentityForm = {
  adapterID: string
  providerID: string
  enabled: boolean
  config: JSONObject
}

export function IdentityProviderEditorPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const params = useParams()
  const providerID = params.providerID ? decodeURIComponent(params.providerID) : undefined
  const mode = providerID ? 'edit' : 'new'
  const locale = i18n.language

  const adapters = useQuery(ankoleWebIdentityProviderControllerAdaptersOptions())
  const providers = useQuery(ankoleWebIdentityProviderControllerIndexOptions())
  const identityAdapters = adapters.data?.identity_provider_adapters ?? []
  const selected = providers.data?.identity_providers.find(provider => provider.provider_id === providerID)

  const [form, setForm] = useState<IdentityForm>(emptyForm())
  const [error, setError] = useState<string>()
  const activeAdapter = identityAdapters.find(adapter => adapter.adapter_id === form.adapterID) ?? identityAdapters[0]
  const selectedAdapter = identityAdapters.find(adapter => adapter.adapter_id === selected?.adapter_id)

  const ready = identityAdapters.length > 0 && (mode === 'new' || Boolean(selected))
  useEffect(() => {
    if (!ready) return
    if (mode === 'edit' && selected) {
      setForm(formFromProvider(selected))
    } else if (mode === 'new') {
      setForm(emptyForm(identityAdapters[0]))
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, mode, providerID])

  const refresh = () => void queryClient.invalidateQueries()
  const saveProvider = useMutation({
    ...ankoleWebIdentityProviderControllerPutProviderMutation(),
    onSuccess: response => {
      toast.success(t('console.identity.saved', { id: response.identity_provider.provider_id }))
      refresh()
      navigate('..')
    },
    onError: mutationError => setError(requestErrorMessage(mutationError))
  })
  const runSync = useMutation({
    ...ankoleWebIdentityProviderControllerRunSyncMutation(),
    onSuccess: () => {
      toast.success(t('console.identity.sync_started'))
      refresh()
    },
    onError: mutationError => toast.error(requestErrorMessage(mutationError))
  })

  const changeAdapter = (adapterID: string) => {
    const adapter = identityAdapters.find(item => item.adapter_id === adapterID)
    if (adapter) setForm(emptyForm(adapter))
  }

  const submit = () => {
    setError(undefined)
    if (!activeAdapter) return
    const trimmedID = form.providerID.trim()
    if (!trimmedID) {
      setError(t('console.identity.provider_id_required'))
      return
    }
    saveProvider.mutate({
      body: { adapter_id: activeAdapter.adapter_id, config: form.config, enabled: form.enabled },
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

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.identity.new') : (providerID ?? '')}
      description={t('console.identity.editor_description')}
      backTo=".."
      error={error ?? saveProvider.error}
      submitting={saveProvider.isPending}
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
      <div className="grid gap-5 md:grid-cols-2">
        <LabeledField label={t('console.identity.adapter')}>
          <Select
            disabled={mode === 'edit'}
            value={activeAdapter?.adapter_id ?? ''}
            onValueChange={value => changeAdapter(String(value))}>
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
        </LabeledField>
        <LabeledField
          label={t('console.identity.provider_id')}
          description={t('console.identity.provider_id_hint')}
          required={mode === 'new'}>
          <Input
            disabled={mode === 'edit'}
            value={form.providerID}
            onChange={event => setForm(current => ({ ...current, providerID: event.target.value }))}
          />
        </LabeledField>
      </div>

      <label className="flex items-center justify-between gap-4 border border-border bg-muted/30 p-4">
        <span className="grid gap-1">
          <span className="text-sm font-medium">{t('console.identity.enabled')}</span>
          <span className="text-xs text-muted-foreground">{t('console.identity.enabled_hint')}</span>
        </span>
        <Checkbox
          checked={form.enabled}
          onCheckedChange={checked => setForm(current => ({ ...current, enabled: checked === true }))}
        />
      </label>

      {activeAdapter ? (
        <ConfigFields
          config={form.config}
          fields={asConfigFields(activeAdapter.fields)}
          locale={locale}
          onChange={(path, value) => setForm(current => ({ ...current, config: setPath(current.config, path, value) }))}
        />
      ) : null}
    </ResourceEditorPage>
  )
}

function emptyForm(adapter?: IdentityProviderAdapterItem): IdentityForm {
  return {
    adapterID: adapter?.adapter_id ?? '',
    providerID: adapter?.default_provider_id ?? '',
    enabled: true,
    config: defaultConfig(asConfigFields(adapter?.fields ?? []))
  }
}

function formFromProvider(provider: IdentityProviderItem): IdentityForm {
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
