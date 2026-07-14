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
  Textarea,
  toast
} from '@ankole/uikit'
import { RiArrowDownSLine } from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ankoleWebAiGatewayProviderControllerDeleteProviderMutation as ankoleWebAIGatewayProviderControllerDeleteProviderMutation,
  ankoleWebAiGatewayProviderControllerIndexOptions as ankoleWebAIGatewayProviderControllerIndexOptions,
  ankoleWebAiGatewayProviderControllerProviderKindsOptions as ankoleWebAIGatewayProviderControllerProviderKindsOptions,
  ankoleWebAiGatewayProviderControllerPutProviderMutation as ankoleWebAIGatewayProviderControllerPutProviderMutation,
  ankoleWebCodexAccountControllerCreateMutation,
  ankoleWebCodexAccountControllerDeleteMutation,
  ankoleWebCodexAccountControllerIndexOptions,
  ankoleWebCodexAccountControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import type {
  AiGatewayProviderItem as AIGatewayProviderItem,
  AiGatewayProviderKindItem as AIGatewayProviderKindItem
} from '../api/generated/types.gen'
import i18n from '../../common/i18n'
import { requestErrorMessage } from '../../common/request-errors'
import { LabeledField, ResourceEditorPage, ResourceListPage, RowActions } from '../console-shell'
import {
  buildConnectionOptions,
  connectionSettings,
  initialSettingValue,
  type ProviderSetting,
  type SettingValidationError
} from './provider-settings'
import { ProviderSettingField } from './provider-setting-field'
import { CodexAccountEditorModel } from '../state/codex-account-editor-model'
import { nextProviderID, ProviderEditorModel } from '../state/provider-editor-model'

export function ProvidersListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const providers = useQuery(ankoleWebAIGatewayProviderControllerIndexOptions())
  const codexAccounts = useQuery(ankoleWebCodexAccountControllerIndexOptions())
  const rows = providers.data?.ai_gateway_providers ?? []
  const accounts = codexAccounts.data?.codex_accounts ?? []
  const deleteProvider = useMutation({
    ...ankoleWebAIGatewayProviderControllerDeleteProviderMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.providers.deleted', { id: variables.path.provider_id }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const deleteCodexAccount = useMutation({
    ...ankoleWebCodexAccountControllerDeleteMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.codex_accounts.deleted', { id: variables.path.account_id }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <div className="grid gap-10">
      <ResourceListPage
        title={t('console.codex_accounts.title')}
        description={t('console.codex_accounts.description')}
        createTo="codex/new"
        createLabel={t('console.codex_accounts.new')}
        columns={[
          t('console.codex_accounts.name'),
          t('console.codex_accounts.account_id'),
          t('console.codex_accounts.auth_hash')
        ]}
        isLoading={codexAccounts.isLoading}
        isEmpty={accounts.length === 0}
        emptyTitle={t('console.codex_accounts.empty_title')}
        emptyDescription={t('console.codex_accounts.empty_description')}
        error={codexAccounts.error}>
        {accounts.map(account => (
          <TableRow
            key={account.account_id}
            className="cursor-pointer"
            onClick={() => navigate(`codex/${encodeURIComponent(account.account_id)}`)}>
            <TableCell>{account.name}</TableCell>
            <TableCell className="font-mono text-xs">{account.account_id}</TableCell>
            <TableCell className="max-w-48 truncate font-mono text-xs">{account.auth_hash}</TableCell>
            <RowActions
              editTo={`codex/${encodeURIComponent(account.account_id)}`}
              editLabel={t('common.edit')}
              deletePending={deleteCodexAccount.isPending}
              deleteConfirm={{
                title: t('console.codex_accounts.delete_title'),
                description: t('console.codex_accounts.delete_description', { name: account.name }),
                confirmLabel: t('common.delete')
              }}
              onDelete={() => deleteCodexAccount.mutate({ path: { account_id: account.account_id } })}
            />
          </TableRow>
        ))}
      </ResourceListPage>

      <ResourceListPage
        title={t('console.providers.title')}
        description={t('console.providers.description')}
        createTo="new"
        createLabel={t('console.providers.new')}
        columns={[
          t('console.providers.provider'),
          t('console.providers.kind'),
          t('console.providers.credentials'),
          t('console.providers.state')
        ]}
        isLoading={providers.isLoading}
        isEmpty={rows.length === 0}
        emptyTitle={t('console.providers.empty_title')}
        emptyDescription={t('console.providers.empty_description')}
        error={providers.error}>
        {rows.map(provider => (
          <TableRow
            key={provider.provider_id}
            className="cursor-pointer"
            onClick={() => navigate(encodeURIComponent(provider.provider_id))}>
            <TableCell className="font-mono text-xs">{provider.provider_id}</TableCell>
            <TableCell>{provider.provider_kind}</TableCell>
            <TableCell>
              <div className="flex flex-wrap gap-1.5">
                {Object.entries(provider.encrypted_options).map(([key, option]) => (
                  <Badge key={key} variant={option.present ? 'default' : 'outline'}>
                    {key}
                  </Badge>
                ))}
              </div>
            </TableCell>
            <TableCell>
              <Badge variant={provider.disabled_at ? 'secondary' : 'default'}>
                {provider.disabled_at ? t('console.status.disabled') : t('console.status.enabled')}
              </Badge>
            </TableCell>
            <RowActions
              editTo={encodeURIComponent(provider.provider_id)}
              editLabel={t('common.edit')}
              deletePending={deleteProvider.isPending}
              deleteConfirm={{
                title: t('console.providers.delete_title'),
                description: t('console.providers.delete_description', { id: provider.provider_id }),
                confirmLabel: t('common.disable')
              }}
              onDelete={() => deleteProvider.mutate({ path: { provider_id: provider.provider_id } })}
            />
          </TableRow>
        ))}
      </ResourceListPage>
    </div>
  )
}

export function CodexAccountEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(CodexAccountEditorModel)
  const params = useParams()
  const accountID = params.accountID ? decodeURIComponent(params.accountID) : undefined
  const mode = accountID ? 'edit' : 'new'
  const accounts = useQuery(ankoleWebCodexAccountControllerIndexOptions())
  const selected = accounts.data?.codex_accounts.find(account => account.account_id === accountID)

  useEffect(() => {
    if (mode === 'new') model.initialize('new')
    else if (selected) model.initialize(`account:${selected.account_id}`, selected.name)
  }, [mode, model, selected])

  const createAccount = useMutation({
    ...ankoleWebCodexAccountControllerCreateMutation(),
    onSuccess: response => {
      toast.success(t('console.codex_accounts.saved', { name: response.codex_account.name }))
      void queryClient.invalidateQueries()
      navigate('../..')
    }
  })
  const updateAccount = useMutation({
    ...ankoleWebCodexAccountControllerUpdateMutation(),
    onSuccess: response => {
      toast.success(t('console.codex_accounts.saved', { name: response.codex_account.name }))
      void queryClient.invalidateQueries()
      navigate('../..')
    }
  })

  const submit = () => {
    model.clearValidation()
    if (!model.name.value.trim()) {
      model.validationError.value = t('console.codex_accounts.name_required')
      return
    }
    if (mode === 'new') {
      if (!model.authJSON.value.trim()) {
        model.validationError.value = t('console.codex_accounts.auth_required')
        return
      }
      createAccount.mutate({ body: { name: model.name.value.trim(), auth_json: model.authJSON.value } })
      return
    }
    if (accountID) {
      updateAccount.mutate({
        body: {
          name: model.name.value.trim(),
          auth_json: model.authJSON.value.trim() ? model.authJSON.value : undefined
        },
        path: { account_id: accountID }
      })
    }
  }

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.codex_accounts.new') : (selected?.name ?? accountID ?? '')}
      description={t('console.codex_accounts.editor_description')}
      backTo={mode === 'new' ? '../..' : '../..'}
      error={model.validationError.value ?? createAccount.error ?? updateAccount.error}
      submitting={createAccount.isPending || updateAccount.isPending}
      onSubmit={submit}>
      {accountID ? (
        <LabeledField label={t('console.codex_accounts.account_id')}>
          <Input disabled value={accountID} />
        </LabeledField>
      ) : null}
      <LabeledField label={t('console.codex_accounts.name')} required>
        <Input value={model.name.value} onChange={event => (model.name.value = event.target.value)} />
      </LabeledField>
      <LabeledField
        label={t('console.codex_accounts.auth_json')}
        description={
          mode === 'edit' ? t('console.codex_accounts.auth_json_keep') : t('console.codex_accounts.auth_json_hint')
        }
        required={mode === 'new'}>
        <Textarea
          className="min-h-48 font-mono text-xs"
          spellCheck={false}
          value={model.authJSON.value}
          onChange={event => (model.authJSON.value = event.target.value)}
        />
      </LabeledField>
    </ResourceEditorPage>
  )
}

export function ProviderEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(ProviderEditorModel)
  const params = useParams()
  const providerID = params.providerID ? decodeURIComponent(params.providerID) : undefined
  const mode = providerID ? 'edit' : 'new'

  const providers = useQuery(ankoleWebAIGatewayProviderControllerIndexOptions())
  const providerKinds = useQuery(ankoleWebAIGatewayProviderControllerProviderKindsOptions())
  const configuredProviders = providers.data?.ai_gateway_providers
  const kinds = providerKinds.data?.provider_kinds ?? []
  const selected = configuredProviders?.find(provider => provider.provider_id === providerID)

  const activeKind = kinds.find(kind => kind.provider_kind === model.providerKind.value)
  const settings = connectionSettings(activeKind)

  // Initialize once per edited target (or once kinds load for a new provider).
  // Later query refreshes must not replace the page-scoped draft.
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
    ...ankoleWebAIGatewayProviderControllerPutProviderMutation(),
    onSuccess: response => {
      toast.success(t('console.providers.saved', { id: response.ai_gateway_provider.provider_id }))
      void queryClient.invalidateQueries()
      navigate('/providers')
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
      error={model.validationError.value ?? saveProvider.error}
      submitting={saveProvider.isPending}
      onSubmit={submit}>
      <div className="grid gap-5 md:grid-cols-2">
        <LabeledField label={t('console.providers.provider_id')} description={t('console.providers.provider_id_hint')}>
          <Input
            disabled={mode === 'edit'}
            placeholder="openai"
            value={model.providerID.value}
            onChange={event => (model.providerID.value = event.target.value)}
          />
        </LabeledField>
        <LabeledField label={t('console.providers.kind')}>
          <Select
            disabled={mode === 'edit'}
            value={model.providerKind.value}
            onValueChange={value => changeKind(String(value))}>
            <SelectTrigger className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {kinds.map(kind => (
                <SelectItem key={kind.provider_kind} value={kind.provider_kind}>
                  {providerKindLabel(kind)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </LabeledField>
      </div>

      {advancedBaseURL ? null : baseURLField}

      {basicSettings.map(setting => (
        <ProviderSettingField
          key={setting.key}
          setting={setting}
          provider={selected}
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
                provider={selected}
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
          <Link to="/agents" className="text-primary underline underline-offset-4">
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
  return kind.label.en ?? kind.label['en-US'] ?? kind.label.default ?? kind.provider_kind
}

function settingValidationMessage(field: string, error: SettingValidationError): string {
  switch (error) {
    case 'required':
      return i18n.t('common.field_required', { field })
    case 'json_object':
      return i18n.t('common.must_be_json_object', { field })
    case 'integer':
      return i18n.t('common.must_be_integer', { field })
    case 'number':
      return i18n.t('common.must_be_number', { field })
    case 'selection':
      return i18n.t('common.must_be_valid_selection', { field })
  }
}
