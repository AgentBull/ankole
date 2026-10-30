import {
  Badge,
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
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
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { RiArrowDownSLine, RiPauseCircleLine, RiPlayCircleLine, RiSparkling2Line } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useDeferredValue, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from '@tanstack/react-router'
import { localizedText } from '../../common/config-fields'
import i18n from '../../common/i18n'
import { requestErrorCode, requestErrorMessage } from '../../common/request-errors'
import { listAiGatewayProviderKindsOptions as providerKindsOptions } from '../api/v2-site/generated/@tanstack/react-query.gen'
import type { AIGatewayProviderKindItem } from '../state/provider-settings'
import {
  deleteAiGatewayProviderMutation as deleteProviderMutation,
  enableAiGatewayProviderMutation as enableProviderMutation,
  getAiGatewayProviderOptions as providerShowOptions,
  listAiGatewayProvidersOptions as providerIndexOptions,
  putAiGatewayProviderMutation as putProviderMutation
} from '../api/v2-site/generated/@tanstack/react-query.gen'
import { EditorNotFound, LabeledField, ReadOnlyValue, ResourceEditorPage, StatusIndicator } from '../console-form'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import { nextProviderID, ProviderEditorModel } from '../state/provider-editor-model'
import {
  aiGatewayProvider,
  aiGatewayProviders,
  buildSettingOptions,
  connectionSettings,
  initialSettingValue,
  settingValidationMessage,
  type AIGatewayProviderItem,
  type ProviderSetting
} from '../state/provider-settings'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { useEditorDraft } from '../use-editor-draft'
import { ProviderSettingField } from './provider-setting-field'

import { CredentialPoolEditor, credentialStrategyLabel } from './provider-credentials'

export function ProvidersListPage() {
  const { t } = useTranslation()
  const providers = useQuery({ ...providerIndexOptions(), select: aiGatewayProviders })
  const providerKinds = useQuery(providerKindsOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const kindByID = new Map((providerKinds.data?.provider_kinds ?? []).map(kind => [kind.provider_kind, kind]))
  const rows = (providers.data ?? []).filter(provider => {
    const pool = provider.credential_pool
    const kind = kindByID.get(provider.provider_kind)
    const entrySearch = pool.entries.flatMap(entry => [
      entry.id,
      entry.label,
      entry.account_id,
      entry.email,
      entry.status
    ])

    return matchesResourceSearch(
      searchQuery,
      provider.provider_id,
      provider.provider_kind,
      kind ? providerKindLabel(kind) : undefined,
      provider.disabled_at ? 'disabled' : 'enabled',
      provider.disabled_at ? t('console.status.disabled') : t('console.status.enabled'),
      pool.strategy,
      credentialStrategyLabel(t, pool.strategy),
      ...entrySearch
    )
  })
  const removeProvider = useMutation({
    ...deleteProviderMutation(),
    onSuccess: (_data, variables) => {
      const provider = providers.data?.find(item => item.provider_id === variables.path.provider_id)
      toast.success(
        t(provider?.disabled_at ? 'console.providers.deleted' : 'console.providers.disabled', {
          id: variables.path.provider_id
        })
      )
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const enableProvider = useMutation({
    ...enableProviderMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.providers.enabled', { id: variables.path.provider_id }))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.providers.title')}
      description={t('console.providers.description')}
      createTo="new"
      createLabel={t('console.providers.new')}
      columns={[
        t('console.providers.provider'),
        t('console.providers.kind'),
        t('console.providers.pool'),
        t('console.providers.state')
      ]}
      isLoading={providers.isLoading || providerKinds.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t('console.providers.empty_title')}
      emptyIcon={<RiSparkling2Line aria-hidden />}
      emptyDescription={t('console.providers.empty_description')}
      error={providers.error ?? providerKinds.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      toolbar={
        <ResourceSearch
          label={t('console.providers.search')}
          placeholder={t('console.providers.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {rows.map(provider => {
        const entries = provider.credential_pool.entries
        const kind = kindByID.get(provider.provider_kind)
        const usable = entries.filter(entry => entry.status === 'ok').length

        return (
          <TableRow key={provider.provider_id}>
            <TableCell className="font-mono text-xs">
              <Link data-row-link className="text-foreground" to={encodeURIComponent(provider.provider_id)}>
                {provider.provider_id}
              </Link>
            </TableCell>
            <TableCell>
              {kind ? (
                providerKindLabel(kind)
              ) : (
                <div className="flex flex-wrap items-center gap-2">
                  <span>{provider.provider_kind}</span>
                  <Badge variant="warning">{t('console.providers.kind_unavailable')}</Badge>
                </div>
              )}
            </TableCell>
            <TableCell>
              <div className="grid gap-1">
                <span>
                  {t('console.providers.pool_summary', {
                    total: entries.length,
                    usable
                  })}
                </span>
                <span className="text-xs text-muted-foreground">
                  {credentialStrategyLabel(t, provider.credential_pool.strategy)}
                </span>
              </div>
            </TableCell>
            <TableCell>
              <StatusIndicator tone={provider.disabled_at ? 'neutral' : 'positive'}>
                {provider.disabled_at ? t('console.status.disabled') : t('console.status.enabled')}
              </StatusIndicator>
            </TableCell>
            <RowActions
              editTo={encodeURIComponent(provider.provider_id)}
              editLabel={t('common.edit')}
              actions={
                provider.disabled_at
                  ? [
                      {
                        icon: <RiPlayCircleLine />,
                        label: t('common.enable'),
                        pending: enableProvider.isPending,
                        onAction: () => enableProvider.mutate({ path: { provider_id: provider.provider_id } })
                      }
                    ]
                  : []
              }
              deletePending={removeProvider.isPending}
              deleteConfirm={{
                title: t(provider.disabled_at ? 'console.providers.delete_title' : 'console.providers.disable_title'),
                description: t(
                  provider.disabled_at
                    ? 'console.providers.delete_description'
                    : 'console.providers.disable_description',
                  { id: provider.provider_id }
                ),
                confirmLabel: t(provider.disabled_at ? 'common.delete' : 'common.disable'),
                icon: provider.disabled_at ? undefined : <RiPauseCircleLine />
              }}
              onDelete={() => removeProvider.mutate({ path: { provider_id: provider.provider_id } })}
            />
          </TableRow>
        )
      })}
    </ResourceListPage>
  )
}

export function ProviderEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const model = useModel(ProviderEditorModel)
  const params = useParams({ strict: false })
  const providerID = params.providerID
  const mode = providerID ? 'edit' : 'new'

  const providers = useQuery({ ...providerIndexOptions(), select: aiGatewayProviders })
  const providerKinds = useQuery(providerKindsOptions())
  const providerDetail = useQuery({
    ...providerShowOptions({ path: { provider_id: providerID ?? '' } }),
    select: aiGatewayProvider,
    enabled: Boolean(providerID)
  })
  const configuredProviders = providers.data
  const kinds = providerKinds.data?.provider_kinds ?? []
  const selected = providerDetail.data ?? configuredProviders?.find(provider => provider.provider_id === providerID)

  const activeKind = kinds.find(kind => kind.provider_kind === model.providerKind.value)
  const settings = connectionSettings(activeKind)
  // A disabled plugin removes its kind from the registry while the stored
  // provider row survives. Detect from the stored row, not the editor model,
  // so the notice cannot flash before the model seeds.
  const unavailableKind =
    mode === 'edit' &&
    kinds.length > 0 &&
    selected &&
    !kinds.some(kind => kind.provider_kind === selected.provider_kind)
      ? selected.provider_kind
      : undefined

  const sourceReady = kinds.length > 0 && (mode === 'new' ? Boolean(configuredProviders) : Boolean(selected))
  const providerDraft = useMemo(() => {
    if (!sourceReady) return undefined
    if (mode === 'edit' && selected) {
      const kind = kinds.find(item => item.provider_kind === selected.provider_kind)
      return {
        providerID: selected.provider_id,
        providerKind: selected.provider_kind,
        baseURL: selected.base_url ?? '',
        options: initialOptions(connectionSettings(kind), selected)
      }
    }
    if (mode === 'new') {
      const kind = kinds[0]
      return {
        providerID: nextProviderID(
          kind?.provider_kind ?? '',
          configuredProviders?.map(provider => provider.provider_id) ?? []
        ),
        providerKind: kind?.provider_kind ?? '',
        baseURL: kind?.default_base_url ?? '',
        options: initialOptions(connectionSettings(kind), undefined)
      }
    }
    return undefined
  }, [configuredProviders, kinds, mode, selected, sourceReady])
  const draftStatus = useEditorDraft(model, {
    sourceKey: providerID ? `provider:${providerID}` : 'new',
    source: providerDraft,
    absent: () => mode === 'edit' && requestErrorCode(providerDetail.error) === 'not_found'
  })

  const saveProvider = useMutation(putProviderMutation())

  const changeKind = (providerKind: string) => {
    const kind = kinds.find(item => item.provider_kind === providerKind)
    model.changeKind({
      providerID: nextProviderID(providerKind, configuredProviders?.map(provider => provider.provider_id) ?? []),
      providerKind,
      baseURL: kind?.default_base_url ?? '',
      options: initialOptions(connectionSettings(kind), undefined)
    })
  }

  const submit = () => {
    model.clearValidation()
    const trimmedID = model.providerID.value.trim()
    if (!trimmedID) {
      model.validationError.value = t('console.providers.provider_id_required')
      return
    }

    const built = buildSettingOptions(settings, model.options.value, settingValidationMessage)
    if (!built.ok) {
      model.validationError.value = built.error
      return
    }

    void model
      .save(
        draft =>
          saveProvider.mutateAsync({
            body: {
              data: {
                type: 'ai_gateway_provider',
                // The path names the provider. A new provider has no record ID yet.
                id: selected?.id ?? '',
                attributes: {
                  provider_kind: draft.providerKind,
                  base_url: draft.baseURL.trim() || null,
                  connection_options: built.value
                }
              }
            },
            path: { provider_id: trimmedID }
          }),
        (response, clean) => {
          const { provider_id } = aiGatewayProvider(response)
          toast.success(t('console.providers.saved', { id: provider_id }))
          if (clean) void navigate({ to: `/providers/${encodeURIComponent(provider_id)}` })
        }
      )
      .catch(() => {
        /* The mutation owns the displayed request error. */
      })
  }

  const baseURLSetting = settings.find(setting => setting.key === 'base_url')
  const optionSettings = settings.filter(setting => setting.key !== 'base_url')
  const advancedBaseURL = baseURLSetting?.advanced ?? false
  const advancedSettings = optionSettings.filter(setting => setting.advanced)
  const basicSettings = optionSettings.filter(setting => !setting.advanced)
  const advancedFieldCount = advancedSettings.length + (advancedBaseURL ? 1 : 0)
  const submitDisabled = mode === 'edit' && !model.dirty.value
  const baseURLField = (
    <LabeledField label={t('console.providers.base_url')} description={t('console.providers.base_url_hint')}>
      <Input
        placeholder={activeKind?.default_base_url ?? 'https://api.example.com/v1'}
        value={model.baseURL.value}
        onChange={event => (model.baseURL.value = event.target.value)}
      />
    </LabeledField>
  )

  if (draftStatus === 'absent') {
    return <EditorNotFound backTo="/providers" message={t('console.not_found.description')} />
  }

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.providers.new') : (providerID ?? '')}
      description={t('console.providers.editor_description')}
      backTo="/providers"
      dirty={model.dirty.value}
      error={
        model.validationError.value ??
        saveProvider.error ??
        providerDetail.error ??
        providers.error ??
        providerKinds.error
      }
      submitting={saveProvider.isPending}
      submitDisabled={submitDisabled}
      submitUnavailable={draftStatus !== 'ready' || Boolean(unavailableKind)}
      contentWidth="wide"
      supplementary={
        mode === 'edit' && selected ? (
          activeKind ? (
            <CredentialPoolEditor provider={selected} providerKind={activeKind} />
          ) : unavailableKind ? (
            <section className="grid gap-1 border border-border bg-card p-5 md:p-6">
              <h3 className="title-section">{t('console.providers.pool_title')}</h3>
              <p className="max-w-2xl text-sm text-muted-foreground">{t('console.providers.pool_kind_unavailable')}</p>
            </section>
          ) : null
        ) : null
      }
      onSubmit={submit}>
      <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
        <LabeledField
          label={t('console.providers.provider_id')}
          description={t('console.providers.provider_id_hint')}
          required={mode === 'new'}>
          {mode === 'edit' ? (
            <ReadOnlyValue mono>{model.providerID.value}</ReadOnlyValue>
          ) : (
            <Input
              required
              placeholder="openai"
              value={model.providerID.value}
              onChange={event => (model.providerID.value = event.target.value)}
            />
          )}
        </LabeledField>
        <LabeledField
          label={t('console.providers.kind')}
          required={mode === 'new'}
          description={
            unavailableKind ? t('console.providers.kind_unavailable_description', { kind: unavailableKind }) : undefined
          }>
          {mode === 'edit' ? (
            <ReadOnlyValue>
              {unavailableKind ? (
                <span className="flex flex-wrap items-center gap-2">
                  {unavailableKind}
                  <Badge variant="warning">{t('console.providers.kind_unavailable')}</Badge>
                </span>
              ) : activeKind ? (
                providerKindLabel(activeKind)
              ) : (
                model.providerKind.value
              )}
            </ReadOnlyValue>
          ) : (
            <Select value={model.providerKind.value} onValueChange={value => changeKind(String(value))}>
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent emptyLabel={t('common.select_empty')}>
                {kinds.map(kind => (
                  <SelectItem key={kind.provider_kind} value={kind.provider_kind}>
                    {providerKindLabel(kind)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </LabeledField>
      </div>

      {advancedBaseURL ? null : baseURLField}

      {basicSettings.map(setting => (
        <ProviderSettingField
          key={setting.key}
          setting={setting}
          value={model.options.value[setting.key] ?? ''}
          onChange={value => model.setOption(setting.key, value)}
        />
      ))}

      {advancedFieldCount > 0 ? (
        <Collapsible className="grid gap-4" defaultOpen={false}>
          <CollapsibleTrigger className="group flex w-full items-center justify-between gap-3 border border-border bg-muted/40 px-4 py-3 text-left text-sm font-medium">
            <span>{t('common.advanced_settings')}</span>
            <span className="flex items-center gap-2 text-xs text-muted-foreground">
              {advancedFieldCount}
              <RiArrowDownSLine
                className="size-4 shrink-0 transition-transform group-aria-expanded:rotate-180"
                aria-hidden
              />
            </span>
          </CollapsibleTrigger>
          <CollapsibleContent className="grid gap-5">
            {advancedBaseURL ? baseURLField : null}
            {advancedSettings.map(setting => (
              <ProviderSettingField
                key={setting.key}
                setting={setting}
                value={model.options.value[setting.key] ?? ''}
                onChange={value => model.setOption(setting.key, value)}
              />
            ))}
          </CollapsibleContent>
        </Collapsible>
      ) : null}

      {mode === 'edit' ? (
        <p className="text-xs text-muted-foreground">
          {t('console.providers.model_profiles_hint')}{' '}
          <Link to="/agents" className="link">
            {t('console.nav.agents')}
          </Link>
        </p>
      ) : null}
    </ResourceEditorPage>
  )
}

function initialOptions(
  settings: ProviderSetting[],
  provider: AIGatewayProviderItem | undefined
): Record<string, string> {
  return Object.fromEntries(settings.map(setting => [setting.key, initialSettingValue(setting, provider)]))
}

function providerKindLabel(kind: AIGatewayProviderKindItem): string {
  return localizedText(kind.label, i18n.language) ?? kind.provider_kind
}
