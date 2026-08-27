import { recordValue } from '@agentbull/active-support'
import {
  Badge,
  Button,
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow,
  Textarea,
  toast
} from '@ankole/uikit'
import {
  RiAddLine,
  RiArrowDownSLine,
  RiExternalLinkLine,
  RiLoaderLine,
  RiPauseCircleLine,
  RiPlayCircleLine,
  RiRefreshLine,
  RiSparkling2Line
} from '@remixicon/react'
import type { TFunction } from 'i18next'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ankoleWebAiGatewayProviderControllerAddChatgptEnterpriseCredentialMutation as addChatGPTEnterpriseCredentialMutation,
  ankoleWebAiGatewayProviderControllerAddCredentialMutation as addCredentialMutation,
  ankoleWebAiGatewayProviderControllerCompleteChatgptBrowserLoginMutation as completeChatGPTBrowserLoginMutation,
  ankoleWebAiGatewayProviderControllerDeleteCredentialMutation as deleteCredentialMutation,
  ankoleWebAiGatewayProviderControllerDeleteProviderMutation as deleteProviderMutation,
  ankoleWebAiGatewayProviderControllerEnableProviderMutation as enableProviderMutation,
  ankoleWebAiGatewayProviderControllerIndexOptions as providerIndexOptions,
  ankoleWebAiGatewayProviderControllerPollChatgptLoginMutation as pollChatGPTLoginMutation,
  ankoleWebAiGatewayProviderControllerProviderKindsOptions as providerKindsOptions,
  ankoleWebAiGatewayProviderControllerPutCredentialMutation as putCredentialMutation,
  ankoleWebAiGatewayProviderControllerPutCredentialStrategyMutation as putCredentialStrategyMutation,
  ankoleWebAiGatewayProviderControllerPutProviderMutation as putProviderMutation,
  ankoleWebAiGatewayProviderControllerShowOptions as providerShowOptions,
  ankoleWebAiGatewayProviderControllerStartChatgptLoginMutation as startChatGPTLoginMutation
} from '../api/generated/@tanstack/react-query.gen'
import type {
  AiGatewayCredentialPoolEntry as AIGatewayCredentialPoolEntry,
  AiGatewayCredentialStrategyWriteRequest as AIGatewayCredentialStrategyWriteRequest,
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem
} from '../api/generated/types.gen'
import { localizedText } from '../../common/config-fields'
import i18n from '../../common/i18n'
import { requestErrorCode, requestErrorDetails, requestErrorMessage } from '../../common/request-errors'
import {
  ConfirmDeleteButton,
  DiscardConfirmDialog,
  LabeledField,
  ReadOnlyValue,
  ResourceEditorPage,
  SaveButton,
  StatusIndicator,
  useDialogDiscardGuard
} from '../console-form'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import { EncryptedValueInput } from '../encrypted-value-input'
import { formatConsoleDate } from '../console-primitives'
import { nextProviderID, ProviderEditorModel } from '../state/provider-editor-model'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { ProviderSettingField } from './provider-setting-field'
import {
  buildConnectionOptions,
  buildSettingOptions,
  connectionSettings,
  credentialSettings,
  humanizeKey,
  initialSettingValue,
  settingValidationMessage,
  type ProviderSetting
} from './provider-settings'

type CredentialStrategy = AIGatewayCredentialStrategyWriteRequest['strategy']
type LoginPayload = Record<string, unknown>

const credentialStrategies = [
  'fill_first',
  'round_robin',
  'least_used',
  'random'
] as const satisfies readonly CredentialStrategy[]

export function ProvidersListPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const providers = useQuery(providerIndexOptions())
  const providerKinds = useQuery(providerKindsOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const kindByID = new Map((providerKinds.data?.provider_kinds ?? []).map(kind => [kind.provider_kind, kind]))
  const rows = (providers.data?.ai_gateway_providers ?? []).filter(provider => {
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
      pool.strategy,
      ...entrySearch
    )
  })
  const removeProvider = useMutation({
    ...deleteProviderMutation(),
    onSuccess: (_data, variables) => {
      const provider = providers.data?.ai_gateway_providers.find(
        item => item.provider_id === variables.path.provider_id
      )
      toast.success(
        t(provider?.disabled_at ? 'console.providers.deleted' : 'console.providers.disabled', {
          id: variables.path.provider_id
        })
      )
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const enableProvider = useMutation({
    ...enableProviderMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.providers.enabled', { id: variables.path.provider_id }))
      void queryClient.invalidateQueries()
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
      error={providers.error}
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
              <Link
                className="text-foreground hover:text-link hover:underline"
                to={encodeURIComponent(provider.provider_id)}>
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
  const queryClient = useQueryClient()
  const model = useModel(ProviderEditorModel)
  const params = useParams()
  const providerID = params.providerID
  const mode = providerID ? 'edit' : 'new'

  const providers = useQuery(providerIndexOptions())
  const providerKinds = useQuery(providerKindsOptions())
  const providerDetail = useQuery({
    ...providerShowOptions({ path: { provider_id: providerID ?? '' } }),
    enabled: Boolean(providerID)
  })
  const configuredProviders = providers.data?.ai_gateway_providers
  const kinds = providerKinds.data?.provider_kinds ?? []
  const selected =
    providerDetail.data?.ai_gateway_provider ??
    configuredProviders?.find(provider => provider.provider_id === providerID)

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

  const ready = kinds.length > 0 && (mode === 'new' ? Boolean(configuredProviders) : Boolean(selected))
  useEffect(() => {
    if (!ready) return
    if (mode === 'edit' && selected) {
      const kind = kinds.find(item => item.provider_kind === selected.provider_kind)
      model.initialize(`provider:${selected.provider_id}`, {
        providerID: selected.provider_id,
        providerKind: selected.provider_kind,
        baseURL: selected.base_url ?? '',
        options: initialOptions(connectionSettings(kind), selected)
      })
    } else if (mode === 'new') {
      const kind = kinds[0]
      model.initialize('new', {
        providerID: nextProviderID(
          kind?.provider_kind ?? '',
          configuredProviders?.map(provider => provider.provider_id) ?? []
        ),
        providerKind: kind?.provider_kind ?? '',
        baseURL: kind?.default_base_url ?? '',
        options: initialOptions(connectionSettings(kind), undefined)
      })
    }
  }, [configuredProviders, kinds, mode, model, providerID, ready, selected])

  const saveProvider = useMutation({
    ...putProviderMutation(),
    onSuccess: response => {
      toast.success(t('console.providers.saved', { id: response.ai_gateway_provider.provider_id }))
      model.markSaved()
      void queryClient.invalidateQueries()
      navigate(`/providers/${encodeURIComponent(response.ai_gateway_provider.provider_id)}`)
    }
  })

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

    const built = buildConnectionOptions(settings, model.options.value, settingValidationMessage)
    if (!built.ok) {
      model.validationError.value = built.error
      return
    }

    saveProvider.mutate({
      body: {
        provider_id: trimmedID,
        provider_kind: model.providerKind.value,
        base_url: model.baseURL.value.trim() ? model.baseURL.value.trim() : null,
        connection_options: built.value
      },
      path: { provider_id: trimmedID }
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

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.providers.new') : (providerID ?? '')}
      description={t('console.providers.editor_description')}
      backTo="/providers"
      error={
        model.validationError.value ??
        saveProvider.error ??
        providerDetail.error ??
        providers.error ??
        providerKinds.error
      }
      submitting={saveProvider.isPending}
      submitDisabled={submitDisabled}
      submitUnavailable={!ready || Boolean(unavailableKind)}
      contentWidth="wide"
      supplementary={
        mode === 'edit' && selected ? (
          activeKind ? (
            <CredentialPoolEditor provider={selected} providerKind={activeKind} />
          ) : unavailableKind ? (
            <section className="grid gap-1 border border-border bg-card p-5 md:p-6">
              <h3 className="text-lg font-semibold">{t('console.providers.pool_title')}</h3>
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
          <CollapsibleTrigger className="flex w-full items-center justify-between gap-3 border border-border bg-muted/40 px-4 py-3 text-left text-sm font-medium">
            <span>{t('common.advanced_settings')}</span>
            <span className="flex items-center gap-2 text-xs text-muted-foreground">
              {advancedFieldCount}
              <RiArrowDownSLine className="size-4" aria-hidden />
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
          <Link to="/agents" className="text-link underline underline-offset-4">
            {t('console.nav.agents')}
          </Link>
        </p>
      ) : null}
    </ResourceEditorPage>
  )
}

function CredentialPoolEditor({
  provider,
  providerKind
}: {
  provider: AIGatewayProviderItem
  providerKind: AIGatewayProviderKindItem
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [credentialEditor, setCredentialEditor] = useState<AIGatewayCredentialPoolEntry | null | undefined>()
  const [chatGPTLoginEntry, setChatGPTLoginEntry] = useState<AIGatewayCredentialPoolEntry | null | undefined>()
  const [enterpriseEntry, setEnterpriseEntry] = useState<AIGatewayCredentialPoolEntry | null | undefined>()
  const isChatGPT = provider.provider_kind === 'chatgpt_subscription'
  const refresh = () => void queryClient.invalidateQueries()

  const setStrategy = useMutation({
    ...putCredentialStrategyMutation(),
    onSuccess: response => {
      toast.success(
        t('console.providers.strategy_saved', {
          strategy: credentialStrategyLabel(t, response.ai_gateway_provider.credential_pool.strategy)
        })
      )
      refresh()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const updateCredential = useMutation({
    ...putCredentialMutation(),
    onSuccess: () => refresh(),
    onError: error => toast.error(requestErrorMessage(error))
  })
  const removeCredential = useMutation({
    ...deleteCredentialMutation(),
    onSuccess: () => {
      toast.success(t('console.providers.credential_deleted'))
      refresh()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const changeAvailability = (entry: AIGatewayCredentialPoolEntry) => {
    updateCredential.mutate({
      body: { disabled_at: entry.status === 'disabled' ? null : new Date().toISOString() },
      path: { provider_id: provider.provider_id, credential_id: entry.id }
    })
  }

  return (
    <section className="grid gap-5 border border-border bg-card p-5 md:p-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="grid gap-1">
          <h3 className="text-lg font-semibold">{t('console.providers.pool_title')}</h3>
          <p className="max-w-2xl text-sm text-muted-foreground">{t('console.providers.pool_description')}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          {isChatGPT ? (
            <>
              <Button size="sm" type="button" onClick={() => setChatGPTLoginEntry(null)}>
                <RiAddLine data-icon="inline-start" />
                {t('console.providers.add_chatgpt_account')}
              </Button>
              <Button size="sm" type="button" variant="outline" onClick={() => setEnterpriseEntry(null)}>
                <RiAddLine data-icon="inline-start" />
                {t('console.providers.add_enterprise_token')}
              </Button>
            </>
          ) : (
            <Button size="sm" type="button" onClick={() => setCredentialEditor(null)}>
              <RiAddLine data-icon="inline-start" />
              {t('console.providers.add_credential')}
            </Button>
          )}
        </div>
      </div>

      <LabeledField label={t('console.providers.strategy')} description={t('console.providers.strategy_hint')}>
        <Select
          value={provider.credential_pool.strategy}
          disabled={setStrategy.isPending}
          onValueChange={value =>
            setStrategy.mutate({
              body: { strategy: String(value) as CredentialStrategy },
              path: { provider_id: provider.provider_id }
            })
          }>
          <SelectTrigger className="w-full md:max-w-sm">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {credentialStrategies.map(strategy => (
              <SelectItem key={strategy} value={strategy}>
                {credentialStrategyLabel(t, strategy)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </LabeledField>

      {provider.credential_pool.entries.length === 0 ? (
        <div className="border border-dashed border-border p-6 text-sm text-muted-foreground">
          {t('console.providers.pool_empty')}
        </div>
      ) : (
        <div className="grid gap-3">
          {provider.credential_pool.entries.map(entry => (
            <article key={entry.id} className="grid gap-4 border border-border bg-background p-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="grid gap-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <h4 className="font-medium">{entry.label}</h4>
                    <StatusIndicator tone={credentialStatusTone(entry.status)}>
                      {t(`console.providers.credential_status_${entry.status}`)}
                    </StatusIndicator>
                    {entry.reauth_required ? (
                      <Badge variant="warning">{t('console.providers.reauth_required')}</Badge>
                    ) : null}
                  </div>
                  <div className="flex flex-wrap gap-x-4 gap-y-1 font-mono text-xs text-muted-foreground">
                    <span>{entry.id}</span>
                    <span>{t('console.providers.priority_value', { priority: entry.priority })}</span>
                    <span>{credentialSourceLabel(t, entry.source)}</span>
                  </div>
                </div>
                <div className="flex flex-wrap gap-2">
                  {entry.reauth_required && isChatGPT ? (
                    <Button
                      size="xs"
                      type="button"
                      variant="outline"
                      onClick={() =>
                        entry.auth_type === 'enterprise_access_token'
                          ? setEnterpriseEntry(entry)
                          : setChatGPTLoginEntry(entry)
                      }>
                      <RiRefreshLine data-icon="inline-start" />
                      {t('console.providers.reauthenticate')}
                    </Button>
                  ) : null}
                  <Button size="xs" type="button" variant="outline" onClick={() => setCredentialEditor(entry)}>
                    {t('common.edit')}
                  </Button>
                  <Button
                    size="xs"
                    type="button"
                    variant="outline"
                    disabled={updateCredential.isPending}
                    onClick={() => changeAvailability(entry)}>
                    {entry.status === 'disabled' ? t('common.enable') : t('common.disable')}
                  </Button>
                  <ConfirmDeleteButton
                    pending={removeCredential.isPending}
                    confirm={{
                      title: t('console.providers.delete_credential_title'),
                      description: t('console.providers.delete_credential_description', { label: entry.label }),
                      confirmLabel: t('common.delete')
                    }}
                    onConfirm={() =>
                      removeCredential.mutate({
                        path: { provider_id: provider.provider_id, credential_id: entry.id }
                      })
                    }
                  />
                </div>
              </div>

              <dl className="grid gap-3 text-sm md:grid-cols-2">
                <CredentialFact label={t('console.providers.account_id')} value={entry.account_id} />
                <CredentialFact label={t('console.providers.email')} value={entry.email} />
                <CredentialFact label={t('console.providers.plan_type')} value={entry.plan_type} />
                <CredentialFact
                  label={t('console.providers.auth_type')}
                  value={entry.auth_type ? humanizeKey(entry.auth_type) : undefined}
                />
                <CredentialFact label={t('console.providers.request_count')} value={String(entry.request_count ?? 0)} />
                <CredentialFact
                  label={t('console.providers.token_usage')}
                  value={formatCredentialUsage(t, entry.usage)}
                />
                <CredentialFact
                  label={t('console.providers.last_selected_at')}
                  value={entry.last_selected_at ? formatConsoleDate(entry.last_selected_at) : undefined}
                />
                <CredentialFact
                  label={t('console.providers.retry_at')}
                  value={entry.retry_at ? formatConsoleDate(entry.retry_at) : undefined}
                />
                <CredentialFact
                  label={t('console.providers.last_refresh')}
                  value={entry.last_refresh ? formatConsoleDate(entry.last_refresh) : undefined}
                />
              </dl>

              <CredentialDiagnostics
                label={t('console.providers.rate_limits')}
                value={formatRateLimits(entry.rate_limits)}
              />

              {entry.last_error_code || entry.last_error_reason || entry.last_error_message ? (
                <div className="grid gap-1 border-l-2 border-warning px-3 text-xs">
                  <span className="font-mono">
                    {[entry.provider_status, entry.last_error_code, entry.last_error_reason]
                      .filter(Boolean)
                      .join(' · ')}
                  </span>
                  {entry.last_error_message ? (
                    <span className="text-muted-foreground">{entry.last_error_message}</span>
                  ) : null}
                </div>
              ) : null}
            </article>
          ))}
        </div>
      )}

      <CredentialEditorDialog
        entry={credentialEditor}
        provider={provider}
        providerKind={providerKind}
        open={credentialEditor !== undefined}
        onOpenChange={open => !open && setCredentialEditor(undefined)}
      />
      <ChatGPTLoginDialog
        entry={chatGPTLoginEntry}
        provider={provider}
        open={chatGPTLoginEntry !== undefined}
        onOpenChange={open => !open && setChatGPTLoginEntry(undefined)}
      />
      <EnterpriseCredentialDialog
        entry={enterpriseEntry}
        provider={provider}
        open={enterpriseEntry !== undefined}
        onOpenChange={open => !open && setEnterpriseEntry(undefined)}
      />
    </section>
  )
}

function CredentialEditorDialog({
  entry,
  onOpenChange,
  open,
  provider,
  providerKind
}: {
  entry: AIGatewayCredentialPoolEntry | null | undefined
  onOpenChange: (open: boolean) => void
  open: boolean
  provider: AIGatewayProviderItem
  providerKind: AIGatewayProviderKindItem
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  // ChatGPT pool entries hold OAuth tokens owned by the login flow, so the
  // editor exposes only label and priority; the control plane keeps the
  // stored values of every omitted field.
  const metadataOnly = provider.provider_kind === 'chatgpt_subscription'
  const settings = useMemo(() => (metadataOnly ? [] : credentialSettings(providerKind)), [metadataOnly, providerKind])
  const [label, setLabel] = useState('')
  const [priority, setPriority] = useState('0')
  const [values, setValues] = useState<Record<string, string>>({})
  const [validationError, setValidationError] = useState<string>()

  const finish = () => {
    void queryClient.invalidateQueries()
    onOpenChange(false)
  }
  const create = useMutation({
    ...addCredentialMutation(),
    onSuccess: finish
  })
  const update = useMutation({
    ...putCredentialMutation(),
    onSuccess: finish
  })

  useEffect(() => {
    if (!open) return
    setLabel(entry?.label ?? '')
    setPriority(String(entry?.priority ?? 0))
    // Reset only when a new editing session opens. Rendering falls back to ''
    // per key, so the cleared map needs no entries — and no `settings`
    // dependency, whose query-driven identity must not wipe in-progress input.
    setValues({})
    setValidationError(undefined)
    create.reset()
    update.reset()
  }, [entry, open])

  const submit = () => {
    setValidationError(undefined)
    if (!label.trim()) {
      setValidationError(t('console.providers.credential_label_required'))
      return
    }
    if (!entry) {
      const missing = settings.find(setting => {
        const value = values[setting.key]?.trim()
        return setting.required && !value
      })
      if (missing) {
        setValidationError(settingValidationMessage(humanizeKey(missing.key), 'required'))
        return
      }
    }

    const built = buildSettingOptions(settings, values, settingValidationMessage)
    if (!built.ok) {
      setValidationError(built.error)
      return
    }
    const body = {
      label: label.trim(),
      priority: Number.parseInt(priority, 10) || 0,
      ...built.value
    }

    if (entry) {
      update.mutate({
        body,
        path: { provider_id: provider.provider_id, credential_id: entry.id }
      })
    } else {
      create.mutate({ body, path: { provider_id: provider.provider_id } })
    }
  }
  const pending = create.isPending || update.isPending
  const error = validationError ?? create.error ?? update.error
  const incomplete =
    !label.trim() ||
    (!entry &&
      settings.some(setting => {
        const value = values[setting.key]?.trim()
        return setting.required && !value
      }))
  const dirty =
    label !== (entry?.label ?? '') ||
    priority !== String(entry?.priority ?? 0) ||
    Object.values(values).some(value => value.trim() !== '')
  const guard = useDialogDiscardGuard({ dirty: open && dirty, pending, onOpenChange })

  return (
    <Dialog open={open} onOpenChange={guard.requestOpenChange}>
      <DialogContent closeLabel={t('common.close')} showCloseButton={!pending}>
        <DialogHeader>
          <DialogTitle>
            {entry ? t('console.providers.edit_credential') : t('console.providers.add_credential')}
          </DialogTitle>
          <DialogDescription>
            {metadataOnly
              ? t('console.providers.chatgpt_credential_editor_description')
              : t('console.providers.credential_editor_description')}
          </DialogDescription>
        </DialogHeader>
        <form
          className="contents"
          noValidate
          onSubmit={event => {
            event.preventDefault()
            submit()
          }}>
          <div className="grid max-h-[65vh] gap-4 overflow-y-auto py-1">
            {error ? (
              <p className="text-sm text-destructive" aria-live="assertive">
                {requestErrorMessage(error)}
              </p>
            ) : null}
            <LabeledField label={t('console.providers.credential_label')} required>
              <Input value={label} onChange={event => setLabel(event.target.value)} />
            </LabeledField>
            <LabeledField label={t('console.providers.priority')}>
              <Input type="number" step={1} value={priority} onChange={event => setPriority(event.target.value)} />
            </LabeledField>
            {settings.map(setting => (
              <ProviderSettingField
                key={setting.key}
                setting={setting}
                keepStored={Boolean(entry)}
                secretPresent={Boolean(entry?.credential_present)}
                value={values[setting.key] ?? ''}
                onChange={value => setValues(current => ({ ...current, [setting.key]: value }))}
              />
            ))}
          </div>
          <DialogFooter>
            <Button type="button" variant="ghost" disabled={pending} onClick={() => guard.requestOpenChange(false)}>
              {t('common.cancel')}
            </Button>
            <SaveButton type="submit" disabled={pending} incomplete={incomplete && !pending} loading={pending}>
              {t('common.save')}
            </SaveButton>
          </DialogFooter>
        </form>
      </DialogContent>
      <DiscardConfirmDialog open={guard.confirming} onDiscard={guard.confirmDiscard} onKeep={guard.keepEditing} />
    </Dialog>
  )
}

// Coded ChatGPT sign-in failures and whether their message interpolates the
// upstream response. Each code's locale key is `console.providers.<code>`.
const chatGPTLoginErrorCodes: Record<string, { upstream: boolean }> = {
  chatgpt_login_rejected: { upstream: true },
  chatgpt_login_unreachable: { upstream: true },
  chatgpt_refresh_failed: { upstream: true },
  chatgpt_login_denied: { upstream: false },
  chatgpt_login_expired: { upstream: false },
  chatgpt_login_invalid: { upstream: false }
}

/**
 * Localizes coded ChatGPT sign-in failures and keeps the real upstream
 * response visible; unknown failures fall back to the envelope message.
 */
function chatGPTLoginErrorText(error: unknown, t: (key: string, values?: Record<string, string>) => string): string {
  if (typeof error === 'string') return error
  const code = requestErrorCode(error) ?? ''
  const entry = chatGPTLoginErrorCodes[code]
  if (!entry) return requestErrorMessage(error)
  if (!entry.upstream) return t(`console.providers.${code}`)

  const details = requestErrorDetails(error)
  const status = details.upstream_status
  const upstreamCode = details.upstream_code ?? details.transport
  const upstream = [
    typeof status === 'number' ? `HTTP ${status}` : undefined,
    typeof upstreamCode === 'string' ? upstreamCode : undefined
  ]
    .filter(Boolean)
    .join(', ')
  return upstream ? t(`console.providers.${code}`, { upstream }) : requestErrorMessage(error)
}

function ChatGPTLoginDialog({
  entry,
  onOpenChange,
  open,
  provider
}: {
  entry: AIGatewayCredentialPoolEntry | null | undefined
  onOpenChange: (open: boolean) => void
  open: boolean
  provider: AIGatewayProviderItem
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [label, setLabel] = useState('')
  const [priority, setPriority] = useState('0')
  const [login, setLogin] = useState<LoginPayload>()
  const [callbackURL, setCallbackURL] = useState('')
  const [validationError, setValidationError] = useState<string>()

  const finish = () => {
    toast.success(t('console.providers.chatgpt_login_complete'))
    void queryClient.invalidateQueries()
    onOpenChange(false)
  }
  const start = useMutation({
    ...startChatGPTLoginMutation(),
    onSuccess: response => setLogin(recordValue(response) ?? undefined)
  })
  const poll = useMutation({
    ...pollChatGPTLoginMutation(),
    onSuccess: response => {
      const update = recordValue(response) ?? {}
      if (update.status === 'complete') {
        finish()
      } else {
        setLogin(current => ({ ...current, ...update }))
      }
    }
  })
  const complete = useMutation({
    ...completeChatGPTBrowserLoginMutation(),
    onSuccess: finish
  })

  useEffect(() => {
    if (!open) return
    setLabel(entry?.label ?? '')
    setPriority(String(entry?.priority ?? 0))
    setLogin(undefined)
    setCallbackURL('')
    setValidationError(undefined)
    start.reset()
    poll.reset()
    complete.reset()
  }, [entry, open])

  const mode = textValue(login?.mode)
  const status = textValue(login?.status)
  const loginContext = recordValue(login?.login_context)
  const retryAfter = numberValue(login?.retry_after) ?? numberValue(login?.interval) ?? 5

  useEffect(() => {
    if (!open || mode !== 'device' || status === 'complete' || !loginContext || poll.isPending) return
    const timer = window.setTimeout(() => {
      poll.mutate({
        body: { login_context: loginContext },
        path: { provider_id: provider.provider_id }
      })
    }, retryAfter * 1_000)
    return () => window.clearTimeout(timer)
    // `poll` itself is a fresh object every render; depending on it would clear
    // and restart the countdown on every re-render. `mutate` and `isPending`
    // are the stable parts this effect actually uses.
  }, [loginContext, mode, open, poll.isPending, poll.mutate, provider.provider_id, retryAfter, status])

  const startLogin = () => {
    if (!label.trim()) {
      setValidationError(t('console.providers.credential_label_required'))
      return
    }
    setValidationError(undefined)
    start.mutate({
      body: {
        id: entry?.id,
        label: label.trim() || entry?.label || undefined,
        priority: Number.parseInt(priority, 10) || 0
      },
      path: { provider_id: provider.provider_id }
    })
  }
  const completeBrowserLogin = () => {
    if (!callbackURL.trim()) {
      setValidationError(
        t('common.field_required', {
          field: t('console.providers.callback_url')
        })
      )
      return
    }
    if (!loginContext) return
    setValidationError(undefined)
    complete.mutate({
      body: { login_context: loginContext, callback_url: callbackURL.trim() },
      path: { provider_id: provider.provider_id }
    })
  }
  const error = validationError ?? start.error ?? poll.error ?? complete.error
  const pending = start.isPending || poll.isPending || complete.isPending
  const dirty =
    Boolean(login) ||
    label !== (entry?.label ?? '') ||
    priority !== String(entry?.priority ?? 0) ||
    callbackURL.trim() !== ''
  const guard = useDialogDiscardGuard({ dirty: open && dirty, pending, onOpenChange })

  return (
    <Dialog open={open} onOpenChange={guard.requestOpenChange}>
      <DialogContent closeLabel={t('common.close')} showCloseButton={!pending}>
        <form
          className="contents"
          noValidate
          onSubmit={event => {
            event.preventDefault()
            if (!login) startLogin()
            else if (mode === 'browser_paste') completeBrowserLogin()
          }}>
          <DialogHeader>
            <DialogTitle>
              {entry ? t('console.providers.reauthenticate') : t('console.providers.add_chatgpt_account')}
            </DialogTitle>
            <DialogDescription>{t('console.providers.chatgpt_login_description')}</DialogDescription>
          </DialogHeader>

          <div className="grid gap-4">
            {error ? (
              <p className="text-sm text-destructive" aria-live="assertive">
                {chatGPTLoginErrorText(error, t)}
              </p>
            ) : null}
            {!login ? (
              <>
                <LabeledField label={t('console.providers.credential_label')} required>
                  <Input
                    value={label}
                    onChange={event => {
                      setLabel(event.target.value)
                      setValidationError(undefined)
                    }}
                  />
                </LabeledField>
                <LabeledField label={t('console.providers.priority')}>
                  <Input type="number" step={1} value={priority} onChange={event => setPriority(event.target.value)} />
                </LabeledField>
              </>
            ) : null}

            {mode === 'device' ? (
              <div className="grid gap-4 border border-border bg-muted/30 p-4">
                <p className="text-sm">{t('console.providers.device_login_instructions')}</p>
                <a
                  className="inline-flex items-center gap-1 text-sm text-link underline underline-offset-4"
                  href={textValue(login?.verification_url)}
                  target="_blank"
                  rel="noreferrer">
                  {textValue(login?.verification_url)}
                  <RiExternalLinkLine className="size-4" aria-hidden />
                </a>
                <ReadOnlyValue mono>{textValue(login?.user_code)}</ReadOnlyValue>
                <p className="text-xs text-muted-foreground">
                  {poll.isPending
                    ? t('console.providers.device_login_polling')
                    : t('console.providers.device_login_waiting', { seconds: retryAfter })}
                </p>
              </div>
            ) : null}

            {mode === 'browser_paste' ? (
              <div className="grid gap-4 border border-border bg-muted/30 p-4">
                <p className="text-sm">{t('console.providers.browser_login_instructions')}</p>
                <a
                  className="inline-flex items-center gap-1 text-sm text-link underline underline-offset-4"
                  href={textValue(login?.authorization_url)}
                  target="_blank"
                  rel="noreferrer">
                  {t('console.providers.open_authorization')}
                  <RiExternalLinkLine className="size-4" aria-hidden />
                </a>
                <LabeledField label={t('console.providers.callback_url')} required>
                  <Textarea
                    className="min-h-24 font-mono text-xs"
                    value={callbackURL}
                    onChange={event => {
                      setCallbackURL(event.target.value)
                      setValidationError(undefined)
                    }}
                  />
                </LabeledField>
              </div>
            ) : null}
          </div>

          <DialogFooter>
            <Button type="button" variant="ghost" disabled={pending} onClick={() => guard.requestOpenChange(false)}>
              {t('common.cancel')}
            </Button>
            {!login ? (
              <Button aria-busy={pending} type="submit" disabled={pending} incomplete={!label.trim() && !pending}>
                {pending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
                {t('console.providers.start_login')}
              </Button>
            ) : null}
            {mode === 'browser_paste' ? (
              <Button
                aria-busy={pending}
                type="submit"
                disabled={pending || !loginContext}
                incomplete={!callbackURL.trim() && !pending && Boolean(loginContext)}>
                {pending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
                {t('console.providers.complete_login')}
              </Button>
            ) : null}
          </DialogFooter>
        </form>
      </DialogContent>
      <DiscardConfirmDialog open={guard.confirming} onDiscard={guard.confirmDiscard} onKeep={guard.keepEditing} />
    </Dialog>
  )
}

function EnterpriseCredentialDialog({
  entry,
  onOpenChange,
  open,
  provider
}: {
  entry: AIGatewayCredentialPoolEntry | null | undefined
  onOpenChange: (open: boolean) => void
  open: boolean
  provider: AIGatewayProviderItem
}) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [label, setLabel] = useState('')
  const [priority, setPriority] = useState('0')
  const [accessToken, setAccessToken] = useState('')
  const [accountID, setAccountID] = useState('')
  const [planType, setPlanType] = useState('')
  const [email, setEmail] = useState('')
  const [validationError, setValidationError] = useState<string>()
  const labelInput = useRef<HTMLInputElement>(null)
  const accessTokenInput = useRef<HTMLInputElement>(null)
  const accountIDInput = useRef<HTMLInputElement>(null)

  const save = useMutation({
    ...addChatGPTEnterpriseCredentialMutation(),
    onSuccess: () => {
      toast.success(t('console.providers.enterprise_token_saved'))
      void queryClient.invalidateQueries()
      onOpenChange(false)
    }
  })

  useEffect(() => {
    if (!open) return
    setLabel(entry?.label ?? '')
    setPriority(String(entry?.priority ?? 0))
    setAccessToken('')
    setAccountID(entry?.account_id ?? '')
    setPlanType(entry?.plan_type ?? '')
    setEmail(entry?.email ?? '')
    setValidationError(undefined)
    save.reset()
  }, [entry, open])

  const submit = () => {
    const requiredField = [
      { field: t('console.providers.credential_label'), input: labelInput, value: label.trim() },
      { field: t('console.providers.access_token'), input: accessTokenInput, value: accessToken.trim() },
      { field: t('console.providers.account_id'), input: accountIDInput, value: accountID.trim() }
    ].find(item => !item.value)
    if (requiredField) {
      setValidationError(t('common.field_required', { field: requiredField.field }))
      requiredField.input.current?.focus()
      return
    }

    setValidationError(undefined)
    save.mutate({
      body: {
        id: entry?.id,
        label: label.trim() || undefined,
        priority: Number.parseInt(priority, 10) || 0,
        access_token: accessToken.trim(),
        account_id: accountID.trim(),
        plan_type: planType.trim() || undefined,
        email: email.trim() || undefined
      },
      path: { provider_id: provider.provider_id }
    })
  }
  const incomplete = !label.trim() || !accessToken.trim() || !accountID.trim()
  const dirty =
    label !== (entry?.label ?? '') ||
    priority !== String(entry?.priority ?? 0) ||
    accessToken.trim() !== '' ||
    accountID !== (entry?.account_id ?? '') ||
    planType !== (entry?.plan_type ?? '') ||
    email !== (entry?.email ?? '')
  const guard = useDialogDiscardGuard({ dirty: open && dirty, pending: save.isPending, onOpenChange })

  return (
    <Dialog open={open} onOpenChange={guard.requestOpenChange}>
      <DialogContent closeLabel={t('common.close')} showCloseButton={!save.isPending}>
        <form
          className="contents"
          noValidate
          onSubmit={event => {
            event.preventDefault()
            submit()
          }}>
          <DialogHeader>
            <DialogTitle>
              {entry ? t('console.providers.reauthenticate') : t('console.providers.add_enterprise_token')}
            </DialogTitle>
            <DialogDescription>{t('console.providers.enterprise_token_description')}</DialogDescription>
          </DialogHeader>
          <div className="grid gap-4">
            {validationError || save.error ? (
              <p className="text-sm text-destructive" aria-live="assertive">
                {validationError ?? requestErrorMessage(save.error)}
              </p>
            ) : null}
            <LabeledField label={t('console.providers.credential_label')} required>
              <Input
                ref={labelInput}
                value={label}
                onChange={event => {
                  setLabel(event.target.value)
                  setValidationError(undefined)
                }}
              />
            </LabeledField>
            <LabeledField label={t('console.providers.priority')}>
              <Input type="number" step={1} value={priority} onChange={event => setPriority(event.target.value)} />
            </LabeledField>
            <LabeledField label={t('console.providers.access_token')} required>
              <EncryptedValueInput
                ref={accessTokenInput}
                revealLabel={t('console.aria.reveal_secret')}
                value={accessToken}
                onChange={event => {
                  setAccessToken(event.target.value)
                  setValidationError(undefined)
                }}
              />
            </LabeledField>
            <LabeledField label={t('console.providers.account_id')} required>
              <Input
                ref={accountIDInput}
                value={accountID}
                onChange={event => {
                  setAccountID(event.target.value)
                  setValidationError(undefined)
                }}
              />
            </LabeledField>
            <LabeledField label={t('console.providers.plan_type')}>
              <Input value={planType} onChange={event => setPlanType(event.target.value)} />
            </LabeledField>
            <LabeledField label={t('console.providers.email')}>
              <Input type="email" value={email} onChange={event => setEmail(event.target.value)} />
            </LabeledField>
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="ghost"
              disabled={save.isPending}
              onClick={() => guard.requestOpenChange(false)}>
              {t('common.cancel')}
            </Button>
            <SaveButton
              type="submit"
              disabled={save.isPending}
              incomplete={incomplete && !save.isPending}
              loading={save.isPending}>
              {t('common.save')}
            </SaveButton>
          </DialogFooter>
        </form>
      </DialogContent>
      <DiscardConfirmDialog open={guard.confirming} onDiscard={guard.confirmDiscard} onKeep={guard.keepEditing} />
    </Dialog>
  )
}

function CredentialFact({ label, value }: { label: string; value: string | null | undefined }) {
  if (!value) return null

  return (
    <div className="grid gap-1 sm:grid-cols-[minmax(8rem,0.4fr)_1fr] sm:gap-3">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="break-all font-mono tabular-nums">{value}</dd>
    </div>
  )
}

function CredentialDiagnostics({ label, value }: { label: string; value: string | undefined }) {
  if (!value) return null

  return (
    <details>
      <summary className="cursor-pointer text-sm font-medium">{label}</summary>
      <pre className="mt-2 max-h-56 overflow-auto whitespace-pre-wrap break-all border border-border bg-muted p-3 text-xs">
        {value}
      </pre>
    </details>
  )
}

function credentialStatusTone(
  status: AIGatewayCredentialPoolEntry['status']
): 'danger' | 'neutral' | 'positive' | 'warning' {
  switch (status) {
    case 'ok':
      return 'positive'
    case 'exhausted':
      return 'warning'
    case 'dead':
      return 'danger'
    case 'disabled':
      return 'neutral'
  }
}

function formatCredentialUsage(t: TFunction, value: Record<string, unknown>): string | undefined {
  const buckets = [
    [t('console.providers.usage_model'), recordValue(value.model)],
    [t('console.providers.usage_image_generation'), recordValue(value.image_gen)]
  ] as const

  const parts = buckets.flatMap(([name, usage]) => {
    if (!usage) return []
    const total = numberValue(usage.total_tokens)
    const input = numberValue(usage.input_tokens) ?? numberValue(usage.prompt_tokens)
    const output = numberValue(usage.output_tokens) ?? numberValue(usage.completion_tokens)
    if (total === undefined && input === undefined && output === undefined) return []

    return [
      t('console.providers.usage_bucket', {
        name,
        total: total ?? (input ?? 0) + (output ?? 0),
        input: input ?? 0,
        output: output ?? 0
      })
    ]
  })

  return parts.length > 0 ? parts.join(' · ') : undefined
}

function formatRateLimits(value: Record<string, unknown>): string | undefined {
  const parts = Object.entries(value)
    .filter((entry): entry is [string, string] => typeof entry[1] === 'string')
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([name, limit]) => `${name.replace(/^x-codex-/, '')}: ${limit}`)

  return parts.length > 0 ? parts.join('\n') : undefined
}

function textValue(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function numberValue(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
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

function credentialStrategyLabel(t: ReturnType<typeof useTranslation>['t'], strategy: CredentialStrategy): string {
  switch (strategy) {
    case 'fill_first':
      return t('console.providers.strategy_fill_first')
    case 'round_robin':
      return t('console.providers.strategy_round_robin')
    case 'least_used':
      return t('console.providers.strategy_least_used')
    case 'random':
      return t('console.providers.strategy_random')
  }
}

function credentialSourceLabel(t: TFunction, source: string): string {
  switch (source) {
    case 'manual':
    case 'provider_default':
    case 'device_oauth':
    case 'browser_oauth':
    case 'enterprise_access_token':
      return t(`console.providers.source_${source}`)
    default:
      return humanizeKey(source)
  }
}
