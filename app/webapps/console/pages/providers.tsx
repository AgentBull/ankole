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
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
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
import {
  JSONField,
  LabeledField,
  ResourceEditorPage,
  ResourceListPage,
  RowActions,
  SecretInput
} from '../console-shell'
import {
  buildConnectionOptions,
  connectionSettings,
  encryptedOptionState,
  humanizeKey,
  initialSettingValue,
  type ProviderSetting
} from './provider-settings'

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

type CodexAccountForm = {
  name: string
  authJSON: string
}

export function CodexAccountEditorPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const params = useParams()
  const accountID = params.accountID ? decodeURIComponent(params.accountID) : undefined
  const mode = accountID ? 'edit' : 'new'
  const accounts = useQuery(ankoleWebCodexAccountControllerIndexOptions())
  const selected = accounts.data?.codex_accounts.find(account => account.account_id === accountID)
  const [form, setForm] = useState<CodexAccountForm>({ name: '', authJSON: '' })
  const [error, setError] = useState<string>()

  useEffect(() => {
    setForm({ name: selected?.name ?? '', authJSON: '' })
  }, [selected?.account_id, selected?.name])

  const createAccount = useMutation({
    ...ankoleWebCodexAccountControllerCreateMutation(),
    onSuccess: response => {
      toast.success(t('console.codex_accounts.saved', { name: response.codex_account.name }))
      void queryClient.invalidateQueries()
      navigate('../..')
    },
    onError: mutationError => setError(requestErrorMessage(mutationError))
  })
  const updateAccount = useMutation({
    ...ankoleWebCodexAccountControllerUpdateMutation(),
    onSuccess: response => {
      toast.success(t('console.codex_accounts.saved', { name: response.codex_account.name }))
      void queryClient.invalidateQueries()
      navigate('../..')
    },
    onError: mutationError => setError(requestErrorMessage(mutationError))
  })

  const submit = () => {
    setError(undefined)
    if (!form.name.trim()) {
      setError(t('console.codex_accounts.name_required'))
      return
    }
    if (mode === 'new') {
      if (!form.authJSON.trim()) {
        setError(t('console.codex_accounts.auth_required'))
        return
      }
      createAccount.mutate({ body: { name: form.name.trim(), auth_json: form.authJSON } })
      return
    }
    if (accountID) {
      updateAccount.mutate({
        body: { name: form.name.trim(), auth_json: form.authJSON.trim() ? form.authJSON : undefined },
        path: { account_id: accountID }
      })
    }
  }

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.codex_accounts.new') : (selected?.name ?? accountID ?? '')}
      description={t('console.codex_accounts.editor_description')}
      backTo={mode === 'new' ? '../..' : '../..'}
      error={error ?? createAccount.error ?? updateAccount.error}
      submitting={createAccount.isPending || updateAccount.isPending}
      onSubmit={submit}>
      {accountID ? (
        <LabeledField label={t('console.codex_accounts.account_id')}>
          <Input disabled value={accountID} />
        </LabeledField>
      ) : null}
      <LabeledField label={t('console.codex_accounts.name')} required>
        <Input value={form.name} onChange={event => setForm(current => ({ ...current, name: event.target.value }))} />
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
          value={form.authJSON}
          onChange={event => setForm(current => ({ ...current, authJSON: event.target.value }))}
        />
      </LabeledField>
    </ResourceEditorPage>
  )
}

type ProviderForm = {
  providerID: string
  providerKind: string
  baseURL: string
  options: Record<string, string>
}

export function ProviderEditorPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const params = useParams()
  const providerID = params.providerID ? decodeURIComponent(params.providerID) : undefined
  const mode = providerID ? 'edit' : 'new'

  const providers = useQuery(ankoleWebAIGatewayProviderControllerIndexOptions())
  const providerKinds = useQuery(ankoleWebAIGatewayProviderControllerProviderKindsOptions())
  const kinds = providerKinds.data?.provider_kinds ?? []
  const selected = providers.data?.ai_gateway_providers.find(provider => provider.provider_id === providerID)

  const [form, setForm] = useState<ProviderForm>({ providerID: '', providerKind: '', baseURL: '', options: {} })
  const [error, setError] = useState<string>()

  const activeKind = kinds.find(kind => kind.provider_kind === form.providerKind)
  const settings = useMemo(() => connectionSettings(activeKind), [activeKind])

  // Initialize the form once per edited target (or once kinds load for a new
  // provider). Manual edits — including switching kind — mutate `form` directly
  // afterwards, so this effect must not depend on the live kind selection.
  const ready = kinds.length > 0 && (mode === 'new' || Boolean(selected))
  useEffect(() => {
    if (!ready) return
    if (mode === 'edit' && selected) {
      const kind = kinds.find(item => item.provider_kind === selected.provider_kind)
      setForm({
        providerID: selected.provider_id,
        providerKind: selected.provider_kind,
        baseURL: selected.base_url ?? '',
        options: initialOptions(connectionSettings(kind), selected)
      })
    } else if (mode === 'new') {
      const kind = kinds[0]
      setForm({
        providerID: '',
        providerKind: kind?.provider_kind ?? '',
        baseURL: kind?.default_base_url ?? '',
        options: initialOptions(connectionSettings(kind), undefined)
      })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, mode, providerID])

  const saveProvider = useMutation({
    ...ankoleWebAIGatewayProviderControllerPutProviderMutation(),
    onSuccess: response => {
      toast.success(t('console.providers.saved', { id: response.ai_gateway_provider.provider_id }))
      void queryClient.invalidateQueries()
      navigate('..')
    },
    onError: mutationError => setError(requestErrorMessage(mutationError))
  })

  const changeKind = (providerKind: string) => {
    const kind = kinds.find(item => item.provider_kind === providerKind)
    setForm({
      providerID: form.providerID,
      providerKind,
      baseURL: kind?.default_base_url ?? '',
      options: initialOptions(connectionSettings(kind), undefined)
    })
  }

  const submit = () => {
    setError(undefined)
    const trimmedID = form.providerID.trim()
    if (!trimmedID) {
      setError(t('console.providers.provider_id_required'))
      return
    }

    const built = buildConnectionOptions(settings, form.options, field =>
      i18n.t('common.must_be_json_object', { field })
    )
    if (!built.ok) {
      setError(built.error)
      return
    }

    saveProvider.mutate({
      body: {
        provider_id: trimmedID,
        provider_kind: form.providerKind,
        base_url: form.baseURL.trim() ? form.baseURL.trim() : null,
        connection_options: built.value
      },
      path: { provider_id: trimmedID }
    })
  }

  const mapSettings = settings.filter(setting => setting.isMap)
  const plainSettings = settings.filter(setting => !setting.isMap)

  return (
    <ResourceEditorPage
      title={mode === 'new' ? t('console.providers.new') : (providerID ?? '')}
      description={t('console.providers.editor_description')}
      backTo=".."
      error={error ?? saveProvider.error}
      submitting={saveProvider.isPending}
      onSubmit={submit}>
      <div className="grid gap-5 md:grid-cols-2">
        <LabeledField label={t('console.providers.provider_id')} description={t('console.providers.provider_id_hint')}>
          <Input
            disabled={mode === 'edit'}
            placeholder="openai"
            value={form.providerID}
            onChange={event => setForm(current => ({ ...current, providerID: event.target.value }))}
          />
        </LabeledField>
        <LabeledField label={t('console.providers.kind')}>
          <Select
            disabled={mode === 'edit'}
            value={form.providerKind}
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

      <LabeledField label={t('console.providers.base_url')} description={t('console.providers.base_url_hint')}>
        <Input
          placeholder={activeKind?.default_base_url ?? 'https://api.example.com/v1'}
          value={form.baseURL}
          onChange={event => setForm(current => ({ ...current, baseURL: event.target.value }))}
        />
      </LabeledField>

      {plainSettings.map(setting => (
        <SettingField
          key={setting.key}
          setting={setting}
          provider={selected}
          value={form.options[setting.key] ?? ''}
          onChange={value =>
            setForm(current => ({ ...current, options: { ...current.options, [setting.key]: value } }))
          }
        />
      ))}

      {mapSettings.length > 0 ? (
        <Collapsible className="grid gap-4" defaultOpen={false}>
          <CollapsibleTrigger className="flex w-full items-center justify-between gap-3 border border-border bg-muted/40 px-4 py-3 text-left text-sm font-medium">
            <span>{t('common.advanced_settings')}</span>
            <span className="flex items-center gap-2 text-xs text-muted-foreground">
              {mapSettings.length}
              <RiArrowDownSLine className="size-4" aria-hidden />
            </span>
          </CollapsibleTrigger>
          <CollapsibleContent className="grid gap-5">
            {mapSettings.map(setting => (
              <SettingField
                key={setting.key}
                setting={setting}
                provider={selected}
                value={form.options[setting.key] ?? ''}
                onChange={value =>
                  setForm(current => ({ ...current, options: { ...current.options, [setting.key]: value } }))
                }
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

function SettingField({
  onChange,
  provider,
  setting,
  value
}: {
  onChange: (value: string) => void
  provider: AIGatewayProviderItem | undefined
  setting: ProviderSetting
  value: string
}) {
  const { t } = useTranslation()
  const label = humanizeKey(setting.key)

  if (setting.encrypted) {
    const state = encryptedOptionState(provider, setting.key)
    const description = state?.present
      ? t('console.providers.secret_keep', { masked: state.masked ?? '••••' })
      : t('console.providers.secret_hint')
    return (
      <LabeledField label={label} description={description} required={setting.required && !state?.present}>
        <SecretInput placeholder="sk-..." value={value} onChange={event => onChange(event.target.value)} />
      </LabeledField>
    )
  }

  if (setting.isMap) {
    return (
      <JSONField
        label={label}
        description={t('console.providers.map_hint')}
        minRows={4}
        value={value}
        onChange={onChange}
      />
    )
  }

  return (
    <LabeledField label={label} required={setting.required}>
      <Input
        placeholder={setting.default != null ? String(setting.default) : undefined}
        value={value}
        onChange={event => onChange(event.target.value)}
      />
    </LabeledField>
  )
}

function initialOptions(
  settings: ProviderSetting[],
  provider: AIGatewayProviderItem | undefined
): Record<string, string> {
  return Object.fromEntries(settings.map(setting => [setting.key, initialSettingValue(setting, provider)]))
}

function providerKindLabel(kind: AIGatewayProviderKindItem): string {
  const label = kind.label.en ?? kind.label['en-US'] ?? kind.label.default ?? kind.provider_kind
  return `${label} (${kind.provider_kind})`
}
